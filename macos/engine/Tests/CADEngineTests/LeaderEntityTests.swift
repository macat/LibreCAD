//
//  LeaderEntityTests.swift
//  CADEngineTests
//
//  Tests for the LEADER annotation-callout entity (`.leader`, feature-catalog #F2):
//   - resolve() of a leader → the polyline PATH + an arrowhead FILL at the first
//     vertex (the shared dimension-arrowhead helper) + the attached text strokes
//     via the SAME `.text` resolve path (no second text path);
//   - a bare (no-annotation) leader resolves to path + arrow only;
//   - a degenerate (< 2 vertex) leader resolves to just its annotation (or empty),
//     matching dim_sample.dxf's two zero-vertex LEADERs;
//   - boundingBox() is finite and encloses the path + annotation;
//   - EntityTransform moves the vertices, scales the arrow, and transforms the
//     annotation through the SAME text-transform path;
//   - Snapping endpoints snap to each path vertex; middles to each leg midpoint;
//   - InspectorEdits set arrow size / arrow flag / vertices / style name;
//   - a DXF LEADER round-trips (write → read with its path + arrow flag);
//   - dim_sample.dxf's 2 LEADER entities import as `.leader` (no warning).
//
//  Uniquely namespaced so it does not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("leader annotation-callout entity")
struct LeaderEntityTests {

    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)

    /// Locates `standard.lff` (bundle first, else the repo support path).
    private func standardFontURL() throws -> URL {
        if let bundled = Bundle.module.url(forResource: "standard", withExtension: "lff") {
            return bundled
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // CADEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // <repo>
        let url = repoRoot.appendingPathComponent("librecad/support/fonts/standard.lff")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "standard.lff fixture not found at \(url.path)")
        return url
    }

    /// A resolve context with a real `.lff` font provider, so the attached text
    /// actually produces stroke geometry (otherwise text resolves to empty).
    private func textCtx() throws -> ResolveContext {
        let provider = StrokeFontProvider()
        provider.registerFont(at: try standardFontURL(), name: "standard")
        provider.registerFont(at: try standardFontURL(), name: "")
        return ResolveContext(tessellationTolerance: 0.01, fontProvider: provider)
    }

    // MARK: - Resolve

    @Test("a leader resolves to a path polyline + an arrowhead fill")
    func resolvesPathAndArrow() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(14, 4)],
                           hasArrow: true, arrowSize: 2)
        let geo = EntityKind.leader(d).resolve(pen: pen, ctx: .default)
        // ONE path polyline of the 3 vertices.
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].points.count == 3)
        #expect(abs(geo.polylines[0].points[0].x - 0) < 1e-9)
        #expect(abs(geo.polylines[0].points[2].x - 14) < 1e-9)
        // ONE arrowhead fill (a triangle) with its tip at the FIRST vertex.
        #expect(geo.fills.count == 1)
        let tri = geo.fills[0].loops[0]
        #expect(tri.count == 3)
        #expect(abs(tri[0].x - 0) < 1e-9 && abs(tri[0].y - 0) < 1e-9)   // tip == first vertex
    }

    @Test("a leader without an arrow resolves to the path only (no fill)")
    func resolvesNoArrow() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(5, 5)], hasArrow: false)
        let geo = EntityKind.leader(d).resolve(pen: pen, ctx: .default)
        #expect(geo.polylines.count == 1)
        #expect(geo.fills.isEmpty)
    }

    @Test("a leader's attached text resolves through the SAME .text path")
    func resolvesAttachedText() throws {
        let annotation = EntityKind.text(TextData(position: Vector(10, 0), height: 2.5,
                                                  text: "OK", styleName: "standard"))
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                           hasArrow: true, arrowSize: 2, annotation: annotation)
        let ctx = try textCtx()
        let leaderGeo = EntityKind.leader(d).resolve(pen: pen, ctx: ctx)
        // The standalone text's geometry, resolved through the SAME shared path.
        let textGeo = annotation.resolve(pen: pen, ctx: ctx)
        let textPieces = textGeo.polylines.count + textGeo.fills.count
        #expect(textPieces > 0)   // the font provider produced real glyph geometry
        // The leader carries the path (1) + arrow fill (1) + every text piece.
        #expect(leaderGeo.polylines.count + leaderGeo.fills.count
                == 2 + textPieces)
    }

    @Test("a degenerate (zero-vertex) leader resolves to just its annotation")
    func degenerateResolvesAnnotationOnly() throws {
        // The dim_sample.dxf shape: a leader with NO path vertices.
        let annotation = EntityKind.text(TextData(position: Vector(0, 0), height: 1,
                                                  text: "x", styleName: "standard"))
        let d = LeaderData(vertices: [], hasArrow: true, arrowSize: 1, annotation: annotation)
        let ctx = try textCtx()
        let geo = EntityKind.leader(d).resolve(pen: pen, ctx: ctx)
        // No path / arrow (no segment), but the annotation still resolves.
        let textGeo = annotation.resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == textGeo.polylines.count)
        #expect(geo.fills.count == textGeo.fills.count)
    }

    @Test("a bare degenerate leader resolves to empty geometry (no crash)")
    func bareDegenerateEmpty() {
        let d = LeaderData(vertices: [Vector(1, 1)], hasArrow: true)   // 1 vertex, no annotation
        let geo = EntityKind.leader(d).resolve(pen: pen, ctx: .default)
        #expect(geo.polylines.isEmpty && geo.fills.isEmpty)
    }

    @Test("a leader with a non-positive arrow size falls back to the default arrow")
    func arrowSizeFallback() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0)], hasArrow: true, arrowSize: 0)
        let geo = EntityKind.leader(d).resolve(pen: pen, ctx: .default)
        // Still draws an arrowhead (using the default size), so a fill is present.
        #expect(geo.fills.count == 1)
    }

    // MARK: - Bounding box

    @Test("a leader's bounding box is finite and encloses its path")
    func boundingBoxEnclosesPath() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 5)])
        let box = EntityKind.leader(d).boundingBox()
        #expect(box.min.x.isFinite && box.max.y.isFinite)
        #expect(box.min.x <= 0 + 1e-9 && box.max.x >= 10 - 1e-9)
        #expect(box.min.y <= 0 + 1e-9 && box.max.y >= 5 - 1e-9)
    }

    @Test("a degenerate leader's bounding box collapses to a valid point")
    func degenerateBoundingBoxValid() {
        let d = LeaderData(vertices: [], hasArrow: true)
        let box = EntityKind.leader(d).boundingBox()
        #expect(box.min.x.isFinite && box.min.y.isFinite)
    }

    // MARK: - Transform

    @Test("translating a leader moves every vertex")
    func translateMovesVertices() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0)], arrowSize: 2)
        let t = Affine2D.translation(Vector(5, 7))
        guard case .leader(let r) = EntityKind.leader(d).transformed(by: t) else {
            Issue.record("not a leader"); return
        }
        #expect(abs(r.vertices[0].x - 5) < 1e-9 && abs(r.vertices[0].y - 7) < 1e-9)
        #expect(abs(r.vertices[1].x - 15) < 1e-9 && abs(r.vertices[1].y - 7) < 1e-9)
        #expect(abs(r.arrowSize - 2) < 1e-9)   // unchanged by a pure translation
    }

    @Test("scaling a leader scales the vertices AND the arrow size")
    func scaleScalesArrow() {
        let d = LeaderData(vertices: [Vector(2, 0), Vector(4, 0)], arrowSize: 2)
        let t = Affine2D.scale(factor: 3, about: Vector(0, 0))
        guard case .leader(let r) = EntityKind.leader(d).transformed(by: t) else {
            Issue.record("not a leader"); return
        }
        #expect(abs(r.vertices[0].x - 6) < 1e-9)
        #expect(abs(r.vertices[1].x - 12) < 1e-9)
        #expect(abs(r.arrowSize - 6) < 1e-9)   // 2 * 3
    }

    @Test("transforming a leader transforms its attached annotation too")
    func transformTransformsAnnotation() {
        let annotation = EntityKind.text(TextData(position: Vector(10, 0), height: 2.5, text: "A"))
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0)], annotation: annotation)
        let t = Affine2D.translation(Vector(0, 100))
        guard case .leader(let r) = EntityKind.leader(d).transformed(by: t),
              let ann = r.annotation, case .text(let td) = ann else {
            Issue.record("annotation not transformed"); return
        }
        #expect(abs(td.position.y - 100) < 1e-9)   // the text moved with the leader
    }

    // MARK: - Snapping

    @Test("a leader's snap endpoints are its path vertices")
    func snapEndpointsAreVertices() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(14, 4)])
        let e = EntityRecord(id: EntityID(1), kind: .leader(d))
        let eps = Snapping.endpoints(of: e)
        #expect(eps.count == 3)
        #expect(abs(eps[0].x - 0) < 1e-9)
        #expect(abs(eps[2].x - 14) < 1e-9 && abs(eps[2].y - 4) < 1e-9)
    }

    @Test("a leader's snap middles are its leg midpoints")
    func snapMiddlesAreLegMids() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 4)])
        let e = EntityRecord(id: EntityID(1), kind: .leader(d))
        let mids = Snapping.middles(of: e, ctx: .default)
        #expect(mids.count == 2)
        #expect(abs(mids[0].x - 5) < 1e-9 && abs(mids[0].y - 0) < 1e-9)
        #expect(abs(mids[1].x - 10) < 1e-9 && abs(mids[1].y - 2) < 1e-9)
    }

    @Test("a leader is a terminal kind for contour traversal (no free ends)")
    func leaderIsTerminal() {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0)])
        let e = EntityRecord(id: EntityID(1), kind: .leader(d))
        #expect(SelectionTraversal.endpoints(of: e).isEmpty)
    }

    // MARK: - InspectorEdits

    @Test("InspectorEdits set the leader's arrow size / arrow flag / style / vertices")
    func inspectorEdits() {
        let base = EntityKind.leader(LeaderData(vertices: [Vector(0, 0), Vector(1, 0)],
                                                hasArrow: true, arrowSize: 2))
        guard case .leader(let a) = InspectorEdits.setLeaderArrowSize(base, 5) else {
            Issue.record("arrow size edit failed"); return
        }
        #expect(abs(a.arrowSize - 5) < 1e-9)

        guard case .leader(let b) = InspectorEdits.setLeaderHasArrow(base, false) else {
            Issue.record("arrow flag edit failed"); return
        }
        #expect(b.hasArrow == false)

        guard case .leader(let c) = InspectorEdits.setLeaderStyleName(base, "ISO") else {
            Issue.record("style edit failed"); return
        }
        #expect(c.styleName == "ISO")

        let pts = [Vector(0, 0), Vector(2, 2), Vector(4, 0)]
        guard case .leader(let v) = InspectorEdits.setLeaderVertices(base, pts) else {
            Issue.record("vertices edit failed"); return
        }
        #expect(v.vertices.count == 3)

        // A non-leader kind is a no-op.
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        if case .line = InspectorEdits.setLeaderArrowSize(line, 9) {} else {
            Issue.record("non-leader edit should be a no-op")
        }
    }

    // MARK: - DXF round-trip

    @Test("a DXF LEADER round-trips with its path vertices + arrow flag")
    func dxfLeaderRoundTrips() async throws {
        let d = LeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(13, 3)],
                           hasArrow: true, arrowSize: 2.5, annotation: nil, styleName: "Standard")
        let leader = EntityRecord(id: EntityID(1), layer: LayerID("0"), kind: .leader(d))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("leader-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities([leader], layers: layers, toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        let leaders = back.records.compactMap { r -> LeaderData? in
            if case .leader(let ld) = r.kind { return ld } else { return nil }
        }
        #expect(leaders.count == 1)
        let r = try #require(leaders.first)
        #expect(r.vertices.count == 3)
        #expect(abs(r.vertices[0].x - 0) < 1e-6 && abs(r.vertices[0].y - 0) < 1e-6)
        #expect(abs(r.vertices[2].x - 13) < 1e-6 && abs(r.vertices[2].y - 3) < 1e-6)
        #expect(r.hasArrow == true)
        // The read leader has no inline annotation (DXF stores it as a separate
        // hard-referenced entity, which the bridge does not collect).
        #expect(r.annotation == nil)
        // No skipped-entity warning for the written LEADER.
        #expect(!back.warnings.contains { $0.contains("LEADER") })
    }

    // MARK: - dim_sample.dxf import (the brief's done-criterion)

    @MainActor
    @Test("dim_sample.dxf imports its 2 LEADER entities as .leader with no warning")
    func dimSampleLeadersImport() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle")
        let result = try await CADEngine.shared.readEntities(dxfPath: url.path)

        let leaders = result.records.filter {
            if case .leader = $0.kind { return true } else { return false }
        }
        #expect(leaders.count == 2)
        // The file's two LEADERs carry NO path vertices (a degenerate, drawn-nothing
        // callout) but still import + round-trip.
        for r in leaders {
            guard case .leader(let d) = r.kind else { continue }
            #expect(d.vertices.isEmpty)
            #expect(d.hasArrow == true)
        }
        // The LEADER warning is gone — dim_sample's last read warning is closed.
        #expect(!result.warnings.contains { $0.contains("LEADER") })
    }
}
