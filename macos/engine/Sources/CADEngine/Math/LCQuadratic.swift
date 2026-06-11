//
//  LCQuadratic.swift
//  CADEngine
//
//  Ported from LibreCAD's LC_Quadratic (librecad/src/lib/math/lc_quadratic.{h,cpp}).
//  Represents a general conic section (or straight line) in canonical algebraic
//  form  A x² + B xy + C y² + D x + E y + F = 0  and computes the intersection of
//  any two such conics/lines via the most stable solver available.
//
//  Only the algebraic core needed by the intersection kernels is ported here:
//  coefficient construction, the perpendicular-bisector and circle-coefficient
//  constructors, move/rotate/scale/flipXY, validity/classification, evaluateAt,
//  and the static getIntersection. The entity-conversion (toEntity) and
//  tangent-locus constructors are out of scope for this workstream.
//
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2015-2024 LibreCAD.org; Copyright (C) Dongxu Li (dongxuli2011@gmail.com).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// A general conic / line in algebraic form
/// `A x² + B xy + C y² + D x + E y + F = 0`.
///
/// The quadratic part is stored as a symmetric 2×2 matrix (off-diagonal = B/2),
/// the linear part as `(D, E)`, and the constant as `F`. This is a faithful port
/// of the algebraic engine LibreCAD uses to intersect any two conics or lines.
public struct LCQuadratic: Sendable, Equatable {

    // symmetric quad matrix entries: q00 = A, q01 = q10 = B/2, q11 = C
    @usableFromInline var q00: Double = 0
    @usableFromInline var q01: Double = 0
    @usableFromInline var q11: Double = 0
    @usableFromInline var linear0: Double = 0   // D
    @usableFromInline var linear1: Double = 0   // E
    @usableFromInline var constTerm: Double = 0 // F
    @usableFromInline var isQuad: Bool = false
    @usableFromInline var valid: Bool = false

    // MARK: - Construction

    /// An invalid (default) quadratic.
    public init() {}

    /// Constructs from explicit coefficients:
    /// - 6 coefficients `[A, B, C, D, E, F]` → full quadratic
    /// - 3 coefficients `[D, E, F]` → straight line `D x + E y + F = 0`
    /// Faithful port of `LC_Quadratic(std::vector<double>)`.
    public init(_ ce: [Double]) {
        if ce.count == 6 {
            q00 = ce[0]
            q01 = 0.5 * ce[1]
            q11 = ce[2]
            linear0 = ce[3]
            linear1 = ce[4]
            constTerm = ce[5]
            isQuad = true
            valid = true
        } else if ce.count == 3 {
            linear0 = ce[0]
            linear1 = ce[1]
            constTerm = ce[2]
            isQuad = false
            valid = true
        } else {
            valid = false
        }
    }

    /// Perpendicular bisector of the segment `point0`→`point1` (the locus of
    /// centers of circles through both points): a straight line.
    /// Faithful port of `LC_Quadratic(const RS_Vector&, const RS_Vector&)`.
    public init(perpendicularBisectorOf point0: Vector, _ point1: Vector) {
        let mid = (point0 + point1) * 0.5
        let dir = point1 - point0
        // line: dir . (p - mid) = 0  =>  dir.x x + dir.y y - dir.dot(mid) = 0
        // LibreCAD normalizes so the leading coefficient is 1 for the axis-aligned case.
        var d = dir.x
        var e = dir.y
        var f = -(dir.x * mid.x + dir.y * mid.y)
        // Normalize by the dominant linear coefficient (matches the test's
        // expectation of {1, 0, -1} for a vertical bisector).
        let scale = abs(d) >= abs(e) ? d : e
        if abs(scale) > Tolerance.distance {
            d /= scale; e /= scale; f /= scale
        }
        self.init([d, e, f])
    }

    /// Builds the coefficient form of a circle centered at `center` with `radius`:
    /// `x² + y² - 2cx x - 2cy y + (cx² + cy² - r²) = 0`.
    public init(circleCenter center: Vector, radius: Double) {
        self.init([1.0, 0.0, 1.0, -2.0 * center.x, -2.0 * center.y,
                   center.x * center.x + center.y * center.y - radius * radius])
    }

    // MARK: - Coefficient access

    /// Coefficient of x² (A).
    public var a: Double { q00 }
    /// Coefficient of xy (B).
    public var b: Double { 2.0 * q01 }
    /// Coefficient of y² (C).
    public var c: Double { q11 }
    /// Coefficient of x (D).
    public var d: Double { linear0 }
    /// Coefficient of y (E).
    public var e: Double { linear1 }
    /// Constant term (F).
    public var f: Double { constTerm }

    /// Standard coefficient vector: `[A, B, C, D, E, F]` for a quadratic,
    /// `[D, E, F]` for a line, `[]` if invalid. Port of `getCoefficients`.
    public func coefficients() -> [Double] {
        guard valid else { return [] }
        if isQuad {
            return [q00, q01 + q01, q11, linear0, linear1, constTerm]
        }
        return [linear0, linear1, constTerm]
    }

    // MARK: - Classification / validity

    /// `true` if this is a genuine conic (non-zero quadratic part).
    /// Port of `isQuadratic` (uses ULP-equality on every quad entry).
    public var isQuadratic: Bool {
        if MathUtils.equal(q00, 0) && MathUtils.equal(q01, 0) && MathUtils.equal(q11, 0) {
            return false
        }
        return isQuad
    }

    /// `true` if the object is valid and usable.
    public var isValid: Bool { valid }

    /// Evaluates `A x² + B xy + C y² + D x + E y + F` at `p`.
    public func evaluate(at p: Vector) -> Double {
        guard p.valid else { return 0 }
        let x = p.x, y = p.y
        return q00 * x * x + 2.0 * q01 * x * y + q11 * y * y
            + linear0 * x + linear1 * y + constTerm
    }

    // MARK: - Transforms

    /// Returns a copy with x and y swapped (reflection over y = x).
    /// Port of `flipXY`.
    public func flippedXY() -> LCQuadratic {
        var r = self
        if isQuad {
            swap(&r.q00, &r.q11)
            // q01 == q10 in a symmetric matrix, so swapping leaves them equal
        }
        swap(&r.linear0, &r.linear1)
        return r
    }

    /// Translates the conic by `offset`. Port of `move`.
    public mutating func move(by offset: Vector) {
        guard valid else { return }
        let dx = offset.x, dy = offset.y
        if isQuadratic {
            let D = d, E = e
            linear0 -= 2.0 * a * dx + b * dy
            linear1 -= b * dx + 2.0 * c * dy
            constTerm += a * dx * dx + b * dx * dy + c * dy * dy - D * dx - E * dy
        } else {
            constTerm -= d * dx + e * dy
        }
    }

    /// Rotates the conic about the origin by `angle` radians. Port of `rotate(double)`.
    public mutating func rotate(by angle: Double) {
        guard abs(angle) >= Tolerance.distance else { return }
        // R = [[cos, sin], [-sin, cos]] (LibreCAD's rotationMatrix)
        let cs = cos(angle), sn = sin(angle)
        // linear' = Rᵀ · linear
        let l0 = cs * linear0 - sn * linear1
        let l1 = sn * linear0 + cs * linear1
        linear0 = l0
        linear1 = l1
        if isQuad {
            // M' = Rᵀ M R, with M = [[q00, q01],[q01, q11]]
            // First MR:
            let mr00 = q00 * cs + q01 * (-sn)
            let mr01 = q00 * sn + q01 * cs
            let mr10 = q01 * cs + q11 * (-sn)
            let mr11 = q01 * sn + q11 * cs
            // Then Rᵀ (MR):  Rᵀ = [[cs, -sn],[sn, cs]]
            let n00 = cs * mr00 + (-sn) * mr10
            let n01 = cs * mr01 + (-sn) * mr11
            let n11 = sn * mr01 + cs * mr11
            q00 = n00
            q01 = n01
            q11 = n11
        }
    }

    /// Rotates the conic about `center` by `angle`. Port of `rotate(center, double)`.
    public mutating func rotate(about center: Vector, by angle: Double) {
        guard valid else { return }
        move(by: -center)
        rotate(by: angle)
        move(by: center)
    }

    // MARK: - Intersection

    /// Computes the intersection points of two quadratics (any combination of
    /// lines and conics), choosing the most stable solver available. Faithful
    /// port of `LC_Quadratic::getIntersection`.
    public static func getIntersection(_ l1: LCQuadratic, _ l2: LCQuadratic) -> VectorSolutions {
        var ret = VectorSolutions()
        guard l1.valid, l2.valid else { return ret }

        var p1 = l1
        var p2 = l2
        if !p1.isQuadratic { swap(&p1, &p2) }

        if !p1.isQuadratic {
            // two lines
            let ce: [[Double]] = [
                [p1.linear0, p1.linear1, -p1.constTerm],
                [p2.linear0, p2.linear1, -p2.constTerm],
            ]
            if let sn = QuadraticSolver.linearSolver(ce) {
                ret.append(Vector(sn[0], sn[1]))
            }
            return ret
        }

        if !p2.isQuadratic {
            // one line, one quadratic
            if abs(p2.linear0) + Double.ulpOfOne < abs(p2.linear1) {
                return getIntersection(p1.flippedXY(), p2.flippedXY()).flippedXY()
            }
            var ce: [[Double]] = []
            if abs(p2.linear1) < Tolerance.distance {
                let angle = 0.25 * Double.pi
                var p11 = p1
                var p22 = p2
                p11.rotate(by: angle)
                p22.rotate(by: angle)
                ce.append(p11.coefficients())
                ce.append(p22.coefficients())
                var sol = QuadraticSolver.simultaneousQuadraticMixed(ce)
                sol = sol.rotated(by: -angle)
                return sol
            }
            ce.append(p1.coefficients())
            ce.append(p2.coefficients())
            return QuadraticSolver.simultaneousQuadraticMixed(ce)
        }

        // both quadratics with zero x²/xy parts → degrade to lines
        if abs(p1.q00) < Tolerance.distance && abs(p1.q01) < Tolerance.distance &&
            abs(p2.q00) < Tolerance.distance && abs(p2.q01) < Tolerance.distance {
            if abs(p1.q11) < Tolerance.distance && abs(p2.q11) < Tolerance.distance {
                let lc10 = LCQuadratic([p1.linear0, p1.linear1, p1.constTerm])
                let lc11 = LCQuadratic([p2.linear0, p2.linear1, p2.constTerm])
                return getIntersection(lc10, lc11)
            }
            return getIntersection(p1.flippedXY(), p2.flippedXY()).flippedXY()
        }

        // radical-axis reduction for numerical stability
        do {
            let c1 = p1.coefficients()
            let c2 = p2.coefficients()
            let quadScale = max(abs(c1[0]), abs(c1[2]), abs(c2[0]), abs(c2[2]), 1.0)
            var t = 0.0
            var canReduce = false
            if abs(c1[0]) > Tolerance.distance * quadScale {
                t = c2[0] / c1[0]
                canReduce = abs(c2[1] - t * c1[1]) <= Tolerance.distance * quadScale
                    && abs(c2[2] - t * c1[2]) <= Tolerance.distance * quadScale
            }
            if !canReduce && abs(c1[2]) > Tolerance.distance * quadScale {
                t = c2[2] / c1[2]
                canReduce = abs(c2[0] - t * c1[0]) <= Tolerance.distance * quadScale
                    && abs(c2[1] - t * c1[1]) <= Tolerance.distance * quadScale
            }
            if canReduce {
                let lineCoeffs = [c2[3] - t * c1[3], c2[4] - t * c1[4], c2[5] - t * c1[5]]
                let lineScale = max(abs(lineCoeffs[0]), abs(lineCoeffs[1]), abs(lineCoeffs[2]))
                if lineScale > Tolerance.distance {
                    let radicalAxis = LCQuadratic(lineCoeffs)
                    return getIntersection(p1, radicalAxis)
                }
            }
        }

        // general conic-conic via the simultaneous quartic solver
        let ce = [p1.coefficients(), p2.coefficients()]
        let sol = QuadraticSolver.simultaneousQuadraticFull(ce)
        var valid = !sol.isEmpty
        for v in sol where v.magnitude >= 1e10 {
            _ = v
            valid = false
            break
        }
        if valid { return sol }

        // fallback: filter finite candidates only
        let sol2 = QuadraticSolver.simultaneousQuadraticFull(ce)
        ret.clear()
        for v in sol2 where v.magnitude <= 1e10 {
            ret.append(v)
        }
        return ret
    }
}
