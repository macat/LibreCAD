//
//  AnnotationScaleTests.swift
//  CADEngineTests
//
//  Lane W3b-3bB: ANNOTATION SCALE surfaced in the app. The annotative-text ENGINE
//  path (ResolveContext.annotationScale + TextShaper/MTextShaper height scaling)
//  was already done; this lane added PERSISTENCE ($CANNOSCALE), live STATE
//  (CanvasModel.annotationScale), a StatusBar control, and RENDER threading
//  (LineRenderer passes the scale into makeResolveContext). These tests pin:
//
//   1. `makeResolveContext(annotationScale: 2)` DOUBLES annotative text height
//      while non-annotative text is unchanged — a regression-assert of the engine
//      path through the drawing-backed resolve context (not just the raw struct).
//   2. The `$CANNOSCALE` GraphicVariables accessor ROUND-TRIPS (save → reopen via
//      the Codable graphic-vars path the DXFPayload / CADDrawing.load uses).
//   3. The DEFAULT annotation scale 1.0 leaves the render resolve-context's
//      annotative output BYTE-IDENTICAL to the no-scale path (the renderer's
//      default = 1.0 guard: annotative text drawn at its authored height).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Annotation scale (W3b-3bB)")
struct AnnotationScaleTests {

    // MARK: - Helpers

    /// The vertical ink extent of resolved text geometry (fills + strokes), so the
    /// test works for both native (fill) and stroke fonts.
    private func height(_ geo: ResolvedGeometry) -> Double {
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for f in geo.fills { for loop in f.loops { for p in loop { lo = min(lo, p.y); hi = max(hi, p.y) } } }
        for pl in geo.polylines { for p in pl.points { lo = min(lo, p.y); hi = max(hi, p.y) } }
        return hi - lo
    }

    /// A drawing whose STYLE table has an annotative "Anno" style and a plain
    /// non-annotative "Plain" style, so `makeResolveContext` resolves both through
    /// the real `textStyleProvider` (mirrors how a loaded document resolves).
    @MainActor
    private func drawingWithAnnotativeStyle() -> CADDrawing {
        let d = CADDrawing()
        _ = d.textStyles.upsert(TextStyle(name: "Anno",
                                          primaryFont: .native(family: "Helvetica Neue"),
                                          annotative: true))
        _ = d.textStyles.upsert(TextStyle(name: "Plain",
                                          primaryFont: .native(family: "Helvetica Neue"),
                                          annotative: false))
        return d
    }

    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)

    // MARK: - (1) makeResolveContext(annotationScale:) scales annotative text

    @Test("makeResolveContext(annotationScale: 2) doubles annotative text height")
    @MainActor
    func annotativeScalesThroughDrawingContext() {
        let drawing = drawingWithAnnotativeStyle()
        let data = TextData(position: Vector(0, 0), height: 10, text: "O", styleName: "Anno")

        let ctx1 = drawing.makeResolveContext(tessellationTolerance: 0.01, annotationScale: 1.0)
        let ctx2 = drawing.makeResolveContext(tessellationTolerance: 0.01, annotationScale: 2.0)

        let h1 = height(EntityKind.text(data).resolve(pen: pen, ctx: ctx1))
        let h2 = height(EntityKind.text(data).resolve(pen: pen, ctx: ctx2))

        #expect(h1 > 0)
        #expect(abs(h2 / h1 - 2.0) < 0.05)   // scale 2.0 ⇒ ~2× height
    }

    @Test("a non-annotative style ignores the drawing's annotation scale")
    @MainActor
    func nonAnnotativeUnaffectedThroughDrawingContext() {
        let drawing = drawingWithAnnotativeStyle()
        let data = TextData(position: Vector(0, 0), height: 10, text: "O", styleName: "Plain")

        let ctx1 = drawing.makeResolveContext(tessellationTolerance: 0.01, annotationScale: 1.0)
        let ctx2 = drawing.makeResolveContext(tessellationTolerance: 0.01, annotationScale: 3.0)

        let h1 = height(EntityKind.text(data).resolve(pen: pen, ctx: ctx1))
        let h2 = height(EntityKind.text(data).resolve(pen: pen, ctx: ctx2))

        #expect(h1 > 0)
        #expect(abs(h2 / h1 - 1.0) < 0.02)   // unchanged
    }

    // MARK: - (2) $CANNOSCALE accessor round-trips (save → reopen)

    @Test("the $CANNOSCALE accessor reads/writes the header var")
    func cannoscaleAccessorReadsWrites() {
        var vars = GraphicVariables()
        #expect(vars.annotationScale == 1.0)        // default 1:1
        vars.annotationScale = 1.0 / 50              // 1:50
        #expect(abs(vars.annotationScale - 0.02) < 1e-12)
        #expect(vars.get("$CANNOSCALE")?.doubleValue == 1.0 / 50)
    }

    @Test("$CANNOSCALE round-trips through the Codable graphic-vars path")
    func cannoscaleRoundTrips() throws {
        var vars = GraphicVariables()
        vars.annotationScale = 1.0 / 20             // 1:20
        // The DXFPayload / CADDrawing.load persistence path is Codable on the bag.
        let data = try JSONEncoder().encode(vars)
        let reopened = try JSONDecoder().decode(GraphicVariables.self, from: data)
        #expect(abs(reopened.annotationScale - (1.0 / 20)) < 1e-12)
    }

    @Test("$CANNOSCALE survives a drawing save → reopen via mutateGraphicVariables")
    @MainActor
    func cannoscaleRoundTripsThroughDrawing() throws {
        let drawing = CADDrawing()
        drawing.mutateGraphicVariables { $0.annotationScale = 1.0 / 100 }   // 1:100
        #expect(abs(drawing.graphicVariables.annotationScale - 0.01) < 1e-12)
        // Reopen: encode the bag (the payload carrier) and decode into a fresh drawing.
        let data = try JSONEncoder().encode(drawing.graphicVariables)
        let reopened = CADDrawing()
        reopened.graphicVariables = try JSONDecoder().decode(GraphicVariables.self, from: data)
        #expect(abs(reopened.graphicVariables.annotationScale - 0.01) < 1e-12)
    }

    // MARK: - (3) default 1.0 leaves the render resolve-context byte-identical

    @Test("default annotationScale 1.0 == no-arg context for annotative output")
    @MainActor
    func defaultScaleIsByteIdentical() {
        let drawing = drawingWithAnnotativeStyle()
        let data = TextData(position: Vector(0, 0), height: 10, text: "Ag", styleName: "Anno")

        // The render path's DEFAULT (model.annotationScale == 1.0) must match the
        // no-annotation-scale resolve context EXACTLY — annotative text at its
        // authored height, so existing LineInstances are unchanged.
        let ctxDefault = drawing.makeResolveContext(tessellationTolerance: 0.01)
        let ctxOne     = drawing.makeResolveContext(tessellationTolerance: 0.01, annotationScale: 1.0)

        let geoDefault = EntityKind.text(data).resolve(pen: pen, ctx: ctxDefault)
        let geoOne     = EntityKind.text(data).resolve(pen: pen, ctx: ctxOne)

        #expect(geoDefault.fills.count == geoOne.fills.count)
        #expect(geoDefault.polylines.count == geoOne.polylines.count)
        #expect(height(geoDefault) > 0)
        // Byte-identical vertex geometry (the height-scale is the only difference a
        // non-unit scale would make, and 1.0 makes none).
        #expect(abs(height(geoDefault) - height(geoOne)) < 1e-12)
        for (a, b) in zip(geoDefault.fills, geoOne.fills) {
            #expect(a.loops.count == b.loops.count)
            for (la, lb) in zip(a.loops, b.loops) {
                #expect(la.count == lb.count)
                for (pa, pb) in zip(la, lb) {
                    #expect(pa.x == pb.x)
                    #expect(pa.y == pb.y)
                }
            }
        }
    }

    @Test("ResolveContext.annotationScale defaults to 1.0")
    func resolveContextDefaultIsOne() {
        #expect(ResolveContext().annotationScale == 1.0)
        #expect(ResolveContext.default.annotationScale == 1.0)
    }
}
