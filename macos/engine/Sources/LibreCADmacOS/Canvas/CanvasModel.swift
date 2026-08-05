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

/// A `@unchecked Sendable` box for the `Quadtree` so a `@Sendable` closure can
/// capture the live MainActor index and query it via `MainActor.assumeIsolated`.
/// The box itself is `Sendable` but the underlying `Quadtree` is only accessed
/// on `MainActor` (the closure is only invoked from `MainActor` code — the tool
/// `handle` path in `CanvasModel.handleToolInput`). This keeps `ToolContext`
/// honestly `Sendable` for the engine tests while the live canvas path uses the
/// real spatial index.
private struct SendableQuadtree: @unchecked Sendable {
    let tree: Quadtree
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

    /// The ids of constraints that, after the most recent re-solve, live in a
    /// component the solver could NOT satisfy (`.failed` — over-constrained / non-
    /// convergent / unsupported). The geometry does NOT honor these constraints, so the
    /// UI must flag them rather than show them as if they hold: the glyph overlay tints
    /// their badge in a WARNING style and the Constraints list marks the row. Recomputed
    /// in `resolveConstraints` for the components it touched (and over the WHOLE table on
    /// `setDrawing`, so a freshly-loaded drawing flags any constraint its restored
    /// geometry does not satisfy). The common case is EMPTY (every constraint solves).
    ///
    /// OBSERVED (no `@ObservationIgnored`) so the SwiftUI Constraints sidebar repaints
    /// when membership changes; the AppKit glyph overlay reads it on its `refresh()`.
    var unsatisfiedConstraintIDs: Set<UUID> = []

    /// The outcome of the most recent `commitConstraints` call — read by the selection-
    /// apply funnels (`applyGeometricConstraintToSelection` /
    /// `applyDimensionalConstraintToSelection`) to distinguish an OVER-CONSTRAINED
    /// rejection (post the "would conflict — delete a constraint" message) from a plain
    /// arity failure. `@ObservationIgnored`: transient internal handoff, never rendered.
    @ObservationIgnored
    var lastConstraintCommitResult: ConstraintCommitResult = .noneAdded

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

    /// The active ANNOTATION SCALE (the AutoCAD `CANNOSCALE` factor, e.g. 1:50 ⇒
    /// `0.02`). The render path threads this into the resolve context
    /// (`makeResolveContext(annotationScale:)`) so an annotative text/mtext STYLE
    /// renders at this scale; the StatusBar scale picker binds to it. Seeded from /
    /// written back to the drawing's `$CANNOSCALE` header var (so it persists), via
    /// `loadSettingsFromDrawing` on open and `setAnnotationScale` on edit. Default
    /// `1.0` (1:1) means annotative text draws at its authored height — so the
    /// out-of-the-box render is byte-identical to before this wave.
    var annotationScale: Double = 1.0

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

    /// Whether POLAR tracking is on (LibreCAD's polar restriction, AutoCAD F10). When
    /// on, a draw tool's candidate point is locked onto the ray from the last placed
    /// point (`relativeZero`) at the NEAREST multiple of `polarAngleIncrement`,
    /// preserving the cursor's distance from that reference — a finer-grained angular
    /// lock than ortho's two fixed axes. ORTHO and POLAR are MUTUALLY EXCLUSIVE (like
    /// LibreCAD / AutoCAD): turning one on turns the other off, so the canvas only ever
    /// applies one angular constraint. Observed so the menu checkmark + status-bar chip
    /// track it live. A live interaction policy (not persisted to the document, like
    /// ortho / the cursor mode). UNWIRED here — the canvas hook is a later wire-wave.
    var polarEnabled: Bool = false

    /// The angular step POLAR snaps the candidate point to, in RADIANS. Defaults to 15°
    /// (`.pi / 12`), LibreCAD's classic polar increment. A live drafting setting (not
    /// persisted), consumed by `polarConstrained` via `PolarConstraint.constrain`.
    var polarAngleIncrement: Double = .pi / 12

    /// The live ⇧ flag for the polar-TRACKING gate (the dotted-ray DISPLAY), mirroring
    /// the `shiftHeld` parameter `polarConstrained` already takes on the point-input
    /// path: ⇧ releases polar, so while it is held no tracking ray is shown either.
    /// CanvasModel imports no AppKit, so the model cannot read `NSEvent.modifierFlags`
    /// itself; the canvas view (which already reads `Self.shiftHeld`) pushes the flag
    /// here on each cursor event in a later wire-wave. `@ObservationIgnored` like `tool`
    /// — it is interaction state consumed by `updateSnap`, not a directly-rendered
    /// property. Defaults `false` (no ⇧) so headless tests and the not-yet-wired state
    /// behave as "⇧ not held". This is DISPLAY-only and does NOT touch the always-on
    /// angle LOCK (`polarConstrained` keeps reading its own `shiftHeld` parameter).
    @ObservationIgnored
    var polarTrackingShiftHeld: Bool = false

    /// Half-width of the polar-tracking engagement wedge, in RADIANS (≈3°). The dotted
    /// tracking ray + distance readout are SHOWN only while the cursor lies within this
    /// aperture of the engaged increment ray (`PolarTracking.Result.withinAperture`).
    /// Draw-gating ONLY — it never affects the always-on angle lock (see the kernel
    /// header). A constant, not a user setting (the lock increment is the tunable knob).
    static let polarApertureRadians: Double = 3.0 * .pi / 180.0

    /// Length of the drawn polar tracking ray, in WORLD units — a generous constant so
    /// the dotted ray spans any realistic viewport; the overlay clips it to the visible
    /// rect, so over-long is harmless and avoids threading a per-frame view extent into
    /// the model. Rendering-only (the kernel degrades a non-finite length gracefully).
    static let polarTrackingRayLengthWorld: Double = 1.0e9

    /// The latest polar-TRACKING result under the cursor — the engaged increment ray,
    /// its draw-gating `withinAperture` bit, and the far ray endpoint a future overlay
    /// draws. Refreshed inside `updateSnap` AFTER the snap is set (so a real osnap can
    /// suppress it), or `nil` when polar tracking is not engaged. DISPLAY data only: it
    /// is the visual sibling of the always-on `polarConstrained` lock and never changes
    /// it. `@ObservationIgnored` like `tool` — the overlay reads it via `trackingDisplay()`
    /// on the same redraw the snap marker drives, so it needs no independent observation.
    @ObservationIgnored
    var polarTrackingResult: PolarTracking.Result?

    // MARK: Object-snap tracking (OTRACK) — W5 model layer

    /// Whether OBJECT-SNAP TRACKING (OTRACK — LibreCAD's object snap tracking,
    /// AutoCAD F11) is on. UNLIKE ortho/polar (which are mutually exclusive with each
    /// other), OTRACK is an INDEPENDENT aid: it can be on together with ortho OR polar,
    /// so `toggleObjectTracking` never disturbs `orthoEnabled`/`polarEnabled`. When on,
    /// REAL object snaps the user hovers (endpoint/center/…) can be ACQUIRED (added to
    /// `acquiredPoints`); the cursor then locks onto the alignment guides radiating from
    /// those points (horizontal/vertical/polar) — or onto the intersection of two guides.
    /// `@ObservationIgnored`: like the polar-tracking display state, the overlay reads it
    /// via `trackingDisplay()` on the same redraw the snap marker drives. A live drafting
    /// policy. UNLIKE the original `false` default, it is now an APP PREFERENCE that
    /// persists across launches (like `dynamicInputEnabled`): seeded at init from
    /// `AppSettings.Key.objectTracking` (default OFF, matching the historical model
    /// default) and `toggleObjectTracking()` writes it back to `UserDefaults`, so the
    /// Preferences toggle + persistence actually take effect. The dwell-to-acquire
    /// trigger, the guide rendering, and the toggle key are LATER waves (W6/W7).
    @ObservationIgnored
    var objectTrackingEnabled: Bool = AppSettings.boolPreference(
        AppSettings.Key.objectTracking, default: AppSettings.Default.objectTracking)

    /// The snap points the user has ACQUIRED for object-snap tracking — the small "+"
    /// glyphs OTRACK radiates alignment guides from. Mutated only through
    /// `acquireTrackingPoint` (append / toggle-off duplicate / drop-oldest at the cap) and
    /// `clearTrackingPoints`; transient drafting state cleared on tool change / run-end /
    /// cursor-leave, NEVER persisted. `@ObservationIgnored`: read via `trackingDisplay()`.
    @ObservationIgnored
    private(set) var acquiredPoints: [AcquiredPoint] = []

    /// The latest OTRACK lock under the cursor — the guide projection or two-guide
    /// intersection the cursor snapped to, plus the engaged guide(s) and the
    /// distance/angle from the first guide's origin. Refreshed inside `updateSnap` AFTER
    /// the snap is set (so a real osnap suppresses it — geometry snap wins), or `nil` when
    /// OTRACK is not engaged / no guide is near. DISPLAY + constraint data only.
    /// `@ObservationIgnored`: read via `trackingDisplay()` / `trackingConstrained`.
    @ObservationIgnored
    private(set) var trackingResult: TrackingResult?

    /// The cap on the number of simultaneously-acquired OTRACK points (AutoCAD-like).
    /// Acquiring beyond this drops the OLDEST acquired point (FIFO), keeping the guide
    /// list bounded so resolving stays responsive (rendering-performance.md §5).
    static let maxAcquiredPoints = 7

    /// Whether DYNAMIC INPUT — the AutoCAD-style live dimensional feedback (a dotted dim
    /// line + value chip an active draw tool shows while you drag) — is on (AutoCAD F12,
    /// DYNMODE). When on, `currentLiveDimensions()` returns the active tool's
    /// `[LiveDimension]` so the on-canvas `LiveDimensionOverlayView` can draw it; when
    /// off it returns `[]` and the overlay stays blank. UNLIKE ortho/polar (live-only
    /// drafting aids), this is an APP PREFERENCE that persists across launches: it is
    /// seeded at init from `AppSettings.Key.dynamicInput` (default `true`) and
    /// `toggleDynamicInput()` writes it back to `UserDefaults`. Observed so the status-bar
    /// DYN chip + the menu/preferences toggle track it live.
    var dynamicInputEnabled: Bool = AppSettings.boolPreference(
        AppSettings.Key.dynamicInput, default: AppSettings.Default.dynamicInput)

    /// How the status-bar coordinate readout is rendered — ABSOLUTE world point,
    /// RELATIVE offset from the last point, or POLAR `dist<angle` (backlog #5). The
    /// single-keystroke "cycle coordinate mode" command advances this through
    /// `absolute → relative → polar → absolute`. Observed so the status bar's coord
    /// segment re-renders on a cycle. A live VIEW policy (not document content, not
    /// undoable). UNWIRED — the status-bar button is a later wire-wave.
    var coordinateDisplayMode: CoordinateDisplayMode = .absolute

    /// The active USER COORDINATE SYSTEM — a rotated/translated input/display frame
    /// (LibreCAD / AutoCAD UCS). The document always stores geometry in WORLD
    /// coordinates; this frame is applied ONLY at the input/display boundary: the
    /// status-bar coordinate readouts convert the cursor's world point INTO this frame
    /// before formatting, typed command-line coordinates are interpreted RELATIVE to it,
    /// and the on-canvas UCS axis gizmo anchors at its origin/angle. It defaults to
    /// `.world` (the identity frame), in which case every conversion is a no-op and the
    /// output is byte-identical to having no UCS. Mutated only through `setUCS` /
    /// `resetUCS` (which bump `modelVersion` so the chrome refreshes). A live DRAFTING
    /// policy — NOT document content, NOT undoable, NOT persisted (DXF round-trip is a
    /// later wave). Ortho/grid-relative and the set-UCS UI are also later waves.
    var currentUCS: UCS = .world

    /// The state of an in-progress interactive "set UCS by picking" gesture (UCS-W3).
    /// Mirrors the lightweight transient-pick style of `settingRelativeZeroArmed` /
    /// `zoomWindowArmed` (a model-owned interaction state, NOT a `Tool` / `ToolKind`):
    /// the canvas view feeds SNAPPED clicks to `ucsPickClick(_:)` and routes Esc to
    /// `cancelUCSPick()` while `isUCSPicking`. Two flavors:
    ///   - 1-point ("Set UCS Origin"): one click sets `currentUCS` to that origin with
    ///     angle 0 (axes parallel to world), then the pick ends.
    ///   - 2-point ("Set UCS by 2 Points"): the first click captures the origin, the
    ///     second click defines the UCS +X direction; `currentUCS` becomes that origin
    ///     rotated to point its +X at the second click, then the pick ends.
    /// `.inactive` is the resting state (the predicate `isUCSPicking` reads `!= .inactive`).
    /// Driven only through `beginUCSPick` / `ucsPickClick` / `cancelUCSPick`, each of which
    /// bumps `modelVersion` so the status prompt + axis overlay chrome refresh.
    enum UCSPick: Equatable {
        /// No pick in progress (resting state).
        case inactive
        /// Awaiting the UCS ORIGIN click. `twoPoint` records whether a second
        /// (X-axis) click follows (2-point flavor) or the origin click finishes it
        /// (1-point flavor, axes parallel to world).
        case awaitingOrigin(twoPoint: Bool)
        /// Awaiting the X-AXIS click (2-point flavor only); `origin` is the captured
        /// first click. The second click's direction from `origin` sets the UCS angle.
        case awaitingXAxis(origin: Vector)
    }

    /// The live UCS-pick gesture state (UCS-W3). `.inactive` unless the user invoked
    /// "Set UCS by 2 Points" / "Set UCS Origin" (View menu). Interaction state, not
    /// document content — not undoable, not persisted. Observed (via `modelVersion`
    /// bumps) so the status prompt + cursor reflect the pick.
    private(set) var ucsPick: UCSPick = .inactive

    /// Whether a UCS-pick gesture is in progress (the canvas consults this to route
    /// clicks/Esc into the pick instead of the active tool / selection).
    var isUCSPicking: Bool { ucsPick != .inactive }

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

    // MARK: Dynamic-input editing state (editable live dimensions — Wave M)

    /// Whether the user is TYPING into a live-dimension field (AutoCAD-style dynamic
    /// input). Set by `beginDynInput(firstChar:)` the first time a digit / `.` / `-`
    /// is pressed while a draw tool exposes an editable live dimension; cleared by
    /// `dynCommit` / `cancelDynInput` / `resetDynInput` (and the run-end / tool-change
    /// hooks). While `true` the model drives the active tool with the SYNTHETIC cursor
    /// (`effectiveCursor()`) so the rubber-band preview + live dims reflect the typed
    /// values, and `currentLiveDimensions()` re-stamps the editable dims as
    /// `.active`/`.locked`. `@ObservationIgnored` like `tool` — interaction state the
    /// explicit methods publish (via `modelVersion`), not a directly-rendered property.
    @ObservationIgnored
    var dynEditing = false

    /// The live-dimension field the user is currently typing into (the `.active` field),
    /// or `nil` when not editing. Advanced by `dynCycleField(reverse:)` (Tab / Shift-Tab)
    /// over `editableFields()` in array order. Re-clamped to a still-valid field (or
    /// cleared) whenever the tool's editable-field set changes mid-run.
    @ObservationIgnored
    var dynActiveField: LiveDimensionField? = nil

    /// The raw text the user has typed for each field, keyed by `LiveDimensionField`. A
    /// field is **LOCKED** ⟺ it is NOT `dynActiveField` AND its buffer parses to a
    /// `Double`; a locked or active buffer that parses feeds `effectiveCursor()` so the
    /// preview honors it live. Partial / unparseable buffers (e.g. `"-"`, `"1."`) are
    /// simply omitted from `parsedDynValues()`, so that field naturally tracks the live
    /// cursor until the text becomes a number. Cleared by `resetDynInput`.
    @ObservationIgnored
    var dynBuffers: [LiveDimensionField: String] = [:]

    /// Whether the canvas is armed for a one-shot "Set Relative Origin" pick: the NEXT
    /// snapped canvas click (in select mode) sets `relativeZero` to that point instead
    /// of toggling selection, then auto-disarms (mirrors the Zoom-Window one-shot arm).
    /// The existing select-mode click path (`toggleSelection`) consults this first, so
    /// no change to the canvas view is needed. Observed so a status chip / the cursor
    /// can reflect the armed "pick a point" state.
    private(set) var settingRelativeZeroArmed: Bool = false

    /// The most recent error from a command-line submission (`interpretCommandLine`),
    /// or `nil` after a successful submit. The command field echoes it so a typo
    /// like `1,,2` shows "Expected x,y" instead of silently doing nothing.
    private(set) var lastCommandError: String?

    // MARK: Command transcript (the AutoCAD-style scrollback above the command line)

    /// The kind of one line in the command transcript — drives its color/role in the
    /// scrollback view. Pure value, `Sendable` so it crosses no isolation boundary.
    enum TranscriptKind: Sendable, Equatable {
        /// The raw line the user submitted (echoed back, e.g. `> line`).
        case input
        /// An informational readout the model emitted (e.g. a resolved point).
        case output
        /// An error message (a parse failure / unknown command) — shown in red.
        case error
        /// A tool was activated by name from the command line (shown in the accent).
        case tool
    }

    /// One immutable entry in the command transcript: its `kind` (color/role) + the
    /// already-formatted display `text`. A plain value (`Equatable`/`Sendable`) so the
    /// scrollback diffs cheaply and the buffer is trivially testable headlessly.
    struct TranscriptEntry: Equatable, Sendable {
        let kind: TranscriptKind
        let text: String
    }

    /// The rolling AutoCAD-style command history shown in the scrollback pane ABOVE the
    /// merged command line. Appended at the single `interpretCommandLine` choke point
    /// (NOT scattered through every tool); capped at `maxTranscriptEntries` (oldest
    /// dropped) so it never grows unbounded. Session-only (not undoable / not persisted).
    /// `private(set)` — mutated only via `appendTranscript` / `clearTranscript`.
    private(set) var commandTranscript: [TranscriptEntry] = []

    /// The hard cap on the transcript ring buffer. When `append` would exceed this, the
    /// OLDEST entries are dropped so the newest `maxTranscriptEntries` are kept in order.
    let maxTranscriptEntries = 200

    /// Append one line to the command transcript, dropping the oldest entries past the
    /// `maxTranscriptEntries` cap so the buffer never grows unbounded. Bumps
    /// `modelVersion` so the scrollback view refreshes + auto-scrolls to the newest line.
    func appendTranscript(_ kind: TranscriptKind, _ text: String) {
        commandTranscript.append(TranscriptEntry(kind: kind, text: text))
        if commandTranscript.count > maxTranscriptEntries {
            commandTranscript.removeFirst(commandTranscript.count - maxTranscriptEntries)
        }
        modelVersion &+= 1
    }

    /// Clear the command transcript (the "Clear" affordance / a fresh session). Bumps
    /// `modelVersion` so the scrollback view empties.
    func clearTranscript() {
        guard !commandTranscript.isEmpty else { return }
        commandTranscript.removeAll(keepingCapacity: true)
        modelVersion &+= 1
    }

    // MARK: Command bar state (the bottom AutoCAD-style tool launcher)

    /// The live text typed into the bottom command BAR's tool-filter field. While
    /// empty the bar shows the adaptive default chip set; as it fills, the chips
    /// narrow to the fuzzy matches (see `ToolSuggester`). Distinct from the
    /// coordinate/command-line text the view owns for `interpretCommandLine` — this one
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

    // MARK: Wave-3B parameterized-tool options (Divide / Spline / Scale / Hatch)
    //
    // These mirror the existing circle/arc construction-mode pattern: the live engine
    // tool fixes the mode at construction (or carries it as a public `var`), so
    // `applyToolConfig` re-mints / re-applies it from the model state the Tool Options
    // bar (Wave 3F) binds to. Defaults reproduce each tool's original behavior, so an
    // un-touched bar is byte-for-byte the pre-Wave-3 flow.

    /// Divide tool: whether the DivideTool runs in DIVIDE-by-COUNT (`.count`, the
    /// default — drop `n−1` interior points) or MEASURE-by-LENGTH (`.length` — drop a
    /// node every `divideSpacing` units along the curve). The options bar (3F) toggles
    /// this; `applyToolConfig` re-mints the DivideTool with the assembled `DivideMode`.
    /// `0` selects count; `1` selects length. Stored as an INDEX (the engine
    /// `DivideTool.DivideMode` carries an associated value, so it can't be a Picker tag
    /// — the same UI-simple split the Polygon/Rectangle/Ellipse pickers use).
    var divideModeStyle: Int = 0

    /// The MEASURE spacing (world units along the curve) used when `divideModeStyle ==
    /// 1` (`.length`). A non-positive spacing yields no nodes (the tool's own guard), so
    /// the bar should keep it > 0. Ignored in count mode.
    var divideSpacing: Double = 10.0

    /// The `DivideTool.DivideMode` assembled from the split UI state (`divideModeStyle`
    /// + `divideCount` / `divideSpacing`). The single mapping `applyToolConfig` and the
    /// wiring test share, so the options bar and the re-mint never drift. Mode `1`
    /// (length) clamps the spacing finite-and-positive; otherwise count (clamped ≥ 2).
    var divideMode: DivideTool.DivideMode {
        if divideModeStyle == 1 {
            let s = (divideSpacing.isFinite && divideSpacing > 0) ? divideSpacing : 10.0
            return .length(s)
        }
        return .count(Swift.max(2, divideCount))
    }

    /// Spline tool: how the picked points are interpreted on commit — FIT points
    /// (`.fit`, the default `.splinePoints` interpolation curve) vs NURBS CONTROL
    /// points (`.controlPoints`, a `.spline` B-spline whose control polygon IS the
    /// picks). `SplineTool.mode` is a `let` fixed at construction, so `applyToolConfig`
    /// RE-MINTS the tool with this (the DivideTool/ArcTool re-mint pattern).
    var splineMode: SplineMode = .fit

    /// Scale tool: the construction MODE — `.factor` (the original three-pick
    /// distance-ratio scale, the default), `.reference` (scale-by-reference-length), or
    /// `.nonUniform` (independent per-axis `(sx, sy)` about a single base). `ScaleTool`
    /// carries `mode` + `nonUniformFactors` as public `var`s (no-arg `init()`), so
    /// `applyToolConfig` sets them IN PLACE on the live tool. The non-uniform factors
    /// come from `scaleX` / `scaleY`.
    var scaleMode: ScaleTool.ScaleMode = .factor
    /// Scale tool: the per-axis X factor used by `.nonUniform` mode (default 1 ⇒ no-op).
    var scaleX: Double = 1
    /// Scale tool: the per-axis Y factor used by `.nonUniform` mode (default 1 ⇒ no-op).
    var scaleY: Double = 1

    /// Hatch tool: the chosen pattern NAME (case-insensitive; resolved against the
    /// bundled `HatchPatternLibrary` at draw time), or `nil` ⇒ a SOLID fill (the
    /// back-compatible default). The options bar (3F) picks a name from
    /// `HatchPatternLibrary.patterns`; `applyToolConfig` assembles it into the
    /// `HatchTool.Fill` (`.solid` for `nil`/"SOLID", else `.pattern`).
    var currentHatchPattern: String?
    /// Hatch tool: the per-hatch pattern SCALE (DXF code 41) applied to a named
    /// pattern. `<= 0`/non-finite is normalized to 1 by the tool. Ignored for solid.
    var hatchPatternScale: Double = 1
    /// Hatch tool: an EXTRA pattern rotation (DXF code 52, RADIANS). The options bar
    /// may edit a friendlier degrees value over this. Ignored for solid.
    var hatchPatternAngle: Double = 0

    /// The `HatchTool.Fill` assembled from the split UI state (`currentHatchPattern` +
    /// scale/angle). The single mapping `applyToolConfig` and the wiring test share. A
    /// `nil`/empty/"SOLID" name (case-insensitive) is a solid fill; any other name is a
    /// named pattern carrying the scale + angle.
    var hatchFillValue: HatchTool.Fill {
        guard let name = currentHatchPattern,
              !name.trimmingCharacters(in: .whitespaces).isEmpty,
              name.uppercased() != "SOLID" else { return .solid }
        let s = (hatchPatternScale.isFinite && hatchPatternScale > 0) ? hatchPatternScale : 1
        return .pattern(name: name, scale: s, angle: hatchPatternAngle)
    }

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
    ///
    /// Index 5 = `.isocircle` (the ISOMETRIC-circle mode — Wire-wave 3): an ellipse
    /// drawn as the iso-projection of a circle onto the ACTIVE iso plane. The plane is
    /// the live `isoPlane` (so the isocircle follows the current isoplane the moment the
    /// user F5-cycles it), matching AutoCAD's `ELLIPSE > Isocircle`, which is only
    /// offered while `SNAPSTYLE == 1`. The ToolOptionsBar surfaces this as the "Iso"
    /// segment (selectable any time; it draws an isocircle on the current plane).
    var ellipseModeValue: EllipseTool.Mode {
        switch ellipseModeIndex {
        case 1:  return .fociPoint
        case 2:  return .fourPoint
        case 3:  return .inscribeQuad
        case 4:  return .arc
        case 5:  return .isocircle(plane: isoPlane)
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

    /// PARAMETRIC AUTO-BIND (Lane L2): the dimensional constraint KIND currently "in
    /// flight" on the selection — set when the user starts a Distance/Radius dimensional
    /// constraint that is awaiting a value. While this is non-nil, a `name=value` line on
    /// the command line not only creates the parameter but AUTO-BINDS a dimensional
    /// constraint of this kind to the just-created parameter over the CURRENT selection
    /// (`interpretCommandLine` → `addConstraint(_:entities:expression:)`), so the dimension
    /// is parameter-driven rather than a frozen literal. `nil` ⇒ no constraint awaiting a
    /// value (a `name=value` line then just defines/updates the parameter). Set via
    /// `beginDimensionalConstraint(_:)`; cleared once consumed (or on cancel). The
    /// mid-line-DRAW dynamic-input binding (binding a length as a segment is rubber-banded)
    /// is a deferred follow-up beyond this CanvasModel selection flow.
    var pendingDimensionalConstraint: DimensionalConstraintKind?

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

    /// Multileader (MLEADER) tool: the optional attached annotation text (empty ⇒ a
    /// bare multileader), its cap height, and the landing ("dogleg") tail length +
    /// whether that tail is drawn. `applyToolConfig` pushes them onto `MultiLeaderTool`.
    var multiLeaderText: String = ""
    var multiLeaderTextHeight: Double = 2.5
    var multiLeaderLandingDistance: Double = 2.0
    var multiLeaderDoglegEnabled: Bool = true

    /// Baseline dimension tool: the DIMDLI spacing (world units) each successive
    /// dimension line is stepped further out by. `applyToolConfig` maps it onto
    /// `BaselineDimTool.baselineSpacing`.
    var baselineSpacing: Double = BaselineDimTool.defaultBaselineSpacing

    // MARK: Wire-wave-4 tool options (Offset modes / Rotate-Mirror copy / Line construction)

    /// Offset tool: which mode decides the offset distance. `OffsetTool.OffsetMode`
    /// is `Equatable` but NOT `Hashable`, so it can't be a SwiftUI Picker tag — bound
    /// as a case INDEX (the Trim/Scale/Ellipse split the brief prescribes). 0 =
    /// `.through` (the original behavior — the offset copy passes through the picked
    /// point; the default), 1 = `.distance` (offset by a fixed `offsetDistance`, the
    /// click only chooses the side). `applyToolConfig` maps the index → `OffsetMode`.
    var offsetModeIndex: Int = 0
    /// Offset tool: the fixed offset distance (world units) used by `.distance` mode
    /// (`offsetModeIndex == 1`). Ignored in `.through` mode. Non-positive ⇒ no offset
    /// (the tool's own safe no-op).
    var offsetDistance: Double = 10.0
    /// Offset tool: when `true`, also emit the OPPOSITE-side offset copy for each
    /// source (LibreCAD "both sides"). Default `false` ⇒ a single copy (the original
    /// behavior). `applyToolConfig` pushes it onto `OffsetTool.bothSides`.
    var offsetBothSides: Bool = false
    /// Offset tool: when `true`, ERASE each source that produced an offset copy
    /// (LibreCAD "delete original"). Default `false` ⇒ copy-only (the original
    /// behavior). `applyToolConfig` pushes it onto `OffsetTool.eraseSource`.
    var offsetEraseSource: Bool = false

    /// The `OffsetTool.OffsetMode` for the current `offsetModeIndex` (assembled here
    /// so `applyToolConfig` and the wiring test share one mapping).
    var offsetModeValue: OffsetTool.OffsetMode {
        offsetModeIndex == 1 ? .distance : .through
    }

    /// Rotate tool: when `true`, KEEP the originals and add rotated COPIES (AutoCAD
    /// ROTATE "Copy" — `RotateTool.keepOriginal`). Default `false` ⇒ rotate in place
    /// (the original behavior). `applyToolConfig` pushes it onto `RotateTool`.
    var rotateKeepOriginal: Bool = false

    /// Mirror tool: when `true`, KEEP the originals and add mirrored COPIES (AutoCAD
    /// MIRROR "keep source"/"Erase source objects? <No>" — `MirrorTool.keepOriginal`).
    /// Defaults to `true` ⇒ mirror-COPY (the reflection is a DUPLICATE; the original
    /// stays), matching AutoCAD's MIRROR default and user expectation — a plain Mirror
    /// produces two objects, not one reflected in place. Toggle OFF for mirror-in-place
    /// ("erase source"). `applyToolConfig` pushes it onto `MirrorTool` (whose own engine
    /// default stays `false`/in-place for byte-identical direct-engine behavior).
    var mirrorKeepOriginal: Bool = true

    /// Multiline (MLINE) tool: which element rides the clicked vertex path —
    /// top / zero / bottom (`MLineTool.justification`). `MLineJustification` is an
    /// `Int`-raw `CaseIterable` enum (so it CAN be a Picker tag directly). Defaults to
    /// `.top` (AutoCAD MLINE's default). `MLineTool.justification` is a settable `var`,
    /// so `applyToolConfig` sets it IN PLACE (the RotateTool/MirrorTool pattern).
    var mlineJustification: MLineJustification = .top

    /// Multiline (MLINE) tool: the overall offset SCALE (DXF code 40) applied to every
    /// element offset (`MLineTool.scale`). A negative scale mirrors the element fan
    /// across the path. Defaults to `1` (the STANDARD width). Settable `var`, so
    /// `applyToolConfig` sets it IN PLACE.
    var mlineScale: Double = 1

    /// Line-construction tool: the construction METHOD. `LineConstructionTool.Mode` is
    /// a `String`-raw `CaseIterable` enum (so it CAN be a Picker tag directly — unlike
    /// the index-bound modes). `LineConstructionTool.mode` is fixed at construction, so
    /// `applyToolConfig` RE-MINTS the tool with this (the DivideTool/ArcTool pattern).
    /// Defaults to `.perpendicularFoot` (the tool's own default).
    var lineConstructionMode: LineConstructionTool.Mode = .perpendicularFoot

    /// Polyline-Edit tool: which vertex/segment EDIT the next pick performs, stored as a
    /// case INDEX (`PolylineEditTool.Mode` is `Equatable`-not-`Hashable`, so it can't be a
    /// Picker tag — the Trim/Ellipse index-bound pattern). 0 = move a vertex (default),
    /// 1 = add a vertex on a segment, 2 = remove a vertex, 3 = toggle a segment straight↔arc.
    /// `PolylineEditTool.mode` is a settable `var`, so `applyToolConfig` sets it IN PLACE
    /// (no re-mint — the tool keeps its picked target across a mode change).
    var polylineEditModeIndex: Int = 0

    /// The `PolylineEditTool.Mode` for the current `polylineEditModeIndex` (assembled here
    /// so `applyToolConfig` and the wiring test share one mapping).
    var polylineEditModeValue: PolylineEditTool.Mode {
        switch polylineEditModeIndex {
        case 1:  return .add
        case 2:  return .remove
        case 3:  return .arc
        default: return .move
        }
    }

    /// Construction-line (XLINE) tool: the direction-CONSTRAINT mode, stored as a case
    /// INDEX (`XLineTool.Mode` carries an associated `.angle(Double)`, so it isn't a Picker
    /// tag — the index-bound pattern). 0 = free / two-point (default), 1 = horizontal,
    /// 2 = vertical, 3 = fixed angle (`xlineAngle`). `XLineTool.mode` is fixed at
    /// construction (it seeds the direction lock), so `applyToolConfig` RE-MINTS the tool
    /// with `xlineModeValue` (the DivideTool/ArcTool pattern).
    var xlineModeIndex: Int = 0
    /// Construction-line tool: the fixed direction angle (RADIANS, CCW from +X) used by the
    /// `.angle` mode. The options bar edits a friendlier degrees value over this.
    var xlineAngle: Double = 0

    /// The `XLineTool.Mode` for the current `xlineModeIndex` + `xlineAngle` (assembled here
    /// so `applyToolConfig` and the wiring test share one mapping).
    var xlineModeValue: XLineTool.Mode {
        switch xlineModeIndex {
        case 1:  return .horizontal
        case 2:  return .vertical
        case 3:  return .angle(xlineAngle)
        default: return .free
        }
    }

    // MARK: Layer defaults (Document Settings — app policy for new layers)
    //
    // These three are APP POLICY (not document content): the color / line width / line
    // type a NEW layer is born with, edited in Document Settings ▸ Layers and consumed
    // by `LayersSidebar.addLayer`. App-WIDE (not per-document), so they live in
    // `UserDefaults` like the other AppSettings — finding #32: before this they were
    // plain per-window vars that reset every launch/window despite the "app policy"
    // intent. Each is SEEDED at init from the persisted value (via the
    // `AppSettings.newLayer*` keys/encoders below) and PERSISTED on change through a
    // `didSet` that writes `UserDefaults.standard` — exactly the dynamic-input /
    // object-tracking pattern. `@ObservationIgnored` only on the seed default value is
    // not needed (these are observed so the Document-Settings pickers track them live).

    /// When true, the three new-layer-default `didSet` persistence writes are suppressed.
    /// Set ONLY for the duration of `seedNewLayerDefaultsFromAppSettings(defaults:)` so
    /// seeding from a store does NOT immediately echo the value back (and so a test can
    /// seed from an isolated suite without writing to `.standard`). `@ObservationIgnored`:
    /// pure internal bookkeeping, never observed.
    @ObservationIgnored
    private var suppressNewLayerDefaultPersist = false

    /// The default color a NEW layer is born with (Document Settings ▸ Layers).
    /// `LayersSidebar.addLayer` seeds a new `Layer` with this. App policy (not a DXF
    /// header var). Seeded from `AppSettings.Key.newLayerColorHex` (default LibreCAD
    /// green); persisted on change.
    var defaultLayerColor: RGBAColor = AppSettings.newLayerColor() {
        didSet { if !suppressNewLayerDefaultPersist { AppSettings.setNewLayerColor(defaultLayerColor) } }
    }
    /// The default line width a new layer is born with. Seeded from
    /// `AppSettings.Key.newLayerLineWidthMM` (default "by default"); persisted on change.
    var defaultLineWidth: PenLineWidth = AppSettings.newLayerLineWidth() {
        didSet { if !suppressNewLayerDefaultPersist { AppSettings.setNewLayerLineWidth(defaultLineWidth) } }
    }
    /// The default line type a new layer is born with. Seeded from
    /// `AppSettings.Key.newLayerLineType` (default solid); persisted on change.
    var defaultLineType: PenLineType = AppSettings.newLayerLineType() {
        didSet { if !suppressNewLayerDefaultPersist { AppSettings.setNewLayerLineType(defaultLineType) } }
    }

    /// Re-seeds the three NEW-LAYER defaults (color / line width / line type) from the
    /// persisted `AppSettings` keys. The plain property initializers already seed from
    /// `UserDefaults.standard` at `init`, so production never needs this; it exists as
    /// the injectable, hermetic seam (mirroring `seedSnapSettingsFromAppSettings(defaults:)`)
    /// so a test can seed a fresh model from an ISOLATED `UserDefaults` suite. The
    /// persistence `didSet` is suppressed for the duration so seeding does not echo back
    /// to the store (and never pollutes `.standard` in a test).
    func seedNewLayerDefaultsFromAppSettings(defaults: UserDefaults = .standard) {
        suppressNewLayerDefaultPersist = true
        defer { suppressNewLayerDefaultPersist = false }
        defaultLayerColor = AppSettings.newLayerColor(defaults: defaults)
        defaultLineWidth = AppSettings.newLayerLineWidth(defaults: defaults)
        defaultLineType = AppSettings.newLayerLineType(defaults: defaults)
    }

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

    // MARK: - App-settings snap seed (Wave 3B — NEW-window default drafting prefs)
    //
    // A NEW document/window should adopt the user's saved drafting PREFERENCES
    // (Preferences ▸ Snapping): the default snap mask, pick aperture, and polar
    // increment. The pure read-site is `AppSettingsModel` (every field already
    // normalized/clamped via `AppSettings.snapMode(fromMask:)` / `clampAperture` /
    // `polarIncrementRadians(fromDegrees:)`). This is OPT-IN — the plain `init` keeps the
    // built-in interactive defaults (so the 2800+ existing tests / a loaded document are
    // untouched); the Wave-3D window-creation path calls `seedSnapSettingsFromAppSettings()`.

    /// Applies a resolved `AppSettingsModel` snapshot's drafting prefs onto this window's
    /// LIVE snap state: `snapModes` (the saved default mask), `pickAperturePoints` (the
    /// clamped aperture), and `polarAngleIncrement` (radians). PURE w.r.t. the snapshot
    /// (no `UserDefaults` read here), so it is unit-testable headlessly with a synthetic
    /// snapshot. Does NOT touch `gridVisible`/`preferredGridSpacing` (those are document
    /// header vars, loaded via `loadSettingsFromDrawing`); this is the new-window default
    /// for the three SNAP prefs only. Bumps `modelVersion` so chrome reflecting these
    /// (snap chips) refreshes. A live policy — not document content, not undoable.
    func applySnapSeed(_ settings: AppSettingsModel) {
        snapModes = settings.defaultSnap
        pickAperturePoints = AppSettings.clampAperture(settings.snapAperturePx)
        polarAngleIncrement = settings.polarIncrementRadians
        modelVersion &+= 1
    }

    /// Seeds this window's snap prefs from the user's SAVED preferences. The Wave-3D
    /// new-window path calls this once after creating the model so a fresh window opens
    /// with the user's chosen default snap mask / aperture / polar increment. Reads the
    /// three `AppSettings.Key` snap keys off `UserDefaults` and runs each through the
    /// documented `AppSettings` normalizer (`snapMode(fromMask:)` / `clampAperture` /
    /// `polarIncrementRadians(fromDegrees:)`) so an absent/corrupt key falls back to the
    /// documented default — the seed is always valid. Delegates to the pure
    /// `applySnapSeed(_:)` (the unit-testable seam) with a snapshot built off the
    /// all-defaults `AppSettingsModel.standard` with only the three snap fields overridden.
    /// Reads `UserDefaults.standard` — keep it OUT of unit tests.
    func seedSnapSettingsFromAppSettings(defaults: UserDefaults = .standard) {
        let maskKey = AppSettings.Key.defaultSnapMask
        let mask = (defaults.object(forKey: maskKey) as? Int) ?? AppSettings.Default.snapMask
        let aperture = (defaults.object(forKey: AppSettings.Key.snapAperturePx) as? Double)
            ?? AppSettings.Default.snapAperturePx
        let polarDeg = (defaults.object(forKey: AppSettings.Key.polarIncrementDegrees) as? Double)
            ?? AppSettings.Default.polarIncrementDegrees

        var snapshot = AppSettingsModel.standard
        snapshot.defaultSnap = AppSettings.snapMode(fromMask: mask)
        snapshot.snapAperturePx = AppSettings.clampAperture(aperture)
        snapshot.polarIncrementRadians = AppSettings.polarIncrementRadians(fromDegrees: polarDeg)
        applySnapSeed(snapshot)
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
        // ENFORCE restored constraints on the loaded geometry: a drawing opened from a
        // payload/DXF carries its constraint table but its geometry was last written by
        // whatever produced the file, so re-solve every constrained component now (and flag
        // any the geometry can't satisfy via `unsatisfiedConstraintIDs`). Constrained
        // entities that moved get their AABBs refreshed by `applySolvedGeometry`'s quadtree
        // update inside the resolve. The undo stack is cleared AGAIN afterward so this
        // load-time enforcement is part of the clean baseline (not a user-undoable step).
        resolveAllConstraints()
        undoManager.removeAllActions()
        let box = drawing.boundingBox()
        renderOrigin = RendererGeometry.renderOrigin(for: box)
        selection.clear()
        // Drop ALL transient interaction state the prior document left behind — the same
        // reset a context switch (`activateTool` / `setActiveSpace`) does (finding-M3). A
        // New-from-Template onto an OPEN window reuses this `CanvasModel`, so a half-drawn
        // tool run, a stale relative-zero datum, acquired OTRACK points, an in-flight dyn
        // entry, and the snap/hover overlays must NOT carry into the fresh drawing.
        snap = nil
        hoverID = nil
        // Re-mint the active tool against the fresh (empty) drawing so no in-progress
        // preview / picked points survive (drops to `.select` when none is active).
        tool = activeToolKind.makeTool()
        applyToolConfig()
        toolStatus = tool?.status ?? ""
        // The relative-zero FAMILY is per-document drafting state — a new document starts
        // with no datum, even if the prior one had a LOCKED datum (it referenced the prior
        // drawing's coordinates).
        relativeZero = nil
        relativeZeroLocked = false
        clearTrackingPoints()
        resetDynInput()
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
        let anno = drawing.graphicVariables.annotationScale
        if anno > 0 { annotationScale = anno }
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

    // MARK: - Table render geometry (Wire-wave-1 — tables drawn on the canvas)

    /// The default pen tables draw with on the canvas. Tables carry no layer / pen of
    /// their own (a `TableObject` has only a `TableStyle`), so they render in the same
    /// "automatic" default color the engine resolves a `.byLayer`/default entity to
    /// (LibreCAD green) — so a placed table reads like the rest of the drawing. The
    /// light-mode auto-invert the renderer applies to near-white pens leaves this
    /// non-white color untouched (it only flips near-white), matching entity geometry.
    static let tableRenderPen = ResolvedPen(color: .librecadGreen, lineType: .solid, lineWidth: .default)

    /// The renderable geometry for every TABLE in the CURRENT active space — the grid
    /// lines (`ResolvedPolyline`s) plus each non-empty cell's text SHAPED through the
    /// SHARED `TextShaper` path (via `TableGeometry.resolve`, so there is no second text
    /// layout — ADR-004). One `ResolvedGeometry` per table.
    ///
    /// MVP scope: tables live in MODEL space, so this returns nothing while a paper-
    /// space layout (or a block-edit session) is active — keeping the table render set
    /// consistent with how entities are space-filtered (a table never leaks onto a sheet
    /// or into a block). The renderer iterates this AFTER the entity pack and feeds each
    /// table's polylines/fills through the SAME `RendererGeometry` packing path, so a
    /// placed table appears on the canvas. The set is a pure function of
    /// `drawing.tables`, so it rebuilds whenever the table list changes (the renderer's
    /// `modelVersion`-keyed cache repaints on every `addTable`/`updateTable`/`removeTable`,
    /// which bump `modelVersion`).
    ///
    /// PURE (no Metal / no view): unit-testable headless over the `_SharedCanvasModel`
    /// symlink — a placed table yields grid-line polylines here without a GPU.
    func tableRenderGeometry() -> [ResolvedGeometry] {
        // MVP: tables are MODEL-space only; nothing to draw outside model space (a paper
        // layout or an open block-edit session scopes to a different content set).
        guard activeSpace == .model, editingBlock == nil else { return [] }
        guard !drawing.tables.isEmpty else { return [] }
        let ctx = drawing.makeResolveContext()
        return drawing.tables.map { table in
            TableGeometry.resolve(table, pen: Self.tableRenderPen, ctx: ctx)
        }
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
        // Abandon any in-progress tool run + unlocked relative-zero — its picked points
        // live in the PRIOR space's coordinates, so a leftover run would draw a stray
        // cross-space segment (finding-M4).
        abandonInProgressTool()
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
        // Abandon any in-progress tool run + unlocked relative-zero — entering the block
        // editor re-scopes the canvas to the block's members, so a leftover run's picked
        // points (in the document's coordinates) would draw a stray segment (finding-M4).
        abandonInProgressTool()
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
        // Abandon any in-progress tool run + unlocked relative-zero — exiting the block
        // editor re-scopes back to the prior space, so a leftover run's picked points (in
        // the block's member coordinates) would draw a stray segment (finding-M4).
        abandonInProgressTool()
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

    // MARK: - Layout tab ops (backlog #4c — Rename / Delete / Duplicate / Page Setup)
    //
    // Thin `CanvasModel` wrappers over the undoable engine layout ops
    // (`CADDrawing.duplicateLayout` / `setLayoutPage` / `renameLayout` / `removeLayout`).
    // Each performs ACTIVE-TAB FIXUP so the model's `activeLayout` pointer never dangles
    // after the table changes — it re-resolves through `setActiveSpace`, which falls
    // back to model space when a name no longer exists — and bumps `modelVersion` so the
    // tab strip + chrome refresh. UNWIRED — the tab `.contextMenu` calls these in a
    // later wire-wave. (These mutate the document table, so they are undoable via the
    // engine ops; the active-tab re-home is a pure view change layered on top.)

    /// Renames the layout `name` → `newName` (backlog #4c). On success, if the renamed
    /// layout was the ACTIVE one, re-homes the active tab onto the new name (the old
    /// name no longer resolves) so the canvas keeps showing the same sheet. No-op
    /// (returns `false`) if the engine rename fails (absent source / taken target).
    @discardableResult
    func renameLayout(_ name: String, to newName: String) -> Bool {
        let wasActive = activeSpace == .paper
            && activeLayout?.caseInsensitiveCompare(name) == .orderedSame
        guard drawing.renameLayout(from: name, to: newName) else { return false }
        if wasActive {
            // The old name is gone; point the active tab at the renamed sheet (its
            // canonical stored casing). Falls back to model space if (defensively) the
            // renamed layout can't be resolved.
            setActiveSpace(.paper, layoutName: newName)
        }
        modelVersion &+= 1
        return true
    }

    /// Deletes the layout `name` (backlog #4c). On success, re-resolves the active tab:
    /// if the deleted layout was active, `setActiveSpace` falls back to model space (no
    /// sheet to show); otherwise the active tab is unchanged. No-op (returns `false`) if
    /// the layout is absent.
    @discardableResult
    func deleteLayout(_ name: String) -> Bool {
        guard drawing.removeLayout(name: name) else { return false }
        // Re-resolve the current active space/layout: if `activeLayout` named the just-
        // removed sheet it no longer exists, so `setActiveSpace` falls back to model.
        setActiveSpace(activeSpace, layoutName: activeLayout)
        modelVersion &+= 1
        return true
    }

    /// Duplicates the layout `name` into a fresh independent sheet (backlog #4c) and —
    /// matching `newLayout` / AutoCAD's Duplicate behavior — ACTIVATES the new sheet so
    /// the user lands on the copy. Returns the new layout's name on success, or `nil`
    /// if the source layout is absent. The engine derives the copy name as `"<name>
    /// (N)"`; this replicates that derivation to know which sheet to activate.
    @discardableResult
    func duplicateLayout(_ name: String) -> String? {
        guard let source = drawing.layout(named: name) else { return nil }
        let newName = duplicateLayoutName(for: source.name)
        guard drawing.duplicateLayout(name: name) else { return nil }
        modelVersion &+= 1
        // Land on the freshly created sheet (active-tab fixup); `setActiveSpace` falls
        // back to model space if the name can't be resolved (defensive).
        setActiveSpace(.paper, layoutName: newName)
        return newName
    }

    /// The name `CADDrawing.duplicateLayout` will mint for a copy of `baseName`:
    /// `"<baseName> (2)"`, bumping the suffix until it does not clash
    /// (case-insensitively). Kept in lockstep with the engine derivation so this
    /// wrapper can activate the copy it just made.
    private func duplicateLayoutName(for baseName: String) -> String {
        var index = 2
        var candidate = "\(baseName) (\(index))"
        while drawing.hasLayout(candidate) {
            index += 1
            candidate = "\(baseName) (\(index))"
        }
        return candidate
    }

    /// Sets the per-layout page descriptor of the layout `name` (backlog #4c's "Page
    /// Setup"). On success, if the edited layout is the ACTIVE sheet, re-applies
    /// `setActiveSpace` so the camera re-frames to the new paper geometry. No-op
    /// (returns `false`) if the layout is absent or the page is unchanged.
    @discardableResult
    func setLayoutPage(_ name: String, _ page: PageDescriptor) -> Bool {
        guard drawing.setLayoutPage(name: name, page) else { return false }
        modelVersion &+= 1
        // If the edited layout is on screen, the sheet rect changed — re-frame it.
        if activeSpace == .paper,
           activeLayout?.caseInsensitiveCompare(name) == .orderedSame {
            reframeActiveLayout()
        }
        return true
    }

    /// Re-frames the camera onto the ACTIVE layout's (possibly resized) paper sheet
    /// without going through `setActiveSpace`'s already-active no-op guard. Used after a
    /// `setLayoutPage` change to the on-screen sheet so the new page geometry frames.
    private func reframeActiveLayout() {
        guard activeSpace == .paper, let page = activeLayoutRecord?.page else { return }
        viewport = PaperSpaceLayout.cameraFit(for: page, in: viewport.size)
        renderOrigin = RendererGeometry.renderOrigin(for: activeSpaceBoundingBox)
        modelDirty = true
        modelVersion &+= 1
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

    /// The LIVE pick/snap aperture in GUI points for THIS window. Defaults to the
    /// historical `catchPoints` (8) so existing behavior + tests are unchanged; a NEW
    /// window seeds it from `AppSettings.snapAperturePx` (clamped) via
    /// `seedSnapSettingsFromAppSettings()` / `applySnapSeed(_:)` (Wave-3D wires the call
    /// at window creation). `worldTolerance` reads THIS, so the seed actually changes the
    /// catch range. A live interaction policy (not persisted to the document).
    var pickAperturePoints: Double = CanvasModel.catchPoints

    /// Snap tolerance in world units for the current zoom (the live aperture × the
    /// current world-per-pixel). Reads `pickAperturePoints` so a seeded/edited aperture
    /// takes effect immediately.
    var worldTolerance: Double { pickAperturePoints * viewport.worldPerPixel }

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
            using: quadtree,
            // `ctx` powers curve nearest-point / resolve; `referencePoint` lights up
            // the constructive modes (.perpendicular / .tangent / .parallel), which
            // gate behind a valid reference point in `Snapping.snap`. The tool's
            // "from" datum is `relativeZero` (nil at a tool's first point → those
            // modes correctly contribute no candidates, matching LibreCAD).
            // `distanceAlong` is intentionally left at its nil default: there is no
            // CanvasModel snap-distance field yet (a tiny follow-up: add a
            // `var snapDistance: Double?` tool option, then pass it here).
            ctx: drawing.makeResolveContext(),
            referencePoint: relativeZero,
            // UCS-W4: snap the grid candidate in the active UCS lattice so grid snap
            // lands on the SAME nodes as the UCS-aligned drawn grid. A world UCS
            // (origin .zero, angle 0) makes these defaults, so grid snap is
            // byte-identical until a UCS is set.
            gridOrigin: currentUCS.origin,
            gridAngle: currentUCS.angle,
            // Wire-wave 3 (iso): when isometric drafting is ON, grid snap lands on the
            // ISO lattice of the active plane instead of the rectangular grid. `nil`
            // (the rectangular default) is byte-identical to the prior behavior, so
            // every non-iso drawing is unchanged.
            isoPlane: isoPlaneIfActive
        )
        let changed = result != snap
        snap = result
        refreshPolarTracking()
        // OTRACK lock refresh — AFTER snap + polar so a real osnap suppresses both the
        // polar ray and the OTRACK lock (geometry snap wins). Uses the same world tolerance.
        refreshObjectTracking()
        return changed
    }

    /// Recomputes `polarTrackingResult` for the DOTTED-RAY DISPLAY. Called from
    /// `updateSnap` AFTER `snap` is set so a real object snap can suppress the ray (the
    /// ray must not fight the snap marker). Mirrors the `polarConstrained` gates exactly
    /// — polar on, a reference (`relativeZero`) to radiate from, ⇧ not held, and no live
    /// osnap — so the SHOWN ray and the always-on angle LOCK always agree about when
    /// polar is in effect. This is display-only: it never alters the lock (`polarConstrained`
    /// is untouched); `withinAperture` further draw-gates the actual rendering in
    /// `trackingDisplay()`.
    private func refreshPolarTracking() {
        guard polarEnabled,                 // polar mode on
              !polarTrackingShiftHeld,       // ⇧ releases polar (mirror polarConstrained)
              !osnapActive,                  // a real osnap wins — yield the ray to it
              let reference = relativeZero,  // need a datum to radiate from
              let cursor = cursorWorld       // need a live cursor
        else {
            polarTrackingResult = nil
            return
        }
        polarTrackingResult = PolarTracking.resolve(
            reference: reference,
            cursor: cursor,
            incrementRadians: polarAngleIncrement,
            apertureRadians: Self.polarApertureRadians,
            rayLengthWorld: Self.polarTrackingRayLengthWorld)
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
        polarTrackingResult = nil   // no cursor → no tracking ray
        clearTrackingPoints()       // OTRACK acquisitions are transient — drop them when the cursor leaves
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
        // OTRACK acquisitions are transient drafting state, like the relative-zero — a
        // tool change starts a fresh tracking context (unconditional: acquisitions are
        // never "locked").
        clearTrackingPoints()
        // A tool change abandons any in-flight typed dimension entry (the new tool has
        // its own — possibly no — editable fields).
        resetDynInput()
        lastCommandError = nil
    }

    /// Abandons any IN-PROGRESS tool run at a SPACE/BLOCK-EDIT transition (finding-M4),
    /// without changing which tool is active. A space switch or a block-edit enter/exit
    /// re-scopes the canvas to a DIFFERENT set of entities; a tool mid-run (a Line with one
    /// point placed, an Offset with a picked source, …) holds picked points in the OLD
    /// space's coordinates, so the next click would draw a stray segment that crosses
    /// spaces. Re-minting the same-kind tool drops that in-progress state (the run-finish /
    /// `activateTool` pattern) so the same tool stays selected but starts a CLEAN run in the
    /// new scope; in `.select` mode the re-mint yields `nil` (a harmless no-op). The
    /// transient drafting aids (the UNLOCKED relative-zero datum, OTRACK points, any
    /// in-flight dyn entry) are dropped too — they all referenced the prior scope. A LOCKED
    /// relative-zero is a deliberate persistent datum, so it survives (matching
    /// `activateTool` / run-finish).
    private func abandonInProgressTool() {
        tool = activeToolKind.makeTool()
        applyToolConfig()
        toolStatus = tool?.status ?? viewportTool?.status ?? ""
        if !relativeZeroLocked { relativeZero = nil }
        clearTrackingPoints()
        resetDynInput()
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

    /// Promotes `kind` to the front of the command bar's MRU (most-recent first,
    /// deduped, capped) via the pure `ToolSuggester.updatedMRU`. The `.image` flow —
    /// which activates via the View-layer file-picker, NOT `activateTool(.image)` —
    /// calls this directly to still record its use in the MRU. The view persists the
    /// updated list to `@AppStorage`.
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
            // DivideTool's `mode` is taken only via `init(mode:)`, so RE-MINT it from the
            // LIVE options-bar state (`divideMode`, read fresh on every (re-)mint —
            // activate / post-commit / `reapplyActiveToolConfig`), NOT a value frozen when
            // the tool was first made. The assembled `DivideMode` is DIVIDE-by-count or
            // MEASURE-by-length (the split UI state); `init(mode:)` carries the
            // clamp/validation. The default (`divideModeStyle == 0`) reproduces the
            // historical count-based DIVIDE.
            tool = DivideTool(mode: divideMode)

        // MARK: Wave-3B parameterized tools (Spline / Scale / Hatch)

        case is SplineTool:
            // SplineTool's `mode` is a `let` fixed at construction (it seeds how the
            // picks are interpreted on commit — fit points vs NURBS control points), so
            // RE-MINT with the chosen mode (the DivideTool/ArcTool re-mint pattern). The
            // default `.fit` keeps the original fit-point interpolation behavior.
            tool = SplineTool(mode: splineMode)
        case var t as ScaleTool:
            // ScaleTool carries `mode` + `nonUniformFactors` as settable `var`s (no-arg
            // init), so apply them IN PLACE on the live tool (the FilletTool/ArrayTool
            // pattern). `.factor` (the default) leaves the original three-pick distance
            // ratio behavior untouched; `.nonUniform` reads the typed X/Y factors.
            t.mode = scaleMode
            t.nonUniformFactors = (sx: scaleX, sy: scaleY)
            tool = t
        case var t as HatchTool:
            // HatchTool's `fill` is a settable `var`, so apply the assembled fill IN
            // PLACE (solid for no/blank/"SOLID" pattern, else a named `.pat` pattern
            // carrying the scale + angle). The default (no pattern) keeps a solid fill —
            // the original behavior — so an un-configured Hatch is byte-for-byte unchanged.
            t.fill = hatchFillValue
            tool = t

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
        case var t as MultiLeaderTool:
            // Empty text ⇒ a bare multileader (the tool maps "" to no annotation).
            t.annotationText = multiLeaderText.isEmpty ? nil : multiLeaderText
            t.textHeight = Swift.max(InspectorEdits.minTextHeight, multiLeaderTextHeight)
            t.landingDistance = Swift.max(0, multiLeaderLandingDistance)
            t.doglegEnabled = multiLeaderDoglegEnabled
            tool = t
        case is BaselineDimTool:
            // BaselineDimTool clamps/stores `baselineSpacing` at construction, so
            // re-mint with the configured spacing (mirrors the DivideTool/ArcTool pattern).
            tool = BaselineDimTool(baselineSpacing: baselineSpacing)

        // MARK: Wire-wave-4 configurable tools (Offset / Rotate / Mirror / Line construction)

        case var t as OffsetTool:
            // OffsetTool carries `mode` / `distance` / `bothSides` / `eraseSource` as
            // settable `var`s (no-arg init), so apply them IN PLACE on the live tool
            // (the FilletTool/ScaleTool pattern). The defaults (`.through`, single copy,
            // copy-only) reproduce the original behavior byte-for-byte.
            t.mode = offsetModeValue
            t.distance = offsetDistance
            t.bothSides = offsetBothSides
            t.eraseSource = offsetEraseSource
            tool = t
        case var t as RotateTool:
            // RotateTool carries `keepOriginal` as a settable `var`; apply IN PLACE.
            // `false` (the default) is rotate-in-place (the original behavior).
            t.keepOriginal = rotateKeepOriginal
            tool = t
        case var t as MirrorTool:
            // MirrorTool carries `keepOriginal` as a settable `var`; apply IN PLACE.
            // `false` (the default) is mirror-in-place (the original behavior).
            t.keepOriginal = mirrorKeepOriginal
            tool = t
        case var t as MLineTool:
            // MLineTool carries `justification` + `scale` as settable `var`s (no-arg
            // init), so apply them IN PLACE on the live tool (the RotateTool/MirrorTool
            // pattern). The defaults (`.top`, scale `1`) reproduce the STANDARD-style
            // multiline, so an un-configured MLINE draws byte-for-byte as before.
            t.justification = mlineJustification
            t.scale = mlineScale
            tool = t
        case is LineConstructionTool:
            // LineConstructionTool's `mode` is read live (a settable `var` re-minted from
            // the options-bar `lineConstructionMode`), so RE-MINT with the chosen mode (the
            // DivideTool/ArcTool re-mint pattern). The construction-MODE picker is now
            // surfaced in the options bar.
            tool = LineConstructionTool(mode: lineConstructionMode)

        // MARK: Lane-M surfaced tool modes (PolylineEdit / XLine)

        case var t as PolylineEditTool:
            // PolylineEditTool's `mode` is a settable `var` (move / add / remove / arc), so
            // apply it IN PLACE on the live tool (the FilletTool/ScaleTool pattern) — the
            // tool keeps its picked polyline target across a mid-run mode switch. The
            // default `.move` reproduces the original vertex-drag behavior.
            t.mode = polylineEditModeValue
            tool = t
        case is XLineTool:
            // XLineTool's `mode` is fixed at construction (it seeds the direction lock), so
            // RE-MINT with the assembled mode (free / horizontal / vertical / fixed-angle —
            // the DivideTool/ArcTool re-mint pattern). The default `.free` keeps the
            // original two-point construction-line behavior.
            tool = XLineTool(mode: xlineModeValue)

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
        // options, LineConstruction's method, XLine's direction-lock are taken only via an
        // `init(…)`), which resets their state/status to the initial prompt. For those,
        // take the fresh tool's status; for the IN-PLACE tools (which keep their state —
        // e.g. PolylineEdit keeps its picked target across a mode switch) restore the prior
        // prompt text. (InsertTool's status is a pure function of its block name —
        // preserved across the re-mint — so this is a no-op for it today, but listing it
        // keeps the set correct if it gains mid-run state, per the review NIT.)
        if tool is DivideTool || tool is CircleTool || tool is ArcTool || tool is LineTool
            || tool is EllipseTool || tool is BaselineDimTool || tool is ImageTool
            || tool is InsertTool || tool is SplineTool || tool is LineConstructionTool
            || tool is XLineTool {
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
            // A point was placed (a typed dyn commit, or a plain click while mid-type):
            // the in-flight typed entry is consumed/abandoned, so clear dyn state. Idempotent
            // when `dynCommit` already cleared it (it resets via `defer`).
            resetDynInput()
            // A geometry commit ends this acquisition context — drop the acquired OTRACK
            // points so the next placement starts fresh (transient drafting state).
            clearTrackingPoints()
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
            // TableTool, like CreateBlockTool, does NOT emit `.commit` edits (a table is
            // not an `EntityKind` — it lives in `drawing.tables`). It records a
            // `pendingTable` REQUEST the app adds via the undoable `CADDrawing.addTable`.
            // Read it from the just-finished tool BEFORE the re-mint discards it.
            applyPendingTableInsertionIfAny()
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
            // The run ended (commit/cancel → `.finished`): drop the acquired OTRACK points
            // so the next run starts with a clean tracking context (transient, never locked).
            clearTrackingPoints()
            // The operation ended (commit/cancel → fresh tool): abandon any typed entry.
            resetDynInput()
            return true
        }
    }

    /// The mouse-MOVE entry point the canvas cursor funnel calls (the constrained,
    /// snapped world point from `mouseMoved`). When NOT typing, it is just
    /// `handleToolInput(.move(point))`. When DYNAMIC INPUT is active, it substitutes the
    /// SYNTHETIC cursor (`effectiveCursor()`) so the locked / typed fields stay FIXED at
    /// their typed values while the unlocked fields (and the rest of the preview) follow
    /// the real mouse — e.g. with a typed length, the line keeps that length while the
    /// angle tracks the cursor. The substitution lives here (not in the view) so it is
    /// headless-testable; Wave V's `mouseMoved` funnel calls THIS instead of
    /// `handleToolInput(.move(...))`.
    @discardableResult
    func handleToolMove(_ point: Vector) -> Bool {
        guard dynEditing else { return handleToolInput(.move(point)) }
        // Remember the live mouse so `effectiveCursor()` uses the new position for any
        // field the user did NOT type (the cursor-tracking fields). `cursorWorld` is set
        // by `updateSnap` upstream of this call, so it already reflects this move; we
        // resolve the synthetic point from it.
        return handleToolInput(.move(effectiveCursor()))
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

    /// If the just-finished tool is a `TableTool` carrying a `pendingTable` request,
    /// adds it to the drawing via the undoable model op `CADDrawing.addTable` (ONE
    /// undoable group — a single ⌘Z removes the placed table). A table is NOT an
    /// `EntityKind` — it lives in `drawing.tables` (off the enum, like a paper-space
    /// viewport) — so it cannot flow through `ToolEdit`/`applyCommit`; this routes
    /// through the model op instead, exactly as `applyPendingBlockCreationIfAny` does
    /// for block creation. Marks the GPU buffer dirty + bumps `modelVersion` so the
    /// renderer repacks (the table render path keys off `modelVersion`). Tables carry no
    /// id in the spatial index this MVP (they are not snap/hit-test targets yet), so no
    /// `rebuildIndex` is needed. No-op for any other tool / a cancelled run.
    private func applyPendingTableInsertionIfAny() {
        guard let tableTool = tool as? TableTool,
              let table = tableTool.pendingTable else { return }

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        TableTool.apply(table, to: drawing)
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

    /// The cursor coordinate formatted for the status bar, honoring the live
    /// `coordinateDisplayMode` (backlog #5) — LibreCAD's classic cycle:
    ///
    ///  • `.absolute` — the cursor's world point `"X 12.5   Y 8 mm"` (the document's
    ///    linear format/precision + unit sign). UNCHANGED from the prior behavior.
    ///  • `.relative` — the signed `"@Δx, Δy"` offset of the cursor FROM the
    ///    relative-zero (the last placed point), the same math as `relativeReadout`.
    ///  • `.polar`    — the polar `"dist<angle"` of that same relative delta, via the
    ///    engine `CoordinateFormatter.polarPair` (linear + angular format/precision).
    ///
    /// `.relative`/`.polar` need a `relativeZero` to measure from; with none yet (the
    /// first point of a run, or select mode) they FALL BACK to the absolute readout so
    /// the segment is never blank. `nil` only when the cursor is outside the canvas.
    /// Pure formatting via the engine's `CoordinateFormatter` so the status bar stays a
    /// thin view.
    var cursorReadout: String? {
        guard let w = cursorWorld else { return nil }
        let gv = drawing.graphicVariables
        switch coordinateDisplayMode {
        case .absolute:
            return absoluteCursorReadout(w, gv)
        case .relative:
            guard let zero = relativeZero else { return absoluteCursorReadout(w, gv) }
            // The relative delta is rotated INTO the UCS frame (translation cancels in a
            // difference, so a direction rotation is exact). With `UCS.world` this is the
            // identity, so the raw `w - zero` deltas are formatted unchanged.
            let d = currentUCS.directionToUCS(w - zero)
            let dx = CoordinateFormatter.length(
                d.x, format: gv.linearFormat, precision: gv.linearPrecision)
            let dy = CoordinateFormatter.length(
                d.y, format: gv.linearFormat, precision: gv.linearPrecision)
            return "@\(dx), \(dy)"
        case .polar:
            guard let zero = relativeZero else { return absoluteCursorReadout(w, gv) }
            // Distance is rotation-invariant; the angle is shifted by the UCS angle via
            // `angleBase` so it reads relative to the UCS +X axis. `UCS.world` ⇒
            // `angleBase: 0` ⇒ byte-identical to before.
            return CoordinateFormatter.polarPair(
                dx: w.x - zero.x, dy: w.y - zero.y,
                format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit,
                angleFormat: gv.angleFormat, anglePrecision: gv.anglePrecision,
                angleBase: currentUCS.angle)
        }
    }

    /// The absolute coordinate readout — the original `cursorReadout` body, factored
    /// out so the `.absolute` mode and the relative/polar no-reference fallback share
    /// exactly one formatting path. The world point is first converted INTO the active
    /// UCS (`currentUCS.toUCS`), so the displayed X/Y is the cursor's position in the
    /// current frame. With `UCS.world` `toUCS` is the identity, so the output is
    /// byte-identical to formatting the raw world point.
    private func absoluteCursorReadout(_ w: Vector, _ gv: GraphicVariables) -> String {
        let p = currentUCS.toUCS(w)
        return CoordinateFormatter.coordinatePair(
            x: p.x, y: p.y,
            format: gv.linearFormat, precision: gv.linearPrecision, unit: gv.unit)
    }

    /// Cycles the status-bar coordinate display mode (backlog #5):
    /// `absolute → relative → polar → absolute`. Bumps `modelVersion` so the status
    /// bar's coord segment re-renders. A pure view-state change (not undoable).
    func cycleCoordinateDisplayMode() {
        coordinateDisplayMode = coordinateDisplayMode.next
        modelVersion &+= 1
    }

    /// The signed `@Δx, Δy` offset of the cursor FROM the relative-zero (the last
    /// placed point), formatted with the document's linear format/precision, or `nil`
    /// when there is no relative-zero yet OR the cursor is outside. Lets the status
    /// bar show the relative coordinate while drawing (LibreCAD's relative readout).
    var relativeReadout: String? {
        guard let zero = relativeZero, let w = cursorWorld else { return nil }
        let gv = drawing.graphicVariables
        // Rotate the delta into the UCS frame (identity for `UCS.world`).
        let d = currentUCS.directionToUCS(w - zero)
        let dx = CoordinateFormatter.length(d.x, format: gv.linearFormat, precision: gv.linearPrecision)
        let dy = CoordinateFormatter.length(d.y, format: gv.linearFormat, precision: gv.linearPrecision)
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
        // Bearing relative to the UCS +X axis: subtract the UCS angle (`displayAngle`)
        // and re-normalize into [0, 2π). `(w - zero).angle` is already normalized, so
        // with `UCS.world` (`displayAngle` is a no-op) `correctAngle` is idempotent and
        // the degrees value is byte-identical to before.
        let bearing = Vector.correctAngle(currentUCS.displayAngle((w - zero).angle))
        let deg = bearing * 180 / .pi
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
        // The datum's position is shown in the active UCS (identity for `UCS.world`).
        let p = currentUCS.toUCS(zero)
        let pos = CoordinateFormatter.coordinatePair(
            x: p.x, y: p.y,
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
        // An in-progress UCS pick owns the prompt (it overrides both tool + select
        // mode): the user is mid-gesture and needs the "Specify UCS …" step text.
        if let ucsPrompt = ucsPickReadout { return ucsPrompt }
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

    // MARK: - Smart command line dispatch (merged command + coordinate field, Wave 3)

    /// The keyword chips the active tool offers at its current step — the tool's own
    /// `keywordOptions` (`[Close]`/`[Undo]` for Polyline/Spline, construction-mode
    /// keywords for Circle/Arc/Ellipse in their initial state), or `[]` when no tool is
    /// active. The merged command line's chip row (Wave 4) renders from this, and a chip
    /// tap routes back through `invokeToolKeyword(_:)` — the SAME entry a typed keyword
    /// uses. A computed read-through of the live tool value (no stored mirror).
    var activeToolKeywordOptions: [ToolKeyword] {
        tool?.keywordOptions ?? []
    }

    /// The single dispatch entry for a tool command KEYWORD — used by BOTH a keyword the
    /// user typed on the merged command line AND a chip tap (Wave 4). Matches `keyword`
    /// case-insensitively against the active tool's CURRENTLY offered `keywordOptions`
    /// (ignoring anything not offered right now), then routes through the EXISTING
    /// `ToolInput` events — there is deliberately NO `ToolInput.keyword` case (that would
    /// force an exhaustive-switch edit across every tool's `handle`):
    ///
    ///   - `Undo`  → `.backspace` (steps the last picked vertex/point back).
    ///   - `Close` → `.click(tool.closeAnchor)` — re-feeds the first vertex/point so the
    ///               tool's close-on-coincidence path commits the closed entity. No-op
    ///               when `closeAnchor` is `nil` (closing not currently possible).
    ///   - construction-MODE keywords (Circle/Arc/Ellipse, offered only in the initial
    ///               state) → set the matching model config field, then
    ///               `reapplyActiveToolConfig()` re-mints the tool in the chosen mode.
    ///
    /// A no-op when no tool is active or the keyword is not one the tool offers right now.
    func invokeToolKeyword(_ keyword: String) {
        guard let tool = self.tool else { return }
        // Only act on a keyword the tool is OFFERING at its current step (case-insensitive).
        guard tool.keywordOptions.contains(where: {
            $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame
        }) else { return }

        let key = keyword.lowercased()
        switch key {
        case "undo":
            handleToolInput(.backspace)
            return
        case "close":
            if let p = tool.closeAnchor { handleToolInput(.click(p)) }
            return
        default:
            break
        }

        // Construction-MODE keywords — disambiguated by the active tool's kind (e.g. `3p`
        // is Circle's three-point vs Arc's three-point). Set the config field then re-mint.
        switch (activeToolKind, key) {
        // Circle — construction mode.
        case (.circle, "cen"):      circleConstructionMode = .centerRadius
        case (.circle, "2p"):       circleConstructionMode = .twoPoint
        case (.circle, "3p"):       circleConstructionMode = .threePoint
        // Circle — size mode (labels the numeric entry).
        case (.circle, "diameter"): circleSizeMode = .diameter
        case (.circle, "radius"):   circleSizeMode = .radius
        // Arc — construction mode.
        case (.arc, "cse"):         arcMode = .centerStartEnd
        case (.arc, "3p"):          arcMode = .threePoint
        case (.arc, "tan"):         arcMode = .tangential
        // Ellipse — construction mode (stored as a case index).
        case (.ellipse, "axis"):     ellipseModeIndex = 0
        case (.ellipse, "foci"):     ellipseModeIndex = 1
        case (.ellipse, "4p"):       ellipseModeIndex = 2
        case (.ellipse, "inscribe"): ellipseModeIndex = 3
        case (.ellipse, "arc"):      ellipseModeIndex = 4
        default:
            // Offered keyword we don't have a config route for — nothing to do.
            return
        }
        reapplyActiveToolConfig()
    }

    /// The outcome of interpreting one line of the merged smart command line — what the
    /// VIEW (Wave 4) does after the user presses ⏎. The View activates tools itself (so it
    /// can special-case `.image`'s `NSOpenPanel` modal, which must NEVER be reached from
    /// the model — a modal on a headless test thread hangs forever), so a recognized
    /// command name returns `.activateTool(kind)` rather than activating here.
    enum CommandLineResult: Equatable {
        /// The line was blank — nothing to do.
        case empty
        /// The model fully handled the line (a tool keyword fired, or a coordinate was
        /// parsed + fed to the active tool). No further View action.
        case handled
        /// The line is a recognized tool command — the View should activate `kind`
        /// (routing `.image` through its file-picker). The MRU was already recorded here.
        case activateTool(ToolKind)
        /// The line could not be interpreted; `lastCommandError` carries the message the
        /// field echoes.
        case error(String)
    }

    /// The unified ⏎ router the merged command line calls. Classifies the trimmed text and
    /// routes it WITHOUT a new `ToolInput` case:
    ///
    ///   1. empty → `.empty`.
    ///   2. a tool is active AND the text matches one of `activeToolKeywordOptions`
    ///      (case-insensitive) → `invokeToolKeyword` → `.handled`.
    ///   3. else the text looks like a coordinate (`CommandParser.looksLikeCoordinate`):
    ///      with a tool active, parse it against `relativeZero`/`cursorWorld` and feed the
    ///      point as `.value` (`.handled`, or `.error` on a parse failure); with NO tool
    ///      active → `.error("Start a tool first")`.
    ///   4. else `ToolSuggester.resolve` recognizes a command name → record the MRU and
    ///      return `.activateTool(kind)` (the View activates — see the `.image` note).
    ///   5. else → `.error("Unknown command: …")`.
    ///
    /// Keyword routing (step 2) is checked BEFORE the coordinate/command routes so a tool
    /// keyword that happens to look like a word (`Close`, `Undo`, `axis`, …) is never
    /// mis-read as a command name; coordinate-shaped keywords don't exist today.
    @discardableResult
    func interpretCommandLine(_ text: String) -> CommandLineResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // 1) Empty — never recorded in the transcript (a stray ⏎ shouldn't echo).
        guard !trimmed.isEmpty else { return .empty }

        // Echo the submitted line FIRST (the single transcript choke point — appends are
        // NOT scattered through the per-route bodies below). The outcome-specific line is
        // appended right before each return so the scrollback reads input-then-result.
        appendTranscript(.input, "> \(trimmed)")

        // 2) An offered tool keyword (only when a tool is active).
        if tool != nil,
           activeToolKeywordOptions.contains(where: {
               $0.keyword.caseInsensitiveCompare(trimmed) == .orderedSame
           }) {
            invokeToolKeyword(trimmed)
            lastCommandError = nil
            return .handled
        }

        // 3) A coordinate (x,y / @dx,dy / dist<angle / bare distance).
        if CommandParser.looksLikeCoordinate(trimmed) {
            guard isToolActive else {
                lastCommandError = "Start a tool first"
                appendTranscript(.error, "Start a tool first")
                return .error("Start a tool first")
            }
            // Typed coordinates are interpreted in the ACTIVE UCS: parse the whole token
            // in UCS space (the reference/cursor are first converted INTO the UCS), then
            // convert the parsed point back to WORLD before feeding the tool. Doing the
            // entire parse in UCS coordinates and converting the RESULT handles absolute
            // `x,y`, relative `@dx,dy`, and polar `dist<angle` uniformly. With `UCS.world`
            // `toUCS`/`toWorld`/`isWorld` collapse to the identity, so this is byte-for-
            // byte the previous behavior (same reference/cursor, same parsed point).
            let world = currentUCS.isWorld
            let reference = world ? relativeZero : relativeZero.map(currentUCS.toUCS)
            let cursor = world ? cursorWorld : cursorWorld.map(currentUCS.toUCS)
            switch CommandParser.parse(trimmed, reference: reference, cursor: cursor) {
            case .point(let p):
                let worldPoint = world ? p : currentUCS.toWorld(p)
                // An ENTITY-pick tool (Trim / Join / …) IGNORES a typed coordinate — its
                // `.value` arm returns `.none` and changes nothing. Don't echo a success
                // "→ x, y" for an input the active tool dropped on the floor (finding-M7);
                // report it as not applicable so the transcript stays truthful.
                if toolIgnoresTypedValue(activeToolKind) {
                    let message = "A typed coordinate doesn't apply to \(activeToolKind.title) — pick an entity"
                    lastCommandError = message
                    appendTranscript(.error, message)
                    return .error(message)
                }
                lastCommandError = nil
                handleToolInput(.value(worldPoint))
                // Echo the resolved WORLD point as an output readout (kept simple — a
                // 4-dp `x, y`, e.g. "→ 10, 20"); the tool itself owns any further prompt.
                appendTranscript(.output, "→ \(Self.transcriptPoint(worldPoint))")
                return .handled
            case .error(let message):
                lastCommandError = message
                appendTranscript(.error, message)
                return .error(message)
            }
        }

        // 3.5) A PARAMETER ASSIGNMENT (`a=22`, `b=a*2`, `w=22mm`) — checked AFTER the
        //      coordinate route (so `10,20` / `@5,5` never reach here — they have no `=`
        //      and `parseAssignment` rejects them anyway) and BEFORE the tool route (so a
        //      parameter line is never mis-read as a command). `parseAssignment` only fires
        //      on a valid identifier LHS, so `2=5` / `key=val`→syntax / a bare `=` all
        //      return `nil` and fall through. On a hit we CREATE/UPDATE the parameter and —
        //      if a dimensional constraint is in flight on the selection — AUTO-BIND it to
        //      the parameter, all in ONE undo group, then return `.handled` (NEVER falling
        //      through to tool parsing).
        if let (name, expression, _) = ExpressionEvaluator.parseAssignment(trimmed) {
            return handleParameterAssignment(name: name, expression: expression, echo: trimmed)
        }

        // 4) A recognized tool command name — the View activates (handles `.image` modal).
        if let kind = ToolSuggester.resolve(command: trimmed) {
            recordCommandBarUse(kind)
            lastCommandError = nil
            appendTranscript(.tool, kind.title)
            return .activateTool(kind)
        }

        // 5) Unrecognized.
        let message = "Unknown command: \(trimmed)"
        lastCommandError = message
        appendTranscript(.error, message)
        return .error(message)
    }

    /// Handles a parsed `name = expression` command-line assignment (Lane L2): creates or
    /// updates the user parameter `name` through the re-solving funnel, and — if a
    /// dimensional constraint is IN FLIGHT on the selection (`pendingDimensionalConstraint`)
    /// — AUTO-BINDS a dimensional constraint of that kind to the new parameter over the
    /// current selection, all in ONE undo group. Always returns `.handled` (a parameter
    /// line never falls through to tool parsing) and echoes a readout into the transcript.
    private func handleParameterAssignment(name: String, expression: String,
                                           echo: String) -> CommandLineResult {
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        // Define / update the parameter (re-solving any geometry it already drives).
        setParameterExpression(name: name, expression: expression)

        // AUTO-BIND: if a dimensional constraint is awaiting a value, create it bound to
        // this parameter over the current selection (in the SAME undo group). On an arity
        // failure the parameter still stands; we just don't bind (and clear the pending
        // flag either way so a stale request doesn't linger).
        var boundNote = ""
        if let kind = pendingDimensionalConstraint {
            let ids = orderedSelectionIDs
            if addConstraint(kind, entities: ids, expression: name) {
                boundNote = " → \(kind.rawValue) constraint bound"
            }
            pendingDimensionalConstraint = nil
        }

        lastCommandError = nil
        let value = drawing.parameters.parameter(named: name)?.value
        let valueText = value.map { Self.transcriptCoord($0) } ?? expression
        appendTranscript(.output, "\(name) = \(valueText)\(boundNote)")
        return .handled
    }

    /// Marks a DIMENSIONAL constraint of `kind` as "in flight" on the current selection,
    /// so the NEXT `name=value` command-line assignment AUTO-BINDS the dimension to that
    /// parameter (see `pendingDimensionalConstraint`). The View/menu calls this when the
    /// user picks "Distance"/"Radius" and is prompted for a value (which they may type as a
    /// parameter assignment). `cancelDimensionalConstraint()` clears it without binding.
    func beginDimensionalConstraint(_ kind: DimensionalConstraintKind) {
        pendingDimensionalConstraint = kind
    }

    /// Clears any pending dimensional-constraint auto-bind request (the user cancelled or
    /// the flow ended without a parameter assignment).
    func cancelDimensionalConstraint() {
        pendingDimensionalConstraint = nil
    }

    /// Format a resolved world point for the transcript `.output` readout: each axis at
    /// up to 4 decimal places with trailing zeros trimmed (so `10, 20` not `10.0000,
    /// 20.0000`), joined `x, y`. Pure + `nonisolated static` so it unit-tests with no
    /// model/GUI from any actor context.
    nonisolated static func transcriptPoint(_ p: Vector) -> String {
        "\(transcriptCoord(p.x)), \(transcriptCoord(p.y))"
    }

    /// One axis value formatted for the transcript: fixed 4-dp then trailing zeros (and a
    /// dangling decimal point) trimmed. Pure helper for `transcriptPoint`.
    nonisolated private static func transcriptCoord(_ v: Double) -> String {
        // Normalize -0.0 → 0 so the readout never shows a signed zero.
        let value = v == 0 ? 0 : v
        var s = String(format: "%.4f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// Builds the read-only `ToolContext` snapshot for one `handle` call: the
    /// current selection resolved to records, a lookup into the drawing, the
    /// last-seen grid step, and the boundary hooks (`nearbyEntities` / `allEntities`)
    /// the editing tools (Trim / Extend / Fillet) read. Rebuilt per call so the tool
    /// always sees current state (cheap: the selection is usually small / empty
    /// while drawing).
    ///
    /// ## Why the live canvas path queries the `Quadtree` (Wave 2)
    /// `Selection.hitTest` prefilters with the shared `quadtree`, then runs the
    /// exact analytic distance. `nearbyEntities` now does the SAME: it queries the
    /// live `quadtree` for AABB candidates around the pick (`query(point:tolerance:)`
    /// → `AABB(min: cursor - tol, max: cursor + tol)` probe) and then keeps only
    /// those whose EXACT `HitTesting.worldDistance` is within `tol`. This is
    /// `O(k log n)` in the number of candidates, not `O(N)` over the whole
    /// drawing, and reuses the single index the renderer and `hitTest` already
    /// maintain.
    ///
    /// The `Quadtree` is a non-`Sendable` `MainActor` class that cannot be captured
    /// directly in a `@Sendable` closure. The closure captures a `SendableQuadtree`
    /// box (`@unchecked Sendable`) and hops to `MainActor` via
    /// `MainActor.assumeIsolated` to query — safe because `handleToolInput` (the
    /// only caller that builds a `ToolContext` from the canvas) is `MainActor` and
    /// every `nearbyEntities` invocation happens synchronously inside that
    /// `handle`. Engine unit tests that build a `ToolContext` by hand (no live
    /// quadtree) use the value-snapshot path and remain off-main safe.
    private func makeToolContext() -> ToolContext {
        let snapshot = drawing.entities          // CoW value snapshot (Sendable)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        let selected = selection.ids.compactMap { byID[$0] }
        // Box the live quadtree for the `@Sendable` closure. The box is
        // `@unchecked Sendable` but we only touch `tree` on `MainActor` (see
        // header comment on `SendableQuadtree`).
        let qtBox = SendableQuadtree(tree: quadtree)
        return ToolContext(
            selected: selected,
            entity: { id in byID[id] },
            gridSpacing: lastGridSpacing,
            nearbyEntities: { point, tolerance in
                guard point.valid else { return [] }
                let tol = Swift.max(tolerance, 0)
                // Fast path: AABB prefilter via the live quadtree (MainActor),
                // then exact analytic distance (shared kernel with `hitTest`).
                // Off-main fallback (defensive): if the closure is ever invoked
                // off the main actor (e.g., a tool test driving handle off-main),
                // fall back to the brute-force `O(N)` scan over the value snapshot
                // — correct and Sendable, just not fast. The live canvas path is
                // always MainActor, so this branch is never taken in the app.
                if !Thread.isMainThread {
                    return snapshot.filter { record in
                        guard record.flags.contains(.visible) else { return false }
                        return HitTesting.worldDistance(from: point, to: record) <= tol
                    }
                }
                let candidateIDs: [EntityID] = MainActor.assumeIsolated {
                    qtBox.tree.query(point: point, tolerance: tol)
                }
                if candidateIDs.isEmpty { return [] }
                var out: [EntityRecord] = []
                out.reserveCapacity(candidateIDs.count)
                for id in candidateIDs {
                    guard let rec = byID[id], rec.flags.contains(.visible) else { continue }
                    if HitTesting.worldDistance(from: point, to: rec) <= tol {
                        out.append(rec)
                    }
                }
                return out
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

    /// The tool kinds whose `Tool.handle` IGNORES a typed `.value` coordinate (it returns
    /// `.none` and changes nothing) — the ENTITY-pick edit/modify tools whose picks name an
    /// entity under the cursor, which a coordinate cannot identify (the documented `.value`
    /// exceptions on `ToolInput.value`). Keyed off the active `ToolKind` so the echo gate
    /// (`interpretCommandLine`) is deterministic without a new engine flag.
    ///
    /// Mirrors each tool's own `case .value: … return .none` arm (TrimTool, ExtendTool,
    /// FilletTool, ChamferTool, BreakTool, JoinTool, DivideTool, ExplodeTool,
    /// ExplodeTextTool, ExplodeInsertTool, ArrayTool, ArrayPathTool, HatchTool). Tools that
    /// CONSUME `.value` are NOT here: every draw/dimension tool, the point-picking modify
    /// tools (Move/Copy/Rotate/Mirror/Align/Scale/Offset), Stretch (delta) and Lengthen
    /// (signed delta), and the partially-consuming `.lineConstruction` / `.polylineEdit`
    /// (whose point-pick steps DO consume — echoing then is correct). `.select`/`.viewport`
    /// have no `Tool`, so a typed coordinate is rejected upstream ("Start a tool first")
    /// before the echo ever runs; their absence here is immaterial.
    private static let ignoresTypedValueKinds: Set<ToolKind> = [
        .trim, .extend, .fillet, .chamfer, .break, .join,
        .divide, .explode, .explodeText, .explodeInsert,
        .array, .arrayPath, .hatch,
    ]

    /// Whether the active tool `kind` IGNORES a typed `.value` coordinate (an entity-pick
    /// tool). The command line uses this to gate the "→ x, y" success echo: a coordinate an
    /// entity-pick tool dropped on the floor must NOT read as if it placed a point
    /// (finding-M7).
    private func toolIgnoresTypedValue(_ kind: ToolKind) -> Bool {
        Self.ignoresTypedValueKinds.contains(kind)
    }

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

        // AUTO-CONSTRAIN (Lane A): the ids of LINE entities freshly added by this commit,
        // collected as they are minted so an AutoConstrain pass can weld their corners +
        // infer angles AFTER all adds land (so a multi-segment commit welds sibling
        // segments too). Only genuine DRAWs (`adoptsCurrentProperties`) feed this — a
        // DERIVE/CLONE (Copy/Array/Offset) must not auto-constrain its clones.
        var autoConstrainCandidates: [EntityID] = []

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

                // AUTO-CONSTRAIN candidate: a genuinely DRAWN line (not a clone, not a
                // block member). Block members live inside a block's local frame and are
                // drawn via inserts, not top-level constrainable geometry — exclude them.
                if adoptsCurrentProperties, editingBlock == nil,
                   case .line? = drawing.entity(id)?.kind {
                    autoConstrainCandidates.append(id)
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

        // AUTO-CONSTRAIN on draw (Lane A): weld touching corners + infer angular
        // constraints for the lines this commit just drew. Runs INSIDE the still-open
        // undo group (the `defer` above closes it only at function exit), so the draw and
        // every auto-constraint it spawns collapse into ONE ⌘Z. A no-op when the toggle is
        // off or nothing line-shaped was drawn (byte-identical to the pre-feature path).
        autoConstrain(newLineIDs: autoConstrainCandidates)

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

        var edited: Set<EntityID> = []
        for record in records {
            guard drawing.contains(record.id) else { continue }
            drawing.replace(record)                 // undoable; preserves id
            edited.insert(record.id)
            let box = record.boundingBox()
            if box.isEmpty { quadtree.remove(record.id) }
            else { quadtree.update(record.id, bounds: box) }
        }
        // PARAMETRIC RE-SOLVE SEAM (Wave 3): after the user-driven edit lands, re-solve
        // the connected component(s) of any edited entity that participates in a
        // constraint, so dependent geometry follows (a dragged grip / changed property
        // pulls coupled entities into a satisfied configuration). The solve's
        // `drawing.replace` calls register into the SAME open undo group as the edits
        // above (we are still inside `explicitGroup` here, before the `defer` closes it,
        // and in the live app the whole inspector commit is one run-loop event), so a
        // single ⌘Z reverts BOTH the edit AND the re-solve. CHEAP early-out when no
        // constraint touches the edit (the common case).
        resolveConstraints(touching: edited)
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

    // MARK: - Layer ISOLATE / UNISOLATE (Wave 3B — via the pure `LayerIsolation`)
    //
    // The daily "focus on these layers, hide the rest, then restore EXACTLY" op
    // (AutoCAD LAYISO / LAYUNISO). The semantics live in the pure engine
    // `LayerIsolation` (keep-set → freeze/thaw plan + an exact restore snapshot);
    // this side only APPLIES the plan through the existing undoable `mutateLayers`
    // funnel and STASHES the restore snapshot so `unisolateLayers()` reverts to the
    // precise prior flags (a frozen-before / locked / printable layer returns to that).

    /// The exact-restore snapshot captured by the last isolate, applied by
    /// `unisolateLayers()`. `nil` when nothing is isolated. Transient view state (not
    /// persisted, not a document mutation) — the undo of the isolate itself is the
    /// `mutateLayers` value-snapshot; this is the explicit LAYUNISO inverse.
    @ObservationIgnored
    private var isolationRestore: LayerState?

    /// Whether a layer isolation is currently in effect (a restore snapshot is stashed)
    /// — drives the "Unisolate Layers" menu item's enabled state.
    var hasIsolatedLayers: Bool { isolationRestore != nil }

    /// Isolates the given `keep` layers: freezes every OTHER layer and thaws any kept
    /// layer that was hidden, in ONE undoable `mutateLayers` step (via the pure
    /// `LayerIsolation.isolate`), and STASHES the exact-restore snapshot so
    /// `unisolateLayers()` can revert. No-op (no undo step, restore left untouched) when
    /// the keep-set is empty of real layers or the plan changes nothing. The shared core
    /// behind the public isolate entry points.
    @discardableResult
    private func applyIsolation(keep: Set<String>) -> Bool {
        let existing = keep.filter { drawing.layers.contains($0) }
        guard !existing.isEmpty else { return false }
        let result = LayerIsolation.isolate(keep: existing, in: drawing.layers)
        guard !result.isNoOp else {
            // Already isolated to exactly this set: keep any prior restore so a later
            // unisolate still works (the no-op didn't change the table).
            return false
        }
        // One undo step (same grouping rationale as `applyCommit`/`applyInspectorEdits`:
        // groups-by-event in the live app, explicit group when a test drives this with
        // grouping-by-event off + no run loop).
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        drawing.mutateLayers { result.isolated.apply(to: &$0) }   // one undo step
        isolationRestore = result.restore
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// "Hide other layers" — isolates the single named `layer` (freezes every other,
    /// thaws this one), undoable, and stashes the exact-restore snapshot. No-op if
    /// `layer` is unknown. Rewired onto the pure `LayerIsolation` (was a manual
    /// visibility loop) so an `unisolateLayers()` returns layers to their PRECISE prior
    /// flags rather than blanket-showing everything.
    func isolateLayer(_ layer: String) {
        _ = applyIsolation(keep: [layer])
    }

    /// Isolates the layers of the CURRENT SELECTION (LAYISO from a selection): the kept
    /// set is every distinct layer the selected entities live on. Freezes all others,
    /// undoable, and stashes the restore snapshot. No-op for an empty selection / when
    /// the selection's layers are already the only visible ones. Returns whether the
    /// visibility changed.
    @discardableResult
    func isolateSelectionLayers() -> Bool {
        let layers = Set(selection.ids.compactMap { drawing.entity($0)?.layer.name })
        return applyIsolation(keep: layers)
    }

    /// Reverses the last isolate (LAYUNISO): applies the stashed exact-restore snapshot
    /// through the undoable `mutateLayers` funnel so every layer returns to its prior
    /// frozen/visible state, then clears the stash. No-op (returns `false`) when nothing
    /// is isolated. Returns whether anything was restored.
    @discardableResult
    func unisolateLayers() -> Bool {
        guard let restore = isolationRestore else { return false }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        drawing.mutateLayers { restore.apply(to: &$0) }   // one undo step
        isolationRestore = nil
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// "Turn off other layers" — freezes every layer EXCEPT those in `keep`, WITHOUT
    /// thawing any kept-but-hidden layer and WITHOUT stashing a restore (the plain
    /// LibreCAD "freeze others" affordance, distinct from LAYISO's isolate-with-restore).
    /// Undoable via `mutateLayers`. No-op when the keep-set has no real layers / nothing
    /// to freeze. Returns whether the visibility changed.
    @discardableResult
    func turnOffOtherLayers(keep: Set<String>) -> Bool {
        let existing = keep.filter { drawing.layers.contains($0) }
        guard !existing.isEmpty else { return false }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        var changed = false
        drawing.mutateLayers { table in
            for l in table.layers where !existing.contains(l.name) && !l.isFrozen {
                table.setFrozen(l.name, true)
                changed = true
            }
        }
        guard changed else { return false }
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// Convenience: turn off every layer except the single named one.
    @discardableResult
    func turnOffOtherLayers(except layer: String) -> Bool {
        turnOffOtherLayers(keep: [layer])
    }

    /// Makes `layer` the CURRENT (active) layer — where new geometry lands (AutoCAD
    /// CLAYER). Undoable via the existing `setActiveLayer` funnel. No-op (returns
    /// `false`) when `layer` is unknown or already current. Returns whether it changed.
    @discardableResult
    func makeLayerCurrent(_ layer: String) -> Bool {
        guard drawing.layers.contains(layer),
              drawing.layers.activeLayerName != layer else { return false }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        drawing.setActiveLayer(layer)   // undoable
        modelVersion &+= 1
        return true
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

    /// The WORLD-space orientation (radians, CCW) the resting/idle selection gizmo
    /// should be drawn at, so a rotated object's resting chrome stays ORIENTED to it
    /// (task #17) instead of reverting to an upright AABB after a rotate.
    ///
    /// Two tiers:
    /// 1. **Intrinsic fast path** — a SINGLE selected entity whose kind carries a
    ///    stored rotation (insert / text / mtext / ellipse / image / linear
    ///    dimension) returns that stored angle directly. This is sourced from the
    ///    entity's STORED rotation, not re-derived from a matrix, so a non-uniform
    ///    scale-then-rotate never drifts the angle. No new `EntityKind` case — a
    ///    read-only `switch` on the single selected entity.
    /// 2. **General OBB fallback** — a rotated rectangle (a baked 4-vertex polyline
    ///    with no angle field), free lines/polylines, or a multi-selection use the
    ///    minimum-area oriented bounding box of the selection's resolved geometry
    ///    points (`OrientedBounds.minAreaRect`). A symmetric shape (square / circle)
    ///    or a degenerate selection falls back to `0` (upright), so the resting
    ///    chrome never jitters onto an arbitrary axis.
    ///
    /// `0` when there is no selection, or when neither tier yields an orientation.
    var gizmoOrientation: Double {
        guard !selection.isEmpty else { return 0 }
        if selection.count == 1, let id = selection.ids.first,
           let e = drawing.entity(id),
           let intrinsic = Self.intrinsicRotation(of: e.kind) {
            return intrinsic
        }
        return OrientedBounds.minAreaRect(selectionWorldPoints())?.angle ?? 0
    }

    /// The stored intrinsic rotation (radians, CCW) of a single entity kind, or
    /// `nil` for kinds with no meaningful single orientation (circle, point,
    /// free polyline, non-linear dimensions, …) — those fall back to the OBB.
    ///
    /// READ-ONLY switch (NO new `EntityKind` case). Angles are read from STORED
    /// fields so they don't drift under a non-uniform scale.
    private static func intrinsicRotation(of kind: EntityKind) -> Double? {
        switch kind {
        case .insert(let d):  return d.rotation
        case .text(let d):    return d.rotation
        case .mtext(let d):   return d.rotation
        case .image(let d):   return d.rotation
        case .ellipse(let d): return d.rotationAngle   // == majorP.angle
        case .dimension(let d):
            // Only a LINEAR (rotated) dimension has a single defining direction.
            if case .linear(_, _, let angle) = d.kind { return angle }
            return nil
        default:
            return nil
        }
    }

    /// The selection's resolved geometry vertices in WORLD coords — the point cloud
    /// the OBB orientation + oriented base frame are derived from. Reuses the same
    /// resolve path as `gizmoPreviewPolylines` (the `.toolPreview` pen is irrelevant
    /// to point positions). Image quads contribute their four corners. Empty for an
    /// empty selection or all-unresolvable ids.
    func selectionWorldPoints() -> [Vector] {
        guard !selection.isEmpty else { return [] }
        let ctx = drawing.makeResolveContext()
        var pts: [Vector] = []
        for id in selection.ids {
            guard let record = drawing.entity(id) else { continue }
            let geo = record.kind.resolve(pen: .toolPreview, ctx: ctx)
            for poly in geo.polylines { pts.append(contentsOf: poly.points) }
            for fill in geo.fills { for loop in fill.loops { pts.append(contentsOf: loop) } }
            for img in geo.images { pts.append(contentsOf: img.corners) }
        }
        return pts
    }

    /// The ORIENTED base frame for the resting gizmo: an AXIS-ALIGNED `GizmoFrame`
    /// (its stored `min`/`max` un-rotated) that, when rotated by `gizmoOrientation`
    /// about its own `center` via `Affine2D.rotation(_:about:)`, hugs the selection
    /// geometry. The overlay draws the oriented quad as `rotation(orientation,
    /// about: base.center).apply(base.corner(·))` (Stage 3), so a base frame +
    /// orientation pair reproduces the object's oriented box.
    ///
    /// Built by un-rotating the selection points by `-orientation` about the
    /// selection's plain AABB center, taking that local AABB, and re-centering it at
    /// the world point the local AABB center maps back to. For `orientation == 0`
    /// this is exactly the plain world AABB (byte-identical to the legacy upright
    /// frame). `nil` when there is no resolvable geometry.
    var gizmoOrientedBaseFrame: GizmoFrame? {
        let angle = gizmoOrientation
        // Angle 0 → the legacy upright AABB frame, unchanged.
        if angle == 0 { return selectionWorldBounds.flatMap { GizmoFrame(box: $0) } }

        let pts = selectionWorldPoints()
        guard pts.count >= 1 else {
            return selectionWorldBounds.flatMap { GizmoFrame(box: $0) }
        }
        // The geometry's plain AABB center (a stable un-rotate pivot).
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        let g = Vector((minX + maxX) * 0.5, (minY + maxY) * 0.5)
        let unrot = Affine2D.rotation(angle: -angle, about: g)
        // AABB of the un-rotated points (the box in the rotated basis).
        let local = unrot.apply(pts[0])
        var lMinX = local.x, lMaxX = local.x, lMinY = local.y, lMaxY = local.y
        for p in pts {
            let q = unrot.apply(p)
            lMinX = Swift.min(lMinX, q.x); lMaxX = Swift.max(lMaxX, q.x)
            lMinY = Swift.min(lMinY, q.y); lMaxY = Swift.max(lMaxY, q.y)
        }
        let lc = Vector((lMinX + lMaxX) * 0.5, (lMinY + lMaxY) * 0.5)
        // The local AABB center mapped back to world is the oriented box center.
        let bc = Affine2D.rotation(angle: angle, about: g).apply(lc)
        let hx = (lMaxX - lMinX) * 0.5
        let hy = (lMaxY - lMinY) * 0.5
        return GizmoFrame(min: Vector(bc.x - hx, bc.y - hy),
                          max: Vector(bc.x + hx, bc.y + hy))
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

    // MARK: - Per-entity GRIP editing mount (Wave 3B — EntityGripOverlay backing)
    //
    // The `EntityGripOverlay` (mounted by 3B') is SELF-CONTAINED + INJECTED: it owns
    // no model and carries no geometry math (that is `EntityGrips`). The mount supplies
    // it five closures — `selectionProvider` / `contextProvider` / `viewportProvider` /
    // `onGripCommit` / `requestRedraw` — plus toggles `isEnabled`. These accessors are
    // the contract 3B' wires those closures to; the GRIP MATH already lives in the pure
    // engine `EntityGrips` (queried + applied by the overlay), so this side only routes
    // the moved record through the EXISTING undoable commit funnel (no new undo path).

    /// The records the grip overlay draws handles for — the SELECTION resolved to live
    /// `EntityRecord`s. The overlay further filters to those that actually expose grips
    /// (`EntityGrips.grips(for:)` non-empty), so this returns the whole selection; the
    /// 3B' mount wires this as the overlay's `selectionProvider`.
    var gripSelectionRecords: [EntityRecord] {
        selection.ids.compactMap { drawing.entity($0) }
    }

    /// The `ResolveContext` the grip overlay passes to `EntityGrips.grips`/`moveGrip`
    /// (font/tessellation/block resolution for the live drawing). The 3B' mount wires
    /// this as the overlay's `contextProvider`. A thin pass-through over the drawing's
    /// resolve context so the overlay never reaches into `drawing` directly.
    func gripResolveContext() -> ResolveContext { drawing.makeResolveContext() }

    /// The live `Viewport` the grip overlay uses for world↔screen projection (handle
    /// placement + nearest-grip hit-testing). The 3B' mount wires this as the overlay's
    /// `viewportProvider`. (A method, not just the `viewport` property, so the mount can
    /// pass it as an `@escaping () -> Viewport` closure that always reads the latest.)
    func gripViewport() -> Viewport { viewport }

    /// Whether the grip overlay should currently participate (the mount drives the
    /// overlay's `isEnabled` from this). Grips are active ONLY in SELECT mode, with a
    /// selection that has at least one grip-editable entity, and NOT while a gizmo drag
    /// is in progress (so the two transparent overlays never fight over an ambiguous
    /// hit-test — the same dual-overlay arbitration the dynamic grip uses). Block-edit
    /// sessions are fine (the selection is scoped to the block's members there).
    var gripsEnabled: Bool {
        guard activeToolKind == .select else { return false }
        guard gizmoPreviewTransform == nil else { return false }   // gizmo owns the gesture
        return hasGripEditableSelection
    }

    /// Whether the current selection contains at least one grip-editable entity (a line/
    /// circle/arc/polyline/ellipse/spline/point/text — anything `EntityGrips.grips(for:)`
    /// returns handles for). Drives `gripsEnabled` + lets the mount skip mounting the
    /// overlay for a selection of only en-bloc kinds (insert/hatch/dimension/…).
    var hasGripEditableSelection: Bool {
        let ctx = drawing.makeResolveContext()
        return selection.ids.contains { id in
            guard let r = drawing.entity(id) else { return false }
            return !EntityGrips.grips(for: r, ctx: ctx).isEmpty
        }
    }

    /// Commits a grip-edited record (the overlay's `onGripCommit`): applies the moved
    /// `EntityRecord` as ONE undoable `.replace` of that id through the EXISTING
    /// inspector-edit funnel (`applyInspectorEdits` — the same path the gizmo + Inspector
    /// use), so a single ⌘Z reverts the grip drag, the quadtree stays in sync, and the
    /// GPU buffer is marked dirty. The overlay already produced the new geometry via the
    /// pure `EntityGrips.moveGrip`, so this side carries NO geometry math. No-op (returns
    /// `false`) if the record's id is no longer in the drawing or the edit is a no-op
    /// (the moved record is byte-for-byte the current one — a zero-effect drag never
    /// pushes an undo step, mirroring `commitGizmoTransform`). Returns whether anything
    /// changed.
    @discardableResult
    func commitMovedGrip(_ record: EntityRecord) -> Bool {
        guard let current = drawing.entity(record.id), current != record else { return false }
        applyInspectorEdits([record])   // undoable .replace; index-synced; GPU dirty
        // NB: the parametric re-solve is driven INSIDE `applyInspectorEdits` (the single
        // chokepoint both the grip overlay and the Inspector route through), so a
        // grip-edited constrained entity pulls its coupled geometry along in the same
        // undo group with no extra call here.
        return true
    }

    // MARK: - Parametric constraints (Wave 3 — APP seam: re-solve + create/remove)
    //
    // The engine pieces (the `ConstraintTable` on `CADDrawing`, the undoable
    // `addConstraint`/`removeConstraint`/`editConstraint` funnels, and the pure
    // `ConstraintSolver`) already exist and are unit-tested. This is the APP seam that
    // makes constraints actually DRIVE geometry: after a user edit (grip drag or
    // Inspector property change) the connected component(s) of any constrained edited
    // entity are re-solved and the satisfied geometry applied — or, on a solver
    // failure, NOTHING is written (a clean revert, never a partial). A selection-based
    // create path (`addConstraint`) validates arity, registers the constraint, and
    // re-solves so it takes effect immediately; all in ONE undo group. The menu/toolbar
    // that invokes these on the current selection is the later wire-wave.

    /// RE-SOLVES the parametric constraints that touch `ids` and applies the satisfied
    /// geometry. For every edited id that actually participates in a constraint, the
    /// id's CONNECTED COMPONENT (every entity transitively coupled to it by shared
    /// constraints) is gathered, the constraints within that component are collected,
    /// and `ConstraintSolver.solve` is run:
    ///   • `.solved` → each entity's new geometry is folded back via the undoable
    ///     `drawing.replace` (layer/pen/flags preserved) and the quadtree updated.
    ///   • `.failed` → NOTHING is written for that component (a clean REVERT — never a
    ///     partial / garbage write; the user's edit stands, the dependents don't move).
    ///
    /// CHEAP EARLY-OUT: if the table is empty, or none of `ids` is referenced by any
    /// constraint, this returns immediately having touched nothing (the common case —
    /// most edits are to unconstrained geometry).
    ///
    /// UNDO GROUPING (critic fix): this method does NOT open its own undo group — its
    /// `drawing.replace` calls register into whatever group is currently open. The two
    /// callers each own the group: `applyInspectorEdits` calls this INSIDE its
    /// `explicitGroup` (so an edit + its re-solve are ONE ⌘Z), and `addConstraint`
    /// wraps the constraint-add + this call in one group. Never call this bare expecting
    /// its own undo step.
    ///
    /// Returns whether any geometry was changed (false on early-out or a no-op solve).
    @discardableResult
    func resolveConstraints(touching ids: Set<EntityID>) -> Bool {
        // (−1) PARAMETER CACHE-FRESHNESS CHOKE POINT (Lane L2): before solving, refresh
        //      every parameter-DRIVEN constraint's cached `value` from the current
        //      parameter table. This is THE single place a re-solve learns about an
        //      edited parameter — so an edited `w` flows into every `expression == w`
        //      constraint and then into the geometry below, in the caller's undo group.
        //      It does NOT open its own group (the caller owns it) and never writes a
        //      bad/cyclic value (it keeps the last-good cache instead — never NaN to the
        //      solver). It registers undo via `editConstraint`, coalescing into the same
        //      ⌘Z as the edit + the re-solve.
        recomputeParameterDrivenValues()

        // (0) Early-out: no constraints at all, or none of the edited ids is constrained.
        guard !drawing.constraints.isEmpty, !ids.isEmpty else { return false }
        let constrained = drawing.constraints.referencedEntityIDs
        let seeds = ids.filter { constrained.contains($0) }
        guard !seeds.isEmpty else { return false }

        // (1) Union the connected components of every constrained seed (one entity can
        //     pull on many; processing a component once handles all its members). A
        //     `processed` set skips re-solving a component already covered by an earlier
        //     seed in the same edit.
        var processed: Set<EntityID> = []
        var changedAny = false
        for seed in seeds where !processed.contains(seed) {
            let component = drawing.constraints.connectedComponent(of: seed)
            processed.formUnion(component)

            // (2) Gather the component's live geometry (keyed by id) + the constraints
            //     that lie entirely within it (the solver's two inputs). A constraint
            //     referencing a now-missing entity is skipped defensively.
            var entities: [EntityID: EntityKind] = [:]
            for id in component {
                if let rec = drawing.entity(id) { entities[id] = rec.kind }
            }
            guard !entities.isEmpty else { continue }
            let constraints = drawing.constraints.constraints(within: component)
            guard !constraints.isEmpty else { continue }

            // (3) Solve. On failure, write NOTHING for this component (clean revert) but
            //     FLAG every constraint in it as unsatisfied (the geometry does not honor
            //     it — the overlay/list must surface the dangling badge, not hide it). On
            //     success, CLEAR those ids from the unsatisfied set (they hold again).
            switch ConstraintSolver.solve(entities: entities, constraints: constraints) {
            case .failed:
                unsatisfiedConstraintIDs.formUnion(constraints.map(\.id))
                continue
            case .solved(let geometry):
                unsatisfiedConstraintIDs.subtract(constraints.map(\.id))
                if applySolvedGeometry(geometry) { changedAny = true }
            }
        }
        return changedAny
    }

    /// RE-SOLVES every constrained component in the drawing (the union of all referenced
    /// entities) and refreshes `unsatisfiedConstraintIDs` over the WHOLE table — the
    /// load-time / full-table counterpart of `resolveConstraints(touching:)`. Used by
    /// `setDrawing` so a freshly-opened drawing ENFORCES its restored constraints on the
    /// loaded geometry (and flags any the geometry doesn't satisfy). A no-op when the
    /// table is empty.
    ///
    /// Unlike `resolveConstraints(touching:)` (which relies on a caller-owned group), this
    /// OPENS ITS OWN undo group when one isn't already open (`groupsByEvent == false`,
    /// e.g. the `setDrawing` load path or a test) so its `drawing.replace` calls always
    /// have a group to register into. `setDrawing` clears the undo stack right after, so
    /// the load-time enforcement is part of the clean baseline, not a user-undoable step.
    @discardableResult
    func resolveAllConstraints() -> Bool {
        guard !drawing.constraints.isEmpty else {
            unsatisfiedConstraintIDs.removeAll()
            return false
        }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        return resolveConstraints(touching: drawing.constraints.referencedEntityIDs)
    }

    /// Folds solver output back into the drawing through the undoable `drawing.replace`
    /// (preserving each entity's layer/pen/flags — only its geometry `kind` changes) and
    /// keeps the quadtree in sync. Skips an entity whose geometry is unchanged (so a
    /// no-op solve never pushes a spurious undo step) or that has gone missing. Returns
    /// whether anything actually changed.
    @discardableResult
    private func applySolvedGeometry(_ geometry: [EntityID: SolvedGeometry]) -> Bool {
        var changed = false
        for (id, solved) in geometry {
            guard var record = drawing.entity(id) else { continue }
            let newKind: EntityKind
            switch solved {
            case .line(let d):   newKind = .line(d)
            case .circle(let d): newKind = .circle(d)
            case .point(let d):  newKind = .point(d)
            }
            guard record.kind != newKind else { continue }   // no-op: don't pollute undo
            record.kind = newKind
            drawing.replace(record)                           // undoable; preserves id
            let box = record.boundingBox()
            if box.isEmpty { quadtree.remove(id) } else { quadtree.update(id, bounds: box) }
            changed = true
        }
        return changed
    }

    // MARK: - Parameter re-eval → re-solve SEAM (Lane L2)
    //
    // This is the glue that makes NAMED PARAMETERS actually DRIVE geometry. The engine
    // pieces already exist: the `ParameterTable` on `CADDrawing` (undoable
    // add/update/remove), the additive `Constraint.expression` (nil = pure literal; the
    // SOLVER reads only `value`), and the pure `ExpressionEvaluator` (topo + cycle-safe).
    // What was missing — and lives HERE — is:
    //   • a cache-freshness CHOKE POINT (`recomputeParameterDrivenValues`) that, at the
    //     top of every re-solve, re-evaluates the whole parameter table and writes each
    //     parameter-driven constraint's fresh `value` (keeping the last-good value on a
    //     bad/cyclic expression — never NaN to the solver);
    //   • edit→re-solve FUNNELS (`setParameterExpression` / `setParameterValue` /
    //     `setConstraintExpression` / `removeParameterAndResolve`) that wrap a parameter/
    //     binding edit AND the geometry it drives in ONE undo group (one ⌘Z reverts both);
    //   • UNIT CONVERSION at this seam (`evaluatedValue(forExpression:)`): a literal that
    //     carries a unit token (`22mm`) is converted to the drawing's unit here — the pure
    //     evaluator stays unit-naive (it only REPORTS the token).

    /// CACHE-FRESHNESS CHOKE POINT: re-evaluates the whole parameter table and writes the
    /// freshly-evaluated `value` onto EVERY constraint with a non-nil `expression`. Called
    /// at the TOP of `resolveConstraints(touching:)` so a parameter edit propagates into
    /// the geometry within the SAME undo group the caller already opened.
    ///
    /// • Builds a name→value symbol map by evaluating the parameter table topologically
    ///   (`ExpressionEvaluator.evaluateTable`), then writing each parameter's own fresh
    ///   `value` back (so the Parameters UI / persistence see the live cache). UNIT-bearing
    ///   bare literals (`22mm`) are converted to the drawing's unit via
    ///   `evaluatedValue(forExpression:)`, and the converted magnitude is what propagates
    ///   to dependents (`h = w/2` uses the converted `w`).
    /// • For every constraint whose `expression != nil`, re-evaluates that expression
    ///   against the symbol map (+ unit conversion) and writes the result through the
    ///   undoable `drawing.editConstraint(_:value:)` (so the solver — which reads ONLY
    ///   `value` — sees the new driven number).
    /// • ROBUSTNESS: a parameter expression that is cyclic / syntactically bad / references
    ///   an unknown name leaves that parameter's (and any dependent constraint's) LAST-GOOD
    ///   `value` untouched — NEVER a NaN written into the solver. A whole-table cycle falls
    ///   back to a per-name best-effort pass so the good parameters still refresh.
    ///
    /// Does NOT open its own undo group (the caller owns it) and does NOT bump
    /// `modelDirty`/`modelVersion` (the caller's re-solve / edit already does). A no-op
    /// (no parameters AND no parameter-driven constraints) returns having touched nothing.
    func recomputeParameterDrivenValues() {
        let params = drawing.parameters.parameters
        let drivenConstraints = drawing.constraints.constraints.filter { $0.expression != nil }
        // Cheap early-out: nothing references a parameter/expression at all.
        guard !params.isEmpty || !drivenConstraints.isEmpty else { return }

        // (1) Resolve the parameter symbol map (name → unit-converted value), keeping the
        //     last-good cache for any parameter that fails to evaluate.
        let symbols = resolvedParameterSymbols(params)

        // (2) Write each parameter's fresh value back (so the table cache stays live for
        //     the Parameters UI / persistence). Skips unchanged / failed ones.
        for p in params {
            guard let fresh = symbols[p.name.lowercased()], fresh.isFinite,
                  p.value != fresh else { continue }
            var updated = p
            updated.value = fresh
            drawing.updateParameter(updated)   // undoable; no-op guard inside
        }

        // (3) Re-evaluate each parameter-driven CONSTRAINT and write its fresh `value`.
        for c in drivenConstraints {
            guard let expr = c.expression,
                  let fresh = evaluatedValue(forExpression: expr, symbols: symbols),
                  fresh.isFinite else { continue }   // bad/cyclic → keep last-good value
            drawing.editConstraint(c.id, value: fresh)   // undoable; no-op + non-dim guard
        }
    }

    /// Resolves the parameter table to a `[lowercasedName: value]` symbol map with UNIT
    /// CONVERSION applied at this seam. Tries a whole-table topological evaluation first
    /// (the fast path); if that fails (a cycle / bad expression anywhere), falls back to a
    /// best-effort per-parameter pass so the GOOD parameters still refresh and only the
    /// offenders keep their last-good cache.
    ///
    /// For a bare unit-literal parameter (`w = 22mm`) the magnitude the evaluator returns
    /// is converted to the drawing's unit HERE, and the converted value is what seeds
    /// dependents — so `h = w/2` is computed from the converted `w`. A parameter whose
    /// own value can't be resolved contributes its LAST-GOOD `value` to the map (so it
    /// neither vanishes nor poisons dependents with NaN).
    private func resolvedParameterSymbols(_ params: [Parameter]) -> [String: Double] {
        // Seed every name with its last-good cached value (the fallback the map always has).
        var symbols: [String: Double] = [:]
        for p in params { symbols[p.name.lowercased()] = p.value }
        guard !params.isEmpty else { return symbols }

        // Build the evaluator table, substituting a bare unit-literal expression with its
        // already-unit-converted numeric so the conversion propagates transitively (the
        // pure evaluator is unit-naive; it would otherwise yield the raw magnitude).
        var table: [String: String] = [:]
        for p in params {
            let key = p.name.lowercased()
            if let converted = unitConvertedLiteral(p.expression) {
                table[key] = String(converted)             // pre-converted literal
            } else {
                table[key] = lowercasedIdentifiers(in: p.expression)
            }
        }

        // Fast path: a clean whole-table topo evaluation.
        if let resolved = try? ExpressionEvaluator.evaluateTable(table) {
            for (name, value) in resolved where value.isFinite { symbols[name] = value }
            return symbols
        }

        // Fallback: a bad/cyclic table. Evaluate name-by-name over the accumulating map;
        // each success refreshes that name, each failure keeps its last-good value. A few
        // passes let non-cyclic dependents resolve once their inputs are known.
        for _ in 0..<max(1, params.count) {
            var progressed = false
            for p in params {
                let key = p.name.lowercased()
                guard let value = try? ExpressionEvaluator.evaluate(table[key] ?? "", symbols: symbols),
                      value.isFinite, symbols[key] != value else { continue }
                symbols[key] = value
                progressed = true
            }
            if !progressed { break }
        }
        return symbols
    }

    /// Lower-cases the identifier tokens in `expr` so a reference resolves against the
    /// lower-cased symbol map (parameter names are case-insensitive). Numbers / operators
    /// pass through unchanged. A token-boundary scan (identifier char = letter/digit/`_`),
    /// mirroring `CADDrawing.expression(_:references:)`'s definition of an identifier.
    private func lowercasedIdentifiers(in expr: String) -> String {
        var out = ""
        out.reserveCapacity(expr.count)
        var inIdent = false
        for ch in expr {
            let isIdent = ch.isLetter || ch.isNumber || ch == "_"
            if isIdent {
                // An identifier STARTS at a letter/underscore; a number is not lowered
                // anyway (Character.lowercased() is a no-op for digits), so a uniform
                // lowercasing of identifier runs is safe and cheap.
                inIdent = true
                out.append(contentsOf: ch.lowercased())
            } else {
                inIdent = false
                out.append(ch)
            }
            _ = inIdent
        }
        return out
    }

    /// Whether the source `expression` references the parameter `name` as a WHOLE-WORD
    /// identifier token (case-insensitive) — so "a" matches `a*2` but not `area`/`data`.
    /// A local twin of the engine's `CADDrawing.expression(_:references:)` (which is
    /// module-internal, so unreachable from the app module); kept byte-equivalent so the
    /// re-solve seeds and the engine's delete-freeze agree on what "references" means.
    private func expression(_ expression: String, references name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let haystack = Array(expression.lowercased())
        let needle = Array(name.lowercased())
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        var i = 0
        while i <= haystack.count - needle.count {
            if Array(haystack[i ..< i + needle.count]) == needle {
                let beforeOK = i == 0 || !isIdentifierChar(haystack[i - 1])
                let afterIdx = i + needle.count
                let afterOK = afterIdx == haystack.count || !isIdentifierChar(haystack[afterIdx])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    /// Evaluates `expr` against `symbols` (lower-cased identifiers) with UNIT CONVERSION
    /// applied for a bare unit-literal (`22mm`). Returns the value in the drawing's unit,
    /// or `nil` on any syntax/name/cycle failure (the caller then keeps the last-good
    /// cache — never writing NaN to the solver).
    private func evaluatedValue(forExpression expr: String, symbols: [String: Double]) -> Double? {
        // A bare unit literal converts directly (no name resolution needed).
        if let converted = unitConvertedLiteral(expr) { return converted }
        return try? ExpressionEvaluator.evaluate(lowercasedIdentifiers(in: expr), symbols: symbols)
    }

    /// If `expr` is a bare top-level numeric literal carrying a UNIT TOKEN (`22mm`,
    /// `-3.5 cm`), returns its magnitude CONVERTED to the drawing's unit (the UNIT BOUNDARY
    /// the pure evaluator deliberately leaves to this app seam). Returns `nil` when `expr`
    /// is not a bare unit literal (a plain number, an expression in parameter terms, or an
    /// unrecognized token) — the caller then evaluates it the ordinary way.
    ///
    /// CONVERSION: the literal's unit token maps to a `DrawingUnit` via
    /// `DrawingUnit(unitToken:)`; the magnitude is converted from that unit to
    /// `drawing.drawingUnit` (`$INSUNITS`) via `factorToMM` (`DrawingUnit.convert`). An
    /// unrecognized token (no `DrawingUnit`) means we can't honor it as a unit, so the
    /// bare MAGNITUDE is returned (better than dropping the value); `none`/`millimeter`
    /// drawings convert by the natural factor.
    private func unitConvertedLiteral(_ expr: String) -> Double? {
        guard let (value, token) = try? ExpressionEvaluator.evaluateLiteralUnit(expr),
              let token, !token.isEmpty else { return nil }
        guard let src = DrawingUnit(unitToken: token) else { return value }   // unknown token → raw
        return DrawingUnit.convert(value, from: src, to: drawing.drawingUnit)
    }

    // MARK: Parameter edit → re-solve funnels (one undo group each)

    /// Creates-or-updates the user parameter `name` with source `expression` AND re-solves
    /// every component its driven constraints touch — ALL in ONE undo group (one ⌘Z reverts
    /// the parameter edit AND the geometry it moved). This is the parametric mirror of
    /// `commitConstraints`: the parameter mutation + the recompute + the geometry re-solve
    /// coalesce into a single undoable step.
    ///
    /// • A new `name` is added (its cached `value` seeded from the freshly-evaluated
    ///   expression, with unit conversion at this seam); an existing one is updated.
    /// • The affected geometry is the connected component of every constraint whose
    ///   expression references `name` (directly, or transitively through another parameter)
    ///   — gathered, then re-solved (the recompute inside `resolveConstraints` refreshes the
    ///   driven `value`s first). On a bad/cyclic expression the geometry is left UNMOVED.
    /// Returns whether the parameter was created/updated (false on an empty name).
    @discardableResult
    func setParameterExpression(name: String, expression: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedExpr = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        // Evaluate the new expression to seed/refresh the parameter's cached value (unit
        // conversion at this seam). On a failure keep 0 / the prior value — never NaN.
        let symbols = currentParameterSymbols()
        let seeded = evaluatedValue(forExpression: trimmedExpr, symbols: symbols)
        let unitToken = (try? ExpressionEvaluator.evaluateLiteralUnit(trimmedExpr).unitToken) ?? nil

        var changed = false
        if let existing = drawing.parameters.parameter(named: trimmedName) {
            var updated = existing
            updated.expression = trimmedExpr
            if let seeded, seeded.isFinite { updated.value = seeded }
            updated.unit = unitToken ?? existing.unit
            changed = drawing.updateParameter(updated)
        } else {
            let value = (seeded?.isFinite == true) ? seeded! : 0
            changed = drawing.addParameter(Parameter(name: trimmedName, expression: trimmedExpr,
                                                     value: value, unit: unitToken))
        }

        // Re-solve every component a constraint driven by this parameter touches (the
        // recompute at the top of `resolveConstraints` refreshes the driven values first).
        resolveConstraints(touching: componentsDriven(byParameterNamed: trimmedName))
        modelDirty = true
        modelVersion &+= 1
        return changed
    }

    /// Sets parameter `name` to a literal `value` (the Parameters-table numeric edit) AND
    /// re-solves the geometry it drives — ONE undo group. A thin wrapper over
    /// `setParameterExpression` that stores the number as the source expression (so the
    /// expression and the cache agree). Returns whether the parameter changed.
    @discardableResult
    func setParameterValue(name: String, value: Double) -> Bool {
        guard value.isFinite else { return false }
        return setParameterExpression(name: name, expression: String(value))
    }

    /// Removes the parameter `name` (FREEZING every referencing constraint to a literal —
    /// the engine's `removeParameter(named:)` does the freeze) AND re-solves the affected
    /// components, ALL in ONE undo group. After the freeze the geometry doesn't actually
    /// move (the frozen literal == the last cache), but the re-solve keeps the seam uniform
    /// and the quadtree in sync. Returns whether a parameter was removed.
    @discardableResult
    func removeParameterAndResolve(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let affected = componentsDriven(byParameterNamed: trimmed)

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        guard drawing.removeParameter(named: trimmed) != nil else { return false }   // undoable freeze
        resolveConstraints(touching: affected)
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// BINDS the existing dimensional constraint `id` to source `expression` (or UNBINDS it
    /// back to a pure literal with `expression: nil`) AND re-solves the geometry — ONE undo
    /// group. The bound constraint's `value` becomes the freshly-evaluated cache of the
    /// expression (unit-converted at this seam); the solver still reads only `value`.
    /// Returns whether the binding changed. No-op (false) for an absent or non-dimensional
    /// constraint.
    @discardableResult
    func setConstraintExpression(id: UUID, expression: String?) -> Bool {
        guard let current = drawing.constraints.constraint(id), current.kind.isDimensional else {
            return false
        }
        let trimmed = expression?.trimmingCharacters(in: .whitespaces)
        let newExpr = (trimmed?.isEmpty == false) ? trimmed : nil

        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        // Compute the bound value: re-evaluate the new expression (keep `value` literal on
        // unbind). On a bad expression keep the current `value` (no NaN).
        var newValue = current.value
        if let newExpr,
           let evaluated = evaluatedValue(forExpression: newExpr,
                                          symbols: currentParameterSymbols()),
           evaluated.isFinite {
            newValue = evaluated
        }
        let bound = current.driven(by: newExpr, value: newValue)
        guard bound != current else { return false }
        drawing.mutateConstraints { $0.replace(bound) }   // undoable
        resolveConstraints(touching: Set(current.entityIDs))
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    /// The name→value parameter symbol map for the CURRENT table (lower-cased keys, unit
    /// conversion applied) — the inputs a fresh expression evaluation needs. A thin public-
    /// to-this-file convenience over `resolvedParameterSymbols`.
    private func currentParameterSymbols() -> [String: Double] {
        resolvedParameterSymbols(drawing.parameters.parameters)
    }

    /// The union of the connected components of every entity touched by a dimensional
    /// constraint whose `expression` references the parameter `name` — DIRECTLY, or
    /// TRANSITIVELY through another parameter (`h = w/2`: editing `w` must re-solve the
    /// `h`-driven constraints too). The set the re-solve seeds when a parameter changes.
    private func componentsDriven(byParameterNamed name: String) -> Set<EntityID> {
        // The transitive closure of parameter names that depend on `name` (so editing `w`
        // pulls `h = w/2`, and anything depending on `h`, …).
        let affectedNames = parameterNamesDepending(on: name)
        var seeds: Set<EntityID> = []
        for c in drawing.constraints.constraints {
            guard let expr = c.expression else { continue }
            if affectedNames.contains(where: { expression(expr, references: $0) }) {
                seeds.formUnion(c.entityIDs)
            }
        }
        // Expand each seed to its full connected component (what the solver solves at once).
        var union = seeds
        for seed in seeds { union.formUnion(drawing.constraints.connectedComponent(of: seed)) }
        return union
    }

    /// The set of parameter names that depend on `name` (transitively), INCLUDING `name`
    /// itself — so a constraint bound to ANY of them is re-solved when `name` changes. A
    /// fixed-point expansion over the parameter table's reference graph (whole-word token
    /// match, case-insensitive, via `CADDrawing.expression(_:references:)`).
    private func parameterNamesDepending(on name: String) -> Set<String> {
        let params = drawing.parameters.parameters
        var affected: Set<String> = [name.lowercased()]
        var changed = true
        while changed {
            changed = false
            for p in params {
                let key = p.name.lowercased()
                guard !affected.contains(key) else { continue }
                if affected.contains(where: { expression(p.expression, references: $0) }) {
                    affected.insert(key)
                    changed = true
                }
            }
        }
        return affected
    }

    // MARK: Create / remove (selection-based; the wire-wave calls these)

    /// Creates a GEOMETRIC constraint of `kind` over `entities` (the current selection),
    /// validating the selection ARITY for the kind, registering it undoably, then
    /// re-solving so it takes effect immediately — all in ONE undo group (the
    /// constraint-add + the resulting geometry move revert together). Returns `false`
    /// (adding nothing) if the arity is wrong for the kind or an entity is missing.
    ///
    /// Arity (matches the solver's `points` ordering in `Constraint`):
    ///   • horizontal / vertical / fix → exactly 1 entity
    ///   • parallel / perpendicular    → exactly 2 entities (treated as lines)
    ///   • coincident                  → exactly 2 entities (their `.start` points pinned)
    ///   • collinear/tangent/equal/concentric/symmetric → rejected (solver-unsupported)
    @discardableResult
    func addConstraint(_ kind: GeometricConstraintKind, entities: [EntityID]) -> Bool {
        // Reset the commit-result handoff so an EARLY arity/kind rejection here (which
        // never reaches `commitConstraints`) doesn't leave a stale `.overConstrained`
        // from a prior call for the selection-apply caller to mis-read.
        lastConstraintCommitResult = .noneAdded
        guard kind.isSolverSupported else { return false }
        guard entities.allSatisfy({ drawing.contains($0) }) else { return false }
        let constraint: Constraint
        switch kind {
        case .horizontal:
            guard entities.count == 1 else { return false }
            constraint = .horizontal(line: entities[0])
        case .vertical:
            guard entities.count == 1 else { return false }
            constraint = .vertical(line: entities[0])
        case .fix:
            guard entities.count == 1 else { return false }
            // Fix the whole entity: both endpoints of a line, else its sole point.
            if case .line = drawing.entity(entities[0])?.kind {
                constraint = .fix(line: entities[0])
            } else {
                constraint = .fix(ConstraintPoint(entityID: entities[0], point: .start))
            }
        case .parallel:
            guard entities.count == 2 else { return false }
            let main = Constraint.parallel(line: entities[0], line: entities[1])
            return commitConstraints(withInferredCorner(main, lineA: entities[0], lineB: entities[1]),
                                     touching: Set(entities)) == .added
        case .perpendicular:
            guard entities.count == 2 else { return false }
            let main = Constraint.perpendicular(line: entities[0], line: entities[1])
            return commitConstraints(withInferredCorner(main, lineA: entities[0], lineB: entities[1]),
                                     touching: Set(entities)) == .added
        case .coincident:
            guard entities.count == 2 else { return false }
            constraint = .coincident(ConstraintPoint(entityID: entities[0], point: .start),
                                     ConstraintPoint(entityID: entities[1], point: .start))
        case .collinear:
            guard entities.count == 2,
                  isLineEntity(entities[0]), isLineEntity(entities[1]) else { return false }
            constraint = .collinear(line: entities[0], line: entities[1])
        case .concentric:
            guard entities.count == 2,
                  hasCenterEntity(entities[0]), hasCenterEntity(entities[1]) else { return false }
            constraint = .concentric(entities[0], entities[1])
        case .equal:
            guard entities.count == 2 else { return false }
            if isLineEntity(entities[0]), isLineEntity(entities[1]) {
                constraint = .equal(line: entities[0], line: entities[1])
            } else if hasRadiusEntity(entities[0]), hasRadiusEntity(entities[1]) {
                constraint = .equal(circle: entities[0], circle: entities[1])
            } else {
                return false   // must be a same-family pair (two lines or two circles/arcs)
            }
        case .tangent, .symmetric:
            return false   // declared but solver-unsupported (Lane B left out of scope)
        }
        return commitConstraint(constraint, touching: Set(entities))
    }

    /// Whether `id` is a LINE entity (for line-family constraints: collinear / equal).
    private func isLineEntity(_ id: EntityID) -> Bool {
        if case .line = drawing.entity(id)?.kind { return true }
        return false
    }

    /// Whether `id` carries a CENTER (circle / arc / ellipse — for concentric).
    private func hasCenterEntity(_ id: EntityID) -> Bool {
        switch drawing.entity(id)?.kind {
        case .circle, .arc, .ellipse: return true
        default:                      return false
        }
    }

    /// Whether `id` carries a single RADIUS (circle / arc — for equal-radius / diameter).
    private func hasRadiusEntity(_ id: EntityID) -> Bool {
        switch drawing.entity(id)?.kind {
        case .circle, .arc: return true
        default:            return false
        }
    }

    /// Creates a DIMENSIONAL constraint of `kind` over `entities` driven to `value`,
    /// validating arity, registering it undoably, then re-solving immediately — all in
    /// ONE undo group. Returns `false` if the arity/value is wrong or unsupported.
    ///
    /// Arity:
    ///   • distance → exactly 2 entities (their `.start` points), a finite `value`
    ///   • radius   → exactly 1 CIRCLE, a finite `value`
    ///   • horizontalDistance/verticalDistance/diameter/angle → rejected (unsupported)
    @discardableResult
    func addConstraint(_ kind: DimensionalConstraintKind, entities: [EntityID],
                       value: Double) -> Bool {
        lastConstraintCommitResult = .noneAdded   // see the geometric overload's note
        guard kind.isSolverSupported, value.isFinite else { return false }
        guard entities.allSatisfy({ drawing.contains($0) }) else { return false }
        let constraint: Constraint
        switch kind {
        case .distance:
            guard entities.count == 2 else { return false }
            constraint = .distance(ConstraintPoint(entityID: entities[0], point: .start),
                                   ConstraintPoint(entityID: entities[1], point: .start),
                                   value: value)
        case .radius:
            guard entities.count == 1 else { return false }
            guard case .circle = drawing.entity(entities[0])?.kind else { return false }
            constraint = .radius(circle: entities[0], value: value)
        case .diameter:
            guard entities.count == 1, hasRadiusEntity(entities[0]) else { return false }
            constraint = .diameter(circle: entities[0], value: value)
        case .angle:
            guard entities.count == 2,
                  isLineEntity(entities[0]), isLineEntity(entities[1]) else { return false }
            constraint = .angle(line: entities[0], line: entities[1], value: value)
        case .horizontalDistance:
            guard entities.count == 2 else { return false }
            constraint = .horizontalDistance(ConstraintPoint(entityID: entities[0], point: .start),
                                             ConstraintPoint(entityID: entities[1], point: .start),
                                             value: value)
        case .verticalDistance:
            guard entities.count == 2 else { return false }
            constraint = .verticalDistance(ConstraintPoint(entityID: entities[0], point: .start),
                                           ConstraintPoint(entityID: entities[1], point: .start),
                                           value: value)
        }
        return commitConstraint(constraint, touching: Set(entities))
    }

    /// AUTO-BIND: creates a DIMENSIONAL constraint of `kind` over `entities` already BOUND
    /// to the parameter-driving `expression` (the constraint's `value` is the freshly-
    /// evaluated cache of that expression, unit-converted at this seam) — validating arity,
    /// registering it undoably, then re-solving immediately, ALL in ONE undo group. This is
    /// what the `name=value` command-line route calls when a dimensional constraint is in
    /// flight on the selection: the constraint is created driven by the parameter rather
    /// than a frozen literal, so editing the parameter later moves the geometry.
    ///
    /// The `expression` is evaluated against the CURRENT parameter table (so it can be the
    /// just-created parameter's name, or any expression in parameter terms). On an
    /// unevaluable expression the constraint is NOT created (returns `false`) — a bound
    /// dimension must have a real driven value, never NaN.
    ///
    /// Arity matches the value overload (distance → 2 entities; radius → 1 circle).
    @discardableResult
    func addConstraint(_ kind: DimensionalConstraintKind, entities: [EntityID],
                       expression: String) -> Bool {
        lastConstraintCommitResult = .noneAdded   // see the value overload's note
        guard kind.isSolverSupported else { return false }
        guard entities.allSatisfy({ drawing.contains($0) }) else { return false }
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let value = evaluatedValue(forExpression: trimmed, symbols: currentParameterSymbols()),
              value.isFinite else { return false }

        let constraint: Constraint
        switch kind {
        case .distance:
            guard entities.count == 2 else { return false }
            constraint = .distance(ConstraintPoint(entityID: entities[0], point: .start),
                                   ConstraintPoint(entityID: entities[1], point: .start),
                                   expression: trimmed, value: value)
        case .radius:
            guard entities.count == 1 else { return false }
            guard case .circle = drawing.entity(entities[0])?.kind else { return false }
            constraint = .radius(circle: entities[0], expression: trimmed, value: value)
        case .horizontalDistance, .verticalDistance, .diameter, .angle:
            // Now solver-supported (Lane B), but NOT parameter-driven via this seam yet
            // (no UI authors a bound expression for them). The value overload above
            // handles them by locking the current measured value.
            return false
        }
        return commitConstraint(constraint, touching: Set(entities))
    }

    /// The outcome of a manual constraint commit (`commitConstraints`): the constraint(s)
    /// were ADDED and the geometry enforces them, or the add was REJECTED because it would
    /// over-constrain a touched component (a clean no-op — nothing left in the table). The
    /// selection-apply callers map `.added` → success and surface a clear message for
    /// `.overConstrained`, so a manual constraint that can't be honored is never left as a
    /// dangling badge on un-enforced geometry.
    enum ConstraintCommitResult: Equatable {
        /// The constraint(s) were registered and the geometry now satisfies them.
        case added
        /// Nothing was added (empty list, or the table rejected every id).
        case noneAdded
        /// The add was ROLLED BACK because it left a touched component `.failed`
        /// (over-constrained / conflicting). The drawing is exactly as before the call.
        case overConstrained
    }

    /// Registers `constraint` undoably AND re-solves the geometry it now constrains, in
    /// ONE undo group (a single ⌘Z reverts both the add and any geometry it moved).
    /// Returns whether the constraint was added (false on a rejected over-constrained add).
    @discardableResult
    private func commitConstraint(_ constraint: Constraint, touching ids: Set<EntityID>) -> Bool {
        commitConstraints([constraint], touching: ids) == .added
    }

    /// Registers EVERY constraint in `constraints` undoably (in order) AND re-solves the
    /// geometry they now constrain, ALL in ONE undo group — a single ⌘Z reverts every
    /// add AND any geometry the combined re-solve moved. This is the generalized tail of
    /// the `addConstraint` overloads: a single explicit constraint commits as a one-element
    /// list, while the perpendicular/parallel create path commits the user's main
    /// constraint TOGETHER with its auto-inferred hidden coincident companion so they
    /// re-solve ONCE as one undoable step (the corner stays joined as the angle rotates).
    ///
    /// OVER-CONSTRAINT ROLLBACK (the manual-apply mirror of `tentativelyAdd`'s auto
    /// rollback): after re-solving, if any touched component is left `.failed`
    /// (over-constrained / conflicting / non-convergent), the just-added constraint(s) are
    /// REMOVED within the SAME undo group and the components re-solved from the reverted
    /// table — so a manual constraint that can't be honored is a clean no-op (`.overConstrained`)
    /// instead of a dangling badge on un-enforced geometry. A normally-solvable add (a
    /// single H on a free line, a partial set the min-displacement regularizer satisfies)
    /// is NOT rejected — only a genuinely `.failed` component is. Returns `.added` when the
    /// constraint(s) hold, `.overConstrained` on a rolled-back add, or `.noneAdded` on an
    /// empty list / a table that rejected every id.
    @discardableResult
    private func commitConstraints(_ constraints: [Constraint],
                                   touching ids: Set<EntityID>) -> ConstraintCommitResult {
        guard !constraints.isEmpty else {
            lastConstraintCommitResult = .noneAdded; return .noneAdded
        }
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        var added: [Constraint] = []
        for constraint in constraints {
            if drawing.addConstraint(constraint) { added.append(constraint) }   // undoable
        }
        guard !added.isEmpty else {
            lastConstraintCommitResult = .noneAdded; return .noneAdded
        }
        resolveConstraints(touching: ids)   // apply ALL once, same undo group

        // OVER-CONSTRAINT GUARD: if the add left a touched component `.failed`, the
        // geometry does NOT honor it — roll the add back (same undo group) so we never
        // leave a dangling badge on un-enforced geometry, and report it to the caller.
        if !touchedComponentsAllSolve(seeds: ids) {
            for constraint in added { drawing.removeConstraint(constraint.id) }   // undoable
            // Re-solve from the reverted (smaller) table so any motion the rejected add
            // caused is undone and the unsatisfied-tracking is refreshed for what REMAINS.
            resolveConstraints(touching: ids)
            // Drop the just-removed ids from the unsatisfied set explicitly: the re-solve
            // above only `subtract`s constraints STILL in the component, so the rolled-back
            // ones (gone from the table) would otherwise linger flagged.
            unsatisfiedConstraintIDs.subtract(added.map(\.id))
            modelDirty = true
            modelVersion &+= 1
            lastConstraintCommitResult = .overConstrained
            return .overConstrained
        }

        modelDirty = true
        modelVersion &+= 1
        lastConstraintCommitResult = .added
        return .added
    }

    // MARK: Inferred coincidence (AutoCAD-style hidden corner coincident)

    /// Returns the constraint list to commit for a perpendicular/parallel applied to two
    /// LINES: the user's `main` constraint, plus — when the two lines meet at a shared
    /// CORNER — a HIDDEN, auto-inferred coincident pinning that endpoint pair together.
    ///
    /// WHY: a bare perpendicular/parallel constrains only the ANGLE; nothing holds the
    /// shared end together, so applying it to a hand-drawn corner rotates the lines and
    /// the ends DRIFT APART. AutoCAD's "inferred coincidence" auto-adds the (hidden)
    /// coincident at the corner so it stays joined as the angle constraint rotates the
    /// pair. The companion solves exactly like an explicit coincident — only the glyph
    /// overlay treats it as hidden.
    ///
    /// Returns `[main]` (no companion) when: an entity isn't a line; the lines don't share
    /// an essentially-touching corner (see `nearestCornerPair`); or a coincident already
    /// binds that endpoint pair (don't duplicate). Returns `[main, inferred]` otherwise.
    private func withInferredCorner(_ main: Constraint,
                                    lineA: EntityID, lineB: EntityID) -> [Constraint] {
        guard case .line(let a)? = drawing.entity(lineA)?.kind,
              case .line(let b)? = drawing.entity(lineB)?.kind else { return [main] }
        guard let (pa, pb) = Self.nearestCornerPair(lineA: lineA, a: a, lineB: lineB, b: b)
        else { return [main] }
        // Don't duplicate an existing coincident already binding this exact pair.
        guard !coincidentExists(pa, pb) else { return [main] }
        return [main, .coincidentInferred(pa, pb)]
    }

    /// The nearest START/END pair between two lines, IF they form an essentially-touching
    /// CORNER. Of the 4 endpoint combos (start/end of A × start/end of B) it picks the
    /// closest, and treats it as a corner only when the gap is within
    /// `max(1e-6, 1e-3 · min(lenA, lenB))` — a snapped / already-touching corner. Lines
    /// that merely cross or sit far apart get NO companion (we never JOIN far-apart lines).
    /// Returns the two `ConstraintPoint`s to pin, or `nil` when there is no such corner
    /// (or either line is degenerate / zero-length).
    static func nearestCornerPair(lineA: EntityID, a: LineData,
                                  lineB: EntityID, b: LineData)
        -> (ConstraintPoint, ConstraintPoint)? {
        let lenA = a.start.distance(to: a.end)
        let lenB = b.start.distance(to: b.end)
        guard lenA > 0, lenB > 0 else { return nil }   // degenerate line → no corner
        let tol = max(1e-6, 1e-3 * min(lenA, lenB))

        let combos: [(EntityPoint, Vector, EntityPoint, Vector)] = [
            (.start, a.start, .start, b.start),
            (.start, a.start, .end,   b.end),
            (.end,   a.end,   .start, b.start),
            (.end,   a.end,   .end,   b.end),
        ]
        var best: (EntityPoint, EntityPoint, Double)? = nil
        for (pa, va, pb, vb) in combos {
            let d = va.distance(to: vb)
            if best == nil || d < best!.2 { best = (pa, pb, d) }
        }
        guard let (pa, pb, gap) = best, gap <= tol else { return nil }
        return (ConstraintPoint(entityID: lineA, point: pa),
                ConstraintPoint(entityID: lineB, point: pb))
    }

    /// Whether a COINCIDENT constraint already binds the endpoint pair {`pa`, `pb`}
    /// (either order). Avoids stacking a redundant inferred coincident on a corner the
    /// user already pinned explicitly.
    private func coincidentExists(_ pa: ConstraintPoint, _ pb: ConstraintPoint) -> Bool {
        drawing.constraints.constraints.contains { c in
            guard case .geometric(.coincident) = c.kind, c.points.count == 2 else { return false }
            let p0 = c.points[0], p1 = c.points[1]
            return (p0 == pa && p1 == pb) || (p0 == pb && p1 == pa)
        }
    }

    // MARK: - AutoConstrain on draw (AutoCAD AutoConstrain — Lane A)
    //
    // The OWNER'S #1 ask + the cure for "the rectangle falls apart": when the user
    // DRAWS lines, automatically add VISIBLE constraints — weld touching corners with a
    // COINCIDENT (the real fix: a perpendicular alone only pins the ANGLE, so the corner
    // drifts when a grip is dragged), and infer the obvious angular relationship
    // (HORIZONTAL / VERTICAL / PERPENDICULAR / PARALLEL). This runs at the single
    // draw-commit choke point (`applyCommit`'s `.add` arm) so EVERY draw path (the live
    // LineTool chain, the inline-text funnel, a future polyline tool) flows through it.
    //
    // SCOPE — LINES ONLY. The MVP `ConstraintSolver` parametrizes `.line`/`.circle`/
    // `.point`; a POLYLINE endpoint does NOT resolve (`VariableLayout.resolvesPosition`
    // returns false for it), so a constraint touching a polyline poisons its whole
    // component to `.failed`. Welding polyline vertices therefore needs SOLVER work
    // (CADEngine, NOT this lane's `CanvasModel`); auto-constrain skips polylines here and
    // that capability is flagged as a follow-up rather than silently mis-welding.
    //
    // NEVER OVER-CONSTRAIN. Each inferred constraint is added TENTATIVELY and re-solved
    // through the existing commit-with-resolve path; if the solve `.failed` OR moved the
    // just-drawn geometry beyond tolerance, the constraint is REMOVED and we move on.
    // Coincident welds are added FIRST (they are the cure and rarely conflict); the
    // angular constraint is the one most likely to be dropped on a closed loop. All of
    // this lands in the SAME undo group as the draw (the caller's `applyCommit` group is
    // still open), so one ⌘Z reverts the draw AND its auto-constraints together.

    /// `@AppStorage`/`UserDefaults` key gating AutoConstrain-on-draw. DEFAULTS TO ON
    /// (the key is absent until a settings sheet first writes it; a missing value reads
    /// as ON via the object-first read in `seedAutoConstrainFromAppSettings`). Lane D's
    /// settings sheet binds an `@AppStorage(CanvasModel.autoConstrainOnDrawKey)` to the
    /// SAME literal key. Lives here (a file this lane owns) beside the model's other
    /// behavior flags; mirrors `CADCanvasController.showConstraintsKey`'s literal-key style.
    static let autoConstrainOnDrawKey = "draw.autoConstrainOnDraw"

    /// Angular tolerance (radians) for INFERRING an angular constraint — a segment within
    /// this of an axis (H/V) or of 90°/0° to a connected neighbor (perpendicular/parallel)
    /// gets that constraint. ~1° — generous enough for a hand-drawn "roughly square"
    /// corner, tight enough not to mis-classify a deliberate slant.
    static let autoConstrainAngleTolerance = 1.0 * .pi / 180.0

    /// World-distance tolerance for WELDING two endpoints with a coincident. The dominant
    /// draw paths land touching corners EXACTLY (the LineTool chains by copying the prior
    /// `end` into the next `start`; an endpoint-snapped pick returns the exact endpoint),
    /// so a small absolute tolerance catches every "drawn connected" corner without ever
    /// joining lines that merely sit near each other. Absolute world units (NOT the old
    /// `1e-3 · len` relative epsilon, which was too tight for a 10u line and too loose for
    /// a 0.01u one) and NOT the view-scaled snap aperture (this seam has no live zoom).
    static let autoConstrainWeldTolerance = 1.0e-6

    /// LIVE AutoConstrain-on-draw flag, read at the `applyCommit` seam. Seeded ON from
    /// `autoConstrainOnDrawKey` at init; a unit test flips this directly (no `UserDefaults`
    /// touch). `@ObservationIgnored`: pure behavior state, never rendered.
    @ObservationIgnored
    var autoConstrainOnDraw: Bool = (UserDefaults.standard.object(forKey: CanvasModel.autoConstrainOnDrawKey) as? Bool) ?? true

    /// Re-seeds `autoConstrainOnDraw` from a (possibly isolated) defaults store — the
    /// hermetic seam mirroring `seedSnapSettingsFromAppSettings`. Production reads
    /// `.standard` at init; a test seeds from its own suite without polluting `.standard`.
    func seedAutoConstrainFromAppSettings(defaults: UserDefaults = .standard) {
        autoConstrainOnDraw = (defaults.object(forKey: Self.autoConstrainOnDrawKey) as? Bool) ?? true
    }

    /// AUTO-CONSTRAIN the freshly-committed LINE entities `newLineIDs`: weld each of their
    /// endpoints to a coincident EXISTING line endpoint (within `autoConstrainWeldTolerance`),
    /// then infer ONE angular constraint per new line. Runs INSIDE the caller's open undo
    /// group (the draw + its constraints are one ⌘Z) and is a no-op when the toggle is off.
    ///
    /// Welds first (the cure — they pin corners so an angular re-solve / later grip drag
    /// keeps the corner joined), each tentatively (drop on a `.failed` solve or a beyond-
    /// tolerance move). Then one angular constraint per line, same tentative discipline.
    /// `coincidentExists` / a duplicate-id table guard keep it idempotent.
    private func autoConstrain(newLineIDs: [EntityID]) {
        guard autoConstrainOnDraw, !newLineIDs.isEmpty else { return }

        // (1) WELD: for each endpoint of each new line, find the nearest EXISTING line
        //     endpoint within the weld tolerance and pin them coincident. "Existing" =
        //     any OTHER line in the drawing (including an earlier sibling in this same
        //     multi-segment commit, since each was already `drawing.add`ed before this
        //     pass runs — so a chained polyline-of-lines welds segment-to-segment too).
        for newID in newLineIDs {
            guard case .line(let nd)? = drawing.entity(newID)?.kind else { continue }
            for newPoint in [EntityPoint.start, .end] {
                let v = (newPoint == .start) ? nd.start : nd.end
                guard let match = nearestExistingLineEndpoint(to: v, excluding: newID) else { continue }
                let pa = ConstraintPoint(entityID: newID, point: newPoint)
                let pb = match
                guard !coincidentExists(pa, pb) else { continue }
                tentativelyAdd(.coincident(pa, pb), seeds: [newID, pb.entityID])
            }
        }

        // (2) ANGLE: one inferred angular constraint per new line, in priority order.
        for newID in newLineIDs {
            addInferredAngularConstraint(for: newID)
        }
    }

    /// The nearest START/END of an EXISTING line (anything but `excluding`) to world point
    /// `v`, within `autoConstrainWeldTolerance`, or `nil`. Ties resolve to the closest;
    /// only `.line` entities are considered (the solver-weldable endpoint kind).
    ///
    /// TODO(perf): linear scan over `drawing.entities`. Fine for the single-segment
    /// LineTool path (one or two new lines per commit); for a future BULK / multi-segment
    /// polyline-draw path, query the quadtree by the tiny weld-tolerance box around `v`.
    private func nearestExistingLineEndpoint(to v: Vector,
                                             excluding: EntityID) -> ConstraintPoint? {
        var best: (ConstraintPoint, Double)? = nil
        for rec in drawing.entities where rec.id != excluding {
            guard case .line(let d) = rec.kind else { continue }
            for (pt, w) in [(EntityPoint.start, d.start), (.end, d.end)] {
                let dist = v.distance(to: w)
                guard dist <= Self.autoConstrainWeldTolerance else { continue }
                if best == nil || dist < best!.1 {
                    best = (ConstraintPoint(entityID: rec.id, point: pt), dist)
                }
            }
        }
        return best?.0
    }

    /// Infers ONE angular constraint for the new line `newID`, in PRIORITY order:
    ///   1. HORIZONTAL  — segment ~axis-aligned to 0°/180°.
    ///   2. VERTICAL    — segment ~axis-aligned to 90°/270°.
    ///   3. PERPENDICULAR — to a COINCIDENT-connected neighbor line at ~90°.
    ///   4. PARALLEL      — to a coincident-connected neighbor line at ~0°/180°.
    /// At most one is added; each is tentative (dropped on over-constraint). H/V come
    /// first because they pin the line to the WORLD frame (the strongest intent); the
    /// relational ones only fire when the absolute ones don't and a welded neighbor exists.
    private func addInferredAngularConstraint(for newID: EntityID) {
        guard case .line(let d)? = drawing.entity(newID)?.kind else { return }
        let len = d.start.distance(to: d.end)
        guard len > Tolerance.distance else { return }   // degenerate: no direction
        let tol = Self.autoConstrainAngleTolerance
        let theta = (d.end - d.start).angle               // [0, 2π)

        // 1 + 2: axis alignment (mod π — a segment and its reverse are the same line).
        let angMod = theta.truncatingRemainder(dividingBy: .pi)        // [0, π)
        if Self.angleNear(angMod, 0, tol: tol) || Self.angleNear(angMod, .pi, tol: tol) {
            tentativelyAdd(.horizontal(line: newID), seeds: [newID]); return
        }
        if Self.angleNear(angMod, .pi / 2, tol: tol) {
            tentativelyAdd(.vertical(line: newID), seeds: [newID]); return
        }

        // 3 + 4: relational to a COINCIDENT-connected neighbor line. Only neighbors the
        // weld pass (or a prior corner) actually joined to `newID` qualify — we never
        // relate two lines that don't share a corner.
        for neighborID in coincidentNeighborLines(of: newID) {
            guard case .line(let n)? = drawing.entity(neighborID)?.kind else { continue }
            let nLen = n.start.distance(to: n.end)
            guard nLen > Tolerance.distance else { continue }
            let nTheta = (n.end - n.start).angle
            let between = Self.acuteAngleBetween(theta, nTheta)        // [0, π/2]
            if Self.angleNear(between, .pi / 2, tol: tol) {
                tentativelyAdd(.perpendicular(line: newID, line: neighborID),
                               seeds: [newID, neighborID]); return
            }
            if Self.angleNear(between, 0, tol: tol) {
                tentativelyAdd(.parallel(line: newID, line: neighborID),
                               seeds: [newID, neighborID]); return
            }
        }
    }

    /// The OTHER line ids joined to `id` by a COINCIDENT constraint (the corners the weld
    /// pass — or a prior explicit coincident — pinned). Order is table order (stable).
    private func coincidentNeighborLines(of id: EntityID) -> [EntityID] {
        var out: [EntityID] = []
        var seen = Set<EntityID>([id])
        for c in drawing.constraints.constraints {
            guard case .geometric(.coincident) = c.kind, c.references(id) else { continue }
            for other in c.entityIDs where seen.insert(other).inserted {
                if case .line? = drawing.entity(other)?.kind { out.append(other) }
            }
        }
        return out
    }

    /// Adds `constraint` TENTATIVELY: register it, re-solve the components it touches, and
    /// KEEP it only if the solve succeeded AND moved the seed geometry within tolerance;
    /// otherwise REMOVE it (so an over/under-constrained add leaves the drawing exactly as
    /// it was — the AutoCAD "don't over-constrain" rule). Runs in the caller's open undo
    /// group. The `seeds` are the entities whose geometry must STAY PUT (the freshly drawn
    /// line + any welded neighbor) — if a tentative angular constraint would splay them we
    /// drop it. Returns whether the constraint was kept.
    @discardableResult
    private func tentativelyAdd(_ constraint: Constraint, seeds: Set<EntityID>) -> Bool {
        // Snapshot the seed geometry so we can both detect a beyond-tolerance move and
        // confirm the table actually accepted the add.
        let before = seeds.reduce(into: [EntityID: EntityKind]()) { acc, id in
            if let k = drawing.entity(id)?.kind { acc[id] = k }
        }
        // `addConstraint` keys on the constraint's fresh UUID, so it never rejects here on
        // a duplicate (semantic weld-dedup is upstream via `coincidentExists`); the guard
        // only defends the unreachable false (a UUID collision) — nothing to do then.
        guard drawing.addConstraint(constraint) else { return false }

        // Re-solve every component the constraint now touches. A `.failed` component
        // writes nothing (clean revert) — but a constraint that POISONED a component to
        // `.failed` must still be removed so it doesn't break the NEXT grip-drag re-solve.
        let solveOK = resolveConstraints(touching: seeds)
        _ = solveOK   // re-solve already applied any satisfiable motion; we verify below.

        // KEEP only if the constraint is still satisfiable AND the seeds didn't splay.
        if autoConstraintIsAcceptable(constraint, seeds: seeds, before: before) {
            return true
        }
        drawing.removeConstraint(constraint.id)   // undoable; revert the tentative add
        // Re-solve once more so any motion the rejected add caused is undone (the now-
        // smaller constraint set re-satisfies the rest from the reverted geometry).
        _ = resolveConstraints(touching: seeds)
        // Drop the reverted constraint's id from the unsatisfied set: the re-solve above
        // only `subtract`s ids STILL in a component, so a poisoning add that briefly
        // flagged the component would otherwise leave its (now-removed) id lingering.
        unsatisfiedConstraintIDs.remove(constraint.id)
        return false
    }

    /// Whether EVERY connected component touched by a seed in `seeds` solves cleanly —
    /// no `.failed` (over-constrained / non-convergent / unsupported) and no non-finite
    /// geometry. The shared acceptability core of BOTH the auto-constrain rollback
    /// (`autoConstraintIsAcceptable` part a) and the MANUAL constraint-apply rollback
    /// (`commitConstraints`): a constraint whose add leaves a touched component `.failed`
    /// is unacceptable and must be rolled back rather than left as a dangling badge on
    /// un-enforced geometry. Empty `seeds`, or a component with no constraints, is
    /// trivially OK.
    private func touchedComponentsAllSolve(seeds: Set<EntityID>) -> Bool {
        for seed in seeds {
            let component = drawing.constraints.connectedComponent(of: seed)
            var ents: [EntityID: EntityKind] = [:]
            for id in component { if let k = drawing.entity(id)?.kind { ents[id] = k } }
            let cons = drawing.constraints.constraints(within: component)
            guard !cons.isEmpty else { continue }
            switch ConstraintSolver.solve(entities: ents, constraints: cons) {
            case .failed:
                return false
            case .solved:
                break
            }
        }
        for id in seeds {
            if let k = drawing.entity(id)?.kind, !Self.kindIsFinite(k) { return false }
        }
        return true
    }

    /// Whether a just-added auto-constraint should be KEPT: its connected components must
    /// all still SOLVE (no `.failed`), no seed may have gone NaN, and the seed geometry
    /// must not have moved beyond a generous tolerance from its pre-add state. A COINCIDENT
    /// weld is always acceptable when it solves (welding is the whole point — it is allowed
    /// to translate the new line onto the corner); only ANGULAR constraints are held to the
    /// "didn't splay the seeds" bar.
    private func autoConstraintIsAcceptable(_ constraint: Constraint,
                                            seeds: Set<EntityID>,
                                            before: [EntityID: EntityKind]) -> Bool {
        // (a) Every component touching a seed must SOLVE, and no geometry may be non-finite.
        guard touchedComponentsAllSolve(seeds: seeds) else { return false }

        // (b) A coincident weld is always kept when it solves (it may legitimately move
        //     the new line onto the corner). An ANGULAR constraint must NOT have SPLAYED
        //     the seeds — guard against an over-constraint that warps the drawing.
        if case .geometric(.coincident) = constraint.kind { return true }

        // The move-bound is RELATIVE to the geometry scale: snapping a near-axis / near-
        // square segment is a rotation of at most the angle tolerance, so a seed endpoint
        // moves by at most ~`L · sin(angleTol)`. We allow a generous multiple of that
        // (rotation can pivot about the far end, doubling the near-end travel, and a welded
        // neighbor may co-rotate) plus a tiny absolute floor for degenerate-length seeds.
        // A move BEYOND this means the add fought another constraint and warped the drawing
        // — drop it. The bound is computed from the LARGEST seed line so both the new line
        // and its neighbor are covered by one threshold.
        var maxSeedLen = 0.0
        for (_, oldKind) in before {
            if case .line(let l) = oldKind { maxSeedLen = Swift.max(maxSeedLen, l.start.distance(to: l.end)) }
        }
        let moveBound = Swift.max(Self.autoConstrainMinAngularMove,
                                  maxSeedLen * sin(Self.autoConstrainAngleTolerance)
                                      * Self.autoConstrainMoveSlack)
        for (id, oldKind) in before {
            guard let newKind = drawing.entity(id)?.kind else { return false }
            if Self.maxEndpointShift(oldKind, newKind) > moveBound { return false }
        }
        return true
    }

    /// Headroom multiplier on the `L · sin(angleTol)` expected endpoint travel when judging
    /// whether an inferred ANGULAR constraint SPLAYED its seeds. A rotation can pivot about
    /// the far endpoint (so the near endpoint travels up to ~2× the half-rotation arc) and a
    /// welded neighbor may co-rotate, so we allow several × the nominal travel before
    /// declaring the add an over-constraint and dropping it.
    static let autoConstrainMoveSlack = 4.0

    /// Absolute floor on the angular move-bound, so a tiny / degenerate-length seed (whose
    /// `L · sin(angleTol)` term is ~0) still tolerates float round-off from the re-solve.
    static let autoConstrainMinAngularMove = 1.0e-6

    /// Whether every coordinate of an entity kind is finite (a guard against an NaN/∞
    /// solver result leaking into the drawing). Only the auto-weldable/solvable kinds
    /// (line / circle / point) carry seed geometry here; anything else is trivially finite.
    private static func kindIsFinite(_ k: EntityKind) -> Bool {
        switch k {
        case .line(let d):
            return d.start.x.isFinite && d.start.y.isFinite && d.end.x.isFinite && d.end.y.isFinite
        case .circle(let d):
            return d.center.x.isFinite && d.center.y.isFinite && d.radius.isFinite
        case .point(let d):
            return d.position.x.isFinite && d.position.y.isFinite
        default:
            return true
        }
    }

    /// The largest endpoint displacement between two LINE geometries (∞ if either side
    /// isn't a line / they don't correspond) — the "did this constraint splay the seed"
    /// metric. Compares start↔start and end↔end (auto-constraints never reorder endpoints).
    private static func maxEndpointShift(_ a: EntityKind, _ b: EntityKind) -> Double {
        guard case .line(let la) = a, case .line(let lb) = b else { return 0 }
        return Swift.max(la.start.distance(to: lb.start), la.end.distance(to: lb.end))
    }

    /// Whether two angles (radians) are within `tol` of each other.
    static func angleNear(_ x: Double, _ y: Double, tol: Double) -> Bool {
        abs(x - y) <= tol
    }

    /// The ACUTE angle (in [0, π/2]) between two line directions `t1`, `t2` (radians) —
    /// direction-agnostic (a line and its reverse are the same), so it folds the raw
    /// difference into [0, π/2]. 0 ⇒ parallel, π/2 ⇒ perpendicular.
    static func acuteAngleBetween(_ t1: Double, _ t2: Double) -> Double {
        var d = abs(t1 - t2).truncatingRemainder(dividingBy: .pi)   // [0, π)
        if d > .pi / 2 { d = .pi - d }                              // fold to [0, π/2]
        return d
    }

    /// Removes the constraint with `id` (undoable). The geometry it WAS holding is left
    /// where it is (removing a constraint frees DOFs but doesn't move anything) — the
    /// engine-level undoable `removeConstraint`. Returns whether a constraint was removed.
    @discardableResult
    func removeConstraint(id: UUID) -> Bool {
        // One undo step for the removal (same `explicitGroup` rationale as the other
        // funnels: groups-by-event in the live app, explicit group under tests so the
        // engine's `registerUndo` always has an open group to register into).
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }
        guard drawing.removeConstraint(id) else { return false }   // undoable
        // The removed constraint can no longer be unsatisfied — drop it from the tracking
        // set (a subsequent re-solve only `subtract`s ids STILL in a component, so a
        // removed one would otherwise linger flagged). Removing it also FREES DOFs, so a
        // previously over-constrained sibling may now solve; the next re-solve (grip /
        // inspector edit, or the panel's redraw path) clears those ids when it runs.
        unsatisfiedConstraintIDs.remove(id)
        modelDirty = true
        modelVersion &+= 1
        return true
    }

    // MARK: Read accessors (the Inspector / overlay query these)

    /// Every constraint that references `entityID`, in table order (for an Inspector
    /// "constraints on this entity" list and the glyph overlay's per-entity badge).
    func constraints(for entityID: EntityID) -> [Constraint] {
        drawing.constraints.referencing(entityID)
    }

    /// The whole constraint list, in stable insertion order (the overlay iterates this).
    var allConstraints: [Constraint] {
        drawing.constraints.constraints
    }

    // MARK: - Wire-wave 2 — selection-driven constraint creation (Constrain menu / ⌘K)
    //
    // The Constrain menu (LibreCADApp) + ⌘K palette call these on the CURRENT
    // selection. They turn the selection `Set` into a STABLE-ordered entity list
    // (by draw order, so a 2-entity constraint is reproducible run-to-run) and
    // forward to the engine `addConstraint` funnels above (arity-validated, undoable,
    // re-solved immediately as ONE undo group). On an arity failure they post a status
    // message instead of crashing (the menu can stay enabled; the verb is a safe
    // no-op). DIMENSIONAL constraints LOCK THE CURRENT MEASURED VALUE (the present
    // distance/radius computed from the live geometry) — no modal prompt this wave
    // (editing the driven value is a deferred follow-up).

    /// The current selection's entity ids in STABLE draw order (the order they appear
    /// in `drawing.entities`), so a two-entity constraint built from the selection is
    /// reproducible regardless of `Set` iteration order. Block members are not special-
    /// cased here (a constraint references whatever the user selected).
    var orderedSelectionIDs: [EntityID] {
        let selected = selection.ids
        guard !selected.isEmpty else { return [] }
        return drawing.entities.map(\.id).filter { selected.contains($0) }
    }

    /// Applies a GEOMETRIC constraint of `kind` to the CURRENT SELECTION (the Constrain
    /// menu / ⌘K entry point). Returns whether it was added; on an arity/kind failure it
    /// posts a status message and returns `false` (no crash, no mutation).
    @discardableResult
    func applyGeometricConstraintToSelection(_ kind: GeometricConstraintKind) -> Bool {
        let ids = orderedSelectionIDs
        guard addConstraint(kind, entities: ids) else {
            // Distinguish an OVER-CONSTRAINED rollback (the add was arity-valid but the
            // solver couldn't honor it, so it was reverted) from a plain arity failure —
            // each gets a message that tells the user how to fix it.
            if lastConstraintCommitResult == .overConstrained {
                flashStatus(Self.overConstrainedMessage(geometric: kind))
            } else {
                flashStatus(Self.constraintFailureMessage(geometric: kind, count: ids.count))
            }
            return false
        }
        return true
    }

    /// Applies a DIMENSIONAL constraint of `kind` to the CURRENT SELECTION, LOCKING the
    /// value currently measured from the selected geometry (distance between the two
    /// selected entities' `.start` points; the selected circle's radius). No modal — the
    /// present value is captured and driven. Returns whether it was added; on an arity/
    /// kind failure it posts a status message and returns `false`.
    @discardableResult
    func applyDimensionalConstraintToSelection(_ kind: DimensionalConstraintKind) -> Bool {
        let ids = orderedSelectionIDs
        guard let value = currentDimensionalValue(kind, entities: ids),
              addConstraint(kind, entities: ids, value: value) else {
            // An OVER-CONSTRAINED rollback gets the "would conflict" message; everything
            // else (bad arity, wrong kind) the arity message.
            if lastConstraintCommitResult == .overConstrained {
                flashStatus(Self.overConstrainedMessage(dimensional: kind))
            } else {
                flashStatus(Self.constraintFailureMessage(dimensional: kind, count: ids.count))
            }
            return false
        }
        return true
    }

    /// The value to LOCK for a dimensional constraint of `kind` over `entities`, measured
    /// from the live geometry RIGHT NOW (so applying the constraint pins the shape exactly
    /// where it already is). Returns `nil` when the selection arity / kind is wrong, so the
    /// caller rejects it (and the engine funnel would too).
    ///
    ///  • distance → 2 entities; the gap between their `.start` points (line start / point
    ///    position / circle center).
    ///  • radius   → 1 CIRCLE; its current radius.
    private func currentDimensionalValue(_ kind: DimensionalConstraintKind,
                                         entities: [EntityID]) -> Double? {
        switch kind {
        case .distance:
            guard entities.count == 2,
                  let a = startPoint(of: entities[0]),
                  let b = startPoint(of: entities[1]) else { return nil }
            return a.distance(to: b)
        case .radius:
            guard entities.count == 1,
                  case .circle(let c)? = drawing.entity(entities[0])?.kind else { return nil }
            return c.radius
        case .diameter:
            // 2·r of a circle OR arc — the present diameter.
            guard entities.count == 1, let r = circularRadius(of: entities[0]) else { return nil }
            return 2.0 * r
        case .angle:
            // The present included angle (radians) between the two selected lines.
            guard entities.count == 2,
                  let a = lineDirectionAngle(of: entities[0]),
                  let b = lineDirectionAngle(of: entities[1]) else { return nil }
            return a - b
        case .horizontalDistance:
            // Present Δx between the two `.start` points.
            guard entities.count == 2,
                  let a = startPoint(of: entities[0]),
                  let b = startPoint(of: entities[1]) else { return nil }
            return b.x - a.x
        case .verticalDistance:
            // Present Δy between the two `.start` points.
            guard entities.count == 2,
                  let a = startPoint(of: entities[0]),
                  let b = startPoint(of: entities[1]) else { return nil }
            return b.y - a.y
        }
    }

    /// The direction angle (radians, `atan2(Δy, Δx)`) of a line entity's start→end
    /// vector, or `nil` if `id` is not a line. Mirrors how the solver derives θ for the
    /// `angle` constraint (so locking the current value pins the present geometry).
    private func lineDirectionAngle(of id: EntityID) -> Double? {
        guard case .line(let l)? = drawing.entity(id)?.kind else { return nil }
        return atan2(l.end.y - l.start.y, l.end.x - l.start.x)
    }

    /// The radius of a circle OR an arc, or `nil` for any other kind. Backs the diameter
    /// constraint's current-value lock.
    private func circularRadius(of id: EntityID) -> Double? {
        switch drawing.entity(id)?.kind {
        case .circle(let c): return c.radius
        case .arc(let a):    return a.radius
        default:             return nil
        }
    }

    /// The world position of an entity's `.start` characteristic point — a line's START,
    /// a point's position, a circle's center — matching how the constraint solver resolves
    /// `EntityPoint.start`. `nil` for an absent entity or a kind with no such point.
    private func startPoint(of id: EntityID) -> Vector? {
        switch drawing.entity(id)?.kind {
        case .line(let l):   return l.start
        case .point(let p):  return p.position
        case .circle(let c): return c.center
        default:             return nil
        }
    }

    /// The message posted when a GEOMETRIC constraint was arity-valid but the solver could
    /// not honor it (OVER-CONSTRAINED), so the add was rolled back. Tells the user the add
    /// would CONFLICT and how to proceed (delete an existing constraint) — distinct from the
    /// arity message, which says the SELECTION is wrong.
    private static func overConstrainedMessage(geometric kind: GeometricConstraintKind) -> String {
        "Can't add \(kind.rawValue): it would over-constrain the geometry — delete a conflicting constraint first."
    }

    /// The over-constrained message for a DIMENSIONAL constraint (see the geometric twin).
    private static func overConstrainedMessage(dimensional kind: DimensionalConstraintKind) -> String {
        "Can't add \(kind.rawValue): it would over-constrain the geometry — delete a conflicting constraint first."
    }

    /// A short, human status message for a rejected GEOMETRIC constraint (wrong arity or
    /// an unsupported kind). Names the required selection so the user can fix it.
    private static func constraintFailureMessage(geometric kind: GeometricConstraintKind,
                                                 count: Int) -> String {
        guard kind.isSolverSupported else {
            return "“\(kind.rawValue.capitalized)” constraint is not supported yet."
        }
        let need: String
        switch kind {
        case .horizontal, .vertical, .fix:    need = "one entity"
        case .parallel, .perpendicular,
             .collinear:                      need = "two lines"
        case .concentric:                     need = "two circles, arcs or ellipses"
        case .equal:                          need = "two lines or two circles/arcs"
        case .coincident:                     need = "two entities"
        default:                              need = "a valid selection"
        }
        return "Select \(need) for a \(kind.rawValue) constraint (selected \(count))."
    }

    /// A short, human status message for a rejected DIMENSIONAL constraint.
    private static func constraintFailureMessage(dimensional kind: DimensionalConstraintKind,
                                                 count: Int) -> String {
        guard kind.isSolverSupported else {
            return "“\(kind.rawValue.capitalized)” constraint is not supported yet."
        }
        switch kind {
        case .distance: return "Select two entities for a distance constraint (selected \(count))."
        case .radius:   return "Select one circle for a radius constraint (selected \(count))."
        case .diameter: return "Select one circle or arc for a diameter constraint (selected \(count))."
        case .angle:    return "Select two lines for an angle constraint (selected \(count))."
        case .horizontalDistance:
            return "Select two entities for a horizontal-distance constraint (selected \(count))."
        case .verticalDistance:
            return "Select two entities for a vertical-distance constraint (selected \(count))."
        }
    }

    /// Posts a transient message into the status HUD (the same `toolStatus` surface the
    /// active tool's prompt uses). Bumps `modelVersion` so the observing status bar
    /// repaints. Used for non-fatal arity failures (the menu/palette stays enabled; the
    /// verb degrades to a status note rather than a crash).
    func flashStatus(_ message: String) {
        toolStatus = message
        modelVersion &+= 1
    }

    // MARK: - Wire-wave 2 — FIELDS live values (Insert-Field + live resolve)

    /// The live `FieldContext` for resolving auto-updating TEXT/MTEXT fields (Wave 2a
    /// FIELDS). Built FRESH each call so `.date` fields reflect the present time:
    ///   • `date`       = `Date()` (the current time).
    ///   • `layoutName` = the active layout name, or `"Model"` in model space.
    ///   • `fileName`   = `nil` for now (DEFERRED — the live document URL is not reachable
    ///                    from the model layer; a `.fileName` field renders as "####" until
    ///                    a later wave threads the document name in). See the report.
    /// Threaded into `renderResolveContext()` (and the renderer, once it routes through
    /// it) so inserted fields substitute their live value before shaping.
    func makeFieldContext() -> FieldContext {
        FieldContext(date: Date(),
                     layoutName: activeLayout ?? "Model",
                     fileName: nil)
    }

    /// A resolve context for RENDERING that carries the live `FieldContext` (so field-
    /// bearing text shapes its evaluated value, not the zero-width placeholder). Mirrors
    /// `drawing.makeResolveContext` but injects `makeFieldContext()`. The renderer should
    /// build its context through this so on-canvas fields show live values; CanvasModel's
    /// own resolve sites that need field substitution call it too.
    func renderResolveContext(tessellationTolerance: Double = 0.05,
                              annotationScale: Double = 1.0) -> ResolveContext {
        drawing.makeResolveContext(tessellationTolerance: tessellationTolerance,
                                   annotationScale: annotationScale,
                                   fieldContext: makeFieldContext())
    }

    /// Appends an auto-updating field `token` to the SELECTED single TEXT/MTEXT entity
    /// (the Insert ▸ Field menu / ⌘K entry point), through the SAME undoable kind-commit
    /// funnel the Inspector's "Insert Field" affordance uses (`InspectorEdits.appendField`
    /// → `replaceEntityKind`). Returns whether a field was appended; a no-op (false) when
    /// the selection is not exactly one TEXT/MTEXT entity (the menu posts a status note).
    @discardableResult
    func appendFieldToSelectedText(_ token: FieldToken) -> Bool {
        guard selection.ids.count == 1, let id = selection.ids.first,
              let record = drawing.entity(id) else {
            flashStatus("Select one text or mtext object to insert a field.")
            return false
        }
        switch record.kind {
        case .text, .mtext:
            replaceEntityKind(id, InspectorEdits.appendField(to: record.kind, token: token))
            return true
        default:
            flashStatus("Insert Field needs a text or mtext object selected.")
            return false
        }
    }

    /// Whether the GEOMETRIC constraint `kind` could apply to the current selection's
    /// cardinality (a cheap menu-enablement predicate — does NOT validate kinds/entity
    /// shape, which the engine funnel does). Lets the Constrain menu disable items that
    /// can't possibly apply to what's selected.
    func canApplyGeometricConstraint(_ kind: GeometricConstraintKind) -> Bool {
        let n = selection.ids.count
        switch kind {
        case .horizontal, .vertical, .fix:                 return n == 1
        case .parallel, .perpendicular, .coincident,
             .collinear, .concentric, .equal:             return n == 2
        // tangent + symmetric stay unsupported (Lane B out of scope).
        case .tangent, .symmetric:                         return false
        }
    }

    /// Whether the DIMENSIONAL constraint `kind` could apply to the current selection's
    /// cardinality (menu-enablement predicate; the engine funnel does the full check).
    func canApplyDimensionalConstraint(_ kind: DimensionalConstraintKind) -> Bool {
        let n = selection.ids.count
        switch kind {
        case .distance, .horizontalDistance, .verticalDistance, .angle: return n == 2
        case .radius, .diameter:                                        return n == 1
        }
    }

    /// Whether the GeometricConstraintKind / DimensionalConstraintKind is solver-supported
    /// (re-exported so the menu builder can read it without importing the engine type).
    func isConstraintSupported(_ kind: GeometricConstraintKind) -> Bool { kind.isSolverSupported }
    func isConstraintSupported(_ kind: DimensionalConstraintKind) -> Bool { kind.isSolverSupported }

    /// Whether the AppKit responder-chain handlers should treat the field-insert verb as
    /// available (exactly one TEXT/MTEXT entity selected). Lets the Insert-Field menu / its
    /// `validateUserInterfaceItem` reflect applicability without re-deriving the predicate.
    var canInsertFieldIntoSelection: Bool {
        guard selection.ids.count == 1, let id = selection.ids.first else { return false }
        switch drawing.entity(id)?.kind {
        case .text, .mtext: return true
        default:            return false
        }
    }

    /// Whether the "Show Constraints" glyph overlay should currently draw anything — i.e.
    /// the document HAS constraints (the overlay's own visibility toggle is the AppStorage
    /// flag the mount drives). Lets the menu/overlay short-circuit when there is nothing
    /// to show.
    var hasConstraints: Bool { !drawing.constraints.constraints.isEmpty }

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

    /// `$CANNOSCALE` ↔ `annotationScale`. Updates both the persisted header var and
    /// the live render flag (so annotative text re-renders at the new scale on the
    /// next repaint without a reload), mirroring `setGridSpacing`. A non-positive
    /// scale is ignored (would collapse annotative text). The StatusBar scale picker
    /// calls this; it is one undo step via the `applySetting` value-snapshot funnel.
    func setAnnotationScale(_ s: Double) {
        guard s > 0 else { return }
        annotationScale = s
        applySetting { $0.annotationScale = s }
    }
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

    /// Undoes the last drawing mutation and incrementally re-syncs the spatial
    /// index (Wave 2 — P3). The drawing's value-snapshot undo restores
    /// `entities` (and the layer/block/layout tables), but the `quadtree` is a
    /// separate index the undo closures don't touch. Instead of a full
    /// `rebuildIndex()` (`O(N)` clear+insert all), we diff the *scoped* entity
    /// set before vs after the undo and patch only the delta:
    ///   - ids that vanished → `quadtree.remove`
    ///   - ids that appeared → `quadtree.insert`
    ///   - ids whose AABB changed → `quadtree.update` / `remove`
    /// This is `O(k log n)` in the size of the change (`k` is the number of
    /// touched entities), not `O(N)` in the drawing size. A layout-table undo
    /// that changes the *active* space (the tab pointer dangles) still takes the
    /// full `setActiveSpace` rebuild path via `rehomeActiveSpaceAfterTableChange`.
    func undo() {
        guard undoManager.canUndo else { return }
        // Snapshot the *scoped* set before the undo — what the quadtree
        // currently indexes (paper-space P2 / block-edit scoping included).
        let beforeScoped = activeSpaceEntities
        let beforeIDs = Set(beforeScoped.map(\.id))
        let beforeBoxes = Self.boxesByID(beforeScoped, ctx: drawing.makeResolveContext())
        let beforeSpace = activeSpace
        let beforeLayout = activeLayout

        undoManager.undo()
        rehomeActiveSpaceAfterTableChange()
        let didRehomeRebuild = (activeSpace != beforeSpace) || (activeLayout != beforeLayout)
        if !didRehomeRebuild {
            syncQuadtreeIncrementally(beforeIDs: beforeIDs, beforeBoxes: beforeBoxes)
        }
        selection.clear()
        clearTransientInteractionState()
        modelDirty = true
        modelVersion &+= 1
    }

    /// Redoes the last undone mutation and incrementally re-syncs the spatial
    /// index (mirrors `undo()` — same `O(k log n)` delta patch, not a full
    /// rebuild, unless the active space itself changed).
    func redo() {
        guard undoManager.canRedo else { return }
        let beforeScoped = activeSpaceEntities
        let beforeIDs = Set(beforeScoped.map(\.id))
        let beforeBoxes = Self.boxesByID(beforeScoped, ctx: drawing.makeResolveContext())
        let beforeSpace = activeSpace
        let beforeLayout = activeLayout

        undoManager.redo()
        rehomeActiveSpaceAfterTableChange()
        let didRehomeRebuild = (activeSpace != beforeSpace) || (activeLayout != beforeLayout)
        if !didRehomeRebuild {
            syncQuadtreeIncrementally(beforeIDs: beforeIDs, beforeBoxes: beforeBoxes)
        }
        selection.clear()
        clearTransientInteractionState()
        modelDirty = true
        modelVersion &+= 1
    }

    /// Incrementally patches the `quadtree` to match the current
    /// `activeSpaceEntities` after an undo/redo, given the *before* snapshot.
    /// `beforeIDs` / `beforeBoxes` are the scoped set + per-id AABB before the
    /// mutation; the *after* state is read live from `drawing` /
    /// `activeSpaceEntities`. Only the delta is touched — see `undo()` header.
    private func syncQuadtreeIncrementally(beforeIDs: Set<EntityID>,
                                           beforeBoxes: [EntityID: AABB]) {
        let ctx = drawing.makeResolveContext()
        let afterScoped = activeSpaceEntities
        let afterMap = Dictionary(uniqueKeysWithValues: afterScoped.map { ($0.id, $0) })
        let afterIDs = Set(afterMap.keys)
        let afterBoxes = Self.boxesByID(afterScoped, ctx: ctx)

        // Removed entities (were in the index, no longer scoped).
        for id in beforeIDs.subtracting(afterIDs) {
            quadtree.remove(id)
        }
        // Added entities (newly scoped — e.g. undo of a delete).
        for id in afterIDs.subtracting(beforeIDs) {
            if let b = afterBoxes[id], !b.isEmpty {
                quadtree.insert(id, bounds: b)
            }
        }
        // Existing but geometrically changed (box delta).
        for id in beforeIDs.intersection(afterIDs) {
            let oldB = beforeBoxes[id] ?? .empty
            let newB = afterBoxes[id] ?? .empty
            if oldB != newB {
                if newB.isEmpty { quadtree.remove(id) } else { quadtree.update(id, bounds: newB) }
            }
        }
    }

    /// Builds an `id → AABB` map for a scoped entity snapshot using the
    /// font-aware `ResolveContext` box (same as `rebuildIndex`) — the single
    /// source of truth for "what box the quadtree indexes for this record".
    private static func boxesByID(_ records: [EntityRecord], ctx: ResolveContext) -> [EntityID: AABB] {
        var m: [EntityID: AABB] = [:]
        m.reserveCapacity(records.count)
        for r in records { m[r.id] = r.boundingBox(ctx: ctx) }
        return m
    }

    /// Re-homes the active-space tab pointer after the undo/redo value-snapshot restored
    /// the layout table (finding-M1). An undo/redo can ADD or REMOVE the active paper-space
    /// LAYOUT (a New/Delete-layout step is undoable), so the `activeSpace`/`activeLayout`
    /// pair the canvas is showing can dangle — pointing at a layout that no longer exists,
    /// which blanks the canvas. Re-issuing the SAME `setActiveSpace` request is the fix:
    /// it re-resolves the request against the restored table and FALLS BACK to model space
    /// when the named layout is gone (its own guard), so the tab pointer is always valid.
    /// A no-op when the active space still resolves (`setActiveSpace`'s already-active
    /// guard short-circuits) — the common case (an entity-only edit) costs nothing.
    private func rehomeActiveSpaceAfterTableChange() {
        // The current active layout no longer resolves ⇒ the request would fall back to
        // model space. `setActiveSpace` re-frames + re-indexes on the change; when the
        // layout still exists the request is the no-op identity, so this is safe to call
        // unconditionally. We pass the CURRENT pair so an unchanged table is the no-op.
        setActiveSpace(activeSpace, layoutName: activeLayout)
    }

    /// Clears the transient interaction overlays that an undo/redo would otherwise leave
    /// pointing at PRE-undo geometry (finding-M2): the snap marker (`CrosshairOverlay`
    /// reads `snap?.point`) and the hover highlight (`MarqueeHoverOverlay` reads `hoverID`),
    /// plus any acquired OTRACK points — the SAME clear-triple `setActiveSpace` /
    /// block-edit transitions drop, since the restored entities may have moved, changed,
    /// or vanished. The selection is cleared separately by the caller.
    private func clearTransientInteractionState() {
        snap = nil
        hoverID = nil
        clearTrackingPoints()
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

    // MARK: - Paste as Block (Wave 3B — Edit ▸ Paste as Block)

    /// Pastes the current clipboard as a NEW BLOCK + an INSERT of it at `target` (a
    /// WORLD point), as ONE undoable group. It re-mints the clipboard records (ids +
    /// the cursor-anchored offset, via the pure `EntityClipboard.pasteRecords(at:)`),
    /// ADDS them to mint real ids, then wraps those ids into a block + drops one
    /// `.insert` via the undoable engine op `CADDrawing.makeBlockFromEntities` (which
    /// removes the just-added loose copies, re-authors them as members, registers the
    /// block, and adds the INSERT) — all inside the SAME undo group, so a single ⌘Z
    /// reverts the whole paste-as-block. The new INSERT becomes the selection. The block
    /// name de-duplicates on a clash (the engine op picks a free name from the
    /// suggestion), so a `nil`/blank name falls back to "Block". No-op (returns `false`)
    /// for an empty clipboard. Returns whether a block was created.
    ///
    /// Plain Cut/Copy/Paste (`cutSelection`/`copySelection`/`paste`) are unchanged; this
    /// is the additive "wrap the paste into a block" verb the Edit menu (Wave 3D) wires.
    @discardableResult
    func pasteAsBlock(name: String? = nil, at target: Vector) -> Bool {
        let records = clipboard.pasteRecords(at: target)
        guard !records.isEmpty else { return false }

        // One undo group for the whole op: add the loose copies (capturing their ids),
        // then makeBlockFromEntities removes them + creates the block + insert. The
        // explicit group keeps it a single ⌘Z under a manual-grouping undo manager
        // (tests); the live app's groupsByEvent coalesces it in one run-loop event.
        let explicitGroup = !undoManager.groupsByEvent
        if explicitGroup { undoManager.beginUndoGrouping() }
        defer { if explicitGroup { undoManager.endUndoGrouping() } }

        var ids: [EntityID] = []
        ids.reserveCapacity(records.count)
        for record in records {
            var added = record
            added.id = EntityID(0)                  // ensure a fresh mint
            added.flags.remove(.selected)
            ids.append(drawing.add(added))          // undoable; mints a real id
        }

        let blockName = (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? name! : "Block"
        let creation = drawing.makeBlockFromEntities(
            name: blockName, basePoint: target, ids: ids)

        // The engine op mutated `entities` directly (removed the loose copies, added the
        // members + the insert), bypassing the quadtree-aware add path above — rebuild
        // the index so the result is immediately snappable/selectable.
        rebuildIndex()
        if let insertID = creation?.insertID {
            selection = Selection(ids: [insertID])   // select the placed INSERT
        } else {
            selection.clear()
        }
        modelDirty = true
        modelVersion &+= 1
        return creation != nil
    }

    /// Pastes the clipboard as a block at the current VIEW CENTER (world) — the menu /
    /// keyboard Paste-as-Block default when there is no cursor anchor.
    @discardableResult
    func pasteAsBlock(name: String? = nil) -> Bool {
        let centerScreen = CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2)
        return pasteAsBlock(name: name, at: viewport.screenToWorld(centerScreen))
    }

    // MARK: - Ortho restriction (LibreCAD Ortho / AutoCAD F8)

    /// Toggles the persistent ortho flag (View ▸ Ortho / status bar). Bumps
    /// `modelVersion` so the menu checkmark + status chip refresh. (The transient
    /// hold-⇧ override is read live by the canvas — it does NOT flip this flag.)
    ///
    /// ORTHO and POLAR are MUTUALLY EXCLUSIVE: turning ortho ON clears `polarEnabled`
    /// (LibreCAD / AutoCAD only apply one angular constraint at a time), so the canvas
    /// never stacks both restrictions on a candidate point.
    func toggleOrtho() {
        orthoEnabled.toggle()
        if orthoEnabled { polarEnabled = false }   // ortho ⊕ polar — mutually exclusive
        modelVersion &+= 1
    }

    // MARK: - Isometric drafting (Wire-wave 3 — AutoCAD ISODRAFT / F5 ISOPLANE)
    //
    // Isometric drafting is a persisted DOCUMENT drafting MODE (the `$SNAPSTYLE` /
    // `$LC_ISOPLANE` header vars, not a live-only aid like ortho/polar), so its two
    // verbs funnel through the undoable `applySetting` value-snapshot mutator (one undo
    // step each, marks the document dirty) — exactly like `setGridOn` / `setGridSpacing`.
    // When iso mode is ON the snap, grid overlay, ortho lock, and crosshair all switch
    // to the active plane's iso lattice (the call sites read `isoPlaneIfActive` /
    // `crosshairAxisAngles` / `isometricMode`); OFF, every path is byte-identical to the
    // rectangular behavior (the parameters default to `nil`).

    /// Whether ISOMETRIC drafting is active (`$SNAPSTYLE == 1`). Reads/writes the
    /// document header var through the undoable mutator, so toggling it is one undo step.
    var isometricMode: Bool {
        get { drawing.graphicVariables.snapIsometric }
        set { applySetting { $0.snapIsometric = newValue } }
    }

    /// The active isometric drafting plane (Top / Left / Right — `$LC_ISOPLANE`).
    /// Reads/writes the document header var through the undoable mutator. Independent of
    /// `isometricMode`: the plane is remembered even while iso is off (so re-enabling
    /// restores the last plane), but only TAKES EFFECT when iso is on (`isoPlaneIfActive`).
    var isoPlane: IsoPlane {
        get { drawing.graphicVariables.isoPlane }
        set { applySetting { $0.isoPlane = newValue } }
    }

    /// The active iso plane ONLY when iso mode is on, else `nil` — the value the snap /
    /// grid-overlay / crosshair call sites pass through. `nil` selects the rectangular
    /// (unchanged) path in each kernel, so a non-iso drawing is byte-identical.
    var isoPlaneIfActive: IsoPlane? { isometricMode ? isoPlane : nil }

    /// Toggles isometric drafting on/off (View ▸ Isometric Snap / the ISO status chip).
    /// One undo step via `isometricMode`'s `applySetting` funnel; `modelVersion` is bumped
    /// there so the menu checkmark + status chip + canvas (iso grid/crosshair) refresh.
    func toggleIsometric() {
        isometricMode.toggle()
    }

    /// Cycles the active iso plane in the AutoCAD F5 order Top → Right → Left → Top.
    /// One undo step via `isoPlane`'s `applySetting` funnel. Bound to F5 (canvas keyDown)
    /// + the View ▸ Isoplane submenu + the ISO chip. Cycling is allowed even when iso is
    /// off (it just records the plane for the next time iso turns on), matching AutoCAD's
    /// F5, which sets ISOPLANE regardless of ISODRAFT.
    func cycleIsoPlane() {
        switch isoPlane {
        case .top:   isoPlane = .right
        case .right: isoPlane = .left
        case .left:  isoPlane = .top
        }
    }

    /// The two SCREEN-space crosshair axis angles (radians) for the active iso plane, or
    /// `nil` when iso mode is off (⇒ the unchanged rectangular crosshair). The plane's
    /// `axisDirections` are WORLD-space angles; the viewport flips Y (screen Y grows
    /// downward), so each angle is NEGATED for the screen-space `CrosshairOverlay`
    /// (`crosshairGeometry(…axisAngles:)`), matching the iso grid the user sees.
    var crosshairAxisAngles: (Double, Double)? {
        guard isometricMode else { return nil }
        let (a1, a2) = isoPlane.axisDirections
        return (-a1.angle, -a2.angle)
    }

    /// Short status-chip label for the active iso plane (e.g. "Top"). View-layer reads
    /// this to render the ISO chip text ("ISO: Top").
    var isoPlaneLabel: String {
        switch isoPlane {
        case .top:   return "Top"
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    // MARK: - Dynamic input (live dimensional feedback — AutoCAD F12 / DYNMODE)

    /// Toggles DYNAMIC INPUT — the on-canvas live dimensional feedback (View menu /
    /// status-bar DYN chip / Preferences). Flips `dynamicInputEnabled`, PERSISTS the new
    /// value to `UserDefaults` (it is an app preference, unlike the live-only ortho/polar
    /// aids), and bumps `modelVersion` so the menu checkmark + status chip refresh. The
    /// canvas mount reads `dynamicInputEnabled` to enable/suppress the
    /// `LiveDimensionOverlayView` and calls its `refresh()`.
    func toggleDynamicInput() {
        dynamicInputEnabled.toggle()
        AppSettings.setBoolPreference(AppSettings.Key.dynamicInput, dynamicInputEnabled)
        modelVersion &+= 1
    }

    /// The live dimensional feedback the ACTIVE draw tool wants shown this frame — the
    /// dotted dim line(s) + pre-formatted value chip(s) the `LiveDimensionOverlayView`
    /// draws (live-dim Wave 3 wiring). Empty unless dynamic input is on AND a draw tool
    /// is active; otherwise it asks the live `tool` value for its `liveDimensions(ctx)`,
    /// where `ctx` is a `LiveDimensionContext` built from the drawing's display-format
    /// header variables (`GraphicVariables`) so labels render in the document's
    /// units/precision exactly like the status-bar readout. The engine contract
    /// guarantees a tool returns `[]` outside its active operation (before the first
    /// point / after commit), so the overlay naturally blanks between operations.
    func currentLiveDimensions() -> [LiveDimension] {
        guard dynamicInputEnabled, isToolActive, let tool else { return [] }
        let gv = drawing.graphicVariables
        let ctx = LiveDimensionContext(
            linearFormat: gv.linearFormat,
            linearPrecision: gv.linearPrecision,
            unit: gv.unit,
            angleFormat: gv.angleFormat,
            anglePrecision: gv.anglePrecision)
        let dims = tool.liveDimensions(ctx)
        // When NOT typing, hand the tool's dims through unchanged (every editable dim
        // stays `.idle` with no `typedString`, so the overlay draws the live `label`).
        guard dynEditing else { return dims }
        // While editing, re-stamp each EDITABLE dim with the live display/edit state so
        // the overlay (Wave V) can draw the active field's raw buffer + caret in an
        // accent chip, a locked field's typed value in a pinned tint, and leave any
        // not-yet-typed editable field showing its live `label` (`.idle`). The tool
        // only stamps `field` + `isEditable`; the MODEL owns `editState` / `typedString`.
        return dims.map { dim in
            guard dim.isEditable, let field = dim.field else { return dim }
            if field == dynActiveField {
                // The focused field — echo the raw (possibly partial) buffer + caret.
                return dim.withEditing(editState: .active, typedString: dynBuffers[field])
            }
            // A non-active field whose buffer parses to a number is LOCKED (Tab moved
            // past it); the synthetic cursor honors it live. A non-parsing / empty
            // buffer leaves the field idle (it still tracks the cursor).
            if let buf = dynBuffers[field], Double(buf) != nil {
                return dim.withEditing(editState: .locked, typedString: buf)
            }
            return dim
        }
    }

    // MARK: - Dynamic input (editable live dimensions — Wave M)

    /// Whether ANY currently-shown live dimension is editable — the gate Wave V's
    /// keyDown handler uses to decide a first digit / `.` / `-` should BEGIN dynamic
    /// input (it replaces the non-existent `hasStartedOperation`). True exactly when a
    /// draw tool is mid-operation AND exposes at least one `isEditable` dim (so it is
    /// `false` in select mode, before the first point, and for non-editable tools).
    var hasEditableLiveField: Bool {
        currentLiveDimensions().contains { $0.isEditable }
    }

    /// The editable live-dimension FIELDS in Tab order (the tool's emit order). E.g.
    /// Line → `[.length, .angle]`, Rectangle → `[.width, .height]`, Circle →
    /// `[.radius]` (or `[.diameter]`). Empty when nothing editable is shown. The Tab /
    /// Shift-Tab cycle and the active-field clamp are defined against this list.
    func editableFields() -> [LiveDimensionField] {
        currentLiveDimensions().compactMap { $0.isEditable ? $0.field : nil }
    }

    /// Each typed buffer that currently parses to a `Double`, keyed by field — the
    /// values fed to `Tool.applyDynamicInput`. A field whose buffer is empty / partial
    /// (`"-"`, `"1."`, `""`) is OMITTED, so `applyDynamicInput` falls back to the live
    /// cursor for it (the field keeps tracking the mouse until the text is a number).
    func parsedDynValues() -> [LiveDimensionField: Double] {
        var out: [LiveDimensionField: Double] = [:]
        for (field, buf) in dynBuffers {
            if let v = Double(buf) { out[field] = v }
        }
        return out
    }

    /// The SYNTHETIC cursor: the world point the active tool resolves from the typed
    /// (locked + active) field values, with any untyped field falling back to the live
    /// `cursorWorld`. This is what the model feeds the tool as `.move(...)` while editing
    /// so the preview + live dims reflect the typed values (type `10` → the line shows
    /// length 10 while the angle still follows the mouse). Falls back to the raw cursor
    /// when the tool does not support dynamic input in its current state (or there is no
    /// cursor yet), so the preview never breaks.
    func effectiveCursor() -> Vector {
        let cursor = cursorWorld ?? .invalid
        let reference = relativeZero ?? cursor
        return tool?.applyDynamicInput(parsedDynValues(), cursor: cursor, reference: reference)
            ?? cursor
    }

    /// Begins dynamic input on the FIRST editable field, seeding its buffer with the
    /// just-pressed character (the digit / `.` / `-` that triggered editing). No-op if
    /// there is no editable field right now (the keyDown gate should prevent that, but
    /// this stays robust). Refreshes the synthetic-cursor preview so the typed digit is
    /// reflected immediately.
    func beginDynInput(firstChar: Character) {
        guard let first = editableFields().first else { return }
        dynEditing = true
        dynActiveField = first
        dynBuffers = [first: String(firstChar)]
        refreshDynPreview()
    }

    /// Appends a typed character to the ACTIVE field's buffer (digit / `.` / `-`, per
    /// Wave V's gate). No-op unless editing with an active field set. Refreshes the
    /// preview so the unlocked/active field updates as the user types.
    func dynAppend(_ ch: Character) {
        guard dynEditing, let field = dynActiveField else { return }
        dynBuffers[field, default: ""].append(ch)
        refreshDynPreview()
    }

    /// Deletes the last character of the ACTIVE field's buffer (Backspace). Stays in
    /// editing mode even when the buffer becomes empty (the user is mid-correction); an
    /// empty buffer just omits the field from `parsedDynValues()` so it tracks the
    /// cursor again. No-op unless editing with an active field set.
    func dynBackspace() {
        guard dynEditing, let field = dynActiveField else { return }
        guard var buf = dynBuffers[field], !buf.isEmpty else { return }
        buf.removeLast()
        dynBuffers[field] = buf
        refreshDynPreview()
    }

    /// Advances (Tab) / retreats (Shift-Tab) the active field across `editableFields()`,
    /// modulo the field count — the field the user just typed into LOCKS (its buffer is
    /// honored live) and focus moves to the next. No-op when fewer than two editable
    /// fields exist (e.g. Circle / Polygon, which have one editable field → no Tab) or
    /// when not editing. Refreshes the preview (the newly-active field now tracks the
    /// cursor; the just-left field stays locked at its typed value).
    func dynCycleField(reverse: Bool) {
        guard dynEditing else { return }
        let fields = editableFields()
        guard fields.count >= 2 else { return }
        let current = dynActiveField.flatMap { fields.firstIndex(of: $0) } ?? 0
        let step = reverse ? -1 : 1
        let next = ((current + step) % fields.count + fields.count) % fields.count
        dynActiveField = fields[next]
        refreshDynPreview()
    }

    /// Commits the typed dimensions: resolves the synthetic cursor and feeds it through
    /// the EXACT `.value(point)` coordinate-commit seam (no snap drift), exactly as if
    /// the user had typed the equivalent coordinate on the command line — so a typed
    /// length / width / radius lands precisely. Then clears all dynamic-input state. A
    /// no-op (still resets) when the tool does not resolve a point in its current state.
    @discardableResult
    func dynCommit() -> Bool {
        defer { resetDynInput() }
        guard dynEditing,
              let p = tool?.applyDynamicInput(parsedDynValues(),
                                              cursor: cursorWorld ?? .invalid,
                                              reference: relativeZero ?? cursorWorld ?? .invalid)
        else { return false }
        return handleToolInput(.value(p))
    }

    /// Cancels dynamic input (Esc while editing): clears the typed buffers + active
    /// field and exits editing, then feeds the tool the REAL cursor again so the
    /// preview reverts to tracking the mouse. Does NOT cancel the tool / the in-progress
    /// operation (decision D1) — only the typed entry is abandoned.
    func cancelDynInput() {
        resetDynInput()
        // Revert the preview to the live cursor (the synthetic cursor is gone now).
        if let c = cursorWorld { _ = handleToolInput(.move(c)) }
        modelVersion &+= 1
    }

    /// Clears ALL dynamic-input state (editing flag, active field, buffers). Used by
    /// `dynCommit` / `cancelDynInput` and the reset hooks (tool change / run end). Does
    /// not itself touch the tool or the preview.
    func resetDynInput() {
        dynEditing = false
        dynActiveField = nil
        dynBuffers = [:]
    }

    /// Drives the active tool with the SYNTHETIC cursor (`effectiveCursor()`) so the
    /// rubber-band preview AND the live dims reflect the typed values, then bumps
    /// `modelVersion` so the observing overlay/canvas repaints. Called from every
    /// dynamic-input mutation (begin / append / backspace / cycle). The `.move` may run
    /// snapping (preview only); the COMMIT path uses `.value(effectiveCursor())` so the
    /// committed point has no snap drift. Also re-clamps the active field if the tool's
    /// editable-field set changed under us (e.g. the tool advanced state).
    private func refreshDynPreview() {
        guard dynEditing else { return }
        clampDynActiveField()
        _ = handleToolInput(.move(effectiveCursor()))
        modelVersion &+= 1
    }

    /// Re-clamps `dynActiveField` to a field still present in `editableFields()`: if the
    /// editable-field set changed (the tool advanced and the active field is gone), it
    /// snaps to the first editable field, or clears to `nil` when nothing is editable.
    private func clampDynActiveField() {
        let fields = editableFields()
        if let active = dynActiveField, fields.contains(active) { return }
        dynActiveField = fields.first
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
        // Iso-ortho (Wire-wave 3): when isometric drafting is ON, ortho locks to the
        // active iso PLANE's two drawing axes (e.g. 30°/150° for .top) instead of
        // horizontal/vertical — the AutoCAD iso-ortho behavior. The iso axes are WORLD
        // directions (not UCS-rotated), so this branch ignores the UCS frame (iso + a
        // rotated UCS is a deferred coupling, noted in the report). Off ⇒ the
        // unchanged rectangular/UCS path below.
        if isometricMode {
            return OrthoConstraint.constrain(point, relativeTo: reference, isoPlane: isoPlane)
        }
        // Ortho locks to the UCS axes (UCS-W3): convert the candidate + reference INTO
        // the active UCS frame, axis-lock there with the unchanged pure kernel, then
        // convert the result back to WORLD. With `UCS.world` `toUCS`/`toWorld` are the
        // identity, so this is BYTE-IDENTICAL to the world-axis behavior (regression-lock).
        if currentUCS.isWorld {
            return OrthoConstraint.constrain(point, relativeTo: reference)
        }
        let pUCS = currentUCS.toUCS(point)
        let rUCS = currentUCS.toUCS(reference)
        let lockedUCS = OrthoConstraint.constrain(pUCS, relativeTo: rUCS)
        return currentUCS.toWorld(lockedUCS)
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

    // MARK: - Polar tracking (LibreCAD Polar / AutoCAD F10)

    /// Toggles the persistent polar-tracking flag (View ▸ Polar / status bar). Bumps
    /// `modelVersion` so the menu checkmark + status chip refresh.
    ///
    /// ORTHO and POLAR are MUTUALLY EXCLUSIVE: turning polar ON clears `orthoEnabled`
    /// (the mirror of `toggleOrtho`), so only one angular constraint is ever active.
    func togglePolar() {
        polarEnabled.toggle()
        if polarEnabled { orthoEnabled = false }   // polar ⊕ ortho — mutually exclusive
        modelVersion &+= 1
    }

    /// Applies the POLAR constraint to a candidate world point for the active draw run,
    /// honoring the same CAD snap precedence as ortho (osnap > polar > free):
    ///
    ///   1. If a REAL geometry snap is under the cursor (`osnapActive`), polar is
    ///      SKIPPED so the user can always bind to existing geometry.
    ///   2. Else, with polar effective AND a reference point (`relativeZero`, the last
    ///      placed point), the point is angle-locked via `PolarConstraint.constrain`
    ///      onto the nearest multiple of `polarAngleIncrement` (15° by default),
    ///      preserving the reference→cursor distance.
    ///   3. Else the point passes through unchanged (free).
    ///
    /// `point` is the already-snapped world point the tool would otherwise receive;
    /// `shiftHeld` is the live ⇧ flag from the point-input path. Unlike ortho's hold-⇧
    /// XOR *flip*, ⇧ here only ever RELEASES polar (AutoCAD semantics: ⇧ forces ortho /
    /// releases polar) — it never engages polar when the persistent flag is off. So this
    /// is `polarEnabled && !shiftHeld`, NOT the `!= shiftHeld` XOR: that lets the canvas
    /// safely chain ortho-then-polar without ⇧-over-ortho being hijacked into a 15° lock
    /// (ortho's own XOR disengages on ⇧ → free; polar must stay off so the point passes
    /// through). With no `relativeZero` (the FIRST point of a run) there is nothing to be
    /// polar to, so the point is returned unchanged.
    func polarConstrained(_ point: Vector, shiftHeld: Bool) -> Vector {
        guard polarEnabled, !shiftHeld else { return point }     // ⇧ releases polar
        guard !osnapActive else { return point }                 // osnap wins
        guard let reference = relativeZero else { return point }  // need a last point
        // Polar measures the angle increment from the UCS +X axis (UCS-W3): convert the
        // candidate + reference INTO the active UCS frame, angle-lock there with the
        // unchanged pure kernel (so the increments are measured from UCS X, not world X),
        // then convert the result back to WORLD. With `UCS.world` `toUCS`/`toWorld` are
        // the identity, so this is BYTE-IDENTICAL to the world behavior (regression-lock).
        if currentUCS.isWorld {
            return PolarConstraint.constrain(
                point, relativeTo: reference, incrementRadians: polarAngleIncrement)
        }
        let pUCS = currentUCS.toUCS(point)
        let rUCS = currentUCS.toUCS(reference)
        let lockedUCS = PolarConstraint.constrain(
            pUCS, relativeTo: rUCS, incrementRadians: polarAngleIncrement)
        return currentUCS.toWorld(lockedUCS)
    }

    /// Short status-bar label for the polar readout: "Polar" when the persistent flag
    /// is on, "—" when off (mirrors `orthoReadout`).
    var polarReadout: String { polarEnabled ? "Polar" : "\u{2014}" }

    // MARK: - User coordinate system (UCS — LibreCAD / AutoCAD UCS) — model foundation

    /// Sets the active UCS (the input/display frame). The document is unchanged — this
    /// only affects how coordinates are READ (the status-bar readouts), TYPED (the
    /// command line), and the UCS axis gizmo's anchor/orientation. Bumps `modelVersion`
    /// so the status bar + the axis overlay refresh (the same redraw mechanism
    /// `togglePolar` uses). A live drafting policy — not undoable, not persisted.
    func setUCS(_ ucs: UCS) {
        currentUCS = ucs
        modelVersion &+= 1
        // UCS-persistence: deferred — writing the active UCS to the document's DXF
        // header ($UCSORG / $UCSXDIR / $UCSYDIR) would hook in here (and the
        // reciprocal read in DXFReader would seed `currentUCS` on open). Out of scope
        // for UCS-W4: `currentUCS` is a live DRAFTING policy, not document content, so
        // it deliberately does not round-trip through DXF this round.
    }

    /// Restores the WORLD frame (`UCS.world`) — the identity, in which every coordinate
    /// conversion is a no-op and readouts/typed input behave exactly as if there were no
    /// UCS. Bumps `modelVersion` so the chrome refreshes.
    func resetUCS() {
        currentUCS = .world
        modelVersion &+= 1
    }

    // MARK: - Interactive UCS pick (UCS-W3 — "Set UCS by 2 Points" / "Set UCS Origin")

    /// Begins an interactive UCS pick. `twoPoint == false` ("Set UCS Origin"): the
    /// next snapped canvas click sets the UCS origin with angle 0 (axes parallel to
    /// world). `twoPoint == true` ("Set UCS by 2 Points"): the first click captures
    /// the origin, the second defines the UCS +X direction. Mirrors the one-shot
    /// `armSetRelativeZero` style — model interaction state, not a `Tool`. Bumps
    /// `modelVersion` so the status prompt ("Specify UCS origin") shows immediately.
    func beginUCSPick(twoPoint: Bool) {
        ucsPick = .awaitingOrigin(twoPoint: twoPoint)
        modelVersion &+= 1
    }

    /// Advances the UCS pick with a (SNAPPED) world click. The canvas funnel feeds
    /// the snapped world point here while `isUCSPicking`, consuming the click (the
    /// active tool / selection never sees it):
    ///   - `.awaitingOrigin(twoPoint: false)` → install `UCS(origin: world, angle: 0)`,
    ///     pick ends (`.inactive`).
    ///   - `.awaitingOrigin(twoPoint: true)` → capture the origin, advance to
    ///     `.awaitingXAxis(origin:)` (next click sets +X).
    ///   - `.awaitingXAxis(origin)` → install `UCS(origin, angle: (world − origin).angle)`,
    ///     pick ends. A degenerate second click coincident with the origin yields a
    ///     zero direction whose `.angle` is 0 (world +X) — a harmless fallback, never a
    ///     bogus frame.
    /// No-op (and `false`) when not picking or the click is invalid. Returns whether
    /// the gesture consumed the click (so the caller redraws). `setUCS` is reused for
    /// the install so the same `modelVersion` bump / chrome refresh applies.
    @discardableResult
    func ucsPickClick(_ world: Vector) -> Bool {
        guard world.valid else { return false }
        switch ucsPick {
        case .inactive:
            return false
        case .awaitingOrigin(let twoPoint):
            if twoPoint {
                ucsPick = .awaitingXAxis(origin: world)
                modelVersion &+= 1
            } else {
                ucsPick = .inactive
                setUCS(UCS(origin: world, angle: 0))   // setUCS bumps modelVersion
            }
            return true
        case .awaitingXAxis(let origin):
            // The +X direction is the click relative to the captured origin; a
            // coincident click degenerates to angle 0 (world +X) — never invalid.
            let angle = (world - origin).angle
            ucsPick = .inactive
            setUCS(UCS(origin: origin, angle: angle))  // setUCS bumps modelVersion
            return true
        }
    }

    /// Cancels an in-progress UCS pick (Esc / mode change) WITHOUT changing the active
    /// UCS — `currentUCS` is untouched, only the gesture state is cleared. No-op (and
    /// `false`) when not picking. Bumps `modelVersion` so the status prompt restores.
    @discardableResult
    func cancelUCSPick() -> Bool {
        guard isUCSPicking else { return false }
        ucsPick = .inactive
        modelVersion &+= 1
        return true
    }

    /// The status-bar prompt for the current UCS-pick step, or `nil` when not picking.
    /// Surfaced through `toolStepReadout` (the command-hint / status channel) so the
    /// user sees "Specify UCS origin" / "Specify point on X-axis" while picking.
    var ucsPickReadout: String? {
        switch ucsPick {
        case .inactive:                    return nil
        case .awaitingOrigin:              return "Specify UCS origin"
        case .awaitingXAxis:               return "Specify point on X-axis"
        }
    }

    // MARK: - Object-snap tracking (OTRACK — LibreCAD object snap tracking / AutoCAD F11)

    /// Toggles the persistent OTRACK flag (View ▸ Object Tracking / status bar). UNLIKE
    /// `toggleOrtho`/`togglePolar` — which are mutually exclusive with each other — OTRACK
    /// is INDEPENDENT: it never clears `orthoEnabled`/`polarEnabled`, so the user can run
    /// object tracking together with ortho or polar. Turning it OFF discards any acquired
    /// points (`clearTrackingPoints`, which also nils `trackingResult`). PERSISTS the new
    /// value to `UserDefaults` (it is an app preference, like dynamic input — seeded at
    /// init from `AppSettings.Key.objectTracking`), then bumps `modelVersion` so the menu
    /// checkmark + status chip refresh (the same redraw mechanism `togglePolar` uses).
    /// The toggle KEY binding is a later wire-wave (W7).
    func toggleObjectTracking() {
        objectTrackingEnabled.toggle()
        // Persist the new value (it is an app preference, like dynamic input) so the
        // Preferences toggle + cross-launch persistence take effect (mirrors
        // `toggleDynamicInput`).
        AppSettings.setBoolPreference(AppSettings.Key.objectTracking, objectTrackingEnabled)
        if !objectTrackingEnabled { clearTrackingPoints() }  // clearTrackingPoints bumps modelVersion
        modelVersion &+= 1
    }

    /// ACQUIRES (or, on a duplicate, de-acquires) a snap point for object tracking. Only a
    /// REAL object snap is acquirable — `snap.kind` must be a geometry snap, NOT `.free` /
    /// `.grid` (the same "real osnap" notion `osnapActive` encodes) — so the cursor's free
    /// position or a grid crossing can never seed a tracking guide. If the snap point is
    /// already acquired (within `worldTolerance`, "≈ equal"), it is REMOVED (the AutoCAD
    /// toggle: hovering an acquired point again drops it). Otherwise it is appended; if the
    /// list is at `maxAcquiredPoints`, the OLDEST is dropped first (FIFO) so the guide list
    /// stays bounded. No-op for a non-geometry snap. The dwell-to-acquire trigger that
    /// CALLS this is a later wave (W6); this is the model-side mutation.
    func acquireTrackingPoint(_ snap: SnapResult) {
        guard Self.isAcquirableSnapKind(snap.kind), snap.point.valid else { return }
        // Toggle off an already-acquired point ("≈ equal" within the snap aperture).
        if let dupIndex = acquiredPoints.firstIndex(where: {
            $0.point.distance(to: snap.point) <= worldTolerance
        }) {
            acquiredPoints.remove(at: dupIndex)
            modelVersion &+= 1
            return
        }
        // Append (drop the oldest if at the cap — FIFO).
        if acquiredPoints.count >= Self.maxAcquiredPoints {
            acquiredPoints.removeFirst()
        }
        acquiredPoints.append(
            AcquiredPoint(point: snap.point, kind: snap.kind, sourceEntity: snap.entity))
        modelVersion &+= 1
    }

    /// Clears every acquired OTRACK point and the live `trackingResult`. Called when OTRACK
    /// is turned off, and from every relative-zero / run-end reset site (acquisitions are
    /// transient drafting state, like the relative-zero). Bumps `modelVersion` so the
    /// overlay erases the "+"s / guides on the next redraw.
    func clearTrackingPoints() {
        guard !acquiredPoints.isEmpty || trackingResult != nil else { return }
        acquiredPoints.removeAll()
        trackingResult = nil
        modelVersion &+= 1
    }

    /// Recomputes `trackingResult` for the OTRACK lock + display. Called from `updateSnap`
    /// AFTER `snap` + `refreshPolarTracking` so a real object snap can SUPPRESS the lock
    /// (geometry snap wins — `!osnapActive`). Engaged only when OTRACK is on, there is at
    /// least one acquired point to radiate from, no real osnap is under the cursor, and a
    /// live cursor exists. Uses the SAME `worldTolerance` `updateSnap` snaps with, so a
    /// guide engages at the same aperture the snapper uses. Display + constraint data only;
    /// it never alters the snap or the polar lock.
    private func refreshObjectTracking() {
        guard objectTrackingEnabled,
              !acquiredPoints.isEmpty,
              !osnapActive,                 // a real osnap wins — yield so geometry snap takes the point
              let cursor = cursorWorld
        else {
            trackingResult = nil
            return
        }
        let gs = Tracking.guides(from: acquiredPoints, polarIncrement: polarAngleIncrement)
        trackingResult = Tracking.resolve(guides: gs, cursor: cursor, worldTolerance: worldTolerance)
    }

    /// Applies the OTRACK lock to a candidate world point: returns the locked
    /// `trackingResult.point` when OTRACK is on, a lock is live, and no real osnap is
    /// under the cursor (geometry snap always wins); otherwise the point passes through
    /// unchanged. OTRACK's lock takes PRECEDENCE over polar/ortho — W6 will chain this
    /// FIRST in the input funnel (osnap > OTRACK > polar/ortho > free).
    func trackingConstrained(_ point: Vector) -> Vector {
        guard objectTrackingEnabled, !osnapActive, let result = trackingResult else { return point }
        return result.point
    }

    /// `true` if `kind` is a REAL geometry snap (acquirable for OTRACK) — anything but
    /// `.free` / `.grid`. Mirrors the `osnapActive` predicate so acquisition and
    /// osnap-suppression agree about what counts as a geometry snap.
    static func isAcquirableSnapKind(_ kind: SnapKind) -> Bool {
        switch kind {
        case .endpoint, .center, .middle, .intersection, .onEntity,
             .perpendicular, .tangent, .nearest, .parallel:
            return true
        case .grid, .free:
            return false
        }
    }

    // MARK: - Snap tracking display (polar tracking + OTRACK — W5)

    /// PURE display data the snap-tracking overlay reads — the dotted polar ray, the
    /// OTRACK alignment guides / acquired-point markers / lock marker, and a
    /// PRE-FORMATTED on-canvas readout. It carries values + already-formatted strings
    /// ONLY: NO AppKit, NO label-box placement (the overlay does its own layout in a
    /// later wave). ALL fields are defined now so the OTRACK wave (W5) only has to FILL
    /// `guides` / `acquiredMarkers` / `lockMarker` (and may reuse `readout`); this wave
    /// populates only the polar ray + readout.
    struct TrackingDisplay {
        /// The dotted polar tracking ray to draw, `from` the relative-zero `to` the far
        /// ray endpoint (`PolarTracking.Result.rayFar`). `nil` when polar tracking is
        /// not engaged / not within the draw aperture. The overlay clips it to the view.
        var polarRay: (from: Vector, to: Vector)? = nil
        /// OTRACK alignment guides to draw (horizontal / vertical / polar / extension).
        /// Filled in W5; empty this wave.
        var guides: [TrackingGuide] = []
        /// Markers for the user's ACQUIRED snap points (the small "+" glyphs OTRACK
        /// radiates guides from). Filled in W5; empty this wave.
        var acquiredMarkers: [Vector] = []
        /// The point the cursor is currently LOCKED to by tracking (a guide projection
        /// or a two-guide intersection). Filled in W5; `nil` this wave.
        var lockMarker: Vector? = nil
        /// A pre-formatted on-canvas readout (`text`) anchored at a world `anchor` — for
        /// polar this is the `dist<angle` chip placed at the snapped point. The overlay
        /// DRAWS the string + places the chip; it does NOT format. `nil` when there is
        /// nothing to read out.
        var readout: (text: String, anchor: Vector)? = nil
    }

    /// Builds the snap-tracking overlay's PURE display data (mirrors
    /// `currentLiveDimensions()`'s build-and-return shape, but is NOT gated on
    /// `dynamicInputEnabled` — the polar ray/readout must show whenever polar tracking
    /// is engaged, independent of DYN).
    ///
    /// THIS WAVE (W2 — polar only): when `polarTrackingResult` is non-nil AND its
    /// `withinAperture` draw-gate is set (and a `relativeZero` exists to anchor the
    /// near end), emits the dotted polar `polarRay` (relativeZero → `rayFar`) and a
    /// pre-formatted `dist<angle` `readout` anchored at the snapped point. The distance
    /// + angle are formatted IN-ENGINE via `CoordinateFormatter` using the same
    /// `graphicVariables` (linear + angular format/precision/unit) `currentLiveDimensions()`
    /// builds its context from, so the chip reads consistently with the status bar. The
    /// `<` is LibreCAD's polar separator (matching `CoordinateFormatter.polarPair`).
    ///
    /// `guides` / `acquiredMarkers` / `lockMarker` stay empty (OTRACK — W5). Returns an
    /// empty `TrackingDisplay()` whenever polar tracking is not engaged. This never
    /// touches the always-on angle LOCK (`polarConstrained` is independent).
    /// THIS WAVE (W5) ALSO fills the OTRACK fields:
    ///   - `acquiredMarkers` — the "+" glyphs for every acquired point (drawn WHENEVER
    ///     OTRACK is on, so the user sees what they've acquired even before a lock).
    ///   - On an OTRACK lock (`trackingResult != nil`): `guides` = only the ENGAGED guides
    ///     (`lockedGuides`), `lockMarker` = the locked point, and `readout` = the
    ///     `dist<angle` chip anchored at the locked point, pre-formatted the same way as
    ///     the polar readout. The OTRACK lock/readout takes PRECEDENCE over polar: when
    ///     OTRACK is locked, the polar ray + readout are SUPPRESSED (an engaged tracking
    ///     lock owns the chip). With no OTRACK lock, the polar ray/readout shows as before.
    func trackingDisplay() -> TrackingDisplay {
        var display = TrackingDisplay()
        let gv = drawing.graphicVariables

        // --- OTRACK lock takes precedence over polar ---
        if objectTrackingEnabled {
            // Always show the acquired "+"s so the user sees what they've acquired.
            display.acquiredMarkers = acquiredPoints.map(\.point)
            if let track = trackingResult {
                display.guides = track.lockedGuides         // draw only the ENGAGED guides
                display.lockMarker = track.point
                display.readout = (
                    text: Self.formatPolarReadout(distance: track.distance, angle: track.angle, gv: gv),
                    anchor: track.point)
                // OTRACK lock owns the chip — suppress the polar ray/readout entirely.
                return display
            }
        }

        // --- Polar ray/readout (fallback — only when OTRACK is not locked) ---
        guard let result = polarTrackingResult,
              result.withinAperture,
              let reference = relativeZero
        else { return display }

        display.polarRay = (from: reference, to: result.rayFar)
        display.readout = (
            text: Self.formatPolarReadout(distance: result.distance, angle: result.engagedAngle, gv: gv),
            anchor: result.snappedPoint)

        return display
    }

    /// Pre-formats a `dist<angle` chip in-engine, honoring the drawing's display settings
    /// (the same source the status bar / `currentLiveDimensions()` use), so the overlay
    /// draws the string verbatim and does no formatting itself. `<` is LibreCAD's polar
    /// separator (matching `CoordinateFormatter.polarPair`). Shared by the polar ray and
    /// the OTRACK lock readouts so both chips read consistently.
    private static func formatPolarReadout(distance: Double, angle: Double, gv: GraphicVariables) -> String {
        let distStr = CoordinateFormatter.length(
            distance,
            format: gv.linearFormat,
            precision: gv.linearPrecision,
            unit: gv.unit)
        let angStr = CoordinateFormatter.angle(
            angle,
            format: gv.angleFormat,
            precision: gv.anglePrecision)
        return "\(distStr)<\(angStr)"
    }
}

// MARK: - AppSettings: new-layer defaults (finding #32 — APP-WIDE, persisted)
//
// The three "new-layer defaults" (color / line width / line type a fresh layer is
// born with, edited in Document Settings ▸ Layers and consumed by
// `LayersSidebar.addLayer`) are APP POLICY — app-wide preferences, NOT per-document
// round-trip state. They belong in `UserDefaults` alongside the other `AppSettings`,
// so a new window seeds from them and a change in Document Settings sticks across
// relaunch. Defined here (not in `AppSettingsView.swift`) because `CanvasModel` owns
// the seed/persist; the keys/encoders follow the established `AppSettings.Key` /
// `AppSettings.Default` naming + the `#RRGGBB` hex / mm-Double / String-token
// encodings already used by `canvasBackgroundHex` / `defaultLineWidthMM` / the enum
// rawValue keys. Encoders are PURE (no `UserDefaults`), so `AppSettingsTests` can
// round-trip them without touching the real domain.

extension AppSettings.Key {
    /// New-layer default COLOR, packed `#RRGGBB` (same shape as `canvasBackgroundHex`).
    static let newLayerColorHex = "app.layers.newLayerColorHex"
    /// New-layer default LINE WIDTH in millimeters (Double). `0` is the "by default"
    /// sentinel (resolve to the drawing/global default lineweight) — mirrors
    /// `defaultLineWidthMM`.
    static let newLayerLineWidthMM = "app.layers.newLayerLineWidthMM"
    /// New-layer default LINE TYPE, stored as a stable String token (see
    /// `AppSettings.lineTypeToken(_:)`).
    static let newLayerLineType = "app.layers.newLayerLineType"
}

extension AppSettings.Default {
    /// LibreCAD's signature green — matches the historical `defaultLayerColor` default.
    static let newLayerColor: RGBAColor = .librecadGreen
    /// `0` mm = "by default" (the historical `defaultLineWidth = .default`).
    static let newLayerLineWidthMM: Double = 0
    /// Solid — the historical `defaultLineType = .solid`.
    static let newLayerLineType: PenLineType = .solid
}

extension AppSettings {

    // MARK: New-layer color (RGBAColor ⇆ #RRGGBB hex) — PURE encoders

    /// Pack an `RGBAColor`'s RGB into an opaque `#RRGGBB` hex string (alpha dropped —
    /// a layer color is opaque). The same shape `CanvasTheme.rgba(fromAppHex:)` parses,
    /// so the new-layer color encodes consistently with the Appearance color overrides.
    static func newLayerColorHex(from color: RGBAColor) -> String {
        func byte(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.r), byte(color.g), byte(color.b))
    }

    /// Parse a `#RRGGBB` / `RRGGBB` hex string back to an opaque `RGBAColor`, falling
    /// back to the `newLayerColor` default for an empty / malformed value (so a corrupt
    /// key never yields an unusable color). Forgiving, matching the rest of AppSettings.
    static func newLayerColor(fromHex hex: String) -> RGBAColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return Default.newLayerColor }
        return RGBAColor(Float((v >> 16) & 0xFF) / 255,
                         Float((v >> 8) & 0xFF) / 255,
                         Float(v & 0xFF) / 255)
    }

    // MARK: New-layer line width (PenLineWidth ⇆ mm Double) — PURE encoders

    /// Encode a `PenLineWidth` to the stored mm Double. Only `.millimeters(v)` (with a
    /// finite, positive `v`) stores a width; every other case — including the
    /// `.default` the Document-Settings picker emits for "Default" — encodes as `0`,
    /// the "by default" sentinel (mirroring `defaultLineWidthMM`).
    static func newLayerLineWidthMM(from width: PenLineWidth) -> Double {
        if case .millimeters(let v) = width, v.isFinite, v > 0 { return v }
        return 0
    }

    /// Decode a stored mm Double back to a `PenLineWidth`: a finite, positive value is
    /// `.millimeters(v)`; `0` / non-positive / non-finite is the "by default" sentinel
    /// `.default` (the historical `defaultLineWidth`).
    static func newLayerLineWidth(fromMM mm: Double) -> PenLineWidth {
        (mm.isFinite && mm > 0) ? .millimeters(mm) : .default
    }

    // MARK: New-layer line type (PenLineType ⇆ String token) — PURE encoders

    /// A stable String token for a `PenLineType` (decoupled from `EntityKind`-style
    /// rawValue switches). The Document-Settings picker only offers the concrete dash
    /// patterns; `.byLayer` / `.byBlock` are never chosen for a layer default but are
    /// mapped for completeness so the encode is total.
    static func lineTypeToken(_ t: PenLineType) -> String {
        switch t {
        case .byLayer:  return "byLayer"
        case .byBlock:  return "byBlock"
        case .solid:    return "solid"
        case .dashed:   return "dashed"
        case .dotted:   return "dotted"
        case .dashDot:  return "dashDot"
        case .center:   return "center"
        case .border:   return "border"
        case .divide:   return "divide"
        }
    }

    /// Decode a `PenLineType` token, falling back to the `newLayerLineType` default
    /// (`.solid`) for an unknown / blank token.
    static func lineType(fromToken token: String) -> PenLineType {
        switch token {
        case "byLayer":  return .byLayer
        case "byBlock":  return .byBlock
        case "solid":    return .solid
        case "dashed":   return .dashed
        case "dotted":   return .dotted
        case "dashDot":  return .dashDot
        case "center":   return .center
        case "border":   return .border
        case "divide":   return .divide
        default:         return Default.newLayerLineType
        }
    }

    // MARK: Read / write (injectable `defaults` for tests; default `.standard`)

    /// The persisted new-layer default COLOR (seeded into `CanvasModel.defaultLayerColor`
    /// at init). A missing key yields the `newLayerColor` default.
    static func newLayerColor(defaults: UserDefaults = .standard) -> RGBAColor {
        guard let hex = defaults.string(forKey: Key.newLayerColorHex) else {
            return Default.newLayerColor
        }
        return newLayerColor(fromHex: hex)
    }

    /// Persist the new-layer default COLOR (called from `CanvasModel.defaultLayerColor.didSet`).
    static func setNewLayerColor(_ color: RGBAColor, defaults: UserDefaults = .standard) {
        defaults.set(newLayerColorHex(from: color), forKey: Key.newLayerColorHex)
    }

    /// The persisted new-layer default LINE WIDTH. A missing key yields the
    /// `newLayerLineWidthMM` default (`0` → `.default`).
    static func newLayerLineWidth(defaults: UserDefaults = .standard) -> PenLineWidth {
        let mm = (defaults.object(forKey: Key.newLayerLineWidthMM) as? Double)
            ?? Default.newLayerLineWidthMM
        return newLayerLineWidth(fromMM: mm)
    }

    /// Persist the new-layer default LINE WIDTH.
    static func setNewLayerLineWidth(_ width: PenLineWidth, defaults: UserDefaults = .standard) {
        defaults.set(newLayerLineWidthMM(from: width), forKey: Key.newLayerLineWidthMM)
    }

    /// The persisted new-layer default LINE TYPE. A missing/unknown token yields the
    /// `newLayerLineType` default (`.solid`).
    static func newLayerLineType(defaults: UserDefaults = .standard) -> PenLineType {
        guard let token = defaults.string(forKey: Key.newLayerLineType) else {
            return Default.newLayerLineType
        }
        return lineType(fromToken: token)
    }

    /// Persist the new-layer default LINE TYPE.
    static func setNewLayerLineType(_ t: PenLineType, defaults: UserDefaults = .standard) {
        defaults.set(lineTypeToken(t), forKey: Key.newLayerLineType)
    }
}
