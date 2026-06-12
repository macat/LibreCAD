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

    // MARK: Derived (for the SwiftUI HUD)

    var entityCount: Int { drawing.count }

    /// Whether a draw tool is active (vs select/pan mode).
    var isToolActive: Bool { activeToolKind != .select }

    /// The window's `UndoManager`. We own one (there is no `DocumentGroup` to
    /// supply one — see LibreCADApp's note) and inject it into the drawing so tool
    /// commits register undo (ADR-002). Re-injected on `setDrawing`.
    @ObservationIgnored
    let undoManager = UndoManager()

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
        // DivideTool re-mint resets status to its initial prompt; restore the
        // prior prompt text only if the tool kept its identity (non-Divide tools
        // keep their state, so their status is unchanged anyway).
        if !(tool is DivideTool) { toolStatus = savedStatus }
        else { toolStatus = tool?.status ?? "" }
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
            return true
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

    /// Enables/disables a single snap mode (the Inspector's per-mode toggles).
    func setSnapMode(_ mode: SnapMode, _ on: Bool) {
        if on { snapModes.insert(mode) } else { snapModes.remove(mode) }
    }

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
}
