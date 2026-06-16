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
