//
//  PaperSpaceLayoutHelperTests.swift
//  CADEngineTests
//
//  Paper space — Phase 2 (paperspace-plan.md §4): the PURE, GPU-/view-free layout
//  math (`enum PaperSpaceLayout` in `CanvasModel.swift`) + the `@MainActor`
//  `CanvasModel` active-space switching (Model / Layout tabs). These backfill the
//  "tests follow" gap left when P2 was salvaged after an infra error.
//
//  Two layers, both reached through the EXISTING `_SharedCanvasModel.swift` symlink
//  (the app module's `CanvasModel.swift`, which the test target compiles via the
//  project's `_Shared*` convention; the `PaperSize` shim it needs already lives in
//  `RelativeZeroTests.swift`):
//
//   • `PaperSpaceLayout` — the side-effect-free helpers the renderer + index-rebuild
//     share: `isInActiveSpace` / `entities(in:)` (space partition), `sheetRect` and
//     `marginRect` (page → world rectangle). No GPU, no Viewport mutation, no Metal.
//
//   • `CanvasModel` space switching — `activateLayout(name:)` / `activateModel()` /
//     `setActiveSpace` / `newLayout()` and the derived `activeSpace` / `activeLayout`
//     / `activeSpaceEntities` / `activeLayoutRecord`, seeded from a `CADDrawing` with
//     a layout + paper/model entities. The suite is `@MainActor` (CanvasModel is a
//     main-actor `@Observable`, matching `PaperSpaceModelTests` / `RelativeZeroTests`).
//
//  SCOPE: we assert ONLY the pure `PaperSpaceLayout` helpers + the CanvasModel
//  active-space STATE — never `LineRenderer` / `PaperSheetGeometry` output nor
//  viewport-fit numerics (owned by concurrent agents). We read `viewport.size`
//  (unchanged across a fit) only to confirm a re-frame ran, not its framing math.
//
//  Uniquely namespaced (`@Suite("paper space P2 ...")`) so it does not collide with
//  the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("paper space P2 (PaperSpaceLayout pure helpers + CanvasModel space switching)")
struct PaperSpaceLayoutHelperTests {

    // MARK: - Fixtures

    /// A model-space LINE.
    private func model(_ id: UInt64) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
    }

    /// A paper-space LINE bound to `layout`.
    private func paper(_ id: UInt64, on layout: String) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(2, 0))),
                     space: .paper, layoutName: layout)
    }

    /// A4 portrait (the engine default page: 210 × 297 mm, 10 mm margin).
    private var a4: PageDescriptor { PageDescriptor() }

    /// The ids of `records`, sorted ascending — kept OUT of the `#expect` macro so the
    /// closure/keypath doesn't trip the SwiftUI-style "unable to type-check" explosion.
    private func sortedIDs(_ records: [EntityRecord]) -> [EntityID] {
        var ids = records.map { $0.id }
        ids.sort { $0.rawValue < $1.rawValue }
        return ids
    }

    // MARK: - 5) Space partition (isInActiveSpace / entities(in:))

    @Test("model space shows model records and HIDES paper records")
    func modelSpaceHidesPaper() {
        let recs = [model(1), paper(2, on: "Layout1"), model(3)]
        let shown = PaperSpaceLayout.entities(in: recs, space: .model, layoutName: nil)
        #expect(sortedIDs(shown) == [EntityID(1), EntityID(3)])
        // The per-entity predicate agrees with the array filter (no drift).
        #expect(PaperSpaceLayout.isInActiveSpace(model(1), space: .model, layoutName: nil))
        #expect(!PaperSpaceLayout.isInActiveSpace(paper(2, on: "Layout1"), space: .model, layoutName: nil))
    }

    @Test("a named layout shows ONLY its matching paper records (model + other-layout hidden)")
    func namedLayoutScopesToItsPaperRecords() {
        let recs = [model(1),
                    paper(2, on: "Layout1"),
                    paper(3, on: "Layout2"),
                    paper(4, on: "Layout1")]
        let shown = PaperSpaceLayout.entities(in: recs, space: .paper, layoutName: "Layout1")
        #expect(sortedIDs(shown) == [EntityID(2), EntityID(4)])
        // The model record and the OTHER layout's paper record are hidden.
        #expect(!PaperSpaceLayout.isInActiveSpace(model(1), space: .paper, layoutName: "Layout1"))
        #expect(!PaperSpaceLayout.isInActiveSpace(paper(3, on: "Layout2"), space: .paper, layoutName: "Layout1"))
    }

    @Test("layout-name matching is CASE-INSENSITIVE")
    func layoutNameMatchIsCaseInsensitive() {
        let rec = paper(2, on: "Layout1")
        #expect(PaperSpaceLayout.isInActiveSpace(rec, space: .paper, layoutName: "LAYOUT1"))
        #expect(PaperSpaceLayout.isInActiveSpace(rec, space: .paper, layoutName: "layout1"))
        let shown = PaperSpaceLayout.entities(in: [rec], space: .paper, layoutName: "lAyOuT1")
        #expect(shown.count == 1)
    }

    @Test("a nil or empty layout name on a PAPER space yields nothing")
    func nilOrBlankLayoutOnPaperYieldsNothing() {
        let recs = [paper(2, on: "Layout1"), paper(3, on: "Layout1")]
        // nil active layout (no sheet picked) ⇒ nothing on a paper space.
        #expect(PaperSpaceLayout.entities(in: recs, space: .paper, layoutName: nil).isEmpty)
        #expect(!PaperSpaceLayout.isInActiveSpace(recs[0], space: .paper, layoutName: nil))
        // An EMPTY active-layout name ⇒ nothing (the helper's explicit empty guard).
        #expect(PaperSpaceLayout.entities(in: recs, space: .paper, layoutName: "").isEmpty)
        #expect(!PaperSpaceLayout.isInActiveSpace(recs[0], space: .paper, layoutName: ""))
        // Sanity: the SAME record IS shown when the correct layout name is active, so
        // the empties above are the guard firing, not a mis-built fixture.
        #expect(PaperSpaceLayout.isInActiveSpace(recs[0], space: .paper, layoutName: "Layout1"))
    }

    // MARK: - 6) sheetRect(for:)

    @Test("sheetRect for A4 is the (0,0)..(210,297) box")
    func sheetRectA4() {
        let rect = PaperSpaceLayout.sheetRect(for: a4)
        #expect(rect.min == Vector(0, 0))
        #expect(rect.max == Vector(210, 297))
        #expect(!rect.isEmpty)
    }

    @Test("a non-finite or zero page dimension collapses safely (no NaN, valid box)")
    func sheetRectDegenerateIsSafe() {
        // Zero width: x collapses to 0, height kept.
        var zeroW = a4; zeroW.widthMM = 0
        let r1 = PaperSpaceLayout.sheetRect(for: zeroW)
        #expect(r1.min == Vector(0, 0))
        #expect(r1.max == Vector(0, 297))
        #expect(r1.max.x.isFinite && r1.max.y.isFinite)

        // NaN / infinite dimensions collapse to 0 — never propagate a NaN.
        var nan = a4; nan.widthMM = .nan; nan.heightMM = .infinity
        let r2 = PaperSpaceLayout.sheetRect(for: nan)
        #expect(r2.min == Vector(0, 0))
        #expect(r2.max == Vector(0, 0))
        #expect(r2.max.x.isFinite && r2.max.y.isFinite)
        #expect(!r2.max.x.isNaN && !r2.max.y.isNaN)
    }

    // MARK: - 7) marginRect(for:)

    @Test("marginRect insets A4 by 10 mm on every edge")
    func marginRectA4Inset() {
        let rect = PaperSpaceLayout.marginRect(for: a4)
        #expect(rect.min == Vector(10, 10))
        #expect(rect.max == Vector(200, 287))   // 210-10, 297-10
    }

    @Test("an oversized margin clamps to a CENTERED, non-inverted rect (never min > max)")
    func marginRectOversizedClampsCentered() {
        // A 1000 mm margin on a 210×297 sheet would invert the box; it must clamp to
        // half each dimension → a centered zero-size line, not a negative box.
        var huge = a4; huge.marginMM = 1000
        let rect = PaperSpaceLayout.marginRect(for: huge)
        #expect(rect.min.x <= rect.max.x)
        #expect(rect.min.y <= rect.max.y)
        // Clamped to half each dimension: x collapses to the sheet mid-x (105), y to
        // the mid-y (148.5).
        #expect(rect.min.x == 105 && rect.max.x == 105)
        #expect(rect.min.y == 148.5 && rect.max.y == 148.5)
    }

    @Test("a zero / negative margin returns the FULL sheet (no inset)")
    func marginRectZeroOrNegativeIsFullSheet() {
        var zero = a4; zero.marginMM = 0
        #expect(PaperSpaceLayout.marginRect(for: zero) == PaperSpaceLayout.sheetRect(for: zero))
        var neg = a4; neg.marginMM = -5
        #expect(PaperSpaceLayout.marginRect(for: neg) == PaperSpaceLayout.sheetRect(for: neg))
    }

    // MARK: - CanvasModel active-space switching

    /// A model seeded with one layout ("Layout1") + a paper line on it + a model line.
    private func seededModel(layout: String = "Layout1") -> CanvasModel {
        let drawing = CADDrawing()
        _ = drawing.addLayout(Layout(name: layout, tabOrder: 0, page: PageDescriptor()))
        _ = drawing.add(paper(1, on: layout))
        _ = drawing.add(model(2))
        return CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
    }

    // MARK: - 8a) activateLayout

    @Test("activateLayout switches to paper, scopes entities, and exposes the layout record")
    func activateLayoutScopesAndExposesRecord() throws {
        let m = seededModel()
        // Fresh model starts in MODEL space (only the model line is active).
        #expect(m.activeSpace == .model)
        #expect(m.activeLayout == nil)
        #expect(m.activeSpaceEntities.map(\.id) == [EntityID(2)])
        #expect(m.activeLayoutRecord == nil)

        m.activateLayout(name: "Layout1")
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == "Layout1")
        // Now scoped to ONLY the paper record on Layout1.
        #expect(m.activeSpaceEntities.map(\.id) == [EntityID(1)])
        // The active layout record resolves (the renderer reads its page for the sheet).
        let rec = try #require(m.activeLayoutRecord)
        #expect(rec.name == "Layout1")
    }

    @Test("activateModel returns to model space and re-scopes to the model entities")
    func activateModelReturnsToModel() {
        let m = seededModel()
        m.activateLayout(name: "Layout1")
        #expect(m.activeSpace == .paper)

        m.activateModel()
        #expect(m.activeSpace == .model)
        #expect(m.activeLayout == nil)
        #expect(m.activeSpaceEntities.map(\.id) == [EntityID(2)])
        #expect(m.activeLayoutRecord == nil)
    }

    // MARK: - 8b) absent-layout fallback

    @Test("switching to .paper with an ABSENT layout falls back to model space")
    func absentLayoutFallsBackToModel() {
        let m = seededModel()
        m.setActiveSpace(.paper, layoutName: "DoesNotExist")
        // No such sheet → resolved to model space (the safe default).
        #expect(m.activeSpace == .model)
        #expect(m.activeLayout == nil)
        #expect(m.activeSpaceEntities.map(\.id) == [EntityID(2)])
    }

    @Test("activating a layout canonicalizes the casing to the stored layout name")
    func activateLayoutCanonicalizesCasing() {
        let m = seededModel(layout: "Layout1")
        // Request with different casing; the live activeLayout should be the stored name
        // so the render filter matches exactly.
        m.activateLayout(name: "LAYOUT1")
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == "Layout1")
        #expect(m.activeSpaceEntities.map(\.id) == [EntityID(1)])
    }

    // MARK: - 8c) newLayout auto-names + activates

    @Test("newLayout auto-names (Layout1, Layout2, …) and activates the fresh sheet")
    func newLayoutAutoNamesAndActivates() {
        let drawing = CADDrawing()
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        #expect(m.orderedLayouts.isEmpty)

        // First "+" → Layout1, active.
        let first = m.newLayout()
        #expect(first == "Layout1")
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == "Layout1")
        #expect(m.orderedLayouts.map(\.name) == ["Layout1"])

        // Second "+" → Layout2, active, appended after Layout1 in tab order.
        let second = m.newLayout()
        #expect(second == "Layout2")
        #expect(m.activeLayout == "Layout2")
        #expect(m.orderedLayouts.map(\.name) == ["Layout1", "Layout2"])
        #expect(m.orderedLayouts.map(\.tabOrder) == [0, 1])
    }

    @Test("newLayout skips a taken auto-name (Layout1 exists ⇒ next is Layout2)")
    func newLayoutSkipsTakenName() {
        let m = seededModel(layout: "Layout1")   // Layout1 already exists
        let created = m.newLayout()
        #expect(created == "Layout2")
        #expect(m.activeLayout == "Layout2")
        #expect(m.orderedLayouts.map(\.name) == ["Layout1", "Layout2"])
    }
}
