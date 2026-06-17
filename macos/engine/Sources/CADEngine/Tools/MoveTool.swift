//
//  MoveTool.swift
//  CADEngine
//
//  The reference MODIFY tool — the first concrete `Tool` that edits EXISTING
//  geometry instead of drawing new geometry. Ported from LibreCAD's
//  `RS_ActionModifyMove` (librecad/src/lib/actions/modify/rs_actionmodifymove.*),
//  with the magic `int m_status` replaced by a private `enum State` and the
//  two-click (base point → destination) interaction preserved.
//
//  Behavior (translate the current selection by `destination − base`):
//    - it operates on `context.selected` (the entities the app handed it). With an
//      EMPTY selection there is nothing to move, so every input is a no-op and the
//      status tells the user to select first.
//    - first `.click`  → fix the base/reference point (State.pickingBase →
//                        .pickingDest(base:)).
//    - `.move` in pickingDest → rubber-band preview: every selected entity's kind
//                        `.transformed(by: .translation(cursor − base))`, resolved
//                        to `[ResolvedPolyline]` (the `.toolPreview` pen) so the
//                        live overlay shows the selection at the cursor offset.
//    - second `.click` → commit: `delta = destination − base`; emit one
//                        `.replace(id, kind.transformed(by: .translation(delta)))`
//                        per selected entity, then reset and report `.finished`.
//                        A zero delta (destination == base) is ignored.
//    - `.backspace`    → step back from pickingDest to pickingBase (undo the base
//                        pick within this run; no commit).
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and builds geometry exclusively through the shared
//  `EntityKind.transformed(by:)` / `Affine2D.translation` — the single source of
//  truth for "move an entity". The app applies the `.replace` edits (preserving
//  each entity's id / layer / pen / flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyMove).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Move tool. Click a base point, then a destination, to
/// translate the current selection by `destination − base` (LibreCAD's
/// move/displacement modify action).
public struct MoveTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyMove`'s status integers
    /// (SetReferencePoint → SetTargetPoint) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the base / reference point (no fixed point yet).
        case pickingBase
        /// Base point fixed; waiting for the destination. `base` is the reference
        /// point the translation is measured FROM.
        case pickingDest(base: Vector)
    }

    /// The current state. Starts waiting for the base point.
    private var state: State = .pickingBase

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move after the base is fixed.
    private var cursor: Vector = .invalid

    /// The selection snapshot captured when the base point is fixed, so the
    /// preview reflects exactly the entities that will be committed (the app
    /// rebuilds `context.selected` per call, but it stays stable for this run).
    private var selection: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Move" }

    public var status: String {
        switch state {
        case .pickingBase:
            // Nothing to move without a selection — tell the user to select first.
            return selection.isEmpty ? "Select objects to move first" : "Specify base point"
        case .pickingDest:
            return "Specify destination"
        }
    }

    /// The live rubber-band: the selected entities translated by `cursor − base`,
    /// resolved to renderable polylines with the preview pen. Empty before the
    /// base point is set, before the cursor has moved, or with no selection.
    public var preview: [ResolvedPolyline] {
        guard case .pickingDest(let base) = state,
              cursor.valid, base.valid, !selection.isEmpty else {
            return []
        }
        let t = Affine2D.translation(cursor - base)
        return selection.flatMap { record -> [ResolvedPolyline] in
            let moved = EntityRecord(
                id: record.id,
                layer: record.layer,
                pen: record.pen,
                flags: record.flags,
                kind: record.kind.transformed(by: t)
            )
            // Resolve the moved geometry, then recolor every polyline with the
            // shared tool-preview pen so the overlay reads as a preview.
            return moved.resolve().polylines.map {
                ResolvedPolyline(points: $0.points, closed: $0.closed, pen: .toolPreview)
            }
        }
    }

    /// A dashed guide from the BASE point to the current cursor — the displacement
    /// vector, so the user sees "where we started from" while dragging the ghost to
    /// the destination. Present only while a base is fixed and the cursor is valid
    /// (the `.pickingDest` drag phase); empty before the base is picked and after
    /// commit/cancel, so it never shows outside the active operation.
    public var referenceSegments: [(Vector, Vector)] {
        guard case .pickingDest(let base) = state, cursor.valid, base.valid else {
            return []
        }
        return [(base, cursor)]
    }

    /// A MODIFY tool: it reads `context.selected` (the entities to translate) and
    /// emits `.replace(id, newKind)` edits — never `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value(let p):
            // A TYPED point (U1 coordinate line) is a "pick a point" event just like
            // `.click`, landing at the EXACT typed coordinate (no snap drift): route it
            // through the same base→destination pick path so MOVE-by-exact-delta works
            // (type the base, then `@dx,dy` for the destination). Unified with `.click`
            // (the ScaleTool/OffsetTool precedent) — an empty selection still no-ops via
            // the `.pickingBase` guard inside `handleClick`.
            return handleClick(p, context: context)

        case .move(let p):
            cursor = p
            // A move only matters once a base point is fixed AND there's something
            // to preview (a non-empty selection).
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — Move completes on its second click, so there's nothing
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingBase:
            // No selection → nothing to move; ignore the click.
            guard !context.selected.isEmpty else { return .none }
            // Capture the selection snapshot now so the preview/commit act on a
            // stable set, then fix the base point.
            selection = context.selected
            state = .pickingDest(base: p)
            cursor = p
            return .none

        case .pickingDest(let base):
            let delta = p - base
            // Ignore a zero-length move (destination coincides with the base).
            guard base.valid, p.valid, delta.magnitude > Tolerance.distance else {
                return .none
            }
            let t = Affine2D.translation(delta)
            let edits: [ToolEdit] = selection.map {
                .replace($0.id, $0.kind.transformed(by: t))
            }
            reset()
            return .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingBase:
            // Nothing to step back.
            return .none
        case .pickingDest:
            // Step back to before the base pick (keep the captured selection so
            // the user can re-pick a base without re-selecting).
            state = .pickingBase
            cursor = .invalid
            return .preview
        }
    }

    /// Returns to the initial waiting-for-base-point state, dropping the captured
    /// selection snapshot and cursor.
    private mutating func reset() {
        state = .pickingBase
        cursor = .invalid
        selection = []
    }
}
