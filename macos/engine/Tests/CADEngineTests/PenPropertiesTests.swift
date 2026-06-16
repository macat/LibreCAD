//
//  PenPropertiesTests.swift
//  CADEngineTests
//
//  Covers the CURRENT-PROPERTIES feature (AutoCAD's CLAYER + CECOLOR/CELTYPE/
//  CELWEIGHT) that lets new geometry adopt the active layer + a chosen pen, plus the
//  per-LAYER line-type / line-width defaults the Layers sidebar sets.
//
//  Three behaviors, all driven through the REAL app paths:
//   1. STAMP — a freshly drawn record (the EntityRecord init defaults: layer "0" + a
//      fully `.byLayer` pen) is stamped, by `CanvasModel.applyCommit`'s `.add` arm,
//      with the ACTIVE layer and the model's `currentPen`. This is the fix for the
//      long-standing bug where every drawn entity landed on layer "0" regardless of
//      the active layer.
//   2. GATE — a MODIFY tool that clones a source entity (CopyTool/array) sets the
//      clone's `layer`+`pen` from the source; the stamp must LEAVE those alone (it
//      only fires on the narrow init-default signature). A non-default source pen
//      survives a clone unchanged.
//   3. LAYER DEFAULTS — the sidebar's line-type / line-width controls funnel through
//      `CADDrawing.mutateLayers` + `LayerTable.setLineType`/`setLineWidth`; the edit
//      mutates the layer and is undoable (the exact engine path the private sidebar
//      callbacks drive — exercised here as a contract test, mirroring DeleteUndoTests).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Current-properties stamp + per-layer pen defaults")
struct PenPropertiesTests {

    // MARK: - Helpers

    /// A plain default line record exactly as a draw tool emits it: placeholder id,
    /// layer "0", a fully `.byLayer` pen. This is the signature the stamp keys off.
    private func defaultDrawnLine() -> EntityRecord {
        EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    /// A model with a second layer "Walls" added and made active, so a stamp lands on
    /// something other than "0" (otherwise the active-layer fix is unobservable).
    private func modelWithActiveLayer(_ name: String) -> CanvasModel {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: name)))
        model.drawing.setActiveLayer(name)
        // The setup layer ops above register undo; clear so a later undo test only sees
        // the action under test.
        model.drawing.undoManager?.removeAllActions()
        return model
    }

    /// The single record currently in the drawing (the one just added). Fails the test
    /// if there isn't exactly one.
    private func soleRecord(_ model: CanvasModel) -> EntityRecord? {
        let recs = model.drawing.entities
        #expect(recs.count == 1)
        return recs.first
    }

    // MARK: - 1. STAMP: drawn entity adopts active layer + currentPen

    @Test("a drawn entity is stamped with the active layer (fixes the layer-0 bug)")
    func drawnEntityAdoptsActiveLayer() {
        let model = modelWithActiveLayer("Walls")
        // currentPen left at its default (.byLayer) — only the layer should change.
        model.applyToolEdits([.add(defaultDrawnLine())])

        let rec = soleRecord(model)
        #expect(rec?.layer == LayerID("Walls"))   // NOT "0" — the bug is fixed
        #expect(rec?.pen == .byLayer)              // default currentPen
    }

    @Test("a drawn entity adopts the model's currentPen (CECOLOR/CELTYPE/CELWEIGHT)")
    func drawnEntityAdoptsCurrentPen() {
        let model = modelWithActiveLayer("Walls")
        let red = RGBAColor(1, 0, 0)
        model.currentPen = Pen(
            lineColor: .explicit(red),
            lineType: .dashed,
            lineWidth: .millimeters(0.5)
        )
        model.applyToolEdits([.add(defaultDrawnLine())])

        let rec = soleRecord(model)
        #expect(rec?.layer == LayerID("Walls"))
        #expect(rec?.pen.lineColor == .explicit(red))
        #expect(rec?.pen.lineType == .dashed)
        #expect(rec?.pen.lineWidth == .millimeters(0.5))
    }

    @Test("the active-layer stamp lands on whichever layer is active at draw time")
    func stampFollowsActiveLayer() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "A")))
        #expect(model.drawing.addLayer(Layer(name: "B")))
        model.drawing.setActiveLayer("B")
        model.applyToolEdits([.add(defaultDrawnLine())])
        #expect(model.drawing.entities.first?.layer == LayerID("B"))
    }

    // MARK: - 2. GATE: a clone keeps its source layer/pen (not clobbered)

    @Test("a Copy/clone with a non-default pen is NOT clobbered by the stamp")
    func clonePenSurvivesStamp() {
        let model = modelWithActiveLayer("Walls")
        // The model's currentPen is something LOUD that must NOT leak onto the clone.
        model.currentPen = Pen(lineColor: .explicit(RGBAColor(1, 0, 0)), lineType: .dotted)

        // A clone as CopyTool builds it: explicit source layer + source pen carried
        // verbatim onto a placeholder-id `.add`.
        let blue = RGBAColor(0, 0, 1)
        let clone = EntityRecord(
            id: .placeholder,
            layer: LayerID("Steel"),                          // non-default layer
            pen: Pen(lineColor: .explicit(blue), lineType: .center, lineWidth: .millimeters(0.7)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 5)))
        )
        model.applyToolEdits([.add(clone)])

        let rec = soleRecord(model)
        // The clone's own attributes survive — the stamp left it alone.
        #expect(rec?.layer == LayerID("Steel"))
        #expect(rec?.pen.lineColor == .explicit(blue))
        #expect(rec?.pen.lineType == .center)
        #expect(rec?.pen.lineWidth == .millimeters(0.7))
    }

    @Test("a clone on a non-default LAYER but byLayer pen is still NOT stamped")
    func cloneNonDefaultLayerSurvives() {
        let model = modelWithActiveLayer("Walls")
        model.currentPen = Pen(lineColor: .explicit(RGBAColor(1, 0, 0)))
        let clone = EntityRecord(
            id: .placeholder,
            layer: LayerID("Steel"),     // non-default layer ⇒ fails the stamp gate
            pen: .byLayer,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        )
        model.applyToolEdits([.add(clone)])

        let rec = soleRecord(model)
        #expect(rec?.layer == LayerID("Steel"))   // kept, not re-stamped to "Walls"
        #expect(rec?.pen == .byLayer)             // currentPen did NOT leak on
    }

    // MARK: - 2b. CLONE GATE BY OPERATION: a real Copy/Array of a layer-"0" /
    //            byLayer source preserves layer "0" even with a DIFFERENT active layer.
    //
    // The content gate alone (`layer == .zero && pen == .byLayer`) CANNOT tell a fresh
    // draw from a clone of a bare layer-"0"/byLayer source — both look identical. These
    // tests drive the REAL clone tools (Copy / Array) end-to-end through the model
    // (`activateTool` + `handleToolInput`), so the discriminator under test is the
    // ORIGINATING OPERATION, not the record contents. AutoCAD COPY/ARRAY/OFFSET preserve
    // the source layer; so must we. (These FAIL before the operation-aware gate — the
    // clone would be re-stamped onto the active layer — and PASS after.)

    /// Adds a source line on layer "0" with a fully `.byLayer` pen (the fresh-doc
    /// default — the exact ambiguous signature) and selects it. Returns its id.
    @discardableResult
    private func addSelectedLayerZeroSource(_ model: CanvasModel) -> EntityID {
        let id = model.drawing.add(EntityRecord(
            id: .placeholder,
            layer: .zero,                 // DXF "0"
            pen: .byLayer,                // the fresh-doc default
            kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0)))
        ))
        model.setSelection([id])
        // Clear the undo registered by the setup add so it can't muddy later assertions.
        model.drawing.undoManager?.removeAllActions()
        return id
    }

    @Test("a COPY of a layer-0 / byLayer source keeps layer 0 (NOT the active layer)")
    func copyOfLayerZeroSourcePreservesLayerZero() {
        let model = modelWithActiveLayer("Walls")     // a DIFFERENT layer is active
        // A loud currentPen that must NOT leak onto the clone either.
        model.currentPen = Pen(lineColor: .explicit(RGBAColor(1, 0, 0)), lineType: .dotted)
        let sourceID = addSelectedLayerZeroSource(model)

        // Drive the REAL Copy tool: base point, then destination (a non-zero delta).
        model.activateTool(.copy)
        _ = model.handleToolInput(.click(Vector(0, 0)))   // base
        _ = model.handleToolInput(.click(Vector(20, 0)))  // destination → commit one .add

        // Two entities now: the original + the copy. The COPY must still be on layer "0"
        // with a byLayer pen — preserved from its source, NOT re-stamped onto "Walls".
        let recs = model.drawing.entities
        #expect(recs.count == 2)
        let copy = recs.first { $0.id != sourceID }
        #expect(copy?.layer == .zero)        // BUG repro: was wrongly re-stamped to "Walls"
        #expect(copy?.pen == .byLayer)       // currentPen did NOT leak onto the clone
        // The original is untouched too.
        let original = recs.first { $0.id == sourceID }
        #expect(original?.layer == .zero)
        #expect(original?.pen == .byLayer)
    }

    @Test("an ARRAY of a layer-0 / byLayer source keeps every copy on layer 0")
    func arrayOfLayerZeroSourcePreservesLayerZero() {
        let model = modelWithActiveLayer("Walls")
        model.currentPen = Pen(lineColor: .explicit(RGBAColor(0, 1, 0)))
        let sourceID = addSelectedLayerZeroSource(model)

        // Drive the REAL Array tool. ArrayTool replicates the selection in a grid and
        // commits on Return; its default config produces at least one extra copy.
        model.activateTool(.array)
        _ = model.handleToolInput(.commit)

        let recs = model.drawing.entities
        // Every CLONE (anything that isn't the original) must remain on layer "0".
        let clones = recs.filter { $0.id != sourceID }
        #expect(!clones.isEmpty)             // the array produced at least one copy
        for clone in clones {
            #expect(clone.layer == .zero)    // preserved, not re-stamped to "Walls"
            #expect(clone.pen == .byLayer)
        }
    }

    @Test("a fresh DRAW via the real tool path still adopts the active layer + currentPen")
    func freshDrawViaRealToolStillAdoptsCurrentProperties() {
        // The companion to the clone tests: the operation-aware gate must NOT regress the
        // layer-0 fix — a genuine DRAW (Line tool) still lands on the active layer.
        let model = modelWithActiveLayer("Walls")
        let blue = RGBAColor(0, 0, 1)
        model.currentPen = Pen(lineColor: .explicit(blue), lineType: .dashed)

        model.activateTool(.line)
        _ = model.handleToolInput(.click(Vector(0, 0)))
        _ = model.handleToolInput(.click(Vector(10, 0)))   // commits one .add line

        // Exactly one entity was drawn — the line.
        #expect(model.drawing.entities.count == 1)
        let drawn = model.drawing.entities.first
        #expect(drawn?.layer == LayerID("Walls"))          // adopted the active layer
        #expect(drawn?.pen.lineColor == .explicit(blue))   // adopted currentPen
        #expect(drawn?.pen.lineType == .dashed)
    }

    // MARK: - 3. LAYER DEFAULTS: setLineType / setLineWidth via the sidebar funnel

    @Test("setting a layer's default line TYPE mutates the layer and is undoable")
    func layerLineTypeIsSettableAndUndoable() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Walls")))
        model.drawing.undoManager?.removeAllActions()
        #expect(model.drawing.layers.layer(named: "Walls")?.lineType == .solid)

        // The exact engine path the sidebar's private `setLineType` callback drives.
        model.drawing.mutateLayers { $0.setLineType("Walls", .dashed) }
        #expect(model.drawing.layers.layer(named: "Walls")?.lineType == .dashed)

        model.undo()
        #expect(model.drawing.layers.layer(named: "Walls")?.lineType == .solid)

        model.redo()
        #expect(model.drawing.layers.layer(named: "Walls")?.lineType == .dashed)
    }

    @Test("setting a layer's default line WIDTH mutates the layer and is undoable")
    func layerLineWidthIsSettableAndUndoable() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Walls")))
        model.drawing.undoManager?.removeAllActions()
        #expect(model.drawing.layers.layer(named: "Walls")?.lineWidth == .default)

        // The exact engine path the sidebar's private `setLineWidth` callback drives.
        model.drawing.mutateLayers { $0.setLineWidth("Walls", .millimeters(0.35)) }
        #expect(model.drawing.layers.layer(named: "Walls")?.lineWidth == .millimeters(0.35))

        model.undo()
        #expect(model.drawing.layers.layer(named: "Walls")?.lineWidth == .default)

        model.redo()
        #expect(model.drawing.layers.layer(named: "Walls")?.lineWidth == .millimeters(0.35))
    }

    // MARK: - PenPickers vocabulary (pure, no view)

    @Test("LineTypePicker offers every concrete dash pattern with a display name")
    func lineTypePickerVocabulary() {
        // The concrete (non-sentinel) cases the layer picker shows.
        #expect(LineTypePicker.concreteCases == [
            .solid, .dashed, .dotted, .dashDot, .center, .border, .divide,
        ])
        #expect(LineTypePicker.displayName(.byLayer) == "By Layer")
        #expect(LineTypePicker.displayName(.dashDot) == "Dash-Dot")
    }

    @Test("LineWidthPicker offers the standard ladder + readable labels")
    func lineWidthPickerVocabulary() {
        // Sorted ascending, includes the common 0.25 / 0.35 / 0.50 steps.
        let ladder = LineWidthPicker.standardMillimeters
        #expect(ladder == ladder.sorted())
        #expect(ladder.contains(0.25))
        #expect(ladder.contains(0.35))
        #expect(ladder.contains(0.50))
        #expect(LineWidthPicker.displayName(.byLayer) == "By Layer")
        #expect(LineWidthPicker.displayName(.default) == "Default")
        #expect(LineWidthPicker.displayName(.millimeters(0.25)) == "0.25 mm")
    }

    // MARK: - 4. STAGE 2: top-bar current-properties control contract
    //
    // The CurrentPropertiesBar only mutates two pieces of LIVE model state — the
    // active layer (via `setActiveLayer`) and `model.currentPen` (its color/type/width
    // bindings). It reaches NO modal and touches no existing geometry. These tests
    // exercise that exact contract: a state change made the way the bar's bindings make
    // it flows into the next drawn entity through the Stage-1 stamp, and an existing
    // entity is left untouched.

    @Test("the bar's currentPen color binding flows into newly drawn geometry")
    func currentPenColorBindingDrivesNewGeometry() {
        let model = modelWithActiveLayer("Walls")
        // Exactly what the color control's bindings write: switch to explicit, set color.
        model.currentPen.lineColor = .explicit(.black)          // mode → explicit
        model.currentPen.lineColor = .explicit(RGBAColor(0, 0, 1))  // pick blue
        model.applyToolEdits([.add(defaultDrawnLine())])
        #expect(soleRecord(model)?.pen.lineColor == .explicit(RGBAColor(0, 0, 1)))
    }

    @Test("the bar's layer picker changes where the NEXT entity is drawn, not prior ones")
    func currentLayerPickerAffectsOnlyFutureGeometry() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "A")))
        #expect(model.drawing.addLayer(Layer(name: "B")))

        // Draw one on A.
        model.drawing.setActiveLayer("A")
        model.applyToolEdits([.add(defaultDrawnLine())])
        let firstID = model.drawing.entities.first?.id

        // The bar's layer binding switches the active layer to B.
        model.drawing.setActiveLayer("B")
        model.applyToolEdits([.add(EntityRecord(id: .placeholder,
                                                kind: .line(LineData(start: Vector(1, 1), end: Vector(2, 2)))))])

        // The first entity stayed on A; the second landed on B.
        let onA = model.drawing.entities.first { $0.id == firstID }
        let onB = model.drawing.entities.first { $0.id != firstID }
        #expect(onA?.layer == LayerID("A"))
        #expect(onB?.layer == LayerID("B"))
    }

    @Test("currentPen defaults to a fully .byLayer pen (the bar's default state)")
    func currentPenDefaultsToByLayer() {
        let model = CanvasModel()
        #expect(model.currentPen == .byLayer)
        #expect(model.currentPen.lineColor == .byLayer)
        #expect(model.currentPen.lineType == .byLayer)
        #expect(model.currentPen.lineWidth == .byLayer)
    }
}
