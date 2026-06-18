//
//  ConstraintGlyphOverlay.swift
//  LibreCADmacOS
//
//  The READ-ONLY PARAMETRIC-CONSTRAINT GLYPH overlay (Wave 3) — a screen-space AppKit
//  overlay floated OVER the Metal canvas that draws a small badge near each
//  constrained entity indicating WHICH constraint(s) hold it: ∥ for parallel, ⊥ for
//  perpendicular, H/V for horizontal/vertical, • for coincident, 🔒 (a small lock) for
//  fix, and a dimension tick (↔ / R) for distance / radius. It makes the otherwise
//  invisible parametric relationships LEGIBLE — the same affordance AutoCAD's
//  constraint bars / FreeCAD's Sketcher constraint icons provide.
//
//  ## READ-ONLY (no editing)
//  This overlay NEVER mutates the document and NEVER intercepts a click — it is pure
//  chrome (like `UCSAxisOverlayView`). It reads `model.drawing.constraints` +
//  `model.drawing.entity(_:)` and `model.viewport.worldToScreen` on each `refresh()`,
//  computes glyph placements (the pure `ConstraintGlyphLayout`), and strokes the
//  badges. Interactive constraint editing / selection / a constraint inspector list is
//  a LATER wave; here a constraint is shown, not touched.
//
//  ## Why a screen-space AppKit overlay (mirrors UCSAxisOverlayView's rationale)
//  The badges must stay a CONSTANT on-screen size across zoom, track the viewport on
//  every pan/zoom, and must NOT intercept clicks (drawing/selection must work through
//  them). An `NSView` subview whose `hitTest` ALWAYS returns `nil` gives both for free
//  and keeps the badges out of the GPU buffer-build path. It is the SAME pattern the
//  crosshair / UCS-axis / marquee overlays use — a transparent flipped subview of the
//  `FlippedMTKView`, refreshed on every `redraw`. The MOUNT (its controller adding it
//  as a subview, sizing it to the canvas, and calling `refresh()` on viewport/model
//  change) is the later wire-wave, exactly like the sibling overlays.
//
//  ## Placement
//  A constraint's badge is anchored at the SCREEN point of the bounding-box CENTER of
//  its FIRST referenced entity, nudged by a small per-constraint stack offset so
//  multiple constraints on one entity don't overprint. Using the bounding-box center
//  (rather than resolving an exact endpoint) keeps the overlay trivially read-only and
//  GPU-free; the badge points AT the entity it constrains, which is the legibility goal.
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

// MARK: - Pure glyph mapping + layout (GPU-/AppKit-free; unit-tested)

/// The SHORT label drawn in a constraint's badge, derived purely from its kind. Pure
/// (no AppKit) so the kind→glyph mapping is unit-tested directly. The strings are the
/// conventional CAD constraint marks (∥, ⊥, H, V, •, a lock, ↔, R).
enum ConstraintGlyph {

    /// The badge label for a constraint kind.
    static func label(for kind: Constraint.Kind) -> String {
        switch kind {
        case .geometric(let g):
            switch g {
            case .coincident:    return "•"
            case .horizontal:    return "H"
            case .vertical:      return "V"
            case .parallel:      return "∥"
            case .perpendicular: return "⊥"
            case .fix:           return "🔒"
            case .collinear:     return "—"
            case .tangent:       return "T"
            case .equal:         return "="
            case .concentric:    return "◎"
            case .symmetric:     return "⋈"
            }
        case .dimensional(let d):
            switch d {
            case .distance:           return "↔"
            case .radius:             return "R"
            case .horizontalDistance: return "↔x"
            case .verticalDistance:   return "↕y"
            case .diameter:           return "⌀"
            case .angle:              return "∠"
            }
        }
    }
}

/// One badge to draw: a SHORT label at a SCREEN anchor. A pure value (no AppKit
/// drawing), so the constraints+entities→placements mapping is fully unit-testable
/// (`ConstraintGlyphOverlayTests`), exactly like `UCSAxisGeometry`.
struct ConstraintGlyphPlacement: Equatable {
    /// The constraint this badge represents (identity for tests / future hit-testing).
    var constraintID: UUID
    /// The badge label (`ConstraintGlyph.label`).
    var label: String
    /// The badge CENTER in the host view's flipped (top-left, Y-down) screen space.
    var anchor: CGPoint
}

/// Pure layout: maps a constraint list + an entity-bounds resolver to badge placements.
/// Takes only value inputs (the constraints, and a `worldCenter(id) -> Vector?` lookup
/// plus a `worldToScreen` projection), so it is exercised headlessly without a live
/// `CADDrawing` / GPU / view.
enum ConstraintGlyphLayout {

    /// Vertical stack step (screen points) between successive badges that share the
    /// same anchor entity, so multiple constraints on one entity don't overprint.
    static let stackStep: CGFloat = 16

    /// The screen badge placements for `constraints`. For each constraint, the FIRST
    /// referenced entity's world center is looked up via `worldCenter`, projected with
    /// `worldToScreen`, then offset UPWARD (toward smaller screen-y) by a per-entity
    /// running stack index so co-anchored badges fan out. A constraint whose first
    /// entity has no resolvable center (deleted / empty bounds) is skipped.
    static func placements(
        for constraints: [Constraint],
        worldCenter: (EntityID) -> Vector?,
        worldToScreen: (Vector) -> CGPoint
    ) -> [ConstraintGlyphPlacement] {
        var out: [ConstraintGlyphPlacement] = []
        var stackByAnchor: [EntityID: Int] = [:]
        for c in constraints {
            guard let first = c.entityIDs.first,
                  let center = worldCenter(first) else { continue }
            let stack = stackByAnchor[first, default: 0]
            stackByAnchor[first] = stack + 1
            let base = worldToScreen(center)
            let anchor = CGPoint(x: base.x, y: base.y - CGFloat(stack) * stackStep)
            out.append(ConstraintGlyphPlacement(
                constraintID: c.id,
                label: ConstraintGlyph.label(for: c.kind),
                anchor: anchor))
        }
        return out
    }
}

// MARK: - The constraint glyph overlay view

/// A transparent, click-through `NSView` drawn over the canvas that renders a small
/// read-only badge near each constrained entity. Added as a subview of the
/// `FlippedMTKView`, kept covering the canvas bounds, and refreshed on every viewport
/// or model change (the mount drives `refresh()`), so the badges track pan/zoom and
/// constraint add/remove. Mirrors `UCSAxisOverlayView`: holds the `CanvasModel`
/// directly (it only READS it), `isFlipped`, and a `hitTest` that always returns `nil`.
@MainActor
final class ConstraintGlyphOverlayView: NSView {

    /// The shared canvas state (the constraint table, entity bounds, and viewport
    /// mapping). READ-ONLY here — this overlay never mutates the document.
    private let model: CanvasModel

    /// Whether the overlay participates. The mount drives this (e.g. tied to a
    /// "show constraints" toggle); when `false` it draws nothing. Default `true`.
    var isShowingGlyphs: Bool = true {
        didSet { if isShowingGlyphs != oldValue { needsDisplay = true } }
    }

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

    // MARK: Style constants (screen points)

    /// The badge font (constant on-screen size — it does NOT scale with zoom).
    private static let badgeFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The half-extent of the rounded badge chip around the centered glyph.
    private static let badgePadding: CGFloat = 4
    /// The badge corner radius.
    private static let badgeCornerRadius: CGFloat = 4

    private static var chipFill: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.16)
    }
    private static var chipStroke: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.85)
    }
    private static var glyphColor: NSColor { NSColor.controlAccentColor }

    // MARK: Click-through

    /// ALWAYS transparent to clicks: the constraint badges are pure chrome, so every
    /// click / drag falls through to the canvas exactly as if the overlay weren't there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Refresh

    /// Repaints the badges. Called by the controller on every viewport change (pan/zoom)
    /// and on constraint add/remove via `redraw`. Cheap: a handful of small chips.
    func refresh() { needsDisplay = true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isShowingGlyphs, !model.allConstraints.isEmpty else { return }

        let viewport = model.viewport
        let placements = ConstraintGlyphLayout.placements(
            for: model.allConstraints,
            worldCenter: { [model] id in
                guard let rec = model.drawing.entity(id) else { return nil }
                let box = rec.boundingBox()
                return box.isEmpty ? nil : box.center
            },
            worldToScreen: { viewport.worldToScreen($0) })

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.badgeFont,
            .foregroundColor: Self.glyphColor,
        ]

        for p in placements {
            let attributed = NSAttributedString(string: p.label, attributes: textAttrs)
            let textSize = attributed.size()
            // Rounded chip centered on the anchor.
            let chip = NSRect(
                x: p.anchor.x - textSize.width * 0.5 - Self.badgePadding,
                y: p.anchor.y - textSize.height * 0.5 - Self.badgePadding,
                width: textSize.width + Self.badgePadding * 2,
                height: textSize.height + Self.badgePadding * 2)
            let chipPath = NSBezierPath(
                roundedRect: chip,
                xRadius: Self.badgeCornerRadius, yRadius: Self.badgeCornerRadius)
            Self.chipFill.setFill()
            chipPath.fill()
            Self.chipStroke.setStroke()
            chipPath.lineWidth = 1
            chipPath.stroke()
            // Centered glyph.
            let textOrigin = CGPoint(
                x: p.anchor.x - textSize.width * 0.5,
                y: p.anchor.y - textSize.height * 0.5)
            attributed.draw(at: textOrigin)
        }
    }
}
