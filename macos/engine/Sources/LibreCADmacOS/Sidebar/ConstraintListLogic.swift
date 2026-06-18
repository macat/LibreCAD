//
//  ConstraintListLogic.swift
//  LibreCADmacOS
//
//  The PURE, SwiftUI-FREE logic behind the Constraints sidebar panel
//  (`ConstraintsSidebar.swift`) and the Inspector's Constraints section
//  (`InspectorView.swift`): how the drawing's constraint list is GROUPED by category,
//  FILTERED to the current selection, described in each row (kind name / referenced
//  entities / driven value), and which entities a row's click-to-select targets.
//
//  It imports ONLY `CADEngine` value types (no SwiftUI / AppKit), so every decision the
//  panel makes is unit-tested headlessly through the `_SharedConstraintListLogic.swift`
//  symlink (the test target depends only on CADEngine). The SwiftUI views in
//  `ConstraintsSidebar.swift` / `InspectorView.swift` are thin shells over these helpers.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CADEngine

// MARK: - Pure list logic (SwiftUI-free; unit-tested)

/// The PURE, value-type logic behind the Constraints panel + the Inspector's Constraints
/// section: how the constraint list is GROUPED, FILTERED to the selection, and described
/// in each row (the kind name, the entities it references, the driven value).
enum ConstraintListModel {

    // MARK: Grouping

    /// The two display categories the panel groups by. `Identifiable`/`CaseIterable` so a
    /// SwiftUI `ForEach` can iterate them in a stable order (Geometric first).
    enum Category: String, CaseIterable, Identifiable, Hashable {
        case geometric
        case dimensional
        var id: String { rawValue }

        /// The section header title.
        var title: String {
            switch self {
            case .geometric:   return "Geometric"
            case .dimensional: return "Dimensional"
            }
        }

        /// The category a constraint belongs to.
        static func of(_ c: Constraint) -> Category {
            c.kind.isDimensional ? .dimensional : .geometric
        }
    }

    /// The constraints of `category` from `constraints`, in stable table order. Inferred
    /// (hidden) constraints are EXCLUDED — they have no user-visible glyph (the overlay
    /// skips them) so listing them here would let the user delete an auto-companion they
    /// never created. (`includeInferred: true` keeps them, for tests / a future "show
    /// hidden" affordance.)
    static func constraints(in category: Category,
                            from constraints: [Constraint],
                            includeInferred: Bool = false) -> [Constraint] {
        constraints.filter {
            (includeInferred || !$0.inferred) && Category.of($0) == category
        }
    }

    /// Whether `constraints` has any USER-VISIBLE (non-inferred) constraint — drives the
    /// panel's empty state.
    static func hasVisibleConstraints(_ constraints: [Constraint]) -> Bool {
        constraints.contains { !$0.inferred }
    }

    // MARK: Selection filter

    /// The subset of `constraints` that reference ANY entity in `selectionIDs` — what the
    /// "Selection only" filter shows. With an EMPTY selection the result is empty (the
    /// filter then has nothing to scope to). Inferred constraints are dropped (same
    /// rationale as `constraints(in:)`). Order preserved.
    static func referencingSelection(_ constraints: [Constraint],
                                     selectionIDs: Set<EntityID>) -> [Constraint] {
        guard !selectionIDs.isEmpty else { return [] }
        return constraints.filter { c in
            !c.inferred && c.entityIDs.contains { selectionIDs.contains($0) }
        }
    }

    /// The constraints the panel should display, honoring the "selection only" toggle:
    /// the selection-referencing subset when `selectionOnly`, else every visible one.
    static func displayed(_ constraints: [Constraint],
                          selectionIDs: Set<EntityID>,
                          selectionOnly: Bool) -> [Constraint] {
        selectionOnly
            ? referencingSelection(constraints, selectionIDs: selectionIDs)
            : constraints.filter { !$0.inferred }
    }

    // MARK: Click-to-select target

    /// The set of entity ids a row's click-to-select should select — the DISTINCT entities
    /// the constraint references. Empty (so the caller no-ops) if it references none.
    static func selectionTarget(for c: Constraint) -> Set<EntityID> {
        Set(c.entityIDs)
    }

    // MARK: Row text

    /// The friendly, title-cased NAME of a constraint kind (paired with the glyph from
    /// `ConstraintGlyph.label`). Distinct from the glyph: the glyph is the terse CAD mark
    /// (∥, ⊥, ↔), this is the readable word the row labels it with.
    static func displayName(for kind: Constraint.Kind) -> String {
        switch kind {
        case .geometric(let g):
            switch g {
            case .coincident:    return "Coincident"
            case .horizontal:    return "Horizontal"
            case .vertical:      return "Vertical"
            case .parallel:      return "Parallel"
            case .perpendicular: return "Perpendicular"
            case .fix:           return "Fix"
            case .collinear:     return "Collinear"
            case .tangent:       return "Tangent"
            case .equal:         return "Equal"
            case .concentric:    return "Concentric"
            case .symmetric:     return "Symmetric"
            }
        case .dimensional(let d):
            switch d {
            case .distance:           return "Distance"
            case .radius:             return "Radius"
            case .horizontalDistance: return "Horizontal Distance"
            case .verticalDistance:   return "Vertical Distance"
            case .diameter:           return "Diameter"
            case .angle:              return "Angle"
            }
        }
    }

    /// A short reference DESCRIPTION for a row: the entity ids the constraint binds and
    /// (when it names more than one point of the same entity, or a non-`.start` point) the
    /// point roles — e.g. "#3 ↔ #7", "#5 start→end", "center of #4". Built purely from the
    /// constraint's `points` so a row reads "what does this hold?" without a live drawing.
    static func referenceDescription(for c: Constraint) -> String {
        let ids = c.entityIDs
        guard !ids.isEmpty else { return "—" }

        // A single entity: describe it by id, naming a SINGLE distinguishing point role
        // only when it isn't the whole entity. A horizontal/vertical/fix-line constraint
        // pins BOTH endpoints (start + end = the whole line) → just "#id"; a radius pins the
        // center → "center of #id"; a single endpoint fix → "end of #id".
        if ids.count == 1 {
            let distinct = orderedUnique(c.points.map { roleWord($0.point) })
            // The whole entity (both endpoints) or the canonical start point → just the id.
            if distinct == ["start"] || Set(distinct) == ["start", "end"] {
                return "#\(ids[0].rawValue)"
            }
            // A single distinguishing role (center / a lone endpoint) → name it.
            if distinct.count == 1 { return "\(distinct[0]) of #\(ids[0].rawValue)" }
            // An unusual multi-role mix → list them after the id.
            return "#\(ids[0].rawValue) " + distinct.joined(separator: "→")
        }

        // Multiple entities: list them joined by the kind's relational symbol.
        let joiner = pairJoiner(for: c.kind)
        return ids.map { "#\($0.rawValue)" }.joined(separator: " \(joiner) ")
    }

    /// The driven-VALUE description for a DIMENSIONAL constraint, or `nil` for a geometric
    /// one (no value). Shows the numeric value (formatted) and, when the constraint is
    /// PARAMETER-BOUND, the source expression in the form "width/2 = 11" (expression =
    /// last-evaluated value). `angle` is reported in DEGREES (the value is stored in
    /// radians) with a ° suffix; the others are unit-less magnitudes.
    static func valueDescription(for c: Constraint) -> String? {
        guard case .dimensional(let d) = c.kind else { return nil }
        let shown = (d == .angle) ? (c.value * 180.0 / .pi) : c.value
        let suffix = (d == .angle) ? "°" : ""
        let number = formatNumber(shown) + suffix
        if let expr = c.expression, !expr.isEmpty {
            return "\(expr) = \(number)"
        }
        return number
    }

    // MARK: - Small pure helpers

    /// The word for an `EntityPoint` role used in `referenceDescription`.
    private static func roleWord(_ p: EntityPoint) -> String {
        switch p {
        case .start:  return "start"
        case .end:    return "end"
        case .center: return "center"
        }
    }

    /// The relational symbol joining the entity ids in a multi-entity row, picked to read
    /// like the constraint's meaning (∥ for parallel, ⊥ for perpendicular, ↔ for a
    /// distance, ◎ for concentric, = for equal, • for coincident, — for collinear).
    private static func pairJoiner(for kind: Constraint.Kind) -> String {
        switch kind {
        case .geometric(.parallel):      return "∥"
        case .geometric(.perpendicular): return "⊥"
        case .geometric(.collinear):     return "—"
        case .geometric(.concentric):    return "◎"
        case .geometric(.equal):         return "="
        case .geometric(.coincident):    return "•"
        case .dimensional(.distance),
             .dimensional(.horizontalDistance),
             .dimensional(.verticalDistance): return "↔"
        case .dimensional(.angle):       return "∠"
        default:                         return "·"
        }
    }

    /// Order-preserving de-duplication of role words.
    private static func orderedUnique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in words where seen.insert(w).inserted { out.append(w) }
        return out
    }

    /// A compact numeric format (up to 3 fractional digits, trailing zeros trimmed) so a
    /// value reads "11" not "11.000" but "11.25" keeps its precision. Mirrors the
    /// `InspectorView` drawing-summary formatter.
    static func formatNumber(_ value: Double) -> String {
        let s = String(format: "%.3f", value)
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
