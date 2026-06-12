//
//  DimensionToolTests.swift
//  CADEngineTests
//
//  Drives the four interactive dimension creation tools — LinearDimTool,
//  AlignedDimTool, RadialDimTool, AngularDimTool — PURELY (no GUI): feeds
//  `ToolInput` clicks/moves + a read-only `ToolContext` and asserts the committed
//  `.dimension` carries the right `DimKind` + defining points + `definitionPoint`,
//  the live preview, the status prompts, and cancel/backspace resets.
//
//  Domain-prefixed suite names (CONVENTIONS.md namespacing) so the parallel tool
//  fan-out adding test files to the SAME target doesn't collide.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Shared decode helpers

private enum DimToolTestSupport {

    /// Pulls the single `DimData` out of a one-edit `.add(.dimension)` commit, or
    /// `nil` if the outcome is not exactly that.
    static func committedDim(_ outcome: ToolOutcome) -> DimData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              record.id == .placeholder,
              case .dimension(let d) = record.kind else { return nil }
        return d
    }

    /// A `ToolContext` whose `nearbyEntities` scans `records` with the SAME
    /// exact-distance semantics the app wires up (visible records within tolerance
    /// by `HitTesting.worldDistance`). Mirrors the FilletTool / ToolContext
    /// fixtures.
    static func context(over records: [EntityRecord], gridSpacing: Double? = nil) -> ToolContext {
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
}

// MARK: - LinearDimTool

@Suite("DimTool Linear")
struct DimToolLinearTests {

    @Test("title + status transitions through the three clicks")
    func statusTransitions() {
        var tool = LinearDimTool()
        #expect(tool.title == "Linear Dimension")
        #expect(tool.status == "Specify first extension line origin")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second extension line origin")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify dimension line location")
    }

    @Test("horizontal linear: (0,0)-(10,0), dim line at y=5 commits .linear with angle 0")
    func horizontalCommit() {
        var tool = LinearDimTool()  // default .horizontal
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(5, 5)), context: .empty)
        let dim = DimToolTestSupport.committedDim(outcome)
        #expect(dim != nil)
        guard case .linear(let e1, let e2, let angle)? = dim?.kind else {
            Issue.record("expected .linear, got \(String(describing: dim?.kind))")
            return
        }
        #expect(e1 == Vector(0, 0))
        #expect(e2 == Vector(10, 0))
        #expect(angle == 0)
        #expect(dim?.definitionPoint == Vector(5, 5))
        // The measured horizontal distance is 10.
        let measured = EntityKind.dimMeasuredValue(dim!).value
        #expect(abs(measured - 10) < 1e-9)
    }

    @Test("vertical orientation locks the measurement angle to π/2 and measures the y span")
    func verticalCommit() {
        var tool = LinearDimTool(orientation: .vertical)
        #expect(tool.title == "Vertical Dimension")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 7)), context: .empty)
        let outcome = tool.handle(.click(Vector(-3, 3.5)), context: .empty)
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .linear(_, _, let angle)? = dim?.kind else {
            Issue.record("expected .linear")
            return
        }
        #expect(abs(angle - Double.pi / 2) < 1e-12)
        // Vertical measures the y component (7), not the diagonal.
        let measured = EntityKind.dimMeasuredValue(dim!).value
        #expect(abs(measured - 7) < 1e-9)
    }

    @Test("free orientation measures along the line through the two origins")
    func freeCommit() {
        var tool = LinearDimTool(orientation: .free)
        #expect(tool.title == "Rotated Dimension")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(3, 4)), context: .empty)
        let outcome = tool.handle(.click(Vector(0, 5)), context: .empty)
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .linear(_, _, let angle)? = dim?.kind else {
            Issue.record("expected .linear")
            return
        }
        #expect(abs(angle - atan2(4, 3)) < 1e-12)
        // Free measures the full 3-4-5 distance.
        let measured = EntityKind.dimMeasuredValue(dim!).value
        #expect(abs(measured - 5) < 1e-9)
    }

    @Test("preview is empty before the dim-line state, then tracks the cursor")
    func preview() {
        var tool = LinearDimTool()
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // Still in the first/second pick — no dim line to preview yet.
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        // Entering the dim-line state seeds the cursor at the last click, so the
        // preview is already live; a move keeps it live and returns .preview.
        #expect(!tool.preview.isEmpty)
        let out = tool.handle(.move(Vector(5, 4)), context: .empty)
        #expect(out == .preview)
        #expect(!tool.preview.isEmpty)
    }

    @Test("coincident second origin is ignored (stays awaiting the second origin)")
    func coincidentSecondIgnored() {
        var tool = LinearDimTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify second extension line origin")
    }

    @Test("cancel resets and finishes; backspace steps back one pick")
    func cancelAndBackspace() {
        var tool = LinearDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.handle(.backspace, context: .empty) == .preview)
        #expect(tool.status == "Specify second extension line origin")
        #expect(tool.handle(.cancel, context: .empty) == .finished)
        #expect(tool.status == "Specify first extension line origin")
    }

    @Test("commit while idle just finishes (each dim already committed on the third click)")
    func commitIdleFinishes() {
        var tool = LinearDimTool()
        #expect(tool.handle(.commit, context: .empty) == .finished)
    }
}

// MARK: - AlignedDimTool

@Suite("DimTool Aligned")
struct DimToolAlignedTests {

    @Test("aligned: (0,0)-(3,4) offset at (4,0) commits .aligned measuring 5")
    func alignedCommit() {
        var tool = AlignedDimTool()
        #expect(tool.title == "Aligned Dimension")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(3, 4)), context: .empty)
        let outcome = tool.handle(.click(Vector(4, 0)), context: .empty)
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .aligned(let e1, let e2)? = dim?.kind else {
            Issue.record("expected .aligned, got \(String(describing: dim?.kind))")
            return
        }
        #expect(e1 == Vector(0, 0))
        #expect(e2 == Vector(3, 4))
        #expect(dim?.definitionPoint == Vector(4, 0))
        // Aligned measures the true (diagonal) distance: 5.
        let measured = EntityKind.dimMeasuredValue(dim!).value
        #expect(abs(measured - 5) < 1e-9)
    }

    @Test("status transitions + preview appears in the offset state")
    func statusAndPreview() {
        var tool = AlignedDimTool()
        #expect(tool.status == "Specify first extension line origin")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second extension line origin")
        _ = tool.handle(.click(Vector(3, 4)), context: .empty)
        #expect(tool.status == "Specify dimension line location")
        _ = tool.handle(.move(Vector(4, 0)), context: .empty)
        #expect(!tool.preview.isEmpty)
    }

    @Test("backspace from the offset state returns to the second-origin pick")
    func backspace() {
        var tool = AlignedDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(3, 4)), context: .empty)
        #expect(tool.handle(.backspace, context: .empty) == .preview)
        #expect(tool.status == "Specify second extension line origin")
    }
}

// MARK: - RadialDimTool

@Suite("DimTool Radial")
struct DimToolRadialTests {

    /// A unit-radius... actually a radius-5 circle centered at the origin.
    private static func circle(_ id: Int = 1, center: Vector = Vector(0, 0), radius: Double = 5) -> EntityRecord {
        EntityRecord(id: EntityID(UInt64(id)), flags: [.visible],
                     kind: .circle(CircleData(center: center, radius: radius)))
    }

    @Test("radius mode: pick circle then leader to the right commits .radial R=radius")
    func radialCommit() {
        let ctx = DimToolTestSupport.context(over: [Self.circle()])
        var tool = RadialDimTool()   // default .radius
        #expect(tool.title == "Radius Dimension")
        #expect(tool.status == "Select arc or circle")
        // Click ON the circle (point (5,0) is on a radius-5 circle at origin).
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)
        #expect(tool.status == "Specify dimension line location")
        // Leader dragged out to the right at (8,0).
        let outcome = tool.handle(.click(Vector(8, 0)), context: ctx)
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .radial(let center, let pointOnCircle)? = dim?.kind else {
            Issue.record("expected .radial, got \(String(describing: dim?.kind))")
            return
        }
        #expect(center == Vector(0, 0))
        // Point on circle is along the leader direction (+x) at radius 5.
        #expect(abs(pointOnCircle.x - 5) < 1e-9)
        #expect(abs(pointOnCircle.y - 0) < 1e-9)
        #expect(dim?.definitionPoint == Vector(8, 0))
        let (value, suffix) = EntityKind.dimMeasuredValue(dim!)
        #expect(abs(value - 5) < 1e-9)
        #expect(suffix == "R")
    }

    @Test("diameter mode: commits .diameter with opposite points, value 2·radius, ⌀ suffix")
    func diameterCommit() {
        let ctx = DimToolTestSupport.context(over: [Self.circle()])
        var tool = RadialDimTool(mode: .diameter)
        #expect(tool.title == "Diameter Dimension")
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(0, 7)), context: ctx)  // leader upward
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .diameter(let p1, let p2)? = dim?.kind else {
            Issue.record("expected .diameter, got \(String(describing: dim?.kind))")
            return
        }
        // Opposite points along the leader direction (+y here): (0,-5) and (0,5).
        #expect(abs((p2 - p1).magnitude - 10) < 1e-9)
        let (value, suffix) = EntityKind.dimMeasuredValue(dim!)
        #expect(abs(value - 10) < 1e-9)
        #expect(suffix == "\u{2300}")
    }

    @Test("picking an ARC works too (uses its center + radius)")
    func arcPick() {
        let arc = EntityRecord(id: EntityID(9), flags: [.visible],
            kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                               startAngle: 0, endAngle: Double.pi / 2, reversed: false)))
        let ctx = DimToolTestSupport.context(over: [arc])
        var tool = RadialDimTool()
        // (5,0) lies on the arc (startAngle 0).
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(8, 0)), context: ctx)
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .radial(let center, _)? = dim?.kind else {
            Issue.record("expected .radial from arc pick")
            return
        }
        #expect(center == Vector(0, 0))
    }

    @Test("a miss on the first click selects nothing (stays awaiting the entity)")
    func firstClickMissIgnored() {
        let ctx = DimToolTestSupport.context(over: [Self.circle()])
        var tool = RadialDimTool()
        // Far from the circle.
        _ = tool.handle(.click(Vector(100, 100)), context: ctx)
        #expect(tool.status == "Select arc or circle")
    }

    @Test("backspace from the leader state returns to entity selection")
    func backspace() {
        let ctx = DimToolTestSupport.context(over: [Self.circle()])
        var tool = RadialDimTool()
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)
        #expect(tool.handle(.backspace, context: ctx) == .preview)
        #expect(tool.status == "Select arc or circle")
    }
}

// MARK: - AngularDimTool

@Suite("DimTool Angular")
struct DimToolAngularTests {

    /// Drives the 4-point path: ray1 (0,0)->(10,0), ray2 (0,0)->(0,10), then the
    /// arc-location click `arcAt`. Returns the committed DimData.
    private func commitFourPoint(arcAt: Vector, context: ToolContext = .empty) -> DimData? {
        var tool = AngularDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: context)   // ray1 start
        _ = tool.handle(.click(Vector(10, 0)), context: context)  // ray1 end
        _ = tool.handle(.click(Vector(0, 0)), context: context)   // ray2 start
        _ = tool.handle(.click(Vector(0, 10)), context: context)  // ray2 end
        let outcome = tool.handle(.click(arcAt), context: context) // arc location
        return DimToolTestSupport.committedDim(outcome)
    }

    @Test("title + status transitions through the 4-point + arc sequence")
    func statusTransitions() {
        var tool = AngularDimTool()
        #expect(tool.title == "Angular Dimension")
        #expect(tool.status == "Select first line or specify first point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second point of first line")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Select second line or specify first point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second point of second line")
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        #expect(tool.status == "Specify dimension arc location")
    }

    @Test("4 points commit .angular with the exact two segments")
    func fourPointCommitsSegments() {
        let dim = commitFourPoint(arcAt: Vector(5, 5))
        guard case .angular(let l1s, let l1e, let l2s, let l2e)? = dim?.kind else {
            Issue.record("expected .angular, got \(String(describing: dim?.kind))")
            return
        }
        #expect(l1s == Vector(0, 0))
        #expect(l1e == Vector(10, 0))
        #expect(l2s == Vector(0, 0))
        #expect(l2e == Vector(0, 10))
        #expect(dim?.definitionPoint == Vector(5, 5))
    }

    @Test("arc location INSIDE the 90° quadrant selects the 90° sector")
    func sectorInside() {
        // (5,5) is at 45°, between ray1 (0°) and ray2 (90°): the small sector.
        let dim = commitFourPoint(arcAt: Vector(5, 5))
        let value = EntityKind.dimMeasuredValue(dim!).value
        #expect(abs(value - 90) < 1e-6)
    }

    @Test("arc location OUTSIDE the 90° quadrant selects the complementary 270° sector")
    func sectorOutside() {
        // (5,-5) is at -45° (315°), OUTSIDE the 0°..90° CCW sector → the resolve
        // spans the complementary 270° arc. This proves the arc-location click
        // selects the sector via the definition point.
        let dim = commitFourPoint(arcAt: Vector(5, -5))
        let value = EntityKind.dimMeasuredValue(dim!).value
        #expect(abs(value - 270) < 1e-6)
    }

    @Test("opposite-side arc location flips the measured sector relative to the inside pick")
    func sectorFlips() {
        let inside = commitFourPoint(arcAt: Vector(5, 5))
        let outside = commitFourPoint(arcAt: Vector(5, -5))
        let vInside = EntityKind.dimMeasuredValue(inside!).value
        let vOutside = EntityKind.dimMeasuredValue(outside!).value
        // The two picks select different sectors that sum to a full turn (360°).
        #expect(abs((vInside + vOutside) - 360) < 1e-6)
    }

    @Test("line-pick path: clicking two LINE entities consumes each as one ray")
    func linePickPath() {
        let l1 = EntityRecord(id: EntityID(1), flags: [.visible],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let l2 = EntityRecord(id: EntityID(2), flags: [.visible],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(0, 10))))
        let ctx = DimToolTestSupport.context(over: [l1, l2])
        var tool = AngularDimTool()
        // Click on line1 (midpoint (5,0)) — consumed as ray1 in ONE click.
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)
        #expect(tool.status == "Select second line or specify first point")
        // Click on line2 (midpoint (0,5)) — consumed as ray2 in ONE click.
        _ = tool.handle(.click(Vector(0, 5)), context: ctx)
        #expect(tool.status == "Specify dimension arc location")
        let outcome = tool.handle(.click(Vector(3, 3)), context: ctx)
        let dim = DimToolTestSupport.committedDim(outcome)
        guard case .angular(let l1s, let l1e, let l2s, let l2e)? = dim?.kind else {
            Issue.record("expected .angular from line picks")
            return
        }
        #expect(l1s == Vector(0, 0))
        #expect(l1e == Vector(10, 0))
        #expect(l2s == Vector(0, 0))
        #expect(l2e == Vector(0, 10))
        // 45° pick → the 90° sector.
        #expect(abs(EntityKind.dimMeasuredValue(dim!).value - 90) < 1e-6)
    }

    @Test("preview appears once both rays are fixed and tracks the cursor")
    func preview() {
        var tool = AngularDimTool()
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // Only one ray fixed so far — nothing to preview.
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        // Entering the arc state seeds the cursor at the last click → live preview.
        #expect(!tool.preview.isEmpty)
        let out = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(out == .preview)
        #expect(!tool.preview.isEmpty)
    }

    @Test("cancel resets the angular tool to its initial state")
    func cancel() {
        var tool = AngularDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.handle(.cancel, context: .empty) == .finished)
        #expect(tool.status == "Select first line or specify first point")
    }

    @Test("backspace from the arc state steps back to re-pick ray2's end")
    func backspace() {
        var tool = AngularDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        #expect(tool.status == "Specify dimension arc location")
        #expect(tool.handle(.backspace, context: .empty) == .preview)
        #expect(tool.status == "Specify second point of second line")
    }
}
