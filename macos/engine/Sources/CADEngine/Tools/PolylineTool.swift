//
//  PolylineTool.swift
//  CADEngine
//
//  A multi-vertex draw tool that accumulates clicks into ONE polyline entity.
//  Ported in spirit from LibreCAD's `RS_ActionDrawPolyline`
//  (librecad/src/lib/actions/drawing/draw/lc_actiondrawpolyline.cpp), with the
//  magic `int m_status` replaced by a private `enum State`.
//
//  ## How it differs from LineTool
//  `LineTool` commits a SEPARATE `.line` entity on every second click (a chain of
//  independent lines). `PolylineTool` is the opposite: it accumulates every click
//  into an in-progress vertex list and, on `.commit` (Return / double-click),
//  emits exactly ONE `.polyline` entity carrying all of those vertices in order.
//  Nothing is committed per click — only the final Return produces geometry.
//
//  Behavior:
//    - `.click`     → append the (snapped) vertex; prompt advances to "Specify
//                     next point (Return to finish)".
//    - `.move`      → while building, the preview is the committed vertices PLUS a
//                     rubber-band segment to the cursor, as ONE open polyline.
//    - `.commit`    → Return / double-click: if ≥2 vertices, emit ONE
//                     `.add(.polyline(...))` (straight segments, bulge 0, open),
//                     then `.finished`; if <2 vertices, just `.finished` (no
//                     geometry).
//    - `.backspace` → remove the last vertex (back to the initial state if the
//                     last one is removed).
//    - `.cancel`    → discard the in-progress run, reset, `.finished`.
//    - (optional)   → clicking very near the FIRST vertex closes the loop
//                     (`closed: true`) and commits immediately.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit and
//  IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawPolyline).
//

import Foundation

/// The interactive Polyline tool. Click to add vertices; press Return (or
/// double-click) to finish, committing all the vertices as ONE `.polyline`
/// entity. Unlike `LineTool` (which emits a separate line per segment), this
/// accumulates into a single multi-vertex polyline.
public struct PolylineTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. `RS_ActionDrawPolyline`'s status integers collapse to
    /// "no vertices yet" vs. "building a vertex list".
    private enum State: Equatable {
        /// Waiting for the first point (no vertices yet).
        case empty
        /// One or more vertices fixed; waiting for the next point (or Return).
        /// `vertices` are the committed picks in order.
        case building(vertices: [Vector])
    }

    /// The current state. Starts with no vertices.
    private var state: State = .empty

    /// The last cursor point seen via `.move`, used to draw the rubber-band from
    /// the last fixed vertex. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Polyline" }

    public var status: String {
        switch state {
        case .empty:    return "Specify first point"
        case .building: return "Specify next point (Return to finish)"
        }
    }

    /// The live preview while building: an OPEN polyline of the committed vertices
    /// plus a rubber-band segment to the current cursor. Empty before the first
    /// point is set (LineTool shows nothing until a point is fixed).
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

    // MARK: - Live dimensional feedback (mirrors LineTool's current-segment readout)

    /// AutoCAD-style live feedback while the NEXT polyline segment is being dragged:
    /// the running LENGTH from the last placed vertex to the cursor plus that
    /// segment's ANGLE near the cursor — exactly like `LineTool` reports its running
    /// segment (a polyline is, mid-draw, a chain of straight segments, so the same
    /// per-segment length+angle readout applies). The dim line runs last-vertex →
    /// cursor (the same rubber-band `preview` shows), so the numbers match what the
    /// next click will fix.
    ///
    /// Empty before the first vertex (`.empty`) and after commit/cancel (the tool
    /// `reset()`s to `.empty`), and for a degenerate (zero-length) drag — the same
    /// invariant `preview` enforces, so it never leaks. Both labels are formatted
    /// IN-ENGINE via `CoordinateFormatter` from `ctx` (no UI dependency). Both fields
    /// are editable (dynamic input): Tab order is `[length, angle]`, mirroring
    /// `LineTool`'s free-mode pair.
    public func liveDimensions(_ ctx: LiveDimensionContext) -> [LiveDimension] {
        guard case .building(let vertices) = state,
              let last = vertices.last, last.valid, cursor.valid else {
            return []
        }
        let delta = cursor - last
        let length = delta.magnitude
        // A degenerate (zero-length) drag shows nothing — mirrors the commit guard.
        guard length > Tolerance.distance else { return [] }

        let lengthLabel = CoordinateFormatter.length(
            length, format: ctx.linearFormat, precision: ctx.linearPrecision, unit: ctx.unit
        )
        let angle = delta.angle
        let angleLabel = CoordinateFormatter.angle(
            angle, format: ctx.angleFormat, precision: ctx.anglePrecision
        )
        // Length dim runs along the segment, labeled at its midpoint; the angle dim
        // shares the segment and is labeled near the cursor end — identical to LineTool.
        let midpoint = (last + cursor) * 0.5
        return [
            LiveDimension(kind: .linear(length), from: last, to: cursor,
                          label: lengthLabel, labelAnchor: midpoint,
                          field: .length, isEditable: true),
            LiveDimension(kind: .angle(angle), from: last, to: cursor,
                          label: angleLabel, labelAnchor: cursor,
                          field: .angle, isEditable: true),
        ]
    }

    // MARK: - Dynamic input (typed length / angle → the next vertex)

    /// Resolves typed LENGTH / ANGLE values into the next vertex, measured from the
    /// last placed vertex (`reference`) — the SAME free-angle polar formula `LineTool`
    /// uses (a polyline segment has no angle constraint). A field the user did not type
    /// falls back to the live value the cursor currently implies.
    ///
    /// Returns `nil` before the first vertex is placed (no running anchor to measure
    /// from) — `applyDynamicInput` is meaningful only while `.building`.
    public func applyDynamicInput(_ values: [LiveDimensionField: Double],
                                  cursor: Vector, reference: Vector) -> Vector? {
        guard case .building = state else { return nil }
        let liveDelta = cursor - reference
        let len = values[.length] ?? liveDelta.magnitude
        let ang = values[.angle] ?? liveDelta.angle
        return reference + Vector(angle: ang) * len
    }

    /// The AutoCAD-style mid-draw command KEYWORDS the polyline offers at its current
    /// step, derived PURELY from the committed-vertex count in `state` (no new stored
    /// fields — reads `state` exactly like `preview`/`status` do). The smart command
    /// line (Wave 4) renders these as `[Close]`/`[Undo]` chips, and a chosen keyword is
    /// dispatched back through the EXISTING `ToolInput` events (Wave 3):
    ///   - `Undo` ↔ `.backspace` (removes the last vertex).
    ///   - `Close` ↔ `.click(firstVertex)` — clicking on the first vertex closes the
    ///     loop and commits (`commitPolyline(closed: true)`); there is no standalone
    ///     close input, so Wave 3 feeds the first vertex back as a `.click`.
    /// Step gating mirrors LineTool's bracketed options: 0 vertices → none; 1 vertex →
    /// `Undo` only (nothing to close yet); ≥2 vertices → `Close` + `Undo`. Empty before
    /// the first point and after commit/reset (`state == .empty`), so it never leaks.
    public var keywordOptions: [ToolKeyword] {
        guard case .building(let vertices) = state else { return [] }
        switch vertices.count {
        case 0:
            return []
        case 1:
            return [ToolKeyword(keyword: "Undo", label: "Undo")]
        default:
            return [
                ToolKeyword(keyword: "Close", label: "Close"),
                ToolKeyword(keyword: "Undo", label: "Undo"),
            ]
        }
    }

    /// The WORLD point the smart command line's `Close` keyword re-feeds to close the
    /// loop: the FIRST committed vertex, returned EXACTLY when `keywordOptions` offers
    /// `Close` (≥ 2 committed vertices), else `nil`. There is no standalone close input,
    /// so Wave 3 dispatches `Close` as `.click(closeAnchor)`; `handleClick`'s
    /// close-on-first-vertex path then commits the closed polyline. Reads the same private
    /// `state.building.vertices` `keywordOptions`/`preview` read — no new stored field.
    public var closeAnchor: Vector? {
        guard case .building(let vertices) = state, vertices.count >= 2 else { return nil }
        return vertices.first
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as a single `.add` edit on commit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once there is a fixed vertex.
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
            // Return / double-click — finish the polyline.
            return handleCommit()
        }
    }

    // MARK: - Click / backspace / commit handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .empty:
            // First vertex fixed; now rubber-band toward the next click.
            state = .building(vertices: [p])
            cursor = p
            return .none

        case .building(var vertices):
            // Closing: clicking very near the FIRST vertex closes the loop and
            // commits immediately (optional convenience; default is open).
            if vertices.count >= 2, let first = vertices.first,
               first.valid, (p - first).magnitude <= Tolerance.distance {
                return commitPolyline(vertices: vertices, closed: true)
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
            // Nothing to step back.
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
            // Nothing pending — just end the run.
            reset()
            return .finished
        case .building(let vertices):
            // Need at least two vertices to make a polyline; otherwise commit
            // nothing.
            guard vertices.count >= 2 else {
                reset()
                return .finished
            }
            return commitPolyline(vertices: vertices, closed: false)
        }
    }

    /// Builds the single `.add(.polyline)` commit (all vertices, bulge 0) and
    /// resets the tool, returning `.commit`. The app re-mints the id and applies
    /// the whole list as one undoable group; `.finished` follows on the next event
    /// since the run is over — but a draw tool ends its run here, so we also reset
    /// so the next activation starts clean.
    private mutating func commitPolyline(vertices: [Vector], closed: Bool) -> ToolOutcome {
        let polyVertices = vertices.map { PolylineVertex(point: $0, bulge: 0) }
        let record = EntityRecord(
            id: .placeholder,
            kind: .polyline(PolylineData(vertices: polyVertices, closed: closed))
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
