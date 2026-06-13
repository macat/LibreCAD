//
//  InsertTool.swift
//  CADEngine
//
//  The INSERT (block reference) draw tool — place a reference to a named block by
//  clicking an insertion point. Ported in spirit from LibreCAD's
//  `RS_ActionBlocksInsert` (librecad/src/actions/blocks/rs_actionblocksinsert.cpp):
//  with a target block chosen, each click drops one INSERT entity referencing that
//  block at the snapped point, applying the tool's current scale + rotation.
//
//  Behavior (a block name is chosen up front — see `init`):
//    - no block chosen → status nudges the user to pick a block; every input is a
//                         no-op (nothing to place).
//    - `.move`         → rubber-band preview of the placed block (an insert at the
//                        cursor, resolved via the previewable members supplied to
//                        `init`); empty if no members were supplied.
//    - `.click` / `.value` (the insertion point) → commit ONE `.add(.insert(...))`
//                        at that point with the tool's scale/rotation/array, then
//                        STAY active for the next placement (LibreCAD chains).
//    - `.cancel` (Esc) → end the run, `.finished`.
//    - `.backspace`    → nothing pending in a single-click placement; no-op.
//    - `.commit` (Ret) → end the run (each insert committed on its click).
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It is handed the block NAME (and, for the live preview, the block's member
//  records) at construction; it reads only the snapped world point in `ToolInput`
//  and emits `.add(.insert(...))`. The app re-mints the id on commit. The
//  block-picker UI + create-block-from-selection are a SEPARATE later task (#7);
//  this tool is intentionally UNWIRED until that wave wires a ToolKind case.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionBlocksInsert).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Insert tool. With a target block name set, each click drops a
/// block reference (`.insert`) at the snapped point using the tool's scale,
/// rotation, and optional MINSERT array. UNWIRED for now (no `ToolKind` case yet —
/// the block-picker UI is task #7); it is fully usable + testable as a value type.
public struct InsertTool: Tool {

    // MARK: - Configuration (set at construction by the caller / future picker)

    /// The block to place. `nil` (or empty) means "no block chosen yet" — the tool
    /// is a no-op until one is set (the picker provides it).
    private let blockName: String?

    /// The placement scale applied to every inserted block (default no scaling).
    private let scale: Vector

    /// The placement rotation (radians) applied to every inserted block.
    private let rotation: Double

    /// The MINSERT rectangular array (default 1×1 == a plain single insert).
    private let rows: Int
    private let cols: Int
    private let rowSpacing: Double
    private let colSpacing: Double

    /// The block's member records, supplied so the rubber-band can preview the
    /// placed geometry. Empty ⇒ no preview (the tool still places correctly; the
    /// app's resolve context expands the real block on commit). Resolved with the
    /// shared preview pen so the rubber-band reads as a preview.
    private let previewMembers: [EntityRecord]

    /// The last cursor point seen via `.move`, used to draw the rubber-band before
    /// the insertion point is clicked. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// Creates an Insert tool that places references to `blockName`.
    ///
    /// - Parameters:
    ///   - blockName: the block to place (`nil`/empty ⇒ inert until set by a picker).
    ///   - scale: per-axis placement scale (default `(1,1)`).
    ///   - rotation: placement rotation in radians (default 0).
    ///   - rows/cols/rowSpacing/colSpacing: optional MINSERT array (default 1×1).
    ///   - previewMembers: the block's member records for the rubber-band preview
    ///     (default none; the placement still works without them).
    public init(blockName: String? = nil,
                scale: Vector = Vector(1, 1),
                rotation: Double = 0,
                rows: Int = 1,
                cols: Int = 1,
                rowSpacing: Double = 0,
                colSpacing: Double = 0,
                previewMembers: [EntityRecord] = []) {
        self.blockName = (blockName?.isEmpty == true) ? nil : blockName
        self.scale = scale
        self.rotation = rotation
        self.rows = Swift.max(1, rows)
        self.cols = Swift.max(1, cols)
        self.rowSpacing = rowSpacing
        self.colSpacing = colSpacing
        self.previewMembers = previewMembers
    }

    // MARK: - Tool

    public var title: String { "Insert Block" }

    public var status: String {
        blockName == nil ? "Choose a block to insert"
                         : "Specify insertion point"
    }

    /// The live rubber-band: the chosen block's member geometry, transformed by the
    /// would-be insert at the cursor, resolved with the preview pen. Empty before a
    /// block is chosen, before the cursor has moved, or when no preview members were
    /// supplied.
    public var preview: [ResolvedPolyline] {
        guard let name = blockName, cursor.valid, !previewMembers.isEmpty else { return [] }
        let data = makeInsertData(name, at: cursor)
        var out: [ResolvedPolyline] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let cellOffset = Vector(Double(c) * colSpacing, Double(r) * rowSpacing)
                let cellT = EntityKind.insertTransform(data, cellOffset: cellOffset)
                for member in previewMembers {
                    let placed = member.kind.transformed(by: cellT)
                    out += placed.resolve(pen: .toolPreview, ctx: .default).polylines
                }
            }
        }
        return out
    }

    /// A DRAW tool: it IGNORES `context` (the block name + members are supplied at
    /// construction by the picker) and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the block exactly like a click.
            guard let name = blockName, p.valid else { return .none }
            let record = EntityRecord(
                id: .placeholder,
                kind: .insert(makeInsertData(name, at: p))
            )
            // Commit one insert, then STAY active for the next placement (chaining,
            // like the other draw tools).
            return .commit([.add(record)])

        case .backspace:
            // Single-click placement — nothing pending to step back.
            return .none

        case .cancel:
            // Esc — end the run.
            return .finished

        case .commit:
            // Return — each insert committed on its click; nothing pending.
            return .finished
        }
    }

    // MARK: - Helpers

    /// Builds the `InsertData` for placing `name` at `point` with the tool's
    /// scale / rotation / array.
    private func makeInsertData(_ name: String, at point: Vector) -> InsertData {
        InsertData(
            blockName: name,
            insertionPoint: point,
            scale: scale,
            rotation: rotation,
            rows: rows,
            cols: cols,
            rowSpacing: rowSpacing,
            colSpacing: colSpacing
        )
    }
}
