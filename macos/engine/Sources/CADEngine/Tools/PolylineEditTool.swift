//
//  PolylineEditTool.swift
//  CADEngine
//
//  The POLYLINE-EDIT modify tool — edit the vertices of an existing polyline:
//  MOVE a vertex, ADD a vertex on a segment, REMOVE a vertex, or TOGGLE a segment
//  between straight and a circular arc (bulge). Ported in spirit from LibreCAD's
//  "Edit Polyline" family (`RS_ActionPolylineSegment*` / `RS_ActionModify
//  EditVertices` in librecad/src/actions/drawing/modify/): you pick the polyline,
//  then act on one of its vertices/segments, and the result is the same polyline
//  with one vertex moved / inserted / removed, or one segment's bulge flipped.
//
//  Behavior (pick the polyline → act on a vertex / segment, per the active `mode`):
//    - With a polyline already in `context.selected` the tool ADOPTS it as the
//      target on activation (no separate pick); otherwise the FIRST `.click`
//      TARGETS the nearest polyline under the pick (other kinds ignored).
//    - Once a target is set, each interaction depends on `mode`:
//        • .move   — `.click(v)` on a VERTEX picks it (handle highlights); the next
//                    `.click(p)` / `.value(p)` MOVES that vertex to p and commits
//                    one `.replace`. A click that is NOT on a vertex but IS on a
//                    segment falls through to picking the vertex it is nearest to —
//                    so a stray click still grabs the closest handle. `.move`
//                    rubber-bands the polyline with the grabbed vertex at the cursor.
//        • .add    — `.click(p)` on a SEGMENT (not on a vertex) inserts a NEW vertex
//                    at the projection of p onto that segment, between the segment's
//                    two endpoints, and commits one `.replace` (vertex count +1).
//        • .remove — `.click(v)` on a VERTEX drops it (keeping ≥2 vertices) and
//                    commits one `.replace` (vertex count −1). A remove that would
//                    leave <2 vertices is refused (no-op).
//        • .arc    — `.click(p)` on a SEGMENT toggles that segment's START-vertex
//                    bulge between 0 (straight) and the default quarter-circle bulge
//                    (tan(π/8) ≈ 0.4142, a 90° included-angle arc), committing one
//                    `.replace`. If the segment already has a non-zero bulge it is
//                    set back to 0 (straight). A separate "arc-through" variant sets
//                    the bulge so the arc passes through a typed third point.
//    - `.commit` (Return) ends the run when nothing is pending; `.cancel` (Esc)
//      discards any pending pick and finishes. `closed` is always preserved.
//
//  ARC-TOGGLE bulge math: a DXF bulge is `tan(includedAngle / 4)`. The default
//  toggle uses a 90° included angle → `tan(90°/4) = tan(22.5°) ≈ 0.41421` (a clean
//  quarter-circle bulge, LibreCAD's common default). The "arc-through-a-point"
//  variant computes the bulge that makes the segment's arc pass through a given
//  point P: with chord endpoints A,B and the perpendicular signed sagitta `s` of P
//  from the chord, `bulge = 2·s / |chord|` (the sagitta-to-bulge identity —
//  `bulge = tan(θ/4)` and `s = (|chord|/2)·tan(θ/4)`), with the sign giving the
//  arc side. A near-zero sagitta yields a straight segment (bulge 0).
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` (`selected` to adopt a target,
//  `nearbyEntities` to pick one) plus the snapped world points in `ToolInput`, and
//  rebuilds the polyline's defining `PolylineData` entirely from value math. The
//  app applies the single `.replace(id, .polyline(newData))` (preserving the
//  entity's id / layer / pen / flags) as one undoable group.
//
//  WIRED: registered as `ToolKind.polylineEdit` and surfaced in the UI. The edit
//  `mode` (move / add / remove / arc) is exposed in the Tool Options bar and pushed
//  onto the live tool IN PLACE via `CanvasModel.applyToolConfig` (Lane M).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionPolyline* / Edit Polyline).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Polyline-Edit tool. Pick a polyline, then move / add / remove a
/// vertex, or toggle a segment between straight and arc (LibreCAD's Edit Polyline).
public struct PolylineEditTool: Tool {

    // MARK: - Edit mode (which action the next pick performs)

    /// What an interaction does to the targeted polyline. The default is `.move`;
    /// the app drives this from its UI (a sub-command / option bar) or a modifier
    /// (e.g. ⌥-click for `.remove`). Modeling it as a settable property keeps the
    /// tool a PURE value type with no modifier field on `ToolInput`.
    public enum Mode: Sendable, Equatable {
        /// Click a vertex to grab it, then click/type a destination to move it.
        case move
        /// Click a segment to insert a new vertex at that point.
        case add
        /// Click a vertex to remove it (keeping ≥2 vertices).
        case remove
        /// Click a segment to toggle its bulge between straight and a default arc.
        case arc
    }

    /// The active edit mode. Mutable so the app (or a test) can switch sub-commands
    /// mid-run without rebuilding the tool. Defaults to `.move`.
    public var mode: Mode = .move

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    private enum State: Equatable {
        /// No target yet: waiting for the click that picks the polyline to edit.
        case pickingPolyline
        /// A polyline target is fixed; waiting for the action click (move/add/
        /// remove/arc, per `mode`). `record` is the entity being edited.
        case editing(record: EntityRecord)
        /// A vertex was grabbed (`.move` mode); waiting for the destination click /
        /// typed point. `record` is the target, `vertex` the grabbed vertex index.
        case movingVertex(record: EntityRecord, vertex: Int)
    }

    /// The current state. Starts waiting for the polyline pick (unless a selection
    /// is adopted on the first `handle`).
    private var state: State = .pickingPolyline

    /// The last cursor point seen via `.move`, used to drive the move preview.
    private var cursor: Vector = .invalid

    /// Whether we have already attempted to adopt `context.selected` (so we only do
    /// it once, on the first interaction of the run).
    private var adoptedSelection = false

    /// The pick aperture in world units used to find the target polyline and to
    /// decide "click is ON a vertex" vs. "click is on a segment".
    private let pickTolerance: Double

    /// The default arc bulge used by the straight↔arc toggle: a 90° included-angle
    /// arc (a quarter circle), `tan(90°/4) = tan(π/8) ≈ 0.41421356`.
    public static let defaultArcBulge: Double = tan(Double.pi / 8)

    /// Creates a Polyline-Edit tool.
    ///   - `pickTolerance`: world-space aperture to find the target polyline and to
    ///     classify a click as on-a-vertex vs. on-a-segment (default `1e-6`; the app
    ///     passes its px-derived tolerance).
    ///   - `mode`: the initial edit mode (default `.move`).
    public init(pickTolerance: Double = 1e-6, mode: Mode = .move) {
        self.pickTolerance = pickTolerance
        self.mode = mode
    }

    // MARK: - Tool

    public var title: String { "Edit Polyline" }

    public var status: String {
        switch state {
        case .pickingPolyline:
            return "Click a polyline to edit"
        case .editing:
            switch mode {
            case .move:   return "Click a vertex to move"
            case .add:    return "Click a segment to add a vertex"
            case .remove: return "Click a vertex to remove"
            case .arc:    return "Click a segment to toggle straight/arc"
            }
        case .movingVertex:
            return "Specify the new vertex location"
        }
    }

    /// The live rubber-band. In `.movingVertex` it is the polyline with the grabbed
    /// vertex dragged to the cursor; otherwise it is the target polyline as-is (so
    /// the user sees what they are editing). Empty before a target is set.
    public var preview: [ResolvedPolyline] {
        switch state {
        case .pickingPolyline:
            return []
        case .editing(let record):
            return Self.previewPolylines(of: record.kind)
        case .movingVertex(let record, let vertex):
            guard cursor.valid, case .polyline(let d) = record.kind else {
                return Self.previewPolylines(of: record.kind)
            }
            let moved = Self.moveVertex(d, index: vertex, to: cursor)
            return Self.previewPolylines(of: .polyline(moved))
        }
    }

    /// A MODIFY tool: it adopts `context.selected` (or picks via `nearbyEntities`)
    /// and emits ONE `.replace(id, .polyline(newData))` per edit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        adoptSelectionIfNeeded(context)

        switch input {
        case .move(let p):
            cursor = p
            // Only the move-destination phase has a moving rubber-band.
            if case .movingVertex = state { return .preview }
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
    /// polyline, adopt it as the target so the user need not re-pick. Picks the
    /// first selected polyline (the common case is exactly one).
    private mutating func adoptSelectionIfNeeded(_ context: ToolContext) {
        guard !adoptedSelection else { return }
        adoptedSelection = true
        guard case .pickingPolyline = state else { return }
        if let pl = context.selected.first(where: { if case .polyline = $0.kind { return true }; return false }) {
            state = .editing(record: pl)
        }
    }

    // MARK: - Click handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .pickingPolyline:
            guard let target = nearestPolyline(to: p, context: context) else { return .none }
            state = .editing(record: target)
            cursor = p
            return .preview

        case .editing(let record):
            return handleActionClick(p, record: record)

        case .movingVertex(let record, let vertex):
            return commitMove(record: record, vertex: vertex, to: p)
        }
    }

    /// The mode-specific action click while a target is set.
    private mutating func handleActionClick(_ p: Vector, record: EntityRecord) -> ToolOutcome {
        guard case .polyline(let d) = record.kind else { return .none }
        switch mode {
        case .move:
            // Grab the nearest vertex within the aperture; if none is in aperture,
            // still grab the nearest vertex on the polyline (a stray click grabs the
            // closest handle).
            guard let vi = nearestVertexIndex(d, to: p) else { return .none }
            state = .movingVertex(record: record, vertex: vi)
            cursor = p
            return .preview

        case .add:
            // Insert a vertex at the projection of p onto the nearest segment.
            guard let newData = Self.addVertex(d, at: p) else { return .none }
            return commitReplace(record: record, newData: newData)

        case .remove:
            // Remove the vertex nearest the click (within aperture), keeping ≥2.
            guard let vi = vertexIndexInAperture(d, to: p),
                  let newData = Self.removeVertex(d, index: vi) else { return .none }
            return commitReplace(record: record, newData: newData)

        case .arc:
            // Toggle the bulge of the segment under the click.
            guard let newData = Self.toggleSegmentArc(d, at: p, arcBulge: Self.defaultArcBulge)
            else { return .none }
            return commitReplace(record: record, newData: newData)
        }
    }

    /// A typed coordinate (U1 `.value`). In `.movingVertex` it is the exact move
    /// destination. In `.arc` mode it is treated as an "arc-through" point: the
    /// segment under the LAST cursor gets the bulge that makes its arc pass through
    /// the typed point. Otherwise ignored (the other modes pick entity points via
    /// `.click`).
    private mutating func handleValue(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .movingVertex(let record, let vertex):
            return commitMove(record: record, vertex: vertex, to: p)

        case .editing(let record):
            guard mode == .arc, cursor.valid, case .polyline(let d) = record.kind,
                  let newData = Self.setSegmentArcThrough(d, segmentAt: cursor, through: p)
            else { return .none }
            return commitReplace(record: record, newData: newData)

        case .pickingPolyline:
            return .none
        }
    }

    private mutating func handleCommit() -> ToolOutcome {
        // Return: nothing is pending mid-vertex-move (a move commits on its
        // destination click), so Return simply ends the run.
        reset()
        return .finished
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingPolyline:
            return .none
        case .editing:
            // Step back to re-pick the polyline (drop the target).
            state = .pickingPolyline
            cursor = .invalid
            return .none
        case .movingVertex(let record, _):
            // Release the grabbed vertex, back to the action phase.
            state = .editing(record: record)
            cursor = .invalid
            return .preview
        }
    }

    // MARK: - Commit helpers

    /// Moves the grabbed vertex to `p`, emits one `.replace`, and resets to the
    /// action phase on the SAME target (chained editing). A no-op move (destination
    /// equals the vertex) still commits the identical data — harmless — but we
    /// short-circuit a zero move to avoid a pointless undo step.
    private mutating func commitMove(record: EntityRecord, vertex: Int, to p: Vector) -> ToolOutcome {
        guard case .polyline(let d) = record.kind, vertex >= 0, vertex < d.vertices.count else {
            state = .editing(record: record)
            return .none
        }
        if d.vertices[vertex].point.distance(to: p) <= Tolerance.distance {
            // Zero move — drop the grab, no commit.
            state = .editing(record: record)
            cursor = .invalid
            return .preview
        }
        let newData = Self.moveVertex(d, index: vertex, to: p)
        return commitReplace(record: record, newData: newData)
    }

    /// Emits one `.replace(id, .polyline(newData))` and returns to the action phase
    /// on the target with its kind updated (so the user can chain edits without
    /// re-picking). `closed` is preserved by every geometry builder.
    private mutating func commitReplace(record: EntityRecord, newData: PolylineData) -> ToolOutcome {
        let updated = EntityRecord(
            id: record.id, layer: record.layer, pen: record.pen, flags: record.flags,
            kind: .polyline(newData)
        )
        state = .editing(record: updated)
        cursor = .invalid
        return .commit([.replace(record.id, .polyline(newData))])
    }

    /// Returns to the initial state, dropping the target / cursor. The next run
    /// re-checks `context.selected` (we reset `adoptedSelection`).
    private mutating func reset() {
        state = .pickingPolyline
        cursor = .invalid
        adoptedSelection = false
    }

    // MARK: - Target / vertex / segment picking

    /// The nearest POLYLINE in the pick aperture, by exact distance to `p`.
    private func nearestPolyline(to p: Vector, context: ToolContext) -> EntityRecord? {
        context.nearbyEntities(p, pickTolerance)
            .filter { if case .polyline = $0.kind { return true }; return false }
            .min { HitTesting.worldDistance(from: p, to: $0) < HitTesting.worldDistance(from: p, to: $1) }
    }

    /// The index of the polyline vertex nearest `p` (no aperture limit — always
    /// returns a vertex if any exist). Used by `.move` so a stray click grabs the
    /// closest handle.
    private func nearestVertexIndex(_ d: PolylineData, to p: Vector) -> Int? {
        guard !d.vertices.isEmpty else { return nil }
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, v) in d.vertices.enumerated() {
            let dist = v.point.distance(to: p)
            if dist < bestDist { bestDist = dist; best = i }
        }
        return best
    }

    /// The index of the polyline vertex within the pick aperture of `p`, or `nil`
    /// if the click is not on any vertex. Used by `.remove` (you must click a
    /// vertex to remove it).
    private func vertexIndexInAperture(_ d: PolylineData, to p: Vector) -> Int? {
        var best: Int?
        var bestDist = pickTolerance
        for (i, v) in d.vertices.enumerated() {
            let dist = v.point.distance(to: p)
            if dist <= bestDist { bestDist = dist; best = i }
        }
        return best
    }

    // MARK: - Polyline geometry edits (pure, self-contained, `closed` preserved)

    /// Returns `d` with vertex `index` moved to `p` (bulges untouched). Out-of-range
    /// index returns `d` unchanged.
    static func moveVertex(_ d: PolylineData, index: Int, to p: Vector) -> PolylineData {
        guard index >= 0, index < d.vertices.count else { return d }
        var verts = d.vertices
        verts[index] = PolylineVertex(point: p, bulge: verts[index].bulge)
        return PolylineData(vertices: verts, closed: d.closed)
    }

    /// Inserts a new vertex at the projection of `p` onto the nearest segment,
    /// between that segment's two endpoints. Returns `nil` if the polyline has no
    /// segments. The new vertex inherits bulge 0 (straight join); for a bulged
    /// segment the original bulge is left on the leading vertex (the straight-chord
    /// approximation — true bulge subdivision is a backlog refinement).
    static func addVertex(_ d: PolylineData, at p: Vector) -> PolylineData? {
        guard let loc = locateOnSegments(d, point: p) else { return nil }
        var verts = d.vertices
        // Insert after vertex `loc.segment` (i.e. between segment endpoints i, i+1).
        verts.insert(PolylineVertex(point: loc.point, bulge: 0), at: loc.segment + 1)
        return PolylineData(vertices: verts, closed: d.closed)
    }

    /// Removes vertex `index`, keeping at least 2 vertices. Returns `nil` if the
    /// removal would leave fewer than 2 vertices, or the index is out of range.
    static func removeVertex(_ d: PolylineData, index: Int) -> PolylineData? {
        guard index >= 0, index < d.vertices.count, d.vertices.count > 2 else { return nil }
        var verts = d.vertices
        verts.remove(at: index)
        return PolylineData(vertices: verts, closed: d.closed)
    }

    /// Toggles the bulge of the segment under `p`: if its leading vertex's bulge is
    /// ~0 it becomes `arcBulge` (straight → arc); otherwise it becomes 0 (arc →
    /// straight). Returns `nil` if the polyline has no segments.
    static func toggleSegmentArc(_ d: PolylineData, at p: Vector, arcBulge: Double) -> PolylineData? {
        guard let loc = locateOnSegments(d, point: p) else { return nil }
        var verts = d.vertices
        let i = loc.segment
        let current = verts[i].bulge
        verts[i].bulge = abs(current) < Tolerance.distance ? arcBulge : 0
        return PolylineData(vertices: verts, closed: d.closed)
    }

    /// Sets the bulge of the segment under `p` so its arc passes through `through`.
    /// Uses the sagitta-to-bulge identity `bulge = 2·s / |chord|`, where `s` is the
    /// SIGNED perpendicular distance of `through` from the directed chord (left of
    /// the chord ⇒ positive bulge, matching DXF's left-bulging convention). A
    /// near-zero sagitta yields a straight segment. Returns `nil` if there is no
    /// segment under `p` or the segment is degenerate.
    static func setSegmentArcThrough(_ d: PolylineData, segmentAt p: Vector, through: Vector) -> PolylineData? {
        guard let loc = locateOnSegments(d, point: p), through.valid else { return nil }
        let i = loc.segment
        var verts = d.vertices
        let a = verts[i].point
        // For a closed polyline the last segment wraps to vertex 0.
        let b = (i + 1 < verts.count) ? verts[i + 1].point : (d.closed ? verts[0].point : verts[i].point)
        let chord = b - a
        let chordLen = chord.magnitude
        guard chordLen > Tolerance.distance else { return nil }
        // Signed perpendicular distance of `through` from the chord (left-positive).
        let dir = chord / chordLen
        let leftNormal = Vector(-dir.y, dir.x)
        let sagitta = (through - a).dot(leftNormal)
        let bulge = abs(sagitta) < Tolerance.distance ? 0 : (2 * sagitta) / chordLen
        verts[i].bulge = bulge
        return PolylineData(vertices: verts, closed: d.closed)
    }

    // MARK: - Segment location helper

    /// A located point on a polyline SEGMENT: the segment index (the vertex it
    /// leaves), the fractional position `t ∈ [0,1]`, and the projected point.
    struct SegmentLocation {
        let segment: Int
        let t: Double
        let point: Vector
    }

    /// Finds the nearest segment of `d` to `p` (by straight chord), returning where
    /// the projection lands. For a CLOSED polyline the implicit wrap segment
    /// (last → first) is considered so a click on the closing edge is handled.
    /// Returns `nil` if the polyline has fewer than 2 vertices.
    static func locateOnSegments(_ d: PolylineData, point p: Vector) -> SegmentLocation? {
        let n = d.vertices.count
        guard n >= 2 else { return nil }
        // Materialize the wrap segment for a closed polyline (last → first) as an
        // extra "virtual" segment whose index is n-1 (leaving the last vertex).
        let segmentCount = d.closed ? n : n - 1
        var best: SegmentLocation?
        var bestDist = Double.greatestFiniteMagnitude
        for i in 0..<segmentCount {
            let s = d.vertices[i].point
            let e = d.vertices[(i + 1) % n].point
            let dir = e - s
            let len2 = dir.squared
            guard len2 > Tolerance.distanceSquared else { continue }
            let t = Swift.min(1, Swift.max(0, (p - s).dot(dir) / len2))
            let proj = s + dir * t
            let dist = proj.distance(to: p)
            if dist < bestDist {
                bestDist = dist
                best = SegmentLocation(segment: i, t: t, point: proj)
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
