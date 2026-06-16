//
//  DrawToolVariantModeTests.swift
//  CADEngineTests
//
//  Drives the ADDITIVE draw-tool construction variants PURELY (no GUI):
//    - CircleTool `.twoPoint`  (diameter endpoints) and `.threePoint` (circumcircle)
//    - ArcTool    `.tangential` (start, tangent direction, through end)
//    - LineTool   `.absolute` / `.relative` angle-locked segments
//  Each test feeds `.click` / `.move` / `.value` inputs to the tool's state machine
//  and asserts the produced entity geometry, plus the degenerate guards (collinear
//  3 points → no circle; coincident picks ignored; end on the tangent line → no arc).
//
//  Domain-prefixed suite names (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide). These suites do
//  NOT overlap the existing `CircleTool` / `ArcTool` / `LineTool` suites — they cover
//  ONLY the new variant modes (the original-flow behavior stays in those files).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Shared extractors

private func committedCircle(_ outcome: ToolOutcome) -> CircleData? {
    guard case .commit(let edits) = outcome, edits.count == 1,
          case .add(let record) = edits[0],
          case .circle(let d) = record.kind else { return nil }
    return d
}

private func committedArc(_ outcome: ToolOutcome) -> ArcData? {
    guard case .commit(let edits) = outcome, edits.count == 1,
          case .add(let record) = edits[0],
          case .arc(let d) = record.kind else { return nil }
    return d
}

private func committedLine(_ outcome: ToolOutcome) -> LineData? {
    guard case .commit(let edits) = outcome, edits.count == 1,
          case .add(let record) = edits[0],
          case .line(let d) = record.kind else { return nil }
    return d
}

/// Angle of the arc's TANGENT (direction of travel away from the start point),
/// accounting for `reversed`. At the start the radial is `start − center`; the CCW
/// tangent is the radial rotated +90°, the CW tangent rotated −90°.
private func arcStartTangentAngle(_ arc: ArcData, start: Vector) -> Double {
    let radial = start - arc.center
    let tangent = arc.reversed
        ? Vector(radial.y, -radial.x)   // radial rotated −90° (CW)
        : Vector(-radial.y, radial.x)   // radial rotated +90° (CCW)
    return tangent.angle
}

private func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
private func approx(_ a: Vector, _ b: Vector, _ eps: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps
}

// MARK: - Circle: two-point (diameter) construction

@Suite("CircleConstructionMode two-point (diameter)")
struct CircleTwoPointModeTests {

    @Test("title and initial status reflect the diameter flow")
    func statusFlow() {
        var tool = CircleTool(mode: .twoPoint)
        #expect(tool.title == "Circle")
        #expect(tool.status == "Specify first diameter point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second diameter point")
    }

    @Test("two clicks → center = midpoint, radius = half the distance")
    func diameterGeometry() {
        var tool = CircleTool(mode: .twoPoint)
        _ = tool.handle(.click(Vector(-3, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(3, 0)), context: .empty)
        let c = committedCircle(outcome)
        #expect(c != nil)
        #expect(approx(c!.center, Vector(0, 0)))
        #expect(approx(c!.radius, 3))
    }

    @Test("diameter geometry is correct for an off-axis pair")
    func diameterOffAxis() {
        var tool = CircleTool(mode: .twoPoint)
        let a = Vector(2, 1), b = Vector(8, 9)
        _ = tool.handle(.click(a), context: .empty)
        let c = committedCircle(tool.handle(.click(b), context: .empty))
        #expect(c != nil)
        #expect(approx(c!.center, Vector(5, 5)))
        #expect(approx(c!.radius, (b - a).magnitude / 2))   // half of 10 = 5
    }

    @Test("re-arms after a commit (next diameter draws another circle)")
    func reArm() {
        var tool = CircleTool(mode: .twoPoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)
        #expect(tool.status == "Specify first diameter point")  // reset to mode's first pick
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let c = committedCircle(tool.handle(.click(Vector(20, 0)), context: .empty))
        #expect(c != nil)
        #expect(approx(c!.center, Vector(15, 0)))
        #expect(approx(c!.radius, 5))
    }

    @Test("coincident diameter endpoints are ignored (no degenerate circle)")
    func coincidentGuard() {
        var tool = CircleTool(mode: .twoPoint)
        _ = tool.handle(.click(Vector(4, 4)), context: .empty)
        let outcome = tool.handle(.click(Vector(4, 4)), context: .empty)
        #expect(committedCircle(outcome) == nil)
        if case .none = outcome {} else { Issue.record("expected .none for coincident pick") }
    }

    @Test(".value typed coordinate places a diameter endpoint just like a click")
    func valueInput() {
        var tool = CircleTool(mode: .twoPoint)
        _ = tool.handle(.value(Vector(0, -5)), context: .empty)
        let c = committedCircle(tool.handle(.value(Vector(0, 5)), context: .empty))
        #expect(c != nil)
        #expect(approx(c!.center, Vector(0, 0)))
        #expect(approx(c!.radius, 5))
    }

    @Test("preview shows the diameter circle once the first endpoint is fixed")
    func preview() {
        var tool = CircleTool(mode: .twoPoint)
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(-2, 0)), context: .empty)
        _ = tool.handle(.move(Vector(2, 0)), context: .empty)
        #expect(tool.preview.count == 1)
        #expect(tool.preview[0].closed)
    }

    @Test("backspace from the second pick rewinds to the first")
    func backspace() {
        var tool = CircleTool(mode: .twoPoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second diameter point")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify first diameter point")
    }
}

// MARK: - Circle: three-point (circumcircle) construction

@Suite("CircleConstructionMode three-point (circumcircle)")
struct CircleThreePointModeTests {

    @Test("status walks first → second → third point")
    func statusFlow() {
        var tool = CircleTool(mode: .threePoint)
        #expect(tool.status == "Specify first point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second point")
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)
        #expect(tool.status == "Specify third point")
    }

    @Test("circle passes through all three points (center equidistant)")
    func passesThroughThree() {
        var tool = CircleTool(mode: .threePoint)
        // (2,0),(0,2),(-2,0) all lie on the unit-... circle of radius 2 about origin.
        let a = Vector(2, 0), b = Vector(0, 2), c = Vector(-2, 0)
        _ = tool.handle(.click(a), context: .empty)
        _ = tool.handle(.click(b), context: .empty)
        let circle = committedCircle(tool.handle(.click(c), context: .empty))
        #expect(circle != nil)
        #expect(approx(circle!.center, Vector(0, 0)))
        #expect(approx(circle!.radius, 2))
        // Each pick is exactly `radius` from the center.
        for p in [a, b, c] {
            #expect(approx((p - circle!.center).magnitude, circle!.radius))
        }
    }

    @Test("circumcircle of an arbitrary (non-symmetric) triple is equidistant")
    func arbitraryTriple() {
        var tool = CircleTool(mode: .threePoint)
        let a = Vector(1, 1), b = Vector(7, 3), c = Vector(2, 8)
        _ = tool.handle(.click(a), context: .empty)
        _ = tool.handle(.click(b), context: .empty)
        let circle = committedCircle(tool.handle(.click(c), context: .empty))
        #expect(circle != nil)
        let r = circle!.radius
        #expect(approx((a - circle!.center).magnitude, r, 1e-7))
        #expect(approx((b - circle!.center).magnitude, r, 1e-7))
        #expect(approx((c - circle!.center).magnitude, r, 1e-7))
    }

    @Test("collinear three points → graceful: NO circle committed, keeps waiting")
    func collinearGuard() {
        var tool = CircleTool(mode: .threePoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(2, 0)), context: .empty)  // all on y=0
        #expect(committedCircle(outcome) == nil)
        if case .none = outcome {} else { Issue.record("expected .none for collinear triple") }
        // Still waiting for a valid third point.
        #expect(tool.status == "Specify third point")
    }

    @Test("coincident second pick is ignored (no advance)")
    func coincidentSecond() {
        var tool = CircleTool(mode: .threePoint)
        _ = tool.handle(.click(Vector(3, 3)), context: .empty)
        let outcome = tool.handle(.click(Vector(3, 3)), context: .empty)  // == first
        if case .none = outcome {} else { Issue.record("expected .none for coincident 2nd pick") }
        #expect(tool.status == "Specify second point")  // did not advance
    }

    @Test("backspace from third pick rewinds to second, keeping the first")
    func backspace() {
        var tool = CircleTool(mode: .threePoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)
        #expect(tool.status == "Specify third point")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify second point")
    }

    @Test("static circleThrough helper: collinear → nil; valid → circumcircle")
    func helperDirect() {
        #expect(CircleTool.circleThrough(Vector(0, 0), Vector(1, 0), Vector(2, 0)) == nil)
        let c = CircleTool.circleThrough(Vector(0, -1), Vector(1, 0), Vector(0, 1))
        #expect(c != nil)
        #expect(approx(c!.center, Vector(0, 0)))
        #expect(approx(c!.radius, 1))
    }
}

// MARK: - Default (centerRadius) mode is unchanged

@Suite("CircleConstructionMode default centerRadius unchanged")
struct CircleDefaultModeTests {

    @Test("CircleTool() and CircleTool(mode: .centerRadius) keep the center→radius flow")
    func defaultUnchanged() {
        for tool0 in [CircleTool(), CircleTool(mode: .centerRadius)] {
            var tool = tool0
            #expect(tool.status == "Specify center point")
            _ = tool.handle(.click(Vector(0, 0)), context: .empty)
            #expect(tool.status == "Specify radius")
            let c = committedCircle(tool.handle(.click(Vector(5, 0)), context: .empty))
            #expect(c != nil)
            #expect(approx(c!.center, Vector(0, 0)))
            #expect(approx(c!.radius, 5))
        }
    }
}

// MARK: - Arc: tangential construction

@Suite("ArcCreationMode tangential")
struct ArcTangentialTests {

    @Test("status walks start → tangent direction → end")
    func statusFlow() {
        var tool = ArcTool(mode: .tangential)
        #expect(tool.title == "Arc")
        #expect(tool.status == "Specify start point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify tangent direction")
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        #expect(tool.status == "Specify end point")
    }

    @Test("arc starts at the start point and is tangent there to the picked direction")
    func tangentAtStart() {
        var tool = ArcTool(mode: .tangential)
        let start = Vector(0, 0)
        let dirPoint = Vector(1, 0)         // tangent points +X at the start
        let end = Vector(0, 2)              // arc curves up to the left
        _ = tool.handle(.click(start), context: .empty)
        _ = tool.handle(.click(dirPoint), context: .empty)
        let arc = committedArc(tool.handle(.click(end), context: .empty))
        #expect(arc != nil)
        // Start point is ON the arc.
        #expect(approx((start - arc!.center).magnitude, arc!.radius))
        // End point is ON the arc.
        #expect(approx((end - arc!.center).magnitude, arc!.radius, 1e-7))
        // Tangent at the start matches the picked direction (+X → angle 0).
        let tanAngle = arcStartTangentAngle(arc!, start: start)
        #expect(approx(Vector.correctAngle(tanAngle), Vector.correctAngle(0), 1e-7))
    }

    @Test("tangent direction is honored for a slanted (45°) tangent")
    func slantedTangent() {
        var tool = ArcTool(mode: .tangential)
        let start = Vector(0, 0)
        let dirPoint = Vector(1, 1)         // tangent at 45°
        let end = Vector(-1, 3)
        _ = tool.handle(.click(start), context: .empty)
        _ = tool.handle(.click(dirPoint), context: .empty)
        let arc = committedArc(tool.handle(.click(end), context: .empty))
        #expect(arc != nil)
        #expect(approx((start - arc!.center).magnitude, arc!.radius, 1e-7))
        #expect(approx((end - arc!.center).magnitude, arc!.radius, 1e-7))
        let tanAngle = Vector.correctAngle(arcStartTangentAngle(arc!, start: start))
        #expect(approx(tanAngle, Vector.correctAngle(.pi / 4), 1e-7))
    }

    @Test("end lying ON the tangent line → graceful: NO arc, keeps waiting")
    func endOnTangentLineGuard() {
        var tool = ArcTool(mode: .tangential)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)   // tangent = +X
        let outcome = tool.handle(.click(Vector(5, 0)), context: .empty)  // end on the +X line
        #expect(committedArc(outcome) == nil)
        if case .none = outcome {} else { Issue.record("expected .none for end on tangent line") }
        #expect(tool.status == "Specify end point")
    }

    @Test("coincident tangent-direction pick is ignored (no direction)")
    func coincidentDirGuard() {
        var tool = ArcTool(mode: .tangential)
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        let outcome = tool.handle(.click(Vector(2, 2)), context: .empty)  // == start
        if case .none = outcome {} else { Issue.record("expected .none for coincident dir pick") }
        #expect(tool.status == "Specify tangent direction")
    }

    @Test("preview rubber-bands a tangential arc once start + direction are fixed")
    func preview() {
        var tool = ArcTool(mode: .tangential)
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.move(Vector(0, 2)), context: .empty)
        #expect(tool.preview.count == 1)
        #expect(!tool.preview[0].closed)
    }

    @Test("backspace from end pick rewinds to tangent direction, keeping start")
    func backspace() {
        var tool = ArcTool(mode: .tangential)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        #expect(tool.status == "Specify end point")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify tangent direction")
    }

    @Test("static arcTangent helper: degenerate inputs → nil")
    func helperGuards() {
        // Zero-length tangent.
        #expect(ArcTool.arcTangent(start: Vector(0, 0), tangent: Vector(0, 0), end: Vector(1, 1)) == nil)
        // End coincident with start.
        #expect(ArcTool.arcTangent(start: Vector(0, 0), tangent: Vector(1, 0), end: Vector(0, 0)) == nil)
        // End on the tangent line.
        #expect(ArcTool.arcTangent(start: Vector(0, 0), tangent: Vector(1, 0), end: Vector(3, 0)) == nil)
        // A valid case yields a finite arc.
        #expect(ArcTool.arcTangent(start: Vector(0, 0), tangent: Vector(1, 0), end: Vector(0, 2)) != nil)
    }
}

// MARK: - Arc: default & three-point modes unchanged

@Suite("ArcCreationMode defaults unchanged by tangential addition")
struct ArcExistingModesUnchangedTests {

    @Test("center→start→end default flow still commits a CCW arc")
    func defaultFlow() {
        var tool = ArcTool()  // .centerStartEnd
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // center
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)   // start (radius 2, angle 0)
        let arc = committedArc(tool.handle(.click(Vector(0, 2)), context: .empty)) // end angle 90°
        #expect(arc != nil)
        #expect(approx(arc!.center, Vector(0, 0)))
        #expect(approx(arc!.radius, 2))
        #expect(arc!.reversed == false)
    }

    @Test("three-point flow still commits the arc through the three picks")
    func threePointFlow() {
        var tool = ArcTool(mode: .threePoint)
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 2)), context: .empty)
        let arc = committedArc(tool.handle(.click(Vector(-2, 0)), context: .empty))
        #expect(arc != nil)
        #expect(approx(arc!.center, Vector(0, 0), 1e-7))
        #expect(approx(arc!.radius, 2, 1e-7))
    }
}

// MARK: - Line: angle-locked construction

@Suite("LineAngleMode absolute / relative")
struct LineAngleModeTests {

    @Test("free mode (default) is unchanged: segment runs straight to the pick")
    func freeUnchanged() {
        var tool = LineTool()  // .free
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let line = committedLine(tool.handle(.click(Vector(3, 4)), context: .empty))
        #expect(line != nil)
        #expect(approx(line!.start, Vector(0, 0)))
        #expect(approx(line!.end, Vector(3, 4)))   // exact pick, no projection
    }

    @Test("absolute angle: endpoint lands on the locked ray (pick projected)")
    func absoluteAngle() {
        // Lock to 0° (the +X axis). A pick at (5, 7) projects onto +X → (5, 0).
        var tool = LineTool(angleMode: .absolute(0))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let line = committedLine(tool.handle(.click(Vector(5, 7)), context: .empty))
        #expect(line != nil)
        #expect(approx(line!.start, Vector(0, 0)))
        #expect(approx(line!.end, Vector(5, 0)))
        // The segment direction is exactly the locked angle.
        #expect(approx((line!.end - line!.start).angle, 0, 1e-9))
    }

    @Test("absolute 90°: pick projects onto the +Y ray")
    func absoluteVertical() {
        var tool = LineTool(angleMode: .absolute(.pi / 2))
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        let line = committedLine(tool.handle(.click(Vector(4, 6)), context: .empty))
        #expect(line != nil)
        // From (1,1) the +Y projection of (4,6) is (1,6).
        #expect(approx(line!.end, Vector(1, 6)))
        #expect(approx((line!.end - line!.start).angle, .pi / 2, 1e-9))
    }

    @Test("relative angle: each segment turns by the angle off the previous segment")
    func relativeAngle() {
        // First segment relative to +X (no previous) → behaves absolute: 0° here.
        // Second segment turns +90° from the first → runs +Y.
        var tool = LineTool(angleMode: .relative(.pi / 2))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // First pick: relative angle is (0 + 90°) = 90° for the FIRST segment
        // (lastDirection nil → base +X, +90° → +Y). Pick (3,5) projects onto +Y.
        let first = committedLine(tool.handle(.click(Vector(3, 5)), context: .empty))
        #expect(first != nil)
        #expect(approx(first!.end, Vector(0, 5)))               // along +Y
        let firstDir = (first!.end - first!.start).angle
        #expect(approx(firstDir, .pi / 2, 1e-9))
        // Second segment turns +90° from +Y → −X direction. Pick (−2, 9) projects
        // onto the ray from (0,5) at angle 180°: only the X-delta counts → (−2, 5).
        let second = committedLine(tool.handle(.click(Vector(-2, 9)), context: .empty))
        #expect(second != nil)
        #expect(approx(second!.start, Vector(0, 5)))
        #expect(approx(second!.end, Vector(-2, 5)))
        let secondDir = Vector.correctAngle((second!.end - second!.start).angle)
        #expect(approx(secondDir, Vector.correctAngle(.pi), 1e-9))   // turned +90° again
    }

    @Test("preview reflects the locked angle (rubber-band already projected)")
    func previewProjected() {
        var tool = LineTool(angleMode: .absolute(0))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 9)), context: .empty)
        #expect(tool.preview.count == 1)
        let pts = tool.preview[0].points
        #expect(pts.count == 2)
        #expect(approx(pts[0], Vector(0, 0)))
        #expect(approx(pts[1], Vector(5, 0)))   // projected onto +X, not (5,9)
    }

    @Test(".value typed point is also angle-projected")
    func valueProjected() {
        var tool = LineTool(angleMode: .absolute(.pi / 2))
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        let line = committedLine(tool.handle(.value(Vector(3, 8)), context: .empty))
        #expect(line != nil)
        #expect(approx(line!.end, Vector(0, 8)))
    }

    @Test("a pick directly behind the locked ray projects to a zero-length no-op")
    func behindRayGuard() {
        // Lock +X; a pick at (−4, 0) is straight behind → projection length is
        // negative, BUT it still lands on the ray line at (−4,0)... that is a
        // valid (non-degenerate) backward segment, so a pick exactly AT the start's
        // projection (perpendicular pick) is the no-op we guard. Pick (0, 9) on +X
        // lock projects to (0,0) == start → ignored.
        var tool = LineTool(angleMode: .absolute(0))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(0, 9)), context: .empty)  // projects to start
        #expect(committedLine(outcome) == nil)
        if case .none = outcome {} else { Issue.record("expected .none for zero-length projection") }
    }

    @Test("chaining still works under an absolute lock (continues from endpoint)")
    func chaining() {
        var tool = LineTool(angleMode: .absolute(0))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let first = committedLine(tool.handle(.click(Vector(3, 5)), context: .empty))
        #expect(first != nil)
        #expect(approx(first!.end, Vector(3, 0)))
        // Next segment continues from (3,0), again locked +X.
        let second = committedLine(tool.handle(.click(Vector(7, 2)), context: .empty))
        #expect(second != nil)
        #expect(approx(second!.start, Vector(3, 0)))
        #expect(approx(second!.end, Vector(7, 0)))
    }
}
