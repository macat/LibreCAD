//
//  RendererGeometryTests.swift
//  CADEngineTests
//
//  Unit tests for the renderer's GPU-FREE geometry generation (the testable part
//  of the instanced-line renderer per the Wave-2 brief): ResolvedPolyline →
//  per-segment `LineInstance` array, the closed-edge append, the ADR-003
//  floating-origin offset, the render-origin choice, and the overlay grid's
//  adaptive "nice step" + snap-marker generation.
//
//  ## Why this file compiles symlinked renderer sources
//  `RendererGeometry`/`OverlayGeometry` live in the `LibreCADmacOS` EXECUTABLE
//  target, which SwiftPM does not produce a linkable library for — so a test
//  target cannot `@testable import` it. Rather than test a divergent copy, the
//  two pure source files are SYMLINKED into this test target
//  (`_SharedRendererGeometry.swift`, `_SharedOverlayGeometry.swift`), so these
//  tests exercise the EXACT shipping source with zero drift. The proper long-term
//  fix is to extract a `CADRender` library target in Package.swift (which this
//  workstream may not edit) and `@testable import` it; tracked as a follow-up.
//  TODO(backlog): extract a `CADRender` library target (Package.swift) and replace
//  the symlinked sources with `@testable import CADRender` (out of scope here).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import CADEngine
import simd
import CoreGraphics

@Suite("Renderer geometry — instanced line generation")
struct RendererGeometryTests {

    private func pen(_ c: RGBAColor = .librecadGreen) -> ResolvedPen {
        ResolvedPen(color: c, lineType: .solid, lineWidth: .default)
    }

    // MARK: - Segment count

    @Test("open polyline of N points → N-1 segment instances")
    func openPolylineSegmentCount() {
        let poly = ResolvedPolyline(
            points: [Vector(0, 0), Vector(1, 0), Vector(1, 1), Vector(0, 1)],
            closed: false, pen: pen()
        )
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out.count == 3)   // 4 points → 3 segments, no closing edge
    }

    @Test("closed polyline of N points → N segment instances (closing edge appended)")
    func closedPolylineAppendsClosingEdge() {
        let pts = [Vector(0, 0), Vector(2, 0), Vector(2, 2), Vector(0, 2)]
        let poly = ResolvedPolyline(points: pts, closed: true, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out.count == 4)   // 4 points → 3 + 1 closing edge

        // The last instance must be the closing edge: last → first.
        let closing = out.last!
        #expect(closing.p0 == SIMD2<Float>(0, 2))   // last point
        #expect(closing.p1 == SIMD2<Float>(0, 0))   // first point
    }

    @Test("two-point line → exactly one instance with correct endpoints")
    func twoPointLine() {
        let poly = ResolvedPolyline(points: [Vector(-5, -3), Vector(5, 3)],
                                    closed: false, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out.count == 1)
        #expect(out[0].p0 == SIMD2<Float>(-5, -3))
        #expect(out[0].p1 == SIMD2<Float>(5, 3))
    }

    @Test("single-point polyline → one zero-length instance (drawn as a dot)")
    func singlePointDot() {
        let poly = ResolvedPolyline(points: [Vector(3, 4)], closed: false, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out.count == 1)
        #expect(out[0].p0 == out[0].p1)
        #expect(out[0].p0 == SIMD2<Float>(3, 4))
    }

    @Test("empty polyline → no instances")
    func emptyPolyline() {
        let poly = ResolvedPolyline(points: [], closed: true, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out.isEmpty)
    }

    @Test("closed 2-point polyline does NOT double the segment (no degenerate closing edge)")
    func closedTwoPointNoExtraEdge() {
        // A 2-point "closed" polyline has no meaningful closing edge (it would be
        // the same segment reversed); the builder requires >= 3 points to close.
        let poly = ResolvedPolyline(points: [Vector(0, 0), Vector(1, 1)],
                                    closed: true, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out.count == 1)
    }

    // MARK: - Floating-origin offset (ADR-003)

    @Test("renderOrigin is subtracted from every endpoint (f32 offsets)")
    func floatingOriginSubtraction() {
        let origin = Vector(1000, 2000)
        let poly = ResolvedPolyline(points: [Vector(1000, 2000), Vector(1003, 2004)],
                                    closed: false, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: origin, into: &out)
        #expect(out.count == 1)
        // World (1000,2000) - origin = (0,0); (1003,2004) - origin = (3,4).
        #expect(out[0].p0 == SIMD2<Float>(0, 0))
        #expect(out[0].p1 == SIMD2<Float>(3, 4))
    }

    @Test("offset() computes f32(world - origin)")
    func offsetHelper() {
        let o = RendererGeometry.offset(Vector(10.5, -7.25), from: Vector(0.5, -0.25))
        #expect(o == SIMD2<Float>(10.0, -7.0))
    }

    // MARK: - Color packing

    @Test("pen color is packed into every instance")
    func colorPacking() {
        let c = RGBAColor(0.2, 0.4, 0.6, 0.8)
        let poly = ResolvedPolyline(points: [Vector(0, 0), Vector(1, 0), Vector(2, 0)],
                                    closed: false, pen: pen(c))
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        for inst in out {
            #expect(inst.color == SIMD4<Float>(0.2, 0.4, 0.6, 0.8))
        }
    }

    @Test("halfWidthPx defaults to a positive hairline value")
    func halfWidthDefault() {
        #expect(RendererGeometry.defaultHalfWidthPx > 0)
        let poly = ResolvedPolyline(points: [Vector(0, 0), Vector(1, 0)],
                                    closed: false, pen: pen())
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        #expect(out[0].halfWidthPx == RendererGeometry.defaultHalfWidthPx)
    }

    // MARK: - Bulk instances from ResolvedGeometry

    @Test("instances(from:) flattens many geometries, preserving total segment count")
    func bulkInstances() {
        let g1 = ResolvedGeometry(polylines: [
            ResolvedPolyline(points: [Vector(0, 0), Vector(1, 0)], closed: false, pen: pen()),   // 1
            ResolvedPolyline(points: [Vector(0, 0), Vector(1, 0), Vector(1, 1)],
                             closed: true, pen: pen()),                                            // 3 (closed triangle)
        ])
        let g2 = ResolvedGeometry(polylines: [
            ResolvedPolyline(points: [Vector(5, 5), Vector(6, 6), Vector(7, 5)],
                             closed: false, pen: pen()),                                           // 2
        ])
        let out = RendererGeometry.instances(from: [g1, g2], renderOrigin: Vector(0, 0))
        #expect(out.count == 1 + 3 + 2)
    }

    // MARK: - renderOrigin choice

    @Test("renderOrigin is the bbox center, or (0,0) for an empty box")
    func renderOriginChoice() {
        let box = AABB(min: Vector(10, 20), max: Vector(30, 60))
        #expect(RendererGeometry.renderOrigin(for: box) == Vector(20, 40))
        #expect(RendererGeometry.renderOrigin(for: .empty) == Vector(0, 0))
    }

    // MARK: - Round-trip through resolve() (the real engine seam)

    @Test("a resolved circle tessellates to a closed polyline → N segments incl. closing edge")
    func circleResolvesToClosedInstances() {
        let circle = EntityRecord(
            id: EntityID(0),
            pen: Pen(lineColor: .explicit(.librecadGreen), lineType: .solid, lineWidth: .default),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 10))
        )
        let geo = circle.resolve(.default)
        #expect(geo.polylines.count == 1)
        let poly = geo.polylines[0]
        #expect(poly.closed)
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0), into: &out)
        // Closed polyline of N points → N instances (closing edge appended).
        #expect(out.count == poly.points.count)
        #expect(out.count >= 3)
    }
}

@Suite("Overlay geometry — grid + snap markers")
struct OverlayGeometryTests {

    // MARK: - Adaptive nice step

    @Test("niceStep rounds to 1/2/5 × 10ⁿ")
    func niceStepValues() {
        #expect(OverlayGeometry.niceStep(1.0) == 1.0)
        #expect(OverlayGeometry.niceStep(1.3) == 1.0)
        #expect(OverlayGeometry.niceStep(1.6) == 2.0)
        #expect(OverlayGeometry.niceStep(4.0) == 5.0)
        #expect(OverlayGeometry.niceStep(8.0) == 10.0)
        #expect(OverlayGeometry.niceStep(23.0) == 20.0)
        #expect(OverlayGeometry.niceStep(0.03) == 0.02)
        #expect(OverlayGeometry.niceStep(700.0) == 500.0)
    }

    @Test("niceStep guards non-positive / non-finite input")
    func niceStepGuards() {
        #expect(OverlayGeometry.niceStep(0) == 1)
        #expect(OverlayGeometry.niceStep(-5) == 1)
        #expect(OverlayGeometry.niceStep(.nan) == 1)
    }

    // MARK: - Grid generation

    @Test("grid covers the visible rect with vertex pairs and a sane spacing")
    func gridGeneration() {
        let vp = Viewport(scale: 10, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let (verts, spacing) = OverlayGeometry.grid(viewport: vp, renderOrigin: Vector(0, 0))
        #expect(spacing > 0)
        #expect(verts.count % 2 == 0)   // line list: pairs
        #expect(!verts.isEmpty)
    }

    @Test("grid uses the chosen spacing as the snap grid spacing")
    func gridSpacingMatchesTarget() {
        // At scale 10 pts/unit, a 64-pt target cell → ~6.4 world units → nice step 5.
        let vp = Viewport(scale: 10, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let (_, spacing) = OverlayGeometry.grid(viewport: vp, renderOrigin: Vector(0, 0))
        #expect(spacing == 5)
    }

    // MARK: - Snap markers

    @Test("snap marker emits a non-empty line list sized for the zoom")
    func snapMarkerEndpoint() {
        let vp = Viewport(scale: 10, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let snap = SnapResult(point: Vector(3, 4), kind: .endpoint)
        let verts = OverlayGeometry.snapMarker(for: snap, viewport: vp, renderOrigin: Vector(0, 0))
        #expect(verts.count == 8)   // square = 4 edges = 8 vertices
    }

    @Test("intersection marker is an X (two crossing segments = 4 vertices)")
    func snapMarkerIntersection() {
        let vp = Viewport(scale: 10, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let snap = SnapResult(point: Vector(0, 0), kind: .intersection)
        let verts = OverlayGeometry.snapMarker(for: snap, viewport: vp, renderOrigin: Vector(0, 0))
        #expect(verts.count == 4)
    }

    @Test("center marker is a polygon ring (16-gon = 32 vertices)")
    func snapMarkerCenter() {
        let vp = Viewport(scale: 10, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let snap = SnapResult(point: Vector(0, 0), kind: .center)
        let verts = OverlayGeometry.snapMarker(for: snap, viewport: vp, renderOrigin: Vector(0, 0))
        #expect(verts.count == 32)
    }

    @Test("snap marker offsets against renderOrigin (ADR-003)")
    func snapMarkerFloatingOrigin() {
        let vp = Viewport(scale: 10, center: Vector(1000, 1000), size: CGSize(width: 800, height: 600))
        let snap = SnapResult(point: Vector(1000, 1000), kind: .endpoint)
        let verts = OverlayGeometry.snapMarker(for: snap, viewport: vp, renderOrigin: Vector(1000, 1000))
        // Marker centered at the origin → vertices are small offsets around 0.
        for v in verts {
            #expect(abs(v.position.x) < 5)
            #expect(abs(v.position.y) < 5)
        }
    }
}
