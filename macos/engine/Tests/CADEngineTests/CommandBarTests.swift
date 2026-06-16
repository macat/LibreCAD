//
//  CommandBarTests.swift
//  CADEngineTests
//
//  Pure-logic tests for the bottom COMMAND BAR's tool launcher — specifically the
//  side-effect-free `ToolSuggester` that decides what the bar shows. The bar is a true
//  command LINE (Wave 4 de-mirror — plan §3d), NOT a static mirror of a default tool
//  set, and these pin that contract:
//    - an EMPTY query returns NO suggestion chips at all (regardless of selection or
//      MRU) — the bar shows a prompt hint, with the recents surfaced separately;
//    - `ToolSuggester.recents` builds the clearly-LABELED "Recent" row from the MRU
//      (most-recent first), EXCLUDING pinned tools, deduped and capped;
//    - chips/results appear ONLY while typing: a non-empty query fuzzy-filters EVERY
//      tool, title + aliases, ranked sensibly ("ci"→Circle first, "tr"→Trim,
//      "rect"→Rectangle, "dim"→a dimension tool), capped at ~10;
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

    // MARK: - Empty query → NO chips (Wave 4 de-mirror)

    @Test("empty query returns NO chips (the static mirror is gone)")
    func emptyQueryReturnsNoChips() {
        // De-mirror: the bar is a command LINE, not a mirror of a default tool set.
        // Chips appear only while typing.
        let result = ToolSuggester.suggestions(query: "", hasSelection: false, mru: [])
        #expect(result.isEmpty)
    }

    @Test("empty query returns no chips regardless of selection or MRU")
    func emptyQueryIgnoresContext() {
        // Neither selection state nor recents resurrect a pre-typed chip set.
        #expect(ToolSuggester.suggestions(query: "", hasSelection: true, mru: [.move]).isEmpty)
        #expect(ToolSuggester.suggestions(query: "", hasSelection: false, mru: [.line, .circle]).isEmpty)
    }

    @Test("whitespace-only query is treated as empty (still no chips)")
    func whitespaceIsEmpty() {
        let blank = ToolSuggester.suggestions(query: "   ", hasSelection: false, mru: [.line])
        #expect(blank.isEmpty)
    }

    // MARK: - Empty query → labeled "Recent" row (replaces the mirror)

    @Test("recents surfaces the MRU, most-recent first")
    func recentsSurfacesMRU() {
        let recents = ToolSuggester.recents(mru: [.hatch, .spline, .move])
        #expect(recents == [.hatch, .spline, .move])
    }

    @Test("recents excludes the pinned tools (no duplicate of a toolbar button)")
    func recentsExcludesPinned() {
        let recents = ToolSuggester.recents(
            mru: [.line, .hatch, .circle, .spline],
            excluding: [.line, .circle])
        #expect(recents == [.hatch, .spline])
        #expect(!recents.contains(.line))
        #expect(!recents.contains(.circle))
    }

    @Test("recents dedupes and caps")
    func recentsDedupesAndCaps() {
        // Duplicate entries collapse to first-occurrence; the cap binds.
        let recents = ToolSuggester.recents(mru: [.line, .line, .circle], cap: 5)
        #expect(recents == [.line, .circle])

        let many: [ToolKind] = [
            .line, .circle, .arc, .rectangle, .polyline, .point, .ellipse,
            .polygon, .spline, .hatch, .move, .copy,
        ]
        let capped = ToolSuggester.recents(mru: many, cap: 3)
        #expect(capped.count == 3)
        #expect(capped == [.line, .circle, .arc])
    }

    @Test("recents on an empty MRU is empty")
    func recentsEmptyMRU() {
        #expect(ToolSuggester.recents(mru: []).isEmpty)
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
