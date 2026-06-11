//
//  LibreCADApp.swift
//  LibreCADmacOS
//
//  SwiftUI entry point. DocumentGroup + ReferenceFileDocument gives us
//  open/save and the standard document UI for free.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI

@main
struct LibreCADApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { CADDocument() }) { configuration in
            ContentView(document: configuration.document)
        }
    }
}
