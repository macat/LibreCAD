//
//  DrawOrderOpsTests.swift
//  CADEngineTests
//
//  The v5 "Arrange" (draw order) + "Revert direction" engine ops (F16):
//    • the pure `DrawOrder` raise/lower permutation math,
//    • the undoable `CADDrawing` reorder ops (raise/lower/front/back) + their
//      `indexByID`/order consistency and ⌘Z,
//    • the pure `EntityDirection.reversed` flips (line endpoints, polyline vertex
//      order + bulge semantics, arc/ellipse sweep, spline control points),
//    • the undoable `CADDrawing.revertDirection`.
//
//  Suite names are domain-prefixed (CONVENTIONS.md "Namespace test-suite type
//  names by domain") to avoid a test-target namespace clash with parallel agents.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Pure draw-order permutation math

@Suite("DrawOrder permutation (F16)")
struct DrawOrderPermutationTests {

    private func ids(_ raw: [UInt64]) -> [EntityID] { raw.map(EntityID.init) }

    @Test("raised moves a single entity one step toward the front")
    func raiseOne() {
        let order = ids([1, 2, 3, 4])           // 4 is front-most
        let out = DrawOrder.raised(order, moving: [EntityID(2)])
        #expect(out == ids([1, 3, 2, 4]))       // 2 swapped past 3
    }

    @Test("raised on the front-most entity is a no-op")
    func raiseFrontmost() {
        let order = ids([1, 2, 3])
        #expect(DrawOrder.raised(order, moving: [EntityID(3)]) == order)
    }

    @Test("lowered moves a single entity one step toward the back")
    func lowerOne() {
        let order = ids([1, 2, 3, 4])
        let out = DrawOrder.lowered(order, moving: [EntityID(3)])
        #expect(out == ids([1, 3, 2, 4]))       // 3 swapped behind 2
    }

    @Test("lowered on the back-most entity is a no-op")
    func lowerBackmost() {
        let order = ids([1, 2, 3])
        #expect(DrawOrder.lowered(order, moving: [EntityID(1)]) == order)
    }

    @Test("a contiguous moving block slides up together (no self leap-frog)")
    func raiseBlock() {
        let order = ids([1, 2, 3, 4])
        // Move {2,3} up one: they slide past 4 as a block, keeping 2 before 3.
        let out = DrawOrder.raised(order, moving: [EntityID(2), EntityID(3)])
        #expect(out == ids([1, 4, 2, 3]))
    }

    @Test("moving everything / nothing is a no-op")
    func degenerate() {
        let order = ids([1, 2, 3])
        #expect(DrawOrder.raised(order, moving: []) == order)
        #expect(DrawOrder.raised(order, moving: Set(order)) == order)
        #expect(DrawOrder.lowered(order, moving: []) == order)
    }
}

// MARK: - Undoable CADDrawing reorder ops

@MainActor
@Suite("CADDrawing draw order (F16)")
struct CADDrawingDrawOrderTests {

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: .placeholder, kind: .line(LineData(start: a, end: b)))
    }

    private func testUndoManager() -> UndoManager {
        let um = UndoManager(); um.groupsByEvent = false; return um
    }

    /// A drawing with three lines; returns (drawing, [id0, id1, id2]) in draw order.
    private func threeLines() -> (CADDrawing, [EntityID]) {
        let d = CADDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        let b = d.add(line(Vector(0, 1), Vector(1, 1)))
        let c = d.add(line(Vector(0, 2), Vector(1, 2)))
        return (d, [a, b, c])
    }

    private func currentOrder(_ d: CADDrawing) -> [EntityID] { d.entities.map(\.id) }

    @Test("storageIndex reflects draw order (front-most == highest index)")
    func storageIndex() {
        let (d, ids) = threeLines()
        #expect(d.storageIndex(of: ids[0]) == 0)
        #expect(d.storageIndex(of: ids[1]) == 1)
        #expect(d.storageIndex(of: ids[2]) == 2)
        #expect(d.storageIndex(of: EntityID(999)) == nil)
    }

    @Test("bringToFront moves the selection to the end of the order")
    func bringToFront() {
        let (d, ids) = threeLines()
        #expect(d.bringToFront([ids[0]]))
        #expect(currentOrder(d) == [ids[1], ids[2], ids[0]])
        // indexByID stayed consistent with the new order.
        #expect(d.storageIndex(of: ids[0]) == 2)
        #expect(d.storageIndex(of: ids[1]) == 0)
    }

    @Test("sendToBack moves the selection to the front of the order")
    func sendToBack() {
        let (d, ids) = threeLines()
        #expect(d.sendToBack([ids[2]]))
        #expect(currentOrder(d) == [ids[2], ids[0], ids[1]])
    }

    @Test("raise/lower move one step and are inverses")
    func raiseLower() {
        let (d, ids) = threeLines()                    // [0,1,2]
        #expect(d.raise([ids[0]]))
        #expect(currentOrder(d) == [ids[1], ids[0], ids[2]])
        #expect(d.lower([ids[0]]))
        #expect(currentOrder(d) == [ids[0], ids[1], ids[2]])   // back to start
    }

    @Test("a reorder is one undoable step (⌘Z restores the prior order)")
    func reorderUndo() {
        let (d, ids) = threeLines()
        let um = testUndoManager(); d.undoManager = um
        let before = currentOrder(d)

        um.beginUndoGrouping()
        #expect(d.bringToFront([ids[0]]))
        um.endUndoGrouping()
        #expect(currentOrder(d) != before)

        #expect(um.canUndo)
        um.undo()
        #expect(currentOrder(d) == before)              // order restored
        #expect(d.storageIndex(of: ids[0]) == 0)        // index restored too

        um.redo()
        #expect(currentOrder(d) == [ids[1], ids[2], ids[0]])
    }

    @Test("a no-op reorder (already at the front) returns false + no undo")
    func reorderNoOp() {
        let (d, ids) = threeLines()
        let um = testUndoManager(); d.undoManager = um
        #expect(!d.raise([ids[2]]))                      // 2 is front-most → no move
        #expect(currentOrder(d) == ids)
        #expect(!um.canUndo)
    }

    @Test("reorderEntities rejects a non-permutation (missing/extra ids)")
    func reorderRejectsInvalid() {
        let (d, ids) = threeLines()
        #expect(!d.reorderEntities([ids[0], ids[1]]))    // too short
        #expect(!d.reorderEntities([ids[0], ids[1], ids[0]]))  // dup
        #expect(!d.reorderEntities([ids[0], ids[1], EntityID(999)]))  // unknown
        #expect(currentOrder(d) == ids)                  // unchanged
    }

    @Test("arrange ops are no-ops on an empty id set")
    func emptySelection() {
        let (d, ids) = threeLines()
        #expect(!d.bringToFront([]))
        #expect(!d.raise([]))
        #expect(currentOrder(d) == ids)
    }
}

// MARK: - Pure revert-direction flips

@Suite("EntityDirection revert (F16)")
struct EntityDirectionRevertTests {

    @Test("line revert swaps endpoints")
    func line() {
        let k = EntityKind.line(LineData(start: Vector(1, 2), end: Vector(7, 9)))
        guard case .line(let r)? = EntityDirection.reversed(k) else {
            Issue.record("line should revert"); return
        }
        #expect(r.start == Vector(7, 9))
        #expect(r.end == Vector(1, 2))
    }

    @Test("arc revert swaps angles and toggles the sweep flag")
    func arc() {
        let k = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 5,
                                       startAngle: 0.1, endAngle: 1.2, reversed: false))
        guard case .arc(let r)? = EntityDirection.reversed(k) else {
            Issue.record("arc should revert"); return
        }
        #expect(r.startAngle == 1.2)
        #expect(r.endAngle == 0.1)
        #expect(r.reversed == true)
        #expect(r.center == Vector(0, 0) && r.radius == 5)   // shape unchanged
    }

    @Test("ellipse revert swaps angles and toggles the sweep flag")
    func ellipse() {
        let k = EntityKind.ellipse(EllipseData(center: Vector(1, 1), majorP: Vector(4, 0),
                                               ratio: 0.5, startAngle: 0.2, endAngle: 2.0,
                                               reversed: false))
        guard case .ellipse(let r)? = EntityDirection.reversed(k) else {
            Issue.record("ellipse should revert"); return
        }
        #expect(r.startAngle == 2.0 && r.endAngle == 0.2 && r.reversed == true)
        #expect(r.majorP == Vector(4, 0) && r.ratio == 0.5)  // shape unchanged
    }

    @Test("polyline revert reverses vertex order and re-homes negated bulges")
    func polyline() {
        // 3 vertices, open: v0--(b=0.5)-->v1--(b=-0.3)-->v2 (v2 carries no bulge).
        let v = [
            PolylineVertex(point: Vector(0, 0), bulge: 0.5),
            PolylineVertex(point: Vector(1, 0), bulge: -0.3),
            PolylineVertex(point: Vector(2, 0), bulge: 0.0),
        ]
        let k = EntityKind.polyline(PolylineData(vertices: v, closed: false))
        guard case .polyline(let r)? = EntityDirection.reversed(k) else {
            Issue.record("polyline should revert"); return
        }
        // Points reversed.
        #expect(r.vertices.map(\.point) == [Vector(2, 0), Vector(1, 0), Vector(0, 0)])
        // The new first segment (v2→v1) is the old v1→v2 segment (bulge -0.3),
        // negated → +0.3; the new second segment (v1→v0) is the old v0→v1 (0.5),
        // negated → -0.5; the new last vertex carries no bulge.
        #expect(abs(r.vertices[0].bulge - 0.3) < 1e-12)
        #expect(abs(r.vertices[1].bulge + 0.5) < 1e-12)
        #expect(r.vertices[2].bulge == 0.0)
        #expect(r.closed == false)
    }

    @Test("closed polyline revert carries the closing-segment bulge correctly")
    func closedPolyline() {
        // Closed triangle: v0--(b=0.5)-->v1--(b=0.2)-->v2--(b=-0.1)-->v0.
        let v = [
            PolylineVertex(point: Vector(0, 0), bulge: 0.5),
            PolylineVertex(point: Vector(2, 0), bulge: 0.2),
            PolylineVertex(point: Vector(1, 2), bulge: -0.1),
        ]
        let k = EntityKind.polyline(PolylineData(vertices: v, closed: true))
        guard case .polyline(let r)? = EntityDirection.reversed(k) else {
            Issue.record("closed polyline should revert"); return
        }
        #expect(r.closed == true)
        #expect(r.vertices.map(\.point) == [Vector(1, 2), Vector(2, 0), Vector(0, 0)])
        // new seg v2→v1 == old v1→v2 (0.2) negated; v1→v0 == old v0→v1 (0.5) negated;
        // closing v0→v2 == old v2→v0 (-0.1) negated → +0.1.
        #expect(abs(r.vertices[0].bulge + 0.2) < 1e-12)
        #expect(abs(r.vertices[1].bulge + 0.5) < 1e-12)
        #expect(abs(r.vertices[2].bulge - 0.1) < 1e-12)
    }

    @Test("spline revert reverses control points (and weights/knots when present)")
    func spline() {
        let k = EntityKind.spline(SplineData(
            degree: 2,
            controlPoints: [Vector(0, 0), Vector(1, 1), Vector(2, 0)],
            knots: [0, 0, 0, 1, 1, 1],
            weights: [1, 2, 1],
            closed: false))
        guard case .spline(let r)? = EntityDirection.reversed(k) else {
            Issue.record("spline should revert"); return
        }
        #expect(r.controlPoints == [Vector(2, 0), Vector(1, 1), Vector(0, 0)])
        #expect(r.weights == [1, 2, 1])              // symmetric here, but reversed
        #expect(r.knots.count == 6)                  // mirrored about its span
        #expect(r.knots.first == 0 && r.knots.last == 1)
    }

    @Test("non-directional kinds revert to nil (no-op)")
    func nonDirectional() {
        #expect(EntityDirection.reversed(.circle(CircleData(center: Vector(0, 0), radius: 1))) == nil)
        #expect(EntityDirection.reversed(.point(PointData(position: Vector(0, 0)))) == nil)
    }
}

// MARK: - Undoable CADDrawing.revertDirection

@MainActor
@Suite("CADDrawing revert direction (F16)")
struct CADDrawingRevertDirectionTests {

    private func testUndoManager() -> UndoManager {
        let um = UndoManager(); um.groupsByEvent = false; return um
    }

    @Test("revertDirection flips a line's endpoints, undoable, preserving id/pen")
    func revertLineUndoable() {
        let d = CADDrawing()
        // Set up the entity BEFORE wiring the undo manager so the setup add()
        // registers no undo (the manual-grouping test UM has no open group yet).
        let id = d.add(EntityRecord(id: .placeholder, layer: LayerID("walls"),
                                    kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0)))))
        let um = testUndoManager(); d.undoManager = um

        um.beginUndoGrouping()
        #expect(d.revertDirection(of: id))
        um.endUndoGrouping()

        guard case .line(let r)? = d.entity(id)?.kind else { Issue.record("missing"); return }
        #expect(r.start == Vector(5, 0) && r.end == Vector(0, 0))
        #expect(d.entity(id)?.layer.name == "walls")    // attrs preserved

        um.undo()
        guard case .line(let back)? = d.entity(id)?.kind else { Issue.record("missing"); return }
        #expect(back.start == Vector(0, 0) && back.end == Vector(5, 0))
    }

    @Test("revertDirection on a non-directional entity is a no-op")
    func revertNoOp() {
        let d = CADDrawing()
        let id = d.add(EntityRecord(id: .placeholder,
                                    kind: .circle(CircleData(center: Vector(0, 0), radius: 3))))
        #expect(!d.revertDirection(of: id))
        #expect(!d.revertDirection(of: EntityID(999)))  // unknown id
    }
}
