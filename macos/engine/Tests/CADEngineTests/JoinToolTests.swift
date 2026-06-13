//
//  JoinToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Join tool PURELY (no GUI): builds a selection of
//  touching / collinear lines and arcs, presses Return, and asserts the commit
//  shape (`.add(polyline)` + one `.remove` per original) and the joined geometry —
//  two collinear touching lines → one 2-vertex polyline + 2 removes; an L of two
//  lines → one 3-vertex polyline; a line+arc chain → a polyline with a bulge
//  segment matching the arc; a closed loop → a closed polyline; and a disjoint
//  selection → no commit (no-op).
//
//  Domain-prefixed suite name (CONVENTIONS.md §7.7: namespace test suites so
//  parallel fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("JoinTool modify (lines/arcs → polyline)")
struct JoinToolModifyTests {

    // MARK: - Fixtures

    /// A context whose `selected` is the given records (Join's primary input) and
    /// whose `nearbyEntities` hit-tests them (for the pick-then-join path).
    private static func context(selected: [EntityRecord], all: [EntityRecord]? = nil) -> ToolContext {
        let records = all ?? selected
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(
            selected: selected,
            entity: { byID[$0] },
            gridSpacing: nil,
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

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-7) -> Bool {
        a.distance(to: b) < tol
    }

    /// Splits a `.commit` into the added polyline + the removed ids, or `nil`.
    private func addedPolylineAndRemoves(_ outcome: ToolOutcome) -> (data: PolylineData, removed: [EntityID])? {
        guard case .commit(let edits) = outcome, let first = edits.first,
              case .add(let rec) = first,
              case .polyline(let data) = rec.kind else { return nil }
        var removed: [EntityID] = []
        for e in edits.dropFirst() {
            guard case .remove(let id) = e else { return nil }
            removed.append(id)
        }
        return (data, removed)
    }

    // MARK: - Metadata

    @Test("title is Join")
    func title() { #expect(JoinTool().title == "Join") }

    @Test("isJoinable accepts lines and arcs only")
    func joinableScope() {
        #expect(JoinTool.isJoinable(.line(LineData(start: .init(0, 0), end: .init(1, 0)))))
        #expect(JoinTool.isJoinable(.arc(ArcData(center: .init(0, 0), radius: 1, startAngle: 0, endAngle: 1))))
        #expect(!JoinTool.isJoinable(.circle(CircleData(center: .init(0, 0), radius: 1))))
        #expect(!JoinTool.isJoinable(.polyline(PolylineData(vertices: []))))
        #expect(!JoinTool.isJoinable(.point(PointData(position: .init(0, 0)))))
    }

    // MARK: - Brief case 1: two collinear touching lines → one 2-vertex polyline + 2 removes

    @Test("two collinear touching lines join into a 2-vertex polyline with 2 removes")
    func twoCollinearLines() {
        // (0,0)-(5,0) then (5,0)-(10,0): collinear, share (5,0).
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5, 0), end: Vector(10, 0))))
        var tool = JoinTool()
        let ctx = Self.context(selected: [a, b])
        let outcome = tool.handle(.commit, context: ctx)

        guard let (data, removed) = addedPolylineAndRemoves(outcome) else {
            Issue.record("expected an .add(polyline) + .remove commit, got \(outcome)")
            return
        }
        #expect(!data.closed)
        #expect(data.vertices.count == 2)
        #expect(approx(data.vertices[0].point, Vector(0, 0)))
        #expect(approx(data.vertices[1].point, Vector(10, 0)))
        // Straight segments → zero bulge.
        #expect(data.vertices.allSatisfy { abs($0.bulge) < 1e-12 })
        #expect(Set(removed) == Set([EntityID(1), EntityID(2)]))
    }

    @Test("the joined collinear polyline inherits the first source's layer/pen and strips selection")
    func inheritsAttributes() {
        var fa = EntityFlags.default; fa.insert(.selected)
        let a = EntityRecord(id: EntityID(1), layer: LayerID("walls"), pen: .byLayer, flags: fa,
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), layer: LayerID("walls"), pen: .byLayer, flags: fa,
                             kind: .line(LineData(start: Vector(5, 0), end: Vector(10, 0))))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [a, b]))
        guard case .commit(let edits) = outcome, case .add(let rec) = edits[0] else {
            Issue.record("expected an .add commit"); return
        }
        #expect(rec.layer == LayerID("walls"))
        #expect(!rec.flags.contains(.selected))   // §7.6 strip .selected on .add
        #expect(rec.id == .placeholder)
    }

    // MARK: - Brief case 2: an L of two lines → one 3-vertex polyline

    @Test("an L of two lines joins into a 3-vertex polyline")
    func lShapeOfTwoLines() {
        // (0,0)-(5,0) then (5,0)-(5,5): an L (right angle), share (5,0).
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5, 0), end: Vector(5, 5))))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [a, b]))

        guard let (data, removed) = addedPolylineAndRemoves(outcome) else {
            Issue.record("expected an .add(polyline) + .remove commit, got \(outcome)")
            return
        }
        #expect(!data.closed)
        #expect(data.vertices.count == 3)
        #expect(approx(data.vertices[0].point, Vector(0, 0)))
        #expect(approx(data.vertices[1].point, Vector(5, 0)))
        #expect(approx(data.vertices[2].point, Vector(5, 5)))
        #expect(Set(removed) == Set([EntityID(1), EntityID(2)]))
    }

    @Test("ordering reverses an out-of-order / mis-directed line to splice it on")
    func reorderAndReverse() {
        // Selection order is shuffled and the middle line points "backwards".
        // Chain should still resolve to 0,0 → 5,0 → 5,5 → 0,5.
        let s1 = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let s3 = EntityRecord(id: EntityID(3), kind: .line(LineData(start: Vector(5, 5), end: Vector(5, 0)))) // reversed dir
        let s2 = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(0, 5), end: Vector(5, 5))))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [s1, s3, s2]))
        guard let (data, removed) = addedPolylineAndRemoves(outcome) else {
            Issue.record("expected a join commit, got \(outcome)"); return
        }
        #expect(!data.closed)
        #expect(data.vertices.count == 4)
        let pts = data.vertices.map(\.point)
        // Endpoints anchor the chain; the run visits all four corners exactly once.
        #expect(approx(pts.first!, Vector(0, 0)) || approx(pts.first!, Vector(0, 5)))
        #expect(approx(pts.last!, Vector(0, 0)) || approx(pts.last!, Vector(0, 5)))
        #expect(approx(pts[1], Vector(5, 0)) || approx(pts[1], Vector(5, 5)))
        #expect(approx(pts[2], Vector(5, 0)) || approx(pts[2], Vector(5, 5)))
        #expect(Set(removed) == Set([EntityID(1), EntityID(2), EntityID(3)]))
    }

    // MARK: - Brief case 3: a line+arc chain → polyline with a bulge matching the arc

    @Test("a line+arc chain joins into a polyline whose arc edge carries a matching bulge")
    func lineArcChainBulge() {
        // Line (0,0)→(2,0); then a quarter arc from (2,0) up to (3,1):
        //   center (2,1), radius 1, start angle -π/2 (point (2,0)),
        //   end angle 0 (point (3,1)), CCW (reversed=false) → quarter sweep +π/2.
        let line = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(2, 0))))
        let arcData = ArcData(center: Vector(2, 1), radius: 1,
                              startAngle: -Double.pi / 2, endAngle: 0, reversed: false)
        let arc = EntityRecord(id: EntityID(2), kind: .arc(arcData))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [line, arc]))

        guard let (data, removed) = addedPolylineAndRemoves(outcome) else {
            Issue.record("expected a join commit, got \(outcome)"); return
        }
        #expect(!data.closed)
        #expect(data.vertices.count == 3)
        #expect(approx(data.vertices[0].point, Vector(0, 0)))
        #expect(approx(data.vertices[1].point, Vector(2, 0)))
        #expect(approx(data.vertices[2].point, Vector(3, 1)))
        // The line segment's leading vertex (index 0) is straight.
        #expect(abs(data.vertices[0].bulge) < 1e-12)
        // The arc edge leaves vertex 1; its bulge = tan(sweep/4). A +π/2 sweep ⇒
        // expandPolyline traverses -4·atan(bulge); to reproduce +π/2 we need
        // bulge = -tan((π/2)/4) = -tan(π/8) ≈ -0.41421.
        let expectedBulge = -tan((Double.pi / 2) / 4)
        #expect(abs(data.vertices[1].bulge - expectedBulge) < 1e-9)

        // Round-trip: exploding the joined polyline must reproduce the arc geometry
        // (the bulge is the exact inverse of ExplodeTool.arc).
        let edge = JoinTool.edge(for: arc.kind)!
        let backArc = ExplodeTool.arc(from: data.vertices[1].point,
                                      to: data.vertices[2].point,
                                      bulge: data.vertices[1].bulge)
        #expect(backArc != nil)
        if let backArc {
            #expect(approx(backArc.center, arcData.center))
            #expect(abs(backArc.radius - arcData.radius) < 1e-7)
            // Same signed sweep (the geometry the renderer walks).
            #expect(abs(JoinTool.signedSweep(backArc) - edge.sweep) < 1e-7)
        }
        #expect(Set(removed) == Set([EntityID(1), EntityID(2)]))
    }

    // MARK: - Closed loop → closed polyline

    @Test("a closed loop of four lines joins into a CLOSED polyline (no duplicate vertex)")
    func closedLoop() {
        // A unit square traversed CCW; the last edge returns to (0,0).
        let e1 = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0))))
        let e2 = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(4, 0), end: Vector(4, 4))))
        let e3 = EntityRecord(id: EntityID(3), kind: .line(LineData(start: Vector(4, 4), end: Vector(0, 4))))
        let e4 = EntityRecord(id: EntityID(4), kind: .line(LineData(start: Vector(0, 4), end: Vector(0, 0))))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [e1, e2, e3, e4]))

        guard let (data, removed) = addedPolylineAndRemoves(outcome) else {
            Issue.record("expected a join commit, got \(outcome)"); return
        }
        #expect(data.closed)
        // Closed → 4 distinct vertices, NOT 5 (the duplicate closing point dropped).
        #expect(data.vertices.count == 4)
        #expect(Set(removed).count == 4)
    }

    // MARK: - Brief case 4: disjoint selection → no commit

    @Test("a disjoint (non-touching) selection produces no commit")
    func disjointSelectionNoOp() {
        // Two lines that don't share any endpoint.
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(100, 100), end: Vector(105, 100))))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [a, b]))
        if case .commit = outcome {
            Issue.record("expected a no-op for a disjoint selection, got a commit")
        }
        // Acceptable outcomes: .none (no-op). Definitely NOT a commit.
        #expect(outcome == .none)
    }

    @Test("a partially-connectable selection (one stray segment) is a no-op")
    func partiallyConnectableNoOp() {
        // Two touching lines + one stray that connects to neither.
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5, 0), end: Vector(10, 0))))
        let stray = EntityRecord(id: EntityID(3), kind: .line(LineData(start: Vector(50, 50), end: Vector(60, 60))))
        var tool = JoinTool()
        let outcome = tool.handle(.commit, context: Self.context(selected: [a, b, stray]))
        #expect(outcome == .none)
    }

    @Test("a single selected segment is a no-op (nothing to join)")
    func singleSegmentNoOp() {
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        var tool = JoinTool()
        #expect(tool.handle(.commit, context: Self.context(selected: [a])) == .none)
    }

    // MARK: - Pick-then-join path (no pre-selection)

    @Test("clicking two touching lines then committing joins them (no pre-selection)")
    func pickThenJoin() {
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5, 0), end: Vector(10, 0))))
        let ctx = Self.context(selected: [], all: [a, b])
        var tool = JoinTool(gapTolerance: 1e-6, pickTolerance: 0.5)
        // Click on each line (mid-points); clicks accrue, no commit yet.
        #expect(tool.handle(.click(Vector(2.5, 0)), context: ctx) == .none)
        #expect(tool.handle(.click(Vector(7.5, 0)), context: ctx) == .none)
        let outcome = tool.handle(.commit, context: ctx)
        guard let (data, removed) = addedPolylineAndRemoves(outcome) else {
            Issue.record("expected a join commit from clicked segments, got \(outcome)"); return
        }
        #expect(data.vertices.count == 2)
        #expect(Set(removed) == Set([EntityID(1), EntityID(2)]))
    }

    @Test("backspace drops the last clicked segment")
    func backspaceDropsPick() {
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5, 0), end: Vector(10, 0))))
        let ctx = Self.context(selected: [], all: [a, b])
        var tool = JoinTool(pickTolerance: 0.5)
        _ = tool.handle(.click(Vector(2.5, 0)), context: ctx)
        _ = tool.handle(.click(Vector(7.5, 0)), context: ctx)
        _ = tool.handle(.backspace, context: ctx)   // drop the second pick
        // Only one segment left → commit is a no-op.
        #expect(tool.handle(.commit, context: ctx) == .none)
    }

    @Test("Esc cancels and finishes")
    func cancelFinishes() {
        var tool = JoinTool()
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }

    @Test("a typed coordinate is ignored")
    func valueIgnored() {
        var tool = JoinTool()
        #expect(tool.handle(.value(Vector(3, 3)), context: .empty) == .none)
    }

    // MARK: - Gap tolerance

    @Test("a small gap within the tolerance is bridged; beyond it is a no-op")
    func gapTolerance() {
        // Lines separated by 0.001 at the join.
        let a = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5.001, 0), end: Vector(10, 0))))

        // Tolerance 0.01 > gap → joins.
        var loose = JoinTool(gapTolerance: 0.01)
        let joined = loose.handle(.commit, context: Self.context(selected: [a, b]))
        #expect(addedPolylineAndRemoves(joined) != nil)

        // Tolerance 1e-6 < gap → no-op.
        var tight = JoinTool(gapTolerance: 1e-6)
        #expect(tight.handle(.commit, context: Self.context(selected: [a, b])) == .none)
    }

    // MARK: - Static join() helper directness

    @Test("join() returns nil for fewer than two edges")
    func joinNeedsTwoEdges() {
        #expect(JoinTool.join([.line(LineData(start: Vector(0, 0), end: Vector(1, 0)))], gapTolerance: 1e-6) == nil)
        #expect(JoinTool.join([], gapTolerance: 1e-6) == nil)
    }
}
