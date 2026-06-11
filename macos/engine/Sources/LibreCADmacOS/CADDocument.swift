//
//  CADDocument.swift
//  LibreCADmacOS
//
//  The SwiftUI `ReferenceFileDocument` wrapper around the engine's `CADDrawing`.
//  The drawing is the real model (entities/layers); the document adapts it to
//  DocumentGroup's open/save/undo machinery.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import UniformTypeIdentifiers
import CADEngine

/// Reference-type document model used by `DocumentGroup`.
///
/// Holds a `@MainActor @Observable` `CADDrawing`. `ReferenceFileDocument`'s
/// requirements are `nonisolated`, and SwiftUI's document machinery invokes
/// `init(configuration:)` / `snapshot(contentType:)` / `fileWrapper(...)` on the
/// **main thread**. We honor that with `MainActor.assumeIsolated` to safely touch
/// the main-actor `CADDrawing` — which lets us delete the old
/// `nonisolated(unsafe)` escape hatch (review follow-up #2) without lying to the
/// compiler about isolation.
final class CADDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    /// The real drawing model (entities, layers, blocks, undo). Main-actor
    /// isolated; only touched from main-thread document callbacks / SwiftUI.
    let drawing: CADDrawing

    static var readableContentTypes: [UTType] { [.librecadDXF] }
    static var writableContentTypes: [UTType] { [.librecadDXF] }

    init() {
        // DocumentGroup's newDocument closure runs on the main thread.
        drawing = MainActor.assumeIsolated { CADDrawing() }
    }

    init(configuration: ReadConfiguration) throws {
        // SwiftUI calls this on the main thread.
        drawing = MainActor.assumeIsolated { CADDrawing() }
        // TODO: real DXF read via DxfBridge (Phase 1 / consolidated gate) — parse
        // configuration.file.regularFileContents through libdxfrw into the model.
        // For the skeleton we accept the file but do not yet populate entities,
        // so DocumentGroup can open .dxf without regressing the build.
        _ = configuration.file.regularFileContents
    }

    func snapshot(contentType: UTType) throws -> Data {
        // TODO: real DXF write via DxfBridge (Phase 1 / consolidated gate) —
        // serialize `drawing` through the libdxfrw writer on the main thread.
        // For now emit empty content so save round-trips without crashing.
        MainActor.assumeIsolated { Data() }
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
