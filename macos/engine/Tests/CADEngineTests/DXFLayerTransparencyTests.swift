//
//  DXFLayerTransparencyTests.swift
//  CADEngineTests
//
//  Per-LAYER TRANSPARENCY — DXF round-trip (Lane W3b-3bA).
//
//  The `Layer.opacity` value model + resolve/render path landed in W1-1D (see
//  `EntityTransparencyTests` → "Per-LAYER transparency (Wave W1-1D)"). This file
//  pins its DXF PERSISTENCE: DRW_Layer has no native transparency field, so a
//  non-opaque layer rides the LAYER table's XDATA — the AutoCAD `AcCmTransparency`
//  pair (code 1001 "AcCmTransparency" + code 1071 <value>), where the value uses
//  the SAME `(alpha_type<<24)|alpha` AcCmTransparency encoding as per-entity
//  transparency (code 440). The write/read codec lives in the bridge
//  (lcdxf.cpp writeLayers/addLayer) + Swift (DXFWriter.makeLayer /
//  DXFReader.mapLayers). NO vendored libdxfrw change — stock writeExtData/parseCode
//  already serialize/parse the 1001/1071 XDATA.
//
//  Round-trip happens at R2004+ (the version EntityTransparencyTests uses for code
//  440); the XDATA path itself is version-independent in libdxfrw's writeLayer, but
//  we keep the version consistent with the rest of the transparency suite.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Per-LAYER transparency (XDATA 1001 AcCmTransparency / 1071) — DXF round-trip")
struct DXFLayerTransparencyTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("layer-transparency-\(UUID().uuidString).dxf").path
    }

    /// A drawing whose layer table carries a single non-opaque layer plus one entity
    /// on it. Used by the round-trip tests.
    private func drawing(layerOpacity: Double)
        -> (records: [EntityRecord], layers: LayerTable) {
        let layers = LayerTable(
            layers: [Layer(name: "0"),
                     Layer(name: "Glass", color: .white, opacity: layerOpacity)],
            activeLayerName: "0")
        let rec = EntityRecord(
            id: EntityID(1),
            layer: LayerID("Glass"),
            pen: Pen(lineColor: .explicit(.white)),    // .byLayer transparency
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        return ([rec], layers)
    }

    // MARK: - (1) A 50%-opacity layer survives a DXF write → reopen

    @Test("a 50%-opacity layer's opacity is preserved through a DXF save → reopen (R2004)")
    func layerOpacityRoundTrip() async throws {
        let (records, layers) = drawing(layerOpacity: 0.5)
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let w = try await CADEngine.shared.writeEntities(
            records, layers: layers, toPath: path, version: .r2004)
        #expect(w.written == 1)

        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let glass = try #require(result.layers.layer(named: "Glass"))
        // 0.5 → round(0.5*255)=128 → 128/255 ≈ 0.502; allow a 1-LSB tolerance.
        #expect(abs(glass.opacity - 0.5) < 0.01)
        // The layer "0" the writer always emits stays fully opaque (no XDATA).
        #expect(try #require(result.layers.layer(named: "0")).opacity == 1.0)
    }

    @Test("a strongly-transparent layer (20%) also round-trips through DXF (R2004)")
    func layerOpacityRoundTripStrong() async throws {
        let (records, layers) = drawing(layerOpacity: 0.2)
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try await CADEngine.shared.writeEntities(
            records, layers: layers, toPath: path, version: .r2004)
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let glass = try #require(result.layers.layer(named: "Glass"))
        // 0.2 → round(0.2*255)=51 → 51/255 == 0.2 exactly.
        #expect(abs(glass.opacity - 0.2) < 0.01)
        // And a .byLayer entity on it inherits the layer's transparency on resolve.
        let ctx = ResolveContext(layerAttributes: { id in
            result.layers.layer(id)?.resolvedPen
                ?? ResolvedPen(color: .white, lineType: .solid, lineWidth: .default)
        })
        let line = try #require(
            result.records.first { if case .line = $0.kind { return true }; return false })
        let resolved = line.resolve(ctx)
        #expect(resolved.polylines.count == 1)
        #expect(abs(resolved.polylines[0].pen.color.a - 0.2) < 0.02)
    }

    // MARK: - (2) Back-compat: a layer with no transparency key reads as opaque

    @Test("a layer with NO AcCmTransparency XDATA reads as fully opaque (back-compat)")
    func backCompatNoXDataIsOpaque() async throws {
        // A plain (pre-transparency / opaque) layer table — no opacity authored — must
        // write NO 1071 group and read back fully opaque, byte-for-byte the historical
        // behavior. This is the path an old file (or any opaque drawing) takes.
        let layers = LayerTable(
            layers: [Layer(name: "0"),
                     Layer(name: "Walls", color: .white)],   // opacity defaults to 1
            activeLayerName: "0")
        let rec = EntityRecord(
            id: EntityID(1), layer: LayerID("Walls"),
            pen: Pen(lineColor: .explicit(.white)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: layers, toPath: path, version: .r2004)
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        #expect(try #require(result.layers.layer(named: "Walls")).opacity == 1.0)
        // Its resolvedPen is fully opaque — the pre-transparency render result.
        #expect(try #require(result.layers.layer(named: "Walls"))
            .resolvedPen.color.a == 1.0)
    }

    // MARK: - (3) Bridge-level: the 1071 value uses the AcCmTransparency encoding

    @Test("the written DXF carries the 1001 'AcCmTransparency' + 1071 group with the right encoding")
    func dxfEmitsAcCmTransparency1071() async throws {
        let (records, layers) = drawing(layerOpacity: 0.5)
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            records, layers: layers, toPath: path, version: .r2004)
        let text = try String(contentsOfFile: path, encoding: .utf8)

        // A DXF group is the code on its own line followed by the value line. The
        // appid string rides code 1001; the value rides code 1071.
        #expect(text.contains("AcCmTransparency"))
        #expect(text.contains("\n1071\n"))
        // AcCmTransparency encoding for opacity 0.5: type 0x02 ("by value") + alpha
        // round(0.5*255)=128 (0x80) ⇒ 0x02000080 == 33554560.
        #expect(text.contains("33554560"))
    }

    // MARK: - (4) Byte-identity-ish: an all-opaque drawing emits no spurious 1071

    @Test("an all-opaque drawing emits NO AcCmTransparency/1071 layer XDATA (byte-clean)")
    func allOpaqueEmitsNoLayerXData() async throws {
        // Every layer fully opaque (the default) — the writer must emit no
        // AcCmTransparency appid and no layer-XDATA 1071 group, so the output is
        // byte-identical to the pre-transparency writer.
        let layers = LayerTable(
            layers: [Layer(name: "0"),
                     Layer(name: "A", color: .white),     // opacity 1
                     Layer(name: "B", color: .white)],    // opacity 1
            activeLayerName: "0")
        let rec = EntityRecord(
            id: EntityID(1), layer: LayerID("A"),
            pen: Pen(lineColor: .explicit(.white)),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: layers, toPath: path, version: .r2004)
        let text = try String(contentsOfFile: path, encoding: .utf8)

        // The load-bearing marker: NO AcCmTransparency appid was written for any
        // layer (a default drawing emits no STYLE table either, so there is no other
        // 1071 source — but the appid is the unambiguous layer-transparency tell).
        #expect(!text.contains("AcCmTransparency"))
        // Sanity: round-trip still yields fully-opaque layers.
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        #expect(try #require(result.layers.layer(named: "A")).opacity == 1.0)
        #expect(try #require(result.layers.layer(named: "B")).opacity == 1.0)
    }
}
