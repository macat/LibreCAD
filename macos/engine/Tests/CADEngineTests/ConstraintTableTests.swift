//
//  ConstraintTableTests.swift
//  CADEngineTests
//
//  Unit tests for the parametric-constraint DATA MODEL (Wave 1): the `Constraint`
//  value type, the `ConstraintTable` queries (referencing / connectedComponent /
//  dropDangling), the `CADDrawing` undoable funnel (add / edit / remove + ⌘Z), the
//  dangling-drop on entity delete, and Codable round-trip + back-compat.
//

import XCTest
@testable import CADEngine

final class ConstraintTableTests: XCTestCase {

    // Stable ids for fixtures.
    private func id(_ n: UInt64) -> EntityID { EntityID(n) }

    // MARK: - Constraint derived helpers

    func testConstraintEntityIDsDedupesAndPreservesOrder() {
        let c = Constraint.parallel(line: id(10), line: id(20))
        // parallel packs [l1Start, l1End, l2Start, l2End] over two entities.
        XCTAssertEqual(c.entityIDs, [id(10), id(20)])
        XCTAssertTrue(c.references(id(10)))
        XCTAssertTrue(c.references(id(20)))
        XCTAssertFalse(c.references(id(30)))
    }

    func testHorizontalConstraintReferencesSingleLineTwice() {
        let c = Constraint.horizontal(line: id(7))
        XCTAssertEqual(c.entityIDs, [id(7)])           // de-duped to one entity
        XCTAssertEqual(c.points.count, 2)              // but two endpoints
        XCTAssertEqual(c.points.map(\.point), [.start, .end])
    }

    func testSolverSupportedFlags() {
        XCTAssertTrue(Constraint.coincident(.init(entityID: id(1)), .init(entityID: id(2))).isSolverSupported)
        XCTAssertTrue(Constraint.radius(circle: id(1), value: 5).isSolverSupported)
        // Declared-but-unimplemented kinds report unsupported.
        XCTAssertFalse(Constraint(kind: .geometric(.tangent), points: []).isSolverSupported)
        XCTAssertFalse(Constraint(kind: .dimensional(.angle), points: []).isSolverSupported)
    }

    // MARK: - Table add / remove / replace / setValue

    func testTableAddRejectsDuplicateID() {
        var t = ConstraintTable()
        let c = Constraint.horizontal(line: id(1))
        XCTAssertTrue(t.add(c))
        XCTAssertFalse(t.add(c))         // same id → rejected
        XCTAssertEqual(t.count, 1)
    }

    func testTableRemove() {
        var t = ConstraintTable()
        let c = Constraint.horizontal(line: id(1))
        t.add(c)
        XCTAssertTrue(t.remove(c.id))
        XCTAssertFalse(t.remove(c.id))   // gone → no-op
        XCTAssertTrue(t.isEmpty)
    }

    func testTableSetValueOnlyDimensional() {
        var t = ConstraintTable()
        let dim = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 10)
        let geo = Constraint.horizontal(line: id(3))
        t.add(dim); t.add(geo)
        XCTAssertTrue(t.setValue(dim.id, 20))
        XCTAssertEqual(t.constraint(dim.id)?.value, 20)
        XCTAssertFalse(t.setValue(dim.id, 20))         // unchanged → no-op
        XCTAssertFalse(t.setValue(geo.id, 5))          // geometric → no driven value
    }

    // MARK: - referencing

    func testReferencing() {
        var t = ConstraintTable()
        let a = Constraint.horizontal(line: id(1))
        let b = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 5)
        let c = Constraint.radius(circle: id(3), value: 4)
        t.add(a); t.add(b); t.add(c)
        XCTAssertEqual(Set(t.referencing(id(1)).map(\.id)), [a.id, b.id])
        XCTAssertEqual(t.referencing(id(2)).map(\.id), [b.id])
        XCTAssertEqual(t.referencing(id(3)).map(\.id), [c.id])
        XCTAssertTrue(t.referencing(id(99)).isEmpty)
        XCTAssertEqual(t.referencedEntityIDs, [id(1), id(2), id(3)])
    }

    // MARK: - connectedComponent

    func testConnectedComponentSingletonForUnconstrainedEntity() {
        let t = ConstraintTable()
        XCTAssertEqual(t.connectedComponent(of: id(42)), [id(42)])
    }

    func testConnectedComponentTransitiveClosure() {
        // Chain: 1—2 (distance), 2—3 (coincident), 3 horizontal; plus an isolated 5.
        var t = ConstraintTable()
        t.add(Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 3))
        t.add(Constraint.coincident(.init(entityID: id(2)), .init(entityID: id(3))))
        t.add(Constraint.horizontal(line: id(3)))
        t.add(Constraint.horizontal(line: id(5)))     // separate component

        XCTAssertEqual(t.connectedComponent(of: id(1)), [id(1), id(2), id(3)])
        XCTAssertEqual(t.connectedComponent(of: id(3)), [id(1), id(2), id(3)])
        XCTAssertEqual(t.connectedComponent(of: id(5)), [id(5)])     // disjoint
    }

    func testConstraintsWithinComponent() {
        var t = ConstraintTable()
        let inComp = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 3)
        let crosses = Constraint.distance(.init(entityID: id(2)), .init(entityID: id(9)), value: 3)
        t.add(inComp); t.add(crosses)
        let comp: Set<EntityID> = [id(1), id(2)]
        // Only `inComp` lies entirely inside {1,2}; `crosses` touches 9 (outside).
        XCTAssertEqual(t.constraints(within: comp).map(\.id), [inComp.id])
    }

    // MARK: - dropDangling

    func testDropDangling() {
        var t = ConstraintTable()
        let a = Constraint.horizontal(line: id(1))
        let b = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 5)
        let c = Constraint.radius(circle: id(3), value: 4)
        t.add(a); t.add(b); t.add(c)
        let dropped = t.dropDangling(removedID: id(1))
        XCTAssertEqual(Set(dropped), [a.id, b.id])      // both referenced 1
        XCTAssertEqual(t.constraints.map(\.id), [c.id]) // c (id 3) survives
        XCTAssertTrue(t.dropDangling(removedID: id(99)).isEmpty)   // nothing → []
    }

    // MARK: - CADDrawing funnel + undo

    /// An UndoManager configured for unit testing (manual grouping, matching the
    /// project's `BlockFreezeTests.testUndoManager` convention — with
    /// `groupsByEvent = false` each mutation must be wrapped in begin/endUndoGrouping).
    @MainActor
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    @MainActor
    func testDrawingAddEditRemoveWithUndo() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        let c = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 10)
        um.beginUndoGrouping(); XCTAssertTrue(drawing.addConstraint(c)); um.endUndoGrouping()
        XCTAssertEqual(drawing.constraints.count, 1)

        // Edit the driven value (undoable, one group).
        um.beginUndoGrouping(); XCTAssertTrue(drawing.editConstraint(c.id, value: 25)); um.endUndoGrouping()
        XCTAssertEqual(drawing.constraints.constraint(c.id)?.value, 25)

        // Undo the edit → back to 10.
        um.undo()
        XCTAssertEqual(drawing.constraints.constraint(c.id)?.value, 10)

        // Redo the edit → 25 again.
        um.redo()
        XCTAssertEqual(drawing.constraints.constraint(c.id)?.value, 25)

        // Remove (undoable), then undo restores it.
        um.beginUndoGrouping(); XCTAssertTrue(drawing.removeConstraint(c.id)); um.endUndoGrouping()
        XCTAssertTrue(drawing.constraints.isEmpty)
        um.undo()
        XCTAssertEqual(drawing.constraints.count, 1)
        XCTAssertEqual(drawing.constraints.constraint(c.id)?.value, 25)
    }

    @MainActor
    func testNoOpEditDoesNotPolluteUndo() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        let c = Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 10)
        um.beginUndoGrouping(); drawing.addConstraint(c); um.endUndoGrouping()
        let priorTable = drawing.constraints

        // A no-op edit (same value) does nothing AND registers no undo — proven by
        // the funnel returning false and the table being byte-identical (the funnel's
        // unchanged-guard never reaches `registerUndo`; if it DID register while no
        // group is open the UndoManager would throw, so the absence of a crash + the
        // unchanged table together prove the no-op).
        XCTAssertFalse(drawing.editConstraint(c.id, value: 10))
        XCTAssertEqual(drawing.constraints, priorTable)
    }

    // MARK: - Dangling-drop on entity delete (the remove(...) hook)

    @MainActor
    func testEntityRemoveDropsReferencingConstraints() {
        let drawing = CADDrawing()
        let lineID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        drawing.addConstraint(Constraint.horizontal(line: lineID))
        XCTAssertEqual(drawing.constraints.count, 1)

        // Deleting the line drops the constraint referencing it.
        drawing.remove(lineID)
        XCTAssertTrue(drawing.constraints.isEmpty)
    }

    @MainActor
    func testEntityRemoveDanglingDropIsUndoable() {
        let drawing = CADDrawing()
        // Seed the entity + constraint BEFORE attaching the UndoManager, so only the
        // remove (the action under test) registers undo. (With groupsByEvent = false,
        // any registration outside a group throws — the seed adds register none here.)
        let lineID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        let c = Constraint.horizontal(line: lineID)
        drawing.addConstraint(c)

        let um = testUndoManager()
        drawing.undoManager = um

        // The remove drops the constraint AND removes the entity; both register their
        // undo inside ONE group, so a single ⌘Z reverts the whole user action
        // (matching removeLayer/renameLayout's multi-registration pattern).
        um.beginUndoGrouping()
        drawing.remove(lineID)
        um.endUndoGrouping()
        XCTAssertTrue(drawing.constraints.isEmpty)
        XCTAssertNil(drawing.entity(lineID))

        // One undo restores BOTH the entity and the dropped constraint.
        um.undo()
        XCTAssertNotNil(drawing.entity(lineID))
        XCTAssertEqual(drawing.constraints.count, 1)
    }

    // MARK: - Codable round-trip + back-compat

    func testTableCodableRoundTrip() throws {
        var t = ConstraintTable()
        t.add(Constraint.horizontal(line: id(1)))
        t.add(Constraint.distance(.init(entityID: id(1)), .init(entityID: id(2)), value: 12.5))
        t.add(Constraint.radius(circle: id(3), value: 4))

        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(ConstraintTable.self, from: data)
        XCTAssertEqual(back, t)
    }

    func testConstraintDecodesFromMinimalJSON() throws {
        // A constraint with only `kind` + `points` (no `id`, no `value`) decodes:
        // `id` minted fresh, `value` defaults 0 (additive back-compat).
        let json = """
        { "kind": { "geometric": { "_0": "horizontal" } },
          "points": [ { "entityID": { "rawValue": 1 }, "point": "start" },
                      { "entityID": { "rawValue": 1 }, "point": "end" } ] }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(Constraint.self, from: json)
        XCTAssertEqual(c.kind, .geometric(.horizontal))
        XCTAssertEqual(c.value, 0)
        XCTAssertEqual(c.entityIDs, [id(1)])
    }

    func testEmptyTableDecodesFromEmptyObject() throws {
        // A document payload with no `constraints` array (an old file) decodes to an
        // empty table.
        let json = "{}".data(using: .utf8)!
        let t = try JSONDecoder().decode(ConstraintTable.self, from: json)
        XCTAssertTrue(t.isEmpty)
    }
}
