//
//  BreakTool.swift
//  CADEngine
//
//  The BREAK modify tool — pick an entity, then a break point (or two points) to
//  split it into two entities at that point, or remove the span BETWEEN two
//  points. Ported in spirit from LibreCAD's `RS_ActionModifyBreakDivide` /
//  `RS_Modification::breakAt` (the "break at a point" / "break two points" family
//  in librecad/src/lib/modification + the divide actions): the entity is cut at
//  the picked location(s) and the result is the surviving piece(s).
//
//  Behavior (pick the entity → pick the break point(s)):
//    - `.click(p)` while picking the entity → TARGET the nearest LINE / ARC /
//                        POLYLINE under the pick (other kinds skipped). Advance to
//                        the "pick first break point" phase.
//    - `.click(p1)` (first break point) → remember the first split location on the
//                        target and advance to the "pick second break point" phase.
//    - `.click(p2)` (second break point):
//                        - if p2 ≈ p1 (a second click at the same spot, or the user
//                          presses Return/commits after the first point) → SPLIT at
//                          a SINGLE point: emit `.remove(original) + .add(piece1) +
//                          .add(piece2)` (the two halves about p1).
//                        - otherwise → REMOVE the span between p1 and p2: emit
//                          `.remove(original) + .add(outerPiece1) + .add(outerPiece2)`
//                          (the two pieces that survive OUTSIDE the [p1,p2] gap). If
//                          a gap end is at/over an original endpoint only one piece
//                          survives (`.remove + .add`).
//    - `.commit` after the first break point → SPLIT at that single point (the
//                        Return shortcut for a one-point break).
//    - `.move`         → preview the surviving piece(s) for the current cursor as a
//                        second break point (once the first point is set).
//    - `.cancel` (Esc) → discard and finish.
//    - `.backspace`    → step back one pick.
//
//  BREAK split geometry (how each kind is cut):
//    - LINE: the split point is PROJECTED onto the segment; the two halves are
//      `(start → split)` and `(split → end)`. A two-point break drops the
//      `[a, b]` middle and keeps `(start → a)` and `(b → end)` (ordered along the
//      segment so the gap is the inner span).
//    - ARC: the split point's ANGLE on the arc's circle splits the sweep; the two
//      sub-arcs are `(startAngle → splitAngle)` and `(splitAngle → endAngle)`
//      taken in the arc's own direction (`reversed` preserved). A two-point break
//      keeps the two outer sub-arcs and drops the inner one between the two split
//      angles. Each surviving sub-arc covers part of the ORIGINAL sweep, so the two
//      pieces of a single-point break together re-cover the original sweep exactly.
//    - POLYLINE: the split point is located on a segment (the vertex index +
//      fractional position via projection); piece #1 is the run of vertices up to
//      the split with the split vertex appended, piece #2 starts at the split vertex
//      and runs to the end. (Bulged segments are split by their straight chord here;
//      true bulge subdivision is a backlog refinement — noted on `splitPolyline`.)
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` (`nearbyEntities` to find the target)
//  plus the snapped world points in `ToolInput`, and computes the split entirely
//  from the entity's defining data. The app applies the `.remove` + `.add` edits
//  (re-minting the new pieces' ids, preserving the original's layer/pen/flags on
//  the copies) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Modification break family).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Break tool. Pick a line / arc / polyline, then a break point
/// to split it into two entities — or a second point to remove the span between
/// them (LibreCAD's modify-break family).
public struct BreakTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from the break-action status integers
    /// (ChooseEntity → SetPoint1 → SetPoint2) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the click that picks the entity to break.
        case pickingEntity
        /// A target is fixed; waiting for the FIRST break point. `record` is the
        /// entity being broken (kept whole so the commit can `.remove` it).
        case pickingFirstPoint(record: EntityRecord)
        /// The first break point is fixed; waiting for the SECOND (or a commit /
        /// repeat-click to split at the single first point).
        case pickingSecondPoint(record: EntityRecord, first: Vector)
    }

    /// The current state. Starts waiting for the entity pick.
    private var state: State = .pickingEntity

    /// The last cursor point seen via `.move`, used to drive the preview once the
    /// first break point is set. Invalid until the first move after that pick.
    private var cursor: Vector = .invalid

    /// The pick aperture in world units used to find the target under the click.
    private let pickTolerance: Double

    /// Creates a Break tool. `pickTolerance` is the world-space aperture used to
    /// find the target entity under the click (default `1e-6`; the app passes its
    /// px-derived tolerance).
    public init(pickTolerance: Double = 1e-6) {
        self.pickTolerance = pickTolerance
    }

    // MARK: - Tool

    public var title: String { "Break" }

    public var status: String {
        switch state {
        case .pickingEntity:
            return "Click a line, arc, or polyline to break"
        case .pickingFirstPoint:
            return "Specify the break point"
        case .pickingSecondPoint:
            return "Specify the second point (or press Return to split at the first)"
        }
    }

    /// The live preview: the surviving piece(s) for the current cursor as a second
    /// break point, with the preview pen. Empty before the first break point is set
    /// or before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .pickingSecondPoint(let record, let first) = state, cursor.valid else {
            return []
        }
        let pieces = Self.breakAt(record.kind, first: first, second: cursor)
        return pieces.flatMap { kind in
            kind.resolve(pen: .toolPreview, ctx: .default).polylines
        }
    }

    /// A MODIFY tool: it reads `context.nearbyEntities` to find the target and, on
    /// the break, emits `.remove(original)` + one `.add` per surviving piece.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value:
            // A typed coordinate doesn't map to Break's entity-pick interaction —
            // ignore (its picks are point-on-entity, fed as `.click`).
            return .none

        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            reset()
            return .finished

        case .commit:
            return handleCommit()
        }
    }

    // MARK: - Click / commit / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .pickingEntity:
            guard let target = nearestTarget(to: p, context: context) else { return .none }
            state = .pickingFirstPoint(record: target)
            cursor = p
            return .none

        case .pickingFirstPoint(let record):
            state = .pickingSecondPoint(record: record, first: p)
            cursor = p
            return .none

        case .pickingSecondPoint(let record, let first):
            // A second click at (≈) the first point splits at the single point;
            // otherwise it removes the span between the two points.
            return commitBreak(record: record, first: first, second: p)
        }
    }

    /// Return: in the second-point phase, split at the single first point.
    private mutating func handleCommit() -> ToolOutcome {
        switch state {
        case .pickingSecondPoint(let record, let first):
            return commitBreak(record: record, first: first, second: first)
        case .pickingEntity, .pickingFirstPoint:
            reset()
            return .finished
        }
    }

    /// Builds the `.remove` + `.add` edits for breaking `record` and resets. A
    /// degenerate break (no surviving piece geometry) commits nothing.
    private mutating func commitBreak(record: EntityRecord, first: Vector, second: Vector) -> ToolOutcome {
        let pieces = Self.breakAt(record.kind, first: first, second: second)
        guard !pieces.isEmpty else { return .none }
        var edits: [ToolEdit] = [.remove(record.id)]
        for kind in pieces {
            edits.append(.add(EntityRecord(
                id: .placeholder,
                layer: record.layer,
                pen: record.pen,
                flags: record.flags,
                kind: kind
            )))
        }
        reset()
        return .commit(edits)
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingEntity:
            return .none
        case .pickingFirstPoint:
            state = .pickingEntity
            cursor = .invalid
            return .none
        case .pickingSecondPoint(let record, _):
            state = .pickingFirstPoint(record: record)
            cursor = .invalid
            return .none
        }
    }

    /// Returns to the initial waiting state, dropping the target / cursor.
    private mutating func reset() {
        state = .pickingEntity
        cursor = .invalid
    }

    // MARK: - Target picking

    /// The nearest LINE / ARC / POLYLINE in the pick aperture, by EXACT distance to
    /// `p`. Other kinds are ignored (scope: line / arc / polyline).
    private func nearestTarget(to p: Vector, context: ToolContext) -> EntityRecord? {
        context.nearbyEntities(p, pickTolerance)
            .filter { Self.isSupported($0.kind) }
            .min { HitTesting.worldDistance(from: p, to: $0) < HitTesting.worldDistance(from: p, to: $1) }
    }

    /// Whether `kind` is a target Break can act on (line / arc / polyline).
    static func isSupported(_ kind: EntityKind) -> Bool {
        switch kind {
        case .line, .arc, .polyline: return true
        // TODO(backlog): break circles (→ arc), ellipses, splines.
        case .circle, .ellipse, .spline, .splinePoints, .point,
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .image:
            return false
        }
    }

    // MARK: - Break geometry (pure, self-contained)

    /// Computes the surviving piece(s) of breaking `kind`:
    ///   - `first ≈ second` → SPLIT at the single point → the two halves about it.
    ///   - else             → REMOVE the inner span `[first, second]` → the two
    ///                         outer pieces (or one, if a span end is at an endpoint).
    /// Returns `[]` when the break is degenerate (e.g. the point is off the entity,
    /// or a half would be zero-length).
    static func breakAt(_ kind: EntityKind, first: Vector, second: Vector) -> [EntityKind] {
        guard first.valid else { return [] }
        let singlePoint = !second.valid || first.distance(to: second) <= Tolerance.distance

        switch kind {
        case .line(let d):
            return singlePoint ? splitLine(d, at: first) : breakLineSpan(d, a: first, b: second)
        case .arc(let d):
            return singlePoint ? splitArc(d, at: first) : breakArcSpan(d, a: first, b: second)
        case .polyline(let d):
            return singlePoint ? splitPolyline(d, at: first) : breakPolylineSpan(d, a: first, b: second)
        default:
            return []
        }
    }

    // MARK: - Line break

    /// Splits a line at the projection of `p` onto the segment into `(start→split)`
    /// and `(split→end)`. Returns `[]` if the split lands at (or past) an endpoint.
    static func splitLine(_ d: LineData, at p: Vector) -> [EntityKind] {
        guard let split = projectOntoSegment(p, d.start, d.end) else { return [] }
        let h1 = (split - d.start).squared > Tolerance.distanceSquared
        let h2 = (d.end - split).squared > Tolerance.distanceSquared
        guard h1, h2 else { return [] }
        return [.line(LineData(start: d.start, end: split)),
                .line(LineData(start: split, end: d.end))]
    }

    /// Removes the inner span between `a` and `b` on a line, keeping the two outer
    /// pieces. The two gap points are ordered along the segment so the dropped span
    /// is the inner one.
    static func breakLineSpan(_ d: LineData, a: Vector, b: Vector) -> [EntityKind] {
        guard let pa = projectOntoSegment(a, d.start, d.end),
              let pb = projectOntoSegment(b, d.start, d.end) else { return [] }
        // Order by parameter along start→end.
        let dir = d.end - d.start
        let len2 = dir.squared
        guard len2 > Tolerance.distanceSquared else { return [] }
        let ta = (pa - d.start).dot(dir) / len2
        let tb = (pb - d.start).dot(dir) / len2
        let (lo, hi) = ta <= tb ? (pa, pb) : (pb, pa)

        var pieces: [EntityKind] = []
        if (lo - d.start).squared > Tolerance.distanceSquared {
            pieces.append(.line(LineData(start: d.start, end: lo)))
        }
        if (d.end - hi).squared > Tolerance.distanceSquared {
            pieces.append(.line(LineData(start: hi, end: d.end)))
        }
        return pieces
    }

    // MARK: - Arc break

    /// Splits an arc at the angle of `p` on its circle into the two sub-arcs
    /// `(startAngle → splitAngle)` and `(splitAngle → endAngle)`, taken in the
    /// arc's own direction. Returns `[]` if the split angle is not strictly inside
    /// the sweep (a half would be zero-length).
    static func splitArc(_ d: ArcData, at p: Vector) -> [EntityKind] {
        guard d.radius > Tolerance.distance else { return [] }
        let split = (p - d.center).angle
        let g1 = MathUtils.getAngleDifference(d.startAngle, split, reversed: d.reversed)
        let g2 = MathUtils.getAngleDifference(split, d.endAngle, reversed: d.reversed)
        guard g1 > Tolerance.angle, g2 > Tolerance.angle else { return [] }
        return [.arc(ArcData(center: d.center, radius: d.radius,
                             startAngle: d.startAngle, endAngle: split, reversed: d.reversed)),
                .arc(ArcData(center: d.center, radius: d.radius,
                             startAngle: split, endAngle: d.endAngle, reversed: d.reversed))]
    }

    /// Removes the inner sub-arc between the angles of `a` and `b`, keeping the two
    /// outer sub-arcs. The two split angles are ordered along the sweep so the
    /// dropped span is the inner one.
    static func breakArcSpan(_ d: ArcData, a: Vector, b: Vector) -> [EntityKind] {
        guard d.radius > Tolerance.distance else { return [] }
        let aa = (a - d.center).angle
        let ab = (b - d.center).angle
        // Sweep offset from start to each split angle (in the arc's direction).
        let oa = MathUtils.getAngleDifference(d.startAngle, aa, reversed: d.reversed)
        let ob = MathUtils.getAngleDifference(d.startAngle, ab, reversed: d.reversed)
        let (loAng, hiAng) = oa <= ob ? (aa, ab) : (ab, aa)

        var pieces: [EntityKind] = []
        if MathUtils.getAngleDifference(d.startAngle, loAng, reversed: d.reversed) > Tolerance.angle {
            pieces.append(.arc(ArcData(center: d.center, radius: d.radius,
                                       startAngle: d.startAngle, endAngle: loAng, reversed: d.reversed)))
        }
        if MathUtils.getAngleDifference(hiAng, d.endAngle, reversed: d.reversed) > Tolerance.angle {
            pieces.append(.arc(ArcData(center: d.center, radius: d.radius,
                                       startAngle: hiAng, endAngle: d.endAngle, reversed: d.reversed)))
        }
        return pieces
    }

    // MARK: - Polyline break

    /// Splits a polyline at `p` into two open polylines: vertices up to the split
    /// (with the split vertex appended) and from the split vertex to the end.
    ///
    /// NOTE: bulged segments are split by their STRAIGHT chord here (the split
    /// vertex inherits a zero bulge and the segment's own bulge is dropped on the
    /// cut). True bulge subdivision (recomputing the two sub-arc bulges) is a
    /// backlog refinement; for straight polylines (the common case) this is exact.
    /// A closed polyline is opened by the break (the result pieces are open).
    static func splitPolyline(_ d: PolylineData, at p: Vector) -> [EntityKind] {
        guard let loc = locateOnPolyline(d, point: p) else { return [] }
        let verts = polylineVerticesForBreak(d)
        guard verts.count >= 2 else { return [] }

        let i = loc.segment
        let split = PolylineVertex(point: loc.point, bulge: 0)

        // Piece 1: vertices [0...i] + split (cap the segment i's bulge at the cut).
        var first = Array(verts[0...i])
        // The segment leaving vertex i is cut, so its bulge no longer applies.
        first[i].bulge = 0
        first.append(split)

        // Piece 2: split + vertices [i+1 ... end].
        var second: [PolylineVertex] = [split]
        second.append(contentsOf: verts[(i + 1)...])

        var pieces: [EntityKind] = []
        if first.count >= 2, polylineLength(first) > Tolerance.distance {
            pieces.append(.polyline(PolylineData(vertices: first, closed: false)))
        }
        if second.count >= 2, polylineLength(second) > Tolerance.distance {
            pieces.append(.polyline(PolylineData(vertices: second, closed: false)))
        }
        return pieces
    }

    /// Removes the inner span between `a` and `b` on a polyline, keeping the two
    /// outer open polylines (start→a) and (b→end). The two locations are ordered
    /// along the polyline so the dropped span is the inner one.
    static func breakPolylineSpan(_ d: PolylineData, a: Vector, b: Vector) -> [EntityKind] {
        guard let la = locateOnPolyline(d, point: a),
              let lb = locateOnPolyline(d, point: b) else { return [] }
        let verts = polylineVerticesForBreak(d)
        guard verts.count >= 2 else { return [] }

        // Order the two break locations along the polyline (segment index, then
        // fractional position within the segment).
        let (lo, hi) = orderedLocations(la, lb)

        // Piece 1: vertices [0...lo.segment] + lo.point.
        var first = Array(verts[0...lo.segment])
        first[lo.segment].bulge = 0
        first.append(PolylineVertex(point: lo.point, bulge: 0))

        // Piece 2: hi.point + vertices [hi.segment+1 ... end].
        var second: [PolylineVertex] = [PolylineVertex(point: hi.point, bulge: 0)]
        second.append(contentsOf: verts[(hi.segment + 1)...])

        var pieces: [EntityKind] = []
        if first.count >= 2, polylineLength(first) > Tolerance.distance {
            pieces.append(.polyline(PolylineData(vertices: first, closed: false)))
        }
        if second.count >= 2, polylineLength(second) > Tolerance.distance {
            pieces.append(.polyline(PolylineData(vertices: second, closed: false)))
        }
        return pieces
    }

    // MARK: - Geometry helpers

    /// Projects `p` onto the finite segment `(s, e)`, clamped to the segment, or
    /// `nil` for a degenerate segment.
    static func projectOntoSegment(_ p: Vector, _ s: Vector, _ e: Vector) -> Vector? {
        let dir = e - s
        let len2 = dir.squared
        guard len2 > Tolerance.distanceSquared else { return nil }
        let u = Swift.min(1, Swift.max(0, (p - s).dot(dir) / len2))
        return s + dir * u
    }

    /// A located point on a polyline: which segment (vertex index it leaves), the
    /// fractional position `t ∈ [0,1]` within that segment, and the projected point.
    struct PolylineLocation {
        let segment: Int
        let t: Double
        let point: Vector
    }

    /// The polyline's vertex list as the renderer treats it for breaking — for a
    /// CLOSED polyline the implicit wrap segment is materialized by appending the
    /// first vertex, so a break can land on the closing edge and the pieces are
    /// well-formed open polylines.
    static func polylineVerticesForBreak(_ d: PolylineData) -> [PolylineVertex] {
        guard d.closed, let firstVert = d.vertices.first, d.vertices.count >= 2 else {
            return d.vertices
        }
        return d.vertices + [PolylineVertex(point: firstVert.point, bulge: 0)]
    }

    /// Finds the location of `p` on the polyline (nearest segment by the straight
    /// chord), or `nil` if the polyline has no segments.
    static func locateOnPolyline(_ d: PolylineData, point p: Vector) -> PolylineLocation? {
        let verts = polylineVerticesForBreak(d)
        guard verts.count >= 2 else { return nil }
        var best: PolylineLocation?
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0..<(verts.count - 1) {
            let s = verts[i].point, e = verts[i + 1].point
            let dir = e - s
            let len2 = dir.squared
            guard len2 > Tolerance.distanceSquared else { continue }
            let t = Swift.min(1, Swift.max(0, (p - s).dot(dir) / len2))
            let proj = s + dir * t
            let dist = proj.distance(to: p)
            if dist < bestDist {
                bestDist = dist
                best = PolylineLocation(segment: i, t: t, point: proj)
            }
        }
        return best
    }

    /// Orders two polyline locations along the polyline (segment, then `t`).
    static func orderedLocations(_ a: PolylineLocation, _ b: PolylineLocation) -> (PolylineLocation, PolylineLocation) {
        if a.segment != b.segment { return a.segment < b.segment ? (a, b) : (b, a) }
        return a.t <= b.t ? (a, b) : (b, a)
    }

    /// The straight-chord length of a vertex run (used to reject zero-length
    /// pieces).
    static func polylineLength(_ verts: [PolylineVertex]) -> Double {
        guard verts.count >= 2 else { return 0 }
        var len = 0.0
        for i in 0..<(verts.count - 1) {
            len += verts[i].point.distance(to: verts[i + 1].point)
        }
        return len
    }
}
