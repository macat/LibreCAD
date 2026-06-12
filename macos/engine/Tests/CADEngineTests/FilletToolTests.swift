//
//  FilletToolTests.swift
//  CADEngineTests
//
//  Drives the FILLET editing tool PURELY (no GUI): feeds `ToolInput` events + a
//  hand-built `ToolContext` whose boundary hook (`nearbyEntities`) scans a known
//  entity set, and asserts the FILLET contract — that picking two LINES rounds the
//  corner where they meet with a tangent arc of the configured radius, emitting one
//  undoable commit of two `.replace`s (the trimmed lines) + one `.add(.arc)`.
//
//  Covers: two perpendicular lines rounded with r=3 (exact center / tangent points
//  / trimmed lines / arc geometry / commit shape), the r=0 sharp corner (two
//  `.replace`s, NO arc), parallel lines (no-op), a non-line pick (no-op), the
//  state machine (status, cancel/backspace reset), and the radius default + config.
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

@Suite("FilletTool editing (pick two lines, round the corner)")
struct FilletToolTests {

    // MARK: - Context fixture

    /// Builds a `ToolContext` whose `nearbyEntities` hook scans `records` with the
    /// SAME exact-distance semantics the app's `makeToolContext` wires up: visible
    /// records within tolerance by `HitTesting.worldDistance`. (Mirrors the
    /// TrimTool / ToolContext fixtures.)
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

    /// Decomposes a `.commit` into its replaces (id, line) and the added arc, or
    /// `nil` when the outcome is not a commit. Asserts each `.replace` carries a
    /// line and the single `.add` (if any) carries an arc.
    private struct Commit {
        var replaces: [(id: EntityID, line: LineData)] = []
        var addedArc: ArcData?
        var addedRecord: EntityRecord?
        var editCount = 0
    }

    private func decompose(_ outcome: ToolOutcome) -> Commit? {
        guard case .commit(let edits) = outcome else { return nil }
        var c = Commit()
        c.editCount = edits.count
        for e in edits {
            switch e {
            case .replace(let id, let kind):
                guard case .line(let d) = kind else {
                    Issue.record("fillet .replace must carry a line, got \(kind)")
                    return nil
                }
                c.replaces.append((id, d))
            case .add(let rec):
                c.addedRecord = rec
                guard case .arc(let a) = rec.kind else {
                    Issue.record("fillet .add must carry an arc, got \(rec.kind)")
                    return nil
                }
                c.addedArc = a
            case .remove:
                Issue.record("fillet must not emit a .remove")
                return nil
            }
        }
        return c
    }

    // MARK: - Fixtures: perpendicular lines meeting at (10,0)

    /// L1 (0,0)→(10,0). FIRST picked line.
    private static func l1(_ id: Int = 1) -> EntityRecord {
        EntityRecord(
            id: EntityID(UInt64(id)),
            layer: LayerID("walls"),
            pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
            flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
    }

    /// L2 (10,0)→(10,10). SECOND picked line. Meets L1 at the corner (10,0).
    private static func l2(_ id: Int = 2) -> EntityRecord {
        EntityRecord(
            id: EntityID(UInt64(id)),
            flags: [.visible],
            kind: .line(LineData(start: Vector(10, 0), end: Vector(10, 10)))
        )
    }

    private let eps = 1e-9

    // MARK: - The canonical perpendicular fillet (r = 3)

    @Test("two perpendicular lines, r=3 → arc center (7,3), tangents (7,0)/(10,3), lines trimmed")
    func filletPerpendicularRadius3() {
        var tool = FilletTool()
        tool.radius = 3
        let ctx = Self.context(over: [Self.l1(), Self.l2()])

        // Pick each line near its FAR end from the corner (10,0): L1 near (0,0),
        // L2 near (10,10).
        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)   // first line
        let outcome = tool.handle(.click(Vector(10, 8)), context: ctx)       // second line → fillet

        guard let c = decompose(outcome) else {
            Issue.record("expected a .commit, got \(outcome)")
            return
        }

        // Commit shape: exactly 2 .replace + 1 .add(.arc).
        #expect(c.editCount == 3)
        #expect(c.replaces.count == 2)
        guard let arc = c.addedArc else {
            Issue.record("expected an added arc")
            return
        }

        // Arc: radius 3, center (7,3).
        #expect(abs(arc.radius - 3) < eps)
        #expect(abs(arc.center.x - 7) < eps)
        #expect(abs(arc.center.y - 3) < eps)

        // Tangent points (7,0) and (10,3) — the arc's endpoints about the center.
        let p0 = arc.center + Vector.polar(radius: arc.radius, angle: arc.startAngle)
        let p1 = arc.center + Vector.polar(radius: arc.radius, angle: arc.endAngle)
        let endpoints = [p0, p1]
        #expect(endpoints.contains { abs($0.x - 7) < 1e-7 && abs($0.y - 0) < 1e-7 })
        #expect(endpoints.contains { abs($0.x - 10) < 1e-7 && abs($0.y - 3) < 1e-7 })

        // The arc rounds the corner (the SHORT 90° way), not the reflex 270°.
        let sweep = MathUtils.getAngleDifference(arc.startAngle, arc.endAngle, reversed: arc.reversed)
        #expect(abs(sweep - .pi / 2) < 1e-7)

        // The arc's midpoint bulges toward the corner (≈ (9.12, 0.88)).
        let mid = Tessellation.arcPoints(center: arc.center, radius: arc.radius,
                                         startAngle: arc.startAngle, endAngle: arc.endAngle,
                                         reversed: arc.reversed, tolerance: 0.001)
        let m = mid[mid.count / 2]
        #expect(m.x > 7 && m.y < 3)   // toward the corner (10,0), away from center (7,3)

        // L1 trimmed to (0,0)-(7,0).
        let r1 = c.replaces.first { $0.id == EntityID(1) }
        #expect(r1?.line.start == Vector(0, 0))
        #expect(r1?.line.end == Vector(7, 0))

        // L2 trimmed to (10,3)-(10,10).
        let r2 = c.replaces.first { $0.id == EntityID(2) }
        #expect(r2?.line.start == Vector(10, 3))
        #expect(r2?.line.end == Vector(10, 10))

        // The added arc inherits the FIRST line's layer/pen/flags.
        #expect(c.addedRecord?.layer == LayerID("walls"))
        #expect(c.addedRecord?.id == .placeholder)

        // After commit the tool resets to picking the first line.
        #expect(tool.status == "Specify first line")
    }

    // MARK: - r = 0 (sharp corner, no arc)

    @Test("radius 0 trims both lines to the corner with NO arc (two .replace, no .add)")
    func filletRadiusZero() {
        var tool = FilletTool()
        tool.radius = 0
        let ctx = Self.context(over: [Self.l1(), Self.l2()])

        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(10, 8)), context: ctx)

        guard let c = decompose(outcome) else {
            Issue.record("expected a .commit, got \(outcome)")
            return
        }
        #expect(c.editCount == 2)
        #expect(c.replaces.count == 2)
        #expect(c.addedArc == nil)

        // Both lines trimmed to the corner (10,0).
        let r1 = c.replaces.first { $0.id == EntityID(1) }
        #expect(r1?.line.start == Vector(0, 0))
        #expect(r1?.line.end == Vector(10, 0))
        let r2 = c.replaces.first { $0.id == EntityID(2) }
        #expect(r2?.line.start == Vector(10, 0))
        #expect(r2?.line.end == Vector(10, 10))
    }

    // MARK: - Degenerate / no-op cases

    @Test("parallel lines have no corner → second pick is a no-op")
    func parallelLinesNoop() {
        // Two horizontal parallels, never intersecting.
        let a = EntityRecord(id: EntityID(1), flags: [.visible],
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let b = EntityRecord(id: EntityID(2), flags: [.visible],
                             kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))))
        var tool = FilletTool()
        tool.radius = 3
        let ctx = Self.context(over: [a, b])

        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)   // first line
        #expect(tool.handle(.click(Vector(2, 5)), context: ctx) == .none)   // parallel → no-op
    }

    @Test("a non-line pick (circle) is a no-op for the first pick")
    func nonLineFirstPickNoop() {
        // A circle whose edge point (0,5) is well away from any line.
        let circle = EntityRecord(id: EntityID(1), flags: [.visible],
                                  kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let line = EntityRecord(id: EntityID(2), flags: [.visible],
                                kind: .line(LineData(start: Vector(20, 0), end: Vector(30, 0))))
        var tool = FilletTool()
        let ctx = Self.context(over: [circle, line])
        // Click on the circle's top edge (0,5): only the circle is under it (scope
        // is line–line, so the circle is skipped) → no-op, still picking first.
        #expect(tool.handle(.click(Vector(0, 5)), context: ctx) == .none)
        #expect(tool.status == "Specify first line")
    }

    @Test("a non-line second pick is a no-op (no second line chosen)")
    func nonLineSecondPickNoop() {
        let line = EntityRecord(id: EntityID(1), flags: [.visible],
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let circle = EntityRecord(id: EntityID(2), flags: [.visible],
                                  kind: .circle(CircleData(center: Vector(20, 0), radius: 3)))
        var tool = FilletTool()
        let ctx = Self.context(over: [line, circle])
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)   // first line OK
        #expect(tool.status == "Specify second line")
        // Second pick lands on the circle (not a line) → no-op.
        #expect(tool.handle(.click(Vector(23, 0)), context: ctx) == .none)
    }

    @Test("clicking empty space for the first line is a no-op")
    func emptyFirstPickNoop() {
        var tool = FilletTool()
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        #expect(tool.handle(.click(Vector(50, 50)), context: ctx) == .none)
        #expect(tool.status == "Specify first line")
    }

    @Test("a radius too large to fit on the finite lines is a no-op")
    func radiusTooLargeNoop() {
        // L1 and L2 are only 10 long; a fillet radius of 50 would need tangent
        // points ~50 from the corner — off both finite lines → no-op.
        var tool = FilletTool()
        tool.radius = 50
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(tool.handle(.click(Vector(10, 8)), context: ctx) == .none)
    }

    // MARK: - State machine: preview / cancel / backspace / commit

    @Test("a move over a candidate second line previews the arc + two trimmed lines")
    func movePreview() {
        var tool = FilletTool()
        tool.radius = 3
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)   // fix first line
        let outcome = tool.handle(.move(Vector(10, 8)), context: ctx)
        #expect(outcome == .preview)
        // Two trimmed lines + the arc → at least 3 preview polylines, all the
        // preview pen.
        #expect(tool.preview.count >= 3)
        #expect(tool.preview.allSatisfy { $0.pen == .toolPreview })
    }

    @Test("a move over empty space (no second line) yields no preview")
    func movePreviewEmpty() {
        var tool = FilletTool()
        tool.radius = 3
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(tool.handle(.move(Vector(50, 50)), context: ctx) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("no preview before the first line is picked")
    func noPreviewBeforeFirst() {
        var tool = FilletTool()
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        #expect(tool.handle(.move(Vector(10, 8)), context: ctx) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("cancel discards the run and finishes (back to picking first)")
    func cancelResets() {
        var tool = FilletTool()
        tool.radius = 3
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        _ = tool.handle(.move(Vector(10, 8)), context: ctx)
        #expect(!tool.preview.isEmpty)
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify first line")
    }

    @Test("backspace from picking-second steps back to picking-first")
    func backspaceSteppsBack() {
        var tool = FilletTool()
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(tool.status == "Specify second line")
        _ = tool.handle(.backspace, context: ctx)
        #expect(tool.status == "Specify first line")
        // Backspace at the start is a no-op.
        #expect(tool.handle(.backspace, context: ctx) == .none)
    }

    @Test("commit (Return) with nothing pending just finishes")
    func commitFinishes() {
        var tool = FilletTool()
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        #expect(tool.handle(.commit, context: ctx) == .finished)
    }

    // MARK: - Radius config

    @Test("the default radius is 10")
    func defaultRadius() {
        let tool = FilletTool()
        #expect(tool.radius == 10)
    }

    @Test("a negative radius is clamped to a sharp corner (no arc)")
    func negativeRadiusClampedToSharp() {
        var tool = FilletTool()
        tool.radius = -5
        let ctx = Self.context(over: [Self.l1(), Self.l2()])
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(10, 8)), context: ctx)
        guard let c = decompose(outcome) else {
            Issue.record("expected a .commit, got \(outcome)")
            return
        }
        // Clamped to 0 → sharp corner, two replaces, no arc.
        #expect(c.editCount == 2)
        #expect(c.addedArc == nil)
    }

    @Test("the title is Fillet")
    func title() {
        #expect(FilletTool().title == "Fillet")
    }
}
