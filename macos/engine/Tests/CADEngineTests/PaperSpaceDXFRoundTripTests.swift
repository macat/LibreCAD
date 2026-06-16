//
//  PaperSpaceDXFRoundTripTests.swift
//  CADEngineTests
//
//  Paper space — Phase 1 (paperspace-plan.md §3): the LIVE DXF/DWG file round-trip
//  for the per-entity space tag (DXF code 67) and the reconstructed single layout.
//  This is the on-disk twin of the in-memory P0 coverage in `PaperSpaceModelTests`
//  (which exercises the `DXFPayload ↔ CADDrawing` value model, not the file bytes).
//
//  These backfill the "tests follow" gap left when P1 was salvaged after an infra
//  error: the writer tags a paper record's POD `spaceFlag` (→ DRW_Entity::space →
//  DXF code 67 == 1) and libdxfrw emits the built-in `*Paper_Space` block; the
//  reader maps that membership / code 67 back onto `EntityRecord.space == .paper`
//  and reconstructs a single "Layout1" (stock libdxfrw does not parse the LAYOUT
//  dictionary, so at most ONE layout reconstructs — see DXFReader.mapLayouts).
//
//  We drive the engine's PUBLIC file entry points directly (not the higher-level
//  document codec, which `SaveRoundTripTests` already covers):
//    • write: `CADEngine.shared.writeEntities(_:layers:toPath:)`  (DXF, R2000 default)
//             `CADEngine.shared.writeEntities(_:layers:toDWGPath:)`(DWG, R2000)
//    • read : `CADEngine.shared.readEntities(dxfPath:)` / `readEntities(dwgPath:)`
//  exactly as `DWGReadWriteTests` / `DXFWriterTests` do (temp file in the system
//  temp dir, cleaned up via `defer`).
//
//  Uniquely namespaced (`@Suite("paper space P1 (DXF/DWG code-67 file round-trip)")`)
//  so it does not collide with the other suites in the shared test target.
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

@Suite("paper space P1 (DXF/DWG code-67 file round-trip)")
struct PaperSpaceDXFRoundTripTests {

    // MARK: - Helpers

    /// A fresh temp path with the given extension in the system temp dir; the caller
    /// cleans it up via `defer { removeFile(path) }`.
    private func tempPath(ext: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paperspace-p1-\(UUID().uuidString).\(ext)").path
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The standard single-layer "0" table the file always carries.
    private func layer0() -> LayerTable {
        LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
    }

    /// A paper-space LINE bound to "Layout1".
    private func paperLine() -> EntityRecord {
        EntityRecord(id: EntityID(1), layer: LayerID("0"),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(50, 0))),
                     space: .paper, layoutName: "Layout1")
    }

    /// A model-space LINE (the default space).
    private func modelLine() -> EntityRecord {
        EntityRecord(id: EntityID(2), layer: LayerID("0"),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 10))))
    }

    /// Classify the read-back records into (model lines, paper lines) by GEOMETRY so we
    /// match the SAME entity across the round-trip regardless of re-minted ids. The
    /// paper line runs to (50,0); the model line runs to (10,10).
    private func splitLines(_ records: [EntityRecord]) -> (model: [EntityRecord], paper: [EntityRecord]) {
        var model: [EntityRecord] = []
        var paper: [EntityRecord] = []
        for r in records {
            guard case .line(let d) = r.kind else { continue }
            if abs(d.end.x - 50) < 1e-6, abs(d.end.y - 0) < 1e-6 {
                paper.append(r)
            } else if abs(d.end.x - 10) < 1e-6, abs(d.end.y - 10) < 1e-6 {
                model.append(r)
            }
        }
        return (model, paper)
    }

    // MARK: - 1) Code-67 round-trip (DXF)

    @Test("a paper LINE returns space == .paper; a model LINE returns space == .model (DXF code 67)")
    func code67RoundTripsThroughDXF() async throws {
        let path = tempPath(ext: "dxf")
        defer { removeFile(path) }

        let result = try await CADEngine.shared.writeEntities(
            [paperLine(), modelLine()], layers: layer0(), toPath: path)
        // Both lines are a writer-supported kind — nothing skipped.
        #expect(result.skipped == 0)
        #expect(result.written == 2)
        #expect(FileManager.default.fileExists(atPath: path))

        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let (model, paper) = splitLines(back.records)

        // The paper line came back tagged `.paper` (its DXF code 67 / `*Paper_Space`
        // block membership round-tripped via the bridge's `spaceFlag`); the model line
        // stayed model space.
        let p = try #require(paper.first, "the paper-space LINE was lost on the DXF round-trip")
        #expect(p.space == .paper)

        let m = try #require(model.first, "the model-space LINE was lost on the DXF round-trip")
        #expect(m.space == .model)
        #expect(m.layoutName == nil)

        // Exactly one of each — the space tag did NOT leak from one onto the other.
        #expect(paper.count == 1)
        #expect(model.count == 1)

        // KNOWN LOSS: stock libdxfrw membership in the single built-in `*Paper_Space`
        // block sets the entity's SPACE (code 67) but does NOT attach a per-entity
        // layout NAME, so the re-read paper entity's `layoutName` is nil even though the
        // file reconstructs a "Layout1" sheet (see the single-layout test below). The
        // entity↔sheet binding by name needs a libdxfrw LAYOUT-dictionary patch. When
        // that lands (the bridge stamps the entity's `layoutName`), FLIP this to assert
        // `p.layoutName?.caseInsensitiveCompare("Layout1") == .orderedSame`.
        #expect(p.layoutName == nil,
                "a per-entity paper-space layout name unexpectedly round-tripped — libdxfrw may have gained LAYOUT-dictionary support; promote this to assert the layout name survives")
    }

    // MARK: - 2) Single-layout reconstruction (DXF)

    @Test("paper content reconstructs ONE layout (Layout1, tabOrder 0); model-only ⇒ no layouts (DXF)")
    func singleLayoutReconstructionDXF() async throws {
        // (a) A file WITH paper content reconstructs exactly one layout.
        let withPaper = tempPath(ext: "dxf")
        defer { removeFile(withPaper) }
        _ = try await CADEngine.shared.writeEntities(
            [paperLine(), modelLine()], layers: layer0(), toPath: withPaper)
        let pRes = try await CADEngine.shared.readEntities(dxfPath: withPaper)
        #expect(pRes.layouts.count == 1)
        let layout = try #require(pRes.layouts.first)
        #expect(layout.name == "Layout1")
        #expect(layout.tabOrder == 0)

        // (b) A model-ONLY file reconstructs NO layouts (no paper-space block at all).
        let modelOnly = tempPath(ext: "dxf")
        defer { removeFile(modelOnly) }
        _ = try await CADEngine.shared.writeEntities(
            [modelLine()], layers: layer0(), toPath: modelOnly)
        let mRes = try await CADEngine.shared.readEntities(dxfPath: modelOnly)
        #expect(mRes.layouts.isEmpty)
        // ...and every record read back is model space.
        #expect(mRes.records.allSatisfy { $0.space == .model })
    }

    // MARK: - 3) PLOTSETTINGS margin loss (regression-DOCUMENTING)

    @Test("the reconstructed layout's margin is NOT preserved — falls back to the A4 default (no PLOTSETTINGS write)")
    func plotSettingsMarginIsLost() async throws {
        // The high-level save path would carry a layout's PageDescriptor, but the WRITER
        // emits no PLOTSETTINGS object (DXFWriter.makeEntity carries spaceFlag/layoutName
        // only — see DXFWriter.swift:454). So on read the reconstructed layout's page has
        // the A4 default margin (10 mm), NOT whatever a layout's PageDescriptor specified.
        //
        // We write a paper entity (which produces the *Paper_Space block) but never a
        // PLOTSETTINGS object, then assert the reconstructed margin is the A4 default.
        let path = tempPath(ext: "dxf")
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities(
            [paperLine()], layers: layer0(), toPath: path)

        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let layout = try #require(back.layouts.first,
                                  "paper content should still reconstruct a layout")
        // KNOWN LOSS: 10 mm is the `PageDescriptor()` (A4) default, NOT a value carried
        // from a source layout's page. When a future PLOTSETTINGS-write fix lands (the
        // writer emits the margin and the reader reads it back), FLIP this to assert the
        // ORIGINAL margin survives instead.
        #expect(layout.page.marginMM == 10,
                "margin unexpectedly differs from the A4 default — a PLOTSETTINGS write/read path may have landed; update this regression-documenting assertion")
        // The page width/height likewise fall back to the A4 default (210 × 297 mm)
        // since no paper size is written either.
        #expect(layout.page.widthMM == 210)
        #expect(layout.page.heightMM == 297)
    }

    // MARK: - 4) DWG parity — geometry round-trips; the paper-space tag is the
    //            documented libdxfrw DWG-WRITER gap (regression-documenting).

    @Test("DWG preserves the geometry but NOT the paper-space tag (libdxfrw dwgWriter15 gap)")
    func code67IsLostThroughDWG() async throws {
        let path = tempPath(ext: "dwg")
        defer { removeFile(path) }

        // The geometry still writes (both lines are supported kinds) — nothing skipped.
        let result = try await CADEngine.shared.writeEntities(
            [paperLine(), modelLine()], layers: layer0(), toDWGPath: path)
        #expect(result.skipped == 0)
        #expect(result.written == 2)
        #expect(FileManager.default.fileExists(atPath: path))
        // The on-disk file is a real binary R2000 DWG ("AC1015" at byte 0).
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(String(decoding: bytes.prefix(6), as: UTF8.self) == "AC1015")

        let back = try await CADEngine.shared.readEntities(dwgPath: path)
        // BOTH lines come back as GEOMETRY (the supported DWG scope) — neither is lost.
        // (`splitLines` buckets by END-POINT geometry, not by space, so it confirms the
        // shapes survived regardless of how their space tag round-tripped.)
        let (model, paper) = splitLines(back.records)
        #expect(model.count + paper.count == 2,
                "a DWG round-trip lost one of the two line geometries")

        // KNOWN LOSS: libdxfrw's DWG writer (`dwgWriter15`) does NOT author a
        // `*Paper_Space` block / DXF code 67, so EVERY record reads back as MODEL space —
        // the paper line keeps its (50,0) geometry but its `.paper` tag is dropped. This
        // is the same honest, pre-existing DWG-writer gap pinned by `SaveRoundTripTests`
        // (custom layers / dim-style tables / block members are likewise DWG-only losses).
        // Full paper-space fidelity round-trips on DXF (tests 1–2 above). When a future
        // libdxfrw upgrade adds DWG paper-space write, FLIP this to assert the paper line
        // returns `.paper` (and re-enable the single-layout DWG assertion below).
        #expect(back.records.allSatisfy { $0.space == .model },
                "DWG unexpectedly preserved a paper-space tag — libdxfrw gained DWG paper-space write; promote the DXF paper-space asserts to DWG too")
        #expect(!back.records.contains { $0.space == .paper },
                "no DWG-read record should be paper space until libdxfrw writes DWG paper space")
    }

    @Test("DWG reconstructs NO layout even with paper content (dwgWriter15 paper-space gap); model-only is unaffected")
    func noLayoutReconstructedThroughDWG() async throws {
        // (a) WITH paper content: because the DWG writer drops paper space (above), the
        // re-read file has no `*Paper_Space` block, so NO layout reconstructs. (On DXF
        // the same content reconstructs "Layout1" — see `singleLayoutReconstructionDXF`.)
        let withPaper = tempPath(ext: "dwg")
        defer { removeFile(withPaper) }
        _ = try await CADEngine.shared.writeEntities(
            [paperLine(), modelLine()], layers: layer0(), toDWGPath: withPaper)
        let pRes = try await CADEngine.shared.readEntities(dwgPath: withPaper)
        // KNOWN LOSS (paired with the test above): no DWG paper-space ⇒ no layout.
        #expect(pRes.layouts.isEmpty,
                "DWG unexpectedly reconstructed a layout — libdxfrw gained DWG paper-space write; promote the DXF single-layout assert to DWG too")

        // (b) Model-ONLY → no layouts (the model-space common case is unaffected by DWG).
        let modelOnly = tempPath(ext: "dwg")
        defer { removeFile(modelOnly) }
        _ = try await CADEngine.shared.writeEntities(
            [modelLine()], layers: layer0(), toDWGPath: modelOnly)
        let mRes = try await CADEngine.shared.readEntities(dwgPath: modelOnly)
        #expect(mRes.layouts.isEmpty)
        #expect(mRes.records.allSatisfy { $0.space == .model })
    }
}
