//
//  Capture.swift
//  LCShot
//
//  The `render` step: builds an `ExportScene` from the live `CanvasModel`'s drawing
//  (scoped to its ACTIVE space, like the on-screen canvas) and rasterizes it to a
//  PNG via the SAME panel-free path `RasterExportTests` exercises
//  (`ExportSceneBuilder.build` → `DrawingExporter.rasterData`). No Metal, no window,
//  no save panel.
//
//  Background defaults to the CAD CANVAS background color (the dark-canvas clear
//  color), NOT the export-default white, so wipeout masks / dark-canvas scenes read
//  correctly. The framing is fit-to-page (the export default), which matches the
//  "fit to content" zoom a human would use to eyeball the whole drawing.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import CADEngine

@MainActor
enum Capture {

    /// The CAD canvas background color, mirrored from `CanvasTheme.dark.clearColor`
    /// `(0.07, 0.08, 0.10)`. The export `ExportOptions.background` is set to THIS
    /// (not the default white) so dark-canvas / wipeout scenes render as they look
    /// on screen. (`CanvasTheme.dark` is an `MTLClearColor`, which would pull in
    /// MetalKit; LCShot replicates the three components as a plain `RGBAColor` so
    /// the headless target stays device-free.)
    static let canvasBackground = RGBAColor(0.07, 0.08, 0.10, 1.0)

    /// Render `model`'s drawing to a PNG at `outPath`, framed fit-to-page on the CAD
    /// canvas background. Optionally writes a `<name>.assert.json` sidecar (entity
    /// count / selection count / world bbox). Returns the written PNG URL.
    @discardableResult
    static func render(model: CanvasModel,
                       to outPath: String,
                       dpi: Double,
                       background: RGBAColor,
                       writeAssert: Bool) throws -> URL {
        // Scope the scene to the model's ACTIVE space — the export twin of what the
        // live canvas shows (model space, or the active paper layout), instead of
        // unioning model + every layout.
        let space = DrawingExporter.exportSpace(forActiveSpace: model.activeSpace,
                                                layout: model.activeLayout)
        let scene = ExportSceneBuilder.build(model.drawing, space: space)

        let options = ExportOptions(pageSize: .usLetter,
                                    margin: 18,
                                    scaling: .fitToPage,
                                    background: background)

        let data = try DrawingExporter.rasterData(scene: scene,
                                                  options: options,
                                                  dpi: dpi,
                                                  format: .png)

        let url = URL(fileURLWithPath: outPath)
        // Ensure the parent directory exists (e.g. macos/build/harness-shots/).
        let dir = url.deletingLastPathComponent()
        if !dir.path.isEmpty {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LCShotError(message: "could not write PNG to \(outPath): \(error)")
        }

        if writeAssert {
            try writeAssertSidecar(model: model, scene: scene, pngURL: url)
        }
        return url
    }

    // MARK: - Assert sidecar

    /// Writes a `<name>.assert.json` next to the PNG, capturing facts a coordinator
    /// can diff WITHOUT opening the image: total entity count, current selection
    /// count, and the rendered scene's world-space bounding box.
    private static func writeAssertSidecar(model: CanvasModel,
                                           scene: ExportScene,
                                           pngURL: URL) throws {
        let b = scene.bounds
        let bboxObj: Any = b.isEmpty
            ? NSNull()
            : ["minX": b.min.x, "minY": b.min.y, "maxX": b.max.x, "maxY": b.max.y]

        let payload: [String: Any] = [
            "entityCount": model.drawing.entities.count,
            "selectionCount": model.selection.ids.count,
            "polylineCount": scene.polylines.count,
            "fillCount": scene.fills.count,
            "imageCount": scene.images.count,
            "bbox": bboxObj,
        ]
        let assertURL = pngURL.deletingPathExtension()
            .appendingPathExtension("assert.json")
        let json = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: assertURL, options: .atomic)
        print("LCShot: wrote assert sidecar \(assertURL.path)")
    }
}
