//
//  MTextRunConverterTests.swift
//  CADEngineTests
//
//  Tests for the PURE (UI-free) bridge between the rich-MTEXT run tree and the
//  in-place editor's spanned-plain-text intermediate (Wave 4C). The app overlay
//  translates `NSAttributedString` ⇄ `MTextSpannedText`; THIS converter does the
//  run-tree ⇄ span mapping, so these tests are the contract that bold / italic /
//  colour authored in the editor survive the round-trip through `TextRun`, and
//  that plain text is unchanged.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("MText: run <-> spanned-text converter (4C authoring)")
struct MTextRunConverterTests {

    // MARK: helpers

    /// All runs of a single-paragraph tree, in order (fails if any inline is not a run).
    private func runs(_ paragraphs: [MTextParagraph], paragraph: Int = 0) -> [TextRun] {
        guard paragraph < paragraphs.count else { return [] }
        return paragraphs[paragraph].inlines.compactMap {
            if case .run(let r) = $0 { return r } else { return nil }
        }
    }

    // MARK: plain text is unchanged

    @Test("plain text round-trips unchanged (no spans, single default run)")
    func plainUnchanged() {
        let original = [MTextParagraph(inlines: [.run(TextRun(text: "Hello world"))])]
        let spanned = MTextRunConverter.spannedText(from: original)

        #expect(spanned.string == "Hello world")
        #expect(spanned.spans.isEmpty)   // a plain run produces NO span

        let back = MTextRunConverter.paragraphs(from: spanned)
        let r = runs(back)
        #expect(r.count == 1)
        #expect(r[0].text == "Hello world")
        #expect(r[0].bold == nil)
        #expect(r[0].italic == nil)
        #expect(r[0].color == nil)
    }

    @Test("plain multi-line text keeps paragraphs, no spans")
    func plainMultiline() {
        let original = [
            MTextParagraph(inlines: [.run(TextRun(text: "line one"))]),
            MTextParagraph(inlines: [.run(TextRun(text: "line two"))]),
        ]
        let spanned = MTextRunConverter.spannedText(from: original)
        #expect(spanned.string == "line one\nline two")
        #expect(spanned.spans.isEmpty)

        let back = MTextRunConverter.paragraphs(from: spanned)
        #expect(back.count == 2)
        #expect(runs(back, paragraph: 0).first?.text == "line one")
        #expect(runs(back, paragraph: 1).first?.text == "line two")
    }

    // MARK: bold / italic / colour authored -> spanned -> runs round-trip

    @Test("a bold span authored in the editor becomes a bold run")
    func boldSpanToRun() {
        // Editor produced: "Hello World" with "World" bold.
        let spanned = MTextSpannedText(
            string: "Hello World",
            spans: [MTextFormatSpan(range: NSRange(location: 6, length: 5), bold: true)])

        let paragraphs = MTextRunConverter.paragraphs(from: spanned)
        let r = runs(paragraphs)
        #expect(r.count == 2)
        #expect(r[0].text == "Hello ")
        #expect(r[0].bold == nil)
        #expect(r[1].text == "World")
        #expect(r[1].bold == true)
        #expect(r[1].italic == nil)
    }

    @Test("bold + colour run survives the full round-trip through the converter")
    func boldColorRoundTrip() {
        let red = RGBAColor(1, 0, 0)
        // Model: "AB" plain + "CD" bold-red + "EF" plain.
        let original = [MTextParagraph(inlines: [
            .run(TextRun(text: "AB")),
            .run(TextRun(text: "CD", color: red, bold: true)),
            .run(TextRun(text: "EF")),
        ])]

        // -> spanned (what the editor would show)
        let spanned = MTextRunConverter.spannedText(from: original)
        #expect(spanned.string == "ABCDEF")
        #expect(spanned.spans.count == 1)
        let span = spanned.spans[0]
        #expect(span.range == NSRange(location: 2, length: 2))
        #expect(span.bold)
        #expect(!span.italic)
        #expect(span.color == red)

        // -> back to runs (what commit would produce)
        let back = MTextRunConverter.paragraphs(from: spanned)
        let r = runs(back)
        #expect(r.count == 3)
        #expect(r[0].text == "AB" && r[0].bold == nil && r[0].color == nil)
        #expect(r[1].text == "CD")
        #expect(r[1].bold == true)
        #expect(r[1].italic == nil)
        #expect(r[1].color == red)
        #expect(r[2].text == "EF" && r[2].bold == nil && r[2].color == nil)
    }

    @Test("italic and bold can overlap on one span and both survive")
    func boldItalicTogether() {
        let spanned = MTextSpannedText(
            string: "xYz",
            spans: [MTextFormatSpan(range: NSRange(location: 1, length: 1), bold: true, italic: true)])
        let r = runs(MTextRunConverter.paragraphs(from: spanned))
        #expect(r.count == 3)
        #expect(r[1].text == "Y")
        #expect(r[1].bold == true)
        #expect(r[1].italic == true)
    }

    @Test("adjacent equal-attribute characters coalesce into one run")
    func coalesceEqualNeighbours() {
        // Two separate bold spans over adjacent ranges -> one bold run.
        let spanned = MTextSpannedText(
            string: "ABCD",
            spans: [
                MTextFormatSpan(range: NSRange(location: 0, length: 2), bold: true),
                MTextFormatSpan(range: NSRange(location: 2, length: 2), bold: true),
            ])
        let r = runs(MTextRunConverter.paragraphs(from: spanned))
        #expect(r.count == 1)
        #expect(r[0].text == "ABCD")
        #expect(r[0].bold == true)
    }

    @Test("colour-only span (no bold/italic) round-trips colour exactly")
    func colorOnlySpan() {
        let blue = RGBAColor(0, 0, 1)
        let spanned = MTextSpannedText(
            string: "red blue",
            spans: [MTextFormatSpan(range: NSRange(location: 4, length: 4), color: blue)])
        let r = runs(MTextRunConverter.paragraphs(from: spanned))
        #expect(r.count == 2)
        #expect(r[1].text == "blue")
        #expect(r[1].color == blue)
        #expect(r[1].bold == nil)
        #expect(r[1].italic == nil)
    }

    // MARK: multi-line + formatting interplay

    @Test("formatting on a multi-line spanned text maps to per-paragraph runs")
    func formattedMultiline() {
        // "one\ntwo" with "two" bold. The '\n' is at UTF-16 location 3.
        let spanned = MTextSpannedText(
            string: "one\ntwo",
            spans: [MTextFormatSpan(range: NSRange(location: 4, length: 3), bold: true)])
        let paragraphs = MTextRunConverter.paragraphs(from: spanned)
        #expect(paragraphs.count == 2)

        let p0 = runs(paragraphs, paragraph: 0)
        #expect(p0.count == 1)
        #expect(p0[0].text == "one")
        #expect(p0[0].bold == nil)

        let p1 = runs(paragraphs, paragraph: 1)
        #expect(p1.count == 1)
        #expect(p1[0].text == "two")
        #expect(p1[0].bold == true)
    }

    @Test("an empty line survives as a paragraph with one empty default run")
    func emptyLinePreserved() {
        let spanned = MTextSpannedText(string: "a\n\nb")
        let paragraphs = MTextRunConverter.paragraphs(from: spanned)
        #expect(paragraphs.count == 3)
        #expect(runs(paragraphs, paragraph: 0).first?.text == "a")
        #expect(runs(paragraphs, paragraph: 1).first?.text == "")
        #expect(runs(paragraphs, paragraph: 2).first?.text == "b")
    }

    // MARK: full model -> spanned -> model isomorphism for the authorable subset

    @Test("model -> spanned -> model is identity for bold/italic/colour runs")
    func modelRoundTripIdentity() {
        let green = RGBAColor(0, 1, 0)
        let original = [
            MTextParagraph(inlines: [
                .run(TextRun(text: "plain ")),
                .run(TextRun(text: "italic", italic: true)),
            ]),
            MTextParagraph(inlines: [
                .run(TextRun(text: "green", color: green)),
            ]),
        ]
        let back = MTextRunConverter.paragraphs(
            from: MTextRunConverter.spannedText(from: original))

        #expect(back.count == 2)
        let p0 = runs(back, paragraph: 0)
        #expect(p0.count == 2)
        #expect(p0[0].text == "plain " && p0[0].italic == nil)
        #expect(p0[1].text == "italic" && p0[1].italic == true)
        let p1 = runs(back, paragraph: 1)
        #expect(p1.count == 1)
        #expect(p1[0].text == "green" && p1[0].color == green)
    }

    // MARK: non-authorable inlines degrade (documented limitation)

    @Test("stacked / tab inlines flatten to plain text (authoring-UI limitation)")
    func nonRunInlinesDegrade() {
        let original = [MTextParagraph(inlines: [
            .run(TextRun(text: "x")),
            .tab,
            .stacked(StackedRun(upper: "1", lower: "2", kind: .fraction)),
        ])]
        let spanned = MTextRunConverter.spannedText(from: original)
        #expect(spanned.string == "x\t1/2")
        #expect(spanned.spans.isEmpty)
    }
}
