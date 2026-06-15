//
//  CommandBarTests.swift
//  CADEngineTests
//
//  Pure-logic tests for the bottom COMMAND BAR's tool launcher — specifically the
//  side-effect-free `ToolSuggester` that decides which ~8-10 tools the chip row
//  shows. These pin the contract the SwiftUI `CommandBar` relies on:
//    - the EMPTY-query adaptive set differs correctly by selection state (Draw vs
//      Modify bias) and always leads with the curated core;
//    - the MRU influences ordering (a recently-used tool surfaces) without ever
//      dropping the core;
//    - a non-empty query fuzzy-filters EVERY tool, title + aliases, ranked sensibly
//      ("ci"→Circle first, "tr"→Trim, "rect"→Rectangle, "dim"→a dimension tool);
//    - the empty set is capped at ~10;
//    - activation promotes a tool in the MRU (dedup + cap).
//
//  Engine-level, no GUI: `ToolSuggester`/`ToolKind` live in CADEngine, so these
//  reach them directly via `@testable import` — no app-module symlink needed.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace suites so parallel fan-out
//  builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Command bar tool suggester")
struct CommandBarTests {

    // MARK: - Empty query → adaptive default set

    @Test("empty query returns the adaptive set, leading with the curated core")
    func emptyQueryLeadsWithCore() {
        let result = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [])
        // The curated core comes first, in order, regardless of selection/MRU.
        #expect(Array(result.prefix(6)) == ToolSuggestionCatalog.default.core)
    }

    @Test("empty query is capped at ~10 chips")
    func emptyQueryIsCapped() {
        let result = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [])
        #expect(result.count <= ToolSuggester.defaultCap)
        // With the default catalog (6 core + 10 draw, deduped) the cap actually binds.
        #expect(result.count == ToolSuggester.defaultCap)
    }

    @Test("whitespace-only query is treated as empty (adaptive set)")
    func whitespaceIsEmpty() {
        let blank = ToolSuggester.suggestions(query: "   ", hasSelection: false, mru: [])
        let empty = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [])
        #expect(blank == empty)
    }

    // MARK: - Selection context: Draw vs Modify bias

    @Test("no selection surfaces Draw tools; a selection surfaces Modify tools")
    func selectionContextChangesTheSet() {
        let noSel = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [])
        let withSel = ToolSuggester.suggestions(query: "", hasSelection: true, mru: [])

        // The two sets must differ — selection flips the context roster.
        #expect(noSel != withSel)

        // With a selection, Modify-only tools (not in the core/draw lists) appear.
        // `.move` is a Modify tool and is NOT in the curated core or the draw roster.
        #expect(withSel.contains(.move))
        #expect(!noSel.contains(.move))

        // Without a selection, a Draw-only tool beyond the core appears (e.g. Ellipse),
        // and Modify-only Move does not.
        #expect(noSel.contains(.ellipse))
        #expect(!withSel.contains(.ellipse))
    }

    @Test("the core is present in BOTH selection states")
    func coreAlwaysPresent() {
        let noSel = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [])
        let withSel = ToolSuggester.suggestions(query: "", hasSelection: true, mru: [])
        for kind in ToolSuggestionCatalog.default.core {
            #expect(noSel.contains(kind), "core \(kind) missing with no selection")
            #expect(withSel.contains(kind), "core \(kind) missing with a selection")
        }
    }

    // MARK: - MRU influences ordering

    @Test("a recently-used tool surfaces right after the core")
    func mruSurfacesAfterCore() {
        // `.hatch` is neither core nor near the front of the draw roster; using it
        // should pull it up to just behind the core.
        let result = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [.hatch])
        let core = ToolSuggestionCatalog.default.core
        #expect(result.contains(.hatch))
        // It lands immediately after the curated core (index == core.count).
        #expect(result.firstIndex(of: .hatch) == core.count)
    }

    @Test("MRU order is honored (most-recent first), core still leads")
    func mruOrderHonored() {
        let result = ToolSuggester.suggestions(
            query: "", hasSelection: false, mru: [.hatch, .spline])
        let core = ToolSuggestionCatalog.default.core
        // Core first, then the MRU in given order.
        #expect(Array(result.prefix(core.count)) == core)
        let iHatch = result.firstIndex(of: .hatch)!
        let iSpline = result.firstIndex(of: .spline)!
        #expect(iHatch < iSpline)         // most-recent (.hatch) precedes .spline
        #expect(iHatch == core.count)     // and sits right after the core
    }

    @Test("an MRU tool already in the core is not duplicated")
    func mruDoesNotDuplicateCore() {
        let result = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [.line])
        #expect(result.filter { $0 == .line }.count == 1)
    }

    // MARK: - Fuzzy narrowing on a non-empty query

    @Test("query 'ci' ranks Circle first")
    func ciRanksCircleFirst() {
        let result = ToolSuggester.suggestions(query: "ci", hasSelection: false, mru: [])
        #expect(result.first == .circle)
    }

    @Test("query 'tr' surfaces Trim")
    func trSurfacesTrim() {
        let result = ToolSuggester.suggestions(query: "tr", hasSelection: false, mru: [])
        #expect(result.contains(.trim))
        // It is the top (prefix) match among the trim/text/… candidates.
        #expect(result.first == .trim)
    }

    @Test("alias 'rect' surfaces Rectangle as the top match")
    func rectAliasSurfacesRectangle() {
        let result = ToolSuggester.suggestions(query: "rect", hasSelection: false, mru: [])
        #expect(result.contains(.rectangle))
        #expect(result.first == .rectangle)
    }

    @Test("query 'dim' surfaces a dimension tool")
    func dimSurfacesADimensionTool() {
        let result = ToolSuggester.suggestions(query: "dim", hasSelection: false, mru: [])
        let dimensionKinds: Set<ToolKind> = [
            .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim,
            .ordinateDim, .arcLengthDim, .angular3pDim, .baselineDim, .continueDim,
        ]
        #expect(result.contains { dimensionKinds.contains($0) })
    }

    @Test("a non-matching query returns no chips")
    func nonMatchReturnsNothing() {
        let result = ToolSuggester.suggestions(query: "zzzq", hasSelection: false, mru: [])
        #expect(result.isEmpty)
    }

    @Test("a fuzzy query result is capped at ~10")
    func fuzzyResultIsCapped() {
        // "e" matches many tool titles; the chip row must still cap.
        let result = ToolSuggester.suggestions(query: "e", hasSelection: false, mru: [])
        #expect(result.count <= ToolSuggester.defaultCap)
    }

    @Test("fuzzy filtering ignores selection + MRU (query is the only driver)")
    func fuzzyIgnoresContext() {
        let a = ToolSuggester.suggestions(query: "circle", hasSelection: false, mru: [])
        let b = ToolSuggester.suggestions(query: "circle", hasSelection: true, mru: [.move, .trim])
        #expect(a == b)
    }

    // MARK: - MRU maintenance (activation updates MRU)

    @Test("using a tool promotes it to the front of the MRU")
    func usePromotesToFront() {
        let mru = ToolSuggester.updatedMRU([], used: .line)
        #expect(mru.first == .line)
    }

    @Test("re-using a tool moves it to the front without duplicating")
    func reuseMovesToFrontNoDuplicate() {
        var mru = ToolSuggester.updatedMRU([], used: .line)
        mru = ToolSuggester.updatedMRU(mru, used: .circle)
        mru = ToolSuggester.updatedMRU(mru, used: .line)   // re-use Line
        #expect(mru.first == .line)
        #expect(mru.filter { $0 == .line }.count == 1)
        #expect(mru == [.line, .circle])
    }

    @Test("MRU is capped at its limit, dropping the oldest")
    func mruIsCapped() {
        var mru: [ToolKind] = []
        // Push more distinct tools than the cap.
        let many: [ToolKind] = [
            .line, .circle, .arc, .rectangle, .polyline, .point, .ellipse,
            .polygon, .spline, .hatch, .move, .copy, .rotate, .scale,
        ]
        for kind in many { mru = ToolSuggester.updatedMRU(mru, used: kind, limit: 12) }
        #expect(mru.count == 12)
        // The most-recent (.scale) is at the front; the oldest (.line) was dropped.
        #expect(mru.first == .scale)
        #expect(!mru.contains(.line))
    }

    // MARK: - Catalog integrity

    @Test("every alias key is a real ToolKind (no stale entries)")
    func aliasKeysAreValid() {
        // Trivially true by the dictionary's key type, but pin that aliases exist for
        // the headline tools the UI advertises.
        let aliases = ToolSuggestionCatalog.default.aliases
        #expect(aliases[.rectangle]?.contains("rect") == true)
        #expect(aliases[.linearDim]?.contains("dim") == true)
        #expect(aliases[.polyline]?.contains("poly") == true)
    }

    @Test("the default catalog's rosters are non-empty")
    func rostersNonEmpty() {
        let c = ToolSuggestionCatalog.default
        #expect(!c.core.isEmpty)
        #expect(!c.draw.isEmpty)
        #expect(!c.modify.isEmpty)
    }
}
