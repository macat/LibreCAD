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

/// Tests the GPU-FREE dashed reference-line builder (`OverlayGeometry.dashedSegments`)
/// that chops a tool's `referenceSegments` world lines into SCREEN-FIXED on/off dash
/// runs (Move's base→cursor guide, Scale's center→reference original-size line). Pure
/// value math — asserts the dash count, screen-fixed ON length, color, the f32
/// floating-origin offset, and the empty/degenerate contracts.
@Suite("Dashed reference overlay")
struct OverlayDashTests {

    // At scale 1, worldPerPixel = 1, so 1 screen-point == 1 world unit. The reference
    // dash is 5pt ON + 3pt OFF = an 8-unit period in world space here.
    private func unitViewport() -> Viewport {
        Viewport(scale: 1, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
    }

    @Test("empty input yields no vertices")
    func emptyInput() {
        let verts = OverlayGeometry.dashedSegments(
            [], viewport: unitViewport(), renderOrigin: Vector(0, 0))
        #expect(verts.isEmpty)
    }

    @Test("a segment produces alternating ON-dash pairs (even count, >= one dash)")
    func alternatingDashes() {
        // A horizontal 20-unit segment. Period 8 → ON runs start at t = 0, 8, 16:
        // three ON dashes → 6 vertices (an even count).
        let segs = [(Vector(0, 0), Vector(20, 0))]
        let verts = OverlayGeometry.dashedSegments(
            segs, viewport: unitViewport(), renderOrigin: Vector(0, 0))
        #expect(!verts.isEmpty)
        #expect(verts.count % 2 == 0)
        #expect(verts.count == 6)

        // First ON dash: [0, 5] (5pt ON at scale 1).
        #expect(verts[0].position == SIMD2<Float>(0, 0))
        #expect(verts[1].position == SIMD2<Float>(5, 0))
        // Second ON dash starts one period (8) later: [8, 13].
        #expect(verts[2].position == SIMD2<Float>(8, 0))
        #expect(verts[3].position == SIMD2<Float>(13, 0))
        // Third ON dash starts at 16, clamped to the segment end at 20: [16, 20].
        #expect(verts[4].position == SIMD2<Float>(16, 0))
        #expect(verts[5].position == SIMD2<Float>(20, 0))
    }

    @Test("the ON-dash length is SCREEN-FIXED across zoom")
    func screenFixedAcrossZoom() {
        let segs = [(Vector(0, 0), Vector(100, 0))]
        // Zoomed in (scale 2 → worldPerPixel 0.5): a 5pt ON dash is 2.5 world units.
        let zoomedIn = Viewport(scale: 2, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let v2 = OverlayGeometry.dashedSegments(segs, viewport: zoomedIn, renderOrigin: Vector(0, 0))
        // First dash ON length = 5pt × 0.5 = 2.5 world units.
        let onLen2 = v2[1].position.x - v2[0].position.x
        #expect(abs(onLen2 - 2.5) < 1e-4)

        // Zoomed out (scale 0.5 → worldPerPixel 2): a 5pt ON dash is 10 world units.
        let zoomedOut = Viewport(scale: 0.5, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let v05 = OverlayGeometry.dashedSegments(segs, viewport: zoomedOut, renderOrigin: Vector(0, 0))
        let onLen05 = v05[1].position.x - v05[0].position.x
        #expect(abs(onLen05 - 10) < 1e-4)
    }

    @Test("all dash vertices carry the reference (guide) color")
    func referenceColor() {
        let segs = [(Vector(0, 0), Vector(20, 0))]
        let verts = OverlayGeometry.dashedSegments(
            segs, viewport: unitViewport(), renderOrigin: Vector(0, 0))
        #expect(verts.allSatisfy { $0.color == OverlayStyle.referenceColor })
        #expect(OverlayStyle.referenceColor != OverlayStyle.toolPreviewColor)
    }

    @Test("vertices are f32 offsets from the render origin (floating-origin)")
    func floatingOrigin() {
        let origin = Vector(1000, 2000)
        let segs = [(Vector(1000, 2000), Vector(1020, 2000))]
        let verts = OverlayGeometry.dashedSegments(
            segs, viewport: unitViewport(), renderOrigin: origin)
        // First ON dash [0,5] in offset space.
        #expect(verts[0].position == SIMD2<Float>(0, 0))
        #expect(verts[1].position == SIMD2<Float>(5, 0))
    }

    @Test("a degenerate (coincident) segment produces no dashes")
    func degenerateSegment() {
        let segs = [(Vector(3, 3), Vector(3, 3))]
        let verts = OverlayGeometry.dashedSegments(
            segs, viewport: unitViewport(), renderOrigin: Vector(0, 0))
        #expect(verts.isEmpty)
    }

    @Test("a short segment shorter than one ON dash still produces one clamped dash")
    func shortSegmentOneDash() {
        // 2-unit segment < 5-unit ON dash → one ON run clamped to the segment: [0,2].
        let segs = [(Vector(0, 0), Vector(2, 0))]
        let verts = OverlayGeometry.dashedSegments(
            segs, viewport: unitViewport(), renderOrigin: Vector(0, 0))
        #expect(verts.count == 2)
        #expect(verts[0].position == SIMD2<Float>(0, 0))
        #expect(verts[1].position == SIMD2<Float>(2, 0))
    }

    @Test("multiple segments each contribute their own dashes")
    func multipleSegments() {
        let segs = [
            (Vector(0, 0), Vector(20, 0)),   // 3 dashes → 6 verts
            (Vector(0, 10), Vector(2, 10)),  // 1 clamped dash → 2 verts
        ]
        let verts = OverlayGeometry.dashedSegments(
            segs, viewport: unitViewport(), renderOrigin: Vector(0, 0))
        #expect(verts.count == 8)
    }
}
