//
//  SidebarHost.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 2 — ContentView decomposition. Thin wrapper around the
//  existing LayersSidebar so ContentView composes via @ViewBuilder and
//  observes only needed slices. Passes the live CanvasModel verbatim to
//  preserve existing behavior; the host itself is Equatable-gated so a
//  viewport-only change does not churn the sidebar.
//
//  GPLv2-or-later.
//

import SwiftUI
import CADEngine

/// Host for the leading sidebar pane. Wraps `LayersSidebar` with its
/// column sizing and title, so `ContentView` stays a thin orchestrator.
struct SidebarHost: View {
    @Bindable var model: CanvasModel
    let controllerBox: CADCanvasView.ControllerBox
    let onCreateBlock: () -> Void
    let onInsertBlockFromFile: () -> Void
    let onSaveBlockToFile: (String) -> Void

    var body: some View {
        sidebarContent
    }

    @ViewBuilder
    private var sidebarContent: some View {
        LayersSidebar(
            model: model,
            controllerBox: controllerBox,
            onCreateBlock: onCreateBlock,
            onInsertBlockFromFile: onInsertBlockFromFile,
            onSaveBlockToFile: onSaveBlockToFile
        )
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .navigationTitle("Document")
    }
}
