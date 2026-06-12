//
//  CommandMatcherTests.swift
//  CADEngineTests
//
//  Pure-logic tests for the ⌘K command-palette fuzzy matcher/ranker. These pin
//  the contract the SwiftUI palette relies on:
//    - an empty query returns ALL candidates, in original order;
//    - matching is a case-insensitive subsequence;
//    - ranking is sensible — "lin" surfaces both "Line" and "Linear Dimension",
//      with the prefix/whole-word hits ranked above scattered ones.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Command palette fuzzy matcher")
struct CommandMatcherTests {

    /// A representative slice of the real palette roster.
    private let roster = [
        "Select", "Line", "Circle", "Arc", "Rectangle", "Polyline",
        "Linear Dimension", "Aligned Dimension", "Radius Dimension",
        "Move", "Mirror", "Export SVG…", "Export PNG…", "Zoom to Fit",
    ]

    // MARK: Empty query

    @Test("empty query returns every candidate in original order")
    func emptyQueryReturnsAll() {
        let result = CommandMatcher.rank(query: "", candidates: roster)
        #expect(result.count == roster.count)
        #expect(result.map(\.index) == Array(roster.indices))
    }

    @Test("whitespace-only query is treated as empty")
    func whitespaceQueryReturnsAll() {
        let result = CommandMatcher.rank(query: "   ", candidates: roster)
        #expect(result.count == roster.count)
        #expect(result.map(\.index) == Array(roster.indices))
    }

    // MARK: Subsequence matching

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(CommandMatcher.matches("CIRCLE", "Circle"))
        #expect(CommandMatcher.matches("circle", "Circle"))
        #expect(CommandMatcher.matches("CiRcLe", "Circle"))
    }

    @Test("scattered subsequence matches; non-subsequence does not")
    func subsequenceContract() {
        // Letters in order but not adjacent.
        #expect(CommandMatcher.matches("rce", "Rectangle"))
        // 'z' is not present.
        #expect(!CommandMatcher.matches("zzz", "Rectangle"))
        // Out-of-order letters do not form a subsequence.
        #expect(!CommandMatcher.matches("elcric", "Circle"))
    }

    // MARK: The headline ranking requirement

    @Test("query 'lin' matches both Line and Linear Dimension, ranked sensibly")
    func linMatchesBothRankedSensibly() {
        let result = CommandMatcher.rank(query: "lin", candidates: roster)
        let titles = result.map { roster[$0.index] }

        #expect(titles.contains("Line"))
        #expect(titles.contains("Linear Dimension"))

        let posLine = titles.firstIndex(of: "Line")!
        let posLinear = titles.firstIndex(of: "Linear Dimension")!
        // Both are prefix matches; the shorter, exact-shaped title leads.
        #expect(posLine < posLinear)
        // A prefix match outranks any scattered "l…i…n" hit (e.g. Polyline).
        if let posPolyline = titles.firstIndex(of: "Polyline") {
            #expect(posLine < posPolyline)
            #expect(posLinear < posPolyline)
        }
    }

    // MARK: Tier ordering

    @Test("exact match outranks prefix outranks substring outranks scattered")
    func tierOrdering() {
        let candidates = ["Line", "Linear Dimension", "Spline", "Lateral Incline"]
        // "line": exact for "Line", prefix for "Linear Dimension",
        // substring for "Spline", scattered for "Lateral Incline".
        let result = CommandMatcher.rank(query: "line", candidates: candidates)
        let order = result.map { candidates[$0.index] }
        #expect(order.first == "Line")
        let iExact = order.firstIndex(of: "Line")!
        let iPrefix = order.firstIndex(of: "Linear Dimension")!
        let iSub = order.firstIndex(of: "Spline")!
        let iScatter = order.firstIndex(of: "Lateral Incline")!
        #expect(iExact < iPrefix)
        #expect(iPrefix < iSub)
        #expect(iSub < iScatter)
    }

    @Test("prefix match beats a word-boundary match in the middle of the title")
    func prefixBeatsMidWord() {
        let candidates = ["Mirror", "Aligned Dimension"]
        // "dim": prefix-ish? No — "Mirror" has no 'd'. Use a cleaner pair:
        let pair = ["Dimension Aligned", "Aligned Dimension"]
        let result = CommandMatcher.rank(query: "dim", candidates: pair)
        let order = result.map { pair[$0.index] }
        // The title that STARTS with "dim" must rank first.
        #expect(order.first == "Dimension Aligned")
        _ = candidates
    }

    // MARK: Match indices (for highlighting)

    @Test("matched indices locate the query characters in the candidate")
    func matchedIndices() {
        let result = CommandMatcher.rank(query: "cir", candidates: ["Circle"])
        #expect(result.count == 1)
        // C-i-r are the first three characters.
        #expect(result[0].matchedIndices == [0, 1, 2])
    }

    @Test("non-matches are excluded from ranked results")
    func nonMatchesExcluded() {
        let result = CommandMatcher.rank(query: "xyz", candidates: roster)
        #expect(result.isEmpty)
    }
}
