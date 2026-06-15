//
//  CommandBar.swift
//  LibreCADmacOS
//
//  The bottom COMMAND BAR — an AutoCAD-style tool launcher pinned full-width at the
//  bottom of the window, ADDITIVE alongside the existing grouped Draw/Modify/Annotate
//  button toolbar (mouse users use the toolbar; keyboard users type here). Think
//  VS Code: the activity bar and ⌘P both present.
//
//  Layout (a single full-width strip):
//    • LEFT  — a `TextField` ("type a command…") that filters the tools as you type.
//    • RIGHT — a horizontal row of TOOL CHIPS (SF Symbol + short label). Before you
//              type, the chips are the ADAPTIVE default set (a curated core blended
//              with most-recently-used + a selection-context bias). As you type, the
//              chips narrow to the fuzzy matches across EVERY tool.
//
//  Behavior:
//    • ⏎ activates the top match (no-op on an empty query).
//    • clicking a chip activates that tool.
//    • Esc clears the query and returns focus to the canvas (so the canvas's letter
//      shortcuts work again).
//    • activating ANY tool routes through `CanvasModel.activateToolFromCommandBar`
//      (the SAME `activateTool` path the toolbar uses) + updates the MRU + clears the
//      query — EXCEPT `.image`, which must trigger the View-layer `NSOpenPanel`
//      file-picker (a modal must never be reachable from the model/suggester/tool —
//      it stays in this View action, mirroring the toolbar's `chooseAndPlaceImage`).
//
//  All ranking/ordering is the PURE `ToolSuggester` in CADEngine (unit-tested there);
//  this view only renders what it returns and routes the taps. The body is decomposed
//  into many small `@ViewBuilder` helpers so the Swift type-checker never sees a large
//  monolithic expression (a known SwiftUI gotcha).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The bottom command-bar strip. Renders the filter field + the tool chips and
/// routes activations. State (query, MRU) lives on the `CanvasModel`; focus is a
/// `@FocusState` bound from the host so the canvas can hand focus here on the
/// launcher keystroke and reclaim it on Esc.
struct CommandBar: View {
    /// The live canvas state: the query, MRU, suggestions, and the activation path.
    @Bindable var model: CanvasModel

    /// Whether the bar's filter field holds keyboard focus. Bound to the host's
    /// `@FocusState` so the canvas's launcher keystroke focuses it and Esc/activation
    /// can return focus to the canvas (mirroring the U1 coordinate line's model).
    var focused: FocusState<Bool>.Binding

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

    var body: some View {
        HStack(spacing: 10) {
            filterField
            Divider().frame(height: 18)
            chipRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Left: the filter field

    /// The "type a command…" filter field. Typing narrows the chips; ⏎ activates the
    /// top match; Esc clears + returns focus to the canvas.
    @ViewBuilder
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "command")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            TextField("Type a command…  (try “rect”, “dim”, “ci”)", text: $model.commandBarQuery)
                .textFieldStyle(.plain)
                .font(.body)
                .focused(focused)
                .onSubmit { activateTopMatch() }
                .onExitCommand { clearAndReturnToCanvas() }
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
            if !model.commandBarQuery.isEmpty {
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

    // MARK: - Right: the tool chips

    /// The horizontal, scrollable row of tool chips for the current suggestions.
    /// Empty query ⇒ the adaptive set; otherwise the fuzzy matches. A "no match"
    /// placeholder keeps the row from collapsing when a query matches nothing.
    @ViewBuilder
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let suggestions = model.commandBarSuggestions
                if suggestions.isEmpty {
                    noMatchLabel
                } else {
                    ForEach(suggestions, id: \.self) { kind in
                        chip(kind, isTopMatch: kind == model.commandBarTopMatch)
                    }
                }
            }
            .padding(.vertical, 2)
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
        HStack(spacing: 4) {
            Image(systemName: meta.symbol)
                .font(.caption)
            Text(kind.title)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(chipBackground(active: active, isTopMatch: isTopMatch))
        .foregroundStyle(active || isTopMatch ? Color.white : .primary)
    }

    /// The chip's capsule fill: the tint for the active tool, a lighter tint for the
    /// keyboard top-match, and a subtle neutral fill otherwise.
    @ViewBuilder
    private func chipBackground(active: Bool, isTopMatch: Bool) -> some View {
        if active {
            Capsule().fill(.tint)
        } else if isTopMatch {
            Capsule().fill(.tint.opacity(0.65))
        } else {
            Capsule().fill(Color.secondary.opacity(0.12))
        }
    }

    /// Shown when a non-empty query matches no tool.
    @ViewBuilder
    private var noMatchLabel: some View {
        Text("No matching tools")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
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
