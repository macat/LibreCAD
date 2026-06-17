//
//  Wave3BCanvasModelWiringTests.swift
//  CADEngineTests
//
//  The Wave-3B `CanvasModel` integration FOUNDATION (the methods/state the Wave-3
//  consumers — ToolOptionsBar / grip mount / ContentView / menus / LayersSidebar —
//  call after this merges). Proves the model wiring carries config through and the
//  new wrappers behave; the engine pieces (DivideMode / SplineMode / ScaleMode /
//  HatchTool.Fill / EntityGrips / LayerIsolation / AppSettings) are already merged
//  and unit-tested in their own suites — here we only verify the CanvasModel surface:
//
//   • Stage 1 — tool-config round-trips through `applyToolConfig` (re-mint / re-apply
//     carries the chosen Divide/Spline/Scale/Hatch mode + params onto the live tool).
//   • Stage 2 — `commitMovedGrip` applies an undoable `.replace` of one record; the
//     `LayerIsolation`-backed layer ops mutate + undo.
//   • Stage 3 — new-window snap seed from AppSettings; `pasteAsBlock` wraps the
//     clipboard into a block + INSERT, undoably.
//
//  `CanvasModel` / `AppSettings` live in the (un-importable) app target — reached
//  here via the existing `_SharedCanvasModel.swift` / `_SharedAppSettings.swift`
//  symlinks (the suite is `@MainActor`, mirroring `InsertOptionsAndBlockFreezeWiringTests`).
//  No SwiftUI body / NSMenu / modal is rendered — only the pure model wiring.
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
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
@Suite("Wave-3B CanvasModel wiring — tool config")
struct Wave3BToolConfigTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    // MARK: - Divide

    @Test("applyToolConfig keeps DivideTool in count mode by default")
    func divideDefaultsToCount() throws {
        let m = model()
        m.divideCount = 7
        m.activateTool(.divide)            // mints + applyToolConfig
        let tool = try #require(m.tool as? DivideTool)
        #expect(tool.mode == .count(7))
    }

    @Test("applyToolConfig re-mints DivideTool in MEASURE-by-length mode")
    func divideLengthMode() throws {
        let m = model()
        m.divideModeStyle = 1
        m.divideSpacing = 12.5
        m.activateTool(.divide)
        let tool = try #require(m.tool as? DivideTool)
        #expect(tool.mode == .length(12.5))
    }

    @Test("divideMode clamps a non-positive spacing back to a usable default")
    func divideSpacingClamp() {
        let m = model()
        m.divideModeStyle = 1
        m.divideSpacing = 0
        #expect(m.divideMode == .length(10.0))
    }

    // MARK: - Spline

    @Test("applyToolConfig re-mints SplineTool in the configured mode")
    func splineMode() throws {
        let m = model()
        m.splineMode = .controlPoints
        m.activateTool(.spline)
        let tool = try #require(m.tool as? SplineTool)
        #expect(tool.mode == .controlPoints)

        m.splineMode = .fit
        m.reapplyActiveToolConfig()
        let refit = try #require(m.tool as? SplineTool)
        #expect(refit.mode == .fit)
    }

    // MARK: - Scale

    @Test("applyToolConfig applies the Scale mode + non-uniform factors in place")
    func scaleMode() throws {
        let m = model()
        m.scaleMode = .nonUniform
        m.scaleX = 2
        m.scaleY = 3
        m.activateTool(.scale)
        let tool = try #require(m.tool as? ScaleTool)
        #expect(tool.mode == .nonUniform)
        #expect(tool.nonUniformFactors.sx == 2)
        #expect(tool.nonUniformFactors.sy == 3)
    }

    @Test("Scale tool defaults to the original .factor behavior")
    func scaleDefault() throws {
        let m = model()
        m.activateTool(.scale)
        let tool = try #require(m.tool as? ScaleTool)
        #expect(tool.mode == .factor)
    }

    // MARK: - Hatch

    @Test("applyToolConfig leaves HatchTool solid by default")
    func hatchDefaultSolid() throws {
        let m = model()
        m.activateTool(.hatch)
        let tool = try #require(m.tool as? HatchTool)
        #expect(tool.fill == .solid)
    }

    @Test("applyToolConfig builds a named pattern fill from currentHatchPattern")
    func hatchPattern() throws {
        let m = model()
        m.currentHatchPattern = "ANSI31"
        m.hatchPatternScale = 2
        m.hatchPatternAngle = .pi / 4
        m.activateTool(.hatch)
        let tool = try #require(m.tool as? HatchTool)
        #expect(tool.fill == .pattern(name: "ANSI31", scale: 2, angle: .pi / 4))
    }

    @Test("a SOLID / blank hatch name resolves to a solid fill")
    func hatchSolidName() {
        let m = model()
        m.currentHatchPattern = "SOLID"
        #expect(m.hatchFillValue == .solid)
        m.currentHatchPattern = "  "
        #expect(m.hatchFillValue == .solid)
        m.currentHatchPattern = nil
        #expect(m.hatchFillValue == .solid)
    }
}

// MARK: - Stage 2 — grip-commit hook + layer ops

@MainActor
@Suite("Wave-3B CanvasModel wiring — grips + layers")
struct Wave3BGripsAndLayersTests {

    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0,
                      layer: String = "0") -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: LayerID(layer),
                     kind: .line(LineData(start: a, end: b)))
    }

    /// A model with one line on layer "0", a clean manual-grouping undo stack.
    private func lineModel() -> (model: CanvasModel, id: EntityID) {
        let drawing = CADDrawing()
        let id = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return (m, id)
    }

    // MARK: Grip commit

    @Test("commitMovedGrip applies an undoable .replace of the moved record")
    func gripCommitUndoable() throws {
        let (m, id) = lineModel()
        m.selection = Selection(ids: [id])

        // Compute the moved record exactly as the overlay would: move grip 1 (the line
        // end) via the pure EntityGrips.moveGrip.
        let ctx = m.gripResolveContext()
        let original = try #require(m.drawing.entity(id))
        let moved = try #require(EntityGrips.moveGrip(1, of: original, to: Vector(10, 5), ctx: ctx))

        #expect(m.commitMovedGrip(moved))
        let after = try #require(m.drawing.entity(id))
        guard case .line(let l) = after.kind else { Issue.record("not a line"); return }
        #expect(l.end == Vector(10, 5))
        #expect(l.start == Vector(0, 0))   // the other end stayed put
        #expect(after.layer.name == "0")   // attributes preserved

        m.undo()
        let reverted = try #require(m.drawing.entity(id))
        guard case .line(let l2) = reverted.kind else { Issue.record("not a line"); return }
        #expect(l2.end == Vector(10, 0))   // one ⌘Z restores the original geometry
    }

    @Test("commitMovedGrip is a no-op for an unchanged record / missing id")
    func gripCommitNoOp() throws {
        let (m, id) = lineModel()
        let original = try #require(m.drawing.entity(id))
        #expect(!m.commitMovedGrip(original))                 // identical → no edit
        var ghost = original
        ghost.id = EntityID(999)
        #expect(!m.commitMovedGrip(ghost))                   // unknown id → no edit
        #expect(!m.undoManager.canUndo)                      // never pushed an undo step
    }

    // MARK: Grip-mount accessors

    @Test("gripsEnabled gates on select mode + a grip-editable selection + no gizmo drag")
    func gripsEnabledGate() {
        let (m, id) = lineModel()
        #expect(!m.gripsEnabled)                  // nothing selected
        m.selection = Selection(ids: [id])
        #expect(m.hasGripEditableSelection)
        #expect(m.gripsEnabled)                   // select mode + grip-editable selection
        #expect(m.gripSelectionRecords.count == 1)

        m.setGizmoPreview(.identity)              // gizmo owns the gesture
        #expect(!m.gripsEnabled)
        m.clearGizmoPreview()
        #expect(m.gripsEnabled)

        m.activateTool(.line)                     // a draw tool is active → no grips
        #expect(!m.gripsEnabled)
    }

    // MARK: Layer ops

    /// A model with layers A/B/C (all visible) + the default "0", and entities on A & B.
    private func layeredModel() -> (model: CanvasModel, a: EntityID, b: EntityID) {
        let drawing = CADDrawing()
        for n in ["A", "B", "C"] { _ = drawing.addLayer(Layer(name: n)) }
        let a = drawing.add(line(Vector(0, 0), Vector(1, 0), id: 0, layer: "A"))
        let b = drawing.add(line(Vector(0, 1), Vector(1, 1), id: 0, layer: "B"))
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return (m, a, b)
    }

    private func frozen(_ m: CanvasModel, _ name: String) -> Bool {
        m.drawing.layers.layer(named: name)?.isFrozen ?? false
    }

    @Test("isolateLayer freezes others, thaws the kept layer, and unisolate restores exactly")
    func isolateAndUnisolate() {
        let (m, _, _) = layeredModel()
        // Pre-freeze C so we can prove unisolate returns it to FROZEN (not blanket-shown).
        // The drawing mutation registers undo; the test's manual-grouping manager needs an
        // open group around it (the live app's groupsByEvent does this implicitly).
        m.undoManager.beginUndoGrouping()
        m.drawing.setLayerVisible("C", false)
        m.undoManager.endUndoGrouping()
        m.undoManager.removeAllActions()
        #expect(frozen(m, "C"))

        m.isolateLayer("A")
        #expect(!frozen(m, "A"))                  // kept visible
        #expect(frozen(m, "B"))                   // hidden
        #expect(frozen(m, "C"))                   // already hidden, stays hidden
        #expect(frozen(m, "0"))                   // default layer hidden too
        #expect(m.hasIsolatedLayers)

        #expect(m.unisolateLayers())
        #expect(!frozen(m, "A"))                  // restored visible
        #expect(!frozen(m, "B"))                  // restored visible
        #expect(frozen(m, "C"))                   // restored to its PRIOR frozen state
        #expect(!frozen(m, "0"))
        #expect(!m.hasIsolatedLayers)
    }

    @Test("isolateSelectionLayers isolates the selection's distinct layers")
    func isolateSelectionLayers() {
        let (m, a, _) = layeredModel()
        m.selection = Selection(ids: [a])
        #expect(m.isolateSelectionLayers())
        #expect(!frozen(m, "A"))                  // selection's layer kept
        #expect(frozen(m, "B"))
        #expect(frozen(m, "C"))
    }

    @Test("isolate is undoable via the layer mutation funnel")
    func isolateUndo() {
        let (m, _, _) = layeredModel()
        m.isolateLayer("A")
        #expect(frozen(m, "B"))
        m.undo()                                  // the mutateLayers value-snapshot reverts
        #expect(!frozen(m, "B"))
        #expect(!frozen(m, "A"))
    }

    @Test("turnOffOtherLayers freezes others without stashing a restore")
    func turnOffOthers() {
        let (m, _, _) = layeredModel()
        #expect(m.turnOffOtherLayers(except: "A"))
        #expect(!frozen(m, "A"))
        #expect(frozen(m, "B"))
        #expect(frozen(m, "C"))
        #expect(!m.hasIsolatedLayers)             // distinct from isolate — no restore stash
        m.undo()
        #expect(!frozen(m, "B"))                  // undoable
    }

    @Test("makeLayerCurrent sets the active layer (undoable) and rejects unknown / same")
    func makeCurrent() {
        let (m, _, _) = layeredModel()
        #expect(m.drawing.layers.activeLayerName == "0")
        #expect(m.makeLayerCurrent("B"))
        #expect(m.drawing.layers.activeLayerName == "B")
        #expect(!m.makeLayerCurrent("B"))         // already current → no-op
        #expect(!m.makeLayerCurrent("NOPE"))      // unknown → no-op
        m.undo()
        #expect(m.drawing.layers.activeLayerName == "0")
    }
}

// MARK: - Stage 3 — snap seed + paste-as-block

@MainActor
@Suite("Wave-3B CanvasModel wiring — snap seed + paste-as-block")
struct Wave3BSnapSeedAndPasteBlockTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    // MARK: Snap seed (pure read-site)

    @Test("applySnapSeed adopts the snapshot's snap mask / aperture / polar increment")
    func snapSeedAppliesSnapshot() {
        let m = model()
        // The plain init keeps the built-in interactive default (no .grid).
        #expect(!m.snapModes.contains(.grid))
        #expect(m.pickAperturePoints == CanvasModel.catchPoints)   // 8 by default

        var snapshot = AppSettingsModel.standard
        snapshot.defaultSnap = AppSettings.snapMode(fromMask: Int(SnapMode.standard.rawValue))
        snapshot.snapAperturePx = 20
        snapshot.polarIncrementRadians = .pi / 6   // 30°

        m.applySnapSeed(snapshot)
        #expect(m.snapModes == SnapMode.standard)            // adopted the saved default mask
        #expect(m.snapModes.contains(.grid))                 // standard includes grid
        #expect(m.pickAperturePoints == 20)                  // adopted (within clamp range)
        #expect(m.polarAngleIncrement == .pi / 6)            // adopted radians
    }

    @Test("applySnapSeed clamps an out-of-range aperture")
    func snapSeedClampsAperture() {
        let m = model()
        var snapshot = AppSettingsModel.standard
        snapshot.snapAperturePx = 9999                       // way over the 64 ceiling
        m.applySnapSeed(snapshot)
        #expect(m.pickAperturePoints == 64)                  // AppSettings.clampAperture
    }

    @Test("the plain init does NOT seed from app settings (defaults preserved)")
    func initDoesNotSeed() {
        let m = model()
        // The documented invariant: existing behavior is untouched unless a window
        // explicitly seeds. The interactive default omits .grid; aperture stays 8.
        #expect(m.snapModes == [.endpoint, .center, .middle, .intersection, .onEntity, .free])
        #expect(m.pickAperturePoints == 8)
    }

    @Test("worldTolerance tracks the live aperture")
    func worldToleranceTracksAperture() {
        let m = model()
        let base = m.worldTolerance
        m.pickAperturePoints = 16                             // 2× the default 8
        #expect(m.worldTolerance == base * 2)
    }

    // MARK: Paste as block

    /// A model with two lines; both copied to the clipboard. Returns the model.
    private func clipboardModel() -> CanvasModel {
        let drawing = CADDrawing()
        let a = drawing.add(line(Vector(0, 0), Vector(10, 0)))
        let b = drawing.add(line(Vector(0, 0), Vector(0, 10)))
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        m.selection = Selection(ids: [a, b])
        #expect(m.copySelection())                           // load the clipboard
        return m
    }

    @Test("pasteAsBlock creates a block + one INSERT, undoably")
    func pasteAsBlockCreatesBlockAndInsert() throws {
        let m = clipboardModel()
        let blocksBefore = m.drawing.blocks.blocks.count
        let entitiesBefore = m.drawing.entities.count        // the 2 originals

        #expect(m.pasteAsBlock(name: "PART", at: Vector(50, 50)))
        #expect(m.drawing.blocks.blocks.count == blocksBefore + 1)
        let block = try #require(m.drawing.blocks.block(named: "PART"))
        #expect(block.entityIDs.count == 2)                  // both clipboard records are members

        // Exactly one new INSERT of the block landed at the paste point + is selected.
        let inserts = m.drawing.entities.filter {
            if case .insert(let d) = $0.kind { return d.blockName == "PART" }
            return false
        }
        #expect(inserts.count == 1)
        guard case .insert(let data) = inserts.first?.kind else { Issue.record("no insert"); return }
        #expect(data.insertionPoint == Vector(50, 50))
        #expect(m.selection.ids == [inserts.first!.id])      // the INSERT is selected

        // ONE undo reverts the WHOLE paste-as-block (block + members + insert gone),
        // leaving only the two original lines.
        m.undo()
        #expect(m.drawing.blocks.blocks.count == blocksBefore)
        #expect(m.drawing.entities.count == entitiesBefore)
        #expect(m.drawing.blocks.block(named: "PART") == nil)
    }

    @Test("pasteAsBlock falls back to a default name on a blank/nil name")
    func pasteAsBlockDefaultName() {
        let m = clipboardModel()
        #expect(m.pasteAsBlock(name: "   ", at: Vector(0, 0)))
        // The engine op de-dups to a free name from the "Block" suggestion.
        #expect(m.drawing.blocks.blocks.contains { $0.name.hasPrefix("Block") || $0.name == "Block" })
    }

    @Test("pasteAsBlock is a no-op for an empty clipboard")
    func pasteAsBlockEmptyClipboard() {
        let m = model()                                      // never copied anything
        #expect(!m.pasteAsBlock(name: "X", at: Vector(0, 0)))
        #expect(m.drawing.blocks.blocks.isEmpty)
        #expect(!m.undoManager.canUndo)
    }

    @Test("pasteAsBlock(name:) at view center places an insert near the center")
    func pasteAsBlockViewCenter() {
        let m = clipboardModel()
        #expect(m.pasteAsBlock(name: "C"))
        #expect(m.drawing.blocks.block(named: "C") != nil)
        let inserts = m.drawing.entities.filter {
            if case .insert = $0.kind { return true }
            return false
        }
        #expect(inserts.count == 1)
    }
}
