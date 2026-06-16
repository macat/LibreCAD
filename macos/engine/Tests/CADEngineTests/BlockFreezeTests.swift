//
//  BlockFreezeTests.swift
//  CADEngineTests
//
//  Block freeze / visibility engine ops (the UNWIRED half of upstream LibreCAD's
//  per-block freeze/toggle-view + Freeze-all/Defreeze-all — `RS_Block::freeze` /
//  `RS_Block::toggle` / `RS_BlockList::freezeAll`):
//   - `CADDrawing.setBlockFrozen(_:_:)`  — set a block's frozen flag (undoable).
//   - `CADDrawing.toggleBlockFrozen(_:)` — flip it (undoable).
//   - `CADDrawing.freezeAllBlocks()` / `thawAllBlocks()` — batch every NAMED block
//     (anonymous `*`-blocks skipped) in ONE undoable step.
//
//  Each op routes through the `mutateBlocks` value-snapshot funnel, so it is exactly
//  ONE ⌘Z-undoable step and a genuine no-op (no flag change) registers no undo. The
//  engine HONORS the flag at resolve: `blockMembersSnapshot()` excludes frozen blocks,
//  so a frozen block's `.insert` resolves to EMPTY geometry. These tests assert both
//  the flag and the resolve-level invisibility, plus undo coalescing + safety.
//
//  Uniquely namespaced (`@Suite("block freeze / visibility")`) so it does not collide
//  with the other block suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("block freeze / visibility")
struct BlockFreezeTests {

    // MARK: - Helpers

    /// An UndoManager configured for unit testing (manual grouping).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    private func line(_ a: Vector, _ b: Vector, id: UInt64) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    /// Whether a resolved geometry has any drawable output at all.
    private func isEmptyGeometry(_ g: ResolvedGeometry) -> Bool {
        g.polylines.allSatisfy { $0.points.isEmpty }
            && g.fills.isEmpty && g.images.isEmpty
    }

    /// A drawing carrying ONE named block "B" with a single member line, placed via
    /// ONE top-level `.insert` of that block. Seeded WITHOUT the undo manager (so the
    /// seed work registers no undo); the caller attaches one for the op under test.
    private func seededWithBlockAndInsert(
        blockName: String = "B"
    ) -> (drawing: CADDrawing, insertID: EntityID) {
        let d = CADDrawing()
        // Member geometry (local origin → simple horizontal line).
        let memberID = d.add(line(Vector(0, 0), Vector(10, 0), id: 1))
        _ = d.addBlock(Block(name: blockName, basePoint: Vector(0, 0),
                             entityIDs: [memberID]))
        let insertID = d.add(EntityRecord(
            id: EntityID(100),
            kind: .insert(InsertData(blockName: blockName, insertionPoint: Vector(5, 5)))))
        return (d, insertID)
    }

    /// Resolves the named insert in the drawing.
    private func resolveInsert(_ d: CADDrawing, _ id: EntityID) -> ResolvedGeometry {
        let rec = d.entity(id)!
        return rec.resolve(d.makeResolveContext())
    }

    // MARK: - setBlockFrozen: flag + resolve-level invisibility

    @Test("setBlockFrozen(true) sets the flag AND the insert resolves to EMPTY")
    func setFrozenTrueHidesInsert() {
        let (d, insertID) = seededWithBlockAndInsert()

        // Before: not frozen, insert resolves to real geometry.
        #expect(d.blocks.block(named: "B")?.isFrozen == false)
        #expect(!isEmptyGeometry(resolveInsert(d, insertID)))

        d.setBlockFrozen("B", true)

        #expect(d.blocks.block(named: "B")?.isFrozen == true)
        // The frozen block is excluded from blockMembersSnapshot → insert is empty.
        #expect(isEmptyGeometry(resolveInsert(d, insertID)))
    }

    @Test("setBlockFrozen(false) restores visibility")
    func setFrozenFalseRestores() {
        let (d, insertID) = seededWithBlockAndInsert()
        d.setBlockFrozen("B", true)
        #expect(isEmptyGeometry(resolveInsert(d, insertID)))

        d.setBlockFrozen("B", false)
        #expect(d.blocks.block(named: "B")?.isFrozen == false)
        #expect(!isEmptyGeometry(resolveInsert(d, insertID)))
    }

    @Test("setBlockFrozen on an unknown block is a safe no-op")
    func setFrozenUnknownNameSafe() {
        let (d, _) = seededWithBlockAndInsert()
        let before = d.blocks
        let um = testUndoManager()             // strong ref (undoManager is weak)
        d.undoManager = um
        d.setBlockFrozen("NOPE", true)
        #expect(d.blocks == before)            // table untouched
        #expect(um.canUndo == false)           // no undo registered
    }

    // MARK: - toggleBlockFrozen

    @Test("toggleBlockFrozen flips the flag each call")
    func toggleFlips() {
        let (d, _) = seededWithBlockAndInsert()
        #expect(d.blocks.block(named: "B")?.isFrozen == false)
        d.toggleBlockFrozen("B")
        #expect(d.blocks.block(named: "B")?.isFrozen == true)
        d.toggleBlockFrozen("B")
        #expect(d.blocks.block(named: "B")?.isFrozen == false)
    }

    @Test("toggleBlockFrozen on an unknown block is a safe no-op")
    func toggleUnknownNameSafe() {
        let (d, _) = seededWithBlockAndInsert()
        let before = d.blocks
        let um = testUndoManager()             // strong ref (undoManager is weak)
        d.undoManager = um
        d.toggleBlockFrozen("NOPE")
        #expect(d.blocks == before)
        #expect(um.canUndo == false)
    }

    // MARK: - freezeAll / thawAll: every NAMED block, anonymous `*` skipped

    @Test("freezeAllBlocks freezes every named block; thawAllBlocks restores all")
    func freezeThawAllNamedBlocks() {
        let d = CADDrawing()
        _ = d.addBlock(Block(name: "A"))
        _ = d.addBlock(Block(name: "B"))
        _ = d.addBlock(Block(name: "C"))

        d.freezeAllBlocks()
        for n in ["A", "B", "C"] {
            #expect(d.blocks.block(named: n)?.isFrozen == true)
        }

        d.thawAllBlocks()
        for n in ["A", "B", "C"] {
            #expect(d.blocks.block(named: n)?.isFrozen == false)
        }
    }

    @Test("freezeAllBlocks skips anonymous `*`-blocks")
    func freezeAllSkipsAnonymous() {
        let d = CADDrawing()
        _ = d.addBlock(Block(name: "REAL"))
        _ = d.addBlock(Block(name: "*U1"))   // anonymous (dimension/hatch geometry)

        d.freezeAllBlocks()
        #expect(d.blocks.block(named: "REAL")?.isFrozen == true)
        #expect(d.blocks.block(named: "*U1")?.isFrozen == false)  // untouched
    }

    // MARK: - undo: each op is exactly ONE ⌘Z step

    @Test("setBlockFrozen is one undoable step")
    func setFrozenUndoable() {
        let (d, _) = seededWithBlockAndInsert()
        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.setBlockFrozen("B", true)
        um.endUndoGrouping()
        #expect(d.blocks.block(named: "B")?.isFrozen == true)

        um.undo()
        #expect(d.blocks.block(named: "B")?.isFrozen == false)
        um.redo()
        #expect(d.blocks.block(named: "B")?.isFrozen == true)
    }

    @Test("toggleBlockFrozen is one undoable step")
    func toggleUndoable() {
        let (d, _) = seededWithBlockAndInsert()
        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.toggleBlockFrozen("B")
        um.endUndoGrouping()
        #expect(d.blocks.block(named: "B")?.isFrozen == true)

        um.undo()
        #expect(d.blocks.block(named: "B")?.isFrozen == false)
    }

    @Test("freezeAllBlocks reverts in ONE undo step (whole batch coalesced)")
    func freezeAllUndoableAsOneStep() {
        let d = CADDrawing()
        _ = d.addBlock(Block(name: "A"))
        _ = d.addBlock(Block(name: "B"))
        _ = d.addBlock(Block(name: "C"))

        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.freezeAllBlocks()
        um.endUndoGrouping()
        for n in ["A", "B", "C"] {
            #expect(d.blocks.block(named: n)?.isFrozen == true)
        }

        // A SINGLE undo reverts the whole batch (value-snapshot funnel).
        um.undo()
        for n in ["A", "B", "C"] {
            #expect(d.blocks.block(named: n)?.isFrozen == false)
        }
    }

    // MARK: - no-op edits register NO undo

    @Test("setBlockFrozen to the same value registers no undo")
    func setFrozenNoOpNoUndo() {
        let (d, _) = seededWithBlockAndInsert()  // born unfrozen
        let um = testUndoManager()
        d.undoManager = um
        d.setBlockFrozen("B", false)             // already false → no change
        #expect(um.canUndo == false)
    }

    @Test("freezeAllBlocks when all already frozen registers no undo")
    func freezeAllNoOpNoUndo() {
        let d = CADDrawing()
        _ = d.addBlock(Block(name: "A", isFrozen: true))
        _ = d.addBlock(Block(name: "B", isFrozen: true))

        let um = testUndoManager()
        d.undoManager = um
        d.freezeAllBlocks()                       // every named block already frozen
        #expect(um.canUndo == false)
    }

    @Test("freezeAllBlocks on a drawing with no named blocks is a no-op")
    func freezeAllNoNamedBlocksNoUndo() {
        let d = CADDrawing()
        _ = d.addBlock(Block(name: "*U1"))        // only anonymous
        let um = testUndoManager()
        d.undoManager = um
        d.freezeAllBlocks()
        #expect(um.canUndo == false)
        #expect(d.blocks.block(named: "*U1")?.isFrozen == false)
    }
}
