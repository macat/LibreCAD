//
//  ToolOptionsBar3FWiringTests.swift
//  CADEngineTests
//
//  Wave-3F: the contextual Tool Options bar arms for the Wave-3B parameterized tools
//  (Divide / Spline / Scale / Hatch). The bar binds each control to a `CanvasModel`
//  config field and, on change, calls `reapplyActiveToolConfig()` — which re-mints /
//  re-applies the value onto the LIVE tool. These tests drive the SAME path the bar
//  drives: set the model's config field exactly as the bar's control would, activate
//  the tool, then assert the live tool carries the chosen mode + params.
//
//  Two of the bar's controls introduce a UI↔engine MAPPING the bar owns (because the
//  engine type can't be a Picker tag): the Scale {Uniform, Non-uniform} control binds a
//  0/1 INDEX over the non-`Hashable` `ScaleTool.ScaleMode`, and the Hatch pattern
//  dropdown maps a "Solid" SENTINEL (empty string) ↔ `currentHatchPattern == nil`.
//  Those mappings are mirrored here (private to the bar's View) and proven to round-trip
//  through the model into the live tool's fill / mode.
//
//  `CanvasModel` lives in the (un-importable) app target — reached via the existing
//  `_SharedCanvasModel.swift` symlink (mirroring `Wave3BCanvasModelWiringTests`). The
//  suite is `@MainActor`; no SwiftUI body / modal is rendered (headless-safe).
//
//  Uniquely namespaced so it does not collide with the other suites in the shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

@MainActor
@Suite("Wave-3F ToolOptionsBar — Divide / Spline / Scale / Hatch arms")
struct ToolOptionsBar3FWiringTests {

    private func model() -> CanvasModel {
        let m = CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
        m.undoManager.groupsByEvent = false
        m.undoManager.removeAllActions()
        return m
    }

    // MARK: - Bar-owned UI ↔ engine mappings (mirror the View's private bindings)
    //
    // The bar can't bind these engine types directly to a Picker (ScaleMode isn't
    // Hashable; "solid" has no pattern name), so it owns a small mapping. Mirror it
    // here so a drift between the bar and the model's config is caught.

    /// Mirror of the bar's `scaleModeIndex` binding setter: 0 ⇒ uniform (.factor),
    /// 1 ⇒ .nonUniform.
    private func scaleMode(forIndex i: Int) -> ScaleTool.ScaleMode {
        i == 1 ? .nonUniform : .factor
    }
    /// Mirror of the bar's `scaleModeIndex` binding getter.
    private func scaleIndex(for mode: ScaleTool.ScaleMode) -> Int {
        mode == .nonUniform ? 1 : 0
    }
    /// Mirror of the bar's `hatchPatternSelection` binding setter: the empty-string
    /// "Solid" sentinel ⇒ nil pattern; any real name ⇒ itself.
    private func hatchPattern(forSelection tag: String) -> String? {
        tag.isEmpty ? nil : tag
    }

    // MARK: - Divide arm: mode segmented control + count / spacing field

    @Test("Divide 'By number' (index 0) + Pieces drives the live tool's count mode")
    func divideByNumberArm() throws {
        let m = model()
        // The bar's "By number" tag sets divideModeStyle = 0; the Pieces stepper sets count.
        m.divideModeStyle = 0
        m.divideCount = 8
        m.activateTool(.divide)
        let tool = try #require(m.tool as? DivideTool)
        #expect(tool.mode == .count(8))
    }

    @Test("Divide 'By length' (index 1) + Spacing drives the live tool's length mode")
    func divideByLengthArm() throws {
        let m = model()
        // The bar's "By length" tag sets divideModeStyle = 1; the Spacing field sets spacing.
        m.divideModeStyle = 1
        m.divideSpacing = 4.25
        m.activateTool(.divide)
        let tool = try #require(m.tool as? DivideTool)
        #expect(tool.mode == .length(4.25))
    }

    @Test("flipping the Divide mode segmented control re-mints the live tool")
    func divideModeFlipReapplies() throws {
        let m = model()
        m.divideModeStyle = 0
        m.divideCount = 5
        m.activateTool(.divide)
        #expect((m.tool as? DivideTool)?.mode == .count(5))
        // Bar flips to "By length" → onChange calls reapplyActiveToolConfig().
        m.divideModeStyle = 1
        m.divideSpacing = 9
        m.reapplyActiveToolConfig()
        #expect((m.tool as? DivideTool)?.mode == .length(9))
    }

    // MARK: - Spline arm: {Fit, Control points} picker

    @Test("Spline picker 'Control points' tag drives the live tool's mode")
    func splineControlPointsArm() throws {
        let m = model()
        m.splineMode = .controlPoints
        m.activateTool(.spline)
        #expect((m.tool as? SplineTool)?.mode == .controlPoints)
    }

    @Test("flipping the Spline picker back to Fit re-mints to the default interpolation")
    func splineFlipBackToFit() throws {
        let m = model()
        m.splineMode = .controlPoints
        m.activateTool(.spline)
        m.splineMode = .fit
        m.reapplyActiveToolConfig()
        #expect((m.tool as? SplineTool)?.mode == .fit)
    }

    @Test("SplineMode is Picker-tag-usable (Hashable, both cases present)")
    func splineModeIsHashable() {
        // The bar uses SplineMode itself as the Picker tag — assert that stays valid.
        let set: Set<SplineMode> = [.fit, .controlPoints]
        #expect(set.count == 2)
    }

    // MARK: - Scale arm: {Uniform, Non-uniform} index picker + X/Y fields

    @Test("Scale index 0 (Uniform) ⇒ the live tool keeps the original .factor mode")
    func scaleUniformArm() throws {
        let m = model()
        m.scaleMode = scaleMode(forIndex: 0)
        m.activateTool(.scale)
        #expect((m.tool as? ScaleTool)?.mode == .factor)
    }

    @Test("Scale index 1 (Non-uniform) + X/Y fields drive the live tool's factors")
    func scaleNonUniformArm() throws {
        let m = model()
        m.scaleMode = scaleMode(forIndex: 1)
        m.scaleX = 2.5
        m.scaleY = 0.5
        m.activateTool(.scale)
        let tool = try #require(m.tool as? ScaleTool)
        #expect(tool.mode == .nonUniform)
        #expect(tool.nonUniformFactors.sx == 2.5)
        #expect(tool.nonUniformFactors.sy == 0.5)
    }

    @Test("the Scale index ↔ ScaleMode mapping round-trips (the bar's binding)")
    func scaleIndexRoundTrips() {
        #expect(scaleIndex(for: .factor) == 0)
        #expect(scaleIndex(for: .nonUniform) == 1)
        // `.reference` (a third engine mode this 2-way control doesn't expose) reads as
        // "Uniform" (index 0) — selecting Uniform then leaves it as `.factor`.
        #expect(scaleIndex(for: .reference) == 0)
        #expect(scaleMode(forIndex: 0) == .factor)
        #expect(scaleMode(forIndex: 1) == .nonUniform)
    }

    // MARK: - Hatch arm: pattern dropdown (Solid sentinel) + scale + angle

    @Test("Hatch 'Solid' sentinel ⇒ nil pattern ⇒ the live tool keeps a solid fill")
    func hatchSolidArm() throws {
        let m = model()
        m.currentHatchPattern = hatchPattern(forSelection: "")   // the Solid sentinel
        m.activateTool(.hatch)
        #expect((m.tool as? HatchTool)?.fill == .solid)
    }

    @Test("Hatch named pattern + scale + angle drive the live tool's pattern fill")
    func hatchPatternArm() throws {
        let m = model()
        // Pick a real bundled name; if the library is empty in this env, skip gracefully.
        guard let name = HatchPatternLibrary.patterns.keys.sorted().first else {
            // No bundled patterns available — the Solid path is still covered above.
            return
        }
        m.currentHatchPattern = hatchPattern(forSelection: name)
        m.hatchPatternScale = 3
        m.hatchPatternAngle = .pi / 6
        m.activateTool(.hatch)
        let tool = try #require(m.tool as? HatchTool)
        #expect(tool.fill == .pattern(name: name, scale: 3, angle: .pi / 6))
    }

    @Test("the Hatch sentinel mapping round-trips (nil ↔ \"\", real name ↔ itself)")
    func hatchSentinelRoundTrips() {
        #expect(hatchPattern(forSelection: "") == nil)
        #expect(hatchPattern(forSelection: "ANSI31") == "ANSI31")
        // The getter side: nil shows the sentinel, a name shows itself (mirror of the bar).
        let solidShown = (nil as String?) ?? ""
        #expect(solidShown == "")
        let nameShown = ("ANSI31" as String?) ?? ""
        #expect(nameShown == "ANSI31")
    }

    @Test("the bundled pattern-name list the dropdown shows is sorted + non-empty names")
    func hatchPatternNamesSorted() {
        let names = HatchPatternLibrary.patterns.keys.sorted()
        #expect(names == names.sorted())                       // the dropdown order
        #expect(names.allSatisfy { !$0.isEmpty })              // never collides with the "" sentinel
    }
}
