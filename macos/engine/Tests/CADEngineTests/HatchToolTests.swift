//
//  HatchToolTests.swift
//  CADEngineTests
//
//  Drives the HATCH tool PURELY (no GUI): feeds `ToolInput` events + a read-only
//  `ToolContext` carrying a known boundary selection and asserts the hatch
//  contract — activating Hatch with a usable closed boundary commits ONE `.add` of
//  a `.hatch` whose loop matches the boundary, and that hatch resolves to a
//  non-empty solid fill; an empty / open / invalid selection commits NOTHING.
//
//  Covered selections:
//   - a closed polyline   → one loop == the polyline's vertex ring; non-empty fill.
//   - a circle            → one tessellated loop; non-empty fill.
//   - a closed chain of lines (4 lines forming a square) → one assembled loop.
//   - an OPEN polyline / a single line / empty selection → no commit (no-op).
//   - two nested circles  → outer + hole (winding-normalized: outer CCW, hole CW).
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("HatchTool fill-from-selected-boundary")
struct HatchToolTests {

    // MARK: - Helpers

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: records,
            entity: { id in records.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    private func record(_ id: UInt64, _ kind: EntityKind,
                        layer: LayerID = LayerID("0")) -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: layer, kind: kind)
    }

    /// Extracts the single `.add`ed `.hatch` record from a commit, or nil if the
    /// outcome isn't a one-`.add`-of-a-hatch commit.
    private func committedHatch(_ outcome: ToolOutcome) -> (record: EntityRecord, data: HatchData)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let r) = edits[0], case .hatch(let d) = r.kind
        else { return nil }
        return (r, d)
    }

    /// The signed area (shoelace, CCW positive) of a point ring (no repeated first).
    private func signedArea(_ ring: [Vector]) -> Double {
        let n = ring.count
        guard n >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    private func closedSquarePolyline(_ side: Double = 10) -> EntityKind {
        .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(side, 0)),
            PolylineVertex(point: Vector(side, side)),
            PolylineVertex(point: Vector(0, side)),
        ], closed: true))
    }

    // MARK: - Basics

    @Test("title is Hatch")
    func title() {
        #expect(HatchTool().title == "Hatch")
    }

    @Test("status nudges to select a boundary when nothing is selected")
    func statusEmpty() {
        #expect(HatchTool().status == "Select closed boundary entities to hatch first")
    }

    // MARK: - Accepted: closed polyline

    @Test("a closed polyline commits one .hatch whose loop matches the boundary")
    func closedPolylineCommitsHatch() {
        var tool = HatchTool()
        let poly = record(1, closedSquarePolyline(10))
        let outcome = tool.handle(.commit, context: context([poly]))

        let result = committedHatch(outcome)
        try? #require(result != nil)
        guard let (rec, data) = result else { return }

        // One loop == the polyline's four corner vertices (no repeated first).
        #expect(data.loops.count == 1)
        let ringPts = Set(data.loops[0].map { $0.point })
        #expect(ringPts == Set([Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]))
        #expect(data.solidFill == true)
        #expect(data.patternName == "SOLID")
        // Added on the active (boundary's) layer, with a placeholder id to re-mint.
        #expect(rec.id == .placeholder)
        #expect(rec.layer == LayerID("0"))
    }

    @Test("the committed hatch resolves to a non-empty solid fill")
    func committedHatchResolvesToFill() {
        var tool = HatchTool()
        let poly = record(1, closedSquarePolyline(10))
        guard let (rec, _) = committedHatch(tool.handle(.commit, context: context([poly]))) else {
            Issue.record("expected a committed hatch")
            return
        }
        let geo = rec.resolve(ResolveContext())
        #expect(!geo.fills.isEmpty)
        #expect(geo.fills[0].loops.first.map { $0.count >= 3 } == true)
    }

    @Test("activating via .click also commits the hatch")
    func clickActivates() {
        var tool = HatchTool()
        let poly = record(1, closedSquarePolyline(10))
        #expect(committedHatch(tool.handle(.click(Vector(5, 5)), context: context([poly]))) != nil)
    }

    @Test("status reports ready once a usable boundary is captured")
    func statusReady() {
        var tool = HatchTool()
        let poly = record(1, closedSquarePolyline(10))
        // A move captures the selection without committing.
        _ = tool.handle(.move(Vector(5, 5)), context: context([poly]))
        #expect(tool.status == "Press Enter to fill the selected boundary")
    }

    // MARK: - Accepted: circle

    @Test("a circle commits a hatch whose tessellated loop resolves to a fill")
    func circleCommitsHatch() {
        var tool = HatchTool()
        let circle = record(1, .circle(CircleData(center: Vector(0, 0), radius: 5)))
        guard let (rec, data) = committedHatch(tool.handle(.commit, context: context([circle]))) else {
            Issue.record("expected a committed hatch for a circle")
            return
        }
        #expect(data.loops.count == 1)
        #expect(data.loops[0].count >= 3)            // tessellated ring
        #expect(!rec.resolve(ResolveContext()).fills.isEmpty)
        // The loop is CCW (outer boundary winding) → positive signed area.
        #expect(signedArea(data.loops[0].map { $0.point }) > 0)
    }

    // MARK: - Accepted: closed chain of lines

    @Test("four lines forming a square are chained into one closed loop")
    func lineChainCommitsHatch() {
        var tool = HatchTool()
        // Edges given out of order and with mixed directions to exercise chaining.
        let lines = [
            record(1, .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))),
            record(2, .line(LineData(start: Vector(10, 10), end: Vector(10, 0)))),  // reversed
            record(3, .line(LineData(start: Vector(0, 10), end: Vector(10, 10)))),
            record(4, .line(LineData(start: Vector(0, 0), end: Vector(0, 10)))),    // reversed
        ]
        guard let (rec, data) = committedHatch(tool.handle(.commit, context: context(lines))) else {
            Issue.record("expected a committed hatch for a closed line chain")
            return
        }
        #expect(data.loops.count == 1)
        let ringPts = Set(data.loops[0].map { $0.point })
        #expect(ringPts == Set([Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)]))
        #expect(!rec.resolve(ResolveContext()).fills.isEmpty)
    }

    // MARK: - Accepted: nested circles → outer + hole winding

    @Test("two nested circles become outer (CCW) + hole (CW)")
    func nestedCirclesWinding() {
        var tool = HatchTool()
        let outer = record(1, .circle(CircleData(center: Vector(0, 0), radius: 10)))
        let inner = record(2, .circle(CircleData(center: Vector(0, 0), radius: 4)))
        guard let (_, data) = committedHatch(tool.handle(.commit, context: context([outer, inner]))) else {
            Issue.record("expected a committed hatch for nested circles")
            return
        }
        #expect(data.loops.count == 2)
        // loops[0] is the largest (outer) → CCW (positive area); the hole is CW.
        let a0 = signedArea(data.loops[0].map { $0.point })
        let a1 = signedArea(data.loops[1].map { $0.point })
        #expect(a0 > 0)            // outer CCW
        #expect(a1 < 0)            // hole CW
        #expect(abs(a0) > abs(a1)) // outer is the bigger ring
    }

    // MARK: - Rejected: nothing committed

    @Test("an empty selection commits nothing")
    func emptyNoCommit() {
        var tool = HatchTool()
        #expect(tool.handle(.commit, context: .empty) == .none)
    }

    @Test("a single open line commits nothing (can't close a boundary)")
    func openLineNoCommit() {
        var tool = HatchTool()
        let line = record(1, .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        #expect(tool.handle(.commit, context: context([line])) == .none)
    }

    @Test("an OPEN polyline commits nothing")
    func openPolylineNoCommit() {
        var tool = HatchTool()
        let open = record(1, .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(10, 0)),
            PolylineVertex(point: Vector(10, 10)),
        ], closed: false)))
        #expect(tool.handle(.commit, context: context([open])) == .none)
    }

    @Test("a broken (non-closing) chain of lines commits nothing")
    func brokenChainNoCommit() {
        var tool = HatchTool()
        // An L of two lines that share one corner but don't close.
        let lines = [
            record(1, .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))),
            record(2, .line(LineData(start: Vector(10, 0), end: Vector(10, 10)))),
        ]
        #expect(tool.handle(.commit, context: context(lines)) == .none)
    }

    @Test("status flags an unusable selection")
    func statusUnusable() {
        var tool = HatchTool()
        let line = record(1, .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        _ = tool.handle(.move(Vector(0, 0)), context: context([line]))
        #expect(tool.status.contains("not a closed boundary"))
    }

    // MARK: - Lifecycle

    @Test("cancel discards the selection and finishes")
    func cancelFinishes() {
        var tool = HatchTool()
        let poly = record(1, closedSquarePolyline(10))
        _ = tool.handle(.move(Vector(0, 0)), context: context([poly]))
        #expect(tool.handle(.cancel, context: context([poly])) == .finished)
        // After cancel the captured selection is dropped → back to the nudge.
        #expect(tool.status == "Select closed boundary entities to hatch first")
    }

    @Test("move and backspace are no-ops")
    func inertInputs() {
        var tool = HatchTool()
        let poly = record(1, closedSquarePolyline(10))
        #expect(tool.handle(.move(Vector(1, 1)), context: context([poly])) == .none)
        #expect(tool.handle(.backspace, context: context([poly])) == .none)
    }
}
