//
//  Selection.swift
//  CADEngine
//
//  Selection state + CPU hit-testing / window-selection (workstream H —
//  selection + snapping engine). All inputs are in WORLD units (the caller
//  converts screen px → world via the viewport's worldPerPixel); this file does
//  NOT depend on any Viewport type, only on `CADDrawing` + `Quadtree` + world
//  points/tolerances (see macos/docs/rendering-performance.md §5: hit-testing is
//  CPU, exact, decoupled from the GPU/render LOD).
//
//  Hit-testing flow (mirrors RS_Snapper / RS_Information semantics):
//    1. quadtree `query(point:tolerance:)` for AABB candidates near the cursor,
//    2. compute the EXACT analytic distance from the cursor to each candidate's
//       geometry (line/circle/arc/ellipse analytic; polyline/spline via resolved
//       polylines), and
//    3. pick the nearest candidate whose exact distance is within tolerance.
//
//  Distance helpers are `static` members of the namespaced `Geometry2D` enum
//  (CONVENTIONS.md: no module-scope free functions — keep helpers as static
//  members of a namespaced type so parallel modules don't redeclare).
//
//  GPLv2-or-later (LibreCAD derivative). Hit/snap semantics port RS_Snapper +
//  RS_Information (librecad/src/lib/actions/rs_snapper.{h,cpp}).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper / RS_Information).
//

import Foundation

// MARK: - Selection state

/// The set of currently-selected entities, keyed by stable `EntityID`.
///
/// A pure value type (`Sendable`) so it crosses actor boundaries freely and can
/// be snapshotted for undo/preview. The drawing's `EntityFlags.selected` bit is
/// the persisted source of truth on each entity; this struct is the cheap,
/// view-side selection model the interaction layer mutates while dragging/
/// clicking. The two are kept in sync by the tool layer (out of scope here).
public struct Selection: Sendable, Hashable {
    /// The selected entity ids.
    public var ids: Set<EntityID>

    /// An empty selection.
    public init(ids: Set<EntityID> = []) {
        self.ids = ids
    }

    /// Whether nothing is selected.
    public var isEmpty: Bool { ids.isEmpty }

    /// How many entities are selected.
    public var count: Int { ids.count }

    /// Whether `id` is currently selected.
    public func contains(_ id: EntityID) -> Bool { ids.contains(id) }

    /// Adds `id` to the selection (no-op if already present).
    public mutating func add(_ id: EntityID) { ids.insert(id) }

    /// Adds many ids at once.
    public mutating func add<S: Sequence>(contentsOf newIDs: S) where S.Element == EntityID {
        ids.formUnion(newIDs)
    }

    /// Removes `id` from the selection (no-op if absent).
    public mutating func remove(_ id: EntityID) { ids.remove(id) }

    /// Toggles `id`: deselects it if selected, selects it otherwise.
    public mutating func toggle(_ id: EntityID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    /// Clears the whole selection.
    public mutating func clear() { ids.removeAll(keepingCapacity: true) }
}

// MARK: - Geometry2D — exact analytic distance / containment helpers

/// Namespaced static geometry helpers used by hit-testing and snapping. Pure
/// f64 (ADR-003); each takes primitive parameters (never an entity enum) so the
/// kernels stay small and testable. Kept as static members of an `enum` per
/// CONVENTIONS.md (no module-scope free functions in a fan-out target).
public enum Geometry2D {

    // MARK: Point ↔ segment

    /// The point on the finite segment `[a, b]` nearest to `p`, clamped to the
    /// endpoints. Returns `a` for a degenerate (zero-length) segment.
    public static func nearestPointOnSegment(_ p: Vector, _ a: Vector, _ b: Vector) -> Vector {
        let d = b - a
        let len2 = d.squared
        guard len2 > Tolerance.distanceSquared else { return a }
        let t = Swift.min(1.0, Swift.max(0.0, (p - a).dot(d) / len2))
        return a + d * t
    }

    /// Distance from `p` to the finite segment `[a, b]`.
    public static func distanceToSegment(_ p: Vector, _ a: Vector, _ b: Vector) -> Double {
        (p - nearestPointOnSegment(p, a, b)).magnitude
    }

    // MARK: Point ↔ circle

    /// The point on the circle `(center, radius)` nearest to `p` (the radial
    /// projection). For `p` exactly at the center returns the +X point on the
    /// circle (an arbitrary but stable choice).
    public static func nearestPointOnCircle(_ p: Vector, center: Vector, radius: Double) -> Vector {
        let d = p - center
        let len = d.magnitude
        guard len > Tolerance.distance else {
            return center + Vector(abs(radius), 0)
        }
        return center + d * (abs(radius) / len)
    }

    /// Distance from `p` to the circle outline `(center, radius)` — the radial
    /// distance `| |p - center| - radius |`, NOT the distance to the disc.
    public static func distanceToCircle(_ p: Vector, center: Vector, radius: Double) -> Double {
        abs((p - center).magnitude - abs(radius))
    }

    // MARK: Point ↔ arc

    /// Distance from `p` to a circular arc, respecting its angular sweep.
    ///
    /// If the radial projection of `p` falls *within* the arc's swept range the
    /// distance is the radial distance (as for a circle). Otherwise the nearest
    /// point is one of the two arc endpoints (LibreCAD `RS_Arc::getNearestPointOnEntity`
    /// onEntity-vs-endpoint behavior). `reversed == true` is the CW sweep.
    public static func distanceToArc(_ p: Vector,
                                     center: Vector, radius: Double,
                                     startAngle: Double, endAngle: Double,
                                     reversed: Bool) -> Double {
        (p - nearestPointOnArc(p, center: center, radius: radius,
                               startAngle: startAngle, endAngle: endAngle,
                               reversed: reversed)).magnitude
    }

    /// The point on a circular arc nearest to `p`, respecting the angular sweep.
    /// Either the radial projection (if within sweep) or the nearer endpoint.
    public static func nearestPointOnArc(_ p: Vector,
                                         center: Vector, radius: Double,
                                         startAngle: Double, endAngle: Double,
                                         reversed: Bool) -> Vector {
        let r = abs(radius)
        let radial = nearestPointOnCircle(p, center: center, radius: r)
        let ang = (radial - center).angle
        if MathUtils.isAngleBetween(ang, startAngle, endAngle, reversed: reversed) {
            return radial
        }
        // Outside the sweep → the closer endpoint.
        let p0 = center + Vector.polar(radius: r, angle: startAngle)
        let p1 = center + Vector.polar(radius: r, angle: endAngle)
        return (p - p0).squared <= (p - p1).squared ? p0 : p1
    }

    // MARK: Point ↔ polyline (resolved point list)

    /// Distance from `p` to the polyline through `points`. When `closed`, the
    /// implicit closing edge (last → first) is included. A single-point list
    /// returns the point distance; an empty list returns a huge sentinel.
    public static func distanceToPolyline(_ p: Vector, points: [Vector], closed: Bool) -> Double {
        guard let np = nearestPointOnPolyline(p, points: points, closed: closed) else {
            return 1e10
        }
        return (p - np).magnitude
    }

    /// The point on the polyline through `points` nearest to `p`, or `nil` for an
    /// empty list. Includes the implicit closing edge when `closed`.
    public static func nearestPointOnPolyline(_ p: Vector, points: [Vector], closed: Bool) -> Vector? {
        guard let first = points.first else { return nil }
        if points.count == 1 { return first }

        var best = first
        var bestDistSq = (p - first).squared
        for i in 0..<(points.count - 1) {
            let n = nearestPointOnSegment(p, points[i], points[i + 1])
            let dSq = (p - n).squared
            if dSq < bestDistSq { bestDistSq = dSq; best = n }
        }
        if closed, points.count >= 3 {
            let n = nearestPointOnSegment(p, points[points.count - 1], first)
            let dSq = (p - n).squared
            if dSq < bestDistSq { bestDistSq = dSq; best = n }
        }
        return best
    }

    // MARK: Polygon containment (point-in-polygon, ray casting)

    /// Whether `p` is inside the closed polygon `loop` (x/y, even-odd ray cast).
    /// `loop` is an ordered ring NOT repeating its first vertex (same convention
    /// as `ResolvedPolyline` closed / `circlePoints`).
    public static func polygonContains(_ p: Vector, loop: [Vector]) -> Bool {
        let n = loop.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let vi = loop[i]
            let vj = loop[j]
            // Standard crossing-number test against the horizontal ray through p.
            if (vi.y > p.y) != (vj.y > p.y) {
                let denom = vj.y - vi.y
                if denom != 0 {
                    let xCross = vi.x + (p.y - vi.y) / denom * (vj.x - vi.x)
                    if p.x < xCross { inside.toggle() }
                }
            }
            j = i
        }
        return inside
    }

    // MARK: Rect ↔ entity (window vs crossing)

    /// Whether the polyline through `points` is **fully inside** `rect` (window
    /// selection): every vertex is within the rect.
    public static func polylineInside(_ points: [Vector], rect: AABB) -> Bool {
        guard !points.isEmpty, !rect.isEmpty else { return false }
        for v in points where !rect.contains(v) { return false }
        return true
    }

    /// Whether the polyline through `points` **intersects** `rect` (crossing
    /// selection): a vertex is inside, OR a segment crosses a rect edge, OR (for a
    /// closed loop) the rect is entirely inside the loop. The implicit closing
    /// edge is tested when `closed`.
    public static func polylineIntersects(_ points: [Vector], closed: Bool, rect: AABB) -> Bool {
        guard !points.isEmpty, !rect.isEmpty else { return false }

        // Any vertex inside the rect ⇒ intersects.
        for v in points where rect.contains(v) { return true }

        // Any segment crossing a rect edge ⇒ intersects.
        let edges = rectEdges(rect)
        func segmentHitsRect(_ a: Vector, _ b: Vector) -> Bool {
            for e in edges where segmentsIntersect(a, b, e.0, e.1) { return true }
            return false
        }
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                if segmentHitsRect(points[i], points[i + 1]) { return true }
            }
            if closed, points.count >= 3, segmentHitsRect(points[points.count - 1], points[0]) {
                return true
            }
        }

        // Rect fully inside a closed loop (no edges cross, no vertex inside) ⇒
        // still "intersects" for crossing selection (the loop encloses the rect).
        if closed, points.count >= 3, polygonContains(rect.center, loop: points) {
            return true
        }
        return false
    }

    /// The four edges of `rect` as endpoint pairs (CCW from the min corner).
    public static func rectEdges(_ rect: AABB) -> [(Vector, Vector)] {
        let lo = rect.min, hi = rect.max
        let bl = Vector(lo.x, lo.y)
        let br = Vector(hi.x, lo.y)
        let tr = Vector(hi.x, hi.y)
        let tl = Vector(lo.x, hi.y)
        return [(bl, br), (br, tr), (tr, tl), (tl, bl)]
    }

    /// Whether the two finite segments `[a0,a1]` and `[b0,b1]` intersect (proper
    /// or touching). Orientation/straddle test with collinear-overlap handling.
    public static func segmentsIntersect(_ a0: Vector, _ a1: Vector,
                                         _ b0: Vector, _ b1: Vector) -> Bool {
        let d1 = orientation(b0, b1, a0)
        let d2 = orientation(b0, b1, a1)
        let d3 = orientation(a0, a1, b0)
        let d4 = orientation(a0, a1, b1)

        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        // Collinear / touching cases.
        if abs(d1) <= Tolerance.distance && onSegment(b0, b1, a0) { return true }
        if abs(d2) <= Tolerance.distance && onSegment(b0, b1, a1) { return true }
        if abs(d3) <= Tolerance.distance && onSegment(a0, a1, b0) { return true }
        if abs(d4) <= Tolerance.distance && onSegment(a0, a1, b1) { return true }
        return false
    }

    /// Signed area sign of triangle (a, b, c): >0 CCW, <0 CW, ~0 collinear.
    @inline(__always)
    static func orientation(_ a: Vector, _ b: Vector, _ c: Vector) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Whether `p` lies on segment `[a, b]`, assuming the three are collinear.
    @inline(__always)
    static func onSegment(_ a: Vector, _ b: Vector, _ p: Vector) -> Bool {
        p.x >= Swift.min(a.x, b.x) - Tolerance.distance &&
        p.x <= Swift.max(a.x, b.x) + Tolerance.distance &&
        p.y >= Swift.min(a.y, b.y) - Tolerance.distance &&
        p.y <= Swift.max(a.y, b.y) + Tolerance.distance
    }
}

// MARK: - HitTesting — exact distance from a cursor to an entity

/// Hit-testing entry points. The `worldDistance(...)` helper is the exact,
/// analytic-where-cheap cursor-to-entity distance used by both `hitTest` and the
/// snapper's `.onEntity` mode. Static members of a namespaced enum per
/// CONVENTIONS.md.
public enum HitTesting {

    /// The exact world-space distance from `point` to `entity`'s geometry,
    /// analytic for line/circle/arc, and via resolved polylines for the rest
    /// (polyline/ellipse/spline/splinePoints/point). `ctx` controls curve
    /// tessellation fidelity for the polyline-based kinds.
    public static func worldDistance(from point: Vector,
                                     to entity: EntityRecord,
                                     ctx: ResolveContext = .default) -> Double {
        switch entity.kind {
        case .point(let d):
            return (point - d.position).magnitude

        case .line(let d):
            return Geometry2D.distanceToSegment(point, d.start, d.end)

        case .circle(let d):
            return Geometry2D.distanceToCircle(point, center: d.center, radius: d.radius)

        case .arc(let d):
            return Geometry2D.distanceToArc(point, center: d.center, radius: d.radius,
                                            startAngle: d.startAngle, endAngle: d.endAngle,
                                            reversed: d.reversed)

        default:
            // Polyline / ellipse / spline / splinePoints: measure against the
            // resolved (tessellated) polylines. These are bounded-error chords;
            // for the foundation this is the exact-enough path (the curve kinds
            // have no cheap closed-form point distance), and matches LibreCAD
            // falling back to per-segment distance over the entity's atomic parts.
            return distanceToResolved(point, entity: entity, ctx: ctx)
        }
    }

    /// Distance from `point` to all resolved polylines of `entity` (the min over
    /// every polyline, honoring each one's `closed` flag).
    static func distanceToResolved(_ point: Vector, entity: EntityRecord,
                                   ctx: ResolveContext) -> Double {
        let geo = entity.resolve(ctx)
        var best = 1e10
        for pl in geo.polylines {
            let d = Geometry2D.distanceToPolyline(point, points: pl.points, closed: pl.closed)
            if d < best { best = d }
        }
        return best
    }
}

// MARK: - Selection queries (hitTest / windowSelect)

extension Selection {

    /// Picks the single nearest entity within `worldTolerance` of `worldPoint`.
    ///
    /// Quadtree-prefiltered (`query(point:tolerance:)`) candidates, then EXACT
    /// analytic distance to each candidate's geometry; the nearest within
    /// tolerance wins. Returns `nil` when nothing is within range. Hidden/locked
    /// entities (cleared `.visible` flag) are skipped so you can't pick what you
    /// can't see. This is the click-to-select / under-cursor query.
    ///
    /// - Parameters:
    ///   - worldPoint: cursor position in world coords (screen px → world done by
    ///     the caller via the viewport's worldPerPixel).
    ///   - worldTolerance: pick aperture in world units (GUI px × worldPerPixel).
    ///   - drawing: the document (entity lookup by id).
    ///   - quadtree: the shared spatial index (AABB candidate prefilter).
    ///   - ctx: resolve context for curve tessellation of polyline-based kinds.
    @MainActor
    public func hitTest(worldPoint: Vector,
                        worldTolerance: Double,
                        in drawing: CADDrawing,
                        using quadtree: Quadtree,
                        ctx: ResolveContext? = nil) -> EntityID? {
        guard worldPoint.valid else { return nil }
        let tol = Swift.max(worldTolerance, 0)
        let context = ctx ?? drawing.makeResolveContext()

        var best: EntityID? = nil
        var bestDist = Double.greatestFiniteMagnitude
        for id in quadtree.query(point: worldPoint, tolerance: tol) {
            guard let e = drawing.entity(id), e.flags.contains(.visible) else { continue }
            let d = HitTesting.worldDistance(from: worldPoint, to: e, ctx: context)
            if d <= tol && d < bestDist {
                bestDist = d
                best = id
            }
        }
        return best
    }

    /// Window / crossing rectangle selection.
    ///
    /// - `crossing == false` (**window**): only entities **fully inside** `rect`.
    /// - `crossing == true` (**crossing**): entities that **intersect** `rect`
    ///   (any part inside, or a boundary crossing, or `rect` enclosed by a closed
    ///   loop) — the LibreCAD left-to-right (window) vs right-to-left (crossing)
    ///   distinction.
    ///
    /// Quadtree `query(region:)` prefilters to AABB-overlapping candidates, then a
    /// precise contained/intersects test runs against each candidate's resolved
    /// geometry. Returns the matching ids (order unspecified). Hidden entities are
    /// skipped.
    @MainActor
    public func windowSelect(rect: AABB,
                             crossing: Bool,
                             in drawing: CADDrawing,
                             using quadtree: Quadtree,
                             ctx: ResolveContext? = nil) -> [EntityID] {
        guard !rect.isEmpty else { return [] }
        let context = ctx ?? drawing.makeResolveContext()

        var result: [EntityID] = []
        for id in quadtree.query(region: rect) {
            guard let e = drawing.entity(id), e.flags.contains(.visible) else { continue }

            if crossing {
                if Self.entityIntersects(rect: rect, entity: e, ctx: context) {
                    result.append(id)
                }
            } else {
                if Self.entityFullyInside(rect: rect, entity: e, ctx: context) {
                    result.append(id)
                }
            }
        }
        return result
    }

    /// Whether `entity` is fully inside `rect` (window selection).
    ///
    /// The entity is fully inside iff its **analytic** bounding box is inside the
    /// rect: the analytic bbox (Resolve.swift) is exact for line/circle/point and
    /// tight (endpoints + swept axis-extremes) for arc/ellipse, so bbox-inside is
    /// the precise test for "every point of the curve is inside the rect". For the
    /// conservative-hull kinds (spline/splinePoints) the hull bbox is a safe
    /// over-estimate of the extent, so bbox-inside still implies curve-inside.
    static func entityFullyInside(rect: AABB, entity: EntityRecord, ctx: ResolveContext) -> Bool {
        rectContainsBBox(rect, entity.boundingBox())
    }

    /// Whether `entity` intersects `rect` (crossing selection), via its resolved
    /// polylines.
    static func entityIntersects(rect: AABB, entity: EntityRecord, ctx: ResolveContext) -> Bool {
        // Fast accept: a point inside the rect.
        if case .point(let d) = entity.kind { return rect.contains(d.position) }

        let geo = entity.resolve(ctx)
        for pl in geo.polylines {
            if Geometry2D.polylineIntersects(pl.points, closed: pl.closed, rect: rect) {
                return true
            }
        }
        return false
    }

    /// Whether `rect` fully contains `bb` (both corners inside, inclusive).
    @inline(__always)
    static func rectContainsBBox(_ rect: AABB, _ bb: AABB) -> Bool {
        guard !bb.isEmpty, !rect.isEmpty else { return false }
        return rect.contains(bb.min) && rect.contains(bb.max)
    }
}

// MARK: - SelectionTraversal — select connected / contour (graph walk by endpoints)

/// Pure, value-only selection-traversal helpers: **Select Connected** (all
/// entities transitively touching a seed at shared endpoints) and **Select
/// Contour** (the closed loop a seed belongs to, if one exists).
///
/// These mirror LibreCAD's `RS_Selection::selectContour` (the "select contour"
/// action: walk endpoint-to-endpoint following a chain of touching entities).
/// They are **additive** — they compute id sets and never mutate the drawing or
/// the existing `Selection`/`hitTest`/`windowSelect` behavior. The interaction /
/// menu layer (a later wave) wires them to a ⌘K action; here they are the engine
/// API + algorithm the UI will call.
///
/// ## Connection model (what "touching" means)
/// Two entities are *connected* iff a free **endpoint** of one lies within
/// `tolerance` of a free endpoint of the other. Endpoints are the chain-joining
/// points: line ends, arc / elliptic-arc ends, an OPEN polyline's first+last
/// vertex, and an open spline / spline-points' first+last control point. CLOSED
/// shapes (circle, full ellipse, closed polyline, closed spline) and shapes with
/// no endpoints (point, text, hatch, solid, dimension, insert) are *terminal*:
/// they are never traversed INTO and never pulled in as neighbors, exactly as a
/// closed loop has no free end to chain from. A seed that is itself a closed
/// shape selects only itself (it forms its own trivial contour).
///
/// `static` members of a namespaced `enum` (CONVENTIONS §7: no module-scope free
/// functions in a fan-out target). `@MainActor` because they read `CADDrawing`
/// (its main-actor-isolated `entities`), like `SelectionPolicy` / `windowSelect`.
public enum SelectionTraversal {

    // MARK: Endpoints (chain-joining points)

    /// The **free endpoints** of an entity — the points at which it can chain to a
    /// neighbor. Open chainable kinds (line / arc / open polyline / elliptic arc /
    /// open spline / open spline-points) return their two free ends; closed or
    /// endpoint-less kinds (circle, full ellipse, closed polyline/spline, point,
    /// text, mtext, hatch, solid, dimension, insert) return `[]` and so act as
    /// chain terminators. Only `.valid` points are returned.
    ///
    /// (Independent of `Snapping.endpoints(of:)` so `Selection.swift` stays
    /// self-contained; the connection semantics here are deliberately "free ends
    /// only", not "every snappable vertex".)
    public static func endpoints(of entity: EntityRecord) -> [Vector] {
        let pts: [Vector]
        switch entity.kind {
        case .line(let d):
            pts = [d.start, d.end]

        case .arc(let d):
            let r = abs(d.radius)
            pts = [
                d.center + Vector.polar(radius: r, angle: d.startAngle),
                d.center + Vector.polar(radius: r, angle: d.endAngle),
            ]

        case .polyline(let d):
            // Only an OPEN polyline has free ends (a closed one chains to nothing).
            guard !d.closed,
                  let f = d.vertices.first?.point,
                  let l = d.vertices.last?.point else { return [] }
            pts = [f, l]

        case .ellipse(let d):
            // Only an elliptic ARC has free ends (a whole ellipse is closed).
            guard d.isArc else { return [] }
            pts = [d.ellipsePoint(d.startAngle), d.ellipsePoint(d.endAngle)]

        case .spline(let d):
            guard !d.closed, let f = d.controlPoints.first, let l = d.controlPoints.last else {
                return []
            }
            pts = [f, l]

        case .splinePoints(let d):
            guard !d.closed, let f = d.controlPoints.first, let l = d.controlPoints.last else {
                return []
            }
            pts = [f, l]

        case .point, .circle, .text, .mtext, .hatch, .solid, .dimension, .insert,
             .xline, .ray, .leader, .image:
            // No free ends to chain from (closed/areal/annotative, or infinite —
            // a construction line has no FINITE end to chain to). A leader is an
            // annotation callout (like a dimension), so it is terminal too; a raster
            // image is an areal placement (its quad has no free chain-end).
            return []
        }
        return pts.filter(\.valid)
    }

    /// Whether `a` and `b` are connected: some free endpoint of `a` is within
    /// `tolerance` of some free endpoint of `b`. Symmetric. Entities with no free
    /// endpoints (closed/terminal kinds) are never connected to anything.
    public static func areConnected(_ a: EntityRecord, _ b: EntityRecord,
                                    tolerance: Double = Tolerance.distance) -> Bool {
        let tolSq = Swift.max(tolerance, 0) * Swift.max(tolerance, 0)
        let ea = endpoints(of: a)
        guard !ea.isEmpty else { return false }
        let eb = endpoints(of: b)
        guard !eb.isEmpty else { return false }
        for pa in ea {
            for pb in eb where (pa - pb).squared <= tolSq {
                return true
            }
        }
        return false
    }

    // MARK: Select Connected (transitive closure over shared endpoints)

    /// Every entity transitively connected to `seed` by shared endpoints — the
    /// connected component (a chain or a network) the seed belongs to, INCLUDING
    /// the seed itself. A disjoint group that does not touch the component is NOT
    /// included.
    ///
    /// BFS over the touch graph: from each frontier entity, pull in every visible
    /// entity whose free endpoint coincides (within `tolerance`) with one of the
    /// frontier's. Candidates are quadtree-prefiltered per frontier endpoint
    /// (AABB-near), so the cost is ~O(component · localCandidates), not O(n²).
    ///
    /// Returns just `{seed}` when the seed has no free endpoints (a closed shape,
    /// point, text, etc.) or has no touching neighbors. Returns `[]` if `seed`
    /// is missing/hidden from the drawing.
    ///
    /// - Parameters:
    ///   - seed: the entity the walk starts from.
    ///   - drawing: the document (entity lookup by id).
    ///   - quadtree: the shared spatial index (AABB candidate prefilter).
    ///   - tolerance: endpoint-coincidence tolerance in world units
    ///     (defaults to the engine `Tolerance.distance`; a UI may pass a larger
    ///     pick-aperture-scaled value for "looks touching").
    @MainActor
    public static func connected(seed: EntityID,
                                 in drawing: CADDrawing,
                                 using quadtree: Quadtree,
                                 tolerance: Double = Tolerance.distance) -> Set<EntityID> {
        guard let seedEntity = drawing.entity(seed),
              seedEntity.flags.contains(.visible) else { return [] }

        let tol = Swift.max(tolerance, 0)
        var visited: Set<EntityID> = [seed]
        var frontier: [EntityRecord] = [seedEntity]

        while let current = frontier.popLast() {
            for p in endpoints(of: current) {
                // AABB-near candidates around this endpoint (a tiny query box).
                let box = queryBox(around: p, tolerance: tol)
                for candidateID in quadtree.query(region: box) {
                    guard !visited.contains(candidateID),
                          let cand = drawing.entity(candidateID),
                          cand.flags.contains(.visible),
                          areConnected(current, cand, tolerance: tol) else { continue }
                    visited.insert(candidateID)
                    frontier.append(cand)
                }
            }
        }
        return visited
    }

    // MARK: Select Contour (follow a single closed loop from a seed)

    /// The closed contour `seed` belongs to, as an ordered set of entity ids, or
    /// `nil` if the seed is NOT part of a closed loop.
    ///
    /// Walks the chain endpoint-to-endpoint in ONE direction from the seed: at each
    /// step the current entity's far endpoint must coincide (within `tolerance`)
    /// with **exactly one** unvisited neighbor's endpoint — a clean, unambiguous
    /// continuation. The walk succeeds (returns the loop) only when it arrives back
    /// at the seed's starting endpoint, closing the ring. It returns `nil` on a
    /// dead end (open chain), an ambiguous branch (a junction where the contour is
    /// not well-defined), or a seed with no free endpoints.
    ///
    /// A self-closed single entity (a closed polyline / circle / full ellipse /
    /// closed spline) is its own trivial contour: `{seed}`.
    ///
    /// - Parameters:
    ///   - seed: the entity the contour walk starts from.
    ///   - drawing / quadtree: document + spatial index (as `connected`).
    ///   - tolerance: endpoint-coincidence tolerance in world units.
    @MainActor
    public static func contour(seed: EntityID,
                               in drawing: CADDrawing,
                               using quadtree: Quadtree,
                               tolerance: Double = Tolerance.distance) -> Set<EntityID>? {
        guard let seedEntity = drawing.entity(seed),
              seedEntity.flags.contains(.visible) else { return nil }

        let seedEnds = endpoints(of: seedEntity)
        // A self-closed single entity is its own trivial contour.
        if seedEnds.isEmpty {
            return isSelfClosed(seedEntity) ? [seed] : nil
        }
        // Need two distinct free ends to walk a loop (a degenerate one-end entity
        // can't form a contour by itself).
        guard seedEnds.count >= 2 else { return nil }

        let tol = Swift.max(tolerance, 0)
        let tolSq = tol * tol

        // We start at seedEnds[0] and try to return to it, leaving via seedEnds[1].
        let loopClose = seedEnds[0]
        var openEnd = seedEnds[1]          // the end we must continue from next
        var visited: Set<EntityID> = [seed]

        // Bound the walk by entity count to guard against pathological cycles.
        let maxSteps = drawing.count + 1
        var steps = 0

        while steps <= maxSteps {
            steps += 1

            // Closed the loop back to the seed's start endpoint?
            if visited.count > 1, (openEnd - loopClose).squared <= tolSq {
                return visited
            }

            // Find the UNIQUE unvisited neighbor touching `openEnd`.
            guard let (nextEntity, nextFarEnd) = uniqueNeighbor(
                from: openEnd, excluding: visited,
                in: drawing, using: quadtree, tolerance: tol
            ) else {
                return nil   // dead end or ambiguous branch ⇒ no clean contour
            }

            visited.insert(nextEntity.id)
            openEnd = nextFarEnd
        }
        return nil   // exceeded the step bound without closing
    }

    /// The single unvisited entity whose free endpoint coincides with `point`,
    /// together with that entity's OTHER (far) free endpoint to continue from.
    /// Returns `nil` if there is no such entity OR more than one (an ambiguous
    /// branch the contour walk must not cross).
    @MainActor
    static func uniqueNeighbor(from point: Vector,
                               excluding visited: Set<EntityID>,
                               in drawing: CADDrawing,
                               using quadtree: Quadtree,
                               tolerance: Double) -> (EntityRecord, Vector)? {
        let tol = Swift.max(tolerance, 0)
        let tolSq = tol * tol
        let box = queryBox(around: point, tolerance: tol)

        var match: (EntityRecord, Vector)? = nil
        for candidateID in quadtree.query(region: box) {
            guard !visited.contains(candidateID),
                  let cand = drawing.entity(candidateID),
                  cand.flags.contains(.visible) else { continue }
            let ends = endpoints(of: cand)
            guard ends.count >= 2 else { continue }
            // Which end touches `point`? The other is where we continue.
            let touches0 = (ends[0] - point).squared <= tolSq
            let touches1 = (ends[1] - point).squared <= tolSq
            guard touches0 || touches1 else { continue }
            let farEnd = touches0 ? ends[1] : ends[0]
            if match != nil { return nil }   // >1 candidate ⇒ ambiguous branch
            match = (cand, farEnd)
        }
        return match
    }

    /// Whether `entity` is a single self-closed loop (closed polyline / circle /
    /// full ellipse / closed spline / closed spline-points) — its own contour.
    static func isSelfClosed(_ entity: EntityRecord) -> Bool {
        switch entity.kind {
        case .circle:                return true
        case .ellipse(let d):        return !d.isArc
        case .polyline(let d):       return d.closed
        case .spline(let d):         return d.closed
        case .splinePoints(let d):   return d.closed
        default:                     return false
        }
    }

    /// A small AABB centered on `point`, padded by `tolerance` (clamped to at
    /// least `Tolerance.distance` so a zero tolerance still yields a non-degenerate
    /// query region for the quadtree AABB prefilter).
    @inline(__always)
    static func queryBox(around point: Vector, tolerance: Double) -> AABB {
        let pad = Swift.max(tolerance, Tolerance.distance)
        let off = Vector(pad, pad)
        return AABB(min: point - off, max: point + off)
    }
}
