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
//  A constraint's badge anchors at its geometric FEATURE, so it reads where the user
//  expects: a perpendicular/parallel pair at the lines' INTERSECTION (the CORNER);
//  coincident/fix at the constrained point; distance at the midpoint of its two points;
//  horizontal/vertical at the line midpoint; radius at the circle center (`anchorWorld`).
//  The badge is then floated a small CONSTANT on-screen GAP (`offsetGap`) OFF that feature
//  along an OUTWARD direction (`outwardWorld` — perpendicular to a line for H/V/⊥/∥, the
//  outward corner bisector for a coincident vertex, up-right for a center) so it sits
//  BESIDE the geometry rather than ON it. The gap is applied in SCREEN space after the
//  world→screen projection, so it is a constant on-screen distance at any zoom. Badges
//  that still land on the same spot fan out by a small stack offset (keyed on the
//  quantized screen anchor) so they don't overprint. The overlay stays read-only + GPU-free.
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

    /// The constant on-screen GAP (in points, ~one badge size) a badge is floated OFF
    /// its feature so it sits BESIDE the geometry rather than on top of it. Applied in
    /// SCREEN space (after the world→screen projection) so the gap is the same at any
    /// zoom. The brief's "a bit away from the object" — a badge-size worth.
    static let offsetGap: CGFloat = 18

    /// The screen badge placements for `constraints`. Each constraint's WORLD anchor —
    /// its geometric FEATURE (e.g. the CORNER where two perpendicular lines meet) — is
    /// looked up via `worldAnchor` and projected with `worldToScreen`. The badge is then
    /// floated a constant `offsetGap` of SCREEN points OFF the feature, along the OUTWARD
    /// direction `worldOutward` returns for that constraint (perpendicular to a line for
    /// H/V/⊥/∥, the outward corner bisector for a coincident vertex, up-right for a
    /// center) so it sits beside the object instead of overlapping it. The outward
    /// direction is supplied in WORLD space and projected to screen here, so the gap
    /// stays a constant on-screen distance regardless of zoom. Finally a running stack
    /// index keyed on the QUANTIZED screen anchor nudges badges that still share a spot
    /// UPWARD so they fan out instead of overprinting. A constraint with no resolvable
    /// anchor (deleted entity / empty bounds) is skipped. When `worldOutward` returns nil
    /// (or is omitted) the badge keeps its old on-feature placement.
    static func placements(
        for constraints: [Constraint],
        worldAnchor: (Constraint) -> Vector?,
        worldToScreen: (Vector) -> CGPoint,
        worldOutward: (Constraint) -> Vector? = { _ in nil }
    ) -> [ConstraintGlyphPlacement] {
        var out: [ConstraintGlyphPlacement] = []
        var stackByKey: [Int64: Int] = [:]
        for c in constraints {
            guard let world = worldAnchor(c) else { continue }
            let base = worldToScreen(world)
            // Float the badge a constant SCREEN gap off the feature along the outward
            // direction. Project both the anchor and a stepped-along-the-direction world
            // point, then normalize the resulting SCREEN delta so the gap is zoom-stable
            // (and correct even under a flipped / non-uniform world→screen map).
            let gapped = Self.offset(base: base, world: world,
                                     outward: worldOutward(c), worldToScreen: worldToScreen)
            let key = Self.anchorKey(gapped)
            let stack = stackByKey[key, default: 0]
            stackByKey[key] = stack + 1
            let anchor = CGPoint(x: gapped.x, y: gapped.y - CGFloat(stack) * stackStep)
            out.append(ConstraintGlyphPlacement(
                constraintID: c.id,
                label: ConstraintGlyph.label(for: c.kind),
                anchor: anchor))
        }
        return out
    }

    /// Floats `base` (the feature's SCREEN point) by `offsetGap` screen points along the
    /// screen-space image of the world `outward` direction. Returns `base` unchanged when
    /// there is no usable direction (nil / zero / degenerate projection) — preserving the
    /// old on-feature placement. The direction is normalized in SCREEN space, so the gap
    /// is a constant on-screen distance at every zoom level.
    static func offset(base: CGPoint, world: Vector, outward: Vector?,
                       worldToScreen: (Vector) -> CGPoint) -> CGPoint {
        guard let dir = outward, dir.valid else { return base }
        let len = (dir.x * dir.x + dir.y * dir.y).squareRoot()
        guard len > 1e-12 else { return base }
        // A tiny world step along the direction, projected, gives the SCREEN direction.
        let stepped = Vector(world.x + dir.x / len, world.y + dir.y / len)
        let sp = worldToScreen(stepped)
        var dx = sp.x - base.x, dy = sp.y - base.y
        let slen = (dx * dx + dy * dy).squareRoot()
        guard slen > 1e-9 else { return base }
        dx /= slen; dy /= slen
        return CGPoint(x: base.x + dx * offsetGap, y: base.y + dy * offsetGap)
    }

    /// Quantizes a screen anchor (to ~half a badge) so genuinely co-located badges
    /// (e.g. two constraints at the same corner) stack instead of overprinting.
    private static func anchorKey(_ p: CGPoint) -> Int64 {
        Int64((p.x / 8).rounded()) &* 100_003 &+ Int64((p.y / 8).rounded())
    }

    /// Intersection of the two INFINITE lines (a1→a2) and (b1→b2) — the CORNER where a
    /// perpendicular/parallel pair meets — or nil when they are (near-)parallel. Pure
    /// math, kept here so it is unit-testable.
    static func lineIntersection(_ a1: Vector, _ a2: Vector,
                                 _ b1: Vector, _ b2: Vector) -> Vector? {
        let d1x = a2.x - a1.x, d1y = a2.y - a1.y
        let d2x = b2.x - b1.x, d2y = b2.y - b1.y
        let denom = d1x * d2y - d1y * d2x
        guard abs(denom) > 1e-9 else { return nil }
        let t = ((b1.x - a1.x) * d2y - (b1.y - a1.y) * d2x) / denom
        return Vector(a1.x + t * d1x, a1.y + t * d1y)
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

    // WARNING palette for a constraint the geometry does NOT satisfy (`.failed`
    // component): an orange tint so an UNSATISFIED constraint is never shown as if it
    // holds — the safety net for over-constrained DXF loads / edge cases that bypass the
    // manual-apply rollback.
    private static var warningChipFill: NSColor {
        NSColor.systemOrange.withAlphaComponent(0.18)
    }
    private static var warningChipStroke: NSColor {
        NSColor.systemOrange.withAlphaComponent(0.95)
    }
    private static var warningGlyphColor: NSColor { NSColor.systemOrange }

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
        // INFERRED constraints are HIDDEN (AutoCAD's inferred coincidence): the
        // auto-added corner-coincident companion of a perpendicular/parallel never gets
        // a badge — it is invisible to the user. Filter it out before laying out badges.
        let visibleConstraints = model.allConstraints.filter { !$0.inferred }
        guard isShowingGlyphs, !visibleConstraints.isEmpty else { return }

        let viewport = model.viewport
        let placements = ConstraintGlyphLayout.placements(
            for: visibleConstraints,
            worldAnchor: { [model] c in Self.anchorWorld(c, model: model) },
            worldToScreen: { viewport.worldToScreen($0) },
            worldOutward: { [model] c in Self.outwardWorld(c, model: model) })

        // Constraints the geometry does NOT satisfy (a `.failed` component) draw in the
        // WARNING palette so a dangling badge is never shown as if it holds.
        let unsatisfied = model.unsatisfiedConstraintIDs

        for p in placements {
            let warn = unsatisfied.contains(p.constraintID)
            let glyphColor = warn ? Self.warningGlyphColor : Self.glyphColor
            let fill = warn ? Self.warningChipFill : Self.chipFill
            let stroke = warn ? Self.warningChipStroke : Self.chipStroke

            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.badgeFont,
                .foregroundColor: glyphColor,
            ]
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
            fill.setFill()
            chipPath.fill()
            stroke.setStroke()
            chipPath.lineWidth = warn ? 1.5 : 1
            chipPath.stroke()
            // Centered glyph.
            let textOrigin = CGPoint(
                x: p.anchor.x - textSize.width * 0.5,
                y: p.anchor.y - textSize.height * 0.5)
            attributed.draw(at: textOrigin)
        }
    }

    // MARK: Anchor placement (badge sits at the constraint's geometric FEATURE)

    /// The WORLD point a constraint's badge anchors at — its geometric feature, so it
    /// reads where the user expects rather than floating by one entity:
    ///  • perpendicular / parallel (two lines) → the lines' INTERSECTION (the CORNER).
    ///    Truly parallel lines have no intersection → midpoint of the four endpoints.
    ///  • coincident / fix → the constrained point itself.
    ///  • distance → the midpoint of the two points.
    ///  • horizontal / vertical → the constrained line's midpoint.
    ///  • radius → the circle's center.
    ///  • anything else → the first entity's bounding-box center (fallback).
    private static func anchorWorld(_ c: Constraint, model: CanvasModel) -> Vector? {
        func pt(_ p: ConstraintPoint) -> Vector? { worldPoint(p, model: model) }
        switch c.kind {
        case .geometric(.perpendicular), .geometric(.parallel),
             .geometric(.collinear), .dimensional(.angle):
            // Two lines: anchor at their INTERSECTION (the corner / vertex); parallel /
            // collinear lines have no intersection → the 4-endpoint mean.
            guard c.points.count >= 4,
                  let a1 = pt(c.points[0]), let a2 = pt(c.points[1]),
                  let b1 = pt(c.points[2]), let b2 = pt(c.points[3])
            else { return fallbackCenter(c, model: model) }
            if let x = ConstraintGlyphLayout.lineIntersection(a1, a2, b1, b2) { return x }  // the corner
            return Vector((a1.x + a2.x + b1.x + b2.x) / 4,
                          (a1.y + a2.y + b1.y + b2.y) / 4)              // parallel: 4-pt mean

        case .geometric(.coincident), .geometric(.fix):
            guard let p = c.points.first.flatMap(pt) else { return fallbackCenter(c, model: model) }
            return p

        case .dimensional(.distance),
             .dimensional(.horizontalDistance), .dimensional(.verticalDistance),
             .geometric(.horizontal), .geometric(.vertical),
             .geometric(.concentric):
            // A measured / related PAIR: anchor at the midpoint of the two points (for
            // concentric, the two near-coincident centers — the shared center).
            guard c.points.count >= 2, let p0 = pt(c.points[0]), let p1 = pt(c.points[1])
            else { return fallbackCenter(c, model: model) }
            return Vector((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)

        case .dimensional(.radius), .dimensional(.diameter):
            guard let id = c.points.first?.entityID,
                  let center = pt(ConstraintPoint(entityID: id, point: .center))
            else { return fallbackCenter(c, model: model) }
            return center

        case .geometric(.equal):
            // Two lines (4 points) → mean of the four endpoints; two circulars (2 points)
            // → midpoint of the two centers. Either way, the mean of the resolved points.
            let pts = c.points.compactMap(pt)
            guard !pts.isEmpty else { return fallbackCenter(c, model: model) }
            let sx = pts.reduce(0) { $0 + $1.x }, sy = pts.reduce(0) { $0 + $1.y }
            return Vector(sx / Double(pts.count), sy / Double(pts.count))

        default:
            return fallbackCenter(c, model: model)
        }
    }

    // MARK: Outward offset direction (badge floats a screen GAP off the feature)

    /// The WORLD-space OUTWARD direction a constraint's badge is floated along (a constant
    /// screen gap, projected + normalized in screen space by `ConstraintGlyphLayout`) so it
    /// sits BESIDE the geometry rather than on it. Returns an UNNORMALIZED direction (only
    /// its bearing matters); nil keeps the old on-feature placement:
    ///  • horizontal / vertical (one line) → PERPENDICULAR to the line direction (the +normal,
    ///    flipped to point away from the drawing's overall centroid when cheap), so the badge
    ///    floats just OFF the line midpoint.
    ///  • perpendicular / parallel / collinear / angle (two lines) → away from the CORNER toward
    ///    the outward direction of the two segments (so the badge clears the vertex region).
    ///  • coincident / fix → the OUTWARD bisector of the two meeting segments (away from the
    ///    corner interior) so the badge doesn't cover the corner.
    ///  • concentric / radius / diameter (a center) → a fixed UP-RIGHT nudge off the center.
    ///  • anything else → up-right (a stable default).
    private static func outwardWorld(_ c: Constraint, model: CanvasModel) -> Vector? {
        func pt(_ p: ConstraintPoint) -> Vector? { worldPoint(p, model: model) }
        let upRight = Vector(1, 1)
        switch c.kind {
        case .geometric(.horizontal), .geometric(.vertical):
            // One line: the badge floats off the midpoint along the line's +normal,
            // flipped to point away from the drawing centroid so it tends OUTWARD.
            guard c.points.count >= 2, let a = pt(c.points[0]), let b = pt(c.points[1])
            else { return upRight }
            let dir = Vector(b.x - a.x, b.y - a.y)
            guard dir.magnitude > 1e-9 else { return upRight }
            let normal = Vector(-dir.y, dir.x)             // +90° rotation of the line dir
            let mid = Vector((a.x + b.x) / 2, (a.y + b.y) / 2)
            return outwardified(normal, at: mid, model: model)

        case .geometric(.perpendicular), .geometric(.parallel),
             .geometric(.collinear), .dimensional(.angle):
            // Two lines: float away from the corner, summing the two outward segment
            // directions (each pointing from the shared vertex toward the segment).
            return cornerOutward(c, model: model) ?? upRight

        case .geometric(.coincident), .geometric(.fix):
            // A meeting vertex of (up to) two segments: the OUTWARD bisector — away from
            // the interior the two segments span.
            return cornerOutward(c, model: model) ?? upRight

        default:
            // Centers (radius/diameter/concentric) and every other kind: a fixed up-right
            // nudge off the anchor is enough to clear the geometry.
            return upRight
        }
    }

    /// Flips `dir` so it points AWAY from the drawing's overall centroid when that is cheap
    /// to know, giving a consistent "outward" side for a free perpendicular (otherwise the
    /// raw +normal). Keeps `dir` if the centroid is unavailable / degenerate.
    private static func outwardified(_ dir: Vector, at anchor: Vector, model: CanvasModel) -> Vector {
        let box = model.drawing.boundingBox()
        guard !box.isEmpty else { return dir }
        let center = box.center
        let away = Vector(anchor.x - center.x, anchor.y - center.y)
        guard away.magnitude > 1e-9 else { return dir }
        // If the +normal points back toward the centroid, flip it to point away.
        return (dir.x * away.x + dir.y * away.y) < 0 ? Vector(-dir.x, -dir.y) : dir
    }

    /// The OUTWARD direction at a shared CORNER: for each of the constraint's first two
    /// points, the far endpoint of that point's owning line gives the segment direction
    /// FROM the vertex; the badge floats along the NEGATIVE sum of those unit directions
    /// (i.e. the outward corner bisector, away from the interior the segments enclose).
    /// nil when fewer than one usable segment resolves.
    private static func cornerOutward(_ c: Constraint, model: CanvasModel) -> Vector? {
        var interior = Vector(0, 0)
        var found = 0
        for p in c.points.prefix(2) {
            guard let from = worldPoint(p, model: model),
                  let far = farEndpoint(of: p, model: model) else { continue }
            let seg = Vector(far.x - from.x, far.y - from.y)
            let len = seg.magnitude
            guard len > 1e-9 else { continue }
            interior = Vector(interior.x + seg.x / len, interior.y + seg.y / len)
            found += 1
        }
        guard found > 0 else { return nil }
        // Outward = away from the segments' interior. If the two are collinear-opposite
        // (interior ~0), fall back to one segment's left-normal so the badge still clears.
        if interior.magnitude > 1e-9 {
            return Vector(-interior.x, -interior.y)
        }
        for p in c.points.prefix(2) {
            if let from = worldPoint(p, model: model),
               let far = farEndpoint(of: p, model: model) {
                let seg = Vector(far.x - from.x, far.y - from.y)
                if seg.magnitude > 1e-9 { return Vector(-seg.y, seg.x) }
            }
        }
        return nil
    }

    /// The OTHER endpoint of the LINE a constraint point names (its `start` ↔ `end`),
    /// giving the segment's far end from that vertex. nil for a non-line entity.
    private static func farEndpoint(of p: ConstraintPoint, model: CanvasModel) -> Vector? {
        guard let rec = model.drawing.entity(p.entityID), case .line(let d) = rec.kind
        else { return nil }
        switch p.point {
        case .start:  return d.end
        case .end:    return d.start
        case .center: return nil                 // a midpoint has no single "far" end
        }
    }

    /// The world coordinate a `ConstraintPoint` names: a line's start/end/midpoint, a
    /// circle's center, a point's position; else the entity's bbox center.
    private static func worldPoint(_ p: ConstraintPoint, model: CanvasModel) -> Vector? {
        guard let rec = model.drawing.entity(p.entityID) else { return nil }
        switch rec.kind {
        case .line(let d):
            switch p.point {
            case .start:  return d.start
            case .end:    return d.end
            case .center: return Vector((d.start.x + d.end.x) / 2, (d.start.y + d.end.y) / 2)
            }
        case .circle(let d):  return d.center
        case .arc(let d):     return d.center
        case .ellipse(let d): return d.center
        case .point(let d):   return d.position
        default:
            let box = rec.boundingBox()
            return box.isEmpty ? nil : box.center
        }
    }

    /// The first entity's bbox center (legacy fallback when a feature point can't resolve).
    private static func fallbackCenter(_ c: Constraint, model: CanvasModel) -> Vector? {
        guard let first = c.entityIDs.first, let rec = model.drawing.entity(first) else { return nil }
        let box = rec.boundingBox()
        return box.isEmpty ? nil : box.center
    }

}
