//
//  SnapGeometry.swift
//  CADEngine
//
//  Analytic geometry kernels for the *constructive* object-snap modes
//  (perpendicular, tangent, parallel) that need a reference ("from") point in
//  addition to the cursor. These mirror LibreCAD's RS2::SnapMode constructive
//  snaps (RS_Snapper + RS_*::getNearestPointOnEntity / tangent helpers) but are
//  expressed as small, primitive-parameter static functions (never an entity
//  enum) so they stay testable in isolation — same shape as `Geometry2D`.
//
//  Conventions match the rest of the engine:
//  - f64 throughout (ADR-003); all inputs/outputs are WORLD units.
//  - `Vector.invalid` is the pervasive "no result" sentinel.
//  - Angles are radians; `reversed == true` is LibreCAD's clockwise arc sweep.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper / RS2::SnapMode and
//  the RS_Line / RS_Circle / RS_Arc / RS_Ellipse perpendicular & tangent math).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// Analytic kernels for the constructive snap modes (perpendicular / tangent /
/// parallel). Static members of an `enum` per CONVENTIONS.md (no module-scope
/// free functions); each takes primitive parameters so they unit-test cleanly.
public enum SnapGeometry {

    // MARK: - Perpendicular foot

    /// The foot of the perpendicular dropped from `from` onto the **infinite**
    /// line through `a → b`. This is the orthogonal projection of `from` onto the
    /// line (NOT clamped to the segment): the point `p` on the line such that
    /// `(p - from) ⟂ (b - a)`. Returns `.invalid` for a degenerate segment.
    ///
    /// Mirrors `RS_Line::getNearestPointOnEntity(..., onEntity:false)` used by the
    /// perpendicular snap: the perpendicular snap projects onto the carrier line,
    /// then the caller may reject feet that fall outside the finite segment.
    public static func perpendicularFootOnLine(from: Vector, a: Vector, b: Vector) -> Vector {
        let d = b - a
        let len2 = d.squared
        guard len2 > Tolerance.distanceSquared, from.valid else { return .invalid }
        let t = (from - a).dot(d) / len2
        return a + d * t
    }

    /// The foot of the perpendicular dropped from `from` onto the **finite**
    /// segment `[a, b]`, i.e. the projection clamped to the segment endpoints.
    /// Returns `.invalid` for a degenerate segment / invalid input.
    public static func perpendicularFootOnSegment(from: Vector, a: Vector, b: Vector) -> Vector {
        let foot = perpendicularFootOnLine(from: from, a: a, b: b)
        guard foot.valid else { return .invalid }
        let d = b - a
        let len2 = d.squared
        let t = Swift.min(1.0, Swift.max(0.0, (foot - a).dot(d) / len2))
        return a + d * t
    }

    /// The foot(s) of the perpendicular from `from` onto a **circle** `(center,
    /// radius)`. For a circle the perpendicular to the curve is the radial line,
    /// so the perpendicular feet are exactly the two radial intersections of the
    /// line `center → from` with the circle (near and far). Returns both, near
    /// first; the caller usually keeps whichever is closest to the cursor.
    ///
    /// For `from` at the center the radial direction is undefined → `[]`.
    public static func perpendicularFeetOnCircle(from: Vector, center: Vector, radius: Double) -> [Vector] {
        guard from.valid else { return [] }
        let d = from - center
        let len = d.magnitude
        guard len > Tolerance.distance else { return [] }   // from == center: undefined
        let r = abs(radius)
        let u = d * (1.0 / len)                              // unit radial direction
        let near = center + u * r
        let far  = center - u * r
        return [near, far]
    }

    /// The perpendicular feet from `from` onto a circular **arc**, restricted to
    /// the arc's angular sweep. Same radial construction as the circle, then each
    /// candidate is kept only if its angle is within `[startAngle, endAngle]`
    /// (respecting `reversed`).
    public static func perpendicularFeetOnArc(from: Vector,
                                              center: Vector, radius: Double,
                                              startAngle: Double, endAngle: Double,
                                              reversed: Bool) -> [Vector] {
        perpendicularFeetOnCircle(from: from, center: center, radius: abs(radius)).filter { p in
            let ang = (p - center).angle
            return MathUtils.isAngleBetween(ang, startAngle, endAngle, reversed: reversed)
        }
    }

    // MARK: - Tangent points

    /// The tangent point(s) on a **circle** `(center, radius)` for the tangent
    /// lines drawn from the external point `from`. There are two for a point
    /// strictly outside the circle, one (the point itself) for a point on the
    /// circle, and none for a point strictly inside.
    ///
    /// Geometry: the tangent point `T` satisfies `(T - center) ⟂ (T - from)`, so
    /// `T` lies on the circle of diameter `[center, from]` (Thales) intersected
    /// with the given circle. Equivalently, with `dist = |from - center|`, the
    /// tangent length is `√(dist² - r²)` and the tangent points are at angle
    /// `±α` off the `center → from` direction where `cos α = r / dist`.
    ///
    /// Each returned point `T` is guaranteed to satisfy the tangency condition
    /// (radius `center → T` is orthogonal to the tangent line `from → T`).
    public static func tangentPointsOnCircle(from: Vector, center: Vector, radius: Double) -> [Vector] {
        guard from.valid else { return [] }
        let r = abs(radius)
        guard r > Tolerance.distance else { return [] }
        let d = from - center
        let dist = d.magnitude
        // Inside the circle → no real tangent from this point.
        if dist < r - Tolerance.distance { return [] }
        let base = d.angle                                  // angle of center → from
        // Point on the circle: a single tangent at the point itself.
        if dist <= r + Tolerance.distance {
            return [center + Vector.polar(radius: r, angle: base)]
        }
        // External point: two tangent points at ±α off the base direction.
        let cosA = Swift.min(1.0, Swift.max(-1.0, r / dist))
        let alpha = acos(cosA)
        return [
            center + Vector.polar(radius: r, angle: base + alpha),
            center + Vector.polar(radius: r, angle: base - alpha),
        ]
    }

    /// The tangent point(s) on a circular **arc** from `from`, restricted to the
    /// arc's angular sweep.
    public static func tangentPointsOnArc(from: Vector,
                                          center: Vector, radius: Double,
                                          startAngle: Double, endAngle: Double,
                                          reversed: Bool) -> [Vector] {
        tangentPointsOnCircle(from: from, center: center, radius: abs(radius)).filter { p in
            let ang = (p - center).angle
            return MathUtils.isAngleBetween(ang, startAngle, endAngle, reversed: reversed)
        }
    }

    /// The tangent point(s) on an **ellipse** from the external point `from`.
    ///
    /// An affine map `M⁻¹` turns the ellipse into the unit circle; tangency is
    /// preserved by affine maps, so we transform `from` into the unit-circle
    /// frame, take the unit-circle tangent points there, and map them back. The
    /// ellipse frame: translate by `-center`, rotate by `-rotation`, then divide
    /// x by `majorRadius` and y by `minorRadius` to land on the unit circle.
    ///
    /// - Parameters:
    ///   - from:         the external point (world coords).
    ///   - center:       ellipse center.
    ///   - majorRadius:  semi-major axis length.
    ///   - minorRadius:  semi-minor axis length.
    ///   - rotation:     major-axis angle (radians).
    /// Returns world-space tangent points (0, 1, or 2). `startAngle`/`endAngle`
    /// filtering for elliptic *arcs* is the caller's job (it knows the sweep).
    public static func tangentPointsOnEllipse(from: Vector,
                                              center: Vector,
                                              majorRadius: Double,
                                              minorRadius: Double,
                                              rotation: Double) -> [Vector] {
        guard from.valid,
              majorRadius > Tolerance.distance,
              minorRadius > Tolerance.distance else { return [] }
        // World → unit-circle frame.
        let rel = (from - center).rotated(by: -rotation)
        let unit = Vector(rel.x / majorRadius, rel.y / minorRadius)
        // Tangent points on the unit circle from the mapped point.
        let circleTangents = tangentPointsOnCircle(from: unit, center: Vector(0, 0), radius: 1.0)
        // Unit-circle frame → world.
        return circleTangents.map { t in
            let scaled = Vector(t.x * majorRadius, t.y * minorRadius)
            return center + scaled.rotated(by: rotation)
        }
    }

    // MARK: - Parallel

    /// Snaps the cursor so the segment `from → cursor` is **parallel** to the
    /// reference direction `refDir`. The result is the orthogonal projection of
    /// `cursor` onto the infinite line through `from` along `refDir` — i.e. the
    /// point on that line nearest the cursor, which is the natural "rubber-band
    /// stays parallel" target. Returns `.invalid` for a degenerate direction.
    ///
    /// `refDir` need not be unit length (it's the raw direction of the hovered
    /// reference entity, e.g. `lineEnd - lineStart`).
    public static func parallelProjection(from: Vector, cursor: Vector, refDir: Vector) -> Vector {
        guard from.valid, cursor.valid else { return .invalid }
        let len2 = refDir.squared
        guard len2 > Tolerance.distanceSquared else { return .invalid }
        let t = (cursor - from).dot(refDir) / len2
        return from + refDir * t
    }

    // MARK: - Distance-along-entity (equidistant / "Snap distance")

    /// A hard cap on how many equidistant points are generated for one entity, so
    /// a tiny `spacing` against a very long entity can't produce an unbounded
    /// candidate list (rendering-performance.md §5: snapping must stay responsive).
    public static let distanceAlongPointCap = 4096

    /// Equidistant points along the **finite line segment** `start → end`, spaced
    /// `spacing` apart, measured from the chosen reference end.
    ///
    /// Mirrors LibreCAD's "Snap distance" (`RS_Snapper` equidistant snap): the
    /// returned points are at `1·spacing, 2·spacing, …` from the reference
    /// endpoint, walking toward the far end, and stopping before the far end. The
    /// reference endpoint itself (distance 0) is NOT emitted — it is already an
    /// endpoint snap. Points are clamped to the segment, so none lie past `end`.
    ///
    /// - Parameters:
    ///   - start:     one segment endpoint.
    ///   - end:       the other segment endpoint.
    ///   - spacing:   distance between successive snap points (world units, > 0).
    ///   - fromStart: `true` measures from `start`; `false` measures from `end`.
    public static func pointsAlongLine(start: Vector, end: Vector,
                                       spacing: Double, fromStart: Bool = true) -> [Vector] {
        guard start.valid, end.valid, spacing > Tolerance.distance else { return [] }
        let ref = fromStart ? start : end
        let far = fromStart ? end : start
        let total = (far - ref).magnitude
        guard total > Tolerance.distance else { return [] }
        let dir = (far - ref) * (1.0 / total)
        return marchPoints(spacing: spacing, total: total).map { ref + dir * $0 }
    }

    /// Equidistant points along a circular **arc**, spaced `spacing` apart by
    /// **arc length** (not chord length), measured from the chosen reference end.
    ///
    /// The arc sweeps from `startAngle` to `endAngle`; `reversed == true` is the
    /// clockwise sweep (LibreCAD convention). The reference end (distance 0) is not
    /// emitted; points stop before the far end. Arc length `s` maps to a swept
    /// angle `s / radius` taken in the sweep direction from the reference end.
    ///
    /// - Parameters:
    ///   - center / radius / startAngle / endAngle / reversed: the arc.
    ///   - spacing:   arc-length distance between successive points (> 0).
    ///   - fromStart: measure from `startAngle` (true) or from `endAngle` (false).
    public static func pointsAlongArc(center: Vector, radius: Double,
                                      startAngle: Double, endAngle: Double, reversed: Bool,
                                      spacing: Double, fromStart: Bool = true) -> [Vector] {
        let r = abs(radius)
        guard center.valid, r > Tolerance.distance, spacing > Tolerance.distance else { return [] }
        // Total swept angle in [0, 2π) in the direction of travel, then arc length.
        let twoPi = 2.0 * Double.pi
        var sweep = reversed ? (startAngle - endAngle) : (endAngle - startAngle)
        sweep = sweep.truncatingRemainder(dividingBy: twoPi)
        if sweep <= Tolerance.angle { sweep += twoPi }
        let total = sweep * r                                   // total arc length
        // March from whichever end is the reference, in the sweep direction.
        let refAngle = fromStart ? startAngle : endAngle
        // Stepping toward the far end: from start we follow the sweep sign; from
        // end we go opposite the sweep sign (back toward start).
        let stepSign: Double = (fromStart == reversed) ? -1.0 : 1.0
        return marchPoints(spacing: spacing, total: total).map { s in
            let dAng = (s / r) * stepSign
            return center + Vector.polar(radius: r, angle: refAngle + dAng)
        }
    }

    /// Equidistant points along a **polyline** path (a chain of points, optionally
    /// closed), spaced `spacing` apart by cumulative path length, measured from the
    /// chosen reference end. Straight-segment interpolation along the chord chain
    /// (bulge arcs are walked by their resolved chord points by the caller). The
    /// reference end (distance 0) is not emitted.
    ///
    /// - Parameters:
    ///   - points:    ordered path vertices (>= 2).
    ///   - closed:    whether the path closes back to `points[0]`.
    ///   - spacing:   distance between successive points (> 0).
    ///   - fromStart: measure from `points.first` (true) or `points.last` (false).
    public static func pointsAlongPolyline(points: [Vector], closed: Bool,
                                           spacing: Double, fromStart: Bool = true) -> [Vector] {
        guard spacing > Tolerance.distance else { return [] }
        var path = points.filter(\.valid)
        guard path.count >= 2 else { return [] }
        if closed, let f = path.first { path.append(f) }
        if !fromStart { path.reverse() }
        // Cumulative arc-length along the (possibly reversed) path.
        var cum: [Double] = [0]
        cum.reserveCapacity(path.count)
        for i in 1..<path.count {
            cum.append(cum[i - 1] + (path[i] - path[i - 1]).magnitude)
        }
        let total = cum[cum.count - 1]
        guard total > Tolerance.distance else { return [] }
        var out: [Vector] = []
        for s in marchPoints(spacing: spacing, total: total) {
            // Find the segment containing cumulative length `s`.
            var seg = 1
            while seg < cum.count && cum[seg] < s { seg += 1 }
            if seg >= cum.count { break }
            let segLen = cum[seg] - cum[seg - 1]
            let t = segLen > Tolerance.distance ? (s - cum[seg - 1]) / segLen : 0
            out.append(path[seg - 1] + (path[seg] - path[seg - 1]) * t)
        }
        return out
    }

    /// The interior march distances `spacing, 2·spacing, …` strictly less than
    /// `total` (the reference end and far end are excluded — both are already
    /// endpoint snaps). Capped at `distanceAlongPointCap`.
    private static func marchPoints(spacing: Double, total: Double) -> [Double] {
        guard spacing > Tolerance.distance, total > Tolerance.distance else { return [] }
        var out: [Double] = []
        var s = spacing
        while s < total - Tolerance.distance && out.count < distanceAlongPointCap {
            out.append(s)
            s += spacing
        }
        return out
    }

    // MARK: - Angle bisector (between two lines)

    /// The UNIT direction of the angle bisector of the wedge between two infinite
    /// lines, selected by a reference point on each line.
    ///
    /// Mirrors LibreCAD's `RS_ActionDrawLineBisector` / `RS_Creation::createBisector`
    /// (librecad/src/lib/creation/rs_creation.cpp): the two lines meet at a CORNER
    /// (their infinite intersection); the bisector emanates from that corner and
    /// bisects the wedge the user picked — the one between the RAYS that point from
    /// the corner TOWARD each reference point (`ref1` on line 1, `ref2` on line 2).
    /// There are four bisector directions for two crossing lines; choosing the wedge
    /// by the two picks selects the one the user means, exactly as the C++ action
    /// orients each line toward its click and bisects `dir1 + dir2`.
    ///
    /// Returns `.invalid` for parallel/coincident lines (no finite corner) or when
    /// the picked rays are anti-parallel (a straight angle — the bisector direction
    /// is undefined, perpendicular to the line, so we report no result). The bisector
    /// LINE is then `corner → corner + dir·L` for any `L` the caller chooses; use
    /// ``bisectorCorner(...)`` to fetch the corner.
    ///
    /// - Parameters:
    ///   - a0, a1: two distinct points on the FIRST line (its segment endpoints).
    ///   - ref1:   a point on (or near) the first line selecting its ray from the corner.
    ///   - b0, b1: two distinct points on the SECOND line.
    ///   - ref2:   a point selecting the second line's ray from the corner.
    public static func angleBisectorDirection(a0: Vector, a1: Vector, ref1: Vector,
                                              b0: Vector, b1: Vector, ref2: Vector) -> Vector {
        guard let corner = bisectorCorner(a0: a0, a1: a1, b0: b0, b1: b1) else { return .invalid }
        // Each ray uses its OWN line's direction (so it lies exactly on the line),
        // oriented from the corner toward the pick side.
        let d1 = rayFromCorner(corner, lineStart: a0, lineEnd: a1, toward: ref1)
        let d2 = rayFromCorner(corner, lineStart: b0, lineEnd: b1, toward: ref2)
        guard d1.valid, d2.valid else { return .invalid }
        let sum = d1 + d2
        let len = sum.magnitude
        // Anti-parallel rays (a straight 180° "corner"): bisector is undefined here
        // (it would be perpendicular to the line, but the wedge is degenerate).
        guard len > Tolerance.distance else { return .invalid }
        return sum * (1.0 / len)
    }

    /// The CORNER of two infinite lines — their intersection point — or `.invalid`
    /// when they are parallel/coincident (no finite crossing). The companion of
    /// ``angleBisectorDirection(...)``: the bisector LINE is `corner → corner + dir·L`.
    public static func bisectorCorner(a0: Vector, a1: Vector, b0: Vector, b1: Vector) -> Vector? {
        let sols = Intersections.lineLine(a0, a1, b0, b1, segment: false)
        guard let corner = sols.first, corner.valid else { return nil }
        return corner
    }

    /// The UNIT direction from `corner` ALONG the line `(lineStart, lineEnd)`,
    /// oriented to point toward the side of `toward`. Returns `.invalid` for a
    /// degenerate (zero-length) line. (Shared by the bisector construction; mirrors
    /// `FilletTool.directionAlongLine` but normalized and engine-shared.)
    private static func rayFromCorner(_ corner: Vector,
                                      lineStart: Vector, lineEnd: Vector,
                                      toward: Vector) -> Vector {
        let dir = lineEnd - lineStart
        let len = dir.magnitude
        guard len > Tolerance.distance else { return .invalid }
        let unit = dir * (1.0 / len)
        let sign = (toward - corner).dot(unit) >= 0 ? 1.0 : -1.0
        return unit * sign
    }

    // MARK: - Manual (two-pick) snap primitives

    /// The midpoint of two user-picked points (LibreCAD "Snap middle manual" —
    /// `RS_ActionSnapMiddleManual`): the snap point is `(a + b) / 2`, regardless of
    /// any entity. Returns `.invalid` if either pick is invalid.
    public static func manualMiddle(a: Vector, b: Vector) -> Vector {
        guard a.valid, b.valid else { return .invalid }
        return (a + b) * 0.5
    }
}
