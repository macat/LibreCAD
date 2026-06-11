//
//  DocumentTests.swift
//  CADEngineTests
//
//  Document model — Workstream C (layers / blocks / graphic variables / units).
//  Covers the LayerTable ops (add/rename/active/visibility/lock/print/
//  construction/pen), the BlockTable + id-ref storage (add/lookup/entityIDs/
//  rename/remove), DrawingUnit conversion, graphic-variable typed accessors, and
//  value-snapshot undo on layer/block mutations (ADR-002).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Document model — layers / blocks / variables / units")
struct DocumentTests {

    // MARK: - Helpers

    private func makeLine(_ id: UInt64 = 0, on layer: String = "0") -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: LayerID(layer),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
    }

    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    // MARK: - LayerTable basics

    @Test("fresh table holds default layer 0 and it is active")
    func freshTable() {
        let t = LayerTable()
        #expect(t.count == 1)
        #expect(t.contains("0"))
        #expect(t.activeLayerName == "0")
        #expect(t.activeLayer.name == "0")
    }

    @Test("add layer, lookup, ordered iteration, no duplicate names")
    func addLookupIterate() {
        var t = LayerTable()
        #expect(t.add(Layer(name: "walls")) == true)
        #expect(t.add(Layer(name: "dims")) == true)
        let dup = t.add(Layer(name: "walls"))   // duplicate rejected
        #expect(dup == false)
        #expect(t.count == 3)
        #expect(t.layer(named: "walls") != nil)
        #expect(t.layer(LayerID("dims")) != nil)
        // Ordered: creation order, "0" first.
        #expect(t.layers.map(\.name) == ["0", "walls", "dims"])
        #expect(t.index(of: "dims") == 2)
    }

    @Test("active layer get/set; activating an unknown name is a no-op")
    func activeLayer() {
        var t = LayerTable()
        _ = t.add(Layer(name: "walls"))
        t.activate("walls")
        #expect(t.activeLayerName == "walls")
        t.activate("does-not-exist")
        #expect(t.activeLayerName == "walls")   // unchanged
    }

    @Test("rename layer; default 0 cannot be renamed; collisions rejected")
    func renameLayer() {
        var t = LayerTable()
        _ = t.add(Layer(name: "walls"))
        _ = t.add(Layer(name: "dims"))
        t.activate("walls")

        let renamed = t.rename("walls", to: "exterior")
        #expect(renamed)
        #expect(!t.contains("walls"))
        #expect(t.contains("exterior"))
        #expect(t.activeLayerName == "exterior")  // active follows the rename

        let protectedZero = t.rename("0", to: "base")   // "0" protected
        #expect(!protectedZero)
        let collision = t.rename("exterior", to: "dims")  // collision rejected
        #expect(!collision)
    }

    @Test("visibility / frozen are inverse; toggle flips")
    func visibility() {
        var t = LayerTable()
        _ = t.add(Layer(name: "hidden"))
        t.setVisible("hidden", false)
        #expect(t.layer(named: "hidden")!.isFrozen)
        #expect(!t.layer(named: "hidden")!.isVisible)
        t.toggleVisible("hidden")
        #expect(t.layer(named: "hidden")!.isVisible)
    }

    @Test("lock / print / construction flags and pen mutators")
    func flagsAndPen() {
        var t = LayerTable()
        _ = t.add(Layer(name: "x"))
        t.setLocked("x", true)
        t.setPrintable("x", false)
        t.setConstruction("x", true)
        let l = t.layer(named: "x")!
        #expect(l.isLocked && !l.isPrintable && l.isConstruction)

        t.setColor("x", .white)
        t.setLineType("x", .dashed)
        t.setLineWidth("x", .millimeters(0.5))
        let p = t.layer(named: "x")!.resolvedPen
        #expect(p.color == .white && p.lineType == .dashed && p.lineWidth == .millimeters(0.5))
    }

    @Test("remove layer; default 0 protected; active falls back to 0")
    func removeLayer() {
        var t = LayerTable()
        _ = t.add(Layer(name: "tmp"))
        t.activate("tmp")
        t.remove(named: "tmp")
        #expect(!t.contains("tmp"))
        #expect(t.activeLayerName == "0")       // active fell back
        t.remove(named: "0")
        #expect(t.contains("0"))                 // "0" never removed
    }

    @Test("freezeAll / lockAll bulk ops")
    func bulkFlags() {
        var t = LayerTable()
        _ = t.add(Layer(name: "a"))
        _ = t.add(Layer(name: "b"))
        t.freezeAll(true)
        #expect(t.layers.allSatisfy { $0.isFrozen })
        t.lockAll(true)
        #expect(t.layers.allSatisfy { $0.isLocked })
    }

    // MARK: - BlockTable + id-ref storage

    @Test("add block, lookup, entityIDs are id-refs; duplicate names rejected")
    func addBlockLookup() {
        var t = BlockTable()
        let b = Block(name: "bolt", basePoint: Vector(1, 2), entityIDs: [EntityID(10), EntityID(11)])
        let added = t.add(b)
        #expect(added)
        let dup = t.add(Block(name: "bolt"))     // duplicate rejected
        #expect(!dup)
        #expect(t.count == 1)

        let found = t.block(named: "bolt")
        #expect(found != nil)
        #expect(found!.basePoint == Vector(1, 2))
        #expect(found!.entityIDs == [EntityID(10), EntityID(11)])
        #expect(t.entityIDs(of: "bolt") == [EntityID(10), EntityID(11)])
        #expect(t.block(BlockID("bolt")) != nil)
        #expect(t.block(namedCaseInsensitive: "BOLT") != nil)
    }

    @Test("block member-id add/remove and remove-everywhere")
    func blockMemberMutation() {
        var t = BlockTable()
        _ = t.add(Block(name: "g", entityIDs: [EntityID(1)]))
        t.addEntityID(EntityID(2), to: "g")
        t.addEntityID(EntityID(2), to: "g")        // dedup
        #expect(t.entityIDs(of: "g") == [EntityID(1), EntityID(2)])
        t.removeEntityID(EntityID(1), from: "g")
        #expect(t.entityIDs(of: "g") == [EntityID(2)])

        _ = t.add(Block(name: "h", entityIDs: [EntityID(2), EntityID(3)]))
        t.removeEntityIDEverywhere(EntityID(2))
        #expect(t.entityIDs(of: "g") == [])
        #expect(t.entityIDs(of: "h") == [EntityID(3)])
    }

    @Test("active block get/set; nil and unknown clear it")
    func activeBlock() {
        var t = BlockTable()
        _ = t.add(Block(name: "a"))
        t.activate("a")
        #expect(t.activeBlock?.name == "a")
        t.activate("nope")
        #expect(t.activeBlock == nil)            // unknown clears
        t.activate("a")
        t.activate(nil)
        #expect(t.activeBlock == nil)
    }

    @Test("rename block; newName generates unique names")
    func blockRenameNewName() {
        var t = BlockTable()
        _ = t.add(Block(name: "a"))
        _ = t.add(Block(name: "b"))
        let renamed = t.rename("a", to: "c")
        #expect(renamed)
        #expect(t.contains("c") && !t.contains("a"))
        let collision = t.rename("c", to: "b")    // collision rejected
        #expect(!collision)

        #expect(t.newName(suggestion: "b") == "b-1")
        #expect(t.newName(suggestion: "fresh") == "fresh")
    }

    // MARK: - DrawingUnit conversion

    @Test("unit conversion: inch↔mm, m→mm, factor & metric flags")
    func unitConversion() {
        #expect(DrawingUnit.inch.factorToMM == 25.4)
        #expect(DrawingUnit.foot.factorToMM == 304.8)
        // 1 inch == 25.4 mm
        #expect(DrawingUnit.convert(1, from: .inch, to: .millimeter) == 25.4)
        // 1000 mm == 1 m
        #expect(abs(DrawingUnit.convert(1000, from: .millimeter, to: .meter) - 1.0) < 1e-12)
        // 1 foot == 12 inch
        #expect(abs(DrawingUnit.convert(1, from: .foot, to: .inch) - 12.0) < 1e-9)
        // round-trip mm helpers
        #expect(abs(DrawingUnit.meter.fromMM(DrawingUnit.meter.toMM(2.5)) - 2.5) < 1e-12)
        #expect(DrawingUnit.meter.isMetric && !DrawingUnit.inch.isMetric)
        #expect(DrawingUnit.inch.sign == "\"")
        #expect(DrawingUnit(dxf: 1) == .inch && DrawingUnit(dxf: 999) == .none)
    }

    // MARK: - Graphic variables

    @Test("graphic variables: raw typed get/set and DXF header accessors")
    func graphicVariables() {
        var v = GraphicVariables()
        // Raw typed storage.
        v.setInt("$LUPREC", 6)
        v.setString("$DIMSTYLE", "Standard")
        v.setVector("$UCSORG", Vector(3, 4))
        #expect(v.int("$LUPREC") == 6)
        #expect(v.string("$DIMSTYLE") == "Standard")
        #expect(v.vector("$UCSORG") == Vector(3, 4))
        #expect(v.has("$DIMSTYLE") && !v.has("$NOPE"))

        // Typed header accessors round-trip through DXF codes.
        v.unit = .meter
        #expect(v.unit == .meter)
        #expect(v.int("$INSUNITS") == DrawingUnit.meter.dxfCode)

        v.linearFormat = .architectural
        #expect(v.linearFormat == .architectural)
        #expect(v.int("$LUNITS") == 4)

        v.angleFormat = .radians
        #expect(v.angleFormat == .radians)

        v.anglesCounterClockwise = false
        #expect(!v.anglesCounterClockwise)
        #expect(v.int("$ANGDIR") == 1)

        v.gridOn = false
        #expect(!v.gridOn)
    }

    @Test("graphic-variable defaults match LibreCAD (mm / decimal / prec 4)")
    func graphicVariableDefaults() {
        let v = GraphicVariables()
        #expect(v.unit == .millimeter)
        #expect(v.linearFormat == .decimal)
        #expect(v.linearPrecision == 4)
        #expect(v.angleFormat == .degreesDecimal)
        #expect(v.anglePrecision == 4)
        #expect(v.anglesCounterClockwise)
        #expect(v.gridOn)
    }

    // MARK: - CADDrawing integration

    @Test("drawing exposes drawingUnit via graphic variables")
    func drawingUnitConvenience() {
        let d = CADDrawing()
        #expect(d.drawingUnit == .millimeter)
        d.drawingUnit = .inch
        #expect(d.drawingUnit == .inch)
        #expect(d.graphicVariables.unit == .inch)
    }

    @Test("drawing layer add/active/visibility through the table")
    func drawingLayerOps() {
        let d = CADDrawing()
        #expect(d.addLayer(Layer(name: "walls")))
        d.setActiveLayer("walls")
        #expect(d.layers.activeLayerName == "walls")
        d.setLayerVisible("walls", false)
        #expect(d.layers.layer(named: "walls")!.isFrozen)
        d.setLayerLocked("walls", true)
        #expect(d.layers.layer(named: "walls")!.isLocked)
    }

    @Test("drawing block add/lookup/remove through the table")
    func drawingBlockOps() {
        let d = CADDrawing()
        let e0 = d.add(makeLine())
        let e1 = d.add(makeLine())
        #expect(d.addBlock(Block(name: "grp", entityIDs: [e0, e1])))
        #expect(d.blocks.block(named: "grp")!.entityIDs == [e0, e1])
        // Remove the definition only — member entities stay in the drawing.
        d.removeBlock("grp")
        #expect(d.blocks.block(named: "grp") == nil)
        #expect(d.count == 2)
    }

    // MARK: - Undo on layer / block ops (ADR-002)

    @Test("layer add then undo removes it, redo restores (real UndoManager)")
    func layerAddUndoRedo() {
        let um = testUndoManager()
        let d = CADDrawing()
        d.undoManager = um

        um.beginUndoGrouping()
        _ = d.addLayer(Layer(name: "walls"))
        um.endUndoGrouping()
        #expect(d.layers.contains("walls"))

        #expect(um.canUndo)
        um.undo()
        #expect(!d.layers.contains("walls"))      // layer add undone

        #expect(um.canRedo)
        um.redo()
        #expect(d.layers.contains("walls"))       // redo restores
    }

    @Test("layer visibility change is undoable")
    func layerVisibilityUndo() {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "x"))         // setup (no undo manager yet)

        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        d.setLayerVisible("x", false)
        um.endUndoGrouping()
        #expect(d.layers.layer(named: "x")!.isFrozen)

        um.undo()
        #expect(!d.layers.layer(named: "x")!.isFrozen)  // visibility restored
    }

    @Test("rename layer re-points entities and is undoable")
    func renameLayerRepointsEntities() {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "old"))
        let e = d.add(makeLine(0, on: "old"))

        let um = testUndoManager()
        d.undoManager = um
        um.beginUndoGrouping()
        #expect(d.renameLayer("old", to: "new"))
        um.endUndoGrouping()
        #expect(d.layers.contains("new") && !d.layers.contains("old"))
        #expect(d.entity(e)!.layer.name == "new")  // entity followed the rename

        um.undo()
        #expect(d.layers.contains("old") && !d.layers.contains("new"))
        #expect(d.entity(e)!.layer.name == "old")  // entity ref restored too
    }

    @Test("block add is undoable")
    func blockAddUndo() {
        let um = testUndoManager()
        let d = CADDrawing()
        d.undoManager = um
        um.beginUndoGrouping()
        _ = d.addBlock(Block(name: "b"))
        um.endUndoGrouping()
        #expect(d.blocks.contains("b"))
        um.undo()
        #expect(!d.blocks.contains("b"))
        um.redo()
        #expect(d.blocks.contains("b"))
    }

    // MARK: - load() integration

    @Test("load installs layers/blocks/variables and clears undo")
    func loadIntegration() {
        let d = CADDrawing()
        var lt = LayerTable()
        _ = lt.add(Layer(name: "loaded"))
        var bt = BlockTable()
        _ = bt.add(Block(name: "lb", entityIDs: [EntityID(10)]))
        var gv = GraphicVariables()
        gv.unit = .inch

        d.load(entities: [makeLine(10)], layers: lt, blocks: bt, graphicVariables: gv)
        #expect(d.count == 1)
        #expect(d.layers.contains("loaded"))
        #expect(d.blocks.contains("lb"))
        #expect(d.drawingUnit == .inch)
        #expect(d.mintID().rawValue == 11)   // counter advanced past loaded id 10
    }

    @Test("resolve context uses real layer pens for .byLayer entities")
    func resolveUsesLayerPen() {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "red", color: .white, lineType: .dashed))
        let e = d.add(makeLine(0, on: "red"))   // pen defaults to .byLayer
        let geo = d.resolveAll()
        // The single line resolves to one polyline whose pen came from layer "red".
        let pen = geo[ d.entities.firstIndex { $0.id == e }! ].polylines.first!.pen
        #expect(pen.color == .white)
        #expect(pen.lineType == .dashed)
    }
}
