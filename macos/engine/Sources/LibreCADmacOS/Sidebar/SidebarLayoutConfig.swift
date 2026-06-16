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
import CADEngine

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
    /// The Parts Library panel (a chosen on-disk folder of `.dxf` symbols, imported
    /// as blocks on double-click / drag-to-canvas). Newly added — `reconciled` appends
    /// it to any stored config from an older build (visible + expanded by default).
    case partsLibrary
    /// The Quick Select panel (select-by-attributes: filter by kind / layer / color /
    /// width, with replace / add / remove / intersect modes — AutoCAD's QSELECT / the
    /// "Select Similar" affordance). Newly added — `reconciled` appends it to any stored
    /// config from an older build. Defaults to HIDDEN (a power-user panel surfaced via the
    /// ⋯ Customize menu), so it does not crowd a fresh sidebar.
    case quickSelect

    /// The default header title for this panel id (used when constructing a descriptor
    /// and as a stable, localizable-later label).
    var defaultTitle: String {
        switch self {
        case .layers:       return "Layers"
        case .layerStates:  return "Layer States"
        case .blocks:       return "Blocks"
        case .partsLibrary: return "Parts Library"
        case .quickSelect:  return "Quick Select"
        }
    }

    /// The default SF Symbol shown in this panel's header.
    var defaultSymbol: String {
        switch self {
        case .layers:       return "square.3.layers.3d"
        case .layerStates:  return "rectangle.stack"
        case .blocks:       return "square.on.square"
        case .partsLibrary: return "books.vertical"
        case .quickSelect:  return "line.3.horizontal.decrease.circle"
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

    /// Panels that start HIDDEN on a fresh install (and when a newly-added id of this set
    /// is absorbed into an older stored config). These are power-user panels surfaced via
    /// the ⋯ Customize menu rather than crowding a default sidebar — currently just Quick
    /// Select. A panel NOT in this set defaults to visible + expanded (the established
    /// behavior for every prior panel).
    static let defaultHiddenIDs: Set<SidebarPanelID> = [.quickSelect]

    /// The built-in default layout: every panel in its canonical declaration order, all
    /// expanded; visible EXCEPT the `defaultHiddenIDs` power-user panels (which start
    /// hidden, reachable via the ⋯ Customize menu). Used on a fresh install (no stored
    /// config) and as the reconciliation baseline.
    static var `default`: SidebarLayoutConfig {
        SidebarLayoutConfig(order: SidebarPanelID.allCases,
                            collapsed: [],
                            hidden: defaultHiddenIDs)
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
    ///      EXPANDED and (for most panels) VISIBLE — EXCEPT a newly-appended id that is in
    ///      `defaultHiddenIDs` (e.g. Quick Select), which starts HIDDEN so it joins the ⋯
    ///      Customize menu rather than crowding an existing user's sidebar. An id the
    ///      stored config ALREADY knew keeps the user's own hidden choice (we only force
    ///      the default-hidden flag for ids the stored config had never seen).
    ///   3. ZERO-VISIBLE FLOOR: if the reconciled config would hide EVERY panel while
    ///      `order` is non-empty, the FIRST panel in `order` is forced visible — so the
    ///      result ALWAYS has ≥1 visible panel. The Customize (⋯) menu rides in the first
    ///      visible panel's header (`SidebarPanelStack`), so an all-hidden state (reachable
    ///      via an externally-edited `@AppStorage` config, or a future build that marks more
    ///      panels default-hidden) would otherwise orphan that menu — leaving no way to
    ///      re-show anything. The live UI guards interactive hides separately (the last
    ///      visible panel's toggle is disabled); this floor backstops the PERSISTED path.
    func reconciled(withAvailable available: [SidebarPanelID]) -> SidebarLayoutConfig {
        let availableSet = Set(available)

        // 1. Stored order, filtered to available + dedup'd, preserving sequence.
        var seen = Set<SidebarPanelID>()
        var newOrder: [SidebarPanelID] = []
        for id in order where availableSet.contains(id) && !seen.contains(id) {
            newOrder.append(id)
            seen.insert(id)
        }
        // The ids the stored config already knew (after filtering to available) — used to
        // tell a NEWLY-appended id from one the user already had a choice about.
        let storedKnown = seen
        // Append any available id the stored order didn't carry (new panels), in the
        // caller's `available` order.
        for id in available where !seen.contains(id) {
            newOrder.append(id)
            seen.insert(id)
        }

        let orderSet = Set(newOrder)
        // Newly-appended ids that default to hidden (a power-user panel the stored config
        // had never seen) join the hidden set so they surface only via ⋯ Customize.
        let newlyDefaultHidden = orderSet
            .subtracting(storedKnown)
            .intersection(SidebarLayoutConfig.defaultHiddenIDs)
        var newHidden = hidden.intersection(orderSet).union(newlyDefaultHidden)

        // ZERO-VISIBLE FLOOR: never hand back a config that hides every panel while there
        // ARE panels to show. If the hidden set covers the whole order, un-hide the first
        // panel so there is ALWAYS ≥1 visible panel to carry the Customize (⋯) menu and
        // keep the sidebar recoverable. (When `order` is empty there's nothing to floor.)
        if let first = newOrder.first, newHidden.count == newOrder.count {
            newHidden.remove(first)
        }

        return SidebarLayoutConfig(
            order: newOrder,
            collapsed: collapsed.intersection(orderSet),
            hidden: newHidden
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

// MARK: - Block-file menu wiring (pure helpers — SwiftUI-free, unit-testable)

/// Pure, SwiftUI-free helpers backing the Blocks file menus ("Insert Block from File…" /
/// "Save Block to File…"). They take only engine value types (`CADDrawing` reads,
/// `EntityID`s) so they unit-test headlessly through the established `_Shared*.swift`
/// symlink (the test target depends only on CADEngine). The `NSOpenPanel`/`NSSavePanel`
/// and the actual import/export calls stay in the View layer (`ContentView`); these only
/// decide WHICH block the menu-bar "Save Block to File…" item targets.
enum BlockFileMenuWiring {

    /// The block the menu-bar "Save Block to File…" item should target, given the current
    /// `selectionIDs` and the `drawing`: the block of the FIRST selected `.insert` whose
    /// referenced block still exists (so selecting an inserted block then using the menu
    /// saves that one), else the FIRST defined block (a usable default with no selection).
    /// `nil` — which DISABLES the menu item — when the drawing defines no blocks. The
    /// per-row Blocks-panel "Save Block to File…" names its block explicitly and does NOT
    /// use this; this only backs the single menu-bar item.
    @MainActor
    static func saveTargetName(selectionIDs: some Sequence<EntityID>,
                               in drawing: CADDrawing) -> String? {
        for id in selectionIDs {
            if case .insert(let data)? = drawing.entity(id)?.kind,
               drawing.blocks.contains(data.blockName) {
                return data.blockName
            }
        }
        return drawing.blocks.blocks.first?.name
    }
}
