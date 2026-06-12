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

    /// The "relative-zero" — the last point the active tool actually PLACED
    /// (clicked or typed), the origin that the command line's `@dx,dy`, polar
    /// `dist<angle`, and bare-distance input are measured from (UX-plan U1 / G7).
    /// Updated by `handleToolInput` on every valid `.click`/`.value` so a typed
    /// `@10,0` is relative to wherever the previous point landed. Reset to `nil`
    /// when the run ends (commit/cancel → `.finished`) or the tool changes, so the
    /// first point of a fresh run has no stale reference. Observed so the command
    /// field / status bar can show/draw it.
    private(set) var relativeZero: Vector?

    /// The most recent error from a command-line submission (`submitCommandText`),
    /// or `nil` after a successful submit. The command field echoes it so a typo
    /// like `1,,2` shows "Expected x,y" instead of silently doing nothing.
    private(set) var lastCommandError: String?

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

    /// Rectangle tool: an optional EXACT width/height. When BOTH are set (> 0) a
    /// single click drops a rectangle of that size; `nil`/0 keeps the two-corner
    /// drag. Stored as `Double` (0 ⇒ "unset") so the bar binds a plain numeric field;
    /// `applyToolConfig` maps 0 → `nil` on the tool.
    var rectWidth: Double = 0
    var rectHeight: Double = 0

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

    /// Rebuilds the quadtree from the current drawing's per-entity AABBs. Text uses
    /// the TIGHT font-aware box (via the drawing's ResolveContext) so glyph culling/
    /// snapping match the real ink extent; all other kinds use the analytic box.
    func rebuildIndex() {
        quadtree.removeAll()
        let ctx = drawing.makeResolveContext()
        let box = drawing.boundingBox()
        if !box.isEmpty { quadtree.reserveWorld(box) }
        for e in drawing.entities {
            let b = e.boundingBox(ctx: ctx)
            if !b.isEmpty { quadtree.insert(e.id, bounds: b) }
        }
    }

    // MARK: - View changes (matrix-only)

    /// Updates the stored view size (on resize). Keeps the same world center/scale.
    func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewport.size = size
    }

    /// Frames the whole drawing in the current view (Zoom to Fit).
    func zoomToFit() {
        viewport = Viewport.fit(drawing.boundingBox(), in: viewport.size)
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
    /// Returns whether the selection changed.
    @discardableResult
    func toggleSelection(atScreenPoint screen: CGPoint) -> Bool {
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
        // command line's `@`/polar/distance input has no leftover reference.
        relativeZero = nil
        lastCommandError = nil
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
            tool = t
        case var t as RectangleTool:
            // 0 ⇒ "unset" so the optional exact-size flow is opt-in (both must be > 0).
            t.fixedWidth = rectWidth > 0 ? rectWidth : nil
            t.fixedHeight = rectHeight > 0 ? rectHeight : nil
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
        // mode are fixed at construction), which resets their state/status to the
        // initial prompt. For those, take the fresh tool's status; for the in-place
        // tools (which keep their state) restore the prior prompt text.
        if tool is DivideTool || tool is ArcTool { toolStatus = tool?.status ?? "" }
        else { toolStatus = savedStatus }
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
        switch input {
        case .click(let p), .value(let p):
            if p.valid { relativeZero = p }
        default:
            break
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
            // The run ended (commit/cancel). Mint a fresh tool of the same kind so
            // the user can immediately start the next run (LibreCAD keeps the tool
            // active after each line). To leave the tool entirely, the app calls
            // `activateTool(.select)`. Re-apply the Inspector's options so a chained
            // run keeps the configured values.
            tool = activeToolKind.makeTool()
            applyToolConfig()
            toolStatus = tool?.status ?? ""
            // The run is over — drop the relative-zero so the next run starts fresh.
            relativeZero = nil
            return true
        }
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

    /// Duplicates the current selection in place at the default offset WITHOUT
    /// touching the clipboard (the ⌘D / "Duplicate" verb): snapshots the selected
    /// records, re-mints + offsets them via a transient clipboard, and adds them as
    /// the new selection (one undo step). Returns whether anything was duplicated.
    @discardableResult
    func duplicateSelection() -> Bool {
        guard !selection.isEmpty else { return false }
        let recs = selection.ids.compactMap { drawing.entity($0) }
        guard !recs.isEmpty else { return false }
        var scratch = EntityClipboard()
        scratch.copy(recs)
        return paste(records: scratch.pasteRecords())
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
