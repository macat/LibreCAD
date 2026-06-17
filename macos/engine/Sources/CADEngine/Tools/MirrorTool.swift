//
//  MirrorTool.swift
//  CADEngine
//
//  A MODIFY tool — reflects the current selection across a user-drawn axis line.
//  Ported from LibreCAD's `RS_ActionModifyMirror`
//  (librecad/src/lib/actions/modify/rs_actionmodifymirror.*), with the magic
//  `int m_status` replaced by a private `enum State` and the two-click
//  (axis point 1 → axis point 2) interaction preserved. Modeled on `MoveTool`,
//  the reference MODIFY tool.
//
//  Behavior (reflect the current selection across the line through the two
//  picked axis points):
//    - it operates on `context.selected` (the entities the app handed it). With an
//      EMPTY selection there is nothing to mirror, so every input is a no-op and
//      the status tells the user to select first.
//    - first `.click`  → fix the first axis point (State.pickingAxis1 →
//                        .pickingAxis2(p1)) and capture the selection snapshot.
//    - `.move` in pickingAxis2 → rubber-band preview: every selected entity's kind
//                        `.transformed(by: .mirror(axisPoint1: p1, axisPoint2:
//                        cursor))`, resolved to `[ResolvedPolyline]` (the
//                        `.toolPreview` pen) so the live overlay shows the
//                        reflected selection across the in-progress axis.
//    - second `.click` → commit: emit one `.replace(id, kind.transformed(by:
//                        .mirror(axisPoint1: p1, axisPoint2: p2)))` per selected
//                        entity, then reset and report `.finished`. A degenerate
//                        axis (p2 ≈ p1) is ignored.
//    - `.backspace`    → step back from pickingAxis2 to pickingAxis1 (undo the
//                        first axis pick within this run; no commit).
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//
//  By default this is mirror-IN-PLACE (the originals are `.replace`d by their
//  reflection). With `keepOriginal == true` it is mirror-COPY: the originals are
//  kept and the reflection is emitted as NEW `.add` records (LibreCAD's "Keep
//  original" option). Both modes share the one orientation-reversing transform.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and builds geometry exclusively through the shared
//  `EntityKind.transformed(by:)` / `Affine2D.mirror(axisPoint1:axisPoint2:)` —
//  the single source of truth for "mirror an entity". The orientation-reversing
//  details (arc/ellipse `reversed` flip, polyline bulge-sign flip, degenerate-axis
//  → identity) all live in `EntityTransform` and are NOT re-implemented here. The
//  app applies the `.replace` edits (preserving each entity's id / layer / pen /
//  flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyMirror).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Mirror tool. Click two points to define a mirror axis line;
/// the current selection is reflected across that line (LibreCAD's mirror modify
/// action). Mirror-in-place: each selected entity is replaced by its reflection.
public struct MirrorTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyMirror`'s status
    /// integers (SetMirrorPoint1 → SetMirrorPoint2) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the first axis point (no axis point fixed yet).
        case pickingAxis1
        /// First axis point fixed; waiting for the second. `p1` is the first point
        /// of the mirror line the reflection is measured across.
        case pickingAxis2(p1: Vector)
    }

    /// The current state. Starts waiting for the first axis point.
    private var state: State = .pickingAxis1

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move after the first axis point is
    /// fixed.
    private var cursor: Vector = .invalid

    /// The selection snapshot captured when the first axis point is fixed, so the
    /// preview reflects exactly the entities that will be committed (the app
    /// rebuilds `context.selected` per call, but it stays stable for this run).
    private var selection: [EntityRecord] = []

    // MARK: - Public options

    /// Mirror-COPY toggle (W1-1C). When `false` (the default) this is
    /// mirror-IN-PLACE: each selected entity is `.replace`d by its reflection —
    /// byte-identical to the original behavior. When `true` the originals are kept
    /// and the reflected geometry is emitted as NEW entities (`.add`), i.e.
    /// mirror-and-keep (LibreCAD's "Keep original" option). Additive and
    /// default-off, so an unwired call site is completely unaffected.
    public var keepOriginal: Bool = false

    public init() {}

    // MARK: - Tool

    public var title: String { "Mirror" }

    public var status: String {
        switch state {
        case .pickingAxis1:
            // Nothing to mirror without a selection — tell the user to select first.
            return selection.isEmpty ? "Select objects to mirror first" : "Specify first point of mirror line"
        case .pickingAxis2:
            return "Specify second point of mirror line"
        }
    }

    /// The live rubber-band: the selected entities reflected across the line
    /// `p1 → cursor`, resolved to renderable polylines with the preview pen. Empty
    /// before the first axis point is set, before the cursor has moved, or with no
    /// selection.
    public var preview: [ResolvedPolyline] {
        guard case .pickingAxis2(let p1) = state,
              cursor.valid, p1.valid, !selection.isEmpty else {
            return []
        }
        let t = Affine2D.mirror(axisPoint1: p1, axisPoint2: cursor)
        return selection.flatMap { record -> [ResolvedPolyline] in
            let mirrored = EntityRecord(
                id: record.id,
                layer: record.layer,
                pen: record.pen,
                flags: record.flags,
                kind: record.kind.transformed(by: t)
            )
            // Resolve the mirrored geometry, then recolor every polyline with the
            // shared tool-preview pen so the overlay reads as a preview.
            return mirrored.resolve().polylines.map {
                ResolvedPolyline(points: $0.points, closed: $0.closed, pen: .toolPreview)
            }
        }
    }

    /// A MODIFY tool: it reads `context.selected` (the entities to reflect) and
    /// emits geometry edits — `.replace(id, newKind)` in the default mirror-in-place
    /// mode, or `.add(newRecord)` (originals kept) when `keepOriginal` is set.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value(let p):
            // A TYPED point (U1 coordinate line) is a "pick a point" event just like
            // `.click`, landing at the EXACT typed coordinate (no snap drift): route it
            // through the same axis-point pick path so the user can type the two mirror-
            // line points instead of clicking. Unified with `.click` (the ScaleTool/
            // OffsetTool precedent) — an empty selection still no-ops via the
            // `.pickingAxis1` guard inside `handleClick`.
            return handleClick(p, context: context)

        case .move(let p):
            cursor = p
            // A move only matters once the first axis point is fixed AND there's
            // something to preview (a non-empty selection).
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
            // Return — Mirror completes on its second click, so there's nothing
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingAxis1:
            // No selection → nothing to mirror; ignore the click.
            guard !context.selected.isEmpty else { return .none }
            // Capture the selection snapshot now so the preview/commit act on a
            // stable set, then fix the first axis point.
            selection = context.selected
            state = .pickingAxis2(p1: p)
            cursor = p
            return .none

        case .pickingAxis2(let p1):
            // Ignore a degenerate axis (the two points coincide): a reflection
            // across a zero-length line is undefined. `Affine2D.mirror` would
            // return `.identity` for it, but a no-op commit is wasteful — skip it
            // and keep waiting for a valid second point.
            guard p1.valid, p.valid, (p - p1).magnitude > Tolerance.distance else {
                return .none
            }
            // The mirror transform (orientation-reversing): arc/ellipse `reversed`
            // and polyline bulge-sign flips are handled inside `EntityTransform`.
            // The SAME `t` builds the reflected geometry in BOTH modes — derive it
            // once so mirror-copy's `.add` carries the identical orientation flips
            // that mirror-in-place's `.replace` does (do NOT re-derive per branch).
            let t = Affine2D.mirror(axisPoint1: p1, axisPoint2: p)
            let edits: [ToolEdit] = selection.map { record in
                let mirroredKind = record.kind.transformed(by: t)
                if keepOriginal {
                    // Mirror-COPY (W1-1C): keep the originals untouched and add the
                    // reflection as a NEW entity with the placeholder id (the app
                    // mints a fresh id on `add`). Preserve every other attribute
                    // (layer / pen / flags / space / layoutName) so the copy is a
                    // faithful duplicate of its source — only id and geometry differ.
                    return .add(EntityRecord(
                        id: .placeholder,
                        layer: record.layer,
                        pen: record.pen,
                        flags: record.flags,
                        kind: mirroredKind,
                        space: record.space,
                        layoutName: record.layoutName
                    ))
                } else {
                    // Mirror-IN-PLACE (default): replace each selected entity's
                    // geometry in place (id / layer / pen / flags preserved by the app).
                    return .replace(record.id, mirroredKind)
                }
            }
            reset()
            return .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingAxis1:
            // Nothing to step back.
            return .none
        case .pickingAxis2:
            // Step back to before the first axis pick (keep the captured selection
            // so the user can re-pick an axis without re-selecting).
            state = .pickingAxis1
            cursor = .invalid
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-axis-point state, dropping the
    /// captured selection snapshot and cursor.
    private mutating func reset() {
        state = .pickingAxis1
        cursor = .invalid
        selection = []
    }
}
