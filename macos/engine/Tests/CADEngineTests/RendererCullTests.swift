//
//  RendererCullTests.swift
//  CADEngineTests
//
//  Unit tests for the renderer's GPU-FREE cull/rebuild decision (`RendererCull`),
//  which enforces the floating-origin invariant: pan/zoom must change ONLY the
//  matrix, NOT rebuild the f32 instance buffer (rendering-performance.md §4.1).
//
//  The buffer is culled over a region PADDED past the literal visible rect; a
//  small pan/zoom that stays inside that padded region reports "no rebuild
//  needed" (matrix-only), and only a view change that escapes it reports "rebuild
//  needed". These tests prove that gate with pure value math — no GPU/MTKView.
//
//  Compiles the EXACT shipping `RendererCull` source via the same symlink trick as
//  `RendererGeometryTests` (`_SharedRendererCull.swift`), since `RendererCull`
//  lives in the non-importable `LibreCADmacOS` executable target.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import CADEngine

@Suite("Renderer cull — floating-origin rebuild gate")
struct RendererCullTests {

    /// A 2D world AABB helper (z collapsed to 0).
    private func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> AABB {
        AABB(min: Vector(minX, minY, 0), max: Vector(maxX, maxY, 0))
    }

    // MARK: - expanded(byFraction:)

    @Test("expanded(byFraction:) pads each side by the fraction of the extent")
    func expandedPadsBothSides() {
        let r = rect(0, 0, 100, 50)            // extent 100 × 50
        let e = RendererCull.expanded(r, byFraction: 0.4)
        // 40% of 100 = 40 per side in x; 40% of 50 = 20 per side in y.
        #expect(e.min.x == -40)
        #expect(e.max.x == 140)
        #expect(e.min.y == -20)
        #expect(e.max.y == 70)
    }

    @Test("expanded() leaves an empty rect empty")
    func expandedEmptyStaysEmpty() {
        let e = RendererCull.expanded(.empty, byFraction: 0.4)
        #expect(e.isEmpty)
    }

    @Test("expanded() of a degenerate (point) rect gets a small non-zero margin")
    func expandedDegenerateGetsEpsilon() {
        let p = AABB(point: Vector(5, 5, 0))
        let e = RendererCull.expanded(p, byFraction: 0.4)
        #expect(!e.isEmpty)
        #expect(e.min.x < 5)
        #expect(e.max.x > 5)
        #expect(e.min.y < 5)
        #expect(e.max.y > 5)
    }

    // MARK: - contains(_:_:)

    @Test("contains() is true for a strictly-inner rect, false for an escaping one")
    func containment() {
        let outer = rect(0, 0, 100, 100)
        #expect(RendererCull.contains(outer, rect(10, 10, 90, 90)))   // fully inside
        #expect(RendererCull.contains(outer, rect(0, 0, 100, 100)))   // exactly equal (boundary ok)
        #expect(!RendererCull.contains(outer, rect(-1, 10, 90, 90)))  // escapes left
        #expect(!RendererCull.contains(outer, rect(10, 10, 101, 90))) // escapes right
        #expect(!RendererCull.contains(outer, rect(10, 10, 90, 101))) // escapes top
    }

    @Test("contains() — empty inner is trivially contained; empty outer contains nothing")
    func containmentEmptyEdges() {
        #expect(RendererCull.contains(rect(0, 0, 10, 10), .empty))
        #expect(!RendererCull.contains(.empty, rect(0, 0, 10, 10)))
    }

    // MARK: - needsRebuild (the gate)

    @Test("no buffer yet → rebuild needed")
    func rebuildWhenNoBuffer() {
        #expect(RendererCull.needsRebuild(
            builtPaddedRect: rect(0, 0, 100, 100),
            currentVisibleRect: rect(10, 10, 90, 90),
            modelChanged: false, hasBuffer: false))
    }

    @Test("model changed → rebuild needed even if the view didn't move")
    func rebuildWhenModelChanged() {
        let r = rect(0, 0, 100, 100)
        #expect(RendererCull.needsRebuild(
            builtPaddedRect: r, currentVisibleRect: rect(10, 10, 90, 90),
            modelChanged: true, hasBuffer: true))
    }

    /// THE floating-origin invariant: a small pan whose visible rect stays inside
    /// the padded built rect reports NO rebuild — i.e. it is a matrix-only frame.
    @Test("small pan staying inside the padded built rect → NO rebuild (matrix-only)")
    func smallPanInsideMarginNoRebuild() {
        // Build at visible rect [0,100]×[0,100]; the renderer culls the padded rect.
        let visible = rect(0, 0, 100, 100)
        let builtPadded = RendererCull.expanded(visible, byFraction: RendererCull.defaultMargin)
        // → builtPadded = [-40,140]×[-40,140].

        // A pan of +10 in x/y: visible becomes [10,110]×[10,110], still well inside.
        let afterSmallPan = rect(10, 10, 110, 110)
        #expect(RendererCull.contains(builtPadded, afterSmallPan))   // sanity
        #expect(!RendererCull.needsRebuild(
            builtPaddedRect: builtPadded, currentVisibleRect: afterSmallPan,
            modelChanged: false, hasBuffer: true))
    }

    /// A series of small pans, each within the margin, must ALL be matrix-only.
    /// (Proves steady-state pan does ZERO buffer rebuild: the gate keeps returning
    /// false while the view stays inside the SAME cached padded rect.)
    @Test("repeated small pans within the margin all report NO rebuild")
    func steadyStatePanZeroRebuild() {
        let visible = rect(0, 0, 200, 200)
        let builtPadded = RendererCull.expanded(visible, byFraction: RendererCull.defaultMargin)
        // builtPadded = [-80,280]×[-80,280]; margin is 80 world units on each side.
        var current = visible
        for _ in 0..<8 {
            current = AABB(min: Vector(current.min.x + 5, current.min.y + 3, 0),
                           max: Vector(current.max.x + 5, current.max.y + 3, 0))
            // After 8 steps x has moved +40 (< 80 margin), y +24 — still inside.
            #expect(!RendererCull.needsRebuild(
                builtPaddedRect: builtPadded, currentVisibleRect: current,
                modelChanged: false, hasBuffer: true))
        }
    }

    /// A large pan that escapes the padded built rect reports rebuild needed.
    @Test("large pan escaping the padded built rect → rebuild needed")
    func largePanOutsideMarginRebuilds() {
        let visible = rect(0, 0, 100, 100)
        let builtPadded = RendererCull.expanded(visible, byFraction: RendererCull.defaultMargin)
        // builtPadded = [-40,140]×[-40,140]; a +200 pan escapes it.
        let afterLargePan = rect(200, 200, 300, 300)
        #expect(!RendererCull.contains(builtPadded, afterLargePan))   // sanity
        #expect(RendererCull.needsRebuild(
            builtPaddedRect: builtPadded, currentVisibleRect: afterLargePan,
            modelChanged: false, hasBuffer: true))
    }

    /// A zoom-OUT that grows the visible rect beyond the cached margin rebuilds;
    /// a zoom-IN (smaller visible rect, still inside) is matrix-only.
    @Test("zoom-in stays inside (no rebuild); zoom-out beyond margin rebuilds")
    func zoomRebuildBehavior() {
        let visible = rect(0, 0, 100, 100)
        let builtPadded = RendererCull.expanded(visible, byFraction: RendererCull.defaultMargin)

        // Zoom IN → smaller visible rect centered the same → inside → no rebuild.
        let zoomedIn = rect(25, 25, 75, 75)
        #expect(!RendererCull.needsRebuild(
            builtPaddedRect: builtPadded, currentVisibleRect: zoomedIn,
            modelChanged: false, hasBuffer: true))

        // Zoom OUT far → visible rect larger than the padded built rect → rebuild.
        let zoomedOut = rect(-100, -100, 200, 200)
        #expect(RendererCull.needsRebuild(
            builtPaddedRect: builtPadded, currentVisibleRect: zoomedOut,
            modelChanged: false, hasBuffer: true))
    }
}
