//
//  ScaleToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Scale tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` (with a known selection) to `ScaleTool` and asserts
//  the commit shape (one `.replace` per selected id, geometry uniformly scaled
//  about the center by `|target − center| / |reference − center|`), the live
//  preview (present + scaled), the empty-selection no-op, the cancel/backspace
//  resets, and that a degenerate factor (≈ 1 or ≈ 0) is ignored.
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

@Suite("ScaleTool interactive modify")
struct ScaleToolTests {

    // MARK: - Fixtures

    /// A line from (0,0) to (10,0), id 1.
    private static let lineID = EntityID(1)
    private func lineRecord() -> EntityRecord {
        EntityRecord(id: Self.lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    /// A circle centered at (10,0) with radius 2, id 2.
    private static let circleID = EntityID(2)
    private func circleRecord() -> EntityRecord {
        EntityRecord(id: Self.circleID, kind: .circle(CircleData(center: Vector(10, 0), radius: 2)))
    }

    /// A `ToolContext` whose selection is the line + circle (the known fixture).
    private func selectionContext() -> ToolContext {
        let records = [lineRecord(), circleRecord()]
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    /// An empty `ToolContext` (no selection).
    private func emptyContext() -> ToolContext { .empty }

    /// The canonical three picks: center (0,0), reference (10,0) → refDist 10,
    /// target (20,0) → factor 2.
    private static let center = Vector(0, 0)
    private static let reference = Vector(10, 0)
    private static let target = Vector(20, 0)

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

    @Test("title is Scale")
    func title() {
        #expect(ScaleTool().title == "Scale")
    }

    @Test("with a selection the status walks center → reference → target")
    func statusWithSelection() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        // Before any click the tool has not yet learned the selection, so the
        // first prompt is the select-first hint until the center is picked.
        #expect(tool.status == "Select objects to scale first")
        _ = tool.handle(.click(Self.center), context: ctx)
        #expect(tool.status == "Specify reference distance point")
        _ = tool.handle(.click(Self.reference), context: ctx)
        #expect(tool.status == "Specify target distance point")
    }

    @Test("empty selection keeps the select-first status")
    func statusEmptySelection() {
        let tool = ScaleTool()
        #expect(tool.status == "Select objects to scale first")
    }

    // MARK: - Three-click commit

    @Test("center + reference + target commits one .replace per selected id, scaled by factor")
    func threeClicksCommitScaled() {
        var tool = ScaleTool()
        let ctx = selectionContext()

        let first = tool.handle(.click(Self.center), context: ctx)
        #expect(first == .none)   // first click only fixes the center

        let second = tool.handle(.click(Self.reference), context: ctx)
        #expect(second == .none)  // second click only fixes the reference distance

        // target (20,0) / refDist 10 → factor 2.
        let outcome = tool.handle(.click(Self.target), context: ctx)
        guard let kinds = replacedKinds(outcome) else {
            Issue.record("expected a .commit of only .replace edits"); return
        }
        // One replace per selected entity (line + circle), keyed by their ids.
        #expect(kinds.count == 2)

        // Line endpoints each scale about (0,0) by 2: (0,0)→(0,0), (10,0)→(20,0).
        guard case .line(let scaledLine)? = kinds[Self.lineID] else {
            Issue.record("line was not replaced with a line"); return
        }
        #expect(scaledLine.start == Vector(0, 0))
        #expect(scaledLine.end == Vector(20, 0))

        // Circle center scales about (0,0) by 2: (10,0)→(20,0); radius 2→4.
        guard case .circle(let scaledCircle)? = kinds[Self.circleID] else {
            Issue.record("circle was not replaced with a circle"); return
        }
        #expect(scaledCircle.center == Vector(20, 0))
        #expect(scaledCircle.radius == 4)
    }

    @Test("commit ends the run: tool resets to pick-center for the next scale")
    func commitResetsState() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        _ = tool.handle(.click(Self.target), context: ctx)
        // After the commit the tool is back at the initial state.
        #expect(tool.status == "Select objects to scale first")
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Preview

    @Test("preview is empty before the reference distance is fixed")
    func previewEmptyBeforeRef() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        // In pickingRef there is no factor yet, so a move shows no preview.
        _ = tool.handle(.move(Vector(5, 0)), context: ctx)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview shows the selection scaled to the cursor after the reference is fixed")
    func previewScaled() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)   // refDist 10

        // Move the cursor to (20,0) → factor 2.
        let outcome = tool.handle(.move(Self.target), context: ctx)
        #expect(outcome == .preview)

        let preview = tool.preview
        #expect(!preview.isEmpty)

        // The line preview (a single 2-point polyline) is scaled about (0,0) by 2.
        let linePreview = preview.first { $0.points.count == 2 }
        #expect(linePreview != nil)
        #expect(linePreview?.points.first == Vector(0, 0))
        #expect(linePreview?.points.last == Vector(20, 0))

        // Every preview polyline uses the shared preview pen.
        #expect(preview.allSatisfy { $0.pen == .toolPreview })

        // The circle preview (a closed ring) is present and recentered/grown: its
        // centroid sits near the scaled center (10,0)·2 = (20,0).
        let ring = preview.first { $0.closed }
        #expect(ring != nil)
        if let ring {
            let n = Double(ring.points.count)
            let cx = ring.points.reduce(0.0) { $0 + $1.x } / n
            let cy = ring.points.reduce(0.0) { $0 + $1.y } / n
            #expect(abs(cx - 20) < 1e-6)
            #expect(abs(cy - 0) < 1e-6)
        }
    }

    // MARK: - Reference segments (dashed center → original-reference guide)

    @Test("referenceSegments is empty before the reference distance is fixed")
    func referenceEmptyBeforeRef() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        // Only the center is fixed: no reference point yet → no guide.
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.move(Vector(5, 0)), context: ctx)
        #expect(tool.referenceSegments.isEmpty)
    }

    @Test("referenceSegments returns the center → original-reference line in pickingTarget")
    func referenceCenterToReference() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)   // fixes the reference point

        // Even as the cursor moves to a new target, the guide marks the ORIGINAL
        // reference (not the live cursor).
        _ = tool.handle(.move(Self.target), context: ctx)

        let segs = tool.referenceSegments
        #expect(segs.count == 1)
        #expect(segs.first?.0 == Self.center)
        #expect(segs.first?.1 == Self.reference)
    }

    @Test("referenceSegments is empty after commit (does not leak past the drag)")
    func referenceEmptyAfterCommit() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        #expect(!tool.referenceSegments.isEmpty)   // present mid-drag

        _ = tool.handle(.click(Self.target), context: ctx)   // commit (factor 2)
        #expect(tool.referenceSegments.isEmpty)
    }

    @Test("referenceSegments is empty after cancel and after backspace to ref-pick")
    func referenceEmptyAfterCancelAndBackspace() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        #expect(!tool.referenceSegments.isEmpty)

        // Backspace steps pickingTarget → pickingRef → no reference point → empty.
        _ = tool.handle(.backspace, context: ctx)
        #expect(tool.referenceSegments.isEmpty)

        // Re-fix the reference, then cancel → empty.
        _ = tool.handle(.click(Self.reference), context: ctx)
        #expect(!tool.referenceSegments.isEmpty)
        _ = tool.handle(.cancel, context: ctx)
        #expect(tool.referenceSegments.isEmpty)
    }

    @Test("empty selection: no reference line")
    func referenceEmptyWithoutSelection() {
        var tool = ScaleTool()
        let ctx = emptyContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        #expect(tool.referenceSegments.isEmpty)
    }

    // MARK: - Empty selection no-op

    @Test("empty selection: clicks and moves are no-ops, no commit, no preview")
    func emptySelectionNoOp() {
        var tool = ScaleTool()
        let ctx = emptyContext()

        let click1 = tool.handle(.click(Self.center), context: ctx)
        #expect(click1 == .none)
        #expect(tool.preview.isEmpty)
        // Still in the initial state (the click did not fix a center).
        #expect(tool.status == "Select objects to scale first")

        let move = tool.handle(.move(Vector(3, 3)), context: ctx)
        #expect(move == .none)
        #expect(tool.preview.isEmpty)

        // A "reference"/"target" click without a center also does nothing.
        let click2 = tool.handle(.click(Self.reference), context: ctx)
        #expect(click2 == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Degenerate factor ignored

    @Test("factor ≈ 1 (target distance == reference distance) is ignored, no commit")
    func factorOneIgnored() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)   // refDist 10

        // Target at the same distance (10) from the center → factor 1 → ignored.
        let outcome = tool.handle(.click(Vector(0, 10)), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify target distance point")

        // A real factor afterwards still commits.
        let real = tool.handle(.click(Self.target), context: ctx)   // factor 2
        #expect(replacedKinds(real)?.count == 2)
    }

    @Test("factor ≈ 0 (target coincides with center) is ignored, no commit")
    func factorZeroIgnored() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)   // refDist 10

        // Target at the center → distance 0 → factor 0 → ignored.
        let outcome = tool.handle(.click(Self.center), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify target distance point")
        #expect(tool.preview.isEmpty)
    }

    @Test("near-zero reference distance is ignored (stays in pickingRef)")
    func zeroReferenceIgnored() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)

        // Reference coincident with the center → refDist 0 → ignored.
        let outcome = tool.handle(.click(Self.center), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify reference distance point")

        // A real reference + target afterwards still commits.
        _ = tool.handle(.click(Self.reference), context: ctx)
        let real = tool.handle(.click(Self.target), context: ctx)
        #expect(replacedKinds(real)?.count == 2)
    }

    // MARK: - Cancel / backspace reset

    @Test("cancel discards the run, resets state, and reports .finished")
    func cancelResets() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        _ = tool.handle(.move(Self.target), context: ctx)
        #expect(!tool.preview.isEmpty)   // mid-run preview exists

        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to scale first")
    }

    @Test("backspace steps pickingTarget → pickingRef → pickingCenter")
    func backspaceStepsBack() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        _ = tool.handle(.move(Self.target), context: ctx)
        #expect(!tool.preview.isEmpty)

        // pickingTarget → pickingRef: in-progress preview clears, selection kept.
        let back1 = tool.handle(.backspace, context: ctx)
        #expect(back1 == .preview)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify reference distance point")

        // pickingRef → pickingCenter: still has the selection, prompts for center.
        let back2 = tool.handle(.backspace, context: ctx)
        #expect(back2 == .preview)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")

        // Re-picking center → reference → target still commits correctly.
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        let outcome = tool.handle(.click(Self.target), context: ctx)
        #expect(replacedKinds(outcome)?.count == 2)
    }

    @Test("backspace in pickingCenter is a no-op")
    func backspaceInCenterNoOp() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .none)
    }
}
