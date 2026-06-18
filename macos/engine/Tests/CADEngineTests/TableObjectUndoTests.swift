//
//  TableObjectUndoTests.swift
//  CADEngineTests
//
//  Unit tests for the TABLE-OBJECT document state (Wave 2b): the `CADDrawing`
//  undoable funnel (add / remove / update + ⌘Z / redo), the no-op-doesn't-pollute-undo
//  guard, the `load(...)` thread-through, and `TableObject`/`TableStyle`/`TableCell`
//  Codable round-trip + additive back-compat.
//

import XCTest
@testable import CADEngine

final class TableObjectUndoTests: XCTestCase {

    /// A small fixture table.
    private func fixture(text: String = "A") -> TableObject {
        var t = TableObject(position: Vector(1, 2), rows: 2, cols: 2,
                            rowHeights: [5, 5], colWidths: [10, 10])
        t.cells[0][0].text = text
        return t
    }

    /// An UndoManager configured for unit testing (manual grouping — matching the
    /// project's `ConstraintTableTests.testUndoManager` convention).
    @MainActor
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    // MARK: - Funnel: add / update / remove + undo / redo

    @MainActor
    func testAddUpdateRemoveWithUndo() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        let t = fixture()
        um.beginUndoGrouping(); XCTAssertTrue(drawing.addTable(t)); um.endUndoGrouping()
        XCTAssertEqual(drawing.tables.count, 1)
        XCTAssertEqual(drawing.table(t.id)?.cells[0][0].text, "A")

        // Update a cell (undoable, one group).
        var edited = t
        edited.cells[0][0].text = "B"
        um.beginUndoGrouping(); XCTAssertTrue(drawing.updateTable(edited)); um.endUndoGrouping()
        XCTAssertEqual(drawing.table(t.id)?.cells[0][0].text, "B")

        // Undo the edit → back to "A".
        um.undo()
        XCTAssertEqual(drawing.table(t.id)?.cells[0][0].text, "A")
        // Redo → "B" again.
        um.redo()
        XCTAssertEqual(drawing.table(t.id)?.cells[0][0].text, "B")

        // Remove (undoable), then undo restores it (at its last-edited value).
        um.beginUndoGrouping(); XCTAssertTrue(drawing.removeTable(t.id)); um.endUndoGrouping()
        XCTAssertTrue(drawing.tables.isEmpty)
        um.undo()
        XCTAssertEqual(drawing.tables.count, 1)
        XCTAssertEqual(drawing.table(t.id)?.cells[0][0].text, "B")
    }

    @MainActor
    func testAddRejectsDuplicateID() {
        let drawing = CADDrawing()
        let t = fixture()
        XCTAssertTrue(drawing.addTable(t))
        XCTAssertFalse(drawing.addTable(t))   // same id → rejected
        XCTAssertEqual(drawing.tables.count, 1)
    }

    @MainActor
    func testUpdateAbsentTableIsNoOp() {
        let drawing = CADDrawing()
        XCTAssertFalse(drawing.updateTable(fixture()))  // never added ⇒ no-op
        XCTAssertTrue(drawing.tables.isEmpty)
    }

    @MainActor
    func testRemoveAbsentTableIsNoOp() {
        let drawing = CADDrawing()
        XCTAssertFalse(drawing.removeTable(UUID()))
    }

    @MainActor
    func testNoOpUpdateDoesNotPolluteUndo() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        let t = fixture()
        um.beginUndoGrouping(); drawing.addTable(t); um.endUndoGrouping()
        let prior = drawing.tables

        // An identical update registers no undo (the funnel's unchanged-guard never
        // reaches `registerUndo`; with groupsByEvent=false a registration outside a
        // group would throw, so the absence of a crash + unchanged list proves the no-op).
        XCTAssertFalse(drawing.updateTable(t))
        XCTAssertEqual(drawing.tables, prior)
    }

    @MainActor
    func testMergeEditIsUndoable() {
        // Merging two cells is a plain value edit routed through updateTable, so it is
        // one undoable step.
        let drawing = CADDrawing()
        let um = testUndoManager()
        var t = fixture()
        drawing.addTable(t)
        drawing.undoManager = um

        var merged = t
        merged.cells[0][0] = TableCell(text: "merged", colSpan: 2)
        merged.cells[0][1] = TableCell(covered: true)
        um.beginUndoGrouping(); XCTAssertTrue(drawing.updateTable(merged)); um.endUndoGrouping()
        XCTAssertTrue(drawing.table(t.id)?.cells[0][0].isMergeAnchor ?? false)
        XCTAssertTrue(drawing.table(t.id)?.cells[0][1].covered ?? false)

        um.undo()
        XCTAssertFalse(drawing.table(t.id)?.cells[0][0].isMergeAnchor ?? true)
        XCTAssertFalse(drawing.table(t.id)?.cells[0][1].covered ?? true)
        // silence unused-warning on `t` mutation path
        t.cells[0][0].text = ""
    }

    // MARK: - load(...) thread-through

    @MainActor
    func testLoadCarriesTables() {
        let drawing = CADDrawing()
        let t = fixture(text: "loaded")
        drawing.load(entities: [], layers: LayerTable(), tables: [t])
        XCTAssertEqual(drawing.tables.count, 1)
        XCTAssertEqual(drawing.table(t.id)?.cells[0][0].text, "loaded")
    }

    @MainActor
    func testLoadDefaultsToNoTables() {
        let drawing = CADDrawing()
        drawing.addTable(fixture())
        // A load that omits `tables` clears them (existing callers are unchanged).
        drawing.load(entities: [], layers: LayerTable())
        XCTAssertTrue(drawing.tables.isEmpty)
    }

    // MARK: - Codable round-trip + back-compat

    func testTableCodableRoundTrip() throws {
        var t = TableObject(position: Vector(3, 7), rows: 2, cols: 3,
                            rowHeights: [4, 6], colWidths: [10, 20, 30])
        t.cells[0][0] = TableCell(text: "title", alignment: .topLeft, colSpan: 3)
        t.cells[0][1] = TableCell(covered: true)
        t.cells[0][2] = TableCell(covered: true)
        t.cells[1][0] = TableCell(text: "data", textHeight: 1.5)
        t.style = TableStyle(defaultTextHeight: 2.0, defaultAlignment: .bottomRight,
                             bordersVisible: false, borderWidth: 0.5, textStyleName: "iso")

        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(TableObject.self, from: data)
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.id, t.id)
        XCTAssertEqual(back.cells[0][0].colSpan, 3)
        XCTAssertEqual(back.cells[0][1].covered, true)
        XCTAssertEqual(back.cells[1][0].textHeight, 1.5)
        XCTAssertEqual(back.style.bordersVisible, false)
        XCTAssertEqual(back.style.textStyleName, "iso")
    }

    func testCellBackCompatDefaultsFromMinimalJSON() throws {
        // A cell serialized before the merge/override fields existed: only `text`.
        let json = #"{"text":"hi"}"#.data(using: .utf8)!
        let cell = try JSONDecoder().decode(TableCell.self, from: json)
        XCTAssertEqual(cell.text, "hi")
        XCTAssertNil(cell.alignment)
        XCTAssertNil(cell.textHeight)
        XCTAssertEqual(cell.rowSpan, 1)
        XCTAssertEqual(cell.colSpan, 1)
        XCTAssertFalse(cell.covered)
    }

    func testStyleBackCompatDefaultsFromEmptyJSON() throws {
        let style = try JSONDecoder().decode(TableStyle.self, from: #"{}"#.data(using: .utf8)!)
        XCTAssertEqual(style.defaultTextHeight, 2.5)
        XCTAssertEqual(style.defaultAlignment, .middleCenter)
        XCTAssertTrue(style.bordersVisible)
        XCTAssertEqual(style.borderWidth, 0)
        XCTAssertNil(style.textStyleName)
    }

    func testTableBackCompatNormalizesRaggedDecodedGrid() throws {
        // A hand-written / older payload with a ragged `cells` and too-few sizes decodes
        // back to the rows×cols invariant (routed through the designated init).
        let json = """
        {"position":{"x":0,"y":0,"z":0,"valid":true},
         "rows":2,"cols":2,
         "rowHeights":[5],
         "colWidths":[10],
         "cells":[[{"text":"a"}]]}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TableObject.self, from: json)
        XCTAssertEqual(t.rowHeights.count, 2)
        XCTAssertEqual(t.colWidths.count, 2)
        XCTAssertEqual(t.cells.count, 2)
        XCTAssertEqual(t.cells[0].count, 2)
        XCTAssertEqual(t.cells[1].count, 2)
        XCTAssertEqual(t.cells[0][0].text, "a")
        // A table with no `id` key still decodes (a fresh UUID is minted).
        XCTAssertNotNil(t.id)
    }

    func testCellAlignmentRawValuesAreStableDXFCodes() {
        // The 9-way alignment uses the DXF ACAD_TABLE integer codes 1..9 so a future
        // DXF write maps directly; lock the mapping.
        XCTAssertEqual(TableCellAlignment.topLeft.rawValue, 1)
        XCTAssertEqual(TableCellAlignment.middleCenter.rawValue, 5)
        XCTAssertEqual(TableCellAlignment.bottomRight.rawValue, 9)
    }
}
