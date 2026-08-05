//
//  DocumentModel.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 1 — extraction from the CanvasModel god object.
//  Owns the document-level state: the engine CADDrawing, its UndoManager,
//  and the modelVersion/modelDirty bookkeeping the renderer observes.
//  Provides the drawing-mutation funnels (add/replace/remove via CADDrawing)
//  that remain the single source of truth for document content.
//
//  Per perf-arch-review-plan Wave 4: DocumentModel is a focused
//  @Observable at @MainActor, so SwiftUI diff only re-renders views that
//  read document state. CanvasModel holds this as a child and forwards
//  its existing public API (canvasModel.drawing -> documentModel.drawing)
//  so 4125 tests stay green.
//
//  GPLv2-or-later.
//

import Foundation
import Observation
import CADEngine

/// The document-owned slice of canvas state: the engine drawing,
/// its undo stack, and the version/dirty bookkeeping the renderer keys off.
///
/// Owns:
///   - `drawing` — the ordered engine store (entities + layers + blocks + …)
///   - `undoManager` — the per-document UndoManager CADDrawing registers undo with
///   - `modelVersion` / `modelDirty` — bumped on any document mutation so the
///     Metal renderer knows to rebuild its instance buffers (view-only changes do NOT bump)
@MainActor
@Observable
final class DocumentModel {

    // MARK: - Stored document state

    /// The engine drawing (entities + layers). Replaced wholesale on File>Open,
    /// mutated in place by edits (all through CADDrawing's undoable funnels).
    var drawing: CADDrawing

    /// The per-document undo manager. CADDrawing's mutators register undo against this;
    /// CanvasModel may swap it for SwiftUI's environment manager via `adoptUndoManager`.
    private(set) var undoManager: UndoManager

    /// Whether the GPU model buffer needs a rebuild (set on model replace/edit,
    /// cleared by the renderer after it rebuilds). View changes do NOT set this.
    var modelDirty: Bool = true

    /// Bumped whenever the document is replaced or mutated, so the renderer
    /// (which holds a snapshot reference) can detect "new model" cheaply.
    var modelVersion: Int = 0

    // MARK: - Derived

    /// How many entities are in the drawing (thin accessor over `drawing.count`).
    var entityCount: Int { drawing.count }

    /// Whether an undo step is available (thin accessor).
    var canUndo: Bool { undoManager.canUndo }

    /// Whether a redo step is available.
    var canRedo: Bool { undoManager.canRedo }

    // MARK: - Init

    init(drawing: CADDrawing = CADDrawing(), undoManager: UndoManager = UndoManager()) {
        self.drawing = drawing
        self.undoManager = undoManager
        self.drawing.undoManager = undoManager
    }

    // MARK: - Lifecycle

    /// Replaces the drawing wholesale (File>Open / launch-load). Resets undo,
    /// re-parents the drawing's undoManager, and bumps version/dirty.
    func setDrawing(_ newDrawing: CADDrawing) {
        drawing = newDrawing
        drawing.undoManager = undoManager
        undoManager.removeAllActions()
        modelDirty = true
        modelVersion &+= 1
    }

    /// Swaps in an externally-owned UndoManager (SwiftUI's environment manager under
    /// DocumentGroup) so drawing mutations register against it. Idempotent.
    func adoptUndoManager(_ manager: UndoManager) {
        guard manager !== undoManager else { return }
        undoManager = manager
        drawing.undoManager = manager
        manager.removeAllActions()
    }

    // MARK: - Drawing mutation funnels (undoable, via CADDrawing)

    /// Adds a record (mints a real id). Marks dirty + bumps version.
    /// The single funnel adders should use so undo/version stay coherent.
    @discardableResult
    func add(_ record: EntityRecord) -> EntityID {
        let id = drawing.add(record)
        modelDirty = true
        modelVersion &+= 1
        return id
    }

    /// Replaces a record by id (full record, undoable). No-op if id absent.
    func replace(_ record: EntityRecord) {
        guard drawing.contains(record.id) else { return }
        drawing.replace(record)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Removes an entity by id (undoable, no-op if absent). Marks dirty + bumps.
    func remove(_ id: EntityID) {
        drawing.remove(id)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Applies a batch of ToolEdits as ONE undo group (the CanvasModel path).
    /// Kept here as the single funnel that keeps drawing + version in sync;
    /// the CanvasModel-level `applyCommit` still owns the quadtree/selection sync.
    func applyEdits(_ edits: [ToolEdit], adoptsCurrentProperties: Bool = true) {
        // Minimal funnel: the full CanvasModel.applyCommit handles layer/pen stamping
        // and the quadtree; this is the document-level batch helper used by decomposed
        // tests to verify undo/version semantics headless.
        guard !edits.isEmpty else { return }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        for edit in edits {
            switch edit {
            case .add(let r): _ = drawing.add(r)
            case .replace(let id, let k):
                if var rec = drawing.entity(id) { rec.kind = k; drawing.replace(rec) }
            case .remove(let id): drawing.remove(id)
            }
        }
        modelDirty = true
        modelVersion &+= 1
    }

    /// Bumps the version/dirty markers (for callers that mutated through
    /// CADDrawing directly but need to signal the renderer).
    func markDirty() {
        modelDirty = true
        modelVersion &+= 1
    }
}
