//
//  CircleTool.swift
//  CADEngine
//
//  The center+radius Circle draw tool — a concrete `Tool` built to the same
//  template as `LineTool`. Ported from LibreCAD's `RS_ActionDrawCircle`
//  (librecad/src/lib/actions/drawing/draw/lc_actiondrawcircle.cpp, the
//  center-then-radius variant), with the magic `int m_status` replaced by a
//  private `enum State` and the post-commit re-arm behavior (stay active for the
//  next circle) preserved.
//
//  Behavior:
//    - first `.click`  → set the center (State.settingCenter → .settingRadius).
//    - `.move`         → rubber-band preview: a tessellated circle centered on the
//                        fixed center with radius = |cursor − center|.
//    - next `.click`   → commit ONE `.circle(CircleData)` (center, radius =
//                        |clicked − center|), then RESET to .settingCenter so the
//                        tool is ready to draw the next circle. A degenerate
//                        zero-radius click is ignored (keeps waiting for radius).
//    - `.backspace`    → step the radius pick back to the initial state (no commit).
//    - `.cancel` (Esc) → discard the in-progress circle, reset to .settingCenter.
//    - `.commit` (Ret) → when idle, end the tool's run; `.finished`.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit, and
//  it IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawCircle).
//

import Foundation

/// The interactive center+radius Circle tool. Click the center, then click (or
/// move to preview) a point on the circle to set the radius; it commits one
/// circle and re-arms for the next (LibreCAD behavior).
public struct CircleTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawCircle`'s status integers
    /// (SetCenter / SetRadius) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the center point (nothing fixed yet).
        case settingCenter
        /// Center fixed; waiting for a point on the circle that sets the radius.
        case settingRadius(center: Vector)
    }

    /// The current state. Starts waiting for the center.
    private var state: State = .settingCenter

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Circle" }

    public var status: String {
        switch state {
        case .settingCenter: return "Specify center point"
        case .settingRadius: return "Specify radius"
        }
    }

    /// The live rubber-band: a tessellated circle centered on the fixed center
    /// with radius = distance from the center to the current cursor, returned as a
    /// CLOSED `ResolvedPolyline`. Empty before the center is set, before the cursor
    /// has moved, or while the radius is still degenerate (zero).
    public var preview: [ResolvedPolyline] {
        guard case .settingRadius(let center) = state, cursor.valid, center.valid else {
            return []
        }
        let radius = (cursor - center).magnitude
        guard radius > Tolerance.distance else { return [] }
        let pts = Tessellation.circlePoints(
            center: center, radius: radius, tolerance: ResolveContext.default.tessellationTolerance
        )
        return [ResolvedPolyline(points: pts, closed: true, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the center is fixed.
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the in-progress circle and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — when idle there is nothing pending, so end the run. (Each
            // circle is committed on its second click; there is never pending
            // geometry to flush here.)
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Center fixed; now rubber-band the radius toward the next click.
            state = .settingRadius(center: p)
            cursor = p
            return .none

        case .settingRadius(let center):
            // Commit one circle (center, radius = |p − center|), then re-arm.
            guard center.valid, p.valid else { return .none }
            let radius = (p - center).magnitude
            guard radius > Tolerance.distance else {
                // Degenerate (zero-radius) pick — ignore it, keep waiting.
                return .none
            }
            let record = EntityRecord(
                id: .placeholder,
                kind: .circle(CircleData(center: center, radius: radius))
            )
            // Re-arm for the next circle (stay active).
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Nothing to step back.
            return .none
        case .settingRadius:
            // Step the radius pick back to before the center was fixed.
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting-for-center state.
    private mutating func reset() {
        state = .settingCenter
        cursor = .invalid
    }
}
