//
//  TrimTool.swift
//  CADEngine
//
//  The TRIM editing tool — click the part of an entity to cut away, and that
//  overhang is removed up to the nearest cutting intersection with another
//  entity. Ported in spirit from LibreCAD's `RS_ActionModifyTrim` /
//  `RS_Modification::trim` (librecad/src/lib/modification/rs_modification.cpp +
//  librecad/src/actions/drawing/modify/rs_actionmodifytrim.cpp), distilled to the
//  single-click "click what you want gone" interaction this app uses.
//
//  Behavior (single click — no pre-selection needed):
//    1. The click point `p` (already snapped, WORLD coords) is the part of the
//       target to cut away. Among `context.nearbyEntities(p, tol)` the tool picks
//       the NEAREST LINE or ARC as the trim target (scope: line/arc; other kinds
//       are skipped).
//    2. The BOUNDARIES are every OTHER entity in the drawing (`context.allEntities()`
//       minus the target). The tool computes the exact intersections of the target
//       with each boundary via the shared `Intersections` kernels, keeping only the
//       points that actually lie ON the target (within its segment / arc sweep) AND
//       on the boundary (the kernels' range/segment filtering enforces this).
//    3. TRIM semantics (LibreCAD "remove the overhang you clicked"): of those
//       intersection points, the one NEAREST the click bounds the cut. The endpoint
//       of the target that is on the SAME side as the click — relative to that
//       intersection — is moved to the intersection; the side AWAY from the click is
//       kept. The tool emits `.commit([.replace(targetID, shortenedKind)])`.
//         - line → new `LineData` with the click-side endpoint moved to the
//                  intersection.
//         - arc  → new `ArcData` with the click-side angle (start or end) moved to
//                  the intersection's angle (keeping the side away from the click).
//    4. If no LINE/ARC target is under the click, or no cutting intersection bounds
//       the click, the input is a no-op (`.none`).
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` boundary hooks (`nearbyEntities` /
//  `allEntities`) plus the snapped world points in `ToolInput`, and computes the
//  cut entirely through the shared `Intersections` kernels. The app applies the
//  one `.replace` edit (preserving the target's id / layer / pen / flags) as one
//  undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyTrim / trim math).
//  Copyright (C) Dongxu Li (intersection / arc-trim kernels).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Trim tool. Click the part of a LINE or ARC you want to cut
/// away; the overhang is removed up to the nearest intersection with any other
/// entity (LibreCAD's modify-trim, single-click form).
public struct TrimTool: Tool {

    // MARK: - Mode configuration (driven by the options bar via CanvasModel)

    /// Which trim variant the interactive `handle` path performs. Set by the app
    /// from the options-bar selection (see `CanvasModel.applyToolConfig`); defaults
    /// to `.boundary` so a freshly minted tool behaves EXACTLY as before. The three
    /// modes are documented on `Mode` below.
    public var mode: Mode = .boundary

    /// The signed distance used by `.amount` (and `.amount` only). POSITIVE
    /// lengthens, NEGATIVE shortens, measured along the entity (straight for a line,
    /// by arc length for an arc) — see `trimAmount`. Ignored by `.boundary` /
    /// `.mutual`. Defaults to `0` (an `.amount` click with a zero amount is a no-op).
    public var amount: Double = 0

    /// Whether `.amount` applies the distance to BOTH ends (symmetric) rather than
    /// only the end nearer the pick. `false` is the LibreCAD-standard single-end
    /// form (`RS_ActionModifyTrimAmount` default); `true` selects the symmetric
    /// toggle (`trimAmountBoth`). Ignored by `.boundary` / `.mutual`.
    public var amountBoth: Bool = false

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. `.boundary` and `.amount` are SINGLE-click actions
    /// (one waiting state); `.mutual` needs TWO entity picks, so a second case
    /// carries the first pick made so far. Kept as an `enum` (not a flag) to match
    /// the tool family and stay exhaustive.
    private enum State: Equatable {
        /// Waiting for the click on the part of an entity to trim away (the only
        /// state for `.boundary` / `.amount`, and the FIRST pick for `.mutual`).
        case picking
        /// `.mutual` only: the first entity is fixed; waiting for the SECOND entity.
        /// `first` is the chosen first record (kept so the second pick can exclude
        /// it and the mutual-trim can reference its id); `firstPick` is the click
        /// point on the first entity (it selects which side of it is kept, matching
        /// LibreCAD's two-click trim2). Reached only when `mode == .mutual`.
        case pickingSecond(first: EntityRecord, firstPick: Vector)
    }

    /// The current state. Starts at the first pick.
    private var state: State = .picking

    /// The last cursor point seen via `.move`, used to drive the highlight preview
    /// of the geometry that WOULD remain after a trim at the cursor.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Trim" }

    public var status: String {
        switch mode {
        case .boundary:
            return "Click the part of a line or arc to trim away"
        case .amount:
            return "Click a line or arc near the end to trim by amount"
        case .mutual:
            switch state {
            case .picking:       return "Specify first entity to trim"
            case .pickingSecond: return "Specify second entity to trim"
            }
        }
    }

    /// The live preview: in `.boundary` mode, if a LINE/ARC under the cursor can be
    /// trimmed at the cursor, highlight the RESULTING (shortened) geometry with the
    /// preview pen. Empty when nothing would be trimmed (no target / no bounding
    /// intersection). The `.amount` / `.mutual` modes don't drive a move preview
    /// (they act on click — see `previewKind`, only populated by `.boundary` moves).
    public var preview: [ResolvedPolyline] {
        guard cursor.valid else { return [] }
        // The preview has no `ToolContext`, so it can only reflect what `.move`
        // captured. We recompute the trimmed geometry lazily from the cached
        // boundary snapshot taken on the last move (see `previewKind`).
        guard let kind = previewKind else { return [] }
        return kind.resolve(pen: .toolPreview, ctx: .default).polylines
    }

    /// The shortened geometry computed for the current cursor on the last `.move`
    /// (cached because `preview` has no context). Nil when nothing would trim.
    private var previewKind: EntityKind?

    /// A TRIM editing tool. The `mode` selects which variant a click performs (set
    /// by the app from the options bar):
    ///   - `.boundary` (default): reads the boundary hooks and, on a click, emits
    ///     ONE `.replace(targetID, kind)` shortening the clicked target up to the
    ///     nearest cutting intersection — UNCHANGED from the original tool.
    ///   - `.amount`: a single entity pick (near the end to act on) → emits ONE
    ///     `.replace` shortened/lengthened by `amount`. No boundary pick.
    ///   - `.mutual`: collects TWO entity picks → emits TWO `.replace`s (both
    ///     entities reshaped to their mutual intersection) as one undoable group.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value:
            // A typed coordinate doesn't apply to this entity-pick EDITING tool — ignore.
            return .none

        case .move(let p):
            cursor = p
            // The would-trim highlight is the `.boundary` preview only (the
            // amount/mutual modes act on click and have no single-cursor preview).
            previewKind = (mode == .boundary) ? Self.trim(at: p, context: context)?.kind : nil
            return previewKind == nil ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the preview / in-progress pick and finish.
            reset()
            return .finished

        case .commit:
            // Return — every mode commits on its click(s), so nothing is pending
            // here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click handling (dispatched on the active mode)

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch mode {
        case .boundary: return handleBoundaryClick(p, context: context)
        case .amount:   return handleAmountClick(p, context: context)
        case .mutual:   return handleMutualClick(p, context: context)
        }
    }

    /// `.boundary` (the default, UNCHANGED): find the nearest LINE/ARC target under
    /// the click and the shortened geometry; if either the target or a bounding
    /// intersection is missing, the click is a no-op.
    private mutating func handleBoundaryClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard let result = Self.trim(at: p, context: context) else { return .none }
        reset()
        return .commit([.replace(result.targetID, result.kind)])
    }

    /// `.amount`: ONE entity pick. Picks the nearest LINE/ARC under the click (the
    /// click point also chooses which end is acted on — see `trimAmount`), applies
    /// the signed `amount` (single-end, or both ends when `amountBoth`), and emits
    /// ONE `.replace`. A no-target click, a zero/degenerate amount, or a result that
    /// would collapse is a no-op.
    private mutating func handleAmountClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        let tol = Self.pickTolerance(context)
        guard let target = Self.nearestTarget(at: p, tolerance: tol, context: context) else {
            return .none
        }
        let trimmed = amountBoth
            ? Self.trimAmountBoth(target.kind, distance: amount)
            : Self.trimAmount(target.kind, near: p, distance: amount)
        guard let trimmed else { return .none }
        reset()
        return .commit([.replace(target.id, trimmed)])
    }

    /// `.mutual`: TWO entity picks. The first click fixes the first LINE/ARC (and
    /// the side to keep via its pick point); the second click selects a different
    /// LINE/ARC, and `mutualTrim` reshapes BOTH to their mutual intersection, emitted
    /// as TWO `.replace`s in one group. A no-target first pick keeps waiting; a
    /// no-target or degenerate second pick keeps waiting for a valid second entity.
    private mutating func handleMutualClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        let tol = Self.pickTolerance(context)
        switch state {
        case .picking:
            // First click selects the nearest LINE/ARC. A non-target (or empty)
            // pick is ignored — keep waiting for the first entity.
            guard let first = Self.nearestTarget(at: p, tolerance: tol, context: context) else {
                return .none
            }
            state = .pickingSecond(first: first, firstPick: p)
            cursor = p
            previewKind = nil
            return .none

        case .pickingSecond(let first, let firstPick):
            // Second click selects a DIFFERENT LINE/ARC and computes the mutual trim.
            guard let second = Self.nearestTarget(at: p, tolerance: tol,
                                                  exclude: first.id, context: context) else {
                return .none
            }
            guard let result = Self.mutualTrim(first.kind, pickA: firstPick,
                                               second.kind, pickB: p) else {
                // The carriers don't cross / a reshape collapses — drop the second
                // pick and keep waiting for a valid second entity.
                return .none
            }
            reset()
            return .commit([.replace(first.id, result.a), .replace(second.id, result.b)])
        }
    }

    /// Backspace: `.boundary` / `.amount` are single picks with nothing to step
    /// back; `.mutual` un-does the first-entity pick when one is pending.
    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .picking:
            return .none
        case .pickingSecond:
            // Undo the first-entity pick → back to waiting for the first entity.
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting state and drops the cached preview / pick.
    private mutating func reset() {
        state = .picking
        cursor = .invalid
        previewKind = nil
    }

    // MARK: - Trim computation (pure, self-contained)

    /// The picked tolerance aperture in world units. The app passes already-snapped
    /// points, so this only needs to be wide enough to resolve "which entity is
    /// under the click". Derived from the grid spacing when present, else a small
    /// fixed default. (A fraction of the grid keeps it stable across zoom levels;
    /// the fallback is a sane world-unit aperture.)
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance {
            return g * 0.5
        }
        return 0.5
    }

    /// The outcome of a trim: which entity to replace and the shortened geometry.
    struct TrimComputation {
        let targetID: EntityID
        let kind: EntityKind
    }

    /// Computes the trim for a click at `p`: pick the nearest LINE/ARC under the
    /// click, find the nearest cutting intersection that bounds the click, and
    /// shorten the target so the click-side overhang is removed. Returns `nil`
    /// when there is no LINE/ARC target or no bounding intersection.
    static func trim(at p: Vector, context: ToolContext) -> TrimComputation? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)

        // 1. Nearest LINE/ARC target under the click (scope: line/arc only).
        guard let target = nearestTarget(at: p, tolerance: tol, context: context) else {
            return nil
        }

        // 2. Boundaries = every other entity; collect all valid cutting points that
        //    lie ON the target AND on the boundary (kernels enforce both via their
        //    segment/arc-range filtering).
        let boundaries = context.allEntities().filter { $0.id != target.id }
        let cuts = intersectionPoints(of: target, with: boundaries)
        guard !cuts.isEmpty else { return nil }

        // 3. The intersection NEAREST the click bounds the cut.
        let (cut, _) = VectorSolutions(cuts).closest(to: p)
        guard cut.valid else { return nil }

        // 4. Shorten the target: move the click-side endpoint/angle to `cut`,
        //    keeping the side away from the click.
        switch target.kind {
        case .line(let d):
            guard let trimmed = trimLine(d, click: p, intersection: cut) else { return nil }
            return TrimComputation(targetID: target.id, kind: .line(trimmed))
        case .arc(let d):
            guard let trimmed = trimArc(d, click: p, intersection: cut) else { return nil }
            return TrimComputation(targetID: target.id, kind: .arc(trimmed))
        default:
            // Scope is line/arc; nearestTarget already excludes other kinds.
            // TODO(backlog): circle (→arc) / polyline / ellipse / spline trim.
            return nil
        }
    }

    /// The nearest LINE or ARC within `tolerance` of `p`, optionally excluding one
    /// id (so the `.mutual` second pick can't re-pick the first), or `nil`. Other
    /// kinds are skipped (scope: line/arc).
    static func nearestTarget(at p: Vector, tolerance: Double,
                              exclude: EntityID? = nil, context: ToolContext) -> EntityRecord? {
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tolerance) where e.id != exclude {
            switch e.kind {
            case .line, .arc:
                let d = HitTesting.worldDistance(from: p, to: e)
                if d < bestDist {
                    bestDist = d
                    best = e
                }
            default:
                // TODO(backlog): circle (→arc) / polyline / ellipse / spline.
                continue
            }
        }
        return best
    }

    /// All intersection points of `target` (a line or arc) with the boundary
    /// entities, keeping only points that lie ON the target's segment/sweep AND on
    /// the boundary (the kernels' range/segment filtering enforces this).
    static func intersectionPoints(of target: EntityRecord, with boundaries: [EntityRecord]) -> [Vector] {
        var pts: [Vector] = []
        for b in boundaries {
            let sols = intersect(target.kind, b.kind)
            for v in sols where v.valid {
                pts.append(v)
            }
        }
        return pts
    }

    /// Intersection of a TARGET line/arc with a BOUNDARY of any supported kind,
    /// dispatched to the matching `Intersections` kernel with on-entity filtering
    /// (`segment: true` for lines, arc-range filtering for arcs). Returns `[]` for
    /// kinds the kernels don't cover here. Both operands are always restricted to
    /// their finite extent so a returned point really is a crossing.
    static func intersect(_ target: EntityKind, _ boundary: EntityKind) -> VectorSolutions {
        switch target {
        case .line(let t):
            return lineBoundary(t, boundary)
        case .arc(let t):
            return arcBoundary(t, boundary)
        default:
            return VectorSolutions()
        }
    }

    /// Intersections of a target LINE segment with one boundary entity.
    private static func lineBoundary(_ t: LineData, _ boundary: EntityKind) -> VectorSolutions {
        switch boundary {
        case .line(let b):
            // Both finite: require the point on BOTH segments.
            return Intersections.lineLine(t.start, t.end, b.start, b.end, segment: true)
        case .circle(let b):
            return Intersections.lineCircle(line: (t.start, t.end),
                                            center: b.center, radius: b.radius, segment: true)
        case .arc(let b):
            return Intersections.lineArc(line: (t.start, t.end),
                                         center: b.center, radius: b.radius,
                                         angle1: b.startAngle, angle2: b.endAngle, reversed: b.reversed,
                                         fullCircle: false, segment: true)
        case .ellipse(let b):
            return onSegment(
                Intersections.lineEllipse(line: (t.start, t.end),
                                          center: b.center, majorP: b.majorP, ratio: b.ratio),
                line: (t.start, t.end))
        default:
            // TODO(backlog): polyline / spline boundaries (resolve to segments).
            return VectorSolutions()
        }
    }

    /// Intersections of a target ARC with one boundary entity (arc range filtered
    /// by the kernels; the line side is segment-restricted).
    private static func arcBoundary(_ t: ArcData, _ boundary: EntityKind) -> VectorSolutions {
        switch boundary {
        case .line(let b):
            return Intersections.lineArc(line: (b.start, b.end),
                                         center: t.center, radius: t.radius,
                                         angle1: t.startAngle, angle2: t.endAngle, reversed: t.reversed,
                                         fullCircle: false, segment: true)
        case .circle(let b):
            return Intersections.circleArc(circleCenter: b.center, circleRadius: b.radius,
                                           arcCenter: t.center, arcRadius: t.radius,
                                           arcAngle1: t.startAngle, arcAngle2: t.endAngle,
                                           arcReversed: t.reversed)
        case .arc(let b):
            return Intersections.arcArc(center1: t.center, radius1: t.radius,
                                        angle1Start: t.startAngle, angle1End: t.endAngle, reversed1: t.reversed,
                                        center2: b.center, radius2: b.radius,
                                        angle2Start: b.startAngle, angle2End: b.endAngle, reversed2: b.reversed)
        case .ellipse(let b):
            return Intersections.arcEllipse(arcCenter: t.center, arcRadius: t.radius,
                                            arcAngle1: t.startAngle, arcAngle2: t.endAngle, arcReversed: t.reversed,
                                            center: b.center, majorP: b.majorP, ratio: b.ratio)
        default:
            // TODO(backlog): polyline / spline boundaries (resolve to segments).
            return VectorSolutions()
        }
    }

    /// Keeps only the solution points lying on the finite line segment `(s, e)` —
    /// used where a kernel returns infinite-line solutions (e.g. `lineEllipse`).
    private static func onSegment(_ sols: VectorSolutions, line: (Vector, Vector)) -> VectorSolutions {
        let (s, e) = line
        let dir = e - s
        let len2 = dir.squared
        var out = VectorSolutions()
        let eps = 1e-9
        for v in sols where v.valid {
            if len2 < Tolerance.distanceSquared {
                if (v - s).squared <= Tolerance.distanceSquared { out.append(v) }
                continue
            }
            let u = (v - s).dot(dir) / len2
            if u >= -eps && u <= 1 + eps { out.append(v) }
        }
        return out
    }

    // MARK: - Per-kind shortening (the trim semantics)

    /// Shortens a LINE so the endpoint on the SAME side as the click (relative to
    /// `intersection`) is moved to the intersection; the side AWAY from the click
    /// is kept. Returns `nil` when the intersection is at (or past) an endpoint so
    /// no actual overhang would be removed.
    ///
    /// Side test (LibreCAD `RS_Line::getTrimPoint` semantics, sign flipped so we
    /// REMOVE the clicked side rather than keep it): the endpoint `q` is on the
    /// click side iff `(q − intersection) · (click − intersection) > 0`.
    static func trimLine(_ d: LineData, click p: Vector, intersection: Vector) -> LineData? {
        let toClick = p - intersection
        // A degenerate click exactly on the intersection can't pick a side.
        guard toClick.squared > Tolerance.distanceSquared else { return nil }

        let startSide = (d.start - intersection).dot(toClick)
        let endSide = (d.end - intersection).dot(toClick)

        // Move the endpoint on the click's side to the intersection. If neither is
        // on the click side (intersection lies beyond both, in the click
        // direction's opposite half) there is nothing to remove → nil.
        if endSide > Tolerance.distance && endSide >= startSide {
            // End is the click-side endpoint → move it in.
            guard (intersection - d.start).squared > Tolerance.distanceSquared else { return nil }
            return LineData(start: d.start, end: intersection)
        } else if startSide > Tolerance.distance {
            // Start is the click-side endpoint → move it in.
            guard (intersection - d.end).squared > Tolerance.distanceSquared else { return nil }
            return LineData(start: intersection, end: d.end)
        }
        return nil
    }

    /// Shortens an ARC so the click-side endpoint angle (start or end) moves to the
    /// intersection's angle, keeping the side away from the click. Returns `nil`
    /// when no real overhang would be removed.
    ///
    /// The arc's two sub-arcs about the intersection are `intersection→start` and
    /// `intersection→end` (in the arc's sweep direction). The click lies in exactly
    /// one of them; the endpoint of THAT sub-arc is the click-side endpoint and is
    /// moved to the intersection angle.
    static func trimArc(_ d: ArcData, click p: Vector, intersection: Vector) -> ArcData? {
        let ai = (intersection - d.center).angle
        let am = (p - d.center).angle

        // The intersection at angle `ai` splits the arc's sweep into two sub-arcs,
        // each taken in the arc's OWN direction (CCW unless reversed):
        //   start-side sub-arc:  startAngle → ai   (contains the START endpoint)
        //   end-side  sub-arc:   ai        → endAngle (contains the END endpoint)
        // The click lies in exactly one; the endpoint of THAT sub-arc is the
        // click-side endpoint and is the one moved to the intersection.
        let clickOnStartSide = MathUtils.isAngleBetween(am, d.startAngle, ai, reversed: d.reversed)
        let clickOnEndSide = MathUtils.isAngleBetween(am, ai, d.endAngle, reversed: d.reversed)

        // Move the click-side endpoint to the intersection angle. Prefer the side
        // the click is unambiguously in; if both/neither (click ~at intersection or
        // exactly on an endpoint) there's nothing meaningful to remove.
        if clickOnStartSide && !clickOnEndSide {
            // Click is between the START and the intersection → move start to `ai`,
            // keeping the `ai → end` sub-arc. Reject if that would be ~zero length.
            guard angularGap(ai, d.endAngle, reversed: d.reversed) > Tolerance.angle else { return nil }
            return ArcData(center: d.center, radius: d.radius,
                           startAngle: ai, endAngle: d.endAngle, reversed: d.reversed)
        } else if clickOnEndSide && !clickOnStartSide {
            // Click is between the intersection and the END → move end to `ai`,
            // keeping the `start → ai` sub-arc. Reject if that would be ~zero length.
            guard angularGap(d.startAngle, ai, reversed: d.reversed) > Tolerance.angle else { return nil }
            return ArcData(center: d.center, radius: d.radius,
                           startAngle: d.startAngle, endAngle: ai, reversed: d.reversed)
        }
        return nil
    }

    /// The swept angular gap from `from` to `to` in the arc's direction (CCW unless
    /// `reversed`), always in `[0, 2π)`. Used to reject a trim that would leave a
    /// zero-length arc.
    private static func angularGap(_ from: Double, _ to: Double, reversed: Bool) -> Double {
        MathUtils.getAngleDifference(from, to, reversed: reversed)
    }

    // MARK: - Trim modes (wired into `handle` via the `mode` field)

    /// The trim variants this tool can perform. The interactive `handle` path now
    /// dispatches on the settable `mode` field (set by the app from the options bar
    /// via `CanvasModel.applyToolConfig`); each mode is also backed by a PURE static
    /// entry point (`trim` / `trimAmount` / `trimAmountBoth` / `mutualTrim`) the
    /// click handlers call. (Modeled as an enum to mirror the LibreCAD action family.)
    ///
    /// - `.boundary`: the default. Click the overhang of a LINE/ARC to cut it back to
    ///                the nearest cutting intersection with another entity (the
    ///                existing `handle`/`trim(at:context:)` behavior — UNCHANGED).
    /// - `.amount`:   shorten OR lengthen a LINE/ARC at a chosen end by a numeric
    ///                signed distance (LibreCAD `RS_ActionModifyTrimAmount`). The
    ///                click handler drives `TrimTool.trimAmount(_:near:distance:)`
    ///                (single end) or `TrimTool.trimAmountBoth(_:distance:)` (the
    ///                symmetric both-ends form, when `amountBoth`).
    /// - `.mutual`:   trim/extend BOTH of two entities to their mutual intersection
    ///                (LibreCAD trim2). The two-click handler drives
    ///                `TrimTool.mutualTrim(_:pickA:_:pickB:)`.
    public enum Mode: Sendable, Equatable {
        /// Single-click cut-to-boundary (the unchanged default).
        case boundary
        /// Trim by a signed amount at a chosen end (`RS_ActionModifyTrimAmount`).
        case amount
        /// Mutual trim/extend of two entities to their intersection (trim2).
        case mutual
    }

    // MARK: - Mode 1: trim by amount (RS_ActionModifyTrimAmount)

    /// Shortens OR lengthens `kind` (a LINE or ARC) at ONE end by the signed
    /// `distance`, mirroring LibreCAD's `RS_ActionModifyTrimAmount` /
    /// `RS_Modification::trimAmount` (single-end form). PURE — no context, no GUI.
    ///
    /// Semantics (matching LibreCAD `trimAmount(coord, e, dist, trimBoth=false)`,
    /// which trims the endpoint nearer the pick to `getNearestDist(-dist, end)`):
    ///   - The end nearer `near` is the one that moves; the other end is the anchor.
    ///   - A POSITIVE `distance` LENGTHENS the entity at that end (moves the endpoint
    ///     outward, away from the anchor); a NEGATIVE `distance` SHORTENS it (moves
    ///     the endpoint inward, toward the anchor). The motion is measured ALONG the
    ///     entity — straight for a line, by arc length (`Δangle = distance / radius`)
    ///     for an arc.
    ///   - `byTotalLength == true` reinterprets `distance` as a desired TOTAL length
    ///     (the action's "total length" toggle): the applied signed delta becomes
    ///     `|distance| − currentLength`, so the result has that total length.
    ///
    /// Returns `nil` for an unsupported kind, an invalid `near`, a zero/degenerate
    /// delta, or a result whose length/sweep would collapse to ≤ 0 (mirrors the
    /// engine's clamp in `LengthenTool`).
    public static func trimAmount(_ kind: EntityKind, near: Vector, distance: Double,
                                  byTotalLength: Bool = false) -> EntityKind? {
        guard near.valid else { return nil }
        let moveEnd = LengthenTool.endNearerIsEnd(kind, point: near)
        let delta = byTotalLength ? (abs(distance) - currentLength(kind)) : distance
        guard abs(delta) > Tolerance.distance else { return nil }
        // The signed-delta lengthen math (positive = grow, negative = shrink at the
        // chosen end) is exactly LibreCAD's `getNearestDist(-dist, end)` outcome.
        return LengthenTool.lengthenByDelta(kind, moveEnd: moveEnd, delta: delta)
    }

    /// The symmetric (both-ends) form of trim-by-amount — LibreCAD's `trimAmount`
    /// with `trimBoth == true` (the action's "symmetric" toggle, valid only when NOT
    /// in total-length mode). Applies the SAME signed `distance` to BOTH ends:
    /// positive lengthens both ends outward, negative shortens both ends inward.
    ///
    /// Returns `nil` for an unsupported kind, a zero/degenerate delta, or a result
    /// that would collapse (e.g. shortening past the whole length / sweep).
    public static func trimAmountBoth(_ kind: EntityKind, distance: Double) -> EntityKind? {
        guard abs(distance) > Tolerance.distance else { return nil }
        // Grow/shrink the END first, then the START, by the same delta. Each step
        // reuses the clamped per-end lengthen so a collapse is rejected as `nil`.
        guard let afterEnd = LengthenTool.lengthenByDelta(kind, moveEnd: true, delta: distance) else {
            return nil
        }
        return LengthenTool.lengthenByDelta(afterEnd, moveEnd: false, delta: distance)
    }

    /// The current length of a LINE (Euclidean) or ARC (arc length), used by the
    /// total-length form of `trimAmount`. `0` for an unsupported kind.
    static func currentLength(_ kind: EntityKind) -> Double {
        switch kind {
        case .line(let d):
            return d.start.distance(to: d.end)
        case .arc(let d):
            let sweep = MathUtils.getAngleDifference(d.startAngle, d.endAngle, reversed: d.reversed)
            return abs(d.radius) * sweep
        default:
            return 0
        }
    }

    // MARK: - Mode 2: mutual trim / trim-2 (LibreCAD trim2)

    /// The result of a mutual trim: the new geometry for BOTH entities.
    public struct MutualTrim: Equatable {
        /// The trimmed/extended geometry for the first entity (`a`).
        public let a: EntityKind
        /// The trimmed/extended geometry for the second entity (`b`).
        public let b: EntityKind
    }

    /// MUTUAL TRIM (LibreCAD trim2): trims OR extends BOTH `a` and `b` so each ends
    /// at their mutual intersection point. PURE — no context, no GUI.
    ///
    /// `pickA` / `pickB` are the points the user clicked on each entity; like
    /// LibreCAD's two-click trim they select (1) which intersection to use when the
    /// pair crosses more than once — the intersection nearest the two picks — and
    /// (2) which side/end of each entity is reshaped: the endpoint nearer that
    /// entity's pick is the one moved to the intersection (so the picked portion is
    /// the part KEPT, matching the action where you click the segment to keep).
    ///
    /// Both entities are intersected on their INFINITE carrier (full line / full
    /// circle) so the operation EXTENDS as readily as it TRIMS — exactly the trim2
    /// behavior where a gap is closed by lengthening to the crossing. Supports
    /// line↔line, line↔arc, and arc↔arc (the line/arc scope of the rest of the tool).
    ///
    /// Returns `nil` when the kinds are unsupported, the carriers don't intersect,
    /// or either reshape would collapse an entity to zero length/sweep.
    public static func mutualTrim(_ a: EntityKind, pickA: Vector,
                                  _ b: EntityKind, pickB: Vector) -> MutualTrim? {
        guard pickA.valid, pickB.valid else { return nil }
        guard isMutualSupported(a), isMutualSupported(b) else { return nil }

        // The carriers' intersections (infinite line / full circle), choosing the one
        // nearest the picks so an ambiguous pair resolves to the clicked crossing.
        let cuts = carrierIntersections(a, b)
        guard !cuts.isEmpty else { return nil }
        let mid = (pickA + pickB) * 0.5
        let (cut, _) = VectorSolutions(cuts).closest(to: mid)
        guard cut.valid else { return nil }

        // Reshape each entity so the endpoint nearer its OWN pick reaches `cut`.
        guard let newA = reshapeToPoint(a, near: pickA, target: cut),
              let newB = reshapeToPoint(b, near: pickB, target: cut) else {
            return nil
        }
        return MutualTrim(a: newA, b: newB)
    }

    /// Whether `kind` is a supported operand for mutual trim (line / arc).
    static func isMutualSupported(_ kind: EntityKind) -> Bool {
        switch kind {
        case .line, .arc: return true
        default: return false
        }
    }

    /// All intersection points of the two entities taken on their INFINITE carriers
    /// (a line's whole infinite line, an arc's whole circle) so mutual trim can
    /// EXTEND to a crossing that lies beyond an entity's current extent, not only
    /// trim to one inside it. Line↔line / line↔arc / arc↔arc.
    static func carrierIntersections(_ a: EntityKind, _ b: EntityKind) -> [Vector] {
        let sols: VectorSolutions
        switch (a, b) {
        case (.line(let la), .line(let lb)):
            sols = Intersections.lineLine(la.start, la.end, lb.start, lb.end, segment: false)
        case (.line(let l), .arc(let ar)):
            sols = Intersections.lineCircle(line: (l.start, l.end),
                                            center: ar.center, radius: ar.radius, segment: false)
        case (.arc(let ar), .line(let l)):
            sols = Intersections.lineCircle(line: (l.start, l.end),
                                            center: ar.center, radius: ar.radius, segment: false)
        case (.arc(let a1), .arc(let a2)):
            sols = Intersections.circleCircle(center1: a1.center, radius1: a1.radius,
                                              center2: a2.center, radius2: a2.radius)
        default:
            sols = VectorSolutions()
        }
        return sols.filter(\.valid)
    }

    /// Reshapes `kind` (a LINE or ARC) so the appropriate endpoint is moved to the
    /// world point `target` (which lies on the entity's carrier). This is the
    /// trim-OR-extend primitive for mutual trim: it both shortens (when `target` is
    /// inside the current extent) and lengthens (when beyond it).
    ///
    /// Which endpoint moves is decided EXACTLY as LibreCAD's `getTrimPoint`
    /// (`RS_Line`/`RS_Arc`) using the pick `near`, so the result matches the trim2
    /// action's keep/discard choice:
    ///   - LINE: the side test `dot(start − near, target − near)`. When the start is
    ///           on the OPPOSITE side of the pick from `target` (dot < 0) the END is
    ///           moved to `target` (keeping the picked portion); otherwise the START
    ///           is moved. (`target` is on the line's carrier, so the moved endpoint
    ///           stays collinear.)
    ///   - ARC:  the end whose endpoint-angle is angularly NEARER the pick angle is
    ///           the one moved to `target`'s angle on the circle; rejected if the
    ///           resulting sweep collapses or exceeds a turn.
    /// Returns `nil` for an unsupported kind or a degenerate result.
    static func reshapeToPoint(_ kind: EntityKind, near: Vector, target: Vector) -> EntityKind? {
        guard target.valid else { return nil }
        switch kind {
        case .line(let d):
            // LibreCAD RS_Line::getTrimPoint: move the END iff start is on the far
            // side of the pick from the intersection.
            let moveEnd = (d.start - near).dot(target - near) < 0
            let anchor = moveEnd ? d.start : d.end
            guard (target - anchor).squared > Tolerance.distanceSquared else { return nil }
            let newLine = moveEnd ? LineData(start: anchor, end: target)
                                  : LineData(start: target, end: anchor)
            return .line(newLine)
        case .arc(let d):
            guard d.radius > Tolerance.distance else { return nil }
            // LibreCAD RS_Arc::getTrimPoint: move the end whose angle is nearer the
            // pick angle (the near-side overhang is removed / extended).
            let angMouse = (near - d.center).angle
            let dStart = abs((angMouse - d.startAngle).remainder(dividingBy: 2 * Double.pi))
            let dEnd = abs((angMouse - d.endAngle).remainder(dividingBy: 2 * Double.pi))
            let moveStart = dStart < dEnd
            let newAngle = (target - d.center).angle
            let candidate = moveStart
                ? ArcData(center: d.center, radius: d.radius,
                          startAngle: newAngle, endAngle: d.endAngle, reversed: d.reversed)
                : ArcData(center: d.center, radius: d.radius,
                          startAngle: d.startAngle, endAngle: newAngle, reversed: d.reversed)
            let sweep = MathUtils.getAngleDifference(candidate.startAngle, candidate.endAngle,
                                                     reversed: candidate.reversed)
            guard sweep > Tolerance.angle, sweep < 2 * Double.pi - Tolerance.angle else { return nil }
            return .arc(candidate)
        default:
            return nil
        }
    }
}
