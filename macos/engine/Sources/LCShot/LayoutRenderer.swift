//
//  LayoutRenderer.swift
//  LCShot
//
//  A LOCAL, compile-only STUB of the app's `LayoutRenderer` — mirrors the same
//  stub the headless `RasterExportTests` keep. The real `LayoutRenderer` lives in
//  the app's `DrawingPrinter.swift`, which imports AppKit and runs
//  `NSPrintOperation.runModal` — pulling that into this headless target would
//  risk the modal-hang trap (a modal reached from a non-View path blocks forever).
//
//  The symlinked `DrawingExporter.swift` only *references* `LayoutRenderer` from
//  its paper-space PDF helper (`layoutPDFData`), which LCShot never calls (LCShot
//  renders the PNG raster path only), so a compile-only stub with the same name +
//  `draw` shape is sufficient to satisfy the linker. It is never invoked.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import CADEngine

/// Compile-only stub — see file header. Same name + `draw` shape as the app's
/// modal-printer-owned `LayoutRenderer`, so the symlinked `DrawingExporter`'s
/// `layoutPDFData` reference resolves at compile time. Never called by LCShot.
@MainActor
enum LayoutRenderer {
    @discardableResult
    static func draw(scene: ExportScene,
                     layout: Layout,
                     in ctx: CGContext,
                     background: RGBAColor? = nil,
                     snapToStandard: Bool = true)
        -> (layout: PlotLayout, setup: PageSetup) {
        let setup = PageSetup()
        let plot = PlotLayout(transform: ExportTransform(bounds: .empty,
                                                         options: ExportOptions()),
                              scale: 1, overflows: false,
                              drawingPagePt: SizePt(width: 0, height: 0))
        return (plot, setup)
    }
}
