//
//  FieldEvaluator.swift
//  CADEngine
//
//  Wave 2a — the FIELDS engine evaluator + the placeholder/substitution scheme.
//
//  A field-bearing TEXT/MTEXT stores its string with PLACEHOLDERS in place of each
//  field's live value, plus a `fields: [FieldRun]` list naming the token each
//  placeholder displays. `resolve()` substitutes the evaluated value for every
//  placeholder — but ONLY when a `FieldContext` is supplied; with no context (or no
//  fields) the displayed string is byte-identical to the stored string, so resolve
//  is a regression-locked no-op for non-field text.
//
//  ## Placeholder scheme (round-trip-lossless, documented)
//  A field placeholder is the marker `U+FEFF "{" <index> "}" U+FEFF` — a
//  zero-width-no-break-space (`U+FEFF`, the BOM/ZWNBSP) bracketing a literal
//  `{<index>}`. The two `U+FEFF` sentinels make the marker reliably detectable and,
//  being zero-width, render to nothing if ever shaped un-substituted. `<index>` is
//  the decimal slot the `FieldRun.index` matches. The stored string + the `fields`
//  array round-trip losslessly through Codable (the marker is plain text; the tokens
//  are a separate Codable list). DXF persistence stores the EVALUATED text only (the
//  fields ride the engine's Codable payload, not DXF FIELD objects) — see the file
//  header / decision-log; a later wave may add DXF FIELD round-trip.
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

// MARK: - Field context

/// The document-side values the field evaluator needs to produce live field text.
/// Every value is OPTIONAL: a missing value makes the corresponding field evaluate
/// to the missing sentinel (`FieldEvaluator.missingSentinel`). The app populates
/// this in a later wire-wave (from the document's date / active layout / file URL);
/// the engine carries the mechanism + a `nil` default on `ResolveContext` so a
/// resolve without it is unchanged.
///
/// `Sendable` so it threads through the `Sendable` `ResolveContext`. The
/// `objectPropertyResolver` is the forward-compatible hook a later wave wires to
/// measure a referenced entity's area/length/radius; `nil` (the default) keeps
/// `.objectProperty` fields at the missing sentinel.
public struct FieldContext: Sendable {
    /// The current date/time used by `.date` fields. `nil` ⇒ `.date` ⇒ sentinel.
    public var date: Date?
    /// The active layout / sheet name used by `.layoutName` fields. `nil`/empty ⇒
    /// `.layoutName` ⇒ sentinel.
    public var layoutName: String?
    /// The drawing file name/path used by `.fileName` fields (the FULL path or the
    /// bare name — the `.fileName` format hint picks the variant). `nil`/empty ⇒
    /// `.fileName` ⇒ sentinel.
    public var fileName: String?
    /// FORWARD-COMPATIBLE (Wave 2a stretch): resolves a `.objectProperty` field to a
    /// formatted value string for `(entityID, property)`. A `nil` resolver — or a
    /// `nil` return — keeps `.objectProperty` fields at the missing sentinel.
    public var objectPropertyResolver: (@Sendable (EntityID, String) -> String?)?

    public init(
        date: Date? = nil,
        layoutName: String? = nil,
        fileName: String? = nil,
        objectPropertyResolver: (@Sendable (EntityID, String) -> String?)? = nil
    ) {
        self.date = date
        self.layoutName = layoutName
        self.fileName = fileName
        self.objectPropertyResolver = objectPropertyResolver
    }
}

// MARK: - Field evaluator

/// Evaluates a `FieldToken` against a `FieldContext` to its displayed string, and
/// performs the placeholder substitution that turns a stored field-bearing string
/// into its live displayed form. Pure (side-effect-free) — unit-testable with no
/// GPU / live view.
public enum FieldEvaluator {
    /// AutoCAD's display for a field whose value cannot be resolved — substituted
    /// for any field whose context value is missing/unavailable.
    public static let missingSentinel = "####"

    /// The zero-width sentinel character (`U+FEFF`, ZWNBSP/BOM) that brackets a
    /// field placeholder. Zero-width so an un-substituted marker shapes to nothing.
    static let markerChar: Character = "\u{FEFF}"

    /// The placeholder marker for slot `index`: `U+FEFF "{" index "}" U+FEFF`.
    /// Embedded in a host string in place of a field's value; `substitute(...)`
    /// replaces it with the evaluated token text (or the stored marker, byte-
    /// identical, when no context is supplied).
    public static func placeholder(for index: Int) -> String {
        "\(markerChar){\(index)}\(markerChar)"
    }

    // MARK: Token evaluation

    /// Evaluates one field token to its displayed string. A value the context does
    /// not supply yields `missingSentinel`.
    public static func evaluate(_ token: FieldToken, context: FieldContext) -> String {
        switch token {
        case .date(let format):
            guard let date = context.date else { return missingSentinel }
            return formatDate(date, hint: format)

        case .layoutName:
            guard let name = context.layoutName, !name.isEmpty else { return missingSentinel }
            return name

        case .fileName(let format):
            guard let raw = context.fileName, !raw.isEmpty else { return missingSentinel }
            return formatFileName(raw, hint: format)

        case .objectProperty(let id, let property, _):
            guard let resolver = context.objectPropertyResolver,
                  let value = resolver(id, property) else { return missingSentinel }
            return value
        }
    }

    // MARK: Placeholder substitution

    /// Substitutes the evaluated value of each `FieldRun` for its placeholder marker
    /// in `text`. Returns `text` UNCHANGED when `context == nil` or `fields` is
    /// `nil`/empty (the regression-lock: non-field text, and any resolve without a
    /// field context, is byte-identical to the stored string). A placeholder whose
    /// matching `FieldRun` is missing is left as-is (the marker is zero-width, so it
    /// renders to nothing rather than as visible garbage).
    public static func substitute(_ text: String, fields: [FieldRun]?, context: FieldContext?) -> String {
        guard let context, let fields, !fields.isEmpty else { return text }
        guard text.contains(markerChar) else { return text }
        var result = text
        for run in fields {
            let marker = placeholder(for: run.index)
            guard result.contains(marker) else { continue }
            let value = evaluate(run.token, context: context)
            result = result.replacingOccurrences(of: marker, with: value)
        }
        return result
    }

    // MARK: Formatting helpers

    /// Formats a date by the `.date` token's `format` hint (a `DateFormatter`
    /// `dateFormat` pattern). `nil`/empty ⇒ a medium date + short time default.
    static func formatDate(_ date: Date, hint: String?) -> String {
        let df = DateFormatter()
        // Use a fixed POSIX locale so a pattern hint formats deterministically
        // (locale-independent), matching how CAD field formats are authored.
        df.locale = Locale(identifier: "en_US_POSIX")
        if let hint, !hint.isEmpty {
            df.dateFormat = hint
        } else {
            df.dateStyle = .medium
            df.timeStyle = .short
        }
        return df.string(from: date)
    }

    /// Formats a file name/path by the `.fileName` token's hint (`FieldFileNameFormat`).
    static func formatFileName(_ raw: String, hint: String?) -> String {
        switch FieldFileNameFormat.from(hint) {
        case .fullPath:
            return raw
        case .nameWithExtension:
            return (raw as NSString).lastPathComponent
        case .nameNoExtension:
            let last = (raw as NSString).lastPathComponent
            return (last as NSString).deletingPathExtension
        }
    }
}
