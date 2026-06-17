//
//  LinetypeScaleRenderTests.swift
//  CADEngineTests
//
//  Linetype-SCALE RENDER scaling — feature-gap Wave 4B, Stage 3.
//
//  The resolved linetype scale (`ResolvedPen.linetypeScale` == the entity's DXF
//  code-48 scale × the drawing-wide `$LTSCALE`) scales the DASH PERIOD in BOTH
//  renderers:
//    - Metal: `RendererGeometry.appendInstances` multiplies the packed
//      `dashPeriodPx`/`dashOnPx` by the scale (no new `LineInstance` field — the MSL
//      struct / `Shaders.swift` are untouched, so the packed layout is byte-stable).
//    - CG export: `CGSceneRenderer.scaledDashLengths` multiplies the dash array.
//  A scale of 1 (the default) leaves both UNCHANGED (regression).
//
//  These exercise the symlinked shipping renderer sources (`_SharedRendererGeometry`
//  / `_SharedCGSceneRenderer`), mirroring RendererGeometryTests / CGDashTests.
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
import CADEngine
import simd
import CoreGraphics

@Suite("Linetype scale render scaling (Metal dash period + CG dash array)")
struct LinetypeScaleRenderTests {

    // MARK: - Metal: appendInstances scales dashPeriodPx / dashOnPx

    private func dashedPen(scale: Double) -> ResolvedPen {
        // ResolvedPen multiplies opacity into color.a and carries linetypeScale.
        ResolvedPen(color: .white, lineType: .dashed, lineWidth: .default,
                    linetypeScale: scale)
    }

    private func firstInstance(scale: Double, backingScale: CGFloat = 2) -> LineInstance {
        let poly = ResolvedPolyline(points: [Vector(0, 0), Vector(100, 0)],
                                    closed: false, pen: dashedPen(scale: scale))
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0),
                                         backingScale: backingScale, into: &out)
        return out[0]
    }

    @Test("a 2× linetype scale doubles the packed Metal dash period + on-length")
    func metalDashScalesByTwo() {
        let base = firstInstance(scale: 1)
        let scaled = firstInstance(scale: 2)
        #expect(base.dashPeriodPx > 0)   // dashed ⇒ non-solid
        #expect(abs(scaled.dashPeriodPx - base.dashPeriodPx * 2) < 1e-4)
        #expect(abs(scaled.dashOnPx - base.dashOnPx * 2) < 1e-4)
    }

    @Test("a 0.5× scale halves the packed Metal dash period")
    func metalDashScalesByHalf() {
        let base = firstInstance(scale: 1)
        let scaled = firstInstance(scale: 0.5)
        #expect(abs(scaled.dashPeriodPx - base.dashPeriodPx * 0.5) < 1e-4)
    }

    @Test("scale 1 leaves the Metal dash period UNCHANGED (regression — no byte change)")
    func metalScaleOneUnchanged() {
        // The default scale must pack the exact same dashPeriodPx/dashOnPx as the
        // base dashParamsPx — proving the scaling is a no-op at 1 (the packed layout
        // is byte-stable for every existing dashed polyline).
        let inst = firstInstance(scale: 1)
        let (basePeriod, baseOn) = RendererGeometry.dashParamsPx(for: .dashed, backingScale: 2)
        #expect(inst.dashPeriodPx == basePeriod)
        #expect(inst.dashOnPx == baseOn)
    }

    @Test("a SOLID pen stays solid (dashPeriodPx == 0) regardless of linetype scale")
    func metalSolidUnaffected() {
        let poly = ResolvedPolyline(
            points: [Vector(0, 0), Vector(10, 0)], closed: false,
            pen: ResolvedPen(color: .white, lineType: .solid, lineWidth: .default,
                             linetypeScale: 5))
        var out: [LineInstance] = []
        RendererGeometry.appendInstances(for: poly, renderOrigin: Vector(0, 0),
                                         backingScale: 2, into: &out)
        #expect(out[0].dashPeriodPx == 0)   // solid ⇒ 0, scaling 0 is still 0
        #expect(out[0].dashOnPx == 0)
    }

    @Test("a 0/negative resolved scale is floored to 1 by ResolvedPen (no dash collapse)")
    func metalZeroScaleFloored() {
        // ResolvedPen floors a ≤0 scale to 1, so the packed period equals the base.
        let inst = firstInstance(scale: 0)
        let (basePeriod, _) = RendererGeometry.dashParamsPx(for: .dashed, backingScale: 2)
        #expect(inst.dashPeriodPx == basePeriod)
    }

    // MARK: - CG export: scaledDashLengths scales the dash array

    @Test("CG scaledDashLengths doubles every element at a 2× scale")
    func cgDashScalesByTwo() {
        let base = CGSceneRenderer.dashLengths(for: .dashed, scale: 1.0, strokeWorld: 0.5)
        let scaled = CGSceneRenderer.scaledDashLengths(
            for: .dashed, scale: 1.0, strokeWorld: 0.5, linetypeScale: 2)
        #expect(base.count == scaled.count)
        for (b, s) in zip(base, scaled) {
            #expect(abs(s - b * 2) < 1e-9)
        }
    }

    @Test("CG scale 1 returns the base array UNCHANGED (regression)")
    func cgScaleOneUnchanged() {
        let base = CGSceneRenderer.dashLengths(for: .dashDot, scale: 2.0, strokeWorld: 0.3)
        let scaled = CGSceneRenderer.scaledDashLengths(
            for: .dashDot, scale: 2.0, strokeWorld: 0.3, linetypeScale: 1)
        #expect(scaled == base)
    }

    @Test("CG solid line stays an EMPTY dash array at any scale")
    func cgSolidStaysEmpty() {
        let scaled = CGSceneRenderer.scaledDashLengths(
            for: .solid, scale: 1.0, strokeWorld: 0.5, linetypeScale: 4)
        #expect(scaled.isEmpty)
    }

    @Test("CG 0/negative scale is floored to 1 (returns the base, never empties)")
    func cgZeroScaleFloored() {
        let base = CGSceneRenderer.dashLengths(for: .dashed, scale: 1.0, strokeWorld: 0.5)
        let scaled = CGSceneRenderer.scaledDashLengths(
            for: .dashed, scale: 1.0, strokeWorld: 0.5, linetypeScale: 0)
        #expect(scaled == base)
    }

    @Test("Metal and CG scale by the SAME factor (screen + export agree)")
    func metalAndCGAgreeOnFactor() {
        // Both renderers multiply by the resolved linetypeScale: the Metal period
        // ratio and the CG element ratio at the same scale must match.
        let metalBase = firstInstance(scale: 1).dashPeriodPx
        let metalScaled = firstInstance(scale: 3).dashPeriodPx
        let metalRatio = Double(metalScaled / metalBase)

        let cgBase = CGSceneRenderer.dashLengths(for: .dashed, scale: 1.0, strokeWorld: 0.5)[0]
        let cgScaled = CGSceneRenderer.scaledDashLengths(
            for: .dashed, scale: 1.0, strokeWorld: 0.5, linetypeScale: 3)[0]
        let cgRatio = Double(cgScaled / cgBase)

        #expect(abs(metalRatio - 3) < 1e-4)
        #expect(abs(cgRatio - 3) < 1e-9)
        #expect(abs(metalRatio - cgRatio) < 1e-4)
    }
}
