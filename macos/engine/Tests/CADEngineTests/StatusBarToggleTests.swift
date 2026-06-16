//
//  StatusBarToggleTests.swift
//  CADEngineTests
//
//  Wave 4 (bottom chrome) — the StatusBar's clickable GRID / SNAP / ORTHO toggle
//  cluster. SwiftUI view metrics aren't headless-testable, so these pin the MODEL
//  BEHAVIOR the cluster drives: each toggle flips exactly the existing state flag the
//  status chip reads, and the read-back (`gridVisible` / `gridSnapEnabled` /
//  `orthoEnabled`) reflects the flip. The toggles SURFACE existing state — they must
//  not introduce new snap geometry — so the SNAP toggle is the `.grid` snap-mode bit
//  and round-trips through the same `snapModes` set the Inspector edits.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink. The suite is `@MainActor` (mirrors the
//  other CanvasModel suites). Uniquely namespaced so it does not collide with the
//  other suites in the shared test target.
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
@Suite("status bar mode toggles (GRID / SNAP / ORTHO surface existing state)")
struct StatusBarToggleTests {

    private func makeModel() -> CanvasModel {
        // The model ships with its own UndoManager; `setSnapMode` registers against it.
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    // MARK: - GRID (F7) ↔ gridVisible

    @Test("toggleGrid flips gridVisible and the status chip read-back reflects it")
    func gridToggleFlipsFlag() {
        let m = makeModel()
        let before = m.gridVisible
        m.toggleGrid()
        #expect(m.gridVisible == !before)
        m.toggleGrid()
        #expect(m.gridVisible == before)
    }

    // MARK: - ORTHO (F8) ↔ orthoEnabled

    @Test("toggleOrtho flips orthoEnabled and the status chip read-back reflects it")
    func orthoToggleFlipsFlag() {
        let m = makeModel()
        #expect(m.orthoEnabled == false)        // default off
        m.toggleOrtho()
        #expect(m.orthoEnabled == true)
        m.toggleOrtho()
        #expect(m.orthoEnabled == false)
    }

    // MARK: - SNAP (F9) ↔ grid-snap bit of snapModes

    @Test("gridSnapEnabled mirrors the .grid bit of snapModes")
    func gridSnapEnabledMirrorsTheBit() {
        let m = makeModel()
        // The interactive default deliberately omits `.grid`.
        #expect(m.gridSnapEnabled == false)
        #expect(m.snapModes.contains(.grid) == false)
    }

    @Test("toggleGridSnap flips the .grid bit (and only it), round-tripping")
    func gridSnapToggleFlipsOnlyTheGridBit() {
        let m = makeModel()
        let othersBefore = m.snapModes.subtracting(.grid)

        m.toggleGridSnap()
        #expect(m.gridSnapEnabled == true)
        #expect(m.snapModes.contains(.grid))
        // The other snap modes are untouched — the toggle surfaces ONLY grid snap.
        #expect(m.snapModes.subtracting(.grid) == othersBefore)

        m.toggleGridSnap()
        #expect(m.gridSnapEnabled == false)
        #expect(m.snapModes.contains(.grid) == false)
        #expect(m.snapModes.subtracting(.grid) == othersBefore)
    }

    @Test("toggleGridSnap agrees with the Inspector's setSnapMode path")
    func gridSnapMatchesInspectorPath() {
        let a = makeModel()
        let b = makeModel()
        // The status toggle and the Inspector toggle drive the SAME bit.
        a.toggleGridSnap()
        b.setSnapMode(.grid, true)
        #expect(a.gridSnapEnabled == b.gridSnapEnabled)
        #expect(a.snapModes == b.snapModes)
    }

    // MARK: - The three toggles are independent

    @Test("the three mode toggles are independent (one does not disturb the others)")
    func togglesAreIndependent() {
        let m = makeModel()
        let grid0 = m.gridVisible
        let ortho0 = m.orthoEnabled
        let snap0 = m.gridSnapEnabled

        m.toggleGrid()
        #expect(m.orthoEnabled == ortho0)
        #expect(m.gridSnapEnabled == snap0)

        m.toggleOrtho()
        #expect(m.gridVisible == !grid0)
        #expect(m.gridSnapEnabled == snap0)

        m.toggleGridSnap()
        #expect(m.gridVisible == !grid0)
        #expect(m.orthoEnabled == !ortho0)
    }
}

// MARK: - Coordinate display mode cycle (backlog #5)

/// `cycleCoordinateDisplayMode` advances `coordinateDisplayMode` through
/// absolute → relative → polar → absolute, and the live `cursorReadout` changes
/// format per mode. These pin the MODEL behavior the (later) status-bar coord
/// button + cycle command drive — the readout switches without regressing the
/// absolute case. Reached via the `_SharedCanvasModel` symlink; `@MainActor`.
@MainActor
@Suite("coordinate display mode cycle (#5) — mode advances + readout reformats")
struct CoordinateDisplayModeCycleTests {

    private func makeModel() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    @Test("cycle advances absolute → relative → polar → absolute")
    func cycleAdvancesThroughTheLoop() {
        let m = makeModel()
        #expect(m.coordinateDisplayMode == .absolute)   // default
        m.cycleCoordinateDisplayMode()
        #expect(m.coordinateDisplayMode == .relative)
        m.cycleCoordinateDisplayMode()
        #expect(m.coordinateDisplayMode == .polar)
        m.cycleCoordinateDisplayMode()
        #expect(m.coordinateDisplayMode == .absolute)   // wrapped
    }

    @Test("cursorReadout is nil when the cursor is outside the canvas")
    func readoutNilOutsideCanvas() {
        let m = makeModel()
        m.cursorWorld = nil
        #expect(m.cursorReadout == nil)
    }

    @Test("each mode produces a DISTINCT readout format with a reference set")
    func readoutFormatChangesPerMode() {
        let m = makeModel()
        // A reference (last placed point) + a cursor offset from it, so relative/polar
        // have something to measure (and differ from absolute).
        m.setRelativeZero(Vector(2, 1))
        m.cursorWorld = Vector(5, 5)             // Δ = (3, 4) ⇒ dist 5, angle 53.13°

        // Absolute: the X/Y world-point readout (unchanged behavior).
        m.coordinateDisplayMode = .absolute
        let abs = m.cursorReadout
        #expect(abs?.contains("X") == true)
        #expect(abs?.contains("<") == false)    // not polar

        // Relative: the "@Δx, Δy" offset form.
        m.coordinateDisplayMode = .relative
        let rel = m.cursorReadout
        #expect(rel?.hasPrefix("@") == true)
        #expect(rel?.contains("3") == true)     // Δx == 3
        #expect(rel?.contains("4") == true)     // Δy == 4

        // Polar: the "dist<angle" form.
        m.coordinateDisplayMode = .polar
        let pol = m.cursorReadout
        #expect(pol?.contains("<") == true)     // polar separator
        #expect(pol?.hasPrefix("5") == true)    // distance == 5

        // The three are genuinely different strings.
        #expect(abs != rel)
        #expect(rel != pol)
        #expect(abs != pol)
    }

    @Test("relative/polar fall back to the absolute readout with no reference")
    func relativeAndPolarFallBackToAbsoluteWithNoReference() {
        let m = makeModel()
        m.cursorWorld = Vector(5, 5)            // no relativeZero set ⇒ no reference

        m.coordinateDisplayMode = .absolute
        let abs = m.cursorReadout

        m.coordinateDisplayMode = .relative
        #expect(m.cursorReadout == abs)        // falls back, never blank

        m.coordinateDisplayMode = .polar
        #expect(m.cursorReadout == abs)        // falls back, never blank
    }

    @Test("absolute mode is identical to the prior (unchanged) readout")
    func absoluteReadoutUnchanged() {
        let m = makeModel()
        m.cursorWorld = Vector(12.5, 8)
        m.coordinateDisplayMode = .absolute
        let gv = m.drawing.graphicVariables
        let expected = CoordinateFormatter.coordinatePair(
            x: 12.5, y: 8,
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        #expect(m.cursorReadout == expected)
    }
}

// MARK: - Polar tracking + ortho/polar mutual exclusivity (backlog #7)

/// `togglePolar` flips `polarEnabled` AND clears `orthoEnabled` (and the mirror —
/// `toggleOrtho` turning ortho on clears polar), so the canvas only ever applies one
/// angular constraint. `polarConstrained` angle-locks a candidate point onto the
/// nearest 15° multiple from the relative-zero. All UNWIRED (no canvas call site).
@MainActor
@Suite("polar tracking (#7) — toggle, ortho/polar exclusivity, constraint")
struct PolarTrackingTests {

    private func makeModel() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    @Test("togglePolar flips polarEnabled and round-trips")
    func togglePolarFlipsFlag() {
        let m = makeModel()
        #expect(m.polarEnabled == false)       // default off
        m.togglePolar()
        #expect(m.polarEnabled == true)
        m.togglePolar()
        #expect(m.polarEnabled == false)
    }

    @Test("togglePolar ON clears orthoEnabled (mutually exclusive)")
    func polarOnClearsOrtho() {
        let m = makeModel()
        m.toggleOrtho()                        // ortho ON
        #expect(m.orthoEnabled == true)
        m.togglePolar()                        // polar ON ⇒ ortho OFF
        #expect(m.polarEnabled == true)
        #expect(m.orthoEnabled == false)
    }

    @Test("toggleOrtho ON clears polarEnabled (the mirror — mutually exclusive)")
    func orthoOnClearsPolar() {
        let m = makeModel()
        m.togglePolar()                        // polar ON
        #expect(m.polarEnabled == true)
        m.toggleOrtho()                        // ortho ON ⇒ polar OFF
        #expect(m.orthoEnabled == true)
        #expect(m.polarEnabled == false)
    }

    @Test("the default polar increment is 15° (π/12)")
    func defaultIncrementIs15Degrees() {
        let m = makeModel()
        #expect(abs(m.polarAngleIncrement - .pi / 12) < 1e-12)
    }

    @Test("polarConstrained is a no-op when polar is off")
    func polarConstrainedNoOpWhenOff() {
        let m = makeModel()
        m.setRelativeZero(Vector(0, 0))
        let p = Vector(3, 1)
        #expect(m.polarConstrained(p, shiftHeld: false) == p)
    }

    @Test("polarConstrained is a no-op with no reference point")
    func polarConstrainedNoOpWithoutReference() {
        let m = makeModel()
        m.togglePolar()                        // polar ON but no relativeZero
        let p = Vector(3, 1)
        #expect(m.polarConstrained(p, shiftHeld: false) == p)
    }

    @Test("polarConstrained locks the point onto the nearest 15° ray, preserving distance")
    func polarConstrainedSnapsAngle() {
        let m = makeModel()
        m.togglePolar()
        m.setRelativeZero(Vector(0, 0))
        // A point near 20° at distance 10 snaps to the 15° ray (nearest multiple of 15).
        let dist = 10.0
        let raw = Vector(dist * cos(20 * .pi / 180), dist * sin(20 * .pi / 180))
        let out = m.polarConstrained(raw, shiftHeld: false)
        // Distance from the reference is preserved.
        #expect(abs(out.distance(to: Vector(0, 0)) - dist) < 1e-9)
        // The angle is locked to 15°.
        let snappedAngle = atan2(out.y, out.x)
        #expect(abs(snappedAngle - 15 * .pi / 180) < 1e-9)
    }

    @Test("hold-⇧ flips polar on-the-fly (XOR), matching ortho")
    func shiftFlipsPolarOnTheFly() {
        let m = makeModel()
        m.setRelativeZero(Vector(0, 0))
        let raw = Vector(10 * cos(20 * .pi / 180), 10 * sin(20 * .pi / 180))
        // Polar OFF + ⇧ held ⇒ constraint APPLIES (XOR). It should move the point.
        #expect(m.polarEnabled == false)
        #expect(m.polarConstrained(raw, shiftHeld: true) != raw)
        // Polar ON + ⇧ held ⇒ constraint SUPPRESSED. Point passes through.
        m.togglePolar()
        #expect(m.polarConstrained(raw, shiftHeld: true) == raw)
    }
}

// MARK: - Layout tab wrappers + active-tab fixup (backlog #4c)

/// The `CanvasModel` layout-tab wrappers (`duplicateLayout` / `renameLayout` /
/// `deleteLayout` / `setLayoutPage`) call the undoable engine ops AND keep the active
/// tab pointer valid — duplicate creates + activates the copy; rename re-homes the
/// active tab; delete falls back to model space when the active sheet is removed;
/// setLayoutPage applies the new page. All UNWIRED (the tab context menu calls these
/// in a later wire-wave).
@MainActor
@Suite("layout tab wrappers (#4c) — engine op + active-tab fixup")
struct LayoutTabWrapperTests {

    private func makeModel() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    @Test("duplicateLayout creates a new layout via the model and activates it")
    func duplicateCreatesAndActivates() {
        let m = makeModel()
        let base = m.newLayout()               // creates + activates "Layout1"
        #expect(base == "Layout1")
        let before = m.drawing.layouts.count

        let dup = m.duplicateLayout("Layout1")
        #expect(dup == "Layout1 (2)")
        #expect(m.drawing.layouts.count == before + 1)
        #expect(m.drawing.hasLayout("Layout1 (2)"))
        // Active tab lands on the freshly created copy.
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == "Layout1 (2)")
    }

    @Test("duplicateLayout returns nil for an absent layout (no fixup)")
    func duplicateAbsentIsNil() {
        let m = makeModel()
        #expect(m.duplicateLayout("Nope") == nil)
    }

    @Test("renameLayout re-homes the active tab onto the new name")
    func renameRehomesActiveTab() {
        let m = makeModel()
        _ = m.newLayout()                      // "Layout1", now active
        #expect(m.activeLayout == "Layout1")

        let ok = m.renameLayout("Layout1", to: "Plan")
        #expect(ok == true)
        #expect(m.drawing.hasLayout("Plan"))
        #expect(m.drawing.hasLayout("Layout1") == false)
        // The active tab follows the rename — it still shows the same sheet.
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == "Plan")
    }

    @Test("renameLayout leaves a valid (non-dangling) active space")
    func renameLeavesValidActiveSpace() {
        let m = makeModel()
        _ = m.newLayout()
        _ = m.renameLayout("Layout1", to: "Sheet A")
        // Whatever the active layout is, it must resolve in the drawing (no dangle).
        if let active = m.activeLayout {
            #expect(m.drawing.hasLayout(active))
        }
    }

    @Test("deleteLayout removes the layout and falls back to model space when active")
    func deleteFallsBackToModelWhenActive() {
        let m = makeModel()
        _ = m.newLayout()                      // "Layout1", active
        #expect(m.activeSpace == .paper)

        let ok = m.deleteLayout("Layout1")
        #expect(ok == true)
        #expect(m.drawing.hasLayout("Layout1") == false)
        // Active sheet is gone ⇒ fall back to model space (no dangling layout).
        #expect(m.activeSpace == .model)
        #expect(m.activeLayout == nil)
    }

    @Test("deleteLayout of a NON-active layout keeps the active tab")
    func deleteNonActiveKeepsActiveTab() {
        let m = makeModel()
        _ = m.newLayout()                      // "Layout1"
        let second = m.newLayout()             // "Layout2", now active
        #expect(second == "Layout2")
        #expect(m.activeLayout == "Layout2")

        let ok = m.deleteLayout("Layout1")     // delete the inactive one
        #expect(ok == true)
        #expect(m.drawing.hasLayout("Layout1") == false)
        // The active tab is untouched and still valid.
        #expect(m.activeSpace == .paper)
        #expect(m.activeLayout == "Layout2")
    }

    @Test("setLayoutPage applies the new page descriptor")
    func setLayoutPageApplies() {
        let m = makeModel()
        _ = m.newLayout()                      // "Layout1" with the default A4 page
        let landscape = PageDescriptor(widthMM: 420, heightMM: 297, marginMM: 10)

        let ok = m.setLayoutPage("Layout1", landscape)
        #expect(ok == true)
        #expect(m.drawing.layout(named: "Layout1")?.page == landscape)
    }

    @Test("setLayoutPage is a no-op (false) when the page is unchanged")
    func setLayoutPageNoOpWhenUnchanged() {
        let m = makeModel()
        _ = m.newLayout()
        let current = m.drawing.layout(named: "Layout1")!.page
        #expect(m.setLayoutPage("Layout1", current) == false)
    }
}
