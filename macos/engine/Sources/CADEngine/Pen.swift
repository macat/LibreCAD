//
//  Pen.swift
//  CADEngine
//
//  Per-entity drawing attributes (color / line type / line width) with the
//  ByLayer / ByBlock sentinels CAD requires. Mirrors LibreCAD's RS_Pen
//  (librecad/src/lib/engine/rs_pen.h) and RS2:: line-type/width enums.
//  Resolution against the layer/block happens at resolve()-time (ADR-001).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Pen / RS2 enums).
//

import Foundation

/// An RGBA color, f32 components in [0, 1]. Distinct from `Pen.lineColor`'s
/// sentinels — this is a resolved, concrete color.
public struct RGBAColor: Sendable, Hashable, Codable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = RGBAColor(0, 0, 0)
    public static let white = RGBAColor(1, 1, 1)
    /// LibreCAD's signature green default pen color.
    public static let librecadGreen = RGBAColor(0.31, 0.80, 0.31)
}

/// An entity's color, including the CAD `.byLayer` / `.byBlock` sentinels.
public enum PenColor: Sendable, Hashable, Codable {
    /// Inherit the layer's color (resolve()-time).
    case byLayer
    /// Inherit the containing block's color (resolve()-time).
    case byBlock
    /// An explicit color.
    case explicit(RGBAColor)
}

/// Line dash pattern. The named cases mirror `RS2::LineType`; the actual dash
/// geometry is applied by the renderer. `.byLayer`/`.byBlock` defer to context.
public enum PenLineType: Sendable, Hashable, Codable {
    case byLayer
    case byBlock
    case solid
    case dashed
    case dotted
    case dashDot
    case center
    case border
    case divide
}

/// Line width. Mirrors `RS2::LineWidth`; explicit widths are in millimeters
/// (DXF lineweight units), matching LibreCAD. `.byLayer`/`.byBlock`/`.default`
/// defer to context.
public enum PenLineWidth: Sendable, Hashable, Codable {
    case byLayer
    case byBlock
    /// The drawing/default lineweight.
    case `default`
    /// An explicit width in millimeters.
    case millimeters(Double)
}

/// An entity's drawing TRANSPARENCY (AutoCAD entity transparency, DXF code 440),
/// including the CAD `.byLayer` / `.byBlock` sentinels — exactly the same
/// inherit-or-explicit shape as `PenColor` / `PenLineWidth`. Resolution against
/// the layer/block happens at `resolve()`-time and lands in the resolved color's
/// ALPHA channel (`ResolvedPen.color.a`), so the renderer needs no new field.
///
/// ## Alpha convention (1 = opaque, 0 = fully transparent)
/// `.opacity(a)` carries a normalized OPACITY in `[0, 1]` where `1` is fully
/// opaque and `0` is fully see-through — the same sense as `RGBAColor.a` (and the
/// inverse of AutoCAD's "transparency %" UI knob, which is `1 - opacity`). The
/// DXF code-440 byte is `round(opacity * 255)` (255 == opaque); the conversion
/// lives in the DXF reader/writer, not here.
///
/// Default is `.byLayer` — back-compatible, because a layer carries no
/// transparency field this wave, so `.byLayer` resolves to fully OPAQUE (the
/// historical behavior). See `Pen.resolved(layer:in:)`.
public enum PenTransparency: Sendable, Hashable, Codable {
    /// Inherit the layer's transparency (resolve()-time → opaque this wave).
    case byLayer
    /// Inherit the containing block's transparency (resolve()-time).
    case byBlock
    /// An explicit OPACITY in `[0, 1]` (1 == opaque, 0 == fully transparent).
    case opacity(Double)

    /// A fully-opaque explicit transparency.
    public static let opaque = PenTransparency.opacity(1)

    /// The explicit opacity carried, clamped to `[0, 1]`, or `nil` for a
    /// `.byLayer`/`.byBlock` sentinel (which the resolve step fills in).
    public var explicitOpacity: Double? {
        if case .opacity(let a) = self { return Swift.max(0, Swift.min(1, a)) }
        return nil
    }
}

/// The full per-entity drawing pen: color + line type + line width, each able to
/// defer to the layer or block (ADR-001).
public struct Pen: Sendable, Hashable, Codable {
    public var lineColor: PenColor
    public var lineType: PenLineType
    public var lineWidth: PenLineWidth
    /// Per-entity transparency (DXF code 440). `.byLayer` (the default) keeps the
    /// historical fully-opaque behavior. Decoded with a custom `init(from:)` so
    /// pre-transparency documents (no `transparency` key) load as `.byLayer`.
    public var transparency: PenTransparency

    public init(
        lineColor: PenColor = .byLayer,
        lineType: PenLineType = .byLayer,
        lineWidth: PenLineWidth = .byLayer,
        transparency: PenTransparency = .byLayer
    ) {
        self.lineColor = lineColor
        self.lineType = lineType
        self.lineWidth = lineWidth
        self.transparency = transparency
    }

    /// A pen that inherits everything from its layer — the common default.
    public static let byLayer = Pen()

    // Custom Codable so a document saved BEFORE per-entity transparency existed
    // (its `Pen` JSON/plist carries no `transparency` key) decodes as `.byLayer`
    // — back-compatible, no migration needed. The other three fields decode as
    // before. The synthesized encoder shape is preserved (one key per field).
    private enum CodingKeys: String, CodingKey {
        case lineColor, lineType, lineWidth, transparency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineColor = try c.decode(PenColor.self, forKey: .lineColor)
        lineType = try c.decode(PenLineType.self, forKey: .lineType)
        lineWidth = try c.decode(PenLineWidth.self, forKey: .lineWidth)
        transparency = try c.decodeIfPresent(PenTransparency.self, forKey: .transparency) ?? .byLayer
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lineColor, forKey: .lineColor)
        try c.encode(lineType, forKey: .lineType)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(transparency, forKey: .transparency)
    }
}

/// A pen with all `.byLayer`/`.byBlock` sentinels resolved to concrete values.
/// Produced at `resolve()`-time and carried on `ResolvedPolyline`/`ResolvedFill`.
///
/// ## Transparency (DXF 440) folds into `color.a`
/// The resolved per-entity opacity (`opacity`, `1` == opaque) is ALSO multiplied
/// into `color.a` at resolve-time, so the renderer (both the Metal `LineInstance`
/// color and the CG stroke color) gets the right alpha with NO new field — it
/// already consumes `pen.color`'s RGBA. `opacity` is kept as a separate resolved
/// value for inspection/testing and so callers can read the entity's effective
/// transparency without un-multiplying the color. For a fully-opaque pen (the
/// historical default) `opacity == 1` and `color.a` is unchanged.
public struct ResolvedPen: Sendable, Hashable, Codable {
    public var color: RGBAColor
    public var lineType: PenLineType
    public var lineWidth: PenLineWidth
    /// The resolved entity opacity in `[0, 1]` (1 == opaque). Already multiplied
    /// into `color.a`; carried separately for inspection. Defaults to `1`.
    public var opacity: Double

    public init(color: RGBAColor, lineType: PenLineType, lineWidth: PenLineWidth,
                opacity: Double = 1) {
        let clamped = Swift.max(0, Swift.min(1, opacity))
        // Fold the opacity into the color's alpha so the renderer's existing
        // `pen.color` path renders the transparency with no new field.
        var c = color
        c.a *= Float(clamped)
        self.color = c
        self.lineType = lineType
        self.lineWidth = lineWidth
        self.opacity = clamped
    }

    // Custom Codable so a `ResolvedPen` persisted before `opacity` existed decodes
    // as fully opaque. (ResolvedPen is rarely serialized directly — it lives on
    // computed geometry — but it conforms to `Codable`, so keep it forward-safe.)
    private enum CodingKeys: String, CodingKey {
        case color, lineType, lineWidth, opacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(RGBAColor.self, forKey: .color)
        lineType = try c.decode(PenLineType.self, forKey: .lineType)
        lineWidth = try c.decode(PenLineWidth.self, forKey: .lineWidth)
        // `color` already carries the folded alpha when this was encoded, so do NOT
        // re-multiply — read `opacity` straight through (default 1 for old data).
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(color, forKey: .color)
        try c.encode(lineType, forKey: .lineType)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(opacity, forKey: .opacity)
    }
}
