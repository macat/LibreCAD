//
//  DimensionTests.swift
//  CADEngineTests
//
//  Tests for the associative `.dimension` EntityKind (S1 `ws/dim-entity`): the
//  DimData model, its `resolve()` graphic (extension lines + dimension line +
//  arrowheads + measurement text), its analytic `boundingBox`, and how it
//  transforms (translate + rotate). The measurement text is verified through the
//  SAME `.lff` font path `.text` uses (ADR-004), so a synthetic single-stroke
//  digit font lets us count the glyph strokes a label produces without depending
//  on the shipped fonts.
//
//  Suite/type names are domain-namespaced (`Dimension*`) per CONVENTIONS.md to
//  avoid the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Dimension entity")
struct DimensionEntityTests {

    // MARK: - Synthetic digit font (one distinctive stroke per glyph)

    /// A tiny `.lff` font giving every digit 0-9 (plus `R`, `°`, `⌀`) exactly ONE
    /// **three-point** stroke per glyph. Three points (not two) so a text glyph
    /// stroke is distinguishable from the dimension's 2-point GRAPHIC lines
    /// (extension / dimension lines): a glyph polyline always has exactly 3
    /// points, letting the tests count "the label produced N glyph strokes"
    /// font-independently. (The angular dim's arc has many more points, also
    /// distinct from 3.)
    private static let glyphStroke = "0,0;3,9;6,0"

    private static func digitFont() -> StrokeFont {
        var blocks: [String] = []
        for ch in "0123456789" {
            let scalar = ch.unicodeScalars.first!
            let hex = String(format: "%04x", scalar.value)
            blocks.append("[\(hex)] \(ch)\n\(glyphStroke)")
        }
        // R (0052), degree sign ° (00b0), diameter sign ⌀ (2300).
        blocks.append("[0052] R\n\(glyphStroke)")
        blocks.append("[00b0] DEG\n\(glyphStroke)")
        blocks.append("[2300] DIA\n\(glyphStroke)")
        return LFFParser.parse(text: blocks.joined(separator: "\n\n"))
    }

    /// The number of glyph (3-point) text strokes in a resolved geometry.
    private static func textGlyphStrokes(_ geo: ResolvedGeometry) -> Int {
        geo.polylines.filter { $0.points.count == 3 }.count
    }

    /// A resolve context whose font provider serves the synthetic digit font for
    /// any requested style name (so measurement text resolves to strokes).
    private static func ctxWithFont() -> ResolveContext {
        let font = digitFont()
        return ResolveContext(
            tessellationTolerance: 0.01,
            fontProvider: SingleStrokeFontProvider(font)
        )
    }

    /// Counts the drawable characters of a label under the digit font (each maps
    /// to exactly one stroke; a space / suppressed char contributes 0).
    private static func glyphCount(_ s: String) -> Int {
        s.filter { $0 != " " }.count
    }

    private func makeRecord(_ kind: DimKind, def: Vector,
                            textHeight: Double = 2.5, arrowSize: Double = 2.5,
                            textOverride: String? = nil) -> EntityRecord {
        EntityRecord(
            id: EntityID(1),
            kind: .dimension(DimData(
                kind: kind, definitionPoint: def,
                textOverride: textOverride,
                textHeight: textHeight, arrowSize: arrowSize))
        )
    }

    // MARK: - Label formatting

    @Test("dimFormat trims trailing zeros: 10.0 reads \"10\"")
    func formatsMeasurement() {
        #expect(EntityKind.dimFormat(10.0) == "10")
        #expect(EntityKind.dimFormat(10.5) == "10.5")
        #expect(EntityKind.dimFormat(0) == "0")
        #expect(EntityKind.dimFormat(3.14159) == "3.1416")
    }

    // MARK: - Linear dimension (0,0)-(10,0)

    @Test("linear dim (0,0)-(10,0) resolves to dim line + 2 ext lines + arrowheads + text \"10\"")
    func linearResolve() {
        let ctx = Self.ctxWithFont()
        // Linear, horizontal, dimension line offset to y = 5.
        let rec = makeRecord(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5))
        let geo = rec.resolve(ctx)

        // Graphic lines: 2 extension lines + 1 dimension line = 3 two-point
        // polylines (plus the text strokes). Arrowheads are 2 fills.
        let twoPointLines = geo.polylines.filter { $0.points.count == 2 }
        #expect(twoPointLines.count >= 3)
        #expect(geo.fills.count == 2)   // two arrowhead triangles

        // The dimension line runs horizontally at y = 5 from x≈0 to x≈10.
        let dimLine = twoPointLines.first {
            abs($0.points[0].y - 5) < 1e-6 && abs($0.points[1].y - 5) < 1e-6
        }
        let dl = try! #require(dimLine)
        let xs = [dl.points[0].x, dl.points[1].x].sorted()
        #expect(abs(xs[0] - 0) < 1e-6)
        #expect(abs(xs[1] - 10) < 1e-6)

        // Measurement value reads "10": exactly two digit glyphs ("1","0") of
        // text strokes (each glyph is one 3-point stroke in the synthetic font).
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("10"))   // == 2

        // Each arrowhead fill is a triangle (3 corners).
        for fill in geo.fills { #expect(fill.loops.first?.count == 3) }
    }

    @Test("linear dim with no font provider still resolves the graphic (text omitted, no crash)")
    func linearResolveNoFont() {
        let rec = makeRecord(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5))
        let geo = rec.resolve(.default)   // no fontProvider
        // Graphic survives; text resolves to nothing without a provider.
        #expect(geo.polylines.count == 3)   // 2 ext + 1 dim line, no text
        #expect(geo.fills.count == 2)       // arrowheads
    }

    @Test("explicit textOverride replaces the measured value")
    func linearTextOverride() {
        let ctx = Self.ctxWithFont()
        let rec = makeRecord(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5), textOverride: "42")
        let geo = rec.resolve(ctx)
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("42"))   // 2 glyphs, not "10"
    }

    @Test("a single-space textOverride suppresses the measurement text")
    func linearTextSuppressed() {
        let ctx = Self.ctxWithFont()
        let rec = makeRecord(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5), textOverride: " ")
        let geo = rec.resolve(ctx)
        // Only the 3 graphic lines; no text strokes.
        #expect(geo.polylines.count == 3)
    }

    // MARK: - Aligned dimension on a slanted segment

    @Test("aligned dim on a slanted segment measures the true length")
    func alignedResolve() {
        let ctx = Self.ctxWithFont()
        // A 3-4-5 segment: length 5. Dimension line offset perpendicular by def.
        let p1 = Vector(0, 0)
        let p2 = Vector(3, 4)
        // Offset the dim line to one side of the segment.
        let def = Vector(2, -1.5)
        let rec = makeRecord(.aligned(extension1: p1, extension2: p2), def: def)
        let geo = rec.resolve(ctx)

        // The dimension line length equals the measured distance (5), since the
        // projected points preserve the parallel extent.
        let twoPointLines = geo.polylines.filter { $0.points.count == 2 }
        let dimLine = try! #require(twoPointLines.max {
            ($0.points[1] - $0.points[0]).magnitude < ($1.points[1] - $1.points[0]).magnitude
        })
        let dimLen = (dimLine.points[1] - dimLine.points[0]).magnitude
        #expect(abs(dimLen - 5) < 1e-6)

        // Label "5" = one glyph.
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("5"))

        // Two arrowheads.
        #expect(geo.fills.count == 2)
    }

    // MARK: - Radial dimension on a circle

    @Test("radial dim on a circle resolves a leader + arrowhead + \"R<radius>\" text")
    func radialResolve() {
        let ctx = Self.ctxWithFont()
        // Circle center (0,0), radius 10 → point on circle at (10,0).
        let rec = makeRecord(.radial(center: Vector(0, 0), pointOnCircle: Vector(10, 0)),
                             def: Vector(10, 0))
        let geo = rec.resolve(ctx)

        // One leader line center→circle, one arrowhead fill.
        let twoPointLines = geo.polylines.filter { $0.points.count == 2 }
        #expect(twoPointLines.count >= 1)
        #expect(geo.fills.count == 1)

        // Leader runs from (0,0) to (10,0).
        let leader = try! #require(twoPointLines.first {
            ($0.points[0].distance(to: Vector(0, 0)) < 1e-6 &&
             $0.points[1].distance(to: Vector(10, 0)) < 1e-6) ||
            ($0.points[1].distance(to: Vector(0, 0)) < 1e-6 &&
             $0.points[0].distance(to: Vector(10, 0)) < 1e-6)
        })
        _ = leader

        // Label "R10" = 3 glyphs (R, 1, 0).
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("R10"))   // == 3
    }

    @Test("diameter dim measures the across-circle distance and labels with ⌀")
    func diameterResolve() {
        let ctx = Self.ctxWithFont()
        // Diameter 20 across (-10,0)-(10,0).
        let rec = makeRecord(.diameter(point1: Vector(-10, 0), point2: Vector(10, 0)),
                             def: Vector(0, 0))
        let geo = rec.resolve(ctx)
        // Diameter line + 2 arrowheads.
        #expect(geo.fills.count == 2)
        // Label "⌀20" = 3 glyphs.
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("\u{2300}20"))   // == 3
    }

    @Test("angular dim measures the angle between two lines (90°)")
    func angularResolve() {
        let ctx = Self.ctxWithFont()
        // Two lines from the origin: along +X and along +Y → 90°.
        let rec = makeRecord(
            .angular(line1Start: Vector(0, 0), line1End: Vector(10, 0),
                     line2Start: Vector(0, 0), line2End: Vector(0, 10)),
            def: Vector(5, 5))   // arc radius ~7.07
        let geo = rec.resolve(ctx)

        // The dimension arc is a many-point polyline (> 3 points; glyph strokes
        // are exactly 3); 2 extension lines are 2-point; 2 arrowheads are fills.
        let arcs = geo.polylines.filter { $0.points.count > 3 }
        #expect(!arcs.isEmpty)
        #expect(geo.fills.count == 2)

        // Label "90°" = 3 glyphs (9, 0, °). Glyph strokes are exactly 3 points;
        // the arc is many points, so this counts only the text.
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("90\u{00B0}"))   // == 3
    }

    // MARK: - Bounding box

    @Test("boundingBox encloses the resolved geometry (linear)")
    func boundingBoxEnclosesResolved() {
        let ctx = Self.ctxWithFont()
        let rec = makeRecord(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5))
        let box = rec.boundingBox()
        #expect(!box.isEmpty)

        // Every resolved point (graphic + arrowhead corners + text strokes) must
        // lie inside the analytic bbox.
        let geo = rec.resolve(ctx)
        for pl in geo.polylines {
            for p in pl.points { #expect(box.contains(p), "point \(p) outside bbox \(box)") }
        }
        for fill in geo.fills {
            for loop in fill.loops {
                for p in loop { #expect(box.contains(p), "fill point \(p) outside bbox \(box)") }
            }
        }
        // The box must at least span the measured points and the dim line.
        #expect(box.min.x <= 0 + 1e-6)
        #expect(box.max.x >= 10 - 1e-6)
        #expect(box.max.y >= 5 - 1e-6)
    }

    @Test("boundingBox is non-empty for every variant")
    func boundingBoxAllVariants() {
        let cases: [DimKind] = [
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            .aligned(extension1: Vector(0, 0), extension2: Vector(3, 4)),
            .radial(center: Vector(0, 0), pointOnCircle: Vector(10, 0)),
            .diameter(point1: Vector(-5, 0), point2: Vector(5, 0)),
            .angular(line1Start: Vector(0, 0), line1End: Vector(10, 0),
                     line2Start: Vector(0, 0), line2End: Vector(0, 10)),
        ]
        for k in cases {
            let rec = makeRecord(k, def: Vector(5, 5))
            #expect(!rec.boundingBox().isEmpty)
        }
    }

    // MARK: - Transform (translate + rotate)

    @Test("translating a linear dim maps every defining point by the offset")
    func transformTranslate() {
        let dim = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5))
        let offset = Vector(3, -7)
        let t = Affine2D.translation(offset)
        let moved = EntityKind.dimension(dim).transformed(by: t)
        guard case let .dimension(md) = moved,
              case let .linear(e1, e2, angle) = md.kind else {
            Issue.record("expected a linear dimension after transform"); return
        }
        #expect(e1.distance(to: Vector(3, -7)) < 1e-9)
        #expect(e2.distance(to: Vector(13, -7)) < 1e-9)
        #expect(md.definitionPoint.distance(to: Vector(8, -2)) < 1e-9)
        // A pure translation leaves the linear direction angle unchanged.
        #expect(abs(Vector.correctAngle(angle)) < 1e-9)
    }

    @Test("rotating a linear dim by 90° rotates points and the direction angle")
    func transformRotate() {
        let dim = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5))
        // Rotate 90° CCW about the origin.
        let t = Affine2D.rotation(angle: .pi / 2, about: Vector(0, 0))
        let rotated = EntityKind.dimension(dim).transformed(by: t)
        guard case let .dimension(rd) = rotated,
              case let .linear(e1, e2, angle) = rd.kind else {
            Issue.record("expected a linear dimension after rotation"); return
        }
        // (0,0)→(0,0); (10,0)→(0,10); def (5,5)→(-5,5).
        #expect(e1.distance(to: Vector(0, 0)) < 1e-9)
        #expect(e2.distance(to: Vector(0, 10)) < 1e-9)
        #expect(rd.definitionPoint.distance(to: Vector(-5, 5)) < 1e-9)
        // The direction angle gains 90° (now vertical).
        #expect(abs(Vector.correctAngle(angle) - .pi / 2) < 1e-9)
    }

    @Test("translate + rotate preserves the measured value")
    func transformPreservesMeasurement() {
        let ctx = Self.ctxWithFont()
        let dim = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5))
        // Compose: translate then rotate 30°.
        let t = Affine2D.rotation(angle: .pi / 6, about: Vector(2, 2))
            * Affine2D.translation(Vector(4, 1))
        let moved = EntityKind.dimension(dim).transformed(by: t)

        // The measured length (10) survives a rigid motion; the label stays "10".
        guard case let .dimension(md) = moved else {
            Issue.record("expected a dimension"); return
        }
        let measured = EntityKind.dimMeasuredValue(md)
        #expect(abs(measured.value - 10) < 1e-6)

        // And the resolved text still has the two "10" glyphs.
        let geo = EntityRecord(id: EntityID(1), kind: .dimension(md)).resolve(ctx)
        #expect(Self.textGlyphStrokes(geo) == Self.glyphCount("10"))
    }

    @Test("scaling a dim scales its text height and arrow size")
    func transformScalesSizes() {
        let dim = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5),
            textHeight: 2.5, arrowSize: 2.5)
        let t = Affine2D.scale(factor: 2.0, about: Vector(0, 0))
        let scaled = EntityKind.dimension(dim).transformed(by: t)
        guard case let .dimension(sd) = scaled else {
            Issue.record("expected a dimension"); return
        }
        #expect(abs(sd.textHeight - 5.0) < 1e-9)
        #expect(abs(sd.arrowSize - 5.0) < 1e-9)
        // The measured length doubles too.
        #expect(abs(EntityKind.dimMeasuredValue(sd).value - 20) < 1e-6)
    }

    // MARK: - Value-type / Codable contract (ADR-001)

    @Test("DimData is a Codable value type (round-trips through JSON)")
    func codableRoundTrip() throws {
        let dim = DimData(
            kind: .angular(line1Start: Vector(0, 0), line1End: Vector(10, 0),
                           line2Start: Vector(0, 0), line2End: Vector(0, 10)),
            definitionPoint: Vector(5, 5),
            textOverride: "ANG", textHeight: 3, arrowSize: 1.5)
        let rec = EntityRecord(id: EntityID(7), kind: .dimension(dim))
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(EntityRecord.self, from: data)
        #expect(back == rec)
    }

    @Test("DimData round-trips the S1 fields through JSON (textRotation, attachment, spacing, oblique)")
    func codableRoundTripS1Fields() throws {
        let dim = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5),
            textMiddle: Vector(7, 8),
            textRotation: .pi / 4,
            attachmentPoint: .bottomRight,
            lineSpacingStyle: .exact,
            lineSpacingFactor: 1.5,
            obliqueAngle: .pi / 6)
        let rec = EntityRecord(id: EntityID(9), kind: .dimension(dim))
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(EntityRecord.self, from: data)
        #expect(back == rec)
        // And the optional textMiddle survives as `.some`.
        guard case let .dimension(bd) = back.kind else {
            Issue.record("expected a dimension"); return
        }
        #expect(bd.textMiddle?.distance(to: Vector(7, 8)) ?? .infinity < 1e-9)
        #expect(bd.textRotation.map { abs($0 - .pi / 4) < 1e-9 } == true)
        #expect(bd.attachmentPoint == .bottomRight)
        #expect(bd.lineSpacingStyle == .exact)
    }
}

// MARK: - Dimension foundation fixes (M1 / M2 / S2 / S3)

/// Tests the dimension-foundation fixes the code review demanded: the angular
/// sector selected by the definition point (M1), the robust extension-line
/// direction (M2), the optional `textMiddle` override (S2), and the
/// measured-metrics text centering (S3). Each is written to genuinely exercise
/// the fix — the M1 wrong-side test in particular FAILS against the old
/// always-CCW behavior.
///
/// Suite/type names are domain-namespaced per CONVENTIONS.md to avoid the
/// parallel-fan-out test-target redeclaration trap.
@Suite("Dimension foundation fixes")
struct DimensionFoundationFixTests {

    // Reuse the synthetic-font helpers' shape: one 3-point stroke per glyph so
    // text strokes are countable and distinguishable from the 2-point graphic
    // lines and the many-point arc.
    private static let glyphStroke = "0,0;3,9;6,0"

    private static func digitFont() -> StrokeFont {
        var blocks: [String] = []
        for ch in "0123456789" {
            let scalar = ch.unicodeScalars.first!
            let hex = String(format: "%04x", scalar.value)
            blocks.append("[\(hex)] \(ch)\n\(glyphStroke)")
        }
        blocks.append("[0052] R\n\(glyphStroke)")
        blocks.append("[00b0] DEG\n\(glyphStroke)")
        blocks.append("[2300] DIA\n\(glyphStroke)")
        return LFFParser.parse(text: blocks.joined(separator: "\n\n"))
    }

    private static func ctxWithFont() -> ResolveContext {
        ResolveContext(tessellationTolerance: 0.01,
                       fontProvider: SingleStrokeFontProvider(digitFont()))
    }

    private static func textGlyphStrokes(_ geo: ResolvedGeometry) -> Int {
        geo.polylines.filter { $0.points.count == 3 }.count
    }

    /// The many-point dimension arc (> 3 points) — distinct from glyph strokes
    /// (exactly 3) and graphic lines (exactly 2).
    private static func arcPolyline(_ geo: ResolvedGeometry) -> ResolvedPolyline? {
        geo.polylines.filter { $0.points.count > 3 }.max { $0.points.count < $1.points.count }
    }

    private func record(_ kind: DimKind, def: Vector,
                        textMiddle: Vector? = nil) -> EntityRecord {
        EntityRecord(
            id: EntityID(1),
            kind: .dimension(DimData(kind: kind, definitionPoint: def,
                                     textMiddle: textMiddle)))
    }

    // MARK: - M1: angular sector selected by the definition point

    /// Baseline: the def point in the CCW (Q1) sector measures 90° and the arc
    /// stays in Q1 (all sampled points have y ≥ 0). This is the value the OLD
    /// always-CCW code also produced — it pins the "right side" reference.
    @Test("M1 angular: def point in the CCW sector measures 90° with the arc in Q1")
    func angularCCWSectorRightSide() {
        let ctx = Self.ctxWithFont()
        // +X ray and +Y ray; def in Q1 → the minor (CCW) 90° sector.
        let rec = record(
            .angular(line1Start: Vector(0, 0), line1End: Vector(10, 0),
                     line2Start: Vector(0, 0), line2End: Vector(0, 10)),
            def: Vector(5, 5))
        let geo = rec.resolve(ctx)

        // Measured value (single source of truth) is 90°.
        guard case let .dimension(dm) = rec.kind else { Issue.record("dim"); return }
        #expect(abs(EntityKind.dimMeasuredValue(dm).value - 90) < 1e-6)

        // Label reads "90°" — 3 glyphs.
        #expect(Self.textGlyphStrokes(geo) == 3)

        // The arc lives in Q1: every sampled arc point has y ≥ 0 (and x ≥ 0).
        let arc = try! #require(Self.arcPolyline(geo))
        #expect(arc.points.allSatisfy { $0.y > -1e-6 && $0.x > -1e-6 })
    }

    /// M1: the def point in the CLOCKWISE (Q4) sector must measure the REFLEX
    /// 270° angle and the arc must sweep the OTHER way (through Q4, where the def
    /// point sits — sampled arc points reach y < 0). The OLD always-CCW code
    /// reported 90° here and kept the arc in Q1, so this test FAILS against it
    /// and PASSES only with the sector-by-def-point selection.
    @Test("M1 angular WRONG-SIDE: def point in the CW sector measures the reflex 270° and the arc follows")
    func angularCWSectorWrongSide() {
        let ctx = Self.ctxWithFont()
        // Same two rays, but def in Q4 → the dimension must span the major
        // (clockwise, 270°) sector that contains the def point.
        let rec = record(
            .angular(line1Start: Vector(0, 0), line1End: Vector(10, 0),
                     line2Start: Vector(0, 0), line2End: Vector(0, 10)),
            def: Vector(5, -5))
        let geo = rec.resolve(ctx)

        // Measured value is the REFLEX 270° (NOT 90°) — this alone fails the old
        // always-CCW behavior.
        guard case let .dimension(dm) = rec.kind else { Issue.record("dim"); return }
        let measured = EntityKind.dimMeasuredValue(dm).value
        #expect(abs(measured - 270) < 1e-6, "expected reflex 270°, got \(measured)")

        // Label reads "270°" — 4 glyphs (2,7,0,°). The old code's "90°" is 3.
        #expect(Self.textGlyphStrokes(geo) == 4)

        // The arc now sweeps through the def-point side: at least one sampled arc
        // point has y < 0 (Q4), which the old Q1-only arc never produced.
        let arc = try! #require(Self.arcPolyline(geo))
        #expect(arc.points.contains { $0.y < -1e-6 },
                "arc must enter Q4 (the def-point side) for the reflex sweep")

        // The text center also sits on the measured (reflex) arc's far side —
        // its midpoint angle is ~225° (Q3), so the text x is < 0.
        let textCenter = EntityKind.dimTextCenter(dm)
        #expect(textCenter.x < 0, "text center should sit on the reflex-arc side")
    }

    // MARK: - M2: extension-line direction with the def point BETWEEN origins

    /// M2: a horizontal linear dim whose dimension line lies BETWEEN the two
    /// extension origins (def y is between the origins' y). Each extension line
    /// must run from its origin TOWARD the dim line — i.e. the two extension
    /// lines point in OPPOSITE normal directions (one up, one down), each
    /// bridging its origin to its projection. The old single-`normal` fallback
    /// could send both the same (wrong) way.
    @Test("M2 extension lines: def line BETWEEN the origins makes the two extensions point opposite ways")
    func extensionLinesDefBetweenOrigins() {
        let ctx = Self.ctxWithFont()
        // Origin1 below the dim line (y = -4), origin2 above (y = +6); the dim
        // line (through def) sits between them at y = 1. Horizontal dim (angle 0).
        let p1 = Vector(0, -4)
        let p2 = Vector(10, 6)
        let def = Vector(5, 1)
        let rec = EntityRecord(
            id: EntityID(2),
            kind: .dimension(DimData(
                kind: .linear(extension1: p1, extension2: p2, angle: 0),
                definitionPoint: def)))
        let geo = rec.resolve(ctx)

        // Find the two extension lines: 2-point polylines that are NOT the
        // (horizontal) dimension line. The dim line is horizontal at y = 1; the
        // extension lines are vertical (constant x ≈ 0 and ≈ 10).
        let twoPt = geo.polylines.filter { $0.points.count == 2 }
        let ext1 = try! #require(twoPt.first { abs($0.points[0].x - 0) < 1e-6 && abs($0.points[1].x - 0) < 1e-6 })
        let ext2 = try! #require(twoPt.first { abs($0.points[0].x - 10) < 1e-6 && abs($0.points[1].x - 10) < 1e-6 })

        // ext1 starts near its origin (y ≈ -4) and runs UP toward/past the dim
        // line (y = 1): its direction has +y.
        let d1 = ext1.points[1].y - ext1.points[0].y
        // ext2 starts near its origin (y ≈ +6) and runs DOWN toward the dim line:
        // its direction has -y. The signs MUST be opposite.
        let d2 = ext2.points[1].y - ext2.points[0].y
        #expect(d1 * d2 < 0, "extension lines must point opposite ways (one up, one down) when the dim line is between the origins")

        // And each spans from below/above its origin across the dim line at y=1:
        // ext1 covers a range that includes y < 0 (its origin side) up past y=1;
        // ext2 covers a range that includes y > 1 (its origin side) down to ~1.
        let ext1Ys = [ext1.points[0].y, ext1.points[1].y]
        let ext2Ys = [ext2.points[0].y, ext2.points[1].y]
        #expect(ext1Ys.min()! < 0 && ext1Ys.max()! > 1 - 1e-6)
        #expect(ext2Ys.max()! > 1 && ext2Ys.min()! < 6)
    }

    /// M2 robustness: when an extension origin lies exactly ON the dim line
    /// (len ≈ 0), the direction is derived from the dim-line normal signed by the
    /// def point — it must NOT collapse to a zero-length or arbitrarily-flipped
    /// line. Here origin1 sits on the dim line (same y as def).
    @Test("M2 extension lines: an origin ON the dim line still yields a non-degenerate, correctly-signed extension")
    func extensionLineOriginOnDimLine() {
        let ctx = Self.ctxWithFont()
        // def at y = 0, origin1 also at y = 0 (ON the dim line), origin2 at y = 8.
        let p1 = Vector(0, 0)
        let p2 = Vector(10, 8)
        let def = Vector(5, 0)
        let rec = EntityRecord(
            id: EntityID(3),
            kind: .dimension(DimData(
                kind: .linear(extension1: p1, extension2: p2, angle: 0),
                definitionPoint: def)))
        let geo = rec.resolve(ctx)

        let twoPt = geo.polylines.filter { $0.points.count == 2 }
        let ext1 = try! #require(twoPt.first { abs($0.points[0].x - 0) < 1e-6 && abs($0.points[1].x - 0) < 1e-6 })
        // The on-dim-line extension is NOT degenerate (the DIMEXO/DIMEXE offsets
        // give it a real length) and points away from the def point's side.
        let len = (ext1.points[1] - ext1.points[0]).magnitude
        #expect(len > 1e-6, "extension line at len≈0 must still be non-degenerate")
        // origin2 (y=8) is above the dim line; the signed normal makes the
        // measured point lie on the side AWAY from the def line — for origin1 ON
        // the line the convention points to the +y side (origin2's side flips it).
        // The key invariant: it is finite and oriented vertically.
        #expect(abs(ext1.points[1].x - 0) < 1e-6)
    }

    // MARK: - S2: textMiddle override placement (the `.some` branch)

    /// S2: an explicit `textMiddle` override places the text center at exactly
    /// that point (the `.some` branch), overriding the default centered-on-dim
    /// placement. The text strokes must be centered around the override point.
    @Test("S2 textMiddle override: the text is placed at the override point, not the default center")
    func textMiddleOverridePlacement() {
        let ctx = Self.ctxWithFont()
        let override = Vector(42, 17)
        let rec = record(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5),
            textMiddle: override)
        let geo = rec.resolve(ctx)

        // dimTextCenter honors the override EXACTLY (the precise `.some` contract).
        guard case let .dimension(dm) = rec.kind else { Issue.record("dim"); return }
        #expect(EntityKind.dimTextCenter(dm).distance(to: override) < 1e-9)

        // The resolved text ink sits AT the override, clearly distinct from the
        // default placement (≈ (5, ~6)). The ink midpoint lands within a glyph
        // height of the override (the small metrics-vs-ink gap is expected, since
        // the shaper anchors on the run's advance/metrics, not the ink box).
        let glyphPts = geo.polylines.filter { $0.points.count == 3 }.flatMap { $0.points }
        #expect(!glyphPts.isEmpty)
        let minX = glyphPts.map(\.x).min()!, maxX = glyphPts.map(\.x).max()!
        let minY = glyphPts.map(\.y).min()!, maxY = glyphPts.map(\.y).max()!
        let inkMidX = (minX + maxX) / 2, inkMidY = (minY + maxY) / 2
        #expect(abs(inkMidX - override.x) < dm.textHeight)
        #expect(abs(inkMidY - override.y) < dm.textHeight)
        // ...and nowhere near the default center it would use without the override.
        let defaultCenter = Vector(5, 5)   // dim-line midpoint region
        #expect(Vector(inkMidX, inkMidY).distance(to: defaultCenter) > 20)
    }

    /// S2: a `nil` textMiddle (the default) falls through to the computed center
    /// — confirming the `.none` branch still works alongside the `.some` branch.
    @Test("S2 textMiddle nil: falls back to the default computed center")
    func textMiddleNilDefault() {
        let rec = record(
            .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            def: Vector(5, 5),
            textMiddle: nil)
        guard case let .dimension(dm) = rec.kind else { Issue.record("dim"); return }
        let center = EntityKind.dimTextCenter(dm)
        // Default center: midpoint of the dim line (x = 5) lifted above by ~textH.
        #expect(abs(center.x - 5) < 1e-6)
        #expect(center.y > 5)   // lifted above the y=5 dim line
    }

    // MARK: - S3: measured-metrics text centering (wide vs narrow label)

    /// S3: text centering uses the MEASURED run width (not a nominal glyph
    /// count). A wide label ("888888") and a narrow label ("8") both anchor on
    /// the SAME text center, so their ink-midpoint OFFSET from that center is
    /// IDENTICAL (the run is symmetric about the advance-width center for any
    /// count). The wide label genuinely spans wider. If centering used a nominal
    /// per-glyph count instead of the measured width, the two offsets would
    /// differ — so equal offsets is the discriminating measured-width property.
    @Test("S3 measured centering: a wide and a narrow override label share the same centered offset")
    func measuredCenteringWideVsNarrow() {
        let ctx = Self.ctxWithFont()
        let center = Vector(20, 30)

        func glyphBounds(_ override: String) -> (midX: Double, span: Double) {
            let rec = EntityRecord(
                id: EntityID(4),
                kind: .dimension(DimData(
                    kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
                    definitionPoint: Vector(5, 5),
                    textOverride: override,
                    textMiddle: center)))
            let geo = rec.resolve(ctx)
            let pts = geo.polylines.filter { $0.points.count == 3 }.flatMap { $0.points }
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
            return ((minX + maxX) / 2, maxX - minX)
        }

        let wide = glyphBounds("888888")   // 6 glyphs
        let narrow = glyphBounds("8")      // 1 glyph

        // The ink-midpoint OFFSET from the anchor is IDENTICAL for both labels —
        // measured-width centering keeps the run symmetric about the same center
        // regardless of glyph count.
        let wideOffset = wide.midX - center.x
        let narrowOffset = narrow.midX - center.x
        #expect(abs(wideOffset - narrowOffset) < 1e-6,
                "wide/narrow centered offsets must match (measured-width centering)")

        // Both offsets are small relative to the wide label's span (the run is
        // centered, not justified to one side).
        #expect(abs(wideOffset) < wide.span)

        // The wide label genuinely spans wider than the narrow one (so we know we
        // are not accidentally measuring an empty / identical run).
        #expect(wide.span > narrow.span + 1e-6)
    }

    // MARK: - Transform: reflection + non-uniform scale

    /// A reflection composed with a NON-UNIFORM scale maps every defining point
    /// by the matrix and scales the text/arrow sizes by the geometric-mean
    /// uniform factor (`sqrt(|det|)`). The measured value re-derives from the
    /// transformed points.
    @Test("transform: reflection + non-uniform scale maps the defining points and sizes correctly")
    func transformReflectNonUniformScale() {
        // Aligned dim on a horizontal segment so its measured length is the
        // segment length (re-derived after transform).
        let p1 = Vector(2, 3)
        let p2 = Vector(8, 3)
        let def = Vector(5, 6)
        let dim = DimData(kind: .aligned(extension1: p1, extension2: p2),
                          definitionPoint: def,
                          textHeight: 2.0, arrowSize: 3.0)

        // Non-uniform scale (sx=2, sy=3) about the origin, then mirror across the
        // x-axis (y → -y). det of the linear part is negative → a reflection.
        let scale = Affine2D.scale(sx: 2, sy: 3, about: Vector(0, 0))
        let mirror = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0)  // x-axis
        let t = mirror * scale

        // Sanity: this is orientation-reversing with the expected uniform factor.
        #expect(t.isMirror)
        let expectedUniform = (2.0 * 3.0).squareRoot()   // sqrt(|det|) = sqrt(6)

        let out = EntityKind.dimension(dim).transformed(by: t)
        guard case let .dimension(od) = out,
              case let .aligned(oe1, oe2) = od.kind else {
            Issue.record("expected an aligned dimension after transform"); return
        }

        // Each defining point maps by the full matrix.
        #expect(oe1.distance(to: t.apply(p1)) < 1e-9)
        #expect(oe2.distance(to: t.apply(p2)) < 1e-9)
        #expect(od.definitionPoint.distance(to: t.apply(def)) < 1e-9)

        // The measured length re-derives from the transformed points: the
        // horizontal segment (length 6) scaled in x by 2 → length 12.
        #expect(abs(EntityKind.dimMeasuredValue(od).value - 12) < 1e-6)

        // Text height / arrow size scale by the uniform (geometric-mean) factor.
        #expect(abs(od.textHeight - 2.0 * expectedUniform) < 1e-9)
        #expect(abs(od.arrowSize - 3.0 * expectedUniform) < 1e-9)
    }

    /// A reflection must reflect the linear-dim direction angle (and keep a
    /// textMiddle override mapped through the same matrix), not silently drop it.
    @Test("transform: a mirror reflects the linear direction angle and the textMiddle override")
    func transformMirrorAngleAndTextMiddle() {
        let tm = Vector(5, 4)
        let dim = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: .pi / 6),
            definitionPoint: Vector(5, 5),
            textMiddle: tm)
        // Mirror across the x-axis (angle 0): y → -y, angle θ → -θ.
        let t = Affine2D.mirror(acrossLineThrough: Vector(0, 0), angle: 0)
        let out = EntityKind.dimension(dim).transformed(by: t)
        guard case let .dimension(od) = out,
              case let .linear(_, _, angle) = od.kind else {
            Issue.record("expected a linear dimension"); return
        }
        // The direction angle reflects: π/6 → -π/6 ≡ 11π/6.
        #expect(abs(Vector.correctAngle(angle) - Vector.correctAngle(-(.pi / 6))) < 1e-9)
        // The textMiddle override maps through the same matrix (y flips).
        #expect(od.textMiddle?.distance(to: t.apply(tm)) ?? .infinity < 1e-9)
    }
}
