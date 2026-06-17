//
//  MultiLeaderToolTests.swift
//  CADEngineTests
//
//  Tests for `MultiLeaderTool` (the MULTILEADER / MLEADER annotation-callout draw
//  tool, ML-W2). Drive `.click`/`.move`/`.commit`/`.cancel`/`.backspace` with NO GUI
//  (the pure `Tool` contract), mirroring `LeaderToolTests`:
//   - clicking N vertices then `.commit` commits a `.multileader` of those vertices;
//   - the arrow flag / arrow size config carries onto the committed multileader;
//   - the landing config (`landingDistance` / `doglegEnabled`) carries through;
//   - a non-empty `annotationText` produces an attached `.text` at the last vertex;
//   - a leg of fewer than 2 vertices finishes WITHOUT committing;
//   - the preview rubber-bands to the cursor; backspace drops the last vertex;
//   - cancel resets the tool; the tool resets after a commit.
//  Plus registry wiring: `.multileader` mints the tool, has the title "Multileader",
//  and the "mleader" command alias resolves to it.
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

@Suite("multileader draw tool")
struct MultiLeaderToolTests {

    /// Drains the first `.add` multileader out of a tool outcome.
    private func addedMultiLeader(_ outcome: ToolOutcome) -> MultiLeaderData? {
        guard case .commit(let edits) = outcome else { return nil }
        for e in edits {
            if case .add(let rec) = e, case .multileader(let d) = rec.kind { return d }
        }
        return nil
    }

    @Test("clicking vertices then commit builds a multileader of those vertices")
    func clicksThenCommit() {
        var tool = MultiLeaderTool(arrowSize: 3, hasArrow: true)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(13, 4)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        let d = addedMultiLeader(out)
        #expect(d != nil)
        #expect(d!.vertices.count == 3)
        #expect(abs(d!.vertices[0].x - 0) < 1e-9)
        #expect(abs(d!.vertices[2].x - 13) < 1e-9 && abs(d!.vertices[2].y - 4) < 1e-9)
        #expect(d!.hasArrow == true)
        #expect(abs(d!.arrowSize - 3) < 1e-9)
        #expect(d!.annotation == nil)   // no annotation text configured
    }

    @Test("the landing/dogleg config is stamped onto the committed multileader")
    func landingConfigCarriesThrough() {
        // Defaults: landingDistance 2.0, doglegEnabled true.
        var def = MultiLeaderTool()
        _ = def.handle(.click(Vector(0, 0)), context: .empty)
        _ = def.handle(.click(Vector(10, 0)), context: .empty)
        let d0 = addedMultiLeader(def.handle(.commit, context: .empty))
        #expect(d0 != nil)
        #expect(abs(d0!.landingDistance - 2.0) < 1e-9)
        #expect(d0!.doglegEnabled == true)

        // Custom: a longer landing, dogleg disabled.
        var custom = MultiLeaderTool(landingDistance: 5.5, doglegEnabled: false)
        _ = custom.handle(.click(Vector(0, 0)), context: .empty)
        _ = custom.handle(.click(Vector(10, 0)), context: .empty)
        let d1 = addedMultiLeader(custom.handle(.commit, context: .empty))
        #expect(d1 != nil)
        #expect(abs(d1!.landingDistance - 5.5) < 1e-9)
        #expect(d1!.doglegEnabled == false)
    }

    @Test("a typed coordinate places a vertex like a click")
    func typedValueVertex() {
        var tool = MultiLeaderTool()
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(5, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        #expect(addedMultiLeader(out)?.vertices.count == 2)
    }

    @Test("a configured annotation text becomes an attached .text at the last vertex")
    func annotationAttached() {
        var tool = MultiLeaderTool(arrowSize: 2, hasArrow: true,
                                   annotationText: "NOTE", textHeight: 2.5)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        let d = addedMultiLeader(out)
        #expect(d != nil)
        guard let ann = d?.annotation, case .text(let td) = ann else {
            Issue.record("expected an attached .text annotation"); return
        }
        #expect(td.text == "NOTE")
        #expect(abs(td.height - 2.5) < 1e-9)
        // Anchored near the last vertex (x ≈ 10, offset a little along +X).
        #expect(td.position.x >= 10 - 1e-9)
    }

    @Test("a multileader of fewer than 2 vertices finishes WITHOUT committing")
    func tooFewVerticesNoCommit() {
        var tool = MultiLeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        // A single vertex is not a usable multileader: finished, no commit.
        #expect(out == .finished)
        #expect(addedMultiLeader(out) == nil)
    }

    @Test("the preview rubber-bands from the clicked vertices to the cursor")
    func previewRubberBands() {
        var tool = MultiLeaderTool()
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
        var tool = MultiLeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(20, 0)), context: .empty)
        _ = tool.handle(.backspace, context: .empty)   // drop (20,0)
        let out = tool.handle(.commit, context: .empty)
        let d = addedMultiLeader(out)
        #expect(d?.vertices.count == 2)
        #expect(abs(d!.vertices.last!.x - 10) < 1e-9)
    }

    @Test("a duplicate click on the last vertex is ignored (no zero-length leg)")
    func duplicateClickIgnored() {
        var tool = MultiLeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // duplicate
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let out = tool.handle(.commit, context: .empty)
        #expect(addedMultiLeader(out)?.vertices.count == 2)
    }

    @Test("cancel resets the tool (no commit, fresh next multileader)")
    func cancelResets() {
        var tool = MultiLeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let out = tool.handle(.cancel, context: .empty)
        #expect(out == .finished)
        #expect(tool.preview.isEmpty)
        // A fresh multileader starts cleanly after cancel.
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(addedMultiLeader(tool.handle(.commit, context: .empty))?.vertices.count == 2)
    }

    @Test("the tool resets after a commit so the next multileader starts fresh")
    func resetsAfterCommit() {
        var tool = MultiLeaderTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.commit, context: .empty)
        #expect(tool.preview.isEmpty)                  // reset
        // The next multileader is independent of the first.
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)
        _ = tool.handle(.click(Vector(6, 6)), context: .empty)
        let d = addedMultiLeader(tool.handle(.commit, context: .empty))
        #expect(d?.vertices.count == 2)
        #expect(abs(d!.vertices[0].x - 5) < 1e-9)
    }

    // MARK: - Registry wiring

    @Test("the .multileader kind mints a MultiLeaderTool with the matching title")
    func kindIsWired() {
        #expect(ToolKind.multileader.title == "Multileader")
        let tool = ToolKind.multileader.makeTool()
        #expect(tool != nil, "ToolKind.multileader minted a nil Tool")
        #expect(tool?.title == "Multileader")
        #expect(tool is MultiLeaderTool)
    }

    @Test("the mleader command alias resolves to .multileader")
    func aliasResolves() {
        #expect(ToolSuggester.resolve(command: "mleader") == .multileader)
        #expect(ToolSuggester.resolve(command: "MLEADER") == .multileader)
        #expect(ToolSuggester.resolve(command: "mlead") == .multileader)
        // The title also resolves exactly.
        #expect(ToolSuggester.resolve(command: "multileader") == .multileader)
    }
}
