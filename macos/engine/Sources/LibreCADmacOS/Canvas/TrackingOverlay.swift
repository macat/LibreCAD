//
//  TrackingOverlay.swift
//  LibreCADmacOS
//
//  The on-canvas SNAP-TRACKING overlay (snap-tracking Wave 3) — a transparent,
//  click-through AppKit overlay floated OVER the Metal canvas that, while a drawing /
//  modify tool runs with POLAR TRACKING engaged, draws AutoCAD-style polar feedback:
//  a DOTTED polar ray radiating from the relative-zero datum through the snapped polar
//  angle, plus a PRE-FORMATTED `dist<angle` readout chip near the snapped point. It is
//  the first user-visible win of the snap-tracking stack: the engine
//  (`CanvasModel.trackingDisplay()` → `TrackingDisplay`) emits the value types, this
//  view renders them. The OTRACK alignment GUIDES / acquired-point MARKERS / lock
//  MARKER fields of `TrackingDisplay` are populated by a later wave (W5/W6); this view
//  already iterates them harmlessly (they are empty now) so the W6 render pass only has
//  to fill the marked TODO stubs.
//
//  ## Why a screen-space AppKit overlay (mirrors the sibling overlays' rationale)
//  The polar ray + readout must stay a CONSTANT on-screen style (a fixed dotted dash,
//  a fixed type size), track the cursor on every move, and must NOT intercept clicks
//  (drawing must work through it). A transparent flipped `NSView` subview whose
//  `hitTest` ALWAYS returns `nil` gives both for free and keeps the feedback entirely
//  out of the GPU buffer-build path — `LineRenderer`, `OverlayGeometry`, the Metal
//  `LineInstance`/shaders are UNTOUCHED (this overlay strokes its own dotted lines and
//  hosts its own text in Core Graphics). It is the SAME contract the crosshair / UCS /
//  gizmo / grip / live-dim overlays use: `isFlipped = true`, an `isEnabled` / `refresh()`
//  lifecycle the Wave-3 mount drives, and a `worldToScreen` projection recomputed every
//  redraw.
//
//  ## Z-ORDER: below the live-dim chip
//  The Wave-3 mount adds this overlay as a subview JUST BEFORE the live-dimension
//  overlay, so the live-dim value chip still paints ON TOP — the tracking guides /
//  polar ray sit above the grid + grips but BELOW the live-dim readout (the live-dim
//  chip is the foreground value the user is actively typing into).
//
//  ## INJECTED, not CanvasModel-coupled (the Wave-3 mount wires it)
//  Like `LiveDimensionOverlayView` / `EntityGripOverlayView`, this overlay is
//  SELF-CONTAINED + INJECTED: it owns NO `CanvasModel` and performs NO document
//  mutation — it only DRAWS. The Wave-3 mount supplies, as closures:
//    • `displayProvider`  — the `CanvasModel.TrackingDisplay` for this frame (the polar
//      ray endpoints in WORLD coords, plus a PRE-FORMATTED `readout` string),
//    • `viewportProvider` — the `Viewport` for world→screen projection.
//  The mount also toggles `isEnabled` (polar/OTRACK on + a tool active) to suppress the
//  feedback when there is nothing to show; `refresh()` repaints on every cursor move /
//  pan / zoom. No first responder, no model read-back.
//
//  ## Polar-ray clipping (why a SCREEN-space clip is required)
//  The polar ray's far endpoint is ~1e9 world units away (an effectively-infinite ray).
//  Projecting that point straight into a CG dash loop would produce an enormous segment
//  and a degenerate dash pattern. So the view projects BOTH endpoints, then clips the
//  resulting screen segment to the view bounds via the pure, unit-tested
//  `TrackingOverlayGeometry.clipRayToBounds(origin:far:bounds:)` (Liang-Barsky) and
//  strokes only the visible portion.
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

// MARK: - Pure tracking-overlay geometry (GPU-free; unit-tested)

/// Pure, headlessly-testable geometry for the snap-tracking overlay — the polar-ray
/// SCREEN-space clip (the only non-trivial geometry the view itself owns; the readout's
/// chip placement reuses `LiveDimensionGeometry.labelBox`, and the world→screen of the
/// ray endpoints / readout anchor is the `Viewport`'s job). Static members of a
/// namespaced `enum` so there are no module-scope free functions (CONVENTIONS.md),
/// mirroring `LiveDimensionGeometry` / `EntityGripHitTest`.
enum TrackingOverlayGeometry {

    /// Clip the SCREEN-space polar-ray segment `origin`→`far` to the visible `bounds`,
    /// returning the visible sub-segment (or `nil` if the segment lies entirely outside
    /// the rect). Liang-Barsky parametric line clip, on the parameter `t ∈ [0, 1]` along
    /// `origin + t·(far - origin)`.
    ///
    /// This runs in SCREEN space AFTER projection, because the polar ray's `far` endpoint
    /// is ~1e9 world units away (an effectively-infinite ray): projecting that into a CG
    /// dash loop blindly would stroke an absurd segment. Clipping the projected segment to
    /// the view bounds first means we stroke only the on-screen portion with a sane dash.
    ///
    /// - Parameters:
    ///   - origin: the near (datum) end of the ray, in flipped screen space.
    ///   - far:    the far end of the ray (the projected ~1e9-unit endpoint), screen space.
    ///   - bounds: the host view bounds (points).
    /// - Returns: `(a, b)` — the visible sub-segment endpoints (clamped to `bounds`), or
    ///   `nil` if the whole segment is outside `bounds`. A degenerate (zero-length)
    ///   segment that lies inside the rect returns that point as both endpoints.
    static func clipRayToBounds(origin: CGPoint,
                                far: CGPoint,
                                bounds: CGRect) -> (CGPoint, CGPoint)? {
        let dx = far.x - origin.x
        let dy = far.y - origin.y

        // Degenerate segment (a point): visible iff it is inside the rect.
        if dx == 0 && dy == 0 {
            return bounds.contains(origin) ? (origin, origin) : nil
        }

        // Liang-Barsky: for each of the 4 edges, p·t <= q. `p < 0` ⇒ entering (raise
        // tMin), `p > 0` ⇒ leaving (lower tMax), `p == 0` ⇒ parallel (reject if outside).
        var tMin = 0.0
        var tMax = 1.0
        let p = [-dx, dx, -dy, dy]
        let q = [origin.x - bounds.minX,   // left   edge
                 bounds.maxX - origin.x,   // right  edge
                 origin.y - bounds.minY,   // top    edge (flipped: minY is the top)
                 bounds.maxY - origin.y]   // bottom edge

        for i in 0..<4 {
            if p[i] == 0 {
                // Parallel to this edge: if the origin is on the outside of it, the whole
                // segment is outside the rect.
                if q[i] < 0 { return nil }
            } else {
                let t = q[i] / p[i]
                if p[i] < 0 {
                    if t > tMax { return nil }   // enters after it already left
                    if t > tMin { tMin = t }
                } else {
                    if t < tMin { return nil }   // leaves before it entered
                    if t < tMax { tMax = t }
                }
            }
        }

        let a = CGPoint(x: origin.x + tMin * dx, y: origin.y + tMin * dy)
        let b = CGPoint(x: origin.x + tMax * dx, y: origin.y + tMax * dy)
        return (a, b)
    }
}

// MARK: - The snap-tracking overlay view

/// A transparent, click-through `NSView` drawn over the canvas that renders the active
/// tool's `CanvasModel.TrackingDisplay` feedback. Added as a subview of the
/// `FlippedMTKView` JUST BELOW the live-dim overlay, kept covering the canvas bounds,
/// and shown ONLY while enabled (the Wave-3 mount toggles `isEnabled` / calls `refresh()`
/// on cursor / pan / zoom change).
@MainActor
final class TrackingOverlayView: NSView {

    // MARK: Injected inputs (the Wave-3 mount supplies these — no CanvasModel here)

    /// The snap-tracking display for this frame — the polar ray endpoints (WORLD coords)
    /// + a PRE-FORMATTED `readout` string, plus the (empty this wave) OTRACK fields.
    private let displayProvider: () -> CanvasModel.TrackingDisplay

    /// The current `Viewport`, for world→screen projection of the ray + readout anchor.
    private let viewportProvider: () -> Viewport

    init(displayProvider: @escaping () -> CanvasModel.TrackingDisplay,
         viewportProvider: @escaping () -> Viewport) {
        self.displayProvider = displayProvider
        self.viewportProvider = viewportProvider
        super.init(frame: .zero)
        wantsLayer = true
        // The overlay paints nothing opaque; only the dotted ray + the readout chip.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Same flipped (top-left, Y-down) space as the host `FlippedMTKView`, so
    /// `worldToScreen` points land directly without a Y flip (matches the siblings).
    override var isFlipped: Bool { true }

    // MARK: Enable / refresh

    /// Whether the mount currently lets this overlay draw. The mount sets this `false`
    /// to SUPPRESS the feedback (polar + OTRACK both off, or no tool active); when
    /// `false` the overlay hides and draws nothing. Default `true`.
    var isEnabled: Bool = true {
        didSet { if oldValue != isEnabled { refresh() } }
    }

    /// Repaints the feedback. Called by the mount on every cursor move (and on pan /
    /// zoom). Cheap: it strokes one dotted ray + draws one readout chip. Also keeps
    /// `isHidden` in sync with `isEnabled` so a disabled overlay never paints.
    func refresh() {
        isHidden = !isEnabled
        needsDisplay = true
    }

    /// Whether the overlay currently has feedback to show (enabled + a non-empty
    /// display). The mount can read this to coordinate with other overlays.
    var isActive: Bool {
        guard isEnabled else { return false }
        let d = displayProvider()
        return d.polarRay != nil
            || d.readout != nil
            || !d.guides.isEmpty
            || !d.acquiredMarkers.isEmpty
            || d.lockMarker != nil
    }

    // MARK: Click-through

    /// ALWAYS transparent to clicks: tracking feedback is pure chrome, so every click /
    /// drag must fall through to the canvas (drawing / selection / pan) exactly as if
    /// the overlay weren't there. Returning `nil` here is what makes it click-through
    /// (the crosshair/UCS/live-dim contract — this overlay never owns a gesture).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Geometry constants (screen points)

    /// The dotted polar-ray width (points). Light enough to read as chrome.
    private static let lineWidth: CGFloat = 1.0
    /// Dotted polar-ray dash period (points), screen-fixed (independent of zoom). A
    /// LONGER on / off than the live-dim dim line's `[2, 3]` so the two are distinct at a
    /// glance — the tracking ray reads as a longer-dash guide, the live-dim line as a
    /// short dotted measure.
    private static let dashLengths: [CGFloat] = [6, 4]
    /// Corner radius of the rounded readout background box (points). Matches the live-dim
    /// chip so the two chips read as one family.
    private static let labelCornerRadius: CGFloat = 4
    /// Half-padding inside the readout box around the text (points).
    private static let labelPadding: CGFloat = 4

    // MARK: Colors (accent-tinted chrome, DISTINCT from the live-dim dim line)

    /// The dotted polar ray — ACCENT-tinted + translucent, so it reads as a tracking
    /// guide distinct from the live-dim line (which is `secondaryLabelColor`). ~0.4 alpha
    /// keeps it a faint guide that geometry shows through.
    private static var polarRayColor: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.4)
    }
    /// The readout text color.
    private static var readoutTextColor: NSColor { .labelColor }
    /// The readout background box fill (translucent so geometry behind shows through).
    private static var readoutBoxFill: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.82)
    }
    /// The readout background box stroke (a faint accent edge so it reads as a chip).
    private static var readoutBoxStroke: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.6)
    }

    // MARK: Readout text attributes

    /// The attributed-string attributes for the polar `readout` — a small,
    /// monospaced-digit system font so the `dist<angle` value reads like a CAD readout.
    /// Static so the rendered size used for box placement matches the drawn glyphs.
    private static var readoutAttributes: [NSAttributedString.Key: Any] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return [.font: font, .foregroundColor: readoutTextColor]
    }

    // MARK: Screen mapping

    private func screen(_ world: Vector) -> CGPoint { viewportProvider().worldToScreen(world) }

    // MARK: Drawing (GUI-only — exercised in the app, not the headless suite)

    /// Renders the tracking display: the dotted polar ray (clipped to the view) and the
    /// pre-formatted `dist<angle` readout in a rounded translucent chip near the snapped
    /// point. A no-op when disabled. THIS WAVE draws only `polarRay` + `readout`; the
    /// OTRACK `guides` / `acquiredMarkers` / `lockMarker` are iterated harmlessly (empty
    /// now) with their rendering left as marked TODO stubs for W6.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEnabled, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let display = displayProvider()

        drawPolarRay(display, in: ctx)
        drawTrackingGuides(display, in: ctx)
        drawAcquiredMarkers(display, in: ctx)
        drawLockMarker(display, in: ctx)
        drawReadout(display, in: ctx)
    }

    /// Strokes the dotted polar ray `from`→`to`, CLIPPED to the view bounds in screen
    /// space (the far end is ~1e9 world units away, so we project both ends then clip the
    /// screen segment via `TrackingOverlayGeometry.clipRayToBounds`). A nil ray / a ray
    /// entirely off-screen draws nothing.
    private func drawPolarRay(_ display: CanvasModel.TrackingDisplay, in ctx: CGContext) {
        guard let ray = display.polarRay else { return }
        let origin = screen(ray.from)
        let far = screen(ray.to)
        guard let (a, b) = TrackingOverlayGeometry.clipRayToBounds(
            origin: origin, far: far, bounds: bounds) else { return }

        ctx.saveGState()
        ctx.setStrokeColor(Self.polarRayColor.cgColor)
        ctx.setLineWidth(Self.lineWidth)
        ctx.setLineDash(phase: 0, lengths: Self.dashLengths)
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// OTRACK alignment guides. W5 fills `display.guides`; W6 renders them. This wave
    /// iterates harmlessly (the array is empty now) so the W6 pass only fills this body.
    private func drawTrackingGuides(_ display: CanvasModel.TrackingDisplay, in ctx: CGContext) {
        for _ in display.guides {
            // TODO (W6): stroke each alignment guide (horizontal / vertical / polar /
            // extension) as a dotted accent line clipped to the view bounds.
        }
    }

    /// Acquired-point markers (the small "+" glyphs OTRACK radiates guides from). W5
    /// fills `display.acquiredMarkers`; W6 renders them. Iterated harmlessly this wave.
    private func drawAcquiredMarkers(_ display: CanvasModel.TrackingDisplay, in ctx: CGContext) {
        for _ in display.acquiredMarkers {
            // TODO (W6): draw a small "+" marker at `screen(point)` for each acquired
            // snap point.
        }
    }

    /// The lock marker (the point the cursor is currently locked to by tracking). W5
    /// fills `display.lockMarker`; W6 renders it. Handled harmlessly this wave.
    private func drawLockMarker(_ display: CanvasModel.TrackingDisplay, in ctx: CGContext) {
        guard display.lockMarker != nil else { return }
        // TODO (W6): draw the lock marker glyph at `screen(lockMarker)`.
    }

    /// Draws the pre-formatted polar `readout` (`dist<angle`) in a rounded translucent
    /// chip, placed by the shared `LiveDimensionGeometry.labelBox(...)` helper so it
    /// clears the crosshair and stays on-screen. Text is hosted by
    /// `NSAttributedString.draw(at:)` directly in the CG context — no NSTextView / first
    /// responder. A nil / empty readout draws nothing.
    private func drawReadout(_ display: CanvasModel.TrackingDisplay, in ctx: CGContext) {
        guard let readout = display.readout, !readout.text.isEmpty else { return }

        let attr = NSAttributedString(string: readout.text, attributes: Self.readoutAttributes)
        let textSize = attr.size()
        let anchor = screen(readout.anchor)
        let box = LiveDimensionGeometry.labelBox(anchor: anchor, size: textSize,
                                                 bounds: bounds, padding: Self.labelPadding)

        // The rounded translucent background chip (solid dash; reset any dotted pattern
        // so the box edge isn't dotted).
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        let roundedPath = NSBezierPath(roundedRect: box,
                                       xRadius: Self.labelCornerRadius,
                                       yRadius: Self.labelCornerRadius)
        Self.readoutBoxFill.setFill()
        roundedPath.fill()
        Self.readoutBoxStroke.setStroke()
        roundedPath.lineWidth = 1
        roundedPath.stroke()
        ctx.restoreGState()

        // The text, centered inside the padded box. `draw(at:)` lands in this flipped
        // view's space directly (the host view is `isFlipped`).
        let textOrigin = CGPoint(
            x: box.minX + (box.width - textSize.width) * 0.5,
            y: box.minY + (box.height - textSize.height) * 0.5)
        attr.draw(at: textOrigin)
    }
}
