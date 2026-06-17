//
//  SplineToolTests.swift
//  CADEngineTests
//
//  Drives the interactive `SplineTool` PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` and asserts the outcomes, the live preview (a
//  tessellated interpolation spline through the fit points + cursor), the single
//  `.splinePoints` commit, backspace / cancel resets, closing on the first point,
//  and the status prompt transitions.
//
//  Like `PolylineTool`, `SplineTool` accumulates all clicks into ONE entity emitted
//  on `.commit` — but a `.splinePoints` (fit-point interpolation) entity drawn as a
//  smooth curve rather than straight segments.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("SplineTool interactive draw")
struct SplineToolTests {

    // MARK: - Helpers

    /// Pulls the single `SplinePointsData` out of a `.commit` outcome (fails the
    /// test if the outcome isn't a one-edit `.add` splinePoints commit).
    private func committedSpline(_ outcome: ToolOutcome) -> SplinePointsData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .splinePoints(let d) = record.kind else { return nil }
        return d
    }

    /// Pulls the single `SplineData` (NURBS) out of a `.commit` outcome (fails the
    /// test if the outcome isn't a one-edit `.add` `.spline` commit).
    private func committedNURBS(_ outcome: ToolOutcome) -> SplineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .spline(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Title / status transitions

    @Test("title is Spline")
    func title() {
        #expect(SplineTool().title == "Spline")
    }

    @Test("status starts at 'Specify first point' and advances after the first click")
    func statusTransitions() {
        var tool = SplineTool()
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify next point (Return to finish)")
    }

    // MARK: - Accumulate fit points → ONE splinePoints entity

    @Test("four clicks then commit produce ONE splinePoints carrying the fit points in order, open")
    func fourClicksCommitOneSpline() {
        var tool = SplineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 5)
        let p2 = Vector(20, -5)
        let p3 = Vector(30, 0)

        // Each click only accumulates — no geometry committed per click.
        #expect(tool.handle(.click(p0), context: .empty) == .none)
        #expect(tool.handle(.click(p1), context: .empty) == .none)
        #expect(tool.handle(.click(p2), context: .empty) == .none)
        #expect(tool.handle(.click(p3), context: .empty) == .none)

        // Return → ONE splinePoints entity carrying all four fit points in order.
        let outcome = tool.handle(.commit, context: .empty)
        let spline = committedSpline(outcome)
        #expect(spline != nil)
        #expect(spline?.closed == false)
        #expect(spline?.controlPoints.count == 4)
        #expect(spline?.controlPoints[0] == p0)
        #expect(spline?.controlPoints[1] == p1)
        #expect(spline?.controlPoints[2] == p2)
        #expect(spline?.controlPoints[3] == p3)
    }

    @Test("two clicks then commit produce a 2-point splinePoints entity")
    func twoClicksCommit() {
        var tool = SplineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(8, 8)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        let spline = committedSpline(tool.handle(.commit, context: .empty))
        #expect(spline?.controlPoints.count == 2)
        #expect(spline?.controlPoints[0] == p0)
        #expect(spline?.controlPoints[1] == p1)
    }

    @Test("the committed splinePoints resolves to a non-empty curve")
    func committedSplineResolves() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        _ = tool.handle(.click(Vector(20, 0)), context: .empty)
        _ = tool.handle(.click(Vector(30, 10)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        // The resolve path tessellates it into a smooth polyline (more points than
        // the four fit points) — confirms the produced data is renderable.
        let geometry = record.resolve()
        #expect(geometry.polylines.count == 1)
        #expect((geometry.polylines.first?.points.count ?? 0) > 4)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = SplineTool()
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
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.commit, context: .empty)
        #expect(tool.status == "Specify first point")
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Preview (tessellated curve through fit points + cursor)

    @Test("preview is empty before the first click")
    func previewEmptyInitially() {
        var tool = SplineTool()
        #expect(tool.preview.isEmpty)
        // A move with no fixed point still shows nothing.
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview while building tessellates the fit points plus the cursor into one open curve")
    func previewIncludesCursorCurve() {
        var tool = SplineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(20, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)

        let cursor = Vector(30, 10)
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let curve = tool.preview[0]
        #expect(curve.closed == false)
        // Tessellated curve: more points than the 3 fixed + 1 cursor fit points,
        // and it interpolates the endpoints (starts at p0, ends at the cursor).
        #expect(curve.points.count > 4)
        #expect(curve.points.first == p0)
        #expect(curve.points.last == cursor)
    }

    @Test("preview follows the cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(1, 1)), context: .empty)
        _ = tool.handle(.move(Vector(20, 5)), context: .empty)
        #expect(tool.preview[0].points.last == Vector(20, 5))
    }

    @Test("preview matches the committed curve's tessellation for the same points")
    func previewMatchesCommittedCurve() {
        var tool = SplineTool()
        let pts = [Vector(0, 0), Vector(10, 10), Vector(20, 0), Vector(30, 10)]
        for p in pts.dropLast() {
            _ = tool.handle(.click(p), context: .empty)
        }
        // Cursor sits exactly on the would-be last fit point.
        _ = tool.handle(.move(pts.last!), context: .empty)
        let previewPoints = tool.preview[0].points

        // The committed entity for the same four points resolves identically.
        let record = EntityRecord(
            id: .placeholder,
            kind: .splinePoints(SplinePointsData(controlPoints: pts, closed: false))
        )
        let resolved = record.resolve().polylines[0].points
        #expect(previewPoints == resolved)
    }

    // MARK: - Backspace removes the last fit point

    @Test("backspace removes the last fit point")
    func backspaceRemovesLastPoint() {
        var tool = SplineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(10, 10)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)

        // Drop p2.
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)

        // Committing now yields a 2-point spline (p0, p1) — p2 is gone.
        let spline = committedSpline(tool.handle(.commit, context: .empty))
        #expect(spline?.controlPoints.count == 2)
        #expect(spline?.controlPoints[0] == p0)
        #expect(spline?.controlPoints[1] == p1)
    }

    @Test("backspace down to zero points returns to the initial state")
    func backspaceToEmpty() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify next point (Return to finish)")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify first point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = SplineTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Commit with too few points emits no geometry

    @Test("commit with no points finishes and emits no geometry")
    func commitEmptyEmitsNothing() {
        var tool = SplineTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.status == "Specify first point")
    }

    @Test("commit with a single point finishes and emits no geometry")
    func commitSinglePointEmitsNothing() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(committedSpline(outcome) == nil)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Cancel resets

    @Test("cancel discards the in-progress run and finishes")
    func cancelResets() {
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 5)), context: .empty)
        _ = tool.handle(.move(Vector(15, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Degenerate clicks

    @Test("a degenerate (coincident) repeat of the last point is ignored")
    func degenerateRepeatIgnored() {
        var tool = SplineTool()
        let p = Vector(3, 3)
        _ = tool.handle(.click(p), context: .empty)
        let outcome = tool.handle(.click(p), context: .empty)   // same point
        #expect(outcome == .none)
        // Only the first point was recorded; another distinct click then commit
        // yields a 2-point spline.
        _ = tool.handle(.click(Vector(9, 3)), context: .empty)
        let spline = committedSpline(tool.handle(.commit, context: .empty))
        #expect(spline?.controlPoints.count == 2)
    }

    // MARK: - Closing on the first point

    @Test("clicking near the first point (with 3+ points) closes the spline and commits")
    func clickNearFirstCloses() {
        var tool = SplineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(10, 10)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)

        // Click back on the first point → closed spline committed immediately.
        let spline = committedSpline(tool.handle(.click(p0), context: .empty))
        #expect(spline != nil)
        #expect(spline?.closed == true)
        #expect(spline?.controlPoints.count == 3)   // first point not duplicated
    }

    @Test("clicking near the first point with only 2 points does NOT close (treated as a new point)")
    func twoPointsDoesNotClose() {
        var tool = SplineTool()
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        // Clicking back near the first point with only 2 points: closing needs 3+,
        // and this click coincides with neither the last point, so it appends.
        let outcome = tool.handle(.click(p0), context: .empty)
        #expect(outcome == .none)   // appended, not committed
        let spline = committedSpline(tool.handle(.commit, context: .empty))
        #expect(spline?.closed == false)
        #expect(spline?.controlPoints.count == 3)
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
        var tool = SplineTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        _ = tool.handle(.click(Vector(7, 9)), context: ctx)
        let spline = committedSpline(tool.handle(.commit, context: ctx))
        #expect(spline?.controlPoints.count == 2)
        #expect(spline?.controlPoints[0] == Vector(1, 2))
        #expect(spline?.controlPoints[1] == Vector(7, 9))
    }

    // MARK: - Control-point (NURBS) mode

    @Test("default tool is fit mode (back-compatible)")
    func defaultModeIsFit() {
        #expect(SplineTool().mode == .fit)
    }

    @Test("fit mode still emits a .splinePoints entity (unchanged)")
    func fitModeStillEmitsSplinePoints() {
        var tool = SplineTool(mode: .fit)
        let pts = [Vector(0, 0), Vector(10, 5), Vector(20, -5), Vector(30, 0)]
        for p in pts { _ = tool.handle(.click(p), context: .empty) }
        let outcome = tool.handle(.commit, context: .empty)
        // It is a .splinePoints, NOT a .spline.
        #expect(committedSpline(outcome) != nil)
        #expect(committedNURBS(outcome) == nil)
        #expect(committedSpline(outcome)?.controlPoints == pts)
        #expect(committedSpline(outcome)?.closed == false)
    }

    @Test("control-point mode emits a .spline (NURBS) carrying the picks as control points")
    func controlPointModeEmitsNURBS() {
        var tool = SplineTool(mode: .controlPoints)
        let pts = [Vector(0, 0), Vector(10, 10), Vector(20, 0), Vector(30, 10)]
        for p in pts { _ = tool.handle(.click(p), context: .empty) }
        let outcome = tool.handle(.commit, context: .empty)
        // It is a .spline, NOT a .splinePoints.
        let nurbs = committedNURBS(outcome)
        #expect(nurbs != nil)
        #expect(committedSpline(outcome) == nil)
        #expect(nurbs?.controlPoints == pts)
        #expect(nurbs?.closed == false)
        // Four control points → the default cubic degree.
        #expect(nurbs?.degree == 3)
        // Empty knot/weight vectors: the resolver generates a clamped knot vector
        // and treats the spline as non-rational.
        #expect(nurbs?.knots.isEmpty == true)
        #expect(nurbs?.weights.isEmpty == true)
    }

    @Test("control-point mode commit resolves to a non-empty smooth curve")
    func controlPointModeResolvesToCurve() {
        var tool = SplineTool(mode: .controlPoints)
        let pts = [Vector(0, 0), Vector(10, 10), Vector(20, 0), Vector(30, 10)]
        for p in pts { _ = tool.handle(.click(p), context: .empty) }
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        // The NURBS resolve path tessellates the control polygon into a smooth
        // polyline with MANY more points than the four control points — proving the
        // emitted degree/knot contract yields a valid, renderable curve.
        let geometry = record.resolve()
        #expect(geometry.polylines.count == 1)
        #expect((geometry.polylines.first?.points.count ?? 0) > 4)
        // A clamped knot vector interpolates the endpoints: the tessellation starts
        // at the first control point and ends at the last.
        #expect(geometry.polylines.first?.points.first == pts.first)
        #expect(geometry.polylines.first?.points.last == pts.last)
    }

    @Test("control-point degree is clamped down so few picks still resolve")
    func controlPointDegreeClamping() {
        // The pure degree helper: cubic by default, clamped to count − 1 (≥ 1).
        #expect(SplineTool.degree(forControlPointCount: 2) == 1)   // line-like
        #expect(SplineTool.degree(forControlPointCount: 3) == 2)   // quadratic
        #expect(SplineTool.degree(forControlPointCount: 4) == 3)   // cubic (default)
        #expect(SplineTool.degree(forControlPointCount: 10) == 3)  // capped at cubic

        // A 3-pick control-point spline is a valid quadratic NURBS that resolves.
        var tool = SplineTool(mode: .controlPoints)
        let pts = [Vector(0, 0), Vector(5, 10), Vector(10, 0)]
        for p in pts { _ = tool.handle(.click(p), context: .empty) }
        let nurbs = committedNURBS(tool.handle(.commit, context: .empty))
        #expect(nurbs?.degree == 2)
        #expect(nurbs?.controlPoints.count == 3)
        let record = EntityRecord(id: .placeholder, kind: .spline(nurbs!))
        #expect((record.resolve().polylines.first?.points.count ?? 0) >= 2)
    }

    @Test("control-point mode closes on the first point with a closed .spline")
    func controlPointModeCloses() {
        var tool = SplineTool(mode: .controlPoints)
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        // Click back on the first point → closed NURBS committed immediately.
        let nurbs = committedNURBS(tool.handle(.click(p0), context: .empty))
        #expect(nurbs != nil)
        #expect(nurbs?.closed == true)
        #expect(nurbs?.controlPoints.count == 3)   // first point not duplicated
    }

    @Test("control-point mode status reflects 'control point'")
    func controlPointModeStatus() {
        var tool = SplineTool(mode: .controlPoints)
        #expect(tool.status == "Specify first control point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify next control point (Return to finish)")
    }

    @Test("control-point mode preview tessellates the picks plus cursor as a NURBS curve")
    func controlPointModePreview() {
        var tool = SplineTool(mode: .controlPoints)
        let p0 = Vector(0, 0)
        let p1 = Vector(10, 0)
        let p2 = Vector(20, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)
        let cursor = Vector(30, 10)
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)
        #expect(tool.preview.count == 1)
        let curve = tool.preview[0]
        #expect(curve.closed == false)
        // Four control points (3 fixed + cursor) → cubic NURBS, tessellated to many
        // points, interpolating the first/last control point.
        #expect(curve.points.count > 4)
        #expect(curve.points.first == p0)
        #expect(curve.points.last == cursor)
    }
}
