//
//  ExtendTool.swift
//  CADEngine
//
//  The EXTEND editing tool — click near the end of a line/arc to lengthen it to
//  the nearest boundary that lies BEYOND that end. Ported in spirit from
//  LibreCAD's `RS_ActionModifyExtend` / the lengthen-to-boundary family
//  (librecad/src/lib/actions/modify): you pick the entity near the end you want
//  to grow, and it snaps out to the first thing it would hit if you extended its
//  geometry indefinitely in that direction.
//
//  Behavior (single click, no selection needed):
//    - `.click(p)`:
//        1. TARGET — the nearest LINE or ARC in `context.nearbyEntities(p, tol)`
//           (by exact distance to the pick). Other kinds are skipped (scope is
//           line/arc; see the `// TODO(backlog)` arm). The END to extend is the
//           target endpoint nearer to the click `p`.
//        2. BOUNDARIES — `context.allEntities()` minus the target. The target's
//           INFINITE extension (the full line for a line, the full circle for an
//           arc) is intersected with every boundary via `Intersections`; only the
//           hits that lie ON the boundary (the kernels filter to the boundary's
//           true extent) AND BEYOND the chosen end (in the extend direction) are
//           kept.
//        3. The NEAREST such hit to the current end becomes the new endpoint:
//           emit `.commit([.replace(targetID, extendedKind)])` — for a line the
//           chosen endpoint is moved out to the hit; for an arc the start/end
//           angle is extended to the hit's angle (sweep direction preserved).
//           If no boundary lies beyond the end (or no target was found) → `.none`.
//    - `.move`      → no preview yet (Extend acts on the single click); `.none`.
//    - `.cancel`    → `.finished`.
//    - `.commit` / `.backspace` → nothing pending for this single-click tool.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` boundary hooks
//  (`nearbyEntities`/`allEntities`) plus the snapped world point in `ToolInput`,
//  and computes the extension entirely through the shared `Intersections`
//  kernels. The app applies the single `.replace` (preserving the entity's id /
//  layer / pen / flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyExtend).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Extend tool. Click near the end of a line or arc to lengthen
/// it out to the nearest boundary that lies beyond that end (LibreCAD's
/// extend / lengthen-to-boundary modify action).
public struct ExtendTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. Extend is a SINGLE-click action: there is one
    /// waiting state. Kept as an `enum` (not a flag) to match the tool family and
    /// stay exhaustive if a future variant (e.g. a boundary-pick first) is added.
    private enum State: Equatable {
        /// Waiting for the click that picks the entity / end to extend.
        case picking
    }

    /// The current state — only `picking` for this single-click tool.
    private var state: State = .picking

    /// The pick aperture in world units used to find the target under the click.
    /// The app would normally derive this from screen px × worldPerPixel; the
    /// tool keeps a sensible default so it works against a hand-built context.
    private let pickTolerance: Double

    /// Creates an Extend tool. `pickTolerance` is the world-space aperture used to
    /// find the target entity under the click (default `1e-6` so callers that
    /// click exactly on the entity always hit; the app passes its px-derived tol).
    public init(pickTolerance: Double = 1e-6) {
        self.pickTolerance = pickTolerance
    }

    // MARK: - Tool

    public var title: String { "Extend" }

    public var status: String { "Click near the end of a line or arc to extend it to a boundary" }

    /// Extend acts on the single click — there is no rubber-band between clicks.
    public var preview: [ResolvedPolyline] { [] }

    /// An EDITING tool: it reads the `context` boundary hooks (`nearbyEntities` to
    /// find the target near the pick, `allEntities` for the boundaries) and emits
    /// a single `.replace(targetID, extendedKind)` — never `.add`/`.remove`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value:
            // A typed coordinate doesn't apply to this entity-pick EDITING tool — ignore.
            return .none

        case .move:
            // No preview for the single-click extend.
            return .none

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            // Single-click action — nothing to step back.
            return .none

        case .cancel:
            // Esc — nothing pending; end the run.
            return .finished

        case .commit:
            // Return — extend commits on the click, so nothing is pending here.
            return .finished
        }
    }

    // MARK: - Click handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }

        // 1. Find the nearest LINE or ARC under the pick.
        guard let target = nearestTarget(to: p, context: context) else { return .none }

        // 2. Boundaries = every other entity in the drawing.
        let boundaries = context.allEntities().filter { $0.id != target.id }

        // 3. Compute the extended geometry to the nearest beyond-the-end boundary.
        guard let extended = Self.extend(target.kind, near: p, boundaries: boundaries) else {
            return .none   // nothing lies beyond the chosen end
        }

        return .commit([.replace(target.id, extended)])
    }

    /// The nearest LINE or ARC in the pick aperture, by EXACT distance to `p`.
    /// Other kinds are ignored (scope is line/arc). Returns `nil` for an empty
    /// area or when only unsupported kinds are under the pick.
    private func nearestTarget(to p: Vector, context: ToolContext) -> EntityRecord? {
        context.nearbyEntities(p, pickTolerance)
            .filter { Self.isSupportedTarget($0.kind) }
            .min { HitTesting.worldDistance(from: p, to: $0) < HitTesting.worldDistance(from: p, to: $1) }
    }

    /// Whether `kind` is a target Extend can act on (line / arc only for now).
    private static func isSupportedTarget(_ kind: EntityKind) -> Bool {
        switch kind {
        case .line, .arc: return true
        // TODO(backlog): extend polylines (grow the end segment), ellipse arcs,
        // and open splines to a boundary. Out of scope for this pass.
        case .circle, .polyline, .ellipse, .spline, .splinePoints, .point,
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .multileader, .image, .wipeout, .mline:
            return false
        }
    }

    // MARK: - Extend geometry (pure, self-contained)

    /// Computes the extended geometry of `target` so its end nearer to `near`
    /// reaches the NEAREST boundary lying beyond that end, or `nil` if `target`
    /// is unsupported or no boundary lies beyond the chosen end.
    static func extend(_ target: EntityKind, near: Vector,
                       boundaries: [EntityRecord]) -> EntityKind? {
        switch target {
        case .line(let d):
            return extendLine(d, near: near, boundaries: boundaries).map(EntityKind.line)
        case .arc(let d):
            return extendArc(d, near: near, boundaries: boundaries).map(EntityKind.arc)
        case .circle, .polyline, .ellipse, .spline, .splinePoints, .point,
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .multileader, .image, .wipeout, .mline:
            return nil
        }
    }

    // MARK: - Line extension

    /// Extends a line by moving the endpoint nearer to `near` out to the nearest
    /// intersection of the line's INFINITE extension with a boundary, kept only if
    /// the hit lies beyond that end (in the outward direction) and on the boundary.
    private static func extendLine(_ d: LineData, near: Vector,
                                   boundaries: [EntityRecord]) -> LineData? {
        let dir = d.end - d.start
        guard dir.magnitude > Tolerance.distance else { return nil }   // degenerate

        // Which end is nearer the pick? The OTHER end is the fixed anchor.
        let extendEnd = near.distance(to: d.end) <= near.distance(to: d.start) ? d.end : d.start
        let anchor = (extendEnd == d.end) ? d.start : d.end

        // Outward direction = from the anchor toward the end being extended.
        let outward = extendEnd - anchor
        guard outward.magnitude > Tolerance.distance else { return nil }

        // All intersections of the INFINITE line through (start,end) with every
        // boundary, kept on the boundary's true extent.
        let hits = infiniteLineHits(p0: d.start, p1: d.end, boundaries: boundaries)

        // Keep hits strictly BEYOND the chosen end, in the outward direction, and
        // pick the nearest such hit to the current end.
        guard let target = nearestBeyond(hits, end: extendEnd, outward: outward) else {
            return nil
        }

        // Move only the chosen endpoint out to the boundary; keep the anchor.
        return (extendEnd == d.end)
            ? LineData(start: d.start, end: target)
            : LineData(start: target, end: d.end)
    }

    /// Every intersection of the infinite line through `(p0,p1)` with each
    /// boundary, filtered to lie ON the boundary's true extent (segment for lines,
    /// arc range for arcs, the whole circle for circles).
    private static func infiniteLineHits(p0: Vector, p1: Vector,
                                         boundaries: [EntityRecord]) -> [Vector] {
        var out: [Vector] = []
        let line = (p0, p1)
        for b in boundaries {
            switch b.kind {
            case .line(let bd):
                // Infinite target line ∩ infinite boundary line, then keep only
                // hits ON the finite boundary segment.
                let sols = Intersections.lineLine(p0, p1, bd.start, bd.end, segment: false)
                for v in sols where v.valid && onSegment(v, bd.start, bd.end) {
                    out.append(v)
                }
            case .circle(let bd):
                let sols = Intersections.lineCircle(line: line, center: bd.center,
                                                    radius: bd.radius, segment: false)
                out.append(contentsOf: sols.filter(\.valid))
            case .arc(let bd):
                let sols = Intersections.lineArc(line: line, center: bd.center, radius: bd.radius,
                                                 angle1: bd.startAngle, angle2: bd.endAngle,
                                                 reversed: bd.reversed,
                                                 fullCircle: false, segment: false)
                out.append(contentsOf: sols.filter(\.valid))
            // TODO(backlog): ellipse / spline boundaries.
            case .ellipse, .spline, .splinePoints, .polyline, .point,
                 .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
                 .multileader, .image, .wipeout, .mline:
                continue
            }
        }
        return out
    }

    // MARK: - Arc extension

    /// Extends an arc by growing the start or end angle (whichever end is nearer
    /// `near`) out to the angle of the nearest intersection of the arc's FULL
    /// circle with a boundary that lies beyond that end in the sweep direction.
    private static func extendArc(_ d: ArcData, near: Vector,
                                  boundaries: [EntityRecord]) -> ArcData? {
        guard d.radius > Tolerance.distance else { return nil }

        let startP = d.center + Vector.polar(radius: d.radius, angle: d.startAngle)
        let endP = d.center + Vector.polar(radius: d.radius, angle: d.endAngle)
        let extendStart = near.distance(to: startP) < near.distance(to: endP)

        // All intersections of the arc's FULL circle with every boundary, kept on
        // the boundary's extent.
        let hits = fullCircleHits(center: d.center, radius: d.radius, boundaries: boundaries)

        // The angle from which we grow, and the sweep direction we grow in.
        //   - extend END:   advance(φ) = sweep from endAngle to φ (sweep dir).
        //   - extend START: advance(φ) = sweep from φ to startAngle (sweep dir),
        //                   i.e. we grow backwards before the start.
        var bestAngle: Double?
        var bestAdvance = Double.greatestFiniteMagnitude
        for h in hits where h.valid {
            let phi = (h - d.center).angle
            let advance = extendStart
                ? MathUtils.getAngleDifference(phi, d.startAngle, reversed: d.reversed)
                : MathUtils.getAngleDifference(d.endAngle, phi, reversed: d.reversed)
            // Strictly beyond the end (advance > 0) and the nearest such hit.
            guard advance > Tolerance.angle, advance < bestAdvance else { continue }
            bestAdvance = advance
            bestAngle = phi
        }

        guard let phi = bestAngle else { return nil }

        return extendStart
            ? ArcData(center: d.center, radius: d.radius,
                      startAngle: phi, endAngle: d.endAngle, reversed: d.reversed)
            : ArcData(center: d.center, radius: d.radius,
                      startAngle: d.startAngle, endAngle: phi, reversed: d.reversed)
    }

    /// Every intersection of the FULL circle `(center, radius)` with each
    /// boundary, filtered to lie ON the boundary's true extent.
    private static func fullCircleHits(center: Vector, radius: Double,
                                       boundaries: [EntityRecord]) -> [Vector] {
        var out: [Vector] = []
        for b in boundaries {
            switch b.kind {
            case .line(let bd):
                // Boundary SEGMENT ∩ the target's full circle.
                let sols = Intersections.lineCircle(line: (bd.start, bd.end),
                                                    center: center, radius: radius,
                                                    segment: true)
                out.append(contentsOf: sols.filter(\.valid))
            case .circle(let bd):
                let sols = Intersections.circleCircle(center1: center, radius1: radius,
                                                      center2: bd.center, radius2: bd.radius)
                out.append(contentsOf: sols.filter(\.valid))
            case .arc(let bd):
                let sols = Intersections.circleArc(circleCenter: center, circleRadius: radius,
                                                   arcCenter: bd.center, arcRadius: bd.radius,
                                                   arcAngle1: bd.startAngle, arcAngle2: bd.endAngle,
                                                   arcReversed: bd.reversed)
                out.append(contentsOf: sols.filter(\.valid))
            // TODO(backlog): ellipse / spline boundaries.
            case .ellipse, .spline, .splinePoints, .polyline, .point,
                 .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
                 .multileader, .image, .wipeout, .mline:
                continue
            }
        }
        return out
    }

    // MARK: - Geometry helpers

    /// The nearest hit to `end` that lies strictly BEYOND `end` in the `outward`
    /// direction (i.e. on the extension side, not back toward the anchor), or
    /// `nil` if none.
    private static func nearestBeyond(_ hits: [Vector], end: Vector, outward: Vector) -> Vector? {
        let outLen = outward.magnitude
        guard outLen > Tolerance.distance else { return nil }
        let unit = outward / outLen

        var best: Vector?
        var bestDist = Double.greatestFiniteMagnitude
        for h in hits where h.valid {
            // Signed distance from the end along the outward direction. Positive =
            // beyond the end (the extension side); ≤ tol = on/behind the end.
            let signed = (h - end).dot(unit)
            guard signed > Tolerance.distance else { continue }
            if signed < bestDist {
                bestDist = signed
                best = h
            }
        }
        return best
    }

    /// Whether `p` lies on the finite segment `(s, e)` (within tolerance of the
    /// segment, with the parameter `t ∈ [0, 1]`). Used to keep only boundary-line
    /// hits that fall on the real boundary, not on its infinite extension.
    private static func onSegment(_ p: Vector, _ s: Vector, _ e: Vector) -> Bool {
        let d = e - s
        let len2 = d.squared
        if len2 < Tolerance.distanceSquared {
            return (p - s).squared <= Tolerance.distanceSquared
        }
        let t = (p - s).dot(d) / len2
        let eps = 1e-9
        return t >= -eps && t <= 1 + eps
    }
}
