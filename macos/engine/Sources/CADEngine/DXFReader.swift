//
//  DXFReader.swift
//  CADEngine
//
//  The full DXF -> entities reader. Streams a DXF file through the DxfBridge C
//  ABI (libdxfrw flattened to POD), maps each flat entity onto the frozen
//  `EntityRecord` model (ADR-001), maps the layer table onto `LayerTable`, and
//  collects a warning list for entity kinds we don't yet flatten
//  (INSERT/DIMENSION/IMAGE/...). TEXT/MTEXT, HATCH, and SOLID/TRACE ARE imported.
//  Unsupported kinds are skipped, never fatal — the read still returns the
//  supported geometry.
//
//  All bridge access goes through `CADEngine.shared` (libdxfrw is non-reentrant,
//  so there is exactly one serialization point per process). The C handle is
//  freed via `defer`; every string is copied into Swift before the free, so no
//  Swift value ever dangles into freed C memory.
//
//  The callback -> data mapping (arc/ellipse/polyline/spline fields, ACI colors,
//  layer flags) is ported from LibreCAD's rs_filterdxfrw.cpp.
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

// MARK: - Engine reader entry points

extension CADEngine {

    /// The flat result of reading a DXF: the mapped entity records (in file
    /// order, ids already minted), the parsed layer table, and a list of
    /// human-readable warnings for entities that were skipped or downgraded.
    /// All value types, safe to cross the actor boundary back to the main actor.
    public struct DXFReadResult: Sendable {
        public var records: [EntityRecord]
        public var layers: LayerTable
        /// The parsed block table. Block member entities are also present in
        /// `records` (ADR-001: a block's contents are id-refs into the drawing's
        /// entity store), so loading is: `drawing.load(entities: records, …,
        /// blocks: blocks)`. Empty when the file has no (non-anonymous) blocks.
        public var blocks: BlockTable
        /// The parsed HEADER variables — drawing unit (`$INSUNITS`), linear format/
        /// precision (`$LUNITS`/`$LUPREC`), and the document-default dimension style
        /// (`$DIMTXT`/`$DIMASZ`/`$DIMSCALE`/`$DIMLUNIT`/`$DIMDEC`). The downstream
        /// `CADDrawing.makeResolveContext` → `dimStyleProvider` turns these into the
        /// `ResolvedDimStyle` dimensions inherit, so a file's real dimension size
        /// reaches the resolve without any Resolve/Tool change. Defaults (empty bag)
        /// when the file supplied none of them.
        public var graphicVariables: GraphicVariables
        public var warnings: [String]

        public init(records: [EntityRecord], layers: LayerTable,
                    blocks: BlockTable = BlockTable(),
                    graphicVariables: GraphicVariables = GraphicVariables(),
                    warnings: [String]) {
            self.records = records
            self.layers = layers
            self.blocks = blocks
            self.graphicVariables = graphicVariables
            self.warnings = warnings
        }
    }

    /// Reads `dxfPath`, flattening every supported entity into `EntityRecord`s
    /// and mapping the layer table. Unsupported entity kinds become warnings
    /// rather than failures.
    ///
    /// - Throws: `CADEngineError.invalidPath` for a null/empty path;
    ///   `CADEngineError.readFailed` if libdxfrw cannot read the file.
    public func readEntities(dxfPath: String) throws -> DXFReadResult {
        let list = try Self.openList(path: dxfPath, reader: lc_dxf_read)
        defer { lc_entity_list_free(list) }
        return Self.mapList(list)
    }

    /// Reads a DWG (binary AutoCAD) file, flattening it into the SAME
    /// `DXFReadResult` model the DXF reader produces — every entity kind, the
    /// layer table, and blocks flow through the identical POD→`EntityRecord`
    /// mapping (the bridge's `FlatteningReader` is shared across both formats).
    /// DWG is binary so it has a distinct entry point + bridge function
    /// (`lc_dwg_read` → libdxfrw `dwgRW`); everything downstream is unchanged.
    ///
    /// libdxfrw reads DWG R2000 (AC1015) and newer; an older/corrupt file fails
    /// the read and surfaces as `CADEngineError.readFailed`.
    ///
    /// - Throws: `CADEngineError.invalidPath` for a null/empty path;
    ///   `CADEngineError.readFailed` if libdxfrw cannot read the file (also
    ///   covers an unsupported/old DWG version).
    public func readEntities(dwgPath: String) throws -> DXFReadResult {
        let list = try Self.openList(path: dwgPath, reader: lc_dwg_read)
        defer { lc_entity_list_free(list) }
        return Self.mapList(list)
    }

    /// Opens a drawing file through the given bridge reader (`lc_dxf_read` or
    /// `lc_dwg_read`), mapping the C status to a thrown `CADEngineError`. The
    /// caller owns the returned handle and must `lc_entity_list_free` it.
    private static func openList(
        path: String,
        reader: (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?) -> LCStatus
    ) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = path.withCString { reader($0, &handle) }
        switch status {
        case LC_OK:
            break
        case LC_ERR_INVALID_PATH:
            throw CADEngineError.invalidPath
        default:
            throw CADEngineError.readFailed
        }
        guard let list = handle else { throw CADEngineError.readFailed }
        return list
    }

    /// Maps an opened bridge handle into a `DXFReadResult`. Shared by the DXF and
    /// DWG readers — the flattened POD model is format-independent, so the entire
    /// entity/layer/block mapping below is reused verbatim across both. The caller
    /// owns the handle's lifetime; every field is copied into Swift values here, so
    /// nothing dangles once the caller frees the handle.
    private static func mapList(_ list: OpaquePointer) -> DXFReadResult {

        let layers = Self.mapLayers(list)
        var records: [EntityRecord] = []
        var warnings: [String] = []
        var nextID: UInt64 = 1

        // Counts of each unsupported type for a compact warning summary.
        var unsupportedCounts: [String: Int] = [:]

        let count = Int(lc_entity_list_count(list))
        if count > 0, let base = lc_entity_list_entities(list) {
            records.reserveCapacity(count)
            for i in 0..<count {
                let e = base[i]
                if let mapped = Self.mapEntity(e, idSource: { defer { nextID += 1 }; return EntityID(nextID) }) {
                    records.append(mapped)
                } else {
                    let name = Self.string(e.typeName) ?? "UNKNOWN"
                    unsupportedCounts[name, default: 0] += 1
                }
            }
        }

        // Block definitions: each block's member entities are mapped + minted ids
        // and APPENDED to `records` (ADR-001 — block contents are id-refs into the
        // drawing's entity store), and the block table records those ids. A member
        // whose kind is unsupported is skipped (the block keeps its other members).
        var blocks = BlockTable()
        let blockCount = Int(lc_block_count(list))
        if blockCount > 0, let blockBase = lc_blocks(list),
           let memberBase = lc_block_entities(list) {
            let memberTotal = Int(lc_block_entity_count(list))
            for bi in 0..<blockCount {
                let b = blockBase[bi]
                guard let blockName = Self.string(b.name), !blockName.isEmpty else { continue }
                var memberIDs: [EntityID] = []
                let start = Int(b.memberOffset)
                let mcount = Int(b.memberCount)
                if start >= 0, mcount >= 0, start + mcount <= memberTotal {
                    for mi in start..<(start + mcount) {
                        let me = memberBase[mi]
                        guard let mapped = Self.mapEntity(
                            me, idSource: { defer { nextID += 1 }; return EntityID(nextID) })
                        else { continue }
                        records.append(mapped)
                        memberIDs.append(mapped.id)
                    }
                }
                blocks.add(Block(
                    name: blockName,
                    basePoint: Vector(b.bx, b.by, b.bz),
                    entityIDs: memberIDs,
                    isFrozen: (b.flags & 0x1) != 0))
            }
        }

        for (name, n) in unsupportedCounts.sorted(by: { $0.key < $1.key }) {
            warnings.append("Skipped \(n) unsupported \(name) entit\(n == 1 ? "y" : "ies") (not yet imported)")
        }

        let graphicVariables = Self.mapGraphicVariables(list)

        return DXFReadResult(records: records, layers: layers, blocks: blocks,
                             graphicVariables: graphicVariables, warnings: warnings)
    }

    // MARK: - Header / dim-style → graphic-variable mapping

    /// Maps the bridge's captured HEADER vars (`lc_header`) and DIMSTYLE table
    /// (`lc_dimstyles`) into `GraphicVariables`. Only vars the file actually
    /// supplied (their `has*` flag set) are written, so an absent var keeps the
    /// document's built-in default. The active/"Standard" dim style fills in any
    /// dimension default the header itself didn't carry (header takes precedence
    /// when both are present, since it is the document-active value). The downstream
    /// `dimStyleProvider` turns the resulting `$DIM*` vars into the `ResolvedDimStyle`
    /// dimensions inherit.
    private static func mapGraphicVariables(_ list: OpaquePointer) -> GraphicVariables {
        var gv = GraphicVariables()

        // 1) Active/"Standard" dim style first — its values are the lowest-priority
        //    document default. The header vars (set next) override them when present.
        if let activeStyle = activeDimStyle(list) {
            gv.dimTextHeight = activeStyle.dimTxt
            gv.dimArrowSize = activeStyle.dimAsz
            if activeStyle.dimScale > 0 { gv.dimScale = activeStyle.dimScale }
            gv.dimLinearFormat = GraphicVariables.linearFormat(fromDXF: Int(activeStyle.dimLUnit))
            gv.dimLinearPrecision = Int(activeStyle.dimDec)
        }

        // 2) HEADER vars — the document-active values; override the style defaults.
        if let hp = lc_header(list) {
            let h = hp.pointee
            if h.hasInsUnits != 0 { gv.unit = DrawingUnit(dxf: Int(h.insUnits)) }
            if h.hasLuUnits != 0 {
                gv.linearFormat = GraphicVariables.linearFormat(fromDXF: Int(h.luUnits))
            }
            if h.hasLuPrec != 0 { gv.linearPrecision = Int(h.luPrec) }
            if h.hasAuUnits != 0 {
                gv.angleFormat = GraphicVariables.angleFormat(fromDXF: Int(h.auUnits))
            }
            if h.hasAuPrec != 0 { gv.anglePrecision = Int(h.auPrec) }
            if h.hasDimTxt != 0, h.dimTxt > 0 { gv.dimTextHeight = h.dimTxt }
            if h.hasDimAsz != 0, h.dimAsz > 0 { gv.dimArrowSize = h.dimAsz }
            if h.hasDimScale != 0, h.dimScale > 0 { gv.dimScale = h.dimScale }
            if h.hasDimLUnit != 0 {
                gv.dimLinearFormat = GraphicVariables.linearFormat(fromDXF: Int(h.dimLUnit))
            }
            if h.hasDimDec != 0 { gv.dimLinearPrecision = Int(h.dimDec) }
        }

        return gv
    }

    /// Returns the dim style the header names active (`$DIMSTYLE`), or the
    /// "Standard"/"STANDARD" style, or the first style — whichever exists — from the
    /// captured DIMSTYLE table; `nil` if the file had no dim styles.
    private static func activeDimStyle(_ list: OpaquePointer) -> LCDimStyle? {
        let count = Int(lc_dimstyle_count(list))
        guard count > 0, let base = lc_dimstyles(list) else { return nil }
        let styles = UnsafeBufferPointer(start: base, count: count)

        // Prefer the header's active style name, if any.
        if let hp = lc_header(list), let activeName = string(hp.pointee.dimStyle),
           !activeName.isEmpty,
           let match = styles.first(where: {
               (string($0.name)?.caseInsensitiveCompare(activeName) == .orderedSame)
           }) {
            return match
        }
        // Else "Standard".
        if let std = styles.first(where: {
            (string($0.name)?.caseInsensitiveCompare("Standard") == .orderedSame)
        }) {
            return std
        }
        // Else the first defined style.
        return styles.first
    }

    // MARK: - Layer-table mapping

    private static func mapLayers(_ list: OpaquePointer) -> LayerTable {
        var parsed: [Layer] = []
        let count = Int(lc_layer_count(list))
        if count > 0, let base = lc_layers(list) {
            parsed.reserveCapacity(count)
            for i in 0..<count {
                let l = base[i]
                guard let name = string(l.name), !name.isEmpty else { continue }
                let frozen = (l.flags & 0x1) != 0
                let locked = (l.flags & 0x4) != 0
                parsed.append(
                    Layer(
                        name: name,
                        color: resolvedColor(aci: l.color, color24: l.color24)
                            ?? .librecadGreen,
                        lineType: lineType(fromName: string(l.lineType)),
                        lineWidth: lineWidth(mm100: l.lineWeightMM100),
                        isFrozen: frozen,
                        isLocked: locked,
                        isPrintable: l.plot != 0
                    )
                )
            }
        }
        // DXF requires layer "0"; ensure it exists so `.byLayer` always resolves.
        if !parsed.contains(where: { $0.name == "0" }) {
            parsed.insert(Layer(name: "0"), at: 0)
        }
        return LayerTable(layers: parsed, activeLayerName: "0")
    }

    // MARK: - Entity mapping

    /// Maps one flattened POD entity to an `EntityRecord`, or `nil` if the kind
    /// is unsupported (the caller turns that into a warning). `idSource` mints a
    /// fresh id only when a record is actually produced.
    private static func mapEntity(_ e: LCEntity, idSource: () -> EntityID) -> EntityRecord? {
        guard let kind = mapKind(e) else { return nil }
        let layerName = string(e.layer) ?? "0"
        let pen = mapPen(e)
        return EntityRecord(
            id: idSource(),
            layer: LayerID(layerName),
            pen: pen,
            flags: .default,
            kind: kind
        )
    }

    private static func mapKind(_ e: LCEntity) -> EntityKind? {
        switch e.kind {
        case Int32(LC_ENT_LINE.rawValue):
            return .line(LineData(start: Vector(e.p1x, e.p1y, e.p1z),
                                  end: Vector(e.p2x, e.p2y, e.p2z)))

        case Int32(LC_ENT_POINT.rawValue):
            return .point(PointData(position: Vector(e.p1x, e.p1y, e.p1z)))

        case Int32(LC_ENT_CIRCLE.rawValue):
            return .circle(CircleData(center: Vector(e.cx, e.cy, e.cz), radius: e.radius))

        case Int32(LC_ENT_ARC.rawValue):
            return .arc(ArcData(
                center: Vector(e.cx, e.cy, e.cz),
                radius: e.radius,
                startAngle: e.startAngle,
                endAngle: e.endAngle,
                reversed: false
            ))

        case Int32(LC_ENT_ELLIPSE.rawValue):
            // `majorEnd` is the major-axis endpoint RELATIVE to the center
            // (DXF code 11/21/31), exactly what EllipseData.majorP expects.
            return .ellipse(EllipseData(
                center: Vector(e.cx, e.cy, e.cz),
                majorP: Vector(e.p2x, e.p2y, e.p2z),
                ratio: e.ratio,
                startAngle: e.startAngle,
                endAngle: e.endAngle,
                reversed: false
            ))

        case Int32(LC_ENT_LWPOLYLINE.rawValue), Int32(LC_ENT_POLYLINE.rawValue):
            return .polyline(PolylineData(
                vertices: vertices(e),
                closed: e.closed != 0
            ))

        case Int32(LC_ENT_SPLINE.rawValue):
            return mapSpline(e)

        case Int32(LC_ENT_TEXT.rawValue):
            return mapText(e)

        case Int32(LC_ENT_MTEXT.rawValue):
            return mapMText(e)

        case Int32(LC_ENT_HATCH.rawValue):
            return .hatch(HatchData(
                loops: hatchLoops(e),
                solidFill: e.solidFill != 0,
                patternName: string(e.textValue)
            ))

        case Int32(LC_ENT_SOLID.rawValue):
            // Corners are already in ring order (the bridge un-swaps DXF's
            // bow-tie 3rd/4th vertex); a degenerate (<3 corner) solid is dropped.
            let corners = vertices(e).map(\.point)
            guard corners.count >= 3 else { return nil }
            return .solid(SolidData(corners: corners))

        case Int32(LC_ENT_DIMENSION.rawValue):
            // The bridge flattens the five DimKind-modelled DIMENSION variants
            // (linear/aligned/radial/diametric/angular) into LC_ENT_DIMENSION with
            // the concrete subtype in `dimType` and the per-variant defining points
            // in the `dim*` fields. Angular-3p and ordinate dimensions (not in the
            // frozen DimKind) still arrive as LC_ENT_UNSUPPORTED -> warning.
            return mapDimension(e)

        case Int32(LC_ENT_INSERT.rawValue):
            // A block reference (DXF INSERT/MINSERT) → `.insert`.
            return mapInsert(e)

        case Int32(LC_ENT_XLINE.rawValue):
            // DXF XLINE → `.xline`. base ← p1 (code 10); direction ← p2 (code 11,
            // a unit direction vector). A degenerate (zero) direction is dropped.
            let dir = Vector(e.p2x, e.p2y, e.p2z)
            guard dir.magnitude > Tolerance.distance else { return nil }
            return .xline(XLineData(base: Vector(e.p1x, e.p1y, e.p1z), direction: dir))

        case Int32(LC_ENT_RAY.rawValue):
            // DXF RAY → `.ray`. base ← p1 (code 10); direction ← p2 (code 11).
            let dir = Vector(e.p2x, e.p2y, e.p2z)
            guard dir.magnitude > Tolerance.distance else { return nil }
            return .ray(RayData(base: Vector(e.p1x, e.p1y, e.p1z), direction: dir))

        default: // LC_ENT_UNSUPPORTED (incl. ordinate/3p DIMENSION) and anything else
            return nil
        }
    }

    /// Maps a flattened INSERT POD to `InsertData`: block name (`textValue`),
    /// insertion point (p1), per-axis scale (ins*), rotation (startAngle, radians),
    /// and the MINSERT array. An insert with no block name is dropped (returns
    /// `nil` -> warning) — the resolve would have nothing to place.
    private static func mapInsert(_ e: LCEntity) -> EntityKind? {
        guard let name = string(e.textValue), !name.isEmpty else { return nil }
        return .insert(InsertData(
            blockName: name,
            insertionPoint: Vector(e.p1x, e.p1y, e.p1z),
            scale: Vector(e.insScaleX, e.insScaleY, e.insScaleZ),
            rotation: e.startAngle,
            rows: Int(e.insRows),
            cols: Int(e.insCols),
            rowSpacing: e.insRowSpacing,
            colSpacing: e.insColSpacing
        ))
    }

    /// Maps a flattened DIMENSION POD to `DimData`. The `dimType` discriminator
    /// (an `LCDimType`) selects the `DimKind` variant and which `dim*` defining
    /// points are meaningful; the shared base fields (text override, style,
    /// attachment, line-spacing, text rotation) map straight onto `DimData`. The
    /// measured value (DXF code 42) is deliberately NOT carried — `resolve()`
    /// recomputes it from the geometry, so a dimension re-measures on edit. An
    /// unrecognised `dimType` is dropped (returns `nil` -> warning).
    private static func mapDimension(_ e: LCEntity) -> EntityKind? {
        let definitionPoint = Vector(e.p1x, e.p1y, e.p1z)
        let kind: DimKind
        switch e.dimType {
        case Int32(LC_DIM_LINEAR.rawValue):
            kind = .linear(
                extension1: Vector(e.dimDef1x, e.dimDef1y, e.dimDef1z),
                extension2: Vector(e.dimDef2x, e.dimDef2y, e.dimDef2z),
                angle: e.dimAngle)
        case Int32(LC_DIM_ALIGNED.rawValue):
            kind = .aligned(
                extension1: Vector(e.dimDef1x, e.dimDef1y, e.dimDef1z),
                extension2: Vector(e.dimDef2x, e.dimDef2y, e.dimDef2z))
        case Int32(LC_DIM_RADIAL.rawValue):
            // center == defPoint (code 10); pointOnCircle == code 15.
            kind = .radial(
                center: definitionPoint,
                pointOnCircle: Vector(e.dimDef5x, e.dimDef5y, e.dimDef5z))
        case Int32(LC_DIM_DIAMETRIC.rawValue):
            // point1 == code 15; point2 == defPoint (code 10).
            kind = .diameter(
                point1: Vector(e.dimDef5x, e.dimDef5y, e.dimDef5z),
                point2: definitionPoint)
        case Int32(LC_DIM_ANGULAR.rawValue):
            // line1 = (def1 code13 -> def2 code14); line2 = (def5 code15 ->
            // defPoint code10); the dimension arc passes through `definitionPoint`,
            // which DimData reads from `definitionPoint` while the arc-through point
            // (code 16) drives the resolve. We store the def points; the resolve
            // uses `definitionPoint` (the arc point, code 16) for the arc location.
            kind = .angular(
                line1Start: Vector(e.dimDef1x, e.dimDef1y, e.dimDef1z),
                line1End: Vector(e.dimDef2x, e.dimDef2y, e.dimDef2z),
                line2Start: Vector(e.dimDef5x, e.dimDef5y, e.dimDef5z),
                line2End: definitionPoint)
        case Int32(LC_DIM_ANGULAR3P.rawValue):
            // point1 == def1 (code 13); point2 == def2 (code 14); vertex == def5
            // (code 15); the dimension arc passes through `definitionPoint` (the
            // dim point, code 10) which selects the sector + arc radius.
            kind = .angular3p(
                vertex: Vector(e.dimDef5x, e.dimDef5y, e.dimDef5z),
                point1: Vector(e.dimDef1x, e.dimDef1y, e.dimDef1z),
                point2: Vector(e.dimDef2x, e.dimDef2y, e.dimDef2z))
        case Int32(LC_DIM_ORDINATE.rawValue):
            // origin == def point (code 10); feature == def1 (code 13); leader end
            // == def2 (code 14); the X- vs Y-datum is the dimOrdinateX flag.
            kind = .ordinate(
                origin: definitionPoint,
                feature: Vector(e.dimDef1x, e.dimDef1y, e.dimDef1z),
                leaderEnd: Vector(e.dimDef2x, e.dimDef2y, e.dimDef2z),
                measuringX: e.dimOrdinateX != 0)
        case Int32(LC_DIM_ARC_LENGTH.rawValue):
            // The feature arc: center (p1/cx), radius, sweep startAngle→endAngle.
            // The dim-arc location is the arc point (code 16, dimArc*). (Only our
            // own writer emits this discriminator — see lcdxf.h LC_DIM_ARC_LENGTH;
            // a file authored elsewhere round-trips arc-length as 3p-angular.)
            kind = .arcLength(
                center: Vector(e.cx, e.cy, e.cz),
                radius: e.radius,
                startAngle: e.startAngle,
                endAngle: e.endAngle,
                reversed: e.dimReversed != 0)
        default:
            return nil
        }

        let textMiddle = e.dimHasText != 0
            ? Vector(e.dimTextx, e.dimTexty, e.dimTextz) : nil
        let textOverride = string(e.textValue)
        let attachment = MTextAttachment(rawValue: Int(e.dimAlign)) ?? .middleCenter
        let lineSpacingStyle = MTextLineSpacingStyle(rawValue: Int(e.dimLineStyle)) ?? .atLeast
        let lineSpacingFactor = e.dimLineFactor > 0 ? e.dimLineFactor : 1.0
        let textRotation: Double? = e.dimHasTextRotation != 0 ? e.dimTextRotation : nil

        // For a 2-line angular dimension the DXF def point (code 10) is the second
        // line's endpoint; the arc-through point (code 16) is the dimension-line
        // location. For an arc-length dim the code-10 point is the feature-arc
        // center (in p1), while the dim-arc location is the arc point (code 16).
        // In both cases use the arc point (code 16) as `definitionPoint` so the
        // resolve draws the arc where the file specifies; for all other variants
        // code 10 IS the definition point.
        let resolvedDefPoint: Vector
        if e.dimType == Int32(LC_DIM_ANGULAR.rawValue)
            || e.dimType == Int32(LC_DIM_ARC_LENGTH.rawValue) {
            resolvedDefPoint = Vector(e.dimArcx, e.dimArcy, e.dimArcz)
        } else {
            resolvedDefPoint = definitionPoint
        }

        // Per-entity text-height / arrow-size override (ACAD:DSTYLE xdata, parsed by
        // the bridge). When the file carries an override we stamp it onto DimData so
        // it WINS over the document default (resolve precedence: per-entity > 0 wins,
        // Resolve.swift:931/940). When absent we pass 0 — the engine's "inherit"
        // sentinel — so the document's `$DIMTXT`/`$DIMASZ` (via dimStyleProvider)
        // apply instead of the hard-coded 2.5 DimData.init default that masked them.
        let textHeight = e.dimHasTextHeightOverride != 0 && e.dimTextHeightOverride > 0
            ? e.dimTextHeightOverride : 0.0
        let arrowSize = e.dimHasArrowSizeOverride != 0 && e.dimArrowSizeOverride > 0
            ? e.dimArrowSizeOverride : 0.0

        return .dimension(DimData(
            kind: kind,
            definitionPoint: resolvedDefPoint,
            textOverride: textOverride,
            textMiddle: textMiddle,
            styleName: string(e.styleName),
            textHeight: textHeight,
            arrowSize: arrowSize,
            textRotation: textRotation,
            attachmentPoint: attachment,
            lineSpacingStyle: lineSpacingStyle,
            lineSpacingFactor: lineSpacingFactor,
            obliqueAngle: e.dimType == Int32(LC_DIM_LINEAR.rawValue) ? e.dimOblique : 0.0))
    }

    /// Maps a TEXT/MTEXT POD to `TextData`. An empty string (or non-positive
    /// height) is dropped (returns `nil` -> warning) since it would resolve to no
    /// geometry. The DXF alignment codes (72/73) map onto `TextHAlign`/
    /// `TextVAlign`; out-of-range codes fall back to the left/baseline default.
    private static func mapText(_ e: LCEntity) -> EntityKind? {
        let text = string(e.textValue) ?? ""
        guard !text.isEmpty, e.height > 0 else { return nil }
        return .text(TextData(
            position: Vector(e.p1x, e.p1y, e.p1z),
            height: e.height,
            rotation: e.startAngle,
            text: text,
            styleName: string(e.styleName),
            hAlign: TextHAlign(rawValue: Int(e.hAlign)) ?? .left,
            vAlign: TextVAlign(rawValue: Int(e.vAlign)) ?? .baseline
        ))
    }

    /// Maps an MTEXT POD to `MTextData`. The bridge hands back the RAW inline-coded
    /// string (`textValue`), the reference/wrap width (`mtextRectWidth`), the
    /// attachment point (`mtextAttachment`, 1..9), and the line-spacing style/factor.
    /// We PARSE the coded string into the run tree (`MTextParser`) AND keep it
    /// verbatim in `rawCode` so format codes we don't model still round-trip. An
    /// empty string or non-positive height is dropped (returns `nil` → warning).
    private static func mapMText(_ e: LCEntity) -> EntityKind? {
        let coded = string(e.textValue) ?? ""
        guard !coded.isEmpty, e.height > 0 else { return nil }
        let attachment = MTextAttachment(rawValue: Int(e.mtextAttachment)) ?? .topLeft
        let spacingStyle = MTextLineSpacingStyle(rawValue: Int(e.mtextLineSpacingStyle)) ?? .atLeast
        let factor = e.mtextLineSpacingFactor > 0 ? e.mtextLineSpacingFactor : 1
        return .mtext(MTextParser.makeData(
            coded: coded,
            position: Vector(e.p1x, e.p1y, e.p1z),
            height: e.height,
            rectWidth: max(0, e.mtextRectWidth),
            rotation: e.startAngle,
            styleName: string(e.styleName),
            attachment: attachment,
            lineSpacingStyle: spacingStyle,
            lineSpacingFactor: factor))
    }

    /// Copies a HATCH's flat vertex array, sliced by its per-loop (offset,count)
    /// windows, into an array of `PolylineVertex` rings.
    private static func hatchLoops(_ e: LCEntity) -> [[PolylineVertex]] {
        guard e.loopCount > 0, let loopBase = e.loops,
              e.vertexCount > 0, let vertBase = e.vertices else { return [] }
        let verts = UnsafeBufferPointer(start: vertBase, count: Int(e.vertexCount))
        let loops = UnsafeBufferPointer(start: loopBase, count: Int(e.loopCount))
        return loops.map { loop in
            let start = Int(loop.offset)
            let end = start + Int(loop.count)
            guard start >= 0, end <= verts.count, start < end else { return [] }
            return verts[start..<end].map {
                PolylineVertex(point: Vector($0.x, $0.y), bulge: $0.bulge)
            }
        }
    }

    /// Maps a SPLINE. A degenerate spline (fewer than `degree + 1` control
    /// points, or degree < 1) is unsupported -> warning. Carries control
    /// points, knots, and rational weights; the NURBS evaluator in Resolve.swift
    /// fills in a clamped knot vector when none is present.
    private static func mapSpline(_ e: LCEntity) -> EntityKind? {
        let cps = vertices(e).map(\.point)
        let degree = Int(e.degree)
        guard degree >= 1, cps.count >= degree + 1 else { return nil }
        var knots: [Double] = []
        if e.knotCount > 0, let kp = e.knots {
            knots = Array(UnsafeBufferPointer(start: kp, count: Int(e.knotCount)))
        }
        var weights: [Double] = []
        if e.weightCount > 0, let wp = e.weights {
            weights = Array(UnsafeBufferPointer(start: wp, count: Int(e.weightCount)))
        }
        // Only carry weights when they cover every control point (a rational
        // spline); a partial array would mis-weight the curve.
        if weights.count != cps.count { weights = [] }
        return .spline(SplineData(
            degree: degree,
            controlPoints: cps,
            knots: knots,
            weights: weights,
            closed: e.closed != 0
        ))
    }

    /// Copies an entity's flat vertex array into Swift `PolylineVertex`es.
    private static func vertices(_ e: LCEntity) -> [PolylineVertex] {
        guard e.vertexCount > 0, let base = e.vertices else { return [] }
        let buf = UnsafeBufferPointer(start: base, count: Int(e.vertexCount))
        return buf.map { PolylineVertex(point: Vector($0.x, $0.y), bulge: $0.bulge) }
    }

    // MARK: - Pen / color / linetype / lineweight mapping

    private static func mapPen(_ e: LCEntity) -> Pen {
        let color: PenColor
        if e.color == 256 {
            color = .byLayer
        } else if e.color == 0 {
            color = .byBlock
        } else if let rgba = resolvedColor(aci: e.color, color24: e.color24) {
            color = .explicit(rgba)
        } else {
            color = .byLayer
        }

        let lt: PenLineType
        switch string(e.lineType)?.uppercased() {
        case nil, "BYLAYER": lt = .byLayer
        case "BYBLOCK": lt = .byBlock
        default: lt = lineType(fromName: string(e.lineType))
        }

        let lw: PenLineWidth = penLineWidth(mm100: e.lineWeightMM100)
        return Pen(lineColor: color, lineType: lt, lineWidth: lw)
    }

    /// Resolves a concrete `RGBAColor` from a DXF entity/layer color. Prefers
    /// the 24-bit true color (code 420) when set; otherwise maps the ACI index
    /// (code 62) through libdxfrw's standard palette. Returns `nil` for the
    /// ByLayer/ByBlock sentinels and unresolvable values (caller treats those as
    /// "inherit").
    private static func resolvedColor(aci: Int32, color24: Int32) -> RGBAColor? {
        if color24 >= 0 {
            return rgba(fromPacked: color24)
        }
        let packed = lc_aci_to_rgb(aci)
        guard packed >= 0 else { return nil }
        return rgba(fromPacked: packed)
    }

    private static func rgba(fromPacked packed: Int32) -> RGBAColor {
        let r = Float((packed >> 16) & 0xFF) / 255.0
        let g = Float((packed >> 8) & 0xFF) / 255.0
        let b = Float(packed & 0xFF) / 255.0
        return RGBAColor(r, g, b, 1)
    }

    /// Maps a DXF linetype *name* to a `PenLineType`. The name set mirrors
    /// LibreCAD's `RS_FilterDXFRW::nameToLineType`; unknown names fall back to
    /// solid (CONTINUOUS).
    private static func lineType(fromName name: String?) -> PenLineType {
        guard let upper = name?.uppercased() else { return .solid }
        switch upper {
        case "", "CONTINUOUS", "SOLID", "BYLAYER", "BYBLOCK":
            return .solid
        case let n where n.hasPrefix("DOT"):
            return .dotted
        case let n where n.hasPrefix("DASHEDX") || n.hasPrefix("HIDDEN")
            || n.hasPrefix("DASHED") || n.hasPrefix("DASH"):
            return .dashed
        case let n where n.hasPrefix("DASHDOT") || n.hasPrefix("DOTDASH"):
            return .dashDot
        case let n where n.hasPrefix("CENTER"):
            return .center
        case let n where n.hasPrefix("BORDER"):
            return .border
        case let n where n.hasPrefix("DIVIDE"):
            return .divide
        default:
            return .solid
        }
    }

    /// Maps a DXF lineweight (mm*100, code 370) onto a layer `PenLineWidth`.
    /// The ByLayer/ByBlock/default sentinels (negative) map to `.default`.
    private static func lineWidth(mm100: Int32) -> PenLineWidth {
        mm100 >= 0 ? .millimeters(Double(mm100) / 100.0) : .default
    }

    /// Maps a DXF lineweight onto an entity `PenLineWidth`, preserving the
    /// ByLayer (-1) / ByBlock (-2) / default (-3) sentinels.
    private static func penLineWidth(mm100: Int32) -> PenLineWidth {
        switch mm100 {
        case -1: return .byLayer
        case -2: return .byBlock
        case ..<0: return .default
        default: return .millimeters(Double(mm100) / 100.0)
        }
    }

    // MARK: - String helpers

    /// Copies a borrowed C string into a Swift `String` (or `nil`). The copy is
    /// what makes freeing the C handle safe.
    private static func string(_ c: UnsafePointer<CChar>?) -> String? {
        guard let c else { return nil }
        return String(cString: c)
    }
}

// MARK: - High-level drawing load (main actor)

/// Loads a DXF file into a fully-built `CADDrawing` (layers + entities). This is
/// the renderer's entry point: hand it a path, get back a drawing the canvas can
/// `resolveAll()`. Heavy parsing runs on the shared `CADEngine` actor; the
/// resulting value records are applied to the `@MainActor` drawing here.
@MainActor
public func loadDrawing(dxfPath: String) async throws -> CADDrawing {
    let result = try await CADEngine.shared.readEntities(dxfPath: dxfPath)
    let drawing = CADDrawing()
    // Load the block table too so any INSERT resolves to its block's geometry
    // (the block's member records are part of `result.records`), plus the parsed
    // header graphic variables so dimensions resolve at the file's real size/units.
    drawing.load(entities: result.records, layers: result.layers,
                 blocks: result.blocks, graphicVariables: result.graphicVariables)
    return drawing
}

/// Loads a DWG file into a fully-built `CADDrawing` — the DWG counterpart of
/// `loadDrawing(dxfPath:)`. Reads through the shared engine actor's DWG path and
/// applies the same value records to a fresh `@MainActor` drawing.
@MainActor
public func loadDrawing(dwgPath: String) async throws -> CADDrawing {
    let result = try await CADEngine.shared.readEntities(dwgPath: dwgPath)
    let drawing = CADDrawing()
    drawing.load(entities: result.records, layers: result.layers,
                 blocks: result.blocks, graphicVariables: result.graphicVariables)
    return drawing
}
