//
//  MetalCanvasView.swift
//  LibreCADmacOS
//
//  The Engine→resolve→Metal seam (ADR-003). An MTKView that takes hardcoded
//  `EntityRecord`s, runs them through `resolve()` into `ResolvedGeometry`, and
//  draws the resulting world-coordinate polylines through a world→clip
//  orthographic matrix. This proves the whole entity→resolve→render pipeline
//  end to end. Pan/zoom UI is not wired yet (just the matrix path exists).
//
//  Per ADR-003 the GPU buffer stores f32 OFFSETS from a per-view f64
//  `renderOrigin`; the subtraction path exists from day one (origin == 0 now)
//  so floating-origin at extreme zoom is not a retrofit.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import MetalKit
import simd
import CADEngine

// MARK: - Shared types between Swift and the inline Metal source.

/// A vertex in render space (f32 offset from `renderOrigin`) plus an RGBA color.
private struct CanvasVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// The transform uniform handed to the vertex shader (world/render → clip).
private struct CanvasUniforms {
    var transform: matrix_float4x4
}

/// Inline Metal source, compiled at runtime via `device.makeLibrary(source:)`.
/// Runtime compilation is the most robust offline path (no .metallib build
/// step / SwiftPM resource quirks).
private let metalSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct Uniforms {
    float4x4 transform;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(VertexIn in [[stage_in]],
                             constant Uniforms &u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.transform * float4(in.position, 0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
"""

// MARK: - World→clip matrix

/// Builds an orthographic world→clip `float4x4` for a world-space `rect`,
/// folding in the f64 `renderOrigin` (ADR-003). Maps `[origin.x+rect.minX,
/// origin.x+rect.maxX] × [...]` to clip `[-1, 1]²`. Vertices are uploaded as
/// `f32(world - renderOrigin)`, so the matrix works in render space and only
/// needs the rect translated by `renderOrigin`.
private func orthographicWorldToClip(rect: CGRect, renderOrigin: SIMD2<Double>) -> matrix_float4x4 {
    // Rect expressed relative to renderOrigin (render space).
    let l = Float(Double(rect.minX) - renderOrigin.x)
    let r = Float(Double(rect.maxX) - renderOrigin.x)
    let b = Float(Double(rect.minY) - renderOrigin.y)
    let t = Float(Double(rect.maxY) - renderOrigin.y)

    let sx = 2 / (r - l)
    let sy = 2 / (t - b)
    let tx = -(r + l) / (r - l)
    let ty = -(t + b) / (t - b)

    // Column-major (simd convention).
    return matrix_float4x4(columns: (
        SIMD4<Float>(sx,  0,  0, 0),
        SIMD4<Float>( 0, sy,  0, 0),
        SIMD4<Float>( 0,  0,  1, 0),
        SIMD4<Float>(tx, ty,  0, 1)
    ))
}

/// SwiftUI wrapper around an `MTKView`.
struct MetalCanvasView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            // Minor review #5: surface a visible, asserted error rather than a
            // silent no-op when no Metal device is available.
            assertionFailure("MetalCanvasView: MTLCreateSystemDefaultDevice() returned nil — no GPU.")
            NSLog("MetalCanvasView: FATAL — no Metal device; canvas will not render.")
            return view
        }
        view.device = device
        view.delegate = context.coordinator
        // On-demand rendering: only redraw when something changes (perf hygiene).
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoResizeDrawable = true
        // Dark background.
        view.clearColor = MTLClearColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
        view.colorPixelFormat = .bgra8Unorm

        context.coordinator.configure(device: device, pixelFormat: view.colorPixelFormat)
        view.setNeedsDisplay(view.bounds)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.setNeedsDisplay(nsView.bounds)
    }

    // MARK: - Coordinator (the MTKViewDelegate + renderer)

    final class Coordinator: NSObject, MTKViewDelegate {
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var uniformBuffer: MTLBuffer?

        /// One draw "run": a contiguous span of the shared vertex buffer drawn as
        /// a connected line strip (one per resolved polyline).
        private struct LineRun { var start: Int; var count: Int }
        private var runs: [LineRun] = []

        /// f64 floating-origin for this view (ADR-003). 0 for now; pan/zoom and
        /// extreme-zoom rebasing will move it later.
        private var renderOrigin = SIMD2<Double>(0, 0)

        /// The world-space bounds of the demo geometry (used to build an
        /// auto-fit orthographic matrix until pan/zoom exists).
        private var worldBounds = CGRect.zero

        /// Builds the pipeline, geometry, and uniform buffers (once).
        func configure(device: MTLDevice, pixelFormat: MTLPixelFormat) {
            commandQueue = device.makeCommandQueue()

            // Compile the inline shader source at runtime.
            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: metalSource, options: nil)
            } catch {
                NSLog("MetalCanvasView: shader compile failed: \(error)")
                return
            }

            guard let vfn = library.makeFunction(name: "vertex_main"),
                  let ffn = library.makeFunction(name: "fragment_main") else {
                NSLog("MetalCanvasView: missing shader functions")
                return
            }

            // Vertex descriptor: position (float2) + color (float4), interleaved.
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float2
            vd.attributes[0].offset = 0
            vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float4
            vd.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
            vd.attributes[1].bufferIndex = 0
            vd.layouts[0].stride = MemoryLayout<CanvasVertex>.stride

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vfn
            desc.fragmentFunction = ffn
            desc.vertexDescriptor = vd
            desc.colorAttachments[0].pixelFormat = pixelFormat

            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                NSLog("MetalCanvasView: pipeline creation failed: \(error)")
                return
            }

            buildDemoGeometry(device: device)
        }

        /// Builds a couple of hardcoded engine `EntityRecord`s (a line + a
        /// circle), runs them through `resolve()`, and uploads the resulting
        /// world-space polylines to a single shared vertex buffer. This proves
        /// the full Entity → resolve → Metal seam end to end.
        private func buildDemoGeometry(device: MTLDevice) {
            let entities = makeDemoEntities()
            let ctx = ResolveContext(tessellationTolerance: 0.25)
            let resolved = entities.map { $0.resolve(ctx) }

            // World bounds for the auto-fit matrix.
            var worldBox = AABB.empty
            for r in resolved {
                for p in r.polylines {
                    for v in p.points { worldBox.expand(toInclude: v) }
                }
            }
            if !worldBox.isEmpty {
                // 10% margin around the geometry.
                let mx = (worldBox.max.x - worldBox.min.x) * 0.1 + 1
                let my = (worldBox.max.y - worldBox.min.y) * 0.1 + 1
                worldBounds = CGRect(
                    x: worldBox.min.x - mx, y: worldBox.min.y - my,
                    width: (worldBox.max.x - worldBox.min.x) + 2 * mx,
                    height: (worldBox.max.y - worldBox.min.y) + 2 * my
                )
            }

            // Flatten resolved polylines into the interleaved vertex buffer.
            var verts: [CanvasVertex] = []
            runs.removeAll(keepingCapacity: true)
            for r in resolved {
                for poly in r.polylines {
                    guard poly.points.count >= 2 else { continue }
                    let start = verts.count
                    let color = SIMD4<Float>(poly.pen.color.r, poly.pen.color.g, poly.pen.color.b, poly.pen.color.a)
                    for wp in poly.points {
                        // ADR-003 floating-origin insertion point:
                        // upload f32 offsets from the f64 renderOrigin.
                        let rx = Float(wp.x - renderOrigin.x)
                        let ry = Float(wp.y - renderOrigin.y)
                        verts.append(CanvasVertex(position: SIMD2<Float>(rx, ry), color: color))
                    }
                    if poly.closed, let first = poly.points.first {
                        let rx = Float(first.x - renderOrigin.x)
                        let ry = Float(first.y - renderOrigin.y)
                        verts.append(CanvasVertex(position: SIMD2<Float>(rx, ry), color: color))
                    }
                    runs.append(LineRun(start: start, count: verts.count - start))
                }
            }

            guard !verts.isEmpty else { return }
            vertexBuffer = device.makeBuffer(
                bytes: verts,
                length: MemoryLayout<CanvasVertex>.stride * verts.count,
                options: .storageModeShared
            )

            // Allocate the uniform buffer once; its contents are refreshed per
            // resize (matrix-only, no per-frame allocation).
            var uniforms = CanvasUniforms(transform: matrix_identity_float4x4)
            uniformBuffer = device.makeBuffer(
                bytes: &uniforms,
                length: MemoryLayout<CanvasUniforms>.stride,
                options: .storageModeShared
            )
        }

        /// The seed demo: a line and a circle as real engine entities. These are
        /// resolve-only records that never enter a `CADDrawing`, so they carry
        /// the unassigned-id placeholder `EntityID(0)` rather than hardcoded
        /// distinct ids — id authority belongs to `CADDrawing.mintID()`/`add`
        /// (which would mint real ids if these were ever inserted). The render
        /// delegate is intentionally NOT main-actor isolated (it drives the GPU
        /// draw loop), so it does not construct the `@MainActor CADDrawing` here.
        private func makeDemoEntities() -> [EntityRecord] {
            let line = EntityRecord(
                id: EntityID(0),
                pen: Pen(lineColor: .explicit(.librecadGreen), lineType: .solid, lineWidth: .default),
                kind: .line(LineData(start: Vector(-40, -30), end: Vector(40, 30)))
            )
            let circle = EntityRecord(
                id: EntityID(0),
                pen: Pen(lineColor: .explicit(RGBAColor(0.95, 0.55, 0.20)), lineType: .solid, lineWidth: .default),
                kind: .circle(CircleData(center: Vector(0, 0), radius: 30))
            )
            return [line, circle]
        }

        /// Refreshes the world→clip matrix in the (already-allocated) uniform
        /// buffer for the current drawable aspect. No allocation per frame.
        private func updateTransform(drawableSize: CGSize) {
            guard let uniformBuffer, !worldBounds.isEmpty, drawableSize.width > 0, drawableSize.height > 0 else { return }

            // Letterbox the world bounds into the drawable aspect so the demo
            // geometry isn't stretched (an honest world→clip, not a hack).
            let viewAspect = drawableSize.width / drawableSize.height
            var rect = worldBounds
            let worldAspect = rect.width / rect.height
            if worldAspect < viewAspect {
                let newW = rect.height * viewAspect
                rect.origin.x -= (newW - rect.width) / 2
                rect.size.width = newW
            } else {
                let newH = rect.width / viewAspect
                rect.origin.y -= (newH - rect.height) / 2
                rect.size.height = newH
            }

            var uniforms = CanvasUniforms(
                transform: orthographicWorldToClip(rect: rect, renderOrigin: renderOrigin)
            )
            uniformBuffer.contents().copyMemory(
                from: &uniforms, byteCount: MemoryLayout<CanvasUniforms>.stride
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            updateTransform(drawableSize: size)
        }

        func draw(in view: MTKView) {
            // Ensure the transform is valid on the first frame too.
            updateTransform(drawableSize: view.drawableSize)

            guard let pipelineState,
                  let commandQueue,
                  let vertexBuffer,
                  let uniformBuffer,
                  let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else { return }

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            // Draw each resolved polyline as a connected line strip.
            for run in runs {
                encoder.drawPrimitives(type: .lineStrip, vertexStart: run.start, vertexCount: run.count)
            }
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
