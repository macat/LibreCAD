//
//  LiveDimensionTests.swift
//  CADEngineTests
//
//  W1a — the ENGINE SEAM for AutoCAD-style live dimensional feedback. Covers ONLY
//  the additive value types (`LiveDimension` / its `Kind` / `LiveDimensionContext`)
//  and the append-only `Tool.liveDimensions(_:)` protocol member with its default
//  `[]` extension — the SAME additive pattern as `Tool.referenceSegments`.
//
//  Per-tool overrides (Line / Circle / Rectangle showing real numbers) and the
//  overlay rendering come in LATER waves; this suite asserts only the contract:
//   - a tool that does NOT override `liveDimensions` inherits the empty default;
//   - the value types construct + Equate (incl. every `Kind` case);
//   - `LiveDimensionContext` carries the formatter inputs and has sane defaults.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("LiveDimension engine seam")
struct LiveDimensionTests {

    // MARK: - Default protocol member (additive: tools inherit "none")

    /// A real conforming tool that does NOT override `liveDimensions` must inherit
    /// the empty default — exactly like `referenceSegments`. `LineTool` is one such
    /// tool (it has no override in W1a), so it proves the additive default reaches
    /// every existing tool with zero per-tool change.
    @Test("a non-overriding tool inherits the empty default")
    func defaultLiveDimensionsIsEmpty() {
        let tool = LineTool()
        #expect(tool.liveDimensions(.default).isEmpty)
        // Stable across a non-default context too (the default ignores its argument).
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 2,
                                       unit: .inch, angleFormat: .radians, anglePrecision: 3)
        #expect(tool.liveDimensions(ctx).isEmpty)
    }

    /// The default is reachable through the protocol existential too (the way the
    /// app holds the active tool), not only the concrete type.
    @Test("default reaches the tool through the protocol existential")
    func defaultThroughExistential() {
        let tool: any Tool = LineTool()
        #expect(tool.liveDimensions(.default).isEmpty)
    }

    // MARK: - LiveDimension value type construction + Equatable

    @Test("LiveDimension constructs and exposes its fields")
    func liveDimensionConstructs() {
        let dim = LiveDimension(
            kind: .linear(12.5),
            from: Vector(0, 0),
            to: Vector(12.5, 0),
            label: "12.5",
            labelAnchor: Vector(6.25, 0.5)
        )
        #expect(dim.kind == .linear(12.5))
        #expect(dim.from == Vector(0, 0))
        #expect(dim.to == Vector(12.5, 0))
        #expect(dim.label == "12.5")
        #expect(dim.labelAnchor == Vector(6.25, 0.5))
    }

    @Test("LiveDimension is Equatable (equal + unequal)")
    func liveDimensionEquatable() {
        let a = LiveDimension(kind: .radius(8), from: Vector(0, 0), to: Vector(8, 0),
                              label: "R8", labelAnchor: Vector(4, 0))
        let b = LiveDimension(kind: .radius(8), from: Vector(0, 0), to: Vector(8, 0),
                              label: "R8", labelAnchor: Vector(4, 0))
        #expect(a == b)

        // Differ in label only → unequal (the label is part of identity).
        let c = LiveDimension(kind: .radius(8), from: Vector(0, 0), to: Vector(8, 0),
                              label: "R8.0", labelAnchor: Vector(4, 0))
        #expect(a != c)
        // Differ in kind only → unequal.
        let d = LiveDimension(kind: .diameter(8), from: Vector(0, 0), to: Vector(8, 0),
                              label: "R8", labelAnchor: Vector(4, 0))
        #expect(a != d)
    }

    // MARK: - LiveDimension.Kind — every case constructs + Equates

    @Test("every Kind case constructs and Equates")
    func kindCasesEquate() {
        #expect(LiveDimension.Kind.linear(1) == .linear(1))
        #expect(LiveDimension.Kind.radius(2) == .radius(2))
        #expect(LiveDimension.Kind.diameter(3) == .diameter(3))
        #expect(LiveDimension.Kind.angle(.pi / 4) == .angle(.pi / 4))
        #expect(LiveDimension.Kind.size(w: 4, h: 5) == .size(w: 4, h: 5))

        // Distinct cases / payloads are unequal.
        #expect(LiveDimension.Kind.linear(1) != .radius(1))
        #expect(LiveDimension.Kind.size(w: 4, h: 5) != .size(w: 5, h: 4))
        #expect(LiveDimension.Kind.angle(0) != .angle(.pi))
    }

    // MARK: - LiveDimensionContext value type + defaults

    @Test("LiveDimensionContext constructs from explicit values")
    func contextConstructs() {
        let ctx = LiveDimensionContext(
            linearFormat: .engineering,
            linearPrecision: 3,
            unit: .millimeter,
            angleFormat: .degreesMinutesSeconds,
            anglePrecision: 1
        )
        #expect(ctx.linearFormat == .engineering)
        #expect(ctx.linearPrecision == 3)
        #expect(ctx.unit == .millimeter)
        #expect(ctx.angleFormat == .degreesMinutesSeconds)
        #expect(ctx.anglePrecision == 1)
    }

    @Test("LiveDimensionContext.default matches the formatter defaults")
    func contextDefaults() {
        let ctx = LiveDimensionContext.default
        #expect(ctx.linearFormat == .decimal)
        #expect(ctx.linearPrecision == 4)
        #expect(ctx.unit == .none)
        #expect(ctx.angleFormat == .degreesDecimal)
        #expect(ctx.anglePrecision == 4)
        // The no-arg initializer agrees with `.default`.
        #expect(LiveDimensionContext() == ctx)
    }

    @Test("LiveDimensionContext is Equatable (equal + unequal)")
    func contextEquatable() {
        let a = LiveDimensionContext(linearFormat: .decimal, linearPrecision: 4,
                                     unit: .none, angleFormat: .degreesDecimal, anglePrecision: 4)
        #expect(a == LiveDimensionContext.default)
        let b = LiveDimensionContext(linearFormat: .decimal, linearPrecision: 2,
                                     unit: .none, angleFormat: .degreesDecimal, anglePrecision: 4)
        #expect(a != b)
    }

    // MARK: - The label stays a plain engine-formatted String (UI-free)

    /// The label is PRE-FORMATTED in-engine; a tool would build it with
    /// `CoordinateFormatter` from a context. Prove the seam composes with the real
    /// formatter (no AppKit/SwiftUI), so a W1b tool can produce a stable label.
    @Test("label composes with CoordinateFormatter using context inputs")
    func labelFromFormatter() {
        let ctx = LiveDimensionContext.default
        let label = CoordinateFormatter.length(12.5,
                                               format: ctx.linearFormat,
                                               precision: ctx.linearPrecision,
                                               unit: ctx.unit)
        let dim = LiveDimension(kind: .linear(12.5), from: Vector(0, 0), to: Vector(12.5, 0),
                                label: label, labelAnchor: Vector(6.25, 0))
        #expect(dim.label == "12.5")
    }

    // MARK: - W1b: per-tool live-dimension overrides
    //
    // Each draw tool overrides `liveDimensions(_:)` to read its EXISTING State +
    // cursor (zero new fields — exactly like `preview`). These tests drive a tool
    // into its drag state with a known cursor and assert the emitted kind, the
    // from/to dim-line endpoints, and the PRE-FORMATTED label (with an architectural
    // assert proving the format threads through `ctx`), plus the empty invariant
    // before the first pick and after commit.

    /// Drives a tool through `.move` to seed the cursor, returning the (mutated) tool.
    /// Inputs are pure world points; no GUI/CADDrawing is touched.
    private func drive<T: Tool>(_ tool: T, _ inputs: [ToolInput]) -> T {
        var t = tool
        for i in inputs { _ = t.handle(i, context: .empty) }
        return t
    }

    // MARK: LineTool — length (.linear) + angle (.angle)

    @Test("LineTool emits length + angle while dragging the next segment")
    func lineLiveDimensions() {
        // Fix the start at the origin, drag the cursor to (30, 0).
        let tool = drive(LineTool(), [.click(Vector(0, 0)), .move(Vector(30, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 2)

        // First descriptor: the running length along the segment.
        #expect(dims[0].kind == .linear(30))
        #expect(dims[0].from == Vector(0, 0))
        #expect(dims[0].to == Vector(30, 0))
        #expect(dims[0].label == "30")                       // decimal default
        #expect(dims[0].labelAnchor == Vector(15, 0))        // segment midpoint

        // Second descriptor: the segment angle near the cursor end.
        #expect(dims[1].kind == .angle(0))
        #expect(dims[1].from == Vector(0, 0))
        #expect(dims[1].to == Vector(30, 0))
        #expect(dims[1].label == "0°")                       // decimal-degrees default
        #expect(dims[1].labelAnchor == Vector(30, 0))        // near the cursor
    }

    /// The architectural format MUST thread from `ctx` into the label: a 30-inch
    /// segment renders `2'-6"` (2 feet 6 inches). This proves the tool formats the
    /// label IN-ENGINE from the passed context, not with a hard-coded format.
    @Test("LineTool length label honors an architectural context")
    func lineLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        let tool = drive(LineTool(), [.click(Vector(0, 0)), .move(Vector(30, 0))])
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .linear(30))
        #expect(dims.first?.label == "2'-6\"")
    }

    @Test("LineTool emits nothing before the first pick and after commit")
    func lineLiveDimensionsEmptyOutsideDrag() {
        // Before the first pick: fresh tool, no fixed point.
        #expect(LineTool().liveDimensions(.default).isEmpty)
        // After moving but still before the first click → still empty.
        #expect(drive(LineTool(), [.move(Vector(30, 0))]).liveDimensions(.default).isEmpty)
        // After committing a segment (second click) the run chains from the endpoint
        // with `last == cursor == end`, so the length is zero ⇒ empty until the next
        // move. (Mirrors the commit guard / the empty-after-commit invariant.)
        let after = drive(LineTool(), [.click(Vector(0, 0)), .click(Vector(30, 0))])
        #expect(after.liveDimensions(.default).isEmpty)
        // And a cancelled run is back to the initial empty state.
        let cancelled = drive(LineTool(), [.click(Vector(0, 0)), .move(Vector(30, 0)), .cancel])
        #expect(cancelled.liveDimensions(.default).isEmpty)
    }

    // MARK: CircleTool — radius / diameter

    @Test("CircleTool emits the radius while dragging (center+radius mode)")
    func circleLiveDimensionsRadius() {
        let tool = drive(CircleTool(), [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .radius(8))
        #expect(dims[0].from == Vector(0, 0))                // center
        #expect(dims[0].to == Vector(8, 0))                  // cursor
        #expect(dims[0].label == "8")
    }

    @Test("CircleTool reports the full diameter in diameter size mode")
    func circleLiveDimensionsDiameter() {
        var tool = CircleTool()
        tool.sizeMode = .diameter
        tool = drive(tool, [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .diameter(16))               // 2 × radius
        #expect(dims[0].label == "16")
    }

    @Test("CircleTool radius label honors an architectural context")
    func circleLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        // radius 30" → 2'-6"
        let tool = drive(CircleTool(), [.click(Vector(0, 0)), .move(Vector(30, 0))])
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .radius(30))
        #expect(dims.first?.label == "2'-6\"")
    }

    @Test("CircleTool 2-point (diameter) mode reads the computed radius")
    func circleLiveDimensionsTwoPoint() {
        // Diameter endpoints (0,0)→(8,0): center (4,0), radius 4.
        let tool = drive(CircleTool(mode: .twoPoint),
                         [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .radius(4))
        #expect(dims[0].from == Vector(4, 0))                // computed center
        #expect(dims[0].label == "4")
    }

    @Test("CircleTool emits nothing before the center and after commit")
    func circleLiveDimensionsEmptyOutsideDrag() {
        #expect(CircleTool().liveDimensions(.default).isEmpty)
        #expect(drive(CircleTool(), [.move(Vector(8, 0))]).liveDimensions(.default).isEmpty)
        // After committing (second click) the tool reset()s to .settingCenter.
        let after = drive(CircleTool(), [.click(Vector(0, 0)), .click(Vector(8, 0))])
        #expect(after.liveDimensions(.default).isEmpty)
    }

    // MARK: RectangleTool — size (W × H)

    @Test("RectangleTool emits W × H while dragging the opposite corner")
    func rectangleLiveDimensions() {
        let tool = drive(RectangleTool(), [.click(Vector(0, 0)), .move(Vector(10, 4))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .size(w: 10, h: 4))
        #expect(dims[0].from == Vector(0, 0))                // first corner
        #expect(dims[0].to == Vector(10, 4))                 // cursor corner
        #expect(dims[0].label == "10 × 4")
        #expect(dims[0].labelAnchor == Vector(10, 4))        // near the cursor corner
    }

    @Test("RectangleTool reports unsigned extents regardless of drag direction")
    func rectangleLiveDimensionsUnsigned() {
        // Drag down-left: cursor below/left of the first corner.
        let tool = drive(RectangleTool(), [.click(Vector(10, 4)), .move(Vector(0, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.first?.kind == .size(w: 10, h: 4))      // |Δx|, |Δy|
    }

    @Test("RectangleTool size label honors an architectural context")
    func rectangleLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        // 30" × 12" → 2'-6" × 1'-0"
        let tool = drive(RectangleTool(), [.click(Vector(0, 0)), .move(Vector(30, 12))])
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .size(w: 30, h: 12))
        #expect(dims.first?.label == "2'-6\" × 1'-0\"")
    }

    @Test("RectangleTool emits nothing before the first corner and after commit")
    func rectangleLiveDimensionsEmptyOutsideDrag() {
        #expect(RectangleTool().liveDimensions(.default).isEmpty)
        #expect(drive(RectangleTool(), [.move(Vector(10, 4))]).liveDimensions(.default).isEmpty)
        // After committing (second click) the tool reset()s to .settingFirst.
        let after = drive(RectangleTool(), [.click(Vector(0, 0)), .click(Vector(10, 4))])
        #expect(after.liveDimensions(.default).isEmpty)
    }

    // MARK: PolygonTool — radius with N sides in the label

    @Test("PolygonTool emits the reference radius with the side count in the label")
    func polygonLiveDimensions() {
        var tool = PolygonTool()
        tool.sides = 6
        tool = drive(tool, [.click(Vector(0, 0)), .move(Vector(12, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .radius(12))
        #expect(dims[0].from == Vector(0, 0))                // center
        #expect(dims[0].to == Vector(12, 0))                 // cursor
        #expect(dims[0].label == "r=12  N=6")
        #expect(dims[0].labelAnchor == Vector(6, 0))         // center→cursor midpoint
    }

    @Test("PolygonTool radius label honors an architectural context + side count")
    func polygonLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        var tool = PolygonTool()
        tool.sides = 5
        tool = drive(tool, [.click(Vector(0, 0)), .move(Vector(30, 0))])   // 30" → 2'-6"
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .radius(30))
        #expect(dims.first?.label == "r=2'-6\"  N=5")
    }

    @Test("PolygonTool edge mode has no center→radius semantics")
    func polygonLiveDimensionsEdgeModeEmpty() {
        var tool = PolygonTool()
        tool.mode = .edge
        tool = drive(tool, [.click(Vector(0, 0)), .move(Vector(12, 0))])
        #expect(tool.liveDimensions(.default).isEmpty)
    }

    @Test("PolygonTool emits nothing before the center and after commit")
    func polygonLiveDimensionsEmptyOutsideDrag() {
        #expect(PolygonTool().liveDimensions(.default).isEmpty)
        #expect(drive(PolygonTool(), [.move(Vector(12, 0))]).liveDimensions(.default).isEmpty)
        // After committing (second click) the tool reset()s to .settingCenter.
        let after = drive(PolygonTool(), [.click(Vector(0, 0)), .click(Vector(12, 0))])
        #expect(after.liveDimensions(.default).isEmpty)
    }
}
