//
//  LayoutPlotTests.swift
//  CADEngineTests
//
//  Unit tests for the PURE layout-aware plot math (Paper Space Phase 4): the
//  engine→app converters and the layout sheet's world→page transform. The print
//  panel / save panel are reachable only from the View layer and are NOT exercised
//  here — these tests target the referentially-transparent half:
//
//    - `PrintLayout.pageSetup(from: PageDescriptor)` — mm page → app `PageSetup`
//      (points + margin + plot scale), snapped to the nearest standard sheet.
//    - `PrintLayout.plotScale(from: LayoutPlotScale)` — `.fit`→`.fit`, `.ratio(r)`→
//      the app's custom-ratio case.
//    - `PrintLayout.nearestStandardPage(...)` — mm page → canonical standard sheet
//      (the symlink-safe basis for the app's `PaperSize` mapping in DrawingPrinter).
//    - `PrintLayout.makeLayout(for: Layout)` — the layout sheet's world→page
//      transform: corners map to the expected page points at fit and at 1:1, the
//      margin insets correctly, a degenerate (0-size) page stays finite.
//
//  `PrintLayout.swift` lives in the (un-importable) app executable target but is
//  compiled INTO this test target via the `_SharedPrintLayout.swift` symlink — the
//  established zero-drift pattern (see Package.swift) — so this math is testable
//  with no AppKit/CoreGraphics and no print dialog. The `PaperSize`-enum mapping
//  (DrawingPrinter.swift) is app-target-only and intentionally NOT covered here;
//  its testable basis (the canonical name + dims) IS covered via `nearestStandardPage`.
//
//  Suite/type names are domain-namespaced (`LayoutPlot*`) per CONVENTIONS to avoid
//  the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// 1 mm in page points (72 pt / 25.4 mm) — the 1:1 paper scale.
private let ptPerMM = 72.0 / 25.4

@Suite("LayoutPlot: page-descriptor → page-setup conversion")
struct LayoutPlotConversionTests {

    @Test("A4 mm descriptor matches the A4 standard sheet (exact) with correct dims")
    func a4DescriptorMatchesA4() {
        let page = PageDescriptor(widthMM: 210, heightMM: 297, marginMM: 10, plotScale: .fit)
        let std = PrintLayout.nearestStandardPage(widthMM: page.widthMM, heightMM: page.heightMM)
        #expect(std.name == "A4")
        #expect(std.isExact)
        #expect(abs(std.widthMM - 210) < 1e-9)
        #expect(abs(std.heightMM - 297) < 1e-9)
    }

    @Test("page-setup from an A4 descriptor has the A4 size in points + mm margin")
    func pageSetupDimsFromA4() {
        let page = PageDescriptor(widthMM: 210, heightMM: 297, marginMM: 10, plotScale: .fit)
        let setup = PrintLayout.pageSetup(from: page)
        // A4 portrait in points: 210 mm × 297 mm at 72/25.4.
        #expect(abs(setup.paperSize.width - 210 * ptPerMM) < 1e-6)
        #expect(abs(setup.paperSize.height - 297 * ptPerMM) < 1e-6)
        #expect(abs(setup.margin - 10 * ptPerMM) < 1e-6)
    }

    @Test("nearest-sheet match is orientation-agnostic (landscape A4 → A4)")
    func landscapeA4MatchesA4() {
        // 297 × 210 is A4 rotated to landscape.
        let std = PrintLayout.nearestStandardPage(widthMM: 297, heightMM: 210)
        #expect(std.name == "A4")
        #expect(std.isExact)
    }

    @Test("page-setup preserves the descriptor's landscape orientation")
    func pageSetupKeepsLandscapeOrientation() {
        let page = PageDescriptor(widthMM: 297, heightMM: 210, marginMM: 10, plotScale: .fit)
        let setup = PrintLayout.pageSetup(from: page)
        // Snapped to A4 but kept landscape (wider than tall).
        #expect(setup.paperSize.width > setup.paperSize.height)
        #expect(abs(setup.paperSize.width - 297 * ptPerMM) < 1e-6)
        #expect(abs(setup.paperSize.height - 210 * ptPerMM) < 1e-6)
    }

    @Test("A3 descriptor matches the A3 standard sheet")
    func a3DescriptorMatchesA3() {
        let std = PrintLayout.nearestStandardPage(widthMM: 297, heightMM: 420)
        #expect(std.name == "A3")
        #expect(std.isExact)
    }

    @Test("a US Letter descriptor matches the Letter sheet")
    func letterDescriptorMatchesLetter() {
        let std = PrintLayout.nearestStandardPage(widthMM: 215.9, heightMM: 279.4)
        #expect(std.name == "Letter")
        #expect(std.isExact)
    }

    @Test("a custom (non-standard) page falls back to the nearest sheet, not exact")
    func customPageNearestNotExact() {
        // 205 × 290 mm is close to A4 but not within 1 mm on both sides.
        let std = PrintLayout.nearestStandardPage(widthMM: 205, heightMM: 290)
        #expect(std.name == "A4")
        #expect(!std.isExact)
    }

    @Test("a degenerate (0-size) page falls back to A4 safely")
    func degeneratePageFallsBackToA4() {
        let std = PrintLayout.nearestStandardPage(widthMM: 0, heightMM: 0)
        #expect(std.name == "A4")
        #expect(!std.isExact)
    }

    @Test("snapToStandard: false keeps the literal custom mm size")
    func noSnapKeepsLiteralSize() {
        let page = PageDescriptor(widthMM: 205, heightMM: 290, marginMM: 5, plotScale: .fit)
        let setup = PrintLayout.pageSetup(from: page, snapToStandard: false)
        #expect(abs(setup.paperSize.width - 205 * ptPerMM) < 1e-6)
        #expect(abs(setup.paperSize.height - 290 * ptPerMM) < 1e-6)
    }
}

@Suite("LayoutPlot: plot-scale conversion")
struct LayoutPlotScaleConversionTests {

    @Test(".fit converts to the app .fit plot scale")
    func fitConvertsToFit() {
        #expect(PrintLayout.plotScale(from: .fit) == .fit)
    }

    @Test(".ratio(r) converts to a custom drawingUnits:paperUnits = r:1")
    func ratioConvertsToCustom() {
        let scale = PrintLayout.plotScale(from: .ratio(50))
        guard case .custom(let du, let pu) = scale else {
            Issue.record("expected .custom for .ratio")
            return
        }
        #expect(du == 50)
        #expect(pu == 1)
        // ratioMultiplier reads back as paper-per-drawing = 1/50 (a 50:1 shrink).
        #expect(abs((scale.ratioMultiplier ?? 0) - 1.0 / 50.0) < 1e-12)
    }

    @Test(".ratio(0.01) (1:100) converts to a 0.01:1 custom scale")
    func ratioFractionConvertsToCustom() {
        let scale = PrintLayout.plotScale(from: .ratio(0.01))
        guard case .custom(let du, let pu) = scale else {
            Issue.record("expected .custom for .ratio")
            return
        }
        #expect(abs(du - 0.01) < 1e-12)
        #expect(pu == 1)
    }

    @Test("page-setup carries the converted plot scale (.fit)")
    func pageSetupCarriesFitScale() {
        let page = PageDescriptor(widthMM: 210, heightMM: 297, marginMM: 10, plotScale: .fit)
        #expect(PrintLayout.pageSetup(from: page).scale == .fit)
    }

    @Test("page-setup carries the converted plot scale (.ratio)")
    func pageSetupCarriesRatioScale() {
        let page = PageDescriptor(widthMM: 210, heightMM: 297, marginMM: 10,
                                  plotScale: .ratio(2))
        guard case .custom(let du, let pu) = PrintLayout.pageSetup(from: page).scale else {
            Issue.record("expected .custom in the page setup")
            return
        }
        #expect(du == 2)
        #expect(pu == 1)
    }
}

@Suite("LayoutPlot: layout sheet world→page transform")
struct LayoutPlotTransformTests {

    /// An A4-portrait layout, 10 mm margin, scaled to fit.
    private func a4FitLayout() -> Layout {
        Layout(name: "Layout1",
               page: PageDescriptor(widthMM: 210, heightMM: 297, marginMM: 10, plotScale: .fit))
    }

    @Test("fit layout: the sheet's lower-left corner maps to the imageable origin")
    func fitLowerLeftCorner() {
        let layout = a4FitLayout()
        let result = PrintLayout.makeLayout(for: layout)
        let xform = result.layout.transform
        // World (0,0) is the sheet's lower-left; in y-down page space it maps to the
        // bottom-left of the centered fit (offsetX, pageHeight - offsetY).
        let p = xform.page(Vector(0, 0))
        #expect(abs(p.x - xform.offsetX) < 1e-6)
        #expect(abs(p.y - (xform.pageSize.height - xform.offsetY)) < 1e-6)
    }

    @Test("fit layout: the sheet fills the imageable area on its limiting axis")
    func fitFillsImageable() {
        let layout = a4FitLayout()
        let result = PrintLayout.makeLayout(for: layout)
        let imageable = result.setup.imageableSize
        // A 210×297 sheet on a 190×277 imageable area (A4 minus 10 mm margins) is
        // WIDTH-limited (190/210 < 277/297), so the width fills exactly and the
        // height is no larger than the imageable area; nothing overflows.
        #expect(!result.layout.overflows)
        #expect(abs(result.layout.drawingPagePt.width - imageable.width) < 1e-3)
        #expect(result.layout.drawingPagePt.height <= imageable.height + 1e-3)
    }

    @Test("ratio layout: the sheet prints at TRUE physical size (1:1, mm→points)")
    func ratioSheetIsOneToOne() {
        let layout = Layout(name: "L",
                            page: PageDescriptor(widthMM: 210, heightMM: 297,
                                                 marginMM: 10, plotScale: .ratio(50)))
        let result = PrintLayout.makeLayout(for: layout)
        // The SHEET always prints 1:1 on paper regardless of the model plot ratio:
        // one sheet-mm → 72/25.4 points.
        #expect(abs(result.layout.scale - ptPerMM) < 1e-9)
        // The 210 mm sheet width maps to 210 mm of page points.
        #expect(abs(result.layout.drawingPagePt.width - 210 * ptPerMM) < 1e-6)
        #expect(abs(result.layout.drawingPagePt.height - 297 * ptPerMM) < 1e-6)
    }

    @Test("fit layout: the margin insets the scaled sheet inside the imageable area")
    func fitMarginInset() {
        let layout = a4FitLayout()
        let result = PrintLayout.makeLayout(for: layout)
        let xform = result.layout.transform
        let marginPt = 10 * ptPerMM
        // In fit, the scaled sheet sits INSIDE the imageable area (page minus margins),
        // centered. The lower-left maps to at least the margin on each axis (it is the
        // margin on the limiting axis, ≥ margin on the other).
        let p = xform.page(Vector(0, 0))
        #expect(p.x >= marginPt - 1e-6)
        #expect(xform.offsetX >= marginPt - 1e-6)
        #expect(xform.offsetY >= marginPt - 1e-6)
        // Width is the limiting axis here, so its offset is exactly the margin.
        #expect(abs(xform.offsetX - marginPt) < 1e-6)
        // The imageable area is the page inset by the margin on every side.
        #expect(abs(result.setup.imageableSize.width
                    - (xform.pageSize.width - 2 * marginPt)) < 1e-6)
        #expect(abs(result.setup.imageableSize.height
                    - (xform.pageSize.height - 2 * marginPt)) < 1e-6)
    }

    @Test("ratio 1:1 on a full-page sheet overflows and centers (margin eaten)")
    func ratioFullPageSheetCenters() {
        // A layout's page rect == its sheet size, so a 1:1 sheet is the FULL page —
        // larger than the imageable area (page minus margins) — hence it overflows and
        // is CENTERED with a negative offset (the sheet edges fall in the margins,
        // which is correct: a 1:1 plot ignores the printer's hardware margin).
        let layout = Layout(name: "L",
                            page: PageDescriptor(widthMM: 210, heightMM: 297,
                                                 marginMM: 10, plotScale: .ratio(1)))
        let result = PrintLayout.makeLayout(for: layout)
        let xform = result.layout.transform
        #expect(result.layout.overflows)
        // Centered: the slack splits evenly, so offsetX == margin + (imageable - drawn)/2.
        let expectedOffsetX = result.setup.margin
            + (result.setup.imageableSize.width - result.layout.drawingPagePt.width) / 2
        #expect(abs(xform.offsetX - expectedOffsetX) < 1e-6)
        // The sheet's full width (210 mm at 1:1) equals the page width.
        #expect(abs(result.layout.drawingPagePt.width - xform.pageSize.width) < 1e-4)
    }

    @Test("a degenerate (0-size) layout page yields a finite transform, no overflow")
    func degenerateLayoutIsSafe() {
        let layout = Layout(name: "L",
                            page: PageDescriptor(widthMM: 0, heightMM: 0,
                                                 marginMM: 0, plotScale: .ratio(1)))
        let result = PrintLayout.makeLayout(for: layout)
        #expect(result.layout.scale.isFinite)
        #expect(!result.layout.overflows)
        // Falls back to A4 points (the nearest-sheet degenerate fallback).
        #expect(result.setup.paperSize.width > 0)
        #expect(result.setup.paperSize.height > 0)
    }

    @Test("a sheet whose margins exceed its size overflows at 1:1")
    func oversizeSheetOverflows() {
        // A 50 mm sheet with a 40 mm margin: 50 − 2·40 < 0, so the imageable area
        // floors to ≥ 1×1 pt, while the sheet at 1:1 is 50 mm ≈ 141.7 pt — far larger
        // than the floored imageable area, so the plot overflows. (No snap, so the
        // literal 50 mm sheet drives the math.)
        let layout = Layout(name: "L",
                            page: PageDescriptor(widthMM: 50, heightMM: 50,
                                                 marginMM: 40, plotScale: .ratio(1)))
        let result = PrintLayout.makeLayout(for: layout, snapToStandard: false)
        #expect(result.layout.overflows)
        #expect(abs(result.layout.scale - ptPerMM) < 1e-9)
    }
}
