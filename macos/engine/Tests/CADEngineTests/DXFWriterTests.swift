//
//  DXFWriterTests.swift
//  CADEngineTests
//
//  Tests for the DXF writer (DXFWriter.swift + the DxfBridge write C ABI). The
//  key test is a full round-trip: read dim_sample.dxf, write it back out, re-read
//  the result, and assert the supported-kind entity counts are preserved. A
//  second test builds a CADDrawing from scratch (line + circle + arc + a custom
//  layer), writes, re-reads, and asserts the geometry round-trips.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DXF writer")
struct DXFWriterTests {

    /// Path to the bundled dim_sample.dxf (copied from
    /// librecad/res/dxf/dim_sample.dxf into the test resources).
    private func samplePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle"
        )
        return url.path
    }

    /// A fresh temp .dxf path in the system temp dir; the caller cleans it up.
    private func tempDXFPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        let name = "dxfwriter-test-\(UUID().uuidString).dxf"
        return dir.appendingPathComponent(name).path
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Per-kind tally over the supported set.

    private struct KindTally: Equatable {
        var line = 0, point = 0, circle = 0, arc = 0, ellipse = 0, polyline = 0
        /// The supported set the writer emits (spline/splinePoints excluded).
        var supportedTotal: Int { line + point + circle + arc + ellipse + polyline }
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
            case .spline, .splinePoints: break   // skipped by the writer
            case .text, .hatch, .solid: break    // display kinds, skipped by the writer
            }
        }
        return t
    }

    // MARK: - The key round-trip test.

    @Test("round-trips supported entity counts through read -> write -> read")
    func roundTripsSampleCounts() async throws {
        // First read: the source-of-truth supported-kind counts.
        let first = try await CADEngine.shared.readEntities(dxfPath: samplePath())
        let firstTally = tally(first.records)
        // The sample carries real supported geometry to round-trip.
        #expect(firstTally.supportedTotal > 0)
        #expect(firstTally.line >= 1)
        #expect(firstTally.circle >= 1)
        #expect(firstTally.arc >= 1)
        #expect(firstTally.polyline >= 1)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        // Write only the supported geometry (the reader already dropped the rest).
        let writeResult = try await CADEngine.shared.writeEntities(
            first.records, layers: first.layers, toPath: outPath
        )
        // Everything the writer received was supported except spline/splinePoints,
        // which dim_sample.dxf does not contain, so nothing should be skipped.
        #expect(writeResult.skipped == 0)
        #expect(FileManager.default.fileExists(atPath: outPath))

        // Re-read and compare the supported-kind tallies exactly.
        let second = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let secondTally = tally(second.records)

        #expect(secondTally.line == firstTally.line)
        #expect(secondTally.circle == firstTally.circle)
        #expect(secondTally.arc == firstTally.arc)
        #expect(secondTally.polyline == firstTally.polyline)
        #expect(secondTally.ellipse == firstTally.ellipse)
        #expect(secondTally.supportedTotal == firstTally.supportedTotal)
    }

    @Test("written file preserves the layer table")
    func roundTripsLayers() async throws {
        let first = try await CADEngine.shared.readEntities(dxfPath: samplePath())
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }
        _ = try await CADEngine.shared.writeEntities(
            first.records, layers: first.layers, toPath: outPath
        )
        let second = try await CADEngine.shared.readEntities(dxfPath: outPath)
        // Layer "0" must survive, and the named layers from the source should too.
        #expect(second.layers.contains("0"))
        for layer in first.layers.layers {
            #expect(second.layers.contains(layer.name),
                    "layer \(layer.name) missing after round-trip")
        }
    }

    // MARK: - Direct build -> write -> read geometry round-trip.

    @Test("a hand-built drawing round-trips geometry")
    func roundTripsBuiltGeometry() async throws {
        // Build value records directly (ids minted explicitly).
        let line = EntityRecord(
            id: EntityID(1),
            layer: LayerID("walls"),
            kind: .line(LineData(start: Vector(1, 2), end: Vector(10, 20)))
        )
        let circle = EntityRecord(
            id: EntityID(2),
            layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(5, 5), radius: 3.5))
        )
        let arc = EntityRecord(
            id: EntityID(3),
            layer: LayerID("0"),
            kind: .arc(ArcData(center: Vector(0, 0), radius: 2,
                               startAngle: 0, endAngle: .pi / 2))
        )
        let records = [line, circle, arc]

        var layers = LayerTable(layers: [Layer(name: "0"), Layer(name: "walls")],
                                activeLayerName: "0")
        _ = layers   // (table built explicitly to exercise the layer writer)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toPath: outPath
        )
        #expect(result.skipped == 0)
        #expect(result.written == 3)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let t = tally(back.records)
        #expect(t.line == 1)
        #expect(t.circle == 1)
        #expect(t.arc == 1)
        #expect(back.layers.contains("walls"))

        // Verify the actual geometry values survived (within tolerance).
        let tol = 1e-6
        for r in back.records {
            switch r.kind {
            case .line(let d):
                #expect(abs(d.start.x - 1) < tol)
                #expect(abs(d.start.y - 2) < tol)
                #expect(abs(d.end.x - 10) < tol)
                #expect(abs(d.end.y - 20) < tol)
            case .circle(let d):
                #expect(abs(d.center.x - 5) < tol)
                #expect(abs(d.center.y - 5) < tol)
                #expect(abs(d.radius - 3.5) < tol)
            case .arc(let d):
                #expect(abs(d.center.x) < tol)
                #expect(abs(d.center.y) < tol)
                #expect(abs(d.radius - 2) < tol)
                #expect(abs(d.startAngle) < tol)
                #expect(abs(d.endAngle - .pi / 2) < tol)
            default:
                break
            }
        }
    }

    @Test("a polyline with bulges round-trips")
    func roundTripsPolyline() async throws {
        let verts = [
            PolylineVertex(point: Vector(0, 0), bulge: 0),
            PolylineVertex(point: Vector(10, 0), bulge: 0.5),
            PolylineVertex(point: Vector(10, 10), bulge: 0),
        ]
        let poly = EntityRecord(
            id: EntityID(1),
            kind: .polyline(PolylineData(vertices: verts, closed: true))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        _ = try await CADEngine.shared.writeEntities(
            [poly], layers: LayerTable(), toPath: outPath
        )
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        let polys = back.records.compactMap { r -> PolylineData? in
            if case .polyline(let d) = r.kind { return d } else { return nil }
        }
        let d = try #require(polys.first, "polyline missing after round-trip")
        #expect(d.closed)
        #expect(d.vertices.count == verts.count)
        let tol = 1e-6
        for (a, b) in zip(d.vertices, verts) {
            #expect(abs(a.point.x - b.point.x) < tol)
            #expect(abs(a.point.y - b.point.y) < tol)
            #expect(abs(a.bulge - b.bulge) < tol)
        }
    }

    // MARK: - Skipped kinds are counted, not fatal.

    @Test("unsupported kinds are skipped and counted")
    func skipsUnsupportedKinds() async throws {
        let spline = EntityRecord(
            id: EntityID(1),
            kind: .spline(SplineData(
                degree: 3,
                controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0), Vector(3, 1)]
            ))
        )
        let line = EntityRecord(
            id: EntityID(2),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        )
        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await CADEngine.shared.writeEntities(
            [spline, line], layers: LayerTable(), toPath: outPath
        )
        #expect(result.skipped == 1)   // the spline
        #expect(result.written == 1)   // the line

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)
        #expect(tally(back.records).line == 1)
    }

    // MARK: - High-level save helper + error path.

    @MainActor
    @Test("writeDrawing saves a loaded drawing")
    func writeDrawingSaves() async throws {
        let drawing = try await loadDrawing(dxfPath: samplePath())
        let supportedBefore = drawing.entities.filter { isSupported($0) }.count
        #expect(supportedBefore > 0)

        let outPath = tempDXFPath()
        defer { removeFile(outPath) }

        let result = try await writeDrawing(drawing, toPath: outPath)
        #expect(result.written == supportedBefore)
        #expect(FileManager.default.fileExists(atPath: outPath))

        // The saved file re-opens as a non-empty drawing.
        let reopened = try await loadDrawing(dxfPath: outPath)
        #expect(reopened.count > 0)
    }

    @Test("empty path throws invalidPath")
    func emptyPathThrows() async throws {
        await #expect(throws: CADWriteError.invalidPath) {
            _ = try await CADEngine.shared.writeEntities(
                [], layers: LayerTable(), toPath: ""
            )
        }
    }

    // Whether a record's kind is in the writer's supported set.
    private func isSupported(_ r: EntityRecord) -> Bool {
        switch r.kind {
        case .line, .point, .circle, .arc, .ellipse, .polyline: return true
        case .spline, .splinePoints, .text, .hatch, .solid: return false
        }
    }
}
