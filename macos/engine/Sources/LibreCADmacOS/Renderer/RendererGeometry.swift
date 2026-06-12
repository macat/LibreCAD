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

// MARK: - Fill triangulation (earcut / ear-clipping, GPU-free & testable)

/// Ear-clipping triangulator for the renderer's filled regions (hatch solid fills,
/// SOLID entities — rendering-performance.md §1.3). Pure value math, NO Metal/AppKit
/// dependency, so it is exercised directly by `FillTriangulationTests` without a GPU.
///
/// ## Scope (foundation)
/// `triangulate(_:)` handles a single **simple** polygon (the `ResolvedFill.loops[0]`
/// outer boundary): concave shapes are fine, CCW/CW input is handled (the algorithm
/// normalizes to CCW internally). It returns a flat triangle list — every group of
/// three consecutive `Vector`s is one CCW triangle.
///
/// ## Holes — backlog
/// `ResolvedFill.loops[1...]` (islands) are NOT yet stitched in. The standard fix is
/// the earcut "bridge" technique (cut a zero-area channel from the outer ring to each
/// hole so the whole thing becomes one simple polygon). Most hatches/SOLIDs in the
/// wild are single-boundary, so this covers the 99% case; holed fills currently render
/// as their solid outer boundary (over-fill, never a crash).
// TODO(backlog): holes — stitch loops[1...] into the outer ring via the earcut bridge
// technique (or fall back to stencil even-odd for loops the ear-clipper rejects, §1.3).
enum FillTriangulation {

    /// Triangulates a simple polygon (one ring; first vertex NOT repeated at the end —
    /// same convention as `ResolvedFill.loops` / `circlePoints`) into a flat list of
    /// triangle vertices (3 per triangle, each triangle CCW).
    ///
    /// - Robustness: collinear / duplicate vertices and a degenerate (< 3 effective
    ///   point) ring yield an empty list rather than a crash. Self-intersecting loops
    ///   are out of scope (the §1.3 stencil fallback covers those) — ear-clipping may
    ///   return a partial fan for them but never crashes.
    /// - CCW/CW agnostic: the input winding is detected via the signed area and the
    ///   working ring is normalized to CCW so the "ear" interior test is consistent.
    static func triangulate(_ loop: [Vector]) -> [Vector] {
        // Drop a duplicated closing vertex if present (callers shouldn't include one,
        // but be defensive so a closed ring `[A,B,C,A]` triangulates as `[A,B,C]`).
        var ring = loop
        if ring.count >= 2, approxEqual(ring.first!, ring.last!) {
            ring.removeLast()
        }
        guard ring.count >= 3 else { return [] }

        // Normalize to CCW so the convex/interior tests below have a fixed orientation.
        if signedArea(ring) < 0 { ring.reverse() }

        // Indices of the remaining (not-yet-clipped) vertices.
        var indices = Array(0..<ring.count)
        var out: [Vector] = []
        out.reserveCapacity((ring.count - 2) * 3)

        // Clip ears until a triangle remains. `guard` count bounds the loop so a
        // pathological (self-intersecting/degenerate) ring can never spin forever.
        var guardCount = 0
        let maxIterations = ring.count * ring.count + 1
        while indices.count > 3 && guardCount < maxIterations {
            guardCount += 1
            var clippedAnEar = false
            let n = indices.count
            for i in 0..<n {
                let iPrev = indices[(i + n - 1) % n]
                let iCurr = indices[i]
                let iNext = indices[(i + 1) % n]
                let a = ring[iPrev], b = ring[iCurr], c = ring[iNext]

                // Convex (CCW) corner? (cross > 0 in a CCW ring is a convex vertex.)
                if cross(a, b, c) <= 0 { continue }

                // No other vertex inside triangle (a, b, c) → it's an ear.
                var isEar = true
                for j in indices where j != iPrev && j != iCurr && j != iNext {
                    if pointInTriangle(ring[j], a, b, c) { isEar = false; break }
                }
                guard isEar else { continue }

                out.append(a); out.append(b); out.append(c)
                indices.remove(at: i)
                clippedAnEar = true
                break
            }
            // No ear found this sweep (collinear/degenerate remainder): bail rather
            // than loop forever — partial output is better than a hang.
            if !clippedAnEar { break }
        }

        // The final triangle.
        if indices.count == 3 {
            out.append(ring[indices[0]])
            out.append(ring[indices[1]])
            out.append(ring[indices[2]])
        }
        return out
    }

    /// Signed area of a 2D polygon (shoelace). Positive == CCW, negative == CW.
    static func signedArea(_ ring: [Vector]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let p = ring[i]
            let q = ring[(i + 1) % ring.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum * 0.5
    }

    /// Twice the signed area of triangle (a, b, c) — `> 0` when CCW (a convex
    /// corner in a CCW ring), `< 0` when CW, `0` when collinear.
    @inline(__always)
    private static func cross(_ a: Vector, _ b: Vector, _ c: Vector) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Point-in-triangle via the same-sign barycentric / half-plane test. Points on
    /// an edge are treated as INSIDE (`<= 0` boundary) so a vertex lying exactly on a
    /// candidate ear's edge blocks the ear (conservative — avoids slivered overlaps).
    @inline(__always)
    private static func pointInTriangle(_ p: Vector, _ a: Vector, _ b: Vector, _ c: Vector) -> Bool {
        let d1 = cross(a, b, p)
        let d2 = cross(b, c, p)
        let d3 = cross(c, a, p)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        // Inside (or on an edge) iff all cross products share a sign.
        return !(hasNeg && hasPos)
    }

    @inline(__always)
    private static func approxEqual(_ a: Vector, _ b: Vector) -> Bool {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy) < 1e-18
    }
}

// MARK: - The per-fill-vertex (matches `FlatVertex` in the Metal source)
//
// Fills reuse the existing flat vertex-color pipeline (`flat_vertex`/`flat_fragment`)
// drawn as `.triangle` primitives. A fill vertex therefore packs exactly like a
// `FlatVertex` (render-space f32 offset + RGBA) — the renderer appends all visible
// fills' triangle vertices into one persistent buffer, drawn BEFORE the lines so the
// stroked edges overlay the fill (rendering-performance.md §1.3).

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

    /// Triangulates one `ResolvedFill`'s OUTER boundary (`loops[0]`) into flat
    /// triangle vertices (`FlatVertex`, render-space f32 offsets + the fill color)
    /// and appends them to `verts` for the shared flat/triangle pipeline.
    ///
    /// - Holes (`loops[1...]`) are NOT yet subtracted — see `FillTriangulation`'s
    ///   holes-backlog note; a holed fill renders as its solid outer boundary.
    /// - Output is appended (3 vertices per triangle) so many fills pack into one
    ///   contiguous buffer with no intermediate allocation.
    /// - A degenerate boundary (< 3 effective points) appends nothing.
    static func appendFillVertices(
        for fill: ResolvedFill,
        renderOrigin: Vector,
        into verts: inout [FlatVertex]
    ) {
        guard let outer = fill.outerLoop, outer.count >= 3 else { return }
        let tris = FillTriangulation.triangulate(outer)
        guard !tris.isEmpty else { return }
        let color = SIMD4<Float>(fill.color.r, fill.color.g, fill.color.b, fill.color.a)
        verts.reserveCapacity(verts.count + tris.count)
        for p in tris {
            verts.append(FlatVertex(position: offset(p, from: renderOrigin), color: color))
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
