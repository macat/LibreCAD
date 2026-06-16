//
//  ColorSwatchPickerTests.swift
//  CADEngineTests
//
//  Regression coverage for the dense-bar COLOR SWATCH change: the layer-row and
//  current-pen color wells were swapped from the stock ~44×22pt `NSColorWell` pill
//  (`ColorPicker("").labelsHidden().frame(width:)` — which ignores `.frame(width:)`)
//  to a small 16pt `ColorSwatchPicker` chip that opens the picker in a popover.
//
//  SwiftUI view-metric assertions (the 16×16 chip size) aren't feasible headlessly,
//  so these tests assert the MODEL CONTRACT the swap must preserve — the part a
//  regression would actually break:
//
//   1. LAYER COLOR — the swatch's binding writes through the SAME undoable funnel the
//      old well used (`onColorChange` → `setColor`/`mutateLayers`): a color edit
//      mutates the layer, round-trips, and is undoable/redoable. The swatch's GET
//      reads `layer.color` directly (the fix for the one-frame `.green` flash), so a
//      freshly created layer's swatch shows ITS color, never green.
//   2. CURRENT PEN COLOR — the bar's `explicitColorBinding` set-path (now driven by
//      ColorSwatchPicker instead of the well) still writes `currentPen.lineColor`,
//      which flows onto the next drawn entity via the Stage-1 stamp.
//
//  These exercise the EXACT engine paths the (private) view bindings drive, mirroring
//  the contract-test style of PenPropertiesTests / DeleteUndoTests.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Color swatch picker — dense-bar color edits preserve the model + undo path")
struct ColorSwatchPickerTests {

    // MARK: - 1. Layer color: the swatch binding's write path (onColorChange → setColor)

    @Test("a layer color edit via the sidebar funnel mutates the layer and is undoable")
    func layerColorIsSettableAndUndoable() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Walls", color: RGBAColor(0, 0, 1))))
        model.drawing.undoManager?.removeAllActions()

        // The layer starts on the color it was BORN with — never `.green`. (This is the
        // value `ColorSwatchPicker`'s GET reads via `layer.color`, so the chip shows
        // ITS color immediately with no first-frame flash.)
        #expect(model.drawing.layers.layer(named: "Walls")?.color == RGBAColor(0, 0, 1))

        // The EXACT engine path the sidebar's private `setColor` callback drives — what
        // `colorBinding.set` → `onColorChange` funnels into. (Swapping the stock well
        // for the swatch must NOT change this wiring.)
        let red = RGBAColor(1, 0, 0)
        model.drawing.mutateLayers { $0.setColor("Walls", red) }
        #expect(model.drawing.layers.layer(named: "Walls")?.color == red)

        model.undo()
        #expect(model.drawing.layers.layer(named: "Walls")?.color == RGBAColor(0, 0, 1))

        model.redo()
        #expect(model.drawing.layers.layer(named: "Walls")?.color == red)
    }

    @Test("a freshly added layer reports its OWN color (no .green seed)")
    func freshLayerHasItsOwnColorNotGreen() {
        let model = CanvasModel()
        let cyan = RGBAColor(0, 1, 1)
        #expect(model.drawing.addLayer(Layer(name: "Grid", color: cyan)))
        // The value the swatch's GET reads is the layer's real color, not a `.green`
        // placeholder — so there is no green first frame.
        #expect(model.drawing.layers.layer(named: "Grid")?.color == cyan)
    }

    // MARK: - 2. Current pen color: the bar's explicit-color binding set-path

    @Test("the current-pen explicit color (swatch binding) flows into new geometry")
    func currentPenExplicitColorDrivesNewGeometry() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Walls")))
        model.drawing.setActiveLayer("Walls")
        model.drawing.undoManager?.removeAllActions()

        // Exactly what CurrentPropertiesBar's `explicitColorBinding.set` (now driven by
        // ColorSwatchPicker) writes: an explicit pen color on `model.currentPen`.
        let blue = RGBAColor(0, 0, 1)
        model.currentPen.lineColor = .explicit(blue)

        // A freshly drawn default line is stamped with currentPen via applyCommit.
        model.applyToolEdits([
            .add(EntityRecord(id: .placeholder,
                              kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        ])

        let recs = model.drawing.entities
        #expect(recs.count == 1)
        #expect(recs.first?.pen.lineColor == .explicit(blue))
    }
}
