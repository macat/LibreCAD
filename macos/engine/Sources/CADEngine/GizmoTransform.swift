//
//  GizmoTransform.swift
//  CADEngine
//
//  Pure transform math for the on-canvas SELECTION GIZMO — the direct-manipulation
//  handles (move body / corner scale / rotate knob) drawn around a selection in
//  Select mode. This file is the single, testable source of truth for "a drag of a
//  given gizmo handle from world point p0 to world point p1 yields THIS `Affine2D`",
//  so the view layer (hit-testing + screen drawing in LibreCADmacOS) carries no
//  geometry math of its own — it only maps screen↔world and routes the resulting
//  transform through the existing undoable commit path.
//
//  It reuses the SAME shared transform primitives the in-canvas MODIFY tools build
//  (`Affine2D.translation` / `.rotation(angle:about:)` / `.scale(factor:about:)`),
//  so a gizmo edit and the equivalent Move/Rotate/Scale tool edit produce identical
//  geometry (and round-trip through `EntityKind.transformed(by:)` the same way).
//
//  Conventions:
//    - All points are WORLD coordinates (Y-up; the view converts screen→world).
//    - The gizmo frame is the selection's axis-aligned bounding box (`GizmoFrame`),
//      whose corners/edge-midpoints/center give the handle anchor points.
//    - Move    : translate by `p1 − p0`.
//    - Corner  : UNIFORM scale about the OPPOSITE corner; factor is the ratio of the
//                dragged corner's distance from that pivot, new ÷ old.
//    - Rotate  : rotate about the box center by `angle(center→p1) − angle(center→p0)`.
//    - Shift   : constrained variants — axis-locked move, 15° rotation snap.
//
//  PURE (ADR-001/-003): value types, f64, no GUI/Metal/AppKit. Unit-tested in
//  `GizmoTransformTests`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_* transform semantics reused
//  via Affine2D / EntityTransform).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Gizmo frame (the selection's box → handle anchor points)

/// The axis-aligned frame the gizmo is drawn around (the selection's world-space
/// bounding box). Exposes the named anchor points the handles attach to so the
/// view never recomputes corner geometry by hand.
///
/// Corner naming is in WORLD space (Y-up): `min` is the bottom-left, `max` the
/// top-right. The "opposite corner" of a dragged corner (the scale pivot) is the
/// box corner diagonal to it.
public struct GizmoFrame: Sendable, Equatable {
    /// The box minimum corner (bottom-left in world Y-up).
    public var min: Vector
    /// The box maximum corner (top-right in world Y-up).
    public var max: Vector

    public init(min: Vector, max: Vector) {
        self.min = min
        self.max = max
    }

    /// Builds a frame from a world-space AABB (uses only x/y; z is dropped to 0 so
    /// the gizmo lives in the drawing plane). Returns `nil` for an empty box.
    public init?(box: AABB) {
        guard !box.isEmpty else { return nil }
        self.min = Vector(box.min.x, box.min.y)
        self.max = Vector(box.max.x, box.max.y)
    }

    /// The box center (the rotate pivot and the move grab point).
    public var center: Vector { Vector((min.x + max.x) * 0.5, (min.y + max.y) * 0.5) }

    /// Box width (x extent), always `>= 0`.
    public var width: Double { max.x - min.x }
    /// Box height (y extent), always `>= 0`.
    public var height: Double { max.y - min.y }

    /// The four corners, in world Y-up. `bottomLeft == min`, `topRight == max`.
    public var bottomLeft: Vector  { Vector(min.x, min.y) }
    public var bottomRight: Vector { Vector(max.x, min.y) }
    public var topRight: Vector    { Vector(max.x, max.y) }
    public var topLeft: Vector     { Vector(min.x, max.y) }

    /// The corners keyed by `GizmoHandle.Corner` (for hit-testing / drawing).
    public func corner(_ c: GizmoHandle.Corner) -> Vector {
        switch c {
        case .bottomLeft:  return bottomLeft
        case .bottomRight: return bottomRight
        case .topRight:    return topRight
        case .topLeft:     return topLeft
        }
    }

    /// The corner diagonally opposite `c` — the pivot a corner-scale drag is about
    /// (dragging a corner scales the box while the opposite corner stays put).
    public func oppositeCorner(_ c: GizmoHandle.Corner) -> Vector {
        corner(c.opposite)
    }

    /// The anchor point of the rotate KNOB: above the top edge center by
    /// `knobOffset` world units (a stalk rising from the top edge). The view passes
    /// a world offset derived from a constant pixel offset so the knob stays a fixed
    /// on-screen distance across zoom.
    public func rotateKnob(offset knobOffset: Double) -> Vector {
        Vector((min.x + max.x) * 0.5, max.y + knobOffset)
    }
}

// MARK: - Gizmo handles

/// The identifiable parts of the gizmo the user can grab.
public enum GizmoHandle: Sendable, Equatable, Hashable {
    /// The body / center — drag to translate the whole selection.
    case move
    /// A corner square — drag to uniformly scale about the opposite corner.
    case corner(Corner)
    /// The knob above the box — drag to rotate about the box center.
    case rotate

    /// The four box corners (world Y-up naming).
    public enum Corner: Sendable, Equatable, Hashable, CaseIterable {
        case bottomLeft, bottomRight, topRight, topLeft

        /// The diagonally-opposite corner (the scale pivot for this corner's drag).
        public var opposite: Corner {
            switch self {
            case .bottomLeft:  return .topRight
            case .bottomRight: return .topLeft
            case .topRight:    return .bottomLeft
            case .topLeft:     return .bottomRight
            }
        }
    }
}

// MARK: - The transform builders (pure)

/// Pure builders mapping a gizmo drag to an `Affine2D`. Static members of a
/// namespaced `enum` (CONVENTIONS.md: no module-scope free functions in a
/// fan-out target). Every result composes from the SHARED `Affine2D` statics so a
/// gizmo edit equals the equivalent Move/Rotate/Scale tool edit.
public enum GizmoTransform {

    /// 15 degrees in radians — the Shift rotation snap increment.
    public static let rotationSnap: Double = .pi / 12

    // MARK: Move

    /// The translation for a MOVE drag from `p0` to `p1`.
    ///
    /// - `constrained == true` (Shift held) locks the motion to the dominant axis:
    ///   the larger of |Δx|/|Δy| is kept, the other zeroed (axis-constrained move).
    public static func move(from p0: Vector, to p1: Vector, constrained: Bool = false) -> Affine2D {
        guard p0.valid, p1.valid else { return .identity }
        var delta = p1 - p0
        if constrained {
            if abs(delta.x) >= abs(delta.y) { delta = Vector(delta.x, 0) }
            else { delta = Vector(0, delta.y) }
        }
        return .translation(Vector(delta.x, delta.y))
    }

    // MARK: Corner scale

    /// The UNIFORM scale `Affine2D` for dragging `corner` of `frame` from world
    /// point `p0` to world point `p1`, pivoting about the OPPOSITE corner.
    ///
    /// The factor is the ratio of the dragged point's distance from the pivot
    /// (new ÷ old). To stay robust when the box is thin in one axis (so the corner
    /// is nearly on the pivot's row/column), the distance is taken as the full
    /// pivot→point vector length (a similarity factor) rather than a single axis.
    /// A degenerate result (pivot ≈ p0, factor ≈ 0, or a non-finite factor) returns
    /// `.identity` so the caller commits nothing.
    ///
    /// NOTE: `p0` is the drag's START point — which the view passes as the corner's
    /// own world position at mouse-down, so `|p0 − pivot|` is exactly the box's
    /// current diagonal half/edge length and the factor is "how much bigger the box
    /// got". Passing the live corner position as `p0` (not the raw cursor) keeps the
    /// factor exact even if the click landed slightly off the handle center.
    public static func cornerScale(
        frame: GizmoFrame,
        corner: GizmoHandle.Corner,
        from p0: Vector,
        to p1: Vector
    ) -> Affine2D {
        guard p0.valid, p1.valid else { return .identity }
        let pivot = frame.oppositeCorner(corner)
        let oldDist = (p0 - pivot).magnitude
        let newDist = (p1 - pivot).magnitude
        guard oldDist > Tolerance.distance else { return .identity }
        let factor = newDist / oldDist
        guard factor.isFinite, factor > Tolerance.distance else { return .identity }
        return .scale(factor: factor, about: pivot)
    }

    /// UNIFORM scale `Affine2D` for a corner drag from `p0` to `p1` about an
    /// EXPLICIT `pivot` — the point-based overload the ORIENTED gizmo uses so the
    /// pivot is the oriented opposite-corner (not the axis-aligned `frame`'s). The
    /// math is identical to `cornerScale(frame:corner:from:to:)` once the pivot is
    /// fixed (that variant just derives the pivot from the upright frame), so a
    /// rotated box scales about the right corner and the resulting world `Affine2D`
    /// rounds through the same undoable commit path. Degenerate → `.identity`.
    public static func cornerScale(pivot: Vector, from p0: Vector, to p1: Vector) -> Affine2D {
        guard pivot.valid, p0.valid, p1.valid else { return .identity }
        let oldDist = (p0 - pivot).magnitude
        let newDist = (p1 - pivot).magnitude
        guard oldDist > Tolerance.distance else { return .identity }
        let factor = newDist / oldDist
        guard factor.isFinite, factor > Tolerance.distance else { return .identity }
        return .scale(factor: factor, about: pivot)
    }

    /// The uniform scale FACTOR alone for a corner drag (exposed for the view's HUD
    /// and for tests asserting the factor directly). Mirrors `cornerScale`'s math;
    /// returns `nil` for a degenerate drag.
    public static func cornerScaleFactor(
        frame: GizmoFrame,
        corner: GizmoHandle.Corner,
        from p0: Vector,
        to p1: Vector
    ) -> Double? {
        guard p0.valid, p1.valid else { return nil }
        let pivot = frame.oppositeCorner(corner)
        let oldDist = (p0 - pivot).magnitude
        guard oldDist > Tolerance.distance else { return nil }
        let factor = (p1 - pivot).magnitude / oldDist
        guard factor.isFinite, factor > Tolerance.distance else { return nil }
        return factor
    }

    // MARK: Rotate

    /// The rotation `Affine2D` for dragging the rotate knob of `frame` from world
    /// point `p0` to world point `p1`, pivoting about the box CENTER.
    ///
    /// The swept angle is `angle(center→p1) − angle(center→p0)`, normalized to
    /// `(−π, +π]`. With `snap == true` (Shift held) it is rounded to the nearest
    /// 15° increment. A near-zero angle (or either point at the center) returns
    /// `.identity`.
    public static func rotate(
        frame: GizmoFrame,
        from p0: Vector,
        to p1: Vector,
        snap: Bool = false
    ) -> Affine2D {
        guard let angle = rotateAngle(frame: frame, from: p0, to: p1, snap: snap) else {
            return .identity
        }
        return .rotation(angle: angle, about: frame.center)
    }

    /// The rotation `Affine2D` for a knob drag from `p0` to `p1` about an EXPLICIT
    /// `center` — the point-based overload the ORIENTED gizmo uses so the pivot is
    /// the oriented box center. Identical to `rotate(frame:from:to:snap:)` once the
    /// center is fixed. A near-zero sweep (or a point at the center) → `.identity`.
    public static func rotate(center: Vector, from p0: Vector, to p1: Vector, snap: Bool = false) -> Affine2D {
        guard let angle = rotateAngle(center: center, from: p0, to: p1, snap: snap) else {
            return .identity
        }
        return .rotation(angle: angle, about: center)
    }

    /// The swept rotation ANGLE about an EXPLICIT `center` (radians, `(−π, +π]`), or
    /// `nil` for a degenerate drag. The shared core both the frame-based and
    /// point-based `rotate*` call.
    public static func rotateAngle(center: Vector, from p0: Vector, to p1: Vector, snap: Bool = false) -> Double? {
        guard center.valid, p0.valid, p1.valid,
              (p0 - center).magnitude > Tolerance.distance,
              (p1 - center).magnitude > Tolerance.distance else {
            return nil
        }
        let a0 = center.angleTo(p0)
        let a1 = center.angleTo(p1)
        var delta = MathUtils.correctAnglePlusMinusPi(a1 - a0)
        if snap {
            delta = (delta / rotationSnap).rounded() * rotationSnap
        }
        guard abs(delta) > Tolerance.angle else { return nil }
        return delta
    }

    /// The swept rotation ANGLE alone (radians, `(−π, +π]`), or `nil` for a
    /// degenerate drag. Exposed for the view's HUD and for tests.
    public static func rotateAngle(
        frame: GizmoFrame,
        from p0: Vector,
        to p1: Vector,
        snap: Bool = false
    ) -> Double? {
        rotateAngle(center: frame.center, from: p0, to: p1, snap: snap)
    }

    // MARK: Oriented frame chrome (for the DRAWN gizmo during a drag)

    /// The four ORIENTED world corners of `base` after applying the live drag
    /// transform `t`, in order **[bottomLeft, bottomRight, topRight, topLeft]**.
    ///
    /// This is the single source of truth the overlay draws its frame outline +
    /// corner squares from while dragging, so the chrome rotates/scales WITH the
    /// object preview (which re-resolves each entity through the SAME `t`) instead
    /// of collapsing back to an upright AABB. Identity `t` yields exactly the base
    /// AABB corners in that order.
    ///
    /// The order matches `GizmoHandle.Corner`'s geometry (`bottomLeft == min`,
    /// `topRight == max`), traversed CCW (BL→BR→TR→TL) so consecutive entries form
    /// a closed quad edge-by-edge.
    public static func transformedQuad(base: GizmoFrame, t: Affine2D) -> [Vector] {
        let corners: [GizmoHandle.Corner] = [.bottomLeft, .bottomRight, .topRight, .topLeft]
        return corners.map { t.apply(base.corner($0)) }
    }

    /// The rotate-knob STALK anchor for the oriented frame: the world `root` (the
    /// transformed top-edge midpoint) and the unit `outward` normal of the
    /// transformed top edge, pointing AWAY from the transformed box center.
    ///
    /// The stalk rises from `root` along `outward`; the view places the knob a fixed
    /// on-screen distance up that direction (projected to screen). The outward sign
    /// is chosen so the stalk always points out of the box in all four quadrants
    /// (for a 90° rotation the stalk turns with the box). Returns a zero `outward`
    /// for a degenerate (zero-area / collinear) transformed top edge.
    public static func transformedKnobAnchor(base: GizmoFrame, t: Affine2D) -> (root: Vector, outward: Vector) {
        let topLeft = t.apply(base.topLeft)
        let topRight = t.apply(base.topRight)
        let root = Vector((topLeft.x + topRight.x) * 0.5, (topLeft.y + topRight.y) * 0.5)

        // The top edge direction (TL→TR); its normal is the candidate outward.
        let edge = topRight - topLeft
        let len = (edge.x * edge.x + edge.y * edge.y).squareRoot()
        guard len > Tolerance.distance else {
            return (root: root, outward: Vector(0, 0))
        }
        // Two unit normals of the edge; pick the one pointing away from the center.
        var normal = Vector(-edge.y / len, edge.x / len)
        let center = t.apply(base.center)
        let centerToRoot = root - center
        if normal.x * centerToRoot.x + normal.y * centerToRoot.y < 0 {
            normal = Vector(-normal.x, -normal.y)
        }
        return (root: root, outward: normal)
    }

    // MARK: Oriented hit-testing (point-in-quad)

    /// Convex-quad containment of point `p` in `quad` (exactly 4 points, CW or CCW),
    /// expanded outward by `slop` on every edge. Winding-agnostic: the test derives
    /// the polygon winding from its signed area, so a screen projection that flips
    /// handedness still tests correctly. Used by the overlay's body/move hit-test on
    /// the screen-projected ORIENTED chrome quad (a rotated box is no longer an
    /// axis-aligned rect, so a plain rect-containment test would miss).
    ///
    /// `slop` is in the same units as `quad`/`p` (the overlay passes SCREEN points).
    /// Returns `false` for a non-quad input or a degenerate (zero-area) quad.
    public static func pointInConvexQuad(_ p: Vector, quad: [Vector], slop: Double = 0) -> Bool {
        guard quad.count == 4 else { return false }
        var area = 0.0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        guard abs(area) > Tolerance.distance else { return false }
        let ccw = area > 0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let ex = b.x - a.x, ey = b.y - a.y
            let len = (ex * ex + ey * ey).squareRoot()
            guard len > Tolerance.distance else { continue }
            // Signed distance of p from the directed edge a→b (positive = left).
            let dist = (ex * (p.y - a.y) - ey * (p.x - a.x)) / len
            if ccw {
                if dist < -slop { return false }   // inside == left of every edge
            } else {
                if dist > slop { return false }    // inside == right of every edge
            }
        }
        return true
    }
}
