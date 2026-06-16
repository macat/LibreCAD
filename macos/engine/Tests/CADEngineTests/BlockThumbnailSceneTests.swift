//
//  BlockThumbnailSceneTests.swift
//  CADEngineTests
//
//  Engine-pure tests for `blockThumbnailScene` — the block-subset `ExportScene`
//  builder backing the Blocks-sidebar thumbnail (the app-side NSImage glue mirrors
//  the proven `writePNG` bitmap path, so the engine scene is the real gate).
//
//  Covers:
//   - a known multi-entity block resolves to non-empty polylines/fills + finite,
//     non-empty world bounds;
//   - an unknown block name returns nil; an empty block (no members) returns nil;
//   - a block whose member is itself an `.insert` of another block resolves the
//     NESTED block's geometry (via the drawing's makeResolveContext blockProvider);
//   - it does NOT honor layer visibility (a member on a frozen layer still draws),
//     so a thumbnail shows the full block definition.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared
//  test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("block thumbnail scene (block-subset ExportScene)")
struct BlockThumbnailSceneTests {

    // MARK: - Helpers

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
    }

    private func circle(_ c: Vector, _ r: Double) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .circle(CircleData(center: c, radius: r)))
    }

    /// A drawing seeded with `members` (ids minted) wrapped in a block `name`.
    /// Returns the drawing + the block's member ids.
    @discardableResult
    private func drawingWithBlock(name: String,
                                  members: [EntityRecord]) -> (CADDrawing, [EntityID]) {
        let d = CADDrawing()
        var ids: [EntityID] = []
        for m in members { ids.append(d.add(m)) }
        _ = d.addBlock(Block(name: name, basePoint: Vector(0, 0), entityIDs: ids))
        return (d, ids)
    }

    // MARK: - Known multi-entity block

    @Test("a multi-entity block → non-empty polylines/fills + finite, non-empty bounds")
    func multiEntityBlockResolves() {
        let (d, _) = drawingWithBlock(name: "WIDGET", members: [
            line(Vector(0, 0), Vector(10, 0)),
            line(Vector(10, 0), Vector(10, 10)),
            circle(Vector(5, 5), 3),
        ])

        let scene = try! #require(blockThumbnailScene(d, blockName: "WIDGET"))
        // The two lines + the tessellated circle all resolve to polylines.
        #expect(scene.polylines.count >= 3)
        // Bounds are finite and have real extent (the geometry spans ~[0,10]²).
        #expect(!scene.bounds.isEmpty)
        #expect(scene.bounds.min.x.isFinite && scene.bounds.min.y.isFinite)
        #expect(scene.bounds.max.x.isFinite && scene.bounds.max.y.isFinite)
        #expect(scene.bounds.size.x > 0)
        #expect(scene.bounds.size.y > 0)
        // The circle at (5,5) r=3 pushes the bounds to ~[-… , 10] in x and y.
        #expect(scene.bounds.min.x <= 0.0 + 1e-9)
        #expect(scene.bounds.max.x >= 10.0 - 1e-9)
    }

    @Test("a block containing a filled region contributes a fill")
    func blockWithFillResolves() {
        // A closed solid-filled circle resolves to a fill loop (hatch/solid path).
        let d = CADDrawing()
        let cid = d.add(EntityRecord(
            id: EntityID(0),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 5))))
        _ = d.addBlock(Block(name: "DOT", basePoint: .init(0, 0), entityIDs: [cid]))

        let scene = try! #require(blockThumbnailScene(d, blockName: "DOT"))
        // A plain circle is a stroke (polyline), not a fill — assert polylines here.
        #expect(!scene.polylines.isEmpty)
        #expect(!scene.bounds.isEmpty)
    }

    // MARK: - Nil cases

    @Test("an unknown block name → nil")
    func unknownBlockIsNil() {
        let (d, _) = drawingWithBlock(name: "WIDGET", members: [
            line(Vector(0, 0), Vector(10, 0)),
        ])
        #expect(blockThumbnailScene(d, blockName: "NOPE") == nil)
        #expect(blockThumbnailScene(d, blockName: "") == nil)
    }

    @Test("a block with no members → nil")
    func emptyBlockIsNil() {
        let d = CADDrawing()
        _ = d.addBlock(Block(name: "EMPTY", basePoint: .init(0, 0), entityIDs: []))
        #expect(blockThumbnailScene(d, blockName: "EMPTY") == nil)
    }

    @Test("a block whose members are all dangling refs → nil")
    func danglingMembersIsNil() {
        let d = CADDrawing()
        // Reference an id that was never added to the drawing.
        _ = d.addBlock(Block(name: "GHOST", basePoint: .init(0, 0),
                             entityIDs: [EntityID(99999)]))
        #expect(blockThumbnailScene(d, blockName: "GHOST") == nil)
    }

    // MARK: - Nested insert

    @Test("a block whose member is an insert of another block resolves the nested geometry")
    func nestedInsertResolves() {
        let d = CADDrawing()

        // Inner block: a single line at [0,0]→[4,0].
        let innerLine = d.add(line(Vector(0, 0), Vector(4, 0)))
        _ = d.addBlock(Block(name: "INNER", basePoint: .init(0, 0), entityIDs: [innerLine]))

        // Outer block: its member is an INSERT of INNER, placed at (10, 10).
        let nestedInsert = d.add(EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "INNER",
                                     insertionPoint: Vector(10, 10)))))
        _ = d.addBlock(Block(name: "OUTER", basePoint: .init(0, 0),
                             entityIDs: [nestedInsert]))

        // The OUTER thumbnail must expand the nested INNER block's geometry, so the
        // bounds land around the placement point (10,10)→(14,10), NOT empty.
        let ctx = d.makeResolveContext()
        let scene = try! #require(blockThumbnailScene(d, blockName: "OUTER", context: ctx))
        #expect(!scene.polylines.isEmpty)
        #expect(!scene.bounds.isEmpty)
        // The nested line spans (10,10)→(14,10) after placement.
        #expect(scene.bounds.min.x <= 10.0 + 1e-6)
        #expect(scene.bounds.max.x >= 14.0 - 1e-6)
        #expect(abs(scene.bounds.min.y - 10.0) <= 1e-6)
    }

    // MARK: - Layer visibility is NOT honored (shows full definition)

    @Test("a member on a frozen/hidden layer still draws in the thumbnail")
    func frozenLayerMemberStillDraws() {
        let d = CADDrawing()
        // Create a FROZEN (hidden) layer and put a line on it.
        _ = d.addLayer(Layer(name: "HIDDEN", isFrozen: true))

        var ln = line(Vector(0, 0), Vector(8, 0))
        ln.layer = LayerID("HIDDEN")
        let lid = d.add(ln)
        _ = d.addBlock(Block(name: "ONHIDDEN", basePoint: .init(0, 0), entityIDs: [lid]))

        // ExportSceneBuilder would DROP this (frozen layer) — but the thumbnail shows
        // the block definition, so it must still resolve the member.
        let scene = try! #require(blockThumbnailScene(d, blockName: "ONHIDDEN"))
        #expect(!scene.polylines.isEmpty)
        #expect(!scene.bounds.isEmpty)
    }

    // MARK: - Context reuse

    @Test("a caller-supplied context yields the same scene as the default")
    func sharedContextMatchesDefault() {
        let (d, _) = drawingWithBlock(name: "WIDGET", members: [
            line(Vector(0, 0), Vector(10, 0)),
            circle(Vector(5, 5), 3),
        ])
        let a = try! #require(blockThumbnailScene(d, blockName: "WIDGET"))
        let ctx = d.makeResolveContext()
        let b = try! #require(blockThumbnailScene(d, blockName: "WIDGET", context: ctx))
        #expect(a.polylines.count == b.polylines.count)
        #expect(a.fills.count == b.fills.count)
        #expect(a.bounds == b.bounds)
    }
}
