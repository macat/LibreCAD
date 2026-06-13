//
//  ChainDimContinueTests.swift
//  CADEngineTests
//
//  Tests for the ContinueDimTool (w4b-baseline, UNWIRED until a later wire-wave):
//  the chained linear-dimension tool whose each new dim continues from the PREVIOUS
//  dim's second extension origin (a running chain), all at ONE shared dimension-line
//  level. Drives the tool's `.click`/`.move`/`.value`/`.commit` state machine with
//  NO GUI, asserting it authors the correct end-to-start chain of
//  `.dimension(.linear)` records (same Tool-contract exercise the other dimension
//  tools use).
//
//  Suite/type names are domain-namespaced (`ChainDimContinue*`) per CONVENTIONS.md.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Continue dimension tool")
struct ChainDimContinueTests {

    // MARK: - Helpers

    private func committedLinear(_ outcome: ToolOutcome)
        -> (e1: Vector, e2: Vector, angle: Double, def: Vector)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let rec) = edits[0], case .dimension(let d) = rec.kind,
              case .linear(let e1, let e2, let angle) = d.kind else {
            return nil
        }
        return (e1, e2, angle, d.definitionPoint)
    }

    private func ctx(_ entities: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: [],
            entity: { id in entities.first { $0.id == id } },
            gridSpacing: nil,
            nearbyEntities: { _, _ in entities }
        )
    }

    /// A horizontal base linear dim: origins (0,0)→(10,0), dim line at y=-3.
    private func baseDimEntity() -> EntityRecord {
        EntityRecord(
            id: EntityID(1),
            kind: .dimension(DimData(
                kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
                definitionPoint: Vector(5, -3)
            ))
        )
    }

    // MARK: - Seed-from-points: 3 points → first dim, then continue

    @Test("Continue of 3 feature points → 2 dims chained end-to-start at one level")
    func seedThenTwoChained() {
        var tool = ContinueDimTool()
        // SEED the first dim: origin1, origin2, dim-line location.
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)
        let first = tool.handle(.click(Vector(5, -3)), context: .empty)
        guard let f = committedLinear(first) else {
            Issue.record("expected first dim commit"); return
        }
        #expect(f.e1.distance(to: Vector(0, 0)) < 1e-9)
        #expect(f.e2.distance(to: Vector(10, 0)) < 1e-9)
        #expect(abs(f.def.y - (-3)) < 1e-9)

        // CONTINUE: feature #1 → dim from the prev dim's SECOND origin (10,0) to it.
        let c1 = tool.handle(.click(Vector(18, 0)), context: .empty)
        guard let d1 = committedLinear(c1) else {
            Issue.record("expected continued dim #1"); return
        }
        #expect(d1.e1.distance(to: Vector(10, 0)) < 1e-9)  // continues from prev e2
        #expect(d1.e2.distance(to: Vector(18, 0)) < 1e-9)  // new feature
        #expect(abs(d1.angle) < 1e-9)
        #expect(abs(d1.def.y - (-3)) < 1e-9)               // SAME level as the seed

        // CONTINUE: feature #2 → dim from #1's second origin (18,0).
        let c2 = tool.handle(.click(Vector(26, 0)), context: .empty)
        guard let d2 = committedLinear(c2) else {
            Issue.record("expected continued dim #2"); return
        }
        #expect(d2.e1.distance(to: Vector(18, 0)) < 1e-9)  // continues from #1's e2
        #expect(d2.e2.distance(to: Vector(26, 0)) < 1e-9)
        #expect(abs(d2.def.y - (-3)) < 1e-9)               // STILL the same level

        // End-to-start: #1's e2 == #2's e1; all three dims share the dim-line level.
        #expect(d1.e2.distance(to: d2.e1) < 1e-9)
        #expect(abs(f.def.y - d1.def.y) < 1e-9)
        #expect(abs(d1.def.y - d2.def.y) < 1e-9)
    }

    // MARK: - Pick an existing base dim, then continue

    @Test("Picking an existing linear dim continues from its second origin at its level")
    func pickBaseThenContinue() {
        var tool = ContinueDimTool()
        let context = ctx([baseDimEntity()])
        // First click picks the starting dim (no commit).
        #expect(tool.handle(.click(Vector(5, -3)), context: context) == .none)
        // Next click is a feature point → continues from the picked dim's e2=(10,0).
        let c1 = tool.handle(.click(Vector(25, 0)), context: context)
        guard let d1 = committedLinear(c1) else {
            Issue.record("expected continued dim after base pick"); return
        }
        #expect(d1.e1.distance(to: Vector(10, 0)) < 1e-9)  // adopted base e2
        #expect(d1.e2.distance(to: Vector(25, 0)) < 1e-9)
        #expect(abs(d1.angle) < 1e-9)                       // adopted base angle
        #expect(abs(d1.def.y - (-3)) < 1e-9)               // adopted base level
    }

    // MARK: - Typed coordinates, degenerate picks, cancel

    @Test("Typed coordinates (.value) seed and continue like clicks")
    func typedValues() {
        var tool = ContinueDimTool()
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(10, 0)), context: .empty)
        #expect(committedLinear(tool.handle(.value(Vector(5, -2)), context: .empty)) != nil)
        let c = tool.handle(.value(Vector(20, 0)), context: .empty)
        guard let d = committedLinear(c) else { Issue.record("expected continue"); return }
        #expect(d.e1.distance(to: Vector(10, 0)) < 1e-9)
    }

    @Test("A coincident continue feature is ignored (no zero-length dim)")
    func coincidentFeatureIgnored() {
        var tool = ContinueDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)   // first dim
        // Feature exactly on the running origin (10,0) → no commit.
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)
    }

    @Test("Cancel finishes the run without committing")
    func cancelFinishes() {
        var tool = ContinueDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }

    @Test("Commit (Return) ends the run without an extra dim")
    func commitFinishes() {
        var tool = ContinueDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)
        #expect(tool.handle(.commit, context: .empty) == .finished)
    }

    // MARK: - Vertical chain (non-zero angle) keeps the running origin advancing

    @Test("Continue along a vertical base advances the running origin up the chain")
    func verticalChain() {
        var tool = ContinueDimTool()
        // Vertical seed: origins (0,0)→(0,10), angle π/2, dim line at x=-3.
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        let first = tool.handle(.click(Vector(-3, 5)), context: .empty)
        guard let f = committedLinear(first) else { Issue.record("seed"); return }
        #expect(abs(f.angle - Double.pi / 2) < 1e-6)
        let c1 = tool.handle(.click(Vector(0, 18)), context: .empty)
        guard let d1 = committedLinear(c1) else { Issue.record("continue"); return }
        #expect(d1.e1.distance(to: Vector(0, 10)) < 1e-9)  // continues from e2
        #expect(d1.e2.distance(to: Vector(0, 18)) < 1e-9)
        #expect(abs(d1.def.x - (-3)) < 1e-9)               // same level
    }

    // MARK: - Preview + status

    @Test("Preview is non-empty while continuing once the chain is set")
    func previewWhileChaining() {
        var tool = ContinueDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)
        #expect(tool.handle(.move(Vector(20, 0)), context: .empty) == .preview)
        #expect(!tool.preview.isEmpty)
    }

    @Test("Title + status reflect the continue tool state")
    func titleAndStatus() {
        var tool = ContinueDimTool()
        #expect(tool.title == "Continue Dimension")
        #expect(tool.status.contains("starting dimension"))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)
        #expect(tool.status.contains("continue"))
    }
}
