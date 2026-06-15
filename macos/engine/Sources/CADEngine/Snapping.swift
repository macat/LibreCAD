//
//  Snapping.swift
//  CADEngine
//
//  CPU snapping engine (workstream H). Given a world-space cursor point and an
//  enabled set of snap modes, gather candidate snap points from nearby entities
//  (quadtree-prefiltered) and pick the best within tolerance, respecting mode
//  priority. All inputs are WORLD units (the caller converts screen px → world
//  via the viewport's worldPerPixel); NO dependency on a Viewport type.
//
//  Snapping is exact and decoupled from the GPU (rendering-performance.md §5):
//  endpoints/centers/middles come straight from the entity defining data,
//  nearest-point-on-entity from the analytic distance kernels (HitTesting), and
//  intersections from the `Intersections` kernels (RS_Information) — never from
//  tessellated approximations. The grid snap rounds to `gridSpacing`.
//
//  Snap modes / kinds port RS2::SnapMode + RS_Snapper
//  (librecad/src/lib/actions/rs_snapper.{h,cpp}).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper / RS2::SnapMode).
//

import Foundation

// MARK: - Snap modes (OptionSet) + kinds

/// The set of enabled snap modes, mirroring `RS2::SnapMode` as a combinable
/// `OptionSet` (LibreCAD's `RS_SnapMode` struct of bools). `.free` is the
/// always-available fallback (raw cursor position).
public struct SnapMode: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Free positioning — the raw cursor point (always the fallback).
    public static let free         = SnapMode(rawValue: 1 << 0)
    /// Snap to grid points (round to `gridSpacing`).
    public static let grid         = SnapMode(rawValue: 1 << 1)
    /// Snap to entity endpoints (line ends, arc/elliptic-arc ends, polyline verts).
    public static let endpoint     = SnapMode(rawValue: 1 << 2)
    /// Snap to entity centers (circle/arc/ellipse center).
    public static let center       = SnapMode(rawValue: 1 << 3)
    /// Snap to entity middle points (segment / arc midpoints).
    public static let middle       = SnapMode(rawValue: 1 << 4)
    /// Snap to the nearest point on an entity.
    public static let onEntity     = SnapMode(rawValue: 1 << 5)
    /// Snap to intersections between nearby entities.
    public static let intersection = SnapMode(rawValue: 1 << 6)
    /// Snap to the closest point ON a nearby entity to the cursor (true
    /// nearest-point-on-curve). Distinct named mode from `.onEntity` so it can be
    /// toggled independently and carries its own status-bar label; the two share
    /// the same analytic nearest-point kernel.
    public static let nearest      = SnapMode(rawValue: 1 << 7)
    /// Snap to the foot of the perpendicular from the reference ("from") point
    /// onto the target entity (line / arc / circle). Inert without a reference
    /// point (`referencePoint == nil` → no candidates).
    public static let perpendicular = SnapMode(rawValue: 1 << 8)
    /// Snap to a tangent point on a circle / arc / ellipse, as seen from the
    /// reference ("from") point. Inert without a reference point.
    public static let tangent      = SnapMode(rawValue: 1 << 9)
    /// Snap the current segment (reference → cursor) to be parallel to a hovered
    /// reference entity's direction. Inert without a reference point.
    public static let parallel     = SnapMode(rawValue: 1 << 10)
    /// Snap to equidistant points spaced `distanceAlong` apart along a hovered
    /// entity (line / arc / polyline), measured from the entity end nearest the
    /// cursor. LibreCAD's "Snap distance" / equidistant snap. The spacing is
    /// carried alongside the mode set (see `Snapping.snap(distanceAlong:)`); a
    /// non-positive spacing makes the mode inert.
    public static let distanceAlong = SnapMode(rawValue: 1 << 11)
    /// Two-pick "manual middle": snap to the midpoint of two user-picked
    /// references (LibreCAD `RS_ActionSnapMiddleManual`). The two picks are armed
    /// by the UI; the engine primitive is `SnapGeometry.manualMiddle(a:b:)`.
    /// Inert in the auto pipeline (it has no single-cursor candidate).
    public static let manualMiddle = SnapMode(rawValue: 1 << 12)
    /// Two-pick "manual intersection": snap to the intersection of two
    /// user-picked entities even when the auto intersection snap wouldn't surface
    /// it (LibreCAD `RS_ActionSnapIntersectionManual`). The two picks are armed by
    /// the UI; the engine primitive is `Snapping.manualIntersection(entityA:entityB:near:)`.
    /// Inert in the auto pipeline.
    public static let manualIntersection = SnapMode(rawValue: 1 << 13)

    /// The common default set (endpoint + center + middle + intersection +
    /// onEntity + grid), with `.free` always available as the fallback. The new
    /// constructive / equidistant / manual modes (nearest / perpendicular /
    /// tangent / parallel / distanceAlong / manualMiddle / manualIntersection)
    /// are OFF by default — opt-in like LibreCAD's RS2::SnapMode.
    public static let standard: SnapMode = [
        .endpoint, .center, .middle, .intersection, .onEntity, .grid, .free,
    ]
}

/// Which kind of snap produced a result. A single concrete kind (not a set), so
/// the renderer can pick the right marker glyph for the chosen snap.
public enum SnapKind: Sendable, Hashable {
    case free
    case grid
    case endpoint
    case center
    case middle
    case onEntity
    case intersection
    /// Closest point on a nearby entity to the cursor (true nearest-point).
    case nearest
    /// Foot of the perpendicular from the reference point onto an entity.
    case perpendicular
    /// Tangent point on a circle / arc / ellipse from the reference point.
    case tangent
    /// Point keeping the reference→cursor segment parallel to a hovered entity.
    case parallel
}

// NOTE on the new modes' result kinds (distanceAlong / manualMiddle /
// manualIntersection): they intentionally do NOT add `SnapKind` cases. Adding a
// case would force every exhaustive `switch snap.kind` in the (non-owned)
// renderer/overlay layer (`OverlayGeometry.swift`, `CADBench/_SharedOverlayGeometry.swift`)
// to grow a marker-glyph arm — a UI change outside this engine change's owned
// surface. Instead:
//   • distance-along auto-snap results reuse the existing `.onEntity` kind for
//     `SnapResult.kind` (the point IS on the entity), so the marker renders with
//     no UI edit; the dedicated `distanceAlongPoints(...)` primitive remains the
//     testable source of truth and a future UI can relabel/redraw it.
//   • the two-pick manual primitives never flow through the single-cursor
//     `snap(...)` pipeline at all (they are armed by a later two-pick UI step), so
//     they need no `SnapResult.kind`. They are exposed as the pure functions
//     `SnapGeometry.manualMiddle(a:b:)` and `Snapping.manualIntersection(...)`.

/// The chosen snap: the snapped world point, what kind of snap it is, and the
/// entity it snapped to (`nil` for free/grid, or for an intersection where two
/// entities are involved — `entity` then carries the first of the pair).
public struct SnapResult: Sendable, Hashable {
    public let point: Vector
    public let kind: SnapKind
    public let entity: EntityID?

    public init(point: Vector, kind: SnapKind, entity: EntityID? = nil) {
        self.point = point
        self.kind = kind
        self.entity = entity
    }
}

// MARK: - Snapping engine

/// CPU snapping. Static entry point (namespaced enum per CONVENTIONS.md) so the
/// interaction layer calls `Snapping.snap(...)` with a world cursor + tolerance.
public enum Snapping {

    /// Cap on the number of candidate entities considered for the O(n²)
    /// intersection-pair enumeration. Quadtree prefiltering already bounds the
    /// candidate set to entities near the cursor, but a dense cluster under the
    /// aperture could still blow up; capping keeps the snap responsive on huge
    /// drawings (rendering-performance.md §5: snapping must not stall the cursor).
    /// With the cap, intersection-snap is at most `cap·(cap-1)/2` pair tests.
    public static let intersectionCandidateCap = 24

    /// Mode-priority order (highest first). When several candidates of different
    /// kinds are within tolerance, the highest-priority kind wins even if a
    /// lower-priority candidate is marginally closer — matching the CAD
    /// expectation that an endpoint "beats" a mere on-entity snap. Ties within a
    /// kind are broken by distance.
    ///
    /// endpoint > center > middle > intersection > perpendicular > tangent >
    /// parallel > distanceAlong > onEntity > nearest > grid > free.
    ///
    /// The constructive snaps (perpendicular / tangent / parallel) require an
    /// explicit reference point and an intentional toggle, so they rank above the
    /// passive `onEntity` / `nearest` "anywhere on the curve" snaps but below the
    /// discrete defining-geometry snaps (endpoint / center / middle / intersection).
    /// `distanceAlong` is a discrete equidistant snap with a configured spacing;
    /// it ranks just above the passive `onEntity`/`nearest` snaps so an equidistant
    /// tick beats a mere closest-point, but below the defining-geometry and
    /// reference-point snaps. It is tracked by an internal priority kind
    /// (`InternalKind.distanceAlong`) yet reported to callers as `.onEntity` (the
    /// point IS on the entity) so no new public `SnapKind` / renderer arm is needed.
    static let priority: [InternalKind] = [
        .public(.endpoint), .public(.center), .public(.middle), .public(.intersection),
        .public(.perpendicular), .public(.tangent), .public(.parallel),
        .distanceAlong,
        .public(.onEntity), .public(.nearest), .public(.grid), .public(.free),
    ]

    /// The internal priority key: either a public `SnapKind`, or the engine-only
    /// `distanceAlong` rank (which is reported to callers as `.onEntity`). Kept
    /// internal so the public `SnapKind` enum — and the renderer switches over it —
    /// stay untouched while distance-along still gets its own resolution rank.
    enum InternalKind: Hashable {
        case `public`(SnapKind)
        case distanceAlong

        /// The public kind reported in `SnapResult` for this internal rank.
        var resultKind: SnapKind {
            switch self {
            case .public(let k): return k
            case .distanceAlong: return .onEntity
            }
        }
    }

    /// An internal candidate before priority resolution. `kind` is the internal
    /// priority key; the public result kind is `kind.resultKind`.
    private struct Candidate {
        let point: Vector
        let kind: InternalKind
        let entity: EntityID?
        let distance: Double
    }

    /// Snaps `worldPoint` to the best candidate within `worldTolerance`.
    ///
    /// Candidates are gathered from entities near the cursor (quadtree
    /// `query(point:tolerance:)`):
    /// - **endpoint**: line ends; arc / elliptic-arc ends; polyline vertices.
    /// - **center**: circle / arc / ellipse center.
    /// - **middle**: segment midpoint (line); arc midpoint; polyline segment mids.
    /// - **onEntity**: the analytic nearest point on each candidate entity.
    /// - **intersection**: crossing points of nearby entity pairs (via the
    ///   `Intersections` kernels), capped at `intersectionCandidateCap` entities.
    /// - **grid**: the cursor rounded to `gridSpacing` (if provided).
    ///
    /// The best is chosen by mode priority (`priority`), then by distance within a
    /// kind. Falls back to `.free` (the raw point) when nothing snaps. The caller
    /// supplies all tolerances/spacing in world units.
    ///
    /// - Parameters:
    ///   - worldPoint: cursor in world coords.
    ///   - modes: the enabled snap modes (`.standard` is a good default).
    ///   - worldTolerance: snap aperture in world units (GUI px × worldPerPixel).
    ///   - gridSpacing: world-unit grid step; `nil` (or `.grid` not enabled)
    ///     disables grid snapping.
    ///   - drawing: the document.
    ///   - quadtree: the shared spatial index.
    ///   - ctx: resolve context for curve tessellation (onEntity for curve kinds).
    ///   - referencePoint: the tool's "from" point (last placed point /
    ///     relative-zero). Required by the constructive modes (`.perpendicular`,
    ///     `.tangent`, `.parallel`); when `nil` those modes contribute no
    ///     candidates, so existing callers that omit it are unaffected.
    ///   - distanceAlong: the equidistant spacing (world units) for the
    ///     `.distanceAlong` snap. When `nil` or non-positive (or `.distanceAlong`
    ///     not enabled) the equidistant snap contributes no candidates, so existing
    ///     callers that omit it are unaffected. The UI sets this from the tool's
    ///     "Snap distance" field.
    @MainActor
    public static func snap(worldPoint: Vector,
                            modes: SnapMode,
                            worldTolerance: Double,
                            gridSpacing: Double?,
                            in drawing: CADDrawing,
                            using quadtree: Quadtree,
                            ctx: ResolveContext? = nil,
                            referencePoint: Vector? = nil,
                            distanceAlong: Double? = nil) -> SnapResult {
        let freeResult = SnapResult(point: worldPoint, kind: .free, entity: nil)
        guard worldPoint.valid else { return freeResult }
        let tol = Swift.max(worldTolerance, 0)
        let context = ctx ?? drawing.makeResolveContext()

        // Quadtree candidate entities near the cursor (AABB prefilter).
        let candidateIDs = quadtree.query(point: worldPoint, tolerance: tol)
        let entities: [EntityRecord] = candidateIDs.compactMap { id in
            guard let e = drawing.entity(id), e.flags.contains(.visible) else { return nil }
            return e
        }

        var candidates: [Candidate] = []

        // Per-entity snap points (endpoint / center / middle / onEntity).
        for e in entities {
            if modes.contains(.endpoint) {
                for p in endpoints(of: e) {
                    appendIfNear(&candidates, point: p, kind: .endpoint, entity: e.id,
                                 cursor: worldPoint, tol: tol)
                }
            }
            if modes.contains(.center) {
                for p in centers(of: e) {
                    appendIfNear(&candidates, point: p, kind: .center, entity: e.id,
                                 cursor: worldPoint, tol: tol)
                }
            }
            if modes.contains(.middle) {
                for p in middles(of: e, ctx: context) {
                    appendIfNear(&candidates, point: p, kind: .middle, entity: e.id,
                                 cursor: worldPoint, tol: tol)
                }
            }
            if modes.contains(.onEntity) {
                let np = nearestOnEntity(worldPoint, entity: e, ctx: context)
                appendIfNear(&candidates, point: np, kind: .onEntity, entity: e.id,
                             cursor: worldPoint, tol: tol)
            }
            if modes.contains(.nearest) {
                // True nearest-point-on-curve to the cursor (shares the analytic
                // kernel with onEntity; distinct mode/label).
                let np = nearestOnEntity(worldPoint, entity: e, ctx: context)
                appendIfNear(&candidates, point: np, kind: .nearest, entity: e.id,
                             cursor: worldPoint, tol: tol)
            }
            // Equidistant ("Snap distance") points along the entity, from the end
            // nearest the cursor. Inert without a positive spacing.
            if modes.contains(.distanceAlong), let spacing = distanceAlong, spacing > Tolerance.distance {
                for p in distanceAlongPoints(of: e, spacing: spacing, near: worldPoint, ctx: context) {
                    appendIfNear(&candidates, point: p, internalKind: .distanceAlong, entity: e.id,
                                 cursor: worldPoint, tol: tol)
                }
            }
            // Constructive modes need the tool's reference ("from") point.
            if let ref = referencePoint, ref.valid {
                if modes.contains(.perpendicular) {
                    for p in perpendicularFeet(from: ref, entity: e) {
                        appendIfNear(&candidates, point: p, kind: .perpendicular, entity: e.id,
                                     cursor: worldPoint, tol: tol)
                    }
                }
                if modes.contains(.tangent) {
                    for p in tangentPoints(from: ref, entity: e) {
                        appendIfNear(&candidates, point: p, kind: .tangent, entity: e.id,
                                     cursor: worldPoint, tol: tol)
                    }
                }
                if modes.contains(.parallel) {
                    if let p = parallelSnap(from: ref, cursor: worldPoint, entity: e) {
                        appendIfNear(&candidates, point: p, kind: .parallel, entity: e.id,
                                     cursor: worldPoint, tol: tol)
                    }
                }
            }
        }

        // Intersections between nearby entity pairs (capped).
        if modes.contains(.intersection) {
            let capped = Array(entities.prefix(intersectionCandidateCap))
            for i in 0..<capped.count {
                for j in (i + 1)..<capped.count {
                    let sols = intersections(capped[i], capped[j])
                    for p in sols where p.valid {
                        appendIfNear(&candidates, point: p, kind: .intersection,
                                     entity: capped[i].id, cursor: worldPoint, tol: tol)
                    }
                }
            }
        }

        // Grid: round the cursor to the spacing (independent of entities).
        if modes.contains(.grid), let spacing = gridSpacing, spacing > Tolerance.distance {
            let gp = snappedToGrid(worldPoint, spacing: spacing)
            appendIfNear(&candidates, point: gp, kind: .grid, entity: nil,
                         cursor: worldPoint, tol: tol)
        }

        // Resolve by mode priority, then by distance within the chosen kind.
        for kind in priority {
            let ofKind = candidates.filter { $0.kind == kind }
            if let best = ofKind.min(by: { $0.distance < $1.distance }) {
                return SnapResult(point: best.point, kind: best.kind.resultKind, entity: best.entity)
            }
        }

        // Nothing within tolerance → free fallback (the raw cursor point).
        return freeResult
    }

    // MARK: - Candidate gathering helpers

    /// Appends a candidate iff it is within `tol` of the cursor. `kind` is given
    /// as a public `SnapKind` (wrapped into the internal priority key); the
    /// `internalKind:` overload is used for the engine-only `distanceAlong` rank.
    private static func appendIfNear(_ out: inout [Candidate],
                                     point: Vector, kind: SnapKind, entity: EntityID?,
                                     cursor: Vector, tol: Double) {
        appendIfNear(&out, point: point, internalKind: .public(kind), entity: entity,
                     cursor: cursor, tol: tol)
    }

    /// Appends a candidate keyed by an explicit internal priority `kind`.
    private static func appendIfNear(_ out: inout [Candidate],
                                     point: Vector, internalKind kind: InternalKind, entity: EntityID?,
                                     cursor: Vector, tol: Double) {
        guard point.valid else { return }
        let d = (point - cursor).magnitude
        guard d <= tol else { return }
        out.append(Candidate(point: point, kind: kind, entity: entity, distance: d))
    }

    /// The endpoints of an entity: line ends, arc / elliptic-arc ends, polyline
    /// vertices, spline / splinePoints control endpoints. Circles/full ellipses
    /// and points have no endpoints.
    static func endpoints(of entity: EntityRecord) -> [Vector] {
        switch entity.kind {
        case .point, .circle:
            return []

        case .line(let d):
            return [d.start, d.end]

        case .arc(let d):
            let r = abs(d.radius)
            return [
                d.center + Vector.polar(radius: r, angle: d.startAngle),
                d.center + Vector.polar(radius: r, angle: d.endAngle),
            ]

        case .polyline(let d):
            return d.vertices.map(\.point)

        case .ellipse(let d):
            // Only an elliptic ARC has endpoints (a whole ellipse is closed).
            guard d.isArc else { return [] }
            return [d.ellipsePoint(d.startAngle), d.ellipsePoint(d.endAngle)]

        case .spline(let d):
            // Open splines interpolate their first/last control points (clamped
            // knots); closed ones have no distinguished endpoint.
            guard !d.closed, let f = d.controlPoints.first, let l = d.controlPoints.last else {
                return []
            }
            return [f, l]

        case .splinePoints(let d):
            guard !d.closed, let f = d.controlPoints.first, let l = d.controlPoints.last else {
                return []
            }
            return [f, l]

        case .text, .mtext:
            // (M)TEXT has no single canonical endpoint to snap (the glyph
            // strokes/fills are an implementation detail); left to other snap kinds.
            return []

        case .hatch(let d):
            // The boundary-loop vertices are the snappable corners.
            return d.loops.flatMap { $0.map(\.point) }

        case .solid(let d):
            return d.corners

        case .dimension(let d):
            // The dimension's defining points (the measured points / extension
            // origins / circle points) plus the dim-line location are the
            // meaningful snap targets.
            var pts: [Vector] = [d.definitionPoint]
            switch d.kind {
            case let .linear(e1, e2, _):                pts += [e1, e2]
            case let .aligned(e1, e2):                  pts += [e1, e2]
            case let .radial(center, pointOnCircle):    pts += [center, pointOnCircle]
            case let .diameter(p1, p2):                 pts += [p1, p2]
            case let .angular(l1s, l1e, l2s, l2e):      pts += [l1s, l1e, l2s, l2e]
            case let .ordinate(origin, feature, leaderEnd, _):
                pts += [origin, feature, leaderEnd]
            case let .arcLength(center, radius, startAngle, endAngle, _):
                // The feature-arc endpoints (+ its center) are the snap targets.
                pts += [center,
                        center + Vector.polar(radius: abs(radius), angle: startAngle),
                        center + Vector.polar(radius: abs(radius), angle: endAngle)]
            case let .angular3p(vertex, p1, p2):        pts += [vertex, p1, p2]
            }
            return pts.filter(\.valid)

        case .insert(let d):
            // The insertion point is the canonical snap target for a block
            // reference (block-interior geometry snapping is backlog — the members
            // aren't expanded here without a block provider).
            return d.insertionPoint.valid ? [d.insertionPoint] : []

        case .xline(let d):
            // The base point is the canonical snap target for an infinite line
            // (it has no finite endpoints).
            return d.base.valid ? [d.base] : []

        case .ray(let d):
            // The ray's start (base) is its one real endpoint.
            return d.base.valid ? [d.base] : []

        case .leader(let d):
            // The leader's path vertices (the arrow tip + each knee + the
            // annotation anchor) are the snappable points.
            return d.vertices.filter(\.valid)

        case .image(let d):
            // The four quad corners are the snappable defining points of a placed
            // image — `corners[0]` IS the lower-left insertion point, so it is not
            // listed again (the quad center is offered by `centers(of:)` below).
            return d.corners.filter(\.valid)
        }
    }

    /// The center(s) of an entity: circle / arc / ellipse center, or a placed
    /// image's quad center. Others none.
    static func centers(of entity: EntityRecord) -> [Vector] {
        switch entity.kind {
        case .circle(let d): return [d.center]
        case .arc(let d):    return [d.center]
        case .ellipse(let d): return [d.center]
        case .image(let d):
            // The quad center == insertion + (u·W + v·H) / 2.
            let c = d.insertion + (d.widthVector + d.heightVector) * 0.5
            return c.valid ? [c] : []
        default:             return []
        }
    }

    /// The middle point(s) of an entity: line segment midpoint, arc / elliptic-arc
    /// midpoint (the point at the sweep's half-angle), and each polyline segment's
    /// midpoint. Circles report the point opposite the start angle (the "12 o'clock
    /// of the radius" has no canonical middle; LibreCAD treats a circle's middle as
    /// its center, but we leave centers to `.center` and report none here).
    static func middles(of entity: EntityRecord, ctx: ResolveContext) -> [Vector] {
        switch entity.kind {
        case .point, .circle:
            return []

        case .line(let d):
            return [(d.start + d.end) * 0.5]

        case .arc(let d):
            // Midpoint at the half-sweep angle, in the direction of travel.
            let twoPi = 2 * Double.pi
            var sweep = d.reversed ? (d.startAngle - d.endAngle) : (d.endAngle - d.startAngle)
            sweep = sweep.truncatingRemainder(dividingBy: twoPi)
            if sweep <= Tolerance.angle { sweep += twoPi }
            let mid = d.startAngle + (d.reversed ? -sweep : sweep) * 0.5
            return [d.center + Vector.polar(radius: abs(d.radius), angle: mid)]

        case .polyline(let d):
            // Midpoint of each straight inter-vertex segment (bulged segments use
            // the chord midpoint — a reasonable approximation for the foundation).
            guard d.vertices.count >= 2 else { return [] }
            var mids: [Vector] = []
            for i in 0..<(d.vertices.count - 1) {
                mids.append((d.vertices[i].point + d.vertices[i + 1].point) * 0.5)
            }
            if d.closed, d.vertices.count >= 3 {
                mids.append((d.vertices[d.vertices.count - 1].point + d.vertices[0].point) * 0.5)
            }
            return mids

        case .ellipse(let d):
            guard d.isArc else { return [] }
            let twoPi = 2 * Double.pi
            var sweep = d.reversed ? (d.startAngle - d.endAngle) : (d.endAngle - d.startAngle)
            sweep = sweep.truncatingRemainder(dividingBy: twoPi)
            if sweep <= Tolerance.angle { sweep += twoPi }
            let mid = d.startAngle + (d.reversed ? -sweep : sweep) * 0.5
            return [d.ellipsePoint(mid)]

        case .spline, .splinePoints:
            // No cheap canonical midpoint; left to onEntity/endpoint snaps.
            return []

        case .text, .mtext:
            // No canonical midpoint for (m)text.
            return []

        case .hatch(let d):
            // Midpoint of each boundary-loop edge (chord midpoints; bulge-arc
            // boundaries use the straight-chord midpoint — see resolve note).
            var mids: [Vector] = []
            for ring in d.loops where ring.count >= 2 {
                for i in 0..<ring.count {
                    let a = ring[i].point
                    let b = ring[(i + 1) % ring.count].point
                    mids.append((a + b) * 0.5)
                }
            }
            return mids

        case .solid(let d):
            // Midpoint of each edge of the filled triangle/quad.
            guard d.corners.count >= 2 else { return [] }
            var mids: [Vector] = []
            for i in 0..<d.corners.count {
                mids.append((d.corners[i] + d.corners[(i + 1) % d.corners.count]) * 0.5)
            }
            return mids

        case .dimension:
            // A dimension has no canonical "middle" snap (its defining points are
            // exposed as endpoints); leave middles to other snap kinds.
            return []

        case .insert:
            // A block reference has no canonical middle (its insertion point is the
            // endpoint snap); block-interior middles are backlog.
            return []

        case .xline, .ray:
            // An infinite/semi-infinite construction line has no canonical middle
            // (its base is the endpoint snap); leave to onEntity/perpendicular.
            return []

        case .leader(let d):
            // The midpoint of each straight path segment (the chord midpoint), so
            // a leader's legs snap like a polyline's.
            guard d.vertices.count >= 2 else { return [] }
            var mids: [Vector] = []
            for i in 0..<(d.vertices.count - 1) {
                mids.append((d.vertices[i] + d.vertices[i + 1]) * 0.5)
            }
            return mids.filter(\.valid)

        case .image(let d):
            // The midpoint of each edge of the image frame quad (so the image's
            // borders snap like a closed polyline's; the corners are the endpoint
            // snap and the quad center is the center snap).
            let corners = d.corners
            guard corners.count == 4 else { return [] }
            var mids: [Vector] = []
            for i in 0..<4 {
                mids.append((corners[i] + corners[(i + 1) % 4]) * 0.5)
            }
            return mids.filter(\.valid)
        }
    }

    /// The analytic nearest point on `entity` to `point` (the `.onEntity` snap).
    /// Analytic for line/circle/arc; via resolved polylines for the rest.
    static func nearestOnEntity(_ point: Vector, entity: EntityRecord, ctx: ResolveContext) -> Vector {
        switch entity.kind {
        case .point(let d):
            return d.position

        case .line(let d):
            return Geometry2D.nearestPointOnSegment(point, d.start, d.end)

        case .circle(let d):
            return Geometry2D.nearestPointOnCircle(point, center: d.center, radius: d.radius)

        case .arc(let d):
            return Geometry2D.nearestPointOnArc(point, center: d.center, radius: d.radius,
                                                startAngle: d.startAngle, endAngle: d.endAngle,
                                                reversed: d.reversed)

        default:
            let geo = entity.resolve(ctx)
            var best = Vector.invalid
            var bestDistSq = Double.greatestFiniteMagnitude
            for pl in geo.polylines {
                if let np = Geometry2D.nearestPointOnPolyline(point, points: pl.points, closed: pl.closed) {
                    let dSq = (point - np).squared
                    if dSq < bestDistSq { bestDistSq = dSq; best = np }
                }
            }
            return best
        }
    }

    // MARK: - Constructive snap helpers (need a reference point)

    /// The perpendicular foot/feet from `from` onto `entity`. Analytic for
    /// line / circle / arc; for a line the foot is kept only if it lands on the
    /// finite segment (matching the CAD "perpendicular to this segment" intent).
    /// Other kinds have no cheap analytic perpendicular and return `[]` (the
    /// passive on-entity/nearest snaps still cover them).
    static func perpendicularFeet(from: Vector, entity: EntityRecord) -> [Vector] {
        switch entity.kind {
        case .line(let d):
            // Foot on the infinite carrier line, kept only if it lies on the
            // finite segment (else there's no valid perpendicular to the drawn line).
            let foot = SnapGeometry.perpendicularFootOnLine(from: from, a: d.start, b: d.end)
            guard foot.valid else { return [] }
            let onSeg = SnapGeometry.perpendicularFootOnSegment(from: from, a: d.start, b: d.end)
            return (foot - onSeg).squared <= Tolerance.distanceSquared ? [foot] : []

        case .circle(let d):
            return SnapGeometry.perpendicularFeetOnCircle(from: from, center: d.center, radius: d.radius)

        case .arc(let d):
            return SnapGeometry.perpendicularFeetOnArc(from: from, center: d.center, radius: d.radius,
                                                       startAngle: d.startAngle, endAngle: d.endAngle,
                                                       reversed: d.reversed)

        case .xline(let d):
            // Perpendicular foot onto the infinite carrier line — always valid for
            // an xline (it has no segment bounds).
            let foot = SnapGeometry.perpendicularFootOnLine(
                from: from, a: d.base, b: d.base + d.direction)
            return foot.valid ? [foot] : []

        case .ray(let d):
            // Foot onto the carrier line, kept only if it lies on the +direction
            // half-line (the drawn part of the ray).
            let foot = SnapGeometry.perpendicularFootOnLine(
                from: from, a: d.base, b: d.base + d.direction)
            guard foot.valid, (foot - d.base).dot(d.direction) >= -Tolerance.distance else { return [] }
            return [foot]

        default:
            return []
        }
    }

    /// The tangent point(s) on `entity` from the external reference `from`.
    /// Defined for circle / arc / ellipse (a line has no tangent point). Other
    /// kinds return `[]`.
    static func tangentPoints(from: Vector, entity: EntityRecord) -> [Vector] {
        switch entity.kind {
        case .circle(let d):
            return SnapGeometry.tangentPointsOnCircle(from: from, center: d.center, radius: d.radius)

        case .arc(let d):
            return SnapGeometry.tangentPointsOnArc(from: from, center: d.center, radius: d.radius,
                                                   startAngle: d.startAngle, endAngle: d.endAngle,
                                                   reversed: d.reversed)

        case .ellipse(let d):
            let pts = SnapGeometry.tangentPointsOnEllipse(from: from, center: d.center,
                                                          majorRadius: d.majorRadius,
                                                          minorRadius: d.minorRadius,
                                                          rotation: d.rotationAngle)
            // For an elliptic ARC, keep only tangent points within the sweep.
            guard d.isArc else { return pts }
            return pts.filter { ellipseAngleSwept($0, ellipse: d) }

        default:
            return []
        }
    }

    /// The parallel snap point for `entity`: the cursor projected onto the line
    /// through `from` parallel to the entity's direction. Defined where the
    /// entity has a well-defined direction (a line / a polyline's straight
    /// segment use the segment direction; we use the line direction here). Other
    /// kinds return `nil`.
    static func parallelSnap(from: Vector, cursor: Vector, entity: EntityRecord) -> Vector? {
        switch entity.kind {
        case .line(let d):
            let p = SnapGeometry.parallelProjection(from: from, cursor: cursor, refDir: d.end - d.start)
            return p.valid ? p : nil
        case .xline(let d):
            let p = SnapGeometry.parallelProjection(from: from, cursor: cursor, refDir: d.direction)
            return p.valid ? p : nil
        case .ray(let d):
            let p = SnapGeometry.parallelProjection(from: from, cursor: cursor, refDir: d.direction)
            return p.valid ? p : nil
        default:
            return nil
        }
    }

    // MARK: - Distance-along-entity ("Snap distance" / equidistant)

    /// The equidistant points `1·spacing, 2·spacing, …` along `entity`, measured
    /// from the entity end nearest `near` (so the snap "starts counting" from the
    /// closest endpoint, matching LibreCAD's "Snap distance"). Defined analytically
    /// for line and arc; polylines walk their resolved chord path. Other kinds have
    /// no canonical "distance along" and return `[]`.
    ///
    /// - Parameters:
    ///   - entity:  the hovered entity.
    ///   - spacing: world-unit step between successive points (> 0).
    ///   - near:    the cursor — only used to pick which end is the reference end.
    ///   - ctx:     resolve context for polyline/curve chord points.
    static func distanceAlongPoints(of entity: EntityRecord, spacing: Double,
                                    near: Vector, ctx: ResolveContext) -> [Vector] {
        switch entity.kind {
        case .line(let d):
            let fromStart = (near - d.start).squared <= (near - d.end).squared
            return SnapGeometry.pointsAlongLine(start: d.start, end: d.end,
                                                spacing: spacing, fromStart: fromStart)

        case .arc(let d):
            let startPt = d.center + Vector.polar(radius: abs(d.radius), angle: d.startAngle)
            let endPt   = d.center + Vector.polar(radius: abs(d.radius), angle: d.endAngle)
            let fromStart = (near - startPt).squared <= (near - endPt).squared
            return SnapGeometry.pointsAlongArc(center: d.center, radius: d.radius,
                                               startAngle: d.startAngle, endAngle: d.endAngle,
                                               reversed: d.reversed,
                                               spacing: spacing, fromStart: fromStart)

        case .polyline:
            // Walk the resolved chord path (bulge arcs become chord points), so the
            // distance is along the drawn path. Pick the nearer overall end.
            let geo = entity.resolve(ctx)
            var out: [Vector] = []
            for pl in geo.polylines where pl.points.count >= 2 {
                let first = pl.points.first!, last = pl.points.last!
                let fromStart = (near - first).squared <= (near - last).squared
                out += SnapGeometry.pointsAlongPolyline(points: pl.points, closed: pl.closed,
                                                        spacing: spacing, fromStart: fromStart)
            }
            return out

        default:
            return []
        }
    }

    // MARK: - Manual (two-pick) intersection primitive

    /// The intersection point of two **user-picked** entities, returned even when
    /// the passive auto-intersection snap wouldn't surface it (LibreCAD
    /// `RS_ActionSnapIntersectionManual`). Reuses the same `Intersections` adapter
    /// as the auto snap, then — when several crossings exist — returns the one
    /// nearest `near` (the cursor / second pick); `near` invalid returns the first.
    /// Returns `.invalid` when the pair does not intersect.
    ///
    /// This is the engine primitive for the two-pick UI flow (arming the two picks
    /// is a later UI step); it is intentionally NOT part of the single-cursor
    /// `snap(...)` auto pipeline.
    static func manualIntersection(entityA: EntityRecord, entityB: EntityRecord,
                                   near: Vector = .invalid) -> Vector {
        let pts = intersections(entityA, entityB).filter(\.valid)
        guard !pts.isEmpty else { return .invalid }
        guard near.valid else { return pts[0] }
        return pts.min(by: { ($0 - near).squared < ($1 - near).squared }) ?? pts[0]
    }

    /// Rounds `point` to the nearest grid node at `spacing` (origin-anchored).
    static func snappedToGrid(_ point: Vector, spacing: Double) -> Vector {
        guard spacing > Tolerance.distance else { return point }
        let gx = (point.x / spacing).rounded(.toNearestOrAwayFromZero) * spacing
        let gy = (point.y / spacing).rounded(.toNearestOrAwayFromZero) * spacing
        return Vector(gx, gy, point.z)
    }

    // MARK: - Intersection between two entities (RS_Information adapter)

    /// The intersection points of two entities, adapting `EntityKind` → the
    /// primitive `Intersections` kernels. Only the analytic kinds (line / circle /
    /// arc / ellipse) participate; polyline/spline pairs fall back to their
    /// resolved-segment intersections so chained geometry still snaps. Returns the
    /// points (angle/segment-range-filtered by the kernels).
    static func intersections(_ a: EntityRecord, _ b: EntityRecord) -> [Vector] {
        if let analytic = analyticIntersections(a.kind, b.kind) {
            return analytic.points.filter(\.valid)
        }
        // At least one non-analytic kind → resolved-polyline segment crossings.
        return resolvedIntersections(a, b)
    }

    /// Intersections of two analytic kinds via the `Intersections` kernels, or
    /// `nil` if either kind isn't analytic (line/circle/arc/ellipse).
    static func analyticIntersections(_ ka: EntityKind, _ kb: EntityKind) -> VectorSolutions? {
        switch (ka, kb) {
        // line / line
        case let (.line(a), .line(b)):
            return Intersections.lineLine(a.start, a.end, b.start, b.end, segment: true)

        // line / circle
        case let (.line(a), .circle(c)):
            return Intersections.lineCircle(line: (a.start, a.end), center: c.center, radius: c.radius, segment: true)
        case let (.circle(c), .line(a)):
            return Intersections.lineCircle(line: (a.start, a.end), center: c.center, radius: c.radius, segment: true)

        // line / arc
        case let (.line(a), .arc(arc)):
            return Intersections.lineArc(line: (a.start, a.end), center: arc.center, radius: arc.radius,
                                         angle1: arc.startAngle, angle2: arc.endAngle, reversed: arc.reversed,
                                         fullCircle: false, segment: true)
        case let (.arc(arc), .line(a)):
            return Intersections.lineArc(line: (a.start, a.end), center: arc.center, radius: arc.radius,
                                         angle1: arc.startAngle, angle2: arc.endAngle, reversed: arc.reversed,
                                         fullCircle: false, segment: true)

        // line / ellipse
        case let (.line(a), .ellipse(e)):
            return filterEllipseSolutions(
                Intersections.lineEllipse(line: (a.start, a.end), center: e.center, majorP: e.majorP, ratio: e.ratio),
                ellipse: e, segment: (a.start, a.end))
        case let (.ellipse(e), .line(a)):
            return filterEllipseSolutions(
                Intersections.lineEllipse(line: (a.start, a.end), center: e.center, majorP: e.majorP, ratio: e.ratio),
                ellipse: e, segment: (a.start, a.end))

        // circle / circle
        case let (.circle(a), .circle(b)):
            return Intersections.circleCircle(center1: a.center, radius1: a.radius,
                                              center2: b.center, radius2: b.radius)

        // circle / arc
        case let (.circle(c), .arc(arc)):
            return Intersections.circleArc(circleCenter: c.center, circleRadius: c.radius,
                                           arcCenter: arc.center, arcRadius: arc.radius,
                                           arcAngle1: arc.startAngle, arcAngle2: arc.endAngle,
                                           arcReversed: arc.reversed)
        case let (.arc(arc), .circle(c)):
            return Intersections.circleArc(circleCenter: c.center, circleRadius: c.radius,
                                           arcCenter: arc.center, arcRadius: arc.radius,
                                           arcAngle1: arc.startAngle, arcAngle2: arc.endAngle,
                                           arcReversed: arc.reversed)

        // arc / arc
        case let (.arc(a), .arc(b)):
            return Intersections.arcArc(center1: a.center, radius1: a.radius,
                                        angle1Start: a.startAngle, angle1End: a.endAngle, reversed1: a.reversed,
                                        center2: b.center, radius2: b.radius,
                                        angle2Start: b.startAngle, angle2End: b.endAngle, reversed2: b.reversed)

        // circle / ellipse
        case let (.circle(c), .ellipse(e)):
            return filterEllipseSolutions(
                Intersections.circleEllipse(circleCenter: c.center, circleRadius: c.radius,
                                            center: e.center, majorP: e.majorP, ratio: e.ratio),
                ellipse: e, segment: nil)
        case let (.ellipse(e), .circle(c)):
            return filterEllipseSolutions(
                Intersections.circleEllipse(circleCenter: c.center, circleRadius: c.radius,
                                            center: e.center, majorP: e.majorP, ratio: e.ratio),
                ellipse: e, segment: nil)

        // arc / ellipse
        case let (.arc(arc), .ellipse(e)):
            return filterEllipseSolutions(
                Intersections.arcEllipse(arcCenter: arc.center, arcRadius: arc.radius,
                                         arcAngle1: arc.startAngle, arcAngle2: arc.endAngle, arcReversed: arc.reversed,
                                         center: e.center, majorP: e.majorP, ratio: e.ratio),
                ellipse: e, segment: nil)
        case let (.ellipse(e), .arc(arc)):
            return filterEllipseSolutions(
                Intersections.arcEllipse(arcCenter: arc.center, arcRadius: arc.radius,
                                         arcAngle1: arc.startAngle, arcAngle2: arc.endAngle, arcReversed: arc.reversed,
                                         center: e.center, majorP: e.majorP, ratio: e.ratio),
                ellipse: e, segment: nil)

        // ellipse / ellipse
        case let (.ellipse(a), .ellipse(b)):
            return filterEllipseSolutions(
                filterEllipseSolutions(
                    Intersections.ellipseEllipse(center1: a.center, majorP1: a.majorP, ratio1: a.ratio,
                                                 center2: b.center, majorP2: b.majorP, ratio2: b.ratio),
                    ellipse: a, segment: nil),
                ellipse: b, segment: nil)

        default:
            return nil
        }
    }

    /// Filters ellipse intersection solutions to the elliptic ARC's parametric
    /// sweep (the `lineEllipse`/`ellipseEllipse` kernels return points on the full
    /// conic; for an elliptic *arc* we discard points outside its sweep) and, when
    /// a finite line `segment` is given, to that segment.
    static func filterEllipseSolutions(_ sols: VectorSolutions,
                                       ellipse e: EllipseData,
                                       segment: (Vector, Vector)?) -> VectorSolutions {
        var out = VectorSolutions()
        out.tangent = sols.tangent
        for p in sols where p.valid {
            // Elliptic-arc sweep filter (whole ellipse passes everything).
            if e.isArc, !ellipseAngleSwept(p, ellipse: e) { continue }
            // Optional finite-segment filter.
            if let seg = segment {
                let d = seg.1 - seg.0
                let len2 = d.squared
                if len2 > Tolerance.distanceSquared {
                    let t = (p - seg.0).dot(d) / len2
                    if t < -1e-9 || t > 1 + 1e-9 { continue }
                }
            }
            out.append(p)
        }
        return out
    }

    /// Whether point `p` (assumed on the ellipse) lies within elliptic-arc `e`'s
    /// parametric sweep. Recovers the parametric angle from `p` by undoing the
    /// ellipse's rotation/scale, then uses the shared angle-between test.
    static func ellipseAngleSwept(_ p: Vector, ellipse e: EllipseData) -> Bool {
        let rel = (p - e.center).rotated(by: -e.rotationAngle)
        // Parametric angle a satisfies rel = (a_major·cos a, a_minor·sin a).
        let a = atan2(rel.y / Swift.max(e.minorRadius, Tolerance.distance),
                      rel.x / Swift.max(e.majorRadius, Tolerance.distance))
        return MathUtils.isAngleBetween(a, e.startAngle, e.endAngle, reversed: e.reversed)
    }

    /// Intersections between two entities via their resolved polylines (used when
    /// at least one is a polyline/spline). Tests every segment pair for a crossing
    /// and returns the crossing points (line-line kernel on each segment pair).
    static func resolvedIntersections(_ a: EntityRecord, _ b: EntityRecord,
                                      ctx: ResolveContext = .default) -> [Vector] {
        let ga = a.resolve(ctx)
        let gb = b.resolve(ctx)
        var out: [Vector] = []
        for pa in ga.polylines {
            let segsA = segments(of: pa)
            for pb in gb.polylines {
                let segsB = segments(of: pb)
                for sa in segsA {
                    for sb in segsB {
                        let sol = Intersections.lineLine(sa.0, sa.1, sb.0, sb.1, segment: true)
                        if let p = sol.first, p.valid { out.append(p) }
                    }
                }
            }
        }
        return out
    }

    /// The segment endpoint-pairs of a resolved polyline (incl. closing edge).
    private static func segments(of pl: ResolvedPolyline) -> [(Vector, Vector)] {
        let pts = pl.points
        guard pts.count >= 2 else { return [] }
        var segs: [(Vector, Vector)] = []
        for i in 0..<(pts.count - 1) { segs.append((pts[i], pts[i + 1])) }
        if pl.closed, pts.count >= 3 { segs.append((pts[pts.count - 1], pts[0])) }
        return segs
    }
}
