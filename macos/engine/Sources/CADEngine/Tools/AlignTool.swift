//
//  AlignTool.swift
//  CADEngine
//
//  A MODIFY tool that ALIGNS the current selection onto a 2-point reference,
//  ported in spirit from AutoCAD's ALIGN command (the 2D, two-point-pair case)
//  and LibreCAD's modify-align family. The magic `int m_status` of the original
//  action interface is replaced by a private `enum State`, and the four-pick
//  interaction (source 1 → destination 1 → source 2 → destination 2) is preserved.
//
//  Behavior (map the SOURCE point pair onto the DESTINATION point pair):
//    The tool collects two source→destination point pairs and builds the single
//    `Affine2D` that carries `source1 → destination1` and (rotating, optionally
//    scaling) `source2 → destination2`, then applies it to the whole selection:
//
//      • TRANSLATION aligns source1 onto destination1.
//      • ROTATION turns the source segment's direction onto the destination
//        segment's direction: `angle(dest1→dest2) − angle(src1→src2)`.
//      • SCALE (when "scale to fit" is ON) uniformly resizes the selection so the
//        source segment's LENGTH matches the destination segment's length:
//        `|dest2 − dest1| / |src2 − src1|`. With "scale to fit" OFF the selection
//        keeps its size (factor 1) and only translates + rotates.
//
//    The resulting map is `p' = dest1 + (scale · R) · (p − src1)`, i.e. it fixes
//    `src1 → dest1` exactly and, under scale-to-fit, `src2 → dest2` exactly too.
//
//  Interaction:
//    - it operates on `context.selected` (the entities the app handed it). With an
//      EMPTY selection there is nothing to align, so every input is a no-op and
//      the status tells the user to select first.
//    - 1st `.click` → fix SOURCE point 1 and capture the selection snapshot
//                     (State.pickingSrc1 → .pickingDst1).
//    - 2nd `.click` → fix DESTINATION point 1 (.pickingDst1 → .pickingSrc2).
//    - 3rd `.click` → fix SOURCE point 2 (.pickingSrc2 → .pickingDst2).
//    - `.move` in pickingDst2 → rubber-band preview: the selection transformed by
//                     the align map for the current cursor as destination 2,
//                     resolved to `[ResolvedPolyline]` (the `.toolPreview` pen).
//    - 4th `.click` → commit: build the align `Affine2D` and emit one
//                     `.replace(id, kind.transformed(by:))` per selected entity,
//                     then reset and report `.finished`. A degenerate source pair
//                     (the two source points coincide) is ignored.
//    - `.backspace` → step back one pick, undoing the in-progress picks without
//                     committing.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//
//  Scale-to-fit toggle: `scaleToFit` (default `true`, the AutoCAD default prompt)
//  selects between the uniform-scale "fit" map and the rotate-only map. It is a
//  plain stored property the app's options bar can flip between runs; the preview
//  and the commit both read it, so they always agree.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and builds geometry exclusively through the shared
//  `EntityKind.transformed(by:)` / `Affine2D` — the single source of truth for
//  "transform an entity". The app applies the `.replace` edits (preserving each
//  entity's id / layer / pen / flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModify* transform semantics).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Align tool. Pick a source point and its destination, then a
/// second source point and its destination, to map the current selection so the
/// source pair lands on the destination pair (AutoCAD's ALIGN, 2D two-pair case).
/// `scaleToFit` chooses between uniform scale-to-fit and rotate-only.
public struct AlignTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle: four picks alternating source / destination.
    private enum State: Equatable {
        /// Waiting for the first SOURCE point (no fixed point yet).
        case pickingSrc1
        /// Source 1 fixed; waiting for its DESTINATION. `src1` is the first source
        /// point — the point that translation aligns onto destination 1.
        case pickingDst1(src1: Vector)
        /// Source 1 + destination 1 fixed; waiting for the second SOURCE point.
        case pickingSrc2(src1: Vector, dst1: Vector)
        /// Source 1 + destination 1 + source 2 fixed; waiting for the second
        /// DESTINATION (drives rotation + optional scale-to-fit).
        case pickingDst2(src1: Vector, dst1: Vector, src2: Vector)
    }

    /// The current state. Starts waiting for the first source point.
    private var state: State = .pickingSrc1

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move after source 2 is fixed.
    private var cursor: Vector = .invalid

    /// The selection snapshot captured when the first source point is fixed, so
    /// the preview reflects exactly the entities that will be committed (the app
    /// rebuilds `context.selected` per call, but it stays stable for this run).
    private var selection: [EntityRecord] = []

    /// When `true` (the AutoCAD default), the align map uniformly scales the
    /// selection so the source segment's length matches the destination segment's
    /// length (`source2 → destination2` exactly). When `false`, the selection
    /// keeps its size — translate + rotate only. The app's options bar can flip
    /// this between runs; the preview and commit both honor it.
    public var scaleToFit: Bool

    /// Creates an Align tool. `scaleToFit` defaults to `true` (AutoCAD's default
    /// "scale objects based on alignment points? <yes>").
    public init(scaleToFit: Bool = true) {
        self.scaleToFit = scaleToFit
    }

    // MARK: - Tool

    public var title: String { "Align" }

    public var status: String {
        switch state {
        case .pickingSrc1:
            // Nothing to align without a selection — tell the user to select first.
            return selection.isEmpty ? "Select objects to align first"
                                     : "Specify first source point"
        case .pickingDst1:
            return "Specify first destination point"
        case .pickingSrc2:
            return "Specify second source point"
        case .pickingDst2:
            return "Specify second destination point"
        }
    }

    /// The live rubber-band: the selected entities transformed by the align map
    /// built for the current cursor as destination 2, resolved to renderable
    /// polylines with the preview pen. Empty before source 2 is fixed, before the
    /// cursor has moved, with no selection, or when the align map is degenerate
    /// (coincident source points).
    public var preview: [ResolvedPolyline] {
        guard case .pickingDst2(let src1, let dst1, let src2) = state,
              cursor.valid, !selection.isEmpty,
              let t = Self.alignTransform(src1: src1, dst1: dst1, src2: src2, dst2: cursor,
                                          scaleToFit: scaleToFit) else {
            return []
        }
        return selection.flatMap { record -> [ResolvedPolyline] in
            // Resolve the transformed geometry directly with the shared
            // tool-preview pen so the overlay reads as a preview.
            record.kind.transformed(by: t)
                .resolve(pen: .toolPreview, ctx: .default)
                .polylines
        }
    }

    /// A MODIFY tool: it reads `context.selected` (the entities to align) and
    /// emits `.replace(id, newKind)` edits — never `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value:
            // A typed coordinate doesn't apply to this selection-based MODIFY tool — ignore.
            return .none

        case .move(let p):
            cursor = p
            // A move only matters once source 2 is fixed AND there's something to
            // preview (a non-empty selection, non-degenerate source pair).
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
            // Return — Align completes on its fourth click, so there's nothing
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingSrc1:
            // No selection → nothing to align; ignore the click.
            guard !context.selected.isEmpty, p.valid else { return .none }
            // Capture the selection snapshot now so the preview/commit act on a
            // stable set, then fix the first source point.
            selection = context.selected
            state = .pickingDst1(src1: p)
            cursor = p
            return .none

        case .pickingDst1(let src1):
            guard p.valid else { return .none }
            state = .pickingSrc2(src1: src1, dst1: p)
            cursor = p
            return .none

        case .pickingSrc2(let src1, let dst1):
            // Source 2 must be distinct from source 1 (the source segment defines
            // the direction/length to align onto the destination) — ignore a
            // coincident second source.
            guard p.valid, (p - src1).magnitude > Tolerance.distance else {
                return .none
            }
            state = .pickingDst2(src1: src1, dst1: dst1, src2: p)
            cursor = p
            return .none

        case .pickingDst2(let src1, let dst1, let src2):
            // Build the align map for this final destination 2. A degenerate
            // source pair yields nil — keep waiting (shouldn't happen since the
            // src2 pick guards distinctness, but stay safe).
            guard p.valid,
                  let t = Self.alignTransform(src1: src1, dst1: dst1, src2: src2, dst2: p,
                                              scaleToFit: scaleToFit) else {
                return .none
            }
            let edits: [ToolEdit] = selection.map {
                .replace($0.id, $0.kind.transformed(by: t))
            }
            reset()
            return .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingSrc1:
            // Nothing to step back.
            return .none
        case .pickingDst1:
            // Step back to before the first source pick (keep the captured
            // selection so the user can re-pick without re-selecting).
            state = .pickingSrc1
            cursor = .invalid
            return .preview
        case .pickingSrc2(let src1, _):
            state = .pickingDst1(src1: src1)
            cursor = .invalid
            return .preview
        case .pickingDst2(let src1, let dst1, _):
            state = .pickingSrc2(src1: src1, dst1: dst1)
            cursor = .invalid
            return .preview
        }
    }

    /// Returns to the initial waiting-for-source-1 state, dropping the captured
    /// selection snapshot and cursor. The `scaleToFit` toggle is preserved across
    /// runs (it's a user setting, not part of the in-progress pick state).
    private mutating func reset() {
        state = .pickingSrc1
        cursor = .invalid
        selection = []
    }

    // MARK: - Geometry

    /// Builds the affine that maps the SOURCE pair onto the DESTINATION pair.
    ///
    /// The map fixes `src1 → dst1` exactly and rotates the source segment's
    /// direction onto the destination segment's direction. Under `scaleToFit` it
    /// also scales uniformly so `src2 → dst2` exactly (`|dst2−dst1| / |src2−src1|`);
    /// otherwise the factor is 1 (rotate-only, size preserved).
    ///
    /// Concretely: `p' = dst1 + (scale · R) · (p − src1)`, where
    /// `R = rotation(angle(dst1→dst2) − angle(src1→src2))`. Returns `nil` if the
    /// source pair is degenerate (the two source points coincide) — there is no
    /// direction or length to align from.
    ///
    /// Shared by the preview and the commit so they always agree.
    static func alignTransform(src1: Vector, dst1: Vector,
                               src2: Vector, dst2: Vector,
                               scaleToFit: Bool) -> Affine2D? {
        guard src1.valid, dst1.valid, src2.valid, dst2.valid else { return nil }

        let srcVec = src2 - src1
        let srcLen = srcVec.magnitude
        // Degenerate source segment → no direction/length to align from.
        guard srcLen > Tolerance.distance else { return nil }

        let dstVec = dst2 - dst1
        let angle = dstVec.angle - srcVec.angle

        // Uniform scale to fit the destination segment's length, or 1 (rotate-only).
        let scale: Double
        if scaleToFit {
            let dstLen = dstVec.magnitude
            scale = dstLen / srcLen
        } else {
            scale = 1.0
        }

        // Linear part: rotate by `angle`, then uniformly scale by `scale`
        // (a similarity — order doesn't matter for uniform scale × rotation).
        let cs = cos(angle), sn = sin(angle)
        let a = scale * cs
        let b = scale * -sn
        let c = scale * sn
        let d = scale * cs

        // Translation so that src1 maps exactly to dst1:
        //   p' = M·(p − src1) + dst1 = M·p + (dst1 − M·src1).
        let mSrc1x = a * src1.x + b * src1.y
        let mSrc1y = c * src1.x + d * src1.y
        let tx = dst1.x - mSrc1x
        let ty = dst1.y - mSrc1y

        return Affine2D(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}
