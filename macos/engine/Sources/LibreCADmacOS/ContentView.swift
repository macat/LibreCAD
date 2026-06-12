//
//  ContentView.swift
//  LibreCADmacOS
//
//  The single window: the interactive Metal canvas (CADCanvasView) plus a
//  coordinate / status HUD. It owns the live model directly — a `@MainActor
//  @Observable CanvasModel` — so there is no NSDocument and nothing on the
//  launch path that crosses actor boundaries.
//
//  On first appear it loads the bundled `dim_sample.dxf` (falling back to the
//  repo copy) so a fresh launch shows real geometry. File▸Open uses a SwiftUI
//  `.fileImporter` driven by the ⌘O command via a focused scene value.
//
//  Crash-fix note: the previous DocumentGroup path constructed the document off
//  the main thread and trapped on `MainActor.assumeIsolated`. There is NO
//  `assumeIsolated` here: `CanvasModel`/`CADDrawing` are touched only on the
//  main actor (this whole view runs there), and `loadDrawing(dxfPath:)` is
//  itself `@MainActor`.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CADEngine

struct ContentView: View {
    /// The canvas state (model, viewport, index, selection, snap). Owned by this
    /// window; `@MainActor @Observable`, so it is only ever touched on the main
    /// actor — which is where this whole view runs.
    @State private var model = CanvasModel()
    /// Tracks the window's current file URL (the doc opened or last saved to) and
    /// its unsaved-changes flag. Drives Save (⌘S) vs Save As… (⇧⌘S) and the title.
    @State private var doc = DocumentState()
    /// Bridge so the Zoom-to-Fit command can reach the live canvas controller.
    @State private var controllerBox = CADCanvasView.ControllerBox()
    @State private var status: String = "Loading…"
    /// Drives the File▸Open importer (toggled by the ⌘O command).
    @State private var showOpen = false
    /// Set once so the launch sample is loaded exactly one time.
    @State private var didLoadSample = false

    /// The sidebar's visibility column state (lets the toolbar toggle drive it).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Whether the trailing Inspector pane (entity properties + snap/grid + tool
    /// options) is shown. Toggled from the toolbar; defaults visible so the modern
    /// editing surface is discoverable on launch.
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Leading pane: the modern Layers (+ Blocks stub) sidebar, bound to
            // the SAME live model the canvas renders so edits reflect immediately.
            LayersSidebar(model: model, controllerBox: controllerBox)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .navigationTitle("Document")
        } detail: {
            // Detail pane: the existing interactive canvas + HUD + toolbar,
            // unchanged from the pre-sidebar layout.
            canvasDetail
        }
    }

    /// The canvas detail pane — the prior single-window body, verbatim. Kept
    /// separate so the `NavigationSplitView` above stays readable and the canvas /
    /// HUD / toolbar wiring is untouched.
    private var canvasDetail: some View {
        CADCanvasView(model: model, controllerBox: controllerBox)
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            .overlay(alignment: .topLeading) { statusHUD }
            .overlay(alignment: .top) { toolPromptHUD }
            .overlay(alignment: .bottomLeading) { coordinateHUD }
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
            .focusedSceneValue(\.zoomToFit) { controllerBox.controller?.zoomToFit() }
            .focusedSceneValue(\.openDocument) { showOpen = true }
            // Save (⌘S): write in place if we have a current file, else Save As…
            .focusedSceneValue(\.saveDocument) { Task { await save() } }
            // Save As… (⇧⌘S): always present the panel.
            .focusedSceneValue(\.saveDocumentAs) { Task { await saveAs() } }
            // Export… (PDF/PNG/SVG): present a save panel whose format follows the
            // chosen extension, then render the current drawing through the shared
            // export facade. Print… (⌘P): the system print dialog.
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
            .fileImporter(
                isPresented: $showOpen,
                allowedContentTypes: Self.dxfTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .onAppear {
                guard !didLoadSample else { return }
                didLoadSample = true
                Task { await loadSample() }
            }
            // Reflect the current file in the window title bar (and show the proxy
            // icon when a real file backs the document). Untitled before first save.
            .navigationTitle(doc.displayName)
            .modifier(NavigationDocumentIfAny(url: doc.currentURL))
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

            Divider()
            // Modify tools (act on the current selection).
            toolButton(.move, symbol: "arrow.up.and.down.and.arrow.left.and.right",
                       help: "Move selection (M)")
            toolButton(.copy, symbol: "plus.square.on.square", help: "Copy selection (⇧C)")
            toolButton(.offset, symbol: "plus.rectangle.on.rectangle",
                       help: "Offset selection (⇧O)")
            toolButton(.rotate, symbol: "rotate.right", help: "Rotate selection (⇧R)")
            toolButton(.scale, symbol: "arrow.up.left.and.arrow.down.right",
                       help: "Scale selection (⇧S)")
            toolButton(.mirror, symbol: "flip.horizontal", help: "Mirror selection (⇧M)")
            toolButton(.array, symbol: "square.grid.3x3", help: "Array selection (⇧A)")
            toolButton(.divide, symbol: "divide", help: "Divide selection (⇧D)")
            toolButton(.explode, symbol: "burst", help: "Explode selection (⇧X)")

            Divider()
            // Edit tools (pick entities under the cursor; no pre-selection needed).
            toolButton(.trim, symbol: "scissors", help: "Trim to boundary (T)")
            toolButton(.extend, symbol: "arrow.right.to.line",
                       help: "Extend to boundary (X)")
            toolButton(.fillet, symbol: "circle.bottomrighthalf.checkered",
                       help: "Fillet (round) corner (F)")
            toolButton(.chamfer, symbol: "angle", help: "Chamfer (bevel) corner (⇧F)")
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

    // MARK: - HUD

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
    }

    /// The active tool's prompt ("Specify first point" / "Specify next point"),
    /// shown centered at the top while a draw tool is active.
    @ViewBuilder
    private var toolPromptHUD: some View {
        if model.isToolActive, !model.toolStatus.isEmpty {
            Text("\(model.activeToolKind.title): \(model.toolStatus)")
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.tint.opacity(0.30), in: Capsule())
                .padding(8)
        }
    }

    @ViewBuilder
    private var coordinateHUD: some View {
        if let w = model.cursorWorld {
            let snapLabel = model.snap.map { " · \(label(for: $0.kind))" } ?? ""
            Text(String(format: "x %.3f   y %.3f%@", w.x, w.y, snapLabel))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                // Adaptive chip (see statusHUD): a system material so the coordinate
                // readout stays legible over both the light and dark canvas.
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
        }
    }

    private func label(for kind: SnapKind) -> String {
        switch kind {
        case .endpoint: return "end"
        case .center: return "center"
        case .middle: return "mid"
        case .onEntity: return "on"
        case .intersection: return "intersect"
        case .grid: return "grid"
        case .free: return "free"
        }
    }

    // MARK: - Open (File▸Open via ⌘O)

    /// Accepted file types for the importer. Prefers the exported DXF UTType but
    /// always also offers the plain `.dxf` extension type as a robust fallback.
    private static let dxfTypes: [UTType] = {
        var types: [UTType] = [.librecadDXF]
        if let byExt = UTType(filenameExtension: "dxf") { types.append(byExt) }
        return types
    }()

    /// Handles the importer result: resolves the security-scoped URL and loads it.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await open(url) }
        case .failure(let error):
            status = "Open cancelled: \(error.localizedDescription)"
        }
    }

    /// Loads a user-picked file, honoring the security-scoped URL lifecycle, and
    /// records it as the document's current file so a later ⌘S writes back to it.
    /// On error the message lands in the status HUD — never a crash.
    @MainActor
    private func open(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ok = await load(path: url.path, label: url.lastPathComponent)
        if ok { doc.markOpened(url) }
    }

    // MARK: - Initial sample load

    /// Loads the launch sample from the app bundle if present, else the repo copy,
    /// so the bundled app is path-independent. Runs on the main actor; on failure
    /// the status HUD shows the error rather than crashing.
    @MainActor
    private func loadSample() async {
        status = "Loading dim_sample.dxf…"
        if let bundled = Bundle.main.url(forResource: "dim_sample", withExtension: "dxf") {
            await load(path: bundled.path, label: "dim_sample.dxf")
            return
        }
        // Fallback to the in-repo copy (useful when running the bare binary).
        await load(path: Self.repoSamplePath, label: "dim_sample.dxf")
    }

    /// Repo-relative fallback path for the launch sample (used only when the
    /// sample is not bundled, e.g. running the SwiftPM binary directly).
    private static let repoSamplePath =
        "/Users/macatt/w/LibreCAD/librecad/res/dxf/dim_sample.dxf"

    // MARK: - Shared load

    /// Parses a DXF at `path` on the main actor, installs it in the model, frames
    /// it, and updates the HUD. Errors surface in the status HUD (no crash).
    /// Returns whether the load succeeded (so callers can record the file URL).
    @MainActor
    @discardableResult
    private func load(path: String, label: String) async -> Bool {
        let size = model.viewport.size
        do {
            let drawing = try await loadDrawing(dxfPath: path)
            model.setDrawing(drawing, viewSize: size)
            status = "\(label) — \(model.entityCount) entities"
            NSLog("CADCanvas: loaded \(model.entityCount) entities from \(label)")
            controllerBox.controller?.zoomToFit()
            return true
        } catch {
            status = "Load failed: \(error.localizedDescription)"
            NSLog("CADCanvas: load failed: \(error)")
            return false
        }
    }

    // MARK: - Save (⌘S) / Save As… (⇧⌘S)

    /// Save (⌘S): if the document already has a file, write the current drawing to
    /// it; otherwise fall through to Save As… The write runs through the
    /// `@MainActor` `writeDrawing` (which hops to the engine actor for the
    /// non-reentrant libdxfrw call). Status/errors land in the HUD — never a crash.
    @MainActor
    private func save() async {
        if let url = doc.currentURL {
            await write(to: url)
        } else {
            await saveAs()
        }
    }

    /// Save As… (⇧⌘S): present an `NSSavePanel` for a `.dxf`, then write the
    /// current drawing there and record it as the document's current file. The
    /// chosen URL is security-scoped (start/stop around the write).
    @MainActor
    private func saveAs() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.dxfTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(doc.displayName).dxf"
        panel.title = "Save Drawing"
        panel.prompt = "Save"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            status = "Save cancelled"
            return
        }
        await write(to: url)
    }

    /// Writes `model.drawing` to `url` via the merged DXF writer, honoring the
    /// security-scoped URL lifecycle (the Save As… panel hands back a scoped URL;
    /// an in-place ⌘S URL is already accessible, so start/stop is a harmless no-op
    /// there). On success records the file (clears dirty) and reports the
    /// written/skipped tallies in the HUD; on failure shows the error (no crash).
    @MainActor
    private func write(to url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await writeDrawing(model.drawing, toPath: url.path)
            doc.markSaved(to: url)
            var msg = "Saved \(url.lastPathComponent) — \(result.written) entities"
            if result.skipped > 0 {
                // Some kinds (text/hatch/solid/spline) aren't yet emitted by the
                // writer; make that visible rather than silently dropping them.
                msg += " (\(result.skipped) unsupported skipped)"
            }
            status = msg
            NSLog("CADCanvas: \(msg)")
        } catch {
            status = "Save failed: \(error.localizedDescription)"
            NSLog("CADCanvas: save failed: \(error)")
        }
    }

    // MARK: - Export (PDF / PNG / SVG) and Print (⌘P)

    /// Export… for one `format`: present an `NSSavePanel` defaulting to the document
    /// name with that format's extension, then render the current drawing through
    /// the shared export facade (PDF/PNG via the CGContext renderer, SVG via the
    /// engine's pure-Swift emitter). Status/errors land in the HUD — never a crash.
    @MainActor
    private func exportDrawing(_ format: ExportFormat) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(doc.displayName).\(format.fileExtension)"
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

// MARK: - Conditional window-document modifier

/// Applies `.navigationDocument(url)` only when a real file backs the document so
/// the title bar shows the proxy icon / path popover; before the first save there
/// is no URL and the modifier is a no-op (the title alone reads "Untitled").
private struct NavigationDocumentIfAny: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}

// MARK: - Focused command plumbing

/// Focused scene values carrying the active window's "Zoom to Fit" and "Open…"
/// actions, so menu/keyboard commands (⌘0 / ⌘O) can drive the focused window
/// without a global singleton (LibreCADApp reads them in its `.commands`).
extension FocusedValues {
    var zoomToFit: (() -> Void)? {
        get { self[ZoomToFitKey.self] }
        set { self[ZoomToFitKey.self] = newValue }
    }

    var openDocument: (() -> Void)? {
        get { self[OpenDocumentKey.self] }
        set { self[OpenDocumentKey.self] = newValue }
    }

    /// Save / Save As… the focused window's drawing (File menu, ⌘S / ⇧⌘S).
    var saveDocument: (() -> Void)? {
        get { self[SaveDocumentKey.self] }
        set { self[SaveDocumentKey.self] = newValue }
    }
    var saveDocumentAs: (() -> Void)? {
        get { self[SaveDocumentAsKey.self] }
        set { self[SaveDocumentAsKey.self] = newValue }
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

private struct ZoomToFitKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SaveDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SaveDocumentAsKey: FocusedValueKey {
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
