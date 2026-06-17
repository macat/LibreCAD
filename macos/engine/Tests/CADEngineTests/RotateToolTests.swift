//
//  RotateToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Rotate tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` (with a known selection) to `RotateTool` and asserts
//  the commit shape (one `.replace` per selected id, geometry rotated about the
//  center by `angle(center→target) − angle(center→reference)`), the live preview
//  (present + rotated), the empty-selection no-op, the cancel/backspace resets,
//  and that a ~zero-angle rotation is ignored.
//
//  Known geometry: a line (0,0)→(10,0); center = (0,0), reference = (10,0)
//  (refAngle 0), target = (0,10) → a 90° CCW rotation maps the line to
//  (0,0)→(0,10). A circle's center rotates while its radius stays put.
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

@Suite("RotateTool interactive modify")
struct RotateToolTests {

    // MARK: - Fixtures

    /// A line from (0,0) to (10,0), id 1.
    private static let lineID = EntityID(1)
    private func lineRecord() -> EntityRecord {
        EntityRecord(id: Self.lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    /// A circle centered at (10,0) with radius 2, id 2. (Placed off-center so a
    /// rotation about the origin actually moves it.)
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

    /// The known geometry from the brief.
    private static let center = Vector(0, 0)
    private static let reference = Vector(10, 0)   // refAngle = 0
    private static let target = Vector(0, 10)      // 90° CCW

    private static let tol = 1e-9

    private func vecClose(_ a: Vector, _ b: Vector) -> Bool {
        abs(a.x - b.x) < Self.tol && abs(a.y - b.y) < Self.tol
    }

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

    /// Drives center → reference → target clicks and returns the commit outcome.
    private func rotate(_ tool: inout RotateTool, ctx: ToolContext,
                        center: Vector, reference: Vector, target: Vector) -> ToolOutcome {
        _ = tool.handle(.click(center), context: ctx)
        _ = tool.handle(.click(reference), context: ctx)
        return tool.handle(.click(target), context: ctx)
    }

    // MARK: - Metadata / status

    @Test("title is Rotate")
    func title() {
        #expect(RotateTool().title == "Rotate")
    }

    @Test("with a selection the status walks center → reference → target")
    func statusWithSelection() {
        var tool = RotateTool()
        let ctx = selectionContext()
        // The tool only learns the selection once the center is picked, so the
        // first prompt is the select-first hint until then.
        #expect(tool.status == "Select objects to rotate first")
        _ = tool.handle(.click(Self.center), context: ctx)
        #expect(tool.status == "Specify reference point")
        _ = tool.handle(.click(Self.reference), context: ctx)
        #expect(tool.status == "Specify target angle")
    }

    @Test("empty selection keeps the select-first status")
    func statusEmptySelection() {
        let tool = RotateTool()
        #expect(tool.status == "Select objects to rotate first")
    }

    // MARK: - Three-click commit

    @Test("center + reference + target commits one .replace per id, rotated 90° about the center")
    func threeClicksCommitRotated() {
        var tool = RotateTool()
        let ctx = selectionContext()

        let first = tool.handle(.click(Self.center), context: ctx)
        #expect(first == .none)   // center click only captures + advances state
        let second = tool.handle(.click(Self.reference), context: ctx)
        #expect(second == .none)  // reference click only fixes the zero angle

        let outcome = tool.handle(.click(Self.target), context: ctx)
        guard let kinds = replacedKinds(outcome) else {
            Issue.record("expected a .commit of only .replace edits"); return
        }
        // One replace per selected entity (line + circle), keyed by their ids.
        #expect(kinds.count == 2)

        // The line (0,0)→(10,0) rotates 90° CCW about the origin to (0,0)→(0,10).
        guard case .line(let rotatedLine)? = kinds[Self.lineID] else {
            Issue.record("line was not replaced with a line"); return
        }
        #expect(vecClose(rotatedLine.start, Vector(0, 0)))
        #expect(vecClose(rotatedLine.end, Vector(0, 10)))

        // The circle center (10,0) rotates 90° CCW about the origin to (0,10);
        // radius is unchanged.
        guard case .circle(let rotatedCircle)? = kinds[Self.circleID] else {
            Issue.record("circle was not replaced with a circle"); return
        }
        #expect(vecClose(rotatedCircle.center, Vector(0, 10)))
        #expect(abs(rotatedCircle.radius - 2) < Self.tol)
    }

    @Test("commit ends the run: tool resets to pick-center for the next rotate")
    func commitResetsState() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = rotate(&tool, ctx: ctx, center: Self.center, reference: Self.reference, target: Self.target)
        // After the commit the tool is back at the initial state.
        #expect(tool.status == "Select objects to rotate first")
        #expect(tool.preview.isEmpty)
    }

    @Test("a non-axis-aligned reference still measures the angle relative to it")
    func rotationRelativeToReference() {
        var tool = RotateTool()
        let ctx = selectionContext()
        // Reference along +Y (refAngle = 90°), target along -X (180°): the swept
        // angle is 180 − 90 = 90° CCW, same as the canonical case.
        let outcome = rotate(&tool, ctx: ctx,
                             center: Vector(0, 0),
                             reference: Vector(0, 5),
                             target: Vector(-5, 0))
        guard let kinds = replacedKinds(outcome),
              case .line(let rotatedLine)? = kinds[Self.lineID] else {
            Issue.record("expected a rotated line"); return
        }
        // 90° CCW: (0,0)→(10,0) becomes (0,0)→(0,10).
        #expect(vecClose(rotatedLine.start, Vector(0, 0)))
        #expect(vecClose(rotatedLine.end, Vector(0, 10)))
    }

    // MARK: - Preview

    @Test("preview is empty before the reference point is fixed")
    func previewEmptyBeforeReference() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        // In pickingRef: a move does not yet drive a preview.
        _ = tool.handle(.move(Vector(5, 5)), context: ctx)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview shows the selection rotated toward the cursor after the reference is fixed")
    func previewRotated() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)   // refAngle = 0

        // Cursor along +Y → 90° CCW preview.
        let outcome = tool.handle(.move(Self.target), context: ctx)
        #expect(outcome == .preview)

        let preview = tool.preview
        #expect(!preview.isEmpty)

        // The line preview (a single 2-point polyline) is rotated to (0,0)→(0,10).
        let linePreview = preview.first { $0.points.count == 2 }
        #expect(linePreview != nil)
        if let linePreview {
            #expect(vecClose(linePreview.points.first ?? .invalid, Vector(0, 0)))
            #expect(vecClose(linePreview.points.last ?? .invalid, Vector(0, 10)))
        }

        // Every preview polyline uses the shared preview pen.
        #expect(preview.allSatisfy { $0.pen == .toolPreview })

        // The circle preview (a closed ring) is present and recentered at (0,10).
        let ring = preview.first { $0.closed }
        #expect(ring != nil)
        if let ring {
            let n = Double(ring.points.count)
            let cx = ring.points.reduce(0.0) { $0 + $1.x } / n
            let cy = ring.points.reduce(0.0) { $0 + $1.y } / n
            #expect(abs(cx - 0) < 1e-6)
            #expect(abs(cy - 10) < 1e-6)
        }
    }

    // MARK: - Empty selection no-op

    @Test("empty selection: clicks and moves are no-ops, no commit, no preview")
    func emptySelectionNoOp() {
        var tool = RotateTool()
        let ctx = emptyContext()

        let click1 = tool.handle(.click(Self.center), context: ctx)
        #expect(click1 == .none)
        #expect(tool.preview.isEmpty)
        // Still in the initial state (the click did not fix a center).
        #expect(tool.status == "Select objects to rotate first")

        let move = tool.handle(.move(Vector(3, 3)), context: ctx)
        #expect(move == .none)
        #expect(tool.preview.isEmpty)

        // Further clicks without a captured selection also do nothing.
        let click2 = tool.handle(.click(Vector(9, 9)), context: ctx)
        #expect(click2 == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Cancel / backspace reset

    @Test("cancel discards the run, resets state, and reports .finished")
    func cancelResets() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        _ = tool.handle(.move(Self.target), context: ctx)
        #expect(!tool.preview.isEmpty)   // mid-run preview exists

        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to rotate first")
    }

    @Test("backspace steps target → reference → center, retaining the selection")
    func backspaceStepsBack() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)
        _ = tool.handle(.move(Self.target), context: ctx)
        #expect(!tool.preview.isEmpty)

        // pickingTarget → pickingRef (clears the in-progress preview).
        let step1 = tool.handle(.backspace, context: ctx)
        #expect(step1 == .preview)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify reference point")

        // pickingRef → pickingCenter (selection retained → not the select-first hint).
        let step2 = tool.handle(.backspace, context: ctx)
        #expect(step2 == .preview)
        #expect(tool.status == "Specify rotation center")

        // Re-picking center → reference → target still commits correctly.
        let outcome = rotate(&tool, ctx: ctx, center: Self.center, reference: Self.reference, target: Self.target)
        #expect(replacedKinds(outcome)?.count == 2)
    }

    @Test("backspace in pickingCenter is a no-op")
    func backspaceInCenterNoOp() {
        var tool = RotateTool()
        let ctx = selectionContext()
        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Zero angle ignored

    @Test("~zero-angle rotation (target collinear with the reference) is ignored, no commit")
    func zeroAngleIgnored() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)
        _ = tool.handle(.click(Self.reference), context: ctx)   // refAngle = 0

        // Target along the same +X direction as the reference → ~zero swept angle.
        let outcome = tool.handle(.click(Vector(20, 0)), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify target angle")   // still waiting

        // A real target afterwards still commits.
        let real = tool.handle(.click(Self.target), context: ctx)
        #expect(replacedKinds(real)?.count == 2)
    }

    @Test("a reference coincident with the center is ignored (no direction)")
    func referenceAtCenterIgnored() {
        var tool = RotateTool()
        let ctx = selectionContext()
        _ = tool.handle(.click(Self.center), context: ctx)

        // Reference == center has no direction → stays in pickingRef.
        let outcome = tool.handle(.click(Self.center), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify reference point")

        // A real reference then a target still commits.
        _ = tool.handle(.click(Self.reference), context: ctx)
        let real = tool.handle(.click(Self.target), context: ctx)
        #expect(replacedKinds(real)?.count == 2)
    }

    // MARK: - Rotate-a-copy (keepOriginal — W1-1B)

    /// Distinctive, non-default identity so the copy path's metadata preservation is
    /// actually observable (a named layer, a `.byBlock` pen, an extra flag, paper
    /// space + a layout) — none of which equals the `EntityRecord` defaults.
    private static let taggedLayer = LayerID("walls")
    private static let taggedPen = Pen(lineColor: .byBlock)
    private static let taggedFlags: EntityFlags = [.visible, .selected]

    /// The line + circle fixtures, but carrying the distinctive identity above.
    private func taggedContext() -> ToolContext {
        let line = EntityRecord(
            id: Self.lineID, layer: Self.taggedLayer, pen: Self.taggedPen,
            flags: Self.taggedFlags,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))),
            space: .paper, layoutName: "Layout1")
        let circle = EntityRecord(
            id: Self.circleID, layer: Self.taggedLayer, pen: Self.taggedPen,
            flags: Self.taggedFlags,
            kind: .circle(CircleData(center: Vector(10, 0), radius: 2)),
            space: .paper, layoutName: "Layout1")
        let records = [line, circle]
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    /// Pulls the `.add`ed records out of a `.commit` (returns nil if the outcome
    /// isn't a `.commit` of ONLY `.add` edits — so a stray `.replace` fails the test).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var out: [EntityRecord] = []
        for edit in edits {
            guard case .add(let record) = edit else { return nil }
            out.append(record)
        }
        return out
    }

    @Test("keepOriginal=true commits ONLY .add copies (placeholder id; identity preserved; geometry rotated)")
    func keepOriginalCommitsOnlyAdds() {
        var tool = RotateTool()
        tool.keepOriginal = true
        let ctx = taggedContext()

        let outcome = rotate(&tool, ctx: ctx,
                             center: Self.center, reference: Self.reference, target: Self.target)
        guard let added = addedRecords(outcome) else {
            Issue.record("expected a .commit of only .add edits"); return
        }
        // One ADD per selected entity (originals are left untouched — no .replace).
        #expect(added.count == 2)

        // Every copy carries the placeholder id (the app re-mints on add) and
        // preserves the source's full identity — layer/pen/flags + space/layout.
        for record in added {
            #expect(record.id == .placeholder)
            #expect(record.layer == Self.taggedLayer)
            #expect(record.pen == Self.taggedPen)
            #expect(record.flags == Self.taggedFlags)
            #expect(record.space == .paper)
            #expect(record.layoutName == "Layout1")
        }

        // The line copy is rotated 90° CCW about the origin to (0,0)→(0,10).
        guard let lineRec = added.first(where: { if case .line = $0.kind { return true } else { return false } }),
              case .line(let rotatedLine) = lineRec.kind else {
            Issue.record("expected a rotated line copy"); return
        }
        #expect(vecClose(rotatedLine.start, Vector(0, 0)))
        #expect(vecClose(rotatedLine.end, Vector(0, 10)))

        // The circle copy's center rotates (10,0) → (0,10); radius unchanged.
        guard let circleRec = added.first(where: { if case .circle = $0.kind { return true } else { return false } }),
              case .circle(let rotatedCircle) = circleRec.kind else {
            Issue.record("expected a rotated circle copy"); return
        }
        #expect(vecClose(rotatedCircle.center, Vector(0, 10)))
        #expect(abs(rotatedCircle.radius - 2) < Self.tol)
    }

    @Test("default (keepOriginal=false) still commits .replace edits — no .add (regression guard)")
    func defaultModeStillReplaces() {
        var tool = RotateTool()              // keepOriginal defaults to false
        #expect(tool.keepOriginal == false)
        let ctx = selectionContext()

        let outcome = rotate(&tool, ctx: ctx,
                             center: Self.center, reference: Self.reference, target: Self.target)
        // replacedKinds returns nil unless the commit is ONLY .replace edits.
        #expect(replacedKinds(outcome)?.count == 2)
        // And it is emphatically NOT an .add commit.
        #expect(addedRecords(outcome) == nil)
    }

    @Test("the .add copy geometry equals the .replace geometry for identical picks")
    func copyGeometryEqualsReplaceGeometry() {
        // Replace path (keepOriginal=false).
        var replaceTool = RotateTool()
        let outcomeReplace = rotate(&replaceTool, ctx: selectionContext(),
                                    center: Self.center, reference: Self.reference, target: Self.target)
        guard let replacedKinds = replacedKinds(outcomeReplace) else {
            Issue.record("expected a .replace commit"); return
        }

        // Copy path (keepOriginal=true) — same selection, same three picks.
        var copyTool = RotateTool()
        copyTool.keepOriginal = true
        let outcomeCopy = rotate(&copyTool, ctx: selectionContext(),
                                 center: Self.center, reference: Self.reference, target: Self.target)
        guard let added = addedRecords(outcomeCopy) else {
            Issue.record("expected an .add commit"); return
        }

        // The set of rotated kinds is identical between the two paths (EntityKind is
        // Hashable): the copy rotates byte-for-byte the same as the in-place replace,
        // differing only in WHICH edit (.add vs .replace) carries it.
        #expect(Set(added.map { $0.kind }) == Set(replacedKinds.values))
    }

    // MARK: - Typed coordinate (.value) parity with .click

    @Test(".value(p) is treated exactly like .click(p): typed center/reference/target rotates the same")
    func typedValueMatchesClick() {
        // Drive one run with typed values, another with clicks — identical picks.
        var typed = RotateTool()
        let ctxA = selectionContext()
        _ = typed.handle(.value(Self.center), context: ctxA)
        _ = typed.handle(.value(Self.reference), context: ctxA)
        let typedOutcome = typed.handle(.value(Self.target), context: ctxA)

        var clicked = RotateTool()
        let typedClick = rotate(&clicked, ctx: selectionContext(),
                                center: Self.center, reference: Self.reference, target: Self.target)

        #expect(typedOutcome == typedClick)
        #expect(replacedKinds(typedOutcome)?.count == 2)
    }

    @Test(".value with an empty selection is still a no-op (nothing to rotate)")
    func typedValueEmptySelectionNoOp() {
        var tool = RotateTool()
        let outcome = tool.handle(.value(Vector(5, 5)), context: emptyContext())
        #expect(outcome == .none)
        #expect(tool.status == "Select objects to rotate first")
    }
}
