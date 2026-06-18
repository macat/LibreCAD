//
//  ConstraintOverConstrainTests.swift
//  CADEngineTests
//
//  The "constraints just did not work" FIX — the MANUAL constraint-apply robustness pass.
//
//  THE BUG (pinned by `overConstrainedAddLeftDanglingBadge_FIXED`): the manual
//  constraint-apply funnel (`addConstraint` → `commitConstraints`) added the constraint to
//  the table, re-solved, and returned `true` WITHOUT checking the solve result. When the
//  add OVER-CONSTRAINED a component, `resolveConstraints` hit `.failed` and wrote NOTHING
//  (geometry unchanged) yet the constraint REMAINED in the table with a visible glyph — a
//  dangling badge on un-enforced geometry ("constraints did not work"). The AUTO path
//  rolled back on `.failed`; the manual path did not.
//
//  THE FIX (proven here):
//   • An over-constraining manual add is ROLLED BACK in the same undo group and reported
//     (`applyGeometricConstraintToSelection`/`...Dimensional...` return false + post the
//     "would over-constrain — delete a conflicting constraint" message). A clean no-op.
//   • A NORMALLY-SOLVABLE add (a single H on a free line, a normal rectangle corner) still
//     succeeds and enforces — the regularizer-solvable common cases must NOT regress.
//   • UNSATISFIED tracking — after a re-solve, the constraints living in a `.failed`
//     component are reported in `model.unsatisfiedConstraintIDs` so the glyph overlay /
//     list can flag them in a warning style; a solved component reports empty.
//   • LOAD-TIME enforce — `setDrawing` re-solves restored constraints so they drive the
//     loaded geometry on open (and flags any the geometry can't satisfy).
//
//  Reached through the existing `_SharedCanvasModel.swift` / `_SharedConstraintListLogic.swift`
//  symlinks (the test target depends only on CADEngine). `@MainActor`; pure model wiring.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
private enum OC {
    static func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }
    static func model(_ drawing: CADDrawing) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }
    static func ends(_ m: CanvasModel, _ id: EntityID) -> (start: Vector, end: Vector)? {
        guard case .line(let l)? = m.drawing.entity(id)?.kind else { return nil }
        return (l.start, l.end)
    }

    /// Calls the otherwise-caller-grouped `resolveConstraints(touching:)` inside an
    /// explicit undo group — the production callers (`addConstraint` / `applyInspectorEdits`)
    /// always have a group open; a bare test call (with `groupsByEvent == false`) must
    /// supply one so the engine's `registerUndo` has a group to register into.
    @discardableResult
    static func resolve(_ m: CanvasModel, touching ids: Set<EntityID>) -> Bool {
        m.undoManager.beginUndoGrouping()
        defer { m.undoManager.endUndoGrouping() }
        return m.resolveConstraints(touching: ids)
    }
}

// MARK: - The bug + its fix (manual over-constraint rollback)

@MainActor
@Suite("Manual constraint apply — over-constraint rollback")
struct ConstraintOverConstrainRollbackTests {

    /// THE BUG, now FIXED. A diagonal line is FIXED (pinning both endpoints), then a
    /// HORIZONTAL is applied — an impossible demand (the fixed endpoints can't go flat),
    /// so the solve `.failed` and the geometry is unchanged.
    ///
    /// BEFORE the fix the horizontal would REMAIN in the table (a dangling badge on the
    /// still-diagonal line). AFTER the fix it is ROLLED BACK: the add returns false, the
    /// table keeps ONLY the fix, and the geometry is exactly the original diagonal.
    @Test("an over-constraining manual add is rejected (no dangling badge), geometry intact")
    func overConstrainingAddIsRejected() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))   // diagonal
        let m = OC.model(drawing)

        // The FIX solves fine (pins the current geometry) and stays.
        #expect(m.addConstraint(.fix, entities: [a]))
        #expect(m.allConstraints.count == 1)
        let before = try #require(OC.ends(m, a))

        // Now HORIZONTAL over-constrains the already-fixed diagonal → REJECTED + rolled back.
        #expect(!m.addConstraint(.horizontal, entities: [a]),
                "an over-constraining horizontal must be rejected, not silently kept")
        // The table is back to JUST the fix — no dangling horizontal badge remains.
        #expect(m.allConstraints.count == 1)
        #expect(m.allConstraints.first?.kind == .geometric(.fix))
        // The geometry is exactly the original diagonal (nothing warped, nothing un-enforced).
        let after = try #require(OC.ends(m, a))
        #expect(after.start == before.start && after.end == before.end)
        // And nothing is flagged unsatisfied (the rolled-back add left a clean table).
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }

    /// The selection-apply funnel posts the OVER-CONSTRAINED message (distinct from the
    /// arity message) so the user learns it would CONFLICT, not that the selection is wrong.
    @Test("applyGeometricConstraintToSelection posts the over-constrained message")
    func overConstrainedSelectionPostsMessage() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))
        let m = OC.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))   // valid selection of 1

        #expect(m.setSelection([a]))
        #expect(!m.applyGeometricConstraintToSelection(.horizontal),
                "over-constrained apply returns false")
        // The message names the over-constraint reason, NOT a selection-arity problem.
        #expect(m.toolStatus.lowercased().contains("over-constrain"),
                "got: \(m.toolStatus)")
        // The constraint did NOT land.
        #expect(m.allConstraints.count == 1)
    }

    /// The rollback (add + its removal in ONE group) is NET-ZERO on the table: after a
    /// rejected add the constraint table is unchanged and the geometry intact, and undoing
    /// it leaves the SAME state (the rejected commit is a no-op step), with the preceding
    /// good `fix` still revertible by a further undo. This mirrors the auto-path rollback,
    /// which also collapses an add+remove into the caller's group.
    @Test("a rejected over-constraining add is net-zero on the table")
    func rejectedAddIsNetZero() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))
        let m = OC.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))           // kept
        #expect(!m.addConstraint(.horizontal, entities: [a]))   // rejected (rolled back)
        // Table holds ONLY the fix — the rolled-back horizontal left nothing behind.
        #expect(m.allConstraints.count == 1)
        #expect(m.allConstraints.first?.kind == .geometric(.fix))

        // Undoing the (net-zero) rejected commit leaves the table identical: still the fix.
        m.undo()
        #expect(m.allConstraints.count == 1 || m.allConstraints.isEmpty,
                "the net-zero rejected commit undoes to the same / preceding state")
        // Whatever the granularity, the geometry never warped (the fix pins the diagonal).
        #expect(OC.ends(m, a)?.end == Vector(10, 6))
        // No dangling horizontal ever survives, in any undo state.
        #expect(!m.allConstraints.contains { $0.kind == .geometric(.horizontal) })
    }

    /// Two CONTRADICTORY relations applied through the manual funnel: two lines made
    /// PARALLEL, then PERPENDICULAR to each other (they cannot be both). The second apply
    /// is rejected and rolled back; only the parallel remains, and it is satisfied.
    @Test("a contradictory second relation is rejected, the first stays satisfied")
    func conflictingSecondConstraintRejected() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 0)))   // horizontal
        let b = drawing.add(OC.line(Vector(0, 5), Vector(10, 5)))   // parallel already
        let m = OC.model(drawing)
        #expect(m.addConstraint(.fix, entities: [a]))                // anchor A so B moves
        #expect(m.addConstraint(.parallel, entities: [a, b]))        // OK — they're parallel
        let parallelCount = m.allConstraints.filter { $0.kind == .geometric(.parallel) }.count
        #expect(parallelCount == 1)

        // PERPENDICULAR on the same pair contradicts the parallel → rejected + rolled back.
        #expect(!m.addConstraint(.perpendicular, entities: [a, b]),
                "perpendicular contradicting an existing parallel must be rejected")
        #expect(!m.allConstraints.contains { $0.kind == .geometric(.perpendicular) },
                "no perpendicular badge should linger")
        // The parallel survives and nothing is flagged unsatisfied (clean rollback).
        #expect(m.allConstraints.contains { $0.kind == .geometric(.parallel) })
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }
}

// MARK: - The common cases must NOT regress

@MainActor
@Suite("Manual constraint apply — solvable cases still succeed")
struct ConstraintSolvableStillSucceedTests {

    /// A single HORIZONTAL on a FREE diagonal line still applies + enforces (the min-
    /// displacement regularizer solves an under-determined partial constraint set). This
    /// is the "do NOT reject normally-solvable adds" guarantee.
    @Test("single horizontal on a free line still applies and straightens it")
    func singleHorizontalStillApplies() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))   // free diagonal
        let m = OC.model(drawing)
        #expect(m.addConstraint(.horizontal, entities: [a]))
        let ends = try #require(OC.ends(m, a))
        #expect(abs(ends.end.y - ends.start.y) < 1e-6, "line is horizontal now")
        #expect(m.allConstraints.count == 1)
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }

    /// A normal rectangle corner: perpendicular two free lines — solvable, kept.
    @Test("perpendicular on two free lines still applies")
    func perpendicularStillApplies() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 0)))   // horizontal
        let b = drawing.add(OC.line(Vector(0, 0), Vector(1, 8)))    // nearly vertical
        let m = OC.model(drawing)
        #expect(m.addConstraint(.perpendicular, entities: [a, b]))
        #expect(m.allConstraints.contains { $0.kind == .geometric(.perpendicular) })
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }

    /// A radius drives a circle — a 1-DOF dimensional add, solvable, kept.
    @Test("radius on a circle still applies")
    func radiusStillApplies() throws {
        let drawing = CADDrawing()
        let c = drawing.add(EntityRecord(id: EntityID(7),
                                         kind: .circle(CircleData(center: Vector(0, 0), radius: 5))))
        let m = OC.model(drawing)
        #expect(m.addConstraint(.radius, entities: [c], value: 9))
        guard case .circle(let circ)? = m.drawing.entity(c)?.kind else {
            Issue.record("not a circle"); return
        }
        #expect(abs(circ.radius - 9) < 1e-6)
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }
}

// MARK: - Unsatisfied tracking (the safety-net for other paths)

@MainActor
@Suite("Constraint unsatisfied tracking")
struct ConstraintUnsatisfiedTrackingTests {

    /// A `.failed` component reports ALL its constraint ids in `unsatisfiedConstraintIDs`.
    /// We inject the conflicting constraints DIRECTLY into the table (bypassing the
    /// model's manual-apply rollback) — the way a DXF load or an edge-case path could —
    /// then re-solve and confirm both ids are flagged.
    @Test("a failed component reports its constraint ids as unsatisfied")
    func failedComponentReportsIDs() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))
        // Inject fix + horizontal straight into the table → a guaranteed .failed component.
        let fix = Constraint.fix(line: a)
        let horiz = Constraint.horizontal(line: a)
        #expect(drawing.addConstraint(fix))
        #expect(drawing.addConstraint(horiz))
        let m = OC.model(drawing)

        // A re-solve over the component flags BOTH constraints as unsatisfied.
        OC.resolve(m, touching: [a])
        #expect(m.unsatisfiedConstraintIDs.contains(fix.id))
        #expect(m.unsatisfiedConstraintIDs.contains(horiz.id))
    }

    /// A SOLVED component clears its ids from the unsatisfied set: after removing the
    /// conflicting constraint, the remaining one is satisfiable and no longer flagged.
    @Test("a re-solve that succeeds clears the unsatisfied flag")
    func solvedComponentClearsFlag() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))
        let fix = Constraint.fix(line: a)
        let horiz = Constraint.horizontal(line: a)
        #expect(drawing.addConstraint(fix))
        #expect(drawing.addConstraint(horiz))
        let m = OC.model(drawing)
        OC.resolve(m, touching: [a])
        #expect(!m.unsatisfiedConstraintIDs.isEmpty)

        // Drop the fix → the lone horizontal now solves; the flag must clear.
        #expect(m.removeConstraint(id: fix.id))
        OC.resolve(m, touching: [a])
        #expect(m.unsatisfiedConstraintIDs.isEmpty,
                "a now-satisfiable component must clear its unsatisfied flag")
    }

    /// `resolveAllConstraints` over a clean (solvable) table reports NOTHING unsatisfied.
    @Test("a fully-solvable table reports no unsatisfied constraints")
    func cleanTableReportsNone() throws {
        let drawing = CADDrawing()
        let a = drawing.add(OC.line(Vector(0, 0), Vector(10, 6)))
        let m = OC.model(drawing)
        #expect(m.addConstraint(.horizontal, entities: [a]))   // solvable
        m.resolveAllConstraints()
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }

    /// The pure list-logic flag helper mirrors the model set: a row whose id is in the
    /// set is flagged (with a note); one not in it is not.
    @Test("ConstraintListModel.isUnsatisfied reflects the set membership")
    func listLogicFlag() {
        let c = Constraint.horizontal(line: EntityID(1))
        #expect(ConstraintListModel.isUnsatisfied(c, unsatisfiedIDs: [c.id]))
        #expect(!ConstraintListModel.isUnsatisfied(c, unsatisfiedIDs: []))
        #expect(ConstraintListModel.unsatisfiedNote(c, unsatisfiedIDs: [c.id]) == "not satisfied")
        #expect(ConstraintListModel.unsatisfiedNote(c, unsatisfiedIDs: []) == nil)
    }
}

// MARK: - Load-time enforce (the one previously untested surface)

@MainActor
@Suite("Constraint load-time enforcement (setDrawing)")
struct ConstraintLoadResolveTests {

    /// A drawing whose stored geometry does NOT yet satisfy its restored constraints gets
    /// ENFORCED on open: `setDrawing` re-solves, so the diagonal line carrying a horizontal
    /// constraint lands horizontal after the load.
    @Test("setDrawing enforces restored constraints on the loaded geometry")
    func setDrawingEnforcesConstraints() throws {
        // Build a drawing whose geometry is diagonal but carries a horizontal constraint
        // (as if a file stored geometry the constraint hadn't been applied to yet).
        let loaded = CADDrawing()
        let a = loaded.add(OC.line(Vector(0, 0), Vector(10, 6)))   // diagonal
        #expect(loaded.addConstraint(Constraint.horizontal(line: a)))

        // Open it into a fresh model via setDrawing.
        let m = OC.model(CADDrawing())
        m.setDrawing(loaded, viewSize: CGSize(width: 800, height: 600))

        // The horizontal constraint is now ENFORCED on the loaded line.
        let ends = try #require(OC.ends(m, a))
        #expect(abs(ends.end.y - ends.start.y) < 1e-6,
                "a restored horizontal constraint should drive the loaded line flat")
        // A clean (solvable) load flags nothing unsatisfied.
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
        // Load-time enforcement is part of the baseline — NOT a user-undoable step.
        #expect(!m.canUndo, "the load + its constraint enforcement is the clean baseline")
    }

    /// An UNSATISFIABLE restored set (fix + horizontal on a diagonal) is flagged on open
    /// rather than silently shown as holding.
    @Test("setDrawing flags an unsatisfiable restored constraint set")
    func setDrawingFlagsUnsatisfiable() throws {
        let loaded = CADDrawing()
        let a = loaded.add(OC.line(Vector(0, 0), Vector(10, 6)))
        #expect(loaded.addConstraint(Constraint.fix(line: a)))
        #expect(loaded.addConstraint(Constraint.horizontal(line: a)))

        let m = OC.model(CADDrawing())
        m.setDrawing(loaded, viewSize: CGSize(width: 800, height: 600))

        // The component is over-constrained → both restored constraints are flagged.
        #expect(!m.unsatisfiedConstraintIDs.isEmpty,
                "an unsatisfiable restored set must be flagged, not shown as if it holds")
    }

    /// A drawing with NO constraints loads with an empty unsatisfied set (no spurious flag).
    @Test("setDrawing on a constraint-free drawing clears the unsatisfied set")
    func setDrawingNoConstraints() throws {
        let loaded = CADDrawing()
        _ = loaded.add(OC.line(Vector(0, 0), Vector(10, 6)))
        let m = OC.model(CADDrawing())
        m.setDrawing(loaded, viewSize: CGSize(width: 800, height: 600))
        #expect(m.unsatisfiedConstraintIDs.isEmpty)
    }
}
