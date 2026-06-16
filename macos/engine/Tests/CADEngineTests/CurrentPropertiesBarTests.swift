//
//  CurrentPropertiesBarTests.swift
//  CADEngineTests
//
//  Contract coverage for Wave 3's CurrentPropertiesBar 3-control disambiguation
//  (see `CurrentPropertiesBar.swift`). The bar's three look-alike "By Layer" pickers
//  were given distinct identifiers (swatch / dash preview / weight preview + a micro-
//  caption), but the WIRING they drive must be unchanged: each pen control reads/writes
//  `model.currentPen`, and the layer control reads/writes the drawing's active layer.
//
//  SwiftUI view metrics (the captions, the preview chips, the `DS.Field.wide` widths)
//  aren't headless-assertable, so — per the project convention (cf.
//  `ColorSwatchPickerTests`) — these assert the EXACT engine paths the bar's private
//  bindings drive, which is the part a regression would actually break.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Current-properties bar — the 3 pen controls + layer control drive currentPen / active layer")
struct CurrentPropertiesBarTests {

    // MARK: - Color control (CECOLOR) — writes currentPen.lineColor

    @Test("the color control's mode + explicit color flow into currentPen.lineColor")
    func colorControlWritesCurrentPen() {
        let model = CanvasModel()
        // Default new geometry inherits its color from the layer.
        #expect(model.currentPen.lineColor == .byLayer)

        // The mode binding's Explicit branch seeds black, then the swatch binding sets a
        // concrete color (the exact paths `colorModeBinding` / `explicitColorBinding` drive).
        model.currentPen.lineColor = .explicit(.black)
        if case .explicit(let c) = model.currentPen.lineColor {
            #expect(c == RGBAColor(0, 0, 0))
        } else {
            Issue.record("expected an explicit color")
        }

        model.currentPen.lineColor = .explicit(RGBAColor(1, 0, 0))
        if case .explicit(let c) = model.currentPen.lineColor {
            #expect(c == RGBAColor(1, 0, 0))
        } else {
            Issue.record("expected an explicit color")
        }

        // Back to By Layer.
        model.currentPen.lineColor = .byLayer
        #expect(model.currentPen.lineColor == .byLayer)
    }

    // MARK: - Line-type control (CELTYPE) — writes currentPen.lineType

    @Test("the type control writes currentPen.lineType")
    func typeControlWritesCurrentPen() {
        let model = CanvasModel()
        #expect(model.currentPen.lineType == .byLayer)   // inherit default

        model.currentPen.lineType = .dashed
        #expect(model.currentPen.lineType == .dashed)

        model.currentPen.lineType = .center
        #expect(model.currentPen.lineType == .center)
    }

    // MARK: - Line-width control (CELWEIGHT) — writes currentPen.lineWidth

    @Test("the width control writes currentPen.lineWidth")
    func widthControlWritesCurrentPen() {
        let model = CanvasModel()
        #expect(model.currentPen.lineWidth == .byLayer)  // inherit default

        model.currentPen.lineWidth = .millimeters(0.5)
        #expect(model.currentPen.lineWidth == .millimeters(0.5))

        model.currentPen.lineWidth = .default
        #expect(model.currentPen.lineWidth == .default)
    }

    // MARK: - Layer control (CLAYER) — writes the drawing's active layer

    @Test("the layer control activates the chosen layer (CLAYER)")
    func layerControlSetsActiveLayer() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Walls")))

        let original = model.drawing.layers.activeLayerName
        model.drawing.setActiveLayer("Walls")
        #expect(model.drawing.layers.activeLayerName == "Walls")
        #expect(model.drawing.layers.activeLayerName != original)
    }

    // MARK: - PenPickers vocabulary is stable (rows now carry previews)

    @Test("adding previews to PenPicker rows did not change the offered vocabulary")
    func penPickerVocabularyUnchanged() {
        // The current-pen pickers offer By Layer + the concrete cases (the rows now
        // also show a dash/weight preview, but the TAGS — the values written — are the
        // same). Spot-check the concrete sets are intact.
        #expect(LineTypePicker.concreteCases.contains(.solid))
        #expect(LineTypePicker.concreteCases.contains(.center))
        #expect(LineTypePicker.displayName(.dashDot) == "Dash-Dot")

        #expect(LineWidthPicker.standardMillimeters.contains(0.25))
        #expect(LineWidthPicker.displayName(.byLayer) == "By Layer")
        #expect(LineWidthPicker.displayName(.millimeters(0.5)) == "0.50 mm")
    }
}
