//
//  DivideToolTests.swift
//  CADEngineTests
//
//  Drives the DIVIDE modify tool PURELY (no GUI): feeds `ToolInput` events + a
//  read-only `ToolContext` carrying a known selection and asserts the divide
//  contract — dividing a line/arc/circle/polyline into N equal pieces emits the
//  right count of `.add` POINT entities at the equal-arc-length division points,
//  the source entity is untouched, and the open/closed point-count convention
//  holds (open → N−1 interior points, closed → N loop points).
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DivideTool modify (equal-segment point nodes)")
struct DivideToolTests {

    // MARK: - Helpers

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: records,
            entity: { id in records.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Pulls the ordered POINT positions out of a `.commit` of pure `.add` points.
    private func addedPoints(_ outcome: ToolOutcome) -> [Vector]? {
        guard case .commit(let edits) = outcome else { return nil }
        var pts: [Vector] = []
        for edit in edits {
            guard case .add(let r) = edit, case .point(let d) = r.kind else { return nil }
            pts.append(d.position)
        }
        return pts
    }

    private func approxEqual(_ a: Vector, _ b: Vector, eps: Double = 1e-9) -> Bool {
        a.distance(to: b) < eps
    }

    // MARK: - Basics

    @Test("title is Divide")
    func title() {
        #expect(DivideTool().title == "Divide")
    }

    @Test("status nudges to select first when nothing is selected")
    func statusEmpty() {
        #expect(DivideTool().status == "Select an object to divide first")
    }

    @Test("a fire with an empty selection is a no-op")
    func emptyNoop() {
        var tool = DivideTool(divisions: 5)
        #expect(tool.handle(.commit, context: .empty) == .none)
    }

    // MARK: - Line: 10-unit line into 5 → 4 interior points

    @Test("dividing a 10-unit line into 5 yields 4 interior points at the right spots")
    func lineInto5() {
        let line = EntityRecord(
            id: EntityID(1),
            layer: LayerID("L"),
            pen: .byLayer,
            flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
        var tool = DivideTool(divisions: 5)
        let pts = addedPoints(tool.handle(.commit, context: context([line])))
        #expect(pts != nil)
        #expect(pts?.count == 4)   // N − 1 interior points for an open entity
        // Equal spacing every 2 units: 2,4,6,8 (endpoints excluded).
        let expected = [Vector(2, 0), Vector(4, 0), Vector(6, 0), Vector(8, 0)]
        for (got, want) in zip(pts ?? [], expected) {
            #expect(approxEqual(got, want))
        }
    }

    @Test("the division points inherit the source line's layer/pen and use the placeholder id")
    func pointsInheritAttrs() {
        let line = EntityRecord(
            id: EntityID(2),
            layer: LayerID("dim"),
            pen: Pen(lineColor: .explicit(RGBAColor(0, 1, 0, 1))),
            flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0)))
        )
        var tool = DivideTool(divisions: 2)
        guard case .commit(let edits) = tool.handle(.commit, context: context([line])) else {
            Issue.record("expected a commit"); return
        }
        #expect(edits.count == 1)   // 2 pieces → 1 interior point
        guard case .add(let r) = edits[0] else { Issue.record("expected .add"); return }
        #expect(r.id == .placeholder)
        #expect(r.layer == line.layer)
        #expect(r.pen == line.pen)
    }

    // MARK: - Source untouched

    @Test("divide only ADDS points — it never replaces/removes the source")
    func sourceUntouched() {
        let line = EntityRecord(
            id: EntityID(3), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(6, 0)))
        )
        var tool = DivideTool(divisions: 3)
        guard case .commit(let edits) = tool.handle(.commit, context: context([line])) else {
            Issue.record("expected a commit"); return
        }
        for edit in edits {
            switch edit {
            case .add: break
            case .replace, .remove: Issue.record("Divide must not modify the source: \(edit)")
            }
        }
    }

    // MARK: - Arc

    @Test("dividing a quarter arc into 4 yields 3 interior points at equal sweep")
    func arcInto4() {
        // Quarter arc, radius 4, center origin, 0 → 90°.
        let arc = EntityRecord(
            id: EntityID(4), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .arc(ArcData(center: Vector(0, 0), radius: 4,
                               startAngle: 0, endAngle: Double.pi / 2, reversed: false))
        )
        var tool = DivideTool(divisions: 4)
        let pts = addedPoints(tool.handle(.commit, context: context([arc])))
        #expect(pts?.count == 3)   // N − 1
        // Equal sweep of 90°/4 = 22.5°: interior at 22.5°, 45°, 67.5°.
        let step = (Double.pi / 2) / 4
        for (k, p) in (pts ?? []).enumerated() {
            let want = Vector(0, 0) + Vector.polar(radius: 4, angle: step * Double(k + 1))
            #expect(approxEqual(p, want))
        }
    }

    // MARK: - Circle (closed → N loop points)

    @Test("dividing a circle into 6 yields 6 points around the circumference")
    func circleInto6() {
        let circle = EntityRecord(
            id: EntityID(5), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .circle(CircleData(center: Vector(0, 0), radius: 5))
        )
        var tool = DivideTool(divisions: 6)
        let pts = addedPoints(tool.handle(.commit, context: context([circle])))
        #expect(pts?.count == 6)   // closed loop → N points (start counts)
        let step = (2 * Double.pi) / 6
        for (k, p) in (pts ?? []).enumerated() {
            let want = Vector(0, 0) + Vector.polar(radius: 5, angle: step * Double(k))
            #expect(approxEqual(p, want))
        }
    }

    // MARK: - Polyline (open, straight)

    @Test("dividing an open 2-segment polyline into 4 yields 3 interior points by arc length")
    func openPolylineInto4() {
        // An L of two unit-length legs: (0,0)→(2,0)→(2,2), total length 4.
        let pl = EntityRecord(
            id: EntityID(6), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(2, 0)),
                PolylineVertex(point: Vector(2, 2)),
            ], closed: false))
        )
        var tool = DivideTool(divisions: 4)
        let pts = addedPoints(tool.handle(.commit, context: context([pl])))
        #expect(pts?.count == 3)   // open → N − 1
        // Total length 4, targets at 1,2,3: (1,0) on leg1, (2,0) at the corner, (2,1) on leg2.
        let expected = [Vector(1, 0), Vector(2, 0), Vector(2, 1)]
        for (got, want) in zip(pts ?? [], expected) {
            #expect(approxEqual(got, want))
        }
    }

    @Test("dividing a closed square polyline into 4 yields 4 loop points (the corners)")
    func closedPolylineInto4() {
        // Unit square (0,0)(2,0)(2,2)(0,2), closed; perimeter 8, quarter = 2 → corners.
        let pl = EntityRecord(
            id: EntityID(7), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(2, 0)),
                PolylineVertex(point: Vector(2, 2)),
                PolylineVertex(point: Vector(0, 2)),
            ], closed: true))
        )
        var tool = DivideTool(divisions: 4)
        let pts = addedPoints(tool.handle(.commit, context: context([pl])))
        #expect(pts?.count == 4)   // closed → N loop points
        // Perimeter 8, step 2 → the four corners starting at (0,0).
        let expected = [Vector(0, 0), Vector(2, 0), Vector(2, 2), Vector(0, 2)]
        for (got, want) in zip(pts ?? [], expected) {
            #expect(approxEqual(got, want))
        }
    }

    // MARK: - Degenerate division count is clamped

    @Test("divisions < 2 is clamped to 2 (one interior point on a line)")
    func divisionsClamped() {
        let line = EntityRecord(
            id: EntityID(8), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(8, 0)))
        )
        var tool = DivideTool(divisions: 1)   // clamped to 2
        let pts = addedPoints(tool.handle(.commit, context: context([line])))
        #expect(pts?.count == 1)
        #expect(approxEqual(pts![0], Vector(4, 0)))
    }
}
