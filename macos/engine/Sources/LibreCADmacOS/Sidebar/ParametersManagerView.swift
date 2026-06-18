//
//  ParametersManagerView.swift
//  LibreCADmacOS
//
//  The PARAMETERS MANAGER sheet (Lane L4 — the user-facing UI for named parameters).
//  An AutoCAD-style Parameters Manager: a panel over the focused window's
//  `CanvasModel`/`CADDrawing` that lists the drawing's USER PARAMETERS in a table
//  (Name | Expression | Value), lets the user ADD / EDIT / REMOVE them, and (read-
//  only-with-edit) lists the PARAMETER-DRIVEN DIMENSIONAL CONSTRAINTS so their source
//  expression can be retuned. Every edit commits through the `CanvasModel` re-solve
//  FUNNELS so the geometry the parameter drives re-solves LIVE in one undo group.
//
//  ## Where this fits (vs. the engine lanes already merged)
//  Lane L1 added `CADDrawing.parameters: ParameterTable` (a `Parameter` is name +
//  expression + evaluated value + optional unit). Lane L2 added the evaluator + the
//  CanvasModel edit→re-solve seam: `setParameterExpression(name:expression:)`,
//  `setParameterValue(name:value:)`, `removeParameterAndResolve(name:)`, and
//  `setConstraintExpression(id:expression:)`. THIS lane is the sheet that drives those
//  funnels — it stores no model state of its own beyond the transient ADD-ROW draft.
//
//  ## Apply model (live-apply + undoable — same as the Dim-Style manager, D3)
//  Each committed edit calls the matching CanvasModel funnel, which wraps the parameter
//  mutation + the geometry re-solve it triggers in ONE undo group (one ⌘Z reverts both)
//  and bumps the model's dirty/version. There is no Apply/Cancel transaction — closing
//  the sheet keeps every change, and each edit is independently undoable with ⌘Z.
//
//  ## Stateless reads, draft only for the ADD row (no desync)
//  The existing-parameter rows read STRAIGHT from `model.drawing.parameters` each
//  render and commit through a closure — there is no per-row draft `@State` that could
//  drift from the model (so the table always reflects undo/redo). The ONE piece of
//  local draft state is the bottom "add a parameter" row (name + expression a user is
//  typing before it becomes a real parameter); it is cleared on a successful add.
//
//  ## Scope (MVP) + what is deferred
//  • Name is editable only when ADDING a parameter — RENAMING an existing parameter is
//    DEFERRED (the engine deferred rename-with-reference-repoint, and there is no rename
//    funnel; an existing row shows its name read-only). Expression + Value ARE editable
//    on existing rows (Value commits as a literal expression via `setParameterValue`).
//  • The dimensional-constraint-parameter section lists only the constraints that ALREADY
//    carry an expression (the parameter-driven ones) and lets the user retune that
//    expression; BINDING a bare-literal constraint to a parameter, and AUTO-NAMING new
//    dimensional constraints (d1, d2…), are deferred to a follow-up.
//
//  ## Modal discipline (project gotcha)
//  No `NSOpenPanel`/`NSAlert`/`.runModal()` lives here, and NO `.sheet` is presented
//  from inside this view. Errors (bad expression, duplicate / invalid name) surface as
//  INLINE RED text, never a modal — so nothing the headless test suite reaches presents
//  UI. The naming/validation logic (`ParameterNaming`) is a pure, side-effect-free value
//  type so it unit-tests WITHOUT presenting the panel (mirrors `DimStyleNaming`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The parameters manager — a sheet over the focused window's `CanvasModel`. Lists the
/// drawing's user parameters (Name | Expression | Value) with add / edit / remove, plus
/// the parameter-driven dimensional constraints (expression editable). Decomposed into
/// small `private` row/cell subviews so the SwiftUI type checker stays comfortable
/// (project gotcha #2). The ONLY thing the wire-wave entry point passes is the model.
struct ParametersManagerView: View {
    /// The live canvas model (model + drawing). Owned by the window; the sheet binds to
    /// it so edits apply immediately and round-trip via the document.
    let model: CanvasModel
    /// Dismiss action for the Done button.
    @Environment(\.dismiss) private var dismiss

    /// The ADD-ROW draft name (the only local draft; existing rows read the model).
    @State private var newName: String = ""
    /// The ADD-ROW draft expression.
    @State private var newExpression: String = ""
    /// The inline error for the add-row (nil ⇒ no error shown).
    @State private var addError: String?

    init(model: CanvasModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 580, height: 460)
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Parameters Manager")
                    .font(DS.Font.panelTitle)
                Text("Name a value, write an expression for it (e.g. \u{201C}22\u{201D} or \u{201C}a*2\u{201D}), and reference it from a dimensional constraint. Editing a parameter re-solves the geometry it drives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Content (scrollable: user-parameter table + constraint-parameter list)

    @ViewBuilder private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                userParameterSection
                Divider().padding(.vertical, 4)
                constraintParameterSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - User-parameter section

    @ViewBuilder private var userParameterSection: some View {
        sectionTitle("User parameters")
        columnHeaderRow
        if userParameters.isEmpty {
            Text("No parameters yet. Add one below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            ForEach(userParameters, id: \.id) { param in
                userParameterRow(param)
                Divider()
            }
        }
        addRow
    }

    /// The Name | Expression | Value column header.
    @ViewBuilder private var columnHeaderRow: some View {
        HStack(spacing: 8) {
            Text("Name").frame(width: nameWidth, alignment: .leading)
            Text("Expression").frame(width: exprWidth, alignment: .leading)
            Text("Value").frame(width: valueWidth, alignment: .trailing)
            Spacer(minLength: 0)
            Color.clear.frame(width: removeWidth)   // align with the per-row remove button
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    /// One existing-parameter row: name (read-only — rename deferred), expression +
    /// value editable, and a remove button. Reads the passed `param` each render and
    /// commits each field through the CanvasModel funnel.
    @ViewBuilder private func userParameterRow(_ param: Parameter) -> some View {
        HStack(spacing: 8) {
            nameCell(param)
            expressionCell(param)
            valueCell(param)
            Spacer(minLength: 0)
            removeButton(param)
        }
        .padding(.vertical, 3)
    }

    /// Name cell — read-only for an existing parameter (rename is deferred). Shown as
    /// plain text with the unit (if any) as a trailing hint.
    @ViewBuilder private func nameCell(_ param: Parameter) -> some View {
        HStack(spacing: 4) {
            Text(param.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let unit = param.unit, !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: nameWidth, alignment: .leading)
        .help("Renaming an existing parameter is not yet supported.")
    }

    /// Expression cell — commits through `setParameterExpression(name:expression:)` on
    /// submit / focus-loss. Reads `param.expression` each render (no draft state).
    @ViewBuilder private func expressionCell(_ param: Parameter) -> some View {
        TextField("expression", text: Binding(
            get: { param.expression },
            set: { commitExpression($0, for: param) }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: exprWidth)
    }

    /// Value cell — the last-evaluated numeric cache. Editing it stores the number as a
    /// LITERAL expression (via `setParameterValue`), so the expression + cache agree.
    @ViewBuilder private func valueCell(_ param: Parameter) -> some View {
        TextField("value", value: Binding(
            get: { param.value },
            set: { commitValue($0, for: param) }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .frame(width: valueWidth)
    }

    @ViewBuilder private func removeButton(_ param: Parameter) -> some View {
        Button { _ = model.removeParameterAndResolve(name: param.name) } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove this parameter (any constraint that referenced it is frozen to its last value)")
        .frame(width: removeWidth)
    }

    /// The bottom ADD-ROW: name + expression drafts and a +, with an inline red error.
    @ViewBuilder private var addRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: nameWidth)
                    .onSubmit { addParameter() }
                TextField("expression", text: $newExpression)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: exprWidth)
                    .onSubmit { addParameter() }
                Color.clear.frame(width: valueWidth)
                Spacer(minLength: 0)
                Button { addParameter() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Add this parameter")
                    .disabled(!canAdd)
                    .frame(width: removeWidth)
            }
            if let addError {
                inlineError(addError)
                    .padding(.leading, 2)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Constraint-parameter section (parameter-driven dimensional constraints)

    @ViewBuilder private var constraintParameterSection: some View {
        sectionTitle("Dimensional-constraint parameters")
        if drivenConstraints.isEmpty {
            Text("No parameter-driven dimensional constraints. Bind a dimensional constraint to a parameter (deferred) or it appears here once it carries an expression.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        } else {
            ForEach(drivenConstraints, id: \.id) { constraint in
                constraintParameterRow(constraint)
                Divider()
            }
        }
    }

    /// One parameter-driven dimensional constraint: a kind label, its expression
    /// (editable → `setConstraintExpression`), and its evaluated value (read-only).
    @ViewBuilder private func constraintParameterRow(_ constraint: Constraint) -> some View {
        HStack(spacing: 8) {
            Text(ParameterNaming.constraintLabel(for: constraint.kind))
                .frame(width: nameWidth, alignment: .leading)
                .lineLimit(1)
            TextField("expression", text: Binding(
                get: { constraint.expression ?? "" },
                set: { model.setConstraintExpression(id: constraint.id, expression: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: exprWidth)
            Text(formatted(constraint.value))
                .frame(width: valueWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Color.clear.frame(width: removeWidth)
        }
        .padding(.vertical, 3)
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

    // MARK: - Shared subviews

    @ViewBuilder private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    @ViewBuilder private func inlineError(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.red)
    }

    // MARK: - Column widths (kept in one place so header + rows align)

    private let nameWidth: CGFloat = 130
    private let exprWidth: CGFloat = 160
    private let valueWidth: CGFloat = 90
    private let removeWidth: CGFloat = 28

    // MARK: - Derived reads (read the model on the main actor in the view body)

    /// The user parameters, in the table's stable insertion order.
    private var userParameters: [Parameter] { model.drawing.parameters.parameters }

    /// The names already in use (for the add-row duplicate check), case-folded by the
    /// validator. Read fresh each render.
    private var existingNames: [String] { userParameters.map(\.name) }

    /// The PARAMETER-DRIVEN dimensional constraints — those carrying a non-nil
    /// `expression`. The constraint-parameter section lists these.
    private var drivenConstraints: [Constraint] {
        model.allConstraints.filter { $0.kind.isDimensional && $0.expression != nil }
    }

    /// Whether the add-row's current draft is a valid, non-duplicate new parameter name.
    private var canAdd: Bool {
        ParameterNaming.classify(name: newName, existingNames: existingNames).isAddable
    }

    // MARK: - Commit helpers (each goes through a CanvasModel re-solve funnel)

    /// Commits an edited expression for an existing parameter. A no-op for an unchanged
    /// value (avoids polluting undo). Re-solve happens inside the funnel.
    private func commitExpression(_ expression: String, for param: Parameter) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != param.expression else { return }
        _ = model.setParameterExpression(name: param.name, expression: trimmed)
    }

    /// Commits an edited value for an existing parameter (stored as a literal expression).
    private func commitValue(_ value: Double, for param: Parameter) {
        guard value.isFinite, value != param.value else { return }
        _ = model.setParameterValue(name: param.name, value: value)
    }

    /// Validates + adds the draft parameter, clearing the draft + error on success and
    /// surfacing an inline red message on failure (never a modal).
    private func addParameter() {
        let classification = ParameterNaming.classify(name: newName, existingNames: existingNames)
        guard classification.isAddable else {
            addError = classification.message
            return
        }
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpr = newExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        // The funnel creates-or-updates by name; the validator already guaranteed the
        // name is free, so this is always a create. An empty expression is allowed
        // (seeds value 0 — the user can fill it in on the row afterwards).
        _ = model.setParameterExpression(name: trimmedName, expression: trimmedExpr)
        newName = ""
        newExpression = ""
        addError = nil
    }

    /// Formats an evaluated value for the read-only constraint-value column.
    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

// The pure naming/validation logic (`ParameterNaming`) lives in its own SwiftUI-free
// file (`ParameterNaming.swift`) so a test can symlink it into the CADEngine test
// target WITHOUT dragging this SwiftUI view or the app module along — the `_Shared*`
// convention. This view references `ParameterNaming` directly (same module).
