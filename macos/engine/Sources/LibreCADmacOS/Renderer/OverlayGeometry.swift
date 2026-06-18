//
//  OverlayGeometry.swift
//  LibreCADmacOS
//
//  GPU-free builders for the interaction OVERLAYS (rendering-performance.md §5:
//  overlays repaint WITHOUT rebuilding the model buffers):
//    - an adaptive world grid (line list),
//    - the snap marker (square = endpoint, circle = center, X = intersection,
//      diamond = middle, triangle = onEntity, + = grid — per Snapping notes),
//    - the selection highlight (the selected entities' resolved polylines in a
//      highlight color, drawn as a line list).
//
//  Output is `FlatVertex` arrays (render-space f32 offsets + color), consumed by
//  the flat pipeline in Shaders.swift. Markers are sized in WORLD units derived
//  from a pixel size (so they stay a constant on-screen size across zoom). No
//  Metal/AppKit dependency → unit-testable.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import simd
import CADEngine

/// A flat-shaded vertex (matches `struct FlatVertex` in Shaders.swift).
struct FlatVertex: Equatable {
    var position: SIMD2<Float>   // render-space (f32 offset from renderOrigin)
    var color: SIMD4<Float>
}

/// Overlay colors + sizes. These default to the DARK canvas palette but are
/// `var`s so `CanvasTheme.apply(to:appearance:)` can swap them to the light
/// palette (and back) when the system appearance changes.
///
/// They are `nonisolated(unsafe)` rather than `@MainActor`: the renderer, the
/// overlay builders, and `CanvasTheme.apply` all run on the MAIN ACTOR, so every
/// read and the single writer are already serialized there. Keeping them
/// non-isolated avoids forcing the GPU-free, unit-tested `OverlayGeometry`
/// builders (and their non-`@MainActor` test suites) onto the main actor just to
/// read a color constant. Mutate ONLY via `CanvasTheme.apply` (main actor).
enum OverlayStyle {
    nonisolated(unsafe) static var gridColor      = SIMD4<Float>(1, 1, 1, 0.06)
    nonisolated(unsafe) static var gridAxisColor  = SIMD4<Float>(0.55, 0.55, 0.62, 0.30)
    nonisolated(unsafe) static var selectionColor = SIMD4<Float>(1.0, 0.85, 0.20, 1.0)  // amber
    nonisolated(unsafe) static var snapColor      = SIMD4<Float>(0.30, 0.85, 1.0, 1.0)  // cyan
    nonisolated(unsafe) static var crosshairColor = SIMD4<Float>(1, 1, 1, 0.18)
    /// The in-progress tool rubber-band color (a distinct, brighter green than the
    /// committed geometry so the live preview reads as "not yet placed").
    nonisolated(unsafe) static var toolPreviewColor = SIMD4<Float>(0.45, 1.0, 0.55, 0.9)
    /// The dashed REFERENCE-line color (Move's base→cursor displacement, Scale's
    /// center→reference original-size guide): a dimmer, greyer tint near the preview
    /// color so the dashed guide reads as a "where we started from" hint, distinct
    /// from the solid live ghost. Drawn dashed (screen-fixed) by `dashedSegments`.
    nonisolated(unsafe) static var referenceColor = SIMD4<Float>(0.62, 0.78, 0.66, 0.55)

    /// On-screen ON-dash length (points) for the reference guide — mirrors
    /// `RendererGeometry.dashParamsPx`'s ~5pt base ON unit so the overlay dash visually
    /// matches the model linetype dashes.
    static let referenceDashOnPoints: Double = 5
    /// On-screen OFF-gap length (points) — 0.6× the ON dash, the same ratio
    /// `dashParamsPx` uses for `gap`.
    static let referenceDashGapPoints: Double = 3

    /// Snap marker radius in screen points (converted to world by the builder).
    static let snapMarkerPointRadius: Double = 6

    /// When true (light mode), near-white "automatic"/color-7 entity pens are
    /// flipped to near-black by the renderer so the default drawing color stays
    /// legible on a light canvas (the standard AutoCAD/LibreCAD auto-invert). The
    /// renderer reads this when packing line instances; it does not affect overlays.
    nonisolated(unsafe) static var invertNearWhiteEntities = false
}

enum OverlayGeometry {

    // MARK: - Adaptive grid

    /// Builds a world-aligned grid (line list) covering the visible rect, with an
    /// adaptive spacing chosen so cells are a comfortable on-screen size, plus a
    /// brighter pair of axis lines through the world origin.
    ///
    /// Spacing is a 1/2/5 × 10ⁿ "nice number" whose on-screen size is closest to
    /// `targetCellPx`. Returns vertices for a `.line` primitive (pairs).
    ///
    /// - Parameters:
    ///   - viewport: current transform (gives the visible rect + scale).
    ///   - renderOrigin: f64 floating origin to offset against (ADR-003).
    ///   - targetCellPx: desired grid cell size in points (default 64).
    ///   - preferredSpacing: when non-`nil` and positive/finite, the EXACT world step
    ///     to use (the Inspector's "Grid spacing"); the adaptive 1/2/5 × 10ⁿ pick is
    ///     bypassed. `nil` (or a non-positive value) falls back to the adaptive
    ///     spacing. The returned spacing is still fed to snapping, so grid-snap tracks
    ///     whichever step is drawn.
    ///   - ucs: the active user coordinate system. The grid is anchored at
    ///     `ucs.origin` and its lines run along the UCS axes (rotated by `ucs.angle`),
    ///     so the drawn grid matches UCS-relative grid snap (UCS-W4). The default
    ///     `.world` keeps the world-aligned grid; when `ucs.isWorld` this takes the
    ///     EXACT same code path as before this parameter existed, so the world-frame
    ///     output is byte-identical (regression-lock — the grid is invisible until a
    ///     UCS is actually set).
    ///   - isoPlane: the active ISOMETRIC drafting plane (Wave 2c). When `nil` (the
    ///     default) the RECTANGULAR grid is generated exactly as before this parameter
    ///     existed (byte-identical — the iso branch is gated off). When a plane is set
    ///     the grid is instead the 30°/90°/150° iso LATTICE for that plane (drawn so it
    ///     matches `Snapping.snappedToIsoGrid`). The iso grid is anchored at
    ///     `ucs.origin` (the world origin for the default `.world`).
    /// - Returns: (vertices, spacing) — spacing is the world step used (also the
    ///   snap grid spacing the caller should pass to `Snapping.snap`).
    static func grid(
        viewport: Viewport,
        renderOrigin: Vector,
        targetCellPx: Double = 64,
        preferredSpacing: Double? = nil,
        ucs: UCS = .world,
        isoPlane: IsoPlane? = nil
    ) -> (vertices: [FlatVertex], spacing: Double) {
        // ISO grid (Wave 2c): the 30°/90°/150° iso lattice for the active plane. Split
        // out so the rectangular path below stays byte-identical when iso is off
        // (regression-lock). Only taken when an iso plane is active.
        if let plane = isoPlane {
            return isoGrid(viewport: viewport, renderOrigin: renderOrigin,
                           targetCellPx: targetCellPx, preferredSpacing: preferredSpacing,
                           plane: plane, origin: ucs.origin)
        }
        // UCS-aligned grid: anchor at the UCS origin and run the lines along the UCS
        // axes. Split out so the world-frame path below stays byte-identical to the
        // pre-UCS code (regression-lock). Only taken when a non-world UCS is active.
        if !ucs.isWorld {
            return ucsGrid(viewport: viewport, renderOrigin: renderOrigin,
                           targetCellPx: targetCellPx, preferredSpacing: preferredSpacing,
                           ucs: ucs)
        }

        let rect = viewport.visibleWorldRect
        guard !rect.isEmpty, viewport.scale > 0 else { return ([], 1) }

        // Use the Inspector's preferred spacing when it is a usable positive value;
        // otherwise choose a "nice" world spacing whose screen size ≈ targetCellPx.
        let spacing: Double
        if let pref = preferredSpacing, pref > 0, pref.isFinite {
            spacing = pref
        } else {
            let rawWorld = targetCellPx / viewport.scale
            spacing = niceStep(rawWorld)
        }
        guard spacing > 0, spacing.isFinite else { return ([], 1) }

        // Avoid pathological line counts at extreme zoom-out: cap total lines.
        let cols = (rect.size.x / spacing)
        let rows = (rect.size.y / spacing)
        guard cols.isFinite, rows.isFinite, cols + rows < 4000 else {
            // Too dense to be useful; draw just the axes.
            return (axisLines(rect: rect, renderOrigin: renderOrigin), spacing)
        }

        var verts: [FlatVertex] = []
        // Vertical lines at x = k·spacing.
        let x0 = (rect.min.x / spacing).rounded(.down) * spacing
        var x = x0
        while x <= rect.max.x {
            let isAxis = abs(x) < spacing * 1e-6
            let c = isAxis ? OverlayStyle.gridAxisColor : OverlayStyle.gridColor
            verts.append(FlatVertex(position: off(Vector(x, rect.min.y), renderOrigin), color: c))
            verts.append(FlatVertex(position: off(Vector(x, rect.max.y), renderOrigin), color: c))
            x += spacing
        }
        // Horizontal lines at y = k·spacing.
        let y0 = (rect.min.y / spacing).rounded(.down) * spacing
        var y = y0
        while y <= rect.max.y {
            let isAxis = abs(y) < spacing * 1e-6
            let c = isAxis ? OverlayStyle.gridAxisColor : OverlayStyle.gridColor
            verts.append(FlatVertex(position: off(Vector(rect.min.x, y), renderOrigin), color: c))
            verts.append(FlatVertex(position: off(Vector(rect.max.x, y), renderOrigin), color: c))
            y += spacing
        }
        return (verts, spacing)
    }

    /// The UCS-aligned grid (UCS-W4): the same adaptive/preferred spacing as the
    /// world grid, but the lines run along the UCS axes and are anchored at the UCS
    /// origin so the drawn grid matches UCS-relative grid snap.
    ///
    /// Construction: the view's visible WORLD rect is mapped into UCS-local space
    /// (its four corners → `ucs.toUCS`, then their UCS-local AABB), grid lines are
    /// generated over that local rect exactly as the world grid does over the world
    /// rect, and every endpoint is mapped back to world (`ucs.toWorld`) before being
    /// offset against `renderOrigin`. With a world UCS this would reduce to the world
    /// grid, but the caller only reaches it for a non-world UCS (see `grid(...)`),
    /// keeping the world path byte-identical.
    private static func ucsGrid(
        viewport: Viewport,
        renderOrigin: Vector,
        targetCellPx: Double,
        preferredSpacing: Double?,
        ucs: UCS
    ) -> (vertices: [FlatVertex], spacing: Double) {
        let worldRect = viewport.visibleWorldRect
        guard !worldRect.isEmpty, viewport.scale > 0 else { return ([], 1) }

        // The visible region expressed in UCS-local coordinates: map the four world
        // corners through `toUCS` and take their axis-aligned bounds in that frame.
        // (A rotated rect's UCS-local bounds is the smallest UCS-aligned box that
        // still covers the whole view, so no visible cell is missed.)
        let corners = [
            Vector(worldRect.min.x, worldRect.min.y),
            Vector(worldRect.max.x, worldRect.min.y),
            Vector(worldRect.max.x, worldRect.max.y),
            Vector(worldRect.min.x, worldRect.max.y),
        ].map { ucs.toUCS($0) }
        var minX = corners[0].x, maxX = corners[0].x
        var minY = corners[0].y, maxY = corners[0].y
        for c in corners {
            minX = Swift.min(minX, c.x); maxX = Swift.max(maxX, c.x)
            minY = Swift.min(minY, c.y); maxY = Swift.max(maxY, c.y)
        }
        let rect = AABB(min: Vector(minX, minY), max: Vector(maxX, maxY))
        guard !rect.isEmpty else { return ([], 1) }

        // Spacing uses the SAME rule as the world grid (the adaptive step depends only
        // on the scale, which the UCS rotation preserves; a preferred spacing wins).
        let spacing: Double
        if let pref = preferredSpacing, pref > 0, pref.isFinite {
            spacing = pref
        } else {
            let rawWorld = targetCellPx / viewport.scale
            spacing = niceStep(rawWorld)
        }
        guard spacing > 0, spacing.isFinite else { return ([], 1) }

        // Cap pathological line counts at extreme zoom-out, mirroring the world grid.
        let cols = (rect.size.x / spacing)
        let rows = (rect.size.y / spacing)
        guard cols.isFinite, rows.isFinite, cols + rows < 4000 else {
            return (ucsAxisLines(rect: rect, renderOrigin: renderOrigin, ucs: ucs), spacing)
        }

        var verts: [FlatVertex] = []
        // UCS-vertical lines at u = k·spacing (run along the UCS +Y axis in world).
        let x0 = (rect.min.x / spacing).rounded(.down) * spacing
        var x = x0
        while x <= rect.max.x {
            let isAxis = abs(x) < spacing * 1e-6
            let c = isAxis ? OverlayStyle.gridAxisColor : OverlayStyle.gridColor
            verts.append(FlatVertex(position: off(ucs.toWorld(Vector(x, rect.min.y)), renderOrigin), color: c))
            verts.append(FlatVertex(position: off(ucs.toWorld(Vector(x, rect.max.y)), renderOrigin), color: c))
            x += spacing
        }
        // UCS-horizontal lines at v = k·spacing (run along the UCS +X axis in world).
        let y0 = (rect.min.y / spacing).rounded(.down) * spacing
        var y = y0
        while y <= rect.max.y {
            let isAxis = abs(y) < spacing * 1e-6
            let c = isAxis ? OverlayStyle.gridAxisColor : OverlayStyle.gridColor
            verts.append(FlatVertex(position: off(ucs.toWorld(Vector(rect.min.x, y)), renderOrigin), color: c))
            verts.append(FlatVertex(position: off(ucs.toWorld(Vector(rect.max.x, y)), renderOrigin), color: c))
            y += spacing
        }
        return (verts, spacing)
    }

    /// The ISOMETRIC grid (Wave 2c): the 30°/90°/150° lattice for `plane`, anchored at
    /// `origin`, drawn so it coincides with `Snapping.snappedToIsoGrid`. The lattice is
    /// spanned by the plane's two iso basis vectors `(e1, e2)` at `spacing`; the grid is
    /// two families of parallel lines — one running ALONG `e1` (stepped by `e2`), one
    /// ALONG `e2` (stepped by `e1`).
    ///
    /// Construction: the visible world rect's four corners are expressed in the
    /// non-orthogonal `(e1, e2)` lattice basis (a 2×2 solve, exactly like the snap), and
    /// the integer index ranges that cover the rect are taken from their bounds (padded
    /// by one so partial edge cells are drawn). Each `i = const` line is drawn ALONG
    /// `e2` across the j-range, and each `j = const` line ALONG `e1` across the i-range,
    /// then offset against `renderOrigin`. The total line count is capped (mirroring the
    /// rectangular grid) so extreme zoom-out degrades gracefully.
    private static func isoGrid(
        viewport: Viewport,
        renderOrigin: Vector,
        targetCellPx: Double,
        preferredSpacing: Double?,
        plane: IsoPlane,
        origin: Vector
    ) -> (vertices: [FlatVertex], spacing: Double) {
        let rect = viewport.visibleWorldRect
        guard !rect.isEmpty, viewport.scale > 0 else { return ([], 1) }

        // Spacing uses the SAME rule as the world grid (a preferred value wins, else the
        // adaptive 1/2/5 × 10ⁿ pick by screen size). The iso spacing is the lattice edge
        // length along the iso axes.
        let spacing: Double
        if let pref = preferredSpacing, pref > 0, pref.isFinite {
            spacing = pref
        } else {
            spacing = niceStep(targetCellPx / viewport.scale)
        }
        guard spacing > 0, spacing.isFinite else { return ([], 1) }

        let (e1, e2) = plane.gridBasis(spacing: spacing)
        let det = e1.x * e2.y - e1.y * e2.x
        guard abs(det) > 1e-12 else { return ([], spacing) }

        // The visible rect's corners expressed in the (e1, e2) lattice basis.
        let corners = [
            Vector(rect.min.x, rect.min.y),
            Vector(rect.max.x, rect.min.y),
            Vector(rect.max.x, rect.max.y),
            Vector(rect.min.x, rect.max.y),
        ]
        var iLo = Double.greatestFiniteMagnitude, iHi = -Double.greatestFiniteMagnitude
        var jLo = Double.greatestFiniteMagnitude, jHi = -Double.greatestFiniteMagnitude
        for c in corners {
            let p = c - origin
            let i = (p.x * e2.y - p.y * e2.x) / det
            let j = (e1.x * p.y - e1.y * p.x) / det
            iLo = Swift.min(iLo, i); iHi = Swift.max(iHi, i)
            jLo = Swift.min(jLo, j); jHi = Swift.max(jHi, j)
        }
        // Integer index ranges covering the rect, padded by one for partial edge cells.
        let i0 = Int(iLo.rounded(.down)) - 1, i1 = Int(iHi.rounded(.up)) + 1
        let j0 = Int(jLo.rounded(.down)) - 1, j1 = Int(jHi.rounded(.up)) + 1

        // Cap pathological line counts at extreme zoom-out (mirrors the rect grid).
        let iCount = i1 - i0, jCount = j1 - j0
        guard iCount > 0, jCount > 0, iCount + jCount < 4000 else {
            return (isoAxisLines(plane: plane, spacing: spacing, origin: origin,
                                 iRange: (i0, i1), jRange: (j0, j1), renderOrigin: renderOrigin),
                    spacing)
        }

        @inline(__always)
        func node(_ i: Int, _ j: Int) -> Vector {
            origin + e1 * Double(i) + e2 * Double(j)
        }

        var verts: [FlatVertex] = []
        let axisC = OverlayStyle.gridAxisColor
        let lineC = OverlayStyle.gridColor
        // Lines of constant i (running ALONG e2 across the j-range).
        for i in i0...i1 {
            let c = i == 0 ? axisC : lineC
            verts.append(FlatVertex(position: off(node(i, j0), renderOrigin), color: c))
            verts.append(FlatVertex(position: off(node(i, j1), renderOrigin), color: c))
        }
        // Lines of constant j (running ALONG e1 across the i-range).
        for j in j0...j1 {
            let c = j == 0 ? axisC : lineC
            verts.append(FlatVertex(position: off(node(i0, j), renderOrigin), color: c))
            verts.append(FlatVertex(position: off(node(i1, j), renderOrigin), color: c))
        }
        return (verts, spacing)
    }

    /// The two iso axis lines (the `i == 0` and `j == 0` lattice lines through
    /// `origin`) spanning the covered index range. The degenerate-density fallback for
    /// `isoGrid`, mirroring the rectangular grid's `axisLines`.
    private static func isoAxisLines(
        plane: IsoPlane, spacing: Double, origin: Vector,
        iRange: (Int, Int), jRange: (Int, Int), renderOrigin: Vector
    ) -> [FlatVertex] {
        let (e1, e2) = plane.gridBasis(spacing: spacing)
        @inline(__always)
        func node(_ i: Int, _ j: Int) -> Vector { origin + e1 * Double(i) + e2 * Double(j) }
        var v: [FlatVertex] = []
        let c = OverlayStyle.gridAxisColor
        // i == 0 line (along e2 across the j-range).
        v.append(FlatVertex(position: off(node(0, jRange.0), renderOrigin), color: c))
        v.append(FlatVertex(position: off(node(0, jRange.1), renderOrigin), color: c))
        // j == 0 line (along e1 across the i-range).
        v.append(FlatVertex(position: off(node(iRange.0, 0), renderOrigin), color: c))
        v.append(FlatVertex(position: off(node(iRange.1, 0), renderOrigin), color: c))
        return v
    }

    /// The UCS axis cross (through the UCS origin) spanning the UCS-local `rect`,
    /// mapped to world. The degenerate-density fallback for `ucsGrid`, mirroring the
    /// world grid's `axisLines`.
    private static func ucsAxisLines(rect: AABB, renderOrigin: Vector, ucs: UCS) -> [FlatVertex] {
        var v: [FlatVertex] = []
        let c = OverlayStyle.gridAxisColor
        if rect.min.x <= 0 && 0 <= rect.max.x {
            v.append(FlatVertex(position: off(ucs.toWorld(Vector(0, rect.min.y)), renderOrigin), color: c))
            v.append(FlatVertex(position: off(ucs.toWorld(Vector(0, rect.max.y)), renderOrigin), color: c))
        }
        if rect.min.y <= 0 && 0 <= rect.max.y {
            v.append(FlatVertex(position: off(ucs.toWorld(Vector(rect.min.x, 0)), renderOrigin), color: c))
            v.append(FlatVertex(position: off(ucs.toWorld(Vector(rect.max.x, 0)), renderOrigin), color: c))
        }
        return v
    }

    /// Just the two axis lines (origin cross) spanning the visible rect.
    private static func axisLines(rect: AABB, renderOrigin: Vector) -> [FlatVertex] {
        var v: [FlatVertex] = []
        let c = OverlayStyle.gridAxisColor
        if rect.min.x <= 0 && 0 <= rect.max.x {
            v.append(FlatVertex(position: off(Vector(0, rect.min.y), renderOrigin), color: c))
            v.append(FlatVertex(position: off(Vector(0, rect.max.y), renderOrigin), color: c))
        }
        if rect.min.y <= 0 && 0 <= rect.max.y {
            v.append(FlatVertex(position: off(Vector(rect.min.x, 0), renderOrigin), color: c))
            v.append(FlatVertex(position: off(Vector(rect.max.x, 0), renderOrigin), color: c))
        }
        return v
    }

    /// Rounds `x` to the nearest 1/2/5 × 10ⁿ "nice" number ≥ a small floor.
    static func niceStep(_ x: Double) -> Double {
        guard x > 0, x.isFinite else { return 1 }
        let exp = (log10(x)).rounded(.down)
        let base = pow(10.0, exp)
        let f = x / base               // in [1, 10)
        let nice: Double = f < 1.5 ? 1 : (f < 3.5 ? 2 : (f < 7.5 ? 5 : 10))
        return nice * base
    }

    // MARK: - Snap marker

    /// Builds the snap marker for a `SnapResult` as a line list, sized in world
    /// units from the screen-point radius so it's a constant on-screen size.
    /// Glyph by kind: square=endpoint, circle=center, diamond=middle,
    /// triangle=onEntity, X=intersection, +=grid/free, hourglass=nearest,
    /// right-angle bracket=perpendicular, ring=tangent, parallel slashes=parallel.
    static func snapMarker(
        for snap: SnapResult,
        viewport: Viewport,
        renderOrigin: Vector
    ) -> [FlatVertex] {
        let r = OverlayStyle.snapMarkerPointRadius * viewport.worldPerPixel
        let p = snap.point
        let c = OverlayStyle.snapColor
        var v: [FlatVertex] = []

        func seg(_ a: Vector, _ b: Vector) {
            v.append(FlatVertex(position: off(a, renderOrigin), color: c))
            v.append(FlatVertex(position: off(b, renderOrigin), color: c))
        }
        func ring(_ corners: [Vector]) {
            for i in 0..<corners.count {
                seg(corners[i], corners[(i + 1) % corners.count])
            }
        }

        switch snap.kind {
        case .endpoint:
            ring([Vector(p.x - r, p.y - r), Vector(p.x + r, p.y - r),
                  Vector(p.x + r, p.y + r), Vector(p.x - r, p.y + r)])
        case .center:
            // Circle approximated by a 16-gon.
            let n = 16
            var corners: [Vector] = []
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * Double.pi
                corners.append(Vector(p.x + r * cos(a), p.y + r * sin(a)))
            }
            ring(corners)
        case .middle:
            ring([Vector(p.x, p.y + r), Vector(p.x + r, p.y),
                  Vector(p.x, p.y - r), Vector(p.x - r, p.y)])
        case .onEntity:
            ring([Vector(p.x, p.y + r), Vector(p.x + r, p.y - r), Vector(p.x - r, p.y - r)])
        case .intersection:
            seg(Vector(p.x - r, p.y - r), Vector(p.x + r, p.y + r))
            seg(Vector(p.x - r, p.y + r), Vector(p.x + r, p.y - r))
        case .grid, .free:
            seg(Vector(p.x - r, p.y), Vector(p.x + r, p.y))
            seg(Vector(p.x, p.y - r), Vector(p.x, p.y + r))
        case .nearest:
            // Hourglass (two opposed triangles meeting at the point), the usual
            // CAD "nearest" glyph.
            seg(Vector(p.x - r, p.y - r), Vector(p.x + r, p.y - r))
            seg(Vector(p.x - r, p.y + r), Vector(p.x + r, p.y + r))
            seg(Vector(p.x - r, p.y - r), Vector(p.x + r, p.y + r))
            seg(Vector(p.x + r, p.y - r), Vector(p.x - r, p.y + r))
        case .perpendicular:
            // Right-angle bracket (⌐-like): a vertical and a horizontal arm with a
            // base, the conventional perpendicular glyph.
            seg(Vector(p.x - r, p.y + r), Vector(p.x - r, p.y - r))
            seg(Vector(p.x - r, p.y - r), Vector(p.x + r, p.y - r))
            seg(Vector(p.x - r, p.y), Vector(p.x, p.y))
            seg(Vector(p.x, p.y), Vector(p.x, p.y - r))
        case .tangent:
            // A ring with a baseline beneath it (tangent line touching a circle).
            let n = 12
            var corners: [Vector] = []
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * Double.pi
                corners.append(Vector(p.x + r * 0.8 * cos(a), p.y + r * 0.4 + r * 0.8 * sin(a)))
            }
            ring(corners)
            seg(Vector(p.x - r, p.y - r), Vector(p.x + r, p.y - r))
        case .parallel:
            // Two parallel slashes.
            seg(Vector(p.x - r, p.y - r), Vector(p.x, p.y + r))
            seg(Vector(p.x, p.y - r), Vector(p.x + r, p.y + r))
        }
        return v
    }

    // MARK: - Selection highlight

    /// Builds a line list highlighting the selected entities' resolved polylines
    /// in the selection color (drawn over the model). Curves are tessellated by
    /// the same `resolve()` the model uses.
    // TODO(backlog): cache the selected entities' resolved polylines and rebuild
    // only when the selection or model changes, instead of re-`resolve()`ing every
    // selected entity each frame (render-gate #7 — per-frame resolve caching).
    @MainActor
    static func selectionHighlight(
        selection: Selection,
        drawing: CADDrawing,
        renderOrigin: Vector,
        ctx: ResolveContext? = nil
    ) -> [FlatVertex] {
        guard !selection.isEmpty else { return [] }
        let context = ctx ?? drawing.makeResolveContext()
        let c = OverlayStyle.selectionColor
        var v: [FlatVertex] = []
        for id in selection.ids {
            guard let e = drawing.entity(id) else { continue }
            let geo = e.resolve(context)
            for poly in geo.polylines {
                let pts = poly.points
                guard pts.count >= 2 else {
                    if let only = pts.first {
                        // Single point → small marker so it's visible.
                        // TODO(backlog): scale `r` by worldPerPixel so the single-
                        // point marker stays a constant pixel size across zoom
                        // (render-gate backlog — pixel-scaled point marker).
                        let r = 3 * 1.0
                        v.append(FlatVertex(position: off(Vector(only.x - r, only.y), renderOrigin), color: c))
                        v.append(FlatVertex(position: off(Vector(only.x + r, only.y), renderOrigin), color: c))
                    }
                    continue
                }
                for i in 0..<(pts.count - 1) {
                    v.append(FlatVertex(position: off(pts[i], renderOrigin), color: c))
                    v.append(FlatVertex(position: off(pts[i + 1], renderOrigin), color: c))
                }
                if poly.closed, pts.count >= 3, let first = pts.first, let last = pts.last {
                    v.append(FlatVertex(position: off(last, renderOrigin), color: c))
                    v.append(FlatVertex(position: off(first, renderOrigin), color: c))
                }
            }
        }
        return v
    }

    // MARK: - Tool preview (rubber-band)

    /// Builds a line list for an active tool's `preview` polylines in the distinct
    /// preview color, drawn over the model each frame. The polylines are the
    /// world-coord rubber-band the tool emits; this just flattens them to segments
    /// (honoring `closed`). Pure / GPU-free → unit-testable.
    static func toolPreview(
        _ polylines: [ResolvedPolyline],
        renderOrigin: Vector
    ) -> [FlatVertex] {
        let c = OverlayStyle.toolPreviewColor
        var v: [FlatVertex] = []
        for poly in polylines {
            let pts = poly.points
            guard pts.count >= 2 else { continue }
            for i in 0..<(pts.count - 1) {
                v.append(FlatVertex(position: off(pts[i], renderOrigin), color: c))
                v.append(FlatVertex(position: off(pts[i + 1], renderOrigin), color: c))
            }
            if poly.closed, pts.count >= 3, let first = pts.first, let last = pts.last {
                v.append(FlatVertex(position: off(last, renderOrigin), color: c))
                v.append(FlatVertex(position: off(first, renderOrigin), color: c))
            }
        }
        return v
    }

    // MARK: - Dashed reference segments

    /// Builds a DASHED line list for the active tool's `referenceSegments` — the
    /// "where we started from" guides (Move's base→cursor displacement, Scale's
    /// center→reference original-size line). Each world segment is chopped into
    /// SCREEN-FIXED on/off dash runs using `viewport.worldPerPixel`, so the dash
    /// rhythm stays a constant on-screen size across zoom (matching the model
    /// linetype dashes from `RendererGeometry.dashParamsPx`, not a world-fixed step).
    ///
    /// The returned vertices are a `.line` primitive (pairs): one pair per ON dash
    /// run, all in the dimmer reference color so the guide reads as a hint distinct
    /// from the solid preview ghost. Pure / GPU-free → unit-testable. Empty input
    /// (no active drag) → no vertices.
    ///
    /// - Parameters:
    ///   - segs: world-coord `(from, to)` segments from `Tool.referenceSegments`.
    ///   - color: the dash color (defaults to `OverlayStyle.referenceColor`).
    ///   - viewport: gives `worldPerPixel` for the screen-fixed dash period.
    ///   - renderOrigin: f64 floating origin to offset against (ADR-003).
    static func dashedSegments(
        _ segs: [(Vector, Vector)],
        color: SIMD4<Float> = OverlayStyle.referenceColor,
        viewport: Viewport,
        renderOrigin: Vector
    ) -> [FlatVertex] {
        guard !segs.isEmpty else { return [] }
        let wpp = viewport.worldPerPixel
        guard wpp > 0, wpp.isFinite else { return [] }

        // Dash geometry in WORLD units (screen points × worldPerPixel) so the dash
        // size is fixed on screen across zoom.
        let onW = OverlayStyle.referenceDashOnPoints * wpp
        let gapW = OverlayStyle.referenceDashGapPoints * wpp
        let periodW = onW + gapW
        guard onW > 0, periodW > 0, periodW.isFinite else { return [] }

        var v: [FlatVertex] = []
        for (a, b) in segs {
            guard a.valid, b.valid else { continue }
            let d = b - a
            let len = d.magnitude
            // Degenerate (coincident) segment: nothing to dash.
            guard len > 1e-12 else { continue }
            let dir = Vector(d.x / len, d.y / len)

            // Walk the segment one period at a time, emitting the ON run [t, t+on]
            // (clamped to the segment end). Cap the iteration count to stay bounded
            // at extreme zoom-out (a very long segment vs a tiny period).
            let maxDashes = 4096
            var t = 0.0
            var count = 0
            while t < len, count < maxDashes {
                let onEnd = Swift.min(t + onW, len)
                let p0 = Vector(a.x + dir.x * t, a.y + dir.y * t)
                let p1 = Vector(a.x + dir.x * onEnd, a.y + dir.y * onEnd)
                v.append(FlatVertex(position: off(p0, renderOrigin), color: color))
                v.append(FlatVertex(position: off(p1, renderOrigin), color: color))
                t += periodW
                count += 1
            }
        }
        return v
    }

    // MARK: - Internal

    @inline(__always)
    private static func off(_ world: Vector, _ origin: Vector) -> SIMD2<Float> {
        SIMD2<Float>(Float(world.x - origin.x), Float(world.y - origin.y))
    }
}
