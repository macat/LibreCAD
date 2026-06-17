//
//  AppMenuWiringTests.swift
//  CADEngineTests
//
//  Feature-gap Wave 3D — app-menu wiring (LibreCADApp.swift). The Edit-clipboard,
//  Layers, Dimension-Style-Manager, and Import/Merge menu items are wired in
//  `LibreCADApp.swift` as SwiftUI menu commands + `@objc` responder-chain handlers on
//  `FlippedMTKView`. The menu/AppKit surface itself (an `App`/`NSView`) is not
//  unit-testable headlessly, but every item is a thin forward to a `CanvasModel` verb —
//  so this suite PINS THE CONTRACT those handlers depend on:
//
//    • the consumed clipboard verbs (`cutSelection` / `copySelection` / `paste` /
//      `pasteAsBlock`) behave as the Edit menu assumes — selection/clipboard-gated,
//      undoable, and SAFE NO-OPS when there is nothing to do (the menu items stay
//      ENABLED while a canvas is focused via the canvas validator's `default: true`,
//      so the verbs MUST not corrupt state on an empty selection / clipboard);
//    • the consumed layer verbs (`isolateSelectionLayers` / `unisolateLayers` /
//      `makeLayerCurrent` / `turnOffOtherLayers`) behave as the Layers menu assumes;
//    • the IMPORT/MERGE semantics the `importMergeDXFAction` handler re-implements
//      inline (re-mint id → undoable `CADDrawing.add` → select → version bump, the
//      exact body of the private `CanvasModel.paste(records:)` it could not call) merge
//      records as ONE undoable group and select them.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink, so the suite is `@MainActor`.
//
//  Uniquely namespaced (`@Suite("app-menu wiring …")`) so it never collides.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("app-menu wiring (Wave 3D: clipboard / layers / import-merge)")
struct AppMenuWiringTests {

    // MARK: - Helpers

    private func line(_ a: Vector, _ b: Vector, layer: String = "0") -> EntityRecord {
        EntityRecord(id: EntityID(0), layer: LayerID(layer),
                     kind: .line(LineData(start: a, end: b)))
    }

    /// A model holding two loose lines (on layers "0" and "WALLS"), with the first
    /// selected. The undo manager is the testing (manual-grouping) one with a clean
    /// stack, mirroring the other UI-wiring suites.
    private func twoLineModel() -> (model: CanvasModel, a: EntityID, b: EntityID) {
        let drawing = CADDrawing()
        _ = drawing.addLayer(Layer(name: "WALLS"))
        let a = drawing.add(line(Vector(0, 0), Vector(10, 0), layer: "0"))
        let b = drawing.add(line(Vector(10, 0), Vector(10, 10), layer: "WALLS"))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        model.selection = Selection(ids: [a])
        return (model, a, b)
    }

    /// The exact body of the private `CanvasModel.paste(records:)` the
    /// `importMergeDXFAction` handler re-implements inline (it cannot call the private
    /// method). Kept BYTE-FOR-BYTE equivalent to that handler so this test exercises the
    /// real merge semantics through the same accessible model surface.
    private func mergeLikeHandler(_ records: [EntityRecord], into model: CanvasModel) {
        let explicitGroup = !model.undoManager.groupsByEvent
        if explicitGroup { model.undoManager.beginUndoGrouping() }
        defer { if explicitGroup { model.undoManager.endUndoGrouping() } }
        var newIDs: Set<EntityID> = []
        for record in records {
            var added = record
            added.id = EntityID(0)
            added.flags.remove(.selected)
            let id = model.drawing.add(added)
            let box = model.drawing.entity(id)?.boundingBox() ?? added.boundingBox()
            if !box.isEmpty { model.quadtree.insert(id, bounds: box) }
            newIDs.insert(id)
        }
        model.selection = Selection(ids: newIDs)
        model.modelDirty = true
        model.modelVersion &+= 1
    }

    // MARK: - Edit ▸ Cut / Copy / Paste / Paste as Block

    @Test("Copy then Paste adds a copy and selects it; the original survives")
    func copyPaste() {
        let (m, a, _) = twoLineModel()
        let before = m.drawing.entities.count
        #expect(m.copySelection() == true)
        #expect(m.hasClipboard == true)
        #expect(m.drawing.entities.count == before)   // copy never mutates the drawing
        #expect(m.paste() == true)
        #expect(m.drawing.entities.count == before + 1)
        #expect(m.drawing.entity(a) != nil)           // original survives a copy/paste
        #expect(m.selection.ids.count == 1)           // the paste becomes the selection
        #expect(m.selection.ids.contains(a) == false) // …the new copy, not the original
    }

    @Test("Cut removes the selection but stocks the clipboard for a later Paste (undoable)")
    func cutThenPaste() {
        let (m, a, _) = twoLineModel()
        let before = m.drawing.entities.count
        #expect(m.cutSelection() == true)
        #expect(m.drawing.entity(a) == nil)           // the cut entity is gone
        #expect(m.drawing.entities.count == before - 1)
        #expect(m.hasClipboard == true)               // …but available to paste back
        m.undo()                                      // one undo step restores the cut
        #expect(m.drawing.entity(a) != nil)
        #expect(m.paste() == true)                    // and the clipboard still pastes
        #expect(m.drawing.entities.count == before + 1)
    }

    @Test("Paste as Block wraps the clipboard into a new block + insert (one undo step)")
    func pasteAsBlock() {
        let (m, _, _) = twoLineModel()
        m.selection = Selection(ids: Set(m.drawing.entities.map(\.id)))   // both lines
        #expect(m.copySelection() == true)
        let blocksBefore = m.drawing.blocks.blocks.count
        #expect(m.pasteAsBlock(name: "Merged") == true)
        #expect(m.drawing.blocks.contains("Merged"))
        #expect(m.drawing.blocks.blocks.count == blocksBefore + 1)
        // The placed insert is the new selection.
        let selectedKinds = m.selection.ids.compactMap { m.drawing.entity($0)?.kind }
        #expect(selectedKinds.contains { if case .insert = $0 { return true }; return false })
        m.undo()                                       // a single ⌘Z reverts the whole op
        #expect(m.drawing.blocks.contains("Merged") == false)
    }

    @Test("clipboard verbs are SAFE NO-OPS with no selection / empty clipboard")
    func clipboardNoOps() {
        let drawing = CADDrawing()
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        #expect(m.hasSelection == false)
        #expect(m.hasClipboard == false)
        // The menu items stay ENABLED while the canvas is focused (validator default),
        // so the verbs MUST be no-ops here — never a crash, never a stray mutation.
        #expect(m.copySelection() == false)
        #expect(m.cutSelection() == false)
        #expect(m.paste() == false)
        #expect(m.pasteAsBlock() == false)
        #expect(m.drawing.entities.isEmpty)
    }

    // MARK: - Layers ▸ Isolate / Unisolate / Make Current / Turn Off Others

    @Test("Isolate selection's layers freezes the others; Unisolate restores them")
    func isolateUnisolate() {
        let (m, _, _) = twoLineModel()       // selection is the line on layer "0"
        #expect(m.isolateSelectionLayers() == true)
        // "WALLS" (not the selection's layer) is now frozen; "0" stays visible.
        #expect(m.drawing.layers.layer(named: "WALLS")?.isFrozen == true)
        #expect(m.drawing.layers.layer(named: "0")?.isFrozen == false)
        #expect(m.unisolateLayers() == true)
        #expect(m.drawing.layers.layer(named: "WALLS")?.isFrozen == false)   // restored
        #expect(m.unisolateLayers() == false)   // nothing left to restore
    }

    @Test("Make Selected Layer Current sets the active layer to the selection's layer")
    func makeLayerCurrent() {
        let (m, _, b) = twoLineModel()
        m.selection = Selection(ids: [b])       // the line on "WALLS"
        // Mirror the handler: derive the selection's layer, then make it current.
        let layer = m.selection.ids.compactMap { m.drawing.entity($0)?.layer.name }.first
        #expect(layer == "WALLS")
        #expect(m.makeLayerCurrent(layer!) == true)
        #expect(m.drawing.layers.activeLayerName == "WALLS")
        #expect(m.makeLayerCurrent("WALLS") == false)   // already current ⇒ no-op
    }

    @Test("Turn Off Other Layers freezes every layer except the selection's")
    func turnOffOthers() {
        let (m, a, _) = twoLineModel()           // selection is on "0"
        m.selection = Selection(ids: [a])
        let keep = Set(m.selection.ids.compactMap { m.drawing.entity($0)?.layer.name })
        #expect(keep == ["0"])
        #expect(m.turnOffOtherLayers(keep: keep) == true)
        #expect(m.drawing.layers.layer(named: "WALLS")?.isFrozen == true)
        #expect(m.drawing.layers.layer(named: "0")?.isFrozen == false)
    }

    // MARK: - File ▸ Import / Merge DXF (the handler's inline merge semantics)

    @Test("Import/Merge adds the read records as one undoable group and selects them")
    func importMerge() {
        let (m, a, b) = twoLineModel()
        let before = m.drawing.entities.count
        // Stand-in for `CADEngine.shared.readEntities(...).records`: two fresh records
        // (with stale ids — the handler re-mints them) on a brand-new layer.
        let imported = [
            line(Vector(100, 100), Vector(110, 100)),
            line(Vector(110, 100), Vector(110, 110)),
        ]
        mergeLikeHandler(imported, into: m)
        #expect(m.drawing.entities.count == before + 2)   // existing geometry preserved
        #expect(m.drawing.entity(a) != nil)
        #expect(m.drawing.entity(b) != nil)
        #expect(m.selection.ids.count == 2)               // the merged records are selected
        #expect(m.selection.ids.isDisjoint(with: [a, b])) // …re-minted ids, not the originals
        #expect(m.modelDirty == true)
        m.undo()                                          // a single ⌘Z reverts the merge
        #expect(m.drawing.entities.count == before)
    }
}
