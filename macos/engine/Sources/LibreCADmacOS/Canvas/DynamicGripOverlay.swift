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

    // MARK: Colors (match the gizmo accent so the chrome reads as one UI)

    private static let chipFill   = NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.0, alpha: 1.0)
    private static let chipStroke = NSColor.white
    private static let glyphColor = NSColor.white

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
        if model.singleSelectedDynamicInsert != nil, let box = model.selectionWorldBounds {
            // Anchor at the box's top-right corner (world max.x / max.y).
            anchorWorld = Vector(box.max.x, box.max.y)
        } else {
            anchorWorld = nil
        }
        isHidden = (anchorWorld == nil)
        needsDisplay = true
    }

    /// Whether the grip currently has something to show (a single dynamic insert selected).
    var isActive: Bool { anchorWorld != nil }

    // MARK: Screen mapping

    private func screen(_ world: Vector) -> CGPoint { model.viewport.worldToScreen(world) }

    /// The chip's screen-space rect (in our flipped, Y-down space), or `nil` when hidden.
    private func chipRect() -> CGRect? {
        guard let a = anchorWorld else { return nil }
        let s = screen(a)
        let origin = CGPoint(x: s.x + Self.chipOffset.width,
                             y: s.y + Self.chipOffset.height)
        return CGRect(x: origin.x, y: origin.y, width: Self.chipWidth, height: Self.chipHeight)
    }

    // MARK: Hit-testing (transparent except over the grip)

    /// `hitTest` returns this view ONLY when the point is over the dropdown chip (so it can
    /// own the click); otherwise `nil`, letting the click fall through to the canvas
    /// (selection / drawing) unchanged — exactly the gizmo overlay's contract.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let rect = chipRect() else { return nil }
        let local = convert(point, from: superview)
        return rect.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(local) ? self : nil
    }

    // MARK: Mouse handling (click → state-pick menu)

    override func mouseDown(with event: NSEvent) {
        guard let rect = chipRect() else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        guard rect.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(p) else {
            super.mouseDown(with: event); return
        }
        presentStateMenu(at: event)
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
        guard let rect = chipRect(), let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The rounded chip body.
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

        // A down-chevron glyph centered in the chip (the dropdown affordance, §13.5).
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
}
