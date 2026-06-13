//
//  DimStyleTableTests.swift
//  CADEngineTests
//
//  Unit tests for the named DIMSTYLE table (`DimStyleTable` / `NamedDimStyle`),
//  the extended dimension-style precedence (per-entity override > named style >
//  document header default), and the DIMEXO/DIMEXE/DIMGAP ext-line offsets feeding
//  the dimension resolve geometry. Pure-engine (no file I/O); the DXF/DWG round
//  trip is covered separately in DimStyleRoundTripTests.
//
//  GPLv2-or-later (LibreCAD derivative). Mirrors RS_DimStyle / DRW_Dimstyle.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DimStyle table + ext-offset resolve (w1-dimstyle)")
struct DimStyleTableTests {

    // MARK: - DimStyleTable value behavior

    @Test("DimStyleTable upsert / lookup is case-insensitive; remove keeps Standard")
    func tableUpsertAndLookup() {
        var t = DimStyleTable()
        t.upsert(NamedDimStyle(name: "Standard", style: ResolvedDimStyle(textHeight: 0.18)))
        t.upsert(NamedDimStyle(name: "ISO-25", style: ResolvedDimStyle(textHeight: 2.5)))
        #expect(t.count == 2)
        // Case-insensitive lookup (AutoCAD style names).
        #expect(t.style(named: "iso-25")?.style.textHeight == 2.5)
        #expect(t.contains("STANDARD"))

        // Upsert with a clashing name (different case) REPLACES, doesn't duplicate.
        t.upsert(NamedDimStyle(name: "iso-25", style: ResolvedDimStyle(textHeight: 9.0)))
        #expect(t.count == 2)
        #expect(t.style(named: "ISO-25")?.style.textHeight == 9.0)

        // Remove a non-Standard style works; removing Standard is a no-op (kept).
        t.remove(named: "ISO-25")
        #expect(!t.contains("ISO-25"))
        t.remove(named: "Standard")
        #expect(t.contains("Standard"))
    }

    @Test("DimStyleTable.active() prefers activeName, then Standard, then first")
    func tableActiveSelection() {
        var t = DimStyleTable(styles: [
            NamedDimStyle(name: "First", style: ResolvedDimStyle(textHeight: 1)),
            NamedDimStyle(name: "Standard", style: ResolvedDimStyle(textHeight: 2)),
            NamedDimStyle(name: "Named", style: ResolvedDimStyle(textHeight: 3)),
        ])
        // activeName wins.
        t.activeName = "Named"
        #expect(t.active()?.name == "Named")
        // No activeName → Standard.
        t.activeName = nil
        #expect(t.active()?.name == "Standard")
        // No Standard, no activeName → first.
        var t2 = DimStyleTable(styles: [NamedDimStyle(name: "Only", style: .default)])
        #expect(t2.active()?.name == "Only")
        t2 = DimStyleTable()
        #expect(t2.active() == nil)
    }

    // MARK: - Resolve precedence (per-entity > named style > header default)

    private func linearDim(styleName: String?, textHeight: Double, arrowSize: Double) -> DimData {
        DimData(kind: .linear(extension1: .init(0, 0), extension2: .init(10, 0), angle: 0),
                definitionPoint: .init(5, 5),
                styleName: styleName,
                textHeight: textHeight, arrowSize: arrowSize)
    }

    @Test("named style fills in when a dim references it and carries no per-entity height")
    func namedStyleFillsInheritedDim() {
        // Header default 9.0; a named "Small" style at 0.18.
        let header = ResolvedDimStyle(textHeight: 9.0, arrowSize: 9.0)
        let named = ResolvedDimStyle(textHeight: 0.18, arrowSize: 0.18)
        let ctx = ResolveContext(
            dimStyleProvider: { header },
            namedDimStyleProvider: { $0.caseInsensitiveCompare("Small") == .orderedSame ? named : nil }
        )

        // A dim referencing "Small" with no per-entity height inherits 0.18 (the
        // NAMED style), NOT the 9.0 header default.
        let d = linearDim(styleName: "Small", textHeight: 0, arrowSize: 0)
        #expect(abs(EntityKind.dimTextHeight(d, ctx: ctx) - 0.18) < 1e-9)
        #expect(abs(EntityKind.dimArrowSize(d, ctx: ctx) - 0.18) < 1e-9)
    }

    @Test("per-entity override beats the named style; absent style falls to header")
    func precedenceFullChain() {
        let header = ResolvedDimStyle(textHeight: 9.0, arrowSize: 9.0)
        let named = ResolvedDimStyle(textHeight: 0.18, arrowSize: 0.18)
        let ctx = ResolveContext(
            dimStyleProvider: { header },
            namedDimStyleProvider: { $0.caseInsensitiveCompare("Small") == .orderedSame ? named : nil }
        )

        // Per-entity height 4.0 WINS over the named style 0.18.
        let overridden = linearDim(styleName: "Small", textHeight: 4.0, arrowSize: 1.5)
        #expect(abs(EntityKind.dimTextHeight(overridden, ctx: ctx) - 4.0) < 1e-9)
        #expect(abs(EntityKind.dimArrowSize(overridden, ctx: ctx) - 1.5) < 1e-9)

        // A dim naming a style NOT in the table falls back to the header default 9.0.
        let unknownStyle = linearDim(styleName: "DoesNotExist", textHeight: 0, arrowSize: 0)
        #expect(abs(EntityKind.dimTextHeight(unknownStyle, ctx: ctx) - 9.0) < 1e-9)

        // A dim with NO style name uses the header default 9.0.
        let noStyle = linearDim(styleName: nil, textHeight: 0, arrowSize: 0)
        #expect(abs(EntityKind.dimTextHeight(noStyle, ctx: ctx) - 9.0) < 1e-9)
    }

    @Test("the named style's $DIMSCALE multiplies the resolved height")
    func namedStyleScale() {
        let named = ResolvedDimStyle(textHeight: 2.0, arrowSize: 2.0, scale: 3.0)
        let ctx = ResolveContext(namedDimStyleProvider: { _ in named })
        let d = linearDim(styleName: "S", textHeight: 0, arrowSize: 0)
        // 2.0 (named) * 3.0 (scale) == 6.0.
        #expect(abs(EntityKind.dimTextHeight(d, ctx: ctx) - 6.0) < 1e-9)
    }

    // MARK: - DIMEXO / DIMEXE / DIMGAP ext-line offsets

    @Test("explicit DIMEXO/DIMEXE/DIMGAP feed the effective ext-offset helpers (scaled)")
    func extOffsetsHonored() {
        let style = ResolvedDimStyle(textHeight: 1.0, arrowSize: 1.0, scale: 2.0,
                                     extensionOffset: 0.0625, extensionBeyond: 0.18,
                                     textGap: 0.09)
        let ctx = ResolveContext(dimStyleProvider: { style })
        let d = linearDim(styleName: nil, textHeight: 0, arrowSize: 0)
        // Each is the style value * $DIMSCALE (2.0).
        #expect(abs(EntityKind.dimExtensionOffset(d, ctx: ctx) - 0.125) < 1e-9)
        #expect(abs(EntityKind.dimExtensionBeyond(d, ctx: ctx) - 0.36) < 1e-9)
        #expect(abs(EntityKind.dimTextGap(d, ctx: ctx) - 0.18) < 1e-9)
    }

    @Test("absent DIMEXO/DIMEXE/DIMGAP fall back to the historical arrow/text fractions")
    func extOffsetsFallback() {
        // No explicit ext offsets → the resolve uses the arrow/text fraction defaults
        // (so existing dimension geometry is unchanged).
        let style = ResolvedDimStyle(textHeight: 2.0, arrowSize: 3.0)   // ext* default 0
        let ctx = ResolveContext(dimStyleProvider: { style })
        let d = linearDim(styleName: nil, textHeight: 0, arrowSize: 0)
        let arrow = EntityKind.dimArrowSize(d, ctx: ctx)        // 3.0
        let textH = EntityKind.dimTextHeight(d, ctx: ctx)       // 2.0
        #expect(abs(EntityKind.dimExtensionOffset(d, ctx: ctx)
                    - arrow * EntityKind.dimExtensionOffsetFactor) < 1e-9)
        #expect(abs(EntityKind.dimExtensionBeyond(d, ctx: ctx)
                    - arrow * EntityKind.dimExtensionBeyondFactor) < 1e-9)
        #expect(abs(EntityKind.dimTextGap(d, ctx: ctx)
                    - textH * EntityKind.dimTextGapFactor) < 1e-9)
    }

    @Test("ext offsets reach the resolved geometry: extension line start respects DIMEXO")
    func extOffsetInResolvedGeometry() {
        // Two horizontal extension origins at y=0; the dim line at y=5. With a large
        // DIMEXO the drawn extension line should START well above each origin (gap).
        let style = ResolvedDimStyle(textHeight: 0.5, arrowSize: 0.5,
                                     extensionOffset: 1.0, extensionBeyond: 0.25,
                                     textGap: 0.2)
        let ctx = ResolveContext(dimStyleProvider: { style })
        let d = DimData(kind: .linear(extension1: .init(0, 0), extension2: .init(10, 0), angle: 0),
                        definitionPoint: .init(5, 5),
                        textHeight: 0, arrowSize: 0)
        let pen = ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)
        let geo = EntityKind.resolveDimension(d, pen: pen, ctx: ctx)

        // The two extension-line polylines are the first two emitted. Each runs from
        // (origin + DIMEXO toward the dim line) up to (dim line + DIMEXE beyond).
        let extLines = geo.polylines.filter { $0.points.count == 2 }
        let ext = try? #require(extLines.first { p in
            abs(p.points[0].x - 0) < 1e-6 || abs(p.points[0].x - 10) < 1e-6
        })
        let start = try! #require(ext).points[0]
        let end = try! #require(ext).points[1]
        // Start is offset 1.0 above the origin (y≈1.0), NOT at the origin (y≈0).
        #expect(abs(start.y - 1.0) < 1e-6)
        // End runs 0.25 past the dim line at y=5 → y≈5.25.
        #expect(abs(end.y - 5.25) < 1e-6)
    }
}
