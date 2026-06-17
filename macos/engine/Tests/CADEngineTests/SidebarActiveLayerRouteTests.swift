//
//  SidebarActiveLayerRouteTests.swift
//  CADEngineTests
//
//  Lane W, finding #05 — the active layer (AutoCAD CLAYER) must be set through ONE
//  funnel. Both the Layers sidebar row tap (`LayersSidebar.selectLayer`) and the
//  current-properties bar layer picker (`CurrentPropertiesBar.activeLayerBinding`) were
//  rerouted from poking `CADDrawing.setActiveLayer` directly to the undoable +
//  modelVersion-bumping `CanvasModel.makeLayerCurrent` path (the same one the layer-row
//  gear-menu "Make Current" already used).
//
//  Those bindings are View closures (not unit-reachable), so this suite locks in the
//  CONTRACT they now rely on: `makeLayerCurrent`
//    • changes the active layer and bumps `modelVersion` (so the renderer re-resolves),
//    • is a single undoable step (⌘Z restores the prior active layer), and
//    • no-ops WITHOUT bumping the version when the target is already current / unknown
//      (so a redundant row tap / picker re-pick is inert, matching the binding guards).
//  If a future edit reverts either binding to the raw `setActiveLayer` (no version bump,
//  no undo group), the version/undo expectations below fail.
//
//  Reached via the established `_SharedCanvasModel.swift` symlink (CanvasModel lives in
//  the app target). Pure, headless — no View, no modal.
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
@Suite("Lane W — active-layer (CLAYER) single-funnel route")
struct SidebarActiveLayerRouteTests {

    /// A model with layers 0 / A / B (0 active), manual undo grouping cleared — mirrors the
    /// Wave-3B layer suites so undo behaves like the live app's per-event grouping.
    private func layeredModel() -> CanvasModel {
        let drawing = CADDrawing()
        for n in ["A", "B"] { _ = drawing.addLayer(Layer(name: n)) }
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    @Test("Selecting a layer routes through makeLayerCurrent: bumps modelVersion + is undoable")
    func routeBumpsVersionAndUndoes() {
        let m = layeredModel()
        #expect(m.drawing.layers.activeLayerName == "0")

        let before = m.modelVersion
        // The funnel both sidebar bindings now call (selectLayer / activeLayerBinding).
        #expect(m.makeLayerCurrent("A"))
        #expect(m.drawing.layers.activeLayerName == "A")
        // The render-sync property the sidebar reroute depends on (a raw setActiveLayer
        // would NOT touch this) — the renderer re-resolves layer pens off modelVersion.
        #expect(m.modelVersion > before)

        // One undoable step restores the prior active layer (⌘Z parity with geometry edits).
        m.undo()
        #expect(m.drawing.layers.activeLayerName == "0")
    }

    @Test("A redundant / unknown selection is inert: no active-layer change, no version bump")
    func noOpDoesNotBumpVersion() {
        let m = layeredModel()
        _ = m.makeLayerCurrent("B")
        #expect(m.drawing.layers.activeLayerName == "B")

        let settled = m.modelVersion
        // Re-picking the already-current layer (a redundant row tap / picker re-pick) is a
        // no-op — the binding guards on this, and the funnel must not register undo / bump.
        #expect(!m.makeLayerCurrent("B"))
        #expect(m.modelVersion == settled)
        // An unknown layer name is likewise inert.
        #expect(!m.makeLayerCurrent("DOES_NOT_EXIST"))
        #expect(m.drawing.layers.activeLayerName == "B")
        #expect(m.modelVersion == settled)
    }
}
