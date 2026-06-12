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
    // --- Draw tools (geometry-creating; ignore the selection) ---
    /// The Circle draw tool (`CircleTool`).
    case circle
    /// The Arc draw tool (`ArcTool`).
    case arc
    /// The Rectangle draw tool (`RectangleTool`).
    case rectangle
    /// The Polyline draw tool (`PolylineTool`).
    case polyline
    /// The Point draw tool (`PointTool`).
    case point
    // --- Modify tools (act on `ToolContext.selected`; need a selection) ---
    /// The Move modify tool (`MoveTool`).
    case move
    /// The Copy modify tool (`CopyTool`).
    case copy
    /// The Rotate modify tool (`RotateTool`).
    case rotate
    /// The Scale modify tool (`ScaleTool`).
    case scale
    /// The Mirror modify tool (`MirrorTool`).
    case mirror
    /// The Ellipse draw tool (`EllipseTool`).
    case ellipse
    /// The Polygon draw tool (`PolygonTool`).
    case polygon
    /// The Offset modify tool (`OffsetTool`) — acts on `ToolContext.selected`.
    case offset
    // Append new draw tools here (one `case` per tool) — see the collision note.

    /// A short title for the UI (toolbar button / menu).
    public var title: String {
        switch self {
        case .select:    return "Select"
        case .line:      return "Line"
        case .circle:    return "Circle"
        case .arc:       return "Arc"
        case .rectangle: return "Rectangle"
        case .polyline:  return "Polyline"
        case .point:     return "Point"
        case .move:      return "Move"
        case .copy:      return "Copy"
        case .rotate:    return "Rotate"
        case .scale:     return "Scale"
        case .mirror:    return "Mirror"
        case .ellipse:   return "Ellipse"
        case .polygon:   return "Polygon"
        case .offset:    return "Offset"
        // Append a title arm per new case.
        }
    }

    /// Mints a fresh `Tool` value for this kind, or `nil` for `.select` (which is
    /// not a `Tool` — it is the app's built-in select/pan mode). The app calls
    /// this when the active kind changes.
    public func makeTool() -> (any Tool)? {
        switch self {
        case .select:    return nil
        case .line:      return LineTool()
        case .circle:    return CircleTool()
        case .arc:       return ArcTool()
        case .rectangle: return RectangleTool()
        case .polyline:  return PolylineTool()
        case .point:     return PointTool()
        case .move:      return MoveTool()
        case .copy:      return CopyTool()
        case .rotate:    return RotateTool()
        case .scale:     return ScaleTool()
        case .mirror:    return MirrorTool()
        case .ellipse:   return EllipseTool()
        case .polygon:   return PolygonTool()
        case .offset:    return OffsetTool()
        // Append a `case <kind>: return <Name>Tool()` arm per new tool.
        }
    }
}
