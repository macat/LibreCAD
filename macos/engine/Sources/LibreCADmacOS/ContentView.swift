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

    /// The single backing string for the MERGED smart command line (Wave-4 bottom-chrome
    /// redesign). It carries BOTH commands (`line`, `rect`) AND coordinates (`0,0`,
    /// `@10,0`, `5<90`) — the model's `interpretCommandLine` routes by shape. Cleared
    /// after each handled submit / tool activation; an error echoes via the model's
    /// `lastCommandError` and keeps the text so the user can fix it. (Replaces the two
    /// former backing strings `commandText` + `commandBarQuery`.)
    @State private var commandLineText: String = ""

    /// The single focus flag for the merged command line (Wave-4). ALL focus entry
    /// points drive THIS one flag: the canvas Space hook (`requestCommandFocus`), the
    /// `/` launcher keypress over the canvas, and the ⇧⌘L menu (`focusCommandLine`).
    /// Esc / a tool activation returns focus to the canvas so tool letters work again.
    /// (Replaces the two former flags `commandFieldFocused` + `commandBarFocused`.)
    @FocusState private var commandLineFocused: Bool

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

    /// Whether the COMMAND TRANSCRIPT scrollback pane is shown above the merged command
    /// line (AutoCAD-style command history). Persisted across launches; default OFF so
    /// the bottom chrome is unchanged for users who don't opt in. Toggled by the
    /// disclosure chevron next to the command line (and the View ▸ menu item).
    @AppStorage("commandTranscript.show") private var showCommandTranscript: Bool = false

    /// Whether the always-on "Current properties" bar (active layer + current pen
    /// color / type / width for NEW geometry) is shown under the toolbar. Default OFF —
    /// new geometry draws "By Layer" out of the box, so the bar is hidden until the user
    /// opts in via View ▸ Show Current Properties Bar (persisted across launches).
    @AppStorage("currentPropertiesBar.show") private var showCurrentPropertiesBar: Bool = false

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
        .onAppear {
            model.seedSnapSettingsFromAppSettings()   // new window: pick up Preferences snap/polar defaults (W2D/3B)
            model.commandBarMRU = Self.decodeMRU(commandBarMRURaw)
        }
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

    // MARK: - Command line row (transcript toggle + the merged command line)

    /// The merged command line preceded by a small disclosure chevron that toggles the
    /// command-transcript scrollback pane above it. Decomposed out of the bottom VStack so
    /// the SwiftUI type-checker never sees a monolithic chrome expression.
    @ViewBuilder
    private var commandLineRow: some View {
        HStack(spacing: 0) {
            transcriptToggle
            CommandLineBar(
                model: model,
                text: $commandLineText,
                focused: $commandLineFocused,
                pinned: pinnedToolsSet,
                activateTool: { kind in controllerBox.controller?.activateTool(kind) },
                placeImage: { chooseAndPlaceImage() },
                returnFocusToCanvas: { controllerBox.controller?.returnFocusToCanvas() },
                requestRedraw: { controllerBox.controller?.requestRedraw() }
            )
        }
    }

    /// The disclosure chevron at the leading edge of the command line that shows/hides the
    /// command-transcript scrollback. Chevron points UP to reveal the history, DOWN to
    /// collapse it. A plain `Button` (not a focusable field) so it never steals the
    /// command line's keyboard focus; it only flips the persisted `showCommandTranscript`.
    @ViewBuilder
    private var transcriptToggle: some View {
        Button {
            showCommandTranscript.toggle()
        } label: {
            Image(systemName: showCommandTranscript ? "chevron.down" : "chevron.up")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(showCommandTranscript ? "Hide command history" : "Show command history")
    }

    /// The canvas detail pane — the interactive canvas + HUD + toolbar + Inspector +
    /// palette wiring. Open/Save/Save As are NO LONGER here (DocumentGroup owns
    /// them); Export / Print remain as custom focused-scene-value actions.
    private var canvasDetail: some View {
        CADCanvasView(model: model, controllerBox: controllerBox)
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            // #6: drag a Parts Library symbol onto the CANVAS to import + place it at the
            // drop point. The drop `location` is in the canvas view's LOCAL coordinate
            // space (top-left origin, Y-down) — the SAME convention `Viewport.screenToWorld`
            // expects (the host `CADCanvasView` is `isFlipped`, so its point space is
            // top-left Y-down), so the location maps straight through. `PartLibraryDragItem`
            // is the panel's existing `Transferable` (W5); the import + insert run via the
            // engine `BlockLibrary.importItem` → `CanvasModel.insertBlock(named:at:)` path.
            .dropDestination(for: PartLibraryDragItem.self) { items, location in
                guard let item = items.first else { return false }
                dropPartLibraryItem(item, atScreenPoint: location)
                return true
            }
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
                // The "Current properties" bar (CLAYER + current pen) is OPT-IN — hidden by
                // default and toggled from View ▸ Show Current Properties Bar. An empty inset
                // content collapses to zero height, so when hidden it adds no chrome.
                if showCurrentPropertiesBar {
                    CurrentPropertiesBar(model: model, controllerBox: controllerBox)
                }
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
                        },
                        // #4c: the tab context-menu actions route to the P0-D `CanvasModel`
                        // layout wrappers (rename/delete/duplicate handle the active-tab
                        // fixup internally) + redraw. Page Setup now opens a REAL per-layout
                        // page editor (the sheet lives in LayoutTabStrip) and commits via
                        // `CanvasModel.setLayoutPage` (one undoable step; re-frames the sheet
                        // if it is the active tab).
                        onRenameLayout: { name, newName in
                            if model.renameLayout(name, to: newName) {
                                controllerBox.controller?.requestRedraw()
                            }
                        },
                        onDeleteLayout: { name in
                            if model.deleteLayout(name) {
                                controllerBox.controller?.requestRedraw()
                            }
                        },
                        onDuplicateLayout: { name in
                            if model.duplicateLayout(name) != nil {
                                controllerBox.controller?.requestRedraw()
                            }
                        },
                        onPageSetup: { name, page in
                            // The Page Setup sheet handed back a new engine `PageDescriptor`;
                            // commit it through the undoable `setLayoutPage` wrapper (a no-op
                            // if the layout is gone or the page is unchanged) + redraw.
                            if model.setLayoutPage(name, page) {
                                controllerBox.controller?.requestRedraw()
                            }
                        }
                    )
                    // The COMMAND TRANSCRIPT — an AutoCAD-style scrollback of every line
                    // submitted through the command line (echoed input, activated tools,
                    // resolved coordinates, errors), mounted IMMEDIATELY ABOVE the merged
                    // command line. Opt-in (default OFF) via the disclosure chevron next to
                    // the command line / the View menu; the buffer is capped on the model
                    // side. Passive + read-only — it never steals the command line's focus.
                    if showCommandTranscript {
                        CommandTranscriptView(model: model)
                    }
                    // Wave-4 bottom-chrome redesign: the MERGED smart command line — ONE
                    // full-width row that replaces BOTH the former U1 coordinate line and
                    // the `CommandBar` tool launcher. It handles commands AND coordinates
                    // (the model's `interpretCommandLine` routes by shape), shows the
                    // active-tool prompt + clickable bracket keyword chips, an autocomplete
                    // dropdown (opens UPWARD over the canvas) while typing a command, and
                    // recent-command chips that LOAD (not execute) into the field. Image
                    // placement routes through the View-layer file-picker (`.image`'s modal
                    // never reaches the model/tool). A leading disclosure chevron toggles
                    // the command-transcript scrollback above it.
                    commandLineRow
                    // The status bar is the LITERAL bottom row (AutoCAD layout): read-only
                    // telemetry (coords / zoom / OSNAP / POLAR / DYN chips) under the
                    // command line. Moved here in Wave-4; the StatusBar HStack is intact.
                    StatusBar(
                        model: model,
                        requestRedraw: { controllerBox.controller?.requestRedraw() }
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
            // Lane S: the Inspector toggle (#03 — View ▸ Show Inspector, ⌃⌘I) + the
            // Layout menu's New / Delete / Duplicate active-layout actions (#00), grouped
            // into one modifier so the `canvasDetail` chain stays under the Swift
            // type-checker's expression-complexity limit (gotcha #2). The Delete/Duplicate
            // closures are `nil` in model space (no active layout) — which disables the
            // matching Layout-menu items; New Layout is always available on a focused canvas.
            .modifier(shellMenuHandlers)
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
            // Match Properties (#2): PICK-UP (load the brush from the single selected
            // entity) + APPLY (paint the brush onto the whole selection, then redraw),
            // grouped into one `ViewModifier` so `canvasDetail`'s modifier chain stays
            // under the Swift type-checker's complexity budget (gotcha #2). Both consume
            // the P0-D `CanvasModel` ops (no model API added here).
            .modifier(matchPropHandlers)
            // Let the canvas hand focus to the command line on Space (D1). The
            // controller calls this closure from `handleKey` when Space is pressed
            // and a tool is active, so a typed length goes to the field, not a tool.
            .onAppear {
                // Canvas Space hook (D1): the canvas controller hands focus to the merged
                // command line so a typed length/coordinate goes to the field, not a tool.
                controllerBox.controller?.requestCommandFocus = { commandLineFocused = true }
                // U5 context-menu hooks: "Properties" reveals + focuses the Inspector;
                // "Document Settings…" raises the per-document settings sheet.
                controllerBox.controller?.requestShowInspector = { showInspector = true }
                controllerBox.controller?.requestDocumentSettings = { showSettings = true }
                // WAVE BW (Ask #1): the canvas context menu's "Create Block from
                // Selection…" verb raises the View-layer name sheet (gated on a
                // selection inside `raiseBlockNamePrompt`).
                controllerBox.controller?.requestCreateBlockFromSelection = { raiseBlockNamePrompt() }
            }
            // View ▸ Show Command Line (⇧⌘L) focuses the merged command line from the menu.
            .focusedSceneValue(\.focusCommandLine) { commandLineFocused = true }
            // The `/` launcher keystroke focuses the merged command line (AutoCAD's
            // command-line convention). `/` is not a tool letter (the canvas never
            // consumes it), so this is non-disruptive: the canvas's bare-letter shortcuts
            // keep working unchanged, and clicking the field focuses it too. SwiftUI
            // delivers the press here only when the canvas is NOT capturing the key.
            .onKeyPress("/") {
                commandLineFocused = true
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

    /// The Match-Properties focused-scene-value handlers (#2 — Pick Up / Apply), pulled
    /// into one `ViewModifier` so `canvasDetail`'s modifier chain stays under the Swift
    /// type-checker's complexity budget (gotcha #2). Pick Up loads the property brush
    /// from the single selected entity; Apply paints it onto the whole selection (one
    /// undoable group) and redraws on a change.
    private var matchPropHandlers: some ViewModifier {
        MatchPropHandlersModifier(
            pickUp: { _ = model.loadPaintBrushFromSelection() },
            apply: {
                if model.applyPaintBrushToSelection() { controllerBox.controller?.requestRedraw() }
            }
        )
    }

    /// Lane S app-shell focused-scene-value handlers — the Inspector toggle (#03) + the
    /// Layout menu's New / Delete / Duplicate active-layout verbs (#00), grouped into one
    /// `ViewModifier` so `canvasDetail`'s modifier chain stays under the Swift
    /// type-checker's complexity budget (gotcha #2).
    ///
    /// • Inspector toggle: the same `showInspector.toggle()` the toolbar button + the ⌘K
    ///   palette fire — wired to View ▸ Show Inspector (⌃⌘I).
    /// • New Layout: always available on a focused canvas (`CanvasModel.newLayout` adds a
    ///   sheet + activates it; one undoable engine op).
    /// • Delete / Duplicate ACTIVE layout: published only when a layout TAB is active
    ///   (paper space); `nil` in model space DISABLES the matching menu items (there is no
    ///   active layout to act on). Both operate on `model.activeLayout` via the existing
    ///   undoable `CanvasModel` wrappers and re-home the active tab. Rename / Page Setup
    ///   are DEFERRED to the tab-strip sheet (see the report) — those modals live in the
    ///   non-owned `LayoutTabStrip`, so the menu surfaces the non-sheet verbs here.
    private var shellMenuHandlers: some ViewModifier {
        let active = model.activeLayout   // the active sheet's name in paper space, else nil
        return ShellMenuHandlersModifier(
            toggleInspector: { showInspector.toggle() },
            toggleCurrentPropertiesBar: { showCurrentPropertiesBar.toggle() },
            newLayout: { _ = model.newLayout() },
            deleteActiveLayout: active.map { name in { _ = model.deleteLayout(name) } },
            duplicateActiveLayout: active.map { name in { _ = model.duplicateLayout(name) } }
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
        // #4a: the old "New drawing (mm)" canvas chip is GONE — W2 relocated the unit to
        // the persistent status bar (StatusBar.docStatusSegment) and the file name lives
        // in the window title bar, so a fresh drawing shows NO top-leading chip. Only a
        // non-empty drawing surfaces a transient load count here (the chip's documented
        // load/export status role).
        let n = model.entityCount
        status = n == 0 ? "" : "\(n) entities"
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
    ///
    /// In the Draw group (#1), a pinned tool that has a registered FLYOUT
    /// (`ToolCatalog.drawFlyout(for:)` — Line / Circle / Arc / Rectangle) renders as a
    /// hold-to-open flyout instead of a plain button (click = its default tool/mode,
    /// hold = the variant menu). All other tools stay plain buttons.
    @ViewBuilder
    private func groupSection(_ group: ToolGroup) -> some View {
        ForEach(pinnedTools(in: group), id: \.self) { kind in
            pinnedButton(kind, in: group)
        }
        groupOverflowMenu(group)
    }

    /// Renders one pinned toolbar entry: a flyout when `kind` has one registered (Draw
    /// Line/Circle/Arc/Rectangle/Spline or Modify Divide/Scale), else a plain tool
    /// button. Split out so `groupSection`'s `ForEach` body stays a single small
    /// expression for the type-checker.
    @ViewBuilder
    private func pinnedButton(_ kind: ToolKind, in group: ToolGroup) -> some View {
        if let flyout = ToolCatalog.flyout(for: kind) {
            drawFlyoutButton(flyout)
        } else {
            toolButton(kind)
        }
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
    /// right, next to where the inspector opens. Also hosts the Match-Properties
    /// PICK-UP button (#2 — `eyedropper`): clicking it loads the property brush from the
    /// single selected entity (then ⌘⇧V / the menu applies it to the next selection).
    @ToolbarContentBuilder
    private var inspectorToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                _ = model.loadPaintBrushFromSelection()
            } label: {
                Label("Match Properties", systemImage: "eyedropper")
            }
            .help("Match Properties — pick up the selected object's properties (⌘⇧C), "
                  + "then apply to a new selection (⌘⇧V)")
        }
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
            // #42 — match the active-TAB badge: the sanctioned selection radius + the ONE
            // selection fill (`DS.Palette.selectionFill`, accent @ 0.15), not the heavier
            // ad-hoc `.tint.opacity(0.25)` literal. One selection look across the chrome.
            RoundedRectangle(cornerRadius: DS.Radius.selection).fill(DS.Palette.selectionFill)
        }
    }

    // MARK: - Draw flyouts (#1)

    /// A Draw FLYOUT button: `Menu(content:label:primaryAction:)`, so a plain CLICK runs
    /// the flyout's default (`primaryAction` → activate the primary kind) and a HOLD opens
    /// the variant menu. The label shows the primary glyph, plus — when a variant is the
    /// currently-active configuration — the active variant's title so the toolbar reflects
    /// the live mode/kind. Reuses the same `activeBadge` highlight as a plain button.
    @ViewBuilder
    private func drawFlyoutButton(_ flyout: ToolCatalog.Flyout) -> some View {
        let meta = ToolCatalog.metadata(for: flyout.primary)
        Menu {
            ForEach(flyout.variants, id: \.self) { variant in
                flyoutVariantRow(variant)
            }
        } label: {
            Label(flyoutLabelTitle(flyout), systemImage: meta.symbol)
        } primaryAction: {
            activate(flyout.primary)
        }
        .menuIndicator(.visible)
        .help("\(flyout.primary.title) — click to draw; hold for variants")
        .background(activeBadge(flyout.primary))
    }

    /// One row of a flyout's hold-menu: activates the variant (a separate KIND, or the
    /// base kind RE-MINTED in a construction MODE) and shows a checkmark when it is the
    /// active configuration.
    @ViewBuilder
    private func flyoutVariantRow(_ variant: ToolCatalog.FlyoutVariant) -> some View {
        Button {
            activateVariant(variant)
        } label: {
            Label(ToolCatalog.variantTitle(variant),
                  systemImage: isActiveVariant(variant) ? "checkmark"
                                                        : ToolCatalog.variantSymbol(variant))
        }
    }

    /// The flyout button's title: the active variant's name when a variant is the live
    /// configuration (e.g. "Circle · 2 Points", "Construction Line"), else the primary
    /// kind's title. Lets the toolbar reflect the held-then-picked mode/kind.
    private func flyoutLabelTitle(_ flyout: ToolCatalog.Flyout) -> String {
        if let active = flyout.variants.first(where: { isActiveVariant($0) }) {
            switch active {
            case .kind(let k):     return k.title
            case .circleMode, .arcMode, .splineMode, .divideStyle, .scaleMode:
                return "\(flyout.primary.title) · \(ToolCatalog.variantTitle(active))"
            }
        }
        return flyout.primary.title
    }

    /// Activates one flyout variant. A `.kind` variant routes through the normal
    /// `activate(_:)` (so Image/Create-Block special-cases still hold); a MODE variant
    /// sets the matching model config FIRST, then activates the base kind so
    /// `applyToolConfig` re-mints/re-applies the tool in that mode — exactly the
    /// ToolOptionsBar path (the Wave-3B/3F plumbing on `CanvasModel`).
    private func activateVariant(_ variant: ToolCatalog.FlyoutVariant) {
        switch variant {
        case .kind(let k):
            activate(k)
        case .circleMode(let mode):
            model.circleConstructionMode = mode
            controllerBox.controller?.activateTool(.circle)
        case .arcMode(let mode):
            model.arcMode = mode
            controllerBox.controller?.activateTool(.arc)
        case .splineMode(let mode):
            model.splineMode = mode
            controllerBox.controller?.activateTool(.spline)
        case .divideStyle(let index):
            model.divideModeStyle = index
            controllerBox.controller?.activateTool(.divide)
        case .scaleMode(let mode):
            model.scaleMode = mode
            controllerBox.controller?.activateTool(.scale)
        }
    }

    /// Whether `variant` is the CURRENT live configuration (drives the hold-menu
    /// checkmark + the button's active-variant title). A `.kind` variant is active when
    /// it is the active tool kind; a mode variant is active when its base kind is active
    /// AND the model's construction/creation mode matches.
    private func isActiveVariant(_ variant: ToolCatalog.FlyoutVariant) -> Bool {
        switch variant {
        case .kind(let k):
            return model.activeToolKind == k
        case .circleMode(let mode):
            return model.activeToolKind == .circle && model.circleConstructionMode == mode
        case .arcMode(let mode):
            return model.activeToolKind == .arc && model.arcMode == mode
        case .splineMode(let mode):
            return model.activeToolKind == .spline && model.splineMode == mode
        case .divideStyle(let index):
            return model.activeToolKind == .divide && model.divideModeStyle == index
        case .scaleMode(let mode):
            return model.activeToolKind == .scale && model.scaleMode == mode
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
            documentSettings: { showSettings = true },
            // Curated parity additions (#01): fire the SAME closures/selectors the menus
            // fire. The canvas-action verbs (Import/Merge, Dim Style Manager, Save/Restore
            // View) dispatch through the responder chain to the focused canvas — exactly
            // like their menu items in LibreCADApp. Insert/Save Block reuse the View-layer
            // functions the Blocks menu wires; New Layout calls the model op directly.
            importMergeDXF: { sendDocumentAction(Selector(("importMergeDXFAction:"))) },
            dimensionStyleManager: { sendDocumentAction(Selector(("dimStyleManagerAction:"))) },
            saveNamedView: { sendDocumentAction(Selector(("saveNamedViewAction:"))) },
            restoreNamedView: { sendDocumentAction(Selector(("restoreNamedViewAction:"))) },
            insertBlockFromFile: { insertBlockFromFile() },
            saveBlockToFile: { if let name = saveBlockTargetName { saveBlockToFile(named: name) } },
            newLayout: { _ = model.newLayout() },
            // Wire-wave 2 — constraints + Insert-Field fire the SAME responder-chain
            // selectors the Constrain / Insert menus fire (so ⌘K == the menu action). The
            // selector is chosen from the kind here; the focused canvas's `@objc` handler
            // (LibreCADApp) forwards to the CanvasModel constraint/field verb.
            applyGeometricConstraint: { kind in
                sendDocumentAction(Selector((Self.geometricConstraintSelector(kind))))
            },
            applyDimensionalConstraint: { kind in
                sendDocumentAction(Selector((Self.dimensionalConstraintSelector(kind))))
            },
            insertField: { token in
                sendDocumentAction(Selector((Self.fieldInsertSelector(token))))
            }
        ))
    }

    /// The responder-chain selector name for a GEOMETRIC constraint kind (matches the
    /// Constrain-menu `@objc` handlers in LibreCADApp). The two solver-unsupported families
    /// route to a no-op-ish handler that posts a status note via the same path.
    private static func geometricConstraintSelector(_ kind: GeometricConstraintKind) -> String {
        switch kind {
        case .coincident:    return "applyCoincidentConstraintAction:"
        case .horizontal:    return "applyHorizontalConstraintAction:"
        case .vertical:      return "applyVerticalConstraintAction:"
        case .parallel:      return "applyParallelConstraintAction:"
        case .perpendicular: return "applyPerpendicularConstraintAction:"
        case .fix:           return "applyFixConstraintAction:"
        // Only the MVP kinds are surfaced in the palette; map the rest to Fix's handler
        // defensively (never reached — no palette entry builds them).
        case .collinear, .tangent, .equal, .concentric, .symmetric:
            return "applyFixConstraintAction:"
        }
    }

    /// The responder-chain selector name for a DIMENSIONAL constraint kind.
    private static func dimensionalConstraintSelector(_ kind: DimensionalConstraintKind) -> String {
        switch kind {
        case .distance: return "applyDistanceConstraintAction:"
        case .radius:   return "applyRadiusConstraintAction:"
        case .horizontalDistance, .verticalDistance, .diameter, .angle:
            return "applyDistanceConstraintAction:"   // not surfaced; defensive default
        }
    }

    /// The responder-chain selector name for an Insert-Field token (matches the Insert ▸
    /// Field `@objc` handlers in LibreCADApp).
    private static func fieldInsertSelector(_ token: FieldToken) -> String {
        switch token {
        case .date:           return "insertDateFieldAction:"
        case .layoutName:     return "insertLayoutNameFieldAction:"
        case .fileName:       return "insertFileNameFieldAction:"
        case .objectProperty: return "insertDateFieldAction:"   // not surfaced; defensive default
        }
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

    // MARK: - Command / coordinate input line (Wave-4 merged)
    //
    // The bottom command/coordinate line is now the merged `CommandLineBar` (see
    // `CommandLineBar.swift`), mounted in the bottom VStack above the status bar. It
    // owns its own routing/prompt/dropdown; ContentView provides the single backing
    // string (`commandLineText`), the single focus flag (`commandLineFocused`), and the
    // controller closures (activate / placeImage / returnFocusToCanvas / requestRedraw).
    // The former U1 `commandBar` property + its `commandPlaceholder`/`submitCommand`/
    // `returnFocusToCanvas` helpers were retired into that view.

    // MARK: - Export (PDF / PNG / SVG) and Print (⌘P)
    //
    // These STAY custom (not the document type). DocumentGroup owns only DXF
    // Open/Save/Save As/autosave; export renders the live drawing to other formats
    // and Print drives the system print dialog.

    /// Export… for one `format`: present an `NSSavePanel` (carrying a small SwiftUI
    /// ACCESSORY — a format picker spanning every supported format incl. the raster
    /// JPEG/BMP/TIFF, a DPI field for the raster pipeline, and a JPEG-quality slider),
    /// then render the current drawing through the shared export facade
    /// (`DrawingExporter.export(…, dpi:, jpegQuality:)`). The accessory's live format
    /// drives the panel's allowed type + name extension, so the final URL always matches
    /// the chosen format. `format` only SEEDS the picker — the default (PNG @ 150 DPI) is
    /// unchanged when the accessory is left untouched. Status/errors land in the HUD —
    /// never a crash. The `NSSavePanel`/accessory live in this View layer only.
    @MainActor
    private func exportDrawing(_ format: ExportFormat) async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Drawing"
        panel.prompt = "Export"

        let options = ExportOptionsState(format: format)
        applyExportFormat(format, to: panel)              // seed allowed type + name ext.
        panel.accessoryView = exportAccessoryView(options: options, panel: panel)

        guard panel.runModal() == .OK, let url = panel.url else {
            status = "Export cancelled"
            return
        }
        // The accessory keeps the panel's allowed type + name extension in sync with the
        // chosen format, so `url` already carries it; re-derive the extension from the
        // chosen format anyway (belt-and-suspenders) so the written file's extension
        // always matches what is encoded. Security-scoped access is requested on the
        // panel-GRANTED `url` (same directory as `finalURL`).
        let chosen = options.format
        let finalURL = url.deletingPathExtension()
            .appendingPathExtension(chosen.fileExtension)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // EXPORT #6 (Wave 1 completion): scope the export to the ACTIVE drawing space
            // so a default Export/Print follows the on-screen Model/Layout tab — exactly
            // like the live canvas — instead of always dumping every space (`.all`). The
            // `exportSpace(forActiveSpace:layout:)` helper maps `CanvasModel.activeSpace` /
            // `.activeLayout` to the exporter's `ExportSpace` (model → `.model`; a layout
            // tab → `.paper(layoutName:)`).
            let count = try DrawingExporter.export(model.drawing, to: finalURL,
                                                   format: chosen,
                                                   dpi: options.effectiveDPI,
                                                   jpegQuality: options.jpegQuality,
                                                   space: DrawingExporter.exportSpace(
                                                       forActiveSpace: model.activeSpace,
                                                       layout: model.activeLayout))
            status = "Exported \(finalURL.lastPathComponent) — \(count) elements"
            NSLog("CADCanvas: exported \(count) elements to \(finalURL.lastPathComponent)")
        } catch {
            status = "Export failed: \(error.localizedDescription)"
            NSLog("CADCanvas: export failed: \(error)")
        }
    }

    /// Syncs an `NSSavePanel` to one export `format`: its allowed content type plus the
    /// name field's extension (preserving the base name the user has typed). Called when
    /// the panel is first built and whenever the accessory's format picker changes, so the
    /// panel + the eventual URL always carry the chosen format's extension.
    @MainActor
    private func applyExportFormat(_ format: ExportFormat, to panel: NSSavePanel) {
        panel.allowedContentTypes = [format.utType]
        let current = panel.nameFieldStringValue
        let base = current.isEmpty
            ? exportBaseName
            : (current as NSString).deletingPathExtension
        let stem = base.isEmpty ? exportBaseName : base
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
    }

    /// Builds the `NSSavePanel` ACCESSORY view (an `NSHostingView` wrapping the SwiftUI
    /// `ExportOptionsAccessory`). The accessory binds to `options`; its format change
    /// closure re-syncs the host `panel` (allowed type + extension). The hosting view is
    /// auto-sized to its SwiftUI content so the panel lays it out correctly.
    @MainActor
    private func exportAccessoryView(options: ExportOptionsState,
                                     panel: NSSavePanel) -> NSView {
        let accessory = ExportOptionsAccessory(options: options) { [weak panel] newFormat in
            guard let panel else { return }
            applyExportFormat(newFormat, to: panel)
        }
        let host = NSHostingView(rootView: accessory)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.setFrameSize(host.fittingSize)
        return host
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
    ///
    /// PRINT #6 (export-parity print half): scope the print to the ACTIVE drawing
    /// space so a plain Print follows the on-screen Model/Layout tab — exactly like
    /// the live canvas + Export now do — instead of always plotting every space
    /// (`.all`, model + every layout unioned). The same
    /// `DrawingExporter.exportSpace(forActiveSpace:layout:)` helper used by Export
    /// maps `CanvasModel.activeSpace` / `.activeLayout` to the printer's `ExportSpace`
    /// (model → `.model`; a layout tab → `.paper(layoutName:)`). The dedicated
    /// per-layout "Print Layout…" path (`printActiveLayout`) is untouched — it already
    /// targets a specific sheet.
    @MainActor
    private func printDrawing() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !DrawingPrinter.print(model.drawing, in: window,
                                 space: DrawingExporter.exportSpace(
                                     forActiveSpace: model.activeSpace,
                                     layout: model.activeLayout)) {
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

    /// #6: import a dragged Parts Library symbol and place ONE insert at the drop's WORLD
    /// point. `screenPoint` is the SwiftUI drop `location` in the canvas view's local
    /// space (top-left origin, Y-down) — the same convention `Viewport.screenToWorld`
    /// expects (the host is `isFlipped`), so it maps straight through to world. Mirrors the
    /// Parts panel's drag-to-place `insert(_:)`: import the file (which drops a placeholder
    /// insert at the origin), remove that placeholder, then re-insert at the world point
    /// via the model's selectable/snappable `insertBlock` path. Collision-safe (the engine
    /// de-dups a clashing block name). Security-scoped read; errors land in the HUD chip.
    @MainActor
    private func dropPartLibraryItem(_ dragItem: PartLibraryDragItem, atScreenPoint screenPoint: CGPoint) {
        let world = model.viewport.screenToWorld(screenPoint)
        let url = URL(fileURLWithPath: dragItem.filePath)
        let item = BlockLibraryItem(name: dragItem.name, url: url)
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockLibrary.importItem(item, into: model.drawing) else {
                    status = "“\(dragItem.name)” has no importable geometry"
                    return
                }
                // The import added the block + a placeholder insert at the origin; drop it
                // and re-place at the drop point via the model's insert path (selectable/
                // snappable, index-synced, undoable).
                model.drawing.remove(result.insertID)
                model.quadtree.remove(result.insertID)
                _ = model.insertBlock(named: result.blockName, at: world)
                model.modelDirty = true
                model.modelVersion &+= 1
                controllerBox.controller?.requestRedraw()
                status = "Inserted “\(result.blockName)”"
            } catch {
                status = "Drop import failed: \(error.localizedDescription)"
                NSLog("CADCanvas: parts-library drop import failed: \(error)")
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
        .text, .linearDim, .leader, .multileader,
    ]

    // MARK: Draw flyouts (#1 — click = default tool, hold = variants)

    /// One VARIANT inside a toolbar flyout. A variant is EITHER:
    ///   • `.kind` — a SEPARATE `ToolKind` (e.g. Ray / Construction Line / Polygon),
    ///     activated directly via the toolbar's `activate(_:)` routing; OR
    ///   • a CONSTRUCTION / CREATION MODE of the SAME kind (Circle / Arc / Spline /
    ///     Divide / Scale), which is NOT its own `ToolKind`. These set the matching
    ///     model config (`circleConstructionMode` / `arcMode` / `splineMode` /
    ///     `divideModeStyle` / `scaleMode`) FIRST, then activate the base kind so
    ///     `applyToolConfig` re-mints/re-applies the tool in that mode (the
    ///     ToolOptionsBar path — Wave-3B/3F plumbing).
    ///
    /// No new `ToolKind` / `EntityKind` / mode is introduced — every case resolves to
    /// an EXISTING kind or an existing construction/creation mode (verified against
    /// `CircleConstructionMode` / `ArcCreationMode` / `SplineMode` /
    /// `ScaleTool.ScaleMode` and the `divideModeStyle` index, which have exactly the
    /// cases listed).
    enum FlyoutVariant: Hashable {
        case kind(ToolKind)
        case circleMode(CircleConstructionMode)
        case arcMode(ArcCreationMode)
        /// Spline ▸ Fit points / Control points (`CanvasModel.splineMode`).
        case splineMode(SplineMode)
        /// Divide ▸ By number / By length — the model's `divideModeStyle` INDEX
        /// (`0` = count, `1` = length; the engine `DivideMode` carries an associated
        /// value so it can't be a `Hashable` tag, exactly as the options bar splits it).
        case divideStyle(Int)
        /// Scale ▸ Uniform (`.factor`) / Non-uniform X/Y (`.nonUniform`)
        /// (`CanvasModel.scaleMode`). `.reference` is options-bar-only — the flyout
        /// offers just the two headline modes the brief lists.
        case scaleMode(ScaleTool.ScaleMode)
    }

    /// A toolbar FLYOUT: a primary tool button (click = activate `primary`) that,
    /// when held, opens a menu of `variants`. Replaces a plain pinned button so the
    /// related tools/modes for a tool family are one hold away (#1).
    struct Flyout: Identifiable {
        /// The kind the flyout's button activates on a plain click (and whose glyph it
        /// shows). Also the `id` so the toolbar `ForEach`/lookup is stable.
        let primary: ToolKind
        /// The hold-menu variants, in display order.
        let variants: [FlyoutVariant]
        var id: ToolKind { primary }
    }

    /// The DRAW-group flyouts (#1), in toolbar order. ONLY the pinned Draw tools that
    /// have meaningful variants/modes are flyouts; every other Draw tool stays a plain
    /// button (and the whole group stays reachable via the `▾` overflow menu).
    ///   • Line ▸ {Construction Line (XLine), Ray, Line Construction}  — separate KINDS.
    ///   • Rectangle ▸ {Polygon}                    — a separate KIND.
    ///   • Circle ▸ {Center+Radius, 2 Points, 3 Points, TTR, TTT, From Arc} — modes.
    ///   • Arc ▸ {Center/Start/End, 3 Points, Tangential} — creation MODES.
    ///   • Spline ▸ {Fit points (default), Control points} — `SplineMode` (Wave-3B).
    /// (Rectangle has no rounded/chamfer KIND in this build, so only the Polygon kind is
    /// offered there — every flyout case resolves to an existing kind/mode.)
    static let drawFlyouts: [Flyout] = [
        Flyout(primary: .line, variants: [.kind(.xline), .kind(.ray),
            // Wire-wave-4: the LINE CONSTRUCTION tool (a separate kind; its construction
            // METHOD is chosen in the Tool Options bar after activation).
            .kind(.lineConstruction)]),
        Flyout(primary: .circle, variants: [
            .circleMode(.centerRadius), .circleMode(.twoPoint), .circleMode(.threePoint),
            // Wire-wave-4: TTR (tan-tan-radius), TTT (tan-tan-tan), and From-Arc.
            .circleMode(.tanTanRadius), .circleMode(.tanTanTan), .circleMode(.fromArc),
        ]),
        Flyout(primary: .arc, variants: [
            .arcMode(.centerStartEnd), .arcMode(.threePoint), .arcMode(.tangential),
        ]),
        Flyout(primary: .rectangle, variants: [.kind(.polygon)]),
        Flyout(primary: .spline, variants: [
            .splineMode(.fit), .splineMode(.controlPoints),
        ]),
    ]

    /// The MODIFY-group flyouts (Wave-3C), in toolbar order. Surface the Wave-3B/3F
    /// parameterized MODES of Divide and Scale as hold-menu variants (the click still
    /// activates the tool in its current/default mode):
    ///   • Divide ▸ {By number (count, default), By length} — the `divideModeStyle`
    ///     INDEX (0 / 1; the engine `DivideMode` carries an associated value).
    ///   • Scale ▸ {Uniform (default), Non-uniform X/Y} — `ScaleTool.ScaleMode`
    ///     (`.factor` / `.nonUniform`; `.reference` stays options-bar-only).
    static let modifyFlyouts: [Flyout] = [
        Flyout(primary: .divide, variants: [
            .divideStyle(0), .divideStyle(1),
        ]),
        Flyout(primary: .scale, variants: [
            .scaleMode(.factor), .scaleMode(.nonUniform),
        ]),
    ]

    /// Every toolbar flyout (Draw then Modify), in toolbar order. The single source of
    /// truth the `flyout(for:)` lookup and the no-orphan test share.
    static var allFlyouts: [Flyout] { drawFlyouts + modifyFlyouts }

    /// The flyout (if any) whose PRIMARY button is `kind` — so `groupSection` can render
    /// a flyout in place of a plain button for any flyout primary (Draw or Modify).
    static func flyout(for kind: ToolKind) -> Flyout? {
        allFlyouts.first { $0.primary == kind }
    }

    /// A short display title for one flyout variant (the hold-menu row label / the
    /// active-variant badge text). Mode variants read as their construction-mode name;
    /// kind variants read as the kind's UI title.
    static func variantTitle(_ variant: FlyoutVariant) -> String {
        switch variant {
        case .kind(let k):           return k.title
        case .circleMode(let m):     return circleModeTitle(m)
        case .arcMode(let m):        return arcModeTitle(m)
        case .splineMode(let m):     return splineModeTitle(m)
        case .divideStyle(let i):    return divideStyleTitle(i)
        case .scaleMode(let m):      return scaleModeTitle(m)
        }
    }

    /// The SF Symbol for one flyout variant's hold-menu row.
    static func variantSymbol(_ variant: FlyoutVariant) -> String {
        switch variant {
        case .kind(let k):       return metadata(for: k).symbol
        case .circleMode:        return "circle"
        case .arcMode:           return "point.topleft.down.to.point.bottomright.curvepath"
        case .splineMode:        return "scribble.variable"
        case .divideStyle(let i): return i == 1 ? "ruler" : "number"
        case .scaleMode(let m):  return m == .nonUniform
                                        ? "arrow.up.left.and.arrow.down.right"
                                        : "arrow.up.left.and.down.right.magnifyingglass"
        }
    }

    /// Display names for the Circle construction modes (mirrors the ToolOptionsBar
    /// picker labels so the flyout and the options bar read identically).
    static func circleModeTitle(_ mode: CircleConstructionMode) -> String {
        switch mode {
        case .centerRadius: return "Center, Radius"
        case .twoPoint:     return "2 Points"
        case .threePoint:   return "3 Points"
        // W5-5A construction modes — titles only (UNWIRED: not yet offered in the
        // options-bar picker / draw flyout; the W4 wire-wave surfaces them). Listed
        // here so this exhaustive no-default switch keeps compiling.
        case .tanTanRadius: return "Tan, Tan, Radius"
        case .tanTanTan:    return "Tan, Tan, Tan"
        case .fromArc:      return "From Arc"
        }
    }

    /// Display names for the Arc construction modes (mirrors the ToolOptionsBar picker).
    static func arcModeTitle(_ mode: ArcCreationMode) -> String {
        switch mode {
        case .centerStartEnd: return "Center, Start, End"
        case .threePoint:     return "3 Points"
        case .tangential:     return "Tangential"
        }
    }

    /// Display names for the Spline creation modes (`SplineMode`).
    static func splineModeTitle(_ mode: SplineMode) -> String {
        switch mode {
        case .fit:           return "Fit Points"
        case .controlPoints: return "Control Points"
        }
    }

    /// Display names for the Divide MODE styles, keyed by the model's `divideModeStyle`
    /// index (`0` = by number / count, `1` = by length / measure).
    static func divideStyleTitle(_ index: Int) -> String {
        index == 1 ? "By Length" : "By Number"
    }

    /// Display names for the Scale modes offered in the flyout (`.factor` reads as the
    /// headline "Uniform" workflow; `.nonUniform` as "Non-uniform X/Y").
    static func scaleModeTitle(_ mode: ScaleTool.ScaleMode) -> String {
        switch mode {
        case .factor:     return "Uniform"
        case .reference:  return "By Reference"
        case .nonUniform: return "Non-uniform X/Y"
        }
    }

    // MARK: Group rosters (canonical order)

    private static let drawTools: [ToolKind] = [
        .line, .circle, .arc, .rectangle, .polyline, .point,
        .ellipse, .polygon, .spline, .hatch, .image,
        .xline, .ray, .insert, .viewport,
        // Wire-wave-4: WIPEOUT masking polygon (a normal draw tool — makeTool mints it).
        .wipeout,
        // Parity-program W: MULTILINE (a normal draw tool — makeTool mints it). Grouped
        // here so it is not orphaned + reachable via the Tools menu; the primary-toolbar
        // pin / canvas chord / options-bar config are a later wire-wave.
        .mline,
        // Wire-wave-1: TABLE insert (a normal draw tool — makeTool mints a TableTool).
        // Click one point to drop a default 3×3 grid; the app adds it to
        // `drawing.tables` via the undoable model op (it is not an EntityKind).
        .table,
    ]

    private static let modifyTools: [ToolKind] = [
        .move, .copy, .offset, .rotate, .scale, .mirror,
        .array, .arrayPath, .divide, .explode, .stretch, .lengthen, .break,
        .trim, .extend, .fillet, .chamfer,
        .polylineEdit, .join, .explodeText, .align,
        .createBlock, .explodeInsert,
        // Wire-wave-4: LINE CONSTRUCTION (perpendicular / parallel / bisector / tangent).
        .lineConstruction,
    ]

    private static let annotateTools: [ToolKind] = [
        .text,
        .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim,
        .ordinateDim, .arcLengthDim, .angular3pDim,
        .leader, .multileader, .baselineDim, .continueDim,
        .measureDistance, .measureAngle, .measureArea, .measureLength,
        // Wire-wave-4: REVISION CLOUD markup (a normal draw/markup tool).
        .revcloud,
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
        case .multileader: return .init(symbol: "text.bubble.fill",
                                        help: "Multileader (MLEADER) callout (⌥M)", shortcut: "⌥M")
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
        // Parity-program W2: Revision Cloud markup (UNWIRED — coupled no-default arm
        // only; no toolbar group / pinned / activate wiring, that's the W4 wire-wave).
        case .revcloud:    return .init(symbol: "cloud", help: "Revision cloud", shortcut: nil)
        // Parity-program W2: Line Construction markup (UNWIRED — coupled no-default
        // arm only; no toolbar group / pinned / activate wiring, that's a later wave).
        case .lineConstruction: return .init(symbol: "line.diagonal",
                                             help: "Line construction (perpendicular / parallel / bisector / tangent)",
                                             shortcut: nil)
        // Parity-program W3: Wipeout masking polygon (coupled no-default arm only;
        // no toolbar group / pinned / activate wiring beyond what compiles).
        case .wipeout:     return .init(symbol: "rectangle.slash",
                                        help: "Wipeout (mask region in the background color)",
                                        shortcut: nil)
        // Parity-program W: Multiline draw tool (UNWIRED — coupled no-default arm only;
        // no toolbar group / pinned / canvas chord / activate wiring, that's a later
        // wire-wave). Surfaced without a shortcut hint until the chord is assigned.
        case .mline:       return .init(symbol: "lines.measurement.horizontal",
                                        help: "Draw multiline (parallel mitered element lines)",
                                        shortcut: nil)
        // Wire-wave-1: Table insert (click one point to place a default 3×3 grid). No
        // canvas chord assigned yet, so the toolbar/menu/⌘K surface it without a hint.
        case .table:       return .init(symbol: "tablecells",
                                        help: "Insert table — click a point to place a default grid",
                                        shortcut: nil)
        }
    }
}

// MARK: - Focused command plumbing

/// Focused scene values carrying the active window's app actions (Zoom-to-Fit,
/// Export, Print, tool activation, undo/redo, delete, command palette, and the
/// "a tool is mid-run" flag). Open/Save/Save As are NO LONGER here — they are
/// native DocumentGroup commands. LibreCADApp reads these in its `.commands`.
extension FocusedValues {
    // `commandPalette` (the ⌘K raise action) + its `CommandPaletteKey` now live in
    // CommandPalette.swift alongside `CommandPaletteModifier` (its sole publisher), so the
    // palette is self-contained for its unit-test symlink. Same module — readers here
    // (and in LibreCADApp) are unaffected.

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

    /// Match Properties — PICK UP (⌘⇧C): load the property brush from the single selected
    /// entity (`CanvasModel.loadPaintBrushFromSelection`). The focused window publishes
    /// this; LibreCADApp's "Match Properties ▸ Pick Up Properties" item + the toolbar
    /// `eyedropper` button fire it. `nil` when no canvas is focused (disables the item).
    var matchPropPickUp: (() -> Void)? {
        get { self[MatchPropPickUpKey.self] }
        set { self[MatchPropPickUpKey.self] = newValue }
    }

    /// Match Properties — APPLY (⌘⇧V): paint the loaded brush onto the whole current
    /// selection (`CanvasModel.applyPaintBrushToSelection`) as one undoable group, then
    /// redraw. `nil` when no canvas is focused (disables the menu item).
    var matchPropApply: (() -> Void)? {
        get { self[MatchPropApplyKey.self] }
        set { self[MatchPropApplyKey.self] = newValue }
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

    /// Toggle the trailing Inspector pane on the focused window (#03 — View ▸ Show
    /// Inspector, ⌃⌘I + the ⌘K palette + the toolbar `sidebar.trailing` button all
    /// fire this same `showInspector.toggle()`). `nil` when no canvas is focused.
    var toggleInspector: (() -> Void)? {
        get { self[ToggleInspectorKey.self] }
        set { self[ToggleInspectorKey.self] = newValue }
    }

    /// Toggle the opt-in "Current properties" bar on the focused window (View ▸ Show
    /// Current Properties Bar). `nil` when no canvas is focused.
    var toggleCurrentPropertiesBar: (() -> Void)? {
        get { self[ToggleCurrentPropertiesBarKey.self] }
        set { self[ToggleCurrentPropertiesBarKey.self] = newValue }
    }

    /// Create a NEW paper-space layout on the focused window and switch to it (#00 —
    /// Layout ▸ New Layout). Always available when a canvas is focused (`CanvasModel.
    /// newLayout`). `nil` when no canvas is focused (disables the item).
    var newLayout: (() -> Void)? {
        get { self[NewLayoutKey.self] }
        set { self[NewLayoutKey.self] = newValue }
    }

    /// Delete the ACTIVE layout on the focused window (#00 — Layout ▸ Delete Layout).
    /// Published ONLY when a layout TAB is active (paper space); `nil` in model space,
    /// which disables the item (there is no active layout to delete).
    var deleteActiveLayout: (() -> Void)? {
        get { self[DeleteActiveLayoutKey.self] }
        set { self[DeleteActiveLayoutKey.self] = newValue }
    }

    /// Duplicate the ACTIVE layout on the focused window into a fresh sheet and switch
    /// to the copy (#00 — Layout ▸ Duplicate Layout). Published ONLY when a layout TAB
    /// is active (paper space); `nil` in model space, which disables the item.
    var duplicateActiveLayout: (() -> Void)? {
        get { self[DuplicateActiveLayoutKey.self] }
        set { self[DuplicateActiveLayoutKey.self] = newValue }
    }
}

// `CommandPaletteKey` moved to CommandPalette.swift (see the note on the `commandPalette`
// accessor above) so the palette's registry + key compile standalone in its test symlink.

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

/// Groups the Match-Properties focused-scene-value handlers (#2 — Pick Up / Apply) into
/// one `ViewModifier`, so `ContentView.canvasDetail`'s modifier chain stays under the
/// Swift type-checker's expression-complexity limit (gotcha #2). Each closure is the
/// same action the Edit menu chords (⌘⇧C / ⌘⇧V) + the toolbar `eyedropper` fire.
private struct MatchPropHandlersModifier: ViewModifier {
    let pickUp: () -> Void
    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.matchPropPickUp) { pickUp() }
            .focusedSceneValue(\.matchPropApply) { apply() }
    }
}

/// Groups the Lane S app-shell focused-scene-value handlers — the Inspector toggle
/// (#03) + the Layout menu's New / Delete / Duplicate active-layout verbs (#00) — into
/// one `ViewModifier`, so `ContentView.canvasDetail`'s modifier chain stays under the
/// Swift type-checker's expression-complexity limit (gotcha #2). The delete/duplicate
/// closures are `nil` in model space, which disables the matching Layout-menu items.
private struct ShellMenuHandlersModifier: ViewModifier {
    let toggleInspector: () -> Void
    let toggleCurrentPropertiesBar: () -> Void
    let newLayout: () -> Void
    let deleteActiveLayout: (() -> Void)?
    let duplicateActiveLayout: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.toggleInspector) { toggleInspector() }
            .focusedSceneValue(\.toggleCurrentPropertiesBar) { toggleCurrentPropertiesBar() }
            .focusedSceneValue(\.newLayout) { newLayout() }
            .focusedSceneValue(\.deleteActiveLayout, deleteActiveLayout)
            .focusedSceneValue(\.duplicateActiveLayout, duplicateActiveLayout)
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

private struct MatchPropPickUpKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct MatchPropApplyKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Carries the focused window's "a draw tool is mid-run" flag. Unlike the action
/// keys above (whose absence means "no canvas focused"), this is a plain `Bool`;
/// `FocusedValues` returns `nil` when unset, so the accessor defaults it to
/// `false` (no tool active ⇒ Delete enablement is governed only by the selection).
private struct IsToolActiveKey: FocusedValueKey {
    typealias Value = Bool
}

private struct ToggleInspectorKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ToggleCurrentPropertiesBarKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct NewLayoutKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct DeleteActiveLayoutKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct DuplicateActiveLayoutKey: FocusedValueKey {
    typealias Value = () -> Void
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
                        .foregroundStyle(DS.Palette.accent)   // #44 — ONE accent source
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

    // #4c — layout-tab context-menu actions (Rename / Delete / Duplicate / Page Setup).
    // Each forwards a LAYOUT name to the call site (ContentView), which calls the
    // matching P0-D `CanvasModel` wrapper + redraws. Defaulted to no-ops so the pure
    // unit tests (which construct the strip without these) need not supply them.

    /// Rename the named layout to a new name (Rename → the View-layer rename sheet).
    var onRenameLayout: (_ name: String, _ newName: String) -> Void = { _, _ in }
    /// Delete the named layout (never the Model tab — only layout tabs show the menu).
    var onDeleteLayout: (_ name: String) -> Void = { _ in }
    /// Duplicate the named layout into a fresh sheet (and activate the copy).
    var onDuplicateLayout: (_ name: String) -> Void = { _ in }
    /// Page Setup commit for the named layout (#4c): the sheet hands back the new
    /// engine `PageDescriptor`; the call site forwards it to the P0-D
    /// `CanvasModel.setLayoutPage(_:_:)` wrapper (one undoable step) + redraws. Defaulted
    /// to a no-op so the pure unit tests can construct the strip without it.
    var onPageSetup: (_ name: String, _ page: PageDescriptor) -> Void = { _, _ in }

    /// The layout whose Rename sheet is open (View-layer only — never reached by the
    /// headless tests, which exercise the `CanvasModel` rename wrapper directly). `nil`
    /// when no rename is in progress. Wrapped so it is `Identifiable` for `.sheet(item:)`.
    @State private var renameTarget: RenameTarget?

    /// An `Identifiable` carrier for the layout name being renamed (so `.sheet(item:)`
    /// can present the rename sheet keyed off the target name).
    private struct RenameTarget: Identifiable {
        let name: String
        var id: String { name }
    }

    /// The layout whose Page Setup sheet is open (View-layer only — never reached by the
    /// headless tests, which exercise the `LayoutPageMapper` + `CanvasModel.setLayoutPage`
    /// round-trip directly). `nil` when no Page Setup is in progress.
    @State private var pageSetupTarget: PageSetupTarget?

    /// An `Identifiable` carrier for the Page Setup target — the layout name + its CURRENT
    /// page descriptor (captured when the menu fires, so the sheet seeds its form without
    /// re-reading the model). Keyed by name for `.sheet(item:)`.
    private struct PageSetupTarget: Identifiable {
        let name: String
        let page: PageDescriptor
        var id: String { name }
    }

    /// Whether the strip is shown at all. The Model/Layout tab strip is ALWAYS visible
    /// (AutoCAD/LibreCAD parity): the "Model" tab, one tab per layout, and the trailing
    /// "+" that adds a layout. It was briefly hidden until a paper-space layout existed
    /// (Wave 4 §3d — "a lone Model pill is noise"), but the ONLY add-layout affordance
    /// ("+") lives INSIDE the strip, so hiding it left a fresh, model-space-only document
    /// with no GUI way to create its first layout (a dead-end). Always showing the strip
    /// restores that entry point.
    /// `LayoutTabStrip.shouldShow(layoutCount:isEditingBlock:)` is the pure predicate
    /// (unit-tested); this is its live read.
    private var isVisible: Bool {
        Self.shouldShow(layoutCount: model.orderedLayouts.count,
                        isEditingBlock: model.editingBlock != nil)
    }

    /// Pure visibility predicate: the strip is ALWAYS shown (returns `true`). The Model
    /// tab + "+" must stay reachable at all times so a fresh, model-space-only drawing
    /// can create its first layout — the "+" is the sole add-layout entry point (no menu,
    /// palette, toolbar, or shortcut creates a layout). Kept as a predicate, rather than
    /// dropping the gate, so the always-visible contract is unit-tested and any future
    /// "hide when empty" regression fails loudly. The parameters are retained for that
    /// test contract (and to document what once gated visibility); the result no longer
    /// depends on them.
    static func shouldShow(layoutCount: Int, isEditingBlock: Bool) -> Bool {
        true
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
        // #4c: the layout RENAME sheet — raised from a tab's context menu (View-layer
        // modal only; never reachable from the headless tests, which call the model
        // rename wrapper directly). Confirming forwards (name → newName) to the call
        // site's `onRenameLayout` (the P0-D `CanvasModel.renameLayout` wrapper).
        .sheet(item: $renameTarget) { target in
            LayoutRenameSheet(
                currentName: target.name,
                existingNames: model.orderedLayouts.map(\.name),
                onConfirm: { newName in
                    renameTarget = nil
                    onRenameLayout(target.name, newName)
                },
                onCancel: { renameTarget = nil }
            )
        }
        // #4c: the per-layout PAGE SETUP sheet — raised from a tab's context menu (View-
        // layer modal only; never reached by the headless tests, which drive the
        // `LayoutPageMapper` + `CanvasModel.setLayoutPage` round-trip directly). On OK the
        // sheet hands back the new engine `PageDescriptor`, forwarded to the call site's
        // `onPageSetup` (the `CanvasModel.setLayoutPage` wrapper).
        .sheet(item: $pageSetupTarget) { target in
            LayoutPageSetupSheet(
                layoutName: target.name,
                page: target.page,
                onCommit: { page in
                    pageSetupTarget = nil
                    onPageSetup(target.name, page)
                },
                onCancel: { pageSetupTarget = nil }
            )
        }
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
        // #4c: the layout-tab right-click menu (LAYOUT tabs only — the Model tab + BEDIT
        // tab have no menu, so Delete can never target the Model space). Rename raises a
        // View-layer sheet; Delete / Duplicate / Page Setup forward to the call site's
        // P0-D `CanvasModel` wrappers (Page Setup is stubbed to Document Settings).
        .contextMenu { layoutTabContextMenu(name) }
        .accessibilityIdentifier("tab.layout.\(name)")
    }

    /// The context-menu content for one LAYOUT tab (#4c): Rename / Delete / Duplicate /
    /// Page Setup. Split into its own `@ViewBuilder` so `layoutTab`'s body stays small.
    @ViewBuilder
    private func layoutTabContextMenu(_ name: String) -> some View {
        Button("Rename…") { renameTarget = RenameTarget(name: name) }
        Button("Duplicate") { onDuplicateLayout(name) }
        // Page Setup (#4c): raise the per-layout Page Setup sheet, seeded with this
        // layout's CURRENT page (read once, here, so the sheet is a pure value editor).
        // A missing layout (race) simply opens nothing.
        Button("Page Setup…") {
            if let page = model.drawing.layout(named: name)?.page {
                pageSetupTarget = PageSetupTarget(name: name, page: page)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { onDeleteLayout(name) }
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

// MARK: - Export options (NSSavePanel accessory state + view)

/// The mutable selection backing the export `NSSavePanel`'s accessory: the chosen
/// `format` (any `ExportFormat`, incl. the raster JPEG/BMP/TIFF), the raster `dpi`, and
/// the JPEG compression `quality`. Seeded from the format the Export command requested;
/// the defaults (PNG @ `DrawingExporter.defaultRasterDPI`, quality 0.9) leave the
/// historical behavior unchanged when the accessory is left untouched. `@MainActor`
/// (it is read back on the main actor right after the modal returns) and an
/// `ObservableObject` so the SwiftUI accessory binds to it.
@MainActor
final class ExportOptionsState: ObservableObject {
    @Published var format: ExportFormat
    /// Raster resolution (dots-per-inch). Only meaningful for raster formats; ignored by
    /// the vector PDF / pure-string SVG paths.
    @Published var dpi: Double
    /// JPEG compression quality (0…1). Only meaningful for `.jpg`.
    @Published var jpegQuality: Double

    init(format: ExportFormat,
         dpi: Double = DrawingExporter.defaultRasterDPI,
         jpegQuality: Double = 0.9) {
        self.format = format
        self.dpi = dpi
        self.jpegQuality = jpegQuality
    }

    /// The DPI to hand the exporter: the edited value clamped finite-and-positive,
    /// falling back to the default when the field is left empty/invalid (so a bad entry
    /// never produces a zero-pixel image). Capped at a sane ceiling to avoid a runaway
    /// allocation.
    var effectiveDPI: Double {
        guard dpi.isFinite, dpi > 0 else { return DrawingExporter.defaultRasterDPI }
        return Swift.min(dpi, 2400)
    }
}

/// The SwiftUI ACCESSORY presented inside the export `NSSavePanel`: a format picker
/// (every `ExportFormat`), plus — for raster formats — a DPI field, and — for JPEG — a
/// compression-quality slider. Picking a format runs `onFormatChange` so the host panel
/// re-syncs its allowed type + name extension. Kept small + decomposed so the SwiftUI
/// type-checker handles it (gotcha #2); lives in the View layer only (never reached by a
/// test — it is built solely inside `exportDrawing`'s modal path).
struct ExportOptionsAccessory: View {
    @ObservedObject var options: ExportOptionsState
    /// Called whenever the format changes, so the host `NSSavePanel` updates its allowed
    /// content type and the name field's extension.
    let onFormatChange: (ExportFormat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            formatRow
            if options.format.isRaster {
                dpiRow
            }
            if options.format == .jpg {
                qualityRow
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    /// The format picker spanning every supported export format.
    @ViewBuilder
    private var formatRow: some View {
        HStack {
            Text("Format").frame(width: 70, alignment: .leading)
            Picker("Format", selection: $options.format) {
                ForEach(ExportFormat.allCases, id: \.self) { fmt in
                    Text(fmt.displayName).tag(fmt)
                }
            }
            .labelsHidden()
            .onChange(of: options.format) { _, newValue in
                onFormatChange(newValue)
            }
        }
    }

    /// The DPI field for the raster pipeline (PNG/JPEG/BMP/TIFF).
    @ViewBuilder
    private var dpiRow: some View {
        HStack {
            Text("Resolution").frame(width: 70, alignment: .leading)
            TextField("DPI", value: $options.dpi, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .labelsHidden()
            Text("DPI").foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// The JPEG compression-quality slider (0…1), shown only for `.jpg`.
    @ViewBuilder
    private var qualityRow: some View {
        HStack {
            Text("Quality").frame(width: 70, alignment: .leading)
            Slider(value: $options.jpegQuality, in: 0...1)
            Text("\(Int((options.jpegQuality * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
