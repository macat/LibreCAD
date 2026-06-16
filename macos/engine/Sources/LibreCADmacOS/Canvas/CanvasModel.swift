//
//  CanvasModel.swift
//  LibreCADmacOS
//
//  The main-actor canvas state shared between SwiftUI, the interaction layer
//  (CADCanvasView), and the Metal renderer. It owns:
//    - the engine `CADDrawing` (the model),
//    - the `Viewport` (matrix-only pan/zoom; ADR-003),
//    - the shared `Quadtree` (culling + snapping, rendering-performance.md §2.2),
//    - the current `Selection` and the latest `SnapResult` + cursor world point.
//
//  Per ADR-003 / rendering-performance.md §4.5 everything here is `@MainActor`:
//  the MTKView delegate callbacks, snapping, and hit-testing all run on the main
//  actor, so there is no cross-actor sharing of the (non-Sendable) `Quadtree`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import Observation
import CADEngine

// MARK: - Paper-space layout math (PURE, GPU-/view-free, unit-tested)

/// The pure, side-effect-free helpers the paper-space UI (P2) needs: partitioning
/// entities by the space currently on screen, deriving a layout's paper sheet
/// rectangle (and its printable/margin border) from the engine `PageDescriptor`,
/// and fitting the camera to a sheet. They take only value types (no `CanvasModel`,
/// no `Viewport` mutation, no Metal) so the whole "which entities render / where is
/// the sheet / how does the camera frame it" contract is testable headlessly
/// (`PaperSpaceUITests`).
///
/// ## Coordinate convention for the sheet
/// A `PageDescriptor` is paper geometry in MILLIMETERS. The sheet is placed in
/// model-world units with its LOWER-LEFT corner at the origin `(0, 0)` and extends
/// to `(widthMM, heightMM)` — i.e. paper millimeters map 1:1 to world units on the
/// layout (the AutoCAD paper-space convention: 1 paper unit == 1 mm). Viewports
/// (which scale model geometry onto the sheet) are a later phase (P3); here the
/// sheet is just a rectangle the camera frames and the renderer outlines.
enum PaperSpaceLayout {

    /// The subset of `entities` that belongs on screen for the given active space.
    ///
    /// - `.model`: every model-space record (`space == .model`). Paper-space records
    ///   are hidden (they live on a sheet, not in the world).
    /// - `.paper`: only the records on the NAMED active layout — `space == .paper`
    ///   AND `layoutName` matching `layoutName` (case-insensitively, mirroring the
    ///   engine's case-insensitive LAYOUT names). A `nil` `layoutName` (no active
    ///   layout) yields nothing on a paper space.
    ///
    /// Pure filter over a value snapshot — the single source of truth for both the
    /// quadtree rebuild (snapping/selection) and the render pack.
    static func entities(
        in entities: [EntityRecord],
        space: EntitySpace,
        layoutName: String?
    ) -> [EntityRecord] {
        entities.filter { isInActiveSpace($0, space: space, layoutName: layoutName) }
    }

    /// Whether one record belongs in the given active space — the per-entity form of
    /// `entities(in:space:layoutName:)`, so the renderer's pack loop and the array
    /// filter share ONE predicate (no drift between "what's indexed" and "what's
    /// drawn"). Model space ⇒ model records; a named layout ⇒ paper records on that
    /// (case-insensitive) layout; a blank/nil layout on paper ⇒ nothing.
    static func isInActiveSpace(
        _ record: EntityRecord,
        space: EntitySpace,
        layoutName: String?
    ) -> Bool {
        switch space {
        case .model:
            return record.space == .model
        case .paper:
            guard let layoutName, !layoutName.isEmpty else { return false }
            return record.space == .paper
                && (record.layoutName?.caseInsensitiveCompare(layoutName) == .orderedSame)
        }
    }

    /// The paper sheet rectangle in world units (mm) for a page: lower-left at the
    /// origin, extending to `(widthMM, heightMM)`. A non-positive / non-finite
    /// dimension collapses that axis to 0, so the rect is always valid (never NaN);
    /// a fully-degenerate page yields a zero-size box at the origin.
    static func sheetRect(for page: PageDescriptor) -> AABB {
        let w = (page.widthMM.isFinite && page.widthMM > 0) ? page.widthMM : 0
        let h = (page.heightMM.isFinite && page.heightMM > 0) ? page.heightMM : 0
        return AABB(min: Vector(0, 0), max: Vector(w, h))
    }

    /// The printable-area (margin) rectangle: the sheet inset by `marginMM` on every
    /// edge. The inset is clamped so it never inverts the rect — a margin at least
    /// half the smaller dimension collapses the printable area to a centered zero-
    /// width/height line rather than a negative box. A non-positive / non-finite
    /// margin returns the full sheet rect (no border inset).
    static func marginRect(for page: PageDescriptor) -> AABB {
        let sheet = sheetRect(for: page)
        guard page.marginMM.isFinite, page.marginMM > 0, !sheet.isEmpty else { return sheet }
        let w = sheet.size.x
        let h = sheet.size.y
        // Clamp the inset so left<=right and bottom<=top (a huge margin collapses to
        // the sheet center, not an inverted box).
        let mx = Swift.min(page.marginMM, w * 0.5)
        let my = Swift.min(page.marginMM, h * 0.5)
        return AABB(
            min: Vector(sheet.min.x + mx, sheet.min.y + my),
            max: Vector(sheet.max.x - mx, sheet.max.y - my)
        )
    }

    /// A viewport that frames a layout's paper sheet in the given view size — the
    /// camera re-frame applied when a layout becomes active. Builds the sheet rect
    /// from the page and delegates to the shared `Viewport.fit` (which centers it
    /// with a padding margin and is robust to a degenerate sheet). Pure: returns a
    /// new `Viewport`, mutating nothing.
    static func cameraFit(for page: PageDescriptor, in size: CGSize) -> Viewport {
        Viewport.fit(sheetRect(for: page), in: size)
    }
}

/// Observable canvas state. SwiftUI observes `entityCount`/`cursorWorld` for the
/// HUD; the renderer reads `drawing`/`viewport`/`quadtree`/`selection`/`snap`.
@MainActor
@Observable
final class CanvasModel {

    // MARK: Model + view state

    /// The engine drawing (entities + layers). Replaced wholesale on File>Open /
    /// the launch load; mutated in place by edits (none yet in this gate).
    var drawing: CADDrawing

    /// The viewport transform. Pan/zoom mutate ONLY this (matrix-only; the f32
    /// instance buffers are never rebuilt for a view change — ADR-003).
    var viewport: Viewport

    // MARK: Active space (paper-space P2 — Model / Layout tab)

    /// Which space is currently ON SCREEN — model (the implicit world drawing, the
    /// default) or paper (a layout sheet). The renderer packs only this space's
    /// entities, the quadtree indexes only them (so snapping/selection are scoped),
    /// and — for paper — the sheet rectangle + margin border are drawn. Defaults to
    /// `.model` so nothing changes until the user picks a Layout tab. Observed so the
    /// tab strip + chrome reflect the active space live. Purely a live VIEW policy
    /// (which space the canvas shows) — not document content, so not undoable.
    private(set) var activeSpace: EntitySpace = .model

    /// WHICH layout is active when `activeSpace == .paper` — the `Layout.name` whose
    /// sheet is on screen. `nil` in model space. The render filter / quadtree scope
    /// key off this so only the named layout's paper-space entities participate.
    private(set) var activeLayout: String?

    /// The shared spatial index over entity AABBs (culling + snapping). Rebuilt
    /// when the model is replaced; incrementally updated on edits.
    @ObservationIgnored
    var quadtree = Quadtree()

    /// The current selection (toggled by click → hitTest).
    var selection = Selection()

    /// Whether anything is currently selected — the gate the "Create Block from
    /// Selection…" command (WAVE BW, Ask #1) and the context menu read (the verb is
    /// meaningless with nothing selected). A thin, observed accessor over `selection`.
    var hasSelection: Bool { !selection.isEmpty }

    /// The latest snap result under the cursor (drives the snap marker overlay).
    var snap: SnapResult?

    /// The cursor's world position (for the coordinate HUD). `nil` when outside.
    var cursorWorld: Vector?

    /// The per-view f64 floating origin the f32 instance buffers are relative to
    /// (ADR-003). Chosen near the drawing centroid when a model loads so f32
    /// offsets stay small.
    @ObservationIgnored
    var renderOrigin: Vector = Vector(0, 0)

    /// Whether the GPU model buffer needs a rebuild (set on model replace/edit;
    /// cleared by the renderer after it rebuilds). View changes do NOT set this.
    @ObservationIgnored
    var modelDirty = true

    /// Bumped whenever the model is replaced, so the renderer (which holds a
    /// snapshot reference) can detect "new model" cheaply.
    @ObservationIgnored
    var modelVersion = 0

    /// Enabled snap modes. The *interactive* default deliberately OMITS `.grid`:
    /// with grid-snap on, a click in empty space rounds the cursor's world point to
    /// the nearest grid node (up to the 8-pt aperture away), so a drawn line lands
    /// with a small visible offset FROM the cursor — the reported "cursor↔point
    /// offset" bug. The transform is exact (ViewportTests round-trip); the offset
    /// was grid-snap moving the click. We keep the geometry snaps (endpoint/center/
    /// middle/intersection/onEntity) so clicks still bind to real geometry, and
    /// `.free` as the always-available fallback so an empty-area click lands EXACTLY
    /// under the cursor. The grid is still drawn as a visual guide. (Engine
    /// `SnapMode.standard` is unchanged; this is the app-level interactive policy.)
    ///
    /// Now OBSERVED (was `@ObservationIgnored`) so the Inspector's snap-mode toggles
    /// both reflect and drive this live; `updateSnap` reads it on every cursor event.
    var snapModes: SnapMode = [.endpoint, .center, .middle, .intersection, .onEntity, .free]

    /// The positive object-snap bits remembered when the master "Object Snap"
    /// toggle is switched OFF, so flipping it back ON restores the user's exact
    /// prior selection (AutoCAD OSNAP / F3). This is ONLY a remembered mask — the
    /// live modes always stay in `snapModes` (the single source of truth, persisted
    /// via `$LC_SNAPMODE`); the stash never holds the non-object `.free`/`.grid`
    /// bits. Empty when the master is currently ON (nothing is stashed).
    @ObservationIgnored
    var stashedObjectSnapModes: SnapMode = []

    /// Whether the grid is drawn / used as a visual guide. The live grid SPACING is
    /// owned by the renderer (passed into `updateSnap` per event); this is the
    /// user-facing on/off the Inspector toggles. (Render-side consumption of this
    /// flag is owned by the canvas/renderer; wired here additively so the Inspector
    /// has a single source of truth for the toggle.)
    var gridVisible: Bool = true

    /// The user's preferred grid spacing (world units), surfaced by the Inspector.
    /// The renderer currently computes its own adaptive spacing and passes it into
    /// `updateSnap`; this stored preference is the Inspector's editable value (full
    /// renderer adoption is owned by the canvas agent — see the report).
    var preferredGridSpacing: Double = 1.0

    /// Whether ORTHO restriction is on (LibreCAD's Ortho mode, AutoCAD F8). When on,
    /// a draw tool's candidate point is locked to the horizontal/vertical axis through
    /// the last placed point (`relativeZero`) before the tool receives it. This is the
    /// PERSISTENT toggle (View ▸ Ortho / status bar); the canvas ALSO honors a
    /// transient hold-⇧ override during point input (see `CADCanvasView`), so the
    /// *effective* ortho state at a given click is `orthoEnabled XOR shiftHeld`.
    /// Observed so the menu checkmark + status-bar chip track it live. Purely a live
    /// interaction policy (not persisted to the document — it is a drafting aid, like
    /// the cursor mode, not drawing content).
    var orthoEnabled: Bool = false

    /// The CURRENT drawing pen — AutoCAD's CECOLOR / CELTYPE / CELWEIGHT trio
    /// (color / line type / line width). NEW geometry drawn by a tool adopts this
    /// pen (and the active layer) when the freshly-committed record still carries the
    /// init defaults — see the stamp in `applyCommit`'s `.add` arm. Defaults to a
    /// fully `.byLayer` pen, so out of the box a drawn entity inherits everything from
    /// its layer (the LibreCAD/AutoCAD default). The top-bar current-properties
    /// control and (indirectly) the Inspector bind to this; it is a live drafting
    /// policy, not document content, so it is not undoable and not persisted.
    var currentPen: Pen = .byLayer

    /// The grid step (world units) last seen via `updateSnap`/`snappedWorldPoint`.
    /// The renderer owns the live grid spacing and the canvas view passes it down
    /// on every cursor event; we cache the latest here so `handleToolInput` can put
    /// it in the `ToolContext` without threading it through every call site. `nil`
    /// until the first snap (or when the grid is off).
    @ObservationIgnored
    private var lastGridSpacing: Double?

    // MARK: Tool state

    /// The active interaction mode: `.select` (default click-to-select / pan) or a
    /// concrete draw tool. Set via `activateTool(_:)` so the live `tool` value is
    /// kept in sync; observed by the HUD/toolbar for the active-tool indicator.
    private(set) var activeToolKind: ToolKind = .select

    /// The live tool value for `activeToolKind`, or `nil` in `.select` mode. A
    /// value type the model owns; canvas events are forwarded to it via
    /// `handleToolInput(_:)`. `@ObservationIgnored` because its mutation is driven
    /// through explicit methods that also publish the HUD-visible derived state.
    @ObservationIgnored
    private(set) var tool: (any Tool)?

    /// The tool's current prompt for the status HUD ("Specify first point" …), or
    /// empty in select mode. Republished on every tool input so SwiftUI updates.
    private(set) var toolStatus: String = ""

    /// The "relative-zero" — by default the last point the active tool actually
    /// PLACED (clicked or typed), the origin that the command line's `@dx,dy`, polar
    /// `dist<angle`, and bare-distance input are measured from (UX-plan U1 / G7).
    /// Updated by `handleToolInput` on every valid `.click`/`.value` so a typed
    /// `@10,0` is relative to wherever the previous point landed — UNLESS the user has
    /// LOCKED it (`relativeZeroLocked`), in which case it stays fixed at the chosen
    /// datum and does NOT auto-advance. Unlocked, it is reset to `nil` when the run
    /// ends (commit/cancel → `.finished`) or the tool changes, so the first point of a
    /// fresh run has no stale reference; locked, it survives those transitions (a
    /// persistent datum, LibreCAD's "Set relative zero" workflow). Observed so the
    /// command field / status bar can show/draw it.
    private(set) var relativeZero: Vector?

    /// Whether the relative-zero is LOCKED at a user-chosen datum (LibreCAD's "Lock
    /// relative zero"). When locked, `relativeZero` does NOT auto-advance to the last
    /// placed point and is NOT cleared on run-end / tool-change — it stays where it was
    /// set so the user can measure/draw multiple things relative to one fixed origin.
    /// When unlocked, the default auto-follow-the-last-point behavior resumes. Purely a
    /// live drafting aid (not persisted to the document, like ortho / the cursor mode).
    /// Observed so the menu state + a status chip can track it live.
    private(set) var relativeZeroLocked: Bool = false

    /// Whether the canvas is armed for a one-shot "Set Relative Origin" pick: the NEXT
    /// snapped canvas click (in select mode) sets `relativeZero` to that point instead
    /// of toggling selection, then auto-disarms (mirrors the Zoom-Window one-shot arm).
    /// The existing select-mode click path (`toggleSelection`) consults this first, so
    /// no change to the canvas view is needed. Observed so a status chip / the cursor
    /// can reflect the armed "pick a point" state.
    private(set) var settingRelativeZeroArmed: Bool = false

    /// The most recent error from a command-line submission (`submitCommandText`),
    /// or `nil` after a successful submit. The command field echoes it so a typo
    /// like `1,,2` shows "Expected x,y" instead of silently doing nothing.
    private(set) var lastCommandError: String?

    // MARK: Command bar state (the bottom AutoCAD-style tool launcher)

    /// The live text typed into the bottom command BAR's tool-filter field. While
    /// empty the bar shows the adaptive default chip set; as it fills, the chips
    /// narrow to the fuzzy matches (see `ToolSuggester`). Distinct from the
    /// coordinate/command-line text the view owns for `submitCommandText` — this one
    /// drives ONLY the tool-launcher filter (Phase 1). Observed so the chip row
    /// recomputes as the user types.
    var commandBarQuery: String = ""

    /// The most-recently-used tools, MOST-RECENT FIRST, that bias the adaptive chip
    /// set toward the user's habits. Seeded from `@AppStorage` by the view on appear
    /// and re-persisted by it whenever this changes (the persistence lives in the
    /// view because `@AppStorage` is a SwiftUI-only wrapper); the LIST and its
    /// promote-on-use logic live here (via the pure `ToolSuggester.updatedMRU`) so the
    /// "activation updates MRU" behavior is unit-testable on the model. Observed so
    /// the chip row reflects a freshly-used tool.
    var commandBarMRU: [ToolKind] = []

    /// The ordered tools the command bar should show as chips right now — the pure
    /// `ToolSuggester` applied to the live query. Wave 4 de-mirror: an EMPTY query
    /// returns NO chips (the bar shows a prompt hint + a labeled Recent row instead —
    /// see `commandBarRecents(pinned:)`); only a non-empty query yields fuzzy-match
    /// chips. A derived, side-effect-free read the chip row binds to.
    var commandBarSuggestions: [ToolKind] {
        ToolSuggester.suggestions(
            query: commandBarQuery,
            hasSelection: !selection.isEmpty,
            mru: commandBarMRU
        )
    }

    /// The most-recently-used tools to surface as a clearly-LABELED "Recent" row when
    /// the query is empty (the de-mirror replacement for the dropped static chip set).
    /// Excludes the tools already PINNED to the toolbar so the row never duplicates a
    /// button the user already has. Pure read over the MRU + the pure `ToolSuggester`.
    func commandBarRecents(pinned: Set<ToolKind>) -> [ToolKind] {
        ToolSuggester.recents(mru: commandBarMRU, excluding: pinned)
    }

    /// The top-ranked suggestion for the current query — what ⏎ activates. `nil` when
    /// the query is empty (⏎ on an empty launcher does nothing) or nothing matches.
    var commandBarTopMatch: ToolKind? {
        let trimmed = commandBarQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return commandBarSuggestions.first
    }

    // MARK: Selection interaction state (UX-plan U5 — marquee + hover)

    /// The entity currently UNDER the cursor in select mode (the hover-highlight
    /// pre-selection affordance, U5/gap G8). `nil` when nothing is under the cursor,
    /// a tool is active, or the cursor is outside. The hover overlay reads this; the
    /// canvas refreshes it on `mouseMoved` via `updateHover`. Kept distinct from
    /// `selection` so the highlight color can differ from the selected color.
    @ObservationIgnored
    private(set) var hoverID: EntityID?

    /// The live rubber-band marquee rectangle in WORLD coordinates while the user is
    /// dragging a selection box on empty space (U5/gap G8), or `nil` when no marquee
    /// is in progress. The marquee overlay reads this (with `marqueeCrossing`) to draw
    /// the box; the canvas sets it on drag and clears it on mouse-up.
    @ObservationIgnored
    private(set) var marqueeRect: AABB?

    /// Whether the in-progress marquee is a CROSSING box (right→left drag, green,
    /// dashed — selects any touched entity) vs a WINDOW box (left→right drag, blue,
    /// solid — selects only fully-enclosed entities). Only meaningful while
    /// `marqueeRect != nil`.
    @ObservationIgnored
    private(set) var marqueeCrossing: Bool = false

    /// The in-app entity clipboard (UX-plan U5 — Cut/Copy/Paste/Duplicate). Holds a
    /// value snapshot of copied records; paste re-mints ids + offsets the geometry
    /// through the pure engine `EntityClipboard`. One per window (per model).
    @ObservationIgnored
    private var clipboard = EntityClipboard()

    // MARK: Tool config (the parameterized tools' "options", surfaced by the Inspector)

    /// Editable defaults for the parameterized tools. These tools (`FilletTool`,
    /// `ChamferTool`, `ArrayTool`, `DivideTool`) carry their parameters as public
    /// `var`s but `ToolKind.makeTool()` mints them with fixed defaults; the
    /// Inspector edits the values here and `activateTool` / the run-restart in
    /// `handleToolInput` apply them onto the freshly-minted tool (see
    /// `applyToolConfig()`), so an option set in the Inspector flows into the tool
    /// no matter how it is activated (toolbar, menu, or keyboard).
    var filletRadius: Double = 10.0
    var chamferDistance1: Double = 10.0
    var chamferDistance2: Double = 10.0

    /// Array tool options. `arrayPolar == false` is a rectangular grid
    /// (`arrayRows` × `arrayCols` stepped by `(arraySpacingX, arraySpacingY)`);
    /// `true` is a polar ring of `arrayPolarCount` over `arrayPolarTotalAngle`.
    var arrayPolar: Bool = false
    var arrayRows: Int = 2
    var arrayCols: Int = 3
    var arraySpacingX: Double = 10.0
    var arraySpacingY: Double = 10.0
    var arrayPolarCount: Int = 6
    /// Total polar sweep in radians (default a full circle).
    var arrayPolarTotalAngle: Double = 2 * .pi
    var arrayPolarRotateItems: Bool = true

    /// Divide tool: number of equal pieces (drops `count − 1` division points).
    var divideCount: Int = 2

    // MARK: Draw-tool options (NEW — UX-plan U2, surfaced by the Tool Options bar)

    /// Polygon tool: number of sides (clamped ≥ 3 by the tool) and whether the
    /// polygon is inscribed in (default) or circumscribed about the reference circle.
    var polygonSides: Int = 6
    var polygonFit: PolygonFit = .inscribed

    /// Polygon tool: which construction MODE the two clicks define. Stored as the
    /// case index + the star-ratio scalar separately (an enum-with-associated-value
    /// doesn't bind cleanly to a segmented control), and assembled into
    /// `PolygonMode` in `applyToolConfig`. 0 = center→corner (default), 1 = edge,
    /// 2 = star (uses `polygonStarRatio`, clamped to (0,1) by the tool's geometry).
    var polygonModeStyle: Int = 0
    var polygonStarRatio: Double = 0.5

    /// Rectangle tool: an optional EXACT width/height. When BOTH are set (> 0) a
    /// single click drops a rectangle of that size; `nil`/0 keeps the two-corner
    /// drag. Stored as `Double` (0 ⇒ "unset") so the bar binds a plain numeric field;
    /// `applyToolConfig` maps 0 → `nil` on the tool.
    var rectWidth: Double = 0
    var rectHeight: Double = 0

    /// Rectangle tool: the CORNER treatment. Stored as the case index + the cut
    /// scalar separately (an enum-with-associated-value doesn't bind to a segmented
    /// control), assembled into `RectangleCorner` in `applyToolConfig`. 0 = square
    /// (default), 1 = rounded(radius:), 2 = chamfer(distance:); `rectCornerSize` is
    /// the radius/distance used by modes 1 and 2.
    var rectCornerStyle: Int = 0
    var rectCornerSize: Double = 10.0

    /// Ellipse tool: the construction MODE, stored as a case INDEX (the engine
    /// `EllipseTool.Mode` is `Equatable` but not `Hashable`, so it can't be a SwiftUI
    /// Picker tag — the index is the UI-simple binding the brief prescribes).
    /// `EllipseTool.mode` is fixed at construction (it seeds the start state), so
    /// `applyToolConfig` RE-MINTS the tool with `ellipseModeValue` (the DivideTool/
    /// ArcTool pattern). 0 = axis (default), 1 = foci+point, 2 = 4-point, 3 = inscribe,
    /// 4 = elliptic arc.
    var ellipseModeIndex: Int = 0

    /// The `EllipseTool.Mode` for the current `ellipseModeIndex` (assembled here so
    /// `applyToolConfig` and the tests share one mapping).
    var ellipseModeValue: EllipseTool.Mode {
        switch ellipseModeIndex {
        case 1:  return .fociPoint
        case 2:  return .fourPoint
        case 3:  return .inscribeQuad
        case 4:  return .arc
        default: return .axis
        }
    }

    /// Trim tool: which trim MODE is active, stored as a case INDEX (the engine
    /// `TrimTool.Mode` is `Equatable` but not `Hashable`, so it can't be a Picker tag).
    /// 0 = boundary (the single-click cut-to-boundary default — the ONLY mode
    /// `TrimTool.handle` drives end-to-end), 1 = amount (a signed distance via the PURE
    /// static `TrimTool.trimAmount`), 2 = mutual (`TrimTool.mutualTrim`). The `.amount`
    /// / `.mutual` variants are NOT dispatched from `handle` yet (engine gap — see the
    /// report); the options bar surfaces them + a signed amount for when the
    /// interaction path is plumbed. `trimAmount` is the distance used by `.amount`.
    var trimModeIndex: Int = 0
    var trimAmount: Double = 10.0

    /// The `TrimTool.Mode` for the current `trimModeIndex`.
    var trimModeValue: TrimTool.Mode {
        switch trimModeIndex {
        case 1:  return .amount
        case 2:  return .mutual
        default: return .boundary
        }
    }

    /// Image tool: the chosen image file path + its source pixel size (read from the
    /// file by the app's file-picker via `NSImage`). `ToolKind.makeTool()` mints a
    /// bare (inert) `ImageTool`; `applyToolConfig` RE-MINTS it with these so the placed
    /// image references the file and keeps its pixel aspect. `nil`/0 ⇒ no file chosen
    /// (the tool is a no-op until the picker provides one).
    var imagePath: String?
    var imagePixelWidth: Double = 1
    var imagePixelHeight: Double = 1

    /// The display name of the chosen image file (for the options bar readout), or
    /// `nil` when no file is chosen. Derived from `imagePath`'s last path component.
    var imageFileName: String? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        return (imagePath as NSString).lastPathComponent
    }

    /// Create-Block tool (WAVE BW, Ask #1): the block name the next `CreateBlockTool`
    /// run uses, supplied by the View-layer name sheet (`BlockNamePrompt`) before it
    /// activates `.createBlock`. `ToolKind.makeTool()` mints a `CreateBlockTool` with
    /// the default "Block" name; `applyToolConfig` RE-MINTS it with this so the new
    /// block carries the user's chosen name. `nil`/empty ⇒ the default name (the model
    /// op de-duplicates on a clash, so a default is always safe). Set via
    /// `beginCreateBlock(name:)`.
    var pendingCreateBlockName: String?

    /// Insert tool (WAVE BW, Ask #3 optional): the block name the next `InsertTool`
    /// run places, supplied by the View-layer block-picker before it activates
    /// `.insert`. `ToolKind.makeTool()` mints a bare (inert) `InsertTool`;
    /// `applyToolConfig` RE-MINTS it with this name + the block's member snapshot (for
    /// the rubber-band preview). `nil`/empty ⇒ inert (the picker sets it first). Set
    /// via `beginInsert(name:)`.
    var pendingInsertBlockName: String?

    // MARK: Insert tool placement options (Tool Options bar — INSERT scale / rotation / array)

    /// Insert tool: whether the placement scale is UNIFORM (one factor applied to both
    /// axes) or independent per-axis. When uniform, `insertScaleX` is the single factor
    /// and `insertScaleY` is ignored (mirrored into the assembled `Vector`). Default
    /// uniform ⇒ the current behavior (no per-axis distortion).
    var insertScaleUniform: Bool = true
    /// Insert tool: the X placement scale (the single factor when uniform). Default 1.
    var insertScaleX: Double = 1
    /// Insert tool: the Y placement scale (used only when `insertScaleUniform == false`).
    /// Default 1.
    var insertScaleY: Double = 1
    /// Insert tool: the placement ROTATION (RADIANS, CCW). The options bar edits a
    /// friendlier degrees value over this (mirroring the Line/Array angle fields).
    /// Default 0 ⇒ unrotated.
    var insertRotation: Double = 0
    /// Insert tool: the MINSERT rectangular array — rows × cols and their spacing
    /// (world units). Default 1×1 with zero spacing ⇒ a plain single insert (current
    /// behavior). `applyToolConfig` clamps rows/cols to ≥ 1 (the tool clamps too).
    var insertRows: Int = 1
    var insertCols: Int = 1
    var insertRowSpacing: Double = 0
    var insertColSpacing: Double = 0

    /// Assembles the Insert tool's placement `scale` from the split UI state
    /// (`insertScaleUniform` + `insertScaleX` / `insertScaleY`). The single mapping the
    /// live tool + the wiring test share, so the options bar and `applyToolConfig` never
    /// drift. Uniform ⇒ `(X, X)`; per-axis ⇒ `(X, Y)`.
    var insertScaleValue: Vector {
        insertScaleUniform ? Vector(insertScaleX, insertScaleX)
                           : Vector(insertScaleX, insertScaleY)
    }

    /// Circle tool: whether numeric size entry is a radius (default) or diameter, and
    /// an optional EXACT size (0 ⇒ unset → two-click center+radius).
    var circleSizeMode: CircleSizeMode = .radius
    var circleFixedSize: Double = 0

    /// Circle tool: the geometric CONSTRUCTION mode (center+radius default, 2-point
    /// diameter, or 3-point circumcircle). Fixed at construction (it seeds the start
    /// state), so `applyToolConfig` RE-MINTS the tool with this mode (the DivideTool/
    /// ArcTool pattern). The default `.centerRadius` keeps the original two-click flow.
    var circleConstructionMode: CircleConstructionMode = .centerRadius

    /// Arc tool: the construction mode (center→start→end default, 3-point, or
    /// tangential — start tangent to a picked edge).
    var arcMode: ArcCreationMode = .centerStartEnd

    /// Line tool: the angle-constraint mode, split into a UI-simple case INDEX +
    /// an angle scalar (the same split the Polygon/Rectangle/Ellipse/Trim pickers
    /// use, since `LineAngleMode` carries an associated value and isn't a Picker tag).
    /// 0 = free (default — back-compatible), 1 = absolute, 2 = relative. `applyToolConfig`
    /// assembles `LineAngleMode` from this index + `lineAngle` (radians).
    var lineAngleModeIndex: Int = 0
    /// Line tool: the constraint angle (RADIANS, CCW from +X) used by the absolute /
    /// relative angle modes. The options bar edits a friendlier degrees value over this.
    var lineAngle: Double = 0

    /// Assembles the Line tool's `LineAngleMode` from the split UI state
    /// (`lineAngleModeIndex` + `lineAngle`). The single mapping the live tool +
    /// the wiring test share, so the options bar and `applyToolConfig` never drift.
    var lineAngleModeValue: LineAngleMode {
        switch lineAngleModeIndex {
        case 1:  return .absolute(lineAngle)
        case 2:  return .relative(lineAngle)
        default: return .free
        }
    }

    /// Point tool: the on-screen marker style for placed points.
    var pointStyle: PointStyle = .dot

    /// Text tool: the default cap height (world units) new text is authored at.
    var textHeight: Double = TextTool.defaultHeight

    // MARK: Wire-wave-3 tool options (surfaced by the Tool Options bar / Inspector)

    /// Align tool: whether the align map uniformly scales the selection so the source
    /// segment's length matches the destination segment's (the AutoCAD default), vs a
    /// rotate-only map that preserves size. `applyToolConfig` pushes it onto `AlignTool`.
    var alignScaleToFit: Bool = true

    /// Array-along-path tool: how many copies to distribute along the picked path, and
    /// whether each copy is rotated to the local path tangent (vs axis-aligned).
    /// `applyToolConfig` maps these onto `ArrayPathTool.Config`.
    var arrayPathCount: Int = 5
    var arrayPathAlignToTangent: Bool = true

    /// Leader tool: the optional attached annotation text (empty ⇒ a bare leader) and
    /// its cap height (world units). `applyToolConfig` pushes them onto `LeaderTool`.
    var leaderText: String = ""
    var leaderTextHeight: Double = 2.5

    /// Baseline dimension tool: the DIMDLI spacing (world units) each successive
    /// dimension line is stepped further out by. `applyToolConfig` maps it onto
    /// `BaselineDimTool.baselineSpacing`.
    var baselineSpacing: Double = BaselineDimTool.defaultBaselineSpacing

    // MARK: Layer defaults (Document Settings — app policy for new layers)

    /// The default color a NEW layer is born with (Document Settings ▸ Layers).
    /// `LayersSidebar.addLayer` seeds a new `Layer` with this. App policy (not a DXF
    /// header var) — new layers are local creation choices, not document round-trip
    /// state. Defaults to LibreCAD green.
    var defaultLayerColor: RGBAColor = .librecadGreen
    /// The default line width a new layer is born with.
    var defaultLineWidth: PenLineWidth = .default
    /// The default line type a new layer is born with.
    var defaultLineType: PenLineType = .solid

    // MARK: Paper defaults (Document Settings — pre-fill Print/Export)

    /// The preferred paper size for Print/Export (app-side default). The paper
    /// insertion base point round-trips via `$PINSBASE`; the size/orientation are
    /// local print defaults stored on the model. Defaults to A4.
    var paperSize: PaperSize = .a4
    /// Whether the preferred paper orientation is landscape (vs portrait).
    var paperLandscape: Bool = false

    // MARK: Derived (for the SwiftUI HUD)

    var entityCount: Int { drawing.count }

    /// Whether a draw tool is active (vs select/pan mode).
    var isToolActive: Bool { activeToolKind != .select }

    /// The window's `UndoManager`. Defaults to a fresh instance the model owns and
    /// injects into the drawing so tool commits register undo (ADR-002); re-injected
    /// on `setDrawing`. Under `DocumentGroup` the view swaps in SwiftUI's environment
    /// `UndoManager` via `adoptUndoManager(_:)` so edits ALSO mark the native
    /// document dirty (and ⌘Z/Revert route through the document) — that is why this
    /// is a `var`, not a `let`. All existing call sites (and the 973 unit tests) keep
    /// the default fresh manager and are unaffected.
    @ObservationIgnored
    private(set) var undoManager = UndoManager()

    /// Swaps in an externally-owned `UndoManager` (SwiftUI's environment manager
    /// under `DocumentGroup`) so drawing mutations register against IT — which is
    /// how the native document learns it is dirty. Idempotent: a no-op if the same
    /// manager is already adopted. Repoints the drawing's `undoManager` (a `weak var`)
    /// and clears the new manager's stack so a freshly-opened document starts clean.
    func adoptUndoManager(_ manager: UndoManager) {
        guard manager !== undoManager else { return }
        undoManager = manager
        drawing.undoManager = manager
        manager.removeAllActions()
    }

    // MARK: Init

    init(drawing: CADDrawing = CADDrawing(), viewSize: CGSize = CGSize(width: 800, height: 600)) {
        self.drawing = drawing
        self.viewport = Viewport(size: viewSize)
        drawing.undoManager = undoManager
        rebuildIndex()
    }

    // MARK: - Model lifecycle

    /// Replaces the model with a freshly-loaded drawing, rebuilds the spatial
    /// index, chooses a floating origin near the content, and frames it (caller
    /// passes the current view size). Marks the GPU buffer dirty.
    func setDrawing(_ newDrawing: CADDrawing, viewSize: CGSize) {
        drawing = newDrawing
        drawing.undoManager = undoManager
        undoManager.removeAllActions()
        // A freshly-loaded drawing always starts in MODEL space (paper-space P2): the
        // prior window's active layout does not carry into a new document, and model
        // space is the safe default that frames + indexes the world drawing below.
        activeSpace = .model
        activeLayout = nil
        // Adopt the document's persisted grid/snap settings into the live model
        // flags so a loaded file (Save→Open) restores the user's grid + snap state
        // (Document Settings round-trip). Header vars are the source of truth.
        loadSettingsFromDrawing()
        rebuildIndex()
        let box = drawing.boundingBox()
        renderOrigin = RendererGeometry.renderOrigin(for: box)
        selection.clear()
        snap = nil
        // Frame the content on first paint (Viewport.fit handles empty/degenerate).
        viewport = Viewport.fit(box, in: viewSize)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Mirrors the drawing's persisted Document-Settings header vars into the live
    /// model flags the renderer/snapper read (`gridVisible`, `preferredGridSpacing`,
    /// `snapModes`). Called on every `setDrawing` so an opened document restores its
    /// grid + snap state. The header vars are the source of truth; this is a one-way
    /// load (the apply* setters below keep the two in sync going forward). Snap modes
    /// load from the private `$LC_SNAPMODE` var only if it was persisted (decision
    /// D5); otherwise the built-in interactive default is kept.
    private func loadSettingsFromDrawing() {
        gridVisible = drawing.graphicVariables.gridOn
        let spacing = drawing.graphicVariables.gridSpacing
        if spacing > 0 { preferredGridSpacing = spacing }
        if let raw = drawing.graphicVariables.snapModeRaw {
            snapModes = SnapMode(rawValue: UInt16(truncatingIfNeeded: raw))
        }
    }

    /// Rebuilds the quadtree from the per-entity AABBs of the ACTIVE space's entities
    /// (paper-space P2): in model space, every model-space record; on a layout, only
    /// that layout's paper-space records (via the pure `PaperSpaceLayout.entities`).
    /// Scoping the index here is what makes snapping + selection operate ONLY on the
    /// space currently on screen — a model-space line is never snappable while a sheet
    /// is shown, and vice versa. Text uses the TIGHT font-aware box (via the drawing's
    /// ResolveContext) so glyph culling/snapping match the real ink extent; all other
    /// kinds use the analytic box. Called on model replace, on every space switch, and
    /// on edits.
    func rebuildIndex() {
        quadtree.removeAll()
        let ctx = drawing.makeResolveContext()
        let scoped = activeSpaceEntities
        var box = AABB.empty
        for e in scoped { box = box.union(e.boundingBox(ctx: ctx)) }
        if !box.isEmpty { quadtree.reserveWorld(box) }
        for e in scoped {
            let b = e.boundingBox(ctx: ctx)
            if !b.isEmpty { quadtree.insert(e.id, bounds: b) }
        }
    }

    /// The entities of the ACTIVE space — the single subset both the index rebuild and
    /// the renderer's pack key off (the pure `PaperSpaceLayout.entities` filter applied
    /// to the live drawing's records for the current `activeSpace` / `activeLayout`).
    /// Model space (the default) returns the model-space records — identical to the
    /// whole drawing for a drawing with no paper entities, so existing behavior is
    /// preserved.
    ///
    /// During an in-place BLOCK EDIT session (`editingBlock != nil`) this is instead the
    /// block's member records (`editingBlockEntities`), so the index/snapping/selection
    /// — and any renderer that keys off this subset — operate on the block's contents,
    /// exactly the way paper space scopes to a sheet. The scope is restored to the
    /// prior space on `exitBlockEditing`.
    ///
    /// In MODEL space (and NOT in a block-edit session) block-DEFINITION members
    /// (`drawing.blockMemberIDs`) are EXCLUDED: they are geometry owned by a block and
    /// must draw/select ONLY via an `.insert` of the block (or while their block is open
    /// in the Block Editor), never as loose top-level model-space entities. Because this
    /// subset drives the quadtree (→ marquee / hit-test / snap) AND the render pack, the
    /// single exclusion keeps members non-selectable and non-double-rendered. The Block
    /// Editor branch above is untouched (members stay editable inside a session); paper
    /// space carries no block members, so it is unaffected.
    var activeSpaceEntities: [EntityRecord] {
        if editingBlock != nil { return editingBlockEntities }
        let scoped = PaperSpaceLayout.entities(
            in: drawing.entities, space: activeSpace, layoutName: activeLayout)
        guard activeSpace == .model else { return scoped }
        let members = drawing.blockMemberIDs
        guard !members.isEmpty else { return scoped }
        return scoped.filter { !members.contains($0.id) }
    }

    /// The `Layout` currently active (paper space), or `nil` in model space / when the
    /// active name no longer resolves. The renderer reads its `page` to draw the sheet.
    var activeLayoutRecord: Layout? {
        guard activeSpace == .paper, let name = activeLayout else { return nil }
        return drawing.layout(named: name)
    }

    /// The drawing's layouts in tab order (the tab strip's source). Already sorted by
    /// `tabOrder` on the engine side; re-sorted here defensively so the UI never
    /// depends on storage order.
    var orderedLayouts: [Layout] {
        drawing.layouts.sorted { $0.tabOrder < $1.tabOrder }
    }

    // MARK: - Active-space switching (paper-space P2 — Model / Layout tabs)

    /// Switches the canvas to `space` (optionally a named `layoutName` for paper).
    /// On a CHANGE it re-frames the camera (model space → fit the whole model; a
    /// layout → fit its paper sheet), rebuilds the spatial index over ONLY the new
    /// active space's entities (so snapping/selection follow), clears the transient
    /// selection/snap/hover (they referenced the prior space's entities), and marks
    /// the GPU buffer dirty + bumps `modelVersion` so the renderer repacks and the
    /// canvas redraws. A no-op (no work) when the requested space/layout is already
    /// active. Switching to `.paper` with an absent/blank layout name falls back to
    /// model space (there is no sheet to show). Purely a view change — not undoable.
    func setActiveSpace(_ space: EntitySpace, layoutName: String? = nil) {
        // Resolve the request: paper needs a real, existing layout; otherwise model.
        let resolvedSpace: EntitySpace
        let resolvedLayout: String?
        if space == .paper, let name = layoutName, drawing.hasLayout(name) {
            // Canonicalize to the stored name's casing so the filter matches exactly.
            resolvedSpace = .paper
            resolvedLayout = drawing.layout(named: name)?.name ?? name
        } else {
            resolvedSpace = .model
            resolvedLayout = nil
        }

        guard resolvedSpace != activeSpace
            || resolvedLayout?.caseInsensitiveCompare(activeLayout ?? "") != .orderedSame
            || (resolvedLayout == nil) != (activeLayout == nil) else {
            return   // already on this space/layout — nothing to do
        }

        activeSpace = resolvedSpace
        activeLayout = resolvedLayout

        // Re-frame the camera to the new space.
        if resolvedSpace == .paper, let page = activeLayoutRecord?.page {
            viewport = PaperSpaceLayout.cameraFit(for: page, in: viewport.size)
        } else {
            viewport = Viewport.fit(modelSpaceBoundingBox, in: viewport.size)
        }
        // Re-home the floating origin near the new content so f32 offsets stay small.
        renderOrigin = RendererGeometry.renderOrigin(for: activeSpaceBoundingBox)

        // Scope the index to the new space; drop transient interaction state that
        // referenced the prior space's entities.
        rebuildIndex()
        selection.clear()
        snap = nil
        hoverID = nil
        modelDirty = true
        modelVersion &+= 1
    }

    /// Activates the named layout's paper sheet (a tab pick). No-op if the layout is
    /// absent. Convenience over `setActiveSpace(.paper, layoutName:)`.
    ///
    /// If a block-edit session is open, picking a Model/Layout tab AUTO Save&Closes it
    /// first (owner decision: switch-away mid-edit keeps the live edits) so the user's
    /// tab pick sticks. `finishBlockEditingIfNeeded` pops every open level, restoring each
    /// level's prior view (`BlockEditSession.priorSpace/priorLayout/priorViewport` — the
    /// space active when that level opened); the subsequent `setActiveSpace` then applies
    /// THIS pick on top — so the pick wins, not the stale prior view. (If the pick equals
    /// the prior view, `setActiveSpace` is a no-op, which is correct: exit already left us
    /// there.)
    func activateLayout(name: String) {
        finishBlockEditingIfNeeded()
        setActiveSpace(.paper, layoutName: name)
    }

    /// Returns to model space (the "Model" tab). Convenience over `setActiveSpace`.
    /// Auto Save&Closes an open block-edit session first (see `activateLayout`).
    func activateModel() {
        finishBlockEditingIfNeeded()
        setActiveSpace(.model)
    }

    /// The bounding box of the ACTIVE space's entities (model or the active layout's
    /// paper entities) — used to re-home the floating origin on a switch.
    private var activeSpaceBoundingBox: AABB {
        var box = AABB.empty
        for e in activeSpaceEntities { box = box.union(e.boundingBox()) }
        return box
    }

    /// The bounding box of only the MODEL-space entities — what model space frames on
    /// a switch back (so a layout's paper geometry never skews the model fit).
    private var modelSpaceBoundingBox: AABB {
        var box = AABB.empty
        for e in drawing.entities where e.space == .model {
            box = box.union(e.boundingBox())
        }
        return box
    }

    /// The MODEL-space extents a newly placed paper-space viewport frames (the whole
    /// model fit). Public so the View layer can seed the `ViewportTool` (which needs
    /// the model AABB to derive the view center + height). Falls back to `.empty`,
    /// which the tool clamps to a unit view at the world origin.
    var modelExtentsForViewport: AABB { modelSpaceBoundingBox }

    // MARK: - Paper-space VIEWPORT placement (OUT-OF-BAND tool — wire-wave-1)
    //
    // `ViewportTool` is a STANDALONE value type (NOT a `Tool` conformer): its result
    // is a `LayoutViewport`, which lives in `Layout.viewports` (off `EntityKind`), so
    // it cannot flow through the frozen `Tool`/`ToolEdit` contract. The app therefore
    // drives the 2-click flow HERE, keyed off `activeToolKind == .viewport`, exactly
    // as the CreateBlock out-of-band path routes through a model op rather than a
    // `ToolEdit`. The tool is ONLY meaningful in PAPER space with an active layout; in
    // model space (or with no layout) the flow is an inert no-op.

    /// The live `ViewportTool` value, owned by the model while `.viewport` is the
    /// active kind. A value type — the mutated copy is stored back after each input.
    /// `nil` when `.viewport` is not active.
    @ObservationIgnored
    private var viewportTool: ViewportTool?

    /// Whether the paper-space viewport-placement mode is BOTH active and meaningful:
    /// the active kind is `.viewport` AND we are in paper space on a real layout.
    /// In model space (or with no active layout) `.viewport` is inert, so the canvas
    /// keeps select-mode behavior.
    var isViewportPlacementActive: Bool {
        activeToolKind == .viewport && activeSpace == .paper && activeLayout != nil
    }

    /// The viewport tool's live rubber-band preview (a closed paper-space polyline),
    /// or empty when not placing. Drives the canvas overlay so the user sees the frame
    /// being dragged. Empty when `.viewport` is inactive / inert.
    var viewportPreview: [ResolvedPolyline] {
        guard isViewportPlacementActive else { return [] }
        return viewportTool?.preview ?? []
    }

    /// Arms / re-arms the `ViewportTool` for the current model extents. Called when
    /// `.viewport` becomes the active kind (and after a placement re-arm) so the
    /// freshly seeded tool frames the CURRENT model. A no-op when `.viewport` is not
    /// the active kind.
    func armViewportTool() {
        guard activeToolKind == .viewport else { viewportTool = nil; return }
        viewportTool = ViewportTool(modelExtents: modelExtentsForViewport)
        toolStatus = viewportTool?.status ?? ""
    }

    /// Feeds the viewport tool a MOVE at a paper-space point (the rubber-band tracks
    /// the cursor). Returns whether the canvas should redraw (the preview changed).
    /// No-op (returns `false`) unless viewport placement is active + meaningful.
    @discardableResult
    func handleViewportMove(_ paperPoint: Vector) -> Bool {
        guard isViewportPlacementActive, viewportTool != nil else { return false }
        let outcome = viewportTool!.handle(.move(paperPoint))
        toolStatus = viewportTool!.status
        switch outcome {
        case .none:    return false
        default:       return true
        }
    }

    /// Feeds the viewport tool a CLICK at a paper-space point. On the second click the
    /// tool yields a finished `LayoutViewport`, which this routes to the active layout
    /// via the undoable `CADDrawing.addViewport` (one ⌘Z removes it), rebuilds nothing
    /// (viewports aren't in the quadtree — they render directly), and re-arms the tool
    /// for the next placement. Returns whether the canvas should redraw. No-op
    /// (returns `false`) unless viewport placement is active + meaningful.
    @discardableResult
    func handleViewportClick(_ paperPoint: Vector) -> Bool {
        guard isViewportPlacementActive, let layoutName = activeLayout,
              viewportTool != nil else { return false }
        let outcome = viewportTool!.handle(.click(paperPoint))
        toolStatus = viewportTool!.status
        switch outcome {
        case .none:
            return false
        case .preview, .cancelled:
            return true
        case .placed(let viewport):
            // Route the finished viewport to the active layout (undoable). The tool
            // already reset to its initial state, so the next two clicks place another.
            let explicitGroup = !undoManager.groupsByEvent
            if explicitGroup { undoManager.beginUndoGrouping() }
            defer { if explicitGroup { undoManager.endUndoGrouping() } }
            drawing.addViewport(viewport, toLayout: layoutName)
            // Re-seed the tool for the current model extents for the next placement.
            viewportTool = ViewportTool(modelExtents: modelExtentsForViewport)
            toolStatus = viewportTool?.status ?? ""
            modelDirty = true
            modelVersion &+= 1
            return true
        }
    }

    /// Cancels an in-progress viewport placement (Esc), discarding the rubber-band and
    /// re-arming the tool. Returns whether the canvas should redraw. No-op unless
    /// viewport placement is active.
    @discardableResult
    func cancelViewportPlacement() -> Bool {
        guard isViewportPlacementActive, viewportTool != nil else { return false }
        let outcome = viewportTool!.handle(.cancel)
        toolStatus = viewportTool!.status
        return outcome != .none
    }

    // MARK: - Per-layout export scene (PURE — no panel; wire-wave-1)

    /// Builds the `ExportScene` for one paper-space `layout` sheet: the resolved
    /// paper-space drawables on that layout (`space == .paper` AND `layoutName ==
    /// layout.name`, case-insensitively — the `PaperSpaceLayout` predicate). PURE (no
    /// `NSSavePanel`/modal), so it is reachable from a unit test AND from the
    /// View-layer Export-Layout / Print-Layout closures, which keep the panel.
    ///
    /// v1 cut: the sheet CONTENT only (paper-space entities on the layout). Model
    /// geometry seen THROUGH viewports is rendered on-screen but NOT plotted here — a
    /// documented follow-up; the on-screen viewport contents are a draw-only mapping.
    func layoutExportScene(for layout: Layout) -> ExportScene {
        let ctx = drawing.makeResolveContext()
        let layers = drawing.layers
        var polylines: [ResolvedPolyline] = []
        var fills: [ResolvedFill] = []
        var images: [ResolvedImage] = []
        var bounds = AABB.empty

        for e in drawing.entities {
            // Scope to THIS layout's paper-space records (the single source-of-truth
            // predicate the renderer + quadtree use).
            guard PaperSpaceLayout.isInActiveSpace(e, space: .paper, layoutName: layout.name)
            else { continue }
            // Layer-visibility / printability filter — identical policy to
            // `ExportSceneBuilder.build` (a frozen/hidden or non-printable layer
            // contributes nothing; an unknown layer still draws via the default pen).
            if let layer = layers.layer(e.layer) {
                if !layer.isVisible { continue }
                if !layer.isPrintable { continue }
            }
            let geo = e.resolve(ctx)
            for poly in geo.polylines {
                polylines.append(poly)
                for p in poly.points { bounds.expand(toInclude: p) }
            }
            for fill in geo.fills {
                fills.append(fill)
                for loop in fill.loops { for p in loop { bounds.expand(toInclude: p) } }
            }
            for image in geo.images {
                images.append(image)
                for p in image.corners { bounds.expand(toInclude: p) }
            }
        }
        return ExportScene(polylines: polylines, fills: fills, images: images, bounds: bounds)
    }

    // MARK: - In-place block editing (REFEDIT / BEDIT-style; built UNWIRED)
    //
    // AutoCAD-grade in-place block editing. The CRUX: a block's members are SHARED
    // id-refs into `drawing.entities` (ADR-001) and `blockMembersSnapshot()` resolves
    // them LIVE at every `makeResolveContext`, so editing a member record instantly
    // updates EVERY insert of that block — the edit IS the save-back. Our job here is
    // only the transient EDIT SESSION + the Save&Close / Discard semantics, reusing the
    // proven paper-space active-space pattern (scope the index/renderer to the members,
    // re-frame the camera, drop transient interaction state). No UI is wired here — a
    // later wire-wave adds double-click / a menu / a BlockEditBar that call these.
    //
    // Undo coherence: the whole session is ONE undo group (begin on enter, end on exit)
    // so a single ⌘Z after Save&Close reverts the entire session. Discard restores the
    // entry-state snapshot deterministically (through the undoable funnels) and then
    // drops the now-net-identity session group off the undo stack so `canUndo` returns
    // to its pre-enter value — no stranded half-session steps.

    /// One level of the block-edit session STACK (STAGE 3 — nested editing). Each level
    /// captures everything needed to restore THAT level on its own Save&Close / Discard:
    /// the block name, the entry-state member records + id list (for Discard), the view
    /// to restore when the level closes, and the `modelVersion` at the level's open (for
    /// the no-edit empty-group drop). Nested editing PUSHES a level; exit POPS one.
    private struct BlockEditSession {
        /// The block being edited at this level.
        var name: String
        /// Deep value copies of the block's members at this level's entry (Discard).
        var entrySnapshot: [EntityRecord]
        /// The block's ordered member-id list at this level's entry (Discard).
        var entryIDs: [EntityID]
        /// The active space + layout + camera to restore when THIS level closes. For a
        /// nested level this is the PARENT block-edit context's camera (so popping returns
        /// to the parent's framing); for the outermost level it is the document view.
        var priorSpace: EntitySpace
        var priorLayout: String?
        var priorViewport: Viewport
        /// `modelVersion` captured the instant this level opened (after its enter bump).
        var entryModelVersion: Int
        /// `true` once a NESTED child level Save&Closed with real edits while THIS level
        /// was its open parent — i.e. committed child work has folded into this level's
        /// still-open undo group. A Discard of this level must then NOT drop its group via
        /// `undoManager.undo()` (that would revert the child's SAVED edits — silent data
        /// loss); the entry-snapshot restore alone produces correct geometry (it touches
        /// only THIS block's members, never the child block's). Set on a child's
        /// Save&Close pop; default `false`.
        var hasSavedNestedWork: Bool = false
    }

    /// The open block-edit sessions, OUTERMOST → innermost. Empty when no session is open;
    /// the LAST element is the level currently being edited. A nested open pushes; an exit
    /// pops one level. Observed (stored) so the tab strip / chrome update on push/pop.
    /// Fully private (its element type is private); external readers use the public
    /// computed views `editingBlock` / `editingBlockStack` / `isEditingBlock`.
    private var editingSessionStack: [BlockEditSession] = []

    /// The name of the block currently being edited in place (the TOP of the session
    /// stack), or `nil` when not in a block-edit session. Drives `activeSpaceEntities`
    /// (which scopes the index / snapping / selection to the block's members) and is what
    /// the chrome reads to show the "Editing block …" affordance. Computed over the
    /// observed `editingSessionStack`, so it stays a live, observable read.
    var editingBlock: String? { editingSessionStack.last?.name }

    /// Whether a block-edit session is active.
    var isEditingBlock: Bool { !editingSessionStack.isEmpty }

    /// The open block-edit sessions by NAME, OUTERMOST → innermost (a breadcrumb for the
    /// tab strip, e.g. `["A", "B"]` while editing B nested inside A). Empty when no
    /// session is open.
    var editingBlockStack: [String] {
        editingSessionStack.map(\.name)
    }

    /// The member `EntityRecord`s of the block being edited (looked up LIVE via the
    /// block's `entityIDs`), or `[]` when not editing / the block vanished. This is the
    /// scoped subset `activeSpaceEntities` returns during a session — a stale member id
    /// (no longer in the drawing) is skipped, matching `blockMembersSnapshot`.
    var editingBlockEntities: [EntityRecord] {
        guard let name = editingBlock,
              let block = drawing.blocks.block(named: name) else { return [] }
        return block.entityIDs.compactMap { drawing.entity($0) }
    }

    /// The bounding box of the block being edited (its live members) — what the camera
    /// frames on enter so the members fill the view.
    private var editingBlockBoundingBox: AABB {
        var box = AABB.empty
        for e in editingBlockEntities { box = box.union(e.boundingBox()) }
        return box
    }

    /// Enters an in-place edit session for the named block (REFEDIT/BEDIT). Mirrors the
    /// `setActiveSpace` body: it scopes the spatial index to the block's members (so
    /// snapping/selection operate on the contents), re-frames the camera to the members'
    /// bounds, drops transient selection/snap/hover, and marks the GPU buffer dirty +
    /// bumps `modelVersion`. It also snapshots the entry-state members (deep value
    /// copies) + the entry member-id list for Discard, remembers the prior view to
    /// restore on exit, and OPENS one undo group so the whole session collapses to a
    /// single ⌘Z.
    ///
    /// While editing, member edits go through the UNCHANGED undoable funnels
    /// (`applyCommit` / `applyInspectorEdits`); every committed edit immediately updates
    /// all inserts via the next `makeResolveContext` (the live-member resolve crux). The
    /// previously-active tool's `relativeZero` etc. are untouched — only the canvas
    /// scope changes.
    ///
    /// NESTED editing (STAGE 3): if a session is ALREADY open, this PUSHES a new level for
    /// `name` (e.g. double-clicking an insert of block B while editing block A opens B
    /// nested inside A). Each level keeps its own entry snapshot + undo group + prior view,
    /// so its Save&Close/Discard affects only that level. A CYCLIC open — `name` is already
    /// somewhere in the stack — is rejected (it would nest a block inside itself forever).
    ///
    /// No-op (returns `false`) if the block is unknown or the open would be cyclic. Returns
    /// `true` on a started (or pushed) session.
    @discardableResult
    func enterBlockEditing(name: String) -> Bool {
        guard let block = drawing.blocks.block(named: name) else { return false }
        // Cyclic-nesting guard: refuse to open a block already in the session stack
        // (case-insensitive, matching the block-name identity). Opening A within A — at any
        // depth — would recurse without bound.
        if editingSessionStack.contains(where: {
            $0.name.caseInsensitiveCompare(block.name) == .orderedSame
        }) { return false }

        // This level returns to the CURRENT view on close (for the outermost level that is
        // the document view; for a nested level it is the parent block-edit framing).
        var session = BlockEditSession(
            name: block.name,
            entrySnapshot: block.entityIDs.compactMap { drawing.entity($0) },
            entryIDs: block.entityIDs,
            priorSpace: activeSpace,
            priorLayout: activeLayout,
            priorViewport: viewport,
            entryModelVersion: 0   // set after the enter bump below
        )

        // ONE undo group for THIS level — a single ⌘Z reverts this level's edits. Mirrors
        // the explicit-grouping rationale in `applyCommit` (inner per-commit groups nest).
        undoManager.beginUndoGrouping()

        // Push the level (the top now drives `editingBlock` / the scoped subset).
        editingSessionStack.append(session)

        // Re-frame the camera to the members; re-home the floating origin near them.
        viewport = Viewport.fit(editingBlockBoundingBox, in: viewport.size)
        renderOrigin = RendererGeometry.renderOrigin(for: editingBlockBoundingBox)

        // Scope the index to the members; drop transient interaction state.
        rebuildIndex()
        selection.clear()
        snap = nil
        hoverID = nil
        modelDirty = true
        modelVersion &+= 1
        // Capture the post-bump version on the pushed level: any later change is a
        // session edit (used at exit to drop an empty no-edit group rather than strand a
        // no-op ⌘Z step). Re-assign the top element (value type).
        session.entryModelVersion = modelVersion
        editingSessionStack[editingSessionStack.count - 1] = session
        return true
    }

    /// Leaves the CURRENT (innermost) block-edit session level, POPPING one level.
    ///
    /// - `save == true` (Save & Close): keep the level's edits — they are already applied to
    ///   the live member records and already undoable. The level's undo group is closed so a
    ///   single ⌘Z reverts that level.
    /// - `save == false` (Discard): restore THIS level's entry-state members + member-id
    ///   list (so the block AND every insert return to this level's entry geometry), close
    ///   the level's group, then drop that now-net-identity group off the undo stack so
    ///   `canUndo` returns to its pre-level value (no stranded half-session steps) —
    ///   EXCEPT when the level absorbed a nested child's SAVED edits (see
    ///   `hasSavedNestedWork`), in which case the group is kept so those committed edits
    ///   are not reverted (the snapshot restore alone fixes THIS block's geometry).
    ///
    /// A level that made NO edits drops its empty group on EITHER path so it never strands a
    /// no-op ⌘Z step — detected via `modelVersion` (only the edit funnels bump it).
    ///
    /// When the popped level was NESTED, the canvas returns to the PARENT block-edit context
    /// (its framing + scope); when it was the outermost level, the canvas returns to the
    /// document view. No-op (returns `false`) if no session is active. Presents NO modal —
    /// the view layer asks Save/Discard and calls this with the answer.
    @discardableResult
    func exitBlockEditing(save: Bool) -> Bool {
        guard let level = editingSessionStack.last else { return false }

        // Is THIS the outermost level being popped? Only then is no PARENT level's undo
        // group still open, so only then may we call `undoManager.undo()` to DROP a
        // net-identity / empty group (UndoManager forbids `undo()` while a group is open —
        // "too many nested undo groups"). For an INNER level we just close its group: its
        // (possibly net-identity) work folds into the parent's still-open group, which
        // reverts atomically when the parent is undone/discarded. Geometry is correct
        // either way because Discard restores the entry snapshot through the undoable
        // funnels BEFORE the group closes.
        let isOutermost = editingSessionStack.count == 1

        // Did any edit funnel commit during THIS level? (The edit funnels —
        // `applyCommit` / `applyInspectorEdits` — and the in-session authoring mutators
        // all bump `modelVersion` between this level's enter and here.)
        let sessionChanged = modelVersion != level.entryModelVersion

        // A Discard MUST NOT drop this level's group via `undo()` when committed nested
        // child work has folded into it (a child Save&Closed inside this level) — that
        // would revert the child's SAVED edits (silent data loss). The snapshot restore
        // alone yields correct geometry (it touches only THIS block's members). So the
        // group-drop is allowed only when THIS is the outermost level AND it carries no
        // saved nested work.
        let mayDropGroup = isOutermost && !level.hasSavedNestedWork

        if save && sessionChanged {
            // Keep edits: just close the level's group (one ⌘Z reverts the level).
            undoManager.endUndoGrouping()
        } else if save {
            // Save & Close with NO edits: close the empty group; drop it (outermost only)
            // so the stack stays at its pre-level depth (no stranded no-op step).
            undoManager.endUndoGrouping()
            if mayDropGroup && undoManager.canUndo { undoManager.undo() }
        } else if sessionChanged {
            // Discard: restore THIS level's entry snapshot through the undoable funnels (so
            // the restorations are captured INSIDE the still-open level group), making the
            // group net-identity for THIS block's members. Geometry is now at this level's
            // entry state regardless of whether we can drop the group.
            restoreBlockEntrySnapshot(level)
            undoManager.endUndoGrouping()
            // Drop the net-identity level group when safe (outermost + no saved nested
            // work). For an inner level the work folds into the parent group; for an outer
            // level that absorbed a child's SAVED edits we keep the group (dropping it
            // would revert that saved work).
            if mayDropGroup && undoManager.canUndo { undoManager.undo() }
        } else {
            // Discard with NO edits: nothing to restore — drop the empty group (when safe).
            undoManager.endUndoGrouping()
            if mayDropGroup && undoManager.canUndo { undoManager.undo() }
        }

        // Pop THIS level and restore its prior view (parent block-edit framing, or the
        // document view for the outermost level).
        editingSessionStack.removeLast()
        // Propagate the "committed nested work folded into me" signal UP the stack on EVERY
        // pop that carries such work — not just the immediate child-save case. When a level
        // closes while a PARENT remains open, any COMMITTED work in the popped level's group
        // folds into the parent's still-open group. That committed work is either:
        //   (a) THIS level's own Save&Close with real edits (`save && sessionChanged`), or
        //   (b) saved DEEPER work this level had already absorbed (`level.hasSavedNestedWork`)
        //       — which survives even if THIS level is itself Discarded (its Discard only
        //       restores its own block's members; the deeper saved edits remain committed).
        // In either case the parent must be marked so its own Discard won't `undo()` that
        // committed work away (the deeper instance of the finding-#1 data-loss bug). Without
        // (b), a Save C → Discard B → Discard A chain at depth ≥3 would silently revert C.
        let foldedSavedWork = (save && sessionChanged) || level.hasSavedNestedWork
        if foldedSavedWork, let parentIdx = editingSessionStack.indices.last {
            editingSessionStack[parentIdx].hasSavedNestedWork = true
        }
        activeSpace = level.priorSpace
        activeLayout = level.priorLayout
        viewport = level.priorViewport
        // If a parent level remains open, re-home the origin to its members; otherwise to
        // the restored active space.
        if editingSessionStack.isEmpty {
            renderOrigin = RendererGeometry.renderOrigin(for: activeSpaceBoundingBox)
        } else {
            renderOrigin = RendererGeometry.renderOrigin(for: editingBlockBoundingBox)
        }

        rebuildIndex()
        selection.clear()
        snap = nil
        hoverID = nil
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// Auto-saves and closes ALL open block-edit session levels if any are open (a no-op
    /// otherwise). The view layer calls this when the session must end unexpectedly — e.g.
    /// the document is being closed, or the user picks a Model/Layout tab mid-edit — because
    /// the member edits are already in the document (the live-member crux), so Save&Close is
    /// the safe, non-destructive default. Pops every nested level (each kept). Presents NO
    /// modal (it is reachable from the document lifecycle, which a unit test exercises).
    /// Returns whether at least one level was closed.
    @discardableResult
    func finishBlockEditingIfNeeded() -> Bool {
        guard !editingSessionStack.isEmpty else { return false }
        while !editingSessionStack.isEmpty {
            _ = exitBlockEditing(save: true)
        }
        return true
    }

    /// Restores a block's members + member-id list to a session LEVEL's entry snapshot,
    /// through the undoable `CADDrawing` funnels so the restorations register inside the
    /// open level group (Discard). Member records present at entry are `replace`d back
    /// (re-added if they were deleted during the level); members ADDED during the level
    /// (ids not in the entry set) are removed; then the member-id list is re-pointed to the
    /// level's entry list via `setBlockMembers`. A block that vanished entirely is skipped.
    private func restoreBlockEntrySnapshot(_ level: BlockEditSession) {
        let name = level.name
        guard drawing.blocks.contains(name) else { return }

        let entryIDSet = Set(level.entryIDs)
        // Remove members that were ADDED during the level (not part of entry).
        let currentIDs = drawing.blocks.block(named: name)?.entityIDs ?? []
        for id in currentIDs where !entryIDSet.contains(id) {
            drawing.remove(id)
            quadtree.remove(id)
            selection.remove(id)
        }
        // Restore each entry member's full record (re-adds any that were deleted). NOTE:
        // a member deleted mid-level is re-added at the draw-order TAIL (drawing.replace
        // falls back to add for an absent id), not its original storage index. This is
        // harmless for block/insert resolution (members resolve in `entityIDs` order,
        // which is restored by `setBlockMembers` below) — only the raw draw-order index of
        // a re-added member is not preserved.
        for record in level.entrySnapshot {
            drawing.replace(record)
        }
        // Re-point the block at exactly the level's entry member-id list.
        drawing.setBlockMembers(name: name, ids: level.entryIDs)
    }

    // MARK: - New layout (paper-space P2 — the "+" tab)

    /// Creates a fresh layout with a sensible default page (ISO A4 portrait, the
    /// engine `PageDescriptor` default) and a unique auto-numbered name ("Layout1",
    /// "Layout2", …), appended after the existing tabs, then ACTIVATES it (so the "+"
    /// button both adds and switches to the new sheet, the AutoCAD behavior). Returns
    /// the created layout's name, or `nil` if (defensively) the add failed. Undoable
    /// via the engine `addLayout` (value-snapshot of the layout table). Model space
    /// stays the default for every OTHER window — this only affects the active model.
    @discardableResult
    func newLayout(page: PageDescriptor = .a4Portrait) -> String? {
        let name = nextLayoutName()
        let order = (drawing.layouts.map(\.tabOrder).max() ?? -1) + 1
        let layout = Layout(name: name, tabOrder: order, page: page)
        guard drawing.addLayout(layout) else { return nil }
        // A new layout changes the document (the layout table) — keep the canvas in
        // sync and switch to the fresh sheet.
        modelVersion &+= 1
        activateLayout(name: name)
        return name
    }

    /// The next free auto-numbered layout name ("Layout1", "Layout2", …) — the lowest
    /// `LayoutN` not already taken (case-insensitively). Mirrors AutoCAD's default
    /// new-layout naming so created tabs read naturally.
    private func nextLayoutName() -> String {
        var n = 1
        while drawing.hasLayout("Layout\(n)") { n += 1 }
        return "Layout\(n)"
    }

    // MARK: - Viewport history (F23 — Zoom Previous)

    /// A bounded back-stack of prior viewports for View ▸ Zoom Previous. A view
    /// change that the user can step BACK from (zoom-to-fit, zoom-window) pushes the
    /// PRIOR viewport here first; Zoom Previous pops the most recent. Bounded so a
    /// long session never grows it without limit (LibreCAD keeps a small zoom
    /// history). `@ObservationIgnored` — it is interaction state, not rendered.
    @ObservationIgnored
    private var viewportHistory: [Viewport] = []

    /// The most viewports the back-stack keeps (oldest dropped past this).
    private static let maxViewportHistory = 32

    /// Whether a previous viewport is available to restore (drives the View ▸ Zoom
    /// Previous menu item's enabled state). Observed via `modelVersion` bumps the
    /// zoom ops perform, so the menu refreshes.
    var canZoomPrevious: Bool { !viewportHistory.isEmpty }

    /// Pushes the CURRENT viewport onto the history back-stack (oldest dropped once
    /// the bound is reached), so a subsequent view change can be undone by Zoom
    /// Previous. Called by the steppable zoom ops BEFORE they change the viewport.
    private func pushViewportHistory() {
        viewportHistory.append(viewport)
        if viewportHistory.count > Self.maxViewportHistory {
            viewportHistory.removeFirst(viewportHistory.count - Self.maxViewportHistory)
        }
    }

    /// Restores the most recently saved viewport (View ▸ Zoom Previous). No-op
    /// (returns `false`) when the history is empty. A pure view change (matrix-only,
    /// no model dirty); bumps `modelVersion` so the menu/canvas refresh.
    @discardableResult
    func zoomPrevious() -> Bool {
        guard let prev = viewportHistory.popLast() else { return false }
        viewport = prev
        modelVersion &+= 1
        return true
    }

    // MARK: - Named views (LibreCAD / AutoCAD parity — save & restore a viewport)

    /// The named-view registry (`NamedViewTable`): the current viewport saved under
    /// a name (center + scale + rotation), restorable later via the View menu. Held
    /// as SESSION state on the model for this version, so save → restore works fully
    /// within a session; cross-save (on-disk) persistence + DXF/DWG VPORT/VIEW
    /// round-trip is a documented FOLLOW-UP (the `NamedView`/`NamedViewTable` types
    /// are already `Codable`, so wiring them into the document codec later is an
    /// additive step). Observed so the View ▸ Restore/Delete submenus + menu enable
    /// state track it live.
    private(set) var namedViews = NamedViewTable()

    /// The saved view names in display order — what the View ▸ Restore/Delete
    /// submenus list. Bumps via `modelVersion` on every named-view mutation so the
    /// menu refreshes.
    var namedViewNames: [String] { namedViews.names }

    /// Whether any named view exists (drives the Restore/Delete menu items' enabled
    /// state). Observed via `modelVersion` bumps the save/delete ops perform.
    var hasNamedViews: Bool { !namedViews.isEmpty }

    /// Saves the CURRENT viewport under `name` (View ▸ Save View…). The captured
    /// state is the viewport's world center + scale (+ rotation 0; the viewport has
    /// none yet) — NOT the view size, so a restore re-frames into whatever the window
    /// size is then (`NamedView.capture`). A blank name is rejected; a same-named
    /// view is overwritten in place (AutoCAD "save over"). Returns the canonical
    /// (trimmed) name it was saved under, or `nil` for a blank name. Bumps
    /// `modelVersion` so the menus refresh. Session state only — not undoable / not
    /// (yet) persisted to disk (a drafting aid, like the relative-zero / ortho).
    @discardableResult
    func saveNamedView(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let view = NamedView.capture(viewport, name: trimmed)
        namedViews.upsert(view)
        modelVersion &+= 1
        return trimmed
    }

    /// Applies a saved `NamedView` to the live viewport: restores its world center +
    /// scale while KEEPING the current view size (so the restore fits the current
    /// window — `NamedView.apply`). A pure view change (matrix-only, no model dirty);
    /// bumps `modelVersion` so the menu/canvas refresh. Pushes the prior viewport
    /// onto the Zoom-Previous history first so a restore can be stepped back from
    /// (matches `zoomToFit`/zoom-window). Returns `true` if the viewport changed.
    @discardableResult
    func applyNamedView(_ view: NamedView) -> Bool {
        let restored = view.apply(to: viewport)
        guard restored != viewport else { return false }
        pushViewportHistory()
        viewport = restored
        modelVersion &+= 1
        return true
    }

    /// Restores the named view called `name` (View ▸ Restore View ▸ <name>). No-op
    /// (returns `false`) if no such view exists or it would not change the viewport.
    @discardableResult
    func restoreNamedView(name: String) -> Bool {
        guard let view = namedViews.view(named: name) else { return false }
        return applyNamedView(view)
    }

    /// Deletes the named view called `name` (View ▸ Delete View ▸ <name>). No-op
    /// (returns `false`) if absent. Bumps `modelVersion` so the menus refresh.
    @discardableResult
    func deleteNamedView(name: String) -> Bool {
        let changed = namedViews.remove(named: name)
        if changed { modelVersion &+= 1 }
        return changed
    }

    // MARK: - View changes (matrix-only)

    /// Updates the stored view size (on resize). Keeps the same world center/scale.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport.size = size
    }

    /// Frames the whole drawing in the current view (Zoom to Fit). Pushes the prior
    /// viewport onto the Zoom-Previous history first so the framing can be stepped
    /// back from.
    func zoomToFit() {
        pushViewportHistory()
        viewport = Viewport.fit(drawing.boundingBox(), in: viewport.size)
        modelVersion &+= 1
    }

    // MARK: - Zoom window (F23 — drag a box → fit it)

    /// Whether the canvas is in transient Zoom-Window mode: the next drag draws a
    /// box and, on release, the view zooms to fit that box (then mode auto-exits).
    /// Entered from View ▸ Zoom Window; the canvas reads this to route a drag to the
    /// zoom-box gesture instead of a marquee/pan. Observed so the menu checkmark +
    /// status chip track it. Purely interaction policy (not document state).
    var zoomWindowArmed: Bool = false

    /// The live zoom-window drag rectangle in WORLD coordinates while the user is
    /// dragging the box, or `nil` when no box is in progress. The marquee/zoom
    /// overlay reads it to draw the box; the canvas sets it on drag, clears on up.
    @ObservationIgnored
    private(set) var zoomWindowRect: AABB?

    /// Arms (or disarms) Zoom-Window mode. Entering it leaves any active draw tool
    /// alone (zoom is a transient view gesture); the canvas only routes the NEXT
    /// empty-style drag to the box. Bumps `modelVersion` for the menu/status chip.
    func setZoomWindowArmed(_ armed: Bool) {
        zoomWindowArmed = armed
        if !armed { zoomWindowRect = nil }
        modelVersion &+= 1
    }

    /// Begins a zoom-window box anchored at a world point (degenerate box).
    func beginZoomWindow(at world: Vector) {
        zoomWindowRect = AABB(point: world)
        modelVersion &+= 1
    }

    /// Updates the live zoom-window box to span from its anchor to the cursor world
    /// point. Bumps `modelVersion` so the overlay repaints.
    func updateZoomWindow(from anchor: Vector, to cursor: Vector) {
        zoomWindowRect = AABB(points: [anchor, cursor])
        modelVersion &+= 1
    }

    /// Commits the in-progress zoom-window box: pushes the prior viewport (so Zoom
    /// Previous can step back), zooms the viewport to fit the box (matrix-only via
    /// the pure `Viewport.zoomedToWorldRect`), clears the box, and auto-exits
    /// Zoom-Window mode (a one-shot gesture, matching LibreCAD). A degenerate box
    /// (a click, not a drag) is treated as "no window" — it just cancels the mode
    /// without zooming. Returns whether the view actually zoomed.
    @discardableResult
    func commitZoomWindow() -> Bool {
        defer { zoomWindowRect = nil; zoomWindowArmed = false; modelVersion &+= 1 }
        guard let rect = zoomWindowRect, !rect.isEmpty else { return false }
        let zoomed = viewport.zoomedToWorldRect(rect)
        guard zoomed != viewport else { return false }   // sub-tolerance box → no-op
        pushViewportHistory()
        viewport = zoomed
        return true
    }

    /// Cancels an in-progress zoom-window box WITHOUT zooming, and exits the mode
    /// (Esc / mouse-exit). Bumps `modelVersion` so the box overlay erases.
    func cancelZoomWindow() {
        guard zoomWindowArmed || zoomWindowRect != nil else { return }
        zoomWindowRect = nil
        zoomWindowArmed = false
        modelVersion &+= 1
    }

    /// Pans by a screen-space delta (AppKit points, Y-down).
    func pan(byScreenDelta d: CGSize) {
        viewport.pan(byScreenDelta: d)
    }

    /// Zooms about a screen point (cursor). `factor > 1` zooms in.
    func zoom(by factor: Double, about screenPoint: CGPoint) {
        viewport.zoom(by: factor, about: screenPoint)
    }

    // MARK: - Interaction (snap + hit-test), CPU, f64, exact

    /// The pick/snap aperture in GUI points (LibreCAD `m_catchEntityGuiRange`).
    static let catchPoints: Double = 8

    /// Snap tolerance in world units for the current zoom.
    var worldTolerance: Double { Self.catchPoints * viewport.worldPerPixel }

    /// Runs snapping for a cursor screen point, updating `cursorWorld` + `snap`.
    /// Returns whether the snap result changed (so the caller can skip a redraw).
    @discardableResult
    func updateSnap(atScreenPoint screen: CGPoint, gridSpacing: Double?) -> Bool {
        lastGridSpacing = gridSpacing
        let world = viewport.screenToWorld(screen)
        cursorWorld = world
        let result = Snapping.snap(
            worldPoint: world,
            modes: snapModes,
            worldTolerance: worldTolerance,
            gridSpacing: gridSpacing,
            in: drawing,
            using: quadtree
        )
        let changed = result != snap
        snap = result
        return changed
    }

    /// The snapped world point for a screen point — the point a draw tool should
    /// receive. Runs the snapper (updating the snap marker + cursor HUD) and
    /// returns the chosen snap point (falling back to the raw world point).
    func snappedWorldPoint(atScreenPoint screen: CGPoint, gridSpacing: Double?) -> Vector {
        updateSnap(atScreenPoint: screen, gridSpacing: gridSpacing)
        return snap?.point ?? viewport.screenToWorld(screen)
    }

    /// Click → hit-test the nearest entity and toggle it into the selection.
    /// Returns whether the selection changed (so the caller redraws).
    ///
    /// FIRST consults the one-shot "Set Relative Origin" arm: when armed, this click is
    /// consumed to set `relativeZero` to the SNAPPED click point (and the arm clears)
    /// instead of toggling selection — so the relative-zero pick rides the EXISTING
    /// select-mode click path with no change to the canvas view (the view already calls
    /// this for a select-mode click). Returns `true` so the canvas repaints the moved
    /// origin marker.
    @discardableResult
    func toggleSelection(atScreenPoint screen: CGPoint) -> Bool {
        // One-shot relative-origin pick (armed via `armSetRelativeZero`): set the datum
        // to the snapped click and disarm. Takes precedence over selection toggling.
        if settingRelativeZeroArmed {
            let p = snappedWorldPoint(atScreenPoint: screen, gridSpacing: lastGridSpacing)
            setRelativeZero(p)
            settingRelativeZeroArmed = false
            return true
        }
        let world = viewport.screenToWorld(screen)
        let id = selection.hitTest(
            worldPoint: world,
            worldTolerance: worldTolerance,
            in: drawing,
            using: quadtree
        )
        guard let id else { return false }
        selection.toggle(id)
        return true
    }

    // MARK: - Relative zero (set / lock / reset) — LibreCAD's "Set relative zero"

    /// Arms the one-shot "Set Relative Origin" pick: the NEXT snapped canvas click (in
    /// select mode) sets `relativeZero` to that point, then auto-disarms (the
    /// Zoom-Window one-shot-arm pattern). The pick is consumed by `toggleSelection` on
    /// the existing select-mode click path, so no canvas-view change is needed. Bumps
    /// `modelVersion` so a status chip / the cursor reflects the armed state.
    func armSetRelativeZero() {
        settingRelativeZeroArmed = true
        modelVersion &+= 1
    }

    /// Cancels a pending one-shot relative-origin pick without setting anything
    /// (Esc / mode change). No-op when not armed.
    func cancelSetRelativeZero() {
        guard settingRelativeZeroArmed else { return }
        settingRelativeZeroArmed = false
        modelVersion &+= 1
    }

    /// Sets the relative-zero datum directly to a world point (the resolved one-shot
    /// pick, or any programmatic set). Does NOT change the lock state — setting an
    /// origin while locked just moves the locked datum. Bumps `modelVersion` so the
    /// origin marker / readouts refresh.
    func setRelativeZero(_ point: Vector) {
        guard point.valid else { return }
        relativeZero = point
        modelVersion &+= 1
    }

    /// Locks / unlocks the relative-zero (LibreCAD's "Lock relative zero"). When LOCKED
    /// the datum stops auto-advancing to the last placed point and survives run-end /
    /// tool-change; when UNLOCKED the default auto-follow-the-last-point behavior
    /// resumes. Bumps `modelVersion` so the menu state + status chip track it.
    func setRelativeZeroLocked(_ locked: Bool) {
        relativeZeroLocked = locked
        modelVersion &+= 1
    }

    /// Toggles the relative-zero lock (the menu/keyboard verb). Returns the NEW locked
    /// state so the caller can reflect it.
    @discardableResult
    func toggleRelativeZeroLock() -> Bool {
        setRelativeZeroLocked(!relativeZeroLocked)
        return relativeZeroLocked
    }

    /// Resets the relative-zero to the ABSOLUTE origin (0, 0) — LibreCAD's "Set
    /// relative zero to origin". Leaves the lock state untouched (a reset just moves
    /// the datum back to the world origin). Bumps `modelVersion` so readouts refresh.
    func resetRelativeZeroToOrigin() {
        relativeZero = Vector(0, 0)
        modelVersion &+= 1
    }

    /// Clears the cursor/snap overlay (mouse left the view).
    func clearCursor() {
        cursorWorld = nil
        snap = nil
    }

    // MARK: - Tool activation + routing

    /// Activates `kind`, minting a fresh tool value (or clearing to select mode).
    /// Returns to `.select` discards any in-progress preview. The freshly-minted
    /// tool is configured from the Inspector's stored options (`applyToolConfig`).
    func activateTool(_ kind: ToolKind) {
        activeToolKind = kind
        tool = kind.makeTool()
        applyToolConfig()
        // `.viewport` is an OUT-OF-BAND kind (no `Tool`): arm the standalone
        // `ViewportTool` so the 2-click paper-space placement flow is ready. Switching
        // to any other kind clears it (a no-op when it was already nil).
        armViewportTool()
        toolStatus = tool?.status ?? viewportTool?.status ?? ""
        // A fresh tool has placed no point yet — clear any stale relative-zero so the
        // command line's `@`/polar/distance input has no leftover reference. A LOCKED
        // datum survives the tool change (the user pinned it deliberately).
        if !relativeZeroLocked { relativeZero = nil }
        lastCommandError = nil
    }

    /// Sets the Image tool's source (file path + the source pixel size the picker read
    /// from the file) and activates the Image tool, so the user can then click the two
    /// placement corners. The path + pixel size flow onto the freshly-minted `ImageTool`
    /// via `applyToolConfig` (`activateTool` calls it). Called by the app's file-picker
    /// flow (ContentView) after the user chooses an image and `NSImage` reports its
    /// pixel dimensions. A non-positive pixel size falls back to 1 (the tool then treats
    /// the click distances as the edge lengths directly).
    func setImageSourceAndActivate(path: String, pixelWidth: Double, pixelHeight: Double) {
        imagePath = path
        imagePixelWidth = pixelWidth > 0 ? pixelWidth : 1
        imagePixelHeight = pixelHeight > 0 ? pixelHeight : 1
        activateTool(.image)
    }

    /// Activates `kind` FROM the command bar: it activates the tool through the SAME
    /// `activateTool` path the toolbar/menu/palette use (so behavior is identical),
    /// promotes `kind` to the front of the MRU (the pure `ToolSuggester.updatedMRU`,
    /// deduping + capping), and clears the launcher query so the chip row returns to
    /// the adaptive set. It does NOT handle `.image` (that needs the View-layer
    /// file-picker — the bar special-cases `.image` to its own picker closure and
    /// records the MRU via `recordCommandBarUse` instead), so callers route `.image`
    /// separately to keep modals out of the model (headless-test-safe).
    func activateToolFromCommandBar(_ kind: ToolKind) {
        recordCommandBarUse(kind)
        activateTool(kind)
        commandBarQuery = ""
    }

    /// Promotes `kind` to the front of the command bar's MRU (most-recent first,
    /// deduped, capped) via the pure `ToolSuggester.updatedMRU`. Split out from
    /// `activateToolFromCommandBar` so the `.image` flow — which activates via the
    /// View-layer file-picker, NOT `activateTool(.image)` — can still record its use
    /// in the MRU. The view persists the updated list to `@AppStorage`.
    func recordCommandBarUse(_ kind: ToolKind) {
        commandBarMRU = ToolSuggester.updatedMRU(commandBarMRU, used: kind)
    }

    /// Pushes the Inspector's stored tool options onto the live tool value. The
    /// parameterized tools expose their parameters as public `var`s / a `config`
    /// (`ToolKind.makeTool()` mints them with fixed defaults), so we downcast and
    /// overwrite the parameters here. Called after EVERY mint of the active tool
    /// (`activateTool` and the post-commit re-mint in `handleToolInput`) so a
    /// chained run keeps the user's configured values. No-op for tools without
    /// options. The `tool` is a value type owned by the model, so the mutated copy
    /// is stored back.
    func applyToolConfig() {
        switch tool {
        case var t as FilletTool:
            t.radius = filletRadius
            tool = t
        case var t as ChamferTool:
            t.distance1 = chamferDistance1
            t.distance2 = chamferDistance2
            tool = t
        case var t as ArrayTool:
            t.config = InspectorEdits.arrayConfig(
                polar: arrayPolar,
                rows: arrayRows, cols: arrayCols,
                spacingX: arraySpacingX, spacingY: arraySpacingY,
                count: arrayPolarCount, totalAngle: arrayPolarTotalAngle,
                rotateItems: arrayPolarRotateItems
            )
            tool = t
        case is DivideTool:
            // DivideTool's `divisions` is set at construction, so re-mint with the
            // configured count (its public `var divisions` is settable too, but the
            // init carries the clamp/validation, so prefer the init).
            tool = DivideTool(divisions: Swift.max(2, divideCount))

        // MARK: NEW draw-tool options (UX-plan U2)

        case var t as PolygonTool:
            t.sides = polygonSides          // the tool clamps to ≥ 3
            t.fit = polygonFit
            // Assemble the enum-with-associated-value from the split state (case index
            // + the star-ratio scalar) — the UI-simple split the brief prescribes.
            switch polygonModeStyle {
            case 1:  t.mode = .edge
            case 2:  t.mode = .star(ratio: polygonStarRatio)
            default: t.mode = .centerCorner
            }
            tool = t
        case var t as RectangleTool:
            // 0 ⇒ "unset" so the optional exact-size flow is opt-in (both must be > 0).
            t.fixedWidth = rectWidth > 0 ? rectWidth : nil
            t.fixedHeight = rectHeight > 0 ? rectHeight : nil
            // Assemble the corner enum from the split state (case index + cut scalar).
            switch rectCornerStyle {
            case 1:  t.corner = .rounded(radius: rectCornerSize)
            case 2:  t.corner = .chamfer(distance: rectCornerSize)
            default: t.corner = .square
            }
            tool = t
        case is EllipseTool:
            // EllipseTool's `mode` is fixed at construction (it seeds the start state),
            // so re-mint with the configured mode (the DivideTool/ArcTool pattern).
            tool = EllipseTool(mode: ellipseModeValue)
        case var t as TrimTool:
            // Push the options-bar trim mode + signed amount onto the active tool so
            // a click dispatches to the chosen variant. `trimModeValue` maps the
            // stored case INDEX (`trimModeIndex`) → `TrimTool.Mode`; `trimAmount` is
            // the signed distance the `.amount` mode applies (positive lengthens,
            // negative shortens). `.boundary` (index 0, the default) leaves the
            // single-click cut-to-boundary behavior unchanged.
            t.mode = trimModeValue
            t.amount = trimAmount
            tool = t
        case is CircleTool:
            // CircleTool's CONSTRUCTION `mode` (centerRadius / twoPoint / threePoint)
            // is fixed at construction (it seeds the start state), so RE-MINT with the
            // chosen mode (the DivideTool/ArcTool/EllipseTool pattern). The size mode +
            // optional fixed size are settable `var`s, applied after the mint.
            var t = CircleTool(mode: circleConstructionMode)
            t.sizeMode = circleSizeMode
            t.fixedSize = circleFixedSize > 0 ? circleFixedSize : nil
            tool = t
        case is ArcTool:
            // ArcTool's `mode` is fixed at construction (it seeds the start state),
            // so re-mint with the configured mode (mirrors the DivideTool pattern).
            tool = ArcTool(mode: arcMode)
        case is LineTool:
            // LineTool's `angleMode` is fixed at construction (it seeds the angle
            // constraint applied to each segment), so re-mint with the assembled mode
            // (the DivideTool/ArcTool re-mint pattern). The default `.free` mode keeps
            // the original unconstrained behavior, so this is fully back-compatible.
            tool = LineTool(angleMode: lineAngleModeValue)
        case var t as PointTool:
            t.style = pointStyle
            tool = t
        case var t as TextTool:
            t.height = Swift.max(InspectorEdits.minTextHeight, textHeight)
            tool = t

        // MARK: Block-members injection (wire-wave-2)

        case is ExplodeInsertTool:
            // ExplodeInsertTool is PURE and `ToolContext` carries no block provider,
            // so the block's member records are supplied at construction (mirroring how
            // InsertTool receives `previewMembers`). Re-mint with a `@Sendable` provider
            // backed by a value-snapshot of the drawing's block table, so a selected
            // `.insert` explodes into its real member geometry. The snapshot is taken
            // each time the tool is (re-)minted (activate / post-commit), so a block
            // edited between runs explodes correctly on the next run.
            let members = blockMembersSnapshot()
            tool = ExplodeInsertTool(blockMembers: { name in members[name] })

        // MARK: Create-Block tool — chosen name injected at construction (WAVE BW)

        case is CreateBlockTool:
            // CreateBlockTool's name is fixed at construction (the View-layer name sheet
            // supplies it via `pendingCreateBlockName` before activating `.createBlock`).
            // Re-mint with the chosen name so the new block carries it; an absent name
            // falls back to the tool's default ("Block"), which the model op de-dups.
            let name = (pendingCreateBlockName?.isEmpty == false)
                ? pendingCreateBlockName! : "Block"
            tool = CreateBlockTool(blockName: name)

        // MARK: Insert tool — chosen block name + member snapshot injected (WAVE BW)

        case is InsertTool:
            // InsertTool's target block name + the member records for its rubber-band
            // preview are fixed at construction, as are its placement scale / rotation /
            // MINSERT array. Re-mint with the picked block (from the View-layer
            // block-picker via `pendingInsertBlockName`) + a value snapshot of its
            // members + the Tool Options bar's scale / rotation / rows / cols / spacing.
            // With no name chosen the tool stays inert (a safe no-op) but STILL carries
            // the configured placement options, so they apply the instant a block is
            // chosen. The tool clamps rows/cols to ≥ 1.
            let members = (pendingInsertBlockName?.isEmpty == false)
                ? blockMembersSnapshot() : [:]
            tool = InsertTool(
                blockName: pendingInsertBlockName,
                scale: insertScaleValue,
                rotation: insertRotation,
                rows: insertRows,
                cols: insertCols,
                rowSpacing: insertRowSpacing,
                colSpacing: insertColSpacing,
                previewMembers: members[pendingInsertBlockName ?? ""] ?? []
            )

        // MARK: Image tool — file path + source pixel size injected at construction

        case is ImageTool:
            // ImageTool's path + pixel size are fixed at construction (the picker reads
            // them from the file), so re-mint with the chosen file (the construction-
            // injection pattern InsertTool/ExplodeInsertTool use). With no path chosen
            // the tool is inert (a safe no-op) — the picker sets `imagePath` first.
            tool = ImageTool(path: imagePath,
                             pixelWidth: imagePixelWidth,
                             pixelHeight: imagePixelHeight)

        // MARK: Wire-wave-3 tool options

        case var t as AlignTool:
            t.scaleToFit = alignScaleToFit
            tool = t
        case var t as ArrayPathTool:
            // Preserve any path already picked this run; only update the dialog params.
            t.config = ArrayPathTool.Config(
                count: Swift.max(1, arrayPathCount),
                alignToTangent: arrayPathAlignToTangent,
                path: t.config.path
            )
            tool = t
        case var t as LeaderTool:
            // Empty text ⇒ a bare leader (the tool maps "" to no annotation).
            t.annotationText = leaderText.isEmpty ? nil : leaderText
            t.textHeight = Swift.max(InspectorEdits.minTextHeight, leaderTextHeight)
            tool = t
        case is BaselineDimTool:
            // BaselineDimTool clamps/stores `baselineSpacing` at construction, so
            // re-mint with the configured spacing (mirrors the DivideTool/ArcTool pattern).
            tool = BaselineDimTool(baselineSpacing: baselineSpacing)

        default:
            break
        }
    }

    /// Re-applies the Inspector's tool options to the CURRENTLY active tool (if it
    /// is one of the parameterized tools). The Inspector calls this when the user
    /// changes an option while the tool is already active, so the change takes
    /// effect on the next click without re-activating.
    func reapplyActiveToolConfig() {
        guard tool != nil else { return }
        let savedStatus = toolStatus
        applyToolConfig()
        // Some tools are RE-MINTED by `applyToolConfig` (DivideTool's count, Circle's
        // construction mode, ArcTool's mode, Line's angle mode, EllipseTool's mode,
        // BaselineDimTool's spacing, ImageTool's file, InsertTool's block + placement
        // options are fixed at construction), which resets their state/status to the
        // initial prompt. For those, take the fresh tool's status; for the in-place tools
        // (which keep their state) restore the prior prompt text. (InsertTool's status is
        // a pure function of its block name — preserved across the re-mint — so this is a
        // no-op for it today, but listing it keeps the set correct if it gains mid-run
        // state, per the review NIT.)
        if tool is DivideTool || tool is CircleTool || tool is ArcTool || tool is LineTool
            || tool is EllipseTool || tool is BaselineDimTool || tool is ImageTool
            || tool is InsertTool {
            toolStatus = tool?.status ?? ""
        } else {
            toolStatus = savedStatus
        }
    }

    /// Forwards a snapped world point as a tool input, applying any committed
    /// geometry to the drawing (undoable) and updating the spatial index. Returns
    /// `true` if the canvas should redraw (preview moved, geometry committed, or
    /// the tool finished). No-op (returns `false`) in select mode.
    @discardableResult
    func handleToolInput(_ input: ToolInput) -> Bool {
        guard tool != nil else { return false }
        let outcome = tool!.handle(input, context: makeToolContext())
        toolStatus = tool!.status

        // Track the relative-zero (UX-plan U1 / G7): a `.click`/`.value` is a point
        // placement, so the point the tool just consumed becomes the origin the
        // command line's `@dx,dy` / polar / bare-distance input measures from next.
        // (Done regardless of the outcome — even the first click of a Line returns
        // `.none` but still fixes the start point a typed `@10,0` should follow.)
        // SKIPPED when the relative-zero is LOCKED: the user pinned a datum, so it must
        // NOT auto-advance to the placed point (LibreCAD's locked relative zero).
        if !relativeZeroLocked {
            switch input {
            case .click(let p), .value(let p):
                if p.valid { relativeZero = p }
            default:
                break
            }
        }

        switch outcome {
        case .none:
            return false
        case .preview:
            return true
        case .commit(let edits):
            // Only genuine DRAW tools adopt the current properties; DERIVE/CLONE tools
            // (Copy/Array/Offset/…) preserve their source layer/pen. Keyed off the
            // active tool kind — see `toolAdoptsCurrentProperties`.
            applyCommit(edits, adoptsCurrentProperties: toolAdoptsCurrentProperties(activeToolKind))
            return true
        case .finished:
            // CreateBlockTool does NOT emit `.commit` edits — block creation touches
            // the BlockTable, which a `ToolEdit` cannot express. Instead it records a
            // `CreateBlockRequest` in `pendingCreation`, which the app applies here via
            // the undoable model op (`CADDrawing.makeBlockFromEntities`, ONE undoable
            // group). We read it from the just-finished tool BEFORE re-minting below
            // (the re-mint discards the request). A `.cancel` clears `pendingCreation`,
            // so a cancelled run applies nothing.
            applyPendingBlockCreationIfAny()
            // The run ended (commit/cancel). Mint a fresh tool of the same kind so
            // the user can immediately start the next run (LibreCAD keeps the tool
            // active after each line). To leave the tool entirely, the app calls
            // `activateTool(.select)`. Re-apply the Inspector's options so a chained
            // run keeps the configured values.
            tool = activeToolKind.makeTool()
            applyToolConfig()
            toolStatus = tool?.status ?? ""
            // The run is over — drop the relative-zero so the next run starts fresh,
            // UNLESS it is locked (a user-pinned datum persists across runs).
            if !relativeZeroLocked { relativeZero = nil }
            return true
        }
    }

    /// If the just-finished tool is a `CreateBlockTool` carrying a `pendingCreation`
    /// request, applies it via the undoable model op `CADDrawing.makeBlockFromEntities`
    /// (which removes the originals, registers the block, and drops one `.insert`, all
    /// as ONE undoable group — the `UndoManager` coalesces the inner calls made in this
    /// event). The new `.insert` becomes the selection so the user sees the result.
    /// Re-syncs the spatial index (the model op mutates `entities` directly, outside the
    /// quadtree-aware `applyCommit` path) and marks the GPU buffer dirty. No-op for any
    /// other tool / a cancelled run (`pendingCreation == nil`).
    ///
    /// This mirrors `applyCommit`'s "one undoable group" discipline but routes through
    /// the model op rather than `ToolEdit`s, because creating a block is a table
    /// mutation, not an entity-level edit (see CreateBlockTool's header).
    private func applyPendingBlockCreationIfAny() {
        guard let blockTool = tool as? CreateBlockTool,
              let request = blockTool.pendingCreation else { return }

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        let result = CreateBlockTool.apply(request, to: drawing)
        // The model op mutated `entities` directly (remove originals + add members +
        // add the insert); rebuild the quadtree so the result is immediately
        // snappable/selectable (the op doesn't touch the separate index).
        rebuildIndex()
        // Select the new INSERT so the user sees what replaced their selection.
        if let insertID = result?.insertID {
            selection = Selection(ids: [insertID])
        } else {
            selection.clear()
        }
        modelDirty = true
        modelVersion &+= 1
    }

    /// Builds a `blockName → [member EntityRecord]` snapshot (value copies) from the
    /// drawing's public block table, for injecting into `ExplodeInsertTool` (which is
    /// PURE and cannot reach the drawing). Mirrors the engine's internal
    /// `CADDrawing.blockMembersSnapshot()` (not part of the public API) using only
    /// public accessors: each non-frozen block's `entityIDs` resolved against the live
    /// entities. A member id no longer present is skipped.
    private func blockMembersSnapshot() -> [String: [EntityRecord]] {
        var map: [String: [EntityRecord]] = [:]
        for block in drawing.blocks.blocks where !block.isFrozen {
            map[block.name] = block.entityIDs.compactMap { drawing.entity($0) }
        }
        return map
    }

    // MARK: - Status bar readouts (UX-plan U3) — derived, formatted via the engine

    /// The drawing's display unit (`$INSUNITS`), for the status bar's unit suffix.
    var drawingUnit: DrawingUnit { drawing.graphicVariables.unit }

    /// The cursor's world position formatted as a unit-aware `"X 12.5   Y 8 mm"`
    /// readout (the document's linear format/precision + unit sign), or `nil` when
    /// the cursor is outside the canvas. Pure formatting via the engine's
    /// `CoordinateFormatter` so the status bar stays a thin view.
    var cursorReadout: String? {
        guard let w = cursorWorld else { return nil }
        let gv = drawing.graphicVariables
        return CoordinateFormatter.coordinatePair(
            x: w.x, y: w.y,
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
    }

    /// The signed `@Δx, Δy` offset of the cursor FROM the relative-zero (the last
    /// placed point), formatted with the document's linear format/precision, or `nil`
    /// when there is no relative-zero yet OR the cursor is outside. Lets the status
    /// bar show the relative coordinate while drawing (LibreCAD's relative readout).
    var relativeReadout: String? {
        guard let zero = relativeZero, let w = cursorWorld else { return nil }
        let gv = drawing.graphicVariables
        let dx = CoordinateFormatter.length(w.x - zero.x, format: gv.linearFormat, precision: gv.linearPrecision)
        let dy = CoordinateFormatter.length(w.y - zero.y, format: gv.linearFormat, precision: gv.linearPrecision)
        return "@\(dx), \(dy)"
    }

    /// The distance + bearing of the cursor FROM the relative-zero — the live
    /// "rubber-band" measurement while drawing (e.g. `"⟂ 14.14  ∠ 45°"`). `nil` when
    /// there is no relative-zero, the cursor is outside, or the two are coincident.
    /// Distance uses the document's linear format/precision + unit sign; the angle is
    /// shown in whole degrees (CCW from +X) for a compact, always-legible readout.
    var distanceAngleReadout: String? {
        guard let zero = relativeZero, let w = cursorWorld else { return nil }
        let d = w.distance(to: zero)
        guard d > 1e-9 else { return nil }
        let gv = drawing.graphicVariables
        let distStr = CoordinateFormatter.length(
            d, format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        let deg = (w - zero).angle * 180 / .pi
        let degStr = String(format: "%.0f", deg)
        return "\u{27C2} \(distStr)   \u{2220} \(degStr)\u{00B0}"
    }

    /// The relative-zero DATUM readout for the status bar: its world position formatted
    /// with the document's linear format/precision, plus a 🔒 marker when locked and a
    /// "(pick…)" hint while armed for a one-shot set. `nil` when no datum is set AND the
    /// canvas is neither armed nor locked (nothing to report). Distinct from
    /// `relativeReadout` (the cursor-relative offset) — this shows WHERE the datum is.
    var relativeZeroReadout: String? {
        if settingRelativeZeroArmed {
            return "RelZero: pick a point\u{2026}"
        }
        guard let zero = relativeZero else {
            return relativeZeroLocked ? "RelZero: locked" : nil
        }
        let gv = drawing.graphicVariables
        let pos = CoordinateFormatter.coordinatePair(
            x: zero.x, y: zero.y,
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
        let lock = relativeZeroLocked ? " \u{1F512}" : ""
        return "RelZero: \(pos)\(lock)"
    }

    /// The current snap mode's short label for the status bar's snap readout (e.g.
    /// "Endpoint" / "Grid"), or "—" when nothing is snapped. Distinct, capitalized
    /// names (vs the terse `coordinateHUD` chip) since the status bar has room.
    var snapReadout: String {
        guard let kind = snap?.kind else { return "\u{2014}" }
        switch kind {
        case .endpoint:     return "Endpoint"
        case .center:       return "Center"
        case .middle:       return "Midpoint"
        case .onEntity:     return "On entity"
        case .intersection: return "Intersection"
        case .nearest:      return "Nearest"
        case .perpendicular: return "Perpendicular"
        case .tangent:      return "Tangent"
        case .parallel:     return "Parallel"
        case .grid:         return "Grid"
        case .free:         return "Free"
        }
    }

    /// The current zoom as a percentage of 1:1 (1 world unit == 1 point), rounded to
    /// a whole percent — the status bar's zoom readout.
    var zoomPercent: Int { Int((viewport.scale * 100).rounded()) }

    /// The active tool + step prompt for the status bar's left segment, plus the
    /// always-on verb hints (Return / ⌫ / Esc) so the keyboard verbs (G4) are
    /// discoverable. Empty `toolStatus` ⇒ just the tool title; select mode ⇒ a
    /// neutral "Select" prompt so the bar is never blank.
    var toolStepReadout: String {
        guard isToolActive else { return "Select \u{2014} click to select, drag to pan" }
        let prompt = toolStatus.isEmpty ? "" : ": \(toolStatus)"
        return "\(activeToolKind.title)\(prompt)"
    }

    // MARK: - Crosshair cursor (UX-plan U3, gap G3)

    /// Whether the full-canvas crosshair cursor is drawn. ON whenever a draw/edit
    /// tool is active (the mode is then unmistakable — G3); the canvas reads this to
    /// show/hide the AppKit crosshair overlay and to hide the system arrow. A future
    /// "always show crosshair" setting can OR into this without touching call sites.
    var crosshairVisible: Bool { isToolActive }

    // MARK: - Command / coordinate line (UX-plan U1)

    /// A short hint of the input the active tool's current step expects, for the
    /// command field's placeholder/echo. Empty in select mode. Mirrors the tool's
    /// own `status` prompt plus the coordinate syntax so the field is
    /// self-documenting ("Specify next point — x,y / @dx,dy / dist<angle").
    var commandHint: String {
        guard isToolActive, !toolStatus.isEmpty else { return "" }
        return "\(activeToolKind.title): \(toolStatus) — x,y · @dx,dy · dist<angle"
    }

    /// Parses a command/coordinate string the user typed on the bottom field and,
    /// on success, feeds the resolved world point to the active tool as
    /// `ToolInput.value(point)` — exactly as a click at that exact coordinate would,
    /// with NO snap drift (the typed value is the truth). Uses the current
    /// `relativeZero` as the `@`/polar/distance origin and `cursorWorld` for the
    /// bare-distance bearing. Returns whether the canvas should redraw.
    ///
    /// On a parse error it stores `lastCommandError` (the field echoes it) and does
    /// NOT touch the tool. A no-op (false) in select mode (no tool to receive the
    /// point) or for empty input.
    @discardableResult
    func submitCommandText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard isToolActive else {
            lastCommandError = "Start a tool first (e.g. press L for Line)"
            return false
        }
        switch CommandParser.parse(trimmed, reference: relativeZero, cursor: cursorWorld) {
        case .point(let p):
            lastCommandError = nil
            return handleToolInput(.value(p))
        case .error(let message):
            lastCommandError = message
            return false
        }
    }

    /// Builds the read-only `ToolContext` snapshot for one `handle` call: the
    /// current selection resolved to records, a lookup into the drawing, the
    /// last-seen grid step, and the boundary hooks (`nearbyEntities` / `allEntities`)
    /// the editing tools (Trim / Extend / Fillet) read. Rebuilt per call so the tool
    /// always sees current state (cheap: the selection is usually small / empty
    /// while drawing).
    ///
    /// ## Why the closures are genuinely `@Sendable` (no `MainActor.assumeIsolated`)
    /// Every closure captures only an immutable VALUE snapshot of the drawing's
    /// `entities` (`snapshot`, a copy-on-write array — cheap, no deep copy) and the
    /// id-keyed `byID` map built from it. They touch no `self`, no actor state, and
    /// — crucially — NOT the live `quadtree` (a non-`Sendable`, main-actor `final
    /// class` that must never cross an isolation boundary). That makes the whole
    /// `ToolContext` honestly `Sendable` with no isolation assumption (CONVENTIONS:
    /// never `assumeIsolated` on a path the framework may invoke off-main).
    ///
    /// ## `nearbyEntities`: prefilter→exact, but over the value snapshot
    /// `Selection.hitTest` prefilters with the shared `quadtree`, then runs the
    /// exact analytic distance. Here the closure can't hold the quadtree
    /// (non-Sendable) and the (point, tolerance) aren't known until the tool calls
    /// it, so it runs the EXACT analytic distance test (`HitTesting.worldDistance`)
    /// over the captured snapshot directly — correct (a returned entity really is
    /// under the pick), skipping only the cheap AABB prefilter. Tool picks are
    /// infrequent and drawings settle small enough that the linear scan is fine for
    /// the editing-tool foundation; a future hot path can capture an immutable
    /// snapshot index here WITHOUT changing the `ToolContext` contract.
    private func makeToolContext() -> ToolContext {
        let snapshot = drawing.entities          // CoW value snapshot (Sendable)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        let selected = selection.ids.compactMap { byID[$0] }
        return ToolContext(
            selected: selected,
            entity: { id in byID[id] },
            gridSpacing: lastGridSpacing,
            nearbyEntities: { point, tolerance in
                guard point.valid else { return [] }
                let tol = Swift.max(tolerance, 0)
                return snapshot.filter { record in
                    // Skip what you can't see (mirrors hitTest's `.visible` gate).
                    guard record.flags.contains(.visible) else { return false }
                    return HitTesting.worldDistance(from: point, to: record) <= tol
                }
            },
            allEntities: { snapshot }
        )
    }

    /// The DERIVE / CLONE tool kinds — the modify tools whose `.add` edits carry an
    /// EXISTING source entity's `layer` + `pen` verbatim (Copy/Array/Offset/Explode/
    /// Join/Divide/Break/Fillet/Chamfer/Duplicate/…). A clone like this must PRESERVE
    /// its source's layer/pen (AutoCAD COPY/ARRAY/OFFSET preserve the source layer),
    /// so it must NOT be re-stamped with the active layer / current pen — even when the
    /// source happens to sit on layer "0" with a `.byLayer` pen (the fresh-document
    /// default), which is exactly the case the record-content gate alone cannot tell
    /// apart from a fresh draw. See `toolAdoptsCurrentProperties` and the stamp in
    /// `applyCommit`'s `.add` arm.
    ///
    /// This is the SMALL, well-bounded set; the default (any OTHER kind) is to adopt
    /// the current properties, so new geometry-from-scratch DRAW tools keep landing on
    /// the active layer automatically with no edit here. A future tool that emits
    /// `.add` records COPIED from an existing entity (i.e. that should preserve the
    /// source layer/pen) MUST add its `ToolKind` to this set.
    ///
    /// Kept entirely app-side (keyed off the `ToolKind` the model already holds in
    /// `activeToolKind`) so no engine `Tool`/`ToolEdit` type needs an intent flag.
    private static let deriveToolKinds: Set<ToolKind> = [
        .copy, .move, .rotate, .scale, .mirror, .align, .stretch,
        .array, .arrayPath, .offset, .divide,
        .explode, .explodeText, .explodeInsert, .join,
        .trim, .extend, .fillet, .chamfer, .lengthen, .break, .polylineEdit,
        .hatch,
    ]

    /// Whether geometry committed by tool `kind` should adopt the CURRENT properties
    /// (active layer + `currentPen`). True for genuine geometry-from-scratch DRAW
    /// tools; false for the DERIVE/CLONE modify tools (`deriveToolKinds`), whose
    /// `.add` records must preserve the source entity's layer/pen. `.select` and
    /// `.viewport` never emit `.add` geometry through this path, so their value is
    /// immaterial (they default to `true`, harmlessly).
    private func toolAdoptsCurrentProperties(_ kind: ToolKind) -> Bool {
        !Self.deriveToolKinds.contains(kind)
    }

    /// Applies a tool's committed edits to the drawing as ONE undoable group, so a
    /// single undo reverts the whole tool action. Each edit is applied through the
    /// undoable `CADDrawing` mutations (ADR-002) and mirrored into the quadtree so
    /// the result is immediately snappable/selectable; the GPU model buffer is
    /// marked dirty so the renderer repacks it.
    ///
    /// `adoptsCurrentProperties` gates the current-properties STAMP in the `.add` arm:
    /// pass `true` only when the edits come from a genuine DRAW (geometry built from
    /// scratch, which should land on the active layer + `currentPen`), and `false` for
    /// DERIVE/CLONE edits (Copy/Array/Offset/…), which must keep their source layer/pen.
    /// Callers compute it from the originating tool via `toolAdoptsCurrentProperties`.
    ///
    /// Quadtree consistency: the `add`/`replace`/`remove` here keep the index in
    /// sync directly. On undo/redo the drawing's value-snapshot restore does NOT
    /// touch the quadtree (the undo closures only know about `entities`), so
    /// `undo()`/`redo()` rebuild the whole index — see those methods.
    private func applyCommit(_ edits: [ToolEdit], adoptsCurrentProperties: Bool) {
        guard !edits.isEmpty else { return }

        // Make the whole commit ONE undo step. UndoManager's default
        // `groupsByEvent == true` already coalesces registrations made within a
        // single run-loop event (a tool commit is applied synchronously in one
        // event), so the edits group automatically in the running app. When
        // grouping-by-event is off (e.g. a unit test driving applyCommit directly,
        // with no run loop) we open an explicit group so one undo still reverts the
        // entire commit rather than one edit at a time.
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        for edit in edits {
            switch edit {
            case .add(let record):
                // Strip the persisted `.selected` flag from any added record so new
                // geometry never arrives pre-selected. Selection is tracked view-side
                // in `selection` (a separate Set) — the live app never sets the flag —
                // but a MODIFY tool that ADDs copies (CopyTool) clones the original's
                // `flags`, and a record loaded with the bit set could carry it. We do
                // NOT add the new id to `selection`, so a copy stays unselected
                // regardless; clearing the flag keeps the persisted state honest too.
                var added = record
                added.flags.remove(.selected)
                // CURRENT-PROPERTIES STAMP (AutoCAD CECOLOR/CELTYPE/CELWEIGHT + CLAYER):
                // a freshly DRAWN record arrives with the EntityRecord init defaults —
                // `layer == .zero` (DXF "0") and a fully `.byLayer` `pen` — because draw
                // tools build `EntityRecord(id:.placeholder, kind:…)` without setting
                // either. We stamp such a record with the ACTIVE layer and the CURRENT
                // pen so new geometry lands on the layer the user picked (this also fixes
                // the long-standing bug where every drawn entity went to layer "0"
                // regardless of the active layer) and adopts the top-bar current pen.
                //
                // The gate has TWO conditions and BOTH must hold:
                //   1. `adoptsCurrentProperties` — the edits came from a genuine DRAW,
                //      NOT a DERIVE/CLONE tool. This is the TRUE boundary. A clone
                //      (Copy/Array/Offset/Explode/…) copies its SOURCE's `layer`+`pen`
                //      verbatim and must keep them — AutoCAD COPY/ARRAY/OFFSET preserve
                //      the source layer. Crucially this holds EVEN when the source sits
                //      on layer "0" with a `.byLayer` pen (the fresh-doc default): such a
                //      clone is content-identical to a fresh draw, so the content check
                //      below cannot distinguish them — only the originating operation can.
                //      (Computed app-side from the active `ToolKind`; see
                //      `toolAdoptsCurrentProperties` / `deriveToolKinds`.)
                //   2. the record still carries the init defaults (`layer == .zero` &&
                //      `pen == .byLayer`) — so a DRAW tool that ever set an explicit
                //      layer/pen itself would be left untouched (none do today).
                if adoptsCurrentProperties && added.layer == .zero && added.pen == Pen.byLayer {
                    added.layer = LayerID(drawing.layers.activeLayerName)
                    added.pen = currentPen
                }
                let id = drawing.add(added)            // undoable; mints a real id
                let box = drawing.entity(id)?.boundingBox() ?? added.boundingBox()
                if !box.isEmpty { quadtree.insert(id, bounds: box) }
                // BLOCK EDITOR: any geometry drawn (or copied) while a block-edit
                // session is open becomes a MEMBER of the editing block — not a loose
                // top-level document entity. We thread the freshly-minted id into the
                // editing block's `entityIDs` in this SAME undo group (the
                // `addEntityToBlock` registration nests with the add's), and BEFORE the
                // `modelVersion` bump below so `exitBlockEditing`'s `sessionChanged`
                // detection counts it. The new member is then excluded from model space
                // via `blockMemberIDs` and drawn only through the block's inserts.
                if let editing = editingBlock {
                    drawing.addEntityToBlock(name: editing, entityID: id)
                }

            case .replace(let id, let newKind):
                // Preserve the entity's layer/pen/flags; swap only its geometry.
                guard var record = drawing.entity(id) else { continue }
                record.kind = newKind
                drawing.replace(record)                // undoable
                let box = record.boundingBox()
                if box.isEmpty { quadtree.remove(id) } else { quadtree.update(id, bounds: box) }

            case .remove(let id):
                // BLOCK EDITOR: deleting a member must also drop its id from the editing
                // block's `entityIDs` (same undo group as the entity removal) so the
                // block's membership stays in sync — otherwise the block would keep a
                // stale id that resolves to nothing. Do this BEFORE `drawing.remove` so
                // the member record still exists for any membership checks, and inside
                // the same group so one ⌘Z restores both the entity and its membership.
                if let editing = editingBlock {
                    drawing.removeEntityFromBlock(name: editing, entityID: id)
                }
                drawing.remove(id)                     // undoable (no-op if absent)
                quadtree.remove(id)
                selection.remove(id)
            }
        }
        modelDirty = true
        modelVersion &+= 1
    }

    /// Applies tool edits produced OUT-OF-BAND (not via the model's internal active
    /// tool) through the SAME undoable `applyCommit` path — one undoable group,
    /// quadtree kept in sync, GPU buffer marked dirty. This is NOT a parallel commit
    /// implementation: it is the single public entry the **inline text editor** uses
    /// to commit a `TextTool` it ran itself (the typed string is collected by the
    /// `NSTextView` overlay in `CADCanvasView`, which builds + runs a `TextTool`
    /// value and hands the resulting edits here). The model's own `handleToolInput`
    /// path can't carry the editor's string into the private(set) active tool, so the
    /// overlay needs this one delegating hook; everything downstream is the existing
    /// `applyCommit` (no behavior fork). No-op on an empty list.
    func applyToolEdits(_ edits: [ToolEdit]) {
        // The inline text editor is a genuine DRAW (new `.text`/`.mtext` should adopt
        // the active layer + current pen). Editing existing text emits `.replace`,
        // which never touches the stamp, so `true` is correct for both sub-cases.
        applyCommit(edits, adoptsCurrentProperties: true)
    }

    // MARK: - Inspector edits (full-record replace; undoable; index-synced)

    /// Applies one or more FULL-RECORD replacements (the Inspector path), as ONE
    /// undoable group. Unlike a tool's `.replace(id, kind)` (geometry only), an
    /// inspector edit may change ANY common attribute — the layer, the pen
    /// (color/line type/width), the flags — as well as the geometry, so it carries
    /// the whole `EntityRecord`. Each replace goes through the undoable
    /// `CADDrawing.replace` (ADR-002) and is mirrored into the quadtree so the
    /// result stays snappable/selectable; the GPU buffer is marked dirty so the
    /// renderer repacks. A single undo reverts the whole edit (e.g. setting the
    /// layer of a multi-selection). Records whose id is not in the drawing are
    /// skipped. No-op (no undo step) for an empty list.
    func applyInspectorEdits(_ records: [EntityRecord]) {
        guard !records.isEmpty else { return }

        // One undo step for the whole inspector commit (same grouping rationale as
        // `applyCommit`: groups-by-event in the live app, explicit group in tests).
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        for record in records {
            guard drawing.contains(record.id) else { continue }
            drawing.replace(record)                 // undoable; preserves id
            let box = record.boundingBox()
            if box.isEmpty { quadtree.remove(record.id) }
            else { quadtree.update(record.id, bounds: box) }
        }
        modelDirty = true
        modelVersion &+= 1
    }

    /// Convenience: replace a single entity's GEOMETRY (its `kind`) while keeping
    /// every other attribute — the common Inspector geometry-field path. Looks the
    /// record up, swaps its `kind`, and applies via `applyInspectorEdits`.
    func replaceEntityKind(_ id: EntityID, _ kind: EntityKind) {
        guard var record = drawing.entity(id) else { return }
        record.kind = kind
        applyInspectorEdits([record])
    }

    /// Applies a TEXT/MTEXT font/style edit as ONE undoable group: upserts a
    /// derived `TextStyle` into the document's STYLE table (so bold/italic/family
    /// render via the resolve path) AND repoints the entity at it (`newKind` carries
    /// the new `styleName`). The STYLE table is a plain `var` (no `CADDrawing`
    /// mutator for it), so its undo is registered manually here, grouped with the
    /// entity replace's own undo — a single undo reverts both the style insertion
    /// and the entity's style pointer.
    ///
    /// When `style` is `nil` this is just a per-entity text edit (no style change)
    /// and behaves like `replaceEntityKind`.
    func applyTextStyleEdit(_ id: EntityID, kind: EntityKind, upserting style: TextStyle?) {
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        if let style {
            let prior = drawing.textStyles
            drawing.textStyles.upsert(style)
            registerTextStylesUndo(prior: prior)
        }
        replaceEntityKind(id, kind)
    }

    /// Registers a self-re-registering undo that restores the whole STYLE table to
    /// `prior` (and, on redo, restores whatever it replaced) — the value-snapshot
    /// pattern `CADDrawing` uses for its layer/block tables, but owned here because
    /// `CADDrawing.textStyles` has no dedicated undoable mutator.
    private func registerTextStylesUndo(prior: TextStyleTable) {
        undoManager.registerUndo(withTarget: self) { model in
            // UndoManager invokes on the main thread for document apps.
            MainActor.assumeIsolated {
                let current = model.drawing.textStyles
                model.drawing.textStyles = prior
                model.registerTextStylesUndo(prior: current)   // redo restores `current`
                model.modelDirty = true
                model.modelVersion &+= 1
            }
        }
    }

    // MARK: - Live blocks panel ops (F9 sidebar — insert / rename / delete)

    /// Inserts a reference (`.insert`) to the named block at a WORLD point, as ONE
    /// undoable `.add` (the same path tools use). The new INSERT inherits the active
    /// layer + a `.byLayer` pen and becomes the selection so the user sees the
    /// placement. No-op (returns `false`) if the block is unknown. The Blocks sidebar
    /// calls this for click-to-insert / drag-to-place (the drop point is the world
    /// location). Re-syncs the spatial index via `applyCommit`'s `.add` arm so the
    /// insert is immediately selectable / snappable.
    @discardableResult
    func insertBlock(named name: String, at point: Vector) -> Bool {
        guard drawing.blocks.contains(name) else { return false }
        let record = EntityRecord(
            id: .placeholder,
            layer: LayerID(drawing.layers.activeLayerName),
            pen: .byLayer,
            flags: .default,
            kind: .insert(InsertData(blockName: name, insertionPoint: point))
        )
        // Add through the undoable group + capture the minted id for selection.
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        let id = drawing.add(record)             // undoable; mints a real id
        let box = drawing.entity(id)?.boundingBox() ?? record.boundingBox()
        if !box.isEmpty { quadtree.insert(id, bounds: box) }
        selection = Selection(ids: [id])
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// Inserts a reference to the named block at the current view CENTER (world), the
    /// menu/sidebar "Insert" action's default placement when there is no drop point.
    @discardableResult
    func insertBlockAtViewCenter(named name: String) -> Bool {
        let centerScreen = CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2)
        return insertBlock(named: name, at: viewport.screenToWorld(centerScreen))
    }

    // MARK: - WAVE BW (block UI wiring): create / insert / double-click-to-edit

    /// Begins a Create-Block-from-selection run with the chosen `name` (WAVE BW, Ask #1).
    /// The View-layer name sheet (`BlockNamePrompt`) calls this after the user confirms a
    /// name (gated on a non-empty selection): it stores the name in `pendingCreateBlockName`
    /// and activates the `.createBlock` tool, which `applyToolConfig` then re-mints as a
    /// `CreateBlockTool(blockName:)`. The user then picks a base point on the canvas; the
    /// out-of-band CreateBlock path (`applyPendingBlockCreationIfAny`) folds the selection
    /// into the named block and replaces it with one insert. A blank/whitespace name falls
    /// back to the default (de-duplicated by the model op). Returns `true` if there is a
    /// selection to block (else a no-op — the sheet should not appear without one).
    @discardableResult
    func beginCreateBlock(name: String) -> Bool {
        guard !selection.isEmpty else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingCreateBlockName = trimmed.isEmpty ? nil : trimmed
        activateTool(.createBlock)
        return true
    }

    /// Begins an Insert run that places references to the existing block `name` (WAVE BW,
    /// Ask #3 optional): stores it in `pendingInsertBlockName` and activates the `.insert`
    /// tool, which `applyToolConfig` re-mints as `InsertTool(blockName:previewMembers:)`
    /// (so the rubber-band preview shows the block). The user then clicks the placement
    /// point. A blank name / unknown block leaves the tool inert. Returns `true` if the
    /// block exists.
    @discardableResult
    func beginInsert(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, drawing.blocks.contains(trimmed) else {
            pendingInsertBlockName = nil
            return false
        }
        pendingInsertBlockName = trimmed
        activateTool(.insert)
        return true
    }

    /// The block name of an `.insert` entity under `world` (within the selection-hit
    /// tolerance), or `nil` if no block reference is there (WAVE BW, Ask #2). The pure,
    /// testable core of the double-click-to-edit gesture: the canvas converts the cursor
    /// to a world point, calls this, and — if non-nil — enters that block's editor. Uses
    /// the SAME hit-test the click/selection path uses (so a double-click resolves the
    /// same entity a single click would select), then keeps only `.insert` records.
    func blockNameOfInsert(at world: Vector) -> String? {
        guard let id = selection.hitTest(
            worldPoint: world,
            worldTolerance: worldTolerance,
            in: drawing,
            using: quadtree
        ), let record = drawing.entity(id),
            case .insert(let data) = record.kind else { return nil }
        return data.blockName
    }

    /// A default suggested name for a NEW block, of the form `Block-N` where `N` is the
    /// smallest positive integer making the name unique in the block table (WAVE BW,
    /// Ask #1). Seeds the `BlockNamePrompt` sheet so the user gets a sensible, unique
    /// prefilled name they can accept or override.
    func suggestedBlockName() -> String {
        var n = drawing.blocks.blocks.count + 1
        while drawing.blocks.contains("Block-\(n)") { n += 1 }
        return "Block-\(n)"
    }

    /// Renames a block definition (undoable). Existing `.insert`s referencing the old
    /// name are re-pointed so they keep resolving. Returns `true` on success. The
    /// sidebar calls this from the inline-rename field.
    @discardableResult
    func renameBlock(_ oldName: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName,
              drawing.blocks.contains(oldName), !drawing.blocks.contains(trimmed) else { return false }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        // Re-point every INSERT that referenced the old name (each undoable).
        for e in drawing.entities {
            guard case .insert(var data) = e.kind, data.blockName == oldName else { continue }
            data.blockName = trimmed
            var moved = e
            moved.kind = .insert(data)
            drawing.replace(moved)
            let box = moved.boundingBox()
            if box.isEmpty { quadtree.remove(moved.id) } else { quadtree.update(moved.id, bounds: box) }
        }
        let ok = drawing.renameBlock(oldName, to: trimmed)
        modelDirty = true
        modelVersion &+= 1
        return ok
    }

    /// Deletes a block definition (undoable). Any `.insert` referencing it is removed
    /// too (a dangling insert would resolve to nothing), so the deletion is coherent;
    /// the block's MEMBER entities are also removed (they exist only to back the
    /// definition). The whole op is one undo group. Returns `true` if the block
    /// existed. The sidebar calls this from the remove button.
    @discardableResult
    func deleteBlock(named name: String) -> Bool {
        guard drawing.blocks.contains(name) else { return false }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        // Remove every INSERT that referenced this block (each undoable + index-synced).
        let referencing = drawing.entities.filter {
            if case .insert(let d) = $0.kind { return d.blockName == name }
            return false
        }
        for e in referencing {
            drawing.remove(e.id)
            quadtree.remove(e.id)
            selection.remove(e.id)
        }
        // Drop the definition AND its backing member entities (deletingContents).
        let members = drawing.blocks.block(named: name)?.entityIDs ?? []
        drawing.removeBlock(name, deletingContents: true)
        for id in members { quadtree.remove(id); selection.remove(id) }
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    // MARK: - Block freeze / visibility (sidebar eye-toggle + Freeze-all/Thaw-all)
    //
    // Thin model wrappers over the engine's undoable `CADDrawing` freeze ops
    // (`setBlockFrozen` / `toggleBlockFrozen` / `freezeAllBlocks` / `thawAllBlocks`).
    // A frozen block's `.insert` resolves to EMPTY geometry, so every reference of it
    // disappears from the canvas + becomes un-snappable.
    //
    // Each wrapper GATES on an actual change FIRST (mirroring `renameBlock`/`deleteBlock`):
    // a no-op returns before any work, so it opens no undo group, registers no undo, and
    // skips the index rebuild. On a real change it opens an explicit undo group when the
    // host undo manager is not auto-grouping by event (the test/headless config) so the
    // engine op's `registerUndo` is legal, runs the op, then rebuilds the spatial index
    // (a frozen insert's ctx-aware bounding box collapses to its insertion point, so the
    // quadtree must resync) and bumps `modelVersion` so the sidebar AND the renderer
    // recompute. The post-op index/version work is view-side state, not undoable.

    /// Toggles a block's frozen flag (undoable; the sidebar's per-row eye toggle). A
    /// frozen block becomes invisible (its inserts resolve empty). No-op (no undo, no
    /// redraw) for an unknown block. Rebuilds the index + bumps `modelVersion`.
    func toggleBlockFrozen(_ name: String) {
        guard let block = drawing.blocks.block(named: name) else { return }
        applyBlockFreezeChange { $0.setBlockFrozen(name, !block.isFrozen) }
    }

    /// Sets a block's frozen flag explicitly (undoable). No-op (no undo, no redraw) for
    /// an unknown block or a redundant value (already at `frozen`).
    func setBlockFrozen(_ name: String, _ frozen: Bool) {
        guard let block = drawing.blocks.block(named: name), block.isFrozen != frozen
        else { return }
        applyBlockFreezeChange { $0.setBlockFrozen(name, frozen) }
    }

    /// Freezes every NAMED block in ONE undoable step (the Blocks panel ⋯ "Freeze All
    /// Blocks"). Anonymous `*`-blocks are skipped by the engine op. No-op (no undo, no
    /// redraw) when every named block is already frozen (or there are none).
    func freezeAllBlocks() {
        guard hasNamedBlock(frozen: false) else { return }   // something to freeze
        applyBlockFreezeChange { $0.freezeAllBlocks() }
    }

    /// Thaws every NAMED block in ONE undoable step ("Thaw All Blocks"). No-op (no undo,
    /// no redraw) when every named block is already thawed (or there are none).
    func thawAllBlocks() {
        guard hasNamedBlock(frozen: true) else { return }    // something to thaw
        applyBlockFreezeChange { $0.thawAllBlocks() }
    }

    /// Whether any NAMED (non-`*`) block is currently at the given frozen state — the
    /// change-gate for `freezeAllBlocks`/`thawAllBlocks` (anonymous `*`-blocks are the
    /// system blocks the engine op skips, so they don't count toward "something to do").
    private func hasNamedBlock(frozen: Bool) -> Bool {
        drawing.blocks.blocks.contains { !$0.name.hasPrefix("*") && $0.isFrozen == frozen }
    }

    /// Runs a guaranteed-changing block-freeze op through the engine in ONE undoable step
    /// (opening an explicit group when the undo manager is not auto-grouping by event),
    /// then resyncs the spatial index + bumps the model/render version. Callers MUST gate
    /// on an actual change before calling (so this never opens an empty group / registers
    /// a stray undo for a no-op).
    private func applyBlockFreezeChange(_ op: (CADDrawing) -> Void) {
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        op(drawing)
        rebuildIndex()
        modelDirty = true
        modelVersion &+= 1
    }

    // MARK: - Dynamic blocks — visibility states (DB-1W wiring)
    //
    // The UI funnel for dynamic-block VISIBILITY STATES (block-features §9). Authoring
    // (create / rename / delete a state; show/hide selected members in the current
    // authoring state) runs INSIDE the in-place Block Editor (`editingBlock`) and routes
    // through the engine's undoable `CADDrawing` mutators. The INSTANCE side switches a
    // placed insert's active state through the same undoable inspector funnel
    // (`applyInspectorEdits`) the gizmo/Inspector use — re-resolving shows the variant.
    // All modal/menu presentation stays in the View layer (overlay + Inspector); these
    // methods are pure model logic so they unit-test headless.

    /// The single selected entity that is a DYNAMIC-block insert — `nil` unless exactly
    /// one entity is selected AND it is an `.insert` whose referenced block carries
    /// visibility states. This is the gate BOTH the on-canvas dropdown grip
    /// (`DynamicGripOverlay`) and the Inspector's active-state picker read, and the
    /// arbitration input that suppresses the transform gizmo (`shouldSuppressGizmoForSelection`).
    var singleSelectedDynamicInsert: (id: EntityID, blockName: String, states: [BlockVisibilityState], active: String?)? {
        guard selection.ids.count == 1, let id = selection.ids.first,
              let record = drawing.entity(id), case .insert(let data) = record.kind,
              let block = drawing.blocks.block(named: data.blockName),
              let def = block.dynamic, !def.visibilityStates.isEmpty
        else { return nil }
        return (id, data.blockName, def.visibilityStates, data.dynamic?.activeVisibilityState)
    }

    /// The arbitration decision for the dual-overlay critic must-fix: when the single
    /// selection is a dynamic insert, the transform gizmo is SUPPRESSED and ONLY the
    /// dynamic-grip overlay shows (no undefined hit-test precedence between two
    /// transparent overlays); for ANY other selection the gizmo behaves as today. Pure
    /// (reads selection + drawing only) so the canvas controller's `refreshGizmo` can
    /// branch on it and a test can assert the decision without any NSView/NSMenu.
    ///
    /// DB-2W broadens the trigger: a single insert whose block carries ANY dynamic
    /// authoring — visibility states (DB-1) OR linear/flip PARAMETERS (DB-2) — suppresses
    /// the gizmo, so the parameter grips (square stretch / triangle flip) own the
    /// manipulation instead of the bounding-box gizmo.
    var shouldSuppressGizmoForSelection: Bool { singleSelectedDynamicInsertID != nil }

    /// The id of the single selected `.insert` whose block carries ANY dynamic authoring
    /// (visibility states OR parameters) — the gate for suppressing the gizmo and showing
    /// the dynamic-grip overlay (DB-2W). `nil` unless EXACTLY one entity is selected and it
    /// is such an insert. Broader than `singleSelectedDynamicInsert` (which is
    /// visibility-specific) so a parameters-only dynamic block still gets its grips.
    var singleSelectedDynamicInsertID: EntityID? {
        guard selection.ids.count == 1, let id = selection.ids.first,
              let record = drawing.entity(id), case .insert(let data) = record.kind,
              let block = drawing.blocks.block(named: data.blockName),
              let def = block.dynamic, !def.isEmpty
        else { return nil }
        return id
    }

    /// Switches a placed `.insert`'s ACTIVE visibility state (block-features §9.4) — the
    /// path the on-canvas dropdown grip and the Inspector picker both trigger. Writes
    /// `InsertData.dynamic.activeVisibilityState` through the SAME undoable funnel the
    /// Inspector/gizmo use (`applyInspectorEdits` → record replace), so one ⌘Z reverts
    /// it and the re-resolve immediately shows the new variant. Passing `nil` resets the
    /// insert to the block's DEFAULT state (state 0). A no-op (false) if `id` is not an
    /// insert or the state is already active. Engine-pure (no UI / no modal).
    @discardableResult
    func setInsertVisibilityState(_ id: EntityID, to stateName: String?) -> Bool {
        guard var record = drawing.entity(id), case .insert(var data) = record.kind else { return false }
        var state = data.dynamic ?? InsertDynamicState()
        guard state.activeVisibilityState != stateName else { return false } // redundant → no-op
        state.activeVisibilityState = stateName
        data.dynamic = state
        record.kind = .insert(data)
        applyInspectorEdits([record])
        return true
    }

    // MARK: - Dynamic blocks — PARAMETER GRIPS (DB-2W instance live-drag)
    //
    // The on-canvas INSTANCE grips for a selected dynamic insert (block-features §5.2.2
    // linear / §5.2.7 flip, §13.5 grips): a SQUARE stretch grip at each linear
    // parameter's `end` (live-DRAG → new distance) and a TRIANGLE flip grip on each flip
    // parameter's line (CLICK → toggle). The pure model below mirrors the gizmo's
    // preview-then-commit shape (`gizmoPreviewPolylines`/`commitGizmoTransform`): the
    // overlay (`DynamicGripOverlayView`) does ONLY screen↔world + hit-test + the drag
    // lifecycle; every value mapping, the live re-resolve preview, and the undoable write
    // live here as pure model logic so they unit-test headless (no NSView / no NSMenu).

    /// One instance grip on a selected dynamic insert, anchored in WORLD coordinates (the
    /// parameter's defining points run through the insert's placement transform). The
    /// overlay enumerates these to draw + hit-test the grips; the value/commit math keys
    /// off `parameterID`.
    enum DynamicInstanceGrip: Equatable {
        /// A SQUARE stretch grip at a LINEAR parameter's `end` (world). Dragging it sets a
        /// new distance along the parameter direction. `base`/`end` are the world-mapped
        /// parameter segment endpoints (so the overlay can project the cursor onto the
        /// direction); `baseDistance` is the parameter's default (LOCAL) distance;
        /// `directionScale` is the local→world length scale along the parameter direction
        /// (`|t.applyLinear(localUnitDir)|`), so a world-projected distance divides by it to
        /// recover the LOCAL distance stored in `parameterValues` — correct under a non-unit
        /// `InsertData.scale` (a pure rotation has `directionScale == 1`).
        case stretch(parameterID: BlockParameterID, base: Vector, end: Vector,
                     baseDistance: Double, directionScale: Double)
        /// A TRIANGLE flip grip at a FLIP parameter's line midpoint (world). Clicking it
        /// toggles the instance flip state. `lineStart`/`lineEnd` are the world-mapped
        /// reflection-line endpoints (so the overlay can orient the triangle).
        case flip(parameterID: BlockParameterID, lineStart: Vector, lineEnd: Vector, isFlipped: Bool)

        /// The grip's world ANCHOR (where the handle is drawn + hit-tested).
        var anchor: Vector {
            switch self {
            case .stretch(_, _, let end, _, _): return end
            case .flip(_, let s, let e, _):     return Vector((s.x + e.x) * 0.5, (s.y + e.y) * 0.5)
            }
        }
    }

    /// The insert's local→world placement transform on the FIRST MINSERT cell — the SAME
    /// `translate(insertionPoint) ∘ rotate(rotation) ∘ scale(scale)` the resolve uses
    /// (`Resolve.insertTransform`, which is module-internal, so reconstructed here from the
    /// public `InsertData` fields). Parameter defining points are authored in the block's
    /// LOCAL frame (same space as the members), so this maps them to where the grip draws.
    /// A degenerate (zero) scale axis is clamped away from 0 (matching the resolve).
    private static func instancePlacementTransform(_ d: InsertData) -> Affine2D {
        let eps = 1e-9
        let sx = abs(d.scale.x) < eps ? (d.scale.x < 0 ? -eps : eps) : d.scale.x
        let sy = abs(d.scale.y) < eps ? (d.scale.y < 0 ? -eps : eps) : d.scale.y
        let scale = Affine2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
        let rotate = Affine2D.rotation(angle: d.rotation)
        let translate = Affine2D.translation(d.insertionPoint)
        return translate * rotate * scale
    }

    /// The instance grips for the single selected dynamic insert, anchored in WORLD
    /// coordinates — `nil` unless exactly one dynamic insert is selected. One SQUARE
    /// stretch grip per LINEAR parameter (anchored at its world-mapped `end`) and one
    /// TRIANGLE flip grip per FLIP parameter (anchored at its line midpoint). The grips
    /// reflect the insert's CURRENT instance values (the dragged distance, the flip flag)
    /// so they sit where the live geometry is. Pure (reads selection + drawing only).
    var singleSelectedDynamicInsertGrips: (id: EntityID, grips: [DynamicInstanceGrip])? {
        guard selection.ids.count == 1, let id = selection.ids.first,
              let record = drawing.entity(id), case .insert(let data) = record.kind,
              let block = drawing.blocks.block(named: data.blockName),
              let def = block.dynamic, !def.parameters.isEmpty
        else { return nil }
        let t = Self.instancePlacementTransform(data)
        var grips: [DynamicInstanceGrip] = []
        for param in def.parameters {
            switch param {
            case .linear(let pid, _, let base, let end):
                let baseDist = param.baseDistance ?? (end - base).magnitude
                // Where the grip currently sits: the parameter's `end` advanced/retracted
                // to the CURRENT distance along the (local) direction, then world-mapped.
                let current = data.dynamic?.parameterValues[pid.raw] ?? baseDist
                let localEnd: Vector
                // The local→world length scale ALONG the parameter direction, so the drag
                // can convert a world projection back to the LOCAL distance under scaling.
                var dirScale = 1.0
                if let dir = param.unitDirection {
                    localEnd = Vector(base.x + dir.x * current, base.y + dir.y * current)
                    let mapped = t.applyLinear(dir)         // local unit dir → world
                    let m = mapped.magnitude
                    dirScale = (m.isFinite && m > Tolerance.distance) ? m : 1.0
                } else {
                    localEnd = end
                }
                grips.append(.stretch(parameterID: pid,
                                      base: t.apply(base),
                                      end: t.apply(localEnd),
                                      baseDistance: baseDist,
                                      directionScale: dirScale))
            case .flip(let pid, _, let lineStart, let lineEnd):
                let flipped = data.dynamic?.flipStates[pid.raw] ?? false
                grips.append(.flip(parameterID: pid,
                                   lineStart: t.apply(lineStart),
                                   lineEnd: t.apply(lineEnd),
                                   isFlipped: flipped))
            }
        }
        return grips.isEmpty ? nil : (id, grips)
    }

    /// The new LOCAL DISTANCE a stretch grip drag yields (the value written into
    /// `parameterValues`, which the evaluator interprets in BLOCK-LOCAL space). The cursor's
    /// world point is projected onto the (world) parameter direction measured from the
    /// parameter's world BASE, then divided by the grip's `directionScale` (the local→world
    /// length scale along that direction) so a non-unit `InsertData.scale` is handled
    /// correctly — for a pure rotation `directionScale == 1` and this is just the world
    /// projection. The pure drag→value mapping (analogous to `GizmoTransform.move`).
    /// Returns `nil` for a degenerate parameter direction. The result is clamped
    /// non-negative (a linear parameter's distance cannot go past its base point — a
    /// negative projection clamps to 0, matching AutoCAD's linear-stretch behavior).
    func stretchDistance(forGrip grip: DynamicInstanceGrip, cursorWorld: Vector) -> Double? {
        guard case .stretch(_, let base, _, _, let directionScale) = grip else { return nil }
        let scale = (directionScale.isFinite && directionScale > Tolerance.distance) ? directionScale : 1.0
        // Use the CURRENT (world) grip direction base→end; if the grip is at base
        // (current distance 0) the direction is ill-defined, so fall back to a tiny step.
        let dir = grip.anchor - base
        let len = dir.magnitude
        guard len > Tolerance.distance else {
            // Direction unknown (grip on the base). Project onto the cursor offset itself
            // so a fresh drag still produces a sensible (positive) LOCAL distance.
            let d = (cursorWorld - base).magnitude
            return d.isFinite ? d / scale : nil
        }
        let unit = Vector(dir.x / len, dir.y / len)
        let proj = (cursorWorld - base).dot(unit)
        guard proj.isFinite else { return nil }
        return Swift.max(0, proj / scale)   // world projection → LOCAL distance
    }

    // MARK: Live preview (mirrors gizmoPreviewPolylines)

    /// The trial per-instance state during a grip drag (a PREVIEW only; not committed).
    /// The overlay sets it on every drag step (a copy of the insert's `InsertDynamicState`
    /// with the dragged parameter's value swapped) and the canvas draws the insert
    /// re-resolved at it via `insertEvaluationPreview`; cleared on commit/cancel. Mirrors
    /// `gizmoPreviewTransform`.
    @ObservationIgnored
    var insertPreviewID: EntityID?
    @ObservationIgnored
    var insertPreviewState: InsertDynamicState?

    /// The selected insert RE-RESOLVED at the trial preview state, as preview polylines
    /// (the tool-preview pen) for the overlay renderer. Empty when no grip drag is in
    /// progress. Mirrors `gizmoPreviewPolylines`: the overlay draws these green lines so a
    /// stretch/flip drag reads identically to the gizmo's rubber-band.
    var insertEvaluationPreview: [ResolvedPolyline] {
        guard let id = insertPreviewID, let trial = insertPreviewState,
              var record = drawing.entity(id), case .insert(var data) = record.kind else { return [] }
        data.dynamic = trial
        record.kind = .insert(data)
        var out: [ResolvedPolyline] = []
        for poly in record.resolve(drawing.makeResolveContext()).polylines {
            out.append(ResolvedPolyline(points: poly.points, closed: poly.closed, pen: .toolPreview))
        }
        return out
    }

    /// Sets the live grip-drag preview: the insert re-resolved at `trial` is drawn via
    /// `insertEvaluationPreview` on the next redraw. The overlay calls this each drag step
    /// with the trial parameter value swapped in.
    func setInsertEvaluationPreview(id: EntityID, state: InsertDynamicState) {
        insertPreviewID = id
        insertPreviewState = state
    }

    /// Clears the live grip-drag preview (drag ended / cancelled) WITHOUT committing.
    func clearInsertEvaluationPreview() {
        insertPreviewID = nil
        insertPreviewState = nil
    }

    /// A copy of the insert's current `InsertDynamicState` (or a fresh one), the base the
    /// overlay mutates to build a trial preview / a commit. `nil` if `id` is not an insert.
    func insertDynamicState(_ id: EntityID) -> InsertDynamicState? {
        guard let record = drawing.entity(id), case .insert(let data) = record.kind else { return nil }
        return data.dynamic ?? InsertDynamicState()
    }

    // MARK: Commit (one undoable edit, mirrors commitGizmoTransform)

    /// Commits a STRETCH grip drag: writes the dragged `distance` into the insert's
    /// `parameterValues[parameterID.raw]` through the SAME undoable funnel the
    /// Inspector/gizmo use (`applyInspectorEdits` → record replace), so one ⌘Z reverts the
    /// whole drag and the re-resolve immediately shows the new geometry. Clears the live
    /// preview. A no-op (returns `false`) if `id` is not an insert, the parameter is
    /// unknown/not linear, or the value is unchanged within tolerance (so an accidental
    /// tiny drag never pushes an undo step). The new value is clamped non-finite-safe.
    @discardableResult
    func commitInsertStretch(_ id: EntityID, parameter parameterID: BlockParameterID,
                             distance: Double) -> Bool {
        clearInsertEvaluationPreview()
        guard distance.isFinite,
              var record = drawing.entity(id), case .insert(var data) = record.kind,
              let block = drawing.blocks.block(named: data.blockName),
              let param = block.dynamic?.parameter(parameterID),
              case .linear = param else { return false }
        let baseDist = param.baseDistance ?? 0
        var state = data.dynamic ?? InsertDynamicState()
        let current = state.parameterValues[parameterID.raw] ?? baseDist
        guard abs(current - distance) > Tolerance.distance else { return false }   // no real change
        // Storing the base distance back is the same as "no override" — drop the key so a
        // grip dragged back to default leaves a clean (key-free) instance state.
        if abs(distance - baseDist) <= Tolerance.distance {
            state.parameterValues.removeValue(forKey: parameterID.raw)
        } else {
            state.parameterValues[parameterID.raw] = distance
        }
        data.dynamic = state
        record.kind = .insert(data)
        applyInspectorEdits([record])
        return true
    }

    /// Toggles a FLIP grip: flips `flipStates[parameterID.raw]` on the insert through the
    /// same undoable funnel, so one ⌘Z reverts it and the re-resolve shows the mirrored (or
    /// un-mirrored) geometry. A no-op (returns `false`) if `id` is not an insert or the
    /// parameter is unknown/not a flip parameter. Clears any live preview.
    @discardableResult
    func toggleInsertFlip(_ id: EntityID, parameter parameterID: BlockParameterID) -> Bool {
        clearInsertEvaluationPreview()
        guard var record = drawing.entity(id), case .insert(var data) = record.kind,
              let block = drawing.blocks.block(named: data.blockName),
              let param = block.dynamic?.parameter(parameterID),
              case .flip = param else { return false }
        var state = data.dynamic ?? InsertDynamicState()
        let nowFlipped = !(state.flipStates[parameterID.raw] ?? false)
        // `false` is the default — drop the key when un-flipping so the instance stays clean.
        if nowFlipped { state.flipStates[parameterID.raw] = true }
        else { state.flipStates.removeValue(forKey: parameterID.raw) }
        data.dynamic = state
        record.kind = .insert(data)
        applyInspectorEdits([record])
        return true
    }

    // MARK: Authoring (inside the Block Editor scope)

    /// The visibility states of the block CURRENTLY being edited (the Block Editor's
    /// authoring target), or `[]` when not in a block-edit session / the block has no
    /// states. Drives the Visibility States panel's list.
    var editingBlockVisibilityStates: [BlockVisibilityState] {
        guard let name = editingBlock,
              let block = drawing.blocks.block(named: name) else { return [] }
        return block.dynamic?.visibilityStates ?? []
    }

    /// Adds a new visibility state to the block being edited (block-features §9.2 New),
    /// creating the block's `DynamicBlockDef` if it has none yet (§9.5: the first state
    /// becomes the default). Undoable. Returns `true` on success — `false` if not in a
    /// block-edit session, the name is blank, or a state with that name already exists.
    @discardableResult
    func addEditingBlockVisibilityState(named name: String) -> Bool {
        guard let block = editingBlock else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let created = drawing.addVisibilityState(toBlock: block, named: trimmed) != nil
        if created { modelDirty = true; modelVersion &+= 1 }
        return created
    }

    /// Removes a visibility state from the block being edited (block-features §9.2
    /// Delete). Undoable. Returns `false` if not editing, the state is unknown, or it is
    /// the LAST state (§9.5 requires ≥1 state) — the panel disables Delete in that case,
    /// but the model enforces it too.
    @discardableResult
    func removeEditingBlockVisibilityState(named name: String) -> Bool {
        guard let block = editingBlock,
              let def = drawing.blocks.block(named: block)?.dynamic,
              def.visibilityState(named: name) != nil,
              def.visibilityStates.count > 1 else { return false }
        drawing.removeVisibilityState(block: block, named: name)
        modelDirty = true; modelVersion &+= 1
        return true
    }

    /// Renames a visibility state of the block being edited (block-features §9.2 Rename),
    /// PRESERVING the state's stable id + its visible-member set. Undoable. Returns
    /// `false` if not editing, the old state is unknown, the new name is blank, or the
    /// new name already names another state. Composed from the engine's
    /// `setBlockDynamic` mutator (there is no dedicated rename mutator — the rename is a
    /// whole-`DynamicBlockDef` replace that keeps every other state intact).
    @discardableResult
    func renameEditingBlockVisibilityState(_ oldName: String, to newName: String) -> Bool {
        guard let block = editingBlock,
              var def = drawing.blocks.block(named: block)?.dynamic,
              let idx = def.visibilityStates.firstIndex(where: { $0.name == oldName }) else { return false }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName,
              !def.visibilityStates.contains(where: { $0.name == trimmed }) else { return false }
        def.visibilityStates[idx].name = trimmed
        drawing.setBlockDynamic(name: block, def)
        modelDirty = true; modelVersion &+= 1
        return true
    }

    /// Shows (`visible == true`, BVSHOW) or hides (`false`, BVHIDE) the CURRENT canvas
    /// SELECTION's members in the named visibility state of the block being edited
    /// (block-features §9.3). Only selected ids that are actual members of the editing
    /// block are toggled (a stray selection of something outside the block is ignored).
    /// One undo group covers the whole batch. Returns the number of members whose
    /// visibility actually changed (0 ⇒ nothing applicable / already in that state).
    @discardableResult
    func setSelectedMembersVisibility(inState stateName: String, visible: Bool) -> Int {
        guard let block = editingBlock,
              let memberIDs = drawing.blocks.block(named: block)?.entityIDs else { return 0 }
        let memberSet = Set(memberIDs)
        // The state's current visible set, so we only act on REAL changes (a redundant
        // toggle registers nothing — matching the engine mutator's own no-op skip).
        let before = drawing.blocks.block(named: block)?.dynamic?
            .visibilityState(named: stateName)?.visibleMemberIDs ?? []
        let targets = selection.ids.filter { memberSet.contains($0) && before.contains($0) != visible }
        guard !targets.isEmpty else { return 0 }   // nothing applicable → no-op, no undo

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        for id in targets {
            drawing.setMemberVisibility(block: block, state: stateName, memberID: id, visible: visible)
        }
        modelDirty = true; modelVersion &+= 1
        return targets.count
    }

    // MARK: Authoring — PARAMETERS + ACTIONS (DB-2W STAGE 2, inside the Block Editor)
    //
    // The DB-2 authoring funnel: while editing a block (`editingBlock != nil`), turn the
    // current canvas SELECTION into a LINEAR STRETCH parameter+action or a FLIP
    // parameter+action, and list/remove them. The geometry (the parameter segment / flip
    // line / stretch frame) is DERIVED from the selection's block-local bounding box — a
    // straightforward, headless-testable UX that needs no modal and no tool-input state
    // machine (the brief: "UX can be straightforward"). Each routes through the engine's
    // undoable `CADDrawing` mutators (one ⌘Z per add/remove), and a parameter remove
    // PRUNES the actions that referenced it (so no orphan action is left behind).

    /// The parameters of the block CURRENTLY being edited (the panel's list), or `[]` when
    /// not editing / the block has none.
    var editingBlockParameters: [BlockParameter] {
        guard let name = editingBlock,
              let block = drawing.blocks.block(named: name) else { return [] }
        return block.dynamic?.parameters ?? []
    }

    /// The actions of the block CURRENTLY being edited (the panel's list), or `[]`.
    var editingBlockActions: [BlockAction] {
        guard let name = editingBlock,
              let block = drawing.blocks.block(named: name) else { return [] }
        return block.dynamic?.actions ?? []
    }

    /// The block-LOCAL bounding box of the current selection's members (the editing block's
    /// own coordinate space — members are stored re-authored about the base point). `nil`
    /// for an empty / non-member selection. The authoring geometry is derived from this.
    private var selectionBlockLocalBounds: AABB? {
        guard let name = editingBlock,
              let memberIDs = drawing.blocks.block(named: name)?.entityIDs else { return nil }
        let memberSet = Set(memberIDs)
        var box = AABB.empty
        for id in selection.ids where memberSet.contains(id) {
            guard let e = drawing.entity(id) else { continue }
            box = box.union(e.boundingBox())
        }
        return box.isEmpty ? nil : box
    }

    /// The selected ids that are actual members of the editing block (an action's selection
    /// set). Empty if not editing / nothing applicable.
    private var selectedMemberIDs: Set<EntityID> {
        guard let name = editingBlock,
              let memberIDs = drawing.blocks.block(named: name)?.entityIDs else { return [] }
        let memberSet = Set(memberIDs)
        return Set(selection.ids.filter { memberSet.contains($0) })
    }

    /// A fresh, unused parameter id within the editing block (prefix `p`), so two adds never
    /// collide on the per-instance value key.
    private func freshParameterID() -> BlockParameterID {
        let used = Set(editingBlockParameters.map { $0.id.raw })
        var n = used.count + 1
        while used.contains("p\(n)") { n += 1 }
        return BlockParameterID("p\(n)")
    }

    /// A fresh, unused action id within the editing block (prefix `a`).
    private func freshActionID() -> BlockActionID {
        let used = Set(editingBlockActions.map { $0.id.raw })
        var n = used.count + 1
        while used.contains("a\(n)") { n += 1 }
        return BlockActionID("a\(n)")
    }

    /// Authors a LINEAR STRETCH from the current selection (block-features §5.2.2 + §6.2.3):
    /// adds a `.linear` parameter running left-mid → right-mid across the selection's
    /// block-local bounds, plus a `.stretch` action over the RIGHT HALF of those bounds
    /// (so dragging the grip stretches the right portion) targeting the selected members.
    /// Both adds are ONE undo group. Returns the new parameter id, or `nil` if not editing
    /// or the selection has no members / a degenerate (zero-width) box.
    ///
    /// `label` names the parameter in the Properties palette; an empty label defaults to
    /// "Distance N".
    @discardableResult
    func addLinearStretchFromSelection(label: String = "") -> BlockParameterID? {
        guard let block = editingBlock, let box = selectionBlockLocalBounds else { return nil }
        let members = selectedMemberIDs
        guard !members.isEmpty else { return nil }
        let midY = (box.min.y + box.max.y) * 0.5
        let base = Vector(box.min.x, midY)
        let end = Vector(box.max.x, midY)
        guard (end - base).magnitude > Tolerance.distance else { return nil }   // degenerate
        // The stretch frame = the RIGHT HALF of the bounds: left edge at the center line,
        // right edge at the bounds' right edge, padded a hair in Y. The evaluator tests each
        // member's ORIGINAL (un-stretched) defining points against this frame, so points
        // right of center (including the original right endpoint at `box.max.x`) move and
        // left-of-center points stay — no need to over-extend past `box.max.x`.
        let midX = (box.min.x + box.max.x) * 0.5
        let pad = Swift.max((box.max.y - box.min.y) * 0.5, Tolerance.distance)
        let frame = AABB(min: Vector(midX, box.min.y - pad),
                         max: Vector(box.max.x, box.max.y + pad))

        let pid = freshParameterID()
        let aid = freshActionID()
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = name.isEmpty ? "Distance \(editingBlockParameters.count + 1)" : name

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        guard drawing.addLinearParameter(toBlock: block, id: pid, label: finalLabel,
                                         base: base, end: end) else { return nil }
        _ = drawing.addStretchAction(toBlock: block, id: aid, parameterID: pid,
                                     frame: frame, memberIDs: members)
        modelDirty = true; modelVersion &+= 1
        return pid
    }

    /// Authors a FLIP from the current selection (block-features §5.2.7 + §6.2.6): adds a
    /// `.flip` parameter whose reflection line is VERTICAL through the selection's
    /// block-local center (so a flip mirrors left↔right), plus a `.flip` action targeting
    /// the selected members. Both adds are ONE undo group. Returns the new parameter id, or
    /// `nil` if not editing / no members / a degenerate box.
    @discardableResult
    func addFlipFromSelection(label: String = "") -> BlockParameterID? {
        guard let block = editingBlock, let box = selectionBlockLocalBounds else { return nil }
        let members = selectedMemberIDs
        guard !members.isEmpty else { return nil }
        let midX = (box.min.x + box.max.x) * 0.5
        let midY = (box.min.y + box.max.y) * 0.5
        // A vertical reflection line through the center, spanning (a bit beyond) the box. For
        // a zero-height selection (e.g. a single horizontal line) fall back to the box WIDTH
        // so the line is non-degenerate and the flip-grip triangle has an orientation.
        let height = box.max.y - box.min.y
        let span = Swift.max(height, box.max.x - box.min.x, Tolerance.distance * 10)
        let lineStart = Vector(midX, midY - span * 0.6)
        let lineEnd = Vector(midX, midY + span * 0.6)
        guard (lineEnd - lineStart).magnitude > Tolerance.distance else { return nil }

        let pid = freshParameterID()
        let aid = freshActionID()
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = name.isEmpty ? "Flip \(editingBlockParameters.count + 1)" : name

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        guard drawing.addFlipParameter(toBlock: block, id: pid, label: finalLabel,
                                       lineStart: lineStart, lineEnd: lineEnd) else { return nil }
        _ = drawing.addFlipAction(toBlock: block, id: aid, parameterID: pid, memberIDs: members)
        modelDirty = true; modelVersion &+= 1
        return pid
    }

    /// Removes a parameter from the editing block AND prunes every action that referenced it
    /// (so no orphan action is left), as ONE undo group. Undoable. Returns `false` if not
    /// editing or the parameter is unknown.
    @discardableResult
    func removeEditingBlockParameter(_ id: BlockParameterID) -> Bool {
        guard let block = editingBlock,
              let def = drawing.blocks.block(named: block)?.dynamic,
              def.parameter(id) != nil else { return false }
        let orphans = def.actions.filter { $0.parameterID == id }.map { $0.id }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        for aid in orphans { drawing.removeAction(fromBlock: block, id: aid) }
        drawing.removeParameter(fromBlock: block, id: id)
        modelDirty = true; modelVersion &+= 1
        return true
    }

    /// Removes a single action from the editing block (leaving its parameter intact).
    /// Undoable. Returns `false` if not editing or the action is unknown.
    @discardableResult
    func removeEditingBlockAction(_ id: BlockActionID) -> Bool {
        guard let block = editingBlock,
              let def = drawing.blocks.block(named: block)?.dynamic,
              def.actions.contains(where: { $0.id == id }) else { return false }
        drawing.removeAction(fromBlock: block, id: id)
        modelDirty = true; modelVersion &+= 1
        return true
    }

    // MARK: - Layer ops (F17 — freeze/lock all, per-entity layer ops, layer states)

    /// Freezes / thaws every layer in one undoable step (sidebar "freeze all").
    func freezeAllLayers(_ frozen: Bool) {
        drawing.freezeAllLayers(frozen)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Locks / unlocks every layer in one undoable step (sidebar "lock all").
    func lockAllLayers(_ locked: Bool) {
        drawing.lockAllLayers(locked)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Sets a layer's printable flag (undoable). Surfaced as a per-layer toggle.
    func setLayerPrintable(_ name: String, _ printable: Bool) {
        drawing.setLayerPrintable(name, printable)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Sets a layer's construction flag (undoable). Surfaced as a per-layer toggle.
    func setLayerConstruction(_ name: String, _ construction: Bool) {
        drawing.setLayerConstruction(name, construction)
        modelDirty = true
        modelVersion &+= 1
    }

    /// Moves the current selection onto `layer` as ONE undoable group (the "move to
    /// layer" per-entity layer op). Routes through the inspector-edit path so it is
    /// undoable + index-synced. No-op for an empty selection / unknown layer.
    /// Returns whether anything moved.
    @discardableResult
    func moveSelectionToLayer(_ layer: String) -> Bool {
        guard drawing.layers.contains(layer), !selection.isEmpty else { return false }
        let records = selection.ids.compactMap { id -> EntityRecord? in
            guard var r = drawing.entity(id), r.layer.name != layer else { return nil }
            r.layer = LayerID(layer)
            return r
        }
        guard !records.isEmpty else { return false }
        applyInspectorEdits(records)
        return true
    }

    /// "Hide other layers" — freezes every layer EXCEPT the named one, in one
    /// undoable step (a focus affordance: isolate a layer). The named layer is
    /// thawed so it is definitely visible. No-op if `layer` is unknown.
    func isolateLayer(_ layer: String) {
        guard drawing.layers.contains(layer) else { return }
        drawing.mutateLayers { table in
            for l in table.layers {
                table.setVisible(l.name, l.name == layer)
            }
        }
        modelDirty = true
        modelVersion &+= 1
    }

    /// Saves the current layer flags as a named state (undoable). Returns the name
    /// it was saved under. The sidebar's "save state" action calls this.
    @discardableResult
    func saveLayerState(named name: String) -> String {
        let saved = drawing.saveLayerState(named: name)
        modelVersion &+= 1
        return saved
    }

    /// Restores a named layer state onto the live layers (undoable). Returns whether
    /// a state was found + applied; nudges the renderer (layer flags affect render).
    @discardableResult
    func restoreLayerState(named name: String) -> Bool {
        let ok = drawing.restoreLayerState(named: name)
        if ok {
            modelDirty = true
            modelVersion &+= 1
        }
        return ok
    }

    /// Removes a named layer state (undoable).
    func removeLayerState(named name: String) {
        drawing.removeLayerState(named: name)
        modelVersion &+= 1
    }

    // MARK: - Property painter (F20 — match properties / eyedropper)

    /// The "loaded brush" the property painter holds — the pen + layer picked from a
    /// source entity, applied to subsequent picks. `nil` when no source has been
    /// picked yet. Observed so the inspector / a status chip can reflect "brush
    /// loaded". Cleared when the painter is turned off.
    private(set) var paintBrush: PaintAttributes?

    /// Whether the property-painter mode is armed (the canvas affordance / inspector
    /// toggle). When ON, a single-selection pick LOADS the brush, and a multi-pick or
    /// the "apply to selection" action stamps it. Purely interaction policy (not
    /// document state). Observed so the toolbar/inspector reflect it.
    var painterArmed: Bool = false

    /// Whether a brush is currently loaded (drives the "apply" affordance's enabled
    /// state).
    var hasPaintBrush: Bool { paintBrush != nil }

    /// Loads the property-painter brush from a single source entity (the eyedropper
    /// pick): captures its pen + layer. No-op (returns `false`) if the id is unknown.
    /// The inspector / canvas calls this to "pick up" properties.
    @discardableResult
    func loadPaintBrush(from id: EntityID) -> Bool {
        guard let record = drawing.entity(id) else { return false }
        paintBrush = PaintAttributes(from: record)
        return true
    }

    /// Loads the brush from the single selected entity (the inspector's "Pick up
    /// properties" button when exactly one entity is selected). Returns whether a
    /// brush was loaded.
    @discardableResult
    func loadPaintBrushFromSelection() -> Bool {
        guard selection.ids.count == 1, let id = selection.ids.first else { return false }
        return loadPaintBrush(from: id)
    }

    /// Applies the loaded brush to a target entity id as ONE undoable edit (a paint
    /// click while armed). No-op if no brush is loaded, the target is unknown, the
    /// target IS the source (painting onto itself), or the paint would be a no-op.
    /// Returns whether anything changed.
    @discardableResult
    func applyPaintBrush(to id: EntityID,
                         options: PropertyPainter.Options = .all) -> Bool {
        guard let brush = paintBrush, let target = drawing.entity(id) else { return false }
        let painted = PropertyPainter.apply(brush, to: target, options: options)
        guard painted != target else { return false }
        applyInspectorEdits([painted])
        return true
    }

    /// Applies the loaded brush to the WHOLE current selection as ONE undoable group
    /// (the inspector's "Apply to selection" button). Only the records that actually
    /// change are committed. Returns whether anything changed.
    @discardableResult
    func applyPaintBrushToSelection(options: PropertyPainter.Options = .all) -> Bool {
        guard let brush = paintBrush, !selection.isEmpty else { return false }
        let targets = selection.ids.compactMap { drawing.entity($0) }
        let changed = PropertyPainter.apply(brush, to: targets, options: options)
        guard !changed.isEmpty else { return false }
        applyInspectorEdits(changed)
        return true
    }

    /// Resets the pen of the whole current selection back to `.byLayer` (the
    /// inspector's "Reset pen to layer" — entities inherit their layer's pen again),
    /// one undoable group. Returns whether anything changed.
    @discardableResult
    func resetSelectionPenToLayer() -> Bool {
        guard !selection.isEmpty else { return false }
        let targets = selection.ids.compactMap { drawing.entity($0) }
        let changed = PropertyPainter.resetPenToLayer(targets)
        guard !changed.isEmpty else { return false }
        applyInspectorEdits(changed)
        return true
    }

    /// Toggles the property-painter armed state. Turning it OFF clears the brush so a
    /// re-arm starts fresh.
    func togglePainterArmed() {
        painterArmed.toggle()
        if !painterArmed { paintBrush = nil }
        modelVersion &+= 1
    }

    // MARK: - Selection gizmo (on-canvas transform handles)

    /// The world-space (Y-up) axis-aligned bounding box that ENCLOSES the current
    /// selection — the frame the on-canvas transform gizmo is drawn around. `nil`
    /// when nothing is selected (or no selected id resolves to a real entity), so
    /// the gizmo overlay is shown only with a non-empty selection in Select mode.
    ///
    /// Uses the font-aware `ResolveContext` box (same as `rebuildIndex`) so a text
    /// selection's frame matches its visible ink extent.
    var selectionWorldBounds: AABB? {
        guard !selection.isEmpty else { return nil }
        let ctx = drawing.makeResolveContext()
        var box = AABB.empty
        for id in selection.ids {
            guard let e = drawing.entity(id) else { continue }
            box = box.union(e.boundingBox(ctx: ctx))
        }
        return box.isEmpty ? nil : box
    }

    /// The live gizmo drag transform (a preview only; not yet committed). The
    /// renderer reads it via `gizmoPreviewPolylines` to draw the selection at the
    /// dragged transform; `nil` when no gizmo drag is in progress. Set on every
    /// drag step by the interaction layer, cleared on commit/cancel.
    @ObservationIgnored
    var gizmoPreviewTransform: Affine2D?

    /// The selection's geometry under the live gizmo drag, resolved to preview
    /// polylines (the tool-preview pen) for the overlay renderer. Empty when no
    /// drag is in progress. Mirrors the MODIFY tools' rubber-band preview so the
    /// gizmo drag reads identically to a Move/Rotate/Scale tool drag.
    var gizmoPreviewPolylines: [ResolvedPolyline] {
        guard let t = gizmoPreviewTransform, !selection.isEmpty else { return [] }
        var out: [ResolvedPolyline] = []
        for id in selection.ids {
            guard let record = drawing.entity(id) else { continue }
            let moved = record.kind.transformed(by: t)
            for poly in moved.resolve(pen: .toolPreview, ctx: .default).polylines {
                out.append(ResolvedPolyline(points: poly.points, closed: poly.closed, pen: .toolPreview))
            }
        }
        return out
    }

    /// Sets the live gizmo preview transform (drag in progress). The overlay
    /// renderer picks it up via `gizmoPreviewPolylines` on the next redraw.
    func setGizmoPreview(_ t: Affine2D?) {
        gizmoPreviewTransform = t
    }

    /// Clears the live gizmo preview (drag ended / cancelled) WITHOUT committing.
    func clearGizmoPreview() {
        gizmoPreviewTransform = nil
    }

    /// Commits a gizmo transform to the whole current selection as ONE undoable
    /// edit: applies `t` to each selected entity's geometry via the shared
    /// `EntityKind.transformed(by:)` and routes the full-record replacements
    /// through `applyInspectorEdits` (the same undoable path the Inspector uses), so
    /// a single ⌘Z reverts the entire gizmo drag. The live preview is cleared. A
    /// near-identity transform (a drag that did not actually move anything) is a
    /// no-op so an accidental tiny drag never pushes an undo step. Returns whether
    /// anything was committed.
    @discardableResult
    func commitGizmoTransform(_ t: Affine2D) -> Bool {
        gizmoPreviewTransform = nil
        guard !selection.isEmpty, !Self.isApproximatelyIdentity(t) else { return false }
        var records: [EntityRecord] = []
        for id in selection.ids {
            guard var record = drawing.entity(id) else { continue }
            record.kind = record.kind.transformed(by: t)
            records.append(record)
        }
        guard !records.isEmpty else { return false }
        applyInspectorEdits(records)
        return true
    }

    /// Whether `t` is within numeric tolerance of the identity transform (a drag
    /// that did not actually move/scale/rotate anything). Used to drop a zero-effect
    /// gizmo drag so it never registers an undo step.
    private static func isApproximatelyIdentity(_ t: Affine2D) -> Bool {
        let e = 1e-9
        return abs(t.a - 1) < e && abs(t.b) < e && abs(t.c) < e && abs(t.d - 1) < e
            && abs(t.tx) < e && abs(t.ty) < e
    }

    // MARK: - Draw order (F16 — Arrange: raise / lower / front / back)
    //
    // Each routes the current selection through the matching undoable `CADDrawing`
    // reorder op (one ⌘Z reverts the whole arrange), then rebuilds the spatial index
    // (the op permutes `entities`, which the quadtree mirrors only by id, but a
    // rebuild keeps the index trivially consistent) and marks the GPU buffer dirty so
    // the renderer re-packs in the new order. No-op (returns `false`) for an empty
    // selection, so the caller can skip a redraw + the menu item can disable.

    /// Brings the current selection to the FRONT of the draw order (Arrange ▸ Bring
    /// to Front). Returns whether the order changed.
    @discardableResult
    func bringSelectionToFront() -> Bool { arrange { $0.bringToFront($1) } }

    /// Sends the current selection to the BACK (Arrange ▸ Send to Back).
    @discardableResult
    func sendSelectionToBack() -> Bool { arrange { $0.sendToBack($1) } }

    /// Raises the current selection one step toward the front (Arrange ▸ Bring
    /// Forward).
    @discardableResult
    func raiseSelection() -> Bool { arrange { $0.raise($1) } }

    /// Lowers the current selection one step toward the back (Arrange ▸ Send
    /// Backward).
    @discardableResult
    func lowerSelection() -> Bool { arrange { $0.lower($1) } }

    /// Shared driver for the four Arrange ops: runs `op` (one of the undoable
    /// `CADDrawing` reorder methods) on the current selection's ids, and — if it
    /// changed the order — re-syncs the spatial index + marks the model dirty so the
    /// renderer re-packs in the new draw order. No-op for an empty selection.
    @discardableResult
    private func arrange(_ op: (CADDrawing, [EntityID]) -> Bool) -> Bool {
        guard !selection.isEmpty else { return false }
        let ids = Array(selection.ids)
        guard op(drawing, ids) else { return false }
        rebuildIndex()
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    // MARK: - Revert direction (F16 — flip an entity's start/end / vertex order)

    /// Reverts the direction of every entity in the current selection as ONE
    /// undoable group (Arrange ▸ Revert Direction / context menu): each line swaps
    /// its endpoints, each polyline reverses its vertex order, each arc/ellipse/
    /// spline flips its sweep. The drawn shapes are unchanged; only the defining
    /// direction flips (matters for offset side, arrow orientation, trim ends).
    /// Kinds with no direction are skipped. Routes through the undoable
    /// `CADDrawing.revertDirection` (a `.replace` per entity) and re-syncs the index.
    /// No-op (returns `false`) when nothing in the selection had a reversible
    /// direction. Returns whether anything changed.
    @discardableResult
    func revertSelectionDirection() -> Bool {
        guard !selection.isEmpty else { return false }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        var changed = false
        for id in selection.ids {
            if drawing.revertDirection(of: id) {
                changed = true
                if let box = drawing.entity(id)?.boundingBox(), !box.isEmpty {
                    quadtree.update(id, bounds: box)
                }
            }
        }
        guard changed else { return false }
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// Whether the current selection has at least one entity whose direction can be
    /// reverted (drives the Arrange ▸ Revert Direction menu item's enabled state).
    var canRevertSelectionDirection: Bool {
        selection.ids.contains { id in
            guard let r = drawing.entity(id) else { return false }
            return EntityDirection.reversed(r.kind) != nil
        }
    }

    /// Whether the current selection can be arranged (any non-empty selection;
    /// drives the Arrange ▸ raise/lower/front/back menu items' enabled state).
    var canArrangeSelection: Bool { !selection.isEmpty }

    // MARK: - Snap modes (Inspector toggles)

    /// Whether a snap mode is currently enabled.
    func isSnapModeOn(_ mode: SnapMode) -> Bool { snapModes.contains(mode) }

    /// The non-object snap bits: `.free` (the always-on raw-cursor fallback the
    /// pipeline never gates on) and `.grid` (the SEPARATE grid snap / F9). Neither
    /// counts as "object snapping"; subtracting them from `snapModes` leaves only
    /// the POSITIVE object-snap bits.
    static let nonObjectSnapModes: SnapMode = [.free, .grid]

    /// The default object-snap set restored by the master toggle when nothing was
    /// previously stashed — the interactive defaults (endpoint + center + middle +
    /// intersection). Object-snap bits only (never `.free`/`.grid`).
    static let defaultObjectSnapModes: SnapMode = [.endpoint, .center, .middle, .intersection]

    /// Whether OBJECT snapping is currently active (AutoCAD OSNAP / F3): true iff
    /// any POSITIVE object-snap bit is set. `.free` (raw-cursor fallback) and
    /// `.grid` (the separate grid snap) do NOT count, since the snap pipeline only
    /// gates on positive object-snap bits — when none are set, `Snapping.snap`
    /// returns the free (raw) cursor point. This is the master toggle's GET.
    var objectSnapEnabled: Bool {
        !snapModes.subtracting(Self.nonObjectSnapModes).isEmpty
    }

    /// Master object-snap on/off (AutoCAD OSNAP / F3), the Inspector's "Object Snap"
    /// toggle SET. Turning it OFF stashes the current positive object-snap bits and
    /// CLEARS them from `snapModes` (so `Snapping.snap` falls back to the free/raw
    /// point), while preserving `.grid`/`.free`. Turning it ON restores the stashed
    /// bits — or `defaultObjectSnapModes` if nothing was stashed (e.g. a fresh-loaded
    /// file). Routes every mutation through the existing `setSnapMode`/`persistSnapModes`
    /// funnel so persistence (`$LC_SNAPMODE`) and undo stay consistent.
    func setObjectSnapEnabled(_ on: Bool) {
        if on {
            // Already on (some object-snap bit set) → nothing to restore.
            guard !objectSnapEnabled else { return }
            let restore = stashedObjectSnapModes.isEmpty
                ? Self.defaultObjectSnapModes
                : stashedObjectSnapModes
            stashedObjectSnapModes = []
            // Funnel through setSnapMode so the change persists + is undoable.
            setSnapMode(restore, true)
        } else {
            let current = snapModes.subtracting(Self.nonObjectSnapModes)
            guard !current.isEmpty else { return }  // already off
            stashedObjectSnapModes = current
            setSnapMode(current, false)
        }
    }

    /// Enables/disables a single snap mode (the Inspector's per-mode toggles + the
    /// Document Settings sheet). Persists the resulting set to the document's private
    /// `$LC_SNAPMODE` header var (decision D5) as ONE undoable step so the snap modes
    /// travel with the file (Save→Open) and ⌘Z reverts the toggle.
    func setSnapMode(_ mode: SnapMode, _ on: Bool) {
        if on { snapModes.insert(mode) } else { snapModes.remove(mode) }
        persistSnapModes()
    }

    /// Writes the current `snapModes` set to the private `$LC_SNAPMODE` header var
    /// (undoable). Called by `setSnapMode` and the settings sheet so the persisted
    /// value always tracks the live set. The undo also restores the live `snapModes`
    /// (the header var alone wouldn't), so ⌘Z fully reverts a toggle.
    private func persistSnapModes() {
        let liveModes = snapModes
        let priorModes = snapModes  // captured for the live-state restore below
        drawing.mutateGraphicVariables { $0.snapModeRaw = Int(liveModes.rawValue) }
        // mutateGraphicVariables registers an undo that restores the header var; also
        // restore the live `snapModes` so the toggle visually reverts on ⌘Z.
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.snapModes
                model.snapModes = priorModes
                // Re-register so redo restores `current` (value-snapshot pattern).
                model.reRegisterSnapModeUndo(restoring: current)
                model.modelDirty = true
                model.modelVersion &+= 1
            }
        }
    }

    /// Re-registers the live-`snapModes` restore for redo (paired with the header-var
    /// undo `mutateGraphicVariables` already manages). Keeps the live set and the
    /// header var in lock-step across undo/redo.
    private func reRegisterSnapModeUndo(restoring modes: SnapMode) {
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.snapModes
                model.snapModes = modes
                model.reRegisterSnapModeUndo(restoring: current)
                model.modelDirty = true
                model.modelVersion &+= 1
            }
        }
    }

    // MARK: - Document Settings (live-apply + per-field undo; D3)
    //
    // The Document Settings sheet binds to the typed `graphicVariables` accessors
    // and applies each edit IMMEDIATELY (D3: live-apply + Done). Every setter below
    // funnels the header-var write through the engine's undoable
    // `CADDrawing.mutateGraphicVariables` (value-snapshot, ADR-002) so each field is
    // ONE undo step, and marks the model dirty so the renderer/document update. The
    // few settings that mirror a live model flag (grid on/off ↔ `gridVisible`, grid
    // spacing ↔ `preferredGridSpacing`) update BOTH so the canvas reflects the change
    // without a reload. Persistence is automatic: the header vars round-trip via the
    // document payload (Save→Open).

    /// Applies one header-var edit through the undoable engine mutator and marks the
    /// model dirty (so the document becomes dirty + the renderer repaints). The body
    /// receives the variables bag by `inout`; a no-op edit registers no undo.
    private func applySetting(_ body: (inout GraphicVariables) -> Void) {
        drawing.mutateGraphicVariables(body)
        modelDirty = true
        modelVersion &+= 1
    }

    // Units ---------------------------------------------------------------------

    /// `$INSUNITS` — the drawing unit.
    func setDrawingUnit(_ unit: DrawingUnit) { applySetting { $0.unit = unit } }
    /// `$LUNITS` — linear display format.
    func setLinearFormat(_ f: LinearFormat) { applySetting { $0.linearFormat = f } }
    /// `$LUPREC` — linear precision (clamped 0…8).
    func setLinearPrecision(_ p: Int) { applySetting { $0.linearPrecision = Swift.max(0, Swift.min(8, p)) } }
    /// `$AUNITS` — angle display format.
    func setAngleFormat(_ f: AngleFormat) { applySetting { $0.angleFormat = f } }
    /// `$AUPREC` — angle precision (clamped 0…8).
    func setAnglePrecision(_ p: Int) { applySetting { $0.anglePrecision = Swift.max(0, Swift.min(8, p)) } }
    /// `$ANGBASE` — base angle (stored radians; the sheet edits degrees).
    func setAngleBaseDegrees(_ deg: Double) { applySetting { $0.anglesBase = deg * .pi / 180 } }
    /// `$ANGDIR` — angle direction (true == counter-clockwise).
    func setAnglesCounterClockwise(_ ccw: Bool) { applySetting { $0.anglesCounterClockwise = ccw } }

    // Grid & snap ---------------------------------------------------------------

    /// `$GRIDMODE` ↔ `gridVisible`. Updates both the header var (persist) and the
    /// live render flag so the canvas reflects the toggle immediately.
    func setGridOn(_ on: Bool) {
        gridVisible = on
        applySetting { $0.gridOn = on }
    }

    /// `$GRIDUNIT` ↔ `preferredGridSpacing`. Updates both. A non-positive spacing is
    /// ignored (would make the grid degenerate).
    func setGridSpacing(_ spacing: Double) {
        guard spacing > 0 else { return }
        preferredGridSpacing = spacing
        applySetting { $0.gridSpacing = spacing }
    }

    // Dimensions ----------------------------------------------------------------

    /// `$DIMTXT` — document-default dimension text height (>0).
    func setDimTextHeight(_ h: Double) { guard h > 0 else { return }; applySetting { $0.dimTextHeight = h } }
    /// `$DIMASZ` — document-default arrow size (>0).
    func setDimArrowSize(_ s: Double) { guard s > 0 else { return }; applySetting { $0.dimArrowSize = s } }
    /// `$DIMSCALE` — overall dimension scale (>0).
    func setDimScale(_ s: Double) { guard s > 0 else { return }; applySetting { $0.dimScale = s } }
    /// `$DIMLUNIT` — dimension-text linear format.
    func setDimLinearFormat(_ f: LinearFormat) { applySetting { $0.dimLinearFormat = f } }
    /// `$DIMDEC` — dimension-text linear precision (clamped 0…8).
    func setDimLinearPrecision(_ p: Int) { applySetting { $0.dimLinearPrecision = Swift.max(0, Swift.min(8, p)) } }

    // Paper ---------------------------------------------------------------------

    /// `$PINSBASE` — paper-space insertion base point.
    func setPaperInsertionBase(_ v: Vector) { applySetting { $0.paperInsertionBase = v } }

    // MARK: - Undo / redo (rebuild the index, which the undo closures don't touch)

    /// Whether an undo is available.
    var canUndo: Bool { undoManager.canUndo }
    /// Whether a redo is available.
    var canRedo: Bool { undoManager.canRedo }

    /// Undoes the last drawing mutation and re-syncs the spatial index (the
    /// drawing's value-snapshot undo restores `entities`, but the quadtree is a
    /// separate index the undo closures don't touch — so rebuild it).
    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        rebuildIndex()
        selection.clear()
        modelDirty = true
        modelVersion &+= 1
    }

    /// Redoes the last undone mutation and re-syncs the spatial index.
    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        rebuildIndex()
        selection.clear()
        modelDirty = true
        modelVersion &+= 1
    }

    // MARK: - Delete selection (Edit ▸ Delete / ⌫)

    /// Removes every entity in the current selection as ONE undoable group, reusing
    /// the existing `applyCommit` edit path: it removes each entity from the drawing
    /// (undoable, ADR-002), drops it from the quadtree, and clears it from the
    /// selection (the `.remove` case already does all three), then marks the GPU
    /// model buffer dirty. A single undo restores the whole deletion. No-op (returns
    /// `false`) when the selection is empty, so the caller can skip a redraw.
    @discardableResult
    func deleteSelection() -> Bool {
        guard !selection.isEmpty else { return false }
        // Snapshot the ids first: `applyCommit`'s `.remove` mutates `selection`
        // while iterating, so we must not iterate `selection.ids` directly.
        let edits: [ToolEdit] = selection.ids.map { .remove($0) }
        // Pure `.remove` edits — the stamp only touches `.add`, so the flag is
        // immaterial here; pass `false` (no geometry adopts current properties).
        applyCommit(edits, adoptsCurrentProperties: false)
        // `applyCommit` removes each id from `selection`; clear any residue so the
        // selection is empty and the highlight overlay disappears.
        selection.clear()
        return true
    }

    // MARK: - Selection primitives (Edit ▸ Select All / Deselect / Invert)

    /// Selects EVERY selectable entity (Edit ▸ Select All, ⌘A). "Selectable" is the
    /// engine policy `SelectionPolicy.selectableIDs`: visible entities NOT on a locked
    /// or frozen layer (you cannot edit what is locked / can't see what is hidden), so
    /// Select All never picks up locked or hidden geometry. Bumps `modelVersion` so the
    /// renderer repaints the highlight overlay. Selection is view-side state (a separate
    /// `Set`), so this registers NO undo — it is not a document mutation. Returns whether
    /// the selection changed (so the caller can skip a redraw).
    @discardableResult
    func selectAll() -> Bool {
        let ids = Set(SelectionPolicy.selectableIDs(in: drawing))
        guard ids != selection.ids else { return false }
        selection = Selection(ids: ids)
        modelVersion &+= 1
        return true
    }

    /// Clears the whole selection (Edit ▸ Deselect All, ⇧⌘A, and reachable via Esc).
    /// No-op (returns `false`) when nothing is selected. Bumps `modelVersion` so the
    /// highlight overlay disappears.
    @discardableResult
    func deselectAll() -> Bool {
        guard !selection.isEmpty else { return false }
        selection.clear()
        modelVersion &+= 1
        return true
    }

    /// Replaces the whole selection with `ids` (the Select Connected / Select Contour
    /// traversal results, wire-wave-2). Bumps `modelVersion` so the highlight overlay
    /// repaints; selection is view-side state, so this registers NO undo (it is not a
    /// document mutation, like the other Select verbs). Returns whether the selection
    /// changed (so the caller can skip a redraw).
    @discardableResult
    func setSelection(_ ids: Set<EntityID>) -> Bool {
        guard ids != selection.ids else { return false }
        selection = Selection(ids: ids)
        modelVersion &+= 1
        return true
    }

    /// Inverts the selection (Edit ▸ Invert Selection): every *selectable* entity that
    /// is not currently selected becomes selected, and vice-versa, computed by the
    /// engine policy `SelectionPolicy.invertedIDs` (which excludes locked/hidden
    /// entities from the universe — an invert never selects something uneditable, and
    /// drops any selected locked entity). Bumps `modelVersion`; selection is view-side
    /// state so no undo is registered. Returns whether the selection changed.
    @discardableResult
    func invertSelection() -> Bool {
        let ids = Set(SelectionPolicy.invertedIDs(current: selection.ids, in: drawing))
        guard ids != selection.ids else { return false }
        selection = Selection(ids: ids)
        modelVersion &+= 1
        return true
    }

    // MARK: - Quick Select / Select Similar (engine: QuickSelect.swift)

    /// The ids matching `filter` WITHIN the active space, gated to selectable entities.
    /// A PURE query (reads only `activeSpaceEntities` + the layer table; mutates nothing)
    /// so the panel can preview the resulting COUNT before applying, and so the apply path
    /// + the unit tests share one definition of "what Quick Select would pick".
    ///
    /// Scoping rationale: `activeSpaceEntities` already restricts the universe to the
    /// active space (model / a paper layout / the open block's members) AND, in model
    /// space, EXCLUDES block-DEFINITION members (`drawing.blockMemberIDs`) — so a quick
    /// select never picks geometry owned by a block (it is editable only via the Block
    /// Editor / an `.insert`). On top of that we apply the same `SelectionPolicy`
    /// selectability gate the other Select verbs use (skip locked / frozen / hidden), so a
    /// Quick Select can only ever land on what the user could click. (`includeHidden` on
    /// the filter still controls the entity's OWN `.visible` flag inside `QuickSelect`; the
    /// layer-level lock/freeze gate is enforced here regardless, matching Select All.)
    func quickSelectMatchIDs(_ filter: QuickSelectFilter) -> Set<EntityID> {
        let scoped = activeSpaceEntities
        let layers = drawing.layers
        let matched = QuickSelect.matches(filter, in: scoped)
        guard !matched.isEmpty else { return [] }
        // Apply the Select-All selectability gate (locked/frozen layers excluded).
        var byID = [EntityID: EntityRecord](minimumCapacity: scoped.count)
        for e in scoped { byID[e.id] = e }
        return matched.filter { id in
            guard let e = byID[id] else { return false }
            return SelectionPolicy.isSelectable(e, layers: layers)
        }
    }

    /// Applies a Quick Select: computes the ids matching `filter` in the active space
    /// (via `quickSelectMatchIDs`), COMBINES them with the current selection per `mode`
    /// (replace / add / remove / intersect — `QuickSelect.combine`), and installs the
    /// result. Returns whether the selection changed (so the caller can skip a redraw).
    ///
    /// Selection is view-side state (a separate `Set`), so this registers NO undo — like
    /// every other Select verb. Bumps `modelVersion` so the highlight overlay repaints.
    /// This is the funnel the `QuickSelectPanel` "Apply" button calls; the modal-free
    /// filter is built entirely in the View layer.
    @discardableResult
    func applyQuickSelect(_ filter: QuickSelectFilter,
                          mode: QuickSelect.ApplyMode) -> Bool {
        let result = quickSelectMatchIDs(filter)
        let newIDs = QuickSelect.combine(prior: selection.ids, result: result, mode: mode)
        guard newIDs != selection.ids else { return false }
        selection = Selection(ids: newIDs)
        modelVersion &+= 1
        return true
    }

    /// Builds the "Select Similar" filter for a reference entity: matches every entity
    /// sharing its KIND tag, LAYER, and pen COLOR (the AutoCAD "Select Similar" defaults).
    /// Pure (reads only the drawing); `nil` when `selectedID` no longer resolves. The View
    /// layer / a menu verb feeds the result to `applyQuickSelect(_:mode:)` (usually
    /// `.replace`). Line WIDTH is intentionally NOT constrained (Select Similar groups by
    /// look — kind + layer + color — not by exact lineweight, matching the AutoCAD verb).
    func similarFilter(to selectedID: EntityID) -> QuickSelectFilter? {
        guard let record = drawing.entity(selectedID) else { return nil }
        return QuickSelectFilter(
            kinds: [record.quickSelectKind],
            layer: record.layer.name,
            color: record.pen.lineColor
        )
    }

    /// "Select Similar": replaces the selection with every entity in the active space that
    /// shares the reference entity's kind + layer + color (see `similarFilter`). A no-op
    /// (returns `false`) when `selectedID` no longer resolves. Returns whether the
    /// selection changed. The convenience the "Select Similar" affordance / context action
    /// calls with the clicked entity's id.
    @discardableResult
    func selectSimilar(to selectedID: EntityID) -> Bool {
        guard let filter = similarFilter(to: selectedID) else { return false }
        return applyQuickSelect(filter, mode: .replace)
    }

    // MARK: - Marquee (rubber-band) selection (UX-plan U5, gap G8)

    /// Begins a live marquee at a world point: sets a degenerate box anchored there.
    /// The canvas calls this on a select-mode mouse-down that did NOT hit an entity
    /// (an empty-space drag), then `updateMarquee` on each drag step.
    func beginMarquee(at world: Vector) {
        marqueeRect = AABB(point: world)
        marqueeCrossing = false
    }

    /// Updates the live marquee to span from its anchor (`from`) to the current
    /// cursor world point (`to`), setting `marqueeCrossing` from the drag DIRECTION:
    /// a right→left drag (`to.x < from.x`) is a CROSSING box (green, any touched), a
    /// left→right drag is a WINDOW box (blue, only fully enclosed) — the LibreCAD /
    /// AutoCAD convention. Bumps `modelVersion` so the overlay repaints.
    func updateMarquee(from anchor: Vector, to cursor: Vector) {
        marqueeRect = AABB(points: [anchor, cursor])
        marqueeCrossing = cursor.x < anchor.x
        modelVersion &+= 1
    }

    /// Commits the in-progress marquee: window/crossing-selects every selectable
    /// entity inside/touching `rect` (the engine's `Selection.windowSelect` +
    /// `SelectionPolicy.isSelectable` gate) and REPLACES the current selection (or,
    /// when `additive`, UNIONS into it — ⇧-drag adds). Clears the live marquee.
    /// Returns whether the selection changed (so the caller can skip a redraw).
    ///
    /// A degenerate (near-zero-area) marquee is treated as "no box" — it selects
    /// nothing and (when not additive) clears the selection, matching a plain click
    /// on empty space; the canvas only starts a marquee past the click threshold, so
    /// in practice this guards a stray sub-pixel drag.
    @discardableResult
    func commitMarquee(crossing: Bool, additive: Bool) -> Bool {
        defer { marqueeRect = nil }
        guard let rect = marqueeRect, !rect.isEmpty else {
            // No real box → behave like an empty-space click (clear unless additive).
            if !additive { return deselectAll() }
            return false
        }
        let layers = drawing.layers
        let hits = selection.windowSelect(
            rect: rect, crossing: crossing, in: drawing, using: quadtree
        ).filter { id in
            // Apply the same selectability gate Select All uses (skip locked/frozen).
            guard let e = drawing.entity(id) else { return false }
            return SelectionPolicy.isSelectable(e, layers: layers)
        }
        let newIDs: Set<EntityID> = additive
            ? selection.ids.union(hits)
            : Set(hits)
        guard newIDs != selection.ids else { return false }
        selection = Selection(ids: newIDs)
        modelVersion &+= 1
        return true
    }

    /// Cancels an in-progress marquee WITHOUT changing the selection (e.g. Esc).
    func cancelMarquee() {
        guard marqueeRect != nil else { return }
        marqueeRect = nil
        modelVersion &+= 1
    }

    // MARK: - Hover highlight (UX-plan U5, gap G8)

    /// Updates the hover-highlight target to the selectable entity under a screen
    /// point in SELECT mode (the cheap pre-selection affordance). Reuses the same
    /// `hitTest` a click uses (quadtree-prefiltered → exact distance), so it is the
    /// EXACT entity a click would select. No hover while a tool is active or the
    /// cursor is outside. Returns whether the hover target changed (so the caller can
    /// skip a redraw when it didn't).
    @discardableResult
    func updateHover(atScreenPoint screen: CGPoint) -> Bool {
        guard !isToolActive else { return setHover(nil) }
        let world = viewport.screenToWorld(screen)
        let id = selection.hitTest(
            worldPoint: world, worldTolerance: worldTolerance,
            in: drawing, using: quadtree
        )
        return setHover(id)
    }

    /// Clears the hover target (mouse left the canvas / tool activated). Returns
    /// whether it changed.
    @discardableResult
    func clearHover() -> Bool { setHover(nil) }

    /// Sets `hoverID` and returns whether it changed.
    @discardableResult
    private func setHover(_ id: EntityID?) -> Bool {
        guard hoverID != id else { return false }
        hoverID = id
        return true
    }

    // MARK: - Entity clipboard (UX-plan U5 — Cut / Copy / Paste / Duplicate)

    /// Whether the clipboard has content to paste (drives the context menu's Paste
    /// enabled state).
    var hasClipboard: Bool { !clipboard.isEmpty }

    /// Copies the current selection's records onto the in-app clipboard (a value
    /// snapshot). No-op for an empty selection. Returns whether anything was copied.
    @discardableResult
    func copySelection() -> Bool {
        guard !selection.isEmpty else { return false }
        let recs = selection.ids.compactMap { drawing.entity($0) }
        guard !recs.isEmpty else { return false }
        clipboard.copy(recs)
        return true
    }

    /// Cut = Copy then Delete the selection (one undoable deletion). Returns whether
    /// anything was cut.
    @discardableResult
    func cutSelection() -> Bool {
        guard copySelection() else { return false }
        return deleteSelection()
    }

    /// Pastes the clipboard at a target WORLD point (the right-click location), so the
    /// pasted geometry's reference corner lands at the cursor. The added records have
    /// RE-MINTED ids + offset geometry (via the pure `EntityClipboard`), go through the
    /// undoable `applyCommit(.add)` path (one undo step), and become the new selection.
    /// Returns whether anything was pasted.
    @discardableResult
    func paste(at target: Vector) -> Bool {
        paste(records: clipboard.pasteRecords(at: target))
    }

    /// Pastes the clipboard at the default offset (no cursor anchor — the menu-bar /
    /// keyboard Paste). Returns whether anything was pasted.
    @discardableResult
    func paste() -> Bool {
        paste(records: clipboard.pasteRecords())
    }

    /// Duplicates the current selection in place WITHOUT touching the clipboard (the
    /// ⌘D / "Duplicate" verb): resolves the selected records and runs them through the
    /// PURE `Duplicate.duplicate(_:offset:)` static API (one `.add` per entity, a deep
    /// value copy translated by `offset` — the AutoCAD-standard small nudge by default
    /// so the copies are grabbable apart from their sources), then applies the
    /// resulting `[ToolEdit]` through the shared undoable `.add` path, capturing the
    /// minted ids so the duplicates become the new selection (one undo step). Returns
    /// whether anything was duplicated. `offset: Vector(0, 0)` gives an exact in-place
    /// duplicate.
    @discardableResult
    func duplicateSelection(offset: Vector = Duplicate.defaultOffset) -> Bool {
        guard !selection.isEmpty else { return false }
        let recs = selection.ids.compactMap { drawing.entity($0) }
        // The exact call the ⌘D command funnels through: the pure static Duplicate API.
        let edits = Duplicate.duplicate(recs, offset: offset)
        guard !edits.isEmpty else { return false }
        // Reuse the shared add-and-select path: extract the `.add` records from the
        // edits, then add+select them through the same undoable group paste/duplicate
        // use. This keeps the duplicates selected and the undo a single step.
        let records: [EntityRecord] = edits.compactMap { edit in
            guard case .add(let r) = edit else { return nil }
            return r
        }
        return paste(records: records)
    }

    /// Shared add-and-select for paste/duplicate: routes `records` through the
    /// undoable `applyCommit(.add)` path (which mints each id + strips `.selected`)
    /// while CAPTURING the minted ids so the freshly-added geometry becomes the new
    /// selection. No-op (false) for an empty list.
    @discardableResult
    private func paste(records: [EntityRecord]) -> Bool {
        guard !records.isEmpty else { return false }
        // `applyCommit` mints ids internally but doesn't report them back; mint here
        // through the same undoable group so we can select the results. We open one
        // group, add each (capturing its id), keep the quadtree in sync, and select
        // the new ids — mirroring `applyCommit`'s `.add` arm exactly.
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        var newIDs: Set<EntityID> = []
        for record in records {
            var added = record
            added.id = EntityID(0)                  // ensure a fresh mint
            added.flags.remove(.selected)
            let id = drawing.add(added)             // undoable; mints a real id
            let box = drawing.entity(id)?.boundingBox() ?? added.boundingBox()
            if !box.isEmpty { quadtree.insert(id, bounds: box) }
            // BLOCK EDITOR: paste/duplicate INSIDE a block-edit session targets the
            // BLOCK — the pasted/duplicated geometry joins the editing block's members
            // (same undo group, before the `modelVersion` bump), not the document.
            if let editing = editingBlock {
                drawing.addEntityToBlock(name: editing, entityID: id)
            }
            newIDs.insert(id)
        }
        selection = Selection(ids: newIDs)
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    // MARK: - Ortho restriction (LibreCAD Ortho / AutoCAD F8)

    /// Toggles the persistent ortho flag (View ▸ Ortho / status bar). Bumps
    /// `modelVersion` so the menu checkmark + status chip refresh. (The transient
    /// hold-⇧ override is read live by the canvas — it does NOT flip this flag.)
    func toggleOrtho() {
        orthoEnabled.toggle()
        modelVersion &+= 1
    }

    // MARK: - Status-bar CAD toggles (Wave 4 — surfaces EXISTING state, no new snap logic)

    /// Toggles the grid's visibility (AutoCAD GRID / F7) — the same `gridVisible` flag
    /// the Inspector and the canvas context menu drive. Bumps `modelVersion` so the
    /// status-bar chip + menu state refresh; the renderer reads `gridVisible` on the
    /// next pack. Additive surface of existing state (no new grid logic).
    func toggleGrid() {
        gridVisible.toggle()
        modelVersion &+= 1
    }

    /// Toggles GRID SNAP (AutoCAD SNAP / F9) — the `.grid` bit of the existing
    /// `snapModes` set, routed through `setSnapMode` so it persists (the same undoable
    /// `$LC_SNAPMODE` path the Inspector's "Grid" snap toggle uses). This is the only
    /// snap on/off this wave surfaces as a single-flag toggle; the per-osnap object
    /// snaps stay in the Inspector's detailed list. `modelVersion` is bumped so the
    /// status chip refreshes immediately.
    func toggleGridSnap() {
        setSnapMode(.grid, !isSnapModeOn(.grid))
        modelVersion &+= 1
    }

    /// Whether grid snap (the `.grid` snap-mode bit) is currently on — the status
    /// bar's SNAP chip reads this. Read-only convenience over `isSnapModeOn(.grid)`.
    var gridSnapEnabled: Bool { isSnapModeOn(.grid) }

    /// The EFFECTIVE ortho state for a point input given whether ⇧ is held: the
    /// persistent flag XOR the transient hold-⇧ override (LibreCAD lets ⇧ flip ortho
    /// on-the-fly — ⇧ turns ortho ON when it is off, and OFF when it is on). The canvas
    /// passes the live Shift flag from the point-input path ONLY (it never reads the
    /// per-tool gizmo/keymap Shift), so this never disturbs the existing Shift uses.
    func orthoEffective(shiftHeld: Bool) -> Bool {
        orthoEnabled != shiftHeld
    }

    /// Applies the ortho constraint to a candidate world point for the active draw run,
    /// honoring CAD snap precedence (osnap > ortho > free):
    ///
    ///   1. If a REAL geometry snap is under the cursor (endpoint/center/middle/
    ///      intersection/onEntity — i.e. `osnapActive`), ortho is SKIPPED: the point is
    ///      returned unchanged so the user can always bind to existing geometry. (Grid
    ///      and free snaps are NOT geometry, so they don't override ortho.)
    ///   2. Else, with ortho effective AND a reference point (`relativeZero`, the last
    ///      placed point), the point is axis-locked via `OrthoConstraint.constrain`.
    ///   3. Else the point passes through unchanged (free).
    ///
    /// `point` is the already-snapped world point the tool would otherwise receive;
    /// `shiftHeld` is the live ⇧ flag from the point-input path. With no `relativeZero`
    /// (the FIRST point of a run) there is nothing to be orthogonal to, so the point is
    /// returned unchanged — ortho only constrains the second point onward.
    func orthoConstrained(_ point: Vector, shiftHeld: Bool) -> Vector {
        guard orthoEffective(shiftHeld: shiftHeld) else { return point }
        guard !osnapActive else { return point }                 // osnap wins
        guard let reference = relativeZero else { return point }  // need a last point
        return OrthoConstraint.constrain(point, relativeTo: reference)
    }

    /// Whether the latest `snap` is a REAL geometry snap (endpoint/center/middle/
    /// intersection/onEntity) — the snaps that must override ortho. Grid/free are not
    /// geometry, so they do not. `nil` snap ⇒ not active.
    var osnapActive: Bool {
        switch snap?.kind {
        case .endpoint, .center, .middle, .intersection, .onEntity,
             .perpendicular, .tangent, .nearest, .parallel:
            return true
        case .grid, .free, .none:
            return false
        }
    }

    /// Short status-bar label for the ortho readout: "Ortho" when the persistent flag
    /// is on, "—" when off (the transient ⇧ override is momentary and not shown here,
    /// mirroring how LibreCAD's status bar reflects the persistent mode).
    var orthoReadout: String { orthoEnabled ? "Ortho" : "\u{2014}" }
}
