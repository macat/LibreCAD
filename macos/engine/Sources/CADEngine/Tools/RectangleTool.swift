//
//  RectangleTool.swift
//  CADEngine
//
//  The Rectangle draw tool — pick two opposite corners to draw an axis-aligned
//  rectangle as a single closed polyline. Ported from LibreCAD's
//  `RS_ActionDrawRectangle` (librecad/src/lib/actions/drawing/draw/rectangle/
//  rs_actiondrawrectangle.cpp), with the magic `int m_status` replaced by a
//  private `enum State` (engine-architecture note) and the result emitted as one
//  closed `PolylineData` (LibreCAD builds the rectangle as a closed polyline).
//
//  Behavior:
//    - first `.click`  → fix the first corner (State.settingFirst → .settingSecond).
//    - `.move`         → rubber-band preview of the closed rect spanned by the
//                        first corner and the cursor (4 corners, closed).
//    - next `.click`   → commit ONE `.polyline(PolylineData)` — a closed 4-vertex
//                        rectangle from the two opposite corners — then RESET to
//                        wait for the next rectangle's first corner.
//    - `.backspace`    → step back the first corner (undo the pick within the run,
//                        no commit), returning to the initial state.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) → end the run; `.finished` (nothing pending — each rectangle
//                        is committed on its second click).
//    - A degenerate pick (zero area / coincident opposite corners) is ignored.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawRectangle).
//

import Foundation

/// The corner treatment of a drawn rectangle, mirroring LibreCAD's
/// `RS_ActionDrawRectangle` corner options (square / rounded / bevel). The
/// tool-options bar (UX-plan U2) would surface this as a segmented control plus a
/// numeric field for the radius / chamfer distance; the app sets it on a
/// freshly-minted tool (like `fixedWidth`/`sides`) before the user draws.
///
/// All variants still commit a SINGLE closed `.polyline` of the SAME entity kind —
/// only the per-vertex shape changes: `.square` keeps the 4 sharp corners (the
/// original behavior); `.rounded` replaces each corner with two tangent vertices
/// joined by a quarter-circle **bulge** arc; `.chamfer` replaces each corner with
/// two tangent vertices joined by a straight bevel segment (8 sharp vertices).
public enum RectangleCorner: Sendable, Hashable {
    /// Sharp 90° corners — the default, identical to the original 4-vertex rect.
    case square
    /// Rounded corners: each corner is cut back by `radius` along both edges and
    /// joined by a convex quarter-circle arc (a bulge edge). A non-positive radius,
    /// or one too large to fit half the shorter side, falls back to `.square`.
    case rounded(radius: Double)
    /// Chamfered (beveled) corners: each corner is cut back by `distance` along
    /// both edges and joined by a straight bevel segment. A non-positive distance,
    /// or one too large to fit half the shorter side, falls back to `.square`.
    case chamfer(distance: Double)
}

/// The interactive Rectangle tool. Click two opposite corners to draw an
/// axis-aligned rectangle as a single closed polyline; it then resets to draw the
/// next rectangle until `.commit`/`.cancel`.
public struct RectangleTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawRectangle`'s status
    /// integers (SetPoint1 = 0, SetPoint2 = 1) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the first corner (no corner fixed yet).
        case settingFirst
        /// The first corner is fixed; waiting for the opposite corner. `first` is
        /// the fixed corner the rectangle is spanned from.
        case settingSecond(first: Vector)
    }

    /// The current state. Starts waiting for the first corner.
    private var state: State = .settingFirst

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// An optional EXACT width (world units) for the rectangle, surfaced by the
    /// tool-options bar (UX-plan U2). When BOTH `fixedWidth` and `fixedHeight` are
    /// set (> 0), a SINGLE click fixes the lower-left corner and immediately commits
    /// a rectangle of that exact size (extending +x / +y from the click) — the
    /// "draw a 100×50 box here" flow. `nil` (the default) keeps the original
    /// two-corner drag behavior, so this is fully back-compatible.
    public var fixedWidth: Double?

    /// An optional EXACT height (world units). See `fixedWidth` — both must be set
    /// (> 0) for the single-click exact-size commit; otherwise the tool draws by two
    /// dragged corners as before.
    public var fixedHeight: Double?

    /// Whether an exact size is configured (both dimensions set and positive), so a
    /// single click commits a rectangle of that size instead of waiting for the
    /// opposite corner.
    private var hasFixedSize: Bool {
        guard let w = fixedWidth, let h = fixedHeight else { return false }
        return w > Tolerance.distance && h > Tolerance.distance
    }

    /// The corner treatment for committed (and previewed) rectangles, surfaced by
    /// the tool-options bar (UX-plan U2). Defaults to `.square` so the original
    /// 4-vertex sharp rectangle is unchanged; `.rounded(radius:)` / `.chamfer(
    /// distance:)` reshape every corner at commit + preview time. Fully orthogonal
    /// to `fixedWidth`/`fixedHeight` — an exact-size single-click box is rounded /
    /// chamfered too.
    public var corner: RectangleCorner = .square

    public init() {}

    // MARK: - Tool

    public var title: String { "Rectangle" }

    public var status: String {
        switch state {
        case .settingFirst:
            return hasFixedSize
                ? "Specify corner (size \(sizePrompt))"
                : "Specify first corner"
        case .settingSecond: return "Specify opposite corner"
        }
    }

    /// A compact "W×H" readout of the configured exact size for the status prompt.
    private var sizePrompt: String {
        let w = fixedWidth ?? 0, h = fixedHeight ?? 0
        return "\(Self.trim(w))×\(Self.trim(h))"
    }

    /// Formats a dimension with no trailing ".0" for whole values (status text only).
    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// The live rubber-band: a closed 4-corner rectangle spanned by the fixed
    /// first corner and the current cursor. Empty before the first corner is set,
    /// or before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .settingSecond(let first) = state, cursor.valid, first.valid else {
            return []
        }
        // The preview shows the corner treatment too: a rounded/chamfered rect
        // previews its shaped outline (rounded corners are tessellated here so the
        // overlay shows the arc, since a `ResolvedPolyline` carries no bulge).
        return [ResolvedPolyline(points: Self.previewPoints(first, cursor, corner: corner),
                                 closed: true, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the first corner is set.
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — end the run. Each rectangle was already committed on its
            // second click, so there is nothing pending to add here.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingFirst:
            // Exact-size mode (UX-plan U2): a single click fixes the lower-left
            // corner and immediately commits a rectangle of the configured size,
            // then re-arms — the "drop a 100×50 box here" flow.
            if hasFixedSize, p.valid {
                let opposite = Vector(p.x + (fixedWidth ?? 0), p.y + (fixedHeight ?? 0))
                return commitRect(from: p, to: opposite)
            }
            // First corner fixed; now rubber-band toward the opposite corner.
            state = .settingSecond(first: p)
            cursor = p
            return .none

        case .settingSecond(let first):
            // Commit one closed rectangle spanned by first↔p, then RESET to draw
            // the next rectangle.
            return commitRect(from: first, to: p)
        }
    }

    /// Builds + commits one closed-polyline rectangle spanned by two opposite
    /// corners, then resets to draw the next. A degenerate (zero-area / coincident
    /// corners) pick is ignored (returns `.none`, keeps the current state) so a
    /// stray click never creates a collapsed rectangle. Shared by the two-corner
    /// drag commit and the exact-size single-click commit.
    private mutating func commitRect(from a: Vector, to b: Vector) -> ToolOutcome {
        guard a.valid, b.valid, !Self.isDegenerate(a, b) else { return .none }
        let data = PolylineData(vertices: Self.vertices(a, b, corner: corner), closed: true)
        let record = EntityRecord(id: .placeholder, kind: .polyline(data))
        reset()
        return .commit([.add(record)])
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingFirst:
            // Nothing to step back.
            return .none
        case .settingSecond:
            // Step back the fixed first corner to before it was picked.
            // (Already-committed rectangles stay in the drawing — the app's undo
            //  removes those; backspace only rewinds the in-progress pick.)
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-corner state.
    private mutating func reset() {
        state = .settingFirst
        cursor = .invalid
    }

    // MARK: - Geometry

    /// The four corners of the axis-aligned rectangle spanned by two opposite
    /// corners, in CCW-from-(x0,y0) order: (x0,y0), (x1,y0), (x1,y1), (x0,y1).
    /// `a`/`b` are the two opposite corners; `x0/y0` come from `a`, `x1/y1` from
    /// `b` (no min/max reorder — the order follows the picked corners directly,
    /// matching LibreCAD's RS_ActionDrawRectangle corner construction).
    static func corners(_ a: Vector, _ b: Vector) -> [Vector] {
        let x0 = a.x, y0 = a.y
        let x1 = b.x, y1 = b.y
        return [
            Vector(x0, y0),
            Vector(x1, y0),
            Vector(x1, y1),
            Vector(x0, y1),
        ]
    }

    /// Whether the two opposite corners span a degenerate (zero-area) rectangle:
    /// the two corners coincide in x or in y (so the rect collapses to a line or a
    /// point). Uses the engine distance tolerance, like LineTool's zero-length
    /// check.
    static func isDegenerate(_ a: Vector, _ b: Vector) -> Bool {
        abs(a.x - b.x) <= Tolerance.distance || abs(a.y - b.y) <= Tolerance.distance
    }

    // MARK: - Corner-treatment geometry (rounded / chamfer variants)

    /// The DXF bulge of a quarter-circle (90°) corner arc: `tan(90° / 4)`. A corner
    /// of an axis-aligned rectangle turns exactly 90°, so a rounded corner is a
    /// quarter circle whose bulge magnitude is this constant. The sign is chosen
    /// per-corner from the winding so the arc always bulges OUTWARD (convex).
    static let quarterBulge = tan(Double.pi / 8)   // ≈ 0.41421356

    /// Builds the closed-polyline VERTICES for the rectangle spanned by opposite
    /// corners `a`/`b`, applying the `corner` treatment:
    ///   - `.square`  → the 4 sharp corners, all bulges 0 (UNCHANGED original).
    ///   - `.rounded` → 8 vertices: each corner becomes two tangent points; the
    ///                  FIRST of the pair carries the quarter-circle bulge to the
    ///                  second (a convex arc), the rest bulge 0.
    ///   - `.chamfer` → 8 vertices: each corner becomes two tangent points joined by
    ///                  a straight bevel; all bulges 0.
    /// A non-positive or too-large cut clamps back to `.square` (so a stray config
    /// never collapses the rectangle). The corner order follows the picked corners
    /// (same winding as `corners`), so the bulge sign is derived per-corner.
    static func vertices(_ a: Vector, _ b: Vector, corner: RectangleCorner) -> [PolylineVertex] {
        let base = corners(a, b)
        switch corner {
        case .square:
            return base.map { PolylineVertex(point: $0, bulge: 0) }
        case .rounded(let radius):
            guard let cut = clampedCut(radius, a, b) else {
                return base.map { PolylineVertex(point: $0, bulge: 0) }
            }
            return cornerVertices(base, cut: cut, rounded: true)
        case .chamfer(let distance):
            guard let cut = clampedCut(distance, a, b) else {
                return base.map { PolylineVertex(point: $0, bulge: 0) }
            }
            return cornerVertices(base, cut: cut, rounded: false)
        }
    }

    /// Validates a requested corner cut (radius / chamfer distance) against the
    /// rectangle spanned by `a`/`b`: it must be positive and no larger than HALF the
    /// shorter side (so opposite corners' cuts never overlap). Returns the usable
    /// cut, or `nil` to fall back to square corners.
    static func clampedCut(_ cut: Double, _ a: Vector, _ b: Vector) -> Double? {
        guard cut > Tolerance.distance else { return nil }
        let w = abs(b.x - a.x), h = abs(b.y - a.y)
        let maxCut = Swift.min(w, h) / 2
        guard cut <= maxCut + Tolerance.distance else { return nil }
        return Swift.min(cut, maxCut)
    }

    /// Replaces each sharp corner of `base` (in order) with two tangent points cut
    /// back by `cut` along the incoming/outgoing edges. When `rounded`, the first
    /// tangent point of each corner carries the per-corner convex bulge to the
    /// second; otherwise all bulges are 0 (a straight chamfer). Produces
    /// `2 * base.count` vertices (8 for a rectangle).
    static func cornerVertices(_ base: [Vector], cut: Double, rounded: Bool) -> [PolylineVertex] {
        let n = base.count
        var out: [PolylineVertex] = []
        out.reserveCapacity(n * 2)
        for i in 0..<n {
            let prev = base[(i + n - 1) % n]
            let curr = base[i]
            let next = base[(i + 1) % n]
            let dIn = unit(curr - prev)
            let dOut = unit(next - curr)
            let t1 = curr - dIn * cut          // back along the incoming edge
            let t2 = curr + dOut * cut         // forward along the outgoing edge
            if rounded {
                // Convex quarter-circle: bulge LEFT for CW turns, RIGHT for CCW
                // turns, so the arc always bows toward the original corner (outward).
                let cross = dIn.x * dOut.y - dIn.y * dOut.x   // >0 ⇒ CCW (left) turn
                let bulge = -copysign(quarterBulge, cross)
                out.append(PolylineVertex(point: t1, bulge: bulge))
                out.append(PolylineVertex(point: t2, bulge: 0))
            } else {
                out.append(PolylineVertex(point: t1, bulge: 0))
                out.append(PolylineVertex(point: t2, bulge: 0))
            }
        }
        return out
    }

    /// A unit vector in the direction of `v` (zero-safe: returns `v` unchanged for a
    /// degenerate length, which only arises on an already-degenerate rectangle).
    private static func unit(_ v: Vector) -> Vector {
        let m = v.magnitude
        return m > Tolerance.distance ? v / m : v
    }

    /// The PREVIEW outline points for the rectangle spanned by `a`/`b` under the
    /// `corner` treatment. A `ResolvedPolyline` carries no bulge, so a rounded
    /// corner is tessellated into short chords here (a 9-sample quarter arc) so the
    /// rubber-band shows the curve; chamfer/square are the exact vertices.
    static func previewPoints(_ a: Vector, _ b: Vector, corner: RectangleCorner) -> [Vector] {
        let verts = vertices(a, b, corner: corner)
        // Fast path: no bulges ⇒ the points ARE the outline (square / chamfer).
        if verts.allSatisfy({ abs($0.bulge) < Tolerance.distance }) {
            return verts.map(\.point)
        }
        // Tessellate each bulged edge into a small chord run for the overlay.
        var pts: [Vector] = []
        let n = verts.count
        for i in 0..<n {
            let v = verts[i]
            let next = verts[(i + 1) % n].point
            pts.append(v.point)
            if abs(v.bulge) >= Tolerance.distance {
                pts.append(contentsOf: arcChords(from: v.point, to: next, bulge: v.bulge))
            }
        }
        return pts
    }

    /// Interior chord points of the bulge arc from `start` to `end` (the endpoints
    /// themselves are added by the caller), for the preview overlay only. 8 interior
    /// samples give a smooth quarter-circle rubber-band.
    private static func arcChords(from start: Vector, to end: Vector, bulge: Double) -> [Vector] {
        let included = 4 * atan(bulge)                 // signed sweep
        let chord = end - start
        let chordLen = chord.magnitude
        guard chordLen > Tolerance.distance else { return [] }
        let radius = abs(chordLen / (2 * sin(included / 2)))
        let mid = (start + end) * 0.5
        let half = chordLen / 2
        let apothem = (Swift.max(0, radius * radius - half * half)).squareRoot()
        let dir = chord / chordLen
        let leftNormal = Vector(-dir.y, dir.x)
        let apexSide = bulge >= 0 ? 1.0 : -1.0
        let centerSign = -copysign(1.0, cos(included / 2))
        let center = mid + leftNormal * (apexSide * centerSign * apothem)
        let startA = (start - center).angle
        let samples = 8
        var pts: [Vector] = []
        pts.reserveCapacity(samples)
        for s in 1...samples {
            let t = Double(s) / Double(samples + 1)
            let ang = startA + (-included) * t
            pts.append(center + Vector.polar(radius: radius, angle: ang))
        }
        return pts
    }
}
