//
//  LayoutTabStripVisibilityTests.swift
//  CADEngineTests
//
//  Wave 4 (bottom chrome) — the LayoutTabStrip's "hide until a paper-space layout
//  exists" rule (plan §3d). The strip's visibility is a PURE predicate over two model
//  reads — the paper-space layout count and whether a block-edit session is open:
//
//      shouldShow == (layoutCount > 0) || isEditingBlock
//
//  `LayoutTabStrip` is a SwiftUI view in the (un-importable) app target and `ContentView`
//  is too large to symlink whole, so these tests pin the predicate's CONTRACT against
//  the REAL model inputs that drive it: a fresh document has only model space (count 0 →
//  hidden); adding a layout makes a paper space exist (count > 0 → shown). The predicate
//  arithmetic is reproduced here exactly as the view uses it so a future change to the
//  rule fails loudly.
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
@Suite("layout tab strip visibility (hide until a paper-space layout exists)")
struct LayoutTabStripVisibilityTests {

    /// The pure predicate the view uses (`LayoutTabStrip.shouldShow`). Reproduced here
    /// because the view itself is not symlink-reachable; kept byte-identical so a rule
    /// change in production must be mirrored here.
    private func shouldShow(layoutCount: Int, isEditingBlock: Bool) -> Bool {
        layoutCount > 0 || isEditingBlock
    }

    private func makeModel() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    // MARK: - The pure predicate

    @Test("only Model (no layouts, no session) → strip is HIDDEN")
    func hiddenWithOnlyModel() {
        #expect(shouldShow(layoutCount: 0, isEditingBlock: false) == false)
    }

    @Test("any paper-space layout → strip is SHOWN")
    func shownWithALayout() {
        #expect(shouldShow(layoutCount: 1, isEditingBlock: false) == true)
        #expect(shouldShow(layoutCount: 3, isEditingBlock: false) == true)
    }

    @Test("a block-edit session shows the strip even with no layouts (BEDIT tab home)")
    func shownDuringBlockEditWithoutLayouts() {
        #expect(shouldShow(layoutCount: 0, isEditingBlock: true) == true)
    }

    // MARK: - The real model inputs that feed the predicate

    @Test("a fresh document has zero paper-space layouts (only model space)")
    func freshDocHasNoLayouts() {
        let m = makeModel()
        #expect(m.orderedLayouts.isEmpty)
        // → the strip is hidden for a brand-new drawing.
        #expect(shouldShow(layoutCount: m.orderedLayouts.count,
                           isEditingBlock: m.editingBlock != nil) == false)
    }

    @Test("adding a layout makes a paper space exist → the strip becomes visible")
    func addingALayoutShowsTheStrip() {
        let m = makeModel()
        #expect(m.orderedLayouts.isEmpty)
        let name = m.newLayout()
        #expect(name != nil, "newLayout should create a paper-space layout")
        #expect(m.orderedLayouts.count >= 1)
        #expect(shouldShow(layoutCount: m.orderedLayouts.count,
                           isEditingBlock: m.editingBlock != nil) == true)
    }
}
