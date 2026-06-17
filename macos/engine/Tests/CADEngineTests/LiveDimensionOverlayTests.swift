//
//  LiveDimensionOverlayTests.swift
//  CADEngineTests
//
//  Tests the PURE, GPU-free placement math behind the live-dimension overlay
//  (live-dim Wave 2) plus the world→screen projection contract the overlay's `draw`
//  relies on. The actual `LiveDimensionOverlayView.draw(_:)` is GUI-only (it strokes
//  dotted CG lines + hosts `NSAttributedString` text), so it is NOT exercised here;
//  instead the testable seams are asserted directly:
//
//    • `LiveDimensionGeometry.labelBox(anchor:size:bounds:offset:padding:)` — the label
//      background box rect: sized to the text + padding, NUDGED off the anchor (so it
//      clears the crosshair sitting at the anchor) and CLAMPED fully on-screen.
//    • `Viewport.worldToScreen` — that a `LiveDimension`'s `from` / `to` / `labelAnchor`
//      project to the screen points the overlay strokes between (the +Y-up → screen-
//      Y-down flip the flipped host view depends on).
//
//  The helper lives in the non-importable LibreCADmacOS executable target and is
//  compiled into the test target via the `_SharedLiveDimensionOverlay.swift` symlink
//  (same trick as UCSAxisGeometryTests / EntityGripOverlayTests).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import AppKit
@testable import CADEngine

@MainActor
@Suite("Live-dimension overlay placement + projection")
struct LiveDimensionOverlayTests {

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let textSize = CGSize(width: 40, height: 14)
    private let padding: CGFloat = 4

    // MARK: Label box — sized to text + padding

    @Test("box is the text size plus padding on every side")
    func boxSizedToTextPlusPadding() {
        let box = LiveDimensionGeometry.labelBox(
            anchor: CGPoint(x: 400, y: 300), size: textSize, bounds: bounds, padding: padding)
        #expect(box.width == textSize.width + padding * 2)
        #expect(box.height == textSize.height + padding * 2)
    }

    // MARK: Label box — nudged OFF the anchor (clears the crosshair)

    @Test("box is nudged right and up of the anchor (off the crosshair)")
    func boxNudgedOffAnchor() {
        let anchor = CGPoint(x: 400, y: 300)
        let offset = CGSize(width: 12, height: -12)
        let box = LiveDimensionGeometry.labelBox(
            anchor: anchor, size: textSize, bounds: bounds, offset: offset, padding: padding)
        // Right of the anchor (positive x offset).
        #expect(box.minX == anchor.x + offset.width)
        // Up of the anchor: the box grows upward, so its BOTTOM edge sits at the
        // offset point — its TOP (minY, smaller on a Y-down view) is above the anchor.
        #expect(box.maxY == anchor.y + offset.height)
        #expect(box.maxY < anchor.y)            // box bottom is above the anchor
        // The anchor itself is NOT inside the box (so it never covers the cursor).
        #expect(!box.contains(anchor))
    }

    @Test("the crosshair anchor is never inside the placed box")
    func anchorNeverInsideBox() {
        // Sweep the anchor across the view; the box must never contain its own anchor.
        for x in stride(from: 0.0, through: 800.0, by: 100.0) {
            for y in stride(from: 0.0, through: 600.0, by: 100.0) {
                let anchor = CGPoint(x: x, y: y)
                let box = LiveDimensionGeometry.labelBox(
                    anchor: anchor, size: textSize, bounds: bounds, padding: padding)
                #expect(!box.contains(anchor))
            }
        }
    }

    // MARK: Label box — clamped fully on-screen

    @Test("box near the top-right corner is pulled back fully on-screen")
    func boxClampedTopRight() {
        // An anchor in the top-right: the default up-right nudge would push the box off
        // the top AND right edges; it must be clamped back inside the bounds.
        let anchor = CGPoint(x: 795, y: 5)
        let box = LiveDimensionGeometry.labelBox(
            anchor: anchor, size: textSize, bounds: bounds, padding: padding)
        #expect(box.minX >= bounds.minX)
        #expect(box.minY >= bounds.minY)
        #expect(box.maxX <= bounds.maxX)
        #expect(box.maxY <= bounds.maxY)
    }

    @Test("box near the bottom-left corner stays on-screen")
    func boxClampedBottomLeft() {
        let anchor = CGPoint(x: 2, y: 598)
        let box = LiveDimensionGeometry.labelBox(
            anchor: anchor, size: textSize, bounds: bounds, padding: padding)
        #expect(box.minX >= bounds.minX)
        #expect(box.minY >= bounds.minY)
        #expect(box.maxX <= bounds.maxX)
        #expect(box.maxY <= bounds.maxY)
    }

    @Test("any anchor across the view yields a fully on-screen box")
    func boxAlwaysOnScreen() {
        for x in stride(from: -50.0, through: 850.0, by: 50.0) {
            for y in stride(from: -50.0, through: 650.0, by: 50.0) {
                let box = LiveDimensionGeometry.labelBox(
                    anchor: CGPoint(x: x, y: y), size: textSize, bounds: bounds, padding: padding)
                #expect(box.minX >= bounds.minX)
                #expect(box.minY >= bounds.minY)
                #expect(box.maxX <= bounds.maxX)
                #expect(box.maxY <= bounds.maxY)
            }
        }
    }

    @Test("box pins to the min edge when the view is narrower than the box")
    func boxPinsWhenViewTooSmall() {
        // A view smaller than the box on both axes: pin to the min edge (clip the far
        // edge rather than hide the value).
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 8)
        let box = LiveDimensionGeometry.labelBox(
            anchor: CGPoint(x: 5, y: 4), size: textSize, bounds: tiny, padding: padding)
        #expect(box.minX == tiny.minX)
        #expect(box.minY == tiny.minY)
    }

    // MARK: world→screen projection of a LiveDimension's from / to / anchor

    @Test("from / to project to the screen points the overlay strokes between")
    func projectionOfFromTo() {
        // 2 pt/unit, centered on the origin, an 800×600 view → the world origin lands
        // at the view center, +X goes right, +Y goes UP (smaller screen-y).
        let vp = Viewport(scale: 2, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let from = vp.worldToScreen(Vector(0, 0))
        let to = vp.worldToScreen(Vector(10, 0))   // 10 units right
        #expect(from == CGPoint(x: 400, y: 300))   // origin at view center
        #expect(to == CGPoint(x: 420, y: 300))     // +10u × 2 = +20 px to the right
        #expect(to.x > from.x)                      // a +X dim line runs rightward
    }

    @Test("a +Y dim line runs UP the flipped screen (smaller screen-y)")
    func projectionRespectsYFlip() {
        let vp = Viewport(scale: 2, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let from = vp.worldToScreen(Vector(0, 0))
        let to = vp.worldToScreen(Vector(0, 10))   // 10 units up in world
        #expect(to.y < from.y)                      // world +Y → smaller screen-y (up)
        #expect(to == CGPoint(x: 400, y: 280))
    }

    @Test("the label anchor projects independently of from / to")
    func projectionOfLabelAnchor() {
        let vp = Viewport(scale: 2, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        // A LiveDimension whose label anchor is the dim-line midpoint.
        let dim = LiveDimension(kind: .linear(10), from: Vector(0, 0), to: Vector(10, 0),
                                label: "10", labelAnchor: Vector(5, 0))
        let anchorScreen = vp.worldToScreen(dim.labelAnchor)
        #expect(anchorScreen == CGPoint(x: 410, y: 300))   // midpoint of from(400)/to(420)
    }

    // MARK: dynamicInputChar — the keyDown gate decode (Wave V)

    @Test("dynamicInputChar accepts a single digit / `.` / `-` and rejects the rest")
    func dynamicInputCharDecode() {
        // Single digits decode to themselves.
        #expect(LiveDimensionGeometry.dynamicInputChar("5") == "5")
        #expect(LiveDimensionGeometry.dynamicInputChar("0") == "0")
        #expect(LiveDimensionGeometry.dynamicInputChar("9") == "9")
        // Decimal point + minus sign decode (for fractional / negative entry).
        #expect(LiveDimensionGeometry.dynamicInputChar(".") == ".")
        #expect(LiveDimensionGeometry.dynamicInputChar("-") == "-")
        // Multi-character strings are NOT a single editable char → nil (fall through).
        #expect(LiveDimensionGeometry.dynamicInputChar("12") == nil)
        // A letter is a tool-switch / chord key, never dynamic input → nil.
        #expect(LiveDimensionGeometry.dynamicInputChar("a") == nil)
        #expect(LiveDimensionGeometry.dynamicInputChar("A") == nil)
        // Punctuation that is not `.` / `-` → nil.
        #expect(LiveDimensionGeometry.dynamicInputChar("+") == nil)
        #expect(LiveDimensionGeometry.dynamicInputChar(",") == nil)
        // nil / empty `charactersIgnoringModifiers` → nil (no character to begin/append).
        #expect(LiveDimensionGeometry.dynamicInputChar(nil) == nil)
        #expect(LiveDimensionGeometry.dynamicInputChar("") == nil)
    }

    // MARK: caretX — insertion-bar offset = measured width of the typed string (Wave V)

    /// The exact attributes the overlay measures its label text with, so `caretX` lands
    /// on the same glyph metrics the chip draws.
    private var caretAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
    }

    @Test("caretX of an empty prefix is ~0")
    func caretXEmpty() {
        #expect(LiveDimensionGeometry.caretX(prefix: "", attributes: caretAttrs) == 0)
    }

    @Test("caretX equals the measured width of the typed string")
    func caretXEqualsMeasuredWidth() {
        let prefix = "123.4"
        let measured = NSAttributedString(string: prefix, attributes: caretAttrs).size().width
        #expect(LiveDimensionGeometry.caretX(prefix: prefix, attributes: caretAttrs) == measured)
    }

    @Test("caretX grows monotonically with prefix length")
    func caretXMonotonic() {
        let x0 = LiveDimensionGeometry.caretX(prefix: "", attributes: caretAttrs)
        let x1 = LiveDimensionGeometry.caretX(prefix: "1", attributes: caretAttrs)
        let x2 = LiveDimensionGeometry.caretX(prefix: "12", attributes: caretAttrs)
        let x3 = LiveDimensionGeometry.caretX(prefix: "123", attributes: caretAttrs)
        #expect(x0 < x1)
        #expect(x1 < x2)
        #expect(x2 < x3)
    }

    @Test("caretX is positive for any non-empty typed string")
    func caretXPositive() {
        #expect(LiveDimensionGeometry.caretX(prefix: "7", attributes: caretAttrs) > 0)
        #expect(LiveDimensionGeometry.caretX(prefix: "-", attributes: caretAttrs) > 0)
        #expect(LiveDimensionGeometry.caretX(prefix: ".", attributes: caretAttrs) > 0)
    }
}
