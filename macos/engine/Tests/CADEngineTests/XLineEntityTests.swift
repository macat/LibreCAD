//
//  XLineEntityTests.swift
//  CADEngineTests
//
//  Tests for the construction-line entities — `.xline` (infinite) and `.ray`
//  (semi-infinite) (feature-catalog #F1):
//   - resolve() of an xline → a LARGE finite segment (no clip) centered on the
//     base; with `ResolveContext.clipBounds` set, a segment clipped to the box;
//   - resolve() of a ray → base → +large·direction (or clipped one-way);
//   - boundingBox() is FINITE (never infinity) — large by default, the clip box
//     when one is supplied;
//   - EntityTransform moves the base and rotates the direction;
//   - Snapping endpoints snap to the base; perpendicular foot lands on the
//     carrier line;
//   - InspectorEdits set base / direction / angle;
//   - a DXF XLINE / RAY round-trips (write → read with base + direction).
//
//  Uniquely namespaced so it does not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("xline/ray construction-line entity")
struct XLineEntityTests {

    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)

    // MARK: - Resolve (no clip → large finite segment)

    @Test("an xline resolves to ONE large finite segment through the base")
    func xlineResolvesLargeSegment() {
        let x = EntityRecord(id: EntityID(1),
            kind: .xline(XLineData(base: Vector(3, 4), direction: Vector(1, 0))))
        let geo = x.resolve()
        #expect(geo.polylines.count == 1)
        #expect(geo.fills.isEmpty)
        let pts = geo.polylines[0].points
        #expect(pts.count == 2)
        // Horizontal line through y == 4, spanning a large +/- extent in x.
        #expect(abs(pts[0].y - 4) < 1e-6)
        #expect(abs(pts[1].y - 4) < 1e-6)
        let half = ResolveContext.xlineFallbackHalfLength
        #expect(abs(pts[0].x - (3 - half)) < 1.0)
        #expect(abs(pts[1].x - (3 + half)) < 1.0)
        // FINITE on both ends (no infinity).
        #expect(pts[0].x.isFinite && pts[1].x.isFinite)
    }

    @Test("a ray resolves to a large segment from the base toward +direction only")
    func rayResolvesOneWaySegment() {
        let r = EntityRecord(id: EntityID(1),
            kind: .ray(RayData(base: Vector(0, 0), direction: Vector(0, 2))))  // up
        let geo = r.resolve()
        let pts = geo.polylines[0].points
        #expect(pts.count == 2)
        // Starts exactly at the base.
        #expect(abs(pts[0].x) < 1e-9 && abs(pts[0].y) < 1e-9)
        // Extends UP (positive y) only, large.
        #expect(pts[1].y > 1e5)
        #expect(abs(pts[1].x) < 1e-6)
    }

    @Test("a degenerate (zero direction) xline resolves to empty geometry")
    func degenerateXlineEmpty() {
        let x = EntityKind.xline(XLineData(base: Vector(1, 1), direction: Vector(0, 0)))
        #expect(x.resolve(pen: pen, ctx: .default).polylines.isEmpty)
    }

    // MARK: - Resolve with clipBounds (the additive viewport hook)

    @Test("an xline with clipBounds resolves to the segment clipped to the box")
    func xlineClippedToBounds() {
        // A horizontal line y == 5 through base (0,5); clip to [0,10]×[0,10].
        let x = EntityKind.xline(XLineData(base: Vector(0, 5), direction: Vector(1, 0)))
        var ctx = ResolveContext()
        ctx.clipBounds = AABB(min: Vector(0, 0), max: Vector(10, 10))
        let geo = x.resolve(pen: pen, ctx: ctx)
        let pts = geo.polylines[0].points
        // Clipped to x ∈ [0, 10] at y == 5.
        let xs = [pts[0].x, pts[1].x].sorted()
        #expect(abs(xs[0] - 0) < 1e-6)
        #expect(abs(xs[1] - 10) < 1e-6)
        #expect(abs(pts[0].y - 5) < 1e-6 && abs(pts[1].y - 5) < 1e-6)
    }

    @Test("a ray with clipBounds clips to the one-way portion inside the box")
    func rayClippedOneWay() {
        // Ray from (5,5) going +x; clip to [0,10]×[0,10] ⇒ x ∈ [5, 10].
        let r = EntityKind.ray(RayData(base: Vector(5, 5), direction: Vector(1, 0)))
        var ctx = ResolveContext()
        ctx.clipBounds = AABB(min: Vector(0, 0), max: Vector(10, 10))
        let geo = r.resolve(pen: pen, ctx: ctx)
        let pts = geo.polylines[0].points
        let xs = [pts[0].x, pts[1].x].sorted()
        #expect(abs(xs[0] - 5) < 1e-6)   // never goes left of the base
        #expect(abs(xs[1] - 10) < 1e-6)
    }

    @Test("an xline whose line misses the clip box resolves to empty")
    func xlineMissesClipBox() {
        // Vertical line x == 50; clip box is far away in x ⇒ no segment.
        let x = EntityKind.xline(XLineData(base: Vector(50, 0), direction: Vector(0, 1)))
        var ctx = ResolveContext()
        ctx.clipBounds = AABB(min: Vector(0, 0), max: Vector(10, 10))
        #expect(x.resolve(pen: pen, ctx: ctx).polylines.isEmpty)
    }

    // MARK: - Bounding box (always finite)

    @Test("xline/ray bounding boxes are FINITE (never infinity)")
    func boundingBoxFinite() {
        let x = EntityKind.xline(XLineData(base: Vector(0, 0), direction: Vector(1, 1)))
        let r = EntityKind.ray(RayData(base: Vector(2, 3), direction: Vector(-1, 0)))
        for box in [x.boundingBox(), r.boundingBox()] {
            #expect(box.min.x.isFinite && box.min.y.isFinite)
            #expect(box.max.x.isFinite && box.max.y.isFinite)
            #expect(!box.isEmpty)
        }
    }

    @Test("the ctx-aware bounding box equals the clip box when one is supplied")
    func boundingBoxUsesClip() {
        let x = EntityKind.xline(XLineData(base: Vector(0, 5), direction: Vector(1, 0)))
        var ctx = ResolveContext()
        ctx.clipBounds = AABB(min: Vector(0, 0), max: Vector(10, 10))
        let box = x.boundingBox(ctx: ctx)
        // The clipped segment spans x ∈ [0,10] at y == 5.
        #expect(abs(box.min.x - 0) < 1e-6 && abs(box.max.x - 10) < 1e-6)
        #expect(abs(box.min.y - 5) < 1e-6 && abs(box.max.y - 5) < 1e-6)
    }

    // MARK: - Transform (base moves, direction rotates)

    @Test("translating an xline moves the base, keeps the direction")
    func translateMovesBase() {
        let x = EntityKind.xline(XLineData(base: Vector(1, 2), direction: Vector(1, 0)))
        let t = Affine2D.translation(Vector(10, 20))
        guard case .xline(let d) = x.transformed(by: t) else { Issue.record("not xline"); return }
        #expect(abs(d.base.x - 11) < 1e-9 && abs(d.base.y - 22) < 1e-9)
        // Direction (a free vector) is unchanged by a pure translation.
        #expect(abs(d.direction.x - 1) < 1e-9 && abs(d.direction.y - 0) < 1e-9)
    }

    @Test("rotating a ray rotates the direction and moves the base")
    func rotateRotatesDirection() {
        // Ray from origin along +x, rotated 90° about the origin → along +y.
        let r = EntityKind.ray(RayData(base: Vector(1, 0), direction: Vector(1, 0)))
        let t = Affine2D.rotation(angle: .pi / 2, about: Vector(0, 0))
        guard case .ray(let d) = r.transformed(by: t) else { Issue.record("not ray"); return }
        // Base (1,0) → (0,1).
        #expect(abs(d.base.x - 0) < 1e-9 && abs(d.base.y - 1) < 1e-9)
        // Direction (1,0) → (0,1).
        #expect(abs(d.direction.x - 0) < 1e-9 && abs(d.direction.y - 1) < 1e-9)
    }

    @Test("scaling an xline scales the base offset and direction magnitude")
    func scaleScalesDirection() {
        let x = EntityKind.xline(XLineData(base: Vector(2, 0), direction: Vector(1, 0)))
        let t = Affine2D.scale(factor: 3, about: Vector(0, 0))
        guard case .xline(let d) = x.transformed(by: t) else { Issue.record("not xline"); return }
        #expect(abs(d.base.x - 6) < 1e-9)
        // The direction's MAGNITUDE scales (resolve normalizes, so the line is the
        // same), but the angle is preserved.
        #expect(abs(d.direction.angle - 0) < 1e-9)
    }

    // MARK: - Snapping

    @Test("an xline's snap endpoint is its base")
    func snapEndpointIsBase() {
        let x = EntityRecord(id: EntityID(1),
            kind: .xline(XLineData(base: Vector(7, 8), direction: Vector(1, 1))))
        let eps = Snapping.endpoints(of: x)
        #expect(eps.count == 1)
        #expect(abs(eps[0].x - 7) < 1e-9 && abs(eps[0].y - 8) < 1e-9)
    }

    @Test("a ray's snap endpoint is its base")
    func raySnapEndpointIsBase() {
        let r = EntityRecord(id: EntityID(1),
            kind: .ray(RayData(base: Vector(-1, -2), direction: Vector(0, 1))))
        let eps = Snapping.endpoints(of: r)
        #expect(eps.count == 1)
        #expect(abs(eps[0].x - (-1)) < 1e-9 && abs(eps[0].y - (-2)) < 1e-9)
    }

    @Test("the perpendicular foot from a point lands on the xline's carrier line")
    func perpFootOnCarrier() {
        // Horizontal line y == 0 through the origin; the foot from (5, 7) is (5, 0).
        let x = EntityRecord(id: EntityID(1),
            kind: .xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0))))
        let feet = Snapping.perpendicularFeet(from: Vector(5, 7), entity: x)
        #expect(feet.count == 1)
        #expect(abs(feet[0].x - 5) < 1e-6 && abs(feet[0].y - 0) < 1e-6)
    }

    @Test("a ray's perpendicular foot is dropped when behind the base")
    func rayPerpFootBehindBaseDropped() {
        // Ray from origin going +x; a point at (-3, 5) projects to (-3, 0), which
        // is BEHIND the base (negative x) → no perpendicular on the drawn ray.
        let r = EntityRecord(id: EntityID(1),
            kind: .ray(RayData(base: Vector(0, 0), direction: Vector(1, 0))))
        #expect(Snapping.perpendicularFeet(from: Vector(-3, 5), entity: r).isEmpty)
        // A point ahead of the base keeps its foot.
        #expect(Snapping.perpendicularFeet(from: Vector(4, 5), entity: r).count == 1)
    }

    @Test("the nearest point on an xline is the analytic carrier-line projection")
    func nearestOnXline() {
        let x = EntityRecord(id: EntityID(1),
            kind: .xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0))))
        let np = Snapping.nearestOnEntity(Vector(5, 9), entity: x, ctx: .default)
        #expect(abs(np.x - 5) < 1e-3 && abs(np.y - 0) < 1e-3)
    }

    // MARK: - InspectorEdits

    @Test("InspectorEdits set the xline's base / direction / angle")
    func inspectorEditsXline() {
        let x = EntityKind.xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0)))
        guard case .xline(let b) = InspectorEdits.setXLineBase(x, Vector(9, 9)) else {
            Issue.record("base edit failed"); return
        }
        #expect(abs(b.base.x - 9) < 1e-9 && abs(b.base.y - 9) < 1e-9)

        guard case .xline(let d) = InspectorEdits.setXLineDirection(x, Vector(0, 5)) else {
            Issue.record("dir edit failed"); return
        }
        #expect(abs(d.direction.x) < 1e-9 && abs(d.direction.y - 5) < 1e-9)

        guard case .xline(let a) = InspectorEdits.setXLineAngle(x, .pi / 2) else {
            Issue.record("angle edit failed"); return
        }
        #expect(abs(a.direction.angle - .pi / 2) < 1e-9)
    }

    @Test("InspectorEdits set the ray's base / direction / angle")
    func inspectorEditsRay() {
        let r = EntityKind.ray(RayData(base: Vector(0, 0), direction: Vector(1, 0)))
        guard case .ray(let b) = InspectorEdits.setRayBase(r, Vector(2, 3)) else {
            Issue.record("base edit failed"); return
        }
        #expect(abs(b.base.x - 2) < 1e-9 && abs(b.base.y - 3) < 1e-9)

        guard case .ray(let a) = InspectorEdits.setRayAngle(r, .pi) else {
            Issue.record("angle edit failed"); return
        }
        #expect(abs(a.direction.angle - .pi) < 1e-9)
    }

    @Test("a zero-direction inspector edit is ignored (keeps the line oriented)")
    func zeroDirectionEditIgnored() {
        let x = EntityKind.xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0)))
        let result = InspectorEdits.setXLineDirection(x, Vector(0, 0))
        guard case .xline(let d) = result else { Issue.record("not xline"); return }
        // Unchanged direction.
        #expect(abs(d.direction.x - 1) < 1e-9)
    }

    // MARK: - DXF round-trip

    @Test("a DXF XLINE round-trips with its base + direction")
    func dxfXlineRoundTrips() async throws {
        let x = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .xline(XLineData(base: Vector(12, 34), direction: Vector(1, 0))))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("xline-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities([x], layers: layers, toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        let xlines = back.records.compactMap { r -> XLineData? in
            if case .xline(let d) = r.kind { return d } else { return nil }
        }
        #expect(xlines.count == 1)
        let d = try #require(xlines.first)
        #expect(abs(d.base.x - 12) < 1e-6 && abs(d.base.y - 34) < 1e-6)
        // libdxfrw unitizes the direction on write; the angle must survive (0 == +x).
        #expect(abs(d.direction.angle - 0) < 1e-6)
        #expect(d.direction.magnitude > Tolerance.distance)
    }

    @Test("a DXF RAY round-trips with its base + direction (one-way sense kept)")
    func dxfRayRoundTrips() async throws {
        let r = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .ray(RayData(base: Vector(-5, 6), direction: Vector(0, 3))))  // +y
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ray-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities([r], layers: layers, toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        let rays = back.records.compactMap { rec -> RayData? in
            if case .ray(let d) = rec.kind { return d } else { return nil }
        }
        #expect(rays.count == 1)
        let d = try #require(rays.first)
        #expect(abs(d.base.x - (-5)) < 1e-6 && abs(d.base.y - 6) < 1e-6)
        // Unitized direction keeps its +y sense (angle π/2).
        #expect(abs(d.direction.angle - .pi / 2) < 1e-6)
    }
}
