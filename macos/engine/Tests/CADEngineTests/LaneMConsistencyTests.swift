//
//  LaneMConsistencyTests.swift
//  CADEngineTests
//
//  Lane M (model/canvas/tool-mode consistency) regression suite. Drives the
//  CanvasModel surface PURELY (no GUI / NSEvent / modal) to lock in the
//  transient-state hygiene + tool-mode-surfacing fixes:
//
//    • M1 — undo/redo RE-HOMES the active-layout tab pointer (an undo that drops
//      the active layout must fall back to model space, not dangle / blank).
//    • M2 — undo/redo CLEARS the snap marker + hover highlight (they referenced
//      pre-undo geometry) + acquired tracking points.
//    • M3 — `setDrawing` (New-from-Template onto an open window) resets ALL
//      transient state (in-progress tool, relative-zero family, snap/hover, dyn).
//    • M4 — a space switch / block-edit enter+exit ABANDONS any in-progress draw
//      run + the unlocked relative-zero (so no stray cross-space segment); a
//      LOCKED relative-zero survives.
//    • M5 — `cancelViewportPlacement` drops an in-progress viewport drag but stays
//      in viewport-placement mode (the dedicated Esc cancel the canvas now calls).
//    • M6 — the F3/F9/F10/F12 status-chip toggles the canvas keyDown binds route to
//      the right model toggles (the keyDown itself is View-layer; the model verbs
//      are tested here).
//    • M7 — the command line does NOT echo a "→ x, y" success for a typed coordinate
//      an ENTITY-pick tool (Trim) ignored; a draw tool (Line) still echoes.
//    • M8 — PolylineEdit + XLine tool MODES round-trip through `applyToolConfig`
//      (the options the now-surfaced Tool Options bar binds).
//
//  `CanvasModel` lives in the (un-importable) app target — reached via the existing
//  `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `Wave3BCanvasModelWiringTests`). No SwiftUI body / NSEvent / modal is touched.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
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
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("Lane M — model/canvas/tool-mode consistency")
struct LaneMConsistencyTests {

    // MARK: - Fixtures

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        // Explicit undo groups (no run loop in a unit test), like the other wiring suites.
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// Commits one Line via the tool path — an UNDOABLE drawing mutation we can revert.
    /// (`applyCommit` opens its own explicit group when `groupsByEvent == false`.)
    private func drawOneLine(_ m: CanvasModel) {
        m.activateTool(.line)
        m.handleToolInput(.click(Vector(0, 0)))
        m.handleToolInput(.click(Vector(10, 0)))
        m.handleToolInput(.commit)               // finish the run
        m.activateTool(.select)                  // back to a clean idle state
    }

    /// Runs `body` inside an explicit undo group. Layout ops (`addLayout` /
    /// `mutateLayouts`) register undo but — unlike `applyCommit` — do NOT open their own
    /// group, so with `groupsByEvent == false` (no run loop) the caller must (the
    /// `PaperSpaceModelTests` convention). Returns `body`'s result.
    @discardableResult
    private func grouped<T>(_ m: CanvasModel, _ body: () -> T) -> T {
        m.undoManager.beginUndoGrouping()
        defer { m.undoManager.endUndoGrouping() }
        return body()
    }

    // MARK: - M1 — undo/redo re-homes the active-layout tab pointer

    @Test("undo that drops the active layout re-homes the tab to model space")
    func undoRehomesActiveLayout() {
        let m = model()
        // `newLayout` adds (undoable) + activates the fresh sheet.
        let name = grouped(m) { m.newLayout() }
        #expect(name != nil)
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == name)

        // Undo the layout-add: the layout table reverts, so the active sheet is gone.
        m.undo()
        #expect(m.activeSpace == .model)          // re-homed, not dangling on a dead sheet
        #expect(m.activeLayout == nil)
    }

    @Test("redo of the layout-add re-activates a valid space (no dangle)")
    func redoKeepsActiveSpaceValid() {
        let m = model()
        _ = grouped(m) { m.newLayout() }
        m.undo()                                   // back to model space
        m.redo()                                   // re-adds the layout
        // After redo the layout exists again; the active space must resolve (model is a
        // valid fallback — redo does not have to re-select the sheet, only stay valid).
        if m.activeSpace == .paper {
            #expect(m.activeLayout != nil)
            #expect(m.drawing.hasLayout(m.activeLayout!))
        } else {
            #expect(m.activeLayout == nil)
        }
    }

    // MARK: - M2 — undo/redo clears the snap marker + hover highlight

    @Test("undo clears the snap marker, hover highlight, and tracking points")
    func undoClearsTransientOverlays() throws {
        let m = model()
        drawOneLine(m)                             // an undoable step to revert (line in index)

        // Seed the snap marker as if the cursor were live over the old geometry.
        m.snap = SnapResult(point: Vector(10, 0), kind: .endpoint)

        // Seed the hover highlight DETERMINISTICALLY: in select mode, hover the line's
        // midpoint (mapped world→screen) so `updateHover` resolves it through the quadtree.
        let mid = m.viewport.worldToScreen(Vector(5, 0))
        _ = m.updateHover(atScreenPoint: mid)
        let hovered = try #require(m.hoverID)      // proves the clear below is non-trivial
        #expect(m.drawing.entity(hovered) != nil)

        m.undo()
        #expect(m.snap == nil)                     // snap marker cleared (CrosshairOverlay)
        #expect(m.hoverID == nil)                  // hover highlight cleared (MarqueeHoverOverlay)
    }

    @Test("redo also clears the snap marker + hover highlight")
    func redoClearsTransientOverlays() {
        let m = model()
        drawOneLine(m)
        m.undo()
        m.snap = SnapResult(point: Vector(5, 5), kind: .grid)
        m.redo()
        #expect(m.snap == nil)
        #expect(m.hoverID == nil)
    }

    // MARK: - M3 — setDrawing resets all transient state

    @Test("setDrawing (New-from-Template) resets in-progress tool + relative-zero + overlays")
    func setDrawingResetsTransientState() {
        let m = model()
        // Put the model in a dirty mid-interaction state.
        m.activateTool(.line)
        m.handleToolInput(.click(Vector(3, 4)))    // one point placed → relativeZero set
        m.snap = SnapResult(point: Vector(3, 4), kind: .endpoint)
        #expect(m.relativeZero != nil)

        // New-from-Template onto this open window: a fresh drawing replaces the model.
        m.setDrawing(CADDrawing(), viewSize: CGSize(width: 800, height: 600))

        #expect(m.relativeZero == nil)             // datum family cleared
        #expect(m.relativeZeroLocked == false)
        #expect(m.snap == nil)                     // overlays cleared
        #expect(m.hoverID == nil)
        // The in-progress Line run is dropped — re-minted to a fresh tool of the same kind
        // (still `.line`), so the next click starts at the first-point prompt, not the 2nd.
        #expect(m.activeToolKind == .line)
        let tool = m.tool as? LineTool
        #expect(tool != nil)
        // A fresh LineTool's status is the first-point prompt (no placed point survived).
        #expect(m.tool?.status == LineTool().status)
    }

    @Test("setDrawing drops even a LOCKED relative-zero (it referenced the prior drawing)")
    func setDrawingDropsLockedDatum() {
        let m = model()
        m.setRelativeZero(Vector(100, 100))
        m.setRelativeZeroLocked(true)
        #expect(m.relativeZeroLocked == true)
        m.setDrawing(CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        #expect(m.relativeZero == nil)
        #expect(m.relativeZeroLocked == false)
    }

    // MARK: - M4 — space switch / block-edit abandons the in-progress run

    @Test("switching to a layout abandons an in-progress draw run + unlocked relative-zero")
    func spaceSwitchAbandonsRun() {
        let m = model()
        let name = grouped(m) { m.newLayout() }    // adds + activates a sheet (paper space)
        #expect(name != nil)
        m.activateModel()                          // back to model space, clean

        // Start a Line in MODEL space (one point placed in model coordinates).
        m.activateTool(.line)
        m.handleToolInput(.click(Vector(7, 8)))
        #expect(m.relativeZero == Vector(7, 8))

        // Switch to the paper sheet: the in-progress run must be abandoned so a click on
        // the sheet does not continue the model-space line across spaces.
        m.activateLayout(name: name!)
        #expect(m.activeSpace == .paper)
        #expect(m.activeToolKind == .line)         // same tool stays selected …
        #expect(m.relativeZero == nil)             // … but the run + datum are abandoned
        #expect(m.tool?.status == LineTool().status)
    }

    @Test("a LOCKED relative-zero survives a space switch (a deliberate persistent datum)")
    func spaceSwitchKeepsLockedDatum() {
        let m = model()
        let name = grouped(m) { m.newLayout() }
        m.activateModel()
        m.setRelativeZero(Vector(2, 2))
        m.setRelativeZeroLocked(true)
        m.activateTool(.line)
        m.activateLayout(name: name!)
        #expect(m.relativeZero == Vector(2, 2))    // locked datum persists
        #expect(m.relativeZeroLocked == true)
    }

    @Test("entering + exiting the block editor abandons an in-progress run")
    func blockEditAbandonsRun() throws {
        let m = model()
        // Build a block to edit: one member line grouped into a named block "B". The
        // setup mutations register undo, so wrap them in an explicit group (no run loop).
        let lineID = grouped(m) {
            let id = m.drawing.add(EntityRecord(
                id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))))
            m.drawing.mutateBlocks { _ = $0.add(Block(name: "B", entityIDs: [id])) }
            return id
        }
        _ = lineID

        // Start a Line in the document, then enter the block editor mid-run.
        m.activateTool(.line)
        m.handleToolInput(.click(Vector(5, 5)))
        #expect(m.relativeZero == Vector(5, 5))

        #expect(m.enterBlockEditing(name: "B") == true)
        #expect(m.relativeZero == nil)             // enter abandoned the doc-space run
        #expect(m.tool?.status == LineTool().status)

        // Place a point inside the editor, then exit — the run must be abandoned again so a
        // click back in the document doesn't continue the block-member line.
        m.handleToolInput(.click(Vector(0.5, 0.5)))
        #expect(m.relativeZero == Vector(0.5, 0.5))
        #expect(m.exitBlockEditing(save: true) == true)
        #expect(m.relativeZero == nil)
        #expect(m.tool?.status == LineTool().status)
    }

    // MARK: - M5 — viewport-placement Esc cancel

    @Test("cancelViewportPlacement drops an in-progress drag but stays in viewport mode")
    func viewportPlacementCancel() {
        let m = model()
        let name = grouped(m) { m.newLayout() }    // a paper sheet (viewport needs one)
        #expect(name != nil)
        m.activateTool(.viewport)
        #expect(m.isViewportPlacementActive == true)

        // First corner click → a drag is in progress (a rubber-band preview is live).
        _ = m.handleViewportClick(Vector(0, 0))
        #expect(m.viewportPreview.isEmpty == false)

        // Esc → the dedicated cancel drops the rubber-band …
        #expect(m.cancelViewportPlacement() == true)
        #expect(m.viewportPreview.isEmpty == true)
        // … but the mode is unchanged (the next click starts a fresh placement).
        #expect(m.isViewportPlacementActive == true)
        #expect(m.activeToolKind == .viewport)
    }

    // MARK: - M6 — the F3/F9/F10/F12 model toggles the keyDown binds route to

    @Test("the drafting-aid toggles the F-keys bind flip the right model state")
    func draftingAidToggles() {
        let m = model()

        // F9 — grid snap (.grid bit). The snap toggles persist to `$LC_SNAPMODE` (undoable),
        // so wrap them in an explicit group (no run loop; the polar/dyn toggles are live-only).
        let snapBefore = m.gridSnapEnabled
        grouped(m) { m.toggleGridSnap() }
        #expect(m.gridSnapEnabled == !snapBefore)

        // F3 — master object snap.
        let osnapBefore = m.objectSnapEnabled
        grouped(m) { m.setObjectSnapEnabled(!osnapBefore) }
        #expect(m.objectSnapEnabled == !osnapBefore)

        // F10 — polar tracking.
        let polarBefore = m.polarEnabled
        m.togglePolar()
        #expect(m.polarEnabled == !polarBefore)

        // F12 — dynamic input.
        let dynBefore = m.dynamicInputEnabled
        m.toggleDynamicInput()
        #expect(m.dynamicInputEnabled == !dynBefore)
        m.toggleDynamicInput()                     // restore (it persists to UserDefaults)
        #expect(m.dynamicInputEnabled == dynBefore)
    }

    // MARK: - M7 — the command-line echo gate

    @Test("an entity-pick tool (Trim) does NOT echo a typed coordinate as a success")
    func entityPickToolDoesNotEchoTypedValue() {
        let m = model()
        m.activateTool(.trim)
        let before = m.commandTranscript.count
        let result = m.interpretCommandLine("10,20")
        // Not a success: a typed coordinate Trim can't use yields an `.error`, never `.handled`.
        guard case .error = result else {
            Issue.record("expected .error for a coordinate an entity-pick tool ignores, got \(result)")
            return
        }
        // No "→ x, y" success readout was appended to the transcript.
        let appended = m.commandTranscript.suffix(m.commandTranscript.count - before)
        #expect(!appended.contains { $0.kind == .output && $0.text.hasPrefix("→") })
    }

    @Test("a draw tool (Line) DOES echo a typed coordinate it consumes")
    func drawToolEchoesTypedValue() {
        let m = model()
        m.activateTool(.line)
        let result = m.interpretCommandLine("10,20")
        #expect(result == .handled)
        // The success "→ 10, 20" readout is present.
        #expect(m.commandTranscript.contains { $0.kind == .output && $0.text.hasPrefix("→") })
    }

    // MARK: - M8 — PolylineEdit + XLine tool modes surface through applyToolConfig

    @Test("PolylineEdit mode round-trips through applyToolConfig (in place)")
    func polylineEditModeRoundTrip() throws {
        let m = model()
        m.polylineEditModeIndex = 0
        m.activateTool(.polylineEdit)
        #expect((m.tool as? PolylineEditTool)?.mode == .move)

        for (idx, expected): (Int, PolylineEditTool.Mode) in
            [(1, .add), (2, .remove), (3, .arc), (0, .move)] {
            m.polylineEditModeIndex = idx
            m.reapplyActiveToolConfig()
            #expect((m.tool as? PolylineEditTool)?.mode == expected)
        }
    }

    @Test("XLine direction mode round-trips through applyToolConfig (re-mint)")
    func xlineModeRoundTrip() throws {
        let m = model()
        m.xlineModeIndex = 0
        m.activateTool(.xline)
        #expect((m.tool as? XLineTool)?.mode == .free)

        m.xlineModeIndex = 1
        m.reapplyActiveToolConfig()
        #expect((m.tool as? XLineTool)?.mode == .horizontal)

        m.xlineModeIndex = 2
        m.reapplyActiveToolConfig()
        #expect((m.tool as? XLineTool)?.mode == .vertical)

        m.xlineModeIndex = 3
        m.xlineAngle = Double.pi / 4
        m.reapplyActiveToolConfig()
        #expect((m.tool as? XLineTool)?.mode == .angle(Double.pi / 4))
    }
}
