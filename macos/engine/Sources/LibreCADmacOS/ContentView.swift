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

    /// The live text of the bottom command / coordinate input line (UX-plan U1).
    /// Cleared after each successful submit; the field echoes parse errors via the
    /// model's `lastCommandError`.
    @State private var commandText: String = ""

    /// Whether the bottom command field has keyboard focus. Bound to a `@FocusState`
    /// so the canvas can hand focus to it on Space (D1) and Esc/submit can return
    /// focus to the canvas (so tool letters work again).
    @FocusState private var commandFieldFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Leading pane: the modern Layers (+ Blocks stub) sidebar, bound to
            // the SAME live model the canvas renders so edits reflect immediately.
            LayersSidebar(model: model, controllerBox: controllerBox)
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
            // U2: the contextual tool-options bar, pinned directly under the toolbar
            // and above the canvas. It shows ONLY the active tool's parameters (and
            // collapses to nothing for tools without options), two-way bound to the
            // SAME CanvasModel config the Inspector uses; changes re-apply onto the
            // live tool via `reapplyActiveToolConfig` (one source of truth).
            .safeAreaInset(edge: .top, spacing: 0) {
                ToolOptionsBar(model: model, controllerBox: controllerBox)
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
                    StatusBar(model: model)
                    commandBar
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
            .focusedSceneValue(\.openDocumentSettings) { showSettings = true }
            .focusedSceneValue(\.commandPalette) { showPalette = true }
            .focusedSceneValue(\.zoomToFit) { controllerBox.controller?.zoomToFit() }
            // Export… (PDF/PNG/SVG): present a save panel whose format follows the
            // chosen extension, then render the current drawing through the shared
            // export facade. Print… (⌘P): the system print dialog. These STAY custom
            // (they are not the document type — DocumentGroup handles only DXF I/O).
            .focusedSceneValue(\.exportDocument) { format in Task { await exportDrawing(format) } }
            .focusedSceneValue(\.printDocument) { printDrawing() }
            .focusedSceneValue(\.activateTool) { kind in
                controllerBox.controller?.activateTool(kind)
            }
            .focusedSceneValue(\.undoAction) { model.undo() }
            .focusedSceneValue(\.redoAction) { model.redo() }
            .focusedSceneValue(\.deleteSelection) {
                if model.deleteSelection() { controllerBox.controller?.requestRedraw() }
            }
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
            }
            // View ▸ Show Command Line (⇧⌘L) focuses the field from the menu.
            .focusedSceneValue(\.focusCommandLine) { commandFieldFocused = true }
    }

    // MARK: - Document ⇄ live model bridge (MAIN ACTOR)

    /// Builds the live `@MainActor CADDrawing`/`CanvasModel` from the document's
    /// Sendable payload, frames it, and adopts the environment UndoManager. Runs on
    /// the main actor (the whole view does); the payload was parsed OFF-main in the
    /// document, so nothing here crosses the launch-crash boundary.
    @MainActor
    private func loadFromDocument() {
        let drawing = CADDrawing.make(from: document.payload)
        model.setDrawing(drawing, viewSize: model.viewport.size)
        adoptEnvironmentUndo()
        controllerBox.controller?.zoomToFit()
        let n = model.entityCount
        status = n == 0 ? "New drawing" : "\(n) entities"
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

    // MARK: - Toolbar (Select + Draw group + Modify group)

    /// One toolbar button per tool, grouped Select → Draw → Modify (dividers
    /// between groups). Each button activates its tool on the focused canvas and
    /// shows the active badge. SF Symbols where one fits; the `help` carries the
    /// shortcut so the toolbar is self-documenting. The shortcuts shown match the
    /// Tools menu / canvas keymap exactly.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            toolButton(.select, symbol: "cursorarrow", help: "Select / pan (V)")

            Divider()
            // Draw tools.
            toolButton(.line, symbol: "line.diagonal", help: "Draw line (L)")
            toolButton(.circle, symbol: "circle", help: "Draw circle (C)")
            toolButton(.arc, symbol: "point.topleft.down.to.point.bottomright.curvepath",
                       help: "Draw arc (A)")
            toolButton(.rectangle, symbol: "rectangle", help: "Draw rectangle (R)")
            toolButton(.polyline, symbol: "scribble", help: "Draw polyline (P)")
            toolButton(.point, symbol: "smallcircle.filled.circle", help: "Place point (O)")
            toolButton(.ellipse, symbol: "oval", help: "Draw ellipse (E)")
            toolButton(.polygon, symbol: "hexagon", help: "Draw polygon (G)")
            toolButton(.spline, symbol: "scribble.variable", help: "Draw spline (S)")
            // Hatch fills the region bounded by the current selection.
            toolButton(.hatch, symbol: "square.grid.2x2.fill", help: "Hatch fill selection (H)")
            // Text authoring: a click sets the insertion point and raises the inline
            // editor; type, then Return commits the text.
            toolButton(.text, symbol: "character.textbox", help: "Add text (⇧T)")
            // Blocks: place a reference to a named block. With no block chosen the
            // tool is inert (the block-picker UI is a later task) — it never crashes.
            toolButton(.insert, symbol: "square.on.square.dashed", help: "Insert block (⇧I)")

            Divider()
            // Modify tools (act on the current selection).
            toolButton(.move, symbol: "arrow.up.and.down.and.arrow.left.and.right",
                       help: "Move selection (M)")
            toolButton(.copy, symbol: "plus.square.on.square", help: "Copy selection (⇧C)")
            toolButton(.offset, symbol: "plus.rectangle.on.rectangle",
                       help: "Offset selection (⇧O)")
            toolButton(.rotate, symbol: "rotate.right", help: "Rotate selection (⇧R)")
            toolButton(.scale, symbol: "square.resize",
                       help: "Scale selection (⇧S)")
            toolButton(.mirror, symbol: "flip.horizontal", help: "Mirror selection (⇧M)")
            toolButton(.array, symbol: "square.grid.3x3", help: "Array selection (⇧A)")
            toolButton(.divide, symbol: "divide", help: "Divide selection (⇧D)")
            toolButton(.explode, symbol: "burst", help: "Explode selection (⇧X)")
            // Wire-wave-C modify tools.
            toolButton(.stretch,
                       symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                       help: "Stretch selection (⌥S)")
            toolButton(.lengthen, symbol: "ruler", help: "Lengthen line/arc (⇧L)")
            toolButton(.break, symbol: "scissors.badge.ellipsis", help: "Break entity (⇧B)")
            // Wire-wave-D: edit an existing polyline's vertices/segments.
            toolButton(.polylineEdit,
                       symbol: "point.topleft.down.to.point.bottomright.curvepath.fill",
                       help: "Edit polyline vertices (⇧P)")
            // Wire-wave-1 modify tools: Join fuses touching lines/arcs into one
            // polyline; Explode Text converts a text/mtext entity to stroke polylines.
            toolButton(.join, symbol: "link", help: "Join lines/arcs into a polyline (⇧J)")
            toolButton(.explodeText, symbol: "character.cursor.ibeam",
                       help: "Explode text to geometry (⇧E)")

            Divider()
            // Edit tools (pick entities under the cursor; no pre-selection needed).
            toolButton(.trim, symbol: "scissors", help: "Trim to boundary (T)")
            toolButton(.extend, symbol: "arrow.right.to.line",
                       help: "Extend to boundary (X)")
            toolButton(.fillet, symbol: "circle.bottomrighthalf.checkered",
                       help: "Fillet (round) corner (F)")
            toolButton(.chamfer, symbol: "skew", help: "Chamfer (bevel) corner (⇧F)")

            Divider()
            // Dimension tools (annotate measurements). Linear/Aligned place two
            // origins + a dimension-line point; Radius/Diameter pick a circle/arc +
            // a leader point; Angular defines two rays + an arc location.
            toolButton(.linearDim, symbol: "ruler", help: "Linear dimension (D)")
            toolButton(.alignedDim, symbol: "arrow.up.left.and.arrow.down.right",
                       help: "Aligned dimension (I)")
            toolButton(.radialDim, symbol: "arrow.left.and.right",
                       help: "Radius dimension (U)")
            toolButton(.diameterDim, symbol: "circle.and.line.horizontal",
                       help: "Diameter dimension (B)")
            toolButton(.angularDim, symbol: "angle", help: "Angular dimension (N)")

            Divider()
            // Measure / info tools (read-only): report a value in the status HUD
            // without mutating the drawing. Distance is keyed ⇧K; the other modes
            // are reachable from the toolbar, the Tools ▸ Measure menu, and ⌘K.
            toolButton(.measureDistance, symbol: "ruler", help: "Measure distance (⇧K)")
            toolButton(.measureAngle, symbol: "angle", help: "Measure angle")
            toolButton(.measureArea, symbol: "square.dashed", help: "Measure area + perimeter")
            toolButton(.measureLength, symbol: "sum", help: "Total length of selection")
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

    /// A single toolbar tool button: activates `kind`, labels it with `symbol`, and
    /// shows the active-tool badge.
    @ViewBuilder
    private func toolButton(_ kind: ToolKind, symbol: String, help: String) -> some View {
        Button {
            controllerBox.controller?.activateTool(kind)
        } label: {
            Label(kind.title, systemImage: symbol)
        }
        .help(help)
        .background(activeBadge(kind))
    }

    /// A subtle highlight behind the active tool's toolbar button.
    @ViewBuilder
    private func activeBadge(_ kind: ToolKind) -> some View {
        if model.activeToolKind == kind {
            RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.25))
        }
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

            if let error = model.lastCommandError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if model.isToolActive {
                Text(commandPlaceholder)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The active tool's step prompt + the accepted coordinate syntax, shown as the
    /// field's placeholder/hint. A neutral hint in select mode.
    private var commandPlaceholder: String {
        let hint = model.commandHint
        return hint.isEmpty
            ? "Command line — start a tool, then type a coordinate (x,y · @dx,dy · dist<angle)"
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

    /// Activate a tool kind in the focused window (Tools menu / shortcuts).
    var activateTool: ((ToolKind) -> Void)? {
        get { self[ActivateToolKey.self] }
        set { self[ActivateToolKey.self] = newValue }
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

private struct ActivateToolKey: FocusedValueKey {
    typealias Value = (ToolKind) -> Void
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

/// Carries the focused window's "a draw tool is mid-run" flag. Unlike the action
/// keys above (whose absence means "no canvas focused"), this is a plain `Bool`;
/// `FocusedValues` returns `nil` when unset, so the accessor defaults it to
/// `false` (no tool active ⇒ Delete enablement is governed only by the selection).
private struct IsToolActiveKey: FocusedValueKey {
    typealias Value = Bool
}
