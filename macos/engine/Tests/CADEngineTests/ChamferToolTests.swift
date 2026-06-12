//
//  ChamferToolTests.swift
//  CADEngineTests
//
//  Drives the CHAMFER (bevel) editing tool PURELY (no GUI): feeds `ToolInput`
//  events + a hand-built `ToolContext` whose `nearbyEntities` hook scans a known
//  entity set, and asserts the bevel contract — that picking two LINES emits two
//  `.replace` (each line trimmed back to its bevel endpoint) plus one `.add` (the
//  straight bevel line P1–P2), with P1/P2 sitting at `distance1`/`distance2` from
//  the corner along each line toward the pick side.
//
//  Covers: the canonical two perpendicular lines (corner at (10,0), distances 3/3
//  → P1 (7,0), P2 (10,3), trimmed lines + bevel line, commit = 2 .replace + 1
//  .add), the parallel-lines no-op, the non-line pick no-op, the cancel/backspace
//  resets, and the move preview.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ChamferTool bevel (pick two lines, bevel their corner)")
struct ChamferToolTests {

    // MARK: - Context fixture

    /// Builds a `ToolContext` whose `nearbyEntities` hook scans `records` with the
    /// SAME exact-distance semantics the app's `makeToolContext` wires up: visible
    /// records within tolerance by `HitTesting.worldDistance`. (Mirrors
    /// `TrimToolTests` / `ToolContextTests`.)
    private static func context(over records: [EntityRecord], gridSpacing: Double? = nil) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(
            selected: [],
            entity: { byID[$0] },
            gridSpacing: gridSpacing,
            nearbyEntities: { point, tolerance in
                guard point.valid else { return [] }
                let tol = Swift.max(tolerance, 0)
                return records.filter { r in
                    guard r.flags.contains(.visible) else { return false }
                    return HitTesting.worldDistance(from: point, to: r) <= tol
                }
            },
            allEntities: { records }
        )
    }

    /// Pulls out the ordered (replace1, replace2, add) of a 3-edit `.commit`, or
    /// `nil` if the outcome isn't exactly two `.replace` followed by one `.add`.
    private func bevelEdits(_ outcome: ToolOutcome)
        -> (r1: (id: EntityID, kind: EntityKind),
            r2: (id: EntityID, kind: EntityKind),
            added: EntityRecord)? {
        guard case .commit(let edits) = outcome, edits.count == 3,
              case .replace(let id1, let k1) = edits[0],
              case .replace(let id2, let k2) = edits[1],
              case .add(let rec) = edits[2] else { return nil }
        return ((id1, k1), (id2, k2), rec)
    }

    // MARK: - Fixtures: two perpendicular lines

    /// Horizontal line (0,0)→(10,0). The FIRST bevel line.
    private static let l1 = EntityRecord(
        id: EntityID(1),
        layer: LayerID("walls"),
        pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
        flags: [.visible],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )

    /// Vertical line (10,0)→(10,10), sharing the corner (10,0) with l1. SECOND line.
    private static let l2 = EntityRecord(
        id: EntityID(2),
        flags: [.visible],
        kind: .line(LineData(start: Vector(10, 0), end: Vector(10, 10)))
    )

    private func approx(_ a: Vector, _ b: Vector, eps: Double = 1e-9) -> Bool {
        (a - b).magnitude < eps
    }

    // MARK: - The canonical bevel

    @Test("two perpendicular lines, distances 3/3, pick far ends → P1 (7,0), P2 (10,3)")
    func canonicalBevel() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])

        // Pick #1: near l1's far end (away from the corner (10,0)).
        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)
        // Pick #2: near l2's far end (away from the corner).
        let outcome = tool.handle(.click(Vector(10, 8)), context: ctx)

        guard let e = bevelEdits(outcome) else {
            Issue.record("expected 2 .replace + 1 .add commit, got \(outcome)")
            return
        }

        // First replace = l1 trimmed to (0,0)-(7,0).
        #expect(e.r1.id == EntityID(1))
        guard case .line(let d1) = e.r1.kind else {
            Issue.record("expected l1 line kind, got \(e.r1.kind)")
            return
        }
        #expect(approx(d1.start, Vector(0, 0)))
        #expect(approx(d1.end, Vector(7, 0)))

        // Second replace = l2 trimmed to (10,3)-(10,10).
        #expect(e.r2.id == EntityID(2))
        guard case .line(let d2) = e.r2.kind else {
            Issue.record("expected l2 line kind, got \(e.r2.kind)")
            return
        }
        #expect(approx(d2.start, Vector(10, 3)))
        #expect(approx(d2.end, Vector(10, 10)))

        // The added bevel line = (7,0)-(10,3).
        guard case .line(let bevel) = e.added.kind else {
            Issue.record("expected an added line, got \(e.added.kind)")
            return
        }
        #expect(approx(bevel.start, Vector(7, 0)))
        #expect(approx(bevel.end, Vector(10, 3)))
    }

    @Test("the added bevel line carries the FIRST line's layer + pen, placeholder id")
    func bevelInheritsFirstLineStyle() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(10, 8)), context: ctx)
        guard let e = bevelEdits(outcome) else {
            Issue.record("expected a bevel commit, got \(outcome)")
            return
        }
        #expect(e.added.id == .placeholder)
        #expect(e.added.layer == LayerID("walls"))
        #expect(e.added.pen == Self.l1.pen)
    }

    @Test("the commit is exactly two .replace followed by one .add(.line)")
    func commitShape() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        guard case .commit(let edits) = tool.handle(.click(Vector(10, 8)), context: ctx) else {
            Issue.record("expected a commit")
            return
        }
        #expect(edits.count == 3)
        if case .replace = edits[0] {} else { Issue.record("edit 0 must be .replace") }
        if case .replace = edits[1] {} else { Issue.record("edit 1 must be .replace") }
        guard case .add(let rec) = edits[2] else {
            Issue.record("edit 2 must be .add")
            return
        }
        if case .line = rec.kind {} else { Issue.record("the added entity must be a line") }
    }

    @Test("picking the near ends still bevels the same corner (P1/P2 from the corner)")
    func pickNearEndsSameCorner() {
        // Pick both lines NEAR the shared corner (10,0). The corner is the same, so
        // the bevel points are still 3 from the corner: P1 (7,0), P2 (10,3).
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(9, 0)), context: ctx)   // l1, near corner
        let outcome = tool.handle(.click(Vector(10, 1)), context: ctx)  // l2, near corner
        guard let e = bevelEdits(outcome),
              case .line(let bevel) = e.added.kind else {
            Issue.record("expected a bevel commit, got \(outcome)")
            return
        }
        #expect(approx(bevel.start, Vector(7, 0)))
        #expect(approx(bevel.end, Vector(10, 3)))
    }

    @Test("unequal distances place each bevel point at its own distance from the corner")
    func unequalDistances() {
        var tool = ChamferTool()
        tool.distance1 = 4   // along l1 → P1 (6,0)
        tool.distance2 = 2   // along l2 → P2 (10,2)
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(10, 8)), context: ctx)
        guard let e = bevelEdits(outcome),
              case .line(let bevel) = e.added.kind else {
            Issue.record("expected a bevel commit, got \(outcome)")
            return
        }
        #expect(approx(bevel.start, Vector(6, 0)))
        #expect(approx(bevel.end, Vector(10, 2)))
    }

    // MARK: - Defaults

    @Test("the default distances are 10/10 (equal-distance, UI backlog)")
    func defaultDistances() {
        let tool = ChamferTool()
        #expect(tool.distance1 == 10.0)
        #expect(tool.distance2 == 10.0)
    }

    // MARK: - No-op cases

    @Test("parallel lines (no corner) are a no-op")
    func parallelNoop() {
        let a = EntityRecord(id: EntityID(1), flags: [.visible],
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let b = EntityRecord(id: EntityID(2), flags: [.visible],
                             kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))))
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [a, b])
        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)   // first ok
        // Second pick on the parallel line → no corner → no-op.
        #expect(tool.handle(.click(Vector(2, 5)), context: ctx) == .none)
    }

    @Test("a non-line first pick (circle) is a no-op (scope: line–line)")
    func nonLineFirstPickNoop() {
        let circle = EntityRecord(id: EntityID(1), flags: [.visible],
                                  kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        var tool = ChamferTool()
        let ctx = Self.context(over: [circle, Self.l2])
        // Click on the circle's edge: not a LINE → ignored, still picking first.
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)
        // A subsequent click on a real line is treated as the FIRST pick (not the
        // second), so it also yields no commit.
        #expect(tool.handle(.click(Vector(10, 8)), context: ctx) == .none)
    }

    @Test("a non-line SECOND pick (arc) is a no-op")
    func nonLineSecondPickNoop() {
        let arc = EntityRecord(id: EntityID(3), flags: [.visible],
                               kind: .arc(ArcData(center: Vector(10, 0), radius: 4,
                                                  startAngle: 0, endAngle: .pi, reversed: false)))
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, arc])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)   // first line ok
        // Second pick lands on the arc (a non-line) → no-op.
        let clickArc = Vector(10 + 4 * cos(.pi / 4), 4 * sin(.pi / 4))
        #expect(tool.handle(.click(clickArc), context: ctx) == .none)
    }

    @Test("clicking empty space for the first pick is a no-op")
    func emptyFirstPickNoop() {
        var tool = ChamferTool()
        let ctx = Self.context(over: [Self.l1, Self.l2])
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
    }

    @Test("a distance longer than the line is a no-op (no valid bevel point)")
    func distanceTooLongNoop() {
        var tool = ChamferTool()
        tool.distance1 = 50   // longer than l1 (length 10) → degenerate
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(tool.handle(.click(Vector(10, 8)), context: ctx) == .none)
    }

    @Test("picking the same line twice is a no-op (need two distinct lines)")
    func sameLineTwiceNoop() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        // Click the SAME first line again → second == first → no-op.
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)
    }

    // MARK: - Preview / cancel / backspace / commit

    @Test("a move over a valid second line previews the trimmed lines + bevel")
    func movePreview() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        let outcome = tool.handle(.move(Vector(10, 8)), context: ctx)
        #expect(outcome == .preview)
        // Two trimmed lines + the bevel line = 3 preview polylines.
        #expect(tool.preview.count == 3)
        #expect(tool.preview.allSatisfy { $0.pen == .toolPreview })
    }

    @Test("a move before any first pick yields no preview")
    func movePreviewBeforeFirstPick() {
        var tool = ChamferTool()
        let ctx = Self.context(over: [Self.l1, Self.l2])
        #expect(tool.handle(.move(Vector(10, 8)), context: ctx) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("cancel discards the run and finishes")
    func cancelResets() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        _ = tool.handle(.move(Vector(10, 8)), context: ctx)
        #expect(!tool.preview.isEmpty)
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.preview.isEmpty)
        // After cancel, a single click is treated as the FIRST pick again (no commit).
        #expect(tool.handle(.click(Vector(10, 8)), context: ctx) == .none)
    }

    @Test("backspace after the first pick steps back to picking the first line")
    func backspaceStepsBack() {
        var tool = ChamferTool()
        tool.distance1 = 3
        tool.distance2 = 3
        let ctx = Self.context(over: [Self.l1, Self.l2])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(tool.handle(.backspace, context: ctx) == .none)
        // Back to first pick: a move over a line no longer previews a bevel.
        #expect(tool.handle(.move(Vector(10, 8)), context: ctx) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace before the first pick is a no-op")
    func backspaceBeforeFirstPick() {
        var tool = ChamferTool()
        let ctx = Self.context(over: [Self.l1, Self.l2])
        #expect(tool.handle(.backspace, context: ctx) == .none)
    }

    @Test("commit (Return) with nothing pending just finishes")
    func commitFinishes() {
        var tool = ChamferTool()
        let ctx = Self.context(over: [Self.l1, Self.l2])
        #expect(tool.handle(.commit, context: ctx) == .finished)
    }

    @Test("the status reflects the pick state")
    func statusReflectsState() {
        var tool = ChamferTool()
        let ctx = Self.context(over: [Self.l1, Self.l2])
        #expect(tool.status == "Select first line")
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(tool.status == "Select second line")
    }
}
