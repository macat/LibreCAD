//
//  HeaderDimStyleReadTests.swift
//  CADEngineTests
//
//  Verifies the bridge now READS the HEADER variables ($INSUNITS/$LUNITS/$LUPREC
//  + the dimension defaults $DIMTXT/$DIMASZ/$DIMSCALE/$DIMLUNIT/$DIMDEC) and the
//  DIMSTYLE table, maps them into the drawing's `graphicVariables`, and that a
//  no-override dimension then RESOLVES at the file's real (small, imperial) text
//  height instead of the engine's 2.5 fallback. Also verifies a per-dimension
//  ACAD:DSTYLE override (DXF 1070 140 / 41 + 1040 value) WINS over the document
//  default. The crafted fixture `imperial_dim.dxf` is a small, shippable DXF
//  (text format, no DWG license needed) with $INSUNITS=1 (inch), $DIMTXT=0.18,
//  $DIMASZ=0.18, a DIMSTYLE, and two linear dimensions (one plain, one overridden).
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
@testable import CADEngine

@Suite("Header + DIMSTYLE read (imperial dim fixture)")
struct HeaderDimStyleReadTests {

    /// Path to the bundled crafted imperial-dimension fixture.
    private func fixturePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "imperial_dim", withExtension: "dxf"),
            "imperial_dim.dxf resource missing from the test bundle")
        return url.path
    }

    @Test("reads $INSUNITS / $LUNITS / $LUPREC into graphicVariables")
    func readsUnitVariables() async throws {
        let result = try await CADEngine.shared.readEntities(dxfPath: fixturePath())
        let gv = result.graphicVariables
        // $INSUNITS=1 → inch (NOT the engine's millimeter default).
        #expect(gv.unit == .inch)
        // $LUNITS=2 → decimal, $LUPREC=3.
        #expect(gv.linearFormat == .decimal)
        #expect(gv.linearPrecision == 3)
    }

    @Test("reads $DIMTXT / $DIMASZ / $DIMSCALE into graphicVariables (NOT the 2.5 default)")
    func readsDimensionDefaults() async throws {
        let result = try await CADEngine.shared.readEntities(dxfPath: fixturePath())
        let gv = result.graphicVariables
        // The file's $DIMTXT/$DIMASZ are 0.18 — the imperial standard, NOT 2.5.
        #expect(abs(gv.dimTextHeight - 0.18) < 1e-9)
        #expect(abs(gv.dimArrowSize - 0.18) < 1e-9)
        #expect(abs(gv.dimScale - 1.0) < 1e-9)
        #expect(gv.dimTextHeight != 2.5)
        // $DIMLUNIT=2 decimal, $DIMDEC=3.
        #expect(gv.dimLinearFormat == .decimal)
        #expect(gv.dimLinearPrecision == 3)
    }

    /// Path to the DIMSTYLE-only fixture (header carries NO $DIM* defaults; the
    /// dimension default must come from the Standard DIMSTYLE table entry instead).
    private func styleOnlyFixturePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "imperial_dim_styleonly", withExtension: "dxf"),
            "imperial_dim_styleonly.dxf resource missing from the test bundle")
        return url.path
    }

    @Test("the DIMSTYLE table supplies the dim default when the header omits $DIM*")
    func dimStyleTableFillsWhenHeaderOmitsDims() async throws {
        // This fixture's HEADER has $INSUNITS but NO $DIMTXT/$DIMASZ; the Standard
        // DIMSTYLE table entry carries dimtxt=dimasz=0.2. The reader must apply the
        // style's values as the document default (the header-omitted path).
        let result = try await CADEngine.shared.readEntities(dxfPath: styleOnlyFixturePath())
        let gv = result.graphicVariables
        #expect(gv.unit == .inch)
        #expect(abs(gv.dimTextHeight - 0.2) < 1e-9)
        #expect(abs(gv.dimArrowSize - 0.2) < 1e-9)
        #expect(gv.dimTextHeight != 2.5)
    }

    @MainActor
    @Test("a no-override dimension RESOLVES at 0.18 (the file's value), not 2.5")
    func noOverrideDimResolvesAtFileHeight() async throws {
        let drawing = try await loadDrawing(dxfPath: fixturePath())
        let ctx = drawing.makeResolveContext()

        // The first DIMENSION carries no per-entity override → it must inherit the
        // document default $DIMTXT (0.18) via the dimStyleProvider.
        let plainDim = try #require(drawing.entities.compactMap { rec -> DimData? in
            if case .dimension(let d) = rec.kind, d.textHeight == 0 { return d }
            return nil
        }.first, "expected a no-override dimension in the fixture")

        let resolvedHeight = EntityKind.dimTextHeight(plainDim, ctx: ctx)
        let resolvedArrow = EntityKind.dimArrowSize(plainDim, ctx: ctx)
        #expect(abs(resolvedHeight - 0.18) < 1e-9)
        #expect(abs(resolvedArrow - 0.18) < 1e-9)
        // The bug being fixed: it must NOT fall back to 2.5.
        #expect(resolvedHeight != 2.5)
    }

    @MainActor
    @Test("a per-dimension override (ACAD:DSTYLE) WINS over the document default")
    func perDimensionOverrideWins() async throws {
        let drawing = try await loadDrawing(dxfPath: fixturePath())
        let ctx = drawing.makeResolveContext()

        // The second DIMENSION carries an ACAD:DSTYLE override of text height 0.5 /
        // arrow 0.5 — the per-entity value must beat the 0.18 document default.
        let overriddenDim = try #require(drawing.entities.compactMap { rec -> DimData? in
            if case .dimension(let d) = rec.kind, d.textHeight > 0 { return d }
            return nil
        }.first, "expected an overridden dimension in the fixture")

        #expect(abs(overriddenDim.textHeight - 0.5) < 1e-9)
        #expect(abs(overriddenDim.arrowSize - 0.5) < 1e-9)
        // Resolved: per-entity 0.5 wins over the document 0.18.
        #expect(abs(EntityKind.dimTextHeight(overriddenDim, ctx: ctx) - 0.5) < 1e-9)
        #expect(abs(EntityKind.dimArrowSize(overriddenDim, ctx: ctx) - 0.5) < 1e-9)
    }
}
