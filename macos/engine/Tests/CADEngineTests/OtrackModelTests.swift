//
//  OtrackModelTests.swift
//  CADEngineTests
//
//  Wave-5 of snap tracking: the `CanvasModel` OBJECT-SNAP-TRACKING (OTRACK) model
//  layer — acquisition (`acquireTrackingPoint` / `clearTrackingPoints`), the live
//  guide solve refreshed inside `updateSnap` (`trackingResult`), the constraint
//  (`trackingConstrained`), the `trackingDisplay()` OTRACK fields, and the reset
//  hooks that drop acquisitions on tool-change / run-end / cursor-leave. These verify
//  the model-side wiring of the merged `Tracking` kernel into a live model; the dwell
//  trigger, the guide rendering, and the toggle key are LATER waves (W6/W7) and are
//  NOT exercised here.
//
//  `CanvasModel` lives in the (un-importable) app target — reached here via the
//  existing `_SharedCanvasModel.swift` symlink (the suite is `@MainActor`, mirroring
//  `PolarTrackingDisplayTests`). No SwiftUI body / NSView / modal is rendered — only
//  the pure model state + `trackingDisplay()` data are exercised, so the suite is
//  headless-safe.
//
//  The cursor is driven through the REAL `updateSnap(atScreenPoint:gridSpacing:)`
//  path: a desired WORLD cursor is mapped to a screen point via `viewport.worldToScreen`
//  (an exact linear inverse of `screenToWorld`), so the production refresh hook
//  (`refreshObjectTracking`) runs end-to-end rather than poking private state. The
//  default viewport is scale 1.0 ⇒ `worldPerPixel == 1` and `worldTolerance == 8` world
//  units (catchPoints 8), so the test coordinates below are chosen relative to that 8u
//  aperture.
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
@Suite("OTRACK model (W5 — CanvasModel wiring)")
struct OtrackModelTests {

    private let viewSize = CGSize(width: 800, height: 600)

    /// A bare model on an empty drawing with a clean (manual-grouping) undo stack.
    private func model(drawing: CADDrawing = CADDrawing()) -> CanvasModel {
        let m = CanvasModel(drawing: drawing, viewSize: viewSize)
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    /// A model with OTRACK on and polar GUIDES disabled (`polarAngleIncrement == 0` ⇒
    /// `Tracking.guides` emits ONLY horizontal + vertical rays). The geometry-lock /
    /// display tests use this so the dense 15°-default polar fan does not add extra
    /// guides near the cursor — they assert the pure H/V (single-guide / intersection)
    /// behavior. The polar-coexistence tests deliberately keep the default increment.
    private func otrackModel(drawing: CADDrawing = CADDrawing()) -> CanvasModel {
        let m = model(drawing: drawing)
        m.objectTrackingEnabled = true
        m.polarAngleIncrement = 0   // H + V guides only — no polar fan
        return m
    }

    /// Drives the production cursor path so `cursorWorld` lands at (approximately)
    /// `world` and `refreshObjectTracking` runs. `worldToScreen`/`screenToWorld` are an
    /// exact linear inverse pair, so the resulting `cursorWorld` equals `world` (z 0).
    private func moveCursor(_ m: CanvasModel, to world: Vector) {
        let screen = m.viewport.worldToScreen(world)
        m.updateSnap(atScreenPoint: screen, gridSpacing: nil)
    }

    /// A real geometry `SnapResult` (an acquirable osnap) at `p`.
    private func osnap(_ p: Vector, _ kind: SnapKind = .endpoint, entity: EntityID? = nil) -> SnapResult {
        SnapResult(point: p, kind: kind, entity: entity)
    }

    // MARK: - Acquisition: append / toggle-off / cap / ignore non-geometry

    @Test("acquireTrackingPoint appends real osnaps")
    func acquireAppendsRealOsnaps() {
        let m = model()
        m.objectTrackingEnabled = true
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        m.acquireTrackingPoint(osnap(Vector(10, 0), .center))
        #expect(m.acquiredPoints.count == 2)
        #expect(m.acquiredPoints[0].point == Vector(0, 0))
        #expect(m.acquiredPoints[0].kind == .endpoint)
        #expect(m.acquiredPoints[1].point == Vector(10, 0))
        #expect(m.acquiredPoints[1].kind == .center)
    }

    @Test("acquiring an already-acquired point toggles it OFF (AutoCAD behavior)")
    func acquireDuplicateToggblesOff() {
        let m = model()
        m.objectTrackingEnabled = true
        m.acquireTrackingPoint(osnap(Vector(5, 5), .endpoint))
        m.acquireTrackingPoint(osnap(Vector(20, 0), .endpoint))
        #expect(m.acquiredPoints.count == 2)
        // Re-acquire the first (exactly equal) ⇒ removed.
        m.acquireTrackingPoint(osnap(Vector(5, 5), .endpoint))
        #expect(m.acquiredPoints.count == 1)
        #expect(m.acquiredPoints[0].point == Vector(20, 0))
        // A point within the snap aperture (≈ equal, < 8u) of an acquired one also toggles.
        m.acquireTrackingPoint(osnap(Vector(20.001, 0), .endpoint))
        #expect(m.acquiredPoints.isEmpty)
    }

    @Test("acquireTrackingPoint caps at maxAcquiredPoints, dropping the OLDEST (FIFO)")
    func acquireCapsDroppingOldest() {
        let m = model()
        m.objectTrackingEnabled = true
        // Acquire 8 DISTINCT points (cap is 7) — points 10u apart so none are "≈ equal".
        for i in 0..<8 {
            m.acquireTrackingPoint(osnap(Vector(Double(i) * 10, 0), .endpoint))
        }
        #expect(CanvasModel.maxAcquiredPoints == 7)
        #expect(m.acquiredPoints.count == 7)
        // The oldest (i == 0, x == 0) was dropped; the list is points 1...7.
        #expect(m.acquiredPoints.first?.point == Vector(10, 0))
        #expect(m.acquiredPoints.last?.point == Vector(70, 0))
    }

    @Test("acquireTrackingPoint IGNORES .free / .grid (non-geometry) snaps")
    func acquireIgnoresNonGeometry() {
        let m = model()
        m.objectTrackingEnabled = true
        m.acquireTrackingPoint(osnap(Vector(1, 1), .free))
        m.acquireTrackingPoint(osnap(Vector(2, 2), .grid))
        #expect(m.acquiredPoints.isEmpty)
        // A real osnap still goes in afterwards.
        m.acquireTrackingPoint(osnap(Vector(3, 3), .endpoint))
        #expect(m.acquiredPoints.count == 1)
    }

    @Test("clearTrackingPoints empties the list and nils the result")
    func clearEmpties() {
        let m = otrackModel()
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        moveCursor(m, to: Vector(10, 3))     // lock onto the H guide
        #expect(!m.acquiredPoints.isEmpty)
        #expect(m.trackingResult != nil)
        m.clearTrackingPoints()
        #expect(m.acquiredPoints.isEmpty)
        #expect(m.trackingResult == nil)
    }

    // MARK: - The guide solve via updateSnap

    @Test("1 acquired point + cursor aligned horizontally ⇒ H-guide lock; trackingConstrained returns it")
    func singleGuideHorizontalLock() throws {
        let m = otrackModel()            // H/V guides only — no polar fan to also engage
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        // (10, 3): 3u above the H guide (y == 0), well inside the 8u aperture; 10u from
        // the V guide (x == 0), outside ⇒ only the H guide is near ⇒ single-guide lock.
        moveCursor(m, to: Vector(10, 3))

        let track = try #require(m.trackingResult, "OTRACK should be engaged on the H guide")
        #expect(track.point.y == 0, "locked onto the horizontal guide (y == acquired.y)")
        #expect(abs(track.point.x - 10) < 1e-9, "projected onto the H guide at the cursor x")
        #expect(track.lockedGuides.count == 1)

        // The constraint snaps a candidate onto the locked point.
        #expect(m.trackingConstrained(Vector(10, 3)) == track.point)
    }

    @Test("2 acquired points ⇒ H-of-one ∩ V-of-other intersection lock")
    func twoGuideIntersectionLock() throws {
        let m = otrackModel()            // H/V guides only — isolate the H×V intersection
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))    // H guide: y == 0
        m.acquireTrackingPoint(osnap(Vector(10, 10), .endpoint))  // V guide: x == 10
        // (9, 1) is 1u from A's H (y==0) and 1u from B's V (x==10) — both inside 8u; the
        // other two guides (A's V x==0, B's H y==10) are 9u away (outside) ⇒ a clean
        // intersection of A-horizontal × B-vertical at (10, 0).
        moveCursor(m, to: Vector(9, 1))

        let track = try #require(m.trackingResult, "OTRACK should lock on the intersection")
        #expect(track.lockedGuides.count == 2, "two-guide intersection lock")
        #expect(abs(track.point.x - 10) < 1e-9)
        #expect(abs(track.point.y - 0) < 1e-9)
    }

    // MARK: - Negative gates

    @Test("a real osnap under the cursor ⇒ trackingResult nil (geometry snap wins)")
    func osnapSuppressesTracking() throws {
        // A line with an endpoint at (10, 0): the cursor there snaps to that .endpoint,
        // so osnapActive is true and OTRACK must yield.
        let drawing = CADDrawing()
        _ = drawing.add(EntityRecord(id: EntityID(1),
                                     kind: .line(LineData(start: Vector(10, 0),
                                                          end: Vector(10, 10)))))
        let m = model(drawing: drawing)
        m.objectTrackingEnabled = true
        // Acquire a DIFFERENT point so guides exist, then hover the real endpoint.
        m.acquireTrackingPoint(osnap(Vector(0, 5), .endpoint))
        moveCursor(m, to: Vector(10, 0))

        #expect(m.osnapActive, "cursor on the endpoint is a real object snap")
        #expect(m.trackingResult == nil, "OTRACK yields to the geometry snap")
        // trackingConstrained also yields while an osnap is active.
        #expect(m.trackingConstrained(Vector(10, 0)) == Vector(10, 0))
    }

    @Test("OTRACK disabled ⇒ no tracking even with acquired points + aligned cursor")
    func disabledNoTracking() {
        let m = model()
        m.objectTrackingEnabled = false
        // acquireTrackingPoint still gates only on snap kind, so we can pre-load a point,
        // but with OTRACK off the solve must produce nothing.
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        moveCursor(m, to: Vector(10, 3))
        #expect(m.trackingResult == nil)
        #expect(m.trackingConstrained(Vector(10, 3)) == Vector(10, 3))
    }

    @Test("no acquired points ⇒ no tracking")
    func noAcquiredNoTracking() {
        let m = model()
        m.objectTrackingEnabled = true
        moveCursor(m, to: Vector(10, 3))
        #expect(m.trackingResult == nil)
    }

    // MARK: - toggleObjectTracking independence + clear-on-off

    @Test("toggleObjectTracking flips the flag; turning OFF clears acquisitions")
    func toggleFlipsAndClearsOnOff() {
        let m = model()
        #expect(!m.objectTrackingEnabled)
        m.toggleObjectTracking()
        #expect(m.objectTrackingEnabled)
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        #expect(!m.acquiredPoints.isEmpty)
        // Turning OFF drops the acquired points.
        m.toggleObjectTracking()
        #expect(!m.objectTrackingEnabled)
        #expect(m.acquiredPoints.isEmpty)
        #expect(m.trackingResult == nil)
    }

    @Test("OTRACK is INDEPENDENT of ortho/polar (not mutually exclusive)")
    func toggleIndependentOfOrthoPolar() {
        let m = model()
        m.orthoEnabled = true
        m.polarEnabled = false
        m.toggleObjectTracking()         // OTRACK on must not touch ortho/polar
        #expect(m.objectTrackingEnabled)
        #expect(m.orthoEnabled)          // unchanged
        // And polar can be on together with OTRACK.
        m.polarEnabled = true
        m.toggleObjectTracking()         // OTRACK off
        m.toggleObjectTracking()         // OTRACK on again
        #expect(m.objectTrackingEnabled)
        #expect(m.polarEnabled)
    }

    // MARK: - trackingDisplay() — acquired markers, lock, OTRACK-over-polar precedence

    @Test("trackingDisplay shows acquired markers whenever OTRACK is on (even with no lock)")
    func displayShowsAcquiredMarkers() {
        let m = otrackModel()            // H/V guides only — (100,100) is far from all of them
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        m.acquireTrackingPoint(osnap(Vector(20, 0), .endpoint))
        // Cursor far from any guide ⇒ no lock, but the "+"s still draw.
        moveCursor(m, to: Vector(100, 100))
        let d = m.trackingDisplay()
        #expect(d.acquiredMarkers == [Vector(0, 0), Vector(20, 0)])
        #expect(d.lockMarker == nil)
        #expect(d.guides.isEmpty)
    }

    @Test("trackingDisplay fills guides / lockMarker / readout on an OTRACK lock")
    func displayFillsOnLock() throws {
        let m = otrackModel()            // H/V guides only — a clean single-H-guide lock
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        moveCursor(m, to: Vector(10, 3))     // H-guide lock at (10, 0)

        let track = try #require(m.trackingResult)
        let d = m.trackingDisplay()
        #expect(d.acquiredMarkers == [Vector(0, 0)])
        #expect(d.guides == track.lockedGuides)
        #expect(d.lockMarker == track.point)
        let readout = try #require(d.readout, "a lock ⇒ a formatted readout")
        #expect(!readout.text.isEmpty)
        #expect(readout.text.contains("<"))      // LibreCAD's dist<angle separator
        #expect(readout.anchor == track.point)    // anchored at the LOCKED point
    }

    @Test("OTRACK lock readout OVERRIDES the polar ray/readout")
    func otrackOverridesPolar() throws {
        let m = model()
        m.activateTool(.line)
        m.objectTrackingEnabled = true
        m.polarEnabled = true
        m.setRelativeZero(Vector(0, 0))          // a polar datum so polar would otherwise engage
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        // (10, 0) is on BOTH the 0° polar ray AND the acquired point's H guide ⇒ both
        // would engage; OTRACK must win — the polar ray is suppressed, the chip is the
        // OTRACK lock chip anchored at the locked point.
        moveCursor(m, to: Vector(10, 0))

        let track = try #require(m.trackingResult, "OTRACK should be locked")
        let d = m.trackingDisplay()
        #expect(d.polarRay == nil, "OTRACK lock suppresses the polar ray")
        #expect(d.lockMarker == track.point)
        let readout = try #require(d.readout)
        #expect(readout.anchor == track.point, "the chip is the OTRACK lock chip")
    }

    @Test("with OTRACK on but NOT locked, the polar ray still shows (fallback)")
    func polarFallbackWhenNoOtrackLock() throws {
        let m = model()
        m.activateTool(.line)
        m.objectTrackingEnabled = true
        m.polarEnabled = true
        m.setRelativeZero(Vector(0, 0))
        // No acquired points ⇒ no OTRACK lock; the cursor is on the 0° polar ray.
        moveCursor(m, to: Vector(10, 0))

        #expect(m.trackingResult == nil)
        let d = m.trackingDisplay()
        let ray = try #require(d.polarRay, "no OTRACK lock ⇒ the polar ray falls through")
        #expect(ray.from == Vector(0, 0))
    }

    // MARK: - Reset hooks (tool change / commit / run-end / cursor-leave)

    @Test("activateTool clears acquisitions")
    func activateToolClears() {
        let m = model()
        m.objectTrackingEnabled = true
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        #expect(!m.acquiredPoints.isEmpty)
        m.activateTool(.circle)
        #expect(m.acquiredPoints.isEmpty)
        #expect(m.trackingResult == nil)
    }

    @Test("clearCursor clears acquisitions")
    func clearCursorClears() {
        let m = model()
        m.objectTrackingEnabled = true
        m.acquireTrackingPoint(osnap(Vector(0, 0), .endpoint))
        moveCursor(m, to: Vector(10, 3))
        #expect(!m.acquiredPoints.isEmpty)
        m.clearCursor()
        #expect(m.acquiredPoints.isEmpty)
        #expect(m.trackingResult == nil)
    }

    @Test("a tool COMMIT (line first point) clears acquisitions")
    func commitClears() {
        let m = model()
        m.activateTool(.line)
        m.objectTrackingEnabled = true
        // First click of a Line returns .none (no commit yet); second click commits the
        // segment. Acquire BETWEEN the clicks, then commit.
        _ = m.handleToolInput(.click(Vector(0, 0)))
        m.acquireTrackingPoint(osnap(Vector(5, 5), .endpoint))
        #expect(!m.acquiredPoints.isEmpty)
        _ = m.handleToolInput(.click(Vector(10, 0)))   // commits the line segment
        #expect(m.acquiredPoints.isEmpty, "a commit ends the acquisition context")
    }

    @Test("a run END (.cancel ⇒ .finished) clears acquisitions")
    func finishClears() {
        let m = model()
        m.activateTool(.line)
        m.objectTrackingEnabled = true
        _ = m.handleToolInput(.click(Vector(0, 0)))
        m.acquireTrackingPoint(osnap(Vector(5, 5), .endpoint))
        #expect(!m.acquiredPoints.isEmpty)
        _ = m.handleToolInput(.cancel)                 // ends the run (.finished)
        #expect(m.acquiredPoints.isEmpty, "run-end clears acquisitions")
    }
}
