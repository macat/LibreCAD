//
//  SVGExportTests.swift
//  CADEngineTests
//
//  Unit tests for the pure-Swift `SVGExporter` (the export-feature engine half).
//  The CGContext PDF/PNG/Print path lives in the app target (needs CoreGraphics/
//  AppKit) and is smoke-covered by the app build + headless launch; the SVG
//  emitter is the geometry-truth, unit-testable surface, so it is tested here.
//
//  Coverage (per the export-feature acceptance bar):
//    - a small drawing (line + circle + text) emits well-formed SVG with the
//      expected element counts,
//    - the `viewBox` derives from the page (computed from the drawing bounds),
//    - text is present as vector PATH data (outline glyph fills, not <text>),
//    - a hidden (frozen) layer's entities are omitted,
//    - the page transform maps world bounds onto the page (fit-to-page) and 1:1.
//
//  Suite/type names are domain-namespaced (`SVGExport*`) per CONVENTIONS to avoid
//  the parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("SVGExport: emitter")
struct SVGExportEmitterTests {

    /// A native (Core Text) resolve context so text resolves to outline FILLS.
    /// Helvetica Neue is universally installed and resolves headless (verified by
    /// the text-system tests).
    private func nativeContext(for drawing: CADDrawing) -> ResolveContext {
        var ctx = drawing.makeResolveContext(tessellationTolerance: 0.05)
        ctx.fontProvider = CADFonts.provider
        return ctx
    }

    /// A small drawing: a line, a circle, and a text — the canonical export fixture.
    private func sampleDrawing() -> CADDrawing {
        let d = CADDrawing()
        d.add(EntityRecord(id: EntityID(0),
                           kind: .line(LineData(start: Vector(0, 0), end: Vector(100, 0)))))
        d.add(EntityRecord(id: EntityID(0),
                           kind: .circle(CircleData(center: Vector(50, 50), radius: 25))))
        d.add(EntityRecord(id: EntityID(0),
                           kind: .text(TextData(position: Vector(0, 60), height: 10, text: "AB"))))
        return d
    }

    @Test("line + circle + text emits well-formed SVG with the expected element count")
    func elementCount() {
        let d = sampleDrawing()
        let svg = SVGExporter.string(for: d, context: nativeContext(for: d))

        // Well-formed envelope.
        #expect(svg.hasPrefix("<?xml"))
        #expect(svg.contains("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(svg.contains("</svg>"))
        #expect(svg.contains("<g transform=\"matrix("))

        // The line is an OPEN polyline → one <polyline>; the circle is a CLOSED
        // ring → one <polygon>. (Both stroke elements.)
        #expect(count(of: "<polyline", in: svg) == 1)
        #expect(count(of: "<polygon", in: svg) == 1)

        // Text glyphs are outline FILLS → <path> elements (≥ 2 for "AB": at least
        // one path per letter; "B" has counters so it may contribute holes within
        // its single path). At minimum two letter paths.
        #expect(count(of: "<path", in: svg) >= 2)
    }

    @Test("viewBox and width/height come from the fit-to-page page size")
    func viewBoxFromPage() {
        let d = sampleDrawing()
        let opts = ExportOptions(pageSize: .usLetter, margin: 18, scaling: .fitToPage)
        let svg = SVGExporter.string(for: d, options: opts, context: nativeContext(for: d))

        // US Letter is 612 × 792 pt; the viewBox is the page rect.
        #expect(svg.contains("viewBox=\"0 0 612 792\""))
        #expect(svg.contains("width=\"612\""))
        #expect(svg.contains("height=\"792\""))
    }

    @Test("text is present as vector PATH data, never an SVG <text> element")
    func textAsVectorPath() {
        let d = CADDrawing()
        d.add(EntityRecord(id: EntityID(0),
                           kind: .text(TextData(position: Vector(0, 0), height: 20, text: "O"))))
        let svg = SVGExporter.string(for: d, context: nativeContext(for: d))

        // Outline glyph → at least one <path d="..."> with real coordinates.
        #expect(svg.contains("<path d=\""))
        // Crucially NOT an SVG <text> element (we vectorize, not font-embed).
        #expect(!svg.contains("<text"))
        // "O" has a counter (hole) → its path has more than one subpath (>=2 "M").
        if let pathFrag = pathData(in: svg) {
            #expect(count(of: "M ", in: pathFrag) >= 2)
            #expect(pathFrag.contains("fill-rule=\"evenodd\"") == false)  // attr on element, not in d
        }
    }

    @Test("a hidden (frozen) layer's entities are omitted from the SVG")
    func hiddenLayerOmitted() {
        let d = CADDrawing()
        // A dedicated "hidden" layer carrying the circle; the line stays on "0".
        d.addLayer(Layer(name: "hidden"))
        d.add(EntityRecord(id: EntityID(0), layer: LayerID("0"),
                           kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        d.add(EntityRecord(id: EntityID(0), layer: LayerID("hidden"),
                           kind: .circle(CircleData(center: Vector(5, 5), radius: 3))))

        // Visible: both the line (polyline) and circle (polygon) appear.
        let visible = SVGExporter.string(for: d, context: nativeContext(for: d))
        #expect(count(of: "<polyline", in: visible) == 1)
        #expect(count(of: "<polygon", in: visible) == 1)

        // Freeze the "hidden" layer → its circle is omitted; the line remains.
        d.setLayerVisible("hidden", false)
        let hidden = SVGExporter.string(for: d, context: nativeContext(for: d))
        #expect(count(of: "<polyline", in: hidden) == 1)   // line still drawn
        #expect(count(of: "<polygon", in: hidden) == 0)    // circle gone
    }

    @Test("a non-printable layer's entities are omitted (plot/print flag honored)")
    func nonPrintableLayerOmitted() {
        let d = CADDrawing()
        d.addLayer(Layer(name: "noplot"))
        d.add(EntityRecord(id: EntityID(0), layer: LayerID("noplot"),
                           kind: .circle(CircleData(center: Vector(0, 0), radius: 5))))
        d.setLayerPrintable("noplot", false)
        let svg = SVGExporter.string(for: d, context: nativeContext(for: d))
        #expect(count(of: "<polygon", in: svg) == 0)
    }

    @Test("empty drawing emits a valid SVG with the fallback page size, no geometry")
    func emptyDrawing() {
        let d = CADDrawing()
        let svg = SVGExporter.string(for: d, context: nativeContext(for: d))
        #expect(svg.contains("<svg"))
        #expect(svg.contains("</svg>"))
        #expect(count(of: "<polyline", in: svg) == 0)
        #expect(count(of: "<polygon", in: svg) == 0)
        #expect(count(of: "<path", in: svg) == 0)
        // Fallback page size is the default US Letter.
        #expect(svg.contains("viewBox=\"0 0 612 792\""))
    }

    // MARK: - Helpers

    private func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: range) {
            n += 1
            range = r.upperBound..<haystack.endIndex
        }
        return n
    }

    /// Extracts the first `<path d="...">`'s d-attribute payload.
    private func pathData(in svg: String) -> String? {
        guard let open = svg.range(of: "<path d=\"") else { return nil }
        let after = open.upperBound
        guard let close = svg.range(of: "\"", range: after..<svg.endIndex) else { return nil }
        return String(svg[after..<close.lowerBound])
    }
}

@Suite("SVGExport: page transform")
struct SVGExportTransformTests {

    @Test("fit-to-page maps the drawing bounds inside the available area")
    func fitToPage() {
        let bounds = AABB(min: Vector(0, 0), max: Vector(100, 50))
        let opts = ExportOptions(pageSize: SizePt(width: 200, height: 200),
                                 margin: 10, scaling: .fitToPage)
        let xform = ExportTransform(bounds: bounds, options: opts)

        // Available 180×180; bound 100×50 → limited by width (180/100 = 1.8) and
        // height (180/50 = 3.6) → uniform scale 1.8.
        #expect(abs(xform.scale - 1.8) < 1e-9)
        #expect(xform.pageSize.width == 200)

        // The four corners map inside [0, page] (with margin), y-flipped.
        let bl = xform.page(Vector(0, 0))
        let tr = xform.page(Vector(100, 50))
        #expect(bl.x >= 10 - 1e-6 && bl.x <= 190 + 1e-6)
        #expect(tr.x >= 10 - 1e-6 && tr.x <= 190 + 1e-6)
        // World-min y maps to a LARGER page-y than world-max y (y-flip).
        #expect(bl.y > tr.y)
    }

    @Test("1:1 scaling sizes the page to the drawing plus margins")
    func oneToOne() {
        let bounds = AABB(min: Vector(0, 0), max: Vector(100, 50))
        let opts = ExportOptions(margin: 20, scaling: .oneToOne(unitsPerPoint: 1.0))
        let xform = ExportTransform(bounds: bounds, options: opts)

        #expect(abs(xform.scale - 1.0) < 1e-9)
        // 100 wide + 2×20 margin = 140; 50 tall + 40 = 90.
        #expect(abs(xform.pageSize.width - 140) < 1e-9)
        #expect(abs(xform.pageSize.height - 90) < 1e-9)
    }

    @Test("an empty bounds falls back to the option page size at scale 1")
    func emptyBounds() {
        let opts = ExportOptions(pageSize: .a4)
        let xform = ExportTransform(bounds: .empty, options: opts)
        #expect(xform.scale == 1)
        #expect(xform.pageSize == SizePt.a4)
    }
}
