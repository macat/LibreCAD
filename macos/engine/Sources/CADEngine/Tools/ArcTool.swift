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

/// The interactive Arc tool (center → start → end, counter-clockwise). Click the
/// center, then the start point (fixing the radius and start angle), then drag and
/// click the end angle to commit a CCW arc. After committing it resets to await a
/// new center.
public struct ArcTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawArc`'s status integers to
    /// an exhaustive `enum`. Each case carries the picks made so far.
    private enum State: Equatable {
        /// Waiting for the center (no pick yet).
        case settingCenter
        /// Center fixed; waiting for the start point (which fixes radius + start
        /// angle). `center` is the fixed center.
        case settingStart(center: Vector)
        /// Center, radius and start angle fixed; waiting for the end angle. The arc
        /// sweeps CCW from `startAngle` to the angle of (center → end click).
        case settingEnd(center: Vector, radius: Double, startAngle: Double)
    }

    /// The current state. Starts waiting for the center.
    private var state: State = .settingCenter

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Arc" }

    public var status: String {
        switch state {
        case .settingCenter: return "Specify center point"
        case .settingStart:  return "Specify start point"
        case .settingEnd:    return "Specify end angle"
        }
    }

    /// The live rubber-band: the tessellated arc sweeping CCW from `startAngle` to
    /// the current cursor's angle at `radius`. Empty until the start point is fixed
    /// and the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .settingEnd(let center, let radius, let startAngle) = state,
              cursor.valid, center.valid else {
            return []
        }
        let endAngle = (cursor - center).angle
        let pts = Tessellation.arcPoints(
            center: center, radius: radius,
            startAngle: startAngle, endAngle: endAngle, reversed: false,
            tolerance: ResolveContext.default.tessellationTolerance
        )
        return [ResolvedPolyline(points: pts, closed: false, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the start point is fixed.
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
        }
    }

    /// Returns to the initial waiting-for-center state.
    private mutating func reset() {
        state = .settingCenter
        cursor = .invalid
    }
}
