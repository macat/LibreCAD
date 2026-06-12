//
//  CrosshairOverlay.swift
//  LibreCADmacOS
//
//  The full-canvas CAD CROSSHAIR cursor (UX-plan U3, gap G3) — a screen-space
//  AppKit overlay floated OVER the Metal canvas that, while a drawing/edit tool is
//  active, draws two thin lines spanning the whole view centered on the cursor (or
//  the snapped point), plus a small box at the snap marker. It makes the active
//  draw mode unmistakable (HIG: "make the current mode obvious") and gives the
//  CAD-native precision affordance every CAD app has.
//
//  ## Why a screen-space AppKit overlay (mirrors GizmoOverlay's rationale)
//  The crosshair must stay a constant on-screen size, track the cursor on every
//  move, and must NOT intercept clicks (drawing/selection must work through it). An
//  `NSView` subview whose `hitTest` ALWAYS returns `nil` gives both for free and
//  keeps the crosshair entirely out of the GPU buffer-build path — `LineRenderer`
//  and `OverlayGeometry` are untouched, per the U3 constraint to prefer an AppKit
//  overlay over editing the renderer. It is the SAME pattern the transform gizmo
//  uses (a transparent flipped subview of the `FlippedMTKView`); the controller
//  owns it alongside the gizmo, keeps it sized to the canvas, and toggles its
//  visibility from `model.crosshairVisible`.
//
//  ## Cursor source of truth
//  The crosshair center is the SNAPPED point when the model has a snap result (so
//  the crosshair locks onto endpoints/centers/grid exactly like the geometry the
//  tool will receive), else the raw cursor world point. Both come straight from the
//  model via `worldToScreen`, recomputed on every `mouseMoved` redraw — no extra
//  state.
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

// MARK: - The crosshair overlay view

/// A transparent, click-through `NSView` drawn over the canvas that renders the CAD
/// crosshair + snap marker. Added as a subview of the `FlippedMTKView`, kept
/// covering the canvas bounds, and shown ONLY while a drawing/edit tool is active
/// (the controller toggles `isHidden` from `model.crosshairVisible`).
@MainActor
final class CrosshairOverlayView: NSView {

    /// The shared canvas state (cursor world point, snap result, viewport mapping).
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

    // MARK: Geometry constants (screen points)

    /// Half-size of the small snap-marker box drawn at the crosshair center (points).
    private static let snapBoxHalf: CGFloat = 4
    /// The crosshair line width (points).
    private static let lineWidth: CGFloat = 0.75

    // MARK: Click-through

    /// ALWAYS transparent to clicks: the crosshair is pure chrome, so every click /
    /// drag must fall through to the canvas (drawing / selection / pan) exactly as if
    /// the overlay weren't there. Returning `nil` here is what makes it click-through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Refresh

    /// Repaints the crosshair. Called by the controller on every cursor move (and
    /// when the snap/viewport changes). Cheap: it just redraws two lines + a box.
    func refresh() {
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Nothing to draw without a live cursor (mouse outside the canvas).
        guard let world = model.cursorWorld else { return }

        // Lock the crosshair onto the snapped point when one exists (so it sits
        // exactly where the tool's next click will land), else the raw cursor.
        let center = model.viewport.worldToScreen(model.snap?.point ?? world)
        let b = bounds

        // Adaptive, low-contrast lines via a semantic color so they read on both the
        // light and dark canvas (and dim enough not to fight the geometry).
        let lineColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)

        let path = NSBezierPath()
        path.lineWidth = Self.lineWidth
        // Vertical span.
        path.move(to: CGPoint(x: center.x, y: b.minY))
        path.line(to: CGPoint(x: center.x, y: b.maxY))
        // Horizontal span.
        path.move(to: CGPoint(x: b.minX, y: center.y))
        path.line(to: CGPoint(x: b.maxX, y: center.y))
        lineColor.setStroke()
        path.stroke()

        // The snap marker: a small box at the center, accent-tinted when a real
        // geometry/grid snap is active (not the always-on `.free` fallback) so the
        // user sees WHEN the cursor has locked onto something.
        let kind = model.snap?.kind
        let isHardSnap = kind != nil && kind != .free
        let markerColor: NSColor = isHardSnap
            ? NSColor.controlAccentColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        let box = NSRect(x: center.x - Self.snapBoxHalf, y: center.y - Self.snapBoxHalf,
                         width: Self.snapBoxHalf * 2, height: Self.snapBoxHalf * 2)
        let marker = NSBezierPath(rect: box)
        marker.lineWidth = 1.5
        markerColor.setStroke()
        marker.stroke()
    }
}
