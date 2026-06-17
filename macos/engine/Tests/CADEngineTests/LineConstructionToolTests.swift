//
//  LineConstructionToolTests.swift
//  CADEngineTests
//
//  Drives the LINE CONSTRUCTION tool PURELY (no GUI): feeds `ToolInput` events + a
//  hand-built `ToolContext` whose boundary hook (`nearbyEntities`) scans a known
//  entity set (the FilletTool fixture pattern), and asserts each construction MODE
//  emits the correct plain `.line` via a single `.add`:
//    • perpendicularFoot — line (0,0)→(10,0), point (3,5) → segment (3,5)→(3,0).
//    • parallelThrough   — line (0,0)→(4,0), point (2,5) → segment (0,5)→(4,5).
//    • angleBisector     — lines on the axes, corner (0,0) → 45° bisector segment.
//    • tangent1/tangent2 — circle r=5 at origin, point (10,0) → the two tangents.
//    • orthTangent       — vertical ref line + circle → the horizontal tangent.
//    • a degenerate no-op (a perpendicular onto a point already on the line → no
//      commit).
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

@Suite("LineConstructionTool (constrained line draw modes)")
struct LineConstructionToolTests {

    private let eps = 1e-7

    // MARK: - Context fixture (mirrors FilletToolTests / TrimToolTests)

    /// A `ToolContext` whose `nearbyEntities` hook scans `records` with the same
    /// exact-distance semantics the app's `makeToolContext` uses (visible records
    /// within tolerance by `HitTesting.worldDistance`).
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

    /// Extracts the single added line from a `.commit([.add(.line)])` outcome, or
    /// records an issue and returns nil otherwise.
    private func addedLine(_ outcome: ToolOutcome) -> LineData? {
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a .commit, got \(outcome)")
            return nil
        }
        guard edits.count == 1, case .add(let rec) = edits[0] else {
            Issue.record("expected exactly one .add edit, got \(edits)")
            return nil
        }
        guard case .line(let d) = rec.kind else {
            Issue.record("expected the added record to be a .line, got \(rec.kind)")
            return nil
        }
        #expect(rec.id == .placeholder, "a constructed line must carry the placeholder id")
        return d
    }

    // MARK: - Fixtures

    private static func line(_ id: Int, _ s: Vector, _ e: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(UInt64(id)), flags: [.visible],
                     kind: .line(LineData(start: s, end: e)))
    }
    private static func circle(_ id: Int, _ c: Vector, _ r: Double) -> EntityRecord {
        EntityRecord(id: EntityID(UInt64(id)), flags: [.visible],
                     kind: .circle(CircleData(center: c, radius: r)))
    }

    /// Tolerant unordered endpoint match: the line's two endpoints equal `{p, q}`.
    private func endpointsMatch(_ d: LineData, _ p: Vector, _ q: Vector) -> Bool {
        let a = (d.start.distance(to: p) < eps && d.end.distance(to: q) < eps)
        let b = (d.start.distance(to: q) < eps && d.end.distance(to: p) < eps)
        return a || b
    }

    // MARK: - perpendicular-foot

    @Test("perpendicular-foot: line (0,0)→(10,0), point (3,5) → segment (3,5)→(3,0)")
    func perpendicularFoot() {
        var tool = LineConstructionTool(mode: .perpendicularFoot)
        let ctx = Self.context(over: [Self.line(1, Vector(0, 0), Vector(10, 0))])
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)   // pick the line
        let outcome = tool.handle(.click(Vector(3, 5)), context: ctx)        // the point → commit
        guard let d = addedLine(outcome) else { return }
        #expect(endpointsMatch(d, Vector(3, 5), Vector(3, 0)),
                "perpendicular foot of (3,5) onto the x-axis is (3,0); got \(d.start)→\(d.end)")
    }

    // MARK: - parallel-through

    @Test("parallel-through: line (0,0)→(4,0), point (2,5) → segment (0,5)→(4,5)")
    func parallelThrough() {
        var tool = LineConstructionTool(mode: .parallelThrough)
        let ctx = Self.context(over: [Self.line(1, Vector(0, 0), Vector(4, 0))])
        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)   // pick the line
        let outcome = tool.handle(.click(Vector(2, 5)), context: ctx)        // the point → commit
        guard let d = addedLine(outcome) else { return }
        // Parallel to the x-axis, length 4, centered on (2,5).
        #expect(endpointsMatch(d, Vector(0, 5), Vector(4, 5)),
                "parallel segment (length 4) through (2,5) is (0,5)→(4,5); got \(d.start)→\(d.end)")
        #expect(abs((d.end - d.start).y) < eps, "result must be parallel (horizontal)")
    }

    // MARK: - angle bisector

    @Test("angle bisector: x-axis & y-axis lines → 45° segment from (0,0)")
    func angleBisector() {
        var tool = LineConstructionTool(mode: .angleBisector)
        let lineA = Self.line(1, Vector(0, 0), Vector(10, 0))   // x-axis
        let lineB = Self.line(2, Vector(0, 0), Vector(0, 10))   // y-axis
        let ctx = Self.context(over: [lineA, lineB])
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)   // first line (ray +x)
        let outcome = tool.handle(.click(Vector(0, 5)), context: ctx)        // second line (ray +y) → commit
        guard let d = addedLine(outcome) else { return }
        // Corner (0,0); bisector along (1,1)/√2; span = min length = 10.
        let k = 10.0 / 2.0.squareRoot()
        #expect(endpointsMatch(d, Vector(0, 0), Vector(k, k)),
                "bisector of +x and +y from (0,0) ends at (\(k),\(k)); got \(d.start)→\(d.end)")
    }

    // MARK: - tangent-1 / tangent-2

    @Test("tangent-1 & tangent-2: circle r=5 at origin, point (10,0) → the two tangent lines")
    func tangentBothSolutions() {
        let circ = Self.circle(1, Vector(0, 0), 5)
        let ctx = Self.context(over: [circ])
        let point = Vector(10, 0)

        // Solution 0 (the +60° tangent point).
        var t1 = LineConstructionTool(mode: .tangent1)
        #expect(t1.handle(.click(Vector(5, 0)), context: ctx) == .none)   // pick the circle
        guard let d1 = addedLine(t1.handle(.click(point), context: ctx)) else { return }

        // Solution 1 (the −60° tangent point).
        var t2 = LineConstructionTool(mode: .tangent2)
        #expect(t2.handle(.click(Vector(5, 0)), context: ctx) == .none)
        guard let d2 = addedLine(t2.handle(.click(point), context: ctx)) else { return }

        // Each line runs from the external point to a tangent point on the circle.
        for d in [d1, d2] {
            #expect(d.start.distance(to: point) < eps, "the tangent starts at the picked point")
            let t = d.end
            #expect(abs(t.distance(to: Vector(0, 0)) - 5) < eps, "the tangent point lies on the circle")
            // Tangency: the radius (center→T) is perpendicular to the line (point→T).
            let radial = t - Vector(0, 0)
            let along = t - point
            #expect(abs(radial.dot(along)) < 1e-6, "radius ⟂ tangent line at the tangent point")
        }
        // The two solutions are mirror images across the x-axis (distinct).
        #expect(abs(d1.end.x - d2.end.x) < eps && abs(d1.end.y + d2.end.y) < eps,
                "tangent-1 and tangent-2 are the two distinct ±solutions; got \(d1.end) / \(d2.end)")
    }

    // MARK: - orth-tangent

    @Test("orth-tangent: vertical ref line + circle (5,5) r=3 → horizontal tangent at y=8")
    func orthTangent() {
        var tool = LineConstructionTool(mode: .orthTangent)
        let ref = Self.line(1, Vector(0, 0), Vector(0, 10))   // vertical reference line
        let circ = Self.circle(2, Vector(5, 5), 3)
        let ctx = Self.context(over: [ref, circ])
        #expect(tool.handle(.click(Vector(0, 5)), context: ctx) == .none)   // pick the ref line
        // Pick the circle nearer its TOP tangent point (5,8).
        let outcome = tool.handle(.click(Vector(5, 7.9)), context: ctx)
        guard let d = addedLine(outcome) else { return }
        // The tangent line is HORIZONTAL (⟂ the vertical ref line), touching at (5,8),
        // spanning ± one radius (diameter) → (8,8)→(2,8).
        #expect(abs((d.end - d.start).y) < eps, "orth-tangent must be perpendicular to the vertical ref (horizontal)")
        #expect(endpointsMatch(d, Vector(8, 8), Vector(2, 8)),
                "tangent at (5,8) spanning a diameter is (8,8)→(2,8); got \(d.start)→\(d.end)")
        // Tangency: the closest distance from the circle center to the line equals r.
        let foot = SnapGeometry.perpendicularFootOnLine(from: Vector(5, 5), a: d.start, b: d.end)
        #expect(abs(foot.distance(to: Vector(5, 5)) - 3) < eps, "the line is tangent to the circle (distance = r)")
    }

    // MARK: - degenerate no-op

    @Test("degenerate: perpendicular onto a point already ON the line commits nothing")
    func degeneratePerpendicularNoOp() {
        var tool = LineConstructionTool(mode: .perpendicularFoot)
        let ctx = Self.context(over: [Self.line(1, Vector(0, 0), Vector(10, 0))])
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)   // pick the line
        // The point (4,0) is already ON the line → foot == point → zero-length → no-op.
        let outcome = tool.handle(.click(Vector(4, 0)), context: ctx)
        #expect(outcome == .none, "a zero-length perpendicular must commit nothing, got \(outcome)")
    }

    @Test("degenerate: a tangent from a point INSIDE the circle commits nothing")
    func degenerateTangentInsideNoOp() {
        var tool = LineConstructionTool(mode: .tangent1)
        let ctx = Self.context(over: [Self.circle(1, Vector(0, 0), 5)])
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)   // pick the circle
        // (1,0) is strictly inside r=5 → no real tangent → no-op.
        let outcome = tool.handle(.click(Vector(1, 0)), context: ctx)
        #expect(outcome == .none, "no tangent exists from inside the circle, got \(outcome)")
    }

    @Test("degenerate: angle bisector of two PARALLEL lines commits nothing")
    func degenerateBisectorParallelNoOp() {
        var tool = LineConstructionTool(mode: .angleBisector)
        let lineA = Self.line(1, Vector(0, 0), Vector(10, 0))
        let lineB = Self.line(2, Vector(0, 5), Vector(10, 5))   // parallel to A → no corner
        let ctx = Self.context(over: [lineA, lineB])
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)
        let outcome = tool.handle(.click(Vector(5, 5)), context: ctx)
        #expect(outcome == .none, "parallel lines have no corner → no bisector, got \(outcome)")
    }

    // MARK: - state machine / non-pick robustness

    @Test("a first click that hits nothing keeps waiting (no state advance, no commit)")
    func firstClickOnEmptyKeepsWaiting() {
        var tool = LineConstructionTool(mode: .perpendicularFoot)
        let ctx = Self.context(over: [Self.line(1, Vector(0, 0), Vector(10, 0))])
        // Click far from any entity → still waiting for the reference line.
        #expect(tool.handle(.click(Vector(500, 500)), context: ctx) == .none)
        #expect(tool.status == "Select reference line")
    }

    @Test("cancel resets the run and finishes")
    func cancelResets() {
        var tool = LineConstructionTool(mode: .parallelThrough)
        let ctx = Self.context(over: [Self.line(1, Vector(0, 0), Vector(4, 0))])
        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)   // first line fixed
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.status == "Select reference line", "after cancel the tool is back at the first step")
    }
}
