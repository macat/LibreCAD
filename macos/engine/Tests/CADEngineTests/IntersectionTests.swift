//
//  IntersectionTests.swift
//  CADEngineTests
//
//  Tests for the pure geometric intersection kernels (Intersections.swift),
//  ported from / inspired by LibreCAD's RS_Information getIntersection* logic,
//  with known-geometry checks (e.g. two unit circles centered (0,0) & (1,0)).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

private let EPS = 1e-9

/// Asserts that `sols` contains a point ~equal to `(x, y)`.
private func contains(_ sols: VectorSolutions, _ x: Double, _ y: Double, tol: Double = 1e-7) -> Bool {
    sols.contains { abs($0.x - x) < tol && abs($0.y - y) < tol }
}

@Suite("Intersections — line/line")
struct LineLineTests {

    @Test("crossing lines intersect at the expected point (infinite)")
    func crossing() {
        // line A: y = x ; line B: y = -x + 2  -> (1, 1)
        let sol = Intersections.lineLine(Vector(0, 0), Vector(2, 2),
                                         Vector(0, 2), Vector(2, 0))
        #expect(sol.count == 1)
        #expect(abs(sol[0].x - 1.0) < EPS)
        #expect(abs(sol[0].y - 1.0) < EPS)
    }

    @Test("parallel lines do not intersect")
    func parallel() {
        let sol = Intersections.lineLine(Vector(0, 0), Vector(2, 0),
                                         Vector(0, 1), Vector(2, 1))
        #expect(sol.isEmpty)
    }

    @Test("segment mode rejects an intersection outside the segments")
    func segmentOutside() {
        // infinite lines cross at (1,1) but segment A ends at (0.5,0.5)
        let inf = Intersections.lineLine(Vector(0, 0), Vector(0.5, 0.5),
                                         Vector(0, 2), Vector(2, 0), segment: false)
        #expect(inf.count == 1)   // infinite line still hits
        let seg = Intersections.lineLine(Vector(0, 0), Vector(0.5, 0.5),
                                         Vector(0, 2), Vector(2, 0), segment: true)
        #expect(seg.isEmpty)      // off the finite segment
    }

    @Test("segment mode accepts an intersection inside both segments")
    func segmentInside() {
        let seg = Intersections.lineLine(Vector(0, 0), Vector(2, 2),
                                         Vector(0, 2), Vector(2, 0), segment: true)
        #expect(seg.count == 1)
        #expect(abs(seg[0].x - 1.0) < EPS)
    }
}

@Suite("Intersections — line/circle and line/arc")
struct LineCircleTests {

    @Test("horizontal line through a unit circle center gives two points")
    func twoPoints() {
        // y = 0 through unit circle at origin -> (-1,0), (1,0)
        let sol = Intersections.lineCircle(line: (Vector(-2, 0), Vector(2, 0)),
                                           center: Vector(0, 0), radius: 1)
        #expect(sol.count == 2)
        #expect(contains(sol, 1, 0))
        #expect(contains(sol, -1, 0))
    }

    @Test("tangent line touches the circle once (tangent flag set)")
    func tangent() {
        // y = 1 tangent to unit circle at (0,1)
        let sol = Intersections.lineCircle(line: (Vector(-2, 1), Vector(2, 1)),
                                           center: Vector(0, 0), radius: 1)
        #expect(sol.count == 1)
        #expect(sol.tangent)
        #expect(abs(sol[0].x - 0.0) < 1e-6)
        #expect(abs(sol[0].y - 1.0) < 1e-6)
    }

    @Test("line missing the circle gives no points")
    func miss() {
        let sol = Intersections.lineCircle(line: (Vector(-2, 2), Vector(2, 2)),
                                           center: Vector(0, 0), radius: 1)
        #expect(sol.isEmpty)
    }

    @Test("line/arc keeps only hits within the arc's angle range")
    func arcRange() {
        // upper-half arc (0..pi) of the unit circle; vertical line x=0 would hit
        // (0,1) and (0,-1) but only (0,1) is on the arc.
        let sol = Intersections.lineArc(line: (Vector(0, -2), Vector(0, 2)),
                                        center: Vector(0, 0), radius: 1,
                                        angle1: 0, angle2: Double.pi, reversed: false)
        #expect(sol.count == 1)
        #expect(contains(sol, 0, 1))
        #expect(!contains(sol, 0, -1))
    }

    @Test("line/circle segment mode trims hits off the segment")
    func circleSegment() {
        // segment only covers x in [0,2]; hits (1,0) yes, (-1,0) no
        let sol = Intersections.lineCircle(line: (Vector(0, 0), Vector(2, 0)),
                                           center: Vector(0, 0), radius: 1, segment: true)
        #expect(sol.count == 1)
        #expect(contains(sol, 1, 0))
    }
}

@Suite("Intersections — circle/circle, circle/arc, arc/arc")
struct CircleCircleTests {

    @Test("two unit circles (0,0)&(1,0) intersect at the expected points")
    func unitCircles() {
        let sol = Intersections.circleCircle(center1: Vector(0, 0), radius1: 1,
                                             center2: Vector(1, 0), radius2: 1)
        #expect(sol.count == 2)
        let yexp = 3.0.squareRoot() / 2.0
        #expect(contains(sol, 0.5, yexp))
        #expect(contains(sol, 0.5, -yexp))
    }

    @Test("externally tangent circles touch once (tangent flag)")
    func tangentCircles() {
        // unit circle at origin and unit circle at (2,0) touch at (1,0)
        let sol = Intersections.circleCircle(center1: Vector(0, 0), radius1: 1,
                                             center2: Vector(2, 0), radius2: 1)
        #expect(sol.count == 1)
        #expect(sol.tangent)
        #expect(contains(sol, 1, 0, tol: 1e-6))
    }

    @Test("separate circles do not intersect")
    func separate() {
        let sol = Intersections.circleCircle(center1: Vector(0, 0), radius1: 1,
                                             center2: Vector(5, 0), radius2: 1)
        #expect(sol.isEmpty)
    }

    @Test("concentric circles do not intersect")
    func concentric() {
        let sol = Intersections.circleCircle(center1: Vector(0, 0), radius1: 1,
                                             center2: Vector(0, 0), radius2: 2)
        #expect(sol.isEmpty)
    }

    @Test("circle/arc filters to the arc range")
    func circleArcRange() {
        // unit circles (0,0) & (1,0) intersect at (0.5, ±√3/2). Arc2 is the upper
        // half of the second circle (angles pi/2..pi about (1,0)) -> keeps only
        // the +y hit which lies at angle 120° about (1,0).
        let yexp = 3.0.squareRoot() / 2.0
        let sol = Intersections.circleArc(circleCenter: Vector(0, 0), circleRadius: 1,
                                          arcCenter: Vector(1, 0), arcRadius: 1,
                                          arcAngle1: Double.pi / 2, arcAngle2: Double.pi,
                                          arcReversed: false)
        #expect(sol.count == 1)
        #expect(contains(sol, 0.5, yexp))
    }

    @Test("arc/arc filters to both arc ranges")
    func arcArcRange() {
        let yexp = 3.0.squareRoot() / 2.0
        // both arcs upper-half so only the +y point survives
        let sol = Intersections.arcArc(center1: Vector(0, 0), radius1: 1,
                                       angle1Start: 0, angle1End: Double.pi, reversed1: false,
                                       center2: Vector(1, 0), radius2: 1,
                                       angle2Start: Double.pi / 2, angle2End: Double.pi, reversed2: false)
        #expect(sol.count == 1)
        #expect(contains(sol, 0.5, yexp))
    }
}

@Suite("Intersections — line/ellipse and ellipse/ellipse")
struct EllipseTests {

    @Test("axis-aligned ellipse: horizontal line through center hits the major-axis endpoints")
    func lineEllipseMajorAxis() {
        // ellipse center origin, major radius 2 along +x, ratio 0.5 (minor = 1)
        let sol = Intersections.lineEllipse(line: (Vector(-3, 0), Vector(3, 0)),
                                            center: Vector(0, 0), majorP: Vector(2, 0), ratio: 0.5)
        #expect(sol.count == 2)
        #expect(contains(sol, 2, 0, tol: 1e-6))
        #expect(contains(sol, -2, 0, tol: 1e-6))
    }

    @Test("axis-aligned ellipse: vertical line through center hits the minor-axis endpoints")
    func lineEllipseMinorAxis() {
        let sol = Intersections.lineEllipse(line: (Vector(0, -3), Vector(0, 3)),
                                            center: Vector(0, 0), majorP: Vector(2, 0), ratio: 0.5)
        #expect(sol.count == 2)
        #expect(contains(sol, 0, 1, tol: 1e-6))
        #expect(contains(sol, 0, -1, tol: 1e-6))
    }

    @Test("line tangent to ellipse top gives a single point")
    func lineEllipseTangent() {
        // ellipse major 2 along x, ratio 0.5 (minor 1) ; line y = 1 tangent at (0,1)
        let sol = Intersections.lineEllipse(line: (Vector(-3, 1), Vector(3, 1)),
                                            center: Vector(0, 0), majorP: Vector(2, 0), ratio: 0.5)
        #expect(sol.count == 1)
        #expect(contains(sol, 0, 1, tol: 1e-6))
    }

    @Test("circle/ellipse: unit circle vs ellipse via the ellipse-ellipse kernel")
    func circleEllipse() {
        // ellipse center origin major 2 along x ratio 0.5 (minor 1); unit circle at origin.
        // Intersections where x²+y²=1 and x²/4 + y²/1 = 1.
        // Solving: from circle y²=1-x²; substitute: x²/4 + 1 - x² = 1 -> -3x²/4 = 0 -> x=0, y=±1.
        let sol = Intersections.circleEllipse(circleCenter: Vector(0, 0), circleRadius: 1,
                                              center: Vector(0, 0), majorP: Vector(2, 0), ratio: 0.5)
        #expect(sol.count == 2)
        #expect(contains(sol, 0, 1, tol: 1e-6))
        #expect(contains(sol, 0, -1, tol: 1e-6))
    }

    @Test("ellipse/ellipse: two orthogonal congruent ellipses intersect at four points")
    func ellipseEllipseFour() {
        // E1: major 2 along x, ratio 0.5 (so x²/4 + y² = 1)
        // E2: major 2 along y, ratio 0.5 (so x² + y²/4 = 1)
        // By symmetry the four solutions are at x = ±y with x² + 4x²... solve:
        //   x²/4 + y² = 1 and x² + y²/4 = 1 -> subtract -> x² = y² -> x=±y
        //   x²/4 + x² = 1 -> 5x²/4 = 1 -> x² = 0.8 -> x = ±0.894427...
        let sol = Intersections.ellipseEllipse(center1: Vector(0, 0), majorP1: Vector(2, 0), ratio1: 0.5,
                                               center2: Vector(0, 0), majorP2: Vector(0, 2), ratio2: 0.5)
        #expect(sol.count == 4)
        let v = (0.8).squareRoot()
        #expect(contains(sol, v, v, tol: 1e-6))
        #expect(contains(sol, v, -v, tol: 1e-6))
        #expect(contains(sol, -v, v, tol: 1e-6))
        #expect(contains(sol, -v, -v, tol: 1e-6))
    }

    @Test("identical ellipses report no overlap intersections")
    func ellipseOverlap() {
        let sol = Intersections.ellipseEllipse(center1: Vector(0, 0), majorP1: Vector(2, 0), ratio1: 0.5,
                                               center2: Vector(0, 0), majorP2: Vector(2, 0), ratio2: 0.5)
        #expect(sol.isEmpty)
    }
}

@Suite("VectorSolutions — conveniences")
struct VectorSolutionsTests {

    @Test("count / isEmpty / get range safety")
    func basics() {
        var sols = VectorSolutions()
        #expect(sols.isEmpty)
        #expect(sols.count == 0)
        #expect(!sols.get(0).valid)   // out of range -> invalid

        sols.append(Vector(1, 2))
        sols.append(Vector(3, 4))
        #expect(sols.count == 2)
        #expect(!sols.isEmpty)
        #expect(sols.get(1) == Vector(3, 4))
        #expect(!sols.get(5).valid)
    }

    @Test("closest(to:) finds the nearest point")
    func closest() {
        let sols = VectorSolutions([Vector(0, 0), Vector(10, 0), Vector(3, 4)])
        let (p, dist): (Vector, Double) = sols.closest(to: Vector(2, 4))
        #expect(p == Vector(3, 4))
        #expect(abs(dist - 1.0) < EPS)
    }

    @Test("map / moved / rotated preserve the tangent flag")
    func transforms() {
        var sols = VectorSolutions([Vector(1, 0)])
        sols.tangent = true
        let moved = sols.moved(by: Vector(1, 1))
        #expect(moved.tangent)
        #expect(moved[0] == Vector(2, 1))

        let rotated = VectorSolutions([Vector(1, 0)]).rotated(by: Double.pi / 2)
        #expect(abs(rotated[0].x - 0.0) < 1e-9)
        #expect(abs(rotated[0].y - 1.0) < 1e-9)
    }

    @Test("flippedXY swaps coordinates")
    func flip() {
        let sols = VectorSolutions([Vector(1, 2), Vector(3, 4)]).flippedXY()
        #expect(sols[0] == Vector(2, 1))
        #expect(sols[1] == Vector(4, 3))
    }
}
