//
//  CrosshairOverlay.swift
//  LibreCADmacOS
//
//  The full-canvas CAD CROSSHAIR cursor (UX-plan U3, gap G3) — a screen-space
//  AppKit overlay floated OVER the Metal canvas that, while a drawing/edit tool is
//  active, draws two thin lines centered on the cursor (or the snapped point), plus
//  a small box at the snap marker. It makes the active draw mode unmistakable (HIG:
//  "make the current mode obvious") and gives the CAD-native precision affordance
//  every CAD app has.
//
//  ## Honoring the `crosshairStyle` preference
//  The Appearance preference (`AppSettings.Key.crosshairStyle`, a `CrosshairStyle`
//  stored as a String rawValue in UserDefaults) controls the cross extent:
//    • `.full`  — two lines spanning the WHOLE view (LibreCAD's "spider" cursor).
//    • `.small` — a short, fixed-size cursor-local cross (the default).
//    • `.none`  — no cross lines at all; just the snap marker box.
//  The snap-marker box is drawn in ALL styles (including `.none`) — it is the
//  precision affordance that shows WHEN/WHERE the cursor has locked onto geometry,
//  independent of the cross style. The cross-line extent itself is computed by the
//  PURE, GPU-free helper `crosshairGeometry(style:bounds:center:)`, so the style→
//  extent mapping is unit-tested without an `NSView`/GPU (`CrosshairStyleTests`);
//  `draw(_:)` stays a thin stroker around it.
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

// MARK: - Pure crosshair geometry (GPU-free; unit-tested)

/// The screen-space line segments to stroke for a crosshair, derived purely from the
/// chosen `CrosshairStyle`, the view bounds, and the center point. Value type, no
/// AppKit drawing — so the style→extent mapping is fully unit-testable.
///
/// A `nil` segment means "draw no line on this axis" (the `.none` style). Each
/// non-nil segment is the inclusive `(from, to)` endpoint pair to stroke.
struct CrosshairGeometry: Equatable {
    /// Vertical line endpoints (top→bottom through the center), or `nil` if none.
    var vertical: (from: CGPoint, to: CGPoint)?
    /// Horizontal line endpoints (left→right through the center), or `nil` if none.
    var horizontal: (from: CGPoint, to: CGPoint)?

    static func == (lhs: CrosshairGeometry, rhs: CrosshairGeometry) -> Bool {
        lhs.vertical?.from == rhs.vertical?.from
            && lhs.vertical?.to == rhs.vertical?.to
            && lhs.horizontal?.from == rhs.horizontal?.from
            && lhs.horizontal?.to == rhs.horizontal?.to
    }

    /// `true` when no cross lines are drawn at all (the `.none` style).
    var isEmpty: Bool { vertical == nil && horizontal == nil }
}

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
    /// Half-length of one arm of the `.small` cursor-local cross (points). Long
    /// enough to read as a cross beyond the snap box, short enough to stay local.
    static let smallArmHalf: CGFloat = 14

    // MARK: Pure geometry helper (unit-tested)

    /// Compute the cross-line segments for a `style`, centered on `center` within
    /// `bounds`. Pure + GPU-free so it's exercised directly by `CrosshairStyleTests`.
    ///
    /// - `.full`  spans the entire `bounds` on both axes (the "spider" cursor).
    /// - `.small` draws a short fixed-length cross (`±smallArmHalf`) about the center.
    /// - `.none`  draws no lines (both segments `nil`).
    static func crosshairGeometry(style: CrosshairStyle,
                                  bounds: CGRect,
                                  center: CGPoint) -> CrosshairGeometry {
        switch style {
        case .none:
            return CrosshairGeometry(vertical: nil, horizontal: nil)
        case .full:
            return CrosshairGeometry(
                vertical: (CGPoint(x: center.x, y: bounds.minY),
                           CGPoint(x: center.x, y: bounds.maxY)),
                horizontal: (CGPoint(x: bounds.minX, y: center.y),
                             CGPoint(x: bounds.maxX, y: center.y)))
        case .small:
            let h = smallArmHalf
            return CrosshairGeometry(
                vertical: (CGPoint(x: center.x, y: center.y - h),
                           CGPoint(x: center.x, y: center.y + h)),
                horizontal: (CGPoint(x: center.x - h, y: center.y),
                             CGPoint(x: center.x + h, y: center.y)))
        }
    }

    /// Resolve the user's crosshair-style preference from UserDefaults, falling back
    /// to the app default (`.full` — the full-window "spider" crosshair;
    /// `AppSettings.Default.crosshairStyle`) when unset or holding a legacy/unknown value.
    /// Read straight from `UserDefaults` (not `@AppStorage`) since this is a plain
    /// `NSView`, not a SwiftUI view; the Preferences picker writes the same key.
    private var currentStyle: CrosshairStyle {
        let raw = UserDefaults.standard.string(forKey: AppSettings.Key.crosshairStyle)
        return raw.flatMap(CrosshairStyle.init(rawValue:)) ?? AppSettings.Default.crosshairStyle
    }

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

        // The cross-line extent is driven by the user's preference. `.none` yields an
        // empty geometry (no lines); we still draw the snap marker below.
        let geometry = Self.crosshairGeometry(style: currentStyle, bounds: bounds, center: center)

        // Adaptive, low-contrast lines via a semantic color so they read on both the
        // light and dark canvas (and dim enough not to fight the geometry).
        let lineColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)

        if !geometry.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = Self.lineWidth
            if let v = geometry.vertical {
                path.move(to: v.from)
                path.line(to: v.to)
            }
            if let h = geometry.horizontal {
                path.move(to: h.from)
                path.line(to: h.to)
            }
            lineColor.setStroke()
            path.stroke()
        }

        // The snap marker: a small box at the center, accent-tinted when a real
        // geometry/grid snap is active (not the always-on `.free` fallback) so the
        // user sees WHEN the cursor has locked onto something. Drawn in EVERY style
        // (incl. `.none`) — it is the precision affordance, not the cross.
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
