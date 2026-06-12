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
            fontProvider: { _ in font }
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
}
