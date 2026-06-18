//
//  Entity.swift
//  CADEngine
//
//  The frozen entity model (ADR-001): every entity is a value `struct` holding
//  only its DEFINING data. Common attributes (id, layer, pen, flags) live on the
//  `EntityRecord` wrapper; the geometry-specific defining data lives in the
//  `EntityKind` enum's associated `*Data` values. This mirrors LibreCAD's split
//  of RS_Entity (common attrs) + RS_*Data (per-type defining data), but with NO
//  stored child graph — derived geometry is produced on demand by `resolve()`.
//
//  GPLv2-or-later (LibreCAD derivative). The *Data fields mirror the RS_*Data
//  structs in librecad/src/lib/engine/.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_*Data).
//

import Foundation

// MARK: - Per-entity defining data (the RS_*Data equivalents)

/// The on-screen display style for a point entity — the value-type port of
/// AutoCAD's `$PDMODE` point-marker encoding (`RS_Point` honors the document
/// `$PDMODE`/`$PDSIZE`). A `PointDisplayMode` wraps the raw DXF `$PDMODE` integer
/// so it round-trips losslessly, and decodes that integer into a **base glyph**
/// (the low bits) plus two independent **enclosure bits** (a circle and/or a
/// square drawn AROUND the glyph). The resolve step (`Resolve.swift` `.point`
/// arm) reads these to emit the marker geometry.
///
/// ## `$PDMODE` encoding (AutoCAD)
/// - Low value (bits 0–2, i.e. `value & 0b111`) selects the base glyph:
///   `0` dot · `1` none (empty) · `2` plus (+) · `3` cross (×) · `4` tick (↑).
/// - Bit 5 (`+32`) draws a **circle** around the glyph.
/// - Bit 6 (`+64`) draws a **square** around the glyph.
///
/// So e.g. `$PDMODE = 35` is `3` (cross) `+ 32` (circle); `$PDMODE = 66` is
/// `2` (plus) `+ 64` (square). The full combination space is supported (any base
/// glyph with either / both enclosures), not just a fixed subset.
public struct PointDisplayMode: Sendable, Hashable, Codable {
    /// The base marker glyph (`$PDMODE` low bits).
    public enum Glyph: Int, Sendable, Hashable, Codable, CaseIterable {
        /// A single dot — `$PDMODE` base `0` (the default).
        case dot = 0
        /// Nothing drawn for the glyph itself (an empty marker; only the
        /// enclosure bits, if any, draw) — `$PDMODE` base `1`.
        case none = 1
        /// A plus sign `+` (axis-aligned) — `$PDMODE` base `2`.
        case plus = 2
        /// An X (diagonal cross) — `$PDMODE` base `3`.
        case cross = 3
        /// A vertical tick running UP from the point — `$PDMODE` base `4`.
        case tick = 4
    }

    /// The raw DXF `$PDMODE` integer (round-trips losslessly). Decoded into the
    /// `glyph` + `hasCircle`/`hasSquare` accessors below.
    public var rawMode: Int

    public init(rawMode: Int) { self.rawMode = rawMode }

    /// Builds a mode from a base glyph + the two enclosure flags.
    public init(glyph: Glyph, circle: Bool = false, square: Bool = false) {
        self.rawMode = glyph.rawValue | (circle ? 32 : 0) | (square ? 64 : 0)
    }

    /// The base glyph (`rawMode & 0b111`). An unknown low value falls back to a
    /// dot so an exotic `$PDMODE` still renders something.
    public var glyph: Glyph { Glyph(rawValue: rawMode & 0b111) ?? .dot }

    /// Whether a circle is drawn around the glyph (`$PDMODE` bit 5, `+32`).
    public var hasCircle: Bool { (rawMode & 32) != 0 }

    /// Whether a square is drawn around the glyph (`$PDMODE` bit 6, `+64`).
    public var hasSquare: Bool { (rawMode & 64) != 0 }

    // Named convenience values (the common AutoCAD point styles).
    /// `$PDMODE 0` — a single dot (the engine default).
    public static let dot = PointDisplayMode(rawMode: 0)
    /// `$PDMODE 1` — nothing drawn.
    public static let none = PointDisplayMode(glyph: .none)
    /// `$PDMODE 2` — a plus sign.
    public static let plus = PointDisplayMode(glyph: .plus)
    /// `$PDMODE 3` — an X.
    public static let cross = PointDisplayMode(glyph: .cross)
    /// `$PDMODE 4` — a vertical tick.
    public static let tick = PointDisplayMode(glyph: .tick)
    /// `$PDMODE 32` — a circle around a dot.
    public static let circle = PointDisplayMode(glyph: .dot, circle: true)
    /// `$PDMODE 64` — a square around a dot.
    public static let square = PointDisplayMode(glyph: .dot, square: true)
}

/// `RS_PointData` — a single position, plus its on-screen display style.
///
/// `style` is ADDITIVE (decision §7): it defaults to `.dot` so existing data and
/// every existing caller is unchanged, and it decodes back-compatibly (a point
/// serialized before this field decodes to `.dot`). A point with the default
/// `.dot` style resolves to the historical single-point marker (so the existing
/// point/render tests are unaffected); any other style resolves to its marker
/// glyph geometry. A point whose style is left at `.dot` (the inherit sentinel —
/// see the resolve arm) picks up the document `$PDMODE`/`$PDSIZE` default.
public struct PointData: Sendable, Hashable, Codable {
    public var position: Vector
    /// The point's display style (`$PDMODE` encoding). Defaults to `.dot`. When
    /// left at `.dot`, the resolve step substitutes the document `$PDMODE`
    /// default so a drawing-wide point style applies to points with no explicit
    /// per-entity style.
    public var style: PointDisplayMode
    public init(position: Vector, style: PointDisplayMode = .dot) {
        self.position = position
        self.style = style
    }
}

// MARK: - Decodable (back-compat: tolerate a missing point style → `.dot`)

extension PointData {
    private enum CodingKeys: String, CodingKey { case position, style }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(Vector.self, forKey: .position)
        style = try c.decodeIfPresent(PointDisplayMode.self, forKey: .style) ?? .dot
    }
}

/// `RS_LineData` — two endpoints.
public struct LineData: Sendable, Hashable, Codable {
    public var start: Vector
    public var end: Vector
    public init(start: Vector, end: Vector) {
        self.start = start
        self.end = end
    }
}

/// `RS_CircleData` — center + radius.
public struct CircleData: Sendable, Hashable, Codable {
    public var center: Vector
    public var radius: Double
    public init(center: Vector, radius: Double) {
        self.center = center
        self.radius = radius
    }
}

/// `RS_ArcData` — center, radius, sweep, and orientation.
///
/// Angles are in radians. `reversed == true` means the arc sweeps clockwise from
/// `startAngle` to `endAngle` (LibreCAD's `reversed` flag).
public struct ArcData: Sendable, Hashable, Codable {
    public var center: Vector
    public var radius: Double
    public var startAngle: Double
    public var endAngle: Double
    public var reversed: Bool
    public init(center: Vector, radius: Double, startAngle: Double, endAngle: Double, reversed: Bool = false) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.reversed = reversed
    }
}

/// A polyline vertex: a point plus a `bulge` (tan(¼ of the included arc angle))
/// for the segment that *follows* it, matching DXF LWPOLYLINE bulge semantics.
/// Zero bulge == straight segment.
public struct PolylineVertex: Sendable, Hashable, Codable {
    public var point: Vector
    public var bulge: Double
    public init(point: Vector, bulge: Double = 0) {
        self.point = point
        self.bulge = bulge
    }
}

/// `RS_PolylineData` — an ordered vertex list, optionally closed.
public struct PolylineData: Sendable, Hashable, Codable {
    public var vertices: [PolylineVertex]
    public var closed: Bool
    public init(vertices: [PolylineVertex], closed: Bool = false) {
        self.vertices = vertices
        self.closed = closed
    }
}

/// `RS_EllipseData` — an ellipse or elliptic arc (ported from `rs_ellipse.h`).
///
/// Mirrors LibreCAD's `RS_EllipseData` field-for-field (the render-cache fields
/// `isArc`/`angleDegrees`/… are NOT stored here — they're derived on demand per
/// ADR-001). All angles are in radians.
///
/// - `center`:     ellipse center.
/// - `majorP`:     endpoint of the major axis **relative to the center**. Its
///                 magnitude is the major radius; its `.angle` is the rotation
///                 of the ellipse (`RS_Ellipse::getAngle()`).
/// - `ratio`:      minor/major radius ratio. The minor radius is
///                 `majorP.magnitude() * ratio`.
/// - `startAngle`: start *ellipse angle* (the parametric angle `a` fed to
///                 `ellipsePoint(a)`), `RS_EllipseData::angle1`.
/// - `endAngle`:   end ellipse angle, `RS_EllipseData::angle2`.
/// - `reversed`:   clockwise sweep flag (`RS_EllipseData::reversed`).
///
/// `startAngle == endAngle == 0` is the LibreCAD convention for a **whole**
/// ellipse (see `isArc`); any other pair makes it an elliptic arc.
public struct EllipseData: Sendable, Hashable, Codable {
    public var center: Vector
    /// Endpoint of the major axis, relative to the center.
    public var majorP: Vector
    /// Ratio of minor radius to major radius.
    public var ratio: Double
    /// Start ellipse angle (radians).
    public var startAngle: Double
    /// End ellipse angle (radians).
    public var endAngle: Double
    /// Clockwise sweep flag.
    public var reversed: Bool

    public init(
        center: Vector,
        majorP: Vector,
        ratio: Double,
        startAngle: Double = 0,
        endAngle: Double = 0,
        reversed: Bool = false
    ) {
        self.center = center
        self.majorP = majorP
        self.ratio = ratio
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.reversed = reversed
    }

    /// The major radius (`RS_Ellipse::getMajorRadius()` — `majorP.magnitude()`).
    public var majorRadius: Double { majorP.magnitude }

    /// The minor radius (`RS_Ellipse::getMinorRadius()`).
    public var minorRadius: Double { majorP.magnitude * ratio }

    /// The rotation angle of the major axis (`RS_Ellipse::getAngle()`).
    public var rotationAngle: Double { majorP.angle }

    /// Whether this is an elliptic **arc** (not a whole ellipse). Mirrors
    /// `RS_Ellipse::isEllipticArc()` / `calculateBorders`'s `isArc` test:
    /// `angle1`/`angle2` not both within the angular tolerance of 0.
    public var isArc: Bool {
        !(abs(startAngle) < Tolerance.angle && abs(endAngle) < Tolerance.angle)
    }

    /// The world point at *ellipse angle* `a` (parametric angle), ported from
    /// `RS_Ellipse::getEllipsePoint`: take the unit vector `(cos a, sin a)`,
    /// scale by `(majorRadius, minorRadius)`, rotate by the major-axis angle,
    /// then translate to the center.
    public func ellipsePoint(_ a: Double) -> Vector {
        let ra = majorRadius
        // unit vector at parametric angle, scaled to the ellipse axes
        let scaled = Vector(ra * cos(a), ra * ratio * sin(a))
        return center + scaled.rotated(by: rotationAngle)
    }
}

/// `RS_SplineData` — a (rational) B-spline / NURBS (ported from `rs_spline.h`).
///
/// Stores only the defining NURBS data (ADR-001); the tessellated polyline is
/// produced on demand by `resolve()`. The `controlPoints`/`knots`/`weights` are
/// the **evaluation-ready** vectors (already wrapped for a closed/periodic
/// spline, as LibreCAD stores them internally in `RS_SplineData`).
///
/// - `degree`:        spline degree (1–3 in LibreCAD).
/// - `controlPoints`: control polygon (wrapped if closed).
/// - `knots`:         non-decreasing knot vector. If empty, `resolve()`
///                    generates a clamped (open) uniform knot vector so the
///                    curve interpolates its endpoints (Piegl & Tiller).
/// - `weights`:       rational weights, one per control point. If empty, the
///                    spline is treated as non-rational (all weights == 1).
/// - `closed`:        periodic/closed flag (`SplineType::WrappedClosed`).
/// - `splineFlags`:   the RAW DXF code-70 bit flags as read from the file
///                    (1 closed, 2 periodic, 4 rational, 8 planar, 16 linear),
///                    or `0` when unknown (an engine-authored spline). Carried so
///                    the periodic / linear bits survive a DXF round-trip instead
///                    of being re-synthesized on write from `closed`/`weights`
///                    alone. NOT used by geometry resolve — purely a write-fidelity
///                    field (the DXF writer prefers it when non-zero).
public struct SplineData: Sendable, Hashable, Codable {
    public var degree: Int
    public var controlPoints: [Vector]
    public var knots: [Double]
    public var weights: [Double]
    public var closed: Bool
    /// Raw DXF code-70 flags from the source file; `0` ⇒ unknown (engine-authored).
    public var splineFlags: Int

    public init(
        degree: Int,
        controlPoints: [Vector],
        knots: [Double] = [],
        weights: [Double] = [],
        closed: Bool = false,
        splineFlags: Int = 0
    ) {
        self.degree = degree
        self.controlPoints = controlPoints
        self.knots = knots
        self.weights = weights
        self.closed = closed
        self.splineFlags = splineFlags
    }

    // Custom decoder so payloads written before `splineFlags` existed still load
    // (the field decodes to its `0` "unknown" default — the writer then falls back
    // to synthesizing the flags from `closed`/`weights`, the prior behavior).
    private enum CodingKeys: String, CodingKey {
        case degree, controlPoints, knots, weights, closed, splineFlags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        degree = try c.decode(Int.self, forKey: .degree)
        controlPoints = try c.decode([Vector].self, forKey: .controlPoints)
        knots = try c.decodeIfPresent([Double].self, forKey: .knots) ?? []
        weights = try c.decodeIfPresent([Double].self, forKey: .weights) ?? []
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        splineFlags = try c.decodeIfPresent(Int.self, forKey: .splineFlags) ?? 0
    }
}

// MARK: - Text / fill defining data (RS_TextData / RS_HatchData / RS_SolidData)

/// Horizontal text alignment, mirroring the full `RS_TextData::HAlign` /
/// `DRW_Text::HAlign` set (DXF group 72). The 15 AutoCAD justification modes are
/// the product of this (72) and `TextVAlign` (73), plus the three special H-only
/// modes (`.aligned`/`.middle`/`.fit`) that apply when V == baseline. ALL are
/// honored by the text resolve arm (text-system-design §2.4).
public enum TextHAlign: Int, Sendable, Hashable, Codable {
    case left = 0
    case center = 1
    case right = 2
    /// Fit between insertion (10) and second point (11); height auto-scales.
    case aligned = 3
    /// Centered H+V on the midpoint (the "TL…BR" Middle, distinct from center).
    case middle = 4
    /// Fit between two points keeping height, varying the width factor.
    case fit = 5
}

/// Vertical text alignment, mirroring the essential `RS_TextData::VAlign`
/// cases (DXF group 73). Carried for round-trip; only `.baseline` is honored by
/// the current layout (rest is backlog).
public enum TextVAlign: Int, Sendable, Hashable, Codable {
    case baseline = 0
    case bottom = 1
    case middle = 2
    case top = 3
}

/// `RS_TextData` — single-line CAD text drawn as **stroked polylines** from a
/// `.lff` stroke font (ADR-004), NOT a glyph atlas. Mirrors the defining fields
/// of LibreCAD's `RS_TextData`; render-cache fields (the laid-out child entity
/// graph) are NOT stored here — the strokes are produced on demand by
/// `resolve()` via `ResolveContext.fontProvider`.
///
/// - `position`:  insertion point (the lower-left of the first glyph for the
///                default `.left`/`.baseline` alignment).
/// - `height`:    nominal cap height in world units; the font's em coords are
///                scaled by `height / capHeight` (LibreCAD ISO fonts use a
///                ~9-unit cap height — see `StrokeFont` em space).
/// - `rotation`:  baseline rotation in radians (CCW), applied about `position`.
/// - `text`:      the string to render.
/// - `styleName`: the text-style/font base name (e.g. `"standard"`) handed to
///                `ctx.fontProvider`; `nil` falls back to the provider's default
///                font (the provider keys an empty/`nil` lookup to its default).
/// - `hAlign`/`vAlign`: alignment (carried for round-trip; only the default is
///                honored by the current layout — see the `text` resolve arm).
/// - `letterSpacingFactor`: multiplier on the font's `letterSpacing`; `1.0`
///                uses the font's declared spacing (LibreCAD default).
public struct TextData: Sendable, Hashable, Codable {
    public var position: Vector
    /// DXF group 11 — the second alignment point, required for `.aligned`/`.fit`
    /// (the run is fit between `position` and `secondPoint`); `nil` otherwise. [NEW]
    public var secondPoint: Vector?
    public var height: Double
    public var rotation: Double
    public var text: String
    public var styleName: String?
    public var hAlign: TextHAlign
    public var vAlign: TextVAlign
    /// DXF group 41 — per-entity horizontal scale, overriding the style's width
    /// factor (AutoCAD precedence: entity 41 over STYLE 41). Default `1`.       [NEW]
    public var widthFactor: Double
    /// DXF group 51 — per-entity slant (radians), overriding the style's oblique
    /// angle. Default `0`.                                                       [NEW]
    public var obliqueAngle: Double
    /// DXF group 71 — backward (X-mirror) / upside-down (Y-mirror) flags. Carried
    /// for round-trip.                                                           [NEW]
    public var generation: TextGenerationFlags
    public var letterSpacingFactor: Double

    public init(
        position: Vector,
        height: Double,
        rotation: Double = 0,
        text: String,
        styleName: String? = nil,
        hAlign: TextHAlign = .left,
        vAlign: TextVAlign = .baseline,
        secondPoint: Vector? = nil,
        widthFactor: Double = 1.0,
        obliqueAngle: Double = 0,
        generation: TextGenerationFlags = [],
        letterSpacingFactor: Double = 1.0
    ) {
        self.position = position
        self.secondPoint = secondPoint
        self.height = height
        self.rotation = rotation
        self.text = text
        self.styleName = styleName
        self.hAlign = hAlign
        self.vAlign = vAlign
        self.widthFactor = widthFactor
        self.obliqueAngle = obliqueAngle
        self.generation = generation
        self.letterSpacingFactor = letterSpacingFactor
    }
}

/// `RS_HatchData` — a filled region defined by boundary loops. Mirrors the
/// defining fields of LibreCAD's `RS_HatchData`; the resolved fill geometry is
/// produced on demand by `resolve()` (ADR-001), not stored.
///
/// - `loops`:       boundary loops, each an ordered ring of `PolylineVertex`
///                  (so DXF bulged boundary edges round-trip). By the
///                  `ResolvedFill` loop contract `loops[0]` is the outer
///                  boundary and `loops[1...]` are holes/islands. A vertex's
///                  `bulge` is carried but treated as straight by the current
///                  resolve (boundary-arc tessellation is backlog).
/// - `solidFill`:   `true` for a solid fill (the only mode rendered now). A
///                  `false` value means a *pattern* fill — pattern lines are
///                  backlog, so a pattern hatch still resolves to a solid fill of
///                  its boundary for visibility.
/// - `patternName`: the hatch pattern name (e.g. `"ANSI31"`), carried for
///                  round-trip; `nil`/`"SOLID"` is a solid fill.
/// - `patternScale`: the pattern scale (DXF code 41) — multiplies the `.pat`
///                  line spacing/dash lengths when pattern lines are generated.
///                  `1` is the un-scaled definition. Ignored for a solid fill.
/// - `patternAngle`: an EXTRA rotation (radians, DXF code 52) applied to the
///                  whole pattern, on top of each `.pat` line's own angle.
///                  Ignored for a solid fill.
/// - `gradient`:    an optional GRADIENT fill descriptor (`HatchGradient`). When
///                  non-`nil` the hatch is filled with a color ramp instead of a
///                  flat solid/pattern; `nil` (the default — and what every older
///                  hatch decodes to) keeps the prior solid/pattern behavior. The
///                  field is additive and render/DXF/inspector support land in
///                  later waves; this wave only carries it through the model,
///                  resolve, and transform.
public struct HatchData: Sendable, Hashable, Codable {
    public var loops: [[PolylineVertex]]
    public var solidFill: Bool
    public var patternName: String?
    /// Pattern scale (DXF code 41); `1` == the `.pat` definition's native scale.
    /// Additive — a hatch born without it (older data) decodes to `1`.
    public var patternScale: Double
    /// Extra pattern rotation in radians (DXF code 52), added to each pattern
    /// line's own angle. Additive — older data decodes to `0`.
    public var patternAngle: Double
    /// An optional GRADIENT fill (DXF gradient hatch). `nil` (the default, and what
    /// older data decodes to) means a flat solid/pattern fill — the prior behavior.
    public var gradient: HatchGradient?

    public init(loops: [[PolylineVertex]], solidFill: Bool = true, patternName: String? = nil,
                patternScale: Double = 1, patternAngle: Double = 0,
                gradient: HatchGradient? = nil) {
        self.loops = loops
        self.solidFill = solidFill
        self.patternName = patternName
        self.patternScale = patternScale
        self.patternAngle = patternAngle
        self.gradient = gradient
    }
}

/// A GRADIENT hatch fill — a color ramp the renderer paints across the hatch's
/// boundary (DXF gradient hatch: codes 450–453 / 460–463 / 470). Mirrors the
/// defining gradient fields; the render-ready form is produced by `resolve()`
/// (ADR-001), not stored.
///
/// - `kind`:   `.linear` (a directional ramp) or `.radial` (a centered ramp),
///             matching the DXF gradient types.
/// - `colors`: the gradient stops. **1** color is a single-color gradient (the
///             DXF "one-color" gradient — the renderer ramps it toward white/a
///             tint); **2** colors is the standard two-color gradient. More than
///             two are tolerated/carried but only the first two are meaningful to
///             the current model. Stored as concrete `RGBAColor` (gradient stops
///             are explicit colors in DXF, not ByLayer/ByBlock sentinels).
/// - `angle`: the gradient rotation in RADIANS (DXF code 460 is radians) — the
///            direction of a `.linear` ramp / the orientation hint of a `.radial`
///            one. Transform-rotated like `HatchData.patternAngle`.
public struct HatchGradient: Equatable, Codable, Sendable, Hashable {
    /// The gradient geometry: a directional (`linear`) or centered (`radial`) ramp.
    public enum Kind: String, Codable, Sendable, Hashable {
        case linear
        case radial
    }

    public var kind: Kind
    /// 1 or 2 (or more, tolerated) gradient stops. A single stop is the DXF
    /// one-color gradient; two stops is the standard two-color gradient.
    public var colors: [RGBAColor]
    /// Gradient rotation in radians (DXF code 460 is radians).
    public var angle: Double

    public init(kind: Kind, colors: [RGBAColor], angle: Double = 0) {
        self.kind = kind
        self.colors = colors
        self.angle = angle
    }
}

// MARK: - Decodable (back-compat: tolerate missing pattern scale/angle/gradient)

extension HatchData {
    private enum CodingKeys: String, CodingKey {
        case loops, solidFill, patternName, patternScale, patternAngle, gradient
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        loops = try c.decode([[PolylineVertex]].self, forKey: .loops)
        solidFill = try c.decodeIfPresent(Bool.self, forKey: .solidFill) ?? true
        patternName = try c.decodeIfPresent(String.self, forKey: .patternName)
        // A non-positive (or absent) scale collapses the pattern; clamp to the
        // native `1` so older data and degenerate scales still render.
        let s = try c.decodeIfPresent(Double.self, forKey: .patternScale) ?? 1
        patternScale = (s.isFinite && s > 0) ? s : 1
        patternAngle = try c.decodeIfPresent(Double.self, forKey: .patternAngle) ?? 0
        // Additive: older data has no `gradient` ⇒ `nil` (a flat fill).
        gradient = try c.decodeIfPresent(HatchGradient.self, forKey: .gradient)
    }
}

/// `RS_SolidData` — a filled triangle or quadrilateral (DXF `SOLID`/`TRACE`).
/// Mirrors LibreCAD's `RS_SolidData` corner array.
///
/// - `corners`: 3 or 4 world-coord corners. NOTE: the DXF `SOLID` quad orders
///              its 3rd/4th vertices "bow-tie" (3 and 4 are swapped relative to
///              a CCW ring); the reader-import wave normalizes that when it maps
///              DXF → `SolidData`, so the corners stored here are already in ring
///              order. The resolve arm emits them as a single fill loop as-is.
public struct SolidData: Sendable, Hashable, Codable {
    public var corners: [Vector]

    public init(corners: [Vector]) {
        self.corners = corners
    }
}

/// `LC_SplinePointsData` — an interpolation spline drawn as a chain of
/// **quadratic Bézier** segments (ported from `lc_splinepoints.h`).
///
/// LibreCAD's `LC_SplinePoints` keeps both the on-curve `splinePoints` (fit
/// data) and the derived quadratic-Bézier `controlPoints`. The render path
/// (`fillStrokePoints` → `GetQuadPoints` → `StrokeQuad`) draws entirely from
/// `controlPoints`, so that is what we store and tessellate. The fit-point →
/// control-point banded solve (`UpdateControlPoints`) is an editing-time
/// concern not needed for `resolve()`/`boundingBox()` and is not ported here.
///
/// - `controlPoints`: the quadratic-Bézier control polygon.
/// - `closed`:        whether the spline wraps (`LC_SplinePointsData::closed`).
public struct SplinePointsData: Sendable, Hashable, Codable {
    public var controlPoints: [Vector]
    public var closed: Bool

    public init(controlPoints: [Vector], closed: Bool = false) {
        self.controlPoints = controlPoints
        self.closed = closed
    }
}

// MARK: - Construction-line defining data (RS_Construction* / DXF XLINE & RAY)

/// `RS_ConstructionLineData` (infinite form) — an **infinite construction line**
/// (DXF `XLINE`, libdxfrw `DRW_Xline`). Defined by a `base` point and a
/// `direction` vector; the line extends to infinity in **both** directions along
/// `direction`. Per ADR-001 a value type holding only the defining data; the
/// drawn segment (a finite segment clipped to the view, or a large fallback
/// segment) is produced on demand by `resolve()` — never stored.
///
/// ## Field grounding (DXF `XLINE` / libdxfrw `DRW_Xline`)
/// - `base`      — DXF code 10: the first point the line passes through
///                 (`DRW_Xline::basePoint`).
/// - `direction` — DXF code 11: the unit direction vector
///                 (`DRW_Xline::secPoint`, stored as a direction). Need not be
///                 normalized; `resolve()` normalizes it.
public struct XLineData: Sendable, Hashable, Codable {
    /// DXF code 10 — a point the infinite line passes through.
    public var base: Vector
    /// DXF code 11 — the line's direction (both ways). Need not be normalized.
    public var direction: Vector
    public init(base: Vector, direction: Vector) {
        self.base = base
        self.direction = direction
    }
}

/// `RS_ConstructionLineData` (semi-infinite form) — a **ray** (DXF `RAY`,
/// libdxfrw `DRW_Ray`). Defined by a `base` point and a `direction`; the ray
/// extends from `base` to infinity in the **`+direction`** sense only. Per
/// ADR-001 a value type holding only the defining data; the drawn segment is
/// produced on demand by `resolve()` — never stored.
///
/// ## Field grounding (DXF `RAY` / libdxfrw `DRW_Ray`)
/// - `base`      — DXF code 10: the ray's start point (`DRW_Ray::basePoint`).
/// - `direction` — DXF code 11: the direction the ray travels
///                 (`DRW_Ray::secPoint`, stored as a direction). Need not be
///                 normalized; `resolve()` normalizes it.
public struct RayData: Sendable, Hashable, Codable {
    /// DXF code 10 — the ray's start point.
    public var base: Vector
    /// DXF code 11 — the direction the ray travels (one way only). Need not be
    /// normalized.
    public var direction: Vector
    public init(base: Vector, direction: Vector) {
        self.base = base
        self.direction = direction
    }
}

// MARK: - Dimension defining data (RS_Dimension* / DRW_Dimension family)

/// An associative CAD dimension (`RS_Dimension` family / DXF `DIMENSION`).
///
/// Per ADR-001 a dimension is a **value struct holding only its defining data**;
/// the drawn graphic (extension lines, the dimension line, arrowheads, and the
/// measurement text) is NOT stored — it is produced on demand by `resolve()` and
/// the measurement value is recomputed from the geometry, so a dimension
/// **re-measures on edit** and **round-trips to DXF faithfully** (a DIMENSION
/// stays a DIMENSION). The renderer needs ZERO changes: `resolve()` emits
/// `ResolvedPolyline`s (lines + measurement-text strokes) and `ResolvedFill`s
/// (arrowhead triangles), exactly the contract the renderer already consumes.
///
/// ## Field grounding (DXF `DIMENSION` / libdxfrw `DRW_Dimension` family)
/// The fields below mirror the DXF dimension model so import/export map cleanly
/// (the DXF *read* import + *write* of dimensions are later waves):
/// - `definitionPoint`  — DXF code 10 (the **dimension-line location**; for a
///   radial/diametric dim, the point the leader passes through; for angular, the
///   point the dimension arc passes through). `DRW_Dimension::getDefPoint`.
/// - `textOverride`     — DXF code 1: the user-entered text that **replaces** the
///   computed measurement. `nil`/empty ⇒ use the measured value; `" "` (a single
///   space, DXF convention) ⇒ suppress the text. `DRW_Dimension::getText`.
/// - `textMiddle`       — DXF code 11: optional override for the text's middle
///   point. `nil` ⇒ the resolve computes a default text position centered on the
///   dimension line. `DRW_Dimension::getTextPoint`.
/// - `styleName`        — DXF code 3: the dimension style name (carried for
///   round-trip; not yet resolved against a style table — that is the reserved
///   `dimStyleProvider` hook on `ResolveContext`). `DRW_Dimension::getStyle`.
/// - `textHeight`       — measurement-text cap height in world units (from the
///   dim style's text height; defaulted here until a style table lands).
/// - `arrowSize`        — arrowhead length in world units (dim style arrow size).
/// - `textRotation`     — DXF code 53: an explicit rotation (radians) for the
///   measurement text, independent of the dimension-line angle. `nil` ⇒ the
///   resolve derives the upright baseline angle from the geometry.
/// - `attachmentPoint`  — DXF code 71: the text attachment / justification
///   (`DRW_MText::Attach` semantics, reused). Carried for round-trip; the
///   dimension tools + DXF write consume it.
/// - `lineSpacingStyle` — DXF code 72/73: at-least vs exact line spacing for
///   multi-line measurement text (round-trip; tolerance text uses it).
/// - `lineSpacingFactor`— DXF code 41: a multiplier on the default line spacing
///   for multi-line measurement text.
/// - `obliqueAngle`     — DXF code 52: an extension-line oblique (slant) angle in
///   radians for linear/aligned dimensions (oblique-dimension support). Carried
///   for round-trip; the tools + write consume it.
///
/// (The measurement value — DXF code 42 — is **recomputed** from the geometry in
/// `resolve()` and is deliberately NOT stored, so a dimension re-measures on edit.)
///
/// The per-variant defining points live in `DimKind`.
public struct DimData: Sendable, Hashable, Codable {
    /// The variant + its defining points (linear / aligned / radial / diameter /
    /// angular).
    public var kind: DimKind
    /// DXF code 10 — the dimension-line location (its meaning is per-variant; see
    /// `DimKind`). Drives where the dimension line / leader / arc is drawn.
    public var definitionPoint: Vector
    /// DXF code 1 — explicit text that REPLACES the computed measurement. `nil`
    /// or empty ⇒ show the measured value; a single space suppresses the text.
    public var textOverride: String?
    /// DXF code 11 — optional override for the text middle point. `nil`
    /// (the default) ⇒ resolve centers the text on the dimension line.
    public var textMiddle: Vector?
    /// DXF code 3 — the dimension style name (round-trip; style resolution TBD).
    public var styleName: String?
    /// Measurement-text cap height in world units.
    public var textHeight: Double
    /// Arrowhead length in world units.
    public var arrowSize: Double
    /// DXF code 53 — explicit measurement-text rotation (radians). `nil` ⇒ the
    /// resolve derives the upright baseline angle from the dimension geometry.
    public var textRotation: Double?
    /// DXF code 71 — text attachment / justification (`DRW_MText::Attach`).
    /// Carried for round-trip + consumed by the dimension tools / DXF write.
    public var attachmentPoint: MTextAttachment
    /// DXF code 72/73 — line-spacing style for multi-line measurement text.
    public var lineSpacingStyle: MTextLineSpacingStyle
    /// DXF code 41 — line-spacing factor (multiplier on default line spacing).
    public var lineSpacingFactor: Double
    /// DXF code 52 — extension-line oblique (slant) angle, radians, for
    /// linear/aligned dimensions. `0` ⇒ extension lines are perpendicular.
    public var obliqueAngle: Double

    public init(
        kind: DimKind,
        definitionPoint: Vector,
        textOverride: String? = nil,
        textMiddle: Vector? = nil,
        styleName: String? = nil,
        textHeight: Double = 2.5,
        arrowSize: Double = 2.5,
        textRotation: Double? = nil,
        attachmentPoint: MTextAttachment = .middleCenter,
        lineSpacingStyle: MTextLineSpacingStyle = .atLeast,
        lineSpacingFactor: Double = 1.0,
        obliqueAngle: Double = 0.0
    ) {
        self.kind = kind
        self.definitionPoint = definitionPoint
        self.textOverride = textOverride
        self.textMiddle = textMiddle
        self.styleName = styleName
        self.textHeight = textHeight
        self.arrowSize = arrowSize
        self.textRotation = textRotation
        self.attachmentPoint = attachmentPoint
        self.lineSpacingStyle = lineSpacingStyle
        self.lineSpacingFactor = lineSpacingFactor
        self.obliqueAngle = obliqueAngle
    }
}

/// The four dimension variants the user wants, each carrying its defining points.
/// Points use the DXF DIMENSION sub-type conventions so import/export are direct.
public enum DimKind: Sendable, Hashable, Codable {
    /// A **linear** dimension: the distance between two extension-line origin
    /// points measured along a fixed direction `angle` (radians; 0 = horizontal,
    /// π/2 = vertical — DXF code 50 of `DRW_DimLinear`). The two points are
    /// `RS_DimLinearData::extensionPoint1/2` (DXF def1/def2, codes 13/14).
    case linear(extension1: Vector, extension2: Vector, angle: Double)

    /// An **aligned** dimension: the distance between two extension-line origin
    /// points measured **parallel to the line** through them (`RS_DimAligned`,
    /// DXF `DIMALIGNED`). The dimension line is offset to pass through
    /// `DimData.definitionPoint`.
    case aligned(extension1: Vector, extension2: Vector)

    /// A **radial** dimension: the radius from `center` to `pointOnCircle`
    /// (`RS_DimRadial`, DXF `DIMRADIUS`). The measured value is the radius; the
    /// drawn leader runs from the circle toward the center.
    case radial(center: Vector, pointOnCircle: Vector)

    /// A **diameter** dimension: the diameter across a circle through the two
    /// opposite points `point1`/`point2` (`RS_DimDiametric`, DXF `DIMDIAMETER`).
    /// The measured value is the diameter (the distance between the two points).
    case diameter(point1: Vector, point2: Vector)

    /// An **angular** dimension: the angle between the two lines
    /// (`line1Start`→`line1End`) and (`line2Start`→`line2End`), with the
    /// dimension arc passing through `DimData.definitionPoint`
    /// (`RS_DimAngular`, DXF `DIMANGULAR`). The measured value is the angle (in
    /// degrees) subtended at the lines' intersection.
    case angular(line1Start: Vector, line1End: Vector,
                 line2Start: Vector, line2End: Vector)

    /// An **ordinate** dimension: the X- or Y-distance from a datum `origin` to a
    /// `feature` point, shown as a leader running from the feature to `leaderEnd`
    /// (where the value text sits) (`LC_DimOrdinate`, DXF `DIMORDINATE`, type-70
    /// low nibble 6). `measuringX == true` is an **X-datum** ordinate (measures the
    /// horizontal distance, the X coordinate relative to the origin; DXF code 70
    /// bit 0x40 set); `false` is a **Y-datum** ordinate (vertical distance). The
    /// measured value is `|feature.x − origin.x|` (X) or `|feature.y − origin.y|`
    /// (Y). `DimData.definitionPoint` is the datum origin (code 10).
    case ordinate(origin: Vector, feature: Vector, leaderEnd: Vector, measuringX: Bool)

    /// An **arc-length** dimension: the length of a circular arc measured *along*
    /// the arc (`LC_DimArc`, AutoCAD ARC_DIMENSION). The feature arc is
    /// `center`/`radius` swept from `startAngle` to `endAngle` (radians; `reversed`
    /// == clockwise sweep, matching `ArcData`). The dimension arc is drawn
    /// concentric at the radius of `DimData.definitionPoint`, with an arc-length
    /// symbol (⌒) prefixed to the value. The measured value is `radius · |sweep|`.
    case arcLength(center: Vector, radius: Double,
                   startAngle: Double, endAngle: Double, reversed: Bool)

    /// A **3-point angular** dimension: the angle at `vertex` between the rays
    /// `vertex`→`point1` and `vertex`→`point2` (`RS_DimAngular` 3-point form, DXF
    /// `DIMANGULAR3P`, type-70 low nibble 5). The dimension arc passes through
    /// `DimData.definitionPoint` (which also SELECTS which of the two sectors is
    /// measured, like the 2-line angular dim). The measured value is the angle (in
    /// degrees) subtended at `vertex`.
    case angular3p(vertex: Vector, point1: Vector, point2: Vector)
}

// MARK: - Leader defining data (RS_Leader / DRW_Leader, DXF LEADER)

/// `RS_LeaderData` — a **leader** (DXF `LEADER`, libdxfrw `DRW_Leader`): an
/// annotation callout made of a polyline path (`vertices`), an optional
/// arrowhead at the FIRST vertex, and an optional attached annotation (text /
/// mtext) anchored at the LAST vertex. Per ADR-001 a value type holding only the
/// defining data; the drawn graphic — the path segments, the arrowhead fill, and
/// the annotation strokes/fills — is produced on demand by `resolve()` (the
/// arrowhead reuses the shared dimension-arrowhead helper; the annotation reuses
/// the shared `.text` / `ResolveContext.fontProvider` text path — no second text
/// code path), never stored.
///
/// ## Field grounding (DXF `LEADER` / libdxfrw `DRW_Leader`)
/// - `vertices`   — DXF codes 10/20/30 (`DRW_Leader::vertexlist`): the ordered
///                  path points. The arrowhead sits at `vertices.first`; the
///                  annotation anchors at `vertices.last`. A leader may carry NO
///                  vertices (a degenerate callout that round-trips but draws
///                  nothing) — matching the two zero-vertex LEADERs in
///                  `dim_sample.dxf`.
/// - `hasArrow`   — DXF code 71 (`DRW_Leader::arrow`, 1 == enabled): whether an
///                  arrowhead is drawn at the first vertex.
/// - `arrowSize`  — the arrowhead length in world units (the dim style's arrow
///                  size / `$DIMASZ`; carried so the leader re-measures
///                  independently of any document style). `<= 0` ⇒ the resolve
///                  falls back to the document/engine default arrow size.
/// - `annotation` — the OPTIONAL attached annotation as a `.text`/`.mtext`
///                  `EntityKind` (DXF: a separate entity hard-referenced by the
///                  leader's code 340; we model it inline so the callout is one
///                  value). `nil` ⇒ a bare leader (path + arrow only). Stored as
///                  an `EntityKind` so the annotation resolves through the SAME
///                  `.text`/`.mtext` resolve arm (no second text path).
/// - `styleName`  — DXF code 3 (`DRW_Leader::style`): the dimension-style name
///                  the leader references; carried for round-trip.
public struct LeaderData: Sendable, Hashable, Codable {
    /// DXF codes 10/20/30 — the ordered path vertices (arrow at the first,
    /// annotation at the last). May be empty (a degenerate, drawn-nothing leader).
    public var vertices: [Vector]
    /// DXF code 71 — whether an arrowhead is drawn at the first vertex.
    public var hasArrow: Bool
    /// The arrowhead length in world units. `<= 0` ⇒ resolve uses the document /
    /// engine default arrow size.
    public var arrowSize: Double
    /// The OPTIONAL attached annotation (`.text` or `.mtext`) anchored at the last
    /// vertex; `nil` for a bare leader. Resolves through the shared text path.
    public var annotation: EntityKind?
    /// DXF code 3 — the referenced dimension-style name (round-trip only).
    public var styleName: String?

    public init(
        vertices: [Vector],
        hasArrow: Bool = true,
        arrowSize: Double = 2.5,
        annotation: EntityKind? = nil,
        styleName: String? = nil
    ) {
        self.vertices = vertices
        self.hasArrow = hasArrow
        self.arrowSize = arrowSize
        self.annotation = annotation
        self.styleName = styleName
    }
}

// MARK: - MultiLeader defining data (DRW_MText/MLEADER, DXF MULTILEADER)

/// `MultiLeaderData` — a **multileader** (DXF `MULTILEADER`/`MLEADER`, AutoCAD's
/// modern annotation callout that superseded the legacy `LEADER`). Like a
/// `LeaderData` it is one leg `vertices` path with an optional arrowhead at the
/// FIRST vertex and an optional attached `.text`/`.mtext` annotation at the LAST
/// vertex — but a multileader adds a **landing** (a short horizontal "dogleg" tail
/// run between the last leg vertex and the annotation) which `resolve()` draws when
/// `doglegEnabled`. Per ADR-001 a value type holding only the defining data; the
/// drawn graphic (leg polyline, arrowhead via the shared `dimArrowhead`, the
/// landing segment, and the annotation via the shared `.text`/`.mtext` resolve arm
/// — no second text path) is produced on demand by `resolve()`, never stored.
///
/// ## v1 scope
/// A **single-root** multileader: ONE leg (one `vertices` path) + landing/dogleg +
/// arrowhead + an MTEXT/TEXT annotation. DXF MLEADER block content (a block as the
/// annotation instead of text) and **multi-root** multileaders (several legs
/// fanning into one shared landing) are DEFERRED to a later wave; this struct
/// mirrors `LeaderData` so those extensions stay additive.
///
/// ## Field grounding (DXF `MULTILEADER` / cloned from `LeaderData`)
/// - `vertices`   — the ordered leg path points (arrow at `vertices.first`, the
///                  landing/annotation anchor at `vertices.last`). May be empty (a
///                  degenerate callout that round-trips but draws nothing).
/// - `hasArrow`   — whether an arrowhead is drawn at the first vertex.
/// - `arrowSize`  — the arrowhead length in world units; `<= 0` ⇒ resolve uses the
///                  document / engine default arrow size.
/// - `annotation` — the OPTIONAL attached annotation (`.text`/`.mtext`) anchored at
///                  the landing end; `nil` for a bare multileader. Resolves through
///                  the SAME shared text path (no second text code path).
/// - `styleName`  — the referenced MLEADER/dimension-style name (round-trip only).
/// - `landingDistance` — the length (world units) of the straight horizontal landing
///                  ("dogleg" tail) drawn from the last leg vertex toward the
///                  annotation when `doglegEnabled`. (DXF `MULTILEADER` "dogleg
///                  length".)
/// - `doglegEnabled` — whether the landing segment is drawn at all. When `false` the
///                  multileader's leg runs straight to the annotation with no tail.
public struct MultiLeaderData: Sendable, Hashable, Codable {
    /// The ordered leg path vertices (arrow at the first, landing/annotation at the
    /// last). May be empty (a degenerate, drawn-nothing multileader).
    public var vertices: [Vector]
    /// Whether an arrowhead is drawn at the first vertex.
    public var hasArrow: Bool
    /// The arrowhead length in world units. `<= 0` ⇒ resolve uses the document /
    /// engine default arrow size.
    public var arrowSize: Double
    /// The OPTIONAL attached annotation (`.text` or `.mtext`) anchored at the landing
    /// end; `nil` for a bare multileader. Resolves through the shared text path.
    public var annotation: EntityKind?
    /// The referenced MLEADER / dimension-style name (round-trip only).
    public var styleName: String?
    /// The straight landing ("dogleg") tail length in world units, drawn from the
    /// last leg vertex toward the annotation when `doglegEnabled`.
    public var landingDistance: Double
    /// Whether the landing/dogleg tail segment is drawn.
    public var doglegEnabled: Bool

    public init(
        vertices: [Vector],
        hasArrow: Bool = true,
        arrowSize: Double = 2.5,
        annotation: EntityKind? = nil,
        styleName: String? = nil,
        landingDistance: Double = 2.0,
        doglegEnabled: Bool = true
    ) {
        self.vertices = vertices
        self.hasArrow = hasArrow
        self.arrowSize = arrowSize
        self.annotation = annotation
        self.styleName = styleName
        self.landingDistance = landingDistance
        self.doglegEnabled = doglegEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case vertices, hasArrow, arrowSize, annotation, styleName
        case landingDistance, doglegEnabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vertices = try c.decodeIfPresent([Vector].self, forKey: .vertices) ?? []
        hasArrow = try c.decodeIfPresent(Bool.self, forKey: .hasArrow) ?? true
        arrowSize = try c.decodeIfPresent(Double.self, forKey: .arrowSize) ?? 2.5
        annotation = try c.decodeIfPresent(EntityKind.self, forKey: .annotation)
        styleName = try c.decodeIfPresent(String.self, forKey: .styleName)
        // ADDITIVE back-compat: a value born without the landing fields (or partial
        // JSON, e.g. a multileader serialized before these two were added) decodes
        // to the defaults so old documents keep round-tripping.
        landingDistance = try c.decodeIfPresent(Double.self, forKey: .landingDistance) ?? 2.0
        doglegEnabled = try c.decodeIfPresent(Bool.self, forKey: .doglegEnabled) ?? true
    }
}

// MARK: - Block attribute value (ATTRIB) — per-insert text field

/// One **block attribute value** attached to a block reference (DXF `ATTRIB`,
/// libdxfrw `DRW_Attrib`). A block attribute is the parametric text field that
/// makes a block (e.g. a title-block symbol) reusable: the block definition
/// declares attribute *templates* (`BlockAttributeDef`, DXF `ATTDEF`) and each
/// placed `INSERT` overrides their *values* with one `ATTRIB` per tag.
///
/// Per ADR-001 this is a pure value type holding only the defining data; the drawn
/// text is produced on demand by `resolve()` through the SAME `.text` resolve arm
/// every other text entity uses (no second text path). An ATTRIB derives from
/// `TEXT` in DXF, so the fields mirror the `TextData` subset that round-trips.
///
/// ## Field grounding (DXF `ATTRIB` / libdxfrw `DRW_Attrib`, derives `DRW_Text`)
/// - `tag`      — DXF code 2: the attribute's tag (the field name, e.g. `"PARTNO"`).
/// - `text`     — DXF code 1: the attribute's VALUE (the displayed string).
/// - `position` — DXF code 10: the text insertion point, in the INSERT's LOCAL
///                frame (relative to the block base), exactly like a block member;
///                `resolve()` transforms it by the insert placement.
/// - `height`   — DXF code 40: the text cap height (world units, local frame).
/// - `rotation` — DXF code 50: baseline rotation in **radians** (CCW), local frame.
public struct BlockAttributeValue: Sendable, Hashable, Codable {
    /// DXF code 2 — the attribute tag (field name).
    public var tag: String
    /// DXF code 1 — the attribute value (the displayed text).
    public var text: String
    /// DXF code 10 — text insertion point in the insert's local frame.
    public var position: Vector
    /// DXF code 40 — text cap height (world units).
    public var height: Double
    /// DXF code 50 — baseline rotation in radians (CCW).
    public var rotation: Double
    /// DXF code 70 — per-instance attribute flags (1 invisible, 2 constant, 4
    /// verify, 8 preset). Carried for round-trip; an ATTRIB normally inherits its
    /// visibility from the block's `BlockAttributeDef`, but a per-instance override
    /// (e.g. an individually-hidden value) survives here. Defaults to `0`.
    public var flags: Int

    public init(
        tag: String,
        text: String,
        position: Vector = Vector(0, 0),
        height: Double = 2.5,
        rotation: Double = 0,
        flags: Int = 0
    ) {
        self.tag = tag
        self.text = text
        self.position = position
        self.height = height
        self.rotation = rotation
        self.flags = flags
    }

    private enum CodingKeys: String, CodingKey {
        case tag, text, position, height, rotation, flags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try c.decodeIfPresent(Vector.self, forKey: .position) ?? Vector(0, 0)
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 2.5
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        // ADDITIVE: a value born without `flags` (or partial JSON) decodes to 0.
        flags = try c.decodeIfPresent(Int.self, forKey: .flags) ?? 0
    }
}

// MARK: - Block reference (Insert) defining data (RS_InsertData / DRW_Insert)

/// `RS_InsertData` — a **block reference**: a placement of a named block. Mirrors
/// LibreCAD's `RS_InsertData` / DXF `INSERT`. Per ADR-001 a value type holding
/// only the defining data; the placed copies of the block's member entities are
/// produced on demand by `resolve()` via `ResolveContext.blockProvider` (the same
/// provider pattern as `fontProvider`/`dimStyleProvider`), never stored.
///
/// ## Field grounding (DXF `INSERT` / libdxfrw `DRW_Insert`)
/// - `blockName`      — DXF code 2: the referenced block's name (`RS_InsertData::name`).
/// - `insertionPoint` — DXF code 10: where the block's base point lands in world
///                      coords (`RS_InsertData::insertionPoint`).
/// - `scale`          — DXF codes 41/42(/43): per-axis scale factors
///                      (`RS_InsertData::scaleFactor`). `(1,1)` is no scaling; a
///                      negative factor mirrors that axis.
/// - `rotation`       — DXF code 50: rotation in **radians**, CCW about the
///                      insertion point (`RS_InsertData::angle`).
///
/// ## MINSERT (rectangular array) — DXF codes 70/71/44/45
/// An INSERT can repeat the block over a `rows × cols` grid (LibreCAD's
/// `RS_InsertData::rows`/`cols`/`spacing`). The defaults (1×1, zero spacing) make
/// a plain single insert. `resolve()` stamps the block at each grid cell
/// `(r, c)` offset by `(c·colSpacing, r·rowSpacing)` in the insert's LOCAL frame
/// (before rotation), matching AutoCAD MINSERT semantics.
public struct InsertData: Sendable, Hashable, Codable {
    /// DXF code 2 — the referenced block's name.
    public var blockName: String
    /// DXF code 10 — the placement point (where the block base point lands).
    public var insertionPoint: Vector
    /// DXF codes 41/42/43 — per-axis scale (`z` carried for round-trip; the
    /// engine is 2D so the resolve uses `x`/`y`). `(1,1)` == no scaling.
    public var scale: Vector
    /// DXF code 50 — rotation in radians (CCW about the insertion point).
    public var rotation: Double
    /// DXF code 71 — MINSERT row count (>= 1; 1 == no array in this axis).
    public var rows: Int
    /// DXF code 70 — MINSERT column count (>= 1; 1 == no array in this axis).
    public var cols: Int
    /// DXF code 44 — MINSERT column spacing (local-frame X step between columns).
    public var colSpacing: Double
    /// DXF code 45 — MINSERT row spacing (local-frame Y step between rows).
    public var rowSpacing: Double
    /// The block **attribute values** (DXF `ATTRIB` sub-entities, code 66 == 1)
    /// attached to this insert — one per attribute tag the referenced block
    /// declares (`Block.attributeDefs`). Each is rendered by `resolve()` as TEXT
    /// at the insert's placement (once per MINSERT cell). ADDITIVE field: a record
    /// born without it — and every old saved file — decodes to `[]`, so a plain
    /// insert is 100% unaffected.
    public var attributes: [BlockAttributeValue]
    /// Per-INSTANCE dynamic state (active visibility state, parameter values, flip
    /// states — see `InsertDynamicState`). ADDITIVE optional field: a plain insert —
    /// and every old saved file — carries `nil`, so a record born without it is
    /// byte-identical (dynamic-blocks-plan §2b). Evaluated inside the existing
    /// `resolveInsert` via `BlockEvaluator.evaluate`; a `nil` here makes the insert
    /// resolve exactly as a static insert.
    ///
    /// PERSISTENCE (R4b, dynamic-blocks-plan §6a): the document is DXF-only, so this
    /// state is round-tripped LOSSLESSLY by embedding it in the DXF as a compact JSON
    /// string carried on a reserved-tag ATTRIB on the INSERT (`InsertDynamicState`'s
    /// `encodeJSON`/`decodeJSON`, wired through `DXFWriter`/`DXFReader` + the C
    /// bridge). It is name/string-keyed, so no member-id remap is needed (unlike the
    /// block DEFINITION). DXF only — dynamic-on-DWG does not round-trip.
    public var dynamic: InsertDynamicState?

    public init(
        blockName: String,
        insertionPoint: Vector,
        scale: Vector = Vector(1, 1),
        rotation: Double = 0,
        rows: Int = 1,
        cols: Int = 1,
        rowSpacing: Double = 0,
        colSpacing: Double = 0,
        attributes: [BlockAttributeValue] = [],
        dynamic: InsertDynamicState? = nil
    ) {
        self.blockName = blockName
        self.insertionPoint = insertionPoint
        self.scale = scale
        self.rotation = rotation
        self.rows = Swift.max(1, rows)
        self.cols = Swift.max(1, cols)
        self.rowSpacing = rowSpacing
        self.colSpacing = colSpacing
        self.attributes = attributes
        self.dynamic = dynamic
    }

    /// Whether this insert repeats over a grid (more than one cell).
    public var isArray: Bool { rows > 1 || cols > 1 }
}

// MARK: - Decodable (back-compat: tolerate missing MINSERT fields)

extension InsertData {
    private enum CodingKeys: String, CodingKey {
        case blockName, insertionPoint, scale, rotation, rows, cols, colSpacing, rowSpacing
        case attributes
        case dynamic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockName = try c.decode(String.self, forKey: .blockName)
        insertionPoint = try c.decode(Vector.self, forKey: .insertionPoint)
        scale = try c.decodeIfPresent(Vector.self, forKey: .scale) ?? Vector(1, 1)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        rows = Swift.max(1, try c.decodeIfPresent(Int.self, forKey: .rows) ?? 1)
        cols = Swift.max(1, try c.decodeIfPresent(Int.self, forKey: .cols) ?? 1)
        colSpacing = try c.decodeIfPresent(Double.self, forKey: .colSpacing) ?? 0
        rowSpacing = try c.decodeIfPresent(Double.self, forKey: .rowSpacing) ?? 0
        // ADDITIVE: old files (no `attributes` key) decode to an empty list.
        attributes = try c.decodeIfPresent([BlockAttributeValue].self, forKey: .attributes) ?? []
        // ADDITIVE: old files (no `dynamic` key) decode to nil — a plain insert.
        dynamic = try c.decodeIfPresent(InsertDynamicState.self, forKey: .dynamic)
    }
}

// MARK: - Raster image defining data (RS_Image / DRW_Image, DXF IMAGE + IMAGEDEF)

/// The IMAGEDEF half of a raster image — the shared **image definition** (the
/// source file + its pixel size). Mirrors libdxfrw's `DRW_ImageDef` (DXF
/// `IMAGEDEF`, an OBJECTS-section object the `IMAGE` entity hard-references by
/// handle, code 340). In AutoCAD one `IMAGEDEF` can back many `IMAGE` placements;
/// the engine models it inline on each `ImageData` (a value type, no shared-graph
/// reference) so a placed image is one self-contained value that round-trips via
/// Codable. The DXF reader links the two halves by handle and folds the IMAGEDEF
/// into the `ImageData` it builds.
///
/// ## Field grounding (DXF `IMAGEDEF` / libdxfrw `DRW_ImageDef`)
/// - `path`        — code 1: the image file's path/name (`DRW_ImageDef::name`).
/// - `pixelWidth`  — code 10: image size in pixels, U value (`DRW_ImageDef::u`).
/// - `pixelHeight` — code 20: image size in pixels, V value (`DRW_ImageDef::v`).
public struct ImageDefData: Sendable, Hashable, Codable {
    /// DXF code 1 — the source image file path/URL string.
    public var path: String
    /// DXF code 10 — the image's pixel width (U size). `0` ⇒ unknown.
    public var pixelWidth: Double
    /// DXF code 20 — the image's pixel height (V size). `0` ⇒ unknown.
    public var pixelHeight: Double

    public init(path: String, pixelWidth: Double = 0, pixelHeight: Double = 0) {
        self.path = path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The display adjustments AutoCAD lets a placed raster image carry (DXF IMAGE
/// codes 280–283). Carried for round-trip + honored by the renderer where cheap
/// (`showImage`); `brightness`/`contrast`/`fade` are passed to the texture draw as
/// shader params (the f32 [0,1] forms are derived from the DXF 0–100 integers).
public struct ImageDisplay: Sendable, Hashable, Codable {
    /// DXF code 281 — brightness, 0–100, default 50.
    public var brightness: Int
    /// DXF code 282 — contrast, 0–100, default 50.
    public var contrast: Int
    /// DXF code 283 — fade, 0–100, default 0 (0 == fully opaque image).
    public var fade: Int
    /// Whether the image is drawn at all (DXF "show image" display flag, code 70
    /// bit 1). `false` ⇒ the resolve still emits the placeholder outline so the
    /// frame is selectable, but the renderer skips the texture.
    public var showImage: Bool
    /// Whether a clip boundary is active (DXF code 280). The engine does not yet
    /// honor clipping (the full polygon clip path is backlog); carried for
    /// round-trip + so the inspector can show the state. Always treated as "off"
    /// by the resolve/render path for now.
    public var clipping: Bool

    public init(brightness: Int = 50, contrast: Int = 50, fade: Int = 0,
                showImage: Bool = true, clipping: Bool = false) {
        self.brightness = brightness
        self.contrast = contrast
        self.fade = fade
        self.showImage = showImage
        self.clipping = clipping
    }

    /// The engine default display (neutral brightness/contrast, no fade, shown,
    /// not clipped).
    public static let `default` = ImageDisplay()
}

// MARK: - Decodable (back-compat: tolerate missing display fields)

extension ImageDisplay {
    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, fade, showImage, clipping
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 50
        contrast = try c.decodeIfPresent(Int.self, forKey: .contrast) ?? 50
        fade = try c.decodeIfPresent(Int.self, forKey: .fade) ?? 0
        showImage = try c.decodeIfPresent(Bool.self, forKey: .showImage) ?? true
        clipping = try c.decodeIfPresent(Bool.self, forKey: .clipping) ?? false
    }
}

/// `RS_ImageData` — a placed **raster image** (DXF `IMAGE`, libdxfrw `DRW_Image`).
/// A value type holding only the defining placement data (ADR-001); the drawn
/// graphic — a textured quad at the four world corners, or a placeholder outline
/// when the file is missing — is produced on demand by `resolve()`, never stored.
///
/// ## DXF IMAGE placement semantics (the u/v vector encoding)
/// A DXF IMAGE is placed by an `insertion` point (code 10, the image's
/// **lower-left** corner in world space) plus two direction-and-scale vectors:
/// - `uVector` (code 11) is **one pixel's worth of the row direction** — i.e. the
///   image's bottom edge spans `uVector * pixelWidth` from the insertion point.
/// - `vVector` (code 12) is one pixel's worth of the column direction — the left
///   edge spans `vVector * pixelHeight`.
///
/// Together u and v encode the image's **size, rotation, and aspect** (they need
/// not be perpendicular or equal length, though they usually are). `pixelWidth`/
/// `pixelHeight` come from the IMAGEDEF (`imageDef.pixelWidth`/`pixelHeight`),
/// captured on `imageDef`. The four world corners the resolve produces are:
///   `insertion`,  `insertion + u·W`,  `insertion + u·W + v·H`,  `insertion + v·H`
/// (CCW from the lower-left), where `W = imageDef.pixelWidth`, `H = pixelHeight`.
///
/// To keep the placement self-consistent even when the IMAGEDEF pixel size is
/// unknown (`0`), `corners` falls back to treating `uVector`/`vVector` as the FULL
/// edge vectors (pixel size `1`); a real DXF always supplies the pixel size, so the
/// per-pixel form is exact there.
///
/// ## Field grounding (DXF `IMAGE` / libdxfrw `DRW_Image`)
/// - `insertion` — code 10 (`DRW_Image::basePoint`): the lower-left corner.
/// - `uVector`   — code 11 (`DRW_Image::secPoint`): per-pixel U (row) vector.
/// - `vVector`   — code 12 (`DRW_Image::vVector`): per-pixel V (column) vector.
/// - `imageDef`  — the linked IMAGEDEF (file path + pixel size).
/// - `display`   — brightness/contrast/fade/show/clip (codes 280–283).
public struct ImageData: Sendable, Hashable, Codable {
    /// DXF code 10 — the image's lower-left corner in world coords.
    public var insertion: Vector
    /// DXF code 11 — the per-pixel U (row-direction) vector. Scaled by the
    /// image's pixel width to span the image's bottom edge.
    public var uVector: Vector
    /// DXF code 12 — the per-pixel V (column-direction) vector. Scaled by the
    /// image's pixel height to span the image's left edge.
    public var vVector: Vector
    /// The linked image DEFINITION (source file path + pixel size).
    public var imageDef: ImageDefData
    /// Display adjustments (brightness/contrast/fade/show/clip).
    public var display: ImageDisplay

    public init(
        insertion: Vector,
        uVector: Vector,
        vVector: Vector,
        imageDef: ImageDefData,
        display: ImageDisplay = .default
    ) {
        self.insertion = insertion
        self.uVector = uVector
        self.vVector = vVector
        self.imageDef = imageDef
        self.display = display
    }

    /// Convenience for building a placement from a file path + the WHOLE edge
    /// vectors (`width`/`height` spanning the full image edges) — the form the
    /// placement TOOL produces from two clicks. The per-pixel u/v the DXF model
    /// stores are derived by dividing the edge vectors by the pixel size.
    ///
    /// - `lowerLeft`:  the lower-left corner.
    /// - `widthVector`: the full bottom-edge vector (size + rotation of the width).
    /// - `heightVector`: the full left-edge vector.
    /// - `pixelWidth`/`pixelHeight`: the source pixel dimensions (default 1×1 so a
    ///   caller that doesn't know them gets `u`/`v` equal to the edge vectors).
    public init(
        path: String,
        lowerLeft: Vector,
        widthVector: Vector,
        heightVector: Vector,
        pixelWidth: Double = 1,
        pixelHeight: Double = 1,
        display: ImageDisplay = .default
    ) {
        let w = pixelWidth > 0 ? pixelWidth : 1
        let h = pixelHeight > 0 ? pixelHeight : 1
        self.insertion = lowerLeft
        self.uVector = widthVector / w
        self.vVector = heightVector / h
        self.imageDef = ImageDefData(path: path, pixelWidth: w, pixelHeight: h)
        self.display = display
    }

    /// The full bottom-edge vector (`uVector · pixelWidth`) — the image's width as a
    /// world vector (size + rotation). Uses pixel size `1` when unknown so `uVector`
    /// is treated as the full edge.
    public var widthVector: Vector { uVector * (imageDef.pixelWidth > 0 ? imageDef.pixelWidth : 1) }

    /// The full left-edge vector (`vVector · pixelHeight`).
    public var heightVector: Vector { vVector * (imageDef.pixelHeight > 0 ? imageDef.pixelHeight : 1) }

    /// The effective image width in world units (the bottom-edge length).
    public var worldWidth: Double { widthVector.magnitude }

    /// The effective image height in world units (the left-edge length).
    public var worldHeight: Double { heightVector.magnitude }

    /// The image's rotation (radians) — the angle of the bottom edge (`uVector`).
    public var rotation: Double { uVector.angle }

    /// The four world-space corners of the placed image, CCW from the lower-left:
    /// `[insertion, +u·W, +u·W +v·H, +v·H]` where `W`/`H` are the pixel sizes (or
    /// `1` when unknown, so `u`/`v` are then treated as full edge vectors).
    public var corners: [Vector] {
        let u = widthVector
        let v = heightVector
        let p0 = insertion
        let p1 = insertion + u
        let p2 = insertion + u + v
        let p3 = insertion + v
        return [p0, p1, p2, p3]
    }
}

// MARK: - Wipeout defining data (DXF WIPEOUT, libdxfrw DRW_Image + AcDbWipeout)

/// `WipeoutData` — a **wipeout** (DXF `WIPEOUT`, AutoCAD's `AcDbWipeout`): a
/// masking polygon that paints the CANVAS BACKGROUND color over every
/// LOWER-draw-order entity beneath it, hiding (not erasing) the geometry behind
/// its boundary. Per ADR-001 a value type holding only the defining data; the
/// drawn graphic — one background-colored fill loop (the mask) plus an optional
/// frame outline — is produced on demand by `resolve()`, never stored.
///
/// ## Why a WIPEOUT reuses the IMAGE encoding (and is cloned from `ImageData`)
/// In DXF a `WIPEOUT` is literally an `AcDbRasterImage` subclass (`AcDbWipeout`)
/// with NO raster: libdxfrw delivers it as a `DRW_Image` (there is no
/// `DRW_Wipeout` class). So a wipeout carries the SAME placement frame an image
/// does — an `insertion` point (code 10), a per-pixel `uVector` (code 11) and
/// `vVector` (code 12), and a `pixelWidth`/`pixelHeight` (codes 13/23) — PLUS a
/// **clip-boundary polygon** (codes 91 + repeated 14/24) that is the masking
/// region, and a `clipMode` (code 290). The boundary lives in IMAGE-PIXEL space
/// (the 14/24 coordinates are fractions of the pixel grid the u/v frame spans),
/// so the WORLD polygon is `insertion + uVector·pxW·bx + vVector·pxH·by` for each
/// boundary vertex `(bx, by)` — this is the standard AcDbRasterImage clip-boundary
/// transform, identical to how `ImageData.corners` maps the unit quad to world.
///
/// ## Field grounding (DXF `WIPEOUT` / `AcDbWipeout`, cloned from `ImageData`)
/// - `insertion`    — code 10: the placement frame origin (lower-left), the pixel
///                    polygon's `(0,0)`.
/// - `uVector`      — code 11: the per-pixel U (row) vector spanning the frame's
///                    bottom edge over `pixelWidth` pixels.
/// - `vVector`      — code 12: the per-pixel V (column) vector spanning the left
///                    edge over `pixelHeight` pixels.
/// - `pixelWidth`/`pixelHeight` — codes 13/23: the frame's pixel size; `u`/`v` are
///                    scaled by these to span the full frame edges. `0` ⇒ treated
///                    as `1` so the u/v are the full edge vectors (a tool-built
///                    wipeout uses a 1×1 frame and stores the polygon in [0,1]²).
/// - `boundary`     — codes 91/14/24: the masking polygon, in IMAGE-PIXEL space (a
///                    flat vertex list, no bulges). Transformed to world by the
///                    frame above. ≥ 3 vertices is a real mask; fewer resolves to
///                    nothing.
/// - `clipMode`     — code 290: `false` (the AutoCAD default) masks OUTSIDE is not
///                    used — a wipeout always masks INSIDE its polygon; the flag is
///                    carried for round-trip. (We treat the polygon interior as the
///                    masked region regardless, matching the common WIPEOUT.)
/// - `frameVisible` — whether the boundary outline (the frame) is DRAWN. AutoCAD's
///                    WIPEOUTFRAME variable is document-global; we model it
///                    per-entity (additive) so a wipeout can show or hide its frame
///                    independently. Default `true` so a placed wipeout is visible
///                    + selectable.
public struct WipeoutData: Sendable, Hashable, Codable {
    /// DXF code 10 — the placement frame origin (the pixel polygon's `(0,0)`).
    public var insertion: Vector
    /// DXF code 11 — the per-pixel U (row-direction) vector. Scaled by
    /// `pixelWidth` to span the frame's bottom edge.
    public var uVector: Vector
    /// DXF code 12 — the per-pixel V (column-direction) vector. Scaled by
    /// `pixelHeight` to span the frame's left edge.
    public var vVector: Vector
    /// DXF code 13 — the frame's pixel width (U size). `0` ⇒ treated as `1`.
    public var pixelWidth: Double
    /// DXF code 23 — the frame's pixel height (V size). `0` ⇒ treated as `1`.
    public var pixelHeight: Double
    /// DXF codes 91/14/24 — the masking polygon in IMAGE-PIXEL space (no bulges).
    public var boundary: [Vector]
    /// DXF code 290 — the clip mode flag (round-trip only).
    public var clipMode: Bool
    /// Whether the boundary outline (frame) is drawn. Additive; default `true`.
    public var frameVisible: Bool

    public init(
        insertion: Vector,
        uVector: Vector,
        vVector: Vector,
        pixelWidth: Double = 1,
        pixelHeight: Double = 1,
        boundary: [Vector],
        clipMode: Bool = false,
        frameVisible: Bool = true
    ) {
        self.insertion = insertion
        self.uVector = uVector
        self.vVector = vVector
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.boundary = boundary
        self.clipMode = clipMode
        self.frameVisible = frameVisible
    }

    /// Convenience for building a wipeout from WORLD-space boundary points (the form
    /// the placement TOOL produces from clicks). Uses a 1×1 pixel frame whose
    /// `insertion` is the FIRST boundary point and whose `uVector`/`vVector` are the
    /// world axes — so the stored `boundary` is the world points expressed RELATIVE
    /// to `insertion` (i.e. pixel space == world-offset space when u/v are the unit
    /// axes). `worldBoundary()` recovers the world polygon exactly.
    public init(worldBoundary points: [Vector], frameVisible: Bool = true) {
        let origin = points.first ?? Vector(0, 0)
        self.insertion = origin
        self.uVector = Vector(1, 0)
        self.vVector = Vector(0, 1)
        self.pixelWidth = 1
        self.pixelHeight = 1
        self.boundary = points.map { $0 - origin }
        self.clipMode = false
        self.frameVisible = frameVisible
    }

    /// The effective pixel width (`1` when unknown/non-positive).
    public var effectivePixelWidth: Double { pixelWidth > 0 ? pixelWidth : 1 }
    /// The effective pixel height (`1` when unknown/non-positive).
    public var effectivePixelHeight: Double { pixelHeight > 0 ? pixelHeight : 1 }

    /// The full bottom-edge vector (`uVector · pixelWidth`).
    public var widthVector: Vector { uVector * effectivePixelWidth }
    /// The full left-edge vector (`vVector · pixelHeight`).
    public var heightVector: Vector { vVector * effectivePixelHeight }

    /// The masking polygon mapped to WORLD space: each pixel-space vertex `(bx, by)`
    /// becomes `insertion + uVector·bx + vVector·by` (the AcDbRasterImage clip-
    /// boundary transform — note the per-pixel u/v already encode the scale, so the
    /// pixel coordinates multiply u/v directly, NOT the full edge vectors).
    public var worldBoundary: [Vector] {
        boundary.map { insertion + uVector * $0.x + vVector * $0.y }
    }

    // MARK: - Decodable (back-compat: tolerate missing pixel size / clipMode / frame)

    private enum CodingKeys: String, CodingKey {
        case insertion, uVector, vVector, pixelWidth, pixelHeight, boundary, clipMode, frameVisible
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        insertion = try c.decode(Vector.self, forKey: .insertion)
        uVector = try c.decodeIfPresent(Vector.self, forKey: .uVector) ?? Vector(1, 0)
        vVector = try c.decodeIfPresent(Vector.self, forKey: .vVector) ?? Vector(0, 1)
        pixelWidth = try c.decodeIfPresent(Double.self, forKey: .pixelWidth) ?? 1
        pixelHeight = try c.decodeIfPresent(Double.self, forKey: .pixelHeight) ?? 1
        boundary = try c.decodeIfPresent([Vector].self, forKey: .boundary) ?? []
        clipMode = try c.decodeIfPresent(Bool.self, forKey: .clipMode) ?? false
        // ADDITIVE: a wipeout born without an explicit frame flag is framed.
        frameVisible = try c.decodeIfPresent(Bool.self, forKey: .frameVisible) ?? true
    }
}

// MARK: - Multiline (MLINE) defining data (DXF MLINE / AcDbMline)

/// How an `MLineData`'s element offsets are anchored to the drawn vertex `path`
/// (DXF `MLINE` justification, group code 70 low bits / `DRW_MLine`):
///
/// - `.top`    — the path follows the element with the **largest** offset (the
///               "top" line rides the vertices; every other element hangs below).
/// - `.zero`   — the path follows the element offset `0` (the centerline rides the
///               vertices). This is AutoCAD's default.
/// - `.bottom` — the path follows the element with the **smallest** offset (the
///               "bottom" line rides the vertices; every other element rises above).
///
/// Justification is applied as a uniform SHIFT of every element offset (so the
/// chosen extreme lands on the path) and is computed from the element offsets at
/// SCALE `1` — the `scale` (including a NEGATIVE scale, which mirrors the element
/// fan across the path) is then applied on top. See `MLineData.justificationShift`.
public enum MLineJustification: Int, Sendable, Hashable, Codable, CaseIterable {
    /// The largest-offset element rides the vertex path (DXF justification 0).
    case top = 0
    /// The zero-offset centerline rides the vertex path (DXF justification 1).
    case zero = 1
    /// The smallest-offset element rides the vertex path (DXF justification 2).
    case bottom = 2
}

/// One **line element** of a multiline (DXF `MLINE` element / an `MLSTYLE` element
/// carried INLINE on the entity for this MVP — there is no separate `MLSTYLE`
/// table yet). Each element is one parallel line drawn at a signed perpendicular
/// `offset` from the multiline's vertex path.
///
/// - `offset`     — the signed perpendicular distance (world units, at SCALE `1`)
///                  from the path to this element's line. Positive is to the LEFT
///                  of the path direction (the path's left normal); negative is to
///                  the right. The justification shift + the entity `scale` are
///                  applied on top of this base offset at resolve time.
/// - `colorIndex` — an OPTIONAL per-element AutoCAD Color Index (ACI) override
///                  (round-trip only in this MVP — resolve draws every element in
///                  the entity's resolved pen; honoring the per-element color is a
///                  later wave). `nil` ⇒ the element uses the entity pen / BYLAYER.
public struct MLineElement: Sendable, Hashable, Codable {
    /// Signed perpendicular offset from the path (world units, at scale 1). `+` left.
    public var offset: Double
    /// Optional per-element ACI color override (round-trip only this MVP).
    public var colorIndex: Int?

    public init(offset: Double, colorIndex: Int? = nil) {
        self.offset = offset
        self.colorIndex = colorIndex
    }

    private enum CodingKeys: String, CodingKey { case offset, colorIndex }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
    }
}

/// `DRW_MLine` — a **multiline** (DXF `MLINE` / `AcDbMline`): N parallel line
/// elements drawn along one shared vertex `path`, the way AutoCAD's `MLINE`
/// command draws walls / multi-line borders. Per ADR-001 this is a value type
/// holding ONLY the defining data; the drawn graphic (the N offset element lines,
/// mitered at interior corners) is produced on demand by `resolve()` as a set of
/// `ResolvedPolyline`s, never stored.
///
/// ## MVP scope (Wave 0 — the EntityKind critical section)
/// The elements are carried **inline** on the entity (an `elements: [MLineElement]`
/// each with an `offset` + optional color) rather than referenced from a separate
/// `MLSTYLE` table — a real `MLSTYLE` table is a later wave and stays additive.
/// Element ends are SQUARE (no start/end caps), there is NO fill between elements,
/// and there is no `MLEDIT` (vertex-style join editing). Interior corners are
/// MITERED; a near-180° reversal (a spike-prone corner) CLAMPS to a butt/bevel
/// join so the miter never runs away to infinity.
///
/// ## Justification × scale sign-lock (pinned by a test)
/// `justification` chooses which element rides the `path` by SHIFTING every element
/// offset so the chosen extreme lands on the path (computed at SCALE `1` —
/// `justificationShift`). The `scale` then multiplies the shifted offsets; a
/// NEGATIVE scale mirrors the whole element fan across the path (flipping element
/// order/side), which is the documented AutoCAD behavior and is locked by
/// `effectiveOffsets`.
public struct MLineData: Sendable, Hashable, Codable {
    /// The ordered vertex path the elements are drawn parallel to. 2+ valid points
    /// draw lines; 0/1 points (or all-coincident) draw nothing (degenerate-safe).
    public var vertices: [Vector]
    /// The inline parallel-line elements (each a signed offset + optional color).
    /// Empty ⇒ nothing drawn (degenerate-safe).
    public var elements: [MLineElement]
    /// Which element rides the vertex path (top / zero / bottom).
    public var justification: MLineJustification
    /// Overall offset scale (DXF code 40). Multiplies every (shifted) element
    /// offset; a NEGATIVE scale mirrors the element fan across the path.
    public var scale: Double
    /// Whether the path is closed (the last vertex joins back to the first, with a
    /// mitered wrap corner). DXF `MLINE` "closed" flag (code 70 bit 2).
    public var closed: Bool

    public init(
        vertices: [Vector],
        elements: [MLineElement],
        justification: MLineJustification = .zero,
        scale: Double = 1,
        closed: Bool = false
    ) {
        self.vertices = vertices
        self.elements = elements
        self.justification = justification
        self.scale = scale
        self.closed = closed
    }

    private enum CodingKeys: String, CodingKey {
        case vertices, elements, justification, scale, closed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ADDITIVE back-compat: every field decodes via decodeIfPresent ?? default
        // so a partial / future-extended MLINE JSON still decodes losslessly.
        vertices = try c.decodeIfPresent([Vector].self, forKey: .vertices) ?? []
        elements = try c.decodeIfPresent([MLineElement].self, forKey: .elements) ?? []
        justification = try c.decodeIfPresent(MLineJustification.self, forKey: .justification) ?? .zero
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }

    /// The uniform offset SHIFT (at scale 1) the justification adds to every
    /// element offset so the chosen extreme element rides the path:
    /// - `.zero`   ⇒ `0` (offsets are used as authored; the `0` element is on path).
    /// - `.top`    ⇒ `-max(offset)` (slides the fan DOWN so the top element is at 0).
    /// - `.bottom` ⇒ `-min(offset)` (slides the fan UP so the bottom element is at 0).
    /// Computed at scale 1 (the sign-lock applies `scale` afterward in
    /// `effectiveOffsets`). No elements ⇒ `0`.
    public var justificationShift: Double {
        let offs = elements.map(\.offset)
        guard let lo = offs.min(), let hi = offs.max() else { return 0 }
        switch justification {
        case .zero:   return 0
        case .top:    return -hi
        case .bottom: return -lo
        }
    }

    /// The per-element EFFECTIVE signed offsets used by `resolve()`:
    /// `(offset + justificationShift) * scale`. The `* scale` is the sign-lock — a
    /// negative scale mirrors the element fan across the path (so the element that
    /// rode the path under `.top` ends up on the far side). Order matches `elements`.
    public var effectiveOffsets: [Double] {
        let shift = justificationShift
        return elements.map { ($0.offset + shift) * scale }
    }
}

// MARK: - The entity-kind sum type

/// The discriminated union of entity geometry. This is the **seed set** for the
/// foundation skeleton; Phase 1 fans out the full set (ellipse, spline, text,
/// mtext, insert, hatch, all dimensions) by adding cases here + a `resolve` arm
/// (see `Resolve.swift`). The compiler's exhaustiveness check makes the resolve
/// switch a checklist for every new case.
public enum EntityKind: Sendable, Hashable, Codable {
    case point(PointData)
    case line(LineData)
    case circle(CircleData)
    case arc(ArcData)
    case polyline(PolylineData)
    /// An ellipse or elliptic arc (`RS_Ellipse`).
    case ellipse(EllipseData)
    /// A (rational) B-spline / NURBS curve (`RS_Spline`).
    case spline(SplineData)
    /// An interpolation spline drawn as quadratic Béziers (`LC_SplinePoints`).
    case splinePoints(SplinePointsData)
    /// Single-line CAD text drawn as `.lff` stroked polylines (`RS_Text`).
    case text(TextData)
    /// Rich multi-line formatted text — paragraphs of per-run-formatted runs with
    /// word wrapping, attachment-point alignment, stacked fractions, and per-run
    /// font/height/colour/decoration (`RS_MText`, DXF `MTEXT`). Its laid-out
    /// geometry (glyph fills/strokes + decoration strokes) is computed in
    /// `resolve()` via `ResolveContext.fontProvider`, never stored (ADR-001).
    case mtext(MTextData)
    /// A filled region defined by boundary loops (`RS_Hatch`).
    case hatch(HatchData)
    /// A filled triangle/quadrilateral (`RS_Solid`, DXF `SOLID`/`TRACE`).
    case solid(SolidData)
    /// An associative CAD dimension — linear / aligned / radial / diameter /
    /// angular (`RS_Dimension` family, DXF `DIMENSION`). Its graphic (extension
    /// lines, dimension line, arrowheads, measurement text) is computed in
    /// `resolve()`, never stored (ADR-001).
    case dimension(DimData)
    /// A **block reference** — a placement of a named block (`RS_Insert`, DXF
    /// `INSERT`/`MINSERT`). Its placed geometry (the block's member entities,
    /// transformed by the insert's placement and optionally repeated over a grid)
    /// is computed in `resolve()` via `ResolveContext.blockProvider`, never stored
    /// (ADR-001).
    case insert(InsertData)
    /// An **infinite construction line** (`RS_ConstructionLine`, DXF `XLINE`).
    /// Extends to infinity both ways along its direction. Its drawn segment
    /// (clipped to the view via `ResolveContext.clipBounds`, or a large finite
    /// fallback segment) is computed in `resolve()`, never stored (ADR-001).
    case xline(XLineData)
    /// A **ray** — a semi-infinite construction line (`RS_ConstructionLine`
    /// one-way form, DXF `RAY`). Extends from its base to infinity in the
    /// `+direction` sense only. Its drawn segment is computed in `resolve()`,
    /// never stored (ADR-001).
    case ray(RayData)
    /// A **leader** — an annotation callout (`RS_Leader`, DXF `LEADER`): a
    /// polyline path + an optional arrowhead at the first vertex + an optional
    /// attached `.text`/`.mtext` annotation at the last vertex. Its graphic (path
    /// segments, arrowhead fill via the shared dimension-arrowhead helper, and the
    /// annotation via the shared `.text`/`.mtext` resolve arm — no second text
    /// path) is computed in `resolve()`, never stored (ADR-001). `indirect`
    /// because `LeaderData.annotation` stores an `EntityKind` (a leader contains a
    /// text/mtext kind — the recursion is bounded: an annotation is never itself a
    /// leader).
    indirect case leader(LeaderData)
    /// A **multileader** — AutoCAD's modern annotation callout (`DXF MULTILEADER`/
    /// `MLEADER`) that superseded the legacy `LEADER`. Like a `.leader` it is a leg
    /// polyline + an optional arrowhead at the first vertex + an optional attached
    /// `.text`/`.mtext` annotation, but it adds a **landing** ("dogleg") tail run
    /// between the last leg vertex and the annotation. Its graphic (leg segments,
    /// arrowhead fill via the shared dimension-arrowhead helper, the landing
    /// segment, and the annotation via the shared `.text`/`.mtext` resolve arm — no
    /// second text path) is computed in `resolve()`, never stored (ADR-001).
    /// `indirect` because `MultiLeaderData.annotation` stores an `EntityKind` (the
    /// recursion is bounded: an annotation is never itself a (multi)leader). v1 is a
    /// single-root callout; block content + multi-root are a later wave.
    indirect case multileader(MultiLeaderData)
    /// A placed **raster image** (`RS_Image`, DXF `IMAGE` + `IMAGEDEF`). Its
    /// graphic — a textured quad at the four world corners (or a placeholder
    /// outline when the source file is missing) — is produced on demand by
    /// `resolve()` as a `ResolvedImage`, never stored (ADR-001). The bitmap is NOT
    /// part of the value model: only the file PATH + pixel size travel in
    /// `ImageData.imageDef`; the renderer loads + caches the texture by that path.
    case image(ImageData)
    /// A **wipeout** — a masking polygon (`DXF WIPEOUT` / `AcDbWipeout`) that
    /// paints the CANVAS BACKGROUND color over every LOWER-draw-order entity
    /// beneath its boundary, hiding (not erasing) the geometry behind it. Its
    /// graphic — one MASK `ResolvedFill` (flagged `isMask` so the renderer
    /// substitutes the live background color and draws it in a dedicated AFTER-the-
    /// lines pass) plus an optional frame `ResolvedPolyline` — is produced on demand
    /// by `resolve()`, never stored (ADR-001). Cloned from `.image` (a WIPEOUT is a
    /// raster-image subclass in DXF, with no raster); behaves like `.solid`/`.image`
    /// for the areal/non-editable switches.
    case wipeout(WipeoutData)
    /// A **multiline** (`DRW_MLine`, DXF `MLINE` / `AcDbMline`) — N parallel line
    /// elements drawn along one shared vertex path (AutoCAD's `MLINE` command, used
    /// for walls / multi-line borders). Its graphic (the N perpendicular-offset
    /// element lines, mitered at interior corners with a near-180° clamp to avoid
    /// runaway spikes) is produced on demand by `resolve()` as a set of
    /// `ResolvedPolyline`s, never stored (ADR-001). The elements are carried INLINE
    /// on the entity (offset + optional color) in this MVP — a separate `MLSTYLE`
    /// table is a later wave. Not `indirect`: `MLineData` holds no nested
    /// `EntityKind`. Behaves like a polyline for the path-vertex switches.
    case mline(MLineData)
}

// MARK: - Per-entity flags

/// Boolean entity state, ported from LibreCAD's `RS2::EntityFlags`
/// (visible/selected/locked/...). An `OptionSet` so flags combine cheaply.
public struct EntityFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// The entity is drawn (cleared == hidden).
    public static let visible      = EntityFlags(rawValue: 1 << 0)
    /// The entity is part of the current selection.
    public static let selected     = EntityFlags(rawValue: 1 << 1)
    /// The entity cannot be edited (e.g. on a locked layer).
    public static let locked       = EntityFlags(rawValue: 1 << 2)
    /// The entity is a temporary construction/helper (not persisted).
    public static let construction = EntityFlags(rawValue: 1 << 3)

    /// A freshly created, visible, editable entity.
    public static let `default`: EntityFlags = [.visible]
}

// MARK: - The entity record (common attrs + geometry)

/// The stored entity: a stable id, layer/pen/flags common attributes, and the
/// geometry-specific defining data in `kind`. Pure value type — copying it is
/// the whole undo snapshot for a single-entity edit (ADR-002).
public struct EntityRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: EntityID
    public var layer: LayerID
    public var pen: Pen
    public var flags: EntityFlags
    public var kind: EntityKind

    /// Which space the entity lives in — model (the implicit world drawing) or
    /// paper (a printed sheet). ADDITIVE (paper-space P0, paperspace-plan §2): a
    /// record born without it, and every old saved file (no space key), is
    /// `.model`, so existing model-space drawings are 100% unaffected. Maps 1:1 to
    /// DXF code 67 (the DXF round-trip is a later phase).
    public var space: EntitySpace
    /// WHICH paper sheet a `.paper` entity is on — the `Layout.name` it belongs to.
    /// `nil` for model-space entities (and for paper-space entities not yet bound to
    /// a named layout). ADDITIVE: born `nil`, old files decode `nil`.
    public var layoutName: String?

    public init(
        id: EntityID,
        layer: LayerID = .zero,
        pen: Pen = .byLayer,
        flags: EntityFlags = .default,
        kind: EntityKind,
        space: EntitySpace = .model,
        layoutName: String? = nil
    ) {
        self.id = id
        self.layer = layer
        self.pen = pen
        self.flags = flags
        self.kind = kind
        self.space = space
        self.layoutName = layoutName
    }

    /// Convenience: is this entity currently selected?
    public var isSelected: Bool {
        get { flags.contains(.selected) }
        set { if newValue { flags.insert(.selected) } else { flags.remove(.selected) } }
    }
}

// MARK: - Decodable (back-compat: tolerate missing space / layoutName)
//
// The paper-space P0 fields (`space`, `layoutName`) are ADDITIVE: an OLD saved
// file (encoded before they existed) has no `space`/`layoutName` keys. A hand-
// written `init(from:)` with `decodeIfPresent` (the same pattern HatchData et al.
// use) decodes those absent keys as `.model` / `nil`, so old model-space drawings
// load unchanged. `encode(to:)` and `Hashable`/`Equatable` stay synthesized (the
// `CodingKeys` below cover every field, so the synthesized encode includes the new
// keys; Hashable/Equatable auto-include the new stored properties).

extension EntityRecord {
    private enum CodingKeys: String, CodingKey {
        case id, layer, pen, flags, kind, space, layoutName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EntityID.self, forKey: .id)
        layer = try c.decode(LayerID.self, forKey: .layer)
        pen = try c.decode(Pen.self, forKey: .pen)
        flags = try c.decode(EntityFlags.self, forKey: .flags)
        kind = try c.decode(EntityKind.self, forKey: .kind)
        // Additive paper-space fields: absent in old files ⇒ model space, no layout.
        space = try c.decodeIfPresent(EntitySpace.self, forKey: .space) ?? .model
        layoutName = try c.decodeIfPresent(String.self, forKey: .layoutName)
    }
}
