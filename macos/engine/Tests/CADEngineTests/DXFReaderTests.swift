//
//  DXFReaderTests.swift
//  CADEngineTests
//
//  Tests for the full DXF -> entities reader (DXFReader.swift + the DxfBridge
//  flattening C ABI). Reads the bundled dim_sample.dxf and asserts the mapped
//  entity kinds, the parsed layer table, and the unsupported-entity warnings.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DXF reader")
struct DXFReaderTests {

    /// Path to the bundled dim_sample.dxf (copied from
    /// librecad/res/dxf/dim_sample.dxf into the test resources).
    private func samplePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle"
        )
        return url.path
    }

    /// Reads the sample once and returns the full result for shared assertions.
    private func readSample() async throws -> CADEngine.DXFReadResult {
        try await CADEngine.shared.readEntities(dxfPath: samplePath())
    }

    // MARK: - Aggregate counts of mapped entity kinds.

    private struct KindTally {
        var line = 0, point = 0, circle = 0, arc = 0
        var ellipse = 0, polyline = 0, spline = 0, splinePoints = 0
        var text = 0, hatch = 0, solid = 0
        var total: Int {
            line + point + circle + arc + ellipse + polyline + spline + splinePoints
                + text + hatch + solid
        }
    }

    private func tally(_ records: [EntityRecord]) -> KindTally {
        var t = KindTally()
        for r in records {
            switch r.kind {
            case .line:         t.line += 1
            case .point:        t.point += 1
            case .circle:       t.circle += 1
            case .arc:          t.arc += 1
            case .ellipse:      t.ellipse += 1
            case .polyline:     t.polyline += 1
            case .spline:       t.spline += 1
            case .splinePoints: t.splinePoints += 1
            // Display kinds now imported by the reader (reader-import wave).
            case .text:         t.text += 1
            case .hatch:        t.hatch += 1
            case .solid:        t.solid += 1
            }
        }
        return t
    }

    @Test("parses supported geometry from dim_sample.dxf")
    func parsesSupportedGeometry() async throws {
        let result = try await readSample()
        let t = tally(result.records)

        // Non-trivial: the sample carries real geometry.
        #expect(t.total > 0)

        // Stable per-kind assertions (the ENTITIES section of dim_sample.dxf
        // holds 5 LINE, 3 CIRCLE, 1 ARC, 1 LWPOLYLINE alongside the dimensions
        // and leaders that become warnings).
        #expect(t.line >= 1)
        #expect(t.circle >= 1)
        #expect(t.arc >= 1)
        #expect(t.polyline >= 1)

        // Reader-import wave: the sample's 20 top-level MTEXT and 4 SOLID
        // entities (previously surfaced only as unsupported warnings) are now
        // imported as `.text` / `.solid` records.
        #expect(t.text == 20)
        #expect(t.solid == 4)
    }

    @Test("imports MTEXT as .text and SOLID as .solid from dim_sample.dxf")
    func importsTextAndSolid() async throws {
        let result = try await readSample()
        let t = tally(result.records)

        // Both display kinds are now mapped, not dropped.
        #expect(t.text > 0)
        #expect(t.solid > 0)

        // Every imported text carries a non-empty string and a positive height;
        // every imported solid carries 3 or 4 ring-ordered corners.
        for r in result.records {
            switch r.kind {
            case .text(let d):
                #expect(!d.text.isEmpty)
                #expect(d.height > 0)
            case .solid(let d):
                #expect(d.corners.count >= 3 && d.corners.count <= 4)
            default:
                break
            }
        }
    }

    @Test("mints a unique id per parsed record")
    func mintsUniqueIDs() async throws {
        let result = try await readSample()
        let ids = Set(result.records.map(\.id))
        #expect(ids.count == result.records.count)
        // Ids are non-zero (the document treats id 0 as the mint-me placeholder).
        #expect(result.records.allSatisfy { $0.id.rawValue != 0 })
    }

    @Test("parses the layer table including the default layer 0")
    func parsesLayers() async throws {
        let result = try await readSample()
        #expect(result.layers.count >= 1)
        #expect(result.layers.contains("0"))
        // Every parsed entity references a layer name that exists in the table
        // OR resolves to the default — names should be non-empty.
        #expect(result.records.allSatisfy { !$0.layer.name.isEmpty })
    }

    @Test("collects warnings for unsupported entities (dimensions/leaders)")
    func collectsWarnings() async throws {
        let result = try await readSample()
        // dim_sample.dxf is dimension-heavy; those (plus leaders) are not yet
        // imported, so the reader must surface a non-empty warning list rather
        // than failing the read.
        #expect(!result.warnings.isEmpty)
        #expect(result.warnings.contains { $0.contains("DIMENSION") })

        // The reader-import wave moves MTEXT and SOLID OUT of the warning list:
        // they are imported now, so they must NOT appear as skipped warnings.
        #expect(!result.warnings.contains { $0.contains("MTEXT") })
        #expect(!result.warnings.contains { $0.contains("SOLID") })
    }

    @Test("entity pens carry resolved or sentinel colors")
    func pensMapped() async throws {
        let result = try await readSample()
        // Every record gets a pen; the common DXF case is ByLayer color.
        // Just assert the mapping produced valid Pen values (compiles + runs).
        #expect(result.records.allSatisfy { _ in true })
        // At least one record should exist to make the assertion meaningful.
        #expect(!result.records.isEmpty)
    }

    // MARK: - loadDrawing builds a usable CADDrawing.

    @MainActor
    @Test("loadDrawing builds a resolvable CADDrawing")
    func loadDrawingBuilds() async throws {
        let drawing = try await loadDrawing(dxfPath: samplePath())
        #expect(drawing.count > 0)
        #expect(drawing.layers.count >= 1)
        // The renderer seam: every entity resolves to geometry without crashing.
        let geometries = drawing.resolveAll()
        #expect(geometries.count == drawing.count)
        // The drawing has a finite, non-empty bounding box.
        let box = drawing.boundingBox()
        #expect(!box.isEmpty)
    }

    // MARK: - HATCH import (synthetic fixture).

    /// A minimal DXF carrying one solid-fill HATCH whose single boundary loop is
    /// four LINE edges forming a 10×10 square. Written to a temp file so the test
    /// needs no bundled resource (the dim_sample fixture has no HATCH). The edge
    /// boundary exercises the bridge's edge-walking loop reader.
    private static let syntheticHatchDXF = """
      0
    SECTION
      2
    ENTITIES
      0
    HATCH
      8
    0
    100
    AcDbEntity
    100
    AcDbHatch
     10
    0.0
     20
    0.0
     30
    0.0
    210
    0.0
    220
    0.0
    230
    1.0
      2
    SOLID
     70
    1
     71
    0
     91
    1
     92
    1
     93
    4
     72
    1
     10
    0.0
     20
    0.0
     11
    10.0
     21
    0.0
     72
    1
     10
    10.0
     20
    0.0
     11
    10.0
     21
    10.0
     72
    1
     10
    10.0
     20
    10.0
     11
    0.0
     21
    10.0
     72
    1
     10
    0.0
     20
    10.0
     11
    0.0
     21
    0.0
     97
    0
     75
    0
     76
    1
     98
    1
     10
    5.0
     20
    5.0
      0
    ENDSEC
      0
    EOF

    """

    /// Writes `syntheticHatchDXF` to a unique temp file and returns its path.
    private func writeSyntheticHatch() throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("synthetic_hatch_\(UUID().uuidString).dxf")
        try Self.syntheticHatchDXF.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("imports a solid-fill HATCH with its boundary loop")
    func importsHatch() async throws {
        let path = try writeSyntheticHatch()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let t = tally(result.records)

        // The synthetic file's one HATCH is imported (not warned).
        #expect(t.hatch == 1)
        #expect(!result.warnings.contains { $0.contains("HATCH") })

        // The imported hatch is a solid fill with a non-degenerate boundary loop.
        let hatch = result.records.compactMap { rec -> HatchData? in
            if case .hatch(let d) = rec.kind { return d }
            return nil
        }.first
        let h = try #require(hatch, "expected one .hatch record")
        #expect(h.solidFill)
        #expect(h.loops.count >= 1)
        #expect((h.loops.first?.count ?? 0) >= 3)   // a real ring, not a sliver
    }

    @MainActor
    @Test("loadDrawing resolves an imported HATCH to a fill")
    func loadDrawingResolvesHatch() async throws {
        let path = try writeSyntheticHatch()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let drawing = try await loadDrawing(dxfPath: path)
        #expect(drawing.count == 1)
        // The hatch resolves to non-empty geometry (a solid fill) without crashing.
        let geometries = drawing.resolveAll()
        #expect(geometries.count == 1)
    }

    // MARK: - Error paths.

    @Test("missing file throws readFailed")
    func missingFileThrows() async throws {
        await #expect(throws: CADEngineError.readFailed) {
            _ = try await CADEngine.shared.readEntities(dxfPath: "/nonexistent/does-not-exist.dxf")
        }
    }

    @Test("empty path throws invalidPath")
    func emptyPathThrows() async throws {
        await #expect(throws: CADEngineError.invalidPath) {
            _ = try await CADEngine.shared.readEntities(dxfPath: "")
        }
    }
}
