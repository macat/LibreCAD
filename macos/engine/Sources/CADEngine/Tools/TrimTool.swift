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

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. Trim is a SINGLE-click action, so there is one
    /// waiting state; kept as an `enum` (not a flag) to match the tool family and
    /// stay exhaustive if states are added.
    private enum State: Equatable {
        /// Waiting for the click on the part of an entity to trim away.
        case picking
    }

    /// The current state. There is only one.
    private var state: State = .picking

    /// The last cursor point seen via `.move`, used to drive the highlight preview
    /// of the geometry that WOULD remain after a trim at the cursor.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Trim" }

    public var status: String { "Click the part of a line or arc to trim away" }

    /// The live preview: if a LINE/ARC under the cursor can be trimmed at the
    /// cursor, highlight the RESULTING (shortened) geometry with the preview pen.
    /// Empty when nothing would be trimmed (no target / no bounding intersection).
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

    /// A TRIM editing tool: it reads the boundary hooks (`nearbyEntities` /
    /// `allEntities`) and, on a click, emits ONE `.replace(targetID, kind)` to
    /// shorten the clicked target up to the nearest cutting intersection.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // Recompute the would-trim preview from the live context so the
            // highlight tracks the cursor (the geometry kept after a trim here).
            previewKind = Self.trim(at: p, context: context)?.kind
            return previewKind == nil ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            // Trim is a single pick; there is nothing to step back.
            return .none

        case .cancel:
            // Esc — discard the preview and finish.
            reset()
            return .finished

        case .commit:
            // Return — trim commits on the click, so nothing is pending here.
            reset()
            return .finished
        }
    }

    // MARK: - Click handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        // Find the nearest LINE/ARC target under the click and the shortened
        // geometry; if either the target or a bounding intersection is missing,
        // the click is a no-op.
        guard let result = Self.trim(at: p, context: context) else { return .none }
        reset()
        return .commit([.replace(result.targetID, result.kind)])
    }

    /// Returns to the initial waiting state and drops the cached preview.
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

    /// The nearest LINE or ARC within `tolerance` of `p`, or `nil`. Other kinds
    /// are skipped (scope: line/arc).
    static func nearestTarget(at p: Vector, tolerance: Double, context: ToolContext) -> EntityRecord? {
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tolerance) {
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
}
