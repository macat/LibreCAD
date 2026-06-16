//
//  BlockLibrary.swift
//  CADEngine
//
//  A parts / symbol library — an engine-pure catalog of reusable symbols (each a
//  `.dxf` file on disk) plus the engine op that imports a symbol file's geometry
//  into a drawing as a NAMED block. This is the model + import seam behind the
//  later parts-gallery UI (B-WIRE wave): the gallery scans a directory into
//  `BlockLibraryItem`s and, on drag-to-place, imports the chosen item.
//
//  ## Engine-pure
//  No app types, no SwiftUI/AppKit, NO file-picker. `scan(directory:)` takes a
//  caller-supplied `URL` and enumerates it; the `NSOpenPanel` that chooses that
//  directory (or an individual `.dxf`) lives ONLY in the View layer — a modal
//  reached from the headless test suite would hang it forever.
//
//  ## Import never overwrites an existing block (data-safety invariant)
//  Block members are id-refs into the drawing's shared entity store (ADR-001);
//  `removeBlock(deletingContents:)` would delete those shared records. So import
//  NEVER overwrites a same-named block in place. It ALWAYS routes through
//  `CADDrawing.makeBlockFromEntities`, whose `BlockTable.newName(suggestion:)`
//  de-dup renames a colliding import (`NAME` → `NAME-1` → …). On a clash BOTH the
//  pre-existing block and the freshly imported one survive with their members
//  intact; the import returns the (possibly renamed) registered name.
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

// MARK: - Catalog model

/// One entry in a parts / symbol library: a reusable symbol backed by a `.dxf`
/// file on disk. Carries display metadata only — the geometry is read lazily at
/// import time (`BlockLibrary.importItem`/`importDXF`), so a catalog of hundreds
/// of symbols costs nothing until a symbol is actually placed.
///
/// Value type, `Sendable`/`Hashable`/`Codable` — safe to cross the actor
/// boundary and to persist a user's catalog. `url` is the source file; `name` is
/// the suggested block name (the file's base name, sans extension, by default).
public struct BlockLibraryItem: Sendable, Hashable, Codable, Identifiable {
    /// Stable identity within a catalog — the source file's path. Two items that
    /// point at the same file are the same item.
    public var id: String { url.path }

    /// The suggested block name when this symbol is imported. Defaults to the
    /// file's base name (without extension); the actual registered name may be
    /// de-duplicated at import time if it collides with an existing block.
    public var name: String

    /// The source `.dxf` file this symbol is read from at import time.
    public var url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// An item whose `name` is derived from the file's base name (no extension).
    /// `Symbols/Valve.dxf` → name `"Valve"`. Blank base names fall back to the
    /// full last path component so the item is never anonymous.
    public init(url: URL) {
        let base = url.deletingPathExtension().lastPathComponent
        self.name = base.isEmpty ? url.lastPathComponent : base
        self.url = url
    }
}

/// An ordered collection of `BlockLibraryItem`s — a parts catalog. Engine-pure
/// (no app/UI types). The B-WIRE gallery owns one of these, populated by
/// `scan(directory:)`; lookup/list back the gallery's rows and its
/// drag-to-place → import call.
public struct BlockLibrary: Sendable, Hashable, Codable {
    /// The catalog entries, in the order produced by `scan` (name-sorted,
    /// case-insensitive) or in caller-supplied order.
    public private(set) var items: [BlockLibraryItem]

    /// An empty catalog.
    public init() { self.items = [] }

    /// A catalog from explicit items (preserves the given order).
    public init(items: [BlockLibraryItem]) { self.items = items }

    // MARK: Reads

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// The first item whose `name` matches (case-insensitive), or `nil`.
    public func item(named name: String) -> BlockLibraryItem? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The item backed by `url` (path-equality), or `nil`.
    public func item(at url: URL) -> BlockLibraryItem? {
        items.first { $0.url.path == url.path }
    }

    // MARK: Mutations

    /// Appends an item. (No de-dup: a catalog may legitimately list two symbols
    /// with the same display name from different files.)
    public mutating func add(_ item: BlockLibraryItem) {
        items.append(item)
    }

    /// Replaces the whole catalog with the result of scanning `directory`.
    public mutating func reload(from directory: URL) {
        items = BlockLibrary.scan(directory: directory)
    }

    // MARK: - Directory scan (NO file-picker — the URL is caller-supplied)

    /// Enumerates the `.dxf` files directly inside `directory` into catalog items
    /// (metadata only — no geometry is read). NON-recursive (a flat symbol folder
    /// is the common shape; the gallery can scan sub-folders itself if it wants a
    /// tree). Hidden files are skipped. The result is sorted by name,
    /// case-insensitively, so the gallery reads it in display order directly.
    ///
    /// The `directory` URL is supplied by the caller — the `NSOpenPanel` that
    /// picks it belongs in the View layer, NEVER here (headless-modal hang rule).
    /// A missing/unreadable directory yields an empty array (never throws): a
    /// catalog of an absent folder is simply empty.
    public static func scan(directory: URL) -> [BlockLibraryItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        let items: [BlockLibraryItem] = entries.compactMap { url in
            guard url.pathExtension.lowercased() == "dxf" else { return nil }
            // Only regular files — a sub-DIRECTORY named "foo.dxf" is not a symbol.
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            guard isFile == true else { return nil }
            return BlockLibraryItem(url: url)
        }
        return items.sorted {
            $0.name.caseInsensitiveCompare($1.name) == .orderedSame
                ? $0.url.path < $1.url.path
                : $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Import a .dxf file's geometry into a drawing as a NAMED block

/// The outcome of importing a symbol file into a drawing.
public struct BlockImportResult: Sendable, Hashable {
    /// The name the imported block was registered under. May differ from the
    /// requested name if a clash forced `BlockTable.newName` de-dup (e.g.
    /// `"Valve"` → `"Valve-1"`); the pre-existing block is left untouched.
    public let blockName: String
    /// The id of the `.insert` entity placed for the imported block (the block's
    /// geometry, drawn once at `basePoint`). Lets the caller select/move it.
    public let insertID: EntityID
    /// Number of source records that became the block's members.
    public let memberCount: Int
}

extension BlockLibrary {

    /// Imports already-read geometry into `drawing` as a NAMED block, placing one
    /// INSERT at `basePoint`. This is the pure, synchronous core of import — it
    /// touches NO file I/O and NO bridge, so it is fully unit-testable on the main
    /// actor. The async file path (`importDXF`/`importItem`) reads the records and
    /// calls this.
    ///
    /// Mechanics (reusing the existing engine ops — nothing here re-implements the
    /// block table):
    ///   1. Each source record is re-minted (id zeroed) and `add`ed to the
    ///      drawing top-level, so its id can never collide with a drawing id.
    ///   2. Those fresh ids are handed to `CADDrawing.makeBlockFromEntities`,
    ///      which re-authors them relative to `basePoint`, registers a block under
    ///      a `newName`-de-duplicated name (NEVER an in-place overwrite — see the
    ///      file header's data-safety invariant), and drops one INSERT in place.
    ///
    /// - Parameters:
    ///   - records:  the geometry to import (typically a `DXFReadResult.records`).
    ///   - name:     the suggested block name; de-duplicated on a clash.
    ///   - drawing:  the destination drawing (mutated, undoably).
    ///   - basePoint: the block's base point / the INSERT's placement (default
    ///                origin). The members keep their world positions: the INSERT
    ///                at `basePoint` cancels the re-authoring translation.
    /// - Returns: the registered name + insert id + member count, or `nil` if
    ///   there was nothing importable (no records) or the name was blank — in
    ///   which case the drawing is left UNCHANGED (no partial block, no orphan
    ///   members).
    @MainActor
    @discardableResult
    public static func importRecords(
        _ records: [EntityRecord],
        name: String,
        into drawing: CADDrawing,
        basePoint: Vector = Vector(0, 0)
    ) -> BlockImportResult? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !records.isEmpty, !trimmed.isEmpty else { return nil }

        // Add the source geometry top-level with FRESH ids (zero the id so
        // `add` mints — loaded records carry ids from the reader that could
        // collide with the destination drawing). Mirrors the clipboard paste
        // convention. The `.selected` flag is cleared so the import doesn't
        // disturb the current selection.
        var newIDs: [EntityID] = []
        newIDs.reserveCapacity(records.count)
        for record in records {
            var r = record
            r.id = EntityID(0)        // re-mint on add
            r.isSelected = false
            newIDs.append(drawing.add(r))
        }

        // Route through the existing block-creation op: it re-authors the members
        // relative to `basePoint`, de-dups the name via `newName`, and drops the
        // INSERT. If — defensively — every id vanished (it cannot here), undo the
        // top-level adds so we leave no orphan geometry.
        guard let creation = drawing.makeBlockFromEntities(
            name: trimmed, basePoint: basePoint, ids: newIDs
        ) else {
            for id in newIDs { drawing.remove(id) }
            return nil
        }

        return BlockImportResult(
            blockName: creation.blockName,
            insertID: creation.insertID,
            memberCount: newIDs.count
        )
    }

    /// Reads the `.dxf` at `path` and imports its geometry into `drawing` as a
    /// named block (placed at `basePoint`). Reads on the shared `CADEngine` actor
    /// (libdxfrw is non-reentrant), then applies on the main actor.
    ///
    /// A file that reads to NO supported geometry (empty file, or only entity
    /// kinds the reader can't flatten) imports nothing and returns `nil` — the
    /// drawing is left unchanged (graceful, no partial block). A path that
    /// libdxfrw cannot open propagates the reader's `CADEngineError` (`.invalidPath`
    /// / `.readFailed`) so the caller can surface it.
    ///
    /// - Parameters:
    ///   - path: the `.dxf` file to import.
    ///   - name: the suggested block name; defaults to the file's base name; the
    ///           actual registered name is de-duplicated on a clash.
    ///   - drawing: the destination drawing.
    ///   - basePoint: the block base / INSERT placement (default origin).
    /// - Returns: the import result, or `nil` if the file held no importable
    ///   geometry.
    @discardableResult
    public static func importDXF(
        path: String,
        name suggestedName: String? = nil,
        into drawing: CADDrawing,
        basePoint: Vector = Vector(0, 0)
    ) async throws -> BlockImportResult? {
        let result = try await CADEngine.shared.readEntities(dxfPath: path)
        let fallbackName = (suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let records = result.records
        return await MainActor.run {
            importRecords(records, name: fallbackName, into: drawing, basePoint: basePoint)
        }
    }

    /// Imports a catalog `item` into `drawing` (reads `item.url`, uses
    /// `item.name` as the suggested block name). The B-WIRE drag-to-place path.
    @discardableResult
    public static func importItem(
        _ item: BlockLibraryItem,
        into drawing: CADDrawing,
        basePoint: Vector = Vector(0, 0)
    ) async throws -> BlockImportResult? {
        try await importDXF(path: item.url.path, name: item.name,
                            into: drawing, basePoint: basePoint)
    }
}
