//
//  DuplicateTool.swift
//  CADEngine
//
//  The DUPLICATE modify operation (AutoCAD-style ⌘D) — duplicate the current
//  selection IN PLACE, leaving the originals untouched. Ported in spirit from
//  LibreCAD's `LC_ActionModifyDuplicate`
//  (librecad/src/lib/actions/modify/lc_actionmodifyduplicate.cpp): it is the COPY
//  tool with NO base/destination pick — every selected entity is copied straight
//  away at a fixed offset (a small nudge by default so the copies are visible, or
//  exactly in place when the offset is zero).
//
//  Two forms live here so a later wire-wave can choose how ⌘D is dispatched:
//
//    1. `enum Duplicate` — a PURE static API. `Duplicate.duplicate(_:offset:)`
//       takes the selected `EntityRecord`s and returns one `.add` `ToolEdit` per
//       entity (a deep value copy translated by `offset`, default a small nudge).
//       The wire step can call this directly from a ⌘D menu command without
//       instantiating an interactive tool — handy because Duplicate has no
//       interaction beyond "do it now".
//
//    2. `struct DuplicateTool: Tool` — the interactive form, so ⌘D can be routed
//       through the same active-tool machinery as every other tool. It mirrors
//       `CopyTool` (same `.add`-per-entity / placeholder-id / attr-preservation
//       contract) but DEFAULTS to an immediate in-place duplicate: on activation
//       with a non-empty selection (the first event it sees) it emits the
//       duplicates at the fixed `offset` and `.finished`s — no base/destination
//       click flow. With an empty selection it is a no-op and nudges the user.
//
//  New copies carry the placeholder id (`EntityID(0)`); the app re-mints a real id
//  when it applies each `.add` via `CADDrawing.add` (ADR-001/ADR-002) — a tool
//  NEVER reuses a source id. Every other attribute (layer, pen, flags, geometry)
//  is preserved; only the geometry is translated by `offset` via the shared
//  `EntityKind.transformed(by:)` / `Affine2D.translation` path.
//
//  PURE (Tool contract): never touches CADDrawing / Quadtree / GUI. It reads only
//  the read-only `ToolContext.selected` and returns outcomes; the app applies the
//  `.add` edits as one undoable group and re-mints ids.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyMoveCopy lineage).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Duplicate (pure static API)

/// The PURE Duplicate API. Given the entities to duplicate (typically
/// `ToolContext.selected` / the app's current selection resolved to full
/// records), `duplicate(_:offset:)` returns one `.add` `ToolEdit` per entity: a
/// deep value copy of the source, translated by `offset`, carrying the
/// `.placeholder` id (the app re-mints on apply) and preserving the source's
/// layer / pen / flags. No interaction, no state — a ⌘D menu command can call
/// this directly and hand the result straight to `CanvasModel.applyCommit`.
public enum Duplicate {

    /// The default duplicate offset — a small nonzero nudge (in world units) so a
    /// freshly duplicated entity is visibly distinct from its source instead of
    /// landing exactly on top of it. Matches LibreCAD's "duplicate then move it a
    /// touch so you can grab it" behavior. A caller that wants an exact in-place
    /// duplicate passes `offset: Vector(0, 0)`.
    public static let defaultOffset = Vector(1, 1)

    /// Duplicates every entity in `entities`, returning one `.add` edit per entity.
    ///
    /// Each emitted record is a deep value copy of its source with:
    ///   - a NEW id: the `.placeholder` id (`EntityID(0)`); the app re-mints a real
    ///     id on `CADDrawing.add` — source ids are NEVER reused.
    ///   - the SAME layer / pen / flags as the source (every property preserved).
    ///   - geometry translated by `offset` via `EntityKind.transformed(by:)`
    ///     (`Affine2D.translation`). With `offset == Vector(0, 0)` the geometry is
    ///     an exact in-place copy (the translation is the identity in effect).
    ///
    /// An empty `entities` returns an empty array (nothing to duplicate → no edits).
    ///
    /// - Parameters:
    ///   - entities: the source entities to duplicate (full records, e.g. the
    ///     current selection).
    ///   - offset: the world-space displacement applied to every copy. Defaults to
    ///     `defaultOffset` (a small nudge); pass `Vector(0, 0)` for in-place copies.
    /// - Returns: one `.add(EntityRecord)` per source entity, in the same order.
    public static func duplicate(_ entities: [EntityRecord],
                                 offset: Vector = defaultOffset) -> [ToolEdit] {
        guard !entities.isEmpty else { return [] }
        let t = Affine2D.translation(offset)
        return entities.map { record in
            // ADD a deep copy: placeholder id (app re-mints → new id; source id is
            // NOT reused), original layer/pen/flags preserved, geometry translated.
            .add(EntityRecord(
                id: .placeholder,
                layer: record.layer,
                pen: record.pen,
                flags: record.flags,
                kind: record.kind.transformed(by: t)
            ))
        }
    }
}

// MARK: - DuplicateTool (interactive form)

/// The interactive Duplicate tool (AutoCAD-style ⌘D). Unlike `CopyTool`, it does
/// NOT collect a base/destination pick: with a non-empty selection it duplicates
/// the selection IMMEDIATELY at a fixed `offset` (a small nudge by default) and
/// finishes. With an empty selection it is a no-op and the status nudges the user
/// to select first.
///
/// The duplicates are emitted from the FIRST event the tool sees once it has a
/// non-empty selection (activation is modeled as that first `handle` call — the
/// app feeds an `.commit` / `.click` / `.move` right after making the tool
/// active). This keeps the tool a pure value type with no "activate()" side-channel
/// while still behaving as "do it now". Every form of input that carries a usable
/// selection triggers the one-shot duplicate; `.cancel` is a clean no-op finish.
public struct DuplicateTool: Tool {

    /// The fixed offset every duplicate is translated by. Defaults to the shared
    /// `Duplicate.defaultOffset` (a small nudge) so copies are visible; a caller
    /// can construct the tool with `Vector(0, 0)` for an exact in-place duplicate.
    private let offset: Vector

    /// Whether this tool has already emitted its duplicates. Once `true` the tool
    /// is spent (a single ⌘D = a single duplicate group); further input is a no-op
    /// finish. Prevents a stray second event from double-duplicating.
    private var didDuplicate = false

    /// Creates a Duplicate tool.
    /// - Parameter offset: the displacement applied to each copy. Defaults to
    ///   `Duplicate.defaultOffset` (a small nudge); pass `Vector(0, 0)` for an
    ///   exact in-place duplicate.
    public init(offset: Vector = Duplicate.defaultOffset) {
        self.offset = offset
    }

    // MARK: - Tool

    public var title: String { "Duplicate" }

    public var status: String {
        // After it has fired (or with nothing to act on) the prompt is the same
        // select-first nudge CopyTool/MoveTool use, so the HUD reads consistently.
        didDuplicate ? "Duplicate complete" : "Select objects to duplicate first"
    }

    /// Duplicate has no rubber-band: it commits immediately, so there is never a
    /// live preview to draw.
    public var preview: [ResolvedPolyline] { [] }

    /// A MODIFY tool with NO pick flow: the first usable event with a non-empty
    /// selection emits one `.add` per selected entity (an in-place / nudged copy)
    /// and finishes. `.cancel` finishes without duplicating.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .cancel:
            // Esc — bail out without duplicating.
            didDuplicate = true
            return .finished

        case .move, .click, .value, .commit, .backspace:
            // Any other event is treated as "do the duplicate now" (the app feeds
            // one of these right after activating the tool). Idempotent: only the
            // first one fires.
            guard !didDuplicate else { return .finished }
            let edits = Duplicate.duplicate(context.selected, offset: offset)
            didDuplicate = true
            // Nothing selected → nothing to duplicate: finish quietly (no commit).
            return edits.isEmpty ? .finished : .commit(edits)
        }
    }
}
