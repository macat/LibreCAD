//
//  RendererGeometry.swift
//  LibreCADmacOS
//
//  The GPU-free, unit-testable core of the instanced line renderer: turn the
//  engine's `ResolvedPolyline`s into a flat array of per-segment INSTANCE structs
//  (rendering-performance.md §1.1 — one instance per line segment). Each instance
//  carries the segment's two endpoints as `Float` OFFSETS from a per-view f64
//  `renderOrigin` (ADR-003 floating-origin: the buffer ALWAYS stores
//  `f32(worldPoint - renderOrigin)`, never absolute world coords) plus the pen
//  color and a pixel half-width.
//
//  Pan/zoom never touch this buffer — only the `world→clip` matrix uniform
//  changes (Viewport.worldToClip). This array is rebuilt ONLY when the model (or
//  the visible/culled set) changes.
//
//  This file deliberately has NO Metal/AppKit dependency so it can be exercised
//  by `RendererGeometryTests` without a GPU: the vertex-expansion / AA math lives
//  in the shader (Shaders.swift); the per-segment packing lives here.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import simd
import CADEngine

// MARK: - The per-segment instance (matches `LineInstance` in the Metal source)

/// One line segment instanced into the GPU pipeline. The vertex shader expands
/// this into a screen-space-oriented quad (constant pixel width); the fragment
/// shader runs analytic edge AA. Layout MUST match `struct LineInstance` in
/// `Shaders.swift` (interleaved, packed the same way).
///
/// Endpoints are `Float` offsets from the renderer's f64 `renderOrigin`
/// (ADR-003). `halfWidthPx` is the line half-width in *device pixels* (so 1px
/// logical lines stay crisp on Retina); the shader expands perpendicular in
/// screen space using it.
struct LineInstance: Equatable {
    /// Segment start, `f32(worldStart - renderOrigin)`.
    var p0: SIMD2<Float>
    /// Segment end, `f32(worldEnd - renderOrigin)`.
    var p1: SIMD2<Float>
    /// RGBA pen color (linear-ish; the drawable does sRGB encode on write).
    var color: SIMD4<Float>
    /// Half-width in device pixels.
    var halfWidthPx: Float
}

// MARK: - Geometry builder (GPU-free, testable)

/// Builds the renderer's CPU-side geometry from resolved polylines. Pure value
/// math; no device, no buffers — the renderer takes the returned arrays and
/// blits them into persistent `MTLBuffer`s.
enum RendererGeometry {

    /// The default line half-width in device pixels. CAD lines are typically
    /// hairline; 0.75 px half-width ≈ 1.5 px stroke, which with analytic AA reads
    /// as a crisp ~1px line. (Pen line-width → pixels is a Phase-1 upgrade; for
    /// the foundation every stroke uses this constant — flagged in the brief.)
    static let defaultHalfWidthPx: Float = 0.75

    /// Expands one resolved polyline into per-segment `LineInstance`s.
    ///
    /// - A polyline of N points yields N−1 segment instances (open) or N segment
    ///   instances (closed — the closing edge `last→first` is appended).
    /// - A degenerate 1-point polyline (e.g. a resolved `.point`) yields a single
    ///   ZERO-LENGTH instance (`p0 == p1`); the shader still draws it as a small
    ///   round dot via cap rounding, so points are visible. (Callers that don't
    ///   want point markers can filter `kind == .point` upstream.)
    /// - Endpoints are stored as `f32(world - renderOrigin)` (ADR-003).
    ///
    /// - Parameters:
    ///   - polyline: the resolved polyline (world coords, f64).
    ///   - renderOrigin: the per-view f64 floating origin to subtract.
    ///   - halfWidthPx: device-pixel half-width for every emitted segment.
    ///   - into: the instance array to append to (lets the caller pack many
    ///     polylines into one contiguous buffer with no intermediate allocation).
    static func appendInstances(
        for polyline: ResolvedPolyline,
        renderOrigin: Vector,
        halfWidthPx: Float = defaultHalfWidthPx,
        into instances: inout [LineInstance]
    ) {
        let pts = polyline.points
        guard !pts.isEmpty else { return }

        let color = SIMD4<Float>(
            polyline.pen.color.r, polyline.pen.color.g,
            polyline.pen.color.b, polyline.pen.color.a
        )

        // Degenerate single point → zero-length segment (drawn as a dot).
        if pts.count == 1 {
            let p = offset(pts[0], from: renderOrigin)
            instances.append(LineInstance(p0: p, p1: p, color: color, halfWidthPx: halfWidthPx))
            return
        }

        // Consecutive segments.
        for i in 0..<(pts.count - 1) {
            instances.append(LineInstance(
                p0: offset(pts[i], from: renderOrigin),
                p1: offset(pts[i + 1], from: renderOrigin),
                color: color,
                halfWidthPx: halfWidthPx
            ))
        }

        // Closing edge for closed polylines (last → first).
        if polyline.closed, pts.count >= 3,
           let first = pts.first, let last = pts.last {
            instances.append(LineInstance(
                p0: offset(last, from: renderOrigin),
                p1: offset(first, from: renderOrigin),
                color: color,
                halfWidthPx: halfWidthPx
            ))
        }
    }

    /// Builds the full instance array for a set of resolved geometries.
    /// (Convenience used by the renderer when (re)building the model buffer; the
    /// renderer may instead build only the culled visible subset — see
    /// `CADCanvasView`.)
    static func instances(
        from geometries: [ResolvedGeometry],
        renderOrigin: Vector,
        halfWidthPx: Float = defaultHalfWidthPx
    ) -> [LineInstance] {
        var out: [LineInstance] = []
        // Reserve a rough estimate to avoid repeated growth on large drawings.
        out.reserveCapacity(geometries.reduce(0) { acc, g in
            acc + g.polylines.reduce(0) { $0 + Swift.max($1.points.count, 1) }
        })
        for g in geometries {
            for poly in g.polylines {
                appendInstances(for: poly, renderOrigin: renderOrigin,
                                halfWidthPx: halfWidthPx, into: &out)
            }
        }
        return out
    }

    /// Picks a sensible f64 `renderOrigin` near the drawing so the f32 offsets
    /// stay small (ADR-003): the center of the bounding box, or `(0,0)` for an
    /// empty/degenerate box.
    static func renderOrigin(for bounds: AABB) -> Vector {
        guard !bounds.isEmpty else { return Vector(0, 0) }
        let c = bounds.center
        return c.valid ? Vector(c.x, c.y) : Vector(0, 0)
    }

    // MARK: - Internal

    /// `f32(world - renderOrigin)` — the floating-origin subtraction (ADR-003).
    @inline(__always)
    static func offset(_ world: Vector, from origin: Vector) -> SIMD2<Float> {
        SIMD2<Float>(Float(world.x - origin.x), Float(world.y - origin.y))
    }
}
