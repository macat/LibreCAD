//
//  BlockOpsTests.swift
//  CADEngineTests
//
//  WAVE 2 — block-tool half (feature-catalog F9 tool + F10):
//   - `CADDrawing.makeBlockFromEntities`: a selection becomes a NAMED block whose
//     members are re-authored relative to a base point, and the originals are
//     replaced by ONE `.insert` referencing the block (placed AT the base point so
//     the geometry re-draws in place); the whole op is undoable.
//   - `CreateBlockTool`: captures the selection + a picked base point into a
//     `CreateBlockRequest`, applied via the model op (block creation is a model op,
//     NOT a `ToolEdit`).
//   - `ExplodeInsertTool`: replaces a selected `.insert` with its block members
//     transformed by the insert's placement (`.remove` + `.add` per member),
//     matching the resolve seam.
//   - round-trip: create-block then explode-insert ≈ the original geometry (identity
//     for a unit-scale insert at the block's base point).
//
//  Uniquely namespaced (`@Suite("block ops (create + explode-insert)")`) so it does
//  not collide with the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("block ops (create + explode-insert)")
struct BlockOpsTests {

    // MARK: - Helpers

    /// An UndoManager configured for unit testing (manual grouping).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A line from `a` to `b`.
    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    /// A circle.
    private func circle(_ c: Vector, _ r: Double, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .circle(CircleData(center: c, radius: r)))
    }

    /// The world endpoints of a line entity (for geometry comparison).
    private func lineEnds(_ rec: EntityRecord) -> (Vector, Vector)? {
        guard case .line(let l) = rec.kind else { return nil }
        return (l.start, l.end)
    }

    /// A drawing seeded with the given records (ids minted) under an UndoManager;
    /// returns the drawing + the assigned ids in order.
    private func seeded(_ records: [EntityRecord]) -> (CADDrawing, [EntityID]) {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        var ids: [EntityID] = []
        for r in records { ids.append(d.add(r)) }
        return (d, ids)
    }

    // MARK: - makeBlockFromEntities: the core model op

    @Test("a selection becomes a named block + ONE insert; originals removed")
    func selectionBecomesBlockPlusInsert() {
        let (d, ids) = seeded([
            line(Vector(10, 10), Vector(20, 10)),
            circle(Vector(10, 10), 3),
        ])
        #expect(d.count == 2)

        let result = d.makeBlockFromEntities(
            name: "WIDGET", basePoint: Vector(10, 10), ids: ids)
        let creation = try! #require(result)
        #expect(creation.blockName == "WIDGET")

        // The block exists with 2 members.
        let block = try! #require(d.blocks.block(named: "WIDGET"))
        #expect(block.entityIDs.count == 2)
        #expect(block.basePoint == Vector(0, 0))

        // The two originals are gone; the insert + the 2 members remain in the store.
        for id in ids { #expect(!d.contains(id)) }
        #expect(d.contains(creation.insertID))

        // The remaining top-level INSERT references the block at the base point.
        let insertRec = try! #require(d.entity(creation.insertID))
        guard case .insert(let data) = insertRec.kind else {
            Issue.record("the replacement is not an .insert"); return
        }
        #expect(data.blockName == "WIDGET")
        #expect(data.insertionPoint == Vector(10, 10))
        #expect(data.scale == Vector(1, 1))
        #expect(data.rotation == 0)
    }

    @Test("members are re-authored RELATIVE to the base point (local origin)")
    func membersAuthoredRelativeToBase() {
        let (d, ids) = seeded([ line(Vector(10, 10), Vector(20, 10)) ])
        let creation = try! #require(d.makeBlockFromEntities(
            name: "L", basePoint: Vector(10, 10), ids: ids))
        let block = try! #require(d.blocks.block(named: "L"))
        let memberID = try! #require(block.entityIDs.first)
        let member = try! #require(d.entity(memberID))
        // World (10,10)->(20,10) authored about base (10,10) ⇒ local (0,0)->(10,0).
        let (s, e) = try! #require(lineEnds(member))
        #expect(s == Vector(0, 0))
        #expect(e == Vector(10, 0))
        #expect(member.isSelected == false)
        _ = creation
    }

    @Test("the placed insert resolves to the members back in their ORIGINAL place")
    func insertResolvesBackToOriginal() {
        let (d, ids) = seeded([ line(Vector(10, 10), Vector(20, 10)) ])
        let creation = try! #require(d.makeBlockFromEntities(
            name: "L", basePoint: Vector(10, 10), ids: ids))
        let insertRec = try! #require(d.entity(creation.insertID))
        let geo = insertRec.resolve(d.makeResolveContext())
        let pts = geo.polylines.flatMap { $0.points }
        // The resolved geometry sits back at the original world endpoints.
        #expect(pts.contains { ($0 - Vector(10, 10)).magnitude < 1e-9 })
        #expect(pts.contains { ($0 - Vector(20, 10)).magnitude < 1e-9 })
    }

    @Test("a name clash is de-duplicated via newName")
    func nameClashDeduplicated() {
        let (d, ids) = seeded([ line(Vector(0, 0), Vector(1, 0)),
                                line(Vector(2, 0), Vector(3, 0), id: 0) ])
        // First block takes "BOX".
        _ = d.makeBlockFromEntities(name: "BOX", basePoint: Vector(0, 0), ids: [ids[0]])
        // Second request for "BOX" gets a de-duplicated name.
        let second = try! #require(d.makeBlockFromEntities(
            name: "BOX", basePoint: Vector(0, 0), ids: [ids[1]]))
        #expect(second.blockName != "BOX")
        #expect(d.blocks.contains("BOX"))
        #expect(d.blocks.contains(second.blockName))
    }

    @Test("an empty / vanished selection is a no-op returning nil")
    func emptySelectionNoOp() {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        #expect(d.makeBlockFromEntities(name: "X", basePoint: Vector(0, 0), ids: []) == nil)
        // Ids not in the drawing also produce nil.
        #expect(d.makeBlockFromEntities(
            name: "X", basePoint: Vector(0, 0), ids: [EntityID(999)]) == nil)
        #expect(d.blocks.isEmpty)
        #expect(d.count == 0)
    }

    @Test("a blank name is rejected (nil, nothing created)")
    func blankNameRejected() {
        let (d, ids) = seeded([ line(Vector(0, 0), Vector(1, 0)) ])
        #expect(d.makeBlockFromEntities(name: "   ", basePoint: Vector(0, 0), ids: ids) == nil)
        #expect(d.blocks.isEmpty)
        #expect(d.contains(ids[0]))   // original untouched
    }

    @Test("the whole creation is undoable (one group restores the originals)")
    func creationUndoable() {
        // Seed WITHOUT the undo manager (so the seed adds don't register undo), then
        // attach it for the operation under test (the CADDrawingTests pattern).
        let d = CADDrawing()
        let a = d.add(line(Vector(10, 10), Vector(20, 10)))
        let b = d.add(circle(Vector(10, 10), 3))

        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        _ = d.makeBlockFromEntities(name: "W", basePoint: Vector(10, 10), ids: [a, b])
        um.endUndoGrouping()
        #expect(d.blocks.contains("W"))
        #expect(!d.contains(a) && !d.contains(b))

        um.undo()
        // The originals are back; the block + members + insert are gone.
        #expect(d.contains(a) && d.contains(b))
        #expect(d.blocks.isEmpty)
        // The originals resolve to their original geometry.
        let restored = try! #require(d.entity(a))
        let (s, e) = try! #require(lineEnds(restored))
        #expect(s == Vector(10, 10) && e == Vector(20, 10))

        um.redo()
        #expect(d.blocks.contains("W"))
        #expect(!d.contains(a) && !d.contains(b))
    }

    // MARK: - CreateBlockTool

    @Test("CreateBlockTool: a base-point click records a CreateBlockRequest")
    func createBlockToolRecordsRequest() {
        let sel = [ line(Vector(10, 10), Vector(20, 10), id: 1),
                    circle(Vector(10, 10), 3, id: 2) ]
        let ctx = ToolContext(selected: sel, entity: { _ in nil }, gridSpacing: nil)
        var tool = CreateBlockTool(blockName: "WIDGET")
        // Move first (captures selection + drives preview), then click the base point.
        _ = tool.handle(.move(Vector(10, 10)), context: ctx)
        #expect(!tool.preview.isEmpty)             // base-point crosshair preview
        let outcome = tool.handle(.click(Vector(10, 10)), context: ctx)
        #expect(outcome == .finished)
        let req = try! #require(tool.pendingCreation)
        #expect(req.name == "WIDGET")
        #expect(req.basePoint == Vector(10, 10))
        #expect(req.ids == [EntityID(1), EntityID(2)])
    }

    @Test("CreateBlockTool: inert with no selection; cancel clears the request")
    func createBlockToolInertAndCancel() {
        var tool = CreateBlockTool(blockName: "B")
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        #expect(tool.pendingCreation == nil)
        #expect(tool.status == "Select entities to make into a block first")

        // With a selection captured then cancelled, the request stays nil.
        let ctx = ToolContext(selected: [line(Vector(0, 0), Vector(1, 0), id: 5)],
                              entity: { _ in nil }, gridSpacing: nil)
        _ = tool.handle(.move(Vector(0, 0)), context: ctx)
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.pendingCreation == nil)
    }

    @Test("CreateBlockTool.apply drives the model op end-to-end")
    func createBlockToolApply() {
        let (d, ids) = seeded([ line(Vector(10, 10), Vector(20, 10)),
                                circle(Vector(10, 10), 3) ])
        let req = CreateBlockRequest(name: "W", basePoint: Vector(10, 10), ids: ids)
        let creation = try! #require(CreateBlockTool.apply(req, to: d))
        #expect(d.blocks.block(named: creation.blockName)?.entityIDs.count == 2)
        #expect(d.contains(creation.insertID))
        for id in ids { #expect(!d.contains(id)) }
    }

    // MARK: - ExplodeInsertTool

    @Test("ExplodeInsertTool: removes the insert and adds the placed members")
    func explodeInsertRemovesAndAdds() {
        // A block "L" with one local member (0,0)->(10,0); an insert at (5,5).
        let member = line(Vector(0, 0), Vector(10, 0), id: 1)
        let insert = EntityRecord(id: EntityID(100),
            kind: .insert(InsertData(blockName: "L", insertionPoint: Vector(5, 5))))
        let provider: @Sendable (String) -> [EntityRecord]? = { $0 == "L" ? [member] : nil }
        let ctx = ToolContext(selected: [insert], entity: { _ in nil }, gridSpacing: nil)

        var tool = ExplodeInsertTool(blockMembers: provider)
        let outcome = tool.handle(.commit, context: ctx)
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit, got \(outcome)"); return
        }
        // .remove(insert) + .add(member).
        #expect(edits.count == 2)
        guard case .remove(let removedID) = edits[0] else {
            Issue.record("first edit should remove the insert"); return
        }
        #expect(removedID == EntityID(100))
        guard case .add(let added) = edits[1], case .line(let l) = added.kind else {
            Issue.record("second edit should add the placed line member"); return
        }
        // Placed back at insertion point: (0,0)->(10,0) + (5,5) = (5,5)->(15,5).
        #expect(l.start == Vector(5, 5))
        #expect(l.end == Vector(15, 5))
        #expect(added.id == .placeholder)   // app re-mints
    }

    @Test("ExplodeInsertTool: a MINSERT array explodes into all cells")
    func explodeMinsertArray() {
        let member = EntityRecord(id: EntityID(1),
            kind: .point(PointData(position: Vector(0, 0))))
        let insert = EntityRecord(id: EntityID(2),
            kind: .insert(InsertData(blockName: "P", insertionPoint: Vector(0, 0),
                                     rows: 2, cols: 3, rowSpacing: 100, colSpacing: 10)))
        let provider: @Sendable (String) -> [EntityRecord]? = { $0 == "P" ? [member] : nil }
        let ctx = ToolContext(selected: [insert], entity: { _ in nil }, gridSpacing: nil)
        var tool = ExplodeInsertTool(blockMembers: provider)
        guard case .commit(let edits) = tool.handle(.commit, context: ctx) else {
            Issue.record("expected a commit"); return
        }
        // 1 remove + 6 placed points.
        #expect(edits.count == 7)
        let pts: [Vector] = edits.compactMap { e in
            if case .add(let r) = e, case .point(let p) = r.kind { return p.position }
            return nil
        }
        #expect(pts.count == 6)
        for r in 0..<2 { for c in 0..<3 {
            let expected = Vector(Double(c) * 10, Double(r) * 100)
            #expect(pts.contains { ($0 - expected).magnitude < 1e-9 })
        } }
    }

    @Test("ExplodeInsertTool: inert with no insert / missing block")
    func explodeInsertInert() {
        // No selection.
        var tool = ExplodeInsertTool()
        #expect(tool.handle(.commit, context: .empty) == .none)
        #expect(tool.status == "Select a block reference to explode first")

        // A selected insert whose block is unknown explodes to nothing.
        let insert = EntityRecord(id: EntityID(1),
            kind: .insert(InsertData(blockName: "NOPE", insertionPoint: Vector(0, 0))))
        let ctx = ToolContext(selected: [insert], entity: { _ in nil }, gridSpacing: nil)
        var tool2 = ExplodeInsertTool(blockMembers: { _ in nil })
        #expect(tool2.handle(.commit, context: ctx) == .none)
    }

    // MARK: - Round-trip: create-block then explode-insert ≈ identity

    @Test("create-block then explode-insert reproduces the original geometry")
    func createThenExplodeIsIdentity() {
        // Two originals in world space.
        let origLine = line(Vector(10, 10), Vector(20, 10))
        let origCircle = circle(Vector(15, 12), 4)
        let (d, ids) = seeded([origLine, origCircle])

        // CREATE: fold them into a block "RT" with base point (10,10).
        let creation = try! #require(d.makeBlockFromEntities(
            name: "RT", basePoint: Vector(10, 10), ids: ids))

        // EXPLODE: take the placed insert + the drawing's block members, expand it.
        let insertRec = try! #require(d.entity(creation.insertID))
        guard case .insert(let data) = insertRec.kind else {
            Issue.record("no insert to explode"); return
        }
        let members = d.blockMembersSnapshot()
        let exploded = ExplodeInsertTool.explode(data) { members[$0] }
        #expect(exploded.count == 2)

        // The exploded geometry equals the ORIGINAL world geometry (identity for a
        // unit-scale insert at the block's base point).
        let lines = exploded.compactMap { lineEnds($0) }
        #expect(lines.contains { ($0.0 - Vector(10, 10)).magnitude < 1e-9
                              && ($0.1 - Vector(20, 10)).magnitude < 1e-9 })
        let circles = exploded.compactMap { rec -> CircleData? in
            if case .circle(let c) = rec.kind { return c } else { return nil }
        }
        let c = try! #require(circles.first)
        #expect((c.center - Vector(15, 12)).magnitude < 1e-9)
        #expect(abs(c.radius - 4) < 1e-9)
    }

    @Test("round-trip survives a rotated + scaled insert (resolve == explode)")
    func roundTripUnderTransformMatchesResolve() {
        // A block authored locally; an insert that rotates 90° and scales 2× — the
        // exploded records must match what resolve places (the inverse-consistency
        // the tool guarantees).
        let member = line(Vector(0, 0), Vector(10, 0), id: 1)
        let data = InsertData(blockName: "L", insertionPoint: Vector(5, 5),
                              scale: Vector(2, 2), rotation: .pi / 2)
        let members: [String: [EntityRecord]] = ["L": [member]]

        let exploded = ExplodeInsertTool.explode(data) { members[$0] }
        let firstExploded = try! #require(exploded.first)
        let (s, e) = try! #require(lineEnds(firstExploded))

        // Resolve the same insert and compare endpoints (resolve transforms members
        // by the SAME insertTransform the explode uses).
        let ctx = ResolveContext(blockProvider: { members[$0] })
        let resolved = EntityKind.insert(data).resolve(pen: .toolPreview, ctx: ctx)
        let rpts = resolved.polylines.flatMap { $0.points }
        #expect(rpts.contains { ($0 - s).magnitude < 1e-9 })
        #expect(rpts.contains { ($0 - e).magnitude < 1e-9 })
        // (0,0)->scale->(0,0)->rot->(0,0)->+ins(5,5) = (5,5);
        // (10,0)->scale->(20,0)->rot90->(0,20)->+ins(5,5) = (5,25).
        #expect((s - Vector(5, 5)).magnitude < 1e-9)
        #expect((e - Vector(5, 25)).magnitude < 1e-9)
    }
}
