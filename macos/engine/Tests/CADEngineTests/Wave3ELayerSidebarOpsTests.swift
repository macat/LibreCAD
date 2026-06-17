//
//  Wave3ELayerSidebarOpsTests.swift
//  CADEngineTests
//
//  Pins the CanvasModel CONTRACTS the Wave-3E Layers-sidebar layer-operation items rely
//  on — the row context menu / panel header verbs delegate to these funnels:
//
//   • "Make Current"            → `makeLayerCurrent(_:)`        (CLAYER; undoable, no-op gated)
//   • "Isolate (Hide Others)"   → `isolateLayer(_:)`           (LAYISO; sets hasIsolatedLayers)
//   • "Turn Off Other Layers"   → `turnOffOtherLayers(except:)` (LAYOFF; freeze others, no stash)
//   • "Unisolate Layers"        → `unisolateLayers()`          (LAYUNISO; gated on hasIsolatedLayers)
//   • "Isolate Selection's…"    → `isolateSelectionLayers()`   (LAYISO from selection)
//   • "Select Entities on Layer"→ `applyQuickSelect(QuickSelectFilter(layer:), .replace)`
//
//  The sidebar is a thin View-layer adapter (no testable logic of its own beyond these
//  calls); these tests assert the funnels behave as the items assume — in particular that a
//  layer-only quick-select filter is the right vehicle for "select every entity on a layer"
//  (selects exactly that layer's selectable entities), and that the isolate / make-current
//  gates the items read (`hasIsolatedLayers`, the `@discardableResult` Bools) flip as wired.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the existing
//  `_SharedCanvasModel.swift` symlink. `@MainActor` like the other CanvasModel suites; no
//  modal is reachable from any path under test. Uniquely namespaced to avoid collisions.
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
@Suite("Wave 3E — Layers sidebar layer-operation wiring contracts")
struct Wave3ELayerSidebarOpsTests {

    // MARK: - Fixtures

    private func makeModel(_ drawing: CADDrawing) -> CanvasModel {
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        return model
    }

    private func line(_ id: UInt64 = 0, layer: String) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     layer: LayerID(layer),
                     pen: Pen(lineColor: .byLayer, lineType: .byLayer, lineWidth: .byLayer),
                     flags: .default,
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
    }

    /// A drawing with layers "0" / "walls" / "doors" and two entities on each non-default
    /// layer. Returns the model plus a name→id map of the minted ids.
    private func threeLayerModel() -> (model: CanvasModel, ids: [String: EntityID]) {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "walls"))
        _ = d.addLayer(Layer(name: "doors"))
        var ids: [String: EntityID] = [:]
        ids["wallA"] = d.add(line(layer: "walls"))
        ids["wallB"] = d.add(line(layer: "walls"))
        ids["doorA"] = d.add(line(layer: "doors"))
        ids["doorB"] = d.add(line(layer: "doors"))
        return (makeModel(d), ids)
    }

    // MARK: - "Select Entities on Layer" (layer-only quick-select filter → replace)

    @Test("Select Entities on Layer selects EXACTLY the layer's entities, replacing the prior selection")
    func selectEntitiesOnLayer() {
        let (model, ids) = threeLayerModel()
        model.selection = Selection(ids: [ids["doorA"]!])   // unrelated prior selection

        // The exact funnel call the sidebar item makes.
        let changed = model.applyQuickSelect(QuickSelectFilter(layer: "walls"), mode: .replace)

        #expect(changed)
        #expect(model.selection.ids == [ids["wallA"]!, ids["wallB"]!])
    }

    @Test("Select Entities on Layer skips entities on a FROZEN/hidden layer (selectability gate)")
    func selectEntitiesOnLayerSkipsFrozen() {
        // Build the drawing with "walls" already frozen BEFORE attaching the model's
        // UndoManager (mirrors the QuickSelect locked-layer fixture: a direct drawing
        // mutation under `groupsByEvent = false` would need an explicit undo group).
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "walls", isFrozen: true))
        _ = d.addLayer(Layer(name: "doors"))
        let wallID = d.add(line(layer: "walls"))
        _ = d.add(line(layer: "doors"))
        let model = makeModel(d)

        // Selecting "walls" entities now lands on nothing (gated out); replace clears.
        let changed = model.applyQuickSelect(QuickSelectFilter(layer: "walls"), mode: .replace)
        #expect(!changed)               // selection was already empty → no change
        #expect(model.selection.isEmpty)
        #expect(!model.selection.ids.contains(wallID))
    }

    // MARK: - "Make Current" (CLAYER) gate

    @Test("Make Current activates the layer; re-invoking on the active layer is a no-op")
    func makeCurrent() {
        let (model, _) = threeLayerModel()
        #expect(model.drawing.layers.activeLayerName != "doors")

        let changed = model.makeLayerCurrent("doors")
        #expect(changed)
        #expect(model.drawing.layers.activeLayerName == "doors")

        // The item enables unconditionally; the funnel itself no-ops when already current.
        let again = model.makeLayerCurrent("doors")
        #expect(!again)
        #expect(model.drawing.layers.activeLayerName == "doors")
    }

    // MARK: - Isolate / Unisolate gate (drives the items' enabled state)

    @Test("Isolate sets hasIsolatedLayers; Unisolate clears it and is a no-op when nothing is isolated")
    func isolateUnisolateGate() {
        let (model, _) = threeLayerModel()
        #expect(!model.hasIsolatedLayers)               // Unisolate item disabled initially

        model.isolateLayer("walls")
        #expect(model.hasIsolatedLayers)                // Unisolate item now enabled
        #expect(!model.drawing.layers.layer(named: "doors")!.isVisible)   // others hidden
        #expect(model.drawing.layers.layer(named: "walls")!.isVisible)

        let restored = model.unisolateLayers()
        #expect(restored)
        #expect(!model.hasIsolatedLayers)               // Unisolate item disabled again
        #expect(model.drawing.layers.layer(named: "doors")!.isVisible)    // restored

        // A second Unisolate with no isolation in effect is a no-op (item is disabled).
        #expect(!model.unisolateLayers())
    }

    @Test("Isolate Selection's Layers isolates every layer the selection lives on")
    func isolateSelectionLayers() {
        let (model, ids) = threeLayerModel()
        model.selection = Selection(ids: [ids["wallA"]!])   // selection on "walls" only

        let changed = model.isolateSelectionLayers()
        #expect(changed)
        #expect(model.hasIsolatedLayers)
        #expect(model.drawing.layers.layer(named: "walls")!.isVisible)
        #expect(!model.drawing.layers.layer(named: "doors")!.isVisible)

        // Empty selection → nothing to isolate (the header item is gated on a selection,
        // but the funnel is also a no-op for safety).
        _ = model.unisolateLayers()
        model.selection = Selection()
        #expect(!model.isolateSelectionLayers())
    }

    // MARK: - "Turn Off Other Layers" (LAYOFF) — freeze others without a restore stash

    @Test("Turn Off Other Layers freezes every other layer WITHOUT stashing a restore")
    func turnOffOtherLayers() {
        let (model, _) = threeLayerModel()

        let changed = model.turnOffOtherLayers(except: "walls")
        #expect(changed)
        #expect(model.drawing.layers.layer(named: "walls")!.isVisible)
        #expect(!model.drawing.layers.layer(named: "doors")!.isVisible)
        #expect(!model.drawing.layers.layer(named: "0")!.isVisible)
        // LAYOFF is distinct from LAYISO: it leaves NO isolation-restore (Unisolate stays off).
        #expect(!model.hasIsolatedLayers)
    }
}
