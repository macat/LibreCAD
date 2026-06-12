//
//  CADCanvasView.swift
//  LibreCADmacOS
//
//  The interactive Metal canvas: a FLIPPED `MTKView` subclass wrapped in an
//  `NSViewRepresentable`, wired to the `LineRenderer` and `CanvasModel`.
//
//  ## isFlipped contract (Viewport / backlog item)
//  `Viewport` is defined for a TOP-LEFT, Y-DOWN screen space (the convention of a
//  *flipped* NSView and of SwiftUI). The host view MUST therefore return
//  `isFlipped == true`, or `screenToWorld`/picking/pan would be vertically
//  mirrored. `FlippedMTKView` returns `true` and a `precondition` at the seam
//  documents + enforces the contract.
//
//  ## Navigation
//  - scroll  → pan (matrix-only).
//  - magnify (pinch) / scroll+⌥ → zoom about the cursor (Viewport.zoom).
//  - mouse-move → snap (Snapping.snap) → snap marker + HUD.
//  - click → hitTest → toggle selection.
//  During an active gesture the view flips to continuous redraw (isPaused=false)
//  for smooth 120 Hz, then back to on-demand (rendering-performance.md §4.3).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import SwiftUI
import MetalKit
import CoreGraphics
import CADEngine

// MARK: - Flipped MTKView (enforces the Viewport top-left Y-down contract)

/// An `MTKView` whose coordinate space is top-left origin, Y-down — the space
/// `Viewport` is defined for. It also routes mouse/scroll/magnify events to the
/// owning `CADCanvasController`.
final class FlippedMTKView: MTKView {

    /// Set by the representable so events reach the interaction logic.
    weak var controller: CADCanvasController?

    /// THE Viewport contract: a flipped view has a top-left origin with Y growing
    /// downward, matching `Viewport`'s screen space. Without this, picking/pan are
    /// vertically mirrored (backlog render-gate viewport item #2).
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    /// The cursor to show over the canvas while a tool is active (the CAD crosshair),
    /// or `nil` for the default arrow (select mode). Set by the controller's
    /// `refreshCrosshair`; consumed by `resetCursorRects`. Driving the system cursor
    /// through the cursor-rect machinery (vs `NSCursor.set()`) keeps it correct across
    /// window activation, tracking, and resize — AppKit re-applies it automatically.
    var toolCursor: NSCursor?

    /// Installs `toolCursor` (if any) over the whole canvas, so the pointer becomes a
    /// CAD crosshair while a tool is active and reverts to the arrow in select mode.
    /// `invalidateCursorRects(for:)` (called by the controller on a mode change) makes
    /// AppKit re-run this.
    override func resetCursorRects() {
        super.resetCursorRects()
        if let cursor = toolCursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }

    /// Re-apply the adaptive canvas chrome whenever the effective appearance flips
    /// (System Settings ▸ Appearance light↔dark, or a per-window override). This
    /// swaps the Metal clear color and the `OverlayStyle` grid/axis/accent colors,
    /// then forces a model rebuild (so the light-mode entity auto-invert re-runs)
    /// and a redraw so the canvas tracks the system theme live.
    ///
    /// `NSView`/`MTKView` are `@MainActor`-isolated in the SDK and this override
    /// inherits that isolation, so it reaches the `@MainActor` controller/model and
    /// `CanvasTheme.apply` directly — NO `assumeIsolated` (which the project bans on
    /// OS-invoked entry points; here the inherited isolation makes the hop unneeded).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        CanvasTheme.apply(to: self, appearance: effectiveAppearance)
        // Force the line/fill buffers to repack so the auto-invert (applied at pack
        // time) reflects the new appearance.
        controller?.model.modelDirty = true
        setNeedsDisplay(bounds)
    }

    // Mouse tracking for snap-on-move even without a button held.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: Event routing — all in the flipped (top-left, Y-down) space.

    /// The flipped-view location of the last mouse-down / drag step. Used to derive
    /// the drag-pan delta from successive cursor positions (so drag-pan uses the
    /// SAME flipped point space as scroll-pan — fixing the prior `event.deltaX/Y`
    /// device-space mismatch) and to measure click-vs-drag travel.
    private var lastDragLocation: CGPoint?
    /// The flipped-view location of the mouse-down, to classify the gesture as a
    /// click (small travel) vs a pan (large travel) on mouse-up.
    private var mouseDownLocation: CGPoint?

    private func locationInView(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved(to: locationInView(event))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.mouseExited()
    }

    override func mouseDown(with event: NSEvent) {
        let loc = locationInView(event)
        // A double-click opens the inline text editor on an existing text/mtext
        // entity under the cursor (edit-in-place). The controller no-ops if there
        // is no editable text there, so a double-click elsewhere falls through to
        // the normal click classification below.
        if event.clickCount == 2, controller?.handleDoubleClick(at: loc) == true {
            mouseDownLocation = nil
            lastDragLocation = nil
            return
        }
        mouseDownLocation = loc
        lastDragLocation = loc
    }

    override func mouseDragged(with event: NSEvent) {
        // Left-drag pans the canvas (in addition to scroll), matching a grab gesture.
        // Derive the delta from successive FLIPPED-view locations (same point space
        // as scroll-pan and `screenToWorld`), so drag-pan direction matches
        // scroll-pan and the content follows the cursor in the flipped view.
        let loc = locationInView(event)
        let prev = lastDragLocation ?? loc
        lastDragLocation = loc
        controller?.panDrag(deltaX: loc.x - prev.x, deltaY: loc.y - prev.y)
    }

    override func mouseUp(with event: NSEvent) {
        let up = locationInView(event)
        defer { mouseDownLocation = nil; lastDragLocation = nil }
        guard let down = mouseDownLocation else { return }
        // Only treat it as a click (toggle selection) if the pointer barely moved —
        // a larger travel means it was a pan, not a click (click-vs-drag threshold).
        let dx = up.x - down.x, dy = up.y - down.y
        if (dx * dx + dy * dy) <= Self.clickThreshold * Self.clickThreshold {
            controller?.mouseClick(at: up)
        }
    }

    /// Max pointer travel (points) between down and up that still counts as a click
    /// rather than a pan (so a grab-drag doesn't toggle selection on release).
    private static let clickThreshold: CGFloat = 3

    override func scrollWheel(with event: NSEvent) {
        let loc = locationInView(event)
        if event.modifierFlags.contains(.option) {
            // ⌥+scroll → zoom about the cursor.
            controller?.zoom(byWheelDelta: event.scrollingDeltaY, at: loc)
        } else {
            // Plain scroll → pan. Natural-direction handled by the sign of delta.
            controller?.scrollPan(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        }
    }

    override func magnify(with event: NSEvent) {
        let loc = locationInView(event)
        controller?.magnify(by: event.magnification, at: loc, phase: event.phase)
    }

    // MARK: Keyboard (tool activation + control)

    override func keyDown(with event: NSEvent) {
        // Let the controller claim tool keys (L / V / Esc / Return / ⌫); fall back
        // to the default responder chain (so menu shortcuts still work) otherwise.
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Interaction controller (bridges events → CanvasModel + redraw)

/// Owns the live interaction state for one canvas: the model, the renderer, the
/// MTKView, and the gesture lifecycle (on-demand vs continuous redraw).
@MainActor
final class CADCanvasController {
    let model: CanvasModel
    private(set) var renderer: LineRenderer?
    weak var view: FlippedMTKView?

    /// While true the view draws continuously (smooth gesture); set during an
    /// active pan/zoom and reset shortly after the gesture ends.
    private var gestureActive = false
    private var gestureEndWorkItem: DispatchWorkItem?

    /// A hook ContentView sets so the canvas can hand keyboard focus to the bottom
    /// command/coordinate line (U1) on Space (D1). `nil` until the view appears; the
    /// `handleKey` Space branch calls it (and consumes Space) only when set AND a
    /// tool is active, so Space is otherwise free.
    var requestCommandFocus: (() -> Void)?

    init(model: CanvasModel) {
        self.model = model
    }

    /// The on-canvas transform gizmo overlay (a subview of the MTKView). Created in
    /// `attach` and shown only in Select mode with a non-empty selection. It owns
    /// the move/scale/rotate handle drag → undoable commit; the controller just
    /// keeps it sized + refreshed as the view/selection/tool change.
    private(set) var gizmo: GizmoOverlayView?

    /// The full-canvas CAD crosshair overlay (UX-plan U3, a subview of the MTKView).
    /// Created in `attach`, shown only while a drawing/edit tool is active
    /// (`model.crosshairVisible`), and refreshed on every cursor move. It is always
    /// click-through (`hitTest` returns nil), so it never affects select/draw/pan.
    private(set) var crosshair: CrosshairOverlayView?

    func attach(view: FlippedMTKView, renderer: LineRenderer) {
        self.view = view
        self.renderer = renderer

        // Float the CAD crosshair UNDER the gizmo (added first). It is fully
        // click-through, so ordering only matters for paint layering — keeping it
        // below the gizmo means the gizmo handles paint over the crosshair lines.
        let crosshairView = CrosshairOverlayView(model: model)
        crosshairView.frame = view.bounds
        crosshairView.autoresizingMask = [.width, .height]
        crosshairView.isHidden = !model.crosshairVisible
        view.addSubview(crosshairView)
        crosshair = crosshairView

        // Float the transform gizmo over the canvas. It is transparent to clicks
        // that are NOT on a handle (its `hitTest` returns nil there), so normal
        // select/draw behavior is unchanged; it only claims a drag that starts on
        // a handle.
        let gizmoView = GizmoOverlayView(model: model) { [weak self] in self?.redraw() }
        gizmoView.frame = view.bounds
        gizmoView.autoresizingMask = [.width, .height]
        view.addSubview(gizmoView)
        gizmo = gizmoView
        refreshGizmo()
        refreshCrosshair()
    }

    /// Shows/hides + repaints the CAD crosshair overlay to match the current mode:
    /// visible while a drawing/edit tool is active (`model.crosshairVisible`), hidden
    /// in select mode. Also swaps the system cursor over the canvas — the tighter
    /// `.crosshair` arrow while a tool is active (so the pointer reinforces the mode,
    /// HIG: "make the current mode obvious"), the normal arrow in select mode, via
    /// the view's cursor-rect machinery. Called after any tool change and on every
    /// cursor move.
    func refreshCrosshair() {
        guard let crosshair else { return }
        let show = model.crosshairVisible
        crosshair.isHidden = !show
        if show { crosshair.refresh() }
        // Drive the system cursor over the canvas through the cursor-rect machinery:
        // set the desired cursor on the view + invalidate so `resetCursorRects` runs.
        if let v = view {
            v.toolCursor = show ? .crosshair : nil
            v.window?.invalidateCursorRects(for: v)
        }
    }

    /// Recomputes the gizmo handle positions and toggles its visibility: shown only
    /// in Select mode with a non-empty selection (and never while an inline text
    /// editor is open, so it doesn't fight the editor). Call after any change to the
    /// selection, the viewport (pan/zoom), or the active tool.
    func refreshGizmo() {
        guard let gizmo else { return }
        let showable = !model.isToolActive && textEditor == nil
        if showable {
            gizmo.refresh()                 // shows itself iff there is a selection
        } else {
            model.clearGizmoPreview()
            gizmo.isHidden = true
        }
    }

    // MARK: Redraw helpers

    private func redraw() {
        // Keep the gizmo handles glued to the (possibly panned/zoomed/edited)
        // selection on every repaint — EXCEPT mid-drag, where the gizmo owns its own
        // frame (its drag math is relative to the frame captured at mouse-down, and
        // it repaints itself). Refreshing mid-drag would not move the frame (the
        // selection bounds are unchanged until commit) but we skip it to avoid any
        // churn while the user is actively dragging a handle.
        if let gizmo, !gizmo.isDragging { refreshGizmo() }
        // Keep the crosshair glued to the (snapped) cursor across pan/zoom repaints
        // (its center is `worldToScreen(cursor)`, which moves when the viewport does).
        if let crosshair, !crosshair.isHidden { crosshair.refresh() }
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    /// Public redraw hook for SwiftUI commands (e.g. Edit ▸ Delete) that mutate the
    /// model directly and need the canvas to repaint.
    func requestRedraw() { redraw() }

    /// Enter continuous-redraw mode for a smooth gesture, scheduling a return to
    /// on-demand after a short idle (so the last frame settles).
    private func beginGesture() {
        gestureEndWorkItem?.cancel()
        if !gestureActive {
            gestureActive = true
            view?.isPaused = false
        }
    }

    private func endGestureSoon() {
        gestureEndWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gestureActive = false
            self.view?.isPaused = true
            self.redraw()
        }
        gestureEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Navigation

    func scrollPan(deltaX: CGFloat, deltaY: CGFloat) {
        beginGesture()
        // Scroll delta is in points; pan the content with it (natural direction).
        model.pan(byScreenDelta: CGSize(width: deltaX, height: deltaY))
        endGestureSoon()
        redraw()
    }

    func panDrag(deltaX: CGFloat, deltaY: CGFloat) {
        beginGesture()
        model.pan(byScreenDelta: CGSize(width: deltaX, height: deltaY))
        endGestureSoon()
        redraw()
    }

    func zoom(byWheelDelta delta: CGFloat, at point: CGPoint) {
        beginGesture()
        // The zoom anchor `point` is in the view's local space, so the viewport must
        // match that view's size for the cursor to stay put (same invariant as click).
        syncViewSizeFromView()
        // Map wheel delta to a multiplicative zoom factor (clamped per tick).
        let step = 1.0 + Double(delta) * 0.01
        let factor = Swift.min(Swift.max(step, 0.5), 2.0)
        model.zoom(by: factor, about: point)
        endGestureSoon()
        redraw()
    }

    func magnify(by magnification: CGFloat, at point: CGPoint, phase: NSEvent.Phase) {
        beginGesture()
        syncViewSizeFromView()
        // `magnification` is a delta (e.g. +0.02 per event); 1 + delta is the factor.
        model.zoom(by: 1.0 + Double(magnification), about: point)
        endGestureSoon()
        redraw()
    }

    func zoomToFit() {
        model.zoomToFit()
        redraw()
    }

    // MARK: Cursor interaction (snap + select)

    /// Pulls the live view bounds INTO the viewport so `screenToWorld`/`worldToScreen`
    /// use exactly the rect the incoming event point was measured in. Events arrive in
    /// the `FlippedMTKView`'s own local space (`convert(_:from: nil)`); the Viewport's
    /// `size` MUST be that same view's point-size or the center term in
    /// `screenToWorld` is off, producing a CONSTANT cursor↔committed-point offset of
    /// half the size mismatch on each axis. `setViewSize` is otherwise driven by
    /// SwiftUI's `updateNSView` and the MTKView resize callback, both of which can lag
    /// the actual bounds by a layout pass; re-syncing here makes the click/move math
    /// provably keyed off the SAME view the point came from, no matter the ordering.
    /// (Matrix-only: keeps center/scale; only `size` may change — cheap, idempotent.)
    private func syncViewSizeFromView() {
        if let b = view?.bounds.size { model.setViewSize(b) }
    }

    func mouseMoved(to point: CGPoint) {
        syncViewSizeFromView()
        let spacing = renderer?.lastGridSpacing
        model.updateSnap(atScreenPoint: point, gridSpacing: spacing)
        // When a draw tool is active, feed it the SNAPPED world point so its
        // rubber-band preview tracks the cursor. Otherwise this is select mode and
        // the snap marker / HUD is all that updates.
        if model.isToolActive {
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            model.handleToolInput(.move(p))
        }
        // Keep the CAD crosshair glued to the (snapped) cursor on every move.
        refreshCrosshair()
        // Redraw the coordinate HUD + snap marker (and tool preview) on every move
        // (overlay-only; the model instance buffer is untouched — §5).
        redraw()
    }

    func mouseExited() {
        model.clearCursor()
        // The cursor left the canvas — repaint so the crosshair (which keys off
        // `cursorWorld`) clears.
        refreshCrosshair()
        redraw()
    }

    /// A classified click (down→up with negligible travel). With a draw tool
    /// active it feeds the tool a snapped `.click`; otherwise it toggles selection.
    /// (A larger-travel down→up is a pan and is handled by `panDrag`, NOT here.)
    func mouseClick(at point: CGPoint) {
        syncViewSizeFromView()
        // The Text tool authors text via the inline NSTextView editor, not the
        // model's geometry-tool input path: a click sets the insertion point and
        // raises the editor. (Detected by the active tool's identity so it works the
        // moment the wire-wave adds `ToolKind.text` — see `isTextToolActive`.)
        if isTextToolActive {
            // If an editor is already open, commit it first (a new click starts a
            // fresh run, like clicking away in a text app).
            if textEditor != nil { commitTextEditing() }
            let spacing = renderer?.lastGridSpacing
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            beginTextEditing(atWorldPoint: p, editing: nil, initialText: "")
            redraw()
            return
        }
        if model.isToolActive {
            let spacing = renderer?.lastGridSpacing
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            if model.handleToolInput(.click(p)) { redraw() }
            return
        }
        if model.toggleSelection(atScreenPoint: point) {
            redraw()
        }
    }

    // MARK: Inline text authoring (the NSTextView editor over the canvas)

    /// The live inline text editor, or `nil` when none is open. The controller owns
    /// at most one at a time; it is added as a subview of the `FlippedMTKView`.
    private(set) var textEditor: TextEditorOverlay?

    /// Whether the active tool is the Text authoring tool. Detected by the tool's
    /// stable `title` ("Text") rather than a `ToolKind` case, so this works the
    /// moment the wire-wave adds `ToolKind.text` + the toolbar/menu/key binding —
    /// no edit to this file is then needed to make text authoring reachable.
    var isTextToolActive: Bool { model.tool?.title == "Text" }

    /// The default text height (world units) for newly authored text. Mirrors
    /// `TextTool.defaultHeight` / the "Standard" style's last height.
    private static let defaultTextHeight: Double = 2.5

    /// Opens the inline editor at a WORLD insertion point. `editing` is the entity
    /// being edited (→ commit replaces it) or `nil` for new text; `initialText`
    /// seeds the editor (the existing string when editing, else empty).
    func beginTextEditing(atWorldPoint world: Vector, editing: EntityID?, initialText: String) {
        guard let view else { return }
        // Tear down any prior editor first.
        teardownEditor(commit: false)

        let height = Self.defaultTextHeight
        // Screen anchor: the insertion point, nudged UP by the cap height so the
        // first line's baseline sits near the click (the precise baseline is set by
        // the renderer once committed). worldToScreen is top-left/Y-down.
        let screenPoint = model.viewport.worldToScreen(world)
        let pointHeight = CGFloat(height * model.viewport.scale)
        let origin = CGPoint(x: screenPoint.x, y: screenPoint.y - pointHeight)

        let overlay = TextEditorOverlay(
            worldPoint: world,
            worldHeight: height,
            styleName: TextTool.standardStyleName,
            editingID: editing,
            initialText: initialText,
            screenOrigin: origin,
            pointHeight: pointHeight,
            accentColor: .controlAccentColor,
            backgroundColor: .textBackgroundColor,
            textColor: .textColor
        )
        overlay.textView.onCommit = { [weak self] in self?.commitTextEditing() }
        overlay.textView.onCancel = { [weak self] in self?.cancelTextEditing() }

        view.addSubview(overlay.container)
        textEditor = overlay
        // Give the editor focus so typing goes straight into it.
        view.window?.makeFirstResponder(overlay.textView)
    }

    /// Double-click handler: if a text/mtext entity is under the cursor, open the
    /// inline editor pre-filled with its string (edit-in-place). Returns whether a
    /// text entity was found and the editor opened.
    @discardableResult
    func handleDoubleClick(at screenPoint: CGPoint) -> Bool {
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        guard let id = model.selection.hitTest(
            worldPoint: world,
            worldTolerance: model.worldTolerance,
            in: model.drawing,
            using: model.quadtree
        ), let record = model.drawing.entity(id) else { return false }

        // Only text/mtext entities are editable by the inline editor.
        switch record.kind {
        case .text(let d):
            beginTextEditing(atWorldPoint: d.position, editing: id, initialText: d.text)
            redraw()
            return true
        case .mtext(let d):
            beginTextEditing(atWorldPoint: d.position, editing: id,
                             initialText: Self.plainText(of: d))
            redraw()
            return true
        default:
            return false
        }
    }

    /// Commits the inline editor: builds + runs a `TextTool` value (single-line →
    /// `.text`, multi-line → `.mtext`; editing → `.replace`) and applies the edits
    /// through the shared `applyToolEdits` (the same undoable `applyCommit` path the
    /// in-canvas tools use). Empty text creates nothing. Tears the editor down.
    func commitTextEditing() {
        guard let overlay = textEditor else { return }
        let string = overlay.currentText
        textEditor = nil
        overlay.container.removeFromSuperview()

        var tool: TextTool
        if let id = overlay.editingID {
            tool = TextTool(
                editing: id, at: overlay.worldPoint, text: string,
                height: overlay.worldHeight, styleName: overlay.styleName)
        } else {
            tool = TextTool(
                text: string, height: overlay.worldHeight, styleName: overlay.styleName)
            // Place the insertion point, then commit.
            _ = tool.handle(.click(overlay.worldPoint), context: .empty)
        }
        let outcome = tool.handle(.commit, context: .empty)
        if case .commit(let edits) = outcome {
            model.applyToolEdits(edits)
        }
        redraw()
    }

    /// Cancels the inline editor (Esc): discards the typed text, no entity created
    /// or replaced.
    func cancelTextEditing() {
        teardownEditor(commit: false)
        redraw()
    }

    /// Removes the editor view + state. `commit` is reserved for callers that want
    /// the editor's text committed first (currently only the explicit commit path
    /// does that itself); this just tears down.
    private func teardownEditor(commit: Bool) {
        guard let overlay = textEditor else { return }
        textEditor = nil
        overlay.container.removeFromSuperview()
    }

    /// Reconstructs a plain multi-line string from an `MTextData`'s paragraph/run
    /// tree (run texts concatenated per paragraph; paragraphs joined with `\n`), so
    /// the inline editor can pre-fill when editing an existing MTEXT entity.
    private static func plainText(of data: MTextData) -> String {
        data.paragraphs.map { paragraph in
            paragraph.inlines.map { inline -> String in
                switch inline {
                case .run(let run):       return run.text
                case .stacked(let s):     return "\(s.upper)/\(s.lower)"
                case .tab:                return "\t"
                }
            }.joined()
        }.joined(separator: "\n")
    }

    // MARK: Tool activation + keyboard

    /// Switches the active tool (toolbar/menu/keyboard). Redraws so the preview /
    /// status clears or appears. Switching tools tears down any open inline text
    /// editor (without committing) so a stale editor never lingers across a mode
    /// change.
    func activateTool(_ kind: ToolKind) {
        teardownEditor(commit: false)
        model.activateTool(kind)
        // The mode changed → show/hide the crosshair + swap the system cursor.
        refreshCrosshair()
        redraw()
    }

    /// Makes the Metal canvas the first responder again (called when the command
    /// line yields focus on Esc/submit, U1) so bare-letter tool shortcuts route to
    /// the canvas `keyDown` instead of the text field.
    func returnFocusToCanvas() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Routes a keyboard event to tool/mode control. Returns `true` if handled.
    ///   V / Esc      → return to select mode (Esc also cancels an in-progress run).
    ///   Return/Enter → commit the current tool run.
    ///   Delete/⌫     → backspace the current tool run (tool active) OR delete the
    ///                  current selection (select mode, if non-empty).
    ///   Draw (bare): L=Line, C=Circle, A=Arc, R=Rectangle, P=Polyline, O=Point,
    ///                E=Ellipse, G=Polygon.
    ///   Modify (⇧):  M=Move, ⇧C=Copy, ⇧R=Rotate, ⇧S=Scale, ⇧M=Mirror, ⇧O=Offset.
    ///   Edit:        T=Trim, X=Extend, F=Fillet, ⇧F=Chamfer (pick under cursor).
    ///   Annotate:    ⇧T=Text. Dimensions: D=Linear, I=Aligned, U=Radius,
    ///                B=Diameter, N=Angular (wire-wave-B).
    /// These mirror the Tools-menu shortcuts in `LibreCADApp` (the discoverable
    /// source of truth) so the canvas and the menu stay in lockstep. Bare keys with
    /// a command modifier are NOT claimed here (⌘O Open / ⌘Z Undo / ⌘0 Zoom-to-Fit
    /// reach the menu via the responder chain).
    func handleKey(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Shift distinguishes a modify tool (⇧C Copy) from its draw twin (C Circle).
        // `charactersIgnoringModifiers` upper-cases a shifted letter, so we lower-case
        // for the lookup and read the Shift flag separately rather than off the char.
        let shift = event.modifierFlags.contains(.shift)
        // A command-key combo is a menu shortcut (⌘O/⌘Z/⌘0); let it pass through.
        let command = event.modifierFlags.contains(.command)
        // Option distinguishes Stretch (⌥S) from Spline (S) / Scale (⇧S) — the one
        // tool with no free mnemonic plain/shift letter (⇧S is Scale). It is the only
        // option chord in the keymap; any other option combo falls through.
        let option = event.modifierFlags.contains(.option)
        // Esc is key code 53 (no reliable character).
        let isEscape = event.keyCode == 53
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return / keypad Enter
        let isDelete = event.keyCode == 51 || event.keyCode == 117 // Delete / Forward-Delete
        let isSpace = event.keyCode == 49

        // Space (D1) hands focus to the bottom command/coordinate line (U1) while a
        // tool is active, so the user can type a precise coordinate/length without a
        // bare letter switching tools. Only claimed when a tool is active AND the
        // focus hook is wired (ContentView sets it); otherwise Space falls through.
        if isSpace, !command, model.isToolActive, let focus = requestCommandFocus {
            focus()
            return true
        }

        if isEscape {
            // Cancel any in-progress run, then drop to select mode.
            if model.isToolActive { model.handleToolInput(.cancel) }
            model.activateTool(.select)
            // Dropping to select mode hides the crosshair + restores the arrow.
            refreshCrosshair()
            redraw()
            return true
        }
        if model.isToolActive, isReturn {
            model.handleToolInput(.commit)
            redraw()
            return true
        }
        if model.isToolActive, isDelete {
            // While a draw tool is mid-run, ⌫ backspaces the run (undo last point),
            // NOT delete-selection — the tool consumes it.
            model.handleToolInput(.backspace)
            redraw()
            return true
        }
        if !model.isToolActive, isDelete {
            // Select mode: ⌫/Delete removes the current selection (undoable). Only
            // claim the key if there is actually a selection to delete, so an empty
            // ⌫ falls through to the responder chain (e.g. system beep) rather than
            // being silently swallowed.
            if model.deleteSelection() {
                redraw()
                return true
            }
            return false
        }
        // ⌥S = Stretch (modify). It is the sole option chord — handled before the
        // bare-letter switch so option+S does NOT fall through to S (Spline). Any
        // other option combo is left for the responder chain.
        if option {
            if !command, chars == "s" {
                activateTool(.stretch)
                return true
            }
            return false
        }
        // Bare letter keys (no command modifier) activate tools. Shift selects the
        // modify variant where a draw tool shares the letter (C/R/S/M/O).
        guard !command else { return false }
        switch chars {
        case "v":
            activateTool(.select)
            return true
        case "l":
            // Bare L = Line (draw); ⇧L = Lengthen (modify, wire-wave-C) — free shift
            // chord (bare L has no other shift twin).
            activateTool(shift ? .lengthen : .line)
            return true
        case "c":
            activateTool(shift ? .copy : .circle)
            return true
        case "a":
            // Bare A = Arc (draw); ⇧A = Array (modify) — shared-letter shift
            // convention (like ⇧C/⇧R/⇧M/⇧O).
            activateTool(shift ? .array : .arc)
            return true
        case "r":
            activateTool(shift ? .rotate : .rectangle)
            return true
        case "p":
            activateTool(.polyline)
            return true
        case "o":
            // Bare O = Point (draw); ⇧O = Offset (modify) — the shared-letter
            // shift convention (like ⇧C/⇧R/⇧M).
            activateTool(shift ? .offset : .point)
            return true
        case "e":
            activateTool(.ellipse)
            return true
        case "g":
            activateTool(.polygon)
            return true
        case "m":
            activateTool(shift ? .mirror : .move)
            return true
        case "s":
            // Bare S = Spline (draw); ⇧S = Scale (modify) — shared-letter shift
            // convention (like ⇧C/⇧R/⇧M/⇧O).
            activateTool(shift ? .scale : .spline)
            return true
        case "h":
            // Hatch (draw/fill): fills the region bounded by the selection. No
            // draw/modify twin → plain H.
            activateTool(.hatch)
            return true
        case "d":
            // Bare D = Linear Dimension (wire-wave-B); ⇧D = Divide (modify).
            activateTool(shift ? .divide : .linearDim)
            return true
        case "i":
            // Bare I = Aligned Dimension (wire-wave-B); ⇧I = Insert Block (wire-wave-C)
            // — free shift chord (bare I has no other shift twin).
            activateTool(shift ? .insert : .alignedDim)
            return true
        case "u":
            // Radius Dimension (wire-wave-B; no draw/modify twin → plain U).
            activateTool(.radialDim)
            return true
        case "b":
            // Bare B = Diameter Dimension (wire-wave-B); ⇧B = Break (modify,
            // wire-wave-C) — free shift chord (bare B has no other shift twin).
            activateTool(shift ? .break : .diameterDim)
            return true
        case "n":
            // Angular Dimension (wire-wave-B; no draw/modify twin → plain N).
            activateTool(.angularDim)
            return true
        case "t":
            // Bare T = Trim (edit); ⇧T = Text (wire-wave-B). The inline NSTextView
            // editor opens on the next canvas click (see `isTextToolActive`).
            activateTool(shift ? .text : .trim)
            return true
        case "x":
            // Bare X = Extend (edit); ⇧X = Explode (modify) — shared-letter shift
            // convention (like ⇧C/⇧R/⇧M/⇧O).
            activateTool(shift ? .explode : .extend)
            return true
        case "f":
            // Edit tools: bare F = Fillet (round), ⇧F = Chamfer (bevel) — the
            // shared-letter shift convention (like ⇧C/⇧R/⇧M/⇧O).
            activateTool(shift ? .chamfer : .fillet)
            return true
        default:
            return false
        }
    }
}

// MARK: - SwiftUI representable

/// SwiftUI wrapper that hosts the flipped Metal canvas and binds it to a
/// `CanvasModel`. The model is the single source of truth; the controller bridges
/// AppKit events into it.
struct CADCanvasView: NSViewRepresentable {
    let model: CanvasModel
    /// A weak hook so the enclosing view can invoke "Zoom to Fit" from a command.
    let controllerBox: ControllerBox

    /// A tiny reference box so SwiftUI commands (menu/key) can reach the
    /// per-instance controller without it being part of the `View` value.
    final class ControllerBox {
        weak var controller: CADCanvasController?
    }

    func makeCoordinator() -> CADCanvasController {
        let c = CADCanvasController(model: model)
        controllerBox.controller = c
        return c
    }

    func makeNSView(context: Context) -> FlippedMTKView {
        let view = FlippedMTKView()

        // Enforce the Viewport top-left Y-down contract at the seam UNCONDITIONALLY
        // — checked before the device guard so it is not dead on the
        // device-failure path (the flipped contract holds regardless of Metal).
        precondition(view.isFlipped, "CADCanvasView host MUST be isFlipped (Viewport contract).")

        guard let device = MTLCreateSystemDefaultDevice() else {
            assertionFailure("CADCanvasView: no Metal device.")
            NSLog("CADCanvasView: FATAL — no Metal device; canvas will not render.")
            return view
        }

        view.device = device
        view.enableSetNeedsDisplay = true     // on-demand draw (rendering-perf §4.3)
        view.isPaused = true
        view.autoResizeDrawable = true
        view.colorPixelFormat = .bgra8Unorm_srgb   // sRGB drawable (rendering-perf §4.4)
        // Adaptive canvas chrome: sets the clear color + OverlayStyle grid/axis/
        // accent colors for the CURRENT system appearance (dark == the prior
        // hardcoded look; light == a tuned light palette). `viewDidChangeEffective-
        // Appearance` re-applies it on every light↔dark toggle.
        CanvasTheme.apply(to: view, appearance: view.effectiveAppearance)
        view.preferredFramesPerSecond = 120

        guard let renderer = LineRenderer(model: model, device: device) else {
            NSLog("CADCanvasView: renderer init failed.")
            return view
        }
        view.delegate = renderer

        let controller = context.coordinator
        view.controller = controller
        controller.attach(view: view, renderer: renderer)

        view.setNeedsDisplay(view.bounds)
        return view
    }

    func updateNSView(_ nsView: FlippedMTKView, context: Context) {
        // Keep the model's view size in sync (drives Viewport.fit on resize-aware
        // commands). The drawable auto-resizes; we only need the point size.
        model.setViewSize(nsView.bounds.size)
        // Re-glue the transform gizmo to the selection after any observed model
        // change SwiftUI funnels through here (e.g. ⌘Z undo / redo, which mutate the
        // drawing + clear the selection without going through the controller's
        // `redraw`). Skipped mid-drag (the gizmo owns its frame then).
        if let gizmo = context.coordinator.gizmo, !gizmo.isDragging {
            context.coordinator.refreshGizmo()
        }
        nsView.setNeedsDisplay(nsView.bounds)
    }
}
