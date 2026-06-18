//
//  LinetypeScaleTests.swift
//  CADEngineTests
//
//  Linetype SCALE — feature-gap Wave 4B.
//
//  Stage 1 (this file's model/resolve/round-trip sections): the per-entity linetype
//  scale (`Pen.linetypeScale`, DXF code 48), the drawing-wide `$LTSCALE`
//  (`GraphicVariables.linetypeScale`), the resolve product (entity × global →
//  `ResolvedPen.linetypeScale`), Codable back-compat, the code-48 READ path
//  (libdxfrw parses it; the app-side WRITE is a documented vendored-lib gap), and the
//  global `$LTSCALE` round-trip through the real codec.
//
//  The Stage-3 render scaling (the resolved scale → Metal `dashParamsPx` / CG
//  `dashLengths` dash period) is asserted in the `_Shared`-backed renderer tests
//  (`RendererGeometryTests` / `CGDashTests`); this file is the engine core.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Linetype scale (DXF 48 + \\$LTSCALE) — model + resolve + DXF round-trip")
struct LinetypeScaleTests {

    // MARK: - Value model

    @Test("Pen defaults linetypeScale to 1 (back-compatible unscaled)")
    func penDefaultUnscaled() {
        #expect(Pen().linetypeScale == 1)
        #expect(Pen.byLayer.linetypeScale == 1)
    }

    @Test("Pen carries an explicit per-entity linetype scale")
    func penExplicitScale() {
        let p = Pen(lineType: .dashed, linetypeScale: 2.5)
        #expect(p.linetypeScale == 2.5)
        #expect(p.lineType == .dashed)
    }

    // MARK: - Resolution chain (entity × global)

    @Test("resolved scale is the per-entity scale × the global \\$LTSCALE")
    func resolveProduct() {
        let pen = Pen(lineColor: .explicit(.white), lineType: .dashed, linetypeScale: 2)
        let ctx = ResolveContext(globalLinetypeScale: 3)
        let r = pen.resolved(layer: LayerID("0"), in: ctx)
        #expect(abs(r.linetypeScale - 6) < 1e-9)   // 2 × 3
    }

    @Test("a unit per-entity scale just carries the global \\$LTSCALE")
    func resolveGlobalOnly() {
        let pen = Pen(lineColor: .explicit(.white), lineType: .dashed)  // scale 1
        let r = pen.resolved(layer: LayerID("0"), in: ResolveContext(globalLinetypeScale: 4))
        #expect(abs(r.linetypeScale - 4) < 1e-9)
    }

    @Test("default resolve (no global, scale 1) is unscaled — regression")
    func resolveDefaultUnscaled() {
        let pen = Pen(lineColor: .explicit(.white), lineType: .dashed)
        let r = pen.resolved(layer: LayerID("0"), in: .default)
        #expect(r.linetypeScale == 1)
    }

    @Test("a 0/negative resolved scale is floored to 1 (never collapses the dash)")
    func resolveFloorsZero() {
        // A pathological 0 global scale would zero the product; ResolvedPen floors it.
        let pen = Pen(lineColor: .explicit(.white), lineType: .dashed, linetypeScale: 5)
        let r = pen.resolved(layer: LayerID("0"), in: ResolveContext(globalLinetypeScale: 0))
        #expect(r.linetypeScale == 1)
        // A direct construction with a negative scale is floored too.
        let rp = ResolvedPen(color: .white, lineType: .dashed, lineWidth: .default,
                             linetypeScale: -3)
        #expect(rp.linetypeScale == 1)
    }

    @Test("resolved scale flows through a full entity resolve onto every polyline pen")
    func resolveEntityPolylinePens() {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), lineType: .dashed, linetypeScale: 2),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let geo = rec.resolve(ResolveContext(globalLinetypeScale: 1.5))
        #expect(geo.polylines.count == 1)
        #expect(abs(geo.polylines[0].pen.linetypeScale - 3) < 1e-9)   // 2 × 1.5
    }

    // MARK: - Codable back-compat

    @Test("a Pen JSON WITHOUT a linetypeScale key decodes as 1")
    func codableBackCompat() throws {
        let modern = Pen(lineColor: .explicit(.white), lineType: .dashed,
                         lineWidth: .millimeters(0.5), linetypeScale: 2.0)
        let data = try JSONEncoder().encode(modern)
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["linetypeScale"] != nil)         // modern Pen DID encode the key
        obj.removeValue(forKey: "linetypeScale")
        let legacy = try JSONSerialization.data(withJSONObject: obj)

        let p = try JSONDecoder().decode(Pen.self, from: legacy)
        #expect(p.linetypeScale == 1)
        // The other fields still decode as authored.
        #expect(p.lineType == .dashed)
        #expect(p.lineWidth == .millimeters(0.5))
    }

    @Test("Pen with an explicit linetypeScale round-trips through Codable")
    func codableRoundTrip() throws {
        let p = Pen(lineColor: .explicit(.white), lineType: .dashed, linetypeScale: 0.75)
        let back = try JSONDecoder().decode(Pen.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        #expect(back.linetypeScale == 0.75)
    }

    // MARK: - DXF code-48 READ (libdxfrw parses it; app-side write is a vendored gap)

    /// A minimal DXF with one dashed LINE carrying a per-entity linetype scale
    /// (DXF code 48 == 2.5). Hand-authored so the test exercises libdxfrw's REAL
    /// code-48 parse (the value model's read mapping), independent of the write path.
    private static let lineWithCode48DXF = """
      0
    SECTION
      2
    ENTITIES
      0
    LINE
      8
    0
      6
    DASHED
     48
    2.5
     10
    0.0
     20
    0.0
     30
    0.0
     11
    10.0
     21
    0.0
     31
    0.0
      0
    ENDSEC
      0
    EOF

    """

    private func writeTemp(_ contents: String, ext: String = "dxf") throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltscale_\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("a DXF LINE with code 48 reads in as Pen.linetypeScale")
    func readsCode48() async throws {
        let path = try writeTemp(Self.lineWithCode48DXF)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let line = try #require(
            result.records.first { if case .line = $0.kind { return true }; return false })
        #expect(abs(line.pen.linetypeScale - 2.5) < 1e-6)
        #expect(line.pen.lineType == .dashed)
    }

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ltscale_\(UUID().uuidString).dxf").path
    }

    @Test("an entity with no code 48 reads back as unscaled (scale 1)")
    func absentCode48IsUnscaled() async throws {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), lineType: .dashed),  // scale 1
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: .r2000)
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let line = try #require(
            result.records.first { if case .line = $0.kind { return true }; return false })
        #expect(line.pen.linetypeScale == 1)
    }

    @Test("the writer now emits a per-entity code 48 (linetype scale) and it round-trips")
    func writeEmitsCode48() async throws {
        // UPSTREAM SYNC (#2603, "DWG round 3"): `dxfRW::writeEntity` now emits code 48
        // (per-entity linetype scale) for a non-default scale on post-R12 versions
        // (`if (version > AC1009 && ent->ltypeScale != 1.0) writeDouble(48, …)`).
        // This CLOSES the formerly-documented gap (the old test pinned "writer does
        // NOT emit code 48"). The bridge was already forward-prepared: it sets
        // ent.ltypeScale on write and reads src.ltypeScale into Pen.linetypeScale on
        // read, so a per-entity scale now survives a .dxf round-trip. Pin the new,
        // correct behavior — emission AND round-trip.
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), lineType: .dashed, linetypeScale: 3),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: .r2004)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        // Scope to the ENTITIES section: code 48 (right-aligned to width 3 → " 48")
        // ALSO appears in the DIMSTYLE table ($DIMTM, libdxfrw.cpp), so a whole-file
        // contains() would false-positive. Slice out the ENTITIES…ENDSEC block and
        // assert the per-entity LINE carries the code-48 group there now.
        let entities = entitiesSection(text)
        #expect(!entities.isEmpty, "could not locate the ENTITIES section")
        #expect(entities.contains("\n 48\n"),
                "writeEntity should now emit a per-entity code 48 for a non-default scale")
        #expect(entities.contains("LINE"))
        // The scale survives the round-trip back into Pen.linetypeScale.
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let line = try #require(
            result.records.first { if case .line = $0.kind { return true }; return false })
        #expect(abs(line.pen.linetypeScale - 3) < 1e-9,
                "per-entity linetype scale (code 48) must round-trip")
    }

    /// Returns the text from the `ENTITIES` group to the first following `ENDSEC`
    /// (the entities section), or "" if not found. Lets a test assert on per-entity
    /// groups without false-positives from other sections (HEADER / DIMSTYLE table).
    private func entitiesSection(_ text: String) -> String {
        guard let start = text.range(of: "\nENTITIES\n") else { return "" }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\nENDSEC\n") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Global \\$LTSCALE round-trip (save → reopen, the real codec)

    @Test("GraphicVariables.linetypeScale defaults to 1 + sets \\$LTSCALE")
    func graphicVarAccessor() {
        var gv = GraphicVariables()
        #expect(gv.linetypeScale == 1)
        gv.linetypeScale = 12
        #expect(gv.double("$LTSCALE") == 12)
        #expect(gv.has("$LTSCALE"))
    }

    @Test("the drawing-wide \\$LTSCALE survives a DXF save → reopen")
    func globalLtscaleRoundTrips() async throws {
        var gv = GraphicVariables()
        gv.linetypeScale = 4.0
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), lineType: .dashed),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), graphicVariables: gv, toPath: path, version: .r2000)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        #expect(abs(back.graphicVariables.linetypeScale - 4.0) < 1e-6,
                "global $LTSCALE did not round-trip")
    }

    @Test("a written DXF carries the \\$LTSCALE header group")
    func writesLtscaleHeaderGroup() async throws {
        var gv = GraphicVariables()
        gv.linetypeScale = 7.0
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [], layers: LayerTable(), graphicVariables: gv, toPath: path, version: .r2000)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        // The header carries the $LTSCALE var marker (code 9) and its code-40 value.
        // libdxfrw's ASCII writer right-aligns codes to width 3 (so "$LTSCALE\n 40\n")
        // and uses default stream precision (7.0 → "7"). Assert the var name + that a
        // `40`-group value of 7 follows it (rather than a brittle exact float string).
        #expect(text.contains("$LTSCALE"))
        let header = String(text.prefix(while: { _ in true }))
        if let range = header.range(of: "$LTSCALE") {
            let after = header[range.upperBound...].prefix(40)
            #expect(after.contains("7"), "expected the $LTSCALE value 7 after the var name, got: \(after)")
        }
    }

    @Test("the global \\$LTSCALE drives ResolveContext.globalLinetypeScale via the drawing")
    @MainActor
    func ltscaleDrivesResolveContext() {
        let d = CADDrawing()
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), lineType: .dashed, linetypeScale: 1.5),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        var gv = GraphicVariables()
        gv.linetypeScale = 2.0
        d.load(entities: [rec], layers: LayerTable(), graphicVariables: gv)
        let ctx = d.makeResolveContext()
        #expect(abs(ctx.globalLinetypeScale - 2.0) < 1e-9)
        // And the per-entity × global product flows onto the resolved polyline pen.
        let geo = rec.resolve(ctx)
        #expect(abs(geo.polylines[0].pen.linetypeScale - 3.0) < 1e-6)   // 1.5 × 2
    }
}
