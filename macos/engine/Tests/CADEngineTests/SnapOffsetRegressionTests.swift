//
//  SnapOffsetRegressionTests.swift
//  CADEngineTests
//
//  Regression guard for the "drawn line lands with a small offset from the
//  cursor" bug. The Viewport transform is exact (ViewportTests prove the
//  screen↔world round-trip), so the offset was NOT a transform error — it was the
//  interactive snap policy defaulting to grid-snap, which rounds a click in empty
//  space to the nearest grid node (up to the catch aperture away from the cursor).
//
//  The fix (CanvasModel.swift) drops `.grid` from the *interactive* default snap
//  modes, keeping the geometry snaps (endpoint/center/middle/intersection/
//  onEntity) and `.free`. This test pins the engine-level behavior that makes that
//  fix correct:
//    1. with grid on, a click in empty space is MOVED off the cursor (the bug);
//    2. with the interactive default (no grid), the same click free-falls to the
//       EXACT cursor point (the fix) — the line lands under the cursor;
//    3. real geometry snaps still fire under that interactive default.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Snap offset regression (cursor↔commit)")
struct SnapOffsetRegressionTests {

    /// The app's *interactive* default snap set — mirrors `CanvasModel.snapModes`.
    /// Deliberately OMITS `.grid` so empty-area clicks land exactly on the cursor.
    /// Kept in lockstep with the model default; if the model re-adds `.grid` this
    /// suite's `interactiveDefaultLandsExactlyOnCursor` test will fail.
    static let interactiveDefault: SnapMode =
        [.endpoint, .center, .middle, .intersection, .onEntity, .free]

    /// The pick/snap aperture in GUI points (mirrors `CanvasModel.catchPoints`).
    static let catchPoints: Double = 8

    // MARK: - The bug: grid-snap moves an empty-area click off the cursor

    @MainActor
    @Test("WITH grid: an empty-area click is rounded to the grid (offset from cursor)")
    func gridSnapMovesClickOffCursor() {
        let drawing = CADDrawing()        // no entities — only grid can fire
        let quadtree = Quadtree()
        // A cursor between grid nodes. At scale 50 pt/unit the 8-pt aperture is
        // 0.16 world units, and a grid spacing of 0.1 puts a node within reach.
        let scale = 50.0
        let worldTol = Self.catchPoints / scale          // 0.16 world units
        let spacing = 0.1
        let cursor = Vector(2.43, 7.57)             // between 0.1-spaced nodes

        let r = Snapping.snap(
            worldPoint: cursor,
            modes: [.grid, .free],
            worldTolerance: worldTol,
            gridSpacing: spacing,
            in: drawing, using: quadtree
        )
        // Grid fired and MOVED the point off the cursor — the reported offset.
        #expect(r.kind == SnapKind.grid)
        let offset = r.point.distance(to: cursor)
        #expect(offset > 1e-6, "grid snap should move the click off the cursor")
        #expect(r.point.distance(to: Vector(2.4, 7.6)) < 1e-9)  // nearest node
    }

    // MARK: - The fix: the interactive default lands exactly on the cursor

    @MainActor
    @Test("FIX: interactive default (no grid) free-falls to the EXACT cursor in empty space")
    func interactiveDefaultLandsExactlyOnCursor() {
        let drawing = CADDrawing()
        let quadtree = Quadtree()
        let scale = 50.0
        let worldTol = Self.catchPoints / scale
        let spacing = 0.1
        let cursor = Vector(2.43, 7.57)

        let r = Snapping.snap(
            worldPoint: cursor,
            modes: Self.interactiveDefault,
            worldTolerance: worldTol,
            gridSpacing: spacing,        // spacing supplied, but grid mode is OFF
            in: drawing, using: quadtree
        )
        // No grid mode, no nearby geometry → free fallback == the raw cursor point,
        // so a committed point lands EXACTLY under the cursor (no offset).
        #expect(r.kind == SnapKind.free)
        #expect(r.point.distance(to: cursor) < 1e-12)
    }

    // MARK: - The fix keeps real geometry snaps working

    @MainActor
    @Test("interactive default still snaps to a real endpoint")
    func interactiveDefaultStillSnapsGeometry() {
        let drawing = CADDrawing()
        // A line from (0,0) to (10,0); we approach its (10,0) endpoint. The id
        // passed here is a placeholder — `add` mints the real one (as the existing
        // SelectionSnapFixture does).
        let id = drawing.add(EntityRecord(id: EntityID(0),
                                          kind: .line(LineData(start: Vector(0, 0),
                                                               end: Vector(10, 0)))))
        let quadtree = Quadtree()
        if let b = drawing.entity(id)?.boundingBox(), !b.isEmpty {
            quadtree.insert(id, bounds: b)
        }

        let cursor = Vector(9.97, 0.02)             // just shy of the endpoint
        let r = Snapping.snap(
            worldPoint: cursor,
            modes: Self.interactiveDefault,
            worldTolerance: 0.2,
            gridSpacing: 1.0,
            in: drawing, using: quadtree
        )
        #expect(r.kind == SnapKind.endpoint)
        #expect(r.point.distance(to: Vector(10, 0)) < 1e-9)
    }
}
