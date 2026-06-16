//
//  CircleToolTests.swift
//  CADEngineTests
//
//  Drives the center+radius `CircleTool` PURELY (no GUI): feeds `ToolInput`
//  events + a read-only `ToolContext` and asserts the committed geometry (a
//  `.circle` with the exact center + radius), the live circular preview, the
//  re-arm-after-commit behavior, cancel/backspace resets, the zero-radius guard,
//  and the status prompt transitions.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CircleTool interactive draw")
struct CircleToolTests {

    // MARK: - Helpers

    /// Pulls the single CircleData out of a `.commit` outcome (returns nil if the
    /// outcome isn't a one-edit `.add` circle commit).
    private func committedCircle(_ outcome: ToolOutcome) -> CircleData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .circle(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status / title

    @Test("status starts at 'Specify center point' and advances after the first click")
    func statusTransitions() {
        var tool = CircleTool()
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify radius")
    }

    @Test("title is Circle")
    func title() {
        #expect(CircleTool().title == "Circle")
    }

    // MARK: - Center + radius commit

    @Test("two clicks commit a circle with the exact center and radius")
    func twoClicksCommit() {
        var tool = CircleTool()
        let center = Vector(2, 3)
        let onCircle = Vector(2 + 5, 3)   // radius 5 along +X

        let first = tool.handle(.click(center), context: .empty)
        #expect(first == .none)   // first click only fixes the center

        let second = tool.handle(.click(onCircle), context: .empty)
        let circle = committedCircle(second)
        #expect(circle != nil)
        #expect(circle?.center == center)
        #expect(circle?.radius == 5)
    }

    @Test("radius is the distance from center to the second click (diagonal)")
    func radiusIsDistance() {
        var tool = CircleTool()
        let center = Vector(0, 0)
        let onCircle = Vector(3, 4)   // distance 5

        _ = tool.handle(.click(center), context: .empty)
        let circle = committedCircle(tool.handle(.click(onCircle), context: .empty))
        #expect(circle?.center == center)
        #expect(circle?.radius == 5)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = CircleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(4, 0)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
        // A draw tool emits the EntityRecord INIT defaults — layer "0" + a fully
        // `.byLayer` pen. This is the tool's *raw* output BEFORE the app applies it:
        // `CanvasModel.applyCommit` STAMPS such a default record with the active layer
        // + the model's `currentPen` (so drawn geometry lands on the active layer, not
        // always "0" — the post-stamp behavior is covered by `PenPropertiesTests`).
        // The stamp keys off exactly these defaults, so the tool MUST keep emitting them.
        #expect(record.layer == .zero)
        #expect(record.pen == .byLayer)
        #expect(record.flags == .default)
    }

    // MARK: - Re-arm after commit

    @Test("after committing a circle the tool re-arms to specify a new center")
    func reArmsAfterCommit() {
        var tool = CircleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(5, 0)), context: .empty)
        #expect(committedCircle(outcome) != nil)
        // Back to the initial state, preview cleared, ready for the next circle.
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)

        // A second circle can be drawn immediately.
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        let circle2 = committedCircle(tool.handle(.click(Vector(13, 14)), context: .empty))
        #expect(circle2?.center == Vector(10, 10))
        #expect(circle2?.radius == 5)
    }

    // MARK: - Preview (rubber-band circle)

    @Test("preview is empty before the center is set")
    func previewEmptyInitially() {
        var tool = CircleTool()
        #expect(tool.preview.isEmpty)
        // A move with no center still shows nothing.
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the center is set a move produces a CLOSED circular preview")
    func previewAfterCenter() {
        var tool = CircleTool()
        let center = Vector(1, 1)
        _ = tool.handle(.click(center), context: .empty)

        let cursor = Vector(1 + 4, 1)   // radius 4
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.closed == true)
        // Tessellated circle: at least a triangle's worth of points.
        #expect(poly.points.count >= 3)
        // Every preview vertex lies ~radius from the center.
        let radius = (cursor - center).magnitude
        for p in poly.points {
            #expect(abs((p - center).magnitude - radius) < 1e-6)
        }
    }

    @Test("preview radius follows the cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = CircleTool()
        let center = Vector(0, 0)
        _ = tool.handle(.click(center), context: .empty)
        _ = tool.handle(.move(Vector(2, 0)), context: .empty)
        _ = tool.handle(.move(Vector(7, 0)), context: .empty)   // radius now 7

        let poly = tool.preview[0]
        for p in poly.points {
            #expect(abs((p - center).magnitude - 7) < 1e-6)
        }
    }

    @Test("preview is empty while the radius is still zero (cursor on center)")
    func previewEmptyAtZeroRadius() {
        var tool = CircleTool()
        let center = Vector(5, 5)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.move(center), context: .empty)   // cursor == center
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Zero-radius guard

    @Test("a degenerate (zero-radius) second click does not commit")
    func zeroRadiusClickIgnored() {
        var tool = CircleTool()
        let center = Vector(3, 3)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.click(center), context: .empty)   // same point
        #expect(outcome == .none)
        // Still waiting for a (nonzero) radius — center stays fixed.
        #expect(tool.status == "Specify radius")
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = CircleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("commit while idle ends the run and finishes")
    func commitFinishes() {
        var tool = CircleTool()
        let outcome = tool.handle(.commit, context: .empty)   // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("backspace after the center is set returns to the initial state")
    func backspaceRewinds() {
        var tool = CircleTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify radius")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = CircleTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify center point")
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
        var tool = CircleTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        let circle = committedCircle(tool.handle(.click(Vector(1, 2 + 6)), context: ctx))
        #expect(circle?.center == Vector(1, 2))
        #expect(circle?.radius == 6)
    }
}
