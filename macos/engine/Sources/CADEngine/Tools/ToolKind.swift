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
    // --- Edit tools (pick entities under the cursor; no pre-selection needed) ---
    /// The Trim edit tool (`TrimTool`) — click the part of a line/arc to cut away.
    case trim
    /// The Extend edit tool (`ExtendTool`) — click near an end to grow it to a boundary.
    case extend
    /// The Fillet edit tool (`FilletTool`) — round the corner between two lines.
    case fillet
    /// The Chamfer edit tool (`ChamferTool`) — bevel the corner between two lines.
    case chamfer
    // --- Wave-A tools (wired into the UI in this wave) ---
    /// The Spline draw tool (`SplineTool`) — click fit points, commit one spline.
    case spline
    /// The Array modify tool (`ArrayTool`) — replicate the selection in a grid/ring.
    case array
    /// The Divide modify tool (`DivideTool`) — drop N−1 division points on a selected entity.
    case divide
    /// The Explode modify tool (`ExplodeTool`) — break a selected polyline into segments.
    case explode
    /// The Hatch draw tool (`HatchTool`) — fill the region bounded by the selection.
    case hatch
    // --- Wire-wave-B tools (wired into the UI in this wave) ---
    /// The Text authoring tool (`TextTool`) — click an insertion point, type, commit.
    case text
    /// The Linear dimension tool (`LinearDimTool`, horizontal) — distance between two
    /// extension origins along a fixed direction.
    case linearDim
    /// The Aligned dimension tool (`AlignedDimTool`) — true distance between two points.
    case alignedDim
    /// The Radial (radius "R…") dimension tool (`RadialDimTool` in `.radius` mode).
    case radialDim
    /// The Diameter ("⌀…") dimension tool (`RadialDimTool` in `.diameter` mode).
    case diameterDim
    /// The Angular dimension tool (`AngularDimTool`) — angle between two rays/lines.
    case angularDim
    // --- Wire-wave-C tools (wired into the UI in this wave) ---
    /// The Stretch modify tool (`StretchTool`) — drag the in-window endpoints/vertices
    /// of the selection by a delta, leaving the rest fixed.
    case stretch
    /// The Lengthen modify tool (`LengthenTool`) — grow/shrink a line or arc at the
    /// picked end by a signed delta or to a point.
    case lengthen
    /// The Break modify tool (`BreakTool`) — split a line/arc/polyline at a point, or
    /// remove the span between two points.
    case `break`
    /// The Insert (block reference) draw tool (`InsertTool`) — place a reference to a
    /// named block by clicking an insertion point.
    case insert
    // --- Wire-wave-D tool (wired into the UI in this wave) ---
    /// The Polyline-Edit modify tool (`PolylineEditTool`) — pick a polyline, then
    /// move / add / remove a vertex, or toggle a segment straight↔arc.
    case polylineEdit
    // --- Wire-wave-1 tools (wired into the UI in this wave) ---
    /// Measure Distance (`MeasureTool` in `.distance` mode) — pick 2 points → the
    /// distance, Δx, Δy, and connecting angle, reported in the status HUD. Read-only.
    case measureDistance
    /// Measure Angle (`MeasureTool` in `.angle` mode) — pick a vertex + two rays →
    /// the interior angle at the vertex. Read-only.
    case measureAngle
    /// Measure Area (`MeasureTool` in `.areaPerimeter` mode) — pick a closed point
    /// loop → polygon area + perimeter (shoelace). Read-only.
    case measureArea
    /// Total Length (`MeasureTool` in `.totalLength` mode) — sum the resolved length
    /// of every entity in the current selection. Read-only.
    case measureLength
    /// The Join modify tool (`JoinTool`) — fuse touching/collinear lines and arcs
    /// into a single polyline (bulges preserved).
    case join
    /// The Explode-Text modify tool (`ExplodeTextTool`) — convert a `.text`/`.mtext`
    /// entity into its stroke `.polyline`s (via the font provider).
    case explodeText
    // --- Wire-wave-2 tools (wired into the UI in this wave) ---
    /// The Ordinate dimension tool (`OrdinateDimTool`) — measure the X/Y coordinate of
    /// a feature point relative to a datum origin, shown as a leader to a text point.
    case ordinateDim
    /// The Arc-Length dimension tool (`ArcLengthDimTool`) — dimension the swept length
    /// of an arc (or arc segment of a polyline) with a curved dimension line.
    case arcLengthDim
    /// The 3-point Angular dimension tool (`Angular3pDimTool`) — angle defined by a
    /// vertex + two endpoint picks (vs the 2-line `AngularDimTool`).
    case angular3pDim
    /// The Create-Block-from-selection tool (`CreateBlockTool`) — group the current
    /// selection into a NAMED block and replace it with one `.insert`. Produces a
    /// `CreateBlockRequest` the app applies via `CADDrawing.makeBlockFromEntities`.
    case createBlock
    /// The Explode-Insert modify tool (`ExplodeInsertTool`) — replace a selected block
    /// reference (`.insert`) with its block's member entities (per MINSERT cell).
    case explodeInsert
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
        case .trim:      return "Trim"
        case .extend:    return "Extend"
        case .fillet:    return "Fillet"
        case .chamfer:   return "Chamfer"
        case .spline:    return "Spline"
        case .array:     return "Array"
        case .divide:    return "Divide"
        case .explode:   return "Explode"
        case .hatch:     return "Hatch"
        case .text:        return "Text"
        case .linearDim:   return "Linear Dimension"
        case .alignedDim:  return "Aligned Dimension"
        case .radialDim:   return "Radius Dimension"
        case .diameterDim: return "Diameter Dimension"
        case .angularDim:  return "Angular Dimension"
        case .stretch:     return "Stretch"
        case .lengthen:    return "Lengthen"
        case .break:       return "Break"
        case .insert:      return "Insert Block"
        case .polylineEdit: return "Edit Polyline"
        case .measureDistance: return "Measure Distance"
        case .measureAngle:    return "Measure Angle"
        case .measureArea:     return "Measure Area"
        case .measureLength:   return "Total Length"
        case .join:            return "Join"
        case .explodeText:     return "Explode Text"
        case .ordinateDim:     return "Ordinate Dimension"
        case .arcLengthDim:    return "Arc Length Dimension"
        case .angular3pDim:    return "Angular Dimension (3-point)"
        case .createBlock:     return "Create Block"
        case .explodeInsert:   return "Explode Block"
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
        case .trim:      return TrimTool()
        case .extend:    return ExtendTool()
        case .fillet:    return FilletTool()
        case .chamfer:   return ChamferTool()
        case .spline:    return SplineTool()
        case .array:     return ArrayTool()
        case .divide:    return DivideTool()
        case .explode:   return ExplodeTool()
        case .hatch:     return HatchTool()
        case .text:        return TextTool()
        case .linearDim:   return LinearDimTool(orientation: .horizontal)
        case .alignedDim:  return AlignedDimTool()
        case .radialDim:   return RadialDimTool(mode: .radius)
        case .diameterDim: return RadialDimTool(mode: .diameter)
        case .angularDim:  return AngularDimTool()
        case .stretch:     return StretchTool()
        case .lengthen:    return LengthenTool()
        case .break:       return BreakTool()
        // InsertTool with no block name is inert (a safe no-op) — the block-picker UI
        // is a later task; activation never crashes even with no blocks in the drawing.
        case .insert:      return InsertTool()
        case .polylineEdit: return PolylineEditTool()
        // Measure variants: ONE ToolKind per MeasureTool.Mode (menu clarity), each
        // minting MeasureTool(mode:). All four are read-only (never commit).
        case .measureDistance: return MeasureTool(mode: .distance)
        case .measureAngle:    return MeasureTool(mode: .angle)
        case .measureArea:     return MeasureTool(mode: .areaPerimeter)
        case .measureLength:   return MeasureTool(mode: .totalLength)
        case .join:            return JoinTool()
        case .explodeText:     return ExplodeTextTool()
        // Wire-wave-2 dimension subtypes (Annotate group).
        case .ordinateDim:     return OrdinateDimTool()
        case .arcLengthDim:    return ArcLengthDimTool()
        case .angular3pDim:    return Angular3pDimTool()
        // CreateBlockTool with the default "Block" name: it produces a
        // `pendingCreation` REQUEST the app applies via the undoable
        // `CADDrawing.makeBlockFromEntities` (see CanvasModel.handleToolInput).
        case .createBlock:     return CreateBlockTool()
        // ExplodeInsertTool minted with the inert (no-blocks) provider; the app
        // injects the real `blockMembers` provider in `CanvasModel.applyToolConfig`
        // (the same construction-injection InsertTool uses for its preview members).
        case .explodeInsert:   return ExplodeInsertTool()
        // Append a `case <kind>: return <Name>Tool()` arm per new tool.
        }
    }
}
