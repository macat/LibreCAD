//
//  RelativeZeroTests.swift
//  CADEngineTests
//
//  Unit tests for the relative-zero (LibreCAD's "Set relative zero") set / lock /
//  reset / one-shot-pick workflow on `CanvasModel`. The relative zero is the datum the
//  command line's `@dx,dy` / polar / bare-distance input is measured from. By default
//  it AUTO-FOLLOWS the last placed point; the user can pin it (set), LOCK it so it
//  stops auto-advancing, RESET it to the absolute origin (0,0), and ARM a one-shot pick
//  that consumes the next select-mode canvas click to set the datum.
//
//  These exercise the testable `CanvasModel` methods (no SwiftUI / no NSOpenPanel):
//    • set → `relativeZero` updates to the point,
//    • arm + simulated click → the next `toggleSelection` sets the datum (snapped) and
//      disarms, without toggling selection,
//    • lock → a simulated "last point" (`handleToolInput(.click)`) does NOT auto-advance
//      the datum, and the lock survives tool-change / run-end,
//    • unlock → the auto-follow behavior resumes,
//    • reset → the datum becomes (0, 0).
//
//  The suite is `@MainActor` (CanvasModel is a main-actor `@Observable`), matching the
//  other model-driving suites (ToolTests' modify-contract suite).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Test-target scaffolding
//
// `CanvasModel` lives in the `LibreCADmacOS` app module, which the `CADEngineTests`
// target does not depend on; the project's convention for testing app-module code is to
// symlink the source into the test target as `_Shared<Name>.swift` (see the 8 existing
// `_Shared*` symlinks). `CanvasModel.swift` is symlinked here as `_SharedCanvasModel.swift`
// and compiles cleanly against `CADEngine` with ONE exception: it references `PaperSize`,
// a trivial value enum that currently lives inside the SwiftUI file
// `DocumentSettingsView.swift` (which cannot be symlinked — it cascades into `CADCanvasView`
// and SwiftUI view builders). `CanvasModel` only uses `PaperSize` as the type of one
// stored default (`paperSize = .a4`) and never calls its methods, so this minimal,
// behavior-free shim satisfies the symlinked compile without pulling in the view layer.
// It is test-target-only (the app target keeps the real definition), and the relative-zero
// tests never touch paper size, so there is no behavioral drift risk. (See the report's
// non-owned-file flag: relocating `PaperSize` out of the SwiftUI file would let the symlink
// resolve without any shim.)
enum PaperSize: String, Sendable, CaseIterable, Hashable {
    case a4, a3, a2, a1, a0, letter, legal, tabloid
}

@MainActor
@Suite("Relative zero — set / lock / reset / one-shot pick")
struct RelativeZeroTests {

    private let eps = 1e-9

    /// A fresh empty model with a known view size. An EMPTY drawing means the snapper
    /// falls back to `.free` (no geometry to bind to), so `snappedWorldPoint` returns
    /// exactly the cursor's world point — making the armed-pick coordinate predictable.
    private func makeModel() -> CanvasModel {
        CanvasModel(viewSize: CGSize(width: 800, height: 600))
    }

    // MARK: - Set

    @Test("setRelativeZero updates the datum to the given point")
    func setUpdatesDatum() {
        let model = makeModel()
        #expect(model.relativeZero == nil)              // fresh model has no datum
        model.setRelativeZero(Vector(12.5, -8))
        #expect(model.relativeZero == Vector(12.5, -8))
    }

    @Test("setRelativeZero ignores an invalid point (no manufactured datum)")
    func setIgnoresInvalid() {
        let model = makeModel()
        model.setRelativeZero(Vector(3, 4))
        model.setRelativeZero(.invalid)
        #expect(model.relativeZero == Vector(3, 4))     // unchanged
    }

    // MARK: - One-shot armed pick (rides the existing select-mode click path)

    @Test("arming makes the next select-mode click set the datum (snapped) and disarm")
    func armedClickSetsDatum() {
        let model = makeModel()
        #expect(!model.settingRelativeZeroArmed)
        model.armSetRelativeZero()
        #expect(model.settingRelativeZeroArmed)

        // The select-mode click path (`toggleSelection`) consults the arm first. On an
        // empty drawing the snapped point equals the raw screen→world point, so assert
        // the datum lands exactly where that screen point maps.
        let screen = CGPoint(x: 200, y: 150)
        let expected = model.viewport.screenToWorld(screen)
        let changed = model.toggleSelection(atScreenPoint: screen)

        #expect(changed)                                // consumed the click → redraw
        #expect(!model.settingRelativeZeroArmed)        // auto-disarmed (one-shot)
        #expect(model.relativeZero != nil)
        #expect(abs((model.relativeZero?.x ?? .nan) - expected.x) < eps)
        #expect(abs((model.relativeZero?.y ?? .nan) - expected.y) < eps)
    }

    @Test("an UNARMED select-mode click does NOT touch the relative zero")
    func unarmedClickDoesNotSetDatum() {
        let model = makeModel()
        // Not armed: a click on empty space just (de)selects — here a no-op — and never
        // sets a datum.
        _ = model.toggleSelection(atScreenPoint: CGPoint(x: 100, y: 100))
        #expect(model.relativeZero == nil)
        #expect(!model.settingRelativeZeroArmed)
    }

    @Test("cancelSetRelativeZero disarms a pending pick without setting a datum")
    func cancelDisarms() {
        let model = makeModel()
        model.armSetRelativeZero()
        model.cancelSetRelativeZero()
        #expect(!model.settingRelativeZeroArmed)
        #expect(model.relativeZero == nil)
    }

    // MARK: - Lock / unlock vs auto-follow

    @Test("unlocked, the datum AUTO-ADVANCES to the last placed point")
    func unlockedAutoAdvances() {
        let model = makeModel()
        model.activateTool(.line)
        // First click of a Line fixes its start; the datum should follow to it.
        _ = model.handleToolInput(.click(Vector(5, 5)))
        #expect(model.relativeZero == Vector(5, 5))
        // A second placed point advances the datum again (the default behavior).
        _ = model.handleToolInput(.click(Vector(20, 5)))
        #expect(model.relativeZero == Vector(20, 5))
    }

    @Test("LOCKED, the datum does NOT auto-advance after a simulated last point")
    func lockedDoesNotAutoAdvance() {
        let model = makeModel()
        model.setRelativeZero(Vector(100, 100))         // pin a datum
        _ = model.toggleRelativeZeroLock()              // lock it
        #expect(model.relativeZeroLocked)

        model.activateTool(.line)
        // Placing points must NOT move the locked datum.
        _ = model.handleToolInput(.click(Vector(5, 5)))
        #expect(model.relativeZero == Vector(100, 100))
        _ = model.handleToolInput(.click(Vector(40, 9)))
        #expect(model.relativeZero == Vector(100, 100))
    }

    @Test("UNLOCKING resumes the auto-follow behavior")
    func unlockResumesAutoFollow() {
        let model = makeModel()
        model.setRelativeZero(Vector(100, 100))
        model.setRelativeZeroLocked(true)
        model.activateTool(.line)
        _ = model.handleToolInput(.click(Vector(5, 5)))
        #expect(model.relativeZero == Vector(100, 100))  // held while locked

        model.setRelativeZeroLocked(false)               // unlock
        #expect(!model.relativeZeroLocked)
        _ = model.handleToolInput(.click(Vector(7, 8)))  // now follows again
        #expect(model.relativeZero == Vector(7, 8))
    }

    @Test("toggleRelativeZeroLock flips the flag and returns the new state")
    func toggleReturnsNewState() {
        let model = makeModel()
        #expect(model.toggleRelativeZeroLock() == true)
        #expect(model.relativeZeroLocked)
        #expect(model.toggleRelativeZeroLock() == false)
        #expect(!model.relativeZeroLocked)
    }

    @Test("a LOCKED datum survives a tool change (activateTool keeps it)")
    func lockSurvivesToolChange() {
        let model = makeModel()
        model.setRelativeZero(Vector(50, 60))
        model.setRelativeZeroLocked(true)
        model.activateTool(.line)
        #expect(model.relativeZero == Vector(50, 60))    // not cleared on activate
        model.activateTool(.circle)
        #expect(model.relativeZero == Vector(50, 60))
    }

    @Test("an UNLOCKED datum is cleared on a tool change (default behavior intact)")
    func unlockedClearsOnToolChange() {
        let model = makeModel()
        model.activateTool(.line)
        _ = model.handleToolInput(.click(Vector(9, 9)))
        #expect(model.relativeZero == Vector(9, 9))
        model.activateTool(.circle)                      // fresh tool → fresh datum
        #expect(model.relativeZero == nil)
    }

    @Test("a LOCKED datum survives a run-end (commit/cancel → .finished)")
    func lockSurvivesRunEnd() {
        let model = makeModel()
        model.setRelativeZero(Vector(11, 22))
        model.setRelativeZeroLocked(true)
        model.activateTool(.line)
        _ = model.handleToolInput(.click(Vector(0, 0)))  // does not move the locked datum
        _ = model.handleToolInput(.cancel)               // run ends (.finished)
        #expect(model.relativeZero == Vector(11, 22))    // datum persists across the run
    }

    // MARK: - Reset to origin

    @Test("resetRelativeZeroToOrigin sets the datum to (0, 0)")
    func resetToOrigin() {
        let model = makeModel()
        model.setRelativeZero(Vector(42, -17))
        model.resetRelativeZeroToOrigin()
        #expect(model.relativeZero == Vector(0, 0))
    }

    @Test("reset leaves the lock state untouched (it only moves the datum)")
    func resetKeepsLock() {
        let model = makeModel()
        model.setRelativeZeroLocked(true)
        model.setRelativeZero(Vector(5, 5))
        model.resetRelativeZeroToOrigin()
        #expect(model.relativeZero == Vector(0, 0))
        #expect(model.relativeZeroLocked)                // still locked
    }

    // MARK: - Status readout

    @Test("the status readout reflects armed / set / locked states")
    func readoutReflectsState() {
        let model = makeModel()
        #expect(model.relativeZeroReadout == nil)        // nothing to report yet

        model.armSetRelativeZero()
        #expect(model.relativeZeroReadout?.contains("pick") == true)
        model.cancelSetRelativeZero()

        model.setRelativeZero(Vector(3, 4))
        let setReadout = model.relativeZeroReadout
        #expect(setReadout != nil)
        #expect(setReadout?.contains("RelZero") == true)

        model.setRelativeZeroLocked(true)
        #expect(model.relativeZeroReadout?.contains("\u{1F512}") == true)  // lock marker
    }
}
