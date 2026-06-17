//
//  LayoutPageSetupSheetTests.swift
//  CADEngineTests
//
//  Exercises (a) the PURE `LayoutPageMapper` form ⇄ `PageDescriptor` mapper that backs
//  the per-layout Page Setup sheet (backlog #4c), and (b) a `CanvasModel.setLayoutPage`
//  + undo ROUND-TRIP driven directly on the model — WITHOUT ever presenting the sheet
//  (the sheet is View-layer-only, the headless-modal trap). The mapper is a side-effect-
//  free value function (mirrors `LayoutRenameSheet.Validation`); the sheet source is
//  compiled into this engine test target via the `_SharedLayoutPageSetupSheet.swift`
//  symlink (the established `_Shared*` convention), and `_SharedCanvasModel.swift`
//  supplies the model.
//
//  Uniquely namespaced (`@Suite`) so it does not collide with the other suites in this
//  fan-out-shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Pure mapper (no GUI, no model)

@Suite("layout page setup (#4c) — pure LayoutPageMapper")
struct LayoutPageMapperTests {

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
        abs(a - b) < tol
    }

    @Test("A4 portrait form → 210×297 mm descriptor with the chosen margin")
    func a4PortraitToDescriptor() {
        let form = LayoutPageMapper.PageForm(
            preset: .a4, orientation: .portrait,
            customWidthMM: 0, customHeightMM: 0,
            marginMM: 12, fitToPage: true, ratio: 1)
        let page = LayoutPageMapper.pageDescriptor(from: form)
        #expect(approx(page.widthMM, 210))
        #expect(approx(page.heightMM, 297))
        #expect(approx(page.marginMM, 12))
        #expect(page.plotScale.ratioValue == nil)   // .fit
    }

    @Test("landscape swaps width/height of a preset")
    func landscapeSwapsDims() {
        let form = LayoutPageMapper.PageForm(
            preset: .a3, orientation: .landscape,
            customWidthMM: 0, customHeightMM: 0,
            marginMM: 0, fitToPage: true, ratio: 1)
        let page = LayoutPageMapper.pageDescriptor(from: form)
        // A3 portrait is 297×420 ⇒ landscape is 420×297.
        #expect(approx(page.widthMM, 420))
        #expect(approx(page.heightMM, 297))
    }

    @Test("a fixed plot scale survives as a positive ratio; non-fit ⇒ .ratio")
    func fixedRatio() {
        let form = LayoutPageMapper.PageForm(
            preset: .a4, orientation: .portrait,
            customWidthMM: 0, customHeightMM: 0,
            marginMM: 5, fitToPage: false, ratio: 100)
        let page = LayoutPageMapper.pageDescriptor(from: form)
        #expect(page.plotScale.ratioValue == 100)
    }

    @Test("negative margin is clamped to 0; a degenerate ratio clamps to 1")
    func clamps() {
        let form = LayoutPageMapper.PageForm(
            preset: .a4, orientation: .portrait,
            customWidthMM: 0, customHeightMM: 0,
            marginMM: -50, fitToPage: false, ratio: -3)
        let page = LayoutPageMapper.pageDescriptor(from: form)
        #expect(approx(page.marginMM, 0))
        #expect(page.plotScale.ratioValue == 1)   // .fixed clamps non-positive to 1:1
    }

    @Test("custom size is normalized to portrait then oriented")
    func customSizeNormalized() {
        // Type a "landscape-shaped" custom pair but ask for portrait: the mapper
        // normalizes to portrait (smaller side = width) first.
        let form = LayoutPageMapper.PageForm(
            preset: .custom, orientation: .portrait,
            customWidthMM: 500, customHeightMM: 300,
            marginMM: 0, fitToPage: true, ratio: 1)
        let page = LayoutPageMapper.pageDescriptor(from: form)
        #expect(approx(page.widthMM, 300))   // smaller side
        #expect(approx(page.heightMM, 500))
    }

    @Test("PageDescriptor → form detects preset, orientation, margin, fit")
    func descriptorToForm() {
        // A4 landscape (420? no — A4 landscape is 297×210), 8 mm margin, fit.
        let page = PageDescriptor(widthMM: 297, heightMM: 210, marginMM: 8, plotScale: .fit)
        let form = LayoutPageMapper.form(from: page)
        #expect(form.preset == .a4)
        #expect(form.orientation == .landscape)
        #expect(approx(form.marginMM, 8))
        #expect(form.fitToPage)
    }

    @Test("PageDescriptor with a non-preset size maps to .custom carrying the size")
    func descriptorToCustom() {
        let page = PageDescriptor(widthMM: 333, heightMM: 555, marginMM: 0, plotScale: .ratio(50))
        let form = LayoutPageMapper.form(from: page)
        #expect(form.preset == .custom)
        #expect(form.orientation == .portrait)   // 333 < 555
        #expect(approx(form.customWidthMM, 333))
        #expect(approx(form.customHeightMM, 555))
        #expect(!form.fitToPage)
        #expect(approx(form.ratio, 50))
    }

    @Test("round-trip: form → descriptor → form is stable for a preset page")
    func roundTripStable() {
        let original = LayoutPageMapper.PageForm(
            preset: .letter, orientation: .landscape,
            customWidthMM: 0, customHeightMM: 0,
            marginMM: 6, fitToPage: false, ratio: 2)
        let page = LayoutPageMapper.pageDescriptor(from: original)
        let back = LayoutPageMapper.form(from: page)
        #expect(back.preset == .letter)            // matched within tolerance
        #expect(back.orientation == .landscape)
        #expect(approx(back.marginMM, 6))
        #expect(!back.fitToPage)
        #expect(approx(back.ratio, 2))
    }
}

// MARK: - CanvasModel.setLayoutPage + undo round-trip (no sheet)

@MainActor
@Suite("layout page setup (#4c) — CanvasModel.setLayoutPage + undo")
struct LayoutSetPageRoundTripTests {

    /// A deterministic UndoManager (no run-loop event coalescing) so a single mutation
    /// in a test is a closed, undoable group — the pattern `LayoutViewportTests` uses.
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    @Test("setLayoutPage replaces the page; one ⌘Z restores the prior page")
    func setLayoutPageUndoable() {
        let drawing = CADDrawing()
        _ = drawing.addLayout(Layout(name: "Layout1", tabOrder: 0, page: .a4Portrait))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))

        let um = testUndoManager()
        model.adoptUndoManager(um)

        let original = drawing.layout(named: "Layout1")!.page
        #expect(original == .a4Portrait)

        // Build a new page via the SAME pure mapper the sheet's OK uses.
        let form = LayoutPageMapper.PageForm(
            preset: .a3, orientation: .landscape,
            customWidthMM: 0, customHeightMM: 0,
            marginMM: 15, fitToPage: false, ratio: 100)
        let newPage = LayoutPageMapper.pageDescriptor(from: form)

        um.beginUndoGrouping()
        #expect(model.setLayoutPage("Layout1", newPage) == true)
        um.endUndoGrouping()

        let after = drawing.layout(named: "Layout1")!.page
        #expect(after.widthMM == 420)            // A3 landscape
        #expect(after.heightMM == 297)
        #expect(after.marginMM == 15)
        #expect(after.plotScale.ratioValue == 100)
        #expect(after != original)

        // One undo restores the original page exactly.
        um.undo()
        #expect(drawing.layout(named: "Layout1")!.page == original)

        // Redo re-applies it.
        um.redo()
        #expect(drawing.layout(named: "Layout1")!.page == newPage)
    }

    @Test("setLayoutPage to an unchanged page is a no-op (returns false, no undo)")
    func setLayoutPageUnchangedNoOp() {
        let drawing = CADDrawing()
        _ = drawing.addLayout(Layout(name: "Layout1", tabOrder: 0, page: .a4Portrait))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        let um = testUndoManager()
        model.adoptUndoManager(um)

        #expect(model.setLayoutPage("Layout1", .a4Portrait) == false)
        #expect(um.canUndo == false)
    }

    @Test("setLayoutPage on a missing layout is a no-op")
    func setLayoutPageMissingNoOp() {
        let drawing = CADDrawing()
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        let um = testUndoManager()
        model.adoptUndoManager(um)
        #expect(model.setLayoutPage("Nope", PageDescriptor(widthMM: 100, heightMM: 100)) == false)
        #expect(um.canUndo == false)
    }
}
