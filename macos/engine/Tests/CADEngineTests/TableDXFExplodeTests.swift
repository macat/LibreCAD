//
//  TableDXFExplodeTests.swift
//  CADEngineTests
//
//  The TABLES persistence / DXF wave: tables survive a SAVE by EXPLODING to loose
//  LINE + TEXT geometry in the written DXF (libdxfrw drops the real ACAD_TABLE on
//  READ — a confirmed dead-end — and a `TableObject` is ADDITIVE document state, not
//  an `EntityKind`, so there is nothing to author as a table entity), AND ride the
//  in-session document payload (`DXFPayload.tables`) so undo / autosave-via-payload
//  keep the EDITABLE model within a session.
//
//  These tests pin three things:
//    1. The pure explode (`DXFTableExploder.explode`) — exact LINE / TEXT counts and
//       positions for a known grid (the grid → 2-point LINEs, cells → placed TEXT).
//    2. The REAL production codec round-trip (`DXFDocumentCodec.data` → `.payload`):
//       a drawing with a `TableObject` writes through the real DXF codec and reopens
//       with the exploded grid LINEs + cell TEXT present (asserted by count/position)
//       — AND with ZERO tables (the documented caveat: a pure-DXF reopen loses the
//       re-editable table; it comes back as loose lines + text).
//    3. The in-session payload threading: `DXFPayload.tables` survives a snapshot ↔
//       live-`CADDrawing` round-trip (`make(from:)` / `payloadSnapshot`), so the
//       editable model is preserved through the document payload (undo / autosave).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Table DXF explode + payload persistence")
struct TableDXFExplodeTests {

    // MARK: - Fixtures

    /// A filled 2×2 table at a known top-left corner with uniform 10×20 cells, all four
    /// cells carrying distinct text. Borders visible (the default style). Used as the
    /// canonical explode fixture: predictable grid + 4 cell texts.
    private func twoByTwoTable(
        position: Vector = Vector(100, 200),
        colWidth: Double = 10,
        rowHeight: Double = 20
    ) -> TableObject {
        let cells: [[TableCell]] = [
            [TableCell(text: "A1"), TableCell(text: "B1")],
            [TableCell(text: "A2"), TableCell(text: "B2")],
        ]
        return TableObject(
            position: position,
            rows: 2, cols: 2,
            rowHeights: [rowHeight, rowHeight],
            colWidths: [colWidth, colWidth],
            cells: cells)
    }

    /// Count the LINE / TEXT records in an exploded set.
    private func counts(_ records: [EntityRecord]) -> (lines: Int, texts: Int) {
        var lines = 0, texts = 0
        for r in records {
            switch r.kind {
            case .line:  lines += 1
            case .text:  texts += 1
            default:     break
            }
        }
        return (lines, texts)
    }

    // MARK: - 1. Pure explode

    @Test("a filled 2×2 table explodes to its grid LINEs + one TEXT per cell")
    func explodeCountsAndKinds() {
        let table = twoByTwoTable()
        let records = DXFTableExploder.explode([table], startingRawID: 1000)

        // Grid: 4 outer-border edges + interior VERTICALs (1 boundary × 2 rows = 2)
        // + interior HORIZONTALs (1 boundary × 2 cols = 2) = 8 LINEs.
        // Cells: 4 non-empty cells = 4 TEXTs.
        let (lines, texts) = counts(records)
        #expect(lines == 8, "expected 8 grid LINE records, got \(lines)")
        #expect(texts == 4, "expected 4 cell TEXT records, got \(texts)")
        // Every emitted record is a LINE or TEXT (no other kind sneaks in).
        #expect(records.count == lines + texts)
    }

    @Test("exploded records carry unique ids starting at the supplied base")
    func explodeMintsUniqueIDs() {
        let table = twoByTwoTable()
        let records = DXFTableExploder.explode([table], startingRawID: 5000)
        let ids = Set(records.map(\.id.rawValue))
        #expect(ids.count == records.count, "exploded record ids collided")
        #expect(ids.min() == 5000, "minting did not start at the supplied base id")
    }

    @Test("exploded LINEs reproduce the table's outer border corners")
    func explodeBorderGeometry() {
        // Table top-left at (100,200), 2 cols × 10 wide, 2 rows × 20 tall.
        // Outer rect: left=100, right=120, top=200, bottom=200-40=160.
        let table = twoByTwoTable(position: Vector(100, 200), colWidth: 10, rowHeight: 20)
        let records = DXFTableExploder.explode([table], startingRawID: 1)

        let lineEndpoints: [(Vector, Vector)] = records.compactMap { rec in
            if case .line(let d) = rec.kind { return (d.start, d.end) }
            return nil
        }
        // Helper: does ANY emitted segment connect these two points (either direction)?
        func hasSegment(_ a: Vector, _ b: Vector) -> Bool {
            lineEndpoints.contains { (s, e) in
                (close(s, a) && close(e, b)) || (close(s, b) && close(e, a))
            }
        }
        // The four outer-border edges must all be present.
        #expect(hasSegment(Vector(100, 200), Vector(120, 200)), "top edge missing")
        #expect(hasSegment(Vector(120, 200), Vector(120, 160)), "right edge missing")
        #expect(hasSegment(Vector(120, 160), Vector(100, 160)), "bottom edge missing")
        #expect(hasSegment(Vector(100, 160), Vector(100, 200)), "left edge missing")
    }

    @Test("exploded TEXT carries the cell text + a finite anchor inside the table")
    func explodeCellTextGeometry() {
        let table = twoByTwoTable(position: Vector(100, 200), colWidth: 10, rowHeight: 20)
        let records = DXFTableExploder.explode([table], startingRawID: 1)

        let texts: [TextData] = records.compactMap { rec in
            if case .text(let d) = rec.kind { return d }
            return nil
        }
        #expect(texts.count == 4)
        // Every cell's text string is present exactly once.
        let strings = Set(texts.map(\.text))
        #expect(strings == ["A1", "B1", "A2", "B2"])
        // Every anchor sits within the table's outer rectangle (x in [100,120],
        // y in [160,200]) and has a positive cap height.
        for t in texts {
            #expect(t.position.x >= 100 - 1e-6 && t.position.x <= 120 + 1e-6)
            #expect(t.position.y >= 160 - 1e-6 && t.position.y <= 200 + 1e-6)
            #expect(t.height > 0)
        }
    }

    @Test("a degenerate (0-row) table explodes to nothing")
    func explodeDegenerateTableIsEmpty() {
        let empty = TableObject(position: Vector(0, 0), rows: 0, cols: 0)
        #expect(DXFTableExploder.explode([empty], startingRawID: 1).isEmpty)
    }

    @Test("an empty tables list explodes to nothing")
    func explodeEmptyListIsEmpty() {
        #expect(DXFTableExploder.explode([], startingRawID: 1).isEmpty)
    }

    @Test("a borders-hidden table explodes to cell TEXT only (no grid LINEs)")
    func explodeBordersHiddenIsTextOnly() {
        var table = twoByTwoTable()
        table.style.bordersVisible = false
        let records = DXFTableExploder.explode([table], startingRawID: 1)
        let (lines, texts) = counts(records)
        #expect(lines == 0, "borders hidden, yet \(lines) grid LINEs were emitted")
        #expect(texts == 4)
    }

    // MARK: - 2. Real codec round-trip (the production save path)

    @Test("a TableObject SAVED through the real DXF codec reopens as exploded LINEs + TEXT, with ZERO tables")
    func tableExplodesThroughRealCodecAndLosesEditableModelOnReopen() throws {
        let table = twoByTwoTable(position: Vector(100, 200), colWidth: 10, rowHeight: 20)
        // A drawing payload that carries ONLY the table (no loose entities), so every
        // LINE/TEXT in the reopened file provably came from the explode.
        let payload = DXFPayload(
            entities: [],
            layers: LayerTable(layers: [Layer(name: "0")], activeLayerName: "0"),
            tables: [table])

        // The REAL production save path the app's `fileWrapper(snapshot:)` calls:
        // payload → DXF bytes → payload.
        let data = try DXFDocumentCodec.data(from: payload, format: .dxf)
        let back = try DXFDocumentCodec.payload(from: data, format: .dxf)

        // --- The exploded geometry survives to disk + reopens ----------------
        let (lines, texts) = counts(back.entities)
        // 8 grid LINEs (4 border + 2 vertical + 2 horizontal) + 4 cell TEXTs.
        #expect(lines == 8, "expected 8 exploded grid LINEs on reopen, got \(lines)")
        #expect(texts == 4, "expected 4 exploded cell TEXTs on reopen, got \(texts)")

        // The reopened cell text strings match (so the cells' content is on disk).
        let strings = Set(back.entities.compactMap { rec -> String? in
            if case .text(let d) = rec.kind { return d.text }
            return nil
        })
        #expect(strings == ["A1", "B1", "A2", "B2"],
                "the cell text was not written/read as exploded TEXT")

        // --- The DOCUMENTED CAVEAT: the editable table model is LOST on reopen
        //     A pure-DXF reopen has NO table source (libdxfrw drops ACAD_TABLE), so the
        //     reopened payload carries 0 tables — the table came back as loose lines+text.
        #expect(back.tables.isEmpty,
                "a pure-DXF reopen must NOT reconstruct a re-editable TableObject (it returns exploded geometry only) — caveat regression")
    }

    @Test("a table-free DXF save still reopens with zero tables (additive: no regression)")
    func tableFreeSaveIsUnaffected() throws {
        let line = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 5))))
        let payload = DXFPayload(
            entities: [line],
            layers: LayerTable(layers: [Layer(name: "0")], activeLayerName: "0"))

        let data = try DXFDocumentCodec.data(from: payload, format: .dxf)
        let back = try DXFDocumentCodec.payload(from: data, format: .dxf)

        // The one loose line round-trips; no phantom table geometry appears.
        let (lines, _) = counts(back.entities)
        #expect(lines == 1, "a table-free save emitted unexpected LINEs (\(lines))")
        #expect(back.tables.isEmpty)
    }

    // MARK: - 3. In-session payload threading (undo / autosave keep the editable model)

    @Test("DXFPayload threads tables through the live-drawing snapshot round-trip")
    @MainActor
    func payloadThreadsTablesThroughLiveDrawing() {
        let table = twoByTwoTable()
        let payload = DXFPayload(tables: [table])

        // payload → live @MainActor CADDrawing → payload snapshot. This is the in-session
        // path undo / autosave-via-payload uses; the editable table must survive verbatim.
        let drawing = CADDrawing.make(from: payload)
        #expect(drawing.tables.count == 1, "make(from:) dropped the table")
        let restored = drawing.tables.first
        #expect(restored?.id == table.id)
        #expect(restored?.rows == 2 && restored?.cols == 2)
        #expect(restored?.cell(row: 0, col: 0)?.text == "A1")

        // Snapshot back out (the document's `payloadSnapshot`).
        let snapshot = drawing.payloadSnapshot
        #expect(snapshot.tables == [table],
                "payloadSnapshot did not carry the live drawing's tables verbatim")
    }

    @Test("an absent tables key decodes to an empty list (additive back-compat)")
    func payloadDefaultsTablesEmpty() {
        // A payload built WITHOUT tables (the historical / table-free case) carries none.
        let payload = DXFPayload(entities: [])
        #expect(payload.tables.isEmpty)
    }

    // MARK: - Helpers

    /// Whether two world points coincide within a tight tolerance.
    private func close(_ a: Vector, _ b: Vector, tol: Double = 1e-6) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }
}
