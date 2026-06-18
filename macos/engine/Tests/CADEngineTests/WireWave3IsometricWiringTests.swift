//
//  WireWave3IsometricWiringTests.swift
//  CADEngineTests
//
//  Wire-wave 3 (final) — the ISOMETRIC drafting MODEL WIRING that surfaces the
//  already-merged + unit-tested iso kernels (`IsoPlane` / `Snapping.snap(…isoPlane:)`
//  / `OverlayGeometry.grid(…isoPlane:)` / `OrthoConstraint.constrain(…isoPlane:)` /
//  `EllipseTool.Mode.isocircle`) to the live `CanvasModel`. This suite asserts ONLY
//  the new CanvasModel surface the View layer (StatusBar ISO chip / F5 / View menu /
//  ToolOptionsBar) drives — NOT the engine kernels (those are pinned in
//  `IsometricSnapTests` / `IsoDrawFeelTests`). Specifically:
//
//   • `isometricMode` reads/writes `$SNAPSTYLE`, is undoable, and bumps the version.
//   • `isoPlane` reads/writes `$LC_ISOPLANE`, independent of `isometricMode`.
//   • `toggleIsometric()` flips the mode; `cycleIsoPlane()` walks Top→Right→Left→Top
//     (the AutoCAD F5 order) regardless of whether iso is on.
//   • `isoPlaneIfActive` gates the snap/grid/crosshair plane on `isometricMode`.
//   • `crosshairAxisAngles` NEGATES the world iso-axis angles for screen space (and is
//     `nil` when iso is off → the rectangular crosshair).
//   • `ellipseModeValue` index 5 maps to `.isocircle(plane: isoPlane)`, following the
//     live plane; `applyToolConfig` re-mints the live `EllipseTool` in that mode.
//   • Iso ortho: `orthoConstrained` routes through the iso axis-lock when iso is on.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `Wave3BCanvasModelWiringTests`). No SwiftUI body / NSMenu / modal is rendered.
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
@Suite("Wire-wave 3 — isometric CanvasModel wiring")
struct WireWave3IsometricWiringTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        // Leave `groupsByEvent` at its default (true): the undoable header-var setters
        // (`isometricMode` / `isoPlane` funnel through `applySetting` →
        // `mutateGraphicVariables` → `registerUndo`) auto-open a top-level group when the
        // manager groups by event, so a single setter call registers cleanly without a
        // manual `beginUndoGrouping`. (The Wave-3B suite sets `groupsByEvent = false` for
        // its multi-step grouped flows; the iso setters are one-shot.)
        m.undoManager.removeAllActions()
        return m
    }

    private func approxEqual(_ a: Double, _ b: Double, tol: Double = 1e-9) -> Bool {
        abs(a - b) <= tol
    }

    // MARK: - isometricMode ↔ $SNAPSTYLE (undoable)

    @Test("isometricMode defaults off and mirrors $SNAPSTYLE")
    func isometricModeDefaultsOff() {
        let m = model()
        #expect(m.isometricMode == false)
        #expect(m.drawing.graphicVariables.snapIsometric == false)
    }

    @Test("setting isometricMode writes $SNAPSTYLE and is undoable")
    func isometricModeUndoable() {
        let m = model()
        let before = m.modelVersion
        m.isometricMode = true
        #expect(m.isometricMode == true)
        #expect(m.drawing.graphicVariables.snapIsometric == true)
        #expect(m.modelVersion != before)        // version bumped → chrome refreshes
        #expect(m.canUndo)                        // one undo step

        m.undo()
        #expect(m.isometricMode == false)         // restored
    }

    @Test("toggleIsometric flips the mode")
    func toggleIsometricFlips() {
        let m = model()
        m.toggleIsometric()
        #expect(m.isometricMode == true)
        m.toggleIsometric()
        #expect(m.isometricMode == false)
    }

    // MARK: - isoPlane ↔ $LC_ISOPLANE (independent of the mode)

    @Test("isoPlane defaults to .top and mirrors $LC_ISOPLANE")
    func isoPlaneDefaultsTop() {
        let m = model()
        #expect(m.isoPlane == .top)
        m.isoPlane = .right
        #expect(m.isoPlane == .right)
        #expect(m.drawing.graphicVariables.isoPlane == .right)
    }

    @Test("isoPlane is independent of isometricMode (remembered while off)")
    func isoPlaneIndependentOfMode() {
        let m = model()
        m.isoPlane = .left           // set while iso OFF
        #expect(m.isometricMode == false)
        #expect(m.isoPlane == .left) // still remembered
        m.isometricMode = true
        #expect(m.isoPlane == .left) // unchanged by turning iso on
    }

    @Test("cycleIsoPlane walks Top → Right → Left → Top (AutoCAD F5 order)")
    func cycleIsoPlaneOrder() {
        let m = model()
        #expect(m.isoPlane == .top)
        m.cycleIsoPlane(); #expect(m.isoPlane == .right)
        m.cycleIsoPlane(); #expect(m.isoPlane == .left)
        m.cycleIsoPlane(); #expect(m.isoPlane == .top)   // wraps
    }

    @Test("cycleIsoPlane works even while iso is off")
    func cycleIsoPlaneWhileOff() {
        let m = model()
        #expect(m.isometricMode == false)
        m.cycleIsoPlane()
        #expect(m.isoPlane == .right)    // records the plane regardless of mode
    }

    // MARK: - isoPlaneIfActive gating (snap / grid / crosshair feed)

    @Test("isoPlaneIfActive is nil when iso is off, the plane when on")
    func isoPlaneIfActiveGating() {
        let m = model()
        m.isoPlane = .right
        #expect(m.isoPlaneIfActive == nil)   // off → rectangular path
        m.isometricMode = true
        #expect(m.isoPlaneIfActive == .right) // on → the active plane
    }

    // MARK: - crosshairAxisAngles (screen-space, NEGATED world angles)

    @Test("crosshairAxisAngles is nil when iso is off")
    func crosshairAxisAnglesNilWhenOff() {
        let m = model()
        #expect(m.crosshairAxisAngles == nil)
    }

    @Test("crosshairAxisAngles negates the plane's world axis angles for screen space")
    func crosshairAxisAnglesNegated() throws {
        let m = model()
        m.isoPlane = .top
        m.isometricMode = true
        let angles = try #require(m.crosshairAxisAngles)
        let (w1, w2) = IsoPlane.top.axisDirections   // world-space directions
        // The screen-space crosshair angle must be the NEGATED world angle (the
        // viewport flips Y), so the cursor tilts WITH the on-screen iso grid.
        #expect(approxEqual(angles.0, -w1.angle))
        #expect(approxEqual(angles.1, -w2.angle))
    }

    @Test("isoPlaneLabel names the active plane")
    func isoPlaneLabelNames() {
        let m = model()
        m.isoPlane = .top;   #expect(m.isoPlaneLabel == "Top")
        m.isoPlane = .left;  #expect(m.isoPlaneLabel == "Left")
        m.isoPlane = .right; #expect(m.isoPlaneLabel == "Right")
    }

    // MARK: - ellipseModeValue index 5 → .isocircle(plane:)

    @Test("ellipseModeValue index 5 maps to isocircle on the active plane")
    func ellipseIndex5IsIsocircle() {
        let m = model()
        m.isoPlane = .right
        m.ellipseModeIndex = 5
        #expect(m.ellipseModeValue == .isocircle(plane: .right))
        #expect(m.ellipseModeValue.isIsocircle)
    }

    @Test("ellipseModeValue isocircle follows the live isoPlane")
    func ellipseIsocircleFollowsPlane() {
        let m = model()
        m.ellipseModeIndex = 5
        m.isoPlane = .top
        #expect(m.ellipseModeValue == .isocircle(plane: .top))
        m.isoPlane = .left
        #expect(m.ellipseModeValue == .isocircle(plane: .left))
    }

    @Test("ellipseModeValue indices 0…4 are unchanged (regression-lock)")
    func ellipseIndicesUnchanged() {
        let m = model()
        m.ellipseModeIndex = 0; #expect(m.ellipseModeValue == .axis)
        m.ellipseModeIndex = 1; #expect(m.ellipseModeValue == .fociPoint)
        m.ellipseModeIndex = 2; #expect(m.ellipseModeValue == .fourPoint)
        m.ellipseModeIndex = 3; #expect(m.ellipseModeValue == .inscribeQuad)
        m.ellipseModeIndex = 4; #expect(m.ellipseModeValue == .arc)
    }

    @Test("activateTool(.ellipse) re-mints the live tool in isocircle mode")
    func activateEllipseIsocircle() throws {
        let m = model()
        m.isoPlane = .left
        m.ellipseModeIndex = 5
        m.activateTool(.ellipse)            // mints + applyToolConfig
        let tool = try #require(m.tool as? EllipseTool)
        #expect(tool.mode == .isocircle(plane: .left))
    }

    // MARK: - iso ortho routing

    @Test("orthoConstrained locks to an iso axis when iso mode is on")
    func orthoIsoAxisLock() {
        let m = model()
        m.isoPlane = .top                   // axes at 30° / 150°
        m.isometricMode = true
        m.orthoEnabled = true
        m.setRelativeZero(Vector(0, 0))     // the datum ortho measures from

        // A candidate near the 30° axis must lock ONTO the 30° axis (y ≈ x·tan30°),
        // not horizontal/vertical (the rectangular lock would zero one component).
        let candidate = Vector(10, 6)       // closest to the 30° axis
        let locked = m.orthoConstrained(candidate, shiftHeld: false)
        let expected = OrthoConstraint.constrain(candidate, relativeTo: .zero, isoPlane: .top)
        #expect(approxEqual(locked.x, expected.x))
        #expect(approxEqual(locked.y, expected.y))
        // It must NOT be the rectangular horizontal/vertical lock.
        #expect(!approxEqual(locked.y, 0))   // not snapped to the horizontal row
    }

    @Test("orthoConstrained uses the rectangular lock when iso mode is off (regression)")
    func orthoRectangularWhenOff() {
        let m = model()
        m.isometricMode = false
        m.orthoEnabled = true
        m.setRelativeZero(Vector(0, 0))
        let candidate = Vector(10, 3)        // |dx| > |dy| → horizontal lock
        let locked = m.orthoConstrained(candidate, shiftHeld: false)
        #expect(approxEqual(locked.x, 10))
        #expect(approxEqual(locked.y, 0))    // horizontal lock zeroes y
    }
}
