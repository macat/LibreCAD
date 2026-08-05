//
//  CanvasContainerView.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 2 — ContentView decomposition. Hosts the interactive
//  Metal canvas + HUD + overlays + safeAreaInsets + bottom chrome.
//  Verbatim extraction of ContentView.canvasDetail plus its focused
//  scene-value wiring, sliced into ViewBuilders <150 so the type-checker
//  stays cheap. Observation is scoped: the canvas viewport reads
//  ViewportModel/InteractionModel slices via CanvasModel projections, and
//  bottom chrome sub-views use Equatable gating where cheap.
//
//  GPLv2-or-later.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CADEngine

/// The canvas detail container — the former `ContentView.canvasDetail`
/// plus bottom chrome and overlay hosts. ContentView composes this
/// via @ViewBuilder so it stays a thin orchestrator.
struct CanvasContainerView: View {
    @Bindable var model: CanvasModel
    let controllerBox: CADCanvasView.ControllerBox

    @Binding var status: String
    @Binding var showInspector: Bool
    @Binding var showPalette: Bool
    @Binding var showSettings: Bool
    @Binding var showTemplateChooser: Bool
    @Binding var showBlockNamePrompt: Bool
    @Binding var suggestedBlockName: String
    @Binding var commandLineText: String
    var commandLineFocused: FocusState<Bool>.Binding
    @Binding var showCommandTranscript: Bool
    @Binding var showCurrentPropertiesBar: Bool
    @Binding var pinnedToolsRaw: String

    // MARK: - Body — thin composition (<150)

    var body: some View {
        canvasWithOverlays
            .modifier(CommandPaletteModifier(isPresented: $showPalette, commands: paletteCommands))
            .sheet(isPresented: $showSettings) { DocumentSettingsView(model: model, controllerBox: controllerBox) }
            .sheet(isPresented: $showTemplateChooser) { templateChooserSheet }
            .sheet(isPresented: $showBlockNamePrompt) { blockNameSheet }
            .onDisappear { _ = model.finishBlockEditingIfNeeded() }
            .focusedSceneValue(\.openDocumentSettings) { showSettings = true }
            .focusedSceneValue(\.newFromTemplate) { showTemplateChooser = true }
            .focusedSceneValue(\.createBlockFromSelection, model.hasSelection ? { raiseBlockNamePrompt() } : nil)
            .modifier(BlockFileHandlersModifier(insertFromFile: { insertBlockFromFile() }, saveToFile: { name in saveBlockToFile(named: name) }, saveTargetName: saveBlockTargetName))
            .focusedSceneValue(\.commandPalette) { showPalette = true }
            .focusedSceneValue(\.zoomToFit) { controllerBox.controller?.zoomToFit() }
            .focusedSceneValue(\.exportDocument) { format in Task { await exportDrawing(format) } }
            .focusedSceneValue(\.printDocument) { printDrawing() }
            .modifier(LayoutPlotHandlersModifier(exportLayout: model.activeLayoutRecord != nil ? { Task { @MainActor in exportActiveLayoutPDF() } } : nil, printLayout: model.activeLayoutRecord != nil ? { printActiveLayout() } : nil))
            .modifier(ShellMenuHandlersModifier(toggleInspector: { showInspector.toggle() }, toggleCurrentPropertiesBar: { showCurrentPropertiesBar.toggle() }, newLayout: { _ = model.newLayout() }, deleteActiveLayout: activeLayoutName.map { name in { _ = model.deleteLayout(name) } }, duplicateActiveLayout: activeLayoutName.map { name in { _ = model.duplicateLayout(name) } }))
            .modifier(ToolActionHandlersModifier(activateTool: { kind in controllerBox.controller?.activateTool(kind) }, placeImage: { chooseAndPlaceImage() }, undo: { model.undo() }, redo: { model.redo() }, delete: { if model.deleteSelection() { controllerBox.controller?.requestRedraw() } }, duplicate: { if model.duplicateSelection() { controllerBox.controller?.requestRedraw() } }))
            .focusedSceneValue(\.isToolActive, model.isToolActive)
            .modifier(MatchPropHandlersModifier(pickUp: { _ = model.loadPaintBrushFromSelection() }, apply: { if model.applyPaintBrushToSelection() { controllerBox.controller?.requestRedraw() } }))
            .onAppear { onCanvasAppear() }
            .focusedSceneValue(\.focusCommandLine) { commandLineFocused.wrappedValue = true }
            .onKeyPress("/") { commandLineFocused.wrappedValue = true; return .handled }
    }

    // MARK: Canvas composition (<150 each)

    @ViewBuilder
    private var canvasWithOverlays: some View {
        canvasViewport
            .overlay(alignment: .topLeading) { statusHUD }
            .overlay(alignment: .topTrailing) { visibilityStatesPanel }
            .safeAreaInset(edge: .top, spacing: 0) { topToolOptions }
            .safeAreaInset(edge: .top, spacing: 0) { currentPropertiesInset }
            .safeAreaInset(edge: .top, spacing: 0) { blockEditInset }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
    }

    // MARK: Viewport

    @ViewBuilder
    private var canvasViewport: some View {
        CADCanvasView(model: model, controllerBox: controllerBox)
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            .dropDestination(for: PartLibraryDragItem.self) { items, location in
                guard let item = items.first else { return false }
                dropPartLibraryItem(item, atScreenPoint: location)
                return true
            }
    }

    // MARK: Overlays

    @ViewBuilder
    private var statusHUD: some View {
        Text(status)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .opacity(status.isEmpty ? 0 : 1)
    }

    @ViewBuilder
    private var visibilityStatesPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            BlockVisibilityStatesPanel(model: model, controllerBox: controllerBox)
            BlockDynamicParametersPanel(model: model, controllerBox: controllerBox)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    // MARK: Top insets

    @ViewBuilder
    private var topToolOptions: some View {
        ToolOptionsBar(model: model, controllerBox: controllerBox)
    }

    @ViewBuilder
    private var currentPropertiesInset: some View {
        if showCurrentPropertiesBar {
            CurrentPropertiesBar(model: model, controllerBox: controllerBox)
        }
    }

    @ViewBuilder
    private var blockEditInset: some View {
        BlockEditBar(model: model) { controllerBox.controller?.requestRedraw() }
    }

    // MARK: Bottom chrome

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            layoutTabs
            transcriptView
            commandLineRow
            statusBar
        }
    }

    @ViewBuilder
    private var layoutTabs: some View {
        LayoutTabStrip(
            model: model,
            onSelectModel: { model.activateModel(); controllerBox.controller?.requestRedraw() },
            onSelectLayout: { name in model.activateLayout(name: name); controllerBox.controller?.requestRedraw() },
            onAddLayout: { model.newLayout(); controllerBox.controller?.requestRedraw() },
            onSelectBlockEdit: { controllerBox.controller?.requestRedraw() },
            onRenameLayout: { name, newName in if model.renameLayout(name, to: newName) { controllerBox.controller?.requestRedraw() } },
            onDeleteLayout: { name in if model.deleteLayout(name) { controllerBox.controller?.requestRedraw() } },
            onDuplicateLayout: { name in if model.duplicateLayout(name) != nil { controllerBox.controller?.requestRedraw() } },
            onPageSetup: { name, page in if model.setLayoutPage(name, page) { controllerBox.controller?.requestRedraw() } }
        )
    }

    @ViewBuilder
    private var transcriptView: some View {
        if showCommandTranscript {
            CommandTranscriptView(model: model)
        }
    }

    @ViewBuilder
    private var commandLineRow: some View {
        HStack(spacing: 0) {
            transcriptToggle
            CommandLineBar(
                model: model,
                text: $commandLineText,
                focused: commandLineFocused,
                pinned: pinnedToolsSet,
                activateTool: { kind in controllerBox.controller?.activateTool(kind) },
                placeImage: { chooseAndPlaceImage() },
                returnFocusToCanvas: { controllerBox.controller?.returnFocusToCanvas() },
                requestRedraw: { controllerBox.controller?.requestRedraw() }
            )
        }
    }

    @ViewBuilder
    private var transcriptToggle: some View {
        Button { showCommandTranscript.toggle() } label: {
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

    @ViewBuilder
    private var statusBar: some View {
        StatusBar(model: model, requestRedraw: { controllerBox.controller?.requestRedraw() })
    }

    // MARK: Sheets

    @ViewBuilder
    private var templateChooserSheet: some View {
        TemplateChooserView(
            templates: DrawingTemplate.bundled,
            onChoose: { template in
                showTemplateChooser = false
                Task { await seedFromTemplate(template) }
            },
            onCancel: { showTemplateChooser = false }
        )
    }

    @ViewBuilder
    private var blockNameSheet: some View {
        BlockNamePrompt(
            suggestedName: suggestedBlockName,
            existingNames: model.drawing.blocks.blocks.map(\.name),
            onConfirm: { name in
                showBlockNamePrompt = false
                if model.beginCreateBlock(name: name) { controllerBox.controller?.requestRedraw() }
            },
            onCancel: { showBlockNamePrompt = false }
        )
    }

    // MARK: Toolbar (inspector toggle) — kept here so window toolbar stays window-scoped

    @ToolbarContentBuilder
    private var inspectorToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { _ = model.loadPaintBrushFromSelection() } label: {
                Label("Match Properties", systemImage: "eyedropper")
            }
            .help("Match Properties — pick up the selected object's properties (⌘⇧C), then apply to a new selection (⌘⇧V)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the Inspector")
        }
    }

    // MARK: Helpers — lightweight copies from ContentView

    private var activeLayoutName: String? { model.activeLayout }

    private var pinnedToolsSet: Set<ToolKind> {
        guard pinnedToolsRaw.hasPrefix("•") else { return ToolCatalog.defaultPrimary }
        let body = String(pinnedToolsRaw.dropFirst(1))
        let kinds = body.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
        return Set(kinds)
    }

    private var saveBlockTargetName: String? {
        BlockFileMenuWiring.saveTargetName(selectionIDs: model.selection.ids, in: model.drawing)
    }

    private func raiseBlockNamePrompt() {
        guard model.hasSelection else { return }
        suggestedBlockName = model.suggestedBlockName()
        showBlockNamePrompt = true
    }

    private func onCanvasAppear() {
        controllerBox.controller?.requestCommandFocus = { commandLineFocused.wrappedValue = true }
        controllerBox.controller?.requestShowInspector = { showInspector = true }
        controllerBox.controller?.requestDocumentSettings = { showSettings = true }
        controllerBox.controller?.requestCreateBlockFromSelection = { raiseBlockNamePrompt() }
    }

    // MARK: Palette

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
            importMergeDXF: { sendDocumentAction(Selector(("importMergeDXFAction:"))) },
            dimensionStyleManager: { sendDocumentAction(Selector(("dimStyleManagerAction:"))) },
            saveNamedView: { sendDocumentAction(Selector(("saveNamedViewAction:"))) },
            restoreNamedView: { sendDocumentAction(Selector(("restoreNamedViewAction:"))) },
            insertBlockFromFile: { insertBlockFromFile() },
            saveBlockToFile: { if let name = saveBlockTargetName { saveBlockToFile(named: name) } },
            newLayout: { _ = model.newLayout() },
            applyGeometricConstraint: { kind in sendDocumentAction(Selector((Self.geometricConstraintSelector(kind)))) },
            applyDimensionalConstraint: { kind in sendDocumentAction(Selector((Self.dimensionalConstraintSelector(kind)))) },
            insertField: { token in sendDocumentAction(Selector((Self.fieldInsertSelector(token)))) },
            parametersManager: { sendDocumentAction(Selector(("parametersManagerAction:"))) }
        ))
    }

    private static func geometricConstraintSelector(_ kind: GeometricConstraintKind) -> String {
        switch kind {
        case .coincident:    return "applyCoincidentConstraintAction:"
        case .horizontal:    return "applyHorizontalConstraintAction:"
        case .vertical:      return "applyVerticalConstraintAction:"
        case .parallel:      return "applyParallelConstraintAction:"
        case .perpendicular: return "applyPerpendicularConstraintAction:"
        case .collinear:     return "applyCollinearConstraintAction:"
        case .concentric:    return "applyConcentricConstraintAction:"
        case .equal:         return "applyEqualConstraintAction:"
        case .fix:           return "applyFixConstraintAction:"
        case .tangent, .symmetric: return "applyFixConstraintAction:"
        }
    }

    private static func dimensionalConstraintSelector(_ kind: DimensionalConstraintKind) -> String {
        switch kind {
        case .distance:           return "applyDistanceConstraintAction:"
        case .radius:             return "applyRadiusConstraintAction:"
        case .diameter:           return "applyDiameterConstraintAction:"
        case .angle:              return "applyAngleConstraintAction:"
        case .horizontalDistance: return "applyHorizontalDistanceConstraintAction:"
        case .verticalDistance:   return "applyVerticalDistanceConstraintAction:"
        }
    }

    private static func fieldInsertSelector(_ token: FieldToken) -> String {
        switch token {
        case .date:           return "insertDateFieldAction:"
        case .layoutName:     return "insertLayoutNameFieldAction:"
        case .fileName:       return "insertFileNameFieldAction:"
        case .objectProperty: return "insertDateFieldAction:"
        }
    }

    private func sendDocumentAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    // MARK: Export / Print / Image / Block

    @MainActor
    private func exportDrawing(_ format: ExportFormat) async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Drawing"
        panel.prompt = "Export"
        let options = ExportOptionsState(format: format)
        applyExportFormat(format, to: panel)
        panel.accessoryView = exportAccessoryView(options: options, panel: panel)
        guard panel.runModal() == .OK, let url = panel.url else { status = "Export cancelled"; return }
        let chosen = options.format
        let finalURL = url.deletingPathExtension().appendingPathExtension(chosen.fileExtension)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let count = try DrawingExporter.export(model.drawing, to: finalURL, format: chosen, dpi: options.effectiveDPI, jpegQuality: options.jpegQuality, space: DrawingExporter.exportSpace(forActiveSpace: model.activeSpace, layout: model.activeLayout))
            status = "Exported \(finalURL.lastPathComponent) — \(count) elements"
            NSLog("CADCanvas: exported \(count) elements to \(finalURL.lastPathComponent)")
        } catch {
            status = "Export failed: \(error.localizedDescription)"
            NSLog("CADCanvas: export failed: \(error)")
        }
    }

    @MainActor
    private func applyExportFormat(_ format: ExportFormat, to panel: NSSavePanel) {
        panel.allowedContentTypes = [format.utType]
        let current = panel.nameFieldStringValue
        let base = current.isEmpty ? exportBaseName : (current as NSString).deletingPathExtension
        let stem = base.isEmpty ? exportBaseName : base
        panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
    }

    @MainActor
    private func exportAccessoryView(options: ExportOptionsState, panel: NSSavePanel) -> NSView {
        let accessory = ExportOptionsAccessory(options: options) { [weak panel] newFormat in
            guard let panel else { return }
            applyExportFormat(newFormat, to: panel)
        }
        let host = NSHostingView(rootView: accessory)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.setFrameSize(host.fittingSize)
        return host
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

    private var exportBaseName: String {
        let title = NSApp.keyWindow?.title ?? ""
        let trimmed = title.replacingOccurrences(of: " — Edited", with: "")
        return trimmed.isEmpty ? "Drawing" : trimmed
    }

    @MainActor
    private func printDrawing() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !DrawingPrinter.print(model.drawing, in: window, space: DrawingExporter.exportSpace(forActiveSpace: model.activeSpace, layout: model.activeLayout)) {
            status = "Print cancelled"
        }
    }

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
                NSLog("CADCanvas: insert block from file failed: \(error)")
            }
        }
    }

    @MainActor
    private func dropPartLibraryItem(_ dragItem: PartLibraryDragItem, atScreenPoint screenPoint: CGPoint) {
        let world = model.viewport.screenToWorld(screenPoint)
        let url = URL(fileURLWithPath: dragItem.filePath)
        let item = BlockLibraryItem(name: dragItem.name, url: url)
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockLibrary.importItem(item, into: model.drawing) else { status = "“\(dragItem.name)” has no importable geometry"; return }
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
                NSLog("CADCanvas: save block to file failed: \(error)")
            }
        }
    }

    @MainActor
    private func exportActiveLayoutPDF() {
        guard let layout = model.activeLayoutRecord else { status = "Open a layout tab to export a layout sheet"; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(exportBaseName)-\(layout.name).pdf"
        panel.title = "Export Layout “\(layout.name)” to PDF"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { status = "Layout export cancelled"; return }
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

    @MainActor
    private func printActiveLayout() {
        guard let layout = model.activeLayoutRecord else { status = "Open a layout tab to print a layout sheet"; return }
        let scene = model.layoutExportScene(for: layout)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if !DrawingPrinter.printLayout(layout, scene: scene, in: window) { status = "Layout print cancelled" }
    }

    @MainActor
    private func seedFromTemplate(_ template: DrawingTemplate) async {
        guard let url = template.fileURL else { status = "Template not found: \(template.displayName)"; return }
        do {
            let data = try Data(contentsOf: url)
            let payload = try await Task.detached { try DXFDocumentCodec.payload(from: data, format: .dxf) }.value
            let drawing = CADDrawing.make(from: payload)
            model.setDrawing(drawing, viewSize: model.viewport.size)
            controllerBox.controller?.zoomToFit()
            status = "New from \(template.displayName) — \(model.entityCount) " + (model.entityCount == 1 ? "entity" : "entities")
        } catch {
            status = "Template load failed: \(error.localizedDescription)"
            NSLog("CADCanvas: template load failed: \(error)")
        }
    }
}

// MARK: - Focused handlers (internal copies so CanvasContainerView is self-contained)

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

private struct LayoutPlotHandlersModifier: ViewModifier {
    let exportLayout: (() -> Void)?
    let printLayout: (() -> Void)?
    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.exportLayout, exportLayout)
            .focusedSceneValue(\.printLayout, printLayout)
    }
}

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

private struct MatchPropHandlersModifier: ViewModifier {
    let pickUp: () -> Void
    let apply: () -> Void
    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.matchPropPickUp) { pickUp() }
            .focusedSceneValue(\.matchPropApply) { apply() }
    }
}

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
