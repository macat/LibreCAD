//
//  Parameter.swift
//  CADEngine
//
//  The NAMED-PARAMETER value model (Lane L1 — engine, UNWIRED). A `Parameter` is a
//  named, expression-backed numeric a dimensional `Constraint` can reference (the
//  "user variable" of a parametric sketcher — AutoCAD's PARAMETERS / FreeCAD's
//  Sketcher named constraints / the SpreadSheet alias): the user names a value
//  ("width", "a"), writes a SOURCE EXPRESSION for it ("22", "a*2"), and a driven
//  dimension is bound to that name instead of a bare literal.
//
//  ## Design (additive, value-type, undoable — the project pattern)
//  Parameters are ADDITIVE document state, NOT a new `EntityKind` case (adding a
//  case is a serialized critical section across ~28 files; the parameter set is a
//  separate list on `CADDrawing`, exactly like the constraint table + `Layout.
//  viewports` live outside `EntityKind`). The type is `Sendable, Hashable, Codable,
//  Identifiable` so the table snapshots cheaply for value-snapshot undo (ADR-002)
//  and round-trips through the Codable document payload, with `decodeIfPresent`
//  back-compat so a payload written before a field existed still loads.
//
//  ## What a Parameter does NOT do here (Lane L1 scope)
//  A `Parameter` carries BOTH the source `expression` text AND the last-EVALUATED
//  `value` cache — but it does NOT evaluate the expression itself. The `value`
//  cache is written by a LATER app-seam lane that runs an expression evaluator over
//  the table; this lane is the dumb STORE only (no parsing, no evaluation, no
//  dependency-graph). The mirror on the constraint side is `Constraint.expression`
//  (see `Constraints.swift`): a dimensional constraint bound to a parameter holds
//  the parameter's name (or an expression in its terms) as text, and the solver
//  still reads ONLY the evaluated numeric `value` — unchanged.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// One NAMED PARAMETER — a value type (ADR-001) pairing a user-facing `name` with
/// a source `expression` and the last-EVALUATED numeric `value` cache.
///
/// A parameter is referenced BY NAME (case-insensitively — see
/// `ParameterTable.parameter(named:)`): a driven dimension's `Constraint.
/// expression` may be the parameter's name ("width") or an expression in its terms
/// ("width/2"), and an evaluator (a LATER lane) resolves those names to numbers and
/// writes the resulting `value` back here + onto the referencing constraints. This
/// type STORES the pieces; it does not evaluate.
///
/// Identity is by `id` (a stable `UUID`); the table edits/removes by id and rejects
/// a case-insensitive DUPLICATE NAME on add/replace (parameter names are the
/// reference key, so they must be unique). `expression` is the SOURCE text the user
/// typed; `value` is the numeric the evaluator last produced for it (for a bare
/// literal like "22" the two agree once evaluated). `unit` is an optional display
/// unit string (e.g. "mm") — purely informational here.
public struct Parameter: Sendable, Hashable, Codable, Identifiable {

    /// Stable identity (minted on creation). Lets the table edit/remove a specific
    /// parameter and lets the UI track selection independently of the (mutable) name.
    public var id: UUID
    /// The user-facing NAME — the key a `Constraint.expression` references
    /// (case-insensitively). Unique within the table (the table rejects a
    /// case-insensitive duplicate on add/replace).
    public var name: String
    /// The SOURCE expression text the user typed for this parameter — e.g. "22"
    /// (a bare literal) or "a*2" (in terms of other parameters). This lane STORES
    /// it verbatim; a later evaluator lane parses + evaluates it into `value`.
    public var expression: String
    /// The last-EVALUATED numeric value of `expression` (the cache the solver-facing
    /// side reads). Written by the evaluator lane; for an as-yet-unevaluated bare
    /// literal it is conventionally the literal's value (a seed the caller supplies).
    public var value: Double
    /// An optional display UNIT string (e.g. "mm", "deg") — purely informational
    /// metadata for the UI; the model does not interpret it. `nil` ⇒ unitless.
    public var unit: String?

    public init(
        id: UUID = UUID(),
        name: String,
        expression: String,
        value: Double = 0,
        unit: String? = nil
    ) {
        self.id = id
        self.name = name
        self.expression = expression
        self.value = value
        self.unit = unit
    }

    // MARK: Codable (additive back-compat)

    private enum CodingKeys: String, CodingKey { case id, name, expression, value, unit }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is additive-tolerant: a payload written without it mints a fresh one
        // (a parameter with no id is still valid; identity is local), matching how
        // `Constraint`'s id decodes.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // A payload predating the source-text split decodes to an empty expression.
        expression = try c.decodeIfPresent(String.self, forKey: .expression) ?? ""
        // A parameter born without an evaluated cache decodes to 0.
        value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        // `unit` is optional metadata; absent ⇒ unitless.
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
    }
}
