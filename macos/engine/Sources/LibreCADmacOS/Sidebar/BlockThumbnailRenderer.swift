//
//  BlockThumbnailRenderer.swift
//  LibreCADmacOS
//
//  Renders a block definition's geometry to a small `NSImage` preview for the
//  Blocks sidebar (so a row shows WHAT the block is instead of a generic
//  "square.on.square" icon — the owner's ask: "if it's a text, it's hard to see
//  what it is").
//
//  It bridges the engine-pure `blockThumbnailScene` (the block's resolved
//  `ExportScene`) to a bitmap via the SAME `CGSceneRenderer` the PDF/PNG exporters
//  use, so the tile is geometrically identical to export and the on-screen canvas.
//  The bitmap path mirrors `DrawingExporter.writePNG`: a square `CGContext`,
//  flipped to a top-left origin, drawn through the shared renderer, `makeImage()` →
//  `NSImage`.
//
//  Fitting: a fit-to-page `ExportTransform` over the scene bounds maps the block to
//  the tile with a small uniform margin, preserving aspect (the block fills the
//  tile). The stroke width is floored to 0.75 device px (`minStrokeDevicePx`) so a
//  thin block doesn't render sub-pixel and vanish. The background is CLEAR
//  (transparent) so the tile blends into the list row.
//
//  Caching: `BlockThumbnailCache` is a `@MainActor` keyed store the sidebar holds;
//  it keys on `(blockName, modelVersion)` so any committed edit (or block enter/
//  exit) — both of which bump `CanvasModel.modelVersion` — auto-invalidates the
//  cached image. Generation is lazy and synchronous on the main actor: with at most
//  dozens of blocks and small tiles this is cheap, and it keeps the value-type
//  drawing read on the main actor (no Sendable hop).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import AppKit
import CoreGraphics
import CADEngine

/// Renders a block's `ExportScene` to a square `NSImage` tile.
enum BlockThumbnailRenderer {

    /// Builds a `size × size` point thumbnail for `scene`. Returns `nil` when the
    /// scene's bounds are empty/degenerate (nothing to frame) or the bitmap context
    /// can't be created.
    ///
    /// - Parameter scale: the backing-store scale (device px per point). Defaults to
    ///   2 (Retina) so the tile is crisp; the returned `NSImage`'s logical size is
    ///   `size × size` points regardless.
    @MainActor
    static func image(for scene: ExportScene, size: CGFloat, scale: CGFloat = 2) -> NSImage? {
        guard size > 0, !scene.bounds.isEmpty else { return nil }
        // A degenerate bounds (a single point, or a zero-extent run) has no area to
        // fit; ExportTransform clamps it, but there's no meaningful tile — bail so
        // the caller shows the icon.
        let bw = scene.bounds.size.x
        let bh = scene.bounds.size.y
        guard bw.isFinite, bh.isFinite, (bw > 0 || bh > 0) else { return nil }

        // Fit-to-page transform: a square page with a small margin so the block
        // doesn't touch the tile edges. ~10% of the tile per side.
        let margin = Double(size) * 0.1
        let options = ExportOptions(
            pageSize: SizePt(width: Double(size), height: Double(size)),
            margin: margin,
            scaling: .fitToPage,
            background: nil          // transparent tile
        )
        let xform = ExportTransform(bounds: scene.bounds, options: options)

        let pxW = Swift.max(1, Int((size * scale).rounded()))
        let pxH = Swift.max(1, Int((size * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Clear (transparent) background — the row already has its own backing.
        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))

        // Bitmap origin is bottom-left, y-up. Flip to a top-left (y-down) origin AND
        // apply the backing scale so the shared renderer's page-point math fills the
        // bitmap (mirrors `DrawingExporter.writePNG`).
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)

        // Transparent background → pass `nil`; floor the stroke so thin blocks stay
        // visible in the tiny tile.
        CGSceneRenderer.draw(scene: scene, in: ctx, transform: xform,
                             background: nil, minStrokeDevicePx: 0.75)

        guard let cg = ctx.makeImage() else { return nil }
        // Logical size is in POINTS (size × size); the backing store is Retina.
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}

/// A `@MainActor` per-sidebar cache of rendered block thumbnails, keyed by block
/// name + the drawing's `modelVersion`. Because `modelVersion` bumps on every
/// committed edit (and on block enter/exit), a stale entry for an edited block is
/// never returned — its key no longer matches — so edits auto-invalidate without an
/// explicit purge. Entries for older versions are dropped lazily on access to keep
/// the dictionary bounded.
@MainActor
final class BlockThumbnailCache {
    private struct Key: Hashable {
        let name: String
        let version: Int
        let size: Int   // tile size in points, rounded — distinct sizes cache apart
    }
    private var images: [Key: NSImage] = [:]

    init() {}

    /// Returns the cached thumbnail for `(blockName, version, size)`, building it
    /// (and any pre-built `context` reuse) on first miss. Returns `nil` when the
    /// block has no resolvable geometry (the caller falls back to the icon); a `nil`
    /// result is NOT cached, so a block that later gains geometry will render once it
    /// does (its version will have changed anyway).
    func image(for drawing: CADDrawing,
               blockName: String,
               version: Int,
               size: CGFloat,
               context: ResolveContext? = nil) -> NSImage? {
        let key = Key(name: blockName, version: version, size: Int(size.rounded()))
        if let hit = images[key] { return hit }

        // Drop any stale entries for this block from older versions (lazy GC).
        images = images.filter { $0.key.name != blockName || $0.key.version == version }

        guard let scene = blockThumbnailScene(drawing, blockName: blockName, context: context),
              let img = BlockThumbnailRenderer.image(for: scene, size: size) else {
            return nil
        }
        images[key] = img
        return img
    }
}
