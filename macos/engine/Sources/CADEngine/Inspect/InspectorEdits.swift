//
//  InspectorEdits.swift
//  CADEngine
//
//  PURE value transforms backing the macOS Inspector panel's property editors.
//  The Inspector lets the user edit a selected entity's defining data (line
//  endpoints, circle center/radius, arc angles, text height/justification, the
//  font/style of a TEXT/MTEXT entity, …). Each edit must produce a NEW
//  `EntityKind` (or a `TextStyle` for the font system) so the app can apply it
//  via the existing undoable `.replace` commit path (ADR-002) — the GUI never
//  mutates the drawing directly.
//
//  Keeping the transforms here (pure, in the engine) — NOT inline in the SwiftUI
//  view — makes them unit-testable WITHOUT a GUI (parallel to EntityTransform.swift
//  / the Tools), and keeps the view a thin shell over tested value math. The view
//  builds drafts, calls these builders, and hands the result to
//  `CanvasModel.applyInspectorEdits`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// Pure builders that turn an edited inspector field into a new `EntityKind` (or
/// the font-system `TextStyle`) the app then applies via `.replace`. Static
/// members of a namespaced `enum` (CONVENTIONS.md: no module-scope free funcs).
public enum InspectorEdits {

    // MARK: - Geometry field edits (one defining field → new EntityKind)

    /// Replaces a `.line`'s start point, keeping its end. No-op for other kinds.
    public static func setLineStart(_ kind: EntityKind, _ start: Vector) -> EntityKind {
        guard case .line(var d) = kind else { return kind }
        d.start = start
        return .line(d)
    }

    /// Replaces a `.line`'s end point, keeping its start.
    public static func setLineEnd(_ kind: EntityKind, _ end: Vector) -> EntityKind {
        guard case .line(var d) = kind else { return kind }
        d.end = end
        return .line(d)
    }

    /// Replaces a `.circle`'s center, keeping its radius.
    public static func setCircleCenter(_ kind: EntityKind, _ center: Vector) -> EntityKind {
        guard case .circle(var d) = kind else { return kind }
        d.center = center
        return .circle(d)
    }

    /// Replaces a `.circle`'s radius (clamped non-negative), keeping its center.
    public static func setCircleRadius(_ kind: EntityKind, _ radius: Double) -> EntityKind {
        guard case .circle(var d) = kind else { return kind }
        d.radius = Swift.max(0, radius)
        return .circle(d)
    }

    /// Replaces an `.arc`'s center, keeping radius + angles.
    public static func setArcCenter(_ kind: EntityKind, _ center: Vector) -> EntityKind {
        guard case .arc(var d) = kind else { return kind }
        d.center = center
        return .arc(d)
    }

    /// Replaces an `.arc`'s radius (clamped non-negative).
    public static func setArcRadius(_ kind: EntityKind, _ radius: Double) -> EntityKind {
        guard case .arc(var d) = kind else { return kind }
        d.radius = Swift.max(0, radius)
        return .arc(d)
    }

    /// Replaces an `.arc`'s start angle (radians).
    public static func setArcStartAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .arc(var d) = kind else { return kind }
        d.startAngle = angle
        return .arc(d)
    }

    /// Replaces an `.arc`'s end angle (radians).
    public static func setArcEndAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .arc(var d) = kind else { return kind }
        d.endAngle = angle
        return .arc(d)
    }

    /// Replaces a `.point`'s position.
    public static func setPointPosition(_ kind: EntityKind, _ position: Vector) -> EntityKind {
        guard case .point = kind else { return kind }
        return .point(PointData(position: position))
    }

    // MARK: - Ellipse field edits (RS_Ellipse, DXF ELLIPSE)

    /// Replaces an `.ellipse`'s center, keeping its axes + angles. No-op otherwise.
    public static func setEllipseCenter(_ kind: EntityKind, _ center: Vector) -> EntityKind {
        guard case .ellipse(var d) = kind else { return kind }
        d.center = center
        return .ellipse(d)
    }

    /// Replaces an `.ellipse`'s major-axis endpoint (relative to center) — this sets
    /// both the major radius (its magnitude) and the ellipse rotation (its angle).
    public static func setEllipseMajor(_ kind: EntityKind, _ major: Vector) -> EntityKind {
        guard case .ellipse(var d) = kind else { return kind }
        d.majorP = major
        return .ellipse(d)
    }

    /// Replaces an `.ellipse`'s minor/major ratio (clamped to a small positive
    /// minimum so the ellipse never collapses to a degenerate line).
    public static func setEllipseRatio(_ kind: EntityKind, _ ratio: Double) -> EntityKind {
        guard case .ellipse(var d) = kind else { return kind }
        d.ratio = Swift.max(minEllipseRatio, ratio)
        return .ellipse(d)
    }

    /// Replaces an `.ellipse`'s start ellipse-angle (radians, parametric).
    public static func setEllipseStartAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .ellipse(var d) = kind else { return kind }
        d.startAngle = angle
        return .ellipse(d)
    }

    /// Replaces an `.ellipse`'s end ellipse-angle (radians, parametric).
    public static func setEllipseEndAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .ellipse(var d) = kind else { return kind }
        d.endAngle = angle
        return .ellipse(d)
    }

    // MARK: - Spline field edits (RS_Spline, DXF SPLINE)

    /// Sets/clears a `.spline`'s closed (periodic) flag, keeping degree + points.
    public static func setSplineClosed(_ kind: EntityKind, _ closed: Bool) -> EntityKind {
        guard case .spline(var d) = kind else { return kind }
        d.closed = closed
        return .spline(d)
    }

    /// Replaces a `.spline`'s degree (clamped to LibreCAD's 1–3 range), keeping the
    /// control polygon. (Degree must be ≤ controlPoints − 1 to evaluate, but the
    /// resolve clamps that on demand, so the inspector keeps this light.)
    public static func setSplineDegree(_ kind: EntityKind, _ degree: Int) -> EntityKind {
        guard case .spline(var d) = kind else { return kind }
        d.degree = Swift.max(1, Swift.min(3, degree))
        return .spline(d)
    }

    /// Replaces a single `.spline` control point by index, keeping the rest. An
    /// out-of-range index is a no-op.
    public static func setSplineControlPoint(_ kind: EntityKind, index: Int, _ point: Vector) -> EntityKind {
        guard case .spline(var d) = kind, d.controlPoints.indices.contains(index) else { return kind }
        d.controlPoints[index] = point
        return .spline(d)
    }

    // MARK: - SplinePoints field edits (LC_SplinePoints)

    /// Sets/clears a `.splinePoints`'s closed flag, keeping its control polygon.
    public static func setSplinePointsClosed(_ kind: EntityKind, _ closed: Bool) -> EntityKind {
        guard case .splinePoints(var d) = kind else { return kind }
        d.closed = closed
        return .splinePoints(d)
    }

    /// Replaces a single `.splinePoints` control point by index, keeping the rest.
    /// An out-of-range index is a no-op.
    public static func setSplinePointsControlPoint(_ kind: EntityKind, index: Int, _ point: Vector) -> EntityKind {
        guard case .splinePoints(var d) = kind, d.controlPoints.indices.contains(index) else { return kind }
        d.controlPoints[index] = point
        return .splinePoints(d)
    }

    // MARK: - Polyline field edits (RS_Polyline, DXF LWPOLYLINE)

    /// Sets/clears a `.polyline`'s closed flag, keeping its vertices. (Per-vertex
    /// editing lives in `PolylineEditTool`; the inspector keeps this light.)
    public static func setPolylineClosed(_ kind: EntityKind, _ closed: Bool) -> EntityKind {
        guard case .polyline(var d) = kind else { return kind }
        d.closed = closed
        return .polyline(d)
    }

    /// Replaces a single `.polyline` vertex POINT by index (keeping its bulge). An
    /// out-of-range index is a no-op.
    public static func setPolylineVertex(_ kind: EntityKind, index: Int, _ point: Vector) -> EntityKind {
        guard case .polyline(var d) = kind, d.vertices.indices.contains(index) else { return kind }
        d.vertices[index].point = point
        return .polyline(d)
    }

    // MARK: - Hatch field edits (RS_Hatch, DXF HATCH)

    /// Replaces a `.hatch`'s pattern name (DXF code 2), keeping its loops + fill
    /// flags. An empty/`"SOLID"` name resolves as a solid fill at resolve time.
    public static func setHatchPatternName(_ kind: EntityKind, _ name: String?) -> EntityKind {
        guard case .hatch(var d) = kind else { return kind }
        d.patternName = name
        return .hatch(d)
    }

    /// Replaces a `.hatch`'s pattern scale (DXF code 41, clamped positive). `1` is
    /// the `.pat` definition's native scale.
    public static func setHatchPatternScale(_ kind: EntityKind, _ scale: Double) -> EntityKind {
        guard case .hatch(var d) = kind else { return kind }
        d.patternScale = Swift.max(minHatchScale, scale)
        return .hatch(d)
    }

    /// Replaces a `.hatch`'s extra pattern rotation (DXF code 52, radians).
    public static func setHatchPatternAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .hatch(var d) = kind else { return kind }
        d.patternAngle = angle
        return .hatch(d)
    }

    /// Sets/clears a `.hatch`'s solid-fill flag (a `false` value means a pattern
    /// fill).
    public static func setHatchSolidFill(_ kind: EntityKind, _ solid: Bool) -> EntityKind {
        guard case .hatch(var d) = kind else { return kind }
        d.solidFill = solid
        return .hatch(d)
    }

    // MARK: - Solid field edits (RS_Solid, DXF SOLID/TRACE)

    /// Replaces a single `.solid` corner POINT by index, keeping the rest. An
    /// out-of-range index is a no-op (the corner count is fixed at 3 or 4).
    public static func setSolidCorner(_ kind: EntityKind, index: Int, _ point: Vector) -> EntityKind {
        guard case .solid(var d) = kind, d.corners.indices.contains(index) else { return kind }
        d.corners[index] = point
        return .solid(d)
    }

    // MARK: - Dimension field edits (RS_Dimension family, DXF DIMENSION)

    /// Replaces a `.dimension`'s dimension-line definition point (DXF code 10),
    /// keeping its variant + style. (A re-measure happens on resolve.)
    public static func setDimDefinitionPoint(_ kind: EntityKind, _ point: Vector) -> EntityKind {
        guard case .dimension(var d) = kind else { return kind }
        d.definitionPoint = point
        return .dimension(d)
    }

    /// Points a `.dimension` at a named DIMSTYLE (DXF code 3), keeping the rest.
    public static func setDimStyleName(_ kind: EntityKind, _ styleName: String?) -> EntityKind {
        guard case .dimension(var d) = kind else { return kind }
        d.styleName = styleName
        return .dimension(d)
    }

    /// Replaces a `.dimension`'s explicit text override (DXF code 1). An empty
    /// string is normalized to `nil` so the dimension shows the measured value.
    public static func setDimTextOverride(_ kind: EntityKind, _ text: String) -> EntityKind {
        guard case .dimension(var d) = kind else { return kind }
        d.textOverride = text.isEmpty ? nil : text
        return .dimension(d)
    }

    /// Moves a `.dimension`'s text middle point (DXF code 11) — the explicit
    /// override for where the measurement text is centered. Passing `nil` clears
    /// the override so the resolve recenters the text on the dimension line.
    public static func setDimTextMiddle(_ kind: EntityKind, _ point: Vector?) -> EntityKind {
        guard case .dimension(var d) = kind else { return kind }
        d.textMiddle = point
        return .dimension(d)
    }

    /// Sets a `.dimension`'s explicit measurement-text rotation (DXF code 53,
    /// radians), independent of the dimension-line angle. Passing `nil` clears the
    /// override so the resolve derives the upright baseline angle from the geometry.
    public static func setDimTextRotation(_ kind: EntityKind, _ rotation: Double?) -> EntityKind {
        guard case .dimension(var d) = kind else { return kind }
        d.textRotation = rotation
        return .dimension(d)
    }

    /// Sets a `.dimension`'s extension-line oblique (slant) angle (DXF code 52,
    /// radians) for linear/aligned dimensions. `0` ⇒ perpendicular extension lines.
    public static func setDimOblique(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .dimension(var d) = kind else { return kind }
        d.obliqueAngle = angle
        return .dimension(d)
    }

    // MARK: - Insert / block-reference field edits (RS_Insert, DXF INSERT)

    /// Replaces an `.insert`'s insertion (placement) point (DXF code 10).
    public static func setInsertPosition(_ kind: EntityKind, _ point: Vector) -> EntityKind {
        guard case .insert(var d) = kind else { return kind }
        d.insertionPoint = point
        return .insert(d)
    }

    /// Replaces an `.insert`'s X scale factor (DXF code 41), keeping Y/Z + rotation.
    /// A zero factor is ignored (a degenerate, invisible block).
    public static func setInsertScaleX(_ kind: EntityKind, _ x: Double) -> EntityKind {
        guard case .insert(var d) = kind, abs(x) > Tolerance.distance else { return kind }
        d.scale = Vector(x, d.scale.y, d.scale.z)
        return .insert(d)
    }

    /// Replaces an `.insert`'s Y scale factor (DXF code 42), keeping X/Z + rotation.
    /// A zero factor is ignored.
    public static func setInsertScaleY(_ kind: EntityKind, _ y: Double) -> EntityKind {
        guard case .insert(var d) = kind, abs(y) > Tolerance.distance else { return kind }
        d.scale = Vector(d.scale.x, y, d.scale.z)
        return .insert(d)
    }

    /// Replaces an `.insert`'s rotation (DXF code 50, radians).
    public static func setInsertRotation(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .insert(var d) = kind else { return kind }
        d.rotation = angle
        return .insert(d)
    }

    // MARK: - Construction-line field edits (xline / ray, RS_ConstructionLine)

    /// Replaces an `.xline`'s base point, keeping its direction. No-op otherwise.
    public static func setXLineBase(_ kind: EntityKind, _ base: Vector) -> EntityKind {
        guard case .xline(var d) = kind else { return kind }
        d.base = base
        return .xline(d)
    }

    /// Replaces an `.xline`'s direction vector, keeping its base. A zero/invalid
    /// direction is ignored (the line would have no orientation).
    public static func setXLineDirection(_ kind: EntityKind, _ direction: Vector) -> EntityKind {
        guard case .xline(var d) = kind else { return kind }
        guard direction.valid, direction.magnitude > Tolerance.distance else { return kind }
        d.direction = direction
        return .xline(d)
    }

    /// Replaces an `.xline`'s direction by ANGLE (radians), keeping its base. The
    /// direction is rebuilt as a unit vector at `angle` (the Inspector's common
    /// "set the construction-line angle" affordance).
    public static func setXLineAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .xline(var d) = kind else { return kind }
        d.direction = Vector(angle: angle)
        return .xline(d)
    }

    /// Replaces a `.ray`'s base (start) point, keeping its direction.
    public static func setRayBase(_ kind: EntityKind, _ base: Vector) -> EntityKind {
        guard case .ray(var d) = kind else { return kind }
        d.base = base
        return .ray(d)
    }

    /// Replaces a `.ray`'s direction vector, keeping its base. A zero/invalid
    /// direction is ignored.
    public static func setRayDirection(_ kind: EntityKind, _ direction: Vector) -> EntityKind {
        guard case .ray(var d) = kind else { return kind }
        guard direction.valid, direction.magnitude > Tolerance.distance else { return kind }
        d.direction = direction
        return .ray(d)
    }

    /// Replaces a `.ray`'s direction by ANGLE (radians), keeping its base.
    public static func setRayAngle(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .ray(var d) = kind else { return kind }
        d.direction = Vector(angle: angle)
        return .ray(d)
    }

    // MARK: - Leader field edits (RS_Leader, DXF LEADER)

    /// Replaces a `.leader`'s arrow size (clamped non-negative), keeping its path +
    /// annotation. No-op for other kinds.
    public static func setLeaderArrowSize(_ kind: EntityKind, _ size: Double) -> EntityKind {
        guard case .leader(var d) = kind else { return kind }
        d.arrowSize = Swift.max(0, size)
        return .leader(d)
    }

    /// Sets/clears whether a `.leader` draws an arrowhead at its first vertex.
    public static func setLeaderHasArrow(_ kind: EntityKind, _ on: Bool) -> EntityKind {
        guard case .leader(var d) = kind else { return kind }
        d.hasArrow = on
        return .leader(d)
    }

    /// Replaces a `.leader`'s entire vertex path, keeping its arrow + annotation.
    /// (The Inspector's "edit leader points" affordance; the path may be empty.)
    public static func setLeaderVertices(_ kind: EntityKind, _ vertices: [Vector]) -> EntityKind {
        guard case .leader(var d) = kind else { return kind }
        d.vertices = vertices
        return .leader(d)
    }

    /// Points a `.leader` at a named dimension style (DXF code 3), keeping the rest.
    public static func setLeaderStyleName(_ kind: EntityKind, _ styleName: String?) -> EntityKind {
        guard case .leader(var d) = kind else { return kind }
        d.styleName = styleName
        return .leader(d)
    }

    /// The plain text of a `.leader`'s attached annotation (its `.text` string or its
    /// `.mtext` plain text), for seeding the inline editor. Empty for a bare leader
    /// (no annotation) or a non-leader kind.
    public static func leaderText(_ kind: EntityKind) -> String {
        guard case .leader(let d) = kind, let annotation = d.annotation else { return "" }
        switch annotation {
        case .text(let t):  return t.text
        case .mtext:        return mtextPlainText(annotation)
        default:            return ""
        }
    }

    /// Sets a `.leader`'s annotation text. If the leader already carries a `.text`/
    /// `.mtext` annotation, its string is replaced (its placement/height kept);
    /// otherwise a fresh single-line `.text` annotation is created at the leader's
    /// LAST vertex (the DXF anchor) with a default height. An empty string CLEARS
    /// the annotation back to a bare leader.
    public static func setLeaderText(_ kind: EntityKind, _ text: String) -> EntityKind {
        guard case .leader(var d) = kind else { return kind }
        if text.isEmpty {
            d.annotation = nil
            return .leader(d)
        }
        switch d.annotation {
        case .text:
            d.annotation = setTextString(d.annotation!, text)
        case .mtext:
            d.annotation = setMTextPlainText(d.annotation!, text)
        default:
            let anchor = d.vertices.last ?? Vector(0, 0)
            d.annotation = .text(TextData(position: anchor, height: 2.5, text: text))
        }
        return .leader(d)
    }

    // MARK: - Image field edits (RS_Image, DXF IMAGE)

    /// Replaces an `.image`'s insertion (lower-left) corner, keeping its u/v +
    /// definition + display (so the picture moves but keeps its size/rotation).
    public static func setImageInsertion(_ kind: EntityKind, _ insertion: Vector) -> EntityKind {
        guard case .image(var d) = kind else { return kind }
        d.insertion = insertion
        return .image(d)
    }

    /// Sets an `.image`'s WIDTH (the bottom-edge world length) by rescaling its
    /// per-pixel u vector to match, keeping the rotation + the height aspect. A
    /// non-positive width is ignored (an image can't have zero width).
    public static func setImageWidth(_ kind: EntityKind, _ width: Double) -> EntityKind {
        guard case .image(var d) = kind, width > Tolerance.distance else { return kind }
        let curLen = d.uVector.magnitude
        guard curLen > Tolerance.distance else { return kind }
        // Per-pixel u must produce |u|·pixelWidth == width.
        let pw = d.imageDef.pixelWidth > 0 ? d.imageDef.pixelWidth : 1
        let scale = (width / pw) / curLen
        d.uVector = d.uVector * scale
        return .image(d)
    }

    /// Sets an `.image`'s HEIGHT (the left-edge world length) by rescaling its
    /// per-pixel v vector, keeping the rotation. Non-positive height is ignored.
    public static func setImageHeight(_ kind: EntityKind, _ height: Double) -> EntityKind {
        guard case .image(var d) = kind, height > Tolerance.distance else { return kind }
        let curLen = d.vVector.magnitude
        guard curLen > Tolerance.distance else { return kind }
        let ph = d.imageDef.pixelHeight > 0 ? d.imageDef.pixelHeight : 1
        let scale = (height / ph) / curLen
        d.vVector = d.vVector * scale
        return .image(d)
    }

    /// Sets an `.image`'s ROTATION (radians): re-aims the bottom edge to `angle`
    /// while keeping the width, and rotates the left edge to stay perpendicular
    /// (keeping the height). Mirrors the placement gesture's right-angle u/v.
    public static func setImageRotation(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .image(var d) = kind else { return kind }
        let uLen = d.uVector.magnitude
        let vLen = d.vVector.magnitude
        guard uLen > Tolerance.distance else { return kind }
        d.uVector = Vector(angle: angle) * uLen
        d.vVector = Vector(angle: angle + Double.pi / 2) * vLen
        return .image(d)
    }

    /// Sets an `.image`'s fade (DXF 283, clamped 0–100), keeping the rest.
    public static func setImageFade(_ kind: EntityKind, _ fade: Int) -> EntityKind {
        guard case .image(var d) = kind else { return kind }
        d.display.fade = Swift.max(0, Swift.min(100, fade))
        return .image(d)
    }

    /// Sets an `.image`'s brightness (DXF 281, clamped 0–100), keeping the rest.
    public static func setImageBrightness(_ kind: EntityKind, _ brightness: Int) -> EntityKind {
        guard case .image(var d) = kind else { return kind }
        d.display.brightness = Swift.max(0, Swift.min(100, brightness))
        return .image(d)
    }

    /// Sets an `.image`'s contrast (DXF 282, clamped 0–100), keeping the rest.
    public static func setImageContrast(_ kind: EntityKind, _ contrast: Int) -> EntityKind {
        guard case .image(var d) = kind else { return kind }
        d.display.contrast = Swift.max(0, Swift.min(100, contrast))
        return .image(d)
    }

    /// Sets/clears an `.image`'s show-image display flag (the texture draws when on;
    /// off shows only the frame placeholder).
    public static func setImageShow(_ kind: EntityKind, _ on: Bool) -> EntityKind {
        guard case .image(var d) = kind else { return kind }
        d.display.showImage = on
        return .image(d)
    }

    // MARK: - Text field edits (TEXT / single-line, RS_TextData)

    /// Replaces a `.text`'s insertion point.
    public static func setTextPosition(_ kind: EntityKind, _ position: Vector) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.position = position
        return .text(d)
    }

    /// Replaces a `.text`'s cap height (clamped to a small positive minimum so the
    /// glyphs never collapse to zero).
    public static func setTextHeight(_ kind: EntityKind, _ height: Double) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.height = Swift.max(minTextHeight, height)
        return .text(d)
    }

    /// Replaces a `.text`'s baseline rotation (radians).
    public static func setTextRotation(_ kind: EntityKind, _ rotation: Double) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.rotation = rotation
        return .text(d)
    }

    /// Replaces a `.text`'s string.
    public static func setTextString(_ kind: EntityKind, _ text: String) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.text = text
        return .text(d)
    }

    /// Replaces a `.text`'s horizontal justification.
    public static func setTextHAlign(_ kind: EntityKind, _ hAlign: TextHAlign) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.hAlign = hAlign
        return .text(d)
    }

    /// Replaces a `.text`'s vertical justification.
    public static func setTextVAlign(_ kind: EntityKind, _ vAlign: TextVAlign) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.vAlign = vAlign
        return .text(d)
    }

    /// Replaces a `.text`'s per-entity width factor (DXF 41; clamped positive).
    public static func setTextWidthFactor(_ kind: EntityKind, _ factor: Double) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.widthFactor = Swift.max(minWidthFactor, factor)
        return .text(d)
    }

    /// Replaces a `.text`'s per-entity oblique (slant) angle (DXF 51, radians).
    public static func setTextOblique(_ kind: EntityKind, _ angle: Double) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.obliqueAngle = angle
        return .text(d)
    }

    /// Sets/clears a `.text`'s backward (X-mirror) generation flag.
    public static func setTextBackward(_ kind: EntityKind, _ on: Bool) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        if on { d.generation.insert(.backward) } else { d.generation.remove(.backward) }
        return .text(d)
    }

    /// Sets/clears a `.text`'s upside-down (Y-mirror) generation flag.
    public static func setTextUpsideDown(_ kind: EntityKind, _ on: Bool) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        if on { d.generation.insert(.upsideDown) } else { d.generation.remove(.upsideDown) }
        return .text(d)
    }

    /// Points a `.text` at a named text style (DXF code 7). `nil`/"Standard" falls
    /// back to the default font at resolve time.
    public static func setTextStyleName(_ kind: EntityKind, _ styleName: String?) -> EntityKind {
        guard case .text(var d) = kind else { return kind }
        d.styleName = styleName
        return .text(d)
    }

    // MARK: - MTEXT field edits (RS_MTextData)

    /// Replaces an `.mtext`'s insertion point.
    public static func setMTextPosition(_ kind: EntityKind, _ position: Vector) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.position = position
        return .mtext(d)
    }

    /// Replaces an `.mtext`'s default cap height (clamped positive).
    public static func setMTextHeight(_ kind: EntityKind, _ height: Double) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.height = Swift.max(minTextHeight, height)
        return .mtext(d)
    }

    /// Replaces an `.mtext`'s wrap reference width (DXF 41; clamped non-negative,
    /// `0` ⇒ no wrap).
    public static func setMTextRectWidth(_ kind: EntityKind, _ width: Double) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.rectWidth = Swift.max(0, width)
        return .mtext(d)
    }

    /// Replaces an `.mtext`'s rotation (radians).
    public static func setMTextRotation(_ kind: EntityKind, _ rotation: Double) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.rotation = rotation
        return .mtext(d)
    }

    /// Replaces an `.mtext`'s attachment point (block-level justification).
    public static func setMTextAttachment(_ kind: EntityKind, _ attachment: MTextAttachment) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.attachment = attachment
        return .mtext(d)
    }

    /// Replaces an `.mtext`'s line-spacing factor (DXF 44; clamped positive).
    public static func setMTextLineSpacingFactor(_ kind: EntityKind, _ factor: Double) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.lineSpacingFactor = Swift.max(0.01, factor)
        return .mtext(d)
    }

    /// Points an `.mtext` at a named text style (the block-level default font).
    public static func setMTextStyleName(_ kind: EntityKind, _ styleName: String?) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        d.styleName = styleName
        return .mtext(d)
    }

    /// Replaces an `.mtext`'s body with a SINGLE plain run carrying `text`,
    /// dropping rich per-run formatting (the inline editor is plain-text only — the
    /// full run-tree editor is backlog). Clears `rawCode` so the writer re-emits
    /// from the edited paragraphs rather than the stale verbatim code.
    public static func setMTextPlainText(_ kind: EntityKind, _ text: String) -> EntityKind {
        guard case .mtext(var d) = kind else { return kind }
        // Split on hard breaks into paragraphs, each a single un-formatted run.
        let lines = text.components(separatedBy: "\n")
        d.paragraphs = lines.map { line in
            MTextParagraph(inlines: [.run(TextRun(text: line))])
        }
        d.rawCode = nil
        return .mtext(d)
    }

    /// The concatenated plain text of an `.mtext` body (paragraph runs joined by
    /// `\n`), for seeding the inline plain-text editor. Empty for non-mtext kinds.
    public static func mtextPlainText(_ kind: EntityKind) -> String {
        guard case .mtext(let d) = kind else { return "" }
        return d.paragraphs.map { para in
            para.inlines.map { inline -> String in
                switch inline {
                case .run(let r):     return r.text
                case .stacked(let s): return "\(s.upper)/\(s.lower)"
                case .tab:            return "\t"
                }
            }.joined()
        }.joined(separator: "\n")
    }

    // MARK: - Font / style derivation (the font-system payoff)

    /// A canonical text style for a chosen font + bold/italic, with a STABLE,
    /// content-derived NAME so repeated picks of the same combination reuse ONE
    /// table slot (the `TextStyleTable.upsert` key is the name). The app upserts
    /// this into the document's STYLE table and points the entity's `styleName` at
    /// `style.name` — bold/italic then render through `CompositeFontProvider`'s
    /// trait forwarding (TextShaper reads `style.bold`/`.italic`).
    ///
    /// - `font`: the glyph source (a native family or a `.lff` stroke base name).
    /// - `bold`/`italic`: face traits (honored for `.native`; carried for round-trip
    ///   on stroke/SHX, which ignore traits at resolve time).
    public static func derivedTextStyle(font: FontSource, bold: Bool, italic: Bool) -> TextStyle {
        TextStyle(
            name: styleName(for: font, bold: bold, italic: italic),
            primaryFont: font,
            bold: bold,
            italic: italic
        )
    }

    /// The canonical STYLE-table name for a font + traits, e.g.
    /// `"Helvetica Neue"`, `"Helvetica Neue Bold Italic"`, `"Stroke:standard"`.
    /// Deterministic so the same pick reuses the same slot rather than spawning a
    /// new style every edit.
    public static func styleName(for font: FontSource, bold: Bool, italic: Bool) -> String {
        let base: String
        switch font {
        case .native(let family): base = family
        case .stroke(let lff):    base = "Stroke:\(lff)"
        case .shx(let file):      base = "Shx:\(file)"
        }
        var name = base
        if bold { name += " Bold" }
        if italic { name += " Italic" }
        return name
    }

    // MARK: - Tool config derivation (parameterized tools' options)

    /// Builds an `ArrayTool.Config` from the inspector's array-options fields.
    /// `polar == false` ⇒ a rectangular grid (`rows` × `cols` stepped by
    /// `(spacingX, spacingY)`); `polar == true` ⇒ a ring of `count` positions over
    /// `totalAngle` radians (the center is picked on the canvas, hence `nil`).
    /// Counts are clamped to at least 1 so the tool always has a usable layout.
    public static func arrayConfig(
        polar: Bool,
        rows: Int, cols: Int, spacingX: Double, spacingY: Double,
        count: Int, totalAngle: Double, rotateItems: Bool
    ) -> ArrayTool.Config {
        if polar {
            return .polar(
                count: Swift.max(2, count),
                center: nil,
                totalAngle: totalAngle,
                rotateItems: rotateItems
            )
        }
        return .rectangular(
            rows: Swift.max(1, rows),
            cols: Swift.max(1, cols),
            spacing: Vector(spacingX, spacingY)
        )
    }

    // MARK: - Clamps

    /// The smallest cap height an inspector edit will write (avoids a zero-height
    /// text that resolves to nothing).
    public static let minTextHeight = 0.01
    /// The smallest width factor an inspector edit will write.
    public static let minWidthFactor = 0.01
    /// The smallest minor/major ratio an inspector edit will write (avoids an
    /// ellipse collapsing to a degenerate line).
    public static let minEllipseRatio = 0.001
    /// The smallest hatch pattern scale an inspector edit will write (a non-positive
    /// scale would collapse the pattern; mirrors the HatchData decode clamp).
    public static let minHatchScale = 0.001
}
