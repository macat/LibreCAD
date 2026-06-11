//
//  PointToolTests.swift
//  CADEngineTests
//
//  Drives the Point draw tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` to `PointTool` and asserts the per-click commits,
//  that the tool stays active for the next point, the empty preview, the
//  cancel/commit teardown, and the status prompt.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("PointTool interactive draw")
struct PointToolTests {

    // MARK: - Helpers

    /// Pulls the single PointData out of a `.commit` outcome (fails the test if
    /// the outcome isn't a one-edit `.add` point commit).
    private func committedPoint(_ outcome: ToolOutcome) -> PointData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .point(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status / title

    @Test("status is 'Specify point location'")
    func status() {
        let tool = PointTool()
        #expect(tool.status == "Specify point location")
    }

    @Test("title is Point")
    func title() {
        #expect(PointTool().title == "Point")
    }

    // MARK: - Click places a point

    @Test("a click commits a single point at the exact clicked location")
    func clickCommitsPoint() {
        var tool = PointTool()
        let p = Vector(3, 7)
        let outcome = tool.handle(.click(p), context: .empty)
        let point = committedPoint(outcome)
        #expect(point != nil)
        #expect(point?.position == p)
    }

    @Test("a click commits exactly one .add edit with a .point kind")
    func clickCommitsOneAddPoint() {
        var tool = PointTool()
        let outcome = tool.handle(.click(Vector(1, 1)), context: .empty)
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a .commit outcome"); return
        }
        #expect(edits.count == 1)
        guard case .add(let record) = edits[0] else {
            Issue.record("expected an .add edit"); return
        }
        guard case .point = record.kind else {
            Issue.record("expected a .point entity kind"); return
        }
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = PointTool()
        let outcome = tool.handle(.click(Vector(0, 0)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome"); return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
    }

    @Test("committed record carries the same layer/pen/flags defaults as a draw record")
    func commitRecordAttributes() {
        var tool = PointTool()
        let outcome = tool.handle(.click(Vector(2, 2)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome"); return
        }
        // EXACTLY the LineTool defaults (EntityRecord's own defaults).
        #expect(record.layer == .zero)
        #expect(record.pen == .byLayer)
        #expect(record.flags == .default)
    }

    // MARK: - Stays active for the next point (multiple clicks)

    @Test("multiple clicks each commit a point and the tool stays active")
    func multipleClicksStayActive() {
        var tool = PointTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(5, 1)
        let p2 = Vector(9, 4)

        let first = committedPoint(tool.handle(.click(p0), context: .empty))
        #expect(first?.position == p0)
        // NOT finished — still placing points.
        #expect(tool.status == "Specify point location")

        let second = committedPoint(tool.handle(.click(p1), context: .empty))
        #expect(second?.position == p1)
        #expect(tool.status == "Specify point location")

        let third = committedPoint(tool.handle(.click(p2), context: .empty))
        #expect(third?.position == p2)
        #expect(tool.status == "Specify point location")
    }

    @Test("a click never returns .finished (it stays active to place the next point)")
    func clickNeverFinishes() {
        var tool = PointTool()
        let outcome = tool.handle(.click(Vector(1, 2)), context: .empty)
        #expect(outcome != .finished)
    }

    // MARK: - Preview (a point has no rubber-band)

    @Test("preview is always empty (a point has no rubber-band)")
    func previewAlwaysEmpty() {
        var tool = PointTool()
        #expect(tool.preview.isEmpty)
        let outcome = tool.handle(.move(Vector(4, 4)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
        // A move after a click still shows no preview.
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(8, 8)), context: .empty)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Move / backspace are no-ops

    @Test("a move does nothing (.none)")
    func moveIsNoop() {
        var tool = PointTool()
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
    }

    @Test("backspace is a no-op (.none)")
    func backspaceNoop() {
        var tool = PointTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
    }

    // MARK: - Commit / cancel finish

    @Test("commit ends the run and finishes (each point already committed on its click)")
    func commitFinishes() {
        var tool = PointTool()
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)   // already committed
        let outcome = tool.handle(.commit, context: .empty)       // Return → end run
        #expect(outcome == .finished)
        #expect(tool.status == "Specify point location")
    }

    @Test("cancel ends the run and finishes")
    func cancelFinishes() {
        var tool = PointTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
    }

    // MARK: - Context is ignored (draw tool)

    @Test("draw tool ignores a populated context (behavior unchanged with selection)")
    func drawToolIgnoresContext() {
        let selected = EntityRecord(id: EntityID(42), kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(
            selected: [selected],
            entity: { id in id == EntityID(42) ? selected : nil },
            gridSpacing: 0.5
        )
        var tool = PointTool()
        let point = committedPoint(tool.handle(.click(Vector(6, 8)), context: ctx))
        #expect(point?.position == Vector(6, 8))
    }
}
