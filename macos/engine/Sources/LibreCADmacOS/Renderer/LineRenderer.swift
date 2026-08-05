//
//  LineRenderer.swift
//  LibreCADmacOS
//
//  The Metal renderer. Owns the two pipelines (instanced lines + flat overlay),
//  persistent buffers, and triple-buffered uniforms. It is the `MTKViewDelegate`
//  driving the on-demand draw loop.
//
//  Architecture (rendering-performance.md):
//    - Geometry lives in WORLD coordinates (as f32 offsets from `renderOrigin`,
//      ADR-003) in a persistent instance buffer. PAN/ZOOM only change the
//      `world→clip` matrix uniform — the instance buffer is NOT rebuilt for a
//      view change (§4.1).
//    - Each segment is ONE instance expanded to a screen-space quad in the vertex
//      shader (constant pixel width) with analytic edge AA + round caps in the
//      fragment shader (§1.1).
//    - The visible set is gathered via `quadtree.query(region:)` (§2.3 culling)
//      over a region PADDED past the literal visible rect, and the visible
//      entities' segments are packed into the instance buffer — only when the
//      model changed OR the current visible rect ESCAPED the padded region. A
//      pan/zoom that stays within the cached margin is matrix-only (zero buffer
//      rebuild), satisfying the §4.1 "pan/zoom only change the matrix" contract.
//    - Triple-buffered uniforms (§4.5) so the CPU can write frame N+1's matrix
//      while the GPU renders frame N, gated by a semaphore.
//
//  All renderer state is `@MainActor` (MTKView delegate callbacks are main-thread
//  and we share the main-actor `CanvasModel`/`Quadtree`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import AppKit
import CoreGraphics
import MetalKit
import simd
import CADEngine

/// The uniform struct uploaded to both pipelines (matches `struct Uniforms` in
/// the Metal source: a transform + the drawable pixel size).
private struct CanvasUniforms {
    var transform: matrix_float4x4
    var viewportPx: SIMD2<Float>
    // Pad to 16-byte alignment for the float4x4 + float2 (Metal `constant` layout
    // already aligns float4x4 to 16; the trailing float2 needs no extra padding
    // here since the struct is only read, never arrayed).
}

/// The per-draw image display knobs (matches `struct ImageParams` in the Metal
/// source): brightness/contrast in [0,1] (DXF 281/282 ÷ 100, 0.5 == neutral) and
/// opacity (`1 - fade/100`). One is set per textured-quad draw call.
private struct ImageParams {
    var brightness: Float
    var contrast: Float
    var opacity: Float
}

// MARK: - Render preferences (Rendering ▸ antialias / LOD / default line width)

/// The resolved Rendering preferences the renderer consumes, derived purely from
/// the stored `AppSettings` values (or their defaults when unset). Kept as a small
/// VALUE type with NO Metal dependency so it is unit-testable headlessly
/// (`PrefsWiringTests`) and so a missing pref always falls back to today's behavior.
///
/// What each knob drives at the render path:
///   • `antialias`        — whether the analytic edge-AA stroke keeps its soft
///                          ~half-pixel feather. When OFF, lines are drawn at a
///                          crisp minimum width with no AA bleed (a hard hairline).
///   • `quality` (LOD)    — scales the tessellation tolerance the resolve context
///                          uses: High = finest curves, Low = coarser (fewer
///                          segments, faster). Maps to a multiplier on the engine's
///                          default tolerance.
///   • `lineHalfWidthPx`  — the per-segment device-pixel half-width every stroke is
///                          packed with. Derived from the stored default line width
///                          (mm) via the points-per-mm scale; 0 mm (the sentinel)
///                          keeps the renderer's hairline default.
struct RenderPrefs: Equatable, Sendable {
    var antialias: Bool
    var quality: RenderQuality
    /// Stored default line width in millimeters (0 = "by default" → hairline).
    var defaultLineWidthMM: Double

    /// Today's defaults — what an untouched install resolves to. Identical to the
    /// pre-prefs renderer behavior (AA on, high LOD, hairline default width).
    static let standard = RenderPrefs(
        antialias: AppSettings.Default.antialias,
        quality: AppSettings.Default.renderQuality,
        defaultLineWidthMM: AppSettings.Default.defaultLineWidthMM)

    /// Reads the three Rendering prefs from `UserDefaults` (the `@AppStorage` keys),
    /// each falling back to its `AppSettings.Default` when the key is unset — so a
    /// user who never opened Preferences gets `.standard` (today's behavior).
    static func fromDefaults(_ d: UserDefaults = .standard) -> RenderPrefs {
        let antialias = d.object(forKey: AppSettings.Key.antialias) == nil
            ? AppSettings.Default.antialias
            : d.bool(forKey: AppSettings.Key.antialias)
        let quality = (d.string(forKey: AppSettings.Key.renderQuality)
            .flatMap(RenderQuality.init(rawValue:))) ?? AppSettings.Default.renderQuality
        let widthMM = d.object(forKey: AppSettings.Key.defaultLineWidthMM) == nil
            ? AppSettings.Default.defaultLineWidthMM
            : d.double(forKey: AppSettings.Key.defaultLineWidthMM)
        return RenderPrefs(antialias: antialias, quality: quality,
                           defaultLineWidthMM: AppSettings.clampLineWidthMM(widthMM))
    }

    /// The device-pixel half-width every stroke is packed with, for a given backing
    /// `scale` (points→pixels, e.g. 2 on Retina). A 0 mm stored width keeps the
    /// renderer's hairline default (`RendererGeometry.defaultHalfWidthPx`); a
    /// positive width converts mm→points (1 pt ≈ 1/72 in ≈ 0.3528 mm) → device px.
    /// When antialias is OFF we floor the half-width to a crisp 0.5 px (a 1 px hard
    /// stroke) so a hairline reads sharp without the AA feather.
    func lineHalfWidthPx(backingScale scale: CGFloat) -> Float {
        let s = Float(scale > 0 ? scale : 1)
        let base: Float
        if defaultLineWidthMM > 0 {
            // mm → points → device px, halved (the instance stores HALF width).
            let pts = Float(defaultLineWidthMM) / RenderPrefs.mmPerPoint
            base = max(RendererGeometry.defaultHalfWidthPx, pts * s * 0.5)
        } else {
            base = RendererGeometry.defaultHalfWidthPx
        }
        // No-AA: floor to a crisp 0.5px half-width (1px hard stroke) so the line is
        // sharp, never thinner than a visible pixel.
        return antialias ? base : max(0.5, base)
    }

    /// Millimeters per typographic point (1 pt = 1/72 inch, 1 inch = 25.4 mm).
    static let mmPerPoint: Float = 25.4 / 72.0

    /// The engine's default tessellation tolerance (mirrors the default argument of
    /// `CADDrawing.makeResolveContext`) — the High-LOD value the quality tier scales.
    static let defaultTessellationTolerance: Double = 0.05

    /// The tessellation tolerance multiplier for this LOD tier, applied to the
    /// engine's default tolerance (smaller = finer curves). High keeps the default
    /// (1×), Medium is a touch coarser, Low coarsest (fewer segments → faster).
    var tessellationToleranceScale: Double {
        switch quality {
        case .high:   return 1.0
        case .medium: return 2.0
        case .low:    return 4.0
        }
    }
}

@MainActor
final class LineRenderer: NSObject, MTKViewDelegate {

    // MARK: Dependencies

    /// Shared canvas state (model, viewport, index, selection, snap).
    private let model: CanvasModel

    /// The resolved Rendering preferences (antialias / LOD / default line width).
    /// RE-READ from `UserDefaults` at the top of every `draw(in:)` (each key falls
    /// back to its default when unset → today's behavior for a user who never opened
    /// Preferences) so a change in Preferences ▸ Rendering takes effect on the next
    /// redraw of an ALREADY-OPEN window — not only on windows opened afterwards
    /// (finding #30). It was previously a `let` frozen at init, which made the
    /// Rendering controls dead for open windows. The half-width feeds every packed
    /// stroke; the LOD scales the resolve tolerance. `refreshRenderPrefs()` detects a
    /// change and forces the line/fill buffer + resolve-context rebuild that bakes the
    /// new width/LOD in (the prefs are NOT consumed per-frame otherwise — they're read
    /// into the cull/resolve path, so a stale value would otherwise persist until the
    /// next model edit). NOTE: an IDLE window still needs an external `setNeedsDisplay`
    /// to repaint at all; this only guarantees the next paint is correct (see report).
    private var renderPrefs: RenderPrefs = .fromDefaults()

    /// Grid spacing chosen on the last frame (fed to snapping). Read by the
    /// interaction layer so grid-snap matches the drawn grid.
    private(set) var lastGridSpacing: Double = 1

    /// The latest backing scale (points→device-pixels) seen from the view, used to
    /// convert the stored default line width (mm) into device pixels. Updated each
    /// frame from the drawable; defaults to 2 (a typical Retina display) so the very
    /// first frame before a window exists is still reasonable.
    private var backingScale: CGFloat = 2

    // MARK: Metal objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var linePipeline: MTLRenderPipelineState?
    private var flatPipeline: MTLRenderPipelineState?
    /// The textured-quad pipeline for raster IMAGE entities (alpha-blended, sRGB).
    private var imagePipeline: MTLRenderPipelineState?

    /// Texture cache keyed by the image source file path (`ResolvedImage.textureKey`).
    /// An entry is `nil` when the file is missing/unloadable, so we don't re-attempt
    /// to load it every frame; the draw pass then falls back to the placeholder
    /// outline. Cleared only if a model change introduces new image keys (we never
    /// evict — a CAD drawing has a bounded number of distinct images).
    private var textureCache: [String: MTLTexture?] = [:]

    // MARK: Persistent buffers

    /// The instanced-line buffer (per-segment `LineInstance`s). Rebuilt on model
    /// change or visible-set change; NEVER on a matrix-only pan/zoom.
    private var lineInstanceBuffer: MTLBuffer?
    private var lineInstanceCount = 0
    private var lineBufferCapacity = 0

    /// The fill triangle buffer (`FlatVertex`, render-space f32 offsets + color),
    /// drawn with the flat pipeline as `.triangle` primitives BEFORE the lines so
    /// stroked edges overlay the fill. Rebuilt on the SAME model/visible-set change
    /// as the line buffer (never on a matrix-only pan/zoom).
    private var fillVertexBuffer: MTLBuffer?
    private var fillVertexCount = 0
    private var fillBufferCapacity = 0

    /// The WIPEOUT mask triangle buffer (`FlatVertex`). Separate from the fill buffer
    /// because a wipeout must paint the CANVAS BACKGROUND color in a dedicated pass
    /// drawn AFTER the model lines (so it masks lower fills AND lower strokes — the
    /// fill pass at 1b is unconditionally UNDER the lines, so a normal fill could
    /// never hide a stroke). Packed in the SAME cull rebuild as the fill buffer (from
    /// `ResolvedFill.isMask` fills), then RE-COLORED + uploaded each frame with the
    /// live `view.clearColor` (the engine is view-free, so the resolve carries only a
    /// fallback color + the `isMask` flag; the renderer supplies the real background).
    /// Empty for every drawing with no wipeout, so non-wipeout rendering is unchanged.
    private var wipeoutVertexBuffer: MTLBuffer?
    private var wipeoutVertexCount = 0
    private var wipeoutBufferCapacity = 0

    /// The overlay vertex buffer (grid + selection + snap marker, flat-shaded).
    private var overlayBuffer: MTLBuffer?
    private var overlayVertexCount = 0
    private var overlayCapacity = 0
    /// Overlay buffer spans, in DRAW (and storage) order: the paper SHEET (paper-
    /// space P2 — drawn FIRST, under everything), then grid, selection, snap, the
    /// tool-preview, and the dashed reference guide LAST. All drawn as `.line`
    /// primitives in one buffer.
    private var sheetVertexCount = 0
    private var gridVertexCount = 0
    private var selectionVertexCount = 0
    private var snapVertexCount = 0
    private var previewVertexCount = 0
    private var referenceVertexCount = 0

    // MARK: Triple-buffered uniforms (§4.5)

    private static let maxInFlight = 3
    private var uniformBuffers: [MTLBuffer] = []
    private let inFlightSemaphore = DispatchSemaphore(value: maxInFlight)
    private var uniformIndex = 0

    // MARK: Dirty tracking

    /// The model version the instance buffer was built for. A mismatch forces a
    /// model rebuild.
    private var builtModelVersion = -1
    /// The PADDED visible rect the instance buffer was built for. We cull a region
    /// LARGER than the literal visible rect (by `Self.cullMargin`) so steady-state
    /// pan/zoom that stays WITHIN this margin is matrix-only (no rebuild). A new
    /// visible rect that escapes the padded region forces a culled rebuild
    /// (rendering-performance.md §4.1 — pan/zoom must not repack the buffer).
    private var builtVisibleRect: AABB = .empty

    /// How far past the literal visible rect we cull, as a fraction of the rect's
    /// own extent on each side. A small pan/zoom inside this padded region reuses
    /// the existing buffer (zero rebuild); only a view change that escapes it
    /// re-culls. Single source of truth in `RendererCull`.
    private static let cullMargin = RendererCull.defaultMargin

    // MARK: - Renderer dirty-set (Wave P5)

    /// Per-entity geometry cache for dirty rebuild — only re-resolves
    /// `dirty ∩ visible`, reuses the rest. Keyed by `EntityID`, value is
    /// the packed geometry that entity contributed at its `resolveVersion`.
    private var entityGeometryCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
    /// The ordered visible ids the cache was last built for (for dirty diff).
    private var lastVisibleOrdered: [EntityID] = []

    // MARK: Cull scratch (reused; no per-frame heap allocation, §2.3)

    /// Persistent scratch the cull rebuild packs into, cleared with
    /// `keepingCapacity` each rebuild so a steady drawing never re-allocates the
    /// backing storage (rendering-performance.md §2.3 — no per-frame heap churn).
    private var instanceScratch: [LineInstance] = []

    /// Persistent scratch for the fill triangle vertices, packed in the SAME cull
    /// rebuild as `instanceScratch` (cleared keepingCapacity → no per-frame churn).
    private var fillScratch: [FlatVertex] = []

    /// Persistent scratch for the WIPEOUT mask triangle vertices (the `isMask` fills),
    /// packed in the SAME cull rebuild as `fillScratch`. Its vertices carry a
    /// placeholder color; the draw pass re-stamps the live `view.clearColor` before
    /// uploading. Cleared keepingCapacity → no per-frame churn.
    private var wipeoutScratch: [FlatVertex] = []

    /// Resolved raster-image quads from the current cull rebuild (one per visible
    /// IMAGE entity). Drawn by the textured-quad pass after the fills, under the
    /// model lines so the frame outline overlays the image. A CAD drawing has few
    /// images, so a per-image draw call (binding its cached texture) is cheap;
    /// rebuilt on the SAME model/visible-set change as the line + fill buffers.
    private var imageScratch: [ImageQuad] = []

    /// Cached resolve context, rebuilt ONLY when the model changes (the layer
    /// table snapshot is stable between edits), not per cull.
    private var cachedResolveContext: ResolveContext?
    /// The model version `cachedResolveContext` was built for.
    private var resolveContextVersion = -1

    // MARK: Init

    /// Creates the renderer. Returns `nil` if no Metal device / command queue is
    /// available (so the caller can surface a visible error).
    init?(model: CanvasModel, device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else {
            NSLog("LineRenderer: makeCommandQueue() returned nil")
            return nil
        }
        self.model = model
        self.device = device
        self.commandQueue = queue
        super.init()
        buildPipelines(pixelFormat: .bgra8Unorm_srgb)
        buildUniformBuffers()
    }

    // MARK: - Pipeline construction (once)

    private func buildPipelines(pixelFormat: MTLPixelFormat) {
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: canvasMetalSource, options: nil)
        } catch {
            // LOUD in DEBUG (assertionFailure is a no-op in release, so this does
            // NOT crash shipping builds). A swallowed shader-compile error here
            // renders a BLANK canvas with no obvious cause — it shipped that way
            // twice (a var named `half`, a reserved MSL type). Make a future
            // break impossible to miss during development. The runtime test
            // `ShaderCompileTests` is the first line of defence; this is the
            // second, for shader changes that slip past it.
            NSLog("LineRenderer: shader compile failed: \(error)")
            assertionFailure("LineRenderer: shader compile failed: \(error)")
            return
        }

        // ---- Instanced line pipeline (no vertex descriptor: shader reads the
        // instance buffer directly via [[instance_id]] + [[vertex_id]]).
        if let vfn = library.makeFunction(name: "line_vertex"),
           let ffn = library.makeFunction(name: "line_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = pixelFormat
            configureAlphaBlend(desc.colorAttachments[0])
            do {
                linePipeline = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("LineRenderer: line pipeline failed: \(error)")
                assertionFailure("LineRenderer: line pipeline failed: \(error)")
            }
        } else {
            NSLog("LineRenderer: missing line shader functions")
            assertionFailure("LineRenderer: missing line shader functions (line_vertex/line_fragment)")
        }

        // ---- Flat overlay pipeline.
        if let vfn = library.makeFunction(name: "flat_vertex"),
           let ffn = library.makeFunction(name: "flat_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = pixelFormat
            configureAlphaBlend(desc.colorAttachments[0])
            do {
                flatPipeline = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("LineRenderer: flat pipeline failed: \(error)")
                assertionFailure("LineRenderer: flat pipeline failed: \(error)")
            }
        } else {
            NSLog("LineRenderer: missing flat shader functions")
            assertionFailure("LineRenderer: missing flat shader functions (flat_vertex/flat_fragment)")
        }

        // ---- Textured-quad pipeline (raster IMAGE entities).
        if let vfn = library.makeFunction(name: "image_vertex"),
           let ffn = library.makeFunction(name: "image_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.colorAttachments[0].pixelFormat = pixelFormat
            configureAlphaBlend(desc.colorAttachments[0])
            do {
                imagePipeline = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("LineRenderer: image pipeline failed: \(error)")
                assertionFailure("LineRenderer: image pipeline failed: \(error)")
            }
        } else {
            NSLog("LineRenderer: missing image shader functions")
            assertionFailure("LineRenderer: missing image shader functions (image_vertex/image_fragment)")
        }
    }

    private func configureAlphaBlend(_ a: MTLRenderPipelineColorAttachmentDescriptor) {
        a.isBlendingEnabled = true
        a.rgbBlendOperation = .add
        a.alphaBlendOperation = .add
        a.sourceRGBBlendFactor = .sourceAlpha
        a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    private func buildUniformBuffers() {
        uniformBuffers = (0..<Self.maxInFlight).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<CanvasUniforms>.stride,
                              options: .storageModeShared)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Update the viewport's POINT size from the resize callback directly, so the
        // first post-resize frame's `worldToClip` matrix already uses the new size —
        // we do NOT rely solely on SwiftUI's `updateNSView` ordering (which can lag
        // the drawable-size change by a frame and briefly skew the aspect/scale).
        // `size` is in device pixels; convert to points via the backing scale.
        let backing = view.window?.backingScaleFactor
            ?? view.layer?.contentsScale
            ?? 1.0
        let scale = backing > 0 ? backing : 1.0
        let pointSize = CGSize(width: size.width / scale, height: size.height / scale)
        model.setViewSize(pointSize)
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else { return }

        // Track the current backing scale so the stored default line width (mm) is
        // converted to the right device-pixel half-width on this display.
        backingScale = view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? backingScale

        // Re-read the Rendering prefs (antialias / LOD / default width) so a change
        // in Preferences ▸ Rendering applies to THIS already-open window's next paint
        // (finding #30). When they actually changed, this forces the line/fill +
        // resolve-context rebuild that bakes the new half-width / tessellation LOD in.
        refreshRenderPrefs()

        // Refresh model/overlay geometry if needed (NOT on matrix-only pan/zoom).
        let visibleRect = model.viewport.visibleWorldRect
        rebuildLineInstancesIfNeeded(visibleRect: visibleRect)
        rebuildOverlay(viewport: model.viewport)

        // Re-color + upload the WIPEOUT masks every frame with the LIVE canvas
        // background (`view.clearColor`), so a wipeout paints exactly the background
        // color even after a theme / preference change (no cull rebuild needed). The
        // mask TRIANGLES come from the cull rebuild; only their color varies per frame.
        let cc = view.clearColor
        let bg = SIMD4<Float>(Float(cc.red), Float(cc.green), Float(cc.blue), Float(cc.alpha))
        uploadWipeoutVertices(backgroundColor: bg)

        // ---- Triple-buffered uniform write, gated so we never overwrite a
        // uniform buffer the GPU is still reading.
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        uniformIndex = (uniformIndex + 1) % Self.maxInFlight
        let uniformBuffer = uniformBuffers[uniformIndex]
        writeUniforms(into: uniformBuffer, drawableSize: view.drawableSize)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            inFlightSemaphore.signal()
            return
        }

        // ---- 0. Paper SHEET + margin border (paper-space P2) — drawn FIRST, under
        // the grid/model, so on a layout the sheet reads as the page the geometry
        // sits on. Empty (zero verts) in model space, so model-space rendering is
        // byte-for-byte unchanged. Lives at the FRONT of the overlay buffer.
        if let flatPipeline, let overlayBuffer, sheetVertexCount >= 2 {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: sheetVertexCount)
        }

        // ---- 1. Grid (under the model, over the sheet).
        if let flatPipeline, let overlayBuffer, gridVertexCount >= 2 {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: sheetVertexCount,
                                   vertexCount: gridVertexCount)
        }

        // ---- 1b. Fills (hatch/solid triangles) — UNDER the model lines so stroked
        // edges overlay the fill (rendering-performance.md §1.3). Shares the flat
        // pipeline with the overlay (alpha-blended, sRGB) so semi-transparent fills
        // composite using the fill color's alpha.
        if let flatPipeline, let fillVertexBuffer, fillVertexCount >= 3 {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(fillVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fillVertexCount)
        }

        // ---- 1c. Raster images (textured quads) — UNDER the model lines so the
        // frame outline (a model polyline) overlays the image, and over the grid/
        // fills. A missing/unloadable texture (or a hidden image) draws nothing here
        // (its frame still shows via the model-line pass). One draw per image, each
        // binding its cached texture; a CAD drawing has few images.
        drawImages(encoder: encoder, uniformBuffer: uniformBuffer)

        // ---- 2. Model lines (instanced quads).
        if let linePipeline, let lineInstanceBuffer, lineInstanceCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(lineInstanceBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: lineInstanceCount)
        }

        // ---- 2b. WIPEOUT masks — background-colored triangles drawn AFTER the model
        // lines (and fills/images) so a wipeout HIDES every lower-draw-order entity
        // beneath its boundary (fills AND strokes), the AutoCAD WIPEOUT behavior.
        // Drawn BEFORE the selection/snap/preview overlay (pass 3) so a selected
        // wipeout still shows its highlight on top. The triangles were re-colored to
        // the live `view.clearColor` in `uploadWipeoutVertices`. Empty (no draw) for
        // any drawing without a wipeout, so non-wipeout rendering is unchanged.
        //
        // LIMITATION (documented): a single post-line pass masks everything below it
        // in the WHOLE drawing, so a stroke deliberately raised ABOVE a wipeout in
        // draw order is still masked (true per-entity draw-order interleaving would
        // need splitting the line batch per wipeout — deferred). For the common case
        // (a wipeout placed on top of what it hides) this is correct.
        if let flatPipeline, let wipeoutVertexBuffer, wipeoutVertexCount >= 3 {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(wipeoutVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: wipeoutVertexCount)
        }

        // ---- 3. Selection highlight + snap marker (over the model). Spans follow
        // the sheet + grid in the buffer, so each start offset includes both.
        if let flatPipeline, let overlayBuffer {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            let afterGrid = sheetVertexCount + gridVertexCount
            if selectionVertexCount >= 2 {
                encoder.drawPrimitives(type: .line, vertexStart: afterGrid,
                                       vertexCount: selectionVertexCount)
            }
            if snapVertexCount >= 2 {
                encoder.drawPrimitives(type: .line,
                                       vertexStart: afterGrid + selectionVertexCount,
                                       vertexCount: snapVertexCount)
            }
            if previewVertexCount >= 2 {
                encoder.drawPrimitives(
                    type: .line,
                    vertexStart: afterGrid + selectionVertexCount + snapVertexCount,
                    vertexCount: previewVertexCount)
            }
            // Dashed reference guide LAST (over the preview): its span follows the
            // preview in the buffer, so its start offset includes every prior span.
            if referenceVertexCount >= 2 {
                encoder.drawPrimitives(
                    type: .line,
                    vertexStart: afterGrid + selectionVertexCount + snapVertexCount
                        + previewVertexCount,
                    vertexCount: referenceVertexCount)
            }
        }

        encoder.endEncoding()

        // Signal the semaphore when this frame's GPU work completes, freeing the
        // uniform buffer for reuse (§4.5 in-flight-frames pattern).
        commandBuffer.addCompletedHandler { [inFlightSemaphore] _ in
            inFlightSemaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Render-preference refresh (finding #30 — live-apply to open windows)

    /// Re-reads the Rendering prefs from `UserDefaults` and, when they CHANGED, forces
    /// the rebuilds that bake the new values into the next frame:
    ///   • a new default line WIDTH or antialias toggle changes every stroke's packed
    ///     half-width → invalidate `builtModelVersion` so the line/fill buffer re-packs;
    ///   • a new LOD/quality tier changes the resolve tessellation tolerance →
    ///     invalidate `resolveContextVersion` so the cached `ResolveContext` is remade.
    /// Both are cheap no-ops when nothing changed (the common steady-state path: the
    /// `==` compare short-circuits and no buffer is touched), so this adds no per-frame
    /// rebuild for a user who never opens Preferences. Reading `UserDefaults` once per
    /// on-demand paint (the canvas uses `enableSetNeedsDisplay`, not a 120 Hz free-run)
    /// is negligible.
    private func refreshRenderPrefs() {
        let fresh = RenderPrefs.fromDefaults()
        guard fresh != renderPrefs else { return }
        renderPrefs = fresh
        builtModelVersion = -1
        resolveContextVersion = -1
        // Dirty-set cache is keyed on halfWidth / tessellation as well (via the
        // packed geometry). A pref change stales it, so invalidate for the next
        // rebuild to fall back to full (correctness first).
        entityGeometryCache.removeAll(keepingCapacity: true)
        lastVisibleOrdered.removeAll(keepingCapacity: true)
    }

    // MARK: - Buffer (re)builds

    /// Rebuilds the instanced-line buffer from the CULLED visible set, but ONLY
    /// when the model changed or the visible rect escaped the padded built region
    /// (rendering-performance.md §2.3 + §4.1). Matrix-only pan/zoom that stays
    /// inside the cached margin re-uses the existing buffer (zero rebuild). The
    /// pure decision + the padding/containment math live in `RendererCull` (GPU-
    /// free, unit-tested in `RendererCullTests`).
    private func rebuildLineInstancesIfNeeded(visibleRect: AABB) {
        let modelChanged = model.modelDirty || model.modelVersion != builtModelVersion
        guard RendererCull.needsRebuild(builtPaddedRect: builtVisibleRect,
                                        currentVisibleRect: visibleRect,
                                        modelChanged: modelChanged,
                                        hasBuffer: lineInstanceBuffer != nil) else { return }

        // Cull a region LARGER than the literal visible rect so subsequent small
        // pans/zooms stay inside it (matrix-only). Empty rect → fall back to the
        // raw rect so the quadtree query still runs.
        let paddedRect = RendererCull.expanded(visibleRect, byFraction: Self.cullMargin)
        let cullRect = paddedRect.isEmpty ? visibleRect : paddedRect

        // Reuse the persistent scratch (no per-frame heap allocation, §2.3) and the
        // cached resolve context (rebuilt only on model change, not per cull).
        let ctx = resolveContext(modelChanged: modelChanged)
        let origin = model.renderOrigin
        let layers = model.drawing.layers
        let activeSpace = model.activeSpace
        let activeLayout = model.activeLayout
        let blockMembers: Set<EntityID> =
            (activeSpace == .model && model.editingBlock == nil)
            ? model.drawing.blockMemberIDs : []
        let halfWidthPx = renderPrefs.lineHalfWidthPx(backingScale: backingScale)
        let identity: (SIMD4<Float>) -> SIMD4<Float> = { $0 }
        let colorTransform: (SIMD4<Float>) -> SIMD4<Float> =
            OverlayStyle.invertNearWhiteEntities ? RendererGeometry.autoInvertWhite : identity

        // Ordered visible ids (draw-order sorted, or activeSpace fallback).
        let rawVisibleIDs = model.quadtree.query(region: cullRect)
        let orderedVisibleIDs: [EntityID]
        if rawVisibleIDs.isEmpty && model.quadtree.isEmpty {
            orderedVisibleIDs = model.activeSpaceEntities.map(\.id)
        } else {
            orderedVisibleIDs = rawVisibleIDs.sorted {
                (model.drawing.storageIndex(of: $0) ?? 0) < (model.drawing.storageIndex(of: $1) ?? 0)
            }
        }

        // --- Dirty-set incremental path (Wave P5) ---
        // When the model changed and we have a prior cache, try to rebuild only
        // `dirty ∩ visible`. On first frame, empty dirty, or oversized dirty,
        // fall back to the full rebuild (correctness first).
        if modelChanged && !orderedVisibleIDs.isEmpty {
            let visibleSet = Set(orderedVisibleIDs)
            let lastVersions = Dictionary(uniqueKeysWithValues: entityGeometryCache.map { ($0.key, $0.value.version) })
            let lastVisibleSet = Set(lastVisibleOrdered)
            let dirtySet = DirtySet.computeDirty(drawing: model.drawing,
                                                 visibleIDs: visibleSet,
                                                 lastVersions: lastVersions,
                                                 lastVisible: lastVisibleSet)
            let isFirstFrame = entityGeometryCache.isEmpty
            if !dirtySet.shouldFallback(visibleCount: orderedVisibleIDs.count, isFirstFrame: isFirstFrame) {
                let previousCount = lineInstanceCount
                var cache = entityGeometryCache
                let result = RendererGeometry.rebuildDirty(
                    visibleIDs: orderedVisibleIDs,
                    dirtyIDs: dirtySet.ids,
                    lookup: { [drawing = model.drawing] id in drawing.entity(id) },
                    ctx: ctx, renderOrigin: origin, layers: layers,
                    activeSpace: activeSpace, activeLayout: activeLayout,
                    blockMembers: blockMembers,
                    halfWidthPx: halfWidthPx, backingScale: backingScale,
                    colorTransform: colorTransform, cache: &cache)

                // If rebuildDirty did NOT fall back, it already produced the
                // fully ordered visible arrays via the cache. Append viewports
                // and tables (which are not per-entity cached) then do a
                // partial or full upload.
                if !result.didFallback {
                    entityGeometryCache = cache
                    instanceScratch = result.lineInstances
                    fillScratch = result.fillVerts
                    wipeoutScratch = result.wipeoutVerts
                    imageScratch = result.imageQuads

                    // Viewport contents and tables are not dirtied per-entity;
                    // they are always re-packed. For a model-space typical
                    // drawing they are empty, so this is no-op.
                    if activeSpace == .paper, let layout = model.activeLayoutRecord, !layout.viewports.isEmpty {
                        packViewportContents(layout.viewports, ctx: ctx, origin: origin, layers: layers)
                    }
                    packTables(origin: origin)

                    // Partial upload when the entity part was small and counts stable.
                    let hasViewportOrTables = (activeSpace == .paper && !(model.activeLayoutRecord?.viewports.isEmpty ?? true))
                        || !model.drawing.tables.isEmpty
                    if !hasViewportOrTables, !result.dirtyLineRanges.isEmpty,
                       instanceScratch.count == previousCount,
                       result.dirtyLineRanges.reduce(0, { $0 + $1.count }) * 2 < instanceScratch.count {
                        uploadLineInstancesDirty(instanceScratch, dirtyRanges: result.dirtyLineRanges, previousCount: previousCount)
                    } else {
                        uploadLineInstances(instanceScratch)
                    }
                    uploadFillVertices(fillScratch)
                    lastVisibleOrdered = orderedVisibleIDs
                    builtModelVersion = model.modelVersion
                    builtVisibleRect = cullRect
                    model.modelDirty = false
                    return
                } else {
                    // rebuildDirty fell back to full (oversized); update cache
                    // and fall through to the full path below (which will rebuild
                    // consistently via the entity loop).
                    entityGeometryCache = cache
                }
            }
        }

        // --- Full rebuild (fallback / first frame / oversized / viewport escape) ---
        instanceScratch.removeAll(keepingCapacity: true)
        fillScratch.removeAll(keepingCapacity: true)
        wipeoutScratch.removeAll(keepingCapacity: true)
        imageScratch.removeAll(keepingCapacity: true)

        if rawVisibleIDs.isEmpty && model.quadtree.isEmpty {
            for e in model.activeSpaceEntities {
                packEntity(e, ctx: ctx, origin: origin, layers: layers,
                           activeSpace: activeSpace, activeLayout: activeLayout,
                           blockMembers: blockMembers)
            }
        } else {
            instanceScratch.reserveCapacity(orderedVisibleIDs.count * 2)
            for id in orderedVisibleIDs {
                guard let e = model.drawing.entity(id) else { continue }
                packEntity(e, ctx: ctx, origin: origin, layers: layers,
                           activeSpace: activeSpace, activeLayout: activeLayout,
                           blockMembers: blockMembers)
            }
        }

        if activeSpace == .paper, let layout = model.activeLayoutRecord, !layout.viewports.isEmpty {
            packViewportContents(layout.viewports, ctx: ctx, origin: origin, layers: layers)
        }
        packTables(origin: origin)

        // Refresh the per-entity cache for the next dirty pass (model-space only).
        // Rebuild it from the currently visible ordered set so future dirty
        // detection is accurate. This is O(visible) but only on full rebuilds.
        if activeSpace == .model {
            var newCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
            newCache.reserveCapacity(orderedVisibleIDs.count)
            for id in orderedVisibleIDs {
                guard let rec = model.drawing.entity(id),
                      let entry = RendererGeometry.cachedGeometry(
                        for: rec, ctx: ctx, renderOrigin: origin, layers: layers,
                        activeSpace: activeSpace, activeLayout: activeLayout,
                        blockMembers: blockMembers, halfWidthPx: halfWidthPx,
                        backingScale: backingScale, colorTransform: colorTransform) else { continue }
                newCache[id] = entry
            }
            entityGeometryCache = newCache
            lastVisibleOrdered = orderedVisibleIDs
        } else {
            // Paper space / block edit: cache not used (geometry is viewport-mapped);
            // keep last ordering for dirty diff but clear entity cache.
            entityGeometryCache.removeAll(keepingCapacity: true)
            lastVisibleOrdered = orderedVisibleIDs
        }

        uploadLineInstances(instanceScratch)
        uploadFillVertices(fillScratch)
        builtModelVersion = model.modelVersion
        builtVisibleRect = cullRect
        model.modelDirty = false
    }

    /// Packs the CONTENTS of each viewport (paper-space P3): for every viewport, the
    /// MODEL-space entities are resolved, their polylines mapped into paper space by
    /// the viewport's model→paper affine, clipped to the viewport frame, and appended
    /// as line instances. The pure transform + clip live on `LayoutViewport` (engine,
    /// GPU-free), so this is just resolve → map → clip → pack. Globally frozen/hidden
    /// layers are skipped, matching `packEntity`. Fills are NOT mapped (v1 draws
    /// viewport contents as STROKES only — a hatch shows as its boundary; fill-through-
    /// the-viewport is a follow-up).
    ///
    /// W2-2D per-viewport honoring (all defaults are no-ops, so a DEFAULT viewport
    /// packs BYTE-IDENTICAL instances to before):
    ///   • `displayOn == false` (via `drawsContents`) skips the whole viewport;
    ///   • a layer in `frozenLayers` (via `freezesLayer`) is excluded from THIS
    ///     viewport only;
    ///   • `twistRadians` is applied inside `modelToPaper`, so the map below rotates
    ///     the model view about its center.
    private func packViewportContents(_ viewports: [LayoutViewport], ctx: ResolveContext,
                                      origin: Vector, layers: LayerTable) {
        let halfWidthPx = renderPrefs.lineHalfWidthPx(backingScale: backingScale)
        // Resolve the model-space set ONCE per rebuild; every viewport reuses it.
        let modelEntities = model.drawing.entities.filter { $0.space == .model }
        for vp in viewports {
            // W2-2D: skip a display-OFF viewport entirely; `drawsContents` also folds
            // in the prior `scale > 0` degenerate-frame gate (default viewport ⇒ same).
            guard vp.drawsContents else { continue }
            for e in modelEntities {
                guard RendererVisibility.isRendered(e.layer, in: layers) else { continue }
                // W2-2D: a layer frozen IN THIS viewport is excluded here only (model
                // space + other viewports still show it). No-op for a default viewport.
                if vp.freezesLayer(e.layer.name) { continue }
                let geo = e.resolve(ctx)
                for poly in geo.polylines {
                    // Map each model point into paper space, then clip the resulting
                    // paper-space polyline to the frame; each surviving segment is a
                    // 2-point instance (clipping breaks a crossing polyline into pieces).
                    let paperPoints = poly.points.map { vp.modelToPaper($0) }
                    let segments = vp.clipPolylineToFrame(paperPoints, closed: poly.closed)
                    for (a, b) in segments {
                        let seg = ResolvedPolyline(points: [a, b], closed: false, pen: poly.pen)
                        RendererGeometry.appendInstances(for: seg, renderOrigin: origin,
                                                         halfWidthPx: halfWidthPx,
                                                         backingScale: backingScale,
                                                         into: &instanceScratch)
                    }
                }
            }
        }
    }

    /// Packs every active-space TABLE's materialized geometry (Wire-wave-1). A table is
    /// NOT an `EntityRecord` (it lives in `drawing.tables`, off `EntityKind`), so the
    /// per-entity pack never sees it; this draws the grid lines + the cell text (already
    /// shaped through the shared `TextShaper` by `CanvasModel.tableRenderGeometry`) via
    /// the SAME line/fill packing the entities use. The model returns an EMPTY set
    /// outside model space / inside a block-edit session (the MVP keeps tables in model
    /// space), so a paper layout packs no tables — consistent with the entity space gate.
    private func packTables(origin: Vector) {
        let geometries = model.tableRenderGeometry()
        guard !geometries.isEmpty else { return }
        let halfWidthPx = renderPrefs.lineHalfWidthPx(backingScale: backingScale)
        // Light-mode auto-invert: flip near-white "automatic color" to near-black so the
        // table stays legible on a light canvas (identity in dark mode) — matching
        // `packEntity`. The table's default pen is non-white, so this is the identity for
        // its grid; it matters only if a future table pen resolves near-white.
        let identity: (SIMD4<Float>) -> SIMD4<Float> = { $0 }
        let colorTransform: (SIMD4<Float>) -> SIMD4<Float> =
            OverlayStyle.invertNearWhiteEntities ? RendererGeometry.autoInvertWhite : identity
        for geo in geometries {
            for poly in geo.polylines {
                RendererGeometry.appendInstances(for: poly, renderOrigin: origin,
                                                 halfWidthPx: halfWidthPx,
                                                 backingScale: backingScale,
                                                 colorTransform: colorTransform,
                                                 into: &instanceScratch)
            }
            for fill in geo.fills {
                RendererGeometry.appendFillVertices(for: fill, renderOrigin: origin, into: &fillScratch)
            }
        }
    }

    /// Resolves one entity and packs its lines + fills into the scratch buffers,
    /// SKIPPING entities on a hidden/frozen layer (so the sidebar's eye-toggle
    /// actually hides them — a layer's `isVisible == false` ⇔ `isFrozen`). A
    /// model-version bump (which the sidebar performs on a visibility change)
    /// re-triggers this rebuild, so toggling re-packs the visible set.
    private func packEntity(_ e: EntityRecord, ctx: ResolveContext, origin: Vector,
                            layers: LayerTable,
                            activeSpace: EntitySpace, activeLayout: String?,
                            blockMembers: Set<EntityID>) {
        // Paper-space P2 space gate: only the active space's entities are packed. The
        // pure `PaperSpaceLayout.entities` predicate is the single source of truth for
        // "does this record belong on screen"; applied per-entity here so even a
        // stale/leaked id never paints geometry from the wrong space.
        guard PaperSpaceLayout.isInActiveSpace(e, space: activeSpace, layoutName: activeLayout)
        else { return }
        // Block-member guard: a block DEFINITION's members are owned geometry — they
        // draw ONLY via an `.insert` of the block (resolveInsert) or inside the Block
        // Editor, never directly. The scoped set / quadtree that feeds this pack already
        // excludes them (via `CanvasModel.activeSpaceEntities`), but this per-entity arm
        // keeps the pack and the index in lockstep so even a stale/leaked id never
        // DOUBLE-renders (drawn directly AND through the insert). `blockMembers` is
        // hoisted by the caller: it is `drawing.blockMemberIDs` in MODEL space outside a
        // block-edit session, and EMPTY otherwise (inside a Block Editor session the
        // active space IS the block's members, so they must draw; paper space carries no
        // block members), so this guard self-disables exactly when members should show.
        if blockMembers.contains(e.id) { return }
        // Layer-visibility filter: a frozen/hidden layer contributes neither lines
        // nor fills. An entity referencing an unknown layer (no record) still draws
        // (resolve() already falls back to the default pen for a missing layer). The
        // predicate lives in the GPU-free `RendererVisibility` (unit-tested without a
        // GPU in `RendererVisibilityTests`).
        guard RendererVisibility.isRendered(e.layer, in: layers) else { return }
        let geo = e.resolve(ctx)
        // In light mode (`OverlayStyle.invertNearWhiteEntities`), flip near-white
        // "automatic color" pens to near-black so the default drawing color stays
        // legible on the light canvas; in dark mode this is the identity transform.
        let identity: (SIMD4<Float>) -> SIMD4<Float> = { $0 }
        let colorTransform: (SIMD4<Float>) -> SIMD4<Float> =
            OverlayStyle.invertNearWhiteEntities ? RendererGeometry.autoInvertWhite : identity
        // The FALLBACK stroke half-width comes from the Rendering prefs (default
        // line width + antialias toggle), converted to device pixels for this
        // display; it applies to pens with no explicit lineweight. A pen with an
        // explicit `.millimeters` width overrides this per-polyline inside
        // `appendInstances` (mm → device px, fixed on zoom). A 0 mm stored width /
        // untouched prefs resolve to the renderer's hairline default.
        let halfWidthPx = renderPrefs.lineHalfWidthPx(backingScale: backingScale)
        for poly in geo.polylines {
            RendererGeometry.appendInstances(for: poly, renderOrigin: origin,
                                             halfWidthPx: halfWidthPx,
                                             backingScale: backingScale,
                                             colorTransform: colorTransform,
                                             into: &instanceScratch)
        }
        for fill in geo.fills {
            // A WIPEOUT mask (`isMask`) packs into the SEPARATE wipeout buffer (drawn
            // AFTER the model lines so it hides lower fills AND strokes); every normal
            // fill packs into the fill buffer (drawn UNDER the lines). The wipeout
            // triangles carry a placeholder color here; the draw pass re-stamps the
            // live `view.clearColor` before uploading.
            if fill.isMask {
                RendererGeometry.appendFillVertices(for: fill, renderOrigin: origin, into: &wipeoutScratch)
            } else {
                RendererGeometry.appendFillVertices(for: fill, renderOrigin: origin, into: &fillScratch)
            }
        }
        // Raster images: collect one ImageQuad per resolved image (drawn by the
        // textured-quad pass, which binds the cached texture per quad).
        for image in geo.images {
            if let quad = RendererGeometry.imageQuad(for: image, renderOrigin: origin) {
                imageScratch.append(quad)
            }
        }
    }

    /// Returns the resolve context, rebuilding it only when the model changed (the
    /// layer-table snapshot is stable between edits — no need to remake it per
    /// cull, which would allocate a fresh closure every pan that crosses a margin).
    private func resolveContext(modelChanged: Bool) -> ResolveContext {
        if modelChanged || cachedResolveContext == nil
            || resolveContextVersion != model.modelVersion {
            // Scale the engine's default tessellation tolerance by the render-quality
            // (LOD) tier: High keeps the fine default, Medium/Low coarsen it (fewer
            // curve segments → faster). Untouched prefs resolve to High (1×) so the
            // default look is unchanged.
            let tolerance = RenderPrefs.defaultTessellationTolerance
                * renderPrefs.tessellationToleranceScale
            // Thread the active ANNOTATION SCALE ($CANNOSCALE) into the resolve
            // context so an annotative text/mtext STYLE RENDERS at the chosen scale
            // (TextShaper/MTextShaper multiply the entity height by
            // `ctx.annotationScale`). Default `1.0` (1:1) leaves the produced
            // LineInstances byte-identical to the pre-annotation-scale renderer.
            //
            // PICK-SIDE LIMITATION (v1, documented — NOT fixed here): the
            // snap/selection/hit-test call sites (Snapping.swift, Selection.swift,
            // OverlayGeometry.swift, MarqueeHoverOverlay.swift, CADCanvasView.swift,
            // and CanvasModel.rebuildIndex) still call `makeResolveContext()` with
            // the 1.0 default, so they size annotative glyphs at their AUTHORED
            // height. At a non-unit annotation scale, PICKING/snapping an annotative
            // glyph can therefore diverge from its DRAWN size (the rendered text is
            // scaled, the hit-test box is not). A follow-up wave would thread
            // `model.annotationScale` through those (non-owned) call sites too; until
            // then this is a known, scoped limitation (text/mtext only; dims/leaders/
            // hatch are unaffected — they are not annotative this round).
            let ctx = model.drawing.makeResolveContext(
                tessellationTolerance: tolerance,
                annotationScale: model.annotationScale,
                fieldContext: model.makeFieldContext())
            cachedResolveContext = ctx
            resolveContextVersion = model.modelVersion
            return ctx
        }
        return cachedResolveContext!
    }

    /// Uploads `instances` into the persistent line buffer, growing it only when
    /// the count exceeds capacity (no realloc on the common steady-state path).
    private func uploadLineInstances(_ instances: [LineInstance]) {
        lineInstanceCount = instances.count
        guard !instances.isEmpty else { return }
        let needed = instances.count
        if lineInstanceBuffer == nil || needed > lineBufferCapacity {
            // Grow with headroom (1.5×) to amortize future growth.
            let cap = Swift.max(needed, Int(Double(needed) * 1.5))
            lineInstanceBuffer = device.makeBuffer(
                length: MemoryLayout<LineInstance>.stride * cap,
                options: .storageModeShared
            )
            lineBufferCapacity = cap
        }
        if let buf = lineInstanceBuffer {
            instances.withUnsafeBytes { raw in
                buf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
    }

    /// Incremental upload: only memcpy the dirty ranges (Wave P5).
    /// Falls back to a full copy when the count changed (offsets shifted)
    /// or the dirty payload is >50% of the buffer.
    private func uploadLineInstancesDirty(_ instances: [LineInstance],
                                          dirtyRanges: [Range<Int>],
                                          previousCount: Int) {
        let needed = instances.count
        // Count changed ⇒ offsets shifted for the tail, so full copy.
        if needed != previousCount {
            uploadLineInstances(instances)
            return
        }
        // Empty or trivial dirty ⇒ full copy (correctness).
        if dirtyRanges.isEmpty {
            uploadLineInstances(instances)
            return
        }
        let dirtyCount = dirtyRanges.reduce(0) { $0 + $1.count }
        if dirtyCount == 0 || dirtyCount * 2 > needed {
            uploadLineInstances(instances)
            return
        }
        // Ensure buffer exists and is large enough (no realloc path here —
        // if we need to grow we do a full upload).
        if lineInstanceBuffer == nil || needed > lineBufferCapacity {
            uploadLineInstances(instances)
            return
        }
        guard let buf = lineInstanceBuffer else {
            uploadLineInstances(instances)
            return
        }
        instances.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            let stride = MemoryLayout<LineInstance>.stride
            for range in dirtyRanges {
                guard range.lowerBound >= 0, range.upperBound <= needed else { continue }
                let byteOffset = range.lowerBound * stride
                let byteCount = range.count * stride
                let src = base.advanced(by: byteOffset)
                let dst = buf.contents().advanced(by: byteOffset)
                dst.copyMemory(from: src, byteCount: byteCount)
            }
        }
        lineInstanceCount = needed
    }

    /// Uploads `verts` (triangle vertices, 3 per triangle) into the persistent fill
    /// buffer, growing it only when the count exceeds capacity (no realloc on the
    /// steady-state path) — same growth policy as the line buffer.
    private func uploadFillVertices(_ verts: [FlatVertex]) {
        fillVertexCount = verts.count
        guard !verts.isEmpty else { return }
        let needed = verts.count
        if fillVertexBuffer == nil || needed > fillBufferCapacity {
            let cap = Swift.max(needed, Int(Double(needed) * 1.5))
            fillVertexBuffer = device.makeBuffer(
                length: MemoryLayout<FlatVertex>.stride * cap,
                options: .storageModeShared
            )
            fillBufferCapacity = cap
        }
        if let buf = fillVertexBuffer {
            verts.withUnsafeBytes { raw in
                buf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
    }

    /// Re-stamps the wipeout mask triangles with the live canvas background `color`
    /// and uploads them into the persistent wipeout buffer (same growth policy as the
    /// fill buffer). Called every frame from `draw(in:)` so a theme / background
    /// change recolors the masks without a cull rebuild. A drawing with no wipeout
    /// has an empty `wipeoutScratch`, so this is a cheap no-op there.
    private func uploadWipeoutVertices(backgroundColor color: SIMD4<Float>) {
        wipeoutVertexCount = wipeoutScratch.count
        guard !wipeoutScratch.isEmpty else { return }
        let needed = wipeoutScratch.count
        if wipeoutVertexBuffer == nil || needed > wipeoutBufferCapacity {
            let cap = Swift.max(needed, Int(Double(needed) * 1.5))
            wipeoutVertexBuffer = device.makeBuffer(
                length: MemoryLayout<FlatVertex>.stride * cap,
                options: .storageModeShared
            )
            wipeoutBufferCapacity = cap
        }
        guard let buf = wipeoutVertexBuffer else { return }
        // Re-color in place (positions are stable from the cull rebuild; only the
        // background color varies per frame) and copy into the GPU buffer.
        let dst = buf.contents().bindMemory(to: FlatVertex.self, capacity: needed)
        for i in 0..<needed {
            dst[i] = FlatVertex(position: wipeoutScratch[i].position, color: color)
        }
    }

    // MARK: - Image (textured-quad) draw pass

    /// Draws every visible raster image as a textured quad: binds its cached texture
    /// (loaded lazily by source path) and a per-draw `ImageParams` (brightness/
    /// contrast/fade), then draws the 6-vertex quad. An image whose texture is
    /// missing/unloadable, or which is marked placeholder (hidden), draws NOTHING in
    /// this pass — its frame outline still shows via the model-line pass, so the
    /// placement stays visible + selectable (the brief's "placeholder rectangle, no
    /// crash"). The quad vertices are uploaded into a small transient buffer; image
    /// count is tiny, so this is allocation-light and never touches the line buffer.
    private func drawImages(encoder: MTLRenderCommandEncoder, uniformBuffer: MTLBuffer) {
        guard let imagePipeline, !imageScratch.isEmpty else { return }
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)

        for quad in imageScratch {
            // A hidden image / empty key has no texture to draw — the frame outline
            // (model line) covers the placement; skip the textured draw.
            guard !quad.placeholder, !quad.textureKey.isEmpty,
                  let texture = texture(for: quad.textureKey),
                  quad.vertices.count == 6 else { continue }

            // Upload the 6 quad vertices into a transient buffer (storage-shared).
            let byteCount = MemoryLayout<TexturedVertex>.stride * quad.vertices.count
            guard let vbuf = device.makeBuffer(length: byteCount, options: .storageModeShared) else { continue }
            quad.vertices.withUnsafeBytes { raw in
                vbuf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }

            var params = ImageParams(
                brightness: Float(max(0, min(100, quad.brightness))) / 100,
                contrast: Float(max(0, min(100, quad.contrast))) / 100,
                opacity: Float(max(0, min(100, 100 - quad.fade))) / 100
            )
            encoder.setVertexBuffer(vbuf, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<ImageParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    /// Returns the cached `MTLTexture` for `path`, loading + caching it on first use
    /// (and caching a `nil` for an unloadable/missing file so we don't retry every
    /// frame). Loads via `NSImage` → `CGImage` → `MTKTextureLoader`. `@MainActor`
    /// (the renderer is main-actor); a one-time synchronous load per image is fine
    /// for a CAD drawing's handful of raster placements.
    private func texture(for path: String) -> MTLTexture? {
        if let cached = textureCache[path] { return cached }
        let loaded = Self.loadTexture(path: path, device: device)
        textureCache[path] = loaded   // cache even nil (don't re-attempt a bad file)
        return loaded
    }

    /// Loads an image file at `path` into an `MTLTexture`, or `nil` if the file is
    /// missing/unreadable. Tries the path as-is, then as a file URL; decodes via
    /// `NSImage` → `CGImage` so any AppKit-supported format (PNG/JPEG/TIFF/…) works.
    private static func loadTexture(path: String, device: MTLDevice) -> MTLTexture? {
        guard !path.isEmpty else { return nil }
        guard let nsImage = NSImage(contentsOfFile: path)
            ?? NSImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .generateMipmaps: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ]
        return try? loader.newTexture(cgImage: cgImage, options: options)
    }

    /// Rebuilds the overlay buffer (grid + selection + snap) each frame. The
    /// overlay is small (a few hundred vertices) so rebuilding it per frame is
    /// cheap; it must repaint on view change AND on snap/selection change without
    /// touching the model buffer (rendering-performance.md §5).
    private func rebuildOverlay(viewport: Viewport) {
        let origin = model.renderOrigin

        // Paper SHEET + margin border (paper-space P2): when a layout is active, draw
        // its page as a sheet rectangle plus the printable-area border. Empty in model
        // space (and when the active layout has no record), so model-space rendering is
        // unchanged. Built GPU-free from the engine `PageDescriptor` via the pure
        // `PaperSheetGeometry`.
        var sheetVerts: [FlatVertex] = []
        if let layout = model.activeLayoutRecord {
            sheetVerts = PaperSheetGeometry.sheetOutline(for: layout.page, renderOrigin: origin)
            // Paper-space P3: draw each viewport's FRAME outline on the sheet (the
            // contents are drawn by the model-buffer pass; this is the pickable
            // border). Reuses the sheet-rect vertex path.
            if !layout.viewports.isEmpty {
                sheetVerts += PaperSheetGeometry.viewportFrames(
                    layout.viewports, renderOrigin: origin)
            }
        }

        // Honor the Inspector's grid settings: the preferred spacing (when set)
        // overrides the adaptive step, and `gridVisible` toggles whether the grid is
        // DRAWN. The spacing is computed either way and fed to `lastGridSpacing` so
        // grid-snap keeps working even when the grid is hidden (snap is independent of
        // the visual guide).
        let (gridVerts, spacing) = OverlayGeometry.grid(
            viewport: viewport,
            renderOrigin: origin,
            preferredSpacing: model.preferredGridSpacing,
            ucs: model.currentUCS,
            isoPlane: model.isoPlaneIfActive
        )
        lastGridSpacing = spacing
        // Drop the grid vertices when the guide is hidden (snap still uses `spacing`).
        let drawnGridVerts = model.gridVisible ? gridVerts : []

        let selVerts = OverlayGeometry.selectionHighlight(
            selection: model.selection, drawing: model.drawing, renderOrigin: origin
        )

        var snapVerts: [FlatVertex] = []
        if let snap = model.snap, snap.kind != .free {
            snapVerts = OverlayGeometry.snapMarker(for: snap, viewport: viewport, renderOrigin: origin)
        }

        // The active tool's rubber-band preview (empty in select mode / before a
        // first point). Distinct preview color so it reads as "not yet placed".
        var previewVerts: [FlatVertex] = []
        if let tool = model.tool {
            previewVerts = OverlayGeometry.toolPreview(tool.preview, renderOrigin: origin)
        }

        // The active tool's dashed REFERENCE guides (Move's base→cursor displacement,
        // Scale's center→reference original-size line). Screen-fixed dashes via the
        // viewport, in the dimmer reference color. Empty outside the active drag.
        var referenceVerts: [FlatVertex] = []
        if let tool = model.tool {
            referenceVerts = OverlayGeometry.dashedSegments(
                tool.referenceSegments, viewport: viewport, renderOrigin: origin)
        }

        sheetVertexCount = sheetVerts.count
        gridVertexCount = drawnGridVerts.count
        selectionVertexCount = selVerts.count
        snapVertexCount = snapVerts.count
        previewVertexCount = previewVerts.count
        referenceVertexCount = referenceVerts.count

        // Storage order MUST match the draw order in `draw(in:)`: sheet, grid,
        // selection, snap, preview, reference.
        let all = sheetVerts + drawnGridVerts + selVerts + snapVerts + previewVerts + referenceVerts
        overlayVertexCount = all.count
        guard !all.isEmpty else { return }

        if overlayBuffer == nil || all.count > overlayCapacity {
            let cap = Swift.max(all.count, Int(Double(all.count) * 1.5), 256)
            overlayBuffer = device.makeBuffer(
                length: MemoryLayout<FlatVertex>.stride * cap,
                options: .storageModeShared
            )
            overlayCapacity = cap
        }
        if let buf = overlayBuffer {
            all.withUnsafeBytes { raw in
                buf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
    }

    /// Writes the `world→clip` matrix + drawable size into the given uniform
    /// buffer. This is the ONLY per-frame state that changes on pan/zoom.
    private func writeUniforms(into buffer: MTLBuffer, drawableSize: CGSize) {
        let transform = model.viewport.worldToClip(
            renderOrigin: model.renderOrigin, drawableSize: drawableSize
        )
        var u = CanvasUniforms(
            transform: transform,
            viewportPx: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
        )
        buffer.contents().copyMemory(from: &u, byteCount: MemoryLayout<CanvasUniforms>.stride)
    }
}

// MARK: - Paper sheet geometry (PURE, GPU-free, unit-tested)

/// GPU-free builder for the paper-space SHEET overlay (paper-space P2): turns an
/// engine `PageDescriptor` into the `FlatVertex` line-list the flat pipeline draws
/// under the model — the page rectangle plus the printable-area (margin) border.
///
/// Mirrors `OverlayGeometry`'s contract: outputs render-space f32 offsets from the
/// per-view `renderOrigin` (ADR-003) and has NO Metal/AppKit dependency, so the
/// rect→vertices mapping is unit-testable headlessly (`PaperSpaceUITests`). The
/// sheet geometry itself (its world rect / margin rect) comes from the pure
/// `PaperSpaceLayout` so "where the sheet is" has one source of truth across the
/// camera-fit, the index, and the render.
enum PaperSheetGeometry {

    /// The paper edge color — a near-white sheet outline (a printed page reads as a
    /// bright rectangle on the dark canvas). Static (not appearance-swapped) for P2;
    /// a light-mode variant can follow `OverlayStyle`'s pattern later.
    static let sheetColor = SIMD4<Float>(0.92, 0.92, 0.95, 0.85)
    /// The printable-area (margin) border color — a dimmer dashed-looking inset edge
    /// (drawn solid here; a distinct, lower-alpha tone so it reads as the inner
    /// "plot border" vs the paper edge).
    static let marginColor = SIMD4<Float>(0.55, 0.65, 0.85, 0.55)
    /// The viewport-frame color (paper-space P3) — a distinct cyan-ish border so a
    /// viewport window reads as separate from the page edge / margin.
    static let viewportFrameColor = SIMD4<Float>(0.40, 0.80, 0.90, 0.80)

    /// The sheet outline + margin border as a `.line` vertex list (pairs), offset to
    /// render space against `renderOrigin`. Returns the page rectangle (4 edges) and,
    /// when the page has a positive margin that leaves a non-degenerate printable
    /// area, the inset border (4 more edges). A degenerate page (zero size) yields no
    /// vertices.
    static func sheetOutline(for page: PageDescriptor, renderOrigin: Vector) -> [FlatVertex] {
        var v: [FlatVertex] = []
        let sheet = PaperSpaceLayout.sheetRect(for: page)
        guard !sheet.isEmpty, sheet.size.x > 0, sheet.size.y > 0 else { return v }
        appendRect(sheet, color: sheetColor, renderOrigin: renderOrigin, into: &v)

        // The printable-area border, only when it is a real inset (not the full sheet,
        // and not collapsed to a line by an oversized margin).
        let margin = PaperSpaceLayout.marginRect(for: page)
        if !margin.isEmpty, margin.size.x > 0, margin.size.y > 0,
           margin != sheet {
            appendRect(margin, color: marginColor, renderOrigin: renderOrigin, into: &v)
        }
        return v
    }

    /// The frame outlines of `viewports` (paper-space P3) as `.line` vertex pairs,
    /// each viewport's `paperRect` drawn as a 4-edge box in render space. A
    /// degenerate (empty/zero-size) viewport rect contributes nothing.
    static func viewportFrames(_ viewports: [LayoutViewport], renderOrigin: Vector) -> [FlatVertex] {
        var v: [FlatVertex] = []
        for vp in viewports {
            let rect = vp.paperRect
            guard !rect.isEmpty, rect.size.x > 0, rect.size.y > 0 else { continue }
            appendRect(rect, color: viewportFrameColor, renderOrigin: renderOrigin, into: &v)
        }
        return v
    }

    /// Appends a rectangle's 4 edges as `.line` vertex PAIRS (8 vertices), each edge
    /// offset to render space. Counter-clockwise from the lower-left corner.
    private static func appendRect(
        _ rect: AABB, color: SIMD4<Float>, renderOrigin: Vector, into v: inout [FlatVertex]
    ) {
        let ll = Vector(rect.min.x, rect.min.y)
        let lr = Vector(rect.max.x, rect.min.y)
        let ur = Vector(rect.max.x, rect.max.y)
        let ul = Vector(rect.min.x, rect.max.y)
        for (a, b) in [(ll, lr), (lr, ur), (ur, ul), (ul, ll)] {
            v.append(FlatVertex(position: off(a, renderOrigin), color: color))
            v.append(FlatVertex(position: off(b, renderOrigin), color: color))
        }
    }

    @inline(__always)
    private static func off(_ world: Vector, _ origin: Vector) -> SIMD2<Float> {
        SIMD2<Float>(Float(world.x - origin.x), Float(world.y - origin.y))
    }
}
