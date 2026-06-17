//
//  DrawingPrinter.swift
//  LibreCADmacOS
//
//  System Print (⌘P) for a `CADDrawing`, via `NSPrintOperation`, AND the scale-aware
//  PDF export entry point. Both draw the drawing through the SAME `CGSceneRenderer`
//  the PDF/PNG/SVG exporters use, over the SAME `ExportScene`, so print output and
//  exported files match — now at a USER-CHOSEN plot scale, not just fit-to-page.
//
//  ## Plot scale (professional CAD plotting)
//  The page setup (paper size, orientation, margins, plot scale) lives in the PURE,
//  unit-tested `PrintLayout` model. The print/export flow asks `PrintLayout` for the
//  world→page `ExportTransform` and renders through it:
//
//    - `.fit`      → the legacy centered fit-to-page (DEFAULT, nothing regresses).
//    - `.oneToOne` → 1 drawing-inch prints as 1 paper-inch (unit-correct).
//    - `.custom`   → an explicit drawingUnits:paperUnits ratio (1:N / N:1).
//
//  A drawing larger than the page at the chosen scale is rendered anchored (centered)
//  and CLIPPED to the page; `PrintLayout.makeLayout(...).overflows` reports it.
//
//  ## Where the chosen setup comes from
//  The Paper tab of Document Settings writes the user's choice to `PrintLayoutStore`
//  (a small `UserDefaults`-backed shared default), and the print/export entry points
//  read it. This keeps the existing call sites in `ContentView` (which can't be
//  modified) source-compatible: the new `setup:` argument defaults to the store.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import AppKit
import CADEngine

/// Runs the system Print dialog for a drawing, and exports a scale-correct PDF.
@MainActor
enum DrawingPrinter {

    /// Presents the print panel for `drawing` at `setup`'s plot scale.
    /// `window` (optional) attaches the panel as a sheet. No-op for an empty
    /// drawing (returns `false`); returns whether the user proceeded.
    ///
    /// `setup` defaults to the shared `PrintLayoutStore` (what the Paper tab last
    /// chose), so the existing `ContentView` call site stays source-compatible while
    /// still honoring the user's plot scale. `.fit` (the store's default) reproduces
    /// the legacy fit-to-page behavior exactly.
    ///
    /// `space` selects WHICH drawing space the print captures — `.model` /
    /// `.paper(layoutName:)` builds the scene from ONLY that space (like the live
    /// canvas's active space), instead of unioning model + every layout. It defaults
    /// to `.all` (the historical behavior) so existing callers are unchanged; the
    /// general "Print…" call site passes the live `CanvasModel`'s active space (via
    /// `DrawingExporter.exportSpace(forActiveSpace:layout:)`) so a plain print follows
    /// the on-screen Model/Layout tab — mirroring `DrawingExporter.export(…, space:)`.
    /// (The dedicated per-layout `printLayout(…)` path is unaffected — it already
    /// plots a specific sheet.)
    @discardableResult
    static func print(_ drawing: CADDrawing,
                      in window: NSWindow? = nil,
                      setup: PageSetup? = nil,
                      space: ExportSpace = .all) -> Bool {
        let scene = ExportSceneBuilder.build(drawing, space: space)
        let unit = drawing.graphicVariables.unit
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        // We position the drawing ourselves (scale-correct, anchored), so let the
        // page draw at its natural size — no auto-fit / auto-center by AppKit.
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        // Size the view to the imageable (printable) area of the chosen paper.
        let paper = info.paperSize
        let resolved = (setup ?? PrintLayoutStore.shared.pageSetup)
            .withPaperSize(SizePt(width: Double(paper.width), height: Double(paper.height)))
        let view = PrintView(scene: scene, unit: unit, setup: resolved, printInfo: info)
        view.frame = NSRect(origin: .zero, size: paper)

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true

        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return true
        } else {
            return op.run()
        }
    }

    /// Exports a scale-correct, single-page PDF of `drawing` at `setup`'s plot scale
    /// to `url`. Reuses the shared `DrawingExporter.writePDF` renderer with the
    /// `ExportOptions` that `PrintLayout` derives for the chosen scale + unit, so a
    /// 1:1 PDF measures correctly with a ruler and a custom-ratio PDF is to scale.
    ///
    /// `setup` defaults to the shared store (the Paper-tab choice). Throws on an
    /// empty drawing or a context failure (surfaced in the HUD by the caller).
    static func exportPDF(_ drawing: CADDrawing,
                          to url: URL,
                          setup: PageSetup? = nil,
                          background: RGBAColor? = .white) throws {
        let scene = ExportSceneBuilder.build(drawing)
        guard !scene.bounds.isEmpty else { throw ExportError.emptyDrawing }
        let unit = drawing.graphicVariables.unit
        let resolved = setup ?? PrintLayoutStore.shared.pageSetup
        let options = PrintLayout.makeExportOptions(unit: unit, setup: resolved,
                                                    background: background)
        try DrawingExporter.writePDF(scene: scene, to: url, options: options)
    }

    // MARK: - Layout (paper-space sheet) plot — Paper Space P4

    /// Presents the print panel for a paper-space `layout` sheet of `drawing`,
    /// plotted at the LAYOUT's own plot scale (the sheet at 1:1 for a fixed ratio,
    /// fit-to-page for `.fit`) rather than the model-space page setup.
    ///
    /// `scene` is the layout's paper-space drawables (the caller filters the drawing's
    /// `space == .paper && layoutName == layout.name` records into a scene — kept as a
    /// parameter so this entry point does not reach into `CADDrawing`'s space/layout
    /// model, which other phases own). `window` (optional) attaches the panel as a
    /// sheet; returns whether the user proceeded.
    @discardableResult
    static func printLayout(_ layout: Layout,
                            scene: ExportScene,
                            in window: NSWindow? = nil,
                            snapToStandard: Bool = true) -> Bool {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        // Bind the print JOB's media to the LAYOUT's (snapped) sheet, not the
        // printer's default paper — the layout renders against `makeLayout(for:)`'s
        // layout-sized media, so a mismatch (e.g. an A3 layout on an A4-default
        // printer) would otherwise make `NSPrintOperation` scale/clip and break the
        // 1:1 sheet. This mirrors `print(...)`, which rebinds the setup to the actual
        // paper. Zero hardware margins so our own margin/clip is the only inset.
        let setup = PrintLayout.pageSetup(from: layout.page, snapToStandard: snapToStandard)
        let sheet = NSSize(width: CGFloat(setup.paperSize.width),
                           height: CGFloat(setup.paperSize.height))
        info.paperSize = sheet
        info.leftMargin = 0; info.rightMargin = 0
        info.topMargin = 0; info.bottomMargin = 0

        let view = LayoutPrintView(scene: scene, layout: layout,
                                   snapToStandard: snapToStandard)
        view.frame = NSRect(origin: .zero, size: sheet)

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true

        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            return true
        } else {
            return op.run()
        }
    }
}

// MARK: - Layout render (pure, panel-free — testable + shared by print/export)

/// The PURE "draw this layout sheet into a CGContext" function — NO print panel, NO
/// save panel, NO modal — so it is reachable from a unit test and shared by the
/// print view (`LayoutPrintView`) and the PDF export path
/// (`DrawingExporter.writeLayoutPDF` / `layoutPDFData`). The context must already be
/// flipped to a TOP-LEFT origin (y-down) to match `ExportTransform` (the
/// PDF/print/bitmap callers do this).
///
/// Draws the sheet through `PrintLayout.makeLayout(for:)`'s layout-aware transform,
/// clipping to the sheet's imageable (margin-inset) area so an oversize sheet at a
/// fixed scale does not bleed into the hardware margins.
@MainActor
enum LayoutRenderer {
    /// Renders `scene` (the layout's paper-space drawables) onto its sheet in `ctx`.
    /// Returns the resolved `PlotLayout`/`PageSetup` used (handy for the caller to
    /// size the page / report overflow).
    @discardableResult
    static func draw(scene: ExportScene,
                     layout: Layout,
                     in ctx: CGContext,
                     background: RGBAColor? = nil,
                     snapToStandard: Bool = true)
        -> (layout: PlotLayout, setup: PageSetup) {
        let result = PrintLayout.makeLayout(for: layout, snapToStandard: snapToStandard)
        let setup = result.setup
        let m = CGFloat(setup.margin)
        let clip = CGRect(x: m, y: m,
                          width: CGFloat(setup.imageableSize.width),
                          height: CGFloat(setup.imageableSize.height))
        ctx.saveGState()
        ctx.clip(to: clip)
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: result.layout.transform,
                             background: background)
        ctx.restoreGState()
        return result
    }
}

/// The NSView that draws one paper-space layout sheet for the print operation, at
/// the layout's plot scale (sheet at 1:1 / fit-to-page), anchored + clipped.
final class LayoutPrintView: NSView {
    private let scene: ExportScene
    private let layout: Layout
    private let snapToStandard: Bool

    init(scene: ExportScene, layout: Layout, snapToStandard: Bool) {
        self.scene = scene
        self.layout = layout
        self.snapToStandard = snapToStandard
        let setup = PrintLayout.pageSetup(from: layout.page, snapToStandard: snapToStandard)
        super.init(frame: NSRect(origin: .zero,
                                 size: NSSize(width: setup.paperSize.width,
                                              height: setup.paperSize.height)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }   // top-left origin, matching the renderer.

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // NSView is flipped (top-left origin), exactly what the layout renderer /
        // ExportTransform expect, so no extra flip is needed here.
        LayoutRenderer.draw(scene: scene, layout: layout, in: ctx,
                            background: nil, snapToStandard: snapToStandard)
    }
}

/// The NSView that draws one page of the drawing for the print operation, at the
/// chosen plot scale (anchored + clipped to the page when the drawing overflows).
final class PrintView: NSView {
    private let scene: ExportScene
    private let unit: DrawingUnit
    private let setup: PageSetup
    private let printInfo: NSPrintInfo

    init(scene: ExportScene, unit: DrawingUnit, setup: PageSetup, printInfo: NSPrintInfo) {
        self.scene = scene
        self.unit = unit
        self.setup = setup
        self.printInfo = printInfo
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: setup.paperSize.width,
                                                             height: setup.paperSize.height)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }   // top-left origin, matching the renderer.

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Re-derive the setup against THIS print job's actual paper size (the panel's
        // paper/orientation flows through `printInfo` and may differ from the stored
        // size). Margins/scale come from the chosen setup.
        let paper = printInfo.paperSize
        let jobSetup = setup.withPaperSize(SizePt(width: Double(paper.width),
                                                  height: Double(paper.height)))

        // The PURE scale→page transform. For `.fit` this is the legacy centered fit;
        // for `.oneToOne`/`.custom` it is the unit-correct physical scale, anchored.
        let layout = PrintLayout.makeLayout(bounds: scene.bounds, unit: unit, setup: jobSetup)

        // Clip to the imageable area so an overflowing drawing doesn't bleed into the
        // hardware margins (the page shows the centered slice; tiling is a follow-up).
        let m = CGFloat(jobSetup.margin)
        let clip = CGRect(x: m, y: m,
                          width: CGFloat(jobSetup.imageableSize.width),
                          height: CGFloat(jobSetup.imageableSize.height))
        ctx.saveGState()
        ctx.clip(to: clip)
        // NSView is flipped (top-left origin), exactly what CGSceneRenderer/
        // ExportTransform expect, so no extra flip is needed here.
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: layout.transform, background: nil)
        ctx.restoreGState()
    }
}

// MARK: - Shared page-setup store (Paper tab ⇄ print/export)

/// A tiny `UserDefaults`-backed shared store for the page setup the Paper tab last
/// chose, so the print/export entry points can read it WITHOUT a parameter threaded
/// through the (un-modifiable) `ContentView` call sites. Defaults to `.fit` on A4 so
/// the very first print after a fresh launch matches the legacy fit-to-page output.
///
/// `@MainActor` because it's read/written from the View/print flow only.
@MainActor
final class PrintLayoutStore {
    static let shared = PrintLayoutStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let paperW = "printLayout.paperWidthPt"
        static let paperH = "printLayout.paperHeightPt"
        static let margin = "printLayout.marginPt"
        static let scaleKind = "printLayout.scaleKind"       // 0=fit 1=oneToOne 2=custom
        static let scaleDrawing = "printLayout.scaleDrawingUnits"
        static let scalePaper = "printLayout.scalePaperUnits"
    }

    /// The persisted page setup (falls back to `.fit` on A4 when unset).
    var pageSetup: PageSetup {
        get {
            let w = defaults.object(forKey: Key.paperW) as? Double ?? SizePt.a4.width
            let h = defaults.object(forKey: Key.paperH) as? Double ?? SizePt.a4.height
            let m = defaults.object(forKey: Key.margin) as? Double ?? 18
            let scale: PlotScale
            switch defaults.integer(forKey: Key.scaleKind) {
            case 1: scale = .oneToOne
            case 2:
                let du = defaults.object(forKey: Key.scaleDrawing) as? Double ?? 1
                let pu = defaults.object(forKey: Key.scalePaper) as? Double ?? 1
                scale = .custom(drawingUnits: du, paperUnits: pu)
            default: scale = .fit
            }
            return PageSetup(paperSize: SizePt(width: w, height: h), margin: m, scale: scale)
        }
        set {
            defaults.set(newValue.paperSize.width, forKey: Key.paperW)
            defaults.set(newValue.paperSize.height, forKey: Key.paperH)
            defaults.set(newValue.margin, forKey: Key.margin)
            switch newValue.scale {
            case .fit:
                defaults.set(0, forKey: Key.scaleKind)
            case .oneToOne:
                defaults.set(1, forKey: Key.scaleKind)
            case .custom(let du, let pu):
                defaults.set(2, forKey: Key.scaleKind)
                defaults.set(du, forKey: Key.scaleDrawing)
                defaults.set(pu, forKey: Key.scalePaper)
            }
        }
    }
}

// MARK: - PageSetup paper-size override

extension PageSetup {
    /// A copy of this setup with the paper rect replaced (used to bind the stored
    /// margin/scale to a print job's actual paper size from `NSPrintInfo`).
    func withPaperSize(_ size: SizePt) -> PageSetup {
        var copy = self
        copy.paperSize = size
        return copy
    }
}

// MARK: - PaperSize ⇄ layout page descriptor (Paper Space P4)
//
// The `PaperSize`-enum mapping lives HERE (an app-target-only file that is never
// symlinked into the test target), not in `PrintLayout.swift`, so `PrintLayout`
// stays symlink-safe. The symlink-safe nearest-sheet MATH is `PrintLayout.
// nearestStandardPage(...)` (tested); this just maps its canonical name to the app
// enum.

extension PaperSize {
    /// The `PaperSize` whose canonical name matches `name` ("A4", "Letter", …),
    /// falling back to A4 for an unknown name. Pairs with
    /// `PrintLayout.nearestStandardPage(...).name`.
    static func named(_ name: String) -> PaperSize {
        PaperSize.allCases.first { $0.label.caseInsensitiveCompare(name) == .orderedSame } ?? .a4
    }

    /// The nearest standard `PaperSize` for an engine `PageDescriptor`'s millimeter
    /// page (orientation-agnostic — A4 portrait and A4 landscape both map to `.a4`).
    /// Bridges the engine layout descriptor to the app's print/page-setup enum.
    static func nearest(to page: PageDescriptor) -> PaperSize {
        named(PrintLayout.nearestStandardPage(widthMM: page.widthMM,
                                              heightMM: page.heightMM).name)
    }
}
