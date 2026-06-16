//
//  BlockAttributeUIWiringTests.swift
//  CADEngineTests
//
//  STAGE 2 — the UI WIRING for block attributes (block-features §14), tested at the
//  MODEL/STATE layer (never the SwiftUI bodies / no modal — project gotcha):
//
//    • Inspector Attributes VALUE editor (EATTEDIT core): the editor builds an updated
//      `.insert` record and commits it through `CanvasModel.applyInspectorEdits` (the
//      same undoable funnel the dynamic-block picker uses). We drive that funnel with
//      the record-shape the editor produces and assert the value persists, the resolved
//      insert renders it, and ⌘Z reverts it.
//    • ATTDEF authoring panel: the def-editor's `onAdd` / `onUpdate` / `onRemove`
//      closures target the undoable def-CRUD ops on `CanvasModel.drawing`, invoked while
//      a block is being edited (`enterBlockEditing`). We assert each op changes the
//      editing block's `attributeDefs` and is undoable.
//    • `AttributeFlag` (the DXF code-70 bit helper the editors use for invisible/constant).
//
//  `CanvasModel` + `BlockAttributesEditor`/`AttributeFlag` live in the app target — reached
//  here via the `_SharedCanvasModel.swift` / `_SharedBlockAttributesEditor.swift` symlinks
//  (the suite is `@MainActor`, mirroring `BlockUIWiringTests`).
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
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
@Suite("block attribute UI wiring (value editor / ATTDEF authoring / flags)")
struct BlockAttributeUIWiringTests {

    // MARK: - Helpers

    /// A model with a block "TB" (one line member + the given ATTDEFs) and a single
    /// `.insert` of it carrying `values`. Returns the model + the insert's id.
    private func seededModel(
        defs: [BlockAttributeDef] = [],
        values: [BlockAttributeValue] = []
    ) -> (CanvasModel, EntityID) {
        let drawing = CADDrawing()
        let memberID = drawing.add(EntityRecord(id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        drawing.addBlock(Block(name: "TB", basePoint: Vector(0, 0),
                               entityIDs: [memberID], attributeDefs: defs))
        let insertID = drawing.add(EntityRecord(id: .placeholder,
            kind: .insert(InsertData(blockName: "TB", insertionPoint: Vector(0, 0),
                                     attributes: values))))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        return (model, insertID)
    }

    /// The InsertData currently stored on entity `id`, or nil.
    private func insertData(_ m: CanvasModel, _ id: EntityID) -> InsertData? {
        guard let rec = m.drawing.entity(id), case .insert(let data) = rec.kind else { return nil }
        return data
    }

    /// Builds the updated `.insert` record exactly as `BlockAttributeValuesEditor.commit`
    /// does (replace in place by tag, else append seeded from the def), then commits it
    /// through `applyInspectorEdits` — the editor's `onCommit`. Returns the new record.
    @discardableResult
    private func editorCommitValue(_ m: CanvasModel, _ id: EntityID,
                                   defs: [BlockAttributeDef], tag: String, text: String) -> EntityRecord? {
        guard let record = m.drawing.entity(id), case .insert(var data) = record.kind else { return nil }
        if let idx = data.attributes.firstIndex(where: {
            $0.tag.caseInsensitiveCompare(tag) == .orderedSame
        }) {
            data.attributes[idx].text = text
        } else {
            let def = defs.first { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }
            data.attributes.append(BlockAttributeValue(
                tag: def?.tag ?? tag, text: text,
                position: def?.position ?? Vector(0, 0),
                height: def?.height ?? 2.5,
                rotation: def?.rotation ?? 0,
                flags: def?.flags ?? 0))
        }
        var updated = record
        updated.kind = .insert(data)
        m.applyInspectorEdits([updated])
        return updated
    }

    // MARK: - Inspector Attributes VALUE editor (EATTEDIT core)

    @Test("editor value commit replaces an existing tag through applyInspectorEdits")
    func valueEditorReplacesExisting() throws {
        let defs = [BlockAttributeDef(tag: "PARTNO", prompt: "Part?", defaultText: "TBD")]
        let (m, id) = seededModel(defs: defs,
            values: [BlockAttributeValue(tag: "PARTNO", text: "OLD")])
        editorCommitValue(m, id, defs: defs, tag: "PARTNO", text: "NEW")

        let data = try #require(insertData(m, id))
        #expect(data.attributes.count == 1)                  // replaced, not appended
        #expect(data.attributes.first?.text == "NEW")
    }

    @Test("editor value commit appends a new tag seeded from the block's ATTDEF")
    func valueEditorAppendsSeeded() throws {
        let defs = [BlockAttributeDef(tag: "REV", prompt: "Rev?", defaultText: "A",
                                      position: Vector(5, 9), height: 6)]
        let (m, id) = seededModel(defs: defs)               // insert has no values yet
        editorCommitValue(m, id, defs: defs, tag: "REV", text: "B")

        let data = try #require(insertData(m, id))
        let v = try #require(data.attributes.first { $0.tag == "REV" })
        #expect(v.text == "B")
        #expect(v.position == Vector(5, 9))                  // seeded from the def
        #expect(v.height == 6)
    }

    @Test("a committed attribute value is undoable (⌘Z reverts it)")
    func valueEditorUndoable() throws {
        let defs = [BlockAttributeDef(tag: "PARTNO", defaultText: "TBD")]
        let (m, id) = seededModel(defs: defs,
            values: [BlockAttributeValue(tag: "PARTNO", text: "OLD")])
        editorCommitValue(m, id, defs: defs, tag: "PARTNO", text: "NEW")
        #expect(insertData(m, id)?.attributes.first?.text == "NEW")

        #expect(m.canUndo)
        m.undo()
        #expect(insertData(m, id)?.attributes.first?.text == "OLD")
    }

    @Test("a resolved insert renders the value committed via the editor funnel")
    func valueEditorRendersInResolve() throws {
        let defs = [BlockAttributeDef(tag: "T", defaultText: "", height: 5)]
        let (m, id) = seededModel(defs: defs)
        editorCommitValue(m, id, defs: defs, tag: "T", text: "VISIBLE")

        let record = try #require(m.drawing.entity(id))
        let ctx = ResolveContext(fontProvider: CADFonts.provider,
                                 blockProvider: { _ in [] })
        let geo = record.resolve(ctx)
        #expect(geo.polylines.count + geo.fills.count > 0)   // the value produced text geometry
    }

    // MARK: - ATTDEF authoring panel (the def-editor closures' targets)

    @Test("def-editor onAdd targets addBlockAttributeDef on the editing block")
    func defEditorAddTarget() throws {
        let (m, _) = seededModel()
        #expect(m.enterBlockEditing(name: "TB"))
        let blockName = try #require(m.editingBlock)

        // The panel's `onAdd` closure → drawing.addBlockAttributeDef(block:_:). (The closure
        // also bumps `modelVersion` via the inspector's `requestRedraw`, so the session
        // retains the def on Save&Close; the standalone op + its undoability are covered by
        // `BlockAttributeOpsTests` STAGE 1, so this test asserts the wiring TARGET only.)
        let ok = m.drawing.addBlockAttributeDef(block: blockName,
            BlockAttributeDef(tag: "REV", prompt: "Revision?", defaultText: "A"))
        #expect(ok)
        #expect(m.drawing.blocks.block(named: "TB")?.attributeDefs.first?.tag == "REV")

        // Rejects a duplicate tag (the op's contract the panel relies on).
        #expect(!m.drawing.addBlockAttributeDef(block: blockName, BlockAttributeDef(tag: "rev")))
        #expect(m.drawing.blocks.block(named: "TB")?.attributeDefs.count == 1)

        #expect(m.exitBlockEditing(save: true))   // close the session group (hygiene)
    }

    @Test("def-editor onUpdate + onRemove target the CRUD ops on the editing block")
    func defEditorUpdateRemoveTargets() throws {
        let (m, _) = seededModel(defs: [
            BlockAttributeDef(tag: "REV", prompt: "old", defaultText: "A"),
        ])
        #expect(m.enterBlockEditing(name: "TB"))
        let blockName = try #require(m.editingBlock)

        // onUpdate → drawing.updateBlockAttributeDef.
        #expect(m.drawing.updateBlockAttributeDef(block: blockName,
            BlockAttributeDef(tag: "REV", prompt: "new", defaultText: "Z")))
        #expect(m.drawing.blocks.block(named: "TB")?.attributeDefs.first?.prompt == "new")

        // onRemove → drawing.removeBlockAttributeDef.
        m.drawing.removeBlockAttributeDef(block: blockName, tag: "REV")
        #expect(m.drawing.blocks.block(named: "TB")?.attributeDefs.isEmpty == true)

        #expect(m.exitBlockEditing(save: true))   // close the session group (hygiene)
    }

    @Test("isEditingBlock gates the ATTDEF authoring panel (editingBlock identifies the target)")
    func attdefPanelGate() {
        let (m, _) = seededModel()
        #expect(m.isEditingBlock == false)          // panel hidden in model space
        #expect(m.editingBlock == nil)
        m.enterBlockEditing(name: "TB")
        #expect(m.isEditingBlock)                    // panel shown
        #expect(m.editingBlock == "TB")             // and targets the editing block
    }

    // MARK: - Context-action predicate (canEditSelectedInsertAttributes mirror)

    /// The exact predicate `CADCanvasView.Controller.canEditSelectedInsertAttributes`
    /// uses (the controller is a Metal-view inner class, not symlinkable; the predicate
    /// is pure model state, mirrored here so the "Edit Attributes…" gating is covered).
    private func canEditAttributes(_ m: CanvasModel) -> Bool {
        guard m.selection.ids.count == 1, let id = m.selection.ids.first,
              let record = m.drawing.entity(id), case .insert(let data) = record.kind,
              let block = m.drawing.blocks.block(named: data.blockName)
        else { return false }
        return !block.attributeDefs.isEmpty
    }

    @Test("Edit Attributes… is offered only for a single attributed insert")
    func contextActionGating() {
        // Attributed insert selected → offered.
        let (m, id) = seededModel(defs: [BlockAttributeDef(tag: "REV")])
        m.selection = Selection(ids: [id])
        #expect(canEditAttributes(m))

        // No defs → not offered.
        let (m2, id2) = seededModel()
        m2.selection = Selection(ids: [id2])
        #expect(!canEditAttributes(m2))

        // No selection → not offered.
        let (m3, _) = seededModel(defs: [BlockAttributeDef(tag: "REV")])
        m3.selection.clear()
        #expect(!canEditAttributes(m3))
    }

    // MARK: - AttributeFlag bit helper

    @Test("AttributeFlag reads + composes the DXF code-70 bits")
    func attributeFlagBits() {
        #expect(AttributeFlag.isSet(AttributeFlag.invisible, in: 1))
        #expect(AttributeFlag.isSet(AttributeFlag.constant, in: 2))
        #expect(!AttributeFlag.isSet(AttributeFlag.invisible, in: 2))

        // Set invisible on, leaving other bits intact.
        let withVerify = AttributeFlag.verify                     // 4
        let composed = AttributeFlag.set(AttributeFlag.invisible, true, in: withVerify)
        #expect(composed == (AttributeFlag.verify | AttributeFlag.invisible))   // 5

        // Clear invisible from a composed value.
        let cleared = AttributeFlag.set(AttributeFlag.invisible, false, in: composed)
        #expect(cleared == AttributeFlag.verify)                  // back to 4
    }
}
