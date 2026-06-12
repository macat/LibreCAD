//
//  LibreCADApp.swift
//  LibreCADmacOS
//
//  SwiftUI entry point. The app is now DOCUMENT-BASED: a `DocumentGroup` over the
//  off-main-safe `LibreCADDocument` (a `ReferenceFileDocument` for `.dxf`). That
//  gives native New / Open / Open Recent / Save / Save As / Revert / autosave /
//  versions / the dirty dot / multi-window for free. Each document window hosts
//  `ContentView`, which builds the live `@MainActor CADDrawing`/`CanvasModel` from
//  the document's Sendable payload — on the MAIN ACTOR — and runs the canvas +
//  inspector + toolbar + palette + gizmos.
//
//  ⚠️ LAUNCH-SAFETY — why DocumentGroup is safe HERE (it crashed once).
//  An earlier document build SIGTRAP-crashed because `CADDocument.init` called
//  `MainActor.assumeIsolated` while NSDocument constructed the document OFF the
//  main actor (a background NSOperationQueue). The current `LibreCADDocument`
//  init/snapshot/fileWrapper touch ONLY Sendable value data (never a `@MainActor`
//  type, never `assumeIsolated`); the `@MainActor` model is built later in the
//  view. See LibreCADDocument.swift / ContentView.swift and DEVLOG.md ("SIGTRAP").
//
//  File ▸ New / Open / Open Recent / Save / Save As / Revert are now NATIVE
//  DocumentGroup commands (no custom panels). Export (PDF/PNG/SVG) and Print STAY
//  custom (they are not the document type) and are added to the File menu via
//  focused scene values, as are the tool/undo/delete/palette commands.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import CADEngine

@main
struct LibreCADApp: App {
    /// The "open command palette" (⌘K) action published by the focused window.
    @FocusedValue(\.commandPalette) private var commandPalette
    @FocusedValue(\.focusCommandLine) private var focusCommandLine
    /// The "open Document Settings" (⌥⌘,) action published by the focused window (D8).
    @FocusedValue(\.openDocumentSettings) private var openDocumentSettings
    /// The Zoom-to-Fit action published by the focused window.
    @FocusedValue(\.zoomToFit) private var zoomToFit
    /// Export (PDF/PNG/SVG) and Print actions published by the focused window.
    @FocusedValue(\.exportDocument) private var exportDocument
    @FocusedValue(\.printDocument) private var printDocument
    /// The tool-activation action published by the focused window.
    @FocusedValue(\.activateTool) private var activateTool
    /// Undo / redo actions published by the focused window.
    @FocusedValue(\.undoAction) private var undoAction
    @FocusedValue(\.redoAction) private var redoAction
    /// Delete-selection action published by the focused window (Edit ▸ Delete, ⌫).
    @FocusedValue(\.deleteSelection) private var deleteSelection
    /// Whether the focused window has a draw tool mid-run. When true the Edit ▸
    /// Delete item is disabled so its bare-⌫ shortcut does NOT pre-empt the tool's
    /// `.backspace` (see the Delete button below and MUST-FIX 1).
    @FocusedValue(\.isToolActive) private var isToolActive

    var body: some Scene {
        // The document scene: a brand-new document is the empty `LibreCADDocument()`;
        // opening a file constructs `LibreCADDocument(configuration:)` OFF-main from
        // Sendable bytes (the launch-safe path). The editor closure hands us the
        // document reference, which ContentView turns into the live model on-main.
        DocumentGroup(newDocument: { LibreCADDocument() }) { configuration in
            ContentView(document: configuration.document)
        }
        .commands {
            // File ▸ Export… / Print… — added AFTER the native Save items (Save /
            // Save As / Revert come from DocumentGroup). Export renders the drawing
            // to PDF / PNG / SVG (not the document type); Print drives the system
            // print dialog. Both route to the focused window via focused values.
            CommandGroup(after: .saveItem) {
                Divider()
                Menu("Export…") {
                    Button("PDF…") { exportDocument?(.pdf) }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(exportDocument == nil)
                    Button("PNG…") { exportDocument?(.png) }
                        .disabled(exportDocument == nil)
                    Button("SVG…") { exportDocument?(.svg) }
                        .disabled(exportDocument == nil)
                }
                // File ▸ Print… (⌘P) — the system print dialog, fitted to paper.
                Button("Print…") { printDocument?() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(printDocument == nil)

                Divider()
                // File ▸ Document Settings… (⌥⌘, — decision D8). The per-document
                // settings sheet (units / grid & snap / dimensions / layers / paper).
                // ⌘, is reserved for a future app-level Preferences, so document
                // settings take ⌥⌘,. Routed to the focused window via a focused value.
                Button("Document Settings…") { openDocumentSettings?() }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(openDocumentSettings == nil)
            }
            // Undo / redo. DocumentGroup provides system Undo/Redo bound to the
            // document's environment UndoManager — which our model now ADOPTS, so
            // edits register against it. We still REPLACE the items to route ⌘Z/⇧⌘Z
            // through `model.undo()`/`redo()`, which run the post-undo bookkeeping the
            // raw UndoManager can't (rebuild the spatial index, clear selection,
            // request a redraw). Because the model's manager IS the environment
            // manager, the native dirty/clean tracking still works.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { undoAction?() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(undoAction == nil)
                Button("Redo") { redoAction?() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(redoAction == nil)
            }
            // Edit ▸ Delete — removes the current selection (undoable). The ⌫ key on
            // the canvas is also handled directly by the controller (select mode);
            // this menu item makes it discoverable and gives it a standard shortcut.
            //
            // It is DISABLED while a draw tool is mid-run (`isToolActive == true`).
            // `NSMenu.performKeyEquivalent` runs BEFORE the canvas `keyDown`, so an
            // enabled bare-⌫ item would steal ⌫ from the active tool (where ⌫ must
            // be the tool's `.backspace`). A disabled item's key equivalent is not
            // consumed, so ⌫ falls through to the canvas `keyDown`, which routes it
            // to the tool. In select mode (`isToolActive` false/nil) the item stays
            // enabled and ⌫ deletes the selection. (MUST-FIX 1.)
            CommandGroup(after: .pasteboard) {
                Button("Delete") { deleteSelection?() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(deleteSelection == nil || (isToolActive ?? false))
            }
            CommandGroup(after: .toolbar) {
                // ⌘K — the command palette: fuzzy-find and run any tool/app action.
                Button("Command Palette…") { commandPalette?() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(commandPalette == nil)
                // ⇧⌘L — focus the bottom command/coordinate input line (U1, D1) so
                // the user can type a precise coordinate/length. (Space also focuses
                // it on the canvas while a tool is active.)
                Button("Command Line") { focusCommandLine?() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(focusCommandLine == nil)
                Button("Zoom to Fit") { zoomToFit?() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoomToFit == nil)
            }
            // The Tools menu — the discoverable source of truth for EVERY tool and
            // its shortcut. Each item activates the tool on the focused canvas via
            // the `activateTool` focused value; the same shortcuts are also handled
            // directly by the canvas `keyDown` (CADCanvasView.handleKey) so they work
            // whether the menu or the canvas has focus. Grouped Select → Draw →
            // Modify. Modify tools act on the current selection (select in V mode,
            // then activate); with nothing selected the tool's HUD prompts "Select
            // objects…". Shift picks the modify variant where a letter is shared
            // (⇧C Copy vs C Circle, ⇧R Rotate vs R Rectangle, ⇧M Mirror vs M Move,
            // ⇧O Offset vs O Point). New draw tools: E Ellipse, G Polygon. Edit
            // tools (pick under the cursor, no pre-selection): T Trim, X Extend,
            // F Fillet, ⇧F Chamfer.
            CommandMenu("Tools") {
                Button("Select") { activateTool?(.select) }
                    .keyboardShortcut("v", modifiers: [])
                    .disabled(activateTool == nil)

                Divider()
                // Draw tools.
                Button("Line") { activateTool?(.line) }
                    .keyboardShortcut("l", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Circle") { activateTool?(.circle) }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Arc") { activateTool?(.arc) }
                    .keyboardShortcut("a", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Rectangle") { activateTool?(.rectangle) }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Polyline") { activateTool?(.polyline) }
                    .keyboardShortcut("p", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Point") { activateTool?(.point) }
                    .keyboardShortcut("o", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Ellipse") { activateTool?(.ellipse) }
                    .keyboardShortcut("e", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Polygon") { activateTool?(.polygon) }
                    .keyboardShortcut("g", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Spline") { activateTool?(.spline) }
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(activateTool == nil)
                // Hatch fills the region bounded by the current selection.
                Button("Hatch") { activateTool?(.hatch) }
                    .keyboardShortcut("h", modifiers: [])
                    .disabled(activateTool == nil)
                // Text authoring (⇧T): a click sets the insertion point and raises the
                // inline editor; type, then Return commits a text/mtext entity.
                Button("Text") { activateTool?(.text) }
                    .keyboardShortcut("t", modifiers: .shift)
                    .disabled(activateTool == nil)

                Divider()
                // Modify tools (act on the current selection).
                Button("Move") { activateTool?(.move) }
                    .keyboardShortcut("m", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Copy") { activateTool?(.copy) }
                    .keyboardShortcut("c", modifiers: .shift)
                    .disabled(activateTool == nil)
                Button("Offset") { activateTool?(.offset) }
                    .keyboardShortcut("o", modifiers: .shift)
                    .disabled(activateTool == nil)
                Button("Rotate") { activateTool?(.rotate) }
                    .keyboardShortcut("r", modifiers: .shift)
                    .disabled(activateTool == nil)
                Button("Scale") { activateTool?(.scale) }
                    .keyboardShortcut("s", modifiers: .shift)
                    .disabled(activateTool == nil)
                Button("Mirror") { activateTool?(.mirror) }
                    .keyboardShortcut("m", modifiers: .shift)
                    .disabled(activateTool == nil)
                // Array / Divide / Explode use the shift convention for their letters
                // (⇧A vs A Arc, ⇧X vs X Extend; ⇧D is free). Each acts on the current
                // selection (select in V mode, then activate) using sensible DEFAULTS
                // (Array: 2×3 grid; Divide: 2 parts) — a config UI is a later wave.
                Button("Array") { activateTool?(.array) }
                    .keyboardShortcut("a", modifiers: .shift)
                    .disabled(activateTool == nil)
                Button("Divide") { activateTool?(.divide) }
                    .keyboardShortcut("d", modifiers: .shift)
                    .disabled(activateTool == nil)
                Button("Explode") { activateTool?(.explode) }
                    .keyboardShortcut("x", modifiers: .shift)
                    .disabled(activateTool == nil)

                Divider()
                // Edit tools (pick entities under the cursor; no pre-selection).
                // Their letters are free (no draw/modify twin), so they take plain
                // keys; Chamfer shares F with Fillet via the shift convention
                // (⇧F Chamfer vs F Fillet, like ⇧C Copy vs C Circle).
                Button("Trim") { activateTool?(.trim) }
                    .keyboardShortcut("t", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Extend") { activateTool?(.extend) }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Fillet") { activateTool?(.fillet) }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Chamfer") { activateTool?(.chamfer) }
                    .keyboardShortcut("f", modifiers: .shift)
                    .disabled(activateTool == nil)

                Divider()
                // Dimension tools (annotate measurements). Each takes a bare,
                // collision-free letter (no draw/modify twin): D Linear, I Aligned,
                // U Radius, B Diameter, N Angular. Linear/Aligned place two extension
                // origins + a dimension-line point; Radius/Diameter pick a circle/arc
                // + a leader; Angular defines two rays + an arc location.
                Menu("Dimensions") {
                    Button("Linear Dimension") { activateTool?(.linearDim) }
                        .keyboardShortcut("d", modifiers: [])
                        .disabled(activateTool == nil)
                    Button("Aligned Dimension") { activateTool?(.alignedDim) }
                        .keyboardShortcut("i", modifiers: [])
                        .disabled(activateTool == nil)
                    Button("Radius Dimension") { activateTool?(.radialDim) }
                        .keyboardShortcut("u", modifiers: [])
                        .disabled(activateTool == nil)
                    Button("Diameter Dimension") { activateTool?(.diameterDim) }
                        .keyboardShortcut("b", modifiers: [])
                        .disabled(activateTool == nil)
                    Button("Angular Dimension") { activateTool?(.angularDim) }
                        .keyboardShortcut("n", modifiers: [])
                        .disabled(activateTool == nil)
                }
            }
        }
    }
}
