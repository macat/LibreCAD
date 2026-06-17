//
//  UCSWiringTests.swift
//  CADEngineTests
//
//  Wave UCS-W2: the USER COORDINATE SYSTEM (UCS) model foundation wired into the live
//  `CanvasModel`. These verify that the active UCS (`currentUCS`) is honored at the
//  three input/display boundaries this wave touches — WITHOUT changing world-frame
//  behavior at all:
//
//    1. Coordinate READOUTS (`cursorReadout` / `absoluteCursorReadout` via that path /
//       `relativeReadout` / `distanceAngleReadout` / `relativeZeroReadout`): the world
//       point is converted INTO the UCS (`toUCS` / `directionToUCS` / `displayAngle` /
//       `angleBase`) before formatting. With `UCS.world` the output is BYTE-IDENTICAL
//       to formatting the raw world point (regression-locked here).
//    2. Typed command-line COORDINATES (`interpretCommandLine`): a typed `x,y` / `@dx,dy`
//       / `dist<angle` is parsed in UCS space (reference + cursor converted in) and the
//       result converted back to WORLD before the tool consumes it.
//    3. `setUCS` / `resetUCS` state + `currentUCS.isWorld`.
//
//  Plus the folded-in OTRACK-pref fix: `objectTrackingEnabled` is SEEDED from
//  `AppSettings.Key.objectTracking` and `toggleObjectTracking()` WRITES it back.
//
//  `CanvasModel` + `AppSettings` live in the (un-importable) app target — reached here
//  via the existing `_SharedCanvasModel.swift` / `_SharedAppSettings.swift` symlinks
//  (the suite is `@MainActor`, mirroring `OtrackModelTests`). No SwiftUI body / NSView /
//  modal is rendered — only pure model state + derived readouts — so the suite is
//  headless-safe.
//
//  The cursor is driven through the REAL `updateSnap(atScreenPoint:gridSpacing:)` path:
//  a desired WORLD cursor is mapped to a screen point via `viewport.worldToScreen` (an
//  exact linear inverse of `screenToWorld`), so `cursorWorld` lands exactly on the test
//  coordinate. The default viewport is scale 1.0.
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
@Suite("UCS wiring (W2 — CanvasModel readouts + typed coords + axis anchor)")
struct UCSWiringTests {

    private let viewSize = CGSize(width: 800, height: 600)
    private let eps = 1e-9

    /// A bare model on an empty drawing with a clean (manual-grouping) undo stack.
    private func model(drawing: CADDrawing = CADDrawing()) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: viewSize)
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// Drives the production cursor path so `cursorWorld` lands exactly on `world`.
    private func moveCursor(_ m: CanvasModel, to world: Vector) {
        let screen = m.viewport.worldToScreen(world)
        _ = m.updateSnap(atScreenPoint: screen, gridSpacing: nil)
    }

    private func approxEqual(_ a: Vector, _ b: Vector) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.z - b.z) < 1e-6
    }

    // MARK: - State: setUCS / resetUCS / isWorld

    @Test("a fresh model is in the world frame")
    func freshModelIsWorld() {
        let m = model()
        #expect(m.currentUCS == .world)
        #expect(m.currentUCS.isWorld)
    }

    @Test("setUCS installs the frame; resetUCS restores world")
    func setAndResetUCS() {
        let m = model()
        let ucs = UCS(origin: Vector(10, 5), angle: .pi / 2)
        m.setUCS(ucs)
        #expect(m.currentUCS == ucs)
        #expect(!m.currentUCS.isWorld)
        m.resetUCS()
        #expect(m.currentUCS == .world)
        #expect(m.currentUCS.isWorld)
    }

    @Test("setUCS / resetUCS bump modelVersion (chrome refresh)")
    func mutatorsBumpVersion() {
        let m = model()
        let v0 = m.modelVersion
        m.setUCS(UCS(origin: Vector(3, 4), angle: 0.5))
        #expect(m.modelVersion != v0)
        let v1 = m.modelVersion
        m.resetUCS()
        #expect(m.modelVersion != v1)
    }

    // MARK: - Readouts: WORLD frame is byte-identical (regression lock)

    @Test("absolute cursorReadout is byte-identical to raw-world formatting under UCS.world")
    func absoluteReadoutWorldIdentical() {
        let m = model()
        let w = Vector(12.5, 8)
        moveCursor(m, to: w)
        let gv = m.drawing.graphicVariables
        let expected = CoordinateFormatter.coordinatePair(
            x: w.x, y: w.y,
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        #expect(m.currentUCS.isWorld)
        #expect(m.cursorReadout == expected)
    }

    @Test("relative cursorReadout is byte-identical to raw-world deltas under UCS.world")
    func relativeReadoutWorldIdentical() {
        let m = model()
        m.setRelativeZero(Vector(2, 3))
        moveCursor(m, to: Vector(12, 8))
        m.coordinateDisplayMode = .relative
        let gv = m.drawing.graphicVariables
        let dx = CoordinateFormatter.length(10, format: gv.linearFormat, precision: gv.linearPrecision)
        let dy = CoordinateFormatter.length(5, format: gv.linearFormat, precision: gv.linearPrecision)
        #expect(m.cursorReadout == "@\(dx), \(dy)")
        // The standalone relativeReadout property matches too.
        #expect(m.relativeReadout == "@\(dx), \(dy)")
    }

    @Test("polar cursorReadout is byte-identical to raw-world polar under UCS.world")
    func polarReadoutWorldIdentical() {
        let m = model()
        m.setRelativeZero(Vector(0, 0))
        moveCursor(m, to: Vector(3, 4))
        m.coordinateDisplayMode = .polar
        let gv = m.drawing.graphicVariables
        let expected = CoordinateFormatter.polarPair(
            dx: 3, dy: 4,
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit,
            angleFormat: gv.angleFormat, anglePrecision: gv.anglePrecision)
        #expect(m.cursorReadout == expected)
    }

    @Test("distanceAngleReadout is byte-identical under UCS.world")
    func distanceAngleReadoutWorldIdentical() {
        let m = model()
        m.setRelativeZero(Vector(0, 0))
        moveCursor(m, to: Vector(10, 10))
        let gv = m.drawing.graphicVariables
        let distStr = CoordinateFormatter.length(
            (10.0 * 10 + 10 * 10).squareRoot(),
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        let degStr = String(format: "%.0f", 45.0)
        #expect(m.distanceAngleReadout == "\u{27C2} \(distStr)   \u{2220} \(degStr)\u{00B0}")
    }

    @Test("relativeZeroReadout is byte-identical under UCS.world")
    func relativeZeroReadoutWorldIdentical() {
        let m = model()
        m.setRelativeZero(Vector(7, 9))
        let gv = m.drawing.graphicVariables
        let pos = CoordinateFormatter.coordinatePair(
            x: 7, y: 9, format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        #expect(m.relativeZeroReadout == "RelZero: \(pos)")
    }

    // MARK: - Readouts: TRANSLATED UCS (origin (10,5))

    @Test("translated UCS: cursor at world (12,5) reads UCS (2,0)")
    func translatedAbsoluteReadout() {
        let m = model()
        m.setUCS(UCS(origin: Vector(10, 5), angle: 0))
        moveCursor(m, to: Vector(12, 5))
        let gv = m.drawing.graphicVariables
        let expected = CoordinateFormatter.coordinatePair(
            x: 2, y: 0, format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        #expect(m.cursorReadout == expected)
    }

    @Test("translated UCS: relativeZeroReadout shows the datum in UCS coords")
    func translatedRelativeZeroReadout() {
        let m = model()
        m.setUCS(UCS(origin: Vector(10, 5), angle: 0))
        m.setRelativeZero(Vector(13, 9))   // world; UCS = (3, 4)
        let gv = m.drawing.graphicVariables
        let pos = CoordinateFormatter.coordinatePair(
            x: 3, y: 4, format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        #expect(m.relativeZeroReadout == "RelZero: \(pos)")
    }

    // MARK: - Readouts: ROTATED UCS (90°) — displayAngle subtracts the UCS angle

    @Test("rotated 90° UCS: a world +X bearing reads as -90° (UCS frame)")
    func rotatedDistanceAngleReadout() {
        let m = model()
        m.setUCS(UCS(origin: .zero, angle: .pi / 2))
        m.setRelativeZero(Vector(0, 0))
        moveCursor(m, to: Vector(10, 0))   // world bearing 0°; UCS bearing -90° → 270°
        let gv = m.drawing.graphicVariables
        let dist = CoordinateFormatter.length(
            10, format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        // displayAngle(0) = -π/2, correctAngle → 3π/2 → 270°.
        #expect(m.distanceAngleReadout == "\u{27C2} \(dist)   \u{2220} 270\u{00B0}")
    }

    @Test("rotated 90° UCS: relative cursorReadout rotates the delta into the frame")
    func rotatedRelativeReadout() {
        let m = model()
        m.setUCS(UCS(origin: .zero, angle: .pi / 2))
        m.setRelativeZero(Vector(0, 0))
        moveCursor(m, to: Vector(1, 0))    // world delta (1,0); UCS delta = (0,-1)
        m.coordinateDisplayMode = .relative
        let gv = m.drawing.graphicVariables
        let dx = CoordinateFormatter.length(0, format: gv.linearFormat, precision: gv.linearPrecision)
        let dy = CoordinateFormatter.length(-1, format: gv.linearFormat, precision: gv.linearPrecision)
        #expect(m.cursorReadout == "@\(dx), \(dy)")
    }

    // MARK: - Typed command-line coordinates

    @Test("world UCS: typed absolute x,y lands at the raw world point (regression)")
    func typedAbsoluteWorld() {
        let m = model()
        m.activateTool(.line)
        let r = m.interpretCommandLine("12,5")
        #expect(r == .handled)
        // The placed point becomes the relative-zero (handleToolInput records it).
        #expect(m.relativeZero.map { approxEqual($0, Vector(12, 5)) } == true)
    }

    @Test("translated UCS: typing 2,0 lands at world (12,5)")
    func typedAbsoluteTranslated() {
        let m = model()
        m.setUCS(UCS(origin: Vector(10, 5), angle: 0))
        m.activateTool(.line)
        let r = m.interpretCommandLine("2,0")
        #expect(r == .handled)
        #expect(m.relativeZero.map { approxEqual($0, Vector(12, 5)) } == true)
    }

    @Test("rotated 90° UCS: typed @1,0 lands rotated into world (0,1)")
    func typedRelativeRotated() {
        let m = model()
        m.setUCS(UCS(origin: .zero, angle: .pi / 2))
        m.activateTool(.line)
        // First point: UCS (0,0) → world (0,0).
        _ = m.interpretCommandLine("0,0")
        #expect(m.relativeZero.map { approxEqual($0, Vector(0, 0)) } == true)
        // Relative @1,0 in UCS space = +1 along UCS +X = world (0,1) after toWorld.
        let r = m.interpretCommandLine("@1,0")
        #expect(r == .handled)
        #expect(m.relativeZero.map { approxEqual($0, Vector(0, 1)) } == true)
    }

    @Test("rotated 90° UCS: polar 1<0 lands along the UCS +X axis → world (0,1)")
    func typedPolarRotated() {
        let m = model()
        m.setUCS(UCS(origin: .zero, angle: .pi / 2))
        m.activateTool(.line)
        _ = m.interpretCommandLine("0,0")
        // Polar 1<0 in UCS = distance 1 at UCS angle 0 = world (0,1).
        let r = m.interpretCommandLine("1<0")
        #expect(r == .handled)
        #expect(m.relativeZero.map { approxEqual($0, Vector(0, 1)) } == true)
    }

    @Test("world UCS: typed @dx,dy is byte-for-byte the same world result as before")
    func typedRelativeWorldUnchanged() {
        let m = model()
        m.activateTool(.line)
        _ = m.interpretCommandLine("5,5")
        let r = m.interpretCommandLine("@10,0")
        #expect(r == .handled)
        #expect(m.relativeZero.map { approxEqual($0, Vector(15, 5)) } == true)
    }

    // MARK: - OTRACK preference fix (folded-in code-review SHOULD-FIX)

    @Test("objectTrackingEnabled seeds from the AppSettings preference")
    func otrackSeedsFromPreference() {
        let key = AppSettings.Key.objectTracking
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        AppSettings.setBoolPreference(key, true)
        let onModel = model()
        #expect(onModel.objectTrackingEnabled == true)

        AppSettings.setBoolPreference(key, false)
        let offModel = model()
        #expect(offModel.objectTrackingEnabled == false)
    }

    @Test("toggleObjectTracking writes the new value back to the preference")
    func otrackToggleWritesBack() {
        let key = AppSettings.Key.objectTracking
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        AppSettings.setBoolPreference(key, false)
        let m = model()
        #expect(m.objectTrackingEnabled == false)

        m.toggleObjectTracking()
        #expect(m.objectTrackingEnabled == true)
        #expect(AppSettings.boolPreference(key, default: false) == true)

        m.toggleObjectTracking()
        #expect(m.objectTrackingEnabled == false)
        #expect(AppSettings.boolPreference(key, default: true) == false)
    }
}
