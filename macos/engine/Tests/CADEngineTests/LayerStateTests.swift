//
//  LayerStateTests.swift
//  CADEngineTests
//
//  WAVE 3 — F17 layer states/filters (UI-shell agent's engine-testable half):
//   - `LayerState` snapshot captures every layer's flags by name.
//   - `LayerState.apply` restores captured flags onto a live table, leaving newer
//     layers untouched and skipping captured-but-deleted layers (AutoCAD LAYERSTATE
//     "restore, don't recreate").
//   - `CADDrawing.saveLayerState` / `restoreLayerState` / `removeLayerState` /
//     `renameLayerState` are undoable through the value-snapshot funnel.
//   - `freezeAllLayers` / `lockAllLayers` bulk flag ops are undoable.
//
//  Uniquely namespaced (`@Suite("layer states (F17)")`) so it does not collide with
//  the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("layer states (F17)")
struct LayerStateTests {

    /// A test UndoManager with manual grouping (so each undo reverts one op).
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A drawing with layers "0", "A", "B" (all default flags), undo-enabled. The
    /// undoManager is attached AFTER seeding so the setup mutations don't register
    /// undo (with `groupsByEvent == false`, registering outside a group is invalid;
    /// the tests below open explicit groups for the ops they intend to undo).
    ///
    /// Returns the manager too: `CADDrawing.undoManager` is a `weak var`, so the
    /// caller MUST retain it for the lifetime of the test, else it deallocates and
    /// undo silently no-ops.
    private func seeded() -> (CADDrawing, UndoManager) {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "A"))
        _ = d.addLayer(Layer(name: "B"))
        let um = testUndoManager()
        d.undoManager = um
        return (d, um)
    }

    /// A drawing with layers "0", "A", "B" but NO UndoManager — for tests that only
    /// check behavior (not undo), so mutations register no undo and the undo stack
    /// stays well-formed (registering outside a group with `groupsByEvent == false`
    /// is invalid).
    private func seededNoUndo() -> CADDrawing {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "A"))
        _ = d.addLayer(Layer(name: "B"))
        return d
    }

    /// Runs `body` inside one explicit undo group (the test UndoManager has
    /// `groupsByEvent == false`, so a discrete `undo()` needs an explicit group —
    /// matching how `CanvasModel` opens an explicit group when not grouping-by-event).
    private func grouped(_ d: CADDrawing, _ body: () -> Void) {
        d.undoManager?.beginUndoGrouping()
        body()
        d.undoManager?.endUndoGrouping()
    }

    // MARK: - LayerState snapshot/restore (pure value type)

    @Test("a snapshot captures every layer's flags by name")
    func snapshotCapturesFlags() {
        var table = LayerTable()
        _ = table.add(Layer(name: "A", isFrozen: true, isLocked: false))
        _ = table.add(Layer(name: "B", isLocked: true, isPrintable: false))

        let state = LayerState(name: "S1", capturing: table)
        #expect(state.flags.count == 3)            // 0, A, B
        #expect(state.flags["A"]?.isFrozen == true)
        #expect(state.flags["B"]?.isLocked == true)
        #expect(state.flags["B"]?.isPrintable == false)
        #expect(state.flags["0"]?.isFrozen == false)
    }

    @Test("apply restores captured flags onto a live table")
    func applyRestoresFlags() {
        var table = LayerTable()
        _ = table.add(Layer(name: "A"))
        let snapshot = LayerState(name: "S", capturing: table)   // A is visible/unlocked

        // Mutate A after the snapshot...
        table.setFrozen("A", true)
        table.setLocked("A", true)
        #expect(table.layer(named: "A")?.isFrozen == true)

        // ...then restore should bring it back to the captured (thawed/unlocked) state.
        snapshot.apply(to: &table)
        #expect(table.layer(named: "A")?.isFrozen == false)
        #expect(table.layer(named: "A")?.isLocked == false)
    }

    @Test("restore leaves newer layers untouched and skips deleted ones")
    func applyIgnoresNewAndDeleted() {
        var table = LayerTable()
        _ = table.add(Layer(name: "A"))
        let snapshot = LayerState(name: "S", capturing: table)  // captures 0, A

        // Add C (not in the snapshot) and freeze it; delete A.
        _ = table.add(Layer(name: "C", isFrozen: true))
        table.remove(named: "A")

        snapshot.apply(to: &table)
        // C was not in the snapshot → untouched (still frozen).
        #expect(table.layer(named: "C")?.isFrozen == true)
        // A was deleted → restore does not recreate it.
        #expect(table.layer(named: "A") == nil)
    }

    // MARK: - CADDrawing save/restore (undoable)

    @Test("saveLayerState then a flag change then restoreLayerState round-trips")
    func saveRestoreRoundTrip() {
        let d = seededNoUndo()
        d.setLayerVisible("A", true)
        let saved = d.saveLayerState(named: "All Visible")
        #expect(saved == "All Visible")
        #expect(d.layerStates.contains("All Visible"))

        // Freeze A, then restore the saved state → A visible again.
        d.setLayerVisible("A", false)
        #expect(d.layers.layer(named: "A")?.isVisible == false)
        #expect(d.restoreLayerState(named: "All Visible") == true)
        #expect(d.layers.layer(named: "A")?.isVisible == true)
    }

    @Test("restoreLayerState is one undoable step")
    func restoreIsUndoable() {
        let (d, um) = seeded()
        grouped(d) { _ = d.saveLayerState(named: "S") }   // captures A visible
        grouped(d) { d.setLayerVisible("A", false) }      // now frozen
        grouped(d) { _ = d.restoreLayerState(named: "S") } // back to visible
        #expect(d.layers.layer(named: "A")?.isVisible == true)
        um.undo()                               // undo the restore
        #expect(d.layers.layer(named: "A")?.isVisible == false)
    }

    @Test("restoreLayerState on an unknown state is a no-op")
    func restoreUnknownNoop() {
        let d = seededNoUndo()
        #expect(d.restoreLayerState(named: "nope") == false)
    }

    @Test("removeLayerState and renameLayerState work and are undoable")
    func removeAndRename() {
        let (d, um) = seeded()
        grouped(d) { _ = d.saveLayerState(named: "S") }
        grouped(d) { #expect(d.renameLayerState("S", to: "T") == true) }
        #expect(d.layerStates.contains("T"))
        #expect(!d.layerStates.contains("S"))

        grouped(d) { d.removeLayerState(named: "T") }
        #expect(!d.layerStates.contains("T"))
        um.undo()                               // undo the removal
        #expect(d.layerStates.contains("T"))
    }

    @Test("saving with a blank name auto-generates a fresh State-N name")
    func blankNameAutoGenerates() {
        let d = seededNoUndo()
        let a = d.saveLayerState(named: "")
        let b = d.saveLayerState(named: "")
        #expect(a != b)
        #expect(d.layerStates.count == 2)
    }

    // MARK: - Bulk flag ops (undoable)

    @Test("freezeAllLayers freezes every layer and is undoable")
    func freezeAllUndoable() {
        let (d, um) = seeded()
        grouped(d) { d.freezeAllLayers(true) }
        #expect(d.layers.layers.allSatisfy { $0.isFrozen })
        um.undo()
        #expect(d.layers.layers.allSatisfy { !$0.isFrozen })
    }

    @Test("lockAllLayers locks every layer and is undoable")
    func lockAllUndoable() {
        let (d, um) = seeded()
        grouped(d) { d.lockAllLayers(true) }
        #expect(d.layers.layers.allSatisfy { $0.isLocked })
        um.undo()
        #expect(d.layers.layers.allSatisfy { !$0.isLocked })
    }
}
