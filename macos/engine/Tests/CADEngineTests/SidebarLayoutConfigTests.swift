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

    @Test("the default layout carries every panel, in declaration order, all visible & expanded")
    func defaultLayout() {
        let cfg = SidebarLayoutConfig.default
        #expect(cfg.order == SidebarPanelID.allCases)
        #expect(cfg.collapsed.isEmpty)
        #expect(cfg.hidden.isEmpty)
        #expect(cfg.visibleOrder == SidebarPanelID.allCases)
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
        let original = SidebarLayoutConfig(
            order: [.blocks, .layers, .layerStates],
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
        // Move the first panel (layers) to the end.
        let moved = SidebarLayoutConfig.default
            .movingVisible(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(moved.order == [.layerStates, .blocks, .layers])
        // Survives persistence.
        let restored = SidebarLayoutConfig.decoded(from: moved.encoded())
        #expect(restored.order == [.layerStates, .blocks, .layers])
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
        var cfg = SidebarLayoutConfig.default
        #expect(!cfg.isHidden(.blocks))
        cfg = cfg.togglingHidden(.blocks)
        #expect(cfg.isHidden(.blocks))
        #expect(cfg.visibleOrder == [.layers, .layerStates])
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
        let reconciled = stored.reconciled(withAvailable: SidebarPanelID.allCases)
        // No duplicates; missing `.layerStates` appended.
        #expect(reconciled.order == [.layers, .blocks, .layerStates])
        #expect(Set(reconciled.order).count == reconciled.order.count)
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
