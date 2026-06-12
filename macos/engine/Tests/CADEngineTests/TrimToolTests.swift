//
//  TrimToolTests.swift
//  CADEngineTests
//
//  Drives the TRIM editing tool PURELY (no GUI): feeds `ToolInput` events + a
//  hand-built `ToolContext` whose boundary hooks (`nearbyEntities` / `allEntities`)
//  scan a known entity set, and asserts the TRIM contract — that clicking the part
//  of a LINE or ARC to cut away emits one `.replace(targetID, shortenedKind)` that
//  removes the click-side overhang up to the NEAREST cutting intersection with
//  another entity, keeping the side away from the click.
//
//  Covers: a horizontal line crossed by a vertical line (click each side), an arc
//  crossed by a line, the no-target (empty area) no-op, the no-intersection target
//  no-op, the cancel reset, the preview, and that other-kind targets are skipped.
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

@Suite("TrimTool editing (click the overhang to cut away)")
struct TrimToolTests {

    // MARK: - Context fixture

    /// Builds a `ToolContext` whose boundary hooks scan `records` with the SAME
    /// exact-distance semantics the app's `makeToolContext` wires up: `nearbyEntities`
    /// returns visible records within tolerance by `HitTesting.worldDistance`,
    /// `allEntities` returns the full snapshot. (Mirrors `ToolContextTests`.)
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
    private func replacement(_ outcome: ToolOutcome) -> (id: EntityID, kind: EntityKind)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0] else { return nil }
        return (id, kind)
    }

    // MARK: - Fixtures: crossing lines

    /// Horizontal line (0,0)→(10,0). The trim TARGET.
    private static let hLine = EntityRecord(
        id: EntityID(1),
        layer: LayerID("walls"),
        pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )

    /// Vertical line (5,-5)→(5,5) crossing the h-line at (5,0). The BOUNDARY.
    private static let vLine = EntityRecord(
        id: EntityID(2),
        kind: .line(LineData(start: Vector(5, -5), end: Vector(5, 5)))
    )

    // MARK: - Crossing-line trim (the canonical cases)

    @Test("click right of the crossing removes the right overhang → (0,0)-(5,0)")
    func trimRightOverhang() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])

        let outcome = tool.handle(.click(Vector(8, 0)), context: ctx)
        guard let r = replacement(outcome) else {
            Issue.record("expected a single .replace commit, got \(outcome)")
            return
        }
        #expect(r.id == EntityID(1))   // the h-line target
        guard case .line(let d) = r.kind else {
            Issue.record("expected a line kind, got \(r.kind)")
            return
        }
        // The start (0,0) is kept; the end moves to the crossing (5,0).
        #expect(d.start == Vector(0, 0))
        #expect(d.end == Vector(5, 0))
    }

    @Test("click left of the crossing removes the left overhang → (5,0)-(10,0)")
    func trimLeftOverhang() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])

        let outcome = tool.handle(.click(Vector(2, 0)), context: ctx)
        guard let r = replacement(outcome) else {
            Issue.record("expected a single .replace commit, got \(outcome)")
            return
        }
        #expect(r.id == EntityID(1))
        guard case .line(let d) = r.kind else {
            Issue.record("expected a line kind, got \(r.kind)")
            return
        }
        // The start moves to the crossing (5,0); the end (10,0) is kept.
        #expect(d.start == Vector(5, 0))
        #expect(d.end == Vector(10, 0))
    }

    @Test("the trim preserves the target's id and only emits .replace (no add/remove)")
    func trimEmitsOnlyReplace() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        let outcome = tool.handle(.click(Vector(8, 0)), context: ctx)
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit")
            return
        }
        #expect(edits.count == 1)
        if case .replace = edits[0] {} else {
            Issue.record("trim must emit a .replace, got \(edits[0])")
        }
    }

    @Test("with multiple cutting lines the NEAREST crossing to the click bounds the trim")
    func trimNearestIntersection() {
        // Two vertical cutters: at x=3 and x=7. A click at (8,0) is nearest the
        // x=7 crossing → the line keeps (0,0)-(7,0).
        let cutterA = EntityRecord(id: EntityID(2),
                                   kind: .line(LineData(start: Vector(3, -5), end: Vector(3, 5))))
        let cutterB = EntityRecord(id: EntityID(3),
                                   kind: .line(LineData(start: Vector(7, -5), end: Vector(7, 5))))
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, cutterA, cutterB])

        let outcome = tool.handle(.click(Vector(8, 0)), context: ctx)
        guard let r = replacement(outcome), case .line(let d) = r.kind else {
            Issue.record("expected a single .replace with a line, got \(outcome)")
            return
        }
        #expect(d.start == Vector(0, 0))
        #expect(d.end == Vector(7, 0))   // bounded by the nearer (x=7) crossing
    }

    // MARK: - Arc trim

    @Test("an arc crossed by a line trims the click-side sweep")
    func trimArcByLine() {
        // Upper-half arc: center (0,0), r=5, CCW from angle 0 → π. A vertical line
        // at x=0 crosses it at the TOP (0,5) = angle π/2.
        let arc = EntityRecord(
            id: EntityID(10),
            flags: [.visible],
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi, reversed: false))
        )
        let cutter = EntityRecord(
            id: EntityID(11),
            kind: .line(LineData(start: Vector(0, -6), end: Vector(0, 6)))
        )
        var tool = TrimTool()
        let ctx = Self.context(over: [arc, cutter])

        // Click on the RIGHT half of the arc (~angle π/4): point on the arc at π/4.
        let clickPt = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))
        let outcome = tool.handle(.click(clickPt), context: ctx)
        guard let r = replacement(outcome), case .arc(let d) = r.kind else {
            Issue.record("expected a single .replace with an arc, got \(outcome)")
            return
        }
        #expect(r.id == EntityID(10))
        // Click on the start side (0→π/2) → the START moves to the crossing angle
        // π/2; the kept sweep is π/2 → π.
        #expect(abs(d.startAngle - .pi / 2) < 1e-6)
        #expect(abs(d.endAngle - .pi) < 1e-6)
        #expect(d.radius == 5)
        #expect(d.center == Vector(0, 0))
    }

    @Test("clicking the OTHER side of the arc trims the end sweep")
    func trimArcOtherSide() {
        let arc = EntityRecord(
            id: EntityID(10),
            flags: [.visible],
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: .pi, reversed: false))
        )
        let cutter = EntityRecord(
            id: EntityID(11),
            kind: .line(LineData(start: Vector(0, -6), end: Vector(0, 6)))
        )
        var tool = TrimTool()
        let ctx = Self.context(over: [arc, cutter])

        // Click on the LEFT half (~angle 3π/4): the END moves to π/2; keep 0 → π/2.
        let clickPt = Vector(5 * cos(3 * .pi / 4), 5 * sin(3 * .pi / 4))
        let outcome = tool.handle(.click(clickPt), context: ctx)
        guard let r = replacement(outcome), case .arc(let d) = r.kind else {
            Issue.record("expected a single .replace with an arc, got \(outcome)")
            return
        }
        #expect(abs(d.startAngle - 0) < 1e-6)
        #expect(abs(d.endAngle - .pi / 2) < 1e-6)
    }

    // MARK: - No-op cases

    @Test("clicking empty space (no target under the cursor) is a no-op")
    func noTargetNoop() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        // Far from any entity → nearbyEntities returns nothing.
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
    }

    @Test("a target with NO cutting intersection is a no-op (nothing bounds the trim)")
    func noIntersectionNoop() {
        // A lone horizontal line with no boundary crossing it anywhere.
        let lone = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        // A parallel line far above — never intersects the target.
        let parallel = EntityRecord(id: EntityID(2),
                                    kind: .line(LineData(start: Vector(0, 20), end: Vector(10, 20))))
        var tool = TrimTool()
        let ctx = Self.context(over: [lone, parallel])
        #expect(tool.handle(.click(Vector(8, 0)), context: ctx) == .none)
    }

    @Test("a single lone line (no boundaries at all) is a no-op")
    func loneLineNoop() {
        let lone = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        var tool = TrimTool()
        let ctx = Self.context(over: [lone])
        #expect(tool.handle(.click(Vector(8, 0)), context: ctx) == .none)
    }

    @Test("an unsupported-kind target (circle) under the click is skipped → no-op")
    func unsupportedKindSkipped() {
        // A circle crossed by a line: the circle is out of scope as a TRIM target
        // (scope is line/arc), so a click on it yields no trim.
        let circle = EntityRecord(id: EntityID(1), flags: [.visible],
                                  kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let cutter = EntityRecord(id: EntityID(2),
                                  kind: .line(LineData(start: Vector(0, -6), end: Vector(0, 6))))
        var tool = TrimTool()
        let ctx = Self.context(over: [circle, cutter])
        // Click on the circle's right side: no LINE/ARC target → no-op.
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)
    }

    // MARK: - Move preview / cancel / commit

    @Test("a move over a trimmable target produces a preview of the kept geometry")
    func movePreview() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        let outcome = tool.handle(.move(Vector(8, 0)), context: ctx)
        #expect(outcome == .preview)
        #expect(tool.preview.count == 1)
        // The preview shows the kept (0,0)-(5,0) line with the preview pen.
        let poly = tool.preview[0]
        #expect(poly.points.first == Vector(0, 0))
        #expect(poly.points.last == Vector(5, 0))
        #expect(poly.pen == .toolPreview)
    }

    @Test("a move over empty space yields no preview")
    func movePreviewEmpty() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        #expect(tool.handle(.move(Vector(50, 50)), context: ctx) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("cancel discards the preview and finishes")
    func cancelResets() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        _ = tool.handle(.move(Vector(8, 0)), context: ctx)
        #expect(!tool.preview.isEmpty)
        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
    }

    @Test("commit (Return) with nothing pending just finishes")
    func commitFinishes() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        #expect(tool.handle(.commit, context: ctx) == .finished)
    }

    @Test("backspace is a no-op for the single-click trim")
    func backspaceNoop() {
        var tool = TrimTool()
        let ctx = Self.context(over: [Self.hLine, Self.vLine])
        #expect(tool.handle(.backspace, context: ctx) == .none)
    }

    // MARK: - Tolerance from grid spacing

    @Test("the pick aperture scales with the grid spacing when present")
    func pickToleranceFromGrid() {
        // gridSpacing 4 → aperture 2.0; a click 1.5 above the line (within 2.0)
        // still resolves the line as the target.
        let ctx = Self.context(over: [Self.hLine, Self.vLine], gridSpacing: 4)
        var tool = TrimTool()
        let outcome = tool.handle(.click(Vector(8, 1.5)), context: ctx)
        guard let r = replacement(outcome), case .line(let d) = r.kind else {
            Issue.record("expected the line to be trimmed within the grid-derived aperture")
            return
        }
        #expect(d.start == Vector(0, 0))
        #expect(d.end == Vector(5, 0))
    }
}
