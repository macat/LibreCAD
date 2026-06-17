//
//  InspectorHatchGradientEditTests.swift
//  CADEngineTests
//
//  Tests for the PURE inspector gradient-fill transform
//  (`InspectorEdits.setHatchGradient`) added by wave GH-W4 (the gradient-hatch
//  inspector UI + undoable setter). The setter must produce the right new
//  `EntityKind` (gradient set / cleared, loops + other fields kept, wrong-kind a
//  no-op, source unmutated for the undoable `.replace` path) and — via the merged
//  GH-W1/W2 resolve — a non-nil gradient must SUPERSEDE the pattern fill. The
//  SwiftUI controls are user-verified; this covers the value math under them
//  (which lives in the engine for exactly this reason — testable without a GUI).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Inspector hatch gradient edits")
struct InspectorHatchGradientEditTests {

    /// A pattern (non-solid) triangle hatch with no gradient — the starting point
    /// for converting solid/pattern ↔ gradient.
    private func sample() -> EntityKind {
        .hatch(HatchData(loops: [[PolylineVertex(point: Vector(0, 0)),
                                  PolylineVertex(point: Vector(1, 0)),
                                  PolylineVertex(point: Vector(1, 1))]],
                         solidFill: false, patternName: "ANSI31",
                         patternScale: 1, patternAngle: 0))
    }

    @Test("setting a two-color linear gradient stores it, keeping loops + other fields")
    func setTwoColorLinear() {
        let kind = sample()
        let grad = HatchGradient(kind: .linear,
                                 colors: [RGBAColor(1, 0, 0), RGBAColor(0, 0, 1)],
                                 angle: .pi / 4)

        let edited = InspectorEdits.setHatchGradient(kind, grad)
        guard case .hatch(let d) = edited else { Issue.record("not hatch"); return }
        #expect(d.gradient == grad)
        #expect(d.gradient?.kind == .linear)
        #expect(d.gradient?.colors.count == 2)
        #expect(abs((d.gradient?.angle ?? 0) - .pi / 4) < 1e-12)
        // Other fields are untouched (the gradient supersedes them at resolve, but
        // the setter does not clear them — clearing the gradient restores them).
        #expect(d.loops.count == 1)
        #expect(d.patternName == "ANSI31")
        #expect(d.solidFill == false)
    }

    @Test("a one-color (single-stop) radial gradient round-trips through the setter")
    func setOneColorRadial() {
        let grad = HatchGradient(kind: .radial, colors: [RGBAColor(0.2, 0.8, 0.3)], angle: 0)
        let edited = InspectorEdits.setHatchGradient(sample(), grad)
        guard case .hatch(let d) = edited else { Issue.record("not hatch"); return }
        #expect(d.gradient?.kind == .radial)
        #expect(d.gradient?.colors.count == 1)
        #expect(d.gradient?.colors.first == RGBAColor(0.2, 0.8, 0.3))
    }

    @Test("passing nil clears the gradient, leaving the solid/pattern fill intact")
    func clearGradient() {
        let withGrad = InspectorEdits.setHatchGradient(
            sample(),
            HatchGradient(kind: .linear, colors: [.black, .white]))
        let cleared = InspectorEdits.setHatchGradient(withGrad, nil)
        guard case .hatch(let d) = cleared else { Issue.record("not hatch"); return }
        #expect(d.gradient == nil)
        // The pattern fill the hatch had before the gradient is still there.
        #expect(d.patternName == "ANSI31")
        #expect(d.solidFill == false)
    }

    @Test("the edit applied to a non-hatch kind is a no-op (returns the kind unchanged)")
    func wrongKindNoOp() {
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        let edited = InspectorEdits.setHatchGradient(
            line, HatchGradient(kind: .linear, colors: [.black, .white]))
        #expect(edited == line)
    }

    @Test("the edit is undoable: the source kind is unmutated, and re-applying reproduces it")
    func undoableValueSemantics() {
        let source = sample()
        let grad = HatchGradient(kind: .radial, colors: [.white, .black], angle: 1)

        let once = InspectorEdits.setHatchGradient(source, grad)
        // The source value type is unchanged (value semantics back the .replace undo).
        guard case .hatch(let srcD) = source else { Issue.record("not hatch"); return }
        #expect(srcD.gradient == nil)
        // Re-applying the same edit to the same source reproduces an equal result.
        let twice = InspectorEdits.setHatchGradient(source, grad)
        #expect(once == twice)
    }

    @Test("a gradient supersedes the pattern fill through resolve (the GH-W1/W2 contract)")
    func gradientSupersedesPatternThroughResolve() {
        // The sample is a NON-solid pattern hatch: without a gradient it resolves to
        // pattern-line polylines. Adding a gradient must divert it to a gradient FILL.
        let grad = HatchGradient(kind: .linear,
                                 colors: [RGBAColor(1, 0, 0), RGBAColor(0, 0, 1)],
                                 angle: .pi / 6)
        let edited = InspectorEdits.setHatchGradient(sample(), grad)

        let geo = edited.resolve(pen: .toolPreview, ctx: .default)
        // One fill carrying the resolved gradient; no pattern-line polylines.
        #expect(geo.fills.count == 1)
        #expect(geo.fills.first?.gradient != nil)
        #expect(geo.fills.first?.gradient?.kind == .linear)
        #expect(geo.fills.first?.gradient?.colors.count == 2)
    }
}
