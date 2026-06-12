//
//  RotateTool.swift
//  CADEngine
//
//  A MODIFY tool that rotates the current selection about a pivot. Ported from
//  LibreCAD's `RS_ActionModifyRotate`
//  (librecad/src/lib/actions/modify/rs_actionmodifyrotate.*), with the magic
//  `int m_status` replaced by a private `enum State` and the three-pick
//  interaction (center → reference point → target point) preserved.
//
//  Behavior (rotate the current selection by `angle(center→target) − angle(center→reference)`):
//    - it operates on `context.selected` (the entities the app handed it). With an
//      EMPTY selection there is nothing to rotate, so every input is a no-op and
//      the status tells the user to select first.
//    - first `.click`  → fix the rotation CENTER and capture the selection
//                        snapshot (State.pickingCenter → .pickingRef(center)).
//    - second `.click` → fix the REFERENCE point; `refAngle = angle(center→ref)`
//                        defines "zero rotation" (State.pickingRef → .pickingTarget).
//    - `.move` in pickingTarget → rubber-band preview: each captured entity's kind
//                        `.transformed(by: .rotation(angle:, about: center))`
//                        where `angle = angle(center→cursor) − refAngle`, resolved
//                        to `[ResolvedPolyline]` (the `.toolPreview` pen) so the
//                        live overlay shows the selection rotating about the pivot.
//    - third `.click`  → commit: `angle = angle(center→target) − refAngle`; emit
//                        one `.replace(id, kind.transformed(by: .rotation(...)))`
//                        per selected entity, then reset and report `.finished`.
//                        A ~zero angle (target collinear with the reference) is
//                        ignored.
//    - `.backspace`    → step back one pick (pickingTarget → pickingRef →
//                        pickingCenter), undoing the in-progress picks without
//                        committing.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and builds geometry exclusively through the shared
//  `EntityKind.transformed(by:)` / `Affine2D.rotation(angle:about:)` — the single
//  source of truth for "rotate an entity". The app applies the `.replace` edits
//  (preserving each entity's id / layer / pen / flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyRotate).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Rotate tool. Click a center, then a reference point, then a
/// target point, to rotate the current selection about the center by the angle
/// swept from the reference to the target (LibreCAD's rotate modify action).
public struct RotateTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyRotate`'s status integers
    /// (SetReferencePoint → SetTargetPoint, with the center first) to an
    /// exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the rotation center / pivot (no fixed point yet).
        case pickingCenter
        /// Center fixed; waiting for the reference point that defines the zero
        /// angle. `center` is the pivot the rotation turns about.
        case pickingRef(center: Vector)
        /// Center + reference fixed; waiting for the target point. `center` is the
        /// pivot; `refAngle` is `angle(center→reference)` — the rotation is
        /// measured RELATIVE to this.
        case pickingTarget(center: Vector, refAngle: Double)
    }

    /// The current state. Starts waiting for the center point.
    private var state: State = .pickingCenter

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move after the reference is fixed.
    private var cursor: Vector = .invalid

    /// The selection snapshot captured when the center point is fixed, so the
    /// preview reflects exactly the entities that will be committed (the app
    /// rebuilds `context.selected` per call, but it stays stable for this run).
    private var selection: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Rotate" }

    public var status: String {
        switch state {
        case .pickingCenter:
            // Nothing to rotate without a selection — tell the user to select first.
            return selection.isEmpty ? "Select objects to rotate first" : "Specify rotation center"
        case .pickingRef:
            return "Specify reference point"
        case .pickingTarget:
            return "Specify target angle"
        }
    }

    /// The live rubber-band: the selected entities rotated about the center by
    /// `angle(center→cursor) − refAngle`, resolved to renderable polylines with the
    /// preview pen. Empty before the reference point is set, before the cursor has
    /// moved, with no selection, or when the swept angle is ~zero.
    public var preview: [ResolvedPolyline] {
        guard case .pickingTarget(let center, let refAngle) = state,
              cursor.valid, center.valid, !selection.isEmpty else {
            return []
        }
        let angle = Self.rotationAngle(center: center, target: cursor, refAngle: refAngle)
        guard abs(angle) > Tolerance.angle else { return [] }
        let t = Affine2D.rotation(angle: angle, about: center)
        return selection.flatMap { record -> [ResolvedPolyline] in
            // Resolve the rotated geometry directly with the shared tool-preview
            // pen so the overlay reads as a preview.
            record.kind.transformed(by: t)
                .resolve(pen: .toolPreview, ctx: .default)
                .polylines
        }
    }

    /// A MODIFY tool: it reads `context.selected` (the entities to rotate) and
    /// emits `.replace(id, newKind)` edits — never `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value:
            // A typed coordinate doesn't apply to this selection-based MODIFY tool — ignore.
            return .none

        case .move(let p):
            cursor = p
            // A move only matters once the reference is fixed AND there's something
            // to preview (a non-empty selection, non-zero angle).
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
            // Return — Rotate completes on its third click, so there's nothing
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingCenter:
            // No selection → nothing to rotate; ignore the click.
            guard !context.selected.isEmpty else { return .none }
            // Capture the selection snapshot now so the preview/commit act on a
            // stable set, then fix the center.
            selection = context.selected
            state = .pickingRef(center: p)
            cursor = p
            return .none

        case .pickingRef(let center):
            // The reference point defines the zero angle. A reference coincident
            // with the center has no direction — ignore it and keep waiting.
            guard center.valid, p.valid, (p - center).magnitude > Tolerance.distance else {
                return .none
            }
            let refAngle = center.angleTo(p)
            state = .pickingTarget(center: center, refAngle: refAngle)
            cursor = p
            return .none

        case .pickingTarget(let center, let refAngle):
            let angle = Self.rotationAngle(center: center, target: p, refAngle: refAngle)
            // Ignore a ~zero rotation (target collinear with the reference).
            guard center.valid, p.valid, abs(angle) > Tolerance.angle else {
                return .none
            }
            let t = Affine2D.rotation(angle: angle, about: center)
            let edits: [ToolEdit] = selection.map {
                .replace($0.id, $0.kind.transformed(by: t))
            }
            reset()
            return .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingCenter:
            // Nothing to step back.
            return .none
        case .pickingRef:
            // Step back to before the center pick (keep the captured selection so
            // the user can re-pick a center without re-selecting).
            state = .pickingCenter
            cursor = .invalid
            return .preview
        case .pickingTarget(let center, _):
            // Step back to before the reference pick.
            state = .pickingRef(center: center)
            cursor = .invalid
            return .preview
        }
    }

    /// Returns to the initial waiting-for-center state, dropping the captured
    /// selection snapshot and cursor.
    private mutating func reset() {
        state = .pickingCenter
        cursor = .invalid
        selection = []
    }

    // MARK: - Geometry

    /// The signed rotation to apply: the difference between the target direction
    /// and the reference direction, normalized to `[-π, π)` so a tiny clockwise
    /// turn reads as a small negative angle (not ~2π). Used by both the preview
    /// and the commit so they agree exactly.
    private static func rotationAngle(center: Vector, target: Vector, refAngle: Double) -> Double {
        let targetAngle = center.angleTo(target)
        return MathUtils.correctAnglePlusMinusPi(targetAngle - refAngle)
    }
}
