//
//  Intersections.swift
//  CADEngine
//
//  Pure geometric intersection kernels ported from LibreCAD's RS_Information
//  (librecad/src/lib/information/rs_information.cpp) getIntersection* functions.
//
//  Every function here takes PRIMITIVE parameters (points, centers, radii,
//  angles) — never an entity enum. The entity-aware layer (another workstream)
//  adapts EntityKind → these parameters at the call site. Operates in f64
//  (ADR-003), mirroring LibreCAD's logic value-for-value.
//
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) Dongxu Li <dongxuli2011@gmail.com> (intersection kernels).
//  Copyright (C) 2001-2003 RibbonSoft.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// Pure 2D intersection kernels. All inputs are primitive geometry; outputs are
/// `VectorSolutions` (with the `tangent` flag set where the curves touch).
///
/// The `segment` parameter, where present, restricts the line to the segment
/// between its two endpoints; passing `false` treats it as an infinite line.
/// Arc parameters carry start/end angles + a `reversed` flag (CW), matching the
/// LibreCAD arc convention; angle-range filtering is applied when requested.
public enum Intersections {

    /// Default range tolerance for endpoint/arc-range "on entity" filtering,
    /// matching the `1.0e-4` constant in `RS_Information::getIntersection`.
    public static let onEntityTolerance = 1.0e-4

    // MARK: - Line / Line

    /// Intersection of two lines.
    ///
    /// `a0`/`a1` are the endpoints of line A, `b0`/`b1` of line B. When
    /// `segment == true`, the returned point must lie on both finite segments;
    /// otherwise the lines are treated as infinite. Faithful port of
    /// `RS_Information::getIntersectionLineLine` (infinite-line core), with the
    /// segment containment check added for the finite case.
    public static func lineLine(_ a0: Vector, _ a1: Vector,
                                _ b0: Vector, _ b1: Vector,
                                segment: Bool = false) -> VectorSolutions {
        let p1 = a0, p2 = a1, p3 = b0, p4 = b1

        let num = (p4.x - p3.x) * (p1.y - p3.y) - (p4.y - p3.y) * (p1.x - p3.x)
        let div = (p4.y - p3.y) * (p2.x - p1.x) - (p4.x - p3.x) * (p2.y - p1.y)

        // parallel condition test (matches the C++ angle remainder check)
        let angleA = (p2 - p1).angle
        let angleB = (p4 - p3).angle
        let dAngle = angleA - angleB

        if abs(div) > Tolerance.distance &&
            abs(dAngle.remainder(dividingBy: Double.pi)) >= Tolerance.angle {
            let u = num / div
            let xs = p1.x + u * (p2.x - p1.x)
            let ys = p1.y + u * (p2.y - p1.y)
            let hit = Vector(xs, ys)

            if segment {
                // u in [0,1] for segment A; compute v for segment B too
                let dB = p4 - p3
                let lenB2 = dB.squared
                let v = lenB2 > Tolerance.distanceSquared ? ((hit - p3).dot(dB) / lenB2) : 0.0
                let eps = 1e-9
                if u < -eps || u > 1 + eps || v < -eps || v > 1 + eps {
                    return VectorSolutions()
                }
            }
            return VectorSolutions(hit)
        }

        // parallel / zero-length handling
        let lenA = (p2 - p1).magnitude
        let lenB = (p4 - p3).magnitude
        var (s1, e1) = (p1, p2)
        var (s2, _) = (p3, p4)
        if lenA < lenB {
            (s1, e1, s2) = (p3, p4, p1)
        }
        let longLen = max(lenA, lenB)
        if longLen <= Tolerance.distance {
            // both zero-length: coincident points only
            if (s1 - s2).squared <= Tolerance.distanceSquared {
                return VectorSolutions(s1)
            }
            return VectorSolutions()
        }
        let shortLen = min(lenA, lenB)
        if shortLen <= Tolerance.distance {
            // one zero-length: project onto the long line
            let proj = nearestOnInfiniteLine(s2, s1, e1)
            if (proj - s2).squared <= Tolerance.distanceSquared {
                return VectorSolutions(proj)
            }
        }
        return VectorSolutions()   // parallel, no intersection
    }

    // MARK: - Line / Circle

    /// Intersection of a line with a full circle.
    ///
    /// `line` is the segment/infinite line `(p, end)`, `center`/`radius` define
    /// the circle. When `segment == true` the hits are filtered to the finite
    /// line segment. Built on the line-arc core with a full 0…2π angle range.
    public static func lineCircle(line: (Vector, Vector),
                                  center: Vector, radius: Double,
                                  segment: Bool = false) -> VectorSolutions {
        lineArc(line: line, center: center, radius: radius,
                angle1: 0, angle2: 0, reversed: false,
                fullCircle: true, segment: segment)
    }

    // MARK: - Line / Arc

    /// Intersection of a line with an arc (or circle when `fullCircle == true`).
    ///
    /// `line` is `(start, end)`. `center`/`radius` + `angle1`/`angle2`/`reversed`
    /// define the arc. When `fullCircle` is `false`, hits outside the arc's angle
    /// range are discarded; when `segment` is `true`, hits off the finite line
    /// segment are discarded. Faithful port of
    /// `RS_Information::getIntersectionLineArc` (with range/segment filtering).
    public static func lineArc(line: (Vector, Vector),
                               center: Vector, radius: Double,
                               angle1: Double, angle2: Double, reversed: Bool,
                               fullCircle: Bool = false,
                               segment: Bool = false) -> VectorSolutions {
        let p = line.0
        let d = line.1 - line.0
        let d2 = d.squared
        let c = center
        let r = radius
        let delta = p - c

        if d2 < Tolerance.distanceSquared {
            // line too short — touches the arc?
            if abs(delta.squared - r * r) < 2.0 * Tolerance.distance * r {
                let mid = (line.0 + line.1) * 0.5
                return filtered(VectorSolutions(mid),
                                arcCenter: c, angle1: angle1, angle2: angle2,
                                reversed: reversed, fullCircle: fullCircle,
                                line: line, segment: segment)
            }
            return VectorSolutions()
        }

        // arc-center projection on the line
        let t = d.dot(c - p) / d2
        var projection = p + d * t
        var dP = projection - c
        dP = dP - d * (d.dot(dP) / d2)   // reduce rounding errors
        projection = c + dP

        let dr = dP.magnitude - r
        let tol = 1e-5 * r
        if dr > tol {
            return VectorSolutions()
        }

        if dr < -tol {
            // two solutions
            let dt = (r * r - dP.squared).squareRoot()
            let dT = d * (dt / d.magnitude)
            let sols = VectorSolutions([projection + dT, projection - dT])
            return filtered(sols, arcCenter: c, angle1: angle1, angle2: angle2,
                            reversed: reversed, fullCircle: fullCircle,
                            line: line, segment: segment)
        }

        // tangential
        var ret = VectorSolutions(projection)
        ret.tangent = true
        return filtered(ret, arcCenter: c, angle1: angle1, angle2: angle2,
                        reversed: reversed, fullCircle: fullCircle,
                        line: line, segment: segment)
    }

    // MARK: - Circle / Circle

    /// Intersection of two circles, mirroring the arc-arc kernel with full angle
    /// ranges. Returns 0, 1 (tangent), or 2 points.
    public static func circleCircle(center1: Vector, radius1: Double,
                                    center2: Vector, radius2: Double) -> VectorSolutions {
        arcArcCore(c1: center1, r1: radius1, c2: center2, r2: radius2)
    }

    // MARK: - Circle / Arc

    /// Intersection of a circle with an arc. The geometric solver is identical to
    /// circle-circle; hits are then filtered to the arc's angle range.
    public static func circleArc(circleCenter: Vector, circleRadius: Double,
                                 arcCenter: Vector, arcRadius: Double,
                                 arcAngle1: Double, arcAngle2: Double,
                                 arcReversed: Bool) -> VectorSolutions {
        let sols = arcArcCore(c1: circleCenter, r1: circleRadius,
                              c2: arcCenter, r2: arcRadius)
        return filterArcRange(sols, center: arcCenter,
                              angle1: arcAngle1, angle2: arcAngle2, reversed: arcReversed)
    }

    // MARK: - Arc / Arc

    /// Intersection of two arcs. The geometric solver is the same circle-circle
    /// core; hits are filtered to *both* arcs' angle ranges.
    /// Faithful port of `RS_Information::getIntersectionArcArc` + range filtering.
    public static func arcArc(center1: Vector, radius1: Double,
                              angle1Start: Double, angle1End: Double, reversed1: Bool,
                              center2: Vector, radius2: Double,
                              angle2Start: Double, angle2End: Double, reversed2: Bool) -> VectorSolutions {
        var sols = arcArcCore(c1: center1, r1: radius1, c2: center2, r2: radius2)
        sols = filterArcRange(sols, center: center1,
                              angle1: angle1Start, angle2: angle1End, reversed: reversed1)
        sols = filterArcRange(sols, center: center2,
                              angle1: angle2Start, angle2: angle2End, reversed: reversed2)
        return sols
    }

    /// The pure circle-circle geometry (no angle filtering), shared by the
    /// circle/arc family. Faithful port of `getIntersectionArcArc`.
    static func arcArcCore(c1: Vector, r1: Double, c2: Vector, r2: Double) -> VectorSolutions {
        let u = c2 - c1

        // concentric
        if u.magnitude < 1.0e-7 * (r1 + r2) {
            return VectorSolutions()
        }

        // perpendicular to the center-to-center line
        let v = Vector(u.y, -u.x)

        let r12 = r1 * r1
        let r22 = r2 * r2
        let s = 0.5 * ((r12 - r22) / u.squared + 1.0)
        let term = r12 / u.squared - s * s

        if term < -Tolerance.distance {
            return VectorSolutions()
        }

        let t1 = max(0.0, term).squareRoot()
        let sol1 = c1 + u * s + v * t1
        let sol2 = c1 + u * s - v * t1

        if sol1.distance(to: sol2) < 1.0e-5 * (r1 + r2) {
            var ret = VectorSolutions(sol1)
            ret.tangent = true
            return ret
        }
        return VectorSolutions([sol1, sol2])
    }

    // MARK: - Line / Ellipse

    /// Intersection of a line with an ellipse.
    ///
    /// `line` is `(start, end)`. The ellipse is `center` + `majorP` (the major
    /// axis endpoint relative to center, encoding both major radius and rotation)
    /// + `ratio` (minor/major). Faithful port of
    /// `RS_Information::getIntersectionEllipseLine`. Returns 0, 1, or 2 points on
    /// the infinite line (range/segment filtering is left to the caller).
    public static func lineEllipse(line: (Vector, Vector),
                                   center: Vector, majorP: Vector, ratio: Double) -> VectorSolutions {
        var ret = VectorSolutions()

        let rx = majorP.magnitude
        if rx < Tolerance.distance {
            // zero-radius ellipse: nearest point on line to center, if it lands on it
            let vp = nearestOnInfiniteLine(center, line.0, line.1)
            if (vp - center).squared < Tolerance.distanceSquared {
                ret.append(vp)
            }
            return ret
        }

        // rotate into normal position: angleVector = majorP scaled by (1/rx, -1/rx)
        let angleVector = Vector(majorP.x / rx, majorP.y * (-1.0 / rx))
        let ry = rx * ratio

        let a1 = rotateAbout(line.0, center: center, angleVector: angleVector)
        let a2 = rotateAbout(line.1, center: center, angleVector: angleVector)
        let dir = a2 - a1
        let diff = a1 - center
        let mDir = Vector(dir.x / (rx * rx), dir.y / (ry * ry))
        let mDiff = Vector(diff.x / (rx * rx), diff.y / (ry * ry))

        let a = dir.dot(mDir)
        let b = dir.dot(mDiff)
        let cc = diff.dot(mDiff) - 1.0
        var d = b * b - a * cc

        if d < -1.0e3 * Tolerance.distance * Tolerance.distance.squareRoot() {
            return ret
        }
        if d < 0 { d = 0 }

        let root = d.squareRoot()
        let tA = -b / a
        let tB = root / a

        ret.append(lerp(a1, a2, tA + tB))
        let vp = lerp(a1, a2, tA - tB)
        if (ret.get(0) - vp).squared > Tolerance.distanceSquared {
            ret.append(vp)
        }

        // rotate back: conjugate angle vector (negate y)
        let backAV = Vector(angleVector.x, -angleVector.y)
        return ret.rotated(about: center, by: backAV)
    }

    // MARK: - Ellipse / Ellipse

    /// Intersection of two ellipses, via the simultaneous-quadratic (quartic)
    /// solver. Each ellipse is `center` + `majorP` + `ratio`. Faithful port of
    /// `RS_Information::getIntersectionEllipseEllipse` (including the degenerate
    /// "treat as a line" fallbacks and the overlap rejection).
    public static func ellipseEllipse(center1: Vector, majorP1: Vector, ratio1: Double,
                                      center2: Vector, majorP2: Vector, ratio2: Double) -> VectorSolutions {
        var ret = VectorSolutions()

        // overlapped ellipses: do not report overlap
        if (center1 - center2).squared < Tolerance.distanceSquared &&
            (majorP1 - majorP2).squared < Tolerance.distanceSquared &&
            abs(ratio1 - ratio2) < Tolerance.distance {
            return ret
        }

        // Normalize so each ellipse has majorRadius >= minorRadius.
        var e01 = EllipseParams(center: center1, majorP: majorP1, ratio: ratio1)
        if e01.majorRadius < e01.minorRadius { e01.switchMajorMinor() }
        var e02 = EllipseParams(center: center2, majorP: majorP2, ratio: ratio2)
        if e02.majorRadius < e02.minorRadius { e02.switchMajorMinor() }

        // transform ellipse2 into ellipse1's coordinate frame
        let shiftc1 = -e01.center
        let shifta1 = -e01.angle
        e02.move(shiftc1)
        e02.rotate(shifta1)

        let a1 = e01.majorRadius
        let b1 = e01.minorRadius
        let x2 = e02.center.x
        let y2 = e02.center.y
        let a2 = e02.majorRadius
        let b2 = e02.minorRadius

        // degenerate ellipse1 → treat as a line
        if e01.minorRadius < Tolerance.distance || e01.ratio < Tolerance.distance {
            let line = (Vector(-a1, 0), Vector(a1, 0))
            ret = lineEllipse(line: line, center: e02.center, majorP: e02.majorP, ratio: e02.ratio)
            ret = ret.rotated(by: -shifta1).moved(by: -shiftc1)
            return ret
        }
        // degenerate ellipse2 → treat as a line
        if e02.minorRadius < Tolerance.distance || e02.ratio < Tolerance.distance {
            var p0 = Vector(-a2, 0)
            var p1 = Vector(a2, 0)
            let av = Vector(angle: e02.angle)
            p0 = p0.rotated(by: av) + e02.center
            p1 = p1.rotated(by: av) + e02.center
            ret = lineEllipse(line: (p0, p1), center: e01.center, majorP: e01.majorP, ratio: e01.ratio)
            ret = ret.rotated(by: -shifta1).moved(by: -shiftc1)
            return ret
        }

        // both proper ellipses: assemble the 8-coefficient simultaneous system
        let t2 = -e02.angle
        let cs = cos(t2), si = sin(t2)
        let ucs = x2 * cs, usi = x2 * si
        let vcs = y2 * cs, vsi = y2 * si
        let cs2 = cs * cs, si2 = 1.0 - cs2
        let tcssi = 2.0 * cs * si
        let ia2 = 1.0 / (a2 * a2), ib2 = 1.0 / (b2 * b2)

        var m = [Double]()
        m.append(1.0 / (a1 * a1))                                              // ma000
        m.append(1.0 / (b1 * b1))                                              // ma011
        m.append(cs2 * ia2 + si2 * ib2)                                        // ma100
        m.append(cs * si * (ib2 - ia2))                                        // ma101
        m.append(si2 * ia2 + cs2 * ib2)                                        // ma111
        m.append((y2 * tcssi - 2.0 * x2 * cs2) * ia2 - (y2 * tcssi + 2.0 * x2 * si2) * ib2)  // mb10
        m.append((x2 * tcssi - 2.0 * y2 * si2) * ia2 - (x2 * tcssi + 2.0 * y2 * cs2) * ib2)  // mb11
        m.append((ucs - vsi) * (ucs - vsi) * ia2 + (usi + vcs) * (usi + vcs) * ib2 - 1.0)    // mc1

        let vs0 = QuadraticSolver.simultaneousQuadratic(m)
        let backRotate = -shifta1   // = e01.angle
        let backMove = -shiftc1     // = e01.center
        for vp in vs0 {
            let r = vp.rotated(by: backRotate) + backMove
            ret.append(r)
        }
        return ret
    }

    // MARK: - Circle / Ellipse and Arc / Ellipse (wrappers, per LibreCAD)

    /// Circle-ellipse intersection: model the circle as a unit-ratio ellipse and
    /// defer to ``ellipseEllipse`` (`getIntersectionCircleEllipse`).
    public static func circleEllipse(circleCenter: Vector, circleRadius: Double,
                                     center: Vector, majorP: Vector, ratio: Double) -> VectorSolutions {
        ellipseEllipse(center1: center, majorP1: majorP, ratio1: ratio,
                       center2: circleCenter, majorP2: Vector(circleRadius, 0), ratio2: 1.0)
    }

    /// Arc-ellipse intersection: model the arc as a unit-ratio ellipse, defer to
    /// ``ellipseEllipse``, then filter to the arc's angle range
    /// (`getIntersectionArcEllipse`).
    public static func arcEllipse(arcCenter: Vector, arcRadius: Double,
                                  arcAngle1: Double, arcAngle2: Double, arcReversed: Bool,
                                  center: Vector, majorP: Vector, ratio: Double) -> VectorSolutions {
        let sols = ellipseEllipse(center1: center, majorP1: majorP, ratio1: ratio,
                                  center2: arcCenter, majorP2: Vector(arcRadius, 0), ratio2: 1.0)
        return filterArcRange(sols, center: arcCenter,
                              angle1: arcAngle1, angle2: arcAngle2, reversed: arcReversed)
    }

    // MARK: - Private helpers

    /// Nearest point on the infinite line through `(s, e)` to `coord`.
    static func nearestOnInfiniteLine(_ coord: Vector, _ s: Vector, _ e: Vector) -> Vector {
        let d = e - s
        let len2 = d.squared
        if len2 < Tolerance.distanceSquared { return s }
        let t = (coord - s).dot(d) / len2
        return s + d * t
    }

    /// Linear interpolation `a + t (b - a)`.
    static func lerp(_ a: Vector, _ b: Vector, _ t: Double) -> Vector {
        a + (b - a) * t
    }

    /// Rotate `p` about `center` by an angle-vector `(cos, sin)`.
    static func rotateAbout(_ p: Vector, center: Vector, angleVector: Vector) -> Vector {
        (p - center).rotated(by: angleVector) + center
    }

    /// Filters arc-arc / line-arc solutions to an arc's angle range and (for
    /// lines) to the finite segment, preserving the `tangent` flag.
    static func filtered(_ sols: VectorSolutions,
                         arcCenter: Vector, angle1: Double, angle2: Double, reversed: Bool,
                         fullCircle: Bool, line: (Vector, Vector), segment: Bool) -> VectorSolutions {
        var out = sols
        if !fullCircle {
            out = filterArcRange(out, center: arcCenter, angle1: angle1, angle2: angle2, reversed: reversed)
        }
        if segment {
            out = filterSegment(out, line: line)
        }
        return out
    }

    /// Keeps only the points whose angle about `center` lies within the arc range.
    static func filterArcRange(_ sols: VectorSolutions,
                               center: Vector, angle1: Double, angle2: Double, reversed: Bool) -> VectorSolutions {
        var out = VectorSolutions()
        out.tangent = sols.tangent
        for p in sols {
            guard p.valid else { continue }
            let ang = (p - center).angle
            if MathUtils.isAngleBetween(ang, angle1, angle2, reversed: reversed) {
                out.append(p)
            }
        }
        return out
    }

    /// Keeps only the points lying on the finite line segment `(s, e)`.
    static func filterSegment(_ sols: VectorSolutions, line: (Vector, Vector)) -> VectorSolutions {
        var out = VectorSolutions()
        out.tangent = sols.tangent
        let s = line.0, e = line.1
        let d = e - s
        let len2 = d.squared
        let eps = 1e-9
        for p in sols {
            guard p.valid else { continue }
            if len2 < Tolerance.distanceSquared {
                if (p - s).squared <= Tolerance.distanceSquared { out.append(p) }
                continue
            }
            let t = (p - s).dot(d) / len2
            if t >= -eps && t <= 1 + eps { out.append(p) }
        }
        return out
    }
}

// MARK: - Ellipse parameter helper (normalization for ellipse intersections)

/// A lightweight, mutable ellipse parameterization used internally by the
/// ellipse intersection kernels. Mirrors the small slice of `RS_Ellipse` the
/// intersection code touches: center, major-axis endpoint, ratio, and the
/// move/rotate/switchMajorMinor operations used during normalization.
struct EllipseParams {
    var center: Vector
    /// Major-axis endpoint relative to the center (encodes radius + rotation).
    var majorP: Vector
    /// Minor/major radius ratio.
    var ratio: Double

    var majorRadius: Double { majorP.magnitude }
    var minorRadius: Double { majorP.magnitude * ratio }
    /// Rotation angle of the major axis.
    var angle: Double { majorP.angle }

    mutating func move(_ offset: Vector) {
        center = center + offset
    }

    mutating func rotate(_ a: Double) {
        let av = Vector(angle: a)
        center = center.rotated(by: av)
        majorP = majorP.rotated(by: av)
    }

    /// Swap which axis is "major": set majorP perpendicular and scaled by the
    /// old ratio, then invert the ratio. Faithful port of
    /// `RS_Ellipse::switchMajorMinor` (direction +π/2 relative to old majorP).
    mutating func switchMajorMinor() {
        guard abs(ratio) >= Tolerance.distance else { return }
        majorP = Vector(-ratio * majorP.y, ratio * majorP.x)   // π/2 relative to old majorP
        ratio = 1.0 / ratio
    }
}
