//
//  RectangleToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Rectangle tool PURELY (no GUI): feeds `ToolInput`
//  events + a read-only `ToolContext` to `RectangleTool` and asserts the commit
//  shape (a closed 4-corner polyline from the two opposite corners), the live
//  preview, the cancel/backspace resets, the status prompts, and that degenerate
//  picks are ignored.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("RectangleTool interactive draw")
struct RectangleToolTests {

    // MARK: - Helpers

    /// Pulls the single `PolylineData` out of a `.commit` outcome (fails the test
    /// if the outcome isn't a one-edit `.add` polyline commit).
    private func committedPolyline(_ outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status transitions

    @Test("title is Rectangle")
    func title() {
        #expect(RectangleTool().title == "Rectangle")
    }

    @Test("status starts at 'Specify first corner' and advances after the first click")
    func statusTransitions() {
        var tool = RectangleTool()
        #expect(tool.status == "Specify first corner")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify opposite corner")
    }

    // MARK: - Two-corner commit

    @Test("two clicks commit a closed 4-corner rectangle at the corners (correct order/winding)")
    func twoClicksCommit() {
        var tool = RectangleTool()
        let first = Vector(0, 0)
        let opposite = Vector(10, 5)

        let firstOutcome = tool.handle(.click(first), context: .empty)
        #expect(firstOutcome == .none)   // first click only fixes the first corner

        let secondOutcome = tool.handle(.click(opposite), context: .empty)
        let poly = committedPolyline(secondOutcome)
        #expect(poly != nil)
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 4)

        // CCW order from (x0,y0): (0,0) → (10,0) → (10,5) → (0,5).
        let pts = poly?.vertices.map(\.point)
        #expect(pts == [Vector(0, 0), Vector(10, 0), Vector(10, 5), Vector(0, 5)])

        // All bulges are zero (straight edges).
        #expect(poly?.vertices.allSatisfy { $0.bulge == 0 } == true)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(4, 3)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
    }

    @Test("after a commit the tool resets to wait for the next rectangle's first corner")
    func resetsAfterCommit() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 5)), context: .empty)
        #expect(tool.status == "Specify first corner")
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Preview (rubber-band)

    @Test("preview is empty before the first click")
    func previewEmptyInitially() {
        var tool = RectangleTool()
        #expect(tool.preview.isEmpty)
        // A move with no fixed corner still shows nothing.
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the first click a move previews a closed 4-corner rect to the cursor")
    func previewAfterFirstClick() {
        var tool = RectangleTool()
        let first = Vector(0, 0)
        _ = tool.handle(.click(first), context: .empty)

        let cursor = Vector(10, 5)
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.closed == true)
        #expect(poly.points.count == 4)
        #expect(poly.points == [Vector(0, 0), Vector(10, 0), Vector(10, 5), Vector(0, 5)])
    }

    @Test("preview updates to span the new cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(2, 2)), context: .empty)
        _ = tool.handle(.move(Vector(8, 3)), context: .empty)
        #expect(tool.preview[0].points == [Vector(0, 0), Vector(8, 0), Vector(8, 3), Vector(0, 3)])
    }

    // MARK: - Degenerate picks

    @Test("a degenerate (coincident) opposite corner does not commit")
    func degenerateCoincidentIgnored() {
        var tool = RectangleTool()
        let p = Vector(3, 3)
        _ = tool.handle(.click(p), context: .empty)
        let outcome = tool.handle(.click(p), context: .empty)   // same point → zero area
        #expect(outcome == .none)
        // Still waiting for a valid opposite corner.
        #expect(tool.status == "Specify opposite corner")
    }

    @Test("a zero-width opposite corner (same x) does not commit")
    func degenerateZeroWidthIgnored() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(2, 5)), context: .empty)   // collapses to a line
        #expect(outcome == .none)
    }

    @Test("a zero-height opposite corner (same y) does not commit")
    func degenerateZeroHeightIgnored() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 4)), context: .empty)
        let outcome = tool.handle(.click(Vector(7, 4)), context: .empty)   // collapses to a line
        #expect(outcome == .none)
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first corner")
    }

    @Test("commit (Return) on an idle tool ends the run and finishes")
    func commitFinishes() {
        var tool = RectangleTool()
        let outcome = tool.handle(.commit, context: .empty)   // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first corner")
    }

    @Test("backspace from a fixed first corner returns to the initial state")
    func backspaceRewinds() {
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify opposite corner")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify first corner")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = RectangleTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify first corner")
    }

    @Test("draw tool ignores a populated context (behavior unchanged with selection)")
    func drawToolIgnoresContext() {
        // A non-empty context (as if entities were selected) must NOT change a
        // draw tool's outcome — RectangleTool reads only the snapped points.
        let selected = EntityRecord(id: EntityID(42), kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(
            selected: [selected],
            entity: { id in id == EntityID(42) ? selected : nil },
            gridSpacing: 0.5
        )
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 5)), context: ctx))
        #expect(poly?.closed == true)
        #expect(poly?.vertices.map(\.point) == [Vector(0, 0), Vector(10, 0), Vector(10, 5), Vector(0, 5)])
    }
}
