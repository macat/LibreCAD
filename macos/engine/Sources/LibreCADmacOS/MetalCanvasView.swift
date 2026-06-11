//
//  MetalCanvasView.swift
//  LibreCADmacOS
//
//  A minimal Metal drawing surface: an MTKView wrapped for SwiftUI that draws a
//  single line through a runtime-compiled pipeline, with a float4x4 transform
//  uniform (identity for now) so future pan/zoom can be matrix-only.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import MetalKit
import simd

// MARK: - Shared types between Swift and the inline Metal source.

/// A vertex in world coordinates plus an RGBA color.
private struct CanvasVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

/// The transform uniform handed to the vertex shader.
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

/// SwiftUI wrapper around an `MTKView`.
struct MetalCanvasView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal device (shouldn't happen on supported Macs); return a
            // bare view so the app still launches.
            return view
        }
        view.device = device
        view.delegate = context.coordinator
        // On-demand rendering: only redraw when something changes.
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
        private var vertexCount = 0

        /// Builds the pipeline, geometry, and uniform buffers.
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

            // One diagonal line in world (clip) coords for the spine, in
            // LibreCAD's signature green.
            let green = SIMD4<Float>(0.31, 0.80, 0.31, 1.0)
            let verts = [
                CanvasVertex(position: SIMD2<Float>(-0.8, -0.8), color: green),
                CanvasVertex(position: SIMD2<Float>( 0.8,  0.8), color: green),
            ]
            vertexCount = verts.count
            vertexBuffer = device.makeBuffer(
                bytes: verts,
                length: MemoryLayout<CanvasVertex>.stride * verts.count,
                options: .storageModeShared
            )

            // Identity transform — pan/zoom becomes a matrix update later.
            var uniforms = CanvasUniforms(transform: matrix_identity_float4x4)
            uniformBuffer = device.makeBuffer(
                bytes: &uniforms,
                length: MemoryLayout<CanvasUniforms>.stride,
                options: .storageModeShared
            )
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // autoResizeDrawable keeps the drawable in pixel units; nothing to
            // recompute yet (identity transform). Hook for viewport math later.
        }

        func draw(in view: MTKView) {
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
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
