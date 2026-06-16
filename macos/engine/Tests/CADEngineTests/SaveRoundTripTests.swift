//
//  SaveRoundTripTests.swift
//  CADEngineTests
//
//  SAVE-fidelity round-trip regression for the DXF/DWG write path. The acceptance
//  pass flagged (`macos/docs/dwg-render-diagnosis.md:40`) that the SAVE path might
//  drop BLOCKS + graphicVariables (writing only entities + layers), which — if true
//  — would break a save→reopen round-trip: INSERTs would lose their geometry and
//  header vars like $DIMTXT would regress to engine defaults (the SAVE-side twin of
//  the old dim-text read bug).
//
//  These tests serialize a payload through the EXACT production save path the app
//  uses (`DXFDocumentCodec.data(from:)` → `CADEngine.writeEntities` → the DxfBridge
//  C ABI), re-read it through the production read path (`DXFDocumentCodec.payload`),
//  and assert the full save matrix survives:
//    (a) a named BLOCK + an actual INSERT of it (definition + reference + the block's
//        MEMBER geometry),
//    (b) non-default graphic variables ($INSUNITS / $DIMTXT) + a named DIMSTYLE,
//    (c) plain entities + a non-default LAYER.
//  DXF (R2000) is covered as the primary, full-fidelity format (everything above
//  round-trips). A DWG variant pins the honest, pre-existing libdxfrw DWG-writer
//  scope: top-level geometry round-trips, but custom LAYERS, the named DIMSTYLE
//  table, and a block's MEMBER geometry do NOT (dwgWriter15 emits only the standard
//  R2000 tables + empty user blocks). Those DWG gaps are documented in lcdxf.h and
//  are NOT regressions of the save path — they are libdxfrw limitations.
//
//  RESULT: STEP-1 verification proved the DXF SAVE path ALREADY round-trips blocks +
//  graphicVariables + dim styles correctly, so the dwg-render-diagnosis.md:40 note
//  ("the write path drops blocks + graphicVariables") is STALE. This suite is kept
//  as the regression guard.
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

@Suite("Save round-trip fidelity (blocks + INSERT + graphic vars + dim styles)")
struct SaveRoundTripTests {

    // MARK: - Fixture: the full save matrix as a payload

    /// Builds a `DXFPayload` carrying every field the save path must preserve:
    ///  - a named BLOCK "WIDGET" with one member LINE + an actual INSERT of it,
    ///  - non-default header graphic vars ($INSUNITS=inch, $DIMTXT=0.125, $DIMEXO),
    ///  - a named DIMSTYLE table ("Standard" active + a distinct "BIG" style),
    ///  - two plain entities (a line + a circle) on a non-default layer "WALLS".
    private func makeFullPayload() -> DXFPayload {
        // (c) A non-default layer, distinct from the default "0" (a custom color +
        // an explicit lineweight + the locked flag — all non-default attributes).
        var layers = LayerTable()
        let walls = Layer(name: "WALLS",
                          color: RGBAColor(0.9, 0.1, 0.1),
                          lineType: .dashed,
                          lineWidth: .millimeters(0.5),
                          isLocked: true)
        layers.upsert(walls)

        // (a) A block member line (lives in `entities`; the block references it by id)
        // plus two plain top-level entities on the non-default layer.
        let blockMember = EntityRecord(
            id: EntityID(100),
            kind: .line(LineData(start: .init(0, 0), end: .init(3, 4))))
        let plainLine = EntityRecord(
            id: EntityID(1),
            layer: LayerID("WALLS"),
            kind: .line(LineData(start: .init(-1, -1), end: .init(5, 5))))
        let plainCircle = EntityRecord(
            id: EntityID(2),
            layer: LayerID("WALLS"),
            kind: .circle(CircleData(center: .init(2, 2), radius: 1.5)))
        // (a) An actual INSERT entity referencing the block by name, with a
        // non-trivial insertion point + scale + rotation so they round-trip too.
        let insert = EntityRecord(
            id: EntityID(3),
            kind: .insert(InsertData(
                blockName: "WIDGET",
                insertionPoint: .init(10, 20),
                scale: .init(2, 2),
                rotation: .pi / 4)))

        var blocks = BlockTable()
        _ = blocks.add(Block(name: "WIDGET",
                             basePoint: .init(0, 0),
                             entityIDs: [blockMember.id]))

        // (b) Non-default header graphic variables: inch units + a real-file $DIMTXT
        // (0.125), NOT the engine default (2.5). The ext-line offset rides the active
        // style.
        var gv = GraphicVariables()
        gv.unit = .inch
        gv.dimTextHeight = 0.125
        gv.dimArrowSize = 0.125
        gv.dimExtensionOffset = 0.0625

        // (b) R4b: the 7 STANDARD document-settings header vars — each set to a
        // NON-default value so a silent drop on a .dxf write is detectable. These ride
        // the generic extra-var bag through the bridge. $GRIDUNIT and $PINSBASE are
        // COORD-typed (must round-trip as a vector, not just a scalar X).
        gv.gridOn = false                          // $GRIDMODE (default true)
        gv.gridSpacing = 7.5                        // $GRIDUNIT (COORD; default 1)
        gv.pointDisplayMode = .cross               // $PDMODE   (default 0/dot)
        gv.pointSize = 3.25                         // $PDSIZE   (default 0)
        gv.anglesBase = 1.5                         // $ANGBASE  (radians; default 0)
        gv.anglesCounterClockwise = false          // $ANGDIR=1 (default 0/CCW)
        gv.paperInsertionBase = Vector(11, 22)     // $PINSBASE (COORD; default 0,0)

        // (b) A named DIMSTYLE table: "Standard" (active) + a distinct "BIG" style.
        var table = DimStyleTable(activeName: "Standard")
        table.upsert(NamedDimStyle(
            name: "Standard",
            style: ResolvedDimStyle(textHeight: 0.125, arrowSize: 0.125, scale: 1,
                                    linearFormat: .decimal, linearPrecision: 3,
                                    extensionOffset: 0.0625, extensionBeyond: 0.18,
                                    textGap: 0.09)))
        table.upsert(NamedDimStyle(
            name: "BIG",
            style: ResolvedDimStyle(textHeight: 0.5, arrowSize: 0.5, scale: 1,
                                    linearFormat: .decimal, linearPrecision: 2,
                                    extensionOffset: 0.25, extensionBeyond: 0.5,
                                    textGap: 0.2)))

        return DXFPayload(
            entities: [plainLine, plainCircle, insert, blockMember],
            layers: layers,
            blocks: blocks,
            graphicVariables: gv,
            dimStyles: table)
    }

    /// The member LINE inside the block that survived (resolved via the block's
    /// member id list, NOT just any line in the entity store).
    private func blockMemberLine(in back: DXFPayload, block name: String) -> LineData? {
        guard let block = back.blocks.block(named: name) else { return nil }
        let byID = Dictionary(back.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in block.entityIDs {
            if case .line(let d)? = byID[id]?.kind { return d }
        }
        return nil
    }

    // MARK: - DXF R2000 (primary, full-fidelity format)

    @Test("DXF save→reopen preserves blocks + INSERT + graphic vars + dim styles + layers")
    func dxfFullMatrixRoundTrips() throws {
        let payload = makeFullPayload()

        // The REAL production save path the app's `fileWrapper(snapshot:)` calls:
        // payload → DXF bytes → payload. Default format is .dxf (R2000 in the writer).
        let data = try DXFDocumentCodec.data(from: payload, format: .dxf)
        let back = try DXFDocumentCodec.payload(from: data, format: .dxf)

        // --- (a) BLOCK definition survives -----------------------------------
        #expect(back.blocks.contains("WIDGET"),
                "the BLOCK definition was dropped on save (data(from:) wrote no BLOCKS section)")

        // --- (a) The block's MEMBER geometry survives ------------------------
        let member = try #require(blockMemberLine(in: back, block: "WIDGET"),
                                  "the block's member LINE geometry was dropped on save")
        #expect(abs(member.start.x - 0) < 1e-6)
        #expect(abs(member.start.y - 0) < 1e-6)
        #expect(abs(member.end.x - 3) < 1e-6)
        #expect(abs(member.end.y - 4) < 1e-6)

        // --- (a) The INSERT entity survives + still names the block ----------
        let insert = try #require(back.entities.compactMap { rec -> InsertData? in
            if case .insert(let d) = rec.kind { return d }
            return nil
        }.first, "the INSERT entity was dropped on save")
        #expect(insert.blockName == "WIDGET")
        #expect(abs(insert.insertionPoint.x - 10) < 1e-6)
        #expect(abs(insert.insertionPoint.y - 20) < 1e-6)
        #expect(abs(insert.scale.x - 2) < 1e-6)
        #expect(abs(insert.rotation - .pi / 4) < 1e-6)

        // --- (b) The non-default graphic variable survives ($DIMTXT not reset) -
        #expect(back.graphicVariables.unit == .inch,
                "$INSUNITS regressed to the default on save")
        #expect(abs(back.graphicVariables.dimTextHeight - 0.125) < 1e-6,
                "$DIMTXT regressed to the engine default on save")
        #expect(back.graphicVariables.dimTextHeight != 2.5,
                "$DIMTXT fell back to the 2.5 engine default — the save dropped the header var")

        // --- (b) R4b: the 7 STANDARD document-settings header vars survive ---------
        // These ride the generic extra-var bag (lcdxf.h LCHeaderVar). Before R4b the
        // bridge carried header vars only through the fixed POD whitelist, so every
        // one of these silently dropped on .dxf write AND read — these asserts are the
        // fail-before/pass-after gate. (The libdxfrw-curated standard targets emit for
        // free once they ride in DRW_Header.vars; see DXFWriter.makeHeaderVars.)
        let rgv = back.graphicVariables
        #expect(rgv.gridOn == false,
                "$GRIDMODE was dropped on .dxf save→reopen (generic header-var bag)")
        #expect(rgv.pointDisplayMode.rawMode == PointDisplayMode.cross.rawMode,
                "$PDMODE was dropped on .dxf save→reopen")
        #expect(abs(rgv.pointSize - 3.25) < 1e-6,
                "$PDSIZE was dropped on .dxf save→reopen")
        #expect(abs(rgv.anglesBase - 1.5) < 1e-6,
                "$ANGBASE was dropped on .dxf save→reopen")
        #expect(rgv.anglesCounterClockwise == false,
                "$ANGDIR was dropped on .dxf save→reopen")
        // The two COORD-typed vars must round-trip as VECTORS (preserving X and Y),
        // not collapse to a scalar — int/double-only handling would corrupt them.
        #expect(abs(rgv.gridSpacing - 7.5) < 1e-6,
                "$GRIDUNIT (COORD) was dropped or scalar-corrupted on .dxf save→reopen")
        #expect(rgv.has("$GRIDUNIT") && rgv.vector("$GRIDUNIT").x == 7.5,
                "$GRIDUNIT did not round-trip as a vector")
        let pinsBase = rgv.paperInsertionBase
        #expect(abs(pinsBase.x - 11) < 1e-6 && abs(pinsBase.y - 22) < 1e-6,
                "$PINSBASE (COORD) lost its vector (x,y) on .dxf save→reopen")

        // --- (b) The named DIMSTYLE table survives ---------------------------
        let std = try #require(back.dimStyles.style(named: "Standard"),
                               "the active 'Standard' dim style was dropped on save")
        #expect(abs(std.style.textHeight - 0.125) < 1e-6)
        #expect(abs(std.style.extensionBeyond - 0.18) < 1e-6)
        let big = try #require(back.dimStyles.style(named: "BIG"),
                               "the named 'BIG' dim style was dropped on save")
        #expect(abs(big.style.textHeight - 0.5) < 1e-6)
        #expect(abs(big.style.extensionOffset - 0.25) < 1e-6)

        // --- (c) Plain entities + the non-default LAYER survive --------------
        let wallsLayer = try #require(back.layers.layer(named: "WALLS"),
                                      "the non-default 'WALLS' layer was dropped on save")
        // The layer's non-default attributes round-trip (color + lock flag).
        #expect(wallsLayer.isLocked, "the 'WALLS' layer's locked flag was dropped on save")
        // The plain top-level LINE survives on its WALLS layer (matched by geometry,
        // so we don't confuse it with the block member line, which — per ADR-001 —
        // is BOTH a top-level entity AND a block member, so it round-trips twice:
        // once in the ENTITIES section and once inside the BLOCK definition).
        let plainLineBack = try #require(back.entities.first { rec -> Bool in
            if case .line(let d) = rec.kind {
                return abs(d.start.x - -1) < 1e-6 && abs(d.end.x - 5) < 1e-6
            }
            return false
        }, "the plain top-level LINE was dropped on save")
        #expect(plainLineBack.layer.name == "WALLS",
                "the plain LINE lost its non-default layer assignment on save")
        let hasCircle = back.entities.contains {
            if case .circle = $0.kind { return true }; return false
        }
        #expect(hasCircle, "the plain CIRCLE entity was dropped on save")
    }

    // MARK: - DWG (R2000) — entities/layers/header round-trip; block-member gap noted

    @Test("DWG save→reopen preserves top-level entities (custom layers / blocks / dim-style tables are the documented libdxfrw DWG gap)")
    func dwgRoundTripsTopLevelEntitiesAndNotesTableGap() throws {
        let payload = makeFullPayload()

        // The same production codec, routed to the DWG bridge path (binary R2000).
        let data = try DXFDocumentCodec.data(from: payload, format: .dwg)
        let back = try DXFDocumentCodec.payload(from: data, format: .dwg)

        // Top-level geometry DOES round-trip on DWG (the supported scope).
        let hasCircle = back.entities.contains {
            if case .circle = $0.kind { return true }; return false
        }
        #expect(hasCircle, "the plain CIRCLE entity was dropped on DWG save")
        let hasPlainLine = back.entities.contains { rec -> Bool in
            if case .line(let d) = rec.kind {
                return abs(d.start.x - -1) < 1e-6 && abs(d.end.x - 5) < 1e-6
            }
            return false
        }
        #expect(hasPlainLine, "the plain top-level LINE was dropped on DWG save")

        // The DWG reader always delivers the standard layer "0" (libdxfrw default).
        #expect(back.layers.contains("0"))

        // KNOWN DWG LIMITATIONS (libdxfrw's dwgWriter15 — documented in lcdxf.h and
        // LibreCADDocument.writableContentTypes; also covered by the existing
        // DWGReadWriteTests, which only assert layer "0"):
        //  - writeLayers is a no-op on DWG (dwgWriter15 emits ONLY the standard R2000
        //    LAYER table), so a CUSTOM layer like "WALLS" is NOT written.
        //  - writeDimstyles is a no-op on DWG (only the standard DIMSTYLE table), so a
        //    named style table does NOT round-trip.
        //  - defineBlock writes EMPTY user blocks (no member-geometry path), so a
        //    block's MEMBER geometry is NOT written.
        // These are NOT regressions of the save fix — they are the honest, pre-existing
        // libdxfrw DWG-writer scope. We pin that scope here so a future libdxfrw upgrade
        // that adds DWG table/block writing is noticed (these would then flip to asserts).
        // Full-fidelity blocks / graphic vars / dim styles round-trip on DXF (above).
        #expect(back.layers.layer(named: "WALLS") == nil,
                "DWG unexpectedly wrote a custom layer — libdxfrw gained DWG LAYER-table write; promote the DXF-only layer/block/dim-style asserts to DWG too")

        //  - R4b generic header vars are ALSO a DWG gap: libdxfrw's dwgWriter15 emits
        //    its own DEFAULT header and does NOT honor the DRW_Header.vars we add, so
        //    the document-settings vars ($GRIDMODE/$GRIDUNIT/$PDMODE/$PDSIZE/$ANGBASE/
        //    $ANGDIR/$PINSBASE) come back at their defaults on a DWG round-trip (they
        //    DO round-trip on DXF — the primary full-fidelity format). Pinned here so a
        //    future libdxfrw DWG header-write upgrade is noticed. The non-default values
        //    we set in makeFullPayload regress to the engine/file defaults on DWG:
        #expect(back.graphicVariables.gridOn == true,
                "DWG unexpectedly preserved $GRIDMODE — libdxfrw gained DWG header-var write; promote the DXF-only R4b header-var asserts to DWG too")
        #expect(back.graphicVariables.pointDisplayMode.rawMode == 0,
                "DWG unexpectedly preserved $PDMODE — libdxfrw gained DWG header-var write; promote the DXF-only R4b header-var asserts to DWG too")
    }
}
