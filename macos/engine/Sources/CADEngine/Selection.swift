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
