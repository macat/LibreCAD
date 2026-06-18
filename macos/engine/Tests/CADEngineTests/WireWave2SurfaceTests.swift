//
//  WireWave2SurfaceTests.swift
//  CADEngineTests
//
//  Wire-wave 2 — surface CONSTRAINTS + FIELDS in the UI. Covers the `CanvasModel` glue
//  the Constrain menu / ⌘K palette / Insert-Field menu call (the SwiftUI menus + the
//  AppKit responder-chain handlers themselves are user-verified; the testable logic lives
//  in pure model verbs for exactly this reason):
//
//   • Selection-driven constraints — `applyGeometricConstraintToSelection` /
//     `applyDimensionalConstraintToSelection` turn the current selection into a STABLE-
//     ordered id list and forward to the arity-validated, undoable engine `addConstraint`
//     funnels (apply immediately as one undo group). A wrong-arity selection is a SAFE
//     no-op that posts a status note (never crashes).
//   • DIMENSIONAL current-value LOCK — distance/radius capture the CURRENT measured value
//     from the live geometry (no modal prompt) and drive the constraint to it, so applying
//     the constraint pins the shape exactly where it already is.
//   • FIELD context — `makeFieldContext()` is populated with a live date + the active
//     layout name ("Model" in model space); `fileName` is deferred (nil). `appendFieldToSelectedText`
//     embeds a field into the SELECTED single text/mtext through the undoable engine setter.
//   • Menu-enablement predicates — `canApplyGeometric/DimensionalConstraint` /
//     `canInsertFieldIntoSelection` reflect the selection cardinality/kind.
//   • Palette roster — the Constrain + Insert-Field commands are present in the ⌘K list.
//
//  `CanvasModel` lives in the (un-importable) app target, reached via the existing
//  `_SharedCanvasModel.swift` symlink; the palette registry via `_SharedCommandPalette.swift`.
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
private enum W2 {
    static func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
    }
    static func circle(_ c: Vector, _ r: Double) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .circle(CircleData(center: c, radius: r)))
    }
    static func point(_ p: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .point(PointData(position: p)))
    }
    static func text(_ s: String) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .text(TextData(position: Vector(0, 0), height: 2.5, text: s)))
    }

    /// A model on `drawing` with a clean, manually-grouped undo stack (one explicit group
    /// == one ⌘Z) — mirrors `ConstraintResolveSeamTests.Fix.model`.
    static func model(_ drawing: CADDrawing) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    static func select(_ m: CanvasModel, _ ids: EntityID...) {
        m.selection = Selection(ids: Set(ids))
    }
}

// MARK: - Selection-driven geometric constraints

@MainActor
@Suite("Wire-2 — geometric constraints from the selection")
struct WireWave2GeometricTests {

    @Test("horizontal-from-selection applies to the single selected line immediately")
    func horizontalFromSelection() throws {
        let drawing = CADDrawing()
        let a = drawing.add(W2.line(Vector(0, 0), Vector(10, 6)))   // diagonal
        let m = W2.model(drawing)
        W2.select(m, a)
        #expect(m.applyGeometricConstraintToSelection(.horizontal))
        guard case .line(let l)? = m.drawing.entity(a)?.kind else { Issue.record("not a line"); return }
        #expect(abs(l.end.y - l.start.y) < 1e-6, "line should be horizontal now")
        #expect(m.allConstraints.count == 1)
    }

    @Test("parallel-from-selection pins two selected lines parallel")
    func parallelFromSelection() throws {
        let drawing = CADDrawing()
        let a = drawing.add(W2.line(Vector(0, 0), Vector(10, 0)))   // horizontal
        let b = drawing.add(W2.line(Vector(0, 5), Vector(10, 8)))   // diagonal
        let m = W2.model(drawing)
        W2.select(m, a, b)
        #expect(m.applyGeometricConstraintToSelection(.parallel))
        guard case .line(let la)? = m.drawing.entity(a)?.kind,
              case .line(let lb)? = m.drawing.entity(b)?.kind else { Issue.record("missing"); return }
        let da = (la.end.x - la.start.x, la.end.y - la.start.y)
        let db = (lb.end.x - lb.start.x, lb.end.y - lb.start.y)
        #expect(abs(da.0 * db.1 - da.1 * db.0) < 1e-6, "B parallel to A")
    }

    @Test("wrong-arity selection is a safe no-op that posts a status note")
    func wrongArityNoOp() throws {
        let drawing = CADDrawing()
        let a = drawing.add(W2.line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(W2.line(Vector(0, 5), Vector(10, 5)))
        let m = W2.model(drawing)
        // horizontal needs ONE entity; selecting two must fail (no constraint, status note).
        W2.select(m, a, b)
        #expect(!m.applyGeometricConstraintToSelection(.horizontal))
        #expect(m.allConstraints.isEmpty, "nothing added on a bad-arity selection")
        #expect(!m.toolStatus.isEmpty, "a status note is posted for the arity failure")
    }

    @Test("an empty selection is a safe no-op")
    func emptySelectionNoOp() {
        let m = W2.model(CADDrawing())
        m.selection = Selection()
        #expect(!m.applyGeometricConstraintToSelection(.fix))
        #expect(m.allConstraints.isEmpty)
    }

    @Test("orderedSelectionIDs follows draw order regardless of insertion order")
    func orderedSelection() {
        let drawing = CADDrawing()
        let a = drawing.add(W2.line(Vector(0, 0), Vector(1, 0)))
        let b = drawing.add(W2.line(Vector(0, 1), Vector(1, 1)))
        let c = drawing.add(W2.line(Vector(0, 2), Vector(1, 2)))
        let m = W2.model(drawing)
        m.selection = Selection(ids: [c, a])   // out-of-draw-order set
        #expect(m.orderedSelectionIDs == [a, c], "ordered by position in drawing.entities")
        _ = b   // (b unselected)
    }
}

// MARK: - Dimensional constraints: lock the CURRENT measured value (no modal)

@MainActor
@Suite("Wire-2 — dimensional constraints lock the current value")
struct WireWave2DimensionalTests {

    @Test("distance-from-selection LOCKS the current gap (geometry does not move)")
    func distanceLocksCurrent() throws {
        let drawing = CADDrawing()
        // Two points 13 apart (5-12-13 triangle), at non-trivial positions.
        let p1 = drawing.add(W2.point(Vector(2, 3)))
        let p2 = drawing.add(W2.point(Vector(7, 15)))   // distance = 13
        let m = W2.model(drawing)
        W2.select(m, p1, p2)
        #expect(m.applyDimensionalConstraintToSelection(.distance))
        // The driven value was captured as the CURRENT distance (13), so neither point moved.
        guard case .point(let q1)? = m.drawing.entity(p1)?.kind,
              case .point(let q2)? = m.drawing.entity(p2)?.kind else { Issue.record("missing"); return }
        #expect(q1.position == Vector(2, 3) && q2.position == Vector(7, 15),
                "locking the current distance must not move the geometry")
        let con = try #require(m.allConstraints.first)
        #expect(con.kind.isDimensional)
        #expect(abs(con.value - 13) < 1e-9, "driven value locked to the measured distance")
    }

    @Test("radius-from-selection LOCKS the circle's current radius")
    func radiusLocksCurrent() throws {
        let drawing = CADDrawing()
        let c = drawing.add(W2.circle(Vector(3, 4), 8.5))
        let m = W2.model(drawing)
        W2.select(m, c)
        #expect(m.applyDimensionalConstraintToSelection(.radius))
        guard case .circle(let circ)? = m.drawing.entity(c)?.kind else { Issue.record("not a circle"); return }
        #expect(abs(circ.radius - 8.5) < 1e-9, "radius unchanged (locked to current)")
        #expect(circ.center == Vector(3, 4))
        #expect(abs((m.allConstraints.first?.value ?? 0) - 8.5) < 1e-9)
    }

    @Test("radius on a non-circle / distance on one entity is a safe no-op + status note")
    func dimensionalArityNoOp() {
        let drawing = CADDrawing()
        let line = drawing.add(W2.line(Vector(0, 0), Vector(10, 0)))
        let m = W2.model(drawing)
        W2.select(m, line)
        #expect(!m.applyDimensionalConstraintToSelection(.radius))   // a line, not a circle
        #expect(!m.applyDimensionalConstraintToSelection(.distance)) // needs two entities
        #expect(m.allConstraints.isEmpty)
        #expect(!m.toolStatus.isEmpty)
    }

    @Test("distance-from-selection is a single undo group (add + immediate apply)")
    func dimensionalOneUndo() throws {
        let drawing = CADDrawing()
        let p1 = drawing.add(W2.point(Vector(0, 0)))
        let p2 = drawing.add(W2.point(Vector(5, 0)))
        let m = W2.model(drawing)
        W2.select(m, p1, p2)
        #expect(m.applyDimensionalConstraintToSelection(.distance))
        #expect(!m.allConstraints.isEmpty)
        m.undo()
        #expect(m.allConstraints.isEmpty, "one ⌘Z removes the constraint")
        #expect(!m.canUndo)
    }
}

// MARK: - Menu-enablement predicates

@MainActor
@Suite("Wire-2 — constraint/field menu-enablement predicates")
struct WireWave2EnablementTests {

    @Test("geometric/dimensional applicability follows the selection cardinality")
    func cardinalityPredicates() {
        let drawing = CADDrawing()
        let a = drawing.add(W2.line(Vector(0, 0), Vector(1, 0)))
        let b = drawing.add(W2.line(Vector(0, 1), Vector(1, 1)))
        let m = W2.model(drawing)

        m.selection = Selection(ids: [a])
        #expect(m.canApplyGeometricConstraint(.horizontal))   // needs 1
        #expect(!m.canApplyGeometricConstraint(.parallel))    // needs 2
        #expect(m.canApplyDimensionalConstraint(.radius))     // needs 1
        #expect(!m.canApplyDimensionalConstraint(.distance))  // needs 2

        m.selection = Selection(ids: [a, b])
        #expect(m.canApplyGeometricConstraint(.parallel))     // needs 2
        #expect(!m.canApplyGeometricConstraint(.fix))         // needs 1
        #expect(m.canApplyDimensionalConstraint(.distance))   // needs 2
        #expect(!m.canApplyDimensionalConstraint(.radius))    // needs 1
    }

    @Test("unsupported kinds are reported unsupported")
    func unsupportedReported() {
        let m = W2.model(CADDrawing())
        #expect(m.isConstraintSupported(.parallel))
        #expect(m.isConstraintSupported(.distance))
        // Lane B implemented angle (and collinear/concentric/equal/diameter/H-V dist).
        #expect(m.isConstraintSupported(.angle))
        #expect(m.isConstraintSupported(.collinear))
        // tangent + symmetric remain out of scope → still unsupported.
        #expect(!m.isConstraintSupported(.tangent))
        #expect(!m.isConstraintSupported(.symmetric))
    }

    @Test("field-insert applicability needs exactly one TEXT/MTEXT entity")
    func fieldInsertPredicate() {
        let drawing = CADDrawing()
        let t = drawing.add(W2.text("Hello"))
        let l = drawing.add(W2.line(Vector(0, 0), Vector(1, 1)))
        let m = W2.model(drawing)

        m.selection = Selection(ids: [t])
        #expect(m.canInsertFieldIntoSelection)
        m.selection = Selection(ids: [l])
        #expect(!m.canInsertFieldIntoSelection)   // not text
        m.selection = Selection(ids: [t, l])
        #expect(!m.canInsertFieldIntoSelection)   // not exactly one
    }
}

// MARK: - Fields: live context + insert-into-selection

@MainActor
@Suite("Wire-2 — field context population + insert")
struct WireWave2FieldsTests {

    @Test("makeFieldContext carries a live date + the active layout (Model in model space)")
    func fieldContextPopulated() {
        let m = W2.model(CADDrawing())
        let before = Date()
        let ctx = m.makeFieldContext()
        let after = Date()
        let date = ctx.date
        #expect(date != nil, "a live date is populated")
        if let date {
            #expect(date >= before.addingTimeInterval(-1) && date <= after.addingTimeInterval(1),
                    "date is the current time")
        }
        // Model space → "Model" sentinel (no active layout).
        #expect(ctx.layoutName == "Model")
        // fileName is DEFERRED this wave (not reachable from the model layer) → nil → "####".
        #expect(ctx.fileName == nil)
    }

    @Test("renderResolveContext injects the live field context")
    func renderContextHasFields() {
        let m = W2.model(CADDrawing())
        let ctx = m.renderResolveContext()
        #expect(ctx.fieldContext != nil, "the render resolve context carries the field context")
        #expect(ctx.fieldContext?.layoutName == "Model")
    }

    @Test("an inserted date field resolves to a live value through the render context")
    func insertedFieldResolvesLive() throws {
        let drawing = CADDrawing()
        let t = drawing.add(W2.text("Today: "))
        let m = W2.model(drawing)
        m.selection = Selection(ids: [t])
        #expect(m.appendFieldToSelectedText(.date(format: "yyyy")))

        // The entity now carries a FieldRun + a zero-width placeholder.
        guard case .text(let td)? = m.drawing.entity(t)?.kind else { Issue.record("not text"); return }
        #expect(td.fields?.isEmpty == false, "a field run was appended")

        // Resolving WITH the live render context substitutes the live year for the marker.
        let resolved = FieldEvaluator.substitute(td.text, fields: td.fields,
                                                  context: m.makeFieldContext())
        let year = Calendar.current.component(.year, from: Date())
        #expect(resolved.contains("\(year)"), "the date field resolves to the current year")
        // WITHOUT a context the stored placeholder is left verbatim (regression-lock).
        let raw = FieldEvaluator.substitute(td.text, fields: td.fields, context: nil)
        #expect(raw == td.text)
    }

    @Test("insert-field on a non-text selection is a safe no-op + status note")
    func insertFieldNoOp() {
        let drawing = CADDrawing()
        let l = drawing.add(W2.line(Vector(0, 0), Vector(1, 1)))
        let m = W2.model(drawing)
        m.selection = Selection(ids: [l])
        #expect(!m.appendFieldToSelectedText(.layoutName()))
        #expect(!m.toolStatus.isEmpty)
    }

    @Test("insert-field is undoable (one ⌘Z restores the original text)")
    func insertFieldUndo() throws {
        let drawing = CADDrawing()
        let t = drawing.add(W2.text("Plot date "))
        let m = W2.model(drawing)
        m.selection = Selection(ids: [t])
        guard case .text(let before)? = m.drawing.entity(t)?.kind else { Issue.record("not text"); return }
        #expect(m.appendFieldToSelectedText(.date()))
        m.undo()
        guard case .text(let after)? = m.drawing.entity(t)?.kind else { Issue.record("not text"); return }
        #expect(after.text == before.text && after.fields == before.fields,
                "one ⌘Z restores the pre-insert text + fields")
    }
}

// MARK: - Palette roster (the ⌘K entries for the new verbs)

@MainActor
@Suite("Wire-2 — command palette roster")
struct WireWave2PaletteTests {

    private var commands: [PaletteCommand] {
        // The new constraint/field actions default to inert no-ops, so the bare stub
        // (only the pre-existing required closures) still builds the full list.
        CommandRegistry.commands(CommandRegistry.Actions(
            activateTool: { _ in },
            placeImage: {},
            createBlockFromSelection: {},
            open: {}, save: {}, saveAs: {},
            export: { _ in }, print: {},
            zoomToFit: {}, undo: {}, redo: {},
            toggleInspector: {}, toggleGrid: {}, documentSettings: {},
            importMergeDXF: {}, dimensionStyleManager: {},
            saveNamedView: {}, restoreNamedView: {},
            insertBlockFromFile: {}, saveBlockToFile: {}, newLayout: {}
        ))
    }

    @Test("the wire-2 constraint + insert-field commands are present in the palette")
    func wire2CommandsPresent() {
        let ids = Set(commands.map(\.id))
        let required = [
            "constrain.coincident", "constrain.horizontal", "constrain.vertical",
            "constrain.parallel", "constrain.perpendicular", "constrain.fix",
            "constrain.distance", "constrain.radius",
            "insert.field.date", "insert.field.layout", "insert.field.fileName",
        ]
        for id in required {
            #expect(ids.contains(id), "missing wire-2 palette command: \(id)")
        }
        // No id collisions introduced.
        let all = commands.map(\.id)
        #expect(Set(all).count == all.count)
    }

    @Test("the constrain/insert commands are findable by their menu-ish wording")
    func wire2CommandsTypeable() {
        let titles = commands.map(\.title)
        let probes: [(query: String, expected: String)] = [
            ("Constrain Parallel", "Constrain: Parallel"),
            ("Constrain Radius", "Constrain: Radius (lock current)"),
            ("Insert Field Date", "Insert Field: Date"),
            ("Insert Field Layout", "Insert Field: Layout Name"),
        ]
        for probe in probes {
            let ranked = CommandMatcher.rank(query: probe.query, candidates: titles)
            #expect(ranked.map { titles[$0.index] }.contains(probe.expected),
                    "‘\(probe.query)’ did not surface ‘\(probe.expected)’")
        }
    }
}
