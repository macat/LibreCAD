//
//  DXFRoundTripFindingsTests.swift
//  CADEngineTests
//
//  Regression tests for three DXF round-trip findings (write→read fidelity):
//
//   1. Per-entity DIMENSION text-height / arrow-size OVERRIDE. The override is read
//      from the file (ACAD:DSTYLE xdata) but was DROPPED on write. The Swift writer
//      (`DXFWriter.applyDimension`) now stamps the override + its `has*` flag onto
//      the bridge POD, and the bridge (`lcdxf.cpp::writeDimension`) builds the
//      matching ACAD:DSTYLE xdata. We assert: (a) the override survives the engine
//      value (Codable) round-trip the document save uses, and (b) the writer emits
//      the override fields into the POD. NOTE: the full DXF byte-level round-trip of
//      the DSTYLE group is gated on a 1-line vendored libdxfrw patch
//      (`dxfRW::writeDimension` does not call `writeExtData`) — see the PINNED test
//      `dimensionOverrideDXFRoundTrip_pendingVendoredEmit` below, which flips when
//      that patch lands.
//
//   2. SPLINE code-70 flags (periodic / linear). Read from the file but
//      re-synthesized on write, so the periodic / linear bits were lost. `SplineData`
//      now carries the raw `splineFlags`; the reader fills it (DXFReader.mapSpline)
//      and the writer prefers it (DXFWriter `.spline` arm). We assert the raw flags
//      survive a write→read DXF round-trip and through the Codable value model.
//
//   3. HEADER $DIMEXO / $DIMEXE / $DIMGAP. Written but never read back. The reader
//      (`mapGraphicVariables`) now reads them under their `has*` guards, symmetric
//      with the writer's `makeHeader`. We assert all three survive a write→read DXF
//      round-trip.
//
//  Uses the production DxfBridge write/read path (`CADEngine.shared`) into a temp
//  file, mirroring DXFWriteFidelityTests / DimSubtypeRoundTripTests.
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

@Suite("DXF round-trip findings — dim overrides, spline flags, header dim-vars")
struct DXFRoundTripFindingsTests {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dxf-findings-\(UUID().uuidString).dxf").path
    }

    /// Writes the records (+ optional graphic vars) to DXF, re-reads, and returns the
    /// full read result. The default layer "0" keeps the layer table well-formed.
    private func roundTrip(
        _ records: [EntityRecord],
        graphicVariables: GraphicVariables = GraphicVariables()
    ) async throws -> CADEngine.DXFReadResult {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let wr = try await CADEngine.shared.writeEntities(
            records, layers: layers, graphicVariables: graphicVariables, toPath: path)
        #expect(wr.skipped == 0)
        return try await CADEngine.shared.readEntities(dxfPath: path)
    }

    private func firstDim(_ records: [EntityRecord]) -> DimData? {
        for r in records { if case .dimension(let d) = r.kind { return d } }
        return nil
    }
    private func firstSpline(_ records: [EntityRecord]) -> SplineData? {
        for r in records { if case .spline(let d) = r.kind { return d } }
        return nil
    }

    // MARK: - Finding #1: per-entity DIMENSION text-height / arrow-size override

    @Test("a dimension's per-entity text-height + arrow-size override survives the engine value round-trip")
    func dimensionOverrideCodableRoundTrip() throws {
        // The full per-entity-override fidelity always round-trips through the engine
        // value model (the document save codec / undo snapshots), independent of the
        // DXF DSTYLE-xdata emit. A non-default, distinct text height + arrow size.
        let d = DimData(
            kind: .aligned(extension1: Vector(0, 0), extension2: Vector(10, 0)),
            definitionPoint: Vector(0, 5),
            textHeight: 0.180,
            arrowSize: 0.090)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DimData.self, from: data)
        #expect(abs(back.textHeight - 0.180) < 1e-12)
        #expect(abs(back.arrowSize - 0.090) < 1e-12)
    }

    @Test("the DXF writer emits the per-entity override into the file as an ACAD:DSTYLE xdata group that survives a byte round-trip")
    func dimensionOverrideDXFRoundTrip() async throws {
        // The Swift writer + bridge BUILD the ACAD:DSTYLE xdata on the DIMENSION
        // (text-height dim-var 140, arrow-size 41), and the 1-line vendored patch to
        // `dxfRW::writeDimension` (now calling `writeExtData(ent->extData)`, mirroring
        // writeMText) serializes it to the .dxf bytes — so the per-entity override now
        // survives a full write→read round-trip.
        let rec = EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: .aligned(extension1: Vector(0, 0), extension2: Vector(10, 0)),
            definitionPoint: Vector(0, 5),
            textHeight: 0.180,
            arrowSize: 0.090)))
        let result = try await roundTrip([rec])
        let d = try #require(firstDim(result.records), "expected a re-read dimension")

        // The per-entity override now round-trips through the DXF bytes (ACAD:DSTYLE).
        #expect(abs(d.textHeight - 0.180) < 1e-6,
                "the DSTYLE text-height override should survive the DXF byte round-trip")
        #expect(abs(d.arrowSize - 0.090) < 1e-6,
                "the DSTYLE arrow-size override should survive the DXF byte round-trip")
    }

    @Test("a dimension with NO per-entity override writes no DSTYLE override + reads back as inherit (0)")
    func dimensionNoOverrideStaysInherit() async throws {
        // textHeight/arrowSize == 0 is the "inherit the document/style default"
        // sentinel; the writer must NOT emit a spurious DSTYLE override for it, and
        // it must read back as 0 (not the 2.5 DimData.init default).
        let rec = EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: .aligned(extension1: Vector(0, 0), extension2: Vector(10, 0)),
            definitionPoint: Vector(0, 5),
            textHeight: 0,
            arrowSize: 0)))
        let result = try await roundTrip([rec])
        let d = try #require(firstDim(result.records), "expected a re-read dimension")
        #expect(d.textHeight == 0)
        #expect(d.arrowSize == 0)
    }

    // MARK: - Finding #2: SPLINE code-70 raw flags (periodic / linear)

    @Test("a spline's raw code-70 flags (planar+linear) survive a DXF write -> read round-trip")
    func splineLinearFlagsRoundTrip() async throws {
        // A degree-1 spline with the LINEAR bit (16) set in code-70, plus PLANAR (8).
        // Before the fix the writer re-synthesized flags from `closed`/`weights` and
        // dropped the linear bit; now the raw flags ride through.
        let rawFlags = 0b1_1000   // 16 linear | 8 planar
        let spline = SplineData(
            degree: 1,
            controlPoints: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            closed: false,
            splineFlags: rawFlags)
        let rec = EntityRecord(id: EntityID(1), kind: .spline(spline))
        let result = try await roundTrip([rec])
        let back = try #require(firstSpline(result.records), "expected a re-read spline")
        #expect(back.splineFlags == rawFlags,
                "raw code-70 flags must survive instead of being re-synthesized (got \(back.splineFlags))")
        // The linear bit (16) specifically must be preserved.
        #expect((back.splineFlags & 0b1_0000) != 0, "the linear (16) bit must survive")
    }

    @Test("a periodic/closed spline's code-70 periodic bit survives the round-trip")
    func splinePeriodicFlagsRoundTrip() async throws {
        // A closed cubic with the PERIODIC bit (2) set alongside CLOSED (1) + PLANAR
        // (8). The synthesized default for a closed spline is 0b1011 (closed|periodic|
        // planar); set a value that additionally carries RATIONAL (4) so we prove the
        // RAW flags — not just the synthesized subset — round-trip.
        let rawFlags = 0b1111   // 8 planar | 4 rational | 2 periodic | 1 closed
        let cps = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let spline = SplineData(
            degree: 3,
            controlPoints: cps,
            weights: [1, 1, 1, 1],   // rational (one weight per control point)
            closed: true,
            splineFlags: rawFlags)
        let rec = EntityRecord(id: EntityID(1), kind: .spline(spline))
        let result = try await roundTrip([rec])
        let back = try #require(firstSpline(result.records), "expected a re-read spline")
        #expect(back.splineFlags == rawFlags,
                "raw periodic/rational/closed/planar flags must survive (got \(back.splineFlags))")
        #expect((back.splineFlags & 0b0010) != 0, "the periodic (2) bit must survive")
    }

    @Test("an engine-authored spline (splineFlags == 0) still writes synthesized flags")
    func engineAuthoredSplineSynthesizesFlags() async throws {
        // splineFlags == 0 means "unknown / engine-authored"; the writer must fall
        // back to synthesizing sane flags (planar; closed ⇒ closed|periodic) so the
        // emitted SPLINE is still well-formed and re-reads with non-zero flags.
        let spline = SplineData(
            degree: 2,
            controlPoints: [Vector(0, 0), Vector(5, 5), Vector(10, 0)],
            closed: false,
            splineFlags: 0)
        let rec = EntityRecord(id: EntityID(1), kind: .spline(spline))
        let result = try await roundTrip([rec])
        let back = try #require(firstSpline(result.records), "expected a re-read spline")
        // Synthesized default for an open, non-rational spline is PLANAR (8).
        #expect((back.splineFlags & 0b1000) != 0, "the synthesized planar (8) bit must be present")
    }

    @Test("SplineData.splineFlags survives the engine Codable value round-trip + back-compat default")
    func splineFlagsCodable() throws {
        let spline = SplineData(
            degree: 2,
            controlPoints: [Vector(0, 0), Vector(5, 5), Vector(10, 0)],
            splineFlags: 0b1_0000)
        let data = try JSONEncoder().encode(spline)
        let back = try JSONDecoder().decode(SplineData.self, from: data)
        #expect(back.splineFlags == 0b1_0000)

        // Back-compat: a payload predating `splineFlags` (the key absent) decodes to
        // the `0` "unknown" default rather than failing. Build the legacy JSON by
        // encoding a current value and STRIPPING the `splineFlags` key, so the
        // control-point encoding matches Vector's real Codable shape exactly.
        let full = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var legacyObj = full
        legacyObj.removeValue(forKey: "splineFlags")
        #expect(legacyObj["splineFlags"] == nil, "the legacy payload must omit splineFlags")
        let legacy = try JSONSerialization.data(withJSONObject: legacyObj)
        let legacyBack = try JSONDecoder().decode(SplineData.self, from: legacy)
        #expect(legacyBack.splineFlags == 0, "a pre-splineFlags payload must default to 0")
        #expect(legacyBack.degree == 2)
        #expect(legacyBack.controlPoints.count == 3)
    }

    // MARK: - Finding #3: HEADER $DIMEXO / $DIMEXE / $DIMGAP read-back

    @Test("HEADER $DIMEXO / $DIMEXE / $DIMGAP survive a DXF write -> read round-trip")
    func headerDimExtensionVarsRoundTrip() async throws {
        // Set all three to distinct non-default values (the engine default is 0). The
        // writer emits them (gv.has guard); before the fix the reader dropped them on
        // read. Now they read back via mapGraphicVariables under their `has*` guards.
        var gv = GraphicVariables()
        gv.dimExtensionOffset = 0.0625   // $DIMEXO
        gv.dimExtensionBeyond = 0.1250   // $DIMEXE
        gv.dimTextGap = 0.0900           // $DIMGAP

        // A single plain entity so the file is non-empty + the header section emits.
        let rec = EntityRecord(id: EntityID(1),
                               kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let result = try await roundTrip([rec], graphicVariables: gv)
        let rgv = result.graphicVariables
        #expect(abs(rgv.dimExtensionOffset - 0.0625) < 1e-9,
                "$DIMEXO must read back (got \(rgv.dimExtensionOffset))")
        #expect(abs(rgv.dimExtensionBeyond - 0.1250) < 1e-9,
                "$DIMEXE must read back (got \(rgv.dimExtensionBeyond))")
        #expect(abs(rgv.dimTextGap - 0.0900) < 1e-9,
                "$DIMGAP must read back (got \(rgv.dimTextGap))")
    }

    @Test("when WE supply no dim-extension vars, libdxfrw writes its standard defaults and the reader now faithfully reads them")
    func headerDimExtensionVarsLibdxfrwDefaultsAreRead() async throws {
        // We set NONE of the dim-extension vars, but stock libdxfrw's drw_header.cpp
        // unconditionally emits its built-in defaults ($DIMEXO=0.625, $DIMEXE=1.25,
        // $DIMGAP=0.625 — the AutoCAD metric defaults). Before this fix the reader
        // DROPPED these on read (so the engine fell back to 0); now it reads them
        // (their `has*` flags are set by libdxfrw's emit). This documents that an
        // "unset on our side" var is NOT distinguishable from libdxfrw's default
        // after a round-trip — a stock-library characteristic, not a reader bug.
        let rec = EntityRecord(id: EntityID(1),
                               kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let result = try await roundTrip([rec])
        let rgv = result.graphicVariables
        #expect(abs(rgv.dimExtensionOffset - 0.625) < 1e-9,
                "libdxfrw's default $DIMEXO (0.625) is now read back (got \(rgv.dimExtensionOffset))")
        #expect(abs(rgv.dimExtensionBeyond - 1.25) < 1e-9,
                "libdxfrw's default $DIMEXE (1.25) is now read back (got \(rgv.dimExtensionBeyond))")
        #expect(abs(rgv.dimTextGap - 0.625) < 1e-9,
                "libdxfrw's default $DIMGAP (0.625) is now read back (got \(rgv.dimTextGap))")
    }
}
