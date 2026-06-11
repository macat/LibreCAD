//
//  LineTool.swift
//  CADEngine
//
//  The reference draw tool — the first concrete `Tool` and the template the
//  fan-out copies. Ported from LibreCAD's `RS_ActionDrawLine`
//  (librecad/src/lib/actions/drawing/draw/lc_actiondrawline.cpp), with the magic
//  `int m_status` replaced by a private `enum State` and the chaining behavior
//  (each committed segment continues from the previous endpoint to form a
//  polyline-like run until commit/cancel) preserved.
//
//  Behavior:
//    - first `.click`  → set the start point (State.settingStart → .settingEnd).
//    - `.move`         → rubber-band preview from the last fixed point to the
//                        cursor (a 1-segment polyline).
//    - next `.click`   → commit ONE `.line(LineData)` from the last fixed point
//                        to the clicked point, then CONTINUE from that endpoint
//                        (the clicked point becomes the new fixed point).
//    - `.backspace`    → step back one fixed point (undo the last pick within the
//                        run, no commit). From a single start point it returns to
//                        the initial state.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) → end the run; `.finished` (nothing pending to add — each
//                        segment was already committed on its second click).
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawLine).
//

import Foundation

/// The interactive Line tool. Click two points to draw a line; it then chains
/// (LibreCAD behavior), continuing from the endpoint until `.commit`/`.cancel`.
public struct LineTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawLine`'s status integers
    /// (SetStartpoint = 0, SetEndpoint = 1) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the first point (no fixed point yet).
        case settingStart
        /// One or more points fixed; waiting for the next point. `last` is the
        /// point the next segment starts from (the running endpoint).
        case settingEnd(last: Vector)
    }

    /// The current state. Starts waiting for the first point.
    private var state: State = .settingStart

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Line" }

    public var status: String {
        switch state {
        case .settingStart: return "Specify first point"
        case .settingEnd:   return "Specify next point"
        }
    }

    /// The live rubber-band: a 1-segment polyline from the running fixed point to
    /// the current cursor. Empty before the first point is set, or before the
    /// cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .settingEnd(let last) = state, cursor.valid, last.valid else {
            return []
        }
        return [ResolvedPolyline(points: [last, cursor], closed: false, pen: .toolPreview)]
    }

    public mutating func handle(_ input: ToolInput) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once there is a fixed point.
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
            // Return — end the run. Each segment was already committed on its
            // second click, so there is nothing pending to add here.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingStart:
            // First point fixed; now rubber-band toward the next click.
            state = .settingEnd(last: p)
            cursor = p
            return .none

        case .settingEnd(let last):
            // Commit one segment last→p, then CONTINUE from p (chaining).
            guard last.valid, p.valid, (p - last).magnitude > Tolerance.distance else {
                // Degenerate (zero-length) pick — ignore it, keep waiting.
                return .none
            }
            let record = EntityRecord(
                id: .placeholder,
                kind: .line(LineData(start: last, end: p))
            )
            state = .settingEnd(last: p)
            cursor = p
            return .commit([record])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingStart:
            // Nothing to step back.
            return .none
        case .settingEnd:
            // Step back the running endpoint to before the first fixed point.
            // (Already-committed segments stay in the drawing — the app's undo
            //  removes those; backspace only rewinds the in-progress pick.)
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-point state.
    private mutating func reset() {
        state = .settingStart
        cursor = .invalid
    }
}
