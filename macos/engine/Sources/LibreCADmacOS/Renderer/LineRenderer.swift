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
//    - Each frame, the visible set is gathered via `quadtree.query(region:)`
//      (§2.3 culling) and the visible entities' segments are packed into the
//      instance buffer — only when the model OR the visible set changed (a static
//      view with the same visible set re-uses the buffer; pan/zoom that don't
//      change the visible set are matrix-only).
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

    /// The overlay vertex buffer (grid + selection + snap marker, flat-shaded).
    private var overlayBuffer: MTLBuffer?
    private var overlayVertexCount = 0
    private var overlayCapacity = 0
    /// Grid line span [0, gridCount), selection span [gridCount, gridCount+selCount),
    /// snap span after that. All drawn as `.line` primitives in one buffer.
    private var gridVertexCount = 0
    private var selectionVertexCount = 0
    private var snapVertexCount = 0

    // MARK: Triple-buffered uniforms (§4.5)

    private static let maxInFlight = 3
    private var uniformBuffers: [MTLBuffer] = []
    private let inFlightSemaphore = DispatchSemaphore(value: maxInFlight)
    private var uniformIndex = 0

    // MARK: Dirty tracking

    /// The model version the instance buffer was built for. A mismatch forces a
    /// model rebuild.
    private var builtModelVersion = -1
    /// The visible rect the instance buffer was built for. A new visible rect
    /// (e.g. pan/zoom that reveals different entities) forces a culled rebuild.
    private var builtVisibleRect: AABB = .empty

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
            NSLog("LineRenderer: shader compile failed: \(error)")
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
            }
        } else {
            NSLog("LineRenderer: missing line shader functions")
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
            }
        } else {
            NSLog("LineRenderer: missing flat shader functions")
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
        // The point size update is driven by the view layer (CanvasModel.setViewSize)
        // via SwiftUI; here we just request a redraw with the new drawable.
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
    /// when the model changed or the visible rect changed (rendering-performance.md
    /// §2.3 + §4.1). Matrix-only pan/zoom that keeps the same visible set re-uses
    /// the existing buffer.
    private func rebuildLineInstancesIfNeeded(visibleRect: AABB) {
        let modelChanged = model.modelDirty || model.modelVersion != builtModelVersion
        let viewChanged = visibleRect != builtVisibleRect
        guard modelChanged || viewChanged || lineInstanceBuffer == nil else { return }

        // Cull to the visible set via the quadtree, then resolve + pack.
        var instances: [LineInstance] = []
        let ctx = model.drawing.makeResolveContext()
        let origin = model.renderOrigin
        let visibleIDs = model.quadtree.query(region: visibleRect)

        if visibleIDs.isEmpty && model.quadtree.isEmpty {
            // Index empty (e.g. entities with degenerate boxes / no model) — fall
            // back to resolving everything so a small/degenerate drawing still
            // shows. Cheap for tiny drawings; large ones populate the index.
            for e in model.drawing.entities {
                let geo = e.resolve(ctx)
                for poly in geo.polylines {
                    RendererGeometry.appendInstances(for: poly, renderOrigin: origin, into: &instances)
                }
            }
        } else {
            instances.reserveCapacity(visibleIDs.count * 2)
            for id in visibleIDs {
                guard let e = model.drawing.entity(id) else { continue }
                let geo = e.resolve(ctx)
                for poly in geo.polylines {
                    RendererGeometry.appendInstances(for: poly, renderOrigin: origin, into: &instances)
                }
            }
        }

        uploadLineInstances(instances)
        builtModelVersion = model.modelVersion
        builtVisibleRect = visibleRect
        model.modelDirty = false
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

    /// Rebuilds the overlay buffer (grid + selection + snap) each frame. The
    /// overlay is small (a few hundred vertices) so rebuilding it per frame is
    /// cheap; it must repaint on view change AND on snap/selection change without
    /// touching the model buffer (rendering-performance.md §5).
    private func rebuildOverlay(viewport: Viewport) {
        let origin = model.renderOrigin

        let (gridVerts, spacing) = OverlayGeometry.grid(viewport: viewport, renderOrigin: origin)
        lastGridSpacing = spacing

        let selVerts = OverlayGeometry.selectionHighlight(
            selection: model.selection, drawing: model.drawing, renderOrigin: origin
        )

        var snapVerts: [FlatVertex] = []
        if let snap = model.snap, snap.kind != .free {
            snapVerts = OverlayGeometry.snapMarker(for: snap, viewport: viewport, renderOrigin: origin)
        }

        gridVertexCount = gridVerts.count
        selectionVertexCount = selVerts.count
        snapVertexCount = snapVerts.count

        let all = gridVerts + selVerts + snapVerts
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
