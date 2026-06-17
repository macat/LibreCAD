//
//  EntityTransparencyTests.swift
//  CADEngineTests
//
//  Per-entity TRANSPARENCY (AutoCAD entity transparency, DXF code 440) — Wave 4A.
//
//  Stage 1 (this file): the value model (`PenTransparency`), the resolve chain
//  (ByLayer → layer opaque / ByBlock → block / explicit → value, folded into the
//  resolved color's alpha), Codable back-compat (a pre-transparency `Pen` decodes
//  as `.byLayer`), and the DXF code-440 round-trip (a transparent entity survives
//  a save → reopen through the DxfBridge write/read path, at R2004+ where libdxfrw
//  emits code 440).
//
//  Stage 2 render-flow assertions (resolved alpha → packed instance color / CG
//  stroke) live in `_Shared`-backed renderer tests; this file is the engine core.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Per-entity transparency (DXF 440) — model + resolve + DXF round-trip")
struct EntityTransparencyTests {

    // MARK: - Value model

    @Test("Pen defaults transparency to .byLayer (back-compatible opaque)")
    func penDefaultByLayer() {
        let p = Pen()
        #expect(p.transparency == .byLayer)
        #expect(Pen.byLayer.transparency == .byLayer)
    }

    @Test("PenTransparency.explicitOpacity clamps + reports only explicit values")
    func explicitOpacityAccessor() {
        #expect(PenTransparency.byLayer.explicitOpacity == nil)
        #expect(PenTransparency.byBlock.explicitOpacity == nil)
        #expect(PenTransparency.opacity(0.4).explicitOpacity == 0.4)
        // Clamps out-of-range.
        #expect(PenTransparency.opacity(1.5).explicitOpacity == 1.0)
        #expect(PenTransparency.opacity(-0.2).explicitOpacity == 0.0)
        #expect(PenTransparency.opaque == .opacity(1))
    }

    // MARK: - Resolution chain

    private func ctx(layerOpacity: Double = 1, blockOpacity: Double = 1) -> ResolveContext {
        ResolveContext(
            layerAttributes: { _ in
                ResolvedPen(color: .white, lineType: .solid, lineWidth: .default,
                            opacity: layerOpacity)
            },
            blockAttributes: { current in
                current ?? ResolvedPen(color: .white, lineType: .solid, lineWidth: .default,
                                       opacity: blockOpacity)
            })
    }

    @Test("explicit .opacity resolves to that value and folds into color.a")
    func resolveExplicit() {
        let pen = Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1)),
                      transparency: .opacity(0.5))
        let r = pen.resolved(layer: LayerID("0"), in: .default)
        #expect(r.opacity == 0.5)
        // Folded into the resolved color's alpha (1 * 0.5).
        #expect(abs(r.color.a - 0.5) < 1e-6)
        // RGB untouched.
        #expect(r.color.r == 1 && r.color.g == 0 && r.color.b == 0)
    }

    @Test(".byLayer resolves to the layer's opacity (OPAQUE this wave)")
    func resolveByLayer() {
        // Layer has no transparency field yet → layerPen.opacity defaults to 1.
        let pen = Pen(transparency: .byLayer)
        let r = pen.resolved(layer: LayerID("0"), in: .default)
        #expect(r.opacity == 1.0)
        #expect(abs(r.color.a - 1.0) < 1e-6)
    }

    @Test(".byLayer picks up a non-opaque layer opacity if the layer supplies one")
    func resolveByLayerNonOpaque() {
        let pen = Pen(transparency: .byLayer)
        let r = pen.resolved(layer: LayerID("0"), in: ctx(layerOpacity: 0.25))
        #expect(abs(r.opacity - 0.25) < 1e-6)
        #expect(abs(r.color.a - 0.25) < 1e-6)
    }

    @Test(".byBlock resolves to the placing block's opacity")
    func resolveByBlock() {
        let pen = Pen(transparency: .byBlock)
        let r = pen.resolved(layer: LayerID("0"), in: ctx(blockOpacity: 0.6))
        #expect(abs(r.opacity - 0.6) < 1e-6)
        #expect(abs(r.color.a - 0.6) < 1e-6)
    }

    @Test("opaque default leaves the resolved color alpha unchanged (regression)")
    func resolveOpaqueRegression() {
        // A plain pen (everything ByLayer) — the historical case — must resolve to a
        // fully-opaque color, byte-for-byte as before transparency existed.
        let pen = Pen()
        let r = pen.resolved(layer: LayerID("0"), in: .default)
        #expect(r.opacity == 1.0)
        #expect(r.color.a == 1.0)
    }

    @Test("resolved opacity flows through a full entity resolve into every polyline pen")
    func resolveEntityPolylinePens() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), transparency: .opacity(0.3)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let geo = rec.resolve()
        #expect(geo.polylines.count == 1)
        let pen = geo.polylines[0].pen
        #expect(abs(pen.opacity - 0.3) < 1e-6)
        #expect(abs(pen.color.a - 0.3) < 1e-6)
    }

    @Test("resolved opacity flows into a fill's color alpha (solid entity)")
    func resolveFillAlpha() {
        let corners = [Vector(0, 0), Vector(10, 0), Vector(10, 10)]
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1)), transparency: .opacity(0.5)),
            kind: .solid(SolidData(corners: corners)))
        let geo = rec.resolve()
        #expect(geo.fills.count == 1)
        // ResolvedFill.color comes from pen.color, which carries the folded alpha.
        #expect(abs(geo.fills[0].color.a - 0.5) < 1e-6)
    }

    // MARK: - Codable back-compat

    @Test("a Pen JSON WITHOUT a transparency key decodes as .byLayer")
    func codableBackCompat() throws {
        // Build a "legacy" Pen JSON by encoding a real Pen, then STRIPPING the
        // `transparency` key from the JSON object — this exercises the actual
        // `decodeIfPresent(...) ?? .byLayer` path using the real (synthesized) enum
        // encoding shape, instead of guessing it.
        let modern = Pen(lineColor: .explicit(.white), lineType: .dashed,
                         lineWidth: .millimeters(0.5), transparency: .opacity(0.5))
        let data = try JSONEncoder().encode(modern)
        var obj = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["transparency"] != nil)   // modern Pen DID encode the key
        obj.removeValue(forKey: "transparency")
        let legacy = try JSONSerialization.data(withJSONObject: obj)

        let p = try JSONDecoder().decode(Pen.self, from: legacy)
        #expect(p.transparency == .byLayer)
        // The other three fields still decode as authored.
        #expect(p.lineType == .dashed)
        #expect(p.lineWidth == .millimeters(0.5))
    }

    @Test("Pen with explicit transparency round-trips through Codable")
    func codableRoundTrip() throws {
        let p = Pen(lineColor: .explicit(.white),
                    lineType: .dashed,
                    lineWidth: .millimeters(0.5),
                    transparency: .opacity(0.42))
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Pen.self, from: data)
        #expect(back == p)
        #expect(back.transparency == .opacity(0.42))
    }

    // MARK: - DXF code-440 round-trip (save → reopen)

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("transparency-\(UUID().uuidString).dxf").path
    }

    @Test("an explicit-transparency entity survives a DXF save → reopen (R2004)")
    func dxfRoundTripExplicit() async throws {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1)), transparency: .opacity(0.5)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 10))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // libdxfrw writes DXF code 440 only for versions > AC1015 (R2000); use R2004.
        let w = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: .r2004)
        #expect(w.written == 1)

        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let lines = result.records.filter { if case .line = $0.kind { return true }; return false }
        #expect(lines.count == 1)
        let back = lines[0].pen.transparency
        // 0.5 → round(0.5*255)=128 → 128/255 ≈ 0.502; allow a 1-LSB tolerance.
        guard let a = back.explicitOpacity else {
            Issue.record("expected an explicit opacity, got \(back)")
            return
        }
        #expect(abs(a - 0.5) < 0.01)
    }

    @Test("a 440-tagged file resolves to a transparent rendered alpha after reopen")
    func dxfRoundTripResolvesToAlpha() async throws {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), transparency: .opacity(0.25)),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: .r2004)
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let circle = result.records.first { if case .circle = $0.kind { return true }; return false }
        let resolved = try #require(circle).resolve()
        #expect(resolved.polylines.count == 1)
        // The reopened entity's resolved stroke alpha is the transparent value.
        #expect(abs(resolved.polylines[0].pen.color.a - 0.25) < 0.02)
    }

    @Test("an OPAQUE (ByLayer) entity round-trips unchanged — no 440 group, stays ByLayer")
    func dxfRoundTripOpaqueRegression() async throws {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white)),   // transparency defaults to .byLayer
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: .r2004)
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let line = result.records.first { if case .line = $0.kind { return true }; return false }
        #expect(try #require(line).pen.transparency == .byLayer)
        // And it still resolves fully opaque.
        #expect(try #require(line).resolve().polylines[0].pen.color.a == 1.0)
    }

    @Test("the written DXF carries a code-440 group for a transparent entity (R2004)")
    func dxfWritesCode440() async throws {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), transparency: .opacity(0.5)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: .r2004)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        // A DXF group is the code on its own line followed by the value line. The
        // "by value" type byte (0x02) + alpha 128 == 0x02000080 == 33554560.
        #expect(text.contains("\n440\n"))
        #expect(text.contains("33554560"))
    }
}
