//
//  RendererVisibilityTests.swift
//  CADEngineTests
//
//  Unit tests for the renderer's GPU-FREE layer-visibility filter
//  (`RendererVisibility.isRendered`), the predicate `LineRenderer.packEntity`
//  consults to decide whether an entity contributes geometry. This is what makes
//  the sidebar's eye toggle actually HIDE pixels: an entity on a hidden/frozen
//  layer is dropped before its geometry is resolved, so neither line instances nor
//  fill triangles reach the GPU.
//
//  The renderer itself is `@MainActor`/Metal-bound and not directly unit-testable,
//  so the load-bearing filter is extracted into the GPU-free `RendererVisibility`
//  and compiled here via the same symlink trick as `RendererCullTests`
//  (`_SharedRendererVisibility.swift`). The "rendered set excludes hidden-layer
//  entities" test simulates the exact packEntity filter loop over a small drawing.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import CADEngine

@Suite("Renderer layer-visibility filter")
struct RendererVisibilityTests {

    /// A layer table with a visible "0", a hidden "hidden", and a visible "shown".
    private func makeLayers() -> LayerTable {
        var t = LayerTable(
            layers: [Layer(name: "0"), Layer(name: "hidden"), Layer(name: "shown")],
            activeLayerName: "0"
        )
        t.setVisible("hidden", false)   // freeze == hide
        return t
    }

    // MARK: - The pure predicate.

    @Test("a visible layer renders; a hidden (frozen) layer does not")
    func predicateHidesFrozenLayer() {
        let layers = makeLayers()
        #expect(RendererVisibility.isRendered(LayerID("0"), in: layers))
        #expect(RendererVisibility.isRendered(LayerID("shown"), in: layers))
        #expect(!RendererVisibility.isRendered(LayerID("hidden"), in: layers))
    }

    @Test("an entity on an UNKNOWN layer still renders (default-pen fallback)")
    func predicateRendersUnknownLayer() {
        let layers = makeLayers()
        // No record for "ghost" → not hidden → drawn (matches resolve()'s fallback).
        #expect(RendererVisibility.isRendered(LayerID("ghost"), in: layers))
    }

    @Test("toggling a layer's visibility flips whether it renders")
    func predicateFollowsToggle() {
        var layers = makeLayers()
        #expect(RendererVisibility.isRendered(LayerID("shown"), in: layers))
        layers.toggleVisible("shown")    // hide it
        #expect(!RendererVisibility.isRendered(LayerID("shown"), in: layers))
        layers.toggleVisible("shown")    // show it again
        #expect(RendererVisibility.isRendered(LayerID("shown"), in: layers))
    }

    // MARK: - The rendered SET excludes hidden-layer entities.

    /// Mirrors `LineRenderer.packEntity`'s filter loop: entities on a hidden layer
    /// are excluded from the set whose geometry would be packed into the instance /
    /// fill buffers. Uses LINE (line instances) and HATCH (fill triangles) so the
    /// exclusion is proven for BOTH the line AND the fill path.
    @Test("the rendered set excludes entities on a hidden layer (lines and fills)")
    func renderedSetExcludesHiddenLayer() {
        let layers = makeLayers()

        let visibleLine = EntityRecord(
            id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        )
        let hiddenLine = EntityRecord(
            id: EntityID(2), layer: LayerID("hidden"),
            kind: .line(LineData(start: Vector(0, 5), end: Vector(10, 5)))
        )
        let visibleHatch = EntityRecord(
            id: EntityID(3), layer: LayerID("shown"),
            kind: .hatch(HatchData(
                loops: [[
                    PolylineVertex(point: Vector(0, 0)),
                    PolylineVertex(point: Vector(4, 0)),
                    PolylineVertex(point: Vector(4, 4)),
                    PolylineVertex(point: Vector(0, 4)),
                ]],
                solidFill: true
            ))
        )
        let hiddenHatch = EntityRecord(
            id: EntityID(4), layer: LayerID("hidden"),
            kind: .hatch(HatchData(
                loops: [[
                    PolylineVertex(point: Vector(10, 10)),
                    PolylineVertex(point: Vector(14, 10)),
                    PolylineVertex(point: Vector(14, 14)),
                    PolylineVertex(point: Vector(10, 14)),
                ]],
                solidFill: true
            ))
        )
        let all = [visibleLine, hiddenLine, visibleHatch, hiddenHatch]

        // The packEntity filter: keep only entities whose layer renders.
        let rendered = all.filter { RendererVisibility.isRendered($0.layer, in: layers) }

        #expect(rendered.count == 2)
        #expect(rendered.contains { $0.id == EntityID(1) })   // visible line kept
        #expect(rendered.contains { $0.id == EntityID(3) })   // visible hatch kept
        #expect(!rendered.contains { $0.id == EntityID(2) })  // hidden line dropped
        #expect(!rendered.contains { $0.id == EntityID(4) })  // hidden hatch dropped
    }
}
