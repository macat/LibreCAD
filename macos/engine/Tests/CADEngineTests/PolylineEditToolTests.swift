//
//  PolylineEditToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Polyline-Edit tool PURELY (no GUI): picks (or adopts) a
//  polyline, then MOVES / ADDS / REMOVES a vertex or TOGGLES a segment's arc, and
//  asserts the single `.replace(id, .polyline(newData))` commit shape and the
//  resulting `PolylineData` — a moved vertex moves (others fixed); an added vertex
//  raises the count by one at the right place; a removed vertex drops the count by
//  one; an arc-toggle flips the segment's bulge between 0 and the default arc; and
//  `closed` is preserved throughout.
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

@Suite("PolylineEditTool modify (move/add/remove/arc-toggle)")
struct PolylineEditToolModifyTests {

    // MARK: - Fixtures

    private static let plID = EntityID(7)

    /// An OPEN 3-vertex polyline: (0,0)-(10,0)-(10,10), all straight.
    private static func openPolyline() -> EntityRecord {
        EntityRecord(id: plID, kind: .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
        ], closed: false)))
    }

    /// A CLOSED square polyline: (0,0)-(10,0)-(10,10)-(0,10).
    private static func closedSquare() -> EntityRecord {
        EntityRecord(id: plID, kind: .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
            PolylineVertex(point: Vector(0, 10)),
        ], closed: true)))
    }

    /// A context that resolves ids and finds entities near a pick (visible only).
    private static func context(over records: [EntityRecord], selected: [EntityRecord] = []) -> ToolContext {
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

    /// Pulls the single `.replace`'s new PolylineData out of a `.commit`, or `nil`.
    private func replacedPolyline(_ outcome: ToolOutcome) -> (id: EntityID, data: PolylineData)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0],
              case .polyline(let d) = kind else { return nil }
        return (id, d)
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    // MARK: - Metadata

    @Test("title is Edit Polyline")
    func title() { #expect(PolylineEditTool().title == "Edit Polyline") }

    @Test("default arc bulge is a 90-degree quarter-circle (tan(pi/8))")
    func defaultBulge() {
        #expect(abs(PolylineEditTool.defaultArcBulge - tan(Double.pi / 8)) < 1e-12)
        #expect(abs(PolylineEditTool.defaultArcBulge - 0.41421356) < 1e-6)
    }

    // MARK: - MOVE a vertex: that vertex moves, others fixed

    @Test("moving a vertex moves only that vertex (others unchanged); closed preserved")
    func moveVertex() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .move)
        let ctx = Self.context(over: [Self.closedSquare()])

        // Pick the polyline (click on an edge), grab vertex #1 at (10,0), drop at (15,5).
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .preview)   // pick polyline
        #expect(tool.handle(.click(Vector(10, 0)), context: ctx) == .preview)  // grab vertex #1
        let outcome = tool.handle(.click(Vector(15, 5)), context: ctx)         // move it

        guard let (id, d) = replacedPolyline(outcome) else {
            Issue.record("expected a single .replace(.polyline) commit"); return
        }
        #expect(id == Self.plID)
        #expect(d.closed)                                  // closed preserved
        #expect(d.vertices.count == 4)                     // no vertex added/removed
        #expect(approx(d.vertices[1].point, Vector(15, 5)))// the grabbed vertex moved
        #expect(approx(d.vertices[0].point, Vector(0, 0))) // others fixed
        #expect(approx(d.vertices[2].point, Vector(10, 10)))
        #expect(approx(d.vertices[3].point, Vector(0, 10)))
    }

    @Test("a typed destination (.value) moves the grabbed vertex to the exact point")
    func moveVertexByTypedPoint() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .move)
        let ctx = Self.context(over: [Self.openPolyline()])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)    // pick polyline
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)    // grab vertex #0
        let outcome = tool.handle(.value(Vector(-3, -3)), context: ctx)
        guard let (_, d) = replacedPolyline(outcome) else {
            Issue.record("expected a .replace commit"); return
        }
        #expect(approx(d.vertices[0].point, Vector(-3, -3)))
    }

    @Test("an adopted selection edits without a separate pick click")
    func adoptSelection() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .move)
        let pl = Self.openPolyline()
        let ctx = Self.context(over: [pl], selected: [pl])
        // No pick click: the first click grabs a vertex directly.
        #expect(tool.handle(.click(Vector(10, 0)), context: ctx) == .preview)  // grab vertex #1
        let outcome = tool.handle(.click(Vector(20, 0)), context: ctx)
        guard let (_, d) = replacedPolyline(outcome) else {
            Issue.record("expected a .replace commit after adopting selection"); return
        }
        #expect(approx(d.vertices[1].point, Vector(20, 0)))
    }

    // MARK: - ADD a vertex on a segment: count +1, at the right place

    @Test("adding a vertex on a segment inserts it between the segment endpoints (count +1)")
    func addVertexOnSegment() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .add)
        let ctx = Self.context(over: [Self.openPolyline()])

        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .preview)   // pick polyline
        // Click on the FIRST segment (0,0)->(10,0) at x=5 → new vertex at (5,0).
        let outcome = tool.handle(.click(Vector(5, 0)), context: ctx)

        guard let (_, d) = replacedPolyline(outcome) else {
            Issue.record("expected a .replace commit"); return
        }
        #expect(d.vertices.count == 4)                          // 3 → 4
        #expect(approx(d.vertices[0].point, Vector(0, 0)))
        #expect(approx(d.vertices[1].point, Vector(5, 0)))      // inserted between #0 and old #1
        #expect(approx(d.vertices[2].point, Vector(10, 0)))     // old #1 shifted to #2
        #expect(approx(d.vertices[3].point, Vector(10, 10)))    // old #2 shifted to #3
        #expect(!d.closed)
    }

    // MARK: - REMOVE a vertex: count -1

    @Test("removing a vertex drops it (count -1); closed preserved")
    func removeVertex() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .remove)
        let ctx = Self.context(over: [Self.closedSquare()])

        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .preview)   // pick polyline
        // Click ON vertex #1 at (10,0) to remove it.
        let outcome = tool.handle(.click(Vector(10, 0)), context: ctx)

        guard let (_, d) = replacedPolyline(outcome) else {
            Issue.record("expected a .replace commit"); return
        }
        #expect(d.vertices.count == 3)                          // 4 → 3
        #expect(d.closed)                                       // closed preserved
        #expect(approx(d.vertices[0].point, Vector(0, 0)))
        #expect(approx(d.vertices[1].point, Vector(10, 10)))    // (10,0) gone
        #expect(approx(d.vertices[2].point, Vector(0, 10)))
    }

    @Test("removing a vertex that would leave fewer than 2 is refused (no-op)")
    func removeRefusedBelowTwo() {
        // A 2-vertex open polyline — removing either would leave 1 vertex.
        let pl = EntityRecord(id: Self.plID, kind: .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
        ], closed: false)))
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .remove)
        let ctx = Self.context(over: [pl])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)    // pick polyline
        let outcome = tool.handle(.click(Vector(0, 0)), context: ctx)
        #expect(outcome == .none)                               // refused
    }

    // MARK: - TOGGLE a segment between straight and arc

    @Test("arc-toggle flips a segment's bulge between 0 and the default arc value")
    func toggleSegmentArc() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .arc)
        let ctx = Self.context(over: [Self.openPolyline()])

        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .preview)   // pick polyline
        // Toggle the FIRST segment (start vertex #0) at x=5 → straight becomes arc.
        let outcome1 = tool.handle(.click(Vector(5, 0)), context: ctx)
        guard let (_, d1) = replacedPolyline(outcome1) else {
            Issue.record("expected a .replace commit (straight → arc)"); return
        }
        #expect(abs(d1.vertices[0].bulge - PolylineEditTool.defaultArcBulge) < 1e-12)
        #expect(d1.vertices.count == 3)                        // toggle never changes count
        #expect(abs(d1.vertices[1].bulge) < 1e-12)             // other segments untouched

        // Toggle the SAME segment again → arc becomes straight.
        let outcome2 = tool.handle(.click(Vector(5, 0)), context: ctx)
        guard let (_, d2) = replacedPolyline(outcome2) else {
            Issue.record("expected a .replace commit (arc → straight)"); return
        }
        #expect(abs(d2.vertices[0].bulge) < 1e-12)             // back to straight
    }

    @Test("arc-through a typed point sets the segment bulge so its arc passes through it")
    func arcThroughPoint() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .arc)
        let ctx = Self.context(over: [Self.openPolyline()])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)    // pick polyline
        _ = tool.handle(.move(Vector(5, 0)), context: ctx)     // hover the first segment
        // The chord is (0,0)->(10,0), |chord| = 10. A point 5 units to the LEFT
        // (i.e. above, +Y) of the chord midpoint gives sagitta = 5 → bulge = 1.0
        // (a semicircle). bulge = 2*s/|chord| = 2*5/10 = 1.0.
        let outcome = tool.handle(.value(Vector(5, 5)), context: ctx)
        guard let (_, d) = replacedPolyline(outcome) else {
            Issue.record("expected a .replace commit for arc-through"); return
        }
        #expect(abs(d.vertices[0].bulge - 1.0) < 1e-9)
    }

    // MARK: - Esc / state

    @Test("Esc cancels and finishes")
    func cancel() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .move)
        let ctx = Self.context(over: [Self.openPolyline()])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)    // pick polyline
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.status == "Click a polyline to edit")     // reset to start
    }

    @Test("clicking empty space (no polyline nearby) is a no-op")
    func pickMiss() {
        var tool = PolylineEditTool(pickTolerance: 0.5, mode: .move)
        let ctx = Self.context(over: [Self.openPolyline()])
        // Far from the polyline → nearbyEntities returns nothing.
        #expect(tool.handle(.click(Vector(100, 100)), context: ctx) == .none)
    }
}
