//
//  LibreCADDocument.swift
//  LibreCADmacOS
//
//  The native document type backing `DocumentGroup` (Open / Open Recent / Save /
//  Save As / autosave / versions / the dirty dot / multi-window). It is a
//  `ReferenceFileDocument` over `.dxf` files.
//
//  ⚠️ LAUNCH-SAFETY — the WHOLE point of this file (read before editing).
//  An earlier document-based build SIGTRAP-crashed on launch: `CADDocument.init`
//  called `MainActor.assumeIsolated` while NSDocumentController constructed the
//  document on a BACKGROUND NSOperationQueue (`makeDocumentWithContentsOfURL`),
//  so the isolation assertion trapped before the first window appeared. See
//  macos/docs/DEVLOG.md ("SIGTRAP") and macos/docs/ADR.md.
//
//  The fix is structural: the document's entry points that SwiftUI/NSDocument
//  call OFF the main actor —
//      • `init(configuration:)`            (read)
//      • `snapshot(contentType:)`          (capture for write)
//      • `fileWrapper(snapshot:configuration:)` (write)
//  — operate ONLY on `Sendable` value data (`DXFPayload`: entity records + the
//  layer/block tables + header variables) and NEVER touch a `@MainActor` type.
//  There is NO `MainActor.assumeIsolated` anywhere here, and no `CADDrawing` /
//  `CanvasModel` is built in this file. The live `@MainActor CADDrawing` +
//  `CanvasModel` are constructed FROM this payload in the SwiftUI view
//  (`DocumentContentView`, on the main actor) — never in the document.
//
//  DXF parse/serialize runs through the documented off-main engine actor APIs
//  (`CADEngine.shared.readEntities` / `.writeEntities`), which return / accept
//  the same `Sendable` value records. Because these document entry points run on
//  a BACKGROUND queue (never the main actor), bridging the async engine call to
//  the synchronous `ReferenceFileDocument` requirement with a semaphore is safe:
//  it blocks a background thread, not the UI, and cannot deadlock the main actor.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import UniformTypeIdentifiers
import CADEngine

// MARK: - Sendable document payload

/// The document's parsed contents as `Sendable` value types — the ONLY state the
/// document holds. Everything here crosses actor boundaries freely (it is what
/// the engine reader returns and the writer accepts), so the off-main document
/// entry points can build/serialize it without ever touching the `@MainActor`
/// `CADDrawing`. The live drawing is reconstructed from this in the view on the
/// main actor (see `CADDrawing.make(from:)`).
struct DXFPayload: Sendable, Equatable {
    /// Entities in stable draw order, ids already minted by the reader.
    var entities: [EntityRecord]
    /// The parsed layer table (always carries at least layer "0" for a new doc).
    var layers: LayerTable
    /// Block definitions (id-refs into `entities`).
    var blocks: BlockTable
    /// Header graphic variables ($INSUNITS et al.).
    var graphicVariables: GraphicVariables

    init(
        entities: [EntityRecord] = [],
        layers: LayerTable = LayerTable(),
        blocks: BlockTable = BlockTable(),
        graphicVariables: GraphicVariables = GraphicVariables()
    ) {
        self.entities = entities
        self.layers = layers
        self.blocks = blocks
        self.graphicVariables = graphicVariables
    }

    /// An empty drawing for File ▸ New: no entities, the default layer table
    /// (`LayerTable()` already seeds layer "0", which DXF requires), default
    /// header. Pure value data — no engine call, no `@MainActor` access.
    static var empty: DXFPayload {
        DXFPayload(layers: LayerTable())
    }
}

// MARK: - Payload ↔ live drawing bridge (MAIN ACTOR ONLY)

extension CADDrawing {
    /// Builds a live `@MainActor CADDrawing` from a `Sendable` payload. RUNS ON
    /// THE MAIN ACTOR (called from the SwiftUI view, never the document) — this is
    /// where the value data crosses from the off-main document into the
    /// `@MainActor` model, AFTER the launch-critical document init has finished.
    @MainActor
    static func make(from payload: DXFPayload) -> CADDrawing {
        let drawing = CADDrawing()
        drawing.load(
            entities: payload.entities,
            layers: payload.layers,
            blocks: payload.blocks,
            graphicVariables: payload.graphicVariables
        )
        return drawing
    }

    /// Captures this live drawing's current contents as a `Sendable` payload for
    /// the document to write. Main actor (the drawing is `@MainActor`); the
    /// returned value is safe to hand to the off-main serializer.
    @MainActor
    var payloadSnapshot: DXFPayload {
        DXFPayload(
            entities: entities,
            layers: layers,
            blocks: blocks,
            graphicVariables: graphicVariables
        )
    }
}

// MARK: - Off-main DXF (de)serialization

/// Pure-`Sendable`, off-main DXF read/write used by the document entry points.
/// All methods are `nonisolated` and operate ONLY on value types and file bytes;
/// none touches a `@MainActor` type. They bridge the async engine actor (the
/// documented single libdxfrw serialization point) to the synchronous
/// `ReferenceFileDocument` requirements with a semaphore — SAFE because the
/// document entry points run on a background queue (never main).
enum DXFDocumentCodec {

    /// The on-disk drawing format the codec reads/writes. DXF is ASCII text; DWG
    /// is binary AutoCAD. Both flow through the same engine value model — only the
    /// bridge function (and the temp-file extension) differ.
    enum Format {
        case dxf
        case dwg

        /// The temp-file extension the bridge keys nothing on (it reads by path),
        /// but kept format-correct so the file is self-describing on disk.
        var ext: String { self == .dwg ? "dwg" : "dxf" }
    }

    /// Errors surfaced to the SwiftUI document machinery (mapped to user alerts).
    enum CodecError: Error {
        /// The read configuration carried no regular-file bytes.
        case noFileContents
        /// Reading/writing the temp file used to bridge the path-only C API failed.
        case tempFileFailed
        /// The engine reader/writer threw (bad/corrupt DXF/DWG, I/O).
        case engine(Error)
    }

    /// Parses drawing `data` (DXF or DWG per `format`) into a `Sendable` payload,
    /// OFF the main actor. Writes the bytes to a temp file (the bridge reads by
    /// path only), parses through the shared engine actor's matching read path,
    /// then removes the temp file. Never touches a `@MainActor` type — safe to
    /// call from `init(configuration:)`.
    static func payload(from data: Data, format: Format = .dxf) throws -> DXFPayload {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("librecad-open-\(UUID().uuidString).\(format.ext)")
        do {
            try data.write(to: tmp, options: .atomic)
        } catch {
            throw CodecError.tempFileFailed
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let result = try runBlocking {
                switch format {
                case .dxf: return try await CADEngine.shared.readEntities(dxfPath: tmp.path)
                case .dwg: return try await CADEngine.shared.readEntities(dwgPath: tmp.path)
                }
            }
            // Carry the parsed BLOCKS and HEADER graphic variables through to the
            // drawing — NOT empty placeholders. Dropping `result.graphicVariables`
            // here made every opened file fall back to the `GraphicVariables()`
            // default `$DIMTXT` (2.5), so a file whose real `$DIMTXT` is e.g. 0.125
            // rendered its dimension/constraint text ~20× too big (the resolve reads
            // the document `$DIMTXT` via `dimStyleProvider`). Dropping `result.blocks`
            // likewise left INSERTs with no geometry to expand.
            return DXFPayload(
                entities: result.records,
                layers: result.layers,
                blocks: result.blocks,
                graphicVariables: result.graphicVariables
            )
        } catch {
            throw CodecError.engine(error)
        }
    }

    /// Serializes a `Sendable` payload to drawing bytes (DXF or DWG per `format`),
    /// OFF the main actor. Writes to a temp file through the shared engine actor's
    /// matching write path (path-only C API), reads the bytes back, then removes
    /// the temp file. Never touches a `@MainActor` type — safe to call from
    /// `fileWrapper(snapshot:configuration:)`.
    static func data(from payload: DXFPayload, format: Format = .dxf) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("librecad-save-\(UUID().uuidString).\(format.ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            _ = try runBlocking {
                switch format {
                case .dxf:
                    return try await CADEngine.shared.writeEntities(
                        payload.entities, layers: payload.layers, toPath: tmp.path
                    )
                case .dwg:
                    return try await CADEngine.shared.writeEntities(
                        payload.entities, layers: payload.layers, toDWGPath: tmp.path
                    )
                }
            }
        } catch {
            throw CodecError.engine(error)
        }

        do {
            return try Data(contentsOf: tmp)
        } catch {
            throw CodecError.tempFileFailed
        }
    }

    /// Runs an async, `Sendable`-returning engine call to completion synchronously
    /// from a background thread. The result/error is shuttled out via a box; the
    /// caller's thread blocks on a semaphore until the detached task signals.
    ///
    /// SAFETY: only ever called from the document's off-main entry points (a
    /// background queue). Blocking there does NOT freeze the UI and cannot
    /// deadlock the main actor; the engine actor runs on the global concurrent
    /// executor, so the awaited work completes on a different thread.
    private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            do {
                box.value = .success(try await work())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .success(let v): return v
        case .failure(let e): throw e
        case .none: throw CodecError.engine(CADEngineError.readFailed)
        }
    }

    /// A minimal one-shot result hand-off across the detached task / semaphore
    /// boundary. `@unchecked Sendable` is sound: exactly one write (in the task)
    /// happens-before the single read (after `semaphore.wait()`), so there is no
    /// concurrent access.
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        var value: Result<T, Error>?
    }
}

// MARK: - The document

/// The DXF document backing `DocumentGroup`. A `ReferenceFileDocument` (reference
/// type) so the live `CanvasModel` the view builds can drive Save by snapshotting
/// the document's payload; the document is the source of truth for the FILE, the
/// `CanvasModel` for the live EDIT session.
///
/// Launch-safety invariant: `init(configuration:)`, `snapshot`, and `fileWrapper`
/// touch ONLY `DXFPayload` (Sendable value data). They never construct a
/// `CADDrawing`/`CanvasModel` and never call `MainActor.assumeIsolated` — that is
/// the exact off-main isolation trap that crashed the previous build.
///
/// `@unchecked Sendable`: `ReferenceFileDocument` requires `Sendable`, but the
/// document holds a mutable `payload`. The access pattern is single-writer per
/// phase and never concurrent: `init` writes it once (off-main, before the view
/// exists); thereafter only the view (main actor) writes via `updatePayload(_:)`,
/// and `snapshot` (main actor) reads it. `DXFPayload` is itself a `Sendable` value
/// type, so any value handed across actors is a safe copy.
final class LibreCADDocument: ReferenceFileDocument, @unchecked Sendable {

    /// The snapshot type written to disk: the same `Sendable` payload the document
    /// holds, captured on the main actor in `snapshot(contentType:)`.
    typealias Snapshot = DXFPayload

    /// The parsed file contents (Sendable value data). Updated by the view's
    /// `CanvasModel` after edits via `updatePayload(_:)` so Save writes the latest
    /// geometry. NOT `@MainActor` — it is plain value state on the document.
    private(set) var payload: DXFPayload

    /// Readable types: DXF (text) AND DWG (binary AutoCAD). For each we accept the
    /// declared UTI plus the extension-derived type, so double-click / Open work
    /// regardless of which UTI Launch Services resolves the file to.
    static var readableContentTypes: [UTType] { dxfTypes + dwgTypes }
    /// Writable types: DXF and DWG. DWG write covers top-level geometry + the
    /// standard tables at R2000; a block's MEMBER geometry does NOT round-trip to
    /// DWG (libdxfrw writes empty blocks) — full block content needs DXF.
    static var writableContentTypes: [UTType] { dxfTypes + dwgTypes }

    /// The DXF content types: the exported UTI first, then the extension-derived
    /// type as a robust fallback.
    static let dxfTypes: [UTType] = {
        var types: [UTType] = [.librecadDXF]
        if let byExt = UTType(filenameExtension: "dxf"), !types.contains(byExt) {
            types.append(byExt)
        }
        return types
    }()

    /// The DWG content types: the system `com.autodesk.dwg` UTI first, then the
    /// extension-derived type as a robust fallback (same pattern as `dxfTypes`).
    static let dwgTypes: [UTType] = {
        var types: [UTType] = [.librecadDWG]
        if let byExt = UTType(filenameExtension: "dwg"), !types.contains(byExt) {
            types.append(byExt)
        }
        return types
    }()

    /// Classifies a content type as DXF or DWG so the codec routes to the right
    /// engine path. A type that conforms to (or matches) any DWG type is DWG;
    /// everything else (the default) is treated as DXF.
    static func format(for contentType: UTType) -> DXFDocumentCodec.Format {
        for t in dwgTypes where contentType == t || contentType.conforms(to: t) {
            return .dwg
        }
        if contentType.preferredFilenameExtension?.lowercased() == "dwg" { return .dwg }
        return .dxf
    }

    /// File ▸ New: an empty document (one default layer "0"). Synchronous, value
    /// data only — no engine call, no `@MainActor` access.
    init() {
        self.payload = .empty
    }

    /// File ▸ Open / Open Recent / double-click. RUNS OFF THE MAIN ACTOR (NSDocument
    /// constructs the document on a background queue). It parses the DXF bytes into
    /// the `Sendable` payload via the off-main engine codec and stores ONLY that —
    /// it does NOT build a `CADDrawing`/`CanvasModel` and does NOT call
    /// `MainActor.assumeIsolated`. (That off-main isolation assertion is the exact
    /// crash this whole design exists to avoid.)
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw DXFDocumentCodec.CodecError.noFileContents
        }
        // Route to the DXF or DWG read path by the opened file's content type
        // (binary DWG and text DXF need different libdxfrw parsers).
        let format = Self.format(for: configuration.contentType)
        self.payload = try DXFDocumentCodec.payload(from: data, format: format)
    }

    /// Captures the document's current payload for a write. Called on the main
    /// actor by SwiftUI; returns the `Sendable` value snapshot (the actual
    /// serialization happens off-main in `fileWrapper`). No `@MainActor` model is
    /// touched — the view has already pushed the latest geometry into `payload`
    /// via `updatePayload(_:)`.
    func snapshot(contentType: UTType) throws -> DXFPayload {
        payload
    }

    /// Serializes a captured snapshot to a DXF `FileWrapper`. RUNS OFF THE MAIN
    /// ACTOR. Operates ONLY on the `Sendable` snapshot via the off-main engine
    /// codec; no `@MainActor` access.
    func fileWrapper(
        snapshot: DXFPayload,
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        // Serialize as DXF or DWG per the destination content type (Save As can
        // switch formats); the codec routes to the matching engine write path.
        let format = Self.format(for: configuration.contentType)
        let data = try DXFDocumentCodec.data(from: snapshot, format: format)
        return FileWrapper(regularFileWithContents: data)
    }

    /// Pushes the live drawing's latest geometry back into the document's payload
    /// so the NEXT Save/autosave writes it. Called from the view (main actor) after
    /// edits / before a save snapshot. Pure value assignment — Sendable in, no
    /// engine call. (Marking the document dirty is driven by SwiftUI's
    /// `UndoManager` registrations in the view; this just keeps the payload current.)
    func updatePayload(_ newPayload: DXFPayload) {
        payload = newPayload
    }
}
