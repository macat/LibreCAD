//
//  ToolKind.swift
//  CADEngine
//
//  The single enumerated tool-registration point. `ToolKind` names the active
//  interaction mode (select, or a concrete draw tool) and `makeTool()` mints a
//  fresh value of the matching `Tool`. The app's `CanvasModel` holds a
//  `ToolKind` and asks it for the live tool.
//
//  ## Fan-out collision note (read before adding a tool)
//  This enum + `makeTool()` is the ONE central file every new tool must edit
//  (add a `case` + an arm). To keep parallel builders from colliding on it:
//    - keep each addition to a SINGLE new `case` line and a SINGLE new arm line
//      (one-line diffs merge cleanly even when several land at once);
//    - add new cases at the END of the enum and new arms at the END of the switch
//      (append-only minimizes textual overlap);
//    - the tool's actual logic lives entirely in its OWN `Tools/<Name>Tool.swift`
//      file (no shared file beyond this two-line touch).
//  A merge of two append-only one-line additions is conflict-free; only two
//  builders editing the *same* line would conflict, which the append rule avoids.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// The active interaction mode. `.select` is the default (no draw tool: the
/// existing click-to-select / pan behavior); every other case is a concrete
/// drawing tool the app can activate.
public enum ToolKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// No draw tool — select / pan mode (the app's default).
    case select
    /// The Line draw tool (`LineTool`).
    case line
    // Append new draw tools here (one `case` per tool) — see the collision note.

    /// A short title for the UI (toolbar button / menu).
    public var title: String {
        switch self {
        case .select: return "Select"
        case .line:   return "Line"
        // Append a title arm per new case.
        }
    }

    /// Mints a fresh `Tool` value for this kind, or `nil` for `.select` (which is
    /// not a `Tool` — it is the app's built-in select/pan mode). The app calls
    /// this when the active kind changes.
    public func makeTool() -> (any Tool)? {
        switch self {
        case .select: return nil
        case .line:   return LineTool()
        // Append a `case <kind>: return <Name>Tool()` arm per new tool.
        }
    }
}
