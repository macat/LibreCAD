//
//  PartsLibraryPanel.swift
//  LibreCADmacOS
//
//  The Parts Library sidebar panel — a browsable catalog of reusable `.dxf` symbols
//  from a folder the user chooses. It is the GUI surface over the engine-pure
//  `BlockLibrary` (catalog model + collision-safe import): the panel scans a chosen
//  directory into `BlockLibraryItem`s and, on double-click or drag-to-canvas, imports
//  the chosen symbol into the live drawing as a NAMED block (de-duplicated on a clash —
//  never an in-place overwrite) and places one insert.
//
//  Like the other sidebar panels it is rendered as the BODY of a `SidebarPanel` in the
//  rearrangeable `SidebarPanelStack` (the stack supplies the header; this view supplies
//  the panel's content + a header "Choose Folder…" control). It binds to the SAME live
//  `CanvasModel` the canvas renders, so an import reflects live and undoes via ⌘Z.
//
//  Modal discipline: the "Choose Folder…" `NSOpenPanel` (chooseDirectory) lives ONLY in
//  this View-layer action closure — never in the model / a tool / a test (a modal
//  reached from the headless suite would hang it forever). The directory SCAN and the
//  IMPORT are engine-pure (`BlockLibrary.scan` / `importItem` take a caller-supplied
//  URL), so they carry no picker.
//
//  Persistence: the last-chosen folder is remembered across launches in `@AppStorage`
//  (a single path string), mirroring `ContentView`'s primitive-string store pattern, so
//  reopening the app restores the catalog.
//
//  v1 scope: each item shows a generic SF-Symbol icon + its name. Per-file thumbnail
//  rendering (resolving each `.dxf`'s geometry to a preview tile, like the Blocks panel)
//  is a documented follow-up — it needs an off-main render of each file's records, which
//  is deferred to keep this wave's surface focused on the catalog + import wiring.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import UniformTypeIdentifiers
import CADEngine

// MARK: - Parts Library header control (Choose Folder…)

/// The Parts Library panel's header control: a "Choose Folder…" button that raises the
/// folder `NSOpenPanel` (View layer only) and stores the chosen path. A small reusable
/// view so the panel HEADER can host it; the host supplies the closure so this view
/// stays model-agnostic (the panel owns the picker + scan).
struct PartsLibraryHeaderControls: View {
    let onChooseFolder: () -> Void

    var body: some View {
        Button(action: onChooseFolder) {
            Image(systemName: "folder.badge.plus")
        }
        .buttonStyle(.borderless)
        .help("Choose a folder of .dxf symbols to browse")
    }
}

// MARK: - Parts Library panel content (live)

/// The live Parts Library content: a "Choose Folder…" affordance + the scanned list of
/// `.dxf` symbols in the chosen folder, each importable via double-click or drag-to-
/// canvas. Bound to the live `CanvasModel` so an import reflects immediately and undoes
/// via ⌘Z. The chosen folder persists across launches via `@AppStorage`.
struct PartsLibrarySectionContent: View {
    @Bindable var model: CanvasModel
    /// Bridge to the canvas controller so an import can request a redraw (the renderer is
    /// on-demand; a placed insert must nudge it).
    let controllerBox: CADCanvasView.ControllerBox
    /// A "tick" the panel HEADER's "Choose Folder…" button flips to ask THIS body to
    /// raise its folder picker (so the `NSOpenPanel` stays in the body's View layer). The
    /// value is meaningless — only its CHANGE triggers the picker (see `onChange` below).
    let chooseFolderTick: Bool

    /// The last-chosen library folder path, persisted across launches. Empty = none
    /// chosen yet (the panel shows the "Choose Folder…" prompt). A single primitive
    /// string store, mirroring `ContentView`'s `commandBar.mru` / sidebar-layout stores.
    @AppStorage("partsLibrary.folderPath") private var folderPath: String = ""

    /// The current catalog (scanned from `folderPath`). Re-scanned on appear + whenever
    /// the folder changes; an absent/empty folder yields an empty catalog (never throws).
    @State private var items: [BlockLibraryItem] = []
    /// A transient status line under the list (last import result / error / empty note).
    @State private var note: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            folderRow
            content
            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .onAppear { rescan() }
        // Re-scan when the persisted folder changes (e.g. a Choose Folder… elsewhere).
        .onChange(of: folderPath) { _, _ in rescan() }
        // The panel header's "Choose Folder…" button flips the tick → raise the picker.
        .onChange(of: chooseFolderTick) { _, _ in chooseFolder() }
    }

    // MARK: Subviews (decomposed for the SwiftUI type-checker)

    /// The current-folder row: the folder name (or a prompt) + a "Choose Folder…" button.
    @ViewBuilder
    private var folderRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(folderDisplayName)
                .font(.callout)
                .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Choose Folder…") { chooseFolder() }
                .controlSize(.small)
        }
    }

    /// The catalog list (or an empty-state prompt).
    @ViewBuilder
    private var content: some View {
        if folderPath.isEmpty {
            Text("Choose a folder of .dxf symbols to build a parts library.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if items.isEmpty {
            Text("No .dxf symbols in this folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(items) { item in
                PartRow(item: item, onInsert: { insert(item) })
                    // Drag-to-place: the canvas drop target decodes this and imports the
                    // file at the drop point (the canvas-side drop handler owns placement;
                    // the panel provides the source). Carries the file URL as a path.
                    .draggable(PartLibraryDragItem(filePath: item.url.path, name: item.name))
                    .contextMenu {
                        Button("Insert at View Center") { insert(item) }
                    }
            }
        }
    }

    // MARK: Display

    /// A friendly name for the chosen folder (its last path component), or a prompt.
    private var folderDisplayName: String {
        guard !folderPath.isEmpty else { return "No folder chosen" }
        let name = URL(fileURLWithPath: folderPath).lastPathComponent
        return name.isEmpty ? folderPath : name
    }

    // MARK: Actions

    /// Raise the folder picker (View-layer `NSOpenPanel`, chooseDirectory only), store
    /// the chosen path (which triggers a re-scan via `onChange`). The picker MUST stay
    /// here in the View layer — never in the model / a tool / a test (headless-hang trap).
    @MainActor
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.title = "Choose a Parts Library Folder"
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path   // onChange → rescan
    }

    /// Re-scan the chosen folder into the catalog (engine-pure; no picker). An absent /
    /// empty / unreadable folder yields an empty catalog (never throws).
    private func rescan() {
        guard !folderPath.isEmpty else {
            items = []
            return
        }
        items = BlockLibrary.scan(directory: URL(fileURLWithPath: folderPath, isDirectory: true))
        if items.isEmpty {
            note = ""
        }
    }

    /// Import a catalog item into the drawing as a named block and place ONE insert at
    /// the view center (double-click / context "Insert"). Collision-safe (the engine
    /// de-dups a clashing name). The engine import drops the insert at the origin; we
    /// re-place it at the view center via the model's insert path (which syncs the index
    /// + selection), then redraw. Errors/empties land in the panel's note line.
    private func insert(_ item: BlockLibraryItem) {
        let url = item.url
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let result = try await BlockLibrary.importItem(item, into: model.drawing) else {
                    note = "“\(item.name)” has no importable geometry"
                    return
                }
                // Re-place the origin-dropped insert at the view center (selectable/snappable).
                model.drawing.remove(result.insertID)
                model.quadtree.remove(result.insertID)
                _ = model.insertBlockAtViewCenter(named: result.blockName)
                model.modelDirty = true
                model.modelVersion &+= 1
                controllerBox.controller?.requestRedraw()
                note = "Inserted “\(result.blockName)”"
            } catch {
                note = "Import failed: \(error.localizedDescription)"
                NSLog("PartsLibrary: import failed: \(error)")
            }
        }
    }
}

// MARK: - One parts-library row

/// A single parts-library symbol row: a generic icon + the symbol name + an Insert
/// button. v1 uses a generic SF-Symbol glyph (per-file thumbnail rendering is a
/// documented follow-up). Double-click and the Insert button both import + place.
private struct PartRow: View {
    let item: BlockLibraryItem
    let onInsert: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onInsert) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Insert this symbol at the view center")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Double-click the row to import + place (a common gallery affordance).
        .onTapGesture(count: 2) { onInsert() }
    }
}

// MARK: - Drag payload (file → canvas)

/// A drag payload carrying a parts-library file path + name from the Parts Library list
/// to the canvas (so a drop can import that symbol at the drop point). A `Transferable`
/// wrapper — the canvas-side drop target (owned by the canvas layer) decodes this and
/// imports the file via `BlockLibrary.importDXF`/`importItem`; the panel provides the
/// source so drag-to-place is wired from this side.
struct PartLibraryDragItem: Codable, Transferable {
    let filePath: String
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .partLibraryDragItem)
    }
}

extension UTType {
    /// A private UTI for the parts-library drag payload (drag-to-place).
    static let partLibraryDragItem = UTType(exportedAs: "org.librecad.macos.part-library-drag-item")
}
