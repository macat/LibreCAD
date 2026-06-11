//
//  ContentView.swift
//  LibreCADmacOS
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI

struct ContentView: View {
    let document: CADDocument

    var body: some View {
        MetalCanvasView()
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            .overlay(alignment: .topLeading) {
                Text("LibreCAD (macOS) — \(document.rawData.count) bytes loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
    }
}
