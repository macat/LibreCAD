//
//  BlockMemberExclusionTests.swift
//  CADEngineTests
//
//  Regression suite for the "block members are editable/selectable in model space
//  (and render DOUBLED)" bug. After a block is created, its member geometry must be
//  editable ONLY by opening the block in the Block Editor — NOT as loose top-level
//  entities in model space. The fix is one source-of-truth membership predicate
//  (`CADDrawing.blockMemberIDs`) subtracted by the model-space consumers:
//
//    • `SelectionPolicy.selectableIDs` / `.invertedIDs`  (⌘A / Invert)
//    • `CanvasModel.activeSpaceEntities`                 (render / index / marquee / snap)
//
//  This suite asserts:
//    • blockMemberIDs is the union of every block's entityIDs (frozen blocks too).
//    • ⌘A (selectableIDs) and Invert (invertedIDs) contain the INSERT, never the members.
//    • activeSpaceEntities (model space, not editing) excludes members; a quadtree
//      windowSelect over the member bounds returns the INSERT, not the members.
//    • Block-editor positive: enter → activeSpaceEntities IS the members (editable);
//      exit → members excluded again.
//    • Double-render guard: the model-space scoped id set (the set the render pack keys
//      off) excludes member ids (drawn only via the INSERT).
//
//  `CanvasModel` lives in the (un-importable) app target — reached via the existing
//  `_SharedCanvasModel.swift` symlink. The CanvasModel-touching tests are `@MainActor`
//  (mirrors `BlockEditSessionTests`). Uniquely namespaced so it does not collide with
//  the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("block-member exclusion (members non-loose in model space; still editable in Block Editor)")
struct BlockMemberExclusionTests {

    // MARK: - Helpers

    /// A line from `a` to `b` (model space), optional explicit id.
    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    /// An UndoManager for unit testing (manual grouping — event-coalescing never fires
    /// without a run loop). Mirrors `BlockEditSessionTests`.
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A drawing seeded by `makeBlockFromEntities` (the true-to-bug path): two loose
    /// lines are turned into a block "WIDGET" with one INSERT standing in for them.
    /// Returns the drawing, the registered name, the insert id, and the member ids.
    private func seededByCreate(
        a aEnds: (Vector, Vector) = (Vector(0, 0), Vector(10, 0)),
        b bEnds: (Vector, Vector) = (Vector(0, 5), Vector(10, 5))
    ) -> (d: CADDrawing, name: String, insertID: EntityID, memberIDs: [EntityID]) {
        let d = CADDrawing()
        _ = d.add(line(aEnds.0, aEnds.1))
        _ = d.add(line(bEnds.0, bEnds.1))
        let sourceIDs = d.entities.map(\.id)
        let creation = d.makeBlockFromEntities(name: "WIDGET",
                                               basePoint: Vector(0, 0), ids: sourceIDs)!
        let memberIDs = d.blocks.block(named: creation.blockName)!.entityIDs
        return (d, creation.blockName, creation.insertID, memberIDs)
    }

    // MARK: - blockMemberIDs is the single membership truth

    @Test("blockMemberIDs is the union of every block's entityIDs (frozen blocks too)")
    func blockMemberIDsUnion() {
        let d = CADDrawing()
        let m1 = d.add(line(Vector(0, 0), Vector(1, 0)))
        let m2 = d.add(line(Vector(2, 0), Vector(3, 0)))
        let m3 = d.add(line(Vector(4, 0), Vector(5, 0)))
        let loose = d.add(line(Vector(9, 9), Vector(10, 10)))   // not in any block
        d.mutateBlocks {
            _ = $0.add(Block(name: "A", entityIDs: [m1, m2]))
            // A FROZEN block — its members are still owned (not loose) geometry.
            _ = $0.add(Block(name: "B", entityIDs: [m3], isFrozen: true))
        }
        let members = d.blockMemberIDs
        #expect(members == Set([m1, m2, m3]))
        #expect(!members.contains(loose))
    }

    @Test("blockMemberIDs is empty for a drawing with no blocks")
    func blockMemberIDsEmpty() {
        let d = CADDrawing()
        _ = d.add(line(Vector(0, 0), Vector(1, 0)))
        #expect(d.blockMemberIDs.isEmpty)
    }

    // MARK: - ⌘A / Invert (SelectionPolicy) exclude members, keep the INSERT

    @Test("selectableIDs (⌘A) contains the INSERT and NONE of the block members")
    func selectAllExcludesMembers() {
        let (d, name, insertID, memberIDs) = seededByCreate()
        let selectable = Set(SelectionPolicy.selectableIDs(in: d))
        #expect(selectable.contains(insertID))
        for mid in memberIDs {
            #expect(!selectable.contains(mid))
        }
        // Sanity: the block really does own these members.
        #expect(d.blocks.block(named: name)!.entityIDs == memberIDs)
        // The only selectable thing IS the insert (the loose originals were consumed).
        #expect(selectable == [insertID])
    }

    @Test("invertedIDs (Invert) contains the INSERT and NONE of the block members")
    func invertExcludesMembers() {
        let (d, _, insertID, memberIDs) = seededByCreate()
        // From an empty selection, Invert == the whole selectable set.
        let inverted = Set(SelectionPolicy.invertedIDs(current: [], in: d))
        #expect(inverted.contains(insertID))
        for mid in memberIDs {
            #expect(!inverted.contains(mid))
        }
        #expect(inverted == [insertID])
    }

    @Test("a member already (erroneously) in the selection is never re-selected by Invert")
    func invertDropsMember() {
        let (d, _, insertID, memberIDs) = seededByCreate()
        // Even if a stale selection somehow holds a member, Invert excludes it (it is
        // outside the selectable universe) and never adds it back.
        let weird: Set<EntityID> = Set(memberIDs)
        let inverted = Set(SelectionPolicy.invertedIDs(current: weird, in: d))
        #expect(inverted == [insertID])      // the insert, never a member
        #expect(inverted.isDisjoint(with: Set(memberIDs)))
    }

    // MARK: - activeSpaceEntities (model space, not editing) excludes members

    @Test("activeSpaceEntities (model, not editing) excludes members; the INSERT remains")
    func activeSpaceExcludesMembers() {
        let (d, _, insertID, memberIDs) = seededByCreate()
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        #expect(model.activeSpace == .model)
        #expect(model.isEditingBlock == false)

        let scoped = Set(model.activeSpaceEntities.map(\.id))
        #expect(scoped.contains(insertID))
        for mid in memberIDs {
            #expect(!scoped.contains(mid))
        }
        // The scoped set is exactly the insert (no loose members double up).
        #expect(scoped == [insertID])
    }

    @Test("a quadtree windowSelect over the member bounds returns the INSERT, not the members")
    func marqueeReturnsInsertNotMembers() {
        // Members are re-authored to the local frame and the INSERT sits at the base, so
        // member geometry and insert geometry overlap in world space — exactly the
        // double-pick the bug caused. The index (scoped via activeSpaceEntities) must
        // hold only the insert there.
        let (d, _, insertID, memberIDs) = seededByCreate()
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.rebuildIndex()   // build the scoped quadtree (model space, not editing)

        // A generous crossing rect over the shared world geometry ([0,10]x[0,5]).
        let rect = AABB(min: Vector(-1, -1), max: Vector(11, 6))
        let hits = Set(model.selection.windowSelect(
            rect: rect, crossing: true, in: d, using: model.quadtree))
        #expect(hits.contains(insertID))
        for mid in memberIDs {
            #expect(!hits.contains(mid))
        }
    }

    // MARK: - Block-editor POSITIVE: members editable inside a session, excluded after

    @Test("enter Block Editor → activeSpaceEntities IS the members; exit → members excluded again")
    func blockEditorPositiveThenExcludedAgain() {
        let d = CADDrawing()
        let mID = d.add(line(Vector(0, 0), Vector(10, 0)))
        d.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [mID])) }
        let insertID = d.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: Vector(20, 20)))))

        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()

        // Model space (not editing): the member is NOT loose — only the insert is scoped.
        let beforeIDs = Set(model.activeSpaceEntities.map(\.id))
        #expect(beforeIDs.contains(insertID))
        #expect(!beforeIDs.contains(mID))

        // Enter the Block Editor: the member becomes editable (it IS the active subset).
        #expect(model.enterBlockEditing(name: "WIDGET") == true)
        #expect(model.activeSpaceEntities.map(\.id) == [mID])
        // The index is scoped to the member, so it is now hit-testable while editing.
        let memberBox = d.entity(mID)!.boundingBox()
        let editHits = model.quadtree.query(region: memberBox)
        #expect(editHits.contains(mID))

        // Exit (Save & Close): the member is excluded from model space again.
        #expect(model.exitBlockEditing(save: true) == true)
        #expect(model.isEditingBlock == false)
        let afterIDs = Set(model.activeSpaceEntities.map(\.id))
        #expect(afterIDs.contains(insertID))
        #expect(!afterIDs.contains(mID))
    }

    // MARK: - Double-render guard: the scoped (packed) id set excludes member ids

    @Test("the model-space scoped id set (what the render pack keys off) excludes member ids")
    func packedScopedSetExcludesMembers() {
        // The render pack and the quadtree both key off `activeSpaceEntities`; asserting
        // member ids are absent from that set proves members are NOT drawn directly (so
        // no double-render — they paint only via the INSERT / resolveInsert).
        let (d, _, insertID, memberIDs) = seededByCreate()
        let model = CanvasModel(drawing: d, viewSize: CGSize(width: 800, height: 600))
        let packed = Set(model.activeSpaceEntities.map(\.id))
        #expect(Set(memberIDs).isDisjoint(with: packed))
        #expect(packed.contains(insertID))
    }

    @Test("resolveInsert still expands the block (members render via the INSERT)")
    func insertStillResolvesMembers() {
        // Excluding members from LOOSE model space must NOT stop the INSERT from drawing
        // them: a resolved insert of WIDGET still produces the member geometry.
        let (d, _, insertID, _) = seededByCreate(
            a: (Vector(0, 0), Vector(10, 0)), b: (Vector(0, 5), Vector(10, 5)))
        let ctx = d.makeResolveContext()
        let pts = d.entity(insertID)!.resolve(ctx).polylines.flatMap { $0.points }
        // The insert at the origin reproduces the original world geometry.
        let want = [Vector(0, 0), Vector(10, 0), Vector(0, 5), Vector(10, 5)]
        for w in want {
            #expect(pts.contains { ($0 - w).magnitude < 1e-9 })
        }
    }

    // MARK: - blockMemberIDs is undoable-stable (members re-excluded after undo of create)

    @Test("undo of block creation removes membership; the originals are loose again")
    func undoOfCreateRestoresLooseOriginals() {
        let d = CADDrawing()
        let s1 = d.add(line(Vector(0, 0), Vector(10, 0)))
        let s2 = d.add(line(Vector(0, 5), Vector(10, 5)))
        let um = testUndoManager()
        d.undoManager = um

        um.beginUndoGrouping()
        let creation = d.makeBlockFromEntities(name: "WIDGET",
                                               basePoint: Vector(0, 0), ids: [s1, s2])!
        um.endUndoGrouping()
        #expect(!d.blockMemberIDs.isEmpty)
        // After create, the originals are gone and the insert is the only selectable.
        #expect(Set(SelectionPolicy.selectableIDs(in: d)) == [creation.insertID])

        um.undo()
        // After undo, no blocks → no members; the loose originals are selectable again.
        #expect(d.blockMemberIDs.isEmpty)
        let selectable = Set(SelectionPolicy.selectableIDs(in: d))
        #expect(selectable.contains(s1))
        #expect(selectable.contains(s2))
    }
}
