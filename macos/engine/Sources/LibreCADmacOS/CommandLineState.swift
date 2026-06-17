//
//  CommandLineState.swift
//  LibreCADmacOS
//
//  The PURE, SwiftUI-free decision logic for the merged smart command line (Wave-4
//  bottom-chrome redesign). Split out of `CommandLineBar.swift` so the mode/dropdown
//  rules can be symlinked into the CADEngine test target and unit-tested headlessly
//  (no GPU / live view / `NSView`). Imports ONLY CADEngine (for `CommandParser`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import CADEngine

// MARK: - Pure display-state classifier (unit-tested via the test symlink)

/// Which auxiliary affordance the merged command line shows alongside its single text
/// field, given the current text + whether a tool is active + whether the command
/// matcher has any suggestions for the text. A pure, side-effect-free classification so
/// the view's mode logic is unit-testable headlessly.
///
/// The precedence mirrors `CanvasModel.interpretCommandLine`'s ⏎ routing so the VISIBLE
/// affordance always matches what ⏎ will do.
enum CommandLineDisplayMode: Equatable {
    /// Empty field, a tool is active: show the active-tool prompt + keyword chips.
    case toolPrompt
    /// Empty field, no tool active: show the Recent-command chips.
    case recents
    /// The text looks like a coordinate/distance: NO dropdown (the active tool will
    /// consume it on ⏎); a parse error is echoed separately.
    case coordinate
    /// The text is a command word with matches: show the autocomplete dropdown.
    case suggestions
    /// The text is a command word with no matches: show a quiet "no match" note.
    case noMatch
}

/// Pure helpers for the merged command line so the routing/mode decisions are testable
/// without any SwiftUI / AppKit dependency (only CADEngine's `CommandParser`).
enum CommandLineState {
    /// Classifies the merged command line's current auxiliary mode (pure). `toolActive`
    /// is whether a draw/edit tool is armed; `hasSuggestions` is the model's
    /// `commandBarSuggestions` non-empty for this text.
    ///
    ///   1. EMPTY text → `.toolPrompt` (tool armed) or `.recents` (no tool).
    ///   2. NON-empty text that `looksLikeCoordinate` → `.coordinate` (no dropdown).
    ///   3. NON-empty command word with matches → `.suggestions`.
    ///   4. NON-empty command word with no matches → `.noMatch`.
    static func classify(
        text: String,
        toolActive: Bool,
        hasSuggestions: Bool
    ) -> CommandLineDisplayMode {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return toolActive ? .toolPrompt : .recents
        }
        if CommandParser.looksLikeCoordinate(trimmed) {
            return .coordinate
        }
        return hasSuggestions ? .suggestions : .noMatch
    }

    /// Whether the autocomplete dropdown should be visible: the field is focused AND the
    /// text classifies to `.suggestions`. (Coordinate text and the empty field never
    /// show the dropdown.) Kept pure so the visibility rule is unit-testable.
    static func showsDropdown(
        text: String,
        focused: Bool,
        toolActive: Bool,
        hasSuggestions: Bool
    ) -> Bool {
        guard focused else { return false }
        return classify(text: text, toolActive: toolActive, hasSuggestions: hasSuggestions) == .suggestions
    }
}
