//
//  OrientedBounds.swift
//  CADEngine
//
//  A pure, value-type minimum-area ORIENTED bounding box (OBB) over a set of 2D
//  world points. Used by the on-canvas selection gizmo to keep the RESTING (idle)
//  selection chrome ORIENTED to a rotated object — a baked rotated rectangle is a
//  4-vertex polyline with no stored angle, so the orientation must be recovered
//  from the geometry. The classic minimum-area enclosing rectangle of a convex
//  polygon has one edge collinear with a hull edge (Freeman–Shapira), so we build
//  the convex hull (Andrew's monotone chain, O(n log n)) and test the bounding box
//  aligned to each hull edge, keeping the smallest-area one.
//
//  Why not just read an entity's stored angle? For a single entity with an
//  intrinsic rotation the caller takes that fast path directly; this helper is the
//  GENERAL fallback for a rotated rectangle / lines / polylines / multi-select,
//  where no single intrinsic angle exists.
//
//  Degenerate handling (so symmetric shapes don't pick a jittery arbitrary axis):
//    - < 2 distinct points            → nil
//    - collinear points               → a zero-thickness box along the line dir
//    - near-square within an epsilon   → angle 0 (axis-aligned tie-break)
//    - the axis-aligned box is already (near-)minimal → angle 0
//  The angle reports the LONG axis as the primary (width) direction, normalized to
//  (−π/2, +π/2] — a mod-π band. The long axis is the consistent primary direction
//  through a full 0→180° turn (it only "flips" at 180°, where the rectangle is
//  geometrically identical, so it's invisible). This keeps the resting gizmo's
//  rotate-knob anchored to a CONSISTENT edge across the 45°/90° boundaries instead
//  of swapping to the short axis (the old mod-π/2 fold did, which made the knob
//  "reset to the top" mid-rotation).
//
//  PURE (ADR-001/-003): value types, f64, no GUI/Metal/AppKit. Unit-tested in
//  `OrientedBoundsTests`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Oriented bounding box

/// A minimum-area oriented rectangle in world space (Y-up, f64): the `center`,
/// the CCW `angle` (radians) of the rectangle's local x-axis, and the
/// `halfExtents` along that rotated local frame (`x` = half-width along the local
/// x-axis, `y` = half-height along the local y-axis).
///
/// The four world corners are `center ± hx·û ± hy·v̂` where `û = (cos a, sin a)`
/// and `v̂ = (−sin a, cos a)`. A zero-thickness box (a line) has `halfExtents.y == 0`.
public struct OrientedBounds: Sendable, Equatable {
    /// The box center in world coords.
    public var center: Vector
    /// The CCW rotation (radians) of the box's local x-axis, normalized to
    /// `(−π/2, +π/2]` (a mod-π band). The local x-axis is the box's LONG axis, so
    /// the direction stays continuous through a full 0→180° turn. `0` means
    /// axis-aligned.
    public var angle: Double
    /// Half-extents along the box's LOCAL (rotated) axes: `x` along `û`, `y` along
    /// `v̂`. Both `>= 0`.
    public var halfExtents: Vector

    public init(center: Vector, angle: Double, halfExtents: Vector) {
        self.center = center
        self.angle = angle
        self.halfExtents = halfExtents
    }

    /// The full width along the local x-axis (`2 · halfExtents.x`).
    public var width: Double { halfExtents.x * 2 }
    /// The full height along the local y-axis (`2 · halfExtents.y`).
    public var height: Double { halfExtents.y * 2 }

    /// The four world corners, CCW from the local bottom-left:
    /// `[−hx−hy, +hx−hy, +hx+hy, −hx+hy]` (local BL, BR, TR, TL rotated by `angle`).
    public var corners: [Vector] {
        let u = Vector(cos(angle), sin(angle))
        let v = Vector(-sin(angle), cos(angle))
        let hx = halfExtents.x
        let hy = halfExtents.y
        return [
            center + u * (-hx) + v * (-hy),
            center + u * ( hx) + v * (-hy),
            center + u * ( hx) + v * ( hy),
            center + u * (-hx) + v * ( hy),
        ]
    }

    // MARK: - Construction

    /// The minimum-area oriented rectangle enclosing `points`, or `nil` if there
    /// are fewer than two distinct points.
    ///
    /// - `squareEpsilon`: a relative tolerance for the "near-square" tie-break. If
    ///   the best oriented box is within this fraction of area of the axis-aligned
    ///   box, the axis-aligned box (angle 0) is returned instead, so a square /
    ///   circle-sample / regular shape doesn't snap to an arbitrary jittery axis.
    public static func minAreaRect(_ points: [Vector],
                                   squareEpsilon: Double = 1e-6) -> OrientedBounds? {
        // Drop invalid/NaN points and project to the drawing plane (x, y).
        let pts = points.compactMap { p -> Vector? in
            guard p.valid, p.x.isFinite, p.y.isFinite else { return nil }
            return Vector(p.x, p.y)
        }
        guard pts.count >= 2 else { return nil }

        // The axis-aligned reference box (the angle-0 fallback + the tie-break ref).
        guard let aabb = axisAlignedBox(pts) else { return nil }

        // Need >= 2 DISTINCT points for any oriented result.
        guard hasTwoDistinctPoints(pts) else { return nil }

        let hull = convexHull(pts)

        // Collinear / degenerate hull (every point on one line): a zero-thickness
        // box along the line direction. `convexHull` returns 2 points for that.
        if hull.count < 3 {
            return collinearBox(pts) ?? aabb
        }

        // Rotating-calipers-style scan: the minimum-area rectangle is aligned to
        // SOME hull edge. Test each hull edge's aligned bounding box.
        var best: (area: Double, obb: OrientedBounds)? = nil
        let n = hull.count
        for i in 0..<n {
            let a = hull[i]
            let b = hull[(i + 1) % n]
            let edge = b - a
            let len = (edge.x * edge.x + edge.y * edge.y).squareRoot()
            guard len > Tolerance.distance else { continue }
            let edgeAngle = atan2(edge.y, edge.x)
            if let obb = boxAligned(to: edgeAngle, points: hull) {
                let area = obb.width * obb.height
                if best == nil || area < best!.area - Tolerance.distanceSquared {
                    best = (area, obb)
                }
            }
        }

        guard let bestOBB = best?.obb else { return aabb }

        let aabbArea = aabb.width * aabb.height
        let bestArea = bestOBB.width * bestOBB.height

        // Tie-break 1 — a (near-)ZERO-area best box is a line: keep its direction
        // (the oriented box IS the line, not the axis-aligned fallback).
        if bestArea <= Tolerance.distanceSquared {
            return bestOBB
        }

        // Tie-break 2 — a (near-)SQUARE best box is rotationally ambiguous (a square
        // / regular polygon / circle-sample has equal-area boxes at every angle), so
        // any chosen edge-angle is arbitrary + jittery. Snap to axis-aligned (0).
        // "Near-square" is measured on the best OBB's OWN extents (width ≈ height),
        // independent of the AABB — a rotated square's AABB is larger, so an AABB
        // comparison would wrongly keep the arbitrary angle.
        let w = bestOBB.width, h = bestOBB.height
        let longer = Swift.max(w, h)
        let shorter = Swift.min(w, h)
        if longer > 0, (longer - shorter) <= longer * squareEpsilon {
            return aabb
        }

        // Tie-break 3 — the oriented box doesn't beat the axis-aligned box by a
        // meaningful fraction of area (the shape is already essentially
        // axis-aligned): keep angle 0 for a stable, non-jittery resting frame.
        if aabbArea > Tolerance.distanceSquared, bestArea >= aabbArea * (1.0 - squareEpsilon) {
            return aabb
        }

        return bestOBB
    }

    // MARK: - Internals (pure helpers)

    /// The axis-aligned (angle-0) `OrientedBounds` of `pts`, or `nil` if empty.
    static func axisAlignedBox(_ pts: [Vector]) -> OrientedBounds? {
        guard var minX = pts.first?.x, var maxX = pts.first?.x,
              var minY = pts.first?.y, var maxY = pts.first?.y else { return nil }
        for p in pts {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return OrientedBounds(
            center: Vector((minX + maxX) * 0.5, (minY + maxY) * 0.5),
            angle: 0,
            halfExtents: Vector((maxX - minX) * 0.5, (maxY - minY) * 0.5))
    }

    /// The bounding box of `pts` measured in the frame rotated by `angle` (the
    /// box's local x-axis along `angle`). Returns the OBB in WORLD coords with the
    /// box's LONG axis chosen as the primary (width) direction, normalized to the
    /// mod-π band `(−π/2, +π/2]`.
    static func boxAligned(to angle: Double, points pts: [Vector]) -> OrientedBounds? {
        let c = cos(angle), s = sin(angle)
        // Project each point onto the rotated axes (u = (c,s), v = (−s,c)) by
        // rotating points by −angle (so the box is axis-aligned in that frame).
        guard let first = pts.first else { return nil }
        func proj(_ p: Vector) -> (u: Double, v: Double) {
            (u: p.x * c + p.y * s, v: -p.x * s + p.y * c)
        }
        var (minU, minV) = proj(first)
        var (maxU, maxV) = (minU, minV)
        for p in pts {
            let (u, v) = proj(p)
            minU = Swift.min(minU, u); maxU = Swift.max(maxU, u)
            minV = Swift.min(minV, v); maxV = Swift.max(maxV, v)
        }
        let cu = (minU + maxU) * 0.5
        let cv = (minV + maxV) * 0.5
        // Un-rotate the local center back to world.
        let center = Vector(cu * c - cv * s, cu * s + cv * c)
        let halfU = (maxU - minU) * 0.5
        let halfV = (maxV - minV) * 0.5
        // Report the LONG axis as the primary (width) direction, normalized mod π.
        return canonical(center: center, axisAngle: angle, halfU: halfU, halfV: halfV)
    }

    /// Builds the canonical `OrientedBounds` from a box measured in the frame whose
    /// x-axis (`û`) is at `axisAngle` with half-extents `halfU` (along `û`) and
    /// `halfV` (along `v̂ = û + 90°`).
    ///
    /// Long-axis convention: pick whichever of `û` / `v̂` carries the LARGER extent
    /// as the box's primary (width) direction, then normalize THAT direction into
    /// the mod-π band `(−π/2, +π/2]`. Normalizing by ±π flips both axes
    /// (`û → −û`, `v̂ → −v̂`) which preserves the box (corners use ±extents), so the
    /// half-extent ↔ axis attachment stays consistent with the reported angle — the
    /// reported `angle`/`halfExtents` reproduce the SAME 4 corners. There is NO
    /// 90° swap at 45° anymore, so the orientation is continuous through 0→180°.
    private static func canonical(center: Vector, axisAngle: Double,
                                  halfU: Double, halfV: Double) -> OrientedBounds {
        // Choose the primary (width) axis = the longer half-extent's axis.
        let primaryAngle: Double
        let hx: Double  // half-extent along the primary axis
        let hy: Double  // half-extent along the perpendicular (secondary) axis
        if halfV > halfU {
            // `v̂` (at axisAngle + 90°) is the long axis → make it primary.
            primaryAngle = axisAngle + Double.pi / 2
            hx = halfV
            hy = halfU
        } else {
            primaryAngle = axisAngle
            hx = halfU
            hy = halfV
        }
        return OrientedBounds(center: center,
                              angle: normalizeAngle(primaryAngle),
                              halfExtents: Vector(hx, hy))
    }

    /// A zero-thickness box along the dominant direction of (near-)collinear pts.
    static func collinearBox(_ pts: [Vector]) -> OrientedBounds? {
        // Direction = farthest-apart pair direction (stable for collinear input).
        guard pts.count >= 2 else { return nil }
        var a = pts[0], b = pts[1]
        var bestD = (b - a).squared
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = (pts[j] - pts[i]).squared
                if d > bestD { bestD = d; a = pts[i]; b = pts[j] }
            }
        }
        let dir = b - a
        guard dir.squared > Tolerance.distanceSquared else { return nil }
        let ang = atan2(dir.y, dir.x)
        return boxAligned(to: ang, points: pts)
    }

    /// `true` if `pts` contains at least two points farther apart than the
    /// distance tolerance.
    static func hasTwoDistinctPoints(_ pts: [Vector]) -> Bool {
        guard let first = pts.first else { return false }
        for p in pts where (p - first).squared > Tolerance.distanceSquared {
            return true
        }
        // All near `first` — but check pairwise in case `first` is a duplicate of
        // a cluster while two others differ (rare; cheap guard).
        for i in 1..<pts.count {
            for j in (i + 1)..<pts.count where (pts[j] - pts[i]).squared > Tolerance.distanceSquared {
                return true
            }
        }
        return false
    }

    /// Normalizes a DIRECTION angle into the mod-π band `(−π/2, +π/2]` — a
    /// direction and its 180° reverse are the same line, so reducing by ±π keeps
    /// the long-axis direction in one half-plane while preserving the box (the box
    /// uses ±extents, so flipping the axis by 180° reproduces the same corners).
    static func normalizeAngle(_ a: Double) -> Double {
        let pi = Double.pi
        // `remainder(dividingBy: π)` lands in [−π/2, +π/2]; nudge an exact −π/2 up to
        // +π/2 so the band is the half-open (−π/2, +π/2] (its two endpoints are the
        // same direction).
        var x = a.remainder(dividingBy: pi)
        if x <= -pi / 2 { x += pi }
        // Snap a numerically-tiny angle to exactly 0 for a stable axis-aligned case.
        if abs(x) < Tolerance.angle { x = 0 }
        return x
    }

    /// Andrew's monotone-chain convex hull of `pts`, CCW, without the duplicated
    /// last point. Returns 2 points for a collinear set, 1 for a single distinct
    /// point. Pure, O(n log n).
    static func convexHull(_ pts: [Vector]) -> [Vector] {
        // Deduplicate (bit-exact is fine after sort dedup of near-equal).
        var sorted = pts.sorted {
            $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y)
        }
        // Remove exact-duplicate neighbours after the sort.
        var unique: [Vector] = []
        for p in sorted {
            if let last = unique.last, (p - last).squared <= Tolerance.distanceSquared { continue }
            unique.append(p)
        }
        sorted = unique
        if sorted.count <= 2 { return sorted }

        func cross(_ o: Vector, _ a: Vector, _ b: Vector) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [Vector] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= Tolerance.distanceSquared {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Vector] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= Tolerance.distanceSquared {
                upper.removeLast()
            }
            upper.append(p)
        }
        // Concatenate, dropping each chain's last point (it's the other's first).
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        // A truly collinear set collapses to 2 endpoints.
        if hull.count < 3 {
            // Fall back to the two extreme points.
            return [sorted.first!, sorted.last!]
        }
        return hull
    }
}
