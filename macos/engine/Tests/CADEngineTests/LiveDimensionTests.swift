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

    /// A plain dim built WITHOUT the new editing args defaults to "not an editable
    /// field": `field == nil`, `isEditable == false`, `editState == .idle`,
    /// `typedString == nil` — so every pre-existing emit site is unchanged.
    @Test("LiveDimension's editing fields default to a non-editable idle dim")
    func liveDimensionEditingFieldDefaults() {
        let dim = LiveDimension(kind: .linear(5), from: Vector(0, 0), to: Vector(5, 0),
                                label: "5", labelAnchor: Vector(2.5, 0))
        #expect(dim.field == nil)
        #expect(dim.isEditable == false)
        #expect(dim.editState == .idle)
        #expect(dim.typedString == nil)
    }

    /// `withEditing` replaces ONLY `editState` + `typedString`, preserving every other
    /// field (kind / geometry / label / `field` / `isEditable`) — the seam the model
    /// uses to re-stamp a tool-emitted dim with live editing display state.
    @Test("withEditing copies editState + typedString and preserves everything else")
    func liveDimensionWithEditing() {
        let base = LiveDimension(kind: .linear(5), from: Vector(0, 0), to: Vector(5, 0),
                                 label: "5", labelAnchor: Vector(2.5, 0),
                                 field: .width, isEditable: true)
        let edited = base.withEditing(editState: .active, typedString: "12")
        // Replaced.
        #expect(edited.editState == .active)
        #expect(edited.typedString == "12")
        // Preserved.
        #expect(edited.kind == .linear(5))
        #expect(edited.from == Vector(0, 0))
        #expect(edited.to == Vector(5, 0))
        #expect(edited.label == "5")
        #expect(edited.labelAnchor == Vector(2.5, 0))
        #expect(edited.field == .width)
        #expect(edited.isEditable)
        // A second re-stamp can clear the buffer / move to locked.
        let locked = edited.withEditing(editState: .locked, typedString: "12")
        #expect(locked.editState == .locked)
        #expect(locked.typedString == "12")
        let cleared = edited.withEditing(editState: .idle, typedString: nil)
        #expect(cleared.editState == .idle)
        #expect(cleared.typedString == nil)
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

    /// Asserts two vectors agree to a tight tolerance — for dim endpoints that round
    /// through cos/sin (e.g. an on-circle point at a typed angle), where exact `==`
    /// is brittle (`cos(π/2)` is `6.12e-16`, not `0`).
    private func nearVec(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9,
                         sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(a.x - b.x) <= tol, "x: \(a.x) vs \(b.x)", sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) <= tol, "y: \(a.y) vs \(b.y)", sourceLocation: sourceLocation)
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

    /// Only the interactive center+radius dim is editable; the 2P/3P derived radii have
    /// no well-defined typed direction, so they stay read-only (`field == nil`,
    /// `isEditable == false`). The center+radius dim, by contrast, IS editable.
    @Test("CircleTool: only the center+radius dim is editable (2P/3P stay read-only)")
    func circleLiveDimensionsEditability() {
        // center+radius → editable, field `.radius`.
        let cr = drive(CircleTool(), [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let crDims = cr.liveDimensions(.default)
        #expect(crDims.count == 1)
        #expect(crDims[0].field == .radius)
        #expect(crDims[0].isEditable)

        // center+radius in diameter size mode → editable, field `.diameter`.
        var crd = CircleTool()
        crd.sizeMode = .diameter
        crd = drive(crd, [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let crdDims = crd.liveDimensions(.default)
        #expect(crdDims[0].field == .diameter)
        #expect(crdDims[0].isEditable)

        // 2-point mode → NOT editable.
        let twoP = drive(CircleTool(mode: .twoPoint),
                         [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let twoPDims = twoP.liveDimensions(.default)
        #expect(twoPDims.count == 1)
        #expect(twoPDims[0].field == nil)
        #expect(twoPDims[0].isEditable == false)

        // 3-point mode → NOT editable.
        let threeP = drive(CircleTool(mode: .threePoint),
                           [.click(Vector(0, 0)), .click(Vector(8, 0)), .move(Vector(4, 4))])
        let threePDims = threeP.liveDimensions(.default)
        #expect(threePDims.count == 1)
        #expect(threePDims[0].field == nil)
        #expect(threePDims[0].isEditable == false)
    }

    @Test("CircleTool emits nothing before the center and after commit")
    func circleLiveDimensionsEmptyOutsideDrag() {
        #expect(CircleTool().liveDimensions(.default).isEmpty)
        #expect(drive(CircleTool(), [.move(Vector(8, 0))]).liveDimensions(.default).isEmpty)
        // After committing (second click) the tool reset()s to .settingCenter.
        let after = drive(CircleTool(), [.click(Vector(0, 0)), .click(Vector(8, 0))])
        #expect(after.liveDimensions(.default).isEmpty)
    }

    // MARK: RectangleTool — TWO editable edge dims (width + height)
    //
    // A rectangle has two independent dimensions, so the tool now emits TWO `.linear`
    // dim lines (the bottom-edge WIDTH and the right-edge HEIGHT) the user can Tab
    // between and type into — replacing the old single diagonal `.size` readout.

    @Test("RectangleTool emits width + height edge dims while dragging the opposite corner")
    func rectangleLiveDimensions() {
        let tool = drive(RectangleTool(), [.click(Vector(0, 0)), .move(Vector(10, 4))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 2)

        // WIDTH: the bottom edge, first → (cursor.x, first.y), editable, field `.width`.
        #expect(dims[0].kind == .linear(10))
        #expect(dims[0].from == Vector(0, 0))                // first corner
        #expect(dims[0].to == Vector(10, 0))                 // along the bottom edge
        #expect(dims[0].label == "10")                       // decimal default
        #expect(dims[0].labelAnchor == Vector(5, 0))         // bottom-edge midpoint
        #expect(dims[0].field == .width)
        #expect(dims[0].isEditable)

        // HEIGHT: the right edge, (cursor.x, first.y) → cursor, editable, field `.height`.
        #expect(dims[1].kind == .linear(4))
        #expect(dims[1].from == Vector(10, 0))               // bottom-right corner
        #expect(dims[1].to == Vector(10, 4))                 // cursor corner
        #expect(dims[1].label == "4")
        #expect(dims[1].labelAnchor == Vector(10, 2))        // right-edge midpoint
        #expect(dims[1].field == .height)
        #expect(dims[1].isEditable)
    }

    @Test("RectangleTool reports unsigned extents regardless of drag direction")
    func rectangleLiveDimensionsUnsigned() {
        // Drag down-left: cursor below/left of the first corner.
        let tool = drive(RectangleTool(), [.click(Vector(10, 4)), .move(Vector(0, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 2)
        // Extents are unsigned (|Δx|, |Δy|), regardless of drag direction.
        #expect(dims[0].kind == .linear(10))                 // width = |Δx|
        #expect(dims[0].field == .width)
        #expect(dims[1].kind == .linear(4))                  // height = |Δy|
        #expect(dims[1].field == .height)
        // The edge geometry follows the (down-left) cursor corner.
        #expect(dims[0].from == Vector(10, 4))               // first corner
        #expect(dims[0].to == Vector(0, 4))                  // bottom edge toward cursor.x
        #expect(dims[1].from == Vector(0, 4))
        #expect(dims[1].to == Vector(0, 0))                  // cursor corner
    }

    @Test("RectangleTool edge dim labels honor an architectural context")
    func rectangleLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        // 30" × 12" → width 2'-6", height 1'-0"
        let tool = drive(RectangleTool(), [.click(Vector(0, 0)), .move(Vector(30, 12))])
        let dims = tool.liveDimensions(ctx)
        #expect(dims.count == 2)
        #expect(dims[0].kind == .linear(30))
        #expect(dims[0].label == "2'-6\"")                   // width
        #expect(dims[1].kind == .linear(12))
        #expect(dims[1].label == "1'-0\"")                   // height
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

    // MARK: PolylineTool — current segment length (.linear) + angle (.angle)
    //
    // A polyline mid-draw is a chain of straight segments, so it reports the SAME
    // per-segment length+angle readout LineTool does, measured from the LAST placed
    // vertex to the cursor. Both fields editable; Tab order [length, angle].

    @Test("PolylineTool emits length + angle for the current segment from the last vertex")
    func polylineLiveDimensions() {
        // Place two vertices, then drag the third toward (10, 0) from (5, 5).
        let tool = drive(PolylineTool(),
                         [.click(Vector(0, 0)), .click(Vector(5, 5)), .move(Vector(15, 5))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 2)

        // Length: last vertex (5,5) → cursor (15,5) = 10 along +X.
        #expect(dims[0].kind == .linear(10))
        #expect(dims[0].from == Vector(5, 5))                // last placed vertex
        #expect(dims[0].to == Vector(15, 5))                 // cursor
        #expect(dims[0].label == "10")
        #expect(dims[0].labelAnchor == Vector(10, 5))        // segment midpoint
        #expect(dims[0].field == .length)
        #expect(dims[0].isEditable)

        // Angle: 0° along +X, labeled near the cursor end.
        #expect(dims[1].kind == .angle(0))
        #expect(dims[1].from == Vector(5, 5))
        #expect(dims[1].to == Vector(15, 5))
        #expect(dims[1].label == "0°")
        #expect(dims[1].labelAnchor == Vector(15, 5))
        #expect(dims[1].field == .angle)
        #expect(dims[1].isEditable)
    }

    @Test("PolylineTool length label honors an architectural context")
    func polylineLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        // First segment from origin, drag to (30, 0) → 2'-6".
        let tool = drive(PolylineTool(), [.click(Vector(0, 0)), .move(Vector(30, 0))])
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .linear(30))
        #expect(dims.first?.label == "2'-6\"")
    }

    @Test("PolylineTool emits nothing before the first vertex and after commit")
    func polylineLiveDimensionsEmptyOutsideDrag() {
        // Before the first vertex: fresh tool / a bare move with no fixed vertex.
        #expect(PolylineTool().liveDimensions(.default).isEmpty)
        #expect(drive(PolylineTool(), [.move(Vector(10, 0))]).liveDimensions(.default).isEmpty)
        // A degenerate (cursor on the last vertex) drag → empty.
        let degenerate = drive(PolylineTool(), [.click(Vector(0, 0)), .move(Vector(0, 0))])
        #expect(degenerate.liveDimensions(.default).isEmpty)
        // After commit (Return with ≥2 vertices) the tool reset()s to .empty.
        let after = drive(PolylineTool(),
                          [.click(Vector(0, 0)), .click(Vector(5, 0)), .commit])
        #expect(after.liveDimensions(.default).isEmpty)
        // A cancelled run is back to the empty state too.
        let cancelled = drive(PolylineTool(),
                              [.click(Vector(0, 0)), .move(Vector(5, 0)), .cancel])
        #expect(cancelled.liveDimensions(.default).isEmpty)
    }

    // MARK: ArcTool — center→start→end mode only (conservative coverage)

    @Test("ArcTool settingStart emits an editable radius (center→cursor)")
    func arcLiveDimensionsSettingStart() {
        // Fix the center at the origin, drag the start point toward (8, 0).
        let tool = drive(ArcTool(), [.click(Vector(0, 0)), .move(Vector(8, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .radius(8))
        #expect(dims[0].from == Vector(0, 0))                // center
        #expect(dims[0].to == Vector(8, 0))                  // cursor
        #expect(dims[0].label == "8")
        #expect(dims[0].labelAnchor == Vector(4, 0))         // center→cursor midpoint
        #expect(dims[0].field == .radius)
        #expect(dims[0].isEditable)
    }

    @Test("ArcTool settingEnd emits a read-only radius + an editable end angle")
    func arcLiveDimensionsSettingEnd() {
        // Center (0,0), start (10,0) → radius 10, startAngle 0. Drag end toward +Y.
        let tool = drive(ArcTool(),
                         [.click(Vector(0, 0)), .click(Vector(10, 0)), .move(Vector(0, 5))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 2)

        // Radius: locked at 10, drawn to the on-circle point at the cursor angle (90°)
        // → (0, 10). NON-editable. (The endpoint rounds through cos/sin, so `nearVec`.)
        #expect(dims[0].kind == .radius(10))
        #expect(dims[0].from == Vector(0, 0))
        nearVec(dims[0].to, Vector(0, 10))                   // on-circle at 90°
        #expect(dims[0].label == "10")
        #expect(dims[0].field == nil)
        #expect(dims[0].isEditable == false)

        // End angle: 90° → editable.
        #expect(dims[1].kind == .angle(.pi / 2))
        #expect(dims[1].from == Vector(0, 0))
        nearVec(dims[1].to, Vector(0, 10))
        #expect(dims[1].label == "90°")
        #expect(dims[1].field == .angle)
        #expect(dims[1].isEditable)
    }

    @Test("ArcTool settingStart radius label honors an architectural context")
    func arcLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        let tool = drive(ArcTool(), [.click(Vector(0, 0)), .move(Vector(30, 0))])  // 30" → 2'-6"
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .radius(30))
        #expect(dims.first?.label == "2'-6\"")
    }

    @Test("ArcTool emits nothing in the 3-point and tangential modes")
    func arcLiveDimensionsOtherModesEmpty() {
        // 3-point: drive through start + mid, dragging the end.
        let threeP = drive(ArcTool(mode: .threePoint),
                           [.click(Vector(0, 0)), .click(Vector(10, 0)), .move(Vector(5, 5))])
        #expect(threeP.liveDimensions(.default).isEmpty)
        // Tangential: start + tangent direction, dragging the end.
        let tan = drive(ArcTool(mode: .tangential),
                        [.click(Vector(0, 0)), .click(Vector(1, 0)), .move(Vector(5, 5))])
        #expect(tan.liveDimensions(.default).isEmpty)
    }

    @Test("ArcTool emits nothing before the center and after commit")
    func arcLiveDimensionsEmptyOutsideDrag() {
        #expect(ArcTool().liveDimensions(.default).isEmpty)
        #expect(drive(ArcTool(), [.move(Vector(8, 0))]).liveDimensions(.default).isEmpty)
        // After committing (third click) the tool reset()s to .settingCenter.
        let after = drive(ArcTool(),
                          [.click(Vector(0, 0)), .click(Vector(10, 0)), .click(Vector(0, 10))])
        #expect(after.liveDimensions(.default).isEmpty)
    }

    // MARK: EllipseTool — axis-style modes only (conservative coverage)

    @Test("EllipseTool settingMajor emits an editable major-axis length (center→cursor)")
    func ellipseLiveDimensionsSettingMajor() {
        // Fix the center at the origin, drag the major endpoint toward (12, 0).
        let tool = drive(EllipseTool(), [.click(Vector(0, 0)), .move(Vector(12, 0))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .linear(12))
        #expect(dims[0].from == Vector(0, 0))                // center
        #expect(dims[0].to == Vector(12, 0))                 // cursor
        #expect(dims[0].label == "12")
        #expect(dims[0].labelAnchor == Vector(6, 0))         // center→cursor midpoint
        #expect(dims[0].field == .radius)
        #expect(dims[0].isEditable)
    }

    @Test("EllipseTool settingRatio emits the editable minor (perpendicular) distance")
    func ellipseLiveDimensionsSettingRatio() {
        // Center (0,0), major endpoint (10,0) → majorP (10,0). Drag the minor point to
        // (3, 4): along the major = 3, perpendicular leg = 4 (the minor distance).
        let tool = drive(EllipseTool(),
                         [.click(Vector(0, 0)), .click(Vector(10, 0)), .move(Vector(3, 4))])
        let dims = tool.liveDimensions(.default)
        #expect(dims.count == 1)
        #expect(dims[0].kind == .linear(4))                  // perpendicular distance
        #expect(dims[0].from == Vector(3, 0))                // foot of the perpendicular
        #expect(dims[0].to == Vector(3, 4))                  // cursor
        #expect(dims[0].label == "4")
        #expect(dims[0].labelAnchor == Vector(3, 2))         // foot→cursor midpoint
        #expect(dims[0].field == .length)
        #expect(dims[0].isEditable)
    }

    @Test("EllipseTool major-axis label honors an architectural context")
    func ellipseLiveDimensionArchitecturalLabel() {
        let ctx = LiveDimensionContext(linearFormat: .architectural, linearPrecision: 4,
                                       unit: .inch)
        let tool = drive(EllipseTool(), [.click(Vector(0, 0)), .move(Vector(30, 0))])  // 30" → 2'-6"
        let dims = tool.liveDimensions(ctx)
        #expect(dims.first?.kind == .linear(30))
        #expect(dims.first?.label == "2'-6\"")
    }

    @Test("EllipseTool emits nothing in the foci / 4-point / inscribe modes")
    func ellipseLiveDimensionsOtherModesEmpty() {
        // Foci + point: two foci placed, dragging the on-ellipse point.
        let foci = drive(EllipseTool(mode: .fociPoint),
                         [.click(Vector(-3, 0)), .click(Vector(3, 0)), .move(Vector(0, 4))])
        #expect(foci.liveDimensions(.default).isEmpty)
        // 4-point: three points placed, dragging the fourth.
        let fourP = drive(EllipseTool(mode: .fourPoint),
                          [.click(Vector(5, 0)), .click(Vector(0, 3)),
                           .click(Vector(-5, 0)), .move(Vector(0, -3))])
        #expect(fourP.liveDimensions(.default).isEmpty)
        // Inscribe: three corners placed, dragging the fourth.
        let inscribe = drive(EllipseTool(mode: .inscribeQuad),
                             [.click(Vector(0, 0)), .click(Vector(10, 0)),
                              .click(Vector(10, 6)), .move(Vector(0, 6))])
        #expect(inscribe.liveDimensions(.default).isEmpty)
    }

    @Test("EllipseTool .arc mode: empty during the start/end angle steps")
    func ellipseLiveDimensionsArcAngleStepsEmpty() {
        // .arc shares the axis spine; once the ratio is fixed it advances to the
        // start-angle step (settingArcStart), which carries no clean editable scalar.
        let arcStart = drive(EllipseTool(mode: .arc),
                             [.click(Vector(0, 0)), .click(Vector(10, 0)),
                              .click(Vector(0, 5)), .move(Vector(10, 0))])
        #expect(arcStart.liveDimensions(.default).isEmpty)
        // But the major/ratio steps of .arc DO emit (it shares the axis spine).
        let arcMajor = drive(EllipseTool(mode: .arc),
                             [.click(Vector(0, 0)), .move(Vector(12, 0))])
        #expect(arcMajor.liveDimensions(.default).count == 1)
    }

    @Test("EllipseTool emits nothing before the center and after commit")
    func ellipseLiveDimensionsEmptyOutsideDrag() {
        #expect(EllipseTool().liveDimensions(.default).isEmpty)
        #expect(drive(EllipseTool(), [.move(Vector(12, 0))]).liveDimensions(.default).isEmpty)
        // After committing (third click) the tool reset()s to .settingCenter.
        let after = drive(EllipseTool(),
                          [.click(Vector(0, 0)), .click(Vector(10, 0)), .click(Vector(0, 4))])
        #expect(after.liveDimensions(.default).isEmpty)
    }
}
