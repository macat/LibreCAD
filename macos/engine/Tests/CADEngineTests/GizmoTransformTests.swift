//
//  GizmoTransformTests.swift
//  CADEngineTests
//
//  Pure-math tests for the on-canvas selection GIZMO transforms (`GizmoTransform`):
//    - MOVE: a body drag yields the exact translation (and Shift axis-locks it).
//    - CORNER SCALE: a corner drag yields the expected UNIFORM scale factor AND
//      `transformed(by:)` maps that box corner onto the drag point while the
//      OPPOSITE corner stays fixed (the pivot invariant).
//    - ROTATE: a knob drag yields the expected angle about the box center (and
//      Shift snaps to 15°), and `transformed(by:)` rotates a frame corner about
//      the center by that angle.
//
//  These lock the "drag p0→p1 ⇒ Affine2D" contract the view depends on, with NO
//  GUI — the view layer only maps screen↔world and routes the resulting transform
//  through the undoable commit path, so this is the load-bearing logic.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Gizmo transform math")
struct GizmoTransformTests {

    // MARK: - Fixtures

    /// A 10×6 box: min (0,0), max (10,6). center (5,3).
    private static let frame = GizmoFrame(min: Vector(0, 0), max: Vector(10, 6))

    /// Tolerance for floating-point geometry comparisons.
    private static let eps = 1e-9

    private func approx(_ a: Double, _ b: Double, _ tol: Double = eps) -> Bool {
        abs(a - b) <= tol
    }
    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = eps) -> Bool {
        approx(a.x, b.x, tol) && approx(a.y, b.y, tol)
    }

    // MARK: - Frame anchor points

    @Test("frame exposes corners, center, and the opposite-corner pivot")
    func frameAnchors() {
        let f = Self.frame
        #expect(approx(f.center, Vector(5, 3)))
        #expect(approx(f.bottomLeft, Vector(0, 0)))
        #expect(approx(f.bottomRight, Vector(10, 0)))
        #expect(approx(f.topRight, Vector(10, 6)))
        #expect(approx(f.topLeft, Vector(0, 6)))
        // Opposite-corner pivots.
        #expect(approx(f.oppositeCorner(.topRight), Vector(0, 0)))
        #expect(approx(f.oppositeCorner(.bottomLeft), Vector(10, 6)))
        #expect(approx(f.oppositeCorner(.topLeft), Vector(10, 0)))
        #expect(approx(f.oppositeCorner(.bottomRight), Vector(0, 6)))
        // Rotate knob rises above the top-edge center.
        #expect(approx(f.rotateKnob(offset: 2), Vector(5, 8)))
    }

    @Test("a frame built from an empty AABB is nil")
    func emptyFrame() {
        #expect(GizmoFrame(box: .empty) == nil)
        // A real box round-trips.
        let box = AABB(min: Vector(1, 2), max: Vector(3, 4))
        let f = GizmoFrame(box: box)
        #expect(f != nil)
        #expect(approx(f!.min, Vector(1, 2)))
        #expect(approx(f!.max, Vector(3, 4)))
    }

    // MARK: - Move

    @Test("move drag yields the exact translation")
    func moveTranslation() {
        let t = GizmoTransform.move(from: Vector(2, 2), to: Vector(9, 5))
        // A pure translation: linear part identity, t = (7, 3).
        #expect(approx(t.tx, 7))
        #expect(approx(t.ty, 3))
        #expect(approx(t.a, 1)); #expect(approx(t.b, 0))
        #expect(approx(t.c, 0)); #expect(approx(t.d, 1))
        // It moves an arbitrary point by exactly the delta.
        #expect(approx(t.apply(Vector(0, 0)), Vector(7, 3)))
    }

    @Test("Shift-constrained move locks to the dominant axis")
    func moveConstrained() {
        // Δ = (7, 3): |Δx| dominates → y is zeroed.
        let tx = GizmoTransform.move(from: Vector(0, 0), to: Vector(7, 3), constrained: true)
        #expect(approx(tx.tx, 7)); #expect(approx(tx.ty, 0))
        // Δ = (2, 9): |Δy| dominates → x is zeroed.
        let ty = GizmoTransform.move(from: Vector(0, 0), to: Vector(2, 9), constrained: true)
        #expect(approx(ty.tx, 0)); #expect(approx(ty.ty, 9))
    }

    // MARK: - Corner scale

    @Test("corner drag yields the expected uniform scale factor")
    func cornerScaleFactorValue() {
        // Drag topRight (10,6) outward to (20,12); pivot is bottomLeft (0,0).
        // |p0-pivot| = sqrt(136); |p1-pivot| = sqrt(544) = 2*sqrt(136) → factor 2.
        let f = GizmoTransform.cornerScaleFactor(
            frame: Self.frame, corner: .topRight,
            from: Self.frame.topRight, to: Vector(20, 12))
        #expect(f != nil)
        #expect(approx(f!, 2.0))
    }

    @Test("corner drag maps the dragged corner onto the drag point, opposite corner fixed")
    func cornerScaleMapsCorner() {
        let frame = Self.frame
        let corner: GizmoHandle.Corner = .topRight
        let pivot = frame.oppositeCorner(corner)   // (0,0)
        // Drag the corner along its own diagonal so the uniform-scale corner lands
        // exactly on the drag point (a diagonal drag keeps the pivot→corner
        // direction, which uniform scale preserves).
        let p0 = frame.corner(corner)              // (10,6)
        let p1 = Vector(20, 12)                     // 2× along the diagonal
        let t = GizmoTransform.cornerScale(frame: frame, corner: corner, from: p0, to: p1)

        // The dragged corner maps onto the drag point.
        #expect(approx(t.apply(p0), p1))
        // The opposite corner (pivot) is fixed.
        #expect(approx(t.apply(pivot), pivot))
        // It is a uniform 2× scale: the box doubles in both extents.
        #expect(approx(t.apply(frame.bottomRight), Vector(20, 0)))
        #expect(approx(t.apply(frame.topLeft), Vector(0, 12)))
    }

    @Test("corner scale applied via EntityKind.transformed scales a line about the pivot")
    func cornerScaleTransformsEntity() {
        let frame = Self.frame
        let corner: GizmoHandle.Corner = .topRight
        // 2× scale about (0,0).
        let t = GizmoTransform.cornerScale(
            frame: frame, corner: corner, from: frame.topRight, to: Vector(20, 12))
        // A line from the pivot to the dragged corner becomes the pivot→drag-point line.
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 6)))
        guard case .line(let scaled) = line.transformed(by: t) else {
            Issue.record("expected a line"); return
        }
        #expect(approx(scaled.start, Vector(0, 0)))
        #expect(approx(scaled.end, Vector(20, 12)))
    }

    @Test("a degenerate corner drag (no motion / zero box) is identity")
    func cornerScaleDegenerate() {
        let frame = Self.frame
        // No motion → factor 1 → but cornerScale returns a scale(1) which is
        // effectively identity; assert it maps points unchanged.
        let t0 = GizmoTransform.cornerScale(
            frame: frame, corner: .topRight, from: frame.topRight, to: frame.topRight)
        #expect(approx(t0.apply(Vector(3, 4)), Vector(3, 4)))
        // Zero-size box (corner == pivot) → identity (oldDist ≈ 0 rejected).
        let zero = GizmoFrame(min: Vector(5, 5), max: Vector(5, 5))
        let t1 = GizmoTransform.cornerScale(
            frame: zero, corner: .topRight, from: Vector(5, 5), to: Vector(9, 9))
        #expect(t1 == .identity)
    }

    // MARK: - Rotate

    @Test("rotate knob drag yields the expected angle about the box center")
    func rotateAngleValue() {
        let frame = Self.frame                    // center (5,3)
        let center = frame.center
        // p0 directly right of center, p1 directly above → +90° (π/2) CCW.
        let p0 = center + Vector(4, 0)
        let p1 = center + Vector(0, 4)
        let a = GizmoTransform.rotateAngle(frame: frame, from: p0, to: p1)
        #expect(a != nil)
        #expect(approx(a!, .pi / 2))
    }

    @Test("rotate transform turns a corner about the center by the swept angle")
    func rotateTransformsCorner() {
        let frame = Self.frame
        let center = frame.center
        let p0 = center + Vector(4, 0)
        let p1 = center + Vector(0, 4)            // +90°
        let t = GizmoTransform.rotate(frame: frame, from: p0, to: p1)
        // A point 4 to the right of center rotates to 4 above center.
        #expect(approx(t.apply(center + Vector(4, 0)), center + Vector(0, 4)))
        // The center itself is fixed.
        #expect(approx(t.apply(center), center))
    }

    @Test("Shift snaps the rotation to the nearest 15 degrees")
    func rotateSnap() {
        let frame = Self.frame
        let center = frame.center
        let p0 = center + Vector(4, 0)            // 0°
        // ~20° target → snaps to 15° (π/12).
        let p1 = center + Vector(4 * cos(20 * .pi / 180), 4 * sin(20 * .pi / 180))
        let a = GizmoTransform.rotateAngle(frame: frame, from: p0, to: p1, snap: true)
        #expect(a != nil)
        #expect(approx(a!, .pi / 12, 1e-9))
    }

    @Test("a near-zero rotation drag is identity / nil angle")
    func rotateDegenerate() {
        let frame = Self.frame
        let center = frame.center
        let p = center + Vector(4, 0)
        // p0 == p1 → no sweep.
        #expect(GizmoTransform.rotateAngle(frame: frame, from: p, to: p) == nil)
        #expect(GizmoTransform.rotate(frame: frame, from: p, to: p) == .identity)
        // A point AT the center has no direction → nil.
        #expect(GizmoTransform.rotateAngle(frame: frame, from: center, to: p) == nil)
    }
}
