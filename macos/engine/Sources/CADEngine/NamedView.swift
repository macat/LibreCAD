//
//  NamedView.swift
//  CADEngine
//
//  Named Views (LibreCAD / AutoCAD parity): save the current viewport under a
//  name and restore it later. The model is a pure value type — a `NamedView`
//  captures the world-facing viewport state (center + scale + rotation), and a
//  `NamedViewTable` is an ordered, name-unique registry of them (add / get /
//  rename / delete), mirroring the engine's other tables (`LayerTable`,
//  `BlockTable`, `DimStyleTable`, `LayerStateTable`).
//
//  ## What a named view captures (and what it does NOT)
//  A `NamedView` stores the part of the `Viewport` that defines *what you are
//  looking at* in WORLD space — the world point at the view center (`center`) and
//  the zoom (`scale`, points per world unit) — plus a `rotation` (radians) for
//  AutoCAD parity. It deliberately does NOT store the view's `size` (the window's
//  point dimensions): restoring a view should re-frame the SAME world content in
//  whatever the window size is NOW, not resize the window. `apply(to:)` therefore
//  keeps the live viewport's `size` and overwrites only `center` + `scale`
//  (capture/restore is exact and round-trips, see `NamedViewTests`).
//
//  ## Rotation
//  The current `Viewport` has no rotation field (it is an axis-aligned pan/zoom
//  transform), so `rotation` is carried for forward-compatibility + AutoCAD-parity
//  shape: `capture` records `0` and `apply` ignores it until the viewport gains a
//  rotation term. Persisting it now means saved views won't need a migration when
//  rotation lands.
//
//  ## Persistence (this version)
//  The owning `NamedViewTable` is held as SESSION state on `CanvasModel` (the live
//  canvas), so save → restore works fully within a session. Cross-save (on-disk)
//  persistence + DXF/DWG VPORT/VIEW round-trip is a documented FOLLOW-UP: this
//  type is already `Codable` so wiring it into the document codec later is a small
//  additive step (it does not need a model change).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics

// MARK: - A single named view

/// One named view — a name plus the captured world-facing viewport state. Pure
/// value type (ADR-001), `Codable` so it can be persisted by the document path in
/// a later pass without a model change.
public struct NamedView: Sendable, Hashable, Codable {

    /// The view's name (case-insensitive uniqueness is enforced by the table). Not
    /// trimmed here — the table trims/validates on insert so the stored name is the
    /// canonical one the menu shows.
    public var name: String

    /// The world point mapped to the CENTER of the view when this was saved
    /// (`Viewport.center`).
    public var center: Vector

    /// The zoom (logical points per world unit) when this was saved
    /// (`Viewport.scale`). Always `> 0` — clamped on capture to a small positive
    /// floor so a restored view is always invertible.
    public var scale: Double

    /// The view rotation in radians (AutoCAD parity). The current `Viewport` has no
    /// rotation, so this is `0` on capture and ignored on apply (forward-compat).
    public var rotation: Double

    public init(name: String, center: Vector, scale: Double, rotation: Double = 0) {
        self.name = name
        self.center = center.valid ? center : Vector(0, 0)
        self.scale = Swift.max(scale, Viewport.minScale)
        self.rotation = rotation.isFinite ? rotation : 0
    }

    // MARK: Capture / apply (pure viewport math — the testable core)

    /// Captures the world-facing state of `viewport` under `name`. Records the
    /// center + scale (+ rotation `0`, the viewport has none yet); the view `size`
    /// is intentionally NOT captured (a restore re-frames into the current window
    /// size — see the type doc).
    public static func capture(_ viewport: Viewport, name: String) -> NamedView {
        NamedView(name: name,
                  center: viewport.center,
                  scale: viewport.scale,
                  rotation: 0)
    }

    /// Returns a COPY of `viewport` with this named view's world-facing state
    /// applied: `center` + `scale` are restored; the view's `size` is KEPT (so the
    /// restore fits the current window). Pure — the input is untouched; the caller
    /// assigns the result. `rotation` is carried in the model but not applied (the
    /// viewport has no rotation term yet).
    public func apply(to viewport: Viewport) -> Viewport {
        Viewport(scale: scale, center: center, size: viewport.size)
    }
}

// MARK: - The ordered, name-unique table

/// The drawing's named-view registry — an ORDERED, name-UNIQUE table of
/// `NamedView`s (the value-type sibling of `LayerTable` / `BlockTable` /
/// `DimStyleTable`). Names are unique case-insensitively (matching AutoCAD table
/// semantics); insertion order is preserved so the menu lists views in the order
/// they were saved. Pure value type so it snapshots cheaply (for value-snapshot
/// undo, ADR-002) and `Codable` for the later document round-trip.
public struct NamedViewTable: Sendable, Hashable, Codable {

    /// The saved views, in stable insertion order.
    public private(set) var views: [NamedView]

    public init(views: [NamedView] = []) {
        self.views = views
    }

    // MARK: Reads

    public var count: Int { views.count }
    public var isEmpty: Bool { views.isEmpty }

    /// The saved names, in display (insertion) order.
    public var names: [String] { views.map(\.name) }

    /// The view matching `name` (case-insensitive), or `nil`.
    public func view(named name: String) -> NamedView? {
        views.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a view with `name` (case-insensitive) is present.
    public func contains(_ name: String) -> Bool { view(named: name) != nil }

    // MARK: Mutations (each returns whether it changed the table)

    /// Adds (or REPLACES, on a case-insensitive name clash) a named view. A blank
    /// name (empty after trimming) is rejected (returns `false`). On a clash the
    /// EXISTING entry is updated IN PLACE (its order is preserved, AutoCAD "save
    /// over an existing view"); otherwise the view is appended. The stored name is
    /// the trimmed form. Returns `true` if the table changed.
    @discardableResult
    public mutating func upsert(_ view: NamedView) -> Bool {
        let trimmed = view.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var v = view
        v.name = trimmed
        if let i = views.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            guard views[i] != v else { return false }   // no-op replace
            views[i] = v
        } else {
            views.append(v)
        }
        return true
    }

    /// Removes a named view by name (case-insensitive). No-op (returns `false`) if
    /// absent.
    @discardableResult
    public mutating func remove(named name: String) -> Bool {
        let before = views.count
        views.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return views.count != before
    }

    /// Renames a view, keeping its position + captured state. Fails (returns
    /// `false`) if `oldName` is absent, `newName` is blank, or `newName` already
    /// names a DIFFERENT view (a rename to the same name, case aside, just updates
    /// the stored casing). The stored new name is the trimmed form.
    @discardableResult
    public mutating func rename(_ oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let i = views.firstIndex(where: {
            $0.name.caseInsensitiveCompare(oldName) == .orderedSame
        }) else { return false }
        // Reject a clash with a DIFFERENT existing view (but allow a casing-only
        // self-rename of the same entry).
        if let j = views.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }), j != i {
            return false
        }
        guard views[i].name != trimmed else { return false }   // no-op
        views[i].name = trimmed
        return true
    }
}
