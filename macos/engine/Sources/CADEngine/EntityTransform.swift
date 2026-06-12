//
//  EntityTransform.swift
//  CADEngine
//
//  The SHARED 2D affine transform + per-`EntityKind` application that every
//  MODIFY tool (move / copy / rotate / scale / mirror) composes against. This is
//  the single source of truth for "apply a geometric transform to an entity",
//  ported from LibreCAD's `RS_Entity::move/rotate/scale/mirror` family
//  (`rs_arc.cpp`, `rs_ellipse.cpp`, `rs_polyline.cpp`, `rs_vector.cpp`).
//
//  Design (ADR-001 / ADR-003): pure value types, f64 throughout, no mutation of
//  the entity model — `EntityKind.transformed(by:)` returns a fresh value.
//
//  An `Affine2D` is a 2x2 linear part `[a b; c d]` plus a translation `(tx, ty)`,
//  applied as `p' = M·p + t`. The MODIFY tools build these from the statics
//  (`.translation`, `.rotation(about:)`, `.scale(about:)`, `.mirror`) and compose
//  them with `*`. The linear part of every tool-produced transform is a SIMILARITY
//  (uniform scale × rotation, optionally with a reflection) — which is exactly the
//  class for which a circle stays a circle and an arc/ellipse keeps its shape. The
//  per-kind application relies on that: `uniformScale` and `rotationDelta` are read
//  off the matrix, and an orientation-reversing transform (`isMirror`, det < 0) is
//  handled with LibreCAD's reflected-angle / flipped-`reversed` / flipped-bulge
//  semantics.
//
//  LIMITATION (documented, out of scope for the foundation): a NON-uniform scale
//  (sx != sy) turns a circle into an ellipse and an arc into an elliptic arc. The
//  faithful LibreCAD behavior (RS_Polyline::scale upgrades arc children to
//  ellipses) is NOT ported here — `circle`/`arc` assume a uniform scale factor and
//  use the average |scale|; non-uniform on a circle/arc is a TODO. Lines,
//  polylines (vertex points), ellipses, and splines transform correctly under
//  non-uniform scale because they only need point transforms (the ellipse's
//  general-shear case is the one nuance and is also noted below).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_* transform semantics).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - Affine2D

/// A 2D affine transform: a 2x2 linear part `[a b; c d]` plus a translation
/// `(tx, ty)`, applied to a point as `p' = M·p + t`.
///
/// Column convention: `x' = a·x + b·y + tx`, `y' = c·x + d·y + ty`. (The `z`
/// component of a `Vector` is carried through unchanged — the engine is 2D.)
///
/// Compose with `*` (or `concatenating(_:)`): `(A * B).apply(p) == A.apply(B.apply(p))`,
/// i.e. `B` is applied first, then `A` — standard matrix-composition order.
public struct Affine2D: Sendable, Equatable {
    // Linear part [a b; c d].
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    // Translation.
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    // MARK: Constructors / statics

    /// The identity transform (leaves every point fixed).
    public static let identity = Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// Pure translation by `offset` (`RS_Entity::move`).
    public static func translation(_ offset: Vector) -> Affine2D {
        Affine2D(a: 1, b: 0, c: 0, d: 1, tx: offset.x, ty: offset.y)
    }

    /// Rotation by `angle` radians (CCW) about the origin.
    public static func rotation(angle: Double) -> Affine2D {
        let cs = cos(angle), sn = sin(angle)
        return Affine2D(a: cs, b: -sn, c: sn, d: cs, tx: 0, ty: 0)
    }

    /// Rotation by `angle` radians (CCW) about the pivot `center`
    /// (`RS_Entity::rotate(center, angle)`).
    public static func rotation(angle: Double, about center: Vector) -> Affine2D {
        rotation(angle: angle).aroundPivot(center)
    }

    /// Uniform scale by `factor` about the pivot `center`
    /// (`RS_Entity::scale(center, factor)` with `factor.x == factor.y`).
    public static func scale(factor: Double, about center: Vector) -> Affine2D {
        scale(sx: factor, sy: factor, about: center)
    }

    /// Non-uniform scale by `(sx, sy)` about the pivot `center`. Note the per-kind
    /// limitation above: circle/arc assume a uniform factor.
    public static func scale(sx: Double, sy: Double, about center: Vector) -> Affine2D {
        Affine2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0).aroundPivot(center)
    }

    /// Reflection across the infinite line through `point` at `angle` radians
    /// (`RS_Entity::mirror(axisPoint1, axisPoint2)` with the axis given as a
    /// point + direction). The reflection matrix for a line at angle `θ` through
    /// the origin is `[cos2θ, sin2θ; sin2θ, -cos2θ]`.
    public static func mirror(acrossLineThrough point: Vector, angle: Double) -> Affine2D {
        let c2 = cos(2 * angle), s2 = sin(2 * angle)
        return Affine2D(a: c2, b: s2, c: s2, d: -c2, tx: 0, ty: 0).aroundPivot(point)
    }

    /// Reflection across the infinite line through the two distinct points
    /// `axisPoint1`/`axisPoint2` — the exact `RS_Vector::mirror(p1, p2)` form the
    /// MIRROR tool collects from the user. Returns `.identity` if the points
    /// coincide (degenerate axis).
    public static func mirror(axisPoint1 p1: Vector, axisPoint2 p2: Vector) -> Affine2D {
        let dir = p2 - p1
        guard dir.squared > Tolerance.distanceSquared else { return .identity }
        return mirror(acrossLineThrough: p1, angle: dir.angle)
    }

    /// Wraps a linear transform `self` so it acts about `pivot` instead of the
    /// origin: `translate(+pivot) * self * translate(-pivot)`.
    private func aroundPivot(_ pivot: Vector) -> Affine2D {
        // p' = M·(p - pivot) + pivot = M·p + (pivot - M·pivot)
        let mpx = a * pivot.x + b * pivot.y
        let mpy = c * pivot.x + d * pivot.y
        return Affine2D(
            a: a, b: b, c: c, d: d,
            tx: tx + pivot.x - mpx,
            ty: ty + pivot.y - mpy
        )
    }

    // MARK: Composition

    /// Matrix composition: `(lhs * rhs).apply(p) == lhs.apply(rhs.apply(p))`
    /// (rhs applied first). Equivalent to `lhs.concatenating(rhs)`.
    public static func * (lhs: Affine2D, rhs: Affine2D) -> Affine2D {
        // Linear: L = lhs.M · rhs.M
        let a = lhs.a * rhs.a + lhs.b * rhs.c
        let b = lhs.a * rhs.b + lhs.b * rhs.d
        let c = lhs.c * rhs.a + lhs.d * rhs.c
        let d = lhs.c * rhs.b + lhs.d * rhs.d
        // Translation: t = lhs.M · rhs.t + lhs.t
        let tx = lhs.a * rhs.tx + lhs.b * rhs.ty + lhs.tx
        let ty = lhs.c * rhs.tx + lhs.d * rhs.ty + lhs.ty
        return Affine2D(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// Returns `self ∘ other` (other applied first). Named alias for `*`.
    public func concatenating(_ other: Affine2D) -> Affine2D { self * other }

    // MARK: Application

    /// Applies the transform to a point. `z`/`valid` are carried through.
    public func apply(_ p: Vector) -> Vector {
        guard p.valid else { return p }
        return Vector(a * p.x + b * p.y + tx, c * p.x + d * p.y + ty, p.z)
    }

    /// Applies only the LINEAR part to a free vector (no translation) — used for
    /// the ellipse's `majorP`, which is stored relative to the center.
    public func applyLinear(_ v: Vector) -> Vector {
        Vector(a * v.x + b * v.y, c * v.x + d * v.y, v.z)
    }

    // MARK: Derived accessors (for entity angle/radius updates)

    /// Determinant of the linear part. Its sign tells orientation: `> 0`
    /// preserves orientation, `< 0` is a reflection (mirror).
    public var determinant: Double { a * d - b * c }

    /// `true` if the transform reverses orientation (a reflection / mirror).
    /// Arc/ellipse `reversed` flips and polyline bulge sign flips iff this holds.
    public var isMirror: Bool { determinant < 0 }

    /// The uniform scale factor, `sqrt(|det|)`. For the similarity transforms the
    /// MODIFY tools produce (uniform scale × rotation × optional reflection) this
    /// is the exact factor a circle/arc radius and ellipse axis are scaled by.
    /// (For a non-uniform scale it is the geometric mean `sqrt(sx·sy)` — see the
    /// circle/arc limitation in the file header.)
    public var uniformScale: Double { determinant.magnitude.squareRoot() }

    /// The rotation the transform applies, in radians, normalized to `[0, 2π)`.
    ///
    /// For an orientation-preserving similarity `[s·cosθ, -s·sinθ; s·sinθ, s·cosθ]`
    /// this is `θ` (`atan2(c, a)`). For a reflection there is no single rotation;
    /// arc/ellipse mirror is handled by the dedicated reflected-angle path, so
    /// callers should consult `isMirror` first. We still return `atan2(c, a)` for
    /// completeness.
    public var rotationDelta: Double { Vector.correctAngle(atan2(c, a)) }

    /// The axis angle of a reflection (mirror) transform, in `[0, π)`. For the arc
    /// reflected-angle formula LibreCAD uses `2 · axisAngle`; this recovers that
    /// axis angle directly from the matrix: a reflection across a line at angle `φ`
    /// is `[cos2φ, sin2φ; sin2φ, -cos2φ]`, so `2φ = atan2(b, a)` (up to scale).
    public var mirrorAxisAngle: Double { 0.5 * atan2(b, a) }
}

// MARK: - EntityKind transform

public extension EntityKind {
    /// Returns a copy of this entity's geometry transformed by `t`.
    ///
    /// This is the contract every MODIFY tool calls. The transform is applied per
    /// `RS_*::move/rotate/scale/mirror` semantics; see the per-case notes. The
    /// returned value is a fresh `EntityKind` (no mutation; ADR-001).
    func transformed(by t: Affine2D) -> EntityKind {
        EntityTransform.transform(self, by: t)
    }
}

/// Namespaced home for the per-`EntityKind` transform application (static helpers,
/// not module-scope free functions — see CONVENTIONS.md fan-out hazard note).
public enum EntityTransform {

    /// Applies `t` to `kind`, dispatching on the entity case. Exhaustive: every
    /// `EntityKind` case is handled, so adding a case is a compile error here.
    public static func transform(_ kind: EntityKind, by t: Affine2D) -> EntityKind {
        switch kind {
        case .point(let p):           return .point(transformPoint(p, t))
        case .line(let l):            return .line(transformLine(l, t))
        case .circle(let c):          return .circle(transformCircle(c, t))
        case .arc(let a):             return .arc(transformArc(a, t))
        case .polyline(let pl):       return .polyline(transformPolyline(pl, t))
        case .ellipse(let e):         return .ellipse(transformEllipse(e, t))
        case .spline(let s):          return .spline(transformSpline(s, t))
        case .splinePoints(let sp):   return .splinePoints(transformSplinePoints(sp, t))
        case .text(let tx):           return .text(transformText(tx, t))
        case .mtext(let mt):          return .mtext(transformMText(mt, t))
        case .hatch(let h):           return .hatch(transformHatch(h, t))
        case .solid(let s):           return .solid(transformSolid(s, t))
        case .dimension(let dm):      return .dimension(transformDimension(dm, t))
        case .insert(let ins):        return .insert(transformInsert(ins, t))
        }
    }

    // MARK: point — transform the position.

    static func transformPoint(_ p: PointData, _ t: Affine2D) -> PointData {
        PointData(position: t.apply(p.position))
    }

    // MARK: line — transform both endpoints.

    static func transformLine(_ l: LineData, _ t: Affine2D) -> LineData {
        LineData(start: t.apply(l.start), end: t.apply(l.end))
    }

    // MARK: circle — transform center; radius *= uniformScale.

    /// LIMITATION: under a non-uniform scale a circle becomes an ellipse. That is
    /// out of scope for the foundation (TODO: upgrade circle → ellipse like
    /// `RS_Polyline::scale` does for arc children). Here we apply `uniformScale`
    /// (the geometric-mean factor) so the common uniform-scale path is exact.
    static func transformCircle(_ c: CircleData, _ t: Affine2D) -> CircleData {
        CircleData(center: t.apply(c.center), radius: c.radius * t.uniformScale)
    }

    // MARK: arc — center transforms; radius *= scale; angles rotate; mirror
    //       flips `reversed` and reflects the angles.

    static func transformArc(_ arc: ArcData, _ t: Affine2D) -> ArcData {
        let center = t.apply(arc.center)
        let radius = abs(arc.radius * t.uniformScale)
        if t.isMirror {
            // RS_Arc::mirror: reversed flips; a = 2·axisAngle; angle_i = a - angle_i.
            let a = t.mirrorAxisAngle * 2
            return ArcData(
                center: center,
                radius: radius,
                startAngle: Vector.correctAngle(a - arc.startAngle),
                endAngle: Vector.correctAngle(a - arc.endAngle),
                reversed: !arc.reversed
            )
        } else {
            // RS_Arc::rotate: both angles shift by the rotation; reversed unchanged.
            // (Pure scale has rotationDelta == 0, so angles are preserved.)
            let rot = t.rotationDelta
            return ArcData(
                center: center,
                radius: radius,
                startAngle: Vector.correctAngle(arc.startAngle + rot),
                endAngle: Vector.correctAngle(arc.endAngle + rot),
                reversed: arc.reversed
            )
        }
    }

    // MARK: polyline — transform every vertex point; bulge sign flips under
    //       mirror (a reflection reverses each arc segment's orientation); bulge
    //       magnitude is unchanged under rotation/uniform-scale.

    static func transformPolyline(_ pl: PolylineData, _ t: Affine2D) -> PolylineData {
        let flip = t.isMirror
        let verts = pl.vertices.map { v in
            PolylineVertex(point: t.apply(v.point), bulge: flip ? -v.bulge : v.bulge)
        }
        return PolylineData(vertices: verts, closed: pl.closed)
    }

    // MARK: ellipse — center transforms; majorP gets the LINEAR part (rotate +
    //       scale); ratio is invariant under uniform scale + rotation; under
    //       mirror `reversed` flips and the parametric angles are recomputed from
    //       the reflected start/end world points (RS_Ellipse::mirror).

    static func transformEllipse(_ e: EllipseData, _ t: Affine2D) -> EllipseData {
        // World start/end points (only meaningful for an elliptic arc) — captured
        // BEFORE transforming so we can re-derive parametric angles afterwards.
        let isArc = e.isArc
        let startWorld = isArc ? e.ellipsePoint(e.startAngle) : .invalid
        let endWorld   = isArc ? e.ellipsePoint(e.endAngle)   : .invalid

        let newCenter = t.apply(e.center)
        // majorP is stored relative to the center, so it gets the linear part only
        // (RS_Ellipse::rotate/mirror map `center + majorP`, then subtract center;
        // for an affine that is exactly `applyLinear(majorP)`).
        let newMajorP = t.applyLinear(e.majorP)

        // For a similarity (uniform scale × rotation × optional reflection) the
        // minor/major ratio is invariant — `applyLinear` scales both axes equally.
        // (A non-uniform scale would change the ratio AND the major-axis direction;
        // that general-conic case — RS_Ellipse::scale's eigen solve — is out of
        // scope here, matching the circle/arc uniform-scale assumption.)
        let ratio = e.ratio

        var result = EllipseData(
            center: newCenter,
            majorP: newMajorP,
            ratio: ratio,
            startAngle: e.startAngle,
            endAngle: e.endAngle,
            reversed: t.isMirror ? !e.reversed : e.reversed
        )

        if isArc {
            // Recompute the parametric (ellipse) angles from the transformed world
            // endpoints, exactly as RS_Ellipse::mirror/scale do via getEllipseAngle.
            let s = t.apply(startWorld)
            let en = t.apply(endWorld)
            result.startAngle = Vector.correctAngle(ellipseAngle(of: s, center: newCenter, majorP: newMajorP, ratio: ratio))
            result.endAngle   = Vector.correctAngle(ellipseAngle(of: en, center: newCenter, majorP: newMajorP, ratio: ratio))
        }
        return result
    }

    /// Inverse of `EllipseData.ellipsePoint` — the parametric *ellipse angle* of a
    /// world point on the ellipse (`RS_Ellipse::getEllipseAngle`): translate to the
    /// center, rotate by `-majorP.angle`, scale x by `ratio`, take the angle.
    static func ellipseAngle(of pos: Vector, center: Vector, majorP: Vector, ratio: Double) -> Double {
        var m = pos - center
        m = m.rotated(by: -majorP.angle)
        return Vector(m.x * ratio, m.y).angle
    }

    // MARK: spline — transform all control points; knots/weights/degree/closed
    //       are unchanged under an affine map (a spline is affine-invariant).

    static func transformSpline(_ s: SplineData, _ t: Affine2D) -> SplineData {
        SplineData(
            degree: s.degree,
            controlPoints: s.controlPoints.map { t.apply($0) },
            knots: s.knots,
            weights: s.weights,
            closed: s.closed
        )
    }

    // MARK: splinePoints — transform the quadratic-Bézier control polygon; closed
    //       flag unchanged (affine-invariant).

    static func transformSplinePoints(_ sp: SplinePointsData, _ t: Affine2D) -> SplinePointsData {
        SplinePointsData(
            controlPoints: sp.controlPoints.map { t.apply($0) },
            closed: sp.closed
        )
    }

    // MARK: text — insertion point transforms; height *= uniformScale; rotation
    //       gains the transform's rotation (or reflects under a mirror), matching
    //       RS_Text::move/rotate/scale/mirror. Alignment fields are unchanged.

    static func transformText(_ tx: TextData, _ t: Affine2D) -> TextData {
        // Under a mirror, the baseline direction reflects across the axis: a
        // direction at angle φ maps to 2·axisAngle − φ (the same reflected-angle
        // form RS_Arc/RS_Ellipse use). Otherwise the baseline simply rotates.
        let rotation: Double = t.isMirror
            ? Vector.correctAngle(t.mirrorAxisAngle * 2 - tx.rotation)
            : Vector.correctAngle(tx.rotation + t.rotationDelta)
        return TextData(
            position: t.apply(tx.position),
            height: abs(tx.height * t.uniformScale),
            rotation: rotation,
            text: tx.text,
            styleName: tx.styleName,
            hAlign: tx.hAlign,
            vAlign: tx.vAlign,
            letterSpacingFactor: tx.letterSpacingFactor
        )
    }

    // MARK: mtext — insertion point transforms; height/rectWidth *= uniformScale;
    //       rotation gains the transform's rotation (or reflects under a mirror),
    //       matching RS_MText::move/rotate/scale/mirror. The run tree (paragraphs)
    //       + rawCode are unchanged — they are size-independent formatting.

    static func transformMText(_ mt: MTextData, _ t: Affine2D) -> MTextData {
        let rotation: Double = t.isMirror
            ? Vector.correctAngle(t.mirrorAxisAngle * 2 - mt.rotation)
            : Vector.correctAngle(mt.rotation + t.rotationDelta)
        return MTextData(
            position: t.apply(mt.position),
            height: abs(mt.height * t.uniformScale),
            rectWidth: abs(mt.rectWidth * t.uniformScale),
            rotation: rotation,
            styleName: mt.styleName,
            attachment: mt.attachment,
            lineSpacingStyle: mt.lineSpacingStyle,
            lineSpacingFactor: mt.lineSpacingFactor,
            paragraphs: mt.paragraphs,
            rawCode: mt.rawCode)
    }

    // MARK: hatch — transform every boundary-loop vertex point; bulge sign flips
    //       under a mirror (each boundary arc reverses orientation), unchanged
    //       under rotation/uniform-scale (RS_Hatch::move/rotate/scale/mirror via
    //       its boundary entities).

    static func transformHatch(_ h: HatchData, _ t: Affine2D) -> HatchData {
        let flip = t.isMirror
        let loops = h.loops.map { ring in
            ring.map { v in
                PolylineVertex(point: t.apply(v.point), bulge: flip ? -v.bulge : v.bulge)
            }
        }
        return HatchData(loops: loops, solidFill: h.solidFill, patternName: h.patternName)
    }

    // MARK: solid — transform every corner (RS_Solid::move/rotate/scale/mirror).

    static func transformSolid(_ s: SolidData, _ t: Affine2D) -> SolidData {
        SolidData(corners: s.corners.map { t.apply($0) })
    }

    // MARK: dimension — transform every defining point + the text-override point,
    //       scale the text/arrow sizes by the uniform factor, and rotate the
    //       linear-dim direction angle (or reflect it under a mirror). Mirrors
    //       RS_Dimension::move/rotate/scale/mirror, which transform the defining
    //       points and re-run update() — here update() is the PURE resolve() so we
    //       only transform the DEFINING data (ADR-001).

    static func transformDimension(_ dm: DimData, _ t: Affine2D) -> DimData {
        // Re-derive a direction angle under the transform (rotate, or reflect
        // across the mirror axis), matching RS_Arc/RS_Text angle handling.
        func mappedAngle(_ a: Double) -> Double {
            t.isMirror
                ? Vector.correctAngle(t.mirrorAxisAngle * 2 - a)
                : Vector.correctAngle(a + t.rotationDelta)
        }

        let newKind: DimKind
        switch dm.kind {
        case let .linear(e1, e2, angle):
            newKind = .linear(extension1: t.apply(e1), extension2: t.apply(e2),
                              angle: mappedAngle(angle))
        case let .aligned(e1, e2):
            newKind = .aligned(extension1: t.apply(e1), extension2: t.apply(e2))
        case let .radial(center, pointOnCircle):
            newKind = .radial(center: t.apply(center), pointOnCircle: t.apply(pointOnCircle))
        case let .diameter(p1, p2):
            newKind = .diameter(point1: t.apply(p1), point2: t.apply(p2))
        case let .angular(l1s, l1e, l2s, l2e):
            newKind = .angular(line1Start: t.apply(l1s), line1End: t.apply(l1e),
                               line2Start: t.apply(l2s), line2End: t.apply(l2e))
        }

        // An unset (nil/invalid) text-middle stays nil; a real one transforms.
        let newTextMiddle: Vector? = dm.textMiddle.flatMap { $0.valid ? t.apply($0) : nil }

        // The explicit measurement-text rotation (DXF 53) follows the same
        // angle mapping as the dimension direction (rotate, or reflect under a
        // mirror); a nil (auto) rotation stays nil.
        let newTextRotation: Double? = dm.textRotation.map(mappedAngle)

        // The extension-line oblique angle (DXF 52) also rotates / reflects.
        let newOblique = mappedAngle(dm.obliqueAngle)

        return DimData(
            kind: newKind,
            definitionPoint: t.apply(dm.definitionPoint),
            textOverride: dm.textOverride,
            textMiddle: newTextMiddle,
            styleName: dm.styleName,
            textHeight: abs(dm.textHeight * t.uniformScale),
            arrowSize: abs(dm.arrowSize * t.uniformScale),
            textRotation: newTextRotation,
            attachmentPoint: dm.attachmentPoint,
            lineSpacingStyle: dm.lineSpacingStyle,
            lineSpacingFactor: dm.lineSpacingFactor,
            obliqueAngle: newOblique
        )
    }

    // MARK: insert — the insertion point transforms; the rotation gains the
    //       transform's rotation (or reflects under a mirror); the per-axis scale
    //       is multiplied by the transform's uniform factor. Mirrors
    //       RS_Insert::move/rotate/scale/mirror, which transform the placement and
    //       re-run update() — here update() is the PURE resolve(), so we only
    //       transform the DEFINING placement (ADR-001). The block name + MINSERT
    //       array (counts + spacing, in the block's local frame) are unchanged.
    //
    //       LIMITATION (documented, matching the circle/arc note in the header): a
    //       NON-uniform scale (sx != sy) of an insert is approximated with the
    //       uniform factor on both axes. The faithful behavior would fold the
    //       transform's anisotropy into the insert's per-axis scale only when the
    //       transform has no rotation; the general anisotropic+rotated case needs a
    //       polar decomposition (out of scope). The common move/rotate/uniform-scale/
    //       mirror paths are exact.

    static func transformInsert(_ ins: InsertData, _ t: Affine2D) -> InsertData {
        // New rotation: reflect across the mirror axis, else add the rotation delta.
        let rotation: Double = t.isMirror
            ? Vector.correctAngle(t.mirrorAxisAngle * 2 - ins.rotation)
            : Vector.correctAngle(ins.rotation + t.rotationDelta)
        // Per-axis scale times the uniform factor. A mirror flips the X scale sign
        // (the reflected-angle rotation already accounts for orientation, so flipping
        // one axis reproduces the reflection of the placed geometry — matching
        // RS_Insert::mirror negating a scale factor).
        let factor = t.uniformScale
        let sx = ins.scale.x * factor * (t.isMirror ? -1 : 1)
        let sy = ins.scale.y * factor
        return InsertData(
            blockName: ins.blockName,
            insertionPoint: t.apply(ins.insertionPoint),
            scale: Vector(sx, sy, ins.scale.z),
            rotation: rotation,
            rows: ins.rows,
            cols: ins.cols,
            rowSpacing: ins.rowSpacing * factor,
            colSpacing: ins.colSpacing * factor
        )
    }
}
