//
//  TableObject.swift
//  CADEngine
//
//  The TABLE OBJECT (Wave 2b — engine, UNWIRED): an ACAD_TABLE-style grid of text
//  cells, modeled as ADDITIVE document state — a separate `CADDrawing.tables` list,
//  NOT a new `EntityKind` case (the deliberate decision, decision-log Wave 2b: a new
//  enum case is a serialized critical section over ~28 exhaustive switches; an
//  additive list — exactly like `Layout.viewports` and the constraint table — keeps
//  the table feature off that hot path).
//
//  Per ADR-001 every type here is a pure VALUE struct holding only DEFINING data:
//  the grid dimensions, per-row/col sizes, the cell text + alignment, a table style,
//  and basic cell MERGE spans. The drawn graphic (grid lines + placed cell text) is
//  produced ON DEMAND by `TableGeometry.materialize` (`TableGeometry.swift`), never
//  stored — the same compute-on-resolve contract every entity follows.
//
//  Coordinate convention (AutoCAD ACAD_TABLE): `position` is the table's TOP-LEFT
//  corner; ROWS stack DOWNWARD (row 0 at the top, +row ⇒ −Y) and COLUMNS run to the
//  RIGHT (col 0 at the left, +col ⇒ +X). World units throughout (f64).
//
//  Codable with the project's additive back-compat idiom (`decodeIfPresent ?? def`)
//  so the table round-trips through the Codable document payload and an older payload
//  (or a partially-written table) loads with sensible defaults.
//
//  DEFERRED (documented, later waves): per-cell FIELDS (a cell stays plain text in
//  the MVP — a `FieldRun`-bearing cell is a later wave); the render-collection
//  wiring (iterating `drawing.tables` at resolve time lives in CanvasModel — the
//  WIRE-WAVE); DXF persistence (Wave 6 — written as exploded LINE + TEXT, since
//  libdxfrw drops ACAD_TABLE on read, a confirmed dead-end); nested / MLINESTYLE-like
//  style tables; and cell formulas.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Cell alignment (the 9-way grid anchor, DXF ACAD_TABLE cell alignment)

/// Where a cell's text is anchored within its rectangle — the 9-way grid AutoCAD's
/// ACAD_TABLE uses (DXF cell `alignment` code 170: 1=TopLeft … 9=BottomRight). The
/// horizontal/vertical parts drive the `TextData.hAlign`/`vAlign` the materializer
/// builds, and the cell's anchor world point. Pure value enum; round-trips via the
/// raw DXF integer so a future DXF write maps directly.
public enum TableCellAlignment: Int, Sendable, Hashable, Codable, CaseIterable {
    case topLeft = 1
    case topCenter = 2
    case topRight = 3
    case middleLeft = 4
    case middleCenter = 5
    case middleRight = 6
    case bottomLeft = 7
    case bottomCenter = 8
    case bottomRight = 9

    /// The horizontal component (left / center / right).
    public enum Horizontal: Sendable, Hashable { case left, center, right }
    /// The vertical component (top / middle / bottom).
    public enum Vertical: Sendable, Hashable { case top, middle, bottom }

    /// The horizontal half of the 9-way anchor.
    public var horizontal: Horizontal {
        switch self {
        case .topLeft, .middleLeft, .bottomLeft:       return .left
        case .topCenter, .middleCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight:    return .right
        }
    }

    /// The vertical half of the 9-way anchor.
    public var vertical: Vertical {
        switch self {
        case .topLeft, .topCenter, .topRight:          return .top
        case .middleLeft, .middleCenter, .middleRight: return .middle
        case .bottomLeft, .bottomCenter, .bottomRight: return .bottom
        }
    }
}

// MARK: - Table style (the document-default cell look)

/// The TABLE-WIDE style — the defaults a cell falls back to (its text height, its
/// alignment) plus the grid's border on/off + line width. The value-type analog of
/// the renderer-relevant subset of a DXF TABLESTYLE; deliberately FLAT (no nested
/// per-row "title/header/data" style classes — that is a later wave). A cell that
/// carries no per-cell text-height override inherits `defaultTextHeight`; a cell with
/// no explicit alignment uses `defaultAlignment`.
public struct TableStyle: Sendable, Hashable, Codable {
    /// The cell text cap height (world units) a cell with no per-cell override uses.
    public var defaultTextHeight: Double
    /// The cell text anchor a cell with no explicit alignment uses.
    public var defaultAlignment: TableCellAlignment
    /// Whether grid lines (the outer border + interior separators) are drawn at all.
    /// `false` ⇒ the materializer emits NO grid polylines (text-only table).
    public var bordersVisible: Bool
    /// The grid line width (world units) — carried for the materializer/renderer; a
    /// `<= 0` value means "use the renderer's hairline default".
    public var borderWidth: Double
    /// The text-style/font base name handed to the shared text path (`TextData.styleName`);
    /// `nil` ⇒ the font provider's default font.
    public var textStyleName: String?

    public init(
        defaultTextHeight: Double = 2.5,
        defaultAlignment: TableCellAlignment = .middleCenter,
        bordersVisible: Bool = true,
        borderWidth: Double = 0,
        textStyleName: String? = nil
    ) {
        self.defaultTextHeight = defaultTextHeight
        self.defaultAlignment = defaultAlignment
        self.bordersVisible = bordersVisible
        self.borderWidth = borderWidth
        self.textStyleName = textStyleName
    }

    // Additive back-compat: an older/partial payload decodes missing fields to the
    // defaults (the project's `decodeIfPresent ?? def` idiom).
    private enum CodingKeys: String, CodingKey {
        case defaultTextHeight, defaultAlignment, bordersVisible, borderWidth, textStyleName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultTextHeight = try c.decodeIfPresent(Double.self, forKey: .defaultTextHeight) ?? 2.5
        defaultAlignment = try c.decodeIfPresent(TableCellAlignment.self, forKey: .defaultAlignment) ?? .middleCenter
        bordersVisible = try c.decodeIfPresent(Bool.self, forKey: .bordersVisible) ?? true
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        textStyleName = try c.decodeIfPresent(String.self, forKey: .textStyleName)
    }
}

// MARK: - Cell

/// One TABLE CELL (DXF ACAD_TABLE cell). Pure value type holding only the defining
/// data: the text, an optional per-cell alignment + text-height override, and the
/// cell's MERGE span. The drawn text is produced on demand by `TableGeometry`
/// through the SHARED text path (no second text layout) — the cell never stores laid
/// out glyphs.
///
/// ## Merge model (the off-by-one correctness case the materializer tests cover)
/// A merged region is described entirely on its TOP-LEFT ANCHOR cell: that cell's
/// `rowSpan`/`colSpan` say how many rows × cols it covers (`1`×`1` is an ordinary,
/// un-merged cell). Every other cell inside that region is marked `covered` (it draws
/// no text and contributes no NEW grid edges). The materializer honors the span so the
/// INTERIOR separators that would slice through a merged region are suppressed (the
/// border around the whole region still draws). Keeping the span on the anchor + a
/// boolean on the covered cells means a merge is a pure data edit — no structural
/// reshaping of the `cells` matrix.
public struct TableCell: Sendable, Hashable, Codable {
    /// The cell's text. MVP keeps this a plain `String` (a future wave layers a
    /// `FieldRun` here for auto-updating fields — see the file header).
    public var text: String
    /// A per-cell alignment override; `nil` ⇒ inherit `TableStyle.defaultAlignment`.
    public var alignment: TableCellAlignment?
    /// A per-cell text cap height (world units); `nil` ⇒ inherit `TableStyle.defaultTextHeight`.
    public var textHeight: Double?
    /// How many ROWS this anchor cell spans (≥ 1). `1` is an un-merged cell.
    public var rowSpan: Int
    /// How many COLS this anchor cell spans (≥ 1). `1` is an un-merged cell.
    public var colSpan: Int
    /// `true` ⇒ this cell is COVERED by a neighboring merge anchor: it draws no text
    /// and emits no interior separators. (The anchor of a merge keeps `covered == false`.)
    public var covered: Bool

    public init(
        text: String = "",
        alignment: TableCellAlignment? = nil,
        textHeight: Double? = nil,
        rowSpan: Int = 1,
        colSpan: Int = 1,
        covered: Bool = false
    ) {
        self.text = text
        self.alignment = alignment
        self.textHeight = textHeight
        self.rowSpan = Swift.max(1, rowSpan)
        self.colSpan = Swift.max(1, colSpan)
        self.covered = covered
    }

    /// Whether this cell is a MERGE ANCHOR (spans more than one row or column).
    public var isMergeAnchor: Bool { rowSpan > 1 || colSpan > 1 }

    private enum CodingKeys: String, CodingKey {
        case text, alignment, textHeight, rowSpan, colSpan, covered
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        alignment = try c.decodeIfPresent(TableCellAlignment.self, forKey: .alignment)
        textHeight = try c.decodeIfPresent(Double.self, forKey: .textHeight)
        rowSpan = Swift.max(1, try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1)
        colSpan = Swift.max(1, try c.decodeIfPresent(Int.self, forKey: .colSpan) ?? 1)
        covered = try c.decodeIfPresent(Bool.self, forKey: .covered) ?? false
    }
}

// MARK: - Table object

/// A TABLE — a grid of text cells (ACAD_TABLE). Pure value type (ADR-001) carrying
/// the defining grid: its world `position` (TOP-LEFT corner), the row/col counts, the
/// per-row heights + per-col widths (world units), the row-major `cells` matrix, and
/// the `TableStyle`. Identity is a stable `UUID` (the table list keys off it, the same
/// way the constraint table keys off `Constraint.id`) so add/remove/update are id-keyed.
///
/// INVARIANT (normalized on init + decode): `rowHeights.count == rows`,
/// `colWidths.count == cols`, and `cells` is exactly `rows × cols` (row-major). The
/// initializer pads/truncates ragged input to these shapes so the materializer can
/// index without bounds checks. A degenerate table (0 rows and/or 0 cols) is allowed
/// and materializes to nothing (the safety case the geometry tests cover).
public struct TableObject: Sendable, Hashable, Codable, Identifiable {
    /// Stable identity (the `CADDrawing.tables` list keys add/remove/update off this).
    public var id: UUID
    /// The table's world TOP-LEFT corner (the origin of the grid; +X right, −Y down).
    public var position: Vector
    /// Row count (≥ 0). Rows stack DOWNWARD from `position`.
    public var rows: Int
    /// Column count (≥ 0). Columns run RIGHT from `position`.
    public var cols: Int
    /// Per-row heights (world units), `rowHeights.count == rows` (normalized).
    public var rowHeights: [Double]
    /// Per-column widths (world units), `colWidths.count == cols` (normalized).
    public var colWidths: [Double]
    /// The cells in ROW-MAJOR order: `cells[r][c]`, `cells.count == rows`, each row
    /// `cells[r].count == cols` (normalized).
    public var cells: [[TableCell]]
    /// The table-wide style (default cell look + grid borders).
    public var style: TableStyle

    /// The default size used to pad a row/col when the caller supplies no explicit
    /// size (and a sane fallback for a non-positive size).
    public static let defaultRowHeight: Double = 9.0
    public static let defaultColWidth: Double = 30.0

    public init(
        id: UUID = UUID(),
        position: Vector,
        rows: Int,
        cols: Int,
        rowHeights: [Double] = [],
        colWidths: [Double] = [],
        cells: [[TableCell]] = [],
        style: TableStyle = TableStyle()
    ) {
        self.id = id
        self.position = position
        let r = Swift.max(0, rows)
        let cc = Swift.max(0, cols)
        self.rows = r
        self.cols = cc
        self.style = style
        self.rowHeights = Self.normalizedSizes(rowHeights, count: r, fallback: Self.defaultRowHeight)
        self.colWidths = Self.normalizedSizes(colWidths, count: cc, fallback: Self.defaultColWidth)
        self.cells = Self.normalizedCells(cells, rows: r, cols: cc)
    }

    // MARK: - Normalization

    /// Pads/truncates `sizes` to exactly `count`, replacing any non-finite or
    /// non-positive size with `fallback` so the grid never collapses or NaNs.
    static func normalizedSizes(_ sizes: [Double], count: Int, fallback: Double) -> [Double] {
        var out = [Double](repeating: fallback, count: count)
        for i in 0..<count where i < sizes.count {
            let s = sizes[i]
            out[i] = (s.isFinite && s > 0) ? s : fallback
        }
        return out
    }

    /// Pads/truncates `cells` to exactly `rows × cols`, row-major, filling missing
    /// cells with an empty default cell.
    static func normalizedCells(_ cells: [[TableCell]], rows: Int, cols: Int) -> [[TableCell]] {
        var out = [[TableCell]](repeating: [TableCell](repeating: TableCell(), count: cols), count: rows)
        for r in 0..<rows where r < cells.count {
            let srcRow = cells[r]
            for c in 0..<cols where c < srcRow.count {
                out[r][c] = srcRow[c]
            }
        }
        return out
    }

    // MARK: - Reads

    /// Whether the table has no drawable grid (0 rows or 0 cols).
    public var isEmpty: Bool { rows == 0 || cols == 0 }

    /// The total table width (sum of column widths).
    public var totalWidth: Double { colWidths.reduce(0, +) }

    /// The total table height (sum of row heights).
    public var totalHeight: Double { rowHeights.reduce(0, +) }

    /// The cell at `(row, col)`, or `nil` if out of range.
    public func cell(row: Int, col: Int) -> TableCell? {
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return cells[row][col]
    }

    /// The world X of the LEFT edge of column `col` (`col == cols` ⇒ the right edge of
    /// the table). Columns run right from `position.x`.
    public func columnLeftX(_ col: Int) -> Double {
        var x = position.x
        for c in 0..<Swift.min(col, cols) { x += colWidths[c] }
        return x
    }

    /// The world Y of the TOP edge of row `row` (`row == rows` ⇒ the bottom edge of
    /// the table). Rows stack DOWNWARD, so the top edge DECREASES in Y.
    public func rowTopY(_ row: Int) -> Double {
        var y = position.y
        for r in 0..<Swift.min(row, rows) { y -= rowHeights[r] }
        return y
    }

    /// The world-space axis-aligned bounding box of the whole table grid (the outer
    /// rectangle). `nil` for a degenerate (0-row/0-col) table.
    public func worldBounds() -> AABB? {
        guard !isEmpty else { return nil }
        let left = position.x
        let right = position.x + totalWidth
        let top = position.y
        let bottom = position.y - totalHeight
        var box = AABB.empty
        box.expand(toInclude: Vector(left, bottom))
        box.expand(toInclude: Vector(right, top))
        return box
    }

    // MARK: - Codable (additive back-compat + re-normalization)

    private enum CodingKeys: String, CodingKey {
        case id, position, rows, cols, rowHeights, colWidths, cells, style
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedPos = try c.decode(Vector.self, forKey: .position)
        let decodedRows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        let decodedCols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        let decodedRowH = try c.decodeIfPresent([Double].self, forKey: .rowHeights) ?? []
        let decodedColW = try c.decodeIfPresent([Double].self, forKey: .colWidths) ?? []
        let decodedCells = try c.decodeIfPresent([[TableCell]].self, forKey: .cells) ?? []
        let decodedStyle = try c.decodeIfPresent(TableStyle.self, forKey: .style) ?? TableStyle()
        // Route through the designated init so a hand-edited / older payload with a
        // ragged grid is re-normalized to the rows×cols invariant on load.
        self.init(
            id: decodedID,
            position: decodedPos,
            rows: decodedRows,
            cols: decodedCols,
            rowHeights: decodedRowH,
            colWidths: decodedColW,
            cells: decodedCells,
            style: decodedStyle
        )
    }
}
