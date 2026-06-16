//
//  PenPreviewTests.swift
//  CADEngineTests
//
//  Coverage for the shared pen PREVIEWS introduced in Wave 2 (sidebar redesign):
//
//   1. `PenPreviewGeometry.dashArray(for:length:)` — the per-`PenLineType` dash array
//      that drives `LinetypePreview` (the replacement for the cryptic `line.diagonal`
//      glyph). Asserts the SwiftUI-dasher contract: solid + inherit sentinels are EMPTY
//      (continuous), every dashed style is a non-empty even-count strictly-positive
//      alternating pattern, and the per-style shape (dot < dash, dash-dot has 4 entries…)
//      matches the export rhythm.
//   2. `PenPreviewGeometry.thicknessPx(for:…)` — the lineweight-bar thickness for
//      `LineweightPreview`: clamped to a legible band, heavier mm ⇒ thicker, the
//      inherit/default cases collapse to the hairline minimum.
//   3. The LAYER-ROW reorg funnels (Wave 2): the printer + construction flags moved into
//      the row context menu; this pins that they STILL route through the same undoable
//      layer mutators (`setLayerPrintable` / `setLayerConstruction`) — a regression here
//      would mean the demoted toggles stopped being undoable. The color / line-type /
//      line-width edits (unchanged funnels) are re-pinned alongside.
//
//  `PenPreviewGeometry` lives in the app module (it imports SwiftUI for CGFloat), so it is
//  reached through the established `_SharedPenPreviews.swift` SYMLINK (the test target
//  depends only on CADEngine). SwiftUI view-METRICS (the 22pt chip, the 1pt stroke) are
//  not headlessly testable — these assert the pure value contract + the model funnels,
//  mirroring DesignTokensTests / ColorSwatchPickerTests / CGDashTests.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import SwiftUI
@testable import CADEngine

@Suite("Pen previews — dash-array + thickness mapping (LinetypePreview / LineweightPreview)")
struct PenPreviewGeometryTests {

    private func dash(_ lt: PenLineType, length: CGFloat = 22) -> [CGFloat] {
        PenPreviewGeometry.dashArray(for: lt, length: length)
    }

    // MARK: - Solid + inherit sentinels → continuous (empty dash)

    @Test("solid produces an EMPTY dash array (continuous stroke)")
    func solidIsEmpty() {
        #expect(dash(.solid).isEmpty)
    }

    @Test("byLayer / byBlock render as solid (empty dash — the inherit baseline)")
    func inheritSentinelsAreSolid() {
        #expect(dash(.byLayer).isEmpty)
        #expect(dash(.byBlock).isEmpty)
    }

    // MARK: - Every dashed style → non-empty, even-count, strictly positive

    @Test("every non-solid line type is a non-empty even-count positive alternating array")
    func dashedStylesAreWellFormed() {
        let styles: [PenLineType] = [.dashed, .dotted, .dashDot, .center, .border, .divide]
        for lt in styles {
            let d = dash(lt)
            #expect(!d.isEmpty, "\(lt) should produce a dash pattern")
            // SwiftUI's StrokeStyle.dash alternates ON, OFF, ON, OFF… — an even count
            // keeps the pattern phase-stable as it repeats.
            #expect(d.count % 2 == 0, "\(lt) must alternate on/off (even count), got \(d.count)")
            for len in d {
                #expect(len > 0 && len.isFinite, "\(lt) has a non-positive/finite length \(len)")
            }
        }
    }

    // MARK: - Per-style shape

    @Test("dashed is a simple [dash, gap] pair with dash longer than the gap")
    func dashedShape() {
        let d = dash(.dashed)
        #expect(d.count == 2)
        #expect(d[0] > d[1])
    }

    @Test("dotted's ON pip is shorter than dashed's ON dash")
    func dottedIsShorterThanDashed() {
        #expect(dash(.dotted)[0] < dash(.dashed)[0])
    }

    @Test("dashDot has four entries (dash, gap, dot, gap) with dash longer than dot")
    func dashDotShape() {
        let d = dash(.dashDot)
        #expect(d.count == 4)
        #expect(d[0] > d[2])
    }

    @Test("center / border / divide carry distinct multi-segment patterns")
    func compoundPatternsAreDistinct() {
        #expect(dash(.center).count == 4)
        #expect(dash(.border).count == 6)
        #expect(dash(.divide).count == 6)
        // border and divide share an entry count but differ in shape (border = two equal
        // dashes; divide = one long dash + two dots), so their arrays must not be equal.
        #expect(dash(.border) != dash(.divide))
    }

    // MARK: - Length scaling + degeneracy

    @Test("the dash unit scales with the preview length (reads at any size)")
    func dashScalesWithLength() {
        let small = dash(.dashed, length: 12)
        let large = dash(.dashed, length: 40)
        #expect(large[0] > small[0])
    }

    @Test("a degenerate (≈0) length still yields a positive finite pattern (no stall)")
    func degenerateLengthIsSafe() {
        let d = PenPreviewGeometry.dashArray(for: .dashDot, length: 0)
        #expect(!d.isEmpty)
        for len in d { #expect(len > 0 && len.isFinite) }
    }

    // MARK: - Lineweight thickness

    @Test("inherit / default widths collapse to the hairline minimum")
    func inheritWidthsAreHairline() {
        #expect(PenPreviewGeometry.thicknessPx(for: .byLayer) == 1)
        #expect(PenPreviewGeometry.thicknessPx(for: .byBlock) == 1)
        #expect(PenPreviewGeometry.thicknessPx(for: .default) == 1)
    }

    @Test("a zero-mm explicit width still reads as the hairline minimum")
    func zeroMillimetersIsHairline() {
        #expect(PenPreviewGeometry.thicknessPx(for: .millimeters(0)) == 1)
    }

    @Test("a heavier mm yields a thicker bar (monotonic in the legible band)")
    func heavierIsThicker() {
        let thin = PenPreviewGeometry.thicknessPx(for: .millimeters(0.25))
        let mid = PenPreviewGeometry.thicknessPx(for: .millimeters(0.70))
        #expect(mid > thin)
        #expect(thin > 1)   // any positive mm exceeds the hairline
    }

    @Test("thickness is clamped into [minPx, maxPx] even for a very heavy pen")
    func thicknessIsClamped() {
        let heavy = PenPreviewGeometry.thicknessPx(for: .millimeters(2.11))
        #expect(heavy <= 6)
        #expect(heavy >= 1)
        // Custom clamp band is honored too.
        let custom = PenPreviewGeometry.thicknessPx(for: .millimeters(2.11), minPx: 2, maxPx: 3)
        #expect(custom <= 3 && custom >= 2)
    }
}

// MARK: - LayerRow reorg: demoted flags still route through undoable funnels

@MainActor
@Suite("Layer row reorg — demoted printer/construction flags stay undoable")
struct LayerRowReorgFunnelTests {

    /// The printable flag moved from an inline row button to the row CONTEXT MENU; this
    /// pins it still routes through the same undoable funnel the menu Toggle binding drives
    /// (`CADDrawing.setLayerPrintable` → `mutateLayers`).
    @Test("printable toggle (now in the context menu) mutates the layer and is undoable")
    func printableFlagIsUndoable() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Walls")))
        model.drawing.undoManager?.removeAllActions()

        let before = model.drawing.layers.layer(named: "Walls")?.isPrintable ?? true
        model.setLayerPrintable("Walls", !before)
        #expect(model.drawing.layers.layer(named: "Walls")?.isPrintable == !before)

        model.undo()
        #expect(model.drawing.layers.layer(named: "Walls")?.isPrintable == before)
        model.redo()
        #expect(model.drawing.layers.layer(named: "Walls")?.isPrintable == !before)
    }

    /// The construction flag likewise moved into the context menu; same undoable funnel
    /// (`CADDrawing.setLayerConstruction`).
    @Test("construction toggle (now in the context menu) mutates the layer and is undoable")
    func constructionFlagIsUndoable() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Aux")))
        model.drawing.undoManager?.removeAllActions()

        let before = model.drawing.layers.layer(named: "Aux")?.isConstruction ?? false
        model.setLayerConstruction("Aux", !before)
        #expect(model.drawing.layers.layer(named: "Aux")?.isConstruction == !before)

        model.undo()
        #expect(model.drawing.layers.layer(named: "Aux")?.isConstruction == before)
        model.redo()
        #expect(model.drawing.layers.layer(named: "Aux")?.isConstruction == !before)
    }

    /// The trailing pen cluster's line-TYPE menu still routes through the unchanged
    /// undoable funnel (`mutateLayers { setLineType }`) after the reorg — what the row's
    /// `lineTypeBinding.set` → `onLineTypeChange` drives, and what `LinetypePreview` shows.
    @Test("layer line-type edit (trailing pen menu) mutates the layer and is undoable")
    func lineTypeIsUndoable() {
        let model = CanvasModel()
        #expect(model.drawing.addLayer(Layer(name: "Hidden", lineType: .solid)))
        model.drawing.undoManager?.removeAllActions()

        model.drawing.mutateLayers { $0.setLineType("Hidden", .dashed) }
        #expect(model.drawing.layers.layer(named: "Hidden")?.lineType == .dashed)
        model.undo()
        #expect(model.drawing.layers.layer(named: "Hidden")?.lineType == .solid)
        model.redo()
        #expect(model.drawing.layers.layer(named: "Hidden")?.lineType == .dashed)
    }
}
