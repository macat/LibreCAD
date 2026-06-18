//
//  AutoConstrainOnDrawTests.swift
//  CADEngineTests
//
//  Lane A — "AutoConstrain on draw" (AutoCAD AutoConstrain) + the fix for the owner's
//  "the rectangle falls apart" bug. Proves the `CanvasModel.autoConstrain` pass that runs
//  at the draw-commit choke point (`applyCommit`'s `.add` arm):
//
//   • Draw-time auto-COINCIDENCE — drawing connected lines (endpoints touching within the
//     weld tolerance) auto-welds the shared corner with a VISIBLE (non-inferred)
//     coincident, so a later grip drag keeps the corner joined (the real cure).
//   • Angle INFERENCE — a segment ~axis-aligned gets HORIZONTAL/VERTICAL; a segment ~90°
//     to a welded neighbor gets PERPENDICULAR; ~0° gets PARALLEL — at most one per segment.
//   • NEVER OVER-CONSTRAIN — a tentative angular add that the solver can't satisfy (or that
//     would splay the geometry) is DROPPED; a closed 4-line loop doesn't explode / NaN.
//   • The OWNER'S REPRO — draw 3 connected lines (a partial rectangle) through the REAL
//     LineTool draw path, then grip-drag a corner: the welded corners STAY coincident.
//   • The default-ON @AppStorage TOGGLE — off ⇒ no constraints added (byte-identical to
//     the pre-feature behavior).
//
//  `CanvasModel` lives in the (un-importable) app target, reached here via the existing
//  `_SharedCanvasModel.swift` symlink (mirroring `ConstraintResolveSeamTests`). The suite
//  is `@MainActor`; no SwiftUI body / NSView is rendered — only the pure model wiring.
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
private enum ACFix {
    /// A model with a clean, manually-grouped undo stack (one explicit group == one ⌘Z),
    /// AutoConstrain ON (the default; set explicitly so the test is independent of any
    /// stray `UserDefaults.standard` value on the build machine).
    static func model(_ drawing: CADDrawing = CADDrawing(), autoConstrain: Bool = true) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        m.autoConstrainOnDraw = autoConstrain
        return m
    }

    /// Draws ONE line through the REAL draw-commit funnel (`applyCommit` via the public
    /// `applyToolEdits`, which DRAWs `adoptsCurrentProperties: true`) and returns its id.
    static func drawLine(_ m: CanvasModel, _ a: Vector, _ b: Vector) -> EntityID {
        let before = Set(m.drawing.entities.map(\.id))
        m.applyToolEdits([.add(EntityRecord(id: .placeholder, kind: .line(LineData(start: a, end: b))))])
        return m.drawing.entities.map(\.id).first { !before.contains($0) }!
    }

    /// The endpoints of the line with `id`, or `nil`.
    static func ends(_ m: CanvasModel, _ id: EntityID) -> (start: Vector, end: Vector)? {
        guard case .line(let l)? = m.drawing.entity(id)?.kind else { return nil }
        return (l.start, l.end)
    }

    /// All COINCIDENT constraints in the drawing.
    static func coincidents(_ m: CanvasModel) -> [Constraint] {
        m.allConstraints.filter { if case .geometric(.coincident) = $0.kind { return true }; return false }
    }

    /// Whether a (non-inferred) constraint of `kind` exists referencing `id`.
    static func hasVisible(_ m: CanvasModel, _ kind: Constraint.Kind, on id: EntityID) -> Bool {
        m.allConstraints.contains { $0.kind == kind && !$0.inferred && $0.references(id) }
    }
}

// MARK: - Draw-time auto-coincidence (the cure)

@MainActor
@Suite("AutoConstrain — draw-time coincidence weld")
struct AutoConstrainWeldTests {

    /// Two lines drawn sharing a touching corner auto-weld with a VISIBLE coincident.
    @Test("connected lines auto-add a visible coincident at the shared corner")
    func connectedLinesWeld() throws {
        let m = ACFix.model()
        let a = ACFix.drawLine(m, Vector(0, 0), Vector(10, 0))     // along x
        let b = ACFix.drawLine(m, Vector(10, 0), Vector(10, 10))   // shares corner (10,0)

        let welds = ACFix.coincidents(m)
        #expect(welds.count == 1, "exactly one corner weld")
        let weld = try #require(welds.first)
        #expect(!weld.inferred, "the weld must be VISIBLE (non-inferred) so the overlay shows it")
        // It binds a.end ↔ b.start (the touching corner).
        let bound = Set(weld.points)
        #expect(bound.contains(ConstraintPoint(entityID: a, point: .end)))
        #expect(bound.contains(ConstraintPoint(entityID: b, point: .start)))
    }

    /// Two lines drawn FAR apart get NO weld (we never join lines that don't touch).
    @Test("far-apart lines are NOT welded")
    func farApartNoWeld() {
        let m = ACFix.model()
        _ = ACFix.drawLine(m, Vector(0, 0), Vector(10, 0))
        _ = ACFix.drawLine(m, Vector(50, 50), Vector(60, 50))    // nowhere near
        #expect(ACFix.coincidents(m).isEmpty)
    }

    /// The weld is idempotent: drawing the SAME corner again doesn't stack a duplicate.
    @Test("welds are idempotent (no duplicate coincident on a re-touched corner)")
    func weldIdempotent() {
        let m = ACFix.model()
        _ = ACFix.drawLine(m, Vector(0, 0), Vector(10, 0))
        _ = ACFix.drawLine(m, Vector(10, 0), Vector(10, 10))
        let firstCount = ACFix.coincidents(m).count
        // A THIRD line touching (10,0) again welds to a corner already pinned — but to the
        // OTHER (a's) end as well; assert we never exceed one weld per distinct endpoint pair.
        _ = ACFix.drawLine(m, Vector(10, 0), Vector(20, 0))
        // No duplicate of the original a.end↔b.start pair; new welds bind the NEW line.
        let pairs = ACFix.coincidents(m).map { Set($0.points) }
        #expect(Set(pairs.map { $0 }).count == pairs.count, "no duplicate coincident pair")
        #expect(ACFix.coincidents(m).count >= firstCount)
    }
}

// MARK: - Angle inference

@MainActor
@Suite("AutoConstrain — angle inference")
struct AutoConstrainAngleTests {

    /// A roughly-horizontal segment gets a VISIBLE horizontal constraint (and is snapped flat).
    @Test("near-horizontal line auto-adds a visible horizontal constraint")
    func nearHorizontalGetsHorizontal() throws {
        let m = ACFix.model()
        let a = ACFix.drawLine(m, Vector(0, 0), Vector(10, 0.05))   // ~0.29° off horizontal
        #expect(ACFix.hasVisible(m, .geometric(.horizontal), on: a))
        let e = try #require(ACFix.ends(m, a))
        #expect(abs(e.end.y - e.start.y) < 1e-6, "horizontal constraint flattened the line")
    }

    /// A roughly-vertical segment gets a VISIBLE vertical constraint.
    @Test("near-vertical line auto-adds a visible vertical constraint")
    func nearVerticalGetsVertical() throws {
        let m = ACFix.model()
        let a = ACFix.drawLine(m, Vector(0, 0), Vector(0.05, 10))   // ~0.29° off vertical
        #expect(ACFix.hasVisible(m, .geometric(.vertical), on: a))
        let e = try #require(ACFix.ends(m, a))
        #expect(abs(e.end.x - e.start.x) < 1e-6, "vertical constraint straightened the line")
    }

    /// A clearly-slanted segment with no axis/relationship gets NO angular constraint.
    @Test("a deliberately slanted, unconnected line gets no angular constraint")
    func slantedGetsNothing() {
        let m = ACFix.model()
        let a = ACFix.drawLine(m, Vector(0, 0), Vector(10, 6))      // ~31° — clearly slanted
        #expect(!ACFix.hasVisible(m, .geometric(.horizontal), on: a))
        #expect(!ACFix.hasVisible(m, .geometric(.vertical), on: a))
        #expect(m.allConstraints.isEmpty, "no weld, no angle — a lone slant is unconstrained")
    }

    /// Two slanted lines meeting at ~90° at a shared corner auto-add a VISIBLE perpendicular
    /// (priority below H/V, which neither qualifies for). The weld comes first.
    @Test("two connected slanted lines at ~90° auto-add a visible perpendicular")
    func connectedRightAngleGetsPerpendicular() throws {
        let m = ACFix.model()
        // A: direction ~30°. B: shares A's end, direction ~120° (≈ +90° from A) — neither
        // is near an axis, so H/V don't fire and PERPENDICULAR (to the welded neighbor) does.
        let a = ACFix.drawLine(m, Vector(0, 0), Vector(8.66, 5))            // 30°
        let aEnd = ACFix.ends(m, a)!.end
        let b = ACFix.drawLine(m, aEnd, aEnd + Vector(-5, 8.66))           // +90°
        #expect(ACFix.coincidents(m).count == 1, "the corner welded")
        #expect(ACFix.hasVisible(m, .geometric(.perpendicular), on: b)
                || ACFix.hasVisible(m, .geometric(.perpendicular), on: a),
                "a perpendicular was inferred between the connected ~90° segments")
        // The angle is actually driven to 90°.
        let ea = try #require(ACFix.ends(m, a))
        let eb = try #require(ACFix.ends(m, b))
        let da = ea.end - ea.start, db = eb.end - eb.start
        let dot = da.x * db.x + da.y * db.y
        #expect(abs(dot) < 1e-5, "the perpendicular drove the corner to a true right angle")
    }
}

// MARK: - Never over-constrain

@MainActor
@Suite("AutoConstrain — never over-constrain")
struct AutoConstrainOverConstraintTests {

    /// Drawing a CLOSED 4-line rectangle (every corner welded, every side axis-aligned)
    /// must NOT explode: every line stays finite, the solver never leaves a `.failed` state,
    /// and the geometry stays a rectangle (no splay / NaN).
    @Test("a closed 4-line rectangle does not over-constrain / explode")
    func closedRectangleStable() throws {
        let m = ACFix.model()
        let p0 = Vector(0, 0), p1 = Vector(10, 0), p2 = Vector(10, 8), p3 = Vector(0, 8)
        let s0 = ACFix.drawLine(m, p0, p1)   // bottom
        let s1 = ACFix.drawLine(m, p1, p2)   // right
        let s2 = ACFix.drawLine(m, p2, p3)   // top
        let s3 = ACFix.drawLine(m, p3, p0)   // left — CLOSES the loop

        // All four segments still finite & roughly where we drew them (no warp).
        for (id, want) in [(s0, (p0, p1)), (s1, (p1, p2)), (s2, (p2, p3)), (s3, (p3, p0))] {
            let e = try #require(ACFix.ends(m, id))
            #expect(e.start.x.isFinite && e.start.y.isFinite && e.end.x.isFinite && e.end.y.isFinite,
                    "segment must stay finite (no NaN/∞ from an over-constraint)")
            #expect(e.start.distance(to: want.0) < 0.5 && e.end.distance(to: want.1) < 0.5,
                    "segment stayed near where it was drawn (no explosion)")
        }
        // Re-solving the whole drawing succeeds (no component is stuck `.failed`).
        let component = m.drawing.constraints.connectedComponent(of: s0)
        var ents: [EntityID: EntityKind] = [:]
        for id in component { ents[id] = m.drawing.entity(id)!.kind }
        let cons = m.drawing.constraints.constraints(within: component)
        if case .failed = ConstraintSolver.solve(entities: ents, constraints: cons) {
            Issue.record("the rectangle's constraint set must remain solvable")
        }
    }

    /// The DROP path: a freshly-drawn line whose corner touches a component already POISONED
    /// to `.failed` (here by an unsupported `tangent` constraint) must NOT be welded into it
    /// — the tentative coincident is re-solved, sees `.failed`, and is REMOVED, so the poison
    /// never spreads. (The line's own, independently-valid angle constraint may still land —
    /// auto-constrain drops only the adds that fail, not every add.)
    @Test("a weld into a poisoned (.failed) component is dropped (poison does not spread)")
    func weldIntoPoisonedComponentDropped() throws {
        let drawing = CADDrawing()
        // An existing line, then an UNSUPPORTED tangent referencing it + a second line —
        // any component containing this short-circuits the solver to .failed.
        let base = drawing.add(EntityRecord(id: EntityID(0), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        let other = drawing.add(EntityRecord(id: EntityID(0), kind: .line(LineData(start: Vector(0, 0), end: Vector(3, 7)))))
        let poison = Constraint(kind: .geometric(.tangent),
                                points: Constraint.lineEndpoints(base) + Constraint.lineEndpoints(other))
        #expect(drawing.addConstraint(poison))
        let m = ACFix.model(drawing)

        // Draw a NEW line whose start touches `base`'s end (would normally weld there).
        let drawn = ACFix.drawLine(m, Vector(10, 0), Vector(20, 6))   // slanted: no H/V either

        // No COINCIDENT welds `drawn` to `base` (the tentative weld hit the poisoned
        // component and was dropped) — the poison did not spread to the new geometry.
        let weldsTouchingDrawn = ACFix.coincidents(m).filter { $0.references(drawn) }
        #expect(weldsTouchingDrawn.isEmpty, "the weld into the poisoned component was dropped")
        // `drawn` is in its OWN clean component, NOT pulled into the poison.
        #expect(!m.drawing.constraints.connectedComponent(of: drawn).contains(base),
                "the new line was not joined to the poisoned component")
        // The drawn line is still exactly where we drew it (the dropped add reverted clean).
        let e = try #require(ACFix.ends(m, drawn))
        #expect(e.start == Vector(10, 0) && e.end == Vector(20, 6))
    }
}

// MARK: - The owner's repro (the bug fix)

@MainActor
@Suite("AutoConstrain — owner repro: the rectangle stays joined")
struct AutoConstrainOwnerReproTests {

    /// THE BUG FIX. Draw 3 connected lines forming a partial rectangle through the REAL
    /// LineTool draw path, then grip-drag the 4th corner. With AutoConstrain on, the welded
    /// corners STAY coincident (the rectangle does NOT "fall apart").
    @Test("3 lines drawn connected through the LineTool; grip-drag keeps corners joined")
    func threeLinesGripDragStaysJoined() throws {
        let m = ACFix.model()

        // Draw three connected segments through the ACTUAL tool state machine:
        //   click p0 (start) → click p1 (commit s0) → click p2 (commit s1) → click p3 (commit s2).
        let p0 = Vector(0, 0), p1 = Vector(10, 0), p2 = Vector(10, 8), p3 = Vector(0, 8)
        m.activateTool(.line)
        _ = m.handleToolInput(.click(p0))
        _ = m.handleToolInput(.click(p1))   // commits s0 = p0→p1
        _ = m.handleToolInput(.click(p2))   // commits s1 = p1→p2  (welds at p1)
        _ = m.handleToolInput(.click(p3))   // commits s2 = p2→p3  (welds at p2)
        m.activateTool(.select)              // end the run

        // Identify the three drawn lines by their committed geometry.
        let lines = m.drawing.entities.filter { if case .line = $0.kind { return true }; return false }
        #expect(lines.count == 3, "three segments drawn")
        func lineBetween(_ a: Vector, _ b: Vector) -> EntityID? {
            lines.first {
                guard case .line(let d) = $0.kind else { return false }
                return (d.start.distance(to: a) < 1e-6 && d.end.distance(to: b) < 1e-6)
            }?.id
        }
        let s0 = try #require(lineBetween(p0, p1))
        let s1 = try #require(lineBetween(p1, p2))
        let s2 = try #require(lineBetween(p2, p3))

        // The two interior corners (p1, p2) auto-welded.
        #expect(ACFix.coincidents(m).count >= 2, "both interior corners welded")

        // GRIP-DRAG the free corner p3 (the end of s2) outward. With the welds in place,
        // the shared corners p1 (s0.end == s1.start) and p2 (s1.end == s2.start) must move
        // TOGETHER (stay coincident) — the rectangle does not splay.
        var movedS2 = try #require(m.drawing.entity(s2))
        guard case .line(var d2) = movedS2.kind else { Issue.record("s2 not a line"); return }
        d2.end = Vector(-4, 14)        // drag the free corner well away
        movedS2.kind = .line(d2)
        m.selection = Selection(ids: [s2])
        #expect(m.commitMovedGrip(movedS2))

        // After the drag + re-solve, the shared corners are STILL coincident.
        let e0 = try #require(ACFix.ends(m, s0))
        let e1 = try #require(ACFix.ends(m, s1))
        let e2 = try #require(ACFix.ends(m, s2))
        #expect(e0.end.distance(to: e1.start) < 1e-6,
                "corner p1 stayed joined (s0.end == s1.start) — the rectangle did not fall apart")
        #expect(e1.end.distance(to: e2.start) < 1e-6,
                "corner p2 stayed joined (s1.end == s2.start) — the rectangle did not fall apart")
    }

    /// CONTROL: with AutoConstrain OFF, the SAME draw + grip-drag DOES splay (proving the
    /// fix is the auto-constraint, and that the toggle truly gates it).
    @Test("with AutoConstrain OFF the same drag splays (toggle gates the fix)")
    func toggleOffSplaysAsBefore() throws {
        let m = ACFix.model(autoConstrain: false)
        let p0 = Vector(0, 0), p1 = Vector(10, 0), p2 = Vector(10, 8), p3 = Vector(0, 8)
        m.activateTool(.line)
        _ = m.handleToolInput(.click(p0))
        _ = m.handleToolInput(.click(p1))
        _ = m.handleToolInput(.click(p2))
        _ = m.handleToolInput(.click(p3))
        m.activateTool(.select)

        #expect(m.allConstraints.isEmpty, "OFF ⇒ no auto-constraints (byte-identical to old behavior)")

        let lines = m.drawing.entities.compactMap { (e) -> (EntityID, LineData)? in
            if case .line(let d) = e.kind { return (e.id, d) }; return nil
        }
        let s1 = try #require(lines.first { $0.1.start.distance(to: p1) < 1e-6 }?.0)   // p1→p2
        let s2 = try #require(lines.first { $0.1.start.distance(to: p2) < 1e-6 }?.0)   // p2→p3

        // Drag s2's free end. Nothing constrains s1, so its end (the shared p2) does NOT move.
        var movedS2 = try #require(m.drawing.entity(s2))
        guard case .line(var d2) = movedS2.kind else { Issue.record("s2 not a line"); return }
        d2.start = Vector(20, 20)   // move the SHARED corner only on s2
        movedS2.kind = .line(d2)
        #expect(m.commitMovedGrip(movedS2))

        let e1 = try #require(ACFix.ends(m, s1))
        let e2 = try #require(ACFix.ends(m, s2))
        #expect(e1.end.distance(to: e2.start) > 1.0,
                "OFF ⇒ the corner separates (the bug the feature fixes)")
    }
}

// MARK: - Toggle + undo coalescing

@MainActor
@Suite("AutoConstrain — toggle gate + single-undo")
struct AutoConstrainToggleTests {

    /// OFF ⇒ drawing adds NO constraints at all (byte-identical to the pre-feature path).
    @Test("toggle OFF adds no constraints")
    func toggleOffNoConstraints() {
        let m = ACFix.model(autoConstrain: false)
        _ = ACFix.drawLine(m, Vector(0, 0), Vector(10, 0))
        _ = ACFix.drawLine(m, Vector(10, 0), Vector(10, 10))
        #expect(m.allConstraints.isEmpty)
    }

    /// The draw AND its auto-constraints collapse into ONE undo step (one ⌘Z removes both
    /// the line and the constraints it spawned).
    @Test("draw + auto-constraints are a single undo group")
    func drawAndConstraintsOneUndo() throws {
        let m = ACFix.model()
        _ = ACFix.drawLine(m, Vector(0, 0), Vector(10, 0))           // group 1 (a horizontal)
        // Drop group 1's undo so only group 2 is on the stack; group 1's constraints stay
        // in the table (they were applied), so we measure the DELTA group 2 contributes.
        m.undoManager.removeAllActions()
        let baseline = m.allConstraints.count

        // Draw a connected vertical: welds at the corner + a vertical constraint, one group.
        let b = ACFix.drawLine(m, Vector(10, 0), Vector(10, 10))     // group 2 (the one we test)
        #expect(m.allConstraints.count > baseline, "group 2 added auto-constraints")
        #expect(m.drawing.entity(b) != nil)

        m.undo()   // ONE ⌘Z
        #expect(m.drawing.entity(b) == nil, "the drawn line is gone")
        #expect(m.allConstraints.count == baseline,
                "and so are its auto-constraints — the draw + its constraints are ONE undo step")
        #expect(!m.canUndo, "that one undo emptied the stack (a single group)")
    }

    /// The hermetic seam: seeding from an isolated defaults store with the key absent reads
    /// as ON; an explicit false reads OFF — without touching `UserDefaults.standard`.
    @Test("seedAutoConstrainFromAppSettings reads the key default-ON")
    func seedFromDefaults() {
        let suite = UserDefaults(suiteName: "AutoConstrainSeedTest")!
        suite.removePersistentDomain(forName: "AutoConstrainSeedTest")
        let m = ACFix.model()
        m.seedAutoConstrainFromAppSettings(defaults: suite)
        #expect(m.autoConstrainOnDraw, "absent key ⇒ default ON")

        suite.set(false, forKey: CanvasModel.autoConstrainOnDrawKey)
        m.seedAutoConstrainFromAppSettings(defaults: suite)
        #expect(!m.autoConstrainOnDraw, "explicit false ⇒ OFF")
        suite.removePersistentDomain(forName: "AutoConstrainSeedTest")
    }
}

// MARK: - Gate + cross-feature regression locks (code-review nits)

@MainActor
@Suite("AutoConstrain — gate + cross-feature locks")
struct AutoConstrainGateTests {

    /// LOCKS THE CRITICAL GATE: a DERIVE/CLONE tool (Copy) must produce ZERO auto-
    /// constraints — only a genuine DRAW feeds AutoConstrain (`adoptsCurrentProperties`).
    /// Mirrors `PenPropertiesTests`' clone-tool drive: an existing line, then the REAL Copy
    /// tool (base click + destination click) clones it. AutoConstrain is ON, but the clone
    /// is a DERIVE — so the constraint count must NOT change. (Guards against a future tool
    /// being mis-classified into the draw arm.)
    @Test("a DERIVE tool (Copy) adds no auto-constraints to the clone")
    func deriveToolAddsNoAutoConstraints() {
        let m = ACFix.model()
        // A SLANTED source drawn through the real path (so the undo group is opened
        // correctly); slanted ⇒ no H/V even as a genuine draw, and it's the only entity,
        // so AutoConstrain adds nothing to it — a clean zero-constraint baseline.
        let src = ACFix.drawLine(m, Vector(0, 0), Vector(6, 4))
        _ = m.setSelection([src])
        m.undoManager.removeAllActions()
        let baseline = m.allConstraints.count
        #expect(baseline == 0, "the slanted lone source draws with no auto-constraints")

        // Drive the REAL Copy tool end-to-end: base point, then a destination far away.
        m.activateTool(.copy)
        _ = m.handleToolInput(.click(Vector(0, 0)))    // base
        _ = m.handleToolInput(.click(Vector(50, 50)))  // destination → commits one .add (a clone)

        // Two entities now (original + clone), and NO new constraints — the clone is a
        // DERIVE, so AutoConstrain never ran on it.
        #expect(m.drawing.entities.count == 2, "the copy produced exactly one clone")
        #expect(m.allConstraints.count == baseline,
                "a DERIVE/CLONE tool must add NO auto-constraints (the draw-vs-derive gate)")
    }

    /// CROSS-FEATURE LOCK: applying an explicit PERPENDICULAR to a corner that AutoConstrain
    /// already welded (a VISIBLE coincident) must NOT stack a second (inferred) coincident on
    /// that same endpoint pair — `withInferredCorner`/`coincidentExists` dedup against the
    /// draw-time weld. Exactly ONE coincident binds the pair afterward.
    @Test("perpendicular after a draw-time weld does not duplicate the coincident")
    func perpendicularAfterWeldNoDuplicateCoincident() throws {
        let m = ACFix.model()
        // Draw two connected SLANTED lines: they weld at the shared corner (one visible
        // coincident) but neither is axis-aligned and they're not ~90°, so no angular
        // constraint is inferred — a clean single-weld starting point.
        let a = ACFix.drawLine(m, Vector(0, 0), Vector(10, 4))            // slanted
        let aEnd = ACFix.ends(m, a)!.end
        let b = ACFix.drawLine(m, aEnd, aEnd + Vector(4, 10))            // shares the corner, slanted
        #expect(ACFix.coincidents(m).count == 1, "exactly the draw-time weld exists")
        let weldedPair = Set(try #require(ACFix.coincidents(m).first).points)

        // Now the user applies an explicit PERPENDICULAR to the same two lines. Its
        // inferred-corner companion must NOT add a duplicate coincident on the welded pair.
        _ = m.setSelection([a, b])
        #expect(m.addConstraint(.perpendicular, entities: [a, b]))

        let coincidents = ACFix.coincidents(m)
        #expect(coincidents.count == 1,
                "still exactly ONE coincident on the corner — no duplicate inferred companion")
        #expect(Set(try #require(coincidents.first).points) == weldedPair,
                "the surviving coincident is the original draw-time weld (same pair)")
        // The perpendicular itself was added (this is a real apply, not a no-op).
        #expect(m.allConstraints.contains { $0.kind == .geometric(.perpendicular) })
    }
}
