//
//  ContentView.swift
//  LibreCADmacOS
//
//  One document window's UI: the modern Layers sidebar + the interactive Metal
//  canvas (CADCanvasView) + the Inspector + the tool toolbar + the ⌘K palette +
//  on-canvas gizmos. Hosted by `DocumentGroup` (see LibreCADApp), which gives us
//  native Open / Open Recent / Save / Save As / autosave / versions / the dirty
//  dot / multi-window for free over `.dxf` files.
//
//  ⚠️ LAUNCH-SAFETY (read before editing) — the document/launch path SIGTRAP-
//  crashed once. The crash was `MainActor.assumeIsolated` in a document `init`
//  that NSDocument constructs OFF the main actor. The safe split this view
//  enforces:
//    • `LibreCADDocument` holds ONLY a `Sendable DXFPayload` (parsed off-main).
//    • THIS view builds the `@MainActor CADDrawing` + `CanvasModel` FROM that
//      payload, on the MAIN ACTOR, in `.task` — never in the document, and with
//      NO `MainActor.assumeIsolated` anywhere.
//  See LibreCADDocument.swift and macos/docs/DEVLOG.md ("SIGTRAP").
//
//  Native Open/Save/Save As/Open Recent/autosave/versions/dirty come from
//  DocumentGroup, so this view no longer carries the custom NSOpenPanel/NSSavePanel
//  Open/Save (those focused-scene-value actions were removed). Export (PDF/PNG/SVG)
//  and Print STAY custom — they are not the document type.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CADEngine

struct ContentView: View {
    /// The native document backing this window (`ReferenceFileDocument`, holding a
    /// Sendable payload only). `DocumentGroup`'s editor closure hands us this
    /// reference. The view reads its payload to build the live model, and pushes the
    /// live geometry back into it so Save/autosave serialize the latest drawing. A
    /// reference type, so a plain `let` is enough — its identity is fixed per window.
    let document: LibreCADDocument

    /// SwiftUI's environment `UndoManager` (supplied by `DocumentGroup`). Adopted by
    /// the model so edits register against IT — which is how the native document
    /// learns it is dirty and how ⌘Z / Revert route through the document.
    @Environment(\.undoManager) private var environmentUndoManager

    /// The canvas state (model, viewport, index, selection, snap). Owned by this
    /// window; `@MainActor @Observable`, so it is only ever touched on the main
    /// actor — which is where this whole view runs. Built from the document payload
    /// in `.task` (NOT in the document init — that is the launch-crash boundary).
    @State private var model = CanvasModel()
    /// Bridge so the Zoom-to-Fit command can reach the live canvas controller.
    @State private var controllerBox = CADCanvasView.ControllerBox()
    @State private var status: String = ""
    /// Set once so the document payload is loaded into the live model exactly once.
    @State private var didLoadPayload = false

    /// The sidebar's visibility column state (lets the toolbar toggle drive it).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Whether the trailing Inspector pane (entity properties + snap/grid + tool
    /// options) is shown. Toggled from the toolbar; defaults visible so the modern
    /// editing surface is discoverable on launch.
    @State private var showInspector = true

    /// Whether the ⌘K command palette overlay is presented. Toggled by the
    /// View ▸ Command Palette… menu item (⌘K) via a focused scene value.
    @State private var showPalette = false

    /// Whether the per-document Document Settings sheet is presented. Raised by
    /// File ▸ Document Settings… (⌥⌘, — decision D8) via a focused scene value.
    @State private var showSettings = false

    /// Whether the "New from Template…" chooser sheet is presented. Raised by
    /// File ▸ New from Template… via a focused scene value (F24). Picking a template
    /// seeds THIS window's live drawing from the chosen bundled `.dxf` template's
    /// entities / layers / units (reusing the same off-main DXF read path the
    /// document Open flow uses), so the user gets a pre-populated drawing to edit.
    @State private var showTemplateChooser = false

    /// Whether the "Create Block from Selection…" name sheet is presented (WAVE BW,
    /// Ask #1). Raised from the canvas context menu / Blocks menu / palette when there
    /// is a selection; confirming runs `CanvasModel.beginCreateBlock(name:)` and the
    /// user then picks a base point on the canvas. The sheet (`BlockNamePrompt`) lives
    /// in the View layer ONLY (modal discipline). The suggested name is captured when
    /// the sheet is raised so the prompt prefills a unique `Block-N`.
    @State private var showBlockNamePrompt = false
    /// The unique suggested name handed to the `BlockNamePrompt` sheet when it opens.
    @State private var suggestedBlockName = "Block-1"

    /// The live text of the bottom command / coordinate input line (UX-plan U1).
    /// Cleared after each successful submit; the field echoes parse errors via the
    /// model's `lastCommandError`.
    @State private var commandText: String = ""

    /// Whether the bottom command field has keyboard focus. Bound to a `@FocusState`
    /// so the canvas can hand focus to it on Space (D1) and Esc/submit can return
    /// focus to the canvas (so tool letters work again).
    @FocusState private var commandFieldFocused: Bool

    /// Whether the bottom COMMAND BAR's tool-filter field has keyboard focus. The bar
    /// is the AutoCAD-style tool launcher ADDED alongside the grouped button toolbar
    /// (the toolbar stays the primary visual surface; the bar is the keyboard surface).
    /// Focused on click, or on the `/` launcher keystroke over the canvas; Esc /
    /// activation returns focus to the canvas (so tool letters work again). Kept
    /// separate from `commandFieldFocused` so the two bottom fields never fight.
    @FocusState private var commandBarFocused: Bool

    /// The command bar's most-recently-used tools, persisted across launches as a
    /// comma-separated list of `ToolKind` raw values (most-recent first). Seeded into
    /// the live model on appear and re-persisted whenever the model's MRU changes —
    /// the LIST + promote-on-use logic live on the model (the pure
    /// `ToolSuggester.updatedMRU`), this is only its durable store.
    @AppStorage("commandBar.mru") private var commandBarMRURaw: String = ""

    /// The user-customized set of tools PINNED to the primary toolbar as buttons,
    /// persisted across launches via `@AppStorage` (a comma-separated list of
    /// `ToolKind` raw values). Tools NOT pinned still live in their group's `▾`
    /// overflow menu, so every tool stays reachable. The empty default ("") means
    /// "use the built-in default primary set" (`ToolCatalog.defaultPrimary`), so a
    /// fresh install shows a sensible curated toolbar; once the user toggles any
    /// pin the stored string becomes authoritative (a leading sentinel distinguishes
    /// "user cleared everything" from "never customized"). See `pinnedToolsSet`.
    @AppStorage("toolbar.pinnedTools") private var pinnedToolsRaw: String = ""

    // MARK: App-wide preference reads (Preferences ▸ General / Text)
    //
    // These back the new-document seeding (General tab) and the Text tool defaults
    // (Text tab). Each falls back to its `AppSettings.Default` when unset, so a user
    // who never opened Preferences gets exactly today's behavior. They drive NEW
    // documents/windows only (units/template seed at creation, autosave/text defaults
    // are app policy) — an open drawing's units are governed by its own DXF header.

    /// READ-SITE (General ▸ default units): the unit a NEW drawing is seeded with.
    @AppStorage(AppSettings.Key.defaultUnit) private var prefDefaultUnitRaw = AppSettings.Default.unit.rawValue
    /// READ-SITE (General ▸ default template): the template a NEW empty drawing is
    /// pre-populated from (`"blank"` / unmatched = none → just seed units).
    @AppStorage(AppSettings.Key.defaultTemplate) private var prefDefaultTemplate = AppSettings.Default.template
    /// READ-SITE (General ▸ autosave): whether new documents autosave.
    @AppStorage(AppSettings.Key.autosaveEnabled) private var prefAutosaveEnabled = AppSettings.Default.autosaveEnabled
    /// READ-SITE (Text ▸ default font): the font style stamped on new text.
    @AppStorage(AppSettings.Key.defaultTextFont) private var prefTextFont = AppSettings.Default.textFont
    /// READ-SITE (Text ▸ default height): the cap height new text is born with.
    @AppStorage(AppSettings.Key.defaultTextHeight) private var prefTextHeight = AppSettings.Default.textHeight

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Leading pane: the modern rearrangeable panel-stack sidebar (Layers /
            // Layer States / Blocks), bound to the SAME live model the canvas renders so
            // edits reflect immediately. The Blocks panel's ＋ raises the View-layer
            // "Create Block from Selection…" name sheet via this closure (the modal MUST
            // stay in the View layer — the sidebar only triggers it).
            LayersSidebar(model: model,
                          controllerBox: controllerBox,
                          onCreateBlock: { raiseBlockNamePrompt() },
                          onInsertBlockFromFile: { insertBlockFromFile() },
                          onSaveBlockToFile: { name in saveBlockToFile(named: name) })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .navigationTitle("Document")
        } detail: {
            // Detail pane: the existing interactive canvas + HUD + toolbar.
            canvasDetail
        }
        // Build the live @MainActor model from the document's Sendable payload, on
        // the MAIN ACTOR, exactly once. This is the safe boundary: the parse already
        // happened off-main in the document; here we just construct the drawing the
        // canvas renders. NO MainActor.assumeIsolated — this whole view is main-actor.
        .task {
            guard !didLoadPayload else { return }
            didLoadPayload = true
            loadFromDocument()
        }
        // Adopt SwiftUI's environment UndoManager so edits dirty the native document
        // (and ⌘Z/Revert route through it). Re-applied if the environment manager
        // appears after first build (it can be nil for the very first body pass).
        .onChange(of: environmentUndoManagerID) { _, _ in adoptEnvironmentUndo() }
        // Keep the document's payload in sync with the live drawing so Save /
        // autosave / versions serialize the LATEST geometry. `modelVersion` bumps on
        // every edit (and on the initial load); pushing the value-type snapshot is
        // cheap and never touches the off-main document codec.
        .onChange(of: model.modelVersion) { _, _ in syncPayloadToDocument() }
        // Command-bar MRU lifecycle: seed the live model from the persisted list on
        // appear, then re-persist whenever the model promotes a freshly-used tool. The
        // list + promote logic live on the model (pure `ToolSuggester.updatedMRU`); the
        // durable store is the `@AppStorage` string here.
        .onAppear { model.commandBarMRU = Self.decodeMRU(commandBarMRURaw) }
        .onChange(of: model.commandBarMRU) { _, new in
            commandBarMRURaw = Self.encodeMRU(new)
        }
    }

    // MARK: - Command-bar MRU persistence (encode/decode the @AppStorage string)

    /// Decodes the persisted comma-separated `ToolKind` raw values into an MRU list
    /// (unknown raws skipped, so a roster change never crashes a stored list).
    private static func decodeMRU(_ raw: String) -> [ToolKind] {
        raw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
    }

    /// Encodes an MRU list back to the comma-separated raw-value string for storage.
    private static func encodeMRU(_ mru: [ToolKind]) -> String {
        mru.map(\.rawValue).joined(separator: ",")
    }

    /// The canvas detail pane — the interactive canvas + HUD + toolbar + Inspector +
    /// palette wiring. Open/Save/Save As are NO LONGER here (DocumentGroup owns
    /// them); Export / Print remain as custom focused-scene-value actions.
    private var canvasDetail: some View {
        CADCanvasView(model: model, controllerBox: controllerBox)
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            // U3 replaces the transient corner HUD chips (coordinateHUD /
            // toolPromptHUD) with the persistent bottom status bar; the small
            // top-leading file-status chip stays (it is the load/export status, not a
            // coordinate/tool readout).
            .overlay(alignment: .topLeading) { statusHUD }
            // DB-1W: the dynamic-block VISIBILITY STATES authoring panel, floated at the
            // top-trailing of the canvas while the in-place Block Editor is open
            // (`model.isEditingBlock`). It lets the user add / rename / delete the editing
            // block's visibility states and show/hide the current selection's members per
            // state (block-features §9). Renders nothing when not editing.
            .overlay(alignment: .topTrailing) { visibilityStatesPanel }
            // U2: the contextual tool-options bar, pinned directly under the toolbar
            // and above the canvas. It shows ONLY the active tool's parameters (and
            // collapses to nothing for tools without options), two-way bound to the
            // SAME CanvasModel config the Inspector uses; changes re-apply onto the
            // live tool via `reapplyActiveToolConfig` (one source of truth).
            .safeAreaInset(edge: .top, spacing: 0) {
                ToolOptionsBar(model: model, controllerBox: controllerBox)
            }
            // STAGE 2 (current-properties): the PERSISTENT current-properties bar —
            // active layer + current pen (color / line type / width). Applied AFTER the
            // contextual ToolOptionsBar so it stacks ABOVE it (closest to the toolbar);
            // always visible (it never collapses) because the current properties apply
            // to every draw tool. New geometry adopts these via Stage 1's applyCommit
            // stamp.
            .safeAreaInset(edge: .top, spacing: 0) {
                CurrentPropertiesBar(model: model, controllerBox: controllerBox)
            }
            // WAVE BW (Ask #2): the contextual Block-Editor bar, pinned at the very top
            // of the canvas while an in-place block-edit session is active. Shows
            // "Editing block: <name>" + Save & Close / Discard; renders nothing
            // otherwise. Save&Close keeps the edits (every insert updates via the
            // engine's live-member resolve); Discard reverts to entry geometry.
            .safeAreaInset(edge: .top, spacing: 0) {
                BlockEditBar(model: model) {
                    controllerBox.controller?.requestRedraw()
                }
            }
            // U3 + U1 bottom chrome, stacked so the persistent STATUS BAR sits just
            // ABOVE the command/coordinate line (both pinned to the bottom, below the
            // canvas). One inset VStack keeps their order deterministic: status bar
            // (read-only telemetry) on top, command line (focusable input) at the very
            // bottom. The command line stays exactly as U1 built it — focus on Space,
            // Return parses → `.value(point)`, Esc returns focus to the canvas — and
            // the status bar never takes focus, so the two coexist cleanly.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // Paper-space P2: the Model / Layout tab strip, pinned at the
                    // BOTTOM of the detail pane just above the status bar (the
                    // AutoCAD/LibreCAD tab position). A "Model" tab + one tab per
                    // layout + a "+" to add one; selecting a tab switches the active
                    // space on the live model (camera re-frame + index rebuild +
                    // render filter) and asks the canvas to repaint.
                    LayoutTabStrip(
                        model: model,
                        onSelectModel: {
                            model.activateModel()
                            controllerBox.controller?.requestRedraw()
                        },
                        onSelectLayout: { name in
                            model.activateLayout(name: name)
                            controllerBox.controller?.requestRedraw()
                        },
                        onAddLayout: {
                            model.newLayout()
                            controllerBox.controller?.requestRedraw()
                        },
                        onSelectBlockEdit: {
                            // The block-edit tab is already the active context; clicking it
                            // just repaints (leaving is via the BlockEditBar).
                            controllerBox.controller?.requestRedraw()
                        }
                    )
                    StatusBar(model: model)
                    commandBar
                    // The AutoCAD-style tool LAUNCHER bar — ADDED below the U1
                    // coordinate line, alongside the grouped button toolbar at the
                    // top (the toolbar stays the primary visual surface). Mouse users
                    // use the toolbar; keyboard users type a command here to narrow
                    // the chips. All ranking is the pure `ToolSuggester`; image
                    // placement routes through the same View-layer file-picker the
                    // toolbar uses (`chooseAndPlaceImage`) so no modal is reachable
                    // from the model/suggester/tool.
                    CommandBar(
                        model: model,
                        focused: $commandBarFocused,
                        pinned: pinnedToolsSet,
                        activateTool: { kind in controllerBox.controller?.activateTool(kind) },
                        placeImage: { chooseAndPlaceImage() },
                        returnFocusToCanvas: { controllerBox.controller?.returnFocusToCanvas() }
                    )
                }
            }
            // Trailing Inspector: the selected entity's editable properties, plus
            // snap/grid controls and the active tool's options. Bound to the SAME
            // live model the canvas + layers sidebar use, so edits reflect live and
            // undo via ⌘Z (see InspectorView).
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model, controllerBox: controllerBox)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .toolbar { toolbarContent }
            .toolbar { inspectorToolbarContent }
            // The ⌘K command palette: a fuzzy-searchable overlay over the canvas
            // that can run any tool or app action. Built from the SAME closures the
            // menus/toolbar use, so a palette pick is identical to the real action.
            .modifier(CommandPaletteModifier(
                isPresented: $showPalette,
                commands: paletteCommands
            ))
            // The per-document Document Settings sheet (File ▸ Document Settings…,
            // ⌥⌘, — D8). Tabs: Units · Grid & Snap · Dimensions · Layers · Paper.
            // Live-apply + Done (D3); binds to the SAME live model so edits apply
            // immediately, are undoable, and round-trip via the document payload.
            .sheet(isPresented: $showSettings) {
                DocumentSettingsView(model: model, controllerBox: controllerBox)
            }
            // The "New from Template…" chooser (File ▸ New from Template…, F24). Lists
            // the bundled `.dxf` templates; picking one seeds THIS window's drawing
            // from the template (entities + layers + units), reusing the document Open
            // read path. Presented as a sheet so it is modal to the window.
            .sheet(isPresented: $showTemplateChooser) {
                TemplateChooserView(
                    templates: DrawingTemplate.bundled,
                    onChoose: { template in
                        showTemplateChooser = false
                        Task { await seedFromTemplate(template) }
                    },
                    onCancel: { showTemplateChooser = false }
                )
            }
            // WAVE BW (Ask #1): the "Create Block from Selection" name sheet. Raised
            // (only when there is a selection) from the canvas context menu / Blocks
            // menu / palette; confirming runs `beginCreateBlock`, then the user picks a
            // base point on the canvas. View-layer modal ONLY (headless-safe).
            .sheet(isPresented: $showBlockNamePrompt) {
                BlockNamePrompt(
                    suggestedName: suggestedBlockName,
                    existingNames: model.drawing.blocks.blocks.map(\.name),
                    onConfirm: { name in
                        showBlockNamePrompt = false
                        if model.beginCreateBlock(name: name) {
                            controllerBox.controller?.requestRedraw()
                        }
                    },
                    onCancel: { showBlockNamePrompt = false }
                )
            }
            // WAVE BW (Ask #2) document-close hook: when this window's canvas goes away
            // (the document closes), auto Save & Close any open block-edit session so
            // the in-flight edits are kept (the engine presents no modal — a deliberate
            // last-chance commit). `LibreCADDocument` is a Sendable payload carrier and
            // cannot reach the @MainActor model, so the hook lives here in the View layer
            // (the only place that owns the live `CanvasModel`).
            .onDisappear { _ = model.finishBlockEditingIfNeeded() }
            .focusedSceneValue(\.openDocumentSettings) { showSettings = true }
            .focusedSceneValue(\.newFromTemplate) { showTemplateChooser = true }
            // WAVE BW (Ask #1): "Create Block from Selection…" raises the name sheet,
            // gated on a non-empty selection (the verb is meaningless without one). The
            // value is `nil` when there is no selection — which DISABLES the matching
            // Blocks-menu item (it reads this focused value). Capturing a fresh unique
            // suggested name each time the sheet opens.
            .focusedSceneValue(\.createBlockFromSelection,
                               model.hasSelection ? { raiseBlockNamePrompt() } : nil)
            // Blocks ▸ "Insert Block from File…" / "Save Block to File…" focused values,
            // grouped into one modifier so the `canvasDetail` chain stays under the Swift
            // type-checker's complexity budget (gotcha #2). The NSOpenPanel/NSSavePanel
            // live inside the action closures (View layer only).
            .modifier(blockFileHandlers)
            .focusedSceneValue(\.commandPalette) { showPalette = true }
            .focusedSceneValue(\.zoomToFit) { controllerBox.controller?.zoomToFit() }
            // Export… (PDF/PNG/SVG): present a save panel whose format follows the
            // chosen extension, then render the current drawing through the shared
            // export facade. Print… (⌘P): the system print dialog. These STAY custom
            // (they are not the document type — DocumentGroup handles only DXF I/O).
            .focusedSceneValue(\.exportDocument) { format in Task { await exportDrawing(format) } }
            .focusedSceneValue(\.printDocument) { printDrawing() }
            // Per-LAYOUT plot (Paper Space P4): the Export/Print Layout focused values,
            // grouped into one modifier so the canvasDetail chain stays under the Swift
            // type-checker's complexity budget (gotcha #2). Each is published only when a
            // layout tab is active (paper space) — `nil` in model space disables the items.
            .modifier(layoutPlotHandlers)
            // The tool / image / undo / redo / delete action handlers are grouped into
            // one modifier so the `canvasDetail` chain stays under the Swift
            // type-checker's expression-complexity limit (adding the Image action inline
            // pushed it over).
            .modifier(toolActionHandlers)
            // Publish whether a draw tool is mid-run so the Edit ▸ Delete menu item
            // (bound to bare ⌫) can DISABLE itself while a tool is active. A disabled
            // item's key equivalent is NOT consumed by `NSMenu.performKeyEquivalent`
            // (which runs BEFORE the canvas `keyDown`), so ⌫ falls through to the
            // canvas, where the tool consumes it as `.backspace`. See MUST-FIX 1.
            .focusedSceneValue(\.isToolActive, model.isToolActive)
            // Let the canvas hand focus to the command line on Space (D1). The
            // controller calls this closure from `handleKey` when Space is pressed
            // and a tool is active, so a typed length goes to the field, not a tool.
            .onAppear {
                controllerBox.controller?.requestCommandFocus = { commandFieldFocused = true }
                // U5 context-menu hooks: "Properties" reveals + focuses the Inspector;
                // "Document Settings…" raises the per-document settings sheet.
                controllerBox.controller?.requestShowInspector = { showInspector = true }
                controllerBox.controller?.requestDocumentSettings = { showSettings = true }
                // WAVE BW (Ask #1): the canvas context menu's "Create Block from
                // Selection…" verb raises the View-layer name sheet (gated on a
                // selection inside `raiseBlockNamePrompt`).
                controllerBox.controller?.requestCreateBlockFromSelection = { raiseBlockNamePrompt() }
            }
            // View ▸ Show Command Line (⇧⌘L) focuses the field from the menu.
            .focusedSceneValue(\.focusCommandLine) { commandFieldFocused = true }
            // The `/` launcher keystroke focuses the bottom COMMAND BAR's tool filter
            // (AutoCAD's command-line convention). `/` is not a tool letter (the canvas
            // never consumes it), so this is non-disruptive: the canvas's bare-letter
            // shortcuts keep working unchanged, and clicking the bar focuses it too.
            // SwiftUI delivers the press here only when the canvas is NOT capturing the
            // key; the always-available focus path remains a click on the field.
            .onKeyPress("/") {
                commandBarFocused = true
                return .handled
            }
    }

    /// The grouped tool / image / undo / redo / delete focused-scene-value handlers,
    /// pulled out of `canvasDetail` so that view's modifier chain stays within the
    /// Swift type-checker's complexity budget. Each handler is identical to its former
    /// inline form (a tool activation, the Image file-picker flow, undo/redo, delete).
    private var toolActionHandlers: some ViewModifier {
        ToolActionHandlersModifier(
            activateTool: { kind in controllerBox.controller?.activateTool(kind) },
            // Tools ▸ Image… (and the ⌘K palette's Image entry) route through the
            // file-picker flow, not a bare `activateTool(.image)`, so the user always
            // chooses a file before placement.
            placeImage: { chooseAndPlaceImage() },
            undo: { model.undo() },
            redo: { model.redo() },
            delete: {
                if model.deleteSelection() { controllerBox.controller?.requestRedraw() }
            },
            // ⌘D Duplicate: resolve the current selection, duplicate it via the pure
            // `Duplicate.duplicate` static API (a small AutoCAD-standard nudge), and
            // apply the resulting edits as ONE undoable group through the model funnel.
            duplicate: {
                if model.duplicateSelection() { controllerBox.controller?.requestRedraw() }
            }
        )
    }

    /// The per-LAYOUT plot focused-scene-value handlers (Export Layout to PDF… / Print
    /// Layout…), pulled into one modifier so `canvasDetail`'s chain stays under the
    /// type-checker's complexity budget. Each closure is published only when a layout
    /// tab is active (paper space); in model space it is `nil`, which disables the menu
    /// items. The save/print PANELS live in the action closures (View layer only).
    private var layoutPlotHandlers: some ViewModifier {
        LayoutPlotHandlersModifier(
            exportLayout: model.activeLayoutRecord != nil
                ? { Task { @MainActor in exportActiveLayoutPDF() } } : nil,
            printLayout: model.activeLayoutRecord != nil
                ? { printActiveLayout() } : nil
        )
    }

    /// The Blocks file-I/O focused-scene-value handlers ("Insert Block from File…" /
    /// "Save Block to File…" + the save target name), pulled into one modifier so
    /// `canvasDetail`'s chain stays under the type-checker's complexity budget (gotcha
    /// #2). The NSOpenPanel/NSSavePanel live inside the action closures (View layer).
    private var blockFileHandlers: some ViewModifier {
        BlockFileHandlersModifier(
            insertFromFile: { insertBlockFromFile() },
            saveToFile: { name in saveBlockToFile(named: name) },
            saveTargetName: saveBlockTargetName
        )
    }

    /// Raises the "Create Block from Selection…" name sheet (WAVE BW, Ask #1) after
    /// capturing a fresh unique suggested name. Called from the Blocks menu / ⌘K palette
    /// / canvas context menu (each gated on a non-empty selection). A no-op with nothing
    /// selected (the model op needs a selection); the sheet's confirm runs
    /// `beginCreateBlock`. The sheet itself is the only modal — never reached by tests.
    private func raiseBlockNamePrompt() {
        guard model.hasSelection else { return }
        suggestedBlockName = model.suggestedBlockName()
        showBlockNamePrompt = true
    }

    /// The block the Blocks ▸ "Save Block to File…" menu item targets: the block of the
    /// first SELECTED `.insert` (so right-clicking / selecting an inserted block then
    /// using the menu saves that one), else the FIRST defined block (a sensible default
    /// so the menu is usable without a selection). `nil` — which DISABLES the menu item —
    /// when the drawing defines no blocks. The per-row Blocks-panel "Save Block to File…"
    /// already names its block explicitly; this only backs the menu-bar item.
    private var saveBlockTargetName: String? {
        BlockFileMenuWiring.saveTargetName(selectionIDs: model.selection.ids,
                                           in: model.drawing)
    }

    // MARK: - Document ⇄ live model bridge (MAIN ACTOR)

    /// Builds the live `@MainActor CADDrawing`/`CanvasModel` from the document's
    /// Sendable payload, frames it, and adopts the environment UndoManager. Runs on
    /// the main actor (the whole view does); the payload was parsed OFF-main in the
    /// document, so nothing here crosses the launch-crash boundary.
    @MainActor
    private func loadFromDocument() {
        // Push the app-wide Text defaults (Preferences ▸ Text) into the Text tool so
        // newly authored text uses the chosen font/height. Idempotent — reads the
        // current prefs each load; absent prefs leave the built-in "Standard"/2.5.
        applyTextDefaults()
        // Honor the autosave preference for new windows (Preferences ▸ General).
        applyAutosavePreference()

        // A BRAND-NEW document (File ▸ New) arrives with the empty payload. Seed it
        // from the General preferences: start from the default template if one is set
        // + bundled, otherwise an empty drawing carrying the preferred units. An
        // OPENED file keeps its own header units (its DXF is authoritative) — we only
        // seed a fresh, empty drawing.
        if PrefsSeeding.isNewEmptyPayload(document.payload),
           let resource = PrefsSeeding.templateResourceName(forPrefID: prefDefaultTemplate),
           let template = DrawingTemplate.bundled.first(where: { $0.resourceName == resource }) {
            Task { await seedNewDocument(from: template) }
            return
        }

        let drawing = CADDrawing.make(from: PrefsSeeding.seededPayload(
            document.payload, defaultUnitRaw: prefDefaultUnitRaw))
        model.setDrawing(drawing, viewSize: model.viewport.size)
        adoptEnvironmentUndo()
        controllerBox.controller?.zoomToFit()
        let n = model.entityCount
        status = n == 0 ? "New drawing (\(DrawingUnit(rawValue: prefDefaultUnitRaw)?.sign ?? ""))" : "\(n) entities"
    }

    /// Pushes the Preferences ▸ Text defaults (font style + height) into the pure
    /// `TextTool` defaults so a new `TextTool()` authors text with them. `TextTool`
    /// lives in CADEngine and cannot read the executable's `@AppStorage`, so the app
    /// hands the resolved values down (the same set-once pattern `CanvasTheme` uses
    /// for the canvas chrome). Validation (empty font / non-positive height → built-in
    /// fallback) happens inside `applyAppDefaults`.
    @MainActor
    private func applyTextDefaults() {
        TextTool.applyAppDefaults(fontStyleName: prefTextFont, height: prefTextHeight)
    }

    /// Honors the Preferences ▸ General autosave toggle for new windows by driving the
    /// shared document controller's autosaving delay: a positive delay enables
    /// periodic autosave-in-place, 0 disables the timed autosave. Absent the pref this
    /// is the default ON (today's behavior).
    @MainActor
    private func applyAutosavePreference() {
        NSDocumentController.shared.autosavingDelay = prefAutosaveEnabled
            ? PrefsSeeding.autosaveDelaySeconds : 0
    }

    /// Seeds THIS fresh window from the General-pref default template, then pushes it
    /// into the document so a Save writes the seeded geometry. Reuses the same
    /// off-main DXF read path as `seedFromTemplate` (a template is just a DXF).
    @MainActor
    private func seedNewDocument(from template: DrawingTemplate) async {
        await seedFromTemplate(template)
    }

    /// Seeds THIS window's drawing from a bundled `.dxf` template (File ▸ New from
    /// Template…, F24). The template bytes are parsed OFF the main actor via the SAME
    /// `DXFDocumentCodec` read path the document Open flow uses (so a template is just
    /// a normal DXF — its entities, layers, and header units come through unchanged);
    /// the resulting `Sendable` payload is then turned into the live `@MainActor`
    /// drawing ON the main actor (the launch-safe boundary), framed, and pushed into
    /// the document so a subsequent Save / Save As writes the seeded geometry. The
    /// seeded drawing replaces whatever was in this window (a fresh File ▸ New is the
    /// usual starting point), giving the user a pre-populated drawing to edit.
    @MainActor
    private func seedFromTemplate(_ template: DrawingTemplate) async {
        guard let url = template.fileURL else {
            status = "Template not found: \(template.displayName)"
            return
        }
        do {
            // Read the template bytes, then parse them off-main on a detached task
            // (the codec blocks a background thread — never the main actor — exactly
            // like the document Open path). The returned payload is Sendable.
            let data = try Data(contentsOf: url)
            let payload = try await Task.detached {
                try DXFDocumentCodec.payload(from: data, format: .dxf)
            }.value
            // Build the live drawing from the payload ON the main actor (this view is
            // main-actor; no MainActor.assumeIsolated, so the launch-crash boundary is
            // respected), frame it, and keep the document payload in sync for Save.
            let drawing = CADDrawing.make(from: payload)
            model.setDrawing(drawing, viewSize: model.viewport.size)
            adoptEnvironmentUndo()
            controllerBox.controller?.zoomToFit()
            syncPayloadToDocument()
            let n = model.entityCount
            status = "New from \(template.displayName) — \(n) " + (n == 1 ? "entity" : "entities")
        } catch {
            status = "Template load failed: \(error.localizedDescription)"
            NSLog("CADCanvas: template load failed: \(error)")
        }
    }

    /// Adopts SwiftUI's environment `UndoManager` (from `DocumentGroup`) into the
    /// model so edits dirty the native document. No-op when unavailable (the very
    /// first body pass) or already adopted.
    @MainActor
    private func adoptEnvironmentUndo() {
        guard let manager = environmentUndoManager else { return }
        model.adoptUndoManager(manager)
    }

    /// A change-detection id for the environment UndoManager (object identity), so
    /// `.onChange` re-adopts when SwiftUI supplies/replaces it after the first pass.
    private var environmentUndoManagerID: ObjectIdentifier? {
        environmentUndoManager.map(ObjectIdentifier.init)
    }

    /// Pushes the live drawing's latest contents into the document's payload so the
    /// next Save / autosave / version serializes the current geometry. Value-type
    /// snapshot only — no off-main codec call here (serialization happens later in
    /// the document's `fileWrapper`, off-main).
    @MainActor
    private func syncPayloadToDocument() {
        document.updatePayload(model.drawing.payloadSnapshot)
    }

    // MARK: - Toolbar (grouped: core + Draw / Modify / Annotate, with overflow)

    /// The grouped tool toolbar (macOS-HIG). Instead of one overcrowded flat row of
    /// ~50 buttons, tools are organized into a small always-visible CORE (Select +
    /// the user's PINNED tools) followed by three group sections — Draw, Modify,
    /// Annotate — each rendered as its pinned buttons plus a `▾` overflow `Menu` that
    /// lists EVERY tool in that group (so nothing is ever unreachable). The overflow
    /// menu doubles as the customization surface: each entry toggles whether the tool
    /// is pinned to the toolbar (a checkmark shows the current state), persisted via
    /// `@AppStorage`. Decomposed into small per-group helpers so the SwiftUI
    /// type-checker never sees a large monolithic toolbar expression (gotcha #2).
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            // Always-visible core: Select is never groupable/unpinnable.
            toolButton(.select)

            Divider()
            groupSection(.draw)
            Divider()
            groupSection(.modify)
            Divider()
            groupSection(.annotate)
        }
    }

    /// One group's toolbar section: its PINNED tools as buttons, then a `▾` overflow
    /// `Menu` carrying the whole group (every tool, with a pin toggle each). Split out
    /// per group so each toolbar sub-expression stays tiny for the type-checker.
    @ViewBuilder
    private func groupSection(_ group: ToolGroup) -> some View {
        ForEach(pinnedTools(in: group), id: \.self) { kind in
            toolButton(kind)
        }
        groupOverflowMenu(group)
    }

    /// The `▾` overflow menu for one group: every tool in the group (so all are
    /// reachable regardless of what is pinned), each as an "activate" button plus a
    /// "pin to toolbar" checkbox toggle for customization. Built from `ToolCatalog`,
    /// the single source of truth shared with the test's no-orphan check.
    @ViewBuilder
    private func groupOverflowMenu(_ group: ToolGroup) -> some View {
        Menu {
            ForEach(ToolCatalog.tools(in: group), id: \.self) { kind in
                overflowEntry(kind)
            }
        } label: {
            Label(group.title, systemImage: group.symbol)
        }
        .menuIndicator(.visible)
        .help("\(group.title) tools — click to activate or pin to the toolbar")
    }

    /// One overflow-menu row for a tool: an "activate" button (its title + glyph +
    /// shortcut hint) and a nested pin toggle so the user can add/remove it from the
    /// primary toolbar (the lightweight, no-risk "Customize…" affordance, #4).
    @ViewBuilder
    private func overflowEntry(_ kind: ToolKind) -> some View {
        let meta = ToolCatalog.metadata(for: kind)
        Menu {
            // Activate (the same routing the toolbar button uses — Image goes through
            // the file-picker flow, everything else through `activateTool`).
            Button("Use \(kind.title)") { activate(kind) }
            Divider()
            // Pin / unpin: customize which tools appear as primary toolbar buttons.
            Toggle("Show in Toolbar", isOn: pinBinding(kind))
        } label: {
            Label("\(kind.title)\(meta.shortcut.map { "  (\($0))" } ?? "")",
                  systemImage: meta.symbol)
        }
    }

    /// The trailing toolbar item: a toggle for the Inspector pane (the standard Mac
    /// inspector affordance). Placed in the trailing group so it sits at the far
    /// right, next to where the inspector opens.
    @ToolbarContentBuilder
    private var inspectorToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the Inspector")
        }
    }

    /// A single primary-toolbar tool button: activates `kind`, labels it from the
    /// shared `ToolCatalog` (glyph + help carrying the shortcut), and shows the
    /// active-tool badge. Symbol/help come from the catalog so the toolbar, overflow
    /// menu, and palette stay consistent.
    @ViewBuilder
    private func toolButton(_ kind: ToolKind) -> some View {
        let meta = ToolCatalog.metadata(for: kind)
        Button {
            activate(kind)
        } label: {
            Label(kind.title, systemImage: meta.symbol)
        }
        .help(meta.help)
        .background(activeBadge(kind))
    }

    /// A subtle highlight behind the active tool's toolbar button.
    @ViewBuilder
    private func activeBadge(_ kind: ToolKind) -> some View {
        if model.activeToolKind == kind {
            RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.25))
        }
    }

    /// Routes a tool activation the same way the menus/palette do: the `.image` kind
    /// goes through the file-picker placement flow (a bare activate would arm an inert
    /// no-file tool); `.createBlock` goes through the name sheet (WAVE BW, Ask #1 — spec
    /// §2.1: name the block first, gated on a selection inside `raiseBlockNamePrompt`);
    /// every other kind activates directly on the focused canvas.
    private func activate(_ kind: ToolKind) {
        switch kind {
        case .image:       chooseAndPlaceImage()
        case .createBlock: raiseBlockNamePrompt()
        default:           controllerBox.controller?.activateTool(kind)
        }
    }

    // MARK: - Toolbar customization (pinned tools, @AppStorage)

    /// The set of tools currently PINNED to the primary toolbar. When the stored
    /// string is empty (never customized) this is the built-in `ToolCatalog`
    /// default; once the user toggles any pin, a leading sentinel ("•") marks the
    /// string as authoritative so an empty-after-customize state (everything
    /// unpinned) is honored rather than reverting to the default.
    private var pinnedToolsSet: Set<ToolKind> {
        guard pinnedToolsRaw.hasPrefix(Self.pinnedSentinel) else {
            return ToolCatalog.defaultPrimary
        }
        let body = String(pinnedToolsRaw.dropFirst(Self.pinnedSentinel.count))
        let kinds = body.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
        return Set(kinds)
    }

    /// A sentinel prefix that distinguishes "user has customized (even to empty)"
    /// from "never customized (use the default set)".
    private static let pinnedSentinel = "•"

    /// The pinned tools of one group, in the group's canonical catalog order, so the
    /// primary toolbar buttons read left-to-right in a stable sequence.
    private func pinnedTools(in group: ToolGroup) -> [ToolKind] {
        let pinned = pinnedToolsSet
        return ToolCatalog.tools(in: group).filter { pinned.contains($0) }
    }

    /// A two-way binding for whether `kind` is pinned to the toolbar, persisting the
    /// updated set (with the customized sentinel) back into `@AppStorage`.
    private func pinBinding(_ kind: ToolKind) -> Binding<Bool> {
        Binding(
            get: { pinnedToolsSet.contains(kind) },
            set: { isOn in
                var set = pinnedToolsSet
                if isOn { set.insert(kind) } else { set.remove(kind) }
                // Persist in canonical catalog order, prefixed with the sentinel.
                let ordered = ToolCatalog.allGroupedTools.filter { set.contains($0) }
                pinnedToolsRaw = Self.pinnedSentinel + ordered.map(\.rawValue).joined(separator: ",")
            }
        )
    }

    // MARK: - Command palette registry

    /// The full ⌘K command list. Tool entries call the controller's `activateTool`
    /// (the same call the toolbar button makes); app actions fire the exact same
    /// closures the menu items fire — so running a command from the palette is
    /// indistinguishable from using the menu/toolbar. The matcher/ranking is the
    /// pure `CommandMatcher` in CADEngine.
    ///
    /// Open / Save / Save As are now native DocumentGroup commands (not view actions),
    /// so the palette's Open/Save entries route through the standard responder-chain
    /// menu selectors rather than custom panels (see CommandRegistry wiring).
    private var paletteCommands: [PaletteCommand] {
        CommandRegistry.commands(.init(
            activateTool: { kind in controllerBox.controller?.activateTool(kind) },
            placeImage: { chooseAndPlaceImage() },
            createBlockFromSelection: { raiseBlockNamePrompt() },
            open: { sendDocumentAction(#selector(NSDocumentController.openDocument(_:))) },
            save: { sendDocumentAction(#selector(NSDocument.save(_:))) },
            saveAs: { sendDocumentAction(#selector(NSDocument.saveAs(_:))) },
            export: { format in Task { await exportDrawing(format) } },
            print: { printDrawing() },
            zoomToFit: { controllerBox.controller?.zoomToFit() },
            undo: { model.undo() },
            redo: { model.redo() },
            toggleInspector: { showInspector.toggle() },
            toggleGrid: { model.gridVisible.toggle(); controllerBox.controller?.requestRedraw() },
            documentSettings: { showSettings = true }
        ))
    }

    /// Fires a standard document menu selector down the responder chain (used by the
    /// ⌘K palette's Open/Save/Save As entries now that DocumentGroup owns those).
    private func sendDocumentAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    // MARK: - HUD

    /// The small top-leading file/operation status chip (load count, export result).
    /// This is NOT a coordinate/tool readout (those moved to the persistent status
    /// bar in U3) — it surfaces document-level status messages, so it stays.
    private var statusHUD: some View {
        Text(status)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(6)
            // Adaptive chip: a system material instead of a fixed black wash, so the
            // HUD reads correctly over BOTH the light and dark canvas (the material
            // + semantic `.secondary` text invert with the appearance).
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .opacity(status.isEmpty ? 0 : 1)
    }

    /// DB-1W + DB-2W: the dynamic-block authoring panels, floated at the canvas top-trailing
    /// while a block-edit session is active — the VISIBILITY STATES panel (DB-1) stacked
    /// above the PARAMETERS & ACTIONS panel (DB-2). Each renders its own chrome only when
    /// `model.isEditingBlock`, so this is a thin host (padded so it clears the
    /// toolbar/tool-options chrome). Bound to the same live `CanvasModel` the canvas uses.
    @ViewBuilder
    private var visibilityStatesPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            BlockVisibilityStatesPanel(model: model, controllerBox: controllerBox)
            BlockDynamicParametersPanel(model: model, controllerBox: controllerBox)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    // MARK: - Command / coordinate input line (U1)

    /// The persistent command/coordinate field pinned to the bottom of the window.
    /// Typing here (focused via Space, click, or ⇧⌘L) and pressing Return parses the
    /// text and feeds the active tool a `.value(point)` — the precision-input path
    /// (e.g. `0,0`, `@10,0`, `5<90`). Esc returns focus to the canvas so tool
    /// shortcut letters work again. The prompt label echoes the active tool's step.
    private var commandBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            TextField(commandPlaceholder, text: $commandText)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .focused($commandFieldFocused)
                .onSubmit { submitCommand() }
                // Esc clears + returns focus to the canvas (so tool letters work).
                .onExitCommand { returnFocusToCanvas() }

            // De-dup (plan §3d): the syntax hint lives ONLY in the placeholder now;
            // the trailing duplicate else-branch hint is removed. Keep the trailing
            // slot for ERROR display (so a typo like `1,,2` is shown in red). The verb
            // hints (⏎ / ⌫ / esc) live in the StatusBar only.
            if let error = model.lastCommandError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The active tool's step prompt + the accepted coordinate syntax, shown as the
    /// field's placeholder/hint (the SINGLE place the syntax hint appears). A short
    /// neutral hint in select mode.
    private var commandPlaceholder: String {
        let hint = model.commandHint
        return hint.isEmpty
            ? "Command — type a coordinate (x,y · @dx,dy · dist<angle)"
            : hint
    }

    /// Parses + submits the current command text via the model, clears the field on
    /// success, and keeps focus for the next coordinate (a chained run types many).
    private func submitCommand() {
        let didChange = model.submitCommandText(commandText)
        if model.lastCommandError == nil {
            commandText = ""
            // A successful submit may have committed geometry / moved the preview.
            if didChange { controllerBox.controller?.requestRedraw() }
        }
        // Keep focus in the field so the user can type the next point immediately.
    }

    /// Returns keyboard focus to the canvas (Esc): clears the field text and the
    /// error, drops the field focus so the MTKView reclaims first-responder and tool
    /// shortcut letters route to it again.
    private func returnFocusToCanvas() {
        commandText = ""
        commandFieldFocused = false
        controllerBox.controller?.returnFocusToCanvas()
    }

    // MARK: - Export (PDF / PNG / SVG) and Print (⌘P)
    //
    // These STAY custom (not the document type). DocumentGroup owns only DXF
    // Open/Save/Save As/autosave; export renders the live drawing to other formats
    // and Print drives the system print dialog.

    /// Export… for one `format`: present an `NSSavePanel` defaulting to a sensible
    /// name with that format's extension, then render the current drawing through
    /// the shared export facade (PDF/PNG via the CGContext renderer, SVG via the
    /// engine's pure-Swift emitter). Status/errors land in the HUD — never a crash.
    @MainActor
    private func exportDrawing(_ format: ExportFormat) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(exportBaseName).\(format.fileExtension)"
        panel.title = "Export \(format.displayName)"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Export cancelled"
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try DrawingExporter.export(model.drawing, to: url, format: format)
            status = "Exported \(url.lastPathComponent) — \(count) elements"
            NSLog("CADCanvas: exported \(count) elements to \(url.lastPathComponent)")
        } catch {
            status = "Export failed: \(error.localizedDescription)"
            NSLog("CADCanvas: export failed: \(error)")
        }
    }

    // MARK: - Image placement (file-picker → two-click placement)

    /// Activates the Image tool via a file-picker, then a two-click placement.
    ///
    /// Flow (the brief's "file-picker → 2 clicks"):
    ///   1. Present an `NSOpenPanel` filtered to common raster types (PNG / JPEG /
    ///      TIFF / GIF / BMP / HEIC). On CANCEL, revert to the select tool (so a
    ///      cancelled pick never leaves an inert Image tool armed) and return.
    ///   2. On a pick, read the source PIXEL size from the file via `NSImage`'s pixel-
    ///      backed representation (the DXF IMAGE model + `ImageTool` keep the source
    ///      pixel aspect). A file with no readable raster falls back to 1×1 (the tool
    ///      then uses the click distances directly as the edge lengths).
    ///   3. Push the path + pixel size into the model and activate the Image tool
    ///      (`setImageSourceAndActivate`), so the next two canvas clicks place the
    ///      image: the first is the lower-left corner, the second a bottom-edge corner
    ///      that sets the width + rotation (ImageTool already does the geometry).
    @MainActor
    private func chooseAndPlaceImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
        panel.title = "Choose an Image to Place"
        panel.prompt = "Place"

        guard panel.runModal() == .OK, let url = panel.url else {
            // Cancelled — don't leave an inert Image tool armed; return to select.
            controllerBox.controller?.activateTool(.select)
            status = "Image placement cancelled"
            return
        }
        let (pw, ph) = Self.imagePixelSize(of: url)
        model.setImageSourceAndActivate(path: url.path, pixelWidth: pw, pixelHeight: ph)
        controllerBox.controller?.requestRedraw()
        status = "Place image \(url.lastPathComponent) — click two corners"
    }

    /// The source PIXEL dimensions of the image at `url`, read from its pixel-backed
    /// `NSImageRep` (NOT `NSImage.size`, which is in points and DPI-scaled). Falls back
    /// to 1×1 when the file has no readable raster representation, so a bad pick never
    /// produces a zero-size placement (the tool then uses the click distances as the
    /// edge lengths directly).
    private static func imagePixelSize(of url: URL) -> (Double, Double) {
        guard let image = NSImage(contentsOf: url) else { return (1, 1) }
        for rep in image.representations {
            if rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                return (Double(rep.pixelsWide), Double(rep.pixelsHigh))
            }
        }
        // No pixel-backed rep — fall back to the (point) size if positive, else 1×1.
        let s = image.size
        return (s.width > 0 ? Double(s.width) : 1, s.height > 0 ? Double(s.height) : 1)
    }

    /// A reasonable default base name for an exported file: the focused document
    /// window's title (the file name DocumentGroup shows), else "Drawing".
    private var exportBaseName: String {
        let title = NSApp.keyWindow?.title ?? ""
        let trimmed = title.replacingOccurrences(of: " — Edited", with: "")
        return trimmed.isEmpty ? "Drawing" : trimmed
    }

    /// Print… (⌘P): present the system print dialog for the current drawing,
    /// fitted to the chosen paper. Attaches to the key window as a sheet when one
    /// is available.
    @MainActor
    private func printDrawing() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !DrawingPrinter.print(model.drawing, in: window) {
            status = "Print cancelled"
        }
    }

    // MARK: - Block file I/O (Insert Block from File / Save Block to File — WBLOCK)

    /// "Insert Block from File… (DXF)" (Blocks menu / Blocks panel ⋯): present an
    /// `NSOpenPanel` filtered to `.dxf`, import the chosen file as a NAMED block (via the
    /// engine's collision-safe `BlockLibrary.importDXF`, which de-dups a colliding name —
    /// never an in-place overwrite), and place ONE insert at the current view CENTER. The
    /// `NSOpenPanel` and the post-import index/selection sync live HERE in the View layer
    /// (the headless-modal trap: a panel reached from a test would hang the suite). The
    /// async read runs on the shared `CADEngine` actor; the apply hops back to the main
    /// actor inside `importDXF`. Errors / cancels land in the HUD — never a crash.
    @MainActor
    private func insertBlockFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = LibreCADDocument.dxfTypes
        panel.title = "Insert Block from File"
        panel.prompt = "Insert"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Insert block cancelled"
            return
        }
        let path = url.path
        let displayName = url.lastPathComponent
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockLibrary.importDXF(path: path,
                                                                    into: model.drawing) else {
                    status = "“\(displayName)” has no importable geometry"
                    return
                }
                // The import added the block + a placeholder insert at the origin via the
                // engine op; re-place it at the view center so the user sees it, syncing
                // the spatial index + selection via the model's insert path. (Importing
                // at the origin first keeps the engine op pure; the model insert is what
                // makes the placed reference selectable/snappable.)
                model.drawing.remove(result.insertID)
                model.quadtree.remove(result.insertID)
                _ = model.insertBlockAtViewCenter(named: result.blockName)
                model.modelDirty = true
                model.modelVersion &+= 1
                controllerBox.controller?.requestRedraw()
                status = "Inserted block “\(result.blockName)” from \(displayName)"
            } catch {
                status = "Insert block failed: \(error.localizedDescription)"
                NSLog("CADCanvas: insert block from file failed: \(error)")
            }
        }
    }

    /// "Save Block to File… (WBLOCK)" (Blocks panel row context menu / Blocks menu):
    /// present an `NSSavePanel` defaulting to `<block>.dxf`, then write the named block's
    /// geometry to a standalone `.dxf` re-based to the origin (via the engine's
    /// `BlockExport.writeBlock`). The `NSSavePanel` lives HERE in the View layer
    /// (headless-modal trap). The write runs on the shared `CADEngine` actor. A no-op
    /// (HUD note) for an unknown/empty block; errors / cancels land in the HUD.
    @MainActor
    private func saveBlockToFile(named name: String) {
        guard model.drawing.blocks.contains(name) else {
            status = "No block named “\(name)” to save"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = LibreCADDocument.dxfTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(name).dxf"
        panel.title = "Save Block to File"
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Save block cancelled"
            return
        }
        let path = url.path
        let displayName = url.lastPathComponent
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockExport.writeBlock(model.drawing,
                                                                    name: name,
                                                                    toPath: path) else {
                    status = "Block “\(name)” has no geometry to save"
                    return
                }
                status = "Saved block “\(name)” to \(displayName) — \(result.recordCount) elements"
            } catch {
                status = "Save block failed: \(error.localizedDescription)"
                NSLog("CADCanvas: save block to file failed: \(error)")
            }
        }
    }

    // MARK: - Per-LAYOUT plot (Paper Space P4 — File ▸ Export Layout / Print Layout)

    /// Export Layout to PDF… (File menu, enabled only in a layout tab): plots the
    /// ACTIVE layout sheet at its own plot scale to a single-page PDF. The PURE scene
    /// is built by `CanvasModel.layoutExportScene` (paper-space records on the active
    /// layout); the `NSSavePanel` lives HERE in the View layer (never in the model /
    /// tool — headless-hang trap). A no-op (status note) when no layout is active.
    @MainActor
    private func exportActiveLayoutPDF() {
        guard let layout = model.activeLayoutRecord else {
            status = "Open a layout tab to export a layout sheet"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(exportBaseName)-\(layout.name).pdf"
        panel.title = "Export Layout “\(layout.name)” to PDF"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Layout export cancelled"
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let scene = model.layoutExportScene(for: layout)
            try DrawingExporter.writeLayoutPDF(scene: scene, layout: layout, to: url)
            status = "Exported layout “\(layout.name)” — \(url.lastPathComponent)"
            NSLog("CADCanvas: exported layout \(layout.name) to \(url.lastPathComponent)")
        } catch {
            status = "Layout export failed: \(error.localizedDescription)"
            NSLog("CADCanvas: layout export failed: \(error)")
        }
    }

    /// Print Layout… (File menu, enabled only in a layout tab): drives the system print
    /// dialog for the ACTIVE layout sheet, plotted at the layout's plot scale. The PURE
    /// scene is built by `CanvasModel.layoutExportScene`; `NSPrintOperation` lives HERE
    /// in the View layer. A no-op (status note) when no layout is active.
    @MainActor
    private func printActiveLayout() {
        guard let layout = model.activeLayoutRecord else {
            status = "Open a layout tab to print a layout sheet"
            return
        }
        let scene = model.layoutExportScene(for: layout)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !DrawingPrinter.printLayout(layout, scene: scene, in: window) {
            status = "Layout print cancelled"
        }
    }
}

// MARK: - Tool grouping catalog (single source of truth)

/// The three macOS-HIG toolbar/menu groups every drawing tool falls into. `.select`
/// is intentionally NOT a group member — it is the always-visible core mode, handled
/// separately. Mirrors AutoCAD's ribbon split (Draw / Modify / Annotate).
enum ToolGroup: String, CaseIterable, Sendable {
    /// Geometry-creating tools (lines, curves, hatch, image, construction lines).
    case draw
    /// Selection transforms + edit-under-cursor tools + block ops.
    case modify
    /// Text, dimensions, leaders, and read-only measurement tools.
    case annotate

    /// The group's menu/overflow label.
    var title: String {
        switch self {
        case .draw:     return "Draw"
        case .modify:   return "Modify"
        case .annotate: return "Annotate"
        }
    }

    /// An SF Symbol for the group's `▾` overflow button / menu.
    var symbol: String {
        switch self {
        case .draw:     return "pencil.tip.crop.circle"
        case .modify:   return "slider.horizontal.3"
        case .annotate: return "text.bubble"
        }
    }
}

/// The canonical mapping from every `ToolKind` to its UI group + display metadata
/// (SF Symbol, tooltip help carrying the shortcut, and a compact shortcut hint).
///
/// This is the SINGLE SOURCE OF TRUTH the grouped toolbar AND the grouped Tools menu
/// both read, so the two never drift. The engine test target cannot import this app
/// module, so `ToolKindWiringTests` mirrors this same roster and asserts it covers
/// every `ToolKind` (no orphaned tools) — a deliberate data-mirror guard (the same
/// pattern `toolShortcutsAreUnique` uses).
enum ToolCatalog {

    /// Per-tool display metadata.
    struct Metadata {
        let symbol: String
        let help: String
        /// A compact keyboard hint (e.g. "L", "⇧C", "⌥A") for menu/overflow rows;
        /// `nil` for tools reachable only via menu/⌘K (no key chord).
        let shortcut: String?
    }

    /// The group `kind` belongs to, or `nil` for `.select` (the core mode, not a
    /// group member).
    static func group(for kind: ToolKind) -> ToolGroup? {
        for group in ToolGroup.allCases where tools(in: group).contains(kind) {
            return group
        }
        return nil
    }

    /// Every tool in one group, in canonical (toolbar/menu) order.
    static func tools(in group: ToolGroup) -> [ToolKind] {
        switch group {
        case .draw:     return drawTools
        case .modify:   return modifyTools
        case .annotate: return annotateTools
        }
    }

    /// All grouped tools (Draw → Modify → Annotate), in canonical order. Used to
    /// serialize the user's pinned set in a stable sequence.
    static var allGroupedTools: [ToolKind] {
        drawTools + modifyTools + annotateTools
    }

    /// The built-in default PINNED (primary toolbar) set on a fresh install — a small
    /// curated row of the most-used tools per group, so the toolbar is useful out of
    /// the box without being overcrowded. Everything else lives in the group `▾`
    /// overflow menus. The user can re-pin any tool (persisted via `@AppStorage`).
    static let defaultPrimary: Set<ToolKind> = [
        // Draw essentials.
        .line, .circle, .arc, .rectangle, .polyline,
        // Modify essentials.
        .move, .copy, .rotate, .scale, .trim, .offset,
        // Annotate essentials.
        .text, .linearDim, .leader,
    ]

    // MARK: Group rosters (canonical order)

    private static let drawTools: [ToolKind] = [
        .line, .circle, .arc, .rectangle, .polyline, .point,
        .ellipse, .polygon, .spline, .hatch, .image,
        .xline, .ray, .insert, .viewport,
    ]

    private static let modifyTools: [ToolKind] = [
        .move, .copy, .offset, .rotate, .scale, .mirror,
        .array, .arrayPath, .divide, .explode, .stretch, .lengthen, .break,
        .trim, .extend, .fillet, .chamfer,
        .polylineEdit, .join, .explodeText, .align,
        .createBlock, .explodeInsert,
    ]

    private static let annotateTools: [ToolKind] = [
        .text,
        .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim,
        .ordinateDim, .arcLengthDim, .angular3pDim,
        .leader, .baselineDim, .continueDim,
        .measureDistance, .measureAngle, .measureArea, .measureLength,
    ]

    // MARK: Per-tool display metadata

    /// SF Symbol + tooltip help (with shortcut) + compact shortcut hint for `kind`.
    static func metadata(for kind: ToolKind) -> Metadata {
        switch kind {
        case .select:    return .init(symbol: "cursorarrow", help: "Select / pan (V)", shortcut: "V")
        // Draw.
        case .line:      return .init(symbol: "line.diagonal", help: "Draw line (L)", shortcut: "L")
        case .circle:    return .init(symbol: "circle", help: "Draw circle (C)", shortcut: "C")
        case .arc:       return .init(symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                      help: "Draw arc (A)", shortcut: "A")
        case .rectangle: return .init(symbol: "rectangle", help: "Draw rectangle (R)", shortcut: "R")
        case .polyline:  return .init(symbol: "scribble", help: "Draw polyline (P)", shortcut: "P")
        case .point:     return .init(symbol: "smallcircle.filled.circle", help: "Place point (O)", shortcut: "O")
        case .ellipse:   return .init(symbol: "oval", help: "Draw ellipse (E)", shortcut: "E")
        case .polygon:   return .init(symbol: "hexagon", help: "Draw polygon (G)", shortcut: "G")
        case .spline:    return .init(symbol: "scribble.variable", help: "Draw spline (S)", shortcut: "S")
        case .hatch:     return .init(symbol: "square.grid.2x2.fill", help: "Hatch fill selection (H)", shortcut: "H")
        case .image:     return .init(symbol: "photo",
                                      help: "Place image — pick a file, then click two corners (⇧Y)", shortcut: "⇧Y")
        case .xline:     return .init(symbol: "line.diagonal.arrow",
                                      help: "Construction line — infinite (⌥I)", shortcut: "⌥I")
        case .ray:       return .init(symbol: "arrow.up.right",
                                      help: "Ray — semi-infinite construction line (⌥Y)", shortcut: "⌥Y")
        case .insert:    return .init(symbol: "square.on.square.dashed", help: "Insert block (⇧I)", shortcut: "⇧I")
        // Modify.
        case .move:      return .init(symbol: "arrow.up.and.down.and.arrow.left.and.right",
                                      help: "Move selection (M)", shortcut: "M")
        case .copy:      return .init(symbol: "plus.square.on.square", help: "Copy selection (⇧C)", shortcut: "⇧C")
        case .offset:    return .init(symbol: "plus.rectangle.on.rectangle",
                                      help: "Offset selection (⇧O)", shortcut: "⇧O")
        case .rotate:    return .init(symbol: "rotate.right", help: "Rotate selection (⇧R)", shortcut: "⇧R")
        case .scale:     return .init(symbol: "square.resize", help: "Scale selection (⇧S)", shortcut: "⇧S")
        case .mirror:    return .init(symbol: "flip.horizontal", help: "Mirror selection (⇧M)", shortcut: "⇧M")
        case .array:     return .init(symbol: "square.grid.3x3", help: "Array selection (⇧A)", shortcut: "⇧A")
        case .arrayPath: return .init(symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                      help: "Array selection along a path (⌥P)", shortcut: "⌥P")
        case .divide:    return .init(symbol: "divide", help: "Divide selection (⇧D)", shortcut: "⇧D")
        case .explode:   return .init(symbol: "burst", help: "Explode selection (⇧X)", shortcut: "⇧X")
        case .stretch:   return .init(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                      help: "Stretch selection (⌥S)", shortcut: "⌥S")
        case .lengthen:  return .init(symbol: "ruler", help: "Lengthen line/arc (⇧L)", shortcut: "⇧L")
        case .break:     return .init(symbol: "scissors.badge.ellipsis", help: "Break entity (⇧B)", shortcut: "⇧B")
        case .trim:      return .init(symbol: "scissors", help: "Trim to boundary (T)", shortcut: "T")
        case .extend:    return .init(symbol: "arrow.right.to.line", help: "Extend to boundary (X)", shortcut: "X")
        case .fillet:    return .init(symbol: "circle.bottomrighthalf.checkered",
                                      help: "Fillet (round) corner (F)", shortcut: "F")
        case .chamfer:   return .init(symbol: "skew", help: "Chamfer (bevel) corner (⇧F)", shortcut: "⇧F")
        case .polylineEdit: return .init(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill",
                                         help: "Edit polyline vertices (⇧P)", shortcut: "⇧P")
        case .join:      return .init(symbol: "link", help: "Join lines/arcs into a polyline (⇧J)", shortcut: "⇧J")
        case .explodeText: return .init(symbol: "character.cursor.ibeam",
                                        help: "Explode text to geometry (⇧E)", shortcut: "⇧E")
        case .align:     return .init(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                      help: "Align selection to a 2-point reference (⌥A)", shortcut: "⌥A")
        case .createBlock:   return .init(symbol: "square.on.square.dashed",
                                          help: "Create block from selection (⌥B)", shortcut: "⌥B")
        case .explodeInsert: return .init(symbol: "square.split.2x2",
                                          help: "Explode block reference (⌥X)", shortcut: "⌥X")
        // Annotate.
        case .text:        return .init(symbol: "character.textbox", help: "Add text (⇧T)", shortcut: "⇧T")
        case .linearDim:   return .init(symbol: "ruler", help: "Linear dimension (D)", shortcut: "D")
        case .alignedDim:  return .init(symbol: "arrow.up.left.and.arrow.down.right",
                                        help: "Aligned dimension (I)", shortcut: "I")
        case .radialDim:   return .init(symbol: "arrow.left.and.right", help: "Radius dimension (U)", shortcut: "U")
        case .diameterDim: return .init(symbol: "circle.and.line.horizontal",
                                        help: "Diameter dimension (B)", shortcut: "B")
        case .angularDim:  return .init(symbol: "angle", help: "Angular dimension (N)", shortcut: "N")
        case .ordinateDim: return .init(symbol: "arrow.down.to.line", help: "Ordinate dimension (⌥O)", shortcut: "⌥O")
        case .arcLengthDim: return .init(symbol: "arrow.up.and.down.and.sparkles",
                                         help: "Arc length dimension (⌥G)", shortcut: "⌥G")
        case .angular3pDim: return .init(symbol: "angle", help: "Angular dimension, 3-point (⌥N)", shortcut: "⌥N")
        case .leader:      return .init(symbol: "text.bubble", help: "Leader callout (⌥L)", shortcut: "⌥L")
        case .baselineDim: return .init(symbol: "arrow.up.and.line.horizontal.and.arrow.down",
                                        help: "Baseline dimension chain (⌥D)", shortcut: "⌥D")
        case .continueDim: return .init(symbol: "arrow.left.and.line.vertical.and.arrow.right",
                                        help: "Continue dimension chain (⌥C)", shortcut: "⌥C")
        case .measureDistance: return .init(symbol: "ruler", help: "Measure distance (⇧K)", shortcut: "⇧K")
        case .measureAngle:    return .init(symbol: "angle", help: "Measure angle", shortcut: nil)
        case .measureArea:     return .init(symbol: "square.dashed", help: "Measure area + perimeter", shortcut: nil)
        case .measureLength:   return .init(symbol: "sum", help: "Total length of selection", shortcut: nil)
        // Paper-space viewport placement (Draw group). Only meaningful in a layout tab.
        case .viewport:    return .init(symbol: "rectangle.dashed",
                                        help: "Place a paper-space viewport — drag two corners on a layout sheet (⌥V)",
                                        shortcut: "⌥V")
        }
    }
}

// MARK: - Focused command plumbing

/// Focused scene values carrying the active window's app actions (Zoom-to-Fit,
/// Export, Print, tool activation, undo/redo, delete, command palette, and the
/// "a tool is mid-run" flag). Open/Save/Save As are NO LONGER here — they are
/// native DocumentGroup commands. LibreCADApp reads these in its `.commands`.
extension FocusedValues {
    /// Raise the ⌘K command palette on the focused window (View ▸ Command Palette…).
    var commandPalette: (() -> Void)? {
        get { self[CommandPaletteKey.self] }
        set { self[CommandPaletteKey.self] = newValue }
    }

    /// Open the per-document Document Settings sheet on the focused window
    /// (File ▸ Document Settings…, ⌥⌘, — D8).
    var openDocumentSettings: (() -> Void)? {
        get { self[OpenDocumentSettingsKey.self] }
        set { self[OpenDocumentSettingsKey.self] = newValue }
    }

    /// Raise the "New from Template…" chooser on the focused window
    /// (File ▸ New from Template… — F24).
    var newFromTemplate: (() -> Void)? {
        get { self[NewFromTemplateKey.self] }
        set { self[NewFromTemplateKey.self] = newValue }
    }

    /// Focus the bottom command/coordinate line on the focused window
    /// (View ▸ Show Command Line, ⇧⌘L) — U1.
    var focusCommandLine: (() -> Void)? {
        get { self[FocusCommandLineKey.self] }
        set { self[FocusCommandLineKey.self] = newValue }
    }

    var zoomToFit: (() -> Void)? {
        get { self[ZoomToFitKey.self] }
        set { self[ZoomToFitKey.self] = newValue }
    }

    /// Export the focused window's drawing to a given format (File ▸ Export…).
    var exportDocument: ((ExportFormat) -> Void)? {
        get { self[ExportDocumentKey.self] }
        set { self[ExportDocumentKey.self] = newValue }
    }
    /// Print the focused window's drawing (File ▸ Print…, ⌘P).
    var printDocument: (() -> Void)? {
        get { self[PrintDocumentKey.self] }
        set { self[PrintDocumentKey.self] = newValue }
    }

    /// Export the focused window's ACTIVE LAYOUT sheet to PDF (File ▸ Export Layout to
    /// PDF…). Published ONLY when a layout tab is active (paper space); `nil` in model
    /// space, which disables the menu item.
    var exportLayout: (() -> Void)? {
        get { self[ExportLayoutKey.self] }
        set { self[ExportLayoutKey.self] = newValue }
    }
    /// Print the focused window's ACTIVE LAYOUT sheet (File ▸ Print Layout…). Published
    /// ONLY when a layout tab is active (paper space); `nil` in model space.
    var printLayout: (() -> Void)? {
        get { self[PrintLayoutKey.self] }
        set { self[PrintLayoutKey.self] = newValue }
    }

    /// Activate a tool kind in the focused window (Tools menu / shortcuts).
    var activateTool: ((ToolKind) -> Void)? {
        get { self[ActivateToolKey.self] }
        set { self[ActivateToolKey.self] = newValue }
    }

    /// Begin Image placement on the focused window (Tools ▸ Image…): present the
    /// file-picker, then arm the two-click placement. Distinct from `activateTool`
    /// because the Image tool needs a file chosen up front.
    var placeImage: (() -> Void)? {
        get { self[PlaceImageKey.self] }
        set { self[PlaceImageKey.self] = newValue }
    }

    /// Raise the "Create Block from Selection…" name sheet on the focused window
    /// (WAVE BW, Ask #1 — Tools ▸ Modify ▸ Blocks / ⌘K palette / canvas context menu).
    /// `nil` when there is no selection, which DISABLES the menu item (the verb needs a
    /// selection). Distinct from `activateTool(.createBlock)` because creating a block
    /// asks for a NAME first (spec §2.1).
    var createBlockFromSelection: (() -> Void)? {
        get { self[CreateBlockFromSelectionKey.self] }
        set { self[CreateBlockFromSelectionKey.self] = newValue }
    }

    /// "Insert Block from File… (DXF)" on the focused window (Blocks menu / Blocks panel
    /// ⋯): present an `NSOpenPanel`, import the chosen `.dxf` as a named block, and place
    /// it at the view center. Always available when a canvas is focused.
    var insertBlockFromFile: (() -> Void)? {
        get { self[InsertBlockFromFileKey.self] }
        set { self[InsertBlockFromFileKey.self] = newValue }
    }

    /// "Save Block to File… (WBLOCK)" on the focused window (Blocks menu): present an
    /// `NSSavePanel` and write a block to a standalone `.dxf`. `nil` when there is no
    /// block to save, which DISABLES the menu item. The closure takes the block name
    /// (the menu passes the current selection's block, else the first block).
    var saveBlockToFile: ((String) -> Void)? {
        get { self[SaveBlockToFileKey.self] }
        set { self[SaveBlockToFileKey.self] = newValue }
    }

    /// The block name the Blocks ▸ "Save Block to File…" menu item should target on the
    /// focused window (the selected `.insert`'s block, else the first defined block).
    /// `nil` when the drawing has no blocks, which DISABLES the menu item.
    var saveBlockTargetName: String? {
        get { self[SaveBlockTargetNameKey.self] }
        set { self[SaveBlockTargetNameKey.self] = newValue }
    }

    /// Undo / redo the focused window's drawing (Edit menu, ⌘Z / ⇧⌘Z).
    var undoAction: (() -> Void)? {
        get { self[UndoActionKey.self] }
        set { self[UndoActionKey.self] = newValue }
    }
    var redoAction: (() -> Void)? {
        get { self[RedoActionKey.self] }
        set { self[RedoActionKey.self] = newValue }
    }

    /// Delete the focused window's current selection (Edit ▸ Delete, ⌫).
    var deleteSelection: (() -> Void)? {
        get { self[DeleteSelectionKey.self] }
        set { self[DeleteSelectionKey.self] = newValue }
    }

    /// Duplicate the focused window's current selection (Edit ▸ Duplicate, ⌘D).
    /// Duplicates the selection in place (a small nudge) as one undoable group via
    /// `CanvasModel.duplicateSelection` (the pure `Duplicate.duplicate` static API).
    var duplicateSelection: (() -> Void)? {
        get { self[DuplicateSelectionKey.self] }
        set { self[DuplicateSelectionKey.self] = newValue }
    }

    /// Whether the focused window has a draw tool mid-run. Used by LibreCADApp to
    /// disable the Edit ▸ Delete item (so its bare-⌫ shortcut does not pre-empt the
    /// tool's `.backspace` — MUST-FIX 1). `nil` when no canvas is focused; the
    /// reader treats `nil`/`false` alike (no tool ⇒ enablement governed only by
    /// `deleteSelection`).
    var isToolActive: Bool? {
        get { self[IsToolActiveKey.self] }
        set { self[IsToolActiveKey.self] = newValue }
    }
}

private struct CommandPaletteKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenDocumentSettingsKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct NewFromTemplateKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct FocusCommandLineKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ZoomToFitKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportDocumentKey: FocusedValueKey {
    typealias Value = (ExportFormat) -> Void
}

private struct PrintDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ExportLayoutKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct PrintLayoutKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ActivateToolKey: FocusedValueKey {
    typealias Value = (ToolKind) -> Void
}

private struct PlaceImageKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct CreateBlockFromSelectionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct InsertBlockFromFileKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SaveBlockToFileKey: FocusedValueKey {
    typealias Value = (String) -> Void
}

private struct SaveBlockTargetNameKey: FocusedValueKey {
    typealias Value = String
}

/// Groups the tool-activation / Image-placement / undo / redo / delete focused-scene-
/// value handlers into one `ViewModifier`, so `ContentView.canvasDetail`'s long
/// modifier chain stays under the Swift type-checker's expression-complexity limit.
/// Each closure is the same action the menus/palette/toolbar fire.
private struct ToolActionHandlersModifier: ViewModifier {
    let activateTool: (ToolKind) -> Void
    let placeImage: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let delete: () -> Void
    let duplicate: () -> Void

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.activateTool) { kind in activateTool(kind) }
            .focusedSceneValue(\.placeImage) { placeImage() }
            .focusedSceneValue(\.undoAction) { undo() }
            .focusedSceneValue(\.redoAction) { redo() }
            .focusedSceneValue(\.deleteSelection) { delete() }
            .focusedSceneValue(\.duplicateSelection) { duplicate() }
    }
}

/// Groups the per-LAYOUT plot focused-scene-value handlers (Export Layout to PDF… /
/// Print Layout…) into one `ViewModifier`, so `ContentView.canvasDetail`'s modifier
/// chain stays under the Swift type-checker's expression-complexity limit. Each value
/// is `nil` in model space (which disables the matching File-menu item) and the real
/// closure in a layout tab. The save/print panels live INSIDE the closures (View layer).
private struct LayoutPlotHandlersModifier: ViewModifier {
    let exportLayout: (() -> Void)?
    let printLayout: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.exportLayout, exportLayout)
            .focusedSceneValue(\.printLayout, printLayout)
    }
}

/// Groups the Blocks file-I/O focused-scene-value handlers ("Insert Block from File…" /
/// "Save Block to File…" + the save target block name) into one `ViewModifier`, so
/// `ContentView.canvasDetail`'s modifier chain stays under the Swift type-checker's
/// expression-complexity limit (gotcha #2). The NSOpenPanel/NSSavePanel live inside the
/// host's action closures (View layer); `saveTargetName` is `nil` when the drawing has
/// no blocks, which disables the Blocks ▸ "Save Block to File…" menu item.
private struct BlockFileHandlersModifier: ViewModifier {
    let insertFromFile: () -> Void
    let saveToFile: (String) -> Void
    let saveTargetName: String?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.insertBlockFromFile) { insertFromFile() }
            .focusedSceneValue(\.saveBlockToFile) { name in saveToFile(name) }
            .focusedSceneValue(\.saveBlockTargetName, saveTargetName)
    }
}

private struct UndoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RedoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct DeleteSelectionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct DuplicateSelectionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Carries the focused window's "a draw tool is mid-run" flag. Unlike the action
/// keys above (whose absence means "no canvas focused"), this is a plain `Bool`;
/// `FocusedValues` returns `nil` when unset, so the accessor defaults it to
/// `false` (no tool active ⇒ Delete enablement is governed only by the selection).
private struct IsToolActiveKey: FocusedValueKey {
    typealias Value = Bool
}

// MARK: - New-from-template catalog (F24)

/// A bundled drawing template the user can start a new document from (File ▸ New
/// from Template…). Each template is a plain `.dxf` file shipped in the app — a
/// "blank" template is just a DXF carrying the right header units (no entities);
/// a "titleblock" template additionally carries a border + titleblock drawn as
/// lines/text. Because a template is an ordinary DXF, seeding from one reuses the
/// SAME read path the document Open flow uses — there is no template-specific
/// parse code, only file discovery here.
///
/// File discovery follows the SAME bundle-then-repo fallback `HatchPatternLibrary`
/// and `CADFonts` use for their bundled resources:
///   • The bundled app — `LibreCADmacOS.app/Contents/Resources/templates/<file>`
///     (copied by `macos/scripts/make-app.sh`), found via `Bundle.main`.
///   • The bare SwiftPM binary / dev — the in-repo `macos/assets/templates/`,
///     derived from this file's `#filePath`.
struct DrawingTemplate: Identifiable, Hashable, Sendable {
    /// Stable id (the resource base name, e.g. `Blank_Metric_A3`).
    var id: String { resourceName }
    /// The `.dxf` resource base name (no extension), used for bundle/file lookup.
    let resourceName: String
    /// The human-readable name shown in the chooser.
    let displayName: String
    /// A one-line description (units / sheet) shown under the name.
    let summary: String
    /// An SF Symbol for the chooser row.
    let symbol: String

    /// The catalog of bundled templates, in chooser order. Keep this list in sync
    /// with the `.dxf` files in `macos/assets/templates/` (and the make-app.sh copy).
    static let bundled: [DrawingTemplate] = [
        DrawingTemplate(
            resourceName: "Blank_Metric_A3",
            displayName: "Blank — Metric (A3)",
            summary: "Millimeters · A3 sheet limits · empty",
            symbol: "doc"),
        DrawingTemplate(
            resourceName: "Blank_Imperial",
            displayName: "Blank — Imperial",
            summary: "Inches · ANSI A limits · empty",
            symbol: "doc"),
        DrawingTemplate(
            resourceName: "Titleblock_A4_Metric",
            displayName: "Title Block — Metric (A4)",
            summary: "Millimeters · A4 landscape · border + title block",
            symbol: "doc.text"),
    ]

    /// The on-disk URL of this template's `.dxf`, searching the app bundle's
    /// `Resources/templates` first, then the in-repo `macos/assets/templates`.
    /// `nil` if the file is found in neither (the caller surfaces a status error
    /// rather than crashing).
    var fileURL: URL? {
        for dir in Self.searchDirectories() {
            let url = dir.appendingPathComponent("\(resourceName).dxf")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Directories searched for `<name>.dxf`, in priority order: the app bundle's
    /// `Resources/templates`, then the in-repo `macos/assets/templates`.
    static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("templates"),
           FileManager.default.fileExists(atPath: bundled.path) {
            dirs.append(bundled)
        }
        if let repo = repoTemplatesDirectory() {
            dirs.append(repo)
        }
        return dirs
    }

    /// The in-repo `macos/assets/templates` directory, derived from this file's
    /// source path (dev fallback for the bare binary). Mirrors
    /// `HatchPatternLibrary.repoPatternsDirectory()`.
    static func repoTemplatesDirectory() -> URL? {
        // <repo>/macos/engine/Sources/LibreCADmacOS/ContentView.swift
        //   -> drop the filename + 3 dirs (LibreCADmacOS, Sources, engine) -> macos
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosDir = thisFile
            .deletingLastPathComponent()   // .../LibreCADmacOS
            .deletingLastPathComponent()   // .../Sources
            .deletingLastPathComponent()   // .../engine
            .deletingLastPathComponent()   // .../macos
        let dir = macosDir.appendingPathComponent("assets/templates")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }
}

/// The "New from Template…" chooser sheet (F24): a small list of bundled templates
/// with Cancel / Create. Picking a template (double-click or Create) calls
/// `onChoose`; the host view then seeds the window's drawing from it. A pure
/// presentation view — all the loading lives in `ContentView.seedFromTemplate`.
struct TemplateChooserView: View {
    let templates: [DrawingTemplate]
    let onChoose: (DrawingTemplate) -> Void
    let onCancel: () -> Void

    /// The currently highlighted template (defaults to the first).
    @State private var selection: DrawingTemplate.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New from Template")
                .font(.headline)
                .padding([.top, .horizontal])
                .padding(.bottom, 4)
            Text("Start a new drawing pre-populated from a template.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 8)

            List(templates, selection: $selection) { template in
                HStack(spacing: 12) {
                    Image(systemName: template.symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.displayName)
                            .font(.body.weight(.medium))
                        Text(template.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .tag(template.id)
                // Double-click a row to create immediately.
                .onTapGesture(count: 2) { onChoose(template) }
            }
            .frame(minHeight: 180)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let chosen = chosenTemplate { onChoose(chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosenTemplate == nil)
            }
            .padding()
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { if selection == nil { selection = templates.first?.id } }
    }

    /// The template matching the current selection (defaults to the first row).
    private var chosenTemplate: DrawingTemplate? {
        if let id = selection, let t = templates.first(where: { $0.id == id }) { return t }
        return templates.first
    }
}

// MARK: - Layout tab strip (paper-space P2)

/// The Model / Layout tab strip at the bottom of the detail pane (the AutoCAD/
/// LibreCAD tab position, just above the status bar): a "Model" tab, one tab per
/// `drawing.layouts` (in `tabOrder`), and a trailing "+" that adds a layout. The
/// view is purely presentational — it reads the live `CanvasModel`'s active space
/// and calls back to the host (ContentView) to perform the actual switch / add (so
/// the redraw hook lives with the controller). Kept small + decomposed into small
/// `@ViewBuilder` helpers so the SwiftUI type-checker stays comfortable.
struct LayoutTabStrip: View {
    /// The live canvas state — observed for `activeSpace` / `activeLayout` (which tab
    /// reads as selected) and `orderedLayouts` (the tab list).
    let model: CanvasModel
    /// Switch to model space.
    let onSelectModel: () -> Void
    /// Switch to the named layout's sheet.
    let onSelectLayout: (String) -> Void
    /// Add (and switch to) a new layout.
    let onAddLayout: () -> Void
    /// Select the transient block-edit tab (BEDIT). A no-op beyond a repaint while a
    /// session is open — leaving the editor is via the BlockEditBar's Save&Close /
    /// Discard. Defaults to a no-op so existing call sites need not pass it.
    var onSelectBlockEdit: () -> Void = {}

    /// Whether the strip is shown at all (plan §3d): HIDE it entirely until there is a
    /// paper-space layout to switch to — with only the implicit "Model" space there is
    /// nothing to tab between, so a lone "Model" pill is noise. The strip also appears
    /// while a block-edit session is open so its transient BEDIT tab has a home.
    /// `LayoutTabStrip.shouldShow(layoutCount:isEditingBlock:)` is the pure predicate
    /// (unit-tested); this is its live read.
    private var isVisible: Bool {
        Self.shouldShow(layoutCount: model.orderedLayouts.count,
                        isEditingBlock: model.editingBlock != nil)
    }

    /// Pure visibility predicate (plan §3d): show the strip iff there is at least one
    /// paper-space layout to switch to, OR a block-edit session is active (so the
    /// transient BEDIT tab is reachable). With only model space (`layoutCount == 0`)
    /// and no session, the strip is hidden — there is nothing to tab between.
    static func shouldShow(layoutCount: Int, isEditingBlock: Bool) -> Bool {
        layoutCount > 0 || isEditingBlock
    }

    var body: some View {
        if isVisible {
            stripBody
        }
    }

    /// The actual tab strip (only built when `isVisible`).
    private var stripBody: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xxs) {
                modelTab
                ForEach(model.orderedLayouts) { layout in
                    layoutTab(named: layout.name)
                }
                addButton
                // BEDIT (STAGE 2): the transient block-edit tab — a visually-distinct
                // "✎ <BlockName>" pill shown ONLY while a session is open, appended after
                // the "+" so the persistent Model/Layout tabs (and the add button) keep
                // their fixed positions. Sourced from `model.editingBlock`; vanishes on
                // Save&Close/Discard.
                blockEditTab
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Size.barPadH)
            .padding(.vertical, DS.Space.xs)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model and layout tabs")
    }

    // MARK: - Tabs

    /// The always-present "Model" tab — selected when the active space is model AND no
    /// block-edit session is open. During a session NO Model/Layout tab reads active —
    /// the block-edit tab does — even though `enterBlockEditing` leaves `activeSpace`
    /// unchanged (it re-scopes the index, not the space). Gating on `editingBlock == nil`
    /// is what keeps exactly ONE tab active at a time.
    @ViewBuilder
    private var modelTab: some View {
        tabButton(
            title: "Model",
            systemImage: "square.dashed",
            isActive: model.editingBlock == nil && model.activeSpace == .model,
            action: onSelectModel
        )
        .accessibilityIdentifier("tab.model")
    }

    /// One tab per layout (keyed by name — the engine `Layout`'s stable id) —
    /// selected when it is the active paper layout AND no block-edit session is open
    /// (see `modelTab` for why the session gate matters). Takes the name (not the engine
    /// `Layout` value) so the helper never has to NAME the engine type, which is
    /// ambiguous in this file (SwiftUI's `Layout` protocol is also in scope, and the
    /// module-qualified form resolves to the `CADEngine` actor).
    @ViewBuilder
    private func layoutTab(named name: String) -> some View {
        let isActive = model.editingBlock == nil
            && model.activeSpace == .paper
            && (model.activeLayout?.caseInsensitiveCompare(name) == .orderedSame)
        tabButton(
            title: name,
            systemImage: "doc",
            isActive: isActive,
            action: { onSelectLayout(name) }
        )
        .accessibilityIdentifier("tab.layout.\(name)")
    }

    /// The transient BLOCK-EDIT tab (BEDIT, STAGE 2). Present ONLY while
    /// `model.editingBlock != nil`; it is the lone active tab during a session (its
    /// active-ness comes from the session itself, not `activeSpace`). For a nested
    /// stack it shows a breadcrumb of the open blocks (STAGE 3). Clicking it is a no-op
    /// (you are already on it) beyond a repaint — leaving is via the BlockEditBar's
    /// Save&Close / Discard.
    @ViewBuilder
    private var blockEditTab: some View {
        if let breadcrumb = blockEditBreadcrumb {
            tabButton(
                title: breadcrumb,
                systemImage: "pencil.and.outline",
                isActive: true,
                action: onSelectBlockEdit
            )
            .accessibilityIdentifier("tab.blockEdit")
        }
    }

    /// The block-edit tab's label: the nested-session breadcrumb when editing
    /// (e.g. "A ▸ B"), or `nil` when no session is open (the tab is then absent).
    /// Falls back to the single `editingBlock` name if the stack is unavailable.
    private var blockEditBreadcrumb: String? {
        let stack = model.editingBlockStack
        if !stack.isEmpty { return stack.joined(separator: " ▸ ") }
        return model.editingBlock
    }

    /// The trailing "+" that adds a new layout (and switches to it).
    @ViewBuilder
    private var addButton: some View {
        Button(action: onAddLayout) {
            Image(systemName: "plus")
                .font(DS.Font.rowLabel)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs)
        }
        .buttonStyle(.plain)
        .help("New layout")
        .accessibilityIdentifier("tab.add")
    }

    /// A single tab pill — shared chrome for the Model tab + each layout tab. The
    /// active tab reads with the accent tint, a `selectionFill` background, a
    /// `.semibold` title, and a 2pt accent underline (plan §3d); inactive tabs are
    /// secondary and underline-free. A plain button so the whole pill is the hit target.
    @ViewBuilder
    private func tabButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(DS.Font.rowLabel)
            .fontWeight(isActive ? .semibold : .regular)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.xs)
            .foregroundStyle(isActive ? DS.Palette.accent : .secondary)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.selection)
                    .fill(isActive ? DS.Palette.selectionFill : Color.clear)
            )
            .overlay(alignment: .bottom) {
                // The 2pt accent underline marks the active tab (AutoCAD/Chrome-style).
                if isActive {
                    Rectangle()
                        .fill(DS.Palette.accent)
                        .frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
