//
//  ConstructiveSnapTests.swift
//  CADEngineTests
//
//  Tests for the constructive object-snap modes added on top of workstream H's
//  snapping engine: nearest (true closest-point-on-curve), perpendicular (foot
//  from a reference point), tangent (from an external reference point), and
//  parallel. Covers the `SnapGeometry` kernels in isolation AND their wiring
//  through `Snapping.snap` (off by default; live only when enabled + given a
//  reference point). Suites are domain-prefixed (CONVENTIONS.md) so this
//  fan-out test file can't collide with the existing snapping suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - SnapGeometry kernel unit tests

@Suite("Constructive snap geometry kernels")
struct ConstructiveSnapGeometryTests {

    // -- Perpendicular foot on a line --

    @Test("perpendicular foot from a point to a horizontal line is the true foot")
    func perpFootLine() {
        // Line along the x-axis; the foot of the perpendicular from (3,5) is (3,0).
        let foot = SnapGeometry.perpendicularFootOnLine(from: Vector(3, 5),
                                                        a: Vector(0, 0), b: Vector(10, 0))
        #expect(foot.valid)
        #expect(foot.distance(to: Vector(3, 0)) < 1e-12)
        // The vector from `from` to `foot` is orthogonal to the line direction.
        let line = Vector(10, 0) - Vector(0, 0)
        let drop = foot - Vector(3, 5)
        #expect(abs(drop.dot(line)) < 1e-12)
    }

    @Test("perpendicular foot on a tilted line is orthogonal to the line")
    func perpFootTilted() {
        let a = Vector(0, 0), b = Vector(4, 4)   // 45° line
        let from = Vector(0, 4)
        let foot = SnapGeometry.perpendicularFootOnLine(from: from, a: a, b: b)
        // Foot is the midpoint (2,2) for this symmetric case.
        #expect(foot.distance(to: Vector(2, 2)) < 1e-12)
        #expect(abs((foot - from).dot(b - a)) < 1e-12)
    }

    @Test("perpendicular foot on a degenerate segment is invalid")
    func perpFootDegenerate() {
        let foot = SnapGeometry.perpendicularFootOnLine(from: Vector(1, 1),
                                                        a: Vector(2, 2), b: Vector(2, 2))
        #expect(!foot.valid)
    }

    @Test("segment-clamped foot clamps when projection is past the endpoint")
    func perpFootSegmentClamp() {
        // Projection of (20,5) onto x-axis is x=20, past the segment end (x=10).
        let foot = SnapGeometry.perpendicularFootOnSegment(from: Vector(20, 5),
                                                           a: Vector(0, 0), b: Vector(10, 0))
        #expect(foot.distance(to: Vector(10, 0)) < 1e-12)
    }

    // -- Perpendicular feet on a circle --

    @Test("perpendicular feet on a circle are the two radial points")
    func perpFeetCircle() {
        // Circle at origin r=3; from (10,0) the radial feet are (3,0) and (-3,0).
        let feet = SnapGeometry.perpendicularFeetOnCircle(from: Vector(10, 0),
                                                          center: Vector(0, 0), radius: 3)
        #expect(feet.count == 2)
        #expect(feet[0].distance(to: Vector(3, 0)) < 1e-12)   // near
        #expect(feet[1].distance(to: Vector(-3, 0)) < 1e-12)  // far
    }

    @Test("perpendicular feet on a circle are undefined from the center")
    func perpFeetCircleCenter() {
        let feet = SnapGeometry.perpendicularFeetOnCircle(from: Vector(0, 0),
                                                          center: Vector(0, 0), radius: 3)
        #expect(feet.isEmpty)
    }

    @Test("perpendicular feet on an arc keep only points within the sweep")
    func perpFeetArc() {
        // Right-half-circle arc (−90°..+90°) of r=3 at origin. From (10,0) the two
        // radial feet are (3,0) [in sweep] and (-3,0) [out of sweep].
        let feet = SnapGeometry.perpendicularFeetOnArc(from: Vector(10, 0),
                                                       center: Vector(0, 0), radius: 3,
                                                       startAngle: -Double.pi / 2,
                                                       endAngle: Double.pi / 2,
                                                       reversed: false)
        #expect(feet.count == 1)
        #expect(feet[0].distance(to: Vector(3, 0)) < 1e-12)
    }

    // -- Tangent points on a circle --

    @Test("tangent from an external point hits a real tangent point (radius perp tangent)")
    func tangentCircleExternal() {
        // Unit circle at origin; from (2,0). Tangent length = √3, tangent points
        // at (0.5, ±√3/2). Verify the tangency condition for each.
        let r = 1.0
        let center = Vector(0, 0)
        let from = Vector(2, 0)
        let pts = SnapGeometry.tangentPointsOnCircle(from: from, center: center, radius: r)
        #expect(pts.count == 2)
        for t in pts {
            // On the circle.
            #expect(abs((t - center).magnitude - r) < 1e-9)
            // Radius (center→T) is orthogonal to the tangent line (from→T).
            let radial = t - center
            let tangentLine = from - t
            #expect(abs(radial.dot(tangentLine)) < 1e-9)
        }
        // The expected closed-form tangent points.
        let expectedY = (3.0).squareRoot() / 2.0
        let hasUpper = pts.contains { $0.distance(to: Vector(0.5, expectedY)) < 1e-9 }
        let hasLower = pts.contains { $0.distance(to: Vector(0.5, -expectedY)) < 1e-9 }
        #expect(hasUpper && hasLower)
    }

    @Test("tangent from a point inside the circle has no real tangent")
    func tangentCircleInside() {
        let pts = SnapGeometry.tangentPointsOnCircle(from: Vector(0.2, 0),
                                                     center: Vector(0, 0), radius: 1)
        #expect(pts.isEmpty)
    }

    @Test("tangent from a point on the circle is the point itself")
    func tangentCircleOn() {
        let pts = SnapGeometry.tangentPointsOnCircle(from: Vector(1, 0),
                                                     center: Vector(0, 0), radius: 1)
        #expect(pts.count == 1)
        #expect(pts[0].distance(to: Vector(1, 0)) < 1e-9)
    }

    @Test("tangent on an ellipse satisfies the tangency condition")
    func tangentEllipse() {
        // Axis-aligned ellipse a=4, b=2 at origin; external point (10,0).
        let center = Vector(0, 0)
        let a = 4.0, b = 2.0
        let from = Vector(10, 0)
        let pts = SnapGeometry.tangentPointsOnEllipse(from: from, center: center,
                                                      majorRadius: a, minorRadius: b,
                                                      rotation: 0)
        #expect(pts.count == 2)
        for t in pts {
            // On the ellipse: (x/a)² + (y/b)² == 1.
            let onEllipse = (t.x / a) * (t.x / a) + (t.y / b) * (t.y / b)
            #expect(abs(onEllipse - 1.0) < 1e-9)
            // The ellipse gradient at T is (x/a², y/b²); the tangent direction is
            // perpendicular to it, so (from − T) must be along the tangent ⇒
            // (from − T) · gradient ≈ 0.
            let grad = Vector(t.x / (a * a), t.y / (b * b))
            #expect(abs((from - t).dot(grad)) < 1e-9)
        }
    }

    // -- Parallel --

    @Test("parallel projection keeps the reference→cursor segment parallel to refDir")
    func parallelProjection() {
        // Reference at origin, refDir along x; cursor (5,3) projects to (5,0).
        let p = SnapGeometry.parallelProjection(from: Vector(0, 0),
                                                cursor: Vector(5, 3),
                                                refDir: Vector(2, 0))
        #expect(p.valid)
        #expect(p.distance(to: Vector(5, 0)) < 1e-12)
        // The from→p direction is parallel to refDir (cross product ≈ 0).
        let seg = p - Vector(0, 0)
        let cross = seg.x * 0.0 - seg.y * 2.0   // seg × refDir, z component
        #expect(abs(cross) < 1e-12)
    }

    @Test("parallel projection with a degenerate direction is invalid")
    func parallelDegenerate() {
        let p = SnapGeometry.parallelProjection(from: Vector(0, 0),
                                                cursor: Vector(5, 3),
                                                refDir: Vector(0, 0))
        #expect(!p.valid)
    }
}

// MARK: - Pipeline integration (Snapping.snap)

@MainActor
private struct ConstructiveSnapFixture {
    let drawing = CADDrawing()
    let quadtree = Quadtree()

    /// Horizontal line from (0,0) to (10,0).
    let hLine: EntityID
    /// Circle centered (0,0) radius 3.
    let circle: EntityID

    init() {
        func add(_ kind: EntityKind, _ d: CADDrawing, _ q: Quadtree) -> EntityID {
            let id = d.add(EntityRecord(id: EntityID(0), kind: kind))
            q.insert(id, bounds: d.entity(id)!.boundingBox())
            return id
        }
        hLine = add(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))), drawing, quadtree)
        circle = add(.circle(CircleData(center: Vector(0, 0), radius: 3)), drawing, quadtree)
    }
}

@Suite("Constructive snap pipeline")
struct ConstructiveSnapPipelineTests {

    // -- Off by default --

    @MainActor
    @Test("constructive modes are NOT in the standard set")
    func notInStandard() {
        #expect(!SnapMode.standard.contains(.nearest))
        #expect(!SnapMode.standard.contains(.perpendicular))
        #expect(!SnapMode.standard.contains(.tangent))
        #expect(!SnapMode.standard.contains(.parallel))
    }

    @MainActor
    @Test("perpendicular is inert without a reference point")
    func perpInertWithoutReference() {
        let f = ConstructiveSnapFixture()
        // Cursor near where the perpendicular foot of (5,5)→hLine would be (5,0),
        // but no referencePoint supplied → perpendicular contributes nothing.
        let r = Snapping.snap(worldPoint: Vector(5, 0.1),
                              modes: [.perpendicular, .free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .free)
    }

    @MainActor
    @Test("perpendicular snaps to the foot from the reference point onto a line")
    func perpSnapLine() {
        let f = ConstructiveSnapFixture()
        // Reference (5,5); foot on the x-axis line is (5,0). Cursor near it.
        let r = Snapping.snap(worldPoint: Vector(5.05, 0.05),
                              modes: [.perpendicular, .free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree,
                              referencePoint: Vector(5, 5))
        #expect(r.kind == .perpendicular)
        #expect(r.point.distance(to: Vector(5, 0)) < 1e-9)
        #expect(r.entity == f.hLine)
    }

    @MainActor
    @Test("tangent snaps to a tangent point on a circle from the reference point")
    func tangentSnapCircle() {
        let f = ConstructiveSnapFixture()   // circle r=3 at origin
        // Reference (6,0); tangent points are at (1.5, ±(3√3)/2) ≈ (1.5, ±2.598).
        let ty = 3.0 * (3.0).squareRoot() / 2.0
        let r = Snapping.snap(worldPoint: Vector(1.55, ty - 0.05),
                              modes: [.tangent, .free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree,
                              referencePoint: Vector(6, 0))
        #expect(r.kind == .tangent)
        #expect(r.point.distance(to: Vector(1.5, ty)) < 1e-6)
        // Verify it is a real tangent point: radius ⟂ tangent line.
        let radial = r.point - Vector(0, 0)
        let tangentLine = Vector(6, 0) - r.point
        #expect(abs(radial.dot(tangentLine)) < 1e-6)
    }

    @MainActor
    @Test("nearest snaps to the closest point on the line and is off in standard")
    func nearestSnapLine() {
        let f = ConstructiveSnapFixture()
        // Above (4,0); only nearest enabled → nearest point on line is (4,0).
        let r = Snapping.snap(worldPoint: Vector(4, 0.1),
                              modes: [.nearest, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .nearest)
        #expect(r.point.distance(to: Vector(4, 0)) < 1e-9)
        #expect(r.entity == f.hLine)

        // With the standard set (nearest off), the same cursor does NOT report nearest.
        let r2 = Snapping.snap(worldPoint: Vector(4, 0.1),
                               modes: .standard,
                               worldTolerance: 0.3, gridSpacing: nil,
                               in: f.drawing, using: f.quadtree)
        #expect(r2.kind != .nearest)
    }

    @MainActor
    @Test("nearest on a circle is the radial projection")
    func nearestSnapCircle() {
        let f = ConstructiveSnapFixture()   // circle r=3 at origin; hLine along x
        // Just outside the circle at the TOP (+y), away from the x-axis line so the
        // circle is unambiguously the nearest entity: nearest outline point is (0,3).
        let r = Snapping.snap(worldPoint: Vector(0, 3.1),
                              modes: [.nearest, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .nearest)
        #expect(r.point.distance(to: Vector(0, 3)) < 1e-9)
        #expect(r.entity == f.circle)
    }

    @MainActor
    @Test("parallel snaps the reference→cursor segment parallel to a hovered line")
    func parallelSnapLine() {
        let f = ConstructiveSnapFixture()   // hLine along x-axis (y=0)
        // The hovered reference entity (hLine) must be near the cursor for the
        // quadtree to surface it. Reference (0,0.2); cursor (5,0.25) is 0.25 from
        // hLine (< tol). Projecting (5,0.25) onto the line through (0,0.2) parallel
        // to hLine's x-direction gives (5,0.2).
        let r = Snapping.snap(worldPoint: Vector(5, 0.25),
                              modes: [.parallel, .free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree,
                              referencePoint: Vector(0, 0.2))
        #expect(r.kind == .parallel)
        #expect(r.point.distance(to: Vector(5, 0.2)) < 1e-9)
    }
}
