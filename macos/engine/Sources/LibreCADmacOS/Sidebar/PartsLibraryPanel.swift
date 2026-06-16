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
    /// chosen yet — the panel then falls back to the BUNDLED starter symbols so it is
    /// non-empty on first launch (backlog #6). A user folder, once chosen, overrides
    /// the bundled default. A single primitive string store, mirroring `ContentView`'s
    /// `commandBar.mru` / sidebar-layout stores.
    @AppStorage("partsLibrary.folderPath") private var folderPath: String = ""

    /// The current catalog (scanned from the EFFECTIVE source directory). Re-scanned on
    /// appear + whenever the folder changes; an absent/empty folder yields an empty
    /// catalog (never throws).
    @State private var items: [BlockLibraryItem] = []
    /// A transient status line under the list (last import result / error / empty note).
    @State private var note: String = ""

    /// Whether the catalog currently shown is the BUNDLED starter library (no user
    /// folder chosen) rather than a user-chosen folder. Drives the "Built-in" section
    /// label and the choice of empty-state vs. starter list. Mirrors `isUsingBuiltIn`
    /// in `effectiveSource`.
    private var isUsingBuiltIn: Bool { folderPath.isEmpty }

    /// The directory the catalog is scanned from: the user's chosen folder if one is
    /// set, otherwise the bundled starter-symbol directory (backlog #6). `nil` only if
    /// no folder is chosen AND the bundled directory cannot be resolved (e.g. a bare
    /// binary with no app bundle and no in-repo assets) — then the panel shows its
    /// empty-state with the "Choose Folder…" CTA, exactly as before.
    private var effectiveSource: URL? {
        if !folderPath.isEmpty {
            return URL(fileURLWithPath: folderPath, isDirectory: true)
        }
        return BlockLibrary.bundledSymbolsDirectory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            // The chosen-folder row only appears once a folder IS chosen; with no folder
            // the body is just the empty-state (which carries its own "Choose Folder…"
            // CTA), so there's no redundant prompt row.
            if !folderPath.isEmpty {
                folderRow
            }
            content
            if !note.isEmpty {
                Text(note)
                    .font(DS.Font.hint)
                    .foregroundStyle(.secondary)
                    // Wrap the status/error line instead of clipping it to 2 lines.
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Finder drop: drag .dxf file(s) onto the panel to import the first directly via
        // the existing import path (places one insert at the view center). Non-.dxf URLs
        // are ignored; an empty match is a no-op (the drop is declined). This is a panel-
        // local convenience and does NOT change the catalog source (#6, optional).
        .dropDestination(for: URL.self) { urls, _ in
            let dxf = urls.filter { $0.pathExtension.lowercased() == "dxf" }
            guard let first = dxf.first else { return false }
            importURL(first)
            return true
        }
        .onAppear { rescan() }
        // Re-scan when the persisted folder changes (e.g. a Choose Folder… elsewhere).
        .onChange(of: folderPath) { _, _ in rescan() }
        // The panel header's "Choose Folder…" button flips the tick → raise the picker.
        .onChange(of: chooseFolderTick) { _, _ in chooseFolder() }
    }

    // MARK: Subviews (decomposed for the SwiftUI type-checker)

    /// The current-folder row: the chosen folder's NAME (last path component) with the
    /// FULL path in a tooltip — no middle truncation, no duplicate Choose-Folder button
    /// (the panel header's `folder.badge.plus` is the single chooser affordance). Shown
    /// only when a folder is chosen.
    @ViewBuilder
    private var folderRow: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(folderDisplayName)
                .font(DS.Font.rowLabel)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(folderPath)   // full path on hover (resolves the truncation conflict)
            Spacer(minLength: 0)
        }
    }

    /// The catalog list (or a unified empty-state). The effective source decides:
    ///  - No user folder AND bundled starter symbols present → the starter list under a
    ///    "Built-in" section header (so the panel is non-empty on first launch — #6).
    ///  - No user folder AND no resolvable bundled directory → the shared
    ///    `SidebarEmptyState` with a "Choose Folder…" CTA (the only body chooser).
    ///  - A user folder that is empty → a plain note.
    ///  - Any non-empty source → the symbol rows.
    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            if isUsingBuiltIn {
                // No user folder AND the bundled library is empty/unresolvable: keep the
                // original empty-state so the user can still point the panel somewhere.
                SidebarEmptyState(
                    icon: "puzzlepiece.extension",
                    title: "No symbols available",
                    cta: (label: "Choose Folder…", action: { chooseFolder() })
                )
            } else {
                Text("No .dxf symbols in this folder.")
                    .font(DS.Font.rowLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            if isUsingBuiltIn {
                builtInHeader
            }
            symbolRows
        }
    }

    /// A small "Built-in" section header shown above the bundled starter symbols when no
    /// user folder is chosen, so the user can tell the starter set apart from a folder
    /// they pick. Choosing a folder (header button or context CTA) replaces these.
    @ViewBuilder
    private var builtInHeader: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text("Built-in")
                .font(DS.Font.hint)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// The symbol rows for the current catalog — each importable via double-click, the
    /// Insert button, drag-to-canvas, or the context menu. Shared by the built-in and
    /// user-folder cases (the source differs, the row affordances do not).
    @ViewBuilder
    private var symbolRows: some View {
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

    // MARK: Display

    /// A friendly name for the chosen folder — its last path component (the full path is
    /// shown in the row's `.help()` tooltip). Falls back to the raw path for an
    /// unusual/rootless path. (Only read when a folder IS chosen — see `folderRow`.)
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

    /// Re-scan the EFFECTIVE source into the catalog (engine-pure; no picker): the user's
    /// chosen folder if one is set, otherwise the bundled starter library (backlog #6).
    /// An absent / empty / unreadable / unresolvable source yields an empty catalog
    /// (never throws).
    private func rescan() {
        guard let source = effectiveSource else {
            items = []
            return
        }
        items = BlockLibrary.scan(directory: source)
        if items.isEmpty {
            note = ""
        }
    }

    /// Import an arbitrary `.dxf` file URL (e.g. a Finder drop onto the panel) via the
    /// existing item-import path — derives a `BlockLibraryItem` (name from the file's
    /// base name) and delegates to `insert`. Does NOT add the file to the catalog (it may
    /// live outside the chosen folder); it just imports + places one insert.
    private func importURL(_ url: URL) {
        insert(BlockLibraryItem(url: url))
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
        HStack(spacing: DS.Space.md) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
                .frame(width: DS.Size.rowIcon, height: DS.Size.rowIcon)
            Text(item.name)
                .font(DS.Font.rowLabel)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onInsert) {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.borderless)
            .help("Insert this symbol at the view center")
        }
        .padding(.vertical, DS.Space.xs)
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
