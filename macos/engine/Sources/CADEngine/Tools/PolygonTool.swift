//
//  PolygonTool.swift
//  CADEngine
//
//  The regular-polygon (N-gon) draw tool — center + vertex, inscribed in a
//  circle. Ported in spirit from LibreCAD's `RS_ActionDrawPolygonCenCor`
//  (librecad/src/lib/actions/drawing/draw/polygon/lc_actiondrawpolygoncentre*.cpp,
//  the centre→corner variant), with the magic `int m_status` replaced by a
//  private `enum State` (engine-architecture note) and the result emitted as one
//  closed `PolylineData` (LibreCAD builds the polygon as a closed polyline).
//
//  Behavior:
//    - first `.click`  → fix the center (State.settingCenter → .settingVertex).
//    - `.move`         → rubber-band preview of the regular `sides`-gon inscribed
//                        in the circle of radius |cursor − center|, with the first
//                        vertex at the angle(center → cursor) and the remaining
//                        vertices spaced evenly by 2π/sides (4 corners, closed).
//    - next `.click`   → commit ONE `.polyline(PolylineData)` — a closed N-vertex
//                        regular polygon — then RESET to wait for the next
//                        polygon's center.
//    - `.backspace`    → step back the fixed center (undo the pick within the run,
//                        no commit), returning to the initial state.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) → end the run; `.finished` (nothing pending — each polygon
//                        is committed on its second click).
//    - A degenerate pick (zero radius / vertex on center) is ignored.
//
//  Side count: `sides` defaults to 6 and is a settable `var` (min 3, clamped on
//  set). A side-count UI is a backlog item — see the TODO below.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit, and
//  it IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawPolygon).
//

import Foundation

/// The interactive regular-polygon (N-gon) tool, center + vertex. Click the
/// center, then click (or move to preview) a vertex; the polygon is the regular
/// `sides`-gon inscribed in the circle through that vertex, with the first vertex
/// at the clicked point. It commits one closed polyline and re-arms for the next
/// (LibreCAD behavior).
public struct PolygonTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawPolygon`'s status integers
    /// (SetCenter / SetCorner) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the center point (nothing fixed yet).
        case settingCenter
        /// Center fixed; waiting for a vertex point that sets the radius + first
        /// vertex angle. `center` is the fixed center the polygon is built around.
        case settingVertex(center: Vector)
    }

    /// The current state. Starts waiting for the center.
    private var state: State = .settingCenter

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The number of sides of the regular polygon. Defaults to 6 and is clamped to
    /// a minimum of 3 on set (a polygon needs at least 3 sides).
    ///
    // TODO(backlog): side-count UI — expose `sides` through a tool-options panel /
    // status-line input so the user can pick N. For now it is settable in code and
    // defaults to a hexagon.
    public var sides: Int {
        get { _sides }
        set { _sides = Swift.max(3, newValue) }
    }
    private var _sides: Int = 6

    public init() {}

    // MARK: - Tool

    public var title: String { "Polygon" }

    public var status: String {
        switch state {
        case .settingCenter: return "Specify center point"
        case .settingVertex: return "Specify a vertex (N=\(_sides))"
        }
    }

    /// The live rubber-band: a closed regular `sides`-gon inscribed in the circle
    /// of radius = |cursor − center|, with the first vertex at angle(center →
    /// cursor). Empty before the center is set, before the cursor has moved, or
    /// while the radius is still degenerate (zero).
    public var preview: [ResolvedPolyline] {
        guard case .settingVertex(let center) = state, cursor.valid, center.valid else {
            return []
        }
        guard let corners = Self.corners(center: center, vertex: cursor, sides: _sides) else {
            return []
        }
        return [ResolvedPolyline(points: corners, closed: true, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once the center is fixed.
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the in-progress polygon and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — when idle there is nothing pending, so end the run. (Each
            // polygon is committed on its second click; there is never pending
            // geometry to flush here.)
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Center fixed; now rubber-band the polygon toward the next click.
            state = .settingVertex(center: p)
            cursor = p
            return .none

        case .settingVertex(let center):
            // Commit one closed regular polygon (center, vertex = p), then re-arm.
            guard let corners = Self.corners(center: center, vertex: p, sides: _sides) else {
                // Degenerate (zero-radius) pick — ignore it, keep waiting.
                return .none
            }
            let data = PolylineData(
                vertices: corners.map { PolylineVertex(point: $0, bulge: 0) },
                closed: true
            )
            let record = EntityRecord(
                id: .placeholder,
                kind: .polyline(data)
            )
            // Re-arm for the next polygon (stay active).
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Nothing to step back.
            return .none
        case .settingVertex:
            // Step the vertex pick back to before the center was fixed.
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting-for-center state.
    private mutating func reset() {
        state = .settingCenter
        cursor = .invalid
    }

    // MARK: - Geometry

    /// The `sides` corners of the regular polygon inscribed in the circle through
    /// `vertex`, centered on `center`. The first corner is exactly `vertex`; the
    /// rest are spaced by 2π/sides CCW around the center. Returns `nil` for a
    /// degenerate pick (radius below the distance tolerance) so callers can ignore
    /// it. The ring does NOT duplicate the first vertex — the `closed` flag carries
    /// the closing edge (same convention as `Tessellation.circlePoints`).
    static func corners(center: Vector, vertex: Vector, sides: Int) -> [Vector]? {
        guard center.valid, vertex.valid, sides >= 3 else { return nil }
        let delta = vertex - center
        let radius = delta.magnitude
        guard radius > Tolerance.distance else { return nil }
        let baseAngle = delta.angle
        let step = 2 * Double.pi / Double(sides)
        var pts: [Vector] = []
        pts.reserveCapacity(sides)
        for i in 0..<sides {
            pts.append(center + Vector.polar(radius: radius, angle: baseAngle + step * Double(i)))
        }
        return pts
    }
}
