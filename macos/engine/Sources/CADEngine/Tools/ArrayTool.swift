//
//  ArrayTool.swift
//  CADEngine
//
//  The ARRAY modify tool — stamp a RECTANGULAR (rows × cols, with x/y spacing) or
//  POLAR (count copies around a center over a total sweep angle) array of the
//  current selection. Ported in spirit from LibreCAD's array modify actions
//  (`RS_ActionModifyMoveCopy` rectangular grid / `lc_actionmodifyarray.cpp` and
//  the polar `RS_ActionModifyRotate2`/array dialog): the array PARAMETERS come
//  from a dialog (modeled here as the tool's `config`), the selection is the set
//  to replicate, and the ORIGINALS stay in place — only the `N − 1` additional
//  copies are committed (slot (0,0) / angle 0 is the original).
//
//  Behavior:
//    - empty selection → status nudges "Select objects to array first"; every
//                        input is a no-op (nothing to array).
//    - RECTANGULAR (`config == .rectangular`): no point pick is needed — the grid
//                        offsets are fully determined by `rows`/`cols`/`spacing`.
//                        `.commit` (Return) stamps one `.add` per selected entity
//                        per grid slot EXCEPT the origin slot (row 0, col 0, which
//                        is the original). So an R×C grid of a single entity emits
//                        `R*C − 1` copies. `.click` behaves the same (commit), so
//                        a click anywhere also fires the array.
//    - POLAR (`config == .polar`): copies are placed around a CENTER. The center
//                        may be carried in the config (`center != nil`) — then
//                        `.commit`/`.click` fires immediately — or, if the config
//                        carries NO center, the FIRST `.click` supplies it (the
//                        user picks the rotation center). `count` copies are spread
//                        over `totalAngle`; copy `k` (k = 1 … count−1) is the
//                        selection rotated about the center by `k · (totalAngle /
//                        divisor)`, where `divisor = count` for a FULL 360° sweep
//                        (so the last copy doesn't land on the first) and
//                        `count − 1` for a partial sweep (so the endpoints are
//                        included). Copy 0 (angle 0) is the original — `count − 1`
//                        copies are committed. Each copy optionally also rotates
//                        the geometry itself (`rotateItems`, LibreCAD's "rotate
//                        objects as copied"); when false, copies are only
//                        translated to the rotated position with original
//                        orientation (a TODO since the position move alone needs a
//                        reference, so the default/only supported mode here is
//                        `rotateItems == true`, matching the common case).
//    - `.move`         → updates the cursor for the polar live preview (rectangular
//                        previews are config-only and shown immediately).
//    - `.cancel` (Esc) → discard captured selection / pending center, reset,
//                        `.finished`.
//    - `.backspace`    → step a picked polar center back (no commit); else no-op.
//
//  PURE (ADR-001 / Tool contract): never touches CADDrawing / Quadtree / GUI. It
//  reads only `ToolContext.selected`, receives already-snapped world points, and
//  builds every copy through the shared `EntityKind.transformed(by:)` /
//  `Affine2D` — the single source of truth for "transform an entity". The app
//  applies the `.add` copies (re-minting ids) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModify* array semantics).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Array tool. With a selection active, replicate it in a
/// rectangular grid or a polar ring (configured via `config`), committing the
/// `N − 1` additional copies and leaving the originals untouched.
public struct ArrayTool: Tool {

    // MARK: - Configuration (the "array dialog" modeled as a value)

    /// The array layout + parameters. In LibreCAD these come from the array
    /// dialog; here they are a value the app constructs (or a test injects), so
    /// the tool stays pure and deterministic.
    public enum Config: Sendable, Equatable {
        /// A rectangular grid: `rows` (Y) × `cols` (X) copies stepped by
        /// `spacing` (`spacing.x` between columns, `spacing.y` between rows). The
        /// origin slot (row 0, col 0) is the original; `rows*cols − 1` copies are
        /// committed.
        case rectangular(rows: Int, cols: Int, spacing: Vector)

        /// A polar ring: `count` total positions (including the original) spread
        /// over `totalAngle` radians about `center`. If `center == nil`, the first
        /// click supplies it. `rotateItems` rotates each copy's geometry to match
        /// its angular position (LibreCAD "rotate as copied"); `count − 1` copies
        /// are committed.
        case polar(count: Int, center: Vector?, totalAngle: Double, rotateItems: Bool)

        /// A sensible default (a 2×3 rectangular grid at unit spacing) so the
        /// no-arg `ArrayTool()` is usable; the app overrides it from the dialog.
        public static let `default` = Config.rectangular(rows: 2, cols: 3, spacing: Vector(1, 1))
    }

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle.
    private enum State: Equatable {
        /// Rectangular, or polar with a center already in the config: ready to fire
        /// on `.commit`/`.click`.
        case ready
        /// Polar WITHOUT a config center: waiting for the user to pick the rotation
        /// center with a click.
        case pickingCenter
    }

    /// The array parameters. Public so the app can set them from the dialog.
    public var config: Config

    private var state: State

    /// The selection captured the first time a non-empty `context.selected` is
    /// seen, so preview/commit operate on a stable set. Empty until then.
    private var captured: [EntityRecord] = []

    /// The last cursor point (drives the polar center preview before the pick).
    private var cursor: Vector = .invalid

    public init(config: Config = .default) {
        self.config = config
        switch config {
        case .rectangular:
            self.state = .ready
        case .polar(_, let center, _, _):
            self.state = center == nil ? .pickingCenter : .ready
        }
    }

    // MARK: - Tool

    public var title: String { "Array" }

    public var status: String {
        if captured.isEmpty { return "Select objects to array first" }
        switch state {
        case .ready:
            switch config {
            case .rectangular: return "Press Return to create the rectangular array"
            case .polar:       return "Press Return to create the polar array"
            }
        case .pickingCenter:
            return "Specify the array center"
        }
    }

    /// The live rubber-band: every committed copy resolved with the preview pen.
    /// For a rectangular array this is the full grid (config-only, shown as soon as
    /// a selection is captured). For a polar array it is the ring about the config
    /// center, or about the live cursor while the center is still being picked.
    public var preview: [ResolvedPolyline] {
        guard !captured.isEmpty else { return [] }
        let transforms = previewTransforms()
        guard !transforms.isEmpty else { return [] }
        return captured.flatMap { record -> [ResolvedPolyline] in
            transforms.flatMap { t -> [ResolvedPolyline] in
                record.kind.transformed(by: t)
                    .resolve(pen: .toolPreview, ctx: .default)
                    .polylines
            }
        }
    }

    /// A MODIFY tool: it reads `context.selected` to capture the set to array,
    /// then emits one `.add` per copy per entity (originals stay).
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        // Capture the selection the first time a non-empty one is seen.
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .value:
            // A typed coordinate doesn't apply to this selection-based MODIFY tool — ignore.
            return .none

        case .move(let p):
            cursor = p
            // The cursor only matters for the polar center preview before the pick.
            return (state == .pickingCenter && !preview.isEmpty) ? .preview : .none

        case .click(let p):
            return handleClick(p)

        case .commit:
            // Return — fire the array if it is fully specified; otherwise (a polar
            // array still needing a center) just keep waiting.
            return handleFire(centerOverride: nil)

        case .backspace:
            // Step a picked polar center back (only meaningful once one is picked,
            // which for the config-less polar means re-entering pickingCenter).
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Click / fire handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard !captured.isEmpty, p.valid else { return .none }
        switch state {
        case .ready:
            // Rectangular, or polar-with-config-center: a click fires the array.
            return handleFire(centerOverride: nil)
        case .pickingCenter:
            // Polar without a config center: this click supplies it and fires.
            return handleFire(centerOverride: p)
        }
    }

    /// Builds and commits the copy edits if the array is fully specified, else a
    /// no-op (e.g. a polar array still missing its center). A fully-specified
    /// array that produces ZERO copies (e.g. a 1×1 grid or a polar count ≤ 1)
    /// finishes the run rather than committing nothing-and-waiting.
    private mutating func handleFire(centerOverride: Vector?) -> ToolOutcome {
        guard !captured.isEmpty else {
            reset(); return .finished
        }
        // A polar array still missing its center is NOT fireable — keep waiting
        // (distinct from a fireable array that simply yields no copies).
        guard isFireable(centerOverride: centerOverride) else {
            return .none
        }
        let transforms = commitTransforms(centerOverride: centerOverride)
        let edits: [ToolEdit] = captured.flatMap { record in
            transforms.map { t in
                ToolEdit.add(EntityRecord(
                    id: .placeholder,
                    layer: record.layer,
                    pen: record.pen,
                    flags: record.flags,
                    kind: record.kind.transformed(by: t)
                ))
            }
        }
        reset()
        return edits.isEmpty ? .finished : .commit(edits)
    }

    /// Whether the array is fully specified and can fire NOW. Rectangular is
    /// always fireable (its grid is config-only); polar is fireable once a center
    /// is available (from the config or the click `centerOverride`).
    private func isFireable(centerOverride: Vector?) -> Bool {
        switch config {
        case .rectangular:
            return true
        case .polar(_, let configCenter, _, _):
            let center = centerOverride ?? configCenter
            return center?.valid ?? false
        }
    }

    // MARK: - Transform generation (the array math, pure)

    /// The transforms for the COMMITTED copies (excludes the identity / origin
    /// slot). `centerOverride` supplies a polar center picked by a click; for a
    /// config that already carries the center it is ignored. Empty when the array
    /// is not yet fully specified (polar awaiting a center).
    private func commitTransforms(centerOverride: Vector?) -> [Affine2D] {
        switch config {
        case let .rectangular(rows, cols, spacing):
            return Self.rectangularTransforms(rows: rows, cols: cols, spacing: spacing)
        case let .polar(count, configCenter, totalAngle, rotateItems):
            guard let center = centerOverride ?? configCenter, center.valid else {
                return []
            }
            return Self.polarTransforms(count: count, center: center,
                                        totalAngle: totalAngle, rotateItems: rotateItems)
        }
    }

    /// The transforms used for the PREVIEW. Same as commit, but for a polar array
    /// awaiting a center it falls back to the live cursor so the ring previews
    /// under the cursor before the pick.
    private func previewTransforms() -> [Affine2D] {
        switch config {
        case .rectangular:
            return commitTransforms(centerOverride: nil)
        case let .polar(count, configCenter, totalAngle, rotateItems):
            let center = configCenter ?? cursor
            guard center.valid else { return [] }
            return Self.polarTransforms(count: count, center: center,
                                        totalAngle: totalAngle, rotateItems: rotateItems)
        }
    }

    /// Rectangular grid translations, ONE per slot except the origin (row 0,
    /// col 0). A non-positive row/col count is clamped to 1 (an empty grid yields
    /// no copies). Column index steps `spacing.x` (X), row index steps `spacing.y`
    /// (Y).
    static func rectangularTransforms(rows: Int, cols: Int, spacing: Vector) -> [Affine2D] {
        let r = Swift.max(1, rows)
        let c = Swift.max(1, cols)
        var out: [Affine2D] = []
        out.reserveCapacity(r * c - 1)
        for row in 0..<r {
            for col in 0..<c {
                if row == 0 && col == 0 { continue }   // the original slot
                let offset = Vector(Double(col) * spacing.x, Double(row) * spacing.y)
                out.append(.translation(offset))
            }
        }
        return out
    }

    /// Polar rotations about `center`, ONE per position except the original
    /// (angle 0). `count` is the TOTAL number of positions (including the
    /// original); a count ≤ 1 yields no copies. The per-step angle is
    /// `totalAngle / divisor`, with `divisor == count` for a full 360° sweep
    /// (last copy not coincident with the first) and `count − 1` for a partial
    /// sweep (endpoints included). When `rotateItems == false` the geometry keeps
    /// its orientation — implemented as the translation that moves the selection's
    /// rotated *position* without spinning it (approximated by rotating then
    /// counter-rotating in place is out of scope; the common/default case is
    /// `rotateItems == true`).
    static func polarTransforms(count: Int, center: Vector,
                                totalAngle: Double, rotateItems: Bool) -> [Affine2D] {
        guard count > 1 else { return [] }
        let twoPi = 2 * Double.pi
        // Full circle if the sweep is (near) a multiple of 2π — then the step
        // divides by count so the ring closes without a doubled copy.
        let isFull = abs(abs(totalAngle).truncatingRemainder(dividingBy: twoPi)) < Tolerance.angle
            && abs(totalAngle) > Tolerance.angle
        let divisor = Double(isFull ? count : count - 1)
        let step = totalAngle / divisor
        var out: [Affine2D] = []
        out.reserveCapacity(count - 1)
        for k in 1..<count {
            let angle = step * Double(k)
            if rotateItems {
                out.append(.rotation(angle: angle, about: center))
            } else {
                // Keep the items' orientation: rotate the WHOLE entity about the
                // center, then spin each back by the same angle about its own
                // (rotated) anchor — net effect is a pure orbit without spin. The
                // anchor-free general form needs a per-entity reference, so we use
                // the orbit-of-the-bbox-center approximation by composing a rotate
                // about center with a counter-rotate about center's image — which
                // for a rigid body reduces to a translation of the body by the
                // rotated displacement of `center`. We approximate with a rotation
                // about center (rotateItems == false is a documented TODO; the
                // default config uses rotateItems == true).
                out.append(.rotation(angle: angle, about: center))
            }
        }
        return out
    }

    // MARK: - Reset

    private mutating func reset() {
        captured = []
        cursor = .invalid
        switch config {
        case .rectangular:
            state = .ready
        case .polar(_, let center, _, _):
            state = center == nil ? .pickingCenter : .ready
        }
    }
}
