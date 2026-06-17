//
//  BlockVisibilityStatesPanel.swift
//  LibreCADmacOS
//
//  The dynamic-block VISIBILITY STATES authoring panel (DB-1W; block-features §9). Shown
//  ONLY while the in-place Block Editor is open (`CanvasModel.isEditingBlock`), it lets the
//  user manage the editing block's named visibility states (§9.2) and assign which members
//  are visible in each state (§9.3, the BVSHOW / BVHIDE equivalent):
//
//   • A LIST of the block's states, with a pick for the CURRENT authoring state (§9.2 Set
//     Current). The first state is the default shown when an insert is placed (§9.5).
//   • Add (§9.2 New) — creates a state (and the block's `DynamicBlockDef` if it has none
//     yet); Rename (§9.2); Delete (§9.2, disabled when only one remains — §9.5 requires ≥1).
//   • Show / Hide SELECTED members in the current state — toggles the current canvas
//     selection (scoped to the block's members) into / out of the state's visible set.
//
//  Every mutation routes through the UNDOABLE `CanvasModel` funnel (which calls the engine's
//  `CADDrawing` visibility mutators), so each is a single ⌘Z and the canvas re-resolves
//  live. The naming prompts (Add / Rename) use SwiftUI `.alert` TextFields — View-layer
//  presentations only, never reachable from a unit test (the headless-modal rule). The
//  body is decomposed into small `@ViewBuilder` subviews for the SwiftUI type checker
//  (project gotcha #2).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The dynamic-block visibility-states authoring panel. Renders nothing unless a block-edit
/// session is active; surfaced by `ContentView` near the canvas while editing.
struct BlockVisibilityStatesPanel: View {
    /// The live canvas state. Observed, so the panel tracks the editing session + every
    /// state edit and the canvas selection live.
    @Bindable var model: CanvasModel

    /// Bridge to the canvas controller so a mutation can request a redraw (the renderer is
    /// on-demand; a state/visibility edit must nudge it to re-resolve).
    let controllerBox: CADCanvasView.ControllerBox

    // MARK: View-layer naming state (Add / Rename alerts — modal, View-layer only)

    /// The CURRENT authoring state's NAME (§9.2 Set Current). Drives the list selection and
    /// is the state Show/Hide writes into. Defaults to the block's first (default) state.
    @State private var currentStateName: String?

    /// Whether the "Add State" naming alert is presented, and its in-progress text.
    @State private var showingAddAlert = false
    @State private var addStateText = ""

    /// Whether the "Rename State" naming alert is presented, its in-progress text, and the
    /// state being renamed (captured when the alert opens).
    @State private var showingRenameAlert = false
    @State private var renameStateText = ""
    @State private var renameTarget: String?

    var body: some View {
        if model.isEditingBlock {
            panel
                // Keep the current-authoring-state selection valid as states change
                // (deleted / renamed / first-add): default to the first state.
                .onAppear { syncCurrentState() }
                .onChange(of: model.editingBlockVisibilityStates) { _, _ in syncCurrentState() }
                .alert("New Visibility State", isPresented: $showingAddAlert) { addAlertButtons } message: {
                    Text("Name the new visibility state for “\(model.editingBlock ?? "")”.")
                }
                .alert("Rename Visibility State", isPresented: $showingRenameAlert) { renameAlertButtons } message: {
                    Text("Enter a new name for “\(renameTarget ?? "")”.")
                }
        }
    }

    // MARK: Panel chrome

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            header
            statesList
            Divider()
            visibilityButtons
        }
        .padding(DS.Space.lg)
        .frame(width: 240)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Visibility States")
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "eye.square")
                .foregroundStyle(DS.Palette.accent)
            Text("Visibility States")
                .font(DS.Font.panelTitle)
            Spacer(minLength: 4)
            Button {
                addStateText = suggestedStateName()
                showingAddAlert = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a new visibility state")
        }
    }

    // MARK: States list (pick the current authoring state; per-row rename / delete)

    @ViewBuilder private var statesList: some View {
        let states = model.editingBlockVisibilityStates
        if states.isEmpty {
            Text("No states yet. Click + to add one — the first becomes the default.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 2) {
                ForEach(states) { state in
                    stateRow(state, isDefault: state.id == states.first?.id)
                }
            }
        }
    }

    @ViewBuilder private func stateRow(_ state: BlockVisibilityState, isDefault: Bool) -> some View {
        let isCurrent = state.name == currentStateName
        HStack(spacing: DS.Space.sm) {
            Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isCurrent ? DS.Palette.accent : .secondary)
                .onTapGesture { currentStateName = state.name }
            Text(state.name)
                .lineLimit(1)
            if isDefault {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(state.visibleMemberIDs.count)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .help("\(state.visibleMemberIDs.count) members visible in this state")
            Button {
                renameTarget = state.name
                renameStateText = state.name
                showingRenameAlert = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Rename this state")
            Button {
                deleteState(state.name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.editingBlockVisibilityStates.count <= 1)   // §9.5: keep ≥1
            .help(model.editingBlockVisibilityStates.count <= 1
                  ? "A block must keep at least one visibility state"
                  : "Delete this state")
        }
        .padding(.vertical, DS.Space.xxs)
        .padding(.horizontal, DS.Space.xs)
        .background(isCurrent ? DS.Palette.selectionFill : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.selection))
        .contentShape(Rectangle())
        .onTapGesture { currentStateName = state.name }
    }

    // MARK: Show / Hide selected members in the current state (BVSHOW / BVHIDE)

    @ViewBuilder private var visibilityButtons: some View {
        let hasCurrent = currentStateName != nil
        let hasSelection = !model.selection.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            Text(hasCurrent ? "Current: \(currentStateName!)" : "Pick a current state")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Show Selected") { setSelectedVisibility(true) }
                    .help("Make the selected members visible in the current state")
                Button("Hide Selected") { setSelectedVisibility(false) }
                    .help("Make the selected members invisible in the current state")
            }
            .disabled(!hasCurrent || !hasSelection)
            if !hasSelection {
                Text("Select members on the canvas to show or hide them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Add / Rename alert buttons (View-layer naming, headless-safe)

    @ViewBuilder private var addAlertButtons: some View {
        TextField("State name", text: $addStateText)
        Button("Add") { commitAdd() }
        Button("Cancel", role: .cancel) { showingAddAlert = false }
    }

    @ViewBuilder private var renameAlertButtons: some View {
        TextField("State name", text: $renameStateText)
        Button("Rename") { commitRename() }
        Button("Cancel", role: .cancel) { showingRenameAlert = false }
    }

    // MARK: - Actions (route through the undoable CanvasModel funnel + redraw)

    /// Adds the named state (creating the block's `DynamicBlockDef` on the first add), makes
    /// it the current authoring state, and repaints.
    private func commitAdd() {
        let name = addStateText
        if model.addEditingBlockVisibilityState(named: name) {
            currentStateName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            requestRedraw()
        }
        showingAddAlert = false
    }

    /// Renames the captured target state (preserving its members), keeping it current, then
    /// repaints.
    private func commitRename() {
        guard let old = renameTarget else { showingRenameAlert = false; return }
        let new = renameStateText.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.renameEditingBlockVisibilityState(old, to: new) {
            if currentStateName == old { currentStateName = new }
            requestRedraw()
        }
        showingRenameAlert = false
    }

    /// Deletes a state (engine enforces ≥1), re-selecting a remaining state as current,
    /// then repaints.
    private func deleteState(_ name: String) {
        if model.removeEditingBlockVisibilityState(named: name) {
            if currentStateName == name {
                currentStateName = model.editingBlockVisibilityStates.first?.name
            }
            requestRedraw()
        }
    }

    /// Shows / hides the current canvas selection in the current authoring state, then
    /// repaints (the editing-scope geometry re-resolves to reflect the new visibility).
    private func setSelectedVisibility(_ visible: Bool) {
        guard let state = currentStateName else { return }
        if model.setSelectedMembersVisibility(inState: state, visible: visible) > 0 {
            requestRedraw()
        }
    }

    // MARK: - Helpers

    /// Keeps `currentStateName` pointing at a valid state: leaves a still-present selection
    /// alone, else falls back to the first (default) state, else `nil` (no states).
    private func syncCurrentState() {
        let names = model.editingBlockVisibilityStates.map(\.name)
        if let cur = currentStateName, names.contains(cur) { return }
        currentStateName = names.first
    }

    /// A unique suggested name for a NEW state, of the form `State N`.
    private func suggestedStateName() -> String {
        let existing = Set(model.editingBlockVisibilityStates.map(\.name))
        var n = existing.count + 1
        while existing.contains("State \(n)") { n += 1 }
        return "State \(n)"
    }

    /// Marks the model dirty + bumps the version so the renderer re-resolves, then asks the
    /// on-demand canvas to redraw (the same dance the Inspector / sidebars use).
    private func requestRedraw() {
        model.modelDirty = true
        model.modelVersion &+= 1
        controllerBox.controller?.requestRedraw()
    }
}
