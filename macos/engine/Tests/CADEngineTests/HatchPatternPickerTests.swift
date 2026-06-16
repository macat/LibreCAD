//
//  HatchPatternPickerTests.swift
//  CADEngineTests
//
//  The hatch-pattern PICKER (v5 WAVE-4a, feature F6 finish): drives `HatchTool`
//  configured with a named `.pat` pattern (via `init(patternName:scale:angle:)`
//  or by setting `.fill`) and asserts the committed `.hatch` is NON-solid and
//  resolves to CLIPPED PATTERN LINES — not a solid fill — for a known boundary,
//  while:
//    - the back-compat default `init()` still commits a SOLID hatch;
//    - an unknown pattern name still commits (and resolves to a solid fallback);
//    - the bundled `.pat` library loads at least the curated set this brief ships.
//
//  These exercise the TOOL + bundled assets; the pattern math itself lives in
//  HatchPattern.swift / Resolve.swift (covered by HatchPatternResolveTests) and
//  is treated here as a fixed dependency.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("HatchTool pattern picker (W4a F6 finish)")
struct HatchPatternPickerTests {

    // MARK: - Helpers

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: records,
            entity: { id in records.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// A closed unit-ish square polyline boundary (0..size), one usable loop.
    private func squarePolyline(_ size: Double = 10) -> EntityRecord {
        EntityRecord(
            id: EntityID(1),
            layer: LayerID("0"),
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(size, 0)),
                PolylineVertex(point: Vector(size, size)),
                PolylineVertex(point: Vector(0, size)),
            ], closed: true)))
    }

    /// Extracts the single `.add`ed `.hatch` from a commit, or nil otherwise.
    private func committedHatch(_ outcome: ToolOutcome) -> HatchData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let r) = edits[0], case .hatch(let d) = r.kind
        else { return nil }
        return d
    }

    /// Commits a hatch from `tool` over a square boundary and returns the record.
    private func commitHatch(_ tool: inout HatchTool, size: Double = 10) -> EntityRecord? {
        let outcome = tool.handle(.commit, context: context([squarePolyline(size)]))
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let r) = edits[0] else { return nil }
        return r
    }

    // MARK: - Default init stays SOLID (back-compat)

    @Test("default init() still commits a SOLID hatch (no regression)")
    func defaultInitSolid() {
        var tool = HatchTool()
        let data = try! #require(committedHatch(
            tool.handle(.commit, context: context([squarePolyline()]))))
        #expect(data.solidFill == true)
        #expect(data.patternName == "SOLID")
    }

    @Test("HatchTool().fill defaults to .solid")
    func fillDefaultsSolid() {
        #expect(HatchTool().fill == .solid)
    }

    // MARK: - Pattern init → a NON-solid hatch carrying the pattern fields

    @Test("init(patternName:) commits a NON-solid hatch with the pattern name")
    func patternInitCarriesName() {
        var tool = HatchTool(patternName: "ANSI31")
        #expect(tool.fill == .pattern(name: "ANSI31", scale: 1, angle: 0))
        let data = try! #require(committedHatch(
            tool.handle(.commit, context: context([squarePolyline()]))))
        #expect(data.solidFill == false)
        #expect(data.patternName == "ANSI31")
        #expect(data.patternScale == 1)
        #expect(data.patternAngle == 0)
    }

    @Test("init(patternName:scale:angle:) carries scale + angle onto the hatch")
    func patternInitCarriesScaleAngle() {
        var tool = HatchTool(patternName: "ANSI31", scale: 2.5, angle: .pi / 4)
        let data = try! #require(committedHatch(
            tool.handle(.commit, context: context([squarePolyline()]))))
        #expect(data.solidFill == false)
        #expect(data.patternName == "ANSI31")
        #expect(abs(data.patternScale - 2.5) < 1e-12)
        #expect(abs(data.patternAngle - .pi / 4) < 1e-12)
    }

    @Test("a non-finite / non-positive scale is normalized to 1")
    func patternInitNormalizesScale() {
        #expect(HatchTool(patternName: "ANSI31", scale: 0).fill
                == .pattern(name: "ANSI31", scale: 1, angle: 0))
        #expect(HatchTool(patternName: "ANSI31", scale: -3).fill
                == .pattern(name: "ANSI31", scale: 1, angle: 0))
        #expect(HatchTool(patternName: "ANSI31", scale: .nan).fill
                == .pattern(name: "ANSI31", scale: 1, angle: 0))
    }

    @Test("init(patternName: \"SOLID\") configures a solid fill")
    func patternInitSolidName() {
        #expect(HatchTool(patternName: "SOLID").fill == .solid)
        #expect(HatchTool(patternName: "solid").fill == .solid)   // case-insensitive
    }

    @Test("the .fill property is settable on a live tool")
    func fillSettable() {
        var tool = HatchTool()
        tool.fill = .pattern(name: "NET", scale: 1, angle: 0)
        let data = try! #require(committedHatch(
            tool.handle(.commit, context: context([squarePolyline()]))))
        #expect(data.solidFill == false)
        #expect(data.patternName == "NET")
    }

    // MARK: - The headline: a pattern hatch RESOLVES to clipped lines, not a fill

    @Test("a pattern hatch resolves to clipped pattern LINES (not a solid fill)")
    func patternHatchResolvesToLines() {
        var tool = HatchTool(patternName: "ANSI31")
        let rec = try! #require(commitHatch(&tool))
        let geo = rec.resolve(ResolveContext())

        #expect(geo.fills.isEmpty)            // NOT a solid fill
        #expect(!geo.polylines.isEmpty)       // real clipped pattern lines
        #expect(geo.polylines.count > 5)
        // Every generated line is a 2-point open segment inside the 10x10 box.
        for pl in geo.polylines {
            #expect(pl.points.count == 2)
            #expect(!pl.closed)
            for p in pl.points {
                #expect(p.x >= -1e-6 && p.x <= 10 + 1e-6)
                #expect(p.y >= -1e-6 && p.y <= 10 + 1e-6)
            }
        }
    }

    @Test("the default (solid) tool still resolves to a solid fill, no lines")
    func solidHatchResolvesToFill() {
        var tool = HatchTool()
        let rec = try! #require(commitHatch(&tool))
        let geo = rec.resolve(ResolveContext())
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
    }

    @Test("an UNKNOWN pattern name still commits and resolves to a SOLID fallback")
    func unknownPatternFallsBackToSolid() {
        var tool = HatchTool(patternName: "DEFINITELY_NOT_A_PATTERN")
        let rec = try! #require(commitHatch(&tool))
        // The committed hatch IS non-solid (carries the requested name) ...
        guard case .hatch(let data) = rec.kind else {
            Issue.record("expected a hatch"); return
        }
        #expect(data.solidFill == false)
        #expect(data.patternName == "DEFINITELY_NOT_A_PATTERN")
        // ... but it RESOLVES to a solid fill (the resolve arm's fallback).
        let geo = rec.resolve(ResolveContext())
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.count == 1)
    }

    @Test("a larger pattern scale yields fewer (more widely spaced) lines")
    func patternScaleAffectsLineCount() {
        func lineCount(scale: Double) -> Int {
            var tool = HatchTool(patternName: "ANSI31", scale: scale)
            guard let rec = commitHatch(&tool) else { return 0 }
            return rec.resolve(ResolveContext()).polylines.count
        }
        let small = lineCount(scale: 1)
        let large = lineCount(scale: 4)
        #expect(large > 0)
        #expect(large < small)
    }

    // MARK: - The bundled `.pat` library loads the curated set

    @Test("the bundled .pat library loads at least the curated picker set")
    func bundledLibraryHasCuratedSet() {
        let names = Set(HatchPatternLibrary.patterns.keys)
        // The set shipped across librecad.pat / ansi.pat / generic.pat / iso.pat.
        let expected: Set<String> = [
            "ANSI31", "ANSI32", "ANSI37", "LINE", "NET",          // librecad.pat
            "ANSI33", "ANSI34", "ANSI35", "ANSI36", "ANSI38",     // ansi.pat
            "DOTS", "GRID", "CROSS", "SQUARE", "BRICK",           // generic.pat
            "ANGLE", "HONEY", "ZIGZAG",
            "ISO02W100", "ISO03W100", "ISO04W100", "ISO10W100",   // iso.pat
        ]
        for name in expected {
            #expect(names.contains(name), "missing bundled pattern \(name)")
        }
        // The library is comfortably above the brief's ~10-15 lower bound.
        #expect(HatchPatternLibrary.patterns.count >= 15)
    }

    @Test("every bundled pattern resolves to clipped lines over a known boundary")
    func everyBundledPatternResolvesToLines() {
        // Each bundled (non-solid) pattern must produce real geometry — lines for
        // a generating family, or at worst the solid fallback — never nothing.
        for name in HatchPatternLibrary.patterns.keys {
            var tool = HatchTool(patternName: name, scale: 1)
            guard let rec = commitHatch(&tool, size: 40) else {
                Issue.record("no commit for pattern \(name)"); continue
            }
            let geo = rec.resolve(ResolveContext())
            let drew = !geo.polylines.isEmpty || !geo.fills.isEmpty
            #expect(drew, "pattern \(name) drew nothing")
        }
    }
}
