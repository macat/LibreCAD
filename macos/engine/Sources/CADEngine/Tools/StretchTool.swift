//
//  StretchTool.swift
//  CADEngine
//
//  The STRETCH modify tool — drag (or type a delta for) the ENDPOINTS / VERTICES
//  of the current selection that fall inside a crossing window, leaving the rest
//  fixed. Ported in spirit from LibreCAD's `RS_ActionModifyStretch` /
//  `RS_Modification::stretch` (librecad/src/lib/modification/rs_modification.cpp +
//  librecad/src/actions/drawing/modify/rs_actionmodifystretch.cpp): a two-corner
//  crossing window selects the moving vertices, then a reference→target drag
//  (`displacement = target − reference`) translates only those vertices.
//
//  Behavior (window corners → reference point → destination):
//    - it operates on `context.selected` (the entities the app handed it). With an
//      EMPTY selection there is nothing to stretch, so every input is a no-op and
//      the status tells the user to select first.
//    - first `.click`  → fix the FIRST window corner (State.pickingFirstCorner →
//                        .pickingSecondCorner(first:)). The selection is captured
//                        now so the preview / commit act on a stable set.
//    - second `.click` → fix the SECOND window corner, defining the crossing
//                        window (the axis-aligned box of the two corners). The
//                        vertices of each selected entity that fall INSIDE that box
//                        are the ones that will move (.pickingSecondCorner →
//                        .pickingReference(window:)).
//    - third `.click`  → fix the reference / base point the displacement is
//                        measured FROM (.pickingReference → .pickingDestination).
//    - `.move` in pickingDestination → rubber-band preview: every selected entity
//                        with its in-window vertices translated by `cursor − base`,
//                        the rest fixed, resolved with the `.toolPreview` pen.
//    - fourth `.click` → commit: `delta = destination − base`; for each selected
//                        entity whose geometry CHANGES (≥1 in-window vertex) emit
//                        one `.replace(id, stretchedKind)`. Entities with no
//                        in-window vertex are untouched (no edit). Then reset and
//                        report `.finished`. A zero delta is ignored.
//    - `.value(v)`     → a TYPED displacement (U1): once the window is set, a typed
//                        coordinate is treated as the displacement vector directly
//                        (LibreCAD lets you type the stretch delta). It short-cuts
//                        the reference/destination picks: `delta = v` and the tool
//                        commits the stretch immediately. Before the window is set
//                        it is ignored (no window → nothing to move).
//    - `.backspace`    → step back one pick within the run (no commit).
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//
//  STRETCH semantics (which vertices move): a vertex/endpoint INSIDE the crossing
//  window translates by the delta; a vertex OUTSIDE stays. A line/segment with
//  BOTH endpoints inside therefore translates entirely (both move by the same
//  delta); with ONE endpoint inside only that endpoint moves; with NEITHER it is
//  unchanged (no edit). This is exactly LibreCAD's per-reference-point stretch.
//
//  SCOPE: line, polyline, arc, point, circle, ellipse, spline, splinePoints.
//  Each kind exposes its movable "reference points" (line endpoints, polyline
//  vertices, point position, circle/arc/ellipse center, arc/ellipse endpoints,
//  spline control points) and is stretched by translating only the in-window ones.
//  For an ARC, if BOTH endpoints are in-window the whole arc translates (center
//  moves too, shape preserved); if only one endpoint is in-window that endpoint is
//  re-anchored (the arc is re-fit through the moved endpoint + the fixed endpoint
//  keeping the radius/center fixed is NOT well-defined, so LibreCAD moves the arc
//  endpoint and recomputes — here we keep the engine's pure model: an arc with a
//  single in-window endpoint translates the WHOLE arc only if its center is also
//  in-window, otherwise it is left unchanged to avoid producing a malformed arc).
//  Text/mtext/hatch/solid/dimension translate as a whole iff a defining point is
//  in-window (best-effort; full per-point stretch of those is backlog).
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and builds geometry by translating individual reference
//  points (the same `Affine2D.translation` math the move tools use). The app
//  applies the `.replace` edits (preserving each entity's id / layer / pen /
//  flags) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyStretch / stretch math).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Stretch tool. Pick two crossing-window corners to mark which
/// endpoints/vertices move, then a reference point and a destination (or type a
/// delta) to translate only the in-window vertices, leaving the rest fixed
/// (LibreCAD's modify-stretch).
public struct StretchTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyStretch`'s status
    /// integers (SetFirstCorner → SetSecondCorner → SetReferencePoint →
    /// SetTargetPoint) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the first crossing-window corner.
        case pickingFirstCorner
        /// First corner fixed; waiting for the second. `first` is corner #1.
        case pickingSecondCorner(first: Vector)
        /// Window fixed; waiting for the base / reference point. `window` is the
        /// axis-aligned crossing box selecting the movable vertices.
        case pickingReference(window: AABB)
        /// Reference fixed; waiting for the destination. `window`/`base` drive the
        /// stretch: in-window vertices translate by `destination − base`.
        case pickingDestination(window: AABB, base: Vector)
    }

    /// The current state. Starts waiting for the first window corner.
    private var state: State = .pickingFirstCorner

    /// The last cursor point seen via `.move`, used to draw the rubber-band
    /// between clicks. Invalid until the first move in `pickingDestination`.
    private var cursor: Vector = .invalid

    /// The selection snapshot captured when the run starts (first corner pick), so
    /// the preview / commit act on a stable set (the app rebuilds `context.selected`
    /// per call but it stays stable for this run).
    private var selection: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Stretch" }

    public var status: String {
        switch state {
        case .pickingFirstCorner:
            return selection.isEmpty
                ? "Select objects to stretch first"
                : "Specify first corner of crossing window"
        case .pickingSecondCorner:
            return "Specify opposite corner of crossing window"
        case .pickingReference:
            return "Specify base point"
        case .pickingDestination:
            return "Specify destination (or type a displacement)"
        }
    }

    /// The live rubber-band: every selected entity with its in-window vertices
    /// translated by `cursor − base`, resolved with the preview pen. Empty before
    /// the destination phase, before the cursor has moved, or with no selection.
    public var preview: [ResolvedPolyline] {
        guard case .pickingDestination(let window, let base) = state,
              cursor.valid, base.valid, !selection.isEmpty else {
            return []
        }
        let delta = cursor - base
        return selection.flatMap { record -> [ResolvedPolyline] in
            guard let kind = Self.stretch(record.kind, window: window, delta: delta) else {
                // No in-window vertex → the entity is unchanged; still show it in the
                // preview at its original position so the user sees the whole picture.
                return record.resolve().polylines.map {
                    ResolvedPolyline(points: $0.points, closed: $0.closed, pen: .toolPreview)
                }
            }
            let moved = EntityRecord(
                id: record.id, layer: record.layer, pen: record.pen, flags: record.flags, kind: kind
            )
            return moved.resolve().polylines.map {
                ResolvedPolyline(points: $0.points, closed: $0.closed, pen: .toolPreview)
            }
        }
    }

    /// A MODIFY tool: it reads `context.selected` (the entities to stretch) and
    /// emits `.replace(id, newKind)` for each entity whose in-window vertices move.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value(let v):
            return handleTypedDisplacement(v)

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
            // Return — Stretch completes on its destination click; nothing pending.
            reset()
            return .finished
        }
    }

    // MARK: - Click / typed-input / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .pickingFirstCorner:
            // No selection → nothing to stretch; ignore the click.
            guard !context.selected.isEmpty else { return .none }
            selection = context.selected
            state = .pickingSecondCorner(first: p)
            cursor = p
            return .none

        case .pickingSecondCorner(let first):
            let window = AABB(points: [first, p])
            state = .pickingReference(window: window)
            cursor = p
            return .none

        case .pickingReference(let window):
            state = .pickingDestination(window: window, base: p)
            cursor = p
            return .none

        case .pickingDestination(let window, let base):
            return commitStretch(window: window, delta: p - base)
        }
    }

    /// A typed displacement (U1 `.value`): once the crossing window is set, the
    /// typed vector IS the stretch delta (LibreCAD lets you type the displacement);
    /// the tool commits immediately. Before the window is set it is ignored.
    private mutating func handleTypedDisplacement(_ v: Vector) -> ToolOutcome {
        guard v.valid else { return .none }
        let window: AABB
        switch state {
        case .pickingReference(let w):              window = w
        case .pickingDestination(let w, _):         window = w
        // No window yet → nothing to move; ignore the typed value.
        case .pickingFirstCorner, .pickingSecondCorner:
            return .none
        }
        return commitStretch(window: window, delta: v)
    }

    /// Builds and emits the `.replace` edits for `delta`, then resets. A zero delta
    /// (or no entity actually changed) commits nothing.
    private mutating func commitStretch(window: AABB, delta: Vector) -> ToolOutcome {
        guard delta.valid, delta.magnitude > Tolerance.distance else { return .none }
        let edits: [ToolEdit] = selection.compactMap { record in
            guard let kind = Self.stretch(record.kind, window: window, delta: delta) else { return nil }
            return .replace(record.id, kind)
        }
        reset()
        return edits.isEmpty ? .none : .commit(edits)
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingFirstCorner:
            return .none
        case .pickingSecondCorner:
            // Step back to before the first corner (keep the captured selection).
            state = .pickingFirstCorner
            cursor = .invalid
            return .none
        case .pickingReference:
            // Step back to re-pick the window from its first corner (we keep the
            // captured selection so the user need not re-select).
            state = .pickingFirstCorner
            cursor = .invalid
            return .none
        case .pickingDestination(let window, _):
            state = .pickingReference(window: window)
            cursor = .invalid
            return .preview
        }
    }

    /// Returns to the initial waiting state, dropping the captured selection /
    /// window / cursor.
    private mutating func reset() {
        state = .pickingFirstCorner
        cursor = .invalid
        selection = []
    }

    // MARK: - Stretch geometry (pure, self-contained)

    /// Translates by `delta` only the reference points of `kind` that fall INSIDE
    /// the crossing `window`, leaving the rest fixed. Returns `nil` when NO
    /// reference point is in the window (the entity is unchanged — no edit).
    static func stretch(_ kind: EntityKind, window: AABB, delta: Vector) -> EntityKind? {
        let inside = { (p: Vector) in p.valid && window.contains(p) }
        let t = Affine2D.translation(delta)

        switch kind {
        case .point(let d):
            guard inside(d.position) else { return nil }
            return .point(PointData(position: t.apply(d.position)))

        case .line(let d):
            let s = inside(d.start), e = inside(d.end)
            guard s || e else { return nil }
            return .line(LineData(
                start: s ? t.apply(d.start) : d.start,
                end:   e ? t.apply(d.end)   : d.end))

        case .polyline(let d):
            var changed = false
            let verts = d.vertices.map { v -> PolylineVertex in
                if inside(v.point) {
                    changed = true
                    return PolylineVertex(point: t.apply(v.point), bulge: v.bulge)
                }
                return v
            }
            guard changed else { return nil }
            return .polyline(PolylineData(vertices: verts, closed: d.closed))

        case .circle(let d):
            // A circle's only movable reference point is its center.
            guard inside(d.center) else { return nil }
            return .circle(CircleData(center: t.apply(d.center), radius: d.radius))

        case .arc(let d):
            return stretchArc(d, window: window, delta: delta).map(EntityKind.arc)

        case .ellipse(let d):
            // Whole-shape translate iff the center is in-window (per-endpoint
            // stretch of an elliptic arc would change the conic — backlog).
            guard inside(d.center) else { return nil }
            return .ellipse(EntityTransform.transformEllipse(d, t))

        case .spline(let d):
            var changed = false
            let cps = d.controlPoints.map { p -> Vector in
                if inside(p) { changed = true; return t.apply(p) }
                return p
            }
            guard changed else { return nil }
            return .spline(SplineData(degree: d.degree, controlPoints: cps,
                                      knots: d.knots, weights: d.weights, closed: d.closed))

        case .splinePoints(let d):
            var changed = false
            let cps = d.controlPoints.map { p -> Vector in
                if inside(p) { changed = true; return t.apply(p) }
                return p
            }
            guard changed else { return nil }
            return .splinePoints(SplinePointsData(controlPoints: cps, closed: d.closed))

        case .solid(let d):
            var changed = false
            let corners = d.corners.map { p -> Vector in
                if inside(p) { changed = true; return t.apply(p) }
                return p
            }
            guard changed else { return nil }
            return .solid(SolidData(corners: corners))

        case .text(let d):
            guard inside(d.position) else { return nil }
            return EntityKind.text(d).transformed(by: t)

        case .mtext(let d):
            guard inside(d.position) else { return nil }
            return EntityKind.mtext(d).transformed(by: t)

        case .xline(let d):
            // A construction line's only movable reference point is its base; an
            // infinite line can't have one end stretched, so move it whole iff the
            // base is in-window.
            guard inside(d.base) else { return nil }
            return EntityKind.xline(d).transformed(by: t)

        case .ray(let d):
            guard inside(d.base) else { return nil }
            return EntityKind.ray(d).transformed(by: t)

        case .hatch, .dimension, .insert, .leader, .image:
            // Best-effort whole-translate if ANY defining point is in-window; the
            // per-point stretch of these composite kinds is backlog. We translate
            // the whole entity (its boundary moves with the geometry it bounds). For
            // an `.insert` the defining point is its insertion point; for a `.leader`
            // any path vertex; for an `.image` any quad corner.
            guard anyDefiningPointInside(kind, window: window) else { return nil }
            return kind.transformed(by: t)
        }
    }

    /// Stretches an ARC. Endpoints are the movable reference points; the center is
    /// also a reference point (LibreCAD).
    ///   - both endpoints in-window → translate the whole arc (center too).
    ///   - center in-window → translate the whole arc (rigid move).
    ///   - exactly one endpoint in-window (center fixed) → keep the arc rigid is
    ///     impossible without breaking it, so LibreCAD re-fits; here we keep the
    ///     pure model and translate ONLY when a rigid move is well-defined (both
    ///     endpoints or the center inside), returning nil otherwise so we never
    ///     emit a malformed arc.
    static func stretchArc(_ d: ArcData, window: AABB, delta: Vector) -> ArcData? {
        let t = Affine2D.translation(delta)
        let startP = d.center + Vector.polar(radius: d.radius, angle: d.startAngle)
        let endP = d.center + Vector.polar(radius: d.radius, angle: d.endAngle)
        let sIn = startP.valid && window.contains(startP)
        let eIn = endP.valid && window.contains(endP)
        let cIn = d.center.valid && window.contains(d.center)

        if cIn || (sIn && eIn) {
            // Rigid translate of the whole arc (shape preserved).
            return EntityTransform.transformArc(d, t)
        }
        // A single moved endpoint with a fixed center/other-endpoint has no
        // well-defined arc in the pure model — leave it unchanged.
        return nil
    }

    /// Whether ANY defining point of a composite kind (hatch / dimension) lies in
    /// the window — the trigger for the best-effort whole-translate path.
    private static func anyDefiningPointInside(_ kind: EntityKind, window: AABB) -> Bool {
        let inside = { (p: Vector) in p.valid && window.contains(p) }
        switch kind {
        case .hatch(let h):
            return h.loops.contains { ring in ring.contains { inside($0.point) } }
        case .dimension(let dm):
            if inside(dm.definitionPoint) { return true }
            switch dm.kind {
            case let .linear(e1, e2, _):   return inside(e1) || inside(e2)
            case let .aligned(e1, e2):     return inside(e1) || inside(e2)
            case let .radial(c, p):        return inside(c) || inside(p)
            case let .diameter(p1, p2):    return inside(p1) || inside(p2)
            case let .angular(a, b, c, e): return inside(a) || inside(b) || inside(c) || inside(e)
            case let .ordinate(o, f, l, _):    return inside(o) || inside(f) || inside(l)
            case let .arcLength(c, _, _, _, _): return inside(c)
            case let .angular3p(v, p1, p2):    return inside(v) || inside(p1) || inside(p2)
            }
        case .insert(let ins):
            // A block reference's only stretch reference point is its insertion point.
            return inside(ins.insertionPoint)
        case .leader(let ld):
            // A leader's path vertices are its stretch reference points.
            return ld.vertices.contains { inside($0) }
        case .image(let im):
            // An image's quad corners (+ insertion) are its stretch reference points.
            return im.insertion.valid && (inside(im.insertion) || im.corners.contains(where: inside))
        default:
            return false
        }
    }
}
