//
//  FilletTool.swift
//  CADEngine
//
//  The FILLET editing tool — pick two lines, round the corner where they meet
//  with a tangent arc of radius `r`. Ported in spirit from LibreCAD's
//  `RS_ActionModifyRound` / `RS_Creation::createRoundEntity`
//  (librecad/src/lib/creation/rs_creation.cpp +
//  librecad/src/actions/drawing/modify/rs_actionmodifyround.cpp), distilled to
//  the two-click line→line interaction this app uses.
//
//  Behavior (two clicks — pick the two lines to round between):
//    - click #1 → FIRST line: the nearest LINE in `context.nearbyEntities(p, tol)`.
//                 status: "Specify second line".
//    - click #2 → SECOND line: the nearest LINE (≠ first) under the click. Compute
//                 the fillet and emit it as ONE undoable commit (see below), then
//                 RESET to picking the first line.
//    - `.move` (in pickingSecond) → rubber-band preview of the resulting arc +
//                 trimmed lines (the `.toolPreview` pen), tracking the cursor as the
//                 candidate second line.
//    - `.cancel` (Esc) / `.backspace` → discard the run, reset to picking first.
//    - `.commit` (Ret) → nothing pending (fillet commits on the second click); end.
//
//  THE FILLET GEOMETRY (line–line):
//    1. CORNER = the two lines' INFINITE intersection
//       (`Intersections.lineLine(..., segment: false)`). Parallel ⇒ no corner ⇒
//       no-op.
//    2. The pick points pick the RAYS being rounded: `dirA`/`dirB` are the unit
//       directions from the corner TOWARD each pick. The fillet arc of radius `r`
//       tangent to both rays sits in that wedge — its CENTER is on the angle
//       bisector at distance `r / sin(θ/2)` from the corner (θ = the angle between
//       the two rays), and the TANGENT POINTS are the feet of the perpendiculars
//       from the center onto each line.
//    3. Emit `.commit([ .replace(firstID, trimmedFirstLine),
//                       .replace(secondID, trimmedSecondLine),
//                       .add(filletArc) ])` — each line is trimmed so its endpoint
//       NEAREST the corner moves to its tangent point, and the arc rounds the
//       corner (the SHORT way across the wedge, never the reflex side). `r == 0`
//       ⇒ just trim both lines to the corner (NO arc, two `.replace`s).
//    4. Degenerate (parallel, `r` too large to fit on a finite line, coincident
//       lines, tangent points off the picked rays) ⇒ no-op.
//
//  SCOPE: LINE–LINE only. A non-line target under either click is a no-op.
//  (`// TODO(backlog)`: arc/circle fillet — `RS_Creation::createRoundEntity`
//  covers line/arc/circle pairs.)
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` boundary hooks (`nearbyEntities`)
//  plus the snapped world points in `ToolInput`, and computes the fillet entirely
//  through the shared `Intersections.lineLine` kernel + vector math. The app
//  applies the two `.replace`s (preserving each line's id / layer / pen / flags)
//  and the one `.add` (re-minting the arc's id, layer/pen from the first line) as
//  ONE undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyRound).
//  Copyright (C) Dongxu Li (RS_Creation::createRoundEntity fillet math).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Fillet tool. Pick two lines; the corner where they meet is
/// rounded with a tangent arc of radius ``radius`` (LibreCAD's modify-round, the
/// line–line case).
public struct FilletTool: Tool {

    // MARK: - Public configuration

    /// The fillet radius in world units. Clamped to `>= 0` on use; `0` produces a
    /// sharp corner (both lines trimmed to the intersection, no arc).
    /// Default 10 (LibreCAD's default round radius).
    // TODO(backlog): radius input UI (a HUD field / coordinate entry to set this
    // interactively; for now the app sets it programmatically before the picks).
    public var radius: Double = 10.0

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyRound`'s status integers
    /// to an exhaustive `enum`. Each case carries the picks made so far.
    private enum State: Equatable {
        /// Waiting for the FIRST line pick (no entity chosen yet).
        case pickingFirst
        /// First line fixed; waiting for the SECOND line. `first` is the chosen
        /// first line record (kept so the second pick can exclude it and the
        /// fillet can reference its id / layer / pen); `firstPick` is the click
        /// point on the first line (it selects which ray of the first line is
        /// rounded, matching LibreCAD rounding the clicked segments).
        case pickingSecond(first: EntityRecord, firstPick: Vector)
    }

    /// The current state. Starts waiting for the first line.
    private var state: State = .pickingFirst

    /// The last cursor point seen via `.move`, used to drive the preview of the
    /// fillet that WOULD result for the line under the cursor. Invalid until the
    /// first move after the first line is fixed.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Fillet" }

    public var status: String {
        switch state {
        case .pickingFirst:  return "Specify first line"
        case .pickingSecond: return "Specify second line"
        }
    }

    /// The live preview: once a first line is fixed and the cursor is over a
    /// candidate second line, show the resulting fillet arc + the two trimmed
    /// lines with the preview pen. Empty when no valid fillet would result.
    public var preview: [ResolvedPolyline] {
        guard case .pickingSecond = state, cursor.valid,
              let result = previewResult else {
            return []
        }
        let ctx = ResolveContext.default
        var out: [ResolvedPolyline] = []
        // The two trimmed lines.
        for kind in [EntityKind.line(result.firstLine), .line(result.secondLine)] {
            out.append(contentsOf: kind.resolve(pen: .toolPreview, ctx: ctx).polylines)
        }
        // The fillet arc (omitted for the r == 0 sharp-corner case).
        if let arc = result.arc {
            out.append(contentsOf: EntityKind.arc(arc).resolve(pen: .toolPreview, ctx: ctx).polylines)
        }
        return out
    }

    /// The fillet computed for the current cursor on the last `.move` (cached
    /// because `preview` has no `ToolContext`). Nil when nothing would fillet.
    private var previewResult: Fillet?

    /// A FILLET editing tool: it reads the boundary hook (`nearbyEntities`) on
    /// each click, and on the SECOND pick emits two `.replace`s (the trimmed
    /// lines) + one `.add` (the arc) as a single undoable commit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // Recompute the would-fillet preview from the live context so the
            // overlay tracks the candidate second line under the cursor.
            previewResult = computeFor(secondPick: p, context: context)
            return previewResult == nil ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — Fillet completes on its second click, so nothing is
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingFirst:
            // First click selects the nearest LINE under the pick. A non-line (or
            // empty) pick is ignored — keep waiting for a first line.
            guard let first = Self.nearestLine(at: p, exclude: nil, context: context) else {
                return .none
            }
            state = .pickingSecond(first: first, firstPick: p)
            cursor = p
            previewResult = nil
            return .none

        case .pickingSecond:
            // Second click selects a different line and computes the fillet.
            guard let result = computeFor(secondPick: p, context: context) else {
                return .none
            }
            let edits = Self.edits(for: result)
            reset()
            return edits.isEmpty ? .none : .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingFirst:
            // Nothing to step back.
            return .none
        case .pickingSecond:
            // Undo the first-line pick → back to the initial state.
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-line state and drops the cached
    /// preview.
    private mutating func reset() {
        state = .pickingFirst
        cursor = .invalid
        previewResult = nil
    }

    /// Computes the fillet for a candidate SECOND pick `p` given the current first
    /// line (the `.pickingSecond` state). Nil when there is no valid second line
    /// or no fitting fillet. The first ray is selected by the FIRST pick point
    /// (stored in the state when the first line was chosen) and the second ray by
    /// `p` — so the rounded wedge is the one the user clicked into, matching
    /// LibreCAD rounding the picked segments.
    private func computeFor(secondPick p: Vector, context: ToolContext) -> Fillet? {
        guard case .pickingSecond(let first, let firstPick) = state else { return nil }
        guard let second = Self.nearestLine(at: p, exclude: first.id, context: context) else {
            return nil
        }
        guard case .line(let a) = first.kind, case .line(let b) = second.kind else { return nil }
        return Self.fillet(firstID: first.id, firstLayer: first.layer, firstPen: first.pen,
                           firstFlags: first.flags, lineA: a, firstPick: firstPick,
                           secondID: second.id, lineB: b, secondPick: p,
                           radius: Swift.max(0, radius))
    }

    // MARK: - Line picking

    /// The nearest LINE within the pick aperture of `p`, optionally excluding one
    /// id (so the second pick can't re-pick the first). Non-line kinds are skipped
    /// (scope: line–line). Mirrors `TrimTool.nearestTarget`'s exact-distance pick.
    static func nearestLine(at p: Vector, exclude: EntityID?, context: ToolContext) -> EntityRecord? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) where e.id != exclude {
            switch e.kind {
            case .line:
                let d = HitTesting.worldDistance(from: p, to: e)
                if d < bestDist {
                    bestDist = d
                    best = e
                }
            default:
                // TODO(backlog): arc / circle fillet targets.
                continue
            }
        }
        return best
    }

    /// The picked tolerance aperture in world units, mirroring `TrimTool`: a
    /// fraction of the grid spacing when present, else a small fixed default.
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance {
            return g * 0.5
        }
        return 0.5
    }

    // MARK: - Fillet computation (pure, self-contained)

    /// The result of a fillet: the two trimmed lines (to `.replace`), and the arc
    /// to `.add` (nil for the `r == 0` sharp-corner case). The arc carries the
    /// first line's layer/pen so the rounded corner inherits its style.
    struct Fillet: Equatable {
        let firstID: EntityID
        let firstLayer: LayerID
        let firstPen: Pen
        let firstFlags: EntityFlags
        let firstLine: LineData
        let secondID: EntityID
        let secondLine: LineData
        /// The fillet arc, or nil when `radius == 0` (sharp corner, no arc).
        let arc: ArcData?
    }

    /// Computes the line–line fillet. `lineA` is the FIRST picked line (its
    /// id/layer/pen go on the arc); `lineB` is the SECOND. `firstPick`/`secondPick`
    /// are the clicks on each line; they select which RAY of each line (which side
    /// of the corner) is rounded.
    ///
    /// Returns nil for any degenerate case: parallel/coincident lines (no finite
    /// corner), a radius too large to land its tangent points on BOTH finite
    /// lines, or a zero-length ray.
    static func fillet(firstID: EntityID, firstLayer: LayerID, firstPen: Pen,
                       firstFlags: EntityFlags, lineA: LineData, firstPick: Vector,
                       secondID: EntityID, lineB: LineData, secondPick: Vector,
                       radius r: Double) -> Fillet? {
        // 1. CORNER = the two lines' infinite intersection.
        let sols = Intersections.lineLine(lineA.start, lineA.end, lineB.start, lineB.end, segment: false)
        guard let corner = sols.first, corner.valid else { return nil }   // parallel ⇒ no corner

        // 2. The two RAYS being rounded — from the corner toward each PICK along
        //    the respective line (the picks may be slightly off the exact line, so
        //    each direction is projected onto its line and oriented toward the pick
        //    side).
        var dirA = directionAlongLine(lineA, from: corner, toward: firstPick)
        var dirB = directionAlongLine(lineB, from: corner, toward: secondPick)

        let lenA = dirA.magnitude
        let lenB = dirB.magnitude
        guard lenA > Tolerance.distance, lenB > Tolerance.distance else { return nil }
        dirA = dirA / lenA
        dirB = dirB / lenB

        // 3. r == 0 ⇒ sharp corner: trim both lines to the corner, no arc.
        if r <= Tolerance.distance {
            guard let ta = trimEndpointNearestCorner(lineA, corner: corner, to: corner),
                  let tb = trimEndpointNearestCorner(lineB, corner: corner, to: corner) else {
                return nil
            }
            return Fillet(firstID: firstID, firstLayer: firstLayer, firstPen: firstPen,
                          firstFlags: firstFlags, firstLine: ta,
                          secondID: secondID, secondLine: tb, arc: nil)
        }

        // 4. Center on the angle bisector at distance r / sin(θ/2) from the corner.
        //    θ is the angle between the rays; cos(θ/2) = dirA · bisector.
        let bisectorRaw = dirA + dirB
        guard bisectorRaw.magnitude > Tolerance.distance else {
            // The rays are anti-parallel (a straight line, 180° "corner"): no
            // finite-radius fillet fits. (Treated as degenerate.)
            return nil
        }
        let bisector = bisectorRaw / bisectorRaw.magnitude
        let cosHalf = dirA.dot(bisector)        // = cos(θ/2)
        let sinHalf = (1.0 - cosHalf * cosHalf).squareRoot()   // = sin(θ/2)
        guard sinHalf > Tolerance.distance else { return nil }  // rays anti-parallel

        let distToCenter = r / sinHalf
        let center = corner + bisector * distToCenter

        // 5. Tangent points = feet of the perpendiculars from the center onto each
        //    infinite line. They must land on the rays we are rounding (between the
        //    corner and the kept far endpoint) — else the radius doesn't fit.
        let tangentA = Intersections.nearestOnInfiniteLine(center, lineA.start, lineA.end)
        let tangentB = Intersections.nearestOnInfiniteLine(center, lineB.start, lineB.end)
        guard tangentA.valid, tangentB.valid else { return nil }
        guard tangentOnRay(tangentA, corner: corner, dir: dirA, line: lineA),
              tangentOnRay(tangentB, corner: corner, dir: dirB, line: lineB) else {
            return nil   // radius too large to land on a finite line
        }

        // 6. Trim each line: move its endpoint NEAREST the corner to its tangent.
        guard let trimmedA = trimEndpointNearestCorner(lineA, corner: corner, to: tangentA),
              let trimmedB = trimEndpointNearestCorner(lineB, corner: corner, to: tangentB) else {
            return nil
        }

        // 7. The fillet arc: tangent points → start/end angles about the center,
        //    swept the SHORT way across the wedge (the side toward the corner).
        let arc = filletArc(center: center, radius: r,
                            tangentA: tangentA, tangentB: tangentB, corner: corner)

        return Fillet(firstID: firstID, firstLayer: firstLayer, firstPen: firstPen,
                      firstFlags: firstFlags, firstLine: trimmedA,
                      secondID: secondID, secondLine: trimmedB, arc: arc)
    }

    /// The direction vector from `corner` along `line` toward the side of `toward`.
    /// Uses the line's own direction (so the ray is exactly on the line) but
    /// oriented to point the same way as `toward − corner`.
    private static func directionAlongLine(_ line: LineData, from corner: Vector, toward: Vector) -> Vector {
        let lineDir = line.end - line.start
        let len = lineDir.magnitude
        guard len > Tolerance.distance else { return toward - corner }
        let unit = lineDir / len
        // Orient `unit` to point from the corner toward the pick side.
        let sign = (toward - corner).dot(unit) >= 0 ? 1.0 : -1.0
        return unit * sign
    }

    /// Whether the tangent point `t` lies on the rounded RAY: on the corner→ray
    /// side (positive projection along `dir`) AND within the finite line segment.
    /// A tangent off the finite line means the radius is too large to fit.
    private static func tangentOnRay(_ t: Vector, corner: Vector, dir: Vector,
                                     line: LineData) -> Bool {
        // Must be on the corner→ray side (positive projection along `dir`).
        let along = (t - corner).dot(dir)
        guard along >= -Tolerance.distance else { return false }
        // Must lie within the finite line segment.
        let seg = line.end - line.start
        let len2 = seg.squared
        if len2 > Tolerance.distanceSquared {
            let u = (t - line.start).dot(seg) / len2
            let eps = 1e-9
            guard u >= -eps && u <= 1 + eps else { return false }
        }
        return true
    }

    /// Returns `line` with whichever endpoint is NEAREST the corner moved to
    /// `target` (the tangent point, or the corner itself for r == 0). Returns nil
    /// if that would collapse the line to ~zero length.
    static func trimEndpointNearestCorner(_ line: LineData, corner: Vector, to target: Vector) -> LineData? {
        let startNearer = line.start.distance(to: corner) <= line.end.distance(to: corner)
        if startNearer {
            guard (target - line.end).squared > Tolerance.distanceSquared else { return nil }
            return LineData(start: target, end: line.end)
        } else {
            guard (line.start - target).squared > Tolerance.distanceSquared else { return nil }
            return LineData(start: line.start, end: target)
        }
    }

    /// Builds the fillet arc from its two tangent points about `center`, choosing
    /// the sweep direction (CCW vs CW) so the arc rounds the corner the SHORT way
    /// (its midpoint sits on the corner side of the center), never the reflex side.
    static func filletArc(center: Vector, radius: Double,
                          tangentA: Vector, tangentB: Vector, corner: Vector) -> ArcData {
        let a1 = (tangentA - center).angle
        let a2 = (tangentB - center).angle
        // The arc's near-corner midpoint direction: from the center toward the
        // corner (the fillet bulges toward the corner). Its angle must lie within
        // the chosen sweep.
        let midAngle = (corner - center).angle
        // Try CCW (reversed: false) from a1 to a2; if the corner-side midpoint is
        // swept, that's the rounding arc — else sweep CW.
        let ccwHasMid = MathUtils.isAngleBetween(midAngle, a1, a2, reversed: false)
        let reversed = !ccwHasMid
        return ArcData(center: center, radius: radius,
                       startAngle: a1, endAngle: a2, reversed: reversed)
    }

    // MARK: - Commit assembly

    /// The ordered edits for a computed fillet: two `.replace`s (the trimmed
    /// lines) and, when there is an arc, one `.add` (the arc, inheriting the first
    /// line's layer/pen/flags, placeholder id so the app re-mints).
    static func edits(for f: Fillet) -> [ToolEdit] {
        var edits: [ToolEdit] = [
            .replace(f.firstID, .line(f.firstLine)),
            .replace(f.secondID, .line(f.secondLine)),
        ]
        if let arc = f.arc {
            edits.append(.add(EntityRecord(
                id: .placeholder,
                layer: f.firstLayer,
                pen: f.firstPen,
                flags: f.firstFlags,
                kind: .arc(arc)
            )))
        }
        return edits
    }
}
