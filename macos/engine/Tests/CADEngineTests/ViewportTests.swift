//
//  ViewportTests.swift
//  CADEngineTests
//
//  Tests for the shared f64 viewport transform (workstream G): world↔screen
//  round-trips, zoom-about-cursor invariance, zoom-to-fit framing, the GPU
//  world→clip matrix (Y-up NDC, floating-origin), and degenerate-input safety.
//
//  Suite name is domain-prefixed (`ViewportTransformTests`) to avoid a
//  test-target namespace clash with any other parallel builder's suites
//  (CONVENTIONS.md "Namespace test-suite type names by domain").
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import simd
@testable import CADEngine

@Suite("Viewport transform")
struct ViewportTransformTests {

    private static let tol = 1e-9

    /// Applies a `world→clip` matrix to a world point (via its f32 offset from the
    /// render origin) the same way the vertex shader will, returning NDC (x, y).
    private func ndc(_ vp: Viewport, world p: Vector, origin: Vector, drawable: CGSize) -> (Float, Float) {
        let m = vp.worldToClip(renderOrigin: origin, drawableSize: drawable)
        let offset = SIMD4<Float>(Float(p.x - origin.x), Float(p.y - origin.y), 0, 1)
        let clip = m * offset
        return (clip.x, clip.y)
    }

    // MARK: - Round-trip world ↔ screen

    @Test("screenToWorld(worldToScreen(p)) ≈ p across points and scales")
    func roundTrip() {
        let sizes: [CGSize] = [CGSize(width: 800, height: 600), CGSize(width: 1024, height: 1024)]
        let scales: [Double] = [0.1, 1, 7.5, 250]
        let centers: [Vector] = [Vector(0, 0), Vector(-1234.5, 6789.0), Vector(1e6, -2e6)]
        let points: [Vector] = [
            Vector(0, 0), Vector(10, 20), Vector(-50, 75),
            Vector(1_000_000.25, -2_000_000.5), Vector(3.14159, -2.71828),
        ]
        for size in sizes {
            for scale in scales {
                for center in centers {
                    let vp = Viewport(scale: scale, center: center, size: size)
                    for p in points {
                        let back = vp.screenToWorld(vp.worldToScreen(p))
                        // Relative tolerance for the large-magnitude cases.
                        let mag = Swift.max(1.0, abs(p.x), abs(p.y))
                        #expect(abs(back.x - p.x) < Self.tol * mag)
                        #expect(abs(back.y - p.y) < Self.tol * mag)
                    }
                }
            }
        }
    }

    @Test("view center maps to screen center; Y is flipped (world-up = screen-up)")
    func centerAndYFlip() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport(scale: 2, center: Vector(100, 100), size: size)

        // Center world → exact screen center.
        let c = vp.worldToScreen(Vector(100, 100))
        #expect(abs(c.x - 400) < Self.tol)
        #expect(abs(c.y - 300) < Self.tol)

        // A world point ABOVE center (larger Y) must be HIGHER on screen
        // (smaller screen-y, because screen is Y-down).
        let above = vp.worldToScreen(Vector(100, 110))
        #expect(above.y < c.y)
        #expect(abs(above.x - c.x) < Self.tol)          // same column
        #expect(abs(above.y - (300 - 10 * 2)) < Self.tol) // 10 units * scale 2 up

        // A world point to the RIGHT (larger X) is farther right on screen.
        let right = vp.worldToScreen(Vector(110, 100))
        #expect(right.x > c.x)
        #expect(abs(right.x - (400 + 10 * 2)) < Self.tol)
    }

    // MARK: - Scale helpers

    @Test("pixelsPerUnit and worldPerPixel are reciprocals")
    func scaleHelpers() {
        let vp = Viewport(scale: 50, center: Vector(0, 0), size: CGSize(width: 100, height: 100))
        #expect(abs(vp.pixelsPerUnit - 50) < Self.tol)
        #expect(abs(vp.worldPerPixel - 1.0 / 50) < Self.tol)
        // A 10-point GUI catch range → world tolerance.
        #expect(abs(10 * vp.worldPerPixel - 0.2) < Self.tol)
    }

    // MARK: - Zoom about a cursor point

    @Test("zoom(by:about:) keeps the world point under the cursor fixed")
    func zoomAboutCursorInvariant() {
        let size = CGSize(width: 800, height: 600)
        let anchors: [CGPoint] = [
            CGPoint(x: 400, y: 300),  // center
            CGPoint(x: 0, y: 0),      // top-left corner
            CGPoint(x: 800, y: 600),  // bottom-right corner
            CGPoint(x: 137, y: 521),  // arbitrary
        ]
        for anchor in anchors {
            for factor in [0.5, 1.0, 2.0, 8.0] as [Double] {
                var vp = Viewport(scale: 3, center: Vector(42, -17), size: size)
                let worldBefore = vp.screenToWorld(anchor)
                vp.zoom(by: factor, about: anchor)
                // Scale changed by exactly `factor`.
                #expect(abs(vp.scale - 3 * factor) < Self.tol)
                // The world point under the cursor is unchanged.
                let worldAfter = vp.screenToWorld(anchor)
                #expect(abs(worldAfter.x - worldBefore.x) < 1e-6)
                #expect(abs(worldAfter.y - worldBefore.y) < 1e-6)
            }
        }
    }

    @Test("zoom rejects non-positive / non-finite factors")
    func zoomRejectsBadFactors() {
        var vp = Viewport(scale: 5, center: Vector(0, 0), size: CGSize(width: 100, height: 100))
        let before = vp
        vp.zoom(by: 0, about: CGPoint(x: 50, y: 50))
        #expect(vp == before)
        vp.zoom(by: -2, about: CGPoint(x: 50, y: 50))
        #expect(vp == before)
        vp.zoom(by: .nan, about: CGPoint(x: 50, y: 50))
        #expect(vp == before)
    }

    // MARK: - Pan

    @Test("pan by a screen delta shifts the world center inversely")
    func panShiftsCenter() {
        let size = CGSize(width: 800, height: 600)
        var vp = Viewport(scale: 4, center: Vector(0, 0), size: size)
        // Where does world origin sit before the pan?
        let originScreenBefore = vp.worldToScreen(Vector(0, 0))
        vp.pan(byScreenDelta: CGSize(width: 40, height: 20))
        // Content moved +40,+20 points → world origin's screen position moves too.
        let originScreenAfter = vp.worldToScreen(Vector(0, 0))
        #expect(abs(originScreenAfter.x - (originScreenBefore.x + 40)) < Self.tol)
        #expect(abs(originScreenAfter.y - (originScreenBefore.y + 20)) < Self.tol)
        // Scale is untouched by a pan.
        #expect(abs(vp.scale - 4) < Self.tol)
    }

    // MARK: - Zoom-to-fit

    @Test("fit frames a bbox: centered, filling the padded view, corners inside")
    func fitFramesBox() {
        let size = CGSize(width: 800, height: 600)
        let padding = 20.0
        let bounds = AABB(min: Vector(-100, -50), max: Vector(100, 50)) // 200 × 100
        let vp = Viewport.fit(bounds, in: size, padding: padding)

        // The bbox center lands at the view center.
        let mid = vp.worldToScreen(bounds.center)
        #expect(abs(mid.x - 400) < 1e-6)
        #expect(abs(mid.y - 300) < 1e-6)

        // All four corners fall inside the view rect (with a tiny epsilon).
        for corner in [Vector(-100, -50), Vector(100, -50), Vector(100, 50), Vector(-100, 50)] {
            let s = vp.worldToScreen(corner)
            #expect(s.x >= -1e-6 && s.x <= Double(size.width) + 1e-6)
            #expect(s.y >= -1e-6 && s.y <= Double(size.height) + 1e-6)
        }

        // The limiting axis (here Y: 100 units into 600-40=560 pts → 5.6; X: 200
        // into 800-40=760 → 3.8; min = 3.8) should touch the padded edge.
        let expectedScale = Swift.min((800 - 2 * padding) / 200, (600 - 2 * padding) / 100)
        #expect(abs(vp.scale - expectedScale) < 1e-6)

        // The bbox should span the padded width exactly along the limiting axis.
        let leftEdge = vp.worldToScreen(Vector(-100, 0))
        let rightEdge = vp.worldToScreen(Vector(100, 0))
        #expect(abs((rightEdge.x - leftEdge.x) - (200 * expectedScale)) < 1e-6)
        // Limiting axis is X here → its on-screen extent fills the padded width.
        #expect(abs((rightEdge.x - leftEdge.x) - (800 - 2 * padding)) < 1e-6)
    }

    @Test("fit centers an off-origin square symmetrically")
    func fitOffOriginSquare() {
        let size = CGSize(width: 500, height: 500)
        let bounds = AABB(min: Vector(1000, 1000), max: Vector(1010, 1010))
        let vp = Viewport.fit(bounds, in: size, padding: 10)
        let center = vp.worldToScreen(Vector(1005, 1005))
        #expect(abs(center.x - 250) < 1e-6)
        #expect(abs(center.y - 250) < 1e-6)
        // Square bbox in square view → both corners equidistant from center.
        let tl = vp.worldToScreen(Vector(1000, 1010))
        let br = vp.worldToScreen(Vector(1010, 1000))
        #expect(abs((250 - tl.x) - (br.x - 250)) < 1e-6)
        #expect(abs((250 - tl.y) - (br.y - 250)) < 1e-6)
    }

    // MARK: - World → clip matrix (GPU, Y-up NDC, floating origin)

    @Test("worldToClip: center maps to NDC (0,0)")
    func clipCenterIsOrigin() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport(scale: 5, center: Vector(50, -30), size: size)
        let drawable = CGSize(width: 1600, height: 1200) // 2× backing
        // renderOrigin near the content (the intended floating-origin usage) →
        // the center maps to NDC (0,0) to f32 precision. A far origin legitimately
        // degrades (that's WHY floating-origin keeps the origin near content);
        // covered separately in clipFloatingOriginInvariant with realistic tol.
        for origin in [Vector(0, 0), Vector(50, -30)] {
            let (nx, ny) = ndc(vp, world: vp.center, origin: origin, drawable: drawable)
            #expect(abs(nx) < 1e-5)
            #expect(abs(ny) < 1e-5)
        }
    }

    @Test("worldToClip: visible edges map near ±1")
    func clipEdgesNearUnit() {
        let size = CGSize(width: 800, height: 600)
        let scale = 4.0
        let center = Vector(0, 0)
        let vp = Viewport(scale: scale, center: center, size: size)
        let origin = Vector(0, 0)
        let drawable = CGSize(width: 800, height: 600)

        // Half the view in world units along each axis.
        let halfWorldX = (Double(size.width) * 0.5) / scale   // 400/4 = 100
        let halfWorldY = (Double(size.height) * 0.5) / scale  // 300/4 = 75

        let (rx, _) = ndc(vp, world: Vector(center.x + halfWorldX, center.y), origin: origin, drawable: drawable)
        let (lx, _) = ndc(vp, world: Vector(center.x - halfWorldX, center.y), origin: origin, drawable: drawable)
        #expect(abs(rx - 1) < 1e-5)    // right edge → +1
        #expect(abs(lx + 1) < 1e-5)    // left edge  → −1

        let (_, ty) = ndc(vp, world: Vector(center.x, center.y + halfWorldY), origin: origin, drawable: drawable)
        let (_, by) = ndc(vp, world: Vector(center.x, center.y - halfWorldY), origin: origin, drawable: drawable)
        #expect(abs(ty - 1) < 1e-5)    // top    → +1
        #expect(abs(by + 1) < 1e-5)    // bottom → −1
    }

    @Test("worldToClip: Y-up — a point above center has positive NDC Y")
    func clipYIsUp() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport(scale: 3, center: Vector(0, 0), size: size)
        let origin = Vector(0, 0)
        let drawable = CGSize(width: 800, height: 600)

        let (_, upY) = ndc(vp, world: Vector(0, 10), origin: origin, drawable: drawable)
        let (_, downY) = ndc(vp, world: Vector(0, -10), origin: origin, drawable: drawable)
        #expect(upY > 0)        // above center → +Y in NDC (Metal Y-up)
        #expect(downY < 0)      // below center → −Y in NDC
        #expect(abs(upY + downY) < 1e-6)  // symmetric about center

        let (rightX, _) = ndc(vp, world: Vector(10, 0), origin: origin, drawable: drawable)
        let (leftX, _) = ndc(vp, world: Vector(-10, 0), origin: origin, drawable: drawable)
        #expect(rightX > 0)
        #expect(leftX < 0)
    }

    @Test("worldToClip: floating-origin invariance — far origin gives same NDC")
    func clipFloatingOriginInvariant() {
        // The whole point of folding renderOrigin into the matrix: the NDC of a
        // world point is independent of which renderOrigin the buffers use.
        let size = CGSize(width: 1024, height: 768)
        let vp = Viewport(scale: 2.5, center: Vector(1_000_000, 2_000_000), size: size)
        let drawable = CGSize(width: 2048, height: 1536)
        let p = Vector(1_000_123, 1_999_950)

        let (ax, ay) = ndc(vp, world: p, origin: Vector(0, 0), drawable: drawable)
        let (bx, by) = ndc(vp, world: p, origin: Vector(1_000_000, 2_000_000), drawable: drawable)
        // Near origin the f32 path is far more precise; both must agree to a
        // reasonable f32 tolerance.
        #expect(abs(ax - bx) < 1e-2)
        #expect(abs(ay - by) < 1e-2)
        // The near-origin computation is the trustworthy one and should be on
        // screen (within NDC bounds for this nearby point).
        #expect(abs(bx) <= 1.0)
        #expect(abs(by) <= 1.0)
    }

    // MARK: - Visible world rect

    @Test("visibleWorldRect is the inverse image of the view, contains center")
    func visibleRect() {
        let size = CGSize(width: 800, height: 600)
        let scale = 2.0
        let vp = Viewport(scale: scale, center: Vector(10, 20), size: size)
        let rect = vp.visibleWorldRect
        #expect(rect.contains(Vector(10, 20)))     // center is visible
        // Width/height in world units = view points / scale.
        #expect(abs(rect.size.x - Double(size.width) / scale) < 1e-6)   // 400
        #expect(abs(rect.size.y - Double(size.height) / scale) < 1e-6)  // 300
        // Corners just inside the rect round-trip to inside the view.
        let c = rect.center
        #expect(abs(c.x - 10) < 1e-6)
        #expect(abs(c.y - 20) < 1e-6)
    }

    // MARK: - Degenerate / defensive

    @Test("fit on an empty bbox falls back to default scale, no crash")
    func fitEmptyBox() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport.fit(.empty, in: size, padding: 20)
        #expect(abs(vp.scale - Viewport.defaultScale) < Self.tol)
        #expect(vp.center == Vector(0, 0))
        // The transform is still usable (finite, invertible).
        let s = vp.worldToScreen(Vector(0, 0))
        #expect(s.x.isFinite && s.y.isFinite)
        let back = vp.screenToWorld(s)
        #expect(abs(back.x) < Self.tol && abs(back.y) < Self.tol)
    }

    @Test("fit on a degenerate (point/line) bbox does not divide by zero")
    func fitDegenerateBox() {
        let size = CGSize(width: 400, height: 400)
        // Single point.
        let pointVp = Viewport.fit(AABB(point: Vector(5, 5)), in: size, padding: 10)
        #expect(pointVp.scale.isFinite && pointVp.scale > 0)
        #expect(pointVp.center == Vector(5, 5))
        // Zero-height horizontal line.
        let lineVp = Viewport.fit(AABB(min: Vector(0, 7), max: Vector(10, 7)), in: size, padding: 10)
        #expect(lineVp.scale.isFinite && lineVp.scale > 0)
        // Centered on the line's midpoint.
        let mid = lineVp.worldToScreen(Vector(5, 7))
        #expect(abs(mid.x - 200) < 1e-6)
        #expect(abs(mid.y - 200) < 1e-6)
    }

    @Test("fit with zero-size view falls back without NaN")
    func fitZeroView() {
        let vp = Viewport.fit(AABB(min: Vector(0, 0), max: Vector(10, 10)),
                              in: CGSize(width: 0, height: 0), padding: 20)
        #expect(abs(vp.scale - Viewport.defaultScale) < Self.tol)
        #expect(vp.scale.isFinite)
    }

    @Test("constructor clamps a non-positive scale to a positive floor")
    func constructorClampsScale() {
        let vp = Viewport(scale: 0, center: Vector(0, 0), size: CGSize(width: 100, height: 100))
        #expect(vp.scale >= Viewport.minScale)
        let neg = Viewport(scale: -5, center: Vector(0, 0), size: CGSize(width: 100, height: 100))
        #expect(neg.scale >= Viewport.minScale)
        // worldToClip stays finite even at the floor.
        let m = vp.worldToClip(renderOrigin: Vector(0, 0), drawableSize: CGSize(width: 100, height: 100))
        #expect(m.columns.0.x.isFinite && m.columns.3.x.isFinite)
    }

    @Test("invalid center falls back to origin")
    func invalidCenterFallsBack() {
        let vp = Viewport(scale: 1, center: .invalid, size: CGSize(width: 100, height: 100))
        #expect(vp.center == Vector(0, 0))
    }

    // MARK: - Cursor↔world commit round-trip (cursor-offset regression)

    /// Pins the EXACT screen→world→screen identity the interaction layer relies on
    /// when a draw tool commits a point: a click at view-point `P` maps to world `W`
    /// via `screenToWorld`, and `worldToScreen(W)` must land back ON `P` (to f64
    /// precision). If this holds, any perceived "the line is offset from the cursor"
    /// is NOT a transform error — it is snapping moving the click (the real cause;
    /// see `SnapOffsetRegressionTests`). This is the regression guard the cursor-
    /// offset bug asked for: a representative view config (off-origin center, a
    /// non-1 scale, a non-square view) with clicks at concrete view points
    /// including the edges and arbitrary interior points.
    @Test("a click at view-point P round-trips: worldToScreen(screenToWorld(P)) == P")
    func clickCommitRoundTrip() {
        // A representative live config: non-1 scale, off-origin center, 16:10 view.
        let size = CGSize(width: 1280, height: 800)
        let vp = Viewport(scale: 3.5, center: Vector(420.25, -137.5), size: size)

        let clicks: [CGPoint] = [
            CGPoint(x: 0, y: 0),                       // top-left corner
            CGPoint(x: 1280, y: 800),                  // bottom-right corner
            CGPoint(x: 640, y: 400),                   // exact view center
            CGPoint(x: 17.5, y: 783.25),              // arbitrary interior
            CGPoint(x: 999.9, y: 12.3),               // arbitrary interior
        ]
        for p in clicks {
            // What the tool actually receives for a click at P (the raw, unsnapped
            // world point — this is exactly `CanvasModel.snappedWorldPoint`'s free
            // fallback when no snap fires).
            let world = vp.screenToWorld(p)
            // Where that committed world point is then drawn — must be UNDER P.
            let back = vp.worldToScreen(world)
            #expect(abs(back.x - Double(p.x)) < 1e-9, "x off at \(p): \(back.x)")
            #expect(abs(back.y - Double(p.y)) < 1e-9, "y off at \(p): \(back.y)")
        }
    }

    /// The conversion the host view performs (`convert(event.locationInWindow,
    /// from: nil)`) yields a point in the FLIPPED view's local space whose origin is
    /// the view's top-left — independent of any title-bar / toolbar inset, because
    /// the conversion is into the view's own coordinate space, not the window's.
    /// This test documents that the Viewport math is keyed off the view's POINT size
    /// only (never the window size or a drawable-pixel size), so a title-bar/toolbar
    /// offset cannot leak into world coords: the same local point gives the same
    /// world point regardless of where the view sits in its window.
    @Test("world mapping depends only on view-local point + view point-size, not window placement")
    func worldMappingIsViewLocalOnly() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport(scale: 2, center: Vector(0, 0), size: size)
        // A view-local click 100 pts right and 50 pts down from the view's top-left.
        let local = CGPoint(x: 100, y: 50)
        let world = vp.screenToWorld(local)
        // Y-down local → world is Y-up: 50 pts down from center-relative math.
        // Center is at (400,300) local; (100,50) is (-300,-250) pts from center.
        // world = center + (dx/scale, -dy/scale) = (-150, +125).
        #expect(abs(world.x - (-150)) < 1e-9)
        #expect(abs(world.y - 125) < 1e-9)
        // And it round-trips back to the SAME view-local point (no inset term).
        let back = vp.worldToScreen(world)
        #expect(abs(back.x - 100) < 1e-9)
        #expect(abs(back.y - 50) < 1e-9)
    }

    /// Pins the structural invariant the canvas relies on: the Viewport's `size` MUST
    /// equal the size of the view the event point was measured in, or a click lands a
    /// CONSTANT offset away from the cursor — exactly the reported "object appears up
    /// and to the left of the click". This proves WHY the canvas re-syncs
    /// `viewport.size` from the live `FlippedMTKView.bounds` on every interaction
    /// (`CADCanvasController.syncViewSizeFromView`): with the sizes matched the
    /// round-trip is exact; with a stale (larger) size it is off by half the
    /// per-axis mismatch, up and to the left — the observed symptom.
    @Test("a size mismatch between Viewport and the event-view yields a constant up-left offset; matched sizes round-trip exactly")
    func viewportSizeMustMatchEventView() {
        // The view the events are actually measured in (the live FlippedMTKView).
        let eventViewSize = CGSize(width: 1200, height: 800)
        // A click at an arbitrary view-local point in THAT view.
        let click = CGPoint(x: 300, y: 220)

        // --- Correct: Viewport size == event-view size → exact round-trip. ---
        let good = Viewport(scale: 2.5, center: Vector(10, -20), size: eventViewSize)
        let goodWorld = good.screenToWorld(click)
        let goodBack = good.worldToScreen(goodWorld)
        #expect(abs(goodBack.x - Double(click.x)) < 1e-9)
        #expect(abs(goodBack.y - Double(click.y)) < 1e-9)

        // --- Bug: a STALE, larger Viewport size (e.g. left over from the initial
        // 800×600 default, or a pre-layout drawable) while the SAME center/scale is
        // used. screenToWorld now uses the wrong half-extents, so the world point the
        // click maps to differs; when that point is drawn (worldToScreen with the
        // stale size) it does round-trip against the stale size, BUT the cursor the
        // user sees is positioned by the REAL view. Model that: the committed world
        // point, re-projected through the TRUE event-view viewport, is where it
        // visually lands relative to the cursor.
        let staleSize = CGSize(width: 1600, height: 1100)   // bigger than the real view
        let stale = Viewport(scale: 2.5, center: Vector(10, -20), size: staleSize)
        let staleWorld = stale.screenToWorld(click)         // what the click computes
        let trueVp = Viewport(scale: 2.5, center: Vector(10, -20), size: eventViewSize)
        let landed = trueVp.worldToScreen(staleWorld)       // where it visually shows
        // The offset is exactly half the per-axis size mismatch (the difference in
        // the `size/2` center term between the two viewports), and it pushes the
        // committed point UP and to the LEFT of the cursor (negative dx, dy).
        let expectedDx = (Double(eventViewSize.width) - Double(staleSize.width)) * 0.5   // -200
        let expectedDy = (Double(eventViewSize.height) - Double(staleSize.height)) * 0.5 // -150
        #expect(abs((landed.x - Double(click.x)) - expectedDx) < 1e-9)
        #expect(abs((landed.y - Double(click.y)) - expectedDy) < 1e-9)
        #expect(landed.x < Double(click.x))   // appears to the LEFT of the cursor
        #expect(landed.y < Double(click.y))   // appears ABOVE the cursor
    }
}
