//
//  SHXFont.swift
//  CADEngine
//
//  AutoCAD compiled SHAPE-font (`.shx`) model + `FontProvider`/`ShapedFont`
//  conformance (ADR-004; text-system-design §"SHX, Phase 3"). AutoCAD drawings
//  whose text styles reference a compiled `.shx` shape font render their text in
//  the true stroke shapes of that font — NOT a substitute — when the `.shx` is
//  available. The binary decode lives in `SHXParser.swift`; this file is the
//  value-semantic, fully-resolved font (mirroring `StrokeFont` / `LFFFont`) plus
//  the provider that bridges SHX glyphs → `GlyphGeometry.strokes`, exactly like
//  the `.lff` `StrokeFontProvider`/`StrokeShapedFont` pair.
//
//  A glyph's geometry is a set of OPEN POLYLINES in font em units (the shape
//  pen-up/pen-down draw vectors, octant arcs expanded to points at parse time),
//  so consumers only ever see straight polylines — identical to the `.lff` path.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Glyph

/// A single resolved glyph of an SHX shape font, in **font em units** (the raw
/// shape coordinate space, normalized so the font's nominal cap band maps to
/// ~`SHXFont.aboveBaseline`). Each stroke is an ordered run of points; octant
/// ("arc") shape codes are expanded into tessellated arc points at parse time so
/// consumers only ever see straight polylines.
///
/// `advance` is the glyph's horizontal pen advance (the final pen x after the
/// shape's draw codes execute, including pen-up moves), used directly as the
/// shaping advance — SHX has no kerning table.
public struct SHXGlyph: Sendable, Equatable {
    /// Open polylines that draw the glyph, in font em units.
    public var strokes: [[Vector]]
    /// Horizontal advance width (font em units) after the glyph is drawn.
    public var advance: Double

    public init(strokes: [[Vector]] = [], advance: Double = 0) {
        self.strokes = strokes
        self.advance = advance
    }

    /// `true` if the glyph has no drawable strokes (e.g. space). A space carries
    /// only an advance.
    public var isEmpty: Bool { strokes.isEmpty || strokes.allSatisfy { $0.count < 2 } }

    /// Axis-aligned em-space extent of the glyph's points, or `nil` if empty.
    public func bounds() -> (min: Vector, max: Vector)? {
        var pts = strokes.flatMap { $0 }
        guard !pts.isEmpty else { return nil }
        let first = pts.removeFirst()
        var lo = first, hi = first
        for p in pts {
            lo = Vector(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y))
            hi = Vector(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y))
        }
        return (lo, hi)
    }
}

// MARK: - SHX font flavor

/// The three documented SHX flavors, distinguished by the file's signature line.
public enum SHXFontKind: Sendable, Equatable {
    /// Classic "AutoCAD-86 shapes 1.0" / "1.1" — 1-byte (255-max) shape numbers,
    /// 8-bit char codes. The common Latin text fonts (txt, romans, …).
    case shapes
    /// "AutoCAD-86 unifont 1.0" — 2-byte (Unicode) shape numbers; the modern
    /// extended-font format.
    case unifont
    /// "AutoCAD-86 bigfont 1.0" — Asian "big font" companion, 2-byte shape
    /// numbers with an escape/range table.
    case bigfont
}

// MARK: - SHX font

/// A parsed AutoCAD `.shx` shape font: a table of resolved glyphs keyed by
/// Unicode scalar plus the metrics the layout step needs.
///
/// **Value semantics / `Sendable`.** A `final class` purely to be a cheap shared
/// reference (a font holds many glyphs); it is **immutable after `init`** and all
/// stored properties are `Sendable`, so the whole type is safely `Sendable` and
/// can back the `Sendable` `ResolveContext.fontProvider`.
public final class SHXFont: Sendable {
    /// Resolved glyphs keyed by Unicode scalar.
    public let glyphs: [UnicodeScalar: SHXGlyph]

    /// Which SHX flavor this font was decoded from.
    public let kind: SHXFontKind

    /// The font's declared height above the baseline (the "letters extend up this
    /// many units" header value). Used as the cap-band normalizer so DXF `height`
    /// maps onto it (parallels `StrokeShapedFont.lffCapHeight`).
    public let aboveBaseline: Double
    /// The font's declared depth below the baseline (descender extent), magnitude.
    public let belowBaseline: Double

    /// The shape number of the special "font definition" shape (shape 0), whose
    /// name carries the font name; retained for inspection / round-trip.
    public let fontName: String

    public init(
        glyphs: [UnicodeScalar: SHXGlyph],
        kind: SHXFontKind,
        aboveBaseline: Double,
        belowBaseline: Double,
        fontName: String = ""
    ) {
        self.glyphs = glyphs
        self.kind = kind
        self.aboveBaseline = aboveBaseline
        self.belowBaseline = belowBaseline
        self.fontName = fontName
    }

    /// Number of resolved glyphs in the font.
    public var glyphCount: Int { glyphs.count }

    /// The resolved glyph for a Unicode scalar, or `nil`.
    public func glyph(for scalar: UnicodeScalar) -> SHXGlyph? { glyphs[scalar] }

    /// The resolved glyph for a `Character` (keyed on its first scalar — SHX
    /// fonts are keyed by single code points, like `.lff`).
    public func glyph(for character: Character) -> SHXGlyph? {
        guard let first = character.unicodeScalars.first else { return nil }
        return glyph(for: first)
    }
}

// MARK: - SHXFontProvider (loads + caches `.shx` fonts; FontProvider)

/// Loads `.shx` fonts from disk and caches the parsed `SHXFont`s by base name.
/// Thread-safe (an internal lock guards the cache), conforming to the unified
/// `FontProvider` so SHX glyphs resolve through the SAME seam as native and
/// `.lff`. Mirrors `StrokeFontProvider` field-for-field (search dirs, explicit
/// URL registrations, cached misses).
public final class SHXFontProvider: FontProvider, @unchecked Sendable {

    private var searchDirectories: [URL] = []
    private var registeredURLs: [String: URL] = [:]
    /// `nil` value caches a *miss* so a repeated absent lookup doesn't re-hit disk.
    private var cache: [String: SHXFont?] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: Registration

    /// Adds a directory to search for `<name>.shx` files.
    public func registerSearchDirectory(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        searchDirectories.append(url)
    }

    /// Registers a specific `.shx` file under a name (defaults to its base name).
    @discardableResult
    public func registerFont(at url: URL, name: String? = nil) -> String {
        let key = Self.normalize(name ?? url.deletingPathExtension().lastPathComponent)
        lock.lock(); defer { lock.unlock() }
        registeredURLs[key] = url
        cache.removeValue(forKey: key)
        return key
    }

    // MARK: Lookup

    /// Returns the parsed font for `name`, loading + caching on first access.
    /// `name` may be a base name, a file name ("simplex.shx"), or a path.
    public func font(named name: String) -> SHXFont? {
        if name.lowercased().hasSuffix(".shx"),
           FileManager.default.fileExists(atPath: name) {
            return loadAndCache(url: URL(fileURLWithPath: name),
                                key: Self.normalize(URL(fileURLWithPath: name)
                                    .deletingPathExtension().lastPathComponent))
        }

        let key = Self.normalize(name)

        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        let registered = registeredURLs[key]
        let dirs = searchDirectories
        lock.unlock()

        let url: URL?
        if let registered {
            url = registered
        } else {
            url = dirs.lazy
                .map { $0.appendingPathComponent("\(key).shx") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        guard let url else {
            lock.lock(); cache[key] = .some(nil); lock.unlock()
            return nil
        }
        return loadAndCache(url: url, key: key)
    }

    private func loadAndCache(url: URL, key: String) -> SHXFont? {
        let parsed = try? SHXParser.load(contentsOf: url)
        lock.lock(); cache[key] = .some(parsed); lock.unlock()
        return parsed
    }

    /// Registers an already-parsed font directly (useful for tests / in-memory).
    public func register(_ font: SHXFont, name: String) {
        let key = Self.normalize(name)
        lock.lock(); defer { lock.unlock() }
        cache[key] = .some(font)
    }

    /// Drops all cached fonts (keeps registrations / search dirs).
    public func clearCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    // MARK: FontProvider

    /// Resolves a `.shx(file:)` source to an `SHXShapedFont`, or `nil` for a
    /// non-`.shx` source / a missing font (the resolve arm then walks the
    /// substitution chain).
    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        guard case let .shx(file) = source else { return nil }
        guard let font = font(named: file) else { return nil }
        return SHXShapedFont(font: font)
    }

    // MARK: Helpers

    /// Normalizes a font name to a cache/search key: drop a `.shx` extension,
    /// keep the last path component, lowercase.
    static func normalize(_ name: String) -> String {
        var n = name
        if n.lowercased().hasSuffix(".shx") { n = String(n.dropLast(4)) }
        if let slash = n.lastIndex(of: "/") { n = String(n[n.index(after: slash)...]) }
        return n.lowercased()
    }
}

// MARK: - SHXShapedFont (a ShapedFont over a parsed SHXFont)

/// A `ShapedFont` over a parsed `.shx` font. Immutable + `Sendable`. SHX has no
/// kerning table, so the advance is the glyph's recorded pen advance; a space (or
/// missing glyph) advances by an inferred word width. Mirrors `StrokeShapedFont`.
public final class SHXShapedFont: ShapedFont, @unchecked Sendable {

    let font: SHXFont

    public let metrics: FontMetrics

    /// Inferred word-space advance (em) for the space character / missing glyphs:
    /// the cap band divided by ~3, matching the `.lff` word-spacing proportion.
    let wordAdvance: Double

    public init(font: SHXFont) {
        self.font = font
        let cap = font.aboveBaseline > 0 ? font.aboveBaseline : 1.0
        // Prefer the font's own space glyph advance if present.
        if let space = font.glyph(for: UnicodeScalar(0x20)), space.advance > 0 {
            self.wordAdvance = space.advance
        } else {
            self.wordAdvance = cap * 0.75
        }
        self.metrics = FontMetrics(
            ascent: font.aboveBaseline,
            descent: font.belowBaseline,
            capHeight: cap,
            lineGap: cap * 0.25,
            unitsPerEm: cap)
    }

    /// Shapes a run into positioned glyphs. Each glyph's id is its Unicode scalar;
    /// the advance is the glyph's recorded pen advance. A space (or a missing /
    /// empty glyph) advances by the inferred word width. `attributes.tracking`
    /// adds extra per-glyph advance (em).
    public func shape(_ text: String, attributes: RunAttributes) -> [PositionedGlyph] {
        guard !text.isEmpty else { return [] }
        var out: [PositionedGlyph] = []
        out.reserveCapacity(text.count)

        for ch in text {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            if ch == " " {
                out.append(PositionedGlyph(
                    glyph: GlyphID(0x20),
                    advance: Vector(wordAdvance + attributes.tracking, 0)))
                continue
            }
            guard let glyph = font.glyph(for: ch), glyph.advance > 0 || !glyph.isEmpty else {
                out.append(PositionedGlyph(
                    glyph: GlyphID(scalar),
                    advance: Vector(wordAdvance + attributes.tracking, 0)))
                continue
            }
            let adv = glyph.advance > 0 ? glyph.advance
                : (glyph.bounds().map(\.max.x) ?? wordAdvance)
            out.append(PositionedGlyph(
                glyph: GlyphID(scalar),
                advance: Vector(adv + attributes.tracking, 0)))
        }
        return out
    }

    /// The glyph's strokes (open polylines, em space). `tolerance` is ignored —
    /// SHX arcs are already flattened at parse time. The id maps to the scalar.
    public func glyphGeometry(_ glyph: GlyphID, tolerance: Double) -> GlyphGeometry {
        guard let scalar = Unicode.Scalar(glyph.rawValue),
              let g = font.glyph(for: scalar) else {
            return GlyphGeometry()
        }
        return GlyphGeometry(strokes: g.strokes)
    }
}

// MARK: - Single-font provider (a FontProvider over one fixed SHXFont)

/// A minimal `FontProvider` that serves ONE fixed `SHXFont` for ANY `.shx`
/// request (and `nil` for native/`.stroke`). Useful for wiring a hand-built or
/// in-memory SHX font into a `ResolveContext` without disk I/O (tests).
public struct SingleSHXFontProvider: FontProvider {
    public let font: SHXFont
    public init(_ font: SHXFont) { self.font = font }
    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        guard case .shx = source else { return nil }
        return SHXShapedFont(font: font)
    }
}
