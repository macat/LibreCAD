//
//  ArcTool.swift
//  CADEngine
//
//  The center-start-end Arc draw tool — a second concrete `Tool`, built against
//  the FROZEN `Tool` contract and mirroring `LineTool` exactly (private `enum
//  State`, pure value type, no CADDrawing/Quadtree/GUI access). Ported in spirit
//  from LibreCAD's `RS_ActionDrawArc` family
//  (librecad/src/lib/actions/drawing/draw/) but with the magic `int m_status`
//  replaced by an exhaustive private `enum State` carrying the picks made so far.
//
//  Behavior (center → start → end, CCW):
//    - click #1 → fix the CENTER (State.settingCenter → .settingStart).
//                 status: "Specify start point".
//    - click #2 → fix the START: radius = |start − center|, startAngle =
//                 angle(center → start) (State.settingStart → .settingEnd).
//                 status: "Specify end angle".
//    - `.move` (in .settingEnd) → rubber-band the arc from `startAngle`
//                 counter-clockwise to angle(center → cursor) at `radius`, as a
//                 tessellated `ResolvedPolyline` (reuses `Tessellation.arcPoints`).
//    - click #3 → endAngle = angle(center → cursor); commit ONE
//                 `.arc(ArcData(center, radius, startAngle, endAngle,
//                 reversed: false))` (CCW), then RESET to await a new center.
//    - `.backspace` → step back one pick (end-pick state → start-pick state →
//                 initial), no commit.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) when idle → end the tool; `.finished` (each arc was already
//                 committed on its third click).
//    - A degenerate pick (zero radius: start coincident with center) is IGNORED.
//
//  ANGLE CONVENTION: the arc always sweeps COUNTER-CLOCKWISE from `startAngle`
//  (center → start) to `endAngle` (center → end). That is exactly LibreCAD's
//  `reversed == false` arc (see `Tessellation.arcPoints` / `RS_ArcData`), so the
//  committed `ArcData` carries `reversed: false` and the preview tessellates with
//  `reversed: false`.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit and
//  IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawArc).
//

import Foundation

/// How the Arc tool collects its three picks — surfaced by the tool-options bar
/// (UX-plan U2). Mirrors LibreCAD's two common arc-construction actions.
public enum ArcCreationMode: Sendable, Hashable, CaseIterable {
    /// Center → start → end (CCW). The first click is the center, the second fixes
    /// the radius + start angle, the third the end angle (the original behavior).
    case centerStartEnd
    /// Three points ON the arc: start → a point the arc passes through → end. The
    /// arc is the unique circular arc through the three clicked points.
    case threePoint
    /// Tangential: the arc STARTS at a point, leaves it TANGENT to a picked
    /// direction (a second point defines the tangent ray from the start), and is
    /// the unique arc that then passes THROUGH a third (end) point. Mirrors
    /// LibreCAD's `RS_ActionDrawArcTangential` (an arc continuing tangentially from
    /// a chosen point/segment direction).
    case tangential
}

/// The interactive Arc tool. Two construction modes (see `ArcCreationMode`):
/// center→start→end (CCW, the default) or three points on the arc. After
/// committing it resets to await the next arc's first pick.
public struct ArcTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawArc`'s status integers to
    /// an exhaustive `enum`. Each case carries the picks made so far. The
    /// center→start→end cases drive the default mode; the `.three*` cases drive the
    /// three-point mode.
    private enum State: Equatable {
        /// Waiting for the center (no pick yet).
        case settingCenter
        /// Center fixed; waiting for the start point (which fixes radius + start
        /// angle). `center` is the fixed center.
        case settingStart(center: Vector)
        /// Center, radius and start angle fixed; waiting for the end angle. The arc
        /// sweeps CCW from `startAngle` to the angle of (center → end click).
        case settingEnd(center: Vector, radius: Double, startAngle: Double)

        /// Three-point mode: waiting for the first (start) point.
        case threeStart
        /// Three-point mode: the start point is fixed; waiting for a point the arc
        /// passes through.
        case threeMid(start: Vector)
        /// Three-point mode: start + mid fixed; waiting for the end point. The
        /// committed arc is the unique circle through the three picks.
        case threeEnd(start: Vector, mid: Vector)

        /// Tangential mode: waiting for the start point (where the arc begins).
        case tanStart
        /// Tangential mode: the start is fixed; waiting for a point that defines the
        /// TANGENT direction at the start (the arc leaves `start` along `dirPoint −
        /// start`).
        case tanDir(start: Vector)
        /// Tangential mode: start + tangent direction fixed; waiting for the end
        /// point the arc passes through. `tangent` is the tangent ray's direction at
        /// `start` (not necessarily unit length).
        case tanEnd(start: Vector, tangent: Vector)
    }

    /// The current state. Set in `init` from the `mode`.
    private var state: State

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The arc construction mode. Surfaced by the tool-options bar (UX-plan U2).
    /// Back-compatible: the default `.centerStartEnd` keeps the original flow.
    public let mode: ArcCreationMode

    /// Creates an Arc tool in the given construction mode (default the original
    /// center→start→end). The app's `applyToolConfig` mints the tool in the mode
    /// the options bar selected.
    public init(mode: ArcCreationMode = .centerStartEnd) {
        self.mode = mode
        self.state = Self.initialState(for: mode)
    }

    /// The initial waiting state for a construction mode.
    private static func initialState(for mode: ArcCreationMode) -> State {
        switch mode {
        case .centerStartEnd: return .settingCenter
        case .threePoint:     return .threeStart
        case .tangential:     return .tanStart
        }
    }

    // MARK: - Tool

    public var title: String { "Arc" }

    public var status: String {
        switch state {
        case .settingCenter: return "Specify center point"
        case .settingStart:  return "Specify start point"
        case .settingEnd:    return "Specify end angle"
        case .threeStart:    return "Specify start point"
        case .threeMid:      return "Specify point on arc"
        case .threeEnd:      return "Specify end point"
        case .tanStart:      return "Specify start point"
        case .tanDir:        return "Specify tangent direction"
        case .tanEnd:        return "Specify end point"
        }
    }

    /// The live rubber-band: the tessellated arc sweeping CCW from `startAngle` to
    /// the current cursor's angle at `radius`. Empty until the start point is fixed
    /// and the cursor has moved.
    public var preview: [ResolvedPolyline] {
        switch state {
        case .settingEnd(let center, let radius, let startAngle):
            guard cursor.valid, center.valid else { return [] }
            let endAngle = (cursor - center).angle
            let pts = Tessellation.arcPoints(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle, reversed: false,
                tolerance: ResolveContext.default.tessellationTolerance
            )
            return [ResolvedPolyline(points: pts, closed: false, pen: .toolPreview)]

        case .threeEnd(let start, let mid):
            // Rubber-band the arc through start → mid → cursor.
            guard cursor.valid, let arc = Self.arcThrough(start, mid, cursor) else { return [] }
            let pts = Tessellation.arcPoints(
                center: arc.center, radius: arc.radius,
                startAngle: arc.startAngle, endAngle: arc.endAngle, reversed: arc.reversed,
                tolerance: ResolveContext.default.tessellationTolerance
            )
            return [ResolvedPolyline(points: pts, closed: false, pen: .toolPreview)]

        case .tanEnd(let start, let tangent):
            // Rubber-band the tangential arc: starts at `start` along `tangent`,
            // through the cursor.
            guard cursor.valid, let arc = Self.arcTangent(start: start, tangent: tangent, end: cursor)
            else { return [] }
            let pts = Tessellation.arcPoints(
                center: arc.center, radius: arc.radius,
                startAngle: arc.startAngle, endAngle: arc.endAngle, reversed: arc.reversed,
                tolerance: ResolveContext.default.tessellationTolerance
            )
            return [ResolvedPolyline(points: pts, closed: false, pen: .toolPreview)]

        default:
            return []
        }
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the start point is fixed.
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
            // Return — end the tool. Each arc was already committed on its third
            // click, so there is nothing pending to add here.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingCenter:
            // First point fixes the center; now wait for the start point.
            state = .settingStart(center: p)
            cursor = p
            return .none

        case .settingStart(let center):
            // Second point fixes the radius + start angle. Ignore a degenerate
            // (zero-radius) pick — keep waiting for a valid start point.
            guard center.valid, p.valid else { return .none }
            let radius = (p - center).magnitude
            guard radius > Tolerance.distance else { return .none }
            let startAngle = (p - center).angle
            state = .settingEnd(center: center, radius: radius, startAngle: startAngle)
            cursor = p
            return .none

        case .settingEnd(let center, let radius, let startAngle):
            // Third point fixes the end angle; commit the CCW arc, then reset.
            guard center.valid, p.valid else { return .none }
            let endAngle = (p - center).angle
            let record = EntityRecord(
                id: .placeholder,
                kind: .arc(ArcData(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, reversed: false
                ))
            )
            reset()
            return .commit([.add(record)])

        // MARK: Three-point mode

        case .threeStart:
            guard p.valid else { return .none }
            state = .threeMid(start: p)
            cursor = p
            return .none

        case .threeMid(let start):
            // Need a mid point distinct from the start; a coincident pick is ignored.
            guard p.valid, (p - start).magnitude > Tolerance.distance else { return .none }
            state = .threeEnd(start: start, mid: p)
            cursor = p
            return .none

        case .threeEnd(let start, let mid):
            // Third pick closes the arc through the three points. Collinear / coincident
            // picks have no finite circle — ignore them and keep waiting for a valid end.
            guard let arc = Self.arcThrough(start, mid, p) else { return .none }
            let record = EntityRecord(id: .placeholder, kind: .arc(arc))
            reset()
            return .commit([.add(record)])

        // MARK: Tangential mode

        case .tanStart:
            guard p.valid else { return .none }
            state = .tanDir(start: p)
            cursor = p
            return .none

        case .tanDir(let start):
            // The second pick defines the tangent direction at the start; reject a
            // coincident pick (no direction).
            guard p.valid, (p - start).magnitude > Tolerance.distance else { return .none }
            state = .tanEnd(start: start, tangent: p - start)
            cursor = p
            return .none

        case .tanEnd(let start, let tangent):
            // Third pick fixes the end the arc passes through. A degenerate
            // configuration (end on the tangent line / coincident with start) has no
            // finite arc — ignore it and keep waiting for a valid end.
            guard let arc = Self.arcTangent(start: start, tangent: tangent, end: p) else { return .none }
            let record = EntityRecord(id: .placeholder, kind: .arc(arc))
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Nothing to step back.
            return .none

        case .settingStart:
            // Undo the center pick → back to the initial state.
            reset()
            return .preview

        case .settingEnd(let center, _, _):
            // Undo the start pick → back to waiting for the start point, keeping
            // the fixed center.
            state = .settingStart(center: center)
            cursor = center
            return .preview

        case .threeStart:
            // Nothing to step back.
            return .none

        case .threeMid:
            // Undo the start pick → back to the initial three-point state.
            reset()
            return .preview

        case .threeEnd(let start, _):
            // Undo the mid pick → back to waiting for the mid point, keeping start.
            state = .threeMid(start: start)
            cursor = start
            return .preview

        case .tanStart:
            // Nothing to step back.
            return .none

        case .tanDir:
            // Undo the start pick → back to the initial tangential state.
            reset()
            return .preview

        case .tanEnd(let start, _):
            // Undo the tangent-direction pick → back to waiting for it, keep start.
            state = .tanDir(start: start)
            cursor = start
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-pick state for the active `mode`.
    private mutating func reset() {
        state = Self.initialState(for: mode)
        cursor = .invalid
    }

    // MARK: - Three-point arc geometry (circumcircle through 3 points)

    /// The unique circular arc that passes through `a` → `b` → `c` in that order,
    /// or `nil` when the three points are collinear / coincident (no finite circle).
    /// The arc is oriented so the SWEEP from `a` to `c` passes through `b`: the
    /// returned `ArcData` carries `reversed` accordingly (CCW when `b` is on the CCW
    /// side, CW otherwise), matching how `Tessellation.arcPoints` walks the sweep.
    static func arcThrough(_ a: Vector, _ b: Vector, _ c: Vector) -> ArcData? {
        guard a.valid, b.valid, c.valid else { return nil }
        // Circumcenter via the perpendicular-bisector determinant. `d` is twice the
        // signed area of triangle abc; it is zero exactly when the points are
        // collinear (or two coincide), which has no finite circle.
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > Tolerance.distance else { return nil }
        let a2 = a.x * a.x + a.y * a.y
        let b2 = b.x * b.x + b.y * b.y
        let c2 = c.x * c.x + c.y * c.y
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        let center = Vector(ux, uy)
        let radius = (a - center).magnitude
        guard radius > Tolerance.distance else { return nil }
        let startAngle = (a - center).angle
        let endAngle = (c - center).angle
        // Orient the sweep so it passes through `b`. `d > 0` ⇔ a→b→c turns CCW, so a
        // CCW (reversed == false) sweep from start to end passes through the mid; a
        // CW turn needs reversed == true.
        let reversed = d < 0
        return ArcData(center: center, radius: radius,
                       startAngle: startAngle, endAngle: endAngle, reversed: reversed)
    }

    // MARK: - Tangential arc geometry

    /// The unique circular arc that BEGINS at `start`, leaves it TANGENT to
    /// direction `tangent` (the arc's velocity at the start is parallel to
    /// `tangent`), and passes THROUGH `end`.
    ///
    /// Construction: the center lies on the line through `start` perpendicular to
    /// `tangent` (the radius is ⟂ to the tangent at the point of tangency). Writing
    /// the center as `C = start + k·n̂` for the unit normal `n̂ ⟂ t̂`, the
    /// equal-radius constraint `|C − end| = |C − start| = |k|` solves for the signed
    /// offset `k = −|start − end|² / (2 (start − end)·n̂)`. The arc is then oriented
    /// so its tangent AT the start points along `tangent` (matching the picked ray).
    ///
    /// Returns `nil` for a degenerate configuration: `start`/`end`/`tangent`
    /// invalid, a zero-length `tangent`, `end` coincident with `start`, or `end`
    /// lying ON the tangent line through `start` (the perpendicular offset is zero,
    /// so there is no finite arc — the straight tangent itself).
    static func arcTangent(start: Vector, tangent: Vector, end: Vector) -> ArcData? {
        guard start.valid, tangent.valid, end.valid else { return nil }
        let tLen = tangent.magnitude
        guard tLen > Tolerance.distance else { return nil }
        // Unit tangent and a unit normal (rotate tangent +90°).
        let tHat = tangent / tLen
        let nHat = Vector(-tHat.y, tHat.x)
        let v = start - end                       // start relative to end
        guard v.magnitude > Tolerance.distance else { return nil }
        let denom = 2 * v.dot(nHat)
        // `end` on the tangent line through `start` ⇒ denom ≈ 0 ⇒ no finite arc.
        guard abs(denom) > Tolerance.distance else { return nil }
        let k = -v.squared / denom
        let radius = abs(k)
        guard radius > Tolerance.distance else { return nil }
        let center = start + nHat * k
        let startAngle = (start - center).angle
        let endAngle = (end - center).angle
        // Orient the sweep so the arc's tangent at the START points along `tangent`.
        // At a point P on a CCW (reversed == false) arc, the tangent (direction of
        // increasing angle) is the radius (P − center) rotated +90°. The arc is CCW
        // exactly when that CCW-tangent agrees with the picked direction.
        let radial = start - center
        let ccwTangent = Vector(-radial.y, radial.x)  // radius rotated +90°
        let reversed = ccwTangent.dot(tHat) < 0
        return ArcData(center: center, radius: radius,
                       startAngle: startAngle, endAngle: endAngle, reversed: reversed)
    }
}
