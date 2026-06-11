//
//  LibreCADApp.swift
//  LibreCADmacOS
//
//  SwiftUI entry point. DocumentGroup + ReferenceFileDocument gives us
//  open/save and the standard document UI for free. A View menu adds
//  "Zoom to Fit" (⌘0), routed to the focused canvas via a focused scene value.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI

@main
struct LibreCADApp: App {
    /// The Zoom-to-Fit action published by the focused document window.
    @FocusedValue(\.zoomToFit) private var zoomToFit

    var body: some Scene {
        DocumentGroup(newDocument: { CADDocument() }) { configuration in
            ContentView(document: configuration.document)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Zoom to Fit") { zoomToFit?() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(zoomToFit == nil)
            }
        }
    }
}
