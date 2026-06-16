//
//  BlockThumbnailScene.swift
//  CADEngine
//
//  Builds an `ExportScene` for a SINGLE block definition's member geometry — the
//  engine half of the Blocks-sidebar thumbnail feature (so a row shows what the
//  block actually looks like instead of a generic "square.on.square" icon).
//
//  This mirrors `ExportSceneBuilder.build` (resolve every member → accumulate
//  polylines/fills/images + world bounds) but iterates ONLY the block's
//  `entityIDs` member subset rather than the whole drawing. Resolution uses the
//  drawing's `ResolveContext` (built once via `makeResolveContext()` when the
//  caller doesn't supply one), so a member that is itself an `.insert` of another
//  block expands correctly (nested inserts) and `byBlock`/`byLayer` pens resolve
//  identically to the canvas / export renderers.
//
//  Layer-visibility policy DIFFERS from drawing export on purpose: a thumbnail
//  shows the block's DEFINITION, so a member on a frozen / non-printable layer is
//  STILL drawn (you want to see the whole block in the palette even if that layer
//  is hidden in the model). It does honor `block.isFrozen` only insofar as the
//  member lookup is by id — a frozen block still has resolvable members, so its
//  thumbnail renders (the sidebar may dim a frozen row separately).
//
//  Like `SVGExporter`, this file is DELIBERATELY free of CoreGraphics/AppKit so it
//  is unit-testable in the CADEngine test target with no graphics context. The
//  bitmap→NSImage rendering lives in the app target (`BlockThumbnailRenderer`) and
//  reuses the shared `CGSceneRenderer` over the `ExportScene` this builds — so the
//  thumbnail is geometrically identical to PDF/PNG/SVG export and the screen.
//
//  Reusable beyond the sidebar: any future block-palette / library-tile / insert-
//  preview UI can call `blockThumbnailScene` to get a resolved scene to render.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// Builds an `ExportScene` from one block definition's member geometry.
///
/// - Parameters:
///   - drawing: the document whose block table + entities back the lookup.
///   - blockName: the block definition to preview (looked up by exact name).
///   - context: an optional pre-built `ResolveContext` (e.g. one the caller already
///     made for a batch of thumbnails — building it once and reusing it across all
///     rows avoids re-snapshotting the layer/style/block tables per row). When
///     `nil`, the drawing's `makeResolveContext()` is used.
/// - Returns: the resolved scene (polylines + fills + images + world bounds), or
///   `nil` when the block is unknown OR has no resolvable, non-empty geometry (so
///   the caller falls back to the generic icon).
///
/// `@MainActor` because `CADDrawing` is main-actor isolated (matching
/// `ExportSceneBuilder.build`); callers (the sidebar) already run there.
@MainActor
public func blockThumbnailScene(_ drawing: CADDrawing,
                                blockName: String,
                                context: ResolveContext? = nil) -> ExportScene? {
    guard let block = drawing.blocks.block(named: blockName) else { return nil }
    guard !block.entityIDs.isEmpty else { return nil }

    let ctx = context ?? drawing.makeResolveContext()

    var polylines: [ResolvedPolyline] = []
    var fills: [ResolvedFill] = []
    var images: [ResolvedImage] = []
    var bounds = AABB.empty

    for id in block.entityIDs {
        // Member id-refs point at records in `CADDrawing.entities` (ADR-001); a
        // ref no longer in the drawing is skipped (the block keeps its other
        // members) — mirrors `blockMembersSnapshot()`'s `compactMap`.
        guard let e = drawing.entity(id) else { continue }
        // NOTE: no layer-visibility filter here (unlike `ExportSceneBuilder`): a
        // thumbnail shows the block's full definition regardless of which layers
        // are frozen / non-printable in the live model.
        let geo = e.resolve(ctx)
        for poly in geo.polylines {
            polylines.append(poly)
            for p in poly.points { bounds.expand(toInclude: p) }
        }
        for fill in geo.fills {
            fills.append(fill)
            for loop in fill.loops { for p in loop { bounds.expand(toInclude: p) } }
        }
        for image in geo.images {
            images.append(image)
            for p in image.corners { bounds.expand(toInclude: p) }
        }
    }

    // Nothing resolved to a drawable (e.g. all members were dangling refs, or the
    // block holds only zero-geometry constructs) → no useful thumbnail.
    if polylines.isEmpty && fills.isEmpty && images.isEmpty { return nil }

    return ExportScene(polylines: polylines, fills: fills, images: images, bounds: bounds)
}
