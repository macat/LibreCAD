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

    // MARK: - Point-based overloads (oriented gizmo pivot/center)

    @Test("point-based cornerScale about an explicit pivot matches the frame-based form")
    func cornerScalePivotOverload() {
        let frame = Self.frame
        let corner: GizmoHandle.Corner = .topRight
        let pivot = frame.oppositeCorner(corner)
        let p0 = frame.corner(corner)
        let p1 = Vector(20, 12)
        let viaFrame = GizmoTransform.cornerScale(frame: frame, corner: corner, from: p0, to: p1)
        let viaPivot = GizmoTransform.cornerScale(pivot: pivot, from: p0, to: p1)
        #expect(viaPivot == viaFrame)
        // It scales about an ARBITRARY (oriented) pivot the frame can't express.
        let oriented = GizmoTransform.cornerScale(pivot: Vector(2, 1), from: Vector(4, 3), to: Vector(6, 5))
        #expect(approx(oriented.apply(Vector(2, 1)), Vector(2, 1)))   // pivot fixed
    }

    @Test("point-based cornerScale is identity for a degenerate drag")
    func cornerScalePivotDegenerate() {
        // pivot == p0 → oldDist 0 → identity.
        let t = GizmoTransform.cornerScale(pivot: Vector(5, 5), from: Vector(5, 5), to: Vector(9, 9))
        #expect(t == .identity)
    }

    @Test("point-based rotate about an explicit center matches the frame-based form")
    func rotateCenterOverload() {
        let frame = Self.frame
        let center = frame.center
        let p0 = center + Vector(4, 0)
        let p1 = center + Vector(0, 4)
        let viaFrame = GizmoTransform.rotate(frame: frame, from: p0, to: p1)
        let viaCenter = GizmoTransform.rotate(center: center, from: p0, to: p1)
        #expect(viaCenter == viaFrame)
        // About an arbitrary oriented center.
        let c = Vector(2, 2)
        let t = GizmoTransform.rotate(center: c, from: c + Vector(3, 0), to: c + Vector(0, 3))
        #expect(approx(t.apply(c + Vector(3, 0)), c + Vector(0, 3)))
        #expect(approx(t.apply(c), c))   // center fixed
    }

    @Test("point-based rotateAngle snaps and rejects degenerate drags")
    func rotateAngleCenterOverload() {
        let c = Vector(0, 0)
        // ~20° → snaps to 15°.
        let p0 = c + Vector(4, 0)
        let p1 = c + Vector(4 * cos(20 * .pi / 180), 4 * sin(20 * .pi / 180))
        let a = GizmoTransform.rotateAngle(center: c, from: p0, to: p1, snap: true)
        #expect(a != nil)
        #expect(approx(a!, .pi / 12, 1e-9))
        // p0 == p1 → nil; a point at the center → nil.
        #expect(GizmoTransform.rotateAngle(center: c, from: p0, to: p0) == nil)
        #expect(GizmoTransform.rotateAngle(center: c, from: c, to: p0) == nil)
    }

    // MARK: - Oriented frame chrome (transformedQuad / transformedKnobAnchor)

    @Test("identity transform yields the base AABB corners in [BL,BR,TR,TL] order")
    func transformedQuadIdentity() {
        let f = Self.frame  // min (0,0), max (10,6)
        let q = GizmoTransform.transformedQuad(base: f, t: .identity)
        #expect(q.count == 4)
        #expect(approx(q[0], Vector(0, 0)))   // bottomLeft
        #expect(approx(q[1], Vector(10, 0)))  // bottomRight
        #expect(approx(q[2], Vector(10, 6)))  // topRight
        #expect(approx(q[3], Vector(0, 6)))   // topLeft
        // The quad equals t.apply of each named corner in BL,BR,TR,TL order.
        #expect(approx(q[0], f.bottomLeft))
        #expect(approx(q[1], f.bottomRight))
        #expect(approx(q[2], f.topRight))
        #expect(approx(q[3], f.topLeft))
    }

    @Test("90° rotate-about-center rotates each corner and de-axis-aligns the quad")
    func transformedQuad90Rotate() {
        let f = Self.frame
        let center = f.center  // (5,3)
        let t = Affine2D.rotation(angle: .pi / 2, about: center)
        let q = GizmoTransform.transformedQuad(base: f, t: t)
        // Each quad corner equals the base corner rotated 90° about the center.
        let corners: [GizmoHandle.Corner] = [.bottomLeft, .bottomRight, .topRight, .topLeft]
        for (i, c) in corners.enumerated() {
            #expect(approx(q[i], t.apply(f.corner(c))))
        }
        // The rotated quad is NOT axis-aligned: the bottom edge BL'→BR' is now
        // vertical, so BL'.y != BR'.y (and BL'.x == BR'.x).
        #expect(!approx(q[0].y, q[1].y))
        #expect(approx(q[0].x, q[1].x))
    }

    @Test("uniform corner-scale keeps the quad axis-aligned at the scaled corners")
    func transformedQuadUniformScale() {
        let f = Self.frame
        // 2× uniform scale about the bottomLeft pivot (0,0).
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        let q = GizmoTransform.transformedQuad(base: f, t: t)
        let corners: [GizmoHandle.Corner] = [.bottomLeft, .bottomRight, .topRight, .topLeft]
        for (i, c) in corners.enumerated() {
            #expect(approx(q[i], t.apply(f.corner(c))))
        }
        // Uniform (non-rotating) scale stays axis-aligned: bottom edge horizontal,
        // left edge vertical.
        #expect(approx(q[0].y, q[1].y))   // BL'.y == BR'.y
        #expect(approx(q[0].x, q[3].x))   // BL'.x == TL'.x
        // Concrete scaled corners.
        #expect(approx(q[0], Vector(0, 0)))
        #expect(approx(q[1], Vector(20, 0)))
        #expect(approx(q[2], Vector(20, 12)))
        #expect(approx(q[3], Vector(0, 12)))
    }

    @Test("knob anchor root is the top-edge midpoint and outward points away from center (identity)")
    func transformedKnobAnchorIdentity() {
        let f = Self.frame  // top edge from (0,6) to (10,6), center (5,3)
        let a = GizmoTransform.transformedKnobAnchor(base: f, t: .identity)
        // Root is the midpoint of TL,TR.
        #expect(approx(a.root, Vector(5, 6)))
        // Outward is the unit +Y normal (points up, away from the center below).
        #expect(approx(a.outward, Vector(0, 1)))
        // Unit length.
        #expect(approx((a.outward.x * a.outward.x + a.outward.y * a.outward.y).squareRoot(), 1))
        // It points away from the transformed center.
        let center = f.center
        let centerToRoot = a.root - center
        #expect(a.outward.x * centerToRoot.x + a.outward.y * centerToRoot.y > 0)
    }

    @Test("knob anchor turns with the box under a 90° rotation")
    func transformedKnobAnchor90Rotate() {
        let f = Self.frame
        let center = f.center
        let t = Affine2D.rotation(angle: .pi / 2, about: center)
        let a = GizmoTransform.transformedKnobAnchor(base: f, t: t)
        // Root is the midpoint of the TRANSFORMED top edge.
        let tl = t.apply(f.topLeft)
        let tr = t.apply(f.topRight)
        #expect(approx(a.root, Vector((tl.x + tr.x) * 0.5, (tl.y + tr.y) * 0.5)))
        // Outward is still unit length...
        #expect(approx((a.outward.x * a.outward.x + a.outward.y * a.outward.y).squareRoot(), 1))
        // ...and still points away from the (unchanged) center — the stalk turned
        // with the box rather than staying upright.
        let centerToRoot = a.root - t.apply(center)
        #expect(a.outward.x * centerToRoot.x + a.outward.y * centerToRoot.y > 0)
        // For a +90° rotation the original top edge (pointing +X normal +Y) turns:
        // the outward normal is no longer +Y.
        #expect(!approx(a.outward, Vector(0, 1)))
    }

    // MARK: - Oriented hit-testing (pointInConvexQuad)

    @Test("point-in-quad: inside / outside an axis-aligned quad")
    func pointInQuadAxisAligned() {
        let q = [Vector(0, 0), Vector(10, 0), Vector(10, 6), Vector(0, 6)]
        #expect(GizmoTransform.pointInConvexQuad(Vector(5, 3), quad: q))   // center
        #expect(GizmoTransform.pointInConvexQuad(Vector(0, 0), quad: q))   // corner
        #expect(!GizmoTransform.pointInConvexQuad(Vector(-1, 3), quad: q)) // left of it
        #expect(!GizmoTransform.pointInConvexQuad(Vector(5, 7), quad: q))  // above it
    }

    @Test("point-in-quad: a ROTATED quad accepts points the AABB would and rejects corners the AABB wouldn't")
    func pointInQuadRotated() {
        // A 10×4 box rotated 45° about its center (5,2): its AABB is much larger.
        let center = Vector(5, 2)
        let t = Affine2D.rotation(angle: .pi / 4, about: center)
        let q = GizmoTransform.transformedQuad(base: GizmoFrame(min: Vector(0, 0), max: Vector(10, 4)), t: t)
        // The center is inside.
        #expect(GizmoTransform.pointInConvexQuad(center, quad: q))
        // A point near a CORNER of the rotated box's AABB but OUTSIDE the rotated
        // quad is rejected — the oriented test is tighter than a screen AABB.
        // The rotated box's AABB spans roughly x∈[~-0.95, ~10.95]; pick a far corner.
        let aabbCorner = Vector(center.x - 4.9, center.y - 4.9)
        #expect(!GizmoTransform.pointInConvexQuad(aabbCorner, quad: q))
    }

    @Test("point-in-quad: slop expands the accept region")
    func pointInQuadSlop() {
        let q = [Vector(0, 0), Vector(10, 0), Vector(10, 6), Vector(0, 6)]
        // Just outside the right edge by 0.5.
        let p = Vector(10.5, 3)
        #expect(!GizmoTransform.pointInConvexQuad(p, quad: q))            // no slop
        #expect(GizmoTransform.pointInConvexQuad(p, quad: q, slop: 1.0))  // within slop
    }

    @Test("point-in-quad: degenerate / non-quad input is rejected")
    func pointInQuadDegenerate() {
        #expect(!GizmoTransform.pointInConvexQuad(Vector(0, 0), quad: [Vector(0, 0), Vector(1, 1), Vector(2, 2)]))
        // Zero-area quad (all points coincide) → rejected.
        let z = Vector(3, 3)
        #expect(!GizmoTransform.pointInConvexQuad(z, quad: [z, z, z, z]))
    }

    @Test("knob anchor outward stays outward across all four rotation quadrants")
    func transformedKnobAnchorAllQuadrants() {
        let f = Self.frame
        let center = f.center
        for deg in stride(from: 0.0, to: 360.0, by: 30.0) {
            let t = Affine2D.rotation(angle: deg * .pi / 180, about: center)
            let a = GizmoTransform.transformedKnobAnchor(base: f, t: t)
            let centerToRoot = a.root - t.apply(center)
            // Outward must have a positive component along center→root (points out).
            let dotOut = a.outward.x * centerToRoot.x + a.outward.y * centerToRoot.y
            #expect(dotOut > 0, "outward flipped inward at \(deg)°")
        }
    }
}

// MARK: - Stage 2: CanvasModel orientation feeder (gizmoOrientation + oriented base)

/// Tests for the resting-gizmo ORIENTATION feeder added to `CanvasModel` (task
/// #17): the intrinsic-angle fast path for a single rotated entity, the min-area
/// OBB fallback for a baked rotated rectangle / multi-select, and the oriented base
/// frame that — rotated by that angle about its own center — hugs the geometry.
///
/// `@MainActor` because `CanvasModel` is a main-actor `@Observable` (reached via
/// the `_SharedCanvasModel.swift` symlink into the test target).
@MainActor
@Suite("Gizmo orientation feeder (CanvasModel)")
struct GizmoOrientationFeederTests {

    private static let eps = 1e-7

    private func approx(_ a: Double, _ b: Double, _ tol: Double = eps) -> Bool {
        abs(a - b) <= tol
    }
    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = eps) -> Bool {
        approx(a.x, b.x, tol) && approx(a.y, b.y, tol)
    }
    /// Orientation difference mod π/2 (a box's angle is canonical to that band).
    private func orientationDiff(_ a: Double, _ b: Double) -> Double {
        let quarter = Double.pi / 2
        var d = (a - b).truncatingRemainder(dividingBy: quarter)
        if d > quarter / 2 { d -= quarter }
        if d < -quarter / 2 { d += quarter }
        return abs(d)
    }

    private func makeModel(_ records: [EntityRecord]) -> CanvasModel {
        let drawing = CADDrawing()
        for r in records { _ = drawing.add(r) }
        let model = CanvasModel(drawing: drawing)
        model.selection.ids = Set(records.map(\.id))
        return model
    }

    /// The 4 corners of a rectangle (half-extents hx,hy) at `center`, rotated CCW.
    private func rotatedRectCorners(center: Vector, hx: Double, hy: Double, angle: Double) -> [Vector] {
        let u = Vector(cos(angle), sin(angle))
        let v = Vector(-sin(angle), cos(angle))
        return [
            center + u * (-hx) + v * (-hy),
            center + u * ( hx) + v * (-hy),
            center + u * ( hx) + v * ( hy),
            center + u * (-hx) + v * ( hy),
        ]
    }

    private func closedPolyline(_ pts: [Vector], id: UInt64) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .polyline(PolylineData(vertices: pts.map { PolylineVertex(point: $0) },
                                                  closed: true)))
    }

    // MARK: Intrinsic fast path (single entity)

    @Test("a single rotated INSERT uses its stored rotation")
    func insertIntrinsic() {
        let m = makeModel([EntityRecord(id: EntityID(1),
            kind: .insert(InsertData(blockName: "B", insertionPoint: Vector(3, 3), rotation: 0.7)))])
        #expect(approx(m.gizmoOrientation, 0.7))
    }

    @Test("a single rotated TEXT uses its stored rotation")
    func textIntrinsic() {
        let m = makeModel([EntityRecord(id: EntityID(1),
            kind: .text(TextData(position: Vector(0, 0), height: 2, rotation: 1.1, text: "hi")))])
        #expect(approx(m.gizmoOrientation, 1.1))
    }

    @Test("a single ELLIPSE uses its major-axis angle")
    func ellipseIntrinsic() {
        // major axis along 30°, length 5; minor ratio 0.5.
        let major = Vector(5 * cos(0.5236), 5 * sin(0.5236))
        let m = makeModel([EntityRecord(id: EntityID(1),
            kind: .ellipse(EllipseData(center: Vector(2, 2), majorP: major, ratio: 0.5)))])
        #expect(approx(m.gizmoOrientation, major.angle))
    }

    @Test("a single CIRCLE has no intrinsic angle → falls back to 0 (symmetric)")
    func circleNoIntrinsic() {
        let m = makeModel([EntityRecord(id: EntityID(1),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 4)))])
        #expect(approx(m.gizmoOrientation, 0))
    }

    // MARK: OBB fallback (baked rotated rectangle / multi-select)

    @Test("a baked rotated RECTANGLE polyline recovers the OBB angle (the user's bug)")
    func rotatedRectangleOBB() {
        let angle = 0.5
        let corners = rotatedRectCorners(center: Vector(10, 4), hx: 7, hy: 2, angle: angle)
        let m = makeModel([closedPolyline(corners, id: 1)])
        // No intrinsic angle on a polyline → OBB path.
        #expect(orientationDiff(m.gizmoOrientation, angle) <= 1e-6)
    }

    @Test("an axis-aligned rectangle polyline stays upright (angle 0)")
    func axisAlignedRectangle() {
        let pts = [Vector(0, 0), Vector(10, 0), Vector(10, 4), Vector(0, 4)]
        let m = makeModel([closedPolyline(pts, id: 1)])
        #expect(approx(m.gizmoOrientation, 0))
    }

    @Test("a multi-selection of two separated lines falls back to its OBB / 0")
    func multiSelect() {
        // Two horizontal lines → the selection's bounding shape is axis-aligned → 0.
        let l1 = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(6, 0))))
        let l2 = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(0, 4), end: Vector(6, 4))))
        let m = makeModel([l1, l2])
        #expect(m.selection.count == 2)
        #expect(approx(m.gizmoOrientation, 0))
    }

    @Test("no selection → orientation 0")
    func emptySelection() {
        let m = CanvasModel(drawing: CADDrawing())
        #expect(approx(m.gizmoOrientation, 0))
    }

    // MARK: Oriented base frame

    @Test("the oriented base box, rotated by the orientation about its center, hugs a rotated rectangle")
    func orientedBaseHugsRectangle() {
        let angle = 0.6
        let hx = 7.0, hy = 2.0
        let corners = rotatedRectCorners(center: Vector(12, 5), hx: hx, hy: hy, angle: angle)
        let m = makeModel([closedPolyline(corners, id: 1)])

        guard let base = m.gizmoOrientedBaseFrame else {
            Issue.record("expected an oriented base frame"); return
        }
        let orient = m.gizmoOrientation
        // The base box is AXIS-ALIGNED in its own frame; rotate by the orientation
        // about its center → the drawn oriented quad. Each input corner must be hit.
        let t = Affine2D.rotation(angle: orient, about: base.center)
        let drawn = GizmoTransform.transformedQuad(base: base, t: t)
        for inp in corners {
            #expect(drawn.contains { approx($0, inp, 1e-6) },
                    "corner \(inp) not hit by the oriented base quad")
        }
        // The base box's extents match the rectangle's (orientation may swap them).
        let exts = [base.width * 0.5, base.height * 0.5].sorted()
        let want = [hx, hy].sorted()
        #expect(approx(exts[0], want[0], 1e-6))
        #expect(approx(exts[1], want[1], 1e-6))
    }

    @Test("for orientation 0 the oriented base frame equals the plain upright AABB")
    func orientedBaseZeroEqualsAABB() {
        let pts = [Vector(1, 2), Vector(9, 2), Vector(9, 7), Vector(1, 7)]
        let m = makeModel([closedPolyline(pts, id: 1)])
        #expect(approx(m.gizmoOrientation, 0))
        guard let base = m.gizmoOrientedBaseFrame,
              let aabbBox = m.selectionWorldBounds,
              let aabbFrame = GizmoFrame(box: aabbBox) else {
            Issue.record("expected frames"); return
        }
        // Byte-identical to the legacy upright frame (no regression for angle 0).
        #expect(base == aabbFrame)
    }
}
