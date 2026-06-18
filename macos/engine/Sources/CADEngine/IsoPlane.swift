//
//  IsoPlane.swift
//  CADEngine
//
//  ISOMETRIC drafting engine (Wave 2c) — the value-type model for AutoCAD-style
//  isometric drafting (the `ISOPLANE` system variable / `SNAPSTYLE == 1`). An
//  isometric drawing projects a 3D box onto 2D so the three visible faces read as
//  the "top", "left", and "right" planes; each face has two drawing axes drawn at
//  the canonical isometric angles 30° / 90° / 150° (and their opposites).
//
//  This file is the PURE MATH foundation only (ADR-001, value types, no GPU / no
//  app dependency): the three planes, their two per-plane axis directions, the iso
//  GRID BASIS (the two lattice vectors), and the snap-to-nearest-iso-node solve.
//  The snap DISPATCH lives in `Snapping.swift` (an `isoPlane`-parameterized entry
//  whose `nil` path is byte-identical to the world-frame grid snap), the iso grid
//  GEOMETRY in `OverlayGeometry.swift`, and the DXF `$SNAPSTYLE` / app `$LC_ISOPLANE`
//  persistence in `CADDrawing` / `DXFWriter` / the C bridge.
//
//  NON-GOALS here (deferred — see the Wave-2c brief): the CanvasModel iso-state
//  plumbing + F5 plane-cycle + ISO status chip + View-menu (the WIRE-WAVE); the
//  iso-ortho axis-lock + iso crosshair (Wave 3); the iso-circle ellipse mode
//  (Wave 4); per-VPORT plane, meta-grid tiling, DIMISO, and the UCS↔iso coupling.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS2::CrosshairType / isometric grid).
//

import Foundation

// MARK: - Isometric plane

/// The active isometric drafting PLANE — the value-type port of AutoCAD's
/// `ISOPLANE` (Top / Left / Right), the face the cursor/grid/snap currently work
/// on. Each plane is drawn with TWO of the three isometric axis directions:
///
/// ```
///        90°
///         |          .top  : 30° / 150°  (the "floor" — both diagonals)
///  150°   |   30°    .left : 90° / 150°  (the left wall — vertical + left diag)
///     \   |   /      .right: 30° / 90°   (the right wall — vertical + right diag)
///      \  |  /
///       \ | /
///  ------- + -------  (origin)
/// ```
///
/// Pure value type (Codable so it round-trips through the document payload as the
/// `$LC_ISOPLANE` app var). The DXF file format has no per-plane var — only the
/// boolean `$SNAPSTYLE` (rectangular vs isometric) — so the plane resets to `.top`
/// on a pure-DXF reopen (it survives only the Codable payload). The raw values are
/// stable (they key the app var) and match LibreCAD's `RS2::IsoGridViewType`
/// ordering (Top=0, Left=1, Right=2).
public enum IsoPlane: Int, Sendable, Hashable, Codable, CaseIterable {
    /// The TOP face — the two "floor" diagonals at 30° and 150°.
    case top = 0
    /// The LEFT face — the vertical (90°) and the left diagonal (150°).
    case left = 1
    /// The RIGHT face — the right diagonal (30°) and the vertical (90°).
    case right = 2

    /// The canonical isometric axis angle (30° in radians) — the slope of the iso
    /// diagonals. AutoCAD/LibreCAD use a fixed 30° isometric (`atan(0.5)` ≈ 26.57°
    /// is the *true* dimetric; the CAD convention is the simpler exact 30°).
    public static let isoAngle: Double = .pi / 6   // 30°

    /// The two DRAWING-AXIS directions (unit vectors) for this plane, ordered as
    /// (first axis, second axis). These are the directions an iso-ortho lock would
    /// snap a segment to, and the directions the grid lines run along (Wave-3 will
    /// consume the first; the grid + lattice consume both).
    ///
    /// - `.top`  → (30°, 150°)
    /// - `.left` → (90°, 150°)
    /// - `.right`→ (30°, 90°)
    public var axisDirections: (Vector, Vector) {
        let a = Self.isoAngle                 // 30°
        let vertical = Double.pi / 2          // 90°
        let leftDiag = Double.pi - a          // 150°
        switch self {
        case .top:   return (Vector(angle: a),        Vector(angle: leftDiag))
        case .left:  return (Vector(angle: vertical), Vector(angle: leftDiag))
        case .right: return (Vector(angle: a),        Vector(angle: vertical))
        }
    }

    /// The two iso GRID BASIS vectors for this plane at `spacing` (the lattice edge
    /// vectors). The grid nodes for the plane are `origin + i·e1 + j·e2` over the
    /// integers i, j; the grid LINES run along `e1` (stepped by `e2`) and along `e2`
    /// (stepped by `e1`). Each basis vector is the corresponding `axisDirections`
    /// unit vector scaled to `spacing`, so a unit `spacing` yields unit-length edges.
    ///
    /// The two basis vectors are linearly independent for every plane (the iso axes
    /// are never parallel), so the lattice is non-degenerate and `snappedToIsoGrid`'s
    /// 2×2 solve is always well-conditioned.
    public func gridBasis(spacing: Double) -> (Vector, Vector) {
        let (d1, d2) = axisDirections
        return (d1 * spacing, d2 * spacing)
    }
}
