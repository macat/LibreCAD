//
//  BlockExport.swift
//  CADEngine
//
//  Export a block (or a raw selection) to a standalone `.dxf` file — the ENGINE
//  half of LibreCAD's "Save Block" (RS_ActionBlocksSave / WBLOCK). The inverse of
//  `BlockLibrary.importDXF`: import reads a `.dxf` into a NAMED block; export takes
//  a named block (or a hand-picked set of records) and writes its geometry out as
//  a `.dxf` whose contents are RE-BASED so the block's base point lands on the
//  origin (0,0). That re-basing is what makes the exported file insert cleanly: a
//  member at world position `basePoint + Δ` is written at `Δ`, so re-importing it
//  (via `BlockLibrary.importDXF`, basePoint = origin) reproduces the block's local
//  frame exactly.
//
//  ## Engine-pure — NO file-picker, NO modal
//  Like `BlockLibrary`, the destination path is supplied by the caller. The
//  `NSSavePanel` that chooses "Save Block As…" lives ONLY in the View layer (a
//  later wire-wave) — a modal reached from the headless test suite would hang it
//  forever. These functions take a plain `path` and write through the existing
//  `CADEngine` writer (the same non-reentrant libdxfrw serialization point as
//  every other save), so they are fully unit-testable.
//
//  ## Re-uses the writer — adds NO new serialization
//  Nothing here re-implements DXF emission. The member records are translated into
//  the block's local frame and handed to `CADEngine.shared.writeEntities`, exactly
//  the entry point `writeDrawing` calls. The referenced layers are gathered from
//  the source drawing so the exported file carries proper layer definitions.
//
//  ## Nested INSERTs (members that reference OTHER blocks)
//  A block member can itself be an `.insert` of another block. Such members are
//  written AS-IS (translated), and the blocks they reference are emitted as block
//  DEFINITIONS in the file's BLOCKS section (with their members) so the export
//  round-trips through the engine reader, which expands the nested inserts. The
//  full reader (`loadDrawing`) reads the file's block table and resolves the nested
//  inserts correctly. NOTE the asymmetry on RE-IMPORT: `BlockLibrary.importDXF`
//  imports only the file's TOP-LEVEL entities (it does NOT merge the file's block
//  table into the destination), so a re-imported nested INSERT references a block
//  the destination lacks — that is a documented IMPORT-side limitation, not an
//  export bug (export fidelity is verified against `loadDrawing`). Nested-insert
//  member geometry is NOT flattened — it stays an INSERT referencing a block
//  definition (v1; deep flattening is a follow-up).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionBlocksSave).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Export a block / a raw selection to a .dxf file

/// The outcome of a block export — the per-kind written/skipped counts the writer
/// reports (skipped == kinds the writer cannot yet represent at the chosen
/// version), plus the number of top-level records that were written and the count
/// of referenced block definitions emitted. A `nil` RESULT (the functions return
/// `BlockExportResult?`) means there was nothing to export (unknown/empty block,
/// no records) — in which case NO file is written.
public struct BlockExportResult: Sendable, Hashable {
    /// Top-level records emitted (each block member, re-based to the local frame).
    public let recordCount: Int
    /// Referenced block DEFINITIONS emitted in the BLOCKS section (the blocks any
    /// nested `.insert` members reference). 0 for a flat block.
    public let nestedBlockCount: Int
    /// The writer's per-kind counts (written / skipped).
    public let written: Int
    public let skipped: Int

    public init(recordCount: Int, nestedBlockCount: Int, written: Int, skipped: Int) {
        self.recordCount = recordCount
        self.nestedBlockCount = nestedBlockCount
        self.written = written
        self.skipped = skipped
    }
}

/// Namespaced home for the block-export ops (static helpers, not module-scope free
/// functions — matches the project's fan-out convention, e.g. `EntityTransform`).
public enum BlockExport {

    // MARK: Named-block export

    /// Writes the named block's geometry to the `.dxf` at `path` (overwriting it),
    /// re-based so the block's `basePoint` lands on the origin. The inverse of
    /// `BlockLibrary.importDXF`.
    ///
    /// Mechanics:
    ///   1. Resolve the block's `entityIDs` to live member records (a stale id —
    ///      one no longer in the drawing — is skipped, matching
    ///      `blockMembersSnapshot`).
    ///   2. Translate each member by `-basePoint` into the block's local frame, so a
    ///      member at world `basePoint + Δ` is written at `Δ`. (`makeBlockFromEntities`
    ///      already stores members re-authored relative to its base point with
    ///      `Block.basePoint == (0,0)`; an IMPORTED block keeps world positions with
    ///      a non-origin base point. This translation handles BOTH: it is always
    ///      "member-position minus the block's recorded base point".)
    ///   3. Collect the layer definitions the members reference (from the source
    ///      drawing's layer table) so the file carries proper layers.
    ///   4. Emit any blocks referenced by nested `.insert` members as block
    ///      definitions (so the file round-trips).
    ///   5. Write through the shared engine writer (the same path `writeDrawing`
    ///      uses).
    ///
    /// - Parameters:
    ///   - drawing:  the source drawing.
    ///   - name:     the block to export (exact name match, via `blocks.block(named:)`).
    ///   - path:     the destination `.dxf` file.
    ///   - version:  the DXF version to write (default `.r2000`, like the rest of
    ///               the writer; SPLINE/MTEXT/HATCH/DIMENSION need R2000+).
    /// - Returns: the export result, or `nil` if the block is unknown or has NO
    ///   live members — in which case NO file is written (graceful).
    /// - Throws: `CADWriteError.invalidPath` for a blank path; `.writeFailed` if
    ///   libdxfrw cannot write the file (propagated from the writer).
    @MainActor
    @discardableResult
    public static func writeBlock(
        _ drawing: CADDrawing,
        name: String,
        toPath path: String,
        version: DXFVersion = .r2000
    ) async throws -> BlockExportResult? {
        guard let block = drawing.blocks.block(named: name) else { return nil }
        // Live member records, in the block's member order; stale ids skipped.
        let members = block.entityIDs.compactMap { drawing.entity($0) }
        guard !members.isEmpty else { return nil }

        return try await writeRecords(
            members,
            basePoint: block.basePoint,
            sourceDrawing: drawing,
            toPath: path,
            version: version
        )
    }

    // MARK: Raw-selection export ("WBLOCK objects")

    /// Writes a raw set of records to the `.dxf` at `path`, re-based so `basePoint`
    /// lands on the origin — the "WBLOCK objects" path (export a hand-picked
    /// selection, not a named block). The caller supplies the layer definitions to
    /// emit (e.g. the source drawing's `layers`); only the layers the records
    /// actually reference are written, so the file is not polluted with the whole
    /// layer table.
    ///
    /// - Parameters:
    ///   - records:   the geometry to export (e.g. the current selection's records).
    ///   - basePoint: the export base point; every record is translated by
    ///                `-basePoint` so a record at `basePoint + Δ` is written at `Δ`.
    ///   - layers:    the layer table to source layer DEFINITIONS from (the layers
    ///                the records reference are emitted; unreferenced ones are not).
    ///   - path:      the destination `.dxf` file.
    ///   - version:   the DXF version (default `.r2000`).
    /// - Returns: the export result, or `nil` if `records` is empty (NO file written).
    /// - Throws: `CADWriteError.invalidPath` / `.writeFailed` from the writer.
    @discardableResult
    public static func writeRecords(
        _ records: [EntityRecord],
        basePoint: Vector,
        layers: LayerTable,
        toPath path: String,
        version: DXFVersion = .r2000
    ) async throws -> BlockExportResult? {
        try await writeRecordsCore(
            records,
            basePoint: basePoint,
            layers: layers,
            nestedBlocks: BlockTable(),
            nestedMembers: [:],
            toPath: path,
            version: version
        )
    }

    // MARK: - Internals

    /// Shared core for `writeBlock` (which also threads in the source drawing's
    /// block table + layer table so nested inserts round-trip) and the public
    /// raw-records `writeRecords`. Translates the records into the local frame,
    /// gathers the referenced layers, and writes through the engine writer.
    ///
    /// This `sourceDrawing` overload is `@MainActor` because it reads the drawing's
    /// value tables (layers / blocks / block members) on the main actor before
    /// handing the snapshot off to the engine actor for the write.
    @MainActor
    private static func writeRecords(
        _ records: [EntityRecord],
        basePoint: Vector,
        sourceDrawing drawing: CADDrawing,
        toPath path: String,
        version: DXFVersion
    ) async throws -> BlockExportResult? {
        guard !records.isEmpty else { return nil }

        // Gather the blocks any nested `.insert` member references, transitively,
        // so the exported file's BLOCKS section is self-contained and the reader can
        // expand the inserts. Block members are written in their OWN local frame
        // (NOT re-based by `basePoint`) — only the top-level INSERT member is
        // re-based; the block definition it points at is unchanged.
        var nestedBlocks = BlockTable()
        var nestedMembers: [String: [EntityRecord]] = [:]
        collectReferencedBlocks(
            from: records, in: drawing,
            into: &nestedBlocks, members: &nestedMembers
        )

        return try await writeRecordsCore(
            records,
            basePoint: basePoint,
            layers: drawing.layers,
            nestedBlocks: nestedBlocks,
            nestedMembers: nestedMembers,
            toPath: path,
            version: version
        )
    }

    /// The single write seam both public entry points funnel through. Translates
    /// the records into the local frame (`-basePoint`), subsets the layer table to
    /// the layers the records (and any nested block members) reference, and hands
    /// everything to the shared engine writer.
    private static func writeRecordsCore(
        _ records: [EntityRecord],
        basePoint: Vector,
        layers: LayerTable,
        nestedBlocks: BlockTable,
        nestedMembers: [String: [EntityRecord]],
        toPath path: String,
        version: DXFVersion
    ) async throws -> BlockExportResult? {
        guard !records.isEmpty else { return nil }
        guard !path.isEmpty else { throw CADWriteError.invalidPath }

        // Re-base: translate every top-level record into the block's local frame so
        // `basePoint` maps to (0,0). The `.selected` flag is stripped so the export
        // never carries transient selection state. Members keep their layer/pen.
        let toLocal = Affine2D.translation(Vector(-basePoint.x, -basePoint.y))
        let exported: [EntityRecord] = records.map { src in
            var r = src
            r.kind = src.kind.transformed(by: toLocal)
            r.isSelected = false
            // Block geometry is always model-space in a standalone symbol file.
            r.space = .model
            r.layoutName = nil
            return r
        }

        // Subset the layer table to the layers actually referenced (by the exported
        // top-level records AND by every nested block member). Layer "0" is always
        // present (a DXF file must have it) so an entity on an unknown layer still
        // resolves. Falls back to a fresh `LayerTable` (just "0") if none match.
        var neededNames = Set<String>()
        for r in exported { neededNames.insert(r.layer.name) }
        for (_, members) in nestedMembers {
            for m in members { neededNames.insert(m.layer.name) }
        }
        let exportLayers = subsetLayers(layers, keeping: neededNames)

        let result = try await CADEngine.shared.writeEntities(
            exported,
            layers: exportLayers,
            blocks: nestedBlocks,
            blockMembers: nestedMembers,
            toPath: path,
            version: version
        )

        return BlockExportResult(
            recordCount: exported.count,
            nestedBlockCount: nestedBlocks.blocks.count,
            written: result.written,
            skipped: result.skipped
        )
    }

    /// Builds a `LayerTable` containing only the layers in `keeping` that exist in
    /// `source`, always including "0" (the mandatory DXF default). The order
    /// follows `source` so the export is deterministic. A layer name in `keeping`
    /// with no definition in `source` is simply omitted — the entity falls back to
    /// "0" semantics on read (it still carries its layer NAME in the record, so a
    /// real definition is only a nicety, not a correctness requirement).
    private static func subsetLayers(
        _ source: LayerTable, keeping names: Set<String>
    ) -> LayerTable {
        var keep = names
        keep.insert("0")
        var picked: [Layer] = source.layers.filter { keep.contains($0.name) }
        // Guarantee "0" is present even if the source table somehow lacks it.
        if !picked.contains(where: { $0.name == "0" }) {
            picked.insert(Layer(name: "0"), at: 0)
        }
        return LayerTable(layers: picked, activeLayerName: "0")
    }

    /// Walks the records for `.insert` members and collects the referenced block
    /// definitions (transitively — a referenced block may itself contain inserts)
    /// from the source drawing into `blocks` + `members`. Anonymous (`*`-prefixed)
    /// blocks are NOT collected (the writer skips them anyway — they regenerate).
    /// A cycle or a re-visit is guarded by the already-collected set.
    @MainActor
    private static func collectReferencedBlocks(
        from records: [EntityRecord],
        in drawing: CADDrawing,
        into blocks: inout BlockTable,
        members: inout [String: [EntityRecord]]
    ) {
        // Seed the work list with every block name referenced by an insert record.
        var queue: [String] = []
        for r in records {
            if case .insert(let d) = r.kind { queue.append(d.blockName) }
        }

        while let name = queue.first {
            queue.removeFirst()
            // Skip anonymous blocks, already-collected ones, and unknown names.
            guard !name.hasPrefix("*"), !blocks.contains(name),
                  let block = drawing.blocks.block(named: name) else { continue }

            let blockMembers = block.entityIDs.compactMap { drawing.entity($0) }
            blocks.add(block)
            members[name] = blockMembers

            // Recurse: any insert WITHIN this block references further blocks.
            for m in blockMembers {
                if case .insert(let d) = m.kind { queue.append(d.blockName) }
            }
        }
    }
}
