//
//  CADDrawing.swift
//  CADEngine
//
//  The document model (ADR-001 / ADR-002): an ordered store of value-type
//  entities keyed by stable `EntityID`, plus the layer table and the id-minting
//  counter. Mirrors LibreCAD's RS_Graphic / RS_EntityContainer, but holds value
//  records by id (NO object pointers, NO child graph) and registers undo as
//  value snapshots of the touched entities (ADR-002) — not LibreCAD's flag-based
//  RS_Undo scheme.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Graphic / RS_Undo model).
//

import Foundation
import Observation

/// The drawing — entities, layers, and the metadata the engine/render/tools all
/// read. `@MainActor` so it integrates cleanly with SwiftUI's `@Observable`
/// document machinery and `UndoManager` (which runs on the main thread for
/// document apps); `@Observable` so views update on mutation.
///
/// ## Threading
/// All mutation/read of `CADDrawing` happens on the main actor. Heavy,
/// off-thread work (DXF parsing, geometry kernels) runs through the single
/// shared `CADEngine` actor (see `CADEngine.swift`) and returns value types that
/// are then applied here on the main actor.
@MainActor
@Observable
public final class CADDrawing {

    // MARK: - Stored state

    /// Entities in stable insertion/draw order.
    public private(set) var entities: [EntityRecord] = []

    /// Fast id → index lookup, kept in sync with `entities`.
    private var indexByID: [EntityID: Int] = [:]

    /// The layer registry.
    public var layers = LayerTable()

    /// Drawing units / graphic variables — placeholder for the full
    /// `RS_Graphic` variable bag (units, dim styles, grid, ...). Phase 1 expands.
    public var graphicVariables: [String: String] = [:]

    /// Block definitions — placeholder for the `RS_BlockList` (ADR-001 stores
    /// block contents as id references in the document). Phase 1 expands.
    public var blocks: [String: [EntityID]] = [:]

    /// The `UndoManager` mutations register with. Injected by the document layer
    /// (SwiftUI hands one in from `DocumentGroup`); nil == undo disabled.
    public weak var undoManager: UndoManager?

    /// Monotonic id source. Never reused within this drawing's lifetime.
    private var nextRawID: UInt64 = 1

    public init() {}

    // MARK: - ID minting

    /// Mints a fresh, never-before-used `EntityID`.
    public func mintID() -> EntityID {
        defer { nextRawID += 1 }
        return EntityID(nextRawID)
    }

    // MARK: - Reads

    public var count: Int { entities.count }
    public var isEmpty: Bool { entities.isEmpty }

    public func entity(_ id: EntityID) -> EntityRecord? {
        guard let i = indexByID[id] else { return nil }
        return entities[i]
    }

    public func contains(_ id: EntityID) -> Bool { indexByID[id] != nil }

    // MARK: - Mutations (each registers a value-snapshot undo per ADR-002)

    /// Appends an entity. Undo removes it; redo re-adds it.
    ///
    /// If the entity's id is the placeholder `EntityID(0)` it is minted a fresh
    /// id here; otherwise its id is honored (used by document load).
    ///
    /// - Important: Callers MUST use `mintID()` for new entities (or leave the id
    ///   as the placeholder `EntityID(0)` to have one minted here). Only
    ///   `load(...)` supplies external ids (from a parsed file). Supplying a
    ///   hand-picked, non-minted id risks colliding with a minted or loaded id;
    ///   the `precondition` below aborts on a duplicate id as a programmer-error
    ///   guard — it is NOT a recoverable runtime path.
    @discardableResult
    public func add(_ entity: EntityRecord) -> EntityID {
        var e = entity
        if e.id.rawValue == 0 { e.id = mintID() }
        precondition(indexByID[e.id] == nil, "duplicate EntityID \(e.id) on add")

        indexByID[e.id] = entities.count
        entities.append(e)

        let id = e.id
        registerUndo { drawing in
            // Undo of add == remove (which itself registers the redo).
            drawing.remove(id)
        }
        return id
    }

    /// Removes an entity by id (no-op if absent). Undo restores it at its
    /// original draw order; redo removes it again.
    public func remove(_ id: EntityID) {
        guard let idx = indexByID[id] else { return }
        let removed = entities[idx]

        entities.remove(at: idx)
        indexByID.removeValue(forKey: id)
        // Reindex the tail that shifted down.
        for i in idx..<entities.count { indexByID[entities[i].id] = i }

        registerUndo { drawing in
            // Undo of remove == reinsert at the original position.
            drawing.reinsert(removed, at: idx)
        }
    }

    /// Replaces an existing entity's full record (same id). Undo restores the
    /// prior value; redo restores the new value. This is the path single-entity
    /// edits go through — the snapshot is one value copy (ADR-002).
    public func replace(_ entity: EntityRecord) {
        guard let idx = indexByID[entity.id] else {
            // Replacing something that isn't there falls back to add.
            _ = add(entity)
            return
        }
        let prior = entities[idx]
        entities[idx] = entity

        registerUndo { drawing in
            drawing.replace(prior)
        }
    }

    // MARK: - Internal reinsert (undo of remove, preserves draw order)

    private func reinsert(_ entity: EntityRecord, at index: Int) {
        let clamped = Swift.min(index, entities.count)
        entities.insert(entity, at: clamped)
        for i in clamped..<entities.count { indexByID[entities[i].id] = i }

        let id = entity.id
        registerUndo { drawing in
            drawing.remove(id)
        }
    }

    // MARK: - Undo plumbing

    /// Registers a value-snapshot undo closure. The closure captures the prior
    /// value(s) and, when invoked, re-mutates the drawing — which re-registers
    /// the inverse, giving redo for free (the standard `UndoManager` pattern).
    private func registerUndo(_ action: @escaping @MainActor (CADDrawing) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { drawing in
            // UndoManager invokes the handler on the main thread for document
            // apps; assert the main-actor contract that makes this sound.
            MainActor.assumeIsolated {
                action(drawing)
            }
        }
    }

    // MARK: - Bulk load (no undo — used by document open)

    /// Replaces all content without registering undo (used when loading a file).
    public func load(entities newEntities: [EntityRecord], layers newLayers: LayerTable) {
        entities = newEntities
        layers = newLayers
        indexByID.removeAll(keepingCapacity: true)
        for (i, e) in entities.enumerated() { indexByID[e.id] = i }
        // Advance the id counter past the highest loaded id.
        let maxID = entities.map(\.id.rawValue).max() ?? 0
        nextRawID = maxID + 1
        undoManager?.removeAllActions()
    }

    // MARK: - Derived geometry

    /// The union bounding box of all entities (empty if the drawing is empty).
    public func boundingBox() -> AABB {
        var box = AABB.empty
        for e in entities { box = box.union(e.boundingBox()) }
        return box
    }

    /// Resolves every entity to renderable geometry. Convenience for the
    /// renderer seam; production rendering caches per-entity by id + version.
    public func resolveAll(_ ctx: ResolveContext = .default) -> [ResolvedGeometry] {
        entities.map { $0.resolve(ctx) }
    }
}
