//
//  BlockAttributeOpsTests.swift
//  CADEngineTests
//
//  STAGE 1 — the undoable EDIT ops for block ATTRIBUTES on `CADDrawing`:
//    • `setInsertAttributeValue` — set/replace an `.insert`'s ATTRIB value (EATTEDIT
//      core); replaces in place when the tag exists, appends (seeded from the block's
//      ATTDEF) when it doesn't; undoable; no-op safe.
//    • `addBlockAttributeDef` / `updateBlockAttributeDef` / `removeBlockAttributeDef`
//      — CRUD a block's ATTDEF *templates* (`Block.attributeDefs`); undoable via
//      `mutateBlocks`; tag-unique; no-op safe.
//    • `syncBlockAttributes` (ATTSYNC) — reconcile every insert of a block to its
//      defs (preserve matching values, add missing-with-default, drop removed), one
//      undo group.
//    • a resolved insert renders the UPDATED ATTRIB text (the resolve seam already
//      emits attribute text; we drive an op then assert the new value shows).
//
//  Uniquely namespaced so it does not collide with the other suites in the shared
//  test target. The op tests mirror `BlockOpsTests` / `BlockFreezeTests`: a seeded
//  `CADDrawing` with NO UndoManager attached for plain state assertions, and a strong
//  manual-grouping `UndoManager` attached + grouped only for the undo/redo tests
//  (a `groupsByEvent = false` UndoManager requires an OPEN group to register undo).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("block attribute ops (set value / def CRUD / ATTSYNC)")
struct BlockAttributeOpsTests {

    // MARK: - Helpers

    /// An UndoManager configured for unit testing (manual grouping).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A drawing seeded with a block (named `block`, declaring `defs`) plus a single
    /// `.insert` of that block carrying `values`. NO UndoManager is attached — plain
    /// state-assertion tests run the op un-attached (no undo registered, no crash);
    /// undo/redo tests attach a strong UndoManager + open a group first.
    private func seeded(
        block name: String = "TB",
        defs: [BlockAttributeDef] = [],
        values: [BlockAttributeValue] = []
    ) -> (CADDrawing, EntityID) {
        let d = CADDrawing()
        d.addBlock(Block(name: name, attributeDefs: defs))
        let insertID = d.add(EntityRecord(id: .placeholder,
            kind: .insert(InsertData(blockName: name, insertionPoint: Vector(0, 0),
                                     attributes: values))))
        return (d, insertID)
    }

    /// The InsertData currently stored on entity `id`, or nil.
    private func insertData(_ d: CADDrawing, _ id: EntityID) -> InsertData? {
        guard let rec = d.entity(id), case .insert(let data) = rec.kind else { return nil }
        return data
    }

    // MARK: - setInsertAttributeValue: replace + append

    @Test("setInsertAttributeValue replaces an existing tag's value (in place)")
    func setValueReplacesExisting() throws {
        let (d, id) = seeded(values: [
            BlockAttributeValue(tag: "PARTNO", text: "OLD", position: Vector(2, 3), height: 4),
        ])
        d.setInsertAttributeValue(insertID: id, tag: "PARTNO", text: "NEW")

        let data = try #require(insertData(d, id))
        #expect(data.attributes.count == 1)                  // replaced, not appended
        let v = try #require(data.attributes.first)
        #expect(v.tag == "PARTNO")
        #expect(v.text == "NEW")
        #expect(v.position == Vector(2, 3))                  // placement preserved
        #expect(v.height == 4)
    }

    @Test("setInsertAttributeValue matches tags case-insensitively")
    func setValueCaseInsensitiveTag() throws {
        let (d, id) = seeded(values: [BlockAttributeValue(tag: "PARTNO", text: "OLD")])
        d.setInsertAttributeValue(insertID: id, tag: "partno", text: "NEW")
        let data = try #require(insertData(d, id))
        #expect(data.attributes.count == 1)                  // matched, not appended
        #expect(data.attributes.first?.text == "NEW")
    }

    @Test("setInsertAttributeValue appends a new tag seeded from the block's ATTDEF")
    func setValueAppendsSeededFromDef() throws {
        let (d, id) = seeded(defs: [
            BlockAttributeDef(tag: "REV", prompt: "Revision?", defaultText: "A",
                              position: Vector(5, 9), height: 6, rotation: 1, flags: 1),
        ])
        d.setInsertAttributeValue(insertID: id, tag: "REV", text: "B")

        let data = try #require(insertData(d, id))
        #expect(data.attributes.count == 1)
        let v = try #require(data.attributes.first)
        #expect(v.tag == "REV")
        #expect(v.text == "B")
        #expect(v.position == Vector(5, 9))                  // seeded from the def
        #expect(v.height == 6)
        #expect(v.rotation == 1)
        #expect(v.flags == 1)
    }

    @Test("setInsertAttributeValue appends a plain value when the block declares no def")
    func setValueAppendsPlainWhenNoDef() throws {
        let (d, id) = seeded()                               // no defs, no values
        d.setInsertAttributeValue(insertID: id, tag: "FREE", text: "X")
        let data = try #require(insertData(d, id))
        #expect(data.attributes.count == 1)
        #expect(data.attributes.first?.tag == "FREE")
        #expect(data.attributes.first?.text == "X")
        #expect(data.attributes.first?.position == Vector(0, 0))
    }

    @Test("setInsertAttributeValue is a no-op on a non-insert / absent id")
    func setValueNoOpOnNonInsert() {
        let d = CADDrawing()
        let lineID = d.add(EntityRecord(id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))))
        d.setInsertAttributeValue(insertID: lineID, tag: "T", text: "X")
        if case .insert = d.entity(lineID)?.kind { Issue.record("line became an insert") }
        d.setInsertAttributeValue(insertID: EntityID(99999), tag: "T", text: "X")  // absent id
    }

    @Test("setInsertAttributeValue is undoable (replace reverts to the prior value)")
    func setValueUndoable() throws {
        let (d, id) = seeded(values: [BlockAttributeValue(tag: "PARTNO", text: "OLD")])
        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        d.setInsertAttributeValue(insertID: id, tag: "PARTNO", text: "NEW")
        um.endUndoGrouping()
        #expect(insertData(d, id)?.attributes.first?.text == "NEW")

        um.undo()
        #expect(insertData(d, id)?.attributes.first?.text == "OLD")
        um.redo()
        #expect(insertData(d, id)?.attributes.first?.text == "NEW")
    }

    @Test("setInsertAttributeValue to the same value registers no undo")
    func setValueNoOpNoUndo() {
        // A genuine no-op never calls the undo funnel, so with NO group open `canUndo`
        // stays false. (We must not open an empty manual group — an empty group itself
        // makes a `groupsByEvent = false` UndoManager report `canUndo == true`.)
        let (d, id) = seeded(values: [BlockAttributeValue(tag: "PARTNO", text: "SAME")])
        let um = testUndoManager()
        d.undoManager = um
        d.setInsertAttributeValue(insertID: id, tag: "PARTNO", text: "SAME")
        #expect(!um.canUndo)
    }

    // MARK: - Def CRUD (add / update / remove), undoable

    @Test("addBlockAttributeDef appends a def; undoable")
    func addDefUndoable() throws {
        let (d, _) = seeded()
        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        let ok = d.addBlockAttributeDef(block: "TB",
            BlockAttributeDef(tag: "REV", prompt: "Revision?", defaultText: "A"))
        um.endUndoGrouping()
        #expect(ok)
        #expect(d.blocks.block(named: "TB")?.attributeDefs.count == 1)

        um.undo()
        #expect(d.blocks.block(named: "TB")?.attributeDefs.isEmpty == true)
        um.redo()
        #expect(d.blocks.block(named: "TB")?.attributeDefs.first?.tag == "REV")
    }

    @Test("addBlockAttributeDef rejects a duplicate tag (case-insensitive) and unknown block")
    func addDefRejectsDuplicateAndUnknown() {
        let (d, _) = seeded(defs: [BlockAttributeDef(tag: "REV")])
        #expect(!d.addBlockAttributeDef(block: "TB", BlockAttributeDef(tag: "rev")))  // dup
        #expect(d.blocks.block(named: "TB")?.attributeDefs.count == 1)
        #expect(!d.addBlockAttributeDef(block: "NOPE", BlockAttributeDef(tag: "X")))  // unknown
    }

    @Test("updateBlockAttributeDef edits a def in place (matched by tag); undoable")
    func updateDefUndoable() throws {
        let (d, _) = seeded(defs: [BlockAttributeDef(tag: "REV", prompt: "old", defaultText: "A")])
        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        let ok = d.updateBlockAttributeDef(block: "TB",
            BlockAttributeDef(tag: "REV", prompt: "new prompt", defaultText: "Z", flags: 2))
        um.endUndoGrouping()
        #expect(ok)
        let def = try #require(d.blocks.block(named: "TB")?.attributeDefs.first)
        #expect(def.prompt == "new prompt")
        #expect(def.defaultText == "Z")
        #expect(def.flags == 2)

        um.undo()
        #expect(d.blocks.block(named: "TB")?.attributeDefs.first?.prompt == "old")
    }

    @Test("updateBlockAttributeDef is a no-op (no undo) for an unknown tag / unchanged def")
    func updateDefNoOp() {
        let (d, _) = seeded(defs: [BlockAttributeDef(tag: "REV", prompt: "p")])
        let um = testUndoManager()
        d.undoManager = um
        #expect(!d.updateBlockAttributeDef(block: "TB", BlockAttributeDef(tag: "NOPE")))             // unknown tag
        #expect(!d.updateBlockAttributeDef(block: "TB", BlockAttributeDef(tag: "REV", prompt: "p"))) // unchanged
        #expect(!um.canUndo)
    }

    @Test("removeBlockAttributeDef drops the def (case-insensitive); undoable")
    func removeDefUndoable() throws {
        let (d, _) = seeded(defs: [BlockAttributeDef(tag: "PARTNO"), BlockAttributeDef(tag: "REV")])
        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        d.removeBlockAttributeDef(block: "TB", tag: "partno")           // case-insensitive
        um.endUndoGrouping()
        let defs = try #require(d.blocks.block(named: "TB")?.attributeDefs)
        #expect(defs.count == 1)
        #expect(defs.first?.tag == "REV")

        um.undo()
        #expect(d.blocks.block(named: "TB")?.attributeDefs.count == 2)
    }

    @Test("removeBlockAttributeDef is a no-op (no undo) for an absent tag")
    func removeDefNoOp() {
        let (d, _) = seeded(defs: [BlockAttributeDef(tag: "REV")])
        let um = testUndoManager()
        d.undoManager = um
        d.removeBlockAttributeDef(block: "TB", tag: "GONE")
        #expect(!um.canUndo)
        #expect(d.blocks.block(named: "TB")?.attributeDefs.count == 1)
    }

    // MARK: - syncBlockAttributes (ATTSYNC)

    @Test("syncBlockAttributes preserves matching values, adds missing-with-default, drops removed")
    func syncReconciles() throws {
        // Block defs: PARTNO (default TBD) + REV (default A). The insert has a stale
        // PARTNO value + an OBSOLETE tag (OLD) that is no longer defined.
        let (d, id) = seeded(
            defs: [
                BlockAttributeDef(tag: "PARTNO", defaultText: "TBD", position: Vector(1, 1), height: 3),
                BlockAttributeDef(tag: "REV", defaultText: "A", position: Vector(1, 5), height: 3),
            ],
            values: [
                BlockAttributeValue(tag: "PARTNO", text: "A-17", position: Vector(9, 9), height: 99),
                BlockAttributeValue(tag: "OLD", text: "obsolete"),
            ])

        d.syncBlockAttributes(block: "TB")

        let data = try #require(insertData(d, id))
        // Reconciled to exactly the two defs, in def order.
        #expect(data.attributes.map { $0.tag } == ["PARTNO", "REV"])

        let partno = try #require(data.attributes.first { $0.tag == "PARTNO" })
        #expect(partno.text == "A-17")                       // existing value PRESERVED
        #expect(partno.position == Vector(1, 1))             // placement adopts the def
        #expect(partno.height == 3)

        let rev = try #require(data.attributes.first { $0.tag == "REV" })
        #expect(rev.text == "A")                             // missing tag added WITH DEFAULT

        #expect(!data.attributes.contains { $0.tag == "OLD" })   // obsolete tag dropped
    }

    @Test("syncBlockAttributes is undoable as ONE group + a no-op sync registers nothing")
    func syncUndoableAndNoOp() throws {
        let (d, id) = seeded(
            defs: [BlockAttributeDef(tag: "REV", defaultText: "A")],
            values: [])                                       // insert is empty → needs sync
        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        d.syncBlockAttributes(block: "TB")
        um.endUndoGrouping()
        #expect(insertData(d, id)?.attributes.map { $0.tag } == ["REV"])

        um.undo()                                            // one ⌘Z reverts the whole sync
        #expect(insertData(d, id)?.attributes.isEmpty == true)
        um.redo()
        #expect(insertData(d, id)?.attributes.first?.text == "A")

        // A second sync (now already reconciled) is a no-op: no further undo.
        um.removeAllActions()
        d.syncBlockAttributes(block: "TB")
        #expect(!um.canUndo)
    }

    @Test("syncBlockAttributes reconciles EVERY insert of the block")
    func syncReconcilesAllInserts() throws {
        let d = CADDrawing()
        d.addBlock(Block(name: "TB",
            attributeDefs: [BlockAttributeDef(tag: "REV", defaultText: "A")]))
        let id1 = d.add(EntityRecord(id: .placeholder,
            kind: .insert(InsertData(blockName: "TB", insertionPoint: Vector(0, 0)))))
        let id2 = d.add(EntityRecord(id: .placeholder,
            kind: .insert(InsertData(blockName: "tb", insertionPoint: Vector(50, 0)))))  // case-insensitive name

        d.syncBlockAttributes(block: "TB")

        for id in [id1, id2] {
            let data = try #require(insertData(d, id))
            #expect(data.attributes.map { $0.tag } == ["REV"])
            #expect(data.attributes.first?.text == "A")
        }
    }

    // MARK: - Resolve reflects the updated value (end-to-end seam)

    @Test("a resolved insert renders the UPDATED ATTRIB text after setInsertAttributeValue")
    func resolveReflectsUpdatedValue() throws {
        let (d, id) = seeded(defs: [
            BlockAttributeDef(tag: "T", prompt: "Tag?", defaultText: "", height: 5),
        ])
        d.setInsertAttributeValue(insertID: id, tag: "T", text: "VISIBLE")

        let record = try #require(d.entity(id))
        let ctx = ResolveContext(fontProvider: CADFonts.provider, blockProvider: { _ in [] })
        let geo = record.resolve(ctx)
        // The updated value resolved to TEXT geometry (polylines or fills).
        #expect(geo.polylines.count + geo.fills.count > 0)
    }
}
