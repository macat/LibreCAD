//
//  PropertyPainterTests.swift
//  CADEngineTests
//
//  WAVE 3 — F20 property-painter (UI-shell agent's engine-testable half):
//   - `PaintAttributes` captures a source entity's pen + layer.
//   - `PropertyPainter.apply` stamps those onto a target (geometry/id preserved),
//     honoring the copy-pen / copy-layer options, and returns nil/unchanged for a
//     no-op so the caller drops it from the undo group.
//   - `PropertyPainter.resetPenToLayer` makes an entity inherit its layer's pen.
//
//  Uniquely namespaced (`@Suite("property painter (F20)")`) so it does not collide
//  with the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("property painter (F20)")
struct PropertyPainterTests {

    private func line(id: UInt64, layer: String, pen: Pen) -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: LayerID(layer), pen: pen,
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
    }

    private var redExplicit: Pen {
        Pen(lineColor: .explicit(RGBAColor(1, 0, 0)), lineType: .dashed, lineWidth: .millimeters(0.5))
    }

    // MARK: - Capture

    @Test("PaintAttributes captures pen + layer from a source")
    func captureFromSource() {
        let src = line(id: 1, layer: "Walls", pen: redExplicit)
        let brush = PaintAttributes(from: src)
        #expect(brush.layer.name == "Walls")
        #expect(brush.pen == redExplicit)
    }

    // MARK: - Apply (both, pen-only, layer-only)

    @Test("apply stamps pen + layer onto a target, preserving id + geometry")
    func applyBoth() {
        let src = line(id: 1, layer: "Walls", pen: redExplicit)
        let dst = line(id: 2, layer: "0", pen: .byLayer)
        let brush = PaintAttributes(from: src)

        let painted = PropertyPainter.apply(brush, to: dst)
        #expect(painted.id == EntityID(2))           // id preserved
        #expect(painted.kind == dst.kind)            // geometry preserved
        #expect(painted.layer.name == "Walls")       // layer copied
        #expect(painted.pen == redExplicit)          // pen copied
    }

    @Test("apply with copyLayer off keeps the target's layer")
    func applyPenOnly() {
        let brush = PaintAttributes(from: line(id: 1, layer: "Walls", pen: redExplicit))
        let dst = line(id: 2, layer: "0", pen: .byLayer)
        let painted = PropertyPainter.apply(brush, to: dst,
                                            options: .init(copyPen: true, copyLayer: false))
        #expect(painted.layer.name == "0")           // layer NOT copied
        #expect(painted.pen == redExplicit)          // pen copied
    }

    @Test("apply with copyPen off keeps the target's pen")
    func applyLayerOnly() {
        let brush = PaintAttributes(from: line(id: 1, layer: "Walls", pen: redExplicit))
        let dst = line(id: 2, layer: "0", pen: .byLayer)
        let painted = PropertyPainter.apply(brush, to: dst,
                                            options: .init(copyPen: false, copyLayer: true))
        #expect(painted.layer.name == "Walls")       // layer copied
        #expect(painted.pen == .byLayer)             // pen NOT copied
    }

    // MARK: - Apply to many (changed-only)

    @Test("apply to a list returns only the records that actually changed")
    func applyToManyChangedOnly() {
        let brush = PaintAttributes(from: line(id: 1, layer: "Walls", pen: redExplicit))
        let already = line(id: 2, layer: "Walls", pen: redExplicit)  // already matches
        let needs = line(id: 3, layer: "0", pen: .byLayer)           // needs paint

        let changed = PropertyPainter.apply(brush, to: [already, needs])
        #expect(changed.count == 1)
        #expect(changed.first?.id == EntityID(3))
    }

    // MARK: - Reset pen to layer

    @Test("resetPenToLayer makes a target inherit its layer's pen")
    func resetPen() {
        let dst = line(id: 2, layer: "Walls", pen: redExplicit)
        let reset = PropertyPainter.resetPenToLayer(dst)
        #expect(reset != nil)
        #expect(reset?.pen == .byLayer)
        #expect(reset?.layer.name == "Walls")        // layer preserved
    }

    @Test("resetPenToLayer is nil for an already-byLayer pen (no-op)")
    func resetPenNoop() {
        let dst = line(id: 2, layer: "Walls", pen: .byLayer)
        #expect(PropertyPainter.resetPenToLayer(dst) == nil)
    }

    @Test("resetPenToLayer over a list returns only the changed records")
    func resetPenManyChangedOnly() {
        let a = line(id: 1, layer: "0", pen: redExplicit)   // changes
        let b = line(id: 2, layer: "0", pen: .byLayer)      // no-op
        let changed = PropertyPainter.resetPenToLayer([a, b])
        #expect(changed.count == 1)
        #expect(changed.first?.id == EntityID(1))
    }
}
