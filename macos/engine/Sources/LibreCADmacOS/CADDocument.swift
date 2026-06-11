//
//  CADDocument.swift
//  LibreCADmacOS
//
//  The SwiftUI `ReferenceFileDocument` wrapper around the engine's `CADDrawing`.
//  The drawing is the real model (entities/layers); the document adapts it to
//  DocumentGroup's open/save/undo machinery.
//
//  On open we capture the file's raw bytes; `ContentView` then parses them
//  through `DXFReader` (libdxfrw is path-based, so we stage the bytes in a temp
//  file) and loads the result into the canvas. The parse runs off the synchronous
//  document `init` so DocumentGroup stays responsive and `CADEngine`'s actor
//  isolation is respected.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import UniformTypeIdentifiers
import CADEngine

/// Reference-type document model used by `DocumentGroup`.
final class CADDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    /// The real drawing model (entities, layers, blocks, undo). Main-actor
    /// isolated; only touched from main-thread document callbacks / SwiftUI.
    let drawing: CADDrawing

    /// The raw bytes of the opened file, if any (a fresh "new document" is nil).
    /// `ContentView` consumes this once to parse via `DXFReader`, then clears it.
    nonisolated(unsafe) var openedFileData: Data?

    static var readableContentTypes: [UTType] { [.librecadDXF] }
    static var writableContentTypes: [UTType] { [.librecadDXF] }

    init() {
        // DocumentGroup's newDocument closure runs on the main thread.
        drawing = MainActor.assumeIsolated { CADDrawing() }
    }

    init(configuration: ReadConfiguration) throws {
        // SwiftUI calls this on the main thread.
        drawing = MainActor.assumeIsolated { CADDrawing() }
        // Capture the bytes; the actual libdxfrw parse + model population happens
        // in ContentView (async, on the CADEngine actor) so we don't block the
        // document open and so actor isolation is honored.
        openedFileData = configuration.file.regularFileContents
    }

    func snapshot(contentType: UTType) throws -> Data {
        // TODO: real DXF write via DxfBridge (the DWG/DXF writing round-trip is a
        // separate workstream). For now emit empty content so save round-trips
        // without crashing.
        MainActor.assumeIsolated { Data() }
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
