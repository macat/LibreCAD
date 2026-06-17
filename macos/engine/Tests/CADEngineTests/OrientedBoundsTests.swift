//
//  OrientedBoundsTests.swift
//  CADEngineTests
//
//  Pure-math tests for the minimum-area ORIENTED bounding box (`OrientedBounds`).
//  This is the load-bearing logic that keeps the resting selection gizmo ORIENTED
//  to a rotated object whose geometry has no stored angle (a baked rotated
//  rectangle is a 4-vertex polyline). The key case is:
//    - a rotated rectangle's 4 corners → recover the rotation angle + extents.
//  Plus the degenerate / tie-break cases (axis-aligned, square, line, collinear,
//  duplicate, empty) that must NOT pick a jittery arbitrary axis.
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

@Suite("Oriented bounding box (min-area OBB)")
struct OrientedBoundsTests {

    private static let eps = 1e-9

    private func approx(_ a: Double, _ b: Double, _ tol: Double = eps) -> Bool {
        abs(a - b) <= tol
    }
    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = eps) -> Bool {
        approx(a.x, b.x, tol) && approx(a.y, b.y, tol)
    }

    /// The unsigned angular difference between two ORIENTATION angles (mod π/2),
    /// so a box and its 90° rotation read as the same orientation. Used for the
    /// extent-agnostic checks (a rotated rectangle's recovered angle equals the
    /// rectangle's angle either exactly or as its perpendicular, depending on which
    /// extent is longer); the long-axis convention is asserted separately.
    private func orientationDiff(_ a: Double, _ b: Double) -> Double {
        let quarter = Double.pi / 2
        var d = (a - b).truncatingRemainder(dividingBy: quarter)
        if d > quarter / 2 { d -= quarter }
        if d < -quarter / 2 { d += quarter }
        return abs(d)
    }

    /// The unsigned angular difference between two DIRECTION angles (mod π), so a
    /// direction and its 180° reverse read as the same line/long-axis direction.
    /// This is the band `OrientedBounds.angle` lives in under the long-axis
    /// convention — use it for continuity (no 45°/90° flip) assertions.
    private func directionDiff(_ a: Double, _ b: Double) -> Double {
        let pi = Double.pi
        var d = (a - b).truncatingRemainder(dividingBy: pi)
        if d > pi / 2 { d -= pi }
        if d < -pi / 2 { d += pi }
        return abs(d)
    }

    /// Builds the 4 corners of a rectangle of half-extents (hx, hy) centered at
    /// `center`, rotated CCW by `angle`.
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

    // MARK: - The load-bearing case: a rotated rectangle

    @Test("a rotated rectangle's 4 corners recover the rotation angle and extents")
    func rotatedRectangle() {
        let center = Vector(20, 7)
        let hx = 6.0, hy = 2.5
        let angle = 0.6   // ~34.4°, clearly not square, not axis-aligned
        let corners = rotatedRectCorners(center: center, hx: hx, hy: hy, angle: angle)

        let obb = OrientedBounds.minAreaRect(corners)
        #expect(obb != nil)
        let b = obb!
        // Long-axis convention: the recovered DIRECTION matches the rectangle's
        // long-axis angle (mod π) EXACTLY — the long edge (hx = 6) lies along
        // `angle`, so `b.angle` == 0.6 (no 45°/90° fold to the short axis).
        #expect(directionDiff(b.angle, angle) <= 1e-7)
        // The half-extent along the primary (width) axis is the LONG one.
        #expect(b.halfExtents.x >= b.halfExtents.y)
        #expect(approx(b.halfExtents.x, hx, 1e-7))
        #expect(approx(b.halfExtents.y, hy, 1e-7))
        // The center is recovered.
        #expect(approx(b.center, center, 1e-7))
        // The reconstructed corners enclose the input corners tightly: the area
        // equals the true rectangle area.
        #expect(approx(b.width * b.height, (2 * hx) * (2 * hy), 1e-6))
        // The hug invariant: reconstructed corners reproduce the input corners.
        for inp in corners {
            #expect(b.corners.contains { approx($0, inp, 1e-7) })
        }
    }

    @Test("a rectangle rotated by a small angle still recovers that angle")
    func smallRotation() {
        let center = Vector(0, 0)
        let angle = 0.15
        let corners = rotatedRectCorners(center: center, hx: 10, hy: 3, angle: angle)
        let obb = OrientedBounds.minAreaRect(corners)
        #expect(obb != nil)
        #expect(orientationDiff(obb!.angle, angle) <= 1e-6)
    }

    @Test("a rotated rectangle with extra interior/edge points still recovers the angle")
    func rotatedRectangleWithExtraPoints() {
        let center = Vector(3, -4)
        let hx = 8.0, hy = 2.0
        let angle = 0.9
        var pts = rotatedRectCorners(center: center, hx: hx, hy: hy, angle: angle)
        // Add edge midpoints + the center (interior points must not change the OBB).
        pts.append(center)
        for i in 0..<4 {
            let a = pts[i], bb = pts[(i + 1) % 4]
            pts.append(Vector((a.x + bb.x) * 0.5, (a.y + bb.y) * 0.5))
        }
        let obb = OrientedBounds.minAreaRect(pts)
        #expect(obb != nil)
        #expect(orientationDiff(obb!.angle, angle) <= 1e-6)
        #expect(approx(obb!.width * obb!.height, (2 * hx) * (2 * hy), 1e-5))
    }

    // MARK: - Continuity regression (the knob-reset fix)

    @Test("a rotated rectangle's orientation is CONTINUOUS through 0–180° (no 45°/90° flip)")
    func orientationContinuousAcross90() {
        // The original bug: the OBB angle folded to a mod-π/2 band and swapped to
        // the SHORT axis at each 45° boundary, so the gizmo rotate-knob jumped ~90°
        // mid-rotation ("reset to the top"). Under the long-axis mod-π convention
        // the reported direction must track the rectangle's actual rotation with NO
        // ~90° discontinuity across the old 45°/90° boundaries.
        let center = Vector(-2, 5)
        let hx = 7.0, hy = 2.0           // clearly non-square (long axis well-defined)
        // A sweep straddling the old 45°(≈0.785) and 90°(≈1.571) fold boundaries.
        let sweep = [0.2, 0.6, 1.0, 1.4, 2.0, 2.8]

        var recovered: [Double] = []
        for a in sweep {
            let corners = rotatedRectCorners(center: center, hx: hx, hy: hy, angle: a)
            let obb = OrientedBounds.minAreaRect(corners)
            #expect(obb != nil)
            let b = obb!
            // Each sample: the long axis is the primary (width) axis, and its
            // DIRECTION (mod π) matches the input rotation EXACTLY.
            #expect(b.halfExtents.x >= b.halfExtents.y)
            #expect(directionDiff(b.angle, a) <= 1e-6)
            recovered.append(b.angle)
        }

        // The regression guard: between ADJACENT samples the recovered orientation
        // changes by the SAME small amount the input changed (mod π) — NOT a ~90°
        // jump. The input steps are ≤ 0.8 rad; assert each recovered step (mod π)
        // matches the input step (mod π) and stays well under the ~π/2 the old fold
        // would have produced.
        for i in 1..<sweep.count {
            let inputStep = directionDiff(sweep[i], sweep[i - 1])
            let recoveredStep = directionDiff(recovered[i], recovered[i - 1])
            // No ~90° flip: a fold-induced jump would read as ~π/2 here.
            #expect(recoveredStep < Double.pi / 2 - 0.1)
            // And it tracks the actual rotation increment.
            #expect(abs(recoveredStep - inputStep) <= 1e-6)
        }
    }

    @Test("crossing exactly 45° does not swap the primary axis to the short side")
    func noSwapAt45() {
        // Just below and just above the old 45° fold boundary: the long axis (hx=5)
        // must stay the primary (width) axis on BOTH sides — the old code swapped to
        // the short axis (hy=2) the moment the angle crossed π/4.
        let hx = 5.0, hy = 2.0
        let below = OrientedBounds.minAreaRect(
            rotatedRectCorners(center: Vector(0, 0), hx: hx, hy: hy, angle: Double.pi / 4 - 0.05))!
        let above = OrientedBounds.minAreaRect(
            rotatedRectCorners(center: Vector(0, 0), hx: hx, hy: hy, angle: Double.pi / 4 + 0.05))!
        // Both keep the long extent on the primary (width) axis.
        #expect(approx(below.halfExtents.x, hx, 1e-7))
        #expect(approx(below.halfExtents.y, hy, 1e-7))
        #expect(approx(above.halfExtents.x, hx, 1e-7))
        #expect(approx(above.halfExtents.y, hy, 1e-7))
        // The angle is continuous across the boundary (no ~90° jump).
        #expect(directionDiff(above.angle, below.angle) < 0.2)
    }

    // MARK: - Axis-aligned + tie-break

    @Test("an axis-aligned rectangle yields angle 0")
    func axisAligned() {
        let pts = [Vector(0, 0), Vector(10, 0), Vector(10, 4), Vector(0, 4)]
        let obb = OrientedBounds.minAreaRect(pts)
        #expect(obb != nil)
        #expect(approx(obb!.angle, 0))
        #expect(approx(obb!.center, Vector(5, 2)))
        // Extents are the half-width / half-height.
        let exts = [obb!.halfExtents.x, obb!.halfExtents.y].sorted()
        #expect(approx(exts[0], 2))
        #expect(approx(exts[1], 5))
    }

    @Test("a square (symmetric) yields angle 0, not a jittery arbitrary axis")
    func square() {
        let pts = [Vector(-3, -3), Vector(3, -3), Vector(3, 3), Vector(-3, 3)]
        let obb = OrientedBounds.minAreaRect(pts)
        #expect(obb != nil)
        #expect(approx(obb!.angle, 0))
    }

    @Test("a rotated square still resolves to angle 0 (square is direction-free)")
    func rotatedSquare() {
        // A square rotated by 0.4 rad — every orientation has equal area, so the
        // tie-break must keep angle 0 (axis-aligned) rather than snap to 0.4.
        let corners = rotatedRectCorners(center: Vector(1, 1), hx: 4, hy: 4, angle: 0.4)
        let obb = OrientedBounds.minAreaRect(corners)
        #expect(obb != nil)
        #expect(approx(obb!.angle, 0))
    }

    @Test("a regular-polygon (circle-like) point cloud yields angle 0")
    func circleSample() {
        var pts: [Vector] = []
        let n = 24
        for i in 0..<n {
            let a = 2 * Double.pi * Double(i) / Double(n)
            pts.append(Vector(5 * cos(a), 5 * sin(a)))
        }
        let obb = OrientedBounds.minAreaRect(pts)
        #expect(obb != nil)
        // A symmetric ring has near-equal area in every orientation → tie-break 0.
        #expect(approx(obb!.angle, 0))
    }

    // MARK: - Lines (zero-thickness)

    @Test("a rotated line's endpoints recover the line's angle (zero thickness)")
    func rotatedLine() {
        let a = Vector(0, 0)
        let b = Vector(6, 6)   // 45°
        let obb = OrientedBounds.minAreaRect([a, b])
        #expect(obb != nil)
        // Orientation is the line direction (mod π/2): 45° == π/4.
        #expect(orientationDiff(obb!.angle, .pi / 4) <= 1e-7)
        // Zero thickness: one half-extent is ~0.
        let minExt = Swift.min(obb!.halfExtents.x, obb!.halfExtents.y)
        #expect(approx(minExt, 0, 1e-9))
        // The non-zero half-extent is half the line length.
        let maxExt = Swift.max(obb!.halfExtents.x, obb!.halfExtents.y)
        #expect(approx(maxExt, (6.0 * 6.0 + 6.0 * 6.0).squareRoot() * 0.5, 1e-7))
        // The center is the midpoint.
        #expect(approx(obb!.center, Vector(3, 3), 1e-9))
    }

    @Test("a vertical line recovers a vertical orientation (π/2 in the mod-π band)")
    func verticalLine() {
        let obb = OrientedBounds.minAreaRect([Vector(2, -3), Vector(2, 5)])
        #expect(obb != nil)
        // The line's long axis is vertical (π/2). Under the mod-π band (−π/2, π/2],
        // π/2 is the (inclusive) top endpoint, so the reported angle is exactly π/2.
        #expect(directionDiff(obb!.angle, .pi / 2) <= 1e-7)
        #expect(approx(obb!.angle, .pi / 2, 1e-7))
        // The non-zero extent is on the primary (width) axis; the thickness is ~0.
        #expect(approx(obb!.halfExtents.y, 0, 1e-9))
        #expect(approx(obb!.halfExtents.x, 4, 1e-7))
    }

    @Test("collinear points (3+) yield a zero-thickness box along the line")
    func collinear() {
        let pts = [Vector(0, 0), Vector(2, 1), Vector(4, 2), Vector(8, 4)]  // slope 1/2
        let obb = OrientedBounds.minAreaRect(pts)
        #expect(obb != nil)
        let minExt = Swift.min(obb!.halfExtents.x, obb!.halfExtents.y)
        #expect(approx(minExt, 0, 1e-9))
        #expect(orientationDiff(obb!.angle, atan2(1, 2)) <= 1e-7)
    }

    // MARK: - Degenerate inputs

    @Test("empty / single / duplicate inputs return nil")
    func degenerate() {
        #expect(OrientedBounds.minAreaRect([]) == nil)
        #expect(OrientedBounds.minAreaRect([Vector(1, 1)]) == nil)
        // All-duplicate points → no two distinct → nil.
        #expect(OrientedBounds.minAreaRect([Vector(2, 2), Vector(2, 2), Vector(2, 2)]) == nil)
        // Invalid points are filtered; fewer than 2 valid → nil.
        #expect(OrientedBounds.minAreaRect([.invalid, Vector(1, 1), .invalid]) == nil)
    }

    @Test("invalid points are filtered but valid ones still produce a box")
    func filtersInvalid() {
        let obb = OrientedBounds.minAreaRect([.invalid, Vector(0, 0), Vector(4, 0), .invalid, Vector(4, 2), Vector(0, 2)])
        #expect(obb != nil)
        #expect(approx(obb!.angle, 0))
        #expect(approx(obb!.center, Vector(2, 1)))
    }

    // MARK: - Convex hull

    @Test("convex hull of a known point set is correct (interior point excluded)")
    func hull() {
        // A unit square plus an interior point; the hull is the 4 square corners.
        let pts = [
            Vector(0, 0), Vector(4, 0), Vector(4, 4), Vector(0, 4),
            Vector(2, 2),               // interior — must be dropped
            Vector(1, 0), Vector(0, 3), // edge points — collinear, dropped
        ]
        let hull = OrientedBounds.convexHull(pts)
        // 4 corners only.
        #expect(hull.count == 4)
        // Every corner of the square is present.
        for corner in [Vector(0, 0), Vector(4, 0), Vector(4, 4), Vector(0, 4)] {
            #expect(hull.contains { approx($0, corner) })
        }
        // The interior point is NOT on the hull.
        #expect(!hull.contains { approx($0, Vector(2, 2)) })
    }

    @Test("convex hull is CCW for a simple triangle")
    func hullCCW() {
        let hull = OrientedBounds.convexHull([Vector(0, 0), Vector(4, 0), Vector(2, 3)])
        #expect(hull.count == 3)
        // Signed area > 0 ⇒ CCW.
        var area = 0.0
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            area += a.x * b.y - b.x * a.y
        }
        #expect(area > 0)
    }

    // MARK: - corners round-trip

    @Test("OrientedBounds.corners reconstructs an enclosing oriented quad")
    func cornersRoundTrip() {
        let center = Vector(2, 2)
        let angle = 0.7
        let input = rotatedRectCorners(center: center, hx: 5, hy: 1.5, angle: angle)
        let obb = OrientedBounds.minAreaRect(input)!
        let out = obb.corners
        #expect(out.count == 4)
        // Each input corner is matched by some output corner (the OBB hugs them).
        for inp in input {
            #expect(out.contains { approx($0, inp, 1e-6) })
        }
    }
}
