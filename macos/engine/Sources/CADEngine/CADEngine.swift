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
public enum CADEngineError: Error, Equatable, Sendable {
    /// The path was null/empty or otherwise rejected before parsing.
    case invalidPath(String)
    /// libdxfrw reported a read failure (with a description, when available).
    case readFailed(String)
}

/// The drawing engine entry point.
///
/// `entityCount(atPath:)` is a synchronous, single-shot call into libdxfrw, so
/// the actor simply serializes access to that non-reentrant C library. The
/// heavy work runs to completion inside the call; this is acceptable for the
/// spine and can later move to a detached task if needed.
public actor CADEngine {
    public init() {}

    /// Counts the geometric entities in the DXF at `path` by streaming it
    /// through libdxfrw's `DRW_Interface`.
    ///
    /// - Throws: `CADEngineError` on an invalid path or a libdxfrw read error.
    /// - Returns: the number of geometric entities found (>= 0).
    public func entityCount(atPath path: String) throws -> Int {
        let result = lc_dxf_count_entities(path)
        if result >= 0 {
            return Int(result)
        }
        let message = lc_dxf_last_error().map { String(cString: $0) } ?? "unknown error"
        switch result {
        case -1:
            throw CADEngineError.invalidPath(message)
        default:
            throw CADEngineError.readFailed(message)
        }
    }
}
