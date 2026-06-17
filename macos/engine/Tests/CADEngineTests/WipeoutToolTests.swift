//
//  WipeoutToolTests.swift
//  CADEngineTests
//
//  Drives `WipeoutTool` headlessly (no GUI) through `.click`/`.commit` sequences
//  and asserts the committed geometry is a correct masking polygon: ONE closed
//  `.wipeout` whose WORLD boundary is exactly the clicked points (straight edges,
//  no bulge); and that fewer than three points commit nothing. Cloned from the
//  RevisionCloudTool test pattern (minus the bulge/winding checks — a wipeout's
//  edges are straight).
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

@Suite("WipeoutTool")
struct WipeoutToolTests {

    // MARK: - Helpers

    /// World-coord approximate equality.
    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    /// Drives a fresh tool through `clicks`, optionally finishing with `.commit`,
    /// and returns the final outcome plus the committed `WipeoutData` (if any).
    private func run(clicks: [Vector], finishWithCommit: Bool = true)
        -> (outcome: ToolOutcome, data: WipeoutData?) {
        var tool = WipeoutTool()
        var outcome: ToolOutcome = .none
        for p in clicks { outcome = tool.handle(.click(p), context: .empty) }
        if finishWithCommit { outcome = tool.handle(.commit, context: .empty) }
        return (outcome, Self.wipeoutData(from: outcome))
    }

    /// Extracts the single committed `.add(.wipeout)` payload from an outcome, or
    /// `nil` if the outcome is not exactly one wipeout `.add`.
    private static func wipeoutData(from outcome: ToolOutcome) -> WipeoutData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .wipeout(let data) = record.kind else { return nil }
        return data
    }

    // MARK: - ≥3 clicks → one closed wipeout over the clicked world boundary

    @Test func threeClicksCommitOneWipeout() {
        let pts = [Vector(0, 0), Vector(4, 0), Vector(2, 3)]
        let (outcome, data) = run(clicks: pts)
        if case .commit(let edits) = outcome {
            #expect(edits.count == 1, "a wipeout commits exactly one .add edit")
        } else {
            Issue.record("expected a .commit outcome, got \(outcome)")
        }
        let d = try! #require(data)
        // The committed wipeout's WORLD boundary is exactly the clicked points.
        let world = d.worldBoundary
        #expect(world.count == 3)
        for (a, b) in zip(world, pts) { #expect(approx(a, b, 1e-9)) }
    }

    @Test func squareWorldBoundaryMatchesClicks() {
        let pts = [Vector(1, 1), Vector(5, 1), Vector(5, 4), Vector(1, 4)]
        let (_, data) = run(clicks: pts)
        let d = try! #require(data)
        let world = d.worldBoundary
        #expect(world.count == 4)
        for (a, b) in zip(world, pts) { #expect(approx(a, b, 1e-9)) }
        // Frame is shown by default so the placed wipeout is visible/selectable.
        #expect(d.frameVisible)
    }

    // MARK: - <3 clicks → commit nothing

    @Test func twoClicksCommitNothing() {
        let (outcome, data) = run(clicks: [Vector(0, 0), Vector(4, 0)])
        #expect(data == nil, "fewer than three points must not produce a wipeout")
        if case .commit = outcome { Issue.record("two points must NOT commit geometry") }
        #expect(outcome == .finished, "Return with <3 points ends the run without committing")
    }

    @Test func oneClickCommitsNothing() {
        let (outcome, data) = run(clicks: [Vector(0, 0)])
        #expect(data == nil)
        #expect(outcome == .finished)
    }

    @Test func commitWithNoPointsIsANoOpFinish() {
        var tool = WipeoutTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished)
        #expect(Self.wipeoutData(from: outcome) == nil)
    }

    // MARK: - Closing by clicking back on the first vertex

    @Test func clickingNearFirstVertexClosesAndCommits() {
        var tool = WipeoutTool()
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        // Click back on the first vertex (within tolerance) → closes + commits.
        let outcome = tool.handle(.click(p0), context: .empty)
        let data = Self.wipeoutData(from: outcome)
        let d = try! #require(data)
        #expect(d.worldBoundary.count == 3, "closing keeps the 3 outline vertices")
    }

    @Test func clickingNearFirstWithTwoVerticesDoesNotCommit() {
        var tool = WipeoutTool()
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        let outcome = tool.handle(.click(p0), context: .empty)
        if case .commit = outcome { Issue.record("must not close a wipeout with <3 vertices") }
    }

    // MARK: - State editing

    @Test func backspaceRemovesLastVertexThenCommitDropsToTooFew() {
        var tool = WipeoutTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        _ = tool.handle(.backspace, context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(Self.wipeoutData(from: outcome) == nil,
                "after a backspace to two vertices, commit produces no wipeout")
    }

    @Test func cancelDiscardsTheRun() {
        var tool = WipeoutTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        let cancelOutcome = tool.handle(.cancel, context: .empty)
        #expect(cancelOutcome == .finished)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(Self.wipeoutData(from: outcome) == nil, "cancel must clear the pending vertices")
    }

    // MARK: - Preview

    @Test func previewIsEmptyBeforeFirstPointAndAfterReset() {
        var tool = WipeoutTool()
        #expect(tool.preview.isEmpty, "no preview before the first click")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(1, 1)), context: .empty)
        #expect(!tool.preview.isEmpty, "preview shows the rubber-band while building")
        _ = tool.handle(.cancel, context: .empty)
        #expect(tool.preview.isEmpty, "preview clears after cancel/reset")
    }

    // MARK: - Registry wiring

    @Test func toolKindMintsWipeoutWithMatchingTitle() {
        #expect(ToolKind.wipeout.title == "Wipeout")
        let tool = ToolKind.wipeout.makeTool()
        #expect(tool != nil, "ToolKind.wipeout must mint a tool")
        #expect(tool?.title == "Wipeout")
    }
}
