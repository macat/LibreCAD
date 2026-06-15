//
//  InspectorEditorsTests.swift
//  CADEngineTests
//
//  Tests for the PURE inspector-edit transforms (`InspectorEdits`) added for the
//  REMAINING entity kinds the inline GEOMETRY editor now covers: ellipse, spline,
//  splinePoints, polyline, hatch, solid, dimension, insert, xline, ray, leader.
//  Each edit must produce the right new `EntityKind` (the kept fields untouched,
//  clamps applied, wrong-kind edits a no-op). The SwiftUI views are user-verified;
//  this covers the value math under them (which lives in the engine for exactly
//  this reason — testable without a GUI).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Ellipse field edits

@Suite("Inspector ellipse edits")
struct InspectorEllipseEditTests {

    private func sample() -> EntityKind {
        .ellipse(EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5,
                             startAngle: 0, endAngle: .pi))
    }

    @Test("center / major / ratio / angle edits keep the other fields")
    func ellipseEdits() {
        let kind = sample()

        let c = InspectorEdits.setEllipseCenter(kind, Vector(3, 4))
        guard case .ellipse(let d) = c else { Issue.record("not ellipse"); return }
        #expect(d.center == Vector(3, 4))
        #expect(d.majorP == Vector(10, 0))   // axis kept
        #expect(d.ratio == 0.5)              // ratio kept

        let m = InspectorEdits.setEllipseMajor(kind, Vector(0, 8))
        guard case .ellipse(let d2) = m else { Issue.record("not ellipse"); return }
        #expect(d2.majorP == Vector(0, 8))
        #expect(abs(d2.majorRadius - 8) < 1e-12)

        let r = InspectorEdits.setEllipseRatio(kind, 0.25)
        guard case .ellipse(let d3) = r else { Issue.record("not ellipse"); return }
        #expect(d3.ratio == 0.25)

        let s = InspectorEdits.setEllipseStartAngle(kind, .pi / 4)
        guard case .ellipse(let d4) = s else { Issue.record("not ellipse"); return }
        #expect(abs(d4.startAngle - .pi / 4) < 1e-12)
        #expect(abs(d4.endAngle - .pi) < 1e-12)   // end kept

        let e = InspectorEdits.setEllipseEndAngle(kind, .pi / 2)
        guard case .ellipse(let d5) = e else { Issue.record("not ellipse"); return }
        #expect(abs(d5.endAngle - .pi / 2) < 1e-12)
    }

    @Test("ratio clamps to a small positive minimum (never zero/negative)")
    func ratioClamp() {
        let z = InspectorEdits.setEllipseRatio(sample(), 0)
        guard case .ellipse(let d) = z else { Issue.record("not ellipse"); return }
        #expect(d.ratio == InspectorEdits.minEllipseRatio)

        let neg = InspectorEdits.setEllipseRatio(sample(), -2)
        guard case .ellipse(let d2) = neg else { Issue.record("not ellipse"); return }
        #expect(d2.ratio == InspectorEdits.minEllipseRatio)
    }

    @Test("an ellipse edit on a circle is a no-op")
    func wrongKind() {
        let circle = EntityKind.circle(CircleData(center: Vector(0, 0), radius: 5))
        #expect(InspectorEdits.setEllipseCenter(circle, Vector(1, 1)) == circle)
    }
}

// MARK: - Spline + SplinePoints field edits

@Suite("Inspector spline edits")
struct InspectorSplineEditTests {

    private func sampleSpline() -> EntityKind {
        .spline(SplineData(degree: 3, controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0)]))
    }

    @Test("closed flag + degree (clamped 1...3) edits keep the control polygon")
    func splineFlags() {
        let kind = sampleSpline()

        let closed = InspectorEdits.setSplineClosed(kind, true)
        guard case .spline(let d) = closed else { Issue.record("not spline"); return }
        #expect(d.closed)
        #expect(d.controlPoints.count == 3)   // points kept

        let hi = InspectorEdits.setSplineDegree(kind, 9)
        guard case .spline(let d2) = hi else { Issue.record("not spline"); return }
        #expect(d2.degree == 3)               // clamped down

        let lo = InspectorEdits.setSplineDegree(kind, 0)
        guard case .spline(let d3) = lo else { Issue.record("not spline"); return }
        #expect(d3.degree == 1)               // clamped up
    }

    @Test("editing a control point by index changes only that point; out-of-range is a no-op")
    func splineControlPoint() {
        let kind = sampleSpline()

        let edited = InspectorEdits.setSplineControlPoint(kind, index: 1, Vector(5, 5))
        guard case .spline(let d) = edited else { Issue.record("not spline"); return }
        #expect(d.controlPoints[1] == Vector(5, 5))
        #expect(d.controlPoints[0] == Vector(0, 0))   // others kept

        let noop = InspectorEdits.setSplineControlPoint(kind, index: 99, Vector(9, 9))
        #expect(noop == kind)                 // out-of-range unchanged
    }

    @Test("splinePoints closed flag + indexed control-point edit")
    func splinePoints() {
        let kind = EntityKind.splinePoints(
            SplinePointsData(controlPoints: [Vector(0, 0), Vector(2, 2)]))

        let closed = InspectorEdits.setSplinePointsClosed(kind, true)
        guard case .splinePoints(let d) = closed else { Issue.record("not splinePoints"); return }
        #expect(d.closed)

        let edited = InspectorEdits.setSplinePointsControlPoint(kind, index: 0, Vector(7, 8))
        guard case .splinePoints(let d2) = edited else { Issue.record("not splinePoints"); return }
        #expect(d2.controlPoints[0] == Vector(7, 8))
        #expect(d2.controlPoints[1] == Vector(2, 2))  // other kept
    }
}

// MARK: - Polyline field edits

@Suite("Inspector polyline edits")
struct InspectorPolylineEditTests {

    private func sample() -> EntityKind {
        .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0), bulge: 0.5),
            PolylineVertex(point: Vector(5, 0)),
        ], closed: false))
    }

    @Test("closed flag toggles; vertices kept")
    func closed() {
        let kind = sample()
        let c = InspectorEdits.setPolylineClosed(kind, true)
        guard case .polyline(let d) = c else { Issue.record("not polyline"); return }
        #expect(d.closed)
        #expect(d.vertices.count == 2)        // vertices kept
    }

    @Test("editing a vertex point keeps its bulge; out-of-range is a no-op")
    func vertexEdit() {
        let kind = sample()
        let v = InspectorEdits.setPolylineVertex(kind, index: 0, Vector(3, 4))
        guard case .polyline(let d) = v else { Issue.record("not polyline"); return }
        #expect(d.vertices[0].point == Vector(3, 4))
        #expect(d.vertices[0].bulge == 0.5)   // bulge preserved
        #expect(d.vertices[1].point == Vector(5, 0))

        #expect(InspectorEdits.setPolylineVertex(kind, index: 7, Vector(9, 9)) == kind)
    }
}

// MARK: - Hatch field edits

@Suite("Inspector hatch edits")
struct InspectorHatchEditTests {

    private func sample() -> EntityKind {
        .hatch(HatchData(loops: [[PolylineVertex(point: Vector(0, 0)),
                                  PolylineVertex(point: Vector(1, 0)),
                                  PolylineVertex(point: Vector(1, 1))]],
                         solidFill: true, patternName: "SOLID",
                         patternScale: 1, patternAngle: 0))
    }

    @Test("pattern name / scale / angle / solid flag edits keep the loops")
    func hatchEdits() {
        let kind = sample()

        let n = InspectorEdits.setHatchPatternName(kind, "ANSI31")
        guard case .hatch(let d) = n else { Issue.record("not hatch"); return }
        #expect(d.patternName == "ANSI31")
        #expect(d.loops.count == 1)           // loops kept

        let s = InspectorEdits.setHatchPatternScale(kind, 2.5)
        guard case .hatch(let d2) = s else { Issue.record("not hatch"); return }
        #expect(d2.patternScale == 2.5)

        let a = InspectorEdits.setHatchPatternAngle(kind, .pi / 3)
        guard case .hatch(let d3) = a else { Issue.record("not hatch"); return }
        #expect(abs(d3.patternAngle - .pi / 3) < 1e-12)

        let f = InspectorEdits.setHatchSolidFill(kind, false)
        guard case .hatch(let d4) = f else { Issue.record("not hatch"); return }
        #expect(d4.solidFill == false)

        let cleared = InspectorEdits.setHatchPatternName(kind, nil)
        guard case .hatch(let d5) = cleared else { Issue.record("not hatch"); return }
        #expect(d5.patternName == nil)
    }

    @Test("pattern scale clamps to a small positive minimum")
    func scaleClamp() {
        let z = InspectorEdits.setHatchPatternScale(sample(), 0)
        guard case .hatch(let d) = z else { Issue.record("not hatch"); return }
        #expect(d.patternScale == InspectorEdits.minHatchScale)
    }
}

// MARK: - Solid field edits

@Suite("Inspector solid edits")
struct InspectorSolidEditTests {

    @Test("editing a corner by index changes only that corner; out-of-range is a no-op")
    func cornerEdit() {
        let kind = EntityKind.solid(SolidData(corners: [
            Vector(0, 0), Vector(1, 0), Vector(1, 1), Vector(0, 1),
        ]))

        let edited = InspectorEdits.setSolidCorner(kind, index: 2, Vector(9, 9))
        guard case .solid(let d) = edited else { Issue.record("not solid"); return }
        #expect(d.corners[2] == Vector(9, 9))
        #expect(d.corners[0] == Vector(0, 0))   // others kept
        #expect(d.corners.count == 4)

        #expect(InspectorEdits.setSolidCorner(kind, index: 10, Vector(0, 0)) == kind)
    }
}

// MARK: - Dimension field edits

@Suite("Inspector dimension edits")
struct InspectorDimEditTests {

    private func sample() -> EntityKind {
        .dimension(DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5),
            styleName: "ISO-25"))
    }

    @Test("definition point + style name + text override edits keep the variant")
    func dimEdits() {
        let kind = sample()

        let p = InspectorEdits.setDimDefinitionPoint(kind, Vector(5, 8))
        guard case .dimension(let d) = p else { Issue.record("not dimension"); return }
        #expect(d.definitionPoint == Vector(5, 8))
        if case .linear(let e1, let e2, _) = d.kind {
            #expect(e1 == Vector(0, 0))       // variant points kept
            #expect(e2 == Vector(10, 0))
        } else { Issue.record("variant changed") }

        let s = InspectorEdits.setDimStyleName(kind, "MyStyle")
        guard case .dimension(let d2) = s else { Issue.record("not dimension"); return }
        #expect(d2.styleName == "MyStyle")

        let t = InspectorEdits.setDimTextOverride(kind, "≈10")
        guard case .dimension(let d3) = t else { Issue.record("not dimension"); return }
        #expect(d3.textOverride == "≈10")
    }

    @Test("an empty text override normalizes to nil (show the measured value)")
    func emptyOverride() {
        let kind = sample()
        let t = InspectorEdits.setDimTextOverride(kind, "")
        guard case .dimension(let d) = t else { Issue.record("not dimension"); return }
        #expect(d.textOverride == nil)
    }
}

// MARK: - Insert / block-reference field edits

@Suite("Inspector insert edits")
struct InspectorInsertEditTests {

    private func sample() -> EntityKind {
        .insert(InsertData(blockName: "BOLT", insertionPoint: Vector(1, 2),
                           scale: Vector(1, 1), rotation: 0))
    }

    @Test("position / scale x,y / rotation edits keep the block name")
    func insertEdits() {
        let kind = sample()

        let p = InspectorEdits.setInsertPosition(kind, Vector(7, 7))
        guard case .insert(let d) = p else { Issue.record("not insert"); return }
        #expect(d.insertionPoint == Vector(7, 7))
        #expect(d.blockName == "BOLT")        // name kept

        let sx = InspectorEdits.setInsertScaleX(kind, 2)
        guard case .insert(let d2) = sx else { Issue.record("not insert"); return }
        #expect(d2.scale.x == 2)
        #expect(d2.scale.y == 1)              // Y kept

        let sy = InspectorEdits.setInsertScaleY(kind, 3)
        guard case .insert(let d3) = sy else { Issue.record("not insert"); return }
        #expect(d3.scale.y == 3)
        #expect(d3.scale.x == 1)              // X kept

        let r = InspectorEdits.setInsertRotation(kind, .pi / 2)
        guard case .insert(let d4) = r else { Issue.record("not insert"); return }
        #expect(abs(d4.rotation - .pi / 2) < 1e-12)
    }

    @Test("a zero scale factor is ignored (the block stays visible)")
    func zeroScaleIgnored() {
        let kind = sample()
        #expect(InspectorEdits.setInsertScaleX(kind, 0) == kind)
        #expect(InspectorEdits.setInsertScaleY(kind, 0) == kind)
    }
}

// MARK: - XLine / Ray field edits

@Suite("Inspector construction-line edits")
struct InspectorConstructionLineEditTests {

    @Test("xline base + direction-by-angle edits keep the other field")
    func xline() {
        let kind = EntityKind.xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0)))

        let b = InspectorEdits.setXLineBase(kind, Vector(2, 3))
        guard case .xline(let d) = b else { Issue.record("not xline"); return }
        #expect(d.base == Vector(2, 3))

        let a = InspectorEdits.setXLineAngle(kind, .pi / 2)
        guard case .xline(let d2) = a else { Issue.record("not xline"); return }
        #expect(abs(d2.direction.angle - .pi / 2) < 1e-9)
        #expect(d2.base == Vector(0, 0))      // base kept
    }

    @Test("ray base + direction-by-angle edits keep the other field")
    func ray() {
        let kind = EntityKind.ray(RayData(base: Vector(1, 1), direction: Vector(1, 0)))

        let b = InspectorEdits.setRayBase(kind, Vector(4, 5))
        guard case .ray(let d) = b else { Issue.record("not ray"); return }
        #expect(d.base == Vector(4, 5))

        let a = InspectorEdits.setRayAngle(kind, .pi)
        guard case .ray(let d2) = a else { Issue.record("not ray"); return }
        #expect(abs(d2.direction.angle - .pi) < 1e-9)
    }
}

// MARK: - Leader field edits (vertices kept; annotation text)

@Suite("Inspector leader edits")
struct InspectorLeaderEditTests {

    private func bareLeader() -> EntityKind {
        .leader(LeaderData(vertices: [Vector(0, 0), Vector(10, 5)], hasArrow: true, arrowSize: 2.5))
    }

    @Test("arrow size / has-arrow / style edits keep the vertices")
    func leaderBasics() {
        let kind = bareLeader()

        let sz = InspectorEdits.setLeaderArrowSize(kind, 4)
        guard case .leader(let d) = sz else { Issue.record("not leader"); return }
        #expect(d.arrowSize == 4)
        #expect(d.vertices.count == 2)        // path kept

        let off = InspectorEdits.setLeaderHasArrow(kind, false)
        guard case .leader(let d2) = off else { Issue.record("not leader"); return }
        #expect(d2.hasArrow == false)

        let clampedNeg = InspectorEdits.setLeaderArrowSize(kind, -3)
        guard case .leader(let d3) = clampedNeg else { Issue.record("not leader"); return }
        #expect(d3.arrowSize == 0)            // clamped non-negative
    }

    @Test("setting text on a bare leader creates a .text annotation at the last vertex")
    func leaderTextCreate() {
        let kind = bareLeader()
        #expect(InspectorEdits.leaderText(kind) == "")   // none initially

        let withText = InspectorEdits.setLeaderText(kind, "See note 4")
        guard case .leader(let d) = withText else { Issue.record("not leader"); return }
        guard case .text(let t)? = d.annotation else { Issue.record("no text annotation"); return }
        #expect(t.text == "See note 4")
        #expect(t.position == Vector(10, 5))  // anchored at the last vertex
        #expect(InspectorEdits.leaderText(withText) == "See note 4")
    }

    @Test("editing text on a leader with an existing .text annotation replaces only the string")
    func leaderTextReplace() {
        let withText = InspectorEdits.setLeaderText(bareLeader(), "old")
        let edited = InspectorEdits.setLeaderText(withText, "new")
        guard case .leader(let d) = edited, case .text(let t)? = d.annotation else {
            Issue.record("no text annotation"); return
        }
        #expect(t.text == "new")
        #expect(t.position == Vector(10, 5))  // placement kept
    }

    @Test("setting empty text clears the annotation back to a bare leader")
    func leaderTextClear() {
        let withText = InspectorEdits.setLeaderText(bareLeader(), "x")
        let cleared = InspectorEdits.setLeaderText(withText, "")
        guard case .leader(let d) = cleared else { Issue.record("not leader"); return }
        #expect(d.annotation == nil)
        #expect(InspectorEdits.leaderText(cleared) == "")
    }
}
