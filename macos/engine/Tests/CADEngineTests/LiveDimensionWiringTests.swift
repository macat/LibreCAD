//
//  LiveDimensionWiringTests.swift
//  CADEngineTests
//
//  live-dim Wave 3 — the WIRING that connects the merged engine seam (`LiveDimension` /
//  `Tool.liveDimensions`) and overlay (`LiveDimensionOverlayView`) to the live document.
//  Covers the PURE, headlessly-testable model surface this wave adds to `CanvasModel`
//  and the `AppSettings` helpers behind it:
//
//   • `CanvasModel.currentLiveDimensions()` GATING — empty when dynamic input is off,
//     empty in select mode (no active tool), empty before a draw is mid-operation, and
//     NON-empty once a draw tool has a fixed point + a moved cursor.
//   • The CONTEXT is built from the drawing's `GraphicVariables` — switching the drawing
//     to architectural inches changes the emitted label's FORMAT (feet-inches), proving
//     the ctx threads `$LUNITS`/`$INSUNITS`/… through, not a hard-coded default.
//   • `CanvasModel.toggleDynamicInput()` flips the published flag AND persists it.
//   • The `AppSettings.boolPreference` / `setBoolPreference` round-trip, including the
//     "missing key honors a TRUE default" contract (which `UserDefaults.bool` would break).
//
//  `CanvasModel` / `AppSettings` live in the (un-importable) app target — reached here via
//  the existing `_SharedCanvasModel.swift` / `_SharedAppSettings.swift` symlinks. The
//  suite is `@MainActor` (mirrors `Wave3BCanvasModelWiringTests`). No SwiftUI body /
//  NSView mount / NSMenu / modal is rendered — only the pure model + settings wiring.
//  (The overlay's DRAWING is GUI-only; it is exercised in the running app, not here.)
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
@Suite("live-dim Wave 3 — CanvasModel.currentLiveDimensions wiring")
struct LiveDimensionWiringCanvasModelTests {

    /// A fresh model with snapping OFF so a `.move(p)` lands the tool cursor at EXACTLY
    /// `p` (no grid/object snap nudging the point), making the emitted geometry/labels
    /// deterministic. Dynamic input defaults ON (the AppSettings default, key unset).
    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.snapModes = []                 // no snapping → moved cursor is used verbatim
        m.gridVisible = false
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// Drive a LineTool to a mid-draw state: fix the start point, then move the cursor —
    /// the state LineTool's `liveDimensions` override requires (`.settingEnd` + a valid,
    /// non-degenerate cursor). Returns the model with the line in progress.
    private func lineInProgress(from a: Vector, to b: Vector) -> CanvasModel {
        let m = model()
        m.activateTool(.line)
        _ = m.handleToolInput(.click(a))   // fix the start → state becomes `.settingEnd`
        _ = m.handleToolInput(.move(b))    // set the rubber-band cursor
        return m
    }

    // MARK: - Gating: empty unless (dynamic input ON) && (a draw tool is mid-operation)

    @Test("empty in select mode (no active tool)")
    func emptyInSelectMode() {
        let m = model()
        #expect(m.dynamicInputEnabled)              // defaults ON
        #expect(!m.isToolActive)                    // select mode
        #expect(m.currentLiveDimensions().isEmpty)
    }

    @Test("empty right after activating a tool, before any point is fixed")
    func emptyBeforeFirstPoint() {
        let m = model()
        m.activateTool(.line)
        #expect(m.isToolActive)
        // No point fixed yet → the tool's override returns [] (the engine contract).
        #expect(m.currentLiveDimensions().isEmpty)
    }

    @Test("NON-empty once a line is mid-draw (point fixed + cursor moved)")
    func nonEmptyMidDraw() throws {
        let m = lineInProgress(from: Vector(0, 0), to: Vector(24, 0))
        let dims = m.currentLiveDimensions()
        #expect(!dims.isEmpty)
        // LineTool emits a linear + an angle descriptor; the linear carries the length.
        let dim = try #require(dims.first { if case .linear = $0.kind { return true }; return false })
        #expect(dim.from == Vector(0, 0))
        #expect(dim.to == Vector(24, 0))
        guard case .linear(let len) = dim.kind else {
            Issue.record("expected a .linear live dimension")
            return
        }
        #expect(abs(len - 24) < 1e-9)
    }

    @Test("empty mid-draw when dynamic input is OFF (the gate)")
    func emptyWhenDisabledMidDraw() {
        let m = lineInProgress(from: Vector(0, 0), to: Vector(24, 0))
        #expect(!m.currentLiveDimensions().isEmpty)   // sanity: ON ⇒ feedback
        m.dynamicInputEnabled = false
        #expect(m.currentLiveDimensions().isEmpty)     // OFF ⇒ suppressed even mid-draw
    }

    // MARK: - The context is built from the drawing's GraphicVariables

    @Test("decimal + unitless — the length label is a plain decimal number")
    func decimalLabel() throws {
        let m = model()
        // Decimal format, explicitly unitless ($INSUNITS=none) so the label is a bare
        // number (a fresh drawing defaults $INSUNITS to millimeter, which would append
        // " mm" — proving the unit field threads through either way). Set the header vars
        // DIRECTLY (not via the undoable `mutateGraphicVariables`, which a test with no
        // open undo group cannot use).
        var gv = m.drawing.graphicVariables
        gv.linearFormat = .decimal
        gv.unit = .none
        m.drawing.graphicVariables = gv
        m.activateTool(.line)
        _ = m.handleToolInput(.click(Vector(0, 0)))
        _ = m.handleToolInput(.move(Vector(24, 0)))
        let dims = m.currentLiveDimensions()
        let linear = try #require(dims.first { if case .linear = $0.kind { return true }; return false })
        #expect(linear.label == "24")
    }

    @Test("the drawing's $INSUNITS reaches the label (millimeter default appends mm)")
    func unitThreadsThrough() throws {
        // A fresh drawing defaults $INSUNITS to millimeter; the decimal label carries it.
        let m = lineInProgress(from: Vector(0, 0), to: Vector(24, 0))
        let dims = m.currentLiveDimensions()
        let linear = try #require(dims.first { if case .linear = $0.kind { return true }; return false })
        #expect(linear.label == "24 mm")
    }

    @Test("architectural inches — the label FORMAT follows GraphicVariables (feet-inches)")
    func architecturalLabelFromGraphicVariables() throws {
        let m = model()
        // Switch the DRAWING to architectural inches BEFORE drawing — the proof the ctx
        // is built from GraphicVariables ($LUNITS=Architectural, $INSUNITS=inch), not a
        // hard-coded default. Set the header vars DIRECTLY (the undoable
        // `mutateGraphicVariables` needs an open undo group a unit test does not have).
        var gv = m.drawing.graphicVariables
        gv.linearFormat = .architectural
        gv.unit = .inch
        m.drawing.graphicVariables = gv
        m.activateTool(.line)
        _ = m.handleToolInput(.click(Vector(0, 0)))
        _ = m.handleToolInput(.move(Vector(24, 0)))    // 24 inches → 2'-0"
        let dims = m.currentLiveDimensions()
        let linear = try #require(dims.first { if case .linear = $0.kind { return true }; return false })
        #expect(linear.label == "2'-0\"")               // architectural, NOT "24"
    }

    // MARK: - toggleDynamicInput flips + persists

    @Test("toggleDynamicInput flips the published flag")
    func toggleFlips() {
        let m = model()
        let before = m.dynamicInputEnabled
        m.toggleDynamicInput()
        #expect(m.dynamicInputEnabled == !before)
        m.toggleDynamicInput()
        #expect(m.dynamicInputEnabled == before)
    }
}

// MARK: - AppSettings bool-preference helpers (pure; isolated UserDefaults)

@Suite("live-dim Wave 3 — AppSettings bool preference round-trip")
struct LiveDimensionWiringAppSettingsTests {

    /// A throwaway `UserDefaults` domain so the tests never touch the real app defaults
    /// (and never collide with each other). Cleaned per call.
    private func scratchDefaults() -> UserDefaults {
        let name = "live-dim-wiring-tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("a MISSING key honors a TRUE default (UserDefaults.bool would return false)")
    func missingKeyHonorsTrueDefault() {
        let d = scratchDefaults()
        // The whole reason `boolPreference` exists: `d.bool(forKey:)` is false here.
        #expect(d.bool(forKey: AppSettings.Key.dynamicInput) == false)
        #expect(AppSettings.boolPreference(AppSettings.Key.dynamicInput,
                                           default: true, defaults: d) == true)
        #expect(AppSettings.boolPreference(AppSettings.Key.dynamicInput,
                                           default: false, defaults: d) == false)
    }

    @Test("set then read round-trips both true and false")
    func setThenRead() {
        let d = scratchDefaults()
        AppSettings.setBoolPreference(AppSettings.Key.dynamicInput, false, defaults: d)
        #expect(AppSettings.boolPreference(AppSettings.Key.dynamicInput,
                                           default: true, defaults: d) == false)
        AppSettings.setBoolPreference(AppSettings.Key.dynamicInput, true, defaults: d)
        #expect(AppSettings.boolPreference(AppSettings.Key.dynamicInput,
                                           default: false, defaults: d) == true)
    }

    @Test("the dynamic-input default is ON")
    func defaultIsOn() {
        #expect(AppSettings.Default.dynamicInput == true)
    }
}
