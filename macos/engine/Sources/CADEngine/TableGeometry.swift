//
//  TableGeometry.swift
//  CADEngine
//
//  The TABLE MATERIALIZER (Wave 2b — engine, UNWIRED): turns a `TableObject`'s
//  defining data (`TableObject.swift`) into renderable geometry ON DEMAND (ADR-001),
//  never stored on the table. It produces two things:
//
//    • the GRID — the outer border rectangle plus the interior row/column separators,
//      as `ResolvedPolyline`s (each a 2-point segment). Merge spans are honored: an
//      interior separator that would slice THROUGH a merged region is suppressed, so a
//      merged region reads as one open cell (the border around it still draws). This is
//      the key correctness case — the off-by-one on which spanned separators to drop —
//      and is exercised directly by the geometry tests.
//
//    • the CELL TEXT — one `TextData` per non-empty, non-covered cell, built at the
//      cell's 9-way ANCHOR point with the cell's alignment (`hAlign`/`vAlign`) + text
//      height. The materializer does NOT lay out glyphs itself: it hands back a
//      `TextData` that the renderer (the WIRE-WAVE) runs through the SHARED
//      `TextShaper` path every other text entity uses — there is no second text layout
//      here (the ADR-004 mandate). The convenience `resolve(...)` overload below DOES
//      run them through `TextShaper`, for callers that already hold a `ResolveContext`.
//
//  Coordinate convention matches `TableObject`: `position` is the TOP-LEFT corner;
//  rows stack DOWNWARD (+row ⇒ −Y), columns run RIGHT (+col ⇒ +X). World units (f64).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The pure table → geometry materializer. Stateless (an `enum` namespace) — every
/// output is a pure function of the input table (+ an optional pen / resolve context).
public enum TableGeometry {

    // MARK: - Output

    /// A placed cell text: the `TextData` to shape (already carrying the cell's
    /// alignment + height + the table's font name) and the world ANCHOR point the text
    /// is placed at (which equals `text.position`; surfaced separately so a caller can
    /// hit-test / debug the anchor without re-deriving it).
    public struct PlacedCellText: Sendable, Equatable {
        /// The (row, col) of the source cell (its merge ANCHOR cell when merged).
        public var row: Int
        public var col: Int
        /// The text entity to shape through the shared `TextShaper` path.
        public var text: TextData
        /// The world anchor point the text is placed at (== `text.position`).
        public var anchor: Vector

        public init(row: Int, col: Int, text: TextData, anchor: Vector) {
            self.row = row
            self.col = col
            self.text = text
            self.anchor = anchor
        }
    }

    /// The materialized table: grid line segments + placed cell texts.
    public struct Materialized: Sendable, Equatable {
        /// The grid as 2-point `ResolvedPolyline` segments (outer border + interior
        /// separators). Empty when borders are hidden or the table is degenerate.
        public var lines: [ResolvedPolyline]
        /// One placed text per non-empty, non-covered cell.
        public var cellTexts: [PlacedCellText]

        public init(lines: [ResolvedPolyline] = [], cellTexts: [PlacedCellText] = []) {
            self.lines = lines
            self.cellTexts = cellTexts
        }
    }

    // MARK: - Public entry (data-only — the wire-wave runs the TextData through TextShaper)

    /// Materializes `table` into grid segments + placed cell `TextData`. The `pen` is
    /// applied to every grid segment (the renderer resolves the table's pen upstream —
    /// the engine module is view-free); defaults to a solid black hairline pen so the
    /// data-only path is usable headless. A degenerate (0-row/0-col) table, or one with
    /// borders hidden, yields no lines; an all-empty table yields no cell texts.
    public static func materialize(
        _ table: TableObject,
        pen: ResolvedPen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
    ) -> Materialized {
        guard !table.isEmpty else { return Materialized() }
        let anchors = regionAnchors(of: table)
        let lines = table.style.bordersVisible ? gridLines(of: table, anchors: anchors, pen: pen) : []
        let texts = cellTexts(of: table)
        return Materialized(lines: lines, cellTexts: texts)
    }

    /// Convenience for a caller that already holds a `ResolveContext`: materializes the
    /// grid AND shapes the cell `TextData` through the SHARED `TextShaper`, returning one
    /// merged `ResolvedGeometry` (grid polylines + the shaped text's polylines/fills).
    /// This is the form the render-collection wire-wave can drop straight into the
    /// renderer; it adds NO second text path (it calls `TextShaper.resolve`).
    public static func resolve(
        _ table: TableObject,
        pen: ResolvedPen,
        ctx: ResolveContext
    ) -> ResolvedGeometry {
        let m = materialize(table, pen: pen)
        var geo = ResolvedGeometry(polylines: m.lines)
        for placed in m.cellTexts {
            geo = geo.merged(with: TextShaper.resolve(placed.text, pen: pen, ctx: ctx))
        }
        return geo
    }

    // MARK: - Region anchors (the merge map)

    /// Maps every `(row, col)` to the `(row, col)` of the merge ANCHOR cell that owns
    /// it. An un-merged cell maps to itself; a covered cell maps to its anchor. This is
    /// the single source of truth the separator suppression reads: an interior edge
    /// between two adjacent cells is drawn IFF they map to DIFFERENT anchors.
    ///
    /// Built by walking the grid: each merge-anchor cell (`rowSpan`/`colSpan` > 1)
    /// claims its `rowSpan × colSpan` block (clamped to the grid). A cell already
    /// claimed by an earlier anchor is not re-claimed (first anchor wins — overlapping
    /// spans are malformed input and degrade gracefully). Any cell not claimed by an
    /// anchor block maps to itself.
    static func regionAnchors(of table: TableObject) -> [[(row: Int, col: Int)]] {
        let rows = table.rows, cols = table.cols
        // Start with every cell its own anchor.
        var map = [[(row: Int, col: Int)]]()
        map.reserveCapacity(rows)
        for r in 0..<rows {
            map.append((0..<cols).map { (row: r, col: $0) })
        }
        // Track which cells have already been claimed so a malformed overlap can't
        // double-claim (first anchor wins).
        var claimed = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let cell = table.cells[r][c]
                guard cell.isMergeAnchor, !cell.covered, !claimed[r][c] else { continue }
                let rEnd = Swift.min(rows, r + cell.rowSpan)
                let cEnd = Swift.min(cols, c + cell.colSpan)
                for rr in r..<rEnd {
                    for cc in c..<cEnd where !claimed[rr][cc] {
                        map[rr][cc] = (row: r, col: c)
                        claimed[rr][cc] = true
                    }
                }
            }
        }
        return map
    }

    // MARK: - Grid lines (outer border + merge-aware interior separators)

    /// Builds the grid as 2-point segments: the outer border (always, when visible)
    /// plus the interior vertical + horizontal separators, dropping any interior
    /// segment that lies INSIDE a merged region (both flanking cells share an anchor).
    static func gridLines(
        of table: TableObject,
        anchors: [[(row: Int, col: Int)]],
        pen: ResolvedPen
    ) -> [ResolvedPolyline] {
        let rows = table.rows, cols = table.cols
        var out: [ResolvedPolyline] = []

        // Precompute the world coordinates of every column boundary (cols+1 of them)
        // and every row boundary (rows+1 of them).
        var xs = [Double](repeating: 0, count: cols + 1)
        for c in 0...cols { xs[c] = table.columnLeftX(c) }
        var ys = [Double](repeating: 0, count: rows + 1)
        for r in 0...rows { ys[r] = table.rowTopY(r) }

        func segment(_ a: Vector, _ b: Vector) {
            out.append(ResolvedPolyline(points: [a, b], closed: false, pen: pen))
        }

        let left = xs[0], right = xs[cols], top = ys[0], bottom = ys[rows]

        // 1. Outer border (one closed-looking rectangle drawn as four edges so each
        //    edge is an independent 2-point segment — the renderer's line contract).
        segment(Vector(left, top), Vector(right, top))       // top
        segment(Vector(right, top), Vector(right, bottom))   // right
        segment(Vector(right, bottom), Vector(left, bottom)) // bottom
        segment(Vector(left, bottom), Vector(left, top))     // left

        // 2. Interior VERTICAL separators: for each interior column boundary `c`
        //    (1..<cols), draw the segment spanning each row `r` — UNLESS the cells to
        //    the left `(r, c-1)` and right `(r, c)` belong to the same merged region.
        if cols >= 2 {
            for c in 1..<cols {
                let x = xs[c]
                for r in 0..<rows where !sameRegion(anchors, r, c - 1, r, c) {
                    segment(Vector(x, ys[r]), Vector(x, ys[r + 1]))
                }
            }
        }

        // 3. Interior HORIZONTAL separators: for each interior row boundary `r`
        //    (1..<rows), draw the segment spanning each column `c` — UNLESS the cells
        //    above `(r-1, c)` and below `(r, c)` belong to the same merged region.
        if rows >= 2 {
            for r in 1..<rows {
                let y = ys[r]
                for c in 0..<cols where !sameRegion(anchors, r - 1, c, r, c) {
                    segment(Vector(xs[c], y), Vector(xs[c + 1], y))
                }
            }
        }

        return out
    }

    /// Whether two in-range cells map to the SAME merge-region anchor.
    private static func sameRegion(
        _ anchors: [[(row: Int, col: Int)]],
        _ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int
    ) -> Bool {
        let a = anchors[r1][c1]
        let b = anchors[r2][c2]
        return a.row == b.row && a.col == b.col
    }

    // MARK: - Cell text placement

    /// Builds the placed `TextData` for every non-empty cell that is a region ANCHOR
    /// (covered cells contribute nothing — their text, if any, is ignored: the anchor
    /// owns the merged region's text). Each text is anchored at the 9-way point of the
    /// cell's (possibly merged) rectangle, with `hAlign`/`vAlign` derived from the
    /// cell alignment, the resolved text height, and the table's font name.
    static func cellTexts(of table: TableObject) -> [PlacedCellText] {
        let rows = table.rows, cols = table.cols
        var out: [PlacedCellText] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let cell = table.cells[r][c]
                // Skip covered cells (a merge anchor owns the region's text) and empties.
                guard !cell.covered, !cell.text.isEmpty else { continue }

                // The (possibly merged) cell rectangle: from column c to c+colSpan and
                // row r to r+rowSpan, clamped to the grid.
                let cEnd = Swift.min(cols, c + cell.colSpan)
                let rEnd = Swift.min(rows, r + cell.rowSpan)
                let x0 = table.columnLeftX(c)
                let x1 = table.columnLeftX(cEnd)
                let y0 = table.rowTopY(r)            // top (larger Y)
                let y1 = table.rowTopY(rEnd)         // bottom (smaller Y)

                let align = cell.alignment ?? table.style.defaultAlignment
                let anchor = anchorPoint(x0: x0, x1: x1, top: y0, bottom: y1, align: align)
                let height = resolvedHeight(cell: cell, style: table.style)

                let text = TextData(
                    position: anchor,
                    height: height,
                    rotation: 0,
                    text: cell.text,
                    styleName: table.style.textStyleName,
                    hAlign: hAlign(for: align),
                    vAlign: vAlign(for: align)
                )
                out.append(PlacedCellText(row: r, col: c, text: text, anchor: anchor))
            }
        }
        return out
    }

    /// The world anchor point inside a cell rectangle for a 9-way alignment.
    /// `x0`/`x1` are the left/right edges; `top`/`bottom` are the top (larger Y) and
    /// bottom (smaller Y) edges.
    static func anchorPoint(
        x0: Double, x1: Double, top: Double, bottom: Double, align: TableCellAlignment
    ) -> Vector {
        let x: Double
        switch align.horizontal {
        case .left:   x = x0
        case .center: x = (x0 + x1) / 2
        case .right:  x = x1
        }
        let y: Double
        switch align.vertical {
        case .top:    y = top
        case .middle: y = (top + bottom) / 2
        case .bottom: y = bottom
        }
        return Vector(x, y)
    }

    /// The `TextData.hAlign` for a cell alignment's horizontal half.
    static func hAlign(for align: TableCellAlignment) -> TextHAlign {
        switch align.horizontal {
        case .left:   return .left
        case .center: return .center
        case .right:  return .right
        }
    }

    /// The `TextData.vAlign` for a cell alignment's vertical half.
    static func vAlign(for align: TableCellAlignment) -> TextVAlign {
        switch align.vertical {
        case .top:    return .top
        case .middle: return .middle
        case .bottom: return .bottom
        }
    }

    /// The cell's resolved text cap height: the per-cell override (when set + positive)
    /// else the table style's default (floored to a small positive value so a degenerate
    /// style height never collapses the text).
    static func resolvedHeight(cell: TableCell, style: TableStyle) -> Double {
        if let h = cell.textHeight, h.isFinite, h > 0 { return h }
        return (style.defaultTextHeight.isFinite && style.defaultTextHeight > 0)
            ? style.defaultTextHeight : TableObject.defaultRowHeight / 3
    }
}
