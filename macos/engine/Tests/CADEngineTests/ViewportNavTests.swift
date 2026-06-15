//
//  ViewportNavTests.swift
//  CADEngineTests
//
//  Tests for the device-aware navigation input math (`ViewportNav`): the
//  scroll-wheel-delta → zoom-factor mapping (direction, compounding, per-tick
//  clamp), the wheel zoom-to-cursor composition (the world point under the pointer
//  stays under the pointer), and the pan-by-screen-delta semantics (content follows
//  the delta). These are the PURE helpers the `CADCanvasView` `scrollWheel` /
//  `magnify` / middle-drag plumbing is a thin GUI layer over — no `NSView`/`NSEvent`
//  needed, so they run without a window or device.
//
//  Suite name is domain-prefixed to avoid a test-target namespace clash with other
//  parallel builders' suites (CONVENTIONS.md "Namespace test-suite type names by
//  domain").
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@Suite("Viewport navigation input")
struct ViewportNavInputTests {

    private static let tol = 1e-9

    // MARK: - Wheel delta → zoom factor (direction + identity)

    @Test("scroll up (positive delta) zooms IN; scroll down zooms OUT; zero is identity")
    func wheelDirection() {
        // Standard CAD / macOS: positive scrollingDeltaY (wheel forward / scroll up)
        // → factor > 1 → zoom IN; negative → factor < 1 → zoom OUT.
        #expect(ViewportNav.zoomFactor(forWheelDelta: 1) > 1.0)
        #expect(ViewportNav.zoomFactor(forWheelDelta: 3) > 1.0)
        #expect(ViewportNav.zoomFactor(forWheelDelta: -1) < 1.0)
        #expect(ViewportNav.zoomFactor(forWheelDelta: -3) < 1.0)
        // A zero (or no-op) scroll leaves the zoom untouched.
        #expect(abs(ViewportNav.zoomFactor(forWheelDelta: 0) - 1.0) < Self.tol)
    }

    @Test("a single notch is a noticeable but bounded ~10% step")
    func wheelSingleNotch() {
        // One coarse notch (delta == 1) should be the tuned per-notch step, not the
        // imperceptible 1% the old `1 + delta*0.01` gave a line-granular wheel.
        let inFactor = ViewportNav.zoomFactor(forWheelDelta: 1)
        #expect(abs(inFactor - (1.0 + ViewportNav.wheelZoomStep)) < Self.tol)
        // And one notch out is its reciprocal-ish inverse (compounding base).
        let outFactor = ViewportNav.zoomFactor(forWheelDelta: -1)
        #expect(abs(outFactor - 1.0 / (1.0 + ViewportNav.wheelZoomStep)) < Self.tol)
    }

    @Test("notches compound: zooming in then out by the same delta returns to start")
    func wheelCompoundsReversibly() {
        // (1+s)^d * (1+s)^(-d) == 1 — two opposite notches cancel exactly, so a
        // scroll-in-then-out leaves the zoom where it began (no drift).
        for d in [1.0, 2.0, 5.0] {
            let net = ViewportNav.zoomFactor(forWheelDelta: d) *
                      ViewportNav.zoomFactor(forWheelDelta: -d)
            // Only meaningful while neither tick is clamped (small d): assert exact.
            if d <= 5 {
                // d=5 in == 1.1^5 ≈ 1.61 (< 2 clamp), out == 1.1^-5 (> 0.5 clamp).
                #expect(abs(net - 1.0) < 1e-9)
            }
        }
    }

    @Test("a large flick is clamped to the per-tick min/max factor")
    func wheelClampsFlick() {
        // A fast flick (a big accumulated delta) must never zoom more than 2× / 0.5×
        // in a single event, so the view can't teleport.
        #expect(abs(ViewportNav.zoomFactor(forWheelDelta: 1000) - ViewportNav.maxWheelZoomFactor) < Self.tol)
        #expect(abs(ViewportNav.zoomFactor(forWheelDelta: -1000) - ViewportNav.minWheelZoomFactor) < Self.tol)
        // Non-finite delta (NaN / ±inf) is garbage input → rejected to the identity
        // (a no-op zoom), never a NaN/inf factor that would corrupt the viewport.
        #expect(abs(ViewportNav.zoomFactor(forWheelDelta: .nan) - 1.0) < Self.tol)
        #expect(abs(ViewportNav.zoomFactor(forWheelDelta: .infinity) - 1.0) < Self.tol)
        #expect(abs(ViewportNav.zoomFactor(forWheelDelta: -.infinity) - 1.0) < Self.tol)
    }

    // MARK: - Wheel zoom is anchored at the cursor (zoom-to-cursor)

    @Test("wheel zoom keeps the world point under the cursor fixed on screen")
    func wheelZoomAnchorInvariant() {
        let size = CGSize(width: 1024, height: 768)
        let cursors: [CGPoint] = [
            CGPoint(x: 512, y: 384),   // dead center
            CGPoint(x: 0, y: 0),       // top-left
            CGPoint(x: 1024, y: 768),  // bottom-right
            CGPoint(x: 271, y: 640),   // arbitrary
        ]
        for cursor in cursors {
            for delta in [1.0, 3.0, -1.0, -4.0] {
                let vp = Viewport(scale: 2.5, center: Vector(33, -77), size: size)
                let worldBefore = vp.screenToWorld(cursor)
                let zoomed = ViewportNav.zoomedByWheel(vp, delta: delta, about: cursor)
                // The input viewport is untouched (pure function).
                #expect(vp.scale == 2.5)
                // The world point under the cursor is invariant across the zoom — this
                // IS "zoom to cursor": the point under the pointer stays under it.
                let worldAfter = zoomed.screenToWorld(cursor)
                #expect(abs(worldAfter.x - worldBefore.x) < 1e-6)
                #expect(abs(worldAfter.y - worldBefore.y) < 1e-6)
                // The scale moved in the expected direction.
                if delta > 0 { #expect(zoomed.scale > vp.scale) }
                if delta < 0 { #expect(zoomed.scale < vp.scale) }
            }
        }
    }

    @Test("wheel zoom about a corner moves the view center toward that corner on zoom-in")
    func wheelZoomTowardCorner() {
        // Zooming IN about the top-left corner pulls more of that corner's world into
        // view, so the new center must shift toward the corner's world point.
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport(scale: 1, center: Vector(0, 0), size: size)
        let corner = CGPoint(x: 0, y: 0)
        let cornerWorld = vp.screenToWorld(corner)   // up-left in world (Y-up): (-400, +300)
        let zoomed = ViewportNav.zoomedByWheel(vp, delta: 3, about: corner)   // zoom IN
        // Center moves from (0,0) toward the corner's world point on both axes.
        #expect(zoomed.center.x < vp.center.x)   // toward -X
        #expect(zoomed.center.y > vp.center.y)   // toward +Y (corner is up in world)
        // And it stays strictly between the old center and the (fixed) corner world.
        #expect(zoomed.center.x > cornerWorld.x)
        #expect(zoomed.center.y < cornerWorld.y)
    }

    // MARK: - Pan by screen delta (trackpad / middle-drag)

    @Test("pan by a screen delta moves the content with the delta (Y-down)")
    func panFollowsDelta() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport(scale: 4, center: Vector(0, 0), size: size)
        let before = vp.worldToScreen(Vector(0, 0))
        // A two-finger / middle-drag of (+30, +15) points: the world origin's screen
        // position moves the SAME (+30, +15) — content follows the fingers.
        let panned = ViewportNav.panned(vp, byScreenDelta: CGSize(width: 30, height: 15))
        let after = panned.worldToScreen(Vector(0, 0))
        #expect(abs(after.x - (before.x + 30)) < Self.tol)
        #expect(abs(after.y - (before.y + 15)) < Self.tol)
        // Pan never changes the zoom, and the input viewport is untouched (pure).
        #expect(abs(panned.scale - 4) < Self.tol)
        #expect(vp.center == Vector(0, 0))
    }

    @Test("pan distance scales inversely with zoom: same point-delta moves fewer world units when zoomed in")
    func panScalesWithZoom() {
        let size = CGSize(width: 800, height: 600)
        let delta = CGSize(width: 100, height: 0)
        let zoomedOut = ViewportNav.panned(
            Viewport(scale: 1, center: Vector(0, 0), size: size), byScreenDelta: delta)
        let zoomedIn = ViewportNav.panned(
            Viewport(scale: 10, center: Vector(0, 0), size: size), byScreenDelta: delta)
        // 100 pts of pan == 100 world units at scale 1, but only 10 world units at
        // scale 10 — the same finger travel covers less ground when zoomed in.
        #expect(abs(zoomedOut.center.x - (-100)) < Self.tol)
        #expect(abs(zoomedIn.center.x - (-10)) < Self.tol)
    }
}
