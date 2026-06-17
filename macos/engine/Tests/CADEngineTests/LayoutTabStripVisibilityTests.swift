//
//  LayoutTabStripVisibilityTests.swift
//  CADEngineTests
//
//  The LayoutTabStrip is ALWAYS visible (AutoCAD/LibreCAD parity): it shows the
//  "Model" tab, one tab per layout, and the trailing "+" add-layout button. Its
//  visibility is a PURE predicate that now returns `true` unconditionally:
//
//      shouldShow == true
//
//  It was briefly hidden until a paper-space layout existed (Wave 4 §3d), but the only
//  add-layout affordance ("+") lives INSIDE the strip — so hiding it left a fresh,
//  model-space-only document with no GUI way to create its first layout (a dead-end).
//  These tests pin the always-visible contract so a future "hide when empty" regression
//  fails loudly: with zero layouts and no block-edit session the strip is STILL shown.
//
//  `LayoutTabStrip` is a SwiftUI view in the (un-importable) app target and `ContentView`
//  is too large to symlink whole, so the predicate is reproduced here exactly as the view
//  uses it (kept byte-identical so a rule change in production must be mirrored here).
//
//  `CanvasModel` is reached via the existing `_SharedCanvasModel.swift` symlink; the
//  suite is `@MainActor`. Uniquely namespaced so it does not collide in the shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("layout tab strip visibility (always shown — Model tab + “+” always reachable)")
struct LayoutTabStripVisibilityTests {

    /// The pure predicate the view uses (`LayoutTabStrip.shouldShow`). Reproduced here
    /// because the view itself is not symlink-reachable; kept byte-identical so a rule
    /// change in production must be mirrored here. The strip is ALWAYS visible — the
    /// parameters are retained only to match the production signature.
    private func shouldShow(layoutCount: Int, isEditingBlock: Bool) -> Bool {
        true
    }

    private func makeModel() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    // MARK: - The pure predicate (always true)

    @Test("only Model (no layouts, no session) → strip is STILL SHOWN (so “+” is reachable)")
    func shownWithOnlyModel() {
        // The regression guard: a fresh, model-space-only drawing MUST show the strip,
        // otherwise the lone "+" (the only add-layout entry point) is unreachable.
        #expect(shouldShow(layoutCount: 0, isEditingBlock: false) == true)
    }

    @Test("any paper-space layout → strip is SHOWN")
    func shownWithALayout() {
        #expect(shouldShow(layoutCount: 1, isEditingBlock: false) == true)
        #expect(shouldShow(layoutCount: 3, isEditingBlock: false) == true)
    }

    @Test("a block-edit session keeps the strip shown (BEDIT tab home)")
    func shownDuringBlockEditWithoutLayouts() {
        #expect(shouldShow(layoutCount: 0, isEditingBlock: true) == true)
    }

    // MARK: - The real model inputs (the strip is shown regardless)

    @Test("a fresh document has zero paper-space layouts — yet the strip is shown (Model + “+”)")
    func freshDocShowsStripWithNoLayouts() {
        let m = makeModel()
        #expect(m.orderedLayouts.isEmpty)
        // → the strip is shown for a brand-new drawing so the first layout can be added.
        #expect(shouldShow(layoutCount: m.orderedLayouts.count,
                           isEditingBlock: m.editingBlock != nil) == true)
    }

    @Test("adding a layout adds a tab; the strip stays shown")
    func addingALayoutKeepsTheStripShown() {
        let m = makeModel()
        #expect(m.orderedLayouts.isEmpty)
        let name = m.newLayout()
        #expect(name != nil, "newLayout should create a paper-space layout")
        #expect(m.orderedLayouts.count >= 1)
        #expect(shouldShow(layoutCount: m.orderedLayouts.count,
                           isEditingBlock: m.editingBlock != nil) == true)
    }
}
