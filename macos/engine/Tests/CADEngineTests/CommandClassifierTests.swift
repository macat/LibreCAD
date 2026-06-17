//
//  CommandClassifierTests.swift
//  CADEngineTests
//
//  Drives `CommandParser.looksLikeCoordinate(_:)` — the cheap heuristic the MERGED
//  bottom command line (bottom-chrome redesign, Wave 1A) uses to tell a coordinate
//  / distance token (route to `parse` + the active tool as `.value(point)`) from a
//  command WORD like `LINE` / `L` / `rect` (route to the command matcher). Pure, no
//  GUI — passes a string and asserts the boolean route.
//
//  Domain-prefixed suite name (CONVENTIONS.md) so parallel fan-out builders adding
//  files to the same target don't collide.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CommandParser.looksLikeCoordinate routing heuristic")
struct CommandClassifierTests {

    // MARK: - Coordinate / distance forms → true

    @Test("absolute pair x,y looks like a coordinate")
    func absolutePair() {
        #expect(CommandParser.looksLikeCoordinate("5,5"))
    }

    @Test("relative @dx,dy looks like a coordinate")
    func relativePair() {
        #expect(CommandParser.looksLikeCoordinate("@3,4"))
    }

    @Test("polar dist<angle looks like a coordinate")
    func polar() {
        #expect(CommandParser.looksLikeCoordinate("10<45"))
    }

    @Test("a bare distance (single number) looks like a coordinate")
    func bareDistance() {
        #expect(CommandParser.looksLikeCoordinate("5"))
    }

    @Test("a leading-minus signed pair looks like a coordinate")
    func signedNegativePair() {
        #expect(CommandParser.looksLikeCoordinate("-3,2"))
    }

    @Test("a leading-plus number looks like a coordinate")
    func signedPositive() {
        #expect(CommandParser.looksLikeCoordinate("+3"))
    }

    @Test("a leading-dot decimal pair looks like a coordinate")
    func leadingDotDecimal() {
        #expect(CommandParser.looksLikeCoordinate(".5,1"))
    }

    @Test("relative-polar @dist<angle looks like a coordinate")
    func relativePolar() {
        #expect(CommandParser.looksLikeCoordinate("@5<90"))
    }

    @Test("leading/trailing whitespace is trimmed before classifying")
    func surroundingWhitespace() {
        #expect(CommandParser.looksLikeCoordinate("  5,5  "))
    }

    // MARK: - Command words → false

    @Test("an uppercase command word LINE is not a coordinate")
    func upperCommand() {
        #expect(!CommandParser.looksLikeCoordinate("LINE"))
    }

    @Test("a single-letter alias L is not a coordinate")
    func aliasCommand() {
        #expect(!CommandParser.looksLikeCoordinate("L"))
    }

    @Test("a lowercase command word line is not a coordinate")
    func lowerCommand() {
        #expect(!CommandParser.looksLikeCoordinate("line"))
    }

    @Test("the rect command word is not a coordinate")
    func rectCommand() {
        #expect(!CommandParser.looksLikeCoordinate("rect"))
    }

    // MARK: - Empty / whitespace → false

    @Test("empty string is not a coordinate")
    func empty() {
        #expect(!CommandParser.looksLikeCoordinate(""))
    }

    @Test("whitespace-only is not a coordinate")
    func whitespaceOnly() {
        #expect(!CommandParser.looksLikeCoordinate("   "))
    }

    // MARK: - Comma/`<`-bearing words → true (route by separator, not validity)

    @Test("a malformed pair x,y routes as a coordinate because it has a comma — parse rejects it later")
    func malformedPairRoutesAsCoordinate() {
        // Documented behavior: the classifier only picks the ROUTE. `x,y` contains
        // a comma so it routes to the coordinate parser, which then errors. The
        // merged command line is expected to surface that error rather than fall
        // back to treating it as a command word.
        #expect(CommandParser.looksLikeCoordinate("x,y"))
    }

    @Test("an alpha token containing < routes as a coordinate (separator wins)")
    func alphaWithAngleSeparator() {
        // Same rationale as `x,y`: the `<` polar separator routes to coordinate
        // parsing, which then validates (and errors) on the non-numeric token.
        #expect(CommandParser.looksLikeCoordinate("a<b"))
    }

    // MARK: - Extra edge cases that matter

    @Test("a lone @ (start of a relative form) routes as a coordinate")
    func loneAtSign() {
        #expect(CommandParser.looksLikeCoordinate("@"))
    }

    @Test("a lone decimal point routes as a coordinate")
    func loneDot() {
        #expect(CommandParser.looksLikeCoordinate("."))
    }

    @Test("a lone sign routes as a coordinate")
    func loneSign() {
        #expect(CommandParser.looksLikeCoordinate("-"))
        #expect(CommandParser.looksLikeCoordinate("+"))
    }

    @Test("a decimal number with no leading digit routes as a coordinate")
    func leadingDotNumber() {
        #expect(CommandParser.looksLikeCoordinate(".25"))
    }

    @Test("a multi-letter command starting with a digit-free word stays a command")
    func multiWordCommand() {
        #expect(!CommandParser.looksLikeCoordinate("circle"))
        #expect(!CommandParser.looksLikeCoordinate("POLYLINE"))
    }

    @Test("a command with trailing spaces is still a command")
    func commandTrailingSpaces() {
        #expect(!CommandParser.looksLikeCoordinate("line   "))
    }
}
