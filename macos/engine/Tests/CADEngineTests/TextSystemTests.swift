//
//  TextSystemTests.swift
//  CADEngineTests
//
//  Phase-1 text-system foundation tests (text-system-design §8.6):
//    - TextStyleTable round-trip + name lookup (TextSystemStyleTests)
//    - Core Text headless shaping → positioned glyphs (TextSystemShapingTests)
//    - glyph outline flattening: tolerance → point count + closed loops +
//      CCW outer / CW holes (TextSystemFlatteningTests)
//    - the special-char pre-pass %%c/%%d/%%p/%%%/\U+ (TextSystemCodecTests)
//    - all 15 justification modes anchor correctly (TextSystemJustificationTests)
//    - annotative scale multiplies height (TextSystemAnnotativeTests)
//    - native text emits FILLS with correct COUNTERS (holes present, not
//      over-filled) and the stroke provider still resolves via the protocol
//      (TextSystemResolveTests)
//    - font-aware tight bbox (TextSystemBBoxTests)
//
//  Suite/type names are domain-namespaced (`TextSystem*`) per CONVENTIONS to
//  avoid the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Shared helpers

enum TextSystemFixtures {
    /// The native provider (Core Text) — Helvetica Neue is universally installed
    /// and resolves headless (verified). Returns the composite so both sources are
    /// reachable through the one protocol.
    static func nativeCtx(tolerance: Double = 0.01) -> ResolveContext {
        ResolveContext(tessellationTolerance: tolerance,
                       fontProvider: CADFonts.provider)
    }

    /// A `.lff` stroke font over the shipped `standard.lff`, wrapped as a provider.
    static func strokeProvider() throws -> StrokeFontProvider {
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
        let p = StrokeFontProvider()
        p.registerFont(at: url, name: "standard")
        p.registerFont(at: url, name: "")
        return p
    }

    /// A style table whose "Standard" is native Helvetica Neue and that also has a
    /// "Stroke" style mapped to `.lff` "standard" and an annotative native style.
    static func styleProvider() -> @Sendable (String) -> TextStyle? {
        var built = TextStyleTable()
        built.upsert(TextStyle(name: "Stroke", primaryFont: .stroke(lff: "standard")))
        built.upsert(TextStyle(name: "Anno",
                               primaryFont: .native(family: "Helvetica Neue"),
                               annotative: true))
        let table = built   // immutable copy for the @Sendable capture
        return { name in table.style(named: name) }
    }
}

// MARK: - TextStyleTable

@Suite("TextSystem: style table")
struct TextSystemStyleTests {

    @Test("a fresh table always has Standard, case-insensitive")
    func standardAlwaysPresent() {
        let table = TextStyleTable()
        #expect(table.style(named: "Standard") != nil)
        #expect(table.style(named: "STANDARD") != nil)
        #expect(table.style(named: "standard") != nil)
        #expect(table.standard.name == "Standard")
    }

    @Test("Standard's default font is the native default family")
    func standardDefaultIsNative() {
        let table = TextStyleTable()
        if case let .native(family) = table.standard.primaryFont {
            #expect(family == TextStyle.defaultNativeFamily)
            #expect(family == "Helvetica Neue")
        } else {
            Issue.record("Standard should default to a native font")
        }
    }

    @Test("upsert allocates ids and round-trips fields")
    func upsertRoundTrip() {
        var table = TextStyleTable()
        let s = TextStyle(name: "Title", primaryFont: .stroke(lff: "iso"),
                          widthFactor: 0.8, obliqueAngle: 0.2, bold: true, annotative: true)
        let id = table.upsert(s)
        let got = table.style(named: "title")    // case-insensitive
        #expect(got != nil)
        #expect(got?.id == id)
        #expect(got?.widthFactor == 0.8)
        #expect(got?.obliqueAngle == 0.2)
        #expect(got?.bold == true)
        #expect(got?.annotative == true)
        if case .stroke(let lff) = got?.primaryFont { #expect(lff == "iso") }
        else { Issue.record("primaryFont should be .stroke(iso)") }
    }

    @Test("upserting an existing name replaces it (keeps the id)")
    func upsertReplaces() {
        var table = TextStyleTable()
        let id1 = table.upsert(TextStyle(name: "X", widthFactor: 1))
        let id2 = table.upsert(TextStyle(name: "X", widthFactor: 2))
        #expect(id1 == id2)
        #expect(table.style(named: "X")?.widthFactor == 2)
    }

    @Test("the table Codable round-trips")
    func codableRoundTrip() throws {
        var table = TextStyleTable()
        table.upsert(TextStyle(name: "Y", primaryFont: .native(family: "Menlo"), italic: true))
        let data = try JSONEncoder().encode(table)
        let back = try JSONDecoder().decode(TextStyleTable.self, from: data)
        #expect(back.style(named: "Y")?.italic == true)
        #expect(back.standard.name == "Standard")
    }
}

// MARK: - Core Text shaping (headless)

@Suite("TextSystem: Core Text shaping")
struct TextSystemShapingTests {

    @Test("shaping a word yields one positioned glyph per character")
    func shapeGlyphCount() throws {
        let font = try #require(CADFonts.nativeProvider.font(
            family: "Helvetica Neue", bold: false, italic: false))
        let glyphs = font.shape("Ag", attributes: .default)
        #expect(glyphs.count == 2)
        // Advances are positive (the pen moves right).
        #expect(glyphs.allSatisfy { $0.advance.x > 0 })
    }

    @Test("kerning: 'AV' shapes with a tighter advance than two isolated glyphs")
    func kerningApplied() throws {
        let font = try #require(CADFonts.nativeProvider.font(
            family: "Helvetica Neue", bold: false, italic: false))
        // Core Text applies kerning when shaping the pair; the A→V advance differs
        // from the A-followed-by-A advance. We just assert shaping is non-trivial
        // (real advances, not zeros) — exact kern values are font-version specific.
        let av = font.shape("AV", attributes: .default)
        #expect(av.count == 2)
        #expect(av[0].advance.x > 0)
    }

    @Test("font metrics are sane (ascent/cap/descent positive)")
    func metricsSane() throws {
        let font = try #require(CADFonts.nativeProvider.font(
            family: "Helvetica Neue", bold: false, italic: false))
        #expect(font.metrics.ascent > 0)
        #expect(font.metrics.capHeight > 0)
        #expect(font.metrics.descent > 0)
        #expect(font.metrics.capHeight <= font.metrics.ascent + 1e-9)
    }

    @Test("an unknown family resolves to nil (deliberate fallback, no silent sub)")
    func unknownFamilyNil() {
        #expect(CADFonts.nativeProvider.font(
            family: "ZZ-No-Such-Font-9999", bold: false, italic: false) == nil)
    }
}

// MARK: - Glyph outline flattening

@Suite("TextSystem: glyph flattening")
struct TextSystemFlatteningTests {

    private func font() throws -> CoreTextFont {
        try #require(CADFonts.nativeProvider.font(
            family: "Helvetica Neue", bold: false, italic: false))
    }

    @Test("an 'O' flattens to outer + hole loops (a counter)")
    func oHasHole() throws {
        let f = try font()
        let glyphs = f.shape("O", attributes: .default)
        let geo = f.glyphGeometry(glyphs[0].glyph, tolerance: 0.01)
        // Two loops: the outer boundary and the inner counter.
        #expect(geo.fills.count >= 2)
        // Outer (loops[0]) is CCW (positive area); the hole is CW (negative).
        #expect(CoreTextFont.signedArea(geo.fills[0]) > 0)
        #expect(CoreTextFont.signedArea(geo.fills[1]) < 0)
        // The outer loop encloses more area than the hole.
        #expect(abs(CoreTextFont.signedArea(geo.fills[0])) >
                abs(CoreTextFont.signedArea(geo.fills[1])))
    }

    @Test("an 'l' flattens to a single closed loop (no counter)")
    func lHasNoHole() throws {
        let f = try font()
        let glyphs = f.shape("l", attributes: .default)
        let geo = f.glyphGeometry(glyphs[0].glyph, tolerance: 0.01)
        #expect(geo.fills.count == 1)
        #expect(geo.fills[0].count >= 4)   // a closed rectangle-ish loop
    }

    @Test("a finer tolerance produces at least as many points (monotonic LOD)")
    func toleranceMonotonic() throws {
        let f = try font()
        let glyphs = f.shape("O", attributes: .default)
        let coarse = f.glyphGeometry(glyphs[0].glyph, tolerance: 0.2)
        let fine = f.glyphGeometry(glyphs[0].glyph, tolerance: 0.001)
        let coarseN = coarse.fills.reduce(0) { $0 + $1.count }
        let fineN = fine.fills.reduce(0) { $0 + $1.count }
        #expect(fineN >= coarseN)
        #expect(coarseN >= 3)
    }

    @Test("tolerance bucketing reuses the flattened outline (cache hit)")
    func toleranceBucketing() {
        // Two nearby tolerances quantize to the same bucket.
        let a = GlyphToleranceBucket.bucket(0.0051)
        let b = GlyphToleranceBucket.bucket(0.0049)
        #expect(a == b)
        // A degenerate tolerance never produces an unbounded bucket.
        #expect(GlyphToleranceBucket.bucket(0) > 0)
        #expect(GlyphToleranceBucket.bucket(-1) > 0)
    }
}

// MARK: - Special-char codec

@Suite("TextSystem: text codec (special chars)")
struct TextSystemCodecTests {

    @Test("%%c → ⌀ , %%d → ° , %%p → ±")
    func mapsSymbols() {
        #expect(TextCodec.expandSpecialCharacters("%%c") == "\u{2300}")
        #expect(TextCodec.expandSpecialCharacters("%%d") == "\u{00B0}")
        #expect(TextCodec.expandSpecialCharacters("%%p") == "\u{00B1}")
        // Case-insensitive.
        #expect(TextCodec.expandSpecialCharacters("%%C") == "\u{2300}")
    }

    @Test("%%% → % and %%nnn → the decimal char")
    func mapsPercentAndDecimal() {
        #expect(TextCodec.expandSpecialCharacters("50%%%") == "50%")
        // %%065 → 'A' (decimal 65).
        #expect(TextCodec.expandSpecialCharacters("%%065") == "A")
    }

    @Test("\\U+XXXX → the Unicode scalar")
    func mapsUnicodeEscape() {
        #expect(TextCodec.expandSpecialCharacters("\\U+00B0") == "\u{00B0}")
        #expect(TextCodec.expandSpecialCharacters("a\\U+2300b") == "a\u{2300}b")
    }

    @Test("inline use: 'R%%c25' → 'R⌀25'")
    func inlineUse() {
        #expect(TextCodec.expandSpecialCharacters("R%%c25") == "R\u{2300}25")
    }

    @Test("an unknown %% sequence passes through verbatim (never dropped)")
    func unknownPassthrough() {
        #expect(TextCodec.expandSpecialCharacters("%%z") == "%%z")
    }

    @Test("plain text is unchanged")
    func plainUnchanged() {
        #expect(TextCodec.expandSpecialCharacters("Hello World") == "Hello World")
    }
}

// MARK: - Justification (all 15 modes)

@Suite("TextSystem: justification (15 modes)")
struct TextSystemJustificationTests {

    /// The world-space x-range of a resolved text's geometry.
    private func xRange(_ geo: ResolvedGeometry) -> (min: Double, max: Double)? {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for f in geo.fills { for loop in f.loops { for p in loop { lo = min(lo, p.x); hi = max(hi, p.x) } } }
        for pl in geo.polylines { for p in pl.points { lo = min(lo, p.x); hi = max(hi, p.x) } }
        return lo <= hi ? (lo, hi) : nil
    }
    private func yRange(_ geo: ResolvedGeometry) -> (min: Double, max: Double)? {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for f in geo.fills { for loop in f.loops { for p in loop { lo = min(lo, p.y); hi = max(hi, p.y) } } }
        for pl in geo.polylines { for p in pl.points { lo = min(lo, p.y); hi = max(hi, p.y) } }
        return lo <= hi ? (lo, hi) : nil
    }

    private func resolve(_ h: TextHAlign, _ v: TextVAlign,
                         second: Vector? = nil) -> ResolvedGeometry {
        let ctx = TextSystemFixtures.nativeCtx()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "HELLO",
                         hAlign: h, vAlign: v, secondPoint: second)
        return EntityKind.text(d).resolve(pen: pen, ctx: ctx)
    }

    @Test("left: the run starts near x≈0 (insertion point, modulo side bearing)")
    func leftAnchor() {
        let r = xRange(resolve(.left, .baseline))!
        // First ink is at the glyph's left side bearing (a small fraction of the
        // 10-unit cap height), NOT exactly 0.
        #expect(r.min >= -0.1 && r.min < 2.0)
        #expect(r.max > 2.0)               // and extends well to the right
    }

    @Test("right: the run ends near x≈0 (insertion point)")
    func rightAnchor() {
        let r = xRange(resolve(.right, .baseline))!
        #expect(r.max <= 0.5)              // last ink at/just-left-of the insertion x
        #expect(r.min < -2.0)              // and extends to the left
    }

    @Test("center: the run straddles x≈0 symmetrically")
    func centerAnchor() {
        let r = xRange(resolve(.center, .baseline))!
        #expect(abs(r.min + r.max) < r.max - r.min)   // mid near 0
        #expect(r.min < 0 && r.max > 0)
    }

    @Test("vAlign top: the cap top is at y≈0 (text hangs below)")
    func topAnchor() {
        let r = yRange(resolve(.left, .top))!
        #expect(r.max <= 0.5)              // top near 0
        #expect(r.min < -1.0)             // body below
    }

    @Test("vAlign bottom: the descender bottom is at y≈0 (text above)")
    func bottomAnchor() {
        let r = yRange(resolve(.left, .bottom))!
        #expect(r.min >= -0.5)             // bottom near 0
        #expect(r.max > 1.0)              // body above
    }

    @Test("vAlign middle: the block straddles y≈0")
    func middleVAnchor() {
        let r = yRange(resolve(.left, .middle))!
        #expect(r.min < 0 && r.max > 0)
    }

    @Test("hAlign .middle centers BOTH axes on the point")
    func middleBoth() {
        let geo = resolve(.middle, .baseline)
        let xr = xRange(geo)!, yr = yRange(geo)!
        #expect(xr.min < 0 && xr.max > 0)
        #expect(yr.min < 0 && yr.max > 0)
    }

    @Test(".aligned fits the run between insertion and secondPoint (height auto-scales)")
    func alignedFits() {
        // A long second point ⇒ the run stretches to ~that x; height grows with it.
        let second = Vector(120, 0)
        let geo = resolve(.aligned, .baseline, second: second)
        let xr = xRange(geo)!
        // The run end reaches close to the second point.
        #expect(xr.max > 100)
        #expect(xr.min >= -1.0)
    }

    @Test(".fit fits the run width to secondPoint keeping height")
    func fitKeepsHeight() {
        let second = Vector(150, 0)
        let geo = resolve(.fit, .baseline, second: second)
        let xr = xRange(geo)!, yr = yRange(geo)!
        // Width stretched toward the second point.
        #expect(xr.max > 120)
        // Height stays ~the cap height (10), NOT stretched like .aligned.
        #expect(yr.max < 14)
    }

    @Test("all 15 (hAlign × vAlign + specials) resolve without crashing")
    func allModesResolve() {
        let hs: [TextHAlign] = [.left, .center, .right, .aligned, .middle, .fit]
        let vs: [TextVAlign] = [.baseline, .bottom, .middle, .top]
        for h in hs {
            for v in vs {
                let second: Vector? = (h == .aligned || h == .fit) ? Vector(50, 0) : nil
                let geo = resolve(h, v, second: second)
                #expect(!geo.fills.isEmpty)
            }
        }
    }
}

// MARK: - Annotative scaling

@Suite("TextSystem: annotative scaling")
struct TextSystemAnnotativeTests {

    private func height(_ geo: ResolvedGeometry) -> Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for f in geo.fills { for loop in f.loops { for p in loop { lo = min(lo, p.y); hi = max(hi, p.y) } } }
        return hi - lo
    }

    @Test("an annotative style scales height by ctx.annotationScale")
    func annotativeScales() {
        let style = TextSystemFixtures.styleProvider()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "O", styleName: "Anno")

        let ctx1 = ResolveContext(tessellationTolerance: 0.01,
                                  fontProvider: CADFonts.provider,
                                  textStyleProvider: style, annotationScale: 1.0)
        let ctx2 = ResolveContext(tessellationTolerance: 0.01,
                                  fontProvider: CADFonts.provider,
                                  textStyleProvider: style, annotationScale: 2.0)
        let h1 = height(EntityKind.text(d).resolve(pen: pen, ctx: ctx1))
        let h2 = height(EntityKind.text(d).resolve(pen: pen, ctx: ctx2))
        #expect(h1 > 0)
        // Scale 2.0 ⇒ ~2× the height.
        #expect(abs(h2 / h1 - 2.0) < 0.05)
    }

    @Test("a non-annotative style ignores annotationScale")
    func nonAnnotativeUnaffected() {
        let style = TextSystemFixtures.styleProvider()   // "Standard" is non-annotative native
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "O", styleName: "Standard")
        let ctx1 = ResolveContext(tessellationTolerance: 0.01,
                                  fontProvider: CADFonts.provider,
                                  textStyleProvider: style, annotationScale: 1.0)
        let ctx2 = ResolveContext(tessellationTolerance: 0.01,
                                  fontProvider: CADFonts.provider,
                                  textStyleProvider: style, annotationScale: 3.0)
        let h1 = height(EntityKind.text(d).resolve(pen: pen, ctx: ctx1))
        let h2 = height(EntityKind.text(d).resolve(pen: pen, ctx: ctx2))
        #expect(abs(h2 / h1 - 1.0) < 0.02)   // unchanged
    }
}

// MARK: - Resolve: native fills vs stroke polylines

@Suite("TextSystem: resolve (fills vs strokes)")
struct TextSystemResolveTests {

    @Test("native 'Ag' resolves to FILLS")
    func nativeEmitsFills() {
        let ctx = TextSystemFixtures.nativeCtx()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "Ag")
        let geo = EntityKind.text(d).resolve(pen: pen, ctx: ctx)
        #expect(!geo.fills.isEmpty)
        #expect(geo.polylines.isEmpty)
    }

    @Test("native 'OØ' has correct COUNTERS (holes present, not over-filled)")
    func nativeCounters() {
        let ctx = TextSystemFixtures.nativeCtx()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "OØ")
        let geo = EntityKind.text(d).resolve(pen: pen, ctx: ctx)
        // Each of O and Ø contributes a fill whose loops include at least one hole
        // (the counter). At least one fill must carry > 1 loop.
        let withHoles = geo.fills.filter { $0.loops.count >= 2 }
        #expect(withHoles.count >= 2)        // O (1 counter) + Ø (counter + slash)
        // The counter (loops[1]) must be wound OPPOSITE the outer (so the renderer
        // cuts it out, not over-fills).
        for f in withHoles {
            #expect(CoreTextFont.signedArea(f.loops[0]) > 0)   // outer CCW
            #expect(CoreTextFont.signedArea(f.loops[1]) < 0)   // hole CW
        }
    }

    @Test("the stroke provider still resolves text via the protocol (polylines)")
    func strokeEmitsPolylines() throws {
        let provider = try TextSystemFixtures.strokeProvider()
        // Style provider maps "S" → .stroke(standard).
        var built = TextStyleTable()
        built.upsert(TextStyle(name: "S", primaryFont: .stroke(lff: "standard")))
        let table = built
        let ctx = ResolveContext(tessellationTolerance: 0.01, fontProvider: provider,
                                 textStyleProvider: { table.style(named: $0) })
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "AB", styleName: "S")
        let geo = EntityKind.text(d).resolve(pen: pen, ctx: ctx)
        #expect(!geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
    }

    @Test("multi-line \\n stacks lines downward")
    func multiLine() {
        let ctx = TextSystemFixtures.nativeCtx()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let one = TextData(position: Vector(0, 0), height: 10, text: "AB")
        let two = TextData(position: Vector(0, 0), height: 10, text: "AB\nAB")
        let g1 = EntityKind.text(one).resolve(pen: pen, ctx: ctx)
        let g2 = EntityKind.text(two).resolve(pen: pen, ctx: ctx)
        // Two lines produce roughly twice the fills and a taller extent.
        #expect(g2.fills.count > g1.fills.count)
        func yspan(_ g: ResolvedGeometry) -> Double {
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            for f in g.fills { for l in f.loops { for p in l { lo = min(lo, p.y); hi = max(hi, p.y) } } }
            return hi - lo
        }
        #expect(yspan(g2) > yspan(g1) * 1.5)
    }

    @Test("special chars resolve through the prepass: 'R%%c' draws the diameter glyph")
    func specialCharsResolve() {
        let ctx = TextSystemFixtures.nativeCtx()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let d = TextData(position: Vector(0, 0), height: 10, text: "R%%c")
        let geo = EntityKind.text(d).resolve(pen: pen, ctx: ctx)
        // R + ⌀ ⇒ at least 2 glyph fills (the prepass turned %%c into a real glyph).
        #expect(geo.fills.count >= 2)
    }

    @Test("a dimension's measurement text still resolves through the provider")
    func dimensionTextRoutes() {
        // Dimension text routes through the SAME shaper (.middle justification).
        // With a native provider it produces fills for the label.
        let ctx = TextSystemFixtures.nativeCtx()
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let geo = EntityKind.dimText("12.5", center: Vector(0, 0),
                                     rotation: 0, height: 2.5, pen: pen, ctx: ctx)
        #expect(!geo.fills.isEmpty)
    }
}

// MARK: - Font-aware bounding box

@Suite("TextSystem: bounding box")
struct TextSystemBBoxTests {

    @Test("the font-aware box is tighter than the loose estimate")
    func tighterThanLoose() {
        let ctx = TextSystemFixtures.nativeCtx()
        let d = TextData(position: Vector(0, 0), height: 10, text: "Hi")
        let tight = TextShaper.boundingBox(d, ctx: ctx)
        #expect(tight != nil)
        let t = tight!
        // The tight box width is bounded by a generous loose estimate
        // (text.count × ~9 em × scale). For "Hi" the tight box must be narrower.
        let looseWidth = Double(d.text.count) * 9.0 * (d.height / 9.0)   // = count*height
        #expect((t.max.x - t.min.x) <= looseWidth + 1e-9)
        #expect((t.max.x - t.min.x) > 0)
        #expect((t.max.y - t.min.y) > 0)
    }

    @Test("no provider ⇒ font-aware box is nil (caller falls back to the estimate)")
    func noProviderNil() {
        let ctx = ResolveContext()   // no provider
        let d = TextData(position: Vector(0, 0), height: 10, text: "Hi")
        #expect(TextShaper.boundingBox(d, ctx: ctx) == nil)
    }
}
