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

/// Whether the regular polygon is built INSCRIBED in (vertex on) the reference
/// circle through the clicked point, or CIRCUMSCRIBED about it (the edge midpoints
/// touch the circle, so the polygon is larger). Mirrors LibreCAD's two N-gon
/// variants (`RS_ActionDrawPolygonCenCor` inscribed vs the circumscribed corner
/// build). The tool-options bar (UX-plan U2) exposes this as a segmented control.
public enum PolygonFit: Sendable, Hashable, CaseIterable {
    /// The clicked vertex lies ON the reference circle (default; LibreCAD's
    /// centre→corner inscribed polygon).
    case inscribed
    /// The reference circle is INSCRIBED in the polygon — the clicked point is the
    /// midpoint of an edge (the polygon's corners sit OUTSIDE the circle), so the
    /// circumradius is `r / cos(π/sides)`.
    case circumscribed
}

/// How the two picked points define the regular polygon, mirroring LibreCAD's
/// two N-gon construction actions plus the star variant. The tool-options bar
/// (UX-plan U2) would surface this as a segmented control (and a ratio field for
/// star), set on a freshly-minted tool (like `sides`/`fit`) before drawing. Every
/// mode still commits a SINGLE closed `.polyline`.
public enum PolygonMode: Sendable, Hashable {
    /// CENTER → CORNER (default, `RS_ActionDrawPolygonCenCor`): the first click is
    /// the CENTER, the second is a vertex on (or an edge midpoint of, per `fit`) the
    /// reference circle. The original behavior — unchanged.
    case centerCorner
    /// CORNER → CORNER (`RS_ActionDrawPolygonCorCor`): the two clicks are two
    /// ADJACENT corners, i.e. they define ONE EDGE of the regular N-gon. The polygon
    /// is built on the LEFT of the directed first→second edge (CCW), with the first
    /// vertex at the first click.
    case edge
    /// STAR: like `centerCorner` (first click center, second a vertex) but the
    /// committed polyline is a 2·N-point star — N OUTER vertices on the clicked
    /// circle alternating with N INNER vertices at `outerRadius · ratio`, the inner
    /// ring rotated half a step. `ratio` is clamped to `(0, 1)`.
    case star(ratio: Double)
}

/// The interactive regular-polygon (N-gon) tool, center + vertex. Click the
/// center, then click (or move to preview) a vertex; the polygon is the regular
/// `sides`-gon built around the circle through that vertex (inscribed by default,
/// or circumscribed per `fit`), with the first vertex at the clicked point. It
/// commits one closed polyline and re-arms for the next (LibreCAD behavior).
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
    /// a minimum of 3 on set (a polygon needs at least 3 sides). Surfaced by the
    /// tool-options bar (UX-plan U2) so the user can pick N (hexagon, pentagon, …)
    /// before drawing.
    public var sides: Int {
        get { _sides }
        set { _sides = Swift.max(3, newValue) }
    }
    private var _sides: Int = 6

    /// Whether the polygon is inscribed in (default) or circumscribed about the
    /// reference circle through the clicked vertex. Surfaced by the tool-options bar
    /// (UX-plan U2). Back-compatible: the default `.inscribed` keeps the original
    /// vertex-on-circle behavior. Honored by `.centerCorner` / `.star`; ignored by
    /// `.edge` (which is defined purely by the two corner clicks).
    public var fit: PolygonFit = .inscribed

    /// How the two clicks define the polygon, surfaced by the tool-options bar
    /// (UX-plan U2). Defaults to `.centerCorner` so the original center→vertex flow
    /// (and every existing test) is unchanged; `.edge` reinterprets the two clicks
    /// as one EDGE, and `.star(ratio:)` commits a 2·N-point star.
    public var mode: PolygonMode = .centerCorner

    public init() {}

    // MARK: - Tool

    public var title: String { "Polygon" }

    public var status: String {
        switch (state, mode) {
        // `.edge` reinterprets the two clicks as two adjacent corners.
        case (.settingCenter, .edge): return "Specify first corner"
        case (.settingVertex, .edge): return "Specify second corner (N=\(_sides))"
        // `.centerCorner` (default) and `.star` are both center→vertex; keep the
        // ORIGINAL prompts for `.centerCorner` so existing tests are unchanged.
        case (.settingCenter, _): return "Specify center point"
        case (.settingVertex, _): return "Specify a vertex (N=\(_sides))"
        }
    }

    /// The live rubber-band: a closed regular `sides`-gon inscribed in the circle
    /// of radius = |cursor − center|, with the first vertex at angle(center →
    /// cursor). Empty before the center is set, before the cursor has moved, or
    /// while the radius is still degenerate (zero).
    public var preview: [ResolvedPolyline] {
        guard case .settingVertex(let first) = state, cursor.valid, first.valid else {
            return []
        }
        guard let pts = Self.shape(first: first, second: cursor,
                                   sides: _sides, fit: fit, mode: mode) else {
            return []
        }
        return [ResolvedPolyline(points: pts, closed: true, pen: .toolPreview)]
    }

    // MARK: - Live dimensional feedback (W1b)

    /// AutoCAD-style live feedback while the polygon is being dragged: the running
    /// reference RADIUS (center → cursor) with the side count folded into the label
    /// (e.g. `"r=12.5  N=6"`). Reuses the SAME center→cursor reference distance the
    /// `preview` rubber-band is built from, so the number matches what will be drawn.
    ///
    /// Only the center-based construction modes (`.centerCorner` / `.star`, where the
    /// first click IS the center) expose a center→cursor radius; `.edge` reinterprets
    /// the two clicks as one EDGE (no center), so it returns `[]`. Empty before the
    /// center is fixed (`.settingCenter`) and after commit (every commit `reset()`s
    /// to `.settingCenter`), and for a degenerate (zero-radius) drag — the same
    /// invariant `referenceSegments` enforces, so it never leaks into exports. The
    /// radius portion of the label is formatted IN-ENGINE via `CoordinateFormatter`
    /// from `ctx` (no UI dependency).
    public func liveDimensions(_ ctx: LiveDimensionContext) -> [LiveDimension] {
        guard case .settingVertex(let center) = state, cursor.valid, center.valid else {
            return []
        }
        // `.edge` has no center→radius semantics (the two picks are one edge).
        if case .edge = mode { return [] }
        let radius = (cursor - center).magnitude
        guard radius > Tolerance.distance else { return [] }
        let radiusStr = CoordinateFormatter.length(
            radius, format: ctx.linearFormat, precision: ctx.linearPrecision, unit: ctx.unit
        )
        let midpoint = (center + cursor) * 0.5
        // The center-based modes (`.centerCorner` / `.star`) expose an editable radius
        // (dynamic input): a typed radius has a well-defined direction (center →
        // cursor). `.edge` already returned `[]` above (no center → radius semantics).
        return [
            LiveDimension(kind: .radius(radius), from: center, to: cursor,
                          label: "r=\(radiusStr)  N=\(_sides)", labelAnchor: midpoint,
                          field: .radius, isEditable: true),
        ]
    }

    // MARK: - Dynamic input (typed radius → the vertex point)

    /// Resolves a typed RADIUS into the reference vertex point that fixes the polygon's
    /// size, measured from the center (`reference`). Meaningful ONLY in the center-based
    /// modes' `.settingVertex(center:)` state (`.edge` has no center → radius semantics)
    /// — returns `nil` otherwise. The direction is the live center→cursor unit vector; a
    /// degenerate cursor==center falls back to +X. A missing `.radius` falls back to the
    /// live radius the cursor implies.
    public func applyDynamicInput(_ values: [LiveDimensionField: Double],
                                  cursor: Vector, reference: Vector) -> Vector? {
        guard case .settingVertex = state else { return nil }
        if case .edge = mode { return nil }
        let r = values[.radius] ?? (cursor - reference).magnitude
        let d = cursor - reference
        let u = d.magnitude > Tolerance.distance ? d / d.magnitude : Vector(angle: 0)
        return reference + u * r
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
            // First point fixed (center for centerCorner/star, first corner for
            // edge); now rubber-band the polygon toward the second click.
            state = .settingVertex(center: p)
            cursor = p
            return .none

        case .settingVertex(let first):
            // Commit one closed polygon defined by the two points under `mode`,
            // then re-arm. A degenerate pick (zero radius / zero-length edge) is
            // ignored — keep waiting for the second point.
            guard let pts = Self.shape(first: first, second: p,
                                       sides: _sides, fit: fit, mode: mode) else {
                return .none
            }
            let data = PolylineData(
                vertices: pts.map { PolylineVertex(point: $0, bulge: 0) },
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

    /// The `sides` corners of the regular polygon built around the circle through
    /// `vertex`, centered on `center`. For `.inscribed` (default) the first corner
    /// is exactly `vertex` and every corner lies ON the reference circle; for
    /// `.circumscribed` the clicked point is an EDGE MIDPOINT (the corners sit
    /// outside the reference circle at circumradius `r / cos(π/sides)`, with the
    /// first edge midpoint at `vertex`). The rest are spaced by 2π/sides CCW around
    /// the center. Returns `nil` for a degenerate pick (radius below the distance
    /// tolerance) so callers can ignore it. The ring does NOT duplicate the first
    /// vertex — the `closed` flag carries the closing edge (same convention as
    /// `Tessellation.circlePoints`).
    static func corners(center: Vector, vertex: Vector, sides: Int,
                        fit: PolygonFit = .inscribed) -> [Vector]? {
        guard center.valid, vertex.valid, sides >= 3 else { return nil }
        let delta = vertex - center
        let refRadius = delta.magnitude
        guard refRadius > Tolerance.distance else { return nil }
        let step = 2 * Double.pi / Double(sides)
        // Inscribed: corners on the reference circle, first at the clicked vertex.
        // Circumscribed: the clicked point is an edge midpoint, so push the corners
        // out to the circumradius and rotate the first corner back by half a step so
        // the FIRST EDGE'S MIDPOINT lands on the clicked point.
        let baseAngle: Double
        let radius: Double
        switch fit {
        case .inscribed:
            baseAngle = delta.angle
            radius = refRadius
        case .circumscribed:
            baseAngle = delta.angle - step / 2
            radius = refRadius / cos(step / 2)
        }
        var pts: [Vector] = []
        pts.reserveCapacity(sides)
        for i in 0..<sides {
            pts.append(center + Vector.polar(radius: radius, angle: baseAngle + step * Double(i)))
        }
        return pts
    }

    // MARK: - Mode dispatch + variant geometry (edge / star)

    /// The outline points for the polygon defined by the two picked points `first`
    /// / `second` under `mode`, the single entry point used by both `preview` and
    /// the commit. Returns `nil` for a degenerate pick (so the caller ignores it):
    ///   - `.centerCorner` → `corners(center: first, vertex: second, …)` (UNCHANGED).
    ///   - `.edge`         → `edgeCorners(first, second, sides:)` — the two points
    ///                       are one EDGE of the N-gon.
    ///   - `.star(ratio:)` → `starPoints(center: first, vertex: second, …)` — a
    ///                       2·N-point star.
    /// The ring never duplicates the first vertex (the `closed` flag carries the
    /// closing edge — same convention as `corners`).
    static func shape(first: Vector, second: Vector, sides: Int,
                      fit: PolygonFit, mode: PolygonMode) -> [Vector]? {
        switch mode {
        case .centerCorner:
            return corners(center: first, vertex: second, sides: sides, fit: fit)
        case .edge:
            return edgeCorners(first, second, sides: sides)
        case .star(let ratio):
            return starPoints(center: first, vertex: second, sides: sides,
                              fit: fit, ratio: ratio)
        }
    }

    /// The `sides` corners of the regular N-gon for which the directed segment
    /// `p0`→`p1` is exactly ONE EDGE (two ADJACENT corners). The polygon is built on
    /// the LEFT of `p0`→`p1` (CCW winding, interior on the left), with the first
    /// corner at `p0` and the second at `p1`. Every side then has the same length
    /// `|p1 − p0|`. Returns `nil` for a degenerate (zero-length) edge.
    ///
    /// Construction: the circumradius of a regular N-gon with side `s` is
    /// `R = s / (2·sin(π/N))`; the center is the edge midpoint offset by the apothem
    /// `R·cos(π/N)` along the edge's LEFT normal. Corners are then `R`-radius points
    /// spaced `2π/N` CCW starting at the angle from the center to `p0`.
    static func edgeCorners(_ p0: Vector, _ p1: Vector, sides: Int) -> [Vector]? {
        guard p0.valid, p1.valid, sides >= 3 else { return nil }
        let edge = p1 - p0
        let side = edge.magnitude
        guard side > Tolerance.distance else { return nil }
        let half = Double.pi / Double(sides)
        let circumradius = side / (2 * sin(half))
        let apothem = circumradius * cos(half)
        let dir = edge / side
        let leftNormal = Vector(-dir.y, dir.x)          // interior side of p0→p1
        let center = (p0 + p1) * 0.5 + leftNormal * apothem
        let baseAngle = (p0 - center).angle             // first corner at p0
        let step = 2 * Double.pi / Double(sides)
        var pts: [Vector] = []
        pts.reserveCapacity(sides)
        for i in 0..<sides {
            pts.append(center + Vector.polar(radius: circumradius,
                                             angle: baseAngle + step * Double(i)))
        }
        return pts
    }

    /// A `2·sides`-point STAR centered on `center` with its first OUTER point at the
    /// clicked `vertex`. Outer points lie on the reference circle (radius / `fit`
    /// resolved exactly like `corners`); inner points lie at `outerRadius · ratio`,
    /// rotated half a step so each inner point sits BETWEEN two outer points. The
    /// returned ring alternates outer, inner, outer, inner, … (so `pts[even]` are the
    /// outer tips and `pts[odd]` the inner valleys). Returns `nil` for a degenerate
    /// pick (zero radius) or a `ratio` outside `(0, 1)`.
    static func starPoints(center: Vector, vertex: Vector, sides: Int,
                           fit: PolygonFit, ratio: Double) -> [Vector]? {
        guard ratio > Tolerance.distance, ratio < 1 - Tolerance.distance else { return nil }
        // Reuse the regular-polygon corners for the OUTER ring (honors `fit` and the
        // zero-radius guard); the outer circumradius is the first corner's distance.
        guard let outer = corners(center: center, vertex: vertex, sides: sides, fit: fit),
              let firstOuter = outer.first else { return nil }
        let outerRadius = (firstOuter - center).magnitude
        let innerRadius = outerRadius * ratio
        let step = 2 * Double.pi / Double(sides)
        let baseAngle = (firstOuter - center).angle
        var pts: [Vector] = []
        pts.reserveCapacity(sides * 2)
        for i in 0..<sides {
            // Outer tip (reuse the exact regular-polygon corner).
            pts.append(outer[i])
            // Inner valley, half a step past the outer tip.
            let innerAngle = baseAngle + step * (Double(i) + 0.5)
            pts.append(center + Vector.polar(radius: innerRadius, angle: innerAngle))
        }
        return pts
    }
}
