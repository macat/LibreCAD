//
//  PrintLayoutTests.swift
//  CADEngineTests
//
//  Unit tests for the PURE plot-scale + page-setup math in `PrintLayout` (the
//  scale-aware print/export feature's testable half). The macOS print panel
//  (`NSPrintOperation`) is reachable only from the View layer and is NOT exercised
//  here — these tests target the referentially-transparent transform: given drawing
//  bounds + unit + plot scale + paper + margins → the CTM (`ExportTransform`) and the
//  overflow flag.
//
//  `PrintLayout.swift` lives in the (un-importable) app executable target but is
//  compiled INTO this test target via the `_SharedPrintLayout.swift` symlink — the
//  established zero-drift pattern (see Package.swift) — so it is testable with no
//  AppKit/CoreGraphics and no print dialog.
//
//  Coverage:
//    - `pointsPerWorldUnit` is unit-correct (inch ⇒ 72 pt, mm ⇒ ≈ 2.8346 pt).
//    - 1:1 maps 1 world unit to its true physical points (imperial AND metric).
//    - a custom ratio scales by drawingUnits:paperUnits (1:50 shrink, 4:1 enlarge).
//    - `.fit` reproduces the legacy centered fit-to-page transform exactly.
//    - overflow is flagged when the scaled drawing exceeds the imageable area.
//    - the scaled drawing is centered (anchored) in the imageable area.
//    - `makeExportOptions` yields the SAME physical scale for the PDF/SVG path (so a
//      1:1 PDF measures correctly).
//
//  Suite/type names are domain-namespaced (`PrintLayout*`) per CONVENTIONS to avoid
//  the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("PrintLayout: unit-correct scale")
struct PrintLayoutScaleTests {

    /// A square-ish A4-portrait page in points.
    private let a4 = SizePt.a4

    @Test("pointsPerWorldUnit is 72 for an inch drawing")
    func pointsPerInch() {
        let s = PrintLayout.pointsPerWorldUnit(.inch)
        #expect(abs(s - 72.0) < 1e-9)
    }

    @Test("pointsPerWorldUnit for mm is 72/25.4 (≈ 2.8346)")
    func pointsPerMM() {
        let s = PrintLayout.pointsPerWorldUnit(.millimeter)
        #expect(abs(s - (72.0 / 25.4)) < 1e-9)
    }

    @Test("pointsPerWorldUnit for foot is 12× the inch value")
    func pointsPerFoot() {
        let foot = PrintLayout.pointsPerWorldUnit(.foot)
        let inch = PrintLayout.pointsPerWorldUnit(.inch)
        #expect(abs(foot - inch * 12.0) < 1e-6)
    }

    @Test("1:1 imperial — a 1-inch drawing extent maps to 72 page points")
    func oneToOneImperial() {
        // A 1×1 inch box.
        let bounds = AABB(min: Vector(0, 0), max: Vector(1, 1))
        let setup = PageSetup(paperSize: a4, margin: 18, scale: .oneToOne)
        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .inch, setup: setup)
        #expect(abs(layout.scale - 72.0) < 1e-9)
        #expect(abs(layout.drawingPagePt.width - 72.0) < 1e-6)
        #expect(abs(layout.drawingPagePt.height - 72.0) < 1e-6)
        #expect(!layout.overflows)
    }

    @Test("1:1 metric — a 100-mm drawing extent maps to its true points")
    func oneToOneMetric() {
        let bounds = AABB(min: Vector(0, 0), max: Vector(100, 100))
        let setup = PageSetup(paperSize: a4, margin: 18, scale: .oneToOne)
        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .millimeter, setup: setup)
        let expected = 100.0 * 72.0 / 25.4   // 100 mm in points
        #expect(abs(layout.drawingPagePt.width - expected) < 1e-6)
        #expect(abs(layout.scale - 72.0 / 25.4) < 1e-9)
    }

    @Test("custom 1:50 shrinks by 50× relative to 1:1")
    func customShrink() {
        let setup = PageSetup(paperSize: a4, margin: 18,
                              scale: .custom(drawingUnits: 50, paperUnits: 1))
        let s = PrintLayout.pageScale(bounds: .empty, unit: .millimeter, setup: setup)
        let oneToOne = PrintLayout.pointsPerWorldUnit(.millimeter)
        #expect(abs(s - oneToOne / 50.0) < 1e-9)
    }

    @Test("custom 4:1 enlarges by 4× relative to 1:1")
    func customEnlarge() {
        let setup = PageSetup(paperSize: a4, margin: 18,
                              scale: .custom(drawingUnits: 1, paperUnits: 4))
        let s = PrintLayout.pageScale(bounds: .empty, unit: .inch, setup: setup)
        let oneToOne = PrintLayout.pointsPerWorldUnit(.inch)
        #expect(abs(s - oneToOne * 4.0) < 1e-6)
    }

    @Test("a non-positive custom ratio clamps to 1:1 (never vanishes)")
    func customClamp() {
        let bad = PlotScale.custom(drawingUnits: 0, paperUnits: 10)
        #expect(bad.ratioMultiplier == 1)
        let bad2 = PlotScale.custom(drawingUnits: 5, paperUnits: -2)
        #expect(bad2.ratioMultiplier == 1)
    }
}

@Suite("PrintLayout: fit-to-page parity")
struct PrintLayoutFitTests {

    /// `.fit` must reproduce the legacy `ExportTransform(.fitToPage)` exactly so
    /// nothing regresses for existing prints/exports.
    @Test("fit matches the legacy ExportTransform(.fitToPage) scale + centering")
    func fitMatchesLegacy() {
        let bounds = AABB(min: Vector(0, 0), max: Vector(200, 100))
        let page = SizePt.usLetter
        let margin = 18.0
        let setup = PageSetup(paperSize: page, margin: margin, scale: .fit)

        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .millimeter, setup: setup)
        let legacy = ExportTransform(
            bounds: bounds,
            options: ExportOptions(pageSize: page, margin: margin, scaling: .fitToPage))

        #expect(abs(layout.transform.scale - legacy.scale) < 1e-9)
        #expect(abs(layout.transform.offsetX - legacy.offsetX) < 1e-9)
        #expect(abs(layout.transform.offsetY - legacy.offsetY) < 1e-9)
        #expect(layout.transform.pageSize == legacy.pageSize)
    }

    @Test("fit of a wide drawing is limited by the width axis and does not overflow")
    func fitNoOverflow() {
        let bounds = AABB(min: Vector(0, 0), max: Vector(1000, 10))
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .fit)
        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .millimeter, setup: setup)
        #expect(!layout.overflows)
        // Width fills the imageable area (the limiting axis).
        #expect(abs(layout.drawingPagePt.width - setup.imageableSize.width) < 1e-6)
    }

    @Test("an empty drawing yields a finite unit transform and no overflow")
    func emptyDrawing() {
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .oneToOne)
        let layout = PrintLayout.makeLayout(bounds: .empty, unit: .inch, setup: setup)
        #expect(layout.scale == 1)
        #expect(!layout.overflows)
        #expect(layout.transform.pageSize == SizePt.a4)
    }
}

@Suite("PrintLayout: overflow + anchoring")
struct PrintLayoutOverflowTests {

    @Test("a drawing too big for the page at 1:1 is flagged as overflowing")
    func overflowFlagged() {
        // A 20-inch box on A4 at 1:1 is far larger than the page.
        let bounds = AABB(min: Vector(0, 0), max: Vector(20, 20))
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .oneToOne)
        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .inch, setup: setup)
        #expect(layout.overflows)
        // Scale is still the true 1:1 scale (we render at scale + clip, not refit).
        #expect(abs(layout.scale - 72.0) < 1e-9)
    }

    @Test("a small drawing at 1:1 fits the page and is centered in the imageable area")
    func fitsAndCentered() {
        // A 1-inch box on A4 at 1:1: 72 pt, well within A4 (595×842 pt).
        let bounds = AABB(min: Vector(0, 0), max: Vector(1, 1))
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .oneToOne)
        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .inch, setup: setup)
        #expect(!layout.overflows)
        // Centered: equal slack on both sides of the imageable area.
        let imageable = setup.imageableSize
        let expectedOffsetX = setup.margin + (imageable.width - layout.drawingPagePt.width) / 2
        let expectedOffsetY = setup.margin + (imageable.height - layout.drawingPagePt.height) / 2
        #expect(abs(layout.transform.offsetX - expectedOffsetX) < 1e-6)
        #expect(abs(layout.transform.offsetY - expectedOffsetY) < 1e-6)
    }

    @Test("a non-origin drawing maps its min corner through the transform correctly")
    func worldOriginHonored() {
        // A 1-inch box offset to (10,10); at 1:1 its corner must map by the transform.
        let bounds = AABB(min: Vector(10, 10), max: Vector(11, 11))
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .oneToOne)
        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .inch, setup: setup)
        // The world min corner maps to (offsetX, pageHeight - offsetY) in y-down page
        // space (per ExportTransform.page).
        let p = layout.transform.page(Vector(10, 10))
        #expect(abs(p.x - layout.transform.offsetX) < 1e-6)
        #expect(abs(p.y - (layout.transform.pageSize.height - layout.transform.offsetY)) < 1e-6)
    }
}

@Suite("PrintLayout: export-options parity (PDF/SVG)")
struct PrintLayoutExportTests {

    @Test("makeExportOptions for 1:1 uses oneToOne with the inverse physical scale")
    func exportOneToOneOptions() {
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .oneToOne)
        let opts = PrintLayout.makeExportOptions(unit: .inch, setup: setup)
        guard case .oneToOne(let unitsPerPoint) = opts.scaling else {
            Issue.record("expected .oneToOne scaling")
            return
        }
        // 1 inch → 72 pt ⇒ unitsPerPoint = 1/72.
        #expect(abs(unitsPerPoint - 1.0 / 72.0) < 1e-12)
    }

    @Test("export options 1:1 and the print layout share the SAME physical scale")
    func exportPrintScaleAgree() {
        let bounds = AABB(min: Vector(0, 0), max: Vector(2, 3))
        let setup = PageSetup(paperSize: .a4, margin: 18, scale: .oneToOne)

        let layout = PrintLayout.makeLayout(bounds: bounds, unit: .inch, setup: setup)
        let opts = PrintLayout.makeExportOptions(unit: .inch, setup: setup)
        let exportXform = ExportTransform(bounds: bounds, options: opts)

        // Both render at the identical world→point scale (so a 1:1 PDF measures the
        // same as the 1:1 print).
        #expect(abs(layout.scale - exportXform.scale) < 1e-9)
        #expect(abs(exportXform.scale - 72.0) < 1e-9)
    }

    @Test("makeExportOptions for .fit uses fitToPage on the chosen paper")
    func exportFitOptions() {
        let setup = PageSetup(paperSize: .usLetter, margin: 18, scale: .fit)
        let opts = PrintLayout.makeExportOptions(unit: .millimeter, setup: setup)
        #expect(opts.scaling == .fitToPage)
        #expect(opts.pageSize == SizePt.usLetter)
        #expect(opts.margin == 18)
    }

    @Test("pointsFromMM converts an inch (25.4 mm) to exactly 72 points")
    func pointsFromMMHelper() {
        #expect(abs(pointsFromMM(25.4) - 72.0) < 1e-9)
    }
}
