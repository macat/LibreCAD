//
//  EllipseToolTests.swift
//  CADEngineTests
//
//  Drives the center + major-axis-endpoint + minor-point `EllipseTool` PURELY
//  (no GUI): feeds `ToolInput` events + a read-only `ToolContext` and asserts the
//  committed geometry (a FULL `.ellipse` with the exact center, relative majorP,
//  and minor/major ratio), the live closed elliptical preview, the
//  re-arm-after-commit behavior, cancel/backspace resets, the degenerate guards,
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

@Suite("EllipseTool interactive draw")
struct EllipseToolTests {

    // MARK: - Helpers

    /// Pulls the single EllipseData out of a `.commit` outcome (returns nil if the
    /// outcome isn't a one-edit `.add` ellipse commit).
    private func committedEllipse(_ outcome: ToolOutcome) -> EllipseData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .ellipse(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status / title

    @Test("status walks center → first axis endpoint → minor axis distance")
    func statusTransitions() {
        var tool = EllipseTool()
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify first axis endpoint")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify minor axis distance")
    }

    @Test("title is Ellipse")
    func title() {
        #expect(EllipseTool().title == "Ellipse")
    }

    // MARK: - Center + major + minor commit (the brief's canonical case)

    @Test("center (0,0), major endpoint (10,0), minor point (0,5) → ratio 0.5")
    func threeClicksCommit() {
        var tool = EllipseTool()
        let center = Vector(0, 0)

        let first = tool.handle(.click(center), context: .empty)
        #expect(first == .none)   // first click only fixes the center

        let second = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(second == .none)  // second click only fixes the major axis

        let third = tool.handle(.click(Vector(0, 5)), context: .empty)
        let ellipse = committedEllipse(third)
        #expect(ellipse != nil)
        #expect(ellipse?.center == center)
        #expect(ellipse?.majorP == Vector(10, 0))      // RELATIVE to center
        #expect(ellipse?.majorRadius == 10)
        #expect(abs((ellipse?.ratio ?? 0) - 0.5) < 1e-9)
        #expect(abs((ellipse?.minorRadius ?? 0) - 5) < 1e-9)
    }

    @Test("majorP is RELATIVE to the center (offset center)")
    func majorPIsRelative() {
        var tool = EllipseTool()
        let center = Vector(3, 7)
        _ = tool.handle(.click(center), context: .empty)
        _ = tool.handle(.click(Vector(3 + 10, 7)), context: .empty)   // +X by 10
        let ellipse = committedEllipse(tool.handle(.click(Vector(3, 7 + 4)), context: .empty))
        #expect(ellipse?.center == center)
        #expect(ellipse?.majorP == Vector(10, 0))      // relative, not absolute
        #expect(abs((ellipse?.ratio ?? 0) - 0.4) < 1e-9)
    }

    @Test("ratio is the perpendicular distance to the major-axis line over |majorP|")
    func ratioIsPerpendicularDistance() {
        // Major axis along +X (len 10); a minor point off the line at (7, 3): its
        // perpendicular distance to the X axis is 3, so ratio = 3 / 10 = 0.3.
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let ellipse = committedEllipse(tool.handle(.click(Vector(7, 3)), context: .empty))
        #expect(abs((ellipse?.ratio ?? 0) - 0.3) < 1e-9)
    }

    @Test("ratio uses perpendicular distance even for a rotated major axis")
    func ratioForRotatedMajorAxis() {
        // Major axis along +Y (rotated 90°), len 10. A minor point at (4, 6): its
        // perpendicular distance to the Y axis is 4, so ratio = 4 / 10 = 0.4.
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        let ellipse = committedEllipse(tool.handle(.click(Vector(4, 6)), context: .empty))
        #expect(ellipse?.majorP == Vector(0, 10))
        #expect(abs((ellipse?.ratio ?? 0) - 0.4) < 1e-9)
    }

    @Test("ratio is clamped to 1 when the minor point is farther than the major radius")
    func ratioClampedToOne() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 0)), context: .empty)         // major radius 5
        let ellipse = committedEllipse(tool.handle(.click(Vector(0, 20)), context: .empty)) // perp 20
        #expect(ellipse?.ratio == 1.0)
    }

    @Test("full ellipse is encoded as startAngle == endAngle == 0 (isArc == false)")
    func fullEllipseEncoding() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let ellipse = committedEllipse(tool.handle(.click(Vector(0, 5)), context: .empty))
        #expect(ellipse?.startAngle == 0)
        #expect(ellipse?.endAngle == 0)
        #expect(ellipse?.reversed == false)
        #expect(ellipse?.isArc == false)   // the whole-ellipse convention
    }

    @Test("committed record carries the placeholder id and EntityRecord defaults")
    func commitUsesPlaceholderID() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(0, 5)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
        // Common attrs match the LineTool/EntityRecord defaults (consistency).
        #expect(record.layer == .zero)
        #expect(record.pen == .byLayer)
        #expect(record.flags == .default)
    }

    // MARK: - Re-arm after commit

    @Test("after committing an ellipse the tool re-arms to specify a new center")
    func reArmsAfterCommit() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(0, 5)), context: .empty)
        #expect(committedEllipse(outcome) != nil)
        // Back to the initial state, preview cleared, ready for the next ellipse.
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)

        // A second ellipse can be drawn immediately.
        _ = tool.handle(.click(Vector(20, 20)), context: .empty)
        _ = tool.handle(.click(Vector(28, 20)), context: .empty)   // major radius 8
        let ellipse2 = committedEllipse(tool.handle(.click(Vector(20, 24)), context: .empty)) // perp 4
        #expect(ellipse2?.center == Vector(20, 20))
        #expect(ellipse2?.majorP == Vector(8, 0))
        #expect(abs((ellipse2?.ratio ?? 0) - 0.5) < 1e-9)
    }

    // MARK: - Preview (closed rubber-band ellipse)

    @Test("preview is empty before and during the first two picks")
    func previewEmptyEarly() {
        var tool = EllipseTool()
        #expect(tool.preview.isEmpty)
        // Move with nothing fixed → nothing.
        #expect(tool.handle(.move(Vector(3, 3)), context: .empty) == .none)
        #expect(tool.preview.isEmpty)
        // After only the center is set, a move still shows nothing (no major axis).
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.handle(.move(Vector(5, 0)), context: .empty) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the major axis is set a move produces a CLOSED elliptical preview")
    func previewAfterMajor() {
        var tool = EllipseTool()
        let center = Vector(0, 0)
        _ = tool.handle(.click(center), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)   // majorP (10,0)

        let outcome = tool.handle(.move(Vector(0, 5)), context: .empty)   // ratio 0.5
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.closed == true)
        // Tessellated ellipse: at least a triangle's worth of points.
        #expect(poly.points.count >= 3)

        // The preview points fit the ellipse: extents ±10 in x, ±5 in y, and every
        // point satisfies (x/10)² + (y/5)² ≈ 1.
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in poly.points {
            maxX = Swift.max(maxX, abs(p.x))
            maxY = Swift.max(maxY, abs(p.y))
            let onCurve = (p.x / 10.0) * (p.x / 10.0) + (p.y / 5.0) * (p.y / 5.0)
            #expect(abs(onCurve - 1.0) < 1e-6)
        }
        #expect(abs(maxX - 10) < 1e-6)   // x extent reaches ±10
        #expect(abs(maxY - 5) < 1e-6)    // y extent reaches ±5
    }

    @Test("preview ratio follows the cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(0, 2)), context: .empty)
        _ = tool.handle(.move(Vector(0, 8)), context: .empty)   // ratio now 0.8

        let poly = tool.preview[0]
        var maxY = -Double.greatestFiniteMagnitude
        for p in poly.points { maxY = Swift.max(maxY, abs(p.y)) }
        #expect(abs(maxY - 8) < 1e-6)   // minor radius 8 = 10 * 0.8
    }

    @Test("preview is empty while the cursor is on the major-axis line (ratio 0)")
    func previewEmptyAtZeroRatio() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        // Cursor on the X axis → perpendicular distance 0 → ratio 0.
        let outcome = tool.handle(.move(Vector(4, 0)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Degenerate guards

    @Test("a zero-length major axis (second click on center) does not advance")
    func zeroMajorClickIgnored() {
        var tool = EllipseTool()
        let center = Vector(3, 3)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.click(center), context: .empty)   // same point
        #expect(outcome == .none)
        // Still waiting for the first axis endpoint — center stays fixed.
        #expect(tool.status == "Specify first axis endpoint")
    }

    @Test("a degenerate (ratio 0) minor click does not commit")
    func zeroRatioClickIgnored() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        // Minor point on the major-axis line → ratio 0 → ignored.
        let outcome = tool.handle(.click(Vector(5, 0)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify minor axis distance")
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(0, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("commit while idle ends the run and finishes")
    func commitFinishes() {
        var tool = EllipseTool()
        let outcome = tool.handle(.commit, context: .empty)   // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("backspace steps back one pick at a time")
    func backspaceRewinds() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify minor axis distance")

        // First backspace: undo the major-axis pick → back to first-endpoint.
        let one = tool.handle(.backspace, context: .empty)
        #expect(one == .preview)
        #expect(tool.status == "Specify first axis endpoint")
        #expect(tool.preview.isEmpty)

        // Second backspace: undo the center pick → back to the initial state.
        let two = tool.handle(.backspace, context: .empty)
        #expect(two == .preview)
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = EllipseTool()
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
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        _ = tool.handle(.click(Vector(1 + 10, 2)), context: ctx)
        let ellipse = committedEllipse(tool.handle(.click(Vector(1, 2 + 5)), context: ctx))
        #expect(ellipse?.center == Vector(1, 2))
        #expect(ellipse?.majorP == Vector(10, 0))
        #expect(abs((ellipse?.ratio ?? 0) - 0.5) < 1e-9)
    }
}
