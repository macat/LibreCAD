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
import CoreGraphics
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
///
/// ## Dash pattern (linetype) — SCREEN-SPACE, fixed-on-zoom
/// `dashPeriodPx` (one full ON+OFF cycle, in DEVICE PIXELS) is `0` for a SOLID
/// segment; the fragment shader then strokes continuously. When `> 0` the shader
/// computes the along-segment distance (using `startOffsetPx` as the running
/// per-polyline arc-length so the pattern is CONTINUOUS across a polyline's
/// segments) modulo `dashPeriodPx` and discards fragments in the gap
/// (`[dashOnPx, dashPeriodPx)`). Because the periods are device pixels (like
/// `halfWidthPx`), dashes are a FIXED SIZE on screen, unchanged by zoom.
struct LineInstance: Equatable {
    /// Segment start, `f32(worldStart - renderOrigin)`.
    var p0: SIMD2<Float>
    /// Segment end, `f32(worldEnd - renderOrigin)`.
    var p1: SIMD2<Float>
    /// RGBA pen color (linear-ish; the drawable does sRGB encode on write).
    var color: SIMD4<Float>
    /// Half-width in device pixels.
    var halfWidthPx: Float
    /// Full dash CYCLE length (ON + OFF) in device pixels. `0` ⇒ solid.
    var dashPeriodPx: Float
    /// The ON (drawn) length within each cycle, in device pixels (`<= dashPeriodPx`).
    var dashOnPx: Float
    /// Running arc-length of this segment's START from the polyline's first point, in
    /// RENDER-SPACE (world) units. The shader converts it to device pixels with the
    /// per-segment world→pixel ratio (a uniform 2D affine scale) and adds it to the
    /// local along-distance, so the dash phase is CONTINUOUS across a polyline's
    /// segments while the period itself stays fixed in device pixels (zoom-fixed).
    var startOffsetWorld: Float
}

// MARK: - The textured-quad vertex (matches `TexturedVertex` in the Metal source)

/// One vertex of a raster-image quad: a render-space position (f32 offset from the
/// floating origin, ADR-003) + a texture coordinate. Layout MUST match
/// `struct TexturedVertex` in `Shaders.swift`. Six per image (two triangles).
struct TexturedVertex: Equatable {
    /// Vertex position, `f32(world - renderOrigin)`.
    var position: SIMD2<Float>
    /// Texture coordinate (0..1).
    var uv: SIMD2<Float>
}

/// One resolved raster image ready for the textured-quad pass: the six quad
/// vertices (two triangles) packed in render space, plus the texture key + display
/// params the renderer needs to bind the texture and set the per-draw shader
/// uniform. The renderer groups by `textureKey` and binds the cached `MTLTexture`.
struct ImageQuad {
    /// The six render-space vertices (triangle list: 0-1-2, 0-2-3).
    var vertices: [TexturedVertex]
    /// The texture cache key (source file path). Empty ⇒ placeholder only.
    var textureKey: String
    /// Brightness 0–100 (DXF 281).
    var brightness: Int
    /// Contrast 0–100 (DXF 282).
    var contrast: Int
    /// Fade 0–100 (DXF 283).
    var fade: Int
    /// Whether to draw only the placeholder outline (hidden/missing image).
    var placeholder: Bool
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
/// ## Holes — implemented (earcut bridge)
/// `triangulateLoops(_:)` stitches `ResolvedFill.loops[1...]` (islands / counters)
/// into the outer ring via the earcut **bridge** technique: cut a zero-area channel
/// from a visible outer-ring vertex to each hole's rightmost vertex so the whole
/// thing becomes ONE simple polygon, then ear-clip it. This is essential for nice
/// outline text — glyph counters (the hole in O / e / A / Ø) render correctly
/// instead of over-filling. (Self-intersecting loops the ear-clipper rejects fall
/// back to a partial fan — never a crash; the §1.3 stencil even-odd path is a later
/// refinement for those.)
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

                // No other vertex inside triangle (a, b, c) → it's an ear. A vertex
                // that COINCIDES with one of the corners (a/b/c) is ignored — this
                // is the case for the duplicated bridge endpoints introduced when
                // stitching a hole (`triangulateLoops`): two distinct indices share
                // the same coordinate, and they must not block the ear.
                var isEar = true
                for j in indices where j != iPrev && j != iCurr && j != iNext {
                    let p = ring[j]
                    if approxEqual(p, a) || approxEqual(p, b) || approxEqual(p, c) { continue }
                    if pointInTriangle(p, a, b, c) { isEar = false; break }
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

    /// Triangulates a polygon WITH holes (`loops[0]` outer, `loops[1...]` islands /
    /// counters) into a flat CCW triangle list. Each hole is stitched into the
    /// outer ring via the earcut **bridge** technique, producing one simple polygon
    /// the single-ring `triangulate(_:)` then ear-clips. Holes render as cut-outs
    /// (glyph counters, hatch islands) instead of over-filling.
    ///
    /// - A single-loop fill (no holes) is forwarded straight to `triangulate(_:)`.
    /// - Degenerate holes (< 3 points) are skipped.
    /// - Robust to CCW/CW input: the outer ring is normalized CCW and each hole CW
    ///   before bridging (the bridge math assumes opposite windings).
    static func triangulateLoops(_ loops: [[Vector]]) -> [Vector] {
        guard let first = loops.first else { return [] }
        // Strip degenerate holes.
        let holes = loops.dropFirst().filter { $0.count >= 3 }
        if holes.isEmpty { return triangulate(first) }

        // Normalize the outer ring to CCW (drop a duplicated closing vertex first).
        var outer = first
        if outer.count >= 2, approxEqual(outer.first!, outer.last!) { outer.removeLast() }
        guard outer.count >= 3 else { return [] }
        if signedArea(outer) < 0 { outer.reverse() }

        // Normalize each hole to CW and sort by descending rightmost-x so the
        // outermost (rightmost) holes bridge first (avoids a later bridge crossing
        // an already-spliced one — the standard earcut ordering).
        var preppedHoles: [[Vector]] = holes.map { h in
            var hole = h
            if hole.count >= 2, approxEqual(hole.first!, hole.last!) { hole.removeLast() }
            if signedArea(hole) > 0 { hole.reverse() }   // make CW
            return hole
        }
        preppedHoles.sort { (maxX($0) ) > (maxX($1)) }

        // Splice each hole into the outer ring via a bridge.
        var ring = outer
        for hole in preppedHoles {
            guard hole.count >= 3 else { continue }
            ring = bridgeHole(ring, hole)
        }

        return triangulate(ring)
    }

    /// Splices `hole` (CW) into `outer` (CCW) by connecting the hole's rightmost
    /// vertex to a mutually-visible vertex of the outer ring with a zero-area
    /// bridge (the two bridge vertices are duplicated so the ring stays a single
    /// closed loop). Returns the merged ring.
    private static func bridgeHole(_ outer: [Vector], _ hole: [Vector]) -> [Vector] {
        // 1. The hole's rightmost vertex (largest x; ties → largest y).
        var hIdx = 0
        for i in 1..<hole.count {
            if hole[i].x > hole[hIdx].x ||
               (hole[i].x == hole[hIdx].x && hole[i].y > hole[hIdx].y) {
                hIdx = i
            }
        }
        let m = hole[hIdx]   // bridge endpoint on the hole

        // 2. Find a visible outer vertex: cast a ray from `m` to the right (+x),
        //    find the closest intersection with an outer edge, then pick the best
        //    visible outer vertex near that intersection (the earcut heuristic).
        var bestOuterIdx = -1
        var bestX = Double.greatestFiniteMagnitude
        var bestPoint = Vector(0, 0)
        let n = outer.count
        for i in 0..<n {
            let a = outer[i]
            let b = outer[(i + 1) % n]
            // Edge must straddle the horizontal line y == m.y, to the right of m.
            if (a.y <= m.y && b.y >= m.y) || (b.y <= m.y && a.y >= m.y) {
                let dy = b.y - a.y
                if abs(dy) < 1e-18 { continue }
                let t = (m.y - a.y) / dy
                let x = a.x + t * (b.x - a.x)
                if x >= m.x - 1e-12, x < bestX {
                    bestX = x
                    bestPoint = Vector(x, m.y)
                    // Candidate bridge vertex: the edge endpoint with the larger x
                    // (closer to the ray's exit), refined below by visibility.
                    bestOuterIdx = (outer[i].x > outer[(i + 1) % n].x) ? i : (i + 1) % n
                }
            }
        }
        if bestOuterIdx < 0 {
            // No visible outer edge (degenerate): bridge to vertex 0 (never
            // crashes; may over/under fill a pathological case).
            bestOuterIdx = 0
            bestPoint = outer[0]
        }

        // 3. Refine: among outer vertices inside the triangle (m, intersection,
        //    candidate) pick the one with the smallest angle to the ray (the
        //    classic earcut "most visible" reflex-vertex check). Cheap version:
        //    keep the candidate unless a reflex vertex lies inside the cone and is
        //    angularly closer.
        let p = bestPoint
        var visibleIdx = bestOuterIdx
        let cand = outer[bestOuterIdx]
        var bestTan = Double.greatestFiniteMagnitude
        if cand.x > m.x {
            bestTan = abs(cand.y - m.y) / (cand.x - m.x)
        }
        for i in 0..<n where i != bestOuterIdx {
            let v = outer[i]
            // Only vertices to the right of m and within the m→intersection→cand
            // triangle can occlude.
            if v.x <= m.x { continue }
            if pointInTriangle(v, m, p, cand) {
                let tan = abs(v.y - m.y) / Swift.max(v.x - m.x, 1e-18)
                if tan < bestTan { bestTan = tan; visibleIdx = i }
            }
        }

        // 4. Build the merged ring: outer[0...visibleIdx], then the hole starting
        //    at hIdx (going around once back to hIdx), then the bridge vertices
        //    duplicated (hole's hIdx and outer's visibleIdx), then the rest of
        //    the outer ring.
        var merged: [Vector] = []
        merged.reserveCapacity(outer.count + hole.count + 2)
        for i in 0...visibleIdx { merged.append(outer[i]) }
        // Hole, starting at its bridge vertex, wrapping fully around.
        for k in 0..<hole.count {
            merged.append(hole[(hIdx + k) % hole.count])
        }
        merged.append(hole[hIdx])          // close back to the hole bridge vertex
        merged.append(outer[visibleIdx])   // bridge back to the outer ring
        if visibleIdx + 1 < outer.count {
            for i in (visibleIdx + 1)..<outer.count { merged.append(outer[i]) }
        }
        return merged
    }

    /// The maximum x of a ring (the rightmost vertex), used to order holes.
    private static func maxX(_ ring: [Vector]) -> Double {
        ring.reduce(-Double.greatestFiniteMagnitude) { Swift.max($0, $1.x) }
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
    /// as a crisp ~1px line. A pen with an EXPLICIT lineweight (`.millimeters`)
    /// overrides this via `halfWidthPx(for:fallback:backingScale:)`; a
    /// `.default`/`.byLayer`/`.byBlock` (unresolved) pen falls back to this.
    static let defaultHalfWidthPx: Float = 0.75

    /// Millimeters per typographic point (1 pt = 1/72 inch, 1 inch = 25.4 mm) —
    /// the mm→points conversion used when turning an explicit pen lineweight into a
    /// device-pixel half-width. Mirrors `RenderPrefs.mmPerPoint` (kept here so this
    /// pure, app-module-free helper has no dependency on the prefs type).
    static let mmPerPoint: Float = 25.4 / 72.0

    /// The device-pixel HALF-width to pack for a resolved pen.
    ///
    /// - An EXPLICIT lineweight (`.millimeters(mm)`) is converted mm → points →
    ///   device pixels, halved (the instance stores HALF the stroke width), and
    ///   FLOORED to the hairline `defaultHalfWidthPx` so a 0 / very-thin width
    ///   still reads as a crisp line rather than vanishing. This is a fixed device
    ///   size — it does NOT scale with zoom (AutoCAD lineweight convention; the
    ///   Metal path is already screen-space so this is automatic).
    /// - Any NON-explicit width (`.default`/`.byLayer`/`.byBlock` — i.e. a pen the
    ///   resolve step could not reduce to a concrete millimeter value) returns the
    ///   supplied `fallback` (the renderer's global default-width half-width), so
    ///   existing behavior is unchanged when no lineweight is set.
    ///
    /// Pure value math (no Metal/AppKit) → unit-testable in `RendererGeometryTests`.
    static func halfWidthPx(for pen: ResolvedPen, fallback: Float, backingScale: CGFloat) -> Float {
        switch pen.lineWidth {
        case .millimeters(let mm):
            let s = Float(backingScale > 0 ? backingScale : 1)
            let pts = Float(mm) / mmPerPoint
            return max(defaultHalfWidthPx, pts * s * 0.5)
        case .default, .byLayer, .byBlock:
            return fallback
        }
    }

    /// The screen-space dash parameters (DEVICE PIXELS) for a resolved pen line type:
    /// `(periodPx, onPx)` where `periodPx` is one full ON+OFF cycle and `onPx` is the
    /// drawn portion. A SOLID line (and any residual `.byLayer`/`.byBlock` the resolve
    /// could not reduce) returns `(0, 0)` ⇒ the shader strokes continuously.
    ///
    /// The periods are device pixels (like `halfWidthPx`), so dashes are a FIXED size
    /// on screen — they do NOT grow/shrink with zoom. A base ON-dash length is taken
    /// in POINTS and multiplied by `backingScale` (Retina 2×) to device pixels; the
    /// other styles are proportional to it. A `.dotted` "dot" is a short ON pip
    /// (rounded by the shader's existing cap AA) rather than a zero-length stall.
    ///
    /// Pure value math (no Metal/AppKit) → unit-testable in `RendererGeometryTests`.
    ///
    /// - Returns: `(periodPx, onPx)` — `(0, 0)` for solid, else `periodPx > onPx > 0`.
    static func dashParamsPx(for lineType: PenLineType, backingScale: CGFloat) -> (period: Float, on: Float) {
        let s = Float(backingScale > 0 ? backingScale : 1)
        // Base dash unit: ~5 points of ON dash → device pixels.
        let dashPt: Float = 5.0
        let dash = dashPt * s          // long ON dash (device px)
        let gap = dash * 0.6           // OFF gap between marks
        let dot = max(1.5 * s, dash * 0.18)   // short ON pip (a "dot")

        switch lineType {
        case .solid, .byLayer, .byBlock:
            return (0, 0)
        case .dashed:
            // ─ ─ ─ : one ON dash + one gap.
            return (dash + gap, dash)
        case .dotted:
            // · · · : one ON dot + one gap.
            return (dot + gap, dot)
        case .dashDot:
            // ─ · ─ · : dash, gap, dot, gap. The shader supports ONE on/off split
            // per cycle, so the cycle is [ON = dash, OFF = (gap + dot + gap)] which
            // reads as a long dash separated by a short dot-gap-dot rhythm.
            return (dash + gap + dot + gap, dash)
        case .center:
            // ─── · ─── : long dash, gap (the long-dash/short-dash centerline reads
            // as a long ON with a proportional gap at this single-split granularity).
            return (dash * 1.5 + gap, dash * 1.5)
        case .border:
            // ── ── · : medium dash + gap.
            return (dash * 0.9 + gap, dash * 0.9)
        case .divide:
            // ─── · · : long dash + a longer gap (the dot run reads as gap here).
            return (dash * 1.3 + gap * 1.4, dash * 1.3)
        }
    }

    /// Light-mode "automatic color" auto-invert: a pen whose RGB is near-white
    /// (the CAD color-7 / "automatic" default the engine resolves to white for a
    /// dark canvas) is flipped to near-black so it stays legible on a light canvas
    /// — the standard AutoCAD/LibreCAD behavior. Any pen with an explicit non-white
    /// color (a layer color, an entity override) is returned UNCHANGED. Alpha is
    /// preserved. Pure value math → unit-testable.
    ///
    /// "Near-white" is min(r,g,b) ≥ `whiteThreshold` so a faint off-white default
    /// still inverts while a real light-gray drawing color does not.
    static func autoInvertWhite(_ c: SIMD4<Float>) -> SIMD4<Float> {
        let whiteThreshold: Float = 0.85
        if min(c.x, c.y, c.z) >= whiteThreshold {
            // Near-black with the same alpha (a hair above pure black so it reads
            // as ink, not a void, against the off-white canvas).
            return SIMD4<Float>(0.10, 0.10, 0.12, c.w)
        }
        return c
    }

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
    ///   - halfWidthPx: the FALLBACK device-pixel half-width — used for a pen with
    ///     no explicit lineweight (`.default`/`.byLayer`/`.byBlock`). A pen with an
    ///     explicit `.millimeters` width OVERRIDES this per-polyline via
    ///     `halfWidthPx(for:fallback:backingScale:)` (mm → device px, fixed on zoom).
    ///   - backingScale: points→pixels for the display (e.g. 2 on Retina), used to
    ///     convert an explicit mm lineweight to device pixels. Defaults to 1 so
    ///     existing call sites / tests that pass only a half-width still compile.
    ///   - colorTransform: an optional per-pen color remap applied to the pen's
    ///     RGBA before packing (identity by default). The renderer uses this for
    ///     the light-mode "automatic color" auto-invert (near-white → near-black)
    ///     so the default drawing color stays legible on a light canvas; passing
    ///     nothing leaves the resolved pen color untouched (so this is GPU-free and
    ///     the unit tests' colors pass through unchanged).
    ///   - into: the instance array to append to (lets the caller pack many
    ///     polylines into one contiguous buffer with no intermediate allocation).
    static func appendInstances(
        for polyline: ResolvedPolyline,
        renderOrigin: Vector,
        halfWidthPx: Float = defaultHalfWidthPx,
        backingScale: CGFloat = 1,
        colorTransform: (SIMD4<Float>) -> SIMD4<Float> = { $0 },
        into instances: inout [LineInstance]
    ) {
        let pts = polyline.points
        guard !pts.isEmpty else { return }

        let color = colorTransform(SIMD4<Float>(
            polyline.pen.color.r, polyline.pen.color.g,
            polyline.pen.color.b, polyline.pen.color.a
        ))

        // Per-polyline stroke half-width: an explicit pen lineweight overrides the
        // passed `halfWidthPx` fallback (mm → device px, fixed on zoom); a pen with
        // no explicit width keeps the fallback (existing behavior).
        let halfWidthPx = self.halfWidthPx(
            for: polyline.pen, fallback: halfWidthPx, backingScale: backingScale)

        // Per-polyline dash params (device pixels, fixed on zoom). `(0, 0)` ⇒ solid,
        // so an existing solid polyline packs `dashPeriodPx == 0` (unchanged render).
        let (dashPeriodPx, dashOnPx) = dashParamsPx(for: polyline.pen.lineType,
                                                    backingScale: backingScale)

        // Degenerate single point → zero-length segment (drawn as a dot). A point is
        // always solid (a dash pattern on a zero-length stub is meaningless).
        if pts.count == 1 {
            let p = offset(pts[0], from: renderOrigin)
            instances.append(LineInstance(
                p0: p, p1: p, color: color, halfWidthPx: halfWidthPx,
                dashPeriodPx: 0, dashOnPx: 0, startOffsetWorld: 0))
            return
        }

        // Running arc-length (RENDER-SPACE / world units) from the polyline's first
        // point, so the dash phase stays CONTINUOUS across segments. The shader
        // converts this to device pixels via the per-segment world→pixel ratio.
        var offsetWorld: Float = 0

        // Consecutive segments.
        for i in 0..<(pts.count - 1) {
            let a = offset(pts[i], from: renderOrigin)
            let b = offset(pts[i + 1], from: renderOrigin)
            instances.append(LineInstance(
                p0: a, p1: b, color: color, halfWidthPx: halfWidthPx,
                dashPeriodPx: dashPeriodPx, dashOnPx: dashOnPx,
                startOffsetWorld: offsetWorld
            ))
            offsetWorld += simd.length(b - a)
        }

        // Closing edge for closed polylines (last → first).
        if polyline.closed, pts.count >= 3,
           let first = pts.first, let last = pts.last {
            let a = offset(last, from: renderOrigin)
            let b = offset(first, from: renderOrigin)
            instances.append(LineInstance(
                p0: a, p1: b, color: color, halfWidthPx: halfWidthPx,
                dashPeriodPx: dashPeriodPx, dashOnPx: dashOnPx,
                startOffsetWorld: offsetWorld
            ))
        }
    }

    /// Triangulates one `ResolvedFill` (outer boundary `loops[0]` + holes
    /// `loops[1...]`) into flat triangle vertices (`FlatVertex`, render-space f32
    /// offsets + the fill color) and appends them to `verts` for the shared flat/
    /// triangle pipeline.
    ///
    /// - Holes (`loops[1...]`) ARE subtracted via the earcut bridge — glyph
    ///   counters / hatch islands render as cut-outs (essential for nice text).
    /// - Output is appended (3 vertices per triangle) so many fills pack into one
    ///   contiguous buffer with no intermediate allocation.
    /// - A degenerate boundary (< 3 effective points) appends nothing.
    static func appendFillVertices(
        for fill: ResolvedFill,
        renderOrigin: Vector,
        into verts: inout [FlatVertex]
    ) {
        guard let outer = fill.outerLoop, outer.count >= 3 else { return }
        let tris = fill.loops.count > 1
            ? FillTriangulation.triangulateLoops(fill.loops)
            : FillTriangulation.triangulate(outer)
        guard !tris.isEmpty else { return }
        let color = SIMD4<Float>(fill.color.r, fill.color.g, fill.color.b, fill.color.a)
        verts.reserveCapacity(verts.count + tris.count)
        for p in tris {
            verts.append(FlatVertex(position: offset(p, from: renderOrigin), color: color))
        }
    }

    /// Builds an `ImageQuad` from a resolved raster image: the four world corners
    /// (CCW from lower-left) become two triangles in render space, UV-mapped so the
    /// image renders upright (the source's TOP-LEFT pixel lands at the upper-left
    /// corner `+v·H`, i.e. `corners[3]`). Returns `nil` for a degenerate (non-4-
    /// corner) image so the caller skips it.
    ///
    /// ## UV mapping (upright, y-down image space → y-up CAD corners)
    /// `corners` are `[LL, LR, UR, UL]` (CCW from lower-left). A raster image's
    /// pixel rows run TOP→bottom, so the image top (UV v=0) maps to the CAD top
    /// (the upper corners UR/UL) and the image bottom (UV v=1) to the lower corners
    /// LL/LR. Thus:
    ///   LL → (0,1)  LR → (1,1)  UR → (1,0)  UL → (0,0)
    static func imageQuad(for image: ResolvedImage, renderOrigin: Vector) -> ImageQuad? {
        let c = image.corners
        guard c.count == 4 else { return nil }
        let ll = offset(c[0], from: renderOrigin)
        let lr = offset(c[1], from: renderOrigin)
        let ur = offset(c[2], from: renderOrigin)
        let ul = offset(c[3], from: renderOrigin)
        let uvLL = SIMD2<Float>(0, 1)
        let uvLR = SIMD2<Float>(1, 1)
        let uvUR = SIMD2<Float>(1, 0)
        let uvUL = SIMD2<Float>(0, 0)
        // Two triangles: LL-LR-UR, LL-UR-UL.
        let verts = [
            TexturedVertex(position: ll, uv: uvLL),
            TexturedVertex(position: lr, uv: uvLR),
            TexturedVertex(position: ur, uv: uvUR),
            TexturedVertex(position: ll, uv: uvLL),
            TexturedVertex(position: ur, uv: uvUR),
            TexturedVertex(position: ul, uv: uvUL),
        ]
        return ImageQuad(
            vertices: verts,
            textureKey: image.textureKey,
            brightness: image.brightness,
            contrast: image.contrast,
            fade: image.fade,
            placeholder: image.placeholder
        )
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
