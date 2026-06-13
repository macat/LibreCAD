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

// MARK: - Document dimension style (the resolved dim defaults)

/// The document-default dimension style (decision D4) — the values a dimension
/// falls back to when it carries no explicit per-entity override. Supplied to the
/// resolve step via `ResolveContext.dimStyleProvider`, wired by
/// `CADDrawing.makeResolveContext` from the drawing's `$DIMTXT`/`$DIMASZ`/
/// `$DIMSCALE`/`$DIMLUNIT`/`$DIMDEC` header vars (the Document Settings sheet
/// writes those).
///
/// ## Precedence (D4: per-entity wins; document default fills in)
/// A dimension's resolve consults this ONLY when the per-entity value is
/// non-positive (`<= 0`, the "inherit" sentinel). So a dimension authored with a
/// real text height keeps it; one born with `0` picks up `textHeight` here. The
/// `scale` multiplies the effective text height + arrow size at draw time
/// (`$DIMSCALE`), and `linearFormat`/`linearPrecision` format the measurement text.
public struct ResolvedDimStyle: Sendable, Hashable, Codable {
    /// Document-default measurement-text cap height (world units, `$DIMTXT`).
    public var textHeight: Double
    /// Document-default arrowhead length (world units, `$DIMASZ`).
    public var arrowSize: Double
    /// Overall dimension scale (`$DIMSCALE`) — multiplies text + arrow at draw time.
    public var scale: Double
    /// How the measurement text's linear value is formatted (`$DIMLUNIT`).
    public var linearFormat: LinearFormat
    /// Measurement-text linear precision (decimal places, `$DIMDEC`).
    public var linearPrecision: Int
    /// `$DIMEXO` — the gap between an extension-line ORIGIN (the measured feature)
    /// and where the drawn extension line starts, in **world units**. `<= 0` ⇒ the
    /// resolve falls back to its arrow-fraction default (`dimExtensionOffsetFactor`).
    /// (`DRW_Dimstyle::dimexo` / AutoCAD's imperial default ~0.0625".)
    public var extensionOffset: Double
    /// `$DIMEXE` — how far an extension line runs PAST the dimension line, in
    /// **world units**. `<= 0` ⇒ the arrow-fraction default (`dimExtensionBeyondFactor`).
    /// (`DRW_Dimstyle::dimexe` / imperial default ~0.18".)
    public var extensionBeyond: Double
    /// `$DIMGAP` — the gap between the dimension line and the measurement text, in
    /// **world units**. `<= 0` ⇒ the text-height-fraction default. (`DRW_Dimstyle::
    /// dimgap` / imperial default ~0.09".)
    public var textGap: Double

    public init(textHeight: Double = 2.5,
                arrowSize: Double = 2.5,
                scale: Double = 1.0,
                linearFormat: LinearFormat = .decimal,
                linearPrecision: Int = 4,
                extensionOffset: Double = 0,
                extensionBeyond: Double = 0,
                textGap: Double = 0) {
        self.textHeight = textHeight
        self.arrowSize = arrowSize
        self.scale = scale
        self.linearFormat = linearFormat
        self.linearPrecision = linearPrecision
        self.extensionOffset = extensionOffset
        self.extensionBeyond = extensionBeyond
        self.textGap = textGap
    }

    /// The built-in defaults (used when no provider is wired) — matches the
    /// engine's historical hard-coded dimension defaults.
    public static let `default` = ResolvedDimStyle()
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

    /// The glyph/shaping abstraction (ADR-004 REVISION; text-system-design §2).
    /// The `.text`/`.dimension` resolve arms shape through this ONE provider, which
    /// has two impls behind it: `CoreTextFontProvider` (native outlines → fills,
    /// the default) and `StrokeFontProvider` (`.lff` → polyline strokes). `nil`
    /// makes text resolve to empty geometry rather than crash. Wired by
    /// `CADDrawing.makeResolveContext`.
    public var fontProvider: (any FontProvider)? = nil

    /// The document-default dimension style (decision D4). The `.dimension` resolve
    /// arm consults it for any value a dimension does NOT carry explicitly (a
    /// non-positive per-entity `textHeight`/`arrowSize` is the "inherit" sentinel),
    /// and it supplies the overall scale + measurement-text format/precision. `nil`
    /// (the default) ⇒ the resolve uses the engine's built-in `ResolvedDimStyle`
    /// defaults, so existing callers/tests are unchanged. Wired by
    /// `CADDrawing.makeResolveContext` from the drawing's `$DIM*` header vars (the
    /// Document Settings sheet writes those). Previously the reserved hook.
    public var dimStyleProvider: (@Sendable () -> ResolvedDimStyle)? = nil

    /// Resolves a NAMED dimension style (a `DimData.styleName`, DXF code 3) to its
    /// concrete `ResolvedDimStyle` from the drawing's `DimStyleTable`. This is the
    /// MIDDLE rung of the dimension-style precedence (decision D4, extended):
    ///
    ///   per-entity override  >  this named style  >  `dimStyleProvider` (header default)
    ///
    /// A dimension that names a style (e.g. "ISO-25") resolves through this; one
    /// with no style name (or a name absent from the table, ⇒ a `nil` return) falls
    /// back to the document `dimStyleProvider`. `nil` (the default) ⇒ no named table
    /// is wired, so dimensions resolve against the header default exactly as before
    /// (existing callers/tests unchanged). Wired by `CADDrawing.makeResolveContext`
    /// from the drawing's `DimStyleTable`. Parallel to `textStyleProvider`.
    public var namedDimStyleProvider: (@Sendable (String) -> ResolvedDimStyle?)? = nil

    /// Resolves a text-style NAME (DXF code 7, e.g. "Standard") to a concrete
    /// `TextStyle` (font source, height, width factor, oblique, annotative …),
    /// defaulting to "Standard". `nil` (or a `nil` return) makes the resolve arm
    /// synthesize a default native style. Parallel to the reserved `dimStyleProvider`
    /// hook; wired by `CADDrawing.makeResolveContext` from the drawing's
    /// `TextStyleTable`.
    public var textStyleProvider: (@Sendable (String) -> TextStyle?)? = nil

    /// The active annotation scale (text-system-design §"annotative mechanism";
    /// ADR T4). When a text's style is annotative, `resolve()` multiplies its
    /// height by this. `1.0` (no scaling) by default. Full paper-space/viewport-
    /// aware annotative is a later wave; this wires the mechanism + field now.
    public var annotationScale: Double = 1.0

    /// Resolves a block NAME (DXF code 2, an `.insert`'s `blockName`) to that
    /// block's ordered member `EntityRecord`s — the geometry placed by the insert.
    /// The same provider pattern as `fontProvider`/`dimStyleProvider`: wired by
    /// `CADDrawing.makeResolveContext` from the drawing's `BlockTable` (the block's
    /// `entityIDs` looked up against `entities`). A `nil` provider — or a `nil`
    /// return (the block doesn't exist) — makes an `.insert` resolve to EMPTY
    /// geometry rather than crash (the brief's "missing block resolves to empty").
    public var blockProvider: (@Sendable (String) -> [EntityRecord]?)? = nil

    /// The remaining recursion budget when expanding nested `.insert`s. Each block
    /// expansion decrements it; at `0` a further `.insert` resolves to empty. This
    /// is the **cyclic-block depth guard** (a block that references itself, or a
    /// cycle A→B→A, terminates instead of recursing forever). Starts at
    /// `maxBlockRecursionDepth` for a top-level resolve; the block-resolve arm
    /// threads a decremented copy into each member's resolve.
    public var blockRecursionDepth: Int = ResolveContext.maxBlockRecursionDepth

    /// The default maximum nesting depth for block (`.insert`) expansion. AutoCAD
    /// allows deep nesting but a real drawing is rarely more than a handful deep;
    /// this is the safety bound that makes a cyclic reference terminate.
    public static let maxBlockRecursionDepth = 32

    public init(
        tessellationTolerance: Double = 0.05,
        layerAttributes: @escaping @Sendable (LayerID) -> ResolvedPen = { _ in
            ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        blockAttributes: @escaping @Sendable (ResolvedPen?) -> ResolvedPen = { currentBlockPen in
            currentBlockPen ?? ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        },
        currentBlockPen: ResolvedPen? = nil,
        fontProvider: (any FontProvider)? = nil,
        textStyleProvider: (@Sendable (String) -> TextStyle?)? = nil,
        annotationScale: Double = 1.0,
        dimStyleProvider: (@Sendable () -> ResolvedDimStyle)? = nil,
        namedDimStyleProvider: (@Sendable (String) -> ResolvedDimStyle?)? = nil,
        blockProvider: (@Sendable (String) -> [EntityRecord]?)? = nil,
        blockRecursionDepth: Int = ResolveContext.maxBlockRecursionDepth
    ) {
        self.tessellationTolerance = tessellationTolerance
        self.layerAttributes = layerAttributes
        self.blockAttributes = blockAttributes
        self.currentBlockPen = currentBlockPen
        self.fontProvider = fontProvider
        self.textStyleProvider = textStyleProvider
        self.annotationScale = annotationScale
        self.dimStyleProvider = dimStyleProvider
        self.namedDimStyleProvider = namedDimStyleProvider
        self.blockProvider = blockProvider
        self.blockRecursionDepth = blockRecursionDepth
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

    /// Context-aware bounding box: identical to `boundingBox()` except `.text`
    /// returns the TIGHT, font-aware box when `ctx` carries a font provider (else
    /// the loose metric estimate). The document/quadtree layer opts in by passing
    /// its `ResolveContext`; every other caller keeps using the no-arg overload, so
    /// there is no signature cascade. (text-system-design §8.4 step 6.)
    public func boundingBox(ctx: ResolveContext) -> AABB {
        kind.boundingBox(ctx: ctx)
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
            // CAD text → glyph geometry via the unified FontProvider (ADR-004
            // REVISION): native outline glyphs become FILLS, `.lff` stroke glyphs
            // become polylines. All 15 justification modes, width factor, oblique,
            // multi-line (\n), the special-char pre-pass, and annotative scaling
            // are handled by the shared TextShaper (no second text path). No
            // provider / font ⇒ empty geometry (no crash).
            return TextShaper.resolve(d, pen: pen, ctx: ctx)

        case .mtext(let d):
            // Rich MTEXT → per-run shaped glyph geometry (native outlines → fills,
            // `.lff` strokes → polylines) laid out with word wrapping to the
            // reference width, line spacing, attachment-point alignment, stacked
            // fractions, and underline/overline/strike decorations. All runs go
            // through the SAME FontProvider as `.text` (no second text path). No
            // provider / font ⇒ empty geometry (no crash).
            return MTextShaper.resolve(d, pen: pen, ctx: ctx)

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

        case .insert(let d):
            // Block reference → the block's member entities, each transformed by
            // the insert's placement (translate∘rotate∘scale about the insertion
            // point) and resolved (recursively, depth-guarded against cyclic
            // blocks). A MINSERT repeats the block over its grid. A missing block
            // (no provider / unknown name) resolves to EMPTY (no crash). The
            // insert's own pen is threaded as the `currentBlockPen` so nested
            // `.byBlock` member pens inherit from the placing insert (ADR-001).
            return Self.resolveInsert(d, pen: pen, ctx: ctx)
        }
    }

    // MARK: - Insert (block reference) resolve — RS_Insert::update as a PURE function

    /// The placement transform of an insert about its insertion point:
    /// `translate(insertionPoint) ∘ rotate(rotation) ∘ scale(scale)`. Applied to
    /// the block's LOCAL geometry (which is authored about the block base point —
    /// conventionally (0,0), with the base point already folded into the member
    /// coords by the block table). A degenerate (zero) scale axis is clamped away
    /// from 0 so the linear part stays invertible enough for downstream kernels.
    static func insertTransform(_ d: InsertData, cellOffset: Vector = Vector(0, 0)) -> Affine2D {
        let sx = abs(d.scale.x) < Tolerance.distance ? Tolerance.distance * (d.scale.x < 0 ? -1 : 1)
            : d.scale.x
        let sy = abs(d.scale.y) < Tolerance.distance ? Tolerance.distance * (d.scale.y < 0 ? -1 : 1)
            : d.scale.y
        // Local frame: scale about origin, then offset by the (un-rotated) grid cell
        // offset, then rotate, then translate to the insertion point. Matches AutoCAD
        // MINSERT (the array spacing is in the insert's local, pre-rotation frame).
        let scale = Affine2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
        let cell = Affine2D.translation(cellOffset)
        let rotate = Affine2D.rotation(angle: d.rotation)
        let translate = Affine2D.translation(d.insertionPoint)
        return translate * rotate * cell * scale
    }

    /// Resolves an `.insert` to its placed block geometry (PURE; ADR-001 — no
    /// mutation, unlike `RS_Insert::update`). Looks the block up via
    /// `ctx.blockProvider`, transforms each member by the insert placement (per
    /// MINSERT grid cell), resolves each member RECURSIVELY with a decremented
    /// depth budget (the cyclic-block guard), and unions the results. Missing
    /// block / exhausted depth ⇒ empty geometry (no crash).
    static func resolveInsert(_ d: InsertData, pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard ctx.blockRecursionDepth > 0,
              let provider = ctx.blockProvider,
              let members = provider(d.blockName), !members.isEmpty
        else { return ResolvedGeometry() }

        // Thread the insert's pen as the current block pen so member `.byBlock`
        // sentinels inherit from the placing insert, and decrement the depth budget
        // so a cyclic block reference terminates.
        var childCtx = ctx
        childCtx.currentBlockPen = pen
        childCtx.blockRecursionDepth = ctx.blockRecursionDepth - 1

        var geo = ResolvedGeometry()
        for r in 0..<Swift.max(1, d.rows) {
            for c in 0..<Swift.max(1, d.cols) {
                let cellOffset = Vector(Double(c) * d.colSpacing, Double(r) * d.rowSpacing)
                let t = insertTransform(d, cellOffset: cellOffset)
                for member in members {
                    var placed = member
                    placed.kind = member.kind.transformed(by: t)
                    geo = geo.merged(with: placed.resolve(childCtx))
                }
            }
        }
        return geo
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
    /// A small non-zero default so the extension line does not touch the measured
    /// feature (the standard CAD DIMEXO gap; AutoCAD's default ~0.0625" ≈ a small
    /// fraction of the arrow length).
    static let dimExtensionOffsetFactor = 0.2
    /// How far an extension line runs past the dimension line, as a fraction of
    /// the arrow size (DIMEXE).
    static let dimExtensionBeyondFactor = 0.5
    /// Gap between the dimension line and the measurement text, as a fraction of
    /// the text height (DIMGAP). The historical default text offset was `0.7`
    /// times the text height; kept here as the fallback when no explicit `$DIMGAP`
    /// is supplied so existing dimension geometry/tests are unchanged.
    static let dimTextGapFactor = 0.7

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

    /// The document dimension style for this resolve (the wired `dimStyleProvider`,
    /// or the engine's built-in defaults when none is supplied). This is the
    /// LOWEST-precedence rung — the document header default.
    static func dimStyle(_ ctx: ResolveContext) -> ResolvedDimStyle {
        ctx.dimStyleProvider?() ?? .default
    }

    /// The effective `ResolvedDimStyle` for a dimension, resolving the NAMED-style
    /// middle rung of the precedence (decision D4, extended):
    ///
    ///   per-entity field override (handled in the field accessors below)
    ///     > the dimension's NAMED style (`d.styleName` via `namedDimStyleProvider`)
    ///       > the document header default (`dimStyleProvider`)
    ///
    /// A dimension whose `styleName` resolves in the wired `DimStyleTable` uses that
    /// named style as its base; otherwise it falls back to the document default. So
    /// `textHeight`/`arrowSize`/`scale`/format/precision AND the DIMEXO/DIMEXE/DIMGAP
    /// ext-line offsets all come from the named style when one is referenced.
    static func effectiveDimStyle(_ d: DimData, _ ctx: ResolveContext) -> ResolvedDimStyle {
        if let name = d.styleName, !name.isEmpty,
           let named = ctx.namedDimStyleProvider?(name) {
            return named
        }
        return dimStyle(ctx)
    }

    /// Effective measurement-text height (decision D4): the per-entity value WINS
    /// when set (`> 0`); otherwise the named/document style fills in (`$DIMTXT` via
    /// the resolved style). The result is multiplied by the style's overall
    /// dimension scale (`$DIMSCALE`). Falls back to the engine default when no
    /// provider is wired.
    static func dimTextHeight(_ d: DimData, ctx: ResolveContext = .default) -> Double {
        let style = effectiveDimStyle(d, ctx)
        let base = d.textHeight > 0 ? d.textHeight
            : (style.textHeight > 0 ? style.textHeight : dimDefaultTextHeight)
        return base * (style.scale > 0 ? style.scale : 1.0)
    }

    /// Effective arrow size (decision D4): per-entity wins when set; named/document
    /// style (`$DIMASZ`) fills in otherwise, then scaled by `$DIMSCALE`.
    static func dimArrowSize(_ d: DimData, ctx: ResolveContext = .default) -> Double {
        let style = effectiveDimStyle(d, ctx)
        let base = d.arrowSize > 0 ? d.arrowSize
            : (style.arrowSize > 0 ? style.arrowSize : dimDefaultArrowSize)
        return base * (style.scale > 0 ? style.scale : 1.0)
    }

    /// Effective extension-line ORIGIN offset (`$DIMEXO`) in world units: the
    /// resolved style's explicit value (scaled by `$DIMSCALE`) when positive,
    /// else the historical arrow-fraction default. The gap between the measured
    /// feature and where the drawn extension line starts.
    static func dimExtensionOffset(_ d: DimData, ctx: ResolveContext = .default) -> Double {
        let style = effectiveDimStyle(d, ctx)
        let scale = style.scale > 0 ? style.scale : 1.0
        if style.extensionOffset > 0 { return style.extensionOffset * scale }
        return dimArrowSize(d, ctx: ctx) * dimExtensionOffsetFactor
    }

    /// Effective extension-line EXTEND-BEYOND (`$DIMEXE`) in world units: the
    /// resolved style's explicit value (scaled) when positive, else the arrow-
    /// fraction default. How far the extension line runs past the dimension line.
    static func dimExtensionBeyond(_ d: DimData, ctx: ResolveContext = .default) -> Double {
        let style = effectiveDimStyle(d, ctx)
        let scale = style.scale > 0 ? style.scale : 1.0
        if style.extensionBeyond > 0 { return style.extensionBeyond * scale }
        return dimArrowSize(d, ctx: ctx) * dimExtensionBeyondFactor
    }

    /// Effective text gap (`$DIMGAP`) in world units: the resolved style's explicit
    /// value (scaled) when positive, else the historical text-height fraction
    /// default (`textH * dimTextGapFactor`). The clearance between the dimension
    /// line and the measurement text.
    static func dimTextGap(_ d: DimData, ctx: ResolveContext = .default) -> Double {
        let style = effectiveDimStyle(d, ctx)
        let scale = style.scale > 0 ? style.scale : 1.0
        if style.textGap > 0 { return style.textGap * scale }
        return dimTextHeight(d, ctx: ctx) * dimTextGapFactor
    }

    /// Formats a measured length/diameter/radius for the label at `precision`
    /// decimal places (the document's `$DIMDEC`; default 4 to match the historical
    /// behavior + existing tests), trimming trailing zeros so "10.0" reads "10".
    static func dimFormat(_ value: Double, precision: Int = 4) -> String {
        let p = Swift.max(0, Swift.min(12, precision))
        let factor = pow(10.0, Double(p))
        let rounded = (value * factor).rounded() / factor
        if abs(rounded - rounded.rounded()) < (0.5 / factor) {
            return String(Int(rounded.rounded()))
        }
        // Up to `p` decimals, trailing zeros stripped.
        var s = String(format: "%.\(p)f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// The label string for a dimension: the explicit override if present
    /// (a single space suppresses the text), else the computed measurement
    /// formatted at the document's `$DIMDEC` precision (via `dimStyleProvider`).
    static func dimLabel(_ d: DimData, measured: Double, suffix: String = "",
                         ctx: ResolveContext = .default) -> String {
        if let override = d.textOverride {
            // A single space is the DXF convention for "suppress the text".
            if override == " " { return "" }
            if !override.isEmpty { return override }
        }
        return suffix + dimFormat(measured, precision: effectiveDimStyle(d, ctx).linearPrecision)
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
        // Reuse the SAME text-resolution path as `.text` (no second text path,
        // per ADR-004 revision). `.middle` justification centers the run on
        // `center` both horizontally and vertically — the shaper handles the
        // metrics-aware centering, so dimension text picks up native fills or
        // `.lff` strokes identically.
        let data = TextData(position: center, height: height, rotation: rotation,
                            text: label, styleName: nil, hAlign: .middle, vAlign: .middle)
        return TextShaper.resolve(data, pen: pen, ctx: ctx)
    }

    /// Linear (fixed-angle) or aligned (angle = p1→p2 direction) dimension.
    static func dimLinearOrAligned(_ d: DimData, p1: Vector, p2: Vector, fixedAngle: Double?,
                                   pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard p1.valid, p2.valid, d.definitionPoint.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d, ctx: ctx)
        let textH = dimTextHeight(d, ctx: ctx)
        // Ext-line offsets from the resolved style ($DIMEXO/$DIMEXE/$DIMGAP), each
        // falling back to its historical arrow/text fraction when not supplied.
        let extOffset = dimExtensionOffset(d, ctx: ctx)
        let extBeyond = dimExtensionBeyond(d, ctx: ctx)
        let textGap = dimTextGap(d, ctx: ctx)

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
        //
        // M2 FIX: when an origin lies ON the dim line (`len ≈ 0`) the toDim
        // vector vanishes and its normalized direction is undefined; the old
        // `normal` fallback had an ARBITRARY sign, so the (zero-length, but the
        // DIMEXO/DIMEXE offsets are non-zero) extension line could point the wrong
        // way. Derive the direction ROBUSTLY from the dim-line normal, signed so it
        // points from the measured point toward the dim line: the dim line sits at
        // the projection of `definitionPoint` along the normal, so the sign is
        // `sign((dimPt − measuredPt)·normal)` and, at len≈0, `sign((measuredPt −
        // definitionPoint)·normal)` flipped — equivalently the side the def point
        // is NOT on. We compute it from the def point so it is stable at len≈0.
        func extLine(_ measuredPt: Vector, _ dimPt: Vector) -> ResolvedPolyline {
            let toDim = dimPt - measuredPt
            let len = toDim.magnitude
            let u: Vector
            if len > Tolerance.distance {
                u = toDim / len
            } else {
                // Origin is on the dim line: take the normal, signed so it points
                // AWAY from the def point (the dim line runs through the def point,
                // the extension runs out the opposite side of the measured point).
                let side = (measuredPt - d.definitionPoint).dot(normal)
                let sign = side >= 0 ? 1.0 : -1.0
                u = normal * sign
            }
            let start = measuredPt + u * extOffset
            let end = dimPt + u * extBeyond
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
        let label = dimLabel(d, measured: measured, ctx: ctx)
        let textCenter = (d.textMiddle.flatMap { $0.valid ? $0 : nil })
            ?? (dimP1 + dimP2) * 0.5 + normal * textGap
        // Keep text upright-ish: normalize the baseline angle to [-90°, 90°].
        // An explicit textRotation (DXF 53) overrides the derived angle.
        let textAngle = d.textRotation ?? dimTextAngle(dirAngle)
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
        let arrow = dimArrowSize(d, ctx: ctx)
        let textH = dimTextHeight(d, ctx: ctx)

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
        let label = dimLabel(d, measured: radius, suffix: "R", ctx: ctx)
        let normal = Vector(-outward.y, outward.x)
        let textCenter = (d.textMiddle.flatMap { $0.valid ? $0 : nil })
            ?? center + outward * (radius * 0.5) + normal * dimTextGap(d, ctx: ctx)
        let textAngle = d.textRotation ?? dimTextAngle(outward.angle)
        let textGeo = dimText(label, center: textCenter, rotation: textAngle,
                              height: textH, pen: pen, ctx: ctx)

        return ResolvedGeometry(polylines: polylines, fills: fills).merged(with: textGeo)
    }

    /// Diameter dimension: a line across the circle through both points, an
    /// arrowhead at each end, and the diameter label.
    static func dimDiameter(_ d: DimData, point1: Vector, point2: Vector,
                            pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard point1.valid, point2.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d, ctx: ctx)
        let textH = dimTextHeight(d, ctx: ctx)

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
        let label = dimLabel(d, measured: diameter, suffix: "\u{2300}", ctx: ctx)
        let normal = Vector(-along.y, along.x)
        let textCenter = (d.textMiddle.flatMap { $0.valid ? $0 : nil })
            ?? (point1 + point2) * 0.5 + normal * dimTextGap(d, ctx: ctx)
        let textAngle = d.textRotation ?? dimTextAngle(along.angle)
        let textGeo = dimText(label, center: textCenter, rotation: textAngle,
                              height: textH, pen: pen, ctx: ctx)

        return ResolvedGeometry(polylines: polylines, fills: fills).merged(with: textGeo)
    }

    /// The angular dimension's vertex + start angle + SIGNED sweep, selected so
    /// the dimension spans the angular sector the **definition point** sits in
    /// (M1). The single source of truth for the arc, the measured value, and the
    /// text center so all three AGREE.
    ///
    /// The vertex is the lines' intersection (parallel ⇒ inner-endpoint midpoint).
    /// `a1`/`a2` are the angles of line1End/line2End about the vertex; the CCW
    /// sweep a1→a2 is `correctAngle(a2 − a1)`. The def point SELECTS the sector:
    /// if its angle (relative to a1, normalized to [0, 2π)) lies within the CCW
    /// sweep, the dim spans CCW (positive sweep); otherwise it spans the
    /// COMPLEMENTARY arc CW (negative sweep = CCWsweep − 2π). The returned
    /// `sweep` is signed and feeds `arcPointsBySweep` directly; its magnitude is
    /// the measured angle. (Mirrors `RS_DimAngular::getAngle`/`update`, where the
    /// definition point chooses which of the four sectors the dimension covers.)
    static func dimAngularGeometry(_ d: DimData,
                                   line1: (Vector, Vector), line2: (Vector, Vector))
        -> (vertex: Vector, a1: Double, sweep: Double) {
        let vertex = lineLineIntersection(line1, line2)
            ?? (line1.1 + line2.1) * 0.5
        let a1 = (line1.1 - vertex).angle
        let a2 = (line2.1 - vertex).angle

        // CCW sweep a1→a2, normalized to (0, 2π].
        var ccw = Vector.correctAngle(a2 - a1)
        if ccw < Tolerance.angle { ccw = 2 * Double.pi }

        // Where does the def point sit, measured CCW from a1?
        let defOffset = Vector.correctAngle((d.definitionPoint - vertex).angle - a1)
        // Inside the CCW sector ⇒ span CCW; otherwise span the complementary arc
        // CW (a signed negative sweep covering 2π − ccw the other way).
        let withinCCW = defOffset <= ccw + Tolerance.angle
        let sweep = withinCCW ? ccw : ccw - 2 * Double.pi
        return (vertex, a1, sweep)
    }

    /// Angular dimension: an arc between the two lines (through definitionPoint),
    /// extension lines out to the arc ends, arrowheads, and the angle label.
    static func dimAngular(_ d: DimData, line1: (Vector, Vector), line2: (Vector, Vector),
                           pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard line1.0.valid, line1.1.valid, line2.0.valid, line2.1.valid,
              d.definitionPoint.valid else { return ResolvedGeometry() }
        let arrow = dimArrowSize(d, ctx: ctx)
        let textH = dimTextHeight(d, ctx: ctx)

        // Vertex + start angle + SIGNED sweep, with the sector selected by the
        // definition point (M1 — the single shared source of truth).
        let (vertex, a1, sweep) = dimAngularGeometry(d, line1: line1, line2: line2)
        let a2 = a1 + sweep   // arc-end angle in the chosen direction

        // Arc radius = distance from the vertex to the definition point.
        let radius = (d.definitionPoint - vertex).magnitude
        guard radius > Tolerance.distance else { return ResolvedGeometry() }

        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []

        // The dimension arc (vertex-centered, from a1 along the SIGNED sweep).
        let arcPts = Tessellation.arcPointsBySweep(
            center: vertex, radius: radius, startAngle: a1, sweep: sweep,
            tolerance: ctx.tessellationTolerance)
        polylines.append(ResolvedPolyline(points: arcPts, closed: false, pen: pen))

        // Extension lines from each line's far endpoint to the arc ends.
        let arcStart = vertex + Vector.polar(radius: radius, angle: a1)
        let arcEnd = vertex + Vector.polar(radius: radius, angle: a2)
        polylines.append(ResolvedPolyline(points: [line1.1, arcStart], closed: false, pen: pen))
        polylines.append(ResolvedPolyline(points: [line2.1, arcEnd], closed: false, pen: pen))

        // Arrowheads tangent to the arc at each end. The tangent direction follows
        // the SIGN of the sweep so heads point along the (CW or CCW) arc.
        let dir = sweep >= 0 ? 1.0 : -1.0
        let tan1 = Vector(angle: a1 + dir * Double.pi / 2)   // tangent at start
        let tan2 = Vector(angle: a2 + dir * Double.pi / 2)   // tangent at end
        fills.append(dimArrowhead(tip: arcStart, direction: -tan1, size: arrow, color: pen.color))
        fills.append(dimArrowhead(tip: arcEnd, direction: tan2, size: arrow, color: pen.color))

        // Angle label (degrees) at the arc midpoint. The MAGNITUDE of the signed
        // sweep is the measured angle (agrees with dimMeasuredValue).
        let degrees = abs(sweep) * 180 / Double.pi
        // N1: a textOverride REPLACES the whole label — do not append "°" to it.
        let label: String
        if let override = d.textOverride {
            label = override == " " ? "" : (override.isEmpty ? dimFormat(degrees) + "\u{00B0}" : override)
        } else {
            label = dimFormat(degrees) + "\u{00B0}"
        }
        let midA = a1 + sweep / 2
        let textCenter = (d.textMiddle.flatMap { $0.valid ? $0 : nil })
            ?? vertex + Vector.polar(radius: radius + dimTextGap(d, ctx: ctx), angle: midA)
        // Baseline tangent to the arc, in the sweep direction, kept upright.
        let textAngle = d.textRotation ?? dimTextAngle(midA + dir * Double.pi / 2)
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

    /// Context-aware bounding box: delegates to the analytic `boundingBox()` for
    /// every kind EXCEPT `.text`, which uses the tight font-aware box (the actual
    /// shaped glyph extents) when `ctx` has a font provider, falling back to the
    /// loose estimate otherwise. The quadtree/document layer calls this so text
    /// culling/snapping use the real ink extent. No other arm needs a ctx, so this
    /// is a thin overlay over the no-arg path (no signature cascade).
    public func boundingBox(ctx: ResolveContext) -> AABB {
        if case .text(let d) = self {
            if let tight = TextShaper.boundingBox(d, ctx: ctx) { return tight }
            return Self.textBoundingBox(d)
        }
        if case .mtext(let d) = self {
            if let tight = MTextShaper.boundingBox(d, ctx: ctx) { return tight }
            return Self.mtextBoundingBox(d)
        }
        if case .insert(let d) = self {
            // The real insert box needs the block provider (only here on the
            // ctx-carrying path): union of every transformed-and-resolved member,
            // per MINSERT cell. Missing block / no provider ⇒ collapse to the
            // insertion point (the no-arg path returns the same).
            return Self.insertBoundingBox(d, ctx: ctx)
        }
        return boundingBox()
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

        case .mtext(let d):
            return Self.mtextBoundingBox(d)

        case .hatch(let d):
            // Union of every boundary loop's vertices (bulge-arc bow is ignored —
            // boundary-arc tessellation is backlog; the vertex hull is a cheap
            // conservative box that contains the straight-edge fill we render).
            return AABB(points: d.loops.flatMap { $0.map(\.point) })

        case .solid(let d):
            return AABB(points: d.corners)

        case .dimension(let d):
            return Self.dimensionBoundingBox(d)

        case .insert(let d):
            // The no-arg path has no block provider, so the member geometry is
            // unavailable — collapse to the insertion point (a valid, if degenerate,
            // box). The ctx-carrying `boundingBox(ctx:)` returns the real union.
            return Self.insertBoundingBox(d, ctx: nil)
        }
    }

    /// World-space bounding box of an `.insert`: the union of every member's
    /// transformed-and-resolved geometry (per MINSERT cell), computed via the
    /// provided context's `blockProvider`. With no context / no provider / a
    /// missing block, collapses to the insertion point (a valid degenerate box).
    static func insertBoundingBox(_ d: InsertData, ctx: ResolveContext?) -> AABB {
        let fallback = AABB(point: d.insertionPoint.valid ? d.insertionPoint : Vector(0, 0))
        guard let ctx,
              ctx.blockRecursionDepth > 0,
              let provider = ctx.blockProvider,
              let members = provider(d.blockName), !members.isEmpty
        else { return fallback }

        var childCtx = ctx
        childCtx.blockRecursionDepth = ctx.blockRecursionDepth - 1

        var box = AABB.empty
        for r in 0..<Swift.max(1, d.rows) {
            for c in 0..<Swift.max(1, d.cols) {
                let cellOffset = Vector(Double(c) * d.colSpacing, Double(r) * d.rowSpacing)
                let t = insertTransform(d, cellOffset: cellOffset)
                for member in members {
                    box = box.union(member.kind.transformed(by: t).boundingBox(ctx: childCtx))
                }
            }
        }
        return box.isEmpty ? fallback : box
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
            // Use the SAME sector selection as the arc (M1): the def point picks
            // which angular sector is measured, so value + arc + label agree.
            let (_, _, sweep) = dimAngularGeometry(d, line1: (l1s, l1e), line2: (l2s, l2e))
            return (abs(sweep) * 180 / Double.pi, "")
        }
    }

    /// The default text center for a dimension (used by the bbox estimate; mirrors
    /// `resolveDimension`'s text placement, honoring `textMiddle` overrides).
    static func dimTextCenter(_ d: DimData) -> Vector {
        if let tm = d.textMiddle, tm.valid { return tm }
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
            // SAME sector selection as the arc (M1): the def point picks the
            // sector, so the text center sits on the measured arc's midpoint.
            let (vertex, a1, sweep) = dimAngularGeometry(d, line1: (l1s, l1e), line2: (l2s, l2e))
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

    /// Conservative world-space bounding box for rich MTEXT, used on the font-less
    /// `boundingBox()` path (the ctx-carrying path uses the tight font-aware box).
    /// Estimates the block from the run-tree text: a width of the reference width
    /// when set, else the longest paragraph's character count × a nominal advance;
    /// a height from the paragraph/line count × the line height. The estimated
    /// block is anchored by the attachment point and rotated about `position`.
    static func mtextBoundingBox(_ d: MTextData) -> AABB {
        guard d.height > 0 else { return AABB(point: d.position) }
        // Approximate line count = paragraphs (wrap adds lines; ignored in the
        // estimate). Longest paragraph length drives the width estimate.
        let lineCount = Swift.max(d.paragraphs.count, 1)
        var maxChars = 1
        for p in d.paragraphs {
            var chars = 0
            for inline in p.inlines {
                switch inline {
                case .run(let r): chars += r.text.count
                case .stacked(let s): chars += Swift.max(s.upper.count, s.lower.count)
                case .tab: chars += 4
                }
            }
            maxChars = Swift.max(maxChars, chars)
        }
        let nominalAdvance = 0.6 * d.height            // ~0.6 × height per glyph
        let estWidth = d.rectWidth > 0 ? d.rectWidth
            : Double(maxChars) * nominalAdvance
        let lineHeight = d.height * 1.6 * (d.lineSpacingFactor > 0 ? d.lineSpacingFactor : 1)
        let blockHeight = Double(lineCount) * lineHeight
        let blockTop = d.height                        // first cap top

        // Attachment shift in the local frame (mirrors MTextShaper.attachmentShift).
        let (dx, dy) = MTextShaper.attachmentShift(
            d.attachment, columnWidth: estWidth, blockTop: blockTop, blockHeight: blockHeight)

        let corners = [
            Vector(0, blockTop), Vector(estWidth, blockTop),
            Vector(estWidth, blockTop - blockHeight), Vector(0, blockTop - blockHeight),
        ]
        var box = AABB.empty
        for c in corners {
            let shifted = Vector(c.x + dx, c.y + dy)
            let rotated = d.rotation != 0 ? shifted.rotated(by: d.rotation) : shifted
            box.expand(toInclude: d.position + rotated)
        }
        return box.isEmpty ? AABB(point: d.position) : box
    }
}
