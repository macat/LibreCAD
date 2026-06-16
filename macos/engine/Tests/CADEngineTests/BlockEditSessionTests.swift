//
//  BlockEditSessionTests.swift
//  CADEngineTests
//
//  In-place BLOCK EDITING (REFEDIT / BEDIT-style) — the engine + CanvasModel session
//  layer, built UNWIRED (no UI). Covers:
//
//   • `CADDrawing.setBlockMembers(name:ids:)` — an undoable re-point of a block's
//     member-id list, routed through the `mutateBlocks` value-snapshot funnel (one ⌘Z
//     reverts; a no-op / unknown block registers nothing). Pure CADEngine.
//   • The CRUX: block members are SHARED id-refs resolved LIVE, so editing a member
//     record instantly updates every `.insert` — Enter → move a member → Save & Close
//     leaves the block AND a resolved insert at the new geometry.
//   • Discard restores the entry-state members AND a resolved insert to entry geometry,
//     and leaves a COHERENT undo stack (post-Discard `canUndo` matches pre-enter — no
//     stranded half-session steps).
//   • Enter re-scopes `activeSpaceEntities` / the spatial index to the block's members;
//     exit restores the prior space.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the existing
//  `_SharedCanvasModel.swift` symlink. The CanvasModel suite is `@MainActor` (mirrors
//  `PaperSpaceModelTests` / `PaperSpaceLayoutHelperTests`).
//
//  Uniquely namespaced (`@Suite("block edit session ...")`) so it does not collide with
//  the other suites in the shared test target.
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
@Suite("block edit session (setBlockMembers + enter / Save&Close / Discard)")
struct BlockEditSessionTests {

    // MARK: - Helpers

    /// An UndoManager configured for unit testing (manual grouping — matches the other
    /// suites; event-coalescing never fires without a run loop).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A line from `a` to `b` (model space).
    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    /// The world endpoints of a line entity.
    private func lineEnds(_ rec: EntityRecord?) -> (Vector, Vector)? {
        guard let rec, case .line(let l) = rec.kind else { return nil }
        return (l.start, l.end)
    }

    /// All resolved polyline points of a record (for resolve-based geometry checks).
    private func resolvedPoints(_ rec: EntityRecord, _ d: CADDrawing) -> [Vector] {
        rec.resolve(d.makeResolveContext()).polylines.flatMap { $0.points }
    }

    private func contains(_ pts: [Vector], _ p: Vector, tol: Double = 1e-9) -> Bool {
        pts.contains { ($0 - p).magnitude < tol }
    }

    // MARK: - setBlockMembers (pure CADEngine)

    @Test("setBlockMembers re-points the member list and is undoable (one ⌘Z reverts)")
    func setBlockMembersUndoable() {
        // Seed two member lines WITHOUT undo (so the seed adds don't register), then a
        // block referencing only the first member.
        let d = CADDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        let b = d.add(line(Vector(2, 0), Vector(3, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [a])) }

        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.setBlockMembers(name: "B", ids: [a, b])
        um.endUndoGrouping()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a, b])

        um.undo()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a])

        um.redo()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a, b])
    }

    @Test("setBlockMembers is a no-op (no undo) for the same ids or an unknown block")
    func setBlockMembersNoOp() {
        let d = CADDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [a])) }

        let um = testUndoManager()
        d.undoManager = um

        // Same id list → no change → no undo registered.
        d.setBlockMembers(name: "B", ids: [a])
        #expect(um.canUndo == false)

        // Unknown block → no change → no undo registered.
        d.setBlockMembers(name: "NOPE", ids: [a])
        #expect(um.canUndo == false)
        #expect(d.blocks.block(named: "B")?.entityIDs == [a])
    }

    @Test("setBlockMembers immediately changes what an .insert of the block resolves to")
    func setBlockMembersDrivesResolve() {
        // Two candidate members; the block starts referencing the FIRST, an insert
        // placed at the origin. Re-pointing the block at the SECOND member changes the
        // resolved insert geometry on the very next makeResolveContext (the live crux).
        let d = CADDrawing()
        let m1 = d.add(line(Vector(0, 0), Vector(5, 0)))      // along +x
        let m2 = d.add(line(Vector(0, 0), Vector(0, 7)))      // along +y
        d.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [m1])) }
        let insertID = d.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "B", insertionPoint: Vector(0, 0)))))

        let before = resolvedPoints(d.entity(insertID)!, d)
        #expect(contains(before, Vector(5, 0)))
        #expect(!contains(before, Vector(0, 7)))

        d.undoManager = testUndoManager()
        d.setBlockMembers(name: "B", ids: [m2])

        let after = resolvedPoints(d.entity(insertID)!, d)
        #expect(contains(after, Vector(0, 7)))
        #expect(!contains(after, Vector(5, 0)))
    }

    // MARK: - CanvasModel: build a model with a block + an insert

    /// A model holding ONE block "WIDGET" (a single member line authored at the local
    /// origin) plus ONE insert of it placed at `insertAt`. Returns the model + the member
    /// id + the insert id. The undo manager is the testing (manual-grouping) one with a
    /// CLEAN stack (the seeding adds register, so we clear after).
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
        model.undoManager.removeAllActions()   // start the session tests from a clean stack
        return (model, mID, iID)
    }

    /// Like `seededBlockModel`, but also seeds a paper-space `Layout` named `layoutName`
    /// BEFORE the model is built, so the layout add registers no undo (the drawing has no
    /// undo manager yet — matching how the block is seeded). Used by the STAGE 2 tab tests
    /// that need a real Model + Layout set to keep intact across a session.
    private func seededBlockModelWithLayout(
        layoutName: String = "Layout1"
    ) -> (model: CanvasModel, memberID: EntityID, insertID: EntityID) {
        let drawing = CADDrawing()
        let mID = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [mID])) }
        let iID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(20, 20)))))
        _ = drawing.addLayout(Layout(name: layoutName, tabOrder: 0))

        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, mID, iID)
    }

    // MARK: - Enter → move a member → Save & Close

    @Test("Enter → move a member → Save & Close: block member + a resolved insert update")
    func enterMoveSaveClose() {
        let (m, memberID, insertID) = seededBlockModel()
        #expect(m.isEditingBlock == false)

        #expect(m.enterBlockEditing(name: "WIDGET") == true)
        #expect(m.isEditingBlock)
        #expect(m.editingBlock == "WIDGET")

        // Move the member (local (0,0)->(10,0) becomes (0,0)->(10,5)) via the EXISTING
        // undoable inspector funnel — the same path the future block-edit UI uses.
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 5)))
        m.applyInspectorEdits([edited])

        m.exitBlockEditing(save: true)
        #expect(m.isEditingBlock == false)

        // The block's member record carries the new geometry.
        let (_, end) = lineEnds(m.drawing.entity(memberID))!
        #expect(end == Vector(10, 5))

        // A resolved insert of WIDGET (placed at (20,20)) reflects the NEW member: the
        // moved endpoint resolves to (20,20)+(10,5) = (30,25); the old (30,20) is gone.
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(30, 25)))
        #expect(!contains(pts, Vector(30, 20)))

        // One coherent ⌘Z reverts the whole session (member back to the entry geometry).
        m.undo()
        let (_, endAfterUndo) = lineEnds(m.drawing.entity(memberID))!
        #expect(endAfterUndo == Vector(10, 0))
    }

    // MARK: - Enter → edit → Discard

    @Test("Enter → edit → Discard: member + a resolved insert revert; undo stack coherent")
    func enterEditDiscard() {
        let (m, memberID, insertID) = seededBlockModel()

        // Pre-enter undo state (clean stack from the seed).
        let canUndoBefore = m.canUndo
        #expect(canUndoBefore == false)

        #expect(m.enterBlockEditing(name: "WIDGET") == true)

        // Edit the member during the session.
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(99, 99)))
        m.applyInspectorEdits([edited])
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(99, 99))

        // Discard.
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.isEditingBlock == false)

        // Geometry reverted to the ENTRY state (local (0,0)->(10,0)).
        let (start, end) = lineEnds(m.drawing.entity(memberID))!
        #expect(start == Vector(0, 0))
        #expect(end == Vector(10, 0))

        // A resolved insert is back to the ENTRY placement ((20,20)+(10,0) = (30,20)).
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(30, 20)))
        #expect(!contains(pts, Vector(119, 119)))   // the discarded edit is gone

        // The block still references the same single member id (entry id list).
        #expect(m.drawing.blocks.block(named: "WIDGET")?.entityIDs == [memberID])

        // Undo-stack COHERENCE: post-Discard canUndo matches the pre-enter value (the
        // net-identity session group was dropped — no stranded half-session steps).
        #expect(m.canUndo == canUndoBefore)
    }

    @Test("Discard from a clean stack leaves NO pending undo (no half-session residue)")
    func discardLeavesCleanUndoStack() {
        let (m, memberID, _) = seededBlockModel()
        #expect(m.canUndo == false)

        m.enterBlockEditing(name: "WIDGET")
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(1, 1), end: Vector(2, 2)))
        m.applyInspectorEdits([edited])
        // Mid-session there IS pending undo (the open session group + the edit).
        #expect(m.canUndo == true)

        m.exitBlockEditing(save: false)
        // After Discard the stack is back to clean (matches the pre-enter state).
        #expect(m.canUndo == false)
        // And the member is at entry geometry.
        let (s, e) = lineEnds(m.drawing.entity(memberID))!
        #expect(s == Vector(0, 0))
        #expect(e == Vector(10, 0))
    }

    // MARK: - Scope: enter re-scopes the active subset + index; exit restores

    @Test("Enter re-scopes activeSpaceEntities to the block members; exit restores the space")
    func enterRescopesExitRestores() {
        // A drawing with a model line OUTSIDE the block + the block member, so the active
        // subset visibly differs in/out of the session.
        let drawing = CADDrawing()
        let outsider = drawing.add(line(Vector(-50, -50), Vector(-40, -50)))   // not in block
        let memberID = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [memberID])) }
        let insertID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(20, 20)))))

        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()

        // Model space sees the outsider, the member, and the insert (all model space).
        #expect(m.activeSpace == .model)
        let modelIDs = Set(m.activeSpaceEntities.map(\.id))
        #expect(modelIDs.contains(outsider))
        #expect(modelIDs.contains(insertID))

        // Enter the block: the active subset is exactly the block's members, and the
        // index is scoped to them (the member is in the quadtree; the outsider is not).
        m.enterBlockEditing(name: "WIDGET")
        #expect(m.activeSpaceEntities.map(\.id) == [memberID])
        #expect(m.editingBlockEntities.map(\.id) == [memberID])
        let memberBox = m.drawing.entity(memberID)!.boundingBox()
        let scopedHits = m.quadtree.query(region: memberBox)
        #expect(scopedHits.contains(memberID))
        #expect(!scopedHits.contains(outsider))

        // Exit (save) → the active subset is the model space again (outsider back).
        m.exitBlockEditing(save: true)
        #expect(m.activeSpace == .model)
        #expect(m.isEditingBlock == false)
        let backIDs = Set(m.activeSpaceEntities.map(\.id))
        #expect(backIDs.contains(outsider))
        #expect(backIDs.contains(insertID))
    }

    // MARK: - Guards / lifecycle

    @Test("enterBlockEditing is a no-op for an unknown block / when already editing")
    func enterGuards() {
        let (m, _, _) = seededBlockModel()
        #expect(m.enterBlockEditing(name: "GHOST") == false)
        #expect(m.isEditingBlock == false)

        #expect(m.enterBlockEditing(name: "WIDGET") == true)
        // A second enter while a session is open is rejected (keeps the group + snapshot
        // coherent — re-entry must go through exit first).
        #expect(m.enterBlockEditing(name: "WIDGET") == false)
        #expect(m.editingBlock == "WIDGET")
        m.exitBlockEditing(save: true)   // balance the open group
    }

    @Test("exitBlockEditing returns false when no session is active")
    func exitWithoutSession() {
        let (m, _, _) = seededBlockModel()
        #expect(m.exitBlockEditing(save: true) == false)
        #expect(m.exitBlockEditing(save: false) == false)
    }

    @Test("finishBlockEditingIfNeeded auto-Save&Closes an open session (else no-op)")
    func finishIfNeededAutoSaves() {
        let (m, memberID, _) = seededBlockModel()
        // No session → no-op.
        #expect(m.finishBlockEditingIfNeeded() == false)

        // Open + edit, then the document-close guard auto-saves (edits are kept).
        m.enterBlockEditing(name: "WIDGET")
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 8)))
        m.applyInspectorEdits([edited])

        #expect(m.finishBlockEditingIfNeeded() == true)
        #expect(m.isEditingBlock == false)
        // The edit survived (auto Save&Close, not Discard).
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 8))
        // A second call is a no-op (no session open).
        #expect(m.finishBlockEditingIfNeeded() == false)
    }

    // MARK: - Discard preserves a PRIOR committed undo step (the realistic in-app case)

    @Test("Discard with a prior committed step on the stack preserves that step")
    func discardPreservesPriorUndoStep() {
        let (m, memberID, _) = seededBlockModel()

        // A REAL committed edit BEFORE entering the block (the prior undo step). Move the
        // member to (10,3) outside any session, as a normal document edit.
        var pre = m.drawing.entity(memberID)!
        pre.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 3)))
        m.applyInspectorEdits([pre])
        #expect(m.canUndo == true)                                   // prior step on stack
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 3))

        // Enter, edit, Discard.
        m.enterBlockEditing(name: "WIDGET")
        var inSession = m.drawing.entity(memberID)!
        inSession.kind = .line(LineData(start: Vector(0, 0), end: Vector(50, 50)))
        m.applyInspectorEdits([inSession])
        m.exitBlockEditing(save: false)

        // Geometry reverted to the SESSION-ENTRY state (which is the prior edit's (10,3),
        // NOT the seed's (10,0)).
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 3))

        // The prior step is STILL undoable (not clobbered by the session group drop) and
        // undoing it reverts to the seed geometry — the prior edit's own pre-state.
        #expect(m.canUndo == true)
        m.undo()
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 0))
    }

    // MARK: - A no-edit session never strands a no-op undo step (SHOULD-FIX)

    @Test("Save & Close with NO edits drops its empty group (no stranded no-op ⌘Z)")
    func emptySaveCloseLeavesNoUndo() {
        let (m, _, _) = seededBlockModel()
        #expect(m.canUndo == false)

        // Enter and immediately Save & Close without touching anything.
        m.enterBlockEditing(name: "WIDGET")
        m.exitBlockEditing(save: true)

        // The empty session group must NOT be left on the stack.
        #expect(m.canUndo == false)
    }

    @Test("an empty no-edit Save & Close does not consume a prior real undo step")
    func emptySaveCloseKeepsPriorStep() {
        let (m, memberID, _) = seededBlockModel()
        // A prior committed edit.
        var pre = m.drawing.entity(memberID)!
        pre.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 4)))
        m.applyInspectorEdits([pre])
        #expect(m.canUndo == true)

        // A no-edit session (enter → Save&Close) must leave the prior step intact and the
        // next ⌘Z must undo the PRIOR edit (not a stranded no-op session step).
        m.enterBlockEditing(name: "WIDGET")
        m.exitBlockEditing(save: true)
        #expect(m.canUndo == true)
        m.undo()
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 0))   // prior edit reverted
    }

    @Test("Discard with NO edits also drops its empty group (clean stack stays clean)")
    func emptyDiscardLeavesNoUndo() {
        let (m, _, _) = seededBlockModel()
        #expect(m.canUndo == false)
        m.enterBlockEditing(name: "WIDGET")
        m.exitBlockEditing(save: false)
        #expect(m.canUndo == false)
    }

    // MARK: - STAGE 1 — every edit in the editor mutates the BLOCK (not the document)
    //
    // The owner's #1 complaint: drawing in the Block Editor used to add LOOSE document
    // objects, not block members. These pin the fix: an `.add` (draw), a paste/duplicate,
    // and a `.remove` (delete) made WHILE a session is open route into the editing block's
    // `entityIDs` — excluded from model space (`blockMemberIDs`), drawn via inserts — and
    // a Discard reverts an added member from BOTH `entities` and `entityIDs`.

    /// Engine-level membership/undo of the two new `CADDrawing` seams (no CanvasModel).
    @Test("addEntityToBlock / removeEntityFromBlock mutate membership and are undoable")
    func addRemoveEntityToBlockUndoable() {
        let d = CADDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        let b = d.add(line(Vector(2, 0), Vector(3, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [a])) }

        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.addEntityToBlock(name: "B", entityID: b)
        um.endUndoGrouping()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a, b])
        // The new id is now a block member → excluded from model space.
        #expect(d.blockMemberIDs.contains(b))

        um.undo()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a])

        um.redo()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a, b])

        // Remove the second member (undoable).
        um.beginUndoGrouping()
        d.removeEntityFromBlock(name: "B", entityID: b)
        um.endUndoGrouping()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a])
        um.undo()
        #expect(d.blocks.block(named: "B")?.entityIDs == [a, b])

        // A duplicate id / unknown block registers nothing.
        let um2 = testUndoManager()
        d.undoManager = um2
        d.addEntityToBlock(name: "B", entityID: a)        // already a member
        #expect(um2.canUndo == false)
        d.addEntityToBlock(name: "NOPE", entityID: a)     // unknown block
        #expect(um2.canUndo == false)
    }

    @Test("Draw in the editor → new entity is a BLOCK MEMBER, not a loose document object")
    func drawInEditorAddsBlockMember() {
        let (m, memberID, insertID) = seededBlockModel()

        #expect(m.enterBlockEditing(name: "WIDGET") == true)
        // Draw a NEW line via the public tool-edit funnel (what the inline tools commit
        // through). A vertical segment from local (0,0) to (0,10).
        let memberCountBefore = m.drawing.blocks.block(named: "WIDGET")!.entityIDs.count
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(0, 10)))])

        // The block grew by exactly one member; find the freshly-minted id.
        let idsAfter = m.drawing.blocks.block(named: "WIDGET")!.entityIDs
        #expect(idsAfter.count == memberCountBefore + 1)
        let newID = idsAfter.last!
        #expect(newID != memberID)
        // It is a real entity in the drawing AND is recorded as a block member.
        #expect(m.drawing.entity(newID) != nil)
        #expect(m.drawing.blockMemberIDs.contains(newID))

        m.exitBlockEditing(save: true)

        // It did NOT leak as a loose model-space object: after exit (back in model space)
        // the active subset excludes the new member (it is block-only).
        let modelIDs = Set(m.activeSpaceEntities.map(\.id))
        #expect(!modelIDs.contains(newID))
        #expect(modelIDs.contains(insertID))           // the insert is still loose model geo

        // The resolved INSERT now includes the NEW geometry: the insert sits at (20,20),
        // so the new local (0,10) resolves to (20,30).
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(20, 30)))
    }

    @Test("Discard after a draw removes the added entity from BOTH entities and entityIDs")
    func discardAfterDrawRevertsAddedMember() {
        let (m, _, _) = seededBlockModel()
        #expect(m.canUndo == false)

        m.enterBlockEditing(name: "WIDGET")
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(0, 10)))])
        let newID = m.drawing.blocks.block(named: "WIDGET")!.entityIDs.last!
        #expect(m.drawing.entity(newID) != nil)        // present mid-session

        m.exitBlockEditing(save: false)                // Discard

        // The added member is gone from BOTH the entity store and the block's id list.
        #expect(m.drawing.entity(newID) == nil)
        #expect(m.drawing.blocks.block(named: "WIDGET")!.entityIDs.contains(newID) == false)
        // The block is back to exactly its entry member.
        #expect(m.drawing.blocks.block(named: "WIDGET")?.entityIDs.count == 1)
        // Undo stack coherent (Discard dropped its net-identity group).
        #expect(m.canUndo == false)
    }

    @Test("Paste/duplicate in the editor joins the BLOCK, not the document")
    func duplicateInEditorJoinsBlock() {
        let (m, memberID, insertID) = seededBlockModel()

        m.enterBlockEditing(name: "WIDGET")
        // Select the member and duplicate it in place (the ⌘D funnel). The duplicate must
        // join the block's members — not leak to the document.
        m.selection = Selection(ids: [memberID])
        #expect(m.duplicateSelection(offset: Vector(0, 5)) == true)

        let idsAfter = m.drawing.blocks.block(named: "WIDGET")!.entityIDs
        #expect(idsAfter.count == 2)
        let dupID = idsAfter.first { $0 != memberID }!
        #expect(m.drawing.blockMemberIDs.contains(dupID))

        m.exitBlockEditing(save: true)
        // Not a loose model-space object after exit.
        let modelIDs = Set(m.activeSpaceEntities.map(\.id))
        #expect(!modelIDs.contains(dupID))
        // The resolved insert now shows the duplicate's geometry (member (0,0)->(10,0)
        // duplicated by (0,5) → (0,5)->(10,5); at the insert (20,20) → (20,25)->(30,25)).
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(30, 25)))
    }

    @Test("Delete a member in the editor drops its id from the block's entityIDs")
    func deleteMemberInEditorDropsFromBlock() {
        // Seed a block with TWO members so deleting one leaves a non-empty block.
        let drawing = CADDrawing()
        let m1 = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        let m2 = drawing.add(line(Vector(0, 0), Vector(0, 10)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [m1, m2])) }
        let insertID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(20, 20)))))

        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()

        m.enterBlockEditing(name: "WIDGET")
        // Delete the second member through the selection-delete funnel.
        m.selection = Selection(ids: [m2])
        #expect(m.deleteSelection() == true)

        // The block dropped m2 from its member list; m1 remains.
        #expect(m.drawing.blocks.block(named: "WIDGET")?.entityIDs == [m1])
        // The underlying entity is gone too.
        #expect(m.drawing.entity(m2) == nil)

        m.exitBlockEditing(save: true)
        // The resolved insert no longer carries the deleted member's geometry (the
        // vertical (0,10) local → (20,30) world is gone); the kept member still resolves.
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(!contains(pts, Vector(20, 30)))
        #expect(contains(pts, Vector(30, 20)))         // m1 → (20,20)+(10,0)

        // One ⌘Z restores the deleted member to the block.
        m.undo()
        #expect(m.drawing.blocks.block(named: "WIDGET")?.entityIDs.contains(m2) == true)
        #expect(m.drawing.entity(m2) != nil)
    }

    // MARK: - STAGE 2 — the Block Editor is its OWN tab (BEDIT)
    //
    // The tab strip (`LayoutTabStrip`) is presentational: each tab's active-ness is a
    // pure predicate over the live model. These mirror those predicates EXACTLY and pin
    // the STAGE 2 behavior without rendering a SwiftUI body (project gotcha: no view
    // rendering / no modal in headless tests).

    /// Mirror of `LayoutTabStrip.modelTab` active predicate.
    private func modelTabActive(_ m: CanvasModel) -> Bool {
        m.editingBlock == nil && m.activeSpace == .model
    }
    /// Mirror of `LayoutTabStrip.layoutTab` active predicate.
    private func layoutTabActive(_ m: CanvasModel, _ name: String) -> Bool {
        m.editingBlock == nil
            && m.activeSpace == .paper
            && (m.activeLayout?.caseInsensitiveCompare(name) == .orderedSame)
    }
    /// Mirror of `LayoutTabStrip.blockEditTab` presence/active predicate (it is present
    /// AND active exactly when a session is open).
    private func blockEditTabActive(_ m: CanvasModel) -> Bool {
        !m.editingBlockStack.isEmpty
    }

    @Test("Entering shows a distinct block-edit tab; Model/Layout tabs stay present")
    func enteringShowsBlockEditTab() {
        let (m, _, _) = seededBlockModelWithLayout()
        let layoutsBefore = m.orderedLayouts.map(\.name)
        #expect(layoutsBefore == ["Layout1"])
        #expect(m.editingBlockStack.isEmpty)        // no block-edit tab yet

        m.enterBlockEditing(name: "WIDGET")
        // The block-edit tab now exists and is labeled with the block name.
        #expect(m.editingBlockStack == ["WIDGET"])
        #expect(m.editingBlock == "WIDGET")
        // The document tabs are NOT replaced — Model + the layout are still there.
        #expect(m.orderedLayouts.map(\.name) == layoutsBefore)

        m.exitBlockEditing(save: true)
        #expect(m.editingBlockStack.isEmpty)        // tab gone after close
        #expect(m.orderedLayouts.map(\.name) == layoutsBefore)
    }

    @Test("Exactly ONE tab reads active during a block-edit session")
    func exactlyOneActiveTabDuringSession() {
        let (m, _, _) = seededBlockModelWithLayout()

        // Before: Model active, no block-edit tab.
        #expect(modelTabActive(m) == true)
        #expect(layoutTabActive(m, "Layout1") == false)
        #expect(blockEditTabActive(m) == false)

        m.enterBlockEditing(name: "WIDGET")
        // During: the block-edit tab is the ONLY active one — even though enter does
        // NOT change activeSpace (it stays .model), the editingBlock gate suppresses it.
        #expect(modelTabActive(m) == false)
        #expect(layoutTabActive(m, "Layout1") == false)
        #expect(blockEditTabActive(m) == true)
        #expect(m.activeSpace == .model)            // confirms the gate, not a space change

        m.exitBlockEditing(save: true)
        // After: back to exactly Model active.
        #expect(modelTabActive(m) == true)
        #expect(blockEditTabActive(m) == false)
    }

    @Test("Switch to Model mid-edit → session auto-Save&Closes and the pick sticks")
    func switchToModelMidEditAutoFinishes() {
        let (m, memberID, _) = seededBlockModel()
        m.enterBlockEditing(name: "WIDGET")
        // Make an edit so it's a real (non-empty) session.
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 6)))
        m.applyInspectorEdits([edited])
        #expect(blockEditTabActive(m) == true)

        // The user picks the Model tab mid-edit → the strip calls activateModel().
        m.activateModel()
        // The session auto-finished (Save&Close — edits kept) and the Model pick stuck.
        #expect(m.isEditingBlock == false)
        #expect(blockEditTabActive(m) == false)
        #expect(modelTabActive(m) == true)
        #expect(m.activeSpace == .model)
        // The edit survived the auto Save&Close.
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 6))
    }

    @Test("Switch to a Layout mid-edit → session auto-finishes and the layout pick sticks")
    func switchToLayoutMidEditAutoFinishes() {
        let (m, memberID, _) = seededBlockModelWithLayout()
        m.enterBlockEditing(name: "WIDGET")
        var edited = m.drawing.entity(memberID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 7)))
        m.applyInspectorEdits([edited])

        // The user picks a Layout tab mid-edit.
        m.activateLayout(name: "Layout1")
        #expect(m.isEditingBlock == false)
        #expect(blockEditTabActive(m) == false)
        #expect(layoutTabActive(m, "Layout1") == true)     // the layout pick stuck
        #expect(modelTabActive(m) == false)
        #expect(lineEnds(m.drawing.entity(memberID))!.1 == Vector(10, 7))   // edit kept
    }

    @Test("Save & Close / Discard closes the block-edit tab and restores the prior tab")
    func saveCloseDiscardRestorePriorTab() {
        let (m1, _, _) = seededBlockModel()
        // Start on Model, enter, Save&Close → back to Model.
        #expect(modelTabActive(m1) == true)
        m1.enterBlockEditing(name: "WIDGET")
        #expect(blockEditTabActive(m1) == true)
        m1.exitBlockEditing(save: true)
        #expect(blockEditTabActive(m1) == false)
        #expect(modelTabActive(m1) == true)

        // Discard from a layout: enter from a layout context, Discard → back to layout.
        let (m2, _, _) = seededBlockModelWithLayout()
        m2.activateLayout(name: "Layout1")
        #expect(layoutTabActive(m2, "Layout1") == true)
        m2.enterBlockEditing(name: "WIDGET")
        #expect(blockEditTabActive(m2) == true)
        #expect(layoutTabActive(m2, "Layout1") == false)   // suppressed during session
        m2.exitBlockEditing(save: false)
        #expect(blockEditTabActive(m2) == false)
        #expect(layoutTabActive(m2, "Layout1") == true)    // prior tab restored
    }

    @Test("Move a member in the editor updates all inserts (regression)")
    func moveMemberUpdatesInserts() {
        // Two inserts of the same block — moving the member updates BOTH live.
        let drawing = CADDrawing()
        let mID = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [mID])) }
        let i1 = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(20, 20)))))
        let i2 = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(0, 100)))))

        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()

        m.enterBlockEditing(name: "WIDGET")
        var edited = m.drawing.entity(mID)!
        edited.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 5)))
        m.applyInspectorEdits([edited])
        m.exitBlockEditing(save: true)

        let p1 = resolvedPoints(m.drawing.entity(i1)!, m.drawing)
        let p2 = resolvedPoints(m.drawing.entity(i2)!, m.drawing)
        #expect(contains(p1, Vector(30, 25)))          // (20,20)+(10,5)
        #expect(contains(p2, Vector(10, 105)))         // (0,100)+(10,5)
    }

    // MARK: - STAGE 3 — NESTED block editing (push / pop, cyclic-guarded, per-level)
    //
    // Owner decision: support nested block editing now. A block A whose members include an
    // INSERT of block B can be edited; double-clicking that insert pushes a session for B
    // nested inside A. Each level keeps its own entry snapshot + undo group, so a level's
    // Save&Close persists that block (visible in the parent via resolve) and a level's
    // Discard reverts only that level. Cyclic opens (a block already in the stack) are
    // rejected.

    /// Builds a model with TWO blocks:
    ///  - "B": one member line local (0,0)->(2,0).
    ///  - "A": one member line local (0,0)->(20,0) PLUS one INSERT of B at local (5,5).
    /// Plus one top-level INSERT of A at world (100,100). Returns the model + the key ids.
    /// No undo registered during seeding (the drawing has no undo manager yet).
    private func seededNestedModel() -> (
        model: CanvasModel,
        bMemberID: EntityID, aMemberID: EntityID,
        aInnerInsertID: EntityID, topInsertID: EntityID
    ) {
        let drawing = CADDrawing()
        // Block B.
        let bMember = drawing.add(line(Vector(0, 0), Vector(2, 0)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [bMember])) }
        // Block A: a line + an insert of B (B's insert is a MEMBER of A).
        let aMember = drawing.add(line(Vector(0, 0), Vector(20, 0)))
        let aInner = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "B", insertionPoint: Vector(5, 5)))))
        drawing.mutateBlocks { _ = $0.add(Block(name: "A", entityIDs: [aMember, aInner])) }
        // A top-level insert of A.
        let topInsert = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "A", insertionPoint: Vector(100, 100)))))

        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, bMember, aMember, aInner, topInsert)
    }

    @Test("Open A → open nested B → edit B → close B pops to A; B's edits persist + show in A")
    func nestedOpenEditPopPersists() {
        let (m, bMemberID, _, _, topInsertID) = seededNestedModel()

        // Open A (outermost).
        #expect(m.enterBlockEditing(name: "A") == true)
        #expect(m.editingBlockStack == ["A"])
        #expect(m.editingBlock == "A")

        // While editing A, open the nested insert's block B → PUSH a level.
        #expect(m.enterBlockEditing(name: "B") == true)
        #expect(m.editingBlockStack == ["A", "B"])     // breadcrumb A ▸ B
        #expect(m.editingBlock == "B")
        // The scoped subset is now B's members.
        #expect(m.activeSpaceEntities.map(\.id) == [bMemberID])

        // Edit B's member: (0,0)->(2,0) becomes (0,0)->(2,9).
        var editedB = m.drawing.entity(bMemberID)!
        editedB.kind = .line(LineData(start: Vector(0, 0), end: Vector(2, 9)))
        m.applyInspectorEdits([editedB])

        // Close B (Save&Close) → pops to A; we are back editing A.
        #expect(m.exitBlockEditing(save: true) == true)
        #expect(m.editingBlockStack == ["A"])
        #expect(m.editingBlock == "A")

        // B's edit persisted to block B's member.
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 9))

        // Close A.
        #expect(m.exitBlockEditing(save: true) == true)
        #expect(m.isEditingBlock == false)

        // The top-level insert of A resolves to include B's NEW geometry: B's insert sits
        // at A-local (5,5); B's edited endpoint is local (2,9); A's insert is at world
        // (100,100). So the deep-resolved point is (100,100)+(5,5)+(2,9) = (107,114).
        let pts = resolvedPoints(m.drawing.entity(topInsertID)!, m.drawing)
        #expect(contains(pts, Vector(107, 114)))
    }

    @Test("Cyclic nested open is rejected (a block already in the stack)")
    func cyclicNestedOpenRejected() {
        let (m, _, _, _, _) = seededNestedModel()

        m.enterBlockEditing(name: "A")
        // Re-opening A (the same block) while it is in the stack is rejected.
        #expect(m.enterBlockEditing(name: "A") == false)
        #expect(m.editingBlockStack == ["A"])

        // Open B nested, then attempt to open A again from within B → still rejected (A is
        // already an ancestor in the stack → would be infinite).
        #expect(m.enterBlockEditing(name: "B") == true)
        #expect(m.enterBlockEditing(name: "A") == false)
        #expect(m.editingBlockStack == ["A", "B"])

        // Balance the open levels.
        m.exitBlockEditing(save: true)
        m.exitBlockEditing(save: true)
        #expect(m.isEditingBlock == false)
    }

    @Test("Each nested level's Discard reverts only THAT level")
    func nestedPerLevelDiscard() {
        let (m, bMemberID, aMemberID, _, _) = seededNestedModel()

        // Open A, edit A's own member.
        m.enterBlockEditing(name: "A")
        var editedA = m.drawing.entity(aMemberID)!
        editedA.kind = .line(LineData(start: Vector(0, 0), end: Vector(20, 4)))
        m.applyInspectorEdits([editedA])
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 4))

        // Open B nested, edit B's member.
        m.enterBlockEditing(name: "B")
        var editedB = m.drawing.entity(bMemberID)!
        editedB.kind = .line(LineData(start: Vector(0, 0), end: Vector(2, 7)))
        m.applyInspectorEdits([editedB])
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 7))

        // Discard B ONLY → B reverts to entry (2,0); A's edit (20,4) is untouched.
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.editingBlockStack == ["A"])
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 0))   // B reverted
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 4))  // A kept

        // Now Discard A → A reverts to entry (20,0).
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.isEditingBlock == false)
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 0))  // A reverted
    }

    @Test("Drawing in a nested level adds a member to the NESTED block, not the parent")
    func nestedDrawAddsToNestedBlock() {
        let (m, _, _, _, _) = seededNestedModel()
        m.enterBlockEditing(name: "A")
        m.enterBlockEditing(name: "B")          // nested

        let aIDsBefore = m.drawing.blocks.block(named: "A")!.entityIDs
        let bCountBefore = m.drawing.blocks.block(named: "B")!.entityIDs.count

        // Draw a new line while editing B (nested).
        m.applyToolEdits([.add(line(Vector(0, 0), Vector(0, 3)))])

        // B grew by one; A is unchanged.
        #expect(m.drawing.blocks.block(named: "B")!.entityIDs.count == bCountBefore + 1)
        #expect(m.drawing.blocks.block(named: "A")!.entityIDs == aIDsBefore)
        let newID = m.drawing.blocks.block(named: "B")!.entityIDs.last!
        #expect(m.drawing.blockMemberIDs.contains(newID))

        m.exitBlockEditing(save: true)          // close B (keep)
        m.exitBlockEditing(save: true)          // close A
        #expect(m.isEditingBlock == false)
        // The new member is in B, not loose model space.
        let modelIDs = Set(m.activeSpaceEntities.map(\.id))
        #expect(!modelIDs.contains(newID))
    }

    @Test("finishBlockEditingIfNeeded auto-saves and pops ALL nested levels")
    func finishPopsAllNestedLevels() {
        let (m, bMemberID, _, _, _) = seededNestedModel()
        m.enterBlockEditing(name: "A")
        m.enterBlockEditing(name: "B")
        var editedB = m.drawing.entity(bMemberID)!
        editedB.kind = .line(LineData(start: Vector(0, 0), end: Vector(2, 6)))
        m.applyInspectorEdits([editedB])
        #expect(m.editingBlockStack == ["A", "B"])

        // A document-close / tab-switch finishes the WHOLE stack (Save&Close each level).
        #expect(m.finishBlockEditingIfNeeded() == true)
        #expect(m.isEditingBlock == false)
        // B's edit was kept (auto Save&Close, not Discard).
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 6))
        // A second call is a no-op.
        #expect(m.finishBlockEditingIfNeeded() == false)
    }

    // MARK: - STAGE 3 regression — nested SAVE must survive an outer DISCARD (finding #1)
    //
    // The data-loss bug the reviewer caught: a nested level that Save&Closes with real
    // edits folds its committed work into the still-open PARENT undo group. A later Discard
    // of the parent used to call `undoManager.undo()` on that whole group — reverting the
    // child's SAVED edits. The fix marks the parent `hasSavedNestedWork` so its Discard
    // keeps the group (the entry-snapshot restore alone fixes the parent block's geometry,
    // and it touches only the parent block's members, never the child's).

    @Test("Save&Close inner B, then Discard outer A: B's SAVED edits PERSIST; A reverts")
    func saveInnerThenDiscardOuterKeepsInnerEdits() {
        let (m, bMemberID, aMemberID, _, topInsertID) = seededNestedModel()

        // Open A, edit A's own member.
        m.enterBlockEditing(name: "A")
        var editedA = m.drawing.entity(aMemberID)!
        editedA.kind = .line(LineData(start: Vector(0, 0), end: Vector(20, 4)))
        m.applyInspectorEdits([editedA])

        // Open B nested, edit B's member, then SAVE&CLOSE B (committed).
        m.enterBlockEditing(name: "B")
        var editedB = m.drawing.entity(bMemberID)!
        editedB.kind = .line(LineData(start: Vector(0, 0), end: Vector(2, 9)))
        m.applyInspectorEdits([editedB])
        #expect(m.exitBlockEditing(save: true) == true)        // SAVE B
        #expect(m.editingBlockStack == ["A"])
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 9))   // saved

        // Now DISCARD A.
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.isEditingBlock == false)

        // CRITICAL: B's SAVED edit must survive — it was committed, not part of A's edit.
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 9))
        // A's own member reverted to its entry geometry (A's edit discarded).
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 0))

        // The top-level insert of A resolves with B's SAVED geometry: (100,100)+(5,5)+(2,9)
        // = (107,114) present; A's discarded (20,4) endpoint at world (120,104) is gone.
        let pts = resolvedPoints(m.drawing.entity(topInsertID)!, m.drawing)
        #expect(contains(pts, Vector(107, 114)))
        #expect(!contains(pts, Vector(120, 104)))
    }

    @Test("Save&Close inner B, then Save&Close outer A: both persist")
    func saveInnerThenSaveOuterBothPersist() {
        let (m, bMemberID, aMemberID, _, topInsertID) = seededNestedModel()
        m.enterBlockEditing(name: "A")
        var editedA = m.drawing.entity(aMemberID)!
        editedA.kind = .line(LineData(start: Vector(0, 0), end: Vector(20, 4)))
        m.applyInspectorEdits([editedA])
        m.enterBlockEditing(name: "B")
        var editedB = m.drawing.entity(bMemberID)!
        editedB.kind = .line(LineData(start: Vector(0, 0), end: Vector(2, 9)))
        m.applyInspectorEdits([editedB])
        m.exitBlockEditing(save: true)        // SAVE B
        m.exitBlockEditing(save: true)        // SAVE A
        #expect(m.isEditingBlock == false)
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 9))   // B kept
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 4))  // A kept
        let pts = resolvedPoints(m.drawing.entity(topInsertID)!, m.drawing)
        #expect(contains(pts, Vector(107, 114)))   // B's saved geo via deep resolve
        #expect(contains(pts, Vector(120, 104)))   // A's saved geo
    }

    @Test("Delete a member then Discard re-adds it (the restore re-add path)")
    func deleteMemberThenDiscardReAdds() {
        // A block with two members; delete one during the session, then Discard — the
        // deleted member must be re-added (restoreBlockEntrySnapshot's replace→add path)
        // and the block's member list restored to its entry.
        let drawing = CADDrawing()
        let m1 = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        let m2 = drawing.add(line(Vector(0, 0), Vector(0, 10)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [m1, m2])) }
        let insertID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(20, 20)))))

        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()

        m.enterBlockEditing(name: "WIDGET")
        m.selection = Selection(ids: [m2])
        #expect(m.deleteSelection() == true)
        #expect(m.drawing.entity(m2) == nil)                       // gone mid-session
        #expect(m.drawing.blocks.block(named: "WIDGET")?.entityIDs == [m1])

        // Discard → the deleted member is re-added and the block restored to entry.
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.drawing.entity(m2) != nil)                       // re-added
        #expect(m.drawing.blocks.block(named: "WIDGET")?.entityIDs == [m1, m2])
        // Its geometry matches the entry record.
        #expect(lineEnds(m.drawing.entity(m2))! == (Vector(0, 0), Vector(0, 10)))

        // The resolved insert again carries the restored member's geometry: (20,20)+(0,10)
        // = (20,30).
        let pts = resolvedPoints(m.drawing.entity(insertID)!, m.drawing)
        #expect(contains(pts, Vector(20, 30)))
    }

    // MARK: - STAGE 3 regression — saved DEEP work survives an intermediate Discard (depth ≥3)
    //
    // The deeper instance of finding #1 (caught on re-review): with A ⊃ insert(B), B ⊃
    // insert(C), the chain Save C → Discard B → Discard A used to silently revert C.
    // Discarding B folds C's committed edits into A's open group, but the prior fix only
    // propagated `hasSavedNestedWork` on a child's SAVE — so A was never marked and its
    // Discard `undo()`-dropped the group containing C's saved work. The propagation now
    // fires on ANY pop carrying saved subtree work (incl. a Discarded intermediate level).

    /// A three-level nested model: block "C" (member local (0,0)->(1,0)); block "B"
    /// (member local (0,0)->(2,0) + an INSERT of C at B-local (3,3)); block "A" (member
    /// local (0,0)->(20,0) + an INSERT of B at A-local (5,5)); plus one top-level INSERT
    /// of A at world (100,100). Returns the model + the three block members + the top
    /// insert. No undo registered during seeding.
    private func seededThreeLevelModel() -> (
        model: CanvasModel,
        cMemberID: EntityID, bMemberID: EntityID, aMemberID: EntityID, topInsertID: EntityID
    ) {
        let drawing = CADDrawing()
        // Block C.
        let cMember = drawing.add(line(Vector(0, 0), Vector(1, 0)))
        drawing.mutateBlocks { _ = $0.add(Block(name: "C", entityIDs: [cMember])) }
        // Block B: a line + an insert of C.
        let bMember = drawing.add(line(Vector(0, 0), Vector(2, 0)))
        let bInner = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "C", insertionPoint: Vector(3, 3)))))
        drawing.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [bMember, bInner])) }
        // Block A: a line + an insert of B.
        let aMember = drawing.add(line(Vector(0, 0), Vector(20, 0)))
        let aInner = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "B", insertionPoint: Vector(5, 5)))))
        drawing.mutateBlocks { _ = $0.add(Block(name: "A", entityIDs: [aMember, aInner])) }
        // A top-level insert of A.
        let topInsert = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "A", insertionPoint: Vector(100, 100)))))

        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, cMember, bMember, aMember, topInsert)
    }

    @Test("Save C → Discard B → Discard A: C's SAVED edits PERSIST (depth-3 data-loss fix)")
    func saveDeepThenDiscardIntermediateThenDiscardOuter() {
        let (m, cMemberID, bMemberID, aMemberID, topInsertID) = seededThreeLevelModel()

        // Open A, B, C.
        m.enterBlockEditing(name: "A")
        m.enterBlockEditing(name: "B")
        m.enterBlockEditing(name: "C")
        #expect(m.editingBlockStack == ["A", "B", "C"])

        // Edit C's member and SAVE&CLOSE C (committed): (0,0)->(1,0) becomes (0,0)->(1,9).
        var editedC = m.drawing.entity(cMemberID)!
        editedC.kind = .line(LineData(start: Vector(0, 0), end: Vector(1, 9)))
        m.applyInspectorEdits([editedC])
        #expect(m.exitBlockEditing(save: true) == true)        // SAVE C
        #expect(m.editingBlockStack == ["A", "B"])
        #expect(lineEnds(m.drawing.entity(cMemberID))!.1 == Vector(1, 9))

        // Discard B (intermediate) — B's own members revert; C stays saved.
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.editingBlockStack == ["A"])
        #expect(lineEnds(m.drawing.entity(cMemberID))!.1 == Vector(1, 9))   // C still saved

        // Discard A (outermost) — must NOT revert C's saved work.
        #expect(m.exitBlockEditing(save: false) == true)
        #expect(m.isEditingBlock == false)

        // CRITICAL: C's SAVED edit survives the whole chain.
        #expect(lineEnds(m.drawing.entity(cMemberID))!.1 == Vector(1, 9))
        // A's own member is at its entry geometry (A made no own edit here).
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 0))
        // B's own member is at its entry geometry (B made no own edit).
        #expect(lineEnds(m.drawing.entity(bMemberID))!.1 == Vector(2, 0))

        // The top insert resolves with C's SAVED geometry deeply: world
        // (100,100)+A-local(5,5)+B-local(3,3)+C-local(1,9) = (109,117).
        let pts = resolvedPoints(m.drawing.entity(topInsertID)!, m.drawing)
        #expect(contains(pts, Vector(109, 117)))
    }

    @Test("Save C → Discard B → Save A: C persists; A kept")
    func saveDeepThenDiscardIntermediateThenSaveOuter() {
        let (m, cMemberID, _, aMemberID, topInsertID) = seededThreeLevelModel()
        m.enterBlockEditing(name: "A")
        // Give A its own edit so its Save is meaningful.
        var editedA = m.drawing.entity(aMemberID)!
        editedA.kind = .line(LineData(start: Vector(0, 0), end: Vector(20, 4)))
        m.applyInspectorEdits([editedA])
        m.enterBlockEditing(name: "B")
        m.enterBlockEditing(name: "C")
        var editedC = m.drawing.entity(cMemberID)!
        editedC.kind = .line(LineData(start: Vector(0, 0), end: Vector(1, 9)))
        m.applyInspectorEdits([editedC])
        m.exitBlockEditing(save: true)        // SAVE C
        m.exitBlockEditing(save: false)       // DISCARD B
        m.exitBlockEditing(save: true)        // SAVE A
        #expect(m.isEditingBlock == false)
        #expect(lineEnds(m.drawing.entity(cMemberID))!.1 == Vector(1, 9))   // C kept
        #expect(lineEnds(m.drawing.entity(aMemberID))!.1 == Vector(20, 4))  // A kept
        let pts = resolvedPoints(m.drawing.entity(topInsertID)!, m.drawing)
        #expect(contains(pts, Vector(109, 117)))   // C saved, via deep resolve through A's new pos
    }
}
