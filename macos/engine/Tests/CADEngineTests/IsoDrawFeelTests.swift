//
//  IsoDrawFeelTests.swift
//  CADEngineTests
//
//  Wave 3+4 ISOMETRIC DRAW-FEEL kernels (UNWIRED — the CanvasModel state that drives
//  them is the wire-wave). Three pure engine/overlay kernels are asserted here:
//
//    1. ISO-ORTHO (`OrthoConstraint.constrain(_:relativeTo:isoPlane:)`) — the iso
//       analog of the H/V ortho lock: it locks the candidate point to the NEAREST of
//       the active plane's two iso-axis directions through the reference. The
//       rectangular `constrain(_:relativeTo:)` path is regression-locked unchanged.
//
//    2. ISO CROSSHAIR GEOMETRY (`CrosshairOverlayView.crosshairGeometry(…axisAngles:)`)
//       — the two cross lines run along two ARBITRARY screen-space angles (the active
//       plane's axes) instead of horizontal+vertical; `axisAngles == nil` reproduces
//       the rectangular geometry byte-for-byte. (The overlay helper lives in the
//       app-only LibreCADmacOS target, reached via the `_SharedCrosshairOverlay.swift`
//       symlink, same as `CrosshairStyleTests`.)
//
//    3. ISO-CIRCLE (`EllipseTool.Mode.isocircle` / `EllipseTool.isocircle(…)`) — a
//       center+radius isometric circle: an `EllipseData` whose major axis runs along
//       the plane's LONG iso diagonal and whose `ratio == tan(30°) ≈ 0.57735`. The
//       ratio is PINNED (a wrong ratio is the likely silent defect) and the per-plane
//       major-axis orientation is asserted (top → 0°, left → 120°, right → 60°).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - 1. Iso-ortho axis lock

@Suite("Iso-ortho axis lock")
struct IsoOrthoConstraintTests {

    private let eps = 1e-9

    /// The unit direction of a vector (relative to a reference), for asserting the
    /// locked point lies ON the expected iso axis.
    private func dir(_ p: Vector, from ref: Vector) -> Vector {
        let d = p - ref
        return d / d.magnitude
    }

    @Test("top plane: a candidate near the 30° axis locks onto the 30° axis")
    func topLocksTo30() {
        let ref = Vector(5, 5)
        // A point a bit above the 30° ray (closer to 30° than to 150°).
        let raw = ref + Vector(angle: .pi / 6) * 10 + Vector(0, 0.3)
        let out = OrthoConstraint.constrain(raw, relativeTo: ref, isoPlane: .top)
        let u = dir(out, from: ref)
        // Locked direction is the 30° unit vector.
        #expect(abs(u.x - cos(.pi / 6)) < eps)
        #expect(abs(u.y - sin(.pi / 6)) < eps)
    }

    @Test("top plane: a candidate near the 150° axis locks onto the 150° axis")
    func topLocksTo150() {
        let ref = Vector(5, 5)
        let raw = ref + Vector(angle: 5 * .pi / 6) * 8 + Vector(0.2, 0)
        let out = OrthoConstraint.constrain(raw, relativeTo: ref, isoPlane: .top)
        let u = dir(out, from: ref)
        #expect(abs(u.x - cos(5 * .pi / 6)) < eps)
        #expect(abs(u.y - sin(5 * .pi / 6)) < eps)
    }

    @Test("left plane axes are 90° (vertical) and 150°")
    func leftPlaneAxes() {
        let ref = Vector(0, 0)
        // Near vertical (90°).
        let vRaw = Vector(0.1, 12)
        let vOut = OrthoConstraint.constrain(vRaw, relativeTo: ref, isoPlane: .left)
        let vu = dir(vOut, from: ref)
        #expect(abs(vu.x - 0) < eps)
        #expect(abs(vu.y - 1) < eps)
        // Near 150°.
        let dRaw = Vector(angle: 5 * .pi / 6) * 9 + Vector(0, 0.2)
        let dOut = OrthoConstraint.constrain(dRaw, relativeTo: ref, isoPlane: .left)
        let du = dir(dOut, from: ref)
        #expect(abs(du.x - cos(5 * .pi / 6)) < eps)
        #expect(abs(du.y - sin(5 * .pi / 6)) < eps)
    }

    @Test("right plane axes are 30° and 90° (vertical)")
    func rightPlaneAxes() {
        let ref = Vector(0, 0)
        // Near 30°.
        let dRaw = Vector(angle: .pi / 6) * 7 + Vector(0, 0.2)
        let dOut = OrthoConstraint.constrain(dRaw, relativeTo: ref, isoPlane: .right)
        let du = dir(dOut, from: ref)
        #expect(abs(du.x - cos(.pi / 6)) < eps)
        #expect(abs(du.y - sin(.pi / 6)) < eps)
        // Near vertical (90°).
        let vRaw = Vector(-0.1, 11)
        let vOut = OrthoConstraint.constrain(vRaw, relativeTo: ref, isoPlane: .right)
        let vu = dir(vOut, from: ref)
        #expect(abs(vu.x - 0) < eps)
        #expect(abs(vu.y - 1) < eps)
    }

    @Test("the locked point is the projection of the offset onto the chosen axis")
    func locksToProjection() {
        let ref = Vector(2, 3)
        let axis = Vector(angle: .pi / 6)          // 30°
        // Reach 10 along the axis, plus a small perpendicular nudge.
        let raw = ref + axis * 10 + Vector(angle: .pi / 6 + .pi / 2) * 0.5
        let out = OrthoConstraint.constrain(raw, relativeTo: ref, isoPlane: .top)
        // The projection magnitude should be ≈ 10 (the nudge is perpendicular).
        let proj = (out - ref).magnitude
        #expect(abs(proj - 10) < 1e-6)
    }

    @Test("the lock follows the offset onto the NEGATIVE half of an axis")
    func locksToNegativeHalf() {
        let ref = Vector(0, 0)
        // Down-left along the (180°+30°) ray — the 30° axis line, negative side.
        let raw = Vector(angle: .pi / 6) * -6 + Vector(0, -0.1)
        let out = OrthoConstraint.constrain(raw, relativeTo: ref, isoPlane: .top)
        // Sits on the 30° axis line, on the negative side (x < 0, y < 0).
        #expect(out.x < 0)
        #expect(out.y < 0)
        // Direction (unit) is the NEGATIVE 30° vector.
        let u = dir(out, from: ref)
        #expect(abs(u.x - (-cos(.pi / 6))) < eps)
        #expect(abs(u.y - (-sin(.pi / 6))) < eps)
    }

    @Test("invalid inputs pass through unchanged (no manufactured coordinate)")
    func invalidPassThrough() {
        let ref = Vector(1, 1)
        #expect(!OrthoConstraint.constrain(.invalid, relativeTo: ref, isoPlane: .top).valid)
        let validRaw = Vector(5, 9)
        let out = OrthoConstraint.constrain(validRaw, relativeTo: .invalid, isoPlane: .top)
        #expect(out.x == 5 && out.y == 9)
    }

    // MARK: Regression-lock: the rectangular path is UNCHANGED.

    @Test("the non-iso constrain() still locks horizontal when |dx| >= |dy|")
    func rectangularHorizontalUnchanged() {
        let ref = Vector(10, 5)
        let out = OrthoConstraint.constrain(Vector(30, 8), relativeTo: ref)
        #expect(out.x == 30 && out.y == 5)
    }

    @Test("the non-iso constrain() still locks vertical when |dy| > |dx|")
    func rectangularVerticalUnchanged() {
        let ref = Vector(10, 5)
        let out = OrthoConstraint.constrain(Vector(13, 40), relativeTo: ref)
        #expect(out.x == 10 && out.y == 40)
    }
}

// MARK: - 2. Iso crosshair geometry

@MainActor
@Suite("Iso crosshair geometry")
struct IsoCrosshairGeometryTests {

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let center = CGPoint(x: 400, y: 300)   // dead center, so a clip is symmetric
    private let eps = 1e-6

    /// The angle (in [-π, π)) of a segment, for asserting the line orientation.
    private func segmentAngle(_ seg: (from: CGPoint, to: CGPoint)) -> Double {
        atan2(Double(seg.to.y - seg.from.y), Double(seg.to.x - seg.from.x))
    }

    /// Whether two angles describe the SAME (undirected) line — equal modulo π.
    private func sameLine(_ a: Double, _ b: Double) -> Bool {
        var d = (a - b).truncatingRemainder(dividingBy: .pi)
        if d < 0 { d += .pi }
        return d < eps || (.pi - d) < eps
    }

    // MARK: nil axisAngles → byte-identical to the rectangular geometry.

    @Test("nil axisAngles reproduces the rectangular full geometry exactly")
    func nilFullMatchesRectangular() {
        let iso = CrosshairOverlayView.crosshairGeometry(
            style: .full, bounds: bounds, center: center, axisAngles: nil)
        let rect = CrosshairOverlayView.crosshairGeometry(
            style: .full, bounds: bounds, center: center)
        #expect(iso == rect)
    }

    @Test("nil axisAngles reproduces the rectangular small geometry exactly")
    func nilSmallMatchesRectangular() {
        let iso = CrosshairOverlayView.crosshairGeometry(
            style: .small, bounds: bounds, center: center, axisAngles: nil)
        let rect = CrosshairOverlayView.crosshairGeometry(
            style: .small, bounds: bounds, center: center)
        #expect(iso == rect)
    }

    @Test("nil axisAngles + none style is empty")
    func nilNoneEmpty() {
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .none, bounds: bounds, center: center, axisAngles: nil)
        #expect(g.isEmpty)
    }

    // MARK: full style — the two lines run along the supplied axis angles.

    @Test("full iso cross: each line runs along its supplied axis angle (top: 30°/150°)")
    func fullLinesFollowTopAxes() {
        // Top plane in SCREEN space (Y-down): world 30°/150° become screen -30°/-150°
        // after the single Viewport Y-flip. Pass the screen angles directly.
        let a1 = -Double.pi / 6          // -30°
        let a2 = -(5 * Double.pi / 6)    // -150°
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .full, bounds: bounds, center: center, axisAngles: (a1, a2))
        let v = try! #require(g.vertical)    // axis 1
        let h = try! #require(g.horizontal)  // axis 2
        #expect(sameLine(segmentAngle(v), a1))
        #expect(sameLine(segmentAngle(h), a2))
    }

    @Test("full iso cross: both clipped lines pass through the center")
    func fullLinesThroughCenter() {
        let a1 = Double.pi / 6
        let a2 = 5 * Double.pi / 6
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .full, bounds: bounds, center: center, axisAngles: (a1, a2))
        let v = try! #require(g.vertical)
        // The center lies between the two clipped endpoints (collinear & bracketed).
        let onLine = abs((Double(v.to.x - v.from.x)) * (Double(center.y - v.from.y))
                       - (Double(v.to.y - v.from.y)) * (Double(center.x - v.from.x)))
        #expect(onLine < 1e-3)
    }

    @Test("full iso cross clips to the bounds (endpoints on the rect border)")
    func fullLinesClipToBounds() {
        let a1 = Double.pi / 6
        let a2 = 5 * Double.pi / 6
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .full, bounds: bounds, center: center, axisAngles: (a1, a2))
        let v = try! #require(g.vertical)
        // An endpoint of the clipped line lies on the rect boundary.
        func onBorder(_ p: CGPoint) -> Bool {
            abs(p.x - bounds.minX) < eps || abs(p.x - bounds.maxX) < eps
                || abs(p.y - bounds.minY) < eps || abs(p.y - bounds.maxY) < eps
        }
        #expect(onBorder(v.from))
        #expect(onBorder(v.to))
    }

    @Test("axis-aligned angle (0) reproduces a full-width horizontal span")
    func axisAlignedReproducesFullSpan() {
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .full, bounds: bounds, center: center,
            axisAngles: (0, Double.pi / 2))
        let v = try! #require(g.vertical)     // angle 0 → horizontal line
        // Spans the full width at the center's y.
        let xs = [Double(v.from.x), Double(v.to.x)].sorted()
        #expect(abs(xs[0] - Double(bounds.minX)) < eps)
        #expect(abs(xs[1] - Double(bounds.maxX)) < eps)
        #expect(abs(Double(v.from.y) - Double(center.y)) < eps)
    }

    // MARK: small style — short arms rotated to the axis angles.

    @Test("small iso cross: each arm is the fixed length, rotated to its axis angle")
    func smallArmsFollowAxes() {
        let a1 = -Double.pi / 6
        let a2 = -(5 * Double.pi / 6)
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .small, bounds: bounds, center: center, axisAngles: (a1, a2))
        let v = try! #require(g.vertical)
        let h = try! #require(g.horizontal)
        let arm = Double(CrosshairOverlayView.smallArmHalf)
        // Full length is 2·arm and the orientation matches the axis angle.
        let lv = hypot(Double(v.to.x - v.from.x), Double(v.to.y - v.from.y))
        let lh = hypot(Double(h.to.x - h.from.x), Double(h.to.y - h.from.y))
        #expect(abs(lv - 2 * arm) < eps)
        #expect(abs(lh - 2 * arm) < eps)
        #expect(sameLine(segmentAngle(v), a1))
        #expect(sameLine(segmentAngle(h), a2))
    }

    @Test("none style with axisAngles still draws nothing")
    func noneStyleEmptyEvenWithAxes() {
        let g = CrosshairOverlayView.crosshairGeometry(
            style: .none, bounds: bounds, center: center,
            axisAngles: (Double.pi / 6, 5 * Double.pi / 6))
        #expect(g.isEmpty)
    }
}

// MARK: - 3. Iso-circle ellipse mode

@Suite("Iso-circle ellipse mode")
struct IsoCircleEllipseTests {

    private let eps = 1e-9

    /// Pulls the single committed EllipseData out of a `.commit` outcome.
    private func committedEllipse(_ outcome: ToolOutcome) -> EllipseData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .ellipse(let d) = record.kind else { return nil }
        return d
    }

    // MARK: The pinned ratio — tan(30°) for ALL planes (the likely silent defect).

    @Test("isoCircleRatio is exactly tan(30°) ≈ 0.57735")
    func ratioConstantIsTan30() {
        #expect(abs(EllipseTool.isoCircleRatio - tan(Double.pi / 6)) < eps)
        #expect(abs(EllipseTool.isoCircleRatio - 0.5773502691896257) < 1e-15)
    }

    @Test("every plane's isocircle has ratio == tan(30°)")
    func everyPlaneRatioPinned() {
        for plane in IsoPlane.allCases {
            let data = try! #require(
                EllipseTool.isocircle(center: Vector(0, 0), radiusPoint: Vector(5, 0), plane: plane))
            #expect(abs(data.ratio - tan(Double.pi / 6)) < eps,
                    "plane \(plane) ratio \(data.ratio) != tan(30°)")
        }
    }

    // MARK: Per-plane major-axis orientation (top 0°, left 120°, right 60°).

    /// Undirected angle equality (modulo π) for an axis direction.
    private func axisAngle(_ majorP: Vector) -> Double {
        var a = atan2(majorP.y, majorP.x)
        if a < 0 { a += .pi }              // fold to [0, π)
        if a >= .pi - 1e-12 { a -= .pi }
        return a
    }

    @Test("top plane isocircle major axis is horizontal (0°)")
    func topMajorIsHorizontal() {
        let data = try! #require(
            EllipseTool.isocircle(center: Vector(0, 0), radiusPoint: Vector(10, 0), plane: .top))
        #expect(abs(axisAngle(data.majorP) - 0) < 1e-9)
    }

    @Test("left plane isocircle major axis is at 120°")
    func leftMajorAt120() {
        let data = try! #require(
            EllipseTool.isocircle(center: Vector(0, 0), radiusPoint: Vector(10, 0), plane: .left))
        // 120° folded into [0, π) is 120° itself.
        #expect(abs(axisAngle(data.majorP) - (2 * Double.pi / 3)) < 1e-9)
    }

    @Test("right plane isocircle major axis is at 60°")
    func rightMajorAt60() {
        let data = try! #require(
            EllipseTool.isocircle(center: Vector(0, 0), radiusPoint: Vector(10, 0), plane: .right))
        #expect(abs(axisAngle(data.majorP) - (Double.pi / 3)) < 1e-9)
    }

    // MARK: Radius → major semi-axis; degenerate guard.

    @Test("the radius point distance becomes the major semi-axis length")
    func radiusIsMajorSemiAxis() {
        let center = Vector(3, 4)
        let radiusPt = center + Vector(0, 7)        // radius 7
        let data = try! #require(
            EllipseTool.isocircle(center: center, radiusPoint: radiusPt, plane: .top))
        #expect(abs(data.majorRadius - 7) < 1e-9)
        // Minor radius = ratio · major = tan(30°)·7.
        #expect(abs(data.minorRadius - tan(Double.pi / 6) * 7) < 1e-9)
    }

    @Test("a zero-radius isocircle is rejected (nil)")
    func zeroRadiusRejected() {
        #expect(EllipseTool.isocircle(center: Vector(1, 1), radiusPoint: Vector(1, 1), plane: .top) == nil)
    }

    @Test("invalid input is rejected (nil)")
    func invalidRejected() {
        #expect(EllipseTool.isocircle(center: .invalid, radiusPoint: Vector(5, 0), plane: .top) == nil)
    }

    // MARK: The tool drives center → radius → commit and re-arms.

    @Test("EllipseTool(.isocircle) commits an isocircle on the second click")
    func toolCommitsOnSecondClick() {
        var tool = EllipseTool(mode: .isocircle(plane: .top))
        let first = tool.handle(.click(Vector(0, 0)), context: .empty)
        // First click only sets the center (no commit).
        if case .commit = first { Issue.record("center click should not commit") }
        let data = try! #require(committedEllipse(tool.handle(.click(Vector(8, 0)), context: .empty)))
        #expect(abs(data.majorRadius - 8) < 1e-9)
        #expect(abs(data.ratio - tan(Double.pi / 6)) < eps)
        #expect(abs(data.center.x - 0) < eps && abs(data.center.y - 0) < eps)
    }

    @Test("the committed isocircle is a WHOLE ellipse (not an arc)")
    func committedIsWholeEllipse() {
        var tool = EllipseTool(mode: .isocircle(plane: .right))
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        let data = try! #require(committedEllipse(tool.handle(.click(Vector(2, 9)), context: .empty)))
        #expect(!data.isArc)
    }

    @Test("after committing, the tool re-arms for the next isocircle center")
    func reArmsAfterCommit() {
        var tool = EllipseTool(mode: .isocircle(plane: .top))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 0)), context: .empty)   // commit #1
        #expect(tool.status == "Specify center of isocircle")
        // A fresh center/radius pair commits again.
        _ = tool.handle(.click(Vector(20, 20)), context: .empty)
        let data = try! #require(committedEllipse(tool.handle(.click(Vector(23, 20)), context: .empty)))
        #expect(abs(data.center.x - 20) < eps && abs(data.center.y - 20) < eps)
    }

    @Test("the isocircle tool previews a closed ellipse while dragging the radius")
    func previewsClosedEllipse() {
        var tool = EllipseTool(mode: .isocircle(plane: .left))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(6, 0)), context: .empty)
        let preview = tool.preview
        #expect(!preview.isEmpty)
        #expect(preview.first?.closed == true)
    }

    @Test("backspace from the radius step returns to the center step")
    func backspaceReturnsToCenter() {
        var tool = EllipseTool(mode: .isocircle(plane: .top))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify radius of isocircle")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify center of isocircle")
    }

    @Test("status starts at the isocircle center prompt")
    func statusStartsAtCenter() {
        let tool = EllipseTool(mode: .isocircle(plane: .right))
        #expect(tool.status == "Specify center of isocircle")
        #expect(tool.title == "Isometric Circle")
    }
}
