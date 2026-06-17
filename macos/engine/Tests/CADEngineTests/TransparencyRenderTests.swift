//
//  TransparencyRenderTests.swift
//  CADEngineTests
//
//  Per-entity TRANSPARENCY (DXF 440) — Wave 4A, Stage 2 render-flow.
//
//  APPROACH: the resolved per-entity opacity is folded into the resolved color's
//  ALPHA channel (`ResolvedPen.color.a`) at resolve-time (Stage 1), so BOTH render
//  paths draw it with NO new per-instance field:
//    - Metal: `RendererGeometry.appendInstances` already packs `pen.color.a` into
//      `LineInstance.color.a`, the line pipeline already alpha-blends
//      (`configureAlphaBlend`), and `line_fragment` returns `color.a * aaAlpha`.
//      Fills go through `appendFillVertices` → `FlatVertex.color.a` on the
//      alpha-blended flat pipeline.
//    - CG export: `CGSceneRenderer.cgColor` maps `color.a` into the CGColor alpha,
//      used for both stroke (`pen.color`) and fill (`fill.color`).
//  This avoids touching the byte-matched `LineInstance` struct entirely (no stride
//  risk). These tests pin that the resolved alpha actually FLOWS to the packed
//  instance / vertex / CG color, and that the opaque default is unchanged.
//
//  Compiles the EXACT shipping renderer + export sources via the established
//  `_Shared*.swift` symlink convention (see RendererGeometryTests' header).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import CADEngine
import simd
import CoreGraphics

@Suite("Transparency render-flow (Stage 2) — resolved alpha → Metal + CG")
struct TransparencyRenderTests {

    // MARK: - Metal: resolved alpha → packed LineInstance color.a

    @Test("a transparent polyline packs its alpha into every LineInstance color.a")
    func metalLineAlpha() {
        // A resolved entity with explicit 50% opacity → pen.color.a == 0.5.
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1)), transparency: .opacity(0.5)),
            kind: .polyline(PolylineData(
                vertices: [PolylineVertex(point: Vector(0, 0)),
                           PolylineVertex(point: Vector(10, 0)),
                           PolylineVertex(point: Vector(10, 10))],
                closed: false)))
        let geo = rec.resolve()
        var instances: [LineInstance] = []
        for poly in geo.polylines {
            RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0),
                                             into: &instances)
        }
        #expect(instances.count == 2)   // 3-point open polyline → 2 segments
        for inst in instances {
            #expect(abs(inst.color.w - 0.5) < 1e-6)   // .w is the alpha lane
            #expect(inst.color.x == 1)                // red preserved
        }
    }

    @Test("opaque default packs alpha 1.0 (regression — Metal line)")
    func metalLineOpaqueRegression() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white)),   // transparency defaults to .byLayer → opaque
            kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 5))))
        let geo = rec.resolve()
        var instances: [LineInstance] = []
        RendererGeometry.appendInstances(for: geo.polylines[0], renderOrigin: Vector(0, 0),
                                         into: &instances)
        #expect(instances.count == 1)
        #expect(instances[0].color.w == 1.0)
    }

    // MARK: - Metal: resolved alpha → packed fill vertex color.a

    @Test("a transparent fill packs its alpha into every FlatVertex color.a")
    func metalFillAlpha() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1)), transparency: .opacity(0.25)),
            kind: .solid(SolidData(corners: [Vector(0, 0), Vector(10, 0), Vector(5, 10)])))
        let geo = rec.resolve()
        #expect(geo.fills.count == 1)
        var verts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: geo.fills[0], renderOrigin: Vector(0, 0),
                                            into: &verts)
        #expect(!verts.isEmpty)
        for v in verts {
            #expect(abs(v.color.w - 0.25) < 1e-6)
        }
    }

    // MARK: - CG export: resolved alpha → CGColor alpha (stroke + fill)

    @Test("CGSceneRenderer.cgColor carries the resolved alpha through (stroke)")
    func cgStrokeAlpha() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(RGBAColor(1, 1, 1, 1)), transparency: .opacity(0.4)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
        let geo = rec.resolve()
        let strokeColor = CGSceneRenderer.cgColor(geo.polylines[0].pen.color)
        let a = strokeColor.components?.last
        #expect(a != nil)
        #expect(abs((a ?? 0) - 0.4) < 1e-6)
    }

    @Test("CGSceneRenderer.cgColor carries the resolved alpha through (fill)")
    func cgFillAlpha() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(RGBAColor(0, 1, 0, 1)), transparency: .opacity(0.6)),
            kind: .solid(SolidData(corners: [Vector(0, 0), Vector(4, 0), Vector(0, 4)])))
        let geo = rec.resolve()
        #expect(geo.fills.count == 1)
        let fillColor = CGSceneRenderer.cgColor(geo.fills[0].color)
        let a = fillColor.components?.last
        #expect(a != nil)
        #expect(abs((a ?? 0) - 0.6) < 1e-6)
    }

    @Test("opaque default → CGColor alpha 1.0 (regression — CG)")
    func cgOpaqueRegression() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.librecadGreen)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let geo = rec.resolve()
        let strokeColor = CGSceneRenderer.cgColor(geo.polylines[0].pen.color)
        #expect(abs((strokeColor.components?.last ?? 0) - 1.0) < 1e-6)
    }
}
