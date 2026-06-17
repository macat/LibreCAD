//
//  Transcript.swift
//  LibreCADmacOS
//
//  The COMMAND TRANSCRIPT — an AutoCAD-style command-history scrollback pane that sits
//  ABOVE the merged command line (`CommandLineBar`) in the bottom chrome stack
//  (LayoutTabStrip → [Transcript when shown] → CommandLineBar → StatusBar). It is a
//  PASSIVE, read-only readout of `CanvasModel.commandTranscript`: every line the user
//  submitted through the merged command line (the `interpretCommandLine` choke point)
//  is echoed here — the raw input (`> line`), the activated tool, a resolved-coordinate
//  readout, and parse/unknown-command errors in red.
//
//  Design constraints (why it's built the way it is):
//    • READ-ONLY + non-focus-stealing. The pane must never grab keyboard focus from the
//      command line — it's a history readout, not an editor. Rows render as `Text`
//      (selectable via `.textSelection(.enabled)` so a user can copy a line), but the
//      pane installs NO `@FocusState` and no focusable controls in the row body.
//    • Auto-scrolls to the NEWEST line (`ScrollViewReader`) as entries arrive, the way a
//      terminal/AutoCAD command history pins to the bottom.
//    • Small fixed height (~5 rows) so it never crowds the canvas; the buffer itself is
//      capped on the MODEL side (`maxTranscriptEntries`), so this view only renders.
//    • Color-coded by `TranscriptKind`: input = primary, output = secondary, tool =
//      accent, error = red. Monospaced (`DS.Font.rowValue`) so coordinate readouts align.
//    • Chrome via the shared `.barStrip` primitive + `DS` tokens (no inline literals).
//
//  The body is decomposed into small `@ViewBuilder` helpers so the Swift type-checker
//  never sees a monolithic expression (the project's standing SwiftUI rule).
//
//  No NSView / modal / panel is reachable from here, so the headless test suite can drive
//  the underlying model freely without a hang.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

// MARK: - Pure presentation helpers (no SwiftUI state — unit-testable)

/// Pure presentation rules for the transcript, kept side-effect-free so they unit-test
/// without a GPU / live view. The SwiftUI `CommandTranscriptView` below consumes them.
enum TranscriptPresentation {
    /// The scrollback's fixed display height (about five monospaced rows). Small enough
    /// that the pane never crowds the canvas; the row content scrolls within it.
    static let paneHeight: CGFloat = 110

    /// A stable identity for a transcript row at `index`. The model's entries are appended
    /// in order and only ever dropped from the FRONT (the ring-buffer cap), so the index
    /// is a safe, monotonic-enough id for `ScrollViewReader` to scroll the newest into
    /// view; the list is rebuilt wholesale on each `modelVersion` bump regardless.
    static func rowID(_ index: Int) -> Int { index }

    /// The color for a transcript line by kind: input = primary, output = secondary,
    /// tool = accent, error = red. Pure (no actor isolation) so it unit-tests headlessly
    /// and the SwiftUI view delegates to it.
    static func color(for kind: CanvasModel.TranscriptKind) -> Color {
        switch kind {
        case .input:  return .primary
        case .output: return .secondary
        case .tool:   return DS.Palette.accent
        case .error:  return .red
        }
    }
}

// MARK: - The scrollback view

/// The AutoCAD-style command-history scrollback pane mounted ABOVE the merged command
/// line. Read-only + passive: it renders `model.commandTranscript`, color-codes each row
/// by kind, auto-scrolls to the newest line, and never takes keyboard focus from the
/// command field. A small "Clear" affordance empties the history (`model.clearTranscript`).
struct CommandTranscriptView: View {
    /// The live canvas state — the transcript is `model.commandTranscript` (observed, so
    /// the list refreshes + auto-scrolls when the model appends via `interpretCommandLine`).
    @Bindable var model: CanvasModel

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            scrollback
            clearButton
        }
        .frame(height: TranscriptPresentation.paneHeight)
        .barStrip(dividerEdge: .top)
        // Belt-and-suspenders: the pane is a passive readout, so it must never become a
        // keyboard-focus target that would steal the command line's focus.
        .focusable(false)
    }

    // MARK: - Scrollback list (auto-scrolls to the newest line)

    /// The scrolling history rows. A `ScrollViewReader` pins the view to the newest entry
    /// as lines arrive (terminal/AutoCAD behavior). Empty state shows a quiet hint.
    @ViewBuilder
    private var scrollback: some View {
        if model.commandTranscript.isEmpty {
            emptyHint
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    rows
                }
                .onChange(of: model.commandTranscript.count) { _, newCount in
                    scrollToNewest(proxy, count: newCount)
                }
                .onAppear { scrollToNewest(proxy, count: model.commandTranscript.count) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The transcript rows, top-aligned and left-aligned, each tagged with its index id so
    /// the `ScrollViewReader` can scroll the newest into view.
    @ViewBuilder
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: DS.Space.xxs) {
            ForEach(Array(model.commandTranscript.enumerated()), id: \.offset) { index, entry in
                transcriptRow(entry)
                    .id(TranscriptPresentation.rowID(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DS.Space.xxs)
    }

    /// One transcript line: monospaced text color-coded by its kind, selectable (so a user
    /// can copy a coordinate / error) but never focusable as an editor.
    @ViewBuilder
    private func transcriptRow(_ entry: CanvasModel.TranscriptEntry) -> some View {
        Text(entry.text)
            .font(DS.Font.rowValue)
            .foregroundStyle(TranscriptPresentation.color(for: entry.kind))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// The quiet placeholder shown while the history is empty.
    @ViewBuilder
    private var emptyHint: some View {
        Text("Command history — your typed commands and results appear here")
            .font(DS.Font.hint)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Clear affordance

    /// A small "Clear" button that empties the history. Disabled while already empty. It
    /// is the only control in the pane; tapping it does NOT touch the command-line focus.
    @ViewBuilder
    private var clearButton: some View {
        Button {
            model.clearTranscript()
        } label: {
            Image(systemName: "trash")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(model.commandTranscript.isEmpty)
        .help("Clear the command history")
    }

    // MARK: - Behavior

    /// Scroll the scrollback so the NEWEST (last) row is visible. No-op when empty.
    private func scrollToNewest(_ proxy: ScrollViewProxy, count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(TranscriptPresentation.rowID(count - 1), anchor: .bottom)
        }
    }
}
