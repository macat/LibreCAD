//
//  MLineToolTests.swift
//  CADEngineTests
//
//  Drives `MLineTool` headlessly (no GUI) through `.click`/`.move`/`.commit`
//  sequences and asserts the committed geometry is a correct multiline: ONE
//  `.mline` carrying exactly the clicked vertices as its path, plus the tool's
//  default STANDARD-like element fan / justification / scale; that `Close`
//  (clicking the start vertex) sets the closed flag; that backspace drops a vertex;
//  that Esc cancels without committing; that the live preview is non-empty mid-run;
//  and that a single-vertex commit is a safe no-op.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("MLineTool")
struct MLineToolTests {

    // MARK: - Helpers

    /// Drives a fresh tool through `clicks`, optionally finishing with `.commit`,
    /// and returns the final outcome plus the committed `MLineData` (if any).
    private func run(clicks: [Vector], finishWithCommit: Bool = true)
        -> (outcome: ToolOutcome, data: MLineData?) {
        var tool = MLineTool()
        var outcome: ToolOutcome = .none
        for p in clicks { outcome = tool.handle(.click(p), context: .empty) }
        if finishWithCommit { outcome = tool.handle(.commit, context: .empty) }
        return (outcome, Self.mlineData(from: outcome))
    }

    /// Extracts the single committed `.add(.mline)` payload from an outcome, or `nil`
    /// if the outcome is not exactly one `.mline` `.add`.
    private static func mlineData(from outcome: ToolOutcome) -> MLineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .mline(let data) = record.kind else { return nil }
        return data
    }

    // MARK: - Accumulating vertices → one .mline with default style

    @Test func threeClicksCommitOneMLineWithClickedVertices() {
        let pts = [Vector(0, 0), Vector(4, 0), Vector(4, 3)]
        let (outcome, data) = run(clicks: pts)

        // Exactly one .add edit (the multiline).
        if case .commit(let edits) = outcome {
            #expect(edits.count == 1, "a multiline commits exactly one .add edit")
        } else {
            Issue.record("expected a .commit outcome, got \(outcome)")
        }

        guard let data else {
            Issue.record("expected a committed .mline, got none")
            return
        }
        // The clicked vertices ARE the multiline path, in order.
        #expect(data.vertices == pts, "the multiline path is the clicked vertices in order")
        #expect(!data.closed, "a Return-committed multiline is open by default")
    }

    @Test func defaultStyleIsStandardLike() {
        let (_, data) = run(clicks: [Vector(0, 0), Vector(5, 0)])
        guard let data else {
            Issue.record("expected a committed .mline")
            return
        }
        // STANDARD-like: two elements at +0.5 / -0.5, top justification, scale 1.
        #expect(data.elements.count == 2, "STANDARD style is a 2-element double line")
        let offsets = data.elements.map(\.offset).sorted()
        #expect(offsets == [-0.5, 0.5], "default elements are at offsets ±0.5")
        #expect(data.justification == .top, "default justification is .top")
        #expect(data.scale == 1, "default scale is 1")
        #expect(data.elements == MLineTool.standardElements,
                "default fan is the STANDARD element fan")
    }

    // MARK: - Settable justification / scale flow onto the committed entity

    @Test func settableJustificationAndScaleAreCommitted() {
        var tool = MLineTool()
        tool.justification = .zero
        tool.scale = 2.5
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(6, 0)), context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        guard let data = Self.mlineData(from: outcome) else {
            Issue.record("expected a committed .mline")
            return
        }
        #expect(data.justification == .zero, "the tool's justification flows onto the entity")
        #expect(data.scale == 2.5, "the tool's scale flows onto the entity")
    }

    // MARK: - Close (clicking back on the first vertex)

    @Test func clickingNearFirstVertexClosesAndCommits() {
        var tool = MLineTool()
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 3)), context: .empty)
        // Click back on the first vertex (within tolerance) → closes + commits.
        let outcome = tool.handle(.click(p0), context: .empty)
        guard let data = Self.mlineData(from: outcome) else {
            Issue.record("expected a closed multiline on clicking the start vertex")
            return
        }
        #expect(data.closed, "clicking the start vertex closes the path")
        // The re-clicked first vertex is NOT appended again (it only closes).
        #expect(data.vertices.count == 3, "closing must not duplicate the start vertex")
    }

    @Test func clickingNearFirstWithTwoVerticesDoesNotClose() {
        var tool = MLineTool()
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        // Only two vertices — clicking near the first must NOT close (needs ≥3); it is
        // within tolerance of neither the last (the second vertex), so it is ignored as
        // a coincident-with-first no-op (close requires ≥3).
        let outcome = tool.handle(.click(p0), context: .empty)
        if case .commit = outcome { Issue.record("must not close a multiline with <3 vertices") }
    }

    // MARK: - Backspace drops a vertex

    @Test func backspaceRemovesLastVertex() {
        var tool = MLineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 3)), context: .empty)
        // Step back one vertex → two remain → commit keeps just those two.
        _ = tool.handle(.backspace, context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        guard let data = Self.mlineData(from: outcome) else {
            Issue.record("expected a committed .mline after backspace to two vertices")
            return
        }
        #expect(data.vertices == [Vector(0, 0), Vector(4, 0)],
                "backspace drops the last vertex; commit keeps the rest")
    }

    @Test func backspaceToEmptyThenCommitIsNoOp() {
        var tool = MLineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.backspace, context: .empty)   // back to empty
        let outcome = tool.handle(.commit, context: .empty)
        #expect(Self.mlineData(from: outcome) == nil, "no vertices → commit makes nothing")
        #expect(outcome == .finished)
    }

    // MARK: - Esc cancels (no commit)

    @Test func cancelDiscardsTheRun() {
        var tool = MLineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 3)), context: .empty)
        let cancelOutcome = tool.handle(.cancel, context: .empty)
        #expect(cancelOutcome == .finished, "cancel ends the run")
        // A subsequent commit on the reset tool produces nothing.
        let outcome = tool.handle(.commit, context: .empty)
        #expect(Self.mlineData(from: outcome) == nil, "cancel must clear the pending vertices")
    }

    // MARK: - Single-vertex / no-vertex commit is a safe no-op

    @Test func oneClickCommitsNothing() {
        let (outcome, data) = run(clicks: [Vector(0, 0)])
        #expect(data == nil, "a single vertex must not produce a multiline")
        #expect(outcome == .finished, "Return with one vertex ends the run without committing")
    }

    @Test func commitWithNoPointsIsANoOpFinish() {
        var tool = MLineTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished, "Return with no points just finishes")
        #expect(Self.mlineData(from: outcome) == nil)
    }

    // MARK: - Preview is non-empty mid-run, empty before/after

    @Test func previewIsEmptyBeforeFirstPointAndAfterReset() {
        var tool = MLineTool()
        #expect(tool.preview.isEmpty, "no preview before the first click")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(4, 1)), context: .empty)
        #expect(!tool.preview.isEmpty, "preview shows the in-progress multiline while building")
        _ = tool.handle(.cancel, context: .empty)
        #expect(tool.preview.isEmpty, "preview clears after cancel/reset")
    }

    @Test func previewResolvesElementFanWithTwoVertices() {
        var tool = MLineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(10, 5)), context: .empty)
        // With ≥2 path points + the moving cursor, the in-progress .mline resolves to
        // its element fan (one preview polyline per element), in the preview pen.
        let preview = tool.preview
        #expect(!preview.isEmpty, "a multi-vertex multiline previews its element fan")
        #expect(preview.allSatisfy { $0.pen == .toolPreview },
                "every preview polyline uses the .toolPreview pen")
        // STANDARD style has two elements → two offset element lines.
        #expect(preview.count == MLineTool.standardElements.count,
                "preview draws one polyline per element")
    }

    // MARK: - Registry wiring

    @Test func toolKindMintsMLineWithMatchingTitle() {
        #expect(ToolKind.mline.title == "Multiline")
        let tool = ToolKind.mline.makeTool()
        #expect(tool != nil, "ToolKind.mline must mint a tool")
        #expect(tool?.title == "Multiline")
    }
}
