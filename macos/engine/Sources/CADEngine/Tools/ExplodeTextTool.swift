//
//  ExplodeTextTool.swift
//  CADEngine
//
//  The EXPLODE-TEXT modify tool — convert a selected `.text` / `.mtext` entity
//  into its RENDERED glyph geometry as independent `.polyline` entities. Ported in
//  spirit from LibreCAD's `RS_ActionBlocksExplode` applied to text / the
//  `RS_Text::explode` path (librecad/src/lib/engine/rs_text.cpp), which walks the
//  shaped letters and emits the underlying stroke/outline geometry as free
//  entities: the text entity itself is REMOVED and one `.polyline` is ADDED per
//  glyph contour, so one text becomes N polylines in a single undoable group.
//
//  How the glyph geometry is obtained (READ-ONLY resolve, ADR-001 / ADR-004):
//    The tool resolves each selected text the SAME way the renderer does — it
//    calls `EntityKind.resolve(pen:ctx:)` with a `ResolveContext` whose
//    `fontProvider` is the process-wide shared `CADFonts.provider` (exactly what
//    `CADDrawing.makeResolveContext` wires). That single resolve path handles all
//    of `TextShaper`/`MTextShaper`'s work — justification, width factor, oblique,
//    multi-line, word-wrap, special-char prepass, annotative scaling — so the
//    exploded geometry visually matches the text's rendered form. The tool never
//    re-implements shaping and never mutates `Resolve`.
//
//  Stroke fonts vs outline fonts (both round-tripped to polylines):
//    - A STROKE font (`.lff`, e.g. a "Stroke" style) resolves to OPEN
//      `ResolvedPolyline`s (the pen-path strokes). Each becomes an OPEN `.polyline`.
//    - A NATIVE OUTLINE font (Core Text, the default "Standard" style) resolves to
//      `ResolvedFill`s — filled glyph regions whose `loops` are `[outer, holes…]`.
//      Each loop becomes a CLOSED `.polyline` (the outline contour). The exploded
//      result is therefore the glyphs' OUTLINES as closed polylines; the visible
//      ink (the filled area, incl. counters/holes) is conveyed by those contours.
//      (Filled regions are NOT re-emitted as hatches/solids — the brief asks for
//      `.polyline` strokes; for an outline font the closed outline polylines are
//      the faithful stroke-geometry analogue. See the report note.)
//
//  Behavior:
//    - empty / non-text selection → status nudges; every input is a no-op (no edits).
//    - the tool explodes EVERY selected `.text`/`.mtext` (other kinds are ignored —
//      they aren't text). For each, it emits `.remove(textID)` followed by one
//      `.add(.polyline(...))` per resolved stroke / outline contour, inheriting the
//      text's layer / pen / flags (the `.selected` flag is stripped on `.add` by the
//      app, matching the other modify tools).
//    - `.commit` (Return) / `.click` → fire the explode.
//    - `.cancel` (Esc) → discard the captured selection, reset, `.finished`.
//
//  PURE (ADR-001 / Tool contract): never touches CADDrawing / Quadtree / GUI. It
//  reads only `ToolContext.selected` and the shared, read-only font registry to
//  resolve glyph geometry. The app applies the `.remove` + `.add`s (re-minting the
//  added ids) as ONE undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Text::explode / RS_ActionBlocksExplode).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Explode-Text tool. With one or more `.text` / `.mtext`
/// entities selected, convert each into its rendered glyph geometry as
/// independent `.polyline` entities (stroke fonts → open polylines; outline fonts
/// → closed outline contours); the text entities are removed.
public struct ExplodeTextTool: Tool {

    // MARK: - State

    private var captured: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Explode Text" }

    public var status: String {
        explodableTexts().isEmpty
            ? "Select text to explode into geometry first"
            : "Press Return to explode the selected text into polylines"
    }

    /// The live preview: every polyline the explode would produce, resolved with
    /// the preview pen. (Geometrically identical to the source text's rendered
    /// strokes/outlines, so this re-draws the text in the preview style.)
    public var preview: [ResolvedPolyline] {
        explodableTexts().flatMap { record in
            Self.explodePolylines(record).map { line in
                ResolvedPolyline(points: line.points, closed: line.closed, pen: .toolPreview)
            }
        }
    }

    /// A MODIFY tool: reads `context.selected`, then on fire emits, per selected
    /// text, a `.remove(id)` plus one `.add(.polyline)` per resolved contour.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .move:
            return .none

        case .value:
            // A typed coordinate doesn't apply to this selection-based tool — ignore.
            return .none

        case .click, .commit:
            return fire()

        case .backspace:
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Fire

    private mutating func fire() -> ToolOutcome {
        let texts = explodableTexts()
        guard !texts.isEmpty else { return .none }

        var edits: [ToolEdit] = []
        for record in texts {
            let lines = Self.explodePolylines(record)
            guard !lines.isEmpty else { continue }
            // Remove the text, then add each contour polyline (inheriting attrs).
            edits.append(.remove(record.id))
            for line in lines {
                edits.append(.add(EntityRecord(
                    id: .placeholder,
                    layer: record.layer,
                    pen: record.pen,
                    flags: record.flags,
                    kind: .polyline(PolylineData(
                        vertices: line.points.map { PolylineVertex(point: $0) },
                        closed: line.closed
                    ))
                )))
            }
        }
        reset()
        return edits.isEmpty ? .none : .commit(edits)
    }

    private mutating func reset() {
        captured = []
    }

    // MARK: - Selection helpers

    /// The captured selections that are `.text`/`.mtext` carrying actual content.
    /// A `.text` with an empty string, or an `.mtext` whose runs are all empty,
    /// resolves to no geometry and is not worth exploding (and `explodePolylines`
    /// returns `[]` for it, so `fire()` skips it regardless — this just keeps the
    /// status/preview honest).
    private func explodableTexts() -> [EntityRecord] {
        captured.filter { record in
            switch record.kind {
            case .text(let d):  return !d.text.isEmpty
            case .mtext(let d): return Self.mtextHasContent(d)
            default:            return false
            }
        }
    }

    /// Whether an `.mtext` carries any non-empty text run (`.mtext` has no single
    /// `text` field — its content lives in `paragraphs` → inline runs).
    static func mtextHasContent(_ d: MTextData) -> Bool {
        for paragraph in d.paragraphs {
            for inline in paragraph.inlines {
                switch inline {
                case .run(let r) where !r.text.isEmpty:        return true
                case .stacked(let s) where !s.upper.isEmpty || !s.lower.isEmpty:
                    return true
                default:
                    continue
                }
            }
        }
        return false
    }

    // MARK: - Explode geometry (pure; resolves via the shared font provider)

    /// One contour the explode emits: an ordered ring/path of world points plus
    /// whether it is closed (outline-font contours are closed; stroke-font strokes
    /// are open).
    struct Contour: Sendable, Equatable {
        var points: [Vector]
        var closed: Bool
    }

    /// The `ResolveContext` the explode resolves text through: the SAME font
    /// registry the renderer uses (`CADFonts.provider`), so the exploded geometry
    /// matches the rendered text exactly. No layer/dim/style table is available to
    /// a pure tool, so `.byLayer` pens resolve to the engine default and the
    /// `textStyleProvider` is absent — a text with no explicit style (the common
    /// case) still resolves to the default native font, and a `.stroke(...)` style
    /// named on the entity still resolves to its `.lff` strokes via the provider.
    static func resolveContext() -> ResolveContext {
        ResolveContext(
            tessellationTolerance: ResolveContext.default.tessellationTolerance,
            fontProvider: CADFonts.provider
        )
    }

    /// Resolves a `.text`/`.mtext` record to its rendered glyph geometry and flattens
    /// it into explode contours:
    ///   - each resolved OPEN stroke `ResolvedPolyline` → an open `Contour`
    ///     (`.lff` stroke fonts);
    ///   - each resolved `ResolvedFill` loop (`[outer, holes…]`) → a CLOSED `Contour`
    ///     (native outline fonts — the glyph outline as closed contours).
    /// A non-text record, or text that resolves to nothing, yields `[]`.
    static func explodePolylines(_ record: EntityRecord) -> [Contour] {
        switch record.kind {
        case .text, .mtext:
            break
        default:
            return []
        }

        let ctx = resolveContext()
        // Resolve through the SAME path the renderer uses. The pen we pass is only a
        // placeholder for the resolved geometry's pen; the emitted `.polyline`
        // entities carry the source text's real `pen`, not this one.
        let geo = record.kind.resolve(pen: .toolPreview, ctx: ctx)

        var out: [Contour] = []
        out.reserveCapacity(geo.polylines.count + geo.fills.count)

        // Stroke fonts → open stroke polylines.
        for line in geo.polylines where line.points.count >= 2 {
            out.append(Contour(points: line.points, closed: line.closed))
        }
        // Outline fonts → each fill loop becomes a CLOSED outline polyline.
        for fill in geo.fills {
            for loop in fill.loops where loop.count >= 3 {
                out.append(Contour(points: loop, closed: true))
            }
        }
        return out
    }
}
