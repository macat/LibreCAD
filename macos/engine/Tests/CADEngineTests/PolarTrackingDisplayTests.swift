//
//  PolarTrackingDisplayTests.swift
//  CADEngineTests
//
//  Wave-2 of snap tracking: the `CanvasModel` wiring of the merged
//  `PolarTracking` kernel into a live model — `polarTrackingResult` (refreshed
//  inside `updateSnap`) plus the pure `trackingDisplay()` overlay data. These
//  verify the GATE conditions (mirrors of `polarConstrained`'s gates) and the
//  pre-formatted readout, and confirm the always-on angle LOCK (`polarConstrained`)
//  is UNAFFECTED by the new display path.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `Wave3BCanvasModelWiringTests`). No SwiftUI body / NSView / modal is rendered —
//  only the pure model state + `trackingDisplay()` data are exercised, so the suite
//  is headless-safe.
//
//  The cursor is driven through the REAL `updateSnap(atScreenPoint:gridSpacing:)`
//  path: a desired WORLD cursor is mapped to a screen point via `viewport.worldToScreen`
//  (an exact linear round-trip with `screenToWorld`), so the production refresh hook
//  runs end-to-end rather than poking private state.
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
@Suite("Polar tracking display (W2 — CanvasModel wiring)")
struct PolarTrackingDisplayTests {

    private let viewSize = CGSize(width: 800, height: 600)

    /// A bare model on an empty drawing with a clean (manual-grouping) undo stack.
    private func model(drawing: CADDrawing = CADDrawing()) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: viewSize)
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// Drives the production cursor path so `cursorWorld` lands at (approximately)
    /// `world` and `refreshPolarTracking` runs. `worldToScreen`/`screenToWorld` are an
    /// exact linear inverse pair, so the resulting `cursorWorld` equals `world` (z 0).
    private func moveCursor(_ m: CanvasModel, to world: Vector) {
        let screen = m.viewport.worldToScreen(world)
        m.updateSnap(atScreenPoint: screen, gridSpacing: nil)
    }

    /// A model wired for polar tracking: a draw tool active, polar on, relative-zero
    /// at the origin, 15° increment (the default). Returns the ready model.
    private func polarReadyModel(drawing: CADDrawing = CADDrawing()) -> CanvasModel {
        let m = model(drawing: drawing)
        m.activateTool(.line)            // any draw tool ⇒ isToolActive
        m.polarEnabled = true
        m.setRelativeZero(Vector(0, 0))  // datum the ray radiates from
        return m
    }

    // MARK: - Engaged (positive) case

    @Test("cursor on an increment ray ⇒ polarRay (from == relativeZero) + readout")
    func engagedShowsRayAndReadout() throws {
        let m = polarReadyModel()
        // (10, 0) is exactly on the 0° increment ray ⇒ withinAperture.
        moveCursor(m, to: Vector(10, 0))

        let result = try #require(m.polarTrackingResult, "polar tracking should be engaged")
        #expect(result.withinAperture)

        let display = m.trackingDisplay()
        let ray = try #require(display.polarRay, "engaged + within aperture ⇒ a ray")
        #expect(ray.from == Vector(0, 0))            // near end is the relative-zero
        #expect(ray.to == result.rayFar)             // far end is the kernel's rayFar

        let readout = try #require(display.readout, "engaged ⇒ a formatted readout")
        #expect(!readout.text.isEmpty)
        #expect(readout.text.contains("<"))          // LibreCAD's dist<angle separator
        #expect(readout.anchor == result.snappedPoint)
    }

    // MARK: - Negative gates (each yields no ray / empty display)

    @Test("no relativeZero ⇒ no tracking, empty display")
    func noReferenceIsEmpty() {
        let m = model()
        m.activateTool(.line)
        m.polarEnabled = true
        // No setRelativeZero — there is nothing to radiate from.
        moveCursor(m, to: Vector(10, 0))

        #expect(m.polarTrackingResult == nil)
        #expect(m.trackingDisplay().polarRay == nil)
        #expect(m.trackingDisplay().readout == nil)
    }

    @Test("polar disabled ⇒ no tracking, empty display")
    func polarOffIsEmpty() {
        let m = model()
        m.activateTool(.line)
        m.polarEnabled = false           // the master gate is off
        m.setRelativeZero(Vector(0, 0))
        moveCursor(m, to: Vector(10, 0))

        #expect(m.polarTrackingResult == nil)
        #expect(m.trackingDisplay().polarRay == nil)
    }

    @Test("⇧ held ⇒ polar released, no tracking ray (mirrors polarConstrained)")
    func shiftHeldReleasesTracking() {
        let m = polarReadyModel()
        m.polarTrackingShiftHeld = true  // ⇧ releases polar for the DISPLAY too
        moveCursor(m, to: Vector(10, 0))

        #expect(m.polarTrackingResult == nil)
        #expect(m.trackingDisplay().polarRay == nil)
    }

    @Test("a real osnap under the cursor wins ⇒ no tracking ray")
    func osnapSuppressesTracking() {
        // A line with an endpoint at (10, 0): the cursor snaps to that .endpoint, so
        // osnapActive is true and the ray must yield to the snap marker.
        let drawing = CADDrawing()
        _ = drawing.add(EntityRecord(id: EntityID(1),
                                     kind: .line(LineData(start: Vector(10, 0),
                                                          end: Vector(10, 10)))))
        let m = polarReadyModel(drawing: drawing)
        moveCursor(m, to: Vector(10, 0))

        #expect(m.osnapActive, "cursor on the endpoint should be an object snap")
        #expect(m.polarTrackingResult == nil)
        #expect(m.trackingDisplay().polarRay == nil)
    }

    @Test("cursor far off any ray ⇒ result present but withinAperture false ⇒ no ray")
    func offRayHidesDisplayButKeepsResult() throws {
        let m = polarReadyModel()
        // 7.5° from the origin is exactly halfway between the 0° and 15° rays — well
        // beyond the ~3° aperture — so the kernel reports !withinAperture.
        let theta = 7.5 * Double.pi / 180.0
        moveCursor(m, to: Vector(10 * cos(theta), 10 * sin(theta)))

        let result = try #require(m.polarTrackingResult, "off-ray still produces a result")
        #expect(!result.withinAperture, "7.5° is outside the 3° draw aperture")

        let display = m.trackingDisplay()
        #expect(display.polarRay == nil, "draw-gated off ⇒ no ray drawn")
        #expect(display.readout == nil)
    }

    @Test("cursor left the view ⇒ tracking cleared")
    func clearCursorClearsTracking() {
        let m = polarReadyModel()
        moveCursor(m, to: Vector(10, 0))
        #expect(m.polarTrackingResult != nil)

        m.clearCursor()
        #expect(m.polarTrackingResult == nil)
        #expect(m.trackingDisplay().polarRay == nil)
    }

    // MARK: - The always-on angle LOCK is UNCHANGED by the display path

    @Test("polarConstrained still angle-locks (display path does not touch the lock)")
    func lockUnaffected() {
        let m = polarReadyModel()
        moveCursor(m, to: Vector(10, 0))   // refresh the tracking display

        // A point 5° off the 0° ray must still snap onto the 0° ray, at the same
        // distance — exactly as before this wave (osnap not active here, ⇧ not held).
        let theta = 5.0 * Double.pi / 180.0
        let off = Vector(10 * cos(theta), 10 * sin(theta))
        let locked = m.polarConstrained(off, shiftHeld: false)
        let d = off.distance(to: Vector(0, 0))
        #expect(abs(locked.x - d) < 1e-9, "locked onto the 0° ray at the cursor distance")
        #expect(abs(locked.y - 0) < 1e-9)
    }

    @Test("polarConstrained still releases on ⇧ regardless of the display flag")
    func lockShiftReleaseUnaffected() {
        let m = polarReadyModel()
        let off = Vector(9, 1)
        // ⇧ held ⇒ polarConstrained passes the point through unchanged (its own gate),
        // independent of polarTrackingShiftHeld (the DISPLAY flag).
        #expect(m.polarConstrained(off, shiftHeld: true) == off)
    }
}
