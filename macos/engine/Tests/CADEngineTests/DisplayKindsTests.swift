//
//  DisplayKindsTests.swift
//  CADEngineTests
//
//  Tests for the display entity kinds (text / hatch / solid) and their
//  computed-geometry `resolve()` (ADR-001 / ADR-004):
//   - text → stroked `.lff` polylines via `ResolveContext.fontProvider`
//     (layout, scale, rotation, missing-glyph fallback, nil-provider graceful);
//   - hatch → a solid `ResolvedFill` of its boundary loops;
//   - solid → a `ResolvedFill` of its corners;
//   - bounding boxes are sane for all three.
//
//  Font fixture: `librecad/support/fonts/standard.lff` (ISO 3098-2), located by
//  the same repo-path-from-`#filePath` idiom `LFFFontTests` uses (the test
//  target's manifest only bundles `dim_sample.dxf`).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("display kinds: text / hatch / solid")
struct DisplayKindsTests {

    // MARK: - Fixture / provider helpers

    /// Locates `standard.lff` (bundle first, else repo path from `#filePath`).
    private func standardFontURL() throws -> URL {
        if let bundled = Bundle.module.url(forResource: "standard", withExtension: "lff") {
            return bundled
        }
        // <repo>/macos/engine/Tests/CADEngineTests/DisplayKindsTests.swift -> up 5 -> <repo>
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // CADEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // <repo>
        let url = repoRoot.appendingPathComponent("librecad/support/fonts/standard.lff")
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "standard.lff fixture not found at \(url.path)"
        )
        return url
    }

    /// A real font provider over the shipped `standard.lff`, registered under
    /// both "standard" and the empty key (so a `nil` style name resolves too).
    /// Returns the `StrokeFontProvider` (which conforms to `FontProvider`): it
    /// serves only `.stroke(...)` sources, so the resolve arm's substitution chain
    /// falls back from the (unavailable) native default to the `.lff` "standard"
    /// stroke font — text resolves to STROKES, as these tests assert.
    private func realProvider() throws -> StrokeFontProvider {
        let url = try standardFontURL()
        let provider = StrokeFontProvider()
        provider.registerFont(at: url, name: "standard")
        provider.registerFont(at: url, name: "")
        return provider
    }

    private func contextWithFont() throws -> ResolveContext {
        ResolveContext(tessellationTolerance: 0.01, fontProvider: try realProvider())
    }

    // MARK: - Text: resolve to strokes

    @Test("text 'ABC' resolves to >= 1 stroke polyline with a real .lff provider")
    func textResolvesToStrokes() throws {
        let ctx = try contextWithFont()
        let e = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: Vector(0, 0), height: 10, text: "ABC", styleName: "standard"))
        )
        let geo = e.resolve(ctx)

        // Stroked text => polylines, no fills.
        #expect(geo.fills.isEmpty)
        #expect(geo.polylines.count >= 1)
        // 'A','B','C' each contribute multiple strokes; expect a healthy count.
        #expect(geo.polylines.count >= 3)

        // Every emitted stroke is a real (>= 2 point) open polyline.
        for pl in geo.polylines {
            #expect(pl.points.count >= 2)
            #expect(pl.closed == false)
        }
    }

    @Test("text scales by height: taller text spans more vertically")
    func textScalesByHeight() throws {
        let ctx = try contextWithFont()
        func maxY(_ height: Double) -> Double {
            let e = EntityRecord(id: EntityID(1),
                                 kind: .text(TextData(position: Vector(0, 0), height: height, text: "A")))
            return e.resolve(ctx).polylines.flatMap { $0.points }.map(\.y).max() ?? 0
        }
        let small = maxY(5)
        let big = maxY(20)
        #expect(big > small)
        // height==cap height (~10 world for a 9-em cap) ⇒ top near the height.
        let tall = maxY(9)
        #expect(tall > 7 && tall < 11)   // cap glyph 'A' reaches ~cap height
    }

    @Test("text advances horizontally: later glyphs sit to the right")
    func textAdvances() throws {
        let ctx = try contextWithFont()
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: Vector(0, 0), height: 10, text: "AB")))
        let xs = e.resolve(ctx).polylines.flatMap { $0.points }.map(\.x)
        // The run starts at x>=0 and extends well to the right (two glyphs + gap).
        #expect((xs.min() ?? 0) >= -1e-6)
        #expect((xs.max() ?? 0) > 10)   // more than one glyph wide
    }

    @Test("text rotation rotates the whole run about the position")
    func textRotation() throws {
        let ctx = try contextWithFont()
        // Rotate 90° CCW: the baseline run (originally along +x) now runs along +y,
        // so the run's vertical extent grows past its horizontal extent.
        let e = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: Vector(0, 0), height: 10, rotation: .pi / 2, text: "AB"))
        )
        let pts = e.resolve(ctx).polylines.flatMap { $0.points }
        let spanX = (pts.map(\.x).max() ?? 0) - (pts.map(\.x).min() ?? 0)
        let spanY = (pts.map(\.y).max() ?? 0) - (pts.map(\.y).min() ?? 0)
        // After a 90° rotation the run is taller than it is wide.
        #expect(spanY > spanX)
    }

    @Test("text position offsets the strokes")
    func textPositioned() throws {
        let ctx = try contextWithFont()
        let origin = Vector(100, 50)
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: origin, height: 10, text: "A")))
        let pts = e.resolve(ctx).polylines.flatMap { $0.points }
        // All strokes sit at/after the insertion point (left/baseline aligned).
        #expect((pts.map(\.x).min() ?? 0) >= origin.x - 1e-6)
        #expect((pts.map(\.y).min() ?? 0) >= origin.y - 1e-6)
    }

    // MARK: - Text: graceful degradation

    @Test("text with nil fontProvider resolves to empty geometry (no crash)")
    func textNilProviderGraceful() {
        let ctx = ResolveContext()   // no font provider
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: Vector(0, 0), height: 10, text: "ABC")))
        let geo = e.resolve(ctx)
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
    }

    @Test("empty text string resolves to empty geometry")
    func emptyTextGraceful() throws {
        let ctx = try contextWithFont()
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: Vector(0, 0), height: 10, text: "")))
        #expect(e.resolve(ctx).polylines.isEmpty)
    }

    @Test("missing glyph falls back to the replacement glyph, does not crash")
    func missingGlyphFallback() throws {
        // A tiny synthetic font with ONLY 'A' + a U+FFFD replacement (synthesized
        // by the parser). Resolving a string with an absent glyph must still draw
        // (the replacement) and never crash.
        let font = LFFParser.parse(text: "[0041] A\n0,0;6,9")
        let ctx = ResolveContext(fontProvider: SingleStrokeFontProvider(font))
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: Vector(0, 0), height: 10, text: "AZ")))
        let geo = e.resolve(ctx)
        // 'A' draws its stroke; 'Z' (absent) draws the U+FFFD replacement diamond.
        #expect(geo.polylines.count >= 2)
    }

    @Test("unknown font name SUBSTITUTES to the fallback font, no crash (ADR-004 §4.3)")
    func unknownFontGraceful() throws {
        // With no textStyleProvider, an unknown style name synthesizes a native
        // default style. This ctx's provider serves ONLY `.lff` strokes, so the
        // substitution chain falls back native-default → `.lff` "standard" and the
        // text STILL DRAWS (the design's "never vanish, always substitute" rule),
        // never crashing.
        let ctx = try contextWithFont()
        let e = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: Vector(0, 0), height: 10, text: "ABC",
                                 styleName: "no-such-font-xyz"))
        )
        // Substituted to the stroke "standard" → real strokes (not empty).
        #expect(!e.resolve(ctx).polylines.isEmpty)
    }

    @Test("no font provider at all resolves to empty geometry, no crash")
    func noProviderGraceful() {
        // The truly graceful-empty case: no provider wired ⇒ empty geometry.
        let ctx = ResolveContext(tessellationTolerance: 0.01)
        let e = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: Vector(0, 0), height: 10, text: "ABC"))
        )
        let geo = e.resolve(ctx)
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
    }

    // MARK: - Text: bounding box

    @Test("text bounding box is non-empty, sane, and contains the position")
    func textBoundingBox() throws {
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: Vector(5, 7), height: 10, text: "ABC")))
        let box = e.boundingBox()
        #expect(!box.isEmpty)
        // Width grows with character count; height is on the order of the text height.
        #expect(box.size.x > 0)
        #expect(box.size.y > 0)
        #expect(box.size.x > box.size.y)         // "ABC" is wider than it is tall
        // Insertion point lies within the box (left/baseline aligned, descender < 0).
        #expect(box.min.x <= 5 + 1e-9 && box.max.x >= 5 - 1e-9)
    }

    @Test("text bounding box scales with height")
    func textBoundingBoxScales() {
        func box(_ h: Double) -> AABB {
            EntityRecord(id: EntityID(1),
                         kind: .text(TextData(position: .init(0, 0), height: h, text: "AB"))).boundingBox()
        }
        #expect(box(20).size.x > box(5).size.x)
        #expect(box(20).size.y > box(5).size.y)
    }

    // MARK: - Hatch

    @Test("hatch resolves to a single solid fill carrying its boundary loop")
    func hatchResolvesToFill() {
        // A unit square boundary (single loop, no holes).
        let ring = [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ]
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let e = EntityRecord(id: EntityID(1),
                             pen: Pen(lineColor: .explicit(.black)),
                             kind: .hatch(HatchData(loops: [ring], solidFill: true)))
        let geo = e.resolve(ResolveContext())

        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
        let fill = geo.fills[0]
        #expect(fill.loops.count == 1)
        #expect(fill.loops[0] == ring.map(\.point))
        #expect(fill.color == pen.color)
    }

    @Test("hatch preserves multiple loops (outer + hole)")
    func hatchMultiLoop() {
        let outer = (0..<4).map { i in
            PolylineVertex(point: [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)][i])
        }
        let hole = (0..<4).map { i in
            PolylineVertex(point: [Vector(3, 3), Vector(7, 3), Vector(7, 7), Vector(3, 7)][i])
        }
        let e = EntityRecord(id: EntityID(1),
                             kind: .hatch(HatchData(loops: [outer, hole])))
        let geo = e.resolve(ResolveContext())
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].loops.count == 2)
        #expect(geo.fills[0].loops[0] == outer.map(\.point))
        #expect(geo.fills[0].loops[1] == hole.map(\.point))
    }

    @Test("pattern hatch (a KNOWN .pat) resolves to clipped pattern LINES, not a fill")
    func patternHatchResolvesToLines() {
        // ANSI31 is a bundled `.pat` pattern (v5 W4a). A non-solid hatch naming a
        // known pattern now resolves to its clipped pattern lines (polylines),
        // NOT a solid fill. An UNKNOWN pattern still falls back to solid — see
        // HatchPatternResolveTests.unknownPatternFallsBackToSolid.
        let ring = (0..<3).map { i in
            PolylineVertex(point: [Vector(0, 0), Vector(10, 0), Vector(5, 8)][i])
        }
        let e = EntityRecord(id: EntityID(1),
                             kind: .hatch(HatchData(loops: [ring], solidFill: false, patternName: "ANSI31")))
        let geo = e.resolve(ResolveContext())
        #expect(geo.fills.isEmpty)
        #expect(!geo.polylines.isEmpty)
        // Each generated pattern line is a 2-point open segment.
        #expect(geo.polylines.allSatisfy { $0.points.count == 2 && !$0.closed })
    }

    @Test("degenerate hatch (< 3 point loop) resolves to no fill, no crash")
    func degenerateHatchGraceful() {
        let ring = [PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(10, 0))]
        let e = EntityRecord(id: EntityID(1), kind: .hatch(HatchData(loops: [ring])))
        let geo = e.resolve(ResolveContext())
        #expect(geo.fills.isEmpty)
    }

    @Test("hatch bounding box is the union of its loop vertices")
    func hatchBoundingBox() {
        let ring = [
            PolylineVertex(point: Vector(-2, -3)),
            PolylineVertex(point: Vector(8, -3)),
            PolylineVertex(point: Vector(8, 5)),
            PolylineVertex(point: Vector(-2, 5)),
        ]
        let e = EntityRecord(id: EntityID(1), kind: .hatch(HatchData(loops: [ring])))
        let box = e.boundingBox()
        #expect(box.min == Vector(-2, -3))
        #expect(box.max == Vector(8, 5))
    }

    // MARK: - Solid

    @Test("solid triangle resolves to a single fill of its corners")
    func solidTriangleResolves() {
        let corners = [Vector(0, 0), Vector(10, 0), Vector(5, 8)]
        let e = EntityRecord(id: EntityID(1),
                             pen: Pen(lineColor: .explicit(.white)),
                             kind: .solid(SolidData(corners: corners)))
        let geo = e.resolve(ResolveContext())
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].loops.count == 1)
        #expect(geo.fills[0].loops[0] == corners)
        #expect(geo.fills[0].color == RGBAColor.white)
    }

    @Test("solid quad resolves to a 4-corner fill")
    func solidQuadResolves() {
        let corners = [Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]
        let e = EntityRecord(id: EntityID(1), kind: .solid(SolidData(corners: corners)))
        let geo = e.resolve(ResolveContext())
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].loops[0].count == 4)
    }

    @Test("degenerate solid (< 3 corners) resolves to no fill, no crash")
    func degenerateSolidGraceful() {
        let e = EntityRecord(id: EntityID(1),
                             kind: .solid(SolidData(corners: [Vector(0, 0), Vector(1, 1)])))
        #expect(e.resolve(ResolveContext()).fills.isEmpty)
    }

    @Test("solid bounding box is the corner extent")
    func solidBoundingBox() {
        let corners = [Vector(1, 2), Vector(9, 2), Vector(5, 7)]
        let e = EntityRecord(id: EntityID(1), kind: .solid(SolidData(corners: corners)))
        let box = e.boundingBox()
        #expect(box.min == Vector(1, 2))
        #expect(box.max == Vector(9, 7))
    }

    // MARK: - Default font wiring (CADDrawing.makeResolveContext)

    @MainActor
    @Test("CADDrawing.makeResolveContext wires a working default font provider")
    func drawingDefaultFontProvider() {
        // The shared CADFonts provider should resolve the DEFAULT style, which is
        // now a NATIVE font (Helvetica Neue) → outline FILLS (ADR-004 revision).
        let drawing = CADDrawing()
        let ctx = drawing.makeResolveContext()
        #expect(ctx.fontProvider != nil)
        let e = EntityRecord(id: EntityID(1),
                             kind: .text(TextData(position: Vector(0, 0), height: 10, text: "A")))
        // With the default native provider, a text entity resolves to outline fills.
        #expect(e.resolve(ctx).fills.count >= 1)
    }

    @Test("CADFonts stroke provider loads the standard .lff font")
    func cadFontsDefaultProvider() {
        let provider = CADFonts.strokeProvider
        // Default `.lff` font resolves under its name and the empty key.
        #expect(provider.font(named: "standard") != nil)
        #expect(provider.font(named: "") != nil)
        #expect((provider.font(named: "standard")?.glyph(for: Character("A"))) != nil)
    }
}
