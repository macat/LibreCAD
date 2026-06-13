//
//  LayersSidebar.swift
//  LibreCADmacOS
//
//  The modern Mac sidebar for the single canvas window. Lives in the leading
//  pane of `ContentView`'s `NavigationSplitView`; the canvas + HUD + toolbar
//  stay in the detail pane untouched.
//
//  It binds DIRECTLY to the live `CanvasModel` the canvas uses (and through it
//  the `@MainActor @Observable CADDrawing`), so every mutation here flows through
//  the drawing's UNDOABLE layer mutators (`addLayer` / `removeLayer` /
//  `renameLayer` / `setActiveLayer` / `setLayerVisible` / `setLayerLocked`, and
//  `mutateLayers { $0.setColor(...) }` for the color — there is no dedicated
//  `CADDrawing.setLayerColor`, so we use the public undoable funnel). Because the
//  model is observable, the sidebar AND the canvas recompute on every edit, and
//  ⌘Z (the window's `UndoManager`, injected into the drawing) reverts a layer
//  edit just like a geometry edit.
//
//  Render-sync note: the Metal renderer only repacks its instance buffer / re-
//  resolves layer pens when `model.modelVersion` changes or `model.modelDirty`
//  is set (see `LineRenderer.rebuildLineInstancesIfNeeded`). A pure layer edit
//  (color especially) does NOT touch the entity store, so we mark the model dirty
//  and bump the version here, then ask the canvas to redraw — otherwise a color
//  change would not reach the GPU until the next geometry edit / view escape.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// MARK: - Layers sidebar

/// The leading-pane sidebar: a Layers section (live, editable) plus a read-only
/// Blocks stub so the structure is visible. Bound to the same `CanvasModel` the
/// canvas renders, so edits reflect live and undo via ⌘Z.
struct LayersSidebar: View {
    /// The live canvas state — the SAME instance the detail-pane canvas renders.
    /// `@Bindable` so the inline rename `TextField` / color `ColorPicker` can bind
    /// into per-row local state and commit through the drawing's undoable mutators.
    @Bindable var model: CanvasModel

    /// Bridge to the canvas controller so a layer edit can request a redraw (the
    /// renderer is on-demand; a layer edit must nudge it — see the render-sync note).
    let controllerBox: CADCanvasView.ControllerBox

    /// The row currently selected in the List (the layer name). Drives the active
    /// layer + the highlight; kept in sync with the drawing's active layer.
    @State private var selectedLayer: String?

    var body: some View {
        List(selection: $selectedLayer) {
            layersSection
            layerStatesSection
            BlocksSection(model: model, controllerBox: controllerBox)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 260)
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear { selectedLayer = model.drawing.layers.activeLayerName }
        .onChange(of: selectedLayer) { _, newValue in
            // Clicking a row sets the active layer (where new geometry lands).
            guard let name = newValue, name != model.drawing.layers.activeLayerName else { return }
            model.drawing.setActiveLayer(name)
        }
        // Keep the selection mirror in step when the active layer changes via undo
        // / programmatic activation.
        .onChange(of: model.drawing.layers.activeLayerName) { _, newActive in
            if selectedLayer != newActive { selectedLayer = newActive }
        }
    }

    // MARK: Layers section

    @ViewBuilder
    private var layersSection: some View {
        Section {
            ForEach(model.drawing.layers.layers) { layer in
                LayerRow(
                    layer: layer,
                    isActive: layer.name == model.drawing.layers.activeLayerName,
                    onToggleVisible: { setVisible(layer.name, $0) },
                    onToggleLocked: { setLocked(layer.name, $0) },
                    onTogglePrintable: { setPrintable(layer.name, $0) },
                    onToggleConstruction: { setConstruction(layer.name, $0) },
                    onColorChange: { setColor(layer.name, $0) },
                    onRename: { rename(layer.name, to: $0) }
                )
                .tag(layer.name)
                // Per-entity / per-layer ops (F17): right-click a layer row.
                .contextMenu { layerRowMenu(layer) }
            }
        } header: {
            // Section header with the bulk freeze/lock-all affordances (F17).
            HStack {
                Text("Layers")
                Spacer()
                Button {
                    freezeAll(true)
                } label: { Image(systemName: "snowflake") }
                    .buttonStyle(.borderless)
                    .help("Freeze all layers")
                Button {
                    freezeAll(false)
                } label: { Image(systemName: "sun.max") }
                    .buttonStyle(.borderless)
                    .help("Thaw all layers")
                Button {
                    lockAll(true)
                } label: { Image(systemName: "lock") }
                    .buttonStyle(.borderless)
                    .help("Lock all layers")
                Button {
                    lockAll(false)
                } label: { Image(systemName: "lock.open") }
                    .buttonStyle(.borderless)
                    .help("Unlock all layers")
            }
        }
    }

    /// The right-click menu on a layer row: activate it, move the current selection
    /// onto it, or isolate it (hide every other layer). Per-entity layer ops (F17).
    @ViewBuilder
    private func layerRowMenu(_ layer: Layer) -> some View {
        Button("Set Active") {
            model.drawing.setActiveLayer(layer.name)
            selectedLayer = layer.name
            syncRenderAfterLayerEdit()
        }
        Button("Move Selection Here") {
            if model.moveSelectionToLayer(layer.name) { syncRenderAfterLayerEdit() }
        }
        .disabled(model.selection.isEmpty)
        Divider()
        Button("Isolate (Hide Others)") {
            model.isolateLayer(layer.name)
            syncRenderAfterLayerEdit()
        }
    }

    // MARK: Layer states (F17 — named snapshots of all layer flags)

    @ViewBuilder
    private var layerStatesSection: some View {
        let states = model.drawing.layerStates.states
        Section {
            if states.isEmpty {
                Text("No saved states")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(states) { state in
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.secondary)
                        Text(state.name)
                        Spacer(minLength: 0)
                        Button {
                            restoreLayerState(state.name)
                        } label: { Image(systemName: "arrow.uturn.backward.circle") }
                            .buttonStyle(.borderless)
                            .help("Restore this layer state")
                        Button {
                            model.removeLayerState(named: state.name)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this layer state")
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text("Layer States")
                Spacer()
                Button { saveCurrentLayerState() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Save the current layer flags as a new state")
            }
        }
    }

    // MARK: Footer (add / remove)

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 2) {
            Button(action: addLayer) {
                Image(systemName: "plus")
            }
            .help("Add a new layer")

            Button(action: removeSelectedLayer) {
                Image(systemName: "minus")
            }
            .help("Remove the selected layer")
            .disabled(!canRemoveSelected)

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// "0" and the active layer are guarded by the model (`removeLayer` refuses
    /// "0"); we also disable removing the last remaining layer.
    private var canRemoveSelected: Bool {
        guard let name = selectedLayer else { return false }
        return name != "0" && model.drawing.layers.count > 1
    }

    // MARK: - Mutations (all undoable, then nudge the renderer)

    private func setVisible(_ name: String, _ visible: Bool) {
        model.drawing.setLayerVisible(name, visible)
        syncRenderAfterLayerEdit()
    }

    private func setLocked(_ name: String, _ locked: Bool) {
        model.drawing.setLayerLocked(name, locked)
        // Lock affects editability only, not pixels — still bump so any future
        // lock-aware overlay stays consistent; cheap.
        syncRenderAfterLayerEdit()
    }

    private func setPrintable(_ name: String, _ printable: Bool) {
        model.setLayerPrintable(name, printable)
        syncRenderAfterLayerEdit()
    }

    private func setConstruction(_ name: String, _ construction: Bool) {
        model.setLayerConstruction(name, construction)
        syncRenderAfterLayerEdit()
    }

    private func freezeAll(_ frozen: Bool) {
        model.freezeAllLayers(frozen)
        syncRenderAfterLayerEdit()
    }

    private func lockAll(_ locked: Bool) {
        model.lockAllLayers(locked)
        syncRenderAfterLayerEdit()
    }

    /// Saves the current layer flags under a fresh auto-generated state name. (A
    /// rename field on the row lets the user retitle it; this keeps the affordance a
    /// single click.)
    private func saveCurrentLayerState() {
        _ = model.saveLayerState(named: model.drawing.layerStates.newName())
    }

    private func restoreLayerState(_ name: String) {
        if model.restoreLayerState(named: name) { syncRenderAfterLayerEdit() }
    }

    private func setColor(_ name: String, _ color: RGBAColor) {
        // No dedicated `CADDrawing.setLayerColor`; the public undoable funnel
        // `mutateLayers` + `LayerTable.setColor` is the engine-sanctioned path.
        model.drawing.mutateLayers { $0.setColor(name, color) }
        syncRenderAfterLayerEdit()
    }

    private func rename(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        let wasActive = oldName == model.drawing.layers.activeLayerName
        if model.drawing.renameLayer(oldName, to: trimmed), wasActive {
            selectedLayer = trimmed
        }
        syncRenderAfterLayerEdit()
    }

    private func addLayer() {
        let name = uniqueLayerName()
        // New layers are born with the Document Settings layer defaults (color /
        // line width / line type — app policy set in the Document Settings sheet).
        let layer = Layer(name: name,
                          color: model.defaultLayerColor,
                          lineType: model.defaultLineType,
                          lineWidth: model.defaultLineWidth)
        if model.drawing.addLayer(layer) {
            selectedLayer = name
            model.drawing.setActiveLayer(name)
        }
        syncRenderAfterLayerEdit()
    }

    private func removeSelectedLayer() {
        guard let name = selectedLayer, canRemoveSelected else { return }
        // Reassign the removed layer's entities to "0" so they keep a valid layer
        // (and the same undo group reverts both the record drop and the moves).
        model.drawing.removeLayer(name, reassignTo: "0")
        selectedLayer = model.drawing.layers.activeLayerName
        syncRenderAfterLayerEdit()
    }

    /// A fresh "LayerN" name not already taken.
    private func uniqueLayerName() -> String {
        var i = model.drawing.layers.count
        var name = "Layer\(i)"
        while model.drawing.layers.contains(name) {
            i += 1
            name = "Layer\(i)"
        }
        return name
    }

    /// Marks the model dirty + bumps the version so the renderer re-resolves layer
    /// pens and repacks its instance buffer, then asks the on-demand canvas to
    /// redraw. (A layer edit does not touch the entity store, so without this the
    /// renderer keeps its cached buffer / resolve context — see the render-sync
    /// note at the top of this file.)
    private func syncRenderAfterLayerEdit() {
        model.modelDirty = true
        model.modelVersion &+= 1
        controllerBox.controller?.requestRedraw()
    }
}

// MARK: - One layer row

/// A single layer row: visibility eye, lock, color swatch (→ ColorPicker), an
/// inline-editable name, and the active indicator. All actions call back into the
/// sidebar, which routes them through the drawing's undoable mutators.
private struct LayerRow: View {
    let layer: Layer
    let isActive: Bool
    let onToggleVisible: (Bool) -> Void
    let onToggleLocked: (Bool) -> Void
    let onTogglePrintable: (Bool) -> Void
    let onToggleConstruction: (Bool) -> Void
    let onColorChange: (RGBAColor) -> Void
    let onRename: (String) -> Void

    /// Local edit buffer for the inline name field (committed on return / blur).
    @State private var draftName: String = ""
    /// Local color binding for the `ColorPicker` (initialised from the layer).
    @State private var swatch: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            // Visibility (eye / eye.slash → setLayerVisible). A frozen layer is
            // hidden in the model; the eye reflects `isVisible`.
            Button {
                onToggleVisible(!layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(layer.isVisible ? "Hide layer" : "Show layer")

            // Lock (lock.open / lock → setLayerLocked).
            Button {
                onToggleLocked(!layer.isLocked)
            } label: {
                Image(systemName: layer.isLocked ? "lock" : "lock.open")
                    .foregroundStyle(layer.isLocked ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(layer.isLocked ? "Unlock layer" : "Lock layer")

            // Printable (printer / printer.dotmatrix → setLayerPrintable). A
            // non-printable layer draws on screen but is excluded from plotted output.
            Button {
                onTogglePrintable(!layer.isPrintable)
            } label: {
                Image(systemName: layer.isPrintable ? "printer" : "printer.slash")
                    .foregroundStyle(layer.isPrintable ? Color.primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(layer.isPrintable ? "Exclude from print" : "Include in print")

            // Construction (ruler → setLayerConstruction). A construction layer holds
            // helper geometry and is never printed; the toggle marks the intent.
            Button {
                onToggleConstruction(!layer.isConstruction)
            } label: {
                Image(systemName: layer.isConstruction ? "ruler.fill" : "ruler")
                    .foregroundStyle(layer.isConstruction ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help(layer.isConstruction ? "Clear construction flag" : "Mark as construction layer")

            // Color swatch (tap → ColorPicker → setLayerColor). The label is empty
            // so only the well shows; macOS renders it as a tappable swatch.
            ColorPicker("", selection: $swatch, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
                .help("Layer color")
                .onChange(of: swatch) { _, newColor in
                    let rgba = newColor.rgbaColor
                    if rgba != layer.color { onColorChange(rgba) }
                }

            // Inline-editable name.
            TextField("Layer name", text: $draftName)
                .textFieldStyle(.plain)
                .onSubmit { onRename(draftName) }
                .disabled(layer.name == "0")   // DXF requires "0"; never renamed.

            Spacer(minLength: 0)

            // Active indicator: the layer where new geometry lands.
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Active layer")
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            draftName = layer.name
            swatch = Color(rgba: layer.color)
        }
        // Keep local mirrors in step if the underlying layer changes (undo,
        // external edit) while the row stays on screen.
        .onChange(of: layer.name) { _, newName in
            if draftName != newName { draftName = newName }
        }
        .onChange(of: layer.color) { _, newColor in
            let asColor = Color(rgba: newColor)
            if swatch.rgbaColor != newColor { swatch = asColor }
        }
    }
}

// MARK: - RGBAColor <-> SwiftUI Color bridge

extension Color {
    /// Builds a SwiftUI `Color` from the engine's `RGBAColor` (sRGB components).
    init(rgba: RGBAColor) {
        self.init(.sRGB,
                  red: Double(rgba.r),
                  green: Double(rgba.g),
                  blue: Double(rgba.b),
                  opacity: Double(rgba.a))
    }

    /// Resolves this `Color` to the engine's `RGBAColor` (sRGB). Uses the macOS
    /// `resolve` API so dynamic/system colors collapse to concrete components.
    var rgbaColor: RGBAColor {
        let resolved = self.resolve(in: EnvironmentValues())
        return RGBAColor(resolved.red, resolved.green, resolved.blue, resolved.opacity)
    }
}
