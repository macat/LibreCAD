//
//  AutoCADCursorTests.swift
//  CADEngineTests
//
//  Tests the AutoCAD-style canvas cursor DECISION PREDICATE. While a drawing/edit tool
//  is active the canvas draws its own "spider" crosshair overlay, and the native macOS
//  pointer must be HIDDEN so the user sees ONLY the drawn crosshair (AutoCAD parity).
//
//  The earlier approach (a transparent cursor RECT on the MTKView) did NOT work: the
//  transparent click-through OVERLAY SUBVIEWS stacked on top (crosshair / gizmo /
//  marquee / UCS axis) shadow this view's cursor rect — AppKit resolves the FRONTMOST
//  view's (absent) cursor and shows the default arrow regardless. So the production code
//  now hides the pointer with the layering-independent `NSCursor.hide()`/`unhide()`,
//  gated by the pure `cursorShouldBeHidden(...)` predicate and balanced by a single
//  guarded reconciler on `FlippedMTKView`.
//
//  WHAT THIS SUITE COVERS: the pure predicate's truth table — the part that is testable
//  HEADLESSLY. The predicate lives in `CanvasCursorVisibility.swift` (app module),
//  symlinked into this target as `_SharedCanvasCursorVisibility.swift` (it is tiny +
//  dependency-free, unlike `CADCanvasView.swift`, whose dependency closure is far too
//  large to symlink whole).
//
//  NOT verifiable headlessly (owner's final visual check): the on-screen invisibility is
//  live AppKit chrome driven by `NSCursor.hide()`/`unhide()` against a real window +
//  tracking area, which neither the headless test suite nor LCShot (committed geometry
//  only — no cursor/overlay chrome) can observe.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
@testable import CADEngine

@Suite("AutoCAD cursor — hide-decision predicate truth table")
struct AutoCADCursorTests {

    // The pointer is hidden (so the drawn crosshair is the only cursor) ONLY when all
    // three inputs are true: the pointer is inside the canvas, a tool is active
    // (crosshair visible), and the window is key. Any false → the native pointer shows.

    @Test("hidden only when inside + crosshair-visible + window-key (all three)")
    func allThreeTrueHides() {
        #expect(cursorShouldBeHidden(
            mouseInsideCanvas: true, crosshairVisible: true, windowIsKey: true) == true)
    }

    @Test("pointer OUTSIDE the canvas never hides (sidebar / menu bar / title bar)")
    func outsideShows() {
        #expect(cursorShouldBeHidden(
            mouseInsideCanvas: false, crosshairVisible: true, windowIsKey: true) == false)
    }

    @Test("select mode (no crosshair) never hides — the arrow stays")
    func selectModeShows() {
        #expect(cursorShouldBeHidden(
            mouseInsideCanvas: true, crosshairVisible: false, windowIsKey: true) == false)
    }

    @Test("app/window not key never hides — switching away reveals the pointer")
    func inactiveWindowShows() {
        #expect(cursorShouldBeHidden(
            mouseInsideCanvas: true, crosshairVisible: true, windowIsKey: false) == false)
    }

    /// Exhaustive truth table: hidden iff (inside && crosshair && key). Guards against a
    /// stray `||`, a dropped term, or an inverted input regressing the predicate.
    @Test("full truth table — hidden iff inside AND crosshair AND key")
    func fullTruthTable() {
        for inside in [false, true] {
            for crosshair in [false, true] {
                for key in [false, true] {
                    let expected = inside && crosshair && key
                    #expect(
                        cursorShouldBeHidden(
                            mouseInsideCanvas: inside,
                            crosshairVisible: crosshair,
                            windowIsKey: key) == expected,
                        "inside=\(inside) crosshair=\(crosshair) key=\(key)")
                }
            }
        }
    }
}
