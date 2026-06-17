//
//  CopyToolTests.swift
//  CADEngineTests
//
//  Drives the COPY modify tool PURELY (no GUI): feeds `ToolInput` events + a
//  read-only `ToolContext` carrying a known selection (a line + a circle) and
//  asserts the COPY contract — that a base→destination pick emits one `.add`
//  per selected entity (a translated COPY, NOT a `.replace` of the original),
//  each carrying the placeholder id and preserving the original's layer/pen/
//  flags, with the geometry translated by the destination delta. Also covers
//  the live preview, the empty-selection no-op, zero-delta rejection, the
//  multi-copy reset after a commit, and cancel/backspace resets.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CopyTool modify (duplicate at offset)")
struct CopyToolTests {

    // MARK: - Fixtures

    /// A selected LINE with distinctive, non-default attrs so attr-preservation is
    /// observable on the copy.
    private static let selectedLine = EntityRecord(
        id: EntityID(11),
        layer: LayerID("walls"),
        pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0)))
    )

    /// A selected CIRCLE with different attrs from the line.
    private static let selectedCircle = EntityRecord(
        id: EntityID(22),
        layer: LayerID("holes"),
        pen: Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1))),
        flags: [.visible, .selected, .construction],
        kind: .circle(CircleData(center: Vector(10, 10), radius: 3))
    )

    /// A `ToolContext` whose `selected` is the line + circle above.
    private func selectionContext() -> ToolContext {
        let sel = [Self.selectedLine, Self.selectedCircle]
        return ToolContext(
            selected: sel,
            entity: { id in sel.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Pulls the ordered `.add` records out of a `.commit` outcome (fails the test
    /// — by returning nil — if the outcome isn't a pure-`.add` commit).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }   // reject .replace/.remove
            records.append(r)
        }
        return records
    }

    // MARK: - Basics

    @Test("title is Copy")
    func title() {
        #expect(CopyTool().title == "Copy")
    }

    @Test("status nudges to select first when nothing is selected")
    func statusEmptySelection() {
        let tool = CopyTool()
        #expect(tool.status == "Select objects to copy first")
    }

    @Test("after fixing a base the status advances to the destination prompt")
    func statusTransitions() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        #expect(tool.status == "Specify destination point")
    }

    // MARK: - Empty-selection no-op

    @Test("a base click with an empty selection is a no-op")
    func emptySelectionNoop() {
        var tool = CopyTool()
        let outcome = tool.handle(.click(Vector(1, 1)), context: .empty)
        #expect(outcome == .none)
        // Still waiting for a base; no destination prompt was entered.
        #expect(tool.status == "Select objects to copy first")
        // A follow-up "destination" click also commits nothing.
        let second = tool.handle(.click(Vector(5, 5)), context: .empty)
        #expect(second == .none)
    }

    // MARK: - Two-click commit emits .add copies (NOT .replace)

    @Test("base then destination emits one .add per selected entity (not .replace)")
    func twoClicksAddCopies() {
        var tool = CopyTool()
        let ctx = selectionContext()
        let base = Vector(0, 0)
        let dest = Vector(5, 7)

        let first = tool.handle(.click(base), context: ctx)
        #expect(first == .none)   // first click only fixes the base

        let outcome = tool.handle(.click(dest), context: ctx)
        let records = addedRecords(outcome)
        #expect(records != nil)
        #expect(records?.count == 2)   // one copy per selected entity, all .add
    }

    @Test("copied records carry the placeholder id (app re-mints on add)")
    func copiesUsePlaceholderID() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let records = addedRecords(tool.handle(.click(Vector(2, 3)), context: ctx))
        #expect(records != nil)
        for r in records ?? [] {
            #expect(r.id == .placeholder)
            #expect(r.id == EntityID(0))
        }
    }

    @Test("copy geometry is translated by the destination delta")
    func copyGeometryTranslated() {
        var tool = CopyTool()
        let ctx = selectionContext()
        let base = Vector(1, 1)
        let dest = Vector(4, 6)   // delta = (3, 5)
        let delta = dest - base

        _ = tool.handle(.click(base), context: ctx)
        let records = addedRecords(tool.handle(.click(dest), context: ctx))
        #expect(records?.count == 2)

        // The line copy: both endpoints translated by delta.
        guard case .line(let lineCopy)? = records?[0].kind else {
            Issue.record("expected the first copy to be a line")
            return
        }
        let origLine = LineData(start: Vector(0, 0), end: Vector(4, 0))
        #expect(lineCopy.start == origLine.start + delta)
        #expect(lineCopy.end == origLine.end + delta)

        // The circle copy: center translated by delta, radius unchanged (pure move).
        guard case .circle(let circleCopy)? = records?[1].kind else {
            Issue.record("expected the second copy to be a circle")
            return
        }
        #expect(circleCopy.center == Vector(10, 10) + delta)
        #expect(circleCopy.radius == 3)
    }

    @Test("originals are NOT modified — only .add edits, never .replace/.remove")
    func originalsUntouched() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(9, 0)), context: ctx)
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit outcome")
            return
        }
        // Every edit must be an .add; no .replace or .remove against the originals.
        for edit in edits {
            switch edit {
            case .add:
                break
            case .replace, .remove:
                Issue.record("Copy must not replace/remove originals; got \(edit)")
            }
        }
    }

    @Test("each copy preserves the original's layer, pen, and flags")
    func attributesPreserved() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let records = addedRecords(tool.handle(.click(Vector(5, 5)), context: ctx))
        #expect(records?.count == 2)

        // Line copy mirrors the line original's attrs.
        #expect(records?[0].layer == Self.selectedLine.layer)
        #expect(records?[0].pen == Self.selectedLine.pen)
        #expect(records?[0].flags == Self.selectedLine.flags)

        // Circle copy mirrors the circle original's attrs (distinct from the line's).
        #expect(records?[1].layer == Self.selectedCircle.layer)
        #expect(records?[1].pen == Self.selectedCircle.pen)
        #expect(records?[1].flags == Self.selectedCircle.flags)
    }

    // MARK: - Zero-delta is ignored

    @Test("a destination equal to the base (zero delta) commits nothing")
    func zeroDeltaIgnored() {
        var tool = CopyTool()
        let ctx = selectionContext()
        let p = Vector(3, 3)
        _ = tool.handle(.click(p), context: ctx)
        let outcome = tool.handle(.click(p), context: ctx)   // same point
        #expect(outcome == .none)
        // Still in the destination state (waiting for a real offset).
        #expect(tool.status == "Specify destination point")
    }

    // MARK: - Preview

    @Test("preview is empty before a base is fixed")
    func previewEmptyInitially() {
        var tool = CopyTool()
        let ctx = selectionContext()
        #expect(tool.preview.isEmpty)
        // A move with no base still yields nothing.
        _ = tool.handle(.move(Vector(2, 2)), context: ctx)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the base a move produces a preview for each selected entity")
    func previewAfterBase() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let outcome = tool.handle(.move(Vector(5, 0)), context: ctx)
        #expect(outcome == .preview)
        // Two selected entities → at least two resolved preview polylines
        // (a line resolves to 1; a circle to 1).
        #expect(tool.preview.count >= 2)
    }

    @Test("preview reflects the cursor offset (line copy endpoints shift by it)")
    func previewFollowsCursor() {
        var tool = CopyTool()
        // Single-line selection makes the preview deterministic (one polyline).
        let line = Self.selectedLine
        let ctx = ToolContext(
            selected: [line],
            entity: { _ in line },
            gridSpacing: nil
        )
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)   // base at origin
        _ = tool.handle(.move(Vector(2, 3)), context: ctx)    // offset (2, 3)
        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        // Original line was (0,0)→(4,0); shifted by (2,3) → (2,3)→(6,3).
        #expect(poly.points.first == Vector(2, 3))
        #expect(poly.points.last == Vector(6, 3))
        // Preview uses the shared tool-preview pen.
        #expect(poly.pen == .toolPreview)
    }

    // MARK: - Multi-copy: stays active after a commit

    @Test("after a commit the tool resets to picking a base (multi-copy)")
    func multiCopyResets() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let first = tool.handle(.click(Vector(5, 0)), context: ctx)
        #expect(addedRecords(first)?.count == 2)
        // Reset to base picking, but the captured selection is retained so the
        // status shows the base prompt (not the "select first" nudge).
        #expect(tool.status == "Specify base point")

        // A second base→dest run copies the SAME selection again.
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let second = tool.handle(.click(Vector(0, 8)), context: ctx)
        let records = addedRecords(second)
        #expect(records?.count == 2)
        guard case .line(let l)? = records?[0].kind else {
            Issue.record("expected a line copy on the second run")
            return
        }
        #expect(l.start == Vector(0, 8))   // (0,0) shifted by (0,8)
    }

    // MARK: - Cancel / backspace

    @Test("cancel discards the pending base/preview and finishes")
    func cancelResets() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.move(Vector(5, 5)), context: ctx)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        // Captured set dropped → back to the "select first" nudge.
        #expect(tool.status == "Select objects to copy first")
    }

    @Test("backspace steps the base back without committing")
    func backspaceRewinds() {
        var tool = CopyTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(2, 2)), context: ctx)
        #expect(tool.status == "Specify destination point")
        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .preview)
        // Back to picking a base; the captured selection is kept (base prompt).
        #expect(tool.status == "Specify base point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with no base fixed is a no-op")
    func backspaceNoop() {
        var tool = CopyTool()
        let ctx = selectionContext()
        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Typed coordinate (.value) parity with .click

    @Test(".value(p) is treated exactly like .click(p): typed base + destination adds the same copies")
    func typedValueMatchesClick() {
        let base = Vector(1, 1)
        let dest = Vector(6, 4)

        var typed = CopyTool()
        let ctxA = selectionContext()
        let typedFirst = typed.handle(.value(base), context: ctxA)
        #expect(typedFirst == .none)   // a typed base only fixes the base point
        #expect(typed.status == "Specify destination point")
        let typedOutcome = typed.handle(.value(dest), context: ctxA)

        var clicked = CopyTool()
        let ctxB = selectionContext()
        _ = clicked.handle(.click(base), context: ctxB)
        let clickedOutcome = clicked.handle(.click(dest), context: ctxB)

        // Same commit: the typed-coordinate path adds identical translated copies.
        #expect(typedOutcome == clickedOutcome)
        #expect(addedRecords(typedOutcome)?.count == 2)
    }

    @Test(".value with an empty selection is still a no-op (nothing to copy)")
    func typedValueEmptySelectionNoOp() {
        var tool = CopyTool()
        let outcome = tool.handle(.value(Vector(5, 5)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Select objects to copy first")
    }
}
