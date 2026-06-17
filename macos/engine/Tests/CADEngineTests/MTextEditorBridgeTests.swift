//
//  MTextEditorBridgeTests.swift
//  CADEngineTests
//
//  Tests for the app-layer `NSAttributedString` ⇄ `MTextSpannedText` bridge
//  (`TextEditorOverlay.attributed(from:...)` / `.spanned(from:...)`, Wave 4C) —
//  the thin AppKit half that sits between the live editor and the pure
//  `MTextRunConverter`. These exercise the pure VALUE transforms (build an
//  attributed string from spans, read spans back out); the live `NSTextView` /
//  format-bar / colour-panel interaction is GUI-only and is not unit-tested here.
//
//  The overlay source is shared into the test target via the established
//  `_Shared*.swift` symlink convention (`_SharedTextEditorOverlay.swift`).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
import AppKit
@testable import CADEngine

@Suite("MText: NSAttributedString <-> spanned bridge (4C)")
@MainActor
struct MTextEditorBridgeTests {

    private var baseFont: NSFont { NSFont(name: "Helvetica Neue", size: 14) ?? .systemFont(ofSize: 14) }
    private var defaultColor: NSColor { .black }

    @Test("plain attributed text yields no spans")
    func plainNoSpans() {
        let attr = NSAttributedString(
            string: "Hello",
            attributes: [.font: baseFont, .foregroundColor: defaultColor])
        let spanned = TextEditorOverlay.spanned(from: attr, defaultColor: defaultColor)
        #expect(spanned.string == "Hello")
        #expect(spanned.spans.isEmpty)
    }

    @Test("a bold + red span survives spanned -> attributed -> spanned")
    func boldColorRoundTrip() {
        let red = RGBAColor(1, 0, 0)
        let source = MTextSpannedText(
            string: "Hello World",
            spans: [MTextFormatSpan(range: NSRange(location: 6, length: 5),
                                    bold: true, color: red)])

        // spanned -> attributed (seed the editor)
        let attr = TextEditorOverlay.attributed(
            from: source, baseFont: baseFont, defaultColor: defaultColor)
        #expect(attr.string == "Hello World")

        // attributed -> spanned (read the editor back)
        let back = TextEditorOverlay.spanned(from: attr, defaultColor: defaultColor)
        #expect(back.string == "Hello World")
        // Exactly one non-plain span over "World".
        let nonPlain = back.spans.filter { !$0.isPlain }
        #expect(nonPlain.count == 1)
        guard let s = nonPlain.first else { Issue.record("no span"); return }
        #expect(s.range == NSRange(location: 6, length: 5))
        #expect(s.bold)
        #expect(!s.italic)
        if let c = s.color {
            #expect(abs(c.r - 1) < 0.01 && abs(c.g) < 0.01 && abs(c.b) < 0.01)
        } else {
            Issue.record("colour lost in round-trip")
        }
    }

    @Test("italic-only attributed run reads back as an italic span")
    func italicSpan() {
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let m = NSMutableAttributedString(
            string: "ab", attributes: [.font: baseFont, .foregroundColor: defaultColor])
        m.addAttribute(.font, value: italicFont, range: NSRange(location: 1, length: 1))

        let back = TextEditorOverlay.spanned(from: m, defaultColor: defaultColor)
        let nonPlain = back.spans.filter { !$0.isPlain }
        #expect(nonPlain.count == 1)
        #expect(nonPlain.first?.italic == true)
        #expect(nonPlain.first?.bold == false)
        #expect(nonPlain.first?.range == NSRange(location: 1, length: 1))
    }

    @Test("default-coloured text yields NO colour span (inherited colour)")
    func defaultColorNotEmitted() {
        // Foreground == defaultColor everywhere → no colour span.
        let m = NSAttributedString(
            string: "xyz",
            attributes: [.font: baseFont, .foregroundColor: defaultColor])
        let back = TextEditorOverlay.spanned(from: m, defaultColor: defaultColor)
        #expect(back.spans.allSatisfy { $0.color == nil })
    }

    @Test("full editor path: attributed -> spanned -> run tree carries formatting")
    func attributedToRunTree() {
        let blue = RGBAColor(0, 0, 1)
        let source = MTextSpannedText(
            string: "plain blue",
            spans: [MTextFormatSpan(range: NSRange(location: 6, length: 4), color: blue)])
        let attr = TextEditorOverlay.attributed(
            from: source, baseFont: baseFont, defaultColor: defaultColor)
        let spanned = TextEditorOverlay.spanned(from: attr, defaultColor: defaultColor)
        let paragraphs = MTextRunConverter.paragraphs(from: spanned)

        let runs = paragraphs[0].inlines.compactMap { inline -> TextRun? in
            if case .run(let r) = inline { return r } else { return nil }
        }
        #expect(runs.count == 2)
        #expect(runs[0].text == "plain " && runs[0].color == nil)
        #expect(runs[1].text == "blue")
        if let c = runs[1].color {
            #expect(abs(c.b - 1) < 0.01 && abs(c.r) < 0.01 && abs(c.g) < 0.01)
        } else {
            Issue.record("blue colour lost")
        }
    }
}
