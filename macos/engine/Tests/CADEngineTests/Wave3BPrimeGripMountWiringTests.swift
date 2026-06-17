//
//  Wave3BPrimeGripMountWiringTests.swift
//  CADEngineTests
//
//  The Wave-3B′ MOUNT contract: the integration seam where `CADCanvasView`'s controller
//  builds an `EntityGripOverlayView` from the merged 3B `CanvasModel` grip API and
//  floats it over the canvas (the P0 grip-editing feature going live). The overlay's
//  own pure logic (`makeHandles` / `nearestHandle` / the drag→moveGrip math) is locked
//  by `EntityGripOverlayTests`, and the model's grip accessors (`gripSelectionRecords`
//  / `gripResolveContext` / `gripViewport` / `gripsEnabled` / `commitMovedGrip`) by
//  `Wave3BCanvasModelWiringTests`. This suite locks what 3B′ ADDS: that an overlay wired
//  to those EXACT model closures (the five the mount injects) drives an end-to-end grip
//  edit through the model — one undoable `.replace` — and that the enable value the mount
//  caches + feeds the overlay's `isEnabled` MIRRORS `model.gripsEnabled` across the
//  selection / tool / gizmo-drag states (the perf-nit cache must track the source).
//
//  The MTKView/Metal + the live AppKit drag are GUI-only (no headless surface), so this
//  exercises the mount's pure seam: build the overlay with the model's closures, then
//  reproduce the mount's mouse-up commit + isEnabled-from-gripsEnabled steps directly.
//  `CanvasModel` lives in the (un-importable) app target — reached via the existing
//  `_SharedCanvasModel.swift` / `_SharedEntityGripOverlay.swift` symlinks; `@MainActor`
//  mirrors the sibling wiring suites. No SwiftUI body / NSMenu / modal is rendered.
//
//  Uniquely namespaced (CONVENTIONS.md) so it never collides with the other suites in
//  the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("Wave-3B′ grip-overlay mount wiring (CADCanvasView ↔ CanvasModel)")
struct Wave3BPrimeGripMountWiringTests {

    // MARK: - Fixtures

    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0,
                      layer: String = "0") -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: LayerID(layer),
                     kind: .line(LineData(start: a, end: b)))
    }

    /// A model with one horizontal line, a clean manual-grouping undo stack, and a 1pt/
    /// unit viewport centered on the origin (so `worldToScreen(x,y) == (w/2+x, h/2−y)`).
    private func lineModel() -> (model: CanvasModel, id: EntityID) {
        let drawing = CADDrawing()
        let id = drawing.add(line(Vector(-50, 0), Vector(50, 0)))
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 200, height: 200))
        m.viewport = Viewport(scale: 1.0, center: Vector(0, 0),
                              size: CGSize(width: 200, height: 200))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return (m, id)
    }

    /// Builds the overlay EXACTLY as `CADCanvasController.attach` does — the five model
    /// closures the mount injects — and reports each `requestRedraw` invocation.
    private func mountedOverlay(
        _ m: CanvasModel,
        redraw: @escaping () -> Void = {}
    ) -> EntityGripOverlayView {
        EntityGripOverlayView(
            selectionProvider: { m.gripSelectionRecords },
            contextProvider: { m.gripResolveContext() },
            viewportProvider: { m.gripViewport() },
            onGripCommit: { m.commitMovedGrip($0) },
            requestRedraw: redraw)
    }

    // MARK: - The mount draws handles for the live selection

    @Test("an overlay wired to the model draws the selection's grips after refresh()")
    func overlayDrawsSelectionGrips() {
        let (m, id) = lineModel()
        let overlay = mountedOverlay(m)
        overlay.isEnabled = m.gripsEnabled    // nothing selected → false
        overlay.refresh()
        #expect(overlay.isHidden)             // no selection → no handles → hidden

        m.selection = Selection(ids: [id])
        overlay.isEnabled = m.gripsEnabled    // select mode + grip-editable line → true
        overlay.refresh()
        #expect(!overlay.isHidden)            // the line's grips are now drawn
        #expect(overlay.isActive)
    }

    // MARK: - End-to-end grip commit through the model's closures

    @Test("a grip drag routed through the mounted overlay's closures commits one undoable edit")
    func mountedGripDragCommitsUndoably() throws {
        let (m, id) = lineModel()
        m.selection = Selection(ids: [id])
        let overlay = mountedOverlay(m)
        overlay.isEnabled = m.gripsEnabled
        overlay.refresh()

        // Reproduce the overlay's mouse-up commit using its OWN pure pieces fed by the
        // model's closures (the AppKit drag has no headless surface). Grab the line's END
        // grip and drag it up 40 points → world (50, 40).
        let vp = m.gripViewport()
        let handles = EntityGripOverlayView.makeHandles(for: m.gripSelectionRecords,
                                                        ctx: m.gripResolveContext())
        let down = vp.worldToScreen(Vector(50, 0))           // the END grip's screen pos
        let i = try #require(EntityGripHitTest.nearestHandle(
            to: down, handles: handles, viewport: vp, slop: 8))
        let grabbed = handles[i]
        let upWorld = vp.screenToWorld(CGPoint(x: down.x, y: down.y - 40))
        let moved = try #require(EntityGrips.moveGrip(
            grabbed.gripIndex, of: grabbed.record, to: upWorld, ctx: m.gripResolveContext()))

        // The mount's commit funnel = the overlay's injected `onGripCommit` = model.commitMovedGrip.
        #expect(m.commitMovedGrip(moved))

        let after = try #require(m.drawing.entity(id))
        guard case .line(let l) = after.kind else { Issue.record("not a line"); return }
        #expect(abs(l.end.y - 40) < 1e-9)                    // dragged end followed the cursor
        #expect(l.start == Vector(-50, 0))                   // the other end stayed put

        m.undo()                                             // ONE ⌘Z reverts the grip drag
        let reverted = try #require(m.drawing.entity(id))
        guard case .line(let l2) = reverted.kind else { Issue.record("not a line"); return }
        #expect(l2.end == Vector(50, 0))
    }

    // MARK: - isEnabled mirrors gripsEnabled across the arbitration states (the cache contract)

    @Test("the cached enable value the mount feeds isEnabled tracks model.gripsEnabled")
    func enableCacheMirrorsGripsEnabled() {
        let (m, id) = lineModel()
        let overlay = mountedOverlay(m)

        // Empty selection → grips off → overlay disabled (mount caches gripsEnabled).
        var cache = m.gripsEnabled
        overlay.isEnabled = cache
        #expect(!cache)
        #expect(!overlay.isEnabled)

        // Select the grip-editable line → grips on.
        m.selection = Selection(ids: [id])
        cache = m.gripsEnabled
        overlay.isEnabled = cache
        #expect(cache)
        #expect(overlay.isEnabled)

        // A gizmo drag OWNS the gesture → grips suppressed (the dual-overlay arbitration).
        m.setGizmoPreview(.identity)
        cache = m.gripsEnabled
        overlay.isEnabled = cache
        #expect(!cache)
        #expect(!overlay.isEnabled)

        // Gizmo drag ends → grips return.
        m.clearGizmoPreview()
        cache = m.gripsEnabled
        overlay.isEnabled = cache
        #expect(cache)
        #expect(overlay.isEnabled)

        // A draw tool active → not select mode → grips off (tool owns the canvas).
        m.activateTool(.line)
        cache = m.gripsEnabled
        overlay.isEnabled = cache
        #expect(!cache)
        #expect(!overlay.isEnabled)
    }

    // MARK: - Escape cancels an in-progress grip drag without committing

    @Test("cancelActiveDrag (the mount's Esc path) drops a grip drag without committing")
    func escapeCancelsGripDragNoCommit() throws {
        let (m, id) = lineModel()
        m.selection = Selection(ids: [id])
        var commits = 0
        let overlay = EntityGripOverlayView(
            selectionProvider: { m.gripSelectionRecords },
            contextProvider: { m.gripResolveContext() },
            viewportProvider: { m.gripViewport() },
            onGripCommit: { record in commits += 1; m.commitMovedGrip(record) },
            requestRedraw: {})
        overlay.isEnabled = m.gripsEnabled
        overlay.refresh()

        // No drag in progress → cancel is a harmless no-op, never commits, never beeps.
        overlay.cancelActiveDrag()
        #expect(!overlay.isDragging)
        #expect(commits == 0)

        // The geometry is untouched and no undo step was pushed.
        let after = try #require(m.drawing.entity(id))
        guard case .line(let l) = after.kind else { Issue.record("not a line"); return }
        #expect(l.end == Vector(50, 0))
        #expect(!m.undoManager.canUndo)
    }
}
