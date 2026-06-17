//
//  RevisionCloudToolTests.swift
//  CADEngineTests
//
//  Drives `RevisionCloudTool` headlessly (no GUI) through `.click`/`.commit`
//  sequences and asserts the committed geometry is a correct revision cloud: ONE
//  CLOSED `.polyline` whose every segment carries a fixed POSITIVE bulge that bows
//  the arc OUTWARD, regardless of which winding the user clicked; and that fewer
//  than three points commit nothing.
//
//  The "outward" check is geometric and self-contained: it reconstructs each
//  segment's arc apex from the engine's DOCUMENTED bulge convention (a positive
//  bulge bows the arc to the LEFT of the directed chord a→b — see
//  `Resolve.expandPolyline`), where the sagitta is `|chord|/2 · bulge` (since
//  `bulge = tan(¼·θ)` and `sagitta/(½·chord) = tan(¼·θ)`), and asserts that apex is
//  FARTHER from the polygon centroid than the straight chord midpoint — i.e. the
//  scallop bumps out, not in. No dependency on the resolve/render path.
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

@Suite("RevisionCloudTool")
struct RevisionCloudToolTests {

    // MARK: - Helpers

    /// Drives a fresh tool through `clicks`, optionally finishing with `.commit`,
    /// and returns the final outcome plus the committed `PolylineData` (if any).
    private func run(clicks: [Vector], finishWithCommit: Bool = true)
        -> (outcome: ToolOutcome, data: PolylineData?) {
        var tool = RevisionCloudTool()
        var outcome: ToolOutcome = .none
        for p in clicks { outcome = tool.handle(.click(p), context: .empty) }
        if finishWithCommit { outcome = tool.handle(.commit, context: .empty) }
        return (outcome, Self.polylineData(from: outcome))
    }

    /// Extracts the single committed `.add(.polyline)` payload from an outcome, or
    /// `nil` if the outcome is not exactly one polyline `.add`.
    private static func polylineData(from outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let data) = record.kind else { return nil }
        return data
    }

    private func centroid(_ pts: [Vector]) -> Vector {
        var sum = Vector(0, 0)
        for p in pts { sum = sum + p }
        return sum / Double(pts.count)
    }

    /// The arc apex (mid-arc point) of segment a→b for a positive `bulge`, per the
    /// engine's convention: bow LEFT of the directed chord by sagitta `|chord|/2·bulge`.
    private func apex(from a: Vector, to b: Vector, bulge: Double) -> Vector {
        let chord = b - a
        let len = chord.magnitude
        let dir = chord / len
        let leftNormal = Vector(-dir.y, dir.x)
        let mid = (a + b) * 0.5
        return mid + leftNormal * (len / 2 * bulge)
    }

    /// Asserts `data` is a closed cloud over `expectedCount` vertices with a fixed
    /// positive bulge on EVERY vertex, normalized to clockwise winding, and that
    /// every segment's arc bows OUTWARD (apex farther from the centroid than the
    /// chord midpoint). Works for any convex loop.
    private func assertIsOutwardCloud(_ data: PolylineData?, expectedCount: Int) {
        guard let data else {
            Issue.record("expected a committed .polyline cloud, got none")
            return
        }
        #expect(data.closed, "a revision cloud must be a CLOSED polyline")
        #expect(data.vertices.count == expectedCount,
                "cloud should keep all \(expectedCount) clicked vertices")

        // Every segment carries the same fixed POSITIVE bulge.
        for v in data.vertices {
            #expect(v.bulge > 0, "every cloud segment must carry a positive (outward) bulge")
            #expect(v.bulge == RevisionCloudTool.cloudBulge,
                    "every segment uses the fixed cloud bulge")
        }

        let pts = data.vertices.map(\.point)
        // Normalized to CLOCKWISE so a positive (left-bowing) bulge points outward.
        #expect(RevisionCloudTool.signedArea(pts) < 0,
                "cloud winding must be normalized clockwise (negative signed area)")

        // Every segment (including the closing edge) bows OUTWARD.
        let c = centroid(pts)
        let n = pts.count
        for i in 0..<n {
            let a = pts[i]
            let b = pts[(i + 1) % n]
            let apexPt = apex(from: a, to: b, bulge: RevisionCloudTool.cloudBulge)
            let mid = (a + b) * 0.5
            #expect((apexPt - c).magnitude > (mid - c).magnitude,
                    "segment \(i) arc must bow OUTWARD (apex farther from centroid than chord midpoint)")
        }
    }

    // MARK: - ≥3 clicks → one closed, all-positive-bulge cloud

    @Test func threeClicksCommitOneClosedBulgedCloud() {
        let (outcome, data) = run(clicks: [Vector(0, 0), Vector(4, 0), Vector(2, 3)])
        // Exactly one .add edit (the cloud).
        if case .commit(let edits) = outcome {
            #expect(edits.count == 1, "a cloud commits exactly one .add edit")
        } else {
            Issue.record("expected a .commit outcome, got \(outcome)")
        }
        assertIsOutwardCloud(data, expectedCount: 3)
    }

    @Test func squareClickedCounterClockwiseBowsOutward() {
        // Clicked CCW (positive signed area) — the tool must reverse to CW so the
        // fixed positive bulge bows outward.
        let ccw = [Vector(0, 0), Vector(2, 0), Vector(2, 2), Vector(0, 2)]
        #expect(RevisionCloudTool.signedArea(ccw) > 0, "fixture must be counter-clockwise")
        let (_, data) = run(clicks: ccw)
        assertIsOutwardCloud(data, expectedCount: 4)
    }

    @Test func squareClickedClockwiseBowsOutward() {
        // Clicked CW (negative signed area) — already correct, kept as-is. Same
        // outward result as the CCW fixture: outward REGARDLESS of winding.
        let cw = [Vector(0, 0), Vector(0, 2), Vector(2, 2), Vector(2, 0)]
        #expect(RevisionCloudTool.signedArea(cw) < 0, "fixture must be clockwise")
        let (_, data) = run(clicks: cw)
        assertIsOutwardCloud(data, expectedCount: 4)
    }

    // MARK: - <3 clicks → commit nothing

    @Test func twoClicksCommitNothing() {
        let (outcome, data) = run(clicks: [Vector(0, 0), Vector(4, 0)])
        #expect(data == nil, "fewer than three points must not produce a cloud")
        if case .commit = outcome { Issue.record("two points must NOT commit geometry") }
        #expect(outcome == .finished, "Return with <3 points ends the run without committing")
    }

    @Test func oneClickCommitsNothing() {
        let (outcome, data) = run(clicks: [Vector(0, 0)])
        #expect(data == nil, "a single point must not produce a cloud")
        #expect(outcome == .finished)
    }

    @Test func commitWithNoPointsIsANoOpFinish() {
        var tool = RevisionCloudTool()
        let outcome = tool.handle(.commit, context: .empty)
        #expect(outcome == .finished, "Return with no points just finishes")
        #expect(Self.polylineData(from: outcome) == nil)
    }

    // MARK: - Closing by clicking back on the first vertex

    @Test func clickingNearFirstVertexClosesAndCommits() {
        var tool = RevisionCloudTool()
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        // Click back on the first vertex (within tolerance) → closes + commits.
        let outcome = tool.handle(.click(p0), context: .empty)
        let data = Self.polylineData(from: outcome)
        assertIsOutwardCloud(data, expectedCount: 3)
    }

    @Test func clickingNearFirstWithTwoVerticesDoesNotCommit() {
        var tool = RevisionCloudTool()
        let p0 = Vector(0, 0)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        // Only two vertices — clicking near the first must NOT close (needs ≥3).
        let outcome = tool.handle(.click(p0), context: .empty)
        if case .commit = outcome { Issue.record("must not close a cloud with <3 vertices") }
    }

    // MARK: - State editing

    @Test func backspaceRemovesLastVertexThenCommitDropsToTooFew() {
        var tool = RevisionCloudTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        // Step back one vertex → only two remain → commit makes nothing.
        _ = tool.handle(.backspace, context: .empty)
        let outcome = tool.handle(.commit, context: .empty)
        #expect(Self.polylineData(from: outcome) == nil,
                "after a backspace to two vertices, commit produces no cloud")
    }

    @Test func cancelDiscardsTheRun() {
        var tool = RevisionCloudTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        let cancelOutcome = tool.handle(.cancel, context: .empty)
        #expect(cancelOutcome == .finished, "cancel ends the run")
        // A subsequent commit on the reset tool produces nothing.
        let outcome = tool.handle(.commit, context: .empty)
        #expect(Self.polylineData(from: outcome) == nil, "cancel must clear the pending vertices")
    }

    // MARK: - Preview

    @Test func previewIsEmptyBeforeFirstPointAndAfterReset() {
        var tool = RevisionCloudTool()
        #expect(tool.preview.isEmpty, "no preview before the first click")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(1, 1)), context: .empty)
        #expect(!tool.preview.isEmpty, "preview shows the rubber-band while building")
        _ = tool.handle(.cancel, context: .empty)
        #expect(tool.preview.isEmpty, "preview clears after cancel/reset")
    }

    // MARK: - Registry wiring

    @Test func toolKindMintsRevisionCloudWithMatchingTitle() {
        #expect(ToolKind.revcloud.title == "Revision Cloud")
        let tool = ToolKind.revcloud.makeTool()
        #expect(tool != nil, "ToolKind.revcloud must mint a tool")
        #expect(tool?.title == "Revision Cloud")
    }
}
