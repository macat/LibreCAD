//
//  CompileShims.swift
//  LCShot
//
//  Minimal, behavior-free compile shims that satisfy the symlinked app sources
//  (`_SharedCanvasModel.swift` et al.) without pulling the SwiftUI view layer into
//  this headless target — the SAME approach the `CADEngineTests` target takes (see
//  the `PaperSize` shim documented in `RelativeZeroTests.swift`).
//
//  `CanvasModel.swift` references `PaperSize`, a trivial value enum that lives inside
//  the SwiftUI file `DocumentSettingsView.swift` (which cannot be symlinked — it
//  cascades into `CADCanvasView` and SwiftUI view builders). `CanvasModel` only uses
//  `PaperSize` as the type of one stored default (`paperSize = .a4`) and never calls
//  its methods, so this minimal, behavior-free shim satisfies the symlinked compile
//  without the view layer. LCShot never reads `model.paperSize`, so there is no
//  behavioral drift risk. (Relocating `PaperSize` out of the SwiftUI file would let
//  the symlink resolve with no shim — a non-owned-file change LCShot does not make.)
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// Behavior-free shim for the app's `PaperSize` enum (whose real definition lives in
/// the un-symlinkable SwiftUI `DocumentSettingsView.swift`). Cases mirror the test
/// target's shim so the two stay in lockstep. Never invoked by LCShot.
enum PaperSize: String, Sendable, CaseIterable, Hashable {
    case a4, a3, a2, a1, a0, letter, legal, tabloid
}
