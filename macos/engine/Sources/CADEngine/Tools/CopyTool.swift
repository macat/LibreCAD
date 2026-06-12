//
//  CopyTool.swift
//  CADEngine
//
//  The COPY modify tool — duplicate the current selection at a base→destination
//  offset, leaving the originals in place. Ported in spirit from LibreCAD's
//  `RS_ActionModifyMoveCopy` with the `copy` flag set
//  (librecad/src/lib/actions/modify/lc_actionmodifymovecopy.cpp): it is the MOVE
//  tool that ADDS translated copies instead of replacing the originals.
//
//  Behavior (mirrors MOVE, but emits `.add` copies):
//    - empty selection → status "Select objects to copy first"; every input is a
//                        no-op (nothing to copy).
//    - first `.click`  → fix the base point (State.pickingBase → .pickingDest).
//    - `.move`         → rubber-band preview: each selected entity translated by
//                        `cursor − base` and resolved with the `.toolPreview` pen.
//    - second `.click` → commit one `.add` per selected entity, each a COPY of the
//                        original (same layer/pen/flags) with its geometry
//                        translated by `dest − base`, carrying the `.placeholder`
//                        id (the app re-mints on `CADDrawing.add`). The originals
//                        are untouched. A zero delta is ignored (no-op copy).
//                        After committing the tool RESETS to `.pickingBase` so the
//                        user can keep stamping copies of the SAME selection from a
//                        new base (LibreCAD "multiple copies" behavior) — it does
//                        NOT `.finished`; the app deactivates it on `.cancel`.
//    - `.backspace`    → step the base back (return to `.pickingBase`), no commit.
//    - `.cancel` (Esc) → discard the pending base/preview, reset, `.finished`.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It reads the read-only
//  `ToolContext.selected`, receives already-snapped world points, and returns
//  outcomes/preview; the app re-mints ids on commit (ADR-001/ADR-002).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyMoveCopy).
//

import Foundation

/// The interactive Copy tool. With a selection active, click a base point then a
/// destination point to duplicate every selected entity at that offset; the
/// originals stay. Stays active after a commit so the same selection can be
/// stamped repeatedly (reset to picking a fresh base).
public struct CopyTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. Ported from the MOVE/COPY action's status integers
    /// (SetReferencePoint / SetTargetPoint) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the base (reference) point.
        case pickingBase
        /// Base fixed; waiting for the destination point. `base` is the reference
        /// the offset is measured from.
        case pickingDest(base: Vector)
    }

    /// The current state. Starts waiting for the base point.
    private var state: State = .pickingBase

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The selection captured when the base was fixed, so the preview and commit
    /// operate on a stable set even if the live `context.selected` is rebuilt per
    /// call. Empty until a base is fixed against a non-empty selection.
    private var captured: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Copy" }

    public var status: String {
        switch state {
        case .pickingBase:
            // Distinguish "nothing selected yet" from "ready for the base point" so
            // the HUD nudges the user to select first (matches the empty-selection
            // no-op below).
            return captured.isEmpty ? "Select objects to copy first" : "Specify base point"
        case .pickingDest:
            return "Specify destination point"
        }
    }

    /// The live rubber-band: every captured (selected) entity translated by
    /// `cursor − base` and resolved with the preview pen. Empty before a base is
    /// fixed, before the cursor has moved, or with an empty selection.
    public var preview: [ResolvedPolyline] {
        guard case .pickingDest(let base) = state, cursor.valid, base.valid,
              !captured.isEmpty else {
            return []
        }
        let t = Affine2D.translation(cursor - base)
        return captured.flatMap { record -> [ResolvedPolyline] in
            // Resolve the TRANSLATED geometry, then stamp the shared preview pen on
            // every polyline so the rubber-band is drawn in the tool-preview style
            // regardless of the original entity's pen (an `.explicit` color would
            // otherwise pass straight through resolve()). The overlay may further
            // recolor previews at draw time.
            record.kind.transformed(by: t)
                .resolve(pen: .toolPreview, ctx: .default)
                .polylines
        }
    }

    /// A MODIFY tool: it reads `context.selected` to capture the set to copy, then
    /// emits one `.add` per selected entity (a translated COPY; originals stay).
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once a base is fixed.
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the pending base/preview and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — end the run. Copies are committed on the second click, so
            // there is nothing pending to add here; just finish.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingBase:
            // Nothing to copy without a selection — no-op (status nudges the user).
            guard !context.selected.isEmpty else { return .none }
            // Capture the selection NOW so the preview/commit operate on a stable
            // set, then fix the base and rubber-band toward the destination.
            captured = context.selected
            state = .pickingDest(base: p)
            cursor = p
            return .none

        case .pickingDest(let base):
            // Commit copies translated by base→p. Ignore a zero-length delta
            // (a copy onto itself is a no-op) — keep waiting for a real destination.
            guard base.valid, p.valid, (p - base).magnitude > Tolerance.distance else {
                return .none
            }
            let t = Affine2D.translation(p - base)
            let edits: [ToolEdit] = captured.map { record in
                // ADD a COPY (placeholder id; app re-mints). Preserve the original's
                // layer/pen/flags; only the geometry is translated. Originals stay.
                .add(EntityRecord(
                    id: .placeholder,
                    layer: record.layer,
                    pen: record.pen,
                    flags: record.flags,
                    kind: record.kind.transformed(by: t)
                ))
            }
            // Keep the tool active for multiple copies of the SAME selection: reset
            // to picking a fresh base (the captured set is retained). The app
            // deactivates the tool on `.cancel`.
            state = .pickingBase
            cursor = p
            return edits.isEmpty ? .none : .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingBase:
            // Nothing to step back.
            return .none
        case .pickingDest:
            // Step the base back to before it was fixed (no commit). The captured
            // selection is kept so a fresh base can be picked immediately.
            state = .pickingBase
            return .preview
        }
    }

    /// Returns to the initial waiting-for-base state and drops the captured set.
    private mutating func reset() {
        state = .pickingBase
        cursor = .invalid
        captured = []
    }
}
