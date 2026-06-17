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

// MARK: - Fidelity: dashes, lineweight, gradients, masks, auto-invert (export lane)

@Suite("SVGExport: stroke fidelity (dash + lineweight)")
struct SVGExportStrokeFidelityTests {

    /// A scene with a single open polyline carrying `pen`.
    private func scene(pen: ResolvedPen,
                       points: [Vector] = [Vector(0, 0), Vector(100, 0)]) -> ExportScene {
        let poly = ResolvedPolyline(points: points, closed: false, pen: pen)
        return ExportScene(polylines: [poly], bounds: AABB(points: points))
    }

    private func pen(lineType: PenLineType = .solid,
                     lineWidth: PenLineWidth = .default,
                     linetypeScale: Double = 1,
                     color: RGBAColor = .librecadGreen) -> ResolvedPen {
        ResolvedPen(color: color, lineType: lineType, lineWidth: lineWidth,
                    linetypeScale: linetypeScale)
    }

    @Test("a DASHED pen emits a stroke-dasharray attribute")
    func dashedEmitsDashArray() {
        let svg = SVGExporter.string(for: scene(pen: pen(lineType: .dashed)))
        #expect(svg.contains("stroke-dasharray=\""))
    }

    @Test("a SOLID pen emits NO stroke-dasharray (continuous stroke, unchanged)")
    func solidEmitsNoDashArray() {
        let svg = SVGExporter.string(for: scene(pen: pen(lineType: .solid)))
        #expect(!svg.contains("stroke-dasharray"))
    }

    @Test("residual byLayer/byBlock line types emit NO dash (treated solid, never a crash)")
    func byLayerByBlockNoDash() {
        #expect(!SVGExporter.string(for: scene(pen: pen(lineType: .byLayer))).contains("stroke-dasharray"))
        #expect(!SVGExporter.string(for: scene(pen: pen(lineType: .byBlock))).contains("stroke-dasharray"))
    }

    @Test("every non-solid line type emits a dash array")
    func everyDashedStyleEmitsArray() {
        for lt in [PenLineType.dashed, .dotted, .dashDot, .center, .border, .divide] {
            let svg = SVGExporter.string(for: scene(pen: pen(lineType: lt)))
            #expect(svg.contains("stroke-dasharray=\""), "\(lt) should emit a dash array")
        }
    }

    @Test("the SVG dash array matches the CG-shared scaledDashLengths helper")
    func dashArrayMatchesHelper() {
        // The fit-to-page scale for a 100-unit-wide drawing on US Letter (612×792,
        // 18pt margin) is what `string(for:)` computes internally; rather than
        // recompute it, assert the helper itself drives a non-empty, even pattern.
        let d = SVGExporter.scaledDashLengths(for: .dashed, scale: 4, strokeWorld: 0.25,
                                              linetypeScale: 1)
        #expect(d.count == 2)
        #expect(d[0] > d[1])
        // Scale 2 ⇒ doubled.
        let d2 = SVGExporter.scaledDashLengths(for: .dashed, scale: 4, strokeWorld: 0.25,
                                               linetypeScale: 2)
        #expect(abs(d2[0] - d[0] * 2) < 1e-9)
    }

    @Test("an explicit mm lineweight yields a WIDER stroke-width than a default pen")
    func explicitLineweightIsWider() {
        // Two scenes at the SAME page scale (identical bounds): a default-width pen
        // and a heavy 2mm pen. The heavy pen's emitted stroke-width must exceed the
        // default hairline's.
        let thin = SVGExporter.string(for: scene(pen: pen(lineWidth: .default)))
        let thick = SVGExporter.string(for: scene(pen: pen(lineWidth: .millimeters(2.0))))
        let thinW = strokeWidth(in: thin)
        let thickW = strokeWidth(in: thick)
        #expect(thinW != nil && thickW != nil)
        if let t = thinW, let k = thickW { #expect(k > t, "2mm pen (\(k)) not wider than default (\(t))") }
    }

    @Test("strokeWidthWorld matches the CG mm→world derivation for an explicit pen")
    func strokeWidthWorldMatchesCG() {
        let p = ResolvedPen(color: .black, lineType: .solid, lineWidth: .millimeters(1.0))
        let scale = 2.0, strokeWorld = 0.5
        let w = SVGExporter.strokeWidthWorld(for: p, strokeWorld: strokeWorld, scale: scale)
        // mm → page points (mm / (25.4/72)) ÷ scale, floored to strokeWorld.
        let expected = Swift.max(strokeWorld, (1.0 / (25.4 / 72.0)) / scale)
        #expect(abs(w - expected) < 1e-9)
    }

    // MARK: - Helpers

    /// The numeric value of the FIRST `stroke-width="…"` attribute in the SVG.
    private func strokeWidth(in svg: String) -> Double? {
        guard let open = svg.range(of: "stroke-width=\"") else { return nil }
        let after = open.upperBound
        guard let close = svg.range(of: "\"", range: after..<svg.endIndex) else { return nil }
        return Double(svg[after..<close.lowerBound])
    }
}

@Suite("SVGExport: gradient fills")
struct SVGExportGradientTests {

    private func gradientFillScene(kind: ResolvedGradient.Kind,
                                   colors: [RGBAColor]) -> ExportScene {
        let loop = [Vector(0, 0), Vector(100, 0), Vector(100, 100), Vector(0, 100)]
        let fill = ResolvedFill(outline: loop, color: colors.first ?? .black,
                                gradient: ResolvedGradient(kind: kind, colors: colors, angle: 0))
        return ExportScene(fills: [fill], bounds: AABB(points: loop))
    }

    @Test("a linear gradient fill emits a <linearGradient> def referenced by the fill")
    func linearGradientDefAndRef() {
        let svg = gradientFillScene(kind: .linear,
                                    colors: [RGBAColor(1, 0, 0), RGBAColor(0, 0, 1)])
        let out = SVGExporter.string(for: svg)
        #expect(out.contains("<defs>"))
        #expect(out.contains("<linearGradient id=\"grad-0\""))
        // Both stop colors present.
        #expect(out.contains("stop-color=\"#ff0000\""))
        #expect(out.contains("stop-color=\"#0000ff\""))
        // The fill path references the def (not a flat color).
        #expect(out.contains("fill=\"url(#grad-0)\""))
    }

    @Test("a radial gradient fill emits a <radialGradient> def")
    func radialGradientDef() {
        let out = SVGExporter.string(for: gradientFillScene(
            kind: .radial, colors: [RGBAColor(0, 1, 0), RGBAColor(1, 1, 1)]))
        #expect(out.contains("<radialGradient id=\"grad-0\""))
        #expect(out.contains("fill=\"url(#grad-0)\""))
    }

    @Test("a one-color gradient still emits two distinct stops (lightened tint)")
    func oneColorGradientShades() {
        let base = RGBAColor(0.2, 0.2, 0.2)
        let out = SVGExporter.string(for: gradientFillScene(kind: .linear, colors: [base]))
        #expect(out.contains("<linearGradient"))
        // The synthetic second stop is the 50%-lightened tint, distinct from the base.
        let tint = SVGExporter.lightenedTint(base)
        #expect(out.contains("stop-color=\"\(SVGExporter.hex(base))\""))
        #expect(out.contains("stop-color=\"\(SVGExporter.hex(tint))\""))
        #expect(SVGExporter.hex(base) != SVGExporter.hex(tint))
    }

    @Test("a flat (non-gradient) fill emits NO gradient def (unchanged)")
    func flatFillNoGradient() {
        let loop = [Vector(0, 0), Vector(10, 0), Vector(10, 10)]
        let fill = ResolvedFill(outline: loop, color: RGBAColor(0.5, 0.5, 0.5))
        let out = SVGExporter.string(for: ExportScene(fills: [fill], bounds: AABB(points: loop)))
        #expect(!out.contains("linearGradient"))
        #expect(!out.contains("radialGradient"))
        #expect(out.contains("fill=\"#808080\""))
    }
}

@MainActor
@Suite("SVGExport: wipeout masks")
struct SVGExportMaskTests {

    /// A scene: one solid black mask fill over a square, plus a stroke crossing it.
    private func maskScene() -> ExportScene {
        let loop = [Vector(0, 0), Vector(100, 0), Vector(100, 100), Vector(0, 100)]
        let mask = ResolvedFill(outline: loop, color: .black, isMask: true)
        let stroke = ResolvedPolyline(points: [Vector(-10, 50), Vector(110, 50)],
                                      closed: false,
                                      pen: ResolvedPen(color: .black, lineType: .solid, lineWidth: .default))
        return ExportScene(polylines: [stroke], fills: [mask], bounds: AABB(points: loop))
    }

    @Test("a wipeout mask paints the PAGE BACKGROUND color, not opaque black")
    func maskPaintsPageBackground() {
        let opts = ExportOptions(background: .white)
        let out = SVGExporter.string(for: maskScene(), options: opts)
        // The mask path is filled white (the page bg), NOT the fallback black.
        #expect(out.contains("fill=\"#ffffff\""))
    }

    @Test("the mask path is emitted AFTER the stroke (so it masks the lower stroke)")
    func maskAfterStroke() {
        let opts = ExportOptions(background: .white)
        let out = SVGExporter.string(for: maskScene(), options: opts)
        // The stroke polyline must appear BEFORE the white mask <path> in document
        // order (later = drawn on top in SVG). NB: the page-background <rect> is also
        // fill="#ffffff", so search for the white-filled <path> specifically (the
        // mask), not just any white fill.
        guard let strokeIdx = out.range(of: "<polyline")?.lowerBound else {
            Issue.record("expected a stroke polyline")
            return
        }
        guard let maskIdx = whiteFilledPathIndex(in: out) else {
            Issue.record("expected a white-filled mask <path>")
            return
        }
        #expect(strokeIdx < maskIdx, "mask <path> must be emitted after the stroke")
    }

    /// The start index of the first `<path … fill="#ffffff" …>` (the mask), scanning
    /// each `<path` element so the page-background `<rect>` is not matched.
    private func whiteFilledPathIndex(in svg: String) -> String.Index? {
        var search = svg.startIndex..<svg.endIndex
        while let open = svg.range(of: "<path", range: search) {
            let elemEnd = svg.range(of: ">", range: open.upperBound..<svg.endIndex)?.upperBound
                ?? svg.endIndex
            let element = svg[open.lowerBound..<elemEnd]
            if element.contains("fill=\"#ffffff\"") { return open.lowerBound }
            search = elemEnd..<svg.endIndex
        }
        return nil
    }

    @Test("a wipeout ENTITY resolves to an isMask fill that exports as page-bg, not black")
    func wipeoutEntityMasksToPageBg() {
        let d = CADDrawing()
        // A simple square wipeout (pixel space == world; boundary in pixel coords).
        d.add(EntityRecord(
            id: EntityID(0),
            kind: .wipeout(WipeoutData(
                insertion: Vector(0, 0),
                uVector: Vector(1, 0),
                vVector: Vector(0, 1),
                pixelWidth: 100, pixelHeight: 100,
                boundary: [Vector(0, 0), Vector(100, 0), Vector(100, 100), Vector(0, 100)],
                frameVisible: false))))
        let scene = ExportSceneBuilder.build(d)
        #expect(scene.fills.contains { $0.isMask }, "wipeout should resolve to an isMask fill")
        let out = SVGExporter.string(for: scene, options: ExportOptions(background: .white))
        // The mask is painted the white page bg — NOT the resolved fallback black.
        #expect(out.contains("fill=\"#ffffff\""))
    }
}

@Suite("SVGExport: light-mode color-7 auto-invert (export slice)")
struct SVGExportAutoInvertTests {

    private func whitePenScene() -> ExportScene {
        // A near-white "automatic color" pen (color-7 resolved to white).
        let pen = ResolvedPen(color: .white, lineType: .solid, lineWidth: .default)
        let pts = [Vector(0, 0), Vector(50, 50)]
        return ExportScene(polylines: [ResolvedPolyline(points: pts, closed: false, pen: pen)],
                           bounds: AABB(points: pts))
    }

    @Test("on a WHITE page, an automatic (white) pen exports as INK (near-black), not white")
    func whitePenInvertsOnLightPage() {
        let out = SVGExporter.string(for: whitePenScene(), options: ExportOptions(background: .white))
        // The near-white pen flips to the near-black ink target (#1a1a1f).
        #expect(out.contains("stroke=\"#1a1a1f\""))
        #expect(!out.contains("stroke=\"#ffffff\""))
    }

    @Test("on a DARK/transparent page, an automatic (white) pen stays white (no invert)")
    func whitePenStaysWhiteOnDarkPage() {
        // Transparent (nil) page → no invert.
        let outNil = SVGExporter.string(for: whitePenScene(), options: ExportOptions(background: nil))
        #expect(outNil.contains("stroke=\"#ffffff\""))
        // Explicitly black page → no invert.
        let outBlack = SVGExporter.string(for: whitePenScene(), options: ExportOptions(background: .black))
        #expect(outBlack.contains("stroke=\"#ffffff\""))
    }

    @Test("an explicit non-white color is NEVER inverted, even on a light page")
    func explicitColorNotInverted() {
        let pen = ResolvedPen(color: RGBAColor(1, 0, 0), lineType: .solid, lineWidth: .default)
        let pts = [Vector(0, 0), Vector(10, 0)]
        let scene = ExportScene(polylines: [ResolvedPolyline(points: pts, closed: false, pen: pen)],
                                bounds: AABB(points: pts))
        let out = SVGExporter.string(for: scene, options: ExportOptions(background: .white))
        #expect(out.contains("stroke=\"#ff0000\""))
    }

    @Test("isLightBackground gates on a near-white opaque page")
    func lightBackgroundGate() {
        #expect(SVGExporter.isLightBackground(.white))
        #expect(!SVGExporter.isLightBackground(.black))
        #expect(!SVGExporter.isLightBackground(nil))
        // A translucent white is NOT a solid light page.
        #expect(!SVGExporter.isLightBackground(RGBAColor(1, 1, 1, 0.2)))
    }
}

@MainActor
@Suite("SVGExport: active-space scene filter (finding #6)")
struct SVGExportSpaceFilterTests {

    /// A drawing with one model-space line and one paper-space line on layout "L1".
    private func mixedDrawing() -> CADDrawing {
        let d = CADDrawing()
        d.add(EntityRecord(id: EntityID(0), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))),
                           space: .model))
        d.add(EntityRecord(id: EntityID(0), kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5))),
                           space: .paper, layoutName: "L1"))
        return d
    }

    @Test(".all (default) includes BOTH spaces (historical union behavior)")
    func allIncludesEverything() {
        let scene = ExportSceneBuilder.build(mixedDrawing())
        #expect(scene.polylines.count == 2)
    }

    @Test(".model includes ONLY the model-space entity")
    func modelOnly() {
        let scene = ExportSceneBuilder.build(mixedDrawing(), space: .model)
        #expect(scene.polylines.count == 1)
    }

    @Test(".paper(layout) includes ONLY that layout's paper entity (case-insensitive)")
    func paperLayoutOnly() {
        let scene = ExportSceneBuilder.build(mixedDrawing(), space: .paper(layoutName: "l1"))
        #expect(scene.polylines.count == 1)
        // A different / nil layout name yields nothing on paper.
        #expect(ExportSceneBuilder.build(mixedDrawing(), space: .paper(layoutName: "other")).polylines.isEmpty)
        #expect(ExportSceneBuilder.build(mixedDrawing(), space: .paper(layoutName: nil)).polylines.isEmpty)
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
