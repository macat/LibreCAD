//
//  SidebarPanelStackGuardTests.swift
//  CADEngineTests
//
//  Pins the DATA CONTRACT behind the Wave-2 SidebarPanelStack change that relocated the
//  Customize (show/hide) ⋯ menu OUT of a dedicated empty top "tune" band and INTO the
//  FIRST visible panel's header. That relocation introduces one hazard the old top band
//  did not have: if the user hides EVERY panel, there is no first header, so the customize
//  menu — the only way to re-show a hidden panel — becomes unreachable.
//
//  `SidebarPanelStack` guards this by disabling the "hide" toggle for the LAST remaining
//  visible panel, using `config.visibleOrder.count` + `config.isHidden(id)` as the signal.
//  That predicate lives in the (non-headless) view, but its INPUTS are the pure config
//  values asserted here: `visibleOrder` genuinely can reach a single-element (and even
//  empty) state through per-panel hides, which is exactly why the view-side guard is
//  required, and re-showing always restores reachability.
//
//  `SidebarLayoutConfig` is app-module but imports only Foundation, so it is reached via
//  the established `_SharedSidebarLayoutConfig.swift` SYMLINK (test target depends only on
//  CADEngine).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("sidebar panel stack — customize-menu reachability guard contract")
struct SidebarPanelStackGuardTests {

    /// The signal the view's guard reads: a single visible panel is the boundary where
    /// the last "hide" toggle must be disabled (hiding it would empty the stack).
    @Test("hiding panels one at a time can reach a single-visible (then empty) visibleOrder")
    func visibleOrderCanCollapseToOneThenEmpty() {
        // Start from a config with exactly two visible panels.
        var cfg = SidebarLayoutConfig(
            order: [.layers, .blocks],
            collapsed: [],
            hidden: []
        )
        #expect(cfg.visibleOrder == [.layers, .blocks])

        // Hide one → a SINGLE visible panel remains. This is the state where the view
        // disables the remaining panel's "hide" toggle (count <= 1 && !isHidden(id)).
        cfg = cfg.settingHidden(.blocks, true)
        #expect(cfg.visibleOrder == [.layers])
        #expect(cfg.visibleOrder.count == 1)
        #expect(!cfg.isHidden(.layers))   // the toggle the guard disables

        // The config layer itself imposes NO floor — it WOULD reach empty if the view let
        // it. (This is the hazard the view-side guard exists to prevent.)
        let wouldBeEmpty = cfg.settingHidden(.layers, true)
        #expect(wouldBeEmpty.visibleOrder.isEmpty)
    }

    /// Re-showing restores reachability: a hidden panel comes back via `settingHidden`
    /// false (what the customize toggle's inverted binding does), and "Show All" resets.
    @Test("re-showing a hidden panel restores visibleOrder (toggle + Show All paths)")
    func reShowingRestoresVisibility() {
        var cfg = SidebarLayoutConfig(order: [.layers, .blocks, .layerStates],
                                      collapsed: [], hidden: [.blocks, .layerStates])
        #expect(cfg.visibleOrder == [.layers])

        // The per-panel toggle (inverted hidden binding) brings one back.
        cfg = cfg.settingHidden(.blocks, false)
        #expect(cfg.visibleOrder == [.layers, .blocks])

        // "Show All Panels" resets every hidden flag.
        cfg = cfg.settingAllHidden(false)
        #expect(cfg.hidden.isEmpty)
        #expect(cfg.visibleOrder == cfg.order)
    }

    /// With two+ visible panels the guard does NOT fire (every hide toggle stays enabled);
    /// only the single-visible boundary disables one. Pins the `count <= 1` threshold.
    @Test("guard threshold is count <= 1: it does not fire while two or more are visible")
    func guardOnlyFiresAtOneVisible() {
        let two = SidebarLayoutConfig(order: [.layers, .blocks], collapsed: [], hidden: [])
        // count == 2 → guard predicate (count <= 1) is false for BOTH visible ids.
        for id in two.visibleOrder {
            let guardFires = two.visibleOrder.count <= 1 && !two.isHidden(id)
            #expect(!guardFires)
        }

        let one = two.settingHidden(.blocks, true)
        // count == 1 → guard fires for the remaining visible id (so it can't be hidden).
        let remaining = one.visibleOrder[0]
        #expect(one.visibleOrder.count <= 1 && !one.isHidden(remaining))
    }

    // MARK: Zero-visible floor (reconciled never empties visibleOrder)

    /// The PRIMARY fix for the S1 review finding: while the INTERACTIVE path is guarded by
    /// the view (the last visible panel's hide toggle is disabled), an all-hidden state can
    /// still arrive through the PERSISTED `@AppStorage` config (externally edited, or a
    /// future build defaulting more panels hidden). `reconciled(withAvailable:)` must impose
    /// a zero-visible FLOOR: after reconciliation, `visibleOrder` is NEVER empty while
    /// `order` is non-empty — it un-hides the first panel so the Customize (⋯) menu, which
    /// rides in the first visible panel's header, always has a home.
    ///
    /// NOTE (fail-before / pass-after): without the floor this `#expect(!...isEmpty)` FAILS
    /// (the un-floored reconcile returns `hidden == order`, so `visibleOrder` is empty);
    /// with the floor it PASSES. Verified by temporarily reverting the floor.
    @Test("reconciled imposes a zero-visible floor: an all-hidden persisted config keeps ≥1 visible")
    func reconciledNeverEmptiesVisibleOrder() {
        let roster: [SidebarPanelID] = [.layers, .blocks, .layerStates]

        // A persisted config that hides EVERY panel in the roster (the unrecoverable state).
        let allHidden = SidebarLayoutConfig(order: roster,
                                            collapsed: [],
                                            hidden: Set(roster))
        #expect(allHidden.visibleOrder.isEmpty)   // pre-reconcile: genuinely all-hidden

        let fixed = allHidden.reconciled(withAvailable: roster)
        #expect(!fixed.visibleOrder.isEmpty)      // FLOOR: at least one visible
        #expect(fixed.visibleOrder.count >= 1)
        // The floor un-hides the FIRST panel in order (so the Customize menu's home is
        // deterministic and the user's relative ordering is preserved).
        #expect(fixed.visibleOrder.first == roster.first)
        #expect(!fixed.isHidden(roster[0]))
        // It un-hides ONLY the first — the user's other hidden choices are respected.
        #expect(fixed.isHidden(.blocks))
        #expect(fixed.isHidden(.layerStates))
    }

    /// The floor reaches the real load path too: `decoded(from:)` of an all-hidden persisted
    /// JSON string yields a recoverable config (≥1 visible). This is exactly how an
    /// externally-edited `@AppStorage` value enters the app.
    @Test("decoded() of an all-hidden persisted string yields a recoverable (≥1 visible) config")
    func decodedAllHiddenStringIsRecoverable() {
        let roster: [SidebarPanelID] = [.layers, .blocks]
        let allHidden = SidebarLayoutConfig(order: roster, collapsed: [], hidden: Set(roster))
        let raw = allHidden.encoded()
        #expect(!raw.isEmpty)

        let loaded = SidebarLayoutConfig.decoded(from: raw, available: roster)
        #expect(!loaded.visibleOrder.isEmpty)
        #expect(loaded.visibleOrder.first == roster.first)
    }

    /// The floor only fires when EVERY panel is hidden: a config that leaves one (or more)
    /// visible is returned untouched by the floor — it must not gratuitously un-hide a
    /// user's deliberately-hidden panels.
    @Test("zero-visible floor is inert when at least one panel is already visible")
    func floorDoesNotDisturbAlreadyVisibleConfigs() {
        let roster: [SidebarPanelID] = [.layers, .blocks, .layerStates]
        // .layers visible, the other two hidden — a legitimate user choice.
        let oneVisible = SidebarLayoutConfig(order: roster,
                                             collapsed: [],
                                             hidden: [.blocks, .layerStates])
        let reconciled = oneVisible.reconciled(withAvailable: roster)
        #expect(reconciled.visibleOrder == [.layers])
        #expect(reconciled.hidden == [.blocks, .layerStates])  // unchanged
    }

    /// An empty `order` has nothing to floor: reconciling an empty roster stays empty (no
    /// crash, no phantom panel). Pins the `order.first` guard.
    @Test("zero-visible floor no-ops on an empty roster")
    func floorNoOpsOnEmptyOrder() {
        let empty = SidebarLayoutConfig(order: [], collapsed: [], hidden: [])
        let reconciled = empty.reconciled(withAvailable: [])
        #expect(reconciled.order.isEmpty)
        #expect(reconciled.visibleOrder.isEmpty)
    }
}
