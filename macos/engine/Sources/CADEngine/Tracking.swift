//
//  Tracking.swift
//  CADEngine
//
//  The pure object-snap-tracking (OTRACK) geometry kernel — LibreCAD / AutoCAD
//  "object snap tracking": after the user ACQUIRES one or more snap points (an
//  endpoint, a center, a midpoint…), the tool radiates alignment GUIDES (rays)
//  from each acquired point — horizontal, vertical, and polar (k·increment) — and
//  optionally STRAIGHT EXTENSION guides along a hovered line. As the cursor moves,
//  the kernel RESOLVES the cursor against the live guides: if the cursor is near
//  TWO guides it locks onto their INTERSECTION; if near a single guide it locks
//  onto the orthogonal projection of the cursor onto that guide.
//
//  This mirrors `RS_Snapper`'s tracking restriction but, like the other snap
//  kernels (`SnapGeometry`, `PolarConstraint`, `Intersections`), it is expressed
//  as pure, stateless f64 functions over PRIMITIVE parameters (points/directions)
//  — never an entity enum, no NSView, no document — so it unit-tests in isolation.
//
//  Conventions match the rest of the engine:
//  - f64 throughout (ADR-003); all inputs/outputs are WORLD units.
//  - Angles are radians; directions are stored UNIT length.
//  - Reuses, READ-ONLY, the existing kernels:
//      `SnapGeometry.parallelProjection(from:cursor:refDir:)` — project cursor
//          onto the infinite line through a point along a direction (= project
//          onto a guide), and
//      `Intersections.lineLine(_:_:_:_:segment:)` — infinite-line crossing of two
//          guides (returns a `VectorSolutions`, possibly empty for parallel pairs).
//  - The acquired point CARRIES an existing `SnapKind` value — OTRACK adds no new
//    `SnapKind` / `EntityKind` / `ToolKind` case.
//
//  v1 SCOPE: `extensionGuide(...)` is STRAIGHT-LINE extension only (a ray that
//  continues a line past its endpoint). Apparent-intersection tracking and
//  arc-continuation / curved (tangential) extension are intentionally deferred to
//  a later wave and are NOT implemented here.
//
//  GPLv2-or-later (LibreCAD derivative). OTRACK semantics port RS_Snapper's
//  tracking restriction (librecad/src/lib/actions/rs_snapper.cpp).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper tracking restriction).
//
//  This program is free software; you can redistribute it and/or modify it under
//  the terms of the GNU General Public License version 2 or (at your option) any
//  later version.
//

import Foundation

// MARK: - Acquired point

/// A snap point the user has ACQUIRED for object-snap tracking. Guides radiate
/// from `point`; `kind` carries the existing `SnapKind` that produced it (e.g.
/// `.endpoint`, `.center`) so a UI can label the source, and `sourceEntity` is the
/// entity it came from (if any) so a guide can be attributed back to it.
public struct AcquiredPoint: Equatable {
    public let point: Vector
    public let kind: SnapKind
    public let sourceEntity: EntityID?

    public init(point: Vector, kind: SnapKind, sourceEntity: EntityID? = nil) {
        self.point = point
        self.kind = kind
        self.sourceEntity = sourceEntity
    }
}

// MARK: - Tracking guide

/// A single alignment guide: an infinite ray (`origin`, unit `direction`) the
/// cursor can lock onto. `kind` records why the guide exists so a UI can pick a
/// glyph / label; `sourceEntity` attributes it back to an acquired point's entity.
public struct TrackingGuide: Equatable {

    /// What produced the guide.
    public enum Kind: Equatable {
        /// Horizontal alignment (direction = (1, 0)).
        case horizontal
        /// Vertical alignment (direction = (0, 1)).
        case vertical
        /// Polar alignment at the carried angle (radians, in [0, 2π)).
        case polar(Double)
        /// Straight-line extension of a hovered line past its endpoint.
        case extension_
    }

    public let origin: Vector
    /// Unit direction of the ray.
    public let direction: Vector
    public let kind: Kind
    public let sourceEntity: EntityID?

    public init(origin: Vector, direction: Vector, kind: Kind, sourceEntity: EntityID? = nil) {
        self.origin = origin
        self.direction = direction
        self.kind = kind
        self.sourceEntity = sourceEntity
    }
}

// MARK: - Tracking result

/// The outcome of resolving the cursor against the live guides: the locked world
/// `point`, the guide(s) it locked to (one for a single-guide lock, two for an
/// intersection lock), and the `distance` / `angle` of `point` from the (first)
/// locked guide's origin.
public struct TrackingResult: Equatable {
    public let point: Vector
    public let lockedGuides: [TrackingGuide]
    public let distance: Double
    public let angle: Double

    public init(point: Vector, lockedGuides: [TrackingGuide], distance: Double, angle: Double) {
        self.point = point
        self.lockedGuides = lockedGuides
        self.distance = distance
        self.angle = angle
    }
}

// MARK: - OTRACK kernel

/// Namespaced static OTRACK kernel (per CONVENTIONS.md — no module-scope free
/// functions). All math is pure f64 over primitive parameters.
public enum Tracking {

    /// A hard cap on the number of polar rays generated per acquired point, so a
    /// tiny `polarIncrement` cannot produce an unbounded guide list (snapping must
    /// stay responsive — rendering-performance.md §5). `2π / increment` is clamped
    /// to this many distinct rays.
    public static let polarRayCap = 360

    // MARK: Guide generation

    /// The alignment guides radiating from a set of acquired points: for each
    /// acquired point a HORIZONTAL guide (direction (1, 0)), a VERTICAL guide
    /// (direction (0, 1)), and one POLAR guide per `k·polarIncrement` angle.
    ///
    /// Polar angles are enumerated `0, increment, 2·increment, …` over a full
    /// turn — the same nearest-multiple increment family as `PolarConstraint`,
    /// here ENUMERATED rather than rounded — and a guide is emitted as a directed
    /// ray (so 0 and π are distinct rays, like LibreCAD's directional tracking).
    ///
    /// Co-linear duplicates are removed PER acquired point: a polar angle that
    /// coincides with the horizontal (0 / π) or vertical (π/2 / 3π/2) ray is
    /// dropped so the same physical ray is not emitted twice. Guides from
    /// DIFFERENT acquired points are always kept (different origins → different
    /// guides whose intersection is the tracking lock).
    ///
    /// - Parameters:
    ///   - acquired: the acquired snap points to radiate from.
    ///   - polarIncrement: the angular step for polar rays (radians, e.g. `.pi/12`
    ///     for 15°). A non-positive / non-finite increment emits only H + V.
    /// - Returns: all guides, H + V first then polar, in acquisition order.
    public static func guides(from acquired: [AcquiredPoint], polarIncrement: Double) -> [TrackingGuide] {
        var out: [TrackingGuide] = []
        let hDir = Vector(1, 0)
        let vDir = Vector(0, 1)

        for ap in acquired where ap.point.valid {
            let origin = ap.point
            let src = ap.sourceEntity

            // Horizontal + vertical (always).
            out.append(TrackingGuide(origin: origin, direction: hDir, kind: .horizontal, sourceEntity: src))
            out.append(TrackingGuide(origin: origin, direction: vDir, kind: .vertical, sourceEntity: src))

            guard polarIncrement.isFinite, polarIncrement > 0 else { continue }

            // Number of distinct rays over a full turn, capped.
            let twoPi = 2.0 * Double.pi
            let rawCount = Int((twoPi / polarIncrement).rounded())
            let count = Swift.min(Swift.max(rawCount, 1), polarRayCap)
            for k in 0..<count {
                let ang = Vector.correctAngle(Double(k) * polarIncrement)
                // Drop polar rays co-linear with the H or V rays already emitted
                // (0 / π/2 / π / 3π/2 within angular tolerance).
                if isAxisAligned(ang) { continue }
                let dir = Vector(angle: ang)
                out.append(TrackingGuide(origin: origin, direction: dir, kind: .polar(ang), sourceEntity: src))
            }
        }
        return out
    }

    /// A STRAIGHT extension guide continuing a hovered line past `endpoint` along
    /// the line's direction. `carrierDir` is the line's raw direction (e.g.
    /// `end - start`); the guide's stored `direction` is its UNIT vector so the
    /// extension ray points away from the line's far end, past the endpoint.
    ///
    /// Returns a guide with `.invalid` origin/direction for a degenerate
    /// `carrierDir` (zero length) or an invalid endpoint — callers should skip a
    /// guide whose `direction` is invalid.
    ///
    /// v1: straight-line extension only (no arc / tangential continuation).
    public static func extensionGuide(endpoint: Vector, carrierDir: Vector, entity: EntityID?) -> TrackingGuide {
        guard endpoint.valid else {
            return TrackingGuide(origin: .invalid, direction: .invalid, kind: .extension_, sourceEntity: entity)
        }
        let len = carrierDir.magnitude
        guard len > Tolerance.distance else {
            return TrackingGuide(origin: endpoint, direction: .invalid, kind: .extension_, sourceEntity: entity)
        }
        let unit = carrierDir * (1.0 / len)
        return TrackingGuide(origin: endpoint, direction: unit, kind: .extension_, sourceEntity: entity)
    }

    // MARK: Resolve

    /// Resolves the cursor against the live `guides`.
    ///
    /// Precedence: INTERSECTION over SINGLE guide. If the cursor is within
    /// `worldTolerance` of TWO (or more) guides, the two nearest such guides are
    /// crossed (infinite-line intersection via `Intersections.lineLine(...,
    /// segment: false)`) and the cursor locks onto that intersection — PROVIDED
    /// the guides actually cross (parallel / co-linear guides yield an empty
    /// `VectorSolutions`, in which case we fall through to the single-guide lock).
    /// Otherwise, the cursor locks onto the orthogonal projection of the cursor
    /// onto the single nearest guide.
    ///
    /// `distance` / `angle` in the result are measured from the FIRST locked
    /// guide's origin to the locked point.
    ///
    /// - Returns: `nil` if no guide is within `worldTolerance` of the cursor.
    public static func resolve(guides: [TrackingGuide], cursor: Vector, worldTolerance: Double) -> TrackingResult? {
        guard cursor.valid, worldTolerance >= 0 else { return nil }

        // Project the cursor onto every (valid) guide and record the perpendicular
        // distance from the cursor to the guide.
        struct Hit {
            let guide: TrackingGuide
            let foot: Vector
            let perpDist: Double
        }
        var hits: [Hit] = []
        hits.reserveCapacity(guides.count)
        for g in guides where g.origin.valid && g.direction.valid {
            let foot = SnapGeometry.parallelProjection(from: g.origin, cursor: cursor, refDir: g.direction)
            guard foot.valid else { continue }
            let d = (cursor - foot).magnitude
            hits.append(Hit(guide: g, foot: foot, perpDist: d))
        }
        guard !hits.isEmpty else { return nil }

        // Keep only guides the cursor is actually near, nearest first.
        let near = hits.filter { $0.perpDist <= worldTolerance }
                       .sorted { $0.perpDist < $1.perpDist }
        guard !near.isEmpty else { return nil }

        // INTERSECTION lock: try the two nearest near-guides. Scan pairs in
        // nearest-first order until one pair actually crosses (non-empty
        // VectorSolutions); parallel/co-linear pairs are skipped.
        if near.count >= 2 {
            for i in 0..<(near.count - 1) {
                for j in (i + 1)..<near.count {
                    let gA = near[i].guide
                    let gB = near[j].guide
                    let sols = Intersections.lineLine(
                        gA.origin, gA.origin + gA.direction,
                        gB.origin, gB.origin + gB.direction,
                        segment: false)
                    // CRITICAL: lineLine returns a VectorSolutions, NOT an optional
                    // Vector. Take the FIRST solution and GUARD the empty case
                    // (parallel/degenerate guides → no intersection lock).
                    guard let hit = sols.first, hit.valid else { continue }
                    let dist = (hit - gA.origin).magnitude
                    let ang = (hit - gA.origin).angle
                    return TrackingResult(point: hit, lockedGuides: [gA, gB], distance: dist, angle: ang)
                }
            }
        }

        // SINGLE-guide lock: the projected point on the nearest guide.
        let best = near[0]
        let point = best.foot
        let dist = (point - best.guide.origin).magnitude
        let ang = (point - best.guide.origin).angle
        return TrackingResult(point: point, lockedGuides: [best.guide], distance: dist, angle: ang)
    }

    // MARK: - Helpers

    /// `true` if `angle` (already in [0, 2π)) coincides — within angular tolerance
    /// — with one of the four axis directions 0, π/2, π, 3π/2, so a polar ray at
    /// this angle would duplicate an already-emitted horizontal/vertical guide.
    private static func isAxisAligned(_ angle: Double) -> Bool {
        let halfPi = Double.pi / 2
        for k in 0..<4 {
            let axis = Double(k) * halfPi          // 0, π/2, π, 3π/2
            // Compare on the circle so 2π≈0 is handled.
            let diff = abs((angle - axis).remainder(dividingBy: 2.0 * Double.pi))
            if diff <= Tolerance.angle { return true }
        }
        return false
    }
}
