//
//  DXFWriter.swift
//  CADEngine
//
//  The DXF writer: the inverse of DXFReader. Takes a `CADDrawing` (entities +
//  layer table) and writes a .dxf file through the DxfBridge C ABI (the same
//  libdxfrw the reader bridges). Each `EntityRecord.kind` is mapped to an
//  `LCEntity` POD (the inverse of DXFReader's POD->kind mapping); the
//  `LayerTable` is mapped to `LCLayer` PODs. The POD arrays are built in Swift,
//  kept contiguous and valid across the single `lc_dxf_write` call, then freed
//  when the call returns.
//
//  Like the reader, all bridge access goes through `CADEngine.shared` (libdxfrw
//  is non-reentrant, so there is exactly one serialization point per process).
//
//  Supported kinds round-trip: line / point / circle / arc / ellipse / polyline /
//  spline / splinePoints / text / mtext / solid / hatch / dimension. `.spline`
//  maps to a control-point DXF SPLINE (degree, control points, knots, rational
//  weights, code-70 flags); `.splinePoints` maps to a degree-2 SPLINE whose
//  control polygon IS the quadratic-Bézier polygon (so it reads back as the same
//  geometry) plus DXF fit points. SPLINE needs R2000+; at R12 the C bridge drops
//  it (counted as skipped), like MTEXT/HATCH/DIMENSION. Any remaining unsupported
//  kind is skipped (counted, not fatal). Dimension writes the DIMENSION
//  entity definition (linear/aligned/radial/diameter/angular); the associated
//  anonymous block is NOT authored — a real CAD app regenerates it, and our own
//  resolve() regenerates the visual on read. MTEXT writes the preserved raw inline-coded string
//  (or, when the run tree was edited and no raw is stored, a reconstruction of
//  the MTEXT codes from the run tree). MTEXT only exists for R2000+; at R12 it is
//  dropped (counted as skipped) by the C bridge. HATCH writes its boundary loops as edge
//  boundaries (libdxfrw's polyline-boundary writer is an unimplemented stub): a zero-bulge
//  boundary vertex becomes a straight LINE edge, and a NON-ZERO-bulge vertex becomes a real
//  DRW_Arc edge (G6a) — so a bulged (arc) boundary loop is written as a TRUE DXF arc, not a
//  flattened chord, and other CAD tools read a real curved boundary. (On OUR re-read the C
//  bridge currently tessellates an ARC edge back into boundary sample points — the arc
//  GEOMETRY round-trips; exact-bulge read-back is a documented follow-up.) See G6a.
//
//  The per-attribute mapping (ACI color, linetype name, lineweight) is the
//  inverse of DXFReader.swift's, which is itself ported from LibreCAD's
//  rs_filterdxfrw.cpp write* callbacks.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft; (C) 2011-2015 José F. Soriano.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation
import DxfBridge

// MARK: - DXF output version

/// The DXF file-format version to write. Mirrors the bridge's `LCDxfVersion`;
/// the default is `.r2000` (AutoCAD 2000 / AC1015), the broadly-compatible
/// modern DXF LibreCAD itself defaults to on export.
public enum DXFVersion: Int32, Sendable {
    case r12 = 0
    case r14 = 1
    case r2000 = 2
    case r2004 = 3
    case r2007 = 4
    case r2018 = 5
}

// MARK: - Errors

/// Errors surfaced by the writer.
public enum CADWriteError: Error, Equatable, Sendable {
    /// The path was null/empty or otherwise rejected before writing.
    case invalidPath
    /// libdxfrw reported a write failure (bad path, I/O), or an exception
    /// escaped the export and was caught at the C boundary.
    case writeFailed
}

// MARK: - Engine writer entry point

extension CADEngine {

    /// The result of a write: the per-kind counts that were emitted vs skipped.
    /// Skipped == entity kinds the writer does not yet support (spline/text/...).
    public struct DXFWriteResult: Sendable {
        public var written: Int
        public var skipped: Int
    }

    /// Reads JUST the named DIMSTYLE table from a DXF/DWG file into a
    /// `DimStyleTable` (the bridge's `lc_dimstyles` flattened into `NamedDimStyle`s,
    /// plus the header's active-style name as `activeName`). The full geometry read
    /// path (`readEntities`) collapses only the ACTIVE style into the `$DIM*`
    /// graphic vars; this accessor preserves EVERY named style so a save→reopen
    /// round-trips the whole table. Runs on the shared engine actor (libdxfrw is
    /// non-reentrant). `format` selects the DXF vs DWG parser.
    ///
    /// - Throws: `CADEngineError.invalidPath` / `.readFailed`, like `readEntities`.
    public func readDimStyles(path: String, dwg: Bool = false) throws -> DimStyleTable {
        var handle: OpaquePointer?
        let reader = dwg ? lc_dwg_read : lc_dxf_read
        let status = path.withCString { reader($0, &handle) }
        switch status {
        case LC_OK: break
        case LC_ERR_INVALID_PATH: throw CADEngineError.invalidPath
        default: throw CADEngineError.readFailed
        }
        guard let list = handle else { return DimStyleTable() }
        defer { lc_entity_list_free(list) }

        func str(_ p: UnsafePointer<CChar>?) -> String? {
            guard let p else { return nil }
            let s = String(cString: p)
            return s.isEmpty ? nil : s
        }

        var table = DimStyleTable()
        let count = Int(lc_dimstyle_count(list))
        if count > 0, let base = lc_dimstyles(list) {
            let styles = UnsafeBufferPointer(start: base, count: count)
            for s in styles {
                let name = str(s.name) ?? "Standard"
                let resolved = ResolvedDimStyle(
                    textHeight: s.dimTxt,
                    arrowSize: s.dimAsz,
                    scale: s.dimScale > 0 ? s.dimScale : 1.0,
                    linearFormat: GraphicVariables.linearFormat(fromDXF: Int(s.dimLUnit)),
                    linearPrecision: Int(s.dimDec),
                    extensionOffset: s.dimExo,
                    extensionBeyond: s.dimExe,
                    textGap: s.dimGap
                )
                table.upsert(NamedDimStyle(name: name, style: resolved))
            }
        }
        if let hp = lc_header(list) { table.activeName = str(hp.pointee.dimStyle) }
        return table
    }

    /// Writes `entities` + `layers` to the DXF at `path` (overwriting it). Runs
    /// on the shared engine actor so the non-reentrant libdxfrw call is
    /// serialized with reads. All POD memory is built and kept valid for the
    /// duration of the C call inside this method.
    ///
    /// - Throws: `CADWriteError.invalidPath` for a null/empty path;
    ///   `CADWriteError.writeFailed` if libdxfrw cannot write the file.
    public func writeEntities(
        _ entities: [EntityRecord],
        layers: LayerTable,
        blocks: BlockTable = BlockTable(),
        blockMembers: [String: [EntityRecord]] = [:],
        graphicVariables: GraphicVariables = GraphicVariables(),
        dimStyles: DimStyleTable = DimStyleTable(),
        textStyles: TextStyleTable = TextStyleTable(),
        layouts: [Layout] = [],
        toPath path: String,
        version: DXFVersion = .r2000
    ) throws -> DXFWriteResult {
        try writeEntities(entities, layers: layers, blocks: blocks,
                          blockMembers: blockMembers,
                          graphicVariables: graphicVariables, dimStyles: dimStyles,
                          textStyles: textStyles,
                          layouts: layouts,
                          toPath: path, version: version, writer: lc_dxf_write)
    }

    /// Writes `entities` + `layers` to a DWG file at `path` (overwriting it). The
    /// DWG counterpart of `writeEntities(...toPath:)`: SAME inputs and POD-build
    /// path, but the bytes are encoded as a binary R2000 (AC1015) DWG via the
    /// bridge's `lc_dwg_write` (libdxfrw `dwgRW`). DWG write is R2000-only, so the
    /// `version` parameter is omitted here.
    ///
    /// Round-trip scope (the honest state of libdxfrw's DWG writer): top-level
    /// entities of every supported kind, layer "0" + the standard tables, and
    /// EMPTY block definitions + INSERT references are written. A block's MEMBER
    /// geometry is NOT written to DWG (the library's `defineBlock` makes empty
    /// blocks); for full block-content round-trip use DXF.
    ///
    /// - Throws: `CADWriteError.invalidPath` for a null/empty path;
    ///   `CADWriteError.writeFailed` if libdxfrw cannot write the file.
    public func writeEntities(
        _ entities: [EntityRecord],
        layers: LayerTable,
        blocks: BlockTable = BlockTable(),
        blockMembers: [String: [EntityRecord]] = [:],
        graphicVariables: GraphicVariables = GraphicVariables(),
        dimStyles: DimStyleTable = DimStyleTable(),
        textStyles: TextStyleTable = TextStyleTable(),
        layouts: [Layout] = [],
        toDWGPath path: String
    ) throws -> DXFWriteResult {
        try writeEntities(entities, layers: layers, blocks: blocks,
                          blockMembers: blockMembers,
                          graphicVariables: graphicVariables, dimStyles: dimStyles,
                          textStyles: textStyles,
                          layouts: layouts,
                          toPath: path, version: .r2000, writer: lc_dwg_write)
    }

    /// Shared write core for the DXF and DWG entry points. Builds the flat POD
    /// model once and hands it to whichever bridge writer (`lc_dxf_write` /
    /// `lc_dwg_write`) the caller passed — both take the identical POD signature.
    private func writeEntities(
        _ entities: [EntityRecord],
        layers: LayerTable,
        blocks: BlockTable,
        blockMembers: [String: [EntityRecord]],
        graphicVariables: GraphicVariables,
        dimStyles: DimStyleTable,
        textStyles: TextStyleTable,
        layouts: [Layout],
        toPath path: String,
        version: DXFVersion,
        writer: (
            UnsafePointer<CChar>?,
            UnsafePointer<LCEntity>?, Int32,
            UnsafePointer<LCLayer>?, Int32,
            UnsafePointer<LCBlock>?, Int32,
            UnsafePointer<LCEntity>?, Int32,
            Int32,
            UnsafeMutablePointer<Int32>?,
            UnsafePointer<LCHeader>?,
            UnsafePointer<LCDimStyle>?, Int32,
            UnsafePointer<LCTextStyle>?, Int32,
            UnsafePointer<LCViewport>?, Int32,
            UnsafePointer<LCHeaderVar>?, Int32
        ) -> LCStatus
    ) throws -> DXFWriteResult {
        guard !path.isEmpty else { throw CADWriteError.invalidPath }

        // Build the flat POD model. `Builder` owns every C string / vertex array
        // the PODs borrow; it must outlive the write call below.
        let builder = PODBuilder()
        // Each entity maps to one POD; a `.leader` carrying an attached annotation
        // ALSO emits the annotation as a SECOND, top-level DXF entity (TEXT/MTEXT)
        // so other CAD tools can SEE the leader's text — see `leaderAnnotationPOD`
        // for the libdxfrw code-340 hard-reference limit. The annotation POD
        // inherits the leader's layer/pen.
        var entityPODs: [LCEntity] = []
        entityPODs.reserveCapacity(entities.count)
        for record in entities {
            entityPODs.append(builder.makeEntity(record))
            if case .leader(let d) = record.kind,
               let annotationPOD = builder.leaderAnnotationPOD(d, from: record) {
                entityPODs.append(annotationPOD)
            }
            // A `.multileader` with an attached annotation ALSO emits the annotation as
            // a SECOND top-level TEXT/MTEXT (same rationale as `.leader`): stock
            // libdxfrw's writeMultiLeader does not serialize the CONTEXT_DATA text, so
            // this is how other CAD tools SEE the multileader's text.
            if case .multileader(let d) = record.kind,
               let annotationPOD = builder.multiLeaderAnnotationPOD(d, from: record) {
                entityPODs.append(annotationPOD)
            }
        }
        let layerPODs = layers.layers.map { builder.makeLayer($0) }
        // The HEADER var POD (units + $DIM* incl. ext-line offsets) + the DIMSTYLE
        // table PODs, so a Save preserves units / dim styles / ext offsets.
        let headerPOD = builder.makeHeader(graphicVariables, dimStyles: dimStyles)
        // R4b: the GENERIC document-settings header vars (the ones the fixed header
        // POD doesn't carry — $GRIDMODE/$GRIDUNIT/$PDMODE/$PDSIZE/$ANGBASE/$ANGDIR/
        // $PINSBASE). Their `name` C-strings are interned in `builder`, so this must
        // be built while `builder` is alive (it is, through the write call below).
        let headerVarPODs = builder.makeHeaderVars(graphicVariables)
        let dimStylePODs = dimStyles.styles.map { builder.makeDimStyle($0) }
        // The STYLE (text-style) table PODs so named text styles + their fonts
        // round-trip (the text-style data-loss fix). BYTE-IDENTITY gate: a default /
        // untouched table (the overwhelming common case — `CADDrawing` starts with a
        // single default "Standard") emits NOTHING, so the bridge falls back to
        // libdxfrw's plain default "Standard" and the output is byte-identical to
        // before. Any customized / extra style makes the table differ from the
        // default, so the WHOLE table is emitted (sorted by id → Standard first, then
        // ascending — deterministic, since `styles` is an unordered dictionary).
        let textStylePODs: [LCTextStyle] =
            (textStyles == TextStyleTable())
            ? []
            : textStyles.styles.values
                .sorted { $0.id.rawValue < $1.id.rawValue }
                .map { builder.makeTextStyle($0) }
        // Paper-space P3: flatten every layout's viewports into LCViewport PODs (the
        // bridge emits them as DXF VIEWPORT entities). Empty unless the caller passed
        // layouts that carry viewports, so all other write paths are byte-identical.
        var viewportPODs: [LCViewport] = []
        for layout in layouts {
            for vp in layout.viewports {
                viewportPODs.append(builder.makeViewport(vp))
            }
        }

        // Build the block definitions + a flat array of their member PODs. Each
        // block windows into `blockEntityPODs`; only non-anonymous user blocks are
        // emitted (anonymous `*`-blocks aren't authored — they regenerate). The
        // member lookup is supplied by the caller (a `name → [EntityRecord]` map);
        // missing members yield an empty (still valid) block.
        var blockPODs: [LCBlock] = []
        var blockEntityPODs: [LCEntity] = []
        for block in blocks.blocks where !block.name.hasPrefix("*") {
            let members = blockMembers[block.name] ?? []
            let offset = blockEntityPODs.count
            for m in members { blockEntityPODs.append(builder.makeEntity(m)) }
            // `memberOrder` is the EXACT written member-id order (drives the dynamic-
            // definition index remap so member refs survive the reader's fresh ids).
            blockPODs.append(builder.makeBlock(
                block, memberOffset: offset, memberCount: members.count,
                memberOrder: members.map { $0.id }))
        }

        var skipped: Int32 = 0
        var headerPODVar = headerPOD
        let status = path.withCString { cpath -> LCStatus in
            entityPODs.withUnsafeBufferPointer { ents -> LCStatus in
                layerPODs.withUnsafeBufferPointer { lays -> LCStatus in
                    blockPODs.withUnsafeBufferPointer { blks -> LCStatus in
                        blockEntityPODs.withUnsafeBufferPointer { blkEnts -> LCStatus in
                            dimStylePODs.withUnsafeBufferPointer { dsty -> LCStatus in
                                textStylePODs.withUnsafeBufferPointer { tsty -> LCStatus in
                                    viewportPODs.withUnsafeBufferPointer { vps -> LCStatus in
                                        headerVarPODs.withUnsafeBufferPointer { hvars -> LCStatus in
                                            withUnsafePointer(to: &headerPODVar) { hdr -> LCStatus in
                                                writer(
                                                    cpath,
                                                    ents.baseAddress, Int32(ents.count),
                                                    lays.baseAddress, Int32(lays.count),
                                                    blks.baseAddress, Int32(blks.count),
                                                    blkEnts.baseAddress, Int32(blkEnts.count),
                                                    version.rawValue,
                                                    &skipped,
                                                    hdr,
                                                    dsty.baseAddress, Int32(dsty.count),
                                                    tsty.baseAddress, Int32(tsty.count),
                                                    vps.baseAddress, Int32(vps.count),
                                                    hvars.baseAddress, Int32(hvars.count)
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Keep the backing pools alive until the call has returned.
        withExtendedLifetime(builder) {}

        switch status {
        case LC_OK:
            return DXFWriteResult(written: entityPODs.count - Int(skipped),
                                  skipped: Int(skipped))
        case LC_ERR_INVALID_PATH:
            throw CADWriteError.invalidPath
        default:
            throw CADWriteError.writeFailed
        }
    }
}

// MARK: - High-level drawing save (main actor)

/// Saves a `CADDrawing` to a .dxf file. The mirror of `loadDrawing(dxfPath:)`:
/// snapshots the drawing's value records on the main actor, then hands them to
/// the shared `CADEngine` actor to write. Returns the per-kind written/skipped
/// counts (skipped == kinds not yet supported by the writer).
@MainActor
@discardableResult
public func writeDrawing(
    _ drawing: CADDrawing,
    toPath path: String,
    version: DXFVersion = .r2000
) async throws -> CADEngine.DXFWriteResult {
    // Snapshot the value-type state on the main actor (cheap copies), then write
    // off-main through the single engine serialization point.
    let entities = drawing.entities
    let layers = drawing.layers
    let blocks = drawing.blocks
    // Resolve each block's member ids to records so the writer can author the block
    // definitions (the same name → [EntityRecord] snapshot the resolve context uses).
    let blockMembers = drawing.blockMembersSnapshot()
    // The header vars + named DIMSTYLE table so units / dim styles / ext-line
    // offsets are preserved on save (symmetric to the read path).
    let graphicVariables = drawing.graphicVariables
    let dimStyles = drawing.dimStyles
    // The STYLE (text-style) table so named text styles + their fonts are preserved
    // on save (the text-style data-loss fix; symmetric to the read path).
    let textStyles = drawing.textStyles
    // Paper-space P3: the layout table (with each layout's viewports) so a Save
    // persists viewports as DXF VIEWPORT entities.
    let layouts = drawing.layouts
    return try await CADEngine.shared.writeEntities(
        entities, layers: layers, blocks: blocks, blockMembers: blockMembers,
        graphicVariables: graphicVariables, dimStyles: dimStyles,
        textStyles: textStyles,
        layouts: layouts,
        toPath: path, version: version
    )
}

// MARK: - POD builder (owns the C-string and vertex-array backing storage)

/// Builds `LCEntity` / `LCLayer` PODs from the Swift value model and owns the
/// backing storage their borrowed pointers reference (C strings via
/// null-terminated UTF-8 byte buffers; vertex arrays as contiguous `LCVertex`
/// blocks). A single instance is held alive across one `lc_dxf_write` call; the
/// PODs it returns are only valid while it lives.
///
/// `final class` (reference type) so the pointers it vends stay stable as PODs
/// are copied into the array passed to C.
private final class PODBuilder {
    /// Each interned C string is a heap UTF-8 byte buffer we keep until the
    /// builder dies, returning a stable `UnsafePointer<CChar>` into it.
    private var strings: [UnsafeMutablePointer<CChar>] = []
    /// Each interned vertex array is a heap `LCVertex` buffer, same lifetime.
    private var vertexBuffers: [UnsafeMutableBufferPointer<LCVertex>] = []
    /// Each interned hatch-loop array is a heap `LCLoop` buffer, same lifetime.
    private var loopBuffers: [UnsafeMutableBufferPointer<LCLoop>] = []
    /// Each interned double array (spline knots / weights) is a heap `Double`
    /// buffer, same lifetime.
    private var doubleBuffers: [UnsafeMutableBufferPointer<Double>] = []
    /// Each interned Int32 array (MLINE per-element colors) is a heap `Int32`
    /// buffer, same lifetime.
    private var int32Buffers: [UnsafeMutableBufferPointer<Int32>] = []
    /// Each interned attribute array (ATTRIB / ATTDEF) is a heap `LCAttrib`
    /// buffer, same lifetime. The `tag`/`text`/`prompt` C strings each `LCAttrib`
    /// borrows are interned into `strings` (same builder lifetime).
    private var attribBuffers: [UnsafeMutableBufferPointer<LCAttrib>] = []

    deinit {
        for s in strings { s.deallocate() }
        for v in vertexBuffers { v.deallocate() }
        for l in loopBuffers { l.deallocate() }
        for d in doubleBuffers { d.deallocate() }
        for i in int32Buffers { i.deallocate() }
        for a in attribBuffers { a.deallocate() }
    }

    /// Interns a Swift string as a stable, null-terminated C string.
    private func intern(_ s: String) -> UnsafePointer<CChar> {
        let utf8 = Array(s.utf8)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
        for (i, byte) in utf8.enumerated() { buf[i] = CChar(bitPattern: byte) }
        buf[utf8.count] = 0
        strings.append(buf)
        return UnsafePointer(buf)
    }

    /// Interns a vertex array as a stable contiguous `LCVertex` block.
    /// Returns `(nil, 0)` for an empty list.
    private func internVertices(_ verts: [PolylineVertex]) -> (UnsafePointer<LCVertex>?, Int32) {
        guard !verts.isEmpty else { return (nil, 0) }
        let buf = UnsafeMutableBufferPointer<LCVertex>.allocate(capacity: verts.count)
        for (i, v) in verts.enumerated() {
            buf[i] = LCVertex(x: v.point.x, y: v.point.y, bulge: v.bulge)
        }
        vertexBuffers.append(buf)
        return (UnsafePointer(buf.baseAddress!), Int32(verts.count))
    }

    /// Interns a `Vector` point list (spline control / fit points; bulge unused)
    /// as a stable contiguous `LCVertex` block. Returns `(nil, 0)` for empty.
    private func internPoints(_ points: [Vector]) -> (UnsafePointer<LCVertex>?, Int32) {
        guard !points.isEmpty else { return (nil, 0) }
        let buf = UnsafeMutableBufferPointer<LCVertex>.allocate(capacity: points.count)
        for (i, p) in points.enumerated() {
            buf[i] = LCVertex(x: p.x, y: p.y, bulge: 0.0)
        }
        vertexBuffers.append(buf)
        return (UnsafePointer(buf.baseAddress!), Int32(points.count))
    }

    /// Interns block ATTRIB values as a stable contiguous `LCAttrib` block. The
    /// rotation is in radians (the C side converts to DXF degrees). `prompt` is "".
    /// Returns `(nil, 0)` for an empty list.
    func internAttribValues(_ values: [BlockAttributeValue]) -> (UnsafePointer<LCAttrib>?, Int32) {
        guard !values.isEmpty else { return (nil, 0) }
        let buf = UnsafeMutableBufferPointer<LCAttrib>.allocate(capacity: values.count)
        for (i, v) in values.enumerated() {
            buf[i] = LCAttrib(
                tag: intern(v.tag),
                text: intern(v.text),
                prompt: intern(""),
                x: v.position.x, y: v.position.y,
                height: v.height,
                rotation: v.rotation,
                flags: Int32(v.flags))
        }
        attribBuffers.append(buf)
        return (UnsafePointer(buf.baseAddress!), Int32(values.count))
    }

    /// Interns block ATTDEF templates as a stable contiguous `LCAttrib` block.
    /// `text` carries the DEFAULT value; `prompt` the prompt. Rotation in radians.
    /// Returns `(nil, 0)` for an empty list.
    func internAttribDefs(_ defs: [BlockAttributeDef]) -> (UnsafePointer<LCAttrib>?, Int32) {
        guard !defs.isEmpty else { return (nil, 0) }
        let buf = UnsafeMutableBufferPointer<LCAttrib>.allocate(capacity: defs.count)
        for (i, d) in defs.enumerated() {
            buf[i] = LCAttrib(
                tag: intern(d.tag),
                text: intern(d.defaultText),
                prompt: intern(d.prompt),
                x: d.position.x, y: d.position.y,
                height: d.height,
                rotation: d.rotation,
                flags: Int32(d.flags))
        }
        attribBuffers.append(buf)
        return (UnsafePointer(buf.baseAddress!), Int32(defs.count))
    }

    /// Interns a `Double` list (spline knots / weights) as a stable contiguous
    /// block. Returns `(nil, 0)` for an empty list.
    private func internDoubles(_ values: [Double]) -> (UnsafePointer<Double>?, Int32) {
        guard !values.isEmpty else { return (nil, 0) }
        let buf = UnsafeMutableBufferPointer<Double>.allocate(capacity: values.count)
        _ = buf.initialize(from: values)
        doubleBuffers.append(buf)
        return (UnsafePointer(buf.baseAddress!), Int32(values.count))
    }

    /// Interns an `Int32` list (MLINE per-element colors) as a stable contiguous
    /// block. Returns `(nil, 0)` for an empty list.
    private func internInt32s(_ values: [Int32]) -> (UnsafePointer<Int32>?, Int32) {
        guard !values.isEmpty else { return (nil, 0) }
        let buf = UnsafeMutableBufferPointer<Int32>.allocate(capacity: values.count)
        _ = buf.initialize(from: values)
        int32Buffers.append(buf)
        return (UnsafePointer(buf.baseAddress!), Int32(values.count))
    }

    /// Interns a hatch's boundary loops as a single flat `LCVertex` array plus a
    /// parallel `LCLoop` window array (offset,count into the vertices) — the
    /// exact layout the reader hands back. Loops with fewer than 2 vertices are
    /// dropped (they can't form an edge boundary). Returns `(nil,0,nil,0)` if no
    /// loop survives.
    private func internHatchLoops(
        _ loops: [[PolylineVertex]]
    ) -> (verts: UnsafePointer<LCVertex>?, vertCount: Int32,
          loops: UnsafePointer<LCLoop>?, loopCount: Int32) {
        var flatVerts: [LCVertex] = []
        var windows: [LCLoop] = []
        for ring in loops {
            guard ring.count >= 2 else { continue }
            let start = Int32(flatVerts.count)
            for v in ring {
                flatVerts.append(LCVertex(x: v.point.x, y: v.point.y, bulge: v.bulge))
            }
            windows.append(LCLoop(offset: start, count: Int32(ring.count)))
        }
        guard !flatVerts.isEmpty, !windows.isEmpty else { return (nil, 0, nil, 0) }

        let vbuf = UnsafeMutableBufferPointer<LCVertex>.allocate(capacity: flatVerts.count)
        _ = vbuf.initialize(from: flatVerts)
        vertexBuffers.append(vbuf)

        let lbuf = UnsafeMutableBufferPointer<LCLoop>.allocate(capacity: windows.count)
        _ = lbuf.initialize(from: windows)
        loopBuffers.append(lbuf)

        return (UnsafePointer(vbuf.baseAddress!), Int32(flatVerts.count),
                UnsafePointer(lbuf.baseAddress!), Int32(windows.count))
    }

    // MARK: Entity mapping (inverse of DXFReader.mapKind)

    /// Maps one `EntityRecord` to an `LCEntity` POD. Every modeled kind maps to a
    /// concrete `LCEntityKind`; only a kind the writer genuinely cannot represent
    /// would fall through to `LC_ENT_UNSUPPORTED` (the C side counts and skips it).
    func makeEntity(_ record: EntityRecord) -> LCEntity {
        var e = LCEntity()
        e.color = 256              // ByLayer default; overwritten by applyPen
        e.color24 = -1
        e.lineWeightMM100 = -1     // ByLayer default
        e.ratio = 1.0
        e.layer = intern(record.layer.name.isEmpty ? "0" : record.layer.name)
        // Paper-space P1: tag the POD's space so the bridge sets DRW_Entity::space →
        // DXF code 67 == 1 for a paper-space entity. libdxfrw writes a single built-
        // in `*Paper_Space` block, so paper-space entities + a single layout round-
        // trip on stock libdxfrw. The layout name is carried for symmetry with the
        // reader (libdxfrw has no multi-block-per-layout write path, so it does not
        // affect the emitted bytes today — documented follow-up). Model entities
        // (`.model`, the default) emit no code 67, leaving them byte-identical.
        e.spaceFlag = (record.space == .paper) ? 1 : 0
        if record.space == .paper, let name = record.layoutName, !name.isEmpty {
            e.layoutName = intern(name)
        }
        applyPen(record.pen, to: &e)

        switch record.kind {
        case .line(let d):
            e.kind = Int32(LC_ENT_LINE.rawValue)
            e.p1x = d.start.x; e.p1y = d.start.y; e.p1z = d.start.z
            e.p2x = d.end.x;   e.p2y = d.end.y;   e.p2z = d.end.z

        case .point(let d):
            e.kind = Int32(LC_ENT_POINT.rawValue)
            e.p1x = d.position.x; e.p1y = d.position.y; e.p1z = d.position.z

        case .circle(let d):
            e.kind = Int32(LC_ENT_CIRCLE.rawValue)
            e.cx = d.center.x; e.cy = d.center.y; e.cz = d.center.z
            e.radius = d.radius

        case .arc(let d):
            e.kind = Int32(LC_ENT_ARC.rawValue)
            e.cx = d.center.x; e.cy = d.center.y; e.cz = d.center.z
            e.radius = d.radius
            // DXF stores arcs CCW; mirror rs_filterdxfrw.cpp::writeArc, which
            // swaps start/end for a reversed (CW) arc.
            if d.reversed {
                e.startAngle = d.endAngle
                e.endAngle = d.startAngle
            } else {
                e.startAngle = d.startAngle
                e.endAngle = d.endAngle
            }

        case .ellipse(let d):
            e.kind = Int32(LC_ENT_ELLIPSE.rawValue)
            e.cx = d.center.x; e.cy = d.center.y; e.cz = d.center.z
            // major-axis endpoint, relative to center (DXF code 11/21/31).
            e.p2x = d.majorP.x; e.p2y = d.majorP.y; e.p2z = d.majorP.z
            e.ratio = d.ratio
            if d.reversed {
                e.startAngle = d.endAngle
                e.endAngle = d.startAngle
            } else {
                e.startAngle = d.startAngle
                e.endAngle = d.endAngle
            }

        case .polyline(let d):
            e.kind = Int32(LC_ENT_LWPOLYLINE.rawValue)
            e.closed = d.closed ? 1 : 0
            let (ptr, count) = internVertices(d.vertices)
            e.vertices = ptr
            e.vertexCount = count

        case .spline(let d):
            // Control-point (rational) B-spline / NURBS -> DXF SPLINE. The degree,
            // control polygon, knots and rational weights map straight onto the
            // POD's spline fields; `closed` carries via the closed flag. The C side
            // sets nknots/ncontrol from these and writes DRW_Spline. Mirrors
            // rs_filterdxfrw.cpp::writeSpline.
            e.kind = Int32(LC_ENT_SPLINE.rawValue)
            e.degree = Int32(d.degree)
            e.closed = d.closed ? 1 : 0
            // code 70: 1 closed, 2 periodic, 4 rational, 8 planar, 16 linear.
            // Prefer the RAW flags read from the source file (a faithful re-write
            // that preserves the periodic / linear bits); only synthesize a default
            // (planar always; closed ⇒ +closed|periodic; per-control weights ⇒
            // +rational) when the spline carries no raw flags (engine-authored).
            let flags: Int32
            if d.splineFlags != 0 {
                flags = Int32(d.splineFlags)
            } else {
                var f: Int32 = 0b1000
                if d.closed { f |= 0b0011 }
                if d.weights.count == d.controlPoints.count, !d.weights.isEmpty {
                    f |= 0b0100
                }
                flags = f
            }
            e.splineFlags = flags
            let (cptr, ccount) = internPoints(d.controlPoints)
            e.vertices = cptr
            e.vertexCount = ccount
            let (kptr, kcount) = internDoubles(d.knots)
            e.knots = kptr
            e.knotCount = kcount
            // Only carry weights when they cover every control point (a rational
            // spline); a partial array would mis-weight the curve (mirrors the
            // reader's guard in mapSpline).
            if d.weights.count == d.controlPoints.count {
                let (wptr, wcount) = internDoubles(d.weights)
                e.weights = wptr
                e.weightCount = wcount
            }

        case .splinePoints(let d):
            // Interpolation (fit-point) spline drawn as quadratic Béziers ->
            // DXF SPLINE. We store the quadratic-Bézier CONTROL polygon (degree 2)
            // as the spline's control points so the geometry reads back exactly as
            // a degree-2 control-point `.spline`. The on-curve fit points (== the
            // control points for our model, which keeps both in lockstep) are also
            // emitted as DXF fit points (codes 11/21) so other CAD apps see a
            // fit-point spline. Mirrors rs_filterdxfrw.cpp::writeSplinePoints.
            e.kind = Int32(LC_ENT_SPLINE.rawValue)
            e.degree = 2
            e.closed = d.closed ? 1 : 0
            var flags: Int32 = 0b1000           // planar
            if d.closed { flags |= 0b0011 }     // + closed | periodic
            e.splineFlags = flags
            let (cptr, ccount) = internPoints(d.controlPoints)
            e.vertices = cptr
            e.vertexCount = ccount
            // Knots: leave empty — the reader/NURBS evaluator generates a clamped
            // uniform vector from degree (2) + control-point count.
            let (fptr, fcount) = internPoints(d.controlPoints)
            e.fitPoints = fptr
            e.fitPointCount = fcount

        case .dimension(let d):
            // Emitted as a DXF DIMENSION (the C side builds the matching DRW_Dim*).
            // The `dimType` discriminator + the per-variant defining points map onto
            // the POD's `dim*` fields; the shared base (text override, style,
            // attachment, line-spacing, text rotation) round-trips. The DIMENSION's
            // rendered geometry lives in an anonymous block in DXF; we do NOT author
            // it (the C side writes the entity definition with an empty block name —
            // a real CAD app regenerates the block, and our resolve() regenerates
            // the visual). The measured value (code 42) is NOT written — it is
            // recomputed on read. DIMENSION needs R2000+; at R12 the C side drops it
            // (counted as skipped), matching MTEXT/HATCH.
            applyDimension(d, to: &e)

        case .text(let d):
            // Emitted as a single-line DXF TEXT (the C side writes DRW_Text). The
            // POD carries one insertion point + the 72/73 alignment codes, which
            // round-trip cleanly; MTEXT-on-read is written back as TEXT.
            e.kind = Int32(LC_ENT_TEXT.rawValue)
            e.p1x = d.position.x; e.p1y = d.position.y; e.p1z = d.position.z
            e.height = d.height
            e.startAngle = d.rotation   // radians; the C side converts to DXF degrees
            e.hAlign = Int32(d.hAlign.rawValue)
            e.vAlign = Int32(d.vAlign.rawValue)
            e.textValue = intern(d.text)
            if let style = d.styleName, !style.isEmpty { e.styleName = intern(style) }

        case .mtext(let d):
            // Emitted as a DXF MTEXT (the C side writes DRW_MText). We prefer the
            // PRESERVED raw inline-coded string (`rawCode`, kept verbatim by the
            // reader) for a lossless round-trip of every format code; if it was
            // never stored (a programmatically-built / edited entity) we
            // reconstruct the MTEXT coded string from the run tree (the inverse of
            // MTextParser). Insertion point, height, reference/wrap width,
            // attachment, rotation (radians; C converts to DXF degrees), the
            // line-spacing style/factor and the STYLE name map straight onto the
            // POD's MTEXT fields.
            e.kind = Int32(LC_ENT_MTEXT.rawValue)
            e.p1x = d.position.x; e.p1y = d.position.y; e.p1z = d.position.z
            e.height = d.height
            e.startAngle = d.rotation   // radians; the C side converts to DXF degrees
            e.mtextRectWidth = d.rectWidth
            e.mtextAttachment = Int32(d.attachment.rawValue)
            e.mtextLineSpacingStyle = Int32(d.lineSpacingStyle.rawValue)
            e.mtextLineSpacingFactor = d.lineSpacingFactor
            let coded = d.rawCode ?? MTextEncoder.encode(d.paragraphs)
            e.textValue = intern(coded)
            if let style = d.styleName, !style.isEmpty { e.styleName = intern(style) }

        case .solid(let d):
            // Emitted as a DXF SOLID. Corners are stored in ring order; the C side
            // re-applies DXF's bow-tie 3rd/4th swap. A degenerate (<3 corner)
            // solid is emitted with its corners and skipped on the C side.
            e.kind = Int32(LC_ENT_SOLID.rawValue)
            let solidVerts = d.corners.map { PolylineVertex(point: $0) }
            let (ptr, count) = internVertices(solidVerts)
            e.vertices = ptr
            e.vertexCount = count

        case .hatch(let d):
            // Emitted as a DXF HATCH with edge (line) boundary loops. All loops'
            // vertices are flattened into one contiguous array; per-loop windows
            // go into `loops` (the same layout the reader hands back).
            e.kind = Int32(LC_ENT_HATCH.rawValue)
            e.solidFill = d.solidFill ? 1 : 0
            e.textValue = intern(d.patternName ?? (d.solidFill ? "SOLID" : "ANSI31"))
            // Pattern scale (code 41) + angle (code 52, radians; the C side converts
            // to DXF degrees). Only meaningful for a pattern hatch, but harmless to
            // carry for a solid one (libdxfrw emits 41/52 only when !solid).
            e.hatchScale = d.patternScale > 0 ? d.patternScale : 1
            e.hatchAngle = d.patternAngle
            // Gradient fill (DRW_Hatch gradient block; codes 450..470 + 463/421 per
            // stop). The C side emits the gradient when `hatchGradient != 0`. Stop
            // colors cross as packed 0x00RRGGBB (the same form as `color24`); up to
            // two stops are carried (1 == single-color, 2 == two-color). The angle
            // (code 460) is RADIANS — passed verbatim (the C side does NOT convert).
            if let g = d.gradient, !g.colors.isEmpty {
                e.hatchGradient = 1
                e.hatchGradKind = (g.kind == .radial) ? 1 : 0
                e.hatchGradAngle = g.angle
                e.hatchGradStopCount = Int32(min(2, g.colors.count))
                e.hatchGradColor0 = packedRGB(g.colors[0])
                e.hatchGradColor1 = g.colors.count > 1 ? packedRGB(g.colors[1]) : -1
            }
            let (vptr, vcount, lptr, lcount) = internHatchLoops(d.loops)
            e.vertices = vptr
            e.vertexCount = vcount
            e.loops = lptr
            e.loopCount = lcount

        case .insert(let d):
            // Emitted as a DXF INSERT/MINSERT (the C side writes DRW_Insert). The
            // block name (textValue), insertion point (p1), per-axis scale, rotation
            // (radians; C converts to DXF degrees) and the MINSERT array map straight
            // onto the POD. The referenced block's DEFINITION is written separately
            // in the BLOCKS section (see writeEntities' block POD build) so the
            // INSERT resolves to real geometry on re-read.
            e.kind = Int32(LC_ENT_INSERT.rawValue)
            e.p1x = d.insertionPoint.x; e.p1y = d.insertionPoint.y; e.p1z = d.insertionPoint.z
            e.insScaleX = d.scale.x
            e.insScaleY = d.scale.y
            e.insScaleZ = d.scale.z == 0 ? 1 : d.scale.z
            e.startAngle = d.rotation   // radians; the C side converts to DXF degrees
            e.insRows = Int32(d.rows)
            e.insCols = Int32(d.cols)
            e.insRowSpacing = d.rowSpacing
            e.insColSpacing = d.colSpacing
            e.textValue = intern(d.blockName)
            // Block ATTRIB values → flat LCAttrib array (the C side emits code 66 +
            // ATTRIB sub-entities + SEQEND after the INSERT). Empty ⇒ (nil, 0).
            let (aptr, acount) = internAttribValues(d.attributes)
            e.attribs = aptr
            e.attribCount = acount
            // DYNAMIC BLOCK: embed this insert's per-INSTANCE state as a compact JSON
            // string. The C bridge persists it as a RESERVED-tag ATTRIB on the INSERT
            // (the block ATTRIB path round-trips through the unmodified libdxfrw; the
            // bridge filters the reserved tag back out on read). NULL for a plain
            // insert (the common case). The block DEFINITION rides its own reserved
            // ATTDEF — see `makeBlock`.
            if let instanceJSON = d.dynamic?.encodeJSON() {
                e.dynamicJSON = intern(instanceJSON)
            }

        case .xline(let d):
            // Emitted as a DXF XLINE (the C side writes DRW_Xline). Base point
            // (code 10) -> p1; direction vector (code 11) -> p2. DXF XLINE/RAY
            // store the direction as a vector, not a second point, so it maps
            // straight from XLineData.direction.
            e.kind = Int32(LC_ENT_XLINE.rawValue)
            e.p1x = d.base.x;      e.p1y = d.base.y;      e.p1z = d.base.z
            e.p2x = d.direction.x; e.p2y = d.direction.y; e.p2z = d.direction.z

        case .ray(let d):
            // Emitted as a DXF RAY (the C side writes DRW_Ray). Start (base) point
            // (code 10) -> p1; direction (code 11) -> p2.
            e.kind = Int32(LC_ENT_RAY.rawValue)
            e.p1x = d.base.x;      e.p1y = d.base.y;      e.p1z = d.base.z
            e.p2x = d.direction.x; e.p2y = d.direction.y; e.p2z = d.direction.z

        case .leader(let d):
            // Emitted as a DXF LEADER (the C side writes DRW_Leader). The path
            // vertices map to the flat vertex array (bulge unused); the arrow flag
            // and arrow size (carried as the annotation text height, code 40) and
            // the dim-style name round-trip. The attached annotation is NOT carried
            // inside the LEADER POD: DXF stores a leader's annotation as a SEPARATE
            // entity hard-referenced by code 340, and libdxfrw's writeLeader cannot
            // emit 340 (see `leaderAnnotationPOD`). Instead the writer emits the
            // annotation as an INDEPENDENT top-level TEXT/MTEXT (so other tools see
            // the text) — that expansion happens in `writeEntities`, not here. LEADER
            // needs R2000+; at R12 / on DWG (no DWG leader writer) the C side drops
            // it (counted skipped), matching MTEXT/DIMENSION.
            e.kind = Int32(LC_ENT_LEADER.rawValue)
            e.leaderHasArrow = d.hasArrow ? 1 : 0
            // Carry the arrow size as the LEADER text-height (code 40) so it
            // round-trips through DRW_Leader (which has no separate arrow-size code).
            e.height = d.arrowSize
            e.leaderArrowSize = d.arrowSize
            if let style = d.styleName, !style.isEmpty { e.styleName = intern(style) }
            let leaderVerts = d.vertices.map { PolylineVertex(point: $0) }
            let (ptr, count) = internVertices(leaderVerts)
            e.vertices = ptr
            e.vertexCount = count

        case .multileader(let d):
            // Emitted as a DXF MULTILEADER (the C side writes DRW_MLeader). The leg
            // vertices map to the flat vertex array (bulge unused); the landing
            // distance (code 41), dogleg flag (code 291) and arrow size (code 42)
            // round-trip through the entity-level scalars; the annotation text rides
            // `textValue` (the CONTEXT_DATA `textLabel`), the text height `height`.
            //
            // FIDELITY LIMITATION (pinned by MultiLeaderDXFRoundTripTests): stock
            // libdxfrw's `writeMultiLeader` is GEOMETRY-LIGHT — it emits only the
            // entity-level scalars, NOT the CONTEXT_DATA{} block, and its DXF reader
            // parses only those scalars. So across a DXF write→reread the leg
            // `vertices`, the annotation text, and `styleName` are DROPPED (they
            // survive only via the engine's own Codable document path); the landing
            // distance, dogleg flag and arrow size DO survive. We do NOT patch the
            // vendored libdxfrw; full CONTEXT_DATA interop is a deferred enhancement.
            // Like LEADER, the writer ALSO emits the annotation as an INDEPENDENT
            // top-level TEXT/MTEXT (in `writeEntities`) so other CAD tools SEE the
            // text. MULTILEADER needs R2000+; at R12 / on DWG it is dropped (counted
            // skipped), matching LEADER/MTEXT/DIMENSION.
            e.kind = Int32(LC_ENT_MLEADER.rawValue)
            e.mleaderHasArrow = d.hasArrow ? 1 : 0
            e.mleaderArrowSize = d.arrowSize
            e.mleaderLandingDistance = d.landingDistance
            e.mleaderDoglegEnabled = d.doglegEnabled ? 1 : 0
            // Carry the annotation text + height for the forward-compat CONTEXT_DATA.
            if let text = multiLeaderAnnotationText(d) { e.textValue = intern(text) }
            e.height = multiLeaderAnnotationHeight(d) ?? d.arrowSize
            if let style = d.styleName, !style.isEmpty { e.styleName = intern(style) }
            let mleaderVerts = d.vertices.map { PolylineVertex(point: $0) }
            let (mptr, mcount) = internVertices(mleaderVerts)
            e.vertices = mptr
            e.vertexCount = mcount

        case .image(let d):
            // Emitted as a DXF IMAGE + its IMAGEDEF (the C side calls
            // `dxfRW::writeImage`, which creates the IMAGEDEF and the reactor wiring
            // for us). The insertion (lower-left, p1), the per-pixel u/v vectors
            // (p2 + imgVVec*), the pixel size (imgSizeU/V) and the display params
            // (brightness/contrast/fade/clip/show) map onto DRW_Image; the file path
            // is `textValue` (the IMAGEDEF name). IMAGE needs R2000+; at R12 / on DWG
            // (no DWG image writer) the C side drops it (counted skipped), like
            // MTEXT/DIMENSION. (The bitmap itself is NEVER embedded — only the path
            // is written, exactly as AutoCAD/LibreCAD store a linked raster image.)
            e.kind = Int32(LC_ENT_IMAGE.rawValue)
            e.p1x = d.insertion.x; e.p1y = d.insertion.y; e.p1z = d.insertion.z
            e.p2x = d.uVector.x;   e.p2y = d.uVector.y;   e.p2z = d.uVector.z
            e.imgVVecX = d.vVector.x; e.imgVVecY = d.vVector.y; e.imgVVecZ = d.vVector.z
            e.imgSizeU = d.imageDef.pixelWidth
            e.imgSizeV = d.imageDef.pixelHeight
            e.imgBrightness = Int32(d.display.brightness)
            e.imgContrast = Int32(d.display.contrast)
            e.imgFade = Int32(d.display.fade)
            e.imgClip = d.display.clipping ? 1 : 0
            e.imgShow = d.display.showImage ? 1 : 0
            e.textValue = intern(d.imageDef.path)

        case .wipeout(let d):
            // Emitted as a DXF WIPEOUT (DRW_Image + the AcDbWipeout subclass marker;
            // the C side calls `dxfRW::writeWipeout`). The placement frame reuses the
            // IMAGE fields: insertion → p1 (code 10); per-pixel u/v → p2 (code 11) +
            // imgVVec* (code 12); pixel size → imgSizeU/V (codes 13/23). The masking
            // polygon (pixel space) → the flat vertex array (codes 91/14/24); the clip
            // mode → wipeoutClipMode (code 290). NO IMAGEDEF (a wipeout has no raster).
            // WIPEOUT needs R2000+; at R12 / on DWG the C side drops it (counted
            // skipped), like IMAGE/MTEXT/DIMENSION.
            e.kind = Int32(LC_ENT_WIPEOUT.rawValue)
            e.p1x = d.insertion.x; e.p1y = d.insertion.y; e.p1z = d.insertion.z
            e.p2x = d.uVector.x;   e.p2y = d.uVector.y;   e.p2z = d.uVector.z
            e.imgVVecX = d.vVector.x; e.imgVVecY = d.vVector.y; e.imgVVecZ = d.vVector.z
            e.imgSizeU = d.pixelWidth
            e.imgSizeV = d.pixelHeight
            e.wipeoutClipMode = d.clipMode ? 1 : 0
            let (wptr, wcount) = internPoints(d.boundary)
            e.vertices = wptr
            e.vertexCount = wcount

        case .mline(let d):
            // Emitted as a DXF MLINE (DRW_MLine / AcDbMline) via STOCK
            // `dxfRW::writeMLine` — ZERO vendored libdxfrw edits. The vertex path →
            // the flat vertex array (codes 10/11); scale → mlineScale (code 40);
            // justification → mlineJustification (code 70: the engine's raw value 0
            // top / 1 zero / 2 bottom IS the DXF value); closed → mlineClosed (code 71
            // bit 0). The per-element offsets + colors do NOT live on the DXF MLINE
            // entity (they belong to the MLINESTYLE, which stock libdxfrw cannot
            // write), so they ride a "LIBRECAD" XDATA element table the C side builds
            // from mlineElementOffsets/mlineElementColors (full round-trip for our own
            // files; a foreign reader still sees the element count via code 73). A nil
            // per-element color → the `mlineColorNone` sentinel (mirrors the C bridge's
            // `LC_MLINE_COLOR_NONE` == Int32.min; restated because the C macro is not
            // Swift-importable). MLINE needs R2000+; at R12 / on DWG the C side drops it
            // (counted skipped), like MTEXT/DIMENSION.
            e.kind = Int32(LC_ENT_MLINE.rawValue)
            let (vptr, vcount) = internPoints(d.vertices)
            e.vertices = vptr
            e.vertexCount = vcount
            e.mlineScale = d.scale
            e.mlineJustification = Int32(d.justification.rawValue)
            e.mlineClosed = d.closed ? 1 : 0
            e.mlineElementCount = Int32(d.elements.count)
            let (optr, _) = internDoubles(d.elements.map(\.offset))
            e.mlineElementOffsets = optr
            // `Int32.min` mirrors the C bridge's `LC_MLINE_COLOR_NONE` (not importable).
            let mlineColorNone = Int32.min
            let colors: [Int32] = d.elements.map { el in
                if let ci = el.colorIndex { return Int32(truncatingIfNeeded: ci) }
                return mlineColorNone
            }
            let (cptr, _) = internInt32s(colors)
            e.mlineElementColors = cptr
        }
        return e
    }

    /// Builds the POD for a leader's ATTACHED ANNOTATION as a standalone, top-level
    /// DXF entity (TEXT/MTEXT), inheriting the leader's layer + pen, or `nil` if the
    /// leader has no annotation (or the annotation is not a text kind).
    ///
    /// G6b — best-effort leader annotation persistence. DXF models a leader's text
    /// as a SEPARATE entity HARD-REFERENCED from the LEADER via group code 340
    /// (`DRW_Leader::annotHandle`). libdxfrw's DXF leader writer
    /// (`dxfRW::writeLeader`) does NOT emit code 340 — it writes only the path,
    /// arrow, style and text height, never the annotation hard reference — and we do
    /// not modify the vendored libdxfrw. So we cannot author the TRUE LEADER→
    /// annotation hard reference through the library. What we CAN do (and do here):
    /// emit the annotation as an INDEPENDENT top-level TEXT/MTEXT so OTHER CAD tools
    /// SEE the leader's text, rather than losing it entirely (today an imported
    /// leader's annotation is dropped on DXF read, surviving only via the engine's
    /// Codable document path). The trade-off: on re-read the annotation comes back
    /// as a plain standalone TEXT/MTEXT, NOT re-attached to the leader (re-attachment
    /// needs code 340, which libdxfrw cannot write). The annotation keeps its own
    /// intrinsic position (anchored at the leader's last vertex by whoever authored
    /// it), so it renders in the right place. Pinned by a test in
    /// DXFWriteFidelityTests.
    func leaderAnnotationPOD(_ d: LeaderData, from leader: EntityRecord) -> LCEntity? {
        guard let annotation = d.annotation else { return nil }
        switch annotation {
        case .text, .mtext:
            // Re-wrap the annotation kind as a real EntityRecord so it goes through
            // the SAME TEXT/MTEXT POD mapping as a standalone text entity, inheriting
            // the leader's layer + pen so it draws in the leader's context.
            let record = EntityRecord(
                id: leader.id, layer: leader.layer, pen: leader.pen,
                flags: leader.flags, kind: annotation,
                space: leader.space, layoutName: leader.layoutName)
            return makeEntity(record)
        default:
            // A leader annotation is only ever a text/mtext kind; ignore anything
            // else (the value model bounds the recursion to text kinds).
            return nil
        }
    }

    /// The plain text string of a multileader's annotation (`.text`/`.mtext`), or
    /// `nil` if it has none. Carried into the MULTILEADER POD's `textValue` (the
    /// forward-compat CONTEXT_DATA `textLabel`). For `.mtext` we use the raw inline-
    /// coded passthrough string (the v1 multileader annotation is a `.text`).
    func multiLeaderAnnotationText(_ d: MultiLeaderData) -> String? {
        switch d.annotation {
        case .text(let t):  return t.text.isEmpty ? nil : t.text
        case .mtext(let m):
            guard let raw = m.rawCode, !raw.isEmpty else { return nil }
            return raw
        default:            return nil
        }
    }

    /// The annotation text height of a multileader's annotation, or `nil` if none.
    func multiLeaderAnnotationHeight(_ d: MultiLeaderData) -> Double? {
        switch d.annotation {
        case .text(let t):  return t.height
        case .mtext(let m): return m.height
        default:            return nil
        }
    }

    /// Builds the POD for a multileader's ATTACHED ANNOTATION as a standalone,
    /// top-level DXF entity (TEXT/MTEXT), inheriting the multileader's layer + pen, or
    /// `nil` if it has no text annotation. Mirrors `leaderAnnotationPOD`: stock
    /// libdxfrw's `writeMultiLeader` does NOT serialize the CONTEXT_DATA annotation,
    /// so — exactly like LEADER — the writer emits the annotation as an INDEPENDENT
    /// TEXT/MTEXT so other CAD tools SEE the multileader's text. On re-read it comes
    /// back as a plain standalone text (not re-attached); the engine's own Codable
    /// document path keeps the attached form. Pinned by MultiLeaderDXFRoundTripTests.
    func multiLeaderAnnotationPOD(_ d: MultiLeaderData, from mleader: EntityRecord) -> LCEntity? {
        guard let annotation = d.annotation else { return nil }
        switch annotation {
        case .text, .mtext:
            let record = EntityRecord(
                id: mleader.id, layer: mleader.layer, pen: mleader.pen,
                flags: mleader.flags, kind: annotation,
                space: mleader.space, layoutName: mleader.layoutName)
            return makeEntity(record)
        default:
            return nil
        }
    }

    /// Builds an `LCBlock` POD from a `Block` definition + the offset/count window
    /// of its member entities in the flat block-member POD array. The block's name +
    /// base point map straight onto the POD; the member PODs are built by the caller
    /// (so their backing storage lives on this builder).
    ///
    /// `memberOrder` is the ORDERED EntityIDs of the block's members as they are
    /// WRITTEN (the resolved `blockMembers[name]` order) — the same declaration order
    /// the reader re-mints fresh ids in. It keys the dynamic-DEFINITION index remap
    /// so member references survive the reader's fresh-id minting.
    func makeBlock(_ block: Block, memberOffset: Int, memberCount: Int,
                   memberOrder: [EntityID]) -> LCBlock {
        var b = LCBlock()
        b.name = intern(block.name.isEmpty ? "block" : block.name)
        b.bx = block.basePoint.x; b.by = block.basePoint.y; b.bz = block.basePoint.z
        b.flags = block.isFrozen ? 0x1 : 0
        b.memberOffset = Int32(memberOffset)
        b.memberCount = Int32(memberCount)
        // Block ATTDEF templates → flat LCAttrib array (the C side emits ATTDEF
        // entities inside the block definition). Empty ⇒ (nil, 0).
        let (dptr, dcount) = internAttribDefs(block.attributeDefs)
        b.attribDefs = dptr
        b.attribDefCount = dcount
        // DYNAMIC BLOCK: embed the per-DEFINITION authoring as a compact JSON string,
        // INDEX-KEYED against the written member order (member references → member
        // INDICES, so they survive the reader's fresh-id minting). The C bridge
        // persists it as a RESERVED-tag ATTDEF inside the block (the block ATTDEF
        // path round-trips through the unmodified libdxfrw; the bridge filters the
        // reserved tag back out on read). NULL for a plain block (the common case).
        if let def = block.dynamic, !def.isEmpty,
           let defJSON = def.encodeIndexKeyedJSON(memberOrder: memberOrder) {
            b.dynamicJSON = intern(defJSON)
        }
        return b
    }

    // MARK: Header + DIMSTYLE mapping (inverse of DXFReader.mapGraphicVariables)

    /// Builds the `LCHeader` POD from the drawing's `GraphicVariables`, setting each
    /// `has*` flag ONLY when the bag actually carries that var (so an absent var is
    /// left to libdxfrw's default rather than forced to a synthesized one). The
    /// active dim-style name comes from the DIMSTYLE table's `activeName` (or the
    /// `$DIMSTYLE` var). Mirrors the reader's header → graphic-var mapping in
    /// reverse so units / dim defaults / ext-line offsets ($DIMEXO/$DIMEXE/$DIMGAP)
    /// round-trip.
    func makeHeader(_ gv: GraphicVariables, dimStyles: DimStyleTable) -> LCHeader {
        var h = LCHeader()
        if gv.has("$INSUNITS") { h.insUnits = Int32(gv.unit.dxfCode); h.hasInsUnits = 1 }
        if gv.has("$LUNITS") {
            h.luUnits = Int32(GraphicVariables.dxfLUNITS(for: gv.linearFormat)); h.hasLuUnits = 1
        }
        if gv.has("$LUPREC") { h.luPrec = Int32(gv.linearPrecision); h.hasLuPrec = 1 }
        if gv.has("$AUNITS") { h.auUnits = Int32(gv.angleFormat.rawValue); h.hasAuUnits = 1 }
        if gv.has("$AUPREC") { h.auPrec = Int32(gv.anglePrecision); h.hasAuPrec = 1 }
        if gv.has("$DIMTXT") { h.dimTxt = gv.dimTextHeight; h.hasDimTxt = 1 }
        if gv.has("$DIMASZ") { h.dimAsz = gv.dimArrowSize; h.hasDimAsz = 1 }
        if gv.has("$DIMSCALE") { h.dimScale = gv.dimScale; h.hasDimScale = 1 }
        if gv.has("$DIMLUNIT") {
            h.dimLUnit = Int32(GraphicVariables.dxfLUNITS(for: gv.dimLinearFormat)); h.hasDimLUnit = 1
        }
        if gv.has("$DIMDEC") { h.dimDec = Int32(gv.dimLinearPrecision); h.hasDimDec = 1 }
        if gv.has("$DIMEXO") { h.dimExo = gv.dimExtensionOffset; h.hasDimExo = 1 }
        if gv.has("$DIMEXE") { h.dimExe = gv.dimExtensionBeyond; h.hasDimExe = 1 }
        if gv.has("$DIMGAP") { h.dimGap = gv.dimTextGap; h.hasDimGap = 1 }
        let activeName = dimStyles.activeName ?? gv.string("$DIMSTYLE", default: "")
        if !activeName.isEmpty { h.dimStyle = intern(activeName) }
        return h
    }

    /// R4b: builds the GENERIC extra-var `LCHeaderVar` PODs — the document-settings
    /// header vars the fixed `LCHeader` POD does NOT carry. Only vars the bag
    /// actually holds (`has`) are emitted, so an absent var stays at the file/engine
    /// default. The 7 standard targets are in libdxfrw's curated emit list, so they
    /// emit for free once they ride in `DRW_Header.vars`. COORD-typed vars
    /// ($GRIDUNIT/$PINSBASE) preserve the full vector (their `.vectorValue`).
    ///
    /// `$LC_SNAPMODE` is INTENTIONALLY NOT emitted here: it is a non-standard private
    /// `$`-var, and libdxfrw's writer only emits its curated standard var list (never
    /// `customVars`), so it would silently drop on a .dxf write. It is persisted only
    /// in memory / the Codable payload (decision: do not patch libdxfrw for an
    /// app-local preference).
    ///
    /// The vended PODs' `name` C-strings are interned in this builder, so the
    /// returned array is only valid while the builder lives (asserted by the caller).
    func makeHeaderVars(_ gv: GraphicVariables) -> [LCHeaderVar] {
        var out: [LCHeaderVar] = []

        func appendInt(_ key: String, _ value: Int) {
            var v = LCHeaderVar()
            v.name = intern(key)
            v.type = Int32(LC_HVAR_INT.rawValue)
            v.i = Int(value)        // C `long`
            out.append(v)
        }
        func appendDouble(_ key: String, _ value: Double) {
            var v = LCHeaderVar()
            v.name = intern(key)
            v.type = Int32(LC_HVAR_DOUBLE.rawValue)
            v.d = value
            out.append(v)
        }
        func appendCoord(_ key: String, _ vec: Vector) {
            var v = LCHeaderVar()
            v.name = intern(key)
            v.type = Int32(LC_HVAR_COORD.rawValue)
            v.coord = (vec.x, vec.y, 0.0)   // doc-settings coords are 2D (z = 0)
            out.append(v)
        }

        // Int-typed doc-settings vars.
        if gv.has("$GRIDMODE") { appendInt("$GRIDMODE", gv.int("$GRIDMODE")) }
        if gv.has("$PDMODE")   { appendInt("$PDMODE",   gv.int("$PDMODE")) }
        if gv.has("$ANGDIR")   { appendInt("$ANGDIR",   gv.int("$ANGDIR")) }
        // ISOMETRIC drafting (Wave 2c): $SNAPSTYLE (0 = rectangular, 1 = isometric).
        // A standard AutoCAD header var in libdxfrw's curated emit list, so once it
        // rides DRW_Header.vars it writes for free and round-trips on read (the bridge
        // whitelists SNAPSTYLE in kExtraInt). The PRIVATE plane var $LC_ISOPLANE is
        // deliberately NOT emitted — it would be dropped by libdxfrw's curated writer
        // anyway; it persists only in memory / the Codable payload (plane resets to
        // .top on a pure-DXF reopen).
        if gv.has("$SNAPSTYLE") { appendInt("$SNAPSTYLE", gv.int("$SNAPSTYLE")) }
        // Double-typed doc-settings vars.
        if gv.has("$PDSIZE")   { appendDouble("$PDSIZE",  gv.double("$PDSIZE")) }
        if gv.has("$ANGBASE")  { appendDouble("$ANGBASE", gv.double("$ANGBASE")) }
        // Drawing-wide LINETYPE SCALE ($LTSCALE, code 40). A standard AutoCAD header
        // var in libdxfrw's curated emit list, so once it rides DRW_Header.vars it
        // emits for free and round-trips on read (the bridge whitelists LTSCALE).
        if gv.has("$LTSCALE")  { appendDouble("$LTSCALE", gv.double("$LTSCALE")) }
        // COORD-typed doc-settings vars (codes 10/20/30) — preserve the vector.
        if gv.has("$GRIDUNIT") { appendCoord("$GRIDUNIT", gv.vector("$GRIDUNIT", default: Vector(0, 0))) }
        if gv.has("$PINSBASE") { appendCoord("$PINSBASE", gv.vector("$PINSBASE", default: Vector(0, 0))) }

        return out
    }

    /// Builds an `LCDimStyle` POD from a `NamedDimStyle` (the inverse of
    /// DXFReader's DIMSTYLE → `NamedDimStyle` mapping). The renderer-relevant
    /// subset (text height / arrow / scale / format / precision + the ext-line
    /// offsets) maps straight onto the POD; the C writer emits a DRW_Dimstyle.
    func makeDimStyle(_ s: NamedDimStyle) -> LCDimStyle {
        var d = LCDimStyle()
        d.name = intern(s.name.isEmpty ? "Standard" : s.name)
        d.dimTxt = s.style.textHeight
        d.dimAsz = s.style.arrowSize
        d.dimScale = s.style.scale
        d.dimDec = Int32(s.style.linearPrecision)
        d.dimLUnit = Int32(GraphicVariables.dxfLUNITS(for: s.style.linearFormat))
        d.dimExo = s.style.extensionOffset
        d.dimExe = s.style.extensionBeyond
        d.dimGap = s.style.textGap
        return d
    }

    /// Builds an `LCTextStyle` POD from a `TextStyle` (the inverse of DXFReader's
    /// STYLE → `TextStyle` mapping). Encodes the `FontSource` into code 3 + the
    /// code-1071 flags per the round-trip contract documented on `LCTextStyle`:
    /// `.native(family)` ⇒ family in code 3 + the `LC_TS_FONT_TTF` bit; `.stroke`/
    /// `.shx` ⇒ the `"<base>.lff"` / `"<base>.shx"` file name in code 3. Bold/italic
    /// ride the high code-1071 bits for ALL source kinds (so a bold STROKE style
    /// round-trips). The oblique angle stays in radians (the bridge converts to DXF
    /// degrees). The C writer emits a DRW_Textstyle. The `annotative` flag is NOT
    /// representable in DRW_Textstyle (it is AutoCAD XDATA) and does not round-trip.
    func makeTextStyle(_ s: TextStyle) -> LCTextStyle {
        var t = LCTextStyle()
        t.name = intern(s.name.isEmpty ? TextStyleTable.standardName : s.name)
        var family: Int32 = 0
        let fontString: String
        switch s.primaryFont {
        case .native(let fam):
            fontString = fam
            family |= Int32(LC_TS_FONT_TTF.rawValue)
        case .stroke(let lff):
            fontString = lff + ".lff"
        case .shx(let file):
            fontString = file.lowercased().hasSuffix(".shx") ? file : file + ".shx"
        }
        t.primaryFont = intern(fontString)
        t.bigFont = intern(s.bigFont ?? "")
        t.fixedTextHeight = s.fixedTextHeight
        t.widthFactor = s.widthFactor
        t.oblique = s.obliqueAngle               // radians; the bridge → DXF degrees
        t.lastHeight = s.lastHeight
        t.generationFlags = Int32(s.generation.rawValue)
        if s.bold   { family |= Int32(LC_TS_FONT_BOLD.rawValue) }
        if s.italic { family |= Int32(LC_TS_FONT_ITALIC.rawValue) }
        t.fontFamily = family
        t.styleFlags = Int32(s.styleFlags.rawValue)
        return t
    }

    // MARK: Viewport mapping (paper-space P3; inverse of DXFReader.mapViewports)

    /// Maps one `LayoutViewport` to an `LCViewport` POD. The paper frame center +
    /// size come from `paperRect`; the model view center/height from `viewCenter`/
    /// `viewHeight`. `vpID`/`vpStatus` are set to real-viewport values (> 1) so a
    /// round-trip read keeps it (the reader skips the overview viewport, vpID <= 1).
    func makeViewport(_ vp: LayoutViewport) -> LCViewport {
        var v = LCViewport()
        let c = vp.paperCenter
        v.centerX = c.x
        v.centerY = c.y
        v.width = vp.paperWidth
        v.height = vp.paperHeight
        v.viewCenterX = vp.viewCenter.x
        v.viewCenterY = vp.viewCenter.y
        v.viewHeight = vp.viewHeight
        v.vpID = 2          // a real (non-overview) viewport
        v.vpStatus = 2      // on/active
        v.layoutName = nil  // the writer keys layouts by emission order, not name
        return v
    }

    // MARK: Layer mapping (inverse of DXFReader.mapLayers)

    func makeLayer(_ layer: Layer) -> LCLayer {
        var l = LCLayer()
        l.name = intern(layer.name.isEmpty ? "0" : layer.name)
        l.lineType = intern(lineTypeName(layer.lineType))
        let (aci, color24) = colorPOD(.explicit(layer.color))
        l.color = aci
        l.color24 = color24
        l.lineWeightMM100 = lineWeightDXF(layer.lineWidth)
        // code 70: bit0 frozen, bit2 locked (matches DXFReader.mapLayers).
        var flags: Int32 = 0
        if layer.isFrozen { flags |= 0x1 }
        if layer.isLocked { flags |= 0x4 }
        l.flags = flags
        l.plot = layer.isPrintable ? 1 : 0
        l.transparency = layerTransparency1071(for: layer.opacity)
        return l
    }

    /// Maps a `Layer.opacity` to the raw `AcCmTransparency` value the bridge writes
    /// to the LAYER table's XDATA (code 1001 "AcCmTransparency" + code 1071 <value>).
    /// The encoding is the SAME `(alpha_type<<24)|alpha` form as per-entity code 440
    /// (`transparency440(for:)`), so the inverse decode is shared in spirit with
    /// `DXFReader.layerOpacity(fromTransparency1071:)`:
    ///   - a FULLY-OPAQUE layer (opacity 1, the historical default) ⇒ `0`, which the
    ///     bridge treats as "emit NO 1001/1071 group" — byte-identical to the
    ///     pre-transparency output.
    ///   - any non-opaque opacity ⇒ `0x02000000 | round(opacity*255)` (type 0x02,
    ///     "by value"; low byte == alpha, 255 == opaque).
    /// DXF only: the DWG layer writer has no per-layer XDATA hook, so per-layer
    /// transparency does not round-trip on DWG (a documented no-op; use DXF).
    private func layerTransparency1071(for opacity: Double) -> Int32 {
        let clamped = max(0, min(1, opacity))
        let alpha = Int32((clamped * 255.0).rounded()) & 0xFF
        // Fully opaque ⇒ 0 (no XDATA group). 255-alpha is exactly "opaque", so the
        // common all-opaque layer emits nothing and stays byte-clean.
        if alpha == 0xFF { return 0 }
        return 0x02000000 | alpha
    }

    // MARK: Pen / color / linetype / lineweight (inverse of DXFReader.mapPen)

    private func applyPen(_ pen: Pen, to e: inout LCEntity) {
        let (aci, color24) = colorPOD(pen.lineColor)
        e.color = aci
        e.color24 = color24
        e.lineType = intern(lineTypeName(pen.lineType))
        e.lineWeightMM100 = lineWeightDXF(pen.lineWidth)
        e.transparency = transparency440(for: pen.transparency)
        // Per-entity LINETYPE SCALE (DXF code 48). Set the POD value (≤ 0 ⇒ the 1.0
        // unscaled default). LIMITATION: stock libdxfrw's `writeEntity` does not emit
        // code 48, so this is dropped on the .dxf write (the bridge sets
        // DRW_Entity::ltypeScale but nothing serializes it). The drawing-wide
        // $LTSCALE round-trips via the HEADER (makeHeaderVars). See lcdxf.h.
        e.linetypeScale = pen.linetypeScale > 0 ? pen.linetypeScale : 1
    }

    /// Maps a `PenTransparency` to the raw DXF code-440 integer (the inverse of
    /// `DXFReader.penTransparency(code440:)`). The encoding is `(alpha_type<<24)|alpha`
    /// (low byte == alpha, 255 == opaque):
    ///   - `.byLayer` ⇒ `0` (DRW::Opaque) — the bridge then writes NO 440 group, so
    ///     a ByLayer entity is byte-identical to the pre-transparency output.
    ///   - `.byBlock` ⇒ `0x01000000` (type 0x01).
    ///   - `.opacity(a)` ⇒ `0x02000000 | round(a*255)` (type 0x02, "by value").
    /// NOTE: libdxfrw only emits code 440 for versions > AC1015 (R2000); at R12/R2000
    /// the transparency is dropped on write (a documented version limit, like MTEXT
    /// at R12). DWG: the dwgWriter15 path has no 440 encode, so transparency does not
    /// round-trip on DWG (use DXF R2004+).
    private func transparency440(for t: PenTransparency) -> Int32 {
        switch t {
        case .byLayer:
            return 0                              // DRW::Opaque ⇒ no 440 group written
        case .byBlock:
            return 0x01000000
        case .opacity(let a):
            let alpha = Int32((max(0, min(1, a)) * 255.0).rounded()) & 0xFF
            return 0x02000000 | alpha
        }
    }

    // MARK: Dimension mapping (inverse of DXFReader.mapDimension)

    /// Fills the DIMENSION fields of `e` from a `DimData`. The `DimKind` variant
    /// selects the `dimType` (an `LCDimType`) and which `dim*` defining points the
    /// C side reads back; the shared base fields (text override, style, attachment,
    /// line-spacing, text rotation) map straight onto the POD. The measured value
    /// (code 42) is intentionally not written — it is recomputed on read. This is
    /// the exact inverse of `DXFReader.mapDimension`.
    private func applyDimension(_ d: DimData, to e: inout LCEntity) {
        e.kind = Int32(LC_ENT_DIMENSION.rawValue)

        switch d.kind {
        case let .linear(e1, e2, angle):
            e.dimType = Int32(LC_DIM_LINEAR.rawValue)
            // code 10 == dim-line location (definitionPoint).
            setP1(&e, d.definitionPoint)
            setDef1(&e, e1)
            setDef2(&e, e2)
            e.dimAngle = angle
            e.dimOblique = d.obliqueAngle

        case let .aligned(e1, e2):
            e.dimType = Int32(LC_DIM_ALIGNED.rawValue)
            setP1(&e, d.definitionPoint)
            setDef1(&e, e1)
            setDef2(&e, e2)

        case let .radial(center, pointOnCircle):
            e.dimType = Int32(LC_DIM_RADIAL.rawValue)
            // center == code 10 (defPoint); pointOnCircle == code 15.
            setP1(&e, center)
            setDef5(&e, pointOnCircle)

        case let .diameter(p1, p2):
            e.dimType = Int32(LC_DIM_DIAMETRIC.rawValue)
            // p1 == code 15; p2 == code 10 (defPoint).
            setP1(&e, p2)
            setDef5(&e, p1)

        case let .angular(l1s, l1e, l2s, l2e):
            e.dimType = Int32(LC_DIM_ANGULAR.rawValue)
            // line1 = (def1 code13, def2 code14); line2 = (def5 code15,
            // defPoint code10 == l2e); the dimension arc passes through
            // DimData.definitionPoint, written as the arc point (code 16).
            setP1(&e, l2e)              // code 10: second line's endpoint
            setDef1(&e, l1s)
            setDef2(&e, l1e)
            setDef5(&e, l2s)
            e.dimArcx = d.definitionPoint.x
            e.dimArcy = d.definitionPoint.y
            e.dimArcz = d.definitionPoint.z

        case let .ordinate(origin, feature, leaderEnd, measuringX):
            e.dimType = Int32(LC_DIM_ORDINATE.rawValue)
            // origin == code 10 (defPoint); feature == def1 (code 13); leaderEnd ==
            // def2 (code 14); the X/Y datum is the dimOrdinateX flag (type-70 0x40).
            setP1(&e, origin)
            setDef1(&e, feature)
            setDef2(&e, leaderEnd)
            e.dimOrdinateX = measuringX ? 1 : 0

        case let .arcLength(center, radius, startAngle, endAngle, reversed):
            e.dimType = Int32(LC_DIM_ARC_LENGTH.rawValue)
            // The feature arc: center (p1/cx), radius, sweep startAngle→endAngle.
            // The dim-arc location is DimData.definitionPoint (written as the arc
            // point, code 16). def1/def2 carry the feature-arc endpoints so the C
            // side can persist the geometry via the 3p-angular carrier.
            setP1(&e, center)
            e.cx = center.x; e.cy = center.y; e.cz = center.z
            e.radius = radius
            e.startAngle = startAngle
            e.endAngle = endAngle
            e.dimReversed = reversed ? 1 : 0
            let featStart = center + Vector.polar(radius: abs(radius), angle: startAngle)
            let featEnd = center + Vector.polar(radius: abs(radius), angle: endAngle)
            setDef1(&e, featStart)
            setDef2(&e, featEnd)
            e.dimArcx = d.definitionPoint.x
            e.dimArcy = d.definitionPoint.y
            e.dimArcz = d.definitionPoint.z

        case let .angular3p(vertex, point1, point2):
            e.dimType = Int32(LC_DIM_ANGULAR3P.rawValue)
            // point1 == def1 (code 13); point2 == def2 (code 14); vertex == def5
            // (code 15); the dim arc passes through DimData.definitionPoint, written
            // as the def point (code 10).
            setP1(&e, d.definitionPoint)
            setDef1(&e, point1)
            setDef2(&e, point2)
            setDef5(&e, vertex)
        }

        if let mid = d.textMiddle {
            e.dimTextx = mid.x; e.dimTexty = mid.y; e.dimTextz = mid.z
            e.dimHasText = 1
        } else {
            e.dimHasText = 0
        }
        if let override = d.textOverride, !override.isEmpty {
            e.textValue = intern(override)
        }
        if let style = d.styleName, !style.isEmpty {
            e.styleName = intern(style)
        }
        e.dimAlign = Int32(d.attachmentPoint.rawValue)
        e.dimLineStyle = Int32(d.lineSpacingStyle.rawValue)
        e.dimLineFactor = d.lineSpacingFactor
        if let rot = d.textRotation {
            e.dimTextRotation = rot
            e.dimHasTextRotation = 1
        } else {
            e.dimHasTextRotation = 0
        }

        // Per-entity text-height / arrow-size override (the inverse of the reader's
        // ACAD:DSTYLE xdata parse, DXFReader.mapDimension). The reader treats `0`
        // as the "inherit the document/style default" sentinel, so a `DimData`
        // value `> 0` is a genuine per-entity override worth re-emitting — set the
        // POD's override field + its `has*` flag. `<= 0` ⇒ leave the flag clear so
        // the bridge omits the DSTYLE group and the dimension inherits on re-read.
        // The C bridge's writeDimension turns these into the `ACAD:DSTYLE` xdata
        // (dim-var 140 = text height, 41 = arrow size).
        if d.textHeight > 0 {
            e.dimTextHeightOverride = d.textHeight
            e.dimHasTextHeightOverride = 1
        } else {
            e.dimHasTextHeightOverride = 0
        }
        if d.arrowSize > 0 {
            e.dimArrowSizeOverride = d.arrowSize
            e.dimHasArrowSizeOverride = 1
        } else {
            e.dimHasArrowSizeOverride = 0
        }
    }

    private func setP1(_ e: inout LCEntity, _ v: Vector) {
        e.p1x = v.x; e.p1y = v.y; e.p1z = v.z
    }
    private func setDef1(_ e: inout LCEntity, _ v: Vector) {
        e.dimDef1x = v.x; e.dimDef1y = v.y; e.dimDef1z = v.z
    }
    private func setDef2(_ e: inout LCEntity, _ v: Vector) {
        e.dimDef2x = v.x; e.dimDef2y = v.y; e.dimDef2z = v.z
    }
    private func setDef5(_ e: inout LCEntity, _ v: Vector) {
        e.dimDef5x = v.x; e.dimDef5y = v.y; e.dimDef5z = v.z
    }

    /// Maps a `PenColor` to the (code-62 ACI, code-420 true color) POD pair.
    /// `.explicit` writes the packed RGB as `color24` (which the reader prefers
    /// over the ACI index) and a placeholder index 7 for legacy readers — the
    /// exact inverse of `DXFReader.resolvedColor`, which round-trips via
    /// `color24 >= 0`.
    private func colorPOD(_ color: PenColor) -> (aci: Int32, color24: Int32) {
        switch color {
        case .byLayer:
            return (256, -1)
        case .byBlock:
            return (0, -1)
        case .explicit(let rgba):
            return (7, packedRGB(rgba))
        }
    }

    /// Packs an `RGBAColor` into 0x00RRGGBB (the inverse of
    /// `DXFReader.rgba(fromPacked:)`).
    private func packedRGB(_ c: RGBAColor) -> Int32 {
        let r = Int32((c.r * 255.0).rounded()) & 0xFF
        let g = Int32((c.g * 255.0).rounded()) & 0xFF
        let b = Int32((c.b * 255.0).rounded()) & 0xFF
        return (r << 16) | (g << 8) | b
    }

    /// Maps a `PenLineType` to its DXF linetype name (the inverse of
    /// `DXFReader.lineType(fromName:)`). Solid is CONTINUOUS.
    private func lineTypeName(_ lt: PenLineType) -> String {
        switch lt {
        case .byLayer: return "BYLAYER"
        case .byBlock: return "BYBLOCK"
        case .solid:   return "CONTINUOUS"
        case .dashed:  return "DASHED"
        case .dotted:  return "DOT"
        case .dashDot: return "DASHDOT"
        case .center:  return "CENTER"
        case .border:  return "BORDER"
        case .divide:  return "DIVIDE"
        }
    }

    /// Maps a `PenLineWidth` to the DXF lineweight integer (mm*100, with the
    /// -1/-2/-3 ByLayer/ByBlock/default sentinels). The inverse of
    /// `DXFReader.penLineWidth(mm100:)`.
    private func lineWeightDXF(_ w: PenLineWidth) -> Int32 {
        switch w {
        case .byLayer:           return -1
        case .byBlock:           return -2
        case .default:           return -3
        case .millimeters(let m): return Int32((m * 100.0).rounded())
        }
    }
}

// MARK: - MTEXT run-tree -> coded string (inverse of MTextParser)

/// Serializes an `MTextData` run tree back into an AutoCAD/DXF MTEXT inline-coded
/// string — the inverse of `MTextParser.parse`. Used ONLY as the fallback when an
/// `.mtext` entity has no preserved `rawCode` (i.e. it was built or edited in the
/// app): a freshly-read entity always re-emits its verbatim `rawCode` for lossless
/// round-trip, so this path never has to reproduce codes the parser merely passes
/// through. Each run's formatting is wrapped in a `{ … }` scope so per-run state
/// never leaks into the next run (matching how the parser pushes/pops on braces).
///
/// Coverage mirrors the codes the parser models: `\f` (font + bold/italic), `\H`
/// (relative `<f>x` / absolute), `\C`/`\c` (colour), `\L`/`\O`/`\K` (decorations),
/// `\T` (tracking), `\Q` (oblique, degrees), `\S` (stacked), `\t` (tab), `\P`
/// (paragraph break), and the `\\ \{ \}` literal escapes. Paragraph alignment
/// (`\pq…`) is emitted at the start of a paragraph when set.
enum MTextEncoder {

    /// Encode a list of paragraphs into one MTEXT coded string (paragraphs joined
    /// by `\P`).
    static func encode(_ paragraphs: [MTextParagraph]) -> String {
        paragraphs.map(encodeParagraph).joined(separator: "\\P")
    }

    private static func encodeParagraph(_ p: MTextParagraph) -> String {
        var out = ""
        if let align = p.alignment {
            out += alignmentCode(align)
        }
        for inline in p.inlines {
            switch inline {
            case .run(let run):       out += encodeRun(run)
            case .stacked(let s):     out += encodeStacked(s)
            case .tab:                out += "\\t"
            }
        }
        return out
    }

    /// Wrap a run's formatting in a `{ … }` scope so it does not bleed into the
    /// following run. Codes are emitted in a stable order before the (escaped) text.
    private static func encodeRun(_ run: TextRun) -> String {
        var codes = ""

        // Bold / italic are FONT attributes in MTEXT — they only exist as the
        // `|b`/`|i` flags inside a `\f…;` code (the parser sets them only via
        // `applyFont`). So emit a font code whenever a font override OR a
        // bold/italic flag is present; if there is no explicit family, fall back to
        // a standard one ("Arial") so the flags have a code to ride on.
        if run.fontOverride != nil || run.bold == true || run.italic == true {
            codes += fontCode(run.fontOverride, bold: run.bold, italic: run.italic)
        }
        if let hf = run.heightFactor {
            // Parser sentinel: negative factor == absolute world height; positive
            // == relative factor (`<f>x`).
            if hf < 0 {
                codes += "\\H\(trimDouble(-hf));"
            } else {
                codes += "\\H\(trimDouble(hf))x;"
            }
        }
        if let color = run.color {
            codes += "\\c\(bgrDecimal(color));"   // true-colour form the parser reads
        }
        if run.underline     { codes += "\\L" }
        if run.overline      { codes += "\\O" }
        if run.strikethrough { codes += "\\K" }
        if let t = run.trackingFactor { codes += "\\T\(trimDouble(t));" }
        if let q = run.obliqueOverride { codes += "\\Q\(trimDouble(q * 180.0 / .pi));" }

        let body = escapeText(run.text)
        // A plain run (no codes) needs no scope braces.
        if codes.isEmpty { return body }
        return "{" + codes + body + "}"
    }

    /// `\S<upper>(/|^|#)<lower>;`. The divider selects the kind (the inverse of
    /// `MTextParser.parseStacked`); a literal `;` inside a side is escaped.
    private static func encodeStacked(_ s: StackedRun) -> String {
        let divider: String
        switch s.kind {
        case .fraction:  divider = "/"
        case .tolerance: divider = "^"
        case .diagonal:  divider = "#"
        }
        return "\\S" + escapeStackedSide(s.upper) + divider + escapeStackedSide(s.lower) + ";"
    }

    // MARK: helpers

    /// `\f<family>|b<0/1>|i<0/1>;` (native/stroke families). `.shx` uses `\F`. With
    /// no font override the family defaults to "Arial" so a standalone bold/italic
    /// flag still has a parseable font code to ride on.
    private static func fontCode(_ font: FontSource?, bold: Bool?, italic: Bool?) -> String {
        let family: String
        let lead: String
        switch font {
        case .native(let f): family = f; lead = "\\f"
        case .stroke(let f): family = f; lead = "\\f"
        case .shx(let f):    family = f; lead = "\\F"
        case nil:            family = "Arial"; lead = "\\f"
        }
        var s = lead + family
        s += "|b\(bold == true ? 1 : 0)"
        s += "|i\(italic == true ? 1 : 0)"
        s += ";"
        return s
    }

    private static func alignmentCode(_ a: MTextParagraphAlign) -> String {
        switch a {
        case .left:        return "\\pql;"
        case .center:      return "\\pqc;"
        case .right:       return "\\pqr;"
        case .justified:   return "\\pqj;"
        case .distributed: return "\\pqd;"
        }
    }

    /// Escape MTEXT control characters in literal run text: backslash and braces.
    private static func escapeText(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "{":  out += "\\{"
            case "}":  out += "\\}"
            default:   out.append(ch)
            }
        }
        return out
    }

    /// A stacked side is `;`-terminated as a whole, so a literal `;` must be
    /// escaped (the parser's `readStackedArg` stops at the first UNescaped `;`).
    private static func escapeStackedSide(_ s: String) -> String {
        escapeText(s).replacingOccurrences(of: ";", with: "\\;")
    }

    /// Pack an `RGBAColor` into the 24-bit BGR decimal AutoCAD stores after `\c`
    /// (the inverse of `MTextParser.colorFromTrueColor`).
    private static func bgrDecimal(_ c: RGBAColor) -> Int {
        let r = Int((c.r * 255.0).rounded()) & 0xFF
        let g = Int((c.g * 255.0).rounded()) & 0xFF
        let b = Int((c.b * 255.0).rounded()) & 0xFF
        return (b << 16) | (g << 8) | r
    }

    /// Format a double without a trailing `.0` (so `\H2x;` not `\H2.0x;`), keeping
    /// fractional values intact.
    private static func trimDouble(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int(v.rounded()))
        }
        return String(v)
    }
}
