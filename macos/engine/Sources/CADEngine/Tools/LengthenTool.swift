//
//  LengthenTool.swift
//  CADEngine
//
//  The LENGTHEN modify tool — pick a LINE or ARC near the end you want to grow or
//  shrink, then lengthen/shorten it by a delta, to a total length, or to a clicked
//  point. Ported in spirit from LibreCAD's `RS_ActionModifyLength`
//  (librecad/src/actions/drawing/modify/rs_actionmodifylength.cpp): the chosen end
//  is moved along the entity's own direction (the line's axis / the arc's circle)
//  by the requested amount; the OTHER end stays fixed.
//
//  Behavior (pick the entity near an end → specify how much):
//    - `.click(p)` while picking → TARGET the nearest LINE/ARC under the pick and
//                        remember WHICH end is nearer `p` (the end that will move).
//                        The tool advances to the "specify amount" phase. (Other
//                        kinds are skipped — scope is line/arc.)
//    - `.value(v)`     → a TYPED amount (U1). `CommandParser` resolves a bare
//                        distance the user typed into a world point along the
//                        relative-zero ray, so for this tool the typed value is
//                        interpreted as a SIGNED DELTA *length*: `v.x` is the change
//                        in length applied to the chosen end (positive = grow,
//                        negative = shrink). (The app feeds a bare typed distance as
//                        `Vector(dist, 0)`, so `v.x` is exactly the number typed.)
//                        Once a target is picked the tool computes the lengthened
//                        geometry and commits one `.replace`.
//    - `.click(p)` after a target is picked → the chosen end is moved so the
//                        entity's length becomes `|p − fixedEnd|` measured along the
//                        entity (line: project; arc: the angle of `p` on the
//                        circle): a click form of "lengthen to a point".
//    - `.move`         → rubber-band preview of the lengthened geometry tracking the
//                        cursor once a target is picked.
//    - `.cancel` (Esc) → discard and finish.
//    - `.commit` / `.backspace` → step back / finish (no pending geometry beyond a
//                        single replace).
//
//  LENGTHEN semantics:
//    - LINE: the chosen end slides along the line's direction; the fixed (other)
//      end is the anchor. A delta `Δ` makes the new length `oldLen + Δ` (clamped so
//      the line never inverts to ≤ 0). To a point: project the point onto the line's
//      axis and move the chosen end there.
//    - ARC: the chosen end's angle advances along the arc's sweep direction so the
//      arc length changes by `Δ` (`Δangle = Δ / radius`); the fixed end's angle is
//      unchanged. To a point: move the chosen-end angle to the angle of the clicked
//      point on the arc's circle. Clamped so the sweep never collapses to ≤ 0 or
//      exceeds a full turn.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` (`nearbyEntities` to find the target)
//  plus the snapped/typed points in `ToolInput`. The app applies the single
//  `.replace` (preserving the entity's id / layer / pen / flags) as one undoable
//  group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyLength).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Lengthen tool. Click a line or arc near the end to change,
/// then type a signed delta (or click a point) to grow / shrink it along its own
/// direction, keeping the other end fixed (LibreCAD's modify-length action).
public struct LengthenTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyLength`'s status integers
    /// (ChooseEntity → SetLength) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the click that picks the entity / end to change.
        case pickingEntity
        /// A target is fixed; waiting for the amount (typed delta, or a point).
        /// `targetID` is the entity to replace; `moveEnd` flags whether the END (vs
        /// the START) is the one that slides.
        case specifyingAmount(targetID: EntityID, kind: EntityKind, moveEnd: Bool)
    }

    /// The current state. Starts waiting for the entity pick.
    private var state: State = .pickingEntity

    /// The last cursor point seen via `.move`, used to drive the preview once a
    /// target is picked. Invalid until the first move after the pick.
    private var cursor: Vector = .invalid

    /// The pick aperture in world units used to find the target under the click.
    private let pickTolerance: Double

    /// Creates a Lengthen tool. `pickTolerance` is the world-space aperture used to
    /// find the target entity under the click (default `1e-6` so callers that click
    /// exactly on the entity always hit; the app passes its px-derived tolerance).
    public init(pickTolerance: Double = 1e-6) {
        self.pickTolerance = pickTolerance
    }

    // MARK: - Tool

    public var title: String { "Lengthen" }

    public var status: String {
        switch state {
        case .pickingEntity:
            return "Click a line or arc near the end to lengthen"
        case .specifyingAmount:
            return "Type a signed length delta, or click a point to lengthen to"
        }
    }

    /// The live preview: the lengthened geometry for the current cursor once a
    /// target is picked (lengthen-to-point form), with the preview pen. Empty
    /// before a target is picked or before the cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .specifyingAmount(_, let kind, let moveEnd) = state, cursor.valid else {
            return []
        }
        guard let new = Self.lengthenToPoint(kind, moveEnd: moveEnd, point: cursor) else { return [] }
        return new.resolve(pen: .toolPreview, ctx: .default).polylines
    }

    /// A MODIFY tool: it reads `context.nearbyEntities` to find the target and
    /// emits a single `.replace(targetID, lengthenedKind)` — never `.add`/`.remove`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value(let v):
            return handleTypedDelta(v)

        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            reset()
            return .finished

        case .commit:
            reset()
            return .finished
        }
    }

    // MARK: - Click / typed-input / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .pickingEntity:
            guard let target = nearestTarget(to: p, context: context) else { return .none }
            let moveEnd = Self.endNearerIsEnd(target.kind, point: p)
            state = .specifyingAmount(targetID: target.id, kind: target.kind, moveEnd: moveEnd)
            cursor = p
            return .none

        case .specifyingAmount(let id, let kind, let moveEnd):
            // Click form: lengthen the chosen end TO the clicked point.
            guard let new = Self.lengthenToPoint(kind, moveEnd: moveEnd, point: p) else { return .none }
            reset()
            return .commit([.replace(id, new)])
        }
    }

    /// A typed amount (U1 `.value`): the SIGNED length delta for the chosen end.
    /// The app feeds a bare typed distance as `Vector(dist, 0)`, so `v.x` is the
    /// number typed (positive = grow, negative = shrink).
    private mutating func handleTypedDelta(_ v: Vector) -> ToolOutcome {
        guard v.valid, case .specifyingAmount(let id, let kind, let moveEnd) = state else {
            return .none
        }
        let delta = v.x
        guard abs(delta) > Tolerance.distance else { return .none }
        guard let new = Self.lengthenByDelta(kind, moveEnd: moveEnd, delta: delta) else { return .none }
        reset()
        return .commit([.replace(id, new)])
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingEntity:
            return .none
        case .specifyingAmount:
            // Step back to re-pick the entity / end.
            state = .pickingEntity
            cursor = .invalid
            return .none
        }
    }

    /// Returns to the initial waiting state, dropping any target / cursor.
    private mutating func reset() {
        state = .pickingEntity
        cursor = .invalid
    }

    // MARK: - Target picking

    /// The nearest LINE or ARC in the pick aperture, by EXACT distance to `p`.
    /// Other kinds are ignored (scope is line/arc).
    private func nearestTarget(to p: Vector, context: ToolContext) -> EntityRecord? {
        context.nearbyEntities(p, pickTolerance)
            .filter { Self.isSupported($0.kind) }
            .min { HitTesting.worldDistance(from: p, to: $0) < HitTesting.worldDistance(from: p, to: $1) }
    }

    /// Whether `kind` is a target Lengthen can act on (line / arc only).
    static func isSupported(_ kind: EntityKind) -> Bool {
        switch kind {
        case .line, .arc: return true
        // TODO(backlog): lengthen open polylines (the end segment) / open splines.
        case .circle, .polyline, .ellipse, .spline, .splinePoints, .point,
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .multileader, .image, .wipeout:
            return false
        }
    }

    // MARK: - Which end moves

    /// Whether the END of `kind` is the one nearer `point` (so the end moves and
    /// the start is the fixed anchor). For an arc the "end" is the `endAngle`
    /// endpoint. Defaults to moving the end when the kind has no endpoints.
    static func endNearerIsEnd(_ kind: EntityKind, point p: Vector) -> Bool {
        switch kind {
        case .line(let d):
            return p.distance(to: d.end) <= p.distance(to: d.start)
        case .arc(let d):
            let s = d.center + Vector.polar(radius: d.radius, angle: d.startAngle)
            let e = d.center + Vector.polar(radius: d.radius, angle: d.endAngle)
            return p.distance(to: e) <= p.distance(to: s)
        default:
            return true
        }
    }

    // MARK: - Lengthen by a signed delta

    /// Lengthens `kind` so the chosen end (END if `moveEnd`, else START) changes the
    /// entity's length by the SIGNED `delta` along its own direction; the other end
    /// is fixed. Returns `nil` for an unsupported kind or a degenerate result
    /// (length / sweep would collapse to ≤ 0).
    static func lengthenByDelta(_ kind: EntityKind, moveEnd: Bool, delta: Double) -> EntityKind? {
        switch kind {
        case .line(let d):
            return lengthenLineByDelta(d, moveEnd: moveEnd, delta: delta).map(EntityKind.line)
        case .arc(let d):
            return lengthenArcByDelta(d, moveEnd: moveEnd, delta: delta).map(EntityKind.arc)
        default:
            return nil
        }
    }

    /// Slides a line's chosen endpoint along the line's direction so the new length
    /// is `oldLen + delta` (clamped > 0). The fixed end is the anchor; the moving
    /// end keeps the direction from anchor → moving end.
    static func lengthenLineByDelta(_ d: LineData, moveEnd: Bool, delta: Double) -> LineData? {
        let anchor = moveEnd ? d.start : d.end
        let moving = moveEnd ? d.end : d.start
        let dir = moving - anchor
        let len = dir.magnitude
        guard len > Tolerance.distance else { return nil }
        let unit = dir / len
        let newLen = len + delta
        guard newLen > Tolerance.distance else { return nil }   // would invert / vanish
        let newMoving = anchor + unit * newLen
        return moveEnd ? LineData(start: anchor, end: newMoving)
                       : LineData(start: newMoving, end: anchor)
    }

    /// Advances an arc's chosen-end angle along the sweep so the ARC LENGTH changes
    /// by `delta` (`Δangle = delta / radius`); the other end's angle is fixed.
    /// Clamped so the resulting sweep stays in `(0, 2π)`.
    static func lengthenArcByDelta(_ d: ArcData, moveEnd: Bool, delta: Double) -> ArcData? {
        guard d.radius > Tolerance.distance else { return nil }
        let sweep = MathUtils.getAngleDifference(d.startAngle, d.endAngle, reversed: d.reversed)
        let dAngle = delta / d.radius
        let newSweep = sweep + dAngle
        // Keep a real, non-degenerate, sub-full-turn arc.
        guard newSweep > Tolerance.angle, newSweep < 2 * Double.pi - Tolerance.angle else { return nil }

        // Grow/shrink at the chosen end in the sweep direction. For a CCW arc the
        // END advances by +dAngle and the START retreats by −dAngle (and vice-versa
        // under `reversed`); we express both as moving along the sweep direction.
        let sign = d.reversed ? -1.0 : 1.0
        if moveEnd {
            let newEnd = Vector.correctAngle(d.endAngle + sign * dAngle)
            return ArcData(center: d.center, radius: d.radius,
                           startAngle: d.startAngle, endAngle: newEnd, reversed: d.reversed)
        } else {
            let newStart = Vector.correctAngle(d.startAngle - sign * dAngle)
            return ArcData(center: d.center, radius: d.radius,
                           startAngle: newStart, endAngle: d.endAngle, reversed: d.reversed)
        }
    }

    // MARK: - Lengthen to a point

    /// Lengthens `kind` so the chosen end is moved to (the projection of) `point`.
    /// LINE: project `point` onto the line's axis; ARC: move the chosen-end angle to
    /// the angle of `point` on the arc's circle. Returns `nil` for an unsupported
    /// kind or a degenerate result.
    static func lengthenToPoint(_ kind: EntityKind, moveEnd: Bool, point p: Vector) -> EntityKind? {
        guard p.valid else { return nil }
        switch kind {
        case .line(let d):
            return lengthenLineToPoint(d, moveEnd: moveEnd, point: p).map(EntityKind.line)
        case .arc(let d):
            return lengthenArcToPoint(d, moveEnd: moveEnd, point: p).map(EntityKind.arc)
        default:
            return nil
        }
    }

    /// Moves the chosen endpoint to the projection of `point` onto the line's
    /// infinite axis (so the end stays collinear), keeping the other end fixed.
    static func lengthenLineToPoint(_ d: LineData, moveEnd: Bool, point p: Vector) -> LineData? {
        let anchor = moveEnd ? d.start : d.end
        let moving = moveEnd ? d.end : d.start
        let dir = moving - anchor
        let len2 = dir.squared
        guard len2 > Tolerance.distanceSquared else { return nil }
        let u = (p - anchor).dot(dir) / len2          // param along anchor→moving
        let projected = anchor + dir * u
        guard (projected - anchor).squared > Tolerance.distanceSquared else { return nil }
        return moveEnd ? LineData(start: anchor, end: projected)
                       : LineData(start: projected, end: anchor)
    }

    /// Moves the chosen-end angle to the angle of `point` on the arc's circle, the
    /// other end's angle fixed. Rejected if the resulting sweep is degenerate.
    static func lengthenArcToPoint(_ d: ArcData, moveEnd: Bool, point p: Vector) -> ArcData? {
        guard d.radius > Tolerance.distance else { return nil }
        let newAngle = (p - d.center).angle
        let candidate = moveEnd
            ? ArcData(center: d.center, radius: d.radius,
                      startAngle: d.startAngle, endAngle: newAngle, reversed: d.reversed)
            : ArcData(center: d.center, radius: d.radius,
                      startAngle: newAngle, endAngle: d.endAngle, reversed: d.reversed)
        let sweep = MathUtils.getAngleDifference(candidate.startAngle, candidate.endAngle,
                                                 reversed: candidate.reversed)
        guard sweep > Tolerance.angle, sweep < 2 * Double.pi - Tolerance.angle else { return nil }
        return candidate
    }
}
