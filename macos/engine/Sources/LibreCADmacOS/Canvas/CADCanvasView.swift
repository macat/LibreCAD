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
final class FlippedMTKView: MTKView, NSUserInterfaceValidations {

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
    /// click (small travel) vs a pan/marquee (large travel) on mouse-up.
    private var mouseDownLocation: CGPoint?

    /// Whether the LEFT-button drag currently in progress is a MARQUEE (rubber-band
    /// selection) rather than a pan. Set on a select-mode empty-space mouse-down
    /// (decision D2: empty-space drag selects, Space/middle-drag pans). Reset on up.
    private var leftDragIsMarquee = false

    /// Whether the LEFT-button drag currently in progress is a ZOOM-WINDOW box (F23):
    /// the canvas was armed for Zoom Window when the drag started. Takes precedence
    /// over the marquee/pan classification. Reset on up.
    private var leftDragIsZoomWindow = false

    /// Whether the Space key is currently held — the pan modifier in SELECT mode
    /// (D2: Space-drag pans, so a plain select-mode drag is free for the marquee).
    /// Tracked via `keyDown`/`keyUp` (Space is a key, not an `NSEvent` modifier).
    private var spaceHeld = false

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
        // Zoom-Window (F23) takes precedence: when armed, ANY left drag draws the
        // zoom box (regardless of tool/entity/Space), released to zoom-to-fit it.
        // The box itself starts on the first past-threshold drag step (so a click in
        // zoom-window mode is a harmless no-op, not an infinite zoom).
        leftDragIsZoomWindow = false
        leftDragIsMarquee = false
        if controller?.isZoomWindowArmed == true {
            leftDragIsZoomWindow = true
            return
        }
        // Decide up-front whether this LEFT drag will be a marquee or a pan (D2):
        //   • Space held  → pan (the explicit pan modifier in select mode), OR
        //   • draw/edit tool active → pan (draw mode never marquees), OR
        //   • the down hit an entity → NOT a marquee (a click/gizmo interaction).
        // Otherwise (select mode, empty space, no Space) → a marquee. We arm it only
        // once the drag passes the click threshold (in `mouseDragged`) so a plain
        // click on empty space still deselects via `mouseClick`.
        if !spaceHeld, controller?.beginMarqueeIfEmptySpaceEligible(at: loc) == true {
            // Eligible (select mode + empty space) — the marquee actually STARTS on
            // first drag past threshold; mark intent here.
            leftDragIsMarquee = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = locationInView(event)
        let prev = lastDragLocation ?? loc
        lastDragLocation = loc

        if leftDragIsZoomWindow {
            // Start the zoom box on the first past-threshold step (a tiny jitter that
            // still counts as a click does not flash a box), then span it.
            if controller?.isZoomWindowDragActive != true, let down = mouseDownLocation {
                let dx = loc.x - down.x, dy = loc.y - down.y
                guard (dx * dx + dy * dy) > Self.clickThreshold * Self.clickThreshold else { return }
                controller?.beginZoomWindowDrag(at: down)
            }
            controller?.updateZoomWindowDrag(to: loc)
            return
        }

        if leftDragIsMarquee {
            // Start the box on the first past-threshold step (so a tiny jitter that
            // still counts as a click does not flash a marquee), then update it.
            if controller?.isMarqueeActive != true, let down = mouseDownLocation {
                let dx = loc.x - down.x, dy = loc.y - down.y
                guard (dx * dx + dy * dy) > Self.clickThreshold * Self.clickThreshold else { return }
                controller?.beginMarquee(at: down)
            }
            controller?.updateMarquee(to: loc)
            return
        }

        // Otherwise this is a PAN (Space-drag, draw-mode drag, or a drag that started
        // on an entity). Derive the delta from successive FLIPPED-view locations (same
        // point space as scroll-pan and `screenToWorld`) so the content follows the
        // cursor in the flipped view.
        controller?.panDrag(deltaX: loc.x - prev.x, deltaY: loc.y - prev.y)
    }

    override func mouseUp(with event: NSEvent) {
        let up = locationInView(event)
        defer {
            mouseDownLocation = nil; lastDragLocation = nil
            leftDragIsMarquee = false; leftDragIsZoomWindow = false
        }

        // A zoom-window box in progress → commit it (zoom-to-fit the box + exit mode).
        if controller?.isZoomWindowDragActive == true {
            controller?.endZoomWindowDrag()
            return
        }
        // The drag was armed for zoom-window but never passed the click threshold (a
        // click, not a box): cancel the mode without zooming, so the click is a
        // harmless no-op rather than leaving the canvas stuck armed.
        if leftDragIsZoomWindow {
            controller?.cancelZoomWindow()
            return
        }
        // A marquee in progress → commit it (window/crossing by direction; ⇧ adds).
        if controller?.isMarqueeActive == true {
            controller?.endMarquee(additive: event.modifierFlags.contains(.shift))
            return
        }
        guard let down = mouseDownLocation else { return }
        // Only treat it as a click (toggle selection) if the pointer barely moved —
        // a larger travel means it was a pan, not a click (click-vs-drag threshold).
        let dx = up.x - down.x, dy = up.y - down.y
        if (dx * dx + dy * dy) <= Self.clickThreshold * Self.clickThreshold {
            controller?.mouseClick(at: up)
        }
    }

    // MARK: Middle-button + right-button (pan + context menu, D2 / U5)

    /// Middle-button drag pans the canvas in ANY mode (D2: the always-available pan
    /// gesture, alongside Space-drag), so a plain left-drag in select mode is free for
    /// the marquee.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        lastDragLocation = locationInView(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDragged(with: event); return }
        let loc = locationInView(event)
        let prev = lastDragLocation ?? loc
        lastDragLocation = loc
        controller?.panDrag(deltaX: loc.x - prev.x, deltaY: loc.y - prev.y)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        lastDragLocation = nil
    }

    /// Right-click → the canvas context menu (U5). Over a selection: Cut/Copy/
    /// Duplicate/Delete/Properties; over empty canvas: Paste / Select All / Zoom to
    /// Fit / toggle Grid / toggle Ortho / Document Settings. The menu items target
    /// THIS view (an NSObject, so ObjC action dispatch works) and forward to the
    /// controller. `nil` while a draw tool is active (no menu mid-draw).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller, controller.canShowContextMenu else { return nil }
        // Stash the click point + select the right-clicked entity (Mac convention).
        controller.prepareContextMenu(at: locationInView(event))

        let menu = NSMenu()
        // We set each item's `isEnabled`/`state` explicitly, so turn OFF auto-enabling
        // (which would otherwise re-derive enablement via the responder chain).
        menu.autoenablesItems = false

        func item(_ title: String, _ action: Selector, enabled: Bool = true,
                  state: NSControl.StateValue = .off) -> NSMenuItem {
            let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
            m.target = self
            m.isEnabled = enabled
            m.state = state
            return m
        }

        if controller.hasSelection {
            menu.addItem(item("Cut", #selector(ctxCut(_:))))
            menu.addItem(item("Copy", #selector(ctxCopy(_:))))
            menu.addItem(item("Duplicate", #selector(ctxDuplicate(_:))))
            menu.addItem(item("Delete", #selector(ctxDelete(_:))))
            menu.addItem(.separator())
            // Arrange (draw order) + Revert direction (F16) — act on the selection.
            let arrange = NSMenu()
            arrange.autoenablesItems = false
            arrange.addItem(item("Bring to Front", #selector(bringToFrontAction(_:))))
            arrange.addItem(item("Bring Forward", #selector(bringForwardAction(_:))))
            arrange.addItem(item("Send Backward", #selector(sendBackwardAction(_:))))
            arrange.addItem(item("Send to Back", #selector(sendToBackAction(_:))))
            let arrangeItem = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
            arrangeItem.submenu = arrange
            menu.addItem(arrangeItem)
            menu.addItem(item("Revert Direction", #selector(revertDirectionAction(_:)),
                              enabled: controller.canRevertSelectionDirection))
            menu.addItem(.separator())
            // WAVE BW (Ask #1): convert the selection to a NAMED block (spec §2.1).
            // Forwards to the View-layer name sheet via the controller hook.
            menu.addItem(item("Create Block from Selection…",
                              #selector(ctxCreateBlockFromSelection(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Properties…", #selector(ctxProperties(_:))))
            menu.addItem(.separator())
        }
        menu.addItem(item("Paste", #selector(ctxPaste(_:)), enabled: controller.canPaste))
        menu.addItem(item("Select All", #selector(ctxSelectAll(_:)),
                          enabled: controller.hasSelectableEntities))
        menu.addItem(.separator())
        menu.addItem(item("Zoom to Fit", #selector(ctxZoomToFit(_:))))
        menu.addItem(item("Show Grid", #selector(ctxToggleGrid(_:)),
                          state: controller.isGridVisible ? .on : .off))
        menu.addItem(item("Ortho", #selector(ctxToggleOrtho(_:)),
                          state: controller.isOrthoEnabled ? .on : .off))
        menu.addItem(.separator())
        menu.addItem(item("Document Settings…", #selector(ctxDocumentSettings(_:))))
        return menu
    }

    // Context-menu @objc action handlers — forward to the controller's plain verb
    // methods. They live on the view (an NSObject) so NSMenuItem target/action ObjC
    // dispatch works; the controller (a plain Swift class) owns the model mutation.
    @objc private func ctxCut(_ sender: Any?)        { controller?.contextCut() }
    @objc private func ctxCopy(_ sender: Any?)       { controller?.contextCopy() }
    @objc private func ctxDuplicate(_ sender: Any?)  { controller?.contextDuplicate() }
    @objc private func ctxDelete(_ sender: Any?)     { controller?.contextDelete() }
    @objc private func ctxProperties(_ sender: Any?) { controller?.contextProperties() }
    @objc private func ctxCreateBlockFromSelection(_ sender: Any?) { controller?.contextCreateBlockFromSelection() }
    @objc private func ctxPaste(_ sender: Any?)      { controller?.contextPaste() }
    @objc private func ctxSelectAll(_ sender: Any?)  { controller?.contextSelectAll() }
    @objc private func ctxZoomToFit(_ sender: Any?)  { controller?.contextZoomToFit() }
    @objc private func ctxToggleGrid(_ sender: Any?) { controller?.contextToggleGrid() }
    @objc private func ctxToggleOrtho(_ sender: Any?){ controller?.contextToggleOrtho() }
    @objc private func ctxDocumentSettings(_ sender: Any?) { controller?.contextDocumentSettings() }

    /// Max pointer travel (points) between down and up that still counts as a click
    /// rather than a pan (so a grab-drag doesn't toggle selection on release).
    private static let clickThreshold: CGFloat = 3

    override func scrollWheel(with event: NSEvent) {
        let loc = locationInView(event)
        // Device-aware mapping (owner-chosen): a TRACKPAD two-finger scroll PANS the
        // canvas (content follows the fingers); a MOUSE WHEEL ZOOMS toward the cursor
        // (a single notch in/out, the standard CAD wheel-zoom). We distinguish the two
        // via `hasPreciseScrollingDeltas`: a trackpad/Magic-Mouse reports *precise*
        // (sub-line, pixel-granular) deltas; a classic notched wheel mouse reports
        // *coarse* line-granular deltas (false).
        //
        // Heuristic caveat: a few high-resolution / "smart" wheel mice ALSO report
        // precise deltas and would therefore pan rather than zoom under the bare
        // gate. We accept that as the lesser evil (those devices also support smooth
        // two-axis scrolling, where panning is the natural feel) AND give every device
        // an explicit, unambiguous escape hatch: ⌥+scroll ALWAYS zooms-to-cursor,
        // regardless of the device, so a precise-delta mouse can still zoom on demand.
        if event.modifierFlags.contains(.option) {
            // ⌥+scroll → zoom about the cursor (device-independent override).
            controller?.zoom(byWheelDelta: event.scrollingDeltaY, at: loc)
        } else if event.hasPreciseScrollingDeltas {
            // Trackpad (precise deltas) → pan. Content follows the fingers; the
            // natural-direction sign is already baked into `scrollingDeltaX/Y`.
            controller?.scrollPan(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        } else {
            // Mouse wheel (coarse deltas) → zoom toward the cursor. The world point
            // under the pointer stays under the pointer (Viewport.zoom anchors it).
            controller?.zoom(byWheelDelta: event.scrollingDeltaY, at: loc)
        }
    }

    override func magnify(with event: NSEvent) {
        let loc = locationInView(event)
        controller?.magnify(by: event.magnification, at: loc, phase: event.phase)
    }

    // MARK: Keyboard (tool activation + control)

    override func keyDown(with event: NSEvent) {
        // Track Space-held for the select-mode pan modifier (D2). In select mode the
        // controller does NOT consume Space (its Space branch needs a tool active), so
        // tracking it here lets a Space-drag pan instead of marquee. Space is still
        // forwarded to `handleKey` (which only claims it when a tool is active).
        if event.keyCode == 49 { spaceHeld = true }
        // Let the controller claim tool keys (L / V / Esc / Return / ⌫); fall back
        // to the default responder chain (so menu shortcuts still work) otherwise.
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
        super.keyUp(with: event)
    }

    // MARK: Edit/View actions (responder-chain targets for the menu)
    //
    // The Edit ▸ Select All / Deselect / Invert and View ▸ Ortho menu items are
    // wired to these `@objc` actions via `NSApp.sendAction(_:to:nil:from:)` (the menu
    // Buttons in LibreCADApp). Routing through the responder chain — rather than a
    // SwiftUI focused value — keeps the wiring entirely inside the canvas + app menu:
    // the FlippedMTKView is the canvas's first responder, so the focused window's
    // canvas receives the action. Each delegates to the controller (which owns the
    // model + redraw). `validateUserInterfaceItem` enables/disables them per state.

    /// Edit ▸ Select All (⌘A). Overrides the standard `NSResponder.selectAll` so the
    /// canvas claims it when focused (rather than a text field's select-all). Selects
    /// every selectable entity and repaints the highlight.
    @objc override func selectAll(_ sender: Any?) {
        controller?.selectAllEntities()
    }

    /// Edit ▸ Deselect All (⇧⌘A).
    @objc func deselectAllEntities(_ sender: Any?) {
        controller?.deselectAllEntities()
    }

    /// Edit ▸ Invert Selection.
    @objc func invertSelectionAction(_ sender: Any?) {
        controller?.invertSelectionEntities()
    }

    /// Edit ▸ Select Connected — grow the selection to the seed's connected component
    /// (`SelectionTraversal.connected`).
    @objc func selectConnectedAction(_ sender: Any?) {
        controller?.selectConnectedFromSeed()
    }

    /// Edit ▸ Select Contour — grow the selection to the seed's closed contour loop
    /// (`SelectionTraversal.contour`).
    @objc func selectContourAction(_ sender: Any?) {
        controller?.selectContourFromSeed()
    }

    /// View ▸ Ortho (F8) — toggles the persistent ortho restriction.
    @objc func toggleOrthoAction(_ sender: Any?) {
        controller?.toggleOrtho()
    }

    /// View ▸ Zoom Window (F23) — arm the transient drag-box zoom.
    @objc func zoomWindowAction(_ sender: Any?) {
        controller?.enterZoomWindow()
    }

    /// View ▸ Zoom Previous (F23) — restore the most recent prior viewport.
    @objc func zoomPreviousAction(_ sender: Any?) {
        controller?.zoomPrevious()
    }

    /// Arrange ▸ Bring to Front (F16).
    @objc func bringToFrontAction(_ sender: Any?) {
        controller?.bringSelectionToFront()
    }

    /// Arrange ▸ Send to Back (F16).
    @objc func sendToBackAction(_ sender: Any?) {
        controller?.sendSelectionToBack()
    }

    /// Arrange ▸ Bring Forward — one step toward the front (F16).
    @objc func bringForwardAction(_ sender: Any?) {
        controller?.raiseSelection()
    }

    /// Arrange ▸ Send Backward — one step toward the back (F16).
    @objc func sendBackwardAction(_ sender: Any?) {
        controller?.lowerSelection()
    }

    /// Arrange ▸ Revert Direction — flip the selection's defining direction (F16).
    @objc func revertDirectionAction(_ sender: Any?) {
        controller?.revertSelectionDirection()
    }

    /// Enables the canvas actions when appropriate so the menu items don't gray out
    /// while the canvas is focused, and drives the Ortho item's checkmark.
    /// `NSView` is not itself `NSUserInterfaceValidations` (the protocol the menu uses
    /// to enable/check items), so we adopt it here for our four canvas actions; any
    /// other selector defaults to enabled (true) — the responder chain still validates
    /// the rest.
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let controller else { return true }
        switch item.action {
        case #selector(NSResponder.selectAll(_:)):
            // Enabled only when there is selectable geometry to select.
            return controller.hasSelectableEntities
        case #selector(deselectAllEntities(_:)), #selector(invertSelectionAction(_:)):
            return true
        case #selector(selectConnectedAction(_:)), #selector(selectContourAction(_:)):
            // Enabled only when there is a seed to grow from (a single selected entity
            // or an entity under the cursor); greyed out otherwise so the verb is never
            // a silent no-op.
            return controller.hasSelectionSeed
        case #selector(toggleOrthoAction(_:)):
            // Reflect the persistent ortho state as the menu checkmark.
            if let menuItem = item as? NSMenuItem {
                menuItem.state = controller.model.orthoEnabled ? .on : .off
            }
            return true
        case #selector(zoomWindowAction(_:)):
            // Reflect the armed state as the menu checkmark (it auto-disarms on use).
            if let menuItem = item as? NSMenuItem {
                menuItem.state = controller.isZoomWindowArmed ? .on : .off
            }
            return true
        case #selector(zoomPreviousAction(_:)):
            // Enabled only when there is a prior viewport to return to.
            return controller.model.canZoomPrevious
        case #selector(bringToFrontAction(_:)), #selector(sendToBackAction(_:)),
             #selector(bringForwardAction(_:)), #selector(sendBackwardAction(_:)):
            // Enabled only with a non-empty selection to reorder.
            return controller.canArrangeSelection
        case #selector(revertDirectionAction(_:)):
            // Enabled only when something in the selection has a revertible direction.
            return controller.canRevertSelectionDirection
        default:
            return true
        }
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

    /// A hook ContentView sets so the canvas context menu's "Properties" verb (U5)
    /// can reveal + focus the Inspector pane (where entity properties are edited).
    /// `nil` until the view appears.
    var requestShowInspector: (() -> Void)?

    /// A hook ContentView sets so the context menu's "Document Settings…" verb can
    /// raise the per-document settings sheet. `nil` until the view appears.
    var requestDocumentSettings: (() -> Void)?

    /// A hook ContentView sets so the context menu's "Create Block from Selection…"
    /// verb (WAVE BW, Ask #1) can raise the View-layer block-name sheet. `nil` until
    /// the view appears. The sheet (a modal) lives in the View layer ONLY; the
    /// controller merely signals "the user asked to create a block".
    var requestCreateBlockFromSelection: (() -> Void)?

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

    /// The marquee + hover overlay (UX-plan U5, a subview of the MTKView). Draws the
    /// live rubber-band selection box (blue window / green-dashed crossing) and the
    /// hover highlight on the entity under the cursor. Always click-through (`hitTest`
    /// returns nil) so the FlippedMTKView keeps the marquee/click/pan gesture.
    private(set) var marqueeOverlay: MarqueeHoverOverlayView?

    /// The dynamic-block VISIBILITY GRIP overlay (DB-1W, a subview of the MTKView). A
    /// down-arrow dropdown grip shown ONLY when the single selection is a dynamic insert;
    /// clicking it pops an `NSMenu` of the block's visibility-state names and switches the
    /// insert's active state (block-features §9.4, §13.5). Transparent to clicks that are
    /// NOT on the grip (its `hitTest` returns nil there). Arbitrated against the gizmo in
    /// `refreshGizmo` (a dynamic insert suppresses the gizmo and shows ONLY this overlay).
    private(set) var dynamicGrip: DynamicGripOverlayView?

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

        // Float the marquee + hover overlay (U5) above the crosshair, below the
        // gizmo. Fully click-through, so the FlippedMTKView keeps the gesture; it
        // only paints the live selection box + hover highlight.
        let marqueeView = MarqueeHoverOverlayView(model: model)
        marqueeView.frame = view.bounds
        marqueeView.autoresizingMask = [.width, .height]
        view.addSubview(marqueeView)
        marqueeOverlay = marqueeView

        // Float the transform gizmo over the canvas. It is transparent to clicks
        // that are NOT on a handle (its `hitTest` returns nil there), so normal
        // select/draw behavior is unchanged; it only claims a drag that starts on
        // a handle.
        let gizmoView = GizmoOverlayView(model: model) { [weak self] in self?.redraw() }
        gizmoView.frame = view.bounds
        gizmoView.autoresizingMask = [.width, .height]
        view.addSubview(gizmoView)
        gizmo = gizmoView

        // Float the dynamic-block visibility grip OVER the gizmo (added last, so its chip
        // paints on top). It is transparent to clicks that are NOT on the grip; and when
        // it is shown for a dynamic insert the gizmo is suppressed (see `refreshGizmo`), so
        // the two overlays never contend for an ambiguous hit-test (critic must-fix).
        let dynamicGripView = DynamicGripOverlayView(model: model) { [weak self] in self?.redraw() }
        dynamicGripView.frame = view.bounds
        dynamicGripView.autoresizingMask = [.width, .height]
        view.addSubview(dynamicGripView)
        dynamicGrip = dynamicGripView

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
    ///
    /// DUAL-OVERLAY ARBITRATION (DB-1W, critic must-fix): when the single selection is a
    /// dynamic-block insert (`model.shouldSuppressGizmoForSelection`), the transform gizmo
    /// is SUPPRESSED (`isHidden = true` + `clearGizmoPreview`) and ONLY the dynamic-grip
    /// overlay shows — so two transparent overlays never contend for an ambiguous hit-test.
    /// For ANY other selection the gizmo behaves exactly as before and the dynamic grip is
    /// hidden. (The dynamic grip is itself only shown in Select mode with no text editor,
    /// the same gate the gizmo uses.)
    func refreshGizmo() {
        guard let gizmo else { return }
        let interactive = !model.isToolActive && textEditor == nil
        let suppressForDynamic = interactive && model.shouldSuppressGizmoForSelection

        if interactive && !suppressForDynamic {
            gizmo.refresh()                 // shows itself iff there is a selection
        } else {
            model.clearGizmoPreview()
            gizmo.isHidden = true
        }

        // The dynamic-grip overlay shows ONLY for a single dynamic insert in Select mode;
        // it hides itself (via its own `refresh`) for any other selection or non-interactive
        // mode, so it never blocks clicks when inactive.
        if let dynamicGrip {
            if interactive { dynamicGrip.refresh() }
            else { dynamicGrip.isHidden = true }
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
        // Keep the marquee/hover overlay glued across pan/zoom (its box + highlight
        // are `worldToScreen`-mapped, so they move when the viewport does).
        marqueeOverlay?.refresh()
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
        // Map the raw scroll delta to a multiplicative zoom factor (pure + tested).
        let factor = ViewportNav.zoomFactor(forWheelDelta: Double(delta))
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

    /// The live ⇧ (Shift) state, read at the point-input call site for the transient
    /// hold-⇧ ortho override ONLY. We read the GLOBAL `NSEvent.modifierFlags` (the
    /// current device state) rather than threading the event through every gesture
    /// callback, so it is correct at the instant the move/click is processed. This is
    /// deliberately scoped to the ortho point-input path — `handleKey` reads its own
    /// `event.modifierFlags` Shift for the keymap (⇧C Copy vs C Circle), and the gizmo
    /// reads its own; none of them consult this, so the existing Shift behavior is
    /// untouched.
    static var shiftHeld: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    func mouseMoved(to point: CGPoint) {
        syncViewSizeFromView()
        let spacing = renderer?.lastGridSpacing
        model.updateSnap(atScreenPoint: point, gridSpacing: spacing)
        // When a draw tool is active, feed it the SNAPPED world point so its
        // rubber-band preview tracks the cursor. Otherwise this is select mode and
        // the snap marker / HUD is all that updates. Ortho (if effective) axis-locks
        // the point to the last placed point BEFORE the tool sees it, so the preview
        // is already constrained; osnap still wins (see `orthoConstrained`).
        // Paper-space VIEWPORT placement is an OUT-OF-BAND mode (no `Tool`): feed its
        // own move handler so the rubber-band frame tracks the (snapped) PAPER-space
        // cursor. Only active + meaningful in a layout tab (model space ⇒ inert).
        if model.isViewportPlacementActive {
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            model.handleViewportMove(p)
        } else if model.isToolActive {
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            let constrained = model.orthoConstrained(p, shiftHeld: Self.shiftHeld)
            model.handleToolInput(.move(constrained))
        }
        // Hover highlight (U5): in SELECT mode, track the entity under the cursor so
        // the overlay can highlight it as a pre-selection affordance. Cheap — it
        // reuses the click hit-test (quadtree-prefiltered). No hover while a tool is
        // active (`updateHover` guards that). Repaint the overlay when it changed.
        if model.updateHover(atScreenPoint: point) { refreshMarquee() }
        // Keep the CAD crosshair glued to the (snapped) cursor on every move.
        refreshCrosshair()
        // Redraw the coordinate HUD + snap marker (and tool preview) on every move
        // (overlay-only; the model instance buffer is untouched — §5).
        redraw()
    }

    func mouseExited() {
        model.clearCursor()
        // Clear the hover highlight (and any in-progress marquee) as the cursor leaves.
        if model.clearHover() { refreshMarquee() }
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
        // Paper-space VIEWPORT placement (out-of-band): the two clicks define the
        // viewport frame on the sheet; the second click commits a `LayoutViewport` to
        // the active layout (undoable). The snapped PAPER-space point feeds the tool.
        if model.isViewportPlacementActive {
            let spacing = renderer?.lastGridSpacing
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            if model.handleViewportClick(p) { redraw() }
            return
        }
        if model.isToolActive {
            let spacing = renderer?.lastGridSpacing
            let p = model.snappedWorldPoint(atScreenPoint: point, gridSpacing: spacing)
            // Apply ortho to the CLICKED point too (osnap > ortho > free), so the
            // committed point matches the constrained preview the user is looking at.
            let constrained = model.orthoConstrained(p, shiftHeld: Self.shiftHeld)
            if model.handleToolInput(.click(constrained)) { redraw() }
            return
        }
        if model.toggleSelection(atScreenPoint: point) {
            redraw()
        }
    }

    // MARK: Marquee (rubber-band) selection (UX-plan U5)

    /// The world anchor of an in-progress marquee drag (the empty-space mouse-down
    /// point), or `nil` when no marquee is active. Set on a select-mode empty-space
    /// mouse-down, used to span the box on each drag step, cleared on mouse-up.
    private var marqueeAnchorWorld: Vector?

    /// Whether a marquee drag is currently in progress (so the view's mouse-up runs
    /// the box-select instead of the click/pan classification).
    var isMarqueeActive: Bool { marqueeAnchorWorld != nil }

    /// Whether a select-mode mouse-down at a screen point is ELIGIBLE to begin a
    /// marquee: select mode (no tool active) AND the down did NOT hit an entity (empty
    /// space). Returns `false` in draw mode or over an entity (those keep the existing
    /// click/gizmo/pan behavior). The view uses this to decide a drag's intent at
    /// mouse-down; the box itself only starts once the drag passes the click threshold
    /// (`beginMarquee`).
    func beginMarqueeIfEmptySpaceEligible(at screenPoint: CGPoint) -> Bool {
        guard !model.isToolActive else { return false }    // draw mode → no marquee
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        // An entity under the cursor ⇒ a click / gizmo interaction, not a marquee.
        let hit = model.selection.hitTest(
            worldPoint: world, worldTolerance: model.worldTolerance,
            in: model.drawing, using: model.quadtree
        )
        return hit == nil
    }

    /// Actually starts the marquee box at a screen anchor (called by the view once a
    /// drag passes the click threshold). Records the world anchor + seeds the model.
    func beginMarquee(at screenPoint: CGPoint) {
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        marqueeAnchorWorld = world
        model.beginMarquee(at: world)
    }

    /// Updates the in-progress marquee to span from its anchor to the current screen
    /// point, repainting the marquee overlay. No-op if no marquee is active.
    func updateMarquee(to screenPoint: CGPoint) {
        guard let anchor = marqueeAnchorWorld else { return }
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        model.updateMarquee(from: anchor, to: world)
        refreshMarquee()
        redraw()
    }

    /// Commits the in-progress marquee (window vs crossing by drag direction, ⇧ adds
    /// to the current selection), then clears it + repaints. No-op if no marquee is
    /// active. Returns whether a marquee was committed (so the view skips the click
    /// classification).
    @discardableResult
    func endMarquee(additive: Bool) -> Bool {
        guard marqueeAnchorWorld != nil else { return false }
        marqueeAnchorWorld = nil
        let crossing = model.marqueeCrossing
        _ = model.commitMarquee(crossing: crossing, additive: additive)
        refreshGizmo()
        refreshMarquee()
        redraw()
        return true
    }

    /// Cancels an in-progress marquee without changing the selection (Esc / mouse
    /// exit), repainting to erase the box.
    func cancelMarquee() {
        guard marqueeAnchorWorld != nil else { return }
        marqueeAnchorWorld = nil
        model.cancelMarquee()
        refreshMarquee()
        redraw()
    }

    /// Repaints the marquee + hover overlay so the live box / highlight tracks the
    /// model state.
    func refreshMarquee() { marqueeOverlay?.refresh() }

    // MARK: Context menu (right-click, UX-plan U5)
    //
    // The NSMenu itself is BUILT by `FlippedMTKView.menu(for:)` (an NSObject, so the
    // menu items can target it for ObjC action dispatch) and its @objc item handlers
    // forward to the plain controller methods below. The controller exposes the
    // model-derived enablement/state + a "prepare" step (selecting the right-clicked
    // entity + stashing the cursor world point for an anchored Paste); the verb
    // methods mirror the menu-bar / keyboard actions exactly (Delete → deleteSelection,
    // Select All → selectAll(), etc.) so a right-click is identical to the real action.

    /// The WORLD point of the last right-click, so the Paste verb anchors there.
    private var contextMenuWorld: Vector?

    /// Whether a context menu may be shown right now (no draw tool mid-run).
    var canShowContextMenu: Bool { !model.isToolActive }

    /// Prepares the canvas for a context menu at a screen point: stashes the cursor
    /// world point (for an anchored Paste) and, if the click is over an entity NOT
    /// already selected, selects it (replace) — right-clicking an unselected entity
    /// acts on it (the Mac convention). Repaints if the selection changed.
    func prepareContextMenu(at screenPoint: CGPoint) {
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        contextMenuWorld = world
        if let hit = model.selection.hitTest(
            worldPoint: world, worldTolerance: model.worldTolerance,
            in: model.drawing, using: model.quadtree
        ), !model.selection.contains(hit) {
            model.selection = Selection(ids: [hit])
            refreshGizmo()
            redraw()
        }
    }

    /// Whether the context menu's selection-dependent verbs (Cut/Copy/Duplicate/
    /// Delete/Properties) should appear.
    var hasSelection: Bool { !model.selection.isEmpty }
    /// Whether Paste is enabled (clipboard has content).
    var canPaste: Bool { model.hasClipboard }
    /// Whether the grid is shown (drives the menu checkmark).
    var isGridVisible: Bool { model.gridVisible }
    /// Whether ortho is on (drives the menu checkmark).
    var isOrthoEnabled: Bool { model.orthoEnabled }

    // Context-menu verb handlers (plain methods; the view's @objc items forward here).
    func contextCut()  { if model.cutSelection() { refreshGizmo(); redraw() } }
    func contextCopy() { _ = model.copySelection() }
    func contextDuplicate() { if model.duplicateSelection() { refreshGizmo(); redraw() } }
    func contextDelete() { if model.deleteSelection() { refreshGizmo(); redraw() } }
    func contextProperties() { requestShowInspector?() }
    func contextPaste() {
        let ok = contextMenuWorld.map { model.paste(at: $0) } ?? model.paste()
        if ok { refreshGizmo(); redraw() }
    }
    func contextSelectAll() { selectAllEntities() }
    /// WAVE BW (Ask #1): the user right-clicked → "Create Block from Selection…".
    /// Signals the View layer (which owns the live `CanvasModel` + the modal sheet) to
    /// raise the block-name prompt for the current selection.
    func contextCreateBlockFromSelection() { requestCreateBlockFromSelection?() }
    func contextZoomToFit() { zoomToFit() }
    func contextToggleGrid() { model.gridVisible.toggle(); redraw() }
    func contextToggleOrtho() { toggleOrtho() }
    func contextDocumentSettings() { requestDocumentSettings?() }

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
    /// inline editor pre-filled with its string (edit-in-place); ELSE if a block
    /// `.insert` is under the cursor, enter its in-place Block Editor (WAVE BW, Ask #2
    /// — BEDIT). Returns whether a double-click action was taken (so the caller can
    /// stop normal click classification).
    ///
    /// Order matters: the text edit-in-place check runs FIRST (a text entity sitting
    /// over an insert still opens the text editor), then the insert → enter-editor
    /// check. Entering an editor is a no-op while one is already open (the engine
    /// guards re-entry), so a double-click inside the editor doesn't nest.
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
        case .insert(let d):
            // Double-click a block reference → enter its in-place editor (BEDIT). The
            // model re-scopes the canvas/index/camera to the block's members; the
            // BlockEditBar (Save & Close / Discard) becomes visible via `isEditingBlock`.
            if model.enterBlockEditing(name: d.blockName) {
                refreshGizmo()
                redraw()
                return true
            }
            return false
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
        // Leaving select mode clears the hover highlight + any in-progress marquee
        // (both are select-mode affordances).
        cancelMarquee()
        _ = model.clearHover()
        refreshMarquee()
        // The mode changed → show/hide the crosshair + swap the system cursor.
        refreshCrosshair()
        redraw()
    }

    // MARK: Selection primitives + ortho (Edit / View menu actions)

    /// Whether any entity is currently selectable (drives Edit ▸ Select All enabled
    /// state via the view's `validateUserInterfaceItem`).
    var hasSelectableEntities: Bool {
        !SelectionPolicy.selectableIDs(in: model.drawing).isEmpty
    }

    /// Edit ▸ Select All — selects every selectable entity and repaints the highlight
    /// + re-glues the gizmo to the new selection.
    func selectAllEntities() {
        if model.selectAll() { refreshGizmo(); redraw() }
    }

    /// Edit ▸ Deselect All — clears the selection and repaints.
    func deselectAllEntities() {
        if model.deselectAll() { refreshGizmo(); redraw() }
    }

    /// Edit ▸ Invert Selection — selects the selectable complement and repaints.
    func invertSelectionEntities() {
        if model.invertSelection() { refreshGizmo(); redraw() }
    }

    // MARK: Select Connected / Contour (wire-wave-2)

    /// The SEED a Select-Connected / Select-Contour traversal grows from: the single
    /// currently-selected entity if there is exactly one, else the entity under the
    /// cursor (the hover target, falling back to a hit-test at the last cursor world
    /// point). `nil` when there is no unambiguous seed (empty/multi selection with
    /// nothing under the cursor). Pure read of the model's selection + hover state.
    private func selectionSeed() -> EntityID? {
        if model.selection.ids.count == 1, let only = model.selection.ids.first {
            return only
        }
        if let hovered = model.hoverID { return hovered }
        guard let world = model.cursorWorld else { return nil }
        return model.selection.hitTest(
            worldPoint: world, worldTolerance: model.worldTolerance,
            in: model.drawing, using: model.quadtree
        )
    }

    /// Whether a Select-Connected / Select-Contour traversal has a seed to grow from
    /// (drives the Edit-menu items' enabled state via `validateUserInterfaceItem`).
    var hasSelectionSeed: Bool { selectionSeed() != nil }

    /// Edit ▸ Select Connected — replace the selection with the seed's connected
    /// component (every entity transitively sharing an endpoint with the seed), via
    /// the pure engine `SelectionTraversal.connected`. No-op (no seed) leaves the
    /// selection unchanged.
    func selectConnectedFromSeed() {
        guard let seed = selectionSeed() else { return }
        let ids = SelectionTraversal.connected(
            seed: seed, in: model.drawing, using: model.quadtree)
        applyTraversalSelection(ids)
    }

    /// Edit ▸ Select Contour — replace the selection with the closed contour loop the
    /// seed belongs to, via the pure engine `SelectionTraversal.contour`. A seed that
    /// is NOT part of a closed loop yields `nil` → no change (a clean no-op).
    func selectContourFromSeed() {
        guard let seed = selectionSeed() else { return }
        guard let ids = SelectionTraversal.contour(
            seed: seed, in: model.drawing, using: model.quadtree) else { return }
        applyTraversalSelection(ids)
    }

    /// Sets the result of a Select-Connected / Select-Contour traversal as the new
    /// selection on the model (view-side state, no undo — like the other Select verbs)
    /// and repaints the highlight + re-glues the gizmo. No-op for an empty result.
    private func applyTraversalSelection(_ ids: Set<EntityID>) {
        guard !ids.isEmpty else { return }
        model.setSelection(ids)
        refreshGizmo()
        redraw()
    }

    /// View ▸ Ortho — flips the persistent ortho restriction and repaints (the
    /// status-bar chip + any active rubber-band preview reflect it on the next move).
    func toggleOrtho() {
        model.toggleOrtho()
        redraw()
    }

    // MARK: - Zoom window + Zoom previous (F23, View menu)

    /// World anchor of an in-progress zoom-window drag (the box's first corner), or
    /// `nil` when no zoom-window box is being dragged. Set on a zoom-window-armed
    /// mouse-down, spanned on each drag, cleared on commit/cancel.
    private var zoomWindowAnchorWorld: Vector?

    /// Whether a zoom-window box drag is currently in progress (so the view's
    /// mouse-up commits the zoom instead of the click/marquee/pan classification).
    var isZoomWindowDragActive: Bool { zoomWindowAnchorWorld != nil }

    /// Whether the canvas is armed for a zoom-window drag (the next empty drag draws
    /// the zoom box). Read by the view to route a drag to the zoom-box gesture.
    var isZoomWindowArmed: Bool { model.zoomWindowArmed }

    /// View ▸ Zoom Window — arm the transient drag-box zoom. The NEXT drag draws a
    /// box; releasing zooms the view to fit it, then auto-exits the mode. Repaints so
    /// a status chip / cursor change can reflect the armed state.
    func enterZoomWindow() {
        // Leaving any in-progress marquee + clearing hover keeps the gesture clean.
        cancelMarquee()
        model.setZoomWindowArmed(true)
        refreshCrosshair()
        redraw()
    }

    /// Starts the zoom-window box at a screen anchor (called by the view on a
    /// zoom-window-armed mouse-down). Records the world anchor + seeds the model box.
    func beginZoomWindowDrag(at screenPoint: CGPoint) {
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        zoomWindowAnchorWorld = world
        model.beginZoomWindow(at: world)
    }

    /// Updates the in-progress zoom-window box to span anchor→cursor, repainting the
    /// overlay. No-op if no zoom-window drag is active.
    func updateZoomWindowDrag(to screenPoint: CGPoint) {
        guard let anchor = zoomWindowAnchorWorld else { return }
        syncViewSizeFromView()
        let world = model.viewport.screenToWorld(screenPoint)
        model.updateZoomWindow(from: anchor, to: world)
        refreshMarquee()
        redraw()
    }

    /// Commits the in-progress zoom-window box: zooms the view to fit it and exits
    /// the mode (a one-shot gesture). A degenerate box (a click) just exits without
    /// zooming. Repaints. Returns whether a zoom-window drag was committed (so the
    /// view skips the click classification).
    @discardableResult
    func endZoomWindowDrag() -> Bool {
        guard zoomWindowAnchorWorld != nil else { return false }
        zoomWindowAnchorWorld = nil
        _ = model.commitZoomWindow()
        refreshGizmo()
        refreshCrosshair()
        refreshMarquee()
        redraw()
        return true
    }

    /// Cancels an in-progress zoom-window drag AND exits the mode without zooming
    /// (Esc / mouse-exit), repainting to erase the box.
    func cancelZoomWindow() {
        let wasActive = zoomWindowAnchorWorld != nil || model.zoomWindowArmed
        zoomWindowAnchorWorld = nil
        model.cancelZoomWindow()
        if wasActive {
            refreshCrosshair()
            refreshMarquee()
            redraw()
        }
    }

    /// View ▸ Zoom Previous — restore the most recent prior viewport, repainting.
    func zoomPrevious() {
        if model.zoomPrevious() { redraw() }
    }

    // MARK: - Arrange / revert direction (F16, Arrange menu + context menu)

    /// Arrange ▸ Bring to Front — raises the selection to the top of the draw order.
    func bringSelectionToFront() { if model.bringSelectionToFront() { redraw() } }
    /// Arrange ▸ Send to Back.
    func sendSelectionToBack() { if model.sendSelectionToBack() { redraw() } }
    /// Arrange ▸ Bring Forward (one step).
    func raiseSelection() { if model.raiseSelection() { redraw() } }
    /// Arrange ▸ Send Backward (one step).
    func lowerSelection() { if model.lowerSelection() { redraw() } }
    /// Arrange ▸ Revert Direction — flips the selection's defining direction.
    func revertSelectionDirection() {
        if model.revertSelectionDirection() { refreshGizmo(); redraw() }
    }

    /// Whether the selection can be arranged (drives the Arrange menu items' enabled
    /// state via the view's `validateUserInterfaceItem`).
    var canArrangeSelection: Bool { model.canArrangeSelection }
    /// Whether the selection has a revertible-direction entity.
    var canRevertSelectionDirection: Bool { model.canRevertSelectionDirection }

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
        let isF8 = event.keyCode == 100                            // F8 → toggle Ortho

        // F8 toggles ortho (AutoCAD/LibreCAD convention), in any mode and regardless
        // of modifiers, so a draw run can flip ortho mid-operation without leaving the
        // canvas. Handled before the tool keys so it never collides with a letter.
        if isF8 {
            toggleOrtho()
            return true
        }

        // Space (D1) hands focus to the bottom command/coordinate line (U1) while a
        // tool is active, so the user can type a precise coordinate/length without a
        // bare letter switching tools. Only claimed when a tool is active AND the
        // focus hook is wired (ContentView sets it); otherwise Space falls through.
        if isSpace, !command, model.isToolActive, let focus = requestCommandFocus {
            focus()
            return true
        }

        if isEscape {
            // Esc in zoom-window mode cancels the box + exits the mode (the gesture
            // is transient; nothing else changes).
            if isZoomWindowArmed || isZoomWindowDragActive {
                cancelZoomWindow()
                return true
            }
            // Esc on an in-progress marquee just cancels the box (keeps the mode +
            // selection), matching the cancel-the-gesture convention.
            if isMarqueeActive {
                cancelMarquee()
                return true
            }
            // Standard CAD Esc: it first CANCELS any in-progress operation, and only
            // when nothing is in progress does it CLEAR the selection — so the canvas
            // unwinds one step at a time to a clean idle state.
            if model.isToolActive {
                // A draw/edit tool is mid-run: cancel the run + drop to select mode
                // (the in-progress operation is the thing Esc unwinds; the selection
                // is left alone, matching "Esc cancels the current op first").
                model.handleToolInput(.cancel)
                model.activateTool(.select)
                // Dropping to select mode hides the crosshair + restores the arrow.
                refreshCrosshair()
                redraw()
                return true
            }
            // Already idle in select mode: Esc clears the current selection, returning
            // the canvas to a clean idle state (CanvasModel.deselectAll). Re-glue the
            // gizmo (which is selection-bound) and repaint the highlight.
            if model.deselectAll() {
                refreshGizmo()
                redraw()
                return true
            }
            // Nothing to cancel and nothing selected: Esc is a harmless no-op but we
            // still claim it (re-asserting select mode) so it never beeps mid-canvas.
            model.activateTool(.select)
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
        // Option chords (the third tier, after bare + ⇧) — handled before the
        // bare-letter switch so e.g. ⌥S does NOT fall through to S (Spline). ⌥ is
        // reserved for tools whose bare/⇧ letter twins are both taken:
        //   ⌥S Stretch · ⌥O Ordinate dim · ⌥G Arc-length dim · ⌥N Angular-3p dim ·
        //   ⌥B Create Block · ⌥X Explode Block (wire-wave-2).
        // Any other option combo is left for the responder chain.
        if option {
            guard !command else { return false }
            switch chars {
            case "s": activateTool(.stretch);        return true
            case "o": activateTool(.ordinateDim);    return true
            case "g": activateTool(.arcLengthDim);   return true
            case "n": activateTool(.angular3pDim);   return true
            case "b":
                // ⌥B "Create Block from Selection…" raises the View-layer NAME sheet
                // (WAVE BW, Ask #1 — spec §2.1), not a bare `activateTool(.createBlock)`
                // (which would skip naming). Gated on a selection inside the hook.
                requestCreateBlockFromSelection?()
                return true
            case "x": activateTool(.explodeInsert);  return true
            default:  return false
            }
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
            // Bare P = Polyline (draw); ⇧P = Edit Polyline (modify, wire-wave-D) —
            // free shift chord (bare P has no other shift twin).
            activateTool(shift ? .polylineEdit : .polyline)
            return true
        case "o":
            // Bare O = Point (draw); ⇧O = Offset (modify) — the shared-letter
            // shift convention (like ⇧C/⇧R/⇧M).
            activateTool(shift ? .offset : .point)
            return true
        case "e":
            // Bare E = Ellipse (draw); ⇧E = Explode Text (modify, wire-wave-1) —
            // free shift chord (bare E has no other shift twin).
            activateTool(shift ? .explodeText : .ellipse)
            return true
        case "g":
            activateTool(.polygon)
            return true
        case "j":
            // ⇧J = Join (modify, wire-wave-1) — fuse touching lines/arcs into a
            // polyline. Bare J is unassigned (no draw/edit twin); claim only ⇧J.
            if shift {
                activateTool(.join)
                return true
            }
            return false
        case "k":
            // ⇧K = Measure Distance (read-only info tool, wire-wave-1). The other
            // measure modes (angle/area/total-length) are menu/⌘K only — no key.
            // Bare K is unassigned; claim only ⇧K.
            if shift {
                activateTool(.measureDistance)
                return true
            }
            return false
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
