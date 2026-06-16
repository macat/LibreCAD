//
//  CrosshairStyleTests.swift
//  CADEngineTests
//
//  Tests the PURE crosshair-extent helper that wires the `crosshairStyle` Appearance
//  preference (`AppSettings.Key.crosshairStyle`, a `CrosshairStyle`) to the canvas
//  crosshair overlay. `CrosshairOverlayView.crosshairGeometry(style:bounds:center:)`
//  maps each style to its screen-space line segments WITHOUT any AppKit drawing or
//  GPU, so the style→extent contract is asserted directly:
//    • `.full`  — both lines span the WHOLE view bounds (the "spider" cursor).
//    • `.small` — a short, fixed-length cross local to the cursor.
//    • `.none`  — no cross lines at all (empty geometry).
//
//  The helper + `CrosshairStyle` live in the non-importable LibreCADmacOS executable
//  target and are compiled into the test target via the `_SharedCrosshairOverlay.swift`
//  and `_SharedAppSettings.swift` symlinks (same trick as ToolPreviewOverlayTests).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Crosshair style → extent")
struct CrosshairStyleTests {

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let center = CGPoint(x: 300, y: 200)

    // MARK: .full — spans the whole view

    @Test("full style: vertical line spans the full view height through the center x")
    func fullSpansHeight() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .full, bounds: bounds, center: center)
        let v = try! #require(g.vertical)
        #expect(v.from == CGPoint(x: center.x, y: bounds.minY))
        #expect(v.to == CGPoint(x: center.x, y: bounds.maxY))
    }

    @Test("full style: horizontal line spans the full view width through the center y")
    func fullSpansWidth() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .full, bounds: bounds, center: center)
        let h = try! #require(g.horizontal)
        #expect(h.from == CGPoint(x: bounds.minX, y: center.y))
        #expect(h.to == CGPoint(x: bounds.maxX, y: center.y))
    }

    @Test("full style is not empty (draws lines)")
    func fullNotEmpty() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .full, bounds: bounds, center: center)
        #expect(!g.isEmpty)
    }

    // MARK: .small — short fixed-length cross local to the cursor

    @Test("small style: vertical arm is the fixed length about the center, not the view")
    func smallVerticalArm() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .small, bounds: bounds, center: center)
        let v = try! #require(g.vertical)
        let arm = CrosshairOverlayView.smallArmHalf
        #expect(v.from == CGPoint(x: center.x, y: center.y - arm))
        #expect(v.to == CGPoint(x: center.x, y: center.y + arm))
        // Critically: the small cross does NOT reach the view edges.
        #expect(v.from.y > bounds.minY)
        #expect(v.to.y < bounds.maxY)
    }

    @Test("small style: horizontal arm is the fixed length about the center, not the view")
    func smallHorizontalArm() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .small, bounds: bounds, center: center)
        let h = try! #require(g.horizontal)
        let arm = CrosshairOverlayView.smallArmHalf
        #expect(h.from == CGPoint(x: center.x - arm, y: center.y))
        #expect(h.to == CGPoint(x: center.x + arm, y: center.y))
        #expect(h.from.x > bounds.minX)
        #expect(h.to.x < bounds.maxX)
    }

    @Test("small arm half-length is the documented total span (2x arm)")
    func smallTotalSpan() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .small, bounds: bounds, center: center)
        let v = try! #require(g.vertical)
        #expect(v.to.y - v.from.y == CrosshairOverlayView.smallArmHalf * 2)
    }

    // MARK: .none — no cross lines

    @Test("none style: no vertical and no horizontal line")
    func noneHasNoLines() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .none, bounds: bounds, center: center)
        #expect(g.vertical == nil)
        #expect(g.horizontal == nil)
    }

    @Test("none style is empty")
    func noneIsEmpty() {
        let g = CrosshairOverlayView.crosshairGeometry(style: .none, bounds: bounds, center: center)
        #expect(g.isEmpty)
    }

    // MARK: Distinctness — the three styles really differ

    @Test("the three styles yield distinct geometries")
    func stylesDiffer() {
        let full = CrosshairOverlayView.crosshairGeometry(style: .full, bounds: bounds, center: center)
        let small = CrosshairOverlayView.crosshairGeometry(style: .small, bounds: bounds, center: center)
        let none = CrosshairOverlayView.crosshairGeometry(style: .none, bounds: bounds, center: center)
        #expect(full != small)
        #expect(full != none)
        #expect(small != none)
    }

    // MARK: The preference default is .full (preserves the prior full-window "spider" crosshair)

    @Test("AppSettings default crosshair style is .full")
    func defaultIsFull() {
        #expect(AppSettings.Default.crosshairStyle == .full)
    }
}
