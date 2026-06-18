//
//  MLineEntityTests.swift
//  CADEngineTests
//
//  Tests for the MULTILINE entity (`.mline`, DXF `MLINE` / `DRW_MLine`) — Wave 0,
//  the EntityKind critical section. An `.mline` is N parallel line elements drawn
//  along one shared vertex path (AutoCAD's MLINE: walls / multi-line borders), with
//  the elements carried INLINE on the entity (offset + optional color) in this MVP
//  (no separate MLSTYLE table, no fill, no caps, no MLEDIT). Coverage:
//   - resolve() → one `ResolvedPolyline` per element, each the path offset
//     PERPENDICULARLY by the element's effective (justification-shifted, scaled)
//     signed distance, at the correct parallel distances;
//   - interior corners are MITERED (the apex is the intersection of the two
//     adjacent offset lines);
//   - a near-180° reversal CLAMPS to a butt/bevel join (no runaway miter spike);
//   - the justification × scale-SIGN interaction is sign-locked (a negative scale
//     flips the element fan / offset signs) — pinned via `effectiveOffsets`;
//   - a closed path wraps (the last→first edge is mitered and the polyline closes);
//   - degenerate inputs (1 vertex / 0 elements) resolve to nothing (no crash);
//   - EntityTransform moves the path full-affine (and a mirror sign-flips `scale`);
//   - Snapping endpoints snap to each path vertex; middles to each segment mid;
//   - EntityGrips treats it as non-grip-editable (transform-only this MVP);
//   - Codable round-trips all fields, and partial JSON decodes to the defaults.
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

@Suite("multiline (MLINE) entity")
struct MLineEntityTests {

    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
    private let ctx = ResolveContext.default

    /// World-coord approximate equality (the suite-local convention).
    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    /// Whether `lines` contains a polyline whose ordered points match `pts` (within
    /// tolerance). Used to assert an element offset line was produced.
    private func contains(_ lines: [ResolvedPolyline], pts: [Vector], tol: Double = 1e-9) -> Bool {
        lines.contains { pl in
            pl.points.count == pts.count
                && zip(pl.points, pts).allSatisfy { approx($0, $1, tol) }
        }
    }

    // MARK: - effectiveOffsets / justification × scale-sign lock

    @Test("zero justification keeps offsets as authored at scale 1")
    func zeroJustificationIdentity() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 2), MLineElement(offset: 0), MLineElement(offset: -2)],
            justification: .zero, scale: 1)
        #expect(d.justificationShift == 0)
        #expect(d.effectiveOffsets == [2, 0, -2])
    }

    @Test("top justification slides the largest-offset element onto the path")
    func topJustificationShift() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 2), MLineElement(offset: 0), MLineElement(offset: -2)],
            justification: .top, scale: 1)
        // shift = -max = -2 ⇒ the +2 element lands at 0 (rides the path).
        #expect(d.justificationShift == -2)
        #expect(d.effectiveOffsets == [0, -2, -4])
    }

    @Test("bottom justification slides the smallest-offset element onto the path")
    func bottomJustificationShift() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 2), MLineElement(offset: 0), MLineElement(offset: -2)],
            justification: .bottom, scale: 1)
        // shift = -min = 2 ⇒ the -2 element lands at 0 (rides the path).
        #expect(d.justificationShift == 2)
        #expect(d.effectiveOffsets == [4, 2, 0])
    }

    @Test("a negative scale flips the element fan across the path (sign-lock)")
    func negativeScaleSignLock() {
        let base = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 2), MLineElement(offset: 0), MLineElement(offset: -2)],
            justification: .top, scale: 1)
        var flipped = base
        flipped.scale = -1
        // POSITIVE scale: [0, -2, -4]; NEGATIVE scale: every effective offset negates,
        // so the fan lands on the OTHER side of the path. This is the documented
        // justification × scale-sign interaction (locked here so a regression is loud).
        #expect(base.effectiveOffsets == [0, -2, -4])
        #expect(flipped.effectiveOffsets == [0, 2, 4])
        // Each flipped offset is the exact negation of the positive-scale offset.
        for (p, n) in zip(base.effectiveOffsets, flipped.effectiveOffsets) {
            #expect(p == -n)
        }
    }

    @Test("scale multiplies the (shifted) offsets")
    func scaleMultiplies() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1), MLineElement(offset: -1)],
            justification: .zero, scale: 3)
        #expect(d.effectiveOffsets == [3, -3])
    }

    // MARK: - resolve(): N parallel offset lines at the right distances

    @Test("resolve produces one parallel offset line per element at the right distance")
    func resolveParallelOffsets() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1), MLineElement(offset: -1)],
            justification: .zero, scale: 1)
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == 2)
        #expect(geo.fills.isEmpty)
        #expect(geo.images.isEmpty)
        // Left normal of (1,0) is (0,1): offset +1 ⇒ y = +1, offset -1 ⇒ y = -1.
        #expect(contains(geo.polylines, pts: [Vector(0, 1), Vector(10, 1)]))
        #expect(contains(geo.polylines, pts: [Vector(0, -1), Vector(10, -1)]))
        // None of the element lines is flagged closed (the path is open).
        #expect(geo.polylines.allSatisfy { !$0.closed })
    }

    @Test("a zero-offset element rides the path exactly")
    func resolveZeroOffsetRidesPath() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 0)],
            justification: .zero, scale: 1)
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == 1)
        #expect(contains(geo.polylines, pts: [Vector(0, 0), Vector(10, 0)]))
    }

    // MARK: - miter at an interior corner

    @Test("an interior right-angle corner mitres (apex = the two offset lines crossing)")
    func miterRightAngle() {
        // Path turns LEFT 90°: (0,0) → (10,0) → (10,10).
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            elements: [MLineElement(offset: 1), MLineElement(offset: -1)],
            justification: .zero, scale: 1)
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == 2)
        // Offset +1: first edge offset line y=1; second edge (dir (0,1), left normal
        // (-1,0)) offset line x=9 ⇒ inner apex (9, 1). Endpoints offset perpendicular.
        #expect(contains(geo.polylines, pts: [Vector(0, 1), Vector(9, 1), Vector(9, 10)]))
        // Offset -1: first line y=-1; second line x=11 ⇒ outer apex (11, -1).
        #expect(contains(geo.polylines, pts: [Vector(0, -1), Vector(11, -1), Vector(11, 10)]))
    }

    // MARK: - near-180° reversal clamps to a bevel/butt (no runaway spike)

    @Test("a near-180° reversal clamps the miter (no runaway spike)")
    func nearReversalClampsMiter() {
        // A path that nearly folds back on itself: (0,0) → (10,0) → (0, 0.001).
        // The interior corner at (10,0) is a ~180° reversal; a naive miter apex would
        // shoot off toward infinity. The clamp emits the two per-edge offset points
        // (a butt join) instead — so the offset line stays a bounded 4-point polyline.
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(0, 0.001)],
            elements: [MLineElement(offset: 1)],
            justification: .zero, scale: 1)
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == 1)
        let pts = geo.polylines[0].points
        // start + (two clamped corner points) + end == 4 points, no fewer/more.
        #expect(pts.count == 4)
        // No coordinate ran away: every point stays near the path's modest extent.
        for p in pts {
            #expect(p.magnitude < 100)
        }
    }

    @Test("a sharp-but-finite acute corner still mitres (does not over-clamp)")
    func acuteCornerStillMiters() {
        // A 90° corner is well within the miter range — it must NOT clamp (only a
        // genuine ~180° fold-back does). Verifies the clamp threshold is not too eager.
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            elements: [MLineElement(offset: 1)],
            justification: .zero, scale: 1)
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        // A mitered corner yields a single apex ⇒ 3 points (start, apex, end), NOT 4
        // (which a clamped butt join would produce).
        #expect(geo.polylines[0].points.count == 3)
    }

    // MARK: - closed-path wrap

    @Test("a closed path wraps (the polyline closes and the wrap corner mitres)")
    func closedPathWrap() {
        // A unit square path, closed. The centerline element rides the path; the
        // resolved polyline is flagged closed and wraps the last→first corner.
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)],
            elements: [MLineElement(offset: 0)],
            justification: .zero, scale: 1, closed: true)
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == 1)
        let pl = geo.polylines[0]
        #expect(pl.closed)
        // A closed offset-0 square has one corner point per vertex (4), all on the path.
        #expect(pl.points.count == 4)
        #expect(pl.points.contains { approx($0, Vector(0, 0)) })
        #expect(pl.points.contains { approx($0, Vector(10, 10)) })
    }

    @Test("closed vs open differ: closed mitres the wrap corner, open does not")
    func closedAddsWrapCorner() {
        let verts = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let openGeo = EntityKind.mline(MLineData(
            vertices: verts, elements: [MLineElement(offset: 1)], closed: false))
            .resolve(pen: pen, ctx: ctx)
        let closedGeo = EntityKind.mline(MLineData(
            vertices: verts, elements: [MLineElement(offset: 1)], closed: true))
            .resolve(pen: pen, ctx: ctx)
        #expect(!openGeo.polylines[0].closed)
        #expect(closedGeo.polylines[0].closed)
    }

    // MARK: - degenerate safety

    @Test("a single-vertex multiline resolves to nothing")
    func degenerateSingleVertex() {
        let d = MLineData(vertices: [Vector(1, 1)], elements: [MLineElement(offset: 1)])
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
        #expect(geo.images.isEmpty)
    }

    @Test("a multiline with no elements resolves to nothing")
    func degenerateNoElements() {
        let d = MLineData(vertices: [Vector(0, 0), Vector(10, 0)], elements: [])
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.isEmpty)
    }

    @Test("an empty multiline resolves to nothing and has a finite bounding box")
    func degenerateEmpty() {
        let d = MLineData(vertices: [], elements: [])
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.isEmpty)
        // boundingBox must be finite (collapses to the origin) — never NaN/crash.
        let box = EntityKind.mline(d).boundingBox()
        #expect(box.min.x.isFinite && box.max.x.isFinite)
    }

    @Test("coincident path vertices do not produce NaN geometry")
    func degenerateCoincidentVertices() {
        // A repeated vertex (zero-length edge) must be skipped, not divide-by-zero.
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1)])
        let geo = EntityKind.mline(d).resolve(pen: pen, ctx: ctx)
        for pl in geo.polylines {
            for p in pl.points { #expect(p.x.isFinite && p.y.isFinite) }
        }
    }

    // MARK: - boundingBox

    @Test("boundingBox encloses the offset element lines")
    func boundingBoxEnclosesOffsets() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 2), MLineElement(offset: -2)],
            justification: .zero, scale: 1)
        let box = EntityKind.mline(d).boundingBox()
        // The fan spans y ∈ [-2, 2] and x ∈ [0, 10].
        #expect(box.min.x <= 0 + 1e-9 && box.max.x >= 10 - 1e-9)
        #expect(box.min.y <= -2 + 1e-9 && box.max.y >= 2 - 1e-9)
    }

    // MARK: - EntityTransform

    @Test("translation moves every path vertex (full affine), keeping scale + elements")
    func transformTranslate() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1), MLineElement(offset: -1)],
            justification: .top, scale: 2)
        let t = Affine2D.translation(Vector(5, 3))
        guard case .mline(let m) = EntityKind.mline(d).transformed(by: t) else {
            Issue.record("transform did not preserve the .mline kind"); return
        }
        #expect(approx(m.vertices[0], Vector(5, 3)))
        #expect(approx(m.vertices[1], Vector(15, 3)))
        // A pure translation has unit scale and no mirror, so `scale` is unchanged.
        #expect(m.scale == 2)
        #expect(m.elements.count == 2)
        #expect(m.justification == .top)
    }

    @Test("a uniform scale folds the factor into the entity scale")
    func transformUniformScale() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1)],
            scale: 1)
        let t = Affine2D.scale(factor: 3, about: Vector(0, 0))
        guard case .mline(let m) = EntityKind.mline(d).transformed(by: t) else {
            Issue.record("transform did not preserve the .mline kind"); return
        }
        #expect(approx(m.vertices[1], Vector(30, 0)))
        // The uniform factor 3 folds into the entity scale (1 → 3) so the offset fan
        // scales with the path.
        #expect(abs(m.scale - 3) < 1e-9)
    }

    @Test("a mirror sign-flips the entity scale (the offset fan reflects to the correct side)")
    func transformMirrorSignFlipsScale() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1)],
            scale: 2)
        // Mirror about the X axis (y → -y): determinant < 0 ⇒ a reflection.
        let t = Affine2D(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        guard case .mline(let m) = EntityKind.mline(d).transformed(by: t) else {
            Issue.record("transform did not preserve the .mline kind"); return
        }
        // |det| == 1 ⇒ uniformScale 1; the mirror flips the scale sign: 2 → -2.
        #expect(abs(m.scale - -2) < 1e-9)
    }

    // MARK: - Snapping

    @Test("endpoint snaps are the path vertices")
    func snapEndpoints() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            elements: [MLineElement(offset: 1)])
        let rec = EntityRecord(id: EntityID(1), kind: .mline(d))
        let pts = Snapping.endpoints(of: rec)
        #expect(pts.count == 3)
        #expect(pts.contains { approx($0, Vector(0, 0)) })
        #expect(pts.contains { approx($0, Vector(10, 0)) })
        #expect(pts.contains { approx($0, Vector(10, 10)) })
    }

    @Test("middle snaps are the path segment midpoints (open: no closing edge)")
    func snapMiddlesOpen() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            elements: [MLineElement(offset: 1)], closed: false)
        let rec = EntityRecord(id: EntityID(1), kind: .mline(d))
        let mids = Snapping.middles(of: rec, ctx: ctx)
        // Two segments ⇒ two midpoints (NO closing last→first edge for an open path).
        #expect(mids.count == 2)
        #expect(mids.contains { approx($0, Vector(5, 0)) })
        #expect(mids.contains { approx($0, Vector(10, 5)) })
    }

    @Test("middle snaps include the closing edge midpoint when closed")
    func snapMiddlesClosed() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)],
            elements: [MLineElement(offset: 1)], closed: true)
        let rec = EntityRecord(id: EntityID(1), kind: .mline(d))
        let mids = Snapping.middles(of: rec, ctx: ctx)
        // Four edges (incl. the closing (0,10)→(0,0) edge) ⇒ four midpoints.
        #expect(mids.count == 4)
        #expect(mids.contains { approx($0, Vector(0, 5)) })   // the closing edge mid
    }

    // MARK: - EntityGrips

    @Test("a multiline is not grip-editable (transform-only this MVP)")
    func notGripEditable() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1)])
        let rec = EntityRecord(id: EntityID(1), kind: .mline(d))
        #expect(EntityGrips.grips(for: rec, ctx: ctx).isEmpty)
    }

    // MARK: - QuickSelect tag

    @Test("a multiline quick-selects under the polyline tag")
    func quickSelectTagIsPolyline() {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1)])
        #expect(QuickSelectKind.tag(of: .mline(d)) == .polyline)
    }

    // MARK: - Codable

    @Test("Codable round-trips a multiline incl. all fields")
    func codableRoundTrips() throws {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            elements: [MLineElement(offset: 1, colorIndex: 5), MLineElement(offset: -1)],
            justification: .bottom, scale: 1.5, closed: true)
        let kind = EntityKind.mline(d)
        let data = try JSONEncoder().encode(kind)
        let back = try JSONDecoder().decode(EntityKind.self, from: data)
        guard case .mline(let r) = back else {
            Issue.record("decoded kind was not .mline"); return
        }
        #expect(r.vertices.count == 3)
        #expect(approx(r.vertices[2], Vector(10, 10)))
        #expect(r.elements.count == 2)
        #expect(r.elements[0].offset == 1)
        #expect(r.elements[0].colorIndex == 5)
        #expect(r.elements[1].offset == -1)
        #expect(r.elements[1].colorIndex == nil)
        #expect(r.justification == .bottom)
        #expect(r.scale == 1.5)
        #expect(r.closed)
    }

    @Test("partial JSON without the additive fields decodes to the defaults")
    func codableAdditiveBackCompat() throws {
        // Simulate a value serialized with only `vertices` present (every other field
        // missing): the hand-written `init(from:)` must fill the documented defaults.
        let full = MLineData(
            vertices: [Vector(1, 2), Vector(3, 4)],
            elements: [MLineElement(offset: 7)],
            justification: .top, scale: 9, closed: true)
        let data = try JSONEncoder().encode(full)
        var obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["elements", "justification", "scale", "closed"] {
            obj.removeValue(forKey: key)
        }
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let d = try JSONDecoder().decode(MLineData.self, from: stripped)
        #expect(d.vertices.count == 2)               // the non-additive field survives
        #expect(d.elements.isEmpty)                  // default []
        #expect(d.justification == .zero)            // default .zero
        #expect(d.scale == 1)                        // default 1
        #expect(!d.closed)                           // default false
    }

    @Test("an MLineElement with a missing offset decodes to 0")
    func elementBackCompat() throws {
        let full = MLineElement(offset: 4, colorIndex: 2)
        let data = try JSONEncoder().encode(full)
        var obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: "offset")
        obj.removeValue(forKey: "colorIndex")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let e = try JSONDecoder().decode(MLineElement.self, from: stripped)
        #expect(e.offset == 0)
        #expect(e.colorIndex == nil)
    }

    // MARK: - InspectorEdits helpers (read-mostly field edits)

    @Test("InspectorEdits sets justification / scale / closed, no-op on other kinds")
    func inspectorEdits() {
        let base = EntityKind.mline(MLineData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            elements: [MLineElement(offset: 1)]))

        guard case .mline(let j) = InspectorEdits.setMLineJustification(base, .bottom) else {
            Issue.record("setMLineJustification dropped the kind"); return
        }
        #expect(j.justification == .bottom)

        guard case .mline(let s) = InspectorEdits.setMLineScale(base, -3) else {
            Issue.record("setMLineScale dropped the kind"); return
        }
        #expect(s.scale == -3)   // a negative scale is preserved (mirrors the fan)

        guard case .mline(let c) = InspectorEdits.setMLineClosed(base, true) else {
            Issue.record("setMLineClosed dropped the kind"); return
        }
        #expect(c.closed)

        // A scale of (effectively) 0 is floored so the multiline stays visible.
        guard case .mline(let z) = InspectorEdits.setMLineScale(base, 0) else {
            Issue.record("setMLineScale dropped the kind"); return
        }
        #expect(z.scale != 0)

        // No-op on a non-mline kind.
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        #expect(InspectorEdits.setMLineClosed(line, true) == line)
    }
}
