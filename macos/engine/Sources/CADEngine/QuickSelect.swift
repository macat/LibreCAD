//
//  QuickSelect.swift
//  CADEngine
//
//  "Quick Select" — a pure predicate that turns a property FILTER into the set of
//  matching entity ids, mirroring AutoCAD's QSELECT / LibreCAD's "Select by
//  attributes". This file is ANALYSIS ONLY: it walks the entity list and returns a
//  `Set<EntityID>`; it does NOT mutate the drawing or the `Selection`. The app /
//  wire-wave assigns the result (e.g. `selection.ids = QuickSelect.matches(...)`,
//  or unions/subtracts it into the live selection) and pushes the selection-flag
//  edit through its usual funnel.
//
//  ## The filter
//  A `QuickSelectFilter` is a conjunction (AND) of OPTIONAL criteria — a criterion
//  left `nil` is "don't care":
//   - `kinds`     : the entity's geometry category is in this set (line / circle /
//                   text / …). `nil` ⇒ any kind. Matched via the `QuickSelectKind`
//                   tag (a stable, associated-value-free projection of `EntityKind`
//                   defined here — a READ-ONLY switch local to this file, so it adds
//                   no `EntityKind` case and breaks no exhaustive switch elsewhere).
//   - `layer`     : the entity's `layer.name` equals this (DXF layer names are
//                   case-sensitive in our model, matching `LayerTable` lookups).
//   - `color`     : the entity's `pen.lineColor` equals this `PenColor` (so you can
//                   target `.byLayer` entities, or one explicit `RGBAColor`).
//   - `lineWidth` : the entity's `pen.lineWidth` equals this `PenLineWidth`.
//  An ALL-`nil` filter matches every entity (a "select all" — the caller decides
//  whether that is useful). `includeHidden` controls whether entities with a
//  cleared `.visible` flag are eligible (default: only visible, matching what a
//  user can see + pick).
//
//  Pure value logic over the entity list (no `@MainActor`, no GPU, no UI) so it
//  unit-tests without a live document; a `@MainActor` convenience that reads a
//  `CADDrawing` is provided for the app/wire-wave.
//
//  `static` members of a namespaced `enum` (CONVENTIONS.md §7: no module-scope
//  free functions in a fan-out target).
//
//  GPLv2-or-later (LibreCAD derivative). Quick-select semantics port AutoCAD
//  QSELECT / LibreCAD select-by-attributes.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Entity-kind tag (associated-value-free projection of EntityKind)

/// A stable, associated-value-free tag for each `EntityKind` case — the "what kind
/// of geometry" projection a quick-select / filter UI groups by. Defined HERE (not
/// in `Entity.swift`) so it stays additive: the `tag(of:)` switch below is the ONLY
/// place that maps `EntityKind → QuickSelectKind`, it is read-only, and it adds no
/// case to `EntityKind` itself (so it breaks none of the package's ~28 exhaustive
/// switches). `CaseIterable` so a UI can list every selectable kind.
public enum QuickSelectKind: String, Sendable, Hashable, CaseIterable, Codable {
    case point, line, circle, arc, polyline, ellipse, spline, splinePoints
    case text, mtext, hatch, solid, dimension, insert, xline, ray, leader, image

    /// The tag for an entity's kind. A read-only switch local to this file (no
    /// `EntityKind` case added; exhaustive so a NEW kind forces this one switch to
    /// be updated, which is correct — a new kind needs a tag to be quick-selectable).
    public static func tag(of kind: EntityKind) -> QuickSelectKind {
        switch kind {
        case .point:        return .point
        case .line:         return .line
        case .circle:       return .circle
        case .arc:          return .arc
        case .polyline:     return .polyline
        case .ellipse:      return .ellipse
        case .spline:       return .spline
        case .splinePoints: return .splinePoints
        case .text:         return .text
        case .mtext:        return .mtext
        case .hatch:        return .hatch
        case .solid:        return .solid
        case .dimension:    return .dimension
        case .insert:       return .insert
        case .xline:        return .xline
        case .ray:          return .ray
        case .leader:       return .leader
        // MLEADER is DEFERRED from Quick-Select v1: a multileader maps to the SAME
        // `.leader` tag (no new `QuickSelectKind` case) so it is still selectable
        // alongside leaders. A dedicated tag is a later wave's call.
        case .multileader:  return .leader
        case .image:        return .image
        }
    }
}

extension EntityRecord {
    /// This record's quick-select kind tag (convenience over `QuickSelectKind.tag`).
    public var quickSelectKind: QuickSelectKind { QuickSelectKind.tag(of: kind) }
}

// MARK: - The filter

/// A conjunction (AND) of OPTIONAL quick-select criteria — each `nil` field is
/// "don't care". A pure value type (`Sendable`) so it crosses actor boundaries and
/// snapshots cheaply. See the file header for the per-field semantics.
public struct QuickSelectFilter: Sendable, Hashable {
    /// Match only entities whose kind tag is in this set. `nil` ⇒ any kind. An
    /// EMPTY set matches NOTHING (an explicit "no kinds" — distinct from `nil`).
    public var kinds: Set<QuickSelectKind>?
    /// Match only entities on this layer (exact `layer.name`). `nil` ⇒ any layer.
    public var layer: String?
    /// Match only entities whose pen color equals this. `nil` ⇒ any color.
    public var color: PenColor?
    /// Match only entities whose pen line width equals this. `nil` ⇒ any width.
    public var lineWidth: PenLineWidth?
    /// Whether hidden entities (cleared `.visible` flag) are eligible. Default
    /// `false` (only what the user can see, matching `hitTest`/`windowSelect`).
    public var includeHidden: Bool

    public init(kinds: Set<QuickSelectKind>? = nil,
                layer: String? = nil,
                color: PenColor? = nil,
                lineWidth: PenLineWidth? = nil,
                includeHidden: Bool = false) {
        self.kinds = kinds
        self.layer = layer
        self.color = color
        self.lineWidth = lineWidth
        self.includeHidden = includeHidden
    }

    /// Whether every criterion is "don't care" (the filter, ignoring `includeHidden`,
    /// matches by kind/layer/color/width unconditionally). A convenience for a UI
    /// that wants to warn "this matches everything".
    public var matchesAllProperties: Bool {
        kinds == nil && layer == nil && color == nil && lineWidth == nil
    }

    /// Whether a single record satisfies this filter. Pure; no drawing needed —
    /// every criterion reads only the record's own attributes.
    public func matches(_ record: EntityRecord) -> Bool {
        if !includeHidden && !record.flags.contains(.visible) { return false }
        if let kinds, !kinds.contains(record.quickSelectKind) { return false }
        if let layer, record.layer.name != layer { return false }
        if let color, record.pen.lineColor != color { return false }
        if let lineWidth, record.pen.lineWidth != lineWidth { return false }
        return true
    }
}

// MARK: - QuickSelect — filter → id set

/// Pure quick-select queries (`static` members of a namespaced `enum`,
/// CONVENTIONS.md). The pure core takes the entity list; a `@MainActor`
/// convenience reads a `CADDrawing`. Nothing here mutates.
public enum QuickSelect {

    // MARK: Pure core (over an entity list)

    /// The ids of every entity in `entities` satisfying `filter`. Order-independent
    /// (a `Set`). An all-`nil` filter returns every (visible, unless `includeHidden`)
    /// entity; an empty `kinds` set returns the empty set.
    public static func matches(_ filter: QuickSelectFilter,
                               in entities: [EntityRecord]) -> Set<EntityID> {
        var result = Set<EntityID>()
        for e in entities where filter.matches(e) { result.insert(e.id) }
        return result
    }

    // MARK: Convenience filter builders (single-criterion)

    /// Ids of every entity of one kind (e.g. all circles). Convenience over a
    /// single-`kinds` filter.
    public static func ofKind(_ kind: QuickSelectKind,
                              in entities: [EntityRecord],
                              includeHidden: Bool = false) -> Set<EntityID> {
        matches(QuickSelectFilter(kinds: [kind], includeHidden: includeHidden),
                in: entities)
    }

    /// Ids of every entity on a given layer. Convenience over a single-`layer`
    /// filter (the "select all on layer X" affordance).
    public static func onLayer(_ name: String,
                               in entities: [EntityRecord],
                               includeHidden: Bool = false) -> Set<EntityID> {
        matches(QuickSelectFilter(layer: name, includeHidden: includeHidden),
                in: entities)
    }

    /// Ids of every entity whose pen color equals `color`. Convenience over a
    /// single-`color` filter.
    public static func withColor(_ color: PenColor,
                                 in entities: [EntityRecord],
                                 includeHidden: Bool = false) -> Set<EntityID> {
        matches(QuickSelectFilter(color: color, includeHidden: includeHidden),
                in: entities)
    }

    /// Ids of every entity whose pen line width equals `width`. Convenience over a
    /// single-`lineWidth` filter.
    public static func withLineWidth(_ width: PenLineWidth,
                                     in entities: [EntityRecord],
                                     includeHidden: Bool = false) -> Set<EntityID> {
        matches(QuickSelectFilter(lineWidth: width, includeHidden: includeHidden),
                in: entities)
    }

    // MARK: @MainActor convenience (reads a live CADDrawing)

    /// The ids matching `filter` in a live document (reads `drawing.entities` on
    /// the main actor and forwards to the pure core). Does NOT mutate the drawing
    /// or any `Selection` — the caller assigns the result (wire-wave).
    @MainActor
    public static func matches(_ filter: QuickSelectFilter,
                               in drawing: CADDrawing) -> Set<EntityID> {
        matches(filter, in: drawing.entities)
    }

    // MARK: Selection composition (pure, value-only)

    /// How a quick-select result combines with an existing selection (AutoCAD
    /// QSELECT's "Append to / Replace / Remove from" modes).
    public enum ApplyMode: String, Sendable, Hashable, CaseIterable, Codable {
        /// Discard the prior selection; the result becomes the whole selection.
        case replace
        /// Union the result into the prior selection.
        case add
        /// Subtract the result from the prior selection.
        case remove
        /// Keep only the entities in BOTH (intersect).
        case intersect
    }

    /// Combines a freshly-computed `result` with a `prior` selection per `mode`.
    /// Pure value op (the wire-wave calls this then assigns the returned set into
    /// `Selection.ids` + pushes the `.selected`-flag edit). Returns the new id set.
    public static func combine(prior: Set<EntityID>,
                               result: Set<EntityID>,
                               mode: ApplyMode) -> Set<EntityID> {
        switch mode {
        case .replace:   return result
        case .add:       return prior.union(result)
        case .remove:    return prior.subtracting(result)
        case .intersect: return prior.intersection(result)
        }
    }
}
