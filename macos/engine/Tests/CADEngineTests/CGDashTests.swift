//
//  CGDashTests.swift
//  CADEngineTests
//
//  Unit tests for the CG-export line-type DASH pattern helper
//  (`CGSceneRenderer.dashLengths(for:scale:strokeWorld:)`). The renderer was
//  previously stroking EVERY polyline solid, ignoring the resolved pen line type;
//  this guards the per-line-type dash-array derivation that drives the
//  PDF/PNG/Print (and now on-screen) dashed-line rendering.
//
//  ## Why this file compiles a symlinked source
//  `CGSceneRenderer` lives in the `LibreCADmacOS` EXECUTABLE target, which SwiftPM
//  does not produce a linkable library for — so a test target cannot
//  `@testable import` it. The shipping source is therefore SYMLINKED into this
//  test target (`_SharedCGSceneRenderer.swift -> .../Export/CGSceneRenderer.swift`),
//  matching the existing `_SharedPrintLayout.swift` / `_SharedShaders.swift`
//  pattern, so these tests exercise the EXACT shipping helper with zero drift.
//
//  The helper is pure value math (no CGContext), so it unit-tests headlessly.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import CADEngine
import CoreGraphics

@Suite("CG export — line-type dash patterns")
struct CGDashTests {

    /// A representative world→page scale and a rendered stroke width in world units.
    private let scale = 4.0
    private let strokeWorld = 0.25

    private func dash(_ lt: PenLineType) -> [CGFloat] {
        CGSceneRenderer.dashLengths(for: lt, scale: scale, strokeWorld: strokeWorld)
    }

    // MARK: - Solid (and residual ByLayer/ByBlock) → no dash

    @Test("solid line type returns an EMPTY dash array (continuous stroke)")
    func solidIsEmpty() {
        #expect(dash(.solid).isEmpty)
    }

    @Test("residual byLayer/byBlock are treated as solid (empty dash, never a crash)")
    func byLayerByBlockTreatedSolid() {
        #expect(dash(.byLayer).isEmpty)
        #expect(dash(.byBlock).isEmpty)
    }

    // MARK: - Each dashed style → non-empty alternating pattern

    @Test("every non-solid line type returns a non-empty, even-count, positive pattern")
    func dashedStylesAreNonEmptyAlternating() {
        let styles: [PenLineType] = [.dashed, .dotted, .dashDot, .center, .border, .divide]
        for lt in styles {
            let d = dash(lt)
            #expect(!d.isEmpty, "\(lt) should produce a dash pattern")
            // CG dash arrays alternate ON, OFF, ON, OFF… — an even count keeps the
            // pattern phase-stable when it repeats.
            #expect(d.count % 2 == 0, "\(lt) pattern must alternate on/off (even count)")
            // Every length must be strictly positive (a 0 would stall the dasher).
            for len in d {
                #expect(len > 0, "\(lt) pattern has a non-positive length \(len)")
            }
        }
    }

    @Test("dashed is a simple [dash, gap] pair")
    func dashedShape() {
        let d = dash(.dashed)
        #expect(d.count == 2)
        #expect(d[0] > d[1])   // dash longer than the gap
    }

    @Test("dotted's ON length is short (a dot), shorter than dashed's dash")
    func dottedDotIsShort() {
        let dotted = dash(.dotted)
        let dashed = dash(.dashed)
        #expect(dotted[0] < dashed[0])
    }

    @Test("dashDot has four entries (dash, gap, dot, gap)")
    func dashDotShape() {
        let d = dash(.dashDot)
        #expect(d.count == 4)
        // The dash (entry 0) is longer than the dot (entry 2).
        #expect(d[0] > d[2])
    }

    // MARK: - Fixed-on-zoom (physical) scaling

    @Test("dash lengths shrink in WORLD units as the world→page scale grows (fixed paper size)")
    func dashIsFixedPhysicalSize() {
        // A larger scale (more page points per world unit) means a given paper dash
        // length is FEWER world units — the dash is a fixed physical size on paper,
        // not a fixed world size. So the world-unit dash length must DECREASE.
        let coarse = CGSceneRenderer.dashLengths(for: .dashed, scale: 2.0, strokeWorld: strokeWorld)
        let fine = CGSceneRenderer.dashLengths(for: .dashed, scale: 8.0, strokeWorld: strokeWorld)
        #expect(coarse[0] > fine[0])
    }

    @Test("a degenerate (≈0) scale still returns a positive, finite pattern (no divide blow-up)")
    func degenerateScaleIsSafe() {
        let d = CGSceneRenderer.dashLengths(for: .dashDot, scale: 0, strokeWorld: strokeWorld)
        #expect(!d.isEmpty)
        for len in d {
            #expect(len > 0 && len.isFinite)
        }
    }
}
