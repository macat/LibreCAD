//
//  TextShaper.swift
//  CADEngine
//
//  The single text resolve entry point (text-system-design §2.4, §8.4). Both
//  `.text` and `.dimension` measurement text route through here — there is NO
//  second text path (the ADR-004-revision mandate). It:
//    1. resolves the TextStyle,
//    2. runs the special-char pre-pass (TextCodec),
//    3. splits on `\n` and shapes each line via the FontProvider,
//    4. places glyphs along the baseline with ALL 15 justification modes,
//       width-factor scale, oblique shear, line advance, rotation, and ADR-003
//       world placement,
//    5. emits native glyph outlines as `ResolvedFill`s and stroke glyphs as
//       `ResolvedPolyline`s.
//
//  Annotative: when the resolved style is annotative, the entity height is scaled
//  by `ResolveContext.annotationScale` before layout (the model + mechanism for
//  "annotative sooner" in model space).
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

public enum TextShaper {

    /// One shaped + placed line, in em space (pre-scale, pre-rotation): the
    /// glyph fills/strokes and the line's advance width + vertical metrics.
    struct ShapedLine {
        /// Native outline loops (em space), grouped per glyph (each is a full
        /// `GlyphGeometry.fills` already placed at its baseline x).
        var fillGlyphs: [[[Vector]]]
        /// Stroke polylines (em space), placed at their baseline x.
        var strokePolylines: [[Vector]]
        /// Total advance width of the line (em).
        var width: Double
    }

    /// Resolves a `TextData` into world-space `ResolvedGeometry` using the
    /// context's provider + style provider. Returns empty geometry (never a crash)
    /// when there is no provider / font or the string is empty.
    ///
    /// This is the entry point the dimension owner consumes directly (it builds a
    /// `TextData` from its dim style and calls this).
    public static func resolve(_ data: TextData, pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard data.height > 0 else { return ResolvedGeometry() }

        // 1. Resolve the style (name → TextStyle, default "Standard").
        let style = resolvedStyle(for: data, ctx: ctx)

        // Annotative: scale the entity height by the active annotation scale.
        var effectiveHeight = data.height
        if style.annotative, ctx.annotationScale > 0 {
            effectiveHeight *= ctx.annotationScale
        }

        // 2. Special-char pre-pass (shared, before shaping).
        let expanded = TextCodec.expandSpecialCharacters(data.text)
        guard !expanded.isEmpty else { return ResolvedGeometry() }

        // 3. Resolve the font through the provider (with substitution fallback).
        guard let provider = ctx.fontProvider else { return ResolvedGeometry() }
        guard let (shaped, isNative) = resolveShaper(style: style, ctx: ctx, provider: provider) else {
            return ResolvedGeometry()
        }

        // Per-entity overrides take precedence over the style (AutoCAD: entity 41/51
        // over STYLE 41/50).
        var widthFactor = data.widthFactor != 1 ? data.widthFactor
            : (style.widthFactor != 0 ? style.widthFactor : 1)
        let oblique = data.obliqueAngle != 0 ? data.obliqueAngle : style.obliqueAngle

        let metrics = shaped.metrics
        let capHeight = metrics.capHeight > 0 ? metrics.capHeight : 1
        var scale = effectiveHeight / capHeight

        // .aligned / .fit consult secondPoint to fit the run between two points.
        // .aligned: rotate to the p1→p2 direction and UNIFORMLY scale so the run
        //           fills the gap (height auto-scales). .fit: same rotation, keep
        //           the height, vary the WIDTH FACTOR so the run fills the gap.
        var fitRotation = 0.0
        let isFitMode = (data.hAlign == .aligned || data.hAlign == .fit)
        if isFitMode, let sp = data.secondPoint, sp.valid {
            let gap = sp - data.position
            let gapLen = gap.magnitude
            if gapLen > Tolerance.distance {
                fitRotation = gap.angle - data.rotation   // align baseline to the gap
                // Measure the unscaled (em, widthFactor-applied) run width first.
                let probeAttrs = RunAttributes(
                    bold: style.bold, italic: style.italic,
                    obliqueAngle: oblique, widthFactor: widthFactor)
                let probe = shapeLine(expanded.replacingOccurrences(of: "\n", with: ""),
                                      shaped: shaped, isNative: isNative,
                                      attrs: probeAttrs,
                                      tolerance: ctx.tessellationTolerance / Swift.max(scale, 1e-9))
                let runWorldWidth = probe.width * scale
                if runWorldWidth > Tolerance.distance {
                    if data.hAlign == .aligned {
                        // Scale everything (height + width) by the fit ratio.
                        scale *= gapLen / runWorldWidth
                    } else {
                        // .fit: keep height, stretch width factor only.
                        widthFactor *= gapLen / runWorldWidth
                    }
                }
            }
        }

        let attrs = RunAttributes(
            bold: style.bold, italic: style.italic,
            obliqueAngle: oblique, widthFactor: widthFactor,
            tracking: 0)
        let tolerance = (ctx.tessellationTolerance / Swift.max(scale, 1e-9))   // em-space tolerance

        // 4. Shape each line (split on \n), collecting em-space geometry.
        let lines = expanded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineGapEm = metrics.ascent + metrics.descent + metrics.lineGap   // em line advance
        let lineSpacing = lineGapEm

        var shapedLines: [ShapedLine] = []
        shapedLines.reserveCapacity(lines.count)
        for line in lines {
            shapedLines.append(shapeLine(line, shaped: shaped, isNative: isNative,
                                         attrs: attrs, tolerance: tolerance))
        }

        // Total run width across all lines (for H justification of single line; for
        // multi-line we justify each line on its own width).
        let maxWidth = shapedLines.map(\.width).max() ?? 0

        // 5. Resolve justification → the (em-space) anchor transform.
        let placement = computePlacement(
            data: data, style: style, attrs: attrs,
            metrics: metrics, scale: scale,
            lineCount: lines.count, lineSpacing: lineSpacing,
            maxWidth: maxWidth, lineWidths: shapedLines.map(\.width))

        // Emit world geometry.
        var fills: [ResolvedFill] = []
        var polylines: [ResolvedPolyline] = []
        let rotation = data.rotation + fitRotation + placement.extraRotation
        let origin = data.position

        // em → world transform for a point on line `li` placed at em x along its
        // baseline (baseline y = 0 for that line). The placement gives a per-line
        // horizontal shift `lineShiftX[li]` and a baseline y `lineBaselineY[li]`.
        func emToWorld(_ p: Vector, lineShiftX: Double, baselineY: Double) -> Vector {
            // 1) oblique shear (about the baseline): x += y * tan(oblique).
            var x = p.x
            let y = p.y
            if oblique != 0 { x += y * tan(oblique) }
            // 2) width factor (horizontal scale) is applied to the baseline x only
            //    (glyph internal x is already in the line metric); here glyphs are
            //    pre-scaled by widthFactor in shapeLine, so just place.
            // 3) line shift + baseline.
            let placed = Vector((x + lineShiftX), y + baselineY)
            // 4) uniform scale to world cap height.
            let scaled = Vector(placed.x * scale, placed.y * scale)
            // 5) rotation about origin, then translate.
            let rot = rotation != 0 ? scaled.rotated(by: rotation) : scaled
            return origin + rot
        }

        for (li, sl) in shapedLines.enumerated() {
            let shiftX = placement.lineShiftX[li]
            let baselineY = placement.lineBaselineY[li]
            // Native fills.
            for glyphLoops in sl.fillGlyphs {
                var worldLoops: [[Vector]] = []
                worldLoops.reserveCapacity(glyphLoops.count)
                for loop in glyphLoops {
                    worldLoops.append(loop.map { emToWorld($0, lineShiftX: shiftX, baselineY: baselineY) })
                }
                if !worldLoops.isEmpty {
                    fills.append(ResolvedFill(loops: worldLoops, color: pen.color))
                }
            }
            // Stroke polylines.
            for stroke in sl.strokePolylines where stroke.count >= 2 {
                let world = stroke.map { emToWorld($0, lineShiftX: shiftX, baselineY: baselineY) }
                polylines.append(ResolvedPolyline(points: world, closed: false, pen: pen))
            }
        }

        return ResolvedGeometry(polylines: polylines, fills: fills)
    }

    // MARK: - Font-aware bounding box

    /// A tight, font-metric-aware bounding box for a `TextData`, computed by
    /// resolving the actual glyph geometry and unioning its extents (§8.4 step 6).
    /// Returns `nil` when no provider/font is available so the caller can fall back
    /// to the loose metric estimate (the `boundingBox()` path has no context today).
    public static func boundingBox(_ data: TextData, ctx: ResolveContext) -> AABB? {
        guard ctx.fontProvider != nil else { return nil }
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let geo = resolve(data, pen: pen, ctx: ctx)
        guard !geo.polylines.isEmpty || !geo.fills.isEmpty else { return nil }
        var box = AABB.empty
        for pl in geo.polylines { for p in pl.points { box.expand(toInclude: p) } }
        for fill in geo.fills { for loop in fill.loops { for p in loop { box.expand(toInclude: p) } } }
        return box.isEmpty ? nil : box
    }

    // MARK: - Style resolution

    /// Resolves the entity's style name to a concrete `TextStyle` via the context's
    /// style provider, falling back to "Standard". If there is no style provider, a
    /// default style is synthesized whose font source is inferred from the name:
    /// a name that resolves as a `.lff` (via the stroke provider) stays stroke; an
    /// empty/unknown name defaults to the native default family.
    static func resolvedStyle(for data: TextData, ctx: ResolveContext) -> TextStyle {
        let name = data.styleName ?? TextStyleTable.standardName
        if let provider = ctx.textStyleProvider, let s = provider(name) {
            return s
        }
        // No style table: synthesize. The default is the native family; but a
        // legacy DXF style name that names a stroke font should still resolve to
        // strokes for fidelity. We let the resolve step probe both providers, so
        // here we pick native by default and the shaper-resolution fallback handles
        // the stroke case when native is unavailable.
        return TextStyle(name: name,
                         primaryFont: .native(family: TextStyle.defaultNativeFamily))
    }

    /// Resolves the shaper for a style, with the substitution chain
    /// (text-system-design §4.3): exact match → default native → `.lff` "standard".
    /// Returns the shaper and whether it is a native (fill) source.
    static func resolveShaper(style: TextStyle, ctx: ResolveContext,
                              provider: any FontProvider) -> (ShapedFont, Bool)? {
        // 1. Exact match for the style's primary font.
        if let s = provider.resolveFont(style.primaryFont) {
            let isNative: Bool
            if case .native = style.primaryFont { isNative = true } else { isNative = false }
            return (s, isNative)
        }
        // 2. Fall back to the default native family.
        if let s = provider.resolveFont(.native(family: TextStyle.defaultNativeFamily)) {
            return (s, true)
        }
        // 3. Last resort: the `.lff` "standard" stroke font.
        if let s = provider.resolveFont(.stroke(lff: "standard")) {
            return (s, false)
        }
        // 4. Empty-key stroke default (legacy provider wiring).
        if let s = provider.resolveFont(.stroke(lff: "")) {
            return (s, false)
        }
        return nil
    }

    // MARK: - Line shaping (em space)

    /// Shapes one line into em-space glyph geometry placed along its baseline.
    /// Native glyphs contribute fill loops; stroke glyphs contribute polylines.
    /// Width-factor scales the glyph geometry + advances horizontally.
    static func shapeLine(_ line: String, shaped: ShapedFont, isNative: Bool,
                          attrs: RunAttributes, tolerance: Double) -> ShapedLine {
        var fillGlyphs: [[[Vector]]] = []
        var strokePolylines: [[Vector]] = []
        var penX = 0.0
        let wf = attrs.widthFactor

        guard !line.isEmpty else { return ShapedLine(fillGlyphs: [], strokePolylines: [], width: 0) }

        let positioned = shaped.shape(line, attributes: attrs)
        for pg in positioned {
            let geo = shaped.glyphGeometry(pg.glyph, tolerance: tolerance)
            let gx = penX + pg.offset.x
            if isNative {
                // Group ALL loops of one glyph (outer + counters) into ONE entry,
                // so the renderer's hole-bridge cuts the counters out (the inside
                // of O / e / A is loops[1...]).
                if !geo.fills.isEmpty {
                    let glyphLoops = geo.fills.map { loop in
                        loop.map { Vector(($0.x + gx) * wf, $0.y) }
                    }
                    fillGlyphs.append(glyphLoops)
                }
            } else {
                for stroke in geo.strokes where stroke.count >= 2 {
                    strokePolylines.append(stroke.map { Vector(($0.x + gx) * wf, $0.y) })
                }
            }
            penX += pg.advance.x
        }
        return ShapedLine(fillGlyphs: fillGlyphs, strokePolylines: strokePolylines,
                          width: penX * wf)
    }

    // MARK: - Justification (all 15 modes)

    /// The placement of every line: per-line horizontal shift and baseline y (em
    /// space, pre-scale), plus an extra rotation and scale tweak for special modes.
    struct Placement {
        var lineShiftX: [Double]
        var lineBaselineY: [Double]
        var extraRotation: Double = 0
    }

    /// Computes per-line placement for all 15 AutoCAD justification modes. The
    /// modes are the product of `(hAlign × vAlign)` plus the three H-only special
    /// modes (`.aligned`, `.middle`, `.fit`) — exactly the DXF 72×73 matrix.
    ///
    /// Convention: glyphs are shaped with the line's left edge at em x = 0 and the
    /// baseline at em y = 0. We translate so the requested H×V anchor lands on the
    /// insertion point (em-space; the world scale + rotation are applied later).
    static func computePlacement(
        data: TextData, style: TextStyle, attrs: RunAttributes,
        metrics: FontMetrics, scale: Double,
        lineCount: Int, lineSpacing: Double,
        maxWidth: Double, lineWidths: [Double]
    ) -> Placement {
        let ascent = metrics.ascent
        let descent = metrics.descent
        let capHeight = metrics.capHeight > 0 ? metrics.capHeight : ascent

        // Multi-line: lines stack downward from the first. Baseline y of line i is
        // -i * lineSpacing (first line baseline at 0).
        let count = Swift.max(lineCount, 1)
        var baselineY = [Double](repeating: 0, count: count)
        for i in 0..<count { baselineY[i] = -Double(i) * lineSpacing }

        // The full block's vertical extent for V justification (top of first line
        // cap to bottom of last line descent).
        let blockTop = capHeight                                   // first line cap top
        let blockBottom = baselineY.last! - descent                // last line descender

        let hMode = data.hAlign

        // Vertical anchor offset (em): translate the block so the requested V
        // anchor sits at y = 0. The `.middle` H-mode (DXF HAMiddle) centers BOTH
        // H and V on the point — overriding vAlign with a geometric middle.
        let vShift: Double
        if hMode == .middle {
            vShift = -(blockTop + blockBottom) / 2
        } else {
            switch data.vAlign {
            case .baseline: vShift = 0                                  // first-line baseline at 0
            case .bottom:   vShift = -blockBottom                       // descender bottom at 0
            case .middle:   vShift = -(blockTop + blockBottom) / 2      // block center at 0
            case .top:      vShift = -blockTop                          // cap top at 0
            }
        }
        // Apply the vertical anchor to every line's baseline.
        for i in 0..<count { baselineY[i] += vShift }

        // Horizontal anchor per line.
        var shiftX = [Double](repeating: 0, count: count)
        func hShift(forWidth w: Double) -> Double {
            switch hMode {
            case .left:    return 0
            case .center:  return -w / 2
            case .right:   return -w
            case .middle:  return -w / 2          // middle centers H too
            case .aligned: return 0               // run starts at position, runs to secondPoint
            case .fit:     return 0               // run starts at position, runs to secondPoint
            }
        }
        for i in 0..<count {
            let w = i < lineWidths.count ? lineWidths[i] : maxWidth
            shiftX[i] = hShift(forWidth: w)
        }

        // Backward / upside-down generation flags (mirror) are reserved on the
        // model; mirroring is a transform refinement (Phase 2 UI) — the field
        // round-trips. (No-op here.)
        return Placement(lineShiftX: shiftX, lineBaselineY: baselineY, extraRotation: 0)
    }
}
