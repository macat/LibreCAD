//
//  OrthoConstraint.swift
//  CADEngine
//
//  The pure ortho (orthogonal) point constraint — LibreCAD's "Ortho" restriction
//  (`RS_ActionDefault` / `RS_Snapper::snapPoint` ortho branch). While a draw tool
//  is taking a point, ortho locks the candidate point to the horizontal OR vertical
//  axis through the reference (last) point: the point keeps the dominant offset and
//  zeroes the other, so a line/rectangle/etc. drawn under ortho is axis-aligned.
//
//  This is a stateless f64 geometry kernel (ADR-003) taking primitive points so it
//  is trivially unit-testable from the engine test target (the app's `CanvasModel`/
//  `CADCanvasView` call it on the point-input path; osnap still overrides it — see
//  the canvas interaction layer). Static member of a namespaced `enum` per
//  CONVENTIONS.md (no module-scope free functions in a fan-out target).
//
//  GPLv2-or-later (LibreCAD derivative). Ortho semantics port RS_Snapper's ortho
//  restriction (librecad/src/lib/actions/rs_snapper.cpp).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Snapper ortho restriction).
//

import Foundation

/// Namespaced static helper for the ortho point constraint.
public enum OrthoConstraint {

    /// Axis-locks `point` to the horizontal or vertical line through `reference`.
    ///
    /// The dominant axis wins: with `|Δx| >= |Δy|` the point is locked to the
    /// HORIZONTAL through `reference` (its `y` becomes `reference.y`, keeping `x`);
    /// otherwise to the VERTICAL (its `x` becomes `reference.x`, keeping `y`). The
    /// tie (`|Δx| == |Δy|`, e.g. an exact diagonal) resolves to horizontal, a stable
    /// arbitrary choice. An invalid input (either point not `valid`) is returned
    /// unchanged so the constraint never manufactures a bogus coordinate.
    ///
    /// - Parameters:
    ///   - point: the raw (already-in-world) candidate point the tool would receive.
    ///   - reference: the point ortho is measured from — the tool's last placed point
    ///     (relative-zero). With no reference the caller should skip the constraint.
    /// - Returns: the axis-locked point (or `point` unchanged when inputs are invalid).
    public static func constrain(_ point: Vector, relativeTo reference: Vector) -> Vector {
        guard point.valid, reference.valid else { return point }
        let dx = point.x - reference.x
        let dy = point.y - reference.y
        if abs(dx) >= abs(dy) {
            // Horizontal lock: keep x, snap y to the reference row.
            return Vector(point.x, reference.y)
        } else {
            // Vertical lock: keep y, snap x to the reference column.
            return Vector(reference.x, point.y)
        }
    }

    // MARK: - Isometric ortho (Wave 3 — iso analog of the H/V lock)

    /// Iso-ortho: axis-locks `point` to the NEAREST of the active iso `plane`'s two
    /// drawing-axis directions, through `reference`. The isometric analog of the
    /// rectangular `constrain(_:relativeTo:)` — instead of locking to horizontal or
    /// vertical, it locks the offset to whichever of the plane's two iso axes (e.g.
    /// 30°/150° for `.top`) the candidate is closest to, so a segment drawn under iso
    /// ortho lies along an iso axis.
    ///
    /// MATH: let `d = point − reference`. Each plane axis `aᵢ` is a unit direction
    /// (`plane.axisDirections`). The locked point is `reference + aᵢ · (d · aᵢ)` for
    /// the axis whose absolute scalar projection `|d · aᵢ|` is LARGER — i.e. the
    /// projection of `d` onto the closer axis line. (`d · aᵢ` is signed, so the lock
    /// follows `d` onto either half of the axis, including the negative direction.)
    /// Projecting onto the axis with the larger `|d · aᵢ|` is equivalent to choosing
    /// the axis whose direction makes the smaller angle with `d`, because the two iso
    /// axes are not orthogonal — the projection magnitude, not the perpendicular
    /// distance, is the correct "nearest axis" measure here (it maximizes the retained
    /// reach along the chosen axis). A tie (`|d·a₁| == |d·a₂|`, e.g. the exact bisector)
    /// resolves to the FIRST axis, a stable arbitrary choice mirroring the H tie-break.
    ///
    /// - Parameters:
    ///   - point: the raw (already-in-world) candidate point.
    ///   - reference: the point iso-ortho is measured from (the tool's last placed
    ///     point / relative-zero). With no reference the caller skips the constraint.
    ///   - plane: the active isometric drafting plane whose two axes are the lock
    ///     targets.
    /// - Returns: the axis-locked point (or `point` unchanged when inputs are invalid).
    public static func constrain(_ point: Vector,
                                 relativeTo reference: Vector,
                                 isoPlane plane: IsoPlane) -> Vector {
        guard point.valid, reference.valid else { return point }
        let d = point - reference
        let (a1, a2) = plane.axisDirections      // unit iso-axis directions
        let p1 = d.dot(a1)                        // signed projection onto axis 1
        let p2 = d.dot(a2)                        // signed projection onto axis 2
        // Lock onto whichever axis the candidate reaches FURTHER along (closer axis).
        // Tie → axis 1 (stable, mirrors the rectangular horizontal tie-break).
        if abs(p1) >= abs(p2) {
            return reference + a1 * p1
        } else {
            return reference + a2 * p2
        }
    }
}
