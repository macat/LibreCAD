//
//  AutoCADCursorTests.swift
//  CADEngineTests
//
//  Tests the AutoCAD-style canvas cursor recipe. While the drawn "spider" crosshair
//  overlay is shown, `CADCanvasController.refreshCrosshair()` installs a fully
//  TRANSPARENT `NSCursor` (`FlippedMTKView.blankCursor`) over the canvas through the
//  cursor-rect machinery, so the native macOS pointer is hidden and the user sees ONLY
//  the drawn crosshair (AutoCAD parity), not the OS pointer drawn on top of it.
//
//  WHY this test mirrors the recipe instead of reading `FlippedMTKView.blankCursor`
//  directly: `blankCursor` is a `static let` on `FlippedMTKView`, which lives in
//  `CADCanvasView.swift`. That file's dependency closure (GizmoOverlayView,
//  MarqueeHoverOverlayView, the whole controller graph, …) is far too large to compile
//  into the test target via a `_Shared*` symlink without dragging in a dozen more
//  files. So this suite asserts the exact construction recipe `blankCursor` uses — a
//  16×16 empty `NSImage` (nothing drawn → fully transparent) wrapped in an `NSCursor`
//  with a centered hotSpot — which is the property that actually matters (the pointer
//  is invisible). The EXISTENCE and correctness of `FlippedMTKView.blankCursor` itself
//  is enforced by the production build + a code review of the one-line swap; keep this
//  recipe in lockstep with the `static let blankCursor` definition in
//  `CADCanvasView.swift`.
//
//  NOT verifiable headlessly (owner's final visual check): the on-screen invisibility
//  is live AppKit chrome driven by `addCursorRect`/`resetCursorRects` against a real
//  window + tracking area, which neither the headless test suite nor LCShot (committed
//  geometry only — no cursor/overlay chrome) can observe.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import AppKit
@testable import CADEngine

@MainActor
@Suite("AutoCAD cursor — transparent blank cursor recipe")
struct AutoCADCursorTests {

    /// Builds an `NSCursor` exactly the way `FlippedMTKView.blankCursor` does (16×16
    /// empty image, centered hotSpot). Kept in lockstep with that `static let`.
    private func makeBlankCursorMirror() -> NSCursor {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }

    @Test("blank cursor is 16×16 with a centered hotspot")
    func sizeAndHotspot() {
        let cursor = makeBlankCursorMirror()
        #expect(cursor.image.size == NSSize(width: 16, height: 16))
        #expect(cursor.hotSpot == NSPoint(x: 8, y: 8))
    }

    @Test("blank cursor image is fully transparent (nothing drawn → invisible pointer)")
    func isTransparent() throws {
        let cursor = makeBlankCursorMirror()
        // Rasterize the cursor image and assert every pixel has zero alpha — i.e. the
        // pointer the OS would draw over the canvas is invisible.
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 16,
                pixelsHigh: 16,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = ctx
        cursor.image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.current = saved

        var maxAlpha = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let color = rep.colorAt(x: x, y: y)
                let alpha = Int(((color?.alphaComponent ?? 0) * 255).rounded())
                maxAlpha = max(maxAlpha, alpha)
            }
        }
        #expect(maxAlpha == 0)
    }
}
