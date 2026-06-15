//
//  TrimDispatchTests.swift
//  CADEngineTests
//
//  Drives the TRIM tool's interactive `handle(_:_:)` DISPATCH across its three
//  modes PURELY (no GUI): feeds `ToolInput` events + a hand-built `ToolContext`
//  whose boundary hooks (`nearbyEntities` / `allEntities`) scan a known entity set,
//  and asserts each mode produces the right edits through the CLICK path (not just
//  the static entry points covered by `TrimAmountTests`):
//
//    - `.boundary` (the default): a single click still emits ONE `.replace` cutting
//      the clicked target to the nearest crossing — UNCHANGED from the original.
//    - `.amount`:   a single click on a LINE/ARC near an end emits ONE `.replace`
//      shortened/lengthened by the tool's signed `amount` (single-end, or both ends
//      when `amountBoth`).
//    - `.mutual`:   TWO clicks (with the usual in-progress state between them) emit
//      TWO `.replace`s reshaping both entities to their mutual intersection.
//
//  Also asserts the mode default is `.boundary` and that the in-progress second-pick
//  state for `.mutual` cancels / backspaces cleanly.
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

@Suite("TrimTool handle dispatch (boundary / amount / mutual)")
struct TrimDispatchTests {

    // MARK: - Context fixture

    /// Builds a `ToolContext` whose boundary hooks scan `records` with the SAME
    /// exact-distance semantics the app's `makeToolContext` wires up (mirrors
    /// `TrimToolTests`): `nearbyEntities` returns visible records within tolerance by
    /// `HitTesting.worldDistance`, `allEntities` returns the full snapshot.
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

    /// Pulls the single `.replace(id, kind)` out of a `.commit` outcome, or `nil`
    /// if the outcome isn't exactly one `.replace`.
    private func oneReplace(_ outcome: ToolOutcome) -> (id: EntityID, kind: EntityKind)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0] else { return nil }
        return (id, kind)
    }

    /// Pulls TWO `.replace`s out of a `.commit` outcome (the `.mutual` shape), or
    /// `nil` if the outcome isn't exactly two `.replace`s.
    private func twoReplaces(_ outcome: ToolOutcome)
        -> (a: (id: EntityID, kind: EntityKind), b: (id: EntityID, kind: EntityKind))? {
        guard case .commit(let edits) = outcome, edits.count == 2,
              case .replace(let ia, let ka) = edits[0],
              case .replace(let ib, let kb) = edits[1] else { return nil }
        return ((ia, ka), (ib, kb))
    }

    private func line(_ k: EntityKind) -> LineData? {
        guard case .line(let d) = k else { return nil }
        return d
    }

    private func approx(_ a: Vector, _ b: Vector, _ eps: Double = 1e-9) -> Bool {
        a.distance(to: b) < eps
    }

    // MARK: - Fixtures

    /// Horizontal line (0,0)→(10,0). The trim TARGET in most cases.
    private static let hLine = EntityRecord(
        id: EntityID(1),
        flags: [.visible],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )

    /// Vertical line (5,-5)→(5,5) crossing the h-line at (5,0). The BOUNDARY.
    private static let vLine = EntityRecord(
        id: EntityID(2),
        flags: [.visible],
        kind: .line(LineData(start: Vector(5, -5), end: Vector(5, 5)))
    )

    // MARK: - Default mode

    @Test("a freshly minted TrimTool defaults to .boundary mode")
    func defaultModeIsBoundary() {
        let tool = TrimTool()
        #expect(tool.mode == .boundary)
    }

    // MARK: - .boundary (must be unchanged)

    @Test(".boundary: a click cuts the clicked overhang to the crossing (unchanged)")
    func boundaryClickCutsToCrossing() {
        var tool = TrimTool()
        tool.mode = .boundary
        let ctx = Self.context(over: [Self.hLine, Self.vLine])

        // Click the right overhang → keep (0,0)-(5,0) (same as TrimToolTests).
        let outcome = tool.handle(.click(Vector(8, 0)), context: ctx)
        guard let r = oneReplace(outcome), let d = line(r.kind) else {
            Issue.record("expected a single .replace with a line, got \(outcome)")
            return
        }
        #expect(r.id == EntityID(1))
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(5, 0)))
    }

    // MARK: - .amount

    @Test(".amount: a click near the END lengthens that end by +amount")
    func amountClickGrowsEnd() {
        var tool = TrimTool()
        tool.mode = .amount
        tool.amount = 2
        // No boundary needed — a lone target line.
        let ctx = Self.context(over: [Self.hLine])

        // Click near the END (9,0) → +2 grows the end to (12,0); start unchanged.
        let outcome = tool.handle(.click(Vector(9, 0)), context: ctx)
        guard let r = oneReplace(outcome), let d = line(r.kind) else {
            Issue.record("expected a single .replace with a line, got \(outcome)")
            return
        }
        #expect(r.id == EntityID(1))
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(12, 0)))
    }

    @Test(".amount: a negative amount near the END shortens that end")
    func amountClickShrinksEnd() {
        var tool = TrimTool()
        tool.mode = .amount
        tool.amount = -3
        let ctx = Self.context(over: [Self.hLine])

        // Click near the END (9,0) → -3 shrinks the end inward to (7,0).
        let outcome = tool.handle(.click(Vector(9, 0)), context: ctx)
        guard let r = oneReplace(outcome), let d = line(r.kind) else {
            Issue.record("expected a single .replace with a line, got \(outcome)")
            return
        }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(7, 0)))
    }

    @Test(".amount (both ends): the same signed amount is applied to BOTH ends")
    func amountBothEnds() {
        var tool = TrimTool()
        tool.mode = .amount
        tool.amount = 2
        tool.amountBoth = true
        let ctx = Self.context(over: [Self.hLine])

        // +2 to both ends → (-2,0)-(12,0).
        let outcome = tool.handle(.click(Vector(9, 0)), context: ctx)
        guard let r = oneReplace(outcome), let d = line(r.kind) else {
            Issue.record("expected a single .replace with a line, got \(outcome)")
            return
        }
        #expect(approx(d.start, Vector(-2, 0)))
        #expect(approx(d.end, Vector(12, 0)))
    }

    @Test(".amount: a zero amount is a no-op")
    func amountZeroNoop() {
        var tool = TrimTool()
        tool.mode = .amount
        tool.amount = 0
        let ctx = Self.context(over: [Self.hLine])
        #expect(tool.handle(.click(Vector(9, 0)), context: ctx) == .none)
    }

    @Test(".amount: a click in empty space (no target) is a no-op")
    func amountNoTargetNoop() {
        var tool = TrimTool()
        tool.mode = .amount
        tool.amount = 2
        let ctx = Self.context(over: [Self.hLine])
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
    }

    @Test(".amount: no boundary pick — the FIRST click commits (single-pick action)")
    func amountIsSinglePick() {
        var tool = TrimTool()
        tool.mode = .amount
        tool.amount = 2
        let ctx = Self.context(over: [Self.hLine])
        if case .commit = tool.handle(.click(Vector(9, 0)), context: ctx) {} else {
            Issue.record(".amount must commit on the first (only) click")
        }
    }

    // MARK: - .mutual

    @Test(".mutual: two crossing lines are BOTH cut to the intersection on two clicks")
    func mutualTwoClicksCutBoth() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])

        // FIRST click on the h-line near its LEFT (keep the left) — in-progress.
        let first = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(first == .none)   // first pick advances state, no commit yet

        // SECOND click on the v-line near its LOWER (keep the lower) — commits.
        let outcome = tool.handle(.click(Vector(5, -3)), context: ctx)
        guard let r = twoReplaces(outcome) else {
            Issue.record("expected two .replace edits, got \(outcome)")
            return
        }
        // A (h-line, id 1) keeps (0,0)-(5,0): the far END pulled to the crossing.
        #expect(r.a.id == EntityID(1))
        guard let la = line(r.a.kind) else { Issue.record("expected line A"); return }
        #expect(approx(la.start, Vector(0, 0)))
        #expect(approx(la.end, Vector(5, 0)))
        // B (v-line, id 2) keeps (5,-5)-(5,0): the far (upper) END pulled in.
        #expect(r.b.id == EntityID(2))
        guard let lb = line(r.b.kind) else { Issue.record("expected line B"); return }
        #expect(approx(lb.start, Vector(5, -5)))
        #expect(approx(lb.end, Vector(5, 0)))
    }

    @Test(".mutual: the OTHER picked sides cut the complementary portions")
    func mutualOtherSides() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])

        _ = tool.handle(.click(Vector(8, 0)), context: ctx)        // keep RIGHT of A
        let outcome = tool.handle(.click(Vector(5, 3)), context: ctx)  // keep UPPER of B
        guard let r = twoReplaces(outcome),
              let la = line(r.a.kind), let lb = line(r.b.kind) else {
            Issue.record("expected two line .replace edits, got \(outcome)")
            return
        }
        #expect(approx(la.start, Vector(5, 0)))
        #expect(approx(la.end, Vector(10, 0)))
        #expect(approx(lb.start, Vector(5, 0)))
        #expect(approx(lb.end, Vector(5, 5)))
    }

    @Test(".mutual: the first click does NOT commit (waits for the second entity)")
    func mutualFirstClickNoCommit() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        let first = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(first == .none)
    }

    @Test(".mutual: a first click in empty space keeps waiting (no-op)")
    func mutualFirstClickEmptyNoop() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
        // Still on the first pick: a real first + second click now commits.
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        if case .commit = tool.handle(.click(Vector(5, -3)), context: ctx) {} else {
            Issue.record("a valid two-pick run should commit after the empty first click")
        }
    }

    @Test(".mutual: cancel during the second pick discards the in-progress run")
    func mutualCancelResetsSecondPick() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)   // first pick made
        #expect(tool.handle(.cancel, context: ctx) == .finished)
    }

    @Test(".mutual: backspace during the second pick steps back to the first pick")
    func mutualBackspaceStepsBack() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)   // first pick made
        #expect(tool.handle(.backspace, context: ctx) == .preview)
        // Back at the first pick: a fresh two-pick run still commits.
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        if case .commit = tool.handle(.click(Vector(5, -3)), context: ctx) {} else {
            Issue.record("after backspace a fresh two-pick run should commit")
        }
    }

    @Test(".mutual: the second pick can't re-pick the first entity (no-op, keeps waiting)")
    func mutualSecondPickExcludesFirst() {
        var tool = TrimTool()
        tool.mode = .mutual
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)   // first = h-line
        // A second click on the SAME h-line (near (8,0)) excludes it → no-op.
        #expect(tool.handle(.click(Vector(8, 0)), context: ctx) == .none)
    }
}
