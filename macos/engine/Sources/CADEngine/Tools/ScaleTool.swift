//
//  ScaleTool.swift
//  CADEngine
//
//  A MODIFY tool — uniformly scales the current selection about a center point.
//  Ported in spirit from LibreCAD's `RS_ActionModifyScale`
//  (librecad/src/lib/actions/modify/rs_actionmodifyscale.*), with the magic
//  `int m_status` replaced by a private `enum State` and the three-pick
//  (center → reference distance → target distance) interaction preserved.
//
//  Behavior (uniformly scale the current selection about a center):
//    - it operates on `context.selected` (the entities the app handed it). With an
//      EMPTY selection there is nothing to scale, so every input is a no-op and the
//      status tells the user to select first.
//    - first  `.click` → fix the scale CENTER (the pivot every entity scales about)
//                        and capture the selection snapshot (State.pickingCenter →
//                        .pickingRef(center:)).
//    - second `.click` → fix the REFERENCE distance point: `refDist = |ref − center|`
//                        becomes the "old size". A near-zero reference distance is
//                        ignored (it would make the factor undefined). On success
//                        State.pickingRef → .pickingTarget(center:, refDist:).
//    - `.move` in pickingTarget → rubber-band preview: `factor = |cursor − center| /
//                        refDist`, and every captured entity's kind
//                        `.transformed(by: .scale(factor:, about: center))`, resolved
//                        to `[ResolvedPolyline]` with the `.toolPreview` pen so the
//                        live overlay shows the selection at the live factor.
//    - third  `.click` → commit: `factor = |target − center| / refDist`; emit one
//                        `.replace(id, kind.transformed(by: .scale(factor:, about:
//                        center)))` per captured entity, then reset and report the
//                        edits. A degenerate factor (≈ 0 or ≈ 1) is ignored — a
//                        factor of 1 is a no-op and a factor of 0 collapses the
//                        geometry to a point.
//    - `.backspace`    → step back one pick (pickingTarget → pickingRef →
//                        pickingCenter), keeping the captured selection so the user
//                        can re-pick without re-selecting.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and builds geometry exclusively through the shared
//  `EntityKind.transformed(by:)` / `Affine2D.scale(factor:about:)` — the single
//  source of truth for "uniformly scale an entity" (the uniform-`factor` path is
//  the exact one for circles/arcs/ellipses). The app applies the `.replace` edits
//  (preserving each entity's id / layer / pen / flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyScale).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Scale tool. Click a center, then a reference distance point,
/// then a target distance point, to uniformly scale the current selection about
/// the center by `|target − center| / |reference − center|` (LibreCAD's
/// scale-by-reference modify action).
public struct ScaleTool: Tool {

    // MARK: - Mode (additive — default reproduces the original behavior)

    /// How the scale factor is obtained. The default `.factor` mode is the
    /// original three-pick interaction (center → reference distance point →
    /// target distance point), unchanged byte-for-byte. The additive `.reference`
    /// mode lets the user define the factor from a FREE reference length (two
    /// independent points) and a new length, scaling about a separately-picked
    /// base — LibreCAD's "scale by reference length" workflow.
    ///
    /// This is an UNWIRED option: the public `mode` var exists so a later
    /// options-bar wire-wave can toggle it; the tool itself defaults to the
    /// original behavior and nothing else in the engine sets it yet.
    public enum ScaleMode: Sendable, Equatable {
        /// Original behavior: factor = |target − center| / |reference − center|,
        /// where the reference distance is measured from the picked center.
        case factor
        /// Scale-by-reference-length: pick a base (pivot), then a reference length
        /// as two FREE points, then a new length (point or typed value); the factor
        /// is `newLen / refLen` and the selection scales about the base.
        case reference
    }

    /// The active mode. Defaults to `.factor` (the original behavior). Public so a
    /// future options-bar can switch it; UNWIRED for now.
    public var mode: ScaleMode = .factor

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyScale`'s status integers
    /// (SetReferencePoint → SetFactor1/SetFactor2) to an exhaustive `enum`.
    private enum State: Equatable {
        // --- .factor mode (original three-pick interaction) ---
        /// Waiting for the scale center / pivot (no fixed point yet).
        case pickingCenter
        /// Center fixed; waiting for the reference distance point. `center` is the
        /// pivot every entity scales about.
        case pickingRef(center: Vector)
        /// Center + reference distance fixed; waiting for the target distance
        /// point. `refDist` is the "old size" the factor is measured against.
        case pickingTarget(center: Vector, refDist: Double)

        // --- .reference mode (scale-by-reference-length, four picks) ---
        /// Waiting for the base / pivot the selection scales about.
        case refPickingBase
        /// Base fixed; waiting for the FIRST point of the reference length segment.
        case refPickingStart(base: Vector)
        /// Base + reference-segment start fixed; waiting for the SECOND point of the
        /// reference length segment. `refStart` anchors both the reference length
        /// and (later) the new length.
        case refPickingEnd(base: Vector, refStart: Vector)
        /// Base + reference length fixed; waiting for the new length point (or a
        /// typed value). `refLen` is the "old size" and the new length is measured
        /// from `refStart`. The factor is `newLen / refLen`.
        case refPickingNew(base: Vector, refStart: Vector, refLen: Double)
    }

    /// The current state. Starts waiting for the center point (the `.factor`
    /// default's initial state). When `mode` is set to `.reference` BEFORE the run
    /// starts, the first `handle`/`status`/`preview` access lazily normalizes it to
    /// the reference mode's initial state (`refNormalizeIfIdle`).
    private var state: State = .pickingCenter

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move after the reference is fixed.
    private var cursor: Vector = .invalid

    /// The selection snapshot captured when the center is fixed, so the preview
    /// and commit act on exactly the entities chosen at the start of the run (the
    /// app rebuilds `context.selected` per call, but it stays stable for this run).
    private var selection: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Scale" }

    public var status: String {
        switch normalizedState {
        // --- .factor mode (original) ---
        case .pickingCenter:
            // Nothing to scale without a selection — tell the user to select first.
            return selection.isEmpty ? "Select objects to scale first" : "Specify center point"
        case .pickingRef:
            return "Specify reference distance point"
        case .pickingTarget:
            return "Specify target distance point"

        // --- .reference mode (scale-by-reference-length) ---
        case .refPickingBase:
            return selection.isEmpty ? "Select objects to scale first" : "Specify base point"
        case .refPickingStart:
            return "Specify first point of reference length"
        case .refPickingEnd:
            return "Specify second point of reference length"
        case .refPickingNew:
            return "Specify new length"
        }
    }

    /// The state as the current `mode` expects it. If the tool is still at the
    /// `.factor` default's initial state but `mode == .reference` (the wire-wave
    /// set the mode after construction), this presents the reference mode's initial
    /// state instead — without mutating (so `status`/`preview` can be `get`-only).
    private var normalizedState: State {
        if mode == .reference, state == .pickingCenter, selection.isEmpty {
            return .refPickingBase
        }
        return state
    }

    /// Mutating sibling of `normalizedState`: aligns the stored `state` with the
    /// current `mode` before a run begins. Called at the top of `handle` so the
    /// reference flow starts from `.refPickingBase` even though `state` is
    /// constructed at the `.factor` default.
    private mutating func refNormalizeIfIdle() {
        if mode == .reference, state == .pickingCenter, selection.isEmpty {
            state = .refPickingBase
        }
    }

    /// The live rubber-band: the selected entities scaled about the center by the
    /// current factor `|cursor − center| / refDist`, resolved to renderable
    /// polylines with the preview pen. Empty before the reference distance is set,
    /// before the cursor has moved, with no selection, or for a degenerate factor.
    public var preview: [ResolvedPolyline] {
        // Resolve the live (pivot, factor) pair for whichever mode is active; both
        // share the same "scale the selection about a pivot" rubber-band.
        let pivotFactor: (pivot: Vector, factor: Double)?
        switch normalizedState {
        case .pickingTarget(let center, let refDist):
            pivotFactor = validFactor(target: cursor, center: center, refDist: refDist)
                .map { (center, $0) }
        case .refPickingNew(let base, let refStart, let refLen):
            // New length = distance from the reference-segment start to the cursor.
            pivotFactor = validFactor(target: cursor, center: refStart, refDist: refLen)
                .map { (base, $0) }
        default:
            pivotFactor = nil
        }
        guard let (pivot, factor) = pivotFactor,
              cursor.valid, pivot.valid, !selection.isEmpty else {
            return []
        }
        let t = Affine2D.scale(factor: factor, about: pivot)
        return selection.flatMap { record -> [ResolvedPolyline] in
            // Transform the geometry, then resolve it directly with the shared
            // tool-preview pen so the overlay reads as a preview.
            record.kind.transformed(by: t)
                .resolve(pen: .toolPreview, ctx: .default)
                .polylines
        }
    }

    /// A MODIFY tool: it reads `context.selected` (the entities to scale) and emits
    /// `.replace(id, newKind)` edits — never `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        // Align the stored state with the active mode before the run starts (the
        // wire-wave may have set `mode = .reference` after construction). No-op for
        // the `.factor` default, so its behavior stays byte-identical.
        refNormalizeIfIdle()

        switch input {
        case .value(let p):
            // A TYPED point (U1 coordinate line) where a point/length is expected:
            // both modes treat it exactly like a `.click` at that exact point (no
            // snap drift). This is what lets the user type a reference/new length
            // or a base/center instead of clicking it. `.factor`'s existing tests
            // never feed `.value`, so the default behavior is unchanged.
            return handleClick(p, context: context)

        case .move(let p):
            cursor = p
            // A move only matters once a reference distance is fixed AND there's a
            // non-empty selection with a non-degenerate factor to preview.
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
            // Return — Scale completes on its third click, so there's nothing
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingCenter:
            // No selection → nothing to scale; ignore the click.
            guard !context.selected.isEmpty else { return .none }
            // Capture the selection snapshot now so the preview/commit act on a
            // stable set, then fix the center.
            selection = context.selected
            state = .pickingRef(center: p)
            cursor = p
            return .none

        case .pickingRef(let center):
            // The reference distance is the "old size". Ignore a near-zero
            // reference (it would make the factor undefined / divide by zero).
            let refDist = (p - center).magnitude
            guard center.valid, p.valid, refDist > Tolerance.distance else {
                return .none
            }
            state = .pickingTarget(center: center, refDist: refDist)
            cursor = p
            return .none

        case .pickingTarget(let center, let refDist):
            // factor = |target − center| / refDist. Ignore a degenerate factor
            // (≈ 1 is a no-op; ≈ 0 collapses the geometry to a point).
            guard let factor = validFactor(target: p, center: center, refDist: refDist) else {
                return .none
            }
            return commitScale(factor: factor, about: center)

        // --- .reference mode (scale-by-reference-length) ---

        case .refPickingBase:
            // No selection → nothing to scale; ignore the click.
            guard !context.selected.isEmpty, p.valid else { return .none }
            // Capture the selection snapshot now, then fix the base / pivot.
            selection = context.selected
            state = .refPickingStart(base: p)
            cursor = p
            return .none

        case .refPickingStart(let base):
            // First point of the FREE reference-length segment.
            guard p.valid else { return .none }
            state = .refPickingEnd(base: base, refStart: p)
            cursor = p
            return .none

        case .refPickingEnd(let base, let refStart):
            // Second point: refLen = |end − start| (the "old size"). Ignore a
            // near-zero reference length (it would make the factor undefined).
            let refLen = (p - refStart).magnitude
            guard p.valid, refLen > Tolerance.distance else { return .none }
            state = .refPickingNew(base: base, refStart: refStart, refLen: refLen)
            cursor = p
            return .none

        case .refPickingNew(let base, let refStart, let refLen):
            // New length = |new − refStart|; factor = newLen / refLen, scaled about
            // the base. Ignore a degenerate factor (≈ 1 no-op; ≈ 0 collapses).
            guard let factor = validFactor(target: p, center: refStart, refDist: refLen) else {
                return .none
            }
            return commitScale(factor: factor, about: base)
        }
    }

    /// Emits one `.replace` per captured entity, scaling its geometry by `factor`
    /// about `pivot`, then resets the run. Shared by both modes' commit arms.
    private mutating func commitScale(factor: Double, about pivot: Vector) -> ToolOutcome {
        let t = Affine2D.scale(factor: factor, about: pivot)
        let edits: [ToolEdit] = selection.map {
            .replace($0.id, $0.kind.transformed(by: t))
        }
        reset()
        return .commit(edits)
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        // --- .factor mode (original) ---
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
            // Step back to before the reference-distance pick.
            state = .pickingRef(center: center)
            cursor = .invalid
            return .preview

        // --- .reference mode (scale-by-reference-length) ---
        case .refPickingBase:
            // Nothing to step back.
            return .none
        case .refPickingStart:
            // Step back to before the base pick (keep the captured selection).
            state = .refPickingBase
            cursor = .invalid
            return .preview
        case .refPickingEnd(let base, _):
            // Step back to before the reference-start pick.
            state = .refPickingStart(base: base)
            cursor = .invalid
            return .preview
        case .refPickingNew(let base, let refStart, _):
            // Step back to before the reference-end pick.
            state = .refPickingEnd(base: base, refStart: refStart)
            cursor = .invalid
            return .preview
        }
    }

    // MARK: - Factor

    /// The scale factor `|target − center| / refDist`, or `nil` if it is
    /// degenerate (`refDist` ≈ 0, factor ≈ 0, or factor ≈ 1). A factor of 1 is a
    /// no-op and a factor of 0 collapses the geometry, so both are rejected.
    private func validFactor(target: Vector, center: Vector, refDist: Double) -> Double? {
        guard target.valid, center.valid, refDist > Tolerance.distance else { return nil }
        let factor = (target - center).magnitude / refDist
        guard factor > Tolerance.distance,
              abs(factor - 1) > Tolerance.distance else {
            return nil
        }
        return factor
    }

    /// Returns to the active mode's initial waiting state, dropping the captured
    /// selection snapshot and cursor. For the `.factor` default this is
    /// `.pickingCenter` (byte-identical to the original); for `.reference` it is
    /// `.refPickingBase`, so a second scale in the same run starts cleanly.
    private mutating func reset() {
        state = (mode == .reference) ? .refPickingBase : .pickingCenter
        cursor = .invalid
        selection = []
    }
}
