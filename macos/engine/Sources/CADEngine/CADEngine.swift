//
//  CADEngine.swift
//  CADEngine
//
//  Native macOS port of LibreCAD (GPLv2-or-later). The DXF reading path
//  bridges to the vendored libdxfrw via the DxfBridge C module.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation
import DxfBridge

/// Errors surfaced by the engine when reading drawing files.
///
/// Wave 7: the original two cases (`invalidPath`, `readFailed`) are preserved
/// for C ABI compatibility and for existing call sites that treat any read
/// failure uniformly. The new `LC_ERR_BAD_*` cases mirror `DRW::error`
/// (one per libdxfrw read phase) so a failure surfaces its phase
/// (open vs header vs tables vs entities …) together with a human-readable
/// detail from `lc_status_message`. `LocalizedError` renders the typed detail
/// to UI (file + phase + message); callers that need only “did it fail?”
/// can still match `readFailed` as the generic fallback.
public enum CADEngineError: Error, Equatable, Sendable {
    /// The path was null/empty or otherwise rejected before parsing.
    case invalidPath
    /// libdxfrw reported a read failure (bad/missing/corrupt file), or an
    /// exception escaped the parse and was caught at the C boundary.
    /// Kept as the generic fallback for unknown `LCStatus` values and for
    /// backward compatibility with call sites that match `.readFailed`.
    case readFailed
    /// Cannot open file (not found or unreadable) — `LC_ERR_BAD_OPEN` / `DRW::BAD_OPEN`.
    case badOpen(detail: String)
    /// Unsupported DXF/DWG version — `LC_ERR_BAD_VERSION`.
    case badVersion(detail: String)
    /// Failed to read DWG metadata / sentinel — `LC_ERR_BAD_READ_METADATA`.
    case badReadMetadata(detail: String)
    /// Failed to read DWG file header — `LC_ERR_BAD_READ_FILE_HEADER`.
    case badReadFileHeader(detail: String)
    /// Failed to read HEADER section vars — `LC_ERR_BAD_READ_HEADER`.
    case badReadHeader(detail: String)
    /// Failed to read handle table — `LC_ERR_BAD_READ_HANDLES`.
    case badReadHandles(detail: String)
    /// Failed to read CLASSES section — `LC_ERR_BAD_READ_CLASSES`.
    case badReadClasses(detail: String)
    /// Failed to read TABLES (layers, styles) — `LC_ERR_BAD_READ_TABLES`.
    case badReadTables(detail: String)
    /// Failed to read BLOCKS section — `LC_ERR_BAD_READ_BLOCKS`.
    case badReadBlocks(detail: String)
    /// Failed to read ENTITIES (corrupt entity) — `LC_ERR_BAD_READ_ENTITIES`.
    /// Note: an *unsupported* entity kind is **not** a failure — it is skipped
    /// and surfaced as a warning in `DXFReadResult.warnings` (graceful
    /// degradation). This error means the ENTITIES section itself could not be
    /// parsed.
    case badReadEntities(detail: String)
    /// Failed to read OBJECTS section — `LC_ERR_BAD_READ_OBJECTS`.
    case badReadObjects(detail: String)
    /// Failed to read section (unknown section or truncated file) — `LC_ERR_BAD_READ_SECTION`.
    case badReadSection(detail: String)
    /// Parse error (invalid DXF group code) — `LC_ERR_BAD_CODE_PARSED`.
    case badCodeParsed(detail: String)
    /// Unknown / unmapped error — `LC_ERR_UNKNOWN` or a caught exception.
    case unknown(detail: String)

    /// Maps an `LCStatus` (plus its `lc_status_message` detail) to the typed
    /// `CADEngineError`. Keeps `LC_ERR_READ_FAILED` / `LC_ERR_WRITE_FAILED`
    /// as the legacy `.readFailed` for callers that match that exact case.
    static func from(status: LCStatus) -> CADEngineError {
        let detail = String(cString: lc_status_message(status))
        return from(status: status, detail: detail)
    }

    static func from(status: LCStatus, detail: String) -> CADEngineError {
        switch status {
        case LC_ERR_INVALID_PATH:         return .invalidPath
        case LC_ERR_READ_FAILED:          return .readFailed
        case LC_ERR_WRITE_FAILED:         return .readFailed
        case LC_ERR_BAD_OPEN:             return .badOpen(detail: detail)
        case LC_ERR_BAD_VERSION:          return .badVersion(detail: detail)
        case LC_ERR_BAD_READ_METADATA:    return .badReadMetadata(detail: detail)
        case LC_ERR_BAD_READ_FILE_HEADER: return .badReadFileHeader(detail: detail)
        case LC_ERR_BAD_READ_HEADER:      return .badReadHeader(detail: detail)
        case LC_ERR_BAD_READ_HANDLES:     return .badReadHandles(detail: detail)
        case LC_ERR_BAD_READ_CLASSES:     return .badReadClasses(detail: detail)
        case LC_ERR_BAD_READ_TABLES:      return .badReadTables(detail: detail)
        case LC_ERR_BAD_READ_BLOCKS:      return .badReadBlocks(detail: detail)
        case LC_ERR_BAD_READ_ENTITIES:    return .badReadEntities(detail: detail)
        case LC_ERR_BAD_READ_OBJECTS:     return .badReadObjects(detail: detail)
        case LC_ERR_BAD_READ_SECTION:     return .badReadSection(detail: detail)
        case LC_ERR_BAD_CODE_PARSED:      return .badCodeParsed(detail: detail)
        case LC_ERR_UNKNOWN:              return .unknown(detail: detail)
        default:                          return .readFailed
        }
    }

    /// Convenience: surface a path together with the typed detail, e.g.
    /// `"/tmp/foo.dxf: Failed to read ENTITIES (corrupt entity)"`.
    func withPath(_ path: String) -> CADEngineError {
        switch self {
        case .invalidPath:                return .invalidPath
        case .readFailed:                 return .readFailed
        case .badOpen(let d):             return .badOpen(detail: "\(path): \(d)")
        case .badVersion(let d):          return .badVersion(detail: "\(path): \(d)")
        case .badReadMetadata(let d):     return .badReadMetadata(detail: "\(path): \(d)")
        case .badReadFileHeader(let d):   return .badReadFileHeader(detail: "\(path): \(d)")
        case .badReadHeader(let d):       return .badReadHeader(detail: "\(path): \(d)")
        case .badReadHandles(let d):      return .badReadHandles(detail: "\(path): \(d)")
        case .badReadClasses(let d):      return .badReadClasses(detail: "\(path): \(d)")
        case .badReadTables(let d):       return .badReadTables(detail: "\(path): \(d)")
        case .badReadBlocks(let d):       return .badReadBlocks(detail: "\(path): \(d)")
        case .badReadEntities(let d):     return .badReadEntities(detail: "\(path): \(d)")
        case .badReadObjects(let d):      return .badReadObjects(detail: "\(path): \(d)")
        case .badReadSection(let d):      return .badReadSection(detail: "\(path): \(d)")
        case .badCodeParsed(let d):       return .badCodeParsed(detail: "\(path): \(d)")
        case .unknown(let d):             return .unknown(detail: "\(path): \(d)")
        }
    }
}

extension CADEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Invalid path"
        case .readFailed:
            return String(cString: lc_status_message(LC_ERR_READ_FAILED))
        case .badOpen(let d), .badVersion(let d), .badReadMetadata(let d),
             .badReadFileHeader(let d), .badReadHeader(let d), .badReadHandles(let d),
             .badReadClasses(let d), .badReadTables(let d), .badReadBlocks(let d),
             .badReadEntities(let d), .badReadObjects(let d), .badReadSection(let d),
             .badCodeParsed(let d), .unknown(let d):
            return d
        }
    }
}

/// The drawing engine entry point.
///
/// ## One shared engine actor (foundation rule — Phase-1 fan-out MUST follow)
/// There is exactly **one** `CADEngine` actor instance for the process; all
/// heavy, off-main work that touches the non-reentrant libdxfrw C library and
/// the f64 geometry kernels is serialized through it. Do NOT spin up per-call or
/// per-feature engine actors — that would race libdxfrw and defeat the single
/// serialization point. The engine returns value types (ADR-001/003); callers
/// apply results to the `@MainActor` `CADDrawing` on the main actor.
///
/// `entityCount(atPath:)` is a synchronous, single-shot call into libdxfrw, so
/// the actor simply serializes access to that non-reentrant C library. The
/// heavy work runs to completion inside the call; this is acceptable for the
/// spine and can later move to a detached task if needed.
public actor CADEngine {
    /// The process-wide shared engine — the ONLY public way to reach the engine.
    public static let shared = CADEngine()

    /// `internal`, not `public`: external callers MUST go through
    /// `CADEngine.shared`. libdxfrw is non-reentrant, so there is exactly one
    /// engine actor per process (foundation rule above); a `public init` would
    /// let the Phase-1 fan-out spin up parallel engine actors and race the C
    /// library. `internal` keeps `.shared` constructible and lets `@testable`
    /// tests build instances without opening the door to the wider codebase.
    init() {}

    /// Counts the geometric entities in the DXF at `path` by streaming it
    /// through libdxfrw's `DRW_Interface`.
    ///
    /// - Throws: `CADEngineError.invalidPath` for a null/empty path;
    ///   a typed `CADEngineError` (e.g. `.badOpen`, `.badReadEntities`) if
    ///   libdxfrw cannot read the file (the detail is `lc_status_message` +
    ///   path, suitable for `LocalizedError` UI).
    /// - Returns: the number of geometric entities found (>= 0).
    public func entityCount(atPath path: String) throws -> Int {
        var count: Int32 = 0
        let status = lc_dxf_count_entities(path, &count)
        switch status {
        case LC_OK:
            return Int(count)
        case LC_ERR_INVALID_PATH:
            throw CADEngineError.invalidPath
        default:
            // Typed mapping: preserve the phase (BAD_OPEN vs BAD_READ_ENTITIES
            // etc.) so the caller can distinguish “file not found” from
            // “corrupt ENTITIES”. Graceful: a missing file now throws
            // `.badOpen`, not a generic `readFailed`, so UI can surface it.
            // Existing call sites that match `.readFailed` as a fallback will
            // need to handle the new cases or fall through to a generic alert.
            throw CADEngineError.from(status: status).withPath(path)
        }
    }
}
