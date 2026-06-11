//
//  RendererCull.swift
//  LibreCADmacOS
//
//  The GPU-free, unit-testable core of the renderer's CULL/REBUILD decision: when
//  must the instanced-line buffer be re-culled, and how big a region to cull.
//
//  Floating-origin invariant (rendering-performance.md §4.1, ADR-003): pan/zoom
//  must change ONLY the `world→clip` matrix — they must NOT rebuild the f32
//  instance buffer. The naive "rebuild whenever the visible rect differs from the
//  last-built rect" gate fails that: every pan/zoom yields a slightly different
//  rect, so every frame re-culls + re-resolves + re-packs.
//
//  The fix: cull a region PADDED past the literal visible rect (`expanded(by:)`),
//  and re-cull only when the current visible rect ESCAPES that padded region
//  (`!aabbContains`). A small pan/zoom that stays inside the cached margin reports
//  "no rebuild needed" → matrix-only frame, ZERO buffer rebuild.
//
//  This file has NO Metal/AppKit dependency (only `CADEngine` value types), so it
//  is exercised by `RendererCullTests` without a GPU — symlinked into the test
//  target the same way `RendererGeometry.swift` is.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import CADEngine

/// The pure, GPU-free cull/rebuild policy for the instanced-line buffer. Owned by
/// `LineRenderer`, which holds the cached "built padded rect" and feeds the live
/// visible rect each frame.
enum RendererCull {

    /// How far past the literal visible rect we cull, as a fraction of the rect's
    /// own extent on each side. A pan/zoom inside this padded region reuses the
    /// existing buffer (zero rebuild); only a view change that escapes it re-culls.
    /// ~0.4 ≈ 40% extra margin per side.
    static let defaultMargin = 0.4

    /// The pure rebuild decision. The instance buffer must be re-culled ONLY when:
    ///   - the model changed (`modelChanged`), OR
    ///   - there is no buffer yet (`hasBuffer == false`), OR
    ///   - the current visible rect is NOT contained within the last-built PADDED
    ///     rect (the view escaped the cached margin).
    ///
    /// Steady-state pan/zoom whose visible rect stays inside the padded built rect
    /// returns `false` → matrix-only frame, ZERO buffer rebuild (§4.1).
    static func needsRebuild(builtPaddedRect: AABB, currentVisibleRect: AABB,
                             modelChanged: Bool, hasBuffer: Bool) -> Bool {
        if modelChanged || !hasBuffer { return true }
        return !contains(builtPaddedRect, currentVisibleRect)
    }

    /// `true` if `outer` fully contains `inner` in x/y (a local containment helper
    /// — we do NOT edit Geometry.swift). An empty `inner` is trivially contained;
    /// an empty `outer` contains nothing non-empty.
    static func contains(_ outer: AABB, _ inner: AABB) -> Bool {
        if inner.isEmpty { return true }
        if outer.isEmpty { return false }
        return inner.min.x >= outer.min.x && inner.max.x <= outer.max.x
            && inner.min.y >= outer.min.y && inner.max.y <= outer.max.y
    }

    /// Returns `rect` enlarged by `fraction` of its own extent on EACH side in x/y
    /// (a local expansion helper — we do NOT edit Geometry.swift). An empty rect is
    /// returned unchanged. A degenerate (zero-extent) rect is padded by a small
    /// absolute epsilon so a point/line still gets a usable margin.
    static func expanded(_ rect: AABB, byFraction fraction: Double) -> AABB {
        guard !rect.isEmpty else { return rect }
        let s = rect.size
        let padX = Swift.max(abs(s.x) * fraction, 1e-9)
        let padY = Swift.max(abs(s.y) * fraction, 1e-9)
        return AABB(
            min: Vector(rect.min.x - padX, rect.min.y - padY, rect.min.z),
            max: Vector(rect.max.x + padX, rect.max.y + padY, rect.max.z)
        )
    }
}
