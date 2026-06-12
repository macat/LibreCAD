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
}
