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
        /// Non-uniform scale: the X and Y axes scale by INDEPENDENT factors
        /// `(sx, sy)` about a single picked base (pivot). The two factors come from
        /// `nonUniformFactors` (set by a later options-bar wire-wave — typed X/Y
        /// fields); the interaction is a single pick that fixes the base and commits.
        /// Uses `EntityTransform.scale(sx:sy:about:)` — the engine's non-uniform
        /// primitive — so e.g. an X-only stretch leaves Y untouched.
        case nonUniform
    }

    /// The active mode. Defaults to `.factor` (the original behavior). Public so a
    /// future options-bar can switch it; UNWIRED for now.
    public var mode: ScaleMode = .factor

    /// The independent `(sx, sy)` factors used by `.nonUniform` mode. Public so a
    /// later options-bar wire-wave can set typed X/Y fields; UNWIRED for now and
    /// defaulting to `(1, 1)` (a no-op the commit path rejects until the user enters
    /// a real factor). Ignored by `.factor`/`.reference` mode.
    public var nonUniformFactors: (sx: Double, sy: Double) = (1, 1)

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
        /// point. `refDist` is the "old size" the factor is measured against, and
        /// `refPoint` is the actual picked reference point (`|refPoint − center| ==
        /// refDist`) — kept so the overlay can draw a dashed `center → refPoint`
        /// guide marking the ORIGINAL size while the live ghost shows the new size.
        case pickingTarget(center: Vector, refDist: Double, refPoint: Vector)

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

        // --- .nonUniform mode (independent X/Y factors about one base) ---
        /// Waiting for the base / pivot the selection scales about with the
        /// independent `(sx, sy)` factors (from `nonUniformFactors`). The single
        /// pick fixes the base and immediately commits if the factors are valid.
        case nuPickingBase
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

        // --- .nonUniform mode ---
        case .nuPickingBase:
            return selection.isEmpty ? "Select objects to scale first" : "Specify base point"
        }
    }

    /// The state as the current `mode` expects it. If the tool is still at the
    /// `.factor` default's initial state but `mode == .reference` (the wire-wave
    /// set the mode after construction), this presents the reference mode's initial
    /// state instead — without mutating (so `status`/`preview` can be `get`-only).
    private var normalizedState: State {
        if state == .pickingCenter, selection.isEmpty {
            switch mode {
            case .factor: break
            case .reference: return .refPickingBase
            case .nonUniform: return .nuPickingBase
            }
        }
        return state
    }

    /// Mutating sibling of `normalizedState`: aligns the stored `state` with the
    /// current `mode` before a run begins. Called at the top of `handle` so the
    /// reference flow starts from `.refPickingBase` even though `state` is
    /// constructed at the `.factor` default.
    private mutating func refNormalizeIfIdle() {
        guard state == .pickingCenter, selection.isEmpty else { return }
        switch mode {
        case .factor: break
        case .reference: state = .refPickingBase
        case .nonUniform: state = .nuPickingBase
        }
    }

    /// The live rubber-band: the selected entities scaled about the center by the
    /// current factor `|cursor − center| / refDist`, resolved to renderable
    /// polylines with the preview pen. Empty before the reference distance is set,
    /// before the cursor has moved, with no selection, or for a degenerate factor.
    public var preview: [ResolvedPolyline] {
        guard let t = previewTransform, cursor.valid, !selection.isEmpty else {
            return []
        }
        return selection.flatMap { record -> [ResolvedPolyline] in
            // Transform the geometry, then resolve it directly with the shared
            // tool-preview pen so the overlay reads as a preview.
            record.kind.transformed(by: t)
                .resolve(pen: .toolPreview, ctx: .default)
                .polylines
        }
    }

    /// The live rubber-band transform for the active mode, or `nil` when there is
    /// nothing to preview (no pivot yet, degenerate factor, or no-op factors).
    /// `.factor`/`.reference` build a UNIFORM scale about a pivot from the cursor;
    /// `.nonUniform` builds a NON-UNIFORM `(sx, sy)` scale about the cursor as the
    /// prospective base, so the ghost shows the independent X/Y result before the
    /// base click that commits it.
    private var previewTransform: Affine2D? {
        switch normalizedState {
        case .pickingTarget(let center, let refDist, _):
            guard let factor = validFactor(target: cursor, center: center, refDist: refDist),
                  center.valid else { return nil }
            return .scale(factor: factor, about: center)
        case .refPickingNew(let base, let refStart, let refLen):
            // New length = distance from the reference-segment start to the cursor.
            guard let factor = validFactor(target: cursor, center: refStart, refDist: refLen),
                  base.valid else { return nil }
            return .scale(factor: factor, about: base)
        case .nuPickingBase:
            // Independent X/Y factors about the cursor (the prospective base). The
            // ghost tracks the cursor so the user sees where the non-uniform scale
            // will pivot before committing.
            guard let (sx, sy) = validNonUniformFactors(), cursor.valid else { return nil }
            return .scale(sx: sx, sy: sy, about: cursor)
        default:
            return nil
        }
    }

    /// A dashed guide marking the ORIGINAL reference size: a `center → refPoint`
    /// line (in `.factor` mode) drawn while picking the target distance, so the user
    /// sees the size they measured FROM while the live ghost shows the new size.
    /// Present only in the `.pickingTarget` drag phase; empty before the reference
    /// distance is fixed and after commit/cancel, so it never shows outside the
    /// active operation. The `.reference` mode keeps no reference line (its base/
    /// reference picks are FREE points, not a center→radius the guide would clarify).
    public var referenceSegments: [(Vector, Vector)] {
        guard case .pickingTarget(let center, _, let refPoint) = normalizedState,
              center.valid, refPoint.valid else {
            return []
        }
        return [(center, refPoint)]
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
            // In .nonUniform mode the base pick is also the commit, so there is no
            // post-pivot drag phase; instead the move itself drives the ghost about
            // the prospective base. Capture the selection snapshot lazily (without
            // fixing a base) so the live preview can reflect (sx, sy) as the cursor
            // tracks candidate base points. No-op for .factor/.reference.
            if case .nuPickingBase = normalizedState, selection.isEmpty {
                selection = context.selected
            }
            // A move only matters once there is a non-empty selection with a
            // non-degenerate factor to preview.
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
            // Keep the actual picked reference point (not just its distance) so the
            // overlay can draw the dashed `center → refPoint` original-size guide.
            state = .pickingTarget(center: center, refDist: refDist, refPoint: p)
            cursor = p
            return .none

        case .pickingTarget(let center, let refDist, _):
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

        // --- .nonUniform mode (independent X/Y factors about one base) ---

        case .nuPickingBase:
            // The single pick fixes the base/pivot AND commits, scaling each entity
            // by the independent (sx, sy) factors about it. The selection may already
            // have been snapshotted by a preceding `.move`; otherwise capture it now.
            // Ignore the click if there is nothing to scale or the factors are a
            // no-op / degenerate (≈ 1 in both axes, or ≈ 0 in either).
            guard p.valid else { return .none }
            let snapshot = selection.isEmpty ? context.selected : selection
            guard !snapshot.isEmpty, let (sx, sy) = validNonUniformFactors() else {
                return .none
            }
            selection = snapshot
            return commitNonUniform(sx: sx, sy: sy, about: p)
        }
    }

    /// Emits one `.replace` per captured entity, scaling its geometry by `factor`
    /// about `pivot`, then resets the run. Shared by both uniform modes' commit arms.
    private mutating func commitScale(factor: Double, about pivot: Vector) -> ToolOutcome {
        commitTransform(Affine2D.scale(factor: factor, about: pivot))
    }

    /// Emits one `.replace` per captured entity, scaling its geometry by the
    /// INDEPENDENT `(sx, sy)` factors about `pivot` via the engine's non-uniform
    /// primitive, then resets the run. The `.nonUniform` mode's commit arm.
    private mutating func commitNonUniform(sx: Double, sy: Double, about pivot: Vector) -> ToolOutcome {
        commitTransform(Affine2D.scale(sx: sx, sy: sy, about: pivot))
    }

    /// Shared commit: one `.replace(id, kind.transformed(by: t))` per captured
    /// entity, then reset. Used by both the uniform and non-uniform commit arms.
    private mutating func commitTransform(_ t: Affine2D) -> ToolOutcome {
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
        case .pickingTarget(let center, _, _):
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

        // --- .nonUniform mode (single pick → nothing to step back) ---
        case .nuPickingBase:
            return .none
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

    /// The independent `(sx, sy)` factors for `.nonUniform` mode, validated, or
    /// `nil` if they are degenerate. Each axis factor must be finite and non-zero
    /// (a 0 in either axis collapses that axis to a line/point); additionally the
    /// pair must not be the identity (`sx ≈ 1` AND `sy ≈ 1`), which is a no-op.
    /// A single axis equal to 1 (e.g. an X-only stretch `(2, 1)`) is allowed.
    private func validNonUniformFactors() -> (sx: Double, sy: Double)? {
        let (sx, sy) = nonUniformFactors
        guard sx.isFinite, sy.isFinite,
              abs(sx) > Tolerance.distance, abs(sy) > Tolerance.distance else {
            return nil
        }
        // Reject the identity (both axes ≈ 1) — it would emit no-op replaces.
        if abs(sx - 1) <= Tolerance.distance, abs(sy - 1) <= Tolerance.distance {
            return nil
        }
        return (sx, sy)
    }

    /// Returns to the active mode's initial waiting state, dropping the captured
    /// selection snapshot and cursor. For the `.factor` default this is
    /// `.pickingCenter` (byte-identical to the original); for `.reference` it is
    /// `.refPickingBase`, so a second scale in the same run starts cleanly.
    private mutating func reset() {
        switch mode {
        case .factor: state = .pickingCenter
        case .reference: state = .refPickingBase
        case .nonUniform: state = .nuPickingBase
        }
        cursor = .invalid
        selection = []
    }
}
