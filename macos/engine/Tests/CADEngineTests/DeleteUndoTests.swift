//
//  DeleteUndoTests.swift
//  CADEngineTests
//
//  Engine-level CONTRACT test for the app's delete-selection feature. The app's
//  `CanvasModel.deleteSelection()` lives in the (un-importable) executable target,
//  so we exercise the exact ENGINE path it drives — and the same one its undo/redo
//  rely on — directly here:
//
//    delete:  for each selected id, `drawing.remove(id)` inside ONE undo group
//             + `quadtree.remove(id)`  (mirrors CanvasModel.applyCommit's
//             `.remove` case, grouped like deleteSelection's single commit).
//    undo:    `undoManager.undo()` restores the drawing's value snapshot, then the
//             spatial index is REBUILT (the undo closures only know about
//             `entities`, never the quadtree — mirrors CanvasModel.undo()).
//    redo:    `undoManager.redo()` re-applies the removal; rebuild the index again.
//
//  Asserts: after delete the subset is gone from BOTH the drawing and the
//  quadtree; after undo every removed entity is reinserted with its original draw
//  order and flags intact and the index is consistent; after redo it is removed
//  again; an empty-selection delete is a no-op.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("CADEngine delete + undo/redo contract")
struct DeleteUndoTests {

    // MARK: - Helpers

    private func makeLine(
        _ id: UInt64 = 0,
        from a: Vector,
        to b: Vector,
        flags: EntityFlags = .default
    ) -> EntityRecord {
        EntityRecord(id: EntityID(id), flags: flags, kind: .line(LineData(start: a, end: b)))
    }

    /// An UndoManager configured for unit testing: manual grouping (there is no run
    /// loop to auto-close per-event groups in a test process). Matches the project's
    /// existing CADDrawingTests convention.
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// Builds a drawing with `n` distinct, non-empty-AABB lines plus a matching
    /// quadtree indexed over their bounding boxes — the same invariant
    /// `CanvasModel.rebuildIndex()` maintains. Returns the drawing, the index, and
    /// the minted ids in draw order. Entities are added BEFORE the UndoManager is
    /// attached, so setup itself registers no undo (only the deletion under test does).
    private func makeScene(n: Int) -> (CADDrawing, Quadtree, [EntityID]) {
        let d = CADDrawing()
        let tree = Quadtree()
        var ids: [EntityID] = []
        for i in 0..<n {
            let f = Double(i)
            // Distinct, well-separated, non-degenerate boxes so each occupies its
            // own region (clean drop/return assertions, no overlap ambiguity).
            let rec = makeLine(from: Vector(f * 10, 0), to: Vector(f * 10 + 1, 1))
            let id = d.add(rec)
            ids.append(id)
            let box = d.entity(id)!.boundingBox()
            tree.insert(id, bounds: box)
        }
        #expect(d.count == n)
        #expect(tree.count == n)
        return (d, tree, ids)
    }

    /// Removes `subset` from `drawing` (undoable, ONE group) and from `tree` — the
    /// exact path `CanvasModel.deleteSelection()` drives for a multi-entity delete.
    private func deleteSubset(_ subset: [EntityID], from drawing: CADDrawing, tree: Quadtree, undo um: UndoManager) {
        um.beginUndoGrouping()
        for id in subset {
            drawing.remove(id)   // undoable value-snapshot removal (ADR-002)
            tree.remove(id)      // keep the spatial index in sync directly
        }
        um.endUndoGrouping()
    }

    /// Rebuilds the index from the drawing's current entities — what
    /// `CanvasModel.undo()`/`redo()` do, since the drawing's undo closures restore
    /// only `entities` and never touch the (separate) quadtree.
    private func rebuildIndex(_ tree: Quadtree, from drawing: CADDrawing) {
        tree.removeAll()
        for e in drawing.entities {
            let b = e.boundingBox()
            if !b.isEmpty { tree.insert(e.id, bounds: b) }
        }
    }

    /// True iff the quadtree's id set exactly matches the drawing's entity ids
    /// (the post-operation index-consistency invariant).
    private func indexConsistent(_ tree: Quadtree, _ drawing: CADDrawing) -> Bool {
        let drawingIDs = Set(drawing.entities.map(\.id))
        guard tree.count == drawingIDs.count else { return false }
        // Every drawing id is present in the tree with a box.
        return drawingIDs.allSatisfy { tree.box(for: $0) != nil }
    }

    // MARK: - Tests

    @Test("delete a subset removes them from drawing and quadtree; survivors remain")
    func deleteSubsetRemovesFromBoth() {
        let (d, tree, ids) = makeScene(n: 5)
        let um = testUndoManager()
        d.undoManager = um

        // Remove a non-contiguous subset (indices 1 and 3).
        let removed = [ids[1], ids[3]]
        let survivors = [ids[0], ids[2], ids[4]]

        deleteSubset(removed, from: d, tree: tree, undo: um)

        #expect(d.count == 3)
        for id in removed {
            #expect(!d.contains(id))         // gone from the drawing
            #expect(tree.box(for: id) == nil) // dropped from the quadtree
        }
        for id in survivors {
            #expect(d.contains(id))
            #expect(tree.box(for: id) != nil)
        }
        #expect(indexConsistent(tree, d))
    }

    @Test("undo reinserts every removed entity with draw order and flags intact; index consistent")
    func undoReinsertsWithOrderAndFlags() {
        // Build a scene where each entity carries a DISTINCT flag set, so undo's
        // value-snapshot restore is checked to preserve flags exactly (not just ids).
        let d = CADDrawing()
        let tree = Quadtree()
        let flagSets: [EntityFlags] = [
            .default,
            [.visible, .selected],
            [.visible, .locked],
            [.visible, .construction],
        ]
        var ids: [EntityID] = []
        for (i, flags) in flagSets.enumerated() {
            let f = Double(i)
            let id = d.add(makeLine(from: Vector(f * 10, 0), to: Vector(f * 10 + 1, 1), flags: flags))
            ids.append(id)
            tree.insert(id, bounds: d.entity(id)!.boundingBox())
        }
        let orderBefore = d.entities.map(\.id)
        let flagsBefore = Dictionary(uniqueKeysWithValues: d.entities.map { ($0.id, $0.flags) })

        let um = testUndoManager()
        d.undoManager = um

        // Remove the middle two (ids[1], ids[2]).
        deleteSubset([ids[1], ids[2]], from: d, tree: tree, undo: um)
        #expect(d.count == 2)

        // Undo the whole deletion as one step, then re-sync the index.
        #expect(um.canUndo)
        um.undo()
        rebuildIndex(tree, from: d)

        // All four reinserted, in the ORIGINAL draw order.
        #expect(d.count == 4)
        #expect(d.entities.map(\.id) == orderBefore)
        // Flags survived the snapshot round-trip exactly.
        for e in d.entities {
            #expect(e.flags == flagsBefore[e.id])
        }
        #expect(indexConsistent(tree, d))
    }

    @Test("redo removes the subset again; index consistent")
    func redoRemovesAgain() {
        let (d, tree, ids) = makeScene(n: 4)
        let um = testUndoManager()
        d.undoManager = um

        let removed = [ids[0], ids[2]]
        deleteSubset(removed, from: d, tree: tree, undo: um)
        #expect(d.count == 2)

        um.undo()
        rebuildIndex(tree, from: d)
        #expect(d.count == 4)
        #expect(indexConsistent(tree, d))

        #expect(um.canRedo)
        um.redo()
        rebuildIndex(tree, from: d)

        #expect(d.count == 2)
        for id in removed {
            #expect(!d.contains(id))
            #expect(tree.box(for: id) == nil)
        }
        #expect(indexConsistent(tree, d))
    }

    @Test("full undo/redo cycle round-trips the drawing and the index")
    func fullCycleRoundTrips() {
        let (d, tree, ids) = makeScene(n: 6)
        let um = testUndoManager()
        d.undoManager = um

        let orderBefore = d.entities.map(\.id)
        let removed = [ids[1], ids[2], ids[4]]

        deleteSubset(removed, from: d, tree: tree, undo: um)
        #expect(d.count == 3)
        #expect(indexConsistent(tree, d))

        um.undo();  rebuildIndex(tree, from: d)
        #expect(d.entities.map(\.id) == orderBefore)   // exact restoration
        #expect(indexConsistent(tree, d))

        um.redo();  rebuildIndex(tree, from: d)
        #expect(d.count == 3)
        #expect(Set(d.entities.map(\.id)) == Set([ids[0], ids[3], ids[5]]))
        #expect(indexConsistent(tree, d))

        um.undo();  rebuildIndex(tree, from: d)
        #expect(d.entities.map(\.id) == orderBefore)   // back to the start, in order
        #expect(indexConsistent(tree, d))
    }

    @Test("empty-selection delete is a no-op (no mutation, no undo step)")
    func emptySelectionIsNoOp() {
        let (d, tree, _) = makeScene(n: 3)
        let um = testUndoManager()
        d.undoManager = um

        // Mirror CanvasModel.deleteSelection's empty guard: with nothing selected
        // there are no edits, so applyCommit is never entered and no group is opened.
        let emptySubset: [EntityID] = []
        let countBefore = d.count
        let idsBefore = d.entities.map(\.id)

        if !emptySubset.isEmpty {
            deleteSubset(emptySubset, from: d, tree: tree, undo: um)
        }

        #expect(d.count == countBefore)
        #expect(d.entities.map(\.id) == idsBefore)
        #expect(!um.canUndo)               // nothing registered ⇒ no undo step
        #expect(indexConsistent(tree, d))
    }
}
