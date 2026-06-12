//
//  TextToolTests.swift
//  CADEngineTests
//
//  Drives the Text authoring tool PURELY (no GUI / no NSTextView): feeds
//  `ToolInput` events + a read-only `ToolContext` to `TextTool` and asserts:
//    - a single-line string commits a `.text(TextData)` with the typed string,
//      the clicked insertion point, the default "Standard" style, and the height;
//    - a multi-line string commits a `.mtext(MTextData)` with one paragraph per
//      line;
//    - editing an existing entity yields a `.replace(id, …)` (not an `.add`);
//    - empty / whitespace-only text creates nothing;
//    - the placeholder id, status prompts, and click/cancel/commit behavior.
//
//  The NSTextView overlay itself is GUI and is verified by the user; this suite
//  unit-tests the pure tool logic the overlay drives.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("TextTool interactive authoring")
struct TextToolTests {

    // MARK: - Helpers

    /// Pulls the single `TextData` out of a one-edit `.add` `.text` commit (fails
    /// the assertion path by returning `nil` otherwise).
    private func committedText(_ outcome: ToolOutcome) -> TextData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .text(let d) = record.kind else { return nil }
        return d
    }

    /// Pulls the single `MTextData` out of a one-edit `.add` `.mtext` commit.
    private func committedMText(_ outcome: ToolOutcome) -> MTextData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .mtext(let d) = record.kind else { return nil }
        return d
    }

    /// Runs a fresh authoring tool through click(point) → commit with `text`.
    private func authorCommit(text: String, at point: Vector,
                              height: Double = TextTool.defaultHeight) -> ToolOutcome {
        var tool = TextTool(text: text, height: height)
        _ = tool.handle(.click(point), context: .empty)
        return tool.handle(.commit, context: .empty)
    }

    // MARK: - Title / status

    @Test("title is Text")
    func title() {
        #expect(TextTool().title == "Text")
    }

    @Test("status reflects the awaiting-point then placed states")
    func statusProgresses() {
        var tool = TextTool()
        #expect(tool.status == "Specify text insertion point")
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        #expect(tool.status == "Type the text, then press Return")
    }

    @Test("preview is always empty (the inline editor is the live preview)")
    func previewEmpty() {
        var tool = TextTool(text: "hi")
        #expect(tool.preview.isEmpty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Click sets the insertion point

    @Test("a click sets the insertion point and stays active (preview outcome)")
    func clickSetsInsertionPoint() {
        var tool = TextTool()
        #expect(tool.insertionPoint == nil)
        let p = Vector(4, 9)
        let outcome = tool.handle(.click(p), context: .empty)
        #expect(outcome == .preview)
        #expect(tool.insertionPoint == p)
    }

    @Test("a re-click before commit moves the insertion point")
    func reclickMovesPoint() {
        var tool = TextTool()
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        _ = tool.handle(.click(Vector(7, 3)), context: .empty)
        #expect(tool.insertionPoint == Vector(7, 3))
    }

    // MARK: - Single-line → .text

    @Test("single-line input commits a .text with the typed string at the clicked point")
    func singleLineCommitsText() {
        let p = Vector(10, 20)
        let outcome = authorCommit(text: "Hello CAD", at: p)
        let data = committedText(outcome)
        #expect(data != nil)
        #expect(data?.text == "Hello CAD")
        #expect(data?.position == p)
    }

    @Test("committed .text carries the default Standard (Helvetica Neue) style + height")
    func textCarriesStyleAndHeight() {
        let outcome = authorCommit(text: "Sized", at: Vector(0, 0), height: 5)
        let data = committedText(outcome)
        #expect(data?.styleName == "Standard")
        #expect(data?.styleName == TextTool.standardStyleName)
        #expect(data?.height == 5)
    }

    @Test("committed .text record carries the placeholder id (app re-mints on add)")
    func textPlaceholderID() {
        var tool = TextTool(text: "X")
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit"); return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
    }

    // MARK: - Multi-line → .mtext

    @Test("multi-line input commits an .mtext with one paragraph per line")
    func multiLineCommitsMText() {
        let p = Vector(3, 4)
        let outcome = authorCommit(text: "line one\nline two\nline three", at: p)
        let data = committedMText(outcome)
        #expect(data != nil)
        #expect(data?.position == p)
        #expect(data?.paragraphs.count == 3)
    }

    @Test("each .mtext paragraph holds the line's text as a single run")
    func mtextParagraphRuns() {
        let outcome = authorCommit(text: "alpha\nbeta", at: Vector(0, 0))
        guard let data = committedMText(outcome) else {
            Issue.record("expected an .mtext commit"); return
        }
        func runText(_ para: MTextParagraph) -> String? {
            guard para.inlines.count == 1, case .run(let r) = para.inlines[0] else { return nil }
            return r.text
        }
        #expect(runText(data.paragraphs[0]) == "alpha")
        #expect(runText(data.paragraphs[1]) == "beta")
    }

    @Test("committed .mtext carries the default Standard style + height")
    func mtextCarriesStyleAndHeight() {
        let outcome = authorCommit(text: "a\nb", at: Vector(0, 0), height: 7)
        let data = committedMText(outcome)
        #expect(data?.styleName == "Standard")
        #expect(data?.height == 7)
    }

    @Test("a single line (no newline) stays .text, not .mtext")
    func singleLineIsNotMText() {
        let outcome = authorCommit(text: "just one line", at: Vector(0, 0))
        #expect(committedText(outcome) != nil)
        #expect(committedMText(outcome) == nil)
    }

    @Test("CRLF / CR newlines are normalized and still promote to .mtext")
    func crlfNormalized() {
        let outcome = authorCommit(text: "p\r\nq\rr", at: Vector(0, 0))
        let data = committedMText(outcome)
        #expect(data?.paragraphs.count == 3)
    }

    // MARK: - Editing an existing entity → .replace

    @Test("editing an existing entity commits a .replace (not an .add)")
    func editingCommitsReplace() {
        let id = EntityID(77)
        var tool = TextTool(editing: id, at: Vector(5, 5), text: "edited", height: 3)
        // Already placed — commit directly.
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1 else {
            Issue.record("expected a single-edit commit"); return
        }
        guard case .replace(let editID, let kind) = edits[0] else {
            Issue.record("expected a .replace edit"); return
        }
        #expect(editID == id)
        guard case .text(let d) = kind else {
            Issue.record("expected a .text kind"); return
        }
        #expect(d.text == "edited")
        #expect(d.position == Vector(5, 5))
        #expect(d.height == 3)
    }

    @Test("editing with a multi-line string replaces with an .mtext kind")
    func editingMultiLineReplacesMText() {
        let id = EntityID(5)
        var tool = TextTool(editing: id, at: Vector(0, 0), text: "x\ny")
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let editID, let kind) = edits[0] else {
            Issue.record("expected a .replace commit"); return
        }
        #expect(editID == id)
        guard case .mtext = kind else {
            Issue.record("expected an .mtext kind for multi-line edit"); return
        }
    }

    @Test("an editing tool starts already placed at the seeded point")
    func editingStartsPlaced() {
        let tool = TextTool(editing: EntityID(1), at: Vector(9, 8), text: "seed")
        #expect(tool.insertionPoint == Vector(9, 8))
    }

    // MARK: - Empty text creates nothing

    @Test("committing empty text creates no entity (just finishes)")
    func emptyTextCommitsNothing() {
        var tool = TextTool(text: "")
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
    }

    @Test("committing whitespace-only text creates no entity")
    func whitespaceOnlyCommitsNothing() {
        var tool = TextTool(text: "   \n\t ")
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
    }

    @Test("committing with no insertion point creates nothing")
    func noPointCommitsNothing() {
        var tool = TextTool(text: "orphan")
        // No click → no placement.
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
    }

    // MARK: - Cancel / move / backspace

    @Test("cancel ends the run (.finished)")
    func cancelFinishes() {
        var tool = TextTool(text: "discarded")
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
    }

    @Test("move and backspace are no-ops (the editor owns the string)")
    func moveAndBackspaceNoops() {
        var tool = TextTool(text: "t")
        #expect(tool.handle(.move(Vector(1, 1)), context: .empty) == .none)
        #expect(tool.handle(.backspace, context: .empty) == .none)
    }

    @Test("an invalid pick is ignored (no insertion point set)")
    func invalidPickIgnored() {
        var tool = TextTool(text: "t")
        let outcome = tool.handle(.click(.invalid), context: .empty)
        #expect(outcome == .none)
        #expect(tool.insertionPoint == nil)
    }

    // MARK: - Default record attributes (draw-record defaults)

    @Test("committed .text record uses the standard draw-record defaults")
    func textRecordDefaults() {
        var tool = TextTool(text: "X")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit"); return
        }
        #expect(record.layer == .zero)
        #expect(record.pen == .byLayer)
        #expect(record.flags == .default)
    }
}
