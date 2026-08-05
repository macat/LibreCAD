//
//  CanvasModelDecompositionTests.swift
//  CADEngineTests — Wave 4 Phase 1
//
//  Proves the god-object decomposition: CanvasModel as a facade over
//  DocumentModel / ViewportModel / InteractionModel, while keeping the
//  existing public API stable. Headless, @MainActor, via _Shared symlinks.
//
//  GPLv2-or-later.
//

import Testing
import Foundation
import CoreGraphics
import CADEngine

// CanvasModel + decomposed slices are in the app target, reached via
// _SharedCanvasModel.swift / _SharedDocumentModel.swift etc. symlinks.
// The suite is @MainActor (all three models are @MainActor @Observable).

@Suite("Wave 4 Phase 1 — CanvasModel decomposition (facade + slices)")
@MainActor
struct CanvasModelDecompositionTests {

    // MARK: - Facade forwards

    @Test("facade: canvasModel.drawing is documentModel.drawing (single source)")
    func facadeDrawingSingleSource() {
        let m = CanvasModel()
        // Identity: the facade and the slice share the same CADDrawing instance.
        #expect(m.drawing === m.documentModel.drawing)
        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let id = m.drawing.add(rec)
        #expect(m.documentModel.drawing.contains(id))
        // Mutating via documentModel is visible via canvasModel.
        let countViaFacade = m.drawing.count
        let countViaSlice = m.documentModel.drawing.count
        #expect(countViaFacade == countViaSlice)
    }

    @Test("facade: canvasModel.viewport is viewportModel.viewport")
    func facadeViewport() {
        let m = CanvasModel(viewSize: CGSize(width: 800, height: 600))
        let originalCenter = m.viewport.center
        // Mutate via facade, read via slice.
        m.viewport.center = Vector(42, 7)
        #expect(m.viewportModel.viewport.center == Vector(42, 7))
        #expect(m.viewport.center == Vector(42, 7))
        // Mutate via slice, read via facade.
        m.viewportModel.viewport.center = originalCenter
        #expect(m.viewport.center == originalCenter)
    }

    @Test("facade: canvasModel.quadtree is viewportModel.quadtree (reference)")
    func facadeQuadtree() {
        let m = CanvasModel()
        #expect(m.quadtree === m.viewportModel.quadtree)
        // Insert via canvasModel is visible via viewportModel.
        let id = EntityID(999)
        m.quadtree.insert(id, bounds: AABB(min: Vector(0, 0), max: Vector(1, 1)))
        #expect(m.viewportModel.quadtree.query(region: AABB(min: Vector(-1, -1), max: Vector(2, 2))).contains(id))
        m.quadtree.remove(id)
        #expect(!m.viewportModel.quadtree.query(region: AABB(min: Vector(-1, -1), max: Vector(2, 2))).contains(id))
    }

    @Test("facade: canvasModel.selection is interactionModel.selection")
    func facadeSelection() {
        let m = CanvasModel()
        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let id = m.drawing.add(rec)
        m.quadtree.insert(id, bounds: rec.boundingBox())
        m.selection = Selection(ids: [id])
        #expect(m.interactionModel.selection.contains(id))
        #expect(m.hasSelection == m.interactionModel.hasSelection)
        m.interactionModel.selection.clear()
        #expect(m.selection.isEmpty)
    }

    @Test("facade: canvasModel.snap and cursorWorld are interactionModel.snap/cursorWorld")
    func facadeSnapCursor() {
        let m = CanvasModel()
        let snap = SnapResult(point: Vector(5, 5), kind: .endpoint, entity: nil)
        m.snap = snap
        m.cursorWorld = Vector(5, 5)
        #expect(m.interactionModel.snap == snap)
        #expect(m.interactionModel.cursorWorld == Vector(5, 5))
        m.interactionModel.snap = nil
        m.interactionModel.cursorWorld = nil
        #expect(m.snap == nil)
        #expect(m.cursorWorld == nil)
    }

    @Test("facade: canvasModel.modelVersion and modelDirty are documentModel")
    func facadeVersionDirty() {
        let m = CanvasModel()
        let v0 = m.modelVersion
        m.modelVersion &+= 1
        #expect(m.documentModel.modelVersion == v0 + 1)
        #expect(m.modelVersion == m.documentModel.modelVersion)
        m.modelDirty = true
        #expect(m.documentModel.modelDirty == true)
        m.documentModel.modelDirty = false
        #expect(m.modelDirty == false)
    }

    @Test("facade: canvasModel.undoManager is documentModel.undoManager")
    func facadeUndoManager() {
        let m = CanvasModel()
        #expect(m.undoManager === m.documentModel.undoManager)
        let other = UndoManager()
        m.adoptUndoManager(other)
        #expect(m.undoManager === other)
        #expect(m.documentModel.undoManager === other)
    }

    @Test("facade: canvasModel.renderOrigin is viewportModel.renderOrigin")
    func facadeRenderOrigin() {
        let m = CanvasModel()
        m.renderOrigin = Vector(100, 200)
        #expect(m.viewportModel.renderOrigin == Vector(100, 200))
        m.viewportModel.renderOrigin = Vector(0, 0)
        #expect(m.renderOrigin == Vector(0, 0))
    }

    @Test("facade: activeToolKind/tool/toolStatus forward to interactionModel")
    func facadeTool() {
        let m = CanvasModel()
        m.activateTool(.line)
        #expect(m.activeToolKind == .line)
        #expect(m.interactionModel.activeToolKind == .line)
        #expect(m.tool != nil)
        #expect(m.interactionModel.tool != nil)
        #expect(m.toolStatus == m.interactionModel.toolStatus)
        m.activateTool(.select)
        #expect(m.activeToolKind == .select)
        #expect(m.interactionModel.activeToolKind == .select)
    }

    // MARK: - DocumentModel: drawing mutations + undo

    @Test("DocumentModel: add is undoable and bumps modelVersion/modelDirty")
    func documentModelUndo() {
        let doc = DocumentModel()
        let v0 = doc.modelVersion
        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let id = doc.add(rec)
        #expect(doc.drawing.contains(id))
        #expect(doc.modelVersion == v0 + 1)
        #expect(doc.modelDirty == true)
        #expect(doc.canUndo)
        doc.undoManager.undo()
        #expect(!doc.drawing.contains(id))
        #expect(doc.undoManager.canRedo)
        doc.undoManager.redo()
        #expect(doc.drawing.contains(id))
    }

    @Test("DocumentModel: modelVersion and drawing count stay coherent via CanvasModel facade")
    func documentModelViaFacadeUndo() {
        let m = CanvasModel()
        let baseCount = m.entityCount
        let baseVersion = m.modelVersion
        // Use CanvasModel's undoable path (applyCommit via tool) vs direct doc mutation.
        // Here we directly mutate via documentModel's funnel and verify facade version.
        let rec = EntityRecord(id: .placeholder, kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let id = m.documentModel.add(rec)
        #expect(m.entityCount == baseCount + 1)
        #expect(m.modelVersion == baseVersion + 1)
        #expect(m.canUndo)
        m.undo()
        #expect(m.entityCount == baseCount)
        // After undo, the facade's drawing should also reflect the undo.
        #expect(!m.drawing.contains(id))
        #expect(m.documentModel.drawing.count == baseCount)
    }

    // MARK: - ViewportModel: matrix-only pan/zoom

    @Test("ViewportModel: pan shifts center by -delta/scale")
    func viewportModelPan() {
        let vm = ViewportModel(viewport: Viewport(scale: 2.0, center: Vector(0, 0), size: CGSize(width: 800, height: 600)))
        let before = vm.viewport.center
        vm.pan(byScreenDelta: CGSize(width: 20, height: 10))
        // pan(byScreenDelta:) moves center by -d/scale, Y un-flipped.
        let expected = Vector(before.x - 20.0 / 2.0, before.y + 10.0 / 2.0)
        #expect(abs(vm.viewport.center.x - expected.x) < 1e-9)
        #expect(abs(vm.viewport.center.y - expected.y) < 1e-9)
        // Quadtree/renderOrigin are untouched by a pan (matrix-only).
        #expect(vm.quadtree.query(region: AABB(min: Vector(-1e9, -1e9), max: Vector(1e9, 1e9))).isEmpty)
    }

    @Test("ViewportModel: zoom about cursor keeps anchor world point stable")
    func viewportModelZoom() {
        var vp = Viewport(scale: 1.0, center: Vector(0, 0), size: CGSize(width: 800, height: 600))
        let cursor = CGPoint(x: 400, y: 300) // view center
        let anchorBefore = vp.screenToWorld(cursor)
        let vm = ViewportModel(viewport: vp)
        vm.zoom(by: 2.0, about: cursor)
        let anchorAfter = vm.viewport.screenToWorld(cursor)
        #expect(abs(anchorBefore.x - anchorAfter.x) < 1e-9)
        #expect(abs(anchorBefore.y - anchorAfter.y) < 1e-9)
        #expect(abs(vm.viewport.scale - 2.0) < 1e-9)
    }

    @Test("ViewportModel: setViewSize keeps center and scale, changes size")
    func viewportModelSetViewSize() {
        let vm = ViewportModel(viewport: Viewport(scale: 1.5, center: Vector(10, 20), size: CGSize(width: 800, height: 600)))
        let beforeCenter = vm.viewport.center
        let beforeScale = vm.viewport.scale
        vm.setViewSize(CGSize(width: 1024, height: 768))
        #expect(vm.viewport.size == CGSize(width: 1024, height: 768))
        #expect(vm.viewport.center == beforeCenter)
        #expect(vm.viewport.scale == beforeScale)
    }

    @Test("ViewportModel: visibleIDs culls via quadtree against visibleWorldRect")
    func viewportModelCulling() {
        let vm = ViewportModel(viewport: Viewport(scale: 1.0, center: Vector(0, 0), size: CGSize(width: 100, height: 100)))
        let ctx = ResolveContext.default
        let e1 = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let e2 = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(1000, 1000), end: Vector(1010, 1000))))
        vm.rebuildIndex(with: [e1, e2], context: ctx)
        let visible = Set(vm.visibleIDs())
        #expect(visible.contains(EntityID(1)))
        #expect(!visible.contains(EntityID(2)))
    }

    @Test("ViewportModel: zoomPrevious restores prior viewport")
    func viewportModelZoomPrevious() {
        let vm = ViewportModel(viewport: Viewport(scale: 1.0, center: Vector(0, 0), size: CGSize(width: 800, height: 600)))
        let original = vm.viewport
        vm.pushHistory()
        vm.zoom(by: 2.0, about: CGPoint(x: 400, y: 300))
        #expect(vm.viewport.scale != original.scale)
        #expect(vm.canZoomPrevious)
        let ok = vm.zoomPrevious()
        #expect(ok)
        #expect(vm.viewport == original)
        #expect(!vm.canZoomPrevious)
    }

    // MARK: - InteractionModel: selection + snap

    @Test("InteractionModel: selection toggle via hitTest")
    func interactionModelSelection() {
        let doc = DocumentModel()
        let vp = ViewportModel(viewport: Viewport(scale: 10, center: Vector(5, 0), size: CGSize(width: 800, height: 600)))
        let inter = InteractionModel(document: doc, viewport: vp)
        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let id = doc.add(rec)
        vp.rebuildIndex(with: doc.drawing.entities, context: doc.drawing.makeResolveContext())
        #expect(inter.selection.isEmpty)
        // Hit near the line's midpoint (world 5,0) should find it.
        let hit = inter.hitTest(at: Vector(5, 0))
        #expect(hit == id)
        inter.selection.toggle(id)
        #expect(inter.selection.contains(id))
        inter.selection.toggle(id)
        #expect(!inter.selection.contains(id))
    }

    @Test("InteractionModel: snap updates cursorWorld and snap")
    func interactionModelSnap() {
        let doc = DocumentModel()
        let vp = ViewportModel(viewport: Viewport(scale: 10, center: Vector(0, 0), size: CGSize(width: 800, height: 600)))
        let inter = InteractionModel(document: doc, viewport: vp)
        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        _ = doc.add(rec)
        vp.rebuildIndex(with: doc.drawing.entities, context: doc.drawing.makeResolveContext())
        let screen = vp.viewport.worldToScreen(Vector(0, 0))
        let changed = inter.updateSnap(atScreenPoint: screen, gridSpacing: nil, snapModes: [.endpoint, .free])
        // At world origin (endpoint of line), snap should be endpoint or free, cursorWorld set.
        #expect(inter.cursorWorld != nil)
        _ = changed // snap may be endpoint; we just verify the model updated.
        #expect(inter.snap != nil)
        inter.clearCursor()
        #expect(inter.cursorWorld == nil)
        #expect(inter.snap == nil)
    }

    @Test("InteractionModel: tool activation routing")
    func interactionModelToolRouting() {
        let doc = DocumentModel()
        let vp = ViewportModel()
        let inter = InteractionModel(document: doc, viewport: vp)
        #expect(inter.activeToolKind == .select)
        #expect(inter.tool == nil)
        inter.activateTool(.circle)
        #expect(inter.activeToolKind == .circle)
        #expect(inter.tool != nil)
        #expect(!inter.toolStatus.isEmpty)
        inter.activateTool(.select)
        #expect(inter.activeToolKind == .select)
        #expect(inter.tool == nil)
    }

    @Test("InteractionModel depends on DocumentModel + ViewportModel via injection")
    func interactionModelInjection() {
        let doc = DocumentModel()
        let vp = ViewportModel()
        let inter = InteractionModel(document: doc, viewport: vp)
        // After injecting, a drawing mutation in doc is visible to inter's hitTest.
        // Circle center distance is radius (10) > tolerance, so hit the perimeter.
        let rec = EntityRecord(id: .placeholder, kind: .circle(CircleData(center: Vector(100, 100), radius: 10)))
        let id = doc.add(rec)
        vp.rebuildIndex(with: doc.drawing.entities, context: doc.drawing.makeResolveContext())
        let hit = inter.hitTest(at: Vector(110, 100))
        #expect(hit == id)
    }

    // MARK: - Render origin & quadtree still together in ViewportModel

    @Test("ViewportModel owns renderOrigin, separate from document")
    func viewportRenderOrigin() {
        let vm = ViewportModel()
        vm.renderOrigin = Vector(123, 456)
        #expect(vm.renderOrigin == Vector(123, 456))
        // Changing document doesn't affect renderOrigin (decoupled).
        let doc = DocumentModel()
        let rec = EntityRecord(id: .placeholder, kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
        _ = doc.add(rec)
        #expect(vm.renderOrigin == Vector(123, 456))
    }
}
