//
//  LayoutViewport.swift
//  CADEngine
//
//  Paper-space P3 — a VIEWPORT entity (paperspace-plan §3 row P3): a rectangular
//  window on a layout SHEET that shows a SCALED view of MODEL space. A drafter
//  places one or more viewports on a paper sheet so the printed page shows the
//  model (often the same model at several scales — a detail blow-up, a plan, a
//  section). The value-type port of an AutoCAD VIEWPORT (DXF VIEWPORT /
//  DRW_Viewport).
//
//  ## Naming — why NOT "Viewport"
//  The name `Viewport` is already TAKEN: `Viewport.swift` is the f64 world↔screen
//  RENDER CAMERA (scale/center/size + the GPU world→clip matrix). This entity is a
//  different thing — a *document* object on a sheet — so it is `LayoutViewport`. Its
//  pure math (the child camera it implies, the model→paper affine, the clip)
//  DELEGATES to / mirrors `Viewport` so there is one transform kernel.
//
//  ## Where it lives — NOT on `EntityKind`
//  Viewports are NOT an `EntityKind` case (that enum is switched exhaustively in
//  ~28 files; adding a case is a serialized critical section). They live in a
//  SEPARATE per-layout list — `Layout.viewports: [LayoutViewport]` — exactly as the
//  paperspace-plan §2 architecture prescribes (viewports ride inside the `Layout`
//  value, so layout add/remove/rename undo carries them for free).
//
//  ## v1 cut (documented follow-ups)
//  Rectangular clip; the scale is FIXED at creation (DERIVED, not stored — see
//  `scale`). W2-2D ADDED (DOCUMENT-PAYLOAD only — Codable carries them; DXF
//  persistence is a later wave): the on/off display flag (`displayOn`), the view
//  twist (`twistRadians`), and per-viewport frozen layers (`frozenLayers`). Still
//  OMITTED for v1: a per-viewport UCS, and the DXF round-trip of these three fields.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics

// MARK: - AABB Codable/Hashable (additive conformance for LayoutViewport)
//
// `AABB` (Geometry.swift) is only `Sendable, Equatable`. `LayoutViewport` needs to
// be `Codable, Hashable` and carries an `AABB` (`paperRect`), so we add those two
// conformances HERE (additively, in this owned file — Geometry.swift is not ours
// to touch). `AABB`'s only stored members are two `Vector`s, both already
// `Codable`/`Hashable`, so the conformances below are exact + lossless. (Automatic
// synthesis can't run in a cross-file extension, so we spell `init(from:)` /
// `encode(to:)` / `hash(into:)` out explicitly — `Equatable` is already declared
// on the type in Geometry.swift.)
extension AABB: Codable {
    private enum CodingKeys: String, CodingKey { case min, max }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mn = try c.decode(Vector.self, forKey: .min)
        let mx = try c.decode(Vector.self, forKey: .max)
        self.init(min: mn, max: mx)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(min, forKey: .min)
        try c.encode(max, forKey: .max)
    }
}

extension AABB: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(min)
        hasher.combine(max)
    }
}

// MARK: - A paper-space viewport (a window on the sheet showing model space)

/// One paper-space viewport — a rectangular window on a layout sheet that shows a
/// scaled view of model space. The value-type port of an AutoCAD VIEWPORT.
///
/// ## Coordinate spaces
///  - `paperRect` is in PAPER (sheet) coordinates — the same world-units-on-the-
///    sheet space the `PageDescriptor` sheet rect uses (mm, lower-left origin). It
///    is the frame the viewport draws within and clips to.
///  - `viewCenter` / `viewHeight` describe the MODEL-space view shown inside that
///    frame: `viewCenter` is the model point mapped to the CENTER of `paperRect`,
///    and `viewHeight` is how many MODEL units tall the visible model window is.
///
/// ## Scale is DERIVED, not stored
/// The plot scale (paper-units per model-unit) is `paperRect.height / viewHeight`.
/// Storing only `viewHeight` (not a scale factor) keeps the model exact: changing
/// the frame height OR the model window re-derives the scale, and a degenerate
/// `viewHeight == 0` is clamped (never a divide-by-zero / NaN). This mirrors how
/// DXF stores a viewport (code 41 paper height + code 45 model view height, not a
/// scale ratio).
public struct LayoutViewport: Sendable, Hashable, Codable, Identifiable {

    /// Stable identity (so SwiftUI lists / selection key on it and edits address a
    /// specific viewport). Minted fresh on creation.
    public var id: UUID

    /// The viewport's frame on the sheet, in PAPER coordinates (mm, lower-left
    /// origin — the same space as the `PageDescriptor` sheet rect). The window the
    /// model view is drawn within and clipped to.
    public var paperRect: AABB

    /// The MODEL-space point mapped to the CENTER of `paperRect`.
    public var viewCenter: Vector

    /// How many MODEL units tall the visible model window is. Together with
    /// `paperRect.height` this derives the plot scale (see `scale`). Always coerced
    /// to a positive, finite value by the initializer (a degenerate input is clamped
    /// to `minViewHeight`).
    public var viewHeight: Double

    /// The smallest model view height we allow — keeps `scale` finite and the
    /// child camera invertible even for a hand-built / corrupt value.
    public static let minViewHeight = 1.0e-9

    // MARK: - W2-2D per-viewport display state (DOCUMENT-PAYLOAD only; DXF later)
    //
    // Three ADDITIVE fields that ride inside the `Layout` value (so layout undo +
    // the document payload carry them for free). All default to "no effect", so a
    // viewport built without them — and every OLD payload, which has none of these
    // keys (see the `decodeIfPresent` `init(from:)` below) — behaves exactly as
    // before: shown, untwisted, nothing frozen.

    /// Whether this viewport's CONTENTS are drawn (the AutoCAD viewport "On/Off"
    /// display flag, DXF VIEWPORT status bit). `false` hides everything the viewport
    /// shows (its frame outline still draws — the window is just empty). Defaults to
    /// `true` (shown).
    public var displayOn: Bool = true

    /// The view TWIST angle in RADIANS — the model view is rotated about
    /// `viewCenter` by this angle inside the frame (the AutoCAD viewport "Twist
    /// angle" / DXF code 51). Engine CCW convention (`Vector.rotated(by:)`). Defaults
    /// to `0` (no twist); a non-finite stored value is coerced to `0` so it can never
    /// produce NaN geometry.
    public var twistRadians: Double = 0

    /// Layer NAMES frozen IN THIS VIEWPORT (the AutoCAD per-viewport layer freeze /
    /// DXF VP_FREEZE). An entity on a frozen layer is excluded from THIS viewport's
    /// contents ONLY — model space and every other viewport still show it. Matched by
    /// exact name (the same exact-name match `LayerTable.layer(_:)` uses). Defaults to
    /// empty (nothing frozen).
    public var frozenLayers: Set<String> = []

    public init(
        id: UUID = UUID(),
        paperRect: AABB,
        viewCenter: Vector,
        viewHeight: Double,
        displayOn: Bool = true,
        twistRadians: Double = 0,
        frozenLayers: Set<String> = []
    ) {
        self.id = id
        self.paperRect = paperRect
        self.viewCenter = viewCenter.valid ? viewCenter : Vector(0, 0)
        self.viewHeight = LayoutViewport.clampHeight(viewHeight)
        self.displayOn = displayOn
        // Coerce a non-finite twist to 0 so a hand-built / corrupt value cannot
        // produce NaN paper coordinates in `modelToPaper`.
        self.twistRadians = twistRadians.isFinite ? twistRadians : 0
        self.frozenLayers = frozenLayers
    }

    /// Clamps a model view height to a positive, finite value (`>= minViewHeight`),
    /// so the derived scale + child camera are always well-defined.
    static func clampHeight(_ h: Double) -> Double {
        (h.isFinite && h > 0) ? Swift.max(h, minViewHeight) : minViewHeight
    }

    // MARK: - Derived geometry

    /// The plot SCALE: paper-units-on-the-sheet per MODEL unit
    /// (`paperRect.height / viewHeight`). For a fitted viewport this is the ratio
    /// that makes `viewHeight` model units fill the frame's height. Always finite
    /// and positive (`viewHeight` is clamped; a degenerate `paperRect` yields a
    /// `0` height → scale `0`, which the consumers treat as "nothing visible").
    public var scale: Double {
        let ph = paperHeight
        guard ph > 0 else { return 0 }
        return ph / viewHeight
    }

    /// The frame's height in paper units (0 for an empty/degenerate rect).
    public var paperHeight: Double {
        paperRect.isEmpty ? 0 : Swift.max(paperRect.size.y, 0)
    }

    /// The frame's width in paper units (0 for an empty/degenerate rect).
    public var paperWidth: Double {
        paperRect.isEmpty ? 0 : Swift.max(paperRect.size.x, 0)
    }

    /// The paper-space center of the frame (the point `viewCenter` maps to).
    public var paperCenter: Vector {
        let c = paperRect.center
        return c.valid ? Vector(c.x, c.y) : Vector(0, 0)
    }

    // MARK: - Framing (compute view from a model extent — the tool's geometry)

    /// Builds a viewport that frames `modelExtents` (a model-space AABB) inside
    /// `paperRect`, centered, at the scale that makes the WHOLE extent fit (the
    /// tighter of the two axes, so nothing is cropped) with a small margin. This is
    /// the "create a viewport that shows the whole model" framing the `ViewportTool`
    /// uses: two clicks define `paperRect`, then the model extent is fitted into it.
    ///
    /// A degenerate `paperRect` (zero area) or an empty `modelExtents` falls back to
    /// the extent's center (or the origin) at a unit view height, so the result is
    /// always a valid, NaN-free viewport.
    ///
    /// - Parameters:
    ///   - paperRect: the frame on the sheet (paper coords).
    ///   - modelExtents: the model AABB to frame.
    ///   - marginFraction: per-edge inset as a fraction of the frame (default 5%),
    ///     so the framed model is not flush against the frame edge.
    public static func framing(
        paperRect: AABB,
        modelExtents: AABB,
        marginFraction: Double = 0.05,
        id: UUID = UUID()
    ) -> LayoutViewport {
        let pw = paperRect.isEmpty ? 0 : Swift.max(paperRect.size.x, 0)
        let ph = paperRect.isEmpty ? 0 : Swift.max(paperRect.size.y, 0)

        // The model point we want centered. Empty extent → world origin.
        let center: Vector = {
            let c = modelExtents.center
            return c.valid ? Vector(c.x, c.y) : Vector(0, 0)
        }()

        // Degenerate frame / empty model → a unit-height view centered on the model.
        guard pw > 0, ph > 0, !modelExtents.isEmpty else {
            return LayoutViewport(id: id, paperRect: paperRect, viewCenter: center, viewHeight: 1)
        }

        let frac = (marginFraction.isFinite && marginFraction >= 0 && marginFraction < 0.5)
            ? marginFraction : 0.05
        // Usable frame fraction after the per-edge margin (never <= 0).
        let usable = Swift.max(1.0 - 2.0 * frac, 1.0e-6)

        let mw = Swift.max(modelExtents.size.x, 0)
        let mh = Swift.max(modelExtents.size.y, 0)

        // Pick the model view height that fits the tighter axis. The view's aspect is
        // the FRAME's aspect (the camera fills the frame), so to make the model fit:
        //   horizontally: viewWidth  >= mw / usable, and viewWidth = viewHeight*(pw/ph)
        //   vertically:   viewHeight >= mh / usable
        // → viewHeight >= max(mh/usable, (mw/usable) * ph/pw).
        let needV = (mh > 0) ? mh / usable : 0
        let needHasV = (mw > 0) ? (mw / usable) * (ph / pw) : 0
        let viewHeight = Swift.max(needV, needHasV)
        let clamped = (viewHeight.isFinite && viewHeight > 0) ? viewHeight : 1

        return LayoutViewport(id: id, paperRect: paperRect, viewCenter: center, viewHeight: clamped)
    }

    // MARK: - The implied child camera (model → paper)

    /// The `Viewport` (render camera) this viewport implies over MODEL space: it
    /// maps a model point to the position inside `paperRect` it should appear, using
    /// the EXACT same `Viewport` math the on-screen camera uses (so there is one
    /// transform kernel). The camera's `scale` is `scale` (paper-per-model), its
    /// `center` is `viewCenter`, and its `size` is the frame size in paper units.
    ///
    /// Because `Viewport.worldToScreen` puts `center` at the MIDDLE of `size` with a
    /// Y-DOWN flip, the returned points are in a frame-local, top-left-origin space;
    /// `modelToPaper(_:)` re-flips + offsets them to absolute paper coordinates
    /// (Y-up, lower-left origin) so they compose with `paperRect` directly. Use
    /// `modelToPaper` for the paper-space mapping; this is exposed for callers that
    /// want the underlying camera (e.g. its `visibleWorldRect` for culling).
    public func childCamera() -> Viewport {
        Viewport(
            scale: scale > 0 ? scale : Viewport.minScale,
            center: viewCenter,
            size: CGSize(width: paperWidth, height: paperHeight)
        )
    }

    /// The model-space AABB currently visible through this viewport (the window of
    /// model the frame shows). Used to cull which model entities feed the viewport.
    public func visibleModelRect() -> AABB {
        guard scale > 0 else {
            // Degenerate frame: nothing meaningfully visible; collapse to the center.
            return AABB(point: viewCenter)
        }
        return childCamera().visibleWorldRect
    }

    /// Maps a MODEL-space point to its absolute PAPER-space position (mm, lower-left
    /// origin — composes directly with `paperRect`). Derivation: a model point at
    /// `viewCenter` lands at `paperCenter`; each model unit is `scale` paper units;
    /// +Y model goes +Y on the sheet (paper is Y-up, like model — no flip here).
    ///   `paper = paperCenter + rot(model - viewCenter, twist) * scale`.
    ///
    /// The model offset is rotated about `viewCenter` by `twistRadians` BEFORE the
    /// scale (the W2-2D view twist). A zero — or non-finite — twist takes the original
    /// untwisted path, so a DEFAULT viewport (twist 0) maps BYTE-IDENTICALLY to
    /// before (the `c.x + dx * s` expression is literally unchanged).
    public func modelToPaper(_ model: Vector) -> Vector {
        let s = scale
        let c = paperCenter
        let dx = model.x - viewCenter.x
        let dy = model.y - viewCenter.y
        if twistRadians != 0, twistRadians.isFinite {
            let r = Vector(dx, dy).rotated(by: twistRadians)
            return Vector(c.x + r.x * s, c.y + r.y * s)
        }
        return Vector(c.x + dx * s, c.y + dy * s)
    }

    // MARK: - W2-2D render decisions (PURE — one source of truth for the renderer)

    /// Whether this viewport's CONTENTS should be drawn at all. `false` when the
    /// display is turned OFF (`displayOn == false`) OR the frame is degenerate
    /// (`scale == 0`, nothing visible). The renderer skips the whole viewport when
    /// this is false. For a DEFAULT viewport (`displayOn == true`) this is exactly
    /// `scale > 0` — the same gate the renderer used before W2-2D (byte-identical).
    public var drawsContents: Bool { displayOn && scale > 0 }

    /// Whether an entity on layer `name` is FROZEN in this viewport (so it is
    /// excluded from THIS viewport's contents only — model space and other viewports
    /// are unaffected). Always `false` for the default (empty `frozenLayers`), so a
    /// default viewport excludes nothing (byte-identical). Exact-name match.
    public func freezesLayer(_ name: String) -> Bool {
        !frozenLayers.isEmpty && frozenLayers.contains(name)
    }

    // MARK: - Cohen–Sutherland segment clip to the frame

    /// Out-codes for Cohen–Sutherland clipping against `paperRect`. Internal (not
    /// private) so the static `cohenSutherland` kernel can take it as a parameter
    /// and focused tests can reach it via `@testable import`.
    struct OutCode: OptionSet {
        let rawValue: Int
        static let inside = OutCode([])
        static let left   = OutCode(rawValue: 1)
        static let right  = OutCode(rawValue: 2)
        static let bottom = OutCode(rawValue: 4)
        static let top    = OutCode(rawValue: 8)
    }

    func outCode(_ p: Vector, _ rect: AABB) -> OutCode {
        var code: OutCode = .inside
        if p.x < rect.min.x { code.insert(.left) }
        else if p.x > rect.max.x { code.insert(.right) }
        if p.y < rect.min.y { code.insert(.bottom) }
        else if p.y > rect.max.y { code.insert(.top) }
        return code
    }

    /// Clips a PAPER-space line segment `(a, b)` to `paperRect` (Cohen–Sutherland).
    /// Returns the clipped segment endpoints, or `nil` if the segment lies wholly
    /// outside the frame. A segment fully inside is returned unchanged. Robust to a
    /// degenerate (empty/zero-size) `paperRect` — that clips everything away
    /// (returns `nil`), and a point segment is returned only if it is inside.
    public func clipToFrame(_ a: Vector, _ b: Vector) -> (Vector, Vector)? {
        let rect = paperRect
        guard !rect.isEmpty else { return nil }
        return LayoutViewport.cohenSutherland(a, b, rect: rect, outCode: outCode)
    }

    /// The pure Cohen–Sutherland kernel — clips segment `(p0, p1)` to `rect`. Static
    /// so it is reachable for focused unit tests; takes the out-code computer to
    /// avoid duplicating the rect-edge comparisons.
    static func cohenSutherland(
        _ p0: Vector, _ p1: Vector, rect: AABB,
        outCode: (Vector, AABB) -> OutCode
    ) -> (Vector, Vector)? {
        var a = p0
        var b = p1
        var codeA = outCode(a, rect)
        var codeB = outCode(b, rect)
        // Bound the iteration so a pathological (NaN) input can never spin forever.
        var guardCount = 0

        while guardCount < 8 {
            guardCount += 1
            if codeA.isEmpty && codeB.isEmpty {
                return (a, b)                 // both inside → accept
            }
            if !codeA.intersection(codeB).isEmpty {
                return nil                    // both share an outside region → reject
            }
            // Pick an endpoint that is outside.
            let codeOut = !codeA.isEmpty ? codeA : codeB
            var x = 0.0
            var y = 0.0
            let dx = b.x - a.x
            let dy = b.y - a.y
            if codeOut.contains(.top) {
                guard dy != 0 else { return nil }
                x = a.x + dx * (rect.max.y - a.y) / dy
                y = rect.max.y
            } else if codeOut.contains(.bottom) {
                guard dy != 0 else { return nil }
                x = a.x + dx * (rect.min.y - a.y) / dy
                y = rect.min.y
            } else if codeOut.contains(.right) {
                guard dx != 0 else { return nil }
                y = a.y + dy * (rect.max.x - a.x) / dx
                x = rect.max.x
            } else if codeOut.contains(.left) {
                guard dx != 0 else { return nil }
                y = a.y + dy * (rect.min.x - a.x) / dx
                x = rect.min.x
            } else {
                return nil
            }
            guard x.isFinite, y.isFinite else { return nil }
            let clipped = Vector(x, y)
            if codeOut == codeA {
                a = clipped
                codeA = outCode(a, rect)
            } else {
                b = clipped
                codeB = outCode(b, rect)
            }
        }
        // If we hit the iteration bound, accept the (possibly partially) clipped
        // segment only when both ends are now inside; otherwise reject.
        return (codeA.isEmpty && codeB.isEmpty) ? (a, b) : nil
    }

    /// Clips a PAPER-space POLYLINE (already mapped via `modelToPaper`) to the frame,
    /// returning the surviving segments. Each input segment `points[i]..points[i+1]`
    /// (plus the closing edge when `closed`) is clipped independently — so a polyline
    /// that crosses the frame edge yields the in-frame pieces, dropping the rest.
    /// A polyline of fewer than 2 points yields no segments.
    public func clipPolylineToFrame(_ points: [Vector], closed: Bool) -> [(Vector, Vector)] {
        guard points.count >= 2 else { return [] }
        var out: [(Vector, Vector)] = []
        for i in 0..<(points.count - 1) {
            if let seg = clipToFrame(points[i], points[i + 1]) { out.append(seg) }
        }
        if closed, points.count >= 3, let seg = clipToFrame(points[points.count - 1], points[0]) {
            out.append(seg)
        }
        return out
    }
}

// MARK: - Codable (back-compat: tolerate the missing W2-2D fields)
//
// `displayOn` / `twistRadians` / `frozenLayers` are ADDITIVE (W2-2D): a viewport
// encoded BEFORE they existed (every old document payload) has none of these keys.
// A hand-written `init(from:)` with `decodeIfPresent` (the SAME pattern `Layout`
// uses for its additive `viewports`, Layout.swift:184) decodes those absent keys to
// their defaults (on / no twist / nothing frozen), so old payloads round-trip
// unchanged. We DELEGATE to the memberwise init so the same validation runs on
// decode (twist non-finite ⇒ 0, viewHeight clamped). `encode(to:)` stays synthesized
// off the explicit `CodingKeys` (which list every field, so it emits all of them);
// `Hashable`/`Equatable` stay synthesized too (they auto-include the new stored
// properties).
extension LayoutViewport {
    private enum CodingKeys: String, CodingKey {
        case id, paperRect, viewCenter, viewHeight, displayOn, twistRadians, frozenLayers
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let paperRect = try c.decode(AABB.self, forKey: .paperRect)
        let viewCenter = try c.decode(Vector.self, forKey: .viewCenter)
        let viewHeight = try c.decode(Double.self, forKey: .viewHeight)
        // Additive W2-2D fields: absent in old payloads ⇒ defaults.
        let displayOn = try c.decodeIfPresent(Bool.self, forKey: .displayOn) ?? true
        let twistRadians = try c.decodeIfPresent(Double.self, forKey: .twistRadians) ?? 0
        let frozenLayers = try c.decodeIfPresent(Set<String>.self, forKey: .frozenLayers) ?? []
        self.init(id: id, paperRect: paperRect, viewCenter: viewCenter, viewHeight: viewHeight,
                  displayOn: displayOn, twistRadians: twistRadians, frozenLayers: frozenLayers)
    }
}
