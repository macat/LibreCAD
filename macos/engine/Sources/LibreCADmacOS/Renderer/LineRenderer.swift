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

@MainActor
final class LineRenderer: NSObject, MTKViewDelegate {

    // MARK: Dependencies

    /// Shared canvas state (model, viewport, index, selection, snap).
    private let model: CanvasModel

    /// Grid spacing chosen on the last frame (fed to snapping). Read by the
    /// interaction layer so grid-snap matches the drawn grid.
    private(set) var lastGridSpacing: Double = 1

    // MARK: Metal objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var linePipeline: MTLRenderPipelineState?
    private var flatPipeline: MTLRenderPipelineState?

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

    /// The overlay vertex buffer (grid + selection + snap marker, flat-shaded).
    private var overlayBuffer: MTLBuffer?
    private var overlayVertexCount = 0
    private var overlayCapacity = 0
    /// Grid line span [0, gridCount), selection span next, snap span next, tool-
    /// preview span last. All drawn as `.line` primitives in one buffer.
    private var gridVertexCount = 0
    private var selectionVertexCount = 0
    private var snapVertexCount = 0
    private var previewVertexCount = 0

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

    // MARK: Cull scratch (reused; no per-frame heap allocation, §2.3)

    /// Persistent scratch the cull rebuild packs into, cleared with
    /// `keepingCapacity` each rebuild so a steady drawing never re-allocates the
    /// backing storage (rendering-performance.md §2.3 — no per-frame heap churn).
    private var instanceScratch: [LineInstance] = []

    /// Persistent scratch for the fill triangle vertices, packed in the SAME cull
    /// rebuild as `instanceScratch` (cleared keepingCapacity → no per-frame churn).
    private var fillScratch: [FlatVertex] = []

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

        // Refresh model/overlay geometry if needed (NOT on matrix-only pan/zoom).
        let visibleRect = model.viewport.visibleWorldRect
        rebuildLineInstancesIfNeeded(visibleRect: visibleRect)
        rebuildOverlay(viewport: model.viewport)

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

        // ---- 1. Grid (under the model).
        if let flatPipeline, let overlayBuffer, gridVertexCount >= 2 {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridVertexCount)
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

        // ---- 2. Model lines (instanced quads).
        if let linePipeline, let lineInstanceBuffer, lineInstanceCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(lineInstanceBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: lineInstanceCount)
        }

        // ---- 3. Selection highlight + snap marker (over the model).
        if let flatPipeline, let overlayBuffer {
            encoder.setRenderPipelineState(flatPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            if selectionVertexCount >= 2 {
                encoder.drawPrimitives(type: .line, vertexStart: gridVertexCount,
                                       vertexCount: selectionVertexCount)
            }
            if snapVertexCount >= 2 {
                encoder.drawPrimitives(type: .line,
                                       vertexStart: gridVertexCount + selectionVertexCount,
                                       vertexCount: snapVertexCount)
            }
            if previewVertexCount >= 2 {
                encoder.drawPrimitives(
                    type: .line,
                    vertexStart: gridVertexCount + selectionVertexCount + snapVertexCount,
                    vertexCount: previewVertexCount)
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
        instanceScratch.removeAll(keepingCapacity: true)
        fillScratch.removeAll(keepingCapacity: true)
        let ctx = resolveContext(modelChanged: modelChanged)
        let origin = model.renderOrigin
        let layers = model.drawing.layers
        let visibleIDs = model.quadtree.query(region: cullRect)

        if visibleIDs.isEmpty && model.quadtree.isEmpty {
            // Index empty (e.g. entities with degenerate boxes / no model) — fall
            // back to resolving everything so a small/degenerate drawing still
            // shows. Cheap for tiny drawings; large ones populate the index.
            for e in model.drawing.entities {
                packEntity(e, ctx: ctx, origin: origin, layers: layers)
            }
        } else {
            instanceScratch.reserveCapacity(visibleIDs.count * 2)
            for id in visibleIDs {
                guard let e = model.drawing.entity(id) else { continue }
                packEntity(e, ctx: ctx, origin: origin, layers: layers)
            }
        }

        uploadLineInstances(instanceScratch)
        uploadFillVertices(fillScratch)
        builtModelVersion = model.modelVersion
        builtVisibleRect = cullRect   // cache the PADDED rect we culled
        model.modelDirty = false
    }

    /// Resolves one entity and packs its lines + fills into the scratch buffers,
    /// SKIPPING entities on a hidden/frozen layer (so the sidebar's eye-toggle
    /// actually hides them — a layer's `isVisible == false` ⇔ `isFrozen`). A
    /// model-version bump (which the sidebar performs on a visibility change)
    /// re-triggers this rebuild, so toggling re-packs the visible set.
    private func packEntity(_ e: EntityRecord, ctx: ResolveContext, origin: Vector, layers: LayerTable) {
        // Layer-visibility filter: a frozen/hidden layer contributes neither lines
        // nor fills. An entity referencing an unknown layer (no record) still draws
        // (resolve() already falls back to the default pen for a missing layer).
        if layers.layer(e.layer)?.isVisible == false { return }
        let geo = e.resolve(ctx)
        // In light mode (`OverlayStyle.invertNearWhiteEntities`), flip near-white
        // "automatic color" pens to near-black so the default drawing color stays
        // legible on the light canvas; in dark mode this is the identity transform.
        let identity: (SIMD4<Float>) -> SIMD4<Float> = { $0 }
        let colorTransform: (SIMD4<Float>) -> SIMD4<Float> =
            OverlayStyle.invertNearWhiteEntities ? RendererGeometry.autoInvertWhite : identity
        for poly in geo.polylines {
            RendererGeometry.appendInstances(for: poly, renderOrigin: origin,
                                             colorTransform: colorTransform,
                                             into: &instanceScratch)
        }
        for fill in geo.fills {
            RendererGeometry.appendFillVertices(for: fill, renderOrigin: origin, into: &fillScratch)
        }
    }

    /// Returns the resolve context, rebuilding it only when the model changed (the
    /// layer-table snapshot is stable between edits — no need to remake it per
    /// cull, which would allocate a fresh closure every pan that crosses a margin).
    private func resolveContext(modelChanged: Bool) -> ResolveContext {
        if modelChanged || cachedResolveContext == nil
            || resolveContextVersion != model.modelVersion {
            let ctx = model.drawing.makeResolveContext()
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

    /// Rebuilds the overlay buffer (grid + selection + snap) each frame. The
    /// overlay is small (a few hundred vertices) so rebuilding it per frame is
    /// cheap; it must repaint on view change AND on snap/selection change without
    /// touching the model buffer (rendering-performance.md §5).
    private func rebuildOverlay(viewport: Viewport) {
        let origin = model.renderOrigin

        // Honor the Inspector's grid settings: the preferred spacing (when set)
        // overrides the adaptive step, and `gridVisible` toggles whether the grid is
        // DRAWN. The spacing is computed either way and fed to `lastGridSpacing` so
        // grid-snap keeps working even when the grid is hidden (snap is independent of
        // the visual guide).
        let (gridVerts, spacing) = OverlayGeometry.grid(
            viewport: viewport,
            renderOrigin: origin,
            preferredSpacing: model.preferredGridSpacing
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

        gridVertexCount = drawnGridVerts.count
        selectionVertexCount = selVerts.count
        snapVertexCount = snapVerts.count
        previewVertexCount = previewVerts.count

        let all = drawnGridVerts + selVerts + snapVerts + previewVerts
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
