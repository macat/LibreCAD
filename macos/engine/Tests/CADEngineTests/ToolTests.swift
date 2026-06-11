//
//  ToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Tool framework PURELY (no GUI): feeds `ToolInput`
//  events to `LineTool` and asserts the outcomes, the live preview, the chaining
//  behavior, cancel/backspace resets, and the status prompt transitions.
//
//  Domain-prefixed suite names (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide). The tool
//  fan-out adds `<Name>ToolTests` suites here following this template.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("LineTool interactive draw")
struct LineToolTests {

    // MARK: - Helpers

    /// Pulls the single LineData out of a `.commit` outcome (fails the test if the
    /// outcome isn't a one-record line commit).
    private func committedLine(_ outcome: ToolOutcome) -> LineData? {
        guard case .commit(let records) = outcome, records.count == 1,
              case .line(let d) = records[0].kind else { return nil }
        return d
    }

    // MARK: - Status transitions

    @Test("status starts at 'Specify first point' and advances after the first click")
    func statusTransitions() {
        var tool = LineTool()
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(0, 0)))
        #expect(tool.status == "Specify next point")
    }

    @Test("title is Line")
    func title() {
        #expect(LineTool().title == "Line")
    }

    // MARK: - Two-click commit

    @Test("two clicks commit a line with the exact endpoints")
    func twoClicksCommit() {
        var tool = LineTool()
        let start = Vector(1, 2)
        let end = Vector(7, 9)

        let first = tool.handle(.click(start))
        #expect(first == .none)   // first click only fixes the start

        let second = tool.handle(.click(end))
        let line = committedLine(second)
        #expect(line != nil)
        #expect(line?.start == start)
        #expect(line?.end == end)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)))
        let outcome = tool.handle(.click(Vector(5, 0)))
        guard case .commit(let records) = outcome else {
            Issue.record("expected a commit outcome")
            return
        }
        #expect(records.count == 1)
        #expect(records[0].id == .placeholder)
        #expect(records[0].id == EntityID(0))
    }

    // MARK: - Preview (rubber-band)

    @Test("preview is empty before the first click")
    func previewEmptyInitially() {
        var tool = LineTool()
        #expect(tool.preview.isEmpty)
        // A move with no fixed point still shows nothing.
        let outcome = tool.handle(.move(Vector(3, 3)))
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the first click a move produces a 1-segment preview start→cursor")
    func previewAfterFirstClick() {
        var tool = LineTool()
        let start = Vector(2, 2)
        _ = tool.handle(.click(start))

        let cursor = Vector(10, 4)
        let outcome = tool.handle(.move(cursor))
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.points.count == 2)
        #expect(poly.closed == false)
        #expect(poly.points[0] == start)
        #expect(poly.points[1] == cursor)
    }

    @Test("preview updates to the new cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)))
        _ = tool.handle(.move(Vector(1, 1)))
        _ = tool.handle(.move(Vector(8, 3)))
        #expect(tool.preview[0].points[1] == Vector(8, 3))
    }

    // MARK: - Chaining (polyline-like run)

    @Test("chaining: the next segment continues from the last endpoint")
    func chainingContinuesFromEndpoint() {
        var tool = LineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(5, 0)
        let p2 = Vector(5, 5)

        _ = tool.handle(.click(p0))
        let seg1 = committedLine(tool.handle(.click(p1)))
        #expect(seg1?.start == p0)
        #expect(seg1?.end == p1)

        // A move now rubber-bands from p1, not p0.
        _ = tool.handle(.move(Vector(5, 3)))
        #expect(tool.preview[0].points[0] == p1)

        // The next click commits p1→p2 (continues the chain).
        let seg2 = committedLine(tool.handle(.click(p2)))
        #expect(seg2?.start == p1)
        #expect(seg2?.end == p2)

        // Still active (chaining), prompt unchanged.
        #expect(tool.status == "Specify next point")
    }

    @Test("a degenerate (zero-length) second click does not commit")
    func degenerateClickIgnored() {
        var tool = LineTool()
        let p = Vector(3, 3)
        _ = tool.handle(.click(p))
        let outcome = tool.handle(.click(p))   // same point
        #expect(outcome == .none)
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)))
        _ = tool.handle(.move(Vector(5, 5)))
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first point")
    }

    @Test("commit ends the run and finishes (segments already committed per click)")
    func commitFinishes() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(0, 0)))
        _ = tool.handle(.click(Vector(4, 0)))   // already committed seg1
        let outcome = tool.handle(.commit)       // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first point")
    }

    @Test("backspace from a single fixed point returns to the initial state")
    func backspaceRewinds() {
        var tool = LineTool()
        _ = tool.handle(.click(Vector(2, 2)))
        #expect(tool.status == "Specify next point")
        let outcome = tool.handle(.backspace)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify first point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = LineTool()
        let outcome = tool.handle(.backspace)
        #expect(outcome == .none)
        #expect(tool.status == "Specify first point")
    }
}

@Suite("ToolKind registration")
struct ToolKindTests {

    @Test("select makes no tool; line makes a LineTool")
    func makeTool() {
        #expect(ToolKind.select.makeTool() == nil)
        let tool = ToolKind.line.makeTool()
        #expect(tool != nil)
        #expect(tool?.title == "Line")
    }

    @Test("titles are present for every kind")
    func titles() {
        #expect(ToolKind.select.title == "Select")
        #expect(ToolKind.line.title == "Line")
    }

    @Test("kinds round-trip through their raw value")
    func rawValueRoundTrip() {
        for kind in ToolKind.allCases {
            #expect(ToolKind(rawValue: kind.rawValue) == kind)
        }
    }
}
