//
//  TrimAmountTests.swift
//  CADEngineTests
//
//  Drives the TWO additional, UNWIRED trim modes added to `TrimTool` PURELY (no
//  GUI, no ToolContext) via their static entry points:
//
//    1. Trim by amount — `TrimTool.trimAmount(_:near:distance:)` /
//       `trimAmountBoth(_:distance:)` (LibreCAD `RS_ActionModifyTrimAmount`):
//       shorten OR lengthen a LINE/ARC at a chosen end by a signed distance,
//       optionally by a desired TOTAL length, optionally symmetric (both ends).
//
//    2. Mutual trim / trim-2 — `TrimTool.mutualTrim(_:pickA:_:pickB:)`
//       (LibreCAD trim2): trim/extend BOTH entities to their mutual intersection.
//
//  Covers: line + arc trim-by-amount (grow / shrink / total-length / symmetric /
//  degenerate-collapse no-op), and mutual trim for intersecting / collinear /
//  non-intersecting / extend-the-gap / arc cases — asserting the resulting
//  geometry numerically. Also asserts the EXISTING single-boundary trim entry
//  point (`TrimTool.trim(at:context:)`) is unchanged by these additions.
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

@Suite("TrimTool extra modes (trim-by-amount + mutual trim)")
struct TrimAmountTests {

    // MARK: - Helpers

    private func line(_ k: EntityKind?) -> LineData? {
        guard case .line(let d)? = k else { return nil }
        return d
    }

    private func arc(_ k: EntityKind?) -> ArcData? {
        guard case .arc(let d)? = k else { return nil }
        return d
    }

    private func approx(_ a: Vector, _ b: Vector, _ eps: Double = 1e-9) -> Bool {
        a.distance(to: b) < eps
    }

    // ----------------------------------------------------------------------
    // MARK: Mode 1 — trim by amount (line)
    // ----------------------------------------------------------------------

    @Test("trim-by-amount: positive distance LENGTHENS the line at the picked (end) side")
    func amountLineGrowEnd() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // Pick near the END → the end moves. +2 grows the line to (0,0)-(12,0).
        let out = TrimTool.trimAmount(l, near: Vector(9, 0), distance: 2)
        guard let d = line(out) else { Issue.record("expected a line, got \(String(describing: out))"); return }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(12, 0)))
    }

    @Test("trim-by-amount: negative distance SHORTENS the line at the picked (end) side")
    func amountLineShrinkEnd() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // Pick near the END → -3 shrinks the end inward to (7,0).
        let out = TrimTool.trimAmount(l, near: Vector(9, 0), distance: -3)
        guard let d = line(out) else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(7, 0)))
    }

    @Test("trim-by-amount: picking near the START moves the start, keeping the end fixed")
    func amountLineStartSide() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // Pick near the START → -2 shrinks the start inward to (2,0); end fixed.
        let out = TrimTool.trimAmount(l, near: Vector(1, 0), distance: -2)
        guard let d = line(out) else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(2, 0)))
        #expect(approx(d.end, Vector(10, 0)))
    }

    @Test("trim-by-amount (total length): distance is the desired TOTAL length")
    func amountLineTotalLength() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // byTotalLength: desired total 6 → delta = 6 - 10 = -4 at the END → (6,0).
        let out = TrimTool.trimAmount(l, near: Vector(9, 0), distance: 6, byTotalLength: true)
        guard let d = line(out) else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(6, 0)))
        #expect(abs(d.start.distance(to: d.end) - 6) < 1e-9)
    }

    @Test("trim-by-amount (symmetric): the same signed distance is applied to BOTH ends")
    func amountLineSymmetric() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // +2 to both ends → (-2,0)-(12,0): the line grows by 2 at each end.
        let out = TrimTool.trimAmountBoth(l, distance: 2)
        guard let d = line(out) else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(-2, 0)))
        #expect(approx(d.end, Vector(12, 0)))
    }

    @Test("trim-by-amount: a zero distance is a no-op (nil)")
    func amountZeroNoop() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        #expect(TrimTool.trimAmount(l, near: Vector(9, 0), distance: 0) == nil)
    }

    @Test("trim-by-amount: shrinking past the whole length collapses → nil")
    func amountCollapseNoop() {
        let l = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // -20 would invert the line → rejected.
        #expect(TrimTool.trimAmount(l, near: Vector(9, 0), distance: -20) == nil)
    }

    @Test("trim-by-amount: an unsupported kind (circle) is a no-op (nil)")
    func amountUnsupportedNoop() {
        let c = EntityKind.circle(CircleData(center: Vector(0, 0), radius: 5))
        #expect(TrimTool.trimAmount(c, near: Vector(5, 0), distance: 2) == nil)
    }

    // ----------------------------------------------------------------------
    // MARK: Mode 1 — trim by amount (arc)
    // ----------------------------------------------------------------------

    @Test("trim-by-amount (arc): positive distance grows the arc by arc-length at the picked end")
    func amountArcGrowEnd() {
        // Quarter arc, center origin, r=5, 0 → π/2 (CCW). Arc length 5·(π/2).
        let a = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 5,
                                       startAngle: 0, endAngle: .pi / 2, reversed: false))
        // Pick near the END point (0,5). +5 grows by 5/r = 1 rad → end angle π/2+1.
        let endP = Vector(0, 5)
        let out = TrimTool.trimAmount(a, near: endP, distance: 5)
        guard let d = arc(out) else { Issue.record("expected an arc"); return }
        #expect(abs(d.startAngle - 0) < 1e-9)
        #expect(abs(d.endAngle - (.pi / 2 + 1)) < 1e-9)
        #expect(d.radius == 5)
    }

    @Test("trim-by-amount (arc): negative distance shrinks the arc by arc-length at the picked end")
    func amountArcShrinkEnd() {
        let a = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 5,
                                       startAngle: 0, endAngle: .pi / 2, reversed: false))
        // Pick near the END (0,5). -5 shrinks by 1 rad → end angle π/2-1.
        let out = TrimTool.trimAmount(a, near: Vector(0, 5), distance: -5)
        guard let d = arc(out) else { Issue.record("expected an arc"); return }
        #expect(abs(d.startAngle - 0) < 1e-9)
        #expect(abs(d.endAngle - (.pi / 2 - 1)) < 1e-9)
    }

    @Test("trim-by-amount (arc, total length): distance is the desired arc length")
    func amountArcTotalLength() {
        // Quarter arc r=5 → current arc length 5·π/2 ≈ 7.854.
        let a = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 5,
                                       startAngle: 0, endAngle: .pi / 2, reversed: false))
        // Desired total arc length = 5 → delta = 5 - 7.854 ≈ -2.854 at END.
        let out = TrimTool.trimAmount(a, near: Vector(0, 5), distance: 5, byTotalLength: true)
        guard let d = arc(out) else { Issue.record("expected an arc"); return }
        let sweep = MathUtils.getAngleDifference(d.startAngle, d.endAngle, reversed: d.reversed)
        #expect(abs(sweep * d.radius - 5) < 1e-9)   // resulting arc length == 5
    }

    // ----------------------------------------------------------------------
    // MARK: Mode 2 — mutual trim / trim-2 (line ↔ line)
    // ----------------------------------------------------------------------

    @Test("mutual trim: two crossing lines are BOTH cut to the intersection, keeping the picked side")
    func mutualLinesIntersect() {
        let a = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))   // horizontal
        let b = EntityKind.line(LineData(start: Vector(5, -5), end: Vector(5, 5)))   // vertical, crosses at (5,0)
        // Keep the LEFT of A (pick at (2,0)) and the LOWER of B (pick at (5,-3)).
        let out = TrimTool.mutualTrim(a, pickA: Vector(2, 0), b, pickB: Vector(5, -3))
        guard let r = out, let la = line(r.a), let lb = line(r.b) else {
            Issue.record("expected both lines, got \(String(describing: out))"); return
        }
        // A keeps (0,0)-(5,0): the far END is pulled to the crossing.
        #expect(approx(la.start, Vector(0, 0)))
        #expect(approx(la.end, Vector(5, 0)))
        // B keeps (5,-5)-(5,0): the far (upper) END is pulled to the crossing.
        #expect(approx(lb.start, Vector(5, -5)))
        #expect(approx(lb.end, Vector(5, 0)))
    }

    @Test("mutual trim: the OTHER picked sides cut the complementary portions")
    func mutualLinesOtherSides() {
        let a = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        let b = EntityKind.line(LineData(start: Vector(5, -5), end: Vector(5, 5)))
        // Keep the RIGHT of A (pick at (8,0)) and the UPPER of B (pick at (5,3)).
        let out = TrimTool.mutualTrim(a, pickA: Vector(8, 0), b, pickB: Vector(5, 3))
        guard let r = out, let la = line(r.a), let lb = line(r.b) else {
            Issue.record("expected both lines"); return
        }
        #expect(approx(la.start, Vector(5, 0)))
        #expect(approx(la.end, Vector(10, 0)))
        #expect(approx(lb.start, Vector(5, 0)))
        #expect(approx(lb.end, Vector(5, 5)))
    }

    @Test("mutual trim: a GAP is closed by EXTENDING both lines to the carrier intersection")
    func mutualLinesExtendGap() {
        // A stops short at x=4; B is a vertical above the axis. Carriers cross at (5,0).
        let a = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(4, 0)))
        let b = EntityKind.line(LineData(start: Vector(5, 1), end: Vector(5, 5)))
        let out = TrimTool.mutualTrim(a, pickA: Vector(2, 0), b, pickB: Vector(5, 3))
        guard let r = out, let la = line(r.a), let lb = line(r.b) else {
            Issue.record("expected both lines"); return
        }
        // A extends its END out to (5,0).
        #expect(approx(la.start, Vector(0, 0)))
        #expect(approx(la.end, Vector(5, 0)))
        // B extends its START down to (5,0).
        #expect(approx(lb.start, Vector(5, 0)))
        #expect(approx(lb.end, Vector(5, 5)))
    }

    @Test("mutual trim: collinear lines (no unique intersection) → nil")
    func mutualCollinearNoop() {
        // Two overlapping collinear segments on the x-axis have no single crossing.
        let a = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(6, 0)))
        let b = EntityKind.line(LineData(start: Vector(4, 0), end: Vector(10, 0)))
        #expect(TrimTool.mutualTrim(a, pickA: Vector(2, 0), b, pickB: Vector(9, 0)) == nil)
    }

    @Test("mutual trim: parallel non-intersecting lines → nil")
    func mutualParallelNoop() {
        let a = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        let b = EntityKind.line(LineData(start: Vector(0, 5), end: Vector(10, 5)))
        #expect(TrimTool.mutualTrim(a, pickA: Vector(2, 0), b, pickB: Vector(2, 5)) == nil)
    }

    @Test("mutual trim: an unsupported kind operand → nil")
    func mutualUnsupportedNoop() {
        let a = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        let circle = EntityKind.circle(CircleData(center: Vector(5, 0), radius: 2))
        #expect(TrimTool.mutualTrim(a, pickA: Vector(2, 0), circle, pickB: Vector(5, 2)) == nil)
    }

    // ----------------------------------------------------------------------
    // MARK: Mode 2 — mutual trim (arc ↔ line)
    // ----------------------------------------------------------------------

    @Test("mutual trim: an arc and a line are both reshaped to their nearest mutual crossing")
    func mutualArcLine() {
        // Upper-half arc center origin r=5 (0 → π). Vertical line through x=0.
        let a = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 5,
                                       startAngle: 0, endAngle: .pi, reversed: false))
        let b = EntityKind.line(LineData(start: Vector(0, -6), end: Vector(0, 6)))
        // Circle ∩ line at (0,5) and (0,-5); picks near (0,3) select the (0,5) crossing.
        let arcPick = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))   // ~angle π/4, the start side
        let out = TrimTool.mutualTrim(a, pickA: arcPick, b, pickB: Vector(0, 3))
        guard let r = out, let da = arc(r.a), let lb = line(r.b) else {
            Issue.record("expected an arc + a line, got \(String(describing: out))"); return
        }
        // Arc: pick is angularly nearer the START → START moves to (0,5) = π/2.
        #expect(abs(da.startAngle - .pi / 2) < 1e-6)
        #expect(abs(da.endAngle - .pi) < 1e-6)
        // Line: keep the lower portion → the upper END is pulled to (0,5).
        #expect(approx(lb.start, Vector(0, -6)))
        #expect(approx(lb.end, Vector(0, 5)))
    }

    @Test("mutual trim: two arcs are reshaped to their mutual crossing")
    func mutualArcArc() {
        // Two circles r=5: centers (0,0) and (8,0). They cross at x=4, y=±3.
        let a = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 5,
                                       startAngle: 0, endAngle: .pi, reversed: false))   // upper half
        let b = EntityKind.arc(ArcData(center: Vector(8, 0), radius: 5,
                                       startAngle: 0, endAngle: .pi, reversed: false))   // upper half
        // Pick the upper crossing (4,3) on both via near-points around it.
        let out = TrimTool.mutualTrim(a, pickA: Vector(4, 4), b, pickB: Vector(4, 4))
        guard let r = out, let da = arc(r.a), let db = arc(r.b) else {
            Issue.record("expected two arcs, got \(String(describing: out))"); return
        }
        // Both arcs now terminate at the (4,3) crossing on their own circle.
        let cross = Vector(4, 3)
        let aEnd = da.center + Vector.polar(radius: da.radius, angle: da.endAngle)
        let aStart = da.center + Vector.polar(radius: da.radius, angle: da.startAngle)
        #expect(approx(aEnd, cross, 1e-6) || approx(aStart, cross, 1e-6))
        let bEnd = db.center + Vector.polar(radius: db.radius, angle: db.endAngle)
        let bStart = db.center + Vector.polar(radius: db.radius, angle: db.startAngle)
        #expect(approx(bEnd, cross, 1e-6) || approx(bStart, cross, 1e-6))
    }

    // ----------------------------------------------------------------------
    // MARK: Regression — the EXISTING single-boundary trim is unchanged
    // ----------------------------------------------------------------------

    @Test("regression: the default single-boundary trim entry point still cuts to the crossing")
    func existingBoundaryTrimUnchanged() {
        // Mirror TrimToolTests: h-line crossed by a v-line, click the right overhang.
        let hLine = EntityRecord(id: EntityID(1),
                                 kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let vLine = EntityRecord(id: EntityID(2),
                                 kind: .line(LineData(start: Vector(5, -5), end: Vector(5, 5))))
        let byID = Dictionary(uniqueKeysWithValues: [hLine, vLine].map { ($0.id, $0) })
        let ctx = ToolContext(
            selected: [],
            entity: { byID[$0] },
            gridSpacing: nil,
            nearbyEntities: { p, tol in
                [hLine, vLine].filter { HitTesting.worldDistance(from: p, to: $0) <= Swift.max(tol, 0) }
            },
            allEntities: { [hLine, vLine] }
        )
        guard let result = TrimTool.trim(at: Vector(8, 0), context: ctx) else {
            Issue.record("the existing single-boundary trim must still produce a cut"); return
        }
        #expect(result.targetID == EntityID(1))
        guard let d = line(result.kind) else { Issue.record("expected a line"); return }
        #expect(approx(d.start, Vector(0, 0)))
        #expect(approx(d.end, Vector(5, 0)))   // cut to the crossing — same as before
    }

    @Test("regression: trim mode enum exposes the three modes with .boundary as the default semantics")
    func modeEnumPresent() {
        // The new modes are modeled but UNWIRED (no ToolKind case); assert the enum
        // surface a future wire-wave will switch on.
        let modes: [TrimTool.Mode] = [.boundary, .amount, .mutual]
        #expect(modes.count == 3)
        #expect(TrimTool.Mode.boundary != TrimTool.Mode.amount)
    }
}
