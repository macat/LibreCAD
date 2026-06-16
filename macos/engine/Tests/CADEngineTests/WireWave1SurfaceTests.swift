//
//  WireWave1SurfaceTests.swift
//  CADEngineTests
//
//  Wire-wave-1 (paper-space + draw-variant) UI surfacing. These guard the WIRING
//  the wave adds — the model-layer plumbing the options bar / menus / canvas dispatch
//  rely on — over the EXISTING `_SharedCanvasModel.swift` symlink (the app module's
//  `CanvasModel.swift`, compiled into this test target via the `_Shared*` convention).
//  Three concerns, none touching a modal (`NSSavePanel`/`NSPrintOperation` live in the
//  View layer only — never reached here):
//
//   1. Draw-variant MODES via `CanvasModel.applyToolConfig`: the options bar sets the
//      circle construction mode / arc creation mode / line angle mode on the model;
//      activating (or re-applying to) the matching tool must mint the tool in that
//      mode. Defaults must preserve the original behavior (centerRadius / centerStartEnd
//      / free).
//
//   2. Paper-space VIEWPORT placement (the out-of-band `ViewportTool` flow): in a
//      layout tab, a 2-click drag must add ONE `LayoutViewport` to the active layout,
//      framing the model; in MODEL space the same activation is an inert no-op.
//
//   3. The per-LAYOUT export SCENE filter (`CanvasModel.layoutExportScene`): the PURE
//      scene the Export/Print Layout closures build must contain ONLY the active
//      layout's paper-space records (model + other-layout records excluded).
//
//  Uniquely namespaced (`@Suite("wire-wave-1 ...")`) so it does not collide with the
//  other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("wire-wave-1 (draw-variant modes + paper-space viewport + layout-plot scene)")
struct WireWave1SurfaceTests {

    // MARK: - Fixtures

    /// A model-space line spanning roughly (0,0)…(40,30) so the model extents are a
    /// non-degenerate box the viewport tool can frame.
    private func modelLine(_ id: UInt64) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(40, 30))))
    }

    /// A paper-space line bound to `layout`.
    private func paperLine(_ id: UInt64, on layout: String) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .line(LineData(start: Vector(5, 5), end: Vector(50, 5))),
                     space: .paper, layoutName: layout)
    }

    /// A drawing with one model line + one layout ("Layout1") carrying a paper line.
    private func drawingWithLayout(_ name: String = "Layout1") -> CADDrawing {
        let d = CADDrawing()
        _ = d.add(modelLine(1))
        _ = d.addLayout(Layout(name: name, tabOrder: 0, page: PageDescriptor()))
        _ = d.add(paperLine(2, on: name))
        return d
    }

    // MARK: - 1) Draw-variant MODES via applyToolConfig

    @Test("Circle: default construction mode is centerRadius (back-compatible)")
    func circleDefaultModeIsCenterRadius() {
        let model = CanvasModel(drawing: CADDrawing())
        model.activateTool(.circle)
        let tool = model.tool as? CircleTool
        #expect(tool != nil, "activating .circle must mint a CircleTool")
        #expect(tool?.mode == .centerRadius, "default circle mode must be centerRadius")
    }

    @Test("Circle: options-bar construction mode is pushed onto the live tool")
    func circleConstructionModeFlowsToTool() {
        let model = CanvasModel(drawing: CADDrawing())
        model.circleConstructionMode = .threePoint
        model.activateTool(.circle)
        #expect((model.tool as? CircleTool)?.mode == .threePoint,
                "the options-bar circle construction mode must reach the minted tool")

        // Re-applying while active (the options-bar onChange path) re-mints in the mode.
        model.circleConstructionMode = .twoPoint
        model.reapplyActiveToolConfig()
        #expect((model.tool as? CircleTool)?.mode == .twoPoint,
                "changing the mode while active must re-mint the CircleTool in that mode")
    }

    @Test("Circle: size mode + fixed size still apply on the centerRadius path")
    func circleSizeOptionsStillApply() {
        let model = CanvasModel(drawing: CADDrawing())
        model.circleConstructionMode = .centerRadius
        model.circleSizeMode = .diameter
        model.circleFixedSize = 50
        model.activateTool(.circle)
        let tool = model.tool as? CircleTool
        #expect(tool?.sizeMode == .diameter)
        #expect(tool?.fixedSize == 50, "a positive fixed size must be pushed onto the tool")
        // A zero fixed size means "unset" (drag the radius).
        model.circleFixedSize = 0
        model.reapplyActiveToolConfig()
        #expect((model.tool as? CircleTool)?.fixedSize == nil,
                "a zero fixed size must map to nil (drag-the-radius)")
    }

    @Test("Arc: default creation mode is centerStartEnd; tangential flows through")
    func arcModeFlowsToTool() {
        let model = CanvasModel(drawing: CADDrawing())
        model.activateTool(.arc)
        #expect((model.tool as? ArcTool)?.mode == .centerStartEnd,
                "default arc mode must be centerStartEnd")

        model.arcMode = .tangential
        model.reapplyActiveToolConfig()
        #expect((model.tool as? ArcTool)?.mode == .tangential,
                "the options-bar tangential arc mode must reach the minted tool")

        model.arcMode = .threePoint
        model.reapplyActiveToolConfig()
        #expect((model.tool as? ArcTool)?.mode == .threePoint)
    }

    @Test("Line: default angle mode is free (back-compatible)")
    func lineDefaultAngleModeIsFree() {
        let model = CanvasModel(drawing: CADDrawing())
        model.activateTool(.line)
        let tool = model.tool as? LineTool
        #expect(tool != nil, "activating .line must mint a LineTool")
        #expect(tool?.angleMode == .free, "default line angle mode must be .free")
    }

    @Test("Line: absolute/relative angle modes carry the configured angle (radians)")
    func lineAngleModesFlowToTool() {
        let model = CanvasModel(drawing: CADDrawing())

        // Absolute (index 1) — the angle is carried as radians.
        model.lineAngleModeIndex = 1
        model.lineAngle = .pi / 4   // 45°
        model.activateTool(.line)
        if case .absolute(let a)? = (model.tool as? LineTool)?.angleMode {
            #expect(abs(a - .pi / 4) < 1e-9, "absolute angle must carry the configured radians")
        } else {
            Issue.record("expected .absolute LineAngleMode, got \(String(describing: (model.tool as? LineTool)?.angleMode))")
        }

        // Relative (index 2) — re-apply while active re-mints in the relative mode.
        model.lineAngleModeIndex = 2
        model.lineAngle = .pi / 2   // 90°
        model.reapplyActiveToolConfig()
        if case .relative(let a)? = (model.tool as? LineTool)?.angleMode {
            #expect(abs(a - .pi / 2) < 1e-9, "relative angle must carry the configured radians")
        } else {
            Issue.record("expected .relative LineAngleMode, got \(String(describing: (model.tool as? LineTool)?.angleMode))")
        }

        // Back to free (index 0).
        model.lineAngleModeIndex = 0
        model.reapplyActiveToolConfig()
        #expect((model.tool as? LineTool)?.angleMode == .free)
    }

    @Test("lineAngleModeValue maps the split (index + angle) state to LineAngleMode")
    func lineAngleModeValueMapping() {
        let model = CanvasModel(drawing: CADDrawing())
        model.lineAngle = 1.0
        model.lineAngleModeIndex = 0
        #expect(model.lineAngleModeValue == .free)
        model.lineAngleModeIndex = 1
        #expect(model.lineAngleModeValue == .absolute(1.0))
        model.lineAngleModeIndex = 2
        #expect(model.lineAngleModeValue == .relative(1.0))
    }

    // MARK: - 2) Paper-space VIEWPORT placement (out-of-band ViewportTool flow)

    @Test("viewport placement is active+meaningful ONLY in a layout tab")
    func viewportPlacementOnlyMeaningfulInPaperSpace() {
        let model = CanvasModel(drawing: drawingWithLayout())

        // Model space: activating .viewport is inert (not meaningful).
        model.activateModel()
        model.activateTool(.viewport)
        #expect(model.activeToolKind == .viewport)
        #expect(!model.isViewportPlacementActive,
                ".viewport in model space must be inert (no active placement)")
        #expect(model.tool == nil, ".viewport mints no Tool (out-of-band)")

        // Paper space (a real layout): now it is active + meaningful.
        model.activateLayout(name: "Layout1")
        model.activateTool(.viewport)
        #expect(model.isViewportPlacementActive,
                ".viewport in a layout tab must be an active placement")
    }

    @Test("a 2-click drag in a layout tab adds ONE framing viewport to the active layout")
    func twoClickAddsViewportToActiveLayout() {
        let model = CanvasModel(drawing: drawingWithLayout())
        model.activateLayout(name: "Layout1")
        model.activateTool(.viewport)

        // Before: the layout has no viewports.
        #expect(model.drawing.layout(named: "Layout1")?.viewports.isEmpty == true)

        // Two opposite corners on the sheet (paper coordinates) define the frame.
        let r1 = model.handleViewportClick(Vector(20, 20))   // first corner — preview only
        #expect(r1, "the first click should arm the rubber-band (redraw)")
        #expect(model.drawing.layout(named: "Layout1")?.viewports.isEmpty == true,
                "no viewport is committed on the first click")

        let r2 = model.handleViewportClick(Vector(120, 90))  // opposite corner — commits
        #expect(r2, "the second click should commit + redraw")

        let viewports = model.drawing.layout(named: "Layout1")?.viewports ?? []
        #expect(viewports.count == 1, "the 2-click drag must add exactly one viewport")

        // The committed viewport frames the model (its paperRect spans the two corners,
        // and its derived scale + view are non-degenerate for the non-empty model).
        if let vp = viewports.first {
            #expect(!vp.paperRect.isEmpty, "the viewport frame must be the dragged rect")
            #expect(vp.scale > 0, "a framed viewport over a real model has a positive scale")
        }
    }

    @Test("a degenerate (zero-area) 2-click is rejected — no viewport added")
    func degenerateDragAddsNoViewport() {
        let model = CanvasModel(drawing: drawingWithLayout())
        model.activateLayout(name: "Layout1")
        model.activateTool(.viewport)

        _ = model.handleViewportClick(Vector(30, 30))   // first corner
        _ = model.handleViewportClick(Vector(30, 30))   // same point — zero area
        #expect(model.drawing.layout(named: "Layout1")?.viewports.isEmpty == true,
                "a zero-area frame must not create a viewport")
    }

    @Test("a viewport click in MODEL space adds nothing (inert)")
    func viewportClickInModelSpaceIsInert() {
        let model = CanvasModel(drawing: drawingWithLayout())
        model.activateModel()
        model.activateTool(.viewport)
        let r1 = model.handleViewportClick(Vector(0, 0))
        let r2 = model.handleViewportClick(Vector(50, 50))
        #expect(!r1 && !r2, "viewport clicks in model space must be no-ops")
        #expect(model.drawing.layout(named: "Layout1")?.viewports.isEmpty == true)
    }

    @Test("two drags add two viewports (the tool re-arms after each placement)")
    func toolReArmsForRepeatedPlacements() {
        let model = CanvasModel(drawing: drawingWithLayout())
        model.activateLayout(name: "Layout1")
        model.activateTool(.viewport)

        _ = model.handleViewportClick(Vector(10, 10))
        _ = model.handleViewportClick(Vector(60, 50))
        _ = model.handleViewportClick(Vector(70, 10))
        _ = model.handleViewportClick(Vector(120, 50))
        #expect(model.drawing.layout(named: "Layout1")?.viewports.count == 2,
                "the tool must re-arm so a second drag places a second viewport")
    }

    @Test("viewportPreview is empty when not placing and non-empty mid-drag")
    func viewportPreviewTracksPlacement() {
        let model = CanvasModel(drawing: drawingWithLayout())
        model.activateLayout(name: "Layout1")
        model.activateTool(.viewport)
        #expect(model.viewportPreview.isEmpty, "no preview before the first click")

        _ = model.handleViewportClick(Vector(20, 20))   // first corner fixed
        _ = model.handleViewportMove(Vector(100, 80))   // cursor moved → rubber-band
        #expect(!model.viewportPreview.isEmpty, "the rubber-band must show mid-drag")
    }

    // MARK: - 3) Per-LAYOUT export SCENE filter (pure — no panel)

    @Test("layoutExportScene contains ONLY the active layout's paper-space records")
    func layoutSceneFiltersToActiveLayout() {
        let d = CADDrawing()
        _ = d.add(modelLine(1))                                   // model — excluded
        _ = d.addLayout(Layout(name: "Layout1", tabOrder: 0, page: PageDescriptor()))
        _ = d.addLayout(Layout(name: "Layout2", tabOrder: 1, page: PageDescriptor()))
        _ = d.add(paperLine(2, on: "Layout1"))                   // included
        _ = d.add(paperLine(3, on: "Layout2"))                   // other layout — excluded
        let model = CanvasModel(drawing: d)

        guard let layout1 = model.drawing.layout(named: "Layout1") else {
            Issue.record("Layout1 missing"); return
        }
        let scene = model.layoutExportScene(for: layout1)
        // The single paper line on Layout1 resolves to one stroke polyline; the model
        // line + Layout2's paper line are excluded.
        #expect(scene.polylines.count == 1,
                "the layout scene must contain only Layout1's paper-space stroke")
        #expect(!scene.bounds.isEmpty, "the scene bounds must reflect the included geometry")
    }

    @Test("layoutExportScene for an empty layout yields an empty scene")
    func emptyLayoutSceneIsEmpty() {
        let d = CADDrawing()
        _ = d.add(modelLine(1))
        _ = d.addLayout(Layout(name: "Blank", tabOrder: 0, page: PageDescriptor()))
        let model = CanvasModel(drawing: d)
        guard let blank = model.drawing.layout(named: "Blank") else {
            Issue.record("Blank layout missing"); return
        }
        let scene = model.layoutExportScene(for: blank)
        #expect(scene.polylines.isEmpty && scene.fills.isEmpty && scene.images.isEmpty,
                "a layout with no paper-space records yields an empty scene")
    }
}
