//
//  ConstraintTable.swift
//  CADEngine
//
//  The CONSTRAINT TABLE (Wave 1 — engine, UNWIRED): an ordered store of
//  `Constraint` value types plus the queries the solver + UI need. A pure value
//  type (ADR-001) so the whole table snapshots cheaply for value-snapshot undo
//  (ADR-002, via `CADDrawing.mutateConstraints`) and round-trips through the
//  Codable document payload.
//
//  Queries:
//    • `referencing(_:)`        — every constraint that touches an entity id.
//    • `connectedComponent(of:)`— the set of entities transitively coupled to a
//                                 seed entity by shared constraints (the unit the
//                                 solver solves at once).
//    • `touchedComponents(containing:)` — the DISTINCT components that intersect a
//                                 set of edited ids (dirty-component incremental
//                                 re-solve: only these need the solver; the rest
//                                 of the drawing is untouched).
//    • `dropDangling(removedID:)`— drop every constraint that references a deleted
//                                 entity (the entity-remove hook keeps the table
//                                 consistent — no constraint ever points at a gone
//                                 entity).
//
//  Wave 3 — sparsity + incremental: the solver is PURE (value in, value out) and
//  solves ONE connected component at a time. Callers (e.g. CanvasModel) MUST use
//  `touchedComponents(containing:)` to find the dirty components after an edit and
//  invoke `ConstraintSolver` only on those — never the whole table. This keeps a
//  single-entity edit O(component size) instead of O(table size) and preserves the
//  solver's pure contract (no global state, no incremental cache inside the solver).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// An ordered registry of parametric `Constraint`s — the document's constraint
/// store. Pure value type (snapshots cheaply for undo; round-trips via Codable).
///
/// Ordering is stable insertion order (the array IS the order). Identity is by
/// `Constraint.id`; the table rejects an add whose id already exists (so an undo
/// re-add is idempotent-safe), and edit/remove key off the id.
public struct ConstraintTable: Sendable, Hashable, Codable {

    /// The constraints, in stable insertion order.
    public private(set) var constraints: [Constraint]

    public init(constraints: [Constraint] = []) {
        self.constraints = constraints
    }

    // MARK: - Reads

    public var count: Int { constraints.count }
    public var isEmpty: Bool { constraints.isEmpty }

    /// The constraint with `id`, or `nil`.
    public func constraint(_ id: UUID) -> Constraint? {
        constraints.first { $0.id == id }
    }

    /// Whether a constraint with `id` is present.
    public func contains(_ id: UUID) -> Bool {
        constraints.contains { $0.id == id }
    }

    // MARK: - Mutations (the table is value-snapshotted by the CADDrawing funnel)

    /// Appends a constraint. No-op (returns `false`) if its id already exists, so a
    /// double-add (e.g. an undo race) can't duplicate it. Returns `true` if added.
    @discardableResult
    public mutating func add(_ constraint: Constraint) -> Bool {
        guard !contains(constraint.id) else { return false }
        constraints.append(constraint)
        return true
    }

    /// Removes the constraint with `id` (no-op if absent). Returns `true` if removed.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        let before = constraints.count
        constraints.removeAll { $0.id == id }
        return constraints.count != before
    }

    /// Replaces the constraint with the same id (no-op if absent). Returns `true`
    /// if a constraint was replaced.
    @discardableResult
    public mutating func replace(_ constraint: Constraint) -> Bool {
        guard let i = constraints.firstIndex(where: { $0.id == constraint.id }) else { return false }
        constraints[i] = constraint
        return true
    }

    /// Sets the driven `value` of the (dimensional) constraint with `id`. No-op
    /// (returns `false`) if absent OR the constraint is geometric (no driven value).
    /// Returns `true` if the value changed.
    @discardableResult
    public mutating func setValue(_ id: UUID, _ value: Double) -> Bool {
        guard let i = constraints.firstIndex(where: { $0.id == id }),
              constraints[i].kind.isDimensional,
              constraints[i].value != value else { return false }
        constraints[i].value = value
        return true
    }

    // MARK: - Queries

    /// Every constraint that references `entityID`, in table order.
    public func referencing(_ entityID: EntityID) -> [Constraint] {
        constraints.filter { $0.references(entityID) }
    }

    /// Every DISTINCT entity id mentioned by any constraint (the constrained set).
    public var referencedEntityIDs: Set<EntityID> {
        var ids = Set<EntityID>()
        for c in constraints { ids.formUnion(c.entityIDs) }
        return ids
    }

    /// The CONNECTED COMPONENT of `seed`: the set of entity ids transitively
    /// coupled to `seed` by shared constraints. Two entities are coupled if any one
    /// constraint references both; the component is the transitive closure of that
    /// relation, ALWAYS including `seed` itself (a lone, unconstrained entity is its
    /// own singleton component). This is the unit the solver solves at once — every
    /// constraint that could pull on `seed`'s geometry, and every entity those
    /// constraints in turn touch.
    ///
    /// BFS over the constraint graph; O(constraints × component size) which is
    /// ample (constraint counts are small relative to entities).
    public func connectedComponent(of seed: EntityID) -> Set<EntityID> {
        var component: Set<EntityID> = [seed]
        var frontier: [EntityID] = [seed]
        while let current = frontier.popLast() {
            for c in constraints where c.references(current) {
                for id in c.entityIDs where component.insert(id).inserted {
                    frontier.append(id)
                }
            }
        }
        return component
    }

    /// Every constraint whose entity set lies ENTIRELY within `entityIDs`. Used by
    /// the solver to gather the constraints that apply to a component it is about to
    /// solve (a component closed under `connectedComponent` is closed under this —
    /// every constraint touching a component member touches only component members).
    public func constraints(within entityIDs: Set<EntityID>) -> [Constraint] {
        constraints.filter { c in c.entityIDs.allSatisfy { entityIDs.contains($0) } }
    }

    // MARK: - Dirty-component helper (Wave 3 — incremental)

    /// The DISTINCT connected components that intersect `ids`.
    ///
    /// Each returned component is the transitive closure of a seed in `ids`; components
    /// are disjoint and together comprise exactly the entities whose constraints could
    /// have been affected by an edit that touched `ids`. Callers that mutate geometry
    /// should re-solve ONLY these components — the solver is pure and solves one
    /// component at a time, and the rest of the table needs no work.
    ///
    /// - If `ids` is empty or none of its members are constrained, the result is `[]`
    ///   (nothing to re-solve — the cheap early-out).
    /// - The order of the returned components follows the first-seen order of `ids`.
    ///
    /// Pure, O(constraints × component size) BFS only over the touched region; never
    /// scans the whole table beyond the BFS frontier.
    public func touchedComponents(containing ids: Set<EntityID>) -> [Set<EntityID>] {
        guard !ids.isEmpty, !constraints.isEmpty else { return [] }
        let constrained = referencedEntityIDs
        // Keep only seeds that actually participate in a constraint; an unconstrained
        // edit never dirties a component.
        let seeds = ids.filter { constrained.contains($0) }
        guard !seeds.isEmpty else { return [] }
        var seen: Set<EntityID> = []
        var result: [Set<EntityID>] = []
        result.reserveCapacity(seeds.count)
        for seed in seeds where !seen.contains(seed) {
            let comp = connectedComponent(of: seed)
            seen.formUnion(comp)
            result.append(comp)
        }
        return result
    }

    /// Convenience overload for an array of ids.
    public func touchedComponents(containing ids: [EntityID]) -> [Set<EntityID>] {
        touchedComponents(containing: Set(ids))
    }

    /// All DISTINCT connected components present in the table (the partition of
    /// `referencedEntityIDs` under `connectedComponent`). Useful for full-table
    /// operations like `resolveAllConstraints`; prefer `touchedComponents` for
    /// incremental edits.
    public var allComponents: [Set<EntityID>] {
        var seen: Set<EntityID> = []
        var result: [Set<EntityID>] = []
        for id in referencedEntityIDs where !seen.contains(id) {
            let comp = connectedComponent(of: id)
            seen.formUnion(comp)
            result.append(comp)
        }
        return result
    }

    // MARK: - Dangling drop (entity-remove hook)

    /// Drops EVERY constraint that references `removedID` (called when an entity is
    /// deleted, so the table never points at a gone entity). Returns the ids of the
    /// constraints that were dropped (empty if none referenced it) — the caller can
    /// surface "N constraints removed" / register them for undo coherence.
    @discardableResult
    public mutating func dropDangling(removedID: EntityID) -> [UUID] {
        let dropped = constraints.filter { $0.references(removedID) }.map(\.id)
        guard !dropped.isEmpty else { return [] }
        constraints.removeAll { $0.references(removedID) }
        return dropped
    }

    // MARK: - Codable (additive back-compat)

    private enum CodingKeys: String, CodingKey { case constraints }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A payload written before this table existed (or an empty one) decodes to
        // an empty table — the same `decodeIfPresent` back-compat the entity *Data
        // structs use, so an old document loads with no constraints.
        constraints = try c.decodeIfPresent([Constraint].self, forKey: .constraints) ?? []
    }
}
