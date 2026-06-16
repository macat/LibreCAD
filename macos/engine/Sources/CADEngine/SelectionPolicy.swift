//
//  SelectionPolicy.swift
//  CADEngine
//
//  Pure, value-only helpers for the standard editing-selection primitives —
//  Select All / Deselect All / Invert Selection — split out of the app's
//  `CanvasModel` so the policy (which entities are *selectable*, and what the
//  complement of a selection is) lives in the engine and is unit-testable without
//  the SwiftUI/Metal executable target.
//
//  `CanvasModel` owns the live `Selection` (a view-side `Set<EntityID>`); these
//  helpers compute the id sets it should hold. They are intentionally stateless
//  static members of a namespaced `enum` (CONVENTIONS.md: no module-scope free
//  functions in a fan-out target).
//
//  ## Selectability (mirrors RS_Selection / hitTest)
//  An entity is selectable iff it is *visible AND editable*:
//    - its own `.visible` flag is set (a hidden entity can't be picked — same gate
//      `Selection.hitTest` / `windowSelect` use), AND
//    - its layer is neither LOCKED nor FROZEN. Entities on a locked layer cannot be
//      edited (LibreCAD `RS_Layer::locked`); a frozen layer is invisible. A missing
//      layer record (dangling `LayerID`) is treated as the default unlocked/visible
//      layer, matching `resolve()`'s fallback-to-default-pen behavior — it never
//      crashes and the entity stays pickable.
//
//  Select All therefore selects every *selectable* entity; Invert produces the
//  complement WITHIN the selectable set (locked/hidden entities are never toggled
//  IN by an invert, and an already-selected locked entity — should one exist — is
//  toggled OUT, so an invert can only ever shrink the locked footprint).
//
//  GPLv2-or-later (LibreCAD derivative). Selectability semantics port
//  RS_Selection + RS_Layer::locked/frozen (librecad/src/lib/engine).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Selection / RS_Layer).
//

import Foundation

/// Namespaced static helpers implementing the Select All / Invert selection policy.
public enum SelectionPolicy {

    /// Whether `entity` may be added to the selection: its `.visible` flag is set
    /// AND its layer is neither locked nor frozen. A dangling layer id (no record)
    /// is treated as unlocked + visible (the `resolve()` default-layer fallback), so
    /// the entity stays selectable rather than silently vanishing from Select All.
    public static func isSelectable(_ entity: EntityRecord, layers: LayerTable) -> Bool {
        guard entity.flags.contains(.visible) else { return false }
        if let layer = layers.layer(entity.layer) {
            return !layer.isLocked && !layer.isFrozen
        }
        return true
    }

    /// Every selectable entity's id in `drawing` (Select All). Order is the
    /// drawing's stable draw order, filtered to the selectable set.
    ///
    /// Block-DEFINITION members (ids in `drawing.blockMemberIDs`) are EXCLUDED: they
    /// are geometry the block owns (editable only inside the Block Editor or drawn via
    /// an `.insert`), never loose top-level entities. `selectableIDs`/`invertedIDs`
    /// bypass the active-space scope (they walk the whole `entities` array), so without
    /// this filter ⌘A and Invert would grab a block's members — the bug this guards.
    ///
    /// `@MainActor` because `CADDrawing` is main-actor-isolated (its `entities` /
    /// `layers` reads); the only callers — `CanvasModel` and the contract tests — are
    /// already on the main actor, so this adds no friction.
    @MainActor
    public static func selectableIDs(in drawing: CADDrawing) -> [EntityID] {
        let layers = drawing.layers
        let members = drawing.blockMemberIDs
        return drawing.entities.compactMap {
            (!members.contains($0.id) && isSelectable($0, layers: layers)) ? $0.id : nil
        }
    }

    /// The complement of `current` within the *selectable* set of `drawing`
    /// (Invert Selection): every selectable id that is NOT currently selected.
    ///
    /// Locked/hidden entities are excluded from the result entirely, so an invert
    /// never selects something the user cannot edit — and because the universe is
    /// the selectable set, a currently-selected locked entity is dropped (toggled
    /// OUT), which is the safe direction. Block-DEFINITION members
    /// (`drawing.blockMemberIDs`) are likewise excluded so an Invert never grabs a
    /// block's owned geometry (same rationale as `selectableIDs`).
    ///
    /// `@MainActor` for the same reason as `selectableIDs` (it reads `CADDrawing`).
    @MainActor
    public static func invertedIDs(current: Set<EntityID>, in drawing: CADDrawing) -> [EntityID] {
        let layers = drawing.layers
        let members = drawing.blockMemberIDs
        return drawing.entities.compactMap { entity in
            guard !members.contains(entity.id),
                  isSelectable(entity, layers: layers) else { return nil }
            return current.contains(entity.id) ? nil : entity.id
        }
    }
}
