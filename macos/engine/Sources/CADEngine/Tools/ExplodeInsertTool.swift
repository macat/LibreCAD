//
//  ExplodeInsertTool.swift
//  CADEngine
//
//  The EXPLODE-INSERT modify tool (feature-catalog F10) — replace a selected block
//  reference (`.insert`) with its block's member entities, each transformed by the
//  insert's placement (and repeated per MINSERT grid cell). Ported in spirit from
//  LibreCAD's `RS_ActionModifyExplode` over an `RS_Insert` / `RS_Insert::explode`
//  (librecad/src/lib/engine/rs_insert.cpp): an INSERT becomes free copies of the
//  block's contents, placed exactly where the insert drew them; the INSERT itself
//  is removed.
//
//  This is the EXACT inverse of `CreateBlockTool` + the resolve seam: resolving an
//  insert (`Resolve.resolveInsert`) transforms each block member by
//  `EntityKind.insertTransform` per grid cell; explode emits those SAME transformed
//  member RECORDS as real entities. So create-block then explode-insert is the
//  identity (the geometry returns, transformed back to its original world place,
//  because the block was authored relative to the base point and the insert sits AT
//  the base point).
//
//  Behavior:
//    - no insert selected → status nudges "Select a block reference to explode
//                        first"; every input is a no-op.
//    - it explodes EVERY selected `.insert` (non-insert selections are ignored).
//      For each insert, for each MINSERT cell, every block member is transformed by
//      `insertTransform(insert, cellOffset:)` and emitted as a fresh `.add`,
//      inheriting the MEMBER's layer/pen/flags (the block's own attributes), exactly
//      like the resolve. The INSERT is removed.
//    - `.commit` (Return) / `.click` → fire the explode.
//    - `.cancel` (Esc) → discard the captured selection, reset, `.finished`.
//
//  The edits are `.remove(insertID)` followed by one `.add(member)` per placed
//  member (the brief's "remove + add" form), one undoable group.
//
//  ## Block members source (construction injection, matching InsertTool)
//  A tool is PURE and `ToolContext` carries no block provider, so the block's
//  member records are supplied to the tool at construction via a `@Sendable`
//  `blockMembers` provider (the same `name -> [EntityRecord]?` shape as
//  `ResolveContext.blockProvider`). The app builds it from the drawing's block
//  table (`CADDrawing.blockMembersSnapshot()`). A block the provider can't satisfy
//  (missing / frozen) explodes to nothing for that insert (no crash) — matching the
//  resolve seam's missing-block behavior.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI. It
//  reads only `context.selected` (the inserts to explode) and the injected
//  `blockMembers` provider, and emits `.remove` + `.add` edits. The app re-mints the
//  added ids on commit. Intentionally UNWIRED until the wire-wave registers a
//  ToolKind case.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Insert::explode).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Explode-Insert tool. With one or more block references
/// (`.insert`) selected, replace each with its block's member entities transformed
/// by the insert's placement (per MINSERT cell); the inserts are removed. UNWIRED
/// for now (no `ToolKind` case yet); fully usable + testable as a value type.
public struct ExplodeInsertTool: Tool {

    // MARK: - Configuration

    /// Resolves a block name to its member records — the same `name -> members?`
    /// shape as `ResolveContext.blockProvider`. Supplied at construction by the app
    /// (from `CADDrawing.blockMembersSnapshot()`); a name it can't satisfy explodes
    /// to nothing for that insert.
    private let blockMembers: @Sendable (String) -> [EntityRecord]?

    // MARK: - State

    /// The selection captured on the first `handle` (snapshotted so a later
    /// selection change cannot alter the in-progress explode). Empty until captured.
    private var captured: [EntityRecord] = []

    /// Creates an Explode-Insert tool backed by `blockMembers` (a block-name →
    /// member-records provider, the same shape as `ResolveContext.blockProvider`).
    /// Defaults to a provider that knows no blocks (every insert explodes to nothing)
    /// — handy for the no-op / inert tests; the app injects the real one.
    public init(blockMembers: @escaping @Sendable (String) -> [EntityRecord]? = { _ in nil }) {
        self.blockMembers = blockMembers
    }

    // MARK: - Tool

    public var title: String { "Explode Block" }

    public var status: String {
        explodableInserts().isEmpty
            ? "Select a block reference to explode first"
            : "Press Return to explode the selected block reference(s)"
    }

    /// The live preview: every placed member the explode would produce, resolved
    /// with the preview pen (geometrically identical to the inserts' drawn geometry).
    public var preview: [ResolvedPolyline] {
        explodedRecords().flatMap { record in
            record.kind.resolve(pen: .toolPreview, ctx: .default).polylines
        }
    }

    /// A MODIFY tool: reads `context.selected`, then on fire emits, per selected
    /// insert, a `.remove(insertID)` plus one `.add` per placed block member.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .move, .value, .backspace:
            return .none

        case .click, .commit:
            return fire()

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Fire

    private mutating func fire() -> ToolOutcome {
        let inserts = explodableInserts()
        guard !inserts.isEmpty else { return .none }

        var edits: [ToolEdit] = []
        for insert in inserts {
            guard case .insert(let data) = insert.kind else { continue }
            let placed = Self.explode(data, blockMembers: blockMembers)
            guard !placed.isEmpty else { continue }
            edits.append(.remove(insert.id))
            for member in placed { edits.append(.add(member)) }
        }
        reset()
        return edits.isEmpty ? .none : .commit(edits)
    }

    private mutating func reset() {
        captured = []
    }

    // MARK: - Selection helpers

    /// The captured selections that are inserts whose block resolves to at least one
    /// member (an insert of a missing/empty block has nothing to explode).
    private func explodableInserts() -> [EntityRecord] {
        captured.filter { record in
            guard case .insert(let d) = record.kind else { return false }
            return !(blockMembers(d.blockName)?.isEmpty ?? true)
        }
    }

    /// The exploded member records across all explodable selections — for preview +
    /// the round-trip tests.
    private func explodedRecords() -> [EntityRecord] {
        explodableInserts().flatMap { record -> [EntityRecord] in
            guard case .insert(let d) = record.kind else { return [] }
            return Self.explode(d, blockMembers: blockMembers)
        }
    }

    // MARK: - Explode geometry (pure, self-contained)

    /// Expands one insert into its placed member RECORDS, matching the resolve seam
    /// (`Resolve.resolveInsert`): for each MINSERT grid cell, each block member is
    /// transformed by `EntityKind.insertTransform(data, cellOffset:)` and emitted as
    /// a fresh top-level record (placeholder id, `.selected` stripped) inheriting the
    /// member's own layer/pen/flags. A missing/empty block ⇒ `[]`.
    ///
    /// This is the inverse of `CADDrawing.makeBlockFromEntities` for a unit-scale,
    /// unrotated insert at the block's base point: the member geometry (authored
    /// relative to the base point) is translated by the insertion point, landing it
    /// back where it started.
    static func explode(_ data: InsertData,
                        blockMembers: (String) -> [EntityRecord]?) -> [EntityRecord] {
        guard let members = blockMembers(data.blockName), !members.isEmpty else { return [] }

        var out: [EntityRecord] = []
        out.reserveCapacity(members.count * Swift.max(1, data.rows) * Swift.max(1, data.cols))
        for r in 0..<Swift.max(1, data.rows) {
            for c in 0..<Swift.max(1, data.cols) {
                let cellOffset = Vector(Double(c) * data.colSpacing, Double(r) * data.rowSpacing)
                let t = EntityKind.insertTransform(data, cellOffset: cellOffset)
                for member in members {
                    var placed = member
                    placed.id = .placeholder            // the app re-mints on .add
                    placed.kind = member.kind.transformed(by: t)
                    placed.isSelected = false           // freshly-added entities aren't selected
                    out.append(placed)
                }
            }
        }
        return out
    }
}
