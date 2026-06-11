//
//  CADDocument.swift
//  LibreCADmacOS
//
//  A placeholder ReferenceFileDocument for the scaffold. It carries a trivial
//  model (the raw bytes of the opened file) so DocumentGroup has something to
//  open/save; the real drawing model lands in a later workstream.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import SwiftUI
import UniformTypeIdentifiers

/// Reference-type document model used by `DocumentGroup`.
///
/// For the spine this just round-trips the file's bytes. A real `CADDrawing`
/// model (entities, layers, blocks) replaces `rawData` later.
///
/// `ReferenceFileDocument` refines `Sendable`, but the model needs mutable
/// state. SwiftUI's document machinery serializes access (reads happen via the
/// `snapshot(contentType:)` it calls before persisting), so the mutable field
/// is marked `nonisolated(unsafe)`; this is replaced by a properly isolated
/// drawing model in a later workstream.
final class CADDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    /// Placeholder model: the raw file contents.
    nonisolated(unsafe) var rawData: Data

    static var readableContentTypes: [UTType] { [.librecadDXF, .plainText, .data] }
    static var writableContentTypes: [UTType] { [.librecadDXF] }

    init() {
        rawData = Data()
    }

    init(configuration: ReadConfiguration) throws {
        rawData = configuration.file.regularFileContents ?? Data()
    }

    func snapshot(contentType: UTType) throws -> Data {
        rawData
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
