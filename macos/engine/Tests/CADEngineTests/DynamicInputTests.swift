//
//  DynamicInputTests.swift
//  CADEngineTests
//
//  Wave EE — the ENGINE COMMIT MATH for EDITABLE live dimensions (dynamic input).
//  Covers `Tool.applyDynamicInput(_:cursor:reference:)` per tool: a typed dimension
//  value (length/angle/width/height/radius/diameter) resolves to the WORLD point the
//  tool commits to, reusing the proven `.value(point)` coordinate-commit seam.
//
//  These tests drive each tool into the state where dynamic input is meaningful and
//  assert the resolved point for: a single typed field (the others fall back to the
//  live cursor), all typed fields, sign/quadrant preservation (Rectangle), the locked
//  ray (constrained Line), zero-safe direction (Circle/Polygon at cursor==reference),
//  and `nil` outside the editable state/mode. No GUI/CADDrawing/modal is touched — the
//  tools are pure value types fed pure world points.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Dynamic input (applyDynamicInput)")
struct DynamicInputTests {

    /// Asserts two vectors agree to a tight tolerance (commit math is f64, but trig
    /// round-trips through cos/sin so an exact `==` is brittle).
    private func near(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.x - b.x) <= tol, "x: \(a.x) vs \(b.x)", sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) <= tol, "y: \(a.y) vs \(b.y)", sourceLocation: sourceLocation)
    }

    /// Drives a tool through inputs (pure world points), returning the mutated tool.
    private func drive<T: Tool>(_ tool: T, _ inputs: [ToolInput]) -> T {
        var t = tool
        for i in inputs { _ = t.handle(i, context: .empty) }
        return t
    }

    // MARK: - LineTool (free angle mode)

    @Test("Line free mode: length-only types the reach along the live cursor angle")
    func lineFreeLengthOnly() {
        // Anchor at origin; cursor on +X at distance 5 (live angle 0).
        let tool = drive(LineTool(), [.click(.init(0, 0)), .move(.init(5, 0))])
        let p = tool.applyDynamicInput([.length: 20], cursor: .init(5, 0), reference: .init(0, 0))
        // Length 20 at the live angle (0) → (20, 0).
        near(p ?? .invalid, .init(20, 0))
    }

    @Test("Line free mode: angle-only keeps the live length, rotates to the typed angle")
    func lineFreeAngleOnly() {
        let tool = drive(LineTool(), [.click(.init(0, 0)), .move(.init(10, 0))])
        // Live length 10; type 90° → straight up.
        let p = tool.applyDynamicInput([.angle: .pi / 2], cursor: .init(10, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, 10))
    }

    @Test("Line free mode: typing both length and angle fully fixes the point")
    func lineFreeBoth() {
        let tool = drive(LineTool(), [.click(.init(0, 0)), .move(.init(3, 3))])
        // length 10 @ 45° → (10/√2, 10/√2).
        let p = tool.applyDynamicInput([.length: 10, .angle: .pi / 4],
                                       cursor: .init(3, 3), reference: .init(0, 0))
        let r = 10.0 / 2.0.squareRoot()
        near(p ?? .invalid, .init(r, r))
    }

    @Test("Line free mode: no typed values falls back to the live cursor reach")
    func lineFreeNoValues() {
        let tool = drive(LineTool(), [.click(.init(0, 0)), .move(.init(6, 8))])
        // Empty map → live length (10) at the live angle → the cursor itself.
        let p = tool.applyDynamicInput([:], cursor: .init(6, 8), reference: .init(0, 0))
        near(p ?? .invalid, .init(6, 8))
    }

    // MARK: - LineTool (constrained angle mode)

    @Test("Line constrained mode: length lands on the locked ray, ignoring a typed angle")
    func lineConstrainedLengthOnLockedRay() {
        // Lock the segment to an absolute 90° ray.
        let tool = drive(LineTool(angleMode: .absolute(.pi / 2)),
                         [.click(.init(0, 0)), .move(.init(2, 5))])
        // Type a length of 7 (and a bogus angle that must be ignored). The point must
        // land on the +Y ray at distance 7 → (0, 7).
        let p = tool.applyDynamicInput([.length: 7, .angle: 0],
                                       cursor: .init(2, 5), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, 7))
    }

    @Test("Line constrained mode: a typed length matches a same-reach click commit")
    func lineConstrainedMatchesClickPath() {
        // The dynamic-input point must equal what a click of that reach commits, since
        // both route through `constrained(_:_:)`. Lock to 30°.
        let angle = Double.pi / 6
        var tool = LineTool(angleMode: .absolute(angle))
        _ = tool.handle(.click(.init(0, 0)), context: .empty)
        _ = tool.handle(.move(.init(4, 1)), context: .empty)
        // Dynamic input: length 9 along the 30° ray.
        let dyn = tool.applyDynamicInput([.length: 9], cursor: .init(4, 1), reference: .init(0, 0))
        // The equivalent click: a point 9 along the ray (any point on the ray at reach 9
        // projects to the same place; use the exact ray point).
        let expected = Vector(angle: angle) * 9
        near(dyn ?? .invalid, expected)
    }

    @Test("Line: nil before the first point is fixed")
    func lineNilBeforeStart() {
        let fresh = LineTool()
        #expect(fresh.applyDynamicInput([.length: 5], cursor: .init(1, 1), reference: .init(0, 0)) == nil)
        // After a single move (still no fixed start) → still nil.
        let moved = drive(LineTool(), [.move(.init(5, 0))])
        #expect(moved.applyDynamicInput([.length: 5], cursor: .init(5, 0), reference: .init(0, 0)) == nil)
    }

    // MARK: - RectangleTool (all four quadrants — sign preservation)

    @Test("Rectangle: typed width/height extend toward the cursor quadrant (4 quadrants)")
    func rectangleQuadrants() {
        let first = Vector(10, 10)
        // For each quadrant, the cursor sign decides the extend direction; the typed
        // W/H magnitudes (3, 7) are applied with that sign from the first corner.
        let cases: [(cursor: Vector, expected: Vector)] = [
            (.init(20, 20), .init(13, 17)),   // up-right  → +x +y
            (.init(0, 20),  .init(7, 17)),    // up-left   → -x +y
            (.init(0, 0),   .init(7, 3)),     // down-left → -x -y
            (.init(20, 0),  .init(13, 3)),    // down-right→ +x -y
        ]
        for c in cases {
            let tool = drive(RectangleTool(), [.click(first), .move(c.cursor)])
            let p = tool.applyDynamicInput([.width: 3, .height: 7], cursor: c.cursor, reference: first)
            near(p ?? .invalid, c.expected)
        }
    }

    @Test("Rectangle: a single typed field keeps the live extent for the other")
    func rectanglePartialField() {
        let first = Vector(0, 0)
        let tool = drive(RectangleTool(), [.click(first), .move(.init(4, 9))])
        // Width typed (10), height from the live cursor (9), cursor up-right → +x +y.
        let pW = tool.applyDynamicInput([.width: 10], cursor: .init(4, 9), reference: first)
        near(pW ?? .invalid, .init(10, 9))
        // Height typed (10), width from the live cursor (4).
        let pH = tool.applyDynamicInput([.height: 10], cursor: .init(4, 9), reference: first)
        near(pH ?? .invalid, .init(4, 10))
    }

    @Test("Rectangle: nil before the first corner is fixed")
    func rectangleNilBeforeFirst() {
        let fresh = RectangleTool()
        #expect(fresh.applyDynamicInput([.width: 5, .height: 5],
                                        cursor: .init(1, 1), reference: .init(0, 0)) == nil)
    }

    // MARK: - CircleTool

    @Test("Circle: typed radius places the on-circle point along the live direction")
    func circleRadius() {
        // Center at origin; cursor in the +X+Y direction. A typed radius 13 lands on the
        // unit direction of the cursor.
        let tool = drive(CircleTool(), [.click(.init(0, 0)), .move(.init(3, 4))])
        let p = tool.applyDynamicInput([.radius: 13], cursor: .init(3, 4), reference: .init(0, 0))
        // unit(3,4) = (0.6, 0.8) → ×13 = (7.8, 10.4).
        near(p ?? .invalid, .init(7.8, 10.4))
    }

    @Test("Circle: typed diameter is halved to the radius")
    func circleDiameter() {
        var tool = CircleTool()
        tool.sizeMode = .diameter
        tool = drive(tool, [.click(.init(0, 0)), .move(.init(1, 0))])
        // Diameter 20 → radius 10, along +X.
        let p = tool.applyDynamicInput([.diameter: 20], cursor: .init(1, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(10, 0))
    }

    @Test("Circle: no typed value falls back to the live radius")
    func circleNoValue() {
        let tool = drive(CircleTool(), [.click(.init(0, 0)), .move(.init(6, 8))])
        let p = tool.applyDynamicInput([:], cursor: .init(6, 8), reference: .init(0, 0))
        near(p ?? .invalid, .init(6, 8))   // live radius 10 along (6,8)
    }

    @Test("Circle: degenerate cursor==center falls back to +X direction")
    func circleDegenerateDirection() {
        // Drive into .settingRadius, then resolve with cursor exactly on the center.
        let tool = drive(CircleTool(), [.click(.init(0, 0)), .move(.init(5, 0))])
        let p = tool.applyDynamicInput([.radius: 5], cursor: .init(0, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(5, 0))   // +X fallback × 5
    }

    @Test("Circle: nil in the 2-point and 3-point construction modes")
    func circleNilInTwoAndThreePoint() {
        let twoP = drive(CircleTool(mode: .twoPoint), [.click(.init(0, 0)), .move(.init(8, 0))])
        #expect(twoP.applyDynamicInput([.radius: 5], cursor: .init(8, 0), reference: .init(4, 0)) == nil)

        let threeP = drive(CircleTool(mode: .threePoint),
                           [.click(.init(0, 0)), .click(.init(8, 0)), .move(.init(4, 4))])
        #expect(threeP.applyDynamicInput([.radius: 5], cursor: .init(4, 4), reference: .init(4, 0)) == nil)

        // And nil before the center is even fixed.
        #expect(CircleTool().applyDynamicInput([.radius: 5],
                                               cursor: .init(1, 1), reference: .init(0, 0)) == nil)
    }

    // MARK: - PolygonTool

    @Test("Polygon center modes: typed radius places the vertex along the live direction")
    func polygonRadius() {
        var tool = PolygonTool()
        tool.sides = 6
        tool = drive(tool, [.click(.init(0, 0)), .move(.init(3, 4))])
        let p = tool.applyDynamicInput([.radius: 13], cursor: .init(3, 4), reference: .init(0, 0))
        near(p ?? .invalid, .init(7.8, 10.4))   // unit(3,4) × 13

        // star mode is also center-based → resolves.
        var star = PolygonTool()
        star.mode = .star(ratio: 0.5)
        star = drive(star, [.click(.init(0, 0)), .move(.init(1, 0))])
        let ps = star.applyDynamicInput([.radius: 9], cursor: .init(1, 0), reference: .init(0, 0))
        near(ps ?? .invalid, .init(9, 0))
    }

    @Test("Polygon: degenerate cursor==center falls back to +X direction")
    func polygonDegenerateDirection() {
        let tool = drive(PolygonTool(), [.click(.init(0, 0)), .move(.init(5, 0))])
        let p = tool.applyDynamicInput([.radius: 5], cursor: .init(0, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(5, 0))
    }

    @Test("Polygon: nil in edge mode and before the center is fixed")
    func polygonNilEdgeAndBeforeCenter() {
        var edge = PolygonTool()
        edge.mode = .edge
        edge = drive(edge, [.click(.init(0, 0)), .move(.init(5, 0))])
        #expect(edge.applyDynamicInput([.radius: 5], cursor: .init(5, 0), reference: .init(0, 0)) == nil)

        #expect(PolygonTool().applyDynamicInput([.radius: 5],
                                                cursor: .init(1, 1), reference: .init(0, 0)) == nil)
    }

    // MARK: - PolylineTool (free angle, like LineTool — reference = last vertex)

    @Test("Polyline: length-only types the reach along the live cursor angle")
    func polylineLengthOnly() {
        // Two vertices placed; the running anchor is the last one (5,5).
        let tool = drive(PolylineTool(),
                         [.click(.init(0, 0)), .click(.init(5, 5)), .move(.init(15, 5))])
        let p = tool.applyDynamicInput([.length: 20], cursor: .init(15, 5), reference: .init(5, 5))
        // Length 20 at the live angle (0) from (5,5) → (25, 5).
        near(p ?? .invalid, .init(25, 5))
    }

    @Test("Polyline: angle-only keeps the live length, rotates to the typed angle")
    func polylineAngleOnly() {
        let tool = drive(PolylineTool(), [.click(.init(0, 0)), .move(.init(10, 0))])
        // Live length 10; type 90° from the first vertex (0,0) → straight up.
        let p = tool.applyDynamicInput([.angle: .pi / 2], cursor: .init(10, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, 10))
    }

    @Test("Polyline: typing both length and angle fully fixes the point")
    func polylineBoth() {
        let tool = drive(PolylineTool(), [.click(.init(2, 2)), .move(.init(5, 5))])
        // length 10 @ 45° from the anchor (2,2) → (2 + 10/√2, 2 + 10/√2).
        let p = tool.applyDynamicInput([.length: 10, .angle: .pi / 4],
                                       cursor: .init(5, 5), reference: .init(2, 2))
        let r = 10.0 / 2.0.squareRoot()
        near(p ?? .invalid, .init(2 + r, 2 + r))
    }

    @Test("Polyline: no typed values falls back to the live cursor reach")
    func polylineNoValues() {
        let tool = drive(PolylineTool(), [.click(.init(0, 0)), .move(.init(6, 8))])
        let p = tool.applyDynamicInput([:], cursor: .init(6, 8), reference: .init(0, 0))
        near(p ?? .invalid, .init(6, 8))
    }

    @Test("Polyline: nil before the first vertex is placed")
    func polylineNilBeforeStart() {
        let fresh = PolylineTool()
        #expect(fresh.applyDynamicInput([.length: 5], cursor: .init(1, 1), reference: .init(0, 0)) == nil)
        // After a bare move (still no fixed vertex) → still nil.
        let moved = drive(PolylineTool(), [.move(.init(5, 0))])
        #expect(moved.applyDynamicInput([.length: 5], cursor: .init(5, 0), reference: .init(0, 0)) == nil)
    }

    // MARK: - ArcTool (center→start→end mode only — reference = center)

    @Test("Arc settingStart: typed radius places the start along the live direction")
    func arcStartRadius() {
        // Center at origin; cursor in the +X+Y direction. A typed radius 13 lands on the
        // unit direction of the cursor.
        let tool = drive(ArcTool(), [.click(.init(0, 0)), .move(.init(3, 4))])
        let p = tool.applyDynamicInput([.radius: 13], cursor: .init(3, 4), reference: .init(0, 0))
        near(p ?? .invalid, .init(7.8, 10.4))   // unit(3,4) × 13
    }

    @Test("Arc settingStart: no typed value falls back to the live radius")
    func arcStartNoValue() {
        let tool = drive(ArcTool(), [.click(.init(0, 0)), .move(.init(6, 8))])
        let p = tool.applyDynamicInput([:], cursor: .init(6, 8), reference: .init(0, 0))
        near(p ?? .invalid, .init(6, 8))         // live radius 10 along (6,8)
    }

    @Test("Arc settingStart: degenerate cursor==center falls back to +X direction")
    func arcStartDegenerate() {
        let tool = drive(ArcTool(), [.click(.init(0, 0)), .move(.init(5, 0))])
        let p = tool.applyDynamicInput([.radius: 5], cursor: .init(0, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(5, 0))         // +X fallback × 5
    }

    @Test("Arc settingEnd: typed end angle places the point on the FIXED-radius circle")
    func arcEndAngle() {
        // Center (0,0), start (10,0) → radius 10. Type 90° → the end point at (0, 10).
        let tool = drive(ArcTool(),
                         [.click(.init(0, 0)), .click(.init(10, 0)), .move(.init(5, 5))])
        let p = tool.applyDynamicInput([.angle: .pi / 2], cursor: .init(5, 5), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, 10))
    }

    @Test("Arc settingEnd: no typed angle uses the live cursor angle at the fixed radius")
    func arcEndNoValue() {
        // Center (0,0), radius 10. Live cursor at 45° → the on-circle point at 45°.
        let tool = drive(ArcTool(),
                         [.click(.init(0, 0)), .click(.init(10, 0)), .move(.init(5, 5))])
        let p = tool.applyDynamicInput([:], cursor: .init(5, 5), reference: .init(0, 0))
        let h = 10.0 / 2.0.squareRoot()
        near(p ?? .invalid, .init(h, h))
    }

    @Test("Arc: nil in the 3-point and tangential modes, and before the center")
    func arcNilOtherModes() {
        let threeP = drive(ArcTool(mode: .threePoint),
                           [.click(.init(0, 0)), .click(.init(10, 0)), .move(.init(5, 5))])
        #expect(threeP.applyDynamicInput([.radius: 5], cursor: .init(5, 5), reference: .init(0, 0)) == nil)

        let tan = drive(ArcTool(mode: .tangential),
                        [.click(.init(0, 0)), .click(.init(1, 0)), .move(.init(5, 5))])
        #expect(tan.applyDynamicInput([.radius: 5], cursor: .init(5, 5), reference: .init(0, 0)) == nil)

        // nil before the center is fixed (settingCenter).
        #expect(ArcTool().applyDynamicInput([.radius: 5],
                                            cursor: .init(1, 1), reference: .init(0, 0)) == nil)
    }

    // MARK: - EllipseTool (axis-style modes only — reference = center)

    @Test("Ellipse settingMajor: typed axis distance places the endpoint along the live direction")
    func ellipseMajorDistance() {
        // Center at origin; cursor in the +X+Y direction. A typed distance 13 lands on
        // the unit direction of the cursor.
        let tool = drive(EllipseTool(), [.click(.init(0, 0)), .move(.init(3, 4))])
        let p = tool.applyDynamicInput([.radius: 13], cursor: .init(3, 4), reference: .init(0, 0))
        near(p ?? .invalid, .init(7.8, 10.4))   // unit(3,4) × 13
    }

    @Test("Ellipse settingMajor: degenerate cursor==center falls back to +X direction")
    func ellipseMajorDegenerate() {
        let tool = drive(EllipseTool(), [.click(.init(0, 0)), .move(.init(5, 0))])
        let p = tool.applyDynamicInput([.radius: 5], cursor: .init(0, 0), reference: .init(0, 0))
        near(p ?? .invalid, .init(5, 0))
    }

    @Test("Ellipse settingRatio: typed minor distance lands perpendicular, on the cursor's side")
    func ellipseRatioMinor() {
        // Center (0,0), major endpoint (10,0) → majorP (10,0). The perpendicular is +Y;
        // the cursor (3,4) is on the +Y side. A typed minor distance 6 → (0, 6) (perp
        // distance to the major line is exactly 6).
        let tool = drive(EllipseTool(),
                         [.click(.init(0, 0)), .click(.init(10, 0)), .move(.init(3, 4))])
        let p = tool.applyDynamicInput([.length: 6], cursor: .init(3, 4), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, 6))
    }

    @Test("Ellipse settingRatio: follows the cursor's perpendicular side (below the major line)")
    func ellipseRatioMinorBelow() {
        // Same major axis, but the cursor is BELOW the major line (3, -4) → the typed
        // minor distance lands on −Y.
        let tool = drive(EllipseTool(),
                         [.click(.init(0, 0)), .click(.init(10, 0)), .move(.init(3, -4))])
        let p = tool.applyDynamicInput([.length: 6], cursor: .init(3, -4), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, -6))
    }

    @Test("Ellipse settingRatio: no typed value falls back to the live perpendicular distance")
    func ellipseRatioNoValue() {
        // Major (10,0); cursor (3,4) → live perpendicular leg = 4 → point at (0, 4).
        let tool = drive(EllipseTool(),
                         [.click(.init(0, 0)), .click(.init(10, 0)), .move(.init(3, 4))])
        let p = tool.applyDynamicInput([:], cursor: .init(3, 4), reference: .init(0, 0))
        near(p ?? .invalid, .init(0, 4))
    }

    @Test("Ellipse: nil in the foci / 4-point / inscribe / arc-angle steps, and before the center")
    func ellipseNilOtherModes() {
        // Foci + point: dragging the on-ellipse point.
        let foci = drive(EllipseTool(mode: .fociPoint),
                         [.click(.init(-3, 0)), .click(.init(3, 0)), .move(.init(0, 4))])
        #expect(foci.applyDynamicInput([.radius: 5], cursor: .init(0, 4), reference: .init(0, 0)) == nil)

        // 4-point: dragging the fourth.
        let fourP = drive(EllipseTool(mode: .fourPoint),
                          [.click(.init(5, 0)), .click(.init(0, 3)),
                           .click(.init(-5, 0)), .move(.init(0, -3))])
        #expect(fourP.applyDynamicInput([.radius: 5], cursor: .init(0, -3), reference: .init(0, 0)) == nil)

        // .arc start-angle step (settingArcStart) — no clean editable scalar.
        let arcStart = drive(EllipseTool(mode: .arc),
                             [.click(.init(0, 0)), .click(.init(10, 0)),
                              .click(.init(0, 5)), .move(.init(10, 0))])
        #expect(arcStart.applyDynamicInput([.angle: 0], cursor: .init(10, 0), reference: .init(0, 0)) == nil)

        // nil before the center is fixed.
        #expect(EllipseTool().applyDynamicInput([.radius: 5],
                                                cursor: .init(1, 1), reference: .init(0, 0)) == nil)
    }
}
