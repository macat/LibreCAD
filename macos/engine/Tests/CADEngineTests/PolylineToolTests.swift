//
//  PolylineToolTests.swift
//  CADEngineTests
//
//  Drives the interactive `PolylineTool` PURELY (no GUI): feeds `ToolInput`
//  events + a read-only `ToolContext` and asserts the outcomes, the live preview
//  (committed vertices + rubber-band), the single-polyline commit, backspace /
//  cancel resets, and the status prompt transitions.
//
//  Unlike `LineTool` (a chain of separate `.line` entities), `PolylineTool`
//  accumulates all clicks into ONE `.polyline` entity emitted on `.commit`.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("PolylineTool interactive draw")
struct PolylineToolTests {

    // MARK: - Helpers

    /// Pulls the single `PolylineData` out of a `.commit` outcome (fails the test
    /// if the outcome isn't a one-edit `.add` polyline commit).
    private func committedPolyline(_ outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Title / status transitions

    @Test("title is Polyline")
    func title() {
        #expect(PolylineTool().title == "Polyline")
    }

    @Test("status starts at 'Specify first point' and advances after the first click")
    func statusTransitions() {
        var tool = PolylineTool()
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify next point (Return to finish)")
    }

    // MARK: - Accumulate vertices → ONE polyline

    @Test("three clicks then commit produce ONE polyline of 3 vertices in order, open")
    func threeClicksCommitOnePolyline() {
        var tool = PolylineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(10, 10)

        // Each click only accumulates — no geometry committed per click.
        #expect(tool.handle(.click(p0), context: .empty) == .none)
        #expect(tool.handle(.click(p1), context: .empty) == .none)
        #expect(tool.handle(.click(p2), context: .empty) == .none)

        // Return → ONE polyline carrying all three vertices in order.
        let outcome = tool.handle(.commit, context: .empty)
        let poly = committedPolyline(outcome)
        #expect(poly != nil)
        #expect(poly?.closed == false)
        #expect(poly?.vertices.count == 3)
        #expect(poly?.vertices[0].point == p0)
        #expect(poly?.vertices[1].point == p1)
        #expect(poly?.vertices[2].point == p2)
        // Straight segments → all bulges are 0.
        #expect(poly?.vertices.allSatisfy { $0.bulge == 0 } == true)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 0)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
    }

    @Test("after committing, the tool resets ready for a fresh run")
    func resetsAfterCommit() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.commit, context: .empty)
        #expect(tool.status == "Specify first point")
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Preview (committed vertices + rubber-band)

    @Test("preview is empty before the first click")
    func previewEmptyInitially() {
        var tool = PolylineTool()
        #expect(tool.preview.isEmpty)
        // A move with no fixed vertex still shows nothing.
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview while building includes the committed vertices plus a rubber-band to the cursor")
    func previewIncludesRubberBand() {
        var tool = PolylineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)

        let cursor = Vector(10, 5)
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.closed == false)
        // Two committed vertices + the rubber-band point = 3 points.
        #expect(poly.points.count == 3)
        #expect(poly.points[0] == p0)
        #expect(poly.points[1] == p1)
        #expect(poly.points[2] == cursor)
    }

    @Test("preview rubber-band follows the cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(1, 1)), context: .empty)
        _ = tool.handle(.move(Vector(8, 3)), context: .empty)
        #expect(tool.preview[0].points.last == Vector(8, 3))
    }

    // MARK: - Backspace removes the last vertex

    @Test("backspace removes the last vertex")
    func backspaceRemovesLastVertex() {
        var tool = PolylineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(10, 10)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)

        // Drop p2.
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)

        // Committing now yields a 2-vertex polyline (p0, p1) — p2 is gone.
        let poly = committedPolyline(tool.handle(.commit, context: .empty))
        #expect(poly?.vertices.count == 2)
        #expect(poly?.vertices[0].point == p0)
        #expect(poly?.vertices[1].point == p1)
    }

    @Test("backspace down to zero vertices returns to the initial state")
    func backspaceToEmpty() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify next point (Return to finish)")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify first point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = PolylineTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Commit with too few vertices emits no geometry

    @Test("commit with no vertices finishes and emits no geometry")
    func commitEmptyEmitsNothing() {
        var tool = PolylineTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.status == "Specify first point")
    }

    @Test("commit with a single vertex finishes and emits no geometry")
    func commitSingleVertexEmitsNothing() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(committedPolyline(outcome) == nil)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Cancel resets

    @Test("cancel discards the in-progress run and finishes")
    func cancelResets() {
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Degenerate clicks

    @Test("a degenerate (zero-length) repeat of the last vertex is ignored")
    func degenerateRepeatIgnored() {
        var tool = PolylineTool()
        let p = Vector(3, 3)
        _ = tool.handle(.click(p), context: .empty)
        let outcome = tool.handle(.click(p), context: .empty)   // same point
        #expect(outcome == .none)
        // Only the first vertex was recorded; another distinct click then commit
        // yields a 2-vertex polyline.
        _ = tool.handle(.click(Vector(9, 3)), context: .empty)
        let poly = committedPolyline(tool.handle(.commit, context: .empty))
        #expect(poly?.vertices.count == 2)
    }

    // MARK: - Optional closing (click near the first vertex)

    @Test("clicking near the first vertex closes the loop and commits")
    func clickNearFirstCloses() {
        var tool = PolylineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(10, 10)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)

        // Click back on the first vertex → closed polyline committed immediately.
        let poly = committedPolyline(tool.handle(.click(p0), context: .empty))
        #expect(poly != nil)
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 3)   // first vertex not duplicated
    }

    // MARK: - Draw tool ignores context

    @Test("draw tool ignores a populated context (behavior unchanged with selection)")
    func drawToolIgnoresContext() {
        let selected = EntityRecord(
            id: EntityID(42),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))
        )
        let ctx = ToolContext(
            selected: [selected],
            entity: { id in id == EntityID(42) ? selected : nil },
            gridSpacing: 0.5
        )
        var tool = PolylineTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        _ = tool.handle(.click(Vector(7, 9)), context: ctx)
        let poly = committedPolyline(tool.handle(.commit, context: ctx))
        #expect(poly?.vertices.count == 2)
        #expect(poly?.vertices[0].point == Vector(1, 2))
        #expect(poly?.vertices[1].point == Vector(7, 9))
    }
}
