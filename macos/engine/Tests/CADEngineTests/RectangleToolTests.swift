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

// MARK: - Corner-treatment variants (rounded / chamfer / typed W×H)

/// Covers the LibreCAD rectangle DRAW VARIANTS layered onto `RectangleTool`:
/// (a) typed W×H from one corner via `ToolInput.value`; (b) rounded corners (a
/// closed `.polyline` with bulge arcs); (c) chamfered corners (corner-cutting
/// segments). Every assertion keeps the EXISTING `.square` default unchanged.
/// Pure value logic — no GUI.
@Suite("RectangleTool draw variants")
struct RectangleVariantTests {

    private func committedPolyline(_ outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Default unchanged

    @Test("corner defaults to .square (existing two-corner rect is unchanged)")
    func cornerDefaultSquare() {
        #expect(RectangleTool().corner == .square)
        var tool = RectangleTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 5)), context: .empty))
        // Exactly the original 4 sharp corners, all bulges 0.
        #expect(poly?.vertices.map(\.point) == [Vector(0, 0), Vector(10, 0), Vector(10, 5), Vector(0, 5)])
        #expect(poly?.vertices.allSatisfy { $0.bulge == 0 } == true)
    }

    // MARK: - (a) Typed W×H from one corner via .value

    @Test("typed W×H: a single .value places the lower-left corner and commits that exact size")
    func typedWidthHeightViaValue() {
        var tool = RectangleTool()
        tool.fixedWidth = 40
        tool.fixedHeight = 25
        // A TYPED coordinate (U1) lands the corner and commits the exact-size box,
        // just like a click — exercising the `.value` path explicitly.
        let poly = committedPolyline(tool.handle(.value(Vector(5, 5)), context: .empty))
        #expect(poly != nil)
        #expect(poly?.vertices.count == 4)
        let pts = poly!.vertices.map(\.point)
        #expect(pts == [Vector(5, 5), Vector(45, 5), Vector(45, 30), Vector(5, 30)])
        #expect(abs(abs(pts[1].x - pts[0].x) - 40) < 1e-9)   // width 40
        #expect(abs(abs(pts[2].y - pts[1].y) - 25) < 1e-9)   // height 25
    }

    @Test("typed W×H second-corner: .value as the opposite corner commits a rect to that point")
    func typedOppositeCornerViaValue() {
        var tool = RectangleTool()                 // no fixed size → two-point flow
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.value(Vector(12, 7)), context: .empty))
        #expect(poly?.vertices.map(\.point) == [Vector(0, 0), Vector(12, 0), Vector(12, 7), Vector(0, 7)])
    }

    // MARK: - (b) Rounded corners

    @Test("rounded: a rect commits 8 vertices, one quarter-circle bulge per corner")
    func roundedVertexCountAndBulge() {
        var tool = RectangleTool()
        tool.corner = .rounded(radius: 2)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 8)), context: .empty))
        #expect(poly != nil)
        #expect(poly?.closed == true)
        // 4 corners × 2 tangent points = 8 vertices.
        #expect(poly?.vertices.count == 8)
        // Exactly 4 bulged vertices (the first tangent of each corner), 4 straight.
        let bulged = poly!.vertices.filter { abs($0.bulge) > 1e-12 }
        #expect(bulged.count == 4)
        // Each corner of an axis-aligned rect turns 90°, so |bulge| == tan(π/8).
        let q = tan(Double.pi / 8)
        for v in bulged { #expect(abs(abs(v.bulge) - q) < 1e-9) }
    }

    @Test("rounded: tangent points sit exactly `radius` back from each corner along the edges")
    func roundedTangentGeometry() {
        var tool = RectangleTool()
        let r = 2.0
        tool.corner = .rounded(radius: r)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 8)), context: .empty))
        let pts = poly!.vertices.map(\.point)
        // Corner (0,0): tangent points are r along the incoming (from (0,8)) and
        // outgoing (toward (10,0)) edges → (0, r) then (r, 0).
        #expect(pts[0] == Vector(0, r))
        #expect(pts[1] == Vector(r, 0))
        // Corner (10,0): (10-r, 0) then (10, r).
        #expect(pts[2] == Vector(10 - r, 0))
        #expect(pts[3] == Vector(10, r))
        // Corner (10,8): (10, 8-r) then (10-r, 8).
        #expect(pts[4] == Vector(10, 8 - r))
        #expect(pts[5] == Vector(10 - r, 8))
        // Corner (0,8): (r, 8) then (0, 8-r).
        #expect(pts[6] == Vector(r, 8))
        #expect(pts[7] == Vector(0, 8 - r))
    }

    @Test("rounded: the corner bulge is signed to bow OUTWARD (convex) — negative for CCW picks")
    func roundedBulgeSignOutward() {
        var tool = RectangleTool()
        tool.corner = .rounded(radius: 2)
        // Picked CCW: (0,0)→(10,8). corners() winds CCW, so each convex arc bulges
        // RIGHT of the directed chord → negative bulge.
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 8)), context: .empty))
        for v in poly!.vertices where abs(v.bulge) > 1e-12 {
            #expect(v.bulge < 0)
        }
    }

    @Test("rounded: a too-large radius falls back to a sharp 4-corner square")
    func roundedTooLargeFallsBack() {
        var tool = RectangleTool()
        tool.corner = .rounded(radius: 100)   // > half the shorter side (2.5)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 5)), context: .empty))
        #expect(poly?.vertices.count == 4)
        #expect(poly?.vertices.allSatisfy { $0.bulge == 0 } == true)
    }

    @Test("rounded: a non-positive radius falls back to a sharp square")
    func roundedNonPositiveFallsBack() {
        var tool = RectangleTool()
        tool.corner = .rounded(radius: 0)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 5)), context: .empty))
        #expect(poly?.vertices.count == 4)
    }

    // MARK: - (c) Chamfered corners

    @Test("chamfer: a rect commits 8 STRAIGHT vertices (bevel segment per corner)")
    func chamferVertexCount() {
        var tool = RectangleTool()
        tool.corner = .chamfer(distance: 2)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 8)), context: .empty))
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 8)
        // Chamfer is straight bevels — every bulge is 0.
        #expect(poly?.vertices.allSatisfy { $0.bulge == 0 } == true)
    }

    @Test("chamfer: each corner is cut back exactly `distance` along both edges")
    func chamferSegmentGeometry() {
        var tool = RectangleTool()
        let d = 2.0
        tool.corner = .chamfer(distance: d)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 8)), context: .empty))
        let pts = poly!.vertices.map(\.point)
        // Same tangent points as the rounded case, but joined straight.
        #expect(pts == [
            Vector(0, d), Vector(d, 0),          // corner (0,0)
            Vector(10 - d, 0), Vector(10, d),    // corner (10,0)
            Vector(10, 8 - d), Vector(10 - d, 8),// corner (10,8)
            Vector(d, 8), Vector(0, 8 - d),      // corner (0,8)
        ])
        // The bevel across corner (10,0) runs from (10-d,0) to (10,d): a 45° cut of
        // length d·√2.
        let bevel = (pts[3] - pts[2]).magnitude
        #expect(abs(bevel - d * 2.squareRoot()) < 1e-9)
    }

    @Test("chamfer: a too-large distance falls back to a sharp square")
    func chamferTooLargeFallsBack() {
        var tool = RectangleTool()
        tool.corner = .chamfer(distance: 99)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 5)), context: .empty))
        #expect(poly?.vertices.count == 4)
    }

    // MARK: - Preview reflects the corner treatment

    @Test("preview of a rounded rect tessellates the arcs (more points than the chamfer)")
    func roundedPreviewTessellated() {
        var tool = RectangleTool()
        tool.corner = .rounded(radius: 2)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(10, 8)), context: .empty)
        #expect(tool.preview.count == 1)
        // Rounded preview tessellates each of the 4 arcs, so it has many more than
        // the 8 raw vertices.
        #expect(tool.preview[0].points.count > 8)
        #expect(tool.preview[0].closed == true)
    }

    @Test("preview of a chamfer rect is the 8 exact vertices (no tessellation)")
    func chamferPreviewExact() {
        var tool = RectangleTool()
        tool.corner = .chamfer(distance: 2)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(10, 8)), context: .empty)
        #expect(tool.preview[0].points.count == 8)
    }
}
