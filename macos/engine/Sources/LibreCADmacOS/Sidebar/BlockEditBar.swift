//
//  BlockEditBar.swift
//  LibreCADmacOS
//
//  The Block Editor context bar (WAVE BW, Ask #2 — spec §4 BEDIT). A prominent strip
//  shown ONLY while an in-place block-edit session is active (`CanvasModel.isEditingBlock`),
//  mirroring AutoCAD's distinct Block-Editor chrome: it names the block being edited
//  ("Editing block: <name>") and offers the two ways out —
//
//    • Save & Close  → `exitBlockEditing(save: true)`  (keep edits; every insert of the
//                       block updates automatically via the engine's live-member resolve)
//    • Discard       → `exitBlockEditing(save: false)` (revert to entry-state geometry)
//
//  It is presentational: it reads the live `CanvasModel` and calls the two engine
//  session APIs, then asks the canvas controller to repaint (the renderer is on-demand;
//  leaving the editor changes the visible scope + camera). When NOT editing it renders
//  nothing (zero height), so it costs nothing in the common case.
//
//  Placed by `ContentView` near the top of the canvas (a `safeAreaInset(edge: .top)`),
//  above the tool-options bar, so it reads like AutoCAD's contextual Block-Editor tab.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The contextual Block-Editor bar. Visible only during a block-edit session; renders
/// `EmptyView` (no chrome) otherwise. Decomposed into small subviews for the SwiftUI
/// type checker (project gotcha #2).
struct BlockEditBar: View {
    /// The live canvas state. Observed, so the bar appears the instant a session starts
    /// (double-click an insert / sidebar Edit) and disappears on exit.
    @Bindable var model: CanvasModel

    /// Called after a Save & Close / Discard so the host can repaint the canvas (the
    /// renderer is on-demand; leaving the editor re-scopes the view + camera).
    let onExit: () -> Void

    var body: some View {
        if model.isEditingBlock {
            bar
        }
    }

    @ViewBuilder private var bar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square.dashed")
                .foregroundStyle(.tint)
            Text("Editing block:")
                .foregroundStyle(.secondary)
            // For a NESTED session show the breadcrumb (e.g. "A ▸ B"), so it is clear
            // which level Save&Close / Discard acts on (the deepest/right-most block).
            Text(breadcrumb)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button("Discard", role: .cancel) { exit(save: false) }
                .help("Discard this block's changes and leave (pops one nested level)")
            Button("Save & Close") { exit(save: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .help("Apply this block's changes — every reference to it updates "
                      + "(pops one nested level)")
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Editing block \(breadcrumb)")
    }

    /// The session breadcrumb shown in the bar: the open block names OUTERMOST → innermost
    /// joined by " ▸ " (e.g. "A ▸ B"), or just the single block when not nested. Falls back
    /// to the top block name if the stack read is empty (defensive — `bar` only renders
    /// while a session is open).
    private var breadcrumb: String {
        let stack = model.editingBlockStack
        if !stack.isEmpty { return stack.joined(separator: " ▸ ") }
        return model.editingBlock ?? ""
    }

    /// Leaves the session (keep or revert) and repaints the canvas.
    private func exit(save: Bool) {
        _ = model.exitBlockEditing(save: save)
        onExit()
    }
}
