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
    @discardableResult
    static func print(_ drawing: CADDrawing,
                      in window: NSWindow? = nil,
                      setup: PageSetup? = nil) -> Bool {
        let scene = ExportSceneBuilder.build(drawing)
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
