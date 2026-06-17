//
//  SmartCommandLineDispatchTests.swift
//  CADEngineTests
//
//  Wave 3 of the bottom-chrome redesign: the MODEL-side dispatch for the merged
//  smart command line, plus the engine `closeAnchor` accessor it routes a `Close`
//  keyword through. Proves the contract the Wave 4 UI consumes:
//
//   • `Tool.closeAnchor` (engine, pure) — `nil` before a tool can close, then the
//     FIRST placed vertex/point exactly when `keywordOptions` offers `Close`
//     (Polyline ≥ 2 vertices, Spline ≥ 3 points).
//   • `CanvasModel.activeToolKeywordOptions` — read-through of the live tool's chips.
//   • `CanvasModel.invokeToolKeyword(_:)` — the single dispatch entry for a typed
//     keyword OR a chip tap: `Undo` → backspace, `Close` → re-feed the first point,
//     construction-MODE keywords → set the config field + re-mint.
//   • `CanvasModel.interpretCommandLine(_:)` — the unified ⏎ router returning a
//     `CommandLineResult` (`.empty`/`.handled`/`.activateTool`/`.error`), keeping
//     `.image`/modal activation in the View (it returns `.activateTool`, never
//     activates here).
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink; the suite is `@MainActor`, mirroring
//  `Wave3BCanvasModelWiringTests`. The engine `closeAnchor` tests need no symlink.
//  No SwiftUI body / NSMenu / modal / NSOpenPanel is rendered — only pure model +
//  engine wiring (a modal reached from a test would hang the headless suite forever).
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

// MARK: - Engine: Tool.closeAnchor (pure, no app target / no GUI)

@Suite("Wave-3 closeAnchor (Polyline / Spline)")
struct CloseAnchorTests {

    // MARK: Polyline — nil until ≥ 2 vertices, then the FIRST vertex.

    @Test("PolylineTool.closeAnchor is nil before there are 2 vertices")
    func polylineNoAnchorBeforeCloseable() {
        var t = PolylineTool()
        #expect(t.closeAnchor == nil)                 // empty state

        _ = t.handle(.click(Vector(0, 0)), context: .empty)
        #expect(t.closeAnchor == nil)                 // 1 vertex — no Close yet
        // And `keywordOptions` agrees: no Close at 1 vertex.
        #expect(!t.keywordOptions.contains { $0.keyword == "Close" })
    }

    @Test("PolylineTool.closeAnchor is the first vertex once ≥ 2 vertices (matches keywordOptions)")
    func polylineAnchorIsFirstVertex() {
        var t = PolylineTool()
        _ = t.handle(.click(Vector(1, 2)), context: .empty)   // first vertex
        _ = t.handle(.click(Vector(5, 6)), context: .empty)   // second vertex → closeable
        #expect(t.closeAnchor == Vector(1, 2))
        // closeAnchor is non-nil EXACTLY when Close is offered.
        #expect(t.keywordOptions.contains { $0.keyword == "Close" })

        // A third vertex keeps the anchor pinned to the FIRST vertex.
        _ = t.handle(.click(Vector(9, 1)), context: .empty)
        #expect(t.closeAnchor == Vector(1, 2))
    }

    // MARK: Spline — nil until ≥ 3 points (the real close gate), then the FIRST point.

    @Test("SplineTool.closeAnchor is nil before there are 3 points")
    func splineNoAnchorBeforeCloseable() {
        var t = SplineTool()
        #expect(t.closeAnchor == nil)                 // empty

        _ = t.handle(.click(Vector(0, 0)), context: .empty)
        #expect(t.closeAnchor == nil)                 // 1 point
        _ = t.handle(.click(Vector(2, 0)), context: .empty)
        #expect(t.closeAnchor == nil)                 // 2 points — still cannot close
        #expect(!t.keywordOptions.contains { $0.keyword == "Close" })
    }

    @Test("SplineTool.closeAnchor is the first point once ≥ 3 points (matches keywordOptions)")
    func splineAnchorIsFirstPoint() {
        var t = SplineTool()
        _ = t.handle(.click(Vector(1, 1)), context: .empty)
        _ = t.handle(.click(Vector(4, 0)), context: .empty)
        _ = t.handle(.click(Vector(2, 5)), context: .empty)   // 3 points → closeable
        #expect(t.closeAnchor == Vector(1, 1))
        #expect(t.keywordOptions.contains { $0.keyword == "Close" })
    }
}

// MARK: - Model: invokeToolKeyword + interpretCommandLine

@MainActor
@Suite("Wave-3 smart command line dispatch")
struct SmartCommandLineDispatchTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    // MARK: activeToolKeywordOptions

    @Test("activeToolKeywordOptions is empty with no tool, and mirrors the live tool")
    func activeKeywordOptionsReadThrough() {
        let m = model()
        #expect(m.activeToolKeywordOptions.isEmpty)            // select mode

        m.activateTool(.circle)                                // default centerRadius
        // A fresh Circle in its initial state offers the OTHER construction modes.
        let keys = Set(m.activeToolKeywordOptions.map { $0.keyword.lowercased() })
        #expect(keys.contains("2p"))
        #expect(keys.contains("3p"))
    }

    // MARK: invokeToolKeyword — Undo

    @Test("invokeToolKeyword(Undo) steps the last polyline vertex back")
    func keywordUndoBacksUp() {
        let m = model()
        m.activateTool(.polyline)
        m.handleToolInput(.click(Vector(0, 0)))
        m.handleToolInput(.click(Vector(10, 0)))
        m.handleToolInput(.click(Vector(10, 10)))
        // 3 vertices: closeAnchor present.
        let poly3 = m.tool as? PolylineTool
        #expect(poly3?.closeAnchor == Vector(0, 0))

        m.invokeToolKeyword("Undo")                            // remove the last vertex
        let poly2 = m.tool as? PolylineTool
        #expect(poly2?.closeAnchor == Vector(0, 0))            // still closeable (2 left)

        m.invokeToolKeyword("Undo")                            // down to 1 vertex
        let poly1 = m.tool as? PolylineTool
        #expect(poly1?.closeAnchor == nil)                     // not closeable anymore
    }

    // MARK: invokeToolKeyword — Close commits a CLOSED polyline

    @Test("invokeToolKeyword(Close) commits a closed polyline to the drawing")
    func keywordCloseCommitsClosedPolyline() throws {
        let m = model()
        m.activateTool(.polyline)
        m.handleToolInput(.click(Vector(0, 0)))
        m.handleToolInput(.click(Vector(10, 0)))
        m.handleToolInput(.click(Vector(10, 10)))
        let before = m.drawing.entities.count

        m.invokeToolKeyword("Close")                           // re-feeds the first vertex

        #expect(m.drawing.entities.count == before + 1)
        let added = try #require(m.drawing.entities.last)
        guard case .polyline(let data) = added.kind else {
            Issue.record("expected a polyline entity, got \(added.kind)")
            return
        }
        #expect(data.closed)                                   // the loop closed
        #expect(data.vertices.count == 3)                      // three picked vertices
    }

    @Test("invokeToolKeyword(Close) is a no-op when the tool cannot close yet")
    func keywordCloseNoOpWhenNotCloseable() {
        let m = model()
        m.activateTool(.polyline)
        m.handleToolInput(.click(Vector(0, 0)))                // only 1 vertex
        let before = m.drawing.entities.count
        m.invokeToolKeyword("Close")                           // not offered → ignored
        #expect(m.drawing.entities.count == before)
    }

    // MARK: invokeToolKeyword — construction-mode keywords

    @Test("invokeToolKeyword(2P) flips Circle construction mode and re-mints")
    func keywordCircle2PFlipsMode() throws {
        let m = model()
        m.activateTool(.circle)                                // default centerRadius
        #expect(m.circleConstructionMode == .centerRadius)

        m.invokeToolKeyword("2P")
        #expect(m.circleConstructionMode == .twoPoint)
        // The live tool was re-minted in the new mode.
        let t = try #require(m.tool as? CircleTool)
        #expect(t.mode == .twoPoint)
    }

    @Test("invokeToolKeyword(Diameter) flips Circle size mode")
    func keywordCircleDiameterFlipsSizeMode() throws {
        let m = model()
        m.activateTool(.circle)
        #expect(m.circleSizeMode == .radius)
        m.invokeToolKeyword("Diameter")
        #expect(m.circleSizeMode == .diameter)
        let t = try #require(m.tool as? CircleTool)
        #expect(t.sizeMode == .diameter)
    }

    @Test("invokeToolKeyword(4P) flips Ellipse mode index and re-mints")
    func keywordEllipse4PFlipsModeIndex() throws {
        let m = model()
        m.activateTool(.ellipse)                               // default axis (index 0)
        #expect(m.ellipseModeIndex == 0)

        m.invokeToolKeyword("4P")
        #expect(m.ellipseModeIndex == 2)
        let t = try #require(m.tool as? EllipseTool)
        #expect(t.mode == .fourPoint)
    }

    @Test("invokeToolKeyword(3P) disambiguates Circle vs Arc by the active tool")
    func keyword3PDisambiguatesByKind() throws {
        // Circle: 3P → threePoint construction.
        let mc = model()
        mc.activateTool(.circle)
        mc.invokeToolKeyword("3P")
        #expect(mc.circleConstructionMode == .threePoint)
        #expect(mc.arcMode == .centerStartEnd)                 // arc field untouched

        // Arc: 3P → threePoint arc mode (not circle).
        let ma = model()
        ma.activateTool(.arc)
        ma.invokeToolKeyword("3P")
        #expect(ma.arcMode == .threePoint)
        #expect(ma.circleConstructionMode == .centerRadius)    // circle field untouched
    }

    @Test("invokeToolKeyword ignores a keyword the tool is not currently offering")
    func keywordIgnoredWhenNotOffered() {
        let m = model()
        m.activateTool(.circle)                                // centerRadius
        // `Cen` is NOT offered while already in centerRadius → no change.
        m.invokeToolKeyword("Cen")
        #expect(m.circleConstructionMode == .centerRadius)
    }

    @Test("invokeToolKeyword is a no-op with no active tool")
    func keywordNoOpNoTool() {
        let m = model()
        m.invokeToolKeyword("Close")                           // select mode
        #expect(m.tool == nil)
        #expect(m.drawing.entities.isEmpty)
    }

    // MARK: interpretCommandLine

    @Test("interpretCommandLine returns .empty on blank input")
    func interpretEmpty() {
        let m = model()
        #expect(m.interpretCommandLine("") == .empty)
        #expect(m.interpretCommandLine("   ") == .empty)
    }

    @Test("interpretCommandLine feeds a coordinate to the active tool → .handled")
    func interpretCoordinateWithTool() {
        let m = model()
        m.activateTool(.line)
        let r = m.interpretCommandLine("10,20")
        #expect(r == .handled)
        #expect(m.lastCommandError == nil)
    }

    @Test("interpretCommandLine on a coordinate with NO tool → .error")
    func interpretCoordinateNoTool() {
        let m = model()
        let r = m.interpretCommandLine("10,20")
        if case .error = r {} else { Issue.record("expected .error, got \(r)") }
        #expect(m.lastCommandError != nil)
    }

    @Test("interpretCommandLine resolves a tool command name → .activateTool (does NOT activate)")
    func interpretToolCommand() {
        let m = model()
        #expect(m.interpretCommandLine("L") == .activateTool(.line))
        // The model returns the kind for the View to activate; it did NOT activate here.
        #expect(m.activeToolKind == .select)
        #expect(m.tool == nil)

        #expect(m.interpretCommandLine("LINE") == .activateTool(.line))
    }

    @Test("interpretCommandLine returns .error for an unknown command")
    func interpretUnknown() {
        let m = model()
        let r = m.interpretCommandLine("xyzzy")
        if case .error = r {} else { Issue.record("expected .error, got \(r)") }
        #expect(m.lastCommandError?.contains("xyzzy") == true)
    }

    @Test("interpretCommandLine fires a matching tool keyword → .handled")
    func interpretMatchingKeyword() throws {
        let m = model()
        m.activateTool(.polyline)
        m.handleToolInput(.click(Vector(0, 0)))
        m.handleToolInput(.click(Vector(10, 0)))
        m.handleToolInput(.click(Vector(10, 10)))
        let before = m.drawing.entities.count

        let r = m.interpretCommandLine("close")                // case-insensitive keyword
        #expect(r == .handled)
        #expect(m.drawing.entities.count == before + 1)        // closed polyline committed
    }

    @Test("interpretCommandLine prefers a tool keyword over a command-name lookup")
    func interpretKeywordBeatsCommand() throws {
        // A Circle in initial state offers `2P`; ensure the keyword route wins over any
        // chance of `2P` resolving as a command name (it would route as a coordinate via
        // the leading digit otherwise — the keyword check comes first).
        let m = model()
        m.activateTool(.circle)
        let r = m.interpretCommandLine("2P")
        #expect(r == .handled)
        #expect(m.circleConstructionMode == .twoPoint)
    }
}
