//
//  BreakToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Break tool PURELY (no GUI): picks a line / arc /
//  polyline, then a break point (or two), and asserts the commit shape
//  (`.remove(original)` + `.add(piece)` per surviving piece) and the split
//  geometry — a line at its midpoint → two halves; an arc at a point → two
//  sub-arcs that re-cover the original sweep; a polyline at a vertex → two open
//  pieces; and the two-point span-removal form.
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

@Suite("BreakTool modify (split / remove-span)")
struct BreakToolModifyTests {

    // MARK: - Fixtures

    private static func context(over records: [EntityRecord]) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(
            selected: [],
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

    private static let lineID = EntityID(1)
    private static let arcID = EntityID(2)
    private static let plID = EntityID(3)

    /// A 10-unit horizontal line (0,0)-(10,0).
    private static func line10() -> EntityRecord {
        EntityRecord(id: lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    /// Splits a `.commit` into the removed id + the added kinds, or `nil`.
    private func removeAndAdds(_ outcome: ToolOutcome) -> (removed: EntityID, added: [EntityKind])? {
        guard case .commit(let edits) = outcome, edits.count >= 2,
              case .remove(let id) = edits[0] else { return nil }
        var adds: [EntityKind] = []
        for e in edits.dropFirst() {
            guard case .add(let rec) = e else { return nil }
            adds.append(rec.kind)
        }
        return (id, adds)
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    private func lineLength(_ k: EntityKind) -> Double? {
        guard case .line(let d) = k else { return nil }
        return d.start.distance(to: d.end)
    }

    private func arcSweep(_ k: EntityKind) -> Double? {
        guard case .arc(let d) = k else { return nil }
        return MathUtils.getAngleDifference(d.startAngle, d.endAngle, reversed: d.reversed)
    }

    // MARK: - Metadata

    @Test("title is Break")
    func title() { #expect(BreakTool().title == "Break") }

    // MARK: - Brief requirement: break a line at its midpoint → two 5-unit lines

    @Test("breaking a 10-unit line at its midpoint yields two 5-unit halves")
    func breakLineAtMidpoint() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])

        // Pick the entity, then the break point at the midpoint, then commit a
        // single-point split (Return).
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)   // pick entity
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)   // first break point
        let outcome = tool.handle(.commit, context: ctx)                    // split at the point

        guard let (removed, adds) = removeAndAdds(outcome) else {
            Issue.record("expected a .remove + .add(s) commit"); return
        }
        #expect(removed == Self.lineID)
        #expect(adds.count == 2)
        guard case .line(let a) = adds[0], case .line(let b) = adds[1] else {
            Issue.record("expected two line pieces"); return
        }
        #expect(approx(a.start, Vector(0, 0)))
        #expect(approx(a.end, Vector(5, 0)))
        #expect(approx(b.start, Vector(5, 0)))
        #expect(approx(b.end, Vector(10, 0)))
        #expect(abs(lineLength(adds[0])! - 5) < 1e-9)
        #expect(abs(lineLength(adds[1])! - 5) < 1e-9)
    }

    @Test("a repeat-click at the same point splits at the single point (no Return needed)")
    func breakLineByRepeatClick() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        _ = tool.handle(.click(Vector(3, 0)), context: ctx)   // pick entity
        _ = tool.handle(.click(Vector(3, 0)), context: ctx)   // first point
        let outcome = tool.handle(.click(Vector(3, 0)), context: ctx)  // same → split

        guard let (_, adds) = removeAndAdds(outcome) else {
            Issue.record("expected a split commit"); return
        }
        #expect(adds.count == 2)
        #expect(abs(lineLength(adds[0])! - 3) < 1e-9)
        #expect(abs(lineLength(adds[1])! - 7) < 1e-9)
    }

    // MARK: - Two-point span removal on a line

    @Test("breaking a line between two points removes the inner span, keeping the outer pieces")
    func breakLineSpan() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])

        _ = tool.handle(.click(Vector(5, 0)), context: ctx)   // pick entity
        _ = tool.handle(.click(Vector(3, 0)), context: ctx)   // first point at x=3
        let outcome = tool.handle(.click(Vector(7, 0)), context: ctx)  // second at x=7

        guard let (_, adds) = removeAndAdds(outcome) else {
            Issue.record("expected a span-removal commit"); return
        }
        #expect(adds.count == 2)
        guard case .line(let a) = adds[0], case .line(let b) = adds[1] else {
            Issue.record("expected two line pieces"); return
        }
        #expect(approx(a.start, Vector(0, 0)))
        #expect(approx(a.end, Vector(3, 0)))    // outer piece 1: start → gap-lo
        #expect(approx(b.start, Vector(7, 0)))  // outer piece 2: gap-hi → end
        #expect(approx(b.end, Vector(10, 0)))
    }

    @Test("a span given in REVERSE order still removes the same inner span")
    func breakLineSpanReversed() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)
        _ = tool.handle(.click(Vector(7, 0)), context: ctx)   // first at x=7
        let outcome = tool.handle(.click(Vector(3, 0)), context: ctx)  // second at x=3

        guard let (_, adds) = removeAndAdds(outcome), case .line(let a) = adds[0],
              case .line(let b) = adds[1] else {
            Issue.record("expected two line pieces"); return
        }
        #expect(approx(a.end, Vector(3, 0)))
        #expect(approx(b.start, Vector(7, 0)))
    }

    // MARK: - Brief requirement: break an arc at a point → two arcs covering the sweep

    @Test("breaking an arc at a point yields two sub-arcs that re-cover the original sweep")
    func breakArcAtPoint() {
        var tool = BreakTool(pickTolerance: 0.5)
        // CCW quarter arc, center origin, r=5: start 0° at (5,0), end 90° at (0,5).
        let arc = EntityRecord(
            id: Self.arcID,
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi / 2, reversed: false))
        )
        let ctx = Self.context(over: [arc])

        // Break at 45° point ≈ (5/√2, 5/√2).
        let p45 = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))
        _ = tool.handle(.click(p45), context: ctx)            // pick entity
        _ = tool.handle(.click(p45), context: ctx)            // first break point
        let outcome = tool.handle(.commit, context: ctx)      // split

        guard let (removed, adds) = removeAndAdds(outcome) else {
            Issue.record("expected a .remove + .add(s) commit"); return
        }
        #expect(removed == Self.arcID)
        #expect(adds.count == 2)
        guard case .arc(let a) = adds[0], case .arc(let b) = adds[1] else {
            Issue.record("expected two arc pieces"); return
        }
        // Piece 1: 0° → 45°; piece 2: 45° → 90°.
        #expect(abs(a.startAngle - 0) < 1e-9)
        #expect(abs(a.endAngle - .pi / 4) < 1e-9)
        #expect(abs(b.startAngle - .pi / 4) < 1e-9)
        #expect(abs(b.endAngle - .pi / 2) < 1e-9)
        #expect(a.center == Vector(0, 0))
        #expect(a.radius == 5)
        #expect(b.radius == 5)
        // The two sub-arc sweeps sum to the original 90° sweep.
        let total = arcSweep(adds[0])! + arcSweep(adds[1])!
        #expect(abs(total - .pi / 2) < 1e-9)
    }

    // MARK: - Polyline split at a vertex

    @Test("breaking a 3-vertex polyline at its middle vertex yields two open pieces")
    func breakPolylineAtVertex() {
        var tool = BreakTool(pickTolerance: 0.5)
        let pl = EntityRecord(id: Self.plID, kind: .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(5, 0)),
            PolylineVertex(point: Vector(5, 5)),
        ])))
        let ctx = Self.context(over: [pl])

        _ = tool.handle(.click(Vector(5, 0)), context: ctx)   // pick (on the middle vertex)
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)   // first break point
        let outcome = tool.handle(.commit, context: ctx)      // split

        guard let (removed, adds) = removeAndAdds(outcome) else {
            Issue.record("expected a .remove + .add(s) commit"); return
        }
        #expect(removed == Self.plID)
        #expect(adds.count == 2)
        guard case .polyline(let a) = adds[0], case .polyline(let b) = adds[1] else {
            Issue.record("expected two polyline pieces"); return
        }
        #expect(a.closed == false)
        #expect(b.closed == false)
        // Piece 1 runs (0,0) → (5,0); piece 2 runs (5,0) → (5,5).
        #expect(approx(a.vertices.first!.point, Vector(0, 0)))
        #expect(approx(a.vertices.last!.point, Vector(5, 0)))
        #expect(approx(b.vertices.first!.point, Vector(5, 0)))
        #expect(approx(b.vertices.last!.point, Vector(5, 5)))
    }

    // MARK: - No-op paths

    @Test("clicking empty space picks no entity → no-op")
    func emptyAreaNoOp() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
    }

    @Test("breaking exactly at an endpoint yields no real split → no commit")
    func breakAtEndpointNoOp() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)   // pick (at the start endpoint)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)   // first point at the endpoint
        #expect(tool.handle(.commit, context: ctx) == .none)  // no half on the start side
    }

    // MARK: - Lifecycle

    @Test("cancel finishes the run")
    func cancelFinishes() {
        var tool = BreakTool()
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }

    @Test("backspace steps back from the second-point phase")
    func backspaceSteps() {
        var tool = BreakTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)   // pick
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)   // first point
        #expect(tool.handle(.backspace, context: ctx) == .none)  // back to first-point phase
    }
}
