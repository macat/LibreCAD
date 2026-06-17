//
//  CGSceneRenderer.swift
//  LibreCADmacOS
//
//  The shared `ResolvedGeometry → CGContext` renderer that drives ALL the raster /
//  vector-context export destinations: PDF, PNG, and the system Print dialog
//  (NSPrintOperation). It consumes the SAME `ExportScene` (resolved + layer-
//  filtered geometry) the pure-Swift `SVGExporter` consumes, so every format is
//  geometrically identical and the resolve / fill-hole / pen logic lives once in
//  the engine.
//
//  Drawing model:
//    - `ResolvedFill` regions (hatch/solid fills AND outline-text glyph fills) are
//      drawn as filled `CGPath`s with the EVEN-ODD rule, so multi-loop fills cut
//      their holes (glyph counters, hatch islands) — the `loops[0]` outer /
//      `loops[1...]` holes contract `ResolvedFill` freezes. Fills are drawn FIRST.
//    - `ResolvedPolyline` strokes are drawn as stroked `CGPath`s (closed polylines
//      close the subpath) on top, so edges overlay the fills (matches the on-screen
//      renderer's order).
//    - Per-entity pen color drives the CG stroke/fill color; the world→page
//      transform (y-up CAD → y-down CG image space, fit-to-page or 1:1) is the
//      engine's `ExportTransform`, applied via a single CTM concatenation so the
//      paths stay in plain world coordinates.
//
//  This file uses CoreGraphics/AppKit, so it lives in the app target (per the
//  agreed architecture). It contains NO geometry math beyond building CGPaths from
//  the already-resolved points.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import ImageIO
import CADEngine

/// Renders an `ExportScene` into a `CGContext` for PDF/PNG/Print. Stateless;
/// callers set up the destination context (PDF page, bitmap, print page) and hand
/// it here with the page transform.
enum CGSceneRenderer {

    /// Draws `scene` into `ctx` using `transform` (world→page). The context is
    /// assumed to be in DEFAULT (page-point, y-down for image/PDF) coordinates on
    /// entry; we apply the world→page mapping as a CTM so path coordinates are the
    /// resolved world points.
    ///
    /// - `background`: when non-nil, the whole page is filled with this color first
    ///   (PDF/PNG want an opaque white page by default; pass `nil` for transparent).
    /// - `minStrokeDevicePx`: a floor (in DEVICE pixels, after the world→page scale)
    ///   on the rendered stroke width. The default `0` means "no floor" so every
    ///   existing PDF/PNG/Print caller is byte-for-byte unchanged. A small tile
    ///   (e.g. the Blocks-sidebar thumbnail) passes a sub-pixel-guard value like
    ///   `0.75` so a thin hairline doesn't fall below one device pixel and vanish.
    static func draw(scene: ExportScene,
                     in ctx: CGContext,
                     transform: ExportTransform,
                     background: RGBAColor?,
                     minStrokeDevicePx: CGFloat = 0) {
        let page = transform.pageSize

        // Light-mode "automatic color" auto-invert gate (export slice): on a LIGHT
        // page, near-white color-7/"automatic" geometry would be invisible, so flip
        // it to ink — keyed off the page background the export actually paints, so
        // PDF/PNG/Print and SVG agree. A dark/transparent page leaves colors as-is.
        let invert = SVGExporter.isLightBackground(background)

        // Opaque page background (so PNG isn't transparent / PDF isn't black).
        if let bg = background {
            ctx.saveGState()
            ctx.setFillColor(cgColor(bg))
            ctx.fill(CGRect(x: 0, y: 0, width: page.width, height: page.height))
            ctx.restoreGState()
        }

        // World→page CTM. ExportTransform maps:
        //   pageX = (worldX − ox)·s + offX
        //   pageY = H − ((worldY − oy)·s + offY)
        // CG's origin is bottom-left (PDF) — but our ExportTransform already
        // produces a y-DOWN page point (top-left origin, matching SVG / NSImage).
        // To make the math identical across destinations, callers flip the context
        // to a top-left origin before calling (see the destination helpers), so we
        // build the affine directly from ExportTransform's page() definition.
        let s = transform.scale
        ctx.saveGState()
        // x' = s·x + (offX − s·ox)
        // y' = (H − offY + s·oy) + (−s)·y
        let tx = transform.offsetX - s * transform.worldOrigin.x
        let ty = page.height - transform.offsetY + s * transform.worldOrigin.y
        ctx.concatenate(CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: tx, ty: ty))

        // A ~1pt page hairline expressed in WORLD units (scaled by the CTM). Floor
        // it to `minStrokeDevicePx` DEVICE pixels so a tiny tile's hairline stays
        // visible: device width == worldWidth · s, so the floor in world units is
        // `minStrokeDevicePx / s`. With the default floor of 0 this is a no-op and
        // `strokeWorld` is exactly `1/s` as before.
        let baseStrokeWorld = s > 1e-12 ? 1.0 / s : 1.0
        let minStrokeWorld = (minStrokeDevicePx > 0 && s > 1e-12)
            ? Double(minStrokeDevicePx) / s
            : 0.0
        let strokeWorld = Swift.max(baseStrokeWorld, minStrokeWorld)

        // Fills first (even-odd, holes cut out). WIPEOUT masks (`isMask`) are
        // DEFERRED to a post-stroke pass (below) so a mask hides BOTH lower fills
        // AND lower strokes — exactly the Metal renderer's separate wipeout pass
        // (LineRenderer "pass 2b"). A non-mask fill with a gradient paints a
        // CGGradient clipped to its path; a flat fill paints a solid color.
        for fill in scene.fills where !fill.isMask {
            drawFill(fill, in: ctx, invert: invert)
        }

        // Raster images next — OVER fills, UNDER strokes: a fill never hides the
        // picture, while the frame outline (a stroke) still overlays it. This mirrors
        // the on-screen renderer's grid → fills → images → lines order so PDF/PNG
        // export composites identically. A missing/unloadable (or hidden) image draws
        // a placeholder outline instead, so export never crashes and the placement
        // stays visible.
        for image in scene.images {
            drawImage(image, in: ctx, strokeWorld: strokeWorld)
        }

        // Strokes on top. The DEFAULT stroke width is in WORLD units (scaled by the
        // CTM) so a ~1pt hairline on paper is `1/scale` world units — matching the
        // SVG path. A pen with an explicit `.millimeters` lineweight OVERRIDES this
        // per-polyline inside `drawPolyline` (mm → page points → world units), so a
        // wider pen renders a physically wider stroke on the page.
        ctx.setLineWidth(strokeWorld)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for poly in scene.polylines {
            drawPolyline(poly, in: ctx, strokeWorld: strokeWorld, scale: s, invert: invert)
        }

        // WIPEOUT mask pass — AFTER strokes (so it masks lower fills + strokes),
        // painting the page background color into each mask region. Mirrors the live
        // renderer's separate wipeout pass (the engine is view-free, so it carries a
        // fallback `color`; the export substitutes the real page bg here, exactly as
        // the renderer substitutes `view.clearColor`). A transparent page falls back
        // to white so a mask still erases. No-op when the scene has no mask.
        let maskColor = background ?? .white
        for fill in scene.fills where fill.isMask {
            drawMask(fill, in: ctx, color: maskColor)
        }

        ctx.restoreGState()
    }

    /// Paints a WIPEOUT mask region with the page background `color` (always opaque
    /// — a mask erases). Even-odd so a multi-loop mask cuts its holes consistently
    /// with the rest of the fill path handling.
    private static func drawMask(_ fill: ResolvedFill, in ctx: CGContext, color: RGBAColor) {
        let loops = fill.loops.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return }
        let path = CGMutablePath()
        for loop in loops {
            path.move(to: CGPoint(x: loop[0].x, y: loop[0].y))
            for p in loop.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
        }
        ctx.saveGState()
        ctx.setFillColor(cgColor(color))
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: - Image drawing

    /// Draws a resolved raster image into its world-space quad, so PDF/PNG export
    /// matches the screen. The quad corners are CCW from the lower-left
    /// `[LL, LR, UR, UL]`; we build a per-image CTM that maps the unit square
    /// `[0,1]²` onto the quad (origin LL, +x → LR edge, +y → UL edge) and draw the
    /// `CGImage` in `[0,1]²` — this reproduces the image's rotation + aspect from
    /// the u/v vectors exactly. A missing/unloadable file (or a placeholder image)
    /// draws the quad outline instead (no crash, placement still visible).
    private static func drawImage(_ image: ResolvedImage, in ctx: CGContext, strokeWorld: Double) {
        let c = image.corners
        guard c.count == 4, c.allSatisfy(\.valid) else { return }

        let cgImage: CGImage? = image.placeholder || image.textureKey.isEmpty
            ? nil : loadCGImage(path: image.textureKey)

        if let cgImage {
            // CTM: unit square → quad. LL is the origin; the +x basis is the LL→LR
            // edge, the +y basis is the LL→UL edge (so the image's bottom edge runs
            // LL→LR and its left edge LL→UL). The CGImage draws y-UP in [0,1]² (CG's
            // default), which lands the image's bottom row at v=0 → the LL/LR edge,
            // matching the on-screen UV mapping.
            let ll = c[0], lr = c[1], ul = c[3]
            let ex = lr - ll          // +x basis (bottom edge)
            let ey = ul - ll          // +y basis (left edge)
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(
                a: ex.x, b: ex.y, c: ey.x, d: ey.y, tx: ll.x, ty: ll.y))
            ctx.setAlpha(CGFloat(image.opacity))
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        } else {
            // Placeholder: the quad outline (so a missing image is visibly a frame).
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c[0].x, y: c[0].y))
            for p in c.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
            ctx.saveGState()
            ctx.setStrokeColor(cgColor(.librecadGreen))
            ctx.setLineWidth(strokeWorld)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// Loads a `CGImage` from an image file at `path`, or `nil` if missing/
    /// unreadable. Uses `CGImageSource` (no AppKit `NSImage` dependency in the
    /// export path) so any ImageIO-supported format (PNG/JPEG/TIFF/…) works.
    private static func loadCGImage(path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: - Element drawing

    private static func drawFill(_ fill: ResolvedFill, in ctx: CGContext, invert: Bool) {
        let loops = fill.loops.filter { $0.count >= 3 }
        guard !loops.isEmpty else { return }
        let path = CGMutablePath()
        for loop in loops {
            path.move(to: CGPoint(x: loop[0].x, y: loop[0].y))
            for p in loop.dropFirst() {
                path.addLine(to: CGPoint(x: p.x, y: p.y))
            }
            path.closeSubpath()
        }

        // GRADIENT fill: clip to the even-odd path and paint a CGGradient across the
        // fill's bbox, matching the Metal ramp (`RendererGeometry.gradientColor`)
        // axis/center/maxRadius so screen + export agree. A gradient carries its own
        // resolved stop colors, so the light-mode auto-invert does NOT apply to it.
        if let gradient = fill.gradient, drawGradientFill(gradient, path: path, loops: loops, in: ctx) {
            return
        }

        ctx.saveGState()
        // Flat solid fill — light-mode auto-invert flips a near-white "automatic"
        // fill to ink on a light page (export slice; gradients excluded above).
        ctx.setFillColor(cgColor(fill.color, invert: invert))
        ctx.addPath(path)
        // Even-odd so islands (glyph counters / hatch holes) are subtracted.
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// Paints a `ResolvedGradient` clipped to `path` (even-odd), mirroring the Metal
    /// renderer's per-vertex ramp (`RendererGeometry.gradientColor`): linear spans
    /// the bbox along the ramp axis (`center ± e·axis`, e = bbox half-extent on the
    /// axis); radial centers on the bbox center with the bbox half-diagonal radius.
    /// A one-color gradient gets a synthetic 50%-lightened second stop (the same
    /// `lightenedTint` the renderer uses). Returns `false` (caller falls back to the
    /// flat color) if the gradient is empty / the CGGradient can't be built.
    private static func drawGradientFill(_ gradient: ResolvedGradient,
                                         path: CGPath, loops: [[Vector]],
                                         in ctx: CGContext) -> Bool {
        // Resolve the two ramp endpoints (c0 → c1) from the stop list, mirroring the
        // renderer: 2+ → first two; 1 → first + lightened tint; 0 → bail (flat).
        let c0: RGBAColor
        let c1: RGBAColor
        switch gradient.colors.count {
        case 0:  return false
        case 1:  c0 = gradient.colors[0]; c1 = lightenedTint(gradient.colors[0])
        default: c0 = gradient.colors[0]; c1 = gradient.colors[1]
        }

        let bounds = AABB(points: loops.flatMap { $0 })
        guard !bounds.isEmpty, bounds.center.valid else { return false }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let comps: [CGFloat] = [
            CGFloat(c0.r), CGFloat(c0.g), CGFloat(c0.b), CGFloat(c0.a),
            CGFloat(c1.r), CGFloat(c1.g), CGFloat(c1.b), CGFloat(c1.a),
        ]
        guard let cgGradient = CGGradient(colorSpace: colorSpace,
                                          colorComponents: comps,
                                          locations: [0, 1], count: 2) else { return false }

        let center = bounds.center
        let halfW = (bounds.max.x - bounds.min.x) * 0.5
        let halfH = (bounds.max.y - bounds.min.y) * 0.5

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)   // even-odd clip = the fill region (holes cut out)
        switch gradient.kind {
        case .linear:
            let ax = cos(gradient.angle)
            let ay = sin(gradient.angle)
            let ext = abs(halfW * ax) + abs(halfH * ay)
            let start = CGPoint(x: center.x - ext * ax, y: center.y - ext * ay)
            let end   = CGPoint(x: center.x + ext * ax, y: center.y + ext * ay)
            // Extend at both ends so the ramp covers the whole clipped region.
            ctx.drawLinearGradient(cgGradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            let r = (halfW * halfW + halfH * halfH).squareRoot()
            let c = CGPoint(x: center.x, y: center.y)
            ctx.drawRadialGradient(cgGradient, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: CGFloat(r),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        return true
    }

    /// A 50%-toward-white lightened tint of `c` (alpha preserved) — the synthetic
    /// second endpoint for a single-color gradient (mirrors the renderer's
    /// `RendererGeometry.lightenedTint`).
    static func lightenedTint(_ c: RGBAColor) -> RGBAColor {
        RGBAColor(c.r + (1 - c.r) * 0.5, c.g + (1 - c.g) * 0.5, c.b + (1 - c.b) * 0.5, c.a)
    }

    private static func drawPolyline(_ poly: ResolvedPolyline, in ctx: CGContext,
                                     strokeWorld: Double, scale: Double, invert: Bool) {
        let pts = poly.points
        guard !pts.isEmpty else { return }
        ctx.saveGState()
        // Light-mode auto-invert flips a near-white "automatic" pen to ink on a
        // light page (export slice; a dark/transparent page leaves it untouched).
        ctx.setStrokeColor(cgColor(poly.pen.color, invert: invert))

        // Per-pen stroke width in WORLD units: an explicit `.millimeters` lineweight
        // renders at its PHYSICAL page size (mm → page points ÷ world→page scale),
        // floored to the shared `strokeWorld` (which already carries the
        // `minStrokeDevicePx` hairline floor) so a thin/zero pen stays crisp. A
        // non-explicit width keeps the shared `strokeWorld` default.
        let width = strokeWidthWorld(for: poly.pen, strokeWorld: strokeWorld, scale: scale)
        ctx.setLineWidth(width)

        if pts.count == 1 {
            // A point marker: a small filled dot (radius == stroke width).
            ctx.setFillColor(cgColor(poly.pen.color, invert: invert))
            let r = width
            ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            return
        }

        // Per-pen dash pattern: a non-solid resolved line type strokes with a dash
        // array (in WORLD units, since the CTM maps world→page). `.solid` (or a
        // residual `.byLayer`/`.byBlock` the resolve left, treated as solid) clears
        // any dash so the stroke is continuous. The pattern is scaled to a stroke
        // proportional to `width`, so a thicker pen gets proportionally longer dashes
        // and the gaps never collapse to nothing at a thin width.
        // W4B Stage 3 — LINETYPE SCALE: scale the dash array by the resolved linetype
        // scale (`ResolvedPen.linetypeScale` == entity DXF-48 × drawing $LTSCALE), the
        // SAME factor the Metal renderer scales `dashPeriodPx` by, so screen + CG
        // export agree. A scale of 1 (the default) leaves `dash` unchanged
        // (byte-for-byte the historical export); a solid pen returns an empty array.
        let dash = scaledDashLengths(for: poly.pen.lineType, scale: scale,
                                     strokeWorld: width,
                                     linetypeScale: poly.pen.linetypeScale)
        if dash.isEmpty {
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            ctx.setLineDash(phase: 0, lengths: dash)
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
        for p in pts.dropFirst() {
            path.addLine(to: CGPoint(x: p.x, y: p.y))
        }
        if poly.closed, pts.count >= 3 {
            path.closeSubpath()
        }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: - Line-type dash patterns

    /// The CG dash-length array (alternating ON, OFF, ON, … in WORLD units) for a
    /// resolved pen line type, or an EMPTY array for a continuous (solid) stroke.
    ///
    /// The patterns mirror the standard CAD line types (ACAD ISO / LibreCAD): a
    /// base "page" length (the dash unit) is expressed in PAGE POINTS and divided by
    /// the world→page `scale` so the dashes are a FIXED PHYSICAL size on paper,
    /// independent of the fit-to-page zoom — exactly like the explicit-lineweight
    /// stroke-width derivation. `strokeWorld` (the rendered stroke width in world
    /// units) sets the dot length so a `.dotted` / `.dashDot` dot is a round pip
    /// sized to the pen, never a zero-length gap.
    ///
    /// Pure value math (no CGContext) → unit-testable in `CGDashTests`.
    ///
    /// - Returns: `[]` for `.solid` (and any residual `.byLayer`/`.byBlock`),
    ///   otherwise a non-empty even-count alternating array.
    static func dashLengths(for lineType: PenLineType,
                            scale: Double,
                            strokeWorld: Double) -> [CGFloat] {
        // The dash UNIT in world units: a ~3.5 pt page length per "dash", scaled by
        // the world→page transform so it is a fixed paper size. Guard a degenerate
        // scale so we never divide by ~0.
        let unitPage = 3.5            // page points for one base dash segment
        let u = scale > 1e-12 ? unitPage / scale : strokeWorld * 8
        // A dot's drawn length: at least the stroke width (a round cap renders it as
        // a pip), capped small so dots stay dots.
        let dot = Swift.max(strokeWorld, u * 0.12)
        // A small gap unit.
        let gap = u * 0.5

        switch lineType {
        case .solid, .byLayer, .byBlock:
            return []
        case .dashed:
            // ─ ─ ─ : long dash, medium gap.
            return [u, gap]
        case .dotted:
            // · · · : tiny dot, small gap.
            return [dot, gap]
        case .dashDot:
            // ─ · ─ · : dash, gap, dot, gap.
            return [u, gap, dot, gap]
        case .center:
            // ─── · ─── · : long dash, gap, short dash, gap.
            return [u * 1.6, gap, u * 0.4, gap]
        case .border:
            // ── ── · : two dashes then a dot (heavy boundary line).
            return [u, gap, u, gap, dot, gap]
        case .divide:
            // ─── · · ─── : long dash then two dots.
            return [u * 1.4, gap, dot, gap, dot, gap]
        }
    }

    /// `dashLengths(...)` with every element multiplied by the resolved LINETYPE
    /// SCALE (`ResolvedPen.linetypeScale` == the entity's DXF code-48 scale × the
    /// drawing-wide `$LTSCALE`) — W4B Stage 3. A `linetypeScale` of `1` (the default)
    /// returns the base array UNCHANGED, so an existing export is byte-for-byte the
    /// same; a solid line stays `[]`. This is the CG counterpart of the Metal
    /// renderer scaling `dashPeriodPx`/`dashOnPx`, so screen + CG export agree.
    /// A `≤ 0` scale is floored to `1` (a malformed scale never collapses the dash).
    ///
    /// Pure value math (no CGContext) → unit-testable in `CGDashTests`.
    static func scaledDashLengths(for lineType: PenLineType,
                                  scale: Double,
                                  strokeWorld: Double,
                                  linetypeScale: Double) -> [CGFloat] {
        let base = dashLengths(for: lineType, scale: scale, strokeWorld: strokeWorld)
        let s = CGFloat(linetypeScale > 0 ? linetypeScale : 1)
        guard s != 1 else { return base }          // scale 1 ⇒ unchanged (regression)
        return base.map { $0 * s }
    }

    /// The stroke width in WORLD units for a resolved pen, consistent with the
    /// `strokeWorld = 1/scale` derivation in `draw(scene:…)`:
    ///
    /// - An EXPLICIT lineweight (`.millimeters(mm)`) is the pen's physical paper
    ///   width: `mm` millimeters == `mm / mmPerPoint` page points; after the
    ///   world→page CTM (`scale` page-points-per-world-unit) that is
    ///   `(mm / mmPerPoint) / scale` world units. It is floored to `strokeWorld`
    ///   (the shared ~1pt / `minStrokeDevicePx` hairline) so a thin/zero pen never
    ///   falls below a visible stroke. This is a fixed PHYSICAL size, independent of
    ///   the fit-to-page zoom (it tracks paper mm, not screen zoom).
    /// - Any NON-explicit width (`.default`/`.byLayer`/`.byBlock`) keeps the shared
    ///   `strokeWorld`, so every existing export is byte-for-byte unchanged.
    ///
    /// `mmPerPoint` mirrors the renderer's constant (1 pt = 1/72 in = 25.4/72 mm).
    static func strokeWidthWorld(for pen: ResolvedPen, strokeWorld: Double, scale: Double) -> Double {
        switch pen.lineWidth {
        case .millimeters(let mm):
            guard scale > 1e-12 else { return strokeWorld }
            let pagePoints = mm / mmPerPoint
            return Swift.max(strokeWorld, pagePoints / scale)
        case .default, .byLayer, .byBlock:
            return strokeWorld
        }
    }

    /// Millimeters per typographic point (1 pt = 1/72 inch, 1 inch = 25.4 mm).
    static let mmPerPoint: Double = 25.4 / 72.0

    // MARK: - Color

    /// Builds a device-RGB `CGColor` from an engine `RGBAColor`.
    static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    /// `cgColor(...)` with the LIGHT-MODE "automatic color" auto-invert applied when
    /// `invert` is set (the export slice of the on-screen behavior): a near-white
    /// pen (CAD color-7 / "automatic", resolved to white for a dark canvas) flips to
    /// near-black so it stays ink on a LIGHT page; any explicit non-white color is
    /// unchanged. The transform is shared with the SVG backend
    /// (`SVGExporter.autoInvertWhite`) so PDF/PNG/Print/SVG agree, and mirrors the
    /// renderer's `RendererGeometry.autoInvertWhite`. `invert == false` is the prior
    /// behavior (plain `cgColor`).
    static func cgColor(_ c: RGBAColor, invert: Bool) -> CGColor {
        cgColor(invert ? SVGExporter.autoInvertWhite(c) : c)
    }
}
