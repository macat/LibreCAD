//
//  LayoutRenameSheetTests.swift
//  CADEngineTests
//
//  Exercises the PURE validation logic of the layout-tab rename sheet
//  (`LayoutRenameSheet.Validation.classify`, backlog #4c) WITHOUT presenting the
//  modal — the sheet itself is View-layer-only (headless-modal trap), but its
//  validator is a side-effect-free value function (mirrors `BlockNamePrompt.Validation`,
//  tested in `BlockUIWiringTests`). The sheet source is compiled into this engine test
//  target via the `_SharedLayoutRenameSheet.swift` symlink (the established convention).
//
//  Uniquely namespaced (`@Suite`) so it does not collide with other suites in this
//  fan-out-shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("layout rename sheet (#4c) — pure validator")
struct LayoutRenameSheetValidationTests {

    private let existing = ["Layout1", "Layout2", "Cover Sheet"]

    @Test("blank / whitespace-only names are .empty (confirm disabled)")
    func blankIsEmpty() {
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "", currentName: "Layout1", existingNames: existing) == .empty)
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "   ", currentName: "Layout1", existingNames: existing) == .empty)
        #expect(!LayoutRenameSheet.Validation.classify(
            newName: "  ", currentName: "Layout1", existingNames: existing).isConfirmable)
    }

    @Test("a fresh unique name is .ok (confirm enabled)")
    func freshNameIsOK() {
        let v = LayoutRenameSheet.Validation.classify(
            newName: "Plan View", currentName: "Layout1", existingNames: existing)
        #expect(v == .ok)
        #expect(v.isConfirmable)
    }

    @Test("renaming to the current name (or its recase) is .unchanged, not .collision")
    func currentNameIsUnchanged() {
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "Layout1", currentName: "Layout1", existingNames: existing) == .unchanged)
        // Recase of the current name is still allowed (the model rename wrapper handles it).
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "  LAYOUT1 ", currentName: "Layout1", existingNames: existing) == .unchanged)
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "layout1", currentName: "Layout1", existingNames: existing).isConfirmable)
    }

    @Test("a name matching a DIFFERENT layout (case-insensitive) is .collision (disabled)")
    func collisionWithOtherLayout() {
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "Layout2", currentName: "Layout1", existingNames: existing) == .collision)
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "  cover sheet ", currentName: "Layout1", existingNames: existing) == .collision)
        #expect(!LayoutRenameSheet.Validation.classify(
            newName: "LAYOUT2", currentName: "Layout1", existingNames: existing).isConfirmable)
    }

    @Test("existingNames including the current name does not self-collide")
    func currentNamePresentInListDoesNotSelfCollide() {
        // The full layout list normally INCLUDES the current name; that must not make a
        // no-op rename read as a collision.
        let withSelf = ["Layout1", "Layout2"]
        #expect(LayoutRenameSheet.Validation.classify(
            newName: "Layout1", currentName: "Layout1", existingNames: withSelf) == .unchanged)
    }
}
