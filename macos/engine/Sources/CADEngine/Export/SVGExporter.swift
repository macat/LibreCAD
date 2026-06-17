//
//  SVGExporter.swift
//  CADEngine
//
//  A pure-Swift SVG emitter for a `CADDrawing`. It walks the drawing's entities,
//  resolves each to `ResolvedGeometry` (the SAME computed-geometry contract the
//  on-screen Metal renderer and the CGContext PDF/PNG/Print renderer consume —
//  ADR-001), and serializes the result to an `<svg>` document:
//
//    - `ResolvedPolyline` strokes → `<polyline>` (open) / `<polygon>` (closed).
//    - `ResolvedFill` filled regions (hatch/solid fills AND outline-text glyph
//      fills) → `<path>` with the even-odd fill rule so holes (glyph counters,
//      hatch islands) are cut out — exactly the `loops[0]` outer / `loops[1...]`
//      holes contract `ResolvedFill` freezes.
//
//  This file is DELIBERATELY free of CoreGraphics/AppKit so it is unit-testable in
//  the CADEngine test target with no graphics context. The CGContext renderer
//  (PDF/PNG/Print) lives in the app target and shares the same resolve + fill-hole
//  geometry; it does not re-implement geometry math.
//
//  Coordinate system: SVG's y-axis points DOWN, CAD's points UP. We emit a single
//  `transform="matrix(...)"` on a wrapping `<g>` that flips y and maps world units
//  to the page, so every child element stays in plain world coordinates (matching
//  the resolved geometry) and is trivially diffable. Pen colors become `stroke`/
//  `fill` hex; a frozen/hidden layer's entities are omitted entirely.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// Options controlling the SVG (and, by sharing the same value type, the
/// CGContext PDF/PNG/Print) page layout.
public struct ExportOptions: Sendable, Equatable {
    /// How the drawing maps onto the page.
    public enum Scaling: Sendable, Equatable {
        /// Scale the drawing's bounding box to fit the page, preserving aspect.
        case fitToPage
        /// 1 world unit == `unitsPerPoint` page points (1.0 == 1:1). The page is
        /// sized to the drawing's bounds at that scale (plus margin).
        case oneToOne(unitsPerPoint: Double)
    }

    /// The target page size in points (72 pt == 1 inch). Used as the fit target
    /// for `.fitToPage`; for `.oneToOne` the page is sized from the bounds and this
    /// is ignored except as a fallback for an empty drawing.
    public var pageSize: SizePt
    /// Uniform margin (points) kept clear around the drawing.
    public var margin: Double
    /// How the drawing scales onto the page.
    public var scaling: Scaling
    /// Background fill (`nil` == transparent; PNG/PDF default to white via the
    /// renderer, SVG omits the rect when `nil`).
    public var background: RGBAColor?

    public init(
        pageSize: SizePt = .usLetter,
        margin: Double = 18,
        scaling: Scaling = .fitToPage,
        background: RGBAColor? = nil
    ) {
        self.pageSize = pageSize
        self.margin = margin
        self.scaling = scaling
        self.background = background
    }
}

/// A simple point-sized page rectangle (width × height in points). Kept in the
/// engine so `ExportOptions` (shared by SVG and the CGContext renderer) needs no
/// CoreGraphics dependency.
public struct SizePt: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
    /// US Letter (8.5in × 11in) at 72 pt/in.
    public static let usLetter = SizePt(width: 612, height: 792)
    /// ISO A4 (210mm × 297mm) at 72 pt/in.
    public static let a4 = SizePt(width: 595.276, height: 841.890)
}

/// The page transform that maps world (CAD) coordinates to page points, computed
/// once from the drawing bounds + `ExportOptions`. Shared by the SVG emitter and
/// the CGContext renderer so PDF/PNG/Print/SVG all frame the drawing identically.
///
/// World→page (y-flipped, since page space is y-down for SVG/CG image space):
///   pageX = (worldX − bounds.minX) · scale + offsetX
///   pageY = pageHeight − ((worldY − bounds.minY) · scale + offsetY)
public struct ExportTransform: Sendable, Equatable {
    /// The output page size in points.
    public var pageSize: SizePt
    /// World-units → page-points scale (uniform; aspect preserved).
    public var scale: Double
    /// World bounds origin (minX, minY) subtracted before scaling.
    public var worldOrigin: Vector
    /// Page-space translation applied after scaling (centers the drawing).
    public var offsetX: Double
    public var offsetY: Double

    /// Builds the transform for `bounds` under `options`. An empty/degenerate
    /// bounds falls back to the option page size at scale 1.
    public init(bounds: AABB, options: ExportOptions) {
        let margin = options.margin
        if bounds.isEmpty {
            self.pageSize = options.pageSize
            self.scale = 1
            self.worldOrigin = Vector(0, 0)
            self.offsetX = margin
            self.offsetY = margin
            return
        }
        let w = Swift.max(bounds.size.x, Tolerance.distance)
        let h = Swift.max(bounds.size.y, Tolerance.distance)
        self.worldOrigin = Vector(bounds.min.x, bounds.min.y)

        switch options.scaling {
        case .fitToPage:
            let page = options.pageSize
            let availW = Swift.max(page.width - 2 * margin, 1)
            let availH = Swift.max(page.height - 2 * margin, 1)
            let s = Swift.min(availW / w, availH / h)
            self.scale = s
            self.pageSize = page
            // Center the scaled drawing inside the available area.
            self.offsetX = margin + (availW - w * s) / 2
            self.offsetY = margin + (availH - h * s) / 2

        case .oneToOne(let unitsPerPoint):
            let s = unitsPerPoint > 0 ? 1.0 / unitsPerPoint : 1.0
            self.scale = s
            // Size the page to the drawing plus a uniform margin.
            self.pageSize = SizePt(width: w * s + 2 * margin,
                                   height: h * s + 2 * margin)
            self.offsetX = margin
            self.offsetY = margin
        }
    }

    /// Maps a world point to page points (y-down page space).
    public func page(_ p: Vector) -> (x: Double, y: Double) {
        let x = (p.x - worldOrigin.x) * scale + offsetX
        let y = (p.y - worldOrigin.y) * scale + offsetY
        return (x, pageSize.height - y)
    }
}

// MARK: - Scene collection (shared resolve + layer-visibility filter)

/// One resolved, layer-visible entity's drawable contribution. The collector
/// emits these in draw order; both the SVG emitter and the CGContext renderer
/// iterate them, so the resolve + visibility + pen logic lives in ONE place.
public struct ExportScene: Sendable, Equatable {
    /// All visible stroke polylines (world coords, resolved pens).
    public var polylines: [ResolvedPolyline]
    /// All visible filled regions (world coords; `loops[0]` outer, `loops[1...]`
    /// holes — even-odd / nonzero per the `ResolvedFill` contract).
    public var fills: [ResolvedFill]
    /// All visible raster-image placements (world-space quad corners + texture key
    /// + display params). The CG export renderer draws the `CGImage` into the quad
    /// rect (or a placeholder outline when the file is missing) so PDF/PNG match the
    /// screen; the pure-string SVG emitter does NOT embed the bitmap (it only knows
    /// the path) — out of scope for SVG, which keeps it dependency-free.
    public var images: [ResolvedImage]
    /// The world-space union bounds of the included geometry.
    public var bounds: AABB

    public init(polylines: [ResolvedPolyline] = [], fills: [ResolvedFill] = [],
                images: [ResolvedImage] = [], bounds: AABB = .empty) {
        self.polylines = polylines
        self.fills = fills
        self.images = images
        self.bounds = bounds
    }
}

/// Which drawing space an export targets — the export-side mirror of the live
/// canvas's `activeSpace`/`activeLayout` so a default export captures exactly what
/// is on screen (NOT the union of model + every layout). The engine-level twin of
/// the app's `PaperSpaceLayout.isInActiveSpace` predicate (the app type lives in
/// the app module, which `CADEngine` may not import; the predicate is trivial, so
/// it is replicated here over `EntityRecord.space`/`layoutName`).
public enum ExportSpace: Sendable, Equatable {
    /// Every entity in EVERY space (model + all paper layouts) — the historical
    /// export behavior, kept as the default so existing callers are unchanged.
    case all
    /// Only the model-space entities.
    case model
    /// Only the named paper layout's entities (case-insensitive name match,
    /// mirroring the engine's case-insensitive layout names). A `nil`/empty name
    /// yields nothing — the same as the live canvas with no active layout.
    case paper(layoutName: String?)

    /// Whether `record` belongs in this export space — the per-entity predicate the
    /// scene builder filters on. `.all` admits everything (historical behavior).
    func includes(_ record: EntityRecord) -> Bool {
        switch self {
        case .all:
            return true
        case .model:
            return record.space == .model
        case .paper(let layoutName):
            guard let layoutName, !layoutName.isEmpty else { return false }
            return record.space == .paper
                && (record.layoutName?.caseInsensitiveCompare(layoutName) == .orderedSame)
        }
    }
}

/// Builds an `ExportScene` from a drawing: resolves every entity, drops entities
/// on a frozen/hidden layer (mirroring the on-screen `LineRenderer.packEntity`
/// filter — a layer's `isVisible == false` ⇔ frozen) and entities outside the
/// target `space` (so a default export captures exactly the active space, like the
/// live canvas — not model + every layout unioned), and accumulates the
/// world-space bounds of what is actually drawn.
///
/// `@MainActor` because `CADDrawing` is main-actor isolated; callers (the export
/// commands and the SVG/CG entry points) already run there.
@MainActor
public enum ExportSceneBuilder {
    public static func build(_ drawing: CADDrawing,
                             space: ExportSpace = .all,
                             context: ResolveContext? = nil) -> ExportScene {
        let ctx = context ?? drawing.makeResolveContext()
        let layers = drawing.layers
        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []
        var images: [ResolvedImage] = []
        var bounds = AABB.empty

        for e in drawing.entities {
            // Space filter — only the targeted space's entities (the export twin of
            // the live `PaperSpaceLayout.isInActiveSpace` scope). `.all` (the
            // default) admits every space, so existing callers are unchanged.
            guard space.includes(e) else { continue }
            // Layer-visibility filter — identical policy to the live renderer:
            // a frozen/hidden layer contributes nothing; an entity referencing an
            // unknown layer (no record) still draws (resolve falls back to the
            // default pen). An explicitly non-printable layer is ALSO omitted so
            // export honors the plot/print flag.
            if let layer = layers.layer(e.layer) {
                if !layer.isVisible { continue }
                if !layer.isPrintable { continue }
            }
            let geo = e.resolve(ctx)
            for poly in geo.polylines {
                polylines.append(poly)
                for p in poly.points { bounds.expand(toInclude: p) }
            }
            for fill in geo.fills {
                fills.append(fill)
                for loop in fill.loops { for p in loop { bounds.expand(toInclude: p) } }
            }
            for image in geo.images {
                images.append(image)
                for p in image.corners { bounds.expand(toInclude: p) }
            }
        }
        return ExportScene(polylines: polylines, fills: fills, images: images, bounds: bounds)
    }
}

// MARK: - SVG emitter

/// Serializes a `CADDrawing` to an SVG document string. Pure string output (no
/// graphics context) so it is unit-testable; the CGContext renderer in the app
/// target covers PDF/PNG/Print from the same resolved geometry.
public enum SVGExporter {

    /// Renders `drawing` to a complete SVG document string.
    ///
    /// - Strokes become `<polyline>`/`<polygon>` (closed polylines use `<polygon>`
    ///   so the closing edge is implicit). Fills become `<path>` with `fill-rule:
    ///   evenodd` so multi-loop fills cut their holes (glyph counters, hatch
    ///   islands) — the same hole handling as the renderer's earcut path, but
    ///   expressed declaratively to the SVG renderer.
    /// - Pen colors map to `#rrggbb`; sub-1 alpha maps to `stroke-opacity`/
    ///   `fill-opacity`. A frozen/hidden (or non-printable) layer's entities are
    ///   omitted by `ExportSceneBuilder`.
    /// - The `viewBox` is the page rect (in points); a `<g transform>` flips y and
    ///   scales world→page so the children carry plain world coordinates.
    @MainActor
    public static func string(for drawing: CADDrawing,
                              options: ExportOptions = ExportOptions(),
                              context: ResolveContext? = nil) -> String {
        let scene = ExportSceneBuilder.build(drawing, context: context)
        return string(for: scene, options: options)
    }

    /// Renders a pre-built `ExportScene` (lets a caller share one scene across
    /// formats / inspect it in tests).
    public static func string(for scene: ExportScene,
                              options: ExportOptions = ExportOptions()) -> String {
        let xform = ExportTransform(bounds: scene.bounds, options: options)
        let page = xform.pageSize
        let w = fmt(page.width)
        let h = fmt(page.height)

        // Light-mode "automatic color" auto-invert is gated on a LIGHT page
        // background (the export slice of the on-screen behavior): a near-white page
        // makes color-7/white "automatic" geometry invisible, so flip it to ink. A
        // dark/transparent page leaves the color untouched (white ink is correct
        // there). Mirrors `CGSceneRenderer`'s gating so PDF/PNG/SVG agree.
        let invert = isLightBackground(options.background)

        var out = ""
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" "
        out += "width=\"\(w)\" height=\"\(h)\" "
        out += "viewBox=\"0 0 \(w) \(h)\">\n"

        // GRADIENT <defs>: one <linearGradient>/<radialGradient> per gradient fill,
        // keyed by index so the fill <path> references it via fill="url(#grad-N)".
        // Emitted in USER-SPACE-ON-USE units inside the world→page group so the
        // ramp axis is in plain world coords (same space the fill path lives in).
        let gradientDefs = buildGradientDefs(scene: scene)
        if !gradientDefs.defs.isEmpty {
            out += "  <defs>\n"
            for def in gradientDefs.defs { out += "    " + def + "\n" }
            out += "  </defs>\n"
        }

        // Optional background rectangle (the page).
        if let bg = options.background {
            out += "  <rect x=\"0\" y=\"0\" width=\"\(w)\" height=\"\(h)\" "
            out += "fill=\"\(hex(bg))\"/>\n"
        }

        // Group carrying the world→page transform (y-flip + scale + translate).
        // SVG matrix(a,b,c,d,e,f): x' = a·x + c·y + e ; y' = b·x + d·y + f.
        // We want: x' = (x − ox)·s + offX ; y' = H − ((y − oy)·s + offY)
        //        = s·x + 0·y + (offX − s·ox)
        //          0·x + (−s)·y + (H − offY + s·oy)
        let s = xform.scale
        let a = s, b = 0.0, c = 0.0, d = -s
        let e = xform.offsetX - s * xform.worldOrigin.x
        let f = page.height - xform.offsetY + s * xform.worldOrigin.y
        out += "  <g transform=\"matrix(\(fmt(a)),\(fmt(b)),\(fmt(c)),\(fmt(d)),\(fmt(e)),\(fmt(f)))\">\n"

        // The PAGE BACKGROUND color a WIPEOUT mask paints (the engine is view-free,
        // so it carries only a fallback `color`; the export supplies the real page
        // bg here — mirroring the live renderer substituting `view.clearColor`).
        // Defaults to white when the page is transparent so a mask still erases.
        let maskColor = options.background ?? .white

        // Fills first (so strokes overlay them — matches the renderer's draw order).
        // WIPEOUT masks (`isMask`) are DEFERRED to a post-stroke pass (below), so a
        // mask hides BOTH lower fills AND lower strokes — exactly the Metal
        // renderer's separate wipeout pass (LineRenderer "pass 2b").
        var gradIndex = 0
        for fill in scene.fills {
            if fill.isMask { continue }
            let ref = fill.gradient != nil ? "grad-\(gradIndex)" : nil
            if fill.gradient != nil { gradIndex += 1 }
            if let path = fillPath(fill, gradientRef: ref, invert: invert) {
                out += "    " + path + "\n"
            }
        }

        // Then strokes. Stroke width comes from the pen's lineweight (mm → world,
        // mirroring `CGSceneRenderer.strokeWidthWorld`); a pen with no explicit
        // lineweight keeps the shared ~1pt page hairline. Dashed/center/hidden pens
        // emit a `stroke-dasharray` (mirroring `CGSceneRenderer.scaledDashLengths`).
        let strokeWorld = strokeWorldWidth(scale: s)
        for poly in scene.polylines {
            if let el = polylineElement(poly, strokeWorld: strokeWorld, scale: s, invert: invert) {
                out += "    " + el + "\n"
            }
        }

        // WIPEOUT mask pass — AFTER strokes (so it masks lower fills + strokes),
        // painting the page background color into each mask region. Matches the live
        // renderer drawing the wipeout triangles re-colored to the canvas bg in a
        // pass after the model lines.
        for fill in scene.fills where fill.isMask {
            if let path = maskPath(fill, color: maskColor) { out += "    " + path + "\n" }
        }

        out += "  </g>\n"
        out += "</svg>\n"
        return out
    }

    // MARK: - Gradient defs

    /// The `<defs>` block for a scene's gradient fills: one element per gradient
    /// fill, in the SAME order the fill paths are emitted (so the Nth gradient fill
    /// references `grad-N`). Linear gradients carry the resolved ramp axis (x1,y1 →
    /// x2,y2 in world coords, `userSpaceOnUse`); radial gradients center on the
    /// fill's bbox center with the bbox half-diagonal as radius — mirroring
    /// `RendererGeometry.gradientColor`'s axis/center/maxRadius math so screen + SVG
    /// agree. A one-color gradient gets a synthetic 50%-lightened second stop (the
    /// same `lightenedTint` the renderer uses).
    static func buildGradientDefs(scene: ExportScene) -> (defs: [String], count: Int) {
        var defs: [String] = []
        var idx = 0
        for fill in scene.fills where !fill.isMask {
            guard let g = fill.gradient else { continue }
            let id = "grad-\(idx)"
            idx += 1
            let bounds = AABB(points: fill.loops.flatMap { $0 })
            defs.append(gradientDef(id: id, gradient: g, bounds: bounds, fallback: fill.color))
        }
        return (defs, idx)
    }

    /// One `<linearGradient>`/`<radialGradient>` def in `userSpaceOnUse` world coords.
    static func gradientDef(id: String, gradient: ResolvedGradient,
                            bounds: AABB, fallback: RGBAColor) -> String {
        // Resolve the two ramp endpoint colors (c0 → c1), mirroring the renderer:
        // 2+ stops → first two; 1 stop → first + a 50%-lightened tint; 0 → fallback.
        let c0: RGBAColor
        let c1: RGBAColor
        switch gradient.colors.count {
        case 0:  c0 = fallback;            c1 = fallback
        case 1:  c0 = gradient.colors[0];  c1 = lightenedTint(gradient.colors[0])
        default: c0 = gradient.colors[0];  c1 = gradient.colors[1]
        }
        func stop(_ off: String, _ c: RGBAColor) -> String {
            let op = c.a < 1 ? " stop-opacity=\"\(fmt(Double(c.a)))\"" : ""
            return "<stop offset=\"\(off)\" stop-color=\"\(hex(c))\"\(op)/>"
        }
        let stops = stop("0", c0) + stop("1", c1)

        if bounds.isEmpty {
            // Degenerate bounds: a trivial linear gradient (still valid markup).
            return "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">\(stops)</linearGradient>"
        }
        let center = bounds.center
        let halfW = (bounds.max.x - bounds.min.x) * 0.5
        let halfH = (bounds.max.y - bounds.min.y) * 0.5

        switch gradient.kind {
        case .linear:
            // Endpoints span the full bbox along the ramp axis (center ± e·axis),
            // where e is the bbox half-extent projected onto the axis — the same
            // span `gradientColor` normalizes `t` over.
            let ax = cos(gradient.angle)
            let ay = sin(gradient.angle)
            let ext = abs(halfW * ax) + abs(halfH * ay)
            let x1 = center.x - ext * ax, y1 = center.y - ext * ay
            let x2 = center.x + ext * ax, y2 = center.y + ext * ay
            return "<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" "
                + "x1=\"\(fmt(x1))\" y1=\"\(fmt(y1))\" x2=\"\(fmt(x2))\" y2=\"\(fmt(y2))\">"
                + "\(stops)</linearGradient>"
        case .radial:
            let r = (halfW * halfW + halfH * halfH).squareRoot()
            return "<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" "
                + "cx=\"\(fmt(center.x))\" cy=\"\(fmt(center.y))\" r=\"\(fmt(r))\">"
                + "\(stops)</radialGradient>"
        }
    }

    /// A 50%-toward-white lightened tint of `c` (alpha preserved) — the synthetic
    /// second endpoint for a single-color gradient (mirrors the renderer's
    /// `RendererGeometry.lightenedTint`).
    static func lightenedTint(_ c: RGBAColor) -> RGBAColor {
        RGBAColor(c.r + (1 - c.r) * 0.5, c.g + (1 - c.g) * 0.5, c.b + (1 - c.b) * 0.5, c.a)
    }

    // MARK: - Element emitters

    /// A world-space stroke width that renders as a ~1pt hairline on the page for
    /// the given world→page scale (clamped so a degenerate scale stays visible).
    static func strokeWorldWidth(scale: Double) -> Double {
        let targetPagePt = 1.0   // ~1pt on paper
        guard scale > Tolerance.distance else { return targetPagePt }
        return targetPagePt / scale
    }

    /// A `<polyline>` (open) or `<polygon>` (closed) for a resolved stroke. A
    /// single-point polyline (a resolved `.point`) emits a tiny `<circle>` marker.
    ///
    /// - `strokeWorld`: the shared ~1pt page hairline in world units (the fallback
    ///   width for a pen with no explicit lineweight).
    /// - `scale`: the world→page scale, used to derive the per-pen mm stroke width
    ///   and the fixed-paper-size dash lengths.
    /// - `invert`: light-mode color-7 auto-invert gate (a near-white "automatic"
    ///   pen becomes ink on a light page).
    static func polylineElement(_ poly: ResolvedPolyline,
                                strokeWorld: Double, scale: Double,
                                invert: Bool) -> String? {
        let pts = poly.points
        guard !pts.isEmpty else { return nil }
        let color = poly.pen.color
        let stroke = autoInvertHex(color, invert: invert)
        let opacity = color.a < 1 ? " stroke-opacity=\"\(fmt(Double(color.a)))\"" : ""

        // Per-pen stroke width (mm → world, mirroring CGSceneRenderer.strokeWidthWorld).
        let width = strokeWidthWorld(for: poly.pen, strokeWorld: strokeWorld, scale: scale)

        if pts.count == 1 {
            // A point marker: a small filled dot (radius == stroke width).
            let (x, y) = (pts[0].x, pts[0].y)
            return "<circle cx=\"\(fmt(x))\" cy=\"\(fmt(y))\" r=\"\(fmt(width))\" fill=\"\(stroke)\"\(opacity.replacingOccurrences(of: "stroke-opacity", with: "fill-opacity"))/>"
        }

        // Per-pen dash array (mirroring CGSceneRenderer.scaledDashLengths) — empty
        // for a solid pen (no attribute, so a solid stroke is byte-for-byte as before).
        let dash = scaledDashLengths(for: poly.pen.lineType, scale: scale,
                                     strokeWorld: width,
                                     linetypeScale: poly.pen.linetypeScale)
        let dashAttr = dash.isEmpty
            ? ""
            : " stroke-dasharray=\"\(dash.map { fmt($0) }.joined(separator: ","))\""

        let coords = pts.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
        let tag = poly.closed ? "polygon" : "polyline"
        return "<\(tag) points=\"\(coords)\" fill=\"none\" stroke=\"\(stroke)\"\(opacity) stroke-width=\"\(fmt(width))\"\(dashAttr) stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
    }

    /// A `<path>` for a resolved fill: the outer boundary `loops[0]` plus every
    /// hole `loops[1...]` as additional subpaths, with `fill-rule:evenodd` so the
    /// holes cut out (glyph counters, hatch islands) — the declarative equivalent
    /// of the renderer's earcut bridge.
    ///
    /// - `gradientRef`: when non-nil, the fill references a `<linearGradient>`/
    ///   `<radialGradient>` def (`fill="url(#…)"`) instead of a flat color.
    /// - `invert`: the light-mode auto-invert gate (applied to the flat-color path
    ///   only; a gradient carries its own resolved stop colors).
    static func fillPath(_ fill: ResolvedFill, gradientRef: String?, invert: Bool) -> String? {
        let loops = fill.loops.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return nil }
        var d = ""
        for loop in loops {
            d += "M " + loop.map { "\(fmt($0.x)) \(fmt($0.y))" }.joined(separator: " L ") + " Z "
        }
        let color = fill.color
        let opacity = color.a < 1 ? " fill-opacity=\"\(fmt(Double(color.a)))\"" : ""
        let fillVal = gradientRef.map { "url(#\($0))" } ?? autoInvertHex(color, invert: invert)
        return "<path d=\"\(d.trimmingCharacters(in: .whitespaces))\" fill=\"\(fillVal)\"\(opacity) fill-rule=\"evenodd\" stroke=\"none\"/>"
    }

    /// A `<path>` painting a WIPEOUT mask region with the page background `color`
    /// (the export substitutes the page bg for the engine's view-free fallback,
    /// exactly as the live renderer substitutes `view.clearColor`). Drawn in a
    /// post-stroke pass so it masks lower fills AND strokes. Always opaque (a mask
    /// erases — it never lets lower geometry bleed through).
    static func maskPath(_ fill: ResolvedFill, color: RGBAColor) -> String? {
        let loops = fill.loops.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return nil }
        var d = ""
        for loop in loops {
            d += "M " + loop.map { "\(fmt($0.x)) \(fmt($0.y))" }.joined(separator: " L ") + " Z "
        }
        return "<path d=\"\(d.trimmingCharacters(in: .whitespaces))\" fill=\"\(hex(color))\" fill-rule=\"evenodd\" stroke=\"none\"/>"
    }

    // MARK: - Per-pen stroke width / dash (SVG mirrors of CGSceneRenderer)

    /// The stroke width in WORLD units for a resolved pen — the SVG twin of
    /// `CGSceneRenderer.strokeWidthWorld`. An EXPLICIT `.millimeters` lineweight is
    /// its physical paper width (`mm / mmPerPoint` page points ÷ `scale`), floored
    /// to the shared `strokeWorld` hairline; a non-explicit width keeps `strokeWorld`.
    static func strokeWidthWorld(for pen: ResolvedPen, strokeWorld: Double, scale: Double) -> Double {
        switch pen.lineWidth {
        case .millimeters(let mm):
            guard scale > Tolerance.distance else { return strokeWorld }
            let pagePoints = mm / mmPerPoint
            return Swift.max(strokeWorld, pagePoints / scale)
        case .default, .byLayer, .byBlock:
            return strokeWorld
        }
    }

    /// Millimeters per typographic point (1 pt = 1/72 in, 1 in = 25.4 mm) — mirrors
    /// `CGSceneRenderer.mmPerPoint`.
    static let mmPerPoint: Double = 25.4 / 72.0

    /// The dash-length array (alternating ON, OFF, … in WORLD units) for a pen line
    /// type — the SVG twin of `CGSceneRenderer.dashLengths`. Empty for a solid (or
    /// residual byLayer/byBlock) pen. A base ~3.5 pt page dash unit is divided by
    /// `scale` so dashes are a FIXED PHYSICAL paper size; `strokeWorld` sizes a dot.
    static func dashLengths(for lineType: PenLineType, scale: Double, strokeWorld: Double) -> [Double] {
        let unitPage = 3.5
        let u = scale > Tolerance.distance ? unitPage / scale : strokeWorld * 8
        let dot = Swift.max(strokeWorld, u * 0.12)
        let gap = u * 0.5
        switch lineType {
        case .solid, .byLayer, .byBlock: return []
        case .dashed:  return [u, gap]
        case .dotted:  return [dot, gap]
        case .dashDot: return [u, gap, dot, gap]
        case .center:  return [u * 1.6, gap, u * 0.4, gap]
        case .border:  return [u, gap, u, gap, dot, gap]
        case .divide:  return [u * 1.4, gap, dot, gap, dot, gap]
        }
    }

    /// `dashLengths` with each element multiplied by the resolved LINETYPE SCALE —
    /// the SVG twin of `CGSceneRenderer.scaledDashLengths`. A scale of 1 returns the
    /// base array unchanged; a `<= 0` scale is floored to 1; a solid pen stays `[]`.
    static func scaledDashLengths(for lineType: PenLineType, scale: Double,
                                  strokeWorld: Double, linetypeScale: Double) -> [Double] {
        let base = dashLengths(for: lineType, scale: scale, strokeWorld: strokeWorld)
        let s = linetypeScale > 0 ? linetypeScale : 1
        guard s != 1 else { return base }
        return base.map { $0 * s }
    }

    // MARK: - Formatting

    /// Formats a double compactly: trims trailing zeros, drops a bare ".0", and
    /// rounds to 4 decimals (sub-micron at any sane CAD scale) so the output is
    /// stable and small.
    static func fmt(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let rounded = (v * 1e4).rounded() / 1e4
        if rounded == rounded.rounded() && abs(rounded) < 1e15 {
            return String(Int(rounded.rounded()))
        }
        var s = String(format: "%.4f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// `#rrggbb` for an `RGBAColor` (alpha handled separately as *-opacity).
    static func hex(_ c: RGBAColor) -> String {
        func ch(_ f: Float) -> Int { Swift.max(0, Swift.min(255, Int((f * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", ch(c.r), ch(c.g), ch(c.b))
    }

    // MARK: - Light-mode auto-invert (export slice)

    /// `hex(...)` with the LIGHT-MODE "automatic color" auto-invert applied when
    /// `invert` is set: a near-white pen (CAD color-7 / "automatic", which the
    /// engine resolves to white for a dark canvas) is flipped to near-black so it
    /// stays legible on a LIGHT page; any explicit non-white color is unchanged.
    /// Mirrors the renderer's `RendererGeometry.autoInvertWhite` threshold (0.85)
    /// and near-black target so screen + SVG agree. `invert == false` is the prior
    /// behavior (plain `hex`).
    ///
    /// NOTE (deferral): the broader auto-invert refactor — also inverting FILLS, also
    /// applying on screen via a single resolve-time pass — is OUT OF SCOPE here (it
    /// would touch Resolve.swift / RendererGeometry, which this lane does not own).
    /// This is the EXPORT SLICE only: strokes + flat fills in the CG/SVG backends.
    static func autoInvertHex(_ c: RGBAColor, invert: Bool) -> String {
        guard invert else { return hex(c) }
        return hex(autoInvertWhite(c))
    }

    /// The export-side auto-invert color transform (matches
    /// `RendererGeometry.autoInvertWhite`): a near-white color (min channel ≥ 0.85)
    /// becomes near-black (0.10, 0.10, 0.12), alpha preserved; any other color is
    /// returned unchanged. `public` so the app-target `CGSceneRenderer` shares the
    /// exact same transform (PDF/PNG/Print/SVG agree).
    public static func autoInvertWhite(_ c: RGBAColor) -> RGBAColor {
        let whiteThreshold: Float = 0.85
        if Swift.min(c.r, Swift.min(c.g, c.b)) >= whiteThreshold {
            return RGBAColor(0.10, 0.10, 0.12, c.a)
        }
        return c
    }

    /// Whether a page background counts as LIGHT (so auto-invert should fire): a
    /// near-white opaque page. A `nil` (transparent) or dark page returns `false`
    /// (white "automatic" ink is correct there, as on a dark canvas). Mirrors the
    /// renderer's light-mode gate (`OverlayStyle.invertNearWhiteEntities`) for the
    /// export slice — keyed off the page color the export actually paints. `public`
    /// so the app-target `CGSceneRenderer` gates PDF/PNG/Print on the SAME rule.
    public static func isLightBackground(_ bg: RGBAColor?) -> Bool {
        guard let bg, bg.a >= 0.5 else { return false }
        // Perceptual luminance > ~0.6 ⇒ a light page.
        let lum = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
        return lum > 0.6
    }
}
