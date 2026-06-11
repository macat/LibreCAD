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
    case invalidPath
    /// libdxfrw reported a read failure (bad/missing/corrupt file), or an
    /// exception escaped the parse and was caught at the C boundary.
    case readFailed
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
    ///   `CADEngineError.readFailed` if libdxfrw cannot read the file.
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
            throw CADEngineError.readFailed
        }
    }
}
