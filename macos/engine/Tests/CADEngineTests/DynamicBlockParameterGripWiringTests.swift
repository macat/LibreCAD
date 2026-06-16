//
//  DynamicBlockParameterGripWiringTests.swift
//  CADEngineTests
//
//  WAVE DB-2W STAGE 1 — the dynamic-block INSTANCE PARAMETER GRIPS (block-features
//  §5.2.2 linear / §5.2.7 flip, §6.2.3 stretch / §6.2.6 flip, §13.5 grips), tested
//  through the PURE, headless-safe `CanvasModel` funnel the View layer drives — NEVER a
//  SwiftUI body or an NSMenu/drag (the headless-hang rule). Covers the STAGE-1 seams:
//
//   • GRIP ENUMERATION: a selected dynamic insert with 1 linear + 1 flip parameter yields
//     exactly 2 grips, world-anchored (a square stretch grip + a triangle flip grip), and
//     no gizmo regression for a normal entity.
//   • STRETCH COMMIT: the drag→distance mapping projects the cursor onto the parameter
//     direction, the commit writes `parameterValues[paramID]`, the insert re-resolves to
//     the stretched geometry, and one ⌘Z reverts it.
//   • FLIP COMMIT: toggles `flipStates[paramID]`, the insert re-resolves mirrored, and one
//     ⌘Z reverts it.
//   • PREVIEW: `insertEvaluationPreview` yields the stretched/flipped polylines mid-drag,
//     and clears on commit/cancel (cancel reverts to the committed value).
//   • ARBITRATION: a parameters-only dynamic insert still suppresses the gizmo (DB-2W
//     broadened `singleSelectedDynamicInsertID`); a normal entity does not.
//   • OVERLAY lifecycle (no NSMenu / no NSView drag): the `DynamicGripOverlayView`
//     `refresh()` shows for a parameters-only insert (reached via the
//     `_SharedDynamicGripOverlay.swift` symlink).
//
//  `CanvasModel` + `DynamicGripOverlayView` live in the (un-importable) app target —
//  reached here via `_SharedCanvasModel.swift` / `_SharedDynamicGripOverlay.swift`
//  symlinks. The suite is `@MainActor` (mirrors `DynamicBlockVisibilityWiringTests`).
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
@Suite("dynamic block parameter grips — DB-2W STAGE 1 instance grips")
struct DynamicBlockParameterGripWiringTests {

    // MARK: - Helpers

    /// A horizontal line from `a` to `b`, id minted by `CADDrawing.add`.
    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: .placeholder, kind: .line(LineData(start: a, end: b)))
    }

    /// The resolved line segments (start/end pairs) of a record — so a stretched/flipped
    /// member can be identified by where its endpoints land.
    private func resolvedSegments(_ rec: EntityRecord, _ d: CADDrawing) -> [(Vector, Vector)] {
        rec.resolve(d.makeResolveContext()).polylines.compactMap { poly in
            guard !poly.closed, poly.points.count == 2 else { return nil }
            return (poly.points[0], poly.points[1])
        }
    }

    private func hasPointNear(_ segs: [(Vector, Vector)], _ p: Vector, tol: Double = 1e-6) -> Bool {
        segs.contains { (a, b) in (a - p).magnitude < tol || (b - p).magnitude < tol }
    }

    /// A model with a DYNAMIC block "DOOR" containing one member line m0 from (0,0)→(10,0),
    /// a LINEAR parameter `len` (base (0,0)→end (10,0), base distance 10) driving a STRETCH
    /// action over a frame around the line's right endpoint, and a FLIP parameter `mir`
    /// (vertical reflection line through x=0) driving a FLIP action over m0. Plus ONE insert
    /// at the origin (unit scale, no rotation, so block-local == world). Returns the model,
    /// the insert id, the member id, and the parameter ids.
    private func doorModel()
        -> (model: CanvasModel, insertID: EntityID, memberID: EntityID,
            lenID: BlockParameterID, mirID: BlockParameterID) {
        let d = CADDrawing()
        let m0 = d.add(line(Vector(0, 0), Vector(10, 0)))
        let lenID = BlockParameterID("len")
        let mirID = BlockParameterID("mir")
        let def = DynamicBlockDef(
            parameters: [
                .linear(id: lenID, label: "Length", base: Vector(0, 0), end: Vector(10, 0)),
                .flip(id: mirID, label: "Mirror", lineStart: Vector(0, -5), lineEnd: Vector(0, 5)),
            ],
            actions: [
                // Stretch frame around the right endpoint (x in [5,15], y in [-1,1]) so the
                // (10,0) endpoint is inside and (0,0) is outside.
                .stretch(id: BlockActionID("a-len"), parameterID: lenID,
                         stretchFrame: AABB(min: Vector(5, -1), max: Vector(15, 1)),
                         memberIDs: [m0]),
                .flip(id: BlockActionID("a-mir"), parameterID: mirID, memberIDs: [m0]),
            ])
        d.mutateBlocks { _ = $0.add(Block(name: "DOOR", entityIDs: [m0], dynamic: def)) }
        let iID = d.add(EntityRecord(id: .placeholder,
                                     kind: .insert(InsertData(blockName: "DOOR", insertionPoint: Vector(0, 0)))))
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, iID, m0, lenID, mirID)
    }

    // MARK: - GRIP ENUMERATION

    @Test("a 1-linear + 1-flip dynamic insert yields exactly 2 world-anchored grips")
    func gripEnumeration() {
        let (m, iID, _, lenID, mirID) = doorModel()
        // Nothing selected → no grips.
        #expect(m.singleSelectedDynamicInsertGrips == nil)

        m.selection = Selection(ids: [iID])
        let result = m.singleSelectedDynamicInsertGrips
        #expect(result?.id == iID)
        let grips = result?.grips ?? []
        #expect(grips.count == 2)

        // One stretch grip (at the linear param end = world (10,0)) and one flip grip.
        var sawStretch = false, sawFlip = false
        for grip in grips {
            switch grip {
            case .stretch(let pid, _, let end, let baseDist):
                #expect(pid == lenID)
                #expect((end - Vector(10, 0)).magnitude < 1e-6)   // end at base distance
                #expect(abs(baseDist - 10) < 1e-6)
                sawStretch = true
            case .flip(let pid, let s, let e, let flipped):
                #expect(pid == mirID)
                #expect((s - Vector(0, -5)).magnitude < 1e-6)
                #expect((e - Vector(0, 5)).magnitude < 1e-6)
                #expect(flipped == false)
                sawFlip = true
            }
        }
        #expect(sawStretch && sawFlip)
    }

    @Test("grips are world-mapped through the insert placement (translation)")
    func gripsWorldMapped() {
        let (m, iID, _, _, _) = doorModel()
        // Move the insert to (100,50): the stretch grip end should map to (110,50).
        if var rec = m.drawing.entity(iID), case .insert(var data) = rec.kind {
            data.insertionPoint = Vector(100, 50)
            rec.kind = .insert(data)
            m.applyInspectorEdits([rec])
        }
        m.selection = Selection(ids: [iID])
        let grips = m.singleSelectedDynamicInsertGrips?.grips ?? []
        let stretch = grips.compactMap { grip -> Vector? in
            if case .stretch(_, _, let end, _) = grip { return end }; return nil
        }.first
        #expect(stretch != nil)
        #expect((stretch! - Vector(110, 50)).magnitude < 1e-6)
    }

    // MARK: - STRETCH drag → distance mapping + commit + re-resolve

    @Test("stretchDistance projects the cursor onto the parameter direction")
    func stretchDistanceProjection() {
        let (m, iID, _, _, _) = doorModel()
        m.selection = Selection(ids: [iID])
        let grip = m.singleSelectedDynamicInsertGrips!.grips.first { grip in
            if case .stretch = grip { return true }; return false
        }!
        // Cursor at (18, 7): the x-projection along the +x parameter direction is 18.
        let d1 = m.stretchDistance(forGrip: grip, cursorWorld: Vector(18, 7))
        #expect(d1 != nil && abs(d1! - 18) < 1e-9)
        // A cursor BEHIND the base (negative projection) clamps to 0.
        let d2 = m.stretchDistance(forGrip: grip, cursorWorld: Vector(-3, 0))
        #expect(d2 != nil && d2! == 0)
    }

    @Test("commitInsertStretch writes the distance + the insert re-resolves stretched")
    func stretchCommitReResolves() {
        let (m, iID, _, lenID, _) = doorModel()
        m.selection = Selection(ids: [iID])
        // Baseline: the member resolves (0,0)→(10,0).
        var segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(10, 0)))
        #expect(!hasPointNear(segs, Vector(15, 0)))

        // Commit a stretch to distance 15 → the right endpoint (inside the frame) moves to
        // (15,0); the left (0,0) stays.
        #expect(m.commitInsertStretch(iID, parameter: lenID, distance: 15) == true)
        segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(15, 0)))
        #expect(hasPointNear(segs, Vector(0, 0)))
        #expect(!hasPointNear(segs, Vector(10, 0)))

        // The stored instance value reflects the stretch.
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect(data.dynamic?.parameterValues[lenID.raw] == 15)
        } else { Issue.record("expected an insert") }
    }

    @Test("commitInsertStretch is undoable (one ⌘Z reverts the stretch)")
    func stretchCommitUndoable() {
        let (m, iID, _, lenID, _) = doorModel()
        m.undoManager.beginUndoGrouping()
        #expect(m.commitInsertStretch(iID, parameter: lenID, distance: 15) == true)
        m.undoManager.endUndoGrouping()

        m.undoManager.undo()
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            // Back to no override (the key was set, undo restores the prior dynamic state).
            #expect((data.dynamic?.parameterValues[lenID.raw]) == nil)
        } else { Issue.record("expected an insert") }
        let segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(10, 0)))   // original length restored
    }

    @Test("commitInsertStretch is a no-op for a redundant / non-linear / non-insert target")
    func stretchCommitNoOps() {
        let (m, iID, memberID, lenID, mirID) = doorModel()
        // Redundant (distance == base) → no-op.
        #expect(m.commitInsertStretch(iID, parameter: lenID, distance: 10) == false)
        // A FLIP parameter is not linear → no-op.
        #expect(m.commitInsertStretch(iID, parameter: mirID, distance: 12) == false)
        // A non-insert id → no-op.
        #expect(m.commitInsertStretch(memberID, parameter: lenID, distance: 12) == false)
    }

    @Test("a stretch back to the base distance drops the override key (clean instance state)")
    func stretchBackToBaseDropsKey() {
        let (m, iID, _, lenID, _) = doorModel()
        #expect(m.commitInsertStretch(iID, parameter: lenID, distance: 15) == true)
        #expect(m.commitInsertStretch(iID, parameter: lenID, distance: 10) == true)  // back to base
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect((data.dynamic?.parameterValues[lenID.raw]) == nil)   // key removed
        } else { Issue.record("expected an insert") }
    }

    // MARK: - FLIP click → toggle + re-resolve

    @Test("toggleInsertFlip mirrors the insert + one ⌘Z reverts it")
    func flipToggleReResolvesAndUndoes() {
        let (m, iID, _, _, mirID) = doorModel()
        // Baseline: (0,0)→(10,0).
        var segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(10, 0)))

        // Flip about x=0 → the (10,0) endpoint mirrors to (-10,0); (0,0) stays on the axis.
        m.undoManager.beginUndoGrouping()
        #expect(m.toggleInsertFlip(iID, parameter: mirID) == true)
        m.undoManager.endUndoGrouping()
        segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(-10, 0)))
        #expect(hasPointNear(segs, Vector(0, 0)))
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect(data.dynamic?.flipStates[mirID.raw] == true)
        } else { Issue.record("expected an insert") }

        // ⌘Z reverts the flip → back to (10,0), flip key cleared.
        m.undoManager.undo()
        segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(10, 0)))
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect((data.dynamic?.flipStates[mirID.raw]) == nil)
        } else { Issue.record("expected an insert") }
    }

    @Test("toggleInsertFlip twice returns to the un-flipped (clean) state")
    func flipToggleTwiceIsIdentity() {
        let (m, iID, _, _, mirID) = doorModel()
        #expect(m.toggleInsertFlip(iID, parameter: mirID) == true)   // flip on
        #expect(m.toggleInsertFlip(iID, parameter: mirID) == true)   // flip off
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect((data.dynamic?.flipStates[mirID.raw]) == nil)    // key dropped on un-flip
        } else { Issue.record("expected an insert") }
        let segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(10, 0)))                   // original geometry
    }

    @Test("toggleInsertFlip is a no-op for a non-flip / non-insert target")
    func flipToggleNoOps() {
        let (m, iID, memberID, lenID, _) = doorModel()
        #expect(m.toggleInsertFlip(iID, parameter: lenID) == false)      // linear param
        #expect(m.toggleInsertFlip(memberID, parameter: lenID) == false) // non-insert
    }

    // MARK: - LIVE PREVIEW (insertEvaluationPreview)

    @Test("insertEvaluationPreview yields the stretched polylines mid-drag, clears on commit")
    func previewMidDrag() {
        let (m, iID, _, lenID, _) = doorModel()
        // No preview set → empty.
        #expect(m.insertEvaluationPreview.isEmpty)

        // Set a trial state at distance 20 (the drag-step path) → the preview re-resolves
        // the insert stretched to (20,0).
        var trial = m.insertDynamicState(iID)!
        trial.parameterValues[lenID.raw] = 20
        m.setInsertEvaluationPreview(id: iID, state: trial)
        let polys = m.insertEvaluationPreview
        #expect(!polys.isEmpty)
        let pts = polys.flatMap(\.points)
        #expect(pts.contains { (($0) - Vector(20, 0)).magnitude < 1e-6 })
        // The preview pen is the tool-preview pen (matching the gizmo rubber-band).
        #expect(polys.allSatisfy { $0.pen == .toolPreview })

        // Committing clears the preview.
        #expect(m.commitInsertStretch(iID, parameter: lenID, distance: 20) == true)
        #expect(m.insertEvaluationPreview.isEmpty)
    }

    @Test("clearInsertEvaluationPreview (cancel) drops the preview WITHOUT committing")
    func previewCancelReverts() {
        let (m, iID, _, lenID, _) = doorModel()
        var trial = m.insertDynamicState(iID)!
        trial.parameterValues[lenID.raw] = 30
        m.setInsertEvaluationPreview(id: iID, state: trial)
        #expect(!m.insertEvaluationPreview.isEmpty)

        // Cancel (Esc) → preview gone, the committed value is unchanged (still base, no key).
        m.clearInsertEvaluationPreview()
        #expect(m.insertEvaluationPreview.isEmpty)
        if case .insert(let data) = m.drawing.entity(iID)!.kind {
            #expect((data.dynamic?.parameterValues[lenID.raw]) == nil)
        } else { Issue.record("expected an insert") }
        let segs = resolvedSegments(m.drawing.entity(iID)!, m.drawing)
        #expect(hasPointNear(segs, Vector(10, 0)))   // original geometry intact
    }

    // MARK: - ARBITRATION: a parameters-only insert suppresses the gizmo

    @Test("a parameters-only dynamic insert suppresses the gizmo; a normal entity does not")
    func parametersOnlySuppressesGizmo() {
        let (m, iID, memberID, _, _) = doorModel()
        // The DOOR block has NO visibility states — only parameters/actions. The broadened
        // gate still suppresses the gizmo for it.
        #expect(m.singleSelectedDynamicInsert == nil)    // visibility-specific gate: nil

        m.selection = Selection(ids: [iID])
        #expect(m.singleSelectedDynamicInsertID == iID)
        #expect(m.shouldSuppressGizmoForSelection == true)

        // A normal entity (a member line) → no suppression.
        m.selection = Selection(ids: [memberID])
        #expect(m.singleSelectedDynamicInsertID == nil)
        #expect(m.shouldSuppressGizmoForSelection == false)
    }

    @Test("a plain (non-dynamic) insert is not gripped + does not suppress the gizmo")
    func plainInsertNoGrips() {
        let d = CADDrawing()
        let mID = d.add(line(Vector(0, 0), Vector(5, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "PLAIN", entityIDs: [mID])) }  // no dynamic def
        let iID = d.add(EntityRecord(id: .placeholder,
                                     kind: .insert(InsertData(blockName: "PLAIN", insertionPoint: Vector(0, 0)))))
        let m = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        m.selection = Selection(ids: [iID])
        #expect(m.singleSelectedDynamicInsertGrips == nil)
        #expect(m.shouldSuppressGizmoForSelection == false)
    }

    // MARK: - OVERLAY lifecycle (no NSMenu / no NSView drag — headless-safe surface)

    @Test("DynamicGripOverlayView.refresh shows for a parameters-only dynamic insert")
    func overlayShowsForParametersOnly() {
        let (m, iID, memberID, _, _) = doorModel()
        let overlay = DynamicGripOverlayView(model: m, requestCanvasRedraw: {})

        overlay.refresh()
        #expect(overlay.isHidden == true)          // nothing selected
        #expect(overlay.isActive == false)
        #expect(overlay.isDragging == false)

        m.selection = Selection(ids: [iID])
        overlay.refresh()
        #expect(overlay.isHidden == false)         // parameter grips present
        #expect(overlay.isActive == true)

        m.selection = Selection(ids: [memberID])
        overlay.refresh()
        #expect(overlay.isHidden == true)          // a normal entity → the gizmo owns it
        #expect(overlay.isActive == false)
    }

    // MARK: - NO GIZMO REGRESSION for normal entities

    @Test("a normal multi-selection does not suppress the gizmo (no regression)")
    func normalSelectionGizmoUnaffected() {
        let (m, iID, memberID, _, _) = doorModel()
        // Even with a dynamic insert in a MULTI-selection, suppression is single-only.
        m.selection = Selection(ids: [iID, memberID])
        #expect(m.shouldSuppressGizmoForSelection == false)
        #expect(m.singleSelectedDynamicInsertID == nil)
        #expect(m.singleSelectedDynamicInsertGrips == nil)
    }
}
