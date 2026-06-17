//
//  LayersSidebar.swift
//  LibreCADmacOS
//
//  The modern Mac sidebar for the single canvas window. Lives in the leading
//  pane of `ContentView`'s `NavigationSplitView`; the canvas + HUD + toolbar
//  stay in the detail pane untouched.
//
//  It is now a REARRANGEABLE PANEL STACK (`SidebarPanelStack`): three collapsible
//  panels — Layers, Layer States, Blocks — each with its own header controls. Panels
//  can be collapsed, dragged to reorder, and shown/hidden via the top ⋯ menu, with the
//  order/collapsed/hidden state persisted across launches in a single `@AppStorage`
//  JSON string (a `SidebarLayoutConfig`). The previous global ＋/− footer is gone — the
//  add/remove-layer buttons now live in the LAYERS panel header, next to the list.
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

/// The leading-pane sidebar: a rearrangeable stack of Layers / Layer States / Blocks
/// panels. Bound to the same `CanvasModel` the canvas renders, so edits reflect live
/// and undo via ⌘Z.
struct LayersSidebar: View {
    /// The live canvas state — the SAME instance the detail-pane canvas renders.
    /// `@Bindable` so the inline rename `TextField` / color `ColorPicker` can bind
    /// into per-row local state and commit through the drawing's undoable mutators.
    @Bindable var model: CanvasModel

    /// Bridge to the canvas controller so a layer edit can request a redraw (the
    /// renderer is on-demand; a layer edit must nudge it — see the render-sync note).
    let controllerBox: CADCanvasView.ControllerBox

    /// Raises the View-layer "Create Block from Selection…" name sheet (owned by
    /// `ContentView` — the modal MUST stay in the View layer; the sidebar only triggers
    /// it). Wired into the Blocks panel header's ＋ button.
    let onCreateBlock: () -> Void

    /// Raises the View-layer "Insert Block from File… (DXF)" open panel (owned by
    /// `ContentView` — the `NSOpenPanel` MUST stay in the View layer; the sidebar only
    /// triggers it). Wired into the Blocks panel header's ⋯ menu.
    let onInsertBlockFromFile: () -> Void

    /// Raises the View-layer "Save Block to File… (WBLOCK)" save panel for the block
    /// named in the argument (owned by `ContentView` — the `NSSavePanel` stays in the
    /// View layer; the sidebar only triggers it). Wired into a per-row context action
    /// in `BlocksSectionContent`.
    let onSaveBlockToFile: (String) -> Void

    /// The row currently selected in the Layers panel (the layer name). Gates the
    /// remove (−) button and drives the active layer; kept in sync with the drawing's
    /// active layer.
    @State private var selectedLayer: String?

    /// The persisted panel layout (order / collapsed / hidden), serialized to one
    /// `@AppStorage` JSON string. Mirrored into `config` (the live value the stack
    /// binds) on appear, and re-encoded whenever `config` changes — the same
    /// primitive-string `@AppStorage` pattern `ContentView` uses for the command-bar
    /// MRU and the pinned-tools set.
    @AppStorage("sidebar.panelLayout") private var panelLayoutRaw: String = ""
    /// The live layout config the panel stack reads + mutates.
    @State private var config: SidebarLayoutConfig = .default

    /// A toggled "tick" the Parts Library HEADER's "Choose Folder…" button flips to ask
    /// the panel BODY (`PartsLibrarySectionContent`) to raise its own folder picker. This
    /// keeps the `NSOpenPanel` inside the body's View layer (which owns the catalog state)
    /// while still surfacing the chooser in the panel header. The body watches it via
    /// `onChange`; the value itself is meaningless (only its CHANGES matter).
    @State private var chooseLibraryFolder = false

    /// A toggled "tick" the Quick Select HEADER's Reset button flips to ask the panel BODY
    /// (`QuickSelectSectionContent`) to clear its filter back to "match anything". The body
    /// watches it via `onChange`; the value itself is meaningless (only its CHANGES matter).
    @State private var resetQuickSelect = false

    var body: some View {
        SidebarPanelStack(panels: panels, config: $config)
            .frame(minWidth: 220, idealWidth: 260)
            .onAppear {
                selectedLayer = model.drawing.layers.activeLayerName
                config = SidebarLayoutConfig.decoded(from: panelLayoutRaw)
            }
            // Persist any layout change (reorder / collapse / show-hide) back to the
            // durable @AppStorage string.
            .onChange(of: config) { _, newValue in
                panelLayoutRaw = newValue.encoded()
            }
            // Keep the selection mirror in step when the active layer changes via undo
            // / programmatic activation.
            .onChange(of: model.drawing.layers.activeLayerName) { _, newActive in
                if selectedLayer != newActive { selectedLayer = newActive }
            }
    }

    // MARK: - Panel descriptors

    /// The three panels, in canonical declaration order. The stack renders them in the
    /// CONFIG's order; this array is just the descriptor set (id → header + body). To
    /// add a panel later: append one descriptor + a `SidebarPanelID` case.
    private var panels: [SidebarPanel] {
        [
            SidebarPanel(id: .layers, header: { layersHeaderControls }, body: { layersBody }),
            SidebarPanel(id: .layerStates, header: { layerStatesHeaderControls }, body: { layerStatesBody }),
            SidebarPanel(id: .blocks, header: { blocksHeaderControls }, body: { blocksBody }),
            SidebarPanel(id: .partsLibrary, header: { partsLibraryHeaderControls }, body: { partsLibraryBody }),
            SidebarPanel(id: .quickSelect, header: { quickSelectHeaderControls }, body: { quickSelectBody })
        ]
    }

    // MARK: Layers panel

    /// The Layers header controls: ＋ (add) / − (remove, gated exactly as before) right
    /// next to the list, plus a ⋯ menu holding the bulk freeze/thaw/lock/unlock-all ops
    /// (de-cluttered out of the row of icons the old section header carried).
    @ViewBuilder
    private var layersHeaderControls: some View {
        Button(action: addLayer) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add a new layer")

        Button(action: removeSelectedLayer) {
            Image(systemName: "minus")
        }
        .buttonStyle(.borderless)
        .help("Remove the selected layer")
        .disabled(!canRemoveSelected)

        Menu {
            Button { freezeAll(true) } label: { Label("Freeze All Layers", systemImage: "snowflake") }
            Button { freezeAll(false) } label: { Label("Thaw All Layers", systemImage: "sun.max") }
            Divider()
            Button { lockAll(true) } label: { Label("Lock All Layers", systemImage: "lock") }
            Button { lockAll(false) } label: { Label("Unlock All Layers", systemImage: "lock.open") }
            Divider()
            // Selection-wide isolate / unisolate live in the PANEL header (they act on the
            // current selection / the whole drawing, not one row) — the W3B LAYISO-from-
            // selection + LAYUNISO funnels.
            Button {
                if model.isolateSelectionLayers() { syncRenderAfterLayerEdit() }
            } label: { Label("Isolate Selection's Layers", systemImage: "eye") }
                .disabled(model.selection.isEmpty)
            Button {
                if model.unisolateLayers() { syncRenderAfterLayerEdit() }
            } label: { Label("Unisolate Layers", systemImage: "eye.circle") }
                .disabled(!model.hasIsolatedLayers)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Bulk layer actions")
    }

    /// The Layers body: the live layer list with the full `LayerRow` (all toggles /
    /// color / inline rename / active indicator / context menu — unchanged). A row tap
    /// selects + activates that layer (the old `List(selection:)` role); the active row
    /// reads from the model's active-layer name.
    @ViewBuilder
    private var layersBody: some View {
        ForEach(model.drawing.layers.layers) { layer in
            LayerRow(
                layer: layer,
                isActive: layer.name == model.drawing.layers.activeLayerName,
                isSelected: layer.name == selectedLayer,
                onSelect: { selectLayer(layer.name) },
                onToggleVisible: { setVisible(layer.name, $0) },
                onToggleLocked: { setLocked(layer.name, $0) },
                onColorChange: { setColor(layer.name, $0) },
                onLineTypeChange: { setLineType(layer.name, $0) },
                onLineWidthChange: { setLineWidth(layer.name, $0) },
                onOpacityChange: { setOpacity(layer.name, $0) },
                onRename: { rename(layer.name, to: $0) }
            )
            // Per-entity / per-layer ops (F17): right-click a layer row.
            .contextMenu { layerRowMenu(layer) }
        }
    }

    /// The right-click menu on a layer row: the less-common per-layer FLAGS (printable /
    /// construction — demoted here from the row so the layer NAME gets its width back,
    /// AutoCAD-style; eye + lock stay inline), then the Wave-3B layer OPERATIONS that act
    /// on this row's layer — make-current / move-selection / isolate / turn-off-others /
    /// select-on-layer (LAYISO / LAYOFF / CLAYER family). Per-entity layer ops (F17 + W3B).
    @ViewBuilder
    private func layerRowMenu(_ layer: Layer) -> some View {
        // Printable (was an inline row button). A non-printable layer draws on screen but
        // is excluded from plotted output.
        Toggle(isOn: printableBinding(layer)) {
            Label("Printable", systemImage: layer.isPrintable ? "printer" : "printer.slash")
        }
        // Construction (was an inline row button). Helper geometry, never printed.
        Toggle(isOn: constructionBinding(layer)) {
            Label("Construction Layer", systemImage: layer.isConstruction ? "ruler.fill" : "ruler")
        }
        Divider()
        // Make Current (AutoCAD CLAYER) — route through the W3B undoable funnel so undo
        // reverts the active-layer change; keep the selection mirror in step.
        Button {
            if model.makeLayerCurrent(layer.name) {
                selectedLayer = layer.name
                syncRenderAfterLayerEdit()
            }
        } label: {
            Label("Make Current", systemImage: "checkmark.circle")
        }
        Button("Move Selection Here") {
            if model.moveSelectionToLayer(layer.name) { syncRenderAfterLayerEdit() }
        }
        .disabled(model.selection.isEmpty)
        // Select every entity on this layer: REPLACE the selection with the layer's
        // entities. Built by funneling a layer-only `QuickSelectFilter` through the
        // existing `applyQuickSelect` select-by-predicate path (no new CanvasModel method;
        // it also applies the Select-All selectability gate + repaints the highlight).
        Button {
            selectEntities(onLayer: layer.name)
        } label: {
            Label("Select Entities on Layer", systemImage: "cursorarrow.rays")
        }
        Divider()
        // Isolate this layer (LAYISO — hide every other, restorable via Unisolate).
        Button {
            model.isolateLayer(layer.name)
            syncRenderAfterLayerEdit()
        } label: {
            Label("Isolate (Hide Others)", systemImage: "eye")
        }
        // Turn off every OTHER layer (LAYOFF — freeze others WITHOUT a restore stash;
        // distinct from Isolate). The W3B `(except:)` convenience.
        Button {
            if model.turnOffOtherLayers(except: layer.name) { syncRenderAfterLayerEdit() }
        } label: {
            Label("Turn Off Other Layers", systemImage: "eye.slash")
        }
        // Unisolate (LAYUNISO) — reverse the last isolate; only meaningful while an
        // isolation is in effect.
        Button {
            if model.unisolateLayers() { syncRenderAfterLayerEdit() }
        } label: {
            Label("Unisolate Layers", systemImage: "eye.circle")
        }
        .disabled(!model.hasIsolatedLayers)
    }

    /// A two-way binding for a layer's PRINTABLE flag, routed through the undoable funnel
    /// (`setPrintable`) — drives the context-menu Toggle that replaced the inline button.
    private func printableBinding(_ layer: Layer) -> Binding<Bool> {
        Binding(get: { layer.isPrintable },
                set: { setPrintable(layer.name, $0) })
    }

    /// A two-way binding for a layer's CONSTRUCTION flag, routed through the undoable
    /// funnel (`setConstruction`) — drives the context-menu Toggle.
    private func constructionBinding(_ layer: Layer) -> Binding<Bool> {
        Binding(get: { layer.isConstruction },
                set: { setConstruction(layer.name, $0) })
    }

    // MARK: Layer States panel (F17 — named snapshots of all layer flags)

    /// The Layer States header control: ＋ to save the current layer flags as a new
    /// named state.
    @ViewBuilder
    private var layerStatesHeaderControls: some View {
        Button { saveCurrentLayerState() } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Save the current layer flags as a new state")
    }

    /// The Layer States body: the saved-states list with restore/delete (unchanged).
    @ViewBuilder
    private var layerStatesBody: some View {
        let states = model.drawing.layerStates.states
        if states.isEmpty {
            // Unified empty state with a CTA — saving the current flags IS reachable from
            // here (`saveCurrentLayerState`), so offer it directly (mirrors the header ＋).
            SidebarEmptyState(
                icon: "rectangle.stack",
                title: "No saved layer states",
                cta: (label: "Save Current State", action: { saveCurrentLayerState() })
            )
        } else {
            ForEach(states) { state in
                HStack(spacing: DS.Space.md) {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.secondary)
                    Text(state.name)
                        .font(DS.Font.rowLabel)
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
                .padding(.vertical, DS.Space.xxs)
            }
        }
    }

    // MARK: Blocks panel

    /// The Blocks header controls: ＋ "Create Block…" routed via the host closure into
    /// `ContentView`'s `BlockNamePrompt` flow (the modal stays in the View layer — the
    /// sidebar never constructs a sheet/panel; the verb needs a selection so it gates on
    /// it), then the `BlocksPanelMenu` ⋯ overflow holding "Insert Block from File…" plus
    /// Freeze-All / Thaw-All. (The temporary copy of the freeze menu in the Blocks BODY
    /// was a Wave-A stopgap; it now lives HERE in the header — its proper home.)
    @ViewBuilder
    private var blocksHeaderControls: some View {
        Button(action: onCreateBlock) {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Create a block from the current selection")
        .disabled(!model.hasSelection)

        BlocksPanelMenu(onInsertFromFile: onInsertBlockFromFile,
                        onFreezeAll: { model.freezeAllBlocks()
                                       controllerBox.controller?.requestRedraw() },
                        onThawAll: { model.thawAllBlocks()
                                     controllerBox.controller?.requestRedraw() })
    }

    /// The Blocks body: the live block rows (thumbnail + Insert / Edit / rename / delete
    /// + drag-to-place + context menu, plus a per-row "Save Block to File…" — delegated
    /// to `BlocksSectionContent`).
    @ViewBuilder
    private var blocksBody: some View {
        BlocksSectionContent(model: model,
                             controllerBox: controllerBox,
                             onSaveBlockToFile: onSaveBlockToFile)
    }

    // MARK: Parts Library panel (a chosen folder of .dxf symbols → import as blocks)

    /// The Parts Library header control: "Choose Folder…" (raises the View-layer folder
    /// picker inside `PartsLibrarySectionContent`). The panel body owns the picker + the
    /// catalog + import; the header just exposes the chooser as a compact header button.
    @ViewBuilder
    private var partsLibraryHeaderControls: some View {
        PartsLibraryHeaderControls(onChooseFolder: { chooseLibraryFolder.toggle() })
    }

    /// The Parts Library body: the chosen-folder row + the scanned symbol list with
    /// double-click / drag-to-canvas import (delegated to `PartsLibrarySectionContent`).
    /// `chooseLibraryFolder` is a tick the header toggles to ask the body to raise its
    /// own folder picker (keeps the `NSOpenPanel` inside the panel content's View layer).
    @ViewBuilder
    private var partsLibraryBody: some View {
        PartsLibrarySectionContent(model: model,
                                   controllerBox: controllerBox,
                                   chooseFolderTick: chooseLibraryFolder)
    }

    // MARK: Quick Select panel (select-by-attributes: filter kind/layer → selection)

    /// The Quick Select header control: a Reset button that clears the panel's filter back
    /// to "match anything" (raised by flipping `resetQuickSelect`, which the body watches).
    @ViewBuilder
    private var quickSelectHeaderControls: some View {
        QuickSelectHeaderControls(onReset: { resetQuickSelect.toggle() })
    }

    /// The Quick Select body: the kind / layer pickers + Replace/Add/Remove/Intersect mode
    /// + a live match count + Apply (delegated to `QuickSelectSectionContent`). Apply
    /// funnels through `model.applyQuickSelect` (pure, undo-free) and repaints the canvas.
    @ViewBuilder
    private var quickSelectBody: some View {
        QuickSelectSectionContent(model: model,
                                  controllerBox: controllerBox,
                                  resetTick: resetQuickSelect)
    }

    // MARK: - Layers selection / remove gating

    /// Selecting a layer row sets it active (where new geometry lands) — the role the
    /// old `List(selection:)` filled. No-op if it is already active.
    private func selectLayer(_ name: String) {
        selectedLayer = name
        guard name != model.drawing.layers.activeLayerName else { return }
        model.drawing.setActiveLayer(name)
    }

    /// Selects every entity on `name`: REPLACES the live selection with the layer's
    /// entities by funneling a layer-only `QuickSelectFilter` through the existing
    /// `applyQuickSelect` select-by-predicate path. This deliberately reuses the model's
    /// select-by-filter funnel (no new CanvasModel method) — it also applies the Select-All
    /// selectability gate (skips locked/frozen) and bumps the version; we still nudge the
    /// on-demand canvas to repaint the highlight overlay. (A selection change is view-side
    /// state, so this registers no undo — like every other Select verb.)
    private func selectEntities(onLayer name: String) {
        let filter = QuickSelectFilter(layer: name)
        if model.applyQuickSelect(filter, mode: .replace) {
            controllerBox.controller?.requestRedraw()
        }
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

    /// Sets a layer's default line TYPE through the undoable layer funnel (mirrors
    /// `setColor`): `mutateLayers` + `LayerTable.setLineType`, then the render nudge so
    /// the renderer re-resolves `.byLayer` entities' dash pattern.
    private func setLineType(_ name: String, _ lineType: PenLineType) {
        model.drawing.mutateLayers { $0.setLineType(name, lineType) }
        syncRenderAfterLayerEdit()
    }

    /// Sets a layer's default line WIDTH through the undoable layer funnel:
    /// `mutateLayers` + `LayerTable.setLineWidth`, then the render nudge so the
    /// renderer re-resolves `.byLayer` entities' lineweight.
    private func setLineWidth(_ name: String, _ width: PenLineWidth) {
        model.drawing.mutateLayers { $0.setLineWidth(name, width) }
        syncRenderAfterLayerEdit()
    }

    /// Sets a layer's transparency/opacity through the undoable layer funnel (mirrors
    /// `setColor`): `mutateLayers` + `LayerTable.setOpacity`, then the render nudge so
    /// the renderer re-resolves the layer's pens (the opacity folds into
    /// `ResolvedPen.opacity`). `value` is the 0…1 alpha (1 = fully opaque); the row
    /// clamps + de-dups, so this is a no-op-safe funnel.
    private func setOpacity(_ name: String, _ value: Double) {
        model.drawing.mutateLayers { $0.setOpacity(name, value) }
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

/// A single layer row: visibility eye, lock, color swatch (→ ColorSwatchPicker), an
/// inline-editable name, and the active indicator. All actions call back into the
/// sidebar, which routes them through the drawing's undoable mutators. A tap on the
/// row's background selects + activates the layer (the old `List(selection:)` role).
private struct LayerRow: View {
    let layer: Layer
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleVisible: (Bool) -> Void
    let onToggleLocked: (Bool) -> Void
    let onColorChange: (RGBAColor) -> Void
    let onLineTypeChange: (PenLineType) -> Void
    let onLineWidthChange: (PenLineWidth) -> Void
    let onOpacityChange: (Double) -> Void
    let onRename: (String) -> Void

    /// Local edit buffer for the inline name field (committed on return / blur).
    @State private var draftName: String = ""

    var body: some View {
        // CAD column grammar: leading [eye][lock] (the two AutoCAD-idiomatic always-on
        // flags) → NAME (given a real min width + layout priority so it stops truncating
        // to "L…"/"0") → trailing pen cluster [color swatch][linetype preview menu]. The
        // printer + construction flags moved into the row context menu (set at the call
        // site) so the name gets its width back.
        HStack(spacing: DS.Space.sm) {
            // Visibility (eye / eye.slash → setLayerVisible). A frozen layer is
            // hidden in the model; the eye reflects `isVisible`.
            Button {
                onToggleVisible(!layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : .secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: DS.Size.iconButton)
            .help(layer.isVisible ? "Hide layer" : "Show layer")

            // Lock (lock.open / lock → setLayerLocked).
            Button {
                onToggleLocked(!layer.isLocked)
            } label: {
                Image(systemName: layer.isLocked ? "lock" : "lock.open")
                    .foregroundStyle(layer.isLocked ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: DS.Size.iconButton)
            .help(layer.isLocked ? "Unlock layer" : "Lock layer")

            // Inline-editable NAME — the priority element. A real min width + layout
            // priority keeps the full name visible at the sidebar's min width instead of
            // collapsing to "L…"/"0" when the trailing controls would otherwise win the
            // squeeze.
            TextField("Layer name", text: $draftName)
                .textFieldStyle(.plain)
                .font(DS.Font.rowLabel)
                .lineLimit(1)
                .frame(minWidth: DS.Field.xy, alignment: .leading)
                .layoutPriority(1)
                .onSubmit { onRename(draftName) }
                .disabled(layer.name == "0")   // DXF requires "0"; never renamed.

            Spacer(minLength: DS.Space.xs)

            // Active indicator: the layer where new geometry lands.
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Active layer")
            }

            // Trailing pen cluster — color swatch then the line-type/-width menu.

            // Color swatch (tap → ColorPicker popover → setLayerColor). A SMALL 16pt
            // chip, not the stock ~44×22pt NSColorWell pill. The binding reads the
            // layer's REAL color (so the swatch shows ITS color immediately — no green
            // first-frame flash) and writes through the SAME undoable `onColorChange`
            // callback the old well used.
            ColorSwatchPicker(color: colorBinding, help: "Layer color")

            // Line TYPE + WIDTH defaults — behind one compact menu so the row stays
            // tight at the sidebar's min width. Each picker binds to the layer's
            // current default and routes a change through the undoable layer mutators.
            // A layer can't defer its own default to a layer/block, so the sentinels
            // are excluded; the width picker still offers the drawing "Default". The menu
            // LABEL is the layer's actual dash pattern (LinetypePreview), not a glyph.
            penDefaultsMenu
        }
        .padding(.vertical, DS.Space.xxs)
        .padding(.horizontal, DS.Space.xs)
        .background(rowBackground)
        .contentShape(Rectangle())
        // Tap the row (outside the controls) to select + activate the layer — the role
        // the old `List(selection:)` filled. The buttons/fields above consume their own
        // taps, so this only fires on the row's empty space.
        .onTapGesture { onSelect() }
        .onAppear {
            draftName = layer.name
        }
        // Keep the name mirror in step if the underlying layer changes (undo,
        // external edit) while the row stays on screen. (The color needs no mirror:
        // `colorBinding` reads `layer.color` directly, so it always reflects the live
        // value with no first-frame flash.)
        .onChange(of: layer.name) { _, newName in
            if draftName != newName { draftName = newName }
        }
    }

    /// A binding to the layer's color for the swatch picker. GET reads the layer's
    /// REAL color (so the chip shows ITS color immediately — no `.green` first-frame
    /// flash); SET routes the edit through the EXACT same undoable `onColorChange`
    /// callback the stock well used, guarding a no-op so an unchanged round-trip
    /// doesn't register a spurious undo step.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: layer.color) },
            set: { newColor in
                let rgba = newColor.rgbaColor
                if rgba != layer.color { onColorChange(rgba) }
            }
        )
    }

    /// The compact line-type / line-width default menu for this layer. The two
    /// reusable pickers (`PenPickers.swift`) bind to the layer's current default and
    /// commit a change through the undoable callbacks. The trailing help text shows
    /// the current values so the user can read the row's defaults at a glance.
    @ViewBuilder
    private var penDefaultsMenu: some View {
        Menu {
            LineTypePicker(
                selection: lineTypeBinding,
                includeByLayer: false,
                includeByBlock: false,
                label: "Line type"
            )
            LineWidthPicker(
                selection: lineWidthBinding,
                includeByLayer: false,
                includeByBlock: false,
                includeDefault: true,
                label: "Line width"
            )
            Divider()
            // Per-layer transparency: a 0…100 % slider over the layer's `opacity`
            // (1 = opaque). Routed through the undoable `setOpacity` funnel; the % read-
            // out keeps the row tight by living inside this menu (not as another inline
            // control). `Layer.opacity` folds into `ResolvedPen.opacity` at resolve, so a
            // change repaints every `.byLayer` entity at the new alpha.
            Section("Transparency") {
                Slider(value: opacityBinding, in: 0...1) {
                    Text("Opacity")
                }
                Text("\(Int((layer.opacity * 100).rounded()))% opaque")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            // Show the layer's ACTUAL dash pattern (not a cryptic "/" glyph) so the row
            // communicates the line type at a glance.
            LinetypePreview(lineType: layer.lineType, color: .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Layer line type: \(LineTypePicker.displayName(layer.lineType)) · "
              + "width: \(LineWidthPicker.displayName(layer.lineWidth))")
    }

    /// A binding to the layer's default line TYPE that routes a change through the
    /// undoable callback (reads the live layer value, writes via `onLineTypeChange`).
    private var lineTypeBinding: Binding<PenLineType> {
        Binding(
            get: { layer.lineType },
            set: { if $0 != layer.lineType { onLineTypeChange($0) } }
        )
    }

    /// A binding to the layer's default line WIDTH that routes a change through the
    /// undoable callback.
    private var lineWidthBinding: Binding<PenLineWidth> {
        Binding(
            get: { layer.lineWidth },
            set: { if $0 != layer.lineWidth { onLineWidthChange($0) } }
        )
    }

    /// A binding to the layer's OPACITY (0…1) routed through the undoable callback. GET
    /// reads the live `layer.opacity`; SET clamps to 0…1 and de-dups (a no-op write
    /// registers no undo step). Drives the Transparency slider in the pen menu.
    private var opacityBinding: Binding<Double> {
        Binding(
            get: { layer.opacity },
            set: { newValue in
                let clamped = min(max(newValue, 0), 1)
                if clamped != layer.opacity { onOpacityChange(clamped) }
            }
        )
    }

    /// A subtle selection highlight behind the selected row (the active row also shows
    /// the checkmark badge above).
    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: DS.Radius.selection).fill(DS.Palette.selectionFill)
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
