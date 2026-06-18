//
//  ParameterResolveSeamTests.swift
//  CADEngineTests
//
//  Lane L2 — the PARAMETER re-eval → re-solve SEAM. Proves the `CanvasModel` glue that
//  makes NAMED PARAMETERS actually DRIVE geometry (the parametric mirror of
//  `ConstraintResolveSeamTests`):
//
//   • Re-eval → re-solve — binding a dimensional constraint's expression to a parameter
//     then editing the parameter MOVES the driven geometry (the recompute choke point
//     refreshes the cached `value` at the top of every re-solve).
//   • ONE undo step — a parameter edit AND the geometry it moved collapse into a single
//     ⌘Z (the funnel's `explicitGroup` one-undo handling).
//   • Transitive — `h = w/2`: editing `w` re-solves an `h`-driven constraint.
//   • Robustness — a cyclic / syntactically-bad expression leaves the geometry UNMOVED
//     (the seam keeps the last-good cache; NEVER writes NaN to the solver).
//   • The `name=value` command-line route — creates the parameter, and (when a
//     dimensional constraint is in flight) AUTO-BINDS it; the classifier rejects
//     `2=5` / `10,20` / `@5,5` / a bare `=` (they don't create a parameter).
//   • Unit conversion at the seam — `w = 22mm` in a `cm` drawing caches 2.2.
//   • Literal-path byte-identical — a constraint with `expression == nil` is untouched
//     by the recompute (the existing constraint behavior is preserved exactly).
//
//  `CanvasModel` lives in the (un-importable) app target, reached here via the existing
//  `_SharedCanvasModel.swift` symlink. The suite is `@MainActor`; no SwiftUI body / NSView
//  is rendered — only the pure model wiring.
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
private enum PFix {
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

    /// The world distance between two POINTS, or `nil`.
    static func gap(_ m: CanvasModel, _ a: EntityID, _ b: EntityID) -> Double? {
        guard case .point(let pa)? = m.drawing.entity(a)?.kind,
              case .point(let pb)? = m.drawing.entity(b)?.kind else { return nil }
        return pa.position.distance(to: pb.position)
    }

    /// The radius of a CIRCLE, or `nil`.
    static func radius(_ m: CanvasModel, _ id: EntityID) -> Double? {
        guard case .circle(let c)? = m.drawing.entity(id)?.kind else { return nil }
        return c.radius
    }
}

// MARK: - Re-eval → re-solve (the heart of the seam)

@MainActor
@Suite("Lane-L2 parameter seam — edit a parameter, geometry follows")
struct ParameterResolveOnEditTests {

    /// Bind a distance constraint to parameter `w` (=50); FIX one point so the solver
    /// moves the other; then edit `w` → 80 and the gap must follow.
    @Test("editing a bound parameter moves the driven geometry")
    func paramEditMovesGeometry() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(50, 0)))
        let m = PFix.model(drawing)

        m.setParameterExpression(name: "w", expression: "50")
        #expect(m.addConstraint(.fix, entities: [p1]))                 // anchor p1
        #expect(m.addConstraint(.distance, entities: [p1, p2], expression: "w"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 50) < 1e-6)

        // Edit the parameter → the distance constraint's cache refreshes → p2 moves.
        #expect(m.setParameterExpression(name: "w", expression: "80"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 80) < 1e-6,
                "the gap should be driven to the new w (got \(PFix.gap(m, p1, p2) ?? .nan))")
        // The bound constraint's cached value also refreshed.
        let bound = try #require(m.allConstraints.first { $0.expression == "w" })
        #expect(abs(bound.value - 80) < 1e-6)
    }

    /// `setParameterValue` (the numeric Parameters-table edit) drives geometry the same way.
    @Test("setParameterValue drives a bound radius constraint")
    func paramValueDrivesRadius() throws {
        let drawing = CADDrawing()
        let c = drawing.add(PFix.circle(Vector(3, 4), 5))
        let m = PFix.model(drawing)
        m.setParameterExpression(name: "r", expression: "5")
        #expect(m.addConstraint(.radius, entities: [c], expression: "r"))
        #expect(abs((PFix.radius(m, c) ?? 0) - 5) < 1e-6)

        #expect(m.setParameterValue(name: "r", value: 12))
        #expect(abs((PFix.radius(m, c) ?? 0) - 12) < 1e-6)
    }

    /// Binding an EXISTING literal constraint to a parameter (`setConstraintExpression`)
    /// then editing the parameter moves the geometry; unbinding keeps the last value.
    @Test("setConstraintExpression binds a literal constraint, then param drives it")
    func bindThenDrive() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(10, 0)))
        let m = PFix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], value: 10))   // LITERAL
        let cid = try #require(m.allConstraints.first { $0.expression == nil && $0.kind.isDimensional }?.id)

        m.setParameterExpression(name: "len", expression: "30")
        #expect(m.setConstraintExpression(id: cid, expression: "len"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 30) < 1e-6, "binding pulls the gap to len=30")

        #expect(m.setParameterExpression(name: "len", expression: "45"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 45) < 1e-6, "editing len re-solves the gap")

        // Unbind → value (45) stays as the now-literal; later param edits don't move it.
        #expect(m.setConstraintExpression(id: cid, expression: nil))
        #expect(m.allConstraints.first { $0.id == cid }?.expression == nil)
        #expect(m.setParameterExpression(name: "len", expression: "99"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 45) < 1e-6, "an unbound constraint ignores the param")
    }

    /// TRANSITIVE: `h = w/2`. A constraint driven by `h`; editing `w` must re-solve it.
    @Test("transitive dependency — editing w re-solves an h-driven constraint")
    func transitiveResolve() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(40, 0)))
        let m = PFix.model(drawing)
        m.setParameterExpression(name: "w", expression: "80")
        m.setParameterExpression(name: "h", expression: "w/2")          // depends on w
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], expression: "h"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 40) < 1e-6)            // h == 40

        // Editing w to 100 → h becomes 50 → the gap follows.
        #expect(m.setParameterExpression(name: "w", expression: "100"))
        #expect(abs((m.drawing.parameters.parameter(named: "h")?.value ?? 0) - 50) < 1e-6,
                "h should re-evaluate to w/2 = 50")
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 50) < 1e-6,
                "the h-driven gap should follow to 50")
    }
}

// MARK: - One undo step

@MainActor
@Suite("Lane-L2 parameter seam — single-undo coalescing")
struct ParameterResolveUndoTests {

    /// ONE ⌘Z reverts BOTH the parameter edit AND the geometry it moved.
    @Test("one undo reverts the parameter edit AND the re-solve together")
    func oneUndoRevertsParamAndGeometry() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(50, 0)))
        let m = PFix.model(drawing)
        m.setParameterExpression(name: "w", expression: "50")
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], expression: "w"))

        // Make the parameter EDIT the only undo step on the stack.
        m.undoManager.removeAllActions()
        #expect(m.setParameterExpression(name: "w", expression: "90"))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 90) < 1e-6)

        // A SINGLE undo restores BOTH the parameter (w → 50) and the geometry (gap → 50).
        m.undo()
        #expect(abs((m.drawing.parameters.parameter(named: "w")?.value ?? 0) - 50) < 1e-6,
                "one ⌘Z restores the parameter value")
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 50) < 1e-6,
                "one ⌘Z restores the geometry the edit moved")
        #expect(!m.canUndo, "param edit + re-solve must collapse into a SINGLE undo step")
    }
}

// MARK: - Robustness — bad / cyclic expressions never poison the solver

@MainActor
@Suite("Lane-L2 parameter seam — bad expressions leave geometry unmoved")
struct ParameterResolveRobustnessTests {

    /// A SYNTACTICALLY-BAD expression edit leaves the driven geometry exactly where it was
    /// (the seam keeps the last-good cache; no NaN reaches the solver).
    @Test("a bad expression keeps the last-good value (geometry unmoved)")
    func badExpressionKeepsLastGood() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(50, 0)))
        let m = PFix.model(drawing)
        m.setParameterExpression(name: "w", expression: "50")
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], expression: "w"))
        let gapBefore = try #require(PFix.gap(m, p1, p2))

        // Edit w to GARBAGE → its value stays 50; the gap is untouched.
        m.setParameterExpression(name: "w", expression: "*/(")
        let gapAfter = try #require(PFix.gap(m, p1, p2))
        #expect(abs(gapAfter - gapBefore) < 1e-9, "a bad parameter expression must not move geometry")
        // The bound constraint never got a NaN.
        let bound = try #require(m.allConstraints.first { $0.expression == "w" })
        #expect(bound.value.isFinite)
        #expect(abs(bound.value - 50) < 1e-6, "the last-good value (50) is kept")
    }

    /// A CYCLE (`a=b`, `b=a`) is detected and leaves geometry unmoved — no infinite loop,
    /// no NaN. We install the mutual reference DIRECTLY (so there is no intermediate
    /// non-cyclic edit that could legitimately move things), seed the bound constraint's
    /// last-good value, then trigger a re-solve: the recompute must NOT hang and must NOT
    /// write a NaN; the geometry stays at the last-good value.
    @Test("a cyclic expression leaves geometry unmoved (no NaN, no hang)")
    func cyclicExpressionUnmoved() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(20, 0)))
        // Install a mutually-referencing parameter pair atomically (no clean intermediate
        // evaluation): a = b, b = a, each carrying a last-good cache of 20.
        drawing.addParameter(Parameter(name: "a", expression: "b", value: 20))
        drawing.addParameter(Parameter(name: "b", expression: "a", value: 20))
        let m = PFix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], expression: "a"))
        // The bound constraint already drives the gap to its last-good 20.
        let gapBefore = try #require(PFix.gap(m, p1, p2))
        #expect(abs(gapBefore - 20) < 1e-6)

        // Trigger a re-solve through an unrelated edit; the recompute hits the cycle. It
        // must NOT hang and must NOT write a NaN; the geometry stays at the last-good value.
        m.applyInspectorEdits([try #require(m.drawing.entity(p2))])   // no-op edit → recompute runs
        m.resolveConstraints(touching: [p2])
        let gapAfter = try #require(PFix.gap(m, p1, p2))
        #expect(gapAfter.isFinite)
        #expect(abs(gapAfter - gapBefore) < 1e-6, "a cyclic table must leave the geometry unmoved")
        for c in m.allConstraints { #expect(c.value.isFinite, "no NaN written to any constraint") }
    }
}

// MARK: - The name=value command-line route + classifier guard

@MainActor
@Suite("Lane-L2 parameter seam — name=value command-line route")
struct ParameterCommandLineRouteTests {

    /// `a=22` on the command line CREATES the parameter and returns `.handled`.
    @Test("a=22 creates the parameter and is handled")
    func assignmentCreatesParameter() throws {
        let m = PFix.model(CADDrawing())
        #expect(m.interpretCommandLine("a=22") == .handled)
        #expect(m.drawing.parameters.parameter(named: "a")?.expression == "22")
        #expect(abs((m.drawing.parameters.parameter(named: "a")?.value ?? 0) - 22) < 1e-6)

        // An expression in terms of the first parameter resolves through the route.
        #expect(m.interpretCommandLine("b = a*2") == .handled)
        #expect(abs((m.drawing.parameters.parameter(named: "b")?.value ?? 0) - 44) < 1e-6)

        // Re-assigning updates (no duplicate).
        #expect(m.interpretCommandLine("a=30") == .handled)
        #expect(m.drawing.parameters.count == 2)
        #expect(abs((m.drawing.parameters.parameter(named: "a")?.value ?? 0) - 30) < 1e-6)
    }

    /// The CLASSIFIER must NOT create a parameter for coordinates / tool input / malformed
    /// LHS — `2=5`, `key=val`(syntax RHS still defines? no — `val` is an unknown name, but
    /// the LHS `key` IS a valid identifier, so it DOES create a parameter with an
    /// unevaluable expression; the GUARD here is specifically the NON-identifier LHS and
    /// coordinate shapes that must be rejected before this route).
    @Test("the classifier rejects 2=5, 10,20, @5,5, and a bare =")
    func classifierRejectsNonAssignments() {
        let m = PFix.model(CADDrawing())
        // `2=5`: LHS not an identifier → parseAssignment returns nil → NOT a parameter.
        _ = m.interpretCommandLine("2=5")
        #expect(!m.drawing.parameters.contains(named: "2"))
        #expect(m.drawing.parameters.isEmpty)

        // Coordinates never reach the assignment route (no `=`); with no tool active they
        // error, but crucially create NO parameter.
        _ = m.interpretCommandLine("10,20")
        _ = m.interpretCommandLine("@5,5")
        #expect(m.drawing.parameters.isEmpty)

        // A bare `=` has an empty LHS → nil → no parameter.
        _ = m.interpretCommandLine("=")
        #expect(m.drawing.parameters.isEmpty)
    }

    /// `key=val` HAS a valid identifier LHS, so it DOES define a parameter — but with an
    /// unevaluable RHS (an unknown name), the cached value stays 0 (never NaN) and nothing
    /// downstream breaks. (Documents the boundary: the guard is the LHS shape, not RHS
    /// validity.)
    @Test("key=val defines the parameter but caches a safe value")
    func keyEqualsValDefinesSafely() {
        let m = PFix.model(CADDrawing())
        #expect(m.interpretCommandLine("key=val") == .handled)
        let p = m.drawing.parameters.parameter(named: "key")
        #expect(p?.expression == "val")
        #expect(p?.value == 0)          // unevaluable → safe 0, no NaN
    }
}

// MARK: - Auto-bind: a name=value line binds an in-flight dimensional constraint

@MainActor
@Suite("Lane-L2 parameter seam — auto-bind a dimensional constraint")
struct ParameterAutoBindTests {

    /// With a DISTANCE constraint in flight on a 2-entity selection, `a=22` creates the
    /// parameter AND binds the distance to it (driven, not literal).
    @Test("a=22 with a distance constraint in flight auto-binds the dimension")
    func autoBindDistance() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(100, 0)))
        let m = PFix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [p1]))      // anchor p1 so p2 moves
        m.selection = Selection(ids: [p1, p2])
        m.beginDimensionalConstraint(.distance)

        #expect(m.interpretCommandLine("a=22") == .handled)
        // The parameter exists AND a distance constraint bound to `a` was created.
        #expect(m.drawing.parameters.contains(named: "a"))
        let bound = try #require(m.allConstraints.first { $0.expression == "a" })
        #expect(bound.kind.isDimensional)
        #expect(abs(bound.value - 22) < 1e-6)
        // The geometry was driven to 22.
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 22) < 1e-6)
        // The pending flag was consumed.
        #expect(m.pendingDimensionalConstraint == nil)

        // Now editing the parameter moves the auto-bound geometry.
        #expect(m.setParameterValue(name: "a", value: 60))
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - 60) < 1e-6)
    }

    /// Without an in-flight constraint, `a=22` defines the parameter but binds nothing.
    @Test("a=22 with no constraint in flight binds nothing")
    func noBindWhenNotInFlight() {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(100, 0)))
        let m = PFix.model(drawing)
        m.selection = Selection(ids: [p1, p2])
        // No beginDimensionalConstraint → no pending kind.
        #expect(m.interpretCommandLine("a=22") == .handled)
        #expect(m.drawing.parameters.contains(named: "a"))
        #expect(m.allConstraints.isEmpty, "no constraint should be created without an in-flight request")
    }
}

// MARK: - Unit conversion at the seam

@MainActor
@Suite("Lane-L2 parameter seam — unit conversion")
struct ParameterUnitConversionTests {

    /// `w = 22mm` in a CENTIMETER drawing caches 2.2 (converted to drawing units at the
    /// seam) while the source expression text stays `22mm`.
    @Test("a unit literal is converted to the drawing unit at the seam")
    func unitLiteralConverts() throws {
        let drawing = CADDrawing()
        drawing.drawingUnit = .centimeter
        let m = PFix.model(drawing)
        #expect(m.interpretCommandLine("w=22mm") == .handled)
        let p = try #require(m.drawing.parameters.parameter(named: "w"))
        #expect(p.expression == "22mm")                 // raw source text kept
        #expect(abs(p.value - 2.2) < 1e-9, "22 mm == 2.2 cm")   // converted cache
    }

    /// In a MILLIMETER (or none) drawing, `w = 22mm` caches 22 (no scaling).
    @Test("a unit literal in a matching-unit drawing keeps the magnitude")
    func unitLiteralNoScaleInMM() throws {
        let drawing = CADDrawing()
        drawing.drawingUnit = .millimeter
        let m = PFix.model(drawing)
        #expect(m.interpretCommandLine("w=22mm") == .handled)
        #expect(abs((m.drawing.parameters.parameter(named: "w")?.value ?? 0) - 22) < 1e-9)
    }
}

// MARK: - Literal path is untouched by the recompute (byte-identical behavior)

@MainActor
@Suite("Lane-L2 parameter seam — literal path preserved")
struct ParameterLiteralPathTests {

    /// A pure-literal constraint (`expression == nil`) is NOT touched by the recompute:
    /// adding a parameter / running a re-solve leaves its `value` and geometry exactly as
    /// the literal create path produced them.
    @Test("a literal constraint is unaffected by the parameter recompute")
    func literalConstraintUntouched() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(PFix.point(Vector(0, 0)))
        let p2 = drawing.add(PFix.point(Vector(10, 0)))
        let m = PFix.model(drawing)
        #expect(m.addConstraint(.fix, entities: [p1]))
        #expect(m.addConstraint(.distance, entities: [p1, p2], value: 10))   // LITERAL
        let litBefore = try #require(m.allConstraints.first { $0.expression == nil && $0.kind.isDimensional })
        #expect(litBefore.expression == nil)
        let gapBefore = try #require(PFix.gap(m, p1, p2))

        // Add an unrelated parameter and edit it — the literal constraint must not move.
        m.setParameterExpression(name: "w", expression: "999")
        m.setParameterExpression(name: "w", expression: "1234")
        let litAfter = try #require(m.allConstraints.first { $0.id == litBefore.id })
        #expect(litAfter.expression == nil, "literal constraint stays literal")
        #expect(litAfter.value == litBefore.value, "literal value is byte-identical")
        #expect(abs((PFix.gap(m, p1, p2) ?? 0) - gapBefore) < 1e-9, "literal geometry unmoved")
    }

    /// The recompute is a CHEAP no-op when there are no parameters and no driven
    /// constraints — a re-solve of unconstrained geometry early-outs untouched (the
    /// existing `ConstraintResolveSeamTests` behavior is preserved through the new top call).
    @Test("recompute is a no-op with no parameters / driven constraints")
    func recomputeNoOpEarlyOut() {
        let drawing = CADDrawing()
        let m = PFix.model(drawing)
        // No parameters, no constraints → the recompute touches nothing, no crash.
        m.recomputeParameterDrivenValues()
        #expect(m.drawing.parameters.isEmpty)
        #expect(m.allConstraints.isEmpty)
        // resolveConstraints (which now calls recompute first) still early-outs false.
        #expect(!m.resolveConstraints(touching: [EntityID(1)]))
    }
}
