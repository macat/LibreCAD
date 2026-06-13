//
//  FontProvider.swift
//  CADEngine
//
//  The single glyph/shaping abstraction (ADR-004 REVISION, text-system-design §2).
//  CAD text resolves through ONE `FontProvider`/`ShapedFont` protocol with two
//  implementations behind it:
//    - `CoreTextFontProvider`  — native outline fonts (the DEFAULT), glyph paths
//                                tessellated to FILLS.
//    - `StrokeFontProvider`    — LibreCAD `.lff` stroke fonts → open polyline
//                                strokes (retained for DXF fidelity).
//
//  The protocol is `Sendable` so a provider can live inside the `Sendable`
//  `ResolveContext`. Implementations are immutable + cache internally behind a
//  lock (the established `StrokeFontProvider` pattern).
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

// MARK: - The provider protocol (ADR-004: ONE abstraction, two impls)

/// The single glyph/shaping abstraction. Two impls: stroke (`.lff`, future SHX)
/// and native (Core Text). `Sendable` so it can back the `Sendable`
/// `ResolveContext.fontProvider` hook.
public protocol FontProvider: Sendable {
    /// Resolve a `TextStyle`'s font source to a concrete shaper, or `nil` if the
    /// source is unavailable (the caller then walks the substitution chain, §4.3).
    /// `source` carries native-family vs `.lff` vs `.shx`.
    func resolveFont(_ source: FontSource) -> ShapedFont?

    /// Resolve a font source PLUS the style's bold/italic traits to a concrete face.
    /// Native providers select a heavier/oblique face (symbolic traits); stroke/SHX
    /// providers ignore the traits (the format has no faces). Has a default impl that
    /// falls back to `resolveFont(_:)` so existing conformers keep working.
    func resolveFont(_ source: FontSource, bold: Bool, italic: Bool) -> ShapedFont?
}

public extension FontProvider {
    /// Default: traits-agnostic resolution (stroke/SHX have no faces).
    func resolveFont(_ source: FontSource, bold: Bool, italic: Bool) -> ShapedFont? {
        resolveFont(source)
    }
}

/// A resolved, ready-to-shape font (one family/face at unit em). Immutable +
/// internally cached.
public protocol ShapedFont: Sendable {
    /// Font metrics in em units (scaled by the entity height at layout time).
    /// Drives baseline / ascent / descent placement and tight bounding boxes.
    var metrics: FontMetrics { get }

    /// Shape ONE run of text into positioned glyphs (kerning, ligatures, Unicode,
    /// complex/RTL applied here). `attributes` carries bold/italic/oblique/
    /// width-factor/tracking for the run. Pure — no GPU, fully unit-testable
    /// (Core Text shaping runs headless).
    func shape(_ text: String, attributes: RunAttributes) -> [PositionedGlyph]

    /// The drawable geometry of ONE glyph at unit em, in em space, flattened to
    /// `tolerance`. Native ⇒ filled loops (outline). Stroke ⇒ open polylines.
    /// Cached by (font, glyphID, toleranceBucket) inside the impl.
    func glyphGeometry(_ glyph: GlyphID, tolerance: Double) -> GlyphGeometry
}

// MARK: - Shaping value types

/// A glyph placed along the baseline by the shaper (em units, pre-scale).
public struct PositionedGlyph: Sendable, Hashable {
    public var glyph: GlyphID
    /// Pen advance after this glyph (kerned). `.x` is the horizontal advance.
    public var advance: Vector
    /// Baseline offset (e.g. for marks / vertical shaping). Usually zero.
    public var offset: Vector

    public init(glyph: GlyphID, advance: Vector, offset: Vector = Vector(0, 0)) {
        self.glyph = glyph
        self.advance = advance
        self.offset = offset
    }
}

/// Per-run shaping attributes (assembled from `TextStyle` + entity/run overrides).
public struct RunAttributes: Sendable, Hashable {
    public var bold: Bool
    public var italic: Bool
    /// Radians; applied as a shear AFTER shaping (the resolve arm applies it, so
    /// the shaper itself does not have to — kept here so the seam is uniform).
    public var obliqueAngle: Double
    /// Horizontal scale; applied AFTER shaping by the resolve arm.
    public var widthFactor: Double
    /// Extra advance per glyph (em).
    public var tracking: Double

    public init(
        bold: Bool = false,
        italic: Bool = false,
        obliqueAngle: Double = 0,
        widthFactor: Double = 1,
        tracking: Double = 0
    ) {
        self.bold = bold
        self.italic = italic
        self.obliqueAngle = obliqueAngle
        self.widthFactor = widthFactor
        self.tracking = tracking
    }

    public static let `default` = RunAttributes()
}

/// Glyph drawable geometry at unit em. A glyph is EITHER fills (native outline)
/// OR strokes (`.lff`/SHX), never both — but the type carries both so the cache +
/// resolve seam is uniform.
public struct GlyphGeometry: Sendable, Hashable {
    /// Containment-GROUPED fill sub-shapes (em space) — native fonts. Each group is
    /// ONE outer contour (CCW) followed by the holes it directly contains (CW), i.e.
    /// the `ResolvedFill` loop contract per group. A glyph with multiple DISJOINT
    /// outer blobs (the dot of `i`/`j`, the dots of `:`/`;`, the bars of `=`, the
    /// slash of `Ø`/`⌀`, accented glyphs) yields ONE group per blob so each blob is
    /// POSITIVE ink — NOT subtracted from the main body. The resolve arm emits one
    /// `ResolvedFill` per group. (text-system-design §2.2 winding contract.)
    public var fillGroups: [[[Vector]]]
    /// Open polylines, em space — stroke fonts.
    public var strokes: [[Vector]]

    /// Backward-compatible FLAT view of all fill contours: every group's loops
    /// concatenated (outer-then-holes per group). For a single-group glyph this is
    /// `[outer, hole1, ...]` exactly as before. Callers that need per-shape hole
    /// subtraction MUST use `fillGroups`; this flat view is for bounds/inspection.
    public var fills: [[Vector]] { fillGroups.flatMap { $0 } }

    /// Constructs from already-grouped sub-fills (the native path).
    public init(fillGroups: [[[Vector]]] = [], strokes: [[Vector]] = []) {
        self.fillGroups = fillGroups
        self.strokes = strokes
    }

    /// Convenience for callers/tests that supply a single group's flat loop list
    /// (`[outer, holes...]`) or just strokes. A non-empty `fills` becomes ONE group.
    public init(fills: [[Vector]], strokes: [[Vector]] = []) {
        self.fillGroups = fills.isEmpty ? [] : [fills]
        self.strokes = strokes
    }

    public var isEmpty: Bool { fillGroups.isEmpty && strokes.isEmpty }

    /// Axis-aligned em-space extent of all points, or `nil` if empty. Used for the
    /// font-aware tight bounding box.
    public func bounds() -> (min: Vector, max: Vector)? {
        var lo: Vector?
        var hi: Vector?
        for loop in fills + strokes {
            for p in loop {
                if let l = lo, let h = hi {
                    lo = Vector(Swift.min(l.x, p.x), Swift.min(l.y, p.y))
                    hi = Vector(Swift.max(h.x, p.x), Swift.max(h.y, p.y))
                } else {
                    lo = p; hi = p
                }
            }
        }
        guard let lo, let hi else { return nil }
        return (lo, hi)
    }
}

/// Font metrics, all in em units (multiply by `height / capHeight` at layout).
public struct FontMetrics: Sendable, Hashable {
    /// Cap/ascender top above the baseline.
    public var ascent: Double
    /// Below the baseline (positive magnitude).
    public var descent: Double
    /// DXF `height` maps to this (the scale denominator).
    public var capHeight: Double
    /// Inter-line leading.
    public var lineGap: Double
    /// Native: the CTFont em; stroke: `lffCapHeight`-based normalization.
    public var unitsPerEm: Double

    public init(
        ascent: Double,
        descent: Double,
        capHeight: Double,
        lineGap: Double,
        unitsPerEm: Double
    ) {
        self.ascent = ascent
        self.descent = descent
        self.capHeight = capHeight
        self.lineGap = lineGap
        self.unitsPerEm = unitsPerEm
    }
}

/// A glyph identifier within a resolved font. For Core Text this is the CGGlyph;
/// for stroke fonts the resolve arm uses a synthetic id mapping to a Unicode
/// scalar (the stroke shaper carries the geometry per id).
public struct GlyphID: Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

// MARK: - LOD tolerance bucketing (scale-independent glyph cache key)

/// Quantizes a flattening tolerance into a coarse "bucket" so the glyph-geometry
/// cache reuses a flattened outline across nearby zoom levels (text-system-design
/// §2.5). Outlines are scale-independent (unit em), so we flatten once per bucket
/// and reuse for every instance/size/zoom.
public enum GlyphToleranceBucket {
    /// Maps an arbitrary positive tolerance to a stable bucketed value. Buckets
    /// are powers-of-two of a base tolerance, clamped to a sane range so a degenerate
    /// (zero/negative) tolerance never produces an unbounded point count.
    public static func bucket(_ tolerance: Double) -> Double {
        let t = tolerance.isFinite && tolerance > 0 ? tolerance : 0.01
        // Quantize on a log2 grid: bucket index = round(log2(t / base)).
        let base = 0.005
        let clamped = Swift.min(Swift.max(t, base / 16), base * 256)
        let idx = (log2(clamped / base)).rounded()
        return base * pow(2.0, idx)
    }
}
