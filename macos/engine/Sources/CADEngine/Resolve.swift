//
//  Resolve.swift
//  CADEngine
//
//  Computed geometry (ADR-001): entity defining data → renderable geometry,
//  produced on demand by `resolve()` and NEVER stored on the entity. World
//  coords, f64. Curves are tessellated with the sagitta criterion (chord error
//  bounded by `tessellationTolerance`), ported from LibreCAD's arc tessellation
//  approach in the painters / RS_Arc.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original arc/polyline math).
//

import Foundation

// MARK: - Resolved geometry (the renderer's input contract)

/// A resolved open/closed polyline in world coords (f64). The renderer uploads
/// these straight into vertex buffers (after the f64→f32 floating-origin
/// subtraction per ADR-003).
public struct ResolvedPolyline: Sendable, Equatable {
    public var points: [Vector]
    public var closed: Bool
    /// Pen with all `.byLayer`/`.byBlock` sentinels resolved to concrete values.
    public var pen: ResolvedPen
    public init(points: [Vector], closed: Bool, pen: ResolvedPen) {
        self.points = points
        self.closed = closed
        self.pen = pen
    }
}

/// A resolved filled region (triangulated by the renderer / later geometry
/// stage). Multi-loop from day one so the Hatch fan-out owner never has to
/// re-broadcast a contract change.
///
/// ## Loop contract (FROZEN — Hatch owner builds on this, do not diverge)
/// `loops[0]` is the **outer boundary**; `loops[1...]` are **holes** (islands)
/// cut out of it. Each loop is an ordered ring of world-coord points and does
/// NOT repeat its first vertex (the closing edge is implicit — same convention
/// as `circlePoints` / closed `ResolvedPolyline`).
///
/// **Winding:** outer boundary CCW, holes CW (the standard even-odd /
/// nonzero-fill convention the renderer's triangulator will assume). The Hatch
/// owner is the single authority on enforcing/normalizing winding when it
/// produces real boundaries; until then this is the documented target and
/// producers SHOULD emit in this order. (Winding-normalization helper TBD by
/// the Hatch owner.)
public struct ResolvedFill: Sendable, Equatable {
    /// Boundary + holes. `loops[0]` outer (CCW), `loops[1...]` holes (CW).
    public var loops: [[Vector]]
    public var color: RGBAColor

    /// The outer boundary loop, if any (`loops[0]`).
    public var outerLoop: [Vector]? { loops.first }

    public init(loops: [[Vector]], color: RGBAColor) {
        self.loops = loops
        self.color = color
    }

    /// Convenience for the common single-boundary (no holes) case.
    public init(outline: [Vector], color: RGBAColor) {
        self.loops = [outline]
        self.color = color
    }
}

/// Everything an entity contributes to the screen for one render pass.
public struct ResolvedGeometry: Sendable, Equatable {
    public var polylines: [ResolvedPolyline]
    public var fills: [ResolvedFill]
    public init(polylines: [ResolvedPolyline] = [], fills: [ResolvedFill] = []) {
        self.polylines = polylines
        self.fills = fills
    }

    /// Merges two resolved geometries (used when composing block contents).
    public func merged(with other: ResolvedGeometry) -> ResolvedGeometry {
        ResolvedGeometry(polylines: polylines + other.polylines, fills: fills + other.fills)
    }
}

// MARK: - Resolve context (style / tessellation hooks)

/// Inputs the `resolve()` step needs that are NOT part of the entity: how finely
/// to tessellate curves, and how to turn `.byLayer`/`.byBlock` pen sentinels
/// into concrete attributes.
///
/// The layer/block resolution hooks are deliberately simple closures so Phase 1
/// can back them with the real `LayerTable`/`BlockTable` without changing the
/// entity API.
public struct ResolveContext: Sendable {
    /// Maximum allowed chord (sagitta) error when tessellating curves, in world
    /// units. Smaller == more segments. f64 (ADR-003).
    public var tessellationTolerance: Double

    /// Resolves a `.byLayer` pen against the entity's layer, returning concrete
    /// attributes. Stub default returns LibreCAD-green solid default-width.
    public var layerAttributes: @Sendable (LayerID) -> ResolvedPen

    /// Resolves a `.byBlock` pen. Returns the **current insert's** pen so a
    /// block-nested entity's `.byBlock` attributes inherit from the Insert that
    /// placed it. The block (Insert) fan-out owner sets `currentBlockPen` during
    /// recursion and reads it back here; outside any Insert there is no block, so
    /// the default mirrors the layer default. Takes the current block context
    /// explicitly so nested-insert resolution is unambiguous.
    public var blockAttributes: @Sendable (ResolvedPen?) -> ResolvedPen

    /// The pen of the Insert currently being expanded, or `nil` at top level.
    /// The block/Insert fan-out owner sets this when recursing into block
    /// contents so nested entities' `.byBlock` sentinels resolve against the
    /// placing Insert's pen (ADR-001). It is threaded through `blockAttributes`.
    public var currentBlockPen: ResolvedPen? = nil

    // Reserved for additive extension by the single owners (do not diverge):
    // var dimStyleProvider: ((DimStyleID) -> ResolvedDimStyle)? = nil   // Dimension owner
    // var fontProvider: ((String) -> StrokeFont?)? = nil                // Text owner (.lff, ADR-004)

    public init(
        tessellationTolerance: Double = 0.05,
        layerAttributes: @escaping @Sendable (LayerID) -> ResolvedPen = { _ in
            ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        blockAttributes: @escaping @Sendable (ResolvedPen?) -> ResolvedPen = { currentBlockPen in
            currentBlockPen ?? ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        currentBlockPen: ResolvedPen? = nil
    ) {
        self.tessellationTolerance = tessellationTolerance
        self.layerAttributes = layerAttributes
        self.blockAttributes = blockAttributes
        self.currentBlockPen = currentBlockPen
    }

    /// A sensible default context for tests/previews.
    public static let `default` = ResolveContext()
}

// MARK: - Pen resolution

extension Pen {
    /// Resolves `.byLayer`/`.byBlock` sentinels into a concrete `ResolvedPen`
    /// using the context's layer/block hooks. Explicit attributes pass through.
    func resolved(layer: LayerID, in ctx: ResolveContext) -> ResolvedPen {
        let layerPen = ctx.layerAttributes(layer)
        let blockPen = ctx.blockAttributes(ctx.currentBlockPen)

        let color: RGBAColor
        switch lineColor {
        case .byLayer: color = layerPen.color
        case .byBlock: color = blockPen.color
        case .explicit(let c): color = c
        }

        let lt: PenLineType
        switch lineType {
        case .byLayer: lt = layerPen.lineType
        case .byBlock: lt = blockPen.lineType
        default: lt = lineType
        }

        let lw: PenLineWidth
        switch lineWidth {
        case .byLayer: lw = layerPen.lineWidth
        case .byBlock: lw = blockPen.lineWidth
        default: lw = lineWidth
        }

        return ResolvedPen(color: color, lineType: lt, lineWidth: lw)
    }
}

// MARK: - Curve tessellation (sagitta criterion)

enum Tessellation {
    /// Number of straight segments to approximate a circular arc of `radius`
    /// sweeping `sweep` radians within chord error `tolerance`.
    ///
    /// Sagitta criterion: for a segment subtending angle `θ`, the chord error
    /// (sagitta) is `r·(1 − cos(θ/2))`. Bounding that by `tolerance` and solving
    /// for the max allowed `θ` gives `θ_max = 2·acos(1 − tol/r)`; the segment
    /// count is `ceil(sweep / θ_max)`. Clamped to [1, 4096].
    ///
    /// TODO: zoom-bucketed LOD (ADR-003 / rendering-performance.md). Fixed-by-
    /// tolerance is correct for the foundation; the renderer will later pick the
    /// tolerance from the current zoom bucket so segment counts track screen px.
    static func segmentCount(radius: Double, sweep: Double, tolerance: Double) -> Int {
        let r = abs(radius)
        let s = abs(sweep)
        guard r > Tolerance.distance, s > Tolerance.angle, tolerance > 0 else { return 1 }
        // If tolerance >= r, a single chord is within error for any sweep < π.
        let ratio = 1.0 - tolerance / r
        guard ratio > -1.0 else { return 1 }
        guard ratio < 1.0 else {
            // tolerance is negligible vs radius → fall back to a fine default.
            return Swift.min(4096, Swift.max(1, Int((s / 0.05).rounded(.up))))
        }
        let thetaMax = 2.0 * acos(Swift.max(-1.0, ratio))
        guard thetaMax > Tolerance.angle else { return 4096 }
        let n = Int((s / thetaMax).rounded(.up))
        return Swift.min(4096, Swift.max(1, n))
    }

    /// Tessellates a circular arc (center, radius, [start,end] sweep, direction)
    /// into points, inclusive of both endpoints.
    static func arcPoints(
        center: Vector,
        radius: Double,
        startAngle: Double,
        endAngle: Double,
        reversed: Bool,
        tolerance: Double
    ) -> [Vector] {
        // Compute the signed sweep in the direction of travel.
        let twoPi = 2 * Double.pi
        var sweep: Double
        if reversed {
            sweep = startAngle - endAngle
        } else {
            sweep = endAngle - startAngle
        }
        // Normalize into (0, 2π]; a full circle (start == end) sweeps 2π.
        sweep = sweep.truncatingRemainder(dividingBy: twoPi)
        if sweep <= Tolerance.angle { sweep += twoPi }

        let n = segmentCount(radius: radius, sweep: sweep, tolerance: tolerance)
        let step = (reversed ? -sweep : sweep) / Double(n)

        var pts: [Vector] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let a = startAngle + step * Double(i)
            pts.append(center + Vector.polar(radius: radius, angle: a))
        }
        return pts
    }

    /// Tessellates an arc given a start angle and a SIGNED sweep (radians;
    /// positive == CCW, negative == CW), inclusive of both endpoints. Used by
    /// polyline bulge expansion where the direction is known exactly.
    static func arcPointsBySweep(
        center: Vector,
        radius: Double,
        startAngle: Double,
        sweep: Double,
        tolerance: Double
    ) -> [Vector] {
        let n = segmentCount(radius: radius, sweep: sweep, tolerance: tolerance)
        let step = sweep / Double(n)
        var pts: [Vector] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let a = startAngle + step * Double(i)
            pts.append(center + Vector.polar(radius: radius, angle: a))
        }
        return pts
    }

    /// Tessellates a full circle into a closed ring of points (not duplicating
    /// the closing point; `closed == true` carries that).
    static func circlePoints(center: Vector, radius: Double, tolerance: Double) -> [Vector] {
        let twoPi = 2 * Double.pi
        let n = Swift.max(3, segmentCount(radius: radius, sweep: twoPi, tolerance: tolerance))
        var pts: [Vector] = []
        pts.reserveCapacity(n)
        let step = twoPi / Double(n)
        for i in 0..<n {
            pts.append(center + Vector.polar(radius: radius, angle: step * Double(i)))
        }
        return pts
    }
}

// MARK: - resolve() — the computed-geometry entry point

extension EntityRecord {
    /// Produces this entity's renderable geometry in world coords. NEVER stored
    /// on the entity (ADR-001) — the caller owns caching by `id` + style/version.
    public func resolve(_ ctx: ResolveContext = .default) -> ResolvedGeometry {
        let pen = pen.resolved(layer: layer, in: ctx)
        return kind.resolve(pen: pen, ctx: ctx)
    }

    /// Analytic-where-cheap world-space bounding box (ADR-001 derived geometry).
    public func boundingBox() -> AABB {
        kind.boundingBox()
    }
}

extension EntityKind {
    /// Resolves geometry given an already-resolved pen and a context.
    public func resolve(pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        switch self {
        case .point(let d):
            // A point is a degenerate single-point polyline; the renderer draws
            // it as a marker. Carry it so the seam is exercised.
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: [d.position], closed: false, pen: pen)
            ])

        case .line(let d):
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: [d.start, d.end], closed: false, pen: pen)
            ])

        case .circle(let d):
            let pts = Tessellation.circlePoints(
                center: d.center, radius: d.radius, tolerance: ctx.tessellationTolerance
            )
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: pts, closed: true, pen: pen)
            ])

        case .arc(let d):
            let pts = Tessellation.arcPoints(
                center: d.center, radius: d.radius,
                startAngle: d.startAngle, endAngle: d.endAngle, reversed: d.reversed,
                tolerance: ctx.tessellationTolerance
            )
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: pts, closed: false, pen: pen)
            ])

        case .polyline(let d):
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: Self.expandPolyline(d, ctx: ctx), closed: d.closed, pen: pen)
            ])
        }
    }

    /// Expands a polyline's vertices into a flat point list, turning bulged
    /// segments into tessellated arc runs.
    ///
    /// ## Closed-polyline contract (matches `circlePoints` / `ResolvedFill`)
    /// When `d.closed == true` the closing edge (last vertex → first vertex) is
    /// **implicit**: the returned `points` do NOT repeat the first vertex. The
    /// renderer adds the single closing edge at draw time (it appends the first
    /// point for a `.lineStrip` of a closed shape). So a closed triangle
    /// `[A,B,C]` resolves to exactly `[A,B,C]` (count == 3, `first != last`),
    /// never `[A,B,C,A]`. Only the real inter-vertex segments are expanded here
    /// (`verts.count - 1` of them); the wrap segment is left to the renderer.
    ///
    /// TODO: true bulge → arc tessellation is implemented here for nonzero
    /// bulges; verify against DXF round-trip corner cases (bulge sign / >semicircle)
    /// during Phase 1 once intersection kernels land. A bulge on the *closing*
    /// edge of a closed polyline is not yet honored (that edge is implicit/
    /// straight); revisit with the Hatch/round-trip work.
    static func expandPolyline(_ d: PolylineData, ctx: ResolveContext) -> [Vector] {
        let verts = d.vertices
        guard verts.count >= 2 else { return verts.map(\.point) }

        var out: [Vector] = []
        out.reserveCapacity(verts.count)

        // Expand only the real inter-vertex segments. For a closed polyline the
        // closing edge is implicit (the renderer draws it) so we never append
        // the first vertex again — the data carries no duplicate wrap point.
        let segmentCount = verts.count - 1
        for i in 0..<segmentCount {
            let a = verts[i]
            let b = verts[i + 1]
            if i == 0 { out.append(a.point) }

            if abs(a.bulge) < Tolerance.distance {
                out.append(b.point)
            } else {
                // DXF bulge = tan(includedAngle / 4). Positive bulge ⇒ the arc
                // bulges to the LEFT of the directed chord a→b (CCW sweep);
                // negative ⇒ to the right (CW). We place the center on the side
                // opposite the apex by the apothem, then sweep the *signed*
                // included angle from the start radius (exact direction, no
                // ambiguous-quadrant normalization).
                let included = 4 * atan(a.bulge)   // signed; |θ| is the sweep magnitude
                let chord = b.point - a.point
                let chordLen = chord.magnitude
                if chordLen < Tolerance.distance { out.append(b.point); continue }
                let radius = abs(chordLen / (2 * sin(included / 2)))
                let mid = (a.point + b.point) * 0.5
                let half = chordLen / 2
                let apothem = sqrt(Swift.max(0, radius * radius - half * half)) // |center→chord|
                let dir = chord / chordLen
                // Left normal of the travel direction (apex side for bulge>0).
                let leftNormal = Vector(-dir.y, dir.x)
                // Center sits opposite the apex by the apothem. For a minor arc
                // (|θ|<π) it's on the far side of the chord from the apex; for a
                // major arc (|θ|>π) it crosses to the apex side. Derived/verified
                // empirically against DXF bulge semantics (apex bulges LEFT for
                // bulge>0). The traversal sweep that produces this left-bulging
                // point set is -θ.
                let apexSide = (a.bulge >= 0 ? 1.0 : -1.0)
                let centerSign = -copysign(1.0, cos(included / 2))  // -1 minor, +1 major
                let center = mid + leftNormal * (apexSide * centerSign * apothem)

                let startA = (a.point - center).angle
                let pts = Tessellation.arcPointsBySweep(
                    center: center, radius: radius,
                    startAngle: startA, sweep: -included,
                    tolerance: ctx.tessellationTolerance
                )
                // arcPointsBySweep includes both endpoints; skip the first.
                if pts.count > 1 { out.append(contentsOf: pts.dropFirst()) }
                else { out.append(b.point) }
            }
        }
        return out
    }

    /// Truly analytic AABB for a circular arc.
    ///
    /// The extent of an arc is reached only at its two **endpoints** or at the
    /// four axis-extreme angles {0, π/2, π, 3π/2} — and only at an extreme that
    /// the arc's sweep actually *crosses*. Tessellating and taking the sample
    /// AABB under-reports (a coarse arc that crosses 90° but has no vertex
    /// exactly at 90° misses maxY = center.y + r). We compute the exact box by
    /// unioning the endpoints with each crossed extreme.
    ///
    /// "Crossed" is decided the same way `arcPoints` decides travel: the signed
    /// sweep is taken in the `reversed` direction, normalized into (0, 2π] (a
    /// degenerate start==end arc sweeps the full circle). An extreme at angle
    /// `ext` is crossed iff the forward angular offset from `startAngle` to
    /// `ext`, measured in the direction of travel and normalized to [0, 2π),
    /// is `<= sweep`.
    static func arcBoundingBox(_ d: ArcData) -> AABB {
        let r = abs(d.radius)
        let c = d.center
        let twoPi = 2 * Double.pi

        // Endpoints (always part of the extent).
        let p0 = c + Vector.polar(radius: r, angle: d.startAngle)
        let p1 = c + Vector.polar(radius: r, angle: d.endAngle)
        var box = AABB(points: [p0, p1])

        // Signed sweep in the travel direction, normalized to (0, 2π] — mirrors
        // `Tessellation.arcPoints`.
        var sweep = d.reversed ? (d.startAngle - d.endAngle) : (d.endAngle - d.startAngle)
        sweep = sweep.truncatingRemainder(dividingBy: twoPi)
        if sweep <= Tolerance.angle { sweep += twoPi }

        // The four axis extremes and the point each contributes.
        let extremes: [(angle: Double, point: Vector)] = [
            (0,                Vector(c.x + r, c.y,     c.z)), // +X  (maxX)
            (Double.pi / 2,    Vector(c.x,     c.y + r, c.z)), // +Y  (maxY)
            (Double.pi,        Vector(c.x - r, c.y,     c.z)), // -X  (minX)
            (3 * Double.pi / 2, Vector(c.x,    c.y - r, c.z)), // -Y  (minY)
        ]
        for ext in extremes {
            // Forward angular offset from start to the extreme in the travel
            // direction, normalized to [0, 2π).
            var off = d.reversed ? (d.startAngle - ext.angle) : (ext.angle - d.startAngle)
            off = off.truncatingRemainder(dividingBy: twoPi)
            if off < 0 { off += twoPi }
            // Include the extreme iff the sweep reaches it (small angular slack
            // so endpoints exactly on an extreme are treated as crossed).
            if off <= sweep + Tolerance.angle {
                box.expand(toInclude: ext.point)
            }
        }
        return box
    }

    /// Analytic bounding box where cheap (line/point/circle), exact for arcs
    /// (endpoints + crossed axis extremes), and from resolved points otherwise.
    public func boundingBox() -> AABB {
        switch self {
        case .point(let d):
            return AABB(point: d.position)

        case .line(let d):
            return AABB(points: [d.start, d.end])

        case .circle(let d):
            let r = abs(d.radius)
            return AABB(
                min: Vector(d.center.x - r, d.center.y - r, d.center.z),
                max: Vector(d.center.x + r, d.center.y + r, d.center.z)
            )

        case .arc(let d):
            return Self.arcBoundingBox(d)

        case .polyline(let d):
            return AABB(points: Self.expandPolyline(d, ctx: .default))
        }
    }
}
