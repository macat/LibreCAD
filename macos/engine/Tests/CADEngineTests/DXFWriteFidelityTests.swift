//
//  DXFWriteFidelityTests.swift
//  CADEngineTests
//
//  DXF-write fidelity tests for two related gaps (audit G6a + G6b):
//
//   - G6a — Hatch boundary-arc BULGE on WRITE. A hatch boundary loop with a bulged
//     (arc) segment must be WRITTEN as a real DXF ARC edge (DRW_Arc), NOT flattened
//     to a straight LINE chord, so other CAD tools read a true curved boundary. We
//     prove the written file actually carries an ARC entity inside the HATCH
//     boundary (raw-DXF inspection), and that the arc GEOMETRY round-trips on
//     re-read. (On our re-read the bridge currently tessellates the arc edge into
//     boundary sample points — the geometry survives; exact-bulge read-back is a
//     documented follow-up, blocked from being enabled here by a locked
//     non-owned round-trip test, HatchPatternRoundTripTests.)
//
//   - G6b — Leader annotation as a top-level DXF entity (best-effort). A `.leader`
//     carrying an attached TEXT/MTEXT annotation writes the annotation as an
//     INDEPENDENT top-level DXF entity, so OTHER CAD tools see the text (today an
//     imported leader's annotation is lost on DXF read). The libdxfrw limit: its
//     DXF leader writer (`dxfRW::writeLeader`) emits no code-340 annotation hard
//     reference, so the re-read annotation is a STANDALONE TEXT/MTEXT, not
//     re-attached to the leader — pinned below.
//
//  Uses the same DxfBridge write/read path as DXFWriterTests, into a temp file.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DXF write fidelity — hatch boundary arcs (G6a) + leader annotation (G6b)")
struct DXFWriteFidelityTests {

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dxfwritefidelity-\(UUID().uuidString).dxf").path
    }
    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func firstHatch(_ records: [EntityRecord]) -> HatchData? {
        for r in records { if case .hatch(let d) = r.kind { return d } }
        return nil
    }

    // MARK: - G6a: a bulged hatch boundary edge is WRITTEN as a real DXF ARC edge.

    @Test("G6a: a bulged hatch boundary edge is WRITTEN as a DXF ARC, not a flattened chord")
    func bulgedHatchBoundaryWrittenAsArcEdge() async throws {
        // A 2-vertex loop: a semicircle edge (bulge = 1 ⇒ 180°) from (0,0)→(10,0)
        // bowing up, with the implicit straight return closing the half-disc.
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
        #expect(w.skipped == 0)

        // KEY ASSERTION (G6a): the written file carries a real ARC boundary edge
        // inside the HATCH — the bulged segment was emitted as a DRW_Arc, NOT
        // flattened to a straight LINE chord. We parse the raw DXF group codes and
        // look, in the single hatch's body, for an arc-edge start/end angle (groups
        // 50 and 51) and a radius (group 40) — all absent from a pure LINE-chord
        // boundary (which writes only 72=1 with 10/20/11/21).
        let dxf = try String(contentsOfFile: path, encoding: .utf8)
        let hatchIdx = try #require(dxf.range(of: "HATCH"), "no HATCH in written file")
        let hatchBody = String(dxf[hatchIdx.lowerBound...])
        let codes = Set(
            hatchBody.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        )
        #expect(codes.contains("50"),
                "expected a HATCH arc-edge start angle (group 50) — a DRW_Arc edge, not a flattened chord")
        #expect(codes.contains("51"),
                "expected a HATCH arc-edge end angle (group 51) — a DRW_Arc edge")
        #expect(codes.contains("40"),
                "expected a HATCH arc-edge radius (group 40) — a DRW_Arc edge")

        // …and the arc GEOMETRY round-trips on re-read (the semicircle bow ~y=5
        // survives as boundary sample points — geometry preserved).
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let d = try #require(firstHatch(back.records), "hatch missing after round-trip")
        let pts = d.loops.first?.map(\.point) ?? []
        let maxY = pts.map(\.y).max() ?? 0
        #expect(maxY > 4, "expected the arc bow (~y=5) geometry to survive the round-trip")
    }

    @Test("G6a: a re-read bulged hatch still resolves to a filled region")
    func bulgedHatchStillResolves() async throws {
        let ring = [
            PolylineVertex(point: Vector(0, 0), bulge: 1),
            PolylineVertex(point: Vector(10, 0), bulge: 0),
        ]
        let hatch = EntityRecord(
            id: EntityID(3),
            kind: .hatch(HatchData(loops: [ring], solidFill: true)))
        let path = tempDXFPath()
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities([hatch], layers: LayerTable(), toPath: path)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let d = try #require(firstHatch(back.records))
        // The bulge resolves (bulge-aware tessellation) into a real bowed region:
        // the arc apex (~y=5) is reached when the boundary expands.
        let geo = EntityRecord(id: EntityID(99), kind: .hatch(d)).resolve(ResolveContext())
        #expect(!geo.fills.isEmpty, "a solid bulged hatch should resolve to a fill")
        let apexY = geo.fills.flatMap { $0.loops }.flatMap { $0 }.map(\.y).max() ?? 0
        #expect(apexY > 4, "expected the arc bow (~y=5) to survive resolve, got \(apexY)")
    }

    // MARK: - G6b: a leader's annotation is authored as a top-level DXF entity.

    /// A leader with an attached MTEXT annotation. Its annotation is NOT carried in
    /// the LEADER POD (DXF needs code 340, which libdxfrw can't write); instead the
    /// writer emits the annotation as an INDEPENDENT top-level MTEXT.
    private func leaderWithMTextAnnotation() -> EntityRecord {
        let annotation = EntityKind.mtext(MTextData(
            position: Vector(20, 10),
            height: 2.5,
            paragraphs: [MTextParagraph(inlines: [.run(TextRun(text: "CALLOUT"))])],
            rawCode: nil))
        return EntityRecord(
            id: EntityID(1),
            layer: LayerID("annot"),
            kind: .leader(LeaderData(
                vertices: [Vector(0, 0), Vector(10, 5), Vector(20, 10)],
                hasArrow: true, arrowSize: 2,
                annotation: annotation,
                styleName: "Standard")))
    }

    @Test("G6b: a leader's annotation is written as a top-level MTEXT other tools can see")
    func leaderAnnotationWrittenAsTopLevelEntity() async throws {
        let leader = leaderWithMTextAnnotation()
        let path = tempDXFPath()
        defer { removeFile(path) }

        // The leader (1) + its annotation (1) are BOTH emitted as top-level entities.
        let w = try await CADEngine.shared.writeEntities(
            [leader],
            layers: LayerTable(layers: [Layer(name: "0"), Layer(name: "annot")],
                               activeLayerName: "0"),
            toPath: path)
        #expect(w.written == 2, "leader + its annotation should both be written, got \(w.written)")
        #expect(w.skipped == 0)

        let back = try await CADEngine.shared.readEntities(dxfPath: path)

        // The leader survives.
        let leaders = back.records.compactMap { r -> LeaderData? in
            if case .leader(let d) = r.kind { return d } else { return nil }
        }
        let ld = try #require(leaders.first, "leader missing after round-trip")
        #expect(ld.vertices.count == 3)
        #expect(ld.hasArrow)

        // The annotation text is now VISIBLE as a standalone MTEXT — other CAD tools
        // (and our re-read) see the leader's "CALLOUT" text instead of losing it.
        let mtexts = back.records.compactMap { r -> MTextData? in
            if case .mtext(let d) = r.kind { return d } else { return nil }
        }
        let mt = try #require(mtexts.first, "leader annotation MTEXT missing after round-trip")
        let body = mt.paragraphs.flatMap { $0.inlines }.reduce(into: "") { acc, inline in
            if case .run(let run) = inline { acc += run.text }
        }
        #expect(body.contains("CALLOUT"), "expected the annotation text to survive, got '\(body)'")
        #expect(abs(mt.position.x - 20) < 1e-6 && abs(mt.position.y - 10) < 1e-6,
                "the annotation keeps its insertion point (leader's last vertex)")
    }

    @Test("G6b: libdxfrw limit — the re-read annotation is NOT re-attached to the leader")
    func leaderAnnotationNotReattachedThroughDXF() async throws {
        // DOCUMENTS the libdxfrw code-340 limit (DRW_Leader::annotHandle is never
        // emitted by dxfRW::writeLeader). The annotation round-trips as a SEPARATE
        // top-level MTEXT, so on re-read the leader's own `annotation` is nil — it
        // is NOT re-attached via a DXF hard reference. This is the honest, pinned
        // best-effort state: the TEXT survives for all tools, but the leader→text
        // hard reference cannot be authored without modifying the vendored library.
        let leader = leaderWithMTextAnnotation()
        let path = tempDXFPath()
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities(
            [leader],
            layers: LayerTable(layers: [Layer(name: "0"), Layer(name: "annot")],
                               activeLayerName: "0"),
            toPath: path)
        let back = try await CADEngine.shared.readEntities(dxfPath: path)
        let ld = try #require(back.records.compactMap { r -> LeaderData? in
            if case .leader(let d) = r.kind { return d } else { return nil }
        }.first)
        #expect(ld.annotation == nil,
                "the libdxfrw writeLeader has no code-340 path, so the re-read leader's annotation is detached")
    }

    @Test("G6b: a bare leader (no annotation) writes exactly one entity")
    func bareLeaderWritesOneEntity() async throws {
        let leader = EntityRecord(
            id: EntityID(1),
            kind: .leader(LeaderData(
                vertices: [Vector(0, 0), Vector(5, 5)], hasArrow: true, arrowSize: 2)))
        let path = tempDXFPath()
        defer { removeFile(path) }
        let w = try await CADEngine.shared.writeEntities([leader], layers: LayerTable(), toPath: path)
        // No annotation ⇒ no extra entity emitted.
        #expect(w.written == 1)
        #expect(w.skipped == 0)
    }
}
