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
}
