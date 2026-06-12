//
//  SHXFontTests.swift
//  CADEngineTests
//
//  Tests for the AutoCAD compiled SHAPE-font (`.shx`) parser, provider, and the
//  font-substitution chain (ADR-004; text-system-design §"SHX, Phase 3").
//
//  We cannot ship real AutoCAD `.shx` fixtures (they are licensed). So the parser
//  is exercised against a HAND-CONSTRUCTED minimal "shapes 1.0" byte buffer built
//  in `MinimalSHX` below: a font-header shape (#0), a space, an 'L' drawn with
//  signed (x,y) line moves, and an 'O' drawn with an octant arc — asserting the
//  decoded strokes + advance. A truncated buffer must THROW (no crash). The
//  substitution-chain ordering is tested with a fake provider that records which
//  sources it is asked for. Real-font fidelity (true glyph shapes for a specific
//  licensed font) needs a licensed `.shx` to fully verify; this suite verifies the
//  decode mechanics + graceful degradation.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("SHX shape font")
struct SHXFontTests {

    // MARK: - Minimal hand-built SHX buffer

    /// Builds a tiny but VALID "AutoCAD-86 shapes 1.0" buffer exercising line
    /// moves + an octant arc + advances. Layout produced (the format the parser
    /// reads): signature line + 0x0D 0x0A 0x1A terminator, then the index table
    /// (`startShape:u16`, `count:u16`, then `count×(shapeNo:u16, len:u16)`), then
    /// the data blocks in directory order (each: NUL-terminated name + bytecode).
    enum MinimalSHX {

        // Bytecode for each shape (the body AFTER the name string).
        // Shape 0 (font header): above-baseline=20, below-baseline=7, modes=0, end.
        static let shape0Body: [UInt8] = [20, 7, 0, 0x00]

        // Space (0x20): pen up, advance only via an 0x08 move of (+10, 0), end.
        // 0x02 = pen up; 0x08 dx dy = signed move; 0x00 end.
        static let spaceBody: [UInt8] = [0x02, 0x08, 10, 0, 0x00]

        // 'L' (0x4C): pen down at origin, go DOWN 14 then RIGHT 8 (two line moves),
        // forming an L. Uses 0x08 (signed x,y) so coordinates are exact.
        //   0x01 pen down; 0x08 0 -14 (down); 0x08 8 0 (right); 0x00 end.
        static let lBody: [UInt8] = [
            0x01,
            0x08, 0, UInt8(bitPattern: -14),
            0x08, 8, 0,
            0x00,
        ]

        // 'O' (0x4F): a single octant arc making a full circle whose center is to
        // the RIGHT of the pen (so the glyph has positive ink width), then a pen-up
        // advance move so the next glyph clears it.
        //   0x01 pen down; 0x0A radius=8, spec; 0x02 pen up; 0x08 +2 0 (advance gap);
        //   0x00 end.
        // octant-arc spec byte: sign bit 0 ⇒ CCW; low nibble = octant count (0 ⇒
        // full 8 octants = full circle); high nibble = start octant (4 = west, so the
        // center sits 8 units to the RIGHT of the pen ⇒ circle spans x∈[0,16]).
        static let oBody: [UInt8] = [
            0x01, 0x0A, 8, 0x40,
            0x02, 0x08, 2, 0,
            0x00,
        ]

        /// Assembles the full buffer.
        static func buffer() -> [UInt8] {
            var bytes: [UInt8] = []

            // 1. Signature line + CR LF + SUB(0x1A) terminator.
            bytes.append(contentsOf: Array("AutoCAD-86 shapes 1.0".utf8))
            bytes.append(0x0D); bytes.append(0x0A)
            bytes.append(0x1A)

            // 2. Index table.
            // startShape (u16, LE) — informational; use 0.
            appendU16(&bytes, 0)
            // shapes in this font, in directory order:
            let shapes: [(no: Int, body: [UInt8], name: String)] = [
                (0,    shape0Body, "TESTFONT"),
                (0x20, spaceBody,  ""),
                (0x4C, lBody,      ""),   // 'L'
                (0x4F, oBody,      ""),   // 'O'
            ]
            appendU16(&bytes, shapes.count)   // count (u16, LE)
            // directory: count × (shapeNo:u16, blockLength:u16).
            for s in shapes {
                let blockLen = s.name.utf8.count + 1 /*NUL*/ + s.body.count
                appendU16(&bytes, s.no)
                appendU16(&bytes, blockLen)
            }
            // 3. data blocks (name NUL-terminated + body), in the same order.
            for s in shapes {
                bytes.append(contentsOf: Array(s.name.utf8))
                bytes.append(0x00)
                bytes.append(contentsOf: s.body)
            }
            return bytes
        }

        static func appendU16(_ bytes: inout [UInt8], _ v: Int) {
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
        }
    }

    // MARK: - Header + metrics

    @Test("parses the minimal buffer: flavor, metrics, glyph set")
    func parsesMinimal() throws {
        let font = try SHXParser.parse(bytes: MinimalSHX.buffer())
        #expect(font.kind == .shapes)
        // Header shape #0 carried above=20, below=7, name "TESTFONT".
        #expect(font.aboveBaseline == 20)
        #expect(font.belowBaseline == 7)
        #expect(font.fontName == "TESTFONT")
        // Three glyph shapes (#0 is the header, not a glyph): space, 'L', 'O'.
        #expect(font.glyph(for: Character("L")) != nil)
        #expect(font.glyph(for: Character("O")) != nil)
        #expect(font.glyph(for: UnicodeScalar(0x20)!) != nil)
    }

    // MARK: - Line-move glyph: 'L'

    @Test("'L' decodes to the down+right stroke with the right advance")
    func glyphLineMoves() throws {
        let font = try SHXParser.parse(bytes: MinimalSHX.buffer())
        let l = try #require(font.glyph(for: Character("L")))

        // One open stroke: (0,0) -> (0,-14) -> (8,-14).
        #expect(l.strokes.count == 1)
        let pts = try #require(l.strokes.first)
        #expect(pts.count == 3)
        #expect(approx(pts[0], 0, 0))
        #expect(approx(pts[1], 0, -14))
        #expect(approx(pts[2], 8, -14))

        // advance == rightmost pen reach (8).
        #expect(abs(l.advance - 8) < 1e-6)
        #expect(!l.isEmpty)
    }

    // MARK: - Octant-arc glyph: 'O'

    @Test("'O' decodes to a tessellated octant arc (a closed-ish ring)")
    func glyphOctantArc() throws {
        let font = try SHXParser.parse(bytes: MinimalSHX.buffer())
        let o = try #require(font.glyph(for: Character("O")))
        #expect(!o.isEmpty)

        // A full 8-octant arc of radius 8 around a center 8 to the RIGHT of the pen
        // (start octant 4 = west, so center = pen - dir(π)*8 = (8,0)). The arc begins
        // at the current pen position. Tessellation produces many points; they should
        // all lie ~radius 8 from that center.
        let pts = o.strokes.flatMap { $0 }
        #expect(pts.count > 8)   // tessellated, not a single segment
        let center = Vector(8, 0)
        for p in pts {
            let r = (p - center).magnitude
            #expect(abs(r - 8) < 0.5, "arc point off the radius-8 circle: r=\(r)")
        }
        // The circle spans x∈[0,16]; advance reaches the rightmost ink (~16) plus the
        // pen-up gap (+2) ⇒ ~18.
        #expect(o.advance > 15)
    }

    // MARK: - Robustness: truncated / malformed buffers THROW (never crash)

    @Test("a truncated buffer throws (no crash)")
    func truncatedThrows() {
        let full = MinimalSHX.buffer()
        // Cut the buffer in the middle of the index directory.
        let cut = Array(full.prefix(full.count / 2))
        #expect(throws: (any Error).self) {
            _ = try SHXParser.parse(bytes: cut)
        }
    }

    @Test("a buffer with no recognizable signature throws .badSignature")
    func badSignatureThrows() {
        let junk: [UInt8] = Array("not a shape font at all".utf8) + [0x1A, 0, 0, 0, 0]
        #expect(throws: SHXFontError.badSignature) {
            _ = try SHXParser.parse(bytes: junk)
        }
    }

    @Test("a buffer with a wild index count throws .malformedIndex")
    func malformedIndexThrows() {
        var bytes: [UInt8] = Array("AutoCAD-86 shapes 1.0".utf8)
        bytes.append(0x0D); bytes.append(0x0A); bytes.append(0x1A)
        MinimalSHX.appendU16(&bytes, 0)        // startShape
        MinimalSHX.appendU16(&bytes, 0)        // count = 0 (invalid)
        #expect(throws: SHXFontError.malformedIndex) {
            _ = try SHXParser.parse(bytes: bytes)
        }
    }

    @Test("an empty buffer throws (no crash)")
    func emptyThrows() {
        #expect(throws: (any Error).self) {
            _ = try SHXParser.parse(bytes: [])
        }
    }

    // MARK: - Provider + ShapedFont

    @Test("SHXShapedFont shapes a run and advances per glyph")
    func shapedFontAdvances() throws {
        let font = try SHXParser.parse(bytes: MinimalSHX.buffer())
        let shaped = SHXShapedFont(font: font)

        // metrics map cap band onto aboveBaseline.
        #expect(shaped.metrics.capHeight == 20)
        #expect(shaped.metrics.ascent == 20)
        #expect(shaped.metrics.descent == 7)

        // "LO L" = 'L'(0), 'O'(1), space(2), 'L'(3).
        let glyphs = shaped.shape("LO L", attributes: .default)
        #expect(glyphs.count == 4)
        #expect(abs(glyphs[0].advance.x - 8) < 1e-6)         // L advances 8
        #expect(glyphs[1].advance.x > 15)                    // O advances by its arc reach
        #expect(abs(glyphs[2].advance.x - 10) < 1e-6)        // space: header word width 10
        #expect(abs(glyphs[3].advance.x - 8) < 1e-6)         // L again

        // glyphGeometry yields the same strokes as the raw glyph.
        let geo = shaped.glyphGeometry(GlyphID(UInt32(Character("L").unicodeScalars.first!.value)),
                                       tolerance: 0.01)
        #expect(geo.strokes.count == 1)
        #expect(geo.fillGroups.isEmpty)   // SHX is strokes, never fills
    }

    @Test("SHXFontProvider resolves only .shx sources; register() works")
    func providerResolution() throws {
        let font = try SHXParser.parse(bytes: MinimalSHX.buffer())
        let provider = SHXFontProvider()
        provider.register(font, name: "testfont")

        // A .shx source resolves; native/stroke do not.
        #expect(provider.resolveFont(.shx(file: "testfont")) != nil)
        #expect(provider.resolveFont(.shx(file: "testfont.shx")) != nil)   // ext normalized
        #expect(provider.resolveFont(.native(family: "Helvetica")) == nil)
        #expect(provider.resolveFont(.stroke(lff: "standard")) == nil)
        // An unregistered name misses (cached miss, no crash).
        #expect(provider.resolveFont(.shx(file: "nope")) == nil)
    }

    // MARK: - Substitution chain ordering

    /// A fake provider that resolves only the sources in `available` and records
    /// every source it is asked for (in order), so we can assert the chain order.
    final class RecordingProvider: FontProvider, @unchecked Sendable {
        let available: Set<FontSourceKey>
        private let lock = NSLock()
        private var _asked: [FontSource] = []
        var asked: [FontSource] { lock.lock(); defer { lock.unlock() }; return _asked }

        init(available: Set<FontSourceKey>) { self.available = available }

        func resolveFont(_ source: FontSource) -> ShapedFont? {
            lock.lock(); _asked.append(source); lock.unlock()
            guard available.contains(FontSourceKey(source)) else { return nil }
            return StubShapedFont()
        }
    }

    /// A hashable key for a `FontSource` (the enum is Hashable already, but we want
    /// a name-insensitive bucket for native default lookups).
    struct FontSourceKey: Hashable {
        let kind: Int
        let name: String
        init(_ s: FontSource) {
            switch s {
            case .native(let f): kind = 0; name = f.lowercased()
            case .stroke(let l): kind = 1; name = l.lowercased()
            case .shx(let f):    kind = 2; name = f.lowercased()
            }
        }
    }

    struct StubShapedFont: ShapedFont {
        var metrics: FontMetrics {
            FontMetrics(ascent: 9, descent: 3, capHeight: 9, lineGap: 0, unitsPerEm: 9)
        }
        func shape(_ text: String, attributes: RunAttributes) -> [PositionedGlyph] { [] }
        func glyphGeometry(_ glyph: GlyphID, tolerance: Double) -> GlyphGeometry { GlyphGeometry() }
    }

    @Test("chain step 1: the exact requested .shx resolves first")
    func chainExactMatch() {
        let style = TextStyle(name: "S", primaryFont: .shx(file: "myfont"))
        let provider = RecordingProvider(available: [FontSourceKey(.shx(file: "myfont"))])
        let result = TextShaper.resolveShaper(style: style, ctx: .init(), provider: provider)
        #expect(result != nil)
        #expect(result?.1 == false)              // .shx is a stroke (non-native) source
        // The very first thing asked is the exact requested source.
        #expect(provider.asked.first == .shx(file: "myfont"))
        #expect(provider.asked.count == 1)       // resolved on the first try
    }

    @Test("chain step 2: a missing classic .shx falls back to the mapped native alias")
    func chainMappedAlias() {
        // "txt" is a classic AutoCAD font with a known native alias.
        let style = TextStyle(name: "S", primaryFont: .shx(file: "txt"))
        let aliasKey = FontSourceKey(.native(family: TextStyle.defaultNativeFamily))
        let provider = RecordingProvider(available: [aliasKey])
        let result = TextShaper.resolveShaper(style: style, ctx: .init(), provider: provider)
        #expect(result != nil)
        #expect(result?.1 == true)               // the alias is native
        // Order: exact (.shx txt) asked first and MISSED, then the alias asked.
        #expect(provider.asked.first == .shx(file: "txt"))
        #expect(provider.asked.contains(.native(family: TextStyle.defaultNativeFamily)))
        // The alias must be tried BEFORE the generic default-native step would also
        // be the same family — for "txt" the alias IS the default family, so the
        // second ask is that family.
        #expect(provider.asked.count >= 2)
    }

    @Test("chain step 4: an unknown .shx, with no native available, falls to .lff standard")
    func chainStrokeFallback() {
        // An unknown name's alias is .stroke("standard"); also make native miss so
        // the chain must reach the stroke font.
        let style = TextStyle(name: "S", primaryFont: .shx(file: "weirdunknownfont"))
        let provider = RecordingProvider(available: [FontSourceKey(.stroke(lff: "standard"))])
        let result = TextShaper.resolveShaper(style: style, ctx: .init(), provider: provider)
        #expect(result != nil)
        #expect(result?.1 == false)              // stroke source
        // Order check: exact .shx first (missed), then the alias .stroke("standard")
        // (which IS available, so it resolves at step 2 here).
        #expect(provider.asked.first == .shx(file: "weirdunknownfont"))
        #expect(provider.asked.contains(.stroke(lff: "standard")))
    }

    @Test("chain: a fully empty provider returns nil (never crashes)")
    func chainExhausted() {
        let style = TextStyle(name: "S", primaryFont: .shx(file: "anything"))
        let provider = RecordingProvider(available: [])
        let result = TextShaper.resolveShaper(style: style, ctx: .init(), provider: provider)
        #expect(result == nil)                   // graceful: nothing resolved, no crash
        // It tried, in order: exact, alias, default native, .lff standard, .lff "".
        #expect(provider.asked.first == .shx(file: "anything"))
        #expect(provider.asked.contains(.native(family: TextStyle.defaultNativeFamily)))
        #expect(provider.asked.contains(.stroke(lff: "standard")))
    }

    // MARK: - CompositeFontProvider integration

    @Test("CompositeFontProvider routes .shx to the SHX registry")
    func compositeRoutesSHX() throws {
        let font = try SHXParser.parse(bytes: MinimalSHX.buffer())
        let shx = SHXFontProvider()
        shx.register(font, name: "testfont")
        let composite = CompositeFontProvider(
            native: CoreTextFontProvider(),
            stroke: StrokeFontProvider(),
            shx: shx)
        #expect(composite.resolveFont(.shx(file: "testfont")) != nil)
        // Without an SHX registry, .shx returns nil (substitution chain handles it).
        let noShx = CompositeFontProvider(native: CoreTextFontProvider(),
                                          stroke: StrokeFontProvider())
        #expect(noShx.resolveFont(.shx(file: "testfont")) == nil)
    }

    // MARK: - Helpers

    private func approx(_ p: Vector, _ x: Double, _ y: Double, _ eps: Double = 1e-6) -> Bool {
        abs(p.x - x) < eps && abs(p.y - y) < eps
    }
}
