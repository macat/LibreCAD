//
//  RendererVisibility.swift
//  LibreCADmacOS
//
//  The GPU-free, unit-testable core of the renderer's LAYER-VISIBILITY filter:
//  given an entity's layer and the live layer table, decide whether the entity
//  contributes geometry (lines AND fills) to the rendered instance set.
//
//  The sidebar's eye toggle freezes/thaws a layer (`isVisible == !isFrozen`), then
//  bumps the model version so the renderer re-culls and re-packs. The filter here
//  is what makes that toggle actually HIDE pixels: an entity on a hidden/frozen
//  layer is dropped before its geometry is resolved, so neither its line instances
//  nor its fill triangles reach the GPU. An entity referencing an UNKNOWN layer
//  (no record) still draws — `resolve()` already falls back to the default pen, so
//  dropping it would silently lose geometry that has no eye-toggle to restore it.
//
//  This file has NO Metal/AppKit dependency (only `CADEngine` value types), so it
//  is exercised by `RendererVisibilityTests` without a GPU — symlinked into the
//  test target the same way `RendererCull.swift` / `RendererGeometry.swift` are.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import CADEngine

/// The pure, GPU-free layer-visibility policy for the instanced-line/fill buffers.
/// Called by `LineRenderer.packEntity` for every culled entity.
enum RendererVisibility {

    /// Whether an entity on `layer` should be rendered, given the live `layers`
    /// table. Returns `false` ONLY for an entity whose layer exists AND is hidden
    /// (`isVisible == false`, i.e. frozen). A missing layer record (unknown layer)
    /// returns `true` so the entity still draws with the default pen — matching the
    /// resolve() fallback and avoiding silent geometry loss for un-toggleable layers.
    static func isRendered(_ layer: LayerID, in layers: LayerTable) -> Bool {
        // `layers.layer(_:)` returns nil for an unknown layer → not hidden → drawn.
        layers.layer(layer)?.isVisible != false
    }
}
