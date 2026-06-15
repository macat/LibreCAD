//
//  SnapModeTests.swift
//  CADEngineTests
//
//  Tests for the LibreCAD snap-parity additions (audit G4) layered on top of the
//  workstream-H snapping engine:
//    - distance-along-entity ("Snap distance" / equidistant): N·spacing points
//      along a line / arc (by arc length) / polyline from the reference end, both
//      as the pure `SnapGeometry` kernels and through `Snapping.snap`.
//    - manual middle: midpoint of two user-picked points.
//    - manual intersection: intersection of two user-picked entities (line/line,
//      line/arc) even when the auto intersection snap wouldn't surface it.
//  Plus regression checks that the existing snap behavior is unchanged (the new
//  modes are off in `.standard`, and the public `SnapKind` set is intact).
//
//  Suites are domain-prefixed (CONVENTIONS.md) so this file can't collide with
//  the existing snapping suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Distance-along geometry kernels (SnapGeometry)

@Suite("Distance-along snap geometry kernels")
struct DistanceAlongGeometryTests {

    // -- Line --

    @Test("equidistant points along a line are N·spacing from the start end")
    func alongLineFromStart() {
        // Line (0,0)→(10,0), spacing 2 → interior points at x = 2,4,6,8 (not 0/10).
        let pts = SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(10, 0),
                                               spacing: 2, fromStart: true)
        #expect(pts.count == 4)
        #expect(pts[0].distance(to: Vector(2, 0)) < 1e-12)
        #expect(pts[1].distance(to: Vector(4, 0)) < 1e-12)
        #expect(pts[2].distance(to: Vector(6, 0)) < 1e-12)
        #expect(pts[3].distance(to: Vector(8, 0)) < 1e-12)
    }

    @Test("equidistant points measured from the far end count back toward start")
    func alongLineFromEnd() {
        // From the end (x=10): points at x = 8,6,4,2.
        let pts = SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(10, 0),
                                               spacing: 2, fromStart: false)
        #expect(pts.count == 4)
        #expect(pts[0].distance(to: Vector(8, 0)) < 1e-12)
        #expect(pts[3].distance(to: Vector(2, 0)) < 1e-12)
    }

    @Test("spacing that exactly divides the length excludes both endpoints")
    func alongLineExactDivision() {
        // Length 10, spacing 5 → interior point only at x=5 (0 and 10 excluded).
        let pts = SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(10, 0),
                                               spacing: 5, fromStart: true)
        #expect(pts.count == 1)
        #expect(pts[0].distance(to: Vector(5, 0)) < 1e-12)
    }

    @Test("spacing larger than the line yields no interior points")
    func alongLineSpacingTooLarge() {
        let pts = SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(3, 0),
                                               spacing: 5, fromStart: true)
        #expect(pts.isEmpty)
    }

    @Test("non-positive spacing / degenerate line yield no points")
    func alongLineDegenerate() {
        #expect(SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(10, 0),
                                             spacing: 0).isEmpty)
        #expect(SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(10, 0),
                                             spacing: -2).isEmpty)
        #expect(SnapGeometry.pointsAlongLine(start: Vector(4, 4), end: Vector(4, 4),
                                             spacing: 1).isEmpty)
    }

    @Test("points along a tilted line are spaced by true distance, on the line")
    func alongLineTilted() {
        // 3-4-5 line of length 5 from (0,0) to (3,4); spacing 2.5 → one interior
        // point at the midpoint (1.5, 2).
        let pts = SnapGeometry.pointsAlongLine(start: Vector(0, 0), end: Vector(3, 4),
                                               spacing: 2.5, fromStart: true)
        #expect(pts.count == 1)
        #expect(pts[0].distance(to: Vector(1.5, 2)) < 1e-12)
    }

    // -- Arc (by arc length) --

    @Test("equidistant points along an arc are spaced by ARC LENGTH")
    func alongArcByArcLength() {
        // Quarter circle r=4 at origin, 0°..90° CCW. Total arc length = 2π ≈ 6.283.
        // spacing = π/2·... use spacing so the swept angle is clean: spacing = r·(π/6)
        // = 4·π/6 ≈ 2.094 → interior angles at 30° and 60° (90° excluded).
        let r = 4.0
        let spacing = r * Double.pi / 6.0
        let pts = SnapGeometry.pointsAlongArc(center: Vector(0, 0), radius: r,
                                              startAngle: 0, endAngle: Double.pi / 2, reversed: false,
                                              spacing: spacing, fromStart: true)
        #expect(pts.count == 2)
        let p30 = Vector(r * cos(Double.pi / 6), r * sin(Double.pi / 6))
        let p60 = Vector(r * cos(Double.pi / 3), r * sin(Double.pi / 3))
        #expect(pts[0].distance(to: p30) < 1e-9)
        #expect(pts[1].distance(to: p60) < 1e-9)
        // Each point is exactly on the circle.
        for p in pts { #expect(abs((p - Vector(0, 0)).magnitude - r) < 1e-9) }
    }

    @Test("arc distance-along from the far end walks back along the sweep")
    func alongArcFromEnd() {
        let r = 4.0
        let spacing = r * Double.pi / 6.0
        let pts = SnapGeometry.pointsAlongArc(center: Vector(0, 0), radius: r,
                                              startAngle: 0, endAngle: Double.pi / 2, reversed: false,
                                              spacing: spacing, fromStart: false)
        #expect(pts.count == 2)
        // From the 90° end: first interior at 60°, then 30°.
        let p60 = Vector(r * cos(Double.pi / 3), r * sin(Double.pi / 3))
        let p30 = Vector(r * cos(Double.pi / 6), r * sin(Double.pi / 6))
        #expect(pts[0].distance(to: p60) < 1e-9)
        #expect(pts[1].distance(to: p30) < 1e-9)
    }

    @Test("reversed (clockwise) arc spacing walks the clockwise sweep")
    func alongArcReversed() {
        // r=4 at origin, from 90° down to 0° clockwise (reversed). Same two interior
        // points (60°, 30°) but reached by going clockwise from 90°.
        let r = 4.0
        let spacing = r * Double.pi / 6.0
        let pts = SnapGeometry.pointsAlongArc(center: Vector(0, 0), radius: r,
                                              startAngle: Double.pi / 2, endAngle: 0, reversed: true,
                                              spacing: spacing, fromStart: true)
        #expect(pts.count == 2)
        let p60 = Vector(r * cos(Double.pi / 3), r * sin(Double.pi / 3))
        let p30 = Vector(r * cos(Double.pi / 6), r * sin(Double.pi / 6))
        #expect(pts[0].distance(to: p60) < 1e-9)
        #expect(pts[1].distance(to: p30) < 1e-9)
    }

    @Test("degenerate arc / non-positive spacing yield no points")
    func alongArcDegenerate() {
        #expect(SnapGeometry.pointsAlongArc(center: Vector(0, 0), radius: 0,
                                            startAngle: 0, endAngle: 1, reversed: false,
                                            spacing: 1).isEmpty)
        #expect(SnapGeometry.pointsAlongArc(center: Vector(0, 0), radius: 4,
                                            startAngle: 0, endAngle: 1, reversed: false,
                                            spacing: 0).isEmpty)
    }

    // -- Polyline --

    @Test("equidistant points along an L-shaped polyline cross the corner correctly")
    func alongPolyline() {
        // L: (0,0)→(4,0)→(4,4). Total length 8, spacing 2 → interior points at
        // path length 2,4,6 → world (2,0), (4,0), (4,2).
        let pts = SnapGeometry.pointsAlongPolyline(points: [Vector(0, 0), Vector(4, 0), Vector(4, 4)],
                                                   closed: false, spacing: 2, fromStart: true)
        #expect(pts.count == 3)
        #expect(pts[0].distance(to: Vector(2, 0)) < 1e-12)
        #expect(pts[1].distance(to: Vector(4, 0)) < 1e-12)   // exactly the corner
        #expect(pts[2].distance(to: Vector(4, 2)) < 1e-12)
    }

    @Test("closed polyline walks the closing edge too")
    func alongPolylineClosed() {
        // Unit-ish square (0,0)→(4,0)→(4,4)→(0,4)→close. Perimeter 16, spacing 4 →
        // interior at 4,8,12 → (4,0), (4,4), (0,4).
        let pts = SnapGeometry.pointsAlongPolyline(
            points: [Vector(0, 0), Vector(4, 0), Vector(4, 4), Vector(0, 4)],
            closed: true, spacing: 4, fromStart: true)
        #expect(pts.count == 3)
        #expect(pts[0].distance(to: Vector(4, 0)) < 1e-12)
        #expect(pts[1].distance(to: Vector(4, 4)) < 1e-12)
        #expect(pts[2].distance(to: Vector(0, 4)) < 1e-12)
    }

    @Test("polyline distance-along from the far end reverses the walk")
    func alongPolylineFromEnd() {
        // L: (0,0)→(4,0)→(4,4) reversed → start counting from (4,4): 2,4,6 →
        // (4,2), (4,0), (2,0).
        let pts = SnapGeometry.pointsAlongPolyline(points: [Vector(0, 0), Vector(4, 0), Vector(4, 4)],
                                                   closed: false, spacing: 2, fromStart: false)
        #expect(pts.count == 3)
        #expect(pts[0].distance(to: Vector(4, 2)) < 1e-12)
        #expect(pts[1].distance(to: Vector(4, 0)) < 1e-12)
        #expect(pts[2].distance(to: Vector(2, 0)) < 1e-12)
    }
}

// MARK: - Manual (two-pick) primitives

@Suite("Manual middle / intersection primitives")
struct ManualSnapPrimitiveTests {

    @Test("manual middle is the midpoint of the two picks")
    func manualMiddleMidpoint() {
        let m = SnapGeometry.manualMiddle(a: Vector(2, 4), b: Vector(8, 10))
        #expect(m.valid)
        #expect(m.distance(to: Vector(5, 7)) < 1e-12)
    }

    @Test("manual middle of identical picks is that point")
    func manualMiddleSamePoint() {
        let m = SnapGeometry.manualMiddle(a: Vector(3, 3), b: Vector(3, 3))
        #expect(m.distance(to: Vector(3, 3)) < 1e-12)
    }

    @Test("manual middle with an invalid pick is invalid")
    func manualMiddleInvalid() {
        #expect(!SnapGeometry.manualMiddle(a: .invalid, b: Vector(1, 1)).valid)
        #expect(!SnapGeometry.manualMiddle(a: Vector(1, 1), b: .invalid).valid)
    }

    @Test("manual intersection finds the crossing of two lines")
    func manualIntersectionLineLine() {
        // Horizontal y=0 line and vertical x=3 line cross at (3,0).
        let a = EntityRecord(id: EntityID(1),
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let b = EntityRecord(id: EntityID(2),
                             kind: .line(LineData(start: Vector(3, -5), end: Vector(3, 5))))
        let p = Snapping.manualIntersection(entityA: a, entityB: b)
        #expect(p.valid)
        #expect(p.distance(to: Vector(3, 0)) < 1e-9)
    }

    @Test("manual intersection finds a line/arc crossing")
    func manualIntersectionLineArc() {
        // Circle-quadrant arc r=5 at origin (0°..90°) and the vertical line x=3.
        // The arc point with x=3 is (3,4) (since 3²+4²=5²) and is within 0°..90°.
        let line = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(3, -10), end: Vector(3, 10))))
        let arc = EntityRecord(id: EntityID(2),
                               kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                                                  startAngle: 0, endAngle: Double.pi / 2)))
        let p = Snapping.manualIntersection(entityA: line, entityB: arc, near: Vector(3, 4))
        #expect(p.valid)
        #expect(p.distance(to: Vector(3, 4)) < 1e-9)
    }

    @Test("manual intersection picks the crossing nearest the cursor when there are two")
    func manualIntersectionNearest() {
        // Full circle r=5 at origin and the vertical line x=3 cross at (3,4) and
        // (3,-4). With `near` below the axis, expect (3,-4).
        let line = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(3, -10), end: Vector(3, 10))))
        let circle = EntityRecord(id: EntityID(2),
                                  kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let p = Snapping.manualIntersection(entityA: line, entityB: circle, near: Vector(3, -3))
        #expect(p.valid)
        #expect(p.distance(to: Vector(3, -4)) < 1e-9)
    }

    @Test("manual intersection of non-crossing entities is invalid")
    func manualIntersectionNone() {
        let a = EntityRecord(id: EntityID(1),
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let b = EntityRecord(id: EntityID(2),
                             kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))))  // parallel
        #expect(!Snapping.manualIntersection(entityA: a, entityB: b).valid)
    }
}

// MARK: - Pipeline integration + existing-behavior regression

@MainActor
private struct DistanceAlongFixture {
    let drawing = CADDrawing()
    let quadtree = Quadtree()
    /// Horizontal line (0,0)→(10,0).
    let hLine: EntityID
    /// Quarter-circle arc r=4 at origin, 0°..90°.
    let arc: EntityID

    init() {
        func add(_ kind: EntityKind, _ d: CADDrawing, _ q: Quadtree) -> EntityID {
            let id = d.add(EntityRecord(id: EntityID(0), kind: kind))
            q.insert(id, bounds: d.entity(id)!.boundingBox())
            return id
        }
        hLine = add(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))), drawing, quadtree)
        arc = add(.arc(ArcData(center: Vector(0, 0), radius: 4,
                               startAngle: 0, endAngle: Double.pi / 2)), drawing, quadtree)
    }
}

@Suite("Distance-along & mode-set pipeline")
struct SnapModePipelineTests {

    @MainActor
    @Test("new modes are NOT in the standard set")
    func newModesOffByDefault() {
        #expect(!SnapMode.standard.contains(.distanceAlong))
        #expect(!SnapMode.standard.contains(.manualMiddle))
        #expect(!SnapMode.standard.contains(.manualIntersection))
    }

    @MainActor
    @Test("distance-along is inert without a configured spacing")
    func distanceAlongInertWithoutSpacing() {
        let f = DistanceAlongFixture()
        // Cursor near where a (spacing=2) tick at x=4 would be, but no spacing passed.
        let r = Snapping.snap(worldPoint: Vector(4, 0.05),
                              modes: [.distanceAlong, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .free)
    }

    @MainActor
    @Test("distance-along snaps to an equidistant tick along a line")
    func distanceAlongLine() {
        let f = DistanceAlongFixture()
        // spacing 2 along the line from the near end (x=0): tick at x=4. Cursor near it.
        let r = Snapping.snap(worldPoint: Vector(4.04, 0.05),
                              modes: [.distanceAlong, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree,
                              distanceAlong: 2)
        #expect(r.point.distance(to: Vector(4, 0)) < 1e-9)
        #expect(r.entity == f.hLine)
        // Surfaced as .onEntity (the point is on the entity) — no new public kind.
        #expect(r.kind == .onEntity)
    }

    @MainActor
    @Test("distance-along snaps to an arc tick by arc length")
    func distanceAlongArc() {
        let f = DistanceAlongFixture()
        // r=4 arc, spacing = 4·π/6 → tick at 30° = (4·cos30, 4·sin30) ≈ (3.464, 2).
        let spacing = 4.0 * Double.pi / 6.0
        let tick = Vector(4 * cos(Double.pi / 6), 4 * sin(Double.pi / 6))
        let r = Snapping.snap(worldPoint: Vector(tick.x + 0.03, tick.y + 0.03),
                              modes: [.distanceAlong, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree,
                              distanceAlong: spacing)
        #expect(r.point.distance(to: tick) < 1e-6)
        #expect(r.entity == f.arc)
    }

    // -- Existing behavior unchanged --

    @MainActor
    @Test("public SnapKind set is unchanged (no new cases leak to renderers)")
    func snapKindSetUnchanged() {
        // Exhaustive over the public SnapKind; if a case were added this fails to
        // compile, which is the guard we want for the non-owned renderer switches.
        let kinds: [SnapKind] = [
            .free, .grid, .endpoint, .center, .middle, .onEntity, .intersection,
            .nearest, .perpendicular, .tangent, .parallel,
        ]
        for k in kinds {
            switch k {
            case .free, .grid, .endpoint, .center, .middle, .onEntity, .intersection,
                 .nearest, .perpendicular, .tangent, .parallel:
                break
            }
        }
        #expect(kinds.count == 11)
    }

    @MainActor
    @Test("standard endpoint snap still wins over a nearby distance-along tick")
    func endpointStillBeatsDistanceAlong() {
        let f = DistanceAlongFixture()
        // Near the line's start endpoint (0,0); with both endpoint and distanceAlong
        // enabled, the endpoint must still win (higher priority).
        let r = Snapping.snap(worldPoint: Vector(0.05, 0.05),
                              modes: [.endpoint, .distanceAlong, .free],
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree,
                              distanceAlong: 2)
        #expect(r.kind == .endpoint)
        #expect(r.point.distance(to: Vector(0, 0)) < 1e-9)
    }

    @MainActor
    @Test("standard snap result is identical with the new params omitted")
    func standardSnapUnchanged() {
        let f = DistanceAlongFixture()
        // A plain endpoint snap near (10,0) using the standard set — unaffected by
        // the additive modes/params.
        let r = Snapping.snap(worldPoint: Vector(9.97, 0.03),
                              modes: .standard,
                              worldTolerance: 0.3, gridSpacing: nil,
                              in: f.drawing, using: f.quadtree)
        #expect(r.kind == .endpoint)
        #expect(r.point.distance(to: Vector(10, 0)) < 1e-9)
    }
}
