//
//  TableGeometryTests.swift
//  CADEngineTests
//
//  Unit tests for the TABLE MATERIALIZER (Wave 2b): `TableGeometry.materialize` —
//  grid line count/positions for a plain table, merged-span correctness (including
//  the spanned-separator off-by-one), cell-text placement + alignment, and degenerate
//  (0-row/0-col) safety.
//

import XCTest
@testable import CADEngine

final class TableGeometryTests: XCTestCase {

    private let eps = 1e-9

    /// A vertical 2-point segment at world x, spanning [yLow, yHigh] (order-agnostic).
    private func isVertical(_ pl: ResolvedPolyline, x: Double) -> Bool {
        pl.points.count == 2 && abs(pl.points[0].x - x) < eps && abs(pl.points[1].x - x) < eps
    }
    /// A horizontal 2-point segment at world y.
    private func isHorizontal(_ pl: ResolvedPolyline, y: Double) -> Bool {
        pl.points.count == 2 && abs(pl.points[0].y - y) < eps && abs(pl.points[1].y - y) < eps
    }

    /// A plain MxN table at the origin with uniform cell sizes.
    private func plainTable(rows: Int, cols: Int, w: Double = 10, h: Double = 5,
                            position: Vector = Vector(0, 0)) -> TableObject {
        TableObject(
            position: position,
            rows: rows, cols: cols,
            rowHeights: [Double](repeating: h, count: rows),
            colWidths: [Double](repeating: w, count: cols)
        )
    }

    // MARK: - Plain grid line count + positions

    func testPlainGridLineCount() {
        // A 2x3 grid: 4 outer border edges + interior separators.
        //   interior vertical separators: (cols-1)=2 boundaries × rows=2 segments = 4
        //   interior horizontal separators: (rows-1)=1 boundary × cols=3 segments = 3
        // total = 4 + 4 + 3 = 11.
        let m = TableGeometry.materialize(plainTable(rows: 2, cols: 3))
        XCTAssertEqual(m.lines.count, 11)
    }

    func testSingleCellTableIsJustTheBorder() {
        // 1x1 — no interior separators, only the 4-edge outer border.
        let m = TableGeometry.materialize(plainTable(rows: 1, cols: 1))
        XCTAssertEqual(m.lines.count, 4)
    }

    func testOuterBorderSpansFullExtent() {
        // 2 cols × 10 wide = 20; 2 rows × 5 high = 10. Top-left at origin ⇒ the table
        // occupies x∈[0,20], y∈[-10,0].
        let m = TableGeometry.materialize(plainTable(rows: 2, cols: 2))
        // The top edge is a horizontal segment at y == 0 from x 0 to 20.
        let topEdges = m.lines.filter { isHorizontal($0, y: 0) }
        XCTAssertTrue(topEdges.contains { pl in
            let xs = Set(pl.points.map { ($0.x * 1e6).rounded() / 1e6 })
            return xs == Set([0, 20])
        }, "expected a full-width top border edge")
        // The bottom edge at y == -10.
        XCTAssertTrue(m.lines.contains { isHorizontal($0, y: -10) })
        // The right edge at x == 20.
        XCTAssertTrue(m.lines.contains { isVertical($0, x: 20) })
    }

    func testInteriorSeparatorsAtCellBoundaries() {
        // 2x2, 10 wide × 5 high. The single interior vertical boundary sits at x == 10;
        // the single interior horizontal boundary at y == -5.
        let m = TableGeometry.materialize(plainTable(rows: 2, cols: 2))
        let interiorV = m.lines.filter { isVertical($0, x: 10) }
        XCTAssertEqual(interiorV.count, 2)   // one per row
        let interiorH = m.lines.filter { isHorizontal($0, y: -5) }
        XCTAssertEqual(interiorH.count, 2)   // one per column
    }

    func testNonUniformColumnWidthsAndRowHeights() {
        // cols [10, 30], rows [5, 9] ⇒ interior vertical boundary at x == 10; interior
        // horizontal boundary at y == -5; right edge at x == 40; bottom at y == -14.
        let t = TableObject(position: Vector(0, 0), rows: 2, cols: 2,
                            rowHeights: [5, 9], colWidths: [10, 30])
        let m = TableGeometry.materialize(t)
        XCTAssertTrue(m.lines.contains { isVertical($0, x: 10) })
        XCTAssertTrue(m.lines.contains { isVertical($0, x: 40) })   // right outer
        XCTAssertTrue(m.lines.contains { isHorizontal($0, y: -5) })
        XCTAssertTrue(m.lines.contains { isHorizontal($0, y: -14) }) // bottom outer
    }

    func testBordersHiddenEmitsNoLines() {
        var t = plainTable(rows: 3, cols: 3)
        t.style.bordersVisible = false
        let m = TableGeometry.materialize(t)
        XCTAssertTrue(m.lines.isEmpty)
    }

    func testPositionOffsetTranslatesGrid() {
        let m = TableGeometry.materialize(plainTable(rows: 1, cols: 1, w: 10, h: 5,
                                                     position: Vector(100, 200)))
        // The 1x1 table at (100,200) occupies x∈[100,110], y∈[195,200].
        XCTAssertTrue(m.lines.contains { isHorizontal($0, y: 200) })
        XCTAssertTrue(m.lines.contains { isHorizontal($0, y: 195) })
        XCTAssertTrue(m.lines.contains { isVertical($0, x: 100) })
        XCTAssertTrue(m.lines.contains { isVertical($0, x: 110) })
    }

    // MARK: - Merge spans (the off-by-one correctness case)

    func testHorizontalMergeSuppressesInteriorVerticalSeparator() {
        // 2x2; merge the TOP row (anchor (0,0) spans 1 row × 2 cols). The interior
        // vertical boundary at x == 10 should now have only ONE segment (the bottom
        // row, r==1) — the top-row segment is suppressed because (0,0) and (0,1) share
        // the merge anchor. Plain count would be 2.
        var t = plainTable(rows: 2, cols: 2)
        t.cells[0][0] = TableCell(text: "merged", colSpan: 2)
        t.cells[0][1] = TableCell(covered: true)
        let m = TableGeometry.materialize(t)
        let interiorV = m.lines.filter { isVertical($0, x: 10) }
        XCTAssertEqual(interiorV.count, 1, "the merged top row must drop its interior vertical separator")
        // The surviving segment is the BOTTOM row band: y∈[-10,-5].
        let seg = interiorV[0]
        let ys = Set(seg.points.map { ($0.y * 1e6).rounded() / 1e6 })
        XCTAssertEqual(ys, Set([-5, -10]))
    }

    func testVerticalMergeSuppressesInteriorHorizontalSeparator() {
        // 2x2; merge the LEFT column (anchor (0,0) spans 2 rows × 1 col). The interior
        // horizontal boundary at y == -5 should have only ONE segment (the right
        // column, c==1) — the left-column segment is suppressed.
        var t = plainTable(rows: 2, cols: 2)
        t.cells[0][0] = TableCell(text: "tall", rowSpan: 2)
        t.cells[1][0] = TableCell(covered: true)
        let m = TableGeometry.materialize(t)
        let interiorH = m.lines.filter { isHorizontal($0, y: -5) }
        XCTAssertEqual(interiorH.count, 1)
        // The surviving segment is the RIGHT column band: x∈[10,20].
        let xs = Set(interiorH[0].points.map { ($0.x * 1e6).rounded() / 1e6 })
        XCTAssertEqual(xs, Set([10, 20]))
    }

    func testBlockMergeSuppressesAllInteriorSeparatorsInsideRegion() {
        // 3x3; merge the top-left 2x2 block (anchor (0,0), rowSpan 2 × colSpan 2). All
        // interior separators WITHIN that block must be suppressed; separators on the
        // block's boundary with the un-merged cells remain.
        var t = plainTable(rows: 3, cols: 3)  // 10 wide, 5 high uniform
        t.cells[0][0] = TableCell(text: "BLK", rowSpan: 2, colSpan: 2)
        t.cells[0][1] = TableCell(covered: true)
        t.cells[1][0] = TableCell(covered: true)
        t.cells[1][1] = TableCell(covered: true)
        let m = TableGeometry.materialize(t)

        // Plain 3x3 counts: outer 4, interior V = 2 boundaries × 3 rows = 6, interior H
        // = 2 boundaries × 3 cols = 6 ⇒ 16 total. The 2x2 merge drops:
        //   interior V boundary at x==10, rows 0 and 1 (rows inside the block): -2
        //   interior H boundary at y==-5, cols 0 and 1 (cols inside the block): -2
        // ⇒ 16 - 4 = 12.
        XCTAssertEqual(m.lines.count, 12)

        // No interior vertical separator at x==10 inside the block's row band: the only
        // surviving x==10 interior segment is row 2 (y∈[-15,-10]).
        let interiorVat10 = m.lines.filter { isVertical($0, x: 10) }
        XCTAssertEqual(interiorVat10.count, 1)
        let ysV = Set(interiorVat10[0].points.map { ($0.y * 1e6).rounded() / 1e6 })
        XCTAssertEqual(ysV, Set([-10, -15]))

        // Similarly the only surviving interior horizontal at y==-5 is col 2 (x∈[20,30]).
        let interiorHat5 = m.lines.filter { isHorizontal($0, y: -5) }
        XCTAssertEqual(interiorHat5.count, 1)
        let xsH = Set(interiorHat5[0].points.map { ($0.x * 1e6).rounded() / 1e6 })
        XCTAssertEqual(xsH, Set([20, 30]))
    }

    func testMergeAnchorTextSpansMergedRectangleCenter() {
        // A horizontally-merged anchor's center anchor sits at the CENTER of the MERGED
        // rectangle, not the single cell. 1x2 merged at the origin, 10 wide each ⇒
        // merged rect x∈[0,20]; middleCenter anchor x == 10.
        var t = plainTable(rows: 1, cols: 2)
        t.cells[0][0] = TableCell(text: "wide", alignment: .middleCenter, colSpan: 2)
        t.cells[0][1] = TableCell(covered: true)
        let m = TableGeometry.materialize(t)
        XCTAssertEqual(m.cellTexts.count, 1)
        XCTAssertEqual(m.cellTexts[0].anchor.x, 10, accuracy: eps)
    }

    // MARK: - Cell text placement + alignment

    func testCellTextOnlyForNonEmptyNonCoveredCells() {
        var t = plainTable(rows: 2, cols: 2)
        t.cells[0][0].text = "A"
        t.cells[1][1].text = "B"
        // (0,1) and (1,0) stay empty ⇒ no text.
        let m = TableGeometry.materialize(t)
        XCTAssertEqual(m.cellTexts.count, 2)
        XCTAssertEqual(Set(m.cellTexts.map(\.text.text)), Set(["A", "B"]))
    }

    func testCoveredCellTextIsIgnored() {
        var t = plainTable(rows: 1, cols: 2)
        t.cells[0][0] = TableCell(text: "anchor", colSpan: 2)
        t.cells[0][1] = TableCell(text: "ghost", covered: true)  // covered ⇒ skipped
        let m = TableGeometry.materialize(t)
        XCTAssertEqual(m.cellTexts.count, 1)
        XCTAssertEqual(m.cellTexts[0].text.text, "anchor")
    }

    func testCellAlignmentMapsToTextDataAndAnchor() {
        // A single 10×5 cell at the origin: x∈[0,10], y∈[-5,0].
        var t = plainTable(rows: 1, cols: 1)
        t.cells[0][0] = TableCell(text: "X", alignment: .topLeft)
        let topLeft = TableGeometry.materialize(t).cellTexts[0]
        XCTAssertEqual(topLeft.text.hAlign, .left)
        XCTAssertEqual(topLeft.text.vAlign, .top)
        XCTAssertEqual(topLeft.anchor.x, 0, accuracy: eps)
        XCTAssertEqual(topLeft.anchor.y, 0, accuracy: eps)   // top edge

        t.cells[0][0] = TableCell(text: "X", alignment: .bottomRight)
        let bottomRight = TableGeometry.materialize(t).cellTexts[0]
        XCTAssertEqual(bottomRight.text.hAlign, .right)
        XCTAssertEqual(bottomRight.text.vAlign, .bottom)
        XCTAssertEqual(bottomRight.anchor.x, 10, accuracy: eps)
        XCTAssertEqual(bottomRight.anchor.y, -5, accuracy: eps)  // bottom edge

        t.cells[0][0] = TableCell(text: "X", alignment: .middleCenter)
        let mid = TableGeometry.materialize(t).cellTexts[0]
        XCTAssertEqual(mid.anchor.x, 5, accuracy: eps)
        XCTAssertEqual(mid.anchor.y, -2.5, accuracy: eps)
    }

    func testCellInheritsStyleAlignmentAndHeightWhenNoOverride() {
        var t = plainTable(rows: 1, cols: 1)
        t.style.defaultAlignment = .bottomRight
        t.style.defaultTextHeight = 3.0
        t.cells[0][0] = TableCell(text: "Y")   // no per-cell alignment / height
        let placed = TableGeometry.materialize(t).cellTexts[0]
        XCTAssertEqual(placed.text.hAlign, .right)
        XCTAssertEqual(placed.text.vAlign, .bottom)
        XCTAssertEqual(placed.text.height, 3.0, accuracy: eps)
    }

    func testPerCellTextHeightOverridesStyle() {
        var t = plainTable(rows: 1, cols: 1)
        t.style.defaultTextHeight = 2.5
        t.cells[0][0] = TableCell(text: "Z", textHeight: 7.5)
        let placed = TableGeometry.materialize(t).cellTexts[0]
        XCTAssertEqual(placed.text.height, 7.5, accuracy: eps)
    }

    func testCellTextCarriesTableFontName() {
        var t = plainTable(rows: 1, cols: 1)
        t.style.textStyleName = "romans"
        t.cells[0][0] = TableCell(text: "F")
        let placed = TableGeometry.materialize(t).cellTexts[0]
        XCTAssertEqual(placed.text.styleName, "romans")
    }

    // MARK: - Degenerate / safety

    func testZeroRowTableMaterializesToNothing() {
        let m = TableGeometry.materialize(TableObject(position: Vector(0, 0), rows: 0, cols: 3))
        XCTAssertTrue(m.lines.isEmpty)
        XCTAssertTrue(m.cellTexts.isEmpty)
    }

    func testZeroColTableMaterializesToNothing() {
        let m = TableGeometry.materialize(TableObject(position: Vector(0, 0), rows: 3, cols: 0))
        XCTAssertTrue(m.lines.isEmpty)
        XCTAssertTrue(m.cellTexts.isEmpty)
    }

    func testNegativeDimensionsClampToEmpty() {
        let t = TableObject(position: Vector(0, 0), rows: -2, cols: -5)
        XCTAssertEqual(t.rows, 0)
        XCTAssertEqual(t.cols, 0)
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.worldBounds())
        XCTAssertTrue(TableGeometry.materialize(t).lines.isEmpty)
    }

    func testRaggedSizesAndCellsAreNormalized() {
        // Supply too-few sizes + a ragged cell matrix; the init pads to rows×cols and
        // replaces non-positive sizes with the default so the grid never collapses.
        let t = TableObject(
            position: Vector(0, 0),
            rows: 2, cols: 2,
            rowHeights: [5],                 // missing the second row height
            colWidths: [10, -3],             // a non-positive width
            cells: [[TableCell(text: "only one cell")]]   // ragged
        )
        XCTAssertEqual(t.rowHeights.count, 2)
        XCTAssertEqual(t.colWidths.count, 2)
        XCTAssertEqual(t.cells.count, 2)
        XCTAssertEqual(t.cells[0].count, 2)
        XCTAssertEqual(t.cells[1].count, 2)
        // The non-positive width was replaced by the default (so totalWidth is finite > 0).
        XCTAssertGreaterThan(t.totalWidth, 0)
        XCTAssertTrue(t.totalWidth.isFinite)
    }

    func testWorldBoundsMatchesOuterRectangle() {
        let t = plainTable(rows: 2, cols: 3, w: 10, h: 5, position: Vector(1, 2))
        // width = 30, height = 10 ⇒ x∈[1,31], y∈[-8,2].
        guard let box = t.worldBounds() else { return XCTFail("expected a box") }
        XCTAssertEqual(box.min.x, 1, accuracy: eps)
        XCTAssertEqual(box.max.x, 31, accuracy: eps)
        XCTAssertEqual(box.min.y, -8, accuracy: eps)
        XCTAssertEqual(box.max.y, 2, accuracy: eps)
    }

    // MARK: - resolve(...) convenience (grid + shaped text via TextShaper)

    func testResolveConvenienceEmitsGridPolylines() {
        // The grid polylines flow through unchanged; the cell text is shaped via the
        // shared TextShaper using a real ResolveContext (a CADDrawing supplies one).
        let drawing = MainActor.assumeIsolated { CADDrawing() }
        let ctx = MainActor.assumeIsolated { drawing.makeResolveContext() }
        var t = plainTable(rows: 1, cols: 1)
        t.cells[0][0] = TableCell(text: "Hi")
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let geo = TableGeometry.resolve(t, pen: pen, ctx: ctx)
        // 4 outer-border segments at minimum (1x1 has only the border).
        XCTAssertGreaterThanOrEqual(geo.polylines.count, 4)
    }
}
