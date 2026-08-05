//
//  ContentView.swift
//  LibreCADmacOS
//
//  One document window's UI: thin orchestrator that composes the
//  decomposed hosts (SidebarHost + CanvasContainerView + ToolBarHost +
//  InspectorHost) via @ViewBuilder. Wave 4 Phase 2 — ContentView
//  decomposition (perf-arch-review-plan Wave4 Builder 2).
//
//  LAUNCH-SAFETY — see original header (document payload vs live model).
//
//  GPLv2-or-later.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CADEngine

struct ContentView: View {
    let document: LibreCADDocument
    @Environment(\.undoManager) private var environmentUndoManager
    @State private var model = CanvasModel()
    @State private var controllerBox = CADCanvasView.ControllerBox()
    @State private var status: String = ""
    @State private var didLoadPayload = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showPalette = false
    @State private var showSettings = false
    @State private var showTemplateChooser = false
    @State private var showBlockNamePrompt = false
    @State private var suggestedBlockName = "Block-1"
    @State private var commandLineText: String = ""
    @FocusState private var commandLineFocused: Bool
    @AppStorage("commandBar.mru") private var commandBarMRURaw: String = ""
    @AppStorage("toolbar.pinnedTools") private var pinnedToolsRaw: String = ""
    @AppStorage("commandTranscript.show") private var showCommandTranscript: Bool = false
    @AppStorage("currentPropertiesBar.show") private var showCurrentPropertiesBar: Bool = false
    @AppStorage(AppSettings.Key.defaultUnit) private var prefDefaultUnitRaw = AppSettings.Default.unit.rawValue
    @AppStorage(AppSettings.Key.defaultTemplate) private var prefDefaultTemplate = AppSettings.Default.template
    @AppStorage(AppSettings.Key.autosaveEnabled) private var prefAutosaveEnabled = AppSettings.Default.autosaveEnabled
    @AppStorage(AppSettings.Key.defaultTextFont) private var prefTextFont = AppSettings.Default.textFont
    @AppStorage(AppSettings.Key.defaultTextHeight) private var prefTextHeight = AppSettings.Default.textHeight

    var body: some View {
        navigationRoot
            .task {
                guard !didLoadPayload else { return }
                didLoadPayload = true
                loadFromDocument()
            }
            .onChange(of: environmentUndoManagerID) { _, _ in adoptEnvironmentUndo() }
            .onChange(of: model.modelVersion) { _, _ in syncPayloadToDocument() }
            .onAppear {
                model.seedSnapSettingsFromAppSettings()
                model.commandBarMRU = Self.decodeMRU(commandBarMRURaw)
            }
            .onChange(of: model.commandBarMRU) { _, new in
                commandBarMRURaw = Self.encodeMRU(new)
            }
    }

    @ViewBuilder
    private var navigationRoot: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarPane
        } detail: {
            detailPane
        }
        .toolbar { toolbarHost }
        .inspector(isPresented: $showInspector) {
            InspectorHost(model: model, controllerBox: controllerBox)
        }
    }

    @ViewBuilder
    private var sidebarPane: some View {
        SidebarHost(
            model: model,
            controllerBox: controllerBox,
            onCreateBlock: { raiseBlockNamePrompt() },
            onInsertBlockFromFile: { insertBlockFromFile() },
            onSaveBlockToFile: { name in saveBlockToFile(named: name) }
        )
    }

    @ViewBuilder
    private var detailPane: some View {
        CanvasContainerView(
            model: model,
            controllerBox: controllerBox,
            status: $status,
            showInspector: $showInspector,
            showPalette: $showPalette,
            showSettings: $showSettings,
            showTemplateChooser: $showTemplateChooser,
            showBlockNamePrompt: $showBlockNamePrompt,
            suggestedBlockName: $suggestedBlockName,
            commandLineText: $commandLineText,
            commandLineFocused: $commandLineFocused,
            showCommandTranscript: $showCommandTranscript,
            showCurrentPropertiesBar: $showCurrentPropertiesBar,
            pinnedToolsRaw: $pinnedToolsRaw
        )
    }

    @ToolbarContentBuilder
    private var toolbarHost: some ToolbarContent {
        ToolBarHost(
            model: model,
            controllerBox: controllerBox,
            pinnedToolsRaw: $pinnedToolsRaw,
            showInspector: $showInspector,
            onImage: { chooseAndPlaceImage() },
            onCreateBlock: { raiseBlockNamePrompt() }
        )
    }

    // MARK: MRU

    private static func decodeMRU(_ raw: String) -> [ToolKind] {
        raw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
    }
    private static func encodeMRU(_ mru: [ToolKind]) -> String {
        mru.map(\.rawValue).joined(separator: ",")
    }

    // MARK: Document bridge (main actor)

    @MainActor
    private func loadFromDocument() {
        applyTextDefaults()
        applyAutosavePreference()
        if PrefsSeeding.isNewEmptyPayload(document.payload),
           let resource = PrefsSeeding.templateResourceName(forPrefID: prefDefaultTemplate),
           let template = DrawingTemplate.bundled.first(where: { $0.resourceName == resource }) {
            Task { await seedNewDocument(from: template) }
            return
        }
        let drawing = CADDrawing.make(from: PrefsSeeding.seededPayload(document.payload, defaultUnitRaw: prefDefaultUnitRaw))
        model.setDrawing(drawing, viewSize: model.viewport.size)
        adoptEnvironmentUndo()
        controllerBox.controller?.zoomToFit()
        let n = model.entityCount
        status = n == 0 ? "" : "\(n) entities"
    }

    @MainActor
    private func applyTextDefaults() {
        TextTool.applyAppDefaults(fontStyleName: prefTextFont, height: prefTextHeight)
    }

    @MainActor
    private func applyAutosavePreference() {
        NSDocumentController.shared.autosavingDelay = prefAutosaveEnabled ? PrefsSeeding.autosaveDelaySeconds : 0
    }

    @MainActor
    private func seedNewDocument(from template: DrawingTemplate) async {
        await seedFromTemplate(template)
    }

    @MainActor
    private func seedFromTemplate(_ template: DrawingTemplate) async {
        guard let url = template.fileURL else { status = "Template not found: \(template.displayName)"; return }
        do {
            let data = try Data(contentsOf: url)
            let payload = try await Task.detached { try DXFDocumentCodec.payload(from: data, format: .dxf) }.value
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

    @MainActor
    private func adoptEnvironmentUndo() {
        guard let manager = environmentUndoManager else { return }
        model.adoptUndoManager(manager)
    }

    private var environmentUndoManagerID: ObjectIdentifier? {
        environmentUndoManager.map(ObjectIdentifier.init)
    }

    @MainActor
    private func syncPayloadToDocument() {
        document.updatePayload(model.drawing.payloadSnapshot)
    }

    // MARK: Shared actions (used by sidebar + toolbar)

    private func raiseBlockNamePrompt() {
        guard model.hasSelection else { return }
        suggestedBlockName = model.suggestedBlockName()
        showBlockNamePrompt = true
    }

    // View-layer file pickers for the sidebar's block I/O (the canvas host
    // also has these, but the sidebar needs them without a canvas binding).
    @MainActor
    private func insertBlockFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = LibreCADDocument.dxfTypes
        panel.title = "Insert Block from File"
        panel.prompt = "Insert"
        guard panel.runModal() == .OK, let url = panel.url else { status = "Insert block cancelled"; return }
        let path = url.path
        let displayName = url.lastPathComponent
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockLibrary.importDXF(path: path, into: model.drawing) else { status = "“\(displayName)” has no importable geometry"; return }
                model.drawing.remove(result.insertID)
                model.quadtree.remove(result.insertID)
                _ = model.insertBlockAtViewCenter(named: result.blockName)
                model.modelDirty = true
                model.modelVersion &+= 1
                controllerBox.controller?.requestRedraw()
                status = "Inserted block “\(result.blockName)” from \(displayName)"
            } catch {
                status = "Insert block failed: \(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func saveBlockToFile(named name: String) {
        guard model.drawing.blocks.contains(name) else { status = "No block named “\(name)” to save"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = LibreCADDocument.dxfTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(name).dxf"
        panel.title = "Save Block to File"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { status = "Save block cancelled"; return }
        let path = url.path
        let displayName = url.lastPathComponent
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockExport.writeBlock(model.drawing, name: name, toPath: path) else { status = "Block “\(name)” has no geometry to save"; return }
                status = "Saved block “\(name)” to \(displayName) — \(result.recordCount) elements"
            } catch {
                status = "Save block failed: \(error.localizedDescription)"
            }
        }
    }

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
            controllerBox.controller?.activateTool(.select)
            status = "Image placement cancelled"
            return
        }
        let (pw, ph) = Self.imagePixelSize(of: url)
        model.setImageSourceAndActivate(path: url.path, pixelWidth: pw, pixelHeight: ph)
        controllerBox.controller?.requestRedraw()
        status = "Place image \(url.lastPathComponent) — click two corners"
    }

    private static func imagePixelSize(of url: URL) -> (Double, Double) {
        guard let image = NSImage(contentsOf: url) else { return (1, 1) }
        for rep in image.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            return (Double(rep.pixelsWide), Double(rep.pixelsHigh))
        }
        let s = image.size
        return (s.width > 0 ? Double(s.width) : 1, s.height > 0 ? Double(s.height) : 1)
    }
}

// MARK: - Focused command plumbing (kept here so both hosts see the keys)

extension FocusedValues {
    var openDocumentSettings: (() -> Void)? {
        get { self[OpenDocumentSettingsKey.self] }
        set { self[OpenDocumentSettingsKey.self] = newValue }
    }
    var newFromTemplate: (() -> Void)? {
        get { self[NewFromTemplateKey.self] }
        set { self[NewFromTemplateKey.self] = newValue }
    }
    var focusCommandLine: (() -> Void)? {
        get { self[FocusCommandLineKey.self] }
        set { self[FocusCommandLineKey.self] = newValue }
    }
    var zoomToFit: (() -> Void)? {
        get { self[ZoomToFitKey.self] }
        set { self[ZoomToFitKey.self] = newValue }
    }
    var exportDocument: ((ExportFormat) -> Void)? {
        get { self[ExportDocumentKey.self] }
        set { self[ExportDocumentKey.self] = newValue }
    }
    var printDocument: (() -> Void)? {
        get { self[PrintDocumentKey.self] }
        set { self[PrintDocumentKey.self] = newValue }
    }
    var exportLayout: (() -> Void)? {
        get { self[ExportLayoutKey.self] }
        set { self[ExportLayoutKey.self] = newValue }
    }
    var printLayout: (() -> Void)? {
        get { self[PrintLayoutKey.self] }
        set { self[PrintLayoutKey.self] = newValue }
    }
    var activateTool: ((ToolKind) -> Void)? {
        get { self[ActivateToolKey.self] }
        set { self[ActivateToolKey.self] = newValue }
    }
    var placeImage: (() -> Void)? {
        get { self[PlaceImageKey.self] }
        set { self[PlaceImageKey.self] = newValue }
    }
    var createBlockFromSelection: (() -> Void)? {
        get { self[CreateBlockFromSelectionKey.self] }
        set { self[CreateBlockFromSelectionKey.self] = newValue }
    }
    var insertBlockFromFile: (() -> Void)? {
        get { self[InsertBlockFromFileKey.self] }
        set { self[InsertBlockFromFileKey.self] = newValue }
    }
    var saveBlockToFile: ((String) -> Void)? {
        get { self[SaveBlockToFileKey.self] }
        set { self[SaveBlockToFileKey.self] = newValue }
    }
    var saveBlockTargetName: String? {
        get { self[SaveBlockTargetNameKey.self] }
        set { self[SaveBlockTargetNameKey.self] = newValue }
    }
    var undoAction: (() -> Void)? {
        get { self[UndoActionKey.self] }
        set { self[UndoActionKey.self] = newValue }
    }
    var redoAction: (() -> Void)? {
        get { self[RedoActionKey.self] }
        set { self[RedoActionKey.self] = newValue }
    }
    var deleteSelection: (() -> Void)? {
        get { self[DeleteSelectionKey.self] }
        set { self[DeleteSelectionKey.self] = newValue }
    }
    var duplicateSelection: (() -> Void)? {
        get { self[DuplicateSelectionKey.self] }
        set { self[DuplicateSelectionKey.self] = newValue }
    }
    var matchPropPickUp: (() -> Void)? {
        get { self[MatchPropPickUpKey.self] }
        set { self[MatchPropPickUpKey.self] = newValue }
    }
    var matchPropApply: (() -> Void)? {
        get { self[MatchPropApplyKey.self] }
        set { self[MatchPropApplyKey.self] = newValue }
    }
    var isToolActive: Bool? {
        get { self[IsToolActiveKey.self] }
        set { self[IsToolActiveKey.self] = newValue }
    }
    var toggleInspector: (() -> Void)? {
        get { self[ToggleInspectorKey.self] }
        set { self[ToggleInspectorKey.self] = newValue }
    }
    var toggleCurrentPropertiesBar: (() -> Void)? {
        get { self[ToggleCurrentPropertiesBarKey.self] }
        set { self[ToggleCurrentPropertiesBarKey.self] = newValue }
    }
    var newLayout: (() -> Void)? {
        get { self[NewLayoutKey.self] }
        set { self[NewLayoutKey.self] = newValue }
    }
    var deleteActiveLayout: (() -> Void)? {
        get { self[DeleteActiveLayoutKey.self] }
        set { self[DeleteActiveLayoutKey.self] = newValue }
    }
    var duplicateActiveLayout: (() -> Void)? {
        get { self[DuplicateActiveLayoutKey.self] }
        set { self[DuplicateActiveLayoutKey.self] = newValue }
    }
}

private struct OpenDocumentSettingsKey: FocusedValueKey { typealias Value = () -> Void }
private struct NewFromTemplateKey: FocusedValueKey { typealias Value = () -> Void }
private struct FocusCommandLineKey: FocusedValueKey { typealias Value = () -> Void }
private struct ZoomToFitKey: FocusedValueKey { typealias Value = () -> Void }
private struct ExportDocumentKey: FocusedValueKey { typealias Value = (ExportFormat) -> Void }
private struct PrintDocumentKey: FocusedValueKey { typealias Value = () -> Void }
private struct ExportLayoutKey: FocusedValueKey { typealias Value = () -> Void }
private struct PrintLayoutKey: FocusedValueKey { typealias Value = () -> Void }
private struct ActivateToolKey: FocusedValueKey { typealias Value = (ToolKind) -> Void }
private struct PlaceImageKey: FocusedValueKey { typealias Value = () -> Void }
private struct CreateBlockFromSelectionKey: FocusedValueKey { typealias Value = () -> Void }
private struct InsertBlockFromFileKey: FocusedValueKey { typealias Value = () -> Void }
private struct SaveBlockToFileKey: FocusedValueKey { typealias Value = (String) -> Void }
private struct SaveBlockTargetNameKey: FocusedValueKey { typealias Value = String }
private struct UndoActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct RedoActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct DeleteSelectionKey: FocusedValueKey { typealias Value = () -> Void }
private struct DuplicateSelectionKey: FocusedValueKey { typealias Value = () -> Void }
private struct MatchPropPickUpKey: FocusedValueKey { typealias Value = () -> Void }
private struct MatchPropApplyKey: FocusedValueKey { typealias Value = () -> Void }
private struct IsToolActiveKey: FocusedValueKey { typealias Value = Bool }
private struct ToggleInspectorKey: FocusedValueKey { typealias Value = () -> Void }
private struct ToggleCurrentPropertiesBarKey: FocusedValueKey { typealias Value = () -> Void }
private struct NewLayoutKey: FocusedValueKey { typealias Value = () -> Void }
private struct DeleteActiveLayoutKey: FocusedValueKey { typealias Value = () -> Void }
private struct DuplicateActiveLayoutKey: FocusedValueKey { typealias Value = () -> Void }
