//
//  CommandPalette.swift
//  LibreCADmacOS
//
//  The ⌘K command palette: a centered, fuzzy-searchable overlay that can find
//  and run ANY tool or app action by typing — the hallmark "command palette" of
//  a modern Mac app (Xcode/VS Code style).
//
//  Three pieces live here:
//    - `PaletteCommand`   — one runnable entry: a title, an optional shortcut
//                           hint (shown right-aligned), and an action closure.
//    - `CommandRegistry`  — assembles the full command list: every `ToolKind`
//                           (activates the tool via the SAME controller call the
//                           toolbar uses) plus the main app actions (Open, Save,
//                           Save As, Export PDF/PNG/SVG, Print, Zoom to Fit,
//                           Undo, Redo, toggle Inspector, toggle Grid). Each app
//                           action fires exactly the focused-scene-value closure
//                           the menu fires.
//    - `CommandPalette`   — the SwiftUI overlay: dim backdrop, search field,
//                           ranked result list. Esc dismisses, ↑/↓ navigate,
//                           Return runs the highlighted command. Filtering +
//                           ranking is delegated to the pure `CommandMatcher`
//                           in CADEngine (unit-tested there).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import CADEngine

// MARK: - One command

/// A single runnable palette entry. `id` is stable for `ForEach`; `shortcut` is
/// a display-only hint (e.g. "⌘S", "C") shown right-aligned; `run` performs the
/// action when the user picks it.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let shortcut: String?
    let run: () -> Void

    init(id: String,
         title: String,
         systemImage: String,
         shortcut: String? = nil,
         run: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.run = run
    }
}

// MARK: - Registry

/// Builds the palette's command list. The app actions are passed in as closures
/// (the focused-scene-value handlers ContentView already wires for the menus), so
/// running an app command from the palette is byte-for-byte the same as choosing
/// it from the menu. Tool commands call the controller's `activateTool` — the
/// exact call the toolbar button makes.
enum CommandRegistry {

    /// Inputs needed to build the list. All are the live closures/objects the
    /// window already owns; nothing here reaches into private model state.
    struct Actions {
        var activateTool: (ToolKind) -> Void
        /// Begin Image placement (the file-picker → two-click flow). The `.image`
        /// kind needs a file chosen up front, so its palette entry routes here instead
        /// of through the bare `activateTool`.
        var placeImage: () -> Void
        /// Raise the "Create Block from Selection…" name sheet (WAVE BW, Ask #1). The
        /// `.createBlock` kind asks for a NAME first (spec §2.1), so its palette entry
        /// routes here instead of through the bare `activateTool`.
        var createBlockFromSelection: () -> Void
        var open: () -> Void
        var save: () -> Void
        var saveAs: () -> Void
        var export: (ExportFormat) -> Void
        var print: () -> Void
        var zoomToFit: () -> Void
        var undo: () -> Void
        var redo: () -> Void
        var toggleInspector: () -> Void
        var toggleGrid: () -> Void
        var documentSettings: () -> Void
    }

    /// SF Symbol + shortcut hint for each tool, mirroring the toolbar/menu so the
    /// palette reads consistently. Keyed by `ToolKind`.
    private static func glyph(for kind: ToolKind) -> (symbol: String, shortcut: String?) {
        switch kind {
        case .select:      return ("cursorarrow", "V")
        case .line:        return ("line.diagonal", "L")
        case .circle:      return ("circle", "C")
        case .arc:         return ("point.topleft.down.to.point.bottomright.curvepath", "A")
        case .rectangle:   return ("rectangle", "R")
        case .polyline:    return ("scribble", "P")
        case .point:       return ("smallcircle.filled.circle", "O")
        case .move:        return ("arrow.up.and.down.and.arrow.left.and.right", "M")
        case .copy:        return ("plus.square.on.square", "⇧C")
        case .rotate:      return ("rotate.right", "⇧R")
        case .scale:       return ("square.resize", "⇧S")
        case .mirror:      return ("flip.horizontal", "⇧M")
        case .ellipse:     return ("oval", "E")
        case .polygon:     return ("hexagon", "G")
        case .offset:      return ("plus.rectangle.on.rectangle", "⇧O")
        case .trim:        return ("scissors", "T")
        case .extend:      return ("arrow.right.to.line", "X")
        case .fillet:      return ("circle.bottomrighthalf.checkered", "F")
        case .chamfer:     return ("skew", "⇧F")
        case .spline:      return ("scribble.variable", "S")
        case .array:       return ("square.grid.3x3", "⇧A")
        case .divide:      return ("divide", "⇧D")
        case .explode:     return ("burst", "⇧X")
        case .hatch:       return ("square.grid.2x2.fill", "H")
        case .text:        return ("character.textbox", "⇧T")
        case .linearDim:   return ("ruler", "D")
        case .alignedDim:  return ("arrow.up.left.and.arrow.down.right", "I")
        case .radialDim:   return ("arrow.left.and.right", "U")
        case .diameterDim: return ("circle.and.line.horizontal", "B")
        case .angularDim:  return ("angle", "N")
        case .stretch:     return ("arrow.left.and.right.righttriangle.left.righttriangle.right", "⌥S")
        case .lengthen:    return ("ruler", "⇧L")
        case .break:       return ("scissors.badge.ellipsis", "⇧B")
        case .insert:      return ("square.on.square.dashed", "⇧I")
        case .polylineEdit: return ("point.topleft.down.to.point.bottomright.curvepath.fill", "⇧P")
        // Wire-wave-1: measure variants (distance keyed ⇧K; the other modes are
        // menu/⌘K only), Join (⇧J), Explode Text (⇧E).
        case .measureDistance: return ("ruler", "⇧K")
        case .measureAngle:    return ("angle", nil)
        case .measureArea:     return ("square.dashed", nil)
        case .measureLength:   return ("sum", nil)
        case .join:            return ("link", "⇧J")
        case .explodeText:     return ("character.cursor.ibeam", "⇧E")
        // Wire-wave-2: three dimension subtypes (ordinate ⌥O, arc-length ⌥G,
        // angular-3p ⌥N) + Create Block (⌥B) + Explode Block (⌥X).
        case .ordinateDim:     return ("arrow.down.to.line", "⌥O")
        case .arcLengthDim:    return ("arrow.up.and.down.and.sparkles", "⌥G")
        case .angular3pDim:    return ("angle", "⌥N")
        case .createBlock:     return ("square.on.square.dashed", "⌥B")
        case .explodeInsert:   return ("square.split.2x2", "⌥X")
        // Wire-wave-3: construction lines (⌥I/⌥Y), Align (⌥A) + Array Along Path (⌥P),
        // and the annotate tools — Leader (⌥L), Baseline (⌥D), Continue (⌥C).
        case .xline:           return ("line.diagonal.arrow", "⌥I")
        case .ray:             return ("arrow.up.right", "⌥Y")
        case .align:           return ("arrow.up.and.down.righttriangle.up.righttriangle.down", "⌥A")
        case .arrayPath:       return ("point.topleft.down.to.point.bottomright.curvepath", "⌥P")
        case .leader:          return ("text.bubble", "⌥L")
        case .multileader:     return ("text.bubble.fill", "⌥M")
        case .baselineDim:     return ("arrow.up.and.line.horizontal.and.arrow.down", "⌥D")
        case .continueDim:     return ("arrow.left.and.line.vertical.and.arrow.right", "⌥C")
        // Image: place a reference to an image file (picked up front), ⇧Y.
        case .image:           return ("photo", "⇧Y")
        // Paper-space Viewport placement (⌥V) — only meaningful in a layout tab.
        case .viewport:        return ("rectangle.dashed", "⌥V")
        }
    }

    /// The full command list: every tool first (in the canonical `ToolKind`
    /// order, prefixed so the user reads them as actions), then the app actions.
    static func commands(_ actions: Actions) -> [PaletteCommand] {
        var list: [PaletteCommand] = []

        // Every tool — activates via the controller (same path as the toolbar). The
        // `.image` kind is special-cased to the file-picker flow (a bare activate would
        // arm an inert tool with no file chosen).
        for kind in ToolKind.allCases {
            let g = glyph(for: kind)
            // `.image` routes to the file-picker flow; `.createBlock` routes to the
            // name sheet (spec §2.1) — both need a View-layer step a bare activate skips.
            let run: () -> Void
            switch kind {
            case .image:       run = actions.placeImage
            case .createBlock: run = actions.createBlockFromSelection
            default:           run = { actions.activateTool(kind) }
            }
            // Give the create-block entry the clear AutoCAD verb (its `ToolKind.title`
            // stays "Create Block"; the palette surfaces the discoverable phrasing).
            let title = (kind == .createBlock) ? "Create Block from Selection…" : kind.title
            list.append(PaletteCommand(
                id: "tool.\(kind.rawValue)",
                title: title,
                systemImage: g.symbol,
                shortcut: g.shortcut,
                run: run
            ))
        }

        // Main app actions — each fires the same closure the menu fires.
        list.append(contentsOf: [
            PaletteCommand(id: "app.open", title: "Open…",
                           systemImage: "folder", shortcut: "⌘O", run: actions.open),
            PaletteCommand(id: "app.save", title: "Save",
                           systemImage: "square.and.arrow.down", shortcut: "⌘S", run: actions.save),
            PaletteCommand(id: "app.saveAs", title: "Save As…",
                           systemImage: "square.and.arrow.down.on.square", shortcut: "⇧⌘S", run: actions.saveAs),
            PaletteCommand(id: "app.exportPDF", title: "Export PDF…",
                           systemImage: "doc.richtext", shortcut: "⇧⌘E", run: { actions.export(.pdf) }),
            PaletteCommand(id: "app.exportPNG", title: "Export PNG…",
                           systemImage: "photo", run: { actions.export(.png) }),
            PaletteCommand(id: "app.exportSVG", title: "Export SVG…",
                           systemImage: "square.on.circle", run: { actions.export(.svg) }),
            PaletteCommand(id: "app.print", title: "Print…",
                           systemImage: "printer", shortcut: "⌘P", run: actions.print),
            PaletteCommand(id: "app.zoomToFit", title: "Zoom to Fit",
                           systemImage: "arrow.up.left.and.down.right.magnifyingglass",
                           shortcut: "⌘0", run: actions.zoomToFit),
            PaletteCommand(id: "app.undo", title: "Undo",
                           systemImage: "arrow.uturn.backward", shortcut: "⌘Z", run: actions.undo),
            PaletteCommand(id: "app.redo", title: "Redo",
                           systemImage: "arrow.uturn.forward", shortcut: "⇧⌘Z", run: actions.redo),
            PaletteCommand(id: "app.toggleInspector", title: "Toggle Inspector",
                           systemImage: "sidebar.trailing", run: actions.toggleInspector),
            PaletteCommand(id: "app.toggleGrid", title: "Toggle Grid",
                           systemImage: "grid", run: actions.toggleGrid),
            PaletteCommand(id: "app.documentSettings", title: "Document Settings…",
                           systemImage: "gearshape", shortcut: "⌥⌘,", run: actions.documentSettings),
        ])

        return list
    }
}

// MARK: - Presentation modifier

/// Bundles the palette's two concerns — the overlay presentation and the
/// View ▸ Command Palette… (⌘K) focused-scene-value handler — into a single
/// `ViewModifier`. ContentView applies it with one `.modifier(...)` so its long
/// `canvasDetail` chain stays small enough for the Swift type-checker.
struct CommandPaletteModifier: ViewModifier {
    @Binding var isPresented: Bool
    let commands: [PaletteCommand]

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    CommandPalette(isPresented: $isPresented, commands: commands)
                        .transition(.opacity)
                }
            }
            // Raise the palette when View ▸ Command Palette… (⌘K) fires on the
            // focused window.
            .focusedSceneValue(\.commandPalette) { isPresented = true }
    }
}

// MARK: - Overlay view

/// The ⌘K overlay. Presented over the canvas; renders a dim backdrop, a centered
/// search field, and a ranked result list. Keyboard: Esc dismiss, ↑/↓ navigate,
/// Return run the highlighted command. Filtering/ranking comes from the pure
/// `CommandMatcher` (tested in CADEngine).
struct CommandPalette: View {
    /// Bound to the presenter (ContentView) so Esc / running a command can close.
    @Binding var isPresented: Bool
    /// The full command list to search.
    let commands: [PaletteCommand]

    @State private var query: String = ""
    /// Index into `filtered` of the highlighted row.
    @State private var selection: Int = 0
    @FocusState private var fieldFocused: Bool

    /// The ranked, filtered commands for the current query. Empty query → all.
    private var filtered: [PaletteCommand] {
        let ranked = CommandMatcher.rank(query: query, candidates: commands.map(\.title))
        return ranked.map { commands[$0.index] }
    }

    var body: some View {
        ZStack {
            // Dim, click-to-dismiss backdrop.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            palette
                .frame(width: 560)
                .frame(maxHeight: 460)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.modal))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.modal)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .shadow(radius: 30, y: 12)
                .padding(.top, 80)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { fieldFocused = true }
        // Esc closes from anywhere in the overlay.
        .onExitCommand { dismiss() }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultList
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Run a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit { runSelected() }
                .onChange(of: query) { _, _ in selection = 0 }
                // Arrow navigation while the field holds focus.
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.return) { runSelected(); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        Text("No matching commands")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, cmd in
                            row(cmd, isSelected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = index; runSelected() }
                                // Hover-to-highlight for mouse users.
                                .onHover { if $0 { selection = index } }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selection) { _, new in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func row(_ cmd: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: DS.Space.md) {
            Image(systemName: cmd.systemImage)
                .frame(width: DS.Size.rowIcon)
                .foregroundStyle(isSelected ? DS.Palette.onAccent : .secondary)
            Text(cmd.title)
                .foregroundStyle(isSelected ? DS.Palette.onAccent : .primary)
            Spacer(minLength: DS.Space.lg)
            if let shortcut = cmd.shortcut {
                Text(shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(isSelected ? DS.Palette.onAccent.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.md)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.selection)
                    .fill(DS.Palette.accent)
                    .padding(.horizontal, DS.Space.md)
            }
        }
    }

    // MARK: Behavior

    private func moveSelection(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelected() {
        let results = filtered
        guard results.indices.contains(selection) else { return }
        let cmd = results[selection]
        dismiss()
        // Run AFTER dismiss so the action (which may present a panel/sheet) lands
        // on a clean window, not behind the overlay.
        cmd.run()
    }

    private func dismiss() {
        isPresented = false
    }
}
