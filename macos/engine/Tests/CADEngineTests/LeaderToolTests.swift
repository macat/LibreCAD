//
//  LeaderToolTests.swift
//  CADEngineTests
//
//  Tests for `LeaderTool` (the LEADER annotation-callout draw tool, feature-catalog
//  #F2). Drive `.click`/`.move`/`.commit`/`.cancel`/`.backspace` with NO GUI (the
//  pure `Tool` contract):
//   - clicking N vertices then `.commit` commits a `.leader` of those vertices;
//   - the arrow flag / arrow size config carries onto the committed leader;
//   - a non-empty `annotationText` produces an attached `.text` at the last vertex;
//   - a path of fewer than 2 vertices finishes WITHOUT committing;
//   - the preview rubber-bands to the cursor; backspace drops the last vertex;
//   - cancel resets the tool.
//
//  Uniquely namespaced so it does not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("leader draw tool")
struct LeaderToolTests {

    /// Drains the first `.add` leader out of a tool outcome.
    private func addedLeader(_ outcome: ToolOutcome) -> LeaderData? {
        guard case .commit(let edits) = outcome else { return nil }
        for e in edits {
            if case .add(let rec) = e, case .leader(let d) = rec.kind { return d }
        }
        return nil
    }

    @Test("clicking vertices then commit builds a leader of those vertices")
    func clicksThenCommit() {
        var tool = LeaderTool(arrowSize: 3, hasArrow: true)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(13, 4)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        let d = addedLeader(out)
        #expect(d != nil)
        #expect(d!.vertices.count == 3)
        #expect(abs(d!.vertices[0].x - 0) < 1e-9)
        #expect(abs(d!.vertices[2].x - 13) < 1e-9 && abs(d!.vertices[2].y - 4) < 1e-9)
        #expect(d!.hasArrow == true)
        #expect(abs(d!.arrowSize - 3) < 1e-9)
        #expect(d!.annotation == nil)   // no annotation text configured
    }

    @Test("a typed coordinate places a vertex like a click")
    func typedValueVertex() {
        var tool = LeaderTool()
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(5, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        #expect(addedLeader(out)?.vertices.count == 2)
    }

    @Test("a configured annotation text becomes an attached .text at the last vertex")
    func annotationAttached() {
        var tool = LeaderTool(arrowSize: 2, hasArrow: true,
                              annotationText: "NOTE", textHeight: 2.5)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        let d = addedLeader(out)
        #expect(d != nil)
        guard let ann = d?.annotation, case .text(let td) = ann else {
            Issue.record("expected an attached .text annotation"); return
        }
        #expect(td.text == "NOTE")
        #expect(abs(td.height - 2.5) < 1e-9)
        // Anchored near the last vertex (x ≈ 10, offset a little along +X).
        #expect(td.position.x >= 10 - 1e-9)
    }

    @Test("a leader of fewer than 2 vertices finishes WITHOUT committing")
    func tooFewVerticesNoCommit() {
        var tool = LeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        // A single vertex is not a usable leader: finished, no commit.
        #expect(out == .finished)
        #expect(addedLeader(out) == nil)
    }

    @Test("the preview rubber-bands from the clicked vertices to the cursor")
    func previewRubberBands() {
        var tool = LeaderTool()
        #expect(tool.preview.isEmpty)                           // nothing yet
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)                          // first vertex → cursor
        let pts = tool.preview[0].points
        #expect(pts.count == 2)
        #expect(abs(pts[0].x - 0) < 1e-9 && abs(pts[1].x - 5) < 1e-9)
    }

    @Test("backspace drops the last placed vertex")
    func backspaceDropsVertex() {
        var tool = LeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(20, 0)), context: .empty)
        _ = tool.handle(.backspace, context: .empty)   // drop (20,0)
        let out = tool.handle(.commit, context: .empty)
        let d = addedLeader(out)
        #expect(d?.vertices.count == 2)
        #expect(abs(d!.vertices.last!.x - 10) < 1e-9)
    }

    @Test("a duplicate click on the last vertex is ignored (no zero-length leg)")
    func duplicateClickIgnored() {
        var tool = LeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // duplicate
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        #expect(addedLeader(out)?.vertices.count == 2)
    }

    @Test("cancel resets the tool (no commit, fresh next leader)")
    func cancelResets() {
        var tool = LeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let out = tool.handle(.cancel, context: .empty)
        #expect(out == .finished)
        #expect(tool.preview.isEmpty)
        // A fresh leader starts cleanly after cancel.
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(addedLeader(tool.handle(.commit, context: .empty))?.vertices.count == 2)
    }

    @Test("the tool resets after a commit so the next leader starts fresh")
    func resetsAfterCommit() {
        var tool = LeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.commit, context: .empty)
        #expect(tool.preview.isEmpty)                  // reset
        // The next leader is independent of the first.
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)
        _ = tool.handle(.click(Vector(6, 6)), context: .empty)
        let d = addedLeader(tool.handle(.commit, context: .empty))
        #expect(d?.vertices.count == 2)
        #expect(abs(d!.vertices[0].x - 5) < 1e-9)
    }
}
