//
//  SelectionPolicyTests.swift
//  CADEngineTests
//
//  Engine-level CONTRACT tests for the app's selection primitives -- Edit > Select
//  All / Deselect All / Invert Selection. The app's CanvasModel.selectAll() /
//  deselectAll() / invertSelection() live in the (un-importable) executable target
//  and are thin wrappers over the pure SelectionPolicy helpers tested here:
//
//    selectAll       -> Selection(ids: SelectionPolicy.selectableIDs(in:))
//    deselectAll     -> Selection() (clear) -- trivial, asserted via the empty set
//    invertSelection -> Selection(ids: SelectionPolicy.invertedIDs(current:in:))
//
//  Asserts: Select All picks every UNLOCKED + VISIBLE entity and SKIPS entities on
//  locked / frozen layers and hidden entities; Invert is the exact complement WITHIN
//  the selectable set; Deselect empties the selection.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("CADEngine selection-policy contract")
struct SelectionPolicyTests {

    // MARK: - Helpers

    private func makeLine(
        _ id: UInt64,
        layer: String = "0",
        flags: EntityFlags = .default
    ) -> EntityRecord {
        EntityRecord(
            id: EntityID(id),
            layer: LayerID(layer),
            flags: flags,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(Double(id), Double(id))))
        )
    }

    /// A drawing with three layers -- "0" (unlocked), "locked" (locked), "frozen"
    /// (frozen/invisible) -- and entities spread across them, plus one hidden entity
    /// on the unlocked layer. Returns the drawing and the ids of the SELECTABLE ones.
    private func makeScene() -> (CADDrawing, selectable: Set<EntityID>, all: [EntityID]) {
        let d = CADDrawing()
        d.mutateLayers { table in
            _ = table.add(Layer(name: "locked", isLocked: true))
            _ = table.add(Layer(name: "frozen", isFrozen: true))
        }
        // Selectable: visible, unlocked layer.
        let a = d.add(makeLine(1, layer: "0"))
        let b = d.add(makeLine(2, layer: "0"))
        // NOT selectable: locked layer.
        let c = d.add(makeLine(3, layer: "locked"))
        // NOT selectable: frozen layer.
        let e = d.add(makeLine(4, layer: "frozen"))
        // NOT selectable: hidden entity (cleared .visible) even on the unlocked layer.
        let f = d.add(makeLine(5, layer: "0", flags: []))
        let all: [EntityID] = [a, b, c, e, f]
        return (d, selectable: [a, b], all: all)
    }

    // MARK: - Select All

    @Test("selectAll selects every unlocked visible entity and skips locked frozen hidden")
    func selectAllSkipsLockedAndHidden() {
        let (d, selectable, _) = makeScene()
        let ids = Set(SelectionPolicy.selectableIDs(in: d))
        #expect(ids == selectable)
        #expect(ids.count == 2)
    }

    @Test("selectAll on an all-unlocked drawing selects everything")
    func selectAllUnlocked() {
        let d = CADDrawing()
        let a = d.add(makeLine(1))
        let b = d.add(makeLine(2))
        let c = d.add(makeLine(3))
        let ids = Set(SelectionPolicy.selectableIDs(in: d))
        #expect(ids == [a, b, c])
    }

    @Test("selectAll on an empty drawing is empty")
    func selectAllEmpty() {
        let d = CADDrawing()
        #expect(SelectionPolicy.selectableIDs(in: d).isEmpty)
    }

    // MARK: - Invert

    @Test("invertSelection is the complement within the selectable set")
    func invertIsComplement() {
        let (d, selectable, _) = makeScene()
        // Start with only one of the two selectable ids selected.
        let a = selectable.sorted { $0.rawValue < $1.rawValue }.first!
        let inverted = Set(SelectionPolicy.invertedIDs(current: [a], in: d))
        // The inverse is the other selectable id only -- never the locked/hidden ones.
        #expect(inverted == selectable.subtracting([a]))
        #expect(inverted.count == 1)
    }

    @Test("invert of nothing selects the whole selectable set, invert of all selects nothing")
    func invertEdges() {
        let (d, selectable, _) = makeScene()
        let fromEmpty = Set(SelectionPolicy.invertedIDs(current: [], in: d))
        #expect(fromEmpty == selectable)
        let fromAll = Set(SelectionPolicy.invertedIDs(current: selectable, in: d))
        #expect(fromAll.isEmpty)
    }

    @Test("invert never selects a locked or hidden entity (outside the universe)")
    func invertExcludesLocked() {
        let (d, selectable, all) = makeScene()
        let lockedAndHidden = Set(all).subtracting(selectable)
        // From a selection that (somehow) includes a locked id, invert drops it and
        // selects the unselected SELECTABLE remainder only.
        let weird: Set<EntityID> = selectable.subtracting([selectable.first!]).union(lockedAndHidden)
        let inverted = Set(SelectionPolicy.invertedIDs(current: weird, in: d))
        #expect(inverted.isDisjoint(with: lockedAndHidden))
        #expect(inverted == [selectable.first!])
    }

    // MARK: - isSelectable predicate

    @Test("isSelectable: visible unlocked true, locked frozen hidden false, dangling layer true")
    func isSelectablePredicate() {
        let d = CADDrawing()
        d.mutateLayers { table in
            _ = table.add(Layer(name: "locked", isLocked: true))
            _ = table.add(Layer(name: "frozen", isFrozen: true))
        }
        let layers = d.layers
        #expect(SelectionPolicy.isSelectable(makeLine(1, layer: "0"), layers: layers))
        #expect(!SelectionPolicy.isSelectable(makeLine(2, layer: "locked"), layers: layers))
        #expect(!SelectionPolicy.isSelectable(makeLine(3, layer: "frozen"), layers: layers))
        #expect(!SelectionPolicy.isSelectable(makeLine(4, layer: "0", flags: []), layers: layers))
        // A dangling layer id (no record) falls back to selectable (resolve default).
        #expect(SelectionPolicy.isSelectable(makeLine(5, layer: "no-such-layer"), layers: layers))
    }
}
