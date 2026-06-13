//
//  CADDrawingTests.swift
//  CADEngineTests
//
//  Document model + ADR-002 undo: add/remove/replace register value-snapshot
//  undo against a real UndoManager; undo/redo restore the prior value.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("CADDrawing document model")
struct CADDrawingTests {

    private func makeLine(_ id: UInt64 = 0, from a: Vector = Vector(0, 0), to b: Vector = Vector(1, 1)) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    /// An UndoManager configured for unit testing: manual grouping (no run loop
    /// to auto-close event groups in a test process).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    @Test("minted ids are unique and monotonic")
    func mintsUniqueIDs() {
        let d = CADDrawing()
        let a = d.mintID(), b = d.mintID(), c = d.mintID()
        #expect(a != b && b != c && a != c)
        #expect(a.rawValue < b.rawValue && b.rawValue < c.rawValue)
    }

    @Test("add assigns an id and indexes the entity")
    func addIndexes() {
        let d = CADDrawing()
        let id = d.add(makeLine())
        #expect(d.count == 1)
        #expect(d.contains(id))
        #expect(d.entity(id) != nil)
        #expect(id.rawValue != 0)  // placeholder 0 was minted a real id
    }

    @Test("add then undo empties, redo restores (real UndoManager)")
    func addUndoRedo() {
        let um = testUndoManager()
        let d = CADDrawing()
        d.undoManager = um

        um.beginUndoGrouping()
        let id = d.add(makeLine())
        um.endUndoGrouping()
        #expect(d.count == 1)

        #expect(um.canUndo)
        um.undo()
        #expect(d.count == 0)
        #expect(!d.contains(id))

        #expect(um.canRedo)
        um.redo()
        #expect(d.count == 1)
        #expect(d.contains(id))
    }

    @Test("remove then undo restores at original draw order")
    func removeUndoRestoresOrder() {
        let d = CADDrawing()
        // Setup without undo registration.
        let id0 = d.add(makeLine(from: Vector(0, 0), to: Vector(1, 0)))
        let id1 = d.add(makeLine(from: Vector(0, 1), to: Vector(1, 1)))
        let id2 = d.add(makeLine(from: Vector(0, 2), to: Vector(1, 2)))

        // Now attach the undo manager for the operation under test.
        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.remove(id1)  // remove the middle one
        um.endUndoGrouping()
        #expect(d.count == 2)
        #expect(!d.contains(id1))

        um.undo()
        #expect(d.count == 3)
        #expect(d.contains(id1))
        // Original order preserved: id0, id1, id2.
        #expect(d.entities.map(\.id) == [id0, id1, id2])
    }

    @Test("replace then undo restores the prior value")
    func replaceUndoRestoresValue() {
        let d = CADDrawing()
        let id = d.add(makeLine(from: Vector(0, 0), to: Vector(1, 1)))

        let um = testUndoManager()
        d.undoManager = um

        var edited = d.entity(id)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(5, 5)))

        um.beginUndoGrouping()
        d.replace(edited)
        um.endUndoGrouping()
        if case .line(let ld) = d.entity(id)!.kind {
            #expect(ld.end == Vector(5, 5))
        } else { Issue.record("expected a line") }

        um.undo()
        if case .line(let ld) = d.entity(id)!.kind {
            #expect(ld.end == Vector(1, 1))  // prior value restored
        } else { Issue.record("expected a line") }

        um.redo()
        if case .line(let ld) = d.entity(id)!.kind {
            #expect(ld.end == Vector(5, 5))  // redo reapplies
        } else { Issue.record("expected a line") }
    }

    @Test("no UndoManager == mutations still apply (undo simply disabled)")
    func noUndoManager() {
        let d = CADDrawing()  // undoManager is nil
        let id = d.add(makeLine())
        d.remove(id)
        #expect(d.count == 0)
    }

    @Test("bulk load clears undo and advances the id counter")
    func bulkLoad() {
        let d = CADDrawing()
        let loaded = [
            makeLine(10), makeLine(20), makeLine(5),
        ]
        d.load(entities: loaded, layers: LayerTable())
        #expect(d.count == 3)
        #expect(d.contains(EntityID(20)))
        // Next minted id must clear the highest loaded id (20).
        #expect(d.mintID().rawValue == 21)
    }

    @Test("document bounding box unions all entities")
    func documentBBox() {
        let d = CADDrawing()
        _ = d.add(makeLine(from: Vector(0, 0), to: Vector(2, 2)))
        _ = d.add(EntityRecord(id: EntityID(0), kind: .circle(CircleData(center: Vector(10, 10), radius: 5))))
        let box = d.boundingBox()
        #expect(box.min == Vector(0, 0))
        #expect(box.max == Vector(15, 15))
    }
}
