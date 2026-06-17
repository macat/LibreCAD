//
//  EntityGripOverlayTests.swift
//  CADEngineTests
//
//  Headless tests for the per-entity GRIP-EDITING overlay (`EntityGripOverlayView`,
//  reached via the `_SharedEntityGripOverlay.swift` symlink into this target). The
//  overlay's geometry MATH lives in `EntityGrips` (already unit-tested); this suite
//  locks the overlay's OWN pure logic — the only logic it carries:
//
//    1. `makeHandles(for:ctx:)` — flattens a selection into one `EntityGripHandle`
//       per `EntityGrips.grips(...)` entry, tagged with the OWNING record + the
//       grip's stable engine index (single- AND multi-entity selection), and drops
//       records that expose no grips.
//    2. `EntityGripHitTest.nearestHandle(...)` — projects each handle's WORLD anchor
//       through the `Viewport` and returns the nearest grip within slop (square test +
//       Euclidean tie-break), or `nil` when the screen point is outside every grip.
//    3. The drag → `EntityGrips.moveGrip` → `onGripCommit(EntityRecord)` contract:
//       a grabbed handle's grip index + the cursor world point produce the correct
//       MOVED record, which is what the overlay hands the injected commit closure.
//
//  The actual AppKit DRAW (the blue grip squares, the green drag preview) is GUI-only
//  and not exercised here (it has no headless surface — `NSGraphicsContext`); the
//  load-bearing logic (which grip is hit, which record is committed) is all pure and
//  fully covered below.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("Entity grip overlay (per-entity grip editing, view layer)")
struct EntityGripOverlayTests {

    // MARK: - Fixtures / helpers

    private static let eps = 1e-9
    private static let ctx = ResolveContext.default

    /// Wraps a bare `EntityKind` in a record (id/layer/pen irrelevant to grips).
    private static func rec(_ kind: EntityKind, id: UInt64 = 1) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: kind)
    }

    /// An identity 1pt/unit viewport centered on the origin: `worldToScreen` is then
    /// `(w/2 + x, h/2 - y)`, so test screen points are easy to reason about.
    private static func viewport(size: CGSize = CGSize(width: 200, height: 200)) -> Viewport {
        Viewport(scale: 1.0, center: Vector(0, 0), size: size)
    }

    private static func approxEqual(_ a: Vector, _ b: Vector, _ tol: Double = eps) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol
    }

    // MARK: - makeHandles: flattening a selection into tagged handles

    @Test("makeHandles: a single line yields its 3 grips, each tagged with the record")
    func makeHandlesSingleLine() {
        let line = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))), id: 7)
        let handles = EntityGripOverlayView.makeHandles(for: [line], ctx: Self.ctx)
        // line → start(0)/end(1)/mid(2)
        #expect(handles.count == 3)
        #expect(handles.map(\.gripIndex) == [0, 1, 2])
        // Every handle is tagged with the SAME owning record.
        #expect(handles.allSatisfy { $0.record.id == EntityID(7) })
        // World anchors match EntityGrips.grips exactly (same source of truth).
        let grips = EntityGrips.grips(for: line, ctx: Self.ctx)
        for (h, g) in zip(handles, grips) {
            #expect(Self.approxEqual(h.world, g.world))
            #expect(h.role == g.role)
        }
    }

    @Test("makeHandles: multi-entity selection flattens grips of EVERY entity, tagged per owner")
    func makeHandlesMultiEntity() {
        let line = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(4, 0))), id: 1)   // 3 grips
        let circle = Self.rec(.circle(CircleData(center: Vector(20, 0), radius: 5)), id: 2)   // 5 grips
        let handles = EntityGripOverlayView.makeHandles(for: [line, circle], ctx: Self.ctx)
        #expect(handles.count == 3 + 5)
        // First three belong to the line, next five to the circle.
        #expect(handles[0..<3].allSatisfy { $0.record.id == EntityID(1) })
        #expect(handles[3..<8].allSatisfy { $0.record.id == EntityID(2) })
        // The circle's grip indices restart at 0 (engine indices are per-entity).
        #expect(Array(handles[3..<8].map(\.gripIndex)) == [0, 1, 2, 3, 4])
    }

    @Test("makeHandles: non-grip kinds contribute nothing")
    func makeHandlesDropsNonGripKinds() {
        // A hatch exposes no per-point grips (EntityGrips returns []).
        let hatch = Self.rec(.hatch(HatchData(loops: [])), id: 9)
        let line = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(1, 1))), id: 10)
        let handles = EntityGripOverlayView.makeHandles(for: [hatch, line], ctx: Self.ctx)
        // Only the line's 3 grips survive.
        #expect(handles.count == 3)
        #expect(handles.allSatisfy { $0.record.id == EntityID(10) })
    }

    @Test("makeHandles: an empty selection yields no handles")
    func makeHandlesEmpty() {
        #expect(EntityGripOverlayView.makeHandles(for: [], ctx: Self.ctx).isEmpty)
    }

    // MARK: - nearestHandle: screen projection + slop hit-test

    @Test("nearestHandle: a click exactly on a grip's screen position hits that grip")
    func nearestHandleDirectHit() {
        let line = Self.rec(.line(LineData(start: Vector(-50, 0), end: Vector(50, 0))))
        let handles = EntityGripOverlayView.makeHandles(for: [line], ctx: Self.ctx)
        let vp = Self.viewport()   // 200×200, identity → world (x,y) → (100+x, 100-y)
        // The END grip (index 1) is at world (50,0) → screen (150, 100).
        let endScreen = vp.worldToScreen(Vector(50, 0))
        #expect(endScreen == CGPoint(x: 150, y: 100))
        let i = EntityGripHitTest.nearestHandle(to: endScreen, handles: handles,
                                                viewport: vp, slop: 8)
        #expect(i != nil)
        #expect(handles[i!].gripIndex == 1)
        #expect(Self.approxEqual(handles[i!].world, Vector(50, 0)))
    }

    @Test("nearestHandle: a click within slop of a grip still hits it")
    func nearestHandleWithinSlop() {
        let pt = Self.rec(.point(PointData(position: Vector(10, 10))))
        let handles = EntityGripOverlayView.makeHandles(for: [pt], ctx: Self.ctx)
        let vp = Self.viewport()                     // grip at world(10,10) → screen(110, 90)
        let gripScreen = vp.worldToScreen(Vector(10, 10))
        // 3 points away in both axes — within slop 8.
        let near = CGPoint(x: gripScreen.x + 3, y: gripScreen.y - 3)
        #expect(EntityGripHitTest.nearestHandle(to: near, handles: handles, viewport: vp, slop: 8) == 0)
    }

    @Test("nearestHandle: a click outside slop of every grip misses (nil)")
    func nearestHandleMiss() {
        let pt = Self.rec(.point(PointData(position: Vector(0, 0))))
        let handles = EntityGripOverlayView.makeHandles(for: [pt], ctx: Self.ctx)
        let vp = Self.viewport()                     // single grip at screen center (100,100)
        // 50 points away — well outside slop 8.
        let far = CGPoint(x: 150, y: 100)
        #expect(EntityGripHitTest.nearestHandle(to: far, handles: handles, viewport: vp, slop: 8) == nil)
    }

    @Test("nearestHandle: overlapping grips resolve to the geometrically nearest")
    func nearestHandleTieBreak() {
        // Two points whose grips are only 4 screen-points apart (both within slop 8 of
        // a click between them); the click sits closer to the SECOND.
        let a = Self.rec(.point(PointData(position: Vector(0, 0))), id: 1)   // screen (100,100)
        let b = Self.rec(.point(PointData(position: Vector(4, 0))), id: 2)   // screen (104,100)
        let handles = EntityGripOverlayView.makeHandles(for: [a, b], ctx: Self.ctx)
        let vp = Self.viewport()
        // Click at screen (103,100): 3 from a, 1 from b → b wins.
        let i = EntityGripHitTest.nearestHandle(to: CGPoint(x: 103, y: 100),
                                                handles: handles, viewport: vp, slop: 8)
        #expect(i != nil)
        #expect(handles[i!].record.id == EntityID(2))
    }

    @Test("nearestHandle: empty handle list is always a miss")
    func nearestHandleEmpty() {
        #expect(EntityGripHitTest.nearestHandle(to: CGPoint(x: 0, y: 0),
                                                handles: [], viewport: Self.viewport(),
                                                slop: 8) == nil)
    }

    // MARK: - drag → moveGrip → onGripCommit (the commit contract)

    /// Mirrors the overlay's mouse-down→up logic headlessly: pick the handle under a
    /// down-screen-point, then on up compute the moved record from the up-world-point
    /// and hand it to `onGripCommit` — exactly what `EntityGripOverlayView.mouseUp`
    /// does, minus the live AppKit events.
    private static func simulateDrag(
        selection: [EntityRecord],
        downScreen: CGPoint,
        upScreen: CGPoint,
        viewport vp: Viewport,
        slop: CGFloat = 8,
        onGripCommit: (EntityRecord) -> Void
    ) {
        let handles = EntityGripOverlayView.makeHandles(for: selection, ctx: ctx)
        guard let i = EntityGripHitTest.nearestHandle(to: downScreen, handles: handles,
                                                      viewport: vp, slop: slop) else { return }
        let grabbed = handles[i]
        let upWorld = vp.screenToWorld(upScreen)
        if let moved = EntityGrips.moveGrip(grabbed.gripIndex, of: grabbed.record,
                                            to: upWorld, ctx: ctx) {
            onGripCommit(moved)
        }
    }

    @Test("drag a line endpoint: moveGrip result is committed, other end fixed, attrs kept")
    func dragLineEndpointCommits() {
        var line = Self.rec(.line(LineData(start: Vector(-50, 0), end: Vector(50, 0))), id: 5)
        line.layer = LayerID("walls")
        let vp = Self.viewport()                     // end grip world(50,0) → screen(150,100)
        var committed: EntityRecord?
        Self.simulateDrag(selection: [line],
                          downScreen: CGPoint(x: 150, y: 100),    // grab the END grip (index 1)
                          upScreen: CGPoint(x: 150, y: 60),       // drag up 40 → world (50, 40)
                          viewport: vp) { committed = $0 }
        guard let committed, case .line(let l) = committed.kind else {
            Issue.record("expected a committed line"); return
        }
        // Dragged end followed the cursor; start stayed put.
        #expect(Self.approxEqual(l.end, Vector(50, 40)))
        #expect(Self.approxEqual(l.start, Vector(-50, 0)))
        // The record's identity/attrs survive the edit (EntityGrips preserves them).
        #expect(committed.id == EntityID(5))
        #expect(committed.layer == LayerID("walls"))
    }

    @Test("drag a circle quadrant: commits a new radius about the fixed center")
    func dragCircleQuadrantCommits() {
        let circle = Self.rec(.circle(CircleData(center: Vector(0, 0), radius: 10)), id: 6)
        let vp = Self.viewport()                     // E quadrant world(10,0) → screen(110,100)
        var committed: EntityRecord?
        Self.simulateDrag(selection: [circle],
                          downScreen: CGPoint(x: 110, y: 100),    // grab the E quadrant (index 1)
                          upScreen: CGPoint(x: 125, y: 100),      // drag to world (25, 0)
                          viewport: vp) { committed = $0 }
        guard let committed, case .circle(let c) = committed.kind else {
            Issue.record("expected a committed circle"); return
        }
        #expect(Self.approxEqual(c.center, Vector(0, 0)))   // center fixed
        #expect(abs(c.radius - 25) < Self.eps)              // new radius = |world − center|
    }

    @Test("drag in a multi-entity selection edits ONLY the owning entity")
    func dragMultiSelectEditsOwnerOnly() {
        let line = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(0, 0))), id: 1)
        let pt = Self.rec(.point(PointData(position: Vector(30, 0))), id: 2)   // screen(130,100)
        let vp = Self.viewport()
        var committed: EntityRecord?
        // Grab the POINT's grip (it owns id 2), drag it to world (30, 20).
        Self.simulateDrag(selection: [line, pt],
                          downScreen: CGPoint(x: 130, y: 100),
                          upScreen: CGPoint(x: 130, y: 80),
                          viewport: vp) { committed = $0 }
        guard let committed else { Issue.record("expected a commit"); return }
        // The committed record is the POINT (id 2), moved — the line is untouched.
        #expect(committed.id == EntityID(2))
        guard case .point(let p) = committed.kind else { Issue.record("expected point"); return }
        #expect(Self.approxEqual(p.position, Vector(30, 20)))
    }

    @Test("a click that hits no grip commits nothing (overlay stays transparent)")
    func clickMissCommitsNothing() {
        let pt = Self.rec(.point(PointData(position: Vector(0, 0))))
        let vp = Self.viewport()
        var commits = 0
        Self.simulateDrag(selection: [pt],
                          downScreen: CGPoint(x: 180, y: 20),     // far from the only grip
                          upScreen: CGPoint(x: 180, y: 20),
                          viewport: vp) { _ in commits += 1 }
        #expect(commits == 0)
    }

    @Test("a degenerate grip move (circle quadrant onto center) commits nothing")
    func degenerateMoveCommitsNothing() {
        let circle = Self.rec(.circle(CircleData(center: Vector(0, 0), radius: 10)))
        let vp = Self.viewport()
        var commits = 0
        // Grab the E quadrant, drag it ONTO the center → zero radius → moveGrip nil.
        Self.simulateDrag(selection: [circle],
                          downScreen: CGPoint(x: 110, y: 100),    // E quadrant
                          upScreen: CGPoint(x: 100, y: 100),      // the center → degenerate
                          viewport: vp) { _ in commits += 1 }
        #expect(commits == 0)
    }
}
