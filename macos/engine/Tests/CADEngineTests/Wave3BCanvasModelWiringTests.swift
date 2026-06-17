//
//  Wave3BCanvasModelWiringTests.swift
//  CADEngineTests
//
//  The Wave-3B `CanvasModel` integration FOUNDATION (the methods/state the Wave-3
//  consumers — ToolOptionsBar / grip mount / ContentView / menus / LayersSidebar —
//  call after this merges). Proves the model wiring carries config through and the
//  new wrappers behave; the engine pieces (DivideMode / SplineMode / ScaleMode /
//  HatchTool.Fill / EntityGrips / LayerIsolation / AppSettings) are already merged
//  and unit-tested in their own suites — here we only verify the CanvasModel surface:
//
//   • Stage 1 — tool-config round-trips through `applyToolConfig` (re-mint / re-apply
//     carries the chosen Divide/Spline/Scale/Hatch mode + params onto the live tool).
//   • Stage 2 — `commitMovedGrip` applies an undoable `.replace` of one record; the
//     `LayerIsolation`-backed layer ops mutate + undo.
//   • Stage 3 — new-window snap seed from AppSettings; `pasteAsBlock` wraps the
//     clipboard into a block + INSERT, undoably.
//
//  `CanvasModel` / `AppSettings` live in the (un-importable) app target — reached
//  here via the existing `_SharedCanvasModel.swift` / `_SharedAppSettings.swift`
//  symlinks (the suite is `@MainActor`, mirroring `InsertOptionsAndBlockFreezeWiringTests`).
//  No SwiftUI body / NSMenu / modal is rendered — only the pure model wiring.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
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
@Suite("Wave-3B CanvasModel wiring — tool config")
struct Wave3BToolConfigTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    // MARK: - Divide

    @Test("applyToolConfig keeps DivideTool in count mode by default")
    func divideDefaultsToCount() throws {
        let m = model()
        m.divideCount = 7
        m.activateTool(.divide)            // mints + applyToolConfig
        let tool = try #require(m.tool as? DivideTool)
        #expect(tool.mode == .count(7))
    }

    @Test("applyToolConfig re-mints DivideTool in MEASURE-by-length mode")
    func divideLengthMode() throws {
        let m = model()
        m.divideModeStyle = 1
        m.divideSpacing = 12.5
        m.activateTool(.divide)
        let tool = try #require(m.tool as? DivideTool)
        #expect(tool.mode == .length(12.5))
    }

    @Test("divideMode clamps a non-positive spacing back to a usable default")
    func divideSpacingClamp() {
        let m = model()
        m.divideModeStyle = 1
        m.divideSpacing = 0
        #expect(m.divideMode == .length(10.0))
    }

    // MARK: - Spline

    @Test("applyToolConfig re-mints SplineTool in the configured mode")
    func splineMode() throws {
        let m = model()
        m.splineMode = .controlPoints
        m.activateTool(.spline)
        let tool = try #require(m.tool as? SplineTool)
        #expect(tool.mode == .controlPoints)

        m.splineMode = .fit
        m.reapplyActiveToolConfig()
        let refit = try #require(m.tool as? SplineTool)
        #expect(refit.mode == .fit)
    }

    // MARK: - Scale

    @Test("applyToolConfig applies the Scale mode + non-uniform factors in place")
    func scaleMode() throws {
        let m = model()
        m.scaleMode = .nonUniform
        m.scaleX = 2
        m.scaleY = 3
        m.activateTool(.scale)
        let tool = try #require(m.tool as? ScaleTool)
        #expect(tool.mode == .nonUniform)
        #expect(tool.nonUniformFactors.sx == 2)
        #expect(tool.nonUniformFactors.sy == 3)
    }

    @Test("Scale tool defaults to the original .factor behavior")
    func scaleDefault() throws {
        let m = model()
        m.activateTool(.scale)
        let tool = try #require(m.tool as? ScaleTool)
        #expect(tool.mode == .factor)
    }

    // MARK: - Hatch

    @Test("applyToolConfig leaves HatchTool solid by default")
    func hatchDefaultSolid() throws {
        let m = model()
        m.activateTool(.hatch)
        let tool = try #require(m.tool as? HatchTool)
        #expect(tool.fill == .solid)
    }

    @Test("applyToolConfig builds a named pattern fill from currentHatchPattern")
    func hatchPattern() throws {
        let m = model()
        m.currentHatchPattern = "ANSI31"
        m.hatchPatternScale = 2
        m.hatchPatternAngle = .pi / 4
        m.activateTool(.hatch)
        let tool = try #require(m.tool as? HatchTool)
        #expect(tool.fill == .pattern(name: "ANSI31", scale: 2, angle: .pi / 4))
    }

    @Test("a SOLID / blank hatch name resolves to a solid fill")
    func hatchSolidName() {
        let m = model()
        m.currentHatchPattern = "SOLID"
        #expect(m.hatchFillValue == .solid)
        m.currentHatchPattern = "  "
        #expect(m.hatchFillValue == .solid)
        m.currentHatchPattern = nil
        #expect(m.hatchFillValue == .solid)
    }
}
