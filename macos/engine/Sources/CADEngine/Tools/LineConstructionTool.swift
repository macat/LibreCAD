//
//  LineConstructionTool.swift
//  CADEngine
//
//  The LINE CONSTRUCTION tool — LibreCAD's family of "draw a line by a geometric
//  CONSTRAINT against existing geometry" actions, distilled into one tool with an
//  internal `mode`. Each mode picks one or two existing entities (a line and/or a
//  circle/arc, plus sometimes a point) and emits a single plain `.line` via `.add`.
//  No new `EntityKind` — every result is an ordinary `.line`, exactly like
//  `RevisionCloudTool` reuses `.polyline`.
//
//  The modes, and the LibreCAD action each mirrors:
//    • .perpendicularFoot — `RS_ActionDrawLineOrthogonal` / perpendicular: pick a
//      LINE, then a POINT; emit the segment POINT → (foot of the perpendicular
//      dropped from POINT onto the picked line's infinite carrier).
//    • .parallelThrough  — `RS_ActionDrawLineParallelThrough`: pick a LINE, then a
//      POINT; emit a segment PARALLEL to the picked line, THROUGH the point, with
//      the same length as the picked line (centered on the through point).
//    • .angleBisector    — `RS_ActionDrawLineBisector`: pick two LINES; emit the
//      bisector of the wedge the two picks selected, a segment from the lines'
//      corner along the bisector direction (length = the shorter picked line).
//    • .tangent1 / .tangent2 — `RS_ActionDrawLineTangent1` (point→circle tangent):
//      pick a CIRCLE/ARC, then a POINT outside it; there are TWO tangent lines, so
//      `.tangent1` emits the first solution and `.tangent2` the second (segment
//      POINT → tangent point on the circle).
//    • .orthTangent      — `RS_ActionDrawLineTangent2` flavor / tangent ⟂ a line:
//      pick a reference LINE, then a CIRCLE/ARC; emit the tangent to the circle
//      whose tangent LINE is PERPENDICULAR to the reference line (the tangent point
//      is where the radius is PARALLEL to the reference line — two such points; the
//      one nearer the reference line is used). Segment = tangent point ± radius
//      along the perpendicular-to-radius direction (a chord-length the radius).
//
//  Interaction (two picks per result, then RESET for the next):
//    - `.click(p)` → pick the entity / point for the current step (see each mode).
//                    The first pick selects an entity via `context.nearbyEntities`
//                    (the FilletTool entity-pick pattern); the second pick is either
//                    a free POINT (perpendicular/parallel/tangent) or a second ENTITY
//                    (bisector/orth-tangent). On the second pick the line is computed
//                    and committed (one `.add(.line)`), then the tool resets.
//    - `.move(p)`  → track the cursor; in the second step show a rubber-band PREVIEW
//                    of the line that WOULD result.
//    - `.value(p)` → a typed coordinate is treated like `.click(p)` for the POINT
//                    steps (perpendicular/parallel/tangent point); ignored where the
//                    step needs an ENTITY pick (a coordinate can't name a line/circle).
//    - `.cancel`/`.commit` → end the run; `.backspace` steps back one pick.
//
//  Degenerate / no-solution picks (parallel lines for the bisector, a point inside
//  the circle for a tangent, a perpendicular foot on a zero-length line, a circle
//  with no radius-parallel tangent) commit NOTHING.
//
//  UNWIRED: this tool is built without a `ToolKind` activation arm beyond the single
//  `.lineConstruction` registration; the UI MODE-PICKER (choosing which construction
//  variant) is a later wire-wave. `mode` defaults to `.perpendicularFoot`.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing/Quadtree/GUI. It
//  reads only the read-only `ToolContext` boundary hook (`nearbyEntities`) plus the
//  snapped world points in `ToolInput`, and computes every line through the shared
//  `SnapGeometry` kernels + vector math. The app re-mints the line's id on commit.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawLine* construction
//  actions and the RS_Creation perpendicular / parallel / bisector / tangent math).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Line Construction tool: draw a plain `.line` constrained against
/// existing geometry (perpendicular foot, parallel-through, angle bisector, tangent,
/// orth-tangent). `mode` selects the variant (the UI mode-picker wires in a later
/// wave); each mode emits ONE `.add(.line)` on its second pick, then resets.
public struct LineConstructionTool: Tool {

    // MARK: - Construction modes

    /// Which constrained line this tool draws. The UI mode-picker (a later wave)
    /// sets this; the tool defaults to `.perpendicularFoot`.
    public enum Mode: String, Sendable, Equatable, CaseIterable {
        /// Pick a LINE, then a POINT → segment from the point to the perpendicular
        /// foot on the line's carrier (LibreCAD perpendicular / orthogonal line).
        case perpendicularFoot
        /// Pick a LINE, then a POINT → segment PARALLEL to the line, through the
        /// point (LibreCAD parallel-through), same length as the picked line.
        case parallelThrough
        /// Pick two LINES → the bisector of the picked wedge (LibreCAD bisector).
        case angleBisector
        /// Pick a CIRCLE/ARC, then a POINT → the FIRST point→circle tangent line.
        case tangent1
        /// Pick a CIRCLE/ARC, then a POINT → the SECOND point→circle tangent line.
        case tangent2
        /// Pick a reference LINE, then a CIRCLE/ARC → the tangent to the circle that
        /// is PERPENDICULAR to the reference line.
        case orthTangent
    }

    /// The active construction variant. Internal config (no UI wiring yet). It is
    /// read LIVE on every `handle`/`status`/`preview` — the private `State` is
    /// mode-agnostic (always starts at `.pickingFirst`), so NOTHING is seeded from
    /// `mode` at construction. The app's mode-picker (a later wave) doesn't mutate this
    /// in place: `applyToolConfig` RE-MINTS the tool via `init(mode:)` with the chosen
    /// variant (the DivideTool/ArcTool re-mint pattern). `var` only because the
    /// `init(mode:)` convenience assigns it.
    public var mode: Mode = .perpendicularFoot

    // MARK: - Private state machine

    /// The tool's lifecycle. The FIRST pick always selects an entity (a line, or a
    /// circle/arc for the tangent modes); the SECOND pick is either a free point or
    /// a second entity, depending on the mode.
    private enum State: Equatable {
        /// Waiting for the FIRST pick (a reference entity under the click).
        case pickingFirst
        /// First entity fixed; waiting for the SECOND pick (a point or a second
        /// entity). `first` is the chosen first record; `firstPick` is the click
        /// point on it (selects the ray for the bisector / the near side otherwise).
        case pickingSecond(first: EntityRecord, firstPick: Vector)
    }

    private var state: State = .pickingFirst

    /// The last cursor seen via `.move`, used to drive the second-step preview.
    private var cursor: Vector = .invalid

    public init() {}

    public init(mode: Mode) {
        self.mode = mode
    }

    // MARK: - Tool

    public var title: String { "Line Construction" }

    public var status: String {
        switch state {
        case .pickingFirst:
            switch mode {
            case .perpendicularFoot, .parallelThrough: return "Select reference line"
            case .angleBisector:                       return "Select first line"
            case .tangent1, .tangent2:                 return "Select circle or arc"
            case .orthTangent:                         return "Select reference line"
            }
        case .pickingSecond:
            switch mode {
            case .perpendicularFoot: return "Specify point for the perpendicular"
            case .parallelThrough:   return "Specify point the parallel passes through"
            case .angleBisector:     return "Select second line"
            case .tangent1, .tangent2: return "Specify point to draw the tangent from"
            case .orthTangent:       return "Select circle or arc"
            }
        }
    }

    /// The live preview of the line that WOULD result for the current cursor (in the
    /// second step), with the preview pen. Empty when no valid line would result.
    public var preview: [ResolvedPolyline] {
        guard case .pickingSecond = state, cursor.valid,
              let line = previewLine else { return [] }
        return EntityKind.line(line).resolve(pen: .toolPreview, ctx: .default).polylines
    }

    /// The line computed for the last `.move` cursor (cached because `preview` has
    /// no `ToolContext`). Nil when nothing would result.
    private var previewLine: LineData?

    /// A construction EDITING tool: it reads the boundary hook (`nearbyEntities`) on
    /// each entity-pick and emits ONE `.add(.line)` on the second pick.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            previewLine = computeFor(secondPick: p, context: context)
            return previewLine == nil ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context, typed: false)

        case .value(let p):
            // A typed coordinate stands in for a POINT pick (perpendicular / parallel
            // / tangent point). For the ENTITY-pick steps a coordinate can't name a
            // line/circle, so it is ignored there (handled inside handleClick).
            return handleClick(p, context: context, typed: true)

        case .backspace:
            return handleBackspace()

        case .cancel:
            reset()
            return .finished

        case .commit:
            // Each result commits on its second pick — nothing is pending here.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext, typed: Bool) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .pickingFirst:
            // A typed coordinate can't name the FIRST (always an entity) pick.
            if typed { return .none }
            guard let first = pickFirst(at: p, context: context) else { return .none }
            state = .pickingSecond(first: first, firstPick: p)
            cursor = p
            previewLine = nil
            return .none

        case .pickingSecond:
            // The second step's pick kind depends on the mode. For ENTITY second
            // picks (bisector / orth-tangent) a typed coordinate is ignored.
            if typed && secondPickIsEntity {
                return .none
            }
            guard let line = computeFor(secondPick: p, context: context) else { return .none }
            let record = EntityRecord(id: .placeholder, kind: .line(line))
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingFirst:
            return .none
        case .pickingSecond:
            reset()
            return .preview
        }
    }

    private mutating func reset() {
        state = .pickingFirst
        cursor = .invalid
        previewLine = nil
    }

    /// Whether the SECOND pick selects an ENTITY (bisector second line / orth-tangent
    /// circle) rather than a free point — drives typed-coordinate handling.
    private var secondPickIsEntity: Bool {
        switch mode {
        case .angleBisector, .orthTangent: return true
        case .perpendicularFoot, .parallelThrough, .tangent1, .tangent2: return false
        }
    }

    // MARK: - First-pick selection (per mode)

    /// The FIRST entity for the current mode: a LINE for perpendicular / parallel /
    /// bisector / orth-tangent, a CIRCLE/ARC for the tangent modes. Nil when nothing
    /// of the required kind is under the pick.
    private func pickFirst(at p: Vector, context: ToolContext) -> EntityRecord? {
        switch mode {
        case .perpendicularFoot, .parallelThrough, .angleBisector, .orthTangent:
            return Self.nearestLine(at: p, exclude: nil, context: context)
        case .tangent1, .tangent2:
            return Self.nearestCircular(at: p, exclude: nil, context: context)
        }
    }

    // MARK: - Line computation (pure; per mode)

    /// Computes the constructed line for a candidate SECOND pick `p`, given the first
    /// entity fixed in the `.pickingSecond` state. Nil for any degenerate / no-solution
    /// case (so a no-op commits nothing and the preview stays empty).
    private func computeFor(secondPick p: Vector, context: ToolContext) -> LineData? {
        guard case .pickingSecond(let first, let firstPick) = state, p.valid else { return nil }
        switch mode {
        case .perpendicularFoot:
            guard case .line(let l) = first.kind else { return nil }
            return Self.perpendicularFootLine(line: l, point: p)
        case .parallelThrough:
            guard case .line(let l) = first.kind else { return nil }
            return Self.parallelThroughLine(line: l, point: p)
        case .angleBisector:
            guard case .line(let a) = first.kind,
                  let second = Self.nearestLine(at: p, exclude: first.id, context: context),
                  case .line(let b) = second.kind else { return nil }
            return Self.bisectorLine(lineA: a, ref1: firstPick, lineB: b, ref2: p)
        case .tangent1, .tangent2:
            guard let (center, radius) = Self.circleParams(first) else { return nil }
            return Self.tangentLine(center: center, radius: radius, point: p,
                                    solution: mode == .tangent1 ? 0 : 1)
        case .orthTangent:
            guard case .line(let ref) = first.kind,
                  let second = Self.nearestCircular(at: p, exclude: first.id, context: context),
                  let (center, radius) = Self.circleParams(second) else { return nil }
            return Self.orthTangentLine(refLine: ref, center: center, radius: radius, near: p)
        }
    }

    // MARK: - Per-mode geometry kernels (pure, self-contained)

    /// Perpendicular foot: segment from `point` to the foot of the perpendicular
    /// dropped onto the line's INFINITE carrier. Nil for a degenerate line or when
    /// the point already lies on the line (zero-length result).
    static func perpendicularFootLine(line: LineData, point: Vector) -> LineData? {
        let foot = SnapGeometry.perpendicularFootOnLine(from: point, a: line.start, b: line.end)
        guard foot.valid, (foot - point).magnitude > Tolerance.distance else { return nil }
        return LineData(start: point, end: foot)
    }

    /// Parallel-through: a segment PARALLEL to `line`, centered on `point`, the same
    /// length as the picked line. Nil for a degenerate (zero-length) line.
    static func parallelThroughLine(line: LineData, point: Vector) -> LineData? {
        let dir = line.end - line.start
        let len = dir.magnitude
        guard len > Tolerance.distance else { return nil }
        let half = dir * 0.5
        return LineData(start: point - half, end: point + half)
    }

    /// Angle bisector: a segment from the two lines' corner along the bisector of the
    /// picked wedge (selected by `ref1` on line A and `ref2` on line B). Its length
    /// is the SHORTER of the two picked lines (a finite, sensible construction span).
    /// Nil for parallel lines (no corner) or anti-parallel rays (no bisector).
    static func bisectorLine(lineA: LineData, ref1: Vector, lineB: LineData, ref2: Vector) -> LineData? {
        guard let corner = SnapGeometry.bisectorCorner(a0: lineA.start, a1: lineA.end,
                                                        b0: lineB.start, b1: lineB.end) else { return nil }
        let dir = SnapGeometry.angleBisectorDirection(a0: lineA.start, a1: lineA.end, ref1: ref1,
                                                      b0: lineB.start, b1: lineB.end, ref2: ref2)
        guard dir.valid else { return nil }
        let lenA = (lineA.end - lineA.start).magnitude
        let lenB = (lineB.end - lineB.start).magnitude
        let span = Swift.min(lenA, lenB)
        guard span > Tolerance.distance else { return nil }
        return LineData(start: corner, end: corner + dir * span)
    }

    /// Point→circle tangent: the segment from `point` to the `solution`-th tangent
    /// point on the circle (0 or 1). Nil when the point is inside the circle (no
    /// tangent) or the requested solution doesn't exist.
    static func tangentLine(center: Vector, radius: Double, point: Vector, solution: Int) -> LineData? {
        let pts = SnapGeometry.tangentPointsOnCircle(from: point, center: center, radius: radius)
        guard solution >= 0, solution < pts.count else { return nil }
        let t = pts[solution]
        guard t.valid, (t - point).magnitude > Tolerance.distance else { return nil }
        return LineData(start: point, end: t)
    }

    /// Tangent ⟂ a reference line: the tangent to the circle whose tangent LINE is
    /// PERPENDICULAR to `refLine`. A tangent line is perpendicular to its radius, so
    /// a tangent line perpendicular to `refLine` touches where the RADIUS is PARALLEL
    /// to `refLine` — two such points (center ± radius·û along `refLine`'s direction).
    /// The point nearer the `near` pick is chosen; the emitted segment is a chord-
    /// length span (= 2·radius, the circle's diameter) centered on the tangent point,
    /// running PERPENDICULAR to the radius (i.e. parallel to nothing — perpendicular
    /// to `refLine`). Nil for a degenerate reference line or zero radius.
    static func orthTangentLine(refLine: LineData, center: Vector, radius: Double, near: Vector) -> LineData? {
        let refDir = refLine.end - refLine.start
        let len = refDir.magnitude
        let r = abs(radius)
        guard len > Tolerance.distance, r > Tolerance.distance else { return nil }
        let u = refDir * (1.0 / len)              // unit reference direction
        // Two tangent points: where the radius is parallel to the reference line.
        let t0 = center + u * r
        let t1 = center - u * r
        let tangent = near.distance(to: t0) <= near.distance(to: t1) ? t0 : t1
        // The tangent line is perpendicular to the radius (= perpendicular to û):
        // a span of one diameter centered on the tangent point along that normal.
        let normal = Vector(-u.y, u.x)
        let half = normal * r
        return LineData(start: tangent - half, end: tangent + half)
    }

    // MARK: - Entity picking (mirrors FilletTool.nearestLine)

    /// The nearest LINE within the pick aperture of `p`, optionally excluding one id.
    static func nearestLine(at p: Vector, exclude: EntityID?, context: ToolContext) -> EntityRecord? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) where e.id != exclude {
            guard case .line = e.kind else { continue }
            let d = HitTesting.worldDistance(from: p, to: e)
            if d < bestDist { bestDist = d; best = e }
        }
        return best
    }

    /// The nearest CIRCLE or ARC within the pick aperture of `p`, optionally
    /// excluding one id (so a second pick can't re-pick the first).
    static func nearestCircular(at p: Vector, exclude: EntityID?, context: ToolContext) -> EntityRecord? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) where e.id != exclude {
            switch e.kind {
            case .circle, .arc:
                let d = HitTesting.worldDistance(from: p, to: e)
                if d < bestDist { bestDist = d; best = e }
            default:
                continue
            }
        }
        return best
    }

    /// (center, radius) for a `.circle` or `.arc` record, or nil for anything else.
    static func circleParams(_ rec: EntityRecord) -> (center: Vector, radius: Double)? {
        switch rec.kind {
        case .circle(let c): return (c.center, c.radius)
        case .arc(let a):    return (a.center, a.radius)
        default:             return nil
        }
    }

    /// The pick tolerance aperture in world units (mirrors `FilletTool.pickTolerance`).
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance { return g * 0.5 }
        return 0.5
    }
}
