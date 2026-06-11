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

/// The full per-entity drawing pen: color + line type + line width, each able to
/// defer to the layer or block (ADR-001).
public struct Pen: Sendable, Hashable, Codable {
    public var lineColor: PenColor
    public var lineType: PenLineType
    public var lineWidth: PenLineWidth

    public init(
        lineColor: PenColor = .byLayer,
        lineType: PenLineType = .byLayer,
        lineWidth: PenLineWidth = .byLayer
    ) {
        self.lineColor = lineColor
        self.lineType = lineType
        self.lineWidth = lineWidth
    }

    /// A pen that inherits everything from its layer — the common default.
    public static let byLayer = Pen()
}

/// A pen with all `.byLayer`/`.byBlock` sentinels resolved to concrete values.
/// Produced at `resolve()`-time and carried on `ResolvedPolyline`/`ResolvedFill`.
public struct ResolvedPen: Sendable, Hashable, Codable {
    public var color: RGBAColor
    public var lineType: PenLineType
    public var lineWidth: PenLineWidth

    public init(color: RGBAColor, lineType: PenLineType, lineWidth: PenLineWidth) {
        self.color = color
        self.lineType = lineType
        self.lineWidth = lineWidth
    }
}
