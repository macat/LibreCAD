//
//  DimStyleRoundTripTests.swift
//  CADEngineTests
//
//  DXF round-trip + document-save-codec tests for the named DIMSTYLE table writer
//  (w1-dimstyle): a drawing carrying a named DIMSTYLE + DIMEXO/DIMEXE/DIMGAP header
//  vars WRITES through the engine writer, RE-READS preserving the style values +
//  ext offsets, and a dimension then RESOLVES with the style's text height + the
//  ext-line offsets applied. Also exercises the `LibreCADDocument` save codec
//  (`DXFDocumentCodec.data → payload`) to prove Save preserves units / dim styles /
//  blocks (the write-side twin of the read drop fixed earlier).
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

@Suite("DIMSTYLE writer round-trip (w1-dimstyle)")
struct DimStyleRoundTripTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dimstyle-rt-\(UUID().uuidString).dxf").path
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Builds a layer table with just the default "0".
    private func layers0() -> LayerTable { LayerTable() }

    @Test("a named DIMSTYLE + DIMEXO/DIMEXE/DIMGAP write → re-read preserving the values")
    func namedStyleAndExtOffsetsRoundTrip() async throws {
        let out = tempDXFPath()
        defer { removeFile(out) }

        // Header dim vars (the document default) carrying the ext-line offsets.
        var gv = GraphicVariables()
        gv.unit = .inch
        gv.dimTextHeight = 0.125
        gv.dimArrowSize = 0.125
        gv.dimExtensionOffset = 0.0625   // $DIMEXO
        gv.dimExtensionBeyond = 0.18     // $DIMEXE
        gv.dimTextGap = 0.09             // $DIMGAP

        // A named DIMSTYLE table: "Standard" (active) at 0.125 + a "BIG" style.
        var table = DimStyleTable(activeName: "Standard")
        table.upsert(NamedDimStyle(name: "Standard",
                                   style: ResolvedDimStyle(textHeight: 0.125, arrowSize: 0.125,
                                                           scale: 1, linearFormat: .decimal,
                                                           linearPrecision: 3,
                                                           extensionOffset: 0.0625,
                                                           extensionBeyond: 0.18, textGap: 0.09)))
        table.upsert(NamedDimStyle(name: "BIG",
                                   style: ResolvedDimStyle(textHeight: 0.5, arrowSize: 0.5,
                                                           scale: 1, linearFormat: .decimal,
                                                           linearPrecision: 2,
                                                           extensionOffset: 0.25,
                                                           extensionBeyond: 0.5, textGap: 0.2)))

        // One linear dimension referencing the "BIG" style (no per-entity height).
        let dim = EntityRecord(
            id: EntityID(1),
            kind: .dimension(DimData(
                kind: .linear(extension1: .init(0, 0), extension2: .init(2, 0), angle: 0),
                definitionPoint: .init(1, 1),
                styleName: "BIG",
                textHeight: 0, arrowSize: 0)))

        // WRITE through the engine writer (header + DIMSTYLE table flow to the bridge).
        _ = try await CADEngine.shared.writeEntities(
            [dim], layers: layers0(),
            graphicVariables: gv, dimStyles: table, toPath: out)
        #expect(FileManager.default.fileExists(atPath: out))

        // RE-READ the named DIMSTYLE table.
        let readBack = try await CADEngine.shared.readDimStyles(path: out)
        // Both named styles survived.
        let std = try #require(readBack.style(named: "Standard"))
        let big = try #require(readBack.style(named: "BIG"))
        #expect(abs(std.style.textHeight - 0.125) < 1e-6)
        #expect(abs(std.style.extensionOffset - 0.0625) < 1e-6)
        #expect(abs(std.style.extensionBeyond - 0.18) < 1e-6)
        #expect(abs(std.style.textGap - 0.09) < 1e-6)
        #expect(abs(big.style.textHeight - 0.5) < 1e-6)
        #expect(abs(big.style.extensionOffset - 0.25) < 1e-6)
        #expect(abs(big.style.extensionBeyond - 0.5) < 1e-6)
        #expect(abs(big.style.textGap - 0.2) < 1e-6)

        // The header dim vars also round-tripped (the active document default). The
        // engine reader maps the unit + $DIMTXT into graphicVariables; the ext-line
        // offsets are carried on the active DIMSTYLE (the engine reader's header→var
        // mapping doesn't surface $DIMEXO/$DIMEXE/$DIMGAP — the document codec
        // backfills them from the active style). So assert the ext offsets via the
        // active style and the unit/$DIMTXT via the header.
        let result = try await CADEngine.shared.readEntities(dxfPath: out)
        #expect(result.graphicVariables.unit == .inch)
        #expect(abs(result.graphicVariables.dimTextHeight - 0.125) < 1e-6)
        let active = try #require(readBack.active())
        #expect(abs(active.style.extensionOffset - 0.0625) < 1e-6)
        #expect(abs(active.style.extensionBeyond - 0.18) < 1e-6)
        #expect(abs(active.style.textGap - 0.09) < 1e-6)
    }

    @MainActor
    @Test("after round-trip a dim resolves at the named style's height + ext offsets")
    func dimResolvesWithStyleAfterRoundTrip() async throws {
        let out = tempDXFPath()
        defer { removeFile(out) }

        var gv = GraphicVariables()
        gv.unit = .inch
        gv.dimTextHeight = 0.125
        gv.dimArrowSize = 0.125

        var table = DimStyleTable(activeName: "Standard")
        table.upsert(NamedDimStyle(name: "Standard",
                                   style: ResolvedDimStyle(textHeight: 0.125, arrowSize: 0.125)))
        // The named style the dim references: a distinctive height + a large DIMEXO.
        table.upsert(NamedDimStyle(name: "TALL",
                                   style: ResolvedDimStyle(textHeight: 0.375, arrowSize: 0.375,
                                                           extensionOffset: 0.5,
                                                           extensionBeyond: 0.1, textGap: 0.05)))

        let dim = EntityRecord(
            id: EntityID(7),
            kind: .dimension(DimData(
                kind: .linear(extension1: .init(0, 0), extension2: .init(4, 0), angle: 0),
                definitionPoint: .init(2, 6),
                styleName: "TALL",
                textHeight: 0, arrowSize: 0)))

        _ = try await CADEngine.shared.writeEntities(
            [dim], layers: layers0(), graphicVariables: gv, dimStyles: table, toPath: out)

        // Rebuild a live drawing the way the document open path does: load entities +
        // header vars + the named DIMSTYLE table.
        let result = try await CADEngine.shared.readEntities(dxfPath: out)
        let readTable = try await CADEngine.shared.readDimStyles(path: out)
        let drawing = CADDrawing()
        drawing.load(entities: result.records, layers: result.layers,
                     blocks: result.blocks, graphicVariables: result.graphicVariables,
                     dimStyles: readTable)
        let ctx = drawing.makeResolveContext()

        let resolvedDim = try #require(drawing.entities.compactMap { rec -> DimData? in
            if case .dimension(let d) = rec.kind { return d }
            return nil
        }.first)
        #expect(resolvedDim.styleName?.caseInsensitiveCompare("TALL") == .orderedSame)
        // The dim resolves at the NAMED style's height (0.375), NOT the header 0.125
        // and NOT the engine 2.5 fallback.
        #expect(abs(EntityKind.dimTextHeight(resolvedDim, ctx: ctx) - 0.375) < 1e-6)
        #expect(EntityKind.dimTextHeight(resolvedDim, ctx: ctx) != 2.5)
        // And the named style's DIMEXO (0.5) drives the ext-line origin offset.
        #expect(abs(EntityKind.dimExtensionOffset(resolvedDim, ctx: ctx) - 0.5) < 1e-6)
        #expect(abs(EntityKind.dimExtensionBeyond(resolvedDim, ctx: ctx) - 0.1) < 1e-6)
    }

    // MARK: - Document save-codec round-trip (the write-codec fix)

    @Test("the document save codec preserves units + dim styles + blocks (write-codec fix)")
    func documentCodecPreservesHeaderBlocksAndStyles() throws {
        // A payload carrying header dim vars, a named DIMSTYLE table, AND a block —
        // exactly the state the old `data(from:)` dropped (it passed only entities +
        // layers). After data → payload it must all survive.
        var gv = GraphicVariables()
        gv.unit = .inch
        gv.dimTextHeight = 0.125          // the real-file value (not the 2.5 default)
        gv.dimExtensionOffset = 0.0625

        var table = DimStyleTable(activeName: "Standard")
        table.upsert(NamedDimStyle(name: "Standard",
                                   style: ResolvedDimStyle(textHeight: 0.125, arrowSize: 0.125,
                                                           extensionOffset: 0.0625,
                                                           extensionBeyond: 0.18, textGap: 0.09)))

        // A block + its one member line (referenced by INSERT-style id-refs).
        let member = EntityRecord(id: EntityID(10),
                                  kind: .line(LineData(start: .init(0, 0), end: .init(1, 1))))
        var blocks = BlockTable()
        _ = blocks.add(Block(name: "PART", basePoint: .init(0, 0), entityIDs: [member.id]))

        let payload = DXFPayload(entities: [member], layers: LayerTable(),
                                 blocks: blocks, graphicVariables: gv, dimStyles: table)

        // Save → reopen via the off-main document codec.
        let data = try DXFDocumentCodec.data(from: payload)
        let back = try DXFDocumentCodec.payload(from: data)

        // Units + dim defaults + ext offset survived (NOT reset to defaults).
        #expect(back.graphicVariables.unit == .inch)
        #expect(abs(back.graphicVariables.dimTextHeight - 0.125) < 1e-6)
        #expect(back.graphicVariables.dimTextHeight != 2.5)
        #expect(abs(back.graphicVariables.dimExtensionOffset - 0.0625) < 1e-6)
        // The named DIMSTYLE table survived.
        let std = try #require(back.dimStyles.style(named: "Standard"))
        #expect(abs(std.style.textHeight - 0.125) < 1e-6)
        #expect(abs(std.style.extensionBeyond - 0.18) < 1e-6)
        // The block definition survived (the BLOCKS section was written).
        #expect(back.blocks.contains("PART"))
    }
}
