//
//  CommandLineBar.swift
//  LibreCADmacOS
//
//  The MERGED smart command line — Wave 4 of the bottom-chrome redesign. This single
//  full-width strip REPLACES the two former bottom rows (the U1 coordinate line + the
//  `CommandBar` tool launcher): one `TextField`, one `@FocusState`, one backing string.
//  It is AutoCAD's command line done macOS-native and lives at the window bottom, just
//  ABOVE the status bar (the literal bottom row after the Wave-4 reorder).
//
//  What the one line does, by state (see `CommandLineState.classify`):
//    • EMPTY + no tool   → quiet hint + a row of RECENT command chips. Tapping a chip
//      LOADS the command word into the field (keeps focus) — it does NOT execute (the
//      Wave-4 behavior change from the old execute-on-tap launcher).
//    • EMPTY + tool armed → the active tool's PROMPT (`commandHint`/`toolStepReadout`)
//      inline, plus its `activeToolKeywordOptions` as clickable `[Close] [Undo]` /
//      `[2P] [3P]` bracket chips. Tapping a chip → `model.invokeToolKeyword`.
//    • TYPING a coordinate (`x,y` / `@dx,dy` / `dist<angle`) → NO dropdown; ⏎ feeds the
//      active tool the exact point (the model's `interpretCommandLine` routes it).
//    • TYPING a command word → an autocomplete DROPDOWN that opens UPWARD over the
//      canvas (the bar is at the bottom), reusing the `CommandPalette` row layout
//      (`ToolCatalog.metadata` icon + title + shortcut + selection highlight + ↑/↓
//      nav + hover). ⏎ / click on the highlighted row activates that tool.
//
//  ⏎ routes through the already-merged `model.interpretCommandLine(_:)` (keyword-before-
//  coordinate-before-command), so a typed `2P`/`3P`/`Close` hits the active tool BEFORE
//  the coordinate classifier. On `.activateTool(kind)` the VIEW activates (so `.image`'s
//  `NSOpenPanel` stays in the View layer — a modal must never be reachable from the
//  model/tool/test). `.error` echoes `model.lastCommandError` in red and KEEPS the text.
//
//  The body is decomposed into small `@ViewBuilder` helpers so the Swift type-checker
//  never sees a monolithic expression. Chrome routes through `DS` tokens + the shared
//  `.barStrip(.top)` primitive (the retired hand-rolled padding/material/divider is
//  gone). The single icon source is `ToolCatalog.metadata` (NOT `CommandRegistry.glyph`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// (The pure `CommandLineDisplayMode` + `CommandLineState` classifier — which decide,
//  WITHOUT any SwiftUI/AppKit, which auxiliary affordance the bar shows and whether the
//  dropdown is up — live in `CommandLineState.swift` so they are symlinked into the
//  CADEngine test target and unit-tested headlessly. This view consumes them.)

// MARK: - The merged command line view

/// The single full-width smart command line pinned at the window bottom (just above the
/// status bar). One `TextField` + one `@FocusState` (bound from the host) + one backing
/// string (bound from the host). Renders the autocomplete dropdown (upward), the
/// active-tool prompt + keyword chips, or the recent-command chips, and routes ⏎ through
/// the model's `interpretCommandLine`. Image placement (`.image`) routes through the
/// View-layer file-picker closure so no modal is reachable from the model/tool.
struct CommandLineBar: View {
    /// The live canvas state: command routing, suggestions, recents, keyword options.
    @Bindable var model: CanvasModel

    /// The single backing string for the merged line (host-owned `@State`, so the host
    /// can clear/load it from the menu / `/` launcher / canvas Space hook).
    @Binding var text: String

    /// The single focus flag for the merged line (host-owned `@FocusState`). All focus
    /// entry points (`/` keypress, ⇧⌘L menu, canvas Space → `requestCommandFocus`) drive
    /// THIS one flag.
    var focused: FocusState<Bool>.Binding

    /// Tools already PINNED to the toolbar — excluded from the Recent chips so the row
    /// never duplicates a button the user already has.
    var pinned: Set<ToolKind> = []

    /// Activate a tool the standard way (host wires this to the controller's
    /// `activateTool`, the same call the toolbar makes). `.image` is handled by
    /// `placeImage` instead, never here.
    let activateTool: (ToolKind) -> Void

    /// Begin Image placement via the View-layer file-picker (host wires this to
    /// `chooseAndPlaceImage`). The modal `NSOpenPanel` lives ONLY in the View layer.
    let placeImage: () -> Void

    /// Return keyboard focus to the canvas (host wires this to the canvas controller's
    /// `returnFocusToCanvas`) so tool letter-shortcuts work again.
    let returnFocusToCanvas: () -> Void

    /// Ask the canvas to repaint after a command line action committed geometry / moved
    /// the preview (host wires this to the controller's `requestRedraw`).
    let requestRedraw: () -> Void

    /// The keyboard-highlighted dropdown row index (into `model.commandBarSuggestions`).
    @State private var highlighted: Int = 0

    // MARK: Derived state

    /// Whether a draw/edit tool is currently armed (drives the prompt-vs-recents state).
    /// Reads the model's canonical `isToolActive` (`activeToolKind != .select`).
    private var toolActive: Bool { model.isToolActive }

    /// The current auxiliary display mode (pure classification).
    private var mode: CommandLineDisplayMode {
        CommandLineState.classify(
            text: text,
            toolActive: toolActive,
            hasSuggestions: !model.commandBarSuggestions.isEmpty
        )
    }

    /// Whether the autocomplete dropdown is showing right now.
    private var dropdownVisible: Bool {
        CommandLineState.showsDropdown(
            text: text,
            focused: focused.wrappedValue,
            toolActive: toolActive,
            hasSuggestions: !model.commandBarSuggestions.isEmpty
        )
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            promptIcon
            inputField
            Divider().frame(height: DS.Size.barDivider)
            auxiliaryRegion
        }
        .barStrip(dividerEdge: .top)
        // The autocomplete dropdown opens UPWARD over the canvas (the bar is at the
        // window bottom), anchored to the bar's top-leading corner.
        .overlay(alignment: .topLeading) { dropdownOverlay }
        // Mirror the single host `@State` text into the model's `commandBarQuery` so the
        // pure `commandBarSuggestions` (which ranks off that query) recompute as the user
        // types — and reset the keyboard highlight to the top match.
        .onChange(of: text) { _, new in
            model.commandBarQuery = new
            highlighted = 0
        }
        // On (re)appear, seed the query mirror so a pre-loaded recent chip / restored
        // text shows its suggestions immediately.
        .onAppear { model.commandBarQuery = text }
    }

    // MARK: - Left: prompt icon + the single text field

    /// The leading glyph: a `command` mark when idle, the active tool's icon when a
    /// tool is armed (so the prompt reads as "this tool wants input").
    @ViewBuilder
    private var promptIcon: some View {
        Image(systemName: toolActive ? ToolCatalog.metadata(for: model.activeToolKind).symbol : "command")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .frame(width: DS.Size.rowIcon)
    }

    /// The ONE text field for both commands and coordinates. ⏎ routes through the model;
    /// Esc clears + returns focus to the canvas; ↑/↓ drive the dropdown highlight.
    @ViewBuilder
    private var inputField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(DS.Font.rowValue)            // monospaced-digit — coordinates align
            .focused(focused)
            .onSubmit { submit() }
            .onExitCommand { clearAndReturnToCanvas() }
            .onKeyPress(.upArrow) { moveHighlight(-1) }
            .onKeyPress(.downArrow) { moveHighlight(1) }
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)
    }

    /// The field placeholder: the active-tool step + coordinate syntax when a tool is
    /// armed, else a neutral "type a command or coordinate" hint.
    private var placeholder: String {
        let hint = model.commandHint
        return hint.isEmpty ? "Command — type a tool name or coordinate (x,y · @dx,dy · dist<angle)" : hint
    }

    // MARK: - Right: prompt / keyword chips / recents / error

    /// The trailing region, chosen by `mode`: the active-tool prompt + keyword chips, the
    /// Recent chips, a coordinate note, a no-match note — plus a trailing red error echo.
    @ViewBuilder
    private var auxiliaryRegion: some View {
        HStack(spacing: DS.Space.md) {
            switch mode {
            case .toolPrompt:  toolPromptRow
            case .recents:     recentsRow
            case .coordinate:  coordinateRow
            case .suggestions: typingHintRow      // the dropdown carries the matches
            case .noMatch:     noMatchRow
            }
            Spacer(minLength: 0)
            errorEcho
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Active-tool state (empty field): the tool's prompt readout + its bracket keyword
    /// chips (`[Close] [Undo]`, `[2P] [3P]`). Tapping a chip dispatches the keyword.
    @ViewBuilder
    private var toolPromptRow: some View {
        Text(model.toolStepReadout)
            .font(DS.Font.secondaryLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        let options = model.activeToolKeywordOptions
        if !options.isEmpty {
            Divider().frame(height: DS.Size.barDivider)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.sm) {
                    ForEach(options, id: \.keyword) { kw in
                        keywordChip(kw)
                    }
                }
                .padding(.vertical, DS.Space.xxs)
            }
        }
    }

    /// Empty field, no tool: a quiet hint + a clearly-labeled Recent row. Tapping a chip
    /// LOADS the command word into the field (keeps focus) — it does NOT execute.
    @ViewBuilder
    private var recentsRow: some View {
        let recents = model.commandBarRecents(pinned: pinned)
        Text("Type a command")
            .font(DS.Font.hint)
            .foregroundStyle(.tertiary)
        if !recents.isEmpty {
            Divider().frame(height: DS.Size.barDivider)
            Text("Recent")
                .font(DS.Font.secondaryLabel)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.sm) {
                    ForEach(recents, id: \.self) { kind in
                        recentChip(kind)
                    }
                }
                .padding(.vertical, DS.Space.xxs)
            }
        }
    }

    /// Coordinate text: a quiet note that ⏎ feeds the active tool the exact point.
    @ViewBuilder
    private var coordinateRow: some View {
        Text(toolActive ? "Press ⏎ to place this point" : "Start a tool first, then type a coordinate")
            .font(DS.Font.secondaryLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Command word with matches: the dropdown (the upward overlay) carries them; this
    /// inline slot just nudges the user up to the list.
    @ViewBuilder
    private var typingHintRow: some View {
        Text("↑↓ to choose · ⏎ to run")
            .font(DS.Font.hint)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    /// Command word with no matches.
    @ViewBuilder
    private var noMatchRow: some View {
        Text("No matching command")
            .font(DS.Font.secondaryLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The trailing red error echo (a parse error / unknown command), if any.
    @ViewBuilder
    private var errorEcho: some View {
        if let error = model.lastCommandError, !error.isEmpty {
            Text(error)
                .font(DS.Font.secondaryLabel)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    // MARK: - Chips

    /// An AutoCAD-style bracket keyword chip (`[Close]`, `[2P]`). Tapping dispatches the
    /// keyword through the SAME model entry a typed keyword uses.
    @ViewBuilder
    private func keywordChip(_ kw: ToolKeyword) -> some View {
        Button {
            model.invokeToolKeyword(kw.keyword)
            focused.wrappedValue = true   // keep the field hot so the next coordinate lands here
            requestRedraw()
        } label: {
            Text("[\(kw.label)]")
                .font(DS.Font.secondaryLabel.monospaced())
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xxs)
                .background(Capsule().fill(DS.Palette.accent.opacity(0.14)))
                .foregroundStyle(DS.Palette.accent)
        }
        .buttonStyle(.plain)
        .help("Option: \(kw.label)")
    }

    /// A Recent command chip: SF Symbol + title. Tapping LOADS the command word into the
    /// field text and keeps focus (Wave-4 behavior change — does NOT execute).
    @ViewBuilder
    private func recentChip(_ kind: ToolKind) -> some View {
        Button {
            text = kind.title
            focused.wrappedValue = true
            highlighted = 0
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: ToolCatalog.metadata(for: kind).symbol)
                    .font(.caption)
                Text(kind.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help("Load “\(kind.title)” into the command line")
    }

    // MARK: - Autocomplete dropdown (opens UPWARD)

    /// The autocomplete dropdown, floated ABOVE the bar (it grows up off the bar's top
    /// edge, over the canvas). Only built while `dropdownVisible`. Reuses the
    /// `CommandPalette` row layout (icon + title + shortcut + selection highlight).
    @ViewBuilder
    private var dropdownOverlay: some View {
        if dropdownVisible {
            dropdownList
                // Anchor the list ABOVE the bar: place its BOTTOM at the bar's top edge.
                .alignmentGuide(.top) { d in d[.bottom] }
                .padding(.leading, DS.Size.barPadH)
        }
    }

    /// The ranked suggestion rows in a bottom-anchored card that opens upward.
    @ViewBuilder
    private var dropdownList: some View {
        let suggestions = model.commandBarSuggestions
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, kind in
                dropdownRow(kind, isSelected: index == clampedHighlight(suggestions.count))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        highlighted = index
                        activate(kind)
                    }
                    .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(.vertical, DS.Space.sm)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(radius: 18, y: -6)
        .padding(.bottom, DS.Space.sm)
    }

    /// One dropdown row — the `CommandPalette.row` layout, sourced from `ToolCatalog`.
    @ViewBuilder
    private func dropdownRow(_ kind: ToolKind, isSelected: Bool) -> some View {
        let meta = ToolCatalog.metadata(for: kind)
        HStack(spacing: DS.Space.md) {
            Image(systemName: meta.symbol)
                .frame(width: DS.Size.rowIcon)
                .foregroundStyle(isSelected ? DS.Palette.onAccent : .secondary)
            Text(kind.title)
                .foregroundStyle(isSelected ? DS.Palette.onAccent : .primary)
            Spacer(minLength: DS.Space.lg)
            if let shortcut = meta.shortcut {
                Text(shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(isSelected ? DS.Palette.onAccent.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.selection)
                    .fill(DS.Palette.accent)
                    .padding(.horizontal, DS.Space.xs)
            }
        }
    }

    // MARK: - Behavior

    /// ⏎ — route the line through the already-merged `interpretCommandLine`. While the
    /// dropdown is showing, ⏎ activates the HIGHLIGHTED suggestion (so ↑/↓ + ⏎ works);
    /// otherwise the model's classifier decides (keyword → coordinate → command).
    private func submit() {
        let suggestions = model.commandBarSuggestions
        if dropdownVisible, suggestions.indices.contains(clampedHighlight(suggestions.count)) {
            activate(suggestions[clampedHighlight(suggestions.count)])
            return
        }
        switch model.interpretCommandLine(text) {
        case .empty, .handled:
            text = ""
            requestRedraw()
        case .activateTool(let kind):
            text = ""
            launch(kind)
        case .error:
            // Keep the text so the user can fix the typo; the red echo shows the message.
            break
        }
    }

    /// Activate a SUGGESTION the user chose from the dropdown / typing flow: record the
    /// MRU (so the launcher biases toward it), clear the field, then launch (View-side so
    /// `.image` opens the panel). Mirrors the model's `interpretCommandLine` MRU step.
    private func activate(_ kind: ToolKind) {
        model.recordCommandBarUse(kind)
        text = ""
        launch(kind)
    }

    /// View-side tool launch: `.image` routes through the file-picker (the modal lives in
    /// the View layer only); everything else through the standard `activateTool`. After a
    /// launch, focus returns to the canvas so the next click / typed coordinate lands on
    /// the drawing, not the field.
    private func launch(_ kind: ToolKind) {
        if kind == .image {
            placeImage()
        } else {
            activateTool(kind)
        }
        focused.wrappedValue = false
        returnFocusToCanvas()
    }

    /// ↑/↓ — move the dropdown highlight (only while the dropdown is up; otherwise let
    /// the system handle the arrow, e.g. caret movement). Returns `.handled`/`.ignored`.
    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        let count = model.commandBarSuggestions.count
        guard dropdownVisible, count > 0 else { return .ignored }
        highlighted = (clampedHighlight(count) + delta + count) % count
        return .handled
    }

    /// The keyboard highlight clamped/wrapped into `[0, count)` (the suggestion list can
    /// shrink under typing, leaving a stale index).
    private func clampedHighlight(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(highlighted, 0), count - 1)
    }

    /// Esc — clear the field + the error and return focus to the canvas.
    private func clearAndReturnToCanvas() {
        text = ""
        focused.wrappedValue = false
        returnFocusToCanvas()
    }
}
