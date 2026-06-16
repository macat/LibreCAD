//
//  InsertOptionsAndBlockFreezeWiringTests.swift
//  CADEngineTests
//
//  The INSERT-options + per-block FREEZE wire-wave (the engine already supports both —
//  this proves the GUI wiring carries the config through and the model wrappers behave):
//
//   • Insert placement options (Tool Options bar): `CanvasModel`'s insert config fields
//     (scale uniform/X/Y, rotation, rows/cols, row/col spacing) flow onto the live
//     `InsertTool` via `applyToolConfig` / `reapplyActiveToolConfig`. Driven END-TO-END:
//     arm an InsertTool for a real block, click an insertion point, and assert the
//     committed `InsertData` carries the configured scale / rotation / MINSERT array.
//     Defaults (unconfigured) commit a plain unit-scale, unrotated 1×1 insert.
//
//   • Per-block freeze: `CanvasModel.toggleBlockFrozen` / `setBlockFrozen` /
//     `freezeAllBlocks` / `thawAllBlocks` flip `Block.isFrozen`, make a resolved insert
//     of the block go EMPTY (re-resolve), and are undoable. Freeze-all / Thaw-all affect
//     every named block. Pure model/state paths — no NSMenu / no modal is touched.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the existing
//  `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `BlockUIWiringTests`). No SwiftUI body / `BlocksPanelMenu` / options-bar view is
//  rendered here — only the pure model wiring the View layer drives.
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
@Suite("insert options + block freeze wiring")
struct InsertOptionsAndBlockFreezeWiringTests {

    // MARK: - Helpers

    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    /// A model with one block "WIDGET" (a single member line at the local origin) plus
    /// one insert of it at `insertAt`. The undo manager is the testing (manual-grouping)
    /// one with a clean stack. Returns the model + member + insert ids.
    private func seededBlockModel(
        member: (Vector, Vector) = (Vector(0, 0), Vector(10, 0)),
        insertAt: Vector = Vector(20, 20)
    ) -> (model: CanvasModel, memberID: EntityID, insertID: EntityID) {
        let drawing = CADDrawing()
        let mID = drawing.add(line(member.0, member.1))
        drawing.mutateBlocks { _ = $0.add(Block(name: "WIDGET", entityIDs: [mID])) }
        let iID = drawing.add(EntityRecord(
            id: .placeholder,
            kind: .insert(InsertData(blockName: "WIDGET", insertionPoint: insertAt))))
        let model = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        model.undoManager.groupsByEvent = false
        model.undoManager.removeAllActions()
        return (model, mID, iID)
    }

    /// Whether a resolved geometry has any drawable output at all.
    private func isEmptyGeometry(_ g: ResolvedGeometry) -> Bool {
        g.polylines.allSatisfy { $0.points.isEmpty }
            && g.fills.isEmpty && g.images.isEmpty
    }

    private func resolveInsert(_ m: CanvasModel, _ id: EntityID) -> ResolvedGeometry {
        m.drawing.entity(id)!.resolve(m.drawing.makeResolveContext())
    }

    /// The single `.insert` committed by the active tool on a `.click`, by diffing the
    /// drawing's insert set before/after. Returns the NEW insert's `InsertData`, or nil
    /// if the click committed nothing. Drives the model exactly like the canvas does.
    private func clickAndExtractInsert(_ m: CanvasModel, at p: Vector) -> InsertData? {
        let before = Set(m.drawing.entities.map(\.id))
        _ = m.handleToolInput(.click(p))
        for e in m.drawing.entities where !before.contains(e.id) {
            if case .insert(let d) = e.kind { return d }
        }
        return nil
    }

    // MARK: - Insert options: applyToolConfig carries scale / rotation / array

    @Test("applyToolConfig builds an InsertTool carrying the configured scale / rotation / array")
    func applyToolConfigCarriesInsertOptions() {
        let (m, _, _) = seededBlockModel()
        // Configure the Tool Options bar fields (per-axis scale, rotation, 2×3 array).
        m.pendingInsertBlockName = "WIDGET"
        m.insertScaleUniform = false
        m.insertScaleX = 2
        m.insertScaleY = 3
        m.insertRotation = .pi / 2           // 90° (radians, the model's storage)
        m.insertRows = 2
        m.insertCols = 3
        m.insertRowSpacing = 15
        m.insertColSpacing = 25

        // Arming the tool runs applyToolConfig (activateTool calls it).
        m.activateTool(.insert)
        #expect(m.activeToolKind == .insert)
        #expect(m.tool is InsertTool)

        // A click commits ONE insert carrying every configured value.
        let data = clickAndExtractInsert(m, at: Vector(40, 40))
        #expect(data != nil)
        #expect(data?.blockName == "WIDGET")
        #expect(data?.scale == Vector(2, 3))
        #expect(abs((data?.rotation ?? 0) - .pi / 2) < 1e-12)
        #expect(data?.rows == 2)
        #expect(data?.cols == 3)
        #expect(data?.rowSpacing == 15)
        #expect(data?.colSpacing == 25)
    }

    @Test("uniform scale maps the single factor onto BOTH axes")
    func applyToolConfigUniformScale() {
        let (m, _, _) = seededBlockModel()
        m.pendingInsertBlockName = "WIDGET"
        m.insertScaleUniform = true
        m.insertScaleX = 4
        m.insertScaleY = 99            // ignored while uniform
        m.activateTool(.insert)

        let data = clickAndExtractInsert(m, at: Vector(40, 40))
        #expect(data?.scale == Vector(4, 4))
    }

    @Test("an unconfigured Insert tool commits a plain unit-scale, unrotated 1×1 insert")
    func applyToolConfigDefaultsUnchanged() {
        let (m, _, _) = seededBlockModel()
        m.pendingInsertBlockName = "WIDGET"
        m.activateTool(.insert)        // no config touched → defaults

        let data = clickAndExtractInsert(m, at: Vector(40, 40))
        #expect(data?.scale == Vector(1, 1))
        #expect(data?.rotation == 0)
        #expect(data?.rows == 1)
        #expect(data?.cols == 1)
        #expect(data?.rowSpacing == 0)
        #expect(data?.colSpacing == 0)
    }

    @Test("reapplyActiveToolConfig pushes a changed option onto the ALREADY-active Insert tool")
    func reapplyActiveToolConfigUpdatesLiveInsert() {
        let (m, _, _) = seededBlockModel()
        m.pendingInsertBlockName = "WIDGET"
        m.activateTool(.insert)        // armed with defaults (scale 1, 1×1)

        // The options bar changes scale + array while the tool is live, then re-applies.
        m.insertScaleUniform = true
        m.insertScaleX = 5
        m.insertRows = 4
        m.insertColSpacing = 7
        m.reapplyActiveToolConfig()

        let data = clickAndExtractInsert(m, at: Vector(40, 40))
        #expect(data?.scale == Vector(5, 5))
        #expect(data?.rows == 4)
        #expect(data?.colSpacing == 7)
    }

    @Test("a CHAINED placement keeps the config across the .finished re-mint")
    func chainedInsertKeepsConfigAfterReMint() {
        let (m, _, _) = seededBlockModel()
        m.pendingInsertBlockName = "WIDGET"
        m.insertScaleUniform = true
        m.insertScaleX = 6
        m.insertRotation = .pi / 4
        m.insertRows = 2
        m.insertColSpacing = 11
        m.activateTool(.insert)

        // First placement — committed on the click; the tool STAYS active (chains).
        let first = clickAndExtractInsert(m, at: Vector(40, 40))
        #expect(first?.scale == Vector(6, 6))
        #expect(first?.rows == 2)

        // End the run (Return) → handleToolInput's .finished branch re-mints the tool via
        // applyToolConfig, which must rebuild it carrying the SAME config.
        _ = m.handleToolInput(.commit)
        #expect(m.activeToolKind == .insert)   // re-armed for the next placement
        #expect(m.tool is InsertTool)

        // Second placement on the freshly re-minted tool still honors every option.
        let second = clickAndExtractInsert(m, at: Vector(80, 80))
        #expect(second?.scale == Vector(6, 6))
        #expect(abs((second?.rotation ?? 0) - .pi / 4) < 1e-12)
        #expect(second?.rows == 2)
        #expect(second?.colSpacing == 11)
        #expect(second?.insertionPoint == Vector(80, 80))
    }

    @Test("the InsertTool's scale assembler matches the model split-state mapping")
    func insertScaleValueMapping() {
        let (m, _, _) = seededBlockModel()
        m.insertScaleUniform = true
        m.insertScaleX = 3
        m.insertScaleY = 8
        #expect(m.insertScaleValue == Vector(3, 3))   // uniform ⇒ (X, X)
        m.insertScaleUniform = false
        #expect(m.insertScaleValue == Vector(3, 8))   // per-axis ⇒ (X, Y)
    }

    // MARK: - Per-block freeze: model wrapper flips the flag + hides the insert

    @Test("toggleBlockFrozen flips isFrozen AND a resolved insert goes empty / back")
    func toggleBlockFrozenHidesAndShowsInsert() {
        let (m, _, insertID) = seededBlockModel()
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == false)
        #expect(!isEmptyGeometry(resolveInsert(m, insertID)))

        m.toggleBlockFrozen("WIDGET")
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == true)
        #expect(isEmptyGeometry(resolveInsert(m, insertID)))   // frozen ⇒ empty

        m.toggleBlockFrozen("WIDGET")
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == false)
        #expect(!isEmptyGeometry(resolveInsert(m, insertID)))   // thawed ⇒ visible
    }

    @Test("toggleBlockFrozen is undoable as ONE step")
    func toggleBlockFrozenUndoable() {
        let (m, _, _) = seededBlockModel()
        m.undoManager.beginUndoGrouping()
        m.toggleBlockFrozen("WIDGET")
        m.undoManager.endUndoGrouping()
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == true)

        m.undoManager.undo()
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == false)
        m.undoManager.redo()
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == true)
    }

    @Test("setBlockFrozen sets the flag explicitly; bumps modelVersion")
    func setBlockFrozenExplicit() {
        let (m, _, insertID) = seededBlockModel()
        let v0 = m.modelVersion
        m.setBlockFrozen("WIDGET", true)
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == true)
        #expect(isEmptyGeometry(resolveInsert(m, insertID)))
        #expect(m.modelVersion != v0)        // sidebar/renderer re-resolve gate bumped
    }

    @Test("toggleBlockFrozen on an unknown block is a safe no-op (no undo)")
    func toggleUnknownBlockNoOp() {
        let (m, _, _) = seededBlockModel()
        m.undoManager.removeAllActions()
        m.toggleBlockFrozen("GHOST")
        #expect(m.canUndo == false)
        #expect(m.drawing.blocks.block(named: "WIDGET")?.isFrozen == false)
    }

    // MARK: - Freeze all / thaw all: every named block, undoable

    @Test("freezeAllBlocks freezes every named block; thawAllBlocks restores all")
    func freezeThawAllNamedBlocks() {
        let drawing = CADDrawing()
        drawing.mutateBlocks {
            _ = $0.add(Block(name: "A"))
            _ = $0.add(Block(name: "B"))
            _ = $0.add(Block(name: "C"))
        }
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()

        m.freezeAllBlocks()
        for n in ["A", "B", "C"] {
            #expect(m.drawing.blocks.block(named: n)?.isFrozen == true)
        }

        m.thawAllBlocks()
        for n in ["A", "B", "C"] {
            #expect(m.drawing.blocks.block(named: n)?.isFrozen == false)
        }
    }

    @Test("freezeAllBlocks reverts in ONE undo step (whole batch coalesced)")
    func freezeAllUndoableAsOneStep() {
        let drawing = CADDrawing()
        drawing.mutateBlocks {
            _ = $0.add(Block(name: "A"))
            _ = $0.add(Block(name: "B"))
        }
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()

        m.undoManager.beginUndoGrouping()
        m.freezeAllBlocks()
        m.undoManager.endUndoGrouping()
        #expect(m.drawing.blocks.block(named: "A")?.isFrozen == true)
        #expect(m.drawing.blocks.block(named: "B")?.isFrozen == true)

        m.undoManager.undo()              // a single ⌘Z reverts the whole batch
        #expect(m.drawing.blocks.block(named: "A")?.isFrozen == false)
        #expect(m.drawing.blocks.block(named: "B")?.isFrozen == false)
    }

    @Test("freezeAllBlocks when nothing changes registers no undo")
    func freezeAllNoOpNoUndo() {
        let drawing = CADDrawing()
        drawing.mutateBlocks {
            _ = $0.add(Block(name: "A", isFrozen: true))
            _ = $0.add(Block(name: "B", isFrozen: true))
        }
        let m = CanvasModel(drawing: drawing, viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        m.freezeAllBlocks()               // every named block already frozen
        #expect(m.canUndo == false)
    }
}
