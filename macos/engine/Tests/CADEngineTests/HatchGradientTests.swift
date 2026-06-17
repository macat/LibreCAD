//
//  HatchGradientTests.swift
//  CADEngineTests
//
//  Tests for the GRADIENT hatch model (wave GH-W1, engine-only):
//   - `HatchGradient` construct / Equatable / Codable round-trip;
//   - `HatchData` with a gradient round-trips, and OLD JSON without `gradient`
//     still decodes (additive back-compat);
//   - `resolveHatch` carries the gradient onto `ResolvedFill.gradient` (and the
//     solid/pattern path is unchanged when there is no gradient);
//   - `transformHatch` preserves `patternScale` / `patternAngle` / `gradient`
//     across a transform (the pre-existing field-dropping bug fix), rotating the
//     pattern/gradient angle the way text/arc angles rotate.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Gradient hatch model (GH-W1)")
struct HatchGradientTests {

    // A unit-ish square boundary ring (CCW), 0..10 — the boundary used throughout.
    private var squareRing: [PolylineVertex] {
        [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ]
    }

    private let red = RGBAColor(1, 0, 0)
    private let blue = RGBAColor(0, 0, 1)

    // MARK: - HatchGradient value type

    @Test("HatchGradient stores kind / colors / angle and is Equatable")
    func gradientConstructAndEquatable() {
        let g = HatchGradient(kind: .linear, colors: [red, blue], angle: .pi / 3)
        #expect(g.kind == .linear)
        #expect(g.colors == [red, blue])
        #expect(abs(g.angle - .pi / 3) < 1e-12)

        // Equatable: identical descriptors are equal; a differing field is not.
        #expect(g == HatchGradient(kind: .linear, colors: [red, blue], angle: .pi / 3))
        #expect(g != HatchGradient(kind: .radial, colors: [red, blue], angle: .pi / 3))
        #expect(g != HatchGradient(kind: .linear, colors: [blue, red], angle: .pi / 3))
        #expect(g != HatchGradient(kind: .linear, colors: [red, blue], angle: 0))
    }

    @Test("HatchGradient default angle is 0 and a single-stop gradient is allowed")
    func gradientDefaultsAndSingleStop() {
        let g = HatchGradient(kind: .radial, colors: [red])
        #expect(g.angle == 0)
        #expect(g.colors.count == 1)
        #expect(g.kind == .radial)
    }

    @Test("HatchGradient Codable round-trips (kind/colors/angle survive)")
    func gradientCodableRoundTrip() throws {
        let g = HatchGradient(kind: .radial, colors: [red, blue], angle: 1.25)
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(HatchGradient.self, from: data)
        #expect(back == g)
    }

    // MARK: - HatchData carries the gradient

    @Test("HatchData defaults gradient to nil (existing callers unchanged)")
    func hatchDataGradientDefaultsNil() {
        let h = HatchData(loops: [squareRing])
        #expect(h.gradient == nil)
        #expect(h.solidFill == true)        // existing defaults intact
        #expect(h.patternScale == 1)
        #expect(h.patternAngle == 0)
    }

    @Test("HatchData with a gradient round-trips through Codable")
    func hatchDataWithGradientRoundTrips() throws {
        let g = HatchGradient(kind: .linear, colors: [red, blue], angle: 0.5)
        let h = HatchData(loops: [squareRing], solidFill: true, patternName: "SOLID",
                          patternScale: 2.5, patternAngle: 0.3, gradient: g)
        let data = try JSONEncoder().encode(h)
        let back = try JSONDecoder().decode(HatchData.self, from: data)
        #expect(back == h)
        #expect(back.gradient == g)
        #expect(back.patternScale == 2.5)
        #expect(abs(back.patternAngle - 0.3) < 1e-12)
    }

    @Test("OLD HatchData JSON without `gradient` still decodes (back-compat ⇒ nil)")
    func oldHatchJSONDecodesWithoutGradient() throws {
        // Build a faithful "old" JSON object by encoding a real (gradient-less)
        // HatchData and STRIPPING the `gradient` key — so the loop/vertex/Vector
        // shapes match the real encoder exactly, and the only difference from
        // current data is the absence of the additive `gradient` key.
        let h = HatchData(loops: [squareRing], solidFill: true, patternName: "SOLID",
                          patternScale: 1, patternAngle: 0)
        var obj = try jsonObject(encoding: h)
        obj.removeValue(forKey: "gradient")
        #expect(obj["gradient"] == nil)        // truly absent — the back-compat case

        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(HatchData.self, from: stripped)
        #expect(back.gradient == nil)
        #expect(back.solidFill == true)
        #expect(back.loops.count == 1)
        #expect(back.loops[0].count == 4)
    }

    @Test("Minimal HatchData JSON (only loops) still decodes (all defaults)")
    func minimalHatchJSONDecodes() throws {
        // The minimal shape: loops only. Everything else must take its default
        // (solid, scale 1, angle 0, gradient nil) via the decodeIfPresent arms.
        let h = HatchData(loops: [squareRing])
        var obj = try jsonObject(encoding: h)
        for key in ["solidFill", "patternName", "patternScale", "patternAngle", "gradient"] {
            obj.removeValue(forKey: key)
        }
        let minimal = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(HatchData.self, from: minimal)
        #expect(back.gradient == nil)
        #expect(back.solidFill == true)
        #expect(back.patternScale == 1)
        #expect(back.patternAngle == 0)
        #expect(back.loops.count == 1)
    }

    /// Encodes a value and returns it as a mutable top-level JSON dictionary, so a
    /// test can simulate "older" data by removing additive keys.
    private func jsonObject<T: Encodable>(encoding value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - resolveHatch carries the gradient

    @Test("resolveHatch carries the gradient onto ResolvedFill.gradient")
    func resolveCarriesGradient() {
        let g = HatchGradient(kind: .radial, colors: [red, blue], angle: 0.75)
        let e = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.black)),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true,
                                   patternName: "SOLID", gradient: g)))
        let geo = e.resolve(ResolveContext())

        #expect(geo.polylines.isEmpty)           // gradient resolves through the fill
        #expect(geo.fills.count == 1)
        let fill = geo.fills[0]
        let rg = try! #require(fill.gradient)
        #expect(rg.kind == .radial)
        #expect(rg.colors == [red, blue])
        #expect(abs(rg.angle - 0.75) < 1e-12)
        // The flat fallback color is the gradient's first stop (a gradient-unaware
        // draw path still paints a plausible solid).
        #expect(fill.color == red)
    }

    @Test("a gradient hatch resolves through the fill even with a pattern name set")
    func gradientSupersedesPattern() {
        // A real `.pat` name AND a gradient: the gradient supersedes the pattern, so
        // it resolves to a fill (not pattern lines).
        let g = HatchGradient(kind: .linear, colors: [red, blue], angle: 0)
        let e = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false,
                                   patternName: "ANSI31", gradient: g)))
        let geo = e.resolve(ResolveContext())
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].gradient != nil)
    }

    @Test("a non-gradient SOLID hatch resolves with gradient == nil (no regression)")
    func solidPathUnchanged() {
        let e = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true, patternName: "SOLID")))
        let geo = e.resolve(ResolveContext())
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].gradient == nil)
        #expect(geo.fills[0].loops[0] == squareRing.map(\.point))
    }

    @Test("ResolvedFill defaults gradient to nil (additive — solid producers unchanged)")
    func resolvedFillGradientDefaultsNil() {
        let f = ResolvedFill(outline: [Vector(0, 0), Vector(1, 0), Vector(0, 1)], color: .black)
        #expect(f.gradient == nil)
        #expect(f.color == .black)
    }

    // MARK: - transformHatch preserves ALL fields (the bug-fix regression)

    @Test("transformHatch preserves patternScale / patternAngle / gradient under a move")
    func transformPreservesFieldsUnderMove() {
        let g = HatchGradient(kind: .linear, colors: [red, blue], angle: 0.4)
        let h = HatchData(loops: [squareRing], solidFill: false, patternName: "ANSI31",
                          patternScale: 3.0, patternAngle: 0.4, gradient: g)
        // A pure translation: NO rotation ⇒ scale + both angles + gradient intact.
        let moved = EntityTransform.transformHatch(h, .translation(Vector(5, -7)))

        #expect(moved.patternScale == 3.0)                       // was DROPPED before the fix
        #expect(abs(moved.patternAngle - 0.4) < 1e-12)           // was DROPPED before the fix
        #expect(moved.solidFill == false)
        #expect(moved.patternName == "ANSI31")
        let mg = try! #require(moved.gradient)
        #expect(mg.kind == .linear)
        #expect(mg.colors == [red, blue])                         // colors transform-invariant
        #expect(abs(mg.angle - 0.4) < 1e-12)                      // unchanged under pure move
        // The boundary actually moved.
        #expect(moved.loops[0][0].point == Vector(5, -7))
    }

    @Test("transformHatch rotates patternAngle and gradient.angle by the rotation delta")
    func transformRotatesAngles() {
        let g = HatchGradient(kind: .linear, colors: [red, blue], angle: 0.1)
        let h = HatchData(loops: [squareRing], solidFill: false, patternName: "ANSI31",
                          patternScale: 2.0, patternAngle: 0.1, gradient: g)
        let rot = Affine2D.rotation(angle: .pi / 2, about: Vector(0, 0))
        let r = EntityTransform.transformHatch(h, rot)

        // Scale is dimensionless ⇒ unchanged; both angles rotate by +π/2.
        #expect(r.patternScale == 2.0)
        #expect(abs(Vector.correctAngle(r.patternAngle - (0.1 + .pi / 2))) < 1e-9)
        let rg = try! #require(r.gradient)
        #expect(rg.colors == [red, blue])
        #expect(abs(Vector.correctAngle(rg.angle - (0.1 + .pi / 2))) < 1e-9)
    }

    @Test("transformHatch under a mirror reflects the angles and preserves scale/gradient")
    func transformMirrorReflectsAngles() {
        let g = HatchGradient(kind: .radial, colors: [red, blue], angle: 0.3)
        let h = HatchData(loops: [squareRing], solidFill: false, patternName: "ANSI31",
                          patternScale: 1.5, patternAngle: 0.3, gradient: g)
        // Mirror across the X axis (angle 0 through origin): angle → -angle.
        let mir = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0)
        let m = EntityTransform.transformHatch(h, mir)

        #expect(m.patternScale == 1.5)                            // dimensionless ⇒ kept
        #expect(abs(Vector.correctAngle(m.patternAngle - (-0.3))) < 1e-9)
        let mg = try! #require(m.gradient)
        #expect(mg.kind == .radial)
        #expect(mg.colors == [red, blue])                         // colors invariant under mirror
        #expect(abs(Vector.correctAngle(mg.angle - (-0.3))) < 1e-9)
    }

    @Test("transformHatch on a plain solid hatch (no gradient) survives the round-trip")
    func transformPlainSolidHatch() {
        let h = HatchData(loops: [squareRing])   // solid, no pattern, no gradient
        let moved = EntityTransform.transformHatch(h, .translation(Vector(2, 2)))
        #expect(moved.gradient == nil)
        #expect(moved.solidFill == true)
        #expect(moved.patternScale == 1)
        #expect(moved.loops[0][0].point == Vector(2, 2))
    }

    // MARK: - HatchTool gradient create-hook (UNWIRED)

    @Test("HatchTool(gradient:) commits a solid hatch carrying the gradient")
    func hatchToolGradientHook() {
        let g = HatchGradient(kind: .linear, colors: [red, blue], angle: 0.2)
        var tool = HatchTool(gradient: g)
        #expect(tool.fill == .gradient(g))

        // A closed square selection (a closed polyline boundary) to fill.
        let boundary = EntityRecord(
            id: EntityID(7),
            kind: .polyline(PolylineData(
                vertices: squareRing, closed: true)))
        let ctx = ToolContext(
            selected: [boundary],
            entity: { id in id == boundary.id ? boundary : nil },
            gridSpacing: nil)

        // Capture the selection, then activate the fill.
        _ = tool.handle(.move(Vector(0, 0)), context: ctx)
        let outcome = tool.handle(.commit, context: ctx)

        guard case let .commit(edits) = outcome, edits.count == 1,
              case let .add(rec) = edits[0],
              case let .hatch(hatch) = rec.kind
        else {
            Issue.record("expected a single .add of a .hatch; got \(outcome)")
            return
        }
        #expect(hatch.solidFill == true)
        #expect(hatch.patternName == "SOLID")
        #expect(hatch.gradient == g)
    }
}
