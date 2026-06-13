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
}
