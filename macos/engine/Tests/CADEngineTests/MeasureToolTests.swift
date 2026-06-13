//
//  MeasureToolTests.swift
//  CADEngineTests
//
//  Drives the read-only `MeasureTool` variants PURELY (no GUI): feeds `ToolInput`
//  events + a read-only `ToolContext`, and asserts the computed value reported in
//  the tool's `status` string (the only result channel a measure tool has) plus
//  the contract that a measure tool NEVER mutates the drawing (every outcome is
//  `.none` / `.finished`; never `.commit`).
//
//  Engine-testable known values (from the brief):
//    - distance of (0,0)→(3,4) == 5
//    - a right angle (vertex at origin, rays along +x and +y) == 90°
//    - a unit square → area 1, perimeter 4
//    - total length sums the selected entities' lengths
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("MeasureTool read-only info tools")
struct MeasureToolTests {

    // MARK: - Helpers

    /// Asserts an outcome carries NO edits — a measure tool must never commit.
    private func assertNoMutation(_ outcome: ToolOutcome, _ comment: Comment = "") {
        if case .commit = outcome {
            Issue.record("measure tool emitted a .commit (must be read-only): \(comment)")
        }
    }

    /// A `ToolContext` whose selection is `records`.
    private func context(selecting records: [EntityRecord]) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    // MARK: - Mode → title / initial status

    @Test("each mode has its own title and initial prompt")
    func titlesAndInitialStatus() {
        #expect(MeasureTool(mode: .distance).title == "Measure Distance")
        #expect(MeasureTool(mode: .angle).title == "Measure Angle")
        #expect(MeasureTool(mode: .areaPerimeter).title == "Measure Area")
        #expect(MeasureTool(mode: .totalLength).title == "Total Length")

        #expect(MeasureTool(mode: .distance).status == "Specify first point")
        #expect(MeasureTool(mode: .angle).status == "Specify the vertex")
        #expect(MeasureTool(mode: .areaPerimeter).status.contains("0 picked"))
    }

    // MARK: - Distance

    @Test("distance of (0,0)→(3,4) reads 5 and reports Δx/Δy/Angle")
    func distanceThreeFourFive() {
        var tool = MeasureTool(mode: .distance)
        let o1 = tool.handle(.click(Vector(0, 0)), context: .empty)
        assertNoMutation(o1, "first distance pick")
        #expect(tool.status == "Specify second point")

        let o2 = tool.handle(.click(Vector(3, 4)), context: .empty)
        assertNoMutation(o2, "second distance pick")
        let s = tool.status
        #expect(s.contains("Distance: 5"))
        #expect(s.contains("Δx 3"))
        #expect(s.contains("Δy 4"))
        // atan2(4,3) ≈ 53.13°
        #expect(s.contains("Angle 53.1"))
    }

    @Test("distance preview is the segment from first pick to the cursor")
    func distancePreview() {
        var tool = MeasureTool(mode: .distance)
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.move(Vector(10, 0)), context: .empty)
        #expect(out == .preview)
        #expect(tool.preview.count == 1)
        #expect(tool.preview[0].points == [Vector(0, 0), Vector(10, 0)])
        #expect(tool.preview[0].closed == false)
    }

    @Test("a typed coordinate (.value) lands a distance pick like a click")
    func distanceTypedValue() {
        var tool = MeasureTool(mode: .distance)
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(6, 8)), context: .empty)
        #expect(tool.status.contains("Distance: 10"))
    }

    @Test("backspace steps a distance measurement back to the first pick")
    func distanceBackspace() {
        var tool = MeasureTool(mode: .distance)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(3, 4)), context: .empty)
        #expect(tool.status.contains("Distance: 5"))
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify first point")
    }

    // MARK: - Angle

    @Test("right angle: vertex at origin, rays +x and +y reads 90°")
    func rightAngle() {
        var tool = MeasureTool(mode: .angle)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // vertex
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)  // +x ray
        #expect(tool.status == "Specify second point")
        let out = tool.handle(.click(Vector(0, 10)), context: .empty) // +y ray
        assertNoMutation(out, "angle 3rd pick")
        #expect(tool.status == "Angle: 90°")
    }

    @Test("a straight (180°) angle and an acute angle compute correctly")
    func straightAndAcuteAngles() {
        var straight = MeasureTool(mode: .angle)
        _ = straight.handle(.click(Vector(0, 0)), context: .empty)
        _ = straight.handle(.click(Vector(10, 0)), context: .empty)
        _ = straight.handle(.click(Vector(-10, 0)), context: .empty)
        #expect(straight.status == "Angle: 180°")

        var acute = MeasureTool(mode: .angle)
        _ = acute.handle(.click(Vector(0, 0)), context: .empty)
        _ = acute.handle(.click(Vector(10, 0)), context: .empty)
        _ = acute.handle(.click(Vector(10, 10)), context: .empty) // 45°
        #expect(acute.status == "Angle: 45°")
    }

    @Test("a ray coincident with the vertex is ignored (no direction)")
    func angleIgnoresDegeneratePick() {
        var tool = MeasureTool(mode: .angle)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)  // coincident → ignored
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify second point")
    }

    // MARK: - Area / perimeter

    @Test("unit square → area 1, perimeter 4 (closed via Return)")
    func unitSquareReturnCloses() {
        var tool = MeasureTool(mode: .areaPerimeter)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        _ = tool.handle(.click(Vector(0, 1)), context: .empty)
        let out = tool.handle(.commit, context: .empty)  // Return closes
        assertNoMutation(out, "area close")
        #expect(tool.status == "Area: 1   Perimeter: 4")
    }

    @Test("unit square → area 1 when closed by clicking the first point")
    func unitSquareClickCloses() {
        var tool = MeasureTool(mode: .areaPerimeter)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        _ = tool.handle(.click(Vector(0, 1)), context: .empty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)  // back to first → closes
        #expect(tool.status == "Area: 1   Perimeter: 4")
    }

    @Test("Return before 3 points does not close (keeps picking)")
    func areaNeedsThreePoints() {
        var tool = MeasureTool(mode: .areaPerimeter)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        #expect(out == .none)
        #expect(tool.status.contains("2 picked"))
    }

    @Test("a 3-4-5 right triangle → area 6, perimeter 12")
    func rightTriangleArea() {
        var tool = MeasureTool(mode: .areaPerimeter)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 3)), context: .empty)
        _ = tool.handle(.commit, context: .empty)
        // area = 1/2 * 4 * 3 = 6 ; perimeter = 4 + 5 + 3 = 12
        #expect(tool.status == "Area: 6   Perimeter: 12")
    }

    @Test("backspace removes the last area boundary point")
    func areaBackspace() {
        var tool = MeasureTool(mode: .areaPerimeter)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        #expect(tool.status.contains("3 picked"))
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status.contains("2 picked"))
    }

    // MARK: - Total length

    @Test("total length sums the selected entities' lengths")
    func totalLengthSumsSelection() {
        // A line of length 5 + a unit-square closed polyline (perimeter 4) = 9.
        let line = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(3, 4))))
        let square = EntityRecord(id: EntityID(2),
                                  kind: .polyline(PolylineData(vertices: [
                                    PolylineVertex(point: Vector(0, 0)),
                                    PolylineVertex(point: Vector(1, 0)),
                                    PolylineVertex(point: Vector(1, 1)),
                                    PolylineVertex(point: Vector(0, 1)),
                                  ], closed: true)))
        var tool = MeasureTool(mode: .totalLength)
        let out = tool.handle(.commit, context: context(selecting: [line, square]))
        assertNoMutation(out, "total length read")
        #expect(tool.status == "Total length (2 entities): 9")
    }

    @Test("total length of a single line uses the singular noun")
    func totalLengthSingular() {
        let line = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        var tool = MeasureTool(mode: .totalLength)
        _ = tool.handle(.commit, context: context(selecting: [line]))
        #expect(tool.status == "Total length (1 entity): 10")
    }

    @Test("total length of an empty selection is zero")
    func totalLengthEmpty() {
        var tool = MeasureTool(mode: .totalLength)
        _ = tool.handle(.commit, context: .empty)
        #expect(tool.status == "Total length (0 entities): 0")
    }

    // MARK: - entityLength: analytic cases

    @Test("entityLength: line / circle / arc / point")
    func entityLengthAnalytic() {
        let line = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(3, 4))))
        #expect(MeasureTool.entityLength(line) == 5)

        let circle = EntityRecord(id: EntityID(2),
                                  kind: .circle(CircleData(center: Vector(0, 0), radius: 2)))
        #expect(abs(MeasureTool.entityLength(circle) - (4 * Double.pi)) < 1e-9)

        // Quarter arc, radius 2, CCW from 0 → π/2 ⇒ length = 2 * (π/2) = π.
        let arc = EntityRecord(id: EntityID(3),
                               kind: .arc(ArcData(center: Vector(0, 0), radius: 2,
                                                  startAngle: 0, endAngle: .pi / 2, reversed: false)))
        #expect(abs(MeasureTool.entityLength(arc) - Double.pi) < 1e-9)

        let point = EntityRecord(id: EntityID(4), kind: .point(PointData(position: Vector(1, 1))))
        #expect(MeasureTool.entityLength(point) == 0)
    }

    @Test("arc sweep honors reversed (clockwise) and full-circle start==end")
    func arcSweepReversedAndFull() {
        // CW quarter from 0 → 3π/2 reversed is a quarter sweep (π/2), length r * π/2.
        let cw = ArcData(center: Vector(0, 0), radius: 4, startAngle: 0, endAngle: 3 * .pi / 2, reversed: true)
        #expect(abs(MeasureTool.arcSweep(cw) - (Double.pi / 2)) < 1e-9)
        // start == end ⇒ a full sweep (2π).
        let full = ArcData(center: Vector(0, 0), radius: 1, startAngle: 1, endAngle: 1, reversed: false)
        #expect(abs(MeasureTool.arcSweep(full) - (2 * Double.pi)) < 1e-9)
    }

    // MARK: - Read-only contract (never commits)

    @Test("cancel ends the tool without mutating")
    func cancelFinishesNoMutation() {
        var tool = MeasureTool(mode: .distance)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.cancel, context: .empty)
        #expect(out == .finished)
        // Reset to the initial prompt.
        #expect(tool.status == "Specify first point")
    }

    @Test("no input path ever returns a .commit outcome")
    func neverCommits() {
        for mode in MeasureTool.Mode.allCases {
            var tool = MeasureTool(mode: mode)
            let inputs: [ToolInput] = [
                .move(Vector(1, 1)), .click(Vector(0, 0)), .value(Vector(2, 2)),
                .click(Vector(3, 3)), .click(Vector(4, 0)), .commit, .backspace, .cancel,
            ]
            for input in inputs {
                let out = tool.handle(input, context: .empty)
                assertNoMutation(out, "mode \(mode) input \(input)")
            }
        }
    }
}
