//
//  SidebarLayoutConfigTests.swift
//  CADEngineTests
//
//  Covers the PURE configuration model behind the rearrangeable left-sidebar panel
//  stack (`SidebarLayoutConfig` / `SidebarPanelID`). The SwiftUI container
//  (`SidebarPanelStack`) and the live `LayersSidebar` are not headlessly testable, so
//  this exercises the value logic they depend on: encode/decode round-trip, reorder,
//  show/hide, collapse, the default order when there is no stored config, graceful
//  handling of an unknown/removed panel id in a stored config, and a newly-added panel
//  id appearing with a sensible default.
//
//  The config type lives in the app module; it imports only Foundation, so it is reached
//  here through the established `_SharedSidebarLayoutConfig.swift` SYMLINK (the test
//  target depends only on CADEngine).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine   // not strictly needed (config is app-module), but keeps
                             // the import style uniform with sibling suites.

@Suite("sidebar panel layout config")
struct SidebarLayoutConfigTests {

    // MARK: Defaults

    @Test("the default layout carries every panel, in declaration order, all expanded; only the power-user panels start hidden")
    func defaultLayout() {
        let cfg = SidebarLayoutConfig.default
        #expect(cfg.order == SidebarPanelID.allCases)
        #expect(cfg.collapsed.isEmpty)
        // Power-user panels (currently just Quick Select) start hidden; everything else
        // is visible. The hidden set is exactly `defaultHiddenIDs`.
        #expect(cfg.hidden == SidebarLayoutConfig.defaultHiddenIDs)
        #expect(cfg.visibleOrder
            == SidebarPanelID.allCases.filter { !SidebarLayoutConfig.defaultHiddenIDs.contains($0) })
    }

    @Test("an empty stored string decodes to the default layout (fresh install)")
    func emptyStringDecodesToDefault() {
        let cfg = SidebarLayoutConfig.decoded(from: "")
        #expect(cfg == SidebarLayoutConfig.default)
    }

    @Test("a malformed / non-JSON stored string decodes to the default layout (never crashes)")
    func malformedStringDecodesToDefault() {
        for junk in ["{not json", "12345", "[\"layers\"", "\u{0000}\u{0001}"] {
            let cfg = SidebarLayoutConfig.decoded(from: junk)
            #expect(cfg == SidebarLayoutConfig.default)
        }
    }

    // MARK: Encode / decode round-trip

    @Test("a config round-trips through encode → decode unchanged")
    func roundTrip() {
        // A config carrying EVERY live panel id (in reversed declaration order) so the
        // decode's reconciliation is a no-op and the test measures pure encode/decode
        // fidelity, independent of how many panel ids the build defines.
        let original = SidebarLayoutConfig(
            order: SidebarPanelID.allCases.reversed(),
            collapsed: [.layerStates],
            hidden: [.blocks]
        )
        let restored = SidebarLayoutConfig.decoded(from: original.encoded())
        #expect(restored.order == original.order)
        #expect(restored.collapsed == original.collapsed)
        #expect(restored.hidden == original.hidden)
        #expect(restored == original)
    }

    @Test("the encoded form is non-empty JSON text")
    func encodedIsJSON() {
        let encoded = SidebarLayoutConfig.default.encoded()
        #expect(!encoded.isEmpty)
        #expect(encoded.contains("layers"))
        // It is valid JSON (parses without error).
        #expect((try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) != nil)
    }

    // MARK: Reorder

    @Test("reordering the visible list moves a panel and persists through a round-trip")
    func reorder() {
        // A fixed three-panel config (independent of how many panels the build defines)
        // so the assertion stays stable as new panel ids are added. Move layers to the end.
        let base = SidebarLayoutConfig(order: [.layers, .layerStates, .blocks])
        let moved = base.movingVisible(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(moved.order == [.layerStates, .blocks, .layers])
        // Survives persistence (decode reconciles against the live roster — any panel id
        // not in `base` is appended, so check the moved trio keeps its relative order).
        let restored = SidebarLayoutConfig.decoded(from: moved.encoded())
        #expect(restored.order.prefix(3) == [.layerStates, .blocks, .layers])
    }

    @Test("reordering the VISIBLE list leaves hidden panels in their original slots")
    func reorderKeepsHiddenSlots() {
        // layerStates is hidden, so visibleOrder = [layers, blocks]; swap those two.
        let cfg = SidebarLayoutConfig(
            order: [.layers, .layerStates, .blocks],
            hidden: [.layerStates]
        )
        #expect(cfg.visibleOrder == [.layers, .blocks])
        let moved = cfg.movingVisible(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        // The two visible panels swapped; the hidden one kept its middle slot.
        #expect(moved.order == [.blocks, .layerStates, .layers])
        #expect(moved.hidden == [.layerStates])
        #expect(moved.visibleOrder == [.blocks, .layers])
    }

    @Test("moving with an empty visible list is a no-op")
    func reorderEmptyVisibleIsNoOp() {
        let cfg = SidebarLayoutConfig(
            order: [.layers, .layerStates, .blocks],
            hidden: [.layers, .layerStates, .blocks]   // everything hidden
        )
        let moved = cfg.movingVisible(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(moved == cfg)
    }

    // MARK: Show / hide

    @Test("toggling hidden flips visibility and drops the panel from the visible order")
    func toggleHidden() {
        // Start from a fully-visible config (the default hides the power-user panels), so
        // this test measures only the toggle behavior for `.blocks`.
        var cfg = SidebarLayoutConfig.default.settingAllHidden(false)
        #expect(!cfg.isHidden(.blocks))
        cfg = cfg.togglingHidden(.blocks)
        #expect(cfg.isHidden(.blocks))
        // The hidden panel drops from the visible order; every OTHER panel stays visible
        // (robust to how many panels the build defines — derived from `allCases`).
        #expect(cfg.visibleOrder == SidebarPanelID.allCases.filter { $0 != .blocks })
        // Hiding keeps the slot in `order` so re-showing restores its place.
        #expect(cfg.order == SidebarPanelID.allCases)
        cfg = cfg.togglingHidden(.blocks)
        #expect(!cfg.isHidden(.blocks))
        #expect(cfg.visibleOrder == SidebarPanelID.allCases)
    }

    @Test("settingHidden explicitly shows / hides, and settingAllHidden resets visibility")
    func settingHidden() {
        var cfg = SidebarLayoutConfig.default.settingHidden(.layers, true)
        #expect(cfg.isHidden(.layers))
        cfg = cfg.settingHidden(.layers, false)
        #expect(!cfg.isHidden(.layers))

        let allHidden = SidebarLayoutConfig.default.settingAllHidden(true)
        #expect(allHidden.hidden == Set(SidebarPanelID.allCases))
        #expect(allHidden.visibleOrder.isEmpty)
        let allShown = allHidden.settingAllHidden(false)
        #expect(allShown.hidden.isEmpty)
        #expect(allShown.visibleOrder == allShown.order)
    }

    // MARK: Collapse

    @Test("toggling collapse flips a single panel's collapsed flag")
    func toggleCollapse() {
        var cfg = SidebarLayoutConfig.default
        #expect(!cfg.isCollapsed(.layers))
        cfg = cfg.togglingCollapsed(.layers)
        #expect(cfg.isCollapsed(.layers))
        #expect(!cfg.isCollapsed(.blocks))   // others untouched
        cfg = cfg.togglingCollapsed(.layers)
        #expect(!cfg.isCollapsed(.layers))
    }

    // MARK: Reconciliation — unknown / removed ids

    @Test("an unknown / removed panel id in a stored config is ignored gracefully")
    func unknownStoredIdDropped() {
        // Simulate a stored config from a build that still had `.blocks` but the current
        // build only offers [.layers, .layerStates] (an id was removed).
        let stored = SidebarLayoutConfig(
            order: [.blocks, .layers, .layerStates],
            collapsed: [.blocks],
            hidden: [.blocks]
        )
        let available: [SidebarPanelID] = [.layers, .layerStates]
        let reconciled = stored.reconciled(withAvailable: available)
        // The removed id is gone from the order AND every flag set.
        #expect(reconciled.order == [.layers, .layerStates])
        #expect(!reconciled.collapsed.contains(.blocks))
        #expect(!reconciled.hidden.contains(.blocks))
        #expect(reconciled.collapsed.isEmpty)
        #expect(reconciled.hidden.isEmpty)
    }

    @Test("decoding a config whose JSON carries a removed id drops it via reconciliation")
    func decodeDropsRemovedId() {
        let stored = SidebarLayoutConfig(order: [.blocks, .layers, .layerStates])
        let decoded = SidebarLayoutConfig.decoded(
            from: stored.encoded(),
            available: [.layers, .layerStates]
        )
        #expect(decoded.order == [.layers, .layerStates])
    }

    // MARK: Reconciliation — newly-added ids

    @Test("a newly-added panel id (not in the stored config) appears at the end, visible & expanded")
    func newIdAppended() {
        // Simulate a stored config from an OLD build that only knew [.layers,
        // .layerStates]; the current build adds `.blocks`.
        let stored = SidebarLayoutConfig(
            order: [.layerStates, .layers],   // user had reordered the two
            collapsed: [.layerStates]
        )
        let available: [SidebarPanelID] = [.layers, .layerStates, .blocks]
        let reconciled = stored.reconciled(withAvailable: available)
        // Stored order preserved, new id appended at the end.
        #expect(reconciled.order == [.layerStates, .layers, .blocks])
        // The new panel is visible and expanded (a sensible default).
        #expect(!reconciled.isHidden(.blocks))
        #expect(!reconciled.isCollapsed(.blocks))
        // The user's existing collapse choice is preserved.
        #expect(reconciled.isCollapsed(.layerStates))
    }

    @Test("reconciliation dedups a stored order that somehow carries duplicates")
    func reconcileDedups() {
        let stored = SidebarLayoutConfig(order: [.layers, .layers, .blocks, .blocks])
        // Pin the roster (independent of the live panel count) so the assertion is stable.
        let reconciled = stored.reconciled(withAvailable: [.layers, .layerStates, .blocks])
        // No duplicates; missing `.layerStates` appended.
        #expect(reconciled.order == [.layers, .blocks, .layerStates])
        #expect(Set(reconciled.order).count == reconciled.order.count)
    }

    // MARK: Reconciliation — the newly-added .partsLibrary panel

    @Test("a stored config WITHOUT .partsLibrary absorbs it (appended, visible & expanded)")
    func partsLibraryAppendedToOlderConfig() {
        // A config saved by a build that predates the Parts Library panel (only the
        // original three ids). Reconciling against the live roster (which now includes
        // .partsLibrary) appends it without disturbing the stored order/flags.
        let stored = SidebarLayoutConfig(
            order: [.blocks, .layers, .layerStates],   // user had reordered
            collapsed: [.blocks],
            hidden: [.layers]
        )
        #expect(!stored.order.contains(.partsLibrary))
        // Pin the roster so the "appended at the end" assertion stays stable as later
        // panels (e.g. Quick Select) are added after Parts Library in `allCases`.
        let roster: [SidebarPanelID] = [.layers, .layerStates, .blocks, .partsLibrary]
        let reconciled = stored.reconciled(withAvailable: roster)
        // The new panel appears (at the end, in the roster's order), visible + expanded.
        #expect(reconciled.order.contains(.partsLibrary))
        #expect(reconciled.order.last == .partsLibrary)
        #expect(!reconciled.isHidden(.partsLibrary))
        #expect(!reconciled.isCollapsed(.partsLibrary))
        // The user's prior order + flags are preserved for the panels they had.
        #expect(reconciled.order.prefix(3) == [.blocks, .layers, .layerStates])
        #expect(reconciled.isCollapsed(.blocks))
        #expect(reconciled.isHidden(.layers))
        // The default layout already lists it (a fresh install sees the panel).
        #expect(SidebarLayoutConfig.default.order.contains(.partsLibrary))
        // It round-trips through encode/decode like any panel id.
        let restored = SidebarLayoutConfig.decoded(from: reconciled.encoded())
        #expect(restored.order.contains(.partsLibrary))
    }

    @Test("a stored config carrying an UNKNOWN id (and missing .partsLibrary) is reconciled cleanly")
    func unknownIdIgnoredWhileNewPanelAppears() {
        // A stored config from a HYPOTHETICAL build with an id this build no longer
        // offers — modeled by reconciling against a roster that EXCLUDES one stored id
        // while INCLUDING the new .partsLibrary. The unknown id drops; .partsLibrary
        // appears; the surviving ids keep their order.
        let stored = SidebarLayoutConfig(
            order: [.layers, .layerStates, .blocks],
            collapsed: [.blocks],
            hidden: [.blocks]
        )
        // Available roster: drop `.blocks` (simulating a removed/unknown stored id), add
        // `.partsLibrary` (the new panel).
        let available: [SidebarPanelID] = [.layers, .layerStates, .partsLibrary]
        let reconciled = stored.reconciled(withAvailable: available)
        // The dropped id is gone from the order AND every flag set.
        #expect(!reconciled.order.contains(.blocks))
        #expect(!reconciled.collapsed.contains(.blocks))
        #expect(!reconciled.hidden.contains(.blocks))
        // The surviving stored ids keep their order; the new panel is appended.
        #expect(reconciled.order == [.layers, .layerStates, .partsLibrary])
        #expect(!reconciled.isHidden(.partsLibrary))
    }

    @Test(".partsLibrary has a non-empty default title and SF-Symbol")
    func partsLibraryMetadata() {
        #expect(SidebarPanelID.partsLibrary.defaultTitle == "Parts Library")
        #expect(!SidebarPanelID.partsLibrary.defaultSymbol.isEmpty)
    }

    // MARK: Reconciliation — the newly-added .quickSelect panel (defaults HIDDEN)

    @Test("a stored config WITHOUT .quickSelect absorbs it (appended) but starts HIDDEN")
    func quickSelectAppendedToOlderConfigStartsHidden() {
        // A config saved by a build that predates the Quick Select panel. Reconciling
        // against the live roster appends it WITHOUT disturbing the stored order/flags,
        // and — because it is a default-hidden power-user panel the stored config never
        // knew — it lands in the hidden set (surfaced only via ⋯ Customize).
        let stored = SidebarLayoutConfig(
            order: [.blocks, .layers, .layerStates],
            collapsed: [.blocks],
            hidden: [.layers]
        )
        #expect(!stored.order.contains(.quickSelect))
        let reconciled = stored.reconciled(withAvailable: SidebarPanelID.allCases)
        // The new panel appears in the order, but HIDDEN (not in the visible order).
        #expect(reconciled.order.contains(.quickSelect))
        #expect(reconciled.isHidden(.quickSelect))
        #expect(!reconciled.visibleOrder.contains(.quickSelect))
        #expect(!reconciled.isCollapsed(.quickSelect))
        // The user's prior order + flags are preserved for the panels they had.
        #expect(reconciled.order.prefix(3) == [.blocks, .layers, .layerStates])
        #expect(reconciled.isCollapsed(.blocks))
        #expect(reconciled.isHidden(.layers))
        // The default layout lists it but starts it hidden (a fresh install does not crowd
        // the sidebar; the panel is reachable via ⋯ Customize).
        #expect(SidebarLayoutConfig.default.order.contains(.quickSelect))
        #expect(SidebarLayoutConfig.default.isHidden(.quickSelect))
        // It round-trips through encode/decode like any panel id.
        let restored = SidebarLayoutConfig.decoded(from: reconciled.encoded())
        #expect(restored.order.contains(.quickSelect))
        #expect(restored.isHidden(.quickSelect))
    }

    @Test("a user who already SHOWED .quickSelect keeps it shown across reconciliation")
    func quickSelectUserShownChoicePreserved() {
        // Once the stored config KNOWS .quickSelect (the user has it in their order and has
        // chosen NOT to hide it), reconciliation must respect that choice — the
        // default-hidden flag only applies to a brand-new id the stored config never saw.
        let stored = SidebarLayoutConfig(
            order: [.layers, .quickSelect, .blocks],   // user moved it up + kept it visible
            collapsed: [],
            hidden: []                                 // explicitly NOT hidden
        )
        let reconciled = stored.reconciled(withAvailable: SidebarPanelID.allCases)
        #expect(reconciled.order.contains(.quickSelect))
        #expect(!reconciled.isHidden(.quickSelect))     // user's "shown" choice survives
        #expect(reconciled.visibleOrder.contains(.quickSelect))
    }

    @Test("an unknown stored id is dropped while the new .quickSelect panel appears (hidden)")
    func unknownIdIgnoredWhileQuickSelectAppears() {
        let stored = SidebarLayoutConfig(
            order: [.layers, .layerStates, .blocks],
            collapsed: [.blocks],
            hidden: [.blocks]
        )
        // Drop `.blocks` (simulating a removed/unknown stored id), add `.quickSelect`.
        let available: [SidebarPanelID] = [.layers, .layerStates, .quickSelect]
        let reconciled = stored.reconciled(withAvailable: available)
        #expect(!reconciled.order.contains(.blocks))
        #expect(!reconciled.collapsed.contains(.blocks))
        #expect(!reconciled.hidden.contains(.blocks))
        #expect(reconciled.order == [.layers, .layerStates, .quickSelect])
        // The new power-user panel is appended HIDDEN.
        #expect(reconciled.isHidden(.quickSelect))
    }

    @Test(".quickSelect has a non-empty default title and SF-Symbol")
    func quickSelectMetadata() {
        #expect(SidebarPanelID.quickSelect.defaultTitle == "Quick Select")
        #expect(!SidebarPanelID.quickSelect.defaultSymbol.isEmpty)
    }

    // MARK: PanelID metadata

    @Test("every panel id has a non-empty default title and SF-Symbol")
    func panelIDMetadata() {
        for id in SidebarPanelID.allCases {
            #expect(!id.defaultTitle.isEmpty)
            #expect(!id.defaultSymbol.isEmpty)
        }
    }
}
