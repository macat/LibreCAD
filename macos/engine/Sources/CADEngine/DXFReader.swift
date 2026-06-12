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
        public var warnings: [String]
    }

    /// Reads `dxfPath`, flattening every supported entity into `EntityRecord`s
    /// and mapping the layer table. Unsupported entity kinds become warnings
    /// rather than failures.
    ///
    /// - Throws: `CADEngineError.invalidPath` for a null/empty path;
    ///   `CADEngineError.readFailed` if libdxfrw cannot read the file.
    public func readEntities(dxfPath: String) throws -> DXFReadResult {
        var handle: OpaquePointer?
        let status = dxfPath.withCString { lc_dxf_read($0, &handle) }
        switch status {
        case LC_OK:
            break
        case LC_ERR_INVALID_PATH:
            throw CADEngineError.invalidPath
        default:
            throw CADEngineError.readFailed
        }
        guard let list = handle else { throw CADEngineError.readFailed }
        // Free the C handle no matter how we leave; every field is copied into
        // Swift values below, so nothing dangles into freed C memory.
        defer { lc_entity_list_free(list) }

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

        for (name, n) in unsupportedCounts.sorted(by: { $0.key < $1.key }) {
            warnings.append("Skipped \(n) unsupported \(name) entit\(n == 1 ? "y" : "ies") (not yet imported)")
        }

        return DXFReadResult(records: records, layers: layers, warnings: warnings)
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

        default: // LC_ENT_UNSUPPORTED and anything else
            return nil
        }
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
    drawing.load(entities: result.records, layers: result.layers)
    return drawing
}
