//
//  DocumentSettingsTests.swift
//  CADEngineTests
//
//  Tests for the Document Settings feature (V4 — owner directive "add a document
//  settings page"; ux-plan.md Part 3, decisions D3/D4/D5). Covers the ENGINE-
//  testable surface that the `DocumentSettingsView` sheet drives through `CanvasModel`
//  (which lives in the un-importable executable target):
//
//   1. The new `GraphicVariables` typed accessors round-trip IN MEMORY (set →
//      read, and through `CADDrawing.load`): `$GRIDUNIT`, `$DIMTXT`, `$DIMASZ`,
//      `$DIMSCALE`, `$DIMLUNIT`, `$DIMDEC`, and the private `$LC_SNAPMODE` (D5).
//      NOTE: these tests exercise ONLY the in-memory accessor + the value-snapshot
//      `CADDrawing.load` path — NOT a DXF-FILE round-trip (write to .dxf bytes and
//      re-read). The DXF save→reopen round-trip for the standard header vars is
//      covered by `SaveRoundTripTests` (the codec write→read path); `$LC_SNAPMODE`
//      is in-memory-only and does NOT survive a .dxf file write (libdxfrw drops
//      non-curated `$`-vars).
//   2. A settings edit applies to the drawing AND is undoable — through the
//      undoable `CADDrawing.mutateGraphicVariables` value-snapshot mutator that
//      `CanvasModel`'s settings setters funnel through (D3: one undo step per field).
//   3. The `dimStyleProvider` hook makes a no-override dimension pick up the
//      document default text height (D4: per-entity wins when set; document default
//      fills in otherwise) — both via the precedence helper AND end-to-end through
//      `makeResolveContext`.
//
//  Suite/type names are domain-namespaced per CONVENTIONS.md to avoid the
//  parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - GraphicVariables: the new Document-Settings accessors round-trip

@MainActor
@Suite("Document Settings — graphic-variable accessors")
struct DocumentSettingsVariableTests {

    @Test("new accessors round-trip set → read with the right DXF backing keys")
    func newAccessorsRoundTrip() {
        var v = GraphicVariables()

        // $GRIDUNIT — stored as a vector (DXF code 10/20); read back as the scalar.
        v.gridSpacing = 5.0
        #expect(v.gridSpacing == 5.0)
        #expect(v.vector("$GRIDUNIT").x == 5.0)

        // $DIMTXT / $DIMASZ / $DIMSCALE — doubles.
        v.dimTextHeight = 3.5
        #expect(v.dimTextHeight == 3.5)
        #expect(v.double("$DIMTXT") == 3.5)

        v.dimArrowSize = 4.0
        #expect(v.dimArrowSize == 4.0)
        #expect(v.double("$DIMASZ") == 4.0)

        v.dimScale = 2.0
        #expect(v.dimScale == 2.0)
        #expect(v.double("$DIMSCALE") == 2.0)

        // $DIMLUNIT / $DIMDEC — format enum + int precision.
        v.dimLinearFormat = .architectural
        #expect(v.dimLinearFormat == .architectural)
        #expect(v.int("$DIMLUNIT") == 4)

        v.dimLinearPrecision = 6
        #expect(v.dimLinearPrecision == 6)
        #expect(v.int("$DIMDEC") == 6)
    }

    @Test("new accessors have LibreCAD-matching defaults")
    func newAccessorDefaults() {
        let v = GraphicVariables()
        #expect(v.gridSpacing == 1.0)
        #expect(v.dimTextHeight == 2.5)
        #expect(v.dimArrowSize == 2.5)
        #expect(v.dimScale == 1.0)
        #expect(v.dimLinearFormat == .decimal)
        #expect(v.dimLinearPrecision == 4)
        #expect(v.snapModeRaw == nil)   // unset until persisted (D5)
    }

    @Test("$LC_SNAPMODE persists + clears the private snap-mode set (D5)")
    func snapModeRawRoundTrip() {
        var v = GraphicVariables()
        let modes: SnapMode = [.endpoint, .center, .grid]
        v.snapModeRaw = Int(modes.rawValue)
        #expect(v.snapModeRaw == Int(modes.rawValue))
        #expect(v.has("$LC_SNAPMODE"))
        // Reconstructs the exact set.
        let read = SnapMode(rawValue: UInt16(truncatingIfNeeded: v.snapModeRaw!))
        #expect(read == modes)

        // nil clears the var (so an "unset" state round-trips, not a sticky 0).
        v.snapModeRaw = nil
        #expect(v.snapModeRaw == nil)
        #expect(!v.has("$LC_SNAPMODE"))
    }

    // NOTE: this checks the IN-MEMORY value-snapshot path only (`CADDrawing.load`
    // replaces the whole `graphicVariables` value). It does NOT write to a .dxf file
    // and re-read it — the DXF FILE save→reopen round-trip for the standard header
    // vars lives in `SaveRoundTripTests` (the codec write→read path).
    @Test("settings survive a CADDrawing.load value-snapshot round-trip (in-memory, not a DXF file)")
    func settingsSurviveLoadRoundTrip() {
        var v = GraphicVariables()
        v.unit = .inch
        v.linearPrecision = 2
        v.gridSpacing = 12.5
        v.dimTextHeight = 7.0
        v.snapModeRaw = Int(SnapMode([.endpoint, .middle]).rawValue)

        // The document open/save path replaces the whole graphicVariables value.
        let drawing = CADDrawing()
        drawing.load(entities: [], layers: LayerTable(), blocks: BlockTable(),
                     graphicVariables: v)

        #expect(drawing.graphicVariables.unit == .inch)
        #expect(drawing.graphicVariables.linearPrecision == 2)
        #expect(drawing.graphicVariables.gridSpacing == 12.5)
        #expect(drawing.graphicVariables.dimTextHeight == 7.0)
        #expect(drawing.graphicVariables.snapModeRaw == Int(SnapMode([.endpoint, .middle]).rawValue))
    }
}

// MARK: - Settings edit applies + is undoable (D3)

@MainActor
@Suite("Document Settings — undoable apply (D3)")
struct DocumentSettingsUndoTests {

    /// An UndoManager configured for unit testing (manual grouping; no run loop to
    /// auto-close per-event groups). Matches the project's existing convention.
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// Applies one settings field edit as ONE undo group — mirrors the live
    /// `CanvasModel` path where `groupsByEvent == true` coalesces a single
    /// run-loop event into one step. In tests (`groupsByEvent == false`) we open an
    /// explicit group, exactly as `CanvasModel.applyCommit` does.
    private func editField(_ drawing: CADDrawing, undo um: UndoManager,
                           _ body: (inout GraphicVariables) -> Void) {
        um.beginUndoGrouping()
        drawing.mutateGraphicVariables(body)
        um.endUndoGrouping()
    }

    @Test("a settings edit applies to the drawing and is undoable (one step)")
    func settingsEditIsUndoable() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        // Baseline (the LibreCAD default the accessor reports).
        #expect(drawing.graphicVariables.linearPrecision == 4)
        #expect(!um.canUndo)

        // ONE field edit through the undoable mutator (the path CanvasModel's
        // settings setters funnel through).
        editField(drawing, undo: um) { $0.linearPrecision = 2 }
        #expect(drawing.graphicVariables.linearPrecision == 2)
        #expect(um.canUndo)

        // Undo restores the prior value; redo re-applies it (value-snapshot pattern).
        um.undo()
        #expect(drawing.graphicVariables.linearPrecision == 4)
        #expect(um.canRedo)

        um.redo()
        #expect(drawing.graphicVariables.linearPrecision == 2)
    }

    @Test("each field is an independent undo step")
    func eachFieldIsItsOwnUndoStep() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        editField(drawing, undo: um) { $0.unit = .meter }
        editField(drawing, undo: um) { $0.dimTextHeight = 5.0 }
        #expect(drawing.graphicVariables.unit == .meter)
        #expect(drawing.graphicVariables.dimTextHeight == 5.0)

        // Undo the dim-text edit only — the unit edit stays.
        um.undo()
        #expect(drawing.graphicVariables.dimTextHeight == 2.5)   // reverted
        #expect(drawing.graphicVariables.unit == .meter)          // untouched

        // Undo again reverts the unit edit.
        um.undo()
        #expect(drawing.graphicVariables.unit == .millimeter)     // back to default
    }

    @Test("a no-op settings edit registers no undo step")
    func noOpEditSkipsUndo() {
        let drawing = CADDrawing()
        let um = testUndoManager()
        drawing.undoManager = um

        // First store a concrete value (this IS a change — it writes the $LUPREC key
        // into the previously-empty bag).
        editField(drawing, undo: um) { $0.linearPrecision = 2 }
        #expect(drawing.graphicVariables.linearPrecision == 2)

        // Writing the SAME value back is a genuine no-op: `mutateGraphicVariables`
        // sees an unchanged bag and registers NO undo. Crucially it does NOT crash
        // even WITHOUT an open group (the registration is what requires a group, and
        // a no-op makes none) — proving the guard short-circuits before registering.
        drawing.mutateGraphicVariables { $0.linearPrecision = 2 }   // same value, no group
        #expect(drawing.graphicVariables.linearPrecision == 2)

        // Undo reverts the ONE real edit back to the default — the no-op added no step.
        um.undo()
        #expect(drawing.graphicVariables.linearPrecision == 4)
        #expect(!um.canUndo)
    }
}

// MARK: - dimStyleProvider hook: document-default dimension style (D4)

@MainActor
@Suite("Document Settings — dimStyleProvider hook (D4)")
struct DocumentSettingsDimStyleTests {

    /// A no-override dimension: a linear dim born with `textHeight == 0` / `arrowSize
    /// == 0` (the "inherit the document style" sentinel).
    private func noOverrideLinearDim() -> EntityRecord {
        let data = DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 5),
            textHeight: 0,   // inherit
            arrowSize: 0)    // inherit
        return EntityRecord(id: EntityID(0), kind: .dimension(data))
    }

    @Test("effective text height: per-entity wins; document default fills in (precedence)")
    func textHeightPrecedence() {
        let docStyle = ResolvedDimStyle(textHeight: 9.0, arrowSize: 3.0, scale: 1.0)
        let ctx = ResolveContext(dimStyleProvider: { docStyle })

        // No-override dim (textHeight 0) → picks up the document default 9.0.
        let inherit = DimData(kind: .linear(extension1: .init(0, 0),
                                            extension2: .init(10, 0), angle: 0),
                              definitionPoint: .init(5, 5),
                              textHeight: 0, arrowSize: 0)
        #expect(EntityKind.dimTextHeight(inherit, ctx: ctx) == 9.0)
        #expect(EntityKind.dimArrowSize(inherit, ctx: ctx) == 3.0)

        // Per-entity value (textHeight 4) WINS over the document default.
        let explicit = DimData(kind: .linear(extension1: .init(0, 0),
                                             extension2: .init(10, 0), angle: 0),
                               definitionPoint: .init(5, 5),
                               textHeight: 4.0, arrowSize: 1.5)
        #expect(EntityKind.dimTextHeight(explicit, ctx: ctx) == 4.0)
        #expect(EntityKind.dimArrowSize(explicit, ctx: ctx) == 1.5)
    }

    @Test("$DIMSCALE multiplies the effective text height + arrow size")
    func dimScaleMultiplies() {
        let docStyle = ResolvedDimStyle(textHeight: 2.0, arrowSize: 2.0, scale: 3.0)
        let ctx = ResolveContext(dimStyleProvider: { docStyle })
        let inherit = DimData(kind: .linear(extension1: .init(0, 0),
                                            extension2: .init(10, 0), angle: 0),
                              definitionPoint: .init(5, 5),
                              textHeight: 0, arrowSize: 0)
        // 2.0 (doc default) * 3.0 (scale) == 6.0.
        #expect(EntityKind.dimTextHeight(inherit, ctx: ctx) == 6.0)
        #expect(EntityKind.dimArrowSize(inherit, ctx: ctx) == 6.0)
    }

    @Test("no provider → engine defaults (existing callers unchanged)")
    func noProviderUsesEngineDefaults() {
        let inherit = DimData(kind: .linear(extension1: .init(0, 0),
                                            extension2: .init(10, 0), angle: 0),
                              definitionPoint: .init(5, 5),
                              textHeight: 0, arrowSize: 0)
        // .default ctx has no dimStyleProvider → falls back to the engine default 2.5.
        #expect(EntityKind.dimTextHeight(inherit, ctx: .default) == 2.5)
        #expect(EntityKind.dimArrowSize(inherit, ctx: .default) == 2.5)
    }

    @Test("end-to-end: makeResolveContext wires $DIMTXT into the no-override dim")
    func makeResolveContextWiresDocDefault() {
        let drawing = CADDrawing()
        // Set the document default dim text height via the Document Settings accessor.
        drawing.graphicVariables.dimTextHeight = 11.0
        drawing.graphicVariables.dimArrowSize = 6.0

        let ctx = drawing.makeResolveContext()
        let dim = noOverrideLinearDim()
        guard case .dimension(let d) = dim.kind else { Issue.record("not a dim"); return }

        // The no-override dimension resolves against the document default (11.0),
        // not the hard-coded 2.5.
        #expect(EntityKind.dimTextHeight(d, ctx: ctx) == 11.0)
        #expect(EntityKind.dimArrowSize(d, ctx: ctx) == 6.0)
    }

    @Test("the document dim style mirrors the $DIM* header vars")
    func dimensionStyleMirrorsHeaderVars() {
        let drawing = CADDrawing()
        drawing.graphicVariables.dimTextHeight = 8.0
        drawing.graphicVariables.dimArrowSize = 1.0
        drawing.graphicVariables.dimScale = 2.0
        drawing.graphicVariables.dimLinearFormat = .fractional
        drawing.graphicVariables.dimLinearPrecision = 3

        let style = drawing.dimensionStyle
        #expect(style.textHeight == 8.0)
        #expect(style.arrowSize == 1.0)
        #expect(style.scale == 2.0)
        #expect(style.linearFormat == .fractional)
        #expect(style.linearPrecision == 3)
    }
}

// MARK: - Measurement-text precision honors $DIMDEC

@Suite("Document Settings — dim text precision ($DIMDEC)")
struct DocumentSettingsDimPrecisionTests {

    @Test("dimFormat honors the requested precision")
    func dimFormatPrecision() {
        // Default precision (4) keeps the historical behavior.
        #expect(EntityKind.dimFormat(3.14159) == "3.1416")
        // Lower precision rounds + trims.
        #expect(EntityKind.dimFormat(3.14159, precision: 2) == "3.14")
        #expect(EntityKind.dimFormat(3.14159, precision: 0) == "3")
        // Trailing zeros are stripped at any precision.
        #expect(EntityKind.dimFormat(10.0, precision: 4) == "10")
        #expect(EntityKind.dimFormat(10.5, precision: 3) == "10.5")
    }

    @Test("dimLabel formats the measurement at the document $DIMDEC precision")
    func dimLabelUsesDocPrecision() {
        let docStyle = ResolvedDimStyle(linearPrecision: 1)
        let ctx = ResolveContext(dimStyleProvider: { docStyle })
        let d = DimData(kind: .aligned(extension1: .init(0, 0), extension2: .init(10, 0)),
                        definitionPoint: .init(5, 5))
        // 3.14159 at precision 1 → "3.1".
        #expect(EntityKind.dimLabel(d, measured: 3.14159, ctx: ctx) == "3.1")
    }
}
