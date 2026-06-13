//
//  Viewport.swift
//  CADEngine
//
//  The shared, pure, testable f64 viewport transform — the single source of
//  truth for "where does a world point land on screen / in the GPU clip space".
//  Consumed by BOTH the Metal renderer (world→clip matrix uniform) and the
//  CPU selection/snapping path (world↔screen + tolerance conversion). Workstream
//  G of the Render+Interaction gate.
//
//  Pure Swift value type, f64 throughout (ADR-003); no AppKit/Metal/GPU
//  dependency beyond CoreGraphics value types (CGPoint/CGSize) and simd's
//  float4x4 for the GPU matrix. Unit-testable without the app or a device.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation
import CoreGraphics
import simd

/// A 2D viewport transform mapping between three coordinate spaces:
///
/// 1. **World** — the engine's f64 CAD coordinates. Right-handed, **Y-up**
///    (mathematical convention; LibreCAD/DXF are Y-up).
/// 2. **Screen** — AppKit points. **Origin top-left, Y-DOWN** (the convention
///    used by a *flipped* `NSView`/`MTKView` whose `isFlipped == true`, and by
///    SwiftUI). This is the single place the Y axis is flipped: everything
///    *outside* `Viewport` stays Y-up. (If the host view is NOT flipped, the
///    view layer must flip the incoming `y` once before calling `screenToWorld`;
///    `Viewport` is defined for the top-left, Y-down convention.)
/// 3. **Clip / NDC** — Metal normalized device coordinates, **Y-UP**, range
///    `[-1, 1]` on both axes (lower-left of the drawable is `(-1, -1)`). Produced
///    only by `worldToClip(...)` for the GPU.
///
/// ## Units: points vs. device pixels
/// `scale`, `center`, and `size` are all in **logical points** (the AppKit
/// coordinate space). `scale` is therefore *points per world unit*. Retina /
/// backing scale is handled at the GPU seam only: `worldToClip(...)` takes the
/// **drawable pixel size** and the NDC mapping is derived from it, so 1-point
/// lines stay crisp on any backing scale without the world↔screen API ever
/// dealing in device pixels. (We deliberately do NOT store a `contentScale`:
/// screen-space math is in points; pixels enter exactly once, at the matrix.)
///
/// ## Floating-origin GPU contract (ADR-003) — read before wiring the renderer
/// Geometry buffers store **`Float` offsets from a per-view f64 `renderOrigin`**
/// (`f32(worldPoint - renderOrigin)`), NEVER absolute world coordinates. The
/// `world→clip` matrix folds in `(center - renderOrigin)`, the scale, the view
/// size, and the Y-up NDC flip. Consequence: **pan and zoom only change the
/// matrix** — the f32 vertex buffers are never rebuilt for a view change. The
/// subtraction path exists from day one (`renderOrigin` may be `(0,0)`
/// initially) so extreme-zoom precision is not a retrofit.
public struct Viewport: Sendable, Equatable {

    /// Logical points per world unit (the zoom factor). Always `> 0` for a usable
    /// viewport; constructors and mutators clamp to a small positive floor.
    public var scale: Double

    /// The world point currently mapped to the **center** of the view.
    public var center: Vector

    /// The view size in **logical points** (width × height).
    public var size: CGSize

    /// The smallest scale we allow, to keep the transform invertible and the GPU
    /// matrix finite even when callers pass garbage (e.g. fitting an empty bbox).
    public static let minScale = 1.0e-12

    /// A sensible fallback scale (1 point == 1 world unit) used when `fit` is
    /// handed a degenerate/empty bounding box.
    public static let defaultScale = 1.0

    // MARK: - Construction

    /// Creates a viewport. `scale` is clamped to `>= minScale`.
    public init(scale: Double, center: Vector, size: CGSize) {
        self.scale = Swift.max(scale, Viewport.minScale)
        self.center = center.valid ? center : Vector(0, 0)
        self.size = size
    }

    /// An identity-ish viewport centered on the world origin at 1 pt/unit, for the
    /// given view size — a safe starting state before any document is loaded.
    public init(size: CGSize) {
        self.init(scale: Viewport.defaultScale, center: Vector(0, 0), size: size)
    }

    // MARK: - Scale helpers

    /// Logical points per world unit (== `scale`). Named for symmetry with the
    /// renderer's "pixels per unit" mental model; on a non-Retina display this is
    /// literally device pixels per unit, on Retina multiply by the backing scale.
    public var pixelsPerUnit: Double { scale }

    /// World units per logical point (`1 / scale`). This is the value the
    /// **selection / snapping** path needs: a GUI catch range in points (e.g.
    /// LibreCAD's `m_catchEntityGuiRange`) times `worldPerPixel` gives the
    /// world-space tolerance for a quadtree probe / nearest-point query.
    public var worldPerPixel: Double { 1.0 / scale }

    // MARK: - World ↔ Screen (Y flipped here, once)

    /// Maps a world point to a screen point (AppKit points, **top-left origin,
    /// Y-down**). World is Y-up, screen is Y-down, so the Y term is negated.
    ///
    /// Derivation: a world point at `center` lands at the view center
    /// `(width/2, height/2)`; each world unit is `scale` points; +Y world goes
    /// *up* the screen i.e. toward smaller screen-y.
    public func worldToScreen(_ p: Vector) -> CGPoint {
        let dx = (p.x - center.x) * scale
        let dy = (p.y - center.y) * scale
        return CGPoint(
            x: Double(size.width) * 0.5 + dx,
            y: Double(size.height) * 0.5 - dy   // Y-flip: world Y-up → screen Y-down
        )
    }

    /// Maps a screen point (AppKit points, **top-left origin, Y-down**) back to a
    /// world point (Y-up). Inverse of `worldToScreen`.
    public func screenToWorld(_ s: CGPoint) -> Vector {
        let dx = (Double(s.x) - Double(size.width) * 0.5) / scale
        let dy = (Double(s.y) - Double(size.height) * 0.5) / scale
        return Vector(
            center.x + dx,
            center.y - dy   // un-flip: screen Y-down → world Y-up
        )
    }

    // MARK: - Zoom & pan (matrix-only view changes; buffers untouched)

    /// Multiplies the zoom by `factor` while keeping the world point currently
    /// under `screenPoint` fixed on screen ("zoom about the cursor"). `factor > 1`
    /// zooms in. The new scale is clamped to `>= minScale`.
    ///
    /// Implementation: capture the world point under the cursor, change `scale`,
    /// then shift `center` so that same world point re-projects to the same screen
    /// point. Derivation — let `w` be the anchor world point and `o` its screen
    /// offset from the view center (`o = screenPoint - viewCenter`, in points,
    /// with Y already screen-down). For the anchor to stay put after scaling:
    ///   `center' = w - (o.x, -o.y) / scale'`
    /// (the `-o.y` undoes the screen Y-down flip back to world Y-up).
    public mutating func zoom(by factor: Double, about screenPoint: CGPoint) {
        guard factor > 0, factor.isFinite else { return }
        let anchorWorld = screenToWorld(screenPoint)
        let newScale = Swift.max(scale * factor, Viewport.minScale)
        // Screen offset of the anchor from the view center, in points.
        let ox = Double(screenPoint.x) - Double(size.width) * 0.5
        let oy = Double(screenPoint.y) - Double(size.height) * 0.5
        scale = newScale
        center = Vector(
            anchorWorld.x - ox / newScale,
            anchorWorld.y + oy / newScale   // +oy: screen Y-down → world Y-up
        )
    }

    /// Pans the view by a screen-space delta (AppKit points, Y-down). A delta of
    /// `(+dx, 0)` moves the *content* right by `dx` points (the world point under
    /// a fixed pixel shifts left), matching a click-drag-the-canvas gesture.
    public mutating func pan(byScreenDelta d: CGSize) {
        // Moving content by +d points means the center world point moves by
        // -d / scale (and Y un-flipped).
        center = Vector(
            center.x - Double(d.width) / scale,
            center.y + Double(d.height) / scale   // screen Y-down → world Y-up
        )
    }

    // MARK: - Zoom-to-fit

    /// Builds a viewport that fits `bounds` inside `size` (centered), leaving a
    /// `padding`-point margin on every edge. Empty or zero-size bounds (and
    /// zero/negative `size`) fall back to `defaultScale` centered on the bbox
    /// center (or the world origin), so this never produces a NaN/inf transform
    /// and never divides by zero.
    ///
    /// - Parameters:
    ///   - bounds: the world AABB to frame.
    ///   - size: the target view size in logical points.
    ///   - padding: per-edge margin in logical points (default 20).
    public static func fit(_ bounds: AABB, in size: CGSize, padding: Double = 20) -> Viewport {
        let w = Double(size.width)
        let h = Double(size.height)

        // The world point we want centered. Empty bbox → world origin.
        let targetCenter: Vector = {
            let c = bounds.center
            return c.valid ? Vector(c.x, c.y) : Vector(0, 0)
        }()

        // Guard the view size: a zero/degenerate view can't fit anything.
        guard w > 0, h > 0, !bounds.isEmpty else {
            return Viewport(scale: defaultScale, center: targetCenter, size: size)
        }

        // Usable area after padding (never negative).
        let availW = Swift.max(w - 2 * padding, 1.0)
        let availH = Swift.max(h - 2 * padding, 1.0)

        let bw = bounds.size.x
        let bh = bounds.size.y

        // Degenerate bbox (a point or a zero-width/height line) → keep default
        // scale rather than dividing by zero / fitting to infinity.
        let scaleX = bw > Tolerance.distance ? availW / bw : Double.greatestFiniteMagnitude
        let scaleY = bh > Tolerance.distance ? availH / bh : Double.greatestFiniteMagnitude
        let fitted = Swift.min(scaleX, scaleY)

        let chosen = fitted.isFinite ? fitted : defaultScale
        return Viewport(scale: chosen, center: targetCenter, size: size)
    }

    // MARK: - Zoom window (drag-box zoom, F23)

    /// Builds the viewport for a **zoom-window** gesture: frame the WORLD rectangle
    /// `worldRect` so it fills the current view, keeping the SAME view `size`
    /// (only `scale` + `center` change). The rectangle is the inverse image of the
    /// user's drag box (two corners → `screenToWorld` → an `AABB`); this re-scales so
    /// that box maps to (nearly) the whole view.
    ///
    /// Unlike `fit(_:in:)` this:
    ///   - keeps the *receiver's* `size` (a zoom-window never resizes the view), and
    ///   - centers on the rectangle's CENTER at a scale that makes the rect fill the
    ///     view minus `padding` on each edge (the tighter of the two axes, so the
    ///     whole box is visible — never cropped),
    ///   - is a pure copy (the receiver is unchanged); the caller assigns the result.
    ///
    /// A degenerate (zero-area, or sub-tolerance) `worldRect` — e.g. a click rather
    /// than a drag — returns the receiver UNCHANGED (no zoom), so a stray click in
    /// zoom-window mode is a harmless no-op rather than an infinite zoom.
    public func zoomedToWorldRect(_ worldRect: AABB, padding: Double = 8) -> Viewport {
        guard !worldRect.isEmpty else { return self }
        let w = Double(size.width)
        let h = Double(size.height)
        guard w > 0, h > 0 else { return self }

        let bw = worldRect.size.x
        let bh = worldRect.size.y
        // A sub-tolerance box (a click) is not a real window → no zoom.
        guard bw > Tolerance.distance || bh > Tolerance.distance else { return self }

        let availW = Swift.max(w - 2 * padding, 1.0)
        let availH = Swift.max(h - 2 * padding, 1.0)

        let scaleX = bw > Tolerance.distance ? availW / bw : Double.greatestFiniteMagnitude
        let scaleY = bh > Tolerance.distance ? availH / bh : Double.greatestFiniteMagnitude
        // Take the TIGHTER axis so the whole box fits (the other axis shows extra).
        let fitted = Swift.min(scaleX, scaleY)
        let chosen = (fitted.isFinite && fitted > 0) ? fitted : Viewport.defaultScale

        let c = worldRect.center
        let newCenter = c.valid ? Vector(c.x, c.y) : center
        return Viewport(scale: chosen, center: newCenter, size: size)
    }

    // MARK: - Visible world rectangle (for quadtree culling)

    /// The world-space AABB currently visible in the view — the inverse image of
    /// the whole view rectangle. Feed this to the quadtree's region query to cull
    /// to potentially-visible entities (rendering doc §2.3).
    public var visibleWorldRect: AABB {
        // The four view corners in screen points; map both extremes back to world.
        // (Y-flip means screen top-left maps to world top-LEFT, so we take min/max
        //  explicitly rather than assuming a corner ordering.)
        let a = screenToWorld(CGPoint(x: 0, y: 0))
        let b = screenToWorld(CGPoint(x: Double(size.width), y: Double(size.height)))
        return AABB(
            min: Vector(Swift.min(a.x, b.x), Swift.min(a.y, b.y)),
            max: Vector(Swift.max(a.x, b.x), Swift.max(a.y, b.y))
        )
    }

    // MARK: - World → Clip matrix (the GPU contract, ADR-003 floating-origin)

    /// Builds the `world→clip` `float4x4` the renderer uploads as a uniform. The
    /// matrix maps a **`Float` offset from `renderOrigin`** —
    /// `f32(worldPoint - renderOrigin)`, the exact contents of the vertex
    /// buffers — directly to Metal NDC (Y-up, `[-1, 1]`).
    ///
    /// The renderer's per-vertex input is `simd_float2(worldPoint - renderOrigin)`
    /// (z fixed at 0). Multiply it (as `float4(x, y, 0, 1)`) by this matrix to get
    /// clip space. Pan/zoom rebuild **only** this matrix; the f32 buffers are
    /// never touched (floating-origin contract).
    ///
    /// - Parameters:
    ///   - renderOrigin: the per-view f64 origin the f32 buffers are relative to.
    ///     Choose it near the visible content (e.g. `center` snapped, or the
    ///     drawing centroid) so the f32 offsets stay small. `(0,0)` is fine until
    ///     coordinates grow large.
    ///   - drawableSize: the Metal drawable size in **device pixels** (typically
    ///     view points × backing scale). Only its **aspect** matters for the
    ///     mapping — clip space is normalized — but it is taken explicitly so the
    ///     renderer threads the real drawable through (and so a future
    ///     non-uniform-DPI path has the hook). If it is zero/degenerate we fall
    ///     back to the point `size` so the matrix is always finite.
    ///
    /// ### Derivation
    /// A world point `p` projects to NDC by:
    ///   `ndc.x = (p.x - center.x) * scale / (viewWidthPx / 2)`
    ///   `ndc.y = (p.y - center.y) * scale / (viewHeightPx / 2)`   (Y-up: no flip)
    /// where `scale` is points/unit and `viewWidthPx` is the drawable width in the
    /// SAME unit as `scale`. Because `scale` is points/unit and `drawableSize` is
    /// in *pixels*, we convert: `viewWidthPts = drawableWidthPx / backingScale`.
    /// The backing scale cancels — `scale` (pts/unit) over half-view-in-points is
    /// dimensionless — so we express the half-extent directly in points using the
    /// stored point `size`, and use `drawableSize` only to guard/aspect. Concretely
    /// we use the point `size` for the half-extents (the visible world rect is
    /// defined by points), giving an exact inverse of `worldToScreen`.
    /// Substituting `p = renderOrigin + offset`:
    ///   `ndc.x = ((renderOrigin.x + offset.x) - center.x) * sx`
    ///          = offset.x * sx + (renderOrigin.x - center.x) * sx`
    /// so the matrix scales `offset` by `(sx, sy)` and translates by
    /// `((renderOrigin - center) * (sx, sy))`. `sy` is POSITIVE (NDC is Y-up like
    /// world), so a world point above `center` maps to `+Y` in NDC.
    public func worldToClip(renderOrigin: Vector, drawableSize: CGSize) -> simd_float4x4 {
        // Half view extents in POINTS (scale is points/unit; backing scale
        // cancels). Guard against a zero/degenerate point size.
        let halfWPts = Swift.max(Double(size.width) * 0.5, 0.5)
        let halfHPts = Swift.max(Double(size.height) * 0.5, 0.5)
        _ = drawableSize   // taken for API completeness / future non-uniform DPI;
                           // the pts→NDC mapping is independent of backing scale.

        let sx = scale / halfWPts   // NDC units per world unit, X
        let sy = scale / halfHPts   // NDC units per world unit, Y (Y-up, positive)

        // Translation folds in (renderOrigin - center) so f32 offsets need no
        // CPU re-centering; this is where floating-origin lives.
        let tx = (renderOrigin.x - center.x) * sx
        let ty = (renderOrigin.y - center.y) * sy

        // Column-major float4x4 (simd convention). Maps (offset.x, offset.y, 0, 1):
        //   clip.x = offset.x * sx + tx
        //   clip.y = offset.y * sy + ty
        //   clip.z = 0,  clip.w = 1
        let fsx = Float(sx)
        let fsy = Float(sy)
        let ftx = Float(tx)
        let fty = Float(ty)
        return simd_float4x4(
            SIMD4<Float>(fsx, 0,   0, 0),   // column 0
            SIMD4<Float>(0,   fsy, 0, 0),   // column 1
            SIMD4<Float>(0,   0,   1, 0),   // column 2
            SIMD4<Float>(ftx, fty, 0, 1)    // column 3 (translation)
        )
    }
}
