//
//  FieldToken.swift
//  CADEngine
//
//  Wave 2a — the FIELDS engine (auto-updating text fields embedded in TEXT/MTEXT,
//  evaluated at resolve time). A FIELD is a placeholder inside a text entity's
//  string whose DISPLAYED value is computed on demand from the document context
//  (current date, the active layout/sheet name, the file name, …) — AutoCAD's
//  FIELD object family. Per ADR-001 the evaluated value is NEVER stored on the
//  entity: the entity stores a placeholder + the field TOKEN, and `resolve()`
//  substitutes the live value (when a `FieldContext` is supplied) before shaping.
//
//  This file defines the value model: `FieldToken` (the field kinds + an optional
//  format hint) and `FieldRun` (a token tied to its placeholder INDEX in the host
//  string). The evaluator + the substitution-context live in `FieldEvaluator.swift`.
//  All types are additive — no new `EntityKind` case; fields ride the existing
//  TEXT/MTEXT entities via an additive `fields` array.
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

// MARK: - Field kind

/// An auto-updating text **field** — the kind of live value substituted into a
/// TEXT/MTEXT string at resolve time (AutoCAD's FIELD object family). Each case
/// carries an optional `format` hint string the evaluator interprets for that kind
/// (e.g. a date format for `.date`); `nil`/empty means "use the kind's default
/// format". A field whose value is unavailable in the supplied `FieldContext`
/// evaluates to the missing-field sentinel (`FieldEvaluator.missingSentinel`,
/// `"####"`), matching AutoCAD's "####" display for an unresolved field.
///
/// MVP set (Wave 2a): `.date`, `.layoutName`, `.fileName`. `.objectProperty` is a
/// FORWARD-COMPATIBLE case (so the storage/codec/evaluator API is stable when a
/// later wave implements object-property fields — area/length/radius of a referenced
/// entity); in this wave it always evaluates to the missing sentinel unless the
/// context supplies an `objectPropertyResolver` that returns a value for it.
public enum FieldToken: Sendable, Hashable, Codable {
    /// The CURRENT date/time, formatted by the `format` hint (a `DateFormatter`
    /// `dateFormat` pattern, e.g. `"yyyy-MM-dd"`). `nil`/empty `format` ⇒ the
    /// evaluator's medium-date default. Value source: `FieldContext.date`.
    case date(format: String? = nil)

    /// The ACTIVE layout / sheet name (the printed sheet a paper-space entity is on,
    /// e.g. `"Layout1"`; for a model-space drawing, the model tab name). Value
    /// source: `FieldContext.layoutName`. `format` is unused (reserved) for now.
    case layoutName(format: String? = nil)

    /// The drawing / FILE name. By default the file's last path component WITHOUT its
    /// extension (AutoCAD's `Filename` field default); the `format` hint selects a
    /// variant — see `FieldFileNameFormat`. Value source: `FieldContext.fileName`.
    case fileName(format: String? = nil)

    /// A PROPERTY of a referenced entity (area / length / radius / …) — AutoCAD's
    /// object-property field. FORWARD-COMPATIBLE: declared so storage/codec/evaluator
    /// stay stable, but in Wave 2a it evaluates to the missing sentinel unless the
    /// context's `objectPropertyResolver` returns a value. `property` is a documented
    /// key (see `FieldObjectProperty`); `format` is a numeric format hint for a later
    /// wave.
    case objectProperty(entityID: EntityID, property: String, format: String? = nil)

    /// This token's format hint (the per-kind interpretation is the evaluator's), or
    /// `nil` when none was supplied / the kind ignores it.
    public var formatHint: String? {
        switch self {
        case .date(let f):                 return f
        case .layoutName(let f):           return f
        case .fileName(let f):             return f
        case .objectProperty(_, _, let f): return f
        }
    }
}

// MARK: - Documented format-hint vocabularies

/// The recognized `format` hints for a `.fileName` field. The raw string stored in
/// the token is matched case-insensitively against these; an unrecognized/`nil`
/// hint falls back to `.nameNoExtension` (the AutoCAD `Filename` default).
public enum FieldFileNameFormat: String, Sendable, Hashable, CaseIterable {
    /// The last path component WITHOUT its extension (e.g. `"drawing"`). Default.
    case nameNoExtension = "name"
    /// The last path component WITH its extension (e.g. `"drawing.dxf"`).
    case nameWithExtension = "nameext"
    /// The FULL path as supplied (e.g. `"/Users/me/drawing.dxf"`).
    case fullPath = "path"

    /// Maps a stored hint to a format, defaulting to `.nameNoExtension`.
    public static func from(_ hint: String?) -> FieldFileNameFormat {
        guard let hint, let v = FieldFileNameFormat(rawValue: hint.lowercased()) else {
            return .nameNoExtension
        }
        return v
    }
}

/// The recognized object-property keys for a `.objectProperty` field (forward-
/// compatible vocabulary; honored by a later wave's `objectPropertyResolver`).
public enum FieldObjectProperty: String, Sendable, Hashable, CaseIterable {
    case area
    case length
    case radius
    case diameter
    case circumference
}

// MARK: - Field run (token ↔ placeholder)

/// One embedded field in a TEXT/MTEXT string: the `token` to evaluate, addressed by
/// its placeholder **index** in the host string. The host `text` carries a
/// placeholder marker `FieldEvaluator.placeholder(for: index)` (a zero-width
/// `U+FEFF`-delimited `{index}` run — see `FieldEvaluator`); `fields[index]` (the
/// `FieldRun` whose `index == n`) names the token that placeholder displays. The
/// representation is order-independent (the run carries its own `index`) so a clean
/// round-trip does not depend on array position, though the conventional layout is
/// `fields[n].index == n`.
public struct FieldRun: Sendable, Hashable, Codable {
    /// The placeholder slot this run fills — the `n` in the host string's
    /// `FieldEvaluator.placeholder(for: n)` marker.
    public var index: Int
    /// The field to evaluate for this placeholder.
    public var token: FieldToken

    public init(index: Int, token: FieldToken) {
        self.index = index
        self.token = token
    }
}
