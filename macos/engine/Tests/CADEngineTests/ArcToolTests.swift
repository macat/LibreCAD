//
//  ArcToolTests.swift
//  CADEngineTests
//
//  Drives the `ArcTool` (center → start → end, CCW) PURELY (no GUI): feeds
//  `ToolInput` events + a read-only `ToolContext` and asserts the committed arc
//  geometry (center / radius / start & end angle / reversed), the live preview
//  sweep, the cancel/backspace resets, the degenerate-pick guard, and the status
//  prompt transitions.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ArcTool interactive draw")
struct ArcToolTests {

    // MARK: - Helpers

    /// Pulls the single `ArcData` out of a `.commit` outcome (fails the assertion
    /// at the call site if the outcome isn't a one-edit `.add` arc commit).
    private func committedArc(_ outcome: ToolOutcome) -> ArcData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .arc(let d) = record.kind else { return nil }
        return d
    }

    /// Drives center → start → end and returns the committed arc.
    private func drawArc(
        center: Vector, start: Vector, end: Vector
    ) -> (tool: ArcTool, outcome: ToolOutcome) {
        var tool = ArcTool()
        _ = tool.handle(.click(center), context: .empty)
        _ = tool.handle(.click(start), context: .empty)
        let outcome = tool.handle(.click(end), context: .empty)
        return (tool, outcome)
    }

    // MARK: - Status transitions

    @Test("status walks center → start → end and resets after a commit")
    func statusTransitions() {
        var tool = ArcTool()
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify start point")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify end angle")
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        // Committed → back to the initial prompt for the next arc.
        #expect(tool.status == "Specify center point")
    }

    @Test("title is Arc")
    func title() {
        #expect(ArcTool().title == "Arc")
    }

    // MARK: - Three-click commit (known geometry)

    @Test("center origin, start (10,0), end (0,10) commits a CCW quarter arc")
    func quarterArcCommit() {
        let (_, outcome) = drawArc(center: Vector(0, 0), start: Vector(10, 0), end: Vector(0, 10))
        let arc = committedArc(outcome)
        #expect(arc != nil)
        #expect(arc?.center == Vector(0, 0))
        #expect(abs((arc?.radius ?? 0) - 10) < 1e-9)
        #expect(abs((arc?.startAngle ?? .nan) - 0) < 1e-9)
        #expect(abs((arc?.endAngle ?? .nan) - Double.pi / 2) < 1e-9)
        #expect(arc?.reversed == false)
    }

    @Test("radius and start angle come from the start pick relative to the center")
    func radiusAndStartAngleFromStartPick() {
        // Center (2,2); start at (2,2)+(3,4) → radius 5, startAngle = atan2(4,3).
        let center = Vector(2, 2)
        let start = Vector(5, 6)            // center + (3, 4)
        let end = Vector(2 - 5, 2)          // center + (-5, 0) → endAngle = π
        let (_, outcome) = drawArc(center: center, start: start, end: end)
        let arc = committedArc(outcome)
        #expect(arc != nil)
        #expect(arc?.center == center)
        #expect(abs((arc?.radius ?? 0) - 5) < 1e-9)
        #expect(abs((arc?.startAngle ?? .nan) - atan2(4, 3)) < 1e-9)
        #expect(abs((arc?.endAngle ?? .nan) - Double.pi) < 1e-9)
        #expect(arc?.reversed == false)
    }

    @Test("first two clicks do not commit (only the third produces geometry)")
    func firstTwoClicksDoNotCommit() {
        var tool = ArcTool()
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        let (_, outcome) = drawArc(center: Vector(0, 0), start: Vector(4, 0), end: Vector(0, 4))
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
    }

    // MARK: - Preview (rubber-band arc)

    @Test("preview is empty before the start point is fixed")
    func previewEmptyBeforeStart() {
        var tool = ArcTool()
        #expect(tool.preview.isEmpty)
        // After the center click a move still shows nothing (no radius yet).
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the start pick a move previews a CCW arc spanning the right sweep")
    func previewArcSweep() {
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // center
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)  // start → radius 10, startAngle 0

        let outcome = tool.handle(.move(Vector(0, 10)), context: .empty)  // cursor → endAngle π/2
        #expect(outcome == .preview)
        #expect(tool.preview.count == 1)

        let poly = tool.preview[0]
        #expect(poly.closed == false)
        #expect(poly.points.count >= 2)
        // Endpoints lie on the circle at startAngle (10,0) and endAngle (0,10).
        let first = poly.points.first!
        let last = poly.points.last!
        #expect(abs(first.x - 10) < 1e-6 && abs(first.y - 0) < 1e-6)
        #expect(abs(last.x - 0) < 1e-6 && abs(last.y - 10) < 1e-6)
        // Every sample is on the radius-10 circle and in the CCW first quadrant.
        for pt in poly.points {
            #expect(abs((pt - Vector(0, 0)).magnitude - 10) < 1e-6)
            #expect(pt.x >= -1e-6 && pt.y >= -1e-6)
        }
    }

    @Test("preview follows the cursor (a wider sweep produces a wider arc)")
    func previewFollowsCursor() {
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)

        _ = tool.handle(.move(Vector(0, 10)), context: .empty)        // ~90° sweep
        let quarterCount = tool.preview[0].points.count
        _ = tool.handle(.move(Vector(-10, 0)), context: .empty)       // ~180° sweep
        let halfCount = tool.preview[0].points.count
        // A larger CCW sweep tessellates into more (or equal) segments.
        #expect(halfCount >= quarterCount)
        // The new endpoint tracks the new cursor angle (180° → (-10, 0)).
        let last = tool.preview[0].points.last!
        #expect(abs(last.x - (-10)) < 1e-6 && abs(last.y - 0) < 1e-6)
    }

    // MARK: - Degenerate (zero-radius) pick

    @Test("a zero-radius start pick (coincident with center) does not advance")
    func degenerateStartIgnored() {
        var tool = ArcTool()
        let center = Vector(3, 3)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.click(center), context: .empty)   // same point → zero radius
        #expect(outcome == .none)
        #expect(tool.status == "Specify start point")   // still waiting for a real start
        // A subsequent move shows no preview (no radius fixed yet).
        _ = tool.handle(.move(Vector(9, 9)), context: .empty)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(0, 10)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("commit when idle ends the tool and finishes (arcs commit on the 3rd click)")
    func commitFinishes() {
        var tool = ArcTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.status == "Specify center point")
    }

    @Test("backspace from the end-pick state steps back to the start pick (keeps center)")
    func backspaceStepsBackToStart() {
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // center
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)  // start
        #expect(tool.status == "Specify end angle")

        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify start point")
        // No radius is fixed now → a move shows no preview.
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace from the start-pick state returns to the initial center state")
    func backspaceStepsBackToCenter() {
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // center
        #expect(tool.status == "Specify start point")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = ArcTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify center point")
    }

    // MARK: - Context is ignored (draw tool)

    @Test("draw tool ignores a populated context (behavior unchanged with selection)")
    func drawToolIgnoresContext() {
        let selected = EntityRecord(id: EntityID(7), kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(
            selected: [selected],
            entity: { id in id == EntityID(7) ? selected : nil },
            gridSpacing: 0.5
        )
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(10, 0)), context: ctx)
        let arc = committedArc(tool.handle(.click(Vector(0, 10)), context: ctx))
        #expect(arc?.center == Vector(0, 0))
        #expect(abs((arc?.radius ?? 0) - 10) < 1e-9)
        #expect(abs((arc?.endAngle ?? .nan) - Double.pi / 2) < 1e-9)
    }

    // MARK: - Chaining (resets for the next arc)

    @Test("after committing, the tool is ready to draw a fresh arc")
    func resetsForNextArc() {
        var tool = ArcTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)   // commit #1
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)

        // A second full sequence commits another arc with its own geometry.
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)
        _ = tool.handle(.click(Vector(5, 8)), context: .empty)    // radius 3, startAngle π/2
        let arc = committedArc(tool.handle(.click(Vector(8, 5)), context: .empty))  // endAngle 0
        #expect(arc?.center == Vector(5, 5))
        #expect(abs((arc?.radius ?? 0) - 3) < 1e-9)
        #expect(abs((arc?.startAngle ?? .nan) - Double.pi / 2) < 1e-9)
        #expect(abs((arc?.endAngle ?? .nan) - 0) < 1e-9)
    }
}
