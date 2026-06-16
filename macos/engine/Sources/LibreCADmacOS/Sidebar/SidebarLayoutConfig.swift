//
//  SidebarLayoutConfig.swift
//  LibreCADmacOS
//
//  The PURE, value-type configuration model behind the rearrangeable left-sidebar
//  panel stack (`SidebarPanelStack`). It carries which panels exist, in what ORDER,
//  which are COLLAPSED, and which are HIDDEN — and nothing else. It imports no
//  SwiftUI: it is plain Codable Swift so it can be encoded into a single
//  `@AppStorage` string for cross-launch persistence AND unit-tested headlessly via
//  the established `_Shared*.swift` symlink convention (the test target only depends
//  on CADEngine, so the testable logic must be SwiftUI-free).
//
//  Persistence pattern mirrors `ContentView`'s `commandBar.mru` / `toolbar.pinnedTools`
//  stores: keep a primitive `String` in `@AppStorage`, encode/decode here. The string
//  is JSON (a tiny stable shape), so adding a field later is forward-compatible.
//
//  EXTENSIBILITY: adding a new panel (e.g. a Parts Library) is a ONE-LINER — add a
//  `SidebarPanelID` case (and a `defaultTitle`/`defaultSymbol`), then register a
//  `SidebarPanel` descriptor at the call site. `reconciled(withAvailable:)` makes a
//  stored config from an older build gracefully absorb the new id (it appears at the
//  end, visible + expanded) and drop any id that no longer exists.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Panel identity

/// The stable identity of a left-sidebar panel. The raw value is the persistence key
/// (stored in the `@AppStorage` JSON), so a case's `rawValue` must never change once
/// shipped — but cases may be freely ADDED (absorbed by `reconciled`) or REMOVED
/// (ignored by `reconciled`). `CaseIterable` gives the canonical "what panels exist
/// in THIS build" set used to reconcile a stored config.
enum SidebarPanelID: String, Codable, CaseIterable, Hashable, Sendable {
    /// The Layers panel (add/remove/freeze/lock + the live layer list).
    case layers
    /// The Layer States panel (named snapshots of all layer flags).
    case layerStates
    /// The Blocks panel (block definitions: insert / edit / rename / delete + drag).
    case blocks

    /// The default header title for this panel id (used when constructing a descriptor
    /// and as a stable, localizable-later label).
    var defaultTitle: String {
        switch self {
        case .layers:      return "Layers"
        case .layerStates: return "Layer States"
        case .blocks:      return "Blocks"
        }
    }

    /// The default SF Symbol shown in this panel's header.
    var defaultSymbol: String {
        switch self {
        case .layers:      return "square.3.layers.3d"
        case .layerStates: return "rectangle.stack"
        case .blocks:      return "square.on.square"
        }
    }
}

// MARK: - The persisted layout configuration

/// The complete, persisted state of the sidebar panel stack: the panel ORDER, the set
/// of COLLAPSED panels, and the set of HIDDEN panels. A pure value type — encode it to
/// a string for `@AppStorage`, decode it back on launch, and mutate it with the pure
/// helpers below (each returns a NEW value so SwiftUI sees a clean change).
struct SidebarLayoutConfig: Codable, Equatable, Sendable {
    /// The panels in display order (top → bottom). May contain a SUBSET of the
    /// available ids after `reconciled` runs only if cases were removed; newly-added
    /// ids are appended. Never contains duplicates (the mutators preserve that).
    var order: [SidebarPanelID]
    /// The panels whose BODY is collapsed (header still shown). A subset of `order`.
    var collapsed: Set<SidebarPanelID>
    /// The panels HIDDEN entirely (not rendered at all; toggled back on via the
    /// "Customize…" menu). A subset of `order` — a hidden panel keeps its slot in the
    /// order so re-showing it restores its place.
    var hidden: Set<SidebarPanelID>

    init(order: [SidebarPanelID],
         collapsed: Set<SidebarPanelID> = [],
         hidden: Set<SidebarPanelID> = []) {
        self.order = order
        self.collapsed = collapsed
        self.hidden = hidden
    }

    // MARK: Defaults

    /// The built-in default layout: every panel in its canonical declaration order,
    /// all expanded and visible. Used on a fresh install (no stored config) and as the
    /// reconciliation baseline.
    static var `default`: SidebarLayoutConfig {
        SidebarLayoutConfig(order: SidebarPanelID.allCases, collapsed: [], hidden: [])
    }

    // MARK: Persistence (single @AppStorage string)

    /// Encodes this config to a compact JSON string for `@AppStorage`. Returns `""` on
    /// the (practically impossible) encode failure, which `decode` then reads back as
    /// the default — so persistence can never crash or wedge the sidebar.
    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Decodes a config from an `@AppStorage` string, then RECONCILES it against the
    /// panels available in THIS build so the result is always coherent:
    ///   • an empty / malformed / unknown-shape string → the default layout;
    ///   • a stored id that no longer exists in this build → dropped;
    ///   • an available id missing from the stored config → appended (visible, expanded).
    /// Pass `available` (defaults to `allCases`) so tests can pin the roster.
    static func decoded(from raw: String,
                        available: [SidebarPanelID] = SidebarPanelID.allCases)
        -> SidebarLayoutConfig {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(SidebarLayoutConfig.self, from: data) else {
            return SidebarLayoutConfig.default.reconciled(withAvailable: available)
        }
        return stored.reconciled(withAvailable: available)
    }

    // MARK: Reconciliation (forward/backward-compatible roster changes)

    /// Returns a copy reconciled against the `available` panel roster:
    ///   1. `order` keeps only available ids, in their stored sequence (dedup'd), then
    ///      APPENDS any available id not already present (a newly-added panel shows up
    ///      at the end of the stack, in `available` order).
    ///   2. `collapsed` / `hidden` are intersected with the resulting `order`, so a
    ///      removed id never lingers in a flag set, and a newly-added panel starts
    ///      EXPANDED and VISIBLE (a sensible default — the user discovers it).
    func reconciled(withAvailable available: [SidebarPanelID]) -> SidebarLayoutConfig {
        let availableSet = Set(available)

        // 1. Stored order, filtered to available + dedup'd, preserving sequence.
        var seen = Set<SidebarPanelID>()
        var newOrder: [SidebarPanelID] = []
        for id in order where availableSet.contains(id) && !seen.contains(id) {
            newOrder.append(id)
            seen.insert(id)
        }
        // Append any available id the stored order didn't carry (new panels), in the
        // caller's `available` order.
        for id in available where !seen.contains(id) {
            newOrder.append(id)
            seen.insert(id)
        }

        let orderSet = Set(newOrder)
        return SidebarLayoutConfig(
            order: newOrder,
            collapsed: collapsed.intersection(orderSet),
            hidden: hidden.intersection(orderSet)
        )
    }

    // MARK: Pure mutators (each returns a new value)

    /// The visible panels in order (drops hidden ones) — what the stack actually renders.
    var visibleOrder: [SidebarPanelID] {
        order.filter { !hidden.contains($0) }
    }

    /// Whether `id` is collapsed (body hidden, header shown).
    func isCollapsed(_ id: SidebarPanelID) -> Bool { collapsed.contains(id) }

    /// Whether `id` is hidden entirely (not rendered).
    func isHidden(_ id: SidebarPanelID) -> Bool { hidden.contains(id) }

    /// Returns a copy with `id`'s collapsed state flipped.
    func togglingCollapsed(_ id: SidebarPanelID) -> SidebarLayoutConfig {
        var copy = self
        if copy.collapsed.contains(id) { copy.collapsed.remove(id) }
        else { copy.collapsed.insert(id) }
        return copy
    }

    /// Returns a copy with `id`'s hidden state flipped. Hiding does NOT remove the id
    /// from `order` (so re-showing restores its slot).
    func togglingHidden(_ id: SidebarPanelID) -> SidebarLayoutConfig {
        var copy = self
        if copy.hidden.contains(id) { copy.hidden.remove(id) }
        else { copy.hidden.insert(id) }
        return copy
    }

    /// Returns a copy with `id` explicitly shown/hidden.
    func settingHidden(_ id: SidebarPanelID, _ isHidden: Bool) -> SidebarLayoutConfig {
        var copy = self
        if isHidden { copy.hidden.insert(id) } else { copy.hidden.remove(id) }
        return copy
    }

    /// Returns a copy with EVERY panel shown (`false`) or hidden (`true`). Hiding all
    /// hides only ids present in `order` (so the set stays a subset of `order`); the
    /// "Show All" affordance uses the `false` form to reset visibility.
    func settingAllHidden(_ isHidden: Bool) -> SidebarLayoutConfig {
        var copy = self
        copy.hidden = isHidden ? Set(order) : []
        return copy
    }

    /// Returns a copy with the panels at `source` offsets moved before `destination`,
    /// using the exact SwiftUI `onMove`/`move(fromOffsets:toOffset:)` semantics so a
    /// drag-to-reorder over the VISIBLE list maps cleanly onto the FULL order.
    ///
    /// `source`/`destination` index into `visibleOrder` (what the user drags). Hidden
    /// panels keep their relative positions around the moved block: we reorder the
    /// visible slice, then splice it back into the full order at the original visible
    /// slots — so hidden panels are never disturbed.
    func movingVisible(fromOffsets source: IndexSet, toOffset destination: Int)
        -> SidebarLayoutConfig {
        var visible = visibleOrder
        guard !visible.isEmpty else { return self }
        visible.move(fromOffsets: source, toOffset: destination)

        // Re-weave: walk the original order; each VISIBLE slot draws the next element
        // from the reordered visible list, each HIDDEN slot stays put.
        var copy = self
        var vIterator = visible.makeIterator()
        copy.order = order.map { id in
            hidden.contains(id) ? id : (vIterator.next() ?? id)
        }
        return copy
    }
}
