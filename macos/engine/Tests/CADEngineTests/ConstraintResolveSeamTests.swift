//
//  ConstraintResolveSeamTests.swift
//  CADEngineTests
//
//  Wave 3 — the PARAMETRIC-CONSTRAINT APP SEAM. Proves the `CanvasModel` glue that
//  makes constraints actually DRIVE geometry:
//
//   • Re-solve on edit — a grip / Inspector edit of a constrained entity re-solves the
//     connected component so dependent geometry follows (parallel, distance), and a
//     re-solve that the solver can't satisfy (`.failed`) writes NOTHING (clean revert,
//     never a partial). An edit to UNCONSTRAINED geometry early-outs untouched.
//   • ONE undo step — the edit AND its re-solve collapse into a single ⌘Z (the
//     `explicitGroup` one-undo handling, the critic fix).
//   • Create path — `addConstraint` validates selection ARITY (rejecting bad
//     selections), registers the constraint undoably, and applies it IMMEDIATELY (in
//     one undo group). `removeConstraint` / `constraints(for:)` / `allConstraints`.
//   • Glyph overlay — the pure kind→glyph mapping + placement layout (read-only).
//
//  `CanvasModel` lives in the (un-importable) app target, reached here via the existing
//  `_SharedCanvasModel.swift` symlink; the glyph overlay's pure helpers via
//  `_SharedConstraintGlyphOverlay.swift`. The suite is `@MainActor` (mirroring
//  `Wave3BCanvasModelWiringTests`); no SwiftUI body / NSView is rendered — only the
//  pure model wiring + pure layout helpers.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Shared fixtures

@MainActor
private enum Fix {
    static func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }
    static func circle(_ c: Vector, _ r: Double, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .circle(CircleData(center: c, radius: r)))
    }
    static func point(_ p: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .point(PointData(position: p)))
    }

    /// A model with a clean, manually-grouped undo stack (so one explicit group == one ⌘Z).
    static func model(_ drawing: CADDrawing) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// The endpoints of the line with `id`, or `nil`.
    static func ends(_ m: CanvasModel, _ id: EntityID) -> (start: Vector, end: Vector)? {
        guard case .line(let l)? = m.drawing.entity(id)?.kind else { return nil }
        return (l.start, l.end)
    }
}

// MARK: - Re-solve on edit (the heart of the seam)

@MainActor
@Suite("Wave-3 constraint seam — re-solve on edit")
struct ConstraintResolveOnEditTests {

    /// A PARALLEL constraint pulls a coupled line parallel after an Inspector edit of
    /// the other line. Line A horizontal, line B diagonal; after rotating A via an
    /// Inspector edit, B must become parallel to A (cross product of directions ≈ 0).
    @Test("parallel constraint re-solves the coupled line after an inspector edit")
    func parallelResolvesAfterInspectorEdit() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))     // horizontal
        let b = drawing.add(Fix.line(Vector(0, 5), Vector(10, 8)))     // diagonal
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.parallel, entities: [a, b]))          // already parallel-ized

        // Now ROTATE line A (Inspector edit: change its endpoint), which should drag B
        // back parallel to the NEW A direction.
        var recA = try #require(m.drawing.entity(a))
        recA.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 10)))   // 45°
        m.applyInspectorEdits([recA])

        let ea = try #require(Fix.ends(m, a))
        let eb = try #require(Fix.ends(m, b))
        let da = (ea.end.x - ea.start.x, ea.end.y - ea.start.y)
        let db = (eb.end.x - eb.start.x, eb.end.y - eb.start.y)
        let cross = da.0 * db.1 - da.1 * db.0
        #expect(abs(cross) < 1e-6, "B should be parallel to the rotated A (cross=\(cross))")
    }

    /// A DISTANCE constraint drives the gap between two points after a grip/inspector
    /// edit moves one. Two points constrained 10 apart; moving one re-solves the other
    /// (or itself) so |p2 − p1| == 10 holds.
    @Test("distance constraint re-solves dependent geometry after a grip edit")
    func distanceResolvesAfterGripEdit() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(Fix.point(Vector(0, 0)))
        let p2 = drawing.add(Fix.point(Vector(10, 0)))
        let m = Fix.model(drawing)
        // Fix p1 so the solver moves p2; drive the distance to 10.
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], value: 10))

        // Simulate a grip edit of p2 to a point that VIOLATES the distance (too far).
        var recP2 = try #require(m.drawing.entity(p2))
        recP2.kind = .point(PointData(position: Vector(20, 0)))
        #expect(m.commitMovedGrip(recP2))   // routes through applyInspectorEdits → re-solve

        guard case .point(let q1)? = m.drawing.entity(p1)?.kind,
              case .point(let q2)? = m.drawing.entity(p2)?.kind else {
            Issue.record("points missing"); return
        }
        let dist = (q2.position - q1.position)
        let len = (dist.x * dist.x + dist.y * dist.y).squareRoot()
        #expect(abs(len - 10) < 1e-6, "distance should be driven back to 10 (got \(len))")
        #expect(q1.position == Vector(0, 0), "fixed p1 must not move")
    }

    /// An edit to UNCONSTRAINED geometry early-outs: the re-solve touches nothing and
    /// the edit is exactly the one record (no spurious geometry changes elsewhere).
    @Test("edit to unconstrained geometry early-outs (no re-solve)")
    func unconstrainedEditEarlyOut() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(Fix.line(Vector(0, 5), Vector(10, 5)))   // NOT constrained
        let m = Fix.model(drawing)
        // A constraint exists, but on a DIFFERENT entity (a), so editing b early-outs
        // on the seed filter.
        #expect(m.addConstraint(.horizontal, entities: [a]))
        let bBefore = try #require(m.drawing.entity(b))

        var recB = bBefore
        recB.kind = .line(LineData(start: Vector(0, 5), end: Vector(20, 9)))
        m.applyInspectorEdits([recB])

        // b is exactly what we set (no constraint pulled it), a is untouched.
        let bAfter = try #require(Fix.ends(m, b))
        #expect(bAfter.end == Vector(20, 9))
        #expect(Fix.ends(m, a)?.end == Vector(10, 0))   // a unchanged
    }

    /// A re-solve the solver CANNOT satisfy (`.failed`) writes NOTHING — the dependent
    /// geometry is left exactly as it was (clean revert). We inject an UNSUPPORTED
    /// constraint kind straight into the table (bypassing the model's arity gate, which
    /// would reject it) so the solver short-circuits to `.failed(.unsupported)`.
    @Test("a forced solver failure leaves geometry unchanged (revert, no partial write)")
    func failedSolveRevertsGeometry() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(Fix.line(Vector(0, 5), Vector(7, 9)))
        // An UNSUPPORTED (tangent) constraint over both → solver returns .failed.
        let bad = Constraint(kind: .geometric(.tangent),
                             points: Constraint.lineEndpoints(a) + Constraint.lineEndpoints(b))
        #expect(drawing.addConstraint(bad))
        let m = Fix.model(drawing)

        let bBefore = try #require(Fix.ends(m, b))
        // Edit a (which IS referenced by the bad constraint), triggering a re-solve that
        // fails — b must NOT move.
        var recA = try #require(m.drawing.entity(a))
        recA.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 10)))
        m.applyInspectorEdits([recA])

        let bAfter = try #require(Fix.ends(m, b))
        #expect(bAfter.start == bBefore.start && bAfter.end == bBefore.end,
                "a failed solve must leave the dependent geometry untouched")
        // The edit to a itself still landed (only the dependent re-solve was reverted).
        #expect(Fix.ends(m, a)?.end == Vector(10, 10))
    }
}

// MARK: - One undo step (the critic fix)

@MainActor
@Suite("Wave-3 constraint seam — single-undo coalescing")
struct ConstraintResolveUndoTests {

    /// ONE ⌘Z reverts BOTH the user edit AND the re-solve it triggered. We FIX line A
    /// (so the solver can only move B) and add a parallel A‖B; then rotate A via an
    /// Inspector edit — B follows. A single undo must restore A's pre-edit geometry AND
    /// B's pre-re-solve geometry together. We `removeAllActions` after setup so only the
    /// edit's group is on the stack, making the "one step" assertion exact.
    @Test("one undo reverts the edit AND the re-solve together")
    func oneUndoRevertsEditAndResolve() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(Fix.line(Vector(0, 5), Vector(10, 5)))   // parallel already
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))      // anchor A so only B moves
        #expect(m.addConstraint(.parallel, entities: [a, b]))

        let aBefore = try #require(Fix.ends(m, a))
        let bBefore = try #require(Fix.ends(m, b))
        // Make the edit the ONLY undo step on the stack (drop the two add groups).
        m.undoManager.removeAllActions()

        // Rotate A (its FIXED endpoints are re-pinned at the new positions by the edit
        // itself; the solver then drags B parallel to the new A direction).
        var recA = try #require(m.drawing.entity(a))
        recA.kind = .line(LineData(start: Vector(0, 0), end: Vector(10, 10)))
        m.applyInspectorEdits([recA])
        #expect(Fix.ends(m, a)?.end == Vector(10, 10))     // A's edit stands (A is fixed)
        // B moved to become parallel to the 45° A.
        let bAfterEdit = try #require(Fix.ends(m, b))
        #expect(bAfterEdit.end != bBefore.end, "B should have been re-solved (moved)")
        let da = (10.0 - 0.0, 10.0 - 0.0)
        let db = (bAfterEdit.end.x - bAfterEdit.start.x, bAfterEdit.end.y - bAfterEdit.start.y)
        #expect(abs(da.0 * db.1 - da.1 * db.0) < 1e-6, "B parallel to A after re-solve")

        // A SINGLE undo must revert BOTH A and B.
        m.undo()
        let aReverted = try #require(Fix.ends(m, a))
        let bReverted = try #require(Fix.ends(m, b))
        #expect(aReverted.start == aBefore.start && aReverted.end == aBefore.end,
                "one ⌘Z restores A")
        #expect(bReverted.start == bBefore.start && bReverted.end == bBefore.end,
                "one ⌘Z restores B (edit + re-solve are one undo group)")
        // That one undo emptied the stack — the edit + re-solve were a SINGLE step.
        #expect(!m.canUndo, "edit + re-solve must collapse into a SINGLE undo step")
    }
}

// MARK: - Create path (arity validation + immediate apply)

@MainActor
@Suite("Wave-3 constraint seam — create / remove / accessors")
struct ConstraintCreatePathTests {

    /// `addConstraint` applies IMMEDIATELY: a horizontal constraint on a diagonal line
    /// makes it horizontal in the same call (no separate re-solve needed).
    @Test("addConstraint(horizontal) applies immediately")
    func horizontalAppliesImmediately() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 6)))   // diagonal
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.horizontal, entities: [a]))
        let ends = try #require(Fix.ends(m, a))
        #expect(abs(ends.end.y - ends.start.y) < 1e-6, "line should be horizontal now")
        #expect(m.constraints(for: a).count == 1)
        #expect(m.allConstraints.count == 1)
    }

    /// addConstraint + its immediate re-solve are ONE undo group.
    @Test("addConstraint is a single undo group (constraint add + apply)")
    func addConstraintOneUndo() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 6)))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.horizontal, entities: [a]))
        #expect(!m.allConstraints.isEmpty)
        m.undo()
        #expect(m.allConstraints.isEmpty, "one ⌘Z removes the constraint")
        // The geometry the re-solve moved is restored too, and no buried second step.
        #expect(Fix.ends(m, a)?.end == Vector(10, 6))
        #expect(!m.canUndo)
    }

    /// Arity validation rejects bad selections (adds nothing, returns false).
    @Test("arity validation rejects wrong-cardinality selections")
    func arityRejectsBadSelections() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(Fix.line(Vector(0, 5), Vector(10, 5)))
        let c = drawing.add(Fix.circle(Vector(0, 0), 5))
        let m = Fix.model(drawing)

        // parallel needs 2, not 1 / 3.
        #expect(!m.addConstraint(.parallel, entities: [a]))
        #expect(!m.addConstraint(.parallel, entities: [a, b, c]))
        // horizontal needs 1, not 2.
        #expect(!m.addConstraint(.horizontal, entities: [a, b]))
        // distance needs a finite value + 2 entities.
        #expect(!m.addConstraint(.distance, entities: [a], value: 5))
        #expect(!m.addConstraint(.distance, entities: [a, b], value: .nan))
        // radius needs a CIRCLE, not a line.
        #expect(!m.addConstraint(.radius, entities: [a], value: 5))
        #expect(m.addConstraint(.radius, entities: [c], value: 8))   // a circle: OK
        // An unsupported kind is rejected.
        #expect(!m.addConstraint(.tangent, entities: [a, b]))
        // A missing entity id is rejected.
        #expect(!m.addConstraint(.horizontal, entities: [EntityID(9999)]))

        // Only the one valid radius constraint got added.
        #expect(m.allConstraints.count == 1)
    }

    /// `radius` drives a circle's radius immediately.
    @Test("addConstraint(radius) drives the circle radius")
    func radiusDrivesRadius() throws {
        let drawing = CADDrawing()
        let c = drawing.add(Fix.circle(Vector(3, 4), 5))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.radius, entities: [c], value: 12))
        guard case .circle(let circ)? = m.drawing.entity(c)?.kind else {
            Issue.record("not a circle"); return
        }
        #expect(abs(circ.radius - 12) < 1e-6)
        #expect(circ.center == Vector(3, 4), "center must not move")
    }

    /// `removeConstraint` removes (undoably) and leaves geometry where it is.
    @Test("removeConstraint removes the constraint, geometry stays put")
    func removeConstraintWorks() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 6)))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.horizontal, entities: [a]))
        let cid = try #require(m.allConstraints.first?.id)
        let endsAfterAdd = try #require(Fix.ends(m, a))   // horizontal now

        #expect(m.removeConstraint(id: cid))
        #expect(m.allConstraints.isEmpty)
        // Removing a constraint frees DOFs but does not move anything.
        #expect(Fix.ends(m, a)?.end == endsAfterAdd.end)
        // Idempotent: removing again is a no-op.
        #expect(!m.removeConstraint(id: cid))
    }
}

// MARK: - Lane B — the 7 newly-implemented constraint kinds (create path + selection)

@MainActor
@Suite("Lane B constraint seam — collinear / concentric / equal / angle / diameter / H-V dist")
struct LaneBConstraintCreateTests {

    private static func arc(_ c: Vector, _ r: Double, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .arc(ArcData(center: c, radius: r, startAngle: 0, endAngle: .pi)))
    }

    // --- collinear ---

    @Test("addConstraint(collinear) puts two lines on one line")
    func collinearApplies() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))     // X axis
        let b = drawing.add(Fix.line(Vector(2, 4), Vector(9, 6)))      // offset + tilted
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))
        #expect(m.addConstraint(.collinear, entities: [a, b]))
        let ends = try #require(Fix.ends(m, b))
        #expect(abs(ends.start.y) < 1e-4 && abs(ends.end.y) < 1e-4, "B lands on the X axis")
        #expect(m.allConstraints.count == 2)
    }

    @Test("collinear rejects a non-line / wrong-arity selection")
    func collinearRejects() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))
        let c = drawing.add(Fix.circle(Vector(0, 0), 5))
        let m = Fix.model(drawing)
        #expect(!m.addConstraint(.collinear, entities: [a]))          // needs 2
        #expect(!m.addConstraint(.collinear, entities: [a, c]))       // circle not a line
        #expect(m.allConstraints.isEmpty)
    }

    // --- concentric ---

    @Test("addConstraint(concentric) snaps a circle onto a fixed circle's center")
    func concentricApplies() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.circle(Vector(5, 5), 3))
        let b = drawing.add(Fix.circle(Vector(20, 1), 8))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))
        #expect(m.addConstraint(.concentric, entities: [a, b]))
        guard case .circle(let bc)? = m.drawing.entity(b)?.kind else {
            Issue.record("b not a circle"); return
        }
        #expect(abs(bc.center.x - 5) < 1e-6 && abs(bc.center.y - 5) < 1e-6)
        #expect(abs(bc.radius - 8) < 1e-6, "radius unchanged by concentric")
    }

    @Test("concentric accepts a circle + arc pair, rejects two lines")
    func concentricArcAndReject() throws {
        let drawing = CADDrawing()
        let arc = drawing.add(Self.arc(Vector(-4, 7), 2))
        let c = drawing.add(Fix.circle(Vector(10, 10), 5))
        let l = drawing.add(Fix.line(Vector(0, 0), Vector(1, 1)))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.concentric, entities: [arc, c]))    // arc has a center
        guard case .circle(let cc)? = m.drawing.entity(c)?.kind else {
            Issue.record("c not a circle"); return
        }
        #expect(abs(cc.center.x - (-4)) < 1e-6 && abs(cc.center.y - 7) < 1e-6)
        #expect(!m.addConstraint(.concentric, entities: [l, l]))     // lines have no center
    }

    // --- equal (lines and circles) ---

    @Test("addConstraint(equal) equalizes two line lengths")
    func equalLines() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))    // len 10
        let b = drawing.add(Fix.line(Vector(0, 5), Vector(3, 5)))     // len 3
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))
        #expect(m.addConstraint(.equal, entities: [a, b]))
        let ends = try #require(Fix.ends(m, b))
        #expect(abs(ends.start.distance(to: ends.end) - 10) < 1e-5)
    }

    @Test("addConstraint(equal) equalizes two radii; rejects a mixed pair")
    func equalCirclesAndMixedReject() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.circle(Vector(0, 0), 7))
        let b = drawing.add(Fix.circle(Vector(30, 0), 2))
        let line = drawing.add(Fix.line(Vector(0, 0), Vector(5, 0)))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))
        #expect(m.addConstraint(.radius, entities: [a], value: 7))    // hold A at 7
        #expect(m.addConstraint(.equal, entities: [a, b]))
        guard case .circle(let bc)? = m.drawing.entity(b)?.kind else {
            Issue.record("b not a circle"); return
        }
        #expect(abs(bc.radius - 7) < 1e-5)
        // A mixed line+circle pair is not a same-family equal → rejected.
        #expect(!m.addConstraint(.equal, entities: [a, line]))
    }

    // --- angle (dimensional, locks the current measured value) ---

    @Test("addConstraint(angle) creates an angle constraint over two lines with the value")
    func angleAppliesWithValue() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(Fix.line(Vector(0, 0), Vector(5, 1)))
        let c = drawing.add(Fix.circle(Vector(0, 0), 5))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.angle, entities: [a, b], value: .pi / 2))
        let added = try #require(m.allConstraints.first { $0.kind == .dimensional(.angle) })
        #expect(abs(added.value - Double.pi / 2) < 1e-9)
        #expect(added.points.count == 4, "two lines → four endpoints")
        // A non-line in the pair is rejected.
        #expect(!m.addConstraint(.angle, entities: [a, c], value: .pi / 4))
        #expect(m.allConstraints.count == 1)
    }

    @Test("angle constraint via selection LOCKS the current measured included angle")
    func angleLocksCurrentViaSelection() throws {
        let drawing = CADDrawing()
        let a = drawing.add(Fix.line(Vector(0, 0), Vector(10, 0)))    // angle 0
        let b = drawing.add(Fix.line(Vector(0, 0), Vector(0, 5)))     // angle 90°
        let m = Fix.model(drawing)
        #expect(m.setSelection([a, b]))
        #expect(m.applyDimensionalConstraintToSelection(.angle))
        let added = try #require(m.allConstraints.first { $0.kind == .dimensional(.angle) })
        // Locked value is the current included angle θA − θB = 0 − (π/2) = −π/2.
        #expect(abs(added.value - (-Double.pi / 2)) < 1e-6)
    }

    @Test("angle rejects a non-line selection")
    func angleRejectsNonLines() throws {
        let drawing = CADDrawing()
        let c = drawing.add(Fix.circle(Vector(0, 0), 5))
        let l = drawing.add(Fix.line(Vector(0, 0), Vector(1, 0)))
        let m = Fix.model(drawing)
        #expect(m.setSelection([c, l]))
        #expect(!m.applyDimensionalConstraintToSelection(.angle))
        #expect(m.toolStatus.contains("angle"))   // a human failure note posted
        #expect(m.allConstraints.isEmpty)
    }

    // --- diameter ---

    @Test("addConstraint(diameter) drives a circle's diameter")
    func diameterApplies() throws {
        let drawing = CADDrawing()
        let c = drawing.add(Fix.circle(Vector(3, 4), 2))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.diameter, entities: [c], value: 9))
        guard case .circle(let circ)? = m.drawing.entity(c)?.kind else {
            Issue.record("not a circle"); return
        }
        #expect(abs(circ.radius - 4.5) < 1e-6, "diameter 9 ⇒ radius 4.5")
    }

    @Test("diameter via selection locks the current diameter; rejects a line")
    func diameterLocksCurrentAndRejects() throws {
        let drawing = CADDrawing()
        let c = drawing.add(Fix.circle(Vector(0, 0), 6))   // diameter 12
        let l = drawing.add(Fix.line(Vector(0, 0), Vector(5, 0)))
        let m = Fix.model(drawing)
        #expect(m.setSelection([c]))
        #expect(m.applyDimensionalConstraintToSelection(.diameter))
        let added = try #require(m.allConstraints.first { $0.kind == .dimensional(.diameter) })
        #expect(abs(added.value - 12) < 1e-6)   // locked the present diameter
        // A line has no diameter → rejected.
        #expect(m.setSelection([l]))
        #expect(!m.applyDimensionalConstraintToSelection(.diameter))
    }

    // --- horizontalDistance / verticalDistance ---

    @Test("addConstraint(horizontalDistance) drives Δx")
    func horizontalDistanceApplies() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(Fix.point(Vector(0, 0)))
        let p2 = drawing.add(Fix.point(Vector(3, 4)))
        let m = Fix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.horizontalDistance, entities: [p1, p2], value: 12))
        guard case .point(let pd)? = m.drawing.entity(p2)?.kind else {
            Issue.record("p2 not a point"); return
        }
        #expect(abs(pd.position.x - 12) < 1e-6)
    }

    @Test("H/V distance via selection lock the present Δx / Δy")
    func hvDistanceLockCurrent() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(Fix.point(Vector(1, 2)))
        let p2 = drawing.add(Fix.point(Vector(9, 7)))   // Δx 8, Δy 5
        let m = Fix.model(drawing)
        #expect(m.setSelection([p1, p2]))
        // Both H and V distance lock from the SAME (unchanged) selection.
        #expect(m.applyDimensionalConstraintToSelection(.horizontalDistance))
        let h = try #require(m.allConstraints.first { $0.kind == .dimensional(.horizontalDistance) })
        #expect(abs(h.value - 8) < 1e-6)
        #expect(m.applyDimensionalConstraintToSelection(.verticalDistance))
        let v = try #require(m.allConstraints.first { $0.kind == .dimensional(.verticalDistance) })
        #expect(abs(v.value - 5) < 1e-6)
    }

    @Test("H/V distance reject a single-entity selection")
    func hvDistanceArity() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(Fix.point(Vector(0, 0)))
        let m = Fix.model(drawing)
        #expect(m.setSelection([p1]))
        #expect(!m.applyDimensionalConstraintToSelection(.horizontalDistance))
        #expect(!m.applyDimensionalConstraintToSelection(.verticalDistance))
        #expect(m.allConstraints.isEmpty)
    }

    // --- the new kinds are supported (no .unsupported funnel rejection) ---

    @Test("Lane B kinds report solver-supported; tangent + symmetric still do not")
    func laneBSupportedFlags() {
        #expect(GeometricConstraintKind.collinear.isSolverSupported)
        #expect(GeometricConstraintKind.concentric.isSolverSupported)
        #expect(GeometricConstraintKind.equal.isSolverSupported)
        #expect(DimensionalConstraintKind.angle.isSolverSupported)
        #expect(DimensionalConstraintKind.diameter.isSolverSupported)
        #expect(DimensionalConstraintKind.horizontalDistance.isSolverSupported)
        #expect(DimensionalConstraintKind.verticalDistance.isSolverSupported)
        #expect(!GeometricConstraintKind.tangent.isSolverSupported)
        #expect(!GeometricConstraintKind.symmetric.isSolverSupported)
    }
}

// MARK: - Glyph overlay (pure helpers — read-only display)

@Suite("Wave-3 constraint seam — glyph overlay layout")
struct ConstraintGlyphLayoutTests {

    @Test("kind→glyph mapping covers the MVP constraint kinds")
    func glyphMapping() {
        #expect(ConstraintGlyph.label(for: .geometric(.parallel)) == "∥")
        #expect(ConstraintGlyph.label(for: .geometric(.perpendicular)) == "⊥")
        #expect(ConstraintGlyph.label(for: .geometric(.horizontal)) == "H")
        #expect(ConstraintGlyph.label(for: .geometric(.vertical)) == "V")
        #expect(ConstraintGlyph.label(for: .geometric(.coincident)) == "•")
        #expect(ConstraintGlyph.label(for: .geometric(.fix)) == "🔒")
        #expect(ConstraintGlyph.label(for: .dimensional(.distance)) == "↔")
        #expect(ConstraintGlyph.label(for: .dimensional(.radius)) == "R")
    }

    @Test("placements anchor each badge at the constraint's feature point")
    func placementAnchors() {
        let e1 = EntityID(1)
        let e2 = EntityID(2)
        let cons = [
            Constraint.horizontal(line: e1),
            Constraint.radius(circle: e2, value: 5),
        ]
        // Per-CONSTRAINT anchor: the horizontal at (10,0), the radius at (0,20).
        // Identity-ish projection: world (x,y) → screen (x, y) for an easy assert.
        let places = ConstraintGlyphLayout.placements(
            for: cons,
            worldAnchor: { c in
                switch c.kind {
                case .geometric(.horizontal): return Vector(10, 0)
                case .dimensional(.radius):   return Vector(0, 20)
                default:                      return nil
                }
            },
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) })

        #expect(places.count == 2)
        #expect(places[0].label == "H")
        #expect(places[0].anchor == CGPoint(x: 10, y: 0))   // first at this spot, no offset
        #expect(places[1].label == "R")
        #expect(places[1].anchor == CGPoint(x: 0, y: 20))
    }

    @Test("badges sharing a screen spot fan out by the stack step")
    func coAnchoredStacking() {
        let e1 = EntityID(1)
        let cons = [
            Constraint.horizontal(line: e1),
            Constraint.fix(line: e1),     // SAME anchor point → stacked
        ]
        let places = ConstraintGlyphLayout.placements(
            for: cons,
            worldAnchor: { _ in Vector(5, 5) },   // both land at the same spot
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) })
        #expect(places.count == 2)
        #expect(places[0].anchor == CGPoint(x: 5, y: 5))
        // Second badge nudged up (smaller screen-y) by the stack step.
        #expect(places[1].anchor == CGPoint(x: 5, y: 5 - ConstraintGlyphLayout.stackStep))
    }

    @Test("a constraint whose anchor doesn't resolve is skipped")
    func skipsMissingAnchor() {
        let cons = [Constraint.horizontal(line: EntityID(1))]
        let places = ConstraintGlyphLayout.placements(
            for: cons,
            worldAnchor: { _ in nil },     // no resolvable anchor
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) })
        #expect(places.isEmpty)
    }

    @Test("a perpendicular badge anchors at the lines' intersection (the corner)")
    func perpendicularAnchorsAtCorner() {
        // Line A horizontal along y=0; line B vertical along x=4. They meet at (4,0) —
        // the corner — even though the segments don't physically touch there.
        let aS = Vector(0, 0), aE = Vector(10, 0)
        let bS = Vector(4, 3), bE = Vector(4, 9)
        let x = ConstraintGlyphLayout.lineIntersection(aS, aE, bS, bE)
        #expect(x?.x == 4)
        #expect(x?.y == 0)
        // Parallel lines have no corner.
        #expect(ConstraintGlyphLayout.lineIntersection(Vector(0, 0), Vector(10, 0),
                                                       Vector(0, 5), Vector(10, 5)) == nil)
    }
}
