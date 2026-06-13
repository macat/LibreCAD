//
//  DimScaleTextHeightTests.swift
//  CADEngineTests
//
//  Regression test for the "dimension/constraint text renders far too big" bug on
//  real imperial drawings (owner's mechanical_example-imperial.dwg).
//
//  ROOT CAUSE pinned here: the document OPEN path (`DXFDocumentCodec.payload(...)`)
//  used to construct its `DXFPayload` with `graphicVariables: GraphicVariables()`
//  (and `blocks: BlockTable()`), DISCARDING the engine's parsed header. So a file
//  whose real `$DIMTXT` is 0.125 was opened with the `GraphicVariables()` default
//  (2.5), and every dimension's measurement/constraint text rendered ~20x too big
//  (the resolve reads the document `$DIMTXT` via `dimStyleProvider`). The engine
//  read path itself parsed 0.125 correctly all along — the app's codec just dropped
//  it on the floor before it reached the drawing.
//
//  This test reproduces the EXACT app open path (file bytes -> DXFDocumentCodec ->
//  CADDrawing.make(from:)) and asserts the opened drawing's constraint dimension
//  (a parametric `textOverride` formula) resolves its glyphs at ~$DIMTXT (0.125),
//  small relative to the geometry — NOT the 2.5 default the dropped-header bug gave.
//
//  Fixture `dim_constraint_header.dxf` is a small shippable DXF (no DWG license
//  needed): $DIMTXT=$DIMASZ=0.125, $DIMSCALE=1.0 (matching the real file), one
//  aligned dimension carrying a code-1 formula override `KEYheight=.25+(SHAFTid/2)`.
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

@Suite("Constraint dim text height — opened file's $DIMTXT must reach the resolve")
struct DimScaleTextHeightTests {

    private func fixturePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "dim_constraint_header", withExtension: "dxf"),
            "dim_constraint_header.dxf resource missing from the test bundle")
        return url.path
    }

    /// World-space bounding height of the dimension's resolved measurement-text
    /// glyphs (fills, or strokes if the provider strokes) — the actual rendered
    /// glyph height a user sees.
    @MainActor
    private static func glyphHeight(_ d: DimData, ctx: ResolveContext) -> Double {
        let measured: Double
        switch d.kind {
        case let .linear(e1, e2, _): measured = (e2 - e1).magnitude
        case let .aligned(e1, e2): measured = (e2 - e1).magnitude
        default: measured = 1.0
        }
        let label = EntityKind.dimLabel(d, measured: measured, ctx: ctx)
        let h = EntityKind.dimTextHeight(d, ctx: ctx)
        let pen = ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        let geo = EntityKind.dimText(label, center: Vector(0, 0), rotation: 0,
                                     height: h, pen: pen, ctx: ctx)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for f in geo.fills { for loop in f.loops { for v in loop { lo = Swift.min(lo, v.y); hi = Swift.max(hi, v.y) } } }
        for p in geo.polylines { for v in p.points { lo = Swift.min(lo, v.y); hi = Swift.max(hi, v.y) } }
        return hi - lo
    }

    @Test("the engine parses the file's small $DIMTXT (0.125), not the 2.5 default")
    func parsesHeader() async throws {
        let gv = try await CADEngine.shared.readEntities(dxfPath: fixturePath()).graphicVariables
        #expect(abs(gv.dimTextHeight - 0.125) < 1e-9)
        #expect(gv.dimTextHeight != 2.5)
    }

    @Test("the document OPEN codec carries the parsed $DIMTXT through (not the 2.5 default)")
    func documentCodecCarriesHeader() async throws {
        // Reproduce the app's File-open path: bytes -> DXFDocumentCodec.payload.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath()))
        let payload = try DXFDocumentCodec.payload(from: bytes, format: .dxf)
        // The regression: the payload must carry the file's $DIMTXT (0.125), NOT the
        // GraphicVariables() default 2.5 that the old codec substituted.
        #expect(abs(payload.graphicVariables.dimTextHeight - 0.125) < 1e-9)
        #expect(payload.graphicVariables.dimTextHeight != 2.5)
    }

    @MainActor
    @Test("a drawing built via the app open path resolves the constraint dim text at ~0.125")
    func openedDrawingResolvesSmall() async throws {
        // The FULL app open path: file bytes -> codec payload -> live drawing.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath()))
        let payload = try DXFDocumentCodec.payload(from: bytes, format: .dxf)
        let drawing = CADDrawing.make(from: payload)
        let ctx = drawing.makeResolveContext()

        let dim = try #require(drawing.entities.compactMap { rec -> DimData? in
            if case .dimension(let d) = rec.kind { return d }
            return nil
        }.first, "expected a dimension in the fixture")

        // Sanity: this dimension carries the parametric constraint formula override.
        #expect(dim.textOverride == "KEYheight=.25+(SHAFTid/2)")

        // The resolved cap height is the file's $DIMTXT (0.125), NOT the 2.5 default
        // the dropped-header bug produced.
        let resolved = EntityKind.dimTextHeight(dim, ctx: ctx)
        #expect(abs(resolved - 0.125) < 1e-9)
        #expect(abs(resolved - 2.5) > 0.1, "must NOT fall back to the 2.5 default")

        // The actual rendered glyph fills of the FORMULA override are ~0.125 tall
        // (a small allowance above cap height for ascenders/descenders), far below
        // the ~2.6 the dropped-header bug measured on the real file.
        let glyph = Self.glyphHeight(dim, ctx: ctx)
        #expect(glyph > 0, "the override formula must produce real glyph geometry")
        #expect(glyph < 0.5, "glyphs must render at ~DIMTXT (0.125), not ~2.5")
    }
}
