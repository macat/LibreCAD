//
//  DynamicGripOverlay.swift
//  LibreCADmacOS
//
//  The on-canvas DYNAMIC-BLOCK VISIBILITY GRIP — a screen-space AppKit overlay floated
//  OVER the Metal canvas that, when a SINGLE dynamic-block insert is selected, draws an
//  AutoCAD-style DOWN-ARROW (dropdown) grip near the insert. Clicking the grip pops an
//  `NSMenu` of the block's visibility-state names; choosing one switches that insert's
//  active state (block-features §9.4, §13.5 "Down-Arrow (Dropdown)").
//
//  ## Why a clone of GizmoOverlayView (and not an edit of it)
//  This mirrors `GizmoOverlayView`'s contract EXACTLY — a transparent flipped `NSView`
//  hosted as a canvas subview, `hitTest` returning self ONLY over the grip (so clicks
//  elsewhere fall through to selection/draw unchanged), and the same `refresh()` /
//  `isHidden` lifecycle the controller drives on selection/pan/zoom. The only behavioral
//  difference from the gizmo is WHAT a hit does: the visibility grip is a CLICK→menu, not
//  a drag (§13.5) — so there is no drag math, no live preview, no `GizmoTransform`. It is
//  a NEW sibling file (the gizmo is untouched, per the DB-1W brief).
//
//  ## Dual-overlay arbitration (critic must-fix)
//  When the single selection IS a dynamic insert, the controller's `refreshGizmo`
//  SUPPRESSES the transform gizmo (`gizmo.isHidden = true` + `clearGizmoPreview`) and
//  shows ONLY this overlay — so two transparent overlays never fight over an ambiguous
//  hit-test. For any other selection this overlay is hidden and the gizmo behaves exactly
//  as today. The decision is the pure `CanvasModel.shouldSuppressGizmoForSelection`.
//
//  ## Commit path (one undoable edit)
//  Choosing a state calls `CanvasModel.setInsertVisibilityState`, which writes
//  `InsertData.dynamic.activeVisibilityState` through the same undoable `applyInspectorEdits`
//  funnel the Inspector/gizmo use, then asks the canvas to repaint so the re-resolve shows
//  the new variant. The `NSMenu` lives ONLY here in the View layer (never reachable from a
//  unit test — the headless-modal rule); the testable decision logic is pure model state.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it under the
//  terms of the GNU General Public License version 2 or (at your option) any later version.
//

import AppKit
import CADEngine

// MARK: - The dynamic-block visibility grip overlay

/// A transparent `NSView` drawn over the canvas that renders + hit-tests the dynamic-block
/// visibility DROPDOWN grip. Added as a subview of the `FlippedMTKView`, kept covering the
/// canvas bounds, and shown ONLY when the single selection is a dynamic insert (the
/// controller toggles `isHidden` / calls `refresh()` from `refreshGizmo`).
@MainActor
final class DynamicGripOverlayView: NSView {

    /// The shared canvas state (selection, viewport, the undoable state-switch funnel).
    private let model: CanvasModel

    /// Repaint the underlying Metal canvas (the controller's `requestRedraw`) after a
    /// state switch re-resolves the insert to its new variant.
    private let requestCanvasRedraw: () -> Void

    /// The grip's WORLD anchor (top-right of the selected insert's bounds), or `nil`
    /// when there is nothing to show. Recomputed in `refresh()`.
    private var anchorWorld: Vector?

    /// The selected dynamic insert's PARAMETER grips (DB-2W), world-anchored, recomputed in
    /// `refresh()` from `model.singleSelectedDynamicInsertGrips`. Empty when the insert has
    /// no parameters (a visibility-only DB-1 block).
    private var paramGrips: [CanvasModel.DynamicInstanceGrip] = []

    /// The id of the selected dynamic insert (for the param-grip commit funnels), or `nil`.
    private var insertID: EntityID?

    /// The in-progress STRETCH drag (a square parameter grip), or `nil` when idle. A flip
    /// grip is a CLICK (no drag state) and the visibility chip pops a menu (no drag state).
    private var activeDrag: StretchDrag?

    /// One live stretch-grip drag: which linear parameter, and the grip captured at
    /// mouse-down (its world `base`/`end` stay stable so the projection math is relative
    /// to the value at grab time, exactly like the gizmo captures its frame).
    private struct StretchDrag {
        let parameterID: BlockParameterID
        let grip: CanvasModel.DynamicInstanceGrip
    }

    // MARK: Geometry constants (screen points)

    /// The drawn dropdown chip's width / height (points). A small rounded square holding
    /// a down-chevron glyph — the AutoCAD dropdown-grip affordance (§13.5).
    private static let chipWidth: CGFloat = 18
    private static let chipHeight: CGFloat = 16
    /// Offset of the chip from the selection's top-right corner (points, toward upper-right
    /// in screen space so it sits clear of the geometry).
    private static let chipOffset = CGSize(width: 10, height: -10)
    /// Click slop around the chip for easier grabbing (points).
    private static let hitSlop: CGFloat = 4

    /// Half-size of a square STRETCH grip (points); the full square is 2× (§13.5 square grip).
    private static let stretchHalf: CGFloat = 5
    /// Half-size of a triangle FLIP grip (points) — the AutoCAD flip-arrow affordance.
    private static let flipHalf: CGFloat = 7

    // MARK: Colors (match the gizmo accent so the chrome reads as one UI)

    private static let chipFill   = NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.0, alpha: 1.0)
    private static let chipStroke = NSColor.white
    private static let glyphColor = NSColor.white
    /// Stretch/flip grip fill + stroke (the same cyan accent the gizmo handles use).
    private static let gripFill   = NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.0, alpha: 1.0)
    private static let gripStroke = NSColor.white
    /// The live drag preview line color (matches the gizmo/tool preview green).
    private static let previewColor = NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.55, alpha: 0.95)

    // MARK: Init

    init(model: CanvasModel, requestCanvasRedraw: @escaping () -> Void) {
        self.model = model
        self.requestCanvasRedraw = requestCanvasRedraw
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same flipped (top-left, Y-down) space as the host `FlippedMTKView`, so
    /// `worldToScreen` points land directly without a Y flip (matches the gizmo overlay).
    override var isFlipped: Bool { true }

    // MARK: Visibility + refresh

    /// Recomputes the grip anchor from the model's selection and repaints. Shown ONLY when
    /// the single selection is a dynamic insert (`singleSelectedDynamicInsert != nil`);
    /// hidden otherwise so it never blocks clicks. Called by the controller's `refreshGizmo`
    /// on selection / pan / zoom change.
    func refresh() {
        // A drag in progress keeps its captured grips/anchor stable until mouse-up.
        guard activeDrag == nil else { needsDisplay = true; return }

        // The visibility DROPDOWN chip (DB-1): shown when the insert carries states.
        if model.singleSelectedDynamicInsert != nil, let box = model.selectionWorldBounds {
            anchorWorld = Vector(box.max.x, box.max.y)   // top-right corner (world)
        } else {
            anchorWorld = nil
        }

        // The PARAMETER grips (DB-2W): square stretch + triangle flip, world-anchored.
        if let g = model.singleSelectedDynamicInsertGrips {
            insertID = g.id
            paramGrips = g.grips
        } else {
            insertID = nil
            paramGrips = []
        }

        isHidden = (anchorWorld == nil && paramGrips.isEmpty)
        needsDisplay = true
    }

    /// Whether the grip currently has something to show (a dropdown chip OR parameter grips).
    var isActive: Bool { anchorWorld != nil || !paramGrips.isEmpty }

    /// Whether a stretch-grip drag is currently in progress (so the controller lets this
    /// overlay own the gesture and skips its own refresh churn mid-drag).
    var isDragging: Bool { activeDrag != nil }

    // MARK: Screen mapping

    private func screen(_ world: Vector) -> CGPoint { model.viewport.worldToScreen(world) }
    private func world(_ screen: CGPoint) -> Vector { model.viewport.screenToWorld(screen) }

    /// The chip's screen-space rect (in our flipped, Y-down space), or `nil` when hidden.
    private func chipRect() -> CGRect? {
        guard let a = anchorWorld else { return nil }
        let s = screen(a)
        let origin = CGPoint(x: s.x + Self.chipOffset.width,
                             y: s.y + Self.chipOffset.height)
        return CGRect(x: origin.x, y: origin.y, width: Self.chipWidth, height: Self.chipHeight)
    }

    /// The screen-space hit rect for a parameter grip's world anchor (square stretch grip
    /// or triangle flip grip), sized for an easy grab.
    private func gripHitRect(_ grip: CanvasModel.DynamicInstanceGrip) -> CGRect {
        let s = screen(grip.anchor)
        let half: CGFloat = {
            switch grip {
            case .stretch: return Self.stretchHalf
            case .flip:    return Self.flipHalf
            }
        }() + Self.hitSlop
        return CGRect(x: s.x - half, y: s.y - half, width: half * 2, height: half * 2)
    }

    /// The parameter grip (if any) under a local screen point — searched before the chip so
    /// a grip near the chip still claims the drag/click. Returns the grip's INDEX.
    private func paramGripIndex(at p: CGPoint) -> Int? {
        for (i, grip) in paramGrips.enumerated() where gripHitRect(grip).contains(p) {
            return i
        }
        return nil
    }

    // MARK: Hit-testing (transparent except over a grip)

    /// `hitTest` returns this view ONLY when the point is over the dropdown chip OR a
    /// parameter grip (so it can own the click/drag); otherwise `nil`, letting the click
    /// fall through to the canvas (selection / drawing) unchanged — the gizmo's contract.
    /// A drag in progress keeps the gesture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if activeDrag != nil { return self }
        let local = convert(point, from: superview)
        if paramGripIndex(at: local) != nil { return self }
        if let rect = chipRect(),
           rect.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(local) { return self }
        return nil
    }

    // MARK: Mouse handling (square = drag, triangle = click toggle, chip = menu)

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        // 1) A PARAMETER grip (square stretch begins a drag; triangle flip toggles now).
        if let i = paramGripIndex(at: p) {
            switch paramGrips[i] {
            case .stretch(let pid, _, _, _):
                activeDrag = StretchDrag(parameterID: pid, grip: paramGrips[i])
                needsDisplay = true
            case .flip(let pid, _, _, _):
                if let id = insertID, model.toggleInsertFlip(id, parameter: pid) {
                    requestCanvasRedraw()
                    refresh()
                }
            }
            return
        }

        // 2) The visibility DROPDOWN chip → state menu (DB-1, unchanged).
        if let rect = chipRect(),
           rect.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(p) {
            presentStateMenu(at: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = activeDrag, let id = insertID else { super.mouseDragged(with: event); return }
        let cursorWorld = world(convert(event.locationInWindow, from: nil))
        guard let distance = model.stretchDistance(forGrip: drag.grip, cursorWorld: cursorWorld),
              var trial = model.insertDynamicState(id) else { return }
        trial.parameterValues[drag.parameterID.raw] = distance
        model.setInsertEvaluationPreview(id: id, state: trial)
        needsDisplay = true
        requestCanvasRedraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = activeDrag, let id = insertID else { super.mouseUp(with: event); return }
        let cursorWorld = world(convert(event.locationInWindow, from: nil))
        activeDrag = nil
        if let distance = model.stretchDistance(forGrip: drag.grip, cursorWorld: cursorWorld) {
            _ = model.commitInsertStretch(id, parameter: drag.parameterID, distance: distance)
        } else {
            model.clearInsertEvaluationPreview()
        }
        // The geometry moved → re-anchor the grips, repaint chrome + canvas.
        refresh()
        requestCanvasRedraw()
    }

    /// Esc cancels an in-progress stretch drag → revert to the committed value (drop the
    /// preview, re-anchor the grips). Matches the gizmo's cancel-on-Escape feel.
    override func cancelOperation(_ sender: Any?) {
        guard activeDrag != nil else { return }
        activeDrag = nil
        model.clearInsertEvaluationPreview()
        refresh()
        requestCanvasRedraw()
    }

    override func keyDown(with event: NSEvent) {
        // Escape (key code 53) cancels an in-progress drag.
        if event.keyCode == 53, activeDrag != nil { cancelOperation(nil); return }
        super.keyDown(with: event)
    }

    /// Pops the visibility-state `NSMenu` at the grip and applies the chosen state through
    /// the undoable funnel. The menu lives ONLY here in the View layer (never reachable
    /// from a unit test — headless-modal rule). A check marks the active state.
    private func presentStateMenu(at event: NSEvent) {
        guard let info = model.singleSelectedDynamicInsert else { return }
        let menu = NSMenu(title: "Visibility State")
        for state in info.states {
            let item = NSMenuItem(title: state.name,
                                  action: #selector(pickState(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = state.name
            // The active state (or the default state-0 when the insert names none) is checked.
            let effective = info.active ?? info.states.first?.name
            item.state = (state.name == effective) ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Menu action: switch the selected insert's active visibility state to the chosen
    /// name (undoable), then repaint so the re-resolve shows the new variant.
    @objc private func pickState(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let info = model.singleSelectedDynamicInsert else { return }
        if model.setInsertVisibilityState(info.id, to: name) {
            requestCanvasRedraw()
            needsDisplay = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // During a stretch drag, draw the insert RE-RESOLVED at the trial value as green
        // preview polylines (the same look as the gizmo's rubber-band).
        if activeDrag != nil { drawPreview(in: ctx) }

        // The PARAMETER grips (DB-2W): square per linear param, triangle per flip param.
        for grip in paramGrips { drawParamGrip(grip, in: ctx) }

        // The visibility DROPDOWN chip (DB-1), if present.
        if let rect = chipRect() { drawChip(rect, in: ctx) }
    }

    /// Draws one parameter grip: a filled square (stretch) or triangle (flip) at its
    /// screen anchor.
    private func drawParamGrip(_ grip: CanvasModel.DynamicInstanceGrip, in ctx: CGContext) {
        let s = screen(grip.anchor)
        switch grip {
        case .stretch:
            let half = Self.stretchHalf
            let r = CGRect(x: s.x - half, y: s.y - half, width: half * 2, height: half * 2)
            ctx.setFillColor(Self.gripFill.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(Self.gripStroke.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        case .flip(_, let lineStart, let lineEnd, _):
            drawFlipTriangle(at: s, lineStart: lineStart, lineEnd: lineEnd, in: ctx)
        }
    }

    /// Draws a small filled triangle (the flip-arrow affordance) at `center`, pointing
    /// ALONG the flip line's screen direction so it reads as a mirror handle.
    private func drawFlipTriangle(at center: CGPoint, lineStart: Vector, lineEnd: Vector,
                                  in ctx: CGContext) {
        let a = screen(lineStart), b = screen(lineEnd)
        var dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.0001)
        dx /= len; dy /= len                       // unit direction along the line (screen)
        let nx = -dy, ny = dx                       // perpendicular
        let h = Self.flipHalf
        // Tip ahead along the line; base two corners behind, spread along the perpendicular.
        let tip  = CGPoint(x: center.x + dx * h,        y: center.y + dy * h)
        let baseL = CGPoint(x: center.x - dx * h + nx * h, y: center.y - dy * h + ny * h)
        let baseR = CGPoint(x: center.x - dx * h - nx * h, y: center.y - dy * h - ny * h)
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: baseL)
        ctx.addLine(to: baseR)
        ctx.closePath()
        ctx.setFillColor(Self.gripFill.cgColor)
        ctx.fillPath()
        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: baseL)
        ctx.addLine(to: baseR)
        ctx.closePath()
        ctx.setStrokeColor(Self.gripStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// Draws the insert's live drag preview (its geometry re-resolved at the trial value),
    /// from `model.insertEvaluationPreview`, as green polylines in screen space.
    private func drawPreview(in ctx: CGContext) {
        let polys = model.insertEvaluationPreview
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

    /// Draws the visibility dropdown chip (the rounded body + the down-chevron glyph).
    private func drawChip(_ rect: CGRect, in ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(Self.chipFill.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(Self.chipStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
        drawDownChevron(in: rect, ctx: ctx)
    }

    /// Draws a small down-pointing chevron centered in `rect` (screen Y-down space, so a
    /// chevron pointing DOWN has its tip at the LARGER y).
    private func drawDownChevron(in rect: CGRect, ctx: CGContext) {
        let cx = rect.midX
        let topY = rect.midY - 3
        let botY = rect.midY + 3
        let half: CGFloat = 4
        ctx.saveGState()
        ctx.setStrokeColor(Self.glyphColor.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: cx - half, y: topY))
        ctx.addLine(to: CGPoint(x: cx, y: botY))
        ctx.addLine(to: CGPoint(x: cx + half, y: topY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The overlay must accept first-responder status so `keyDown`/`cancelOperation`
    /// (Escape-to-cancel a drag) reach it during a stretch drag.
    override var acceptsFirstResponder: Bool { activeDrag != nil }
}
