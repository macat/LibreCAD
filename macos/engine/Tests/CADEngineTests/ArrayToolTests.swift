//
//  ArrayToolTests.swift
//  CADEngineTests
//
//  Drives the ARRAY modify tool PURELY (no GUI): feeds `ToolInput` events + a
//  read-only `ToolContext` carrying a known selection and asserts the array
//  contract — a RECTANGULAR (rows × cols) array emits `rows*cols − 1` `.add`
//  copies at the right grid offsets, and a POLAR array places `count − 1` copies
//  rotated about the center over the total sweep. Also covers attr preservation,
//  the placeholder id, the empty-selection no-op, and cancel/reset.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ArrayTool modify (rectangular + polar array)")
struct ArrayToolTests {

    // MARK: - Fixtures

    /// A selected LINE with distinctive attrs so attr-preservation is observable.
    private static let selectedLine = EntityRecord(
        id: EntityID(101),
        layer: LayerID("walls"),
        pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
        flags: [.visible, .selected],
        kind: .line(LineData(start: Vector(0, 0), end: Vector(2, 0)))
    )

    private func lineContext() -> ToolContext {
        let sel = [Self.selectedLine]
        return ToolContext(
            selected: sel,
            entity: { id in sel.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    /// Pulls the ordered `.add` records out of a `.commit` (nil if not pure-add).
    private func addedRecords(_ outcome: ToolOutcome) -> [EntityRecord]? {
        guard case .commit(let edits) = outcome else { return nil }
        var records: [EntityRecord] = []
        for edit in edits {
            guard case .add(let r) = edit else { return nil }
            records.append(r)
        }
        return records
    }

    private func approxEqual(_ a: Vector, _ b: Vector, eps: Double = 1e-9) -> Bool {
        a.distance(to: b) < eps
    }

    // MARK: - Basics

    @Test("title is Array")
    func title() {
        #expect(ArrayTool().title == "Array")
    }

    @Test("status nudges to select first when nothing is selected")
    func statusEmptySelection() {
        #expect(ArrayTool().status == "Select objects to array first")
    }

    @Test("a fire with an empty selection is a no-op (rectangular)")
    func emptySelectionNoop() {
        var tool = ArrayTool(config: .rectangular(rows: 2, cols: 2, spacing: Vector(1, 1)))
        let outcome = tool.handle(.commit, context: .empty)
        // Nothing captured → commit just finishes (no edits).
        #expect(outcome == .finished)
    }

    // MARK: - Rectangular array

    @Test("rectangular R×C array of a line emits R*C − 1 copies")
    func rectangularCount() {
        var tool = ArrayTool(config: .rectangular(rows: 2, cols: 3, spacing: Vector(5, 4)))
        let outcome = tool.handle(.commit, context: lineContext())
        let records = addedRecords(outcome)
        #expect(records != nil)
        // 2*3 = 6 slots; the origin slot is the original → 5 copies.
        #expect(records?.count == 5)
    }

    @Test("rectangular copies land at the right grid offsets")
    func rectangularOffsets() {
        var tool = ArrayTool(config: .rectangular(rows: 2, cols: 2, spacing: Vector(10, 7)))
        let records = addedRecords(tool.handle(.commit, context: lineContext()))
        #expect(records?.count == 3)   // 4 slots − origin

        // Expected offsets for the non-origin slots of a 2×2 grid (col×x, row×y):
        //   (1,0) → (10, 0), (0,1) → (0, 7), (1,1) → (10, 7).
        let expectedStarts: Set<[Double]> = [
            [10, 0], [0, 7], [10, 7]
        ]
        var gotStarts: Set<[Double]> = []
        for r in records ?? [] {
            guard case .line(let l) = r.kind else {
                Issue.record("expected a line copy"); return
            }
            // original start was (0,0), so the copy's start IS the offset.
            gotStarts.insert([l.start.x, l.start.y])
        }
        #expect(gotStarts == expectedStarts)
    }

    @Test("rectangular copies preserve the original's layer/pen/flags and use the placeholder id")
    func rectangularAttrs() {
        var tool = ArrayTool(config: .rectangular(rows: 1, cols: 2, spacing: Vector(3, 0)))
        let records = addedRecords(tool.handle(.commit, context: lineContext()))
        #expect(records?.count == 1)
        let copy = records![0]
        #expect(copy.id == .placeholder)
        #expect(copy.layer == Self.selectedLine.layer)
        #expect(copy.pen == Self.selectedLine.pen)
        #expect(copy.flags == Self.selectedLine.flags)
    }

    @Test("a 1×1 rectangular array commits nothing (only the origin slot)")
    func rectangularSingleSlot() {
        var tool = ArrayTool(config: .rectangular(rows: 1, cols: 1, spacing: Vector(5, 5)))
        let outcome = tool.handle(.commit, context: lineContext())
        // No non-origin slots → no edits; the fire finishes the run.
        #expect(outcome == .finished)
    }

    // MARK: - Polar array

    @Test("polar array with a config center places count − 1 rotated copies")
    func polarCountWithConfigCenter() {
        let center = Vector(0, 0)
        var tool = ArrayTool(config: .polar(count: 4, center: center,
                                            totalAngle: 2 * Double.pi, rotateItems: true))
        let records = addedRecords(tool.handle(.commit, context: lineContext()))
        #expect(records != nil)
        #expect(records?.count == 3)   // count − 1
    }

    @Test("polar full-circle: copy k is the selection rotated by k·(360/count) about the center")
    func polarFullCircleAngles() {
        let center = Vector(0, 0)
        let count = 4
        var tool = ArrayTool(config: .polar(count: count, center: center,
                                            totalAngle: 2 * Double.pi, rotateItems: true))
        let records = addedRecords(tool.handle(.commit, context: lineContext()))
        #expect(records?.count == 3)

        // Original line (0,0)→(2,0). For a full circle the step is 2π/count = 90°.
        // Copy 1 → rotated 90°: (0,0)→(0,2). Copy 2 → 180°: (0,0)→(-2,0).
        // Copy 3 → 270°: (0,0)→(0,-2).
        let step = (2 * Double.pi) / Double(count)
        for (k, r) in (records ?? []).enumerated() {
            guard case .line(let l) = r.kind else {
                Issue.record("expected a line copy"); return
            }
            let angle = step * Double(k + 1)
            let expectedEnd = center + Vector.polar(radius: 2, angle: angle)
            #expect(approxEqual(l.start, center))           // start stays at center
            #expect(approxEqual(l.end, expectedEnd))
        }
    }

    @Test("polar partial sweep includes the endpoint (step = total/(count−1))")
    func polarPartialSweepEndpoints() {
        let center = Vector(0, 0)
        let count = 3
        let total = Double.pi / 2   // 90° over 3 positions → step 45°.
        var tool = ArrayTool(config: .polar(count: count, center: center,
                                            totalAngle: total, rotateItems: true))
        let records = addedRecords(tool.handle(.commit, context: lineContext()))
        #expect(records?.count == 2)

        let step = total / Double(count - 1)   // 45°
        // Copy 1 → 45°, copy 2 → 90° (the endpoint of the sweep).
        for (k, r) in (records ?? []).enumerated() {
            guard case .line(let l) = r.kind else {
                Issue.record("expected a line copy"); return
            }
            let expectedEnd = center + Vector.polar(radius: 2, angle: step * Double(k + 1))
            #expect(approxEqual(l.end, expectedEnd))
        }
    }

    @Test("polar without a config center picks the center on the first click")
    func polarPicksCenter() {
        var tool = ArrayTool(config: .polar(count: 4, center: nil,
                                            totalAngle: 2 * Double.pi, rotateItems: true))
        let ctx = lineContext()
        // Before a center is picked, the status asks for it.
        _ = tool.handle(.move(Vector(9, 9)), context: ctx)
        #expect(tool.status == "Specify the array center")
        // A commit with no center yet is a no-op (still waiting).
        #expect(tool.handle(.commit, context: ctx) == .none)
        // A click supplies the center and fires.
        let center = Vector(5, 5)
        let records = addedRecords(tool.handle(.click(center), context: ctx))
        #expect(records?.count == 3)
        // Copy 1 is the line (0,0)→(2,0) rotated 90° about (5,5):
        //   (0,0) → (10,0); (2,0) → (10,2). (Rotating about a non-origin pivot.)
        guard case .line(let l) = records![0].kind else {
            Issue.record("expected a line copy"); return
        }
        let rot = Affine2D.rotation(angle: Double.pi / 2, about: center)
        #expect(approxEqual(l.start, rot.apply(Vector(0, 0))))
        #expect(approxEqual(l.end, rot.apply(Vector(2, 0))))
    }

    @Test("polar with count ≤ 1 commits nothing")
    func polarDegenerateCount() {
        var tool = ArrayTool(config: .polar(count: 1, center: Vector(0, 0),
                                            totalAngle: 2 * Double.pi, rotateItems: true))
        let outcome = tool.handle(.commit, context: lineContext())
        #expect(outcome == .finished)   // no copies → just finishes
    }

    // MARK: - Originals untouched

    @Test("array only emits .add edits — never .replace/.remove")
    func originalsUntouched() {
        var tool = ArrayTool(config: .rectangular(rows: 2, cols: 2, spacing: Vector(1, 1)))
        guard case .commit(let edits) = tool.handle(.commit, context: lineContext()) else {
            Issue.record("expected a commit"); return
        }
        for edit in edits {
            switch edit {
            case .add: break
            case .replace, .remove: Issue.record("Array must not modify originals: \(edit)")
            }
        }
    }

    // MARK: - Cancel

    @Test("cancel discards the captured selection and finishes")
    func cancelResets() {
        var tool = ArrayTool(config: .rectangular(rows: 2, cols: 2, spacing: Vector(1, 1)))
        let ctx = lineContext()
        _ = tool.handle(.move(Vector(1, 1)), context: ctx)   // captures selection
        #expect(tool.status == "Press Return to create the rectangular array")
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.status == "Select objects to array first")
    }

    // MARK: - Preview

    @Test("rectangular preview shows the copies as soon as a selection is captured")
    func rectangularPreview() {
        var tool = ArrayTool(config: .rectangular(rows: 2, cols: 2, spacing: Vector(3, 3)))
        let ctx = lineContext()
        _ = tool.handle(.move(Vector(0, 0)), context: ctx)   // captures
        // 3 copies × 1 polyline each (a line resolves to one polyline).
        #expect(tool.preview.count == 3)
        #expect(tool.preview.allSatisfy { $0.pen == .toolPreview })
    }
}
