//
//  CoordinateConsistencyTests.swift
//  CADEngineTests
//
//  Regression lock for the cursor-offset bug (a ~200 px click→geometry offset
//  caused by a STALE viewport size lagging the live MTKView bounds). The bug was
//  diagnosed and fixed in the interaction layer (CADCanvasController re-syncs
//  `viewport.size` from the live `FlippedMTKView.bounds`), and the
//  `LC_DEBUG_COORDS` print instrumentation that helped pin it has been removed —
//  THIS suite is the CI-level invariant that replaces it.
//
//  The single invariant that, if it ever breaks, reproduces the offset:
//  **the CPU picking transform (`worldToScreen`) and the GPU render transform
//  (`worldToClip`) must agree on where a world point lands.** The cursor-offset
//  bug was precisely the two transforms disagreeing because they were fed
//  different view sizes. Here we drive ONE Viewport through BOTH transforms and
//  assert they map the same world point to the same on-screen pixel, across a
//  matrix of drawable sizes, backing-scale factors, pan offsets, and zoom levels
//  — including a far floating-origin offset (ADR-003), with the worst-case ULP
//  documented.
//
//  Suite/struct name is domain-unique (`CoordinateConsistencyTests`) to avoid a
//  test-target namespace clash with the parallel `ViewportTransformTests`
//  (CONVENTIONS.md "Namespace test-suite type names by domain"). This suite is
//  complementary: `ViewportTransformTests` checks each transform in isolation;
//  this one pins the CROSS-transform consistency the offset bug violated.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
import CoreGraphics
import simd
@testable import CADEngine

@Suite("Coordinate consistency (worldToScreen ↔ worldToClip)")
struct CoordinateConsistencyTests {

    // MARK: - Tolerances (documented per ADR-003 floating-origin worst case)

    /// f64 world↔screen round-trip tolerance, RELATIVE to the point magnitude.
    /// `worldToScreen`/`screenToWorld` are pure f64 affine inverses, so the only
    /// error is f64 rounding in the multiply/divide → a handful of ULP. 1e-9 of
    /// the coordinate magnitude is ~6 orders of magnitude of slack over that.
    private static let worldRoundTripRelTol = 1e-9

    /// Cross-transform NDC agreement tolerance for the NEAR-origin case
    /// (`renderOrigin` chosen near the content, the intended floating-origin
    /// usage). Both the `worldToScreen→NDC` path and `worldToClip` are exact in
    /// f64; the only loss is the final `Float` cast of the matrix and of the
    /// `f32(worldPoint - renderOrigin)` vertex offset. With the offset small
    /// (origin near content) that cast keeps ~6–7 significant digits, so the two
    /// NDC values agree to well under 1e-5.
    private static let ndcNearTol: Float = 1e-5

    /// Cross-transform NDC agreement tolerance for the FAR floating-origin case
    /// (`renderOrigin` at world (0,0) while content sits ~1e6 away — the WORST
    /// case ADR-003 calls out, and the reason we keep the origin near content).
    ///
    /// ## Worst-case ULP (documented per the brief)
    /// The f32 vertex offset is `Float(worldPoint - renderOrigin)`. At a magnitude
    /// of ~1e6 a `Float` has ~24 bits of mantissa, so 1 ULP ≈ `1e6 * 2^-23`
    /// ≈ 0.119 world units of representable spacing. Multiplied by the NDC scale
    /// `sx = scale / (halfWidthPts)` for the configs here (scale ≤ 250, half-width
    /// ≥ 256 pts → sx up to ~0.98 NDC/unit, but the far case below uses scale 2.5
    /// over a 512 pt half-width → sx ≈ 0.0049 NDC/unit), the far-origin NDC error
    /// is bounded by a few f32 ULP of the offset, i.e. on the order of 1e-3 NDC.
    /// We assert 1e-2 — a comfortable bound that still FAILS loudly if the two
    /// transforms structurally disagree (the offset bug), while tolerating the
    /// legitimate f32 precision loss the floating-origin design exists to AVOID by
    /// keeping the origin near content.
    private static let ndcFarTol: Float = 1e-2

    // MARK: - Helpers

    /// NDC of a world point via the GPU path: the exact transform the vertex
    /// shader applies — `worldToClip` matrix × `Float(worldPoint - renderOrigin)`.
    private func clipNDC(_ vp: Viewport, world p: Vector, origin: Vector, drawable: CGSize) -> SIMD2<Float> {
        let m = vp.worldToClip(renderOrigin: origin, drawableSize: drawable)
        let offset = SIMD4<Float>(Float(p.x - origin.x), Float(p.y - origin.y), 0, 1)
        let clip = m * offset
        return SIMD2<Float>(clip.x, clip.y)
    }

    /// NDC of a world point via the CPU path: `worldToScreen` (points, top-left,
    /// Y-down) re-expressed in NDC (Y-up, [-1, 1]) using the SAME view point-size
    /// the Viewport stores. This is the picking/cursor space; if it disagrees with
    /// `clipNDC` the cursor and the geometry are drawn in different places — the
    /// cursor-offset bug. Computed in f64 then cast to f32 so the comparison is
    /// apples-to-apples against the GPU's f32 clip output.
    private func screenNDC(_ vp: Viewport, world p: Vector) -> SIMD2<Float> {
        let s = vp.worldToScreen(p)
        let halfW = Double(vp.size.width) * 0.5
        let halfH = Double(vp.size.height) * 0.5
        // Screen points → NDC. X: right is +. Y: screen is Y-down, NDC is Y-up,
        // so negate. (halfW/halfH guaranteed > 0 for the configs under test.)
        let ndcX = (Double(s.x) - halfW) / halfW
        let ndcY = -(Double(s.y) - halfH) / halfH
        return SIMD2<Float>(Float(ndcX), Float(ndcY))
    }

    // MARK: - 1. The cross-transform consistency matrix (the lock)

    /// THE regression lock: for every combination of drawable size, backing
    /// scale, pan offset (center), and zoom level, the CPU picking transform
    /// (`worldToScreen`) and the GPU render transform (`worldToClip`) map the SAME
    /// world point to the SAME on-screen position (in NDC). Backing scale enters
    /// only at the drawable-pixel size; because NDC is normalized it must CANCEL —
    /// so a Retina (2×/3×) drawable maps a world point to exactly the same NDC as
    /// a 1× drawable. If a future change reintroduces a size/scale mismatch
    /// between the two transforms (the cursor-offset bug), this fails.
    @Test("worldToScreen and worldToClip agree on the same world point across sizes/backing/pan/zoom (near origin)")
    func crossTransformConsistencyMatrix() {
        let pointSizes: [CGSize] = [
            CGSize(width: 800, height: 600),    // 4:3
            CGSize(width: 1280, height: 800),   // 16:10
            CGSize(width: 1024, height: 1024),  // square
        ]
        let backings: [Double] = [1.0, 2.0, 3.0]            // non-Retina, Retina, 3×
        let centers: [Vector] = [
            Vector(0, 0),
            Vector(123.5, -456.25),
            Vector(-9_000.0, 4_200.0),
        ]
        let scales: [Double] = [0.1, 1.0, 7.5, 250.0]       // zoomed out → in
        // Probe points spread across the view, expressed RELATIVE to center so
        // they stay on-screen at every zoom (fractions of the visible half-size).
        let relProbes: [(Double, Double)] = [
            (0, 0), (0.4, 0.3), (-0.45, 0.2), (0.25, -0.48), (-0.5, -0.5),
        ]

        for pts in pointSizes {
            for backing in backings {
                let drawable = CGSize(width: pts.width * backing, height: pts.height * backing)
                for center in centers {
                    for scale in scales {
                        let vp = Viewport(scale: scale, center: center, size: pts)
                        // Floating-origin used the intended way: origin near content.
                        let origin = center
                        // Half the visible world extent (so probes stay in view).
                        let halfWorldX = (Double(pts.width) * 0.5) / scale
                        let halfWorldY = (Double(pts.height) * 0.5) / scale
                        for (rx, ry) in relProbes {
                            let p = Vector(center.x + rx * halfWorldX,
                                           center.y + ry * halfWorldY)
                            let gpu = clipNDC(vp, world: p, origin: origin, drawable: drawable)
                            let cpu = screenNDC(vp, world: p)
                            #expect(abs(gpu.x - cpu.x) < Self.ndcNearTol,
                                    "NDC.x mismatch pts=\(pts) backing=\(backing) scale=\(scale) center=(\(center.x),\(center.y)) p=(\(p.x),\(p.y)): gpu=\(gpu.x) cpu=\(cpu.x)")
                            #expect(abs(gpu.y - cpu.y) < Self.ndcNearTol,
                                    "NDC.y mismatch pts=\(pts) backing=\(backing) scale=\(scale) center=(\(center.x),\(center.y)) p=(\(p.x),\(p.y)): gpu=\(gpu.y) cpu=\(cpu.y)")
                        }
                    }
                }
            }
        }
    }

    /// Pins the backing-scale-cancels property explicitly: the SAME Viewport and
    /// world point produce the SAME GPU NDC at 1×, 2×, and 3× drawable sizes.
    /// (The cursor-offset bug was a sibling of this — a drawable/point-size
    /// mismatch leaking into the transform; this proves backing scale alone never
    /// moves a point.)
    @Test("backing scale cancels: identical NDC at 1×, 2×, 3× drawable")
    func backingScaleCancels() {
        let pts = CGSize(width: 1440, height: 900)
        let vp = Viewport(scale: 12.5, center: Vector(50, -75), size: pts)
        let origin = vp.center
        let p = Vector(58.0, -60.0)
        let n1 = clipNDC(vp, world: p, origin: origin, drawable: pts)
        let n2 = clipNDC(vp, world: p, origin: origin,
                         drawable: CGSize(width: pts.width * 2, height: pts.height * 2))
        let n3 = clipNDC(vp, world: p, origin: origin,
                         drawable: CGSize(width: pts.width * 3, height: pts.height * 3))
        #expect(abs(n1.x - n2.x) < 1e-6 && abs(n1.y - n2.y) < 1e-6)
        #expect(abs(n1.x - n3.x) < 1e-6 && abs(n1.y - n3.y) < 1e-6)
    }

    // MARK: - 2. World → screen → world round-trip (tight tolerance)

    /// `screenToWorld(worldToScreen(p)) ≈ p` across drawable sizes (via point
    /// size), backing scales (irrelevant to this f64 path — asserted by reusing
    /// the same point sizes), pan offsets, and zoom levels, INCLUDING a far
    /// floating-origin point. Pure f64 affine inverse → relative error ~ULP.
    @Test("world → screen → world returns the original within ~ULP (incl. far floating-origin)")
    func worldScreenWorldRoundTrip() {
        let sizes: [CGSize] = [
            CGSize(width: 800, height: 600),
            CGSize(width: 1280, height: 800),
            CGSize(width: 1024, height: 1024),
        ]
        let scales: [Double] = [0.1, 1.0, 7.5, 250.0]
        let centers: [Vector] = [
            Vector(0, 0),
            Vector(-1234.5, 6789.0),
            Vector(1_000_000.0, -2_000_000.0),   // far floating-origin region
        ]
        let probes: [Vector] = [
            Vector(0, 0),
            Vector(10, 20),
            Vector(-50, 75),
            Vector(3.14159, -2.71828),
            Vector(1_000_000.25, -2_000_000.5),  // far point, large magnitude
        ]
        for size in sizes {
            for scale in scales {
                for center in centers {
                    let vp = Viewport(scale: scale, center: center, size: size)
                    for p in probes {
                        let back = vp.screenToWorld(vp.worldToScreen(p))
                        let mag = Swift.max(1.0, abs(p.x), abs(p.y))
                        #expect(abs(back.x - p.x) < Self.worldRoundTripRelTol * mag,
                                "x drift size=\(size) scale=\(scale) center=(\(center.x),\(center.y)) p=(\(p.x),\(p.y)): \(back.x)")
                        #expect(abs(back.y - p.y) < Self.worldRoundTripRelTol * mag,
                                "y drift size=\(size) scale=\(scale) center=(\(center.x),\(center.y)) p=(\(p.x),\(p.y)): \(back.y)")
                    }
                }
            }
        }
    }

    // MARK: - 3. Far floating-origin: the worst-case ULP is bounded

    /// ADR-003 worst case: content ~1e6 from the world origin, but the f32 vertex
    /// buffers are kept relative to a `renderOrigin` AT (0,0) (the pathological
    /// choice the floating-origin design exists to avoid). Even so, the GPU NDC
    /// must agree with the CPU picking NDC to within the documented far tolerance
    /// (`ndcFarTol`, ~1e-2 NDC — see the constant's worst-case-ULP derivation).
    /// This both (a) proves the two transforms stay consistent at the floating-
    /// origin extreme and (b) documents the precision the design recovers by
    /// instead choosing `renderOrigin` near content (asserted tighter below).
    @Test("far floating-origin: GPU vs CPU NDC stay within the documented worst-case ULP bound")
    func farFloatingOriginWorstCaseULP() {
        let pts = CGSize(width: 1024, height: 768)
        let backing = 2.0
        let drawable = CGSize(width: pts.width * backing, height: pts.height * backing)
        let center = Vector(1_000_000, 2_000_000)
        let scale = 2.5
        let vp = Viewport(scale: scale, center: center, size: pts)
        let p = Vector(1_000_123.0, 1_999_950.0)  // ~150 units from center, on-screen

        // Pathological far origin at world (0,0): max f32 cancellation.
        let far = clipNDC(vp, world: p, origin: Vector(0, 0), drawable: drawable)
        // Near origin (the intended usage): the trustworthy reference.
        let near = clipNDC(vp, world: p, origin: center, drawable: drawable)
        // CPU picking NDC (exact f64 → f32).
        let cpu = screenNDC(vp, world: p)

        // Far-origin GPU NDC stays within the worst-case ULP bound of the
        // trustworthy near-origin computation AND of the CPU picking transform.
        #expect(abs(far.x - near.x) < Self.ndcFarTol, "far vs near NDC.x: \(far.x) vs \(near.x)")
        #expect(abs(far.y - near.y) < Self.ndcFarTol, "far vs near NDC.y: \(far.y) vs \(near.y)")
        #expect(abs(far.x - cpu.x) < Self.ndcFarTol, "far GPU vs CPU NDC.x: \(far.x) vs \(cpu.x)")
        #expect(abs(far.y - cpu.y) < Self.ndcFarTol, "far GPU vs CPU NDC.y: \(far.y) vs \(cpu.y)")

        // The near-origin path (intended floating-origin usage) is FAR tighter to
        // the CPU transform — this is the precision the design recovers.
        #expect(abs(near.x - cpu.x) < Self.ndcNearTol, "near GPU vs CPU NDC.x: \(near.x) vs \(cpu.x)")
        #expect(abs(near.y - cpu.y) < Self.ndcNearTol, "near GPU vs CPU NDC.y: \(near.y) vs \(cpu.y)")

        // The nearby point is genuinely on screen (within NDC bounds), so the
        // tolerances above are measured where it matters.
        #expect(abs(near.x) <= 1.0 && abs(near.y) <= 1.0)
    }
}
