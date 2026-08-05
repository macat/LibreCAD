//
//  ViewportModel.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 1 — extraction from the CanvasModel god object.
//  Owns viewport-matrix state: the Viewport (worldToClip, world↔screen),
//  the shared Quadtree (culling + snapping), and the floating-origin
//  renderOrigin. Matrix-only pan/zoom; no document mutation.
//
//  Per perf-arch-review-plan Wave 4: ViewportModel is a focused
//  @Observable at @MainActor so view-matrix changes don't churn
//  document observers. CanvasModel holds this and forwards
//  canvasModel.viewport -> viewportModel.viewport etc.
//
//  GPLv2-or-later.
//

import Foundation
import CoreGraphics
import Observation
import simd
import CADEngine

/// The viewport-owned slice of canvas state: the camera matrix,
/// the spatial index, and the floating origin. Pan/zoom are matrix-only
/// (the f32 instance buffers stay untouched — ADR-003).
@MainActor
@Observable
final class ViewportModel {

    // MARK: - Stored viewport state

    /// The viewport transform. Pan/zoom mutate ONLY this (matrix-only).
    var viewport: Viewport

    /// The shared spatial index over entity AABBs (culling + snapping).
    /// Rebuilt when the model is replaced; incrementally updated on edits.
    @ObservationIgnored
    var quadtree = Quadtree()

    /// The per-view f64 floating origin the f32 instance buffers are relative to
    /// (ADR-003). Chosen near the drawing centroid so f32 offsets stay small.
    @ObservationIgnored
    var renderOrigin: Vector = Vector(0, 0)

    /// The active paper-space / model-space selector and which layout is on screen.
    /// ViewportModel owns the *view* aspect of this (which space is shown) while
    /// the document owns the layout table itself; kept here so the visible-set
    /// culling can be computed without reaching back into CanvasModel.
    private(set) var activeSpace: EntitySpace = .model
    private(set) var activeLayout: String?

    /// Bounded back-stack for Zoom Previous (F23).
    @ObservationIgnored
    private var viewportHistory: [Viewport] = []
    private static let maxViewportHistory = 32

    /// Whether a previous viewport is available (drives menu enable).
    var canZoomPrevious: Bool { !viewportHistory.isEmpty }

    /// Transient zoom-window state (F23).
    var zoomWindowArmed: Bool = false
    @ObservationIgnored
    private(set) var zoomWindowRect: AABB?

    // MARK: - Init

    init(viewport: Viewport = Viewport(size: CGSize(width: 800, height: 600)),
         renderOrigin: Vector = Vector(0, 0)) {
        self.viewport = viewport
        self.renderOrigin = renderOrigin
    }

    // MARK: - Viewport lifecycle

    /// Updates the stored view size (on resize). Keeps the same world center/scale.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport.size = size
    }

    /// Frames a bounding box in the current view (Zoom to Fit, matrix-only).
    func zoomToFit(_ box: AABB) {
        pushHistory()
        viewport = Viewport.fit(box, in: viewport.size)
    }

    /// Pans by a screen-space delta (AppKit points, Y-down).
    func pan(byScreenDelta d: CGSize) {
        viewport.pan(byScreenDelta: d)
    }

    /// Zooms about a screen point. `factor > 1` zooms in.
    func zoom(by factor: Double, about screenPoint: CGPoint) {
        viewport.zoom(by: factor, about: screenPoint)
    }

    /// The current world→clip matrix (for the Metal renderer). Pure pass-through
    /// over Viewport's own matrix, exposed so the renderer can read a single
    /// source without reaching into CanvasModel.
    func worldToClip(drawableSize: CGSize) -> simd_float4x4 {
        viewport.worldToClip(renderOrigin: renderOrigin, drawableSize: drawableSize)
    }

    // MARK: - Quadtree / visible-set culling

    /// Rebuilds the quadtree from the given scoped entities (paper-space filtering
    /// is applied by the caller via PaperSpaceLayout — the caller owns that policy).
    func rebuildIndex(with entities: [EntityRecord], context: ResolveContext) {
        quadtree.removeAll()
        var box = AABB.empty
        for e in entities { box = box.union(e.boundingBox(ctx: context)) }
        if !box.isEmpty { quadtree.reserveWorld(box) }
        for e in entities {
            let b = e.boundingBox(ctx: context)
            if !b.isEmpty { quadtree.insert(e.id, bounds: b) }
        }
    }

    /// The visible entity ids for the current viewport (culling via quadtree).
    /// Thin wrapper so the renderer can cull without reaching into the quadtree directly.
    func visibleIDs() -> [EntityID] {
        // Query the quadtree for the viewport's world rect via its visibleWorldRect.
        let worldRect = viewport.visibleWorldRect
        return quadtree.query(region: worldRect)
    }

    /// When the delta exceeds this many touched entities, fall back to a
    /// full rebuild (same rationale as CanvasModel.quadtreeIncrementalThreshold).
    static let incrementalThreshold = 500

    /// Incremental quadtree sync after an undo/redo delta (Wave 2 P3).
    /// Falls back to `rebuildIndex(with:context:)` when the delta size exceeds
    /// `incrementalThreshold` (the spec's "size > threshold" fallback).
    func syncIncrementally(beforeIDs: Set<EntityID>, beforeBoxes: [EntityID: AABB],
                           afterEntities: [EntityRecord], context: ResolveContext) {
        let afterMap = Dictionary(uniqueKeysWithValues: afterEntities.map { ($0.id, $0) })
        let afterIDs = Set(afterMap.keys)
        var afterBoxes: [EntityID: AABB] = [:]
        for r in afterEntities { afterBoxes[r.id] = r.boundingBox(ctx: context) }
        let removed = beforeIDs.subtracting(afterIDs)
        let added = afterIDs.subtracting(beforeIDs)
        var changedCount = 0
        for id in beforeIDs.intersection(afterIDs) {
            let ob = beforeBoxes[id] ?? .empty
            let nb = afterBoxes[id] ?? .empty
            if ob != nb { changedCount += 1 }
        }
        if removed.count + added.count + changedCount > Self.incrementalThreshold {
            rebuildIndex(with: afterEntities, context: context)
            return
        }
        for id in removed { quadtree.remove(id) }
        for id in added {
            if let b = afterBoxes[id], !b.isEmpty { quadtree.insert(id, bounds: b) }
        }
        for id in beforeIDs.intersection(afterIDs) {
            let oldB = beforeBoxes[id] ?? .empty
            let newB = afterBoxes[id] ?? .empty
            if oldB != newB {
                if newB.isEmpty { quadtree.remove(id) } else { quadtree.update(id, bounds: newB) }
            }
        }
    }

    // MARK: - Zoom history

    /// Pushes the current viewport onto the history stack.
    func pushHistory() {
        viewportHistory.append(viewport)
        if viewportHistory.count > Self.maxViewportHistory {
            viewportHistory.removeFirst(viewportHistory.count - Self.maxViewportHistory)
        }
    }

    /// Restores the most recent viewport (Zoom Previous).
    @discardableResult
    func zoomPrevious() -> Bool {
        guard let prev = viewportHistory.popLast() else { return false }
        viewport = prev
        return true
    }

    // MARK: - Zoom window (F23)

    func setZoomWindowArmed(_ armed: Bool) {
        zoomWindowArmed = armed
        if !armed { zoomWindowRect = nil }
    }

    func beginZoomWindow(at world: Vector) {
        zoomWindowRect = AABB(point: world)
    }

    func updateZoomWindow(from anchor: Vector, to cursor: Vector) {
        zoomWindowRect = AABB(points: [anchor, cursor])
    }

    @discardableResult
    func commitZoomWindow() -> Bool {
        defer { zoomWindowRect = nil; zoomWindowArmed = false }
        guard let rect = zoomWindowRect, !rect.isEmpty else { return false }
        let zoomed = viewport.zoomedToWorldRect(rect)
        guard zoomed != viewport else { return false }
        pushHistory()
        viewport = zoomed
        return true
    }

    func cancelZoomWindow() {
        guard zoomWindowArmed || zoomWindowRect != nil else { return }
        zoomWindowRect = nil
        zoomWindowArmed = false
    }

    // MARK: - Active space (view scoping)

    func setActiveSpace(_ space: EntitySpace, layoutName: String?) {
        activeSpace = space
        activeLayout = layoutName
    }

    // MARK: - Render origin

    /// Picks a floating origin near the content so f32 offsets stay small.
    func rehomeRenderOrigin(to box: AABB) {
        renderOrigin = RendererGeometry.renderOrigin(for: box)
    }
}
