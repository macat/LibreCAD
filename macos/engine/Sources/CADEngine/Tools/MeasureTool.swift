//
//  MeasureTool.swift
//  CADEngine
//
//  The read-only measurement / info tools (v5 feature F11): pick points or read
//  the current selection, COMPUTE a value, and report it back through the tool's
//  `status` string — which the app already surfaces in the persistent status HUD
//  (`toolStatus`). These are query tools: they NEVER mutate the drawing, so every
//  outcome is `.none` / `.finished` and NO `ToolEdit` is ever emitted (no
//  `.commit`). Ported in spirit from LibreCAD's info actions
//  (librecad/src/lib/actions/info/: `RS_ActionInfoDist`, `RS_ActionInfoAngle`,
//  `RS_ActionInfoArea`, `RS_ActionInfoTotalLength`), but as a single pure value
//  type with a private `enum State` (no magic `int m_status`) and the variant
//  chosen by a public `Mode` — matching the FROZEN `Tool` contract.
//
//  Variants (`MeasureTool.Mode`):
//    - `.distance`     — pick 2 points → "Distance: <d>  Δx <> Δy <> Angle <°>".
//    - `.angle`        — pick 3 points (vertex, then the two rays) → the angle at
//                        the vertex, in degrees (and its radian value).
//    - `.areaPerimeter`— pick a closed sequence of points (Return / a click on the
//                        first point closes it) → polygon area + perimeter via the
//                        shoelace formula. Picking a single CLOSED entity from the
//                        selection (run the tool with one closed entity selected
//                        and press Return) reports that entity's area+perimeter.
//    - `.totalLength`  — sum the resolved length of every entity in
//                        `context.selected` (read immediately on the first input).
//
//  Snapping: all picked points arrive ALREADY snapped (the app runs `Snapping.snap`
//  and feeds the snapped world point in via `.click` / `.value`), exactly like the
//  draw tools — the measure tool never snaps.
//
//  Number formatting: linear quantities (distances, perimeter, side lengths) go
//  through `CoordinateFormatter.length(_:)` so the readout matches the status-bar
//  coordinate readout and the dimension labels (decimal, trailing zeros stripped).
//  A later pass can thread the document's `LinearFormat`/precision/unit through
//  `ToolContext`; until then the default decimal form is used. Angles are reported
//  in degrees (there is no unit-aware angle formatter yet).
//
//  PURE: it never touches CADDrawing / Quadtree / GUI. `.distance` / `.angle` /
//  `.areaPerimeter` need only the snapped points; `.totalLength` reads the
//  read-only `context.selected`. The app re-mints nothing (no commit ever happens).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionInfo* family).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive measurement / info tool. One value type, four `Mode`s. It picks
/// points (or reads the selection) and reports a computed value via `status`; it
/// makes NO change to the drawing (read-only), so it never returns `.commit`.
public struct MeasureTool: Tool {

    // MARK: - Variant

    /// Which quantity this tool measures — surfaced as four separate entries in the
    /// tool palette / `ToolKind` (the wire-wave maps each to `MeasureTool(mode:)`).
    public enum Mode: Sendable, Hashable, CaseIterable {
        /// Pick 2 points → distance, Δx, Δy, and the angle of the connecting vector.
        case distance
        /// Pick 3 points (vertex first, then the two rays) → the angle at the vertex.
        case angle
        /// Pick a closed sequence of points → polygon area + perimeter. Or, with a
        /// single closed entity selected, press Return to measure that entity.
        case areaPerimeter
        /// Sum the length of every entity in the current selection.
        case totalLength
    }

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. Each case carries the picks made so far; an exhaustive
    /// `switch` over it drives `status`, `handle`, and `backspace`.
    private enum State: Equatable {
        // Distance: collect the first point, then the second.
        case distFirst
        case distSecond(first: Vector)
        /// Distance reported (terminal until Return/Esc resets for the next measure).
        case distDone(first: Vector, second: Vector)

        // Angle: vertex, then the first ray, then the second ray.
        case angVertex
        case angFirst(vertex: Vector)
        case angSecond(vertex: Vector, first: Vector)
        /// Angle reported (terminal until reset).
        case angDone(degrees: Double)

        // Area / perimeter: accumulate the boundary points until closed (Return or a
        // click back on the first point).
        case areaPicking(points: [Vector])
        /// Area + perimeter reported (terminal until reset).
        case areaDone(area: Double, perimeter: Double)

        // Total length: a one-shot read of `context.selected`.
        case lenPending
        /// Total length reported (terminal until reset).
        case lenDone(total: Double, count: Int)
    }

    /// The current state, seeded from `mode` in `init`.
    private var state: State

    /// The last `.move` cursor — used only for the live preview of the in-progress
    /// distance segment / area boundary. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The measured quantity (`Mode`). Picked by the wire-wave when minting the tool.
    public let mode: Mode

    /// Creates a measurement tool for the given `mode`.
    public init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .distance:      state = .distFirst
        case .angle:         state = .angVertex
        case .areaPerimeter: state = .areaPicking(points: [])
        case .totalLength:   state = .lenPending
        }
    }

    // MARK: - Tool: title

    public var title: String {
        switch mode {
        case .distance:      return "Measure Distance"
        case .angle:         return "Measure Angle"
        case .areaPerimeter: return "Measure Area"
        case .totalLength:   return "Total Length"
        }
    }

    // MARK: - Tool: status (the readout — this IS the result channel)

    /// The prompt while picking, and the computed RESULT once enough picks are in.
    /// This is the only output channel a measure tool has: the app shows it in the
    /// status HUD (`toolStatus`), so the result text lives here.
    public var status: String {
        switch state {
        case .distFirst:
            return "Specify first point"
        case .distSecond:
            return "Specify second point"
        case .distDone(let a, let b):
            return Self.distanceReadout(a, b)

        case .angVertex:
            return "Specify the vertex"
        case .angFirst:
            return "Specify first point"
        case .angSecond:
            return "Specify second point"
        case .angDone(let deg):
            return "Angle: \(Self.angleReadout(deg))"

        case .areaPicking(let pts):
            if pts.count < 3 {
                return "Specify boundary point (\(pts.count) picked)"
            }
            return "Specify next point or Return to close (\(pts.count) picked)"
        case .areaDone(let area, let perimeter):
            return "Area: \(Self.lengthString(area))   Perimeter: \(Self.lengthString(perimeter))"

        case .lenPending:
            return "Select entities, then run — measuring selection"
        case .lenDone(let total, let count):
            let noun = count == 1 ? "entity" : "entities"
            return "Total length (\(count) \(noun)): \(Self.lengthString(total))"
        }
    }

    // MARK: - Tool: preview (rubber-band of the in-progress pick — read-only)

    public var preview: [ResolvedPolyline] {
        switch state {
        case .distSecond(let first):
            guard cursor.valid, first.valid else { return [] }
            return [ResolvedPolyline(points: [first, cursor], closed: false, pen: .toolPreview)]

        case .angFirst(let vertex):
            guard cursor.valid, vertex.valid else { return [] }
            return [ResolvedPolyline(points: [vertex, cursor], closed: false, pen: .toolPreview)]

        case .angSecond(let vertex, let first):
            // Both rays from the vertex (the fixed first ray and the live second).
            guard vertex.valid else { return [] }
            var lines: [ResolvedPolyline] = []
            if first.valid {
                lines.append(ResolvedPolyline(points: [vertex, first], closed: false, pen: .toolPreview))
            }
            if cursor.valid {
                lines.append(ResolvedPolyline(points: [vertex, cursor], closed: false, pen: .toolPreview))
            }
            return lines

        case .areaPicking(let pts):
            guard !pts.isEmpty else { return [] }
            var chain = pts
            if cursor.valid { chain.append(cursor) }
            guard chain.count >= 2 else { return [] }
            // Show the open boundary so far (it visually closes when the user closes it).
            return [ResolvedPolyline(points: chain, closed: false, pen: .toolPreview)]

        default:
            return []
        }
    }

    // MARK: - Tool: handle

    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) lands a pick exactly like a click.
            return handlePick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .commit:
            // Return: close the area boundary, or read the selection's total length;
            // otherwise (distance/angle, or nothing pending) end the tool.
            return handleCommit(context: context)

        case .cancel:
            // Esc — discard the run and end the tool.
            reset()
            return .finished
        }
    }

    // MARK: - Pick handling

    private mutating func handlePick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        // MARK: Distance
        case .distFirst:
            state = .distSecond(first: p)
            cursor = p
            return .none
        case .distSecond(let first):
            state = .distDone(first: first, second: p)
            cursor = p
            // Result is now in `status`; the app redraws the HUD. No mutation.
            return .none
        case .distDone:
            // Start a fresh measurement from this click.
            state = .distSecond(first: p)
            cursor = p
            return .none

        // MARK: Angle
        case .angVertex:
            state = .angFirst(vertex: p)
            cursor = p
            return .none
        case .angFirst(let vertex):
            // A first ray coincident with the vertex carries no direction — ignore it.
            guard (p - vertex).magnitude > Tolerance.distance else { return .none }
            state = .angSecond(vertex: vertex, first: p)
            cursor = p
            return .none
        case .angSecond(let vertex, let first):
            guard (p - vertex).magnitude > Tolerance.distance else { return .none }
            let deg = Self.angleBetween(vertex: vertex, a: first, b: p)
            state = .angDone(degrees: deg)
            cursor = p
            return .none
        case .angDone:
            // Restart: this click becomes the new vertex.
            state = .angFirst(vertex: p)
            cursor = p
            return .none

        // MARK: Area / perimeter
        case .areaPicking(var pts):
            // Clicking back on (near) the first point closes the boundary.
            if pts.count >= 3, let first = pts.first,
               (p - first).magnitude <= Tolerance.distance {
                return closeArea(pts)
            }
            // Ignore a pick coincident with the previous one (no zero-length edge).
            if let last = pts.last, (p - last).magnitude <= Tolerance.distance {
                return .none
            }
            pts.append(p)
            state = .areaPicking(points: pts)
            cursor = p
            return .none
        case .areaDone:
            // Restart a fresh boundary from this click.
            state = .areaPicking(points: [p])
            cursor = p
            return .none

        // MARK: Total length
        case .lenPending:
            // A click in total-length mode just reads the selection (same as Return).
            return measureTotalLength(context)
        case .lenDone:
            // Re-measure (the selection may have changed).
            return measureTotalLength(context)
        }
    }

    // MARK: - Commit (Return) handling

    private mutating func handleCommit(context: ToolContext) -> ToolOutcome {
        switch state {
        case .areaPicking(let pts):
            // Return closes the boundary with the points picked so far.
            if pts.count >= 3 {
                return closeArea(pts)
            }
            // Not enough for a polygon — keep waiting.
            return .none
        case .lenPending:
            return measureTotalLength(context)
        case .lenDone:
            return measureTotalLength(context)
        default:
            // Distance / angle (or a finished area) — Return ends the tool.
            reset()
            return .finished
        }
    }

    // MARK: - Backspace handling

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .distSecond, .distDone:
            state = .distFirst
            cursor = .invalid
            return .preview
        case .angFirst, .angDone:
            state = .angVertex
            cursor = .invalid
            return .preview
        case .angSecond(let vertex, _):
            state = .angFirst(vertex: vertex)
            cursor = vertex
            return .preview
        case .areaPicking(var pts):
            guard !pts.isEmpty else { return .none }
            pts.removeLast()
            state = .areaPicking(points: pts)
            return .preview
        case .areaDone:
            state = .areaPicking(points: [])
            cursor = .invalid
            return .preview
        default:
            return .none
        }
    }

    // MARK: - Result computation

    /// Closes the area boundary, computes area + perimeter (shoelace), reports them
    /// via `status`. Read-only — returns `.none` (the HUD redraws from `status`).
    private mutating func closeArea(_ pts: [Vector]) -> ToolOutcome {
        let area = Self.polygonArea(pts)
        let perimeter = Self.polygonPerimeter(pts, closed: true)
        state = .areaDone(area: area, perimeter: perimeter)
        return .none
    }

    /// Reads the current selection, sums each entity's resolved length, reports it.
    private mutating func measureTotalLength(_ context: ToolContext) -> ToolOutcome {
        let entities = context.selected
        let total = entities.reduce(0.0) { $0 + Self.entityLength($1) }
        state = .lenDone(total: total, count: entities.count)
        return .none
    }

    /// Returns to the initial waiting state for the active `mode`.
    private mutating func reset() {
        switch mode {
        case .distance:      state = .distFirst
        case .angle:         state = .angVertex
        case .areaPerimeter: state = .areaPicking(points: [])
        case .totalLength:   state = .lenPending
        }
        cursor = .invalid
    }

    // MARK: - Readout formatting (namespaced statics — CONVENTIONS §7)

    /// Formats a linear quantity via the shared coordinate formatter (decimal,
    /// trailing zeros stripped) so measure readouts match the status-bar coordinate
    /// readout and the dimension labels. Unit-aware formatting is a later pass.
    static func lengthString(_ value: Double) -> String {
        CoordinateFormatter.length(value)
    }

    /// Formats an angle in degrees, trailing zeros stripped, with a `°` suffix.
    static func angleReadout(_ degrees: Double) -> String {
        "\(CoordinateFormatter.length(degrees))°"
    }

    /// The full distance readout line: distance, Δx, Δy, and the connecting angle.
    static func distanceReadout(_ a: Vector, _ b: Vector) -> String {
        let d = a.distance(to: b)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let deg = (b - a).angle * 180 / .pi
        return "Distance: \(lengthString(d))   Δx \(lengthString(dx))   Δy \(lengthString(dy))   Angle \(angleReadout(deg))"
    }

    // MARK: - Geometry (namespaced statics)

    /// The angle (in DEGREES) at `vertex` between the rays vertex→a and vertex→b,
    /// in `[0, 180]` (the unsigned interior angle, like `RS_ActionInfoAngle`). The
    /// rays are assumed non-degenerate (the caller guards coincident picks).
    static func angleBetween(vertex: Vector, a: Vector, b: Vector) -> Double {
        let va = a - vertex
        let vb = b - vertex
        let la = va.magnitude
        let lb = vb.magnitude
        guard la > Tolerance.distance, lb > Tolerance.distance else { return 0 }
        // cos θ = (va · vb) / (|va| |vb|), clamped for float safety.
        let cosTheta = max(-1.0, min(1.0, va.dot(vb) / (la * lb)))
        return acos(cosTheta) * 180 / .pi
    }

    /// Unsigned polygon area via the shoelace formula. The ring is treated as
    /// implicitly closed (the last→first edge is added); it need NOT repeat the
    /// first vertex. Fewer than 3 points has no area (returns 0).
    static func polygonArea(_ ring: [Vector]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let p = ring[i]
            let q = ring[(i + 1) % ring.count]
            sum += p.x * q.y - q.x * p.y
        }
        return abs(sum) / 2
    }

    /// The perimeter of a point chain. When `closed`, the last→first edge is added.
    static func polygonPerimeter(_ ring: [Vector], closed: Bool) -> Double {
        guard ring.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(ring.count - 1) {
            total += ring[i].distance(to: ring[i + 1])
        }
        if closed, let first = ring.first, let last = ring.last {
            total += last.distance(to: first)
        }
        return total
    }

    /// The length of one entity, used by `.totalLength`. Analytic for the common
    /// cases (line / circle / arc); for everything else it resolves the entity to
    /// its tessellated polyline(s) and sums the segment lengths (exact for straight
    /// geometry, tessellation-accurate for curves). A point has zero length.
    static func entityLength(_ record: EntityRecord) -> Double {
        switch record.kind {
        case .point:
            return 0
        case .line(let d):
            return d.start.distance(to: d.end)
        case .circle(let d):
            return 2 * .pi * d.radius
        case .arc(let d):
            return abs(d.radius) * arcSweep(d)
        default:
            // Resolve → sum the resolved polyline lengths (closed rings add the
            // implicit closing edge). Covers polyline (with bulges), ellipse,
            // splines, and any other resolvable kind without special-casing each.
            let geometry = record.resolve()
            return geometry.polylines.reduce(0.0) { acc, poly in
                acc + polygonPerimeter(poly.points, closed: poly.closed)
            }
        }
    }

    /// The (positive) angular sweep of an arc in radians, honoring `reversed`
    /// (clockwise). Mirrors `RS_Arc::getAngleLength`.
    static func arcSweep(_ d: ArcData) -> Double {
        let twoPi = 2 * Double.pi
        var sweep: Double
        if d.reversed {
            // Clockwise: start → end going negative.
            sweep = d.startAngle - d.endAngle
        } else {
            sweep = d.endAngle - d.startAngle
        }
        // Normalize into (0, 2π]; a full circle (start == end) sweeps 2π.
        sweep = sweep.truncatingRemainder(dividingBy: twoPi)
        if sweep <= Tolerance.angle { sweep += twoPi }
        return sweep
    }
}
