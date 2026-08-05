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
// Bring the engine's paper-space `Layout` struct in BY NAME so it shadows
// SwiftUI's `Layout` protocol in this SwiftUI-importing module (a targeted
// `import struct` takes precedence over the broad `import SwiftUI`, so the bare
// `Layout` below resolves unambiguously to the engine struct). A `CADEngine.`
// qualifier can't be used: the module name collides with the engine ACTOR of the
// same name, so `CADEngine.Layout` would resolve to the actor, not the module.
import struct CADEngine.Layout

// MARK: - Sendable document payload

/// The document's parsed contents as `Sendable` value types — the ONLY state the
/// document holds. Everything here crosses actor boundaries freely (it is what
/// the engine reader returns and the writer accepts), so the off-main document
/// entry points can build/serialize it without ever touching the `@MainActor`
/// `CADDrawing`. The live drawing is reconstructed from this in the view on the
/// main actor (see `CADDrawing.make(from:)`).
///
/// `Codable` (additive, back-compat): every field is itself `Codable`, and the
/// custom `init(from:)` below decodes the two parametric tables
/// (`constraints`/`parameters`) with `decodeIfPresent` so a payload encoded BEFORE
/// those keys existed (an old serialized snapshot) decodes to EMPTY tables rather
/// than failing — the same back-compat contract the entity `*Data` structs and the
/// two tables' own decoders use.
struct DXFPayload: Sendable, Equatable, Codable {
    /// Entities in stable draw order, ids already minted by the reader.
    var entities: [EntityRecord]
    /// The parsed layer table (always carries at least layer "0" for a new doc).
    var layers: LayerTable
    /// Block definitions (id-refs into `entities`).
    var blocks: BlockTable
    /// Header graphic variables ($INSUNITS et al.).
    var graphicVariables: GraphicVariables
    /// The named DIMSTYLE table (named dim styles + ext-line offsets). Carried so a
    /// save preserves named styles — symmetric to `graphicVariables`/`blocks`.
    var dimStyles: DimStyleTable
    /// The paper-space LAYOUT table — the named sheets (paper-space P0). Carried so
    /// the native value-model round-trip preserves layouts + the per-entity space
    /// tag (which travels on the `EntityRecord`s in `entities`). Symmetric to
    /// `dimStyles`/`blocks`. (Paper-space P3: a SAVE to DXF now DOES carry layouts +
    /// their viewports to disk via the bridge writer; DWG viewport write + multi-layout
    /// DXF remain follow-ups.)
    var layouts: [Layout]
    /// The TABLE-OBJECT list (`TableObject`) — ADDITIVE document state (NOT an
    /// `EntityKind`), the editable ACAD_TABLE-style grids. Carried so the in-session
    /// model's `drawing.tables` SURVIVES the document snapshot/restore (undo +
    /// autosave-via-payload). Symmetric to `layouts`/`dimStyles`.
    ///
    /// PURE-DXF CAVEAT (the documented limit): on a Save the writer EXPLODES each table
    /// to loose LINE + TEXT geometry (libdxfrw drops the real ACAD_TABLE on read — a
    /// confirmed dead-end), so a table SAVED to .dxf and REOPENED from disk comes back
    /// as loose LINEs + TEXT, NOT a re-editable `TableObject` — `payload(from:)` always
    /// decodes `tables` to `[]` (the read path has no table source). The editable model
    /// rides ONLY this in-session payload; it is exploded on a pure-DXF reopen.
    var tables: [TableObject]
    /// The parametric CONSTRAINT table (`constraints`) — ADDITIVE document state (NOT an
    /// `EntityKind`). Carried so the in-session model's `drawing.constraints` SURVIVES the
    /// document snapshot/restore (undo + autosave-via-payload). Symmetric to `tables`.
    /// Previously the constraint table rode the LIVE model + undo, but was DROPPED on a
    /// `payloadSnapshot` → `make(from:)` round-trip — so a constraint was lost across a
    /// document snapshot/restore. Threading it here (Lane L3) closes that in-session gap.
    ///
    /// PURE-DXF CAVEAT (the documented limit — IDENTICAL to `tables`): DXF cannot carry a
    /// native constraint, so the read path (`payload(from:)`) has NO source for it and
    /// always decodes `constraints` to an EMPTY table. The constraint table therefore
    /// rides ONLY this in-session payload (undo / snapshot-restore / autosave-via-payload);
    /// a pure-`.dxf` save → reopen-from-disk still DROPS constraints. (No DXF-bytes
    /// encoding of constraints is attempted in this lane.)
    var constraints: ConstraintTable
    /// The named-PARAMETER table (`parameters`) — ADDITIVE document state (NOT an
    /// `EntityKind`). Carried so the in-session model's `drawing.parameters` SURVIVES the
    /// document snapshot/restore (undo + autosave-via-payload). Symmetric to `constraints`.
    ///
    /// PURE-DXF CAVEAT (the documented limit — IDENTICAL to `constraints`): DXF cannot carry
    /// a named parameter, so the read path (`payload(from:)`) has NO source for it and always
    /// decodes `parameters` to an EMPTY table. The parameter table rides ONLY this in-session
    /// payload; a pure-`.dxf` save → reopen-from-disk still DROPS parameters.
    var parameters: ParameterTable
    /// The text-style registry (STYLE table). ADDITIVE (Wave 6): carried so a TEXT/
    /// MTEXT entity's code-7 style name survives the in-session round-trip AND the
    /// native `.lcad` save. DXF round-trip already preserves it via the bridge, but
    /// the payload now also carries it for snapshot/restore.
    var textStyles: TextStyleTable

    init(
        entities: [EntityRecord] = [],
        layers: LayerTable = LayerTable(),
        blocks: BlockTable = BlockTable(),
        graphicVariables: GraphicVariables = GraphicVariables(),
        dimStyles: DimStyleTable = DimStyleTable(),
        layouts: [Layout] = [],
        tables: [TableObject] = [],
        constraints: ConstraintTable = ConstraintTable(),
        parameters: ParameterTable = ParameterTable(),
        textStyles: TextStyleTable = TextStyleTable()
    ) {
        self.entities = entities
        self.layers = layers
        self.blocks = blocks
        self.graphicVariables = graphicVariables
        self.dimStyles = dimStyles
        self.layouts = layouts
        self.tables = tables
        self.constraints = constraints
        self.parameters = parameters
        self.textStyles = textStyles
    }

    // MARK: - Codable (additive, back-compat)
    //
    // Explicit keys + a custom `init(from:)` so the two parametric tables decode with
    // `decodeIfPresent` → empty: a payload encoded BEFORE these keys existed (an old
    // serialized snapshot) loads with no constraints/parameters instead of throwing. The
    // pre-existing fields keep their synthesized round-trip. `encode(to:)` stays
    // synthesized (Swift derives it from the same `CodingKeys`).

    private enum CodingKeys: String, CodingKey {
        case entities, layers, blocks, graphicVariables, dimStyles, layouts, tables
        case constraints, parameters, textStyles
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entities = try c.decode([EntityRecord].self, forKey: .entities)
        layers = try c.decode(LayerTable.self, forKey: .layers)
        blocks = try c.decode(BlockTable.self, forKey: .blocks)
        graphicVariables = try c.decode(GraphicVariables.self, forKey: .graphicVariables)
        dimStyles = try c.decode(DimStyleTable.self, forKey: .dimStyles)
        layouts = try c.decode([Layout].self, forKey: .layouts)
        tables = try c.decode([TableObject].self, forKey: .tables)
        // The two parametric tables are ADDITIVE: an old payload (encoded before these
        // keys existed) omits them, so decode them forgivingly to an EMPTY table — the
        // same back-compat the tables' own `init(from:)` and the entity `*Data` structs use.
        constraints = try c.decodeIfPresent(ConstraintTable.self, forKey: .constraints) ?? ConstraintTable()
        parameters = try c.decodeIfPresent(ParameterTable.self, forKey: .parameters) ?? ParameterTable()
        textStyles = try c.decodeIfPresent(TextStyleTable.self, forKey: .textStyles) ?? TextStyleTable()
    }

    /// An empty drawing for File ▸ New: no entities, the default layer table
    /// (`LayerTable()` already seeds layer "0", which DXF requires), default
    /// header. Pure value data — no engine call, no `@MainActor` access.
    static var empty: DXFPayload {
        DXFPayload(layers: LayerTable())
    }
}

// MARK: - New-document preference seeding (Preferences ▸ General)
//
// Pure helpers for the General-tab prefs (default units / default template /
// autosave) the new-document path consults. Free of SwiftUI/AppKit so they are
// unit-tested headlessly (`PrefsWiringTests`); the SwiftUI read-site
// (`ContentView.loadFromDocument`) just calls them with the stored `@AppStorage`
// values. The whole contract: a fresh File ▸ New gets the preferred units (and the
// preferred template, if set), while an opened DXF keeps its own header — so the
// pref never silently rewrites an existing drawing.
enum PrefsSeeding {

    /// The autosaving delay (seconds) used when the autosave preference is ON. A
    /// modest interval — autosave-in-place is incremental, so this is the "max age of
    /// unsaved work" knob, not a per-keystroke cost. 0 (the OFF value) disables the
    /// timed autosave entirely.
    static let autosaveDelaySeconds: TimeInterval = 30

    /// Whether `payload` is a brand-new EMPTY drawing (File ▸ New): no entities and no
    /// blocks. Such a payload is the only thing we seed from the General prefs — an
    /// opened file (any entities/blocks) is authoritative and left untouched.
    static func isNewEmptyPayload(_ payload: DXFPayload) -> Bool {
        payload.entities.isEmpty && payload.blocks.blocks.isEmpty
    }

    /// Returns `payload` with its `$INSUNITS` set from the stored default-unit raw
    /// value, ONLY when the payload is a new empty drawing that does not already carry
    /// an explicit `$INSUNITS`. An opened drawing (or one that already declares units)
    /// is returned unchanged. The raw value is decoded forgivingly (unknown code →
    /// the default unit), so a corrupt stored value can never produce a bad header.
    static func seededPayload(_ payload: DXFPayload, defaultUnitRaw: Int) -> DXFPayload {
        guard isNewEmptyPayload(payload), !payload.graphicVariables.has("$INSUNITS") else {
            return payload
        }
        var seeded = payload
        seeded.graphicVariables.unit = AppSettings.unit(fromRaw: defaultUnitRaw)
        return seeded
    }

    /// Maps a stored default-template PREF id (the `GeneralSettingsTab` picker tags:
    /// `"blank"`, `"a4_mm"`, `"letter_inch"`, `"iso_a3"`) to a bundled template
    /// RESOURCE name (`DrawingTemplate.resourceName`), or `nil` for "no template"
    /// (`"blank"`, empty, or an unknown id → seed units only, no pre-population). This
    /// is the bridge between the Preferences picker's stable tags and the on-disk
    /// template files, kept as a pure String→String? table so it is unit-tested
    /// without touching the bundle/file system.
    static func templateResourceName(forPrefID id: String) -> String? {
        switch id {
        case "a4_mm":       return "Titleblock_A4_Metric"
        case "letter_inch": return "Blank_Imperial"
        case "iso_a3":      return "Blank_Metric_A3"
        // "blank" / "" / unknown → no template (just seed the preferred units).
        default:            return nil
        }
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
            graphicVariables: payload.graphicVariables,
            dimStyles: payload.dimStyles,
            textStyles: payload.textStyles,
            layouts: payload.layouts,
            // Restore the in-session CONSTRAINT + PARAMETER tables (they ride the payload,
            // not the DXF bytes — see `DXFPayload.constraints`/`.parameters`). On a FRESH
            // file open both are EMPTY (the DXF read path has no source for them); on an
            // undo/autosave snapshot-restore they are the live tables, so a constraint /
            // parameter survives the round-trip in-session.
            constraints: payload.constraints,
            parameters: payload.parameters,
            // Restore the in-session TABLE-OBJECT list (it rides the payload, not the DXF
            // bytes — see `DXFPayload.tables`). On a FRESH file open this is `[]` (the DXF
            // read path has no table source); on an undo/autosave snapshot-restore it is
            // the live tables, so an edited table survives the round-trip in-session.
            tables: payload.tables
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
            graphicVariables: graphicVariables,
            dimStyles: dimStyles,
            layouts: layouts,
            // Capture the live TABLE-OBJECT list so the in-session model's tables ride the
            // payload (undo / autosave). On a SAVE the codec explodes them to LINE + TEXT
            // (see `DXFDocumentCodec.data`); within the session they survive verbatim.
            tables: tables,
            // Capture the live CONSTRAINT + PARAMETER tables so the in-session model's
            // `constraints`/`parameters` ride the payload (undo / autosave / snapshot-
            // restore). These do NOT reach the DXF bytes (DXF can't carry them — see the
            // caveats on `DXFPayload.constraints`/`.parameters`); within the session they
            // survive verbatim, closing the pre-existing snapshot gap (Lane L3).
            constraints: constraints,
            parameters: parameters,
            textStyles: textStyles
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
            let isDWG = (format == .dwg)
            let result = try runBlocking {
                switch format {
                case .dxf: return try await CADEngine.shared.readEntities(dxfPath: tmp.path)
                case .dwg: return try await CADEngine.shared.readEntities(dwgPath: tmp.path)
                }
            }
            // The full named DIMSTYLE table (`readEntities` collapses only the active
            // style into the `$DIM*` graphic vars; this preserves EVERY named style
            // + its ext-line offsets so a save→reopen round-trips the whole table).
            let dimStyles = try runBlocking {
                try await CADEngine.shared.readDimStyles(path: tmp.path, dwg: isDWG)
            }
            // Carry the parsed BLOCKS and HEADER graphic variables through to the
            // drawing — NOT empty placeholders. Dropping `result.graphicVariables`
            // here made every opened file fall back to the `GraphicVariables()`
            // default `$DIMTXT` (2.5), so a file whose real `$DIMTXT` is e.g. 0.125
            // rendered its dimension/constraint text ~20× too big (the resolve reads
            // the document `$DIMTXT` via `dimStyleProvider`). Dropping `result.blocks`
            // likewise left INSERTs with no geometry to expand.
            var gv = result.graphicVariables
            // The header-var → graphic-var mapping in the engine reader does not
            // surface the ext-line offsets ($DIMEXO/$DIMEXE/$DIMGAP); backfill the
            // document-default ext offsets from the ACTIVE DIMSTYLE so they reach the
            // resolve (the named-style middle rung still wins for styled dims). Only
            // set when the bag doesn't already carry the var (don't clobber a value
            // the reader did supply).
            if let active = dimStyles.active()?.style {
                if !gv.has("$DIMEXO"), active.extensionOffset > 0 {
                    gv.dimExtensionOffset = active.extensionOffset
                }
                if !gv.has("$DIMEXE"), active.extensionBeyond > 0 {
                    gv.dimExtensionBeyond = active.extensionBeyond
                }
                if !gv.has("$DIMGAP"), active.textGap > 0 {
                    gv.dimTextGap = active.textGap
                }
            }
            return DXFPayload(
                entities: result.records,
                layers: result.layers,
                blocks: result.blocks,
                graphicVariables: gv,
                dimStyles: dimStyles,
                // Paper-space P1/P3: carry the reconstructed layouts (and their
                // viewports) so an opened paper-space DXF shows its layout tabs +
                // viewports. Previously DROPPED here, so a paper-space file opened
                // with ZERO layout tabs and invisible paper entities (confirmed bug).
                layouts: result.layouts
                // DOCUMENTED LIMIT (Lane L3): `tables`, `constraints`, and `parameters`
                // are INTENTIONALLY omitted here, so they default to EMPTY. DXF (and DWG)
                // cannot carry a native table / constraint / parameter — the read path has
                // NO source for them — so a pure-`.dxf` save → reopen-from-disk drops them
                // (a table comes back as exploded LINE+TEXT; constraints/parameters come
                // back as nothing). They ride ONLY the in-session payload (snapshot/restore,
                // undo, autosave-via-payload) — see `DXFPayload.constraints`/`.parameters`.
            )
        } catch {
            throw CodecError.engine(error)
        }
    }

    /// Resolves a stored DXF-export-version raw string to the engine `DXFVersion` the
    /// writer accepts. PURE — no `UserDefaults`, no I/O — so it is fully unit-testable:
    /// it forwards to the app-settings forgiving decoder (`DXFExportVersion(rawValue:)` →
    /// fall back to the R2000 default on a blank / unknown / legacy string), then maps the
    /// settings tier to the engine type. An empty/absent string therefore resolves to the
    /// writer's existing default (`.r2000`), keeping legacy save behavior unchanged.
    static func dxfVersion(fromRaw raw: String?) -> DXFVersion {
        AppSettings.dxfExportVersion(fromRaw: raw ?? "").engineVersion
    }

    /// The DXF version the save path should write, resolved from the persisted
    /// `app.general.dxfExportVersion` preference. Reads `UserDefaults.standard` — which is
    /// reachable off-main (the codec runs on a background queue, never a `@MainActor`
    /// type) — and falls back to `.r2000` when the key is unset/garbage via the pure
    /// `dxfVersion(fromRaw:)` resolver. The defaults read is the ONLY side effect; the
    /// mapping itself is the pure helper above (which the tests exercise directly).
    static func resolvedDXFExportVersion() -> DXFVersion {
        let raw = UserDefaults.standard.string(forKey: AppSettings.Key.dxfExportVersion)
        return dxfVersion(fromRaw: raw)
    }

    /// Resolves a stored DWG-export-version raw string to the engine `DXFVersion` the
    /// DWG writer accepts. Mirrors `dxfVersion(fromRaw:)`. Clamps anything outside the
    /// 5 DWG-writable tiers {r2000, r2004, r2010, r2013, r2018} to `.r2000` — defense-
    /// in-depth even though the UI's `DWGExportVersion` picker excludes R2007/R12/R14.
    /// PURE — no `UserDefaults`, no I/O — so it is fully unit-testable.
    static func dwgVersion(fromRaw raw: String?) -> DXFVersion {
        AppSettings.dwgExportVersion(fromRaw: raw ?? "").engineVersion
    }

    /// The DWG version the save path should write, resolved from the persisted
    /// `app.general.dwgExportVersion` preference. Reads `UserDefaults.standard` off-main
    /// (the codec runs on a background queue) and falls back to `.r2000` when the key is
    /// unset/garbage. The defaults read is the ONLY side effect; the mapping itself is
    /// the pure `dwgVersion(fromRaw:)` helper (which tests exercise directly).
    static func resolvedDWGExportVersion() -> DXFVersion {
        let raw = UserDefaults.standard.string(forKey: AppSettings.Key.dwgExportVersion)
        return dwgVersion(fromRaw: raw)
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

        // Pass the BLOCKS + HEADER graphic variables + named DIMSTYLE table through
        // to the writer — symmetric to the read path. Dropping them on write was the
        // save-side twin of the read bug: a Save discarded the drawing's units / dim
        // styles / ext-line offsets / block member geometry, so a reopen fell back to
        // the engine defaults (e.g. $DIMTXT reset to 2.5). Resolve each block's member
        // ids to records (the writer authors the BLOCK definitions from these).
        let entitiesByID = Dictionary(
            payload.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let blockMembers: [String: [EntityRecord]] = payload.blocks.blocks.reduce(into: [:]) {
            $0[$1.name] = $1.entityIDs.compactMap { entitiesByID[$0] }
        }
        // The DXF format version to write, resolved from the persisted Preference
        // (`app.general.dxfExportVersion`) off-main here on the codec's background queue;
        // defaults to .r2000 (unchanged behavior) when unset. Only affects the .dxf branch.
        let dxfVersion = resolvedDXFExportVersion()
        // The DWG format version to write, resolved from `app.general.dwgExportVersion`.
        // Exposes R2000/R2004/R2010/R2013/R2018 — the 5 tiers the DWG writer supports;
        // R2007/R12/R14 are excluded from the UI picker and clamped to R2000 by the resolver.
        let dwgVersion = resolvedDWGExportVersion()
        do {
            _ = try runBlocking {
                switch format {
                case .dxf:
                    return try await CADEngine.shared.writeEntities(
                        payload.entities, layers: payload.layers,
                        blocks: payload.blocks, blockMembers: blockMembers,
                        graphicVariables: payload.graphicVariables,
                        dimStyles: payload.dimStyles,
                        // Paper-space P3: persist each layout's viewports as DXF
                        // VIEWPORT entities (symmetric to the read path).
                        layouts: payload.layouts,
                        // TABLES persistence: the writer EXPLODES each `TableObject` to
                        // loose LINE + TEXT geometry on disk (libdxfrw drops ACAD_TABLE,
                        // so there is no real table entity to author). The exploded
                        // geometry is visible on reopen here AND in AutoCAD / LibreCAD,
                        // but comes back as loose lines + text (NOT a re-editable table).
                        tables: payload.tables,
                        toPath: tmp.path,
                        // The user-chosen DXF version (Settings ▸ General ▸ Files);
                        // .r2000 default keeps the prior hardcoded behavior.
                        version: dxfVersion
                    )
                case .dwg:
                    return try await CADEngine.shared.writeEntities(
                        payload.entities, layers: payload.layers,
                        blocks: payload.blocks, blockMembers: blockMembers,
                        graphicVariables: payload.graphicVariables,
                        dimStyles: payload.dimStyles,
                        // DWG has no VIEWPORT write path (the library gap); the
                        // layouts are passed for symmetry but viewports aren't written.
                        layouts: payload.layouts,
                        // TABLES persistence: same explode-to-LINE+TEXT path as DXF (the
                        // exploded records flow through the standard DWG entity writer).
                        tables: payload.tables,
                        toDWGPath: tmp.path,
                        // The user-chosen DWG version (Settings ▸ General ▸ Files);
                        // .r2000 default keeps the prior hardcoded behavior.
                        version: dwgVersion
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

// MARK: - Native JSON codec (Wave 6 — lossless .lcad)

/// Wave 6 native codec (".lcad" versioned JSON). Preserves the full document
/// model — entities+layers+blocks+tables+constraints+params+layouts+textStyles —
/// which DXF drops. Off-main, Sendable value types only, so the document's
/// `init(configuration:)` and `fileWrapper` (which run on a background queue)
/// can call it without ever touching a `@MainActor` type.
enum NativeDocumentCodec {

    /// Current native file format version. Bumped when the schema changes.
    static let currentVersion: Int = 1

    /// Versioned wrapper so a file carries its schema version for migration.
    private struct VersionedPayload: Codable, Sendable {
        var version: Int
        var payload: DXFPayload
    }

    enum CodecError: Error {
        case decodeFailed(Error)
        case encodeFailed(Error)
    }

    /// Decodes `data` (native JSON) into a `Sendable` payload. Validates `version`
    /// and migrates if needed (currently v0 → v1 is a no-op because all fields
    /// decode forgivingly). Throws if the data is not native JSON.
    static func payload(from data: Data) throws -> DXFPayload {
        let decoder = JSONDecoder()
        do {
            // Try versioned wrapper first (current format).
            if let wrapped = try? decoder.decode(VersionedPayload.self, from: data) {
                // Migration: v0 (pre-versioned) is treated as v1; future versions
                // can switch on `wrapped.version` here.
                return wrapped.payload
            }
            // Fallback: bare payload (pre-versioned file that wrote DXFPayload directly).
            return try decoder.decode(DXFPayload.self, from: data)
        } catch {
            throw CodecError.decodeFailed(error)
        }
    }

    /// Encodes `payload` to native JSON data (versioned, sorted keys for determinism).
    static func data(from payload: DXFPayload) throws -> Data {
        let wrapped = VersionedPayload(version: currentVersion, payload: payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(wrapped)
        } catch {
            throw CodecError.encodeFailed(error)
        }
    }

    /// Whether `data` looks like native JSON (heuristic: starts with `{` and
    /// contains `"version"` or `"payload"` or `"entities"`). Used as a fast
    /// pre-check before attempting a full decode.
    static func isNativeJSON(_ data: Data) -> Bool {
        guard let prefix = data.first, prefix == UInt8(ascii: "{") else { return false }
        // Cheap string search before JSON decode — avoids trying to parse a DXF as JSON.
        if let str = String(data: data.prefix(4096), encoding: .utf8) {
            return str.contains("\"version\"") || str.contains("\"payload\"") || str.contains("\"entities\"")
        }
        return false
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

    /// Readable types: DXF (text), DWG (binary), AND native .lcad (JSON lossless).
    /// For each we accept the declared UTI plus the extension-derived type, so
    /// double-click / Open work regardless of which UTI Launch Services resolves
    /// the file to.
    static var readableContentTypes: [UTType] { dxfTypes + dwgTypes + lcadTypes }
    /// Writable types: DXF, DWG, and native .lcad. Native is lossless
    /// (preserves constraints/parameters/tables); DXF/DWG remain lossy but explicit.
    static var writableContentTypes: [UTType] { dxfTypes + dwgTypes + lcadTypes }

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

    /// The native .lcad content types: the exported UTI first, then the
    /// extension-derived type as a robust fallback.
    static let lcadTypes: [UTType] = {
        var types: [UTType] = [.librecadLCAD]
        if let byExt = UTType(filenameExtension: "lcad"), !types.contains(byExt) {
            types.append(byExt)
        }
        return types
    }()

    /// Whether `contentType` is the native .lcad type (UTI or extension).
    static func isLCAD(_ contentType: UTType) -> Bool {
        for t in lcadTypes where contentType == t || contentType.conforms(to: t) { return true }
        if contentType.preferredFilenameExtension?.lowercased() == "lcad" { return true }
        return false
    }

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
    /// constructs the document on a background queue). It parses the bytes into
    /// the `Sendable` payload via the off-main codecs and stores ONLY that —
    /// it does NOT build a `CADDrawing`/`CanvasModel` and does NOT call
    /// `MainActor.assumeIsolated`. (That off-main isolation assertion is the exact
    /// crash this whole design exists to avoid.)
    ///
    /// Wave 6: tries the native `.lcad` JSON codec FIRST (lossless, preserves
    /// constraints/params/tables), falling back to DXF/DWG. If the content type
    /// claims `.lcad`, native is required; otherwise native is probed via a
    /// heuristic and the data's JSON shape.
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw DXFDocumentCodec.CodecError.noFileContents
        }
        // Native .lcad is lossless (constraints/params/tables/layouts). Try it
        // FIRST (as the task requires), then fall back to the lossy DXF/DWG
        // path. Handles both correctly-typed .lcad and mis-typed/extension-less files.
        let contentType = configuration.contentType
        if Self.isLCAD(contentType) {
            // Content type claims LCAD — native must succeed; on failure surface
            // the native error (don't silently treat a corrupt .lcad as DXF).
            self.payload = try NativeDocumentCodec.payload(from: data)
            return
        }
        // For DXF/DWG (or unknown), probe native JSON heuristically first; if the
        // bytes look like JSON and decode, prefer the lossless path, otherwise DXF.
        if NativeDocumentCodec.isNativeJSON(data),
           let native = try? NativeDocumentCodec.payload(from: data) {
            self.payload = native
            return
        }
        let format = Self.format(for: contentType)
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

    /// Serializes a captured snapshot to a `FileWrapper`. RUNS OFF THE MAIN
    /// ACTOR. Operates ONLY on the `Sendable` snapshot via the off-main codecs;
    /// no `@MainActor` access. Wave 6: writes native `.lcad` JSON when the
    /// destination is `.lcad` (lossless), otherwise DXF/DWG (lossy but explicit).
    func fileWrapper(
        snapshot: DXFPayload,
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        if Self.isLCAD(configuration.contentType) {
            let data = try NativeDocumentCodec.data(from: snapshot)
            return FileWrapper(regularFileWithContents: data)
        }
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
