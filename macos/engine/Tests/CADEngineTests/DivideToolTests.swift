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

    // MARK: - Mode facade / config

    @Test("default mode is count(2); the divisions facade mirrors it")
    func defaultModeIsCount() {
        let tool = DivideTool()
        #expect(tool.mode == .count(2))
        #expect(tool.divisions == 2)
    }

    @Test("setting divisions switches the mode to count(n); reading mirrors it back")
    func divisionsFacadeRoundTrips() {
        var tool = DivideTool(divisions: 7)
        #expect(tool.mode == .count(7))
        #expect(tool.divisions == 7)
        tool.divisions = 3
        #expect(tool.mode == .count(3))
        #expect(tool.divisions == 3)
    }

    @Test("the divisions facade reads 0 while in length mode")
    func divisionsFacadeInLengthMode() {
        let tool = DivideTool(mode: .length(2.5))
        #expect(tool.mode == .length(2.5))
        #expect(tool.divisions == 0)
    }

    @Test("count mode is unchanged when constructed via the explicit mode initializer")
    func countModeViaModeInitMatchesLegacy() {
        // The .count(n) mode initializer must produce identical output to the
        // historical DivideTool(divisions:) path — the by-length feature does not
        // perturb the existing DIVIDE behavior.
        let line = EntityRecord(
            id: EntityID(20), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
        var legacy = DivideTool(divisions: 5)
        var viaMode = DivideTool(mode: .count(5))
        let a = addedPoints(legacy.handle(.commit, context: context([line])))
        let b = addedPoints(viaMode.handle(.commit, context: context([line])))
        #expect(a?.count == 4)
        #expect(b?.count == 4)
        for (x, y) in zip(a ?? [], b ?? []) { #expect(approxEqual(x, y)) }
    }

    // MARK: - MEASURE (by length): line

    @Test("MEASURE a 10-unit line at spacing 2 → 4 interior nodes at 2,4,6,8 (start & end excluded)")
    func measureLineEvenFit() {
        let line = EntityRecord(
            id: EntityID(21), layer: LayerID("L"), pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
        var tool = DivideTool(mode: .length(2))
        let pts = addedPoints(tool.handle(.commit, context: context([line])))
        #expect(pts != nil)
        // Marched from the start every 2 units; the start (0) is not emitted and
        // the far end (10) is excluded too → 2,4,6,8.
        let expected = [Vector(2, 0), Vector(4, 0), Vector(6, 0), Vector(8, 0)]
        #expect(pts?.count == expected.count)
        for (got, want) in zip(pts ?? [], expected) { #expect(approxEqual(got, want)) }
    }

    @Test("MEASURE drops the trailing partial segment: 10-unit line at spacing 3 → 3,6,9 (1-unit stub dropped)")
    func measureLineRemainderDropped() {
        let line = EntityRecord(
            id: EntityID(22), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
        var tool = DivideTool(mode: .length(3))
        let pts = addedPoints(tool.handle(.commit, context: context([line])))
        // 3,6,9 — the final 1-unit remainder (9→10) is shorter than the spacing
        // so no node lands there (documented MEASURE remainder semantics).
        let expected = [Vector(3, 0), Vector(6, 0), Vector(9, 0)]
        #expect(pts?.count == 3)
        for (got, want) in zip(pts ?? [], expected) { #expect(approxEqual(got, want)) }
    }

    @Test("MEASURE marches from the start endpoint (vertical line: nodes climb in +Y)")
    func measureLineFromStart() {
        let line = EntityRecord(
            id: EntityID(23), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(0, 9)))
        )
        var tool = DivideTool(mode: .length(4))
        let pts = addedPoints(tool.handle(.commit, context: context([line])))
        // 4, 8 from the start; the 8→9 stub is dropped.
        let expected = [Vector(0, 4), Vector(0, 8)]
        #expect(pts?.count == 2)
        for (got, want) in zip(pts ?? [], expected) { #expect(approxEqual(got, want)) }
    }

    @Test("MEASURE with spacing longer than the line → no nodes (no-op, no commit)")
    func measureLineSpacingTooLong() {
        let line = EntityRecord(
            id: EntityID(24), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0)))
        )
        var tool = DivideTool(mode: .length(8))
        // No node fits → fire() emits no edits → the tool stays a no-op (.none),
        // matching the empty-result guard (it never commits an empty edit list).
        #expect(tool.handle(.commit, context: context([line])) == .none)
    }

    @Test("MEASURE with a non-positive spacing yields no nodes (no commit)")
    func measureNonPositiveSpacing() {
        let line = EntityRecord(
            id: EntityID(25), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
        var zeroTool = DivideTool(mode: .length(0))
        #expect(zeroTool.handle(.commit, context: context([line])) == .none)
        var negTool = DivideTool(mode: .length(-3))
        #expect(negTool.handle(.commit, context: context([line])) == .none)
    }

    // MARK: - MEASURE: arc

    @Test("MEASURE a quarter arc (radius 4) by arc-length spacing → nodes at the right sweep angles")
    func measureArc() {
        // Quarter arc radius 4 from 0→90°; arc length = (π/2)·4 ≈ 6.2832.
        let r = 4.0
        let arc = EntityRecord(
            id: EntityID(26), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .arc(ArcData(center: Vector(0, 0), radius: r,
                               startAngle: 0, endAngle: Double.pi / 2, reversed: false))
        )
        let spacing = 2.0   // arc-length units → 2/4 = 0.5 rad per step
        var tool = DivideTool(mode: .length(spacing))
        let pts = addedPoints(tool.handle(.commit, context: context([arc])))
        // total ≈ 6.2832 → nodes at 2,4,6 (the 6→6.2832 stub dropped) = 3 nodes.
        #expect(pts?.count == 3)
        for (k, p) in (pts ?? []).enumerated() {
            let s = spacing * Double(k + 1)
            let ang = s / r                              // CCW from start angle 0
            let want = Vector(0, 0) + Vector.polar(radius: r, angle: ang)
            #expect(approxEqual(p, want, eps: 1e-9))
        }
    }

    // MARK: - MEASURE: circle (full circumference from +X)

    @Test("MEASURE a circle marches the whole circumference from the +X point, remainder dropped")
    func measureCircle() {
        let r = 5.0
        let circle = EntityRecord(
            id: EntityID(27), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .circle(CircleData(center: Vector(0, 0), radius: r))
        )
        let spacing = 4.0
        var tool = DivideTool(mode: .length(spacing))
        let pts = addedPoints(tool.handle(.commit, context: context([circle])))
        // circumference = 2π·5 ≈ 31.4159 → nodes at 4,8,…,28 = 7 (the 28→31.42 stub dropped).
        #expect(pts?.count == 7)
        for (k, p) in (pts ?? []).enumerated() {
            let s = spacing * Double(k + 1)
            let ang = s / r                              // CCW from angle 0 (+X)
            let want = Vector(0, 0) + Vector.polar(radius: r, angle: ang)
            #expect(approxEqual(p, want, eps: 1e-9))
        }
    }

    // MARK: - MEASURE: polyline (open & closed)

    @Test("MEASURE an open 2-leg polyline (total length 4) at spacing 1 → 3 nodes at 1,2,3")
    func measureOpenPolyline() {
        // L of two legs: (0,0)→(2,0)→(2,2), total length 4.
        let pl = EntityRecord(
            id: EntityID(28), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(2, 0)),
                PolylineVertex(point: Vector(2, 2)),
            ], closed: false))
        )
        var tool = DivideTool(mode: .length(1))
        let pts = addedPoints(tool.handle(.commit, context: context([pl])))
        // Cumulative length 1,2,3 (the end at 4 is excluded): (1,0),(2,0),(2,1).
        let expected = [Vector(1, 0), Vector(2, 0), Vector(2, 1)]
        #expect(pts?.count == 3)
        for (got, want) in zip(pts ?? [], expected) { #expect(approxEqual(got, want)) }
    }

    @Test("MEASURE a closed square (perimeter 8) at spacing 2 → 3 corner nodes (start & wrap excluded)")
    func measureClosedPolyline() {
        // Unit-ish square (0,0)(2,0)(2,2)(0,2) closed; perimeter 8.
        let pl = EntityRecord(
            id: EntityID(29), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(2, 0)),
                PolylineVertex(point: Vector(2, 2)),
                PolylineVertex(point: Vector(0, 2)),
            ], closed: true))
        )
        var tool = DivideTool(mode: .length(2))
        let pts = addedPoints(tool.handle(.commit, context: context([pl])))
        // Perimeter 8, marched from the start (0,0): nodes at 2,4,6 → (2,0),(2,2),(0,2).
        // The start (0,0) and the full-loop wrap (8) are both excluded (MEASURE
        // marches the closed path as a finite length, dropping the closing stub).
        let expected = [Vector(2, 0), Vector(2, 2), Vector(0, 2)]
        #expect(pts?.count == 3)
        for (got, want) in zip(pts ?? [], expected) { #expect(approxEqual(got, want)) }
    }
}
