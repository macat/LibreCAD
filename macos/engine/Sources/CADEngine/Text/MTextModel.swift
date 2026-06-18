//
//  MTextModel.swift
//  CADEngine
//
//  The rich-MTEXT paragraph/run tree (text-system-design §1.3). These value
//  types are DEFINED in Phase 1 so the Phase-2 MTEXT builder layers on without
//  re-broadcasting a model change — but Phase 1 does NOT add `EntityKind.mtext`
//  and does NOT implement per-run formatting layout (that is the next builder's
//  job). MTEXT-on-read continues to be downgraded to single-line `.text` until
//  Phase 2.
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

/// A contiguous run of text sharing formatting — the atom MTEXT layout shapes.
/// Per-run overrides; `nil` ⇒ inherit the paragraph/style value. The comments
/// give the MTEXT inline code each maps to.
public struct TextRun: Sendable, Hashable, Codable {
    public var text: String
    public var fontOverride: FontSource?    // \f  (font family / .shx switch)
    public var heightFactor: Double?        // \H  (relative: 1.5x) or absolute height
    public var color: RGBAColor?            // \C / \c  (ACI / true-color)
    public var bold: Bool?                  // \f ... |b1
    public var italic: Bool?                // \f ... |i1
    public var underline: Bool              // \L … \l
    public var overline: Bool               // \O … \o
    public var strikethrough: Bool          // \K … \k  (AutoCAD 2018+)
    public var trackingFactor: Double?      // \T  (char spacing)
    public var obliqueOverride: Double?     // \Q  (per-run slant, radians)

    public init(
        text: String,
        fontOverride: FontSource? = nil,
        heightFactor: Double? = nil,
        color: RGBAColor? = nil,
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool = false,
        overline: Bool = false,
        strikethrough: Bool = false,
        trackingFactor: Double? = nil,
        obliqueOverride: Double? = nil
    ) {
        self.text = text
        self.fontOverride = fontOverride
        self.heightFactor = heightFactor
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.overline = overline
        self.strikethrough = strikethrough
        self.trackingFactor = trackingFactor
        self.obliqueOverride = obliqueOverride
    }
}

/// A stacked fraction / tolerance: `\S<upper>^<lower>`; `\S<num>/<den>`;
/// `\S<a>#<b>`.
public struct StackedRun: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Hashable, Codable { case fraction, tolerance, diagonal } // / ^ #
    public var upper: String
    public var lower: String
    public var kind: Kind
    public var heightFactor: Double         // stacked text is drawn smaller (AutoCAD ~0.7)

    public init(upper: String, lower: String, kind: Kind, heightFactor: Double = 0.7) {
        self.upper = upper
        self.lower = lower
        self.kind = kind
        self.heightFactor = heightFactor
    }
}

/// One inline atom of a paragraph, in logical order. (Bidi reordering happens at
/// layout time.)
public enum MTextInline: Sendable, Hashable, Codable {
    case run(TextRun)
    case stacked(StackedRun)
    case tab            // \t / column tab
    // paragraph break (\P) is the boundary BETWEEN paragraphs, not an inline atom
}

public enum MTextParagraphAlign: Sendable, Hashable, Codable {
    case left, center, right, justified, distributed
}

public struct MTextParagraph: Sendable, Hashable, Codable {
    public var inlines: [MTextInline]
    public var alignment: MTextParagraphAlign?   // \pq… per-paragraph; nil ⇒ block default

    public init(inlines: [MTextInline], alignment: MTextParagraphAlign? = nil) {
        self.inlines = inlines
        self.alignment = alignment
    }
}

public enum MTextAttachment: Int, Sendable, Hashable, Codable {  // DXF 71 (DRW_MText::Attach)
    case topLeft = 1, topCenter, topRight,
         middleLeft, middleCenter, middleRight,
         bottomLeft, bottomCenter, bottomRight
}

public enum MTextLineSpacingStyle: Int, Sendable, Hashable, Codable {
    case atLeast = 1, exact = 2   // DXF 73
}

/// `RS_MTextData` equivalent. Tree (paragraphs) + block-level layout. Phase 2
/// adds `EntityKind.mtext`.
public struct MTextData: Sendable, Hashable, Codable {
    public var position: Vector                 // insertion point (DXF 10)
    public var height: Double                   // default cap height (DXF 40); runs scale relative
    public var rectWidth: Double                // wrap reference width (DXF 41); 0 ⇒ no wrap
    public var rotation: Double                 // radians (DXF 50 / X-axis vector 11)
    public var styleName: String?               // STYLE name (DXF 7)
    public var attachment: MTextAttachment      // DXF 71
    public var lineSpacingStyle: MTextLineSpacingStyle  // DXF 73
    public var lineSpacingFactor: Double        // DXF 44
    public var paragraphs: [MTextParagraph]     // the run tree
    /// The raw MTEXT inline-coded string (DXF group 1/3 concatenation), kept
    /// verbatim for LOSSLESS round-trip of codes we don't yet model. `paragraphs`
    /// is the parsed view; on write we re-emit from `paragraphs` when the user
    /// edited, else from `rawCode` (faithful passthrough).
    public var rawCode: String?
    /// Wave 2a — the auto-updating FIELDS embedded in this MTEXT's run text. When
    /// non-`nil`, the run text (`TextRun.text` across `paragraphs`) carries field
    /// PLACEHOLDERS (`FieldEvaluator.placeholder(for:)`) and each `FieldRun.index`
    /// names the token its placeholder displays; `resolve()` substitutes evaluated
    /// values into each run before shaping when a `ResolveContext.fieldContext` is
    /// supplied, else the runs shape verbatim. ADDITIVE: a record born without it —
    /// and every old saved file — decodes to `nil` (no fields), so plain MTEXT is
    /// byte-identical. `nil` vs `[]` both mean "no fields".                      [NEW]
    public var fields: [FieldRun]?

    public init(
        position: Vector,
        height: Double,
        rectWidth: Double = 0,
        rotation: Double = 0,
        styleName: String? = nil,
        attachment: MTextAttachment = .topLeft,
        lineSpacingStyle: MTextLineSpacingStyle = .atLeast,
        lineSpacingFactor: Double = 1,
        paragraphs: [MTextParagraph] = [],
        rawCode: String? = nil,
        fields: [FieldRun]? = nil
    ) {
        self.position = position
        self.height = height
        self.rectWidth = rectWidth
        self.rotation = rotation
        self.styleName = styleName
        self.attachment = attachment
        self.lineSpacingStyle = lineSpacingStyle
        self.lineSpacingFactor = lineSpacingFactor
        self.paragraphs = paragraphs
        self.rawCode = rawCode
        self.fields = fields
    }
}

// MARK: - Decodable (back-compat: tolerate a missing `fields` → nil)
//
// `fields` (Wave 2a) is ADDITIVE: an OLD saved MTEXT (encoded before fields existed)
// has no `fields` key. A hand-written `init(from:)` (the `decodeIfPresent` pattern the
// *Data structs use) decodes the absent key to `nil`, so old MTEXT loads byte-
// identically and resolves unchanged. `encode(to:)` + Hashable/Equatable stay
// synthesized (CodingKeys covers every field; Hashable auto-includes `fields`).
extension MTextData {
    private enum CodingKeys: String, CodingKey {
        case position, height, rectWidth, rotation, styleName, attachment
        case lineSpacingStyle, lineSpacingFactor, paragraphs, rawCode, fields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(Vector.self, forKey: .position)
        height = try c.decode(Double.self, forKey: .height)
        rectWidth = try c.decodeIfPresent(Double.self, forKey: .rectWidth) ?? 0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        styleName = try c.decodeIfPresent(String.self, forKey: .styleName)
        attachment = try c.decodeIfPresent(MTextAttachment.self, forKey: .attachment) ?? .topLeft
        lineSpacingStyle = try c.decodeIfPresent(MTextLineSpacingStyle.self, forKey: .lineSpacingStyle) ?? .atLeast
        lineSpacingFactor = try c.decodeIfPresent(Double.self, forKey: .lineSpacingFactor) ?? 1
        paragraphs = try c.decodeIfPresent([MTextParagraph].self, forKey: .paragraphs) ?? []
        rawCode = try c.decodeIfPresent(String.self, forKey: .rawCode)
        // ADDITIVE: old files (no `fields` key) decode to nil — plain MTEXT.
        fields = try c.decodeIfPresent([FieldRun].self, forKey: .fields)
    }
}
