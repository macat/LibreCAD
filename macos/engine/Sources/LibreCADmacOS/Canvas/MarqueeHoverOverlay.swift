//
//  MarqueeHoverOverlay.swift
//  LibreCADmacOS
//
//  The MARQUEE (rubber-band selection box) + HOVER highlight overlay (UX-plan U5,
//  gap G8) — a screen-space AppKit overlay floated OVER the Metal canvas that draws:
//    • the live selection rectangle while the user drags on empty space in select
//      mode — BLUE + solid for a WINDOW box (left→right drag, only fully-enclosed
//      entities), GREEN + dashed for a CROSSING box (right→left drag, any touched);
//      both standard CAD colors, and
//    • a faint HIGHLIGHT on the entity under the cursor (the pre-selection
//      affordance), distinct from the selected color.
//
//  ## Why a screen-space AppKit overlay (mirrors Crosshair/Gizmo's rationale)
//  The marquee box must stay a crisp constant-width outline and track the cursor on
//  every move; the hover highlight must redraw cheaply as the cursor moves. An
//  `NSView` subview whose `hitTest` ALWAYS returns `nil` gives both for free and
//  keeps the marquee/hover entirely out of the GPU buffer-build path (`LineRenderer`
//  and `OverlayGeometry` are untouched). It is the SAME pattern the crosshair +
//  transform gizmo use; the controller owns it alongside them, keeps it covering the
//  canvas, and repaints it from the model's `marqueeRect` / `hoverID` on every move.
//
//  ## Source of truth
//  The box geometry + window/crossing flag live on the model (`marqueeRect`,
//  `marqueeCrossing`), set by the canvas drag; the hover target is `model.hoverID`.
//  This view only maps world→screen (`worldToScreen`) and strokes — no extra state.
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

// MARK: - The marquee + hover overlay view

/// A transparent, click-through `NSView` drawn over the canvas that renders the live
/// marquee selection box and the hover highlight. Added as a subview of the
/// `FlippedMTKView` and kept covering the canvas bounds; the controller calls
/// `refresh()` whenever the marquee / hover / viewport changes.
@MainActor
final class MarqueeHoverOverlayView: NSView {

    /// The shared canvas state (marquee rect + crossing flag, hover id, viewport).
    private let model: CanvasModel

    init(model: CanvasModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same flipped (top-left, Y-down) space as the host `FlippedMTKView`, so
    /// `worldToScreen` points land directly without a Y flip.
    override var isFlipped: Bool { true }

    // MARK: Colors (standard CAD window/crossing + a subtle hover)

    /// WINDOW box (left→right, fully-enclosed) — blue outline, faint blue fill.
    private static let windowStroke = NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 0.95)
    private static let windowFill   = NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 0.12)
    /// CROSSING box (right→left, any touched) — green dashed outline, faint green fill.
    private static let crossingStroke = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 0.95)
    private static let crossingFill   = NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 0.12)
    /// HOVER highlight — a soft accent, distinct from the amber selection color.
    private static let hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.85)
    private static let hoverLineWidth: CGFloat = 2.5

    // MARK: Click-through

    /// ALWAYS transparent to clicks: the marquee + hover are pure chrome, so every
    /// click / drag falls through to the canvas (the FlippedMTKView owns the marquee/
    /// click/pan gesture). Returning `nil` here is what makes it click-through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Refresh

    /// Repaints the overlay. Called by the controller on every cursor move and on any
    /// marquee / hover / viewport change. Cheap: a rect + a few polylines.
    func refresh() { needsDisplay = true }

    // MARK: Screen mapping

    private func screen(_ world: Vector) -> CGPoint { model.viewport.worldToScreen(world) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHover()        // under the box, so a marquee outline reads on top
        drawMarquee()
    }

    /// Strokes the hover highlight over the entity under the cursor (select mode), in
    /// the accent color — a subtle, distinct-from-selected pre-selection cue. Skipped
    /// when nothing is hovered or the hovered entity vanished.
    private func drawHover() {
        guard let id = model.hoverID,
              let record = model.drawing.entity(id),
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Do not double-draw the hover on an already-selected entity (the Metal
        // selection highlight already marks it) — keeps the cue meaning "not yet
        // selected".
        if model.selection.contains(id) { return }

        let geo = record.resolve(model.drawing.makeResolveContext())
        ctx.saveGState()
        ctx.setStrokeColor(Self.hoverColor.cgColor)
        ctx.setLineWidth(Self.hoverLineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for poly in geo.polylines {
            let pts = poly.points
            guard pts.count >= 2 else {
                // Single point → a small marker so a point entity is still hoverable.
                if let only = pts.first {
                    let s = screen(only)
                    ctx.addEllipse(in: CGRect(x: s.x - 3, y: s.y - 3, width: 6, height: 6))
                }
                continue
            }
            ctx.move(to: screen(pts[0]))
            for i in 1..<pts.count { ctx.addLine(to: screen(pts[i])) }
            if poly.closed, pts.count >= 3 { ctx.addLine(to: screen(pts[0])) }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Strokes the live marquee selection box — blue solid for window, green dashed
    /// for crossing — with a faint fill so the box reads over busy geometry. Skipped
    /// when no marquee is in progress.
    private func drawMarquee() {
        guard let rect = model.marqueeRect, !rect.isEmpty,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        // World AABB → screen rect (flipped Y-down: world min/max map to screen
        // corners whose order may swap, so take the min/abs to build a positive rect).
        let a = screen(rect.min)
        let b = screen(rect.max)
        let r = CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
                       width: abs(a.x - b.x), height: abs(a.y - b.y))

        let crossing = model.marqueeCrossing
        let stroke = crossing ? Self.crossingStroke : Self.windowStroke
        let fill = crossing ? Self.crossingFill : Self.windowFill

        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(1)
        if crossing { ctx.setLineDash(phase: 0, lengths: [5, 3]) }
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))   // crisp 1pt outline
        ctx.restoreGState()
    }
}
