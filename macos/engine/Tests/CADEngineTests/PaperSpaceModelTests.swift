//
//  PaperSpaceModelTests.swift
//  CADEngineTests
//
//  Paper space / layouts — Phase 0 (paperspace-plan.md §2). Covers the ADDITIVE,
//  model-space-preserving data model:
//
//   • `CADDrawing.layouts`: add / get / rename / remove are name-unique,
//     tab-ordered, and UNDOABLE (mirroring the block-table mutators). Model space
//     stays IMPLICIT (never a `Layout` entry).
//   • `EntityRecord.space` / `.layoutName`: the additive per-entity space tag —
//     the default record is `.model`/`nil`, a Codable round-trip preserves an
//     explicit paper-space tag, AND an OLD-FORMAT record (no space keys at all)
//     decodes back as `.model`/`nil` (back-compat: old files still load).
//   • `DXFPayload` ↔ `CADDrawing`: the native value-model round-trip carries the
//     layout table AND the per-entity space tag in BOTH directions.
//
//  Uniquely namespaced (`@Suite("paper space P0 ...")`) so it does not collide
//  with the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("paper space P0 (layouts + per-entity space + persistence)")
struct PaperSpaceModelTests {

    // MARK: - Helpers

    /// An UndoManager configured for unit testing (manual grouping).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A line entity (model space by default).
    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    // MARK: - EntitySpace / EntityRecord additive fields

    @Test("a default EntityRecord is model space with no layout (additive defaults)")
    func defaultRecordIsModelSpace() {
        let rec = line(Vector(0, 0), Vector(1, 0), id: 1)
        #expect(rec.space == .model)
        #expect(rec.layoutName == nil)
        // The existing 5-arg initializer call stays source-compatible (no space args).
        let explicit = EntityRecord(id: EntityID(2), layer: .zero, pen: .byLayer,
                                    flags: .default, kind: .line(LineData(start: .init(0, 0),
                                                                           end: .init(1, 1))))
        #expect(explicit.space == .model)
        #expect(explicit.layoutName == nil)
    }

    @Test("EntitySpace raw values match the DXF code-67 flag (0 model / 1 paper)")
    func entitySpaceRawValues() {
        #expect(EntitySpace.model.rawValue == 0)
        #expect(EntitySpace.paper.rawValue == 1)
        #expect(EntitySpace(rawValue: 0) == .model)
        #expect(EntitySpace(rawValue: 1) == .paper)
    }

    @Test("a paper-space record round-trips through Codable (space + layoutName)")
    func paperRecordCodableRoundTrip() throws {
        let rec = EntityRecord(id: EntityID(7),
                               kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))),
                               space: .paper, layoutName: "Layout1")
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(EntityRecord.self, from: data)
        #expect(back.id == EntityID(7))
        #expect(back.space == .paper)
        #expect(back.layoutName == "Layout1")
        #expect(back == rec)   // Hashable/Equatable include the new fields
    }

    @Test("an OLD-FORMAT record (no space keys) decodes as .model / nil")
    func oldFormatRecordDecodesAsModel() throws {
        // Simulate a file saved BEFORE the paper-space fields existed: encode a normal
        // record, strip the `space`/`layoutName` keys from the JSON, then decode. The
        // back-compat `decodeIfPresent` must yield `.model` / `nil` so old model-space
        // drawings load unchanged.
        let rec = line(Vector(2, 3), Vector(8, 3), id: 11)
        let data = try JSONEncoder().encode(rec)
        var json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Sanity: the new keys ARE present in a fresh encode.
        #expect(json["space"] != nil)
        json.removeValue(forKey: "space")
        json.removeValue(forKey: "layoutName")
        let oldData = try JSONSerialization.data(withJSONObject: json)

        let back = try JSONDecoder().decode(EntityRecord.self, from: oldData)
        #expect(back.id == EntityID(11))
        #expect(back.space == .model)       // absent key ⇒ model space
        #expect(back.layoutName == nil)     // absent key ⇒ no layout
        // The rest of the record is intact (the geometry decoded normally).
        guard case .line(let l) = back.kind else { Issue.record("not a line"); return }
        #expect(l.start == Vector(2, 3))
        #expect(l.end == Vector(8, 3))
    }

    @Test("Layout + PageDescriptor + PlotScale round-trip through Codable")
    func layoutCodableRoundTrip() throws {
        let layout = Layout(name: "ISO A3", tabOrder: 2,
                            page: PageDescriptor(widthMM: 420, heightMM: 297,
                                                 marginMM: 7.5, plotScale: .ratio(0.01)))
        let back = try JSONDecoder().decode(
            Layout.self, from: try JSONEncoder().encode(layout))
        #expect(back == layout)
        #expect(back.name == "ISO A3")
        #expect(back.tabOrder == 2)
        #expect(back.page.widthMM == 420)
        #expect(back.page.heightMM == 297)
        #expect(back.page.marginMM == 7.5)
        #expect(back.page.plotScale == .ratio(0.01))
        #expect(back.page.plotScale.ratioValue == 0.01)
        // `.fit` carries no stored ratio.
        #expect(LayoutPlotScale.fit.ratioValue == nil)
        // `LayoutPlotScale.fixed` clamps a non-positive / non-finite value to 1:1.
        #expect(LayoutPlotScale.fixed(-3) == .ratio(1))
        #expect(LayoutPlotScale.fixed(.nan) == .ratio(1))
        #expect(LayoutPlotScale.fixed(50) == .ratio(50))
    }

    // MARK: - CADDrawing.layouts: add / get

    @Test("addLayout registers a named sheet; get looks it up case-insensitively")
    func addAndGetLayout() {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        #expect(d.layouts.isEmpty)

        #expect(d.addLayout(Layout(name: "Layout1")) == true)
        #expect(d.layouts.count == 1)
        #expect(d.hasLayout("LAYOUT1"))                       // case-insensitive
        #expect(d.layout(named: "layout1")?.name == "Layout1")
        // Model space is NEVER a layout entry.
        #expect(d.layouts.allSatisfy { $0.name.caseInsensitiveCompare("Model") != .orderedSame })
    }

    @Test("a duplicate name (case-insensitive) is rejected, no second entry")
    func duplicateLayoutNameRejected() {
        let d = CADDrawing()
        #expect(d.addLayout(Layout(name: "Sheet")) == true)
        #expect(d.addLayout(Layout(name: "SHEET")) == false)  // case-insensitive clash
        #expect(d.layouts.count == 1)
    }

    @Test("the layout table stays ordered by tabOrder")
    func layoutsOrderedByTab() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "C", tabOrder: 2))
        d.addLayout(Layout(name: "A", tabOrder: 0))
        d.addLayout(Layout(name: "B", tabOrder: 1))
        #expect(d.layouts.map(\.name) == ["A", "B", "C"])
    }

    // MARK: - CADDrawing.layouts: remove

    @Test("removeLayout(name:) drops the sheet (case-insensitive); absent is a no-op")
    func removeLayout() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        d.addLayout(Layout(name: "Layout2", tabOrder: 1))
        #expect(d.removeLayout(name: "LAYOUT1") == true)
        #expect(!d.hasLayout("Layout1"))
        #expect(d.layouts.map(\.name) == ["Layout2"])
        #expect(d.removeLayout(name: "Nope") == false)        // absent ⇒ no-op
        #expect(d.layouts.count == 1)
    }

    // MARK: - CADDrawing.layouts: rename

    @Test("renameLayout re-points referencing paper-space entities to the new name")
    func renameLayoutRepointsEntities() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        // A paper-space entity bound to "Layout1" + a model-space entity (untouched).
        let paperID = d.add(EntityRecord(id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))),
            space: .paper, layoutName: "Layout1"))
        let modelID = d.add(line(Vector(0, 0), Vector(2, 0)))

        #expect(d.renameLayout(from: "Layout1", to: "Plan") == true)
        #expect(d.hasLayout("Plan"))
        #expect(!d.hasLayout("Layout1"))
        // The paper-space entity followed the rename; the model entity is untouched.
        #expect(d.entity(paperID)?.layoutName == "Plan")
        #expect(d.entity(paperID)?.space == .paper)
        #expect(d.entity(modelID)?.layoutName == nil)
        #expect(d.entity(modelID)?.space == .model)
    }

    @Test("renameLayout rejects an absent source or a taken target name")
    func renameLayoutRejects() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "A"))
        d.addLayout(Layout(name: "B", tabOrder: 1))
        #expect(d.renameLayout(from: "ZZZ", to: "X") == false)  // source absent
        #expect(d.renameLayout(from: "A", to: "B") == false)    // target taken
        #expect(d.renameLayout(from: "A", to: "   ") == false)  // blank target
        // A pure case-change of the SAME layout is allowed.
        #expect(d.renameLayout(from: "A", to: "a") == true)
        #expect(d.layout(named: "A")?.name == "a")
    }

    // MARK: - Undo / redo of the layout mutators

    @Test("addLayout is undoable (one ⌘Z removes it; redo re-adds)")
    func addLayoutUndoable() {
        let d = CADDrawing()
        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        d.addLayout(Layout(name: "L"))
        um.endUndoGrouping()
        #expect(d.hasLayout("L"))

        um.undo()
        #expect(!d.hasLayout("L"))
        #expect(d.layouts.isEmpty)

        um.redo()
        #expect(d.hasLayout("L"))
    }

    @Test("removeLayout + renameLayout are undoable (entity re-point reverses too)")
    func removeAndRenameUndoable() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        let paperID = d.add(EntityRecord(id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))),
            space: .paper, layoutName: "Layout1"))

        let um = testUndoManager()
        d.undoManager = um

        // Rename, then undo — the layout name AND the entity's layoutName revert.
        um.beginUndoGrouping()
        #expect(d.renameLayout(from: "Layout1", to: "Plan") == true)
        um.endUndoGrouping()
        #expect(d.entity(paperID)?.layoutName == "Plan")
        um.undo()
        #expect(d.hasLayout("Layout1"))
        #expect(d.entity(paperID)?.layoutName == "Layout1")

        // Remove, then undo — the sheet comes back.
        um.beginUndoGrouping()
        #expect(d.removeLayout(name: "Layout1") == true)
        um.endUndoGrouping()
        #expect(!d.hasLayout("Layout1"))
        um.undo()
        #expect(d.hasLayout("Layout1"))
    }

    @Test("a no-op layout mutation registers no undo")
    func noOpLayoutMutationNoUndo() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "L"))
        let um = testUndoManager()
        d.undoManager = um
        // A duplicate add is a no-op (returns false) and must not register undo.
        #expect(d.addLayout(Layout(name: "L")) == false)
        #expect(um.canUndo == false)
    }

    // MARK: - load(...) carries layouts

    @Test("CADDrawing.load carries the layout table (ordered) and per-entity space")
    func loadCarriesLayoutsAndSpace() {
        let d = CADDrawing()
        let paper = EntityRecord(id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))),
            space: .paper, layoutName: "Layout1")
        let model = line(Vector(0, 0), Vector(2, 0), id: 2)
        d.load(entities: [paper, model],
               layers: LayerTable(),
               layouts: [Layout(name: "Layout2", tabOrder: 1),
                         Layout(name: "Layout1", tabOrder: 0)])
        // Ordered by tabOrder on load.
        #expect(d.layouts.map(\.name) == ["Layout1", "Layout2"])
        // Per-entity space survived the load.
        #expect(d.entity(EntityID(1))?.space == .paper)
        #expect(d.entity(EntityID(1))?.layoutName == "Layout1")
        #expect(d.entity(EntityID(2))?.space == .model)
    }

    // MARK: - DXFPayload ↔ CADDrawing round-trip

    @Test("DXFPayload → CADDrawing → DXFPayload carries layouts + per-entity space")
    func payloadRoundTripCarriesLayoutsAndSpace() {
        let paper = EntityRecord(id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0))),
            space: .paper, layoutName: "Layout1")
        let model = line(Vector(0, 0), Vector(3, 0), id: 2)
        let layout = Layout(name: "Layout1", tabOrder: 0,
                            page: PageDescriptor(widthMM: 297, heightMM: 210,
                                                 marginMM: 5, plotScale: .ratio(1)))
        let payload = DXFPayload(entities: [paper, model],
                                 layers: LayerTable(),
                                 layouts: [layout])

        // Forward: payload → live drawing.
        let drawing = CADDrawing.make(from: payload)
        #expect(drawing.layouts == [layout])
        #expect(drawing.entity(EntityID(1))?.space == .paper)
        #expect(drawing.entity(EntityID(1))?.layoutName == "Layout1")
        #expect(drawing.entity(EntityID(2))?.space == .model)

        // Back: live drawing → payload snapshot. The whole value model round-trips.
        let snapshot = drawing.payloadSnapshot
        #expect(snapshot.layouts == [layout])
        #expect(snapshot.entities.count == 2)
        let paperBack = try! #require(snapshot.entities.first { $0.id == EntityID(1) })
        #expect(paperBack.space == .paper)
        #expect(paperBack.layoutName == "Layout1")
        let modelBack = try! #require(snapshot.entities.first { $0.id == EntityID(2) })
        #expect(modelBack.space == .model)
        #expect(modelBack.layoutName == nil)
        // Full payload equality (Equatable) confirms NOTHING else regressed.
        #expect(snapshot == payload)
    }

    @Test("an empty / model-only payload round-trips with no layouts (unaffected)")
    func modelOnlyPayloadUnaffected() {
        let payload = DXFPayload(entities: [line(Vector(0, 0), Vector(1, 0), id: 1)],
                                 layers: LayerTable())
        let drawing = CADDrawing.make(from: payload)
        #expect(drawing.layouts.isEmpty)
        #expect(drawing.entity(EntityID(1))?.space == .model)
        #expect(drawing.payloadSnapshot == payload)
        #expect(drawing.payloadSnapshot.layouts.isEmpty)
    }
}
