//
//  MultiLeaderDXFRoundTripTests.swift
//  CADEngineTests
//
//  ML-W3 — DXF read/write for the MULTILEADER entity (`.multileader`). ML-W1 added
//  the engine value model UNWIRED + STUBBED DXF write to UNSUPPORTED; ML-W3 replaces
//  that stub with a real DXF MULTILEADER write (bridge `LC_ENT_MLEADER` POD +
//  `dxfRW::writeMultiLeader`) and a real read arm.
//
//  HONEST FIDELITY (the whole point of these tests): stock libdxfrw's
//  `writeMultiLeader` is GEOMETRY-LIGHT — it emits ONLY the entity-level scalars,
//  NOT the embedded CONTEXT_DATA{} block; and its DXF reader (`parseCode`) likewise
//  parses ONLY those scalars (the CONTEXT_DATA leg points + text are decoded in the
//  DWG bit-stream path only). We do NOT patch the vendored library. So across a DXF
//  write→reread of a `MultiLeaderData`:
//    - SURVIVES: `landingDistance` (code 41), `doglegEnabled` (code 291),
//                `arrowSize` (code 42), and the common entity attrs (layer/color).
//    - DROPPED:  the leg `vertices`, the inline annotation text, `styleName`, and
//                `hasArrow` (no entity-level "has arrow" DXF flag).
//  These tests PIN exactly that contract (the survives-vs-dropped split), so a future
//  full-CONTEXT_DATA enhancement is a deliberate, test-visible change. The
//  annotation text is ALSO emitted as a standalone top-level TEXT (like LEADER), so
//  other CAD tools SEE the text — pinned here too.
//
//  Uniquely namespaced so it does not collide with MultiLeaderEntityTests.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("multileader DXF read/write round-trip (ML-W3)")
struct MultiLeaderDXFRoundTripTests {

    /// Writes the given records to a temp DXF, reads them back, returns the result.
    private func roundTrip(_ records: [EntityRecord]) async throws -> CADEngine.DXFReadResult {
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mleader-rt-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        _ = try await CADEngine.shared.writeEntities(records, layers: layers, toPath: outPath)
        return try await CADEngine.shared.readEntities(dxfPath: outPath)
    }

    private func firstMultiLeader(_ result: CADEngine.DXFReadResult) -> MultiLeaderData? {
        for r in result.records {
            if case .multileader(let d) = r.kind { return d }
        }
        return nil
    }

    // MARK: - The entity is no longer dropped (ML-W1 stub removed)

    @Test("a MULTILEADER is WRITTEN (not skipped as UNSUPPORTED) and re-read as .multileader")
    func multiLeaderIsWrittenAndRead() async throws {
        let d = MultiLeaderData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(13, 3)],
            hasArrow: true, arrowSize: 3.0, annotation: nil, styleName: "Standard",
            landingDistance: 4.0, doglegEnabled: true)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .multileader(d))

        let back = try await roundTrip([rec])
        let ml = try #require(firstMultiLeader(back),
                              "the MULTILEADER must round-trip as a .multileader (ML-W1 stub removed)")
        // No skipped-entity warning for the written MULTILEADER.
        #expect(!back.warnings.contains { $0.uppercased().contains("MULTILEADER") })
        #expect(!back.warnings.contains { $0.uppercased().contains("MLEADER") })
        _ = ml
    }

    // MARK: - What SURVIVES the DXF round-trip (entity-level scalars)

    @Test("landingDistance (code 41), doglegEnabled (code 291) and arrowSize (code 42) SURVIVE")
    func scalarsSurvive() async throws {
        let d = MultiLeaderData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            hasArrow: true, arrowSize: 3.5, annotation: nil, styleName: nil,
            landingDistance: 4.25, doglegEnabled: false)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .multileader(d))

        let back = try await roundTrip([rec])
        let ml = try #require(firstMultiLeader(back))
        #expect(abs(ml.landingDistance - 4.25) < 1e-6, "landing distance (code 41) must survive")
        #expect(ml.doglegEnabled == false, "dogleg flag (code 291) must survive")
        #expect(abs(ml.arrowSize - 3.5) < 1e-6, "arrow size (code 42) must survive")
    }

    @Test("the dogleg-enabled flag survives in the TRUE state too")
    func doglegEnabledTrueSurvives() async throws {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(5, 0)],
                                doglegEnabled: true)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .multileader(d))
        let back = try await roundTrip([rec])
        let ml = try #require(firstMultiLeader(back))
        #expect(ml.doglegEnabled == true)
    }

    // MARK: - What is DROPPED (the geometry-light vendored writer limitation)

    @Test("the leg VERTICES are DROPPED on a DXF round-trip (libdxfrw geometry-light)")
    func verticesAreDropped() async throws {
        // This pins the documented limitation: a 3-vertex leg comes back empty,
        // because stock libdxfrw's writeMultiLeader does not emit CONTEXT_DATA{} and
        // its DXF reader does not parse it. (Engine Codable round-trips it losslessly;
        // DXF does not.)
        let d = MultiLeaderData(
            vertices: [Vector(0, 0), Vector(10, 0), Vector(13, 3)],
            arrowSize: 2.5, landingDistance: 2.0, doglegEnabled: true)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .multileader(d))

        let back = try await roundTrip([rec])
        let ml = try #require(firstMultiLeader(back))
        #expect(ml.vertices.isEmpty,
                "leg vertices are NOT serialized by the vendored writeMultiLeader (documented gap)")
    }

    @Test("the inline ANNOTATION is DROPPED from the re-read MULTILEADER (but emitted as standalone TEXT)")
    func annotationDroppedFromMultiLeaderButEmittedStandalone() async throws {
        let annotation = EntityKind.text(TextData(position: Vector(10, 0), height: 2.5,
                                                  text: "ML-NOTE", styleName: "Standard"))
        let d = MultiLeaderData(
            vertices: [Vector(0, 0), Vector(10, 0)],
            hasArrow: true, arrowSize: 2.5, annotation: annotation,
            landingDistance: 2.0, doglegEnabled: true)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .multileader(d))

        let back = try await roundTrip([rec])
        // The re-read MULTILEADER has NO inline annotation (CONTEXT_DATA dropped).
        let ml = try #require(firstMultiLeader(back))
        #expect(ml.annotation == nil,
                "the re-read multileader carries no inline annotation (CONTEXT_DATA not serialized)")
        // ...but the text SURVIVES as a standalone top-level TEXT so other tools see it.
        let texts = back.records.compactMap { r -> String? in
            if case .text(let t) = r.kind { return t.text } else { return nil }
        }
        #expect(texts.contains("ML-NOTE"),
                "the annotation text must survive as a standalone TEXT (like LEADER)")
    }

    @Test("the styleName is DROPPED on a DXF round-trip (no DXF group for the MLEADERSTYLE name)")
    func styleNameDropped() async throws {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(5, 0)],
                                styleName: "MY_MLEADER_STYLE", landingDistance: 1.0)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .multileader(d))
        let back = try await roundTrip([rec])
        let ml = try #require(firstMultiLeader(back))
        // Stock writeMultiLeader emits only a styleHANDLE, never the style NAME.
        #expect(ml.styleName == nil || ml.styleName?.isEmpty == true,
                "the MLEADERSTYLE name is not serialized by the vendored writer (documented gap)")
    }

    // MARK: - Reading a hand-authored (foreign) AutoCAD MULTILEADER

    /// A minimal DXF carrying ONE AutoCAD MULTILEADER with the entity-level scalars
    /// the vendored DXF reader actually parses: leaderType (170), landing distance
    /// (41), default arrow head size (42), dogleg-enabled (291). NOTE: the embedded
    /// CONTEXT_DATA{} leg points + text are intentionally OMITTED — stock libdxfrw's
    /// DXF reader does not parse them anyway (they decode in the DWG path only), so a
    /// foreign *.dxf* MULTILEADER imports as a scalar-only, drawn-light callout. This
    /// fixture pins exactly that honest import behavior.
    private static let foreignMultiLeaderDXF = """
      0
    SECTION
      2
    ENTITIES
      0
    MULTILEADER
      8
    0
    100
    AcDbEntity
    100
    AcDbMLeader
     90
    0
    170
    1
     91
    0
    171
    0
    290
    1
    291
    1
     41
    7.5
     42
    3.25
    172
    2
     45
    1.0
      0
    ENDSEC
      0
    EOF

    """

    /// Writes `foreignMultiLeaderDXF` to a unique temp file and returns its path.
    private func writeForeignMultiLeader() throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("foreign_mleader_\(UUID().uuidString).dxf")
        try Self.foreignMultiLeaderDXF.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("a hand-authored AutoCAD MULTILEADER imports as a .multileader (scalar-only, no warning)")
    func foreignMultiLeaderImports() async throws {
        let path = try writeForeignMultiLeader()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let ml = try #require(firstMultiLeader(result),
                              "a MULTILEADER entity must import as a .multileader")
        // The entity-level scalars the DXF reader parses survive the import.
        #expect(abs(ml.landingDistance - 7.5) < 1e-6, "landing distance (code 41) imported")
        #expect(abs(ml.arrowSize - 3.25) < 1e-6, "arrow size (code 42) imported")
        #expect(ml.doglegEnabled == true, "dogleg flag (code 291) imported")
        // The CONTEXT_DATA leg geometry + text are NOT parsed by the DXF reader, so
        // the imported callout is scalar-only (the honest, documented gap).
        #expect(ml.vertices.isEmpty, "no CONTEXT_DATA leg points are parsed from DXF")
        #expect(ml.annotation == nil, "no CONTEXT_DATA text is parsed from DXF")
        // The entity is mapped (not dropped as UNSUPPORTED) — no MULTILEADER warning.
        #expect(!result.warnings.contains { $0.uppercased().contains("MULTILEADER") })
        #expect(!result.warnings.contains { $0.uppercased().contains("MLEADER") })
    }

    // MARK: - Non-multileader entities are unaffected

    @Test("non-multileader entities round-trip unaffected alongside a multileader")
    func otherEntitiesUnaffected() async throws {
        let line = EntityRecord(id: EntityID(1), layer: LayerID("0"),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(100, 50))))
        let circle = EntityRecord(id: EntityID(2), layer: LayerID("0"),
                                  kind: .circle(CircleData(center: Vector(20, 20), radius: 7)))
        let ml = EntityRecord(id: EntityID(3), layer: LayerID("0"),
                              kind: .multileader(MultiLeaderData(
                                vertices: [Vector(0, 0), Vector(5, 0)], landingDistance: 2)))

        let back = try await roundTrip([line, circle, ml])
        let lines = back.records.filter { if case .line = $0.kind { return true } else { return false } }
        let circles = back.records.filter { if case .circle = $0.kind { return true } else { return false } }
        #expect(lines.count == 1)
        #expect(circles.count == 1)
        // The line geometry is intact.
        if case .line(let l) = lines.first?.kind {
            #expect(abs(l.end.x - 100) < 1e-6 && abs(l.end.y - 50) < 1e-6)
        } else { Issue.record("line geometry lost") }
        if case .circle(let c) = circles.first?.kind {
            #expect(abs(c.radius - 7) < 1e-6)
        } else { Issue.record("circle geometry lost") }
    }

    // MARK: - The common attributes (layer/color) survive

    @Test("the multileader's layer and explicit color survive the DXF round-trip")
    func commonAttrsSurvive() async throws {
        let pen = Pen(lineColor: .explicit(RGBAColor(0, 0, 1)))
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(4, 0)], landingDistance: 1)
        let rec = EntityRecord(id: EntityID(1), layer: LayerID("0"), pen: pen,
                               kind: .multileader(d))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mleader-attr-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        _ = try await CADEngine.shared.writeEntities([rec], layers: layers, toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        let mleaders = back.records.filter {
            if case .multileader = $0.kind { return true } else { return false }
        }
        let r = try #require(mleaders.first)
        #expect(r.layer.name == "0")
        // The explicit (non-ByLayer) color survives on the entity pen.
        if case .explicit = r.pen.lineColor {
            // ok — an explicit color round-tripped (the exact ACI mapping is covered
            // by the dedicated color round-trip suites; here we only pin survival).
        } else {
            Issue.record("multileader explicit color did not round-trip")
        }
    }
}
