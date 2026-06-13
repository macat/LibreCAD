//
//  ToolModeTests.swift
//  CADEngineTests
//
//  Drives the ADDITIVE tool modes (WAVE 4a, w4a-toolmodes) PURELY (no GUI):
//    - ScaleTool's `.reference` mode (scale-by-reference-length): pick a base, a
//      FREE 2-point reference length, then a new length → factor = newLen / refLen,
//      scaling the selection about the base. The brief's worked example (ref 2 /
//      new 4 → ×2 about the base) is asserted directly.
//    - OffsetTool's `.distance` mode (fixed offset distance): the configured
//      `distance` sets the magnitude and the clicked point only chooses the SIDE,
//      while the result still passes through the clicked point in the default
//      `.through` mode.
//  Both modes honor `.value` typed input where a point/length is expected, and
//  this suite also confirms the DEFAULT modes are byte-identical to the originals.
//
//  Domain-prefixed suite names (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - ScaleTool .reference mode

@Suite("ScaleTool reference-length mode (w4a-toolmodes)")
struct ScaleToolReferenceModeTests {

    // MARK: Fixtures

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

    private func selectionContext() -> ToolContext {
        let records = [lineRecord(), circleRecord()]
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    /// A reference-mode scale tool (the wire-wave would set `.mode` after construction).
    private func referenceTool() -> ScaleTool {
        var t = ScaleTool()
        t.mode = .reference
        return t
    }

    /// Pulls the `.replace`d kinds out of a `.commit`, keyed by id (fails if the
    /// outcome isn't a `.commit` of only `.replace` edits).
    private func replacedKinds(_ outcome: ToolOutcome) -> [EntityID: EntityKind]? {
        guard case .commit(let edits) = outcome else { return nil }
        var out: [EntityID: EntityKind] = [:]
        for edit in edits {
            guard case .replace(let id, let kind) = edit else { return nil }
            out[id] = kind
        }
        return out
    }

    // MARK: Status walk

    @Test("status walks base → reference (2 pts) → new length")
    func statusWalk() {
        var tool = referenceTool()
        let ctx = selectionContext()
        // Before any click the reference mode prompts to select first.
        #expect(tool.status == "Select objects to scale first")
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // base
        #expect(tool.status == "Specify first point of reference length")
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // ref start
        #expect(tool.status == "Specify second point of reference length")
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)     // ref end → refLen 2
        #expect(tool.status == "Specify new length")
    }

    // MARK: The brief's worked example — ref 2 / new 4 → ×2 about the base

    @Test("ref length 2, new length 4 → factor 2 about the base")
    func refTwoNewFourScalesByTwo() {
        var tool = referenceTool()
        let ctx = selectionContext()

        // Base / pivot at (0,0).
        #expect(tool.handle(.click(Vector(0, 0)), context: ctx) == .none)
        // Reference length segment (0,0)→(2,0) → refLen 2.
        #expect(tool.handle(.click(Vector(0, 0)), context: ctx) == .none)
        #expect(tool.handle(.click(Vector(2, 0)), context: ctx) == .none)
        // New length: distance from the ref-start (0,0) to (4,0) is 4 → factor 4/2 = 2.
        let outcome = tool.handle(.click(Vector(4, 0)), context: ctx)

        guard let kinds = replacedKinds(outcome) else {
            Issue.record("expected a .commit of only .replace edits"); return
        }
        #expect(kinds.count == 2)

        // Line scales about (0,0) by 2: (0,0)→(0,0), (10,0)→(20,0).
        guard case .line(let l)? = kinds[Self.lineID] else {
            Issue.record("line not replaced with a line"); return
        }
        #expect(l.start == Vector(0, 0))
        #expect(l.end == Vector(20, 0))

        // Circle scales about (0,0) by 2: center (10,0)→(20,0), radius 2→4.
        guard case .circle(let c)? = kinds[Self.circleID] else {
            Issue.record("circle not replaced with a circle"); return
        }
        #expect(c.center == Vector(20, 0))
        #expect(abs(c.radius - 4) < 1e-9)
    }

    @Test("scales about the picked BASE, not the reference segment")
    func scalesAboutBaseNotReferenceSegment() {
        var tool = referenceTool()
        let ctx = selectionContext()
        // Base away from the reference segment, at (5,0).
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)     // base (pivot)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // ref start
        _ = tool.handle(.click(Vector(1, 0)), context: ctx)     // ref end → refLen 1
        // New length 3 from ref-start → factor 3 about base (5,0).
        let outcome = tool.handle(.click(Vector(3, 0)), context: ctx)
        guard case .line(let l)? = replacedKinds(outcome)?[Self.lineID] else {
            Issue.record("line not replaced"); return
        }
        // (0,0) about (5,0) ×3 → 5 + 3·(0-5) = -10; (10,0) → 5 + 3·5 = 20.
        #expect(l.start == Vector(-10, 0))
        #expect(l.end == Vector(20, 0))
    }

    // MARK: Typed `.value` honored where a point/length is expected

    @Test(".value typed points drive base / reference / new length")
    func valueTypedPointsDriveTheFlow() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.value(Vector(0, 0)), context: ctx)     // base typed
        #expect(tool.status == "Specify first point of reference length")
        _ = tool.handle(.value(Vector(0, 0)), context: ctx)     // ref start typed
        _ = tool.handle(.value(Vector(2, 0)), context: ctx)     // ref end typed → refLen 2
        #expect(tool.status == "Specify new length")
        let outcome = tool.handle(.value(Vector(4, 0)), context: ctx)  // new length typed → ×2
        #expect(replacedKinds(outcome)?.count == 2)
    }

    // MARK: Degenerate guards

    @Test("near-zero reference length is ignored (stays awaiting the second point)")
    func zeroReferenceLengthIgnored() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // base
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // ref start
        // Second point coincident → refLen 0 → ignored.
        let outcome = tool.handle(.click(Vector(0, 0)), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify second point of reference length")
    }

    @Test("factor ≈ 1 (new length == reference length) is ignored, no commit")
    func factorOneIgnored() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // base
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // ref start
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)     // refLen 2
        // New length also 2 → factor 1 → ignored.
        let outcome = tool.handle(.click(Vector(0, 2)), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify new length")
        // A real new length afterwards still commits.
        #expect(replacedKinds(tool.handle(.click(Vector(4, 0)), context: ctx))?.count == 2)
    }

    @Test("empty selection: the base click is a no-op")
    func emptySelectionNoOp() {
        var tool = referenceTool()
        let outcome = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Select objects to scale first")
    }

    // MARK: Preview

    @Test("preview is empty before the reference length is fixed, then shows the scaled selection")
    func previewAppearsAfterReferenceLength() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // base
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // ref start
        // No reference length yet → a move shows nothing.
        _ = tool.handle(.move(Vector(1, 0)), context: ctx)
        #expect(tool.preview.isEmpty)

        _ = tool.handle(.click(Vector(2, 0)), context: ctx)     // refLen 2
        let out = tool.handle(.move(Vector(4, 0)), context: ctx)  // new len 4 → ×2
        #expect(out == .preview)
        let line = tool.preview.first { $0.points.count == 2 }
        #expect(line?.points.first == Vector(0, 0))
        #expect(line?.points.last == Vector(20, 0))
        #expect(tool.preview.allSatisfy { $0.pen == .toolPreview })
    }

    // MARK: Backspace / cancel

    @Test("backspace steps new → refEnd → refStart → base")
    func backspaceStepsBack() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // base
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // ref start
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)     // refLen 2 → refPickingNew

        #expect(tool.handle(.backspace, context: ctx) == .preview)
        #expect(tool.status == "Specify second point of reference length")
        #expect(tool.handle(.backspace, context: ctx) == .preview)
        #expect(tool.status == "Specify first point of reference length")
        #expect(tool.handle(.backspace, context: ctx) == .preview)
        #expect(tool.status == "Specify base point")
        // At base again, a further backspace is a no-op.
        #expect(tool.handle(.backspace, context: ctx) == .none)
    }

    @Test("cancel discards the run and finishes")
    func cancelResets() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        _ = tool.handle(.move(Vector(4, 0)), context: ctx)
        #expect(!tool.preview.isEmpty)
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to scale first")
    }

    @Test("after a commit a second reference scale starts cleanly")
    func secondRunAfterCommit() {
        var tool = referenceTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        _ = tool.handle(.click(Vector(4, 0)), context: ctx)     // commit ×2
        // Back at the base prompt for the next run.
        #expect(tool.status == "Select objects to scale first")
        // A fresh full run still commits.
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        _ = tool.handle(.click(Vector(2, 0)), context: ctx)
        #expect(replacedKinds(tool.handle(.click(Vector(4, 0)), context: ctx))?.count == 2)
    }
}

// MARK: - ScaleTool .factor default unchanged

@Suite("ScaleTool factor mode default unchanged (w4a-toolmodes)")
struct ScaleToolFactorDefaultTests {

    private func selectionContext() -> ToolContext {
        let records = [
            EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))),
        ]
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    @Test("default mode is .factor")
    func defaultModeIsFactor() {
        #expect(ScaleTool().mode == .factor)
    }

    @Test("default three-pick flow still uses the center → reference → target prompts")
    func defaultPromptsUnchanged() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        #expect(tool.status == "Select objects to scale first")
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        #expect(tool.status == "Specify reference distance point")
        _ = tool.handle(.click(Vector(10, 0)), context: ctx)
        #expect(tool.status == "Specify target distance point")
    }

    @Test("default three-pick flow commits the expected factor (×2 about center)")
    func defaultCommitUnchanged() {
        var tool = ScaleTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)     // center
        _ = tool.handle(.click(Vector(10, 0)), context: ctx)    // refDist 10
        let outcome = tool.handle(.click(Vector(20, 0)), context: ctx)  // ×2
        guard case .commit(let edits) = outcome, case .replace(_, let kind) = edits.first,
              case .line(let l) = kind else {
            Issue.record("expected a .replace line commit"); return
        }
        #expect(l.start == Vector(0, 0))
        #expect(l.end == Vector(20, 0))
    }
}

// MARK: - OffsetTool .distance mode

@Suite("OffsetTool fixed-distance mode (w4a-toolmodes)")
struct OffsetToolDistanceModeTests {

    private static let line = EntityRecord(
        id: EntityID(11),
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )
    private static let circle = EntityRecord(
        id: EntityID(22),
        kind: .circle(CircleData(center: Vector(0, 0), radius: 5))
    )
    private static let arc = EntityRecord(
        id: EntityID(33),
        kind: .arc(ArcData(center: Vector(0, 0), radius: 5,
                           startAngle: 0, endAngle: .pi / 2, reversed: false))
    )

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(selected: records, entity: { id in records.first { $0.id == id } }, gridSpacing: nil)
    }

    /// A `.distance`-mode offset tool with the given fixed distance.
    private func distanceTool(_ d: Double) -> OffsetTool {
        var t = OffsetTool()
        t.mode = .distance
        t.distance = d
        return t
    }

    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }
            records.append(r)
        }
        return records
    }

    @Test("line offset uses the FIXED distance, not the click's perpendicular distance")
    func lineUsesFixedDistance() {
        var tool = distanceTool(3)
        // Click far above the line (y=9): in .distance mode the magnitude is the
        // fixed 3, only the SIDE (positive Y) comes from the click.
        let recs = addedRecords(tool.handle(.click(Vector(5, 9)), context: context([Self.line])))
        guard case .line(let l)? = recs?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, 3))
        #expect(l.end == Vector(10, 3))
    }

    @Test("clicking the other side flips the offset direction")
    func lineSideFromClick() {
        var tool = distanceTool(3)
        let recs = addedRecords(tool.handle(.click(Vector(5, -2)), context: context([Self.line])))
        guard case .line(let l)? = recs?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, -3))
        #expect(l.end == Vector(10, -3))
    }

    @Test("circle: clicking outside grows by the fixed distance")
    func circleOutsideGrows() {
        var tool = distanceTool(2)
        let recs = addedRecords(tool.handle(.click(Vector(0, 100)), context: context([Self.circle])))
        guard case .circle(let c)? = recs?.first?.kind else {
            Issue.record("expected a circle offset copy"); return
        }
        #expect(abs(c.radius - 7) < 1e-9)   // 5 + 2
        #expect(c.center == Vector(0, 0))
    }

    @Test("circle: clicking inside shrinks by the fixed distance")
    func circleInsideShrinks() {
        var tool = distanceTool(2)
        let recs = addedRecords(tool.handle(.click(Vector(0, 1)), context: context([Self.circle])))
        guard case .circle(let c)? = recs?.first?.kind else {
            Issue.record("expected a circle offset copy"); return
        }
        #expect(abs(c.radius - 3) < 1e-9)   // 5 - 2
    }

    @Test("circle: shrinking past the center is rejected (no edit)")
    func circleShrinkPastCenterRejected() {
        var tool = distanceTool(10)
        let outcome = tool.handle(.click(Vector(0, 1)), context: context([Self.circle]))
        #expect(outcome == .none)
    }

    @Test("arc fixed-distance offset preserves angles + reversed flag")
    func arcPreservesAngles() {
        var tool = distanceTool(2)
        let recs = addedRecords(tool.handle(.click(Vector(0, 100)), context: context([Self.arc])))
        guard case .arc(let a)? = recs?.first?.kind else {
            Issue.record("expected an arc offset copy"); return
        }
        #expect(abs(a.radius - 7) < 1e-9)
        #expect(a.startAngle == 0)
        #expect(abs(a.endAngle - .pi / 2) < 1e-12)
        #expect(a.reversed == false)
    }

    @Test("zero / non-positive distance yields no edit")
    func zeroDistanceNoEdit() {
        var tool = distanceTool(0)
        #expect(tool.handle(.click(Vector(5, 9)), context: context([Self.line])) == .none)
    }

    @Test(".distance offsets emit ONLY .add edits (originals untouched)")
    func onlyAddEdits() {
        var tool = distanceTool(2)
        let outcome = tool.handle(.click(Vector(0, 100)), context: context([Self.line, Self.circle, Self.arc]))
        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit"); return
        }
        #expect(edits.count == 3)
        for edit in edits {
            if case .add = edit { continue }
            Issue.record("distance offset must only .add; got \(edit)")
        }
    }

    @Test(".value typed point drives the side pick in .distance mode")
    func valueTypedSidePick() {
        var tool = distanceTool(3)
        let recs = addedRecords(tool.handle(.value(Vector(5, 9)), context: context([Self.line])))
        guard case .line(let l)? = recs?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, 3))
        #expect(l.end == Vector(10, 3))
    }

    @Test(".distance preview reflects the fixed distance, not the cursor distance")
    func previewUsesFixedDistance() {
        var tool = distanceTool(3)
        _ = tool.handle(.move(Vector(5, 9)), context: context([Self.line]))
        #expect(tool.preview.count == 1)
        #expect(tool.preview[0].points.first == Vector(0, 3))
        #expect(tool.preview[0].points.last == Vector(10, 3))
    }
}

// MARK: - OffsetTool .through default unchanged

@Suite("OffsetTool through-point mode default unchanged (w4a-toolmodes)")
struct OffsetToolThroughDefaultTests {

    private static let line = EntityRecord(
        id: EntityID(11),
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
    )

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(selected: records, entity: { id in records.first { $0.id == id } }, gridSpacing: nil)
    }

    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }
            records.append(r)
        }
        return records
    }

    @Test("default mode is .through")
    func defaultModeIsThrough() {
        #expect(OffsetTool().mode == .through)
    }

    @Test("default offset still passes THROUGH the clicked point (perpendicular distance)")
    func defaultThroughPointUnchanged() {
        var tool = OffsetTool()
        // Far past the right end at y=4: the copy passes through y=4 (perpendicular
        // distance), confirming the default still derives distance from the point.
        let recs = addedRecords(tool.handle(.click(Vector(99, 4)), context: context([Self.line])))
        guard case .line(let l)? = recs?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, 4))
        #expect(l.end == Vector(10, 4))
    }

    @Test(".value typed through point honored in the default mode (passes through it)")
    func valueThroughPointHonored() {
        var tool = OffsetTool()
        let recs = addedRecords(tool.handle(.value(Vector(0, 3)), context: context([Self.line])))
        guard case .line(let l)? = recs?.first?.kind else {
            Issue.record("expected a line offset copy"); return
        }
        #expect(l.start == Vector(0, 3))
        #expect(l.end == Vector(10, 3))
    }
}
