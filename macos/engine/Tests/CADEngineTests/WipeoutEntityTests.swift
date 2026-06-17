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
}
