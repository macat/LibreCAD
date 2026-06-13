//
//  LFFFont.swift
//  CADEngine
//
//  LibreCAD Font Format (.lff) stroke-font loader (ADR-004). CAD text is drawn
//  as stroked polylines from LibreCAD's shipped `.lff` stroke fonts, NOT from
//  SDF/system glyphs. This file ports the `.lff` parser + glyph reference
//  resolution from LibreCAD's `RS_Font::readLFF` / `generateLffFont`
//  (librecad/src/lib/engine/document/fonts/rs_font.{h,cpp}).
//
//  The result of parsing is a value-semantic, fully-resolved `StrokeFont`:
//  every glyph's `C<hex>` references are expanded at parse time so the type is
//  immutable and `Sendable` (safe to plug into the `Sendable` `ResolveContext`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2010 R. van Twisk (librecad@rvt.dds.nl).
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Font / readLFF logic).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Glyph

/// A single resolved glyph (one code point) of a stroke font.
///
/// `strokes` is the set of polylines that draw the glyph, in **font em units**
/// (the raw `.lff` coordinate space; LibreCAD ISO-style fonts use a ~9-unit cap
/// height). Each stroke is an ordered run of points; bulge ("A") segments are
/// expanded into tessellated arc points at parse time (see
/// `LFFFont.expand(...)`), so consumers only ever see straight polylines.
///
/// Coordinates are NOT scaled or positioned — the Text-entity layout owner
/// scales by the text height and translates by the running pen position using
/// the font metrics (`StrokeFont.letterSpacing` etc.).
public struct LFFGlyph: Sendable, Equatable {
    /// Polylines that draw the glyph, in font em units.
    public var strokes: [[Vector]]

    public init(strokes: [[Vector]] = []) {
        self.strokes = strokes
    }

    /// `true` if the glyph has no drawable strokes (e.g. space). Spaces are
    /// represented by the *absence* of a glyph rather than an empty one, but a
    /// reference-only glyph that resolves to nothing lands here.
    public var isEmpty: Bool { strokes.isEmpty || strokes.allSatisfy { $0.count < 2 } }

    /// Axis-aligned em-space extent of the glyph's points, or `nil` if empty.
    /// Useful for the Text owner's auto-fit / advance-width heuristics.
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

// MARK: - Stroke font

/// A parsed LibreCAD stroke font: a table of resolved glyphs plus the metadata
/// the text layout step needs (spacing, encoding, names, authors, license).
///
/// **Value semantics / `Sendable`.** This is a `final class` purely to be a
/// cheap shared reference (a font holds hundreds of glyphs); it is **immutable
/// after `init`** and all stored properties are `Sendable`, so the whole type
/// is safely `Sendable`. It can therefore back the reserved
/// `ResolveContext.fontProvider` hook without breaking `ResolveContext`'s
/// `Sendable` conformance.
public final class StrokeFont: Sendable {
    /// Resolved glyphs keyed by Unicode scalar (`C<hex>` references already
    /// expanded in place).
    public let glyphs: [UnicodeScalar: LFFGlyph]

    // --- Metadata (ported from RS_Font; defaults match RS_Font's constructor) ---

    /// Extra advance (em units) inserted between adjacent glyphs. `.lff`
    /// `# LetterSpacing`; LibreCAD default `3.0`.
    public let letterSpacing: Double
    /// Advance (em units) for a space character. `.lff` `# WordSpacing`;
    /// LibreCAD default `6.75`.
    public let wordSpacing: Double
    /// Multiplier on the nominal line height for inter-line advance. `.lff`
    /// `# LineSpacingFactor`; LibreCAD default `1.0`.
    public let lineSpacingFactor: Double

    /// Text encoding declared by the font (`.lff` files are UTF-8).
    public let encoding: String
    /// Alternative display names (`# Name`).
    public let names: [String]
    /// Author(s) (`# Author`).
    public let authors: [String]
    /// License string (`# License`); `"unknown"` if absent.
    public let license: String
    /// Creation date string (`# Created`), if present.
    public let created: String?

    public init(
        glyphs: [UnicodeScalar: LFFGlyph],
        letterSpacing: Double = 3.0,
        wordSpacing: Double = 6.75,
        lineSpacingFactor: Double = 1.0,
        encoding: String = "UTF-8",
        names: [String] = [],
        authors: [String] = [],
        license: String = "unknown",
        created: String? = nil
    ) {
        self.glyphs = glyphs
        self.letterSpacing = letterSpacing
        self.wordSpacing = wordSpacing
        self.lineSpacingFactor = lineSpacingFactor
        self.encoding = encoding
        self.names = names
        self.authors = authors
        self.license = license
        self.created = created
    }

    /// Number of resolved glyphs in the font.
    public var glyphCount: Int { glyphs.count }

    /// The Unicode REPLACEMENT CHARACTER (U+FFFD) glyph LibreCAD synthesizes as
    /// a fallback for missing code points (a small diamond), if present.
    public var replacementGlyph: LFFGlyph? { glyphs[UnicodeScalar(0xFFFD)!] }

    // MARK: Glyph lookup

    /// The resolved glyph for a Unicode scalar, or `nil` if the font has none.
    /// References are already expanded, so this is a plain dictionary read.
    public func glyph(for scalar: UnicodeScalar) -> LFFGlyph? { glyphs[scalar] }

    /// The resolved glyph for a `Character`.
    ///
    /// A `Character` is a grapheme cluster and may comprise several scalars
    /// (e.g. base + combining mark). Stroke fonts are keyed by single scalars,
    /// so we look up the first scalar of the cluster — matching how LibreCAD's
    /// `findLetter` keys on a single `QChar`. Returns `nil` if absent; the
    /// caller may fall back to `replacementGlyph`.
    public func glyph(for character: Character) -> LFFGlyph? {
        guard let first = character.unicodeScalars.first else { return nil }
        return glyph(for: first)
    }
}
