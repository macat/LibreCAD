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
}
