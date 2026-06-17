//
//  UCSAxisGeometryTests.swift
//  CADEngineTests
//
//  Tests the PURE UCS-axis geometry helper that drives the canvas UCS axis indicator
//  overlay (backlog #4b). `UCSAxisOverlayView.axisGeometry(origin:length:angle:)` maps
//  the on-screen UCS-origin anchor + a fixed arm length + the UCS angle to its two
//  screen-space axis-arm segments WITHOUT any AppKit drawing or GPU, so the
//  anchor+angle→segments contract is asserted directly:
//    • With the WORLD frame (`angle == 0`, the default):
//      – +X arm runs from the origin toward INCREASING screen-x (rightward).
//      – +Y arm runs from the origin toward DECREASING screen-y (upward on the flipped,
//        Y-down host view — world +Y points up).
//    • With a ROTATED UCS the arms rotate by the UCS angle, mapping the world direction
//      `(dx, dy)` to the flipped screen delta `(dx, -dy)`.
//    • The arms are a CONSTANT on-screen length (independent of the anchor position),
//      i.e. only the anchor moves with pan/zoom; the gizmo never scales.
//
//  The helper lives in the non-importable LibreCADmacOS executable target and is
//  compiled into the test target via the `_SharedUCSAxisOverlay.swift` symlink (same
//  trick as CrosshairStyleTests / ToolPreviewOverlayTests).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("UCS axis gizmo geometry")
struct UCSAxisGeometryTests {

    private let origin = CGPoint(x: 300, y: 200)
    private let length = UCSAxisOverlayView.armLength

    // MARK: +X arm — rightward (increasing screen-x), flat in y

    @Test("X arm starts at the origin anchor")
    func xArmStartsAtOrigin() {
        let g = UCSAxisOverlayView.axisGeometry(origin: origin, length: length)
        #expect(g.xArm.from == origin)
    }

    @Test("X arm runs toward increasing screen-x with no y change")
    func xArmRightward() {
        let g = UCSAxisOverlayView.axisGeometry(origin: origin, length: length)
        #expect(g.xArm.to == CGPoint(x: origin.x + length, y: origin.y))
        #expect(g.xArm.to.x > g.xArm.from.x)          // rightward
        #expect(g.xArm.to.y == g.xArm.from.y)         // horizontal
    }

    // MARK: +Y arm — upward (DECREASING screen-y on the flipped view), flat in x

    @Test("Y arm starts at the origin anchor")
    func yArmStartsAtOrigin() {
        let g = UCSAxisOverlayView.axisGeometry(origin: origin, length: length)
        #expect(g.yArm.from == origin)
    }

    @Test("Y arm runs toward DECREASING screen-y (world +Y is up on a flipped view)")
    func yArmUpward() {
        let g = UCSAxisOverlayView.axisGeometry(origin: origin, length: length)
        #expect(g.yArm.to == CGPoint(x: origin.x, y: origin.y - length))
        #expect(g.yArm.to.y < g.yArm.from.y)          // upward (Y-down screen ⇒ smaller y)
        #expect(g.yArm.to.x == g.yArm.from.x)         // vertical
    }

    // MARK: Fixed on-screen size — arms are `length`, independent of the anchor

    @Test("both arms are exactly the requested fixed length")
    func armsAreFixedLength() {
        let g = UCSAxisOverlayView.axisGeometry(origin: origin, length: length)
        #expect(g.xArm.to.x - g.xArm.from.x == length)
        #expect(g.yArm.from.y - g.yArm.to.y == length)
    }

    @Test("arm length is independent of the anchor position (gizmo does not scale)")
    func armLengthIndependentOfAnchor() {
        let a = UCSAxisOverlayView.axisGeometry(origin: CGPoint(x: 10, y: 10), length: length)
        let b = UCSAxisOverlayView.axisGeometry(origin: CGPoint(x: 900, y: 700), length: length)
        // Same arm spans regardless of where the origin lands on screen.
        #expect(a.xArm.to.x - a.xArm.from.x == b.xArm.to.x - b.xArm.from.x)
        #expect(a.yArm.from.y - a.yArm.to.y == b.yArm.from.y - b.yArm.to.y)
    }

    // MARK: The anchor tracks pan/zoom — different origins ⇒ translated (not scaled) gizmos

    @Test("a different anchor translates both arms by the same delta")
    func anchorTranslatesGizmo() {
        let g0 = UCSAxisOverlayView.axisGeometry(origin: CGPoint(x: 100, y: 100), length: length)
        let g1 = UCSAxisOverlayView.axisGeometry(origin: CGPoint(x: 150, y: 80), length: length)
        let dx = g1.xArm.from.x - g0.xArm.from.x
        let dy = g1.xArm.from.y - g0.xArm.from.y
        #expect(dx == 50)
        #expect(dy == -20)
        // The arm endpoints translate by the SAME delta (rigid translation, no scale).
        #expect(g1.xArm.to.x - g0.xArm.to.x == dx)
        #expect(g1.yArm.to.y - g0.yArm.to.y == dy)
    }

    @Test("two distinct anchors yield distinct geometries")
    func distinctAnchorsDiffer() {
        let g0 = UCSAxisOverlayView.axisGeometry(origin: CGPoint(x: 0, y: 0), length: length)
        let g1 = UCSAxisOverlayView.axisGeometry(origin: CGPoint(x: 5, y: 5), length: length)
        #expect(g0 != g1)
    }

    // MARK: UCS angle — the world frame (angle 0) is byte-identical to the old helper

    @Test("angle 0 reduces EXACTLY to the prior axis-aligned geometry (world frame)")
    func worldAngleIdenticalToDefault() {
        let withoutAngle = UCSAxisOverlayView.axisGeometry(origin: origin, length: length)
        let withZero = UCSAxisOverlayView.axisGeometry(origin: origin, length: length, angle: 0)
        #expect(withoutAngle == withZero)
        // And those equal the literal axis-aligned arms.
        #expect(withZero.xArm.to == CGPoint(x: origin.x + length, y: origin.y))
        #expect(withZero.yArm.to == CGPoint(x: origin.x, y: origin.y - length))
    }

    // MARK: UCS angle — a rotated UCS rotates the arms into flipped screen space

    @Test("90° UCS: +X arm points up on screen, +Y arm points left")
    func rotated90() {
        // UCS angle +90° CCW in world: +X world dir → (0, 1) → screen (0, -length) (UP);
        // +Y world dir → (-1, 0) → screen (-length, 0) (LEFT).
        let g = UCSAxisOverlayView.axisGeometry(
            origin: origin, length: length, angle: .pi / 2)
        let tol: CGFloat = 1e-9
        #expect(g.xArm.from == origin)
        #expect(abs(g.xArm.to.x - origin.x) < tol)            // X arm: no screen-x change
        #expect(abs(g.xArm.to.y - (origin.y - length)) < tol) // X arm: up the screen
        #expect(g.yArm.from == origin)
        #expect(abs(g.yArm.to.x - (origin.x - length)) < tol) // Y arm: left
        #expect(abs(g.yArm.to.y - origin.y) < tol)            // Y arm: no screen-y change
    }

    @Test("the gizmo anchors at the supplied (UCS) origin regardless of angle")
    func anchorsAtSuppliedOrigin() {
        let o = CGPoint(x: 420, y: 130)
        let g = UCSAxisOverlayView.axisGeometry(origin: o, length: length, angle: .pi / 3)
        #expect(g.xArm.from == o)
        #expect(g.yArm.from == o)
    }

    @Test("arms stay the fixed length at any UCS angle (rotation, not scale)")
    func rotatedArmsKeepLength() {
        let g = UCSAxisOverlayView.axisGeometry(
            origin: origin, length: length, angle: .pi / 5)
        let xLen = hypot(g.xArm.to.x - g.xArm.from.x, g.xArm.to.y - g.xArm.from.y)
        let yLen = hypot(g.yArm.to.x - g.yArm.from.x, g.yArm.to.y - g.yArm.from.y)
        #expect(abs(xLen - length) < 1e-9)
        #expect(abs(yLen - length) < 1e-9)
    }

    @Test("X and Y arms stay perpendicular at any UCS angle")
    func armsStayPerpendicular() {
        let g = UCSAxisOverlayView.axisGeometry(
            origin: origin, length: length, angle: 0.7)
        let xv = CGVector(dx: g.xArm.to.x - g.xArm.from.x, dy: g.xArm.to.y - g.xArm.from.y)
        let yv = CGVector(dx: g.yArm.to.x - g.yArm.from.x, dy: g.yArm.to.y - g.yArm.from.y)
        let dot = xv.dx * yv.dx + xv.dy * yv.dy
        #expect(abs(dot) < 1e-9)
    }

    // MARK: The documented fixed arm length

    @Test("default arm length is the documented 24pt fixed on-screen size")
    func defaultArmLength() {
        #expect(UCSAxisOverlayView.armLength == 24)
    }
}
