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

    init(model: CanvasModel) {
        self.model = model
    }

    func attach(view: FlippedMTKView, renderer: LineRenderer) {
        self.view = view
        self.renderer = renderer
    }

    // MARK: Redraw helpers

    private func redraw() { view?.setNeedsDisplay(view?.bounds ?? .zero) }

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
        // Redraw the coordinate HUD + snap marker (and tool preview) on every move
        // (overlay-only; the model instance buffer is untouched — §5).
        redraw()
    }

    func mouseExited() {
        model.clearCursor()
        redraw()
    }

    /// A classified click (down→up with negligible travel). With a draw tool
    /// active it feeds the tool a snapped `.click`; otherwise it toggles selection.
    /// (A larger-travel down→up is a pan and is handled by `panDrag`, NOT here.)
    func mouseClick(at point: CGPoint) {
        syncViewSizeFromView()
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

    // MARK: Tool activation + keyboard

    /// Switches the active tool (toolbar/menu/keyboard). Redraws so the preview /
    /// status clears or appears.
    func activateTool(_ kind: ToolKind) {
        model.activateTool(kind)
        redraw()
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
        // Esc is key code 53 (no reliable character).
        let isEscape = event.keyCode == 53
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return / keypad Enter
        let isDelete = event.keyCode == 51 || event.keyCode == 117 // Delete / Forward-Delete

        if isEscape {
            // Cancel any in-progress run, then drop to select mode.
            if model.isToolActive { model.handleToolInput(.cancel) }
            model.activateTool(.select)
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
        // Bare letter keys (no command modifier) activate tools. Shift selects the
        // modify variant where a draw tool shares the letter (C/R/S/M/O).
        guard !command else { return false }
        switch chars {
        case "v":
            activateTool(.select)
            return true
        case "l":
            activateTool(.line)
            return true
        case "c":
            activateTool(shift ? .copy : .circle)
            return true
        case "a":
            activateTool(.arc)
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
            // No bare-S draw tool; ⇧S is Scale. A bare S is unassigned (falls
            // through) so a future draw tool can claim it.
            if shift { activateTool(.scale); return true }
            return false
        case "t":
            // Edit tool: Trim (no draw/modify twin → plain T).
            activateTool(.trim)
            return true
        case "x":
            // Edit tool: Extend (no draw/modify twin → plain X).
            activateTool(.extend)
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
        view.clearColor = MTLClearColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
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
        nsView.setNeedsDisplay(nsView.bounds)
    }
}
