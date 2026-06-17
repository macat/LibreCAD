//
//  UCSPickTests.swift
//  CADEngineTests
//
//  Wave UCS-W3: the USER COORDINATE SYSTEM made USER-SETTABLE (interactive pick) and
//  ortho/polar drafting made RELATIVE to it. Two concerns, both on the live
//  `CanvasModel`:
//
//    1. The interactive UCS-pick state machine (`beginUCSPick` / `ucsPickClick` /
//       `cancelUCSPick` / `isUCSPicking` / `ucsPickReadout`): a lightweight transient
//       gesture (NOT a `Tool`/`ToolKind`) mirroring the `armSetRelativeZero` one-shot
//       style. 1-point → origin only (angle 0); 2-point → origin then +X direction.
//       Cancel leaves `currentUCS` untouched.
//    2. Ortho / polar constraints relative to the UCS (`orthoConstrained` /
//       `polarConstrained`): with `UCS.world` the constrained world point is
//       BYTE-IDENTICAL to the world-axis behavior (regression-lock); with a rotated
//       UCS the lock follows the UCS axes (ortho) and the increments are measured from
//       the UCS +X axis (polar).
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `UCSWiringTests` / `PolarTrackingTests`). No SwiftUI body / NSView / modal is
//  rendered — only model state + the pure constraint wrappers — so the suite is
//  headless-safe (the menu actions route through the responder chain; the pick is model
//  state, testable without a window).
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
@Suite("UCS pick + UCS-relative ortho/polar (UCS-W3)")
struct UCSPickTests {

    private let viewSize = CGSize(width: 800, height: 600)

    /// A bare model on an empty drawing.
    private func model() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: viewSize)
    }

    private func approxEqual(_ a: Vector, _ b: Vector, _ eps: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    // MARK: - Pick state machine: 1-point ("Set UCS Origin")

    @Test("a fresh model is not picking")
    func freshModelNotPicking() {
        let m = model()
        #expect(m.isUCSPicking == false)
        #expect(m.ucsPick == .inactive)
        #expect(m.ucsPickReadout == nil)
    }

    @Test("1-point pick: begin then one click sets origin (angle 0) and resets")
    func onePointPickSetsOrigin() {
        let m = model()
        m.beginUCSPick(twoPoint: false)
        #expect(m.isUCSPicking)
        #expect(m.ucsPick == .awaitingOrigin(twoPoint: false))
        #expect(m.ucsPickReadout == "Specify UCS origin")

        let p = Vector(12, 7)
        let consumed = m.ucsPickClick(p)
        #expect(consumed)
        #expect(approxEqual(m.currentUCS.origin, p))
        #expect(m.currentUCS.angle == 0)
        // Pick resets to inactive after the single click.
        #expect(m.isUCSPicking == false)
        #expect(m.ucsPick == .inactive)
    }

    // MARK: - Pick state machine: 2-point ("Set UCS by 2 Points")

    @Test("2-point pick: origin click then x-axis click sets origin + angle and resets")
    func twoPointPickSetsOriginAndAngle() {
        let m = model()
        m.beginUCSPick(twoPoint: true)
        #expect(m.ucsPick == .awaitingOrigin(twoPoint: true))
        #expect(m.ucsPickReadout == "Specify UCS origin")

        let origin = Vector(5, 5)
        let c1 = m.ucsPickClick(origin)
        #expect(c1)
        // First click captured the origin; now awaiting the X-axis click.
        #expect(m.ucsPick == .awaitingXAxis(origin: origin))
        #expect(m.ucsPickReadout == "Specify point on X-axis")
        #expect(m.isUCSPicking)
        // The origin click did NOT yet install a UCS.
        #expect(m.currentUCS.isWorld)

        // Second click: +X points up-right at 45°.
        let xPoint = Vector(15, 15)   // direction (10,10) → angle 45°
        let c2 = m.ucsPickClick(xPoint)
        #expect(c2)
        #expect(approxEqual(m.currentUCS.origin, origin))
        let expectedAngle = (xPoint - origin).angle
        #expect(abs(m.currentUCS.angle - expectedAngle) < 1e-12)
        #expect(abs(m.currentUCS.angle - .pi / 4) < 1e-12)
        // Pick resets after the second click.
        #expect(m.isUCSPicking == false)
        #expect(m.ucsPick == .inactive)
    }

    @Test("2-point pick: a degenerate coincident x-axis click yields angle 0 (world +X)")
    func twoPointDegenerateXAxis() {
        let m = model()
        m.beginUCSPick(twoPoint: true)
        let origin = Vector(3, 4)
        _ = m.ucsPickClick(origin)
        // Second click coincident with origin → zero direction → angle 0, never invalid.
        _ = m.ucsPickClick(origin)
        #expect(approxEqual(m.currentUCS.origin, origin))
        #expect(m.currentUCS.angle == 0)
        #expect(m.isUCSPicking == false)
    }

    // MARK: - Cancel

    @Test("cancelUCSPick returns to inactive and leaves currentUCS unchanged")
    func cancelLeavesUCSUnchanged() {
        let m = model()
        // Install a non-world UCS first, so we can prove cancel does not touch it.
        let installed = UCS(origin: Vector(20, 1), angle: .pi / 3)
        m.setUCS(installed)
        m.beginUCSPick(twoPoint: true)
        _ = m.ucsPickClick(Vector(0, 0))     // mid-gesture (captured a new origin)
        #expect(m.isUCSPicking)
        let cancelled = m.cancelUCSPick()
        #expect(cancelled)
        #expect(m.isUCSPicking == false)
        #expect(m.ucsPick == .inactive)
        // The active UCS is the one installed before the pick — untouched by the cancel.
        #expect(m.currentUCS == installed)
    }

    @Test("cancelUCSPick is a no-op (returns false) when not picking")
    func cancelNoOpWhenNotPicking() {
        let m = model()
        #expect(m.cancelUCSPick() == false)
        #expect(m.isUCSPicking == false)
    }

    @Test("ucsPickClick is a no-op (returns false) when not picking")
    func clickNoOpWhenNotPicking() {
        let m = model()
        #expect(m.ucsPickClick(Vector(1, 2)) == false)
        #expect(m.currentUCS.isWorld)
    }

    @Test("ucsPickClick ignores an invalid point")
    func clickIgnoresInvalid() {
        let m = model()
        m.beginUCSPick(twoPoint: false)
        #expect(m.ucsPickClick(.invalid) == false)
        // Still awaiting the origin (the invalid click did not advance the machine).
        #expect(m.ucsPick == .awaitingOrigin(twoPoint: false))
    }

    // MARK: - modelVersion bumps (chrome refresh)

    @Test("begin / click / cancel each bump modelVersion")
    func gestureBumpsVersion() {
        let m = model()
        let v0 = m.modelVersion
        m.beginUCSPick(twoPoint: true)
        #expect(m.modelVersion != v0)
        let v1 = m.modelVersion
        _ = m.ucsPickClick(Vector(1, 1))     // origin → awaitingXAxis
        #expect(m.modelVersion != v1)
        let v2 = m.modelVersion
        _ = m.cancelUCSPick()
        #expect(m.modelVersion != v2)
    }

    // MARK: - toolStepReadout shows the pick prompt (status channel)

    @Test("toolStepReadout surfaces the UCS-pick prompt over select / tool state")
    func readoutSurfacesPickPrompt() {
        let m = model()
        // Select mode, not picking → the neutral select prompt.
        #expect(m.toolStepReadout.hasPrefix("Select"))
        m.beginUCSPick(twoPoint: false)
        #expect(m.toolStepReadout == "Specify UCS origin")
        m.beginUCSPick(twoPoint: true)
        _ = m.ucsPickClick(Vector(0, 0))
        #expect(m.toolStepReadout == "Specify point on X-axis")
        _ = m.cancelUCSPick()
        #expect(m.toolStepReadout.hasPrefix("Select"))
    }

    // MARK: - ortho relative to the UCS

    @Test("orthoConstrained under UCS.world is byte-identical to the kernel (regression)")
    func orthoWorldByteIdentical() {
        let m = model()
        m.toggleOrtho()                       // ortho ON
        m.setRelativeZero(Vector(2, 3))
        #expect(m.currentUCS.isWorld)
        // Sweep several candidates; each must EXACTLY equal the pure kernel on the raw
        // world point (no UCS transform should perturb the world-frame result).
        let raws = [Vector(9, 4), Vector(3, 12), Vector(-5, -1), Vector(7, 7), Vector(2.5, 100)]
        for raw in raws {
            let got = m.orthoConstrained(raw, shiftHeld: false)
            let expected = OrthoConstraint.constrain(raw, relativeTo: Vector(2, 3))
            #expect(got == expected)          // byte-identical (==, not approx)
        }
    }

    @Test("orthoConstrained under a 30° UCS locks to the UCS axes through the reference")
    func ortho30DegreeLocksToUCSAxes() {
        let m = model()
        let ucs = UCS(origin: Vector(10, 5), angle: .pi / 6)   // 30°
        m.setUCS(ucs)
        m.toggleOrtho()
        let refWorld = Vector(10, 5)          // UCS origin → UCS (0,0)
        m.setRelativeZero(refWorld)

        // A candidate that, in the UCS frame, is dominantly along +X (so ortho should
        // lock it onto the UCS X axis: its UCS-y becomes the reference's UCS-y = 0).
        let candUCS = Vector(8, 2)            // |Δx| > |Δy| in UCS → horizontal (UCS) lock
        let candWorld = ucs.toWorld(candUCS)
        let outWorld = m.orthoConstrained(candWorld, shiftHeld: false)
        let outUCS = ucs.toUCS(outWorld)
        // Locked onto the UCS X axis through the reference (UCS y == 0), x preserved.
        #expect(abs(outUCS.y - 0) < 1e-9)
        #expect(abs(outUCS.x - candUCS.x) < 1e-9)
        // And the world result is NOT on a world axis through the reference (proves the
        // lock is UCS-relative, not world-relative): world Δy is non-trivial.
        #expect(abs(outWorld.y - refWorld.y) > 1e-6)

        // A candidate dominantly along UCS +Y → locks onto the UCS Y axis (UCS x == 0).
        let candUCS2 = Vector(2, 8)           // |Δy| > |Δx| in UCS → vertical (UCS) lock
        let out2 = ucs.toUCS(m.orthoConstrained(ucs.toWorld(candUCS2), shiftHeld: false))
        #expect(abs(out2.x - 0) < 1e-9)
        #expect(abs(out2.y - candUCS2.y) < 1e-9)
    }

    // MARK: - polar relative to the UCS

    @Test("polarConstrained under UCS.world is byte-identical to the kernel (regression)")
    func polarWorldByteIdentical() {
        let m = model()
        m.togglePolar()                       // polar ON (also clears ortho)
        m.setRelativeZero(Vector(0, 0))
        #expect(m.currentUCS.isWorld)
        let inc = m.polarAngleIncrement
        let raws = [
            Vector(10 * cos(20 * .pi / 180), 10 * sin(20 * .pi / 180)),
            Vector(5, 9),
            Vector(-3, 2),
            Vector(7, -7),
        ]
        for raw in raws {
            let got = m.polarConstrained(raw, shiftHeld: false)
            let expected = PolarConstraint.constrain(raw, relativeTo: Vector(0, 0), incrementRadians: inc)
            #expect(got == expected)          // byte-identical
        }
    }

    @Test("polarConstrained under a 30° UCS measures increments from the UCS X axis")
    func polar30DegreeFromUCSXAxis() {
        let m = model()
        let ucs = UCS(origin: Vector(4, 1), angle: .pi / 6)    // 30°
        m.setUCS(ucs)
        m.togglePolar()
        let refWorld = ucs.toWorld(Vector(0, 0))               // UCS origin
        m.setRelativeZero(refWorld)
        let inc = m.polarAngleIncrement                        // 15°

        // A point at UCS angle 20° (from the UCS +X axis), distance 10. Polar should snap
        // its UCS-frame bearing to the nearest 15° multiple = 15°, preserving distance.
        let dist = 10.0
        let candUCS = Vector(dist * cos(20 * .pi / 180), dist * sin(20 * .pi / 180))
        let candWorld = ucs.toWorld(candUCS)
        let outWorld = m.polarConstrained(candWorld, shiftHeld: false)
        let outUCS = ucs.toUCS(outWorld)

        // Distance from the reference (in UCS, = in world) is preserved.
        #expect(abs(outUCS.distance(to: Vector(0, 0)) - dist) < 1e-9)
        // The UCS-frame bearing is locked to 15° (a multiple of the increment).
        let bearingUCS = atan2(outUCS.y, outUCS.x)
        #expect(abs(bearingUCS - 15 * .pi / 180) < 1e-9)
        // Increments are measured from the UCS X axis, not world: the WORLD bearing is
        // (UCS bearing + UCS angle) = 15° + 30° = 45°, NOT a 15° multiple in world terms
        // would still be coincidence — assert it equals the UCS+frame composition instead.
        let bearingWorld = Vector.correctAngle((outWorld - refWorld).angle)
        #expect(abs(bearingWorld - Vector.correctAngle(15 * .pi / 180 + ucs.angle)) < 1e-9)
        _ = inc
    }
}
