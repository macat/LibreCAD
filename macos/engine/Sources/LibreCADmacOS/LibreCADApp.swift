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
            CommandGroup(after: .toolbar) {
                Button("Zoom to Fit") { zoomToFit?() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoomToFit == nil)
            }
            // The Tools menu — minimal but real tool selection (also bound to the
            // bare L/V keys on the canvas; these add discoverable menu items +
            // standalone shortcuts).
            CommandMenu("Tools") {
                Button("Select") { activateTool?(.select) }
                    .keyboardShortcut("v", modifiers: [])
                    .disabled(activateTool == nil)
                Button("Line") { activateTool?(.line) }
                    .keyboardShortcut("l", modifiers: [])
                    .disabled(activateTool == nil)
            }
        }
    }
}
