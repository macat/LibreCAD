//
//  SplineEditTool.swift
//  CADEngine
//
//  The SPLINE-EDIT modify tool — edit the DEFINING points of an existing spline
//  on the canvas: MOVE a point, ADD a point on/near the curve, or REMOVE a point.
//  This is the spline analogue of `PolylineEditTool` (which edits polyline
//  vertices); before it, splines were inspector-only. Ported in spirit from
//  LibreCAD's spline-modify family (`RS_ActionModifyEntity` / the spline control-
//  point handles in `RS_Spline` / `LC_SplinePoints`): you pick the spline, then
//  act on one of its defining points, and the result is the same spline with one
//  point moved / inserted / removed.
//
//  ## Which point set is editable (per spline kind)
//  This engine has TWO spline kinds (Entity.swift), and the USER-EDITABLE point
//  set differs:
//
//    • `.spline` (NURBS — `SplineData`): the defining points are the
//      `controlPoints` (the control polygon). MOVE replaces a control point while
//      KEEPING the `degree` and `weights`; ADD inserts a control point; REMOVE
//      drops one (guarding the NURBS minimum of `degree + 1` control points so the
//      curve stays evaluable). Because the stored `knots` are sized exactly
//      `controlPoints.count + degree + 1`, any change to the control-point COUNT
//      (add/remove) invalidates them, so we CLEAR `knots` on add/remove and let
//      `resolve()` regenerate a clamped (open) uniform knot vector
//      (`NURBS.knotVector`). A pure MOVE keeps the knots (count is unchanged).
//      The `weights` array (if non-empty / rational) is kept index-aligned: a
//      moved point keeps its weight, an added point gets weight 1, a removed point
//      drops its weight.
//
//    • `.splinePoints` (interpolation spline — `SplinePointsData`): the defining
//      points ARE the stored `controlPoints` — this engine stores the user's fit
//      points DIRECTLY as the quadratic-Bézier control polygon (the fit→control
//      banded solve `UpdateControlPoints` was never ported; see the ADR note on
//      `SplinePointsData` and `SplineTool`). So MOVE/ADD/REMOVE edit those points
//      directly, exactly like a polyline's vertices. The minimum kept is 2 points
//      (below that there is no curve to draw), matching `PolylineEditTool`.
//
//  Behavior (pick the spline → act on a point, per the active `mode`):
//    - With a spline/splinePoints in `context.selected` the tool ADOPTS it as the
//      target on activation (no separate pick); otherwise the FIRST `.click`
//      TARGETS the nearest spline under the pick (other kinds ignored).
//    - Once a target is set, each interaction depends on `mode`:
//        • .move   — `.click(p)` grabs the NEAREST defining point (a stray click
//                    still grabs the closest handle); the next `.click(p)` /
//                    `.value(p)` MOVES that point to p and commits one `.replace`.
//                    `.move` rubber-bands the spline with the grabbed point at the
//                    cursor.
//        • .add    — `.click(p)` inserts a NEW defining point at the projection of
//                    p onto the nearest leg of the DEFINING polygon, between that
//                    leg's two endpoints, and commits one `.replace` (point
//                    count +1). The recomputed curve passes near the inserted point.
//        • .remove — `.click(p)` on a defining point (within the pick aperture)
//                    drops it (keeping the per-kind minimum) and commits one
//                    `.replace` (point count −1). A remove that would breach the
//                    minimum is refused (no-op).
//    - `.commit` (Return) ends the run when nothing is pending; `.cancel` (Esc)
//      discards any pending grab and finishes. `closed` is always preserved.
//
//  A pick of a NON-spline entity (or no spline under the pick) is INERT (no
//  target is set, no commit). A zero-length move (destination == the grabbed
//  point) is dropped without a commit (no pointless undo step). A coincident
//  ADD/grab uses the nearest leg/point so it never produces a degenerate edit.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` (`selected` to adopt a target,
//  `nearbyEntities` to pick one) plus the snapped world points in `ToolInput`, and
//  rebuilds the spline's defining data entirely from value math. The app applies
//  the single `.replace(id, .spline(...))` / `.replace(id, .splinePoints(...))`
//  (preserving the entity's id / layer / pen / flags / space) as one undoable group.
//
//  UNWIRED: this tool conforms to `Tool` but is NOT yet registered in `ToolKind`
//  nor surfaced in the UI (that is a later wire-wave owned by the canvas/UI agent).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (RS_Spline); (C) 2014 Pavel Krejcir /
//  Dongxu Li (LC_SplinePoints).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Spline-Edit tool. Pick a spline (NURBS `.spline` or fit-point
/// `.splinePoints`), then MOVE / ADD / REMOVE a defining point on the canvas —
/// the spline analogue of `PolylineEditTool`.
public struct SplineEditTool: Tool {

    // MARK: - Edit mode (which action the next pick performs)

    /// What an interaction does to the targeted spline. The default is `.move`;
    /// the app drives this from its UI (a sub-command / option bar) or a modifier
    /// (e.g. ⌥-click for `.remove`). Modeling it as a settable property keeps the
    /// tool a PURE value type with no modifier field on `ToolInput`.
    public enum Mode: Sendable, Equatable {
        /// Click a point to grab it, then click/type a destination to move it.
        case move
        /// Click on/near the curve to insert a new defining point there.
        case add
        /// Click a defining point to remove it (keeping the per-kind minimum).
        case remove
    }

    /// The active edit mode. Mutable so the app (or a test) can switch sub-commands
    /// mid-run without rebuilding the tool. Defaults to `.move`.
    public var mode: Mode = .move

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    private enum State: Equatable {
        /// No target yet: waiting for the click that picks the spline to edit.
        case pickingSpline
        /// A spline target is fixed; waiting for the action click (move/add/remove,
        /// per `mode`). `record` is the entity being edited.
        case editing(record: EntityRecord)
        /// A point was grabbed (`.move` mode); waiting for the destination click /
        /// typed point. `record` is the target, `point` the grabbed point index.
        case movingPoint(record: EntityRecord, point: Int)
    }

    /// The current state. Starts waiting for the spline pick (unless a selection
    /// is adopted on the first `handle`).
    private var state: State = .pickingSpline

    /// The last cursor point seen via `.move`, used to drive the move preview.
    private var cursor: Vector = .invalid

    /// Whether we have already attempted to adopt `context.selected` (so we only do
    /// it once, on the first interaction of the run).
    private var adoptedSelection = false

    /// The pick aperture in world units used to find the target spline and to
    /// decide "click is ON a defining point" (for `.remove`).
    private let pickTolerance: Double

    /// Creates a Spline-Edit tool.
    ///   - `pickTolerance`: world-space aperture to find the target spline and to
    ///     classify a click as on-a-defining-point (default `1e-6`; the app passes
    ///     its px-derived tolerance).
    ///   - `mode`: the initial edit mode (default `.move`).
    public init(pickTolerance: Double = 1e-6, mode: Mode = .move) {
        self.pickTolerance = pickTolerance
        self.mode = mode
    }

    // MARK: - Tool

    public var title: String { "Edit Spline" }

    public var status: String {
        switch state {
        case .pickingSpline:
            return "Click a spline to edit"
        case .editing:
            switch mode {
            case .move:   return "Click a point to move"
            case .add:    return "Click on the spline to add a point"
            case .remove: return "Click a point to remove"
            }
        case .movingPoint:
            return "Specify the new point location"
        }
    }

    /// The live rubber-band. In `.movingPoint` it is the spline with the grabbed
    /// point dragged to the cursor; otherwise it is the target spline as-is (so the
    /// user sees what they are editing). Empty before a target is set.
    public var preview: [ResolvedPolyline] {
        switch state {
        case .pickingSpline:
            return []
        case .editing(let record):
            return Self.previewPolylines(of: record.kind)
        case .movingPoint(let record, let point):
            guard cursor.valid,
                  let moved = Self.movePoint(record.kind, index: point, to: cursor) else {
                return Self.previewPolylines(of: record.kind)
            }
            return Self.previewPolylines(of: moved)
        }
    }

    /// A MODIFY tool: it adopts `context.selected` (or picks via `nearbyEntities`)
    /// and emits ONE `.replace(id, newKind)` per edit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        adoptSelectionIfNeeded(context)

        switch input {
        case .move(let p):
            cursor = p
            // Only the move-destination phase has a moving rubber-band.
            if case .movingPoint = state { return .preview }
            return .none

        case .click(let p):
            return handleClick(p, context: context)

        case .value(let p):
            return handleValue(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            reset()
            return .finished

        case .commit:
            return handleCommit()
        }
    }

    // MARK: - Selection adoption

    /// On the first interaction of a run, if the caller handed us a selected
    /// spline, adopt it as the target so the user need not re-pick. Picks the first
    /// selected spline/splinePoints (the common case is exactly one).
    private mutating func adoptSelectionIfNeeded(_ context: ToolContext) {
        guard !adoptedSelection else { return }
        adoptedSelection = true
        guard case .pickingSpline = state else { return }
        if let sp = context.selected.first(where: { Self.isSpline($0.kind) }) {
            state = .editing(record: sp)
        }
    }

    // MARK: - Click handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .pickingSpline:
            guard let target = nearestSpline(to: p, context: context) else { return .none }
            state = .editing(record: target)
            cursor = p
            return .preview

        case .editing(let record):
            return handleActionClick(p, record: record)

        case .movingPoint(let record, let point):
            return commitMove(record: record, point: point, to: p)
        }
    }

    /// The mode-specific action click while a target is set.
    private mutating func handleActionClick(_ p: Vector, record: EntityRecord) -> ToolOutcome {
        let points = Self.definingPoints(record.kind)
        guard !points.isEmpty else { return .none }
        switch mode {
        case .move:
            // Grab the nearest defining point (no aperture limit — a stray click
            // grabs the closest handle).
            guard let i = Self.nearestPointIndex(points, to: p) else { return .none }
            state = .movingPoint(record: record, point: i)
            cursor = p
            return .preview

        case .add:
            // Insert a defining point at the projection of p onto the nearest leg
            // of the defining polygon.
            guard let newKind = Self.addPoint(record.kind, at: p) else { return .none }
            return commitReplace(record: record, newKind: newKind)

        case .remove:
            // Remove the defining point nearest the click (within aperture),
            // keeping the per-kind minimum.
            guard let i = pointIndexInAperture(points, to: p),
                  let newKind = Self.removePoint(record.kind, index: i) else { return .none }
            return commitReplace(record: record, newKind: newKind)
        }
    }

    /// A typed coordinate (U1 `.value`). In `.movingPoint` it is the exact move
    /// destination. Otherwise ignored (the move/add/remove modes pick entity points
    /// via `.click`).
    private mutating func handleValue(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .movingPoint(let record, let point):
            return commitMove(record: record, point: point, to: p)
        case .editing, .pickingSpline:
            return .none
        }
    }

    private mutating func handleCommit() -> ToolOutcome {
        // Return: nothing is pending mid-point-move (a move commits on its
        // destination click), so Return simply ends the run.
        reset()
        return .finished
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingSpline:
            return .none
        case .editing:
            // Step back to re-pick the spline (drop the target).
            state = .pickingSpline
            cursor = .invalid
            return .none
        case .movingPoint(let record, _):
            // Release the grabbed point, back to the action phase.
            state = .editing(record: record)
            cursor = .invalid
            return .preview
        }
    }

    // MARK: - Commit helpers

    /// Moves the grabbed point to `p`, emits one `.replace`, and resets to the
    /// action phase on the SAME target (chained editing). A no-op move (destination
    /// equals the point) drops the grab WITHOUT committing (no pointless undo step).
    private mutating func commitMove(record: EntityRecord, point: Int, to p: Vector) -> ToolOutcome {
        let points = Self.definingPoints(record.kind)
        guard point >= 0, point < points.count else {
            state = .editing(record: record)
            return .none
        }
        if points[point].distance(to: p) <= Tolerance.distance {
            // Zero move — drop the grab, no commit.
            state = .editing(record: record)
            cursor = .invalid
            return .preview
        }
        guard let newKind = Self.movePoint(record.kind, index: point, to: p) else {
            state = .editing(record: record)
            return .none
        }
        return commitReplace(record: record, newKind: newKind)
    }

    /// Emits one `.replace(id, newKind)` and returns to the action phase on the
    /// target with its kind updated (so the user can chain edits without
    /// re-picking). The record's id / layer / pen / flags / space are preserved by
    /// mutating a copy (only `kind` changes); `closed` is preserved by every
    /// geometry builder.
    private mutating func commitReplace(record: EntityRecord, newKind: EntityKind) -> ToolOutcome {
        var updated = record
        updated.kind = newKind
        state = .editing(record: updated)
        cursor = .invalid
        return .commit([.replace(record.id, newKind)])
    }

    /// Returns to the initial state, dropping the target / cursor. The next run
    /// re-checks `context.selected` (we reset `adoptedSelection`).
    private mutating func reset() {
        state = .pickingSpline
        cursor = .invalid
        adoptedSelection = false
    }

    // MARK: - Target / point picking

    /// Whether `kind` is one of the two editable spline kinds.
    static func isSpline(_ kind: EntityKind) -> Bool {
        switch kind {
        case .spline, .splinePoints: return true
        default: return false
        }
    }

    /// The nearest SPLINE in the pick aperture, by exact distance to `p`.
    private func nearestSpline(to p: Vector, context: ToolContext) -> EntityRecord? {
        context.nearbyEntities(p, pickTolerance)
            .filter { Self.isSpline($0.kind) }
            .min { HitTesting.worldDistance(from: p, to: $0) < HitTesting.worldDistance(from: p, to: $1) }
    }

    /// The index of the defining point nearest `p` (no aperture limit — always
    /// returns a point if any exist). Used by `.move` so a stray click grabs the
    /// closest handle.
    static func nearestPointIndex(_ points: [Vector], to p: Vector) -> Int? {
        guard !points.isEmpty else { return nil }
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, v) in points.enumerated() {
            let dist = v.distance(to: p)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    /// The index of the defining point within the pick aperture of `p`, or `nil`
    /// if the click is not on any point. Used by `.remove` (you must click a point
    /// to remove it).
    private func pointIndexInAperture(_ points: [Vector], to p: Vector) -> Int? {
        var best: Int?
        var bestDist = pickTolerance
        for (i, v) in points.enumerated() {
            let dist = v.distance(to: p)
            if dist <= bestDist { bestDist = dist; best = i }
        }
        return best
    }

    // MARK: - Defining-point accessors (per spline kind)

    /// The user-editable defining points of `kind`: the control polygon for
    /// `.spline` (NURBS) and the stored fit/control points for `.splinePoints`.
    /// Empty for any other kind (the tool never targets those).
    static func definingPoints(_ kind: EntityKind) -> [Vector] {
        switch kind {
        case .spline(let d):        return d.controlPoints
        case .splinePoints(let d):  return d.controlPoints
        default:                    return []
        }
    }

    // MARK: - Spline geometry edits (pure, self-contained, `closed` preserved)

    /// Returns `kind` with defining point `index` moved to `p`. For `.spline` the
    /// `degree` / `knots` / `weights` are KEPT (the count is unchanged, so the
    /// existing knot vector stays valid); for `.splinePoints` the point is replaced
    /// directly. Out-of-range index or a non-spline kind returns `nil`.
    static func movePoint(_ kind: EntityKind, index: Int, to p: Vector) -> EntityKind? {
        switch kind {
        case .spline(var d):
            guard index >= 0, index < d.controlPoints.count else { return nil }
            d.controlPoints[index] = p
            return .spline(d)
        case .splinePoints(var d):
            guard index >= 0, index < d.controlPoints.count else { return nil }
            d.controlPoints[index] = p
            return .splinePoints(d)
        default:
            return nil
        }
    }

    /// Inserts a new defining point at the projection of `p` onto the nearest leg
    /// of the defining polygon (between that leg's two endpoints), so the recomputed
    /// curve passes near the click. Returns `nil` if the spline has no legs or the
    /// kind is not a spline.
    ///
    /// For `.spline` (NURBS): inserting a control point changes the count, so the
    /// stored `knots` no longer match (`count + degree + 1`); we CLEAR them and let
    /// `resolve()` regenerate a clamped uniform knot vector. A rational spline's
    /// `weights` array (if non-empty) gets a weight `1` inserted at the same index
    /// to stay length-aligned.
    static func addPoint(_ kind: EntityKind, at p: Vector) -> EntityKind? {
        switch kind {
        case .spline(var d):
            guard let loc = locateOnLegs(d.controlPoints, closed: d.closed, point: p) else {
                return nil
            }
            d.controlPoints.insert(loc.point, at: loc.leg + 1)
            // Count changed ⇒ existing knots are stale; regenerate on resolve.
            d.knots = []
            if !d.weights.isEmpty {
                d.weights.insert(1.0, at: Swift.min(loc.leg + 1, d.weights.count))
            }
            return .spline(d)
        case .splinePoints(var d):
            guard let loc = locateOnLegs(d.controlPoints, closed: d.closed, point: p) else {
                return nil
            }
            d.controlPoints.insert(loc.point, at: loc.leg + 1)
            return .splinePoints(d)
        default:
            return nil
        }
    }

    /// Removes defining point `index`, guarding the per-kind minimum:
    ///   - `.spline` (NURBS) keeps at least `degree + 1` control points (the
    ///     `NURBS.knotVector` requirement) and CLEARS the stale `knots` so resolve
    ///     regenerates them; a non-empty `weights` array drops the matching weight.
    ///   - `.splinePoints` keeps at least 2 points (below that there is no curve),
    ///     matching `PolylineEditTool.removeVertex`.
    /// Returns `nil` if the removal would breach the minimum, the index is out of
    /// range, or the kind is not a spline.
    static func removePoint(_ kind: EntityKind, index: Int) -> EntityKind? {
        switch kind {
        case .spline(var d):
            let minCount = Swift.max(2, d.degree + 1)
            guard index >= 0, index < d.controlPoints.count, d.controlPoints.count > minCount else {
                return nil
            }
            d.controlPoints.remove(at: index)
            d.knots = []
            if index < d.weights.count { d.weights.remove(at: index) }
            return .spline(d)
        case .splinePoints(var d):
            guard index >= 0, index < d.controlPoints.count, d.controlPoints.count > 2 else {
                return nil
            }
            d.controlPoints.remove(at: index)
            return .splinePoints(d)
        default:
            return nil
        }
    }

    // MARK: - Defining-polygon leg location helper

    /// A located point on a defining-polygon LEG: the leg index (the point it
    /// leaves), the fractional position `t ∈ [0,1]`, and the projected point.
    struct LegLocation {
        let leg: Int
        let t: Double
        let point: Vector
    }

    /// Finds the nearest LEG of the defining polygon `points` to `p`, returning
    /// where the projection lands. For a CLOSED spline the implicit wrap leg
    /// (last → first) is considered. Returns `nil` for fewer than 2 points.
    static func locateOnLegs(_ points: [Vector], closed: Bool, point p: Vector) -> LegLocation? {
        let n = points.count
        guard n >= 2 else { return nil }
        let legCount = closed ? n : n - 1
        var best: LegLocation?
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0..<legCount {
            let s = points[i]
            let e = points[(i + 1) % n]
            let dir = e - s
            let len2 = dir.squared
            guard len2 > Tolerance.distanceSquared else { continue }
            let t = Swift.min(1, Swift.max(0, (p - s).dot(dir) / len2))
            let proj = s + dir * t
            let dist = proj.distance(to: p)
            if dist < bestDist {
                bestDist = dist
                best = LegLocation(leg: i, t: t, point: proj)
            }
        }
        return best
    }

    // MARK: - Preview helper

    /// Resolves an entity kind to preview polylines with the shared preview pen.
    private static func previewPolylines(of kind: EntityKind) -> [ResolvedPolyline] {
        kind.resolve(pen: .toolPreview, ctx: .default).polylines
    }
}
