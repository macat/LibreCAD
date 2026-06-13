//
//  MathTests.swift
//  CADEngineTests
//
//  Ported from LibreCAD's math unit tests:
//    - librecad/src/lib/math/tests/rs_math_tests.cpp  (correctAngle, rad2deg,
//      deg2rad, rad2gra, gra2rad)
//    - the RS_Math::test() quadratic-solver cases in rs_math.cpp
//    - librecad/src/lib/math/tests/lc_quadratic_tests.cpp (constructors,
//      coefficients, line-line/circle-circle/circle-line via LC_Quadratic,
//      flipXY symmetry)
//  plus cubic/quartic solver checks.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

private let EPS = 1e-6

// MARK: - RS_Math scalar helpers (port of rs_math_tests.cpp)

@Suite("MathUtils — RS_Math scalar helpers")
struct MathUtilsTests {

    @Test("correctAngle (port of RS_Math::correctAngle cases)")
    func correctAngle() {
        #expect(abs(MathUtils.correctAngle(0.0) - 0.0) < EPS)
        #expect(abs(MathUtils.correctAngle(2 * Double.pi) - 0.0) < EPS)
        #expect(abs(MathUtils.correctAngle(-Double.pi) - Double.pi) < EPS)
        #expect(abs(MathUtils.correctAngle(3 * Double.pi) - Double.pi) < EPS)
        #expect(abs(MathUtils.correctAngle(4 * Double.pi + Double.pi / 2) - Double.pi / 2) < EPS)
    }

    @Test("rad2deg (port of RS_Math::rad2deg cases)")
    func rad2deg() {
        #expect(abs(MathUtils.rad2deg(0.0) - 0.0) < EPS)
        #expect(abs(MathUtils.rad2deg(Double.pi) - 180.0) < EPS)
        #expect(abs(MathUtils.rad2deg(Double.pi / 2) - 90.0) < EPS)
        #expect(abs(MathUtils.rad2deg(-Double.pi) - -180.0) < EPS)
    }

    @Test("deg2rad (port of RS_Math::deg2rad cases)")
    func deg2rad() {
        #expect(abs(MathUtils.deg2rad(0.0) - 0.0) < EPS)
        #expect(abs(MathUtils.deg2rad(180.0) - Double.pi) < EPS)
        #expect(abs(MathUtils.deg2rad(90.0) - Double.pi / 2) < EPS)
        #expect(abs(MathUtils.deg2rad(-180.0) - -Double.pi) < EPS)
    }

    @Test("rad2gra (port of RS_Math::rad2gra cases)")
    func rad2gra() {
        #expect(abs(MathUtils.rad2gra(0.0) - 0.0) < EPS)
        #expect(abs(MathUtils.rad2gra(Double.pi) - 200.0) < EPS)
        #expect(abs(MathUtils.rad2gra(Double.pi / 2) - 100.0) < EPS)
    }

    @Test("gra2rad (port of RS_Math::gra2rad cases)")
    func gra2rad() {
        #expect(abs(MathUtils.gra2rad(0.0) - 0.0) < EPS)
        #expect(abs(MathUtils.gra2rad(200.0) - Double.pi) < EPS)
        #expect(abs(MathUtils.gra2rad(100.0) - Double.pi / 2) < EPS)
    }

    @Test("getAngleDifference is the CCW sweep a1 -> a2")
    func angleDifference() {
        #expect(abs(MathUtils.getAngleDifference(0, Double.pi / 2) - Double.pi / 2) < EPS)
        // wrapping: from 3pi/2 to 0 is pi/2 CCW
        #expect(abs(MathUtils.getAngleDifference(3 * Double.pi / 2, 0) - Double.pi / 2) < EPS)
        // reversed swaps the direction
        #expect(abs(MathUtils.getAngleDifference(0, Double.pi / 2, reversed: true) - 3 * Double.pi / 2) < EPS)
    }

    @Test("isAngleBetween across the 0 boundary")
    func angleBetween() {
        // arc from 7pi/4 to pi/4 (passing through 0)
        #expect(MathUtils.isAngleBetween(0, 7 * Double.pi / 4, Double.pi / 4))
        #expect(!MathUtils.isAngleBetween(Double.pi, 7 * Double.pi / 4, Double.pi / 4))
        // simple arc 0..pi
        #expect(MathUtils.isAngleBetween(Double.pi / 2, 0, Double.pi))
        #expect(!MathUtils.isAngleBetween(3 * Double.pi / 2, 0, Double.pi))
        // reversed (CW) arc 0..pi excludes pi/2 but includes 3pi/2
        #expect(!MathUtils.isAngleBetween(Double.pi / 2, 0, Double.pi, reversed: true))
        #expect(MathUtils.isAngleBetween(3 * Double.pi / 2, 0, Double.pi, reversed: true))
    }

    @Test("round to nearest and to precision")
    func rounding() {
        #expect(MathUtils.round(2.4) == 2)
        #expect(MathUtils.round(2.6) == 3)
        #expect(MathUtils.round(-2.5) == -3)   // round half away from zero
        #expect(abs(MathUtils.round(0.123, precision: 0.01) - 0.12) < EPS)
        #expect(abs(MathUtils.round(0.127, precision: 0.05) - 0.15) < EPS)
    }

    @Test("ULP-based equality")
    func ulpEqual() {
        #expect(MathUtils.equal(1.0, 1.0))
        #expect(MathUtils.equal(1.0, 1.0 + Double.ulpOfOne))
        #expect(!MathUtils.equal(1.0, 1.0001))
        #expect(MathUtils.equal(1.0, 1.0001, tolerance: 1e-3))
    }
}

// MARK: - Quadratic / cubic / quartic solvers

@Suite("QuadraticSolver — real-root solvers")
struct SolverTests {

    /// Port of the quadratic test cases in RS_Math::test():
    /// equations x^2 + v[0] x + v[1] = 0 with known roots.
    @Test("quadraticSolver matches RS_Math::test() reference roots")
    func quadraticReference() {
        let eqns: [[Double]] = [
            [-1.0, -1.0],
            [-101.0, -1.0],
            [-1.0, -100.0],
            [2.0, 1.0],
            [-2.0, 1.0],
        ]
        let roots: [[Double]] = [
            [-0.6180339887498948, 1.6180339887498948],
            [-0.0099000196991084878, 101.009900019699108],
            [-9.5124921972503929, 10.5124921972503929],
            [-1.0],
            [1.0],
        ]
        for i in 0..<eqns.count {
            var sol = QuadraticSolver.quadratic(eqns[i])
            #expect(sol.count == roots[i].count)
            sol.sort()
            let expected = roots[i].sorted()
            for j in 0..<sol.count {
                let x0 = sol[j], x1 = expected[j]
                let prec = (x0 - x1) / (abs(x0 + x1) + Tolerance.distanceSquared)
                #expect(abs(prec) < Tolerance.distance)
            }
        }
    }

    @Test("quadratic: negative discriminant has no real root")
    func quadraticNoRoot() {
        // x^2 + 1 = 0
        #expect(QuadraticSolver.quadratic([0.0, 1.0]).isEmpty)
    }

    @Test("quadratic: double root")
    func quadraticDouble() {
        // x^2 - 2x + 1 = (x-1)^2
        let sol = QuadraticSolver.quadratic([-2.0, 1.0])
        #expect(sol.count == 1)
        #expect(abs(sol[0] - 1.0) < EPS)
    }

    @Test("cubic: three real roots (x-1)(x-2)(x-3)")
    func cubicThreeRoots() {
        // x^3 - 6x^2 + 11x - 6 = 0
        let sol = QuadraticSolver.cubic([-6.0, 11.0, -6.0]).sorted()
        #expect(sol.count == 3)
        #expect(abs(sol[0] - 1.0) < EPS)
        #expect(abs(sol[1] - 2.0) < EPS)
        #expect(abs(sol[2] - 3.0) < EPS)
    }

    @Test("cubic: one real root x^3 + x - 2 = 0 (single real root at 1)")
    func cubicOneRoot() {
        // p != 0 path (Cardano real branch). x^3 + x - 2 = (x-1)(x^2+x+2).
        let sol = QuadraticSolver.cubic([0.0, 1.0, -2.0])
        #expect(sol.count == 1)
        #expect(abs(sol[0] - 1.0) < EPS)
    }

    @Test("cubic p≈0 special case mirrors LibreCAD's cbrt(q) branch")
    func cubicDepressedSpecialCase() {
        // Faithful port note: for x^3 = c (p≈0), RS_Math::cubicSolver returns
        // cbrt(q) where q is the constant term, NOT the mathematically expected
        // cbrt(-q). We reproduce that behavior exactly so the kernel stays bit-
        // for-bit compatible with the C++ engine.
        let sol = QuadraticSolver.cubic([0.0, 0.0, -1.0])   // x^3 - 1
        #expect(sol.count == 1)
        #expect(abs(sol[0] - -1.0) < EPS)   // cbrt(q) = cbrt(-1) = -1 (as in LibreCAD)
    }

    @Test("quartic: four real roots (x-1)(x-2)(x-3)(x-4)")
    func quarticFourRoots() {
        // x^4 - 10x^3 + 35x^2 - 50x + 24 = 0
        let sol = QuadraticSolver.quartic([-10.0, 35.0, -50.0, 24.0]).sorted()
        #expect(sol.count == 4)
        #expect(abs(sol[0] - 1.0) < 1e-5)
        #expect(abs(sol[1] - 2.0) < 1e-5)
        #expect(abs(sol[2] - 3.0) < 1e-5)
        #expect(abs(sol[3] - 4.0) < 1e-5)
    }

    @Test("quartic: biquadratic x^4 - 5x^2 + 4 (roots ±1, ±2)")
    func quarticBiquadratic() {
        let sol = QuadraticSolver.quartic([0.0, -5.0, 0.0, 4.0]).sorted()
        #expect(sol.count == 4)
        #expect(abs(sol[0] - -2.0) < 1e-6)
        #expect(abs(sol[1] - -1.0) < 1e-6)
        #expect(abs(sol[2] - 1.0) < 1e-6)
        #expect(abs(sol[3] - 2.0) < 1e-6)
    }

    @Test("quarticFull degrades to quadratic when leading coeffs are zero")
    func quarticFullDegrade() {
        // 0 x^4 + 0 x^3 + 1 x^2 + 0 x - 4 = 0  -> roots ±2
        let sol = QuadraticSolver.quarticFull([-4.0, 0.0, 1.0, 0.0, 0.0]).sorted()
        #expect(sol.count == 2)
        #expect(abs(sol[0] - -2.0) < EPS)
        #expect(abs(sol[1] - 2.0) < EPS)
    }

    @Test("linearSolver solves a 2x2 system")
    func linear2x2() {
        // x + y = 3 ; x - y = 1  -> (2, 1)
        let sn = QuadraticSolver.linearSolver([[1, 1, 3], [1, -1, 1]])
        #expect(sn != nil)
        #expect(abs(sn![0] - 2.0) < EPS)
        #expect(abs(sn![1] - 1.0) < EPS)
    }

    @Test("linearSolver returns nil for a singular system")
    func linearSingular() {
        // x + y = 1 ; 2x + 2y = 3  -> no unique solution
        #expect(QuadraticSolver.linearSolver([[1, 1, 1], [2, 2, 3]]) == nil)
    }
}

// MARK: - LC_Quadratic (port of lc_quadratic_tests.cpp)

@Suite("LCQuadratic — conic algebra (port of lc_quadratic_tests.cpp)")
struct LCQuadraticTests {

    /// Helper: circle in coefficient form (as makeCircleCoeffs in the C++ test).
    private func makeCircle(_ cx: Double, _ cy: Double, _ r: Double) -> LCQuadratic {
        LCQuadratic(circleCenter: Vector(cx, cy), radius: r)
    }

    @Test("Perpendicular bisector constructor produces expected vertical line")
    func bisectorVertical() {
        let bis = LCQuadratic(perpendicularBisectorOf: Vector(0, 0), Vector(2, 0))
        #expect(bis.isValid)
        #expect(!bis.isQuadratic)
        let ce = bis.coefficients()
        #expect(ce.count >= 3)
        // vertical line x = 1 => 1*x + 0*y - 1 == 0
        #expect(abs(ce[0] - 1.0) < 1e-12)
        #expect(abs(ce[1] - 0.0) < 1e-12)
        #expect(abs(ce[2] - -1.0) < 1e-12)
    }

    @Test("Two circles intersection (coeff-based) gives the standard two points")
    func circleCircleStandard() {
        // circle1 at (0,0) r=1 ; circle2 at (1,0) r=1
        let c1 = makeCircle(0, 0, 1)
        let c2 = makeCircle(1, 0, 1)
        let sol = LCQuadratic.getIntersection(c1, c2)
        #expect(sol.count == 2)

        let xexp = 0.5
        let yexp = 3.0.squareRoot() / 2.0
        var foundPos = false, foundNeg = false
        for p in sol {
            if abs(p.x - xexp) < 1e-9 && abs(p.y - yexp) < 1e-9 { foundPos = true }
            if abs(p.x - xexp) < 1e-9 && abs(p.y - -yexp) < 1e-9 { foundNeg = true }
        }
        #expect(foundPos)
        #expect(foundNeg)
    }

    @Test("Line-line intersection: intersecting and parallel cases")
    func lineLineCoeff() {
        // intersecting lines x=1 and y=2
        let l1 = LCQuadratic([1.0, 0.0, -1.0])
        let l2 = LCQuadratic([0.0, 1.0, -2.0])
        let sol = LCQuadratic.getIntersection(l1, l2)
        #expect(sol.count == 1)
        #expect(abs(sol[0].x - 1.0) < 1e-12)
        #expect(abs(sol[0].y - 2.0) < 1e-12)

        // parallel lines x=1 and x=2 -> no intersection
        let p1 = LCQuadratic([1.0, 0.0, -1.0])
        let p2 = LCQuadratic([1.0, 0.0, -2.0])
        #expect(LCQuadratic.getIntersection(p1, p2).isEmpty)
    }

    @Test("FlipXY symmetry: intersections stable under flip and flip-back")
    func flipXYSymmetry() {
        let circ = makeCircle(0, 0, 2)
        let line = LCQuadratic([0.0, 1.0, -1.0])   // y = 1
        let sol1 = LCQuadratic.getIntersection(circ, line)
        #expect(sol1.count == 2)

        let sol2 = LCQuadratic.getIntersection(circ.flippedXY(), line.flippedXY()).flippedXY()
        #expect(sol2.count == sol1.count)

        for p in sol1 {
            var found = false
            for q in sol2 where abs(p.x - q.x) < 1e-9 && abs(p.y - q.y) < 1e-9 {
                found = true
                break
            }
            #expect(found)
        }
    }

    @Test("Invalid coefficient count yields invalid quadratic")
    func invalidConstruction() {
        #expect(!LCQuadratic([1.0, 2.0]).isValid)
        #expect(!LCQuadratic([]).isValid)
        #expect(LCQuadratic([1, 0, 1, 0, 0, -1]).isValid)
    }

    @Test("evaluateAt the conic is zero on its locus")
    func evaluateOnLocus() {
        let circ = makeCircle(0, 0, 1)
        // (1,0) is on the unit circle
        #expect(abs(circ.evaluate(at: Vector(1, 0))) < 1e-12)
        // origin is inside -> negative
        #expect(circ.evaluate(at: Vector(0, 0)) < 0)
    }
}
