//
//  HatchPatternRoundTripTests.swift
//  CADEngineTests
//
//  DXF round-trip tests for real hatch patterns (v5 WAVE-4a, feature F6):
//   - a pattern hatch's NAME + SCALE (code 41) + ANGLE (code 52) survive
//     write→reread;
//   - a bulged (arc) boundary edge round-trips its GEOMETRY (written as a DXF
//     arc edge, read back as tessellated boundary points enclosing the arc).
//
//  Uses the same DxfBridge write/read path as DXFWriterTests, into a temp file.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Hatch patterns — DXF round-trip (W4a F6)")
struct HatchPatternRoundTripTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hatchpat-test-\(UUID().uuidString).dxf").path
    }
    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func firstHatch(_ records: [EntityRecord]) -> HatchData? {
        for r in records { if case .hatch(let d) = r.kind { return d } }
        return nil
    }

    private var squareRing: [PolylineVertex] {
        [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ]
    }

    // MARK: - pattern name + scale + angle round-trip

    @Test("a pattern hatch round-trips its name, scale (41) and angle (52)")
    func patternNameScaleAngleRoundTrip() async throws {
        let hatch = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false,
                                   patternName: "ANSI31",
                                   patternScale: 2.5,
                                   patternAngle: .pi / 6)))   // 30°
        let path = tempDXFPath()
        defer { removeFile(path) }

        let w = try await CADEngine.shared.writeEntities([hatch], layers: LayerTable(), toPath: path)
        #expect(w.written == 1)
        #expect(w.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let d = try #require(firstHatch(back.records), "hatch missing after round-trip")
        #expect(d.solidFill == false)
        #expect(d.patternName?.uppercased() == "ANSI31")
        #expect(abs(d.patternScale - 2.5) < 1e-6)
        // Angle round-trips through DXF degrees (code 52) ⇒ small tolerance.
        #expect(abs(d.patternAngle - .pi / 6) < 1e-6)
    }

    @Test("a re-read pattern hatch still resolves to pattern lines")
    func roundTrippedPatternResolvesToLines() async throws {
        let hatch = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: false, patternName: "ANSI31")))
        let path = tempDXFPath()
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities([hatch], layers: LayerTable(), toPath: path)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let d = try #require(firstHatch(back.records))
        let geo = EntityRecord(id: EntityID(9), kind: .hatch(d)).resolve(ResolveContext())
        #expect(geo.fills.isEmpty)
        #expect(!geo.polylines.isEmpty)
    }

    // MARK: - solid hatch keeps native scale (no spurious 41/52 on read)

    @Test("a solid hatch round-trips with the default scale/angle")
    func solidHatchDefaultsRoundTrip() async throws {
        let hatch = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [squareRing], solidFill: true, patternName: "SOLID")))
        let path = tempDXFPath()
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities([hatch], layers: LayerTable(), toPath: path)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let d = try #require(firstHatch(back.records))
        #expect(d.solidFill)
        #expect(abs(d.patternScale - 1) < 1e-9)
        #expect(abs(d.patternAngle) < 1e-9)
    }

    // MARK: - bulged boundary edge round-trips as an arc

    @Test("a bulged boundary edge round-trips its arc geometry (written as a DXF arc)")
    func bulgedBoundaryRoundTrip() async throws {
        // A boundary with one semicircle edge (bulge = 1, 180°) from (0,0)→(10,0)
        // bowing up, then a straight return (10,0)→(0,0) — a half-disc.
        let ring = [
            PolylineVertex(point: Vector(0, 0), bulge: 1),
            PolylineVertex(point: Vector(10, 0), bulge: 0),
        ]
        let hatch = EntityRecord(
            id: EntityID(1),
            kind: .hatch(HatchData(loops: [ring], solidFill: true)))
        let path = tempDXFPath()
        defer { removeFile(path) }

        let w = try await CADEngine.shared.writeEntities([hatch], layers: LayerTable(), toPath: path)
        #expect(w.written == 1)

        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let d = try #require(firstHatch(back.records), "hatch missing after round-trip")
        let pts = d.loops.first?.map(\.point) ?? []
        // The arc edge was written as a DXF arc and read back tessellated: many
        // boundary points, and the bow reaches y ≈ 5 (radius-5 semicircle).
        #expect(pts.count > 4)
        let maxY = pts.map(\.y).max() ?? 0
        #expect(maxY > 4, "expected the arc bow (~y=5) to survive the round-trip")
        // The chord endpoints survive too.
        #expect(pts.contains { abs($0.x - 0) < 0.2 && abs($0.y) < 0.2 })
        #expect(pts.contains { abs($0.x - 10) < 0.2 && abs($0.y) < 0.2 })
    }
}
