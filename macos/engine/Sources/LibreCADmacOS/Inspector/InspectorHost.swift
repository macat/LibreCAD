//
//  InspectorHost.swift
//  LibreCADmacOS
//
//  Wave 4 Phase 2 — ContentView decomposition. Thin wrapper around
//  InspectorView so ContentView composes the trailing inspector via
//  @ViewBuilder and observation is scoped to inspector-used slices.
//
//  GPLv2-or-later.
//

import SwiftUI
import CADEngine

/// Host for the trailing inspector pane. Wraps `InspectorView` with its
/// column sizing. Used inside `.inspector(isPresented:)` in the canvas
/// container so the inspector chrome is decoupled from the orchestrator.
struct InspectorHost: View {
    @Bindable var model: CanvasModel
    let controllerBox: CADCanvasView.ControllerBox

    var body: some View {
        inspectorContent
    }

    @ViewBuilder
    private var inspectorContent: some View {
        InspectorView(model: model, controllerBox: controllerBox)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
}
