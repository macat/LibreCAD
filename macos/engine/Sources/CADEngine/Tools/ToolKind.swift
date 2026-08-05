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
    // --- Wire-wave-3 tools (wired into the UI in this wave) ---
    /// The infinite construction-line tool (`XLineTool`) — pick a base + a direction
    /// point, commit an infinite `.xline` (Draw ▸ construction-line subgroup).
    case xline
    /// The semi-infinite construction-line tool (`RayTool`) — pick a base + a
    /// direction point, commit a `.ray` (Draw ▸ construction-line subgroup).
    case ray
    /// The Align modify tool (`AlignTool`) — map the selection onto a 2-point
    /// source→destination reference (translate + rotate + optional scale-to-fit).
    case align
    /// The Array-along-path modify tool (`ArrayPathTool`) — distribute N copies of the
    /// selection at equal arc-length stations along a picked path entity.
    case arrayPath
    /// The Leader annotation tool (`LeaderTool`) — click callout vertices (arrow at the
    /// first), commit a `.leader` with an optional attached text annotation.
    case leader
    /// The Multileader (MLEADER) annotation tool (`MultiLeaderTool`) — click callout
    /// vertices (arrow at the first), commit a `.multileader` with a landing/dogleg
    /// tail and an optional attached text annotation.
    case multileader
    /// The Baseline linear-dimension tool (`BaselineDimTool`) — chain dims from a
    /// common baseline origin, each stepped one DIMDLI further out (a stacked run).
    case baselineDim
    /// The Continue linear-dimension tool (`ContinueDimTool`) — chain dims end-to-start
    /// along one shared dimension-line level (a running, in-line chain).
    case continueDim
    // --- Wire-wave (image) tool (wired into the UI in this wave) ---
    /// The Image (raster reference) draw tool (`ImageTool`) — place a reference to an
    /// image FILE by clicking a lower-left corner then a bottom-edge corner (size +
    /// rotation). The file path + source pixel size are chosen up front via a
    /// file-picker (the app presents `NSOpenPanel`, reads the pixel size, and pushes
    /// path + pixel size onto the minted tool through `CanvasModel.applyToolConfig`).
    case image
    // --- Wire-wave-1 (paper space) OUT-OF-BAND kind ---
    /// The paper-space Viewport placement mode (`ViewportTool`) — a 2-click drag on a
    /// layout sheet that creates a `LayoutViewport` framing the model. Unlike every
    /// other kind, `.viewport` is NOT backed by a `Tool` conformer (`makeTool()`
    /// returns `nil`, like `.select`): `ViewportTool` is a STANDALONE value type whose
    /// result (`LayoutViewport`) lives in `Layout.viewports`, off `EntityKind`, so it
    /// cannot flow through `ToolEdit`. The app drives its 2-click flow OUT OF BAND in
    /// `CanvasModel` and routes the finished viewport to `CADDrawing.addViewport`. Only
    /// meaningful in PAPER space with an active layout (a no-op in model space).
    case viewport
    // --- Parity-program W2 tool (built UNWIRED; surfaced in a later wire-wave) ---
    /// The Revision Cloud markup tool (`RevisionCloudTool`) — click a path, commit
    /// ONE closed `.polyline` whose every segment is a fixed outward-bowing arc
    /// (the AutoCAD REVCLOUD scallop). No new `EntityKind` — it reuses `.polyline`.
    case revcloud
    /// The Line Construction tool (`LineConstructionTool`) — draw a plain `.line`
    /// constrained against existing geometry (perpendicular foot, parallel-through,
    /// angle bisector, point→circle tangent, orth-tangent). No new `EntityKind`; it
    /// reuses `.line`. Built UNWIRED — the construction-MODE picker is a later wave.
    case lineConstruction
    // --- Parity-program W3 tool (the ONE new-EntityKind tool; built minimally
    //     wired since EntityKind.wipeout's exhaustive switches are inseparable) ---
    /// The Wipeout tool (`WipeoutTool`) — click a polygon boundary, commit ONE
    /// closed `.wipeout` masking region that paints the canvas background color over
    /// lower-draw-order entities (the AutoCAD WIPEOUT). This is the ONE tool whose
    /// committed entity is the new `EntityKind.wipeout`.
    case wipeout
    // --- Parity-program W (new-EntityKind reuse) tool (built UNWIRED) ---
    /// The Multiline draw tool (`MLineTool`) — click path vertices, commit ONE
    /// `.mline` drawn as N parallel mitered element lines (the AutoCAD MLINE). Reuses
    /// the existing `EntityKind.mline`; built UNWIRED (surfaced in a later wire-wave).
    case mline
    // --- Wire-wave-1 (tables) tool ---
    /// The Table insert tool (`TableTool`) — click ONE point to place a DEFAULT empty
    /// `rows × cols` grid (the AutoCAD TABLE). A table is NOT an `EntityKind` (it lives
    /// in `CADDrawing.tables`, off the enum), so this tool records a `TableObject`
    /// REQUEST the app applies via the undoable `CADDrawing.addTable` (the same
    /// non-`ToolEdit` request/apply path `.createBlock` uses for the block table).
    case table
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
        case .xline:           return "Construction Line"
        case .ray:             return "Ray"
        case .align:           return "Align"
        case .arrayPath:       return "Array Along Path"
        case .leader:          return "Leader"
        case .multileader:     return "Multileader"
        case .baselineDim:     return "Baseline Dimension"
        case .continueDim:     return "Continue Dimension"
        case .image:           return "Image"
        case .viewport:        return "Viewport"
        case .revcloud:        return "Revision Cloud"
        case .lineConstruction: return "Line Construction"
        case .wipeout:         return "Wipeout"
        case .mline:           return "Multiline"
        case .table:           return "Table"
        // Append a title arm per new case.
        }
    }

    /// Mints a fresh `Tool` value for this kind, or `nil` for `.select` (which is
    /// not a `Tool` — it is the app's built-in select/pan mode). The app calls
    /// this when the active kind changes.
    ///
    /// Wave 7 — DI: this now DELEGATES to `ToolRegistry.shared` (registration,
    /// not an exhaustive switch). The switch below is the FALLBACK that seeds
    /// the registry's defaults (see `ToolRegistry.registerDefaults()`); adding a
    /// tool = register in one place (the registry), not N switches across
    /// `ToolKind`/`CommandPalette`/`ToolCatalog`. The delegation keeps existing
    /// call sites (`kind.makeTool()`) working while the UI can inject a custom
    /// registry (`CommandRegistry.commands(_:registry:)`).
    public func makeTool() -> (any Tool)? {
        ToolRegistry.shared.makeTool(for: self)
    }

    /// DI overload: mint via an explicit registry (injected by the UI/tests).
    /// Lets a caller supply a bespoke registry (e.g. a test double) without
    /// touching `shared`.
    public func makeTool(using registry: ToolRegistry) -> (any Tool)? {
        registry.makeTool(for: self)
    }
}
