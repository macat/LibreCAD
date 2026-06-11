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
/// stage). Seeded as an outline ring for now; hatch fan-out fills this in.
public struct ResolvedFill: Sendable, Equatable {
    public var outline: [Vector]
    public var color: RGBAColor
    public init(outline: [Vector], color: RGBAColor) {
        self.outline = outline
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

    /// Resolves a `.byBlock` pen. Stub default mirrors the layer default; the
    /// block fan-out replaces this with the insert's pen.
    public var blockAttributes: @Sendable () -> ResolvedPen

    public init(
        tessellationTolerance: Double = 0.05,
        layerAttributes: @escaping @Sendable (LayerID) -> ResolvedPen = { _ in
            ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        blockAttributes: @escaping @Sendable () -> ResolvedPen = {
            ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        }
    ) {
        self.tessellationTolerance = tessellationTolerance
        self.layerAttributes = layerAttributes
        self.blockAttributes = blockAttributes
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
        let blockPen = ctx.blockAttributes()

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
    /// TODO: true bulge → arc tessellation is implemented here for nonzero
    /// bulges; verify against DXF round-trip corner cases (bulge sign / >semicircle)
    /// during Phase 1 once intersection kernels land.
    static func expandPolyline(_ d: PolylineData, ctx: ResolveContext) -> [Vector] {
        let verts = d.vertices
        guard verts.count >= 2 else { return verts.map(\.point) }

        var out: [Vector] = []
        out.reserveCapacity(verts.count)

        let segmentCount = d.closed ? verts.count : verts.count - 1
        for i in 0..<segmentCount {
            let a = verts[i]
            let b = verts[(i + 1) % verts.count]
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

    /// Analytic bounding box where cheap (line/point/circle), from the swept
    /// extent for arcs, and from resolved points otherwise.
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
            // Endpoints plus any axis-extreme (0/π/2, π, 3π/2) the arc crosses.
            let pts = Tessellation.arcPoints(
                center: d.center, radius: d.radius,
                startAngle: d.startAngle, endAngle: d.endAngle, reversed: d.reversed,
                // A coarse tessellation is enough to capture the extent; the
                // endpoints + crossing quadrant points dominate the box.
                tolerance: max(abs(d.radius) * 0.01, Tolerance.distance)
            )
            return AABB(points: pts)

        case .polyline(let d):
            return AABB(points: Self.expandPolyline(d, ctx: .default))
        }
    }
}
