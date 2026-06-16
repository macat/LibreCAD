//
//  UCSAxisOverlay.swift
//  LibreCADmacOS
//
//  The fixed-screen-size UCS AXIS INDICATOR (backlog #4b) — a small L-shaped X/Y
//  gizmo, anchored at the WORLD ORIGIN (0, 0), floated as an AppKit overlay OVER the
//  Metal canvas. It shows where the world origin is and which way the +X / +Y axes
//  point on screen, so the coordinate frame is always legible (HIG: orient the user
//  in the drawing). The arms are a CONSTANT on-screen length (they do not scale with
//  zoom); only the anchor point moves with pan/zoom (it is `worldToScreen(0,0)`).
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
//  ## Anchor source of truth
//  The gizmo origin is `model.viewport.worldToScreen(Vector(0, 0))`, recomputed on
//  every `refresh()` — no extra state. `worldToScreen` returns a Y-DOWN (flipped)
//  screen point, the SAME space this `isFlipped` view draws in, so the point lands
//  directly. World +Y points UP, which in flipped (Y-down) screen space is toward
//  SMALLER y — so the +Y arm is drawn with a NEGATIVE screen-y delta (see
//  `axisGeometry`). The +X arm is drawn with a POSITIVE screen-x delta.
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
/// from the on-screen anchor (the world origin) and a fixed arm length. Value type,
/// no AppKit drawing — so the anchor→segments mapping is fully unit-testable
/// (`UCSAxisGeometryTests`), exactly like `CrosshairGeometry`.
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
    /// scale with zoom; only the anchor (the origin) moves with pan/zoom.
    static let armLength: CGFloat = 24
    /// The axis line width (points). A touch heavier than the crosshair so the gizmo
    /// reads as a distinct UCS affordance.
    private static let lineWidth: CGFloat = 1.5

    // MARK: Pure geometry helper (unit-tested)

    /// Compute the two axis-arm segments for an `origin` anchor (the world origin in
    /// flipped screen space) and arm `length`. Pure + GPU-free so it's exercised
    /// directly by `UCSAxisGeometryTests`.
    ///
    /// - The +X arm runs from `origin` to `origin + (length, 0)` (rightward).
    /// - The +Y arm runs from `origin` to `origin + (0, -length)` (upward on screen,
    ///   because the host view is flipped/Y-down and world +Y is up).
    static func axisGeometry(origin: CGPoint, length: CGFloat) -> UCSAxisGeometry {
        UCSAxisGeometry(
            xArm: (origin, CGPoint(x: origin.x + length, y: origin.y)),
            yArm: (origin, CGPoint(x: origin.x, y: origin.y - length)))
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

        // The anchor is the world origin mapped to (flipped) screen space; it moves
        // with pan/zoom, while the arm length stays a constant on-screen size.
        let origin = model.viewport.worldToScreen(Vector(0, 0))
        let geometry = Self.axisGeometry(origin: origin, length: Self.armLength)

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
