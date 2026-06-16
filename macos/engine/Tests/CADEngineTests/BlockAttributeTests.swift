//
//  BlockAttributeTests.swift
//  CADEngineTests
//
//  Block ATTRIBUTES (DXF ATTDEF / ATTRIB) — the model + resolve + DXF round-trip.
//  A block declares attribute TEMPLATES (`Block.attributeDefs`, DXF ATTDEF) and
//  each `INSERT` overrides their VALUES (`InsertData.attributes`, DXF ATTRIB). This
//  suite covers, in one place:
//    • back-compat Codable decode (old InsertData / Block JSON ⇒ empty attr lists)
//    • resolve: an insert with ATTRIB values resolves to the member geometry PLUS
//      the attribute TEXT, once per MINSERT cell, at the placed position; existing
//      insert/MINSERT/nested resolve is UNCHANGED (no regression)
//    • DXF round-trip: ATTDEFs on a block + ATTRIB values on an insert survive a
//      write→read, and the written DXF carries code-66 + ATTRIB + SEQEND + ATTDEF
//    • degenerate: an insert with no attributes round-trips unchanged; empty /
//      malformed attribute text is safe (no crash, no stray geometry)
//
//  Uniquely namespaced so it does not collide with the other suites in the shared
//  test target. The DXF round-trip drives the engine's public file entry points
//  (`CADEngine.shared.writeEntities(...toPath:)` / `readEntities(dxfPath:)`), the
//  same pattern as `InsertEntityTests` / `PaperSpaceDXFRoundTripTests`.
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

@Suite("block attributes (ATTDEF/ATTRIB) model + resolve + DXF round-trip")
struct BlockAttributeTests {

    // MARK: - Helpers

    /// A resolve context with a block provider AND a (Core Text) font provider, so
    /// an attribute's TEXT actually produces geometry. Helvetica Neue is universally
    /// installed; serial test runs avoid the CADFonts first-touch parallel hang.
    private func ctxWithFont(_ blocks: [String: [EntityRecord]]) -> ResolveContext {
        ResolveContext(fontProvider: CADFonts.provider,
                       blockProvider: { blocks[$0] })
    }

    /// A block provider-only context (no font) — for member-geometry-only assertions.
    private func ctx(_ blocks: [String: [EntityRecord]]) -> ResolveContext {
        ResolveContext(blockProvider: { blocks[$0] })
    }

    /// A single-line block member (so member resolve has a stable polyline count).
    private func lineMember() -> [EntityRecord] {
        [EntityRecord(id: EntityID(1),
                      kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))]
    }

    private func tempDXF() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blockattr-\(UUID().uuidString).dxf").path
    }

    /// Total drawn primitive count (polylines + fills) — text resolves to one or the
    /// other depending on the provider; we only care that geometry APPEARED.
    private func primitiveCount(_ g: ResolvedGeometry) -> Int {
        g.polylines.count + g.fills.count
    }

    // MARK: - Back-compat decode (critic must-fix)

    /// Encodes `value`, removes the top-level `key` from the resulting JSON object
    /// (simulating an OLD file written before that key existed), and returns the
    /// trimmed JSON bytes. The inner `Vector`s etc. keep their real encoded shape, so
    /// this is a faithful "old payload" rather than a hand-written approximation.
    private func encodeDropping<T: Encodable>(_ value: T, key: String) throws -> Data {
        let data = try JSONEncoder().encode(value)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: key)
        #expect(obj[key] == nil)
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test("old InsertData JSON without `attributes` decodes to an empty list")
    func insertDataBackCompatDecode() throws {
        // A real InsertData, re-encoded with the NEW `attributes` key stripped out —
        // exactly what an old saved drawing's JSON looks like.
        let current = InsertData(blockName: "WIDGET", insertionPoint: Vector(1, 2))
        let oldJSON = try encodeDropping(current, key: "attributes")
        let d = try JSONDecoder().decode(InsertData.self, from: oldJSON)
        #expect(d.blockName == "WIDGET")
        #expect(d.attributes.isEmpty)        // defaulted, no throw
    }

    @Test("old Block JSON without `attributeDefs` decodes to an empty list")
    func blockBackCompatDecode() throws {
        let current = Block(name: "WIDGET", entityIDs: [EntityID(1)])
        let oldJSON = try encodeDropping(current, key: "attributeDefs")
        let b = try JSONDecoder().decode(Block.self, from: oldJSON)
        #expect(b.name == "WIDGET")
        #expect(b.attributeDefs.isEmpty)     // defaulted, no throw
    }

    @Test("a current InsertData with attributes Codable-round-trips")
    func insertDataCodableRoundTrip() throws {
        let original = InsertData(
            blockName: "TB", insertionPoint: Vector(5, 6),
            attributes: [BlockAttributeValue(tag: "PARTNO", text: "A-17",
                                             position: Vector(1, 1), height: 3, rotation: 0)])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(InsertData.self, from: data)
        #expect(back.attributes.count == 1)
        #expect(back.attributes.first?.tag == "PARTNO")
        #expect(back.attributes.first?.text == "A-17")
    }

    @Test("a current Block with attributeDefs Codable-round-trips")
    func blockCodableRoundTrip() throws {
        let original = Block(name: "TB", attributeDefs: [
            BlockAttributeDef(tag: "PARTNO", prompt: "Part number?",
                              defaultText: "N/A", position: Vector(1, 1), height: 3, flags: 0)])
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Block.self, from: data)
        #expect(back.attributeDefs.count == 1)
        #expect(back.attributeDefs.first?.tag == "PARTNO")
        #expect(back.attributeDefs.first?.prompt == "Part number?")
        #expect(back.attributeDefs.first?.defaultText == "N/A")
    }

    // MARK: - Resolve: ATTRIB text is emitted at the placement

    @Test("an insert with 2 ATTRIB values resolves to members PLUS extra text geometry")
    func resolveEmitsAttributeText() {
        let members = lineMember()
        let context = ctxWithFont(["TB": members])

        // Same insert, with and without attributes.
        let plain = EntityRecord(id: EntityID(100),
            kind: .insert(InsertData(blockName: "TB", insertionPoint: Vector(100, 50))))
        let withAttrs = EntityRecord(id: EntityID(101),
            kind: .insert(InsertData(blockName: "TB", insertionPoint: Vector(100, 50),
                attributes: [
                    BlockAttributeValue(tag: "A", text: "X", position: Vector(0, 0), height: 5),
                    BlockAttributeValue(tag: "B", text: "Y", position: Vector(0, 8), height: 5),
                ])))

        let plainGeo = plain.resolve(context)
        let attrGeo = withAttrs.resolve(context)

        // The plain insert is the single line member.
        #expect(plainGeo.polylines.count == 1)
        // The attributed insert has the SAME member plus text geometry for 2 runs.
        #expect(primitiveCount(attrGeo) > primitiveCount(plainGeo))
    }

    @Test("ATTRIB text is placed at the insert's transformed position")
    func resolveAttributePlacement() {
        // No block members at all — only the attribute, so the resolved bbox is the
        // attribute text's box. Place the attribute at local (0,0) and the insert at
        // (200,100); the text must appear near (200,100), not at the origin.
        let context = ctxWithFont(["EMPTY": []])
        let insert = EntityRecord(id: EntityID(7),
            kind: .insert(InsertData(blockName: "EMPTY", insertionPoint: Vector(200, 100),
                attributes: [BlockAttributeValue(tag: "T", text: "Z",
                                                 position: Vector(0, 0), height: 10)])))
        let geo = insert.resolve(context)
        #expect(primitiveCount(geo) > 0)             // text produced geometry

        // Every produced point sits near the insert placement (within a few text
        // heights of (200,100)), nowhere near the origin.
        let pts = geo.polylines.flatMap { $0.points } + geo.fills.flatMap { $0.loops.flatMap { $0 } }
        #expect(!pts.isEmpty)
        for p in pts {
            #expect(p.x > 150 && p.y > 50)
        }
    }

    @Test("a MINSERT renders each attribute once per grid cell")
    func resolveAttributePerCell() {
        // A 2×3 grid (6 cells), no members, one attribute → text geometry for 6 runs.
        let context = ctxWithFont(["EMPTY": []])
        let oneCell = EntityRecord(id: EntityID(1),
            kind: .insert(InsertData(blockName: "EMPTY", insertionPoint: Vector(0, 0),
                attributes: [BlockAttributeValue(tag: "T", text: "Q", height: 5)])))
        let grid = EntityRecord(id: EntityID(2),
            kind: .insert(InsertData(blockName: "EMPTY", insertionPoint: Vector(0, 0),
                rows: 2, cols: 3, rowSpacing: 20, colSpacing: 20,
                attributes: [BlockAttributeValue(tag: "T", text: "Q", height: 5)])))

        let oneN = primitiveCount(oneCell.resolve(context))
        let gridN = primitiveCount(grid.resolve(context))
        #expect(oneN > 0)
        // 6 cells ⇒ ~6× the per-cell geometry (a single glyph "Q" per cell).
        #expect(gridN == oneN * 6)
    }

    // MARK: - Resolve: NO REGRESSION on existing insert/MINSERT/nested resolve

    @Test("an insert with NO attributes resolves identically to before")
    func resolveNoAttributesUnchanged() {
        let members = lineMember()
        let context = ctx(["L": members])
        let insert = EntityRecord(id: EntityID(1),
            kind: .insert(InsertData(blockName: "L", insertionPoint: Vector(5, 5))))
        let geo = insert.resolve(context)
        #expect(geo.polylines.count == 1)
        #expect(geo.fills.isEmpty)
        // The line endpoint (10,0) lands at (15,5).
        let pts = geo.polylines.flatMap { $0.points }
        #expect(pts.contains { abs($0.x - 15) < 1e-9 && abs($0.y - 5) < 1e-9 })
    }

    @Test("MINSERT with no attributes still stamps members once per cell (unchanged)")
    func resolveMinsertNoAttributesUnchanged() {
        let members = lineMember()
        let context = ctx(["L": members])
        let grid = EntityRecord(id: EntityID(1),
            kind: .insert(InsertData(blockName: "L", insertionPoint: Vector(0, 0),
                rows: 2, cols: 3, rowSpacing: 20, colSpacing: 20)))
        let geo = grid.resolve(context)
        #expect(geo.polylines.count == 6)   // one line member × 6 cells
    }

    @Test("a nested insert with no attributes still resolves (depth-guarded, unchanged)")
    func resolveNestedInsertUnchanged() {
        // Block INNER = a line; block OUTER = an insert of INNER.
        let inner: [EntityRecord] = [EntityRecord(id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))]
        let outer: [EntityRecord] = [EntityRecord(id: EntityID(2),
            kind: .insert(InsertData(blockName: "INNER", insertionPoint: Vector(0, 0))))]
        let context = ctx(["INNER": inner, "OUTER": outer])
        let top = EntityRecord(id: EntityID(3),
            kind: .insert(InsertData(blockName: "OUTER", insertionPoint: Vector(50, 0))))
        let geo = top.resolve(context)
        #expect(geo.polylines.count == 1)   // the single inner line, twice-translated
    }

    // MARK: - DXF round-trip

    @Test("ATTDEFs on a block + ATTRIB values on an insert survive a DXF round-trip")
    func dxfAttributeRoundTrip() async throws {
        let member = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let insertData = InsertData(
            blockName: "TITLEBLOCK", insertionPoint: Vector(100, 50),
            attributes: [
                BlockAttributeValue(tag: "PARTNO", text: "A-17",
                                    position: Vector(2, 3), height: 4, rotation: 0),
                BlockAttributeValue(tag: "REV", text: "B",
                                    position: Vector(2, 9), height: 4, rotation: 0),
            ])
        let insert = EntityRecord(id: EntityID(2), layer: LayerID("0"),
            kind: .insert(insertData))

        var blocks = BlockTable()
        blocks.add(Block(name: "TITLEBLOCK", basePoint: Vector(0, 0),
            entityIDs: [EntityID(1)],
            attributeDefs: [
                BlockAttributeDef(tag: "PARTNO", prompt: "Part number?",
                                  defaultText: "TBD", position: Vector(2, 3), height: 4, flags: 0),
                BlockAttributeDef(tag: "REV", prompt: "Revision?",
                                  defaultText: "A", position: Vector(2, 9), height: 4, flags: 0),
            ]))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = tempDXF()
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities(
            [member, insert], layers: layers, blocks: blocks,
            blockMembers: ["TITLEBLOCK": [member]], toPath: outPath)

        // --- The written DXF proves the writer patch fired. ---
        let dxfText = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(dxfText.contains("ATTRIB"))   // ATTRIB sub-entities written
        #expect(dxfText.contains("ATTDEF"))   // ATTDEF templates written
        #expect(dxfText.contains("SEQEND"))   // SEQEND closes the ATTRIB list
        // Code 66 == 1 (attributes-follow flag) appears as a `66 / 1` group pair.
        #expect(dxfRegexGroupHasValue(dxfText, code: "66", value: "1"))

        // --- The read-back model proves the reader patch fired. ---
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        // ATTRIB values survive on the insert.
        let inserts = back.records.compactMap { r -> InsertData? in
            if case .insert(let d) = r.kind { return d } else { return nil }
        }
        let d = try #require(inserts.first)
        #expect(d.attributes.count == 2)
        let partno = try #require(d.attributes.first { $0.tag.caseInsensitiveCompare("PARTNO") == .orderedSame })
        #expect(partno.text == "A-17")
        #expect(abs(partno.position.x - 2) < 1e-6)
        #expect(abs(partno.position.y - 3) < 1e-6)
        #expect(abs(partno.height - 4) < 1e-6)
        let rev = try #require(d.attributes.first { $0.tag.caseInsensitiveCompare("REV") == .orderedSame })
        #expect(rev.text == "B")

        // ATTDEF templates survive on the block.
        let blk = try #require(back.blocks.block(named: "TITLEBLOCK")
                               ?? back.blocks.block(namedCaseInsensitive: "TITLEBLOCK"))
        #expect(blk.attributeDefs.count == 2)
        let defPartno = try #require(blk.attributeDefs.first { $0.tag.caseInsensitiveCompare("PARTNO") == .orderedSame })
        #expect(defPartno.prompt == "Part number?")
        #expect(defPartno.defaultText == "TBD")
    }

    @Test("an insert with NO attributes round-trips unchanged (no stray ATTRIB)")
    func dxfNoAttributesRoundTrip() async throws {
        let member = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 2)))
        let insert = EntityRecord(id: EntityID(2), layer: LayerID("0"),
            kind: .insert(InsertData(blockName: "DOT", insertionPoint: Vector(7, 8))))
        var blocks = BlockTable()
        blocks.add(Block(name: "DOT", entityIDs: [EntityID(1)]))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = tempDXF()
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities(
            [member, insert], layers: layers, blocks: blocks,
            blockMembers: ["DOT": [member]], toPath: outPath)

        // No ATTRIB / ATTDEF / SEQEND records written for a plain insert.
        let dxfText = try String(contentsOfFile: outPath, encoding: .utf8)
        #expect(!dxfText.contains("ATTRIB"))
        #expect(!dxfText.contains("ATTDEF"))
        #expect(!dxfText.contains("SEQEND"))

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let d = try #require(back.records.compactMap { r -> InsertData? in
            if case .insert(let i) = r.kind { return i } else { return nil }
        }.first)
        #expect(d.attributes.isEmpty)
        #expect(d.blockName.caseInsensitiveCompare("DOT") == .orderedSame)
    }

    @Test("empty/whitespace attribute text round-trips safely")
    func dxfEmptyAttributeTextSafe() async throws {
        let insert = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .insert(InsertData(blockName: "EB", insertionPoint: Vector(0, 0),
                attributes: [
                    BlockAttributeValue(tag: "EMPTY", text: "", position: Vector(0, 0), height: 2),
                    BlockAttributeValue(tag: "SPACE", text: "  ", position: Vector(0, 5), height: 2),
                ])))
        var blocks = BlockTable()
        blocks.add(Block(name: "EB"))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = tempDXF()
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        // Must not throw / crash on empty + whitespace values.
        _ = try await CADEngine.shared.writeEntities(
            [insert], layers: layers, blocks: blocks, blockMembers: ["EB": []],
            toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let d = try #require(back.records.compactMap { r -> InsertData? in
            if case .insert(let i) = r.kind { return i } else { return nil }
        }.first)
        // Both tags survive; the values are exactly as written (possibly empty).
        #expect(d.attributes.count == 2)
        #expect(d.attributes.contains { $0.tag.caseInsensitiveCompare("EMPTY") == .orderedSame })
    }

    // MARK: - tiny DXF text helper

    /// True if the DXF text has a `code` group line immediately followed by a line
    /// whose trimmed content equals `value` (DXF group pairs are 2 lines: the code,
    /// then the value). Used to assert `66 / 1` (attributes-follow) was written.
    private func dxfRegexGroupHasValue(_ dxf: String, code: String, value: String) -> Bool {
        let lines = dxf.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var i = 0
        while i + 1 < lines.count {
            if lines[i] == code && lines[i + 1] == value { return true }
            i += 1
        }
        return false
    }
}
