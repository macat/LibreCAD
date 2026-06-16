//
//  SplineEditToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Spline-Edit tool PURELY (no GUI): picks (or adopts) a
//  spline, then MOVES / ADDS / REMOVES a defining point, and asserts the single
//  `.replace(id, newKind)` commit shape and the resulting spline data — for both
//  spline kinds:
//    • `.spline` (NURBS): the editable point set is `controlPoints`; a move keeps
//      `degree`/`knots`/`weights`; an add/remove changes the count and CLEARS the
//      stale `knots` (resolve regenerates a clamped uniform vector).
//    • `.splinePoints` (fit-point spline): the editable set is the stored
//      `controlPoints` (the fit points, stored directly).
//  Assertions check the RESOLVED (tessellated) curve geometry — a moved point
//  shifts the curve toward it; an added point raises the count by one and the
//  recomputed curve passes near the added point; a removed point drops the count
//  by one. Degenerate guards (remove below the per-kind minimum, coincident move,
//  non-spline entity) are covered too.
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

@Suite("SplineEditTool modify (move/add/remove, NURBS + fit-point)")
struct SplineEditToolModifyTests {

    // MARK: - Fixtures

    private static let spID = EntityID(11)

    /// An OPEN degree-2 NURBS spline with 4 control points forming an arch:
    /// (0,0)-(10,10)-(20,10)-(30,0). Knots left empty (resolve clamps them).
    private static func nurbsSpline() -> EntityRecord {
        EntityRecord(id: spID, kind: .spline(SplineData(
            degree: 2,
            controlPoints: [
                Vector(0, 0), Vector(10, 10), Vector(20, 10), Vector(30, 0),
            ],
            closed: false
        )))
    }

    /// A RATIONAL open degree-2 NURBS spline (non-trivial weights) so weight
    /// index-alignment on add/remove is exercised.
    private static func rationalSpline() -> EntityRecord {
        EntityRecord(id: spID, kind: .spline(SplineData(
            degree: 2,
            controlPoints: [
                Vector(0, 0), Vector(10, 10), Vector(20, 10), Vector(30, 0),
            ],
            knots: [],
            weights: [1, 2, 2, 1],
            closed: false
        )))
    }

    /// An OPEN fit-point spline through 4 points: (0,0)-(10,10)-(20,10)-(30,0).
    private static func fitSpline() -> EntityRecord {
        EntityRecord(id: spID, kind: .splinePoints(SplinePointsData(
            controlPoints: [
                Vector(0, 0), Vector(10, 10), Vector(20, 10), Vector(30, 0),
            ],
            closed: false
        )))
    }

    /// A LINE (non-spline) entity, to prove the tool is inert on it.
    private static func line() -> EntityRecord {
        EntityRecord(id: EntityID(99), kind: .line(LineData(start: Vector(0, 0), end: Vector(50, 0))))
    }

    /// A context that resolves ids and finds entities near a pick (visible only).
    private static func context(over records: [EntityRecord], selected: [EntityRecord] = []) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(
            selected: selected,
            entity: { byID[$0] },
            gridSpacing: nil,
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

    // MARK: - Commit extraction helpers

    /// Pulls the single `.replace`'s new `SplineData` out of a `.commit`, or `nil`.
    private func replacedNURBS(_ outcome: ToolOutcome) -> (id: EntityID, data: SplineData)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0],
              case .spline(let d) = kind else { return nil }
        return (id, d)
    }

    /// Pulls the single `.replace`'s new `SplinePointsData` out of a `.commit`.
    private func replacedFit(_ outcome: ToolOutcome) -> (id: EntityID, data: SplinePointsData)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0],
              case .splinePoints(let d) = kind else { return nil }
        return (id, d)
    }

    /// Resolves an entity kind to its single tessellated polyline's points.
    private func resolvedPoints(_ kind: EntityKind) -> [Vector] {
        kind.resolve(pen: .toolPreview, ctx: .default).polylines.first?.points ?? []
    }

    /// The closest distance from any tessellated point of `kind` to `p`.
    private func curveDistance(_ kind: EntityKind, to p: Vector) -> Double {
        let pts = resolvedPoints(kind)
        guard !pts.isEmpty else { return .greatestFiniteMagnitude }
        return pts.map { $0.distance(to: p) }.min() ?? .greatestFiniteMagnitude
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    // MARK: - Targeting: pick & adopt

    @Test("First click on the spline targets it (NURBS); a later move-grab + move commits a .replace")
    func picksNURBSByClick() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let sp = Self.nurbsSpline()
        let ctx = Self.context(over: [sp])
        // Pick the spline by clicking near an endpoint (which the curve interpolates).
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        // Grab the nearest control point (the (0,0) endpoint).
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        // Move it to (-5, -5).
        let out = tool.handle(.click(Vector(-5, -5)), context: ctx)
        let r = replacedNURBS(out)
        #expect(r != nil)
        #expect(r?.id == Self.spID)
        #expect(approx(r?.data.controlPoints[0] ?? .invalid, Vector(-5, -5)))
    }

    @Test("A selected spline is adopted on activation (no separate pick)")
    func adoptsSelectedSpline() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let sp = Self.fitSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        // No pick click needed: grab the first control point directly.
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let out = tool.handle(.click(Vector(1, -3)), context: ctx)
        let r = replacedFit(out)
        #expect(r != nil)
        #expect(approx(r?.data.controlPoints[0] ?? .invalid, Vector(1, -3)))
    }

    @Test("A pick of a non-spline entity is inert (no target, no commit)")
    func inertOnNonSpline() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let ctx = Self.context(over: [Self.line()])
        let pick = tool.handle(.click(Vector(10, 0)), context: ctx)
        #expect(pick == .none)
        // A follow-up click still does nothing (still no target).
        let again = tool.handle(.click(Vector(20, 0)), context: ctx)
        #expect(again == .none)
    }

    // MARK: - MOVE — NURBS control point

    @Test("Moving a NURBS control point shifts the resolved curve toward the new spot, keeping degree/weights")
    func moveNURBSControlPoint() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let sp = Self.rationalSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        let before = resolvedPoints(sp.kind)

        // Grab the interior control point at (10,10) and pull it far up to (10,40).
        _ = tool.handle(.click(Vector(10, 10)), context: ctx)
        let out = tool.handle(.click(Vector(10, 40)), context: ctx)
        let r = replacedNURBS(out)
        #expect(r != nil)

        let d = r!.data
        // Degree, count, and weights are preserved by a pure move.
        #expect(d.degree == 2)
        #expect(d.controlPoints.count == 4)
        #expect(d.weights == [1, 2, 2, 1])
        #expect(approx(d.controlPoints[1], Vector(10, 40)))

        // The resolved curve actually changed and now reaches higher (pulled up).
        let after = resolvedPoints(.spline(d))
        let maxYBefore = before.map(\.y).max() ?? 0
        let maxYAfter = after.map(\.y).max() ?? 0
        #expect(maxYAfter > maxYBefore + 1.0)
    }

    @Test("Moving a NURBS endpoint moves the curve endpoint (interpolated)")
    func moveNURBSEndpoint() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let sp = Self.nurbsSpline()
        let ctx = Self.context(over: [sp], selected: [sp])

        _ = tool.handle(.click(Vector(30, 0)), context: ctx)   // grab last ctrl pt
        let out = tool.handle(.value(Vector(40, -10)), context: ctx)  // typed dest
        let r = replacedNURBS(out)
        #expect(r != nil)
        // A clamped NURBS interpolates its endpoints, so the curve now ends at the
        // moved control point.
        #expect(curveDistance(.spline(r!.data), to: Vector(40, -10)) < 1e-6)
    }

    // MARK: - MOVE — fit-point spline

    @Test("Moving a fit point shifts the resolved fit-spline toward the new spot")
    func moveFitPoint() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let sp = Self.fitSpline()
        let ctx = Self.context(over: [sp], selected: [sp])

        _ = tool.handle(.click(Vector(20, 10)), context: ctx)   // grab 3rd fit pt
        let out = tool.handle(.click(Vector(20, 30)), context: ctx)
        let r = replacedFit(out)
        #expect(r != nil)
        #expect(r?.data.controlPoints.count == 4)
        #expect(approx(r?.data.controlPoints[2] ?? .invalid, Vector(20, 30)))
        // The curve was pulled up near the moved fit point.
        let maxY = resolvedPoints(.splinePoints(r!.data)).map(\.y).max() ?? 0
        #expect(maxY > 15)
    }

    @Test("A zero-length move (destination == grabbed point) does NOT commit")
    func zeroMoveNoCommit() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        let sp = Self.fitSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        _ = tool.handle(.click(Vector(10, 10)), context: ctx)   // grab 2nd pt
        let out = tool.handle(.click(Vector(10, 10)), context: ctx)  // same spot
        if case .commit = out { Issue.record("zero move should not commit") }
        #expect(out == .preview)
    }

    // MARK: - ADD — point count +1, curve passes near the added point

    @Test("Adding a NURBS control point raises the count by one, clears stale knots, and the curve passes near it")
    func addNURBSControlPoint() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .add)
        // Seed a NURBS that carries an explicit clamped knot vector so we can prove
        // it is cleared on add.
        let withKnots = SplineData(
            degree: 2,
            controlPoints: [Vector(0, 0), Vector(10, 10), Vector(20, 10), Vector(30, 0)],
            knots: NURBS.knotVector(for: SplineData(
                degree: 2,
                controlPoints: [Vector(0, 0), Vector(10, 10), Vector(20, 10), Vector(30, 0)]
            ))!,
            closed: false
        )
        let sp = EntityRecord(id: Self.spID, kind: .spline(withKnots))
        #expect(!withKnots.knots.isEmpty)   // precondition: knots present
        let ctx = Self.context(over: [sp], selected: [sp])

        // Click between control points 1 and 2 (the (10,10)-(20,10) leg midpoint).
        let out = tool.handle(.click(Vector(15, 10)), context: ctx)
        let r = replacedNURBS(out)
        #expect(r != nil)
        #expect(r?.data.controlPoints.count == 5)        // +1
        #expect(r?.data.knots.isEmpty == true)           // stale knots cleared
        // The inserted control point sits on the clicked leg.
        #expect(approx(r?.data.controlPoints[2] ?? .invalid, Vector(15, 10)))
        // The recomputed curve still resolves (regenerated knots) and reaches the
        // raised middle (curve passes near the added point's neighborhood).
        #expect(curveDistance(.spline(r!.data), to: Vector(15, 10)) < 5)
    }

    @Test("Adding to a rational NURBS keeps weights length-aligned (inserts weight 1)")
    func addRationalKeepsWeights() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .add)
        let sp = Self.rationalSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        let out = tool.handle(.click(Vector(15, 10)), context: ctx)
        let r = replacedNURBS(out)
        #expect(r != nil)
        #expect(r?.data.controlPoints.count == 5)
        #expect(r?.data.weights.count == 5)
        #expect(r?.data.weights == [1, 2, 1, 2, 1])   // weight 1 inserted at idx 2
    }

    @Test("Adding a fit point raises the count by one and the fit-spline passes near it")
    func addFitPoint() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .add)
        let sp = Self.fitSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        let out = tool.handle(.click(Vector(5, 5)), context: ctx)  // on leg 0
        let r = replacedFit(out)
        #expect(r != nil)
        #expect(r?.data.controlPoints.count == 5)
        #expect(approx(r?.data.controlPoints[1] ?? .invalid, Vector(5, 5)))
        // The fit-point curve interpolates its points smoothly, so it runs near it.
        #expect(curveDistance(.splinePoints(r!.data), to: Vector(5, 5)) < 5)
    }

    // MARK: - REMOVE — point count −1, with min-count guards

    @Test("Removing a fit point drops the count by one")
    func removeFitPoint() {
        var tool = SplineEditTool(pickTolerance: 2, mode: .remove)
        let sp = Self.fitSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        let out = tool.handle(.click(Vector(20, 10)), context: ctx)  // on the 3rd pt
        let r = replacedFit(out)
        #expect(r != nil)
        #expect(r?.data.controlPoints.count == 3)
        // The removed point is gone.
        #expect(!(r?.data.controlPoints.contains { approx($0, Vector(20, 10)) } ?? true))
    }

    @Test("Removing a NURBS control point drops the count by one and clears stale knots")
    func removeNURBSControlPoint() {
        var tool = SplineEditTool(pickTolerance: 2, mode: .remove)
        // Degree-2 with 5 control points so removal stays above the minimum (3).
        let d5 = SplineData(
            degree: 2,
            controlPoints: [
                Vector(0, 0), Vector(10, 10), Vector(20, 10), Vector(30, 10), Vector(40, 0),
            ],
            closed: false
        )
        let sp = EntityRecord(id: Self.spID, kind: .spline(d5))
        let ctx = Self.context(over: [sp], selected: [sp])
        let out = tool.handle(.click(Vector(20, 10)), context: ctx)  // middle ctrl pt
        let r = replacedNURBS(out)
        #expect(r != nil)
        #expect(r?.data.controlPoints.count == 4)
        #expect(r?.data.knots.isEmpty == true)
    }

    @Test("Removing below the NURBS minimum (degree+1 control points) is refused")
    func removeBelowNURBSMinRefused() {
        var tool = SplineEditTool(pickTolerance: 2, mode: .remove)
        // Degree-2 with exactly 3 control points: the minimum — any remove refused.
        let dMin = SplineData(
            degree: 2,
            controlPoints: [Vector(0, 0), Vector(10, 10), Vector(20, 0)],
            closed: false
        )
        let sp = EntityRecord(id: Self.spID, kind: .spline(dMin))
        let ctx = Self.context(over: [sp], selected: [sp])
        let out = tool.handle(.click(Vector(10, 10)), context: ctx)
        if case .commit = out { Issue.record("removing below the NURBS minimum must not commit") }
    }

    @Test("Removing below 2 fit points is refused")
    func removeBelowFitMinRefused() {
        var tool = SplineEditTool(pickTolerance: 2, mode: .remove)
        let d2 = SplinePointsData(controlPoints: [Vector(0, 0), Vector(10, 10)], closed: false)
        let sp = EntityRecord(id: Self.spID, kind: .splinePoints(d2))
        let ctx = Self.context(over: [sp], selected: [sp])
        let out = tool.handle(.click(Vector(0, 0)), context: ctx)
        if case .commit = out { Issue.record("removing below 2 fit points must not commit") }
    }

    @Test("A remove click NOT on any defining point (outside aperture) is a no-op")
    func removeMissNoCommit() {
        var tool = SplineEditTool(pickTolerance: 1, mode: .remove)
        let sp = Self.fitSpline()
        let ctx = Self.context(over: [sp], selected: [sp])
        // Far from every fit point.
        let out = tool.handle(.click(Vector(100, 100)), context: ctx)
        if case .commit = out { Issue.record("a remove miss must not commit") }
    }

    // MARK: - Closed flag preserved

    @Test("Editing preserves the closed flag (NURBS + fit)")
    func preservesClosed() {
        // Closed fit spline.
        var fitTool = SplineEditTool(pickTolerance: 5, mode: .move)
        let closedFit = EntityRecord(id: Self.spID, kind: .splinePoints(SplinePointsData(
            controlPoints: [Vector(0, 0), Vector(10, 10), Vector(20, 0), Vector(10, -10)],
            closed: true
        )))
        let fctx = Self.context(over: [closedFit], selected: [closedFit])
        _ = fitTool.handle(.click(Vector(0, 0)), context: fctx)
        let fout = fitTool.handle(.click(Vector(-5, 0)), context: fctx)
        #expect(replacedFit(fout)?.data.closed == true)

        // Closed NURBS.
        var nTool = SplineEditTool(pickTolerance: 5, mode: .move)
        let closedNurbs = EntityRecord(id: Self.spID, kind: .spline(SplineData(
            degree: 2,
            controlPoints: [Vector(0, 0), Vector(10, 10), Vector(20, 0), Vector(10, -10)],
            closed: true
        )))
        let nctx = Self.context(over: [closedNurbs], selected: [closedNurbs])
        _ = nTool.handle(.click(Vector(0, 0)), context: nctx)
        let nout = nTool.handle(.click(Vector(-5, 0)), context: nctx)
        #expect(replacedNURBS(nout)?.data.closed == true)
    }

    // MARK: - Record attribute preservation

    @Test("Editing preserves the record's layer / pen / flags / id via .replace")
    func preservesRecordAttributes() {
        var tool = SplineEditTool(pickTolerance: 5, mode: .move)
        var sp = Self.fitSpline()
        sp.layer = LayerID("walls")
        sp.pen = Pen(lineColor: .explicit(RGBAColor(1, 0, 0)), lineType: .dashed, lineWidth: .default)
        let ctx = Self.context(over: [sp], selected: [sp])
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let out = tool.handle(.click(Vector(2, 2)), context: ctx)
        // .replace carries only id + new kind; the app preserves layer/pen/flags.
        // Assert the commit shape and that the id is the original.
        guard case .commit(let edits) = out, case .replace(let id, _) = edits[0] else {
            Issue.record("expected a .replace commit"); return
        }
        #expect(id == Self.spID)
    }

    // MARK: - Pure-helper unit checks (no state machine)

    @Test("movePoint helper rejects out-of-range and non-spline kinds")
    func movePointHelperGuards() {
        let nurbs = EntityKind.spline(SplineData(degree: 2,
            controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0)]))
        #expect(SplineEditTool.movePoint(nurbs, index: -1, to: Vector(5, 5)) == nil)
        #expect(SplineEditTool.movePoint(nurbs, index: 3, to: Vector(5, 5)) == nil)
        #expect(SplineEditTool.movePoint(.line(LineData(start: .init(0, 0), end: .init(1, 1))),
                                         index: 0, to: Vector(5, 5)) == nil)
    }

    @Test("definingPoints helper returns the control polygon / fit points and empty for others")
    func definingPointsHelper() {
        let cps = [Vector(0, 0), Vector(1, 1), Vector(2, 0)]
        #expect(SplineEditTool.definingPoints(.spline(SplineData(degree: 2, controlPoints: cps))) == cps)
        #expect(SplineEditTool.definingPoints(.splinePoints(SplinePointsData(controlPoints: cps))) == cps)
        #expect(SplineEditTool.definingPoints(.line(LineData(start: .init(0, 0), end: .init(1, 1)))).isEmpty)
    }
}
