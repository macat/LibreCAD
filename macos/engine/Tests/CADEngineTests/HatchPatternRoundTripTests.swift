//
//  HatchPatternRoundTripTests.swift
//  CADEngineTests
//
//  DXF round-trip tests for real hatch patterns (v5 WAVE-4a, feature F6):
//   - a pattern hatch's NAME + SCALE (code 41) + ANGLE (code 52) survive
//     write→reread;
//   - a bulged (arc) boundary edge round-trips its GEOMETRY (written as a DXF
//     arc edge, read back as a SINGLE bulged PolylineVertex preserving the arc —
//     the exact-bulge read path inverts the writer's DRW_Arc edge encoding).
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

    // MARK: - bulged boundary edge round-trips as a SINGLE bulged vertex (arc preserved)

    @Test("a bulged boundary edge round-trips as ONE bulged vertex (arc preserved, not tessellated)")
    func bulgedBoundaryRoundTrip() async throws {
        // A boundary with one semicircle edge (bulge = 1, 180°) from (0,0)→(10,0)
        // bowing up, then a straight return (10,0)→(0,0) — a half-disc. The arc
        // edge is authored as a real DRW_Arc on write and recovered EXACTLY as a
        // single bulged PolylineVertex on read (the inverse of that encoding), so
        // the loop reads back at its minimal vertex count.
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
        let loop = try #require(d.loops.first, "boundary loop missing after round-trip")

        // EXACT read-back: the arc edge + the straight return collapse to the SAME
        // minimal 2 vertices we authored — NOT a tessellated chord run.
        #expect(loop.count == ring.count, "expected the minimal 2-vertex loop, got \(loop.count)")

        // The arc edge survives as ONE vertex carrying the DXF bulge (≈ +1 for the
        // CCW-bowing semicircle); the straight return stays a plain (bulge 0) vertex.
        let arcVertex = try #require(
            loop.first { abs($0.bulge) > 1e-6 }, "expected exactly one bulged vertex")
        #expect(abs(arcVertex.bulge - 1) < 1e-6,
                "bulge should round-trip ≈ 1 (semicircle), got \(arcVertex.bulge)")
        #expect(loop.filter { abs($0.bulge) > 1e-6 }.count == 1,
                "only the arc edge should carry a bulge")
        // The arc edge's start vertex sits at the chord start; the loop's other
        // (straight) vertex is the chord end — both endpoints preserved.
        #expect(loop.contains { abs($0.point.x - 0) < 1e-6 && abs($0.point.y) < 1e-6 })
        #expect(loop.contains { abs($0.point.x - 10) < 1e-6 && abs($0.point.y) < 1e-6 })

        // The bulge resolves back to the same bowing arc: tessellating the
        // recovered loop reaches the radius-5 apex (~y=5), centered over x≈5, so
        // the arc geometry is reconstructed — not flattened to a chord.
        let samples = HatchBoundary.tessellate(loop, tolerance: 0.001)
        let maxY = samples.map(\.y).max() ?? 0
        #expect(abs(maxY - 5) < 0.05, "expected the arc to bow to y≈5, got \(maxY)")
        // The apex sits over the chord midpoint x≈5 (a sample near the top is
        // horizontally centered, proving the bow is the semicircle, not a chord).
        let apex = samples.max { $0.y < $1.y }
        #expect(apex.map { abs($0.x - 5) < 0.6 } ?? false,
                "expected the arc apex centered over x≈5, got \(String(describing: apex))")
    }
}
