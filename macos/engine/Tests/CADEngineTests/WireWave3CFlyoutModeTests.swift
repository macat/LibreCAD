//
//  WireWave3CFlyoutModeTests.swift
//  CADEngineTests
//
//  Wire-wave-3C (toolbar tool-MODE flyouts) surfacing. The new ContentView toolbar
//  flyouts — Spline ▸ {Fit points / Control points}, Divide ▸ {By number / By length},
//  Scale ▸ {Uniform / Non-uniform X/Y} — each work by SETTING the matching `CanvasModel`
//  config FIRST, then ACTIVATING the existing tool, so `applyToolConfig` mints/re-applies
//  the tool in that mode (the same Wave-3B/3F plumbing the options bar uses). These guard
//  THAT contract over the `_SharedCanvasModel.swift` symlink (the app module's
//  `CanvasModel.swift`, compiled into this test target via the `_Shared*` convention).
//
//  The flyout *view* (`ToolCatalog`/`ExportOptionsAccessory`) is a SwiftUI surface in the
//  app module and is NOT compiled into the engine test target — and it is reachable only
//  through a modal, so it must not be exercised here (the modal-hang trap). What IS
//  testable, and what the flyout depends on, is the model→tool config flow asserted below
//  (mirrors `WireWave1SurfaceTests`' circle/arc construction-mode tests).
//
//  Uniquely namespaced (`@Suite("wire-wave-3C ...")`) so it does not collide with the
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
@testable import CADEngine

@MainActor
@Suite("wire-wave-3C (Spline / Divide / Scale tool-mode flyouts → minted tool)")
struct WireWave3CFlyoutModeTests {

    // MARK: - Spline ▸ {Fit points (default) / Control points}

    @Test("Spline: default creation mode is .fit (back-compatible)")
    func splineDefaultModeIsFit() {
        let model = CanvasModel(drawing: CADDrawing())
        model.activateTool(.spline)
        let tool = model.tool as? SplineTool
        #expect(tool != nil, "activating .spline must mint a SplineTool")
        #expect(tool?.mode == .fit, "default spline mode must be .fit")
    }

    @Test("Spline: the flyout's control-points mode is pushed onto the minted tool")
    func splineControlPointsModeFlowsToTool() {
        let model = CanvasModel(drawing: CADDrawing())
        // The flyout sets the model mode FIRST, then activates the existing tool.
        model.splineMode = .controlPoints
        model.activateTool(.spline)
        #expect((model.tool as? SplineTool)?.mode == .controlPoints,
                "the flyout's spline mode must reach the minted tool")

        // Switching back to fit + re-activating re-mints in .fit (the toolbar can flip).
        model.splineMode = .fit
        model.activateTool(.spline)
        #expect((model.tool as? SplineTool)?.mode == .fit)
    }

    // MARK: - Divide ▸ {By number (count, default) / By length}

    @Test("Divide: default style is by-number/count (back-compatible)")
    func divideDefaultStyleIsCount() {
        let model = CanvasModel(drawing: CADDrawing())
        #expect(model.divideModeStyle == 0, "default divide style index must be 0 (count)")
        model.divideCount = 4
        model.activateTool(.divide)
        let tool = model.tool as? DivideTool
        #expect(tool != nil, "activating .divide must mint a DivideTool")
        #expect(tool?.mode == .count(4), "default divide style must mint a .count mode")
    }

    @Test("Divide: the by-length style index mints a .length DivideMode")
    func divideByLengthStyleFlowsToTool() {
        let model = CanvasModel(drawing: CADDrawing())
        // The flyout sets divideModeStyle = 1 (By Length) then activates the tool.
        model.divideModeStyle = 1
        model.divideSpacing = 12.5
        model.activateTool(.divide)
        #expect((model.tool as? DivideTool)?.mode == .length(12.5),
                "the by-length flyout style must mint a .length DivideMode at the spacing")

        // Flipping back to count (index 0) re-mints a .count mode.
        model.divideModeStyle = 0
        model.divideCount = 3
        model.activateTool(.divide)
        #expect((model.tool as? DivideTool)?.mode == .count(3))
    }

    // MARK: - Scale ▸ {Uniform (.factor, default) / Non-uniform X/Y (.nonUniform)}

    @Test("Scale: default mode is .factor / Uniform (back-compatible)")
    func scaleDefaultModeIsFactor() {
        let model = CanvasModel(drawing: CADDrawing())
        model.activateTool(.scale)
        let tool = model.tool as? ScaleTool
        #expect(tool != nil, "activating .scale must mint a ScaleTool")
        #expect(tool?.mode == .factor, "default scale mode must be .factor (Uniform)")
    }

    @Test("Scale: the non-uniform flyout mode + per-axis factors flow to the tool")
    func scaleNonUniformModeFlowsToTool() {
        let model = CanvasModel(drawing: CADDrawing())
        // The flyout sets scaleMode = .nonUniform then activates the tool; the per-axis
        // factors come from scaleX / scaleY (options bar 3F).
        model.scaleMode = .nonUniform
        model.scaleX = 2
        model.scaleY = 3
        model.activateTool(.scale)
        let tool = model.tool as? ScaleTool
        #expect(tool?.mode == .nonUniform, "the flyout's non-uniform mode must reach the tool")
        #expect(tool?.nonUniformFactors.sx == 2)
        #expect(tool?.nonUniformFactors.sy == 3)

        // Flipping back to Uniform (.factor) re-applies the original mode.
        model.scaleMode = .factor
        model.activateTool(.scale)
        #expect((model.tool as? ScaleTool)?.mode == .factor)
    }
}
