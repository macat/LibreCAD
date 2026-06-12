//
//  LibreCADApp.swift
//  LibreCADmacOS
//
//  SwiftUI entry point. A single-window `WindowGroup` shell owns the live canvas
//  directly (ContentView holds the `@MainActor @Observable CanvasModel`). The
//  View menu adds "Zoom to Fit" (⌘0) and "Open…" (⌘O), both routed to the
//  focused window via focused scene values.
//
//  NOTE: We intentionally do NOT use `DocumentGroup`/`ReferenceFileDocument`.
//  SwiftUI's NSDocument machinery constructs the document off the main thread
//  (a background NSOperationQueue), which traps any `MainActor.assumeIsolated`
//  in the document's `init` and crashes before the first window appears. The
//  model (`CADDrawing`) is `@MainActor`-isolated, so the document path is
//  fundamentally unsafe here. See CADDocument deletion in this commit and the
//  backlog note below.
//
//  TODO(backlog): reintroduce DocumentGroup with an off-main-safe
//  ReferenceFileDocument (store only Sendable parsed data in init/snapshot/
//  fileWrapper; build the @MainActor CADDrawing later in the view, never in
//  the document init).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import CADEngine

@main
struct LibreCADApp: App {
    /// The Zoom-to-Fit action published by the focused window.
    @FocusedValue(\.zoomToFit) private var zoomToFit
    /// The Open action published by the focused window (drives its .fileImporter).
    @FocusedValue(\.openDocument) private var openDocument
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
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openDocument?() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(openDocument == nil)
            }
            // Undo / redo (replaces the empty default since there's no DocumentGroup).
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
            // (⇧C Copy vs C Circle, ⇧R Rotate vs R Rectangle, ⇧M Mirror vs M Move).
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

                Divider()
                // Modify tools (act on the current selection).
                Button("Move") { activateTool?(.move) }
                    .keyboardShortcut("m", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Copy") { activateTool?(.copy) }
                    .keyboardShortcut("c", modifiers: .shift)
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
            }
        }
    }
}
