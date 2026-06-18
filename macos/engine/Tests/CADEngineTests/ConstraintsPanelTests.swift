//
//  ConstraintsPanelTests.swift
//  CADEngineTests
//
//  Lane C — the CONSTRAINTS GUI (the owner's ask #3: "add gui to handle them. currently
//  they are hard to find in the menu"). Proves the two layers the panel is built on:
//
//   • The PURE list logic (`ConstraintListModel`, the SwiftUI-free helper backing the
//     panel + the Inspector section): grouping by category, the "selection only" filter,
//     the row text (kind name / reference description / driven value), and the
//     click-to-select target — each exercised on plain value inputs, no view rendered.
//   • The MODEL wiring the panel's actions funnel through (`CanvasModel`): per-row DELETE
//     restores on one ⌘Z; the selection-filter returns the right subset against a live
//     drawing; click-to-select sets the selection; and the Lane-C live-apply re-seed of
//     the AutoConstrain flag.
//
//  `CanvasModel` lives in the (un-importable) app target, reached here via the existing
//  `_SharedCanvasModel.swift` symlink; the pure list helpers via the new
//  `_SharedConstraintsSidebar.swift` symlink; the glyph mapping via
//  `_SharedConstraintGlyphOverlay.swift`. No SwiftUI body / NSView is rendered — only
//  pure helpers + the pure model wiring (the SwiftUI views stay thin + untested, per the
//  project's test discipline).
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
private enum CFix {
    static func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }
    static func circle(_ c: Vector, _ r: Double, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .circle(CircleData(center: c, radius: r)))
    }

    /// A model with a clean, manually-grouped undo stack (so one explicit group == one ⌘Z).
    static func model(_ drawing: CADDrawing) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }
}

// MARK: - Pure list logic (ConstraintListModel)

@Suite("Lane C — ConstraintListModel pure list logic")
struct ConstraintListModelTests {

    private let a = EntityID(1)
    private let b = EntityID(2)
    private let c = EntityID(3)

    /// A geometric + a dimensional constraint, plus an inferred one (which must be hidden).
    private func fixtures() -> [Constraint] {
        [
            .horizontal(line: a),                                   // geometric
            .parallel(line: a, line: b),                            // geometric (2 entities)
            .distance(ConstraintPoint(entityID: a), ConstraintPoint(entityID: b), value: 10),  // dimensional
            .radius(circle: c, value: 5),                           // dimensional
            .coincidentInferred(ConstraintPoint(entityID: a, point: .end),
                                ConstraintPoint(entityID: b, point: .start)),  // inferred → hidden
        ]
    }

    @Test("grouping splits geometric vs dimensional and hides inferred")
    func grouping() {
        let all = fixtures()
        let geo = ConstraintListModel.constraints(in: .geometric, from: all)
        let dim = ConstraintListModel.constraints(in: .dimensional, from: all)
        #expect(geo.count == 2, "horizontal + parallel (the inferred coincident is hidden)")
        #expect(dim.count == 2, "distance + radius")
        // The inferred one appears in NEITHER visible group.
        #expect(!geo.contains { $0.inferred })
        #expect(!dim.contains { $0.inferred })
        // includeInferred surfaces it (for a future "show hidden" affordance).
        #expect(ConstraintListModel.constraints(in: .geometric, from: all,
                                                includeInferred: true).count == 3)
    }

    @Test("hasVisibleConstraints ignores inferred-only lists")
    func hasVisible() {
        #expect(ConstraintListModel.hasVisibleConstraints(fixtures()))
        let inferredOnly: [Constraint] = [
            .coincidentInferred(ConstraintPoint(entityID: a), ConstraintPoint(entityID: b))
        ]
        #expect(!ConstraintListModel.hasVisibleConstraints(inferredOnly))
        #expect(!ConstraintListModel.hasVisibleConstraints([]))
    }

    @Test("selection filter returns only constraints referencing the selection")
    func selectionFilter() {
        let all = fixtures()
        // Selecting `c` (the circle) → only its radius constraint.
        let onC = ConstraintListModel.referencingSelection(all, selectionIDs: [c])
        #expect(onC.count == 1)
        #expect(onC.first.map { ConstraintListModel.Category.of($0) } == .dimensional)

        // Selecting `a` → horizontal(a) + parallel(a,b) + distance(a,b); inferred hidden.
        let onA = ConstraintListModel.referencingSelection(all, selectionIDs: [a])
        #expect(onA.count == 3)
        #expect(!onA.contains { $0.inferred })

        // Empty selection → empty result (the filter has nothing to scope to).
        #expect(ConstraintListModel.referencingSelection(all, selectionIDs: []).isEmpty)
    }

    @Test("displayed honors the selection-only toggle")
    func displayed() {
        let all = fixtures()
        // Off → every VISIBLE constraint (4; the inferred one excluded).
        #expect(ConstraintListModel.displayed(all, selectionIDs: [a], selectionOnly: false).count == 4)
        // On → only those on the selection.
        #expect(ConstraintListModel.displayed(all, selectionIDs: [c], selectionOnly: true).count == 1)
    }

    @Test("selectionTarget is the distinct referenced entities")
    func selectionTarget() {
        let parallel = Constraint.parallel(line: a, line: b)
        #expect(ConstraintListModel.selectionTarget(for: parallel) == [a, b])
        let radius = Constraint.radius(circle: c, value: 5)
        #expect(ConstraintListModel.selectionTarget(for: radius) == [c])
    }

    @Test("displayName gives a readable word per kind")
    func displayName() {
        #expect(ConstraintListModel.displayName(for: .geometric(.perpendicular)) == "Perpendicular")
        #expect(ConstraintListModel.displayName(for: .dimensional(.distance)) == "Distance")
        #expect(ConstraintListModel.displayName(for: .dimensional(.horizontalDistance)) == "Horizontal Distance")
    }

    @Test("referenceDescription names the entities / point roles")
    func referenceDescription() {
        // A single-entity geometric on all-start points → just the id.
        #expect(ConstraintListModel.referenceDescription(for: .horizontal(line: a)) == "#1")
        // A radius (single entity, center point) → "center of #3".
        #expect(ConstraintListModel.referenceDescription(for: .radius(circle: c, value: 5))
                == "center of #3")
        // A two-entity parallel → "#1 ∥ #2".
        #expect(ConstraintListModel.referenceDescription(for: .parallel(line: a, line: b))
                == "#1 ∥ #2")
    }

    @Test("valueDescription shows value (+ expression) only for dimensional kinds")
    func valueDescription() {
        // Geometric → nil (no driven value).
        #expect(ConstraintListModel.valueDescription(for: .horizontal(line: a)) == nil)
        // A literal distance → the trimmed number.
        #expect(ConstraintListModel.valueDescription(
            for: .distance(ConstraintPoint(entityID: a), ConstraintPoint(entityID: b), value: 11))
                == "11")
        // A parameter-bound radius → "expr = value".
        #expect(ConstraintListModel.valueDescription(
            for: .radius(circle: c, expression: "width/2", value: 11))
                == "width/2 = 11")
        // An angle is reported in DEGREES with a ° suffix (value stored in radians).
        let quarter = Constraint.angle(line: a, line: b, value: .pi / 2)
        #expect(ConstraintListModel.valueDescription(for: quarter) == "90°")
    }
}

// MARK: - Model wiring (CanvasModel) the panel's actions funnel through

@MainActor
@Suite("Lane C — Constraints panel ↔ CanvasModel wiring (delete / filter / select)")
struct ConstraintsPanelModelTests {

    /// Per-row DELETE removes the constraint, and one ⌘Z restores it — the headline new
    /// capability (delete was previously unreachable from any UI). Asserts through
    /// `model.allConstraints` count, exactly as the brief requires.
    @Test("delete via model removes the constraint; one undo restores it")
    func deleteThenUndoRestores() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CFix.line(Vector(0, 0), Vector(10, 6)))
        let m = CFix.model(drawing)
        #expect(m.addConstraint(.horizontal, entities: [a]))
        #expect(m.allConstraints.count == 1)
        let cid = try #require(m.allConstraints.first?.id)

        // The panel's trash button calls exactly this.
        #expect(m.removeConstraint(id: cid))
        #expect(m.allConstraints.isEmpty, "delete drops it from the list")

        // One ⌘Z restores it (the model funnel is undoable).
        m.undo()
        #expect(m.allConstraints.count == 1, "one undo restores the deleted constraint")
        #expect(m.allConstraints.first?.id == cid)
    }

    /// The selection-filter the panel applies (via `model.constraints(for:)`) returns the
    /// right subset against a LIVE drawing — the engine side of `referencingSelection`.
    @Test("constraints(for:) returns exactly the selection's constraints")
    func selectionFilterAgainstLiveModel() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CFix.line(Vector(0, 5), Vector(10, 5)))
        let circ = drawing.add(CFix.circle(Vector(20, 20), 5))
        let m = CFix.model(drawing)
        #expect(m.addConstraint(.parallel, entities: [a, b]))     // touches a + b
        #expect(m.addConstraint(.radius, entities: [circ], value: 5))  // touches circ only

        // The circle's filtered list is just its radius constraint.
        let onCircle = m.constraints(for: circ)
        #expect(onCircle.count == 1)
        #expect(onCircle.first?.kind.isDimensional == true)

        // `a`'s filtered list is just the parallel constraint.
        let onA = m.constraints(for: a)
        #expect(onA.count == 1)
        #expect(onA.first?.references(b) == true, "the parallel constraint spans a + b")

        // The pure helper over `allConstraints` agrees with the live filter for a 2-entity sel.
        let pureOnAB = ConstraintListModel.referencingSelection(m.allConstraints,
                                                                selectionIDs: [a, b])
        #expect(pureOnAB.count == 1, "parallel(a,b) once; radius(circ) excluded")
    }

    /// Click-to-select sets the selection to the constraint's entities (the panel funnels
    /// the pure `selectionTarget` through `model.setSelection`).
    @Test("click-to-select sets the selection to the constraint's entities")
    func clickToSelect() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CFix.line(Vector(0, 5), Vector(10, 5)))
        let m = CFix.model(drawing)
        #expect(m.addConstraint(.parallel, entities: [a, b]))
        let parallel = try #require(m.allConstraints.first)

        #expect(m.selection.ids.isEmpty)
        let target = ConstraintListModel.selectionTarget(for: parallel)
        #expect(m.setSelection(target))
        #expect(m.selection.ids == [a, b], "selecting the row selects both constrained lines")
    }

    /// The Inspector "Constraints" section + the panel both filter inferred (hidden)
    /// constraints out of what they list — the user can only delete what they made.
    @Test("inferred constraints are never listed for deletion")
    func inferredHidden() throws {
        let drawing = CADDrawing()
        let a = drawing.add(CFix.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(CFix.line(Vector(0, 5), Vector(10, 5)))
        // Add a real one + a hidden inferred one straight on the drawing table.
        #expect(drawing.addConstraint(.horizontal(line: a)))
        #expect(drawing.addConstraint(.coincidentInferred(
            ConstraintPoint(entityID: a, point: .end),
            ConstraintPoint(entityID: b, point: .start))))
        let m = CFix.model(drawing)

        #expect(m.allConstraints.count == 2, "the table holds both")
        let displayed = ConstraintListModel.displayed(m.allConstraints,
                                                      selectionIDs: [], selectionOnly: false)
        #expect(displayed.count == 1, "only the user-visible horizontal is listed")
        #expect(!displayed.contains { $0.inferred })
    }
}

// MARK: - Lane C live-apply: the AutoConstrain flag re-seeds from defaults

@MainActor
@Suite("Lane C — AutoConstrain live-apply re-seed")
struct AutoConstrainLiveApplyTests {

    /// The `.lcAutoConstrainDidChange` observer (in `CADCanvasView`) calls
    /// `model.seedAutoConstrainFromAppSettings()`; this proves the re-seed reads the flag
    /// FRESH from a defaults store, so flipping the persisted value flips the live flag on
    /// an already-open model. (The notification → observer hop is View-layer; the testable
    /// unit is the re-seed funnel it calls, given an injectable defaults store.)
    @Test("seedAutoConstrainFromAppSettings re-reads the persisted flag")
    func reSeedReadsFreshFlag() throws {
        let drawing = CADDrawing()
        let m = CFix.model(drawing)
        let key = CanvasModel.autoConstrainOnDrawKey

        // A throwaway, isolated defaults store so the test never touches the real domain.
        let suite = "lc.test.autoConstrain.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removeSuite(named: suite) }

        // Flip the persisted flag OFF, then re-seed → the live flag follows.
        defaults.set(false, forKey: key)
        m.seedAutoConstrainFromAppSettings(defaults: defaults)
        #expect(m.autoConstrainOnDraw == false, "re-seed picked up the OFF flag")

        // Flip it back ON, re-seed → the live flag follows again.
        defaults.set(true, forKey: key)
        m.seedAutoConstrainFromAppSettings(defaults: defaults)
        #expect(m.autoConstrainOnDraw == true, "re-seed picked up the ON flag")

        // A MISSING key reads as ON (object-first default), matching the @AppStorage default.
        defaults.removeObject(forKey: key)
        m.seedAutoConstrainFromAppSettings(defaults: defaults)
        #expect(m.autoConstrainOnDraw == true, "absent key defaults to ON")
    }
}
