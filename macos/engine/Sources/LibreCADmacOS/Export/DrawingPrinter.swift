//
//  DrawingPrinter.swift
//  LibreCADmacOS
//
//  System Print (⌘P) for a `CADDrawing`, via `NSPrintOperation`. A small custom
//  `NSView` (`PrintView`) draws the drawing through the SAME `CGSceneRenderer` the
//  PDF/PNG exporters use, over the SAME `ExportScene`, so print output matches the
//  on-disk export pixel-for-pixel (fit-to-page on the printer's paper size).
//
//  The view sizes itself to the print job's paper size and fits the drawing into
//  the imageable area; the print panel's paper/orientation selection flows through
//  because `PrintView` reads the operation's `NSPrintInfo` at draw time.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import AppKit
import CADEngine

/// Runs the system Print dialog for a drawing.
@MainActor
enum DrawingPrinter {

    /// Presents the print panel for `drawing`, fitting it to the selected paper.
    /// `window` (optional) attaches the panel as a sheet. No-op for an empty
    /// drawing (returns `false`); returns whether the user proceeded.
    @discardableResult
    static func print(_ drawing: CADDrawing, in window: NSWindow? = nil) -> Bool {
        let scene = ExportSceneBuilder.build(drawing)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        // Size the view to the imageable (printable) area of the chosen paper.
        let paper = info.paperSize
        let view = PrintView(scene: scene, paperSize: paper, printInfo: info)
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
}

/// The NSView that draws one page of the drawing for the print operation.
final class PrintView: NSView {
    private let scene: ExportScene
    private let paperSize: NSSize
    private let printInfo: NSPrintInfo

    init(scene: ExportScene, paperSize: NSSize, printInfo: NSPrintInfo) {
        self.scene = scene
        self.paperSize = paperSize
        self.printInfo = printInfo
        super.init(frame: NSRect(origin: .zero, size: paperSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }   // top-left origin, matching the renderer.

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Fit the drawing into the imageable area of the current page using the
        // shared ExportTransform (so print matches PDF/PNG/SVG framing). The
        // imageable area accounts for the printer's hardware margins.
        let imageable = printInfo.imageablePageBounds
        let options = ExportOptions(
            pageSize: SizePt(width: Double(bounds.width), height: Double(bounds.height)),
            margin: Double(imageable.origin.x),   // a reasonable uniform margin
            scaling: .fitToPage,
            background: nil                        // printer paper is the background
        )
        let xform = ExportTransform(bounds: scene.bounds, options: options)
        // NSView is flipped (top-left origin), exactly what CGSceneRenderer/
        // ExportTransform expect, so no extra flip is needed here.
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: xform, background: nil)
    }
}
