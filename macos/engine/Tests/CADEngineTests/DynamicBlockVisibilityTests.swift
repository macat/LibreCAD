//
//  DynamicBlockVisibilityTests.swift
//  CADEngineTests
//
//  Tests for the FIRST dynamic-block feature — VISIBILITY STATES (block-features
//  §9; dynamic-blocks-plan §3/DB-1), engine-side and UNWIRED:
//   - `BlockEvaluator.evaluate` filters members to the active visibility state;
//     unknown / nil active state ⇒ the default (first) state (§9.5);
//   - a block with NO dynamic def resolves all members unchanged;
//   - PURITY / ISOLATION (critic Fix 3): the same dynamic block evaluated at two
//     different instance states yields INDEPENDENT results; a MINSERT grid of a
//     dynamic insert yields identical cells with the source members unmutated;
//   - back-compat Codable: old `Block`/`InsertData` JSON (no `dynamic` key) decodes
//     with `dynamic == nil`; a block-with-states + an insert-with-an-active-state
//     round-trip;
//   - the undoable engine mutators (`addVisibilityState` / `setMemberVisibility` /
//     `removeVisibilityState` / `setBlockDynamic`) are one-⌘Z undoable; no-ops skip.
//
//  Uniquely namespaced (`@Suite("dynamic block — visibility states")`) so it does
//  not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("dynamic block — visibility states", .serialized)
@MainActor
struct DynamicBlockVisibilityTests {

    // MARK: - Helpers

    /// A circle member with a stable id (distinct radius lets us identify it in
    /// resolved geometry — each circle resolves to one closed polyline).
    private func circle(_ id: UInt64, center: Vector = Vector(0, 0), radius: Double) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .circle(CircleData(center: center, radius: radius)))
    }

    /// Three members m1=r1, m2=r2, m3=r3 (ids 1/2/3) — visually distinguishable.
    private func threeMembers() -> [EntityRecord] {
        [circle(1, radius: 1), circle(2, radius: 2), circle(3, radius: 3)]
    }

    /// A `DynamicBlockDef` with two states: A={m1,m2}, B={m3}.
    private func twoStateDef() -> DynamicBlockDef {
        DynamicBlockDef(visibilityStates: [
            BlockVisibilityState(name: "A", visibleMemberIDs: [EntityID(1), EntityID(2)]),
            BlockVisibilityState(name: "B", visibleMemberIDs: [EntityID(3)]),
        ])
    }

    /// The ids of the members in an evaluated result (order-preserving).
    private func ids(_ recs: [EntityRecord]) -> [EntityID] { recs.map(\.id) }

    /// An UndoManager configured for manual grouping (the BlockOps test pattern).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// Runs `body` as ONE undo group (begin/end) — so `um.undo()` reverts it whole.
    private func grouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    /// A drawing whose block "VALVE" holds the three circle members + the given
    /// dynamic def, with one insert of it carrying `state` active. Returns the
    /// drawing and the insert id (so a test can resolve that one insert).
    private func drawingWithDynamicBlock(def: DynamicBlockDef?,
                                         insertState: InsertDynamicState?) -> (CADDrawing, EntityID) {
        // No undo manager — these are resolve/integration drawings, not undo tests
        // (so the seed `add`s register nothing).
        let d = CADDrawing()
        // Add members with id 0 so `add` MINTS fresh ids (avoids colliding the
        // hand-picked 1/2/3 with the insert's minted id). Radii 1/2/3 keep them
        // distinguishable in resolved geometry, in member order.
        var memberIDs: [EntityID] = []
        for r in [1.0, 2.0, 3.0] {
            memberIDs.append(d.add(circle(0, radius: r)))
        }
        // Member ids are minted by `add`; rebuild the def/state against the minted ids.
        let mapped = remap(def: def, originalToMinted: memberIDs)
        let block = Block(name: "VALVE", entityIDs: memberIDs, dynamic: mapped.def)
        d.addBlock(block)
        let insert = EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "VALVE",
                                     insertionPoint: Vector(0, 0),
                                     dynamic: insertState))
        )
        let insertID = d.add(insert)
        return (d, insertID)
    }

    /// Remaps a def authored against ids 1/2/3 to the actually-minted member ids
    /// (ids are minted sequentially by `add`, so 1↦minted[0], 2↦minted[1], …).
    private func remap(def: DynamicBlockDef?, originalToMinted minted: [EntityID])
        -> (def: DynamicBlockDef?, _: Void) {
        guard let def else { return (nil, ()) }
        func map(_ id: EntityID) -> EntityID? {
            switch id.rawValue { case 1: return minted[0]; case 2: return minted[1]
                                 case 3: return minted[2]; default: return nil }
        }
        let states = def.visibilityStates.map { s in
            BlockVisibilityState(id: s.id, name: s.name,
                                 visibleMemberIDs: Set(s.visibleMemberIDs.compactMap(map)))
        }
        return (DynamicBlockDef(visibilityStates: states), ())
    }

    // MARK: - Visibility filter (the core behavior)

    @Test("active state A resolves only m1,m2; B resolves only m3")
    func activeStateFiltersMembers() {
        let members = threeMembers()
        let def = twoStateDef()

        let a = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(activeVisibilityState: "A"))
        #expect(ids(a) == [EntityID(1), EntityID(2)])

        let b = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(activeVisibilityState: "B"))
        #expect(ids(b) == [EntityID(3)])
    }

    @Test("nil active state falls back to the DEFAULT (first) state")
    func nilActiveUsesDefaultState() {
        let members = threeMembers()
        let def = twoStateDef() // default = "A" = {m1,m2}

        let nilState = BlockEvaluator.evaluate(def, members: members,
                                               instanceState: InsertDynamicState(activeVisibilityState: nil))
        #expect(ids(nilState) == [EntityID(1), EntityID(2)])

        // No instance state at all (a plain insert of a dynamic block) → default too.
        let noState = BlockEvaluator.evaluate(def, members: members, instanceState: nil)
        #expect(ids(noState) == [EntityID(1), EntityID(2)])
    }

    @Test("an UNKNOWN active state name falls back to the default state")
    func unknownActiveUsesDefaultState() {
        let members = threeMembers()
        let def = twoStateDef()
        let unknown = BlockEvaluator.evaluate(
            def, members: members,
            instanceState: InsertDynamicState(activeVisibilityState: "Nope"))
        #expect(ids(unknown) == [EntityID(1), EntityID(2)])
    }

    @Test("a block with NO dynamic def resolves ALL members unchanged")
    func noDynamicDefResolvesAllMembers() {
        let members = threeMembers()
        // nil def
        let plain = BlockEvaluator.evaluate(nil, members: members,
                                            instanceState: InsertDynamicState(activeVisibilityState: "A"))
        #expect(ids(plain) == [EntityID(1), EntityID(2), EntityID(3)])
        // empty def (no states)
        let empty = BlockEvaluator.evaluate(DynamicBlockDef(), members: members, instanceState: nil)
        #expect(ids(empty) == [EntityID(1), EntityID(2), EntityID(3)])
    }

    @Test("a state visible set referencing missing ids resolves to the present subset")
    func missingVisibleIDsAreSimplyAbsent() {
        let members = [circle(1, radius: 1), circle(2, radius: 2)] // no m3 present
        let def = DynamicBlockDef(visibilityStates: [
            BlockVisibilityState(name: "X", visibleMemberIDs: [EntityID(2), EntityID(99)]),
        ])
        let r = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(activeVisibilityState: "X"))
        #expect(ids(r) == [EntityID(2)])
    }

    // MARK: - Purity / isolation (critic Fix 3)

    @Test("same dynamic block at two instance states yields INDEPENDENT results")
    func twoInstancesAreIndependent() {
        let members = threeMembers()
        let def = twoStateDef()

        // Evaluate B first, then A, from the SAME source members — A must not be
        // contaminated by B (no shared mutable state / no aliasing).
        let b = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(activeVisibilityState: "B"))
        let a = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(activeVisibilityState: "A"))
        #expect(ids(b) == [EntityID(3)])
        #expect(ids(a) == [EntityID(1), EntityID(2)])
        // The source members are untouched (count + ids intact).
        #expect(ids(members) == [EntityID(1), EntityID(2), EntityID(3)])
    }

    @Test("two SIBLING dynamic inserts in one drawing resolve to their own states")
    func siblingInsertsResolveOwnStates() {
        // Drawing with the block + member ids minted; add a SECOND insert at "B".
        let (d, insertA) = drawingWithDynamicBlock(
            def: twoStateDef(),
            insertState: InsertDynamicState(activeVisibilityState: "A"))
        let insertB = d.add(EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "VALVE", insertionPoint: Vector(50, 0),
                                     dynamic: InsertDynamicState(activeVisibilityState: "B")))))

        let ctx = d.makeResolveContext()
        let geoA = d.entity(insertA)!.resolve(ctx)
        let geoB = d.entity(insertB)!.resolve(ctx)

        // State A = {r1,r2} ⇒ 2 closed polylines; B = {r3} ⇒ 1.
        #expect(geoA.polylines.count == 2)
        #expect(geoB.polylines.count == 1)
        // B's single circle has radius 3 (its closed polyline points are ~3 from center).
        let bPts = geoB.polylines.first!.points
        for p in bPts { #expect(abs((p - Vector(50, 0)).magnitude - 3) < 1e-6) }
    }

    @Test("a MINSERT grid of a dynamic insert yields identical cells; source unmutated")
    func minsertGridCellsIdenticalAndPure() {
        let (d, _) = drawingWithDynamicBlock(def: twoStateDef(), insertState: nil)
        // Replace the existing insert with a 2x2 MINSERT of the SAME dynamic block at "B".
        let grid = EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "VALVE", insertionPoint: Vector(0, 0),
                                     rows: 2, cols: 2, rowSpacing: 100, colSpacing: 100,
                                     dynamic: InsertDynamicState(activeVisibilityState: "B"))))
        let gridID = d.add(grid)
        let ctx = d.makeResolveContext()
        let geo = d.entity(gridID)!.resolve(ctx)

        // 4 cells × (state B = 1 member) = 4 closed polylines, each radius-3.
        #expect(geo.polylines.count == 4)
        for pl in geo.polylines {
            // every cell's circle has radius 3 (relative to its own cell center)
            let c = pl.points.reduce(Vector(0, 0)) { $0 + $1 } / Double(pl.points.count)
            for p in pl.points { #expect(abs((p - c).magnitude - 3) < 1e-6) }
        }
        // Re-resolving yields the same count (no accumulated mutation of the snapshot).
        let geo2 = d.entity(gridID)!.resolve(d.makeResolveContext())
        #expect(geo2.polylines.count == 4)
    }

    @Test("resolveInsert evaluates visibility through the drawing context")
    func resolveInsertHonorsVisibilityViaContext() {
        let (d, insertID) = drawingWithDynamicBlock(
            def: twoStateDef(),
            insertState: InsertDynamicState(activeVisibilityState: "B"))
        let geo = d.entity(insertID)!.resolve(d.makeResolveContext())
        #expect(geo.polylines.count == 1) // only m3 visible in state B
    }

    @Test("a plain (non-dynamic) insert still resolves ALL members — unchanged behavior")
    func plainInsertUnaffected() {
        // Same three members, but the block has NO dynamic def and the insert has
        // no dynamic state — must resolve all 3 (the existing insert contract).
        let (d, insertID) = drawingWithDynamicBlock(def: nil, insertState: nil)
        let geo = d.entity(insertID)!.resolve(d.makeResolveContext())
        #expect(geo.polylines.count == 3)
    }

    // MARK: - Back-compat Codable

    @Test("old Block JSON (no `dynamic` key) decodes with dynamic == nil")
    func oldBlockJSONDecodesNilDynamic() throws {
        // A pre-dynamic Block: only name/entityIDs/isFrozen (basePoint omitted →
        // its decodeIfPresent default applies, exactly like an old saved file).
        let json = """
        {"name":"OLD","entityIDs":[],"isFrozen":false}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(Block.self, from: json)
        #expect(block.name == "OLD")
        #expect(block.dynamic == nil)
        #expect(block.isDynamic == false)
        // The pre-existing attributeDefs back-compat still holds (empty, no throw).
        #expect(block.attributeDefs.isEmpty)
    }

    @Test("old InsertData JSON (no `dynamic` key) decodes with dynamic == nil")
    func oldInsertJSONDecodesNilDynamic() throws {
        // `insertionPoint` is a required field; encode a real Vector so the JSON is
        // a faithful pre-dynamic insert with NO `dynamic`/`attributes` keys.
        let pt = String(data: try JSONEncoder().encode(Vector(1, 2)), encoding: .utf8)!
        let json = """
        {"blockName":"OLD","insertionPoint":\(pt)}
        """.data(using: .utf8)!
        let data = try JSONDecoder().decode(InsertData.self, from: json)
        #expect(data.blockName == "OLD")
        #expect(data.insertionPoint == Vector(1, 2))
        #expect(data.dynamic == nil)
        #expect(data.attributes.isEmpty) // pre-existing back-compat still holds
    }

    @Test("a Block with visibility states round-trips through Codable")
    func blockRoundTrip() throws {
        let original = Block(name: "VALVE", entityIDs: [EntityID(1), EntityID(2), EntityID(3)],
                             dynamic: twoStateDef())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Block.self, from: data)
        #expect(decoded == original)
        #expect(decoded.dynamic?.visibilityStates.count == 2)
        #expect(decoded.dynamic?.visibilityState(named: "A")?.visibleMemberIDs == [EntityID(1), EntityID(2)])
    }

    @Test("an InsertData with an active state round-trips through Codable")
    func insertRoundTrip() throws {
        let original = InsertData(blockName: "VALVE", insertionPoint: Vector(3, 4),
                                  dynamic: InsertDynamicState(activeVisibilityState: "B",
                                                              parameterValues: ["w": 12.5]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InsertData.self, from: data)
        #expect(decoded == original)
        #expect(decoded.dynamic?.activeVisibilityState == "B")
        #expect(decoded.dynamic?.parameterValues["w"] == 12.5)
    }

    @Test("a plain Block with nil dynamic round-trips and stays plain")
    func plainBlockRoundTrip() throws {
        let original = Block(name: "PLAIN", entityIDs: [EntityID(7)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Block.self, from: data)
        #expect(decoded == original)
        #expect(decoded.dynamic == nil)
    }

    // MARK: - Undoable engine mutators

    @Test("addVisibilityState creates a state, undoable in one ⌘Z")
    func addVisibilityStateUndoable() {
        // Seed the block WITHOUT the undo manager (the BlockOps pattern), then
        // attach it for the operation under test.
        let d = CADDrawing()
        d.addBlock(Block(name: "VALVE", entityIDs: [EntityID(1)]))
        let um = testUndoManager()
        d.undoManager = um
        #expect(d.blocks.block(named: "VALVE")?.dynamic == nil)

        var id: UUID?
        grouped(um) { id = d.addVisibilityState(toBlock: "VALVE", named: "Gate") }
        #expect(id != nil)
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 1)
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityState(named: "Gate") != nil)

        um.undo()
        // One ⌘Z reverts the whole add → back to a plain block.
        #expect(d.blocks.block(named: "VALVE")?.dynamic == nil)
    }

    @Test("addVisibilityState is a no-op (no undo) for a duplicate name / unknown block")
    func addVisibilityStateNoOps() {
        // Block already has a "Gate" state. Seeded without the undo manager.
        let d = CADDrawing()
        d.addBlock(Block(name: "VALVE", entityIDs: [EntityID(1)],
                         dynamic: DynamicBlockDef(visibilityStates: [BlockVisibilityState(name: "Gate")])))
        let um = testUndoManager()
        d.undoManager = um
        #expect(!um.canUndo)

        // Duplicate name → nil, no mutation, no undo registered.
        let dup = d.addVisibilityState(toBlock: "VALVE", named: "Gate")
        #expect(dup == nil)
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 1)
        #expect(!um.canUndo)

        // Unknown block → nil, no mutation, no undo registered.
        let unknown = d.addVisibilityState(toBlock: "NOPE", named: "X")
        #expect(unknown == nil)
        #expect(!um.canUndo)
    }

    @Test("setMemberVisibility adds/removes a member, undoable in one ⌘Z; redundant is a no-op")
    func setMemberVisibilityUndoable() {
        // Seed the block + one state WITHOUT the undo manager.
        let d = CADDrawing()
        d.addBlock(Block(name: "VALVE", entityIDs: [EntityID(1), EntityID(2)],
                         dynamic: DynamicBlockDef(visibilityStates: [BlockVisibilityState(name: "A")])))
        let um = testUndoManager()
        d.undoManager = um

        grouped(um) { d.setMemberVisibility(block: "VALVE", state: "A", memberID: EntityID(1), visible: true) }
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityState(named: "A")?.visibleMemberIDs == [EntityID(1)])

        // Redundant add → no-op (no mutation, no new undo step).
        d.setMemberVisibility(block: "VALVE", state: "A", memberID: EntityID(1), visible: true)
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityState(named: "A")?.visibleMemberIDs == [EntityID(1)])

        // One ⌘Z reverts the add → empty visible set.
        um.undo()
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityState(named: "A")?.visibleMemberIDs.isEmpty == true)
        #expect(!um.canUndo)

        // Remove of an absent member → no-op (nothing to undo).
        d.setMemberVisibility(block: "VALVE", state: "A", memberID: EntityID(2), visible: false)
        #expect(!um.canUndo)
    }

    @Test("setBlockDynamic replaces the bundle; nil clears; undoable; same value is a no-op")
    func setBlockDynamicUndoable() {
        // Seed the plain block WITHOUT the undo manager.
        let d = CADDrawing()
        d.addBlock(Block(name: "VALVE", entityIDs: [EntityID(1), EntityID(2), EntityID(3)]))
        let um = testUndoManager()
        d.undoManager = um

        // Hold ONE def value: `twoStateDef()` mints fresh state UUIDs each call, so
        // the no-op check below must compare against the SAME value, not a re-mint.
        let def = twoStateDef()
        grouped(um) { d.setBlockDynamic(name: "VALVE", def) }
        #expect(d.blocks.block(named: "VALVE")?.isDynamic == true)
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 2)

        // Setting the IDENTICAL value → no-op (no mutation, no undo registered).
        d.setBlockDynamic(name: "VALVE", def)
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 2)

        // Clearing back to nil is undoable; one ⌘Z restores the bundle.
        grouped(um) { d.setBlockDynamic(name: "VALVE", nil) }
        #expect(d.blocks.block(named: "VALVE")?.dynamic == nil)
        um.undo()
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 2)
    }

    @Test("removeVisibilityState drops a state, undoable; unknown is a no-op")
    func removeVisibilityStateUndoable() {
        // Seed the dynamic block WITHOUT the undo manager.
        let d = CADDrawing()
        d.addBlock(Block(name: "VALVE", entityIDs: [EntityID(1)], dynamic: twoStateDef()))
        let um = testUndoManager()
        d.undoManager = um
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 2)

        grouped(um) { d.removeVisibilityState(block: "VALVE", named: "A") }
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.map(\.name) == ["B"])

        um.undo()
        #expect(d.blocks.block(named: "VALVE")?.dynamic?.visibilityStates.count == 2)
        #expect(!um.canUndo)

        // Removing an unknown state → no-op (nothing to undo).
        d.removeVisibilityState(block: "VALVE", named: "ghost")
        #expect(!um.canUndo)
    }
}
