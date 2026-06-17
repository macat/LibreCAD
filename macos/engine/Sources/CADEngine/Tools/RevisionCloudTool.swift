//
//  RevisionCloudTool.swift
//  CADEngine
//
//  A markup tool that turns a clicked path into a REVISION CLOUD — the AutoCAD
//  REVCLOUD markup: a closed loop whose every edge is a small outward-bowing arc,
//  so the boundary reads as a chain of scallops around the revised region.
//
//  ## Why this is a plain `.polyline` (no new EntityKind)
//  A revision cloud is geometrically just a CLOSED polyline where every segment
//  carries a fixed POSITIVE bulge (DXF LWPOLYLINE bulge = tan(¼·includedAngle)).
//  It needs NO new `EntityKind` case (which would be a serialized critical section
//  across ~28 exhaustive switches) — it reuses `.polyline`, exactly like
//  `PolylineTool`/`PolygonTool`/`RectangleTool` do. This is the cheapest possible
//  AutoCAD-LT markup win.
//
//  ## Outward-bowing arcs (orientation normalization)
//  The engine's bulge convention (see `Resolve.expandPolyline`) is: a POSITIVE
//  bulge bows the arc to the LEFT of the directed chord a→b. So a fixed positive
//  bulge bows OUTWARD only when the boundary is walked so the EXTERIOR is on the
//  left — i.e. CLOCKWISE (interior on the right). The user may click the path in
//  either winding, so on commit we measure the signed area and REVERSE the vertex
//  order when it is counter-clockwise, normalizing to clockwise. Then a single
//  fixed positive bulge on every vertex bows every arc outward, regardless of how
//  the user clicked.
//
//  ## How it differs from PolylineTool
//  Built on the same accumulate-then-commit-one-entity template as `PolylineTool`
//  (this file's `commitCloud` mirrors `PolylineTool.commitPolyline`), but:
//    - it always commits CLOSED (a cloud is a loop) and needs ≥3 vertices;
//    - it stamps a fixed POSITIVE bulge on every vertex (arcs, not straight edges);
//    - it normalizes the winding to clockwise so the arcs bow outward.
//
//  Behavior:
//    - `.click`/`.value` → append the (snapped) vertex; clicking near the FIRST
//                          vertex with ≥3 vertices closes + commits the cloud.
//    - `.move`           → preview the in-progress path (straight rubber-band).
//    - `.commit`         → Return / double-click: if ≥3 vertices, emit ONE closed
//                          bulged `.polyline`; if <3, commit nothing.
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

/// The interactive Revision Cloud tool. Click points to outline a region; press
/// Return (or click back on the first point) to finish, committing all vertices
/// as ONE CLOSED `.polyline` whose every segment is a fixed outward-bowing arc
/// (a revision-cloud scallop). Needs at least three points; fewer commits nothing.
public struct RevisionCloudTool: Tool {

    // MARK: - Tuning

    /// The fixed POSITIVE bulge stamped on every cloud segment. DXF bulge is
    /// `tan(includedAngle / 4)`; `0.5` ⇒ an included arc of `4·atan(0.5) ≈ 106°`,
    /// a pleasant scallop a bit more than a quarter circle (revision clouds read as
    /// shallow-to-semicircular bumps). A POSITIVE value bows the arc to the LEFT of
    /// the directed chord, which — after the clockwise winding normalization on
    /// commit — points OUTWARD. Constant (per-segment arc sizing is a later polish).
    static let cloudBulge: Double = 0.5

    // MARK: - Private state machine (mirrors PolylineTool)

    private enum State: Equatable {
        /// Waiting for the first point (no vertices yet).
        case empty
        /// One or more vertices fixed; waiting for the next point (or Return).
        case building(vertices: [Vector])
    }

    private var state: State = .empty

    /// The last cursor point seen via `.move`, used to draw the rubber-band from
    /// the last fixed vertex. Invalid until the first move.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Revision Cloud" }

    public var status: String {
        switch state {
        case .empty:
            return "Specify cloud start point"
        case .building(let vertices):
            return vertices.count >= 3
                ? "Specify next point (Return to close the cloud)"
                : "Specify next point"
        }
    }

    /// The live preview while building: an OPEN polyline of the committed vertices
    /// plus a rubber-band segment to the current cursor. Straight (the bulged
    /// scallops appear on commit) — mirrors `PolylineTool`'s rubber-band preview.
    /// Empty before the first point is set, so it never leaks after reset.
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

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as a single `.add` edit on commit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
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
            // loop and commits the cloud immediately.
            if vertices.count >= 3, let first = vertices.first,
               first.valid, (p - first).magnitude <= Tolerance.distance {
                return commitCloud(vertices: vertices)
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
            // A cloud is a closed loop — need at least three vertices; otherwise
            // commit nothing.
            guard vertices.count >= 3 else {
                reset()
                return .finished
            }
            return commitCloud(vertices: vertices)
        }
    }

    /// Builds the single `.add(.polyline)` commit: a CLOSED polyline whose every
    /// vertex carries the fixed positive `cloudBulge`, with the vertex order
    /// normalized to CLOCKWISE so each arc bows OUTWARD. Resets the tool and
    /// returns `.commit`. The app re-mints the id and applies it as one undoable
    /// group (mirrors `PolylineTool.commitPolyline`).
    private mutating func commitCloud(vertices: [Vector]) -> ToolOutcome {
        let ordered = Self.normalizedClockwise(vertices)
        let polyVertices = ordered.map { PolylineVertex(point: $0, bulge: Self.cloudBulge) }
        let record = EntityRecord(
            id: .placeholder,
            kind: .polyline(PolylineData(vertices: polyVertices, closed: true))
        )
        reset()
        return .commit([.add(record)])
    }

    /// Returns to the initial waiting-for-first-point state.
    private mutating func reset() {
        state = .empty
        cursor = .invalid
    }

    // MARK: - Winding normalization (outward-bowing arcs)

    /// The signed area of the closed polygon through `pts` (shoelace). POSITIVE ⇒
    /// the vertices wind COUNTER-CLOCKWISE; NEGATIVE ⇒ clockwise; ~0 ⇒ degenerate
    /// / collinear. The closing edge `last→first` is included (a cloud is closed).
    static func signedArea(_ pts: [Vector]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<pts.count {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Normalizes the vertex order to CLOCKWISE (non-positive signed area). The
    /// engine bows a POSITIVE bulge to the LEFT of the directed chord; walking a
    /// loop clockwise keeps the EXTERIOR on the left, so a fixed positive bulge
    /// then bows OUTWARD. A counter-clockwise input is reversed; an already-CW (or
    /// degenerate) input is returned unchanged. Because every vertex gets the SAME
    /// bulge, reversal needs no per-vertex bulge bookkeeping.
    static func normalizedClockwise(_ pts: [Vector]) -> [Vector] {
        signedArea(pts) > 0 ? Array(pts.reversed()) : pts
    }
}
