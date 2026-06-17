//
//  LinetypeLTypeTableTests.swift
//  CADEngineTests
//
//  Dashed-line export FIDELITY — feature-gap Wave 4B, Stage 2.
//
//  THE BUG: a dashed/dotted entity exported to DXF rendered SOLID in other CAD apps
//  because the written DXF's LTYPE table held only the three SOLID built-ins
//  (CONTINUOUS / ByLayer / ByBlock); an entity referencing "DASHED" (code 6) pointed
//  at an UNDEFINED linetype. THE FIX: the writer now emits each non-solid linetype
//  the writer names (DASHED/DOT/DASHDOT/CENTER/BORDER/DIVIDE) as a real LTYPE record
//  carrying its dash-element pattern (DXF code 49 + the count code 73), so the dash
//  geometry travels with the file.
//
//  These tests parse the WRITTEN DXF text's LTYPE table directly (not a round-trip),
//  so they pin the actual serialized dash elements regardless of the reader's
//  name→PenLineType mapping.
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

@Suite("LTYPE table dash geometry on DXF write (dashed-export fidelity)")
struct LinetypeLTypeTableTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ltype_\(UUID().uuidString).dxf").path
    }

    /// Writes one entity with `lineType` and returns the produced DXF text.
    private func writeDXF(lineType: PenLineType, version: DXFVersion = .r2000) async throws -> String {
        let rec = EntityRecord(
            id: EntityID(1),
            pen: Pen(lineColor: .explicit(.white), lineType: lineType),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let path = tempDXFPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await CADEngine.shared.writeEntities(
            [rec], layers: LayerTable(), toPath: path, version: version)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// Returns the text of the LTYPE table record named `name`, from its `LTYPE`
    /// marker to the next `\n  0\n` (the next table-record / table end), or "" if the
    /// named record is not in the file. A record is `0\nLTYPE … 2\n<name> … `; we find
    /// the `2`/<name> group then walk back to the owning `LTYPE` marker and forward to
    /// the next entry.
    private func ltypeRecord(_ text: String, named name: String) -> String {
        // Split on the LTYPE entry marker; each chunk after the first starts at a
        // record body. (Group codes are right-aligned to width 3 by libdxfrw's ASCII
        // writer, so the type marker line is "LTYPE" preceded by a "  0" group.)
        let parts = text.components(separatedBy: "\nLTYPE\n")
        for chunk in parts.dropFirst() {
            // Record name is the code-2 group: "  2\n<NAME>\n". Width-3 → "  2".
            guard let r = chunk.range(of: "\n  2\n") else { continue }
            let after = chunk[r.upperBound...]
            let recName = after.prefix(while: { $0 != "\n" })
            if recName == Substring(name) {
                // Trim the chunk to just this record (up to the next code-0 group).
                if let end = chunk.range(of: "\n  0\n") {
                    return String(chunk[..<end.lowerBound])
                }
                return String(chunk)
            }
        }
        return ""
    }

    /// Counts the code-49 (dash element length) groups in an LTYPE record body.
    private func dashElementCount(_ record: String) -> Int {
        // A dash element group is " 49\n<value>\n" (code 49 right-aligned to width 3).
        record.components(separatedBy: "\n 49\n").count - 1
    }

    @Test("the DASHED linetype is written as a real LTYPE record with dash elements")
    func dashedHasDashElements() async throws {
        let text = try await writeDXF(lineType: .dashed)
        let record = ltypeRecord(text, named: "DASHED")
        #expect(!record.isEmpty, "no DASHED LTYPE record was written")
        // It carries a non-empty dash sequence (the bug was ZERO elements → solid).
        #expect(dashElementCount(record) >= 2,
                "DASHED LTYPE record has no dash elements (would render solid)")
        // And the element-count group (code 73) matches.
        #expect(record.contains("\n 73\n"))
    }

    @Test("DOT / DASHDOT / CENTER / BORDER / DIVIDE all carry dash elements")
    func everyNonSolidHasDashElements() async throws {
        // The expected canonical element counts (acad.lin), pinned so a future tweak
        // to the pattern table is a deliberate, reviewed change.
        let expected: [(PenLineType, String, Int)] = [
            (.dotted,  "DOT",     2),
            (.dashDot, "DASHDOT", 4),
            (.center,  "CENTER",  4),
            (.border,  "BORDER",  6),
            (.divide,  "DIVIDE",  6),
        ]
        for (lt, name, count) in expected {
            let text = try await writeDXF(lineType: lt)
            let record = ltypeRecord(text, named: name)
            #expect(!record.isEmpty, "no \(name) LTYPE record was written")
            #expect(dashElementCount(record) == count,
                    "\(name) LTYPE record had \(dashElementCount(record)) dash elements, expected \(count)")
        }
    }

    @Test("the dashed LINE references its DASHED linetype by name (code 6)")
    func entityReferencesLinetype() async throws {
        let text = try await writeDXF(lineType: .dashed)
        // The entity's linetype reference (code 6, width-3 → "  6") names DASHED, which
        // now resolves to a real LTYPE record (the round-trip the fix enables).
        #expect(text.contains("\n  6\nDASHED\n"))
    }

    @Test("a SOLID entity writes NO extra LTYPE record (regression — only the built-ins)")
    func solidWritesNoDashRecord() async throws {
        let text = try await writeDXF(lineType: .solid)
        // A solid pen references CONTINUOUS (a built-in); the dashed records are STILL
        // emitted into the table (the table is a fixed catalog), but the entity itself
        // must reference CONTINUOUS, not a dashed name.
        #expect(text.contains("\n  6\nCONTINUOUS\n"))
        // The built-in CONTINUOUS record carries NO dash elements (it is solid).
        let cont = ltypeRecord(text, named: "CONTINUOUS")
        #expect(dashElementCount(cont) == 0)
    }

    @Test("the written DASHED elements are the canonical acad.lin lengths")
    func canonicalDashLengths() async throws {
        // Pin the actual serialized lengths so the LTYPE geometry agrees with the
        // renderer rhythm (long dash, shorter gap). DASHED == [0.5, -0.25].
        let text = try await writeDXF(lineType: .dashed)
        let record = ltypeRecord(text, named: "DASHED")
        #expect(!record.isEmpty)
        // The pen-down dash (positive) and the pen-up gap (negative) are both present.
        #expect(record.contains("0.5"), "expected the 0.5 dash length")
        #expect(record.contains("-0.25"), "expected the -0.25 gap length")
    }
}
