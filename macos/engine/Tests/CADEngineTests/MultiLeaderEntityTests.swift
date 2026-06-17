//
//  MultiLeaderEntityTests.swift
//  CADEngineTests
//
//  Tests for the MULTILEADER annotation-callout entity (`.multileader`), cloned
//  from `.leader` (LeaderEntityTests) and adding the landing ("dogleg") tail +
//  the two new defining fields (`landingDistance`, `doglegEnabled`). ML-W1 builds
//  the entity UNWIRED (no ToolKind / no DXF write / no inline inspector editing —
//  those are ML-W2/W3/W4); it must EXIST and resolve / transform / snap / Codable-
//  round-trip:
//   - resolve() → the leg polyline PATH + an arrowhead FILL at the first vertex
//     (the shared dimension-arrowhead helper) + a LANDING tail polyline (when
//     `doglegEnabled`) + the attached text via the SAME `.text` resolve path;
//   - the landing tail is OMITTED when `doglegEnabled == false`;
//   - a degenerate (< 2 vertex) multileader resolves to just its annotation;
//   - boundingBox() is finite and encloses the leg + landing + annotation;
//   - EntityTransform moves the leg vertices, scales the arrow + landing distance,
//     and transforms the annotation through the SAME text-transform path;
//   - Snapping endpoints snap to each leg vertex PLUS the landing end; middles to
//     each leg midpoint PLUS the landing midpoint;
//   - Codable round-trips incl. the 2 new fields, and OLD JSON without them decodes
//     to the defaults (additive back-compat);
//   - a multileader is a terminal kind for contour traversal (no free ends).
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

@Suite("multileader annotation-callout entity")
struct MultiLeaderEntityTests {

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

    @Test("a multileader resolves to a leg polyline + an arrowhead fill (+ landing)")
    func resolvesLegArrowAndLanding() {
        // doglegEnabled with a positive landingDistance, no annotation → the landing
        // extends the last leg segment (so its direction is well-defined).
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(14, 4)],
                                hasArrow: true, arrowSize: 2,
                                landingDistance: 3, doglegEnabled: true)
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: .default)
        // ONE leg polyline of the 3 vertices + ONE landing polyline (2 points).
        #expect(geo.polylines.count == 2)
        let leg = geo.polylines[0]
        #expect(leg.points.count == 3)
        #expect(abs(leg.points[0].x - 0) < 1e-9)
        #expect(abs(leg.points[2].x - 14) < 1e-9)
        // The landing starts at the LAST leg vertex and is `landingDistance` long.
        let landing = geo.polylines[1]
        #expect(landing.points.count == 2)
        #expect(abs(landing.points[0].x - 14) < 1e-9 && abs(landing.points[0].y - 4) < 1e-9)
        let landLen = (landing.points[1] - landing.points[0]).magnitude
        #expect(abs(landLen - 3) < 1e-6)
        // ONE arrowhead fill (a triangle) with its tip at the FIRST vertex.
        #expect(geo.fills.count == 1)
        let tri = geo.fills[0].loops[0]
        #expect(tri.count == 3)
        #expect(abs(tri[0].x - 0) < 1e-9 && abs(tri[0].y - 0) < 1e-9)   // tip == first vertex
    }

    @Test("a multileader's landing aims at the annotation anchor")
    func landingAimsAtAnnotation() {
        // Last leg vertex at (10,0); annotation anchored at (10,5) → the landing
        // points straight up toward the text, length == landingDistance.
        let annotation = EntityKind.text(TextData(position: Vector(10, 5), height: 2.5, text: "A"))
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                hasArrow: false, annotation: annotation,
                                landingDistance: 2, doglegEnabled: true)
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: .default)
        // The font-less ctx resolves the text to nothing, so polylines are leg(1) +
        // landing(1) only.
        #expect(geo.polylines.count == 2)
        let landing = geo.polylines[1]
        #expect(abs(landing.points[0].x - 10) < 1e-9 && abs(landing.points[0].y - 0) < 1e-9)
        // Aims toward (10,5): straight up, 2 units → ends at (10,2).
        #expect(abs(landing.points[1].x - 10) < 1e-6 && abs(landing.points[1].y - 2) < 1e-6)
    }

    @Test("disabling the dogleg omits the landing segment")
    func doglegDisabledOmitsLanding() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(14, 4)],
                                hasArrow: true, arrowSize: 2,
                                landingDistance: 3, doglegEnabled: false)
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: .default)
        // Just the leg polyline (no landing) + the arrow fill.
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].points.count == 3)
        #expect(geo.fills.count == 1)
    }

    @Test("a zero landing distance omits the landing segment")
    func zeroLandingOmitsLanding() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                hasArrow: false, landingDistance: 0, doglegEnabled: true)
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: .default)
        #expect(geo.polylines.count == 1)   // leg only
        #expect(geo.fills.isEmpty)
    }

    @Test("a multileader's attached text resolves through the SAME .text path")
    func resolvesAttachedText() throws {
        let annotation = EntityKind.text(TextData(position: Vector(10, 0), height: 2.5,
                                                  text: "OK", styleName: "standard"))
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                hasArrow: true, arrowSize: 2, annotation: annotation,
                                landingDistance: 2, doglegEnabled: true)
        let ctx = try textCtx()
        let mlGeo = EntityKind.multileader(d).resolve(pen: pen, ctx: ctx)
        // The standalone text's geometry, resolved through the SAME shared path.
        let textGeo = annotation.resolve(pen: pen, ctx: ctx)
        let textPieces = textGeo.polylines.count + textGeo.fills.count
        #expect(textPieces > 0)   // the font provider produced real glyph geometry
        // The multileader carries the leg (1) + landing (1) + arrow fill (1) + every
        // text piece.
        #expect(mlGeo.polylines.count + mlGeo.fills.count == 3 + textPieces)
    }

    @Test("a degenerate (zero-vertex) multileader resolves to just its annotation")
    func degenerateResolvesAnnotationOnly() throws {
        let annotation = EntityKind.text(TextData(position: Vector(0, 0), height: 1,
                                                  text: "x", styleName: "standard"))
        let d = MultiLeaderData(vertices: [], hasArrow: true, arrowSize: 1,
                                annotation: annotation)
        let ctx = try textCtx()
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: ctx)
        // No leg / landing / arrow (no segment), but the annotation still resolves.
        let textGeo = annotation.resolve(pen: pen, ctx: ctx)
        #expect(geo.polylines.count == textGeo.polylines.count)
        #expect(geo.fills.count == textGeo.fills.count)
    }

    @Test("a bare degenerate multileader resolves to empty geometry (no crash)")
    func bareDegenerateEmpty() {
        let d = MultiLeaderData(vertices: [Vector(1, 1)], hasArrow: true)   // 1 vertex
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: .default)
        #expect(geo.polylines.isEmpty && geo.fills.isEmpty)
    }

    @Test("a non-positive arrow size falls back to the default arrow")
    func arrowSizeFallback() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                hasArrow: true, arrowSize: 0, doglegEnabled: false)
        let geo = EntityKind.multileader(d).resolve(pen: pen, ctx: .default)
        // Still draws an arrowhead (using the default size), so a fill is present.
        #expect(geo.fills.count == 1)
    }

    // MARK: - Bounding box

    @Test("a multileader's bounding box is finite and encloses its leg + landing")
    func boundingBoxEnclosesLegAndLanding() {
        // Leg ends at (10,5); a 4-unit landing extending the last segment upward
        // reaches (10,9), so the box's top must include y == 9.
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 5)],
                                hasArrow: false, landingDistance: 4, doglegEnabled: true)
        let box = EntityKind.multileader(d).boundingBox()
        #expect(box.min.x.isFinite && box.max.y.isFinite)
        #expect(box.min.x <= 0 + 1e-9 && box.max.x >= 10 - 1e-9)
        #expect(box.min.y <= 0 + 1e-9 && box.max.y >= 9 - 1e-6)   // landing tail end
    }

    @Test("a degenerate multileader's bounding box collapses to a valid point")
    func degenerateBoundingBoxValid() {
        let d = MultiLeaderData(vertices: [], hasArrow: true)
        let box = EntityKind.multileader(d).boundingBox()
        #expect(box.min.x.isFinite && box.min.y.isFinite)
    }

    // MARK: - Transform

    @Test("translating a multileader moves every leg vertex")
    func translateMovesVertices() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                arrowSize: 2, landingDistance: 3)
        let t = Affine2D.translation(Vector(5, 7))
        guard case .multileader(let r) = EntityKind.multileader(d).transformed(by: t) else {
            Issue.record("not a multileader"); return
        }
        #expect(abs(r.vertices[0].x - 5) < 1e-9 && abs(r.vertices[0].y - 7) < 1e-9)
        #expect(abs(r.vertices[1].x - 15) < 1e-9 && abs(r.vertices[1].y - 7) < 1e-9)
        #expect(abs(r.arrowSize - 2) < 1e-9)        // unchanged by a pure translation
        #expect(abs(r.landingDistance - 3) < 1e-9)  // unchanged by a pure translation
        #expect(r.doglegEnabled == true)            // size-independent flag preserved
    }

    @Test("scaling a multileader scales the vertices, arrow size AND landing distance")
    func scaleScalesArrowAndLanding() {
        let d = MultiLeaderData(vertices: [Vector(2, 0), Vector(4, 0)],
                                arrowSize: 2, landingDistance: 3)
        let t = Affine2D.scale(factor: 3, about: Vector(0, 0))
        guard case .multileader(let r) = EntityKind.multileader(d).transformed(by: t) else {
            Issue.record("not a multileader"); return
        }
        #expect(abs(r.vertices[0].x - 6) < 1e-9)
        #expect(abs(r.vertices[1].x - 12) < 1e-9)
        #expect(abs(r.arrowSize - 6) < 1e-9)        // 2 * 3
        #expect(abs(r.landingDistance - 9) < 1e-9)  // 3 * 3
    }

    @Test("rotating a multileader rotates its leg vertices")
    func rotateRotatesVertices() {
        // A 90° CCW rotation about the origin maps (10,0) → (0,10).
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)], doglegEnabled: false)
        let t = Affine2D.rotation(angle: .pi / 2, about: Vector(0, 0))
        guard case .multileader(let r) = EntityKind.multileader(d).transformed(by: t) else {
            Issue.record("not a multileader"); return
        }
        #expect(abs(r.vertices[1].x - 0) < 1e-6 && abs(r.vertices[1].y - 10) < 1e-6)
    }

    @Test("transforming a multileader transforms its attached annotation too")
    func transformTransformsAnnotation() {
        let annotation = EntityKind.text(TextData(position: Vector(10, 0), height: 2.5, text: "A"))
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)], annotation: annotation)
        let t = Affine2D.translation(Vector(0, 100))
        guard case .multileader(let r) = EntityKind.multileader(d).transformed(by: t),
              let ann = r.annotation, case .text(let td) = ann else {
            Issue.record("annotation not transformed"); return
        }
        #expect(abs(td.position.y - 100) < 1e-9)   // the text moved with the multileader
    }

    // MARK: - Snapping

    @Test("snap endpoints are the leg vertices plus the landing end")
    func snapEndpointsAreVerticesPlusLanding() {
        // Leg (0,0)→(10,0); a 2-unit landing extending the last segment → ends (12,0).
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                landingDistance: 2, doglegEnabled: true)
        let e = EntityRecord(id: EntityID(1), kind: .multileader(d))
        let eps = Snapping.endpoints(of: e)
        #expect(eps.count == 3)                                       // 2 leg + 1 landing end
        #expect(abs(eps[0].x - 0) < 1e-9)
        #expect(abs(eps[1].x - 10) < 1e-9)
        #expect(abs(eps[2].x - 12) < 1e-6 && abs(eps[2].y - 0) < 1e-6)
    }

    @Test("snap endpoints omit the landing end when the dogleg is off")
    func snapEndpointsNoLandingWhenDoglegOff() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(14, 4)],
                                landingDistance: 3, doglegEnabled: false)
        let e = EntityRecord(id: EntityID(1), kind: .multileader(d))
        let eps = Snapping.endpoints(of: e)
        #expect(eps.count == 3)   // just the 3 leg vertices
    }

    @Test("snap middles are the leg midpoints plus the landing midpoint")
    func snapMiddlesAreLegMidsPlusLanding() {
        // Leg (0,0)→(10,0)→(10,4); a 2-unit landing extending the last segment up
        // → from (10,4) to (10,6), midpoint (10,5).
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(10, 4)],
                                landingDistance: 2, doglegEnabled: true)
        let e = EntityRecord(id: EntityID(1), kind: .multileader(d))
        let mids = Snapping.middles(of: e, ctx: .default)
        #expect(mids.count == 3)
        #expect(abs(mids[0].x - 5) < 1e-9 && abs(mids[0].y - 0) < 1e-9)
        #expect(abs(mids[1].x - 10) < 1e-9 && abs(mids[1].y - 2) < 1e-9)
        #expect(abs(mids[2].x - 10) < 1e-6 && abs(mids[2].y - 5) < 1e-6)   // landing mid
    }

    @Test("a multileader is a terminal kind for contour traversal (no free ends)")
    func multiLeaderIsTerminal() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)])
        let e = EntityRecord(id: EntityID(1), kind: .multileader(d))
        #expect(SelectionTraversal.endpoints(of: e).isEmpty)
    }

    // MARK: - Stretch

    @Test("a multileader stretches (whole-translates) when a leg vertex is in-window")
    func stretchWholeTranslates() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)], landingDistance: 2)
        // A window enclosing only the first vertex.
        let window = AABB(min: Vector(-1, -1), max: Vector(1, 1))
        guard let out = StretchTool.stretch(.multileader(d), window: window, delta: Vector(0, 5)),
              case .multileader(let r) = out else {
            Issue.record("multileader stretch did not whole-translate"); return
        }
        // The WHOLE entity translated by the delta (best-effort composite stretch).
        #expect(abs(r.vertices[0].y - 5) < 1e-9)
        #expect(abs(r.vertices[1].y - 5) < 1e-9)
    }

    @Test("a multileader is unchanged when no defining point is in-window")
    func stretchNoOpOutsideWindow() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)])
        let window = AABB(min: Vector(100, 100), max: Vector(200, 200))
        #expect(StretchTool.stretch(.multileader(d), window: window, delta: Vector(0, 5)) == nil)
    }

    // MARK: - Purge (referenced dim-style names)

    @Test("a multileader's style name is collected as a used dim-style")
    func styleNameUsedForPurge() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(1, 0)], styleName: "MLSTYLE")
        let rec = EntityRecord(id: EntityID(1), kind: .multileader(d))
        let used = Purge.usedDimStyleNames(in: [rec])
        #expect(used.contains("MLSTYLE"))
    }

    // MARK: - Quick-select (deferred → maps to the leader tag)

    @Test("a multileader's quick-select tag is .leader (MLEADER deferred from QS v1)")
    func quickSelectTagIsLeader() {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(1, 0)])
        #expect(QuickSelectKind.tag(of: .multileader(d)) == .leader)
    }

    // MARK: - Codable

    @Test("a multileader Codable round-trips including the 2 new fields")
    func codableRoundTrip() throws {
        let annotation = EntityKind.text(TextData(position: Vector(10, 0), height: 2.5, text: "A"))
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0), Vector(14, 4)],
                                hasArrow: true, arrowSize: 2.5, annotation: annotation,
                                styleName: "MLSTYLE", landingDistance: 3.5, doglegEnabled: false)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(MultiLeaderData.self, from: data)
        #expect(back.vertices.count == 3)
        #expect(abs(back.vertices[2].x - 14) < 1e-9 && abs(back.vertices[2].y - 4) < 1e-9)
        #expect(back.hasArrow == true)
        #expect(abs(back.arrowSize - 2.5) < 1e-9)
        #expect(back.styleName == "MLSTYLE")
        #expect(abs(back.landingDistance - 3.5) < 1e-9)
        #expect(back.doglegEnabled == false)
        if case .text(let td)? = back.annotation { #expect(td.text == "A") }
        else { Issue.record("annotation did not round-trip") }
    }

    @Test("a multileader round-trips through the EntityKind/EntityRecord Codable path")
    func codableRecordRoundTrip() throws {
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(5, 5)],
                                landingDistance: 2, doglegEnabled: true)
        let rec = EntityRecord(id: EntityID(7), kind: .multileader(d))
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(EntityRecord.self, from: data)
        guard case .multileader(let r) = back.kind else {
            Issue.record("record did not round-trip as .multileader"); return
        }
        #expect(r.vertices.count == 2)
        #expect(abs(r.landingDistance - 2) < 1e-9)
        #expect(r.doglegEnabled == true)
    }

    @Test("old JSON without the 2 new fields decodes to the defaults (back-compat)")
    func oldJSONDecodesToDefaults() throws {
        // Encode a value, then STRIP the two newer keys to simulate JSON written
        // before `landingDistance`/`doglegEnabled` existed.
        let d = MultiLeaderData(vertices: [Vector(0, 0), Vector(10, 0)],
                                hasArrow: true, arrowSize: 2, styleName: "S",
                                landingDistance: 99, doglegEnabled: false)
        let data = try JSONEncoder().encode(d)
        var obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "encoded MultiLeaderData was not a JSON object")
        obj.removeValue(forKey: "landingDistance")
        obj.removeValue(forKey: "doglegEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(MultiLeaderData.self, from: legacy)
        // The defining data that WAS present round-trips.
        #expect(back.vertices.count == 2)
        #expect(back.hasArrow == true)
        #expect(back.styleName == "S")
        // The two absent fields fall back to the struct's defaults.
        #expect(abs(back.landingDistance - 2.0) < 1e-9)   // default landingDistance
        #expect(back.doglegEnabled == true)               // default doglegEnabled
    }
}
