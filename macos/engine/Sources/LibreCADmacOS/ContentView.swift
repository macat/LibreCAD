//
//  ContentView.swift
//  LibreCADmacOS
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import CADEngine

struct ContentView: View {
    let document: CADDocument
    /// The document's UndoManager, injected by DocumentGroup. Wired into the
    /// drawing so entity mutations register undo (ADR-002).
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        MetalCanvasView()
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            .overlay(alignment: .topLeading) {
                Text("LibreCAD (macOS) — \(document.drawing.count) entities")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .onAppear { document.drawing.undoManager = undoManager }
            .onChange(of: undoManager) { _, newValue in
                document.drawing.undoManager = newValue
            }
    }
}
