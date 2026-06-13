//
//  ExtendToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Extend tool PURELY (no GUI): feeds `.click` events + a
//  hand-built `ToolContext` whose boundary hooks (`nearbyEntities`/`allEntities`)
//  scan a fixed record set, and asserts the commit shape (one `.replace` of the
//  target with the endpoint/angle moved out to the nearest beyond-the-end
//  boundary), the which-end selection (right end vs left end), the arc-extension
//  case, and the no-op paths (no boundary beyond the end, empty-area click).
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ExtendTool editing (extend to boundary)")
struct ExtendToolTests {

    // MARK: - Fixtures

    /// A `ToolContext` whose boundary hooks scan `records` with the SAME exact-
    /// distance semantics the app's `makeToolContext` wires up (visible-only,
    /// `HitTesting.worldDistance` for the pick). Mirrors `ToolContextTests`.
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

    private static let targetID = EntityID(1)
    private static let boundaryID = EntityID(2)

    /// A short horizontal line (0,0)-(4,0), the extend target.
    private static func shortLine() -> EntityRecord {
        EntityRecord(id: targetID, kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0))))
    }

    /// A vertical boundary line at x=10, from (10,-5) to (10,5).
    private static func boundaryAtX10() -> EntityRecord {
        EntityRecord(id: boundaryID, kind: .line(LineData(start: Vector(10, -5), end: Vector(10, 5))))
    }

    /// A vertical boundary line at x=-5, from (-5,-5) to (-5,5).
    private static func boundaryAtXMinus5() -> EntityRecord {
        EntityRecord(id: boundaryID, kind: .line(LineData(start: Vector(-5, -5), end: Vector(-5, 5))))
    }

    /// Pulls the single `.replace`d kind out of a `.commit`, or `nil` if the
    /// outcome isn't a one-edit `.replace` commit.
    private func replaced(_ outcome: ToolOutcome) -> (EntityID, EntityKind)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0] else { return nil }
        return (id, kind)
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-6) -> Bool {
        a.distance(to: b) < tol
    }

    // MARK: - Metadata

    @Test("title is Extend")
    func title() {
        #expect(ExtendTool().title == "Extend")
    }

    // MARK: - Line: extend the right end to a boundary

    @Test("click near the right end extends the line out to the boundary at x=10")
    func extendRightEndToBoundary() {
        var tool = ExtendTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.shortLine(), Self.boundaryAtX10()])

        // Click right on the right end (4,0): the right end extends to (10,0).
        let outcome = tool.handle(.click(Vector(4, 0)), context: ctx)
        guard let (id, kind) = replaced(outcome) else {
            Issue.record("expected a single .replace commit"); return
        }
        #expect(id == Self.targetID)
        guard case .line(let d) = kind else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(0, 0)))   // anchor (left end) unchanged
        #expect(approx(d.end, Vector(10, 0)))    // right end moved out to the boundary
    }

    // MARK: - Line: extend the left end to a boundary

    @Test("click near the left end extends the line out to the boundary at x=-5")
    func extendLeftEndToBoundary() {
        var tool = ExtendTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.shortLine(), Self.boundaryAtXMinus5()])

        // Click right on the left end (0,0): the left end extends to (-5,0).
        let outcome = tool.handle(.click(Vector(0, 0)), context: ctx)
        guard let (id, kind) = replaced(outcome) else {
            Issue.record("expected a single .replace commit"); return
        }
        #expect(id == Self.targetID)
        guard case .line(let d) = kind else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(-5, 0)))  // left end moved out to the boundary
        #expect(approx(d.end, Vector(4, 0)))     // anchor (right end) unchanged
    }

    // MARK: - Line: nearest-of-many boundaries beyond the end

    @Test("with two boundaries beyond the end the NEAREST one wins")
    func nearestBoundaryWins() {
        var tool = ExtendTool(pickTolerance: 0.5)
        let near = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(7, -3), end: Vector(7, 3))))
        let far = EntityRecord(id: EntityID(3), kind: .line(LineData(start: Vector(12, -3), end: Vector(12, 3))))
        let ctx = Self.context(over: [Self.shortLine(), near, far])

        let outcome = tool.handle(.click(Vector(4, 0)), context: ctx)
        guard let (_, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace"); return
        }
        #expect(approx(d.end, Vector(7, 0)))   // the nearer boundary (x=7), not x=12
    }

    // MARK: - No boundary beyond the end → no-op

    @Test("no boundary beyond the chosen end is a no-op")
    func noBoundaryBeyondEndNoOp() {
        var tool = ExtendTool(pickTolerance: 0.5)
        // The only boundary (x=-5) is BEHIND the right end, not beyond it.
        let ctx = Self.context(over: [Self.shortLine(), Self.boundaryAtXMinus5()])

        // Click near the RIGHT end (4,0): nothing lies to the right → no-op.
        let outcome = tool.handle(.click(Vector(4, 0)), context: ctx)
        #expect(outcome == .none)
    }

    @Test("a boundary that only crosses the line BETWEEN the ends (not beyond) is a no-op")
    func boundaryBetweenEndsNoOp() {
        var tool = ExtendTool(pickTolerance: 0.5)
        // A boundary at x=2 crosses the segment between (0,0) and (4,0) — that is
        // not BEYOND either end, so clicking the right end finds nothing beyond it.
        let mid = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(2, -3), end: Vector(2, 3))))
        let ctx = Self.context(over: [Self.shortLine(), mid])

        let outcome = tool.handle(.click(Vector(4, 0)), context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Empty-area click → no-op

    @Test("clicking in empty space (no target under the pick) is a no-op")
    func emptyAreaNoOp() {
        var tool = ExtendTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.shortLine(), Self.boundaryAtX10()])

        // (50,50) is far from any entity: no target → no-op.
        let outcome = tool.handle(.click(Vector(50, 50)), context: ctx)
        #expect(outcome == .none)
    }

    @Test("empty drawing: a click is a no-op")
    func emptyDrawingNoOp() {
        var tool = ExtendTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [])
        #expect(tool.handle(.click(Vector(0, 0)), context: ctx) == .none)
    }

    // MARK: - Arc: extend the end angle to a boundary

    @Test("an arc extends its end angle out to a boundary on its circle")
    func extendArcEndToBoundary() {
        var tool = ExtendTool(pickTolerance: 0.5)
        // CCW quarter arc, center origin, r=5: start 0° at (5,0), end 90° at (0,5).
        let arc = EntityRecord(
            id: Self.targetID,
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi / 2, reversed: false))
        )
        // Short vertical boundary at x=-5 crossing the full circle ONLY at (-5,0)
        // (angle 180°), which is beyond the 90° end in the CCW sweep direction.
        let boundary = EntityRecord(
            id: Self.boundaryID,
            kind: .line(LineData(start: Vector(-5, -1), end: Vector(-5, 1)))
        )
        let ctx = Self.context(over: [arc, boundary])

        // Click on the END endpoint (0,5).
        let outcome = tool.handle(.click(Vector(0, 5)), context: ctx)
        guard let (id, kind) = replaced(outcome), case .arc(let d) = kind else {
            Issue.record("expected an arc .replace"); return
        }
        #expect(id == Self.targetID)
        #expect(approx(d.center, Vector(0, 0)))
        #expect(d.radius == 5)
        #expect(d.startAngle == 0)                       // start end unchanged
        #expect(abs(d.endAngle - .pi) < 1e-9)            // end grown to 180° (-5,0)
        #expect(d.reversed == false)                     // sweep direction preserved
        // The new end endpoint sits at (-5,0).
        let endP = d.center + Vector.polar(radius: d.radius, angle: d.endAngle)
        #expect(approx(endP, Vector(-5, 0)))
    }

    @Test("an arc with no boundary beyond the end is a no-op")
    func extendArcNoBoundaryNoOp() {
        var tool = ExtendTool(pickTolerance: 0.5)
        let arc = EntityRecord(
            id: Self.targetID,
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi / 2, reversed: false))
        )
        // A boundary far from the arc's circle (radius 5) — no intersection at all.
        let boundary = EntityRecord(
            id: Self.boundaryID,
            kind: .line(LineData(start: Vector(50, -1), end: Vector(50, 1)))
        )
        let ctx = Self.context(over: [arc, boundary])
        #expect(tool.handle(.click(Vector(0, 5)), context: ctx) == .none)
    }

    // MARK: - Lifecycle

    @Test("cancel finishes the run")
    func cancelFinishes() {
        var tool = ExtendTool()
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }

    @Test("move produces no preview / no outcome")
    func moveNoOp() {
        var tool = ExtendTool()
        #expect(tool.handle(.move(Vector(1, 1)), context: .empty) == .none)
        #expect(tool.preview.isEmpty)
    }
}
