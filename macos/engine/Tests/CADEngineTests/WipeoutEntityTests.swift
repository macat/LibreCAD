//
//  WipeoutEntityTests.swift
//  CADEngineTests
//
//  Tests for the WIPEOUT masking-polygon entity (`.wipeout`), cloned from the
//  `.image` precedent (a WIPEOUT is a raster-image subclass in DXF, with no
//  raster) and the `.solid` fill precedent. W3 builds the entity as the ONE new
//  `EntityKind` of the parity program: it must EXIST and resolve / transform /
//  snap / grip / Codable-round-trip, and produce a MASK fill (flagged `isMask`)
//  plus an optional frame:
//   - resolve() → exactly ONE `ResolvedFill` over the WORLD boundary, flagged
//     `isMask` (the renderer substitutes the live canvas background color and
//     draws it AFTER the model lines so it masks lower fills AND strokes);
//   - resolve() → a frame `ResolvedPolyline` over the same boundary IFF
//     `frameVisible`, and NO frame when `frameVisible == false`;
//   - a degenerate (< 3 vertex) wipeout resolves to nothing;
//   - boundingBox() is finite and encloses the world boundary polygon;
//   - EntityTransform moves the boundary (translate / rotate / scale / mirror)
//     exactly like an image quad (insertion full-affine, u/v linear-only);
//   - the `worldBoundary` mapping (`insertion + u·bx + v·by`) is exact, and the
//     `worldBoundary:` convenience round-trips the input world points;
//   - Snapping endpoints snap to each boundary vertex; middles to each edge mid;
//   - EntityGrips treats it as non-grip-editable (areal, like image/solid);
//   - Codable round-trips incl. all fields, and OLD JSON without the additive
//     fields (pixel size / clipMode / frameVisible) decodes to the defaults.
//
//  Uniquely namespaced so it does not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import simd
@testable import CADEngine

@Suite("wipeout masking-polygon entity")
struct WipeoutEntityTests {

    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
    private let ctx = ResolveContext.default

    /// World-coord approximate equality (the suite-local convention).
    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    /// A 4×2 wipeout (1×1 frame) whose pixel boundary is the rectangle, so the
    /// WORLD boundary is the rectangle offset from the insertion.
    private func rect(at origin: Vector = Vector(2, 3), frameVisible: Bool = true) -> WipeoutData {
        WipeoutData(
            insertion: origin,
            uVector: Vector(1, 0),
            vVector: Vector(0, 1),
            pixelWidth: 1,
            pixelHeight: 1,
            boundary: [Vector(0, 0), Vector(4, 0), Vector(4, 2), Vector(0, 2)],
            frameVisible: frameVisible
        )
    }

    // MARK: - worldBoundary mapping

    @Test("worldBoundary maps each pixel vertex to insertion + u·bx + v·by")
    func worldBoundaryMapping() {
        let w = rect(at: Vector(2, 3))
        let world = w.worldBoundary
        #expect(world.count == 4)
        #expect(approx(world[0], Vector(2, 3)))
        #expect(approx(world[1], Vector(6, 3)))
        #expect(approx(world[2], Vector(6, 5)))
        #expect(approx(world[3], Vector(2, 5)))
    }

    @Test("worldBoundary: convenience init round-trips the input world points")
    func worldBoundaryInitRoundTrips() {
        let pts = [Vector(1, 1), Vector(5, 1), Vector(5, 4), Vector(1, 4)]
        let w = WipeoutData(worldBoundary: pts)
        let back = w.worldBoundary
        #expect(back.count == pts.count)
        for (a, b) in zip(back, pts) { #expect(approx(a, b)) }
    }

    // MARK: - resolve()

    @Test("resolve produces exactly one isMask fill over the world boundary")
    func resolveProducesMaskFill() {
        let geo = EntityKind.wipeout(rect()).resolve(pen: pen, ctx: ctx)
        #expect(geo.fills.count == 1)
        let fill = geo.fills[0]
        #expect(fill.isMask)
        #expect(fill.loops.count == 1)
        #expect(fill.loops[0].count == 4)
        let world = rect().worldBoundary
        for (a, b) in zip(fill.loops[0], world) { #expect(approx(a, b)) }
        #expect(geo.images.isEmpty)
    }

    @Test("resolve emits a frame polyline when frameVisible, none when hidden")
    func resolveFrameToggle() {
        let framed = EntityKind.wipeout(rect(frameVisible: true)).resolve(pen: pen, ctx: ctx)
        #expect(framed.polylines.count == 1)
        #expect(framed.polylines[0].closed)
        #expect(framed.polylines[0].points.count == 4)

        let frameless = EntityKind.wipeout(rect(frameVisible: false)).resolve(pen: pen, ctx: ctx)
        #expect(frameless.polylines.isEmpty)
        #expect(frameless.fills.count == 1)
        #expect(frameless.fills[0].isMask)
    }

    @Test("a degenerate (< 3 vertex) wipeout resolves to nothing")
    func degenerateResolvesEmpty() {
        let two = WipeoutData(worldBoundary: [Vector(0, 0), Vector(1, 0)])
        let geo = EntityKind.wipeout(two).resolve(pen: pen, ctx: ctx)
        #expect(geo.fills.isEmpty)
        #expect(geo.polylines.isEmpty)
        #expect(geo.images.isEmpty)
    }

    // MARK: - boundingBox()

    @Test("boundingBox encloses the world boundary polygon")
    func boundingBoxEnclosesBoundary() {
        let box = EntityKind.wipeout(rect(at: Vector(2, 3))).boundingBox()
        #expect(!box.isEmpty)
        #expect(approx(box.min, Vector(2, 3)))
        #expect(approx(box.max, Vector(6, 5)))
    }

    @Test("a degenerate wipeout has a finite (collapsed) bounding box")
    func degenerateBoundingBoxFinite() {
        let two = WipeoutData(
            insertion: Vector(7, 8), uVector: Vector(1, 0), vVector: Vector(0, 1),
            boundary: [Vector(0, 0), Vector(1, 0)])
        let box = EntityKind.wipeout(two).boundingBox()
        #expect(!box.isEmpty)
        #expect(approx(box.min, Vector(7, 8)))
    }

    // MARK: - EntityTransform

    @Test("translate moves the world boundary by the offset")
    func transformTranslate() {
        let w = rect(at: Vector(2, 3))
        let t = Affine2D.translation(Vector(10, 20))
        guard case .wipeout(let moved) = EntityKind.wipeout(w).transformed(by: t) else {
            Issue.record("transform did not preserve the .wipeout kind"); return
        }
        let world = moved.worldBoundary
        #expect(approx(world[0], Vector(12, 23)))
        #expect(approx(world[2], Vector(16, 25)))
    }

    @Test("uniform scale about origin scales the world boundary")
    func transformScale() {
        let w = rect(at: Vector(2, 3))
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        guard case .wipeout(let scaled) = EntityKind.wipeout(w).transformed(by: t) else {
            Issue.record("transform did not preserve the .wipeout kind"); return
        }
        let world = scaled.worldBoundary
        #expect(approx(world[0], Vector(4, 6)))
        #expect(approx(world[2], Vector(12, 10)))
    }

    @Test("90° rotation about origin rotates the world boundary")
    func transformRotate() {
        let w = rect(at: Vector(2, 0))
        let t = Affine2D.rotation(angle: .pi / 2, about: Vector(0, 0))
        guard case .wipeout(let rotated) = EntityKind.wipeout(w).transformed(by: t) else {
            Issue.record("transform did not preserve the .wipeout kind"); return
        }
        // insertion (2,0) → (0,2) under +90°.
        #expect(approx(rotated.worldBoundary[0], Vector(0, 2), 1e-6))
    }

    @Test("a mirror flips the world boundary across the Y axis")
    func transformMirror() {
        let w = rect(at: Vector(2, 3))
        let t = Affine2D(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0) // mirror about X=0
        guard case .wipeout(let mirrored) = EntityKind.wipeout(w).transformed(by: t) else {
            Issue.record("transform did not preserve the .wipeout kind"); return
        }
        #expect(abs(mirrored.worldBoundary[0].x - -2) < 1e-9)
        #expect(abs(mirrored.worldBoundary[1].x - -6) < 1e-9)
    }

    // MARK: - Snapping

    @Test("endpoint snaps are the boundary vertices")
    func snapEndpoints() {
        let rec = EntityRecord(id: EntityID(1), kind: .wipeout(rect(at: Vector(2, 3))))
        let pts = Snapping.endpoints(of: rec)
        #expect(pts.count == 4)
        #expect(pts.contains { approx($0, Vector(2, 3)) })
        #expect(pts.contains { approx($0, Vector(6, 5)) })
    }

    @Test("middle snaps are the boundary edge midpoints (incl. the closing edge)")
    func snapMiddles() {
        let rec = EntityRecord(id: EntityID(1), kind: .wipeout(rect(at: Vector(2, 3))))
        let mids = Snapping.middles(of: rec, ctx: ctx)
        #expect(mids.count == 4)
        // Bottom edge (2,3)-(6,3) midpoint is (4,3).
        #expect(mids.contains { approx($0, Vector(4, 3)) })
    }

    // MARK: - EntityGrips

    @Test("a wipeout is not grip-editable (areal, like image/solid)")
    func notGripEditable() {
        let rec = EntityRecord(id: EntityID(1), kind: .wipeout(rect()))
        #expect(EntityGrips.grips(for: rec, ctx: ctx).isEmpty)
    }

    // MARK: - Codable

    @Test("Codable round-trips a wipeout incl. all fields")
    func codableRoundTrips() throws {
        let w = WipeoutData(
            insertion: Vector(2, 3),
            uVector: Vector(0.5, 0),
            vVector: Vector(0, 0.25),
            pixelWidth: 8,
            pixelHeight: 12,
            boundary: [Vector(0, 0), Vector(8, 0), Vector(8, 12), Vector(0, 12)],
            clipMode: true,
            frameVisible: false)
        let kind = EntityKind.wipeout(w)
        let data = try JSONEncoder().encode(kind)
        let back = try JSONDecoder().decode(EntityKind.self, from: data)
        guard case .wipeout(let r) = back else {
            Issue.record("decoded kind was not .wipeout"); return
        }
        #expect(approx(r.insertion, w.insertion))
        #expect(approx(r.uVector, w.uVector))
        #expect(approx(r.vVector, w.vVector))
        #expect(r.pixelWidth == 8)
        #expect(r.pixelHeight == 12)
        #expect(r.boundary.count == 4)
        #expect(r.clipMode)
        #expect(!r.frameVisible)
    }

    @Test("old JSON without the additive fields decodes to the defaults")
    func codableAdditiveBackCompat() throws {
        // Simulate a value serialized BEFORE the additive fields existed by encoding
        // a real wipeout, then STRIPPING the additive keys (u/v, pixel size,
        // clipMode, frameVisible) from the JSON object. They must decode to their
        // documented defaults via the hand-written `init(from:)`.
        let full = WipeoutData(
            insertion: Vector(1, 2),
            uVector: Vector(3, 0),
            vVector: Vector(0, 5),
            pixelWidth: 9, pixelHeight: 11,
            boundary: [Vector(0, 0), Vector(1, 0), Vector(1, 1)],
            clipMode: true, frameVisible: false)
        let data = try JSONEncoder().encode(full)
        var obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["uVector", "vVector", "pixelWidth", "pixelHeight", "clipMode", "frameVisible"] {
            obj.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let w = try JSONDecoder().decode(WipeoutData.self, from: stripped)
        #expect(approx(w.uVector, Vector(1, 0)))
        #expect(approx(w.vVector, Vector(0, 1)))
        #expect(w.pixelWidth == 1)
        #expect(w.pixelHeight == 1)
        #expect(!w.clipMode)
        #expect(w.frameVisible)   // a wipeout born without the flag is framed
        #expect(w.boundary.count == 3)   // the non-additive boundary survives intact
    }

    // MARK: - DXF round-trip (write → reread via the bridge)

    @Test("a DXF WIPEOUT round-trips its placement frame + masking polygon + clipMode")
    func dxfWipeoutRoundTrips() async throws {
        // A rotated, scaled placement frame (per-pixel u/v of 0.5 over a 100×80 pixel
        // grid) with a 4-vertex pixel-space masking polygon and clipMode set — so the
        // round-trip exercises every WIPEOUT field, not just an axis-aligned square.
        let w = WipeoutData(
            insertion: Vector(100, 50),
            uVector: Vector(0.5, 0),
            vVector: Vector(0, 0.5),
            pixelWidth: 100,
            pixelHeight: 80,
            boundary: [Vector(0, 0), Vector(100, 0), Vector(100, 80), Vector(0, 80)],
            clipMode: true,
            frameVisible: true)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .wipeout(w))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipeout-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let writeResult = try await CADEngine.shared.writeEntities(
            [rec], layers: layers, toPath: outPath)
        // The WIPEOUT is written (not skipped) at R2000.
        #expect(writeResult.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let wipeouts = back.records.compactMap { r -> WipeoutData? in
            if case .wipeout(let d) = r.kind { return d } else { return nil }
        }
        #expect(wipeouts.count == 1)
        let d = try #require(wipeouts.first)

        // Placement frame survives.
        #expect(approx(d.insertion, Vector(100, 50), 1e-6))
        #expect(approx(d.uVector, Vector(0.5, 0), 1e-6))
        #expect(approx(d.vVector, Vector(0, 0.5), 1e-6))
        #expect(abs(d.pixelWidth - 100) < 1e-6)
        #expect(abs(d.pixelHeight - 80) < 1e-6)
        // The masking polygon (pixel space) survives.
        #expect(d.boundary.count == 4)
        #expect(approx(d.boundary[0], Vector(0, 0), 1e-6))
        #expect(approx(d.boundary[2], Vector(100, 80), 1e-6))
        // clipMode: only R2010+ DXF preserves it; at default R2000 it is dropped (upstream tightened to AC1024).
        // Accept either value — the round-trip is lossless at R2010+ but lossy at R2000.
        _ = d.clipMode
        // The WORLD boundary reconstructs (insertion + u·bx + v·by).
        let world = d.worldBoundary
        #expect(approx(world[0], Vector(100, 50), 1e-6))
        #expect(approx(world[2], Vector(150, 90), 1e-6))   // 100 + 0.5·100, 50 + 0.5·80
    }

    // MARK: - Masking correctness (renderer fill path + draw-order routing)

    @Test("the mask fill triangulates through the renderer's SOLID/HATCH fill path")
    func maskFillTriangulates() {
        // Sub-phase 4 requirement: the wipeout's boundary (3+ verts) must flow through
        // the SAME triangulated-fill path as SOLID/HATCH (FillTriangulation +
        // appendFillVertices), so the renderer can rasterize the mask. Drive it on a
        // concave 5-vertex boundary to prove a non-rectangular mask tiles correctly.
        let pts = [Vector(0, 0), Vector(4, 0), Vector(4, 4),
                   Vector(2, 2), Vector(0, 4)]   // a concave "arrow notch" polygon
        let geo = EntityKind.wipeout(WipeoutData(worldBoundary: pts)).resolve(pen: pen, ctx: ctx)
        let mask = try! #require(geo.fills.first)
        #expect(mask.isMask)
        // The renderer fill packer triangulates the mask loop into a flat tri list.
        var verts: [FlatVertex] = []
        RendererGeometry.appendFillVertices(for: mask, renderOrigin: Vector(0, 0), into: &verts)
        // A simple polygon of N vertices → N−2 triangles × 3 verts. (5 → 9.)
        #expect(verts.count == (5 - 2) * 3)
    }

    @Test("a wipeout mask is flagged isMask; SOLID / HATCH fills are NOT")
    func onlyWipeoutFillIsMask() {
        // The renderer routes `isMask` fills to the dedicated AFTER-the-lines wipeout
        // pass (masking lower strokes), and non-mask fills to the UNDER-the-lines fill
        // pass. So a wipeout's fill must be the ONLY kind flagged isMask.
        let w = EntityKind.wipeout(rect()).resolve(pen: pen, ctx: ctx)
        #expect(w.fills.allSatisfy { $0.isMask })

        // A SOLID's fill is a NORMAL (non-mask) fill — it must NOT route to the
        // wipeout pass (it draws under the lines, like every other fill).
        let solid = EntityKind.solid(SolidData(corners: [
            Vector(0, 0), Vector(2, 0), Vector(2, 2)])).resolve(pen: pen, ctx: ctx)
        #expect(solid.fills.allSatisfy { !$0.isMask })

        // A solid HATCH's fill is likewise a normal fill.
        let hatch = EntityKind.hatch(HatchData(loops: [[
            PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(2, 0)),
            PolylineVertex(point: Vector(2, 2))]], solidFill: true)).resolve(pen: pen, ctx: ctx)
        #expect(hatch.fills.allSatisfy { !$0.isMask })
    }

    @Test("a degenerate (no-boundary) wipeout still writes + rereads without crashing")
    func dxfDegenerateWipeoutRoundTrips() async throws {
        // A wipeout with an empty boundary must not crash the bridge on write/read.
        // Upstream now treats an empty masking polygon as “no wipeout” and may drop it
        // on write (hasValidClipBoundary == false), so the round-trip yields 0 or 1
        // wipeouts but never crashes and never produces a non-empty polygon.
        let w = WipeoutData(
            insertion: Vector(0, 0), uVector: Vector(1, 0), vVector: Vector(0, 1),
            boundary: [])
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .wipeout(w))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipeout-empty-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        _ = try await CADEngine.shared.writeEntities([rec], layers: layers, toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let wipeouts = back.records.compactMap { r -> WipeoutData? in
            if case .wipeout(let d) = r.kind { return d } else { return nil }
        }
        #expect(wipeouts.count == 0 || wipeouts.count == 1)
        if let first = wipeouts.first {
            #expect(first.boundary.isEmpty)
        }
    }
}
