//
//  QuadraticSolver.swift
//  CADEngine
//
//  Real-root polynomial solvers ported from LibreCAD's RS_Math
//  (librecad/src/lib/math/rs_math.cpp): quadratic, cubic, quartic, plus the
//  Gauss-Jordan linear solver and the simultaneous-quadratic solvers that drive
//  ellipse/ellipse and ellipse/conic intersections (the quartic path).
//
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) Dongxu Li <dongxuli2011@gmail.com> (original equation solvers).
//  Copyright (C) 2001-2003 RibbonSoft.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// Real-root polynomial solvers, a faithful Swift port of LibreCAD's `RS_Math`
/// equation solvers. All inputs/outputs are f64 (ADR-003); the quadratic solver
/// uses extended `Float80` precision internally exactly as the C++ does with
/// `long double`.
///
/// The solvers assume valid arguments (no pointer checks in the original); each
/// returns the real roots, in the same order the C++ produces them.
public enum QuadraticSolver {

    // MARK: - Quadratic

    /// Solves `x² + ce[0]·x + ce[1] = 0`, returning the real roots.
    ///
    /// Faithful port of `RS_Math::quadraticSolver`, including the loss-of-
    /// significance avoidance. The original uses `long double` working precision;
    /// on Apple Silicon `long double == double`, so this f64 port reproduces what
    /// the C++ compiles to on this platform. Returns `[]` for a negative
    /// discriminant, `[b]` for a double root.
    public static func quadratic(_ ce: [Double]) -> [Double] {
        guard ce.count == 2 else { return [] }

        let b = -0.5 * ce[0]
        let c = ce[1]
        // x² - 2 b x + c = 0  =>  (x - b)² = b² - c
        let b2 = b * b
        let discriminant = b2 - c
        let fc = abs(c)

        let TOL = 1e-24

        if discriminant < 0 {
            return []   // negative discriminant, no real root
        }

        // find the radical, avoiding cancellation:
        // given |p| >= |q|, sqrt(p² ± q²) = |p| sqrt(1 ± q²/p²)
        let r: Double
        if b2 >= fc {
            r = abs(b) * (1.0 - c / b2).squareRoot()
        } else {
            // c is negative, because b² - c is non-negative
            r = fc.squareRoot() * (1.0 + b2 / fc).squareRoot()
        }

        var ans: [Double] = []
        if r >= TOL * abs(b) {
            // two roots; pick the sum without cancellation, then Vieta for the other
            let first = (b >= 0) ? (b + r) : (b - r)
            ans.append(first)
            ans.append(c / first)   // Vieta's formula for the second root
        } else {
            // multiple (double) root
            ans.append(b)
        }
        return ans
    }

    // MARK: - Cubic

    /// Solves `x³ + ce[0]·x² + ce[1]·x + ce[2] = 0`, returning the real roots.
    ///
    /// Faithful port of `RS_Math::cubicSolver` — depressed cubic via the
    /// Tschirnhaus shift, Cardano's method (real or complex branch chosen by the
    /// discriminant sign), then a Newton-Raphson polish pass.
    public static func cubic(_ ce: [Double]) -> [Double] {
        guard ce.count == 3 else { return [] }

        var ans: [Double] = []

        // depressed cubic, x = t - b/(3a): t³ + p t + q = 0
        let shift = (1.0 / 3.0) * ce[0]
        let p = ce[1] - shift * ce[0]
        let q = ce[0] * ((2.0 / 27.0) * ce[0] * ce[0] - (1.0 / 3.0) * ce[1]) + ce[2]

        // u³ and v³ are roots of z² + q z - p³/27 = 0
        let discriminant = (1.0 / 27.0) * p * p * p + (1.0 / 4.0) * q * q

        if abs(p) < 1.0e-75 {
            // p≈0 special case: return raw cbrt(q) without the Newton polish,
            // exactly as RS_Math::cubicSolver does (returns before the NR loop).
            ans.append(Foundation.cbrt(q) - shift)
            return ans
        }

        if discriminant.sign != .minus {
            // one real root (Cardano, real branch)
            let ce2 = [q, -1.0 / 27.0 * p * p * p]
            let r = quadratic(ce2)
            if r.isEmpty {
                // should not happen for a valid cubic
                return []
            }
            let u: Double
            if r.count < 2 {
                u = Foundation.cbrt(r[0])
            } else {
                u = (q.sign == .minus) ? Foundation.cbrt(r[0]) : Foundation.cbrt(r[1])
            }
            let v = (-1.0 / 3.0) * p / u
            ans.append(u + v - shift)
        } else {
            // three real roots (Cardano, complex branch)
            var u = Complex(q, 0)
            u = Complex.pow(Complex(-0.5, 0) * u - Complex.sqrt(Complex(0.25, 0) * u * u + Complex(p * p * p / 27.0, 0)), 1.0 / 3.0)
            let w = Complex(-0.5, 3.0.squareRoot() / 2.0)
            let r0 = u - Complex(p, 0) / (Complex(3.0, 0) * u) - Complex(shift, 0)
            let r1 = u * w - Complex(p, 0) / (Complex(3.0, 0) * u * w) - Complex(shift, 0)
            let r2 = u / w - (Complex(p, 0) * w) / (Complex(3.0, 0) * u) - Complex(shift, 0)
            ans.append(r0.re)
            ans.append(r1.re)
            ans.append(r2.re)
        }

        return polishCubic(ans, ce)
    }

    /// Newton-Raphson polish for cubic roots (20 iterations max), as in the C++.
    private static func polishCubic(_ roots: [Double], _ ce: [Double]) -> [Double] {
        var ans = roots
        for i in ans.indices {
            var x0 = ans[i]
            for _ in 0..<20 {
                let f = ((x0 + ce[0]) * x0 + ce[1]) * x0 + ce[2]
                let df = (3.0 * x0 + 2.0 * ce[0]) * x0 + ce[1]
                if abs(df) > abs(f) + Tolerance.distance {
                    x0 -= f / df
                } else {
                    break
                }
            }
            ans[i] = x0
        }
        return ans
    }

    // MARK: - Quartic (monic)

    /// Solves `x⁴ + ce[0]·x³ + ce[1]·x² + ce[2]·x + ce[3] = 0`, returning the
    /// real roots. Faithful port of `RS_Math::quarticSolver`.
    ///
    /// Handles the biquadratic special case, the zero-constant factorization,
    /// and the general resolvent-cubic factorization into two quadratics, with a
    /// final Newton-Raphson polish. Needed for ellipse/ellipse intersections.
    public static func quartic(_ ce: [Double]) -> [Double] {
        guard ce.count == 4 else { return [] }

        var ans: [Double] = []

        // depressed quartic, x = t - a/4: t⁴ + p t² + q t + r = 0
        let shift = 0.25 * ce[0]
        let shift2 = shift * shift
        let a2 = ce[0] * ce[0]
        let p = ce[1] - (3.0 / 8.0) * a2
        let q = ce[2] + ce[0] * ((1.0 / 8.0) * a2 - 0.5 * ce[1])
        let r = ce[3] - shift * ce[2] + (ce[1] - 3.0 * shift2) * shift2

        // Biquadratic special case (q ≈ 0)
        if q * q <= 1.0e-4 * Tolerance.distance * abs(p * r) {
            let discriminant = 0.25 * p * p - r
            if discriminant < -1.0e3 * Tolerance.distance {
                return ans
            }
            var t2 = [Double](repeating: 0, count: 2)
            t2[0] = -0.5 * p - abs(discriminant).squareRoot()
            t2[1] = -p - t2[0]
            if t2[1] >= 0 {
                ans.append(t2[1].squareRoot() - shift)
                ans.append(-t2[1].squareRoot() - shift)
            }
            if t2[0] >= 0 {
                ans.append(t2[0].squareRoot() - shift)
                ans.append(-t2[0].squareRoot() - shift)
            }
            return ans
        }

        // Zero constant term: factor out a root at the shift, solve a cubic
        if abs(r) < 1.0e-75 {
            let cubicCe = [0.0, p, q]
            ans.append(0.0)
            let r3 = cubic(cubicCe)
            ans.append(contentsOf: r3)
            for i in ans.indices { ans[i] -= shift }
            return ans
        }

        // General: resolvent cubic  y³ + 2p y² + (p² - 4r) y - q² = 0,  y = u²
        let cubicCe = [2.0 * p, p * p - 4.0 * r, -q * q]
        let r3 = cubic(cubicCe)
        if r3.isEmpty { return [] }

        if r3.count == 1 {
            // one real root from the cubic
            if r3[0] < 0 {
                // should not happen
                return ans
            }
            let sqrtz0 = r3[0].squareRoot()
            var ce2 = [-sqrtz0, 0.5 * (p + r3[0]) + 0.5 * q / sqrtz0]
            var r1 = quadratic(ce2)
            if r1.isEmpty {
                ce2 = [sqrtz0, 0.5 * (p + r3[0]) - 0.5 * q / sqrtz0]
                r1 = quadratic(ce2)
            }
            for i in r1.indices { r1[i] -= shift }
            return r1
        }

        if r3[0] > 0 && r3[1] > 0 {
            let sqrtz0 = r3[0].squareRoot()
            var ce2 = [-sqrtz0, 0.5 * (p + r3[0]) + 0.5 * q / sqrtz0]
            ans = quadratic(ce2)
            ce2 = [sqrtz0, 0.5 * (p + r3[0]) - 0.5 * q / sqrtz0]
            let r1 = quadratic(ce2)
            ans.append(contentsOf: r1)
            for i in ans.indices { ans[i] -= shift }
        }

        // Newton-Raphson polish
        for i in ans.indices {
            var x0 = ans[i]
            for _ in 0..<20 {
                let f = (((x0 + ce[0]) * x0 + ce[1]) * x0 + ce[2]) * x0 + ce[3]
                let df = ((4.0 * x0 + 3.0 * ce[0]) * x0 + 2.0 * ce[1]) * x0 + ce[2]
                if abs(df) > Tolerance.distanceSquared {
                    x0 -= f / df
                } else {
                    break
                }
            }
            ans[i] = x0
        }

        return ans
    }

    // MARK: - Quartic (general / "full")

    /// Solves `ce[4]·x⁴ + ce[3]·x³ + ce[2]·x² + ce[1]·x + ce[0] = 0`, returning
    /// the real roots. Faithful port of `RS_Math::quarticSolverFull`.
    ///
    /// Degrades gracefully when leading coefficients are (near) zero, dropping to
    /// cubic / quadratic / linear as appropriate.
    public static func quarticFull(_ ce: [Double]) -> [Double] {
        guard ce.count == 5 else { return [] }

        if abs(ce[4]) < 1.0e-14 {
            if abs(ce[3]) < 1.0e-14 {
                if abs(ce[2]) < 1.0e-14 {
                    if abs(ce[1]) > 1.0e-14 {
                        return [-ce[0] / ce[1]]
                    } else {
                        return []   // cannot determine — overlapped, handled elsewhere
                    }
                } else {
                    return quadratic([ce[1] / ce[2], ce[0] / ce[2]])
                }
            } else {
                return cubic([ce[2] / ce[3], ce[1] / ce[3], ce[0] / ce[3]])
            }
        }

        var ce2 = [ce[3] / ce[4], ce[2] / ce[4], ce[1] / ce[4], ce[0] / ce[4]]
        if abs(ce2[3]) <= Tolerance.distance15 {
            // constant term zero: factor out, solve a cubic + add the zero root
            ce2.removeLast()
            var roots = cubic(ce2)
            roots.append(0.0)
            return roots
        }
        return quartic(ce2)
    }

    // MARK: - Linear solver (Gauss-Jordan)

    /// Solves the linear equation set held in the augmented matrix `m`
    /// (each row has `n` coefficients + 1 RHS, so width = `n + 1`), writing the
    /// solution into the return value. Returns `nil` for a singular system.
    ///
    /// Faithful port of `RS_Math::linearSolver` (Gauss-Jordan elimination with
    /// partial pivoting).
    public static func linearSolver(_ m: [[Double]]) -> [Double]? {
        let mSize = m.count          // rows
        let aSize = mSize + 1        // columns of augmented matrix
        guard m.allSatisfy({ $0.count == aSize }) else { return nil }

        var mt0 = m
        for i in 0..<mSize {
            var imax = i
            var cmax = abs(mt0[i][i])
            for j in (i + 1)..<mSize where abs(mt0[j][i]) > cmax {
                imax = j
                cmax = abs(mt0[j][i])
            }
            if cmax < Tolerance.distance { return nil }   // singular
            if imax != i { mt0.swapAt(i, imax) }

            // normalize row i
            for k in (i + 1)...mSize {
                mt0[i][k] /= mt0[i][i]
            }
            mt0[i][i] = 1.0

            // eliminate column i in every other row
            for j in 0..<mSize where j != i {
                let a = mt0[j][i]
                for k in (i + 1)...mSize {
                    mt0[j][k] -= mt0[i][k] * a
                }
                mt0[j][i] = 0.0
            }
        }

        return (0..<mSize).map { mt0[$0][mSize] }
    }

    // MARK: - Simultaneous quadratic solvers (ellipse/conic intersections)

    /// Solves the two simultaneous quadratics whose 8 coefficients are
    /// `[ma000, ma011, ma100, ma101, ma111, mb10, mb11, mc1]`:
    /// ```
    /// ma000 x² + ma011 y² - 1 = 0
    /// ma100 x² + 2 ma101 xy + ma111 y² + mb10 x + mb11 y + mc1 = 0
    /// ```
    /// Faithful port of `RS_Math::simultaneousQuadraticSolver`.
    public static func simultaneousQuadratic(_ m: [Double]) -> VectorSolutions {
        guard m.count == 8 else { return VectorSolutions() }
        let row0 = [m[0], 0.0, m[1], 0.0, 0.0, -1.0]
        let row1 = [m[2], 2.0 * m[3], m[4], m[5], m[6], m[7]]
        return simultaneousQuadraticFull([row0, row1])
    }

    /// Solves two general simultaneous quadratics, each given as 6 coefficients
    /// `[a, b, c, d, e, f]` for `a x² + b xy + c y² + d x + e y + f = 0`.
    ///
    /// Eliminates x to a quartic in y (the resolvent), solves that with the
    /// quartic solver, back-substitutes for x, then verifies & filters the
    /// candidates. Faithful port of `RS_Math::simultaneousQuadraticSolverFull`.
    public static func simultaneousQuadraticFull(_ m: [[Double]]) -> VectorSolutions {
        guard m.count == 2 else { return VectorSolutions() }
        if m[0].count == 3 || m[1].count == 3 {
            return simultaneousQuadraticMixed(m)
        }
        guard m[0].count == 6 && m[1].count == 6 else { return VectorSolutions() }

        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[0][3], e = m[0][4], f = m[0][5]
        let g = m[1][0], h = m[1][1], i = m[1][2], j = m[1][3], k = m[1][4], l = m[1][5]

        let a2 = a * a, b2 = b * b, c2 = c * c, d2 = d * d, e2 = e * e, f2 = f * f
        let g2 = g * g, h2 = h * h, i2 = i * i, j2 = j * j, k2 = k * k, l2 = l * l

        var qy = [Double](repeating: 0, count: 5)
        // y⁴
        qy[4] = -c2 * g2 + b * c * g * h - a * c * h2 - b2 * g * i + 2.0 * a * c * g * i + a * b * h * i - a2 * i2
        // y³
        qy[3] = -2.0 * c * e * g2 + c * d * g * h + b * e * g * h - a * e * h2 - 2.0 * b * d * g * i + 2.0 * a * e * g * i + a * d * h * i
              + b * c * g * j - 2.0 * a * c * h * j + a * b * i * j - b2 * g * k + 2.0 * a * c * g * k + a * b * h * k - 2.0 * a2 * i * k
        // y²
        qy[2] = (-e2 * g2 + d * e * g * h - d2 * g * i + c * d * g * j + b * e * g * j - 2.0 * a * e * h * j + a * d * i * j - a * c * j2
                 - 2.0 * b * d * g * k + 2.0 * a * e * g * k + a * d * h * k + a * b * j * k - a2 * k2 - b2 * g * l + 2.0 * a * c * g * l + a * b * h * l - 2.0 * a2 * i * l)
              - (2.0 * c * f * g2 - b * f * g * h + a * f * h2 - 2.0 * a * f * g * i)
        // y
        qy[1] = (d * e * g * j - a * e * j2 - d2 * g * k + a * d * j * k - 2.0 * b * d * g * l + 2.0 * a * e * g * l + a * d * h * l + a * b * j * l - 2.0 * a2 * k * l)
              - (2.0 * e * f * g2 - d * f * g * h - b * f * g * j + 2.0 * a * f * h * j - 2.0 * a * f * g * k)
        // y⁰
        qy[0] = -d2 * g * l + a * d * j * l - a2 * l2
              - (f2 * g2 - d * f * g * j + a * f * j2 - 2.0 * a * f * g * l)

        let roots = quarticFull(qy)
        if roots.isEmpty { return VectorSolutions() }

        var ret = VectorSolutions()
        for y in roots {
            var ce = [a, b * y + d, c * y * y + e * y + f]
            if abs(ce[0]) < 1.0e-75 && abs(ce[1]) < 1.0e-75 {
                ce = [g, h * y + j, i * y * y + k * y + f]
            }
            if abs(ce[0]) < 1.0e-75 && abs(ce[1]) < 1.0e-75 { continue }

            if abs(a) > 1.0e-75 {
                let xRoots = quadratic([ce[1] / ce[0], ce[2] / ce[0]])
                for x in xRoots {
                    var vp = Vector(x, y)
                    if simultaneousQuadraticVerify(m, &vp) { ret.append(vp) }
                }
                continue
            }
            var vp = Vector(-ce[2] / ce[1], y)
            if simultaneousQuadraticVerify(m, &vp) { ret.append(vp) }
        }

        // filtering: valid, finite, and de-duplicated by RS_TOLERANCE
        var filtered = VectorSolutions()
        for vp in ret {
            guard vp.valid, vp.magnitude <= 1e10 else { continue }
            if filtered.isEmpty || filtered.closestDistance(to: vp) >= Tolerance.distance {
                filtered.append(vp)
            }
        }
        return filtered
    }

    /// Solves a mixed pair where one equation is linear (3 coefficients) and the
    /// other quadratic (6 coefficients). Faithful port of
    /// `RS_Math::simultaneousQuadraticSolverMixed`.
    public static func simultaneousQuadraticMixed(_ m: [[Double]]) -> VectorSolutions {
        var ret = VectorSolutions()
        var p0 = m[0]
        var p1 = m[1]
        if p1.count == 3 { swap(&p0, &p1) }

        if p1.count == 3 {
            // both linear
            var ce = [m[0], m[1]]
            ce[0][2] = -ce[0][2]
            ce[1][2] = -ce[1][2]
            if let sn = linearSolver(ce) {
                ret.append(Vector(sn[0], sn[1]))
            }
            return ret
        }

        // p0 is linear: a x + b y + c = 0 ; p1 quadratic: d x² + e xy + f y² + g x + h y + i = 0
        let a = p0[0], b = p0[1], c = p0[2]
        let d = p1[0], e = p1[1], f = p1[2], g = p1[3], h = p1[4], i = p1[5]

        let a2 = a * a, b2 = b * b, c2 = c * c
        var ce = [Double](repeating: 0, count: 3)
        ce[0] = -f * a2 + a * b * e - b2 * d
        ce[1] = a * b * g - a2 * h - (2.0 * b * c * d - a * c * e)
        ce[2] = a * c * g - c2 * d - a2 * i

        var roots: [Double] = []
        if abs(ce[1]) > Tolerance.distance15 && abs(ce[0] / ce[1]) < Tolerance.distance15 {
            roots.append(-ce[2] / ce[1])
        } else {
            roots = quadratic([ce[1] / ce[0], ce[2] / ce[0]])
        }

        if roots.isEmpty { return VectorSolutions() }

        for x in roots {
            ret.append(Vector(-(b * x + c) / a, x))
        }
        return ret
    }

    /// Verifies (and Newton-refines) a candidate solution of the two quadratics,
    /// mirroring `RS_Math::simultaneousQuadraticVerify` (bug#3606099 tolerance
    /// scheme). Mutates `v` in place toward the refined root.
    public static func simultaneousQuadraticVerify(_ m: [[Double]], _ v: inout Vector) -> Bool {
        let v0 = v
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[0][3], e = m[0][4], f = m[0][5]
        let g = m[1][0], h = m[1][1], i = m[1][2], j = m[1][3], k = m[1][4], l = m[1][5]

        var sum0 = 0.0, sum1 = 0.0
        var f00 = 0.0, f01 = 0.0
        var amax0 = 0.0, amax1 = 0.0

        for i0 in 0..<20 {
            let x = v.x, y = v.y
            let x2 = x * x, y2 = y * y
            let terms0 = [a * x2, b * x * y, c * y2, d * x, e * y, f,
                          g * x2, h * x * y, i * y2, j * x, k * y, l]
            amax0 = abs(terms0[0])
            amax1 = abs(terms0[6])

            var px = 2.0 * a * x + b * y + d
            var py = b * x + 2.0 * c * y + e
            sum0 = 0.0
            for t in 0..<6 {
                if amax0 < abs(terms0[t]) { amax0 = abs(terms0[t]) }
                sum0 += terms0[t]
            }
            var nrCe: [[Double]] = [[px, py, sum0]]

            px = 2.0 * g * x + h * y + j
            py = h * x + 2.0 * i * y + k
            sum1 = 0.0
            for t in 6..<12 {
                if amax1 < abs(terms0[t]) { amax1 = abs(terms0[t]) }
                sum1 += terms0[t]
            }
            nrCe.append([px, py, sum1])

            if i0 == 0 {
                f00 = sum0
                f01 = sum1
            }
            guard let dn = linearSolver(nrCe) else { break }
            v = v - Vector(dn[0], dn[1])
        }

        if abs(sum0) > abs(f00) && abs(sum1) > abs(f01) {
            v = v0
            sum0 = f00
            sum1 = f01
        }

        // experimental tolerances to verify simultaneous quadratics
        let tols = 2.0 * 6.0.squareRoot() * Double.ulpOfOne.squareRoot()
        return (amax0 <= tols || abs(sum0) / amax0 < tols)
            && (amax1 <= tols || abs(sum1) / amax1 < tols)
    }
}

// MARK: - Minimal complex helper (cubic complex branch)

/// A tiny double-precision complex type, just enough for the cubic solver's
/// three-real-root (`casus irreducibilis`) branch. Mirrors the `std::complex`
/// usage in `RS_Math::cubicSolver`.
@usableFromInline
struct Complex {
    @usableFromInline var re: Double
    @usableFromInline var im: Double

    @usableFromInline init(_ re: Double, _ im: Double) {
        self.re = re
        self.im = im
    }

    @usableFromInline static func + (a: Complex, b: Complex) -> Complex {
        Complex(a.re + b.re, a.im + b.im)
    }
    @usableFromInline static func - (a: Complex, b: Complex) -> Complex {
        Complex(a.re - b.re, a.im - b.im)
    }
    @usableFromInline static func * (a: Complex, b: Complex) -> Complex {
        Complex(a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re)
    }
    @usableFromInline static func / (a: Complex, b: Complex) -> Complex {
        let denom = b.re * b.re + b.im * b.im
        return Complex((a.re * b.re + a.im * b.im) / denom,
                       (a.im * b.re - a.re * b.im) / denom)
    }

    @usableFromInline var magnitude: Double { (re * re + im * im).squareRoot() }
    @usableFromInline var argument: Double { atan2(im, re) }

    /// Principal square root.
    @usableFromInline static func sqrt(_ z: Complex) -> Complex {
        let r = z.magnitude.squareRoot()
        let theta = 0.5 * z.argument
        return Complex(r * cos(theta), r * sin(theta))
    }

    /// `z^p` for real exponent `p` (principal branch).
    @usableFromInline static func pow(_ z: Complex, _ p: Double) -> Complex {
        let r = Foundation.pow(z.magnitude, p)
        let theta = z.argument * p
        return Complex(r * cos(theta), r * sin(theta))
    }
}
