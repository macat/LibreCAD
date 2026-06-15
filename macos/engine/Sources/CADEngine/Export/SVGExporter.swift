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

/// Builds an `ExportScene` from a drawing: resolves every entity, drops entities
/// on a frozen/hidden layer (mirroring the on-screen `LineRenderer.packEntity`
/// filter — a layer's `isVisible == false` ⇔ frozen), and accumulates the
/// world-space bounds of what is actually drawn.
///
/// `@MainActor` because `CADDrawing` is main-actor isolated; callers (the export
/// commands and the SVG/CG entry points) already run there.
@MainActor
public enum ExportSceneBuilder {
    public static func build(_ drawing: CADDrawing,
                             context: ResolveContext? = nil) -> ExportScene {
        let ctx = context ?? drawing.makeResolveContext()
        let layers = drawing.layers
        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []
        var images: [ResolvedImage] = []
        var bounds = AABB.empty

        for e in drawing.entities {
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

        var out = ""
        out += "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" "
        out += "width=\"\(w)\" height=\"\(h)\" "
        out += "viewBox=\"0 0 \(w) \(h)\">\n"

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

        // Fills first (so strokes overlay them — matches the renderer's draw order).
        for fill in scene.fills {
            if let path = fillPath(fill) { out += "    " + path + "\n" }
        }

        // Then strokes. Stroke width is expressed in WORLD units (so it scales with
        // the group transform); a hairline maps to a small fraction of the drawing
        // extent — vector-stroke-width is a backlog refinement. We use a constant
        // world-space stroke chosen relative to the page scale so 1:1 and fit both
        // render visible hairlines.
        let strokeWorld = strokeWorldWidth(scale: s)
        for poly in scene.polylines {
            if let el = polylineElement(poly, strokeWidth: strokeWorld) { out += "    " + el + "\n" }
        }

        out += "  </g>\n"
        out += "</svg>\n"
        return out
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
    static func polylineElement(_ poly: ResolvedPolyline, strokeWidth: Double) -> String? {
        let pts = poly.points
        guard !pts.isEmpty else { return nil }
        let color = poly.pen.color
        let stroke = hex(color)
        let opacity = color.a < 1 ? " stroke-opacity=\"\(fmt(Double(color.a)))\"" : ""

        if pts.count == 1 {
            // A point marker: a small filled dot (radius == stroke width).
            let (x, y) = (pts[0].x, pts[0].y)
            return "<circle cx=\"\(fmt(x))\" cy=\"\(fmt(y))\" r=\"\(fmt(strokeWidth))\" fill=\"\(stroke)\"\(opacity.replacingOccurrences(of: "stroke-opacity", with: "fill-opacity"))/>"
        }

        let coords = pts.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
        let tag = poly.closed ? "polygon" : "polyline"
        return "<\(tag) points=\"\(coords)\" fill=\"none\" stroke=\"\(stroke)\"\(opacity) stroke-width=\"\(fmt(strokeWidth))\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
    }

    /// A `<path>` for a resolved fill: the outer boundary `loops[0]` plus every
    /// hole `loops[1...]` as additional subpaths, with `fill-rule:evenodd` so the
    /// holes cut out (glyph counters, hatch islands) — the declarative equivalent
    /// of the renderer's earcut bridge.
    static func fillPath(_ fill: ResolvedFill) -> String? {
        let loops = fill.loops.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return nil }
        var d = ""
        for loop in loops {
            d += "M " + loop.map { "\(fmt($0.x)) \(fmt($0.y))" }.joined(separator: " L ") + " Z "
        }
        let color = fill.color
        let opacity = color.a < 1 ? " fill-opacity=\"\(fmt(Double(color.a)))\"" : ""
        return "<path d=\"\(d.trimmingCharacters(in: .whitespaces))\" fill=\"\(hex(color))\"\(opacity) fill-rule=\"evenodd\" stroke=\"none\"/>"
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
}
