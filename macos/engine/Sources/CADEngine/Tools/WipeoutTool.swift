//
//  WipeoutTool.swift
//  CADEngine
//
//  The interactive WIPEOUT tool — the AutoCAD WIPEOUT command: click a polygon
//  boundary, and on close/Return commit ONE masking `.wipeout` region that paints
//  the canvas background color over every lower-draw-order entity beneath it
//  (hiding, not erasing, what is behind its boundary).
//
//  ## Built on the RevisionCloudTool / PolylineTool accumulate-then-commit template
//  Like `RevisionCloudTool` it accumulates clicked vertices and commits ONE closed
//  multi-vertex entity, but it differs in two ways:
//    - it commits a `.wipeout` (the ONE new EntityKind of the parity program), NOT a
//      `.polyline` — because a wipeout MASKS (the renderer paints its fill in the
//      background color in a dedicated AFTER-the-lines pass), which a plain polyline
//      cannot do;
//    - its edges are STRAIGHT (a mask polygon has no scallops), so no per-vertex
//      bulge and no winding normalization is needed.
//  The committed `WipeoutData` uses the `worldBoundary:` convenience initializer (a
//  unit 1×1 pixel frame whose insertion is the first vertex), so the clicked WORLD
//  points round-trip exactly through resolve/transform/DXF.
//
//  Behavior:
//    - `.click`/`.value` → append the (snapped) vertex; clicking near the FIRST
//                          vertex with ≥3 vertices closes + commits the wipeout.
//    - `.move`           → preview the in-progress boundary (straight rubber-band).
//    - `.commit`         → Return / double-click: if ≥3 vertices, emit ONE closed
//                          `.wipeout`; if <3, commit nothing.
//    - `.backspace`      → remove the last vertex.
//    - `.cancel`         → discard the run, reset.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit and
//  IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The interactive Wipeout tool. Click points to outline a region; press Return
/// (or click back on the first point) to finish, committing all vertices as ONE
/// closed `.wipeout` masking polygon. Needs at least three points; fewer commits
/// nothing.
public struct WipeoutTool: Tool {

    // MARK: - Private state machine (mirrors RevisionCloudTool / PolylineTool)

    private enum State: Equatable {
        /// Waiting for the first point (no vertices yet).
        case empty
        /// One or more vertices fixed; waiting for the next point (or Return).
        case building(vertices: [Vector])
    }

    private var state: State = .empty

    /// The last cursor point seen via `.move`, used to draw the rubber-band from the
    /// last fixed vertex. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Wipeout" }

    public var status: String {
        switch state {
        case .empty:
            return "Specify wipeout start point"
        case .building(let vertices):
            return vertices.count >= 3
                ? "Specify next point (Return to close the wipeout)"
                : "Specify next point"
        }
    }

    /// The live preview while building: an OPEN polyline of the committed vertices
    /// plus a rubber-band segment to the current cursor. Empty before the first point
    /// is set, so it never leaks after reset.
    public var preview: [ResolvedPolyline] {
        guard case .building(let vertices) = state, !vertices.isEmpty else {
            return []
        }
        var points = vertices
        if cursor.valid {
            points.append(cursor)   // rubber-band to the cursor
        }
        return [ResolvedPolyline(points: points, closed: false, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points) and
    /// emits new geometry as a single `.add` edit on commit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate places the next point exactly like a click.
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            reset()
            return .finished

        case .commit:
            return handleCommit()
        }
    }

    // MARK: - Click / backspace / commit handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .empty:
            state = .building(vertices: [p])
            cursor = p
            return .none

        case .building(var vertices):
            // Closing: clicking near the FIRST vertex with ≥3 vertices closes the
            // loop and commits the wipeout immediately.
            if vertices.count >= 3, let first = vertices.first,
               first.valid, (p - first).magnitude <= Tolerance.distance {
                return commitWipeout(vertices: vertices)
            }
            // Ignore a degenerate (zero-length) repeat of the last vertex.
            if let last = vertices.last, last.valid,
               (p - last).magnitude <= Tolerance.distance {
                return .none
            }
            vertices.append(p)
            state = .building(vertices: vertices)
            cursor = p
            return .none
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .empty:
            return .none
        case .building(var vertices):
            vertices.removeLast()
            if vertices.isEmpty {
                reset()
            } else {
                state = .building(vertices: vertices)
            }
            return .preview
        }
    }

    private mutating func handleCommit() -> ToolOutcome {
        switch state {
        case .empty:
            reset()
            return .finished
        case .building(let vertices):
            // A wipeout is a closed polygon — need at least three vertices; otherwise
            // commit nothing.
            guard vertices.count >= 3 else {
                reset()
                return .finished
            }
            return commitWipeout(vertices: vertices)
        }
    }

    /// Builds the single `.add(.wipeout)` commit: a closed masking polygon over the
    /// clicked world vertices (via `WipeoutData(worldBoundary:)`, a unit 1×1 frame so
    /// the world points round-trip exactly). Resets the tool and returns `.commit`.
    /// The app re-mints the id and applies it as one undoable group (mirrors
    /// `RevisionCloudTool.commitCloud`).
    private mutating func commitWipeout(vertices: [Vector]) -> ToolOutcome {
        let record = EntityRecord(
            id: .placeholder,
            kind: .wipeout(WipeoutData(worldBoundary: vertices))
        )
        reset()
        return .commit([.add(record)])
    }

    /// Returns to the initial waiting-for-first-point state.
    private mutating func reset() {
        state = .empty
        cursor = .invalid
    }
}
