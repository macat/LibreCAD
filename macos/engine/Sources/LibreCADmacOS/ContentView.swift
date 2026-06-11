//
//  ContentView.swift
//  LibreCADmacOS
//
//  The single window: the interactive Metal canvas (CADCanvasView) plus a
//  coordinate / status HUD. It owns the live model directly — a `@MainActor
//  @Observable CanvasModel` — so there is no NSDocument and nothing on the
//  launch path that crosses actor boundaries.
//
//  On first appear it loads the bundled `dim_sample.dxf` (falling back to the
//  repo copy) so a fresh launch shows real geometry. File▸Open uses a SwiftUI
//  `.fileImporter` driven by the ⌘O command via a focused scene value.
//
//  Crash-fix note: the previous DocumentGroup path constructed the document off
//  the main thread and trapped on `MainActor.assumeIsolated`. There is NO
//  `assumeIsolated` here: `CanvasModel`/`CADDrawing` are touched only on the
//  main actor (this whole view runs there), and `loadDrawing(dxfPath:)` is
//  itself `@MainActor`.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import UniformTypeIdentifiers
import CADEngine

struct ContentView: View {
    /// The canvas state (model, viewport, index, selection, snap). Owned by this
    /// window; `@MainActor @Observable`, so it is only ever touched on the main
    /// actor — which is where this whole view runs.
    @State private var model = CanvasModel()
    /// Bridge so the Zoom-to-Fit command can reach the live canvas controller.
    @State private var controllerBox = CADCanvasView.ControllerBox()
    @State private var status: String = "Loading…"
    /// Drives the File▸Open importer (toggled by the ⌘O command).
    @State private var showOpen = false
    /// Set once so the launch sample is loaded exactly one time.
    @State private var didLoadSample = false

    var body: some View {
        CADCanvasView(model: model, controllerBox: controllerBox)
            .ignoresSafeArea()
            .frame(minWidth: 480, minHeight: 320)
            .overlay(alignment: .topLeading) { statusHUD }
            .overlay(alignment: .bottomLeading) { coordinateHUD }
            .focusedSceneValue(\.zoomToFit) { controllerBox.controller?.zoomToFit() }
            .focusedSceneValue(\.openDocument) { showOpen = true }
            .fileImporter(
                isPresented: $showOpen,
                allowedContentTypes: Self.dxfTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .onAppear {
                guard !didLoadSample else { return }
                didLoadSample = true
                Task { await loadSample() }
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

    // MARK: - Open (File▸Open via ⌘O)

    /// Accepted file types for the importer. Prefers the exported DXF UTType but
    /// always also offers the plain `.dxf` extension type as a robust fallback.
    private static let dxfTypes: [UTType] = {
        var types: [UTType] = [.librecadDXF]
        if let byExt = UTType(filenameExtension: "dxf") { types.append(byExt) }
        return types
    }()

    /// Handles the importer result: resolves the security-scoped URL and loads it.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await open(url) }
        case .failure(let error):
            status = "Open cancelled: \(error.localizedDescription)"
        }
    }

    /// Loads a user-picked file, honoring the security-scoped URL lifecycle. On
    /// error the message lands in the status HUD — never a crash.
    @MainActor
    private func open(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        await load(path: url.path, label: url.lastPathComponent)
    }

    // MARK: - Initial sample load

    /// Loads the launch sample from the app bundle if present, else the repo copy,
    /// so the bundled app is path-independent. Runs on the main actor; on failure
    /// the status HUD shows the error rather than crashing.
    @MainActor
    private func loadSample() async {
        status = "Loading dim_sample.dxf…"
        if let bundled = Bundle.main.url(forResource: "dim_sample", withExtension: "dxf") {
            await load(path: bundled.path, label: "dim_sample.dxf")
            return
        }
        // Fallback to the in-repo copy (useful when running the bare binary).
        await load(path: Self.repoSamplePath, label: "dim_sample.dxf")
    }

    /// Repo-relative fallback path for the launch sample (used only when the
    /// sample is not bundled, e.g. running the SwiftPM binary directly).
    private static let repoSamplePath =
        "/Users/macatt/w/LibreCAD/librecad/res/dxf/dim_sample.dxf"

    // MARK: - Shared load

    /// Parses a DXF at `path` on the main actor, installs it in the model, frames
    /// it, and updates the HUD. Errors surface in the status HUD (no crash).
    @MainActor
    private func load(path: String, label: String) async {
        let size = model.viewport.size
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
}

// MARK: - Focused command plumbing

/// Focused scene values carrying the active window's "Zoom to Fit" and "Open…"
/// actions, so menu/keyboard commands (⌘0 / ⌘O) can drive the focused window
/// without a global singleton (LibreCADApp reads them in its `.commands`).
extension FocusedValues {
    var zoomToFit: (() -> Void)? {
        get { self[ZoomToFitKey.self] }
        set { self[ZoomToFitKey.self] = newValue }
    }

    var openDocument: (() -> Void)? {
        get { self[OpenDocumentKey.self] }
        set { self[OpenDocumentKey.self] = newValue }
    }
}

private struct ZoomToFitKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenDocumentKey: FocusedValueKey {
    typealias Value = () -> Void
}
