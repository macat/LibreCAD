//
//  SelectionSnapTests.swift
//  CADEngineTests
//
//  Tests for the selection + snapping engine (workstream H): exact CPU
//  hit-testing, window/crossing rectangle selection, and the snap modes
//  (endpoint / center / middle / intersection / on-entity / grid / free) with
//  priority resolution. Suites are domain-prefixed (CONVENTIONS.md) so parallel
//  fan-out test files can't collide at the test-target namespace.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Shared fixture

/// Builds a small drawing + a quadtree populated from entity bboxes, on the main
/// actor (CADDrawing is `@MainActor`). Returns the drawing, the index, and the
/// ids of the entities it added so tests can assert by id.
@MainActor
private struct SelectionSnapFixture {
    let drawing = CADDrawing()
    let quadtree = Quadtree()

    /// Horizontal line from (0,0) to (10,0).
    let hLine: EntityID
    /// Vertical line from (5,-5) to (5,5) — crosses hLine at (5,0).
    let vLine: EntityID
    /// Circle centered (20,0) radius 3.
    let circle: EntityID

    init() {
        // A free helper (drawing/quadtree passed explicitly) so the `let` fields
        // can each be initialized exactly once without a self-capturing closure.
        func add(_ kind: EntityKind, _ d: CADDrawing, _ q: Quadtree) -> EntityID {
            let id = d.add(EntityRecord(id: EntityID(0), kind: kind))
            q.insert(id, bounds: d.entity(id)!.boundingBox())
            return id
        }
        hLine = add(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))), drawing, quadtree)
        vLine = add(.line(LineData(start: Vector(5, -5), end: Vector(5, 5))), drawing, quadtree)
        circle = add(.circle(CircleData(center: Vector(20, 0), radius: 3)), drawing, quadtree)
    }
}

// MARK: - Geometry2D unit tests

@Suite("Selection geometry helpers")
struct SelectionGeometryTests {

    @Test("point-to-segment distance clamps to endpoints")
    func pointToSegment() {
        let a = Vector(0, 0), b = Vector(10, 0)
        // Perpendicular foot inside the segment.
        #expect(abs(Geometry2D.distanceToSegment(Vector(5, 2), a, b) - 2) < 1e-12)
        // Off the end → distance to the endpoint.
        #expect(abs(Geometry2D.distanceToSegment(Vector(13, 0), a, b) - 3) < 1e-12)
        // On the segment → ~0.
        #expect(Geometry2D.distanceToSegment(Vector(4, 0), a, b) < 1e-12)
    }

    @Test("point-to-circle is the radial distance to the outline")
    func pointToCircle() {
        let c = Vector(0, 0)
        #expect(abs(Geometry2D.distanceToCircle(Vector(5, 0), center: c, radius: 3) - 2) < 1e-12)
        // Inside the disc still measures to the outline.
        #expect(abs(Geometry2D.distanceToCircle(Vector(1, 0), center: c, radius: 3) - 2) < 1e-12)
    }

    @Test("point-to-arc respects the angular sweep")
    func pointToArc() {
        // Quarter arc on the unit circle from 0 to π/2 (CCW). A point near the
        // mid (45°) snaps radially; a point past the end falls to the endpoint.
        let c = Vector(0, 0)
        let onSweep = Geometry2D.distanceToArc(Vector(2, 2), center: c, radius: 1,
                                               startAngle: 0, endAngle: Double.pi / 2, reversed: false)
        // Radial distance from (2,2) (|·|=2.828) to r=1 ⇒ ~1.828.
        #expect(abs(onSweep - (Vector(2, 2).magnitude - 1)) < 1e-9)

        // A point below the x-axis (angle ~ -90°, outside [0,90°]) → nearest is the
        // start endpoint (1,0).
        let offSweep = Geometry2D.distanceToArc(Vector(2, -2), center: c, radius: 1,
                                                startAngle: 0, endAngle: Double.pi / 2, reversed: false)
        #expect(abs(offSweep - Vector(2, -2).distance(to: Vector(1, 0))) < 1e-9)
    }

    @Test("polygon containment via ray casting")
    func polygonContains() {
        let square = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        #expect(Geometry2D.polygonContains(Vector(5, 5), loop: square))
        #expect(!Geometry2D.polygonContains(Vector(15, 5), loop: square))
    }

    @Test("segment intersection detects crossing and rejects disjoint")
    func segmentIntersect() {
        #expect(Geometry2D.segmentsIntersect(Vector(0, 0), Vector(10, 0),
                                              Vector(5, -5), Vector(5, 5)))
        #expect(!Geometry2D.segmentsIntersect(Vector(0, 0), Vector(1, 0),
                                              Vector(5, -5), Vector(5, 5)))
    }
}

// MARK: - hitTest

@Suite("Selection hit testing")
struct SelectionHitTestTests {

    @MainActor
    @Test("a point on a line returns that line")
    func hitOnLine() {
        let f = SelectionSnapFixture()
        let sel = Selection()
        // Just above the horizontal line, within tolerance.
        let hit = sel.hitTest(worldPoint: Vector(3, 0.05), worldTolerance: 0.2,
                              in: f.drawing, using: f.quadtree)
        #expect(hit == f.hLine)
    }

    @MainActor
    @Test("a point in empty space returns nil")
    func hitEmpty() {
        let f = SelectionSnapFixture()
        let sel = Selection()
        let hit = sel.hitTest(worldPoint: Vector(50, 50), worldTolerance: 0.2,
                              in: f.drawing, using: f.quadtree)
        #expect(hit == nil)
    }

    @MainActor
    @Test("nearest wins when two entities are close")
    func hitNearestWins() {
        let f = SelectionSnapFixture()
        let sel = Selection()
        // Near the (5,0) crossing but slightly closer to the vertical line:
        // x=5.02 is 0.02 from vLine (x=5), and y=0.1 is 0.1 from hLine (y=0).
        let hit = sel.hitTest(worldPoint: Vector(5.02, 0.1), worldTolerance: 0.3,
                              in: f.drawing, using: f.quadtree)
        #expect(hit == f.vLine)

        // And the reverse: closer to the horizontal line.
        let hit2 = sel.hitTest(worldPoint: Vector(5.1, 0.02), worldTolerance: 0.3,
                               in: f.drawing, using: f.quadtree)
        #expect(hit2 == f.hLine)
    }

    @MainActor
    @Test("a point on the circle outline returns the circle")
    func hitOnCircle() {
        let f = SelectionSnapFixture()
        let sel = Selection()
        // On the circle outline at (23,0) (center (20,0), r=3).
        let hit = sel.hitTest(worldPoint: Vector(23.05, 0), worldTolerance: 0.2,
                              in: f.drawing, using: f.quadtree)
        #expect(hit == f.circle)
        // The circle CENTER is empty space for hit-testing (outline only).
        let center = sel.hitTest(worldPoint: Vector(20, 0), worldTolerance: 0.2,
                                 in: f.drawing, using: f.quadtree)
        #expect(center == nil)
    }
}

// MARK: - windowSelect (window vs crossing)

@Suite("Selection window/crossing")
struct SelectionWindowTests {

    /// An entity straddling the rect edge: a line from (8,0) to (15,0) where the
    /// rect covers x∈[0,12]. Window (fully-inside) must EXCLUDE it; crossing
    /// (intersecting) must INCLUDE it.
    @MainActor
    @Test("window excludes a straddling entity; crossing includes it")
    func windowVsCrossingStraddle() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let straddle = drawing.add(EntityRecord(id: EntityID(0),
            kind: .line(LineData(start: Vector(8, 0), end: Vector(15, 0)))))
        quadtree.insert(straddle, bounds: drawing.entity(straddle)!.boundingBox())

        let rect = AABB(min: Vector(0, -5), max: Vector(12, 5))
        let sel = Selection()

        // Window: entity is NOT fully inside (end at x=15 escapes) → excluded.
        let windowHits = sel.windowSelect(rect: rect, crossing: false,
                                          in: drawing, using: quadtree)
        #expect(!windowHits.contains(straddle))

        // Crossing: the entity crosses the right edge → included.
        let crossingHits = sel.windowSelect(rect: rect, crossing: true,
                                            in: drawing, using: quadtree)
        #expect(crossingHits.contains(straddle))
    }

    @MainActor
    @Test("a fully-contained entity is selected by both window and crossing")
    func fullyInsideBoth() {
        let f = SelectionSnapFixture()
        let sel = Selection()
        // Rect covering the whole horizontal line [0,10]×0.
        let rect = AABB(min: Vector(-1, -1), max: Vector(11, 1))
        let window = sel.windowSelect(rect: rect, crossing: false, in: f.drawing, using: f.quadtree)
        let crossing = sel.windowSelect(rect: rect, crossing: true, in: f.drawing, using: f.quadtree)
        #expect(window.contains(f.hLine))
        #expect(crossing.contains(f.hLine))
    }

    @MainActor
    @Test("crossing includes a circle whose outline crosses the rect; window excludes it")
    func crossingCircleEdge() {
        let f = SelectionSnapFixture()
        let sel = Selection()
        // Rect overlapping only the left part of the circle (center (20,0) r=3):
        // x∈[15,18.5] clips the left edge of the circle (leftmost point x=17).
        let rect = AABB(min: Vector(15, -5), max: Vector(18.5, 5))
        let crossing = sel.windowSelect(rect: rect, crossing: true, in: f.drawing, using: f.quadtree)
        #expect(crossing.contains(f.circle))
        let window = sel.windowSelect(rect: rect, crossing: false, in: f.drawing, using: f.quadtree)
        #expect(!window.contains(f.circle))
    }
}

// MARK: - Selection state

@Suite("Selection state mutations")
struct SelectionStateTests {

    @Test("add/remove/toggle/clear/contains")
    func mutations() {
        var sel = Selection()
        let a = EntityID(1), b = EntityID(2)
        #expect(sel.isEmpty)
        sel.add(a)
        #expect(sel.contains(a))
        #expect(sel.count == 1)
        sel.toggle(b)
        #expect(sel.contains(b))
        sel.toggle(a)               // toggles a OFF
        #expect(!sel.contains(a))
        sel.remove(b)
        #expect(sel.isEmpty)
        sel.add(contentsOf: [a, b])
        #expect(sel.count == 2)
        sel.clear()
        #expect(sel.isEmpty)
    }
}

// MARK: - Snapping

@Suite("Snapping engine")
struct SnappingTests {

    @MainActor
    @Test("endpoint snap to a known line end")
    func endpointSnap() {
        let f = SelectionSnapFixture()
        // Cursor near the (10,0) end of the horizontal line.
        let r = Snapping.snap(worldPoint: Vector(9.9, 0.05), modes: .standard,
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .endpoint)
        #expect(r.point.distance(to: Vector(10, 0)) < 1e-9)
        #expect(r.entity == f.hLine)
    }

    @MainActor
    @Test("center snap to the circle center")
    func centerSnap() {
        let f = SelectionSnapFixture()
        let r = Snapping.snap(worldPoint: Vector(20.1, 0.1), modes: [.center, .free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .center)
        #expect(r.point.distance(to: Vector(20, 0)) < 1e-9)
        #expect(r.entity == f.circle)
    }

    @MainActor
    @Test("middle snap to a line midpoint")
    func middleSnap() {
        let f = SelectionSnapFixture()
        // The horizontal line midpoint is (5,0); approach from just off it but
        // only enable middle (+free) so endpoint/intersection don't win.
        let r = Snapping.snap(worldPoint: Vector(5.05, 0.05), modes: [.middle, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .middle)
        #expect(r.point.distance(to: Vector(5, 0)) < 1e-9)
    }

    @MainActor
    @Test("grid snap rounds the cursor to the spacing")
    func gridSnap() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()   // empty — only grid can fire
        let r = Snapping.snap(worldPoint: Vector(2.4, 7.6), modes: [.grid, .free],
                              worldTolerance: 1.0, gridSpacing: 1.0,
                              in: drawing, using: quadtree)
        #expect(r.kind == .grid)
        #expect(r.point.distance(to: Vector(2, 8)) < 1e-9)
    }

    @MainActor
    @Test("intersection snap returns the crossing of two lines (via Intersections)")
    func intersectionSnap() {
        let f = SelectionSnapFixture()
        // The two lines cross at (5,0); approach near it with only intersection
        // (+free) so no endpoint/midpoint of either line competes... but (5,0) is
        // also the midpoint of both lines. Disable middle to isolate intersection.
        let r = Snapping.snap(worldPoint: Vector(5.08, 0.08), modes: [.intersection, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .intersection)
        #expect(r.point.distance(to: Vector(5, 0)) < 1e-9)
    }

    @MainActor
    @Test("on-entity snap returns the nearest point on the line")
    func onEntitySnap() {
        let f = SelectionSnapFixture()
        // Above (3,0) on the horizontal line; only onEntity enabled.
        let r = Snapping.snap(worldPoint: Vector(3, 0.1), modes: [.onEntity, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .onEntity)
        #expect(r.point.distance(to: Vector(3, 0)) < 1e-9)
        #expect(r.entity == f.hLine)
    }

    @MainActor
    @Test("priority: endpoint beats on-entity when both are within tolerance")
    func priorityEndpointOverOnEntity() {
        let f = SelectionSnapFixture()
        // Near the (0,0) endpoint of the horizontal line. on-entity nearest point
        // is (0.05,0) [dist 0.02], endpoint is (0,0) [dist ~0.054]. on-entity is
        // marginally CLOSER, but endpoint must still win by priority.
        let r = Snapping.snap(worldPoint: Vector(0.05, 0.02), modes: [.endpoint, .onEntity, .free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .endpoint)
        #expect(r.point.distance(to: Vector(0, 0)) < 1e-9)
    }

    @MainActor
    @Test("free fallback when nothing is within tolerance")
    func freeFallback() {
        let f = SelectionSnapFixture()
        let cursor = Vector(100, 100)
        let r = Snapping.snap(worldPoint: cursor, modes: .standard,
                              worldTolerance: 0.5, gridSpacing: 1.0,
                              in: f.drawing, using: f.quadtree)
        // No entity near (100,100); grid would snap to (100,100) which IS the
        // cursor, so the snapped point equals the cursor regardless of kind.
        #expect(r.point.distance(to: cursor) < 1e-9)
    }

    @MainActor
    @Test("free fallback with no modes returns the raw cursor as .free")
    func freeOnlyMode() {
        let f = SelectionSnapFixture()
        let cursor = Vector(3, 0.05)
        let r = Snapping.snap(worldPoint: cursor, modes: [.free],
                              worldTolerance: 0.5, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .free)
        #expect(r.point == cursor)
    }
}
