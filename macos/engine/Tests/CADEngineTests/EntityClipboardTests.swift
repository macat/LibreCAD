//
//  EntityClipboardTests.swift
//  CADEngineTests
//
//  Engine-level tests for the in-app entity clipboard (UX-plan U5 — Cut/Copy/Paste/
//  Duplicate) and the marquee additive-selection composition. The app's CanvasModel
//  clipboard verbs (copySelection / cutSelection / paste / duplicateSelection) live
//  in the (un-importable) executable target and are thin wrappers over the pure
//  `EntityClipboard` tested here plus the existing `Selection.windowSelect` +
//  `SelectionPolicy.isSelectable` (already covered elsewhere):
//
//    copySelection  -> EntityClipboard.copy(selectedRecords)
//    paste(at:)     -> drawing.add(each of) clipboard.pasteRecords(at:)  (ids minted)
//    duplicate      -> scratch.copy(sel); add(each of) scratch.pasteRecords()
//    ⇧-marquee add  -> selection.ids ∪ windowSelect(rect, crossing).filter(selectable)
//
//  Asserts: paste RE-MINTS ids (placeholder 0 so `add` mints) and OFFSETS geometry;
//  the default offset and the cursor-anchored offset both land where expected; the
//  clipboard is a value snapshot (mutating the source after copy doesn't change it);
//  and a ⇧-marquee UNIONS the new window hits into the prior selection.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Entity clipboard (copy / paste / duplicate)")
struct EntityClipboardTests {

    /// A horizontal line entity from (0,0)→(10,0), id 1.
    private func lineRecord(id: UInt64 = 1, start: Vector = Vector(0, 0), end: Vector = Vector(10, 0)) -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: LayerID("walls"), pen: .byLayer,
                     kind: .line(LineData(start: start, end: end)))
    }

    @Test("copy stores a value snapshot and clears the selected flag")
    func copySnapshot() {
        var clip = EntityClipboard()
        var rec = lineRecord()
        rec.flags.insert(.selected)            // a stale selected bit
        clip.copy([rec])

        #expect(clip.count == 1)
        #expect(!clip.isEmpty)
        // The stored copy must NOT carry the selected flag.
        #expect(clip.records[0].isSelected == false)
        // Snapshot independence: mutating the source after copy doesn't touch the clip.
        rec.kind = .line(LineData(start: Vector(99, 99), end: Vector(100, 100)))
        if case .line(let d) = clip.records[0].kind {
            #expect(d.start == Vector(0, 0))   // unchanged
        } else { Issue.record("expected a line") }
    }

    @Test("paste re-mints ids (placeholder 0) and offsets the geometry")
    func pasteReMintsAndOffsets() {
        var clip = EntityClipboard()
        clip.copy([lineRecord(id: 7)])         // a real, non-zero source id

        let pasted = clip.pasteRecords()       // default offset (10,10)
        #expect(pasted.count == 1)
        // Re-mint: the id is the placeholder 0 so `CADDrawing.add` mints a fresh one
        // (never the source's id 7 — that would collide on add).
        #expect(pasted[0].id == EntityID(0))
        // Offset: the line moved by the default (10,10).
        guard case .line(let d) = pasted[0].kind else { Issue.record("expected a line"); return }
        #expect(d.start == Vector(10, 10))
        #expect(d.end == Vector(20, 10))
        // Non-geometry attributes are preserved (layer/pen).
        #expect(pasted[0].layer == LayerID("walls"))
    }

    @Test("two pastes both re-mint to placeholder 0 (so add mints distinct ids)")
    func twoPastesBothReMint() {
        var clip = EntityClipboard()
        clip.copy([lineRecord(id: 7)])
        let a = clip.pasteRecords()
        let b = clip.pasteRecords()
        // Both carry the placeholder id; `add` is what makes them distinct at insert.
        #expect(a[0].id == EntityID(0))
        #expect(b[0].id == EntityID(0))
    }

    @Test("paste at a target anchors the bbox lower-left to the cursor")
    func pasteAtTargetAnchorsToCursor() {
        var clip = EntityClipboard()
        // Line from (0,0)→(10,0); its bbox lower-left (anchor) is (0,0).
        clip.copy([lineRecord(id: 3)])
        #expect(clip.anchor == Vector(0, 0))

        // Paste so the anchor lands at (100,50): offset = target - anchor = (100,50).
        let pasted = clip.pasteRecords(at: Vector(100, 50))
        guard case .line(let d) = pasted[0].kind else { Issue.record("expected a line"); return }
        #expect(d.start == Vector(100, 50))
        #expect(d.end == Vector(110, 50))
    }

    @Test("empty clipboard pastes nothing")
    func emptyPastesNothing() {
        let clip = EntityClipboard()
        #expect(clip.isEmpty)
        #expect(clip.pasteRecords().isEmpty)
        #expect(clip.pasteRecords(at: Vector(5, 5)).isEmpty)
        #expect(clip.anchor == nil)
    }

    @MainActor
    @Test("paste through CADDrawing.add mints REAL distinct ids and keeps the offset")
    func pasteThroughDrawingMintsDistinctIDs() {
        // This mirrors what CanvasModel.paste does: route the re-minted records
        // through the undoable `add`, which mints a real id for each placeholder-0.
        let drawing = CADDrawing()
        let srcID = drawing.add(lineRecord(id: 0))   // a real entity (minted)

        var clip = EntityClipboard()
        clip.copy([drawing.entity(srcID)!])

        let recs = clip.pasteRecords()               // placeholder-0 + offset
        var mintedIDs: [EntityID] = []
        for r in recs { mintedIDs.append(drawing.add(r)) }

        // The minted id is distinct from the source (no collision).
        #expect(mintedIDs.count == 1)
        #expect(mintedIDs[0] != srcID)
        // The added entity carries the offset geometry.
        guard case .line(let d) = drawing.entity(mintedIDs[0])!.kind else {
            Issue.record("expected a line"); return
        }
        #expect(d.start == Vector(10, 10))
        // Drawing now has both the original and the paste.
        #expect(drawing.count == 2)
    }
}

// MARK: - Marquee additive selection (⇧-drag unions into the selection)

@Suite("Marquee additive selection (window/crossing + ⇧ union)")
@MainActor
struct MarqueeAdditiveTests {

    /// Builds a drawing + quadtree with three separated lines and returns the ids.
    private func fixture() -> (CADDrawing, Quadtree, EntityID, EntityID, EntityID) {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        func add(_ start: Vector, _ end: Vector) -> EntityID {
            let id = drawing.add(EntityRecord(id: EntityID(0),
                                              kind: .line(LineData(start: start, end: end))))
            quadtree.insert(id, bounds: drawing.entity(id)!.boundingBox())
            return id
        }
        let a = add(Vector(0, 0), Vector(2, 0))      // near origin
        let b = add(Vector(10, 0), Vector(12, 0))    // ~x=10
        let c = add(Vector(20, 0), Vector(22, 0))    // ~x=20
        return (drawing, quadtree, a, b, c)
    }

    @Test("non-additive window selection REPLACES the selection (enclosed only)")
    func windowReplaces() {
        let (drawing, quadtree, a, b, _) = fixture()
        let sel = Selection()
        // A window box around line a only.
        let rect = AABB(points: [Vector(-1, -1), Vector(3, 1)])
        let hits = sel.windowSelect(rect: rect, crossing: false, in: drawing, using: quadtree)
        #expect(Set(hits) == Set([a]))
        #expect(!Set(hits).contains(b))
    }

    @Test("crossing selects a straddling line that window excludes")
    func crossingVsWindow() {
        let (drawing, quadtree, _, b, _) = fixture()
        let sel = Selection()
        // A box that only PARTIALLY overlaps line b (x 10..12): spans x 11..15, so it
        // straddles b's right half — crossing hits it, window does not.
        let rect = AABB(points: [Vector(11, -1), Vector(15, 1)])
        let crossing = sel.windowSelect(rect: rect, crossing: true, in: drawing, using: quadtree)
        let window = sel.windowSelect(rect: rect, crossing: false, in: drawing, using: quadtree)
        #expect(Set(crossing).contains(b))
        #expect(!Set(window).contains(b))
    }

    @Test("⇧-marquee UNIONS new window hits into the prior selection")
    func additiveUnion() {
        let (drawing, quadtree, a, b, c) = fixture()
        // Prior selection: line a (e.g. an earlier click/marquee).
        var selection = Selection(ids: [a])

        // A new window box enclosing line c only.
        let rect = AABB(points: [Vector(19, -1), Vector(23, 1)])
        let hits = selection.windowSelect(rect: rect, crossing: false, in: drawing, using: quadtree)
        #expect(Set(hits) == Set([c]))

        // ADDITIVE (⇧): union the hits into the prior selection (what commitMarquee
        // does when `additive == true`). a stays, c joins; b is untouched.
        let additive = selection.ids.union(hits)
        #expect(additive == Set([a, c]))
        #expect(!additive.contains(b))

        // NON-additive (plain drag): the hits REPLACE the selection (a is dropped).
        let replaced = Set(hits)
        #expect(replaced == Set([c]))

        selection = Selection(ids: additive)
        #expect(selection.count == 2)
    }
}
