//
//  LFFFontTests.swift
//  CADEngineTests
//
//  Tests for the `.lff` stroke-font loader (ADR-004): parse a shipped LibreCAD
//  font, verify glyph extraction, `C<hex>` reference resolution, bulge handling,
//  metadata, and graceful failure on bad input.
//
//  Font fixture: `librecad/support/fonts/standard.lff` (ISO 3098-2). The test
//  target's `Package.swift` only `.copy`s `dim_sample.dxf`, and we are not
//  permitted to edit the manifest to declare another bundled resource (doing so
//  unbundled would emit an "unhandled resource" build warning). So the fixture
//  is read by repo path, derived from this file's `#filePath` (stable/absolute),
//  with a `Bundle.module` attempt first in case the manifest later bundles it.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("LFF stroke font")
struct LFFFontTests {

    // MARK: - Fixture location

    /// Locates `standard.lff`: prefer the test bundle (future-proof), else walk
    /// up from this source file to the repo's `librecad/support/fonts`.
    private func standardFontURL() throws -> URL {
        if let bundled = Bundle.module.url(forResource: "standard", withExtension: "lff") {
            return bundled
        }
        // <repo>/macos/engine/Tests/CADEngineTests/LFFFontTests.swift -> up 4 -> <repo>
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // CADEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // <repo>
        let url = repoRoot
            .appendingPathComponent("librecad/support/fonts/standard.lff")
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "standard.lff fixture not found at \(url.path)"
        )
        return url
    }

    private func loadStandard() throws -> StrokeFont {
        try LFFParser.load(contentsOf: standardFontURL())
    }

    // MARK: - Basic parse + metadata

    @Test("parses the shipped standard.lff: glyphs present, metadata read")
    func parsesStandard() throws {
        let font = try loadStandard()

        // standard.lff has ~220 glyph blocks; assert it parsed a real font.
        #expect(font.glyphCount > 0)
        #expect(font.glyphCount > 100)

        // Metadata from the file header:
        //   # LetterSpacing: 3 / # WordSpacing: 6.75 / # LineSpacingFactor: 1
        //   # Encoding: UTF-8 / # Name: ISO 3098-2 / # License: GPL v2 or later
        #expect(font.letterSpacing == 3.0)
        #expect(font.wordSpacing == 6.75)
        #expect(font.lineSpacingFactor == 1.0)
        #expect(font.encoding == "UTF-8")
        #expect(font.names.contains("ISO 3098-2"))
        #expect(font.license.lowercased().contains("gpl"))
        #expect(!font.authors.isEmpty)
    }

    // MARK: - Known glyph: 'A' (U+0041)

    @Test("glyph 'A' (U+0041) has >=1 stroke with sensible em coords")
    func glyphA() throws {
        let font = try loadStandard()
        let g = try #require(font.glyph(for: Character("A")), "no glyph for 'A'")

        // In standard.lff, 'A' is two strokes: a crossbar and the inverted-V.
        #expect(g.strokes.count >= 1)
        #expect(!g.isEmpty)

        // Every point must be in a sane em range (cap height ~9, never wild).
        let allPoints = g.strokes.flatMap { $0 }
        #expect(!allPoints.isEmpty)
        for p in allPoints {
            #expect(p.x >= -2 && p.x <= 12)
            #expect(p.y >= -4 && p.y <= 16)
        }

        // The inverted-V apex reaches near the cap height (~9).
        let maxY = allPoints.map(\.y).max() ?? 0
        #expect(maxY > 5)
    }

    @Test("scalar lookup matches Character lookup for 'A'")
    func scalarLookupA() throws {
        let font = try loadStandard()
        let byChar = font.glyph(for: Character("A"))
        let byScalar = font.glyph(for: UnicodeScalar(0x0041)!)
        #expect(byChar == byScalar)
        #expect(byScalar != nil)
    }

    // MARK: - C-reference resolution: 'À' (U+00C0) includes C0041 ('A')

    @Test("'À' (U+00C0) resolves its C0041 reference: includes all of 'A' strokes + accent")
    func referencedGlyphResolves() throws {
        let font = try loadStandard()
        let a = try #require(font.glyph(for: Character("A")))
        let agrave = try #require(font.glyph(for: Character("À")), "no glyph for 'À'")

        // 'À' in standard.lff is `C0041` (include 'A') plus one accent stroke.
        // So it must have strictly MORE strokes than 'A', and contain all of
        // 'A's strokes (reference resolution copied them in).
        #expect(agrave.strokes.count == a.strokes.count + 1)
        for stroke in a.strokes {
            #expect(agrave.strokes.contains(stroke),
                    "À must include every stroke of the referenced 'A'")
        }

        // The accent sits ABOVE the cap height (y around 11.5–13 in the file).
        let agraveMaxY = agrave.strokes.flatMap { $0 }.map(\.y).max() ?? 0
        let aMaxY = a.strokes.flatMap { $0 }.map(\.y).max() ?? 0
        #expect(agraveMaxY > aMaxY)
    }

    // MARK: - Synthetic reference resolution (chain + cycle guard)

    @Test("synthetic: C-reference chains resolve, self/cycle references are ignored")
    func syntheticReferenceResolution() {
        // [0041] base: one stroke.  [00C0] -> C0041 + own stroke.
        // [00C1] -> C00C0 (chain) .  [0042] -> C0042 (self-ref, ignored).
        // [0043] -> C0044 ; [0044] -> C0043 (cycle, both ignored).
        let text = """
        # Name: synthetic

        [0041] A
        0,0;6,9

        [00c0] À
        C0041
        2,13;4,11.5

        [00c1] Á
        C00c0
        2,11.5;4,13

        [0042] B
        C0042
        0,0;3,3

        [0043] C
        C0044

        [0044] D
        C0043
        """
        let font = LFFParser.parse(text: text)

        let a = font.glyph(for: UnicodeScalar(0x0041)!)
        #expect(a?.strokes.count == 1)

        // À = A's stroke + accent = 2 strokes.
        let agrave = font.glyph(for: UnicodeScalar(0x00C0)!)
        #expect(agrave?.strokes.count == 2)

        // Á chains through À (which itself references A) + own stroke = 3.
        let aacute = font.glyph(for: UnicodeScalar(0x00C1)!)
        #expect(aacute?.strokes.count == 3)

        // B self-references; the self-ref is ignored, only its real stroke remains.
        let b = font.glyph(for: UnicodeScalar(0x0042)!)
        #expect(b?.strokes.count == 1)

        // C<->D form a cycle with no real strokes; cycle guard => empty glyphs.
        let c = font.glyph(for: UnicodeScalar(0x0043)!)
        let d = font.glyph(for: UnicodeScalar(0x0044)!)
        #expect(c?.strokes.isEmpty == true)
        #expect(d?.strokes.isEmpty == true)
    }

    // MARK: - Bulge handling

    @Test("bulge segment tessellates into an arc (more points than the chord)")
    func bulgeTessellation() throws {
        // One stroke from (0,0) to (10,0) with a semicircle bulge (A1 => 180°).
        let text = """
        [0041] A
        0,0,A1;10,0
        """
        let font = LFFParser.parse(text: text)
        let g = try #require(font.glyph(for: UnicodeScalar(0x0041)!))
        let pts = try #require(g.strokes.first)

        #expect(pts.count > 2)   // tessellated, not a straight 2-point chord
        #expect(pts.first!.distance(to: Vector(0, 0)) < 1e-6)
        #expect(pts.last!.distance(to: Vector(10, 0)) < 1e-6)
        // Apex of a unit-bulge (semicircle) over chord 10 is at y≈5 (radius 5).
        let maxY = pts.map(\.y).max()!
        #expect(abs(maxY - 5) < 0.2)
    }

    @Test("missing y-coordinate defaults to 0 (Issue #2045)")
    func missingYDefaultsToZero() {
        let text = """
        [0041] A
        0;5,3
        """
        let font = LFFParser.parse(text: text)
        let g = font.glyph(for: UnicodeScalar(0x0041)!)
        let pts = g?.strokes.first
        #expect(pts?.first == Vector(0, 0))   // "0" -> (0, 0)
        #expect(pts?.last == Vector(5, 3))
    }

    // MARK: - Tolerant parsing & graceful failure

    @Test("single-vertex strokes are skipped (need >= 2 vertices)")
    func singleVertexStrokeSkipped() {
        let text = """
        [0041] A
        3,3
        0,0;6,9
        """
        let font = LFFParser.parse(text: text)
        let g = font.glyph(for: UnicodeScalar(0x0041)!)
        // The "3,3" lone vertex is dropped; only the 2-point stroke survives.
        #expect(g?.strokes.count == 1)
        #expect(g?.strokes.first?.count == 2)
    }

    @Test("comment-only '#' lines (no ':') are ignored, not treated as metadata")
    func commentLinesIgnored() {
        let text = """
        # this is a free-form comment with no colon
        # Name: T

        [0041] A
        0,0;6,9
        """
        let font = LFFParser.parse(text: text)
        #expect(font.names == ["T"])
        #expect(font.glyphCount >= 1)
    }

    @Test("font always provides a U+FFFD replacement glyph")
    func replacementGlyphSynthesized() {
        let font = LFFParser.parse(text: "[0041] A\n0,0;6,9")
        #expect(font.replacementGlyph != nil)
        #expect(font.glyph(for: UnicodeScalar(0xFFFD)!) != nil)
    }

    @Test("missing file throws cannotReadFile, does not crash")
    func missingFileThrows() {
        let url = URL(fileURLWithPath: "/nonexistent/path/no-such-font.lff")
        #expect(throws: LFFFontError.self) {
            _ = try LFFParser.load(contentsOf: url)
        }
    }

    @Test("malformed / empty content parses to an (almost) empty font, no crash")
    func malformedContentIsGraceful() {
        // Garbage that resembles nothing: no glyph headers, no metadata pairs.
        let font = LFFParser.parse(text: "garbage\n!!!\n,,,\n;;;\n")
        // No real glyphs, but the synthesized U+FFFD fallback is always present.
        #expect(font.glyphCount == 1)
        #expect(font.replacementGlyph != nil)
    }

    // MARK: - StrokeFontProvider

    @Test("provider loads + caches by name; same instance returned")
    func providerLoadsAndCaches() throws {
        let fontURL = try standardFontURL()
        let provider = StrokeFontProvider()
        let key = provider.registerFont(at: fontURL)
        #expect(key == "standard")

        let f1 = provider.font(named: "standard")
        let f2 = provider.font(named: "Standard.lff")   // case- & ext-insensitive
        #expect(f1 != nil)
        #expect(f1 === f2)                               // cached (same reference)
        #expect((f1?.glyphCount ?? 0) > 100)
    }

    @Test("provider search directory resolves <name>.lff")
    func providerSearchDirectory() throws {
        let fontURL = try standardFontURL()
        let provider = StrokeFontProvider()
        provider.registerSearchDirectory(fontURL.deletingLastPathComponent())
        let f = provider.font(named: "standard")
        #expect(f != nil)
        #expect(f?.glyph(for: Character("A")) != nil)
    }

    @Test("provider returns nil for an unknown font (and caches the miss)")
    func providerUnknownFont() {
        let provider = StrokeFontProvider()
        #expect(provider.font(named: "does-not-exist-xyz") == nil)
        // Second call hits the cached miss (still nil, no crash).
        #expect(provider.font(named: "does-not-exist-xyz") == nil)
    }

    @Test("makeProvider() yields the reserved ((String) -> StrokeFont?) closure")
    func makeProviderClosureShape() throws {
        let fontURL = try standardFontURL()
        let provider = StrokeFontProvider()
        provider.registerFont(at: fontURL)
        // This is exactly the shape ResolveContext.fontProvider reserves.
        let hook: @Sendable (String) -> StrokeFont? = provider.makeProvider()
        #expect(hook("standard") != nil)
        #expect(hook("nope") == nil)
    }
}
