//
//  ToolVerbKeywordTests.swift
//  CADEngineTests
//
//  Drives `PolylineTool` / `SplineTool` PURELY (no GUI: only `ToolInput` events +
//  the read-only `ToolContext.empty`) and asserts their `keywordOptions` overrides —
//  the AutoCAD-style mid-draw `[Close]`/`[Undo]` command-line verbs the smart command
//  line (Wave 4) renders. These verbs reflect the tool's current `State` (the placed-
//  point count), mirroring how `status`/`preview` already reflect state, and must be
//  empty outside the active operation (before the first point and after commit/reset).
//
//  Wave 2A (smart-parameter command line). The keywords are PURE data; dispatching a
//  chosen keyword reuses EXISTING `ToolInput` events (`Undo` ↔ `.backspace`,
//  `Close` ↔ a `.click` on the first point) — wired in a later wave, not here.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Tool verb keywordOptions (Close/Undo)")
struct ToolVerbKeywordTests {

    // MARK: - Helpers

    /// The literal `keyword` tokens of a tool's current `keywordOptions`, in order.
    private func keywords(_ options: [ToolKeyword]) -> [String] {
        options.map(\.keyword)
    }

    // MARK: - PolylineTool

    @Test("Polyline: no keywords before the first point")
    func polylineEmptyBeforeFirstPoint() {
        let tool = PolylineTool()
        #expect(tool.keywordOptions.isEmpty)
    }

    @Test("Polyline: one vertex offers only [Undo]")
    func polylineOneVertexUndoOnly() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
        #expect(tool.keywordOptions.count == 1)
    }

    @Test("Polyline: two vertices offer [Close, Undo]")
    func polylineTwoVerticesCloseUndo() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Close", "Undo"])
        #expect(tool.keywordOptions.count == 2)
    }

    @Test("Polyline: three vertices still offer [Close, Undo]")
    func polylineThreeVerticesCloseUndo() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Close", "Undo"])
    }

    @Test("Polyline: labels match keywords")
    func polylineLabels() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let byKeyword = Dictionary(uniqueKeysWithValues: tool.keywordOptions.map { ($0.keyword, $0.label) })
        #expect(byKeyword["Close"] == "Close")
        #expect(byKeyword["Undo"] == "Undo")
    }

    @Test("Polyline: backspace to one vertex drops Close")
    func polylineBackspaceDropsClose() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Close", "Undo"])
        _ = tool.handle(.backspace, context: .empty)   // back to one vertex
        #expect(keywords(tool.keywordOptions) == ["Undo"])
    }

    @Test("Polyline: backspace to zero vertices clears keywords")
    func polylineBackspaceToEmptyClears() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
        _ = tool.handle(.backspace, context: .empty)   // back to empty
        #expect(tool.keywordOptions.isEmpty)
    }

    @Test("Polyline: no keywords after commit (state resets)")
    func polylineEmptyAfterCommit() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        if case .commit = outcome {} else { Issue.record("expected a commit") }
        #expect(tool.keywordOptions.isEmpty)
    }

    @Test("Polyline: no keywords after cancel (state resets)")
    func polylineEmptyAfterCancel() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.cancel, context: .empty)
        #expect(tool.keywordOptions.isEmpty)
    }

    // MARK: - SplineTool (fit mode — default)

    @Test("Spline: no keywords before the first point")
    func splineEmptyBeforeFirstPoint() {
        let tool = SplineTool()
        #expect(tool.keywordOptions.isEmpty)
    }

    @Test("Spline: one point offers only [Undo]")
    func splineOnePointUndoOnly() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
        #expect(tool.keywordOptions.count == 1)
    }

    @Test("Spline: two points still offer only [Undo] (cannot close yet)")
    func splineTwoPointsUndoOnly() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
    }

    @Test("Spline: three points offer [Close, Undo]")
    func splineThreePointsCloseUndo() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Close", "Undo"])
        #expect(tool.keywordOptions.count == 2)
    }

    @Test("Spline: control-point mode follows the same point-count gating")
    func splineControlPointModeSameGating() {
        var tool = SplineTool(mode: .controlPoints)
        #expect(tool.keywordOptions.isEmpty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Close", "Undo"])
    }

    @Test("Spline: labels match keywords")
    func splineLabels() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        let byKeyword = Dictionary(uniqueKeysWithValues: tool.keywordOptions.map { ($0.keyword, $0.label) })
        #expect(byKeyword["Close"] == "Close")
        #expect(byKeyword["Undo"] == "Undo")
    }

    @Test("Spline: backspace to two points drops Close")
    func splineBackspaceDropsClose() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Close", "Undo"])
        _ = tool.handle(.backspace, context: .empty)   // back to two points
        #expect(keywords(tool.keywordOptions) == ["Undo"])
    }

    @Test("Spline: backspace to zero points clears keywords")
    func splineBackspaceToEmptyClears() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(keywords(tool.keywordOptions) == ["Undo"])
        _ = tool.handle(.backspace, context: .empty)   // back to empty
        #expect(tool.keywordOptions.isEmpty)
    }

    @Test("Spline: no keywords after commit (state resets)")
    func splineEmptyAfterCommit() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        if case .commit = outcome {} else { Issue.record("expected a commit") }
        #expect(tool.keywordOptions.isEmpty)
    }

    @Test("Spline: no keywords after cancel (state resets)")
    func splineEmptyAfterCancel() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.cancel, context: .empty)
        #expect(tool.keywordOptions.isEmpty)
    }
}
