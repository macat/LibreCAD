//
//  SnapQuadtreeTests.swift
//  CADEngineTests
//
//  Wave 2 — Snap fast path + incremental quadtree (P2/P3 in perf-arch-review-plan.md).
//  Verifies:
//    - `Quadtree.query(aabb:)` alias and `query(point:tolerance:)` tolerance box
//      correctness (AABB(cursor±tol) fast path for snapping).
//    - `nearbyEntities`-style prefilter→exact (quadtree + HitTesting) matches the
//      brute-force `O(N)` linear scan, and `Selection.hitTest` remains exact.
//    - `Snapping.snap` via the quadtree still finds the correct endpoint/center.
//    - `CanvasModel.undo`/`redo` incrementally re-sync the quadtree (no full
//      rebuild) and the index stays consistent with `activeSpaceEntities`.
//
//  GPLv2-or-later (LibreCAD macOS port).
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Pure quadtree / hit-test correctness (no CanvasModel)

@MainActor
@Suite("Snap quadtree fast path (pure)")
struct SnapQuadtreeFastPathTests {

    private func line(_ a: Vector, _ b: Vector, id: UInt64) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    @Test("query(aabb:) alias matches query(region:) and query(point:tolerance:)")
    func queryAABBAlias() {
        let qt = Quadtree()
        let r1 = line(Vector(0, 0), Vector(10, 0), id: 1)
        let r2 = line(Vector(100, 100), Vector(110, 100), id: 2)
        qt.insert(r1.id, bounds: r1.boundingBox())
        qt.insert(r2.id, bounds: r2.boundingBox())

        let p = Vector(5, 0)
        let tol = 1.0
        let aabb = AABB(min: Vector(p.x - tol, p.y - tol), max: Vector(p.x + tol, p.y + tol))
        let viaRegion = qt.query(region: aabb)
        let viaAABB = qt.query(aabb: aabb)
        let viaPoint = qt.query(point: p, tolerance: tol)
        #expect(Set(viaRegion) == Set(viaAABB))
        #expect(Set(viaRegion) == Set(viaPoint))
        #expect(viaRegion.contains(r1.id))
        #expect(!viaRegion.contains(r2.id))
    }

    @Test("quadtree point query uses AABB(cursor±tol) — inclusive on edges")
    func pointQueryToleranceBox() {
        let qt = Quadtree()
        // A point entity at (5,5) — its box is a degenerate point.
        let pt = EntityRecord(id: EntityID(10), kind: .point(PointData(position: Vector(5, 5))))
        qt.insert(pt.id, bounds: pt.boundingBox())
        // Query exactly at the point with tol 0 → should hit (edge inclusive).
        #expect(qt.query(point: Vector(5, 5), tolerance: 0).contains(pt.id))
        // Query 0.1 away with tol 0 → miss.
        #expect(!qt.query(point: Vector(5.1, 5), tolerance: 0).contains(pt.id))
        // Query 0.1 away with tol 0.1 → hit (box inflated contains cursor).
        #expect(qt.query(point: Vector(5.1, 5), tolerance: 0.1).contains(pt.id))
    }

    @Test("quadtree prefilter + HitTesting exact matches brute-force linear scan")
    func prefilterMatchesBruteForce() {
        // Build a drawing with a mix of near and far lines/circles.
        let drawing = CADDrawing()
        // Near line at origin
        _ = drawing.add(line(Vector(0, 0), Vector(10, 0), id: 0))
        // Far lines at (1000, 1000) etc. — far from origin pick.
        for i in 1...50 {
            let x = Double(1000 + i * 10)
            _ = drawing.add(line(Vector(x, x), Vector(x + 5, x), id: 0))
        }
        // Build quadtree over all entities (like CanvasModel.rebuildIndex does).
        let qt = Quadtree()
        let ctx = drawing.makeResolveContext()
        for e in drawing.entities {
            let b = e.boundingBox(ctx: ctx)
            if !b.isEmpty { qt.insert(e.id, bounds: b) }
        }
        let pick = Vector(5, 0.2)
        let tol = 0.5
        // Brute-force (old makeToolContext): O(N) filter by exact distance.
        let brute = drawing.entities.filter { rec in
            guard rec.flags.contains(.visible) else { return false }
            return HitTesting.worldDistance(from: pick, to: rec) <= tol
        }
        // Fast path: quadtree prefilter → exact distance.
        let candidates = qt.query(point: pick, tolerance: tol)
        let fast = candidates.compactMap { drawing.entity($0) }.filter { rec in
            guard rec.flags.contains(.visible) else { return false }
            return HitTesting.worldDistance(from: pick, to: rec) <= tol
        }
        #expect(Set(brute.map(\.id)) == Set(fast.map(\.id)))
        // Specifically, the near line should be found, far lines should not.
        #expect(fast.count == 1)
        #expect(fast.first?.id == brute.first?.id)
    }

    @Test("hitTest via quadtree remains exact (prefilter + analytic distance)")
    func hitTestExact() async {
        let drawing = CADDrawing()
        let a = drawing.add(line(Vector(0, 0), Vector(10, 0), id: 0))
        _ = drawing.add(line(Vector(100, 100), Vector(110, 100), id: 0))
        let qt = Quadtree()
        let ctx = drawing.makeResolveContext()
        for e in drawing.entities {
            let b = e.boundingBox(ctx: ctx)
            if !b.isEmpty { qt.insert(e.id, bounds: b) }
        }
        // Hit near (5, 0) within 0.5 should pick `a`.
        let sel = Selection()
        let hit = await sel.hitTest(worldPoint: Vector(5, 0.2), worldTolerance: 0.5, in: drawing, using: qt)
        #expect(hit == a)
        // Far pick should miss.
        let miss = await sel.hitTest(worldPoint: Vector(50, 50), worldTolerance: 0.5, in: drawing, using: qt)
        #expect(miss == nil)
        // Exact distance at tolerance edge: line at y=0, pick at y=0.5, tol 0.5 → hit (inclusive).
        let edge = await sel.hitTest(worldPoint: Vector(5, 0.5), worldTolerance: 0.5, in: drawing, using: qt)
        #expect(edge == a)
        // Just beyond → miss.
        let beyond = await sel.hitTest(worldPoint: Vector(5, 0.51), worldTolerance: 0.5, in: drawing, using: qt)
        #expect(beyond == nil)
    }

    @Test("Snapping via quadtree finds the correct endpoint and ignores far entities")
    func snappingViaQuadtree() async {
        let drawing = CADDrawing()
        _ = drawing.add(line(Vector(0, 0), Vector(10, 0), id: 0))
        // Far entity that must NOT be considered (outside snap aperture).
        _ = drawing.add(line(Vector(1000, 1000), Vector(1010, 1000), id: 0))
        let qt = Quadtree()
        let ctx = drawing.makeResolveContext()
        for e in drawing.entities {
            let b = e.boundingBox(ctx: ctx)
            if !b.isEmpty { qt.insert(e.id, bounds: b) }
        }
        // Snap near (0,0) endpoint with small tolerance — should snap to (0,0).
        let snap = await Snapping.snap(
            worldPoint: Vector(0.15, 0.05),
            modes: [.endpoint, .free],
            worldTolerance: 0.5,
            gridSpacing: nil,
            in: drawing,
            using: qt,
            ctx: ctx
        )
        #expect(snap.kind == .endpoint)
        #expect(snap.point.x == 0 && snap.point.y == 0)
        // Snap far from any geometry should fall back to .free.
        let free = await Snapping.snap(
            worldPoint: Vector(50, 50),
            modes: [.endpoint, .free],
            worldTolerance: 0.5,
            gridSpacing: nil,
            in: drawing,
            using: qt,
            ctx: ctx
        )
        #expect(free.kind == .free)
    }
}

// MARK: - CanvasModel incremental undo / quadtree consistency

@MainActor
@Suite("Quadtree incremental undo (CanvasModel)")
struct QuadtreeIncrementalUndoTests {

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: .placeholder, kind: .line(LineData(start: a, end: b)))
    }

    private func makeModel() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    private func quadtreeIDs(_ m: CanvasModel) -> Set<EntityID> {
        // Query a huge region to enumerate everything in the index.
        let big = AABB(min: Vector(-1e6, -1e6), max: Vector(1e6, 1e6))
        return Set(m.quadtree.query(region: big))
    }

    @Test("quadtree count matches activeSpaceEntities after rebuild")
    func countMatches() {
        let m = makeModel()
        #expect(m.quadtree.isEmpty)
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(10, 0)))])
        #expect(m.quadtree.count == 1)
        #expect(quadtreeIDs(m).count == 1)
    }

    @Test("undo of an add removes the id from the quadtree incrementally")
    func undoAdd() {
        let m = makeModel()
        let before = quadtreeIDs(m)
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(10, 0)))])
        let afterAdd = quadtreeIDs(m)
        #expect(afterAdd.count == before.count + 1)
        let added = afterAdd.subtracting(before)
        #expect(added.count == 1)

        m.undo()
        let afterUndo = quadtreeIDs(m)
        #expect(afterUndo == before)
        #expect(m.quadtree.count == before.count)
        // Quadtree should no longer contain the added id.
        for id in added { #expect(!afterUndo.contains(id)) }

        m.redo()
        let afterRedo = quadtreeIDs(m)
        #expect(afterRedo == afterAdd)
    }

    @Test("undo of a remove restores the id to the quadtree")
    func undoRemove() {
        let m = makeModel()
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(10, 0)))])
        m.applyToolEdits([.add(line(Vector(20, 0), Vector(30, 0)))])
        // Clear undo stack so the two adds are baseline, not undoable for this test.
        m.undoManager.removeAllActions()
        m.rebuildIndex()
        let baseline = quadtreeIDs(m)
        #expect(baseline.count == 2)

        // Remove one entity via deleteSelection (uses applyCommit → quadtree.remove).
        let toDelete = baseline.first!
        m.selection = Selection(ids: [toDelete])
        _ = m.deleteSelection()
        let afterDelete = quadtreeIDs(m)
        #expect(afterDelete.count == 1)
        #expect(!afterDelete.contains(toDelete))

        m.undo()
        let afterUndo = quadtreeIDs(m)
        #expect(afterUndo == baseline)
        #expect(afterUndo.contains(toDelete))

        m.redo()
        #expect(quadtreeIDs(m) == afterDelete)
    }

    @Test("undo of a replace (move) updates the quadtree box")
    func undoReplaceUpdatesBox() {
        let m = makeModel()
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(10, 0)))])
        m.undoManager.removeAllActions()
        m.rebuildIndex()
        let id = m.drawing.entities.first!.id
        let boxBefore = m.quadtree.box(for: id)
        #expect(boxBefore != nil)

        // Move the line far away via inspector edit (replace).
        var moved = m.drawing.entity(id)!
        moved.kind = .line(LineData(start: Vector(100, 100), end: Vector(110, 100)))
        m.applyInspectorEdits([moved])
        let boxAfter = m.quadtree.box(for: id)
        #expect(boxAfter != boxBefore)
        // Quadtree should query near new location, not old.
        let nearOld = m.quadtree.query(point: Vector(5, 0), tolerance: 1)
        #expect(!nearOld.contains(id))
        let nearNew = m.quadtree.query(point: Vector(105, 100), tolerance: 1)
        #expect(nearNew.contains(id))

        m.undo()
        let boxRestored = m.quadtree.box(for: id)
        #expect(boxRestored == boxBefore)
        #expect(m.quadtree.query(point: Vector(5, 0), tolerance: 1).contains(id))
        #expect(!m.quadtree.query(point: Vector(105, 100), tolerance: 1).contains(id))

        m.redo()
        #expect(m.quadtree.box(for: id) == boxAfter)
    }

    @Test("quadtree stays consistent after undo/redo with many far entities (incremental correctness)")
    func incrementalWithManyFarEntities() {
        let m = makeModel()
        // Add 100 far lines + 1 near line.
        for i in 0..<100 {
            let x = Double(1000 + i * 10)
            m.applyToolEdits([.add(line(Vector(x, x), Vector(x + 5, x)))])
        }
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(10, 0)))])
        m.undoManager.removeAllActions()
        m.rebuildIndex()
        let baselineCount = m.quadtree.count
        #expect(baselineCount == 101)

        // Delete the near line, then undo — far entities must remain indexed.
        let nearID = m.drawing.entities.first { e in
            if case .line(let d) = e.kind { return d.start == Vector(0, 0) }
            return false
        }!.id
        m.selection = Selection(ids: [nearID])
        _ = m.deleteSelection()
        #expect(m.quadtree.count == 100)
        #expect(!quadtreeIDs(m).contains(nearID))

        m.undo()
        #expect(m.quadtree.count == baselineCount)
        #expect(quadtreeIDs(m).contains(nearID))
        // Far query still finds a far entity (sanity that incremental didn't drop far nodes).
        let farProbe = m.quadtree.query(point: Vector(1005, 1000), tolerance: 2)
        #expect(!farProbe.isEmpty)
    }
}
