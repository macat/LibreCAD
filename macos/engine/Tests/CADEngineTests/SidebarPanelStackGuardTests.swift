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
}
