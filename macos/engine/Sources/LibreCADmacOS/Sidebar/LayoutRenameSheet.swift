//
//  LayoutRenameSheet.swift
//  LibreCADmacOS
//
//  The layout-tab RENAME sheet (backlog #4c — the Model/Layout tab strip's right-click
//  "Rename…" action). A small View-layer modal: it asks the user for a new name for a
//  paper-space layout, prefilled with the current name, and validates it against the
//  other layout names (a name that collides with a DIFFERENT layout is rejected; the
//  current name unchanged is accepted as a harmless no-op-or-recase). On confirm it
//  hands the trimmed new name back to the host (`LayoutTabStrip`), which calls the
//  P0-D `CanvasModel.renameLayout(_:to:)` wrapper.
//
//  Modal discipline (project gotcha): this sheet is presented ONLY from a View-layer
//  `.sheet` in `LayoutTabStrip`; nothing the headless test suite reaches ever
//  constructs or presents it. The VALIDATION (`Validation.classify`) is a pure,
//  side-effect-free value function so it is unit-testable WITHOUT presenting the UI
//  (mirrors `BlockNamePrompt.Validation`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI

/// The layout-rename sheet. Self-contained: it owns the live text draft, derives the
/// validation state from the OTHER layout names, and reports the confirmed new name (or
/// a cancel) to the host. Decomposed into small `@ViewBuilder` subviews so the SwiftUI
/// type checker stays comfortable (project gotcha #2).
struct LayoutRenameSheet: View {
    /// The layout's current name (prefilled into the field; excluded from the collision
    /// check so renaming to the SAME name — or a recase of it — is allowed).
    let currentName: String
    /// ALL layout names in the document (including `currentName`); the collision check
    /// excludes `currentName` so only a clash with a DIFFERENT layout is rejected.
    let existingNames: [String]

    /// Reports the confirmed (trimmed, non-empty, non-colliding) new name to the host.
    let onConfirm: (String) -> Void
    /// Reports a cancel back to the host (dismiss with no action).
    let onCancel: () -> Void

    /// The live name draft, seeded with the current name on appear.
    @State private var draft: String

    init(currentName: String,
         existingNames: [String],
         onConfirm: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.currentName = currentName
        self.existingNames = existingNames
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._draft = State(initialValue: currentName)
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
        Text("Rename Layout")
            .font(.headline)
            .padding([.top, .horizontal])
            .padding(.bottom, 4)
        Text("Rename the “\(currentName)” layout.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }

    @ViewBuilder private var nameField: some View {
        TextField("Layout name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { confirmIfValid() }
            .padding(.horizontal)
            .padding(.bottom, 6)
    }

    @ViewBuilder private var validationMessage: some View {
        switch validation {
        case .empty:
            label("Enter a name for the layout.", systemImage: "exclamationmark.circle", tint: .secondary)
        case .collision:
            label("A layout named “\(trimmed)” already exists — choose a different name.",
                  systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .unchanged:
            label("This is the current name.", systemImage: "checkmark.circle", tint: .secondary)
        case .ok:
            label("Renames the layout to “\(trimmed)”.", systemImage: "checkmark.circle", tint: .secondary)
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
            Button("Rename") { confirmIfValid() }
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isConfirmable)
        }
        .padding()
    }

    // MARK: - Derived

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validation: Validation {
        Validation.classify(newName: draft, currentName: currentName, existingNames: existingNames)
    }

    private func confirmIfValid() {
        guard validation.isConfirmable else { return }
        onConfirm(trimmed)
    }

    /// The pure validation classification of a typed layout name against the document's
    /// other layout names — extracted so it unit-tests WITHOUT presenting the sheet
    /// (mirrors `BlockNamePrompt.Validation`).
    enum Validation: Equatable {
        /// Blank / whitespace-only → confirm disabled.
        case empty
        /// Matches a DIFFERENT existing layout (case-insensitive) → confirm disabled.
        case collision
        /// Equal to the current name (case-insensitive) → confirm allowed (a no-op /
        /// recase; the model rename wrapper handles an unchanged name safely).
        case unchanged
        /// A fresh, unique name → confirm allowed.
        case ok

        /// Whether the confirm button is enabled for this classification.
        var isConfirmable: Bool {
            switch self {
            case .empty, .collision: return false
            case .unchanged, .ok:    return true
            }
        }

        /// Classifies `newName` against the document's layouts (case-insensitive,
        /// whitespace-trimmed). `currentName` is excluded from the collision check so
        /// renaming to the same name (or its recase) is `.unchanged`, not `.collision`.
        /// Pure value logic the sheet and the tests share.
        static func classify(newName: String, currentName: String, existingNames: [String]) -> Validation {
            let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return .empty }
            let lower = t.lowercased()
            if lower == currentName.lowercased() { return .unchanged }
            let others = existingNames.filter { $0.lowercased() != currentName.lowercased() }
            return others.contains { $0.lowercased() == lower } ? .collision : .ok
        }
    }
}
