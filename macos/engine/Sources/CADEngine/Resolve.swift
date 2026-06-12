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

    /// Resolves a text style's font base name (e.g. `"standard"`) to a parsed
    /// `.lff` stroke font (ADR-004). The Text resolve arm calls this to lay out
    /// glyphs; `nil` (or a `nil` return) makes text resolve to empty geometry
    /// rather than crash. Wired by `CADDrawing.makeResolveContext` from a shared
    /// `StrokeFontProvider` (see `StrokeFontProvider.makeProvider()`).
    ///
    /// Reserved for additive extension by the other single owners (do not diverge):
    /// `// var dimStyleProvider: ((DimStyleID) -> ResolvedDimStyle)? = nil` — Dimension owner.
    /// NOTE (S1 `ws/dim-entity`): the `.dimension` resolve uses defining-data
    /// sizes (`DimData.textHeight`/`arrowSize`) and the existing `fontProvider`
    /// for its measurement text (ADR-004), so this hook stays RESERVED until a
    /// real DimStyle table lands (the dim-style fan-out wave wires it then).
    public var fontProvider: (@Sendable (String) -> StrokeFont?)? = nil

    public init(
        tessellationTolerance: Double = 0.05,
        layerAttributes: @escaping @Sendable (LayerID) -> ResolvedPen = { _ in
            ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        blockAttributes: @escaping @Sendable (ResolvedPen?) -> ResolvedPen = { currentBlockPen in
            currentBlockPen ?? ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        currentBlockPen: ResolvedPen? = nil,
        fontProvider: (@Sendable (String) -> StrokeFont?)? = nil
    ) {
        self.tessellationTolerance = tessellationTolerance
        self.layerAttributes = layerAttributes
        self.blockAttributes = blockAttributes
        self.currentBlockPen = currentBlockPen
        self.fontProvider = fontProvider
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

    /// Tessellates an ellipse (arc) by stepping the **parametric** ellipse angle
    /// and evaluating `EllipseData.ellipsePoint`.
    ///
    /// The sagitta segment count uses the **major** radius as a conservative
    /// upper bound on local curvature radius (the true chord error of an ellipse
    /// is bounded by that of the circumscribing circle), so the chord error stays
    /// within `tolerance` everywhere along the curve. The signed sweep is taken
    /// in the `reversed` direction and normalized into (0, 2π] exactly like
    /// `arcPoints`, so a degenerate `start == end` arc sweeps the whole ellipse.
    ///
    /// For a **full** ellipse (`!isArc`) returns a closed ring of `n` points NOT
    /// duplicating the first vertex (same convention as `circlePoints`). For an
    /// elliptic **arc** returns `n + 1` points inclusive of both endpoints.
    static func ellipsePoints(_ d: EllipseData, tolerance: Double) -> (points: [Vector], closed: Bool) {
        let twoPi = 2 * Double.pi

        guard d.isArc else {
            // Whole ellipse: closed ring, no duplicated closing vertex.
            let n = Swift.max(3, segmentCount(radius: d.majorRadius, sweep: twoPi, tolerance: tolerance))
            var pts: [Vector] = []
            pts.reserveCapacity(n)
            let step = twoPi / Double(n)
            for i in 0..<n {
                pts.append(d.ellipsePoint(step * Double(i)))
            }
            return (pts, true)
        }

        // Elliptic arc: signed sweep in travel direction, normalized to (0, 2π].
        var sweep = d.reversed ? (d.startAngle - d.endAngle) : (d.endAngle - d.startAngle)
        sweep = sweep.truncatingRemainder(dividingBy: twoPi)
        if sweep <= Tolerance.angle { sweep += twoPi }

        let n = segmentCount(radius: d.majorRadius, sweep: sweep, tolerance: tolerance)
        let step = (d.reversed ? -sweep : sweep) / Double(n)
        var pts: [Vector] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            pts.append(d.ellipsePoint(d.startAngle + step * Double(i)))
        }
        return (pts, false)
    }
}

// MARK: - NURBS / B-spline evaluation (de Boor / Piegl & Tiller)

/// B-spline / NURBS evaluation, ported from `RS_Spline` (`findSpan`,
/// `basisFunctions`, `evaluateNURBS`). Pure functions over `SplineData`.
///
/// Copyright (C) 2025 Dongxu Li; (C) 2001-2003 RibbonSoft — see Resolve.swift
/// header. GPLv2-or-later.
enum NURBS {

    /// Builds an evaluation-ready knot vector for `d`. If the spline already
    /// carries a valid-sized knot vector it is used as-is; otherwise a clamped
    /// (open) uniform vector is generated so the curve interpolates its
    /// endpoints (LibreCAD `LC_SplineHelper::knot`). Returns `nil` if the spline
    /// is degenerate (fewer than `degree + 1` control points).
    static func knotVector(for d: SplineData) -> [Double]? {
        let p = d.degree
        let nCtrl = d.controlPoints.count
        guard p >= 1, nCtrl >= p + 1 else { return nil }

        let order = p + 1
        let expected = nCtrl + order
        if d.knots.count == expected { return d.knots }

        // Generate a clamped knot vector (multiplicity `order` at both ends),
        // ported from LC_SplineHelper::knot(num, order).
        var kv = [Double](repeating: 0, count: nCtrl + order)
        let segments = nCtrl - p   // interior spans
        for i in 0..<segments {
            kv[order + i] = Double(i + 1)
        }
        // Trailing clamp value (max interior index).
        for i in (nCtrl + 1)..<kv.count {
            kv[i] = Double(segments)
        }
        return kv
    }

    /// `RS_Spline::findSpan` — the knot span index containing `u`
    /// (Piegl & Tiller A2.1), with the standard right-interval / endpoint clamp.
    static func findSpan(_ n: Int, _ p: Int, _ u: Double, _ U: [Double]) -> Int {
        if u >= U[n + 1] { return n }
        if u <= U[p] { return p }
        // Largest index i with U[i] <= u < U[i+1] (upper_bound − 1).
        var lo = p
        var hi = n + 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if U[mid] <= u { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// `RS_Spline::basisFunctions` — the `p + 1` non-zero basis functions at
    /// `u` in span `i` (Piegl & Tiller A2.2, the stable non-recursive form).
    static func basisFunctions(_ i: Int, _ u: Double, _ p: Int, _ U: [Double]) -> [Double] {
        var N = [Double](repeating: 0, count: p + 1)
        var left = [Double](repeating: 0, count: p + 1)
        var right = [Double](repeating: 0, count: p + 1)
        N[0] = 1
        guard p >= 1 else { return N }   // degree 0: single unit basis function
        for j in 1...p {
            left[j] = u - U[i + 1 - j]
            right[j] = U[i + j] - u
            var saved = 0.0
            for r in 0..<j {
                let denom = right[r + 1] + left[j - r]
                let alpha = denom != 0 ? N[r] / denom : 0
                N[r] = saved + right[r + 1] * alpha
                saved = left[j - r] * alpha
            }
            N[j] = saved
        }
        return N
    }

    /// `RS_Spline::evaluateNURBS` — the rational B-spline point at parameter `u`.
    static func evaluate(_ d: SplineData, knots U: [Double], at u: Double) -> Vector {
        let p = d.degree
        let n = d.controlPoints.count - 1
        guard n >= p else { return .invalid }
        let span = findSpan(n, p, u, U)
        let basis = basisFunctions(span, u, p, U)
        var pt = Vector(0, 0)
        var wsum = 0.0
        for i in 0...p {
            let idx = span - p + i
            let w = idx < d.weights.count ? d.weights[idx] : 1.0
            pt = pt + d.controlPoints[idx] * (basis[i] * w)
            wsum += basis[i] * w
        }
        return wsum > Tolerance.distance ? pt / wsum : pt
    }

    /// Tessellates the spline into a polyline over the curve's valid parameter
    /// domain `[U[p], U[count − p − 1]]` (LibreCAD `fillStrokePoints`).
    ///
    /// `segments` is the number of straight segments (LibreCAD uses a fixed 32);
    /// we scale that with the control-hull extent vs. `tolerance` so finer
    /// tolerances yield more segments, while keeping the fixed-N character.
    ///
    /// TODO: zoom-bucketed LOD — replace the heuristic segment count with a true
    /// adaptive (sagitta) subdivision keyed off the renderer's zoom bucket
    /// (ADR-003 / rendering-performance.md), matching the arc/circle path.
    static func tessellate(_ d: SplineData, tolerance: Double) -> [Vector]? {
        guard let U = knotVector(for: d) else { return nil }
        let p = d.degree
        let count = U.count
        guard count >= 2 * p + 2 else { return nil }
        let tmin = U[p]
        let tmax = U[count - p - 1]
        guard tmax > tmin else { return nil }

        let segments = segmentEstimate(controlPoints: d.controlPoints, tolerance: tolerance)
        let step = (tmax - tmin) / Double(segments)
        var pts: [Vector] = []
        pts.reserveCapacity(segments + 1)
        for i in 0...segments {
            // Clamp the last sample exactly to tmax to avoid FP drift past the
            // domain (which findSpan clamps anyway, but this keeps endpoints exact).
            let u = (i == segments) ? tmax : tmin + Double(i) * step
            let v = evaluate(d, knots: U, at: u)
            if v.valid { pts.append(v) }
        }
        return pts.count >= 2 ? pts : nil
    }

    /// Heuristic segment count for spline tessellation: a base of 32 (LibreCAD's
    /// `fillStrokePoints` default) refined by the control-hull diagonal vs. the
    /// chord tolerance, clamped to a sane range. Per-control-point density keeps
    /// many-point splines smooth.
    static func segmentEstimate(controlPoints: [Vector], tolerance: Double) -> Int {
        let base = 8 * Swift.max(1, controlPoints.count - 1)
        guard tolerance > 0, controlPoints.count >= 2 else {
            return Swift.min(2048, Swift.max(16, base))
        }
        let hull = AABB(points: controlPoints)
        let diag = hull.size.magnitude
        let byTol = Int((diag / Swift.max(tolerance, Tolerance.distance)).squareRoot().rounded(.up))
        return Swift.min(2048, Swift.max(16, Swift.max(base, byTol)))
    }
}

// MARK: - Quadratic-Bézier (interpolation) spline (LC_SplinePoints)

/// Quadratic-Bézier stroke evaluation, ported from `LC_SplinePoints`
/// (`GetQuadPoints`, `StrokeQuad`, `fillStrokePoints`, `GetQuadPoint`).
///
/// Copyright (C) 2014 Pavel Krejcir / Dongxu Li — GPLv2-or-later.
enum QuadSpline {

    /// `GetQuadPoint` — a point on the quadratic Bézier (x1, c1, x2) at `t`.
    static func point(_ x1: Vector, _ c1: Vector, _ x2: Vector, _ t: Double) -> Vector {
        let mt = 1.0 - t
        return x1 * (mt * mt) + c1 * (2.0 * t * mt) + x2 * (t * t)
    }

    /// `LC_SplinePoints::GetQuadPoints` — the (start, control, end) of Bézier
    /// segment `iSeg` (1-based), derived from the control polygon. Returns the
    /// number of meaningful points (0/1/2/3); a 3 means a real quadratic segment.
    static func quadPoints(
        _ cps: [Vector], closed: Bool, seg iSeg: Int
    ) -> (count: Int, start: Vector, control: Vector, end: Vector) {
        let n = cps.count
        var start = Vector.invalid
        var control = Vector.invalid
        var end = Vector.invalid

        if closed {
            guard n >= 3 else { return (0, start, control, end) }
            let i1 = (iSeg - 1 + n - 1) % n
            let i2 = iSeg - 1
            let i3 = (iSeg + 1 + n - 1) % n
            start = (cps[i1] + cps[i2]) / 2.0
            control = cps[i2]
            end = (cps[i2] + cps[i3]) / 2.0
            return (3, start, control, end)
        }

        guard iSeg >= 1, n >= 1 else { return (0, start, control, end) }
        start = cps[0]
        if n < 2 { return (1, start, control, end) }
        end = cps[1]
        if n < 3 { return (2, start, control, end) }
        control = end
        end = cps[2]
        if n < 4 { return (3, start, control, end) }

        let i1 = iSeg - 1
        let i2 = iSeg
        let i3 = iSeg + 1
        start = (i1 < 1) ? cps[0] : (cps[i1] + cps[i2]) / 2.0
        control = cps[i2]
        end = (i3 > n - 2) ? cps[n - 1] : (cps[i2] + cps[i3]) / 2.0
        return (3, start, control, end)
    }

    /// `LC_SplinePoints::fillStrokePoints` — the full polyline approximation.
    /// Returns the points and whether the result should be drawn closed.
    ///
    /// `segments` is the per-segment subdivision (LibreCAD's `$SPLINESEGS`,
    /// default 8). Open splines append the final segment endpoint; closed ones
    /// do NOT duplicate the first vertex (same convention as `circlePoints`).
    static func tessellate(_ d: SplinePointsData, tolerance: Double) -> (points: [Vector], closed: Bool)? {
        let cps = d.controlPoints
        guard cps.count >= 1 else { return nil }
        if cps.count == 1 { return ([cps[0]], false) }

        let segments = segmentEstimate(controlPoints: cps, tolerance: tolerance)
        var nSplines = cps.count
        if !d.closed { nSplines -= 2 }
        guard nSplines >= 1 else {
            // Too few points for a real segment: draw the control polygon.
            return (cps, d.closed)
        }

        var out: [Vector] = []
        var lastEnd = Vector.invalid
        for i in 1...nSplines {
            let q = quadPoints(cps, closed: d.closed, seg: i)
            lastEnd = q.end
            if q.count > 2 {
                // StrokeQuad: sample t in [0, 1) — the next segment contributes t=0.
                for s in 0..<segments {
                    let t = Double(s) / Double(segments)
                    out.append(point(q.start, q.control, q.end, t))
                }
            } else if q.count > 1 {
                out.append(q.start)
            }
        }
        if !d.closed, lastEnd.valid {
            out.append(lastEnd)
        }
        guard out.count >= 2 else { return (cps, d.closed) }
        return (out, d.closed)
    }

    /// Same per-curve segment heuristic as the NURBS path (kept consistent).
    static func segmentEstimate(controlPoints: [Vector], tolerance: Double) -> Int {
        NURBS.segmentEstimate(controlPoints: controlPoints, tolerance: tolerance) /
            Swift.max(1, controlPoints.count - 1) + 4
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

        case .ellipse(let d):
            // Full ellipse → closed ring; elliptic arc → open polyline. Respects
            // `reversed` via the signed sweep in `ellipsePoints`.
            let (pts, closed) = Tessellation.ellipsePoints(d, tolerance: ctx.tessellationTolerance)
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: pts, closed: closed, pen: pen)
            ])

        case .spline(let d):
            // NURBS evaluated over its valid parameter domain. A degenerate
            // spline (too few control points / bad knots) resolves to its control
            // polygon so it is at least visible (matches LibreCAD falling back to
            // an empty/degenerate update rather than crashing).
            if let pts = NURBS.tessellate(d, tolerance: ctx.tessellationTolerance) {
                return ResolvedGeometry(polylines: [
                    ResolvedPolyline(points: pts, closed: d.closed, pen: pen)
                ])
            }
            return ResolvedGeometry(polylines: [
                ResolvedPolyline(points: d.controlPoints, closed: d.closed, pen: pen)
            ])

        case .splinePoints(let d):
            if let (pts, closed) = QuadSpline.tessellate(d, tolerance: ctx.tessellationTolerance) {
                return ResolvedGeometry(polylines: [
                    ResolvedPolyline(points: pts, closed: closed, pen: pen)
                ])
            }
            return ResolvedGeometry()

        case .text(let d):
            // CAD text → stroked polylines via the .lff stroke font (ADR-004).
            // No font provider (or a missing font) ⇒ resolve to empty geometry
            // rather than crash; the renderer simply draws nothing for that text.
            let strokes = Self.layoutText(d, pen: pen, ctx: ctx)
            return ResolvedGeometry(polylines: strokes)

        case .hatch(let d):
            // Solid fill of the boundary loops. Pattern lines are backlog, so a
            // pattern hatch still fills its boundary for visibility. Bulged
            // boundary edges are treated as straight for now (the vertex point is
            // taken); boundary-arc tessellation is backlog.
            let loops = d.loops.map { ring in ring.map(\.point) }
            // Drop degenerate (<3 point) loops so the triangulator gets real rings.
            let valid = loops.filter { $0.count >= 3 }
            guard !valid.isEmpty else { return ResolvedGeometry() }
            return ResolvedGeometry(fills: [ResolvedFill(loops: valid, color: pen.color)])

        case .solid(let d):
            // A filled triangle/quad: a single fill loop of its corners.
            guard d.corners.count >= 3 else { return ResolvedGeometry() }
            return ResolvedGeometry(fills: [ResolvedFill(outline: d.corners, color: pen.color)])

        case .dimension(let d):
            // Associative dimension → extension lines + dimension line +
            // arrowheads (filled triangles) + measurement text (.lff strokes via
            // ctx.fontProvider, ADR-004). The measurement value is recomputed
            // from the geometry unless overridden. The renderer draws all of this
            // for free (it consumes ResolvedGeometry only).
            return Self.resolveDimension(d, pen: pen, ctx: ctx)
        }
    }

    // MARK: - Dimension resolve (RS_Dimension::update ported as a PURE function)

    /// The default measurement-text height when a dimension carries a
    /// non-positive `textHeight` (no dim style resolved yet).
    static let dimDefaultTextHeight = 2.5
    /// The default arrowhead length when a dimension carries a non-positive
    /// `arrowSize`.
    static let dimDefaultArrowSize = 2.5
    /// Half-width of an arrowhead triangle as a fraction of its length (a slim
    /// CAD arrowhead). LibreCAD's default arrow is ~1:3 wide:long.
    static let dimArrowHalfWidthFactor = 1.0 / 6.0
    /// Gap between an extension-line origin (the measured point) and where the
    /// drawn extension line starts, as a fraction of the arrow size (DIMEXO).
    static let dimExtensionOffsetFactor = 0.0
    /// How far an extension line runs past the dimension line, as a fraction of
    /// the arrow size (DIMEXE).
    static let dimExtensionBeyondFactor = 0.5

    /// Resolves a dimension's full graphic (ADR-001: PURE — no `clear()/addEntity`
    /// mutation, unlike `RS_Dimension::update`). Dispatches per variant; each
    /// helper emits the dimension line, extension lines, arrowheads, and the
    /// measurement text positioned on/above the dimension line.
    static func resolveDimension(_ d: DimData, pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        switch d.kind {
        case let .linear(e1, e2, angle):
            return dimLinearOrAligned(d, p1: e1, p2: e2, fixedAngle: angle, pen: pen, ctx: ctx)
        case let .aligned(e1, e2):
            // Aligned: the dimension-line direction is parallel to e1→e2.
            return dimLinearOrAligned(d, p1: e1, p2: e2, fixedAngle: nil, pen: pen, ctx: ctx)
        case let .radial(center, pointOnCircle):
            return dimRadial(d, center: center, pointOnCircle: pointOnCircle,
                             pen: pen, ctx: ctx)
        case let .diameter(p1, p2):
            return dimDiameter(d, point1: p1, point2: p2, pen: pen, ctx: ctx)
        case let .angular(l1s, l1e, l2s, l2e):
            return dimAngular(d, line1: (l1s, l1e), line2: (l2s, l2e), pen: pen, ctx: ctx)
        }
    }

    /// Effective measurement-text height (style → default fallback).
    static func dimTextHeight(_ d: DimData) -> Double {
        d.textHeight > 0 ? d.textHeight : dimDefaultTextHeight
    }

    /// Effective arrow size (style → default fallback).
    static func dimArrowSize(_ d: DimData) -> Double {
        d.arrowSize > 0 ? d.arrowSize : dimDefaultArrowSize
    }

    /// Formats a measured length/diameter/radius for the label (trims trailing
    /// zeros so "10.0" reads "10"; falls back to a short decimal otherwise).
    static func dimFormat(_ value: Double) -> String {
        let rounded = (value * 1e4).rounded() / 1e4
        if abs(rounded - rounded.rounded()) < 1e-9 {
            return String(Int(rounded.rounded()))
        }
        // Up to 4 decimals, trailing zeros stripped.
        var s = String(format: "%.4f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The label string for a dimension: the explicit override if present
    /// (a single space suppresses the text), else the computed measurement.
    static func dimLabel(_ d: DimData, measured: Double, suffix: String = "") -> String {
        if let override = d.textOverride {
            // A single space is the DXF convention for "suppress the text".
            if override == " " { return "" }
            if !override.isEmpty { return override }
        }
        return suffix + dimFormat(measured)
    }

    /// A filled arrowhead triangle (as a `ResolvedFill`) whose tip is at `tip`
    /// and whose body extends back along `direction` (a unit vector pointing FROM
    /// the tip back toward the dimension line) by `size`, with a half-width of
    /// `size * dimArrowHalfWidthFactor`.
    static func dimArrowhead(tip: Vector, direction unit: Vector, size: Double, color: RGBAColor) -> ResolvedFill {
        let back = tip + unit * size
        let halfWidth = size * dimArrowHalfWidthFactor
        let perpUnit = Vector(-unit.y, unit.x)
        let perp = perpUnit * halfWidth
        return ResolvedFill(outline: [tip, back + perp, back - perp], color: color)
    }

    /// Resolves the measurement label as a `.text` entity centered at `center` and
    /// rotated by `rotation` (radians), reusing the SAME text-resolution path as
    /// `.text` (`EntityKind.text(...).resolve`). Returns the text's full
    /// `ResolvedGeometry` — which is stroke polylines today, but will carry FILLS
    /// when the font provider serves outline glyphs (Core Text). Dimension text
    /// therefore introduces NO new text-rendering code path and is forward
    /// compatible. Returns empty geometry (no crash) when there is no provider /
    /// font or the label is empty.
    static func dimText(_ label: String, center: Vector, rotation: Double,
                        height: Double, pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard !label.isEmpty, height > 0 else { return ResolvedGeometry() }
        // Estimate the run width (em units → world) to center it, using the same
        // nominal advance the text-bbox estimate uses, then place the run so its
        // mid-width lands on `center`.
        let scale = height / lffCapHeight
        let nominalAdvance = 9.0
        let runWidth = Double(label.count) * nominalAdvance * scale
        // Position the baseline-left so the run is centered on `center` and lifted
        // half its cap height so the vertical middle sits on the line too.
        let halfW = runWidth / 2
        let halfH = height / 2
        // Unrotated offset from center to the text origin (baseline-left).
        let offset = Vector(-halfW, -halfH)
        let origin = center + (rotation != 0 ? offset.rotated(by: rotation) : offset)
        let data = TextData(position: origin, height: height, rotation: rotation,
                            text: label, styleName: nil)
        // Reuse the .text resolve arm so dimension text picks up strokes today and
        // outline-glyph fills later, with zero dimension-specific text code.
        return EntityKind.text(data).resolve(pen: pen, ctx: ctx)
    }

    /// Linear (fixed-angle) or aligned (angle = p1→p2 direction) dimension.
    static func dimLinearOrAligned(_ d: DimData, p1: Vector, p2: Vector, fixedAngle: Double?,
                                   pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard p1.valid, p2.valid, d.definitionPoint.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d)
        let textH = dimTextHeight(d)

        // Dimension-line direction (unit). Aligned: along p1→p2. Linear: the
        // fixed angle (the perpendicular distance between the points is measured
        // along this direction).
        let dirAngle = fixedAngle ?? (p2 - p1).angle
        let dirUnit = Vector(angle: dirAngle)
        let normal = Vector(-dirUnit.y, dirUnit.x)   // perpendicular to the dim line

        // The dimension line passes through definitionPoint, parallel to dirUnit.
        // Project each extension origin onto that line (slide along the normal).
        func ontoDimLine(_ p: Vector) -> Vector {
            // Offset from the dim line to p along the normal, removed.
            let delta = p - d.definitionPoint
            let alongNormal = delta.dot(normal)
            return p - normal * alongNormal
        }
        let dimP1 = ontoDimLine(p1)
        let dimP2 = ontoDimLine(p2)

        // Measured value: distance between the projected points (= component of
        // (p2 - p1) along dirUnit for linear; full distance for aligned).
        let measured = (dimP2 - dimP1).magnitude

        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []

        // Extension lines: from each measured point out to (slightly past) the
        // dimension line, in the direction from the measured point toward its
        // projection on the dim line.
        func extLine(_ measuredPt: Vector, _ dimPt: Vector) -> ResolvedPolyline {
            let toDim = dimPt - measuredPt
            let len = toDim.magnitude
            let u = len > Tolerance.distance ? toDim / len : normal
            let start = measuredPt + u * (arrow * dimExtensionOffsetFactor)
            let end = dimPt + u * (arrow * dimExtensionBeyondFactor)
            return ResolvedPolyline(points: [start, end], closed: false, pen: pen)
        }
        polylines.append(extLine(p1, dimP1))
        polylines.append(extLine(p2, dimP2))

        // Dimension line between the two projected points.
        polylines.append(ResolvedPolyline(points: [dimP1, dimP2], closed: false, pen: pen))

        // Arrowheads at each end, pointing OUTWARD (tips at dimP1/dimP2).
        if measured > Tolerance.distance {
            let along = (dimP2 - dimP1) / measured
            fills.append(dimArrowhead(tip: dimP1, direction: along, size: arrow, color: pen.color))
            fills.append(dimArrowhead(tip: dimP2, direction: -along, size: arrow, color: pen.color))
        }

        // Measurement text centered above the dimension line.
        let label = dimLabel(d, measured: measured)
        let textCenter = d.textMiddle.valid
            ? d.textMiddle
            : (dimP1 + dimP2) * 0.5 + normal * (textH * 0.7)
        // Keep text upright-ish: normalize the baseline angle to [-90°, 90°].
        let textAngle = dimTextAngle(dirAngle)
        let textGeo = dimText(label, center: textCenter, rotation: textAngle,
                              height: textH, pen: pen, ctx: ctx)

        return ResolvedGeometry(polylines: polylines, fills: fills).merged(with: textGeo)
    }

    /// Normalizes a dimension-line angle so the text reads roughly upright
    /// (DXF/CAD convention: text is never upside-down — angles in (90°, 270°)
    /// flip by π).
    static func dimTextAngle(_ angle: Double) -> Double {
        var a = Vector.correctAngle(angle)
        if a > Double.pi / 2 && a < 3 * Double.pi / 2 { a -= Double.pi }
        return a
    }

    /// Radial dimension: a leader from the point on the circle toward the center,
    /// an arrowhead at the circle, and the radius label.
    static func dimRadial(_ d: DimData, center: Vector, pointOnCircle: Vector,
                          pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard center.valid, pointOnCircle.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d)
        let textH = dimTextHeight(d)

        let radial = pointOnCircle - center
        let radius = radial.magnitude
        guard radius > Tolerance.distance else { return ResolvedGeometry() }
        let outward = radial / radius   // center → circle

        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []

        // Leader line from the center to the point on the circle.
        polylines.append(ResolvedPolyline(points: [center, pointOnCircle], closed: false, pen: pen))
        // Arrowhead at the circle, pointing outward (tip on the circle).
        fills.append(dimArrowhead(tip: pointOnCircle, direction: -outward, size: arrow, color: pen.color))

        // Label "R<radius>" near the mid-leader, baseline along the leader.
        let label = dimLabel(d, measured: radius, suffix: "R")
        let normal = Vector(-outward.y, outward.x)
        let textCenter = d.textMiddle.valid
            ? d.textMiddle
            : center + outward * (radius * 0.5) + normal * (textH * 0.7)
        let textAngle = dimTextAngle(outward.angle)
        let textGeo = dimText(label, center: textCenter, rotation: textAngle,
                              height: textH, pen: pen, ctx: ctx)

        return ResolvedGeometry(polylines: polylines, fills: fills).merged(with: textGeo)
    }

    /// Diameter dimension: a line across the circle through both points, an
    /// arrowhead at each end, and the diameter label.
    static func dimDiameter(_ d: DimData, point1: Vector, point2: Vector,
                            pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard point1.valid, point2.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d)
        let textH = dimTextHeight(d)

        let across = point2 - point1
        let diameter = across.magnitude
        guard diameter > Tolerance.distance else { return ResolvedGeometry() }
        let along = across / diameter

        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []

        // The diameter line and an arrowhead at each end (tips at the points).
        polylines.append(ResolvedPolyline(points: [point1, point2], closed: false, pen: pen))
        fills.append(dimArrowhead(tip: point1, direction: along, size: arrow, color: pen.color))
        fills.append(dimArrowhead(tip: point2, direction: -along, size: arrow, color: pen.color))

        // Label "⌀<diameter>" centered above the diameter line.
        let label = dimLabel(d, measured: diameter, suffix: "\u{2300}")
        let normal = Vector(-along.y, along.x)
        let textCenter = d.textMiddle.valid
            ? d.textMiddle
            : (point1 + point2) * 0.5 + normal * (textH * 0.7)
        let textAngle = dimTextAngle(along.angle)
        let textGeo = dimText(label, center: textCenter, rotation: textAngle,
                              height: textH, pen: pen, ctx: ctx)

        return ResolvedGeometry(polylines: polylines, fills: fills).merged(with: textGeo)
    }

    /// Angular dimension: an arc between the two lines (through definitionPoint),
    /// extension lines out to the arc ends, arrowheads, and the angle label.
    static func dimAngular(_ d: DimData, line1: (Vector, Vector), line2: (Vector, Vector),
                           pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard line1.0.valid, line1.1.valid, line2.0.valid, line2.1.valid,
              d.definitionPoint.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d)
        let textH = dimTextHeight(d)

        // Vertex = intersection of the two lines (fall back to the midpoint of the
        // inner endpoints if the lines are parallel).
        let vertex = lineLineIntersection(line1, line2)
            ?? (line1.1 + line2.1) * 0.5

        let a1 = (line1.1 - vertex).angle
        let a2 = (line2.1 - vertex).angle
        // Sweep from a1 to a2 (CCW), normalized to (0, 2π).
        var sweep = Vector.correctAngle(a2 - a1)
        if sweep < Tolerance.angle { sweep = 2 * Double.pi }

        // Arc radius = distance from the vertex to the definition point.
        let radius = (d.definitionPoint - vertex).magnitude
        guard radius > Tolerance.distance else { return ResolvedGeometry() }

        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []

        // The dimension arc (vertex-centered, from a1 sweeping CCW to a2).
        let arcPts = Tessellation.arcPointsBySweep(
            center: vertex, radius: radius, startAngle: a1, sweep: sweep,
            tolerance: ctx.tessellationTolerance)
        polylines.append(ResolvedPolyline(points: arcPts, closed: false, pen: pen))

        // Extension lines from each line's far endpoint to the arc ends.
        let arcStart = vertex + Vector.polar(radius: radius, angle: a1)
        let arcEnd = vertex + Vector.polar(radius: radius, angle: a2)
        polylines.append(ResolvedPolyline(points: [line1.1, arcStart], closed: false, pen: pen))
        polylines.append(ResolvedPolyline(points: [line2.1, arcEnd], closed: false, pen: pen))

        // Arrowheads tangent to the arc at each end (pointing along the sweep).
        let tan1 = Vector(angle: a1 + Double.pi / 2)        // CCW tangent at start
        let tan2 = Vector(angle: a2 + Double.pi / 2)
        fills.append(dimArrowhead(tip: arcStart, direction: -tan1, size: arrow, color: pen.color))
        fills.append(dimArrowhead(tip: arcEnd, direction: tan2, size: arrow, color: pen.color))

        // Angle label (degrees) at the arc midpoint.
        let degrees = sweep * 180 / Double.pi
        let label = dimLabel(d, measured: degrees, suffix: "") + "\u{00B0}"
        let midA = a1 + sweep / 2
        let textCenter = d.textMiddle.valid
            ? d.textMiddle
            : vertex + Vector.polar(radius: radius + textH * 0.7, angle: midA)
        let textAngle = dimTextAngle(midA + Double.pi / 2)
        let textGeo = dimText(label, center: textCenter, rotation: textAngle,
                              height: textH, pen: pen, ctx: ctx)

        return ResolvedGeometry(polylines: polylines, fills: fills).merged(with: textGeo)
    }

    /// Intersection of two infinite lines, or `nil` if parallel.
    static func lineLineIntersection(_ l1: (Vector, Vector), _ l2: (Vector, Vector)) -> Vector? {
        let p = l1.0, r = l1.1 - l1.0
        let q = l2.0, s = l2.1 - l2.0
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > Tolerance.distance else { return nil }
        let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / denom
        return p + r * t
    }

    // MARK: - Text layout (.lff stroked text, ADR-004)

    /// Nominal cap height of the LibreCAD `.lff` em space (ISO 3098 fonts use a
    /// ~9-unit cap height). DXF text `height` is the cap height in world units,
    /// so glyph em coords are scaled by `height / lffCapHeight`.
    static let lffCapHeight = 9.0

    /// Lays out a text string into world-space stroked polylines using the
    /// context's `.lff` font provider (ADR-004).
    ///
    /// ## Layout
    /// Glyphs are placed left-to-right along the baseline starting at
    /// `data.position`. Each glyph's em strokes are scaled by
    /// `height / lffCapHeight`, then the running pen advance is added and the
    /// whole run is rotated by `data.rotation` about `position`. Per-glyph
    /// advance is the glyph's em width plus the font's `letterSpacing` (× the
    /// data's `letterSpacingFactor`); a space (or a missing glyph) advances by
    /// the font's `wordSpacing`. A missing glyph falls back to the font's U+FFFD
    /// replacement glyph; if even that is absent the character is skipped (only
    /// advancing the pen) — never a crash.
    ///
    /// ## Deferred (backlog)
    /// `hAlign`/`vAlign` beyond the default left/baseline, multi-line `\n`
    /// handling, and oblique/width-factor are NOT applied here — the fields are
    /// carried on `TextData` for round-trip and a follow-up layout pass. Returns
    /// `[]` (empty, no crash) when there is no font provider, the font can't be
    /// loaded, or the string is empty.
    static func layoutText(_ data: TextData, pen: ResolvedPen, ctx: ResolveContext) -> [ResolvedPolyline] {
        guard !data.text.isEmpty, data.height > 0 else { return [] }
        guard let provider = ctx.fontProvider else { return [] }
        // An explicit style name, else the provider's default (empty key).
        guard let font = provider(data.styleName ?? "") else { return [] }

        let scale = data.height / lffCapHeight
        let advanceSpacing = font.letterSpacing * data.letterSpacingFactor
        let rotation = data.rotation
        let origin = data.position

        var out: [ResolvedPolyline] = []
        var penX = 0.0   // running em-space x advance along the (unrotated) baseline

        for ch in data.text {
            if ch == " " {
                penX += font.wordSpacing
                continue
            }

            // Resolve the glyph (or the replacement glyph for a missing one).
            let glyph = font.glyph(for: ch) ?? font.replacementGlyph
            guard let glyph, !glyph.isEmpty else {
                // No drawable glyph at all: advance a word space so following
                // text doesn't pile up, then move on (graceful, no crash).
                penX += font.wordSpacing
                continue
            }

            // Emit each stroke, transformed em→world: translate by the pen x,
            // scale by `scale`, rotate by `rotation`, then offset by `origin`.
            for stroke in glyph.strokes where stroke.count >= 2 {
                var pts: [Vector] = []
                pts.reserveCapacity(stroke.count)
                for p in stroke {
                    // em-space placement along the baseline, then world scale.
                    let placed = Vector((p.x + penX) * scale, p.y * scale)
                    let rotated = rotation != 0 ? placed.rotated(by: rotation) : placed
                    pts.append(origin + rotated)
                }
                out.append(ResolvedPolyline(points: pts, closed: false, pen: pen))
            }

            // Advance the pen by the glyph's em width + letter spacing. The em
            // width is the glyph's right extent (so spacing is measured from the
            // ink, matching LibreCAD's per-glyph advance from glyph bounds).
            let glyphWidth = glyph.bounds().map(\.max.x) ?? 0
            penX += glyphWidth + advanceSpacing
        }
        return out
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

    /// Truly analytic AABB for an ellipse / elliptic arc, ported from
    /// `RS_Ellipse::calculateBorders` + `mergeBoundingBox`.
    ///
    /// The axis-aligned extent of a *rotated* ellipse is reached at the four
    /// **parametric** angles whose tangent is horizontal/vertical — found by
    /// LibreCAD as the parametric angle of the directions
    /// `vpx = (majorP.x, −ratio·majorP.y)` (x-extremes) and
    /// `vpy = (majorP.y,  ratio·majorP.x)` (y-extremes), plus the opposite of
    /// each. For a **whole** ellipse all four are included (giving the classic
    /// `sqrt((a·cosθ)² + (b·sinθ)²)` extent); for an **arc** the box seeds with
    /// the two endpoints and an extreme is merged only if its parametric angle is
    /// swept (the same `isAngleBetween` test used for the arc bbox).
    static func ellipseBoundingBox(_ d: EllipseData) -> AABB {
        var box = d.isArc
            ? AABB(points: [d.ellipsePoint(d.startAngle), d.ellipsePoint(d.endAngle)])
            : .empty

        // The two extreme directions (their `.angle` is the parametric angle at
        // which x resp. y is extremal). Mirrors RS_Ellipse::calculateBorders.
        let vpx = Vector(d.majorP.x, -d.ratio * d.majorP.y)
        let vpy = Vector(d.majorP.y, d.ratio * d.majorP.x)

        func mergeExtremes(_ direction: Vector) {
            let base = direction.angle
            for a in [base, base + Double.pi] {
                if !d.isArc || Self.isParametricAngleSwept(a, d) {
                    box.expand(toInclude: d.ellipsePoint(a))
                }
            }
        }
        mergeExtremes(vpx)
        mergeExtremes(vpy)
        return box
    }

    /// Whether parametric ellipse angle `a` lies within the arc's sweep, ported
    /// from `RS_Math::isAngleBetween(a, angle1, angle2, reversed)`.
    static func isParametricAngleSwept(_ a: Double, _ d: EllipseData) -> Bool {
        var a1 = d.startAngle
        var a2 = d.endAngle
        if d.reversed { swap(&a1, &a2) }
        // Full sweep (a2 ≈ a1 going forward) ⇒ everything is "between".
        if Self.unsignedAngleDiff(a2, a1) < Tolerance.angle { return true }
        let tol = 0.5 * Tolerance.angle
        let diff0 = Vector.correctAngle(a2 - a1) + tol
        return diff0 >= Vector.correctAngle(a - a1) || diff0 >= Vector.correctAngle(a2 - a)
    }

    /// `RS_Math::correctAngle0ToPi(a1 − a2)` — unsigned angular difference in [0, π].
    static func unsignedAngleDiff(_ a1: Double, _ a2: Double) -> Double {
        abs((a1 - a2).remainder(dividingBy: 2 * Double.pi))
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

        case .ellipse(let d):
            // Analytic (endpoints + swept parametric extremes).
            return Self.ellipseBoundingBox(d)

        case .spline(let d):
            // Conservative AABB from the control-point convex hull. A B-spline is
            // contained in the convex hull of its control polygon, so the hull box
            // is a guaranteed (if loose) bound — and it's what LibreCAD's
            // RS_Spline::calculateBorders uses. (Tight extrema-based borders are a
            // later refinement; see RS_Spline::calculateTightBorders.)
            return AABB(points: d.controlPoints)

        case .splinePoints(let d):
            // Quadratic Béziers are contained in their control hull too; the
            // control-point box is conservative and cheap (LibreCAD computes the
            // tighter per-segment quad extent — a later refinement).
            return AABB(points: d.controlPoints)

        case .text(let d):
            return Self.textBoundingBox(d)

        case .hatch(let d):
            // Union of every boundary loop's vertices (bulge-arc bow is ignored —
            // boundary-arc tessellation is backlog; the vertex hull is a cheap
            // conservative box that contains the straight-edge fill we render).
            return AABB(points: d.loops.flatMap { $0.map(\.point) })

        case .solid(let d):
            return AABB(points: d.corners)

        case .dimension(let d):
            return Self.dimensionBoundingBox(d)
        }
    }

    /// Bounding box for a dimension, derived from its RESOLVED geometry (ADR-001:
    /// the box is computed from `resolve()`, not a stroke-specific path). The
    /// `boundingBox()` path has no `ResolveContext` (so no font provider), so the
    /// graphic parts (extension lines, dimension line / leader / arc, arrowheads)
    /// are resolved with the default context and unioned; the measurement text —
    /// which would need a provider — is added as an estimated band so the box
    /// still encloses where the label will draw (matching `textBoundingBox`). This
    /// stays correct whether the provider later emits stroke polylines or outline
    /// fills, because both contribute through the same resolved geometry.
    static func dimensionBoundingBox(_ d: DimData) -> AABB {
        // Resolve the geometric graphic with the default (font-less) context: text
        // resolves to nothing, but every line / arc / arrowhead is present.
        let geo = EntityKind.dimension(d).resolve(pen:
            ResolvedPen(color: .black, lineType: .solid, lineWidth: .default), ctx: .default)
        var box = AABB.empty
        for pl in geo.polylines { for p in pl.points { box.expand(toInclude: p) } }
        for fill in geo.fills { for loop in fill.loops { for p in loop { box.expand(toInclude: p) } } }

        // Add an estimated text band around the label's center so the box covers
        // the measurement text even without a font provider here.
        let measured = dimMeasuredValue(d)
        let label = dimLabel(d, measured: measured.value, suffix: measured.suffix)
        if !label.isEmpty {
            let h = dimTextHeight(d)
            let center = dimTextCenter(d)
            if center.valid {
                let textBox = textBoundingBox(TextData(
                    position: center, height: h, rotation: 0, text: label))
                // The text-box is anchored at `position`; shift it so `center` is
                // its middle (matching how dimText centers the run).
                let shift = (textBox.min + textBox.max) * 0.5 - center
                box = box.union(AABB(
                    min: textBox.min - shift, max: textBox.max - shift))
            }
        }
        if box.isEmpty {
            // Degenerate dim (e.g. coincident points): collapse to the def point.
            return AABB(point: d.definitionPoint.valid ? d.definitionPoint : Vector(0, 0))
        }
        return box
    }

    /// The measured value + label suffix for a dimension, recomputed from
    /// geometry (matches `resolveDimension`'s per-variant measurement).
    static func dimMeasuredValue(_ d: DimData) -> (value: Double, suffix: String) {
        switch d.kind {
        case let .linear(e1, e2, angle):
            let u = Vector(angle: angle)
            return (abs((e2 - e1).dot(u)), "")
        case let .aligned(e1, e2):
            return ((e2 - e1).magnitude, "")
        case let .radial(center, pointOnCircle):
            return ((pointOnCircle - center).magnitude, "R")
        case let .diameter(p1, p2):
            return ((p2 - p1).magnitude, "\u{2300}")
        case let .angular(l1s, l1e, l2s, l2e):
            let vertex = lineLineIntersection((l1s, l1e), (l2s, l2e)) ?? (l1e + l2e) * 0.5
            var sweep = Vector.correctAngle((l2e - vertex).angle - (l1e - vertex).angle)
            if sweep < Tolerance.angle { sweep = 2 * Double.pi }
            return (sweep * 180 / Double.pi, "")
        }
    }

    /// The default text center for a dimension (used by the bbox estimate; mirrors
    /// `resolveDimension`'s text placement, honoring `textMiddle` overrides).
    static func dimTextCenter(_ d: DimData) -> Vector {
        if d.textMiddle.valid { return d.textMiddle }
        let h = dimTextHeight(d)
        switch d.kind {
        case let .linear(e1, e2, angle):
            let dirUnit = Vector(angle: angle)
            let normal = Vector(-dirUnit.y, dirUnit.x)
            func ontoDimLine(_ p: Vector) -> Vector {
                p - normal * (p - d.definitionPoint).dot(normal)
            }
            return (ontoDimLine(e1) + ontoDimLine(e2)) * 0.5 + normal * (h * 0.7)
        case let .aligned(e1, e2):
            let dirUnit = Vector(angle: (e2 - e1).angle)
            let normal = Vector(-dirUnit.y, dirUnit.x)
            func ontoDimLine(_ p: Vector) -> Vector {
                p - normal * (p - d.definitionPoint).dot(normal)
            }
            return (ontoDimLine(e1) + ontoDimLine(e2)) * 0.5 + normal * (h * 0.7)
        case let .radial(center, pointOnCircle):
            let radial = pointOnCircle - center
            let r = radial.magnitude
            guard r > Tolerance.distance else { return center }
            let outward = radial / r
            let normal = Vector(-outward.y, outward.x)
            return center + outward * (r * 0.5) + normal * (h * 0.7)
        case let .diameter(p1, p2):
            let across = p2 - p1
            let len = across.magnitude
            guard len > Tolerance.distance else { return (p1 + p2) * 0.5 }
            let along = across / len
            let normal = Vector(-along.y, along.x)
            return (p1 + p2) * 0.5 + normal * (h * 0.7)
        case let .angular(l1s, l1e, l2s, l2e):
            let vertex = lineLineIntersection((l1s, l1e), (l2s, l2e)) ?? (l1e + l2e) * 0.5
            let a1 = (l1e - vertex).angle
            let a2 = (l2e - vertex).angle
            var sweep = Vector.correctAngle(a2 - a1)
            if sweep < Tolerance.angle { sweep = 2 * Double.pi }
            let radius = (d.definitionPoint - vertex).magnitude
            return vertex + Vector.polar(radius: radius + h * 0.7, angle: a1 + sweep / 2)
        }
    }

    /// Conservative world-space bounding box for single-line text.
    ///
    /// `boundingBox()` has no `ResolveContext` (so no font provider), so the box
    /// can't be the exact stroke hull. We estimate it from the text metrics: the
    /// baseline run from `position`, a width of `text.count` × a nominal advance
    /// (em width ~6 + letter spacing ~3, scaled by `height / lffCapHeight`), and
    /// a vertical band from the descender to the cap height. The estimate is
    /// rotated by `rotation` about `position`. This is a *sane*, slightly loose
    /// box (enough for culling/framing); a font-aware tight box is a backlog
    /// refinement once a ctx-carrying bbox path exists.
    static func textBoundingBox(_ d: TextData) -> AABB {
        guard !d.text.isEmpty, d.height > 0 else { return AABB(point: d.position) }
        let scale = d.height / lffCapHeight
        // Nominal per-glyph advance in em units (ISO glyph ~6 wide + ~3 spacing).
        let nominalAdvance = 9.0
        let width = Double(d.text.count) * nominalAdvance * scale
        // Vertical band: descenders ~ -3 em, ascenders/cap ~ 9 em + accents ~13.
        let descender = -3.0 * scale
        let ascender = 13.0 * scale

        // The four (unrotated) corners of the text band, relative to position.
        let corners = [
            Vector(0, descender),
            Vector(width, descender),
            Vector(width, ascender),
            Vector(0, ascender),
        ]
        var box = AABB.empty
        for c in corners {
            let rotated = d.rotation != 0 ? c.rotated(by: d.rotation) : c
            box.expand(toInclude: d.position + rotated)
        }
        return box
    }
}
