//
//  DimStyleManagerView.swift
//  LibreCADmacOS
//
//  A standalone DIMENSION STYLE MANAGER panel (feature-gap Wave 2B). A sheet/panel-
//  style SwiftUI view over the focused window's `CanvasModel`/`CADDrawing` that lets
//  the user manage the drawing's NAMED dimension styles (the DXF DIMSTYLE table):
//  list them, add / rename / delete a style, set the document-active ("current")
//  style, and edit the common `NamedDimStyle` fields (text height, arrow size, overall
//  scale, the measurement-text linear format + precision, and the ext-line offsets
//  DIMEXO/DIMEXE/DIMGAP).
//
//  ## Where this fits (vs. Document Settings ▸ Dimensions)
//  The Document Settings "Dimensions" tab edits the document-DEFAULT dimension style
//  (the `$DIM*` header vars — the fallback a dimension uses when it names no style).
//  THIS manager edits the NAMED styles a dimension can reference by name (DXF code 3),
//  via `CADDrawing.mutateDimStyles` / `upsertDimStyle`. Resolve precedence (decision
//  D4, extended): per-entity override > the referenced named style > the header default.
//
//  ## Apply model (live-apply + undoable — same as Document Settings, D3)
//  Every edit writes IMMEDIATELY to the model through the undoable DIMSTYLE funnel
//  (`CADDrawing.mutateDimStyles`, a value-snapshot undo step per ADR-002) and bumps the
//  model's dirty/version so the document becomes dirty and the renderer re-resolves
//  every dimension (a named style's geometry feeds resolve). There is no Apply/Cancel
//  transaction — closing the panel keeps every change and each edit is independently
//  undoable with ⌘Z.
//
//  ## Wiring (UNWIRED — Wave 3)
//  This view is SELF-CONTAINED and NOT yet referenced anywhere. Its entry point (a
//  menu item / inspector button) is wired in a later wire-wave; nothing else in the
//  app references it today. Its init takes just the `CanvasModel` (see `init`).
//
//  ## Modal discipline (project gotcha)
//  No `NSOpenPanel`/`.runModal()` lives here. The only modal is the rename SHEET,
//  presented purely via a SwiftUI `.sheet`; nothing the headless test suite reaches
//  constructs or presents it. The naming/validation logic (`DimStyleNaming`) is a
//  pure, side-effect-free value type so it unit-tests WITHOUT presenting any UI
//  (mirrors `LayoutRenameSheet.Validation`).
//
//  GPLv2-or-later (LibreCAD derivative). Mirrors RS_DimStyle / DRW_Dimstyle.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The dimension-style manager — a panel over the focused window's `CanvasModel`.
/// Lists the drawing's named dim styles, supports add / rename / delete / set-current,
/// and edits the selected style's fields. Decomposed into small `private` subviews so
/// the SwiftUI type checker stays comfortable (project gotcha #2).
struct DimStyleManagerView: View {
    /// The live canvas model (model + drawing). Owned by the window; the panel binds to
    /// it so edits apply immediately and round-trip via the document. This is the ONLY
    /// thing the Wave-3 entry point must pass.
    let model: CanvasModel
    /// Dismiss action for the Done button.
    @Environment(\.dismiss) private var dismiss

    /// The name of the style currently selected in the list (case-insensitive key into
    /// the table). `nil` until the list resolves a selection on appear.
    @State private var selectedName: String?
    /// Whether the rename sheet is presented.
    @State private var renaming = false

    init(model: CanvasModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                stylesList
                Divider()
                editorPane
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 440)
        .onAppear { ensureSelection() }
        .sheet(isPresented: $renaming) { renameSheet }
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dimension Styles")
                    .font(DS.Font.panelTitle)
                Text("Manage the named styles a dimension can reference. The current style is used by new dimensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Styles list (left pane)

    @ViewBuilder private var stylesList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedName) {
                ForEach(styleNames, id: \.self) { name in
                    styleRow(name)
                        .tag(name)
                }
            }
            .listStyle(.inset)
            .frame(width: 220)

            Divider()
            listToolbar
        }
    }

    @ViewBuilder private func styleRow(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isCurrent(name) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent(name) ? Color.accentColor : Color.secondary)
                .help(isCurrent(name) ? "Current style" : "Not the current style")
            Text(name)
                .fontWeight(isCurrent(name) ? .semibold : .regular)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var listToolbar: some View {
        HStack(spacing: 2) {
            Button { addStyle() } label: { Image(systemName: "plus") }
                .help("Add a new dimension style")
            Button { renaming = true } label: { Image(systemName: "pencil") }
                .help("Rename the selected style")
                .disabled(!canRenameSelected)
            Button { deleteSelected() } label: { Image(systemName: "minus") }
                .help("Delete the selected style")
                .disabled(!canDeleteSelected)
            Spacer()
            Button("Set Current") { setSelectedCurrent() }
                .help("Make the selected style the document-active style")
                .disabled(!canSetSelectedCurrent)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Editor pane (right)

    @ViewBuilder private var editorPane: some View {
        if let name = selectedName, let named = model.drawing.dimStyles.style(named: name) {
            DimStyleFieldsEditor(
                style: named.style,
                isCurrent: isCurrent(name),
                apply: { updated in updateSelectedStyle(name: name, to: updated) })
        } else {
            VStack {
                Spacer()
                Text("Select a style to edit its values.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Rename sheet

    @ViewBuilder private var renameSheet: some View {
        if let current = selectedName {
            DimStyleRenameSheet(
                currentName: current,
                existingNames: styleNames,
                onConfirm: { newName in
                    renameSelected(from: current, to: newName)
                    renaming = false
                },
                onCancel: { renaming = false })
        } else {
            // Defensive: nothing selected (shouldn't happen — button is disabled).
            Color.clear.onAppear { renaming = false }
        }
    }

    // MARK: - Derived (read the model on the main actor in the view body)

    /// The named styles, in the table's stable insertion order (always non-empty in
    /// practice — the table keeps "Standard").
    private var styleNames: [String] { model.drawing.dimStyles.styles.map(\.name) }

    /// Whether `name` is the document-active ("current") style.
    private func isCurrent(_ name: String) -> Bool {
        model.drawing.dimStyles.active()?.name.caseInsensitiveCompare(name) == .orderedSame
    }

    private var canRenameSelected: Bool {
        guard let n = selectedName else { return false }
        // "Standard" is the mandatory fallback; renaming it would orphan references.
        return !DimStyleNaming.isStandard(n)
    }

    private var canDeleteSelected: Bool {
        guard let n = selectedName else { return false }
        // The table refuses to remove "Standard"; reflect that in the button state.
        return !DimStyleNaming.isStandard(n) && model.drawing.dimStyles.count > 1
    }

    private var canSetSelectedCurrent: Bool {
        guard let n = selectedName else { return false }
        return !isCurrent(n)
    }

    // MARK: - Selection bookkeeping

    /// Seeds the selection (active style, else first) on appear and after edits that
    /// could leave the selection dangling (e.g. a delete).
    private func ensureSelection() {
        if let sel = selectedName, model.drawing.dimStyles.contains(sel) { return }
        selectedName = model.drawing.dimStyles.active()?.name ?? styleNames.first
    }

    // MARK: - Mutations (all undoable via the DIMSTYLE funnel)

    /// The single undoable funnel: mutate the DIMSTYLE table, then bump the model's
    /// dirty/version so the document becomes dirty and the renderer re-resolves every
    /// dimension. Mirrors `CanvasModel.applySetting` but for the dim-style table; kept
    /// here so the manager needs no new `CanvasModel` surface.
    private func apply(_ body: (inout DimStyleTable) -> Void) {
        model.drawing.mutateDimStyles(body)
        model.modelDirty = true
        model.modelVersion &+= 1
    }

    /// Adds a fresh style (named "Style N", seeded from the current style's values so a
    /// new style starts from something sensible) and selects it.
    private func addStyle() {
        let newName = DimStyleNaming.defaultNewName(existing: styleNames)
        // Seed from the active style if present, else the engine default.
        let seed = model.drawing.dimStyles.active()?.style ?? ResolvedDimStyle.default
        apply { $0.upsert(NamedDimStyle(name: newName, style: seed)) }
        selectedName = newName
    }

    /// Deletes the selected style (the table keeps "Standard" regardless) and re-seeds
    /// the selection.
    private func deleteSelected() {
        guard let name = selectedName, !DimStyleNaming.isStandard(name) else { return }
        apply { $0.remove(named: name) }
        selectedName = nil
        ensureSelection()
    }

    /// Sets the selected style as the document-active style.
    private func setSelectedCurrent() {
        guard let name = selectedName else { return }
        apply { $0.activeName = name }
    }

    /// Renames the selected style: re-key the table entry (preserving the style values)
    /// and carry the active-name pointer if it referenced the old name.
    private func renameSelected(from old: String, to new: String) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !DimStyleNaming.isStandard(old) else { return }
        guard let existing = model.drawing.dimStyles.style(named: old) else { return }
        // A pure recase (same name, different case) is a harmless no-op-or-recase.
        apply { table in
            let wasActive = table.activeName?.caseInsensitiveCompare(old) == .orderedSame
            table.remove(named: old)
            table.upsert(NamedDimStyle(name: trimmed, style: existing.style))
            if wasActive { table.activeName = trimmed }
        }
        selectedName = trimmed
    }

    /// Writes the edited field values back to the named style (preserving its name).
    private func updateSelectedStyle(name: String, to updated: ResolvedDimStyle) {
        apply { $0.upsert(NamedDimStyle(name: name, style: updated)) }
    }
}

// MARK: - Field editor (the selected style's NamedDimStyle values)

/// Edits one named style's `ResolvedDimStyle` fields. Stateless w.r.t. the values
/// (it reads the passed `style` each render and reports each edit back through
/// `apply`), so every keystroke commits as ONE undoable DIMSTYLE step in the host.
/// Decomposed into small rows so the SwiftUI type checker stays comfortable.
private struct DimStyleFieldsEditor: View {
    /// The style being edited (read each render; never stored as draft state so the
    /// view always reflects the model — including after undo/redo).
    let style: ResolvedDimStyle
    /// Whether this style is the document-active one (shown as a hint).
    let isCurrent: Bool
    /// Reports an edited copy of the style back to the host's undoable funnel.
    let apply: (ResolvedDimStyle) -> Void

    var body: some View {
        Form {
            geometrySection
            textSection
            extensionSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var geometrySection: some View {
        Section("Geometry") {
            numberRow("Text height", value: style.textHeight, minimum: 0) {
                var s = style; s.textHeight = $0; apply(s)
            }
            numberRow("Arrow size", value: style.arrowSize, minimum: 0) {
                var s = style; s.arrowSize = $0; apply(s)
            }
            numberRow("Overall scale", value: style.scale, minimum: 0) {
                var s = style; s.scale = $0; apply(s)
            }
        }
    }

    @ViewBuilder private var textSection: some View {
        Section("Measurement text") {
            Picker("Linear format", selection: Binding(
                get: { style.linearFormat },
                set: { var s = style; s.linearFormat = $0; apply(s) }
            )) {
                ForEach(LinearFormat.allCases, id: \.self) { f in
                    Text(f.dimStyleLabel).tag(f)
                }
            }
            Stepper(value: Binding(
                get: { style.linearPrecision },
                set: { var s = style; s.linearPrecision = Swift.max(0, Swift.min(8, $0)); apply(s) }
            ), in: 0...8) {
                Text("Precision: \(style.linearPrecision)")
            }
        }
    }

    @ViewBuilder private var extensionSection: some View {
        Section("Extension lines") {
            numberRow("Offset from origin (DIMEXO)", value: style.extensionOffset, minimum: 0) {
                var s = style; s.extensionOffset = $0; apply(s)
            }
            numberRow("Extend beyond line (DIMEXE)", value: style.extensionBeyond, minimum: 0) {
                var s = style; s.extensionBeyond = $0; apply(s)
            }
            numberRow("Text gap (DIMGAP)", value: style.textGap, minimum: 0) {
                var s = style; s.textGap = $0; apply(s)
            }
            if isCurrent {
                Text("This is the current style.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A right-aligned numeric field row (world-unit values) that live-applies. The
    /// current `value` is read by the caller; `set` clamps to `minimum` and commits.
    @ViewBuilder
    private func numberRow(_ title: String, value: Double, minimum: Double,
                           set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { value },
                set: { set(Swift.max(minimum, $0)) }
            ), format: .number)
            .frame(width: DS.Field.std)
            .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Rename sheet (View-layer modal; pure validation via DimStyleNaming)

/// The dim-style RENAME sheet. Self-contained: owns the live text draft, derives the
/// validation from the OTHER style names, and reports the confirmed new name (or a
/// cancel) to the host. Modal discipline: presented ONLY via a SwiftUI `.sheet`;
/// nothing the headless test suite reaches presents it. Mirrors `LayoutRenameSheet`.
private struct DimStyleRenameSheet: View {
    let currentName: String
    let existingNames: [String]
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String

    init(currentName: String, existingNames: [String],
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.currentName = currentName
        self.existingNames = existingNames
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._draft = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rename Dimension Style")
                .font(.headline)
                .padding([.top, .horizontal])
                .padding(.bottom, 4)
            Text("Rename the “\(currentName)” style.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)
            TextField("Style name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmIfValid() }
                .padding(.horizontal)
                .padding(.bottom, 6)
            validationMessage
            Divider()
            buttons
        }
        .frame(minWidth: 380)
    }

    @ViewBuilder private var validationMessage: some View {
        switch validation {
        case .empty:
            label("Enter a name for the style.", systemImage: "exclamationmark.circle", tint: .secondary)
        case .collision:
            label("A style named “\(trimmed)” already exists — choose a different name.",
                  systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .reserved:
            label("“Standard” is reserved and cannot be used.",
                  systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .unchanged:
            label("This is the current name.", systemImage: "checkmark.circle", tint: .secondary)
        case .ok:
            label("Renames the style to “\(trimmed)”.", systemImage: "checkmark.circle", tint: .secondary)
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

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validation: DimStyleNaming.Validation {
        DimStyleNaming.classify(newName: draft, currentName: currentName, existingNames: existingNames)
    }

    private func confirmIfValid() {
        guard validation.isConfirmable else { return }
        onConfirm(trimmed)
    }
}

// MARK: - Pure naming/validation logic (unit-testable WITHOUT any UI)

/// Side-effect-free naming + validation helpers for the dimension-style manager,
/// extracted so they unit-test WITHOUT presenting the panel/sheet (the View layer is
/// the headless-modal trap). Pure value logic shared by the manager and its tests
/// (mirrors `LayoutRenameSheet.Validation`).
enum DimStyleNaming {
    /// The DXF mandatory-fallback style name (case-insensitive). It cannot be renamed
    /// or deleted (the table always retains it).
    static let standardName = "Standard"

    /// Whether `name` is the reserved "Standard" style (case-insensitive).
    static func isStandard(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(standardName) == .orderedSame
    }

    /// A fresh, unique default name for a NEW style: "Style 1", "Style 2", … skipping
    /// any name already present (case-insensitive). Always returns a name not in
    /// `existing`.
    static func defaultNewName(existing: [String]) -> String {
        let lower = Set(existing.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var n = 1
        while lower.contains("style \(n)") { n += 1 }
        return "Style \(n)"
    }

    /// The classification of a typed style name on RENAME.
    enum Validation: Equatable {
        /// Blank / whitespace-only → confirm disabled.
        case empty
        /// "Standard" is reserved (you cannot rename a style TO "Standard") → disabled.
        case reserved
        /// Matches a DIFFERENT existing style (case-insensitive) → confirm disabled.
        case collision
        /// Equal to the current name (case-insensitive) → confirm allowed (no-op/recase).
        case unchanged
        /// A fresh, unique, non-reserved name → confirm allowed.
        case ok

        /// Whether the confirm button is enabled for this classification.
        var isConfirmable: Bool {
            switch self {
            case .empty, .reserved, .collision: return false
            case .unchanged, .ok:               return true
            }
        }
    }

    /// Classifies `newName` for a rename against the document's styles (case-insensitive,
    /// whitespace-trimmed). `currentName` is excluded from the collision check so a
    /// recase of the current name is `.unchanged`, not `.collision`. Renaming TO
    /// "Standard" is `.reserved` unless the current name already IS "Standard" (a recase,
    /// classified `.unchanged`). Pure value logic the sheet and the tests share.
    static func classify(newName: String, currentName: String, existingNames: [String]) -> Validation {
        let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .empty }
        let lower = t.lowercased()
        let currentLower = currentName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == currentLower { return .unchanged }
        if isStandard(t) { return .reserved }
        let others = existingNames.filter { $0.lowercased() != currentLower }
        return others.contains { $0.lowercased() == lower } ? .collision : .ok
    }
}

// MARK: - Display-name helper (manager-local label for LinearFormat)

private extension LinearFormat {
    /// A friendly label for the manager's linear-format picker.
    var dimStyleLabel: String {
        switch self {
        case .scientific:          return "Scientific"
        case .decimal:             return "Decimal"
        case .engineering:         return "Engineering"
        case .architectural:       return "Architectural"
        case .fractional:          return "Fractional"
        case .architecturalMetric: return "Architectural (metric)"
        }
    }
}
