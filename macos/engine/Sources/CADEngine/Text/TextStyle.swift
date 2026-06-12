//
//  TextStyle.swift
//  CADEngine
//
//  The DXF STYLE table model (text-system-design §1.1) plus the MTEXT run-tree
//  types (§1.3). Pure value types (ADR-001), `Sendable, Hashable, Codable`, so
//  they snapshot for undo (ADR-002) and serialize for the document store. Field
//  comments give the DXF group code each maps to (DRW_Textstyle / LC_TextStyle /
//  DRW_MText), so DXF round-trip is structural, not lossy.
//
//  Phase 1 defines the FULL-scope model (even where features are stubbed) so
//  Phases 2-4 layer on without re-broadcasting a model change. The MTEXT run-tree
//  types are DEFINED here but NOT implemented (no `EntityKind.mtext` — that is the
//  Phase-2 serialized EntityKind step).
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

// MARK: - Font source (ADR-004: the two glyph sources behind one provider)

/// The glyph source a style resolves through (ADR-004's "two impls behind ONE
/// FontProvider").
public enum FontSource: Sendable, Hashable, Codable {
    /// Native outline font: a macOS font family resolved via Core Text → glyph
    /// paths → fills. `family` is a PostScript/family name ("Helvetica Neue",
    /// "SF Pro Text"). DEFAULT for new text.
    case native(family: String)
    /// LibreCAD stroke font: a `.lff` base name ("standard", "iso"). Retained for
    /// DXF fidelity.
    case stroke(lff: String)
    /// AutoCAD compiled shape font (.shx). Phase 3. Read-only; mapped to a fallback
    /// (the substitution chain) until SHX lands.
    case shx(file: String)
}

// MARK: - STYLE table flags

/// Text-generation flags (code 71): backward (X-mirror) / upside-down (Y-mirror).
public struct TextGenerationFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let backward   = TextGenerationFlags(rawValue: 2) // code 71 bit: mirror X
    public static let upsideDown = TextGenerationFlags(rawValue: 4) // code 71 bit: mirror Y
}

/// STYLE flags (code 70 on the table entry): e.g. shape-file / vertical. Carried
/// for round-trip.
public struct TextStyleFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The style describes a shape file rather than a text font (code 70 bit 0x01).
    public static let shapeFile = TextStyleFlags(rawValue: 1)
    /// Vertical text style (code 70 bit 0x04).
    public static let vertical  = TextStyleFlags(rawValue: 4)
}

/// Stable id for a style slot (parallels `EntityID` / `LayerID`).
public struct TextStyleID: Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

// MARK: - TextStyle (the DXF STYLE table entry)

/// A named text style — the DXF STYLE table entry. One per `TextStyleTable` slot.
/// Field comments give the DXF group code it maps to (DRW_Textstyle / LC_TextStyle).
public struct TextStyle: Sendable, Hashable, Codable, Identifiable {
    public var id: TextStyleID            // stable id in the table (name is the DXF key)
    public var name: String               // STYLE table name, e.g. "Standard" (DXF: the table key)

    /// Where glyphs come from. Encodes BOTH the primary font file (DXF code 3) and
    /// source kind. For DXF round-trip: `.native(family)` ⇒ family in code 3 + the
    /// 1071 TTF-family flag; `.stroke(lff)`/`.shx(file)` ⇒ code 3 is the `.lff`/
    /// `.shx` file name.
    public var primaryFont: FontSource

    /// Optional Asian "big font" companion (DXF code 4). Only meaningful for `.shx`
    /// primaries (SHX + bigfont is the classic CJK pairing). `nil` for native/lff.
    public var bigFont: String?

    public var fixedTextHeight: Double    // code 40; 0 = "not fixed" (entity supplies height)
    public var widthFactor: Double        // code 41; default 1.0 (horizontal scale of glyphs)
    public var obliqueAngle: Double       // code 50; radians (DXF stores degrees); slant
    public var lastHeight: Double         // code 42; last interactively used height (UI convenience)

    /// Backward (X-mirror) / upside-down (Y-mirror) generation flags (code 71).
    public var generation: TextGenerationFlags

    /// TTF family / italic / bold flags (code 1071). For `.native`, bold/italic are
    /// ALSO expressible by choosing a face; this mirror keeps DXF round-trip.
    public var bold: Bool
    public var italic: Bool

    /// STYLE flags (code 70 on the table entry). Carried for round-trip.
    public var styleFlags: TextStyleFlags

    /// Annotative flag (DXF XDATA `AcDbTextStyleAnnotative`). When `true`, text
    /// using this style is scaled by `ResolveContext.annotationScale` at resolve
    /// time (text-system-design §"annotative mechanism"; ADR T4). The full
    /// per-viewport machinery is a later wave; the FIELD + scaling are wired now.
    public var annotative: Bool

    public init(
        id: TextStyleID = TextStyleID(0),
        name: String = TextStyleTable.standardName,
        primaryFont: FontSource = .native(family: TextStyle.defaultNativeFamily),
        bigFont: String? = nil,
        fixedTextHeight: Double = 0,
        widthFactor: Double = 1,
        obliqueAngle: Double = 0,
        lastHeight: Double = 2.5,
        generation: TextGenerationFlags = [],
        bold: Bool = false,
        italic: Bool = false,
        styleFlags: TextStyleFlags = [],
        annotative: Bool = false
    ) {
        self.id = id
        self.name = name
        self.primaryFont = primaryFont
        self.bigFont = bigFont
        self.fixedTextHeight = fixedTextHeight
        self.widthFactor = widthFactor
        self.obliqueAngle = obliqueAngle
        self.lastHeight = lastHeight
        self.generation = generation
        self.bold = bold
        self.italic = italic
        self.styleFlags = styleFlags
        self.annotative = annotative
    }

    /// The default native font family for newly created text (ADR T1 recommend B:
    /// Helvetica Neue — the closest-to-CAD/ISO native sans, universally installed,
    /// substitutes cleanly for romans/simplex).
    public static let defaultNativeFamily = "Helvetica Neue"

    /// The classic stroke "Standard" — `.lff` "standard" still selectable.
    public static let strokeStandard = TextStyle(
        name: "StrokeStandard", primaryFont: .stroke(lff: "standard"))
}

// MARK: - TextStyleTable (the document's STYLE table)

/// The document's STYLE table (parallels `LayerTable` / `BlockTable`). Always
/// contains "Standard". Name lookup is case-insensitive (matching DXF).
public struct TextStyleTable: Sendable, Hashable, Codable {
    public var styles: [TextStyleID: TextStyle]
    /// Case-insensitive name → id (the lookup key is the lowercased name).
    public var byName: [String: TextStyleID]
    /// Monotonic id allocator (next free id).
    private var nextID: UInt32

    public static let standardName = "Standard"

    public init() {
        let standard = TextStyle(id: TextStyleID(0), name: Self.standardName)
        self.styles = [standard.id: standard]
        self.byName = [Self.standardName.lowercased(): standard.id]
        self.nextID = 1
    }

    /// The always-present "Standard" style (created on init, never nil).
    public var standard: TextStyle {
        styles[byName[Self.standardName.lowercased()] ?? TextStyleID(0)]
            ?? TextStyle(name: Self.standardName)
    }

    /// Resolve a code-7 style name (case-insensitive); `nil` if absent.
    public func style(named name: String) -> TextStyle? {
        guard let id = byName[name.lowercased()] else { return nil }
        return styles[id]
    }

    /// Inserts or replaces a style by name, allocating an id if the name is new.
    /// Returns the (possibly newly allocated) id. The "Standard" slot keeps id 0.
    @discardableResult
    public mutating func upsert(_ style: TextStyle) -> TextStyleID {
        let key = style.name.lowercased()
        if let existing = byName[key] {
            var s = style
            s.id = existing
            styles[existing] = s
            return existing
        }
        let id = TextStyleID(nextID)
        nextID += 1
        var s = style
        s.id = id
        styles[id] = s
        byName[key] = id
        return id
    }
}
