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

/// Overlay colors + sizes (tuned for the dark canvas background).
enum OverlayStyle {
    static let gridColor      = SIMD4<Float>(1, 1, 1, 0.06)
    static let gridAxisColor  = SIMD4<Float>(0.55, 0.55, 0.62, 0.30)
    static let selectionColor = SIMD4<Float>(1.0, 0.85, 0.20, 1.0)   // amber
    static let snapColor      = SIMD4<Float>(0.30, 0.85, 1.0, 1.0)   // cyan
    static let crosshairColor = SIMD4<Float>(1, 1, 1, 0.18)

    /// Snap marker radius in screen points (converted to world by the builder).
    static let snapMarkerPointRadius: Double = 6
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
    /// - Returns: (vertices, spacing) — spacing is the world step used (also the
    ///   snap grid spacing the caller should pass to `Snapping.snap`).
    static func grid(
        viewport: Viewport,
        renderOrigin: Vector,
        targetCellPx: Double = 64
    ) -> (vertices: [FlatVertex], spacing: Double) {
        let rect = viewport.visibleWorldRect
        guard !rect.isEmpty, viewport.scale > 0 else { return ([], 1) }

        // Choose a "nice" world spacing whose screen size ≈ targetCellPx.
        let rawWorld = targetCellPx / viewport.scale
        let spacing = niceStep(rawWorld)
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
    /// triangle=onEntity, X=intersection, +=grid/free.
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

    // MARK: - Internal

    @inline(__always)
    private static func off(_ world: Vector, _ origin: Vector) -> SIMD2<Float> {
        SIMD2<Float>(Float(world.x - origin.x), Float(world.y - origin.y))
    }
}
