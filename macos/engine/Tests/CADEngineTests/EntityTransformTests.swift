//
//  EntityTransformTests.swift
//  CADEngineTests
//
//  Tests for the shared `Affine2D` transform + per-`EntityKind` application that
//  every MODIFY tool (move/copy/rotate/scale/mirror) composes against. Domain-
//  prefixed suite names (`Affine2D*`, `EntityTransform*`) so parallel fan-out
//  test files don't clash at the test-target namespace (CONVENTIONS.md).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

private let tol = 1e-9

private func approxEqual(_ a: Vector, _ b: Vector, _ t: Double = tol) -> Bool {
    abs(a.x - b.x) < t && abs(a.y - b.y) < t && abs(a.z - b.z) < t
}

/// Angle equality on the circle (mod 2π), so 0 ≈ 2π.
private func angleEqual(_ a: Double, _ b: Double, _ t: Double = 1e-7) -> Bool {
    let d = Vector.correctAngle(a - b)
    return d < t || (2 * Double.pi - d) < t
}

// MARK: - Affine2D math

@Suite("Affine2D transform math")
struct Affine2DTransformTests {

    @Test("identity leaves points fixed")
    func identity() {
        let p = Vector(3, -7)
        #expect(approxEqual(Affine2D.identity.apply(p), p))
        #expect(Affine2D.identity == Affine2D.identity)
    }

    @Test("translation moves a point by the offset")
    func translation() {
        let t = Affine2D.translation(Vector(5, -2))
        #expect(approxEqual(t.apply(Vector(1, 1)), Vector(6, -1)))
        // z is carried through unchanged.
        #expect(abs(t.apply(Vector(0, 0, 4)).z - 4) < tol)
    }

    @Test("rotation 90deg about origin")
    func rotationAboutOrigin() {
        let t = Affine2D.rotation(angle: Double.pi / 2)
        #expect(approxEqual(t.apply(Vector(1, 0)), Vector(0, 1)))
        #expect(approxEqual(t.apply(Vector(0, 1)), Vector(-1, 0)))
    }

    @Test("rotation 90deg about an arbitrary pivot")
    func rotationAboutPivot() {
        let pivot = Vector(2, 2)
        let t = Affine2D.rotation(angle: Double.pi / 2, about: pivot)
        // The pivot is fixed.
        #expect(approxEqual(t.apply(pivot), pivot))
        // A point 1 to the right of the pivot rotates to 1 above it.
        #expect(approxEqual(t.apply(Vector(3, 2)), Vector(2, 3)))
    }

    @Test("uniform scale about a pivot")
    func scaleAboutPivot() {
        let pivot = Vector(1, 1)
        let t = Affine2D.scale(factor: 2, about: pivot)
        #expect(approxEqual(t.apply(pivot), pivot))            // pivot fixed
        #expect(approxEqual(t.apply(Vector(2, 1)), Vector(3, 1))) // dist doubles
        #expect(abs(t.uniformScale - 2) < tol)
    }

    @Test("non-uniform scale about a pivot")
    func nonUniformScale() {
        let t = Affine2D.scale(sx: 3, sy: 2, about: Vector(0, 0))
        #expect(approxEqual(t.apply(Vector(1, 1)), Vector(3, 2)))
        // uniformScale is the geometric mean sqrt(3*2).
        #expect(abs(t.uniformScale - (6.0).squareRoot()) < tol)
    }

    @Test("mirror across the x-axis (line through origin, angle 0)")
    func mirrorXAxis() {
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0)
        #expect(approxEqual(t.apply(Vector(2, 3)), Vector(2, -3)))
        #expect(t.isMirror)
        #expect(t.determinant < 0)
    }

    @Test("mirror across the y-axis (vertical line, angle pi/2)")
    func mirrorYAxis() {
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: Double.pi / 2)
        #expect(approxEqual(t.apply(Vector(2, 3)), Vector(-2, 3)))
    }

    @Test("mirror across an offset horizontal line through (0, 5)")
    func mirrorOffsetLine() {
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 5), angle: 0)
        // y reflects about 5: a point at y=8 lands at y=2.
        #expect(approxEqual(t.apply(Vector(3, 8)), Vector(3, 2)))
        // Points on the axis are fixed.
        #expect(approxEqual(t.apply(Vector(3, 5)), Vector(3, 5)))
    }

    @Test("mirror via two axis points equals the angle form")
    func mirrorTwoPoints() {
        let p1 = Vector(0, 0), p2 = Vector(1, 1)            // 45-degree line
        let t = Affine2D.mirror(axisPoint1: p1, axisPoint2: p2)
        // Reflection across y = x swaps x and y.
        #expect(approxEqual(t.apply(Vector(2, 5)), Vector(5, 2)))
        // Degenerate axis (coincident points) -> identity.
        #expect(Affine2D.mirror(axisPoint1: p1, axisPoint2: p1) == .identity)
    }

    @Test("composition applies rhs first, then lhs")
    func composition() {
        let move = Affine2D.translation(Vector(10, 0))
        let rot = Affine2D.rotation(angle: Double.pi / 2)
        // (move * rot): rotate first, then move.
        let composed = move * rot
        #expect(approxEqual(composed.apply(Vector(1, 0)), Vector(10, 1)))
        // concatenating is the same as *.
        #expect(approxEqual(move.concatenating(rot).apply(Vector(1, 0)), Vector(10, 1)))
        // Associativity / equivalence with sequential apply.
        let seq = move.apply(rot.apply(Vector(1, 0)))
        #expect(approxEqual(composed.apply(Vector(1, 0)), seq))
    }

    @Test("rotationDelta and uniformScale read off a similarity matrix")
    func derivedAccessors() {
        let t = Affine2D.scale(factor: 2, about: .invalidSafeOrigin)
            * Affine2D.rotation(angle: Double.pi / 4)
        #expect(angleEqual(t.rotationDelta, Double.pi / 4))
        #expect(abs(t.uniformScale - 2) < tol)
        #expect(!t.isMirror)
    }
}

// MARK: - per-kind transforms

@Suite("EntityKind transform application")
struct EntityTransformKindTests {

    @Test("point: position transforms")
    func point() {
        let k = EntityKind.point(PointData(position: Vector(1, 2)))
        guard case let .point(p) = k.transformed(by: .translation(Vector(3, 4))) else {
            Issue.record("expected point"); return
        }
        #expect(approxEqual(p.position, Vector(4, 6)))
    }

    @Test("line: both endpoints translate")
    func lineTranslate() {
        let k = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(2, 0)))
        guard case let .line(l) = k.transformed(by: .translation(Vector(1, 5))) else {
            Issue.record("expected line"); return
        }
        #expect(approxEqual(l.start, Vector(1, 5)))
        #expect(approxEqual(l.end, Vector(3, 5)))
    }

    @Test("line: rotate 90deg about origin")
    func lineRotate() {
        let k = EntityKind.line(LineData(start: Vector(1, 0), end: Vector(2, 0)))
        guard case let .line(l) = k.transformed(by: .rotation(angle: Double.pi / 2)) else {
            Issue.record("expected line"); return
        }
        #expect(approxEqual(l.start, Vector(0, 1)))
        #expect(approxEqual(l.end, Vector(0, 2)))
    }

    @Test("circle: rotate 90deg about a point — center moves, radius same")
    func circleRotate() {
        let k = EntityKind.circle(CircleData(center: Vector(3, 0), radius: 2))
        let t = Affine2D.rotation(angle: Double.pi / 2, about: Vector(0, 0))
        guard case let .circle(c) = k.transformed(by: t) else {
            Issue.record("expected circle"); return
        }
        #expect(approxEqual(c.center, Vector(0, 3)))
        #expect(abs(c.radius - 2) < tol)
    }

    @Test("circle: uniform scale doubles the radius and scales the center")
    func circleScale() {
        let k = EntityKind.circle(CircleData(center: Vector(2, 0), radius: 3))
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        guard case let .circle(c) = k.transformed(by: t) else {
            Issue.record("expected circle"); return
        }
        #expect(approxEqual(c.center, Vector(4, 0)))
        #expect(abs(c.radius - 6) < tol)
    }

    @Test("arc: pure scale scales radius, preserves angles")
    func arcScalePreservesAngles() {
        let arc = ArcData(center: Vector(0, 0), radius: 2,
                          startAngle: 0, endAngle: Double.pi / 2, reversed: false)
        let t = Affine2D.scale(factor: 3, about: Vector(0, 0))
        guard case let .arc(a) = EntityKind.arc(arc).transformed(by: t) else {
            Issue.record("expected arc"); return
        }
        #expect(abs(a.radius - 6) < tol)
        #expect(angleEqual(a.startAngle, 0))
        #expect(angleEqual(a.endAngle, Double.pi / 2))
        #expect(a.reversed == false)
    }

    @Test("arc: rotate shifts both angles by the rotation, radius unchanged")
    func arcRotateShiftsAngles() {
        let arc = ArcData(center: Vector(1, 0), radius: 2,
                          startAngle: 0, endAngle: Double.pi / 2, reversed: false)
        let t = Affine2D.rotation(angle: Double.pi / 2, about: Vector(0, 0))
        guard case let .arc(a) = EntityKind.arc(arc).transformed(by: t) else {
            Issue.record("expected arc"); return
        }
        #expect(approxEqual(a.center, Vector(0, 1)))
        #expect(abs(a.radius - 2) < tol)
        #expect(angleEqual(a.startAngle, Double.pi / 2))
        #expect(angleEqual(a.endAngle, Double.pi))
        #expect(a.reversed == false)
    }

    @Test("arc: mirror across x-axis flips reversed and reflects angles")
    func arcMirror() {
        // Arc centered at origin, sweep 0 -> 90deg, CCW.
        let arc = ArcData(center: Vector(0, 0), radius: 2,
                          startAngle: 0, endAngle: Double.pi / 2, reversed: false)
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0) // x-axis
        guard case let .arc(a) = EntityKind.arc(arc).transformed(by: t) else {
            Issue.record("expected arc"); return
        }
        // RS_Arc::mirror: a = 2*axisAngle = 0; angle_i = 0 - angle_i.
        #expect(approxEqual(a.center, Vector(0, 0)))
        #expect(abs(a.radius - 2) < tol)
        #expect(angleEqual(a.startAngle, 0))               // -0
        #expect(angleEqual(a.endAngle, -Double.pi / 2))    // wraps to 3pi/2
        #expect(a.reversed == true)
    }

    @Test("arc: mirror endpoints land on the reflected world endpoints")
    func arcMirrorEndpointsConsistent() {
        let arc = ArcData(center: Vector(2, 1), radius: 3,
                          startAngle: 0.3, endAngle: 1.7, reversed: false)
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: Double.pi / 6)
        guard case let .arc(a) = EntityKind.arc(arc).transformed(by: t) else {
            Issue.record("expected arc"); return
        }
        // The transformed start endpoint must equal the mirror of the original
        // start endpoint (geometric invariant, independent of the angle bookkeeping).
        let origStart = arc.center + Vector.polar(radius: arc.radius, angle: arc.startAngle)
        let newStart = a.center + Vector.polar(radius: a.radius, angle: a.startAngle)
        #expect(approxEqual(t.apply(origStart), newStart, 1e-7))
        let origEnd = arc.center + Vector.polar(radius: arc.radius, angle: arc.endAngle)
        let newEnd = a.center + Vector.polar(radius: a.radius, angle: a.endAngle)
        #expect(approxEqual(t.apply(origEnd), newEnd, 1e-7))
    }

    @Test("polyline: vertices reflect and bulge signs flip under mirror")
    func polylineMirrorFlipsBulge() {
        let pl = PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0), bulge: 0.5),
            PolylineVertex(point: Vector(2, 0), bulge: -0.25),
            PolylineVertex(point: Vector(2, 3), bulge: 0),
        ], closed: true)
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0) // x-axis
        guard case let .polyline(out) = EntityKind.polyline(pl).transformed(by: t) else {
            Issue.record("expected polyline"); return
        }
        #expect(out.closed == true)
        #expect(approxEqual(out.vertices[0].point, Vector(0, 0)))
        #expect(approxEqual(out.vertices[1].point, Vector(2, 0)))
        #expect(approxEqual(out.vertices[2].point, Vector(2, -3)))
        // Bulge signs flip (reflection reverses arc orientation), magnitude same.
        #expect(abs(out.vertices[0].bulge - (-0.5)) < tol)
        #expect(abs(out.vertices[1].bulge - 0.25) < tol)
        #expect(abs(out.vertices[2].bulge - 0) < tol)
    }

    @Test("polyline: rotation preserves bulge sign and magnitude")
    func polylineRotateKeepsBulge() {
        let pl = PolylineData(vertices: [
            PolylineVertex(point: Vector(1, 0), bulge: 0.5),
            PolylineVertex(point: Vector(3, 0), bulge: -0.25),
        ], closed: false)
        let t = Affine2D.rotation(angle: Double.pi / 2, about: Vector(0, 0))
        guard case let .polyline(out) = EntityKind.polyline(pl).transformed(by: t) else {
            Issue.record("expected polyline"); return
        }
        #expect(approxEqual(out.vertices[0].point, Vector(0, 1)))
        #expect(approxEqual(out.vertices[1].point, Vector(0, 3)))
        #expect(abs(out.vertices[0].bulge - 0.5) < tol)    // unchanged
        #expect(abs(out.vertices[1].bulge - (-0.25)) < tol)
    }

    @Test("ellipse: rotate — majorP rotates, ratio unchanged, center moves")
    func ellipseRotate() {
        // Whole ellipse, major axis along +x, length 4, ratio 0.5.
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(4, 0), ratio: 0.5)
        let t = Affine2D.rotation(angle: Double.pi / 2, about: Vector(0, 0))
        guard case let .ellipse(out) = EntityKind.ellipse(e).transformed(by: t) else {
            Issue.record("expected ellipse"); return
        }
        #expect(approxEqual(out.center, Vector(0, 0)))
        #expect(approxEqual(out.majorP, Vector(0, 4)))     // major axis now +y
        #expect(abs(out.ratio - 0.5) < tol)
        // rotationAngle of majorP is now pi/2.
        #expect(angleEqual(out.rotationAngle, Double.pi / 2))
    }

    @Test("ellipse: uniform scale scales majorP magnitude, ratio unchanged")
    func ellipseScale() {
        let e = EllipseData(center: Vector(1, 0), majorP: Vector(4, 0), ratio: 0.5)
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        guard case let .ellipse(out) = EntityKind.ellipse(e).transformed(by: t) else {
            Issue.record("expected ellipse"); return
        }
        #expect(approxEqual(out.center, Vector(2, 0)))
        #expect(abs(out.majorRadius - 8) < tol)
        #expect(abs(out.ratio - 0.5) < tol)
    }

    @Test("ellipse arc: mirror flips reversed and recomputes endpoints")
    func ellipseArcMirror() {
        // Elliptic arc, major along +x, sweeping 0 -> 90deg parametric.
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(4, 0), ratio: 0.5,
                            startAngle: 0, endAngle: Double.pi / 2, reversed: false)
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0) // x-axis
        guard case let .ellipse(out) = EntityKind.ellipse(e).transformed(by: t) else {
            Issue.record("expected ellipse"); return
        }
        #expect(out.reversed == true)
        // The transformed start/end world points must equal the reflected originals.
        let origStart = e.ellipsePoint(e.startAngle)
        let origEnd = e.ellipsePoint(e.endAngle)
        #expect(approxEqual(out.ellipsePoint(out.startAngle), t.apply(origStart), 1e-7))
        #expect(approxEqual(out.ellipsePoint(out.endAngle), t.apply(origEnd), 1e-7))
    }

    @Test("spline: control points transform; knots/weights/degree unchanged")
    func spline() {
        let s = SplineData(degree: 3,
                           controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0)],
                           knots: [0, 0, 0, 0, 1, 1, 1, 1],
                           weights: [1, 2, 1],
                           closed: false)
        let t = Affine2D.translation(Vector(5, 5)) * Affine2D.rotation(angle: Double.pi / 2)
        guard case let .spline(out) = EntityKind.spline(s).transformed(by: t) else {
            Issue.record("expected spline"); return
        }
        #expect(out.degree == 3)
        #expect(out.knots == [0, 0, 0, 0, 1, 1, 1, 1])     // affine-invariant
        #expect(out.weights == [1, 2, 1])                   // affine-invariant
        #expect(out.closed == false)
        #expect(approxEqual(out.controlPoints[0], t.apply(Vector(0, 0))))
        #expect(approxEqual(out.controlPoints[1], t.apply(Vector(1, 1))))
        #expect(approxEqual(out.controlPoints[2], t.apply(Vector(2, 0))))
    }

    @Test("splinePoints: control points transform; closed flag unchanged")
    func splinePoints() {
        let sp = SplinePointsData(controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0)],
                                  closed: true)
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        guard case let .splinePoints(out) = EntityKind.splinePoints(sp).transformed(by: t) else {
            Issue.record("expected splinePoints"); return
        }
        #expect(out.closed == true)
        #expect(approxEqual(out.controlPoints[0], Vector(0, 0)))
        #expect(approxEqual(out.controlPoints[1], Vector(2, 2)))
        #expect(approxEqual(out.controlPoints[2], Vector(4, 0)))
    }

    @Test("round-trip: mirror twice across the same axis is identity")
    func mirrorTwiceIsIdentity() {
        let pl = PolylineData(vertices: [
            PolylineVertex(point: Vector(1, 2), bulge: 0.4),
            PolylineVertex(point: Vector(3, 5), bulge: -0.6),
        ], closed: false)
        let m = Affine2D.mirror(acrossLineThrough: Vector(1, 1), angle: Double.pi / 5)
        guard case let .polyline(once) = EntityKind.polyline(pl).transformed(by: m),
              case let .polyline(twice) = EntityKind.polyline(once).transformed(by: m) else {
            Issue.record("expected polyline"); return
        }
        for (orig, back) in zip(pl.vertices, twice.vertices) {
            #expect(approxEqual(orig.point, back.point, 1e-7))
            #expect(abs(orig.bulge - back.bulge) < 1e-9)   // sign flipped twice
        }
    }
}

// Small test helper so the composition test reads naturally.
private extension Vector {
    static var invalidSafeOrigin: Vector { Vector(0, 0) }
}
