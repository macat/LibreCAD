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
    /// `ToolSuggester` applied to the live query, the current selection state, and
    /// the MRU. Empty query ⇒ the adaptive default set; otherwise the fuzzy matches.
    /// A derived, side-effect-free read the chip row binds to.
    var commandBarSuggestions: [ToolKind] {
        ToolSuggester.suggestions(
            query: commandBarQuery,
            hasSelection: !selection.isEmpty,
            mru: commandBarMRU
        )
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

    /// Circle tool: whether numeric size entry is a radius (default) or diameter, and
    /// an optional EXACT size (0 ⇒ unset → two-click center+radius).
    var circleSizeMode: CircleSizeMode = .radius
    var circleFixedSize: Double = 0

    /// Arc tool: the construction mode (center→start→end default, or 3-point).
    var arcMode: ArcCreationMode = .centerStartEnd

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
    var activeSpaceEntities: [EntityRecord] {
        if editingBlock != nil { return editingBlockEntities }
        return PaperSpaceLayout.entities(
            in: drawing.entities, space: activeSpace, layoutName: activeLayout)
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
    func activateLayout(name: String) {
        setActiveSpace(.paper, layoutName: name)
    }

    /// Returns to model space (the "Model" tab). Convenience over `setActiveSpace`.
    func activateModel() {
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

    /// The name of the block currently being edited in place, or `nil` when not in a
    /// block-edit session. Drives `activeSpaceEntities` (which scopes the index /
    /// snapping / selection to the block's members) and is what the (future) chrome
    /// reads to show a "Editing block …" affordance. Purely live VIEW/session state —
    /// the member EDITS themselves are document mutations (undoable); this flag is not.
    private(set) var editingBlock: String?

    /// The member records (deep value copies) the block held when the session was
    /// entered, used to restore entry-state geometry on Discard. Empty when not editing.
    @ObservationIgnored
    private var editingEntrySnapshot: [EntityRecord] = []

    /// The block's ordered member-id list at session entry, restored on Discard so the
    /// block (and every insert) re-point at exactly the entry members.
    @ObservationIgnored
    private var editingEntryIDs: [EntityID] = []

    /// The view state (active space + layout + viewport) to restore when the session
    /// ends, so leaving the block returns the canvas to wherever it was on entry.
    @ObservationIgnored
    private var editingPriorView: (space: EntitySpace, layout: String?, viewport: Viewport)?

    /// `modelVersion` captured the instant the session opened (after the enter bump).
    /// The edit funnels (`applyCommit` / `applyInspectorEdits`) bump `modelVersion` on
    /// every committed change, so `modelVersion != editingEntryModelVersion` at exit
    /// means the session registered at least one undo step. We use this to AVOID
    /// stranding an empty (no-edit) session group on the undo stack: an untouched
    /// Save & Close (or the document-close guard firing with no edits) drops its empty
    /// group instead of leaving a no-op ⌘Z step.
    @ObservationIgnored
    private var editingEntryModelVersion = 0

    /// Whether a block-edit session is active.
    var isEditingBlock: Bool { editingBlock != nil }

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
    /// scope changes. No-op (returns `false`) if the block is unknown or a session is
    /// already active (re-entering must go through exit first, so the undo group + the
    /// entry snapshot stay coherent). Returns `true` on a started session.
    @discardableResult
    func enterBlockEditing(name: String) -> Bool {
        guard editingBlock == nil else { return false }            // already editing
        guard let block = drawing.blocks.block(named: name) else { return false }

        // Remember where to return on exit (the prior space/layout + camera).
        editingPriorView = (activeSpace, activeLayout, viewport)

        // Deep value snapshot of the entry-state members + the entry id list (for Discard).
        editingEntryIDs = block.entityIDs
        editingEntrySnapshot = block.entityIDs.compactMap { drawing.entity($0) }

        // Enter the scope (canonicalize to the stored block name's casing).
        editingBlock = block.name

        // ONE undo group for the whole session — a single ⌘Z reverts it all. Mirrors the
        // explicit-grouping rationale in `applyCommit` (the inner per-commit groups nest).
        undoManager.beginUndoGrouping()

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
        // Capture the post-bump version: any later change is a session edit (used at
        // exit to drop an empty no-edit group rather than strand a no-op ⌘Z step).
        editingEntryModelVersion = modelVersion
        return true
    }

    /// Leaves the current block-edit session.
    ///
    /// - `save == true` (Save & Close): keep the edits — they are already applied to the
    ///   live member records and already undoable. The session undo group is closed so a
    ///   single ⌘Z reverts the whole session.
    /// - `save == false` (Discard): restore the entry-state members + member-id list from
    ///   the snapshot (so the block AND every insert return to entry geometry), close the
    ///   session group, then drop that now-net-identity group off the undo stack so
    ///   `canUndo` returns to its pre-enter value (no stranded half-session steps).
    ///
    /// A session that made NO edits (the user double-clicked, looked around, and left)
    /// drops its empty group on EITHER path so it never strands a no-op ⌘Z step that
    /// would silently consume the user's prior real undo — the change is detected via
    /// `modelVersion` (only the edit funnels bump it during a session).
    ///
    /// Either way the canvas scope + camera are restored to the prior view, the index is
    /// rebuilt for that space, and transient interaction state is cleared. No-op (returns
    /// `false`) if no session is active. Presents NO modal — the (future) view layer asks
    /// the user Save/Discard and calls this with the answer.
    @discardableResult
    func exitBlockEditing(save: Bool) -> Bool {
        guard let name = editingBlock else { return false }

        // Did any edit funnel commit during the session? (Only `applyCommit` /
        // `applyInspectorEdits` bump `modelVersion` between enter and here.)
        let sessionChanged = modelVersion != editingEntryModelVersion

        if save && sessionChanged {
            // Keep edits: just close the session group (one ⌘Z reverts the session).
            undoManager.endUndoGrouping()
        } else if save {
            // Save & Close with NO edits: close the empty group and drop it so the undo
            // stack stays at its pre-enter depth (no stranded no-op step).
            undoManager.endUndoGrouping()
            if undoManager.canUndo { undoManager.undo() }
        } else if sessionChanged {
            // Discard: restore the entry snapshot through the undoable funnels (so the
            // restorations are captured INSIDE the still-open session group), making the
            // group net-identity.
            restoreBlockEntrySnapshot(name: name)
            undoManager.endUndoGrouping()
            // Drop the net-identity session group off the undo stack so the stack depth
            // matches the pre-enter state (canUndo back to its prior value). Undoing a
            // net-identity group leaves geometry at the entry state.
            if undoManager.canUndo { undoManager.undo() }
        } else {
            // Discard with NO edits: nothing to restore — just drop the empty group.
            undoManager.endUndoGrouping()
            if undoManager.canUndo { undoManager.undo() }
        }

        // Restore the prior view scope + camera, then leave the session.
        let prior = editingPriorView
        editingBlock = nil
        editingEntrySnapshot = []
        editingEntryIDs = []
        editingPriorView = nil
        if let prior {
            activeSpace = prior.space
            activeLayout = prior.layout
            viewport = prior.viewport
        }
        renderOrigin = RendererGeometry.renderOrigin(for: activeSpaceBoundingBox)

        rebuildIndex()
        selection.clear()
        snap = nil
        hoverID = nil
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// Auto-saves and closes an active block-edit session if one is open (a no-op
    /// otherwise). The (future) view layer calls this when the session must end
    /// unexpectedly — e.g. the document is being closed — because the member edits are
    /// already in the document (the live-member crux), so Save&Close is the safe,
    /// non-destructive default. Presents NO modal (it is reachable from the document
    /// lifecycle, which a unit test exercises). Returns whether a session was closed.
    @discardableResult
    func finishBlockEditingIfNeeded() -> Bool {
        guard editingBlock != nil else { return false }
        return exitBlockEditing(save: true)
    }

    /// Restores a block's members + member-id list to the entry snapshot, through the
    /// undoable `CADDrawing` funnels so the restorations register inside the open session
    /// group (Discard). Member records present at entry are `replace`d back (re-added if
    /// they were deleted during the session); members ADDED during the session (ids not
    /// in the entry set) are removed; then the member-id list is re-pointed to the entry
    /// list via `setBlockMembers`. A block that vanished entirely is skipped.
    private func restoreBlockEntrySnapshot(name: String) {
        guard drawing.blocks.contains(name) else { return }

        let entryIDSet = Set(editingEntryIDs)
        // Remove members that were ADDED during the session (not part of entry).
        let currentIDs = drawing.blocks.block(named: name)?.entityIDs ?? []
        for id in currentIDs where !entryIDSet.contains(id) {
            drawing.remove(id)
            quadtree.remove(id)
            selection.remove(id)
        }
        // Restore each entry member's full record (re-adds any that were deleted). NOTE:
        // a member deleted mid-session is re-added at the draw-order TAIL (drawing.replace
        // falls back to add for an absent id), not its original storage index. This is
        // harmless for block/insert resolution (members resolve in `entityIDs` order,
        // which is restored by `setBlockMembers` below) — only the raw draw-order index of
        // a re-added member is not preserved.
        for record in editingEntrySnapshot {
            drawing.replace(record)
        }
        // Re-point the block at exactly the entry member-id list.
        drawing.setBlockMembers(name: name, ids: editingEntryIDs)
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
        toolStatus = tool?.status ?? ""
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
        case var t as CircleTool:
            t.sizeMode = circleSizeMode
            t.fixedSize = circleFixedSize > 0 ? circleFixedSize : nil
            tool = t
        case is ArcTool:
            // ArcTool's `mode` is fixed at construction (it seeds the start state),
            // so re-mint with the configured mode (mirrors the DivideTool pattern).
            tool = ArcTool(mode: arcMode)
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
        // Some tools are RE-MINTED by `applyToolConfig` (DivideTool's count, ArcTool's
        // mode, EllipseTool's mode, BaselineDimTool's spacing, ImageTool's file are fixed
        // at construction), which resets their state/status to the initial prompt. For
        // those, take the fresh tool's status; for the in-place tools (which keep their
        // state) restore the prior prompt text.
        if tool is DivideTool || tool is ArcTool || tool is EllipseTool
            || tool is BaselineDimTool || tool is ImageTool {
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
            applyCommit(edits)
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

    /// Applies a tool's committed edits to the drawing as ONE undoable group, so a
    /// single undo reverts the whole tool action. Each edit is applied through the
    /// undoable `CADDrawing` mutations (ADR-002) and mirrored into the quadtree so
    /// the result is immediately snappable/selectable; the GPU model buffer is
    /// marked dirty so the renderer repacks it.
    ///
    /// Quadtree consistency: the `add`/`replace`/`remove` here keep the index in
    /// sync directly. On undo/redo the drawing's value-snapshot restore does NOT
    /// touch the quadtree (the undo closures only know about `entities`), so
    /// `undo()`/`redo()` rebuild the whole index — see those methods.
    private func applyCommit(_ edits: [ToolEdit]) {
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
                let id = drawing.add(added)            // undoable; mints a real id
                let box = drawing.entity(id)?.boundingBox() ?? added.boundingBox()
                if !box.isEmpty { quadtree.insert(id, bounds: box) }

            case .replace(let id, let newKind):
                // Preserve the entity's layer/pen/flags; swap only its geometry.
                guard var record = drawing.entity(id) else { continue }
                record.kind = newKind
                drawing.replace(record)                // undoable
                let box = record.boundingBox()
                if box.isEmpty { quadtree.remove(id) } else { quadtree.update(id, bounds: box) }

            case .remove(let id):
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
        applyCommit(edits)
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
        applyCommit(edits)
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
