//
//  CGExportFidelityTests.swift
//  CADEngineTests
//
//  Pixel-sampling tests for the CG (PDF/PNG/Print) export backend's fidelity fixes:
//    - WIPEOUT masks (`ResolvedFill.isMask`) paint the PAGE BACKGROUND in a
//      POST-STROKE pass (so they erase lower strokes), not opaque black;
//    - GRADIENT hatch fills (`ResolvedFill.gradient`) render a CGGradient ramp
//      (two distinct colors across the fill), not a single flat color;
//    - LIGHT-MODE color-7 auto-invert flips a near-white "automatic" pen/fill to
//      ink on a light page, leaves it on a dark/transparent page, and never touches
//      an explicit color.
//
//  `CGSceneRenderer` lives in the `LibreCADmacOS` executable target; it is reached
//  here via the established `_SharedCGSceneRenderer.swift` symlink (same convention
//  as `CGDashTests`). The helper draws into an in-memory RGBA bitmap (NO modal, NO
//  GPU), and these tests sample pixels — fully headless.
//
//  Suite/type names are domain-namespaced (`CGExport*`) per CONVENTIONS.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
import CADEngine

@Suite("CG export — fidelity (mask / gradient / auto-invert)")
struct CGExportFidelityTests {

    // MARK: - Bitmap helper

    /// Renders `scene` into an `options`-sized RGBA bitmap at 1:1 (1 device px per
    /// page point) and returns the context so callers can sample pixels. The
    /// page→device flip matches `DrawingExporter.renderBitmap`.
    private func render(scene: ExportScene, options: ExportOptions) -> (ctx: CGContext, xform: ExportTransform)? {
        let xform = ExportTransform(bounds: scene.bounds, options: options)
        let pxW = Swift.max(1, Int(xform.pageSize.width.rounded()))
        let pxH = Swift.max(1, Int(xform.pageSize.height.rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Flip to a top-left origin (y-down) so the renderer's page-point math fills
        // the bitmap (same as renderBitmap, but with a 1:1 DPI scale).
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: 1, y: -1)
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: xform,
                             background: options.background)
        return (ctx, xform)
    }

    /// The RGBA (0…255) of the device pixel at world point `p`.
    private func pixel(_ ctx: CGContext, _ xform: ExportTransform, at p: Vector) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let data = ctx.data else { return nil }
        let page = xform.page(p)               // page points (y-down) == device px at 1:1
        let px = Int(page.x.rounded())
        let py = Int(page.y.rounded())
        guard px >= 0, px < ctx.width, py >= 0, py < ctx.height else { return nil }
        let bpr = ctx.bytesPerRow
        let buf = data.bindMemory(to: UInt8.self, capacity: bpr * ctx.height)
        let off = py * bpr + px * 4
        // premultipliedLast (RGBA). For opaque pixels (alpha 255) the stored values
        // are the straight colors, which is all these tests sample.
        return (Int(buf[off]), Int(buf[off + 1]), Int(buf[off + 2]), Int(buf[off + 3]))
    }

    // MARK: - Wipeout mask

    @Test("a wipeout mask paints the WHITE page background, not opaque black")
    func maskPaintsPageBackgroundNotBlack() throws {
        // A black mask square + a black stroke crossing its center. With the fix, the
        // mask is painted the WHITE page bg in a post-stroke pass, so the stroke's
        // center is ERASED (white), not black.
        let loop = [Vector(0, 0), Vector(100, 0), Vector(100, 100), Vector(0, 100)]
        let mask = ResolvedFill(outline: loop, color: .black, isMask: true)
        let stroke = ResolvedPolyline(points: [Vector(-50, 50), Vector(150, 50)],
                                      closed: false,
                                      pen: ResolvedPen(color: .black, lineType: .solid, lineWidth: .millimeters(3)))
        let scene = ExportScene(polylines: [stroke], fills: [mask], bounds: AABB(points: loop))
        let opts = ExportOptions(margin: 5, scaling: .oneToOne(unitsPerPoint: 1), background: .white)

        let (ctx, xform) = try #require(render(scene: scene, options: opts))
        // The mask interior (over the stroke line) must be WHITE (erased), not black.
        let center = try #require(pixel(ctx, xform, at: Vector(50, 50)))
        #expect(center.r > 230 && center.g > 230 && center.b > 230,
                "mask interior should be white (erased), got \(center)")
    }

    // MARK: - Gradient

    @Test("a two-color gradient fill renders DISTINCT colors at its two ends")
    func gradientRendersTwoColors() throws {
        // A horizontal red→blue linear gradient across a 100×100 square.
        let loop = [Vector(0, 0), Vector(100, 0), Vector(100, 100), Vector(0, 100)]
        let grad = ResolvedGradient(kind: .linear,
                                    colors: [RGBAColor(1, 0, 0), RGBAColor(0, 0, 1)], angle: 0)
        let fill = ResolvedFill(outline: loop, color: RGBAColor(1, 0, 0), gradient: grad)
        let scene = ExportScene(fills: [fill], bounds: AABB(points: loop))
        let opts = ExportOptions(margin: 5, scaling: .oneToOne(unitsPerPoint: 1), background: .white)

        let (ctx, xform) = try #require(render(scene: scene, options: opts))
        // Left end ≈ red-dominant; right end ≈ blue-dominant. (Sample inset from the
        // very edge so antialiasing on the boundary doesn't dominate.)
        let left = try #require(pixel(ctx, xform, at: Vector(8, 50)))
        let right = try #require(pixel(ctx, xform, at: Vector(92, 50)))
        #expect(left.r > left.b, "left end should be red-dominant, got \(left)")
        #expect(right.b > right.r, "right end should be blue-dominant, got \(right)")
    }

    @Test("a flat (non-gradient) fill is a single uniform color (unchanged)")
    func flatFillUniform() throws {
        let loop = [Vector(0, 0), Vector(100, 0), Vector(100, 100), Vector(0, 100)]
        let fill = ResolvedFill(outline: loop, color: RGBAColor(0.2, 0.6, 0.2))
        let scene = ExportScene(fills: [fill], bounds: AABB(points: loop))
        let opts = ExportOptions(margin: 5, scaling: .oneToOne(unitsPerPoint: 1), background: .white)

        let (ctx, xform) = try #require(render(scene: scene, options: opts))
        let a = try #require(pixel(ctx, xform, at: Vector(20, 50)))
        let b = try #require(pixel(ctx, xform, at: Vector(80, 50)))
        #expect(abs(a.r - b.r) <= 2 && abs(a.g - b.g) <= 2 && abs(a.b - b.b) <= 2,
                "flat fill should be uniform, got \(a) vs \(b)")
    }

    // MARK: - Auto-invert (color-7) — shared transform

    @Test("cgColor auto-invert flips a near-white pen to ink, leaves explicit colors")
    func cgColorAutoInvert() {
        // A near-white color → near-black ink (0.10,0.10,0.12) when invert is on.
        let inverted = CGSceneRenderer.cgColor(.white, invert: true)
        let comps = inverted.components ?? []
        #expect(comps.count >= 3)
        if comps.count >= 3 {
            #expect(comps[0] < 0.2 && comps[1] < 0.2 && comps[2] < 0.2,
                    "white pen should invert to ink, got \(comps)")
        }
        // invert == false leaves it white.
        let plain = CGSceneRenderer.cgColor(.white, invert: false)
        let pc = plain.components ?? []
        if pc.count >= 3 { #expect(pc[0] > 0.9 && pc[1] > 0.9 && pc[2] > 0.9) }
        // An explicit red is never inverted, even with invert on.
        let red = CGSceneRenderer.cgColor(RGBAColor(1, 0, 0), invert: true)
        let rc = red.components ?? []
        if rc.count >= 3 { #expect(rc[0] > 0.9 && rc[1] < 0.1 && rc[2] < 0.1) }
    }

    @Test("on a white page, a white automatic stroke renders as ink (not invisible)")
    func whiteStrokeInkOnWhitePage() throws {
        let pen = ResolvedPen(color: .white, lineType: .solid, lineWidth: .millimeters(3))
        let stroke = ResolvedPolyline(points: [Vector(0, 50), Vector(100, 50)], closed: false, pen: pen)
        let scene = ExportScene(polylines: [stroke], bounds: AABB(points: [Vector(0, 0), Vector(100, 100)]))
        let opts = ExportOptions(margin: 5, scaling: .oneToOne(unitsPerPoint: 1), background: .white)

        let (ctx, xform) = try #require(render(scene: scene, options: opts))
        let onLine = try #require(pixel(ctx, xform, at: Vector(50, 50)))
        // The stroke must be visible as ink (dark), not white-on-white.
        #expect(onLine.r < 120 && onLine.g < 120 && onLine.b < 120,
                "white automatic stroke should render as ink on a white page, got \(onLine)")
    }
}
