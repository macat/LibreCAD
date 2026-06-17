//
//  BlockDynamicParametersPanel.swift
//  LibreCADmacOS
//
//  The dynamic-block PARAMETERS + ACTIONS authoring panel (DB-2W STAGE 2; block-features
//  §5.2.2 linear / §5.2.7 flip, §6.2.3 stretch / §6.2.6 flip). Shown ONLY while the in-place
//  Block Editor is open (`CanvasModel.isEditingBlock`), it lets the user turn the current
//  canvas SELECTION into a LINEAR STRETCH or a FLIP, and list / remove the block's
//  parameters + actions:
//
//   • Add Linear Stretch — select the members to stretch, click the button: a `.linear`
//     parameter (left-mid → right-mid of the selection's block-local bounds) + a `.stretch`
//     action over the right half are added (block-features §5.2.2 + §6.2.3). The grip then
//     appears on every placed insert (DB-2W STAGE 1).
//   • Add Flip — select the members, click: a `.flip` parameter (a vertical reflection line
//     through the selection center) + a `.flip` action are added (§5.2.7 + §6.2.6).
//   • A LIST of parameters (kind + label) and actions (kind + driving parameter), each with
//     a Remove. Removing a parameter PRUNES the actions that referenced it (no orphans).
//
//  The geometry is DERIVED from the selection — no modal, no tool-input state machine — so
//  the whole panel is straightforward and headless-testable. Every mutation routes through
//  the UNDOABLE `CanvasModel` funnel (which calls the engine's `CADDrawing` mutators), so
//  each is a single ⌘Z and the canvas re-resolves live. The body is decomposed into small
//  `@ViewBuilder` subviews for the SwiftUI type checker (project gotcha #2).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

/// The dynamic-block parameters/actions authoring panel. Renders nothing unless a block-edit
/// session is active; surfaced by `ContentView` near the canvas while editing.
struct BlockDynamicParametersPanel: View {
    /// The live canvas state. Observed, so the panel tracks the editing session + every
    /// parameter/action edit and the canvas selection live.
    @Bindable var model: CanvasModel

    /// Bridge to the canvas controller so a mutation can request a redraw (the renderer is
    /// on-demand; a parameter/action edit must nudge it to re-resolve).
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        if model.isEditingBlock {
            panel
        }
    }

    // MARK: Panel chrome

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            addButtons
            Divider()
            parametersSection
            actionsSection
        }
        .padding(DS.Space.lg)
        .frame(width: 250)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dynamic Parameters")
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.below.square.filled.and.square")
                .foregroundStyle(DS.Palette.accent)
            Text("Parameters & Actions")
                .font(DS.Font.panelTitle)
            Spacer(minLength: 4)
        }
    }

    // MARK: Add buttons (drive off the current selection)

    @ViewBuilder private var addButtons: some View {
        let hasSelection = !model.selection.isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if model.addLinearStretchFromSelection() != nil { requestRedraw() }
                } label: {
                    Label("Linear Stretch", systemImage: "arrow.left.and.right")
                }
                .help("Add a linear stretch driven by the selected members")
                Button {
                    if model.addFlipFromSelection() != nil { requestRedraw() }
                } label: {
                    Label("Flip", systemImage: "arrow.left.arrow.right")
                }
                .help("Add a flip driven by the selected members")
            }
            .disabled(!hasSelection)
            if !hasSelection {
                Text("Select members on the canvas, then add a parameter.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Parameters list

    @ViewBuilder private var parametersSection: some View {
        let params = model.editingBlockParameters
        VStack(alignment: .leading, spacing: 2) {
            Text("Parameters")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if params.isEmpty {
                Text("None yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(params) { param in parameterRow(param) }
            }
        }
    }

    @ViewBuilder private func parameterRow(_ param: BlockParameter) -> some View {
        HStack(spacing: 6) {
            Image(systemName: parameterIcon(param))
                .foregroundStyle(.secondary)
            Text(param.label).lineLimit(1)
            Text(parameterKindName(param))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button {
                if model.removeEditingBlockParameter(param.id) { requestRedraw() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this parameter (and the actions that use it)")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    // MARK: Actions list

    @ViewBuilder private var actionsSection: some View {
        let actions = model.editingBlockActions
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if actions.isEmpty {
                Text("None yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(actions) { action in actionRow(action) }
            }
        }
    }

    @ViewBuilder private func actionRow(_ action: BlockAction) -> some View {
        HStack(spacing: 6) {
            Image(systemName: actionIcon(action))
                .foregroundStyle(.secondary)
            Text(actionKindName(action)).lineLimit(1)
            Text("· \(action.memberIDs.count) members")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button {
                if model.removeEditingBlockAction(action.id) { requestRedraw() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this action")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    // MARK: - Display helpers

    private func parameterIcon(_ param: BlockParameter) -> String {
        switch param {
        case .linear: return "arrow.left.and.right"
        case .flip:   return "arrow.left.arrow.right"
        }
    }

    private func parameterKindName(_ param: BlockParameter) -> String {
        switch param {
        case .linear: return "linear"
        case .flip:   return "flip"
        }
    }

    private func actionIcon(_ action: BlockAction) -> String {
        switch action {
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        case .flip:    return "arrow.left.arrow.right"
        }
    }

    private func actionKindName(_ action: BlockAction) -> String {
        switch action {
        case .stretch: return "Stretch"
        case .flip:    return "Flip"
        }
    }

    // MARK: - Redraw

    /// Marks the model dirty + bumps the version so the renderer re-resolves, then asks the
    /// on-demand canvas to redraw (the same dance the visibility panel / Inspector use).
    private func requestRedraw() {
        model.modelDirty = true
        model.modelVersion &+= 1
        controllerBox.controller?.requestRedraw()
    }
}
