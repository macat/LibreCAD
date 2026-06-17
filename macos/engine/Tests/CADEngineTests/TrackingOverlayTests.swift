//
//  TrackingOverlayTests.swift
//  CADEngineTests
//
//  Tests the PURE, GPU-free geometry behind the snap-tracking overlay (snap-tracking
//  Wave 3): `TrackingOverlayGeometry.clipRayToBounds(origin:far:bounds:)` — the screen-
//  space Liang-Barsky clip the overlay applies to the (effectively-infinite) polar ray
//  before stroking it. The actual `TrackingOverlayView.draw(_:)` is GUI-only (it strokes
//  a dotted CG ray + hosts an `NSAttributedString` chip), so it is NOT exercised here;
//  the clip helper is the only non-trivial geometry the view owns and is asserted
//  directly. (The readout chip reuses `LiveDimensionGeometry.labelBox`, covered by
//  `LiveDimensionOverlayTests`.)
//
//  The helper lives in the non-importable LibreCADmacOS executable target and is compiled
//  into the test target via the `_SharedTrackingOverlay.swift` symlink (same trick as
//  `LiveDimensionOverlayTests` / `UCSAxisGeometryTests` / `EntityGripOverlayTests`).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import AppKit
@testable import CADEngine

@MainActor
@Suite("Snap-tracking overlay polar-ray clip")
struct TrackingOverlayTests {

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// How close two screen points must be to count as equal (clip arithmetic is exact
    /// here but tolerate float noise).
    private func near(_ a: CGPoint, _ b: CGPoint, eps: CGFloat = 1e-6) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    // MARK: Both endpoints inside → unchanged

    @Test("a segment fully inside the bounds is returned unchanged")
    func fullyInside() {
        let o = CGPoint(x: 100, y: 100)
        let f = CGPoint(x: 700, y: 500)
        let clipped = TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds)
        let (a, b) = try! #require(clipped)
        #expect(near(a, o))
        #expect(near(b, f))
    }

    // MARK: Origin inside, far outside (the real polar-ray case) → far end clipped to edge

    @Test("an inside origin with a far-away (≈1e9) far end is clipped to the right edge")
    func originInsideFarFarAway() {
        // The real case: the ray's far end is ~1e9 units out. A horizontal ray from the
        // view center must clip at the right edge (x == maxX), Y unchanged.
        let o = CGPoint(x: 400, y: 300)
        let f = CGPoint(x: 1e9, y: 300)
        let (a, b) = try! #require(
            TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds))
        #expect(near(a, o))                       // near end is the (inside) origin
        #expect(abs(b.x - bounds.maxX) < 1e-3)    // far end pinned to the right edge
        #expect(abs(b.y - 300) < 1e-3)            // horizontal: Y unchanged
    }

    @Test("an inside origin with a far end up-and-out clips on the first edge crossed")
    func originInsideDiagonal() {
        // A diagonal ray from center toward the top-right; the far end clips on whichever
        // edge it crosses first. Result must stay inside the bounds and lie on the segment.
        let o = CGPoint(x: 400, y: 300)
        let f = CGPoint(x: 400 + 1e9, y: 300 - 1e9)   // up-right (Y-down: smaller y = up)
        let (a, b) = try! #require(
            TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds))
        #expect(near(a, o))
        // Endpoint clamped on-screen, on the top OR right edge.
        #expect(b.x <= bounds.maxX + 1e-3 && b.x >= bounds.minX - 1e-3)
        #expect(b.y <= bounds.maxY + 1e-3 && b.y >= bounds.minY - 1e-3)
        let onRight = abs(b.x - bounds.maxX) < 1e-3
        let onTop = abs(b.y - bounds.minY) < 1e-3
        #expect(onRight || onTop)
    }

    // MARK: A segment crossing the view (both ends outside) → both ends clipped

    @Test("a segment crossing the view with both ends outside clips to both edges")
    func crossingBothOutside() {
        // A horizontal line through the middle, both ends well outside.
        let o = CGPoint(x: -500, y: 300)
        let f = CGPoint(x: 1300, y: 300)
        let (a, b) = try! #require(
            TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds))
        #expect(abs(a.x - bounds.minX) < 1e-3)    // entered at the left edge
        #expect(abs(b.x - bounds.maxX) < 1e-3)    // left at the right edge
        #expect(abs(a.y - 300) < 1e-3)
        #expect(abs(b.y - 300) < 1e-3)
    }

    // MARK: Fully outside → nil

    @Test("a segment entirely outside (to the right) returns nil")
    func fullyOutsideRight() {
        let o = CGPoint(x: 900, y: 300)
        let f = CGPoint(x: 1e9, y: 300)
        #expect(TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds) == nil)
    }

    @Test("a segment entirely above the view (parallel to an edge) returns nil")
    func fullyOutsideAboveParallel() {
        // A horizontal segment above the top edge (y < 0): parallel to top/bottom, outside.
        let o = CGPoint(x: 100, y: -50)
        let f = CGPoint(x: 700, y: -50)
        #expect(TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds) == nil)
    }

    @Test("a diagonal segment that misses the corner returns nil")
    func diagonalMissesCorner() {
        // A diagonal that cuts ACROSS the top-left corner's EXTERIOR — it crosses the
        // x==minX line at y==-50 (above the top) and the y==minY line at x==-50 (left of
        // the left edge), so it never enters the rect. (Verified by hand: at x=0 ⇒ y=-50,
        // at y=0 ⇒ x=-50, both outside.)
        let o = CGPoint(x: -100, y: 50)
        let f = CGPoint(x: 50, y: -100)
        #expect(TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds) == nil)
    }

    // MARK: Origin exactly at an edge

    @Test("an origin exactly on the left edge with a far end inside is kept from the edge")
    func originOnLeftEdge() {
        let o = CGPoint(x: 0, y: 300)          // on the left edge (minX)
        let f = CGPoint(x: 1e9, y: 300)        // far to the right
        let (a, b) = try! #require(
            TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds))
        #expect(abs(a.x - bounds.minX) < 1e-3) // near end stays at the left edge
        #expect(abs(b.x - bounds.maxX) < 1e-3) // far end clips to the right edge
    }

    @Test("an origin at the top-left corner with a far end inside is kept")
    func originAtCorner() {
        let o = CGPoint(x: 0, y: 0)            // top-left corner
        let f = CGPoint(x: 800, y: 600)        // bottom-right corner
        let (a, b) = try! #require(
            TrackingOverlayGeometry.clipRayToBounds(origin: o, far: f, bounds: bounds))
        #expect(near(a, o))
        #expect(near(b, f))
    }

    // MARK: Degenerate (zero-length) segment

    @Test("a degenerate (point) segment inside the bounds returns the point twice")
    func degenerateInside() {
        let p = CGPoint(x: 400, y: 300)
        let (a, b) = try! #require(
            TrackingOverlayGeometry.clipRayToBounds(origin: p, far: p, bounds: bounds))
        #expect(near(a, p))
        #expect(near(b, p))
    }

    @Test("a degenerate (point) segment outside the bounds returns nil")
    func degenerateOutside() {
        let p = CGPoint(x: 900, y: 300)
        #expect(TrackingOverlayGeometry.clipRayToBounds(origin: p, far: p, bounds: bounds) == nil)
    }

    // MARK: The clipped sub-segment always lies on the original line + inside bounds

    @Test("for a sweep of far directions the clipped segment stays on-line and in-bounds")
    func sweepStaysOnLineAndInBounds() {
        let o = CGPoint(x: 400, y: 300)
        // Sweep the far end around a big circle (≈1e6 radius) — every result must lie on
        // the o→far line and be clamped inside the bounds.
        for deg in stride(from: 0.0, to: 360.0, by: 15.0) {
            let r = 1e6
            let f = CGPoint(x: o.x + r * cos(deg * .pi / 180),
                            y: o.y + r * sin(deg * .pi / 180))
            guard let (a, b) = TrackingOverlayGeometry.clipRayToBounds(
                origin: o, far: f, bounds: bounds) else { continue }
            for pt in [a, b] {
                // Inside (with a small tolerance for the edge).
                #expect(pt.x >= bounds.minX - 1e-3 && pt.x <= bounds.maxX + 1e-3)
                #expect(pt.y >= bounds.minY - 1e-3 && pt.y <= bounds.maxY + 1e-3)
                // On the o→far line: the cross product of (pt-o) and (f-o) is ~0.
                let cross = (pt.x - o.x) * (f.y - o.y) - (pt.y - o.y) * (f.x - o.x)
                #expect(abs(cross) < 1.0)   // scaled by the ≈1e6 magnitude
            }
        }
    }
}
