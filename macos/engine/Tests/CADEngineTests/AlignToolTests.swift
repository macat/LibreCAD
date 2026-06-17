//
//  AlignToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Align tool PURELY (no GUI): feeds `ToolInput` events +
//  a read-only `ToolContext` (with a known selection) to `AlignTool` and asserts
//  the align math (the source point pair maps onto the destination point pair),
//  the scale-to-fit toggle (scale = |dst2−dst1| / |src2−src1| vs rotate-only size
//  preservation), the live preview, the empty-selection no-op, and the
//  cancel / backspace resets.
//
//  Canonical brief geometry:
//    • source pair (0,0)–(1,0) → destination (5,5)–(5,6): a point on the source
//      segment maps onto the destination segment.
//    • scale-to-fit doubles a selection when the destination distance is 2× the
//      source distance.
//    • rotate-only preserves size.
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

@Suite("AlignTool interactive modify")
struct AlignToolTests {

    // MARK: - Fixtures

    /// A line from (0,0) to (1,0), id 1 — coincides with the canonical source
    /// segment so the align maps its endpoints onto the destination segment.
    private static let lineID = EntityID(1)
    private func lineRecord() -> EntityRecord {
        EntityRecord(id: Self.lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
    }

    /// A circle centered at (0,0) with radius 1, id 2 — handy for asserting that
    /// scale-to-fit doubles its radius and the center lands on destination 1.
    private static let circleID = EntityID(2)
    private func circleRecord() -> EntityRecord {
        EntityRecord(id: Self.circleID, kind: .circle(CircleData(center: Vector(0, 0), radius: 1)))
    }

    /// A `ToolContext` whose selection is the given records.
    private func context(_ records: [EntityRecord]) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(selected: records, entity: { byID[$0] }, gridSpacing: nil)
    }

    /// An empty `ToolContext` (no selection).
    private func emptyContext() -> ToolContext { .empty }

    // The canonical brief point pairs.
    private static let src1 = Vector(0, 0)
    private static let src2 = Vector(1, 0)
    private static let dst1 = Vector(5, 5)
    private static let dst2 = Vector(5, 6)   // |dst2−dst1| = 1 (same length as src)

    private static let tol = 1e-9

    private func vecClose(_ a: Vector, _ b: Vector, _ eps: Double = tol) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
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

    /// Drives src1 → dst1 → src2 → dst2 clicks and returns the final outcome.
    private func align(_ tool: inout AlignTool, ctx: ToolContext,
                       src1: Vector, dst1: Vector, src2: Vector, dst2: Vector) -> ToolOutcome {
        _ = tool.handle(.click(src1), context: ctx)
        _ = tool.handle(.click(dst1), context: ctx)
        _ = tool.handle(.click(src2), context: ctx)
        return tool.handle(.click(dst2), context: ctx)
    }

    // MARK: - Metadata / status

    @Test("title is Align")
    func title() {
        #expect(AlignTool().title == "Align")
    }

    @Test("with a selection the status walks the four picks")
    func statusWithSelection() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        // The tool only learns the selection once source 1 is picked, so the
        // first prompt is the select-first hint until then.
        #expect(tool.status == "Select objects to align first")
        _ = tool.handle(.click(Self.src1), context: ctx)
        #expect(tool.status == "Specify first destination point")
        _ = tool.handle(.click(Self.dst1), context: ctx)
        #expect(tool.status == "Specify second source point")
        _ = tool.handle(.click(Self.src2), context: ctx)
        #expect(tool.status == "Specify second destination point")
    }

    @Test("empty selection keeps the select-first status")
    func statusEmptySelection() {
        #expect(AlignTool().status == "Select objects to align first")
    }

    @Test("scaleToFit defaults to true (AutoCAD default)")
    func scaleToFitDefault() {
        #expect(AlignTool().scaleToFit == true)
        #expect(AlignTool(scaleToFit: false).scaleToFit == false)
    }

    // MARK: - Brief case 1: a point on the source line maps onto the dest line

    @Test("source pair (0,0)-(1,0) → dest (5,5)-(5,6) maps the source line onto the dest line")
    func sourceLineMapsOntoDestLine() {
        var tool = AlignTool()              // scale-to-fit on (default)
        let ctx = context([lineRecord()])

        let c1 = tool.handle(.click(Self.src1), context: ctx)
        #expect(c1 == .none)               // source 1 only captures + advances
        let c2 = tool.handle(.click(Self.dst1), context: ctx)
        #expect(c2 == .none)
        let c3 = tool.handle(.click(Self.src2), context: ctx)
        #expect(c3 == .none)

        let outcome = tool.handle(.click(Self.dst2), context: ctx)
        guard let kinds = replacedKinds(outcome),
              case .line(let mapped)? = kinds[Self.lineID] else {
            Issue.record("expected a .commit replacing the line"); return
        }
        // The line endpoints coincide with the source pair, so they map exactly
        // onto the destination pair (a point on the source line lands on the dest
        // line). src1(0,0)→dst1(5,5); src2(1,0)→dst2(5,6).
        #expect(vecClose(mapped.start, Self.dst1))
        #expect(vecClose(mapped.end, Self.dst2))
    }

    @Test("a point on the source segment maps onto the destination segment")
    func midpointMapsOntoDestSegment() {
        // A line whose endpoints ARE the source pair: its midpoint (0.5,0) must
        // land on the destination segment's midpoint (5,5.5).
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        let outcome = align(&tool, ctx: ctx, src1: Self.src1, dst1: Self.dst1,
                            src2: Self.src2, dst2: Self.dst2)
        guard let kinds = replacedKinds(outcome),
              case .line(let mapped)? = kinds[Self.lineID] else {
            Issue.record("expected a mapped line"); return
        }
        let mid = (mapped.start + mapped.end) * 0.5
        #expect(vecClose(mid, Vector(5, 5.5)))
    }

    // MARK: - Brief case 2: scale-to-fit doubles when dest is 2× the source

    @Test("scale-to-fit doubles a selection when the destination distance is 2× the source")
    func scaleToFitDoubles() {
        var tool = AlignTool(scaleToFit: true)
        let ctx = context([circleRecord()])   // radius 1 at origin
        // Source pair length 1 ((0,0)-(1,0)); destination pair length 2
        // ((0,0)-(0,2)) → uniform scale 2, plus a 90° rotation. The circle's
        // center sits at src1, so it lands on dst1 with radius doubled.
        let outcome = align(&tool, ctx: ctx,
                            src1: Vector(0, 0), dst1: Vector(0, 0),
                            src2: Vector(1, 0), dst2: Vector(0, 2))
        guard let kinds = replacedKinds(outcome),
              case .circle(let mapped)? = kinds[Self.circleID] else {
            Issue.record("expected a mapped circle"); return
        }
        #expect(vecClose(mapped.center, Vector(0, 0)))
        #expect(abs(mapped.radius - 2) < Self.tol)   // doubled
    }

    @Test("scale-to-fit maps the source endpoints exactly onto the destination pair")
    func scaleToFitMapsBothEndpointsExactly() {
        var tool = AlignTool(scaleToFit: true)
        let ctx = context([lineRecord()])     // line (0,0)-(1,0) == source pair
        let outcome = align(&tool, ctx: ctx,
                            src1: Vector(0, 0), dst1: Vector(0, 0),
                            src2: Vector(1, 0), dst2: Vector(0, 2))
        guard let kinds = replacedKinds(outcome),
              case .line(let mapped)? = kinds[Self.lineID] else {
            Issue.record("expected a mapped line"); return
        }
        // Both source endpoints map exactly onto the destination pair.
        #expect(vecClose(mapped.start, Vector(0, 0)))
        #expect(vecClose(mapped.end, Vector(0, 2)))
    }

    // MARK: - Brief case 3: rotate-only preserves size

    @Test("rotate-only preserves size (circle radius unchanged when dest is 2× source)")
    func rotateOnlyPreservesSize() {
        var tool = AlignTool(scaleToFit: false)
        let ctx = context([circleRecord()])   // radius 1 at origin
        // Same picks as the scale-to-fit case (dest 2× source), but scale-to-fit
        // OFF → the circle keeps radius 1; only its center translates/rotates.
        let outcome = align(&tool, ctx: ctx,
                            src1: Vector(0, 0), dst1: Vector(0, 0),
                            src2: Vector(1, 0), dst2: Vector(0, 2))
        guard let kinds = replacedKinds(outcome),
              case .circle(let mapped)? = kinds[Self.circleID] else {
            Issue.record("expected a mapped circle"); return
        }
        #expect(vecClose(mapped.center, Vector(0, 0)))
        #expect(abs(mapped.radius - 1) < Self.tol)   // size preserved
    }

    @Test("rotate-only fixes src1→dst1 and rotates, but does NOT reach dst2 in length")
    func rotateOnlyLengthPreserved() {
        var tool = AlignTool(scaleToFit: false)
        let ctx = context([lineRecord()])     // line (0,0)-(1,0), length 1
        let outcome = align(&tool, ctx: ctx,
                            src1: Vector(0, 0), dst1: Vector(0, 0),
                            src2: Vector(1, 0), dst2: Vector(0, 2))
        guard let kinds = replacedKinds(outcome),
              case .line(let mapped)? = kinds[Self.lineID] else {
            Issue.record("expected a mapped line"); return
        }
        // 90° rotation about the origin, length preserved at 1: (0,0)→(0,1),
        // i.e. it points at dst2's direction but stops at length 1 (not 2).
        #expect(vecClose(mapped.start, Vector(0, 0)))
        #expect(vecClose(mapped.end, Vector(0, 1)))
        #expect(abs((mapped.end - mapped.start).magnitude - 1) < Self.tol)
    }

    // MARK: - Translation-only (collinear pairs, no rotation/scale change)

    @Test("source pair (0,0)-(1,0) → dest (5,5)-(6,5) is a pure translation")
    func pureTranslation() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        // Source and dest segments are parallel (+X) and equal length → no
        // rotation, scale 1; the whole line just shifts by (5,5).
        let outcome = align(&tool, ctx: ctx,
                            src1: Vector(0, 0), dst1: Vector(5, 5),
                            src2: Vector(1, 0), dst2: Vector(6, 5))
        guard let kinds = replacedKinds(outcome),
              case .line(let mapped)? = kinds[Self.lineID] else {
            Issue.record("expected a mapped line"); return
        }
        #expect(vecClose(mapped.start, Vector(5, 5)))
        #expect(vecClose(mapped.end, Vector(6, 5)))
    }

    // MARK: - Multiple entities

    @Test("commit emits one .replace per selected entity")
    func multipleEntitiesAllReplaced() {
        var tool = AlignTool()
        let ctx = context([lineRecord(), circleRecord()])
        let outcome = align(&tool, ctx: ctx, src1: Self.src1, dst1: Self.dst1,
                            src2: Self.src2, dst2: Self.dst2)
        #expect(replacedKinds(outcome)?.count == 2)
    }

    @Test("commit ends the run: tool resets to pick-source-1 for the next align")
    func commitResetsState() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        _ = align(&tool, ctx: ctx, src1: Self.src1, dst1: Self.dst1,
                  src2: Self.src2, dst2: Self.dst2)
        #expect(tool.status == "Select objects to align first")
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Preview

    @Test("preview is empty before the second source point is fixed")
    func previewEmptyBeforeSrc2() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        _ = tool.handle(.click(Self.src1), context: ctx)
        _ = tool.handle(.click(Self.dst1), context: ctx)
        // In pickingSrc2: a move does not yet drive a preview.
        _ = tool.handle(.move(Vector(2, 2)), context: ctx)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview shows the selection aligned toward the cursor after source 2 is fixed")
    func previewAligned() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        _ = tool.handle(.click(Self.src1), context: ctx)
        _ = tool.handle(.click(Self.dst1), context: ctx)
        _ = tool.handle(.click(Self.src2), context: ctx)

        let outcome = tool.handle(.move(Self.dst2), context: ctx)
        #expect(outcome == .preview)

        let preview = tool.preview
        #expect(!preview.isEmpty)

        // The line preview (a single 2-point polyline) is aligned onto the dest
        // pair: (5,5)→(5,6).
        let linePreview = preview.first { $0.points.count == 2 }
        #expect(linePreview != nil)
        if let linePreview {
            #expect(vecClose(linePreview.points.first ?? .invalid, Self.dst1))
            #expect(vecClose(linePreview.points.last ?? .invalid, Self.dst2))
        }
        // Every preview polyline uses the shared preview pen.
        #expect(preview.allSatisfy { $0.pen == .toolPreview })
    }

    // MARK: - Empty selection no-op

    @Test("empty selection: clicks and moves are no-ops, no commit, no preview")
    func emptySelectionNoOp() {
        var tool = AlignTool()
        let ctx = emptyContext()

        let click1 = tool.handle(.click(Self.src1), context: ctx)
        #expect(click1 == .none)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to align first")

        let move = tool.handle(.move(Vector(3, 3)), context: ctx)
        #expect(move == .none)
        #expect(tool.preview.isEmpty)

        let click2 = tool.handle(.click(Vector(9, 9)), context: ctx)
        #expect(click2 == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Degenerate source pair

    @Test("a second source coincident with the first is ignored (no source direction)")
    func coincidentSecondSourceIgnored() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        _ = tool.handle(.click(Self.src1), context: ctx)
        _ = tool.handle(.click(Self.dst1), context: ctx)

        // Source 2 == source 1 → no source segment direction; stay in pickingSrc2.
        let outcome = tool.handle(.click(Self.src1), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify second source point")

        // A real source 2 then a destination 2 still commits.
        _ = tool.handle(.click(Self.src2), context: ctx)
        let real = tool.handle(.click(Self.dst2), context: ctx)
        #expect(replacedKinds(real)?.count == 1)
    }

    // MARK: - Cancel / backspace reset

    @Test("cancel discards the run, resets state, and reports .finished")
    func cancelResets() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        _ = tool.handle(.click(Self.src1), context: ctx)
        _ = tool.handle(.click(Self.dst1), context: ctx)
        _ = tool.handle(.click(Self.src2), context: ctx)
        _ = tool.handle(.move(Self.dst2), context: ctx)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: ctx)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Select objects to align first")
    }

    @Test("backspace steps back through the picks, retaining the selection")
    func backspaceStepsBack() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        _ = tool.handle(.click(Self.src1), context: ctx)
        _ = tool.handle(.click(Self.dst1), context: ctx)
        _ = tool.handle(.click(Self.src2), context: ctx)
        _ = tool.handle(.move(Self.dst2), context: ctx)
        #expect(!tool.preview.isEmpty)

        // pickingDst2 → pickingSrc2 (clears the in-progress preview).
        let step1 = tool.handle(.backspace, context: ctx)
        #expect(step1 == .preview)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify second source point")

        // pickingSrc2 → pickingDst1.
        let step2 = tool.handle(.backspace, context: ctx)
        #expect(step2 == .preview)
        #expect(tool.status == "Specify first destination point")

        // pickingDst1 → pickingSrc1 (selection retained → not the select-first hint).
        let step3 = tool.handle(.backspace, context: ctx)
        #expect(step3 == .preview)
        #expect(tool.status == "Specify first source point")

        // Re-picking all four still commits correctly.
        let outcome = align(&tool, ctx: ctx, src1: Self.src1, dst1: Self.dst1,
                            src2: Self.src2, dst2: Self.dst2)
        #expect(replacedKinds(outcome)?.count == 1)
    }

    @Test("backspace in pickingSrc1 is a no-op")
    func backspaceInSrc1NoOp() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        let outcome = tool.handle(.backspace, context: ctx)
        #expect(outcome == .none)
    }

    // MARK: - Typed coordinate (.value) parity with .click

    @Test("a typed .value coordinate is treated like a .click pick (advances the run)")
    func typedValueFixesPick() {
        var tool = AlignTool()
        let ctx = context([lineRecord()])
        // With a selection, a typed first source point behaves like the first click:
        // it captures the selection and fixes src1 (no commit yet, status advances).
        let outcome = tool.handle(.value(Self.src1), context: ctx)
        #expect(outcome == .none)
        #expect(tool.status == "Specify first destination point")
    }

    @Test(".value with an empty selection is still a no-op (nothing to align)")
    func typedValueEmptySelectionNoOp() {
        var tool = AlignTool()
        let outcome = tool.handle(.value(Vector(7, 7)), context: emptyContext())
        #expect(outcome == .none)
        #expect(tool.status == "Select objects to align first")
    }

    @Test(".value(p) matches .click(p) across all four picks (identical commit)")
    func typedValueMatchesClick() {
        var typed = AlignTool()
        let ctxA = context([lineRecord()])
        _ = typed.handle(.value(Self.src1), context: ctxA)
        _ = typed.handle(.value(Self.dst1), context: ctxA)
        _ = typed.handle(.value(Self.src2), context: ctxA)
        let typedOutcome = typed.handle(.value(Self.dst2), context: ctxA)

        var clicked = AlignTool()
        let clickedOutcome = align(&clicked, ctx: context([lineRecord()]),
                                   src1: Self.src1, dst1: Self.dst1,
                                   src2: Self.src2, dst2: Self.dst2)

        #expect(typedOutcome == clickedOutcome)
        #expect(replacedKinds(typedOutcome)?.count == 1)
    }

    // MARK: - Direct align-math unit (rotation + scale composition)

    @Test("alignTransform composes scale + rotation about src1 onto dst1")
    func alignTransformMath() {
        // src (0,0)-(1,0) → dst (10,10)-(10,12): rotation +90°, scale 2.
        guard let t = AlignTool.alignTransform(
            src1: Vector(0, 0), dst1: Vector(10, 10),
            src2: Vector(1, 0), dst2: Vector(10, 12),
            scaleToFit: true) else {
            Issue.record("expected a non-nil transform"); return
        }
        #expect(vecClose(t.apply(Vector(0, 0)), Vector(10, 10)))   // src1 → dst1
        #expect(vecClose(t.apply(Vector(1, 0)), Vector(10, 12)))   // src2 → dst2
        #expect(abs(t.uniformScale - 2) < Self.tol)                // doubled
    }

    @Test("alignTransform returns nil for a degenerate source pair")
    func alignTransformDegenerate() {
        let t = AlignTool.alignTransform(
            src1: Vector(0, 0), dst1: Vector(5, 5),
            src2: Vector(0, 0), dst2: Vector(5, 6),   // src2 == src1
            scaleToFit: true)
        #expect(t == nil)
    }
}
