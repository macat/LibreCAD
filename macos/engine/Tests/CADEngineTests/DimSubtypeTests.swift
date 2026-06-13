//
//  DimSubtypeTests.swift
//  CADEngineTests
//
//  Tests for the three dimension subtypes added by the dim-subtype wave
//  (w2-dimsub): `DimKind.ordinate`, `.arcLength`, and `.angular3p`. Covers the
//  resolve() graphic (leader / dimension-arc / extension lines / arrowheads /
//  measurement text), the recomputed measured value, the analytic boundingBox,
//  EntityTransform (translate / scale), and DXF round-trip (write -> read).
//
//  The measurement text is verified through the SAME `.lff` font path `.text` uses
//  (ADR-004): a synthetic single-stroke digit font (with the arc symbol ⌒) lets us
//  count glyph strokes a label produces without depending on the shipped fonts.
//
//  Suite/type names are domain-namespaced (`DimSubtype*`) per CONVENTIONS.md to
//  avoid the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Dimension subtypes (ordinate / arc-length / angular-3p)")
struct DimSubtypeResolveTests {

    // MARK: - Synthetic digit font (one distinctive stroke per glyph)

    /// Every glyph (0-9, the diameter ⌀, degree °, and the arc-length ⌒ symbol)
    /// gets exactly ONE three-point stroke, so the count of 3-point polylines is
    /// the count of drawable label characters — font-independently.
    private static let glyphStroke = "0,0;3,9;6,0"

    private static func digitFont() -> StrokeFont {
        var blocks: [String] = []
        for ch in "0123456789" {
            let hex = String(format: "%04x", ch.unicodeScalars.first!.value)
            blocks.append("[\(hex)] \(ch)\n\(glyphStroke)")
        }
        blocks.append("[00b0] DEG\n\(glyphStroke)")     // °
        blocks.append("[2300] DIA\n\(glyphStroke)")     // ⌀
        blocks.append("[2312] ARC\n\(glyphStroke)")     // ⌒ arc-length symbol
        return LFFParser.parse(text: blocks.joined(separator: "\n\n"))
    }

    private static func textGlyphStrokes(_ geo: ResolvedGeometry) -> Int {
        geo.polylines.filter { $0.points.count == 3 }.count
    }

    private static func ctxWithFont() -> ResolveContext {
        ResolveContext(tessellationTolerance: 0.01,
                       fontProvider: SingleStrokeFontProvider(digitFont()))
    }

    private static func glyphCount(_ s: String) -> Int {
        s.filter { $0 != " " }.count
    }

    private func record(_ kind: DimKind, def: Vector,
                        textHeight: Double = 2.5, arrowSize: Double = 2.5,
                        textOverride: String? = nil) -> EntityRecord {
        EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: kind, definitionPoint: def, textOverride: textOverride,
            textHeight: textHeight, arrowSize: arrowSize)))
    }

    // MARK: - Ordinate

    @Test("X-datum ordinate resolves an L-leader + the feature X coordinate text")
    func ordinateXResolve() {
        let ctx = Self.ctxWithFont()
        // Origin at (0,0); feature at (12, 7); leader dragged up to (12, 20).
        // A vertical leader → X-datum: the measured value is |12 - 0| = 12.
        let rec = record(.ordinate(origin: Vector(0, 0), feature: Vector(12, 7),
                                   leaderEnd: Vector(12, 20), measuringX: true),
                         def: Vector(0, 0))
        let geo = rec.resolve(ctx)

        // The leader is a polyline of 2+ vertices; no arrowhead fills for ordinate.
        #expect(geo.polylines.contains { $0.points.count >= 2 })
        #expect(geo.fills.isEmpty)

        // The leader starts at the feature point.
        let leader = try! #require(geo.polylines.first { $0.points.count >= 2 })
        #expect(leader.points.first!.distance(to: Vector(12, 7)) < 1e-6)

        // Value "12" → 2 glyphs.
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("12"))
    }

    @Test("Y-datum ordinate measures the feature Y coordinate")
    func ordinateYResolve() {
        let ctx = Self.ctxWithFont()
        // Origin (0,0); feature (5, 8); horizontal leader to (25, 8) → Y-datum:
        // measured = |8 - 0| = 8.
        let rec = record(.ordinate(origin: Vector(0, 0), feature: Vector(5, 8),
                                   leaderEnd: Vector(25, 8), measuringX: false),
                         def: Vector(0, 0))
        let geo = rec.resolve(ctx)
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("8"))   // one glyph
    }

    @Test("ordinate measured value = feature coordinate relative to the origin")
    func ordinateMeasured() {
        let x = DimData(kind: .ordinate(origin: Vector(10, 10), feature: Vector(37, 99),
                                        leaderEnd: Vector(37, 50), measuringX: true),
                        definitionPoint: Vector(10, 10))
        #expect(abs(EntityKind.dimMeasuredValue(x).value - 27) < 1e-9)   // |37 - 10|
        let y = DimData(kind: .ordinate(origin: Vector(10, 10), feature: Vector(37, 99),
                                        leaderEnd: Vector(60, 99), measuringX: false),
                        definitionPoint: Vector(10, 10))
        #expect(abs(EntityKind.dimMeasuredValue(y).value - 89) < 1e-9)   // |99 - 10|
    }

    // MARK: - Arc length

    @Test("arc-length dim resolves a dimension arc + 2 ext lines + arrowheads + ⌒ text")
    func arcLengthResolve() {
        let ctx = Self.ctxWithFont()
        // Quarter circle, center (0,0), radius 10, 0 → π/2. Arc length = 10·π/2.
        // Dimension arc drawn at radius 15 (def point at (15, 0)).
        let rec = record(.arcLength(center: Vector(0, 0), radius: 10,
                                    startAngle: 0, endAngle: Double.pi / 2, reversed: false),
                         def: Vector(15, 0))
        let geo = rec.resolve(ctx)

        // A long (>2 point) tessellated dimension arc + two 2-point extension lines.
        #expect(geo.polylines.contains { $0.points.count > 3 })
        let twoPt = geo.polylines.filter { $0.points.count == 2 }
        #expect(twoPt.count >= 2)            // 2 extension lines
        #expect(geo.fills.count == 2)        // 2 arrowheads

        // Label "⌒15.708" (arc symbol + length 10·π/2 ≈ 15.708 at 4-dp default,
        // trailing zeros stripped) → the arc glyph plus the digit glyphs. The
        // synthetic font has no '.' glyph, so the decimal point draws no stroke;
        // count only the glyph-bearing characters (digits + ⌒).
        let expected = EntityKind.dimArcSymbol + EntityKind.dimFormat(10 * Double.pi / 2)
        let drawable = expected.filter { $0 != " " && $0 != "." }.count
        #expect(Self.textGlyphStrokes(geo) == drawable)
    }

    @Test("arc-length measured value = radius × |sweep|")
    func arcLengthMeasured() {
        // Half circle radius 4: length = 4·π.
        let d = DimData(kind: .arcLength(center: Vector(0, 0), radius: 4,
                                         startAngle: 0, endAngle: Double.pi, reversed: false),
                        definitionPoint: Vector(6, 0))
        let m = EntityKind.dimMeasuredValue(d)
        #expect(abs(m.value - 4 * Double.pi) < 1e-9)
        #expect(m.suffix == EntityKind.dimArcSymbol)
    }

    @Test("arc-length with no font provider still resolves the graphic (no crash)")
    func arcLengthNoFont() {
        let rec = record(.arcLength(center: Vector(0, 0), radius: 10,
                                    startAngle: 0, endAngle: Double.pi / 2, reversed: false),
                         def: Vector(15, 0))
        let geo = rec.resolve(.default)   // no font
        #expect(!geo.polylines.isEmpty)
        #expect(geo.fills.count == 2)
    }

    // MARK: - Angular 3-point

    @Test("angular-3p dim resolves an arc + 2 ext lines + arrowheads + angle text")
    func angular3pResolve() {
        let ctx = Self.ctxWithFont()
        // Vertex at origin; ray1 → +X (10,0); ray2 → +Y (0,10): a 90° angle.
        // Def point in the +X/+Y quadrant selects that 90° sector.
        let rec = record(.angular3p(vertex: Vector(0, 0), point1: Vector(10, 0),
                                    point2: Vector(0, 10)),
                         def: Vector(7, 7))
        let geo = rec.resolve(ctx)

        // A tessellated dimension arc (>3 points) + two extension lines + 2 arrows.
        #expect(geo.polylines.contains { $0.points.count > 3 })
        #expect(geo.fills.count == 2)

        // Label "90°" → 2 digit glyphs + 1 degree glyph = 3.
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("90") + 1)
    }

    @Test("angular-3p measured value = angle (degrees) at the vertex")
    func angular3pMeasured() {
        let d = DimData(kind: .angular3p(vertex: Vector(0, 0), point1: Vector(10, 0),
                                         point2: Vector(0, 10)),
                        definitionPoint: Vector(7, 7))
        #expect(abs(EntityKind.dimMeasuredValue(d).value - 90) < 1e-6)
    }

    @Test("angular-3p def point selects the complementary (270°) sector")
    func angular3pSectorSelect() {
        // Same rays, but def point in the opposite quadrant → the 270° reflex angle.
        let d = DimData(kind: .angular3p(vertex: Vector(0, 0), point1: Vector(10, 0),
                                         point2: Vector(0, 10)),
                        definitionPoint: Vector(-7, -7))
        #expect(abs(EntityKind.dimMeasuredValue(d).value - 270) < 1e-6)
    }

    // MARK: - Bounding boxes (no crash; encloses the defining geometry)

    @Test("each subtype's boundingBox encloses its defining points")
    func boundingBoxes() {
        let ord = EntityKind.dimension(DimData(
            kind: .ordinate(origin: Vector(0, 0), feature: Vector(12, 7),
                            leaderEnd: Vector(12, 20), measuringX: true),
            definitionPoint: Vector(0, 0)))
        let bord = ord.boundingBox()
        #expect(!bord.isEmpty)
        #expect(bord.contains(Vector(12, 7)))
        #expect(bord.contains(Vector(12, 20)))

        let arc = EntityKind.dimension(DimData(
            kind: .arcLength(center: Vector(0, 0), radius: 10,
                             startAngle: 0, endAngle: Double.pi / 2, reversed: false),
            definitionPoint: Vector(15, 0)))
        let barc = arc.boundingBox()
        #expect(!barc.isEmpty)
        #expect(barc.contains(Vector(10, 0)))    // feature-arc start

        let a3 = EntityKind.dimension(DimData(
            kind: .angular3p(vertex: Vector(0, 0), point1: Vector(10, 0),
                             point2: Vector(0, 10)),
            definitionPoint: Vector(7, 7)))
        let ba3 = a3.boundingBox()
        #expect(!ba3.isEmpty)
        #expect(ba3.contains(Vector(7, 7)))
    }

    // MARK: - EntityTransform

    @Test("translate maps every defining point of each subtype")
    func transformTranslate() {
        let t = Affine2D.translation(Vector(5, 3))

        let ord = EntityKind.dimension(DimData(
            kind: .ordinate(origin: Vector(0, 0), feature: Vector(12, 7),
                            leaderEnd: Vector(12, 20), measuringX: true),
            definitionPoint: Vector(0, 0))).transformed(by: t)
        guard case .dimension(let od) = ord, case let .ordinate(o, f, l, mx) = od.kind else {
            Issue.record("expected ordinate"); return
        }
        #expect(o.distance(to: Vector(5, 3)) < 1e-9)
        #expect(f.distance(to: Vector(17, 10)) < 1e-9)
        #expect(l.distance(to: Vector(17, 23)) < 1e-9)
        #expect(mx == true)

        let a3 = EntityKind.dimension(DimData(
            kind: .angular3p(vertex: Vector(0, 0), point1: Vector(10, 0),
                             point2: Vector(0, 10)),
            definitionPoint: Vector(7, 7))).transformed(by: t)
        guard case .dimension(let a3d) = a3, case let .angular3p(v, p1, p2) = a3d.kind else {
            Issue.record("expected angular3p"); return
        }
        #expect(v.distance(to: Vector(5, 3)) < 1e-9)
        #expect(p1.distance(to: Vector(15, 3)) < 1e-9)
        #expect(p2.distance(to: Vector(5, 13)) < 1e-9)
    }

    @Test("uniform scale scales the arc-length feature radius + the measured length")
    func transformScale() {
        let t = Affine2D(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0)   // ×2 about origin
        let rec = EntityKind.dimension(DimData(
            kind: .arcLength(center: Vector(0, 0), radius: 10,
                             startAngle: 0, endAngle: Double.pi / 2, reversed: false),
            definitionPoint: Vector(15, 0))).transformed(by: t)
        guard case .dimension(let d) = rec, case let .arcLength(c, r, _, _, _) = d.kind else {
            Issue.record("expected arcLength"); return
        }
        #expect(c.distance(to: Vector(0, 0)) < 1e-9)
        #expect(abs(r - 20) < 1e-9)    // radius doubled
        // Measured length doubled too: 20·π/2.
        #expect(abs(EntityKind.dimMeasuredValue(d).value - 20 * Double.pi / 2) < 1e-6)
    }
}

// MARK: - DXF round-trip

@Suite("Dimension subtypes DXF round-trip (ordinate / angular-3p)")
struct DimSubtypeRoundTripTests {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dimsub-\(UUID().uuidString).dxf").path
    }

    /// Writes the records to DXF, re-reads them, and returns the re-read records.
    private func roundTrip(_ records: [EntityRecord]) async throws -> [EntityRecord] {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let wr = try await CADEngine.shared.writeEntities(records, layers: layers, toPath: path)
        #expect(wr.skipped == 0)
        return try await CADEngine.shared.readEntities(dxfPath: path).records
    }

    @Test("an X-datum ordinate dimension survives write -> read with its axis + points")
    func ordinateXRoundTrip() async throws {
        let rec = EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: .ordinate(origin: Vector(1, 2), feature: Vector(13, 9),
                            leaderEnd: Vector(13, 25), measuringX: true),
            definitionPoint: Vector(1, 2))))
        let back = try await roundTrip([rec])
        let dims = back.compactMap { r -> DimData? in
            if case .dimension(let d) = r.kind { return d } else { return nil }
        }
        #expect(dims.count == 1)
        guard case let .ordinate(o, f, l, mx) = dims.first?.kind else {
            Issue.record("expected ordinate"); return
        }
        #expect(o.distance(to: Vector(1, 2)) < 1e-6)
        #expect(f.distance(to: Vector(13, 9)) < 1e-6)
        #expect(l.distance(to: Vector(13, 25)) < 1e-6)
        #expect(mx == true)
    }

    @Test("a Y-datum ordinate dimension round-trips with measuringX == false")
    func ordinateYRoundTrip() async throws {
        let rec = EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: .ordinate(origin: Vector(0, 0), feature: Vector(5, 8),
                            leaderEnd: Vector(30, 8), measuringX: false),
            definitionPoint: Vector(0, 0))))
        let back = try await roundTrip([rec])
        guard let d = back.compactMap({ r -> DimData? in
            if case .dimension(let d) = r.kind { return d } else { return nil }
        }).first, case let .ordinate(_, _, _, mx) = d.kind else {
            Issue.record("expected ordinate"); return
        }
        #expect(mx == false)
    }

    @Test("a 3-point angular dimension round-trips its vertex + two ray points")
    func angular3pRoundTrip() async throws {
        let rec = EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: .angular3p(vertex: Vector(2, 2), point1: Vector(12, 2),
                             point2: Vector(2, 12)),
            definitionPoint: Vector(8, 8))))
        let back = try await roundTrip([rec])
        guard let d = back.compactMap({ r -> DimData? in
            if case .dimension(let d) = r.kind { return d } else { return nil }
        }).first, case let .angular3p(v, p1, p2) = d.kind else {
            Issue.record("expected angular3p"); return
        }
        #expect(v.distance(to: Vector(2, 2)) < 1e-6)
        #expect(p1.distance(to: Vector(12, 2)) < 1e-6)
        #expect(p2.distance(to: Vector(2, 12)) < 1e-6)
        #expect(d.definitionPoint.distance(to: Vector(8, 8)) < 1e-6)
    }

    @Test("an arc-length dimension survives the engine Codable value round-trip")
    func arcLengthCodableRoundTrip() throws {
        // Arc-length has no native DXF DIMENSION subtype (libdxfrw lacks
        // ARC_DIMENSION); its full fidelity round-trips through the engine value
        // model (the document save codec). Assert the Codable round-trip preserves
        // every defining field.
        let d = DimData(
            kind: .arcLength(center: Vector(3, 4), radius: 7,
                             startAngle: 0.25, endAngle: 1.75, reversed: true),
            definitionPoint: Vector(13, 4))
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DimData.self, from: data)
        guard case let .arcLength(c, r, s, e, rev) = back.kind else {
            Issue.record("expected arcLength"); return
        }
        #expect(c.distance(to: Vector(3, 4)) < 1e-12)
        #expect(abs(r - 7) < 1e-12)
        #expect(abs(s - 0.25) < 1e-12)
        #expect(abs(e - 1.75) < 1e-12)
        #expect(rev == true)
    }

    @Test("an arc-length dimension does not crash the DXF writer (persists as a valid dim)")
    func arcLengthDXFNoCrash() async throws {
        // The writer persists arc-length via the 3p-angular geometry (documented
        // graceful degradation); assert it writes without skipping and re-reads as
        // a valid .dimension (not a warning / dropped entity).
        let rec = EntityRecord(id: EntityID(1), kind: .dimension(DimData(
            kind: .arcLength(center: Vector(0, 0), radius: 10,
                             startAngle: 0, endAngle: Double.pi / 2, reversed: false),
            definitionPoint: Vector(15, 0))))
        let back = try await roundTrip([rec])
        let dims = back.filter { if case .dimension = $0.kind { return true } else { return false } }
        #expect(dims.count == 1)
    }
}
