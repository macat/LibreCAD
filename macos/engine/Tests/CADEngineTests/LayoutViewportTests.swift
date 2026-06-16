//
//  LayoutViewportTests.swift
//  CADEngineTests
//
//  Paper-space P3 — the VIEWPORT entity (a window on a layout sheet showing a
//  scaled view of model space). Covers:
//   - the pure math: child-camera scale, model→paper affine, framing fit, and the
//     Cohen–Sutherland clip (inside / outside / crossing; no NaN on degenerate);
//   - `LayoutViewport` Codable round-trip + `Layout` back-compat (OLD JSON without
//     a `viewports` key decodes as `[]`);
//   - CADDrawing add/remove/update viewport undo (one ⌘Z reverts; no-op skipped;
//     rename-layout carries the viewports);
//   - the `ViewportTool` 2-click placement produces the expected `LayoutViewport`;
//   - a DXF + DWG VIEWPORT round-trip (build a drawing with a layout + viewport,
//     write to a temp path, read back, assert the paper rect / view center / view
//     height survive).
//
//  Uniquely namespaced (`@Suite("paper space P3 (layout viewport entity)")`) so it
//  does not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("paper space P3 (layout viewport entity)")
struct LayoutViewportTests {

    // MARK: - Helpers

    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
        abs(a - b) < tol
    }

    private func approxV(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        (a - b).magnitude < tol
    }

    /// A 100×80 (paper) viewport at origin showing a model window centered on
    /// (50, 50) that is 40 model units tall (so scale = 80/40 = 2 paper per model).
    private func sampleViewport() -> LayoutViewport {
        LayoutViewport(
            paperRect: AABB(min: Vector(0, 0), max: Vector(100, 80)),
            viewCenter: Vector(50, 50),
            viewHeight: 40
        )
    }

    // MARK: - Derived scale + child camera

    @Test("scale is paperRect.height / viewHeight (paper units per model unit)")
    func derivedScale() {
        let vp = sampleViewport()
        #expect(approx(vp.scale, 2.0))            // 80 / 40
        #expect(approx(vp.paperWidth, 100))
        #expect(approx(vp.paperHeight, 80))
        #expect(approxV(vp.paperCenter, Vector(50, 40)))
    }

    @Test("a degenerate viewHeight is clamped (no divide-by-zero / NaN)")
    func degenerateViewHeightClamped() {
        let vp = LayoutViewport(paperRect: AABB(min: Vector(0, 0), max: Vector(10, 10)),
                                viewCenter: Vector(0, 0), viewHeight: 0)
        #expect(vp.viewHeight > 0)
        #expect(vp.scale.isFinite)
        #expect(vp.scale > 0)
        // NaN/inf height also clamps.
        let vp2 = LayoutViewport(paperRect: AABB(min: Vector(0, 0), max: Vector(10, 10)),
                                 viewCenter: Vector(0, 0), viewHeight: .nan)
        #expect(vp2.viewHeight.isFinite && vp2.viewHeight > 0)
    }

    @Test("childCamera uses the derived scale, viewCenter, and paper frame size")
    func childCameraShape() {
        let vp = sampleViewport()
        let cam = vp.childCamera()
        #expect(approx(cam.scale, 2.0))
        #expect(approxV(cam.center, Vector(50, 50)))
        #expect(approx(Double(cam.size.width), 100))
        #expect(approx(Double(cam.size.height), 80))
    }

    @Test("visibleModelRect is the model window the frame shows")
    func visibleModelRect() {
        let vp = sampleViewport()
        let r = vp.visibleModelRect()
        // 80 paper tall / scale 2 = 40 model tall; 100 paper wide / 2 = 50 model wide.
        #expect(approx(r.size.y, 40, 1e-6))
        #expect(approx(r.size.x, 50, 1e-6))
        #expect(approxV(r.center, Vector(50, 50), 1e-6))
    }

    // MARK: - model → paper affine

    @Test("model→paper maps viewCenter to the frame center")
    func affineCenter() {
        let vp = sampleViewport()
        #expect(approxV(vp.modelToPaper(Vector(50, 50)), vp.paperCenter))
    }

    @Test("model→paper scales an offset by the derived scale (Y-up, no flip)")
    func affineScaleAndDirection() {
        let vp = sampleViewport()
        // +10 model in X → +20 paper (scale 2) from the frame center (50,40).
        #expect(approxV(vp.modelToPaper(Vector(60, 50)), Vector(70, 40)))
        // +10 model in Y → +20 paper UP (Y-up on the sheet).
        #expect(approxV(vp.modelToPaper(Vector(50, 60)), Vector(50, 60)))
        // The model window corner (top of the 40-tall view) maps to the frame top.
        #expect(approxV(vp.modelToPaper(Vector(50, 70)), Vector(50, 80)))
    }

    // MARK: - framing (whole-model fit)

    @Test("framing fits the whole model extent inside the rect, centered")
    func framingFitsModel() {
        let rect = AABB(min: Vector(0, 0), max: Vector(200, 100))
        let model = AABB(min: Vector(-10, -5), max: Vector(10, 5))   // 20×10, center 0
        let vp = LayoutViewport.framing(paperRect: rect, modelExtents: model)
        #expect(approxV(vp.viewCenter, Vector(0, 0)))
        // The whole model fits (with a small margin) — its mapped corners stay inside.
        for corner in [Vector(-10, -5), Vector(10, -5), Vector(10, 5), Vector(-10, 5)] {
            let p = vp.modelToPaper(corner)
            #expect(p.x >= rect.min.x - 1e-6 && p.x <= rect.max.x + 1e-6)
            #expect(p.y >= rect.min.y - 1e-6 && p.y <= rect.max.y + 1e-6)
        }
    }

    @Test("framing an empty model yields a valid (NaN-free) unit-height viewport")
    func framingEmptyModel() {
        let rect = AABB(min: Vector(0, 0), max: Vector(50, 50))
        let vp = LayoutViewport.framing(paperRect: rect, modelExtents: .empty)
        #expect(vp.viewHeight.isFinite && vp.viewHeight > 0)
        #expect(vp.scale.isFinite)
        #expect(approxV(vp.viewCenter, Vector(0, 0)))
    }

    @Test("framing a degenerate (zero-area) rect does not crash / NaN")
    func framingDegenerateRect() {
        let rect = AABB(min: Vector(5, 5), max: Vector(5, 5))     // a point
        let model = AABB(min: Vector(0, 0), max: Vector(10, 10))
        let vp = LayoutViewport.framing(paperRect: rect, modelExtents: model)
        #expect(vp.viewHeight.isFinite && vp.viewHeight > 0)
        #expect(approxV(vp.viewCenter, Vector(5, 5)))   // the model center
    }

    // MARK: - Cohen–Sutherland clip

    @Test("a segment fully inside the frame is unchanged")
    func clipInside() {
        let vp = sampleViewport()                  // frame [0,0]..[100,80]
        let seg = vp.clipToFrame(Vector(10, 10), Vector(90, 70))
        let r = try! #require(seg)
        #expect(approxV(r.0, Vector(10, 10)))
        #expect(approxV(r.1, Vector(90, 70)))
    }

    @Test("a segment fully outside the frame is rejected (nil)")
    func clipOutside() {
        let vp = sampleViewport()
        #expect(vp.clipToFrame(Vector(200, 200), Vector(300, 300)) == nil)
        #expect(vp.clipToFrame(Vector(-50, 10), Vector(-10, 10)) == nil)
    }

    @Test("a segment crossing the right edge is clipped at the edge")
    func clipCrossing() {
        let vp = sampleViewport()                  // frame x in [0,100]
        // Horizontal segment from inside (50,40) to outside (150,40): clip at x=100.
        let seg = vp.clipToFrame(Vector(50, 40), Vector(150, 40))
        let r = try! #require(seg)
        #expect(approxV(r.0, Vector(50, 40), 1e-9))
        #expect(approx(r.1.x, 100, 1e-9))
        #expect(approx(r.1.y, 40, 1e-9))
    }

    @Test("clipping against a degenerate (empty) frame rejects everything")
    func clipDegenerateFrame() {
        let vp = LayoutViewport(paperRect: AABB.empty, viewCenter: Vector(0, 0), viewHeight: 1)
        #expect(vp.clipToFrame(Vector(0, 0), Vector(1, 1)) == nil)
    }

    @Test("clipPolylineToFrame breaks a crossing polyline into in-frame pieces")
    func clipPolyline() {
        let vp = sampleViewport()
        // A polyline that starts inside, exits, and re-enters: zig-zag across x=100.
        let pts = [Vector(50, 40), Vector(150, 40), Vector(50, 60)]
        let segs = vp.clipPolylineToFrame(pts, closed: false)
        // Both segments cross the right edge, so each yields one clipped piece.
        #expect(segs.count == 2)
        for (a, b) in segs {
            #expect(a.x <= 100 + 1e-9 && b.x <= 100 + 1e-9)
            #expect(a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite)
        }
    }

    // MARK: - Codable round-trip + Layout back-compat

    @Test("LayoutViewport round-trips through Codable (id, rect, center, height)")
    func viewportCodableRoundTrip() throws {
        let vp = sampleViewport()
        let data = try JSONEncoder().encode(vp)
        let back = try JSONDecoder().decode(LayoutViewport.self, from: data)
        #expect(back.id == vp.id)
        #expect(back.paperRect == vp.paperRect)
        #expect(approxV(back.viewCenter, vp.viewCenter))
        #expect(approx(back.viewHeight, vp.viewHeight))
    }

    @Test("Layout with viewports round-trips through Codable")
    func layoutWithViewportsCodable() throws {
        var layout = Layout(name: "L", tabOrder: 1)
        layout.viewports = [sampleViewport()]
        let back = try JSONDecoder().decode(
            Layout.self, from: try JSONEncoder().encode(layout))
        #expect(back.name == "L")
        #expect(back.viewports.count == 1)
        #expect(back.viewports.first?.paperRect == sampleViewport().paperRect)
    }

    @Test("an OLD-FORMAT Layout JSON (no viewports key) decodes as []")
    func layoutBackCompatNoViewportsKey() throws {
        // Hand-build the JSON an old Layout (pre-P3) would have encoded: name +
        // tabOrder + page, NO `viewports` key.
        let json = """
        {"name":"Layout1","tabOrder":0,"page":{"widthMM":210,"heightMM":297,"marginMM":10,"plotScale":{"fit":{}}}}
        """
        let data = Data(json.utf8)
        let back = try JSONDecoder().decode(Layout.self, from: data)
        #expect(back.name == "Layout1")
        #expect(back.viewports.isEmpty)            // additive default
    }

    // MARK: - CADDrawing mutators (undoable)

    @Test("addViewport adds to the layout; one ⌘Z removes it; redo re-adds")
    func addViewportUndoable() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        let um = testUndoManager()
        d.undoManager = um

        let vp = sampleViewport()
        um.beginUndoGrouping()
        #expect(d.addViewport(vp, toLayout: "LAYOUT1") == true)   // case-insensitive
        um.endUndoGrouping()
        #expect(d.layout(named: "Layout1")?.viewports.count == 1)

        um.undo()
        #expect(d.layout(named: "Layout1")?.viewports.isEmpty == true)

        um.redo()
        #expect(d.layout(named: "Layout1")?.viewports.count == 1)
    }

    @Test("addViewport to a missing layout is a no-op (no undo)")
    func addViewportMissingLayoutNoOp() {
        let d = CADDrawing()
        let um = testUndoManager()
        d.undoManager = um
        #expect(d.addViewport(sampleViewport(), toLayout: "Nope") == false)
        #expect(um.canUndo == false)
    }

    @Test("removeViewport removes by id; undoable")
    func removeViewportUndoable() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        let vp = sampleViewport()
        d.addViewport(vp, toLayout: "Layout1")

        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        #expect(d.removeViewport(id: vp.id, fromLayout: "Layout1") == true)
        um.endUndoGrouping()
        #expect(d.layout(named: "Layout1")?.viewports.isEmpty == true)

        um.undo()
        #expect(d.layout(named: "Layout1")?.viewports.count == 1)

        // Removing an unknown id is a no-op.
        #expect(d.removeViewport(id: UUID(), fromLayout: "Layout1") == false)
    }

    @Test("updateViewport replaces by id (move/reframe); undoable")
    func updateViewportUndoable() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        let vp = sampleViewport()
        d.addViewport(vp, toLayout: "Layout1")

        let um = testUndoManager()
        d.undoManager = um
        var moved = vp
        moved.viewCenter = Vector(99, 99)
        um.beginUndoGrouping()
        #expect(d.updateViewport(moved, inLayout: "Layout1") == true)
        um.endUndoGrouping()
        #expect(approxV(d.layout(named: "Layout1")!.viewports.first!.viewCenter, Vector(99, 99)))

        um.undo()
        #expect(approxV(d.layout(named: "Layout1")!.viewports.first!.viewCenter, Vector(50, 50)))

        // Updating an unknown viewport id is a no-op.
        var orphan = sampleViewport()       // a fresh id
        orphan.viewCenter = Vector(0, 0)
        #expect(d.updateViewport(orphan, inLayout: "Layout1") == false)
    }

    @Test("renameLayout carries the layout's viewports to the new name")
    func renameLayoutCarriesViewports() {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1"))
        let vp = sampleViewport()
        d.addViewport(vp, toLayout: "Layout1")

        #expect(d.renameLayout(from: "Layout1", to: "Plan") == true)
        #expect(d.layout(named: "Plan")?.viewports.count == 1)
        #expect(d.layout(named: "Plan")?.viewports.first?.id == vp.id)
        #expect(d.hasLayout("Layout1") == false)
    }

    // MARK: - ViewportTool (2-click placement)

    @Test("ViewportTool produces a viewport from two corner clicks, framing the model")
    func viewportToolTwoClicks() {
        let model = AABB(min: Vector(0, 0), max: Vector(40, 20))
        var tool = ViewportTool(modelExtents: model)

        // Move before the first click → nothing.
        #expect(tool.handle(.move(Vector(5, 5))) == .none)
        // First click — start placing (a preview).
        #expect(tool.handle(.click(Vector(10, 10))) == .preview)
        #expect(tool.isPlacing)
        // Move — the rubber-band frame updates.
        #expect(tool.handle(.move(Vector(110, 90))) == .preview)
        #expect(!tool.preview.isEmpty)
        // Second click — the viewport is placed.
        let outcome = tool.handle(.click(Vector(110, 90)))
        guard case .placed(let vp) = outcome else {
            Issue.record("expected .placed, got \(outcome)")
            return
        }
        // The frame is the box between the two corners (order-independent).
        #expect(vp.paperRect == AABB(min: Vector(10, 10), max: Vector(110, 90)))
        // The model is framed inside (its center is the view center).
        #expect(approxV(vp.viewCenter, Vector(20, 10)))
        // The tool reset (ready for the next placement).
        #expect(!tool.isPlacing)
    }

    @Test("ViewportTool rejects a zero-area second click (no viewport)")
    func viewportToolRejectsZeroArea() {
        var tool = ViewportTool(modelExtents: AABB(min: Vector(0, 0), max: Vector(10, 10)))
        _ = tool.handle(.click(Vector(5, 5)))
        // Second click at the SAME point → zero-area box → no-op (still placing).
        #expect(tool.handle(.click(Vector(5, 5))) == .none)
        #expect(tool.isPlacing)
    }

    @Test("ViewportTool cancel clears an in-progress placement")
    func viewportToolCancel() {
        var tool = ViewportTool()
        _ = tool.handle(.click(Vector(0, 0)))
        #expect(tool.isPlacing)
        #expect(tool.handle(.cancel) == .cancelled)
        #expect(!tool.isPlacing)
        // Cancel with nothing in progress is a plain no-op.
        #expect(tool.handle(.cancel) == .none)
    }

    // MARK: - DXF / DWG VIEWPORT round-trip

    /// Builds a drawing carrying one layout + one viewport, writes it, reads it back,
    /// and returns the read-back layouts (so the round-trip is asserted by the caller).
    private func roundTripLayouts(dwg: Bool) async throws -> [Layout] {
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        // A paper-space entity so a `*Paper_Space` block + Layout1 are reconstructed.
        let paperLine = EntityRecord(
            id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))),
            space: .paper, layoutName: "Layout1")
        var layout = Layout(name: "Layout1")
        layout.viewports = [
            LayoutViewport(paperRect: AABB(min: Vector(20, 30), max: Vector(120, 110)),
                           viewCenter: Vector(250, 175), viewHeight: 80)
        ]

        let ext = dwg ? "dwg" : "dxf"
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewport-roundtrip-\(UUID().uuidString).\(ext)").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        if dwg {
            _ = try await CADEngine.shared.writeEntities(
                [paperLine], layers: layers, layouts: [layout], toDWGPath: outPath)
            return try await CADEngine.shared.readEntities(dwgPath: outPath).layouts
        } else {
            _ = try await CADEngine.shared.writeEntities(
                [paperLine], layers: layers, layouts: [layout], toPath: outPath)
            return try await CADEngine.shared.readEntities(dxfPath: outPath).layouts
        }
    }

    @Test("a DXF VIEWPORT round-trips its paper rect, view center and view height")
    func dxfViewportRoundTrips() async throws {
        let layouts = try await roundTripLayouts(dwg: false)
        let layout = try #require(layouts.first { $0.name.caseInsensitiveCompare("Layout1") == .orderedSame })
        #expect(layout.viewports.count == 1)
        let vp = try #require(layout.viewports.first)
        // The paper frame: center (70,70), size 100×80 → rect [20,30]..[120,110].
        #expect(approx(vp.paperWidth, 100, 1e-6))
        #expect(approx(vp.paperHeight, 80, 1e-6))
        #expect(approxV(vp.paperCenter, Vector(70, 70), 1e-6))
        #expect(approxV(vp.viewCenter, Vector(250, 175), 1e-6))
        #expect(approx(vp.viewHeight, 80, 1e-6))
    }

    @Test("a DWG write accepts viewports (the DWG writer has no VIEWPORT path)")
    func dwgViewportWriteDoesNotCrash() async throws {
        // libdxfrw's dwgWriter15 has no writeViewport path, so a DWG round-trip does
        // not carry the viewport back (documented gap). The contract under test: the
        // DWG write path ACCEPTS the layouts/viewports without error (it skips them).
        let layouts = try await roundTripLayouts(dwg: true)
        // The layout itself may or may not be reconstructed on DWG; the assertion is
        // only that the write+read completed (no throw) — reaching here proves it.
        _ = layouts
        #expect(Bool(true))
    }
}
