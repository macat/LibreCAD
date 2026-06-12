//
//  MoveToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Move tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` (with a known selection) to `MoveTool` and asserts
//  the commit shape (one `.replace` per selected id, geometry translated by
//  `destination − base`), the live preview (present + translated), the
//  empty-selection no-op, the cancel/backspace resets, and that a zero-delta move
//  is ignored.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("MoveTool interactive modify")
struct MoveToolTests {

    // MARK: - Fixtures

    /// A line from (0,0) to (10,0), id 1.
    private static let lineID = EntityID(1)
    private func lineRecord() -> EntityRecord {
        EntityRecord(id: Self.lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    /// A circle centered at (5,5) with radius 2, id 2.
    private static let circleID = EntityID(2)
    private func circleRecord() -> EntityRecord {
        EntityRecord(id: Self.circleID, kind: .circle(CircleData(center: Vector(5, 5), radius: 2)))
    }

    /// A `ToolContext` whose selection is the line + circle (the known fixture).
    private func selectionContext() -> ToolContext {
        let records = [lineRecord(), circleRecord()]
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    /// An empty `ToolContext` (no selection).
    private func emptyContext() -> ToolContext { .empty }

    /// Pulls the `.replace`d kinds out of a `.commit`, keyed by id (fails the test
    /// if the outcome isn't a `.commit` of only `.replace` edits).
    private func replacedKinds(_ outcome: ToolOutcome) -> [EntityID: EntityKind]? {
        guard case .commit(let edits) = outcome else { return nil }
        var out: [EntityID: EntityKind] = [:]
        for edit in edits {
            guard case .replace(let id, let kind) = edit else { return nil }
            out[id] = kind
        }
        return out
    }

    // MARK: - Metadata / status

    @Test("title is Move")
    func title() {
        #expect(MoveTool().title == "Move")
    }

    @Test("with a selection the status walks base → destination")
    func statusWithSelection() {
        var tool = MoveTool()
        let ctx = selectionContext()
        // Before any click the status reflects the (current) empty-internal-state;
        // the tool only learns the selection once the base is picked, so the first
        // prompt is the select-first hint until then.
        #expect(tool.status == "Select objects to move first")
        _ = tool.handle(.click(Vector(2, 2)), context: ctx)
        #expect(tool.status == "Specify destination")
    }

    @Test("empty selection keeps the select-first status")
    func statusEmptySelection() {
        let tool = MoveTool()
        #expect(tool.status == "Select objects to move first")
    }

    // MARK: - Two-click commit

    @Test("base + destination commits one .replace per selected id, translated by (dest − base)")
    func twoClicksCommitTranslated() {
        var tool = MoveTool()
        let ctx = selectionContext()
        let base = Vector(2, 2)
        let dest = Vector(5, 9)
        let delta = dest - base   // (3, 7)

        let first = tool.handle(.click(base), context: ctx)
        #expect(first == .none)   // first click only fixes the base point

        let outcome = tool.handle(.click(dest), context: ctx)
        guard let kinds = replacedKinds(outcome) else {
            Issue.record("expected a .commit of only .replace edits"); return
        }
        // One replace per selected entity (line + circle), keyed by their ids.
        #expect(kinds.count == 2)

        // Line endpoints each shift by delta.
        guard case .line(let movedLine)? = kinds[Self.lineID] else {
            Issue.record("line was not replaced with a line"); return
        }
        #expect(movedLine.start == Vector(0, 0) + delta)   // (3, 7)
        #expect(movedLine.end == Vector(10, 0) + delta)    // (13, 7)

        // Circle center shifts by delta; radius unchanged.
        guard case .circle(let movedCircle)? = kinds[Self.circleID] else {
            Issue.record("circle was not replaced with a circle"); return
        }
        #expect(movedCircle.center == Vector(5, 5) + delta) // (8, 12)
        #expect(movedCircle.radius == 2)
    }

    @Test("commit ends the run: tool resets to pick-base for the next move")
    func commitResetsState() {
        var tool = MoveTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(2, 2)), context: ctx)
        _ = tool.handle(.click(Vector(5, 9)), context: ctx)
        // After the commit the tool is back at the initial state.
        #expect(tool.status == "Select objects to move first")
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Preview

    @Test("preview is empty before the base point is fixed")
    func previewEmptyBeforeBase() {
        var tool = MoveTool()
        let ctx = selectionContext()
        _ = tool.handle(.move(Vector(3, 3)), context: ctx)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview shows the selection translated to the cursor after the base is fixed")
    func previewTranslated() {
        var tool = MoveTool()
        let ctx = selectionContext()
        let base = Vector(0, 0)
        _ = tool.handle(.click(base), context: ctx)

        let cursor = Vector(4, 1)
        let outcome = tool.handle(.move(cursor), context: ctx)
        #expect(outcome == .preview)

        let preview = tool.preview
        #expect(!preview.isEmpty)

        // The line preview (a single 2-point polyline) is translated by cursor−base.
        let delta = cursor - base
        let linePreview = preview.first { $0.points.count == 2 }
        #expect(linePreview != nil)
        #expect(linePreview?.points.first == Vector(0, 0) + delta)   // (4, 1)
        #expect(linePreview?.points.last == Vector(10, 0) + delta)   // (14, 1)

        // Every preview polyline uses the shared preview pen.
        #expect(preview.allSatisfy { $0.pen == .toolPreview })

        // The circle preview (a closed ring) is present and recentered: its
        // centroid sits near the translated center (8 → no; original center (5,5)
        // + delta (4,1) = (9, 6)).
        let ring = preview.first { $0.closed }
        #expect(ring != nil)
        if let ring {
            let n = Double(ring.points.count)
            let cx = ring.points.reduce(0.0) { $0 + $1.x } / n
            let cy = ring.points.reduce(0.0) { $0 + $1.y } / n
            #expect(abs(cx - 9) < 1e-6)
            #expect(abs(cy - 6) < 1e-6)
        }
    }

    // MARK: - Empty selection no-op

    @Test("empty selection: clicks and moves are no-ops, no commit, no preview")
    func emptySelectionNoOp() {
        var tool = MoveTool()
        let ctx = emptyContext()

        let click1 = tool.handle(.click(Vector(2, 2)), context: ctx)
        #expect(click1 == .none)
        #expect(tool.preview.isEmpty)
        // Still in the initial state (the click did not fix a base).
        #expect(tool.status == "Select objects to move first")

        let move = tool.handle(.move(Vector(3, 3)), context: ctx)
        #expect(move == .none)
        #expect(tool.preview.isEmpty)

        // A "destination" click without a base also does nothing.
        let click2 = tool.handle(.click(Vector(9, 9)), context: ctx)
        #expect(click2 == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Cancel / backspace reset

    @Test("cancel discards the run, resets state, and reports .finished")
    func cancelResets() {
        var tool = MoveTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(2, 2)), context: ctx)
        _ = tool.handle(.move(Vector(4, 4)), context: ctx)
        #expect(!tool.preview.isEmpty)   // mid-run preview exists

        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to move first")
    }

    @Test("backspace steps pickingDest → pickingBase (clears the in-progress preview)")
    func backspaceStepsBack() {
        var tool = MoveTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(2, 2)), context: ctx)
        _ = tool.handle(.move(Vector(4, 4)), context: ctx)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .preview)
        // Back at base-pick: no cursor → no preview. Selection is retained, so the
        // status prompts for a (new) base point, not the select-first hint.
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify base point")

        // Re-picking a base then a destination still commits correctly.
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let outcome2 = tool.handle(.click(Vector(1, 0)), context: ctx)
        let kinds = replacedKinds(outcome2)
        #expect(kinds?.count == 2)
    }

    @Test("backspace in pickingBase is a no-op")
    func backspaceInBaseNoOp() {
        var tool = MoveTool()
        let ctx = selectionContext()
        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Zero delta ignored

    @Test("zero-delta move (destination == base) is ignored, no commit")
    func zeroDeltaIgnored() {
        var tool = MoveTool()
        let ctx = selectionContext()
        let base = Vector(3, 3)
        _ = tool.handle(.click(base), context: ctx)

        // Second click at the same point → no commit, tool stays in pickingDest.
        let outcome = tool.handle(.click(base), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify destination")

        // A real destination afterwards still commits.
        let real = tool.handle(.click(Vector(8, 3)), context: ctx)
        #expect(replacedKinds(real)?.count == 2)
    }
}
