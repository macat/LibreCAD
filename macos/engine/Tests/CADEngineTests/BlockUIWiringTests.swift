//
//  BlockUIWiringTests.swift
//  CADEngineTests
//
//  WAVE BW — the BLOCK UI wire-wave (Asks #1 create / #2 edit / #3 reinsert). Tests the
//  PURE, headless-safe wiring logic the View layer drives — NEVER the SwiftUI sheet
//  bodies or anything that presents a modal (the headless-hang rule):
//
//   • Ask #1 (Create Block from Selection): `CanvasModel.beginCreateBlock(name:)` arms a
//     `CreateBlockTool` carrying the chosen name — verified END-TO-END by driving the
//     base-point pick and asserting the new block (and its replacing INSERT) carries that
//     name. Gated on a non-empty selection. `suggestedBlockName()` yields a unique
//     `Block-N`. `BlockNamePrompt.Validation.classify` (the sheet's pure validator) flags
//     empty / new / redefine (spec §20) without presenting the sheet.
//   • Ask #2 (Block Editor): `blockNameOfInsert(at:)` resolves an `.insert` under a world
//     point to its block name (the double-click hit-test core); `BlockEditBar` visibility
//     tracks `isEditingBlock`; a programmatic enter→edit→Save&Close updates a resolved
//     insert and Discard reverts (the CanvasModel session paths).
//   • Ask #3 (Reinsert): `beginInsert(name:)` arms an `InsertTool` for an existing block
//     (and is inert / false for an unknown block).
//
//  `CanvasModel` + `BlockNamePrompt` live in the (un-importable) app target — reached here
//  via the existing `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `BlockEditSessionTests`). `BlockEditBar`/`BlockNamePrompt` SwiftUI bodies are NOT
//  rendered here — only `BlockNamePrompt.Validation` (a pure value enum) is exercised.
//
//  Uniquely namespaced (`@Suite("block UI wiring ...")`) so it does not collide with the
//  other suites in the shared test target.
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
@Suite("block UI wiring (WAVE BW: create / edit / reinsert)")
struct BlockUIWiringTests {

    // MARK: - Helpers

    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    private func lineEnds(_ rec: EntityRecord?) -> (Vector, Vector)? {
        guard let rec, case .line(let l) = rec.kind else { return nil }
        return (l.start, l.end)
    }

    private func resolvedPoints(_ rec: EntityRecord, _ d: CADDrawing) -> [Vector] {
        rec.resolve(d.makeResolveContext()).polylines.flatMap { $0.points }
    }

    private func contains(_ pts: [Vector], _ p: Vector, tol: Double = 1e-9) -> Bool {
        pts.contains { ($0 - p).magnitude < tol }
    }

    /// A model with TWO loose lines selected (no block yet) — the starting state for the
    /// create-from-selection flow. The undo manager is the testing (manual-grouping) one
    /// with a clean stack.
    private func looseSelectionModel() -> (model: CanvasModel, ids: [EntityID]) {
        let drawing = CADDrawing()
        let a = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(line(Vector(10, 0), Vector(10, 10)))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        model.selection = Selection(ids: [a, b])
        return (model, [a, b])
    }

    /// A model with one block "WIDGET" (a single member line at the local origin) plus one
    /// insert of it at `insertAt`. Returns the model + member + insert ids.
    private func seededBlockModel(
        member: (Vector, Vector) = (Vector(0, 0), Vector(10, 0)),
        insertAt: Vector = Vector(20, 20)
    ) -> (model: CanvasModel, memberID: EntityID, insertID: EntityID) {
        let drawing = CADDrawing()
        let mID = drawing.add(line(member.0, member.1))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [mID])) }
        let iID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: insertAt))))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, mID, iID)
    }

    // MARK: - Ask #1: beginCreateBlock arms a named CreateBlockTool (end-to-end)

    @Test("beginCreateBlock(name:) → base-point pick creates a block of THAT name + an insert")
    func beginCreateBlockUsesGivenName() {
        let (m, ids) = looseSelectionModel()
        #expect(m.hasSelection)

        // The View-layer name sheet confirmed "Bracket"; begin the run.
        #expect(m.beginCreateBlock(name: "Bracket") == true)
        #expect(m.activeToolKind == .createBlock)

        // Pick the base point (what the canvas click does) → the out-of-band CreateBlock
        // path folds the selection into the NAMED block and replaces it with one insert.
        _ = m.handleToolInput(.click(Vector(0, 0)))

        // A block named exactly "Bracket" now exists (carrying the chosen name).
        #expect(m.drawing.blocks.contains("Bracket"))
        // The originals were replaced by ONE insert of that block.
        let inserts = m.drawing.entities.filter {
            if case .insert(let d) = $0.kind { return d.blockName == "Bracket" }
            return false
        }
        #expect(inserts.count == 1)
        // The two loose lines are gone (folded into the block definition).
        #expect(m.drawing.entity(ids[0]) == nil || m.drawing.entity(ids[1]) == nil)
    }

    @Test("beginCreateBlock with a blank name falls back to a default (de-duplicated) block")
    func beginCreateBlockBlankNameDefaults() {
        let (m, _) = looseSelectionModel()
        #expect(m.beginCreateBlock(name: "   ") == true)
        _ = m.handleToolInput(.click(Vector(0, 0)))
        // Some block was created (the model op de-dups the default name); the table grew.
        #expect(m.drawing.blocks.blocks.count == 1)
    }

    @Test("beginCreateBlock is a no-op (false) with nothing selected")
    func beginCreateBlockNeedsSelection() {
        let drawing = CADDrawing()
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        #expect(m.hasSelection == false)
        #expect(m.beginCreateBlock(name: "X") == false)
        #expect(m.activeToolKind == .select)   // never armed the tool
    }

    @Test("suggestedBlockName yields a unique Block-N not already in the table")
    func suggestedNameIsUnique() {
        let drawing = CADDrawing()
        drawing.mutateBlocks {
            _ = $0.add(Block(name: "Block-1", entityIDs: []))
            _ = $0.add(Block(name: "Block-2", entityIDs: []))
        }
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        let name = m.suggestedBlockName()
        #expect(!m.drawing.blocks.contains(name))
        #expect(name.hasPrefix("Block-"))
    }

    // MARK: - Ask #1: BlockNamePrompt.Validation (the sheet's PURE validator, no modal)

    @Test("BlockNamePrompt.Validation: empty / new / redefine classification")
    func nameValidationClassifies() {
        let existing = ["Door", "Window"]
        #expect(BlockNamePrompt.Validation.classify(name: "", existingNames: existing) == .empty)
        #expect(BlockNamePrompt.Validation.classify(name: "   ", existingNames: existing) == .empty)
        #expect(BlockNamePrompt.Validation.classify(name: "Stair", existingNames: existing) == .new)
        // Redefine match is case-insensitive + whitespace-trimmed (spec §20).
        #expect(BlockNamePrompt.Validation.classify(name: "door", existingNames: existing) == .redefine)
        #expect(BlockNamePrompt.Validation.classify(name: "  Window  ", existingNames: existing) == .redefine)
    }

    // MARK: - Ask #2: double-click hit-test core (blockNameOfInsert)

    @Test("blockNameOfInsert resolves an insert under a world point to its block name")
    func blockNameOfInsertHits() {
        // Insert placed at (20,20); its single member line spans local (0,0)->(10,0), so a
        // world point ON that resolved segment (e.g. (25,20)) is over the insert.
        let (m, _, _) = seededBlockModel(insertAt: Vector(20, 20))
        #expect(m.blockNameOfInsert(at: Vector(25, 20)) == "WIDGET")
        // Far from any geometry → nil (no block to edit there).
        #expect(m.blockNameOfInsert(at: Vector(500, 500)) == nil)
    }

    @Test("blockNameOfInsert returns nil over a NON-insert entity")
    func blockNameOfInsertIgnoresLoose() {
        let (m, _) = looseSelectionModel()    // two loose lines, no insert
        m.selection.clear()
        // A point on the loose line (0,0)->(10,0) is over a LINE, not an insert → nil.
        #expect(m.blockNameOfInsert(at: Vector(5, 0)) == nil)
    }

    // MARK: - Ask #2: enter → edit → Save & Close updates a resolved insert

    @Test("Enter via the editor → edit a member → Save & Close updates a resolved insert")
    func enterEditSaveCloseUpdatesInsert() {
        let (m, memberID, insertID) = seededBlockModel()
        #expect(m.isEditingBlock == false)

        // The sidebar "Edit" / a double-click both call enterBlockEditing(name:).
        #expect(m.enterBlockEditing(name: "WIDGET") == true)
        #expect(m.isEditingBlock)
        #expect(m.editingBlock == "WIDGET")

        // Edit the member through the same undoable funnel the edit UI uses.
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 5)))
        m.applyInspectorEdits([edited])

        // Save & Close (the BlockEditBar "Save & Close" button).
        #expect(m.exitBlockEditing(save: true) == true)
        #expect(m.isEditingBlock == false)

        // A resolved insert of WIDGET reflects the NEW member geometry (live-member resolve).
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(30, 25)))
        #expect(!contains(pts, Vector(30, 20)))
    }

    @Test("Enter → edit → Discard reverts the member + a resolved insert")
    func enterEditDiscardReverts() {
        let (m, memberID, insertID) = seededBlockModel()
        let canUndoBefore = m.canUndo

        #expect(m.enterBlockEditing(name: "WIDGET") == true)
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(99, 99)))
        m.applyInspectorEdits([edited])

        // Discard (the BlockEditBar "Discard" button).
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.isEditingBlock == false)

        // Geometry + a resolved insert are back to entry state; the undo stack is coherent.
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 0))
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(30, 20)))
        #expect(!contains(pts, Vector(119, 119)))
        #expect(m.canUndo == canUndoBefore)
    }

    // MARK: - Ask #2: BlockEditBar visibility tracks isEditingBlock

    @Test("isEditingBlock (the BlockEditBar visibility gate) tracks enter / exit")
    func editBarVisibilityTracksSession() {
        let (m, _, _) = seededBlockModel()
        // The BlockEditBar renders its chrome iff `model.isEditingBlock`.
        #expect(m.isEditingBlock == false)
        m.enterBlockEditing(name: "WIDGET")
        #expect(m.isEditingBlock == true)
        #expect(m.editingBlock == "WIDGET")   // the bar shows "Editing block: WIDGET"
        m.exitBlockEditing(save: true)
        #expect(m.isEditingBlock == false)
    }

    // MARK: - Ask #2: document-close auto Save & Close (the .onDisappear hook)

    @Test("finishBlockEditingIfNeeded (document-close hook) auto Save&Closes an open session")
    func documentCloseFinishesSession() {
        let (m, memberID, insertID) = seededBlockModel()
        m.enterBlockEditing(name: "WIDGET")
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 7)))
        m.applyInspectorEdits([edited])

        // The View-layer `.onDisappear` calls this on document close.
        #expect(m.finishBlockEditingIfNeeded() == true)
        #expect(m.isEditingBlock == false)
        // The edit was KEPT (auto Save&Close) — a resolved insert shows the new geometry.
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(30, 27)))

        // No open session → the next close is a no-op.
        #expect(m.finishBlockEditingIfNeeded() == false)
    }

    // MARK: - Ask #3: beginInsert arms an InsertTool for an existing block

    @Test("beginInsert(name:) arms the Insert tool for an existing block")
    func beginInsertArmsForExistingBlock() {
        let (m, _, _) = seededBlockModel()
        #expect(m.beginInsert(name: "WIDGET") == true)
        #expect(m.activeToolKind == .insert)
        // Placing the reference works through the armed tool.
        _ = m.handleToolInput(.click(Vector(40, 40)))
        let inserts = m.drawing.entities.filter {
            if case .insert(let d) = $0.kind { return d.blockName == "WIDGET" }
            return false
        }
        // The seed had one insert; placing adds a second.
        #expect(inserts.count == 2)
    }

    @Test("beginInsert is a no-op (false) for an unknown / blank block")
    func beginInsertRejectsUnknown() {
        let (m, _, _) = seededBlockModel()
        #expect(m.beginInsert(name: "GHOST") == false)
        #expect(m.beginInsert(name: "   ") == false)
        #expect(m.activeToolKind == .select)   // never armed for a bad name
    }
}
