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
    static func draw(scene: ExportScene,
                     in ctx: CGContext,
                     transform: ExportTransform,
                     background: RGBAColor?) {
        let page = transform.pageSize

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

        // Raster images first (UNDER fills + strokes, so a frame outline overlays
        // them — matching the on-screen renderer's order). A missing/unloadable file
        // (or a hidden image) draws a placeholder outline instead, so export never
        // crashes and the placement stays visible.
        let strokeWorld = s > 1e-12 ? 1.0 / s : 1.0
        for image in scene.images {
            drawImage(image, in: ctx, strokeWorld: strokeWorld)
        }

        // Fills next (even-odd, holes cut out).
        for fill in scene.fills {
            drawFill(fill, in: ctx)
        }

        // Strokes on top. Stroke width is in WORLD units (scaled by the CTM) so a
        // ~1pt hairline on paper is `1/scale` world units — matching the SVG path.
        ctx.setLineWidth(strokeWorld)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for poly in scene.polylines {
            drawPolyline(poly, in: ctx, strokeWorld: strokeWorld)
        }

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

    private static func drawFill(_ fill: ResolvedFill, in ctx: CGContext) {
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
        ctx.saveGState()
        ctx.setFillColor(cgColor(fill.color))
        ctx.addPath(path)
        // Even-odd so islands (glyph counters / hatch holes) are subtracted.
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private static func drawPolyline(_ poly: ResolvedPolyline, in ctx: CGContext, strokeWorld: Double) {
        let pts = poly.points
        guard !pts.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(cgColor(poly.pen.color))

        if pts.count == 1 {
            // A point marker: a small filled dot (radius == stroke width).
            ctx.setFillColor(cgColor(poly.pen.color))
            let r = strokeWorld
            ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            return
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

    // MARK: - Color

    /// Builds a device-RGB `CGColor` from an engine `RGBAColor`.
    static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
}
