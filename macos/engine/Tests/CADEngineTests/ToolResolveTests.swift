//
//  ToolResolveTests.swift
//  CADEngineTests
//
//  Pure-logic tests for the smart command line's command-word → ToolKind resolver
//  (`ToolSuggester.resolve(command:catalog:)`) and the AutoCAD short aliases that feed
//  it. These pin the contract the bottom command LINE relies on:
//    - exact title / alias wins (case-insensitive, whitespace-trimmed);
//    - canonical single/two-letter AutoCAD aliases resolve (l→Line, c→Circle, …);
//    - a confident fuzzy fallback resolves typos/prefixes ("rectang" → Rectangle);
//    - clear garbage ("xyzzy") resolves to nil rather than a random tool;
//    - the short command aliases are collision-free across kinds.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Command-word → ToolKind resolver")
struct ToolResolveTests {

    // MARK: - Exact title match (case-insensitive)

    @Test("uppercase title resolves to its kind")
    func uppercaseTitle() {
        #expect(ToolSuggester.resolve(command: "LINE") == .line)
    }

    @Test("lowercase title resolves to its kind")
    func lowercaseTitle() {
        #expect(ToolSuggester.resolve(command: "line") == .line)
    }

    @Test("surrounding whitespace is trimmed before matching")
    func trimmedTitle() {
        #expect(ToolSuggester.resolve(command: "   Circle  ") == .circle)
    }

    @Test("a multi-word title resolves exactly")
    func multiWordTitle() {
        #expect(ToolSuggester.resolve(command: "linear dimension") == .linearDim)
    }

    // MARK: - Single / short AutoCAD aliases

    @Test("single-letter AutoCAD aliases resolve")
    func singleLetterAliases() {
        #expect(ToolSuggester.resolve(command: "l") == .line)
        #expect(ToolSuggester.resolve(command: "c") == .circle)
        #expect(ToolSuggester.resolve(command: "a") == .arc)
        #expect(ToolSuggester.resolve(command: "r") == .rectangle)
        #expect(ToolSuggester.resolve(command: "m") == .move)
        #expect(ToolSuggester.resolve(command: "o") == .offset)
        #expect(ToolSuggester.resolve(command: "h") == .hatch)
        #expect(ToolSuggester.resolve(command: "t") == .text)
    }

    @Test("two-letter AutoCAD aliases resolve")
    func twoLetterAliases() {
        #expect(ToolSuggester.resolve(command: "ln") == .line)
        #expect(ToolSuggester.resolve(command: "rec") == .rectangle)
        #expect(ToolSuggester.resolve(command: "pl") == .polyline)
        #expect(ToolSuggester.resolve(command: "el") == .ellipse)
        #expect(ToolSuggester.resolve(command: "co") == .copy)
        #expect(ToolSuggester.resolve(command: "ro") == .rotate)
        #expect(ToolSuggester.resolve(command: "mi") == .mirror)
        #expect(ToolSuggester.resolve(command: "tr") == .trim)
        #expect(ToolSuggester.resolve(command: "ex") == .extend)
    }

    @Test("aliases are case-insensitive")
    func aliasCaseInsensitive() {
        #expect(ToolSuggester.resolve(command: "L") == .line)
        #expect(ToolSuggester.resolve(command: "REC") == .rectangle)
    }

    @Test("existing pre-redesign aliases still resolve (not removed)")
    func existingAliasesPreserved() {
        #expect(ToolSuggester.resolve(command: "rect") == .rectangle)
        #expect(ToolSuggester.resolve(command: "box") == .rectangle)
        #expect(ToolSuggester.resolve(command: "circ") == .circle)
        #expect(ToolSuggester.resolve(command: "mv") == .move)
        #expect(ToolSuggester.resolve(command: "cp") == .copy)
    }

    // MARK: - Exact alias wins over fuzzy

    @Test("an exact alias beats any fuzzy candidate")
    func exactAliasWins() {
        // "a" is the Arc alias; many titles contain an 'a' as a subsequence, but the
        // exact alias must win deterministically over all of them.
        #expect(ToolSuggester.resolve(command: "a") == .arc)
        // "c" is the Circle alias even though "Copy", "Scale", … also contain a 'c'.
        #expect(ToolSuggester.resolve(command: "c") == .circle)
    }

    // MARK: - Fuzzy fallback (above threshold)

    @Test("a prefix typo resolves via the fuzzy fallback")
    func fuzzyPrefix() {
        // "rectang" is not an alias or full title, but it's a strong prefix of
        // "Rectangle" → clears the threshold.
        #expect(ToolSuggester.resolve(command: "rectang") == .rectangle)
    }

    @Test("another prefix resolves via the fuzzy fallback")
    func fuzzyPrefix2() {
        #expect(ToolSuggester.resolve(command: "poly") == .polyline)
        #expect(ToolSuggester.resolve(command: "ellip") == .ellipse)
    }

    // MARK: - Garbage → nil (below threshold / no match)

    @Test("clear garbage resolves to nil")
    func garbageIsNil() {
        #expect(ToolSuggester.resolve(command: "xyzzy") == nil)
    }

    @Test("empty / whitespace command resolves to nil")
    func emptyIsNil() {
        #expect(ToolSuggester.resolve(command: "") == nil)
        #expect(ToolSuggester.resolve(command: "   ") == nil)
    }

    @Test("a scattered low-confidence subsequence is rejected")
    func lowConfidenceRejected() {
        // "zzzz" has no subsequence match anywhere → nil.
        #expect(ToolSuggester.resolve(command: "zzzz") == nil)
    }

    // MARK: - Alias hygiene

    @Test("short command aliases are collision-free across kinds")
    func noDuplicateCommandAliases() {
        let dupes = ToolSuggester.duplicateCommandAliases()
        #expect(dupes.isEmpty, "Colliding command aliases: \(dupes)")
    }

    @Test("every single/short command alias resolves to exactly the expected kind")
    func commandAliasRoundTrip() {
        // The canonical short-alias contract: each must resolve back to its owner kind.
        let expected: [(String, ToolKind)] = [
            ("l", .line), ("ln", .line),
            ("c", .circle), ("a", .arc),
            ("r", .rectangle), ("rec", .rectangle),
            ("pl", .polyline), ("el", .ellipse),
            ("m", .move), ("co", .copy),
            ("ro", .rotate), ("mi", .mirror),
            ("o", .offset), ("tr", .trim),
            ("ex", .extend), ("h", .hatch),
            ("t", .text),
        ]
        for (alias, kind) in expected {
            #expect(ToolSuggester.resolve(command: alias) == kind,
                    "alias \"\(alias)\" should resolve to \(kind)")
        }
    }

    @Test("a custom catalog with no aliases falls back on titles only")
    func customCatalogTitlesOnly() {
        let bare = ToolSuggestionCatalog(core: [], draw: [], modify: [], aliases: [:])
        // Title still resolves exactly.
        #expect(ToolSuggester.resolve(command: "circle", catalog: bare) == .circle)
        // With no aliases, "rectang" can only resolve via the title prefix → Rectangle.
        #expect(ToolSuggester.resolve(command: "rectang", catalog: bare) == .rectangle)
        // Garbage is still nil with a bare catalog (no subsequence match anywhere).
        #expect(ToolSuggester.resolve(command: "xyzzy", catalog: bare) == nil)
    }
}
