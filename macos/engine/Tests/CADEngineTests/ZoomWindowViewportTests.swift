//
//  ZoomWindowViewportTests.swift
//  CADEngineTests
//
//  The zoom-window rect→viewport math (F23): `Viewport.zoomedToWorldRect` frames a
//  WORLD rectangle (the inverse image of the user's drag box) so it fills the view,
//  keeping the same view size and centering on the rect, at the tighter-axis scale
//  so the whole box is visible. Degenerate boxes (a click) are a no-op.
//
//  Suite name is domain-prefixed (CONVENTIONS.md) to avoid a test-target clash.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@Suite("Zoom window viewport (F23)")
struct ZoomWindowViewportTests {

    private static let size = CGSize(width: 800, height: 600)

    @Test("zoom window centers on the box center")
    func centersOnBox() {
        let vp = Viewport(scale: 1, center: Vector(0, 0), size: Self.size)
        let rect = AABB(points: [Vector(10, 20), Vector(110, 80)])  // center (60, 50)
        let zoomed = vp.zoomedToWorldRect(rect, padding: 0)
        #expect(abs(zoomed.center.x - 60) < 1e-9)
        #expect(abs(zoomed.center.y - 50) < 1e-9)
        #expect(zoomed.size == Self.size)                  // view size unchanged
    }

    @Test("zoom window scale fits the box on the tighter axis (whole box visible)")
    func tighterAxisScale() {
        let vp = Viewport(scale: 1, center: Vector(0, 0), size: Self.size)
        // A 100-wide × 60-tall world box into an 800×600 view with no padding:
        //   scaleX = 800/100 = 8, scaleY = 600/60 = 10 → chosen = min = 8.
        let rect = AABB(points: [Vector(0, 0), Vector(100, 60)])
        let zoomed = vp.zoomedToWorldRect(rect, padding: 0)
        #expect(abs(zoomed.scale - 8) < 1e-9)
        // At that scale the box's 100 width maps to exactly the 800-pt view width.
        #expect(abs(rect.size.x * zoomed.scale - 800) < 1e-6)
        // The box's height (60 * 8 = 480) is < 600, so the whole box fits.
        #expect(rect.size.y * zoomed.scale <= 600 + 1e-6)
    }

    @Test("after zoom, the box maps inside the view rect (no crop)")
    func boxFitsInView() {
        let vp = Viewport(scale: 0.3, center: Vector(500, 500), size: Self.size)
        let rect = AABB(points: [Vector(120, 40), Vector(360, 300)])
        let zoomed = vp.zoomedToWorldRect(rect, padding: 8)
        // Map the box corners to screen; both must land within [0,size] (with the
        // 8-pt padding margin honored on the tighter axis).
        let a = zoomed.worldToScreen(rect.min)
        let b = zoomed.worldToScreen(rect.max)
        let minX = Swift.min(a.x, b.x), maxX = Swift.max(a.x, b.x)
        let minY = Swift.min(a.y, b.y), maxY = Swift.max(a.y, b.y)
        #expect(minX >= -1e-6 && maxX <= Self.size.width + 1e-6)
        #expect(minY >= -1e-6 && maxY <= Self.size.height + 1e-6)
    }

    @Test("padding shrinks the fitted scale vs no padding")
    func paddingShrinksScale() {
        let vp = Viewport(scale: 1, center: Vector(0, 0), size: Self.size)
        let rect = AABB(points: [Vector(0, 0), Vector(100, 100)])
        let tight = vp.zoomedToWorldRect(rect, padding: 0)
        let padded = vp.zoomedToWorldRect(rect, padding: 40)
        #expect(padded.scale < tight.scale)
    }

    @Test("a degenerate (click) box is a no-op")
    func degenerateBoxNoOp() {
        let vp = Viewport(scale: 2.5, center: Vector(3, 4), size: Self.size)
        // Empty box (the AABB the canvas yields for a click: both corners coincide).
        #expect(vp.zoomedToWorldRect(AABB.empty) == vp)
        // A zero-size box from two identical points is also empty → no zoom.
        let click = AABB(point: Vector(5, 5))
        #expect(vp.zoomedToWorldRect(click) == vp)
    }

    @Test("a zero-height (or zero-width) box still zooms on the non-degenerate axis")
    func sliverBox() {
        let vp = Viewport(scale: 1, center: Vector(0, 0), size: Self.size)
        // A wide, zero-height sliver: fits the width, finite scale (not infinity).
        let rect = AABB(points: [Vector(0, 50), Vector(200, 50)])
        let zoomed = vp.zoomedToWorldRect(rect, padding: 0)
        #expect(zoomed.scale.isFinite)
        #expect(abs(zoomed.scale - 800.0 / 200.0) < 1e-9)  // width drives it
        #expect(abs(zoomed.center.x - 100) < 1e-9)
    }
}
