//
//  LengthenToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Lengthen tool PURELY (no GUI): picks a line / arc near
//  an end, then feeds a typed signed delta (`.value`) or a click point, and
//  asserts the lengthened geometry (the chosen end slid along the entity, the
//  other fixed), the which-end selection, the shorten case, and the no-op paths.
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

@Suite("LengthenTool modify (lengthen / shorten line & arc)")
struct LengthenToolModifyTests {

    // MARK: - Fixtures

    /// A `ToolContext` whose `nearbyEntities` scans `records` with the app's exact-
    /// distance, visible-only semantics (mirrors `ToolContextTests`).
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

    /// A 10-unit horizontal line (0,0)-(10,0).
    private static func line10() -> EntityRecord {
        EntityRecord(id: lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    private func replaced(_ outcome: ToolOutcome) -> (EntityID, EntityKind)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0] else { return nil }
        return (id, kind)
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    private func lineLength(_ d: LineData) -> Double { d.start.distance(to: d.end) }

    // MARK: - Metadata

    @Test("title is Lengthen")
    func title() { #expect(LengthenTool().title == "Lengthen") }

    // MARK: - Brief requirement: +5 on a 10-unit line → 15 on the chosen end

    @Test("a typed +5 delta on the right end extends a 10-unit line to 15 units")
    func extendLineByTypedDelta() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])

        // Pick near the RIGHT end (the end that will move).
        #expect(tool.handle(.click(Vector(10, 0)), context: ctx) == .none)
        // Type a bare distance +5 (the app feeds it as Vector(5,0)).
        let outcome = tool.handle(.value(Vector(5, 0)), context: ctx)

        guard let (id, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace"); return
        }
        #expect(id == Self.lineID)
        #expect(approx(d.start, Vector(0, 0)))          // anchor fixed
        #expect(approx(d.end, Vector(15, 0)))           // right end slid out +5
        #expect(abs(lineLength(d) - 15) < 1e-9)         // total length 15
    }

    @Test("a typed +5 delta on the LEFT end extends from the start, keeping the right end")
    func extendLineLeftEnd() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])

        // Pick near the LEFT end.
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let outcome = tool.handle(.value(Vector(5, 0)), context: ctx)

        guard let (_, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace"); return
        }
        #expect(approx(d.start, Vector(-5, 0)))   // left end slid out by 5 (away from anchor)
        #expect(approx(d.end, Vector(10, 0)))     // right end (anchor) fixed
        #expect(abs(lineLength(d) - 15) < 1e-9)
    }

    // MARK: - Shorten (negative delta)

    @Test("a typed −4 delta on the right end shortens a 10-unit line to 6 units")
    func shortenLine() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])

        _ = tool.handle(.click(Vector(10, 0)), context: ctx)
        let outcome = tool.handle(.value(Vector(-4, 0)), context: ctx)

        guard let (_, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace"); return
        }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(6, 0)))      // right end pulled in to length 6
    }

    @Test("a delta that would invert the line (≤ 0 length) is a no-op")
    func deltaInvertingLineNoOp() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        _ = tool.handle(.click(Vector(10, 0)), context: ctx)
        #expect(tool.handle(.value(Vector(-10, 0)), context: ctx) == .none)  // exactly 0
        // (state is reset on the no-op path only if it committed; -10 yields no commit)
    }

    // MARK: - Lengthen to a clicked point

    @Test("after picking, a click lengthens the right end to the projection of the point")
    func lengthenLineToPoint() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])

        _ = tool.handle(.click(Vector(10, 0)), context: ctx)    // pick near right end
        // Click at (20, 5): projects onto the x-axis at (20, 0).
        let outcome = tool.handle(.click(Vector(20, 5)), context: ctx)

        guard let (_, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace"); return
        }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(20, 0)))     // moved to the projection of the click
    }

    // MARK: - Arc: lengthen the end by a delta

    @Test("a typed delta extends an arc's end angle by delta/radius along the sweep")
    func extendArcByDelta() {
        var tool = LengthenTool(pickTolerance: 0.5)
        // CCW quarter arc, center origin, r=5: start 0° at (5,0), end 90° at (0,5).
        let arc = EntityRecord(
            id: Self.arcID,
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi / 2, reversed: false))
        )
        let ctx = Self.context(over: [arc])

        // Pick near the END endpoint (0,5).
        _ = tool.handle(.click(Vector(0, 5)), context: ctx)
        // Delta arc length +5: Δangle = 5/5 = 1 rad. New end angle = π/2 + 1.
        let outcome = tool.handle(.value(Vector(5, 0)), context: ctx)

        guard let (id, kind) = replaced(outcome), case .arc(let d) = kind else {
            Issue.record("expected an arc .replace"); return
        }
        #expect(id == Self.arcID)
        #expect(d.startAngle == 0)                          // start fixed
        #expect(abs(d.endAngle - (.pi / 2 + 1)) < 1e-9)     // end grown by 1 rad
        #expect(d.reversed == false)
        #expect(d.radius == 5)
    }

    @Test("a click lengthens an arc's end to the angle of the point on its circle")
    func lengthenArcToPoint() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let arc = EntityRecord(
            id: Self.arcID,
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi / 2, reversed: false))
        )
        let ctx = Self.context(over: [arc])

        _ = tool.handle(.click(Vector(0, 5)), context: ctx)  // pick near the end
        // Click at (-5, 0) → angle π; the end angle becomes π.
        let outcome = tool.handle(.click(Vector(-5, 0)), context: ctx)

        guard let (_, kind) = replaced(outcome), case .arc(let d) = kind else {
            Issue.record("expected an arc .replace"); return
        }
        #expect(d.startAngle == 0)
        #expect(abs(d.endAngle - .pi) < 1e-9)
    }

    // MARK: - No-op paths

    @Test("clicking empty space picks no target → no-op")
    func emptyAreaNoOp() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
    }

    @Test("a typed value before any target is picked is a no-op")
    func typedBeforePickNoOp() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        #expect(tool.handle(.value(Vector(5, 0)), context: ctx) == .none)
    }

    @Test("a zero delta is a no-op")
    func zeroDeltaNoOp() {
        var tool = LengthenTool(pickTolerance: 0.5)
        let ctx = Self.context(over: [Self.line10()])
        _ = tool.handle(.click(Vector(10, 0)), context: ctx)
        #expect(tool.handle(.value(Vector(0, 0)), context: ctx) == .none)
    }

    // MARK: - Lifecycle

    @Test("cancel finishes the run")
    func cancelFinishes() {
        var tool = LengthenTool()
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }
}
