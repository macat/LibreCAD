//
//  DrawingRepository.swift
//  CADEngine
//
//  Wave 6 — Persistence & undo modernization (M).
//
//  Provides a durable native format (.lcad versioned JSON) that preserves the
//  full document model (constraints / parameters / tables / layouts / blocks …)
//  which DXF drops, and modernizes undo to a structural-sharing diff log.
//
//  Two repositories behind one protocol:
//
//    • NativeJSONRepository — .lcad versioned JSON, lossless.
//    • DXFRepository          — existing DXFReader/Writer, lossy but explicit.
//
//  Undo is modeled as `DrawingEdit` (.add / .remove / .replace) and `UndoLog`
//  which stores the diff, not a whole-array CoW snapshot. For this wave the log
//  is additive: CADDrawing.add/replace/remove emit a DrawingEdit to the log
//  while keeping UndoManager as adapter so existing tests pass. Full
//  persistent-array can be follow-up.
//
//  CADEngine ⊥ app — no LibreCADmacOS import.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Foundation

// MARK: - DrawingEdit (structural-sharing diff, not whole-array copy)

/// One atomic edit to the drawing's entity store — the unit stored in `UndoLog`
/// instead of a whole-array CoW snapshot (Wave 6, A6). Value type, Sendable, so
/// the log snapshots cheaply and crosses actor boundaries.
public enum DrawingEdit: Sendable, Equatable {
    /// An entity was added.
    case add(EntityRecord)
    /// An entity was removed from `index` (its original draw-order position).
    case remove(EntityRecord, at: Int)
    /// An entity with the same id was replaced (old → new).
    case replace(old: EntityRecord, new: EntityRecord)

    /// The inverse edit (what undo should apply).
    public var inverse: DrawingEdit {
        switch self {
        case .add(let r): return .remove(r, at: -1)
        case .remove(let r, _): return .add(r)
        case .replace(let o, let n): return .replace(old: n, new: o)
        }
    }
}

// MARK: - UndoLog (structural-sharing, not whole-array CoW)

/// An undo log that stores `DrawingEdit` diffs rather than whole-array CoW
/// snapshots (Wave 6 A6). Each committed mutation appends one `DrawingEdit`;
/// undo pops the last edit and returns it so the caller can apply the inverse.
/// Redo is the symmetrical redo stack. Groups are implicit: one
/// UndoManager transaction == one `UndoLog` entry in this wave; a follow-up
/// can coalesce edits into a persistent-array transaction if needed.
///
/// Value type so CADDrawing snapshots it cheaply; Sendable so it can be read
/// off-main in tests.
public struct UndoLog: Sendable, Equatable {
    /// Recorded edits, oldest first. Each `add`/`remove`/`replace` that mutates
    /// the drawing appends one entry (no-op edits append nothing).
    public private(set) var edits: [DrawingEdit] = []
    /// Redo stack: edits that were undone and can be redone.
    public private(set) var redoStack: [DrawingEdit] = []

    public init() {}

    /// Records an edit and clears the redo stack (a new branch).
    public mutating func record(_ edit: DrawingEdit) {
        edits.append(edit)
        redoStack.removeAll()
    }

    /// Pops the last edit for undo, pushing it onto the redo stack. Returns
    /// nil if nothing to undo.
    @discardableResult
    public mutating func popUndo() -> DrawingEdit? {
        guard let last = edits.popLast() else { return nil }
        redoStack.append(last)
        return last
    }

    /// Pops the last redo edit, re-recording it on the undo stack. Returns nil
    /// if nothing to redo.
    @discardableResult
    public mutating func popRedo() -> DrawingEdit? {
        guard let last = redoStack.popLast() else { return nil }
        edits.append(last)
        return last
    }

    /// Whether an undo is available.
    public var canUndo: Bool { !edits.isEmpty }
    /// Whether a redo is available.
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Total number of recorded edits (not counting redos).
    public var count: Int { edits.count }

    /// Clears both stacks.
    public mutating func clear() {
        edits.removeAll()
        redoStack.removeAll()
    }

    /// The most recent edit, if any.
    public var lastEdit: DrawingEdit? { edits.last }
}

// MARK: - Native drawing snapshot (versioned JSON)

/// Versioned Codable snapshot of the full drawing — the source of truth for the
/// native `.lcad` format (Wave 6). Every field is Codable and additive: older
/// files missing a key decode to the same defaults `CADDrawing.load` uses, so
/// loading a v0 file never throws.
///
/// `version` is the file-format version (current 1). Migration is handled in
/// `init(from:)` via `decodeIfPresent` with defaults, so an older payload that
/// pre-dates a field loads as empty/default rather than failing — the same
/// additive back-compat idiom every `*Data` / table type uses.
public struct NativeDrawingSnapshot: Sendable, Equatable, Codable {
    /// Current native file format version. Bumped when the schema adds a
    /// required field or changes semantics.
    public static let currentVersion: Int = 1

    /// File format version this snapshot was written with.
    public var version: Int
    public var entities: [EntityRecord]
    public var layers: LayerTable
    public var blocks: BlockTable
    public var graphicVariables: GraphicVariables
    public var dimStyles: DimStyleTable
    public var textStyles: TextStyleTable
    public var layouts: [Layout]
    public var tables: [TableObject]
    public var constraints: ConstraintTable
    public var parameters: ParameterTable

    public init(
        version: Int = NativeDrawingSnapshot.currentVersion,
        entities: [EntityRecord] = [],
        layers: LayerTable = LayerTable(),
        blocks: BlockTable = BlockTable(),
        graphicVariables: GraphicVariables = GraphicVariables(),
        dimStyles: DimStyleTable = DimStyleTable(),
        textStyles: TextStyleTable = TextStyleTable(),
        layouts: [Layout] = [],
        tables: [TableObject] = [],
        constraints: ConstraintTable = ConstraintTable(),
        parameters: ParameterTable = ParameterTable()
    ) {
        self.version = version
        self.entities = entities
        self.layers = layers
        self.blocks = blocks
        self.graphicVariables = graphicVariables
        self.dimStyles = dimStyles
        self.textStyles = textStyles
        self.layouts = layouts
        self.tables = tables
        self.constraints = constraints
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case entities, layers, blocks, graphicVariables, dimStyles, textStyles
        case layouts, tables, constraints, parameters
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Additive: missing version ⇒ 0 (pre-versioned file), treated as v1.
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        entities = try c.decodeIfPresent([EntityRecord].self, forKey: .entities) ?? []
        layers = try c.decodeIfPresent(LayerTable.self, forKey: .layers) ?? LayerTable()
        blocks = try c.decodeIfPresent(BlockTable.self, forKey: .blocks) ?? BlockTable()
        graphicVariables = try c.decodeIfPresent(GraphicVariables.self, forKey: .graphicVariables) ?? GraphicVariables()
        dimStyles = try c.decodeIfPresent(DimStyleTable.self, forKey: .dimStyles) ?? DimStyleTable()
        textStyles = try c.decodeIfPresent(TextStyleTable.self, forKey: .textStyles) ?? TextStyleTable()
        layouts = try c.decodeIfPresent([Layout].self, forKey: .layouts) ?? []
        tables = try c.decodeIfPresent([TableObject].self, forKey: .tables) ?? []
        constraints = try c.decodeIfPresent(ConstraintTable.self, forKey: .constraints) ?? ConstraintTable()
        parameters = try c.decodeIfPresent(ParameterTable.self, forKey: .parameters) ?? ParameterTable()
    }

    /// Migration hook: if `version` == 0 (pre-versioned) and constraints etc
    /// are empty, no migration is needed — the additive defaults already match
    /// the current schema. Future versions can switch on `version` here.
    public func migrated() -> NativeDrawingSnapshot {
        var s = self
        if s.version == 0 { s.version = Self.currentVersion }
        return s
    }
}

// MARK: - DrawingRepository protocol

/// Persistence seam (Wave 6 A5). Two implementations: native JSON (lossless) and
/// DXF (lossy but explicit).
public protocol DrawingRepository: Sendable {
    /// Loads a drawing from `url`. The native repo reads `.lcad` JSON; the DXF
    /// repo reads DXF/DWG via the bridge. Throws on I/O or parse failure.
    @MainActor func load(from url: URL) throws -> CADDrawing
    /// Saves `drawing` to `url`, overwriting it. Throws on I/O or write failure.
    @MainActor func save(_ drawing: CADDrawing, to url: URL) throws
}

// MARK: - NativeJSONRepository (lossless, versioned)

/// The native `.lcad` repository (Wave 6). Persists the full document model as
/// versioned JSON (`NativeDrawingSnapshot`), preserving constraints/parameters/
/// tables/layouts/blocks/textStyles which DXF drops.
public struct NativeJSONRepository: DrawingRepository, Sendable {
    public init() {}

    @MainActor
    public func load(from url: URL) throws -> CADDrawing {
        let data = try Data(contentsOf: url)
        return try load(from: data)
    }

    /// Loads from raw JSON data. Must be called on the MainActor because it
    /// constructs a `@MainActor CADDrawing`.
    @MainActor
    public func load(from data: Data) throws -> CADDrawing {
        let snapshot = try decodeSnapshot(from: data)
        return makeDrawing(from: snapshot)
    }

    @MainActor
    public func save(_ drawing: CADDrawing, to url: URL) throws {
        let data = try encode(drawing: drawing)
        try data.write(to: url, options: .atomic)
    }

    /// Encodes `drawing` to native JSON data (off-main safe — reads MainActor
    /// state synchronously; call on MainActor or via `MainActor.assumeIsolated`).
    @MainActor
    public func encode(drawing: CADDrawing) throws -> Data {
        let snapshot = NativeDrawingSnapshot(
            version: NativeDrawingSnapshot.currentVersion,
            entities: drawing.entities,
            layers: drawing.layers,
            blocks: drawing.blocks,
            graphicVariables: drawing.graphicVariables,
            dimStyles: drawing.dimStyles,
            textStyles: drawing.textStyles,
            layouts: drawing.layouts,
            tables: drawing.tables,
            constraints: drawing.constraints,
            parameters: drawing.parameters
        )
        return try encodeSnapshot(snapshot)
    }

    // MARK: Data helpers (Sendable, off-main)

    /// Decodes a snapshot from JSON data (pure, off-main).
    public func decodeSnapshot(from data: Data) throws -> NativeDrawingSnapshot {
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(NativeDrawingSnapshot.self, from: data)
        return snapshot.migrated()
    }

    /// Encodes a snapshot to JSON data (pure, off-main, sorted keys for determinism).
    public func encodeSnapshot(_ snapshot: NativeDrawingSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Convenience: encode a snapshot value directly (off-main, Sendable).
    public func data(from snapshot: NativeDrawingSnapshot) throws -> Data {
        try encodeSnapshot(snapshot)
    }

    /// Convenience: decode data to a snapshot (off-main, Sendable).
    public func snapshot(from data: Data) throws -> NativeDrawingSnapshot {
        try decodeSnapshot(from: data)
    }
}

// MARK: - DXFRepository (lossy but explicit)

/// The DXF/DWG repository (Wave 6). Wraps the existing `CADEngine` DXFReader/
/// Writer path (libdxfrw via DxfBridge). Lossy: constraints / parameters / tables
/// are NOT written (DXF has no native representation), and the loaded drawing
/// always has empty tables for those. Callers that need those must use
/// `NativeJSONRepository`.
public struct DXFRepository: DrawingRepository, Sendable {
    public init() {}

    @MainActor
    public func load(from url: URL) throws -> CADDrawing {
        let isDWG = url.pathExtension.lowercased() == "dwg"
        let result: CADEngine.DXFReadResult
        if isDWG {
            result = try runBlocking { try await CADEngine.shared.readEntities(dwgPath: url.path) }
        } else {
            result = try runBlocking { try await CADEngine.shared.readEntities(dxfPath: url.path) }
        }
        // Also load dim styles (the full named table) when available.
        let dimStyles: DimStyleTable
        do {
            dimStyles = try runBlocking {
                try await CADEngine.shared.readDimStyles(path: url.path, dwg: isDWG)
            }
        } catch {
            dimStyles = DimStyleTable()
        }
        // Backfill ext-line offsets into graphicVariables like DXFDocumentCodec does.
        var gv = result.graphicVariables
        if let active = dimStyles.active()?.style {
            if !gv.has("$DIMEXO"), active.extensionOffset > 0 { gv.dimExtensionOffset = active.extensionOffset }
            if !gv.has("$DIMEXE"), active.extensionBeyond > 0 { gv.dimExtensionBeyond = active.extensionBeyond }
            if !gv.has("$DIMGAP"), active.textGap > 0 { gv.dimTextGap = active.textGap }
        }
        let drawing = CADDrawing()
        drawing.load(
            entities: result.records,
            layers: result.layers,
            blocks: result.blocks,
            graphicVariables: gv,
            dimStyles: dimStyles,
            textStyles: result.textStyles,
            layouts: result.layouts,
            // Lossy: DXF cannot carry constraints / parameters / tables — always empty.
            constraints: ConstraintTable(),
            parameters: ParameterTable(),
            tables: []
        )
        return drawing
    }

    @MainActor
    public func save(_ drawing: CADDrawing, to url: URL) throws {
        let isDWG = url.pathExtension.lowercased() == "dwg"
        let entitiesByID = Dictionary(
            drawing.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let blockMembers: [String: [EntityRecord]] = drawing.blocks.blocks.reduce(into: [:]) {
            $0[$1.name] = $1.entityIDs.compactMap { entitiesByID[$0] }
        }
        if isDWG {
            _ = try runBlocking {
                try await CADEngine.shared.writeEntities(
                    drawing.entities, layers: drawing.layers,
                    blocks: drawing.blocks, blockMembers: blockMembers,
                    graphicVariables: drawing.graphicVariables,
                    dimStyles: drawing.dimStyles,
                    textStyles: drawing.textStyles,
                    layouts: drawing.layouts,
                    tables: drawing.tables,
                    toDWGPath: url.path, version: .r2000)
            }
        } else {
            _ = try runBlocking {
                try await CADEngine.shared.writeEntities(
                    drawing.entities, layers: drawing.layers,
                    blocks: drawing.blocks, blockMembers: blockMembers,
                    graphicVariables: drawing.graphicVariables,
                    dimStyles: drawing.dimStyles,
                    textStyles: drawing.textStyles,
                    layouts: drawing.layouts,
                    tables: drawing.tables,
                    toPath: url.path, version: .r2000)
            }
        }
    }
}

// MARK: - Helpers

/// Builds a live @MainActor CADDrawing from a snapshot (value types only).
@MainActor
func makeDrawing(from snapshot: NativeDrawingSnapshot) -> CADDrawing {
    let d = CADDrawing()
    d.load(
        entities: snapshot.entities,
        layers: snapshot.layers,
        blocks: snapshot.blocks,
        graphicVariables: snapshot.graphicVariables,
        dimStyles: snapshot.dimStyles,
        textStyles: snapshot.textStyles,
        layouts: snapshot.layouts,
        constraints: snapshot.constraints,
        parameters: snapshot.parameters,
        tables: snapshot.tables
    )
    return d
}

/// Encodes a snapshot to JSON data (off-main, Sendable).
func encodeSnapshot(_ snapshot: NativeDrawingSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(snapshot)
}

// Box for runBlocking — must be file-scope (Swift disallows generic local classes).
private final class RunBlockingBox<T: Sendable>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// Runs an async Sendable engine call synchronously from a (possibly) main-
/// actor context. The caller's thread blocks on a semaphore until the detached
/// task signals — safe when called from the document's background queue; when
/// called on the main actor (repository's @MainActor save/load) it still
/// works because the engine actor runs on the global concurrent executor, not
/// the main actor. For very large drawings this blocks the main thread briefly
/// (DXF I/O); a future wave can make the repository async.
private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = RunBlockingBox<T>()
    Task.detached {
        do { box.value = Result<T, Error>.success(try await work()) }
        catch { box.value = Result<T, Error>.failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    switch box.value {
    case .success(let v): return v
    case .failure(let e): throw e
    case .none: throw CADEngineError.readFailed
    }
}
