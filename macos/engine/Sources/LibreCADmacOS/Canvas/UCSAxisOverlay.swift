//
//  UCSAxisOverlay.swift
//  LibreCADmacOS
//
//  The fixed-screen-size UCS AXIS INDICATOR (backlog #4b) — a small L-shaped X/Y
//  gizmo, anchored at the CURRENT UCS ORIGIN, floated as an AppKit overlay OVER the
//  Metal canvas. It shows where the active coordinate frame's origin is and which way
//  its +X / +Y axes point on screen, so the coordinate frame is always legible (HIG:
//  orient the user in the drawing). The arms are a CONSTANT on-screen length (they do
//  not scale with zoom); only the anchor point and the arm DIRECTIONS follow the UCS:
//  the anchor is `worldToScreen(currentUCS.origin)`, and the arms are rotated by the
//  UCS angle. With the WORLD frame (`UCS.world`) the gizmo is identical to before —
//  anchored at `worldToScreen(0,0)` with axis-aligned arms.
//
//  ## Why a screen-space AppKit overlay (mirrors CrosshairOverlayView's rationale)
//  The gizmo must stay a constant on-screen size, track the viewport on every
//  pan/zoom, and must NOT intercept clicks (drawing/selection must work through it).
//  An `NSView` subview whose `hitTest` ALWAYS returns `nil` gives both for free and
//  keeps the gizmo entirely out of the GPU buffer-build path — `LineRenderer` and
//  `OverlayGeometry` are untouched (the Metal grid/axis-line path is NOT used here).
//  It is the SAME pattern the crosshair, marquee, and transform-gizmo overlays use (a
//  transparent flipped subview of the `FlippedMTKView`); the controller owns it
//  alongside the other overlays, keeps it sized to the canvas, and calls `refresh()`
//  on every `redraw` so it tracks pan/zoom.
//
//  ## Anchor + orientation source of truth
//  The gizmo origin is `model.viewport.worldToScreen(model.currentUCS.origin)`, and
//  the arm directions come from `model.currentUCS.angle`, both recomputed on every
//  `refresh()` — no extra state. `worldToScreen` returns a Y-DOWN (flipped) screen
//  point, the SAME space this `isFlipped` view draws in, so the point lands directly.
//  World +Y points UP, which in flipped (Y-down) screen space is toward SMALLER y —
//  so a world direction `(dx, dy)` maps to the screen DELTA `(dx, -dy)`. With the
//  world frame the +X arm is a POSITIVE screen-x delta and the +Y arm a NEGATIVE
//  screen-y delta (see `axisGeometry`); a rotated UCS rotates both arms accordingly.
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

// MARK: - Pure UCS-axis geometry (GPU-free; unit-tested)

/// The screen-space line segments to stroke for the UCS axis gizmo, derived purely
/// from the on-screen anchor (the UCS origin), a fixed arm length, and the UCS angle.
/// Value type, no AppKit drawing — so the anchor+angle→segments mapping is fully
/// unit-testable (`UCSAxisGeometryTests`), exactly like `CrosshairGeometry`.
///
/// Each segment is the inclusive `(from, to)` endpoint pair to stroke, both in the
/// host view's flipped (top-left, Y-down) screen space.
struct UCSAxisGeometry: Equatable {
    /// The +X arm: from the origin anchor toward INCREASING screen-x.
    var xArm: (from: CGPoint, to: CGPoint)
    /// The +Y arm: from the origin anchor toward DECREASING screen-y (world +Y is up,
    /// which in flipped/Y-down screen space is toward the top of the view).
    var yArm: (from: CGPoint, to: CGPoint)

    static func == (lhs: UCSAxisGeometry, rhs: UCSAxisGeometry) -> Bool {
        lhs.xArm.from == rhs.xArm.from && lhs.xArm.to == rhs.xArm.to
            && lhs.yArm.from == rhs.yArm.from && lhs.yArm.to == rhs.yArm.to
    }
}

// MARK: - The UCS axis overlay view

/// A transparent, click-through `NSView` drawn over the canvas that renders the small
/// fixed-size UCS axis L-gizmo at the world origin. Added as a subview of the
/// `FlippedMTKView`, kept covering the canvas bounds, and refreshed on every viewport
/// change (pan/zoom) so its anchor tracks the origin.
@MainActor
final class UCSAxisOverlayView: NSView {

    /// The shared canvas state (the viewport mapping; origin = `worldToScreen(0,0)`).
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

    /// Length of one arm of the L-gizmo (points). Fixed on-screen size — it does NOT
    /// scale with zoom; only the anchor (the UCS origin) moves with pan/zoom and the
    /// arms rotate with the UCS angle.
    static let armLength: CGFloat = 24
    /// The axis line width (points). A touch heavier than the crosshair so the gizmo
    /// reads as a distinct UCS affordance.
    private static let lineWidth: CGFloat = 1.5

    // MARK: Pure geometry helper (unit-tested)

    /// Compute the two axis-arm segments for an `origin` anchor (the UCS origin in
    /// flipped screen space), an arm `length`, and the UCS rotation `angle` (radians,
    /// world-space CCW — the same convention as `UCS.angle`). Pure + GPU-free so it's
    /// exercised directly by `UCSAxisGeometryTests`.
    ///
    /// The UCS +X axis world direction is `(cos θ, sin θ)` and the +Y axis is that
    /// rotated 90° CCW, `(-sin θ, cos θ)`. A world direction `(dx, dy)` maps to a
    /// FLIPPED (Y-down) screen delta `(dx, -dy)` — world +Y is up, i.e. toward smaller
    /// screen-y. So:
    /// - The +X arm runs from `origin` to `origin + (cos θ, -sin θ) · length`.
    /// - The +Y arm runs from `origin` to `origin + (-sin θ, -cos θ) · length`.
    ///
    /// With `angle == 0` (the world frame, the default) this reduces EXACTLY to the
    /// prior behavior: +X → `(length, 0)` (rightward), +Y → `(0, -length)` (up).
    static func axisGeometry(origin: CGPoint, length: CGFloat,
                             angle: CGFloat = 0) -> UCSAxisGeometry {
        let c = cos(angle)
        let s = sin(angle)
        // World dir (dx, dy) → flipped screen delta (dx, -dy).
        let xEnd = CGPoint(x: origin.x + c * length, y: origin.y - s * length)
        let yEnd = CGPoint(x: origin.x - s * length, y: origin.y - c * length)
        return UCSAxisGeometry(xArm: (origin, xEnd), yArm: (origin, yEnd))
    }

    // MARK: Click-through

    /// ALWAYS transparent to clicks: the UCS gizmo is pure chrome, so every click /
    /// drag must fall through to the canvas (drawing / selection / pan) exactly as if
    /// the overlay weren't there. Returning `nil` here is what makes it click-through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Refresh

    /// Repaints the gizmo. Called by the controller on every viewport change (pan/zoom)
    /// via `redraw`. Cheap: it just redraws two short lines.
    func refresh() {
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // The anchor is the CURRENT UCS origin mapped to (flipped) screen space; it
        // moves with pan/zoom, while the arm length stays a constant on-screen size and
        // the arm directions follow the UCS angle. With `UCS.world` this is identical to
        // anchoring at the world origin with axis-aligned arms.
        let ucs = model.currentUCS
        let origin = model.viewport.worldToScreen(ucs.origin)
        let geometry = Self.axisGeometry(
            origin: origin, length: Self.armLength, angle: CGFloat(ucs.angle))

        // +X red-ish, +Y green-ish — the conventional CAD axis coloring, tinted down a
        // little so the gizmo reads without fighting the geometry.
        let xColor = NSColor.systemRed.withAlphaComponent(0.85)
        let yColor = NSColor.systemGreen.withAlphaComponent(0.85)

        let xPath = NSBezierPath()
        xPath.lineWidth = Self.lineWidth
        xPath.move(to: geometry.xArm.from)
        xPath.line(to: geometry.xArm.to)
        xColor.setStroke()
        xPath.stroke()

        let yPath = NSBezierPath()
        yPath.lineWidth = Self.lineWidth
        yPath.move(to: geometry.yArm.from)
        yPath.line(to: geometry.yArm.to)
        yColor.setStroke()
        yPath.stroke()
    }
}
