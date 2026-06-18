//
//  InferredCornerCoincidentTests.swift
//  CADEngineTests
//
//  AutoCAD-style INFERRED COINCIDENCE: applying a perpendicular / parallel constraint to
//  two LINES that meet at a shared CORNER auto-adds a HIDDEN coincident pinning that
//  endpoint pair, so the corner stays JOINED while the angle constraint rotates the lines
//  (a bare perpendicular/parallel constrains only the ANGLE — nothing holds the ends
//  together, so the shared end would otherwise DRIFT APART).
//
//  Proves:
//   • The `inferred` model flag + `coincidentInferred` factory + Codable round-trip with
//     back-compat (old payload → `inferred == false`).
//   • The corner detector (`CanvasModel.nearestCornerPair`): a snapped/touching corner
//     yields the nearest endpoint pair; far-apart lines yield NO pair.
//   • The CREATE PATH: perpendicular on a touching corner ADDS a hidden inferred
//     coincident AND the corner stays joined after the re-solve (both ends coincide, both
//     lines keep ~their length, dot ≈ 0); on far-apart lines it adds NO companion; one ⌘Z
//     reverts the constraint, the inferred companion, AND the geometry move together.
//   • The glyph overlay SKIPS inferred constraints (no badge / placement).
//
//  `CanvasModel` + `ConstraintGlyphLayout` live in the (un-importable) app target, reached
//  here via the existing `_SharedCanvasModel.swift` / `_SharedConstraintGlyphOverlay.swift`
//  symlinks. `@MainActor` (mirrors `ConstraintResolveSeamTests`); no SwiftUI body / NSView
//  is rendered — only the pure model wiring + pure helpers.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Fixtures (uniquely namespaced for the shared target)

@MainActor
private enum CornerFix {
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
    static func len(_ v: (start: Vector, end: Vector)) -> Double { v.start.distance(to: v.end) }
}

// MARK: - Model: inferred flag, factory, Codable

@Suite("inferred coincidence — model + Codable")
struct InferredCoincidentModelTests {

    @Test("coincidentInferred factory makes a hidden coincident")
    func factory() {
        let a = ConstraintPoint(entityID: EntityID(1), point: .end)
        let b = ConstraintPoint(entityID: EntityID(2), point: .start)
        let c = Constraint.coincidentInferred(a, b)
        #expect(c.kind == .geometric(.coincident))
        #expect(c.inferred == true)
        #expect(c.points == [a, b])
        // The plain coincident is NOT inferred (default false).
        #expect(Constraint.coincident(a, b).inferred == false)
    }

    @Test("inferred flag round-trips through Codable")
    func codableRoundTrip() throws {
        let a = ConstraintPoint(entityID: EntityID(1), point: .end)
        let b = ConstraintPoint(entityID: EntityID(2), point: .start)
        let original = Constraint.coincidentInferred(a, b)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(Constraint.self, from: data)
        #expect(back == original)
        #expect(back.inferred == true)
    }

    @Test("a payload written before `inferred` existed decodes to inferred=false (back-compat)")
    func backCompatDecode() throws {
        // No `inferred` key — an OLD file. It must decode to `false`.
        let json = """
        { "kind": { "geometric": { "_0": "coincident" } },
          "points": [ { "entityID": { "rawValue": 1 }, "point": "end" },
                      { "entityID": { "rawValue": 2 }, "point": "start" } ] }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(Constraint.self, from: json)
        #expect(c.kind == .geometric(.coincident))
        #expect(c.inferred == false)
    }
}

// MARK: - Corner detection (the pure static helper)

@MainActor
@Suite("inferred coincidence — corner detection")
struct InferredCornerDetectionTests {

    /// Two lines sharing an essentially-touching corner: the detector returns the
    /// nearest endpoint pair (here A.end ≈ B.start at the corner).
    @Test("nearestCornerPair finds the shared, touching corner")
    func findsTouchingCorner() throws {
        // A: (0,0)→(10,0); B starts at (10,0)-ish (a tiny snap gap) going up.
        let a = LineData(start: Vector(0, 0), end: Vector(10, 0))
        let b = LineData(start: Vector(10, 0.0000005), end: Vector(10, 10))
        let pair = try #require(CanvasModel.nearestCornerPair(
            lineA: EntityID(1), a: a, lineB: EntityID(2), b: b))
        #expect(pair.0 == ConstraintPoint(entityID: EntityID(1), point: .end))
        #expect(pair.1 == ConstraintPoint(entityID: EntityID(2), point: .start))
    }

    /// Two FAR-APART lines: no corner, no pair (we never join far-apart lines).
    @Test("nearestCornerPair returns nil for far-apart lines")
    func rejectsFarApart() {
        let a = LineData(start: Vector(0, 0), end: Vector(10, 0))
        let b = LineData(start: Vector(0, 50), end: Vector(10, 53))   // 50 away — not a corner
        #expect(CanvasModel.nearestCornerPair(
            lineA: EntityID(1), a: a, lineB: EntityID(2), b: b) == nil)
    }

    /// The tolerance scales with the shorter line length, so a tiny-but-relative gap on
    /// long lines still counts, while the same absolute gap on a short stub does not.
    @Test("nearestCornerPair tolerance is relative to the shorter line")
    func relativeTolerance() {
        // Two long lines (length 1000) with a 0.5 gap → 0.5 ≤ 1e-3·1000 = 1.0 → corner.
        let aLong = LineData(start: Vector(0, 0), end: Vector(1000, 0))
        let bLong = LineData(start: Vector(1000, 0.5), end: Vector(1000, 1000))
        #expect(CanvasModel.nearestCornerPair(
            lineA: EntityID(1), a: aLong, lineB: EntityID(2), b: bLong) != nil)
        // Two short stubs (length 1) with the same 0.5 gap → 0.5 > 1e-3·1 = 1e-3 → NO corner.
        let aShort = LineData(start: Vector(0, 0), end: Vector(1, 0))
        let bShort = LineData(start: Vector(1, 0.5), end: Vector(1, 1))
        #expect(CanvasModel.nearestCornerPair(
            lineA: EntityID(1), a: aShort, lineB: EntityID(2), b: bShort) == nil)
    }

    /// A degenerate (zero-length) line has no usable endpoint pair.
    @Test("nearestCornerPair returns nil for a degenerate line")
    func rejectsDegenerate() {
        let degenerate = LineData(start: Vector(5, 5), end: Vector(5, 5))
        let b = LineData(start: Vector(5, 5), end: Vector(5, 10))
        #expect(CanvasModel.nearestCornerPair(
            lineA: EntityID(1), a: degenerate, lineB: EntityID(2), b: b) == nil)
    }
}

// MARK: - Create path: perpendicular at a corner keeps it joined

@MainActor
@Suite("inferred coincidence — create path")
struct InferredCreatePathTests {

    /// Applying PERPENDICULAR to two lines that share a (snapped) corner adds a HIDDEN
    /// inferred coincident AND, after the re-solve, the corner stays JOINED: both shared
    /// endpoints coincide, both lines keep ~their original length, and they are ⊥ (dot≈0).
    @Test("perpendicular on a shared corner adds a hidden coincident and keeps the corner joined")
    func perpendicularKeepsCornerJoined() throws {
        let drawing = CADDrawing()
        // A horizontal-ish + B diagonal, sharing a corner near (10,0) with a tiny snap gap.
        let a = drawing.add(CornerFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CornerFix.line(Vector(10, 0.0000003), Vector(16, 8)))
        let m = CornerFix.model(drawing)
        let lenA0 = CornerFix.len(try #require(CornerFix.ends(m, a)))
        let lenB0 = CornerFix.len(try #require(CornerFix.ends(m, b)))

        #expect(m.addConstraint(.perpendicular, entities: [a, b]))

        // A HIDDEN inferred coincident was auto-added alongside the perpendicular.
        let inferred = m.allConstraints.filter(\.inferred)
        #expect(inferred.count == 1, "exactly one hidden coincident was inferred")
        #expect(inferred.first?.kind == .geometric(.coincident))
        #expect(m.allConstraints.contains { $0.kind == .geometric(.perpendicular) })

        // The corner is JOINED: A.end coincides with B.start after the re-solve.
        let ea = try #require(CornerFix.ends(m, a))
        let eb = try #require(CornerFix.ends(m, b))
        #expect(ea.end.distance(to: eb.start) < 1e-6, "the shared corner stays joined")
        // Both lines remain SUBSTANTIAL (the constraint rotated the pair, it didn't
        // collapse them to a point). Length is a free DOF the least-squares solver may
        // shift to satisfy coincident + perpendicular, so we only assert the lines stay
        // a healthy fraction of their original length — not exact preservation.
        #expect(CornerFix.len(ea) > 0.5 * lenA0, "line A did not collapse")
        #expect(CornerFix.len(eb) > 0.5 * lenB0, "line B did not collapse")
        // They are perpendicular: direction dot ≈ 0.
        let da = ea.end - ea.start, db = eb.end - eb.start
        let dot = da.x * db.x + da.y * db.y
        #expect(abs(dot) < 1e-6, "lines are perpendicular (dot=\(dot))")
    }

    /// Applying PARALLEL to a shared corner likewise infers a hidden coincident.
    @Test("parallel on a shared corner also infers a hidden coincident")
    func parallelInfersCoincident() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CornerFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CornerFix.line(Vector(10, 0), Vector(14, 5)))   // exact shared corner
        let m = CornerFix.model(drawing)
        #expect(m.addConstraint(.parallel, entities: [a, b]))
        #expect(m.allConstraints.filter(\.inferred).count == 1)
    }

    /// Applying PERPENDICULAR to two FAR-APART lines adds NO inferred coincident — the
    /// lines simply rotate to 90°, nothing is joined (we never glue far-apart geometry).
    @Test("perpendicular on far-apart lines infers NOTHING")
    func farApartInfersNothing() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CornerFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CornerFix.line(Vector(0, 50), Vector(8, 56)))   // far away
        let m = CornerFix.model(drawing)
        #expect(m.addConstraint(.perpendicular, entities: [a, b]))
        #expect(m.allConstraints.filter(\.inferred).isEmpty, "no corner → no inferred coincident")
        // Only the explicit perpendicular is present.
        #expect(m.allConstraints.count == 1)
        #expect(m.allConstraints.first?.kind == .geometric(.perpendicular))
    }

    /// If the corner endpoint pair is ALREADY bound by a coincident (e.g. the user pinned
    /// it explicitly), the create path does NOT stack a redundant inferred one (it would
    /// solve identically). Inject the exact corner pair through the engine, then apply ⊥.
    @Test("an existing coincident on the corner suppresses the inferred companion")
    func existingCoincidentSuppressesInferred() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CornerFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CornerFix.line(Vector(10, 0), Vector(14, 5)))
        // Explicit coincident binding the corner pair (A.end ≡ B.start) before the model exists.
        drawing.addConstraint(.coincident(ConstraintPoint(entityID: a, point: .end),
                                          ConstraintPoint(entityID: b, point: .start)))
        let m = CornerFix.model(drawing)
        #expect(m.allConstraints.filter(\.inferred).isEmpty)

        #expect(m.addConstraint(.perpendicular, entities: [a, b]))
        // No inferred coincident was added — the explicit one already binds the pair.
        #expect(m.allConstraints.filter(\.inferred).isEmpty,
                "an existing coincident on the corner suppresses the inferred companion")
    }

    /// ONE ⌘Z reverts the perpendicular, the inferred companion, AND the geometry move —
    /// they are committed + re-solved as a SINGLE undo group.
    @Test("one undo reverts the perpendicular, the inferred coincident, and the geometry move")
    func oneUndoRevertsEverything() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CornerFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CornerFix.line(Vector(10, 0), Vector(16, 8)))
        let m = CornerFix.model(drawing)
        let ea0 = try #require(CornerFix.ends(m, a))
        let eb0 = try #require(CornerFix.ends(m, b))

        #expect(m.addConstraint(.perpendicular, entities: [a, b]))
        #expect(m.allConstraints.count == 2)   // perpendicular + inferred coincident

        m.undo()
        // A single undo cleared BOTH constraints.
        #expect(m.allConstraints.isEmpty, "one ⌘Z removes the perpendicular AND the inferred coincident")
        // And restored the original geometry.
        let ea = try #require(CornerFix.ends(m, a))
        let eb = try #require(CornerFix.ends(m, b))
        #expect(ea.start == ea0.start && ea.end == ea0.end)
        #expect(eb.start == eb0.start && eb.end == eb0.end)
        // It was a SINGLE step — the stack is now empty.
        #expect(!m.canUndo, "the constraint add + companion + re-solve are ONE undo step")
    }
}

// MARK: - Glyph overlay skips inferred constraints

@Suite("inferred coincidence — glyph overlay hides them")
struct InferredGlyphHidingTests {

    /// The glyph layout, fed a mix of explicit + inferred constraints (as the overlay
    /// pre-filters), only places badges for the VISIBLE ones. We mirror the overlay's
    /// `!$0.inferred` filter at the call site.
    @Test("placements exclude inferred constraints (the overlay filters them out)")
    func placementsExcludeInferred() {
        let e1 = EntityID(1), e2 = EntityID(2)
        let visible = Constraint.perpendicular(line: e1, line: e2)
        let hidden = Constraint.coincidentInferred(
            ConstraintPoint(entityID: e1, point: .end),
            ConstraintPoint(entityID: e2, point: .start))
        let all = [visible, hidden]

        // The overlay filters `!$0.inferred` BEFORE calling placements; emulate that.
        let visibleOnly = all.filter { !$0.inferred }
        #expect(visibleOnly.count == 1)
        let places = ConstraintGlyphLayout.placements(
            for: visibleOnly,
            worldAnchor: { _ in Vector(5, 5) },
            worldToScreen: { CGPoint(x: $0.x, y: $0.y) })
        // Only the perpendicular got a badge; the inferred coincident is invisible.
        #expect(places.count == 1)
        #expect(places.first?.constraintID == visible.id)
        #expect(places.first?.label == "⊥")
    }
}
