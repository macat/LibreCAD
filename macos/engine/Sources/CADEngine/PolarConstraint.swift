//
//  PolarConstraint.swift
//  CADEngine
//
//  The pure polar (angle-increment) point constraint — LibreCAD's "polar
//  tracking" restriction (`RS_Snapper::snapPoint` angular branch). While a draw
//  tool is taking a point, polar locks the candidate point onto the ray from the
//  reference (last) point at the NEAREST multiple of a fixed angular increment
//  (e.g. 15°), preserving the cursor's distance from the reference. This snaps a
//  line/rectangle/etc. drawn under polar to a discrete set of angles.
//
//  Unlike ortho (which is two fixed axes), polar is a finer-grained angular lock:
//  ortho with a 90° increment is the same family of constraint. Both are point
//  CONSTRAINTS, not snap candidates — they are NOT `SnapKind`/`SnapMode` cases
//  (see Snapping.swift's NOTE on result kinds). The canvas calls this on the
//  point-input path; osnap still overrides it (see the canvas interaction layer).
//
//  This is a stateless f64 geometry kernel (ADR-003) taking primitive points so it
//  is trivially unit-testable from the engine test target. Static member of a
//  namespaced `enum` per CONVENTIONS.md (no module-scope free functions in a
//  fan-out target). As in ortho, `z` is passed through (the 2D workflow).
//
//  GPLv2-or-later (LibreCAD derivative). Polar semantics port RS_Snapper's
//  angular restriction (librecad/src/lib/actions/rs_snapper.cpp).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper angular restriction).
//

import Foundation

/// Namespaced static helper for the polar (angle-increment) point constraint.
public enum PolarConstraint {

    /// Locks `point` onto the ray from `reference` at the nearest multiple of
    /// `incrementRadians`, preserving the reference→point distance.
    ///
    /// The vector `reference → point` is measured; its angle is rounded to the
    /// nearest multiple of `incrementRadians`, and the result is placed at that
    /// snapped angle at the original distance. With `incrementRadians == .pi/2`
    /// this degenerates to the four ortho axes (but unlike `OrthoConstraint` it
    /// preserves distance rather than dropping the off-axis component).
    ///
    /// Degenerate inputs are returned unchanged so the constraint never
    /// manufactures a bogus coordinate:
    ///   • an invalid `point` or `reference`,
    ///   • a non-positive (or non-finite) `incrementRadians`,
    ///   • a `point` coincident with `reference` (zero direction — no angle).
    ///
    /// - Parameters:
    ///   - point: the raw (already-in-world) candidate point the tool would
    ///     receive.
    ///   - reference: the point polar is measured from — the tool's last placed
    ///     point (relative-zero). With no reference the caller should skip the
    ///     constraint.
    ///   - incrementRadians: the angular step the result snaps to (e.g. `.pi/12`
    ///     for 15°). Must be positive and finite.
    /// - Returns: the angle-locked point at the preserved distance (or `point`
    ///   unchanged when an input is degenerate).
    public static func constrain(
        _ point: Vector,
        relativeTo reference: Vector,
        incrementRadians: Double
    ) -> Vector {
        guard point.valid, reference.valid else { return point }
        guard incrementRadians.isFinite, incrementRadians > 0 else { return point }

        let dx = point.x - reference.x
        let dy = point.y - reference.y

        // Coincident point: no direction to snap. Return unchanged.
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return point }

        let rawAngle = atan2(dy, dx)
        let steps = (rawAngle / incrementRadians).rounded()   // nearest multiple
        let snappedAngle = steps * incrementRadians

        return Vector(
            reference.x + distance * cos(snappedAngle),
            reference.y + distance * sin(snappedAngle),
            point.z
        )
    }
}
