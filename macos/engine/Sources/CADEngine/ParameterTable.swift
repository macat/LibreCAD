//
//  ParameterTable.swift
//  CADEngine
//
//  The NAMED-PARAMETER TABLE (Lane L1 — engine, UNWIRED): an ordered store of
//  `Parameter` value types plus the name lookup the constraint side + UI need. A
//  pure value type (ADR-001) so the whole table snapshots cheaply for value-snapshot
//  undo (ADR-002, via `CADDrawing.mutateParameters`) and round-trips through the
//  Codable document payload — mirroring `ConstraintTable` exactly.
//
//  ## A DUMB STORE — it does NOT evaluate
//  The table holds parameters; it does NOT parse or evaluate their `expression`s.
//  Names are unique (case-insensitively — the reference key), so add/replace REJECT
//  a case-insensitive duplicate name. The evaluator that fills each parameter's
//  `value` cache (and re-evaluates dependent expressions) is a LATER app-seam lane;
//  this lane is the storage + name lookup only.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// An ordered registry of named `Parameter`s — the document's parameter store. Pure
/// value type (snapshots cheaply for undo; round-trips via Codable), mirroring
/// `ConstraintTable`.
///
/// Ordering is stable insertion order (the array IS the order). Identity is by
/// `Parameter.id`, but the REFERENCE key is the NAME: the table rejects an add/replace
/// whose name (case-insensitively) collides with a DIFFERENT parameter — names are how
/// a `Constraint.expression` references a parameter, so they must be unique. Lookup by
/// name (`parameter(named:)`) is case-insensitive.
public struct ParameterTable: Sendable, Hashable, Codable {

    /// The parameters, in stable insertion order.
    public private(set) var parameters: [Parameter]

    public init(parameters: [Parameter] = []) {
        self.parameters = parameters
    }

    // MARK: - Reads

    public var count: Int { parameters.count }
    public var isEmpty: Bool { parameters.isEmpty }

    /// The parameter with `id`, or `nil`.
    public func parameter(_ id: UUID) -> Parameter? {
        parameters.first { $0.id == id }
    }

    /// The parameter named `name` (CASE-INSENSITIVE — the reference key), or `nil`.
    /// This is how a `Constraint.expression` ("width", "a*2") resolves a name to its
    /// parameter; matching is case-insensitive because parameter names are
    /// case-insensitive (matching AutoCAD/FreeCAD parameter aliases).
    public func parameter(named name: String) -> Parameter? {
        parameters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a parameter with `id` is present.
    public func contains(_ id: UUID) -> Bool {
        parameters.contains { $0.id == id }
    }

    /// Whether a parameter NAMED `name` (case-insensitive) is present.
    public func contains(named name: String) -> Bool {
        parameter(named: name) != nil
    }

    // MARK: - Mutations (the table is value-snapshotted by the CADDrawing funnel)

    /// Appends a parameter. No-op (returns `false`) if its id already exists OR its
    /// name (case-insensitively) collides with an EXISTING parameter — names are the
    /// reference key and must be unique. Returns `true` if added.
    @discardableResult
    public mutating func add(_ parameter: Parameter) -> Bool {
        guard !contains(parameter.id) else { return false }
        guard !contains(named: parameter.name) else { return false }   // dup-name reject
        parameters.append(parameter)
        return true
    }

    /// Removes the parameter with `id` (no-op if absent). Returns `true` if removed.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        let before = parameters.count
        parameters.removeAll { $0.id == id }
        return parameters.count != before
    }

    /// Removes the parameter NAMED `name` (case-insensitive; no-op if absent).
    /// Returns the id of the removed parameter, or `nil` if none matched.
    @discardableResult
    public mutating func remove(named name: String) -> UUID? {
        guard let i = parameters.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return nil }
        let id = parameters[i].id
        parameters.remove(at: i)
        return id
    }

    /// Replaces the parameter with the same id. No-op (returns `false`) if absent OR
    /// the new name (case-insensitively) collides with a DIFFERENT parameter (a
    /// rename onto another parameter's name is rejected — names stay unique). Returns
    /// `true` if a parameter was replaced. (A no-name-change replace, or a case-only
    /// rename of the SAME parameter, is allowed.)
    @discardableResult
    public mutating func replace(_ parameter: Parameter) -> Bool {
        guard let i = parameters.firstIndex(where: { $0.id == parameter.id }) else { return false }
        // Reject if the new name collides with a DIFFERENT parameter.
        if parameters.contains(where: {
            $0.id != parameter.id && $0.name.caseInsensitiveCompare(parameter.name) == .orderedSame
        }) { return false }
        parameters[i] = parameter
        return true
    }

    // MARK: - Codable (additive back-compat)

    private enum CodingKeys: String, CodingKey { case parameters }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A payload written before this table existed (or an empty one) decodes to an
        // empty table — the same `decodeIfPresent` back-compat `ConstraintTable` uses,
        // so an old document loads with no parameters.
        parameters = try c.decodeIfPresent([Parameter].self, forKey: .parameters) ?? []
    }
}
