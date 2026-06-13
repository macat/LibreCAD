//
//  ChainDimBaselineTests.swift
//  CADEngineTests
//
//  Tests for the BaselineDimTool (w4b-baseline, UNWIRED until a later wire-wave):
//  the chained linear-dimension tool whose successive dims all measure from a COMMON
//  first extension origin (the baseline), each drawn at a dimension line offset
//  further out. Drives the tool's `.click`/`.move`/`.value`/`.commit` state machine
//  with NO GUI, asserting it authors the correct chain of `.dimension(.linear)`
//  records (same Tool-contract exercise the other dimension tools use).
//
//  Suite/type names are domain-namespaced (`ChainDimBaseline*`) per CONVENTIONS.md.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Baseline dimension tool")
struct ChainDimBaselineTests {

    // MARK: - Helpers

    /// Extracts the single committed `.linear` dim from an outcome, or `nil`.
    private func committedLinear(_ outcome: ToolOutcome)
        -> (e1: Vector, e2: Vector, angle: Double, def: Vector)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let rec) = edits[0], case .dimension(let d) = rec.kind,
              case .linear(let e1, let e2, let angle) = d.kind else {
            return nil
        }
        return (e1, e2, angle, d.definitionPoint)
    }

    /// Builds a `ToolContext` whose `nearbyEntities` returns the given entities
    /// (the chained tools pick a base dim from this hook).
    private func ctx(_ entities: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: [],
            entity: { id in entities.first { $0.id == id } },
            gridSpacing: nil,
            nearbyEntities: { _, _ in entities }
        )
    }

    /// A horizontal base linear dim: origins on y=0, dim line at y=-3.
    private func baseDimEntity() -> EntityRecord {
        EntityRecord(
            id: EntityID(1),
            kind: .dimension(DimData(
                kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
                definitionPoint: Vector(5, -3)
            ))
        )
    }

    // MARK: - Seed-from-points: 3 points → first dim, then chain

    @Test("Baseline of 3 feature points → 2 chained dims sharing origin1 with increasing offset")
    func seedThenTwoChained() {
        var tool = BaselineDimTool(baselineSpacing: 4)
        // SEED the first dim from points: origin1, origin2, dim-line location.
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)
        let first = tool.handle(.click(Vector(5, -3)), context: .empty)
        guard let f = committedLinear(first) else {
            Issue.record("expected first dim commit"); return
        }
        #expect(f.e1.distance(to: Vector(0, 0)) < 1e-9)
        #expect(f.e2.distance(to: Vector(10, 0)) < 1e-9)
        #expect(abs(f.def.y - (-3)) < 1e-9)

        // CHAIN: feature point #1 → first chained dim. Shares origin1=(0,0),
        // angle 0; dim line one step further out (y = -3 - 4 = -7).
        let c1 = tool.handle(.click(Vector(18, 0)), context: .empty)
        guard let d1 = committedLinear(c1) else {
            Issue.record("expected chained dim #1"); return
        }
        #expect(d1.e1.distance(to: Vector(0, 0)) < 1e-9)   // shared baseline origin
        #expect(d1.e2.distance(to: Vector(18, 0)) < 1e-9)  // new feature
        #expect(abs(d1.angle) < 1e-9)
        #expect(abs(d1.def.y - (-7)) < 1e-9)               // base(-3) − 1·4

        // CHAIN: feature point #2 → second chained dim. Same origin1, dim line two
        // steps out (y = -3 - 8 = -11) — a GROWING offset.
        let c2 = tool.handle(.click(Vector(26, 0)), context: .empty)
        guard let d2 = committedLinear(c2) else {
            Issue.record("expected chained dim #2"); return
        }
        #expect(d2.e1.distance(to: Vector(0, 0)) < 1e-9)   // SAME shared origin1
        #expect(d2.e2.distance(to: Vector(26, 0)) < 1e-9)
        #expect(abs(d2.def.y - (-11)) < 1e-9)              // base(-3) − 2·4

        // The two chained dims share origin1 and offset grows monotonically.
        #expect(d1.e1.distance(to: d2.e1) < 1e-9)
        #expect(abs(d2.def.y) > abs(d1.def.y))             // further out
    }

    // MARK: - Pick an existing base dim, then chain

    @Test("Picking an existing linear dim adopts its origin1 + angle as the baseline")
    func pickBaseThenChain() {
        var tool = BaselineDimTool(baselineSpacing: 4)
        let context = ctx([baseDimEntity()])
        // First click picks the base dim (no commit).
        #expect(tool.handle(.click(Vector(5, -3)), context: context) == .none)
        // Next click is a feature point → first chained dim off the picked baseline.
        let c1 = tool.handle(.click(Vector(20, 0)), context: context)
        guard let d1 = committedLinear(c1) else {
            Issue.record("expected chained dim after base pick"); return
        }
        #expect(d1.e1.distance(to: Vector(0, 0)) < 1e-9)   // adopted base origin1
        #expect(d1.e2.distance(to: Vector(20, 0)) < 1e-9)
        #expect(abs(d1.angle) < 1e-9)                       // adopted base angle
        #expect(abs(d1.def.y - (-7)) < 1e-9)               // base offset(-3) − 1·4
    }

    // MARK: - Typed coordinates, degenerate picks, cancel

    @Test("Typed coordinates (.value) seed and chain like clicks")
    func typedValues() {
        var tool = BaselineDimTool(baselineSpacing: 5)
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(10, 0)), context: .empty)
        #expect(committedLinear(tool.handle(.value(Vector(5, -2)), context: .empty)) != nil)
        #expect(committedLinear(tool.handle(.value(Vector(15, 0)), context: .empty)) != nil)
    }

    @Test("A coincident second seed origin is ignored (no zero-length dim)")
    func coincidentSeedIgnored() {
        var tool = BaselineDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // Same point as origin1 → still awaiting a distinct second origin (no commit).
        let out = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(out == .none)
    }

    @Test("A feature coincident with the baseline origin is ignored while chaining")
    func coincidentFeatureIgnored() {
        var tool = BaselineDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)   // first dim
        // Feature exactly on origin1 → zero-length, no commit.
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
    }

    @Test("Cancel finishes the run without committing")
    func cancelFinishes() {
        var tool = BaselineDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }

    @Test("Commit (Return) ends the run without an extra dim")
    func commitFinishes() {
        var tool = BaselineDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)
        #expect(tool.handle(.commit, context: .empty) == .finished)
    }

    // MARK: - Preview + status

    @Test("Preview is non-empty while chaining once the baseline is set")
    func previewWhileChaining() {
        var tool = BaselineDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)
        #expect(tool.handle(.move(Vector(20, 0)), context: .empty) == .preview)
        #expect(!tool.preview.isEmpty)
    }

    @Test("Title + status reflect the baseline tool state")
    func titleAndStatus() {
        var tool = BaselineDimTool()
        #expect(tool.title == "Baseline Dimension")
        #expect(tool.status.contains("base dimension"))
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, -3)), context: .empty)
        #expect(tool.status.contains("baseline"))
    }

    @Test("baselineSpacing is clamped to a positive value")
    func spacingClamped() {
        let tool = BaselineDimTool(baselineSpacing: -10)
        #expect(tool.baselineSpacing > 0)
    }
}
