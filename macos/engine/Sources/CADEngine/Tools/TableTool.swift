//
//  TableTool.swift
//  CADEngine
//
//  The TABLE INSERT tool (Wire-wave-1, tables half) — place a DEFAULT empty table
//  (a grid of rows × cols) at a clicked point. Ported in spirit from LibreCAD's
//  "Insert ▸ Table" action: the user picks ONE insertion point (the table's
//  TOP-LEFT corner) and a fresh `TableObject` is dropped there.
//
//  ## Why this tool is NOT a plain `ToolEdit`-emitting tool (decision — mirrors
//  ## CreateBlockTool)
//  A `ToolEdit` only expresses entity-level `.add` / `.replace` / `.remove`, and a
//  TABLE is NOT an `EntityKind` — it lives in `CADDrawing.tables` (off `EntityKind`,
//  exactly like paper-space viewports live in `Layout.viewports`). So this tool does
//  NOT emit `.commit` edits: it captures the picked insertion point into a
//  `pendingTable` REQUEST (a fully-built `TableObject`), and the app applies it
//  through the undoable model op `CADDrawing.addTable(_:)`. The static helper
//  `TableTool.apply(_:to:)` performs exactly that, so the whole flow is unit-testable
//  against a real `CADDrawing` WITHOUT the GUI.
//
//  Behavior (single-pick placement, like an INSERT of a default block):
//    - `.move`           → a small crosshair preview at the cursor (where the table's
//                          top-left corner will land).
//    - `.click`/`.value` → build the `pendingTable` at the (snapped) point and return
//                          `.finished`. The app reads `pendingTable` and adds it.
//    - `.commit` (Ret)   → place at the last cursor point (or the origin if none yet).
//    - `.cancel` (Esc)   → discard the request, `.finished`.
//    - `.backspace`      → no-op (single-pick placement — nothing to step back).
//
//  ## MVP scope
//  The default table is `defaultRows × defaultCols` (3 × 3) of EMPTY cells with the
//  default row/col sizes and the STANDARD table style (borders visible). EDITING the
//  cell text / resizing rows-cols / merging cells / table styles are the Inspector's
//  job in a later pass; placing + rendering + undo is the bar this wave targets.
//
//  PURE (the Tool contract): it never touches CADDrawing/Quadtree/GUI. It receives
//  already-snapped world points and records a value request the app applies via the
//  undoable model op (the CreateBlockTool template).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Table-insert tool. Click ONE point (the table's top-left corner)
/// to place a default empty grid; the tool records a `TableObject` the app adds via
/// the undoable `CADDrawing.addTable(_:)` model op. A table is NOT an `EntityKind`
/// (it lives in `CADDrawing.tables`), so this tool follows the `CreateBlockTool`
/// request/apply template rather than emitting `ToolEdit`s.
public struct TableTool: Tool {

    // MARK: - Default table geometry

    /// The default row count for a freshly-placed table (a small, useful grid).
    public static let defaultRows = 3
    /// The default column count for a freshly-placed table.
    public static let defaultCols = 3

    // MARK: - Configuration

    /// The number of rows the placed table gets (clamped to ≥ 1). Settable so a later
    /// options-bar pass can drive it; defaults to `defaultRows`.
    public var rows: Int
    /// The number of columns the placed table gets (clamped to ≥ 1). Settable so a
    /// later options-bar pass can drive it; defaults to `defaultCols`.
    public var cols: Int

    // MARK: - State

    /// The last cursor point seen via `.move`, used for the insertion-point preview and
    /// as the `.commit` fallback point. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The request the most recent commit produced — the app reads this after a
    /// `.finished` outcome and adds it via `CADDrawing.addTable`. `nil` until a point is
    /// committed (or after a cancel).
    public private(set) var pendingTable: TableObject?

    /// Creates a Table-insert tool that places a `rows × cols` default empty table.
    public init(rows: Int = TableTool.defaultRows, cols: Int = TableTool.defaultCols) {
        self.rows = Swift.max(1, rows)
        self.cols = Swift.max(1, cols)
    }

    // MARK: - Tool

    public var title: String { "Table" }

    public var status: String { "Specify the table insertion point (top-left corner)" }

    /// A tiny insertion-point crosshair at the cursor so the user sees where the
    /// table's top-left corner will land. Empty before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard cursor.valid else { return [] }
        return Self.crosshair(at: cursor)
    }

    /// A single-pick placement tool: on a point pick it records a `pendingTable` and
    /// ends its run. It does NOT emit `.commit` edits (a table is not an `EntityKind`).
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the table exactly like a click.
            guard p.valid else { return .none }
            return finish(at: p)

        case .commit:
            // Return — use the last cursor if it has moved, else the origin.
            return finish(at: cursor.valid ? cursor : Vector(0, 0))

        case .backspace:
            // Single-pick placement — nothing to step back.
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Finish

    /// Builds the default `TableObject` at `position` (the top-left corner) and ends the
    /// run. The app reads `pendingTable` after the `.finished` and adds it undoably.
    private mutating func finish(at position: Vector) -> ToolOutcome {
        pendingTable = Self.defaultTable(at: position, rows: rows, cols: cols)
        cursor = .invalid
        return .finished
    }

    private mutating func reset() {
        cursor = .invalid
        pendingTable = nil
    }

    // MARK: - Default-table factory (pure — shared by the app + tests)

    /// A fresh default `TableObject`: `rows × cols` EMPTY cells with the default row/col
    /// sizes and the standard table style (borders visible), anchored at `position` (its
    /// top-left corner). Rows/cols are clamped to ≥ 1 so a degenerate request still
    /// yields a drawable 1×1 grid. A NEW `id` is minted per call so two placements never
    /// collide in `CADDrawing.tables`.
    public static func defaultTable(at position: Vector,
                                    rows: Int = defaultRows,
                                    cols: Int = defaultCols) -> TableObject {
        TableObject(
            position: position,
            rows: Swift.max(1, rows),
            cols: Swift.max(1, cols)
        )
    }

    // MARK: - Apply (the model-op bridge — exercised in tests + by the app)

    /// Adds `table` to a drawing via the undoable model op `CADDrawing.addTable`. The
    /// single seam the app calls after the tool finishes; returns whether the table was
    /// added (false only on a duplicate id — never for a fresh placement).
    @MainActor
    @discardableResult
    public static func apply(_ table: TableObject, to drawing: CADDrawing) -> Bool {
        drawing.addTable(table)
    }

    // MARK: - Preview geometry (pure)

    /// A small "+" crosshair (two short segments) centered at `p`, in the preview pen —
    /// the insertion-point marker (mirrors `CreateBlockTool.crosshair`).
    static func crosshair(at p: Vector, halfSize: Double = 1.0) -> [ResolvedPolyline] {
        let h = ResolvedPolyline(
            points: [Vector(p.x - halfSize, p.y), Vector(p.x + halfSize, p.y)],
            closed: false, pen: .toolPreview)
        let v = ResolvedPolyline(
            points: [Vector(p.x, p.y - halfSize), Vector(p.x, p.y + halfSize)],
            closed: false, pen: .toolPreview)
        return [h, v]
    }
}
