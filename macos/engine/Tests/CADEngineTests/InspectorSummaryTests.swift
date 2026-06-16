//
//  InspectorSummaryTests.swift
//  CADEngineTests
//
//  Contract coverage for Wave 3's two pure Inspector value types (see
//  `InspectorSummaries.swift`, surfaced into the test target via the
//  `_SharedInspectorSummaries.swift` symlink):
//
//   1. `DrawingSummary` — the drawing-level facts the Inspector shows when nothing is
//      selected (units / counts / extents) are computed correctly from a `CADDrawing`,
//      including the empty-drawing (`extents == nil`) and the model-vs-all space split.
//   2. `MatchPropertiesAvailability` — the enable/disable truth table + status word the
//      renamed "Match Properties" section drives.
//
//  SwiftUI view metrics / `.lineLimit` aren't headless-assertable, so (per the project
//  convention, cf. `ColorSwatchPickerTests`) these assert the MODEL/STRING CONTRACTS
//  the view formats — the part a regression would actually break.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Inspector summaries — drawing-level props + Match-Properties availability")
struct InspectorSummaryTests {

    // MARK: helpers

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
    }

    // MARK: - 1. DrawingSummary

    @Test("an empty drawing has nil extents and zero entity count")
    func emptyDrawingSummary() {
        let d = CADDrawing()
        let s = DrawingSummary(drawing: d)

        #expect(s.entityCount == 0)
        #expect(s.modelEntityCount == 0)
        #expect(s.extents == nil)          // empty AABB ⇒ nil, NOT the ±∞ sentinel
        // A fresh drawing always has at least the "0" layer.
        #expect(s.layerCount >= 1)
    }

    @Test("extents union every entity's bounding box")
    func extentsUnionAllEntities() {
        let d = CADDrawing()
        _ = d.add(line(Vector(0, 0), Vector(10, 5)))
        _ = d.add(EntityRecord(id: EntityID(0),
                               kind: .circle(CircleData(center: Vector(20, 20), radius: 3))))

        let s = DrawingSummary(drawing: d)
        #expect(s.entityCount == 2)
        let e = try? #require(s.extents)
        if let e {
            #expect(e.minX == 0)
            #expect(e.minY == 0)
            #expect(e.maxX == 23)          // circle center 20 + radius 3
            #expect(e.maxY == 23)
            #expect(e.width == 23)
            #expect(e.height == 23)
        }
    }

    @Test("the unit sign + long name reflect the drawing unit")
    func unitNameTracksDrawingUnit() {
        let d = CADDrawing()
        d.drawingUnit = .millimeter
        #expect(DrawingSummary(drawing: d).unitSign == "mm")
        #expect(DrawingSummary(drawing: d).unitName == "Millimeters")

        d.drawingUnit = .inch
        #expect(DrawingSummary(drawing: d).unitSign == "\"")
        #expect(DrawingSummary(drawing: d).unitName == "Inches")

        d.drawingUnit = .none
        #expect(DrawingSummary(drawing: d).unitName == "Unitless")
    }

    @Test("displayName is total over every DrawingUnit case")
    func displayNameIsTotal() {
        for unit in DrawingUnit.allCases {
            #expect(!DrawingSummary.displayName(for: unit).isEmpty)
        }
    }

    @Test("layer count tracks the layer table")
    func layerCountTracksTable() {
        let d = CADDrawing()
        let base = DrawingSummary(drawing: d).layerCount
        #expect(d.addLayer(Layer(name: "Walls")))
        #expect(DrawingSummary(drawing: d).layerCount == base + 1)
    }

    @Test("model-space count excludes paper-space entities")
    func modelSpaceCountSplit() {
        let d = CADDrawing()
        _ = d.add(line(Vector(0, 0), Vector(1, 1)))               // model space (default)
        var paper = line(Vector(0, 0), Vector(2, 2))
        paper.space = .paper
        _ = d.add(paper)

        let s = DrawingSummary(drawing: d)
        #expect(s.entityCount == 2)        // all spaces
        #expect(s.modelEntityCount == 1)   // model only
    }

    // MARK: - 2. MatchPropertiesAvailability

    @Test("nothing selected, no brush ⇒ every action unavailable, status Empty")
    func availabilityEmpty() {
        let a = MatchPropertiesAvailability(hasBrush: false, selectionCount: 0)
        #expect(!a.canPickUp)
        #expect(!a.canApply)
        #expect(!a.canReset)
        #expect(a.isAllUnavailable)
        #expect(a.statusWord == "Empty")
    }

    @Test("exactly one selected ⇒ can pick up + reset; apply still needs a brush")
    func availabilityOneSelected() {
        let noBrush = MatchPropertiesAvailability(hasBrush: false, selectionCount: 1)
        #expect(noBrush.canPickUp)
        #expect(noBrush.canReset)
        #expect(!noBrush.canApply)          // no brush yet
        #expect(!noBrush.isAllUnavailable)

        let withBrush = MatchPropertiesAvailability(hasBrush: true, selectionCount: 1)
        #expect(withBrush.canApply)         // brush + a target
        #expect(withBrush.statusWord == "Loaded")
    }

    @Test("multiple selected ⇒ cannot pick up (needs exactly one), can apply/reset")
    func availabilityMultiSelected() {
        let a = MatchPropertiesAvailability(hasBrush: true, selectionCount: 3)
        #expect(!a.canPickUp)               // pick-up requires exactly 1
        #expect(a.canApply)
        #expect(a.canReset)
        #expect(!a.isAllUnavailable)
    }

    // MARK: - 3. CanvasModel parity — the live model drives the same availability

    @Test("availability built from a live CanvasModel matches its paint-brush state")
    func availabilityFromLiveModel() {
        let model = CanvasModel()
        let id = model.drawing.add(line(Vector(0, 0), Vector(5, 0)))

        // No selection, no brush ⇒ all unavailable.
        var a = MatchPropertiesAvailability(hasBrush: model.hasPaintBrush,
                                            selectionCount: model.selection.ids.count)
        #expect(a.isAllUnavailable)

        // Select the one entity ⇒ can pick up.
        model.selection.ids = [id]
        a = MatchPropertiesAvailability(hasBrush: model.hasPaintBrush,
                                        selectionCount: model.selection.ids.count)
        #expect(a.canPickUp)

        // Load the brush ⇒ apply becomes available + status Loaded.
        _ = model.loadPaintBrushFromSelection()
        a = MatchPropertiesAvailability(hasBrush: model.hasPaintBrush,
                                        selectionCount: model.selection.ids.count)
        #expect(a.canApply)
        #expect(a.statusWord == "Loaded")
    }

    // MARK: - 4. Master "Object Snap" toggle — the REAL F3 contract
    //
    // The old test just round-tripped a local `.free` binding (tautological): it
    // proved the bit flipped, NOT that snapping changed — and it couldn't, because
    // `.free` is the always-on fallback the pipeline never gates on. These drive the
    // ACTUAL snap pipeline (`Snapping.snap`, the same call `updateSnap` makes with the
    // model's live `snapModes`): with the master ON a nearby endpoint snaps; after
    // `setObjectSnapEnabled(false)` the SAME cursor yields the FREE/raw point.

    /// Runs the real snapper with the model's live `snapModes` (the contract
    /// `updateSnap`/`snappedWorldPoint` exercise) against the model's own drawing +
    /// quadtree.
    @MainActor
    private func snap(_ model: CanvasModel, at cursor: Vector, tol: Double) -> SnapResult {
        Snapping.snap(worldPoint: cursor,
                      modes: model.snapModes,
                      worldTolerance: tol,
                      gridSpacing: nil,
                      in: model.drawing,
                      using: model.quadtree)
    }

    @Test("master Object-Snap OFF makes Snapping.snap return the raw cursor point")
    func objectSnapMasterReallyGatesSnapping() {
        let model = CanvasModel()
        // A line whose endpoint we want to snap to.
        let endA = Vector(0, 0), endB = Vector(10, 0)
        _ = model.drawing.add(EntityRecord(id: EntityID(0),
                                           kind: .line(LineData(start: endA, end: endB))))
        model.rebuildIndex()

        // Ensure a clean known starting mode set: endpoint snap on, master ON.
        model.snapModes = [.endpoint, .free]
        let cursor = Vector(0.04, 0.04)   // within tolerance of endA
        let tol = 0.5

        // Master ON ⇒ snaps to the endpoint (NOT the raw cursor).
        #expect(model.objectSnapEnabled)
        let on = snap(model, at: cursor, tol: tol)
        #expect(on.kind == .endpoint)
        #expect((on.point - endA).magnitude < 1e-9)

        // Master OFF ⇒ the SAME cursor now yields the FREE/raw point (no object snap).
        model.setObjectSnapEnabled(false)
        #expect(!model.objectSnapEnabled)
        let off = snap(model, at: cursor, tol: tol)
        #expect(off.kind == .free)
        #expect((off.point - cursor).magnitude < 1e-9)
    }

    @Test("toggling Object Snap off→on restores the prior osnap selection (not a wipe)")
    func objectSnapMasterRestoresPriorSelection() {
        let model = CanvasModel()

        // A distinctive selection: endpoint + center + grid (grid is non-object).
        model.snapModes = [.endpoint, .center, .grid, .free]
        #expect(model.objectSnapEnabled)

        // OFF: positive object-snap bits cleared; .grid/.free preserved.
        model.setObjectSnapEnabled(false)
        #expect(!model.objectSnapEnabled)
        #expect(!model.isSnapModeOn(.endpoint))
        #expect(!model.isSnapModeOn(.center))
        #expect(model.isSnapModeOn(.grid))   // separate grid snap untouched
        #expect(model.isSnapModeOn(.free))

        // ON: the EXACT prior object-snap selection comes back (endpoint+center),
        // and the grid snap is still on (it was never touched).
        model.setObjectSnapEnabled(true)
        #expect(model.objectSnapEnabled)
        #expect(model.isSnapModeOn(.endpoint))
        #expect(model.isSnapModeOn(.center))
        #expect(!model.isSnapModeOn(.middle))        // was NOT selected → stays off
        #expect(!model.isSnapModeOn(.intersection))  // was NOT selected → stays off
        #expect(model.isSnapModeOn(.grid))
    }

    @Test("Object Snap on with nothing stashed restores a sensible default set")
    func objectSnapMasterDefaultsWhenNothingStashed() {
        let model = CanvasModel()
        // Start fully OFF (no positive object-snap bits), nothing ever stashed.
        model.snapModes = [.free]
        #expect(!model.objectSnapEnabled)

        model.setObjectSnapEnabled(true)
        #expect(model.objectSnapEnabled)
        // The default set: endpoint + center + middle + intersection.
        #expect(model.isSnapModeOn(.endpoint))
        #expect(model.isSnapModeOn(.center))
        #expect(model.isSnapModeOn(.middle))
        #expect(model.isSnapModeOn(.intersection))
    }
}
