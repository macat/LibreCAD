//
//  BlockNamePrompt.swift
//  LibreCADmacOS
//
//  The "Create Block from Selection" NAME sheet (WAVE BW, Ask #1 — spec §2.1: the
//  BLOCK dialog asks for a name before converting a selection to a block). A small
//  View-layer modal: it asks the user to name the new block (prefilled with a
//  unique `Block-N`), validates that the name is non-empty, and warns — per spec §20
//  (Redefining Existing Blocks) — when the typed name matches an existing block, so
//  the user knows confirming will REDEFINE it. On confirm it hands the chosen name
//  back to the host, which calls `CanvasModel.beginCreateBlock(name:)`.
//
//  Modal discipline (project gotcha): this sheet is presented ONLY from a View-layer
//  `.sheet`/action closure in `ContentView`; nothing the headless test suite reaches
//  ever constructs or presents it. The VALIDATION (`Validation.classify`) is a pure,
//  side-effect-free value function so it is unit-testable WITHOUT presenting the UI.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

/// The block-name sheet. Self-contained: it owns the live text draft, derives the
/// validation state from `existingNames`, and reports the confirmed name (or cancel)
/// to the host. Decomposed into small `@ViewBuilder` subviews so the SwiftUI type
/// checker stays comfortable (project gotcha #2).
struct BlockNamePrompt: View {
    /// The title shown atop the sheet (so the same view serves "Create Block" and a
    /// future "Insert Block" picker without code change).
    var title: String = "Create Block from Selection"
    /// A one-line subtitle describing the action.
    var prompt: String = "Name the new block. The selected objects become its definition and are replaced with one block reference."
    /// The label for the confirm button.
    var confirmLabel: String = "Create Block"

    /// The existing block names in the document — drives the "this will redefine an
    /// existing block" warning (spec §20). Case-insensitive matched.
    let existingNames: [String]

    /// Reports the confirmed (trimmed, non-empty) name back to the host.
    let onConfirm: (String) -> Void
    /// Reports a cancel back to the host (dismiss with no action).
    let onCancel: () -> Void

    /// The live name draft, seeded with the suggested unique name on appear.
    @State private var draft: String

    /// Builds the sheet with a prefilled suggested name.
    init(suggestedName: String,
         existingNames: [String],
         title: String = "Create Block from Selection",
         prompt: String = "Name the new block. The selected objects become its definition and are replaced with one block reference.",
         confirmLabel: String = "Create Block",
         onConfirm: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.existingNames = existingNames
        self.title = title
        self.prompt = prompt
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._draft = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            nameField
            validationMessage
            Divider()
            buttons
        }
        .frame(minWidth: 380)
    }

    // MARK: - Subviews (decomposed for the type checker)

    @ViewBuilder private var header: some View {
        Text(title)
            .font(.headline)
            .padding([.top, .horizontal])
            .padding(.bottom, 4)
        Text(prompt)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    @ViewBuilder private var nameField: some View {
        TextField("Block name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { confirmIfValid() }
            .padding(.horizontal)
            .padding(.bottom, 6)
    }

    @ViewBuilder private var validationMessage: some View {
        switch validation {
        case .empty:
            label("Enter a name for the block.", systemImage: "exclamationmark.circle", tint: .secondary)
        case .redefine:
            label("A block named “\(trimmed)” already exists — confirming will redefine it (all its references update).",
                  systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .new:
            label("Creates a new block “\(trimmed)”.", systemImage: "checkmark.circle", tint: .secondary)
        }
    }

    @ViewBuilder private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(confirmLabel) { confirmIfValid() }
                .keyboardShortcut(.defaultAction)
                .disabled(validation == .empty)
        }
        .padding()
    }

    // MARK: - Derived

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validation: Validation {
        Validation.classify(name: draft, existingNames: existingNames)
    }

    private func confirmIfValid() {
        guard validation != .empty else { return }
        onConfirm(trimmed)
    }

    /// The pure validation classification of a typed block name against the existing
    /// block names — extracted so it unit-tests WITHOUT presenting the sheet.
    enum Validation: Equatable {
        /// Blank / whitespace-only → confirm disabled.
        case empty
        /// Matches an existing block (case-insensitive) → confirming REDEFINES it (§20).
        case redefine
        /// A fresh, unique name → creates a new block.
        case new

        /// Classifies `name` against `existingNames` (case-insensitive, whitespace
        /// trimmed). Pure value logic the sheet and the tests share.
        static func classify(name: String, existingNames: [String]) -> Validation {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return .empty }
            let lower = t.lowercased()
            return existingNames.contains { $0.lowercased() == lower } ? .redefine : .new
        }
    }
}
