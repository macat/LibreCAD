//
//  CoordinateDisplayMode.swift
//  CADEngine
//
//  The coordinate-readout display mode for the status bar (backlog #5). Mirrors
//  LibreCAD's classic status-bar behavior: the cursor coordinate can be shown as
//  an ABSOLUTE world point (`X / Y`), a RELATIVE offset from the last point
//  (`Δ X / Y`), or in POLAR form (`dist<angle`). The legacy app cycles these with
//  a single keystroke; this enum is the pure value that the (Phase 1) status bar
//  and the cycle command will read.
//
//  It is intentionally in CADEngine (NOT the SwiftUI app target) so it is plain,
//  testable state with NO GUI dependency. Pair it with `CoordinateFormatter`
//  (same module): `.absolute`/`.relative` render via `coordinatePair`, `.polar`
//  via `polarPair`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// How the status bar renders the cursor coordinate: an absolute world point, a
/// relative offset from the last point, or a polar `dist<angle` pair.
public enum CoordinateDisplayMode: String, Sendable, Hashable, CaseIterable {
    /// Absolute world coordinate (`X 12.5  Y 8`).
    case absolute
    /// Offset from the last point (`Δ X 3  Y 4`).
    case relative
    /// Polar form relative to the last point (`5<53.13°`).
    case polar

    /// The next mode in the status-bar cycle: absolute → relative → polar →
    /// absolute. The single-keystroke "toggle coordinate mode" command advances
    /// through this loop.
    public var next: CoordinateDisplayMode {
        switch self {
        case .absolute: return .relative
        case .relative: return .polar
        case .polar:    return .absolute
        }
    }
}
