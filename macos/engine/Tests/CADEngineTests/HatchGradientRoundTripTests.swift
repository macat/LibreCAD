//
//  HatchGradientRoundTripTests.swift
//  CADEngineTests
//
//  DXF round-trip tests for the GRADIENT hatch (wave GH-W3): a gradient hatch's
//  KIND (linear/radial), STOP COLORS and ANGLE survive write→reread through the
//  full DxfBridge path (Swift HatchGradient -> POD -> DRW_Hatch gradient block ->
//  DXF codes 450..470/463/421 -> back). Builds on the GH-W1 HatchGradient model.
//
//  Pins exactly what round-trips:
//   - a TWO-color linear gradient: kind + both stop colors (24-bit RGB, code 421)
//     + angle (code 460, RADIANS) survive.
//   - a TWO-color radial gradient: the radial KIND mapping survives (the C side
//     emits "SPHERICAL"; the reader classifies it back to .radial).
//   - a SINGLE-color gradient: 1-stop count + its color survive.
//   - a non-gradient hatch reads back with gradient == nil (no spurious gradient).
//
//  Uses the same write/read helpers as HatchPatternRoundTripTests (a temp file).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Hatch gradient — DXF round-trip (GH-W3)")
struct HatchGradientRoundTripTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchgrad-test-\(UUID().uuidString).dxf").path
    }
    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func firstHatch(_ records: [EntityRecord]) -> HatchData? {
        for r in records { if case .hatch(let d) = r.kind { return d } }
        return nil
    }

    private var squareRing: [PolylineVertex] {
        [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ]
    }

    // 24-bit RGB round-trips lossless when the components are exact byte values
    // (multiples of 1/255). Use such colors so the stop comparison is exact-ish.
    private let red  = RGBAColor(1, 0, 0)            // 0xFF0000
    private let blue = RGBAColor(0, 0, 1)            // 0x0000FF
    private let green = RGBAColor(0, 1, 0)           // 0x00FF00

    private func roundTrip(_ hatch: EntityRecord) async throws -> HatchData {
        let path = tempDXFPath()
        defer { removeFile(path) }
        let w = try await CADEngine.shared.writeEntities([hatch], layers: LayerTable(), toPath: path)
        #expect(w.written == 1)
        #expect(w.skipped == 0)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        return try #require(firstHatch(back.records), "hatch missing after round-trip")
    }

    private func expectColorClose(_ a: RGBAColor, _ b: RGBAColor,
                                  _ tol: Float = 1.5 / 255.0) {
        #expect(abs(a.r - b.r) < tol, "r: \(a.r) vs \(b.r)")
        #expect(abs(a.g - b.g) < tol, "g: \(a.g) vs \(b.g)")
        #expect(abs(a.b - b.b) < tol, "b: \(a.b) vs \(b.b)")
    }

    // MARK: - two-color LINEAR gradient: kind + colors + angle round-trip

    @Test("a two-color linear gradient round-trips kind, both stop colors and angle")
    func twoColorLinearRoundTrip() async throws {
        let grad = HatchGradient(kind: .linear, colors: [red, blue], angle: .pi / 4)  // 45°
        let hatch = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true,
                                   gradient: grad)))
        let d = try await roundTrip(hatch)
        let g = try #require(d.gradient, "gradient dropped on round-trip")
        #expect(g.kind == .linear)
        #expect(g.colors.count == 2)
        expectColorClose(g.colors[0], red)
        expectColorClose(g.colors[1], blue)
        // Code 460 is RADIANS end-to-end (no deg conversion) — survives near-exact.
        #expect(abs(g.angle - .pi / 4) < 1e-9, "angle (radians) drifted: \(g.angle)")
    }

    // MARK: - two-color RADIAL gradient: the radial KIND mapping survives

    @Test("a radial gradient round-trips its radial kind (SPHERICAL <-> .radial)")
    func radialKindRoundTrip() async throws {
        let grad = HatchGradient(kind: .radial, colors: [green, blue], angle: 0)
        let hatch = EntityRecord(
            id: EntityID(2),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true,
                                   gradient: grad)))
        let d = try await roundTrip(hatch)
        let g = try #require(d.gradient, "gradient dropped on round-trip")
        #expect(g.kind == .radial, "radial kind not preserved")
        #expect(g.colors.count == 2)
        expectColorClose(g.colors[0], green)
        expectColorClose(g.colors[1], blue)
    }

    // MARK: - single-color gradient: 1-stop count + color survive

    @Test("a single-color gradient round-trips its one stop")
    func singleColorRoundTrip() async throws {
        let grad = HatchGradient(kind: .linear, colors: [red], angle: 0)
        let hatch = EntityRecord(
            id: EntityID(3),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true,
                                   gradient: grad)))
        let d = try await roundTrip(hatch)
        let g = try #require(d.gradient, "single-color gradient dropped")
        #expect(g.kind == .linear)
        #expect(g.colors.count == 1, "expected exactly one stop, got \(g.colors.count)")
        expectColorClose(g.colors[0], red)
    }

    // MARK: - a non-zero gradient angle (not a round multiple) survives

    @Test("a gradient angle that is not a round multiple survives (radians, no deg drift)")
    func arbitraryAngleRoundTrip() async throws {
        let angle = 1.2345
        let grad = HatchGradient(kind: .linear, colors: [red, blue], angle: angle)
        let hatch = EntityRecord(
            id: EntityID(4),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true,
                                   gradient: grad)))
        let d = try await roundTrip(hatch)
        let g = try #require(d.gradient)
        #expect(abs(g.angle - angle) < 1e-9, "angle drifted: \(g.angle) vs \(angle)")
    }

    // MARK: - a plain (non-gradient) hatch reads back with gradient == nil

    @Test("a non-gradient hatch round-trips with gradient == nil (no spurious gradient)")
    func nonGradientStaysNil() async throws {
        let hatch = EntityRecord(
            id: EntityID(5),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false,
                                   patternName: "ANSI31")))
        let d = try await roundTrip(hatch)
        #expect(d.gradient == nil, "a pattern hatch should have no gradient")
        #expect(d.patternName?.uppercased() == "ANSI31")
    }

    // MARK: - a gradient hatch still resolves (GH-W1 resolve path) after round-trip

    @Test("a re-read gradient hatch resolves to a gradient fill")
    func roundTrippedGradientResolves() async throws {
        let grad = HatchGradient(kind: .linear, colors: [red, blue], angle: .pi / 6)
        let hatch = EntityRecord(
            id: EntityID(6),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true,
                                   gradient: grad)))
        let d = try await roundTrip(hatch)
        _ = try #require(d.gradient)
        // The resolved geometry should carry the gradient (GH-W1 resolveHatch);
        // a gradient hatch produces a filled region (not pattern lines).
        let geo = EntityRecord(id: EntityID(99), kind: .hatch(d)).resolve(ResolveContext())
        let fill = try #require(geo.fills.first, "a gradient hatch should resolve to a fill")
        let rg = try #require(fill.gradient, "the resolved fill should carry the gradient")
        #expect(rg.kind == .linear)
        #expect(rg.colors.count == 2)
    }
}
