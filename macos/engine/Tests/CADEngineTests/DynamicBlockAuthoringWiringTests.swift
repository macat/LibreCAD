//
//  DynamicBlockAuthoringWiringTests.swift
//  CADEngineTests
//
//  WAVE DB-2W STAGE 2 — the dynamic-block PARAMETER + ACTION authoring (block-features
//  §5.2.2 linear / §5.2.7 flip, §6.2.3 stretch / §6.2.6 flip), tested through the PURE,
//  headless-safe `CanvasModel` funnel the `BlockDynamicParametersPanel` drives — NEVER a
//  SwiftUI body (the headless-hang rule). Covers the STAGE-2 seams:
//
//   • ADD LINEAR STRETCH from the selection → a `.linear` parameter (left-mid → right-mid of
//     the selection's block-local bounds) + a `.stretch` action over the right half,
//     targeting the selected members. The resulting parameter is then DRAGGABLE (a placed
//     insert stretches), proving the round trip into STAGE 1.
//   • ADD FLIP from the selection → a `.flip` parameter (vertical reflection line) + a
//     `.flip` action over the selected members.
//   • REMOVE a parameter PRUNES the actions that referenced it (no orphans); REMOVE an
//     action leaves its parameter.
//   • Each add/remove is captured in the block-edit session undo group (Save & Close + one
//     ⌘Z reverts all of it), mirroring the visibility-authoring test convention.
//   • Guards: not editing → no-op; no-member / degenerate selection → no-op.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via
//  `_SharedCanvasModel.swift`. The suite is `@MainActor`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
import AppKit
@testable import CADEngine

@MainActor
@Suite("dynamic block authoring — DB-2W STAGE 2 parameters + actions")
struct DynamicBlockAuthoringWiringTests {

    // MARK: - Helpers

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: .placeholder, kind: .line(LineData(start: a, end: b)))
    }

    /// A model holding a plain block "DOOR" (one member line (0,0)→(10,0)) being EDITED, no
    /// dynamic def yet — the starting point for authoring. Returns the model + the member id.
    private func editingDoor() -> (model: CanvasModel, memberID: EntityID) {
        let d = CADDrawing()
        let m = d.add(line(Vector(0, 0), Vector(10, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "DOOR", entityIDs: [m])) }
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        _ = model.enterBlockEditing(name: "DOOR")
        return (model, m)
    }

    // MARK: - ADD LINEAR STRETCH

    @Test("addLinearStretchFromSelection adds a linear parameter + a stretch action over the members")
    func addLinearStretch() {
        let (m, member) = editingDoor()
        #expect(m.editingBlockParameters.isEmpty)
        #expect(m.editingBlockActions.isEmpty)

        m.selection = Selection(ids: [member])
        let pid = m.addLinearStretchFromSelection(label: "Width")
        #expect(pid != nil)

        // One linear parameter, labelled, with a sensible base distance (the box width 10).
        #expect(m.editingBlockParameters.count == 1)
        let param = m.editingBlockParameters.first!
        if case .linear(_, let label, let base, let end) = param {
            #expect(label == "Width")
            #expect((end - base).magnitude > 9.99)        // ~10 wide
        } else { Issue.record("expected a linear parameter") }

        // One stretch action, driven by that parameter, over the selected member.
        #expect(m.editingBlockActions.count == 1)
        let action = m.editingBlockActions.first!
        #expect(action.parameterID == pid)
        #expect(action.memberIDs == [member])
        if case .stretch = action {} else { Issue.record("expected a stretch action") }
    }

    @Test("an authored linear stretch is DRAGGABLE on a placed insert (round trip into STAGE 1)")
    func authoredStretchIsDraggable() {
        let (m, member) = editingDoor()
        m.selection = Selection(ids: [member])
        let pid = m.addLinearStretchFromSelection()!
        // Save & Close so the block carries the new dynamic def.
        #expect(m.exitBlockEditing(save: true) == true)

        // Place an insert of DOOR (the undoable insert funnel opens its own group) and
        // commit a stretch on it → the geometry re-resolves.
        #expect(m.insertBlock(named: "DOOR", at: Vector(0, 0)) == true)
        let iID = m.selection.ids.first!
        m.selection = Selection(ids: [iID])
        // The grip enumeration sees the authored linear parameter.
        let grips = m.singleSelectedDynamicInsertGrips?.grips ?? []
        #expect(grips.contains { grip in
            if case .stretch(let gpid, _, _, _) = grip { return gpid == pid }; return false
        })
        // Committing a stretch writes the value + re-resolves to the new length.
        #expect(m.commitInsertStretch(iID, parameter: pid, distance: 16) == true)
        let segs = m.drawing.entity(iID)!.resolve(m.drawing.makeResolveContext()).polylines
            .filter { !$0.closed && $0.points.count == 2 }
        #expect(segs.contains { seg in seg.points.contains { ($0 - Vector(16, 0)).magnitude < 1e-6 } })
    }

    // MARK: - ADD FLIP

    @Test("addFlipFromSelection adds a flip parameter + a flip action over the members")
    func addFlip() {
        let (m, member) = editingDoor()
        m.selection = Selection(ids: [member])
        let pid = m.addFlipFromSelection(label: "Mirror")
        #expect(pid != nil)

        #expect(m.editingBlockParameters.count == 1)
        if case .flip(_, let label, let s, let e) = m.editingBlockParameters.first! {
            #expect(label == "Mirror")
            // A VERTICAL line through the box center x=5.
            #expect(abs(s.x - 5) < 1e-6 && abs(e.x - 5) < 1e-6)
        } else { Issue.record("expected a flip parameter") }

        #expect(m.editingBlockActions.count == 1)
        let action = m.editingBlockActions.first!
        #expect(action.parameterID == pid)
        #expect(action.memberIDs == [member])
        if case .flip = action {} else { Issue.record("expected a flip action") }
    }

    // MARK: - REMOVE (prune orphan actions)

    @Test("removeEditingBlockParameter prunes the actions that referenced it")
    func removeParameterPrunesActions() {
        let (m, member) = editingDoor()
        m.selection = Selection(ids: [member])
        let lenID = m.addLinearStretchFromSelection()!
        let mirID = m.addFlipFromSelection()!
        #expect(m.editingBlockParameters.count == 2)
        #expect(m.editingBlockActions.count == 2)

        // Remove the linear parameter → its stretch action is pruned; the flip pair stays.
        #expect(m.removeEditingBlockParameter(lenID) == true)
        #expect(m.editingBlockParameters.map(\.id) == [mirID])
        #expect(m.editingBlockActions.count == 1)
        #expect(m.editingBlockActions.first!.parameterID == mirID)
    }

    @Test("removeEditingBlockAction removes only the action, leaving its parameter")
    func removeActionKeepsParameter() {
        let (m, member) = editingDoor()
        m.selection = Selection(ids: [member])
        let lenID = m.addLinearStretchFromSelection()!
        let aid = m.editingBlockActions.first!.id

        #expect(m.removeEditingBlockAction(aid) == true)
        #expect(m.editingBlockActions.isEmpty)
        #expect(m.editingBlockParameters.map(\.id) == [lenID])   // parameter intact
    }

    @Test("removeEditingBlockParameter is a no-op for an unknown id")
    func removeUnknownParameterNoOp() {
        let (m, member) = editingDoor()
        m.selection = Selection(ids: [member])
        _ = m.addLinearStretchFromSelection()
        #expect(m.removeEditingBlockParameter(BlockParameterID("ghost")) == false)
        #expect(m.editingBlockParameters.count == 1)
    }

    // MARK: - UNDO (session group)

    @Test("authoring is captured in the session undo group: Save & Close + ⌘Z reverts all of it")
    func authoringUndoneByOneZ() {
        let (m, member) = editingDoor()
        m.selection = Selection(ids: [member])
        #expect(m.addLinearStretchFromSelection() != nil)
        #expect(m.addFlipFromSelection() != nil)
        #expect(m.drawing.blocks.block(named: "DOOR")?.dynamic?.parameters.count == 2)

        // Save & Close closes the session group; one ⌘Z reverts the whole session → the
        // block is plain again (no parameters/actions).
        #expect(m.exitBlockEditing(save: true) == true)
        m.undoManager.undo()
        let def = m.drawing.blocks.block(named: "DOOR")?.dynamic
        #expect((def?.parameters.isEmpty ?? true) && (def?.actions.isEmpty ?? true))
    }

    // MARK: - GUARDS

    @Test("authoring is a no-op outside a block-edit session")
    func authoringRequiresEditing() {
        let d = CADDrawing()
        let m = d.add(line(Vector(0, 0), Vector(10, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "DOOR", entityIDs: [m])) }
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.selection = Selection(ids: [m])
        #expect(model.isEditingBlock == false)
        #expect(model.addLinearStretchFromSelection() == nil)
        #expect(model.addFlipFromSelection() == nil)
        #expect(model.removeEditingBlockParameter(BlockParameterID("x")) == false)
        #expect(model.removeEditingBlockAction(BlockActionID("x")) == false)
    }

    @Test("authoring with no member selection is a no-op")
    func authoringRequiresMembers() {
        let (m, _) = editingDoor()
        // Nothing selected.
        m.selection = Selection(ids: [])
        #expect(m.addLinearStretchFromSelection() == nil)
        #expect(m.addFlipFromSelection() == nil)
        // A NON-member selection (an id outside the block) is also a no-op.
        m.selection = Selection(ids: [EntityID(9999)])
        #expect(m.addLinearStretchFromSelection() == nil)
        #expect(m.editingBlockParameters.isEmpty)
    }

    @Test("editing-block parameter/action lists are empty when not editing")
    func listsEmptyOutsideSession() {
        let d = CADDrawing()
        let m = d.add(line(Vector(0, 0), Vector(10, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "DOOR", entityIDs: [m])) }
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        #expect(model.editingBlockParameters.isEmpty)
        #expect(model.editingBlockActions.isEmpty)
    }
}
