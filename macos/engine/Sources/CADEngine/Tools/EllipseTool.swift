//
//  EllipseTool.swift
//  CADEngine
//
//  The center + major-axis-endpoint + minor-point Ellipse draw tool — a concrete
//  `Tool` built to the same template as `CircleTool` / `ArcTool` (private `enum
//  State`, pure value type, no CADDrawing/Quadtree/GUI access). Ported in spirit
//  from LibreCAD's `RS_ActionDrawEllipseAxis`
//  (librecad/src/lib/actions/drawing/draw/ellipse/), with the magic `int
//  m_status` replaced by an exhaustive private `enum State` carrying the picks
//  made so far, and the post-commit re-arm behavior preserved.
//
//  Behavior (center → first axis endpoint → minor-axis distance, FULL ellipse):
//    - click #1 → fix the CENTER (State.settingCenter → .settingMajor).
//                 status: "Specify first axis endpoint".
//    - click #2 → fix the MAJOR-axis endpoint relative to the center:
//                 majorP = (p − center) (State.settingMajor → .settingRatio).
//                 status: "Specify minor axis distance".
//    - `.move` (in .settingRatio) → rubber-band a FULL tessellated ellipse whose
//                 minor/major ratio is the cursor's perpendicular distance to the
//                 major-axis LINE divided by |majorP|, clamped to (0, 1], drawn as
//                 a CLOSED `ResolvedPolyline` (reuses `Tessellation.ellipsePoints`).
//    - click #3 → ratio from that click's perpendicular distance; commit ONE
//                 `.ellipse(EllipseData(center, majorP, ratio, startAngle: 0,
//                 endAngle: 0, reversed: false))` — a WHOLE ellipse (the
//                 `startAngle == endAngle == 0` LibreCAD convention, see
//                 `EllipseData.isArc`) — then RESET to await a new center.
//    - `.backspace` → step back one pick (ratio-pick state → major-pick state →
//                 initial), no commit.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) when idle → end the tool; `.finished` (each ellipse was
//                 already committed on its third click).
//    - A degenerate pick (zero major axis, or ratio ≈ 0 i.e. the minor point on
//                 the major-axis line) is IGNORED.
//
//  FULL-ELLIPSE CONVENTION: the committed `EllipseData` carries
//  `startAngle == endAngle == 0`, which `EllipseData.isArc` (and therefore
//  `Tessellation.ellipsePoints`) treats as a WHOLE ellipse — a closed ring of
//  points. The preview tessellates the same way (closed), so what you see while
//  dragging is exactly what gets committed.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit and
//  IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawEllipseAxis).
//

import Foundation

/// The interactive Ellipse tool (center → major-axis endpoint → minor distance).
/// Click the center, then a point that fixes the major axis (its endpoint
/// relative to the center), then drag and click to set the minor/major ratio
/// from the cursor's perpendicular distance to the major-axis line. Commits one
/// FULL ellipse and re-arms for the next (LibreCAD behavior).
public struct EllipseTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawEllipseAxis`'s status
    /// integers to an exhaustive `enum`. Each case carries the picks made so far.
    private enum State: Equatable {
        /// Waiting for the center (no pick yet).
        case settingCenter
        /// Center fixed; waiting for the first axis endpoint (which fixes the
        /// major axis: `majorP = pick − center`). `center` is the fixed center.
        case settingMajor(center: Vector)
        /// Center and major axis fixed; waiting for the minor-axis distance. The
        /// minor/major ratio is the cursor's perpendicular distance to the
        /// major-axis line divided by |majorP|.
        case settingRatio(center: Vector, majorP: Vector)
    }

    /// The current state. Starts waiting for the center.
    private var state: State = .settingCenter

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Ellipse" }

    public var status: String {
        switch state {
        case .settingCenter: return "Specify center point"
        case .settingMajor:  return "Specify first axis endpoint"
        case .settingRatio:  return "Specify minor axis distance"
        }
    }

    /// The live rubber-band: a FULL tessellated ellipse (center, majorP, ratio)
    /// returned as a CLOSED `ResolvedPolyline`, where `ratio` is the cursor's
    /// perpendicular distance to the major-axis line over |majorP|, clamped to
    /// (0, 1]. Empty until the major axis is fixed and the cursor has produced a
    /// non-degenerate ratio.
    public var preview: [ResolvedPolyline] {
        guard case .settingRatio(let center, let majorP) = state,
              cursor.valid, center.valid, majorP.valid else {
            return []
        }
        guard let ratio = Self.ratio(center: center, majorP: majorP, point: cursor) else {
            return []
        }
        let data = EllipseData(
            center: center, majorP: majorP, ratio: ratio,
            startAngle: 0, endAngle: 0, reversed: false
        )
        let (pts, closed) = Tessellation.ellipsePoints(
            data, tolerance: ResolveContext.default.tessellationTolerance
        )
        guard pts.count >= 3 else { return [] }
        return [ResolvedPolyline(points: pts, closed: closed, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the major axis is fixed.
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — end the tool. Each ellipse was already committed on its
            // third click, so there is nothing pending to add here.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingCenter:
            // First point fixes the center; now wait for the first axis endpoint.
            state = .settingMajor(center: p)
            cursor = p
            return .none

        case .settingMajor(let center):
            // Second point fixes the major axis: majorP = (p − center), relative
            // to the center. Ignore a degenerate (zero-length) major axis.
            guard center.valid, p.valid else { return .none }
            let majorP = p - center
            guard majorP.magnitude > Tolerance.distance else { return .none }
            state = .settingRatio(center: center, majorP: majorP)
            cursor = p
            return .none

        case .settingRatio(let center, let majorP):
            // Third point fixes the minor/major ratio; commit the FULL ellipse,
            // then reset. Ignore a degenerate (ratio ≈ 0) pick — the minor point
            // lying on the major-axis line gives a zero minor radius.
            guard center.valid, p.valid else { return .none }
            guard let ratio = Self.ratio(center: center, majorP: majorP, point: p) else {
                return .none
            }
            let record = EntityRecord(
                id: .placeholder,
                kind: .ellipse(EllipseData(
                    center: center, majorP: majorP, ratio: ratio,
                    startAngle: 0, endAngle: 0, reversed: false
                ))
            )
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Nothing to step back.
            return .none

        case .settingMajor:
            // Undo the center pick → back to the initial state.
            reset()
            return .preview

        case .settingRatio(let center, _):
            // Undo the major-axis pick → back to waiting for the first axis
            // endpoint, keeping the fixed center.
            state = .settingMajor(center: center)
            cursor = center
            return .preview
        }
    }

    /// Returns to the initial waiting-for-center state.
    private mutating func reset() {
        state = .settingCenter
        cursor = .invalid
    }

    // MARK: - Ratio from the minor point

    /// The minor/major ratio implied by `point`: its perpendicular distance to
    /// the major-axis LINE (through `center`, direction `majorP`) divided by the
    /// major radius |majorP|, clamped to (0, 1]. Returns `nil` when the major
    /// axis is degenerate or the resulting ratio is ≈ 0 (point on the major-axis
    /// line) — the caller treats that as "ignore this pick".
    private static func ratio(center: Vector, majorP: Vector, point: Vector) -> Double? {
        let majorLen = majorP.magnitude
        guard majorLen > Tolerance.distance else { return nil }
        // Perpendicular distance from `point` to the line through `center` along
        // `majorP`: |(point − center) × majorP| / |majorP| (2D cross magnitude).
        let d = point - center
        let cross = abs(d.x * majorP.y - d.y * majorP.x)
        let perp = cross / majorLen
        let raw = perp / majorLen
        guard raw > Tolerance.distance else { return nil }
        // A minor radius never exceeds the major radius (ratio ≤ 1).
        return Swift.min(raw, 1.0)
    }
}
