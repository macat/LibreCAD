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

/// `RS_PointData` — a single position.
public struct PointData: Sendable, Hashable, Codable {
    public var position: Vector
    public init(position: Vector) { self.position = position }
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
public struct SplineData: Sendable, Hashable, Codable {
    public var degree: Int
    public var controlPoints: [Vector]
    public var knots: [Double]
    public var weights: [Double]
    public var closed: Bool

    public init(
        degree: Int,
        controlPoints: [Vector],
        knots: [Double] = [],
        weights: [Double] = [],
        closed: Bool = false
    ) {
        self.degree = degree
        self.controlPoints = controlPoints
        self.knots = knots
        self.weights = weights
        self.closed = closed
    }
}

// MARK: - Text / fill defining data (RS_TextData / RS_HatchData / RS_SolidData)

/// Horizontal text alignment, mirroring the essential `RS_TextData::HAlign`
/// cases (DXF group 72). Layout honoring beyond `.left` is backlog (see the
/// `text` resolve arm); the field is carried so the reader-import wave can map
/// DXF group 72 without a contract change.
public enum TextHAlign: Int, Sendable, Hashable, Codable {
    case left = 0
    case center = 1
    case right = 2
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
    public var height: Double
    public var rotation: Double
    public var text: String
    public var styleName: String?
    public var hAlign: TextHAlign
    public var vAlign: TextVAlign
    public var letterSpacingFactor: Double

    public init(
        position: Vector,
        height: Double,
        rotation: Double = 0,
        text: String,
        styleName: String? = nil,
        hAlign: TextHAlign = .left,
        vAlign: TextVAlign = .baseline,
        letterSpacingFactor: Double = 1.0
    ) {
        self.position = position
        self.height = height
        self.rotation = rotation
        self.text = text
        self.styleName = styleName
        self.hAlign = hAlign
        self.vAlign = vAlign
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
public struct HatchData: Sendable, Hashable, Codable {
    public var loops: [[PolylineVertex]]
    public var solidFill: Bool
    public var patternName: String?

    public init(loops: [[PolylineVertex]], solidFill: Bool = true, patternName: String? = nil) {
        self.loops = loops
        self.solidFill = solidFill
        self.patternName = patternName
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
    /// A filled region defined by boundary loops (`RS_Hatch`).
    case hatch(HatchData)
    /// A filled triangle/quadrilateral (`RS_Solid`, DXF `SOLID`/`TRACE`).
    case solid(SolidData)
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

    public init(
        id: EntityID,
        layer: LayerID = .zero,
        pen: Pen = .byLayer,
        flags: EntityFlags = .default,
        kind: EntityKind
    ) {
        self.id = id
        self.layer = layer
        self.pen = pen
        self.flags = flags
        self.kind = kind
    }

    /// Convenience: is this entity currently selected?
    public var isSelected: Bool {
        get { flags.contains(.selected) }
        set { if newValue { flags.insert(.selected) } else { flags.remove(.selected) } }
    }
}
