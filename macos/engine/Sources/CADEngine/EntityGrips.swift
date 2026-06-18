//
//  EntityGrips.swift
//  CADEngine
//
//  Pure, UI-free grip-editing math for a single entity — the engine sibling of
//  `GizmoTransform`. Where the gizmo manipulates a WHOLE selection by an affine
//  transform, GRIPS edit ONE entity's defining geometry directly: the small square
//  handles drawn at an entity's characteristic points (a line's endpoints, a
//  circle's quadrants, a polyline's vertices, …). Dragging a grip reshapes that
//  one entity — a line endpoint follows the cursor while the other end stays put, a
//  circle quadrant sets a new radius about the fixed center, a polyline vertex
//  moves while its neighbours (and every bulge) are preserved.
//
//  ## THE CONTRACT (stable public API — the overlay/mount consume ONLY these)
//
//  This file is the single, testable source of truth for grip editing. The
//  view-layer overlay (`EntityGripOverlay`) + its `CanvasModel` mount carry NO
//  geometry math — they only:
//    1. call `EntityGrips.grips(for:ctx:)` to know WHERE to draw the handles and
//       what each handle's `role` is (for cursor/affordance), and
//    2. call `EntityGrips.moveGrip(_:of:to:ctx:)` on drag to get a NEW
//       `EntityRecord` to route through the existing undoable commit path.
//
//  The PUBLIC surface is intentionally tiny and frozen:
//    • `GripPoint`  — { index, world, role }
//    • `GripRole`   — the handle's semantic class (for the overlay's affordance)
//    • `EntityGrips.grips(for:ctx:) -> [GripPoint]`           (read-only query)
//    • `EntityGrips.moveGrip(_:of:to:ctx:) -> EntityRecord?`  (the solver)
//
//  `GripPoint.index` is the STABLE handle index for an entity's current geometry:
//  `grips(for:)[i].index == i`, and `moveGrip(i, …)` edits exactly that handle.
//  Indices are positional (they shift if the entity's vertex count changes), so
//  the overlay must re-query `grips(for:)` after any commit — it never caches an
//  index across an edit.
//
//  ## DESIGN
//
//  - `grips(for:ctx:)` is a READ-ONLY `switch` on `record.kind` (NO new
//    `EntityKind` case — adding a kind is a serialized critical section, and grips
//    only READ the existing geometry). Kinds without meaningful per-point grips
//    (hatch / solid / dimension / insert / image / ray / xline / leader / mtext)
//    return `[]` — the gizmo/Move tool handles those en bloc; per-point grip
//    editing of their internals is out of scope (documented per-arm below).
//  - `moveGrip` REUSES the existing geometry kernels (`ArcTool.arcThrough` for arc
//    re-fitting, the `EllipseData`/`*Data` structs, `Vector` math) — it does not
//    re-derive circle/arc/ellipse math sloppily.
//
//  PURE (ADR-001/-003): value types, f64, no GUI/Metal/AppKit/app-module import.
//  Unit-tested in `EntityGripsTests`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (RS_* grip/handle semantics reused).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Grip role + point

/// The semantic class of a grip handle — what characteristic point it sits on.
/// The overlay uses this only for the drawn AFFORDANCE (handle glyph / hover
/// cursor / tooltip); the EDIT behaviour is keyed off the grip's `index` via
/// `moveGrip`, never off the role. Carried so the overlay can, e.g., draw a
/// hollow square for a midpoint vs. a filled square for an endpoint.
public enum GripRole: Sendable, Equatable, Hashable {
    /// An endpoint of an open curve (a line/arc/elliptic-arc end, a spline end).
    case endpoint
    /// A midpoint handle (a line's middle, an arc's mid-sweep point). Often a
    /// "move the whole entity" affordance in CAD UIs (LibreCAD's middle grip).
    case midpoint
    /// A center handle (circle/arc/ellipse center). Dragging it MOVES the whole
    /// entity (translates it) rather than reshaping it.
    case center
    /// A circle/ellipse axis or quadrant handle — dragging resizes that axis.
    case quadrant
    /// A polyline / closed-shape vertex.
    case vertex
    /// A spline/NURBS control point (or a `.splinePoints` fit/Bézier point).
    case controlPoint
    /// An insertion / anchor point (text/mtext insertion, a point entity).
    case insertion
    /// A grip whose role doesn't fit the above (reserved; currently unused).
    case other
}

/// One grip handle on an entity: its stable `index`, its current `world`
/// position, and its semantic `role`. `index` is what `moveGrip` takes — for the
/// array returned by `grips(for:)`, `grips[i].index == i`.
public struct GripPoint: Sendable, Equatable, Hashable {
    /// The stable handle index for `moveGrip(_:of:to:ctx:)`. Positional within the
    /// entity's current geometry (re-query after any edit; never cache across one).
    public var index: Int
    /// The handle's current world position (f64, Y-up).
    public var world: Vector
    /// The handle's semantic class (for the overlay's drawn affordance only).
    public var role: GripRole

    public init(index: Int, world: Vector, role: GripRole) {
        self.index = index
        self.world = world
        self.role = role
    }
}

// MARK: - EntityGrips (the pure grip kernel)

/// Pure grip-editing math for a single entity — the read-only `grips(for:)` query
/// + the `moveGrip(_:of:to:)` solver. Static members of a namespaced `enum`
/// (CONVENTIONS.md: no module-scope free functions in a fan-out target).
///
/// This is the CONTRACT the `EntityGripOverlay` + its `CanvasModel` mount build
/// against; keep the public surface (`grips` / `moveGrip` + `GripPoint`/`GripRole`)
/// minimal and stable.
public enum EntityGrips {

    // MARK: - Query: grips(for:ctx:)

    /// The grip handles for `record`, in stable index order, or `[]` for a kind
    /// with no per-point grips. The view draws a handle at each `world` position
    /// and uses `role` for the affordance; it edits via `moveGrip(_:of:to:ctx:)`.
    ///
    /// Per-kind coverage (index → role):
    /// - **line**    : `0` start (endpoint), `1` end (endpoint), `2` mid (midpoint).
    /// - **circle**  : `0` center, then `1..4` quadrants at 0°/90°/180°/270°
    ///   (E, N, W, S) — `quadrant` role.
    /// - **arc**     : `0` center, `1` start (endpoint), `2` end (endpoint),
    ///   `3` mid-sweep (midpoint).
    /// - **polyline**: one `vertex` grip per stored vertex, in vertex order.
    /// - **ellipse** : `0` center, `1`/`2` the two major-axis endpoints
    ///   (`+majorP`/`−majorP`, `quadrant`), `3`/`4` the two minor-axis endpoints
    ///   (`quadrant`). For an elliptic ARC the same five are emitted (axis grips,
    ///   not the arc ends — the axis grips fully define the conic).
    /// - **spline**  : one `controlPoint` grip per control point, in order.
    /// - **splinePoints**: one `controlPoint` grip per (quadratic-Bézier) control
    ///   point, in order.
    /// - **point**   : `0` the point position (`insertion`).
    /// - **text**    : `0` the insertion point (`insertion`).
    /// - **mtext / hatch / solid / dimension / insert / xline / ray / leader /
    ///   image**: `[]` (no per-point grips — the gizmo/Move tool moves them en
    ///   bloc; per-point editing of their internals is out of scope here).
    public static func grips(for record: EntityRecord, ctx: ResolveContext) -> [GripPoint] {
        switch record.kind {
        case .point(let p):
            return [GripPoint(index: 0, world: p.position, role: .insertion)]

        case .line(let l):
            let mid = (l.start + l.end) * 0.5
            return [
                GripPoint(index: 0, world: l.start, role: .endpoint),
                GripPoint(index: 1, world: l.end,   role: .endpoint),
                GripPoint(index: 2, world: mid,     role: .midpoint),
            ]

        case .circle(let c):
            return circleGrips(c)

        case .arc(let a):
            return arcGrips(a)

        case .polyline(let pl):
            return pl.vertices.enumerated().map { i, v in
                GripPoint(index: i, world: v.point, role: .vertex)
            }

        case .ellipse(let e):
            return ellipseGrips(e)

        case .spline(let s):
            return s.controlPoints.enumerated().map { i, p in
                GripPoint(index: i, world: p, role: .controlPoint)
            }

        case .splinePoints(let sp):
            return sp.controlPoints.enumerated().map { i, p in
                GripPoint(index: i, world: p, role: .controlPoint)
            }

        case .text(let t):
            return [GripPoint(index: 0, world: t.position, role: .insertion)]

        // No per-point grips — moved en bloc by the gizmo / Move tool. (mtext's
        // insertion grip is intentionally omitted: mtext layout is owned by its
        // attachment + rect, not a single draggable point in this wave.)
        case .mtext, .hatch, .solid, .dimension, .insert,
             .xline, .ray, .leader, .multileader, .image, .wipeout, .mline:
            return []
        }
    }

    /// Circle grips: center (index 0) + four quadrant points E/N/W/S (1..4).
    private static func circleGrips(_ c: CircleData) -> [GripPoint] {
        let r = c.radius
        return [
            GripPoint(index: 0, world: c.center, role: .center),
            GripPoint(index: 1, world: c.center + Vector(r, 0),  role: .quadrant),   // E (0°)
            GripPoint(index: 2, world: c.center + Vector(0, r),  role: .quadrant),   // N (90°)
            GripPoint(index: 3, world: c.center + Vector(-r, 0), role: .quadrant),   // W (180°)
            GripPoint(index: 4, world: c.center + Vector(0, -r), role: .quadrant),   // S (270°)
        ]
    }

    /// Arc grips: center (0) + start (1) + end (2) + mid-sweep (3).
    private static func arcGrips(_ a: ArcData) -> [GripPoint] {
        let start = arcPoint(a, angle: a.startAngle)
        let end   = arcPoint(a, angle: a.endAngle)
        let mid   = arcPoint(a, angle: arcMidAngle(a))
        return [
            GripPoint(index: 0, world: a.center, role: .center),
            GripPoint(index: 1, world: start,    role: .endpoint),
            GripPoint(index: 2, world: end,      role: .endpoint),
            GripPoint(index: 3, world: mid,      role: .midpoint),
        ]
    }

    /// Ellipse grips: center (0) + the two major-axis endpoints (1/2) + the two
    /// minor-axis endpoints (3/4). The minor pair is cheap (a 90° rotation of the
    /// major direction scaled by `ratio`), so it's always included.
    private static func ellipseGrips(_ e: EllipseData) -> [GripPoint] {
        let major = e.majorP                            // center→major endpoint
        // Minor axis = major rotated +90°, scaled by ratio.
        let minor = Vector(-major.y, major.x) * e.ratio
        return [
            GripPoint(index: 0, world: e.center,         role: .center),
            GripPoint(index: 1, world: e.center + major, role: .quadrant),
            GripPoint(index: 2, world: e.center - major, role: .quadrant),
            GripPoint(index: 3, world: e.center + minor, role: .quadrant),
            GripPoint(index: 4, world: e.center - minor, role: .quadrant),
        ]
    }

    // MARK: - Solver: moveGrip(_:of:to:ctx:)

    /// Returns a NEW `EntityRecord` with grip `index` of `record` moved to `world`,
    /// or `nil` if that grip/index is not editable (an out-of-range index, a
    /// non-grip kind, or a degenerate result — e.g. a circle quadrant dragged onto
    /// the center, leaving no finite radius). The returned record keeps the entity's
    /// id/layer/pen/flags/space/layout — only the geometry (`kind`) changes.
    ///
    /// Per-kind edit semantics:
    /// - **line**    : index `0`/`1` drags that endpoint (the other end fixed);
    ///   index `2` (mid) TRANSLATES the whole line so its midpoint lands on `world`.
    /// - **circle**  : index `0` (center) MOVES the circle; a quadrant index
    ///   (`1..4`) sets a NEW radius = `|world − center|` about the fixed center.
    /// - **arc**     : index `0` (center) MOVES the arc; index `1`/`2` re-fits the
    ///   arc through the moved end, the fixed other end, and the (unchanged) old
    ///   mid-sweep point (`ArcTool.arcThrough`); index `3` (mid) re-fits through the
    ///   fixed start, the moved mid, and the fixed end.
    /// - **polyline**: index `i` moves vertex `i` to `world`, PRESERVING every
    ///   vertex's bulge (and the closed flag).
    /// - **ellipse** : index `0` (center) MOVES the ellipse; index `1`/`2` sets a
    ///   new MAJOR axis (the dragged endpoint defines `majorP`, keeping the minor
    ///   radius absolute so `ratio` re-derives); index `3`/`4` sets a new MINOR
    ///   radius (keeping the major axis), updating `ratio`.
    /// - **spline / splinePoints**: index `i` moves control point `i` to `world`.
    /// - **point**   : index `0` moves the point.
    /// - **text**    : index `0` moves the insertion point.
    /// - everything else → `nil`.
    public static func moveGrip(
        _ index: Int,
        of record: EntityRecord,
        to world: Vector,
        ctx: ResolveContext
    ) -> EntityRecord? {
        guard world.valid else { return nil }
        guard let newKind = movedKind(index, of: record.kind, to: world) else {
            return nil
        }
        var out = record
        out.kind = newKind
        return out
    }

    /// The geometry-only half of `moveGrip` (returns a new `EntityKind` or `nil`).
    /// Split out so the record wrapper (id/layer/pen/…) is preserved in one place.
    private static func movedKind(_ index: Int, of kind: EntityKind, to world: Vector) -> EntityKind? {
        switch kind {
        case .point(let p):
            guard index == 0 else { return nil }
            return .point(PointData(position: world, style: p.style))

        case .line(let l):
            switch index {
            case 0: return .line(LineData(start: world, end: l.end))
            case 1: return .line(LineData(start: l.start, end: world))
            case 2:                                   // mid → translate the whole line
                let mid = (l.start + l.end) * 0.5
                let delta = world - mid
                return .line(LineData(start: l.start + delta, end: l.end + delta))
            default: return nil
            }

        case .circle(let c):
            return movedCircle(c, index: index, to: world).map { .circle($0) }

        case .arc(let a):
            return movedArc(a, index: index, to: world).map { .arc($0) }

        case .polyline(let pl):
            guard pl.vertices.indices.contains(index) else { return nil }
            var verts = pl.vertices
            // Preserve the moved vertex's OWN bulge (and every other vertex/bulge).
            verts[index] = PolylineVertex(point: world, bulge: verts[index].bulge)
            return .polyline(PolylineData(vertices: verts, closed: pl.closed))

        case .ellipse(let e):
            return movedEllipse(e, index: index, to: world).map { .ellipse($0) }

        case .spline(let s):
            guard s.controlPoints.indices.contains(index) else { return nil }
            var cps = s.controlPoints
            cps[index] = world
            return .spline(SplineData(degree: s.degree, controlPoints: cps,
                                      knots: s.knots, weights: s.weights, closed: s.closed))

        case .splinePoints(let sp):
            guard sp.controlPoints.indices.contains(index) else { return nil }
            var cps = sp.controlPoints
            cps[index] = world
            return .splinePoints(SplinePointsData(controlPoints: cps, closed: sp.closed))

        case .text(let t):
            guard index == 0 else { return nil }
            var nt = t
            nt.position = world
            return .text(nt)

        // No per-point grips → not grip-editable.
        case .mtext, .hatch, .solid, .dimension, .insert,
             .xline, .ray, .leader, .multileader, .image, .wipeout, .mline:
            return nil
        }
    }

    /// Circle grip move: center (0) translates; a quadrant (1..4) sets the radius.
    private static func movedCircle(_ c: CircleData, index: Int, to world: Vector) -> CircleData? {
        switch index {
        case 0:
            return CircleData(center: world, radius: c.radius)
        case 1, 2, 3, 4:
            let r = (world - c.center).magnitude
            guard r > Tolerance.distance else { return nil }
            return CircleData(center: c.center, radius: r)
        default:
            return nil
        }
    }

    /// Arc grip move: center (0) translates; start (1)/end (2)/mid (3) re-fit the
    /// arc through the moved point + the two fixed others via `ArcTool.arcThrough`.
    private static func movedArc(_ a: ArcData, index: Int, to world: Vector) -> ArcData? {
        switch index {
        case 0:                                       // center → translate the arc
            return ArcData(center: world, radius: a.radius,
                           startAngle: a.startAngle, endAngle: a.endAngle, reversed: a.reversed)
        case 1, 2, 3:
            let start = arcPoint(a, angle: a.startAngle)
            let end   = arcPoint(a, angle: a.endAngle)
            let mid   = arcPoint(a, angle: arcMidAngle(a))
            // Re-fit the arc through the THREE characteristic points with one moved.
            // `arcThrough(start, mid, end)` orients the sweep to pass through `mid`,
            // exactly the arc-creation 3-point fitter (no duplicated math).
            let s = (index == 1) ? world : start
            let m = (index == 3) ? world : mid
            let e = (index == 2) ? world : end
            return ArcTool.arcThrough(s, m, e)
        default:
            return nil
        }
    }

    /// Ellipse grip move: center (0) translates; a major endpoint (1/2) sets a new
    /// major axis (preserving the absolute minor radius); a minor endpoint (3/4)
    /// sets a new minor radius (preserving the major axis), updating `ratio`.
    private static func movedEllipse(_ e: EllipseData, index: Int, to world: Vector) -> EllipseData? {
        switch index {
        case 0:                                       // center → translate
            return EllipseData(center: world, majorP: e.majorP, ratio: e.ratio,
                               startAngle: e.startAngle, endAngle: e.endAngle, reversed: e.reversed)

        case 1, 2:
            // New major axis: index 1 is the +majorP endpoint, index 2 the −majorP.
            // The dragged point fixes the major axis direction + length; we KEEP the
            // absolute minor radius (so the conic's shorter axis doesn't jump) and
            // re-derive `ratio = minorRadius / newMajorRadius`.
            let oldMinor = e.minorRadius
            var newMajorP = world - e.center
            if index == 2 { newMajorP = -newMajorP }   // dragged the −major endpoint
            let newMajorR = newMajorP.magnitude
            guard newMajorR > Tolerance.distance else { return nil }
            let newRatio = oldMinor / newMajorR
            return EllipseData(center: e.center, majorP: newMajorP, ratio: newRatio,
                               startAngle: e.startAngle, endAngle: e.endAngle, reversed: e.reversed)

        case 3, 4:
            // New minor radius from the dragged minor endpoint: project onto the
            // minor-axis direction (major rotated +90°) so an off-axis cursor still
            // gives a well-defined minor length. Major axis (majorP) is unchanged;
            // only `ratio` updates.
            let majorR = e.majorRadius
            guard majorR > Tolerance.distance else { return nil }
            let minorDir = Vector(-e.majorP.y, e.majorP.x) / majorR   // unit ⟂ major
            let newMinorR = abs((world - e.center).dot(minorDir))
            guard newMinorR > Tolerance.distance else { return nil }
            let newRatio = newMinorR / majorR
            return EllipseData(center: e.center, majorP: e.majorP, ratio: newRatio,
                               startAngle: e.startAngle, endAngle: e.endAngle, reversed: e.reversed)

        default:
            return nil
        }
    }

    // MARK: - Arc angle helpers (shared by grips + solver)

    /// The world point on `a` at parametric `angle` (`center + r·(cos,sin)`).
    private static func arcPoint(_ a: ArcData, angle: Double) -> Vector {
        a.center + Vector.polar(radius: abs(a.radius), angle: angle)
    }

    /// The mid-SWEEP angle of `a` — the angle halfway along the actual drawn sweep
    /// (honoring `reversed`), so the mid grip sits ON the arc. `getAngleDifference`
    /// gives the swept extent from start→end in the sweep direction; half of that,
    /// applied in the sweep sense, is the mid angle.
    private static func arcMidAngle(_ a: ArcData) -> Double {
        let sweep = MathUtils.getAngleDifference(a.startAngle, a.endAngle, reversed: a.reversed)
        // `reversed` sweeps clockwise (decreasing angle); otherwise CCW.
        let half = a.reversed ? -sweep * 0.5 : sweep * 0.5
        return Vector.correctAngle(a.startAngle + half)
    }
}
