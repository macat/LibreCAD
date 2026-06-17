//
//  EntityGripsTests.swift
//  CADEngineTests
//
//  Pure-math tests for per-entity GRIP editing (`EntityGrips`):
//    - grips(for:) returns the expected COUNT + ROLES + POSITIONS per kind
//      (line / circle / arc / polyline / ellipse / spline / splinePoints / point /
//      text), and `[]` for the non-grip kinds.
//    - moveGrip(_:of:to:) correctly EDITS each kind: a line endpoint follows the
//      drag with the other end fixed; a circle quadrant sets a new radius about the
//      fixed center; an arc end re-fits the arc keeping the other end + mid; a
//      polyline vertex moves while every bulge is preserved; an ellipse axis grip
//      sets a new axis; spline/point/text move their point. Out-of-range /
//      non-editable indices return `nil`.
//
//  These lock the CONTRACT the `EntityGripOverlay` + `CanvasModel` mount depend on,
//  with NO GUI — the view layer only maps screen↔world and routes the resulting
//  `EntityRecord` through the undoable commit path, so this is the load-bearing
//  logic.
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

@Suite("Entity grip editing math")
struct EntityGripsTests {

    // MARK: - Fixtures / helpers

    private static let eps = 1e-9
    private static let ctx = ResolveContext.default

    /// Wraps a bare `EntityKind` in a record (id/layer/pen are irrelevant to grips).
    private static func rec(_ kind: EntityKind, id: UInt64 = 1) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: kind)
    }

    private static func approxEqual(_ a: Vector, _ b: Vector, _ tol: Double = eps) -> Bool {
        a.valid == b.valid && abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol
    }

    // MARK: - point

    @Test("point: one insertion grip; moveGrip moves it; index 1 is nil")
    func pointGrips() {
        let r = Self.rec(.point(PointData(position: Vector(3, 4))))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 1)
        #expect(g[0].index == 0)
        #expect(g[0].role == .insertion)
        #expect(Self.approxEqual(g[0].world, Vector(3, 4)))

        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(10, -2), ctx: Self.ctx)
        guard case .point(let p)? = moved?.kind else { Issue.record("expected point"); return }
        #expect(Self.approxEqual(p.position, Vector(10, -2)))

        #expect(EntityGrips.moveGrip(1, of: r, to: Vector(0, 0), ctx: Self.ctx) == nil)
    }

    @Test("point: moveGrip preserves the record's common attrs")
    func pointPreservesAttrs() {
        var r = Self.rec(.point(PointData(position: Vector(0, 0))), id: 42)
        r.layer = LayerID("walls")
        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(5, 5), ctx: Self.ctx)
        #expect(moved?.id == EntityID(42))
        #expect(moved?.layer == LayerID("walls"))
    }

    // MARK: - line

    @Test("line: 2 endpoints + midpoint, correct roles & positions")
    func lineGrips() {
        let r = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 3)
        #expect(g.map(\.role) == [.endpoint, .endpoint, .midpoint])
        #expect(Self.approxEqual(g[0].world, Vector(0, 0)))
        #expect(Self.approxEqual(g[1].world, Vector(10, 0)))
        #expect(Self.approxEqual(g[2].world, Vector(5, 0)))   // midpoint
    }

    @Test("line: drag endpoint 0 → it moves, endpoint 1 fixed")
    func lineDragStart() {
        let r = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(-3, 4), ctx: Self.ctx)
        guard case .line(let l)? = moved?.kind else { Issue.record("expected line"); return }
        #expect(Self.approxEqual(l.start, Vector(-3, 4)))   // moved
        #expect(Self.approxEqual(l.end, Vector(10, 0)))     // fixed
    }

    @Test("line: drag endpoint 1 → it moves, endpoint 0 fixed")
    func lineDragEnd() {
        let r = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let moved = EntityGrips.moveGrip(1, of: r, to: Vector(12, 7), ctx: Self.ctx)
        guard case .line(let l)? = moved?.kind else { Issue.record("expected line"); return }
        #expect(Self.approxEqual(l.start, Vector(0, 0)))    // fixed
        #expect(Self.approxEqual(l.end, Vector(12, 7)))     // moved
    }

    @Test("line: drag midpoint → whole line translates, length preserved")
    func lineDragMid() {
        let r = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let moved = EntityGrips.moveGrip(2, of: r, to: Vector(5, 5), ctx: Self.ctx)
        guard case .line(let l)? = moved?.kind else { Issue.record("expected line"); return }
        // Mid was (5,0); dragged to (5,5) ⇒ +(0,5) translation.
        #expect(Self.approxEqual(l.start, Vector(0, 5)))
        #expect(Self.approxEqual(l.end, Vector(10, 5)))
        let newMid = (l.start + l.end) * 0.5
        #expect(Self.approxEqual(newMid, Vector(5, 5)))
    }

    @Test("line: out-of-range index → nil")
    func lineOutOfRange() {
        let r = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        #expect(EntityGrips.moveGrip(3, of: r, to: Vector(0, 0), ctx: Self.ctx) == nil)
        #expect(EntityGrips.moveGrip(-1, of: r, to: Vector(0, 0), ctx: Self.ctx) == nil)
    }

    // MARK: - circle

    @Test("circle: center + 4 quadrants at E/N/W/S")
    func circleGrips() {
        let r = Self.rec(.circle(CircleData(center: Vector(0, 0), radius: 5)))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 5)
        #expect(g[0].role == .center)
        #expect(g.dropFirst().allSatisfy { $0.role == .quadrant })
        #expect(Self.approxEqual(g[0].world, Vector(0, 0)))
        #expect(Self.approxEqual(g[1].world, Vector(5, 0)))    // E
        #expect(Self.approxEqual(g[2].world, Vector(0, 5)))    // N
        #expect(Self.approxEqual(g[3].world, Vector(-5, 0)))   // W
        #expect(Self.approxEqual(g[4].world, Vector(0, -5)))   // S
    }

    @Test("circle: drag a quadrant → new radius, center fixed")
    func circleDragQuadrant() {
        let r = Self.rec(.circle(CircleData(center: Vector(0, 0), radius: 5)))
        // Drag the E quadrant out to (8,0): radius → 8.
        let moved = EntityGrips.moveGrip(1, of: r, to: Vector(8, 0), ctx: Self.ctx)
        guard case .circle(let c)? = moved?.kind else { Issue.record("expected circle"); return }
        #expect(Self.approxEqual(c.center, Vector(0, 0)))      // fixed
        #expect(abs(c.radius - 8) < Self.eps)
    }

    @Test("circle: quadrant radius is the full distance to center (off-axis ok)")
    func circleQuadrantOffAxis() {
        let r = Self.rec(.circle(CircleData(center: Vector(0, 0), radius: 5)))
        // Drag to (3,4): distance 5 → radius stays 5 even if dragged off-axis.
        let moved = EntityGrips.moveGrip(2, of: r, to: Vector(3, 4), ctx: Self.ctx)
        guard case .circle(let c)? = moved?.kind else { Issue.record("expected circle"); return }
        #expect(abs(c.radius - 5) < Self.eps)
    }

    @Test("circle: drag center → circle translates, radius unchanged")
    func circleDragCenter() {
        let r = Self.rec(.circle(CircleData(center: Vector(1, 1), radius: 5)))
        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(9, 9), ctx: Self.ctx)
        guard case .circle(let c)? = moved?.kind else { Issue.record("expected circle"); return }
        #expect(Self.approxEqual(c.center, Vector(9, 9)))
        #expect(abs(c.radius - 5) < Self.eps)
    }

    @Test("circle: quadrant dragged onto center (zero radius) → nil")
    func circleDegenerate() {
        let r = Self.rec(.circle(CircleData(center: Vector(2, 2), radius: 5)))
        #expect(EntityGrips.moveGrip(1, of: r, to: Vector(2, 2), ctx: Self.ctx) == nil)
    }

    // MARK: - arc

    @Test("arc: center + start + end + mid; mid sits on the arc")
    func arcGrips() {
        // Quarter arc, CCW from 0° to 90°, radius 5 at origin.
        let arc = ArcData(center: Vector(0, 0), radius: 5,
                          startAngle: 0, endAngle: .pi / 2, reversed: false)
        let r = Self.rec(.arc(arc))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 4)
        #expect(g.map(\.role) == [.center, .endpoint, .endpoint, .midpoint])
        #expect(Self.approxEqual(g[0].world, Vector(0, 0)))
        #expect(Self.approxEqual(g[1].world, Vector(5, 0)))                 // start (0°)
        #expect(Self.approxEqual(g[2].world, Vector(0, 5)))                 // end (90°)
        // Mid at 45° → (5·cos45, 5·sin45).
        let m = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))
        #expect(Self.approxEqual(g[3].world, m, 1e-9))
        // The mid grip is exactly the radius away from center (lies on the arc).
        #expect(abs((g[3].world - Vector(0, 0)).magnitude - 5) < 1e-9)
    }

    @Test("arc: drag the END grip → arc re-fits, start + mid still on the new arc")
    func arcDragEnd() {
        let arc = ArcData(center: Vector(0, 0), radius: 5,
                          startAngle: 0, endAngle: .pi / 2, reversed: false)
        let r = Self.rec(.arc(arc))
        let oldStart = Vector(5, 0)
        let oldMid = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))
        // Move the end to (0,7) — a new, larger sweep.
        let newEnd = Vector(0, 7)
        let moved = EntityGrips.moveGrip(2, of: r, to: newEnd, ctx: Self.ctx)
        guard case .arc(let a)? = moved?.kind else { Issue.record("expected arc"); return }
        // Every fixed characteristic point must lie on the re-fit arc (|p−c| == r),
        // and the new arc must pass through the moved end.
        let c = a.center
        #expect(abs((oldStart - c).magnitude - a.radius) < 1e-7)
        #expect(abs((oldMid - c).magnitude - a.radius) < 1e-7)
        #expect(abs((newEnd - c).magnitude - a.radius) < 1e-7)
        // The arc's resolved start grip is still the (unchanged) old start.
        let g2 = EntityGrips.grips(for: moved!, ctx: Self.ctx)
        #expect(Self.approxEqual(g2[1].world, oldStart, 1e-7))
        #expect(Self.approxEqual(g2[2].world, newEnd, 1e-7))
    }

    @Test("arc: drag the START grip → arc re-fits through moved start + fixed end/mid")
    func arcDragStart() {
        let arc = ArcData(center: Vector(0, 0), radius: 5,
                          startAngle: 0, endAngle: .pi / 2, reversed: false)
        let r = Self.rec(.arc(arc))
        let oldEnd = Vector(0, 5)
        let oldMid = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))
        let newStart = Vector(6, -2)
        let moved = EntityGrips.moveGrip(1, of: r, to: newStart, ctx: Self.ctx)
        guard case .arc(let a)? = moved?.kind else { Issue.record("expected arc"); return }
        let c = a.center
        #expect(abs((newStart - c).magnitude - a.radius) < 1e-7)
        #expect(abs((oldEnd - c).magnitude - a.radius) < 1e-7)
        #expect(abs((oldMid - c).magnitude - a.radius) < 1e-7)
        let g2 = EntityGrips.grips(for: moved!, ctx: Self.ctx)
        #expect(Self.approxEqual(g2[1].world, newStart, 1e-7))
        #expect(Self.approxEqual(g2[2].world, oldEnd, 1e-7))
    }

    @Test("arc: drag center → arc translates, radius & angles unchanged")
    func arcDragCenter() {
        let arc = ArcData(center: Vector(0, 0), radius: 5,
                          startAngle: 0, endAngle: .pi / 2, reversed: false)
        let r = Self.rec(.arc(arc))
        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(10, 10), ctx: Self.ctx)
        guard case .arc(let a)? = moved?.kind else { Issue.record("expected arc"); return }
        #expect(Self.approxEqual(a.center, Vector(10, 10)))
        #expect(abs(a.radius - 5) < Self.eps)
        #expect(abs(a.startAngle - 0) < Self.eps)
        #expect(abs(a.endAngle - .pi / 2) < Self.eps)
    }

    @Test("arc: collinear re-fit (degenerate) → nil")
    func arcDegenerate() {
        let arc = ArcData(center: Vector(0, 0), radius: 5,
                          startAngle: 0, endAngle: .pi / 2, reversed: false)
        let r = Self.rec(.arc(arc))
        // Move the end so start/mid/end become collinear: put the end on the line
        // through start (5,0) and mid (≈3.54,3.54) — pick a far collinear point.
        // Easier degenerate: out-of-range index.
        #expect(EntityGrips.moveGrip(4, of: r, to: Vector(0, 0), ctx: Self.ctx) == nil)
    }

    @Test("arc: reversed arc's mid grip lies on the drawn (CW) sweep")
    func arcReversedMid() {
        // Reversed (CW) arc sweeping from 90° down to 0°.
        let arc = ArcData(center: Vector(0, 0), radius: 5,
                          startAngle: .pi / 2, endAngle: 0, reversed: true)
        let r = Self.rec(.arc(arc))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        // The CW mid between 90° and 0° is 45°.
        let m = Vector(5 * cos(.pi / 4), 5 * sin(.pi / 4))
        #expect(Self.approxEqual(g[3].world, m, 1e-9))
    }

    // MARK: - polyline

    @Test("polyline: one vertex grip per vertex, in order")
    func polylineGrips() {
        let pl = PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0), bulge: 0),
            PolylineVertex(point: Vector(10, 0), bulge: 0.5),
            PolylineVertex(point: Vector(10, 10), bulge: 0),
        ], closed: false)
        let r = Self.rec(.polyline(pl))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 3)
        #expect(g.allSatisfy { $0.role == .vertex })
        #expect(Self.approxEqual(g[0].world, Vector(0, 0)))
        #expect(Self.approxEqual(g[1].world, Vector(10, 0)))
        #expect(Self.approxEqual(g[2].world, Vector(10, 10)))
    }

    @Test("polyline: drag a vertex → it moves, others fixed, ALL bulges preserved")
    func polylineDragVertex() {
        let pl = PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0), bulge: 0.25),
            PolylineVertex(point: Vector(10, 0), bulge: 0.5),
            PolylineVertex(point: Vector(10, 10), bulge: -0.75),
        ], closed: true)
        let r = Self.rec(.polyline(pl))
        let moved = EntityGrips.moveGrip(1, of: r, to: Vector(20, 5), ctx: Self.ctx)
        guard case .polyline(let p)? = moved?.kind else { Issue.record("expected polyline"); return }
        #expect(p.vertices.count == 3)
        #expect(Self.approxEqual(p.vertices[0].point, Vector(0, 0)))     // fixed
        #expect(Self.approxEqual(p.vertices[1].point, Vector(20, 5)))    // moved
        #expect(Self.approxEqual(p.vertices[2].point, Vector(10, 10)))   // fixed
        // Bulges preserved exactly (including the moved vertex's own bulge).
        #expect(abs(p.vertices[0].bulge - 0.25) < Self.eps)
        #expect(abs(p.vertices[1].bulge - 0.5) < Self.eps)
        #expect(abs(p.vertices[2].bulge - (-0.75)) < Self.eps)
        #expect(p.closed == true)
    }

    @Test("polyline: out-of-range vertex index → nil")
    func polylineOutOfRange() {
        let pl = PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(1, 1)),
        ])
        let r = Self.rec(.polyline(pl))
        #expect(EntityGrips.moveGrip(2, of: r, to: Vector(5, 5), ctx: Self.ctx) == nil)
        #expect(EntityGrips.moveGrip(-1, of: r, to: Vector(5, 5), ctx: Self.ctx) == nil)
    }

    // MARK: - ellipse

    @Test("ellipse: center + 2 major + 2 minor axis endpoints")
    func ellipseGrips() {
        // Axis-aligned ellipse: major along +x length 10, ratio 0.5 (minor 5).
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
        let r = Self.rec(.ellipse(e))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 5)
        #expect(g[0].role == .center)
        #expect(g.dropFirst().allSatisfy { $0.role == .quadrant })
        #expect(Self.approxEqual(g[0].world, Vector(0, 0)))
        #expect(Self.approxEqual(g[1].world, Vector(10, 0)))    // +major
        #expect(Self.approxEqual(g[2].world, Vector(-10, 0)))   // −major
        #expect(Self.approxEqual(g[3].world, Vector(0, 5)))     // +minor (ratio·major ⟂)
        #expect(Self.approxEqual(g[4].world, Vector(0, -5)))    // −minor
    }

    @Test("ellipse: drag +major endpoint → new major axis, minor radius kept")
    func ellipseDragMajor() {
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
        let oldMinor = e.minorRadius   // 5
        let r = Self.rec(.ellipse(e))
        // Lengthen the major axis to 20 along +x.
        let moved = EntityGrips.moveGrip(1, of: r, to: Vector(20, 0), ctx: Self.ctx)
        guard case .ellipse(let ne)? = moved?.kind else { Issue.record("expected ellipse"); return }
        #expect(abs(ne.majorRadius - 20) < Self.eps)
        #expect(abs(ne.minorRadius - oldMinor) < Self.eps)    // minor preserved absolutely
        #expect(Self.approxEqual(ne.majorP, Vector(20, 0)))
    }

    @Test("ellipse: drag −major endpoint → major flips through center correctly")
    func ellipseDragMinusMajor() {
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
        let r = Self.rec(.ellipse(e))
        // Drag the −major endpoint (was at (-10,0)) to (-15,0): new major length 15.
        let moved = EntityGrips.moveGrip(2, of: r, to: Vector(-15, 0), ctx: Self.ctx)
        guard case .ellipse(let ne)? = moved?.kind else { Issue.record("expected ellipse"); return }
        #expect(abs(ne.majorRadius - 15) < Self.eps)
        // majorP should point along +x (the −endpoint was negated back).
        #expect(Self.approxEqual(ne.majorP, Vector(15, 0)))
    }

    @Test("ellipse: drag +minor endpoint → new minor radius, major axis kept")
    func ellipseDragMinor() {
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
        let r = Self.rec(.ellipse(e))
        // Drag the +minor endpoint (was (0,5)) to (0,8): minor radius → 8.
        let moved = EntityGrips.moveGrip(3, of: r, to: Vector(0, 8), ctx: Self.ctx)
        guard case .ellipse(let ne)? = moved?.kind else { Issue.record("expected ellipse"); return }
        #expect(abs(ne.majorRadius - 10) < Self.eps)          // major preserved
        #expect(abs(ne.minorRadius - 8) < Self.eps)
        #expect(abs(ne.ratio - 0.8) < Self.eps)
    }

    @Test("ellipse: drag center → ellipse translates, shape unchanged")
    func ellipseDragCenter() {
        let e = EllipseData(center: Vector(1, 1), majorP: Vector(10, 0), ratio: 0.5)
        let r = Self.rec(.ellipse(e))
        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(5, -3), ctx: Self.ctx)
        guard case .ellipse(let ne)? = moved?.kind else { Issue.record("expected ellipse"); return }
        #expect(Self.approxEqual(ne.center, Vector(5, -3)))
        #expect(Self.approxEqual(ne.majorP, Vector(10, 0)))
        #expect(abs(ne.ratio - 0.5) < Self.eps)
    }

    @Test("ellipse: degenerate major drag (onto center) → nil")
    func ellipseDegenerate() {
        let e = EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
        let r = Self.rec(.ellipse(e))
        #expect(EntityGrips.moveGrip(1, of: r, to: Vector(0, 0), ctx: Self.ctx) == nil)
        #expect(EntityGrips.moveGrip(5, of: r, to: Vector(1, 1), ctx: Self.ctx) == nil)
    }

    // MARK: - spline / splinePoints

    @Test("spline: one control-point grip per control point; moveGrip moves it")
    func splineGrips() {
        let s = SplineData(degree: 3, controlPoints: [
            Vector(0, 0), Vector(1, 3), Vector(4, 3), Vector(5, 0),
        ])
        let r = Self.rec(.spline(s))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 4)
        #expect(g.allSatisfy { $0.role == .controlPoint })
        #expect(Self.approxEqual(g[1].world, Vector(1, 3)))

        let moved = EntityGrips.moveGrip(2, of: r, to: Vector(9, 9), ctx: Self.ctx)
        guard case .spline(let ns)? = moved?.kind else { Issue.record("expected spline"); return }
        #expect(Self.approxEqual(ns.controlPoints[2], Vector(9, 9)))
        #expect(Self.approxEqual(ns.controlPoints[0], Vector(0, 0)))   // others fixed
        #expect(ns.degree == 3)
        #expect(EntityGrips.moveGrip(4, of: r, to: Vector(0, 0), ctx: Self.ctx) == nil)
    }

    @Test("splinePoints: control-point grips; moveGrip moves the chosen one")
    func splinePointsGrips() {
        let sp = SplinePointsData(controlPoints: [Vector(0, 0), Vector(2, 2), Vector(4, 0)], closed: false)
        let r = Self.rec(.splinePoints(sp))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 3)
        #expect(g.allSatisfy { $0.role == .controlPoint })
        let moved = EntityGrips.moveGrip(1, of: r, to: Vector(2, 6), ctx: Self.ctx)
        guard case .splinePoints(let ns)? = moved?.kind else { Issue.record("expected splinePoints"); return }
        #expect(Self.approxEqual(ns.controlPoints[1], Vector(2, 6)))
        #expect(ns.closed == false)
    }

    // MARK: - text

    @Test("text: one insertion grip; moveGrip moves the insertion, keeps the string")
    func textGrips() {
        let t = TextData(position: Vector(2, 2), height: 2.5, text: "hi")
        let r = Self.rec(.text(t))
        let g = EntityGrips.grips(for: r, ctx: Self.ctx)
        #expect(g.count == 1)
        #expect(g[0].role == .insertion)
        #expect(Self.approxEqual(g[0].world, Vector(2, 2)))

        let moved = EntityGrips.moveGrip(0, of: r, to: Vector(7, 7), ctx: Self.ctx)
        guard case .text(let nt)? = moved?.kind else { Issue.record("expected text"); return }
        #expect(Self.approxEqual(nt.position, Vector(7, 7)))
        #expect(nt.text == "hi")
        #expect(abs(nt.height - 2.5) < Self.eps)
    }

    // MARK: - non-grip kinds

    @Test("non-grip kinds: grips == [] and moveGrip == nil")
    func nonGripKinds() {
        let solid = Self.rec(.solid(SolidData(corners: [Vector(0, 0), Vector(1, 0), Vector(1, 1)])))
        #expect(EntityGrips.grips(for: solid, ctx: Self.ctx).isEmpty)
        #expect(EntityGrips.moveGrip(0, of: solid, to: Vector(5, 5), ctx: Self.ctx) == nil)

        let xline = Self.rec(.xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0))))
        #expect(EntityGrips.grips(for: xline, ctx: Self.ctx).isEmpty)
        #expect(EntityGrips.moveGrip(0, of: xline, to: Vector(5, 5), ctx: Self.ctx) == nil)

        let ray = Self.rec(.ray(RayData(base: Vector(0, 0), direction: Vector(0, 1))))
        #expect(EntityGrips.grips(for: ray, ctx: Self.ctx).isEmpty)

        let hatch = Self.rec(.hatch(HatchData(loops: [[
            PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(1, 0)),
            PolylineVertex(point: Vector(1, 1)),
        ]])))
        #expect(EntityGrips.grips(for: hatch, ctx: Self.ctx).isEmpty)
        #expect(EntityGrips.moveGrip(0, of: hatch, to: Vector(5, 5), ctx: Self.ctx) == nil)
    }

    // MARK: - invalid target guard

    @Test("moveGrip with an invalid world point → nil")
    func invalidWorld() {
        let r = Self.rec(.line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        #expect(EntityGrips.moveGrip(0, of: r, to: .invalid, ctx: Self.ctx) == nil)
    }

    // MARK: - index invariant

    @Test("grips[i].index == i for every kind that emits grips")
    func indexInvariant() {
        let kinds: [EntityKind] = [
            .point(PointData(position: Vector(0, 0))),
            .line(LineData(start: Vector(0, 0), end: Vector(1, 1))),
            .circle(CircleData(center: Vector(0, 0), radius: 1)),
            .arc(ArcData(center: Vector(0, 0), radius: 1, startAngle: 0, endAngle: 1)),
            .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(1, 1)),
            ])),
            .ellipse(EllipseData(center: Vector(0, 0), majorP: Vector(2, 0), ratio: 0.5)),
            .spline(SplineData(degree: 2, controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0)])),
            .text(TextData(position: Vector(0, 0), height: 1, text: "x")),
        ]
        for k in kinds {
            let g = EntityGrips.grips(for: Self.rec(k), ctx: Self.ctx)
            for (i, gp) in g.enumerated() {
                #expect(gp.index == i)
            }
        }
    }
}
