//
//  ToolPreviewOverlayTests.swift
//  CADEngineTests
//
//  Tests the GPU-FREE tool-preview overlay builder (`OverlayGeometry.toolPreview`)
//  that flattens a tool's `[ResolvedPolyline]` rubber-band into render-space
//  `FlatVertex` line segments. The builder lives in the non-importable
//  LibreCADmacOS executable target but is compiled into the test target via the
//  `_SharedOverlayGeometry.swift` symlink (same trick as RendererCullTests).
//
//  No GPU / MTKView — pure value math, asserting segment count, color, and the
//  f32 floating-origin offset.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import simd
@testable import CADEngine

@Suite("Tool preview overlay")
struct ToolPreviewOverlayTests {

    @Test("a 1-segment preview polyline flattens to one line (2 vertices)")
    func oneSegment() {
        let poly = ResolvedPolyline(points: [Vector(0, 0), Vector(10, 4)],
                                    closed: false, pen: .toolPreview)
        let verts = OverlayGeometry.toolPreview([poly], renderOrigin: Vector(0, 0))
        #expect(verts.count == 2)
        #expect(verts[0].position == SIMD2<Float>(0, 0))
        #expect(verts[1].position == SIMD2<Float>(10, 4))
        // All preview vertices carry the distinct preview color.
        #expect(verts[0].color == OverlayStyle.toolPreviewColor)
        #expect(verts[1].color == OverlayStyle.toolPreviewColor)
    }

    @Test("empty preview yields no vertices")
    func emptyPreview() {
        #expect(OverlayGeometry.toolPreview([], renderOrigin: Vector(0, 0)).isEmpty)
    }

    @Test("vertices are f32 offsets from the render origin (floating-origin)")
    func floatingOrigin() {
        let origin = Vector(1000, 2000)
        let poly = ResolvedPolyline(points: [Vector(1000, 2000), Vector(1005, 2003)],
                                    closed: false, pen: .toolPreview)
        let verts = OverlayGeometry.toolPreview([poly], renderOrigin: origin)
        #expect(verts[0].position == SIMD2<Float>(0, 0))
        #expect(verts[1].position == SIMD2<Float>(5, 3))
    }

    @Test("a closed preview adds the implicit closing edge")
    func closedAddsClosingEdge() {
        let poly = ResolvedPolyline(points: [Vector(0, 0), Vector(4, 0), Vector(4, 4)],
                                    closed: true, pen: .toolPreview)
        let verts = OverlayGeometry.toolPreview([poly], renderOrigin: Vector(0, 0))
        // 3 open segments (2 real + 1 closing) → 3 lines → 6 vertices.
        #expect(verts.count == 6)
    }
}
