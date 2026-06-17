//
//  MTextRunConverter.swift
//  CADEngine
//
//  The PURE (UI-free, Foundation-only) bridge between the rich-MTEXT run tree
//  (`[MTextParagraph]` / `TextRun`) and a flat "spanned plain text" intermediate
//  the in-place MTEXT editor authors against. This is the load-bearing half of
//  Wave 4C (rich MTEXT inline authoring): the APP overlay only has to translate
//  `NSAttributedString` ⇄ `MTextSpannedText` (an `NSRange`-shaped, AppKit-free
//  representation), and THIS converter does the real run-tree ⇄ span mapping —
//  so no AppKit / `NSAttributedString` ever leaks into `CADEngine`.
//
//  ## Why a flat span intermediate (not paragraphs directly)
//  A live text editor exposes a single plain string + ranged attributes (an
//  `NSAttributedString`). MTEXT, by contrast, is a TREE: paragraphs of inline
//  runs. The natural editor-side shape is therefore "one plain string with
//  newlines + a set of formatting SPANS"; the tree shape is the engine's. This
//  converter is the isomorphism between them for the attributes the editor can
//  author (bold / italic / colour):
//
//      [MTextParagraph]  ──spannedText(from:)──▶  MTextSpannedText
//      [MTextParagraph]  ◀──paragraphs(from:)──   MTextSpannedText
//
//  Paragraphs are joined by a single `\n` (newline) in the flat string — exactly
//  the boundary the editor inserts on Shift-Return and that `MTextParser`/the
//  writer treat as `\P`. Within a paragraph, contiguous runs become contiguous
//  spans; on the way back, adjacent characters that share the same (bold, italic,
//  colour) attributes are coalesced into one `TextRun`.
//
//  ## Offsets are UTF-16 code units (NSRange-compatible, still pure Foundation)
//  `MTextFormatSpan.range` uses `NSRange` (location/length in UTF-16 code units)
//  so the app's `NSAttributedString` bridge is a direct, lossless copy with no
//  index re-mapping. `NSRange` is a Foundation type — no AppKit dependency.
//
//  ## Attribute scope (what the EDITOR can author)
//  Only bold / italic / colour round-trip through this converter — those are the
//  three affordances the format bar / ⌘B / ⌘I expose. Other run attributes
//  (height factor, underline/overline/strikethrough, tracking, oblique, font
//  family overrides, stacked fractions, tabs) are NOT representable as editor
//  spans here; `spannedText(from:)` therefore DROPS them when flattening, and a
//  paragraph that contains a non-run inline (stacked / tab) is flattened to its
//  textual form. This is an authoring-UI limitation, not a model one: the run
//  model and the DXF round-trip still carry every attribute for entities the user
//  does not open in the inline editor. (Editing such an entity in the inline
//  editor and committing will normalize it to the bold/italic/colour subset.)
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it under
//  the terms of the GNU General Public License version 2 or (at your option) any
//  later version.
//

import Foundation

// MARK: - The editor-facing intermediate

/// One contiguous formatting span over `MTextSpannedText.string`, in UTF-16 code
/// units (so it maps 1:1 onto an `NSAttributedString`'s `NSRange` attribute runs).
/// Only the editor-authorable attributes are carried; a span whose attributes are
/// all defaults (no bold, no italic, no colour) is redundant and is never emitted
/// by `spannedText(from:)`.
public struct MTextFormatSpan: Sendable, Hashable {
    /// The covered range, in UTF-16 code units, into `MTextSpannedText.string`.
    public var range: NSRange
    /// Bold over this span (`true`). Maps to `TextRun.bold == true`.
    public var bold: Bool
    /// Italic over this span (`true`). Maps to `TextRun.italic == true`.
    public var italic: Bool
    /// Explicit run colour over this span, or `nil` for the inherited/default
    /// colour. Maps to `TextRun.color`.
    public var color: RGBAColor?

    public init(range: NSRange, bold: Bool = false, italic: Bool = false, color: RGBAColor? = nil) {
        self.range = range
        self.bold = bold
        self.italic = italic
        self.color = color
    }

    /// Whether this span carries no non-default formatting (so it need not exist).
    public var isPlain: Bool { !bold && !italic && color == nil }
}

/// A plain string + a set of formatting spans — the editor-facing flattening of a
/// rich-MTEXT run tree. Paragraph breaks are `\n` characters in `string`; spans
/// never straddle attributes within a paragraph (they may straddle `\n` only if
/// the runs on both sides share formatting, which is harmless: the paragraph
/// rebuild splits on `\n` first).
public struct MTextSpannedText: Sendable, Hashable {
    /// The flattened plain text. Paragraphs are joined by `\n`.
    public var string: String
    /// The formatting spans (each non-plain). Order is by ascending `location`.
    public var spans: [MTextFormatSpan]

    public init(string: String, spans: [MTextFormatSpan] = []) {
        self.string = string
        self.spans = spans
    }
}

// MARK: - The pure converter

/// Maps between the rich-MTEXT run tree and the editor's spanned-plain-text
/// intermediate. Stateless; every method is pure.
public enum MTextRunConverter {

    // MARK: paragraphs -> spanned text (open an MTEXT entity for editing)

    /// Flattens a paragraph/run tree into editor-facing spanned plain text.
    ///
    /// - Paragraphs are joined with `\n`.
    /// - Each `.run` contributes its `text`; a span is emitted for it iff the run
    ///   carries bold / italic / colour (other attributes are dropped — see the
    ///   file header's "Attribute scope").
    /// - Non-run inlines degrade to plain text: a `.stacked` becomes
    ///   `"<upper>/<lower>"` and a `.tab` becomes a literal tab — no span.
    public static func spannedText(from paragraphs: [MTextParagraph]) -> MTextSpannedText {
        var pieces: [String] = []
        pieces.reserveCapacity(paragraphs.count)
        var spans: [MTextFormatSpan] = []

        // Running UTF-16 cursor across the whole flattened string (paragraph texts
        // joined by a single '\n', which is one UTF-16 unit).
        var cursorUTF16 = 0

        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 {
                // The '\n' separator we will join with below occupies one unit.
                cursorUTF16 += 1
            }
            var paragraphText = ""
            for inline in paragraph.inlines {
                switch inline {
                case .run(let run):
                    let len = run.text.utf16.count
                    if len > 0 {
                        let bold = run.bold == true
                        let italic = run.italic == true
                        if bold || italic || run.color != nil {
                            spans.append(MTextFormatSpan(
                                range: NSRange(location: cursorUTF16, length: len),
                                bold: bold, italic: italic, color: run.color))
                        }
                    }
                    paragraphText += run.text
                    cursorUTF16 += len
                case .stacked(let s):
                    let flat = "\(s.upper)/\(s.lower)"
                    paragraphText += flat
                    cursorUTF16 += flat.utf16.count
                case .tab:
                    paragraphText += "\t"
                    cursorUTF16 += 1   // '\t' is one UTF-16 unit
                }
            }
            pieces.append(paragraphText)
        }

        return MTextSpannedText(string: pieces.joined(separator: "\n"), spans: spans)
    }

    // MARK: spanned text -> paragraphs (commit the editor back to the model)

    /// Rebuilds a paragraph/run tree from editor-facing spanned plain text.
    ///
    /// The string is split on `\n` into paragraphs; within each paragraph, every
    /// character is assigned its effective (bold, italic, colour) — the LAST span
    /// covering that character wins, matching how an attributed editor layers
    /// attributes — and adjacent characters sharing the same attributes are
    /// coalesced into one `TextRun`. A paragraph with no characters becomes a
    /// single empty default run (so blank lines survive the round-trip).
    public static func paragraphs(from spanned: MTextSpannedText) -> [MTextParagraph] {
        let units = Array(spanned.string.utf16)

        // Per-UTF-16-unit effective attributes (last covering span wins).
        var attrs = [RunAttr](repeating: RunAttr(), count: units.count)
        for span in spanned.spans where !span.isPlain {
            let lo = max(0, span.range.location)
            let hi = min(units.count, span.range.location + span.range.length)
            guard lo < hi else { continue }
            for i in lo..<hi {
                if span.bold { attrs[i].bold = true }
                if span.italic { attrs[i].italic = true }
                if let c = span.color { attrs[i].color = c }
            }
        }

        // Walk the units, splitting paragraphs on '\n' (U+000A == 10) and runs on
        // an attribute change, coalescing equal-attribute neighbours into one run.
        return rebuild(units: units, attrs: attrs)
    }

    // MARK: - internals

    /// Effective per-character attributes accumulated from spans.
    private struct RunAttr: Equatable {
        var bold = false
        var italic = false
        var color: RGBAColor?

        /// Build a `TextRun` carrying only the editor-authorable attributes. `nil`
        /// is used for bold/italic when false so a plain run stays fully default
        /// (matching how `TextTool` / the parser leave them).
        func makeRun(text: String) -> TextRun {
            TextRun(
                text: text,
                color: color,
                bold: bold ? true : nil,
                italic: italic ? true : nil)
        }
    }

    /// Indexed rebuild: split on '\n', coalesce equal-attribute neighbours.
    private static func rebuild(units: [UInt16], attrs: [RunAttr]) -> [MTextParagraph] {
        var paragraphs: [MTextParagraph] = []
        var currentInlines: [MTextInline] = []
        var runUnits: [UInt16] = []
        var runAttr = RunAttr()
        var haveRun = false

        func flushRun() {
            if haveRun && !runUnits.isEmpty {
                let text = String(decoding: runUnits, as: UTF16.self)
                currentInlines.append(.run(runAttr.makeRun(text: text)))
            }
            runUnits.removeAll(keepingCapacity: true)
            haveRun = false
        }

        func flushParagraph() {
            flushRun()
            if currentInlines.isEmpty {
                currentInlines = [.run(TextRun(text: ""))]
            }
            paragraphs.append(MTextParagraph(inlines: currentInlines))
            currentInlines = []
        }

        let newline: UInt16 = 10
        for i in 0..<units.count {
            let unit = units[i]
            if unit == newline {
                flushParagraph()
                continue
            }
            let a = attrs[i]
            if haveRun, a == runAttr {
                runUnits.append(unit)
            } else {
                flushRun()
                runAttr = a
                runUnits = [unit]
                haveRun = true
            }
        }
        flushParagraph()   // the final (possibly only) paragraph

        return paragraphs
    }
}
