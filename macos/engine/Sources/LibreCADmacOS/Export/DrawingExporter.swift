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
    case svg

    var fileExtension: String { rawValue }

    var utType: UTType {
        switch self {
        case .pdf: return .pdf
        case .png: return .png
        case .svg: return UTType(filenameExtension: "svg") ?? .svg
        }
    }

    var displayName: String {
        switch self {
        case .pdf: return "PDF Document"
        case .png: return "PNG Image"
        case .svg: return "SVG Vector"
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

    /// Exports `drawing` to `url` in `format` under `options`. Returns the number
    /// of drawn elements (polylines + fills) for a status message.
    @discardableResult
    static func export(_ drawing: CADDrawing,
                       to url: URL,
                       format: ExportFormat,
                       options: ExportOptions = ExportOptions(background: .white)) throws -> Int {
        switch format {
        case .svg:
            let svg = SVGExporter.string(for: drawing, options: options)
            do {
                try svg.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
            // Recompute element count cheaply from a fresh scene.
            let scene = ExportSceneBuilder.build(drawing)
            return scene.polylines.count + scene.fills.count

        case .pdf:
            let scene = ExportSceneBuilder.build(drawing)
            try writePDF(scene: scene, to: url, options: options)
            return scene.polylines.count + scene.fills.count

        case .png:
            let scene = ExportSceneBuilder.build(drawing)
            try writePNG(scene: scene, to: url, options: options, dpi: 150)
            return scene.polylines.count + scene.fills.count
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

    // MARK: - PNG

    /// Writes a raster PNG of `scene` at `url` at `dpi` (white-backed).
    static func writePNG(scene: ExportScene, to url: URL, options: ExportOptions, dpi: Double) throws {
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
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: xform, background: options.background ?? .white)

        guard let image = ctx.makeImage() else { throw ExportError.imageEncodingFailed }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ExportError.imageEncodingFailed
        }
        // Record the DPI in the PNG so it prints at the right physical size.
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.writeFailed("PNG finalize failed")
        }
    }
}
