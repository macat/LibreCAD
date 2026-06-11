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

    public init() {}

    // MARK: - Tool

    public var title: String { "Rectangle" }

    public var status: String {
        switch state {
        case .settingFirst:  return "Specify first corner"
        case .settingSecond: return "Specify opposite corner"
        }
    }

    /// The live rubber-band: a closed 4-corner rectangle spanned by the fixed
    /// first corner and the current cursor. Empty before the first corner is set,
    /// or before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .settingSecond(let first) = state, cursor.valid, first.valid else {
            return []
        }
        return [ResolvedPolyline(points: Self.corners(first, cursor), closed: true, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the first corner is set.
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
            // First corner fixed; now rubber-band toward the opposite corner.
            state = .settingSecond(first: p)
            cursor = p
            return .none

        case .settingSecond(let first):
            // Commit one closed rectangle spanned by first↔p, then RESET to draw
            // the next rectangle.
            guard first.valid, p.valid, !Self.isDegenerate(first, p) else {
                // Degenerate (zero-area / coincident corners) pick — ignore it,
                // keep waiting for a valid opposite corner.
                return .none
            }
            let corners = Self.corners(first, p)
            let data = PolylineData(
                vertices: corners.map { PolylineVertex(point: $0, bulge: 0) },
                closed: true
            )
            let record = EntityRecord(
                id: .placeholder,
                kind: .polyline(data)
            )
            reset()
            return .commit([.add(record)])
        }
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
}
