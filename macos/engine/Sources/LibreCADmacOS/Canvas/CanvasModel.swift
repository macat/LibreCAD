//
//  CanvasModel.swift
//  LibreCADmacOS
//
//  The main-actor canvas state shared between SwiftUI, the interaction layer
//  (CADCanvasView), and the Metal renderer. It owns:
//    - the engine `CADDrawing` (the model),
//    - the `Viewport` (matrix-only pan/zoom; ADR-003),
//    - the shared `Quadtree` (culling + snapping, rendering-performance.md §2.2),
//    - the current `Selection` and the latest `SnapResult` + cursor world point.
//
//  Per ADR-003 / rendering-performance.md §4.5 everything here is `@MainActor`:
//  the MTKView delegate callbacks, snapping, and hit-testing all run on the main
//  actor, so there is no cross-actor sharing of the (non-Sendable) `Quadtree`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import Observation
import CADEngine

/// Observable canvas state. SwiftUI observes `entityCount`/`cursorWorld` for the
/// HUD; the renderer reads `drawing`/`viewport`/`quadtree`/`selection`/`snap`.
@MainActor
@Observable
final class CanvasModel {

    // MARK: Model + view state

    /// The engine drawing (entities + layers). Replaced wholesale on File>Open /
    /// the launch load; mutated in place by edits (none yet in this gate).
    var drawing: CADDrawing

    /// The viewport transform. Pan/zoom mutate ONLY this (matrix-only; the f32
    /// instance buffers are never rebuilt for a view change — ADR-003).
    var viewport: Viewport

    /// The shared spatial index over entity AABBs (culling + snapping). Rebuilt
    /// when the model is replaced; incrementally updated on edits.
    @ObservationIgnored
    var quadtree = Quadtree()

    /// The current selection (toggled by click → hitTest).
    var selection = Selection()

    /// The latest snap result under the cursor (drives the snap marker overlay).
    var snap: SnapResult?

    /// The cursor's world position (for the coordinate HUD). `nil` when outside.
    var cursorWorld: Vector?

    /// The per-view f64 floating origin the f32 instance buffers are relative to
    /// (ADR-003). Chosen near the drawing centroid when a model loads so f32
    /// offsets stay small.
    @ObservationIgnored
    var renderOrigin: Vector = Vector(0, 0)

    /// Whether the GPU model buffer needs a rebuild (set on model replace/edit;
    /// cleared by the renderer after it rebuilds). View changes do NOT set this.
    @ObservationIgnored
    var modelDirty = true

    /// Bumped whenever the model is replaced, so the renderer (which holds a
    /// snapshot reference) can detect "new model" cheaply.
    @ObservationIgnored
    var modelVersion = 0

    /// Enabled snap modes (foundation default: the standard CAD set).
    @ObservationIgnored
    var snapModes: SnapMode = .standard

    // MARK: Derived (for the SwiftUI HUD)

    var entityCount: Int { drawing.count }

    // MARK: Init

    init(drawing: CADDrawing = CADDrawing(), viewSize: CGSize = CGSize(width: 800, height: 600)) {
        self.drawing = drawing
        self.viewport = Viewport(size: viewSize)
        rebuildIndex()
    }

    // MARK: - Model lifecycle

    /// Replaces the model with a freshly-loaded drawing, rebuilds the spatial
    /// index, chooses a floating origin near the content, and frames it (caller
    /// passes the current view size). Marks the GPU buffer dirty.
    func setDrawing(_ newDrawing: CADDrawing, viewSize: CGSize) {
        drawing = newDrawing
        rebuildIndex()
        let box = drawing.boundingBox()
        renderOrigin = RendererGeometry.renderOrigin(for: box)
        selection.clear()
        snap = nil
        // Frame the content on first paint (Viewport.fit handles empty/degenerate).
        viewport = Viewport.fit(box, in: viewSize)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Rebuilds the quadtree from the current drawing's per-entity AABBs.
    func rebuildIndex() {
        quadtree.removeAll()
        let box = drawing.boundingBox()
        if !box.isEmpty { quadtree.reserveWorld(box) }
        for e in drawing.entities {
            let b = e.boundingBox()
            if !b.isEmpty { quadtree.insert(e.id, bounds: b) }
        }
    }

    // MARK: - View changes (matrix-only)

    /// Updates the stored view size (on resize). Keeps the same world center/scale.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport.size = size
    }

    /// Frames the whole drawing in the current view (Zoom to Fit).
    func zoomToFit() {
        viewport = Viewport.fit(drawing.boundingBox(), in: viewport.size)
    }

    /// Pans by a screen-space delta (AppKit points, Y-down).
    func pan(byScreenDelta d: CGSize) {
        viewport.pan(byScreenDelta: d)
    }

    /// Zooms about a screen point (cursor). `factor > 1` zooms in.
    func zoom(by factor: Double, about screenPoint: CGPoint) {
        viewport.zoom(by: factor, about: screenPoint)
    }

    // MARK: - Interaction (snap + hit-test), CPU, f64, exact

    /// The pick/snap aperture in GUI points (LibreCAD `m_catchEntityGuiRange`).
    static let catchPoints: Double = 8

    /// Snap tolerance in world units for the current zoom.
    var worldTolerance: Double { Self.catchPoints * viewport.worldPerPixel }

    /// Runs snapping for a cursor screen point, updating `cursorWorld` + `snap`.
    /// Returns whether the snap result changed (so the caller can skip a redraw).
    @discardableResult
    func updateSnap(atScreenPoint screen: CGPoint, gridSpacing: Double?) -> Bool {
        let world = viewport.screenToWorld(screen)
        cursorWorld = world
        let result = Snapping.snap(
            worldPoint: world,
            modes: snapModes,
            worldTolerance: worldTolerance,
            gridSpacing: gridSpacing,
            in: drawing,
            using: quadtree
        )
        let changed = result != snap
        snap = result
        return changed
    }

    /// Click → hit-test the nearest entity and toggle it into the selection.
    /// Returns whether the selection changed.
    @discardableResult
    func toggleSelection(atScreenPoint screen: CGPoint) -> Bool {
        let world = viewport.screenToWorld(screen)
        let id = selection.hitTest(
            worldPoint: world,
            worldTolerance: worldTolerance,
            in: drawing,
            using: quadtree
        )
        guard let id else { return false }
        selection.toggle(id)
        return true
    }

    /// Clears the cursor/snap overlay (mouse left the view).
    func clearCursor() {
        cursorWorld = nil
        snap = nil
    }
}
