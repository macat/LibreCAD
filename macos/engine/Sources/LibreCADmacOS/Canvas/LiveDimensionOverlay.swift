//
//  LiveDimensionOverlay.swift
//  LibreCADmacOS
//
//  The on-canvas LIVE DIMENSIONAL FEEDBACK overlay (live-dim Wave 2) — a transparent,
//  click-through AppKit overlay floated OVER the Metal canvas that, while a drawing /
//  modify tool runs, draws AutoCAD-style "dynamic input" dimensional feedback: a
//  DOTTED dimension line from the operation's fixed point to the cursor (plus short
//  witness/extension lines where it reads), and the tool's PRE-FORMATTED value as a
//  text label in a small rounded translucent box near the cursor. It is the visible
//  half of the `LiveDimension` engine seam (W1a): the engine emits the value types,
//  this view renders them.
//
//  ## Why a screen-space AppKit overlay (mirrors the sibling overlays' rationale)
//  The dim line + label must stay a CONSTANT on-screen size (a fixed dotted period, a
//  fixed type size), track the cursor on every move, and must NOT intercept clicks
//  (drawing must work through it). A transparent flipped `NSView` subview whose
//  `hitTest` ALWAYS returns `nil` gives both for free and keeps the feedback entirely
//  out of the GPU buffer-build path — `LineRenderer`, `OverlayGeometry`, the Metal
//  `LineInstance`/shaders are UNTOUCHED (this overlay strokes its own dotted lines and
//  hosts its own text in Core Graphics). It is the SAME contract the crosshair / UCS /
//  gizmo / grip overlays use: `isFlipped = true`, a `refresh()` / `isHidden` lifecycle
//  the Wave-3 mount drives, and a `worldToScreen` projection recomputed every redraw.
//
//  ## INJECTED, not CanvasModel-coupled (the Wave-3 mount wires it)
//  Like `EntityGripOverlayView`, this overlay is SELF-CONTAINED + INJECTED: it owns NO
//  `CanvasModel` and performs NO document mutation — it only DRAWS. The Wave-3 mount
//  (`CADCanvasView`/its controller) supplies, as closures:
//    • `liveDimensionsProvider` — the MERGED `[LiveDimension]` the active tool emits
//      (already in WORLD coords, with a PRE-FORMATTED `label` string),
//    • `viewportProvider`       — the `Viewport` for world→screen projection.
//  The mount also toggles `isEnabled` (DYN on/off + "is a draw actually in progress")
//  to suppress the feedback when there is nothing to show; `refresh()` repaints on
//  every cursor move / pan / zoom. No first responder, no model read-back.
//
//  ## First text-over-canvas in the project
//  This is the FIRST place the app draws TEXT over the canvas. The correct host is
//  `NSAttributedString.draw(at:)` straight into the current CG context (NOT NSTextView
//  / NSTextField, which would need a first responder and could hang the headless suite,
//  and NOT the Metal pipeline, which has no glyph path). The label sits in a small
//  rounded translucent rounded-rect so it reads on either canvas theme, and is NUDGED
//  by the pure `LiveDimensionGeometry.labelBox(...)` helper so it never sits under the
//  crosshair and always stays on-screen — that placement math is GPU-free + unit-tested.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it under the
//  terms of the GNU General Public License version 2 or (at your option) any later
//  version.
//

import AppKit
import CADEngine

// MARK: - Pure live-dimension geometry (GPU-free; unit-tested)

/// Pure, headlessly-testable placement math for the live-dimension overlay — the only
/// non-trivial geometry the view itself owns (the world→screen of `from`/`to` is the
/// `Viewport`'s job). Static members of a namespaced `enum` so there are no module-
/// scope free functions (CONVENTIONS.md), mirroring `EntityGripHitTest`.
enum LiveDimensionGeometry {

    /// Place the label's background box for a `labelAnchor` already projected to (the
    /// flipped, Y-down) screen space, given the rendered text `size` and the view
    /// `bounds`. Pure + GPU-free so the placement contract is asserted directly.
    ///
    /// The box is sized to `size` plus a symmetric `padding` on each axis, then:
    ///   1. OFFSET from the anchor by `offset` (default up-and-right) so it does NOT sit
    ///      directly under the crosshair / cursor at the anchor; and
    ///   2. CLAMPED so the whole box stays inside `bounds` (it never runs off-screen) —
    ///      when the up-right offset would push it past the top/right edge it is pulled
    ///      back in, so the label stays fully legible at any cursor position.
    ///
    /// - Parameters:
    ///   - anchor:  the label anchor in flipped screen space (`worldToScreen(labelAnchor)`).
    ///   - size:    the rendered text size (points).
    ///   - bounds:  the host view bounds (points).
    ///   - offset:  the anchor→box-origin nudge (default `(12, -12)`: right + up, so the
    ///              box clears the crosshair which sits at the anchor). On a flipped,
    ///              Y-down view a NEGATIVE y moves UP the screen.
    ///   - padding: half-padding added on each side of the text inside the box.
    /// - Returns: the box rect in flipped screen space, clamped on-screen.
    static func labelBox(anchor: CGPoint,
                         size: CGSize,
                         bounds: CGRect,
                         offset: CGSize = CGSize(width: 12, height: -12),
                         padding: CGFloat = 4) -> CGRect {
        let w = size.width + padding * 2
        let h = size.height + padding * 2

        // Initial top-left origin: nudge up-and-right of the anchor. The `-h` lifts the
        // box so its BOTTOM edge sits at the offset point (the box grows upward), which
        // keeps it clear of the cursor/crosshair below.
        var x = anchor.x + offset.width
        var y = anchor.y + offset.height - h

        // Clamp on-screen. If the view is smaller than the box on an axis, pin to the
        // min edge (better to clip the far edge than to hide the value entirely).
        if x + w > bounds.maxX { x = bounds.maxX - w }
        if x < bounds.minX { x = bounds.minX }
        if y + h > bounds.maxY { y = bounds.maxY - h }
        if y < bounds.minY { y = bounds.minY }

        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - The live-dimension overlay view

/// A transparent, click-through `NSView` drawn over the canvas that renders the active
/// tool's `[LiveDimension]` feedback. Added as a subview of the `FlippedMTKView`, kept
/// covering the canvas bounds, and shown ONLY while enabled with feedback to show (the
/// Wave-3 mount toggles `isEnabled` / calls `refresh()` on cursor / pan / zoom change).
@MainActor
final class LiveDimensionOverlayView: NSView {

    // MARK: Injected inputs (the Wave-3 mount supplies these — no CanvasModel here)

    /// The MERGED live-dimension feedback the active tool emits this frame — already in
    /// WORLD coords with a PRE-FORMATTED `label`. Empty when the tool emits none.
    private let liveDimensionsProvider: () -> [LiveDimension]

    /// The current `Viewport`, for world→screen projection of `from` / `to` / anchor.
    private let viewportProvider: () -> Viewport

    init(liveDimensionsProvider: @escaping () -> [LiveDimension],
         viewportProvider: @escaping () -> Viewport) {
        self.liveDimensionsProvider = liveDimensionsProvider
        self.viewportProvider = viewportProvider
        super.init(frame: .zero)
        wantsLayer = true
        // The overlay paints nothing opaque; only the dotted lines + the label boxes.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same flipped (top-left, Y-down) space as the host `FlippedMTKView`, so
    /// `worldToScreen` points land directly without a Y flip (matches the siblings).
    override var isFlipped: Bool { true }

    // MARK: Enable / refresh

    /// Whether the mount currently lets this overlay draw. The mount sets this `false`
    /// to SUPPRESS the feedback (DYN preference off, or no draw in progress); when
    /// `false` the overlay hides and draws nothing. Default `true`.
    var isEnabled: Bool = true {
        didSet { if oldValue != isEnabled { refresh() } }
    }

    /// Repaints the feedback. Called by the mount on every cursor move (and on pan /
    /// zoom). Cheap: it strokes a few dotted lines + draws the label boxes. Also keeps
    /// `isHidden` in sync with `isEnabled` so a disabled overlay never paints.
    func refresh() {
        isHidden = !isEnabled
        needsDisplay = true
    }

    /// Whether the overlay currently has feedback to show (enabled + a non-empty
    /// provider). The mount can read this to coordinate with other overlays.
    var isActive: Bool { isEnabled && !liveDimensionsProvider().isEmpty }

    // MARK: Click-through

    /// ALWAYS transparent to clicks: live dimensions are pure chrome, so every click /
    /// drag must fall through to the canvas (drawing / selection / pan) exactly as if
    /// the overlay weren't there. Returning `nil` here is what makes it click-through
    /// (the crosshair/UCS contract — this overlay never owns a gesture).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Geometry constants (screen points)

    /// The dotted dimension-line width (points). Light enough to read as chrome.
    private static let lineWidth: CGFloat = 1.0
    /// Dotted-line dash period (points), screen-fixed (independent of zoom) — the same
    /// dotted look the gizmo reference line uses (a short on / short off pattern).
    private static let dashLengths: [CGFloat] = [2, 3]
    /// Half-length of a witness/extension tick drawn perpendicular at each end of a
    /// linear dim line (points). Short — just enough to read as an AutoCAD witness.
    private static let witnessHalf: CGFloat = 5
    /// Corner radius of the rounded label background box (points).
    private static let labelCornerRadius: CGFloat = 4
    /// Half-padding inside the label box around the text (points).
    private static let labelPadding: CGFloat = 4
    /// Radius of the small angle arc drawn for an `.angle` dimension (points).
    private static let angleArcRadius: CGFloat = 22

    // MARK: Colors (low-contrast chrome that reads on either canvas theme)

    /// The dotted dim line + witness ticks. A semantic color so it adapts to the theme.
    private static var dimLineColor: NSColor { .secondaryLabelColor.withAlphaComponent(0.85) }
    /// The label text color.
    private static var labelTextColor: NSColor { .labelColor }
    /// The label background box fill (translucent so geometry behind shows through).
    private static var labelBoxFill: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.82)
    }
    /// The label background box stroke (a faint accent edge so it reads as a chip).
    private static var labelBoxStroke: NSColor { .separatorColor.withAlphaComponent(0.9) }

    // MARK: Label text attributes

    /// The attributed-string attributes for a live-dimension `label` — a small,
    /// monospaced-digit system font so values read like a CAD readout. Static so the
    /// rendered size used for box placement matches the drawn glyphs exactly.
    private static var labelAttributes: [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return [.font: font, .foregroundColor: labelTextColor]
    }

    // MARK: Screen mapping

    private func screen(_ world: Vector) -> CGPoint { viewportProvider().worldToScreen(world) }

    // MARK: Drawing (GUI-only — exercised in the app, not the headless suite)

    /// Renders every `LiveDimension` from the provider: a dotted dim line `from`→`to`
    /// (with kind-specific embellishment) and the pre-formatted `label` in a rounded
    /// translucent box near `labelAnchor`, nudged off the crosshair by the pure
    /// `LiveDimensionGeometry.labelBox(...)` helper. A no-op when disabled / empty.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEnabled, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dims = liveDimensionsProvider()
        guard !dims.isEmpty else { return }

        for dim in dims {
            drawDimLine(dim, in: ctx)
            drawLabel(dim, in: ctx)
        }
    }

    /// Strokes the dotted dimension line `from`→`to` for one feedback item, plus the
    /// kind-specific embellishment: short perpendicular witness ticks for a linear/size
    /// dim, a small sweep arc for an angle. All screen-fixed (the dash period and tick
    /// length do not scale with zoom).
    private func drawDimLine(_ dim: LiveDimension, in ctx: CGContext) {
        let a = screen(dim.from)
        let b = screen(dim.to)

        ctx.saveGState()
        ctx.setStrokeColor(Self.dimLineColor.cgColor)
        ctx.setLineWidth(Self.lineWidth)
        ctx.setLineDash(phase: 0, lengths: Self.dashLengths)

        // The main dotted dim line.
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()

        switch dim.kind {
        case .linear, .size:
            // AutoCAD-style witness ticks: a short segment PERPENDICULAR to the dim
            // line at each end, so the measured span reads clearly. Computed from the
            // screen-space direction (handles any orientation, including the flipped Y).
            drawWitnessTicks(from: a, to: b, in: ctx)
        case .angle:
            // A small sweep arc centered on `from` (the vertex), through the radius the
            // `to` direction defines — a compact angle affordance.
            drawAngleArc(vertex: a, toward: b, in: ctx)
        case .radius, .diameter:
            // The straight dotted line IS the radius/diameter; no extra embellishment
            // (a witness tick on a radius reads as clutter).
            break
        }
        ctx.restoreGState()
    }

    /// Draws short perpendicular witness ticks at both ends of a screen segment. The
    /// perpendicular is the unit normal of the screen-space direction; a degenerate
    /// (zero-length) segment draws nothing.
    private func drawWitnessTicks(from a: CGPoint, to b: CGPoint, in ctx: CGContext) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 1e-6 else { return }
        // Unit perpendicular (rotate the unit direction 90°).
        let nx = -dy / len
        let ny = dx / len
        let h = Self.witnessHalf
        for p in [a, b] {
            ctx.move(to: CGPoint(x: p.x - nx * h, y: p.y - ny * h))
            ctx.addLine(to: CGPoint(x: p.x + nx * h, y: p.y + ny * h))
        }
        ctx.strokePath()
    }

    /// Draws a small fixed-radius sweep arc from the +X screen axis around to the
    /// `vertex`→`toward` direction, as a compact angle affordance. The arc is screen-
    /// fixed (a constant on-screen radius), and the dotted dash carries over from the
    /// caller's graphics state.
    private func drawAngleArc(vertex: CGPoint, toward: CGPoint, in ctx: CGContext) {
        let dx = toward.x - vertex.x
        let dy = toward.y - vertex.y
        guard hypot(dx, dy) > 1e-6 else { return }
        let endAngle = atan2(dy, dx)
        ctx.addArc(center: vertex, radius: Self.angleArcRadius,
                   startAngle: 0, endAngle: endAngle,
                   clockwise: endAngle < 0)
        ctx.strokePath()
    }

    /// Draws one feedback item's pre-formatted `label` in a rounded translucent box,
    /// placed by the pure `LiveDimensionGeometry.labelBox(...)` helper so it clears the
    /// crosshair and stays on-screen. Text is hosted by `NSAttributedString.draw(at:)`
    /// directly in the CG context — no NSTextView / first responder.
    private func drawLabel(_ dim: LiveDimension, in ctx: CGContext) {
        guard !dim.label.isEmpty else { return }
        let attr = NSAttributedString(string: dim.label, attributes: Self.labelAttributes)
        let textSize = attr.size()
        let anchor = screen(dim.labelAnchor)
        let box = LiveDimensionGeometry.labelBox(anchor: anchor, size: textSize,
                                                 bounds: bounds, padding: Self.labelPadding)

        // The rounded translucent background chip (solid dash; reset the caller's dotted
        // pattern so the box edge isn't dotted).
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        let roundedPath = NSBezierPath(roundedRect: box,
                                       xRadius: Self.labelCornerRadius,
                                       yRadius: Self.labelCornerRadius)
        Self.labelBoxFill.setFill()
        roundedPath.fill()
        Self.labelBoxStroke.setStroke()
        roundedPath.lineWidth = 1
        roundedPath.stroke()
        ctx.restoreGState()

        // The text, centered inside the padded box. `draw(at:)` lands in this flipped
        // view's space directly (the host view is `isFlipped`), so the baseline is
        // computed top-down like every other coordinate here.
        let textOrigin = CGPoint(
            x: box.minX + (box.width - textSize.width) * 0.5,
            y: box.minY + (box.height - textSize.height) * 0.5)
        attr.draw(at: textOrigin)
    }
}
