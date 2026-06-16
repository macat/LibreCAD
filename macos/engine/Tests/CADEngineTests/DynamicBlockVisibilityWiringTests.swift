//
//  DynamicBlockVisibilityWiringTests.swift
//  CADEngineTests
//
//  WAVE DB-1W — the dynamic-block VISIBILITY-STATES UI WIRING (block-features §9), tested
//  through the PURE, headless-safe `CanvasModel` funnel the View layer drives — NEVER a
//  SwiftUI body or an NSMenu/modal (the headless-hang rule). Covers the three DB-1W seams:
//
//   • AUTHORING (inside the Block Editor scope): the panel actions call the right
//     `CADDrawing` mutators via `CanvasModel` — add / rename / delete a state, and BVSHOW /
//     BVHIDE the current selection's members in the current state — and each is one-⌘Z
//     undoable. §9.5 invariants (≥1 state; first state default) are enforced.
//   • INSTANCE: `setInsertVisibilityState` (the path the dropdown grip + Inspector picker
//     trigger) writes `activeVisibilityState`, a resolved insert shows the new state's
//     members, and `nil` resolves to the default (first) state.
//   • ARBITRATION (critic must-fix): the PURE `shouldSuppressGizmoForSelection` /
//     `singleSelectedDynamicInsert` decision — a single dynamic insert suppresses the gizmo
//     (overlay shown); a normal entity does not (gizmo shown). The `DynamicGripOverlayView`
//     `refresh()` lifecycle (`isHidden`/`isActive`) is exercised WITHOUT presenting its
//     NSMenu (reached via the `_SharedDynamicGripOverlay.swift` symlink).
//
//  `CanvasModel` + `DynamicGripOverlayView` live in the (un-importable) app target — reached
//  here via `_SharedCanvasModel.swift` / `_SharedDynamicGripOverlay.swift` symlinks. The
//  suite is `@MainActor` (mirrors `BlockUIWiringTests`).
//
//  Uniquely namespaced (`@Suite("dynamic block visibility — DB-1W UI wiring")`) so it does
//  not collide with the other suites in the shared test target.
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
@Suite("dynamic block visibility — DB-1W UI wiring")
struct DynamicBlockVisibilityWiringTests {

    // MARK: - Helpers

    /// A circle entity with a distinct radius (so resolved geometry identifies it). The id
    /// is minted by `CADDrawing.add` (the `.placeholder` id), avoiding hand-picked-id
    /// collisions with `mintID()` (which `add` aborts on).
    private func circle(radius: Double) -> EntityRecord {
        EntityRecord(id: .placeholder, kind: .circle(CircleData(center: Vector(0, 0), radius: radius)))
    }

    /// All resolved circle radii (from the closed polylines) of a record, so a resolved
    /// insert's VISIBLE members can be identified by their radius.
    private func resolvedRadii(_ rec: EntityRecord, _ d: CADDrawing) -> [Double] {
        rec.resolve(d.makeResolveContext()).polylines.compactMap { poly -> Double? in
            guard poly.closed, let p0 = poly.points.first else { return nil }
            // A circle resolves centered at the insertion point; radius ~ max |p - center|.
            let cx = poly.points.map(\.x).reduce(0, +) / Double(poly.points.count)
            let cy = poly.points.map(\.y).reduce(0, +) / Double(poly.points.count)
            return (p0 - Vector(cx, cy)).magnitude
        }
    }

    private func hasRadius(_ radii: [Double], _ r: Double, tol: Double = 1e-6) -> Bool {
        radii.contains { abs($0 - r) < tol }
    }

    /// A model with a DYNAMIC block "VALVE" carrying three circle members (r1/r2/r3) and two
    /// visibility states A={m1,m2}, B={m3}; plus one insert of it. Returns the model, the
    /// insert id, and the three member ids (m1/m2/m3) for arbitration/no-member checks. The
    /// undo manager is the testing (manual-grouping) one with a clean stack.
    private func dynamicModel(active: String? = nil)
        -> (model: CanvasModel, insertID: EntityID, members: [EntityID]) {
        let d = CADDrawing()
        let m1 = d.add(circle(radius: 1))
        let m2 = d.add(circle(radius: 2))
        let m3 = d.add(circle(radius: 3))
        let def = DynamicBlockDef(visibilityStates: [
            BlockVisibilityState(name: "A", visibleMemberIDs: [m1, m2]),
            BlockVisibilityState(name: "B", visibleMemberIDs: [m3]),
        ])
        d.mutateBlocks { _ = $0.add(Block(name: "VALVE", entityIDs: [m1, m2, m3], dynamic: def)) }
        var ins = InsertData(blockName: "VALVE", insertionPoint: Vector(50, 50))
        if let active { ins.dynamic = InsertDynamicState(activeVisibilityState: active) }
        let iID = d.add(EntityRecord(id: .placeholder, kind: .insert(ins)))
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, iID, [m1, m2, m3])
    }

    /// A model holding ONE plain block "WIDGET" (one member) being EDITED, with no dynamic
    /// def yet — the starting point for authoring tests. Returns the model + the member id.
    private func editingPlainBlock() -> (model: CanvasModel, memberID: EntityID) {
        let d = CADDrawing()
        let m = d.add(circle(radius: 7))
        d.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [m])) }
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        _ = model.enterBlockEditing(name: "WIDGET")
        return (model, m)
    }

    // MARK: - INSTANCE: setInsertVisibilityState (dropdown grip + Inspector path)

    @Test("setInsertVisibilityState writes activeVisibilityState and re-resolves to that state")
    func setActiveStateResolvesNewVariant() {
        let (m, iID, _) = dynamicModel(active: "A")
        // State A → members m1 (r1) + m2 (r2) visible, m3 (r3) hidden.
        var radii = resolvedRadii(m.drawing.entity(iID)!, m.drawing)
        #expect(hasRadius(radii, 1) && hasRadius(radii, 2) && !hasRadius(radii, 3))

        // Switch to B (the grip/inspector path) → only m3 (r3) visible.
        #expect(m.setInsertVisibilityState(iID, to: "B") == true)
        radii = resolvedRadii(m.drawing.entity(iID)!, m.drawing)
        #expect(!hasRadius(radii, 1) && !hasRadius(radii, 2) && hasRadius(radii, 3))

        // The stored instance state reflects the switch.
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect(data.dynamic?.activeVisibilityState == "B")
        } else { Issue.record("expected an insert") }
    }

    @Test("setInsertVisibilityState is undoable (one ⌘Z reverts the switch)")
    func setActiveStateUndoable() {
        let (m, iID, _) = dynamicModel(active: "A")
        m.undoManager.beginUndoGrouping()
        #expect(m.setInsertVisibilityState(iID, to: "B") == true)
        m.undoManager.endUndoGrouping()

        m.undoManager.undo()
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect(data.dynamic?.activeVisibilityState == "A")
        } else { Issue.record("expected an insert") }
    }

    @Test("nil active state resolves to the DEFAULT (first) state; redundant set is a no-op")
    func defaultStateWhenNil() {
        let (m, iID, _) = dynamicModel(active: nil)  // no explicit state → default = first (A)
        let radii = resolvedRadii(m.drawing.entity(iID)!, m.drawing)
        #expect(hasRadius(radii, 1) && hasRadius(radii, 2) && !hasRadius(radii, 3))

        // Setting to the same nil is a no-op; setting to A then back to nil both apply once.
        #expect(m.setInsertVisibilityState(iID, to: nil) == false)   // already nil
        #expect(m.setInsertVisibilityState(iID, to: "A") == true)
        #expect(m.setInsertVisibilityState(iID, to: "A") == false)   // redundant
    }

    @Test("setInsertVisibilityState is false for a non-insert id")
    func setActiveStateRejectsNonInsert() {
        let (m, _, members) = dynamicModel()
        // A member circle is a circle, not an insert.
        #expect(m.setInsertVisibilityState(members[0], to: "B") == false)
    }

    // MARK: - ARBITRATION (critic must-fix): the pure gizmo-suppression decision

    @Test("a single dynamic insert suppresses the gizmo (overlay-only); a normal entity does not")
    func gizmoArbitrationDecision() {
        let (m, iID, members) = dynamicModel(active: "A")

        // Nothing selected → no suppression (gizmo behaves as today; here it has no selection).
        #expect(m.shouldSuppressGizmoForSelection == false)
        #expect(m.singleSelectedDynamicInsert == nil)

        // Select the dynamic insert → suppress the gizmo, show ONLY the dynamic grip.
        m.selection = Selection(ids: [iID])
        #expect(m.shouldSuppressGizmoForSelection == true)
        #expect(m.singleSelectedDynamicInsert?.id == iID)
        #expect(m.singleSelectedDynamicInsert?.blockName == "VALVE")
        #expect(m.singleSelectedDynamicInsert?.states.count == 2)

        // Select a NORMAL entity (a member circle) → no suppression (gizmo shown as today).
        m.selection = Selection(ids: [members[0]])
        #expect(m.shouldSuppressGizmoForSelection == false)
        #expect(m.singleSelectedDynamicInsert == nil)
    }

    @Test("multi-selection including a dynamic insert does NOT suppress the gizmo")
    func multiSelectionDoesNotSuppress() {
        let (m, iID, members) = dynamicModel()
        m.selection = Selection(ids: [iID, members[0]])
        #expect(m.shouldSuppressGizmoForSelection == false)  // suppression is single-selection only
    }

    @Test("a non-dynamic block insert is NOT treated as a dynamic insert")
    func plainInsertIsNotDynamic() {
        let d = CADDrawing()
        let mID = d.add(circle(radius: 1))
        d.mutateBlocks { _ = $0.add(Block(name: "PLAIN", entityIDs: [mID])) }   // no dynamic def
        let iID = d.add(EntityRecord(id: .placeholder,
                                     kind: .insert(InsertData(blockName: "PLAIN", insertionPoint: Vector(0, 0)))))
        let m = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        m.selection = Selection(ids: [iID])
        #expect(m.shouldSuppressGizmoForSelection == false)
        #expect(m.singleSelectedDynamicInsert == nil)
    }

    // MARK: - AUTHORING (inside the Block Editor scope)
    //
    // NOTE on undo: `enterBlockEditing` opens ONE session undo group that stays open until
    // `exitBlockEditing` (a single ⌘Z reverts the whole session). So authoring-undo here is
    // verified the realistic way — author inside the session, Save & Close to register the
    // session group, then ONE ⌘Z reverts ALL the authoring. (The per-mutator undoability is
    // additionally proven at the engine layer in `DynamicBlockVisibilityTests`.)

    @Test("addEditingBlockVisibilityState creates the def + state (first becomes default)")
    func authoringAddState() {
        let (m, _) = editingPlainBlock()
        #expect(m.editingBlockVisibilityStates.isEmpty)          // plain block, no states yet

        #expect(m.addEditingBlockVisibilityState(named: "Open") == true)
        #expect(m.editingBlockVisibilityStates.map(\.name) == ["Open"])
        // First state is the default (§9.5).
        #expect(m.drawing.blocks.block(named: "WIDGET")?.dynamic?.defaultVisibilityState?.name == "Open")

        // A duplicate name is rejected (no-op).
        #expect(m.addEditingBlockVisibilityState(named: "Open") == false)
        // A blank name is rejected.
        #expect(m.addEditingBlockVisibilityState(named: "   ") == false)
    }

    @Test("authoring is captured in the session undo group: Save & Close + ⌘Z reverts all of it")
    func authoringUndoneByOneZAfterSaveClose() {
        let (m, member) = editingPlainBlock()
        #expect(m.addEditingBlockVisibilityState(named: "Open") == true)
        m.selection = Selection(ids: [member])
        #expect(m.setSelectedMembersVisibility(inState: "Open", visible: true) == 1)
        #expect(m.drawing.blocks.block(named: "WIDGET")?.dynamic?.visibilityStates.count == 1)

        // Save & Close closes the session group; one ⌘Z reverts the whole session →
        // the block is plain again (no dynamic def).
        #expect(m.exitBlockEditing(save: true) == true)
        m.undoManager.undo()
        let block = m.drawing.blocks.block(named: "WIDGET")
        #expect(block?.dynamic?.visibilityStates.isEmpty ?? true)
    }

    @Test("addEditingBlockVisibilityState is a no-op outside a block-edit session")
    func authoringAddRequiresEditing() {
        let (m, _, _) = dynamicModel()
        #expect(m.isEditingBlock == false)
        #expect(m.addEditingBlockVisibilityState(named: "X") == false)
    }

    @Test("renameEditingBlockVisibilityState preserves the id + visible-member set")
    func authoringRenameState() {
        let (m, member) = editingPlainBlock()
        #expect(m.addEditingBlockVisibilityState(named: "Open") == true)
        // Put the member into "Open".
        m.selection = Selection(ids: [member])
        #expect(m.setSelectedMembersVisibility(inState: "Open", visible: true) == 1)
        let originalID = m.editingBlockVisibilityStates.first!.id

        #expect(m.renameEditingBlockVisibilityState("Open", to: "Closed") == true)
        let renamed = m.editingBlockVisibilityStates.first!
        #expect(renamed.name == "Closed")
        #expect(renamed.id == originalID)                          // stable id preserved
        #expect(renamed.visibleMemberIDs.contains(member))         // member set preserved
    }

    @Test("renameEditingBlockVisibilityState rejects unknown / blank / colliding names")
    func authoringRenameRejections() {
        let (m, _) = editingPlainBlock()
        #expect(m.addEditingBlockVisibilityState(named: "Open") == true)
        #expect(m.addEditingBlockVisibilityState(named: "Shut") == true)
        #expect(m.renameEditingBlockVisibilityState("Ghost", to: "Z") == false)   // unknown old
        #expect(m.renameEditingBlockVisibilityState("Open", to: "  ") == false)   // blank new
        #expect(m.renameEditingBlockVisibilityState("Open", to: "Open") == false) // same name
        #expect(m.renameEditingBlockVisibilityState("Open", to: "Shut") == false) // collides
        // The states are unchanged after the rejected attempts.
        #expect(m.editingBlockVisibilityStates.map(\.name) == ["Open", "Shut"])
    }

    @Test("removeEditingBlockVisibilityState deletes a state but enforces ≥1 (§9.5)")
    func authoringDeleteState() {
        let (m, _) = editingPlainBlock()
        #expect(m.addEditingBlockVisibilityState(named: "A") == true)
        #expect(m.addEditingBlockVisibilityState(named: "B") == true)
        #expect(m.editingBlockVisibilityStates.map(\.name) == ["A", "B"])

        #expect(m.removeEditingBlockVisibilityState(named: "A") == true)
        #expect(m.editingBlockVisibilityStates.map(\.name) == ["B"])

        // The last state cannot be deleted (§9.5: ≥1 state).
        #expect(m.removeEditingBlockVisibilityState(named: "B") == false)
        #expect(m.editingBlockVisibilityStates.map(\.name) == ["B"])
    }

    @Test("setSelectedMembersVisibility shows/hides only the block's members in the current state")
    func authoringShowHideMembers() {
        let (m, member) = editingPlainBlock()
        #expect(m.addEditingBlockVisibilityState(named: "S") == true)

        // Selecting a NON-member id changes nothing.
        m.selection = Selection(ids: [EntityID(9999)])
        #expect(m.setSelectedMembersVisibility(inState: "S", visible: true) == 0)

        // Selecting the real member adds it to the state's visible set (BVSHOW).
        m.selection = Selection(ids: [member])
        #expect(m.setSelectedMembersVisibility(inState: "S", visible: true) == 1)
        #expect(m.editingBlockVisibilityStates.first!.visibleMemberIDs.contains(member))

        // Re-showing is a no-op (already visible).
        #expect(m.setSelectedMembersVisibility(inState: "S", visible: true) == 0)

        // BVHIDE removes it.
        #expect(m.setSelectedMembersVisibility(inState: "S", visible: false) == 1)
        #expect(!m.editingBlockVisibilityStates.first!.visibleMemberIDs.contains(member))
    }

    @Test("editingBlockVisibilityStates is empty when not editing")
    func authoringStatesEmptyOutsideSession() {
        let (m, _, _) = dynamicModel()
        #expect(m.isEditingBlock == false)
        #expect(m.editingBlockVisibilityStates.isEmpty)
    }

    // MARK: - OVERLAY lifecycle (no NSMenu — the headless-safe surface)

    @Test("DynamicGripOverlayView.refresh shows only for a single dynamic insert")
    func overlayRefreshLifecycle() {
        let (m, iID, members) = dynamicModel(active: "A")
        let overlay = DynamicGripOverlayView(model: m, requestCanvasRedraw: {})

        // No selection → hidden / inactive.
        overlay.refresh()
        #expect(overlay.isHidden == true)
        #expect(overlay.isActive == false)

        // Single dynamic insert selected → shown / active (anchored at the selection bounds).
        m.selection = Selection(ids: [iID])
        overlay.refresh()
        #expect(overlay.isHidden == false)
        #expect(overlay.isActive == true)

        // A normal entity selected → hidden again (the gizmo owns that case).
        m.selection = Selection(ids: [members[0]])
        overlay.refresh()
        #expect(overlay.isHidden == true)
        #expect(overlay.isActive == false)
    }
}
