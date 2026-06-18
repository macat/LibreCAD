//
//  MLineDXFRoundTripTests.swift
//  CADEngineTests
//
//  Wave 1 — DXF read/write for the MLINE entity (`.mline`). Wave 0 added the engine
//  value model (`MLineData`) UNWIRED + a STUBBED DXF write to UNSUPPORTED; Wave 1
//  replaces that stub with a real DXF MLINE write (bridge `LC_ENT_MLINE` POD +
//  STOCK `dxfRW::writeMLine`, ZERO vendored libdxfrw edits) and a real read arm.
//
//  FIDELITY (the whole point of these tests). A DXF MLINE entity carries the path
//  vertices + scalars (scale / justification / closed / numLines) natively, but the
//  per-ELEMENT offsets + colors live in the referenced MLINESTYLE OBJECT — which
//  stock libdxfrw can NEITHER write (no writeMLineStyle, no MLINESTYLE in
//  writeObjects) NOR read on the DXF path (processObjects parses only IMAGEDEF +
//  PLOTSETTINGS). To round-trip element geometry with NO vendored edit, the bridge
//  rides the element table on the MLINE entity's own XDATA under the "LIBRECAD" appid
//  (stock `writeMLine` emits `ent->extData`; the stock reader collects it into
//  `DRW_Entity::extData`). So for OUR OWN files everything round-trips losslessly:
//  vertices, scale, justification, closed, AND the per-element offsets + colors.
//
//  These tests PIN that full round-trip, plus the honest FOREIGN-file behavior: a
//  hand-authored AutoCAD MLINE (no LIBRECAD XDATA) imports as a real `.mline` with
//  the right element COUNT + default centered offsets (NOT a noisy UNSUPPORTED skip),
//  since the per-element offsets are only recoverable via the MLINESTYLE we cannot
//  parse with stock libdxfrw.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("MLINE DXF read/write round-trip (Wave 1)")
struct MLineDXFRoundTripTests {

    /// Writes the given records to a temp DXF (R2000+, where MLINE is valid), reads
    /// them back, returns the result.
    private func roundTrip(
        _ records: [EntityRecord],
        version: DXFVersion = .r2000
    ) async throws -> CADEngine.DXFReadResult {
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mline-rt-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        _ = try await CADEngine.shared.writeEntities(records, layers: layers,
                                                     toPath: outPath, version: version)
        return try await CADEngine.shared.readEntities(dxfPath: outPath)
    }

    private func firstMLine(_ result: CADEngine.DXFReadResult) -> MLineData? {
        for r in result.records {
            if case .mline(let d) = r.kind { return d }
        }
        return nil
    }

    /// A 3-vertex path with TWO elements (±1 offset). The base fixture for most tests.
    private func sampleMLine(
        justification: MLineJustification = .zero,
        scale: Double = 1,
        closed: Bool = false,
        elements: [MLineElement] = [MLineElement(offset: 1.0),
                                    MLineElement(offset: -1.0)]
    ) -> MLineData {
        MLineData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 10)],
            elements: elements,
            justification: justification,
            scale: scale,
            closed: closed)
    }

    // MARK: - The entity is no longer dropped (Wave-0 stub removed)

    @Test("an MLINE is WRITTEN (not skipped as UNSUPPORTED) and re-read as .mline")
    func mlineIsWrittenAndRead() async throws {
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                               kind: .mline(sampleMLine()))
        let back = try await roundTrip([rec])
        _ = try #require(firstMLine(back),
                         "the MLINE must round-trip as a .mline (Wave-0 stub removed)")
        // No skipped-entity warning for the written MLINE.
        #expect(!back.warnings.contains { $0.uppercased().contains("MLINE") },
                "an MLINE must not be reported as an unsupported/skipped entity")
    }

    // MARK: - Full geometry round-trip (vertices)

    @Test("the vertex PATH survives the DXF round-trip exactly")
    func verticesSurvive() async throws {
        let d = sampleMLine()
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .mline(d))
        let back = try await roundTrip([rec])
        let r = try #require(firstMLine(back))
        #expect(r.vertices.count == d.vertices.count, "vertex count must survive")
        for (a, b) in zip(r.vertices, d.vertices) {
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9,
                    "vertex (\(a.x),\(a.y)) must match (\(b.x),\(b.y))")
        }
    }

    // MARK: - Scalars: scale (incl. negative) + closed

    @Test("a non-unit POSITIVE scale survives")
    func positiveScaleSurvives() async throws {
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                               kind: .mline(sampleMLine(scale: 2.5)))
        let r = try #require(firstMLine(try await roundTrip([rec])))
        #expect(abs(r.scale - 2.5) < 1e-9, "scale (code 40) must survive")
    }

    @Test("a NEGATIVE scale survives (the documented sign-lock mirror)")
    func negativeScaleSurvives() async throws {
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                               kind: .mline(sampleMLine(scale: -1.5)))
        let r = try #require(firstMLine(try await roundTrip([rec])))
        #expect(abs(r.scale - (-1.5)) < 1e-9, "a negative scale must round-trip verbatim")
    }

    @Test("the CLOSED flag survives in both states (open + closed)")
    func closedFlagSurvives() async throws {
        let open = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                                kind: .mline(sampleMLine(closed: false)))
        let closed = EntityRecord(id: EntityID(2), layer: LayerID("0"),
                                  kind: .mline(sampleMLine(closed: true)))
        let backOpen = try #require(firstMLine(try await roundTrip([open])))
        #expect(backOpen.closed == false, "an OPEN mline must come back open")
        let backClosed = try #require(firstMLine(try await roundTrip([closed])))
        #expect(backClosed.closed == true, "a CLOSED mline must come back closed (code 71 bit 0)")
    }

    // MARK: - Justification: each of top / zero / bottom

    @Test("each justification (top / zero / bottom) round-trips exactly")
    func eachJustificationSurvives() async throws {
        for just in MLineJustification.allCases {
            let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                                   kind: .mline(sampleMLine(justification: just)))
            let r = try #require(firstMLine(try await roundTrip([rec])),
                                 "justification \(just) must round-trip as a .mline")
            #expect(r.justification == just,
                    "justification \(just) (code 70) must survive; got \(r.justification)")
        }
    }

    // MARK: - Element offsets + per-element colors (the XDATA carrier)

    @Test("element OFFSETS survive for a 2-element mline")
    func twoElementOffsetsSurvive() async throws {
        let d = sampleMLine(elements: [MLineElement(offset: 0.75),
                                       MLineElement(offset: -0.25)])
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .mline(d))
        let r = try #require(firstMLine(try await roundTrip([rec])))
        #expect(r.elements.count == 2, "element count must survive")
        #expect(abs(r.elements[0].offset - 0.75) < 1e-9)
        #expect(abs(r.elements[1].offset - (-0.25)) < 1e-9)
    }

    @Test("element offsets survive for a 3-element (odd-count) mline")
    func threeElementOffsetsSurvive() async throws {
        let offs = [0.5, 0.0, -0.5]
        let d = sampleMLine(elements: offs.map { MLineElement(offset: $0) })
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .mline(d))
        let r = try #require(firstMLine(try await roundTrip([rec])))
        #expect(r.elements.count == 3)
        for (a, b) in zip(r.elements.map(\.offset), offs) {
            #expect(abs(a - b) < 1e-9, "element offset \(b) must survive; got \(a)")
        }
    }

    @Test("per-element COLOR override survives, and a nil color stays nil")
    func perElementColorSurvives() async throws {
        let d = sampleMLine(elements: [MLineElement(offset: 1, colorIndex: 5),
                                       MLineElement(offset: -1, colorIndex: nil)])
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .mline(d))
        let r = try #require(firstMLine(try await roundTrip([rec])))
        #expect(r.elements.count == 2)
        #expect(r.elements[0].colorIndex == 5,
                "an explicit per-element ACI (5) must survive the XDATA round-trip")
        #expect(r.elements[1].colorIndex == nil,
                "an absent per-element color must come back nil (sentinel decoded)")
    }

    // MARK: - A combined torture case (everything at once)

    @Test("a closed, negatively-scaled, bottom-justified, 3-element MLINE round-trips fully")
    func combinedFidelity() async throws {
        let d = MLineData(
            vertices: [Vector(0, 0), Vector(8, 0), Vector(8, 6), Vector(0, 6)],
            elements: [MLineElement(offset: 1.0, colorIndex: 1),
                       MLineElement(offset: 0.0),
                       MLineElement(offset: -1.0, colorIndex: 3)],
            justification: .bottom,
            scale: -2.0,
            closed: true)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .mline(d))
        let r = try #require(firstMLine(try await roundTrip([rec])))
        #expect(r.vertices.count == 4)
        #expect(r.justification == .bottom)
        #expect(abs(r.scale - (-2.0)) < 1e-9)
        #expect(r.closed == true)
        #expect(r.elements.count == 3)
        #expect(abs(r.elements[0].offset - 1.0) < 1e-9 && r.elements[0].colorIndex == 1)
        #expect(abs(r.elements[1].offset - 0.0) < 1e-9 && r.elements[1].colorIndex == nil)
        #expect(abs(r.elements[2].offset - (-1.0)) < 1e-9 && r.elements[2].colorIndex == 3)
    }

    // MARK: - The common attributes (layer / color) survive

    @Test("the mline's layer and explicit color survive the DXF round-trip")
    func commonAttrsSurvive() async throws {
        let pen = Pen(lineColor: .explicit(RGBAColor(0, 0, 1)))
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), pen: pen,
                               kind: .mline(sampleMLine()))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mline-attr-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        _ = try await CADEngine.shared.writeEntities([rec], layers: layers, toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let mlines = back.records.filter {
            if case .mline = $0.kind { return true } else { return false }
        }
        let r = try #require(mlines.first)
        #expect(r.layer.name == "0")
        if case .explicit = r.pen.lineColor {
            // ok — an explicit color round-tripped (exact ACI mapping is covered by the
            // dedicated color suites; here we pin survival only).
        } else {
            Issue.record("mline explicit color did not round-trip")
        }
    }

    // MARK: - R12: MLINE is dropped (needs R2000+)

    @Test("at R12 an MLINE is dropped (counted skipped) — it is an R13+ entity")
    func r12DropsMLine() async throws {
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                               kind: .mline(sampleMLine()))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mline-r12-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        let result = try await CADEngine.shared.writeEntities(
            [rec], layers: layers, toPath: outPath, version: .r12)
        #expect(result.skipped >= 1,
                "MLINE is R13+; at R12 the writer drops it (counted skipped)")
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        #expect(firstMLine(back) == nil, "no MLINE should be present in an R12 file")
    }

    // MARK: - Reading a hand-authored (foreign) AutoCAD MLINE

    /// A minimal DXF carrying ONE AutoCAD MLINE with the entity-level groups stock
    /// libdxfrw parses: style name (2), scale (40), justification (70), open/closed
    /// (71), vertex count (72), line count (73), base point (10/20/30), and two
    /// per-vertex baseline points (11/21/31). NO "LIBRECAD" XDATA element table — so
    /// this fixture pins the honest FOREIGN-file behavior: the multiline imports as a
    /// real `.mline` with the right element COUNT + default centered offsets (the
    /// per-element offsets live in the MLINESTYLE we cannot parse with stock libdxfrw).
    private static let foreignMLineDXF = """
      0
    SECTION
      2
    ENTITIES
      0
    MLINE
      8
    0
    100
    AcDbEntity
    100
    AcDbMline
      2
    STANDARD
     40
    1.0
     70
    1
     71
    1
     72
    2
     73
    2
     10
    0.0
     20
    0.0
     30
    0.0
     11
    0.0
     21
    0.0
     31
    0.0
     12
    1.0
     22
    0.0
     32
    0.0
     13
    0.0
     23
    1.0
     33
    0.0
     74
    0
     75
    0
     74
    0
     75
    0
     11
    20.0
     21
    0.0
     31
    0.0
     12
    1.0
     22
    0.0
     32
    0.0
     13
    0.0
     23
    1.0
     33
    0.0
     74
    0
     75
    0
     74
    0
     75
    0
      0
    ENDSEC
      0
    EOF

    """

    private func writeForeignMLine() throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("foreign_mline_\(UUID().uuidString).dxf")
        try Self.foreignMLineDXF.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("a hand-authored AutoCAD MLINE imports as a .mline (NOT a noisy skip)")
    func foreignMLineImports() async throws {
        let path = try writeForeignMLine()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let m = try #require(firstMLine(result),
                             "a foreign MLINE entity must import as a .mline, not be dropped")
        // The path + scalars the stock DXF reader parses survive the import.
        #expect(m.vertices.count == 2, "the two baseline vertices import")
        #expect(abs(m.vertices[0].x - 0.0) < 1e-9 && abs(m.vertices[1].x - 20.0) < 1e-9,
                "the imported path matches the codes-11 baseline points")
        #expect(m.scale == 1.0, "scale (code 40) imports")
        #expect(m.justification == .zero, "justification 1 (code 70) imports as .zero")
        #expect(m.closed == true, "open/closed bit 0 (code 71 == 1) imports as closed")
        // The element COUNT (code 73 == 2) survives even though the per-element offsets
        // (which live in the un-parsed MLINESTYLE) fall back to default centered offsets.
        #expect(m.elements.count == 2,
                "the element count (code 73) imports; offsets default (no LIBRECAD XDATA)")
        // The entity is mapped (not dropped as UNSUPPORTED) — no MLINE warning.
        #expect(!result.warnings.contains { $0.uppercased().contains("MLINE") },
                "a foreign MLINE must import without an unsupported-entity warning")
    }

    // MARK: - Non-mline entities are unaffected

    @Test("non-mline entities round-trip unaffected alongside an mline")
    func otherEntitiesUnaffected() async throws {
        let line = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(100, 50))))
        let circle = EntityRecord(id: EntityID(2), layer: LayerID("0"),
                                  kind: .circle(CircleData(center: Vector(20, 20), radius: 7)))
        let mline = EntityRecord(id: EntityID(3), layer: LayerID("0"),
                                 kind: .mline(sampleMLine()))
        let back = try await roundTrip([line, circle, mline])
        let lines = back.records.filter { if case .line = $0.kind { return true } else { return false } }
        let circles = back.records.filter { if case .circle = $0.kind { return true } else { return false } }
        let mlines = back.records.filter { if case .mline = $0.kind { return true } else { return false } }
        #expect(lines.count == 1)
        #expect(circles.count == 1)
        #expect(mlines.count == 1)
        if case .line(let l) = lines.first?.kind {
            #expect(abs(l.end.x - 100) < 1e-6 && abs(l.end.y - 50) < 1e-6)
        } else { Issue.record("line geometry lost") }
        if case .circle(let c) = circles.first?.kind {
            #expect(abs(c.radius - 7) < 1e-6)
        } else { Issue.record("circle geometry lost") }
    }
}
