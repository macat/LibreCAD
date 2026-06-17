//
//  RasterExportTests.swift
//  CADEngineTests
//
//  Unit tests for the app-target raster export pipeline (`DrawingExporter`'s
//  PNG/JPEG/BMP/TIFF path + the DPI control). The app type is reached via the
//  established `_Shared*` symlink convention (`_SharedDrawingExporter.swift`),
//  alongside the already-symlinked `_SharedCGSceneRenderer.swift` /
//  `_SharedPrintLayout.swift`.
//
//  Coverage (per the raster-export acceptance bar):
//    - the `ExportFormat` → `UTType` / file-extension map is correct for ALL formats,
//    - the pure `rasterData(...)` writer produces non-empty, valid (decode-back) image
//      data for each raster format at a given DPI,
//    - DPI scales the output pixel dimensions (2× DPI ⇒ ~2× pixels each axis),
//    - PNG output is unchanged at the default DPI (regression guard: the pixel size a
//      150-DPI render produces matches the historical page-points × (150/72) sizing),
//    - JPEG honors a compression-quality option (lower quality ⇒ smaller bytes),
//    - the vector formats (`pdf`/`svg`) throw from the raster-only `rasterData`.
//
//  NO save panel / NO modal is reached — `rasterData` is the pure, in-memory writer
//  (the `NSSavePanel` stays in the View layer). A tiny test-only `LayoutRenderer`
//  STUB satisfies the symlinked `DrawingExporter`'s paper-space PDF reference at
//  compile time; it is never invoked here (the modal `DrawingPrinter.swift` that owns
//  the real `LayoutRenderer` is deliberately kept OUT of the headless test target).
//
//  Suite/type names are domain-namespaced (`RasterExport*`) per CONVENTIONS to avoid
//  the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import CADEngine

// MARK: - Test-only stub for the (modal-printer-owned) LayoutRenderer

/// The real `LayoutRenderer` lives in `DrawingPrinter.swift`, which imports AppKit
/// and runs `NSPrintOperation.runModal` — pulling that into the headless test target
/// would risk the modal-hang trap. The symlinked `DrawingExporter.swift` only
/// *references* `LayoutRenderer` from its paper-space PDF helper, which these tests
/// never call, so a compile-only stub (same name + `draw` shape) is sufficient.
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

// MARK: - ExportFormat map

@Suite("RasterExport: format map")
struct RasterExportFormatMapTests {

    @Test("every ExportFormat maps to the expected UTType")
    func utTypeMap() {
        #expect(ExportFormat.pdf.utType == .pdf)
        #expect(ExportFormat.png.utType == .png)
        #expect(ExportFormat.jpg.utType == .jpeg)
        #expect(ExportFormat.bmp.utType == .bmp)
        #expect(ExportFormat.tiff.utType == .tiff)
        // SVG has no canonical system UTType constant; it resolves from the extension.
        #expect(ExportFormat.svg.utType.preferredFilenameExtension == "svg")
    }

    @Test("every ExportFormat maps to the expected file extension")
    func extensionMap() {
        #expect(ExportFormat.pdf.fileExtension == "pdf")
        #expect(ExportFormat.png.fileExtension == "png")
        #expect(ExportFormat.jpg.fileExtension == "jpg")
        #expect(ExportFormat.bmp.fileExtension == "bmp")
        #expect(ExportFormat.tiff.fileExtension == "tiff")
        #expect(ExportFormat.svg.fileExtension == "svg")
    }

    @Test("the new raster formats are present in CaseIterable.allCases")
    func allCasesContainsNewFormats() {
        let all = Set(ExportFormat.allCases)
        #expect(all.isSuperset(of: [.pdf, .png, .jpg, .bmp, .tiff, .svg]))
    }

    @Test("isRaster classifies PNG/JPEG/BMP/TIFF as raster and PDF/SVG as not")
    func isRasterClassification() {
        #expect(ExportFormat.png.isRaster)
        #expect(ExportFormat.jpg.isRaster)
        #expect(ExportFormat.bmp.isRaster)
        #expect(ExportFormat.tiff.isRaster)
        #expect(!ExportFormat.pdf.isRaster)
        #expect(!ExportFormat.svg.isRaster)
    }

    @Test("each raster format's UTType identifier is a CGImageDestination-writable type")
    func destinationSupportsEachRasterFormat() {
        for fmt in [ExportFormat.png, .jpg, .bmp, .tiff] {
            let supported = CGImageDestinationCopyTypeIdentifiers() as NSArray
            #expect(supported.contains(fmt.utType.identifier as String),
                    "ImageIO cannot write \(fmt.rawValue) (\(fmt.utType.identifier))")
        }
    }
}

// MARK: - Raster writer

@MainActor
@Suite("RasterExport: writer")
struct RasterExportWriterTests {

    /// The canonical small export fixture (line + circle) — geometry-only so no font
    /// provider is required (matches the non-text portion of the SVG fixture).
    private func sampleScene() -> ExportScene {
        let d = CADDrawing()
        d.add(EntityRecord(id: EntityID(0),
                           kind: .line(LineData(start: Vector(0, 0), end: Vector(100, 0)))))
        d.add(EntityRecord(id: EntityID(0),
                           kind: .circle(CircleData(center: Vector(50, 50), radius: 25))))
        return ExportSceneBuilder.build(d)
    }

    private var fitOptions: ExportOptions {
        ExportOptions(pageSize: .usLetter, margin: 18,
                      scaling: .fitToPage, background: .white)
    }

    /// Decode encoded image `Data` back to pixel dimensions (validity + size check).
    private func decodedPixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard !data.isEmpty,
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (img.width, img.height)
    }

    @Test("each raster format produces non-empty, decode-valid image data")
    func everyFormatDecodes() throws {
        let scene = sampleScene()
        for fmt in [ExportFormat.png, .jpg, .bmp, .tiff] {
            let data = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                      dpi: 150, format: fmt)
            #expect(!data.isEmpty, "\(fmt.rawValue) produced empty data")
            let size = decodedPixelSize(data)
            #expect(size != nil, "\(fmt.rawValue) did not decode back to an image")
            if let s = size {
                #expect(s.w > 0 && s.h > 0, "\(fmt.rawValue) decoded to a zero size")
            }
        }
    }

    @Test("the page sizing matches page-points × (dpi/72) for a raster render")
    func pixelSizeMatchesPagePointsAndDPI() throws {
        let scene = sampleScene()
        let xform = ExportTransform(bounds: scene.bounds, options: fitOptions)
        let dpi = 150.0
        let scale = dpi / 72.0
        let expectedW = Int((xform.pageSize.width * scale).rounded())
        let expectedH = Int((xform.pageSize.height * scale).rounded())

        let data = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                  dpi: dpi, format: .png)
        let size = try #require(decodedPixelSize(data))
        #expect(size.w == expectedW)
        #expect(size.h == expectedH)
    }

    @Test("doubling DPI doubles the output pixel dimensions on both axes")
    func dpiScalesPixels() throws {
        let scene = sampleScene()

        let low = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                 dpi: 75, format: .png)
        let high = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                  dpi: 150, format: .png)
        let lo = try #require(decodedPixelSize(low))
        let hi = try #require(decodedPixelSize(high))

        // 150 DPI is exactly 2× 75 DPI; allow ±1 px for independent rounding per axis.
        #expect(abs(hi.w - 2 * lo.w) <= 1, "width did not ~double (lo=\(lo.w) hi=\(hi.w))")
        #expect(abs(hi.h - 2 * lo.h) <= 1, "height did not ~double (lo=\(lo.h) hi=\(hi.h))")
    }

    @Test("PNG output is byte-identical at the default DPI (regression guard)")
    func pngUnchangedAtDefaultDPI() throws {
        // The default raster DPI must remain 150 (the historical PNG default).
        #expect(DrawingExporter.defaultRasterDPI == 150)

        let scene = sampleScene()
        // Re-encoding the same scene at the same DPI is deterministic → identical bytes.
        let a = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                               dpi: DrawingExporter.defaultRasterDPI, format: .png)
        let b = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                               dpi: DrawingExporter.defaultRasterDPI, format: .png)
        #expect(a == b)
        #expect(!a.isEmpty)

        // The decoded PNG carries the recorded 150-DPI sizing the old path produced.
        let xform = ExportTransform(bounds: scene.bounds, options: fitOptions)
        let scale = DrawingExporter.defaultRasterDPI / 72.0
        let size = try #require(decodedPixelSize(a))
        #expect(size.w == Int((xform.pageSize.width * scale).rounded()))
        #expect(size.h == Int((xform.pageSize.height * scale).rounded()))
    }

    @Test("JPEG honors the compression-quality option (lower quality ⇒ smaller bytes)")
    func jpegQualityAffectsSize() throws {
        let scene = sampleScene()
        let high = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                  dpi: 150, format: .jpg, jpegQuality: 0.95)
        let low = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                 dpi: 150, format: .jpg, jpegQuality: 0.1)
        #expect(!high.isEmpty && !low.isEmpty)
        #expect(low.count < high.count,
                "low-quality JPEG (\(low.count)B) was not smaller than high (\(high.count)B)")
    }

    @Test("rasterData rejects the vector (non-raster) formats")
    func rasterDataRejectsVectorFormats() {
        let scene = sampleScene()
        for fmt in [ExportFormat.pdf, .svg] {
            #expect(throws: ExportError.self) {
                _ = try DrawingExporter.rasterData(scene: scene, options: fitOptions,
                                                   dpi: 150, format: fmt)
            }
        }
    }

    @Test("writeRaster writes valid on-disk image data for each raster format")
    func writeRasterToDiskRoundTrips() throws {
        let scene = sampleScene()
        let tmp = FileManager.default.temporaryDirectory
        for fmt in [ExportFormat.png, .jpg, .bmp, .tiff] {
            let url = tmp.appendingPathComponent("rasterexport-test-\(UUID().uuidString).\(fmt.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try DrawingExporter.writeRaster(scene: scene, to: url, options: fitOptions,
                                            dpi: 96, format: fmt)
            let onDisk = try Data(contentsOf: url)
            let size = decodedPixelSize(onDisk)
            #expect(size != nil, "\(fmt.rawValue) on-disk file did not decode")
            if let s = size { #expect(s.w > 0 && s.h > 0) }
        }
    }
}
