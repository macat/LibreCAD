//
//  EntitySetTests.swift
//  CADEngineTests
//
//  Phase 1 workstream B — Ellipse + Spline (NURBS) + SplinePoints (quadratic
//  Bézier). Verifies the ADR-001 computed-geometry path (resolve() + analytic /
//  conservative boundingBox()) for the entity-set expansion, ported from
//  RS_Ellipse / RS_Spline / LC_SplinePoints.
//
//  Spline is a known bug-farm — these tests pin endpoint interpolation (clamped
//  knot vector) and a mid-curve evaluation against hand-computed values.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

private let tol = 1e-9

// MARK: - Ellipse

@Suite("ellipse entity resolve + bbox")
struct EllipseEntityTests {

    /// An axis-aligned ellipse: majorP along +X, so rotation == 0.
    private func axisAlignedFullEllipse() -> EllipseData {
        EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
    }

    @Test("ellipsePoint maps parametric angles onto the ellipse")
    func ellipsePointParametric() {
        let d = axisAlignedFullEllipse() // a = 10, b = 5
        // angle 0 → (a, 0); angle π/2 → (0, b); angle π → (-a, 0).
        #expect(d.ellipsePoint(0).distance(to: Vector(10, 0)) < tol)
        #expect(d.ellipsePoint(.pi / 2).distance(to: Vector(0, 5)) < tol)
        #expect(d.ellipsePoint(.pi).distance(to: Vector(-10, 0)) < tol)
    }

    @Test("full ellipse resolves to a closed ring, every point on the curve")
    func fullEllipseResolves() {
        let d = axisAlignedFullEllipse()
        let e = EntityRecord(id: EntityID(1), kind: .ellipse(d))
        let geo = e.resolve(ResolveContext(tessellationTolerance: 0.001))
        #expect(geo.polylines.count == 1)
        let poly = geo.polylines[0]
        #expect(poly.closed == true)
        #expect(poly.points.count >= 3)
        // No duplicated closing vertex (same convention as circlePoints).
        #expect(poly.points.first != poly.points.last)
        // The implicit ellipse equation (x/a)² + (y/b)² == 1 holds on every vertex.
        let a = 10.0, b = 5.0
        for p in poly.points {
            let f = (p.x / a) * (p.x / a) + (p.y / b) * (p.y / b)
            #expect(abs(f - 1.0) < 1e-3)
        }
    }

    @Test("rotated ellipse: a point lands at the rotated major endpoint")
    func rotatedEllipsePointOnCurve() {
        // major axis rotated 45°, major radius 10, ratio 0.4.
        let angle = Double.pi / 4
        let majorP = Vector(10 * cos(angle), 10 * sin(angle))
        let d = EllipseData(center: Vector(3, -2), majorP: majorP, ratio: 0.4)
        // parametric angle 0 → center + majorP (the major-axis endpoint).
        let p0 = d.ellipsePoint(0)
        #expect(p0.distance(to: Vector(3, -2) + majorP) < tol)
        // parametric angle π/2 → center + minorP (perp to major, length b).
        let minorP = Vector(-majorP.y, majorP.x) * 0.4
        #expect(d.ellipsePoint(.pi / 2).distance(to: Vector(3, -2) + minorP) < tol)
    }

    @Test("full axis-aligned ellipse bbox is the analytic a/b box")
    func fullEllipseBBox() {
        let d = axisAlignedFullEllipse() // a=10, b=5, centered origin
        let box = EntityRecord(id: EntityID(1), kind: .ellipse(d)).boundingBox()
        #expect(abs(box.min.x - (-10)) < tol)
        #expect(abs(box.max.x - 10) < tol)
        #expect(abs(box.min.y - (-5)) < tol)
        #expect(abs(box.max.y - 5) < tol)
    }

    @Test("rotated full ellipse bbox matches sqrt((a·cosθ)²+(b·sinθ)²) extent")
    func rotatedEllipseBBox() {
        let theta = Double.pi / 6 // 30°
        let a = 12.0, b = 4.0
        let majorP = Vector(a * cos(theta), a * sin(theta))
        let d = EllipseData(center: Vector(0, 0), majorP: majorP, ratio: b / a)
        let box = EntityRecord(id: EntityID(1), kind: .ellipse(d)).boundingBox()
        // Closed-form half-extents of a rotated ellipse.
        let hx = sqrt(pow(a * cos(theta), 2) + pow(b * sin(theta), 2))
        let hy = sqrt(pow(a * sin(theta), 2) + pow(b * cos(theta), 2))
        #expect(abs(box.max.x - hx) < 1e-7)
        #expect(abs(box.min.x + hx) < 1e-7)
        #expect(abs(box.max.y - hy) < 1e-7)
        #expect(abs(box.min.y + hy) < 1e-7)
    }

    @Test("elliptic arc resolves open and respects the sweep endpoints")
    func ellipticArcSweep() {
        // Quarter arc of an axis-aligned a=10,b=5 ellipse: parametric 0 → π/2.
        let d = EllipseData(
            center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5,
            startAngle: 0, endAngle: .pi / 2, reversed: false
        )
        let e = EntityRecord(id: EntityID(1), kind: .ellipse(d))
        let geo = e.resolve(ResolveContext(tessellationTolerance: 0.001))
        let poly = geo.polylines[0]
        #expect(poly.closed == false)
        #expect(poly.points.count >= 2)
        // Endpoints land on the parametric start/end (a,0) and (0,b).
        #expect(poly.points.first!.distance(to: Vector(10, 0)) < 1e-6)
        #expect(poly.points.last!.distance(to: Vector(0, 5)) < 1e-6)
        // The whole quarter arc stays in the first quadrant (x>=0, y>=0).
        for p in poly.points {
            #expect(p.x >= -1e-6)
            #expect(p.y >= -1e-6)
        }
    }

    @Test("reversed elliptic arc travels the CW (long-way) path")
    func reversedEllipticArc() {
        // Same start/end parametric angles but reversed: CW from 0 goes 0 → -ε …
        // → π/2 the long way, dipping below the x-axis early on.
        let d = EllipseData(
            center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5,
            startAngle: 0, endAngle: .pi / 2, reversed: true
        )
        let e = EntityRecord(id: EntityID(1), kind: .ellipse(d))
        let geo = e.resolve(ResolveContext(tessellationTolerance: 0.01))
        let pts = geo.polylines[0].points
        #expect(pts.first!.distance(to: Vector(10, 0)) < 1e-6)
        #expect(pts.last!.distance(to: Vector(0, 5)) < 1e-6)
        // An early sample on the CW path is below the x-axis (y < 0).
        let early = pts[max(1, pts.count / 8)]
        #expect(early.y < 0)
    }

    @Test("elliptic arc bbox includes a swept parametric extreme")
    func ellipticArcBBoxExtreme() {
        // Axis-aligned a=10,b=5, arc from parametric -π/2 (-> (0,-5)) to π/2
        // (-> (0,5)) CCW passes through parametric 0 (-> (10,0)), so maxX == 10
        // even though neither endpoint reaches it.
        let d = EllipseData(
            center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5,
            startAngle: -.pi / 2, endAngle: .pi / 2, reversed: false
        )
        let box = EntityRecord(id: EntityID(1), kind: .ellipse(d)).boundingBox()
        #expect(abs(box.max.x - 10) < 1e-7)   // parametric 0 is swept
        #expect(abs(box.max.y - 5) < 1e-7)    // endpoint (0,5)
        #expect(abs(box.min.y + 5) < 1e-7)    // endpoint (0,-5)
        // minX is the chord side (x>=0): the arc never reaches -10 (π not swept).
        #expect(box.min.x > -1e-7)
    }
}

// MARK: - Spline (NURBS)

@Suite("spline (NURBS) resolve + bbox")
struct SplineNURBSTests {

    /// A cubic clamped B-spline interpolates its first and last control points.
    @Test("clamped cubic spline interpolates the endpoints")
    func clampedCubicEndpoints() {
        let cps = [
            Vector(0, 0), Vector(1, 4), Vector(3, 4), Vector(4, 0),
            Vector(6, -3), Vector(8, 1),
        ]
        let d = SplineData(degree: 3, controlPoints: cps) // empty knots → clamped
        let e = EntityRecord(id: EntityID(1), kind: .spline(d))
        let geo = e.resolve(ResolveContext(tessellationTolerance: 0.001))
        let pts = geo.polylines[0].points
        #expect(pts.count >= 2)
        // Clamped knot vector ⇒ curve passes exactly through the end control pts.
        #expect(pts.first!.distance(to: cps.first!) < 1e-7)
        #expect(pts.last!.distance(to: cps.last!) < 1e-7)
    }

    @Test("degree-1 spline is the control polygon (line-segment interpolation)")
    func degreeOneSplineIsPolygon() {
        // A degree-1 B-spline with a clamped knot vector IS the polyline through
        // its control points, so the curve interpolates EVERY control point.
        let cps = [Vector(0, 0), Vector(5, 5), Vector(10, 0)]
        let d = SplineData(degree: 1, controlPoints: cps)
        guard let U = NURBS.knotVector(for: d) else {
            Issue.record("degree-1 knot vector should generate")
            return
        }
        // The interior control point sits at the interior knot value.
        let mid = NURBS.evaluate(d, knots: U, at: U[2])
        #expect(mid.distance(to: Vector(5, 5)) < 1e-9)
    }

    @Test("cubic Bézier (4 cps, single span) matches the analytic Bézier point")
    func cubicBezierMidpoint() {
        // 4 control points + clamped cubic knots == a single cubic Bézier patch.
        // Evaluate at the parametric midpoint and compare to the Bernstein form.
        let p0 = Vector(0, 0), p1 = Vector(0, 6), p2 = Vector(6, 6), p3 = Vector(6, 0)
        let d = SplineData(degree: 3, controlPoints: [p0, p1, p2, p3])
        guard let U = NURBS.knotVector(for: d) else {
            Issue.record("cubic knot vector should generate")
            return
        }
        // Domain is [U[3], U[4]]; pick the midpoint parameter.
        let t = 0.5 * (U[3] + U[4])
        let got = NURBS.evaluate(d, knots: U, at: t)
        // Bernstein cubic at u=0.5: (p0 + 3p1 + 3p2 + p3) / 8.
        let want = (p0 + p1 * 3.0 + p2 * 3.0 + p3) * (1.0 / 8.0)
        #expect(got.distance(to: want) < 1e-9)
    }

    @Test("explicit clamped knot vector is used as-is")
    func explicitKnotVector() {
        // 4 cps, degree 3, clamped knots [0,0,0,0,1,1,1,1] → cubic Bézier on [0,1].
        let p0 = Vector(0, 0), p1 = Vector(1, 3), p2 = Vector(3, 3), p3 = Vector(4, 0)
        let d = SplineData(
            degree: 3,
            controlPoints: [p0, p1, p2, p3],
            knots: [0, 0, 0, 0, 1, 1, 1, 1]
        )
        let kv = NURBS.knotVector(for: d)
        #expect(kv == [0, 0, 0, 0, 1, 1, 1, 1])
        // Endpoints interpolate.
        #expect(NURBS.evaluate(d, knots: kv!, at: 0).distance(to: p0) < 1e-9)
        #expect(NURBS.evaluate(d, knots: kv!, at: 1).distance(to: p3) < 1e-9)
    }

    @Test("rational weights bias the curve toward a heavy control point")
    func rationalWeightsBiasCurve() {
        // Same cubic, but a heavy weight on p1/p2 pulls the midpoint upward
        // compared to the non-rational case.
        let p0 = Vector(0, 0), p1 = Vector(0, 6), p2 = Vector(6, 6), p3 = Vector(6, 0)
        let plain = SplineData(degree: 3, controlPoints: [p0, p1, p2, p3])
        let heavy = SplineData(
            degree: 3, controlPoints: [p0, p1, p2, p3],
            weights: [1, 8, 8, 1]
        )
        let Up = NURBS.knotVector(for: plain)!
        let Uh = NURBS.knotVector(for: heavy)!
        let tMid = 0.5 * (Up[3] + Up[4])
        let yPlain = NURBS.evaluate(plain, knots: Up, at: tMid).y
        let yHeavy = NURBS.evaluate(heavy, knots: Uh, at: tMid).y
        #expect(yHeavy > yPlain)   // pulled toward the heavy (high-y) control pts
    }

    @Test("finer tolerance yields more spline segments")
    func splineToleranceRefines() {
        let cps = [Vector(0, 0), Vector(10, 30), Vector(30, 30), Vector(40, 0)]
        let coarse = NURBS.tessellate(SplineData(degree: 3, controlPoints: cps), tolerance: 5.0)!
        let fine = NURBS.tessellate(SplineData(degree: 3, controlPoints: cps), tolerance: 0.01)!
        #expect(fine.count > coarse.count)
    }

    @Test("degenerate spline (too few control points) falls back to control polygon")
    func degenerateSplineFallback() {
        // degree 3 needs >=4 cps; with 2 it can't evaluate, so resolve() returns
        // the control polygon so it's at least visible.
        let cps = [Vector(0, 0), Vector(5, 5)]
        let d = SplineData(degree: 3, controlPoints: cps)
        #expect(NURBS.knotVector(for: d) == nil)
        let geo = EntityRecord(id: EntityID(1), kind: .spline(d)).resolve()
        #expect(geo.polylines[0].points == cps)
    }

    @Test("spline bbox is the control-point hull box (conservative)")
    func splineBBox() {
        let cps = [Vector(0, 0), Vector(1, 10), Vector(9, 10), Vector(10, 0)]
        let box = EntityRecord(id: EntityID(1), kind: .spline(SplineData(degree: 3, controlPoints: cps))).boundingBox()
        #expect(box.min == Vector(0, 0))
        #expect(box.max == Vector(10, 10))
        // The resolved curve must lie inside the (conservative) hull box.
        let pts = NURBS.tessellate(SplineData(degree: 3, controlPoints: cps), tolerance: 0.01)!
        for p in pts { #expect(box.contains(p)) }
    }
}

// MARK: - SplinePoints (quadratic Bézier interpolation spline)

@Suite("splinePoints (quadratic Bézier) resolve + bbox")
struct SplinePointsTests {

    @Test("GetQuadPoint matches the Bernstein quadratic")
    func quadPointBernstein() {
        let x1 = Vector(0, 0), c1 = Vector(2, 4), x2 = Vector(4, 0)
        // t = 0.5 ⇒ (x1 + 2·c1 + x2)/4.
        let got = QuadSpline.point(x1, c1, x2, 0.5)
        let want = (x1 + c1 * 2.0 + x2) * 0.25
        #expect(got.distance(to: want) < tol)
        #expect(QuadSpline.point(x1, c1, x2, 0).distance(to: x1) < tol)
        #expect(QuadSpline.point(x1, c1, x2, 1).distance(to: x2) < tol)
    }

    @Test("open splinePoints interpolates the first and last control points")
    func openSplinePointsEndpoints() {
        let cps = [Vector(0, 0), Vector(2, 5), Vector(6, 5), Vector(8, 0)]
        let d = SplinePointsData(controlPoints: cps, closed: false)
        let e = EntityRecord(id: EntityID(1), kind: .splinePoints(d))
        let geo = e.resolve(ResolveContext(tessellationTolerance: 0.01))
        let poly = geo.polylines[0]
        #expect(poly.closed == false)
        #expect(poly.points.count >= 3)
        // Open LC_SplinePoints anchors at the first and last control points.
        #expect(poly.points.first!.distance(to: cps.first!) < 1e-9)
        #expect(poly.points.last!.distance(to: cps.last!) < 1e-9)
    }

    @Test("closed splinePoints resolves closed with no duplicated vertex")
    func closedSplinePoints() {
        let cps = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let d = SplinePointsData(controlPoints: cps, closed: true)
        let geo = EntityRecord(id: EntityID(1), kind: .splinePoints(d)).resolve()
        let poly = geo.polylines[0]
        #expect(poly.closed == true)
        #expect(poly.points.count >= 3)
        #expect(poly.points.first != poly.points.last)
    }

    @Test("3-control-point open splinePoints is a single quadratic Bézier")
    func threePointQuad() {
        // With exactly 3 control points the open curve is the quadratic Bézier
        // (cp0, cp1, cp2); its midpoint matches the Bernstein form.
        let cps = [Vector(0, 0), Vector(4, 8), Vector(8, 0)]
        let d = SplinePointsData(controlPoints: cps, closed: false)
        let pts = QuadSpline.tessellate(d, tolerance: 0.001)!.points
        #expect(pts.first!.distance(to: cps[0]) < 1e-9)
        #expect(pts.last!.distance(to: cps[2]) < 1e-9)
        // The apex must reach roughly the Bézier midpoint y = (0 + 2·8 + 0)/4 = 4.
        let maxY = pts.map(\.y).max()!
        #expect(abs(maxY - 4) < 0.1)
    }

    @Test("splinePoints bbox is the control-point hull box")
    func splinePointsBBox() {
        let cps = [Vector(-3, 2), Vector(5, 9), Vector(7, -1)]
        let box = EntityRecord(id: EntityID(1), kind: .splinePoints(SplinePointsData(controlPoints: cps))).boundingBox()
        #expect(box.min == Vector(-3, -1))
        #expect(box.max == Vector(7, 9))
    }
}
