//
//  ParameterTableTests.swift
//  CADEngineTests
//
//  Unit tests for the NAMED-PARAMETER model (Lane L1): the `Parameter` value type,
//  the `ParameterTable` store (add/remove/replace, case-insensitive name lookup +
//  duplicate-name reject, Codable round-trip + decodeIfPresent back-compat), the
//  additive `Constraint.expression` field (Codable round-trip + literal-path
//  byte-identical proof + old-payload-no-key → nil), the `CADDrawing.mutateParameters`
//  undoable funnel (add / update / remove + ⌘Z), and the parameter-delete freeze that
//  turns a referencing constraint back into a pure-literal one (undoable).
//

import XCTest
@testable import CADEngine

final class ParameterTableTests: XCTestCase {

    private func id(_ n: UInt64) -> EntityID { EntityID(n) }

    // MARK: - Parameter / table: add / remove / replace

    func testTableAddAndLookupByName() {
        var t = ParameterTable()
        let p = Parameter(name: "width", expression: "22", value: 22)
        XCTAssertTrue(t.add(p))
        XCTAssertEqual(t.count, 1)
        // Case-INSENSITIVE name lookup (the reference key).
        XCTAssertEqual(t.parameter(named: "width")?.id, p.id)
        XCTAssertEqual(t.parameter(named: "WIDTH")?.id, p.id)
        XCTAssertEqual(t.parameter(named: "Width")?.expression, "22")
        XCTAssertNil(t.parameter(named: "height"))
        XCTAssertEqual(t.parameter(p.id)?.name, "width")
    }

    func testTableAddRejectsDuplicateID() {
        var t = ParameterTable()
        let p = Parameter(name: "a", expression: "1", value: 1)
        XCTAssertTrue(t.add(p))
        XCTAssertFalse(t.add(p))            // same id → rejected
        XCTAssertEqual(t.count, 1)
    }

    func testTableAddRejectsDuplicateNameCaseInsensitively() {
        var t = ParameterTable()
        XCTAssertTrue(t.add(Parameter(name: "Length", expression: "10", value: 10)))
        // A DIFFERENT id but a case-insensitively colliding NAME is rejected — names
        // are the unique reference key.
        XCTAssertFalse(t.add(Parameter(name: "length", expression: "99", value: 99)))
        XCTAssertFalse(t.add(Parameter(name: "LENGTH", expression: "99", value: 99)))
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.parameter(named: "length")?.value, 10)   // original kept
    }

    func testTableRemoveByIDAndByName() {
        var t = ParameterTable()
        let p = Parameter(name: "a", expression: "1", value: 1)
        let q = Parameter(name: "b", expression: "2", value: 2)
        t.add(p); t.add(q)
        XCTAssertTrue(t.remove(p.id))
        XCTAssertFalse(t.remove(p.id))          // gone → no-op
        XCTAssertEqual(t.remove(named: "B"), q.id)   // case-insensitive remove
        XCTAssertNil(t.remove(named: "missing"))
        XCTAssertTrue(t.isEmpty)
    }

    func testTableReplace() {
        var t = ParameterTable()
        var p = Parameter(name: "a", expression: "1", value: 1)
        t.add(p)
        p.expression = "5"; p.value = 5; p.unit = "mm"
        XCTAssertTrue(t.replace(p))
        XCTAssertEqual(t.parameter(p.id)?.value, 5)
        XCTAssertEqual(t.parameter(p.id)?.unit, "mm")
        // Replacing an absent id is a no-op.
        XCTAssertFalse(t.replace(Parameter(name: "z", expression: "0", value: 0)))
    }

    func testTableReplaceRejectsNameCollisionWithDifferentParameter() {
        var t = ParameterTable()
        let a = Parameter(name: "a", expression: "1", value: 1)
        let b = Parameter(name: "b", expression: "2", value: 2)
        t.add(a); t.add(b)
        // Renaming `b` onto `a`'s name (case-insensitively) is rejected.
        var bRenamed = b; bRenamed.name = "A"
        XCTAssertFalse(t.replace(bRenamed))
        XCTAssertEqual(t.parameter(b.id)?.name, "b")    // unchanged
        // A case-only rename of the SAME parameter is allowed (no different-id clash).
        var aCase = a; aCase.name = "A"
        XCTAssertTrue(t.replace(aCase))
        XCTAssertEqual(t.parameter(a.id)?.name, "A")
    }

    func testContainsNamed() {
        var t = ParameterTable()
        t.add(Parameter(name: "Foo", expression: "1", value: 1))
        XCTAssertTrue(t.contains(named: "foo"))
        XCTAssertFalse(t.contains(named: "bar"))
    }

    // MARK: - Codable round-trip + back-compat

    func testParameterTableCodableRoundTrip() throws {
        var t = ParameterTable()
        t.add(Parameter(name: "width", expression: "22", value: 22, unit: "mm"))
        t.add(Parameter(name: "a", expression: "width*2", value: 44))
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(ParameterTable.self, from: data)
        XCTAssertEqual(back, t)
    }

    func testEmptyTableDecodesFromEmptyObject() throws {
        // A document payload with no `parameters` key (an OLD file written before this
        // table existed) decodes to an empty table (decodeIfPresent back-compat).
        let json = "{}".data(using: .utf8)!
        let t = try JSONDecoder().decode(ParameterTable.self, from: json)
        XCTAssertTrue(t.isEmpty)
    }

    func testParameterDecodesFromMinimalJSON() throws {
        // A parameter with only `name` (no id/expression/value/unit): id minted fresh,
        // expression "" , value 0, unit nil (additive back-compat).
        let json = """
        { "name": "x" }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Parameter.self, from: json)
        XCTAssertEqual(p.name, "x")
        XCTAssertEqual(p.expression, "")
        XCTAssertEqual(p.value, 0)
        XCTAssertNil(p.unit)
    }

    // MARK: - Constraint.expression: additive field + back-compat proof

    func testConstraintExpressionCodableRoundTrip() throws {
        let c = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)),
                                    expression: "width", value: 22)
        XCTAssertEqual(c.expression, "width")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Constraint.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.expression, "width")
        XCTAssertEqual(back.value, 22)
    }

    func testLiteralConstraintExpressionIsNilByDefault() {
        // A constraint built the old way carries no expression — a pure-literal path.
        let c = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 22)
        XCTAssertNil(c.expression)
        XCTAssertEqual(c.value, 22)
    }

    func testLiteralConstraintEncodesByteIdenticalToPreExpressionPayload() throws {
        // PROVE the literal path is byte-identical: a constraint with expression == nil
        // must NOT emit an `expression` key (the optional is omitted by the encoder), so
        // its payload equals what was written before the field existed. We compare the
        // encoded JSON object's KEY SET to the pre-field key set.
        let c = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 22)
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // The pre-`expression` field set (id, kind, points, value, inferred). NO
        // `expression` key for a pure-literal constraint.
        XCTAssertFalse(obj.keys.contains("expression"),
                       "a pure-literal constraint must not emit an `expression` key")
        XCTAssertEqual(Set(obj.keys), ["id", "kind", "points", "value", "inferred"])
    }

    func testConstraintWithoutExpressionKeyDecodesToNil() throws {
        // An OLD payload with no `expression` key decodes to expression == nil (the
        // pure-literal path) — additive back-compat, exactly like `inferred`.
        let json = """
        { "kind": { "dimensional": { "_0": "distance" } },
          "points": [ { "entityID": { "rawValue": 1 }, "point": "start" },
                      { "entityID": { "rawValue": 2 }, "point": "start" } ],
          "value": 22, "inferred": false }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(Constraint.self, from: json)
        XCTAssertNil(c.expression)
        XCTAssertEqual(c.value, 22)
    }

    func testDrivenByBindAndUnbind() {
        let lit = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 22)
        let bound = lit.driven(by: "width", value: 30)
        XCTAssertEqual(bound.expression, "width")
        XCTAssertEqual(bound.value, 30)
        XCTAssertEqual(bound.id, lit.id)            // same constraint, copied
        let unbound = bound.driven(by: nil)
        XCTAssertNil(unbound.expression)
        XCTAssertEqual(unbound.value, 30)           // value (literal) kept on unbind
    }

    // MARK: - Expression-references-name token scan

    func testExpressionReferencesWholeWordOnly() {
        XCTAssertTrue(CADDrawing.expression("a*2", references: "a"))
        XCTAssertTrue(CADDrawing.expression("width/2", references: "width"))
        XCTAssertTrue(CADDrawing.expression("WIDTH + 1", references: "width"))   // case-insens
        XCTAssertTrue(CADDrawing.expression("a", references: "a"))
        XCTAssertTrue(CADDrawing.expression("2*a + b", references: "b"))
        // NOT a whole-word match → false.
        XCTAssertFalse(CADDrawing.expression("area", references: "a"))
        XCTAssertFalse(CADDrawing.expression("data", references: "a"))
        XCTAssertFalse(CADDrawing.expression("width", references: "wid"))
        XCTAssertFalse(CADDrawing.expression("a*2", references: ""))             // empty never
        XCTAssertFalse(CADDrawing.expression("", references: "a"))
    }

    // MARK: - CADDrawing funnel + undo

    /// An UndoManager configured for unit testing (manual grouping — matching
    /// ConstraintTableTests.testUndoManager).
    @MainActor
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    @MainActor
    func testDrawingAddUpdateRemoveWithUndo() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        let p = Parameter(name: "width", expression: "22", value: 22)
        um.beginUndoGrouping(); XCTAssertTrue(drawing.addParameter(p)); um.endUndoGrouping()
        XCTAssertEqual(drawing.parameters.count, 1)

        // Update (edit the expression/value), one group.
        var edited = p; edited.expression = "30"; edited.value = 30
        um.beginUndoGrouping(); XCTAssertTrue(drawing.updateParameter(edited)); um.endUndoGrouping()
        XCTAssertEqual(drawing.parameters.parameter(p.id)?.value, 30)

        // ⌘Z reverts the edit → back to 22.
        um.undo()
        XCTAssertEqual(drawing.parameters.parameter(p.id)?.value, 22)
        // Redo → 30 again.
        um.redo()
        XCTAssertEqual(drawing.parameters.parameter(p.id)?.value, 30)

        // Remove (undoable), then ⌘Z restores it.
        um.beginUndoGrouping(); XCTAssertTrue(drawing.removeParameter(p.id)); um.endUndoGrouping()
        XCTAssertTrue(drawing.parameters.isEmpty)
        um.undo()
        XCTAssertEqual(drawing.parameters.count, 1)
        XCTAssertEqual(drawing.parameters.parameter(p.id)?.value, 30)
    }

    @MainActor
    func testAddRejectsDuplicateNameAndAddDoesNotPolluteUndo() {
        let drawing = CADDrawing()
        drawing.addParameter(Parameter(name: "a", expression: "1", value: 1))
        // A case-insensitive name clash is rejected (no second parameter).
        XCTAssertFalse(drawing.addParameter(Parameter(name: "A", expression: "9", value: 9)))
        XCTAssertEqual(drawing.parameters.count, 1)

        // A no-op update (same value) registers no undo: with groupsByEvent = false a
        // registration outside a group would throw, so no crash + unchanged table prove
        // the no-op (mirrors ConstraintTableTests.testNoOpEditDoesNotPolluteUndo).
        let um = testUndoManager()
        drawing.undoManager = um
        let prior = drawing.parameters
        let unchanged = drawing.parameters.parameters[0]
        XCTAssertFalse(drawing.updateParameter(unchanged))
        XCTAssertEqual(drawing.parameters, prior)
    }

    // MARK: - Parameter DELETE freezes referencing constraint expression → literal

    @MainActor
    func testRemoveParameterFreezesReferencingConstraintToLiteral() {
        let drawing = CADDrawing()
        // A parameter + a dimensional constraint DRIVEN by it (expression == name,
        // value == last-evaluated cache).
        let p = Parameter(name: "width", expression: "22", value: 22)
        drawing.addParameter(p)
        let bound = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)),
                                        expression: "width", value: 22)
        drawing.addConstraint(bound)
        // A literal constraint that mentions a SUBSTRING but not the whole word — must
        // be left untouched.
        let unrelated = Constraint.distance(.init(entityID: id(3)), .init(entityID: id(4)),
                                            expression: "widths", value: 5)
        drawing.addConstraint(unrelated)

        // Delete the parameter → the bound constraint's expression freezes to nil, its
        // cached `value` (22) kept as the now-literal; the unrelated one is untouched.
        XCTAssertTrue(drawing.removeParameter(p.id))
        XCTAssertTrue(drawing.parameters.isEmpty)
        let frozen = drawing.constraints.constraint(bound.id)
        XCTAssertNil(frozen?.expression)
        XCTAssertEqual(frozen?.value, 22)                     // literal preserved
        XCTAssertEqual(drawing.constraints.constraint(unrelated.id)?.expression, "widths")
    }

    @MainActor
    func testRemoveParameterFreezeIsUndoable() {
        let drawing = CADDrawing()
        // Seed BEFORE attaching the UndoManager so only the remove registers undo
        // (groupsByEvent = false: a registration outside a group throws).
        let p = Parameter(name: "a", expression: "10", value: 10)
        drawing.addParameter(p)
        let bound = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)),
                                        expression: "a", value: 10)
        drawing.addConstraint(bound)

        let um = testUndoManager()
        drawing.undoManager = um

        // The remove FREEZES the constraint AND removes the parameter; both register
        // undo inside ONE group, so a single ⌘Z reverts the whole user action.
        um.beginUndoGrouping()
        XCTAssertTrue(drawing.removeParameter(p.id))
        um.endUndoGrouping()
        XCTAssertTrue(drawing.parameters.isEmpty)
        XCTAssertNil(drawing.constraints.constraint(bound.id)?.expression)
        XCTAssertEqual(drawing.constraints.constraint(bound.id)?.value, 10)

        // One ⌘Z restores BOTH the parameter and the constraint's driving expression.
        um.undo()
        XCTAssertEqual(drawing.parameters.count, 1)
        XCTAssertEqual(drawing.constraints.constraint(bound.id)?.expression, "a")
        XCTAssertEqual(drawing.constraints.constraint(bound.id)?.value, 10)
    }

    @MainActor
    func testRemoveAbsentParameterIsNoOp() {
        let drawing = CADDrawing()
        XCTAssertFalse(drawing.removeParameter(UUID()))
        XCTAssertNil(drawing.removeParameter(named: "nope"))
    }

    // MARK: - load() threads parameters

    @MainActor
    func testLoadThreadsParameters() {
        let drawing = CADDrawing()
        var table = ParameterTable()
        table.add(Parameter(name: "width", expression: "22", value: 22))
        drawing.load(entities: [], layers: LayerTable(), parameters: table)
        XCTAssertEqual(drawing.parameters.count, 1)
        XCTAssertEqual(drawing.parameters.parameter(named: "width")?.value, 22)
        // load() clears undo (no undo for a file open).
        XCTAssertFalse(drawing.undoManager?.canUndo ?? false)
    }

    @MainActor
    func testLoadDefaultsToEmptyParameters() {
        let drawing = CADDrawing()
        drawing.addParameter(Parameter(name: "x", expression: "1", value: 1))
        // A load WITHOUT a parameters arg resets to an empty table (existing callers
        // unchanged — the additive default).
        drawing.load(entities: [], layers: LayerTable())
        XCTAssertTrue(drawing.parameters.isEmpty)
    }
}
