//
//  CommandLineStateTests.swift
//  CADEngineTests
//
//  Unit tests for the PURE merged-command-line classifier (`CommandLineState` /
//  `CommandLineDisplayMode`), shared into this target via `_SharedCommandLineState.swift`
//  (a symlink to the app-module source — the established `_Shared*.swift` convention).
//
//  These pin the Wave-4 merged command line's mode + dropdown-visibility rules so a
//  refactor can't silently change which affordance the bar shows. They are headless: the
//  classifier touches only CADEngine's `CommandParser`, no SwiftUI / AppKit / NSView.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
@testable import CADEngine

@Suite("Merged command line display-state classifier (Wave 4)")
struct CommandLineStateTests {

    // MARK: - Empty field

    @Test("empty field with a tool armed → tool prompt")
    func emptyToolActiveIsPrompt() {
        #expect(CommandLineState.classify(text: "", toolActive: true, hasSuggestions: false) == .toolPrompt)
        // Whitespace-only is still empty.
        #expect(CommandLineState.classify(text: "   ", toolActive: true, hasSuggestions: true) == .toolPrompt)
    }

    @Test("empty field with no tool → recents")
    func emptyNoToolIsRecents() {
        #expect(CommandLineState.classify(text: "", toolActive: false, hasSuggestions: false) == .recents)
        #expect(CommandLineState.classify(text: "  ", toolActive: false, hasSuggestions: true) == .recents)
    }

    // MARK: - Coordinate text → no dropdown (the active tool consumes it)

    @Test("coordinate-shaped text → coordinate mode (never the dropdown)")
    func coordinateShapesAreCoordinateMode() {
        // Absolute / relative / polar / bare-distance — all classify as coordinate even
        // when there happen to be command suggestions, so ⏎ feeds the active tool.
        for text in ["0,0", "10,20", "@10,0", "5<90", "-3,4", ".5,.5", "+1,2", "42"] {
            #expect(
                CommandLineState.classify(text: text, toolActive: true, hasSuggestions: true) == .coordinate,
                "\(text) should classify as a coordinate"
            )
        }
    }

    // MARK: - Command words → suggestions / no-match

    @Test("command word with matches → suggestions")
    func commandWordWithMatchesIsSuggestions() {
        #expect(CommandLineState.classify(text: "line", toolActive: false, hasSuggestions: true) == .suggestions)
        // A command word while a tool is active still shows suggestions (the keyword case
        // is handled separately by interpretCommandLine; the classifier keys off shape).
        #expect(CommandLineState.classify(text: "rect", toolActive: true, hasSuggestions: true) == .suggestions)
    }

    @Test("command word with no matches → noMatch")
    func commandWordNoMatchesIsNoMatch() {
        #expect(CommandLineState.classify(text: "zzzq", toolActive: false, hasSuggestions: false) == .noMatch)
        #expect(CommandLineState.classify(text: "zzzq", toolActive: true, hasSuggestions: false) == .noMatch)
    }

    // MARK: - Dropdown visibility (focus-gated, suggestions-only)

    @Test("dropdown shows only when focused AND text is a matching command word")
    func dropdownVisibilityRule() {
        // Focused + matching command word → visible.
        #expect(CommandLineState.showsDropdown(text: "li", focused: true, toolActive: false, hasSuggestions: true))
        // Not focused → never visible.
        #expect(!CommandLineState.showsDropdown(text: "li", focused: false, toolActive: false, hasSuggestions: true))
        // Coordinate text → never the dropdown, even focused with suggestions.
        #expect(!CommandLineState.showsDropdown(text: "0,0", focused: true, toolActive: true, hasSuggestions: true))
        // Empty → never the dropdown.
        #expect(!CommandLineState.showsDropdown(text: "", focused: true, toolActive: false, hasSuggestions: true))
        // Command word but no matches → no dropdown.
        #expect(!CommandLineState.showsDropdown(text: "zzzq", focused: true, toolActive: false, hasSuggestions: false))
    }
}
