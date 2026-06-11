//
//  ContentView.swift
//  LibreCADmacOS
//
//  The document window: the interactive Metal canvas (CADCanvasView) plus a
//  coordinate / status HUD. On appear it loads the document's drawing into a
//  `CanvasModel` and frames it. For the empty "new document" case it loads the
//  bundled `dim_sample.dxf` so a fresh launch shows real geometry (the Wave-2
//  payoff).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import CADEngine

struct ContentView: View {
    let document: CADDocument
    /// The document's UndoManager, injected by DocumentGroup (ADR-002).
    @Environment(\.undoManager) private var undoManager

    /// The canvas state (model, viewport, index, selection, snap). Created per
    /// window; the document's drawing is loaded into it on appear.
    @State private var model = CanvasModel()
    /// Bridge so the Zoom-to-Fit command can reach the live canvas controller.
    @State private var controllerBox = CADCanvasView.ControllerBox()
    @State private var status: String = "Loading…"

    /// Hard-coded path to the launch sample (per the Wave-2 brief). Used only when
    /// the document opened empty (a fresh "new document").
    private static let launchSamplePath =
        "/Users/macatt/w/LibreCAD/librecad/res/dxf/dim_sample.dxf"

    var body: some View {
        CADCanvasView(model: model, controllerBox: controllerBox)
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            .overlay(alignment: .topLeading) { statusHUD }
            .overlay(alignment: .bottomLeading) { coordinateHUD }
            .focusedSceneValue(\.zoomToFit) { controllerBox.controller?.zoomToFit() }
            .onAppear {
                document.drawing.undoManager = undoManager
                loadInitialDrawing()
            }
            .onChange(of: undoManager) { _, newValue in
                document.drawing.undoManager = newValue
            }
    }

    // MARK: - HUD

    private var statusHUD: some View {
        Text(status)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(6)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
    }

    @ViewBuilder
    private var coordinateHUD: some View {
        if let w = model.cursorWorld {
            let snapLabel = model.snap.map { " · \(label(for: $0.kind))" } ?? ""
            Text(String(format: "x %.3f   y %.3f%@", w.x, w.y, snapLabel))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .padding(6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
        }
    }

    private func label(for kind: SnapKind) -> String {
        switch kind {
        case .endpoint: return "end"
        case .center: return "center"
        case .middle: return "mid"
        case .onEntity: return "on"
        case .intersection: return "intersect"
        case .grid: return "grid"
        case .free: return "free"
        }
    }

    // MARK: - Initial load

    /// Loads the document's drawing into the canvas model. Three cases:
    ///   1. File>Open of a real .dxf → parse the opened bytes via DXFReader.
    ///   2. A new/empty document → load the bundled sample DXF (Wave-2 payoff).
    private func loadInitialDrawing() {
        let size = CGSize(width: 1000, height: 700)   // a sane first frame size

        if let data = document.openedFileData, !data.isEmpty {
            document.openedFileData = nil   // consume once
            status = "Opening…"
            Task { await load(path: stage(data: data) ?? Self.launchSamplePath,
                              label: "opened file", size: size) }
            return
        }

        // New/empty document → load the launch sample.
        status = "Loading dim_sample.dxf…"
        Task { await load(path: Self.launchSamplePath, label: "dim_sample.dxf", size: size) }
    }

    /// Parses a DXF at `path` and frames it. Errors surface in the status HUD.
    @MainActor
    private func load(path: String, label: String, size: CGSize) async {
        do {
            let drawing = try await loadDrawing(dxfPath: path)
            model.setDrawing(drawing, viewSize: size)
            status = "\(label) — \(model.entityCount) entities"
            NSLog("CADCanvas: loaded \(model.entityCount) entities from \(label)")
            controllerBox.controller?.zoomToFit()
        } catch {
            status = "Load failed: \(error.localizedDescription)"
            NSLog("CADCanvas: load failed: \(error)")
        }
    }

    /// Writes opened bytes to a temp .dxf so the path-based DXFReader/libdxfrw can
    /// read them. Returns the temp path, or nil on failure.
    private func stage(data: Data) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("librecad-open-\(UUID().uuidString).dxf")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            NSLog("CADCanvas: failed to stage opened file: \(error)")
            return nil
        }
    }
}

// MARK: - Zoom-to-Fit focused command plumbing

/// A focused scene value carrying the active canvas's "Zoom to Fit" action, so a
/// menu/keyboard command (⌘0) can drive the focused canvas without a global
/// singleton (LibreCADApp reads it in its `.commands`).
extension FocusedValues {
    var zoomToFit: (() -> Void)? {
        get { self[ZoomToFitKey.self] }
        set { self[ZoomToFitKey.self] = newValue }
    }
}

private struct ZoomToFitKey: FocusedValueKey {
    typealias Value = () -> Void
}
