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
}
