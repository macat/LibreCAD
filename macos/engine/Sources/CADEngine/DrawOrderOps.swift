//
//  DrawOrderOps.swift
//  CADEngine
//
//  The GPU-free, pure-value engine logic behind the v5 "Arrange" (draw order)
//  and "Revert direction" entity operations (feature-catalog F16 / catalog §3):
//
//    • `DrawOrder` — the one-step raise/lower permutation math over an ordered
//      `[EntityID]` Z-stack (front-most last, matching the renderer's storage-order
//      iteration). `CADDrawing` calls these to compute the new order, then applies
//      it as ONE undoable step (the to-front / to-back ops are simple partitions
//      done directly in `CADDrawing`).
//
//    • `EntityDirection` — flips an entity's geometric *direction* (its defining
//      traversal order) WITHOUT changing the drawn shape: a line's endpoints swap,
//      a polyline's vertex order reverses (with the DXF bulge semantics carried to
//      the correct following segment), an arc/ellipse arc's sweep flag toggles, a
//      spline's control points reverse. Mirrors LibreCAD's `RS_Entity::revertDirection`
//      family. Kinds with no meaningful direction return `nil` (a no-op).
//
//  Both are namespaced enums of `static` members (no module-scope free functions —
//  CONVENTIONS §7 fan-out rule) and pure value transforms, so they are fully
//  unit-testable without the app or a GPU.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Entity::revertDirection / draw order).
//

import Foundation

// MARK: - Draw order (raise / lower one step)

/// Pure permutation helpers for the entity Z-stack. The stack is an ordered
/// `[EntityID]` where the LAST element is front-most (painted on top), matching
/// the renderer drawing `entities` in storage order. `moving` is the set of ids to
/// shift; they move as a block by one position past the nearest non-moving
/// neighbour in the requested direction.
public enum DrawOrder {

    /// Raises every id in `moving` one step toward the FRONT (the array tail). Walk
    /// from the front: each moving id swaps with the FIRST non-moving id ahead of
    /// it, so a moving block slides up by one past the next stationary entity. Ids
    /// already at the front (nothing stationary ahead) stay put. The relative order
    /// among the moving ids is preserved. A `moving` set that is empty, covers
    /// everything, or matches none of `order` returns `order` unchanged.
    public static func raised(_ order: [EntityID], moving: Set<EntityID>) -> [EntityID] {
        guard !moving.isEmpty, moving.count < order.count else { return order }
        var result = order
        // Walk from the SECOND-TO-LAST down to the front. For each moving entity,
        // if the slot immediately AHEAD (higher index) holds a non-moving entity,
        // swap them — moving it one step toward the front. Going top-down ensures a
        // contiguous moving block slides together without leap-frogging itself.
        var i = result.count - 2
        while i >= 0 {
            let here = result[i]
            let ahead = result[i + 1]
            if moving.contains(here), !moving.contains(ahead) {
                result.swapAt(i, i + 1)
            }
            i -= 1
        }
        return result
    }

    /// Lowers every id in `moving` one step toward the BACK (the array head) — the
    /// mirror of `raised`. Walk from the back: each moving id swaps with the first
    /// non-moving id behind it.
    public static func lowered(_ order: [EntityID], moving: Set<EntityID>) -> [EntityID] {
        guard !moving.isEmpty, moving.count < order.count else { return order }
        var result = order
        var i = 1
        while i < result.count {
            let here = result[i]
            let behind = result[i - 1]
            if moving.contains(here), !moving.contains(behind) {
                result.swapAt(i, i - 1)
            }
            i += 1
        }
        return result
    }
}

// MARK: - Revert direction (flip an entity's defining order)

/// Pure "revert direction" transforms: return a NEW `EntityKind` whose defining
/// direction is reversed but whose drawn shape is identical, or `nil` for a kind
/// with no meaningful direction (so the caller can treat it as a no-op).
public enum EntityDirection {

    /// The direction-reversed form of `kind`, or `nil` if the kind has no
    /// reversible direction (point / circle / text / hatch / solid / dimension /
    /// insert / construction lines). The geometry drawn is unchanged — only the
    /// order it is defined in flips.
    public static func reversed(_ kind: EntityKind) -> EntityKind? {
        switch kind {
        case .line(let d):
            // Swap the endpoints — same segment, opposite direction.
            return .line(LineData(start: d.end, end: d.start))

        case .arc(let d):
            // Swap start/end angle and toggle the sweep flag so the SAME arc is
            // traversed the other way (LibreCAD `RS_Arc::revertDirection`).
            return .arc(ArcData(
                center: d.center, radius: d.radius,
                startAngle: d.endAngle, endAngle: d.startAngle,
                reversed: !d.reversed))

        case .ellipse(let d):
            // Same scheme as the arc (a whole ellipse, startAngle==endAngle==0,
            // is unchanged by the swap but the toggled flag still flips winding).
            return .ellipse(EllipseData(
                center: d.center, majorP: d.majorP, ratio: d.ratio,
                startAngle: d.endAngle, endAngle: d.startAngle,
                reversed: !d.reversed))

        case .polyline(let d):
            return .polyline(reversedPolyline(d))

        case .spline(let d):
            // Reverse the control polygon, weights, and the knot vector (mirrored
            // about its span) so the curve is identical but parameterised the other
            // way. Empty knots/weights stay empty (resolve() generates a clamped
            // vector / treats it as non-rational).
            var s = d
            s.controlPoints = Array(d.controlPoints.reversed())
            if !d.weights.isEmpty { s.weights = Array(d.weights.reversed()) }
            if let mirrored = mirroredKnots(d.knots) { s.knots = mirrored }
            return .spline(s)

        case .splinePoints(let d):
            var s = d
            s.controlPoints = Array(d.controlPoints.reversed())
            return .splinePoints(s)

        case .point, .circle, .text, .mtext, .hatch, .solid, .dimension,
             .insert, .xline, .ray, .leader, .multileader, .image:
            // No meaningful direction to revert (a raster image's u/v placement has
            // no "traversal direction" — flipping it would mirror the picture, which
            // is a TRANSFORM, not a reverse). A (multi)leader is an annotation
            // callout: its leg order is not user-reversible here.
            return nil
        }
    }

    /// Reverses a polyline's vertex order while preserving the DXF bulge semantics:
    /// a vertex's `bulge` describes the arc on the segment that FOLLOWS it, so when
    /// the order flips, each segment's bulge must move to the new preceding vertex
    /// AND negate (the arc now sweeps the other way). Concretely the reversed
    /// bulge at new index `i` is `-bulge` of the vertex that was the segment's far
    /// end. The `closed` flag is preserved.
    static func reversedPolyline(_ d: PolylineData) -> PolylineData {
        let pts = d.vertices
        guard pts.count >= 2 else {
            // 0/1 vertices: reversing is a no-op on geometry; just copy.
            return d
        }
        let n = pts.count
        var out: [PolylineVertex] = []
        out.reserveCapacity(n)
        // New vertex order is the points reversed; the bulge carried at each new
        // vertex is the NEGATED bulge of the segment that now follows it. For an
        // OPEN polyline the original segment bulges are at indices 0..<n-1 (the
        // last vertex carries none); reversed, the segment between new[i] and
        // new[i+1] is the original segment between old[n-1-i] and old[n-2-i], whose
        // bulge lived on old[n-2-i].
        for i in 0..<n {
            let oldIndex = n - 1 - i
            // The bulge for the new following segment (i → i+1) comes from the old
            // vertex that was the START of that segment in the original direction:
            // old[oldIndex - 1] for an open run; the closing wrap for a closed one.
            var bulge = 0.0
            if i < n - 1 {
                bulge = -pts[oldIndex - 1].bulge
            } else if d.closed {
                // Closed: the new last→first segment is the old first→last segment,
                // whose bulge lived on the old LAST vertex.
                bulge = -pts[n - 1].bulge
            }
            out.append(PolylineVertex(point: pts[oldIndex].point, bulge: bulge))
        }
        return PolylineData(vertices: out, closed: d.closed)
    }

    /// Mirrors a knot vector about its own span so a reversed control polygon yields
    /// the identical curve: `kᵢ' = (k_first + k_last) − k_{n-1-i}`. Empty input
    /// returns `nil` (the caller keeps the empty vector → resolve regenerates one).
    static func mirroredKnots(_ knots: [Double]) -> [Double]? {
        guard let first = knots.first, let last = knots.last, knots.count >= 2 else {
            return nil
        }
        let span = first + last
        return knots.reversed().map { span - $0 }
    }
}
