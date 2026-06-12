//
//  StrokeFontProvider+Provider.swift
//  CADEngine
//
//  Conforms the existing `.lff` `StrokeFontProvider` to the unified `FontProvider`
//  protocol (ADR-004; text-system-design §2.3), so stroke fonts and native fonts
//  resolve through the SAME seam. Stroke glyphs are open polylines (the existing
//  `.lff` geometry); they become `GlyphGeometry.strokes` and the resolve arm
//  emits them as `ResolvedPolyline`s (unchanged behavior).
//
//  GlyphID for a stroke font is a synthetic value: the Unicode scalar of the
//  character (`.lff` is keyed by single scalars). The shaper carries the source
//  string so the resolve arm can advance per glyph using the font's letter/word
//  spacing (lifting `Resolve.layoutText`'s advance logic into the shaper).
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

// MARK: - StrokeFontProvider conforms to FontProvider

extension StrokeFontProvider: FontProvider {
    /// Resolves a `.stroke(lff:)` source to a `StrokeShapedFont`, or `nil` for a
    /// non-stroke source (so the resolve arm falls back to the native provider /
    /// substitution chain). An empty `.lff` name resolves to the provider's
    /// default font (the empty-key registration).
    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        guard case let .stroke(lff) = source else { return nil }
        guard let font = font(named: lff) else { return nil }
        return StrokeShapedFont(font: font)
    }
}

// MARK: - Single-font provider (a FontProvider over one fixed StrokeFont)

/// A minimal `FontProvider` that serves ONE fixed `StrokeFont` for ANY `.stroke`
/// request (and `nil` for native/`.shx`). Useful for wiring a hand-built or
/// in-memory stroke font into a `ResolveContext` without disk I/O — e.g. the
/// dimension-text tests build a synthetic digit font and resolve through this.
public struct SingleStrokeFontProvider: FontProvider {
    public let font: StrokeFont
    public init(_ font: StrokeFont) { self.font = font }
    public func resolveFont(_ source: FontSource) -> ShapedFont? {
        guard case .stroke = source else { return nil }
        return StrokeShapedFont(font: font)
    }
}

// MARK: - StrokeShapedFont (a ShapedFont over a parsed StrokeFont)

/// A `ShapedFont` over a parsed `.lff` `StrokeFont`. Immutable + `Sendable`
/// (`StrokeFont` is itself `Sendable`). There is no kerning table in `.lff`, so
/// the advance is the glyph's ink width plus the font's letter spacing; a space
/// (or a missing glyph) advances by the word spacing.
public final class StrokeShapedFont: ShapedFont, @unchecked Sendable {

    let font: StrokeFont

    /// `.lff` ISO fonts use a ~9-unit cap height (matches `Resolve.lffCapHeight`).
    /// Em-space coordinates are therefore normalized so DXF `height` maps to this.
    public static let lffCapHeight = 9.0

    public let metrics: FontMetrics

    public init(font: StrokeFont) {
        self.font = font
        // Stroke fonts carry no explicit ascent/descent; use the ISO-ish band the
        // existing text-bbox estimate uses (cap 9, descender ~3, accents ~13).
        self.metrics = FontMetrics(
            ascent: 9.0,
            descent: 3.0,
            capHeight: Self.lffCapHeight,
            lineGap: Self.lffCapHeight * (font.lineSpacingFactor - 1.0) + 0,
            unitsPerEm: Self.lffCapHeight
        )
    }

    /// Shapes a run into positioned glyphs. Each glyph's id is its Unicode scalar
    /// value; the advance is the glyph's ink width + the font's letter spacing. A
    /// space advances by word spacing (a glyph with id == 0x20 and no geometry).
    /// `attributes.tracking` adds extra per-glyph advance (em).
    public func shape(_ text: String, attributes: RunAttributes) -> [PositionedGlyph] {
        guard !text.isEmpty else { return [] }
        let spacing = font.letterSpacing + attributes.tracking
        var out: [PositionedGlyph] = []
        out.reserveCapacity(text.count)

        for ch in text {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            if ch == " " {
                out.append(PositionedGlyph(
                    glyph: GlyphID(0x20),
                    advance: Vector(font.wordSpacing, 0)))
                continue
            }
            let glyph = font.glyph(for: ch) ?? font.replacementGlyph
            guard let glyph, !glyph.isEmpty else {
                // No drawable glyph: advance a word space so following text doesn't
                // pile up (graceful — matches the prior layoutText behavior).
                out.append(PositionedGlyph(
                    glyph: GlyphID(scalar),
                    advance: Vector(font.wordSpacing, 0)))
                continue
            }
            // Advance by the glyph's right ink extent + letter spacing.
            let width = glyph.bounds().map(\.max.x) ?? 0
            out.append(PositionedGlyph(
                glyph: GlyphID(scalar),
                advance: Vector(width + spacing, 0)))
        }
        return out
    }

    /// The glyph's strokes (open polylines, em space). `tolerance` is ignored —
    /// `.lff` strokes are already flattened (bulges expanded at parse time). The
    /// id maps back to the Unicode scalar.
    public func glyphGeometry(_ glyph: GlyphID, tolerance: Double) -> GlyphGeometry {
        guard let scalar = Unicode.Scalar(glyph.rawValue) else { return GlyphGeometry() }
        guard let g = font.glyph(for: scalar) ?? font.replacementGlyph else {
            return GlyphGeometry()
        }
        return GlyphGeometry(strokes: g.strokes)
    }
}
