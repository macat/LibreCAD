//
//  MTextShaper.swift
//  CADEngine
//
//  Rich-MTEXT layout + resolve (text-system-design §1.3, §3, Phase 2). Turns an
//  `MTextData` run tree into world-space `ResolvedGeometry`:
//    - each run is shaped through the SAME `FontProvider`/`ShapedFont` path the
//      single-line `TextShaper` uses (no second text-rendering path) with the
//      run's own font / height / bold / italic / colour / tracking / oblique;
//    - runs flow into lines with WORD WRAPPING to `MTextData.rectWidth`
//      (rectWidth == 0 ⇒ no wrap; only explicit `\P` paragraph breaks split);
//    - lines stack downward with the MTEXT line spacing (factor × style);
//    - the whole block is positioned by its ATTACHMENT POINT (the 9 TL…BR modes);
//    - native glyphs become `ResolvedFill`s (per containment group, as `.text`),
//      stroke glyphs become `ResolvedPolyline`s, both coloured by the run's colour
//      (falling back to the entity pen colour);
//    - underline / overline / strikethrough are `ResolvedPolyline` strokes;
//    - stacked fractions draw numerator/denominator at reduced height with a
//      divider bar (`/` and `#`) or stacked with no bar (`^` tolerance).
//
//  All layout is done in a LOCAL frame (block origin at 0, +x baseline right, +y
//  up, first line's cap top region near 0), then transformed by rotation +
//  insertion point at the end (ADR-003 world placement).
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

public enum MTextShaper {

    // MARK: - Public entry

    /// Resolves an `MTextData` into world-space `ResolvedGeometry`. Returns empty
    /// geometry (never a crash) when there is no provider / font or no content.
    public static func resolve(_ data: MTextData, pen: ResolvedPen, ctx: ResolveContext) -> ResolvedGeometry {
        guard data.height > 0 else { return ResolvedGeometry() }
        guard let provider = ctx.fontProvider else { return ResolvedGeometry() }

        // Resolve the block's base style (font source / bold / italic defaults).
        let baseStyle = resolvedStyle(for: data, ctx: ctx)

        // Annotative base height (matches single-line TextShaper).
        var baseHeight = data.height
        if baseStyle.annotative, ctx.annotationScale > 0 {
            baseHeight *= ctx.annotationScale
        }

        // 1. Lay out each paragraph into lines (with word wrapping), producing the
        //    local-frame placed geometry per line.
        var lines: [LaidLine] = []
        let wrapWidth = data.rectWidth > 0 ? data.rectWidth : Double.greatestFiniteMagnitude
        for paragraph in data.paragraphs {
            let paraLines = layoutParagraph(
                paragraph, data: data, baseStyle: baseStyle, baseHeight: baseHeight,
                wrapWidth: wrapWidth, pen: pen, provider: provider, ctx: ctx)
            // An empty paragraph still contributes a blank line (so \P\P leaves a
            // gap), with the base line height.
            if paraLines.isEmpty {
                lines.append(LaidLine(segments: [], width: 0,
                                      ascent: baseHeight, descent: baseHeight * 0.25,
                                      align: paragraph.alignment))
            } else {
                lines.append(contentsOf: paraLines)
            }
        }
        guard !lines.isEmpty else { return ResolvedGeometry() }

        // 2. Stack the lines vertically and compute the block bounds. The first
        //    line's baseline is the reference; each subsequent line drops by the
        //    line advance (max ascent+descent of the pair × spacing factor).
        let spacing = data.lineSpacingFactor > 0 ? data.lineSpacingFactor : 1.0
        var baselineY = [Double](repeating: 0, count: lines.count)
        for (idx, line) in lines.enumerated() {
            if idx == 0 {
                baselineY[idx] = 0                     // first line's baseline is the reference
            } else {
                // Advance: previous line's descent already consumed; drop by this
                // line's ascent plus the spacing leading.
                let advance = (lines[idx - 1].descent + line.ascent) * spacing
                baselineY[idx] = baselineY[idx - 1] - advance
            }
        }

        // Block vertical extent (local frame): top of the first line's cap to the
        // bottom of the last line's descender.
        let blockTop = (lines.first?.ascent ?? baseHeight)
        let blockBottom = baselineY.last! - (lines.last?.descent ?? 0)
        let blockHeight = blockTop - blockBottom

        // Block horizontal extent for the attachment / per-line alignment.
        let blockWidth = lines.map(\.width).max() ?? 0
        // When wrapping, the reference width drives alignment columns.
        let columnWidth = data.rectWidth > 0 ? data.rectWidth : blockWidth

        // 3. Attachment-point shift: place the block so the chosen attachment
        //    corner lands on the insertion point.
        let (attachX, attachY) = attachmentShift(
            data.attachment, columnWidth: columnWidth,
            blockTop: blockTop, blockHeight: blockHeight)

        // 4. Emit geometry, transforming local → world.
        var fills: [ResolvedFill] = []
        var polylines: [ResolvedPolyline] = []
        let rotation = data.rotation
        let origin = data.position

        func toWorld(_ p: Vector) -> Vector {
            let shifted = Vector(p.x + attachX, p.y + attachY)
            let rot = rotation != 0 ? shifted.rotated(by: rotation) : shifted
            return origin + rot
        }

        for (idx, line) in lines.enumerated() {
            let by = baselineY[idx]
            // Per-line horizontal alignment within the column.
            let align = line.align ?? blockAlign(for: data.attachment)
            let lineShiftX: Double
            switch align {
            case .left, .justified, .distributed: lineShiftX = 0
            case .center: lineShiftX = (columnWidth - line.width) / 2
            case .right:  lineShiftX = columnWidth - line.width
            }

            for seg in line.segments {
                let dx = seg.x + lineShiftX
                switch seg.content {
                case .fillGroups(let groups, let color):
                    for group in groups {
                        let worldLoops = group.map { loop in
                            loop.map { toWorld(Vector($0.x + dx, $0.y + by)) }
                        }
                        if !worldLoops.isEmpty {
                            fills.append(ResolvedFill(loops: worldLoops, color: color))
                        }
                    }
                case .strokes(let strokes, let color):
                    let segPen = ResolvedPen(color: color, lineType: pen.lineType,
                                             lineWidth: pen.lineWidth)
                    for stroke in strokes where stroke.count >= 2 {
                        let world = stroke.map { toWorld(Vector($0.x + dx, $0.y + by)) }
                        polylines.append(ResolvedPolyline(points: world, closed: false, pen: segPen))
                    }
                case .decoration(let p0, let p1, let color):
                    let segPen = ResolvedPen(color: color, lineType: pen.lineType,
                                             lineWidth: pen.lineWidth)
                    let a = toWorld(Vector(p0.x + dx, p0.y + by))
                    let b = toWorld(Vector(p1.x + dx, p1.y + by))
                    polylines.append(ResolvedPolyline(points: [a, b], closed: false, pen: segPen))
                }
            }
        }

        return ResolvedGeometry(polylines: polylines, fills: fills)
    }

    // MARK: - Bounding box (font-aware)

    /// A tight, font-aware bounding box for an `MTextData`, from the resolved ink.
    /// Returns `nil` when no provider/font is available so the caller can fall back.
    public static func boundingBox(_ data: MTextData, ctx: ResolveContext) -> AABB? {
        guard ctx.fontProvider != nil else { return nil }
        let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
        let geo = resolve(data, pen: pen, ctx: ctx)
        guard !geo.polylines.isEmpty || !geo.fills.isEmpty else { return nil }
        var box = AABB.empty
        for pl in geo.polylines { for p in pl.points { box.expand(toInclude: p) } }
        for fill in geo.fills { for loop in fill.loops { for p in loop { box.expand(toInclude: p) } } }
        return box.isEmpty ? nil : box
    }

    // MARK: - Layout model (local frame, baseline at y = 0 for the line)

    /// One drawable piece placed within a line, at a local x along the baseline.
    /// `y` is relative to the line's baseline (y = 0). Coordinates are already in
    /// WORLD units (em-scaled) so the only remaining transform is the line shift +
    /// baseline drop + attachment + rotation.
    struct PlacedSegment {
        var x: Double                 // local x of this segment's left edge
        var content: SegmentContent
    }

    enum SegmentContent {
        case fillGroups([[[Vector]]], RGBAColor)   // native glyph fills (per containment group)
        case strokes([[Vector]], RGBAColor)        // stroke glyph polylines
        case decoration(Vector, Vector, RGBAColor) // underline / overline / strike (a line)
    }

    /// A laid-out line: its placed segments, total advance width, and vertical
    /// metrics (max ascent / descent of the runs on it).
    struct LaidLine {
        var segments: [PlacedSegment]
        var width: Double
        var ascent: Double
        var descent: Double
        var align: MTextParagraphAlign?
    }

    // MARK: - Paragraph layout (word wrapping)

    /// A measured atom of a paragraph: either a word (run of non-space glyphs), a
    /// space (collapsible at wrap boundaries), or a stacked fraction. Each carries
    /// its placed geometry (left edge at x = 0) + its advance width + metrics.
    private struct Atom {
        var geometry: [PlacedSegment]   // at x = 0
        var advance: Double
        var ascent: Double
        var descent: Double
        var isSpace: Bool
    }

    private static func layoutParagraph(
        _ paragraph: MTextParagraph, data: MTextData, baseStyle: TextStyle,
        baseHeight: Double, wrapWidth: Double, pen: ResolvedPen,
        provider: any FontProvider, ctx: ResolveContext
    ) -> [LaidLine] {
        // 1. Build the atom stream for the paragraph.
        var atoms: [Atom] = []
        for inline in paragraph.inlines {
            switch inline {
            case .run(let run):
                atoms.append(contentsOf: runAtoms(run, data: data, baseStyle: baseStyle,
                                                  baseHeight: baseHeight, pen: pen,
                                                  provider: provider, ctx: ctx))
            case .stacked(let stacked):
                if let atom = stackedAtom(stacked, data: data, baseStyle: baseStyle,
                                          baseHeight: baseHeight, pen: pen,
                                          provider: provider, ctx: ctx) {
                    atoms.append(atom)
                }
            case .tab:
                // A tab is a wide space (4× the base space).
                atoms.append(Atom(geometry: [], advance: baseHeight * 2,
                                  ascent: baseHeight, descent: baseHeight * 0.25, isSpace: true))
            }
        }
        guard !atoms.isEmpty else { return [] }

        // 2. Greedy word-wrap the atoms into lines.
        var lines: [LaidLine] = []
        var current: [Atom] = []
        var currentWidth = 0.0

        func commit() {
            // Drop trailing spaces from a wrapped line.
            while let last = current.last, last.isSpace {
                current.removeLast()
            }
            guard !current.isEmpty else { return }
            lines.append(assembleLine(current, align: paragraph.alignment,
                                      fallbackAscent: baseHeight,
                                      fallbackDescent: baseHeight * 0.25))
            current = []
            currentWidth = 0
        }

        for atom in atoms {
            // Leading space on a fresh wrapped line is dropped.
            if atom.isSpace && current.isEmpty { continue }
            let next = currentWidth + atom.advance
            if next > wrapWidth, !current.isEmpty, !atom.isSpace {
                commit()
                // re-evaluate this atom on the new line
                current.append(atom)
                currentWidth = atom.advance
            } else {
                current.append(atom)
                currentWidth = next
            }
        }
        commit()
        return lines
    }

    /// Assembles placed atoms into a `LaidLine`, concatenating their geometry at
    /// successive x offsets and taking the max ascent/descent.
    private static func assembleLine(_ atoms: [Atom], align: MTextParagraphAlign?,
                                     fallbackAscent: Double, fallbackDescent: Double) -> LaidLine {
        var segments: [PlacedSegment] = []
        var x = 0.0
        var ascent = 0.0
        var descent = 0.0
        for atom in atoms {
            for seg in atom.geometry {
                segments.append(PlacedSegment(x: seg.x + x, content: seg.content))
            }
            x += atom.advance
            ascent = Swift.max(ascent, atom.ascent)
            descent = Swift.max(descent, atom.descent)
        }
        if ascent <= 0 { ascent = fallbackAscent }
        if descent <= 0 { descent = fallbackDescent }
        return LaidLine(segments: segments, width: x, ascent: ascent, descent: descent, align: align)
    }

    // MARK: - Run → atoms (split into words + spaces for wrapping)

    private static func runAtoms(
        _ run: TextRun, data: MTextData, baseStyle: TextStyle, baseHeight: Double,
        pen: ResolvedPen, provider: any FontProvider, ctx: ResolveContext
    ) -> [Atom] {
        guard !run.text.isEmpty else { return [] }

        // Resolve the run's font + traits + height + colour.
        let height = runHeight(run.heightFactor, base: baseHeight)
        guard height > 0 else { return [] }
        let bold = run.bold ?? baseStyle.bold
        let italic = run.italic ?? baseStyle.italic
        let fontSource = run.fontOverride ?? baseStyle.primaryFont
        guard let (shaped, isNative) = resolveRunShaper(
            fontSource: fontSource, bold: bold, italic: italic,
            baseStyle: baseStyle, provider: provider) else { return [] }

        let color = run.color ?? pen.color
        let metrics = shaped.metrics
        let capHeight = metrics.capHeight > 0 ? metrics.capHeight : 1
        let scale = height / capHeight
        let ascent = metrics.ascent * scale
        let descent = metrics.descent * scale
        let tolerance = ctx.tessellationTolerance / Swift.max(scale, 1e-9)

        let oblique = run.obliqueOverride ?? baseStyle.obliqueAngle
        let tracking = (run.trackingFactor.map { ($0 - 1.0) * (capHeight / 3.0) }) ?? 0
        let attrs = RunAttributes(bold: bold, italic: italic,
                                  obliqueAngle: oblique, widthFactor: 1, tracking: tracking)

        // Split the run text into word / space chunks so the wrapper can break at
        // spaces. (Non-breaking spaces U+00A0 stay inside a word.)
        let chunks = splitWordsKeepingSpaces(run.text)
        var atoms: [Atom] = []
        for chunk in chunks {
            let isSpace = chunk.allSatisfy { $0 == " " }
            let placed = shapeChunk(chunk, shaped: shaped, isNative: isNative, attrs: attrs,
                                    scale: scale, oblique: oblique, color: color,
                                    underline: run.underline, overline: run.overline,
                                    strikethrough: run.strikethrough,
                                    ascent: ascent, descent: descent,
                                    capHeight: capHeight * scale, tolerance: tolerance)
            atoms.append(Atom(geometry: placed.segments, advance: placed.width,
                              ascent: ascent, descent: descent, isSpace: isSpace))
        }
        return atoms
    }

    /// Shapes one chunk (word or space) into placed segments at x = 0, plus the
    /// run decorations (underline/overline/strike) spanning the chunk.
    private static func shapeChunk(
        _ chunk: String, shaped: ShapedFont, isNative: Bool, attrs: RunAttributes,
        scale: Double, oblique: Double, color: RGBAColor,
        underline: Bool, overline: Bool, strikethrough: Bool,
        ascent: Double, descent: Double, capHeight: Double, tolerance: Double
    ) -> (segments: [PlacedSegment], width: Double) {
        var segments: [PlacedSegment] = []
        var penX = 0.0

        let positioned = shaped.shape(chunk, attributes: attrs)
        for pg in positioned {
            let geo = shaped.glyphGeometry(pg.glyph, tolerance: tolerance)
            let gx = penX + pg.offset.x
            // Transform em-space glyph geometry to local world: scale + oblique shear.
            func place(_ p: Vector) -> Vector {
                var x = p.x + gx
                let y = p.y
                if oblique != 0 { x += y * tan(oblique) }
                return Vector(x * scale, y * scale)
            }
            if isNative {
                var groups: [[[Vector]]] = []
                for group in geo.fillGroups where !group.isEmpty {
                    groups.append(group.map { loop in loop.map(place) })
                }
                if !groups.isEmpty {
                    segments.append(PlacedSegment(x: 0, content: .fillGroups(groups, color)))
                }
            } else {
                var strokes: [[Vector]] = []
                for stroke in geo.strokes where stroke.count >= 2 {
                    strokes.append(stroke.map(place))
                }
                if !strokes.isEmpty {
                    segments.append(PlacedSegment(x: 0, content: .strokes(strokes, color)))
                }
            }
            penX += pg.advance.x
        }
        let width = penX * scale

        // Decorations span the whole chunk (skip pure-space chunks for overline /
        // strike, but DO underline spaces between words — AutoCAD underlines them).
        if width > 0 || underline {
            let underlineY = -descent * 0.5
            let overlineY = ascent * 1.02
            let strikeY = capHeight * 0.4
            if underline {
                segments.append(PlacedSegment(x: 0,
                    content: .decoration(Vector(0, underlineY), Vector(width, underlineY), color)))
            }
            if overline, width > 0 {
                segments.append(PlacedSegment(x: 0,
                    content: .decoration(Vector(0, overlineY), Vector(width, overlineY), color)))
            }
            if strikethrough, width > 0 {
                segments.append(PlacedSegment(x: 0,
                    content: .decoration(Vector(0, strikeY), Vector(width, strikeY), color)))
            }
        }
        return (segments, width)
    }

    // MARK: - Stacked fractions

    private static func stackedAtom(
        _ stacked: StackedRun, data: MTextData, baseStyle: TextStyle, baseHeight: Double,
        pen: ResolvedPen, provider: any FontProvider, ctx: ResolveContext
    ) -> Atom? {
        let h = baseHeight * (stacked.heightFactor > 0 ? stacked.heightFactor : 0.7)
        guard h > 0 else { return nil }
        let fontSource = baseStyle.primaryFont
        guard let (shaped, isNative) = resolveRunShaper(
            fontSource: fontSource, bold: baseStyle.bold, italic: baseStyle.italic,
            baseStyle: baseStyle, provider: provider) else { return nil }

        let color = pen.color
        let metrics = shaped.metrics
        let capHeight = metrics.capHeight > 0 ? metrics.capHeight : 1
        let scale = h / capHeight
        let tolerance = ctx.tessellationTolerance / Swift.max(scale, 1e-9)
        let attrs = RunAttributes(bold: baseStyle.bold, italic: baseStyle.italic,
                                  obliqueAngle: baseStyle.obliqueAngle, widthFactor: 1, tracking: 0)

        // Shape numerator and denominator at the reduced height.
        let upper = shapeChunk(stacked.upper, shaped: shaped, isNative: isNative, attrs: attrs,
                               scale: scale, oblique: baseStyle.obliqueAngle, color: color,
                               underline: false, overline: false, strikethrough: false,
                               ascent: metrics.ascent * scale, descent: metrics.descent * scale,
                               capHeight: capHeight * scale, tolerance: tolerance)
        let lower = stacked.lower.isEmpty ? (segments: [PlacedSegment](), width: 0.0)
            : shapeChunk(stacked.lower, shaped: shaped, isNative: isNative, attrs: attrs,
                         scale: scale, oblique: baseStyle.obliqueAngle, color: color,
                         underline: false, overline: false, strikethrough: false,
                         ascent: metrics.ascent * scale, descent: metrics.descent * scale,
                         capHeight: capHeight * scale, tolerance: tolerance)

        let stackWidth = Swift.max(upper.width, lower.width)
        guard stackWidth > 0 else { return nil }

        // Vertical placement: numerator above the baseline-ish, denominator below.
        // Use the reduced cap height as the unit. The divider sits near the
        // main-text baseline midline.
        let unit = capHeight * scale
        let gap = unit * 0.15
        let upperY = gap + unit * 0.55            // numerator baseline above mid
        let lowerY = -(unit * 0.55)               // denominator baseline below mid

        var segments: [PlacedSegment] = []
        // Centre each part within the stack width.
        let upperShift = (stackWidth - upper.width) / 2
        let lowerShift = (stackWidth - lower.width) / 2
        for seg in upper.segments {
            segments.append(PlacedSegment(x: seg.x + upperShift, content: shift(seg.content, dy: upperY)))
        }
        for seg in lower.segments {
            segments.append(PlacedSegment(x: seg.x + lowerShift, content: shift(seg.content, dy: lowerY)))
        }
        // Divider bar for fraction (/) and diagonal (#); tolerance (^) has no bar.
        if stacked.kind != .tolerance {
            let barY = unit * 0.05
            segments.append(PlacedSegment(x: 0,
                content: .decoration(Vector(0, barY), Vector(stackWidth, barY), color)))
        }

        let ascent = upperY + unit
        let descent = -lowerY + unit * 0.25
        return Atom(geometry: segments, advance: stackWidth + unit * 0.1,
                    ascent: ascent, descent: descent, isSpace: false)
    }

    /// Vertically shifts a segment's content by `dy` (local units).
    private static func shift(_ content: SegmentContent, dy: Double) -> SegmentContent {
        switch content {
        case .fillGroups(let groups, let c):
            return .fillGroups(groups.map { g in g.map { loop in loop.map { Vector($0.x, $0.y + dy) } } }, c)
        case .strokes(let strokes, let c):
            return .strokes(strokes.map { s in s.map { Vector($0.x, $0.y + dy) } }, c)
        case .decoration(let a, let b, let c):
            return .decoration(Vector(a.x, a.y + dy), Vector(b.x, b.y + dy), c)
        }
    }

    // MARK: - Helpers

    /// The run's world height from its `heightFactor` (positive = relative to the
    /// base; negative = absolute world height — the parser's sentinel).
    static func runHeight(_ factor: Double?, base: Double) -> Double {
        guard let f = factor else { return base }
        if f < 0 { return -f }            // absolute (parser sentinel)
        return base * f                   // relative
    }

    /// Splits text into alternating word / space chunks, keeping the spaces as
    /// their own chunks so the wrapper can break at them. Runs of spaces collapse
    /// into one space chunk.
    static func splitWordsKeepingSpaces(_ text: String) -> [String] {
        var chunks: [String] = []
        var cur = ""
        var curIsSpace = false
        for ch in text {
            let isSpace = (ch == " ")
            if cur.isEmpty {
                cur.append(ch); curIsSpace = isSpace
            } else if isSpace == curIsSpace {
                cur.append(ch)
            } else {
                chunks.append(cur); cur = String(ch); curIsSpace = isSpace
            }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }

    /// Resolves the shaper for a run's font source + traits, falling back through
    /// the substitution chain (native default → `.lff` standard) so a run never
    /// vanishes. Returns the shaper and whether it is a native (fill) source.
    static func resolveRunShaper(
        fontSource: FontSource, bold: Bool, italic: Bool,
        baseStyle: TextStyle, provider: any FontProvider
    ) -> (ShapedFont, Bool)? {
        // 1. Exact run font + traits.
        if let s = provider.resolveFont(fontSource, bold: bold, italic: italic) {
            let isNative: Bool
            if case .native = fontSource { isNative = true } else { isNative = false }
            return (s, isNative)
        }
        // 2. The block base style's font.
        if let s = provider.resolveFont(baseStyle.primaryFont, bold: bold, italic: italic) {
            let isNative: Bool
            if case .native = baseStyle.primaryFont { isNative = true } else { isNative = false }
            return (s, isNative)
        }
        // 3. Default native family.
        if let s = provider.resolveFont(.native(family: TextStyle.defaultNativeFamily),
                                        bold: bold, italic: italic) {
            return (s, true)
        }
        // 4. Stroke "standard" / empty key.
        if let s = provider.resolveFont(.stroke(lff: "standard")) { return (s, false) }
        if let s = provider.resolveFont(.stroke(lff: "")) { return (s, false) }
        return nil
    }

    /// Resolves the block's base `TextStyle` (name → table → default native).
    static func resolvedStyle(for data: MTextData, ctx: ResolveContext) -> TextStyle {
        let name = data.styleName ?? TextStyleTable.standardName
        if let provider = ctx.textStyleProvider, let s = provider(name) { return s }
        return TextStyle(name: name, primaryFont: .native(family: TextStyle.defaultNativeFamily))
    }

    // MARK: - Attachment-point placement

    /// The per-line horizontal alignment implied by the attachment column
    /// (left column ⇒ left, centre ⇒ centre, right ⇒ right). Per-paragraph `\pq`
    /// overrides this.
    static func blockAlign(for attachment: MTextAttachment) -> MTextParagraphAlign {
        switch attachment {
        case .topLeft, .middleLeft, .bottomLeft:       return .left
        case .topCenter, .middleCenter, .bottomCenter: return .center
        case .topRight, .middleRight, .bottomRight:    return .right
        }
    }

    /// The local-frame shift `(dx, dy)` that places the block so its attachment
    /// corner lands on the insertion point. Local frame: x = 0 is the column left,
    /// y = 0 is the first line's baseline; the block spans [blockTop … blockTop −
    /// blockHeight] vertically and [0 … columnWidth] horizontally.
    static func attachmentShift(_ attachment: MTextAttachment, columnWidth: Double,
                                blockTop: Double, blockHeight: Double) -> (Double, Double) {
        // Horizontal: anchor the column's left/center/right at x = 0.
        let dx: Double
        switch attachment {
        case .topLeft, .middleLeft, .bottomLeft:       dx = 0
        case .topCenter, .middleCenter, .bottomCenter: dx = -columnWidth / 2
        case .topRight, .middleRight, .bottomRight:    dx = -columnWidth
        }
        // Vertical: the top of the block is at +blockTop in local; we shift so the
        // requested vertical anchor sits at y = 0 (the insertion point).
        let dy: Double
        switch attachment {
        case .topLeft, .topCenter, .topRight:          dy = -blockTop
        case .middleLeft, .middleCenter, .middleRight: dy = -blockTop + blockHeight / 2
        case .bottomLeft, .bottomCenter, .bottomRight: dy = -blockTop + blockHeight
        }
        return (dx, dy)
    }
}
