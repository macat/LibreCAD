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
//  Supported kinds round-trip: line / point / circle / arc / ellipse / polyline.
//  Spline / text / hatch / and any other kind are skipped for now (counted, not
//  fatal) — they land with the matching reader-side wave.
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
        toPath path: String,
        version: DXFVersion = .r2000
    ) throws -> DXFWriteResult {
        guard !path.isEmpty else { throw CADWriteError.invalidPath }

        // Build the flat POD model. `Builder` owns every C string / vertex array
        // the PODs borrow; it must outlive the `lc_dxf_write` call below.
        let builder = PODBuilder()
        let entityPODs = entities.map { builder.makeEntity($0) }
        let layerPODs = layers.layers.map { builder.makeLayer($0) }

        var skipped: Int32 = 0
        let status = path.withCString { cpath -> LCStatus in
            entityPODs.withUnsafeBufferPointer { ents -> LCStatus in
                layerPODs.withUnsafeBufferPointer { lays -> LCStatus in
                    lc_dxf_write(
                        cpath,
                        ents.baseAddress, Int32(ents.count),
                        lays.baseAddress, Int32(lays.count),
                        version.rawValue,
                        &skipped
                    )
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
    return try await CADEngine.shared.writeEntities(
        entities, layers: layers, toPath: path, version: version
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

    deinit {
        for s in strings { s.deallocate() }
        for v in vertexBuffers { v.deallocate() }
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

    // MARK: Entity mapping (inverse of DXFReader.mapKind)

    /// Maps one `EntityRecord` to an `LCEntity` POD. Kinds the writer does not
    /// support (spline/splinePoints) are emitted as `LC_ENT_UNSUPPORTED`; the C
    /// side counts and skips them.
    func makeEntity(_ record: EntityRecord) -> LCEntity {
        var e = LCEntity()
        e.color = 256              // ByLayer default; overwritten by applyPen
        e.color24 = -1
        e.lineWeightMM100 = -1     // ByLayer default
        e.ratio = 1.0
        e.layer = intern(record.layer.name.isEmpty ? "0" : record.layer.name)
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

        case .spline, .splinePoints:
            // Not yet supported by the writer; the C side skips UNSUPPORTED.
            e.kind = Int32(LC_ENT_UNSUPPORTED.rawValue)
            e.typeName = intern("SPLINE")

        case .text, .hatch, .solid:
            // Display kinds not yet round-tripped through the writer; skipped
            // (counted UNSUPPORTED on the C side). TODO(backlog): DXF write for
            // TEXT/MTEXT/HATCH/SOLID once these are imported by the reader.
            e.kind = Int32(LC_ENT_UNSUPPORTED.rawValue)
            e.typeName = intern("DISPLAY")
        }
        return e
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
        return l
    }

    // MARK: Pen / color / linetype / lineweight (inverse of DXFReader.mapPen)

    private func applyPen(_ pen: Pen, to e: inout LCEntity) {
        let (aci, color24) = colorPOD(pen.lineColor)
        e.color = aci
        e.color24 = color24
        e.lineType = intern(lineTypeName(pen.lineType))
        e.lineWeightMM100 = lineWeightDXF(pen.lineWidth)
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
