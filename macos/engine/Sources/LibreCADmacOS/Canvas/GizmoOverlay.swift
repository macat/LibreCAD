//
//  GizmoOverlay.swift
//  LibreCADmacOS
//
//  The on-canvas TRANSFORM GIZMO — a screen-space AppKit overlay floated OVER the
//  Metal canvas that, when entities are selected in Select mode, draws direct-
//  manipulation handles around the selection's bounding box and lets the user
//  move / scale / rotate the selection by DRAGGING (no tool to pick first — a
//  modern-UX hallmark).
//
//  ## Why a screen-space AppKit overlay (not the Metal overlay renderer)
//  The gizmo chrome (the frame outline, the four corner squares, the rotate stalk
//  + knob) must stay a CONSTANT on-screen size across zoom, and the overlay must
//  be transparent to clicks that are NOT on a handle (so clicking empty space or
//  another entity behaves exactly as today). An `NSView` subview whose `hitTest`
//  returns itself ONLY when the cursor is over a handle gives both for free, and
//  keeps the gizmo entirely out of the GPU buffer-build path (`LineRenderer` is
//  untouched). The handle positions come from `worldToScreen` of the selection
//  bounds and are recomputed on every pan/zoom via `refresh()`.
//
//  ## The math lives in CADEngine (`GizmoTransform`)
//  This view does ONLY screen↔world mapping + hit-testing. Every transform —
//  the translation for a body drag, the uniform scale about the opposite corner
//  for a corner drag, the rotation about the box center for a knob drag — is built
//  by the pure, unit-tested `GizmoTransform` from the drag's world endpoints, so a
//  gizmo edit produces the SAME geometry as the equivalent Move/Rotate/Scale tool.
//
//  ## Commit path (one undoable edit)
//  During a drag the view publishes a live preview transform to the model
//  (`setGizmoPreview`) and repaints the dragged geometry; on mouse-up it commits
//  ONE undoable edit via `CanvasModel.commitGizmoTransform` (which applies the
//  transform to each selected entity and routes the full-record replacements
//  through `applyInspectorEdits` — the same undoable path the Inspector uses), so a
//  single ⌘Z reverts the whole drag. Hold ⇧ for a constrained drag (axis-locked
//  move / 15° rotation snap).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it under
//  the terms of the GNU General Public License version 2 or (at your option) any
//  later version.
//

import AppKit
import CADEngine

// MARK: - The gizmo overlay view

/// A transparent `NSView` drawn over the canvas that renders + hit-tests the
/// selection transform gizmo. It is added as a subview of the `FlippedMTKView`,
/// kept covering the canvas bounds, and shown ONLY when there is a non-empty
/// selection in Select mode (the controller toggles `isHidden` / calls `refresh()`).
@MainActor
final class GizmoOverlayView: NSView {

    /// The shared canvas state (selection, viewport, commit path).
    private let model: CanvasModel

    /// Repaint the underlying Metal canvas (the controller's `requestRedraw`), so
    /// the dragged geometry preview the model publishes is drawn while dragging.
    private let requestCanvasRedraw: () -> Void

    /// The last computed gizmo frame in WORLD coordinates (Y-up). `nil` when there
    /// is nothing to show.
    private var frame3D: GizmoFrame?

    /// The in-progress drag, or `nil` when idle.
    private var activeDrag: Drag?

    /// One live drag of a gizmo handle.
    private struct Drag {
        /// Which handle is grabbed.
        let handle: GizmoHandle
        /// The gizmo frame captured at mouse-down (the drag math is relative to it,
        /// so it stays stable even as the live preview moves the geometry).
        let frame: GizmoFrame
        /// The drag's START world point. For a corner drag this is the corner's own
        /// world position (so the scale factor is exact); for move/rotate it is the
        /// world point under the cursor at mouse-down.
        let startWorld: Vector
    }

    // MARK: Geometry constants (screen points)

    /// Half-size of a corner handle square (points). The full square is 2×.
    private static let handleHalf: CGFloat = 5
    /// Radius of the rotate knob circle (points).
    private static let knobRadius: CGFloat = 6
    /// Length of the stalk from the top edge up to the rotate knob (points).
    private static let knobStalk: CGFloat = 26
    /// Click slop added around a handle's drawn size for easier grabbing (points).
    private static let hitSlop: CGFloat = 4

    // MARK: Colors (match the Metal overlay accent so the gizmo reads as one UI)

    private static let frameColor   = NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.0, alpha: 0.9)  // cyan accent
    private static let handleFill   = NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.0, alpha: 1.0)
    private static let handleStroke = NSColor.white
    private static let previewColor = NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.55, alpha: 0.95) // matches toolPreview

    // MARK: Init

    init(model: CanvasModel, requestCanvasRedraw: @escaping () -> Void) {
        self.model = model
        self.requestCanvasRedraw = requestCanvasRedraw
        super.init(frame: .zero)
        wantsLayer = true
        // The overlay paints nothing opaque; only the chrome lines/handles.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The overlay is in the SAME flipped (top-left, Y-down) space as the host
    /// `FlippedMTKView`, so `worldToScreen` points land directly without a Y flip.
    override var isFlipped: Bool { true }

    // MARK: Visibility + refresh

    /// Recomputes the world frame from the model's selection bounds and repaints.
    /// Hides the overlay when there is no selection (so it never blocks clicks).
    /// Called by the controller on selection / pan / zoom change.
    func refresh() {
        frame3D = model.selectionWorldBounds.flatMap { GizmoFrame(box: $0) }
        isHidden = (frame3D == nil)
        needsDisplay = true
    }

    /// Whether the gizmo currently has something to show (a non-empty selection).
    var isActive: Bool { frame3D != nil }

    /// Whether a gizmo drag is currently in progress (so the controller can let the
    /// gizmo own the gesture and suppress its own click/pan handling).
    var isDragging: Bool { activeDrag != nil }

    // MARK: Screen mapping helpers

    private func screen(_ world: Vector) -> CGPoint { model.viewport.worldToScreen(world) }
    private func world(_ screen: CGPoint) -> Vector { model.viewport.screenToWorld(screen) }

    /// The rotate-knob CENTER in screen points: above the top edge's screen midpoint
    /// by `knobStalk` (screen Y-down, so "above" is a SMALLER y).
    private func knobScreenCenter(_ f: GizmoFrame) -> CGPoint {
        let topMidWorld = Vector((f.min.x + f.max.x) * 0.5, f.max.y)
        let s = screen(topMidWorld)
        return CGPoint(x: s.x, y: s.y - Self.knobStalk)
    }

    // MARK: Hit-testing (transparent except over a handle)

    /// The handle (if any) under a screen point. Corners first (most specific),
    /// then the rotate knob, then the body (inside the frame) for move.
    private func handle(at p: CGPoint) -> GizmoHandle? {
        guard let f = frame3D else { return nil }

        // Corners.
        for c in GizmoHandle.Corner.allCases {
            let cs = screen(f.corner(c))
            if abs(p.x - cs.x) <= Self.handleHalf + Self.hitSlop,
               abs(p.y - cs.y) <= Self.handleHalf + Self.hitSlop {
                return .corner(c)
            }
        }

        // Rotate knob.
        let knob = knobScreenCenter(f)
        let dk = hypot(p.x - knob.x, p.y - knob.y)
        if dk <= Self.knobRadius + Self.hitSlop { return .rotate }

        // Body (inside the frame rect in screen space) → move.
        let r = screenFrameRect(f)
        if r.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(p) { return .move }

        return nil
    }

    /// `hitTest` returns this view ONLY when the point is over a handle (so it can
    /// own the drag); otherwise `nil`, letting the click fall through to the canvas
    /// (selection / drawing) unchanged. A drag in progress keeps the gesture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame3D != nil else { return nil }
        // `point` is in the SUPERVIEW's coordinate space; convert to ours.
        let local = convert(point, from: superview)
        if activeDrag != nil { return self }
        return handle(at: local) != nil ? self : nil
    }

    // MARK: Mouse handling (the drag lifecycle)

    override func mouseDown(with event: NSEvent) {
        guard let f = frame3D else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        guard let h = handle(at: p) else { super.mouseDown(with: event); return }

        // The drag start world point: for a corner, the corner's own world position
        // (exact scale factor); for move/rotate, the cursor's world point.
        let startWorld: Vector
        switch h {
        case .corner(let c): startWorld = f.corner(c)
        default:             startWorld = world(p)
        }
        activeDrag = Drag(handle: h, frame: f, startWorld: startWorld)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = activeDrag else { super.mouseDragged(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let cursorWorld = world(p)
        let shift = event.modifierFlags.contains(.shift)
        let t = transform(for: drag, cursorWorld: cursorWorld, shift: shift)
        model.setGizmoPreview(t)
        // Repaint our chrome (drawn at the dragged transform) AND the canvas (which
        // draws the dragged geometry preview the model publishes).
        needsDisplay = true
        requestCanvasRedraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = activeDrag else { super.mouseUp(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let cursorWorld = world(p)
        let shift = event.modifierFlags.contains(.shift)
        let t = transform(for: drag, cursorWorld: cursorWorld, shift: shift)
        activeDrag = nil
        // Commit ONE undoable edit (no-op for a zero-effect drag). This clears the
        // live preview inside the model too.
        _ = model.commitGizmoTransform(t)
        // The selection bounds moved → recompute the frame, repaint chrome + canvas.
        refresh()
        requestCanvasRedraw()
    }

    // MARK: Drag → transform (delegates the math to GizmoTransform)

    /// Builds the `Affine2D` for the current drag from its world endpoints.
    private func transform(for drag: Drag, cursorWorld: Vector, shift: Bool) -> Affine2D {
        switch drag.handle {
        case .move:
            return GizmoTransform.move(from: drag.startWorld, to: cursorWorld, constrained: shift)
        case .corner(let c):
            return GizmoTransform.cornerScale(frame: drag.frame, corner: c,
                                              from: drag.startWorld, to: cursorWorld)
        case .rotate:
            return GizmoTransform.rotate(frame: drag.frame, from: drag.startWorld,
                                         to: cursorWorld, snap: shift)
        }
    }

    // MARK: Drawing

    /// The selection frame as a screen-space rect (in our flipped, Y-down space).
    private func screenFrameRect(_ f: GizmoFrame) -> CGRect {
        let a = screen(f.bottomLeft)   // world min → screen (Y-down → larger y)
        let b = screen(f.topRight)     // world max → screen (Y-down → smaller y)
        let x = Swift.min(a.x, b.x)
        let y = Swift.min(a.y, b.y)
        return CGRect(x: x, y: y, width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let f = frame3D, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // During a drag, draw the dragged geometry preview (the selection at the
        // live transform) as green polylines, matching the tool-preview look.
        if activeDrag != nil {
            drawPreview(in: ctx)
        }

        // The frame outline (dashed) + corner squares + rotate stalk/knob, drawn as
        // an ORIENTED QUAD using the SAME transform the object preview re-resolves
        // each entity with — so the chrome rotates/scales WITH the object during a
        // drag instead of collapsing back to an upright AABB. Idle (no live
        // transform) this is identity, so the quad is the plain base AABB.
        let t = model.gizmoPreviewTransform ?? .identity
        let base = activeDrag?.frame ?? f
        // World quad in [bottomLeft, bottomRight, topRight, topLeft] order, mapped
        // to screen via the existing projection.
        let quadScreen = GizmoTransform.transformedQuad(base: base, t: t).map { screen($0) }

        // Frame outline — a closed quad (was an AABB rect, which threw away rotation).
        ctx.saveGState()
        ctx.setStrokeColor(Self.frameColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: quadScreen[0])
        ctx.addLine(to: quadScreen[1])
        ctx.addLine(to: quadScreen[2])
        ctx.addLine(to: quadScreen[3])
        ctx.closePath()
        ctx.strokePath()
        ctx.restoreGState()

        // Rotate stalk + knob — anchored on the ORIENTED top edge, rising along the
        // outward normal so the stalk turns with the box. The knob stays a fixed
        // on-screen distance up that direction (independent of zoom).
        let anchor = GizmoTransform.transformedKnobAnchor(base: base, t: t)
        let rootScreen = screen(anchor.root)
        // Outward direction in SCREEN space: project root and root+outward, take the
        // screen delta, normalize. (Handles the flipped Y-down overlay automatically.)
        let outScreen = screen(anchor.root + anchor.outward)
        var dir = CGPoint(x: outScreen.x - rootScreen.x, y: outScreen.y - rootScreen.y)
        let dirLen = hypot(dir.x, dir.y)
        if dirLen > 1e-9 {
            dir = CGPoint(x: dir.x / dirLen, y: dir.y / dirLen)
        } else {
            // Degenerate transformed top edge → fall back to straight up (screen Y-up).
            dir = CGPoint(x: 0, y: -1)
        }
        let knob = CGPoint(x: rootScreen.x + dir.x * Self.knobStalk,
                           y: rootScreen.y + dir.y * Self.knobStalk)
        ctx.saveGState()
        ctx.setStrokeColor(Self.frameColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: rootScreen)
        // Stop the stalk at the knob's edge (not its center) so it reads cleanly.
        ctx.addLine(to: CGPoint(x: knob.x - dir.x * Self.knobRadius,
                                y: knob.y - dir.y * Self.knobRadius))
        ctx.strokePath()
        ctx.restoreGState()

        drawKnob(at: knob, in: ctx)

        // Corner handles — at the 4 ORIENTED screen corners.
        for p in quadScreen {
            drawHandleSquare(at: p, in: ctx)
        }
    }

    private func drawHandleSquare(at p: CGPoint, in ctx: CGContext) {
        let r = CGRect(x: p.x - Self.handleHalf, y: p.y - Self.handleHalf,
                       width: Self.handleHalf * 2, height: Self.handleHalf * 2)
        ctx.setFillColor(Self.handleFill.cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(Self.handleStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r)
    }

    private func drawKnob(at p: CGPoint, in ctx: CGContext) {
        let r = CGRect(x: p.x - Self.knobRadius, y: p.y - Self.knobRadius,
                       width: Self.knobRadius * 2, height: Self.knobRadius * 2)
        ctx.setFillColor(Self.handleFill.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(Self.handleStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: r)
    }

    /// Draws the model's live gizmo preview polylines (selection at the dragged
    /// transform) as green lines in screen space.
    private func drawPreview(in ctx: CGContext) {
        let polys = model.gizmoPreviewPolylines
        guard !polys.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(Self.previewColor.cgColor)
        ctx.setLineWidth(1.5)
        for poly in polys {
            let pts = poly.points
            guard pts.count >= 2 else { continue }
            ctx.move(to: screen(pts[0]))
            for i in 1..<pts.count { ctx.addLine(to: screen(pts[i])) }
            if poly.closed, pts.count >= 3 { ctx.addLine(to: screen(pts[0])) }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
