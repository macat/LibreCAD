//
//  CommandBar.swift
//  LibreCADmacOS
//
//  The bottom COMMAND BAR — an AutoCAD-style command LINE pinned full-width at the
//  bottom of the window, ADDITIVE alongside the existing grouped Draw/Modify/Annotate
//  button toolbar (mouse users use the toolbar; keyboard users type here). Think
//  VS Code: the activity bar and ⌘P both present.
//
//  Wave 4 de-mirror (plan §3d): this is a TRUE command line, NOT a static mirror of a
//  default tool set. The layout (a single full-width strip):
//    • LEFT  — a `TextField` ("type a command…") that filters the tools as you type.
//    • RIGHT — context that depends on the query:
//        - EMPTY query → a quiet PROMPT HINT, plus (when the user has used tools) a
//          clearly-LABELED "Recent" row of those tools, EXCLUDING ones already pinned
//          to the toolbar (so it never duplicates a button they already have).
//        - TYPING      → the fuzzy-match TOOL CHIPS (SF Symbol + short label) across
//          EVERY tool. The chips appear ONLY while typing — there is no pre-typed
//          mirror of the toolbar's default set.
//
//  Behavior:
//    • ⏎ activates the top match (no-op on an empty query).
//    • clicking a chip / a Recent item activates that tool.
//    • Esc clears the query and returns focus to the canvas (so the canvas's letter
//      shortcuts work again).
//    • activating ANY tool routes through the model's command-bar activation (the SAME
//      `activateTool` path the toolbar uses) + updates the MRU + clears the query —
//      EXCEPT `.image`, which must trigger the View-layer `NSOpenPanel` file-picker (a
//      modal must never be reachable from the model/suggester/tool — it stays in this
//      View action, mirroring the toolbar's `chooseAndPlaceImage`).
//
//  All ranking/ordering is the PURE `ToolSuggester` in CADEngine (unit-tested there);
//  this view only renders what it returns and routes the taps. The body is decomposed
//  into many small `@ViewBuilder` helpers so the Swift type-checker never sees a large
//  monolithic expression (a known SwiftUI gotcha). Chrome routes through `DS` tokens +
//  `.barStrip(.top)` so its padding/material/divider match the rest of the bottom bar.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The bottom command-bar strip. Renders the filter field + (the prompt hint / Recent
/// row / fuzzy chips) and routes activations. State (query, MRU) lives on the
/// `CanvasModel`; focus is a `@FocusState` bound from the host so the canvas can hand
/// focus here on the launcher keystroke and reclaim it on Esc.
struct CommandBar: View {
    /// The live canvas state: the query, MRU, suggestions, and the activation path.
    @Bindable var model: CanvasModel

    /// Whether the bar's filter field holds keyboard focus. Bound to the host's
    /// `@FocusState` so the canvas's launcher keystroke focuses it and Esc/activation
    /// can return focus to the canvas (mirroring the U1 coordinate line's model).
    var focused: FocusState<Bool>.Binding

    /// The tools already PINNED to the primary toolbar. The empty-query "Recent" row
    /// excludes these so it never duplicates a button the user already has.
    var pinned: Set<ToolKind> = []

    /// Activate a tool the standard way (the host wires this to the controller's
    /// `activateTool`, the same call the toolbar makes). The `.image` kind is handled
    /// by `placeImage` instead, never here.
    let activateTool: (ToolKind) -> Void

    /// Begin Image placement via the View-layer file-picker (the host wires this to
    /// `chooseAndPlaceImage`). Kept as a closure so the modal `NSOpenPanel` lives in
    /// the View layer, never in the model/suggester/tool (headless-test-safe).
    let placeImage: () -> Void

    /// Return keyboard focus to the canvas (the host wires this to the canvas
    /// controller's `returnFocusToCanvas`), so tool letter-shortcuts work again.
    let returnFocusToCanvas: () -> Void

    /// Whether the user is currently typing a query (drives chips-vs-hint).
    private var isTyping: Bool {
        !model.commandBarQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            filterField
            Divider().frame(height: DS.Size.barDivider)
            resultRegion
        }
        .barStrip(dividerEdge: .top)
    }

    // MARK: - Left: the filter field

    /// The "type a command…" filter field. Typing narrows to fuzzy chips; ⏎ activates
    /// the top match; Esc clears + returns focus to the canvas.
    @ViewBuilder
    private var filterField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "command")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TextField("Type a command…", text: $model.commandBarQuery)
                .textFieldStyle(.plain)
                .font(.body)
                .focused(focused)
                .onSubmit { activateTopMatch() }
                .onExitCommand { clearAndReturnToCanvas() }
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
            if isTyping {
                Button {
                    model.commandBarQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
    }

    // MARK: - Right: prompt hint / Recent row / fuzzy chips

    /// The trailing region: the fuzzy chips while typing, otherwise the prompt hint
    /// plus a labeled Recent row (when there are recents). De-mirror: NO static set.
    @ViewBuilder
    private var resultRegion: some View {
        if isTyping {
            chipRow
        } else {
            emptyStateRow
        }
    }

    /// Empty-query state: a quiet prompt hint, and — when the user has recents — a
    /// clearly-LABELED "Recent" row of those tools (minus the pinned ones).
    @ViewBuilder
    private var emptyStateRow: some View {
        let recents = model.commandBarRecents(pinned: pinned)
        HStack(spacing: DS.Space.md) {
            Text("Type to find a tool")
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
                            chip(kind, isTopMatch: false)
                        }
                    }
                    .padding(.vertical, DS.Space.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The horizontal, scrollable row of fuzzy-match tool chips (typing only). A "no
    /// match" placeholder keeps the row from collapsing when a query matches nothing.
    @ViewBuilder
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.sm) {
                let suggestions = model.commandBarSuggestions
                if suggestions.isEmpty {
                    noMatchLabel
                } else {
                    ForEach(suggestions, id: \.self) { kind in
                        chip(kind, isTopMatch: kind == model.commandBarTopMatch)
                    }
                }
            }
            .padding(.vertical, DS.Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One tool chip: SF Symbol + short label, activating the tool on tap. The top
    /// match (what ⏎ fires) gets a tinted highlight so the keyboard target is clear.
    @ViewBuilder
    private func chip(_ kind: ToolKind, isTopMatch: Bool) -> some View {
        Button {
            activate(kind)
        } label: {
            chipLabel(kind, isTopMatch: isTopMatch)
        }
        .buttonStyle(.plain)
        .help(ToolCatalog.metadata(for: kind).help)
    }

    /// The visual content of a chip: glyph + title in a rounded capsule, tinted when
    /// it is the current active tool or the top fuzzy match.
    @ViewBuilder
    private func chipLabel(_ kind: ToolKind, isTopMatch: Bool) -> some View {
        let meta = ToolCatalog.metadata(for: kind)
        let active = model.activeToolKind == kind
        HStack(spacing: DS.Space.xs) {
            Image(systemName: meta.symbol)
                .font(.caption)
            Text(kind.title)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.xs)
        .background(chipBackground(active: active, isTopMatch: isTopMatch))
        .foregroundStyle(active || isTopMatch ? DS.Palette.onAccent : .primary)
    }

    /// The chip's capsule fill: the accent tint for the active tool, a lighter accent
    /// for the keyboard top-match, and a subtle neutral fill otherwise.
    @ViewBuilder
    private func chipBackground(active: Bool, isTopMatch: Bool) -> some View {
        if active {
            Capsule().fill(DS.Palette.accent)
        } else if isTopMatch {
            Capsule().fill(DS.Palette.accent.opacity(0.65))
        } else {
            Capsule().fill(Color.secondary.opacity(0.12))
        }
    }

    /// Shown when a non-empty query matches no tool.
    @ViewBuilder
    private var noMatchLabel: some View {
        Text("No matching tools")
            .font(DS.Font.secondaryLabel)
            .foregroundStyle(.secondary)
            .padding(.vertical, DS.Space.xs)
    }

    // MARK: - Actions

    /// Activates a tool from the bar. `.image` routes through the View-layer
    /// file-picker (recording MRU first so a placed image still biases the bar);
    /// everything else routes through the model's command-bar activation (which calls
    /// the same `activateTool` path, updates the MRU, and clears the query). After a
    /// successful activation focus returns to the canvas so the user can place points.
    private func activate(_ kind: ToolKind) {
        if kind == .image {
            model.recordCommandBarUse(.image)
            model.commandBarQuery = ""
            placeImage()
        } else {
            // The model funnels through `activateTool` so behavior is identical to the
            // toolbar; the View still owns the actual controller call (the closure),
            // so we activate via the host closure AND update the model's launcher state.
            model.recordCommandBarUse(kind)
            model.commandBarQuery = ""
            activateTool(kind)
        }
        // Hand focus back to the canvas so the next click / typed coordinate lands on
        // the drawing, not the filter field.
        focused.wrappedValue = false
        returnFocusToCanvas()
    }

    /// ⏎ — activates the top fuzzy match, if any. No-op on an empty query (so a stray
    /// Return in an empty launcher does nothing, per the focus model).
    private func activateTopMatch() {
        guard let top = model.commandBarTopMatch else { return }
        activate(top)
    }

    /// Esc — clear the query and return focus to the canvas.
    private func clearAndReturnToCanvas() {
        model.commandBarQuery = ""
        focused.wrappedValue = false
        returnFocusToCanvas()
    }
}
