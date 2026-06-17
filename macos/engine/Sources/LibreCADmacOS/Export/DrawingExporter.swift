//
//  DrawingExporter.swift
//  LibreCADmacOS
//
//  The app-target export entry points: PDF, PNG, and SVG (SVG just forwards to the
//  engine's pure-Swift `SVGExporter`). PDF and PNG share the CGContext renderer
//  (`CGSceneRenderer`) over the SAME `ExportScene` the SVG path uses, so all three
//  formats are geometrically identical.
//
//  - PDF: a single-page vector `CGContext` PDF (strokes + filled paths, including
//    outline text glyph fills — so text stays crisp and selectable-as-vector).
//  - PNG: a bitmap raster at a chosen DPI, white-backed, drawn via the same
//    renderer into a `CGContext` bitmap.
//  - SVG: forwarded to `CADEngine.SVGExporter.string(...)` (pure-Swift, unit-tested).
//
//  All three are `@MainActor` (they read the main-actor `CADDrawing`) and write to
//  a destination `URL`; errors are thrown, never crashed.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CADEngine

/// The export file formats this app can write.
enum ExportFormat: String, CaseIterable, Sendable {
    case pdf
    case png
    case jpg
    case bmp
    case tiff
    case svg

    /// The on-disk file extension (lowercase, no dot).
    var fileExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .pdf:  return .pdf
        case .png:  return .png
        case .jpg:  return .jpeg
        case .bmp:  return .bmp
        case .tiff: return .tiff
        case .svg:  return UTType(filenameExtension: "svg") ?? .svg
        }
    }

    var displayName: String {
        switch self {
        case .pdf:  return "PDF Document"
        case .png:  return "PNG Image"
        case .jpg:  return "JPEG Image"
        case .bmp:  return "BMP Image"
        case .tiff: return "TIFF Image"
        case .svg:  return "SVG Vector"
        }
    }

    /// Whether this format is written through the shared CGImage raster pipeline
    /// (PNG/JPEG/BMP/TIFF) as opposed to the vector PDF / pure-string SVG paths.
    var isRaster: Bool {
        switch self {
        case .png, .jpg, .bmp, .tiff: return true
        case .pdf, .svg:              return false
        }
    }
}

/// Errors the exporters can throw (surfaced in the status HUD).
enum ExportError: LocalizedError {
    case emptyDrawing
    case contextCreationFailed
    case imageEncodingFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDrawing:          return "Nothing to export (the drawing is empty)."
        case .contextCreationFailed: return "Could not create the graphics context."
        case .imageEncodingFailed:   return "Could not encode the image."
        case .writeFailed(let s):    return "Write failed: \(s)"
        }
    }
}

/// The app-side export facade. Builds one `ExportScene` from the drawing and
/// renders it to the requested format.
@MainActor
enum DrawingExporter {

    /// The default raster resolution (dots-per-inch) used when a caller does not
    /// specify one. 150 DPI matches the historical PNG default — keeping PNG output
    /// byte-compatible at the default DPI.
    static let defaultRasterDPI: Double = 150

    /// Exports `drawing` to `url` in `format` under `options`. Returns the number
    /// of drawn elements (polylines + fills) for a status message.
    ///
    /// `dpi` controls the output pixel size of the raster formats (PNG/JPEG/BMP/
    /// TIFF): pixels = page-points × (dpi / 72). It is ignored by the vector PDF
    /// and pure-string SVG paths.
    ///
    /// `jpegQuality` is the JPEG compression quality (0…1) when `format == .jpg`;
    /// ignored by every other format.
    ///
    /// `space` selects WHICH drawing space the export captures — `.model` /
    /// `.paper(layoutName:)` builds the scene from ONLY that space (like the live
    /// canvas's active space), instead of unioning model + every layout. It defaults
    /// to `.all` (the historical behavior) so existing callers are unchanged; the
    /// View-layer call site should pass the live `CanvasModel`'s active space (see
    /// `exportSpace(forActiveSpace:layout:)`) so a default export matches the screen.
    @discardableResult
    static func export(_ drawing: CADDrawing,
                       to url: URL,
                       format: ExportFormat,
                       options: ExportOptions = ExportOptions(background: .white),
                       dpi: Double = defaultRasterDPI,
                       jpegQuality: Double = 0.9,
                       space: ExportSpace = .all) throws -> Int {
        switch format {
        case .svg:
            let scene = ExportSceneBuilder.build(drawing, space: space)
            let svg = SVGExporter.string(for: scene, options: options)
            do {
                try svg.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
            return scene.polylines.count + scene.fills.count

        case .pdf:
            let scene = ExportSceneBuilder.build(drawing, space: space)
            try writePDF(scene: scene, to: url, options: options)
            return scene.polylines.count + scene.fills.count

        case .png, .jpg, .bmp, .tiff:
            let scene = ExportSceneBuilder.build(drawing, space: space)
            try writeRaster(scene: scene, to: url, options: options,
                            dpi: dpi, format: format, jpegQuality: jpegQuality)
            return scene.polylines.count + scene.fills.count
        }
    }

    /// Maps the live canvas's active-space pair (`CanvasModel.activeSpace` /
    /// `.activeLayout`) to an `ExportSpace`, so the View-layer export call site can
    /// thread the on-screen space into `export(…, space:)` with one helper (no app
    /// type reaches the engine — this takes the raw `EntitySpace` + layout name). A
    /// model space → `.model`; a paper space → `.paper(layoutName:)`.
    ///
    /// NOTE (deferral / non-owned-file dependency): wiring this at the actual call
    /// site (`ContentView.exportDrawing`, which is NOT in this lane's owned files)
    /// is required to make a DEFAULT export honor the active space. That call site
    /// already has `model.activeSpace` / `model.activeLayout` (both readable today),
    /// so a one-line change there —
    ///   `space: DrawingExporter.exportSpace(forActiveSpace: model.activeSpace,
    ///                                        layout: model.activeLayout)`
    /// — finishes finding #6. Until that wave, `export` defaults to `.all` (the
    /// historical union behavior), so nothing regresses.
    static func exportSpace(forActiveSpace space: EntitySpace,
                            layout: String?) -> ExportSpace {
        switch space {
        case .model: return .model
        case .paper: return .paper(layoutName: layout)
        }
    }

    // MARK: - PDF

    /// Writes a single-page vector PDF of `scene` at `url`.
    static func writePDF(scene: ExportScene, to url: URL, options: ExportOptions) throws {
        let xform = ExportTransform(bounds: scene.bounds, options: options)
        var mediaBox = CGRect(x: 0, y: 0, width: xform.pageSize.width, height: xform.pageSize.height)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }

        ctx.beginPDFPage(nil)
        // PDF origin is bottom-left, y-UP. CGSceneRenderer (and ExportTransform)
        // produce TOP-LEFT, y-down page points (matching SVG/NSImage). Flip the
        // PDF context to a top-left origin so the shared renderer maps identically.
        ctx.translateBy(x: 0, y: xform.pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: xform, background: options.background)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: - Layout (paper-space sheet) PDF export — Paper Space P4

    /// Exports a paper-space `layout` sheet of `scene` to a single-page PDF at `url`,
    /// plotted at the LAYOUT's own plot scale (the sheet at 1:1 for a fixed ratio,
    /// fit-to-page for `.fit`) via the layout-aware transform. The page MEDIA box is
    /// the layout's sheet size (snapped to the nearest standard sheet by default), so
    /// the PDF is the size of the plotted sheet.
    ///
    /// `scene` is the layout's paper-space drawables (the caller filters `space ==
    /// .paper && layoutName == layout.name` into a scene — kept a parameter so this
    /// does not reach into the space/layout model another phase owns).
    static func writeLayoutPDF(scene: ExportScene,
                               layout: Layout,
                               to url: URL,
                               background: RGBAColor? = .white,
                               snapToStandard: Bool = true) throws {
        let data = try layoutPDFData(scene: scene, layout: layout,
                                     background: background, snapToStandard: snapToStandard)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// The PURE "render this layout sheet to PDF data" function — NO save panel, NO
    /// modal — so it is reachable from a unit test (the panel stays in the View
    /// layer). Returns the in-memory single-page PDF `Data`; `writeLayoutPDF` just
    /// writes it to disk. The page size is the layout's sheet (snapped to standard by
    /// default); the sheet is drawn through the shared `LayoutRenderer` (clipped to
    /// the margin-inset imageable area).
    static func layoutPDFData(scene: ExportScene,
                              layout: Layout,
                              background: RGBAColor? = .white,
                              snapToStandard: Bool = true) throws -> Data {
        let setup = PrintLayout.pageSetup(from: layout.page, snapToStandard: snapToStandard)
        let pageW = Swift.max(setup.paperSize.width, 1)
        let pageH = Swift.max(setup.paperSize.height, 1)
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }

        ctx.beginPDFPage(nil)
        // PDF origin is bottom-left, y-up; the layout renderer / ExportTransform
        // produce TOP-LEFT, y-down page points. Flip to a top-left origin so the
        // shared renderer maps identically (same flip as `writePDF`).
        ctx.translateBy(x: 0, y: pageH)
        ctx.scaleBy(x: 1, y: -1)
        LayoutRenderer.draw(scene: scene, layout: layout, in: ctx,
                            background: background, snapToStandard: snapToStandard)
        ctx.endPDFPage()
        ctx.closePDF()
        return pdfData as Data
    }

    // MARK: - Raster (PNG / JPEG / BMP / TIFF)

    /// Writes a raster PNG of `scene` at `url` at `dpi` (white-backed). Retained as
    /// a thin convenience wrapper over the generalized `writeRaster` so existing
    /// callers keep working; PNG output is byte-identical to the previous code path.
    static func writePNG(scene: ExportScene, to url: URL, options: ExportOptions, dpi: Double) throws {
        try writeRaster(scene: scene, to: url, options: options, dpi: dpi, format: .png)
    }

    /// Renders `scene` into a `CGImage` bitmap at `dpi`, then writes it to `url`
    /// encoded as `format`'s raster type (PNG/JPEG/BMP/TIFF). White-backed by
    /// default (the renderer fills `options.background ?? .white`).
    ///
    /// Output pixel size = page-points × (dpi / 72). The shared `CGSceneRenderer`
    /// draws in page points; the bitmap context carries the DPI scale, so every
    /// raster format frames the drawing identically to PDF/SVG, just rasterized.
    static func writeRaster(scene: ExportScene,
                            to url: URL,
                            options: ExportOptions,
                            dpi: Double,
                            format: ExportFormat,
                            jpegQuality: Double = 0.9) throws {
        let data = try rasterData(scene: scene, options: options, dpi: dpi,
                                  format: format, jpegQuality: jpegQuality)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    /// The PURE "render this scene to encoded raster `Data`" function — NO save
    /// panel, NO modal — so it is reachable from a unit test (the panel stays in the
    /// View layer). Returns the encoded image bytes for `format` (must be a raster
    /// format; `pdf`/`svg` throw). `dpi` sets the pixel size; `jpegQuality` (0…1)
    /// applies only to JPEG.
    static func rasterData(scene: ExportScene,
                           options: ExportOptions,
                           dpi: Double,
                           format: ExportFormat,
                           jpegQuality: Double = 0.9) throws -> Data {
        guard format.isRaster else {
            throw ExportError.writeFailed("\(format.rawValue) is not a raster format")
        }
        let image = try renderBitmap(scene: scene, options: options, dpi: dpi)

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData, format.utType.identifier as CFString, 1, nil
        ) else {
            throw ExportError.imageEncodingFailed
        }

        // DPI metadata so the file prints/places at the right physical size; JPEG
        // gets a compression-quality option (other formats use sensible defaults).
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        if format == .jpg {
            props[kCGImageDestinationLossyCompressionQuality] =
                Swift.min(Swift.max(jpegQuality, 0), 1)
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed("\(format.rawValue) finalize failed")
        }
        return mutableData as Data
    }

    /// Renders `scene` into a white-backed RGBA `CGImage` at `dpi`. Shared by every
    /// raster format so the only per-format difference is the encoder.
    private static func renderBitmap(scene: ExportScene,
                                     options: ExportOptions,
                                     dpi: Double) throws -> CGImage {
        let xform = ExportTransform(bounds: scene.bounds, options: options)
        let scale = dpi / 72.0
        let pxW = Swift.max(1, Int((xform.pageSize.width * scale).rounded()))
        let pxH = Swift.max(1, Int((xform.pageSize.height * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ExportError.contextCreationFailed
        }

        // Bitmap origin is bottom-left, y-up. Flip to top-left (y-down) AND apply
        // the DPI scale so the shared renderer's page-point math fills the bitmap.
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.setShouldAntialias(true)
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: xform,
                             background: options.background ?? .white)

        guard let image = ctx.makeImage() else { throw ExportError.imageEncodingFailed }
        return image
    }
}
