//
//  StretchToolTests.swift
//  CADEngineTests
//
//  Drives the interactive Stretch tool PURELY (no GUI): feeds the crossing-window
//  corners + reference / destination picks (and a typed displacement) against a
//  hand-built `ToolContext.selected`, and asserts that ONLY the endpoints /
//  vertices inside the window translate while the rest stay fixed (the LibreCAD
//  stretch contract), plus the commit shape (one `.replace` per affected entity)
//  and the no-op paths.
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

@Suite("StretchTool modify (crossing-window vertex stretch)")
struct StretchToolModifyTests {

    // MARK: - Fixtures

    /// A `ToolContext` whose `selected` is `records` (the modify tools read the
    /// selection). The boundary hooks are unused by Stretch.
    private static func context(selected records: [EntityRecord]) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(
            selected: records,
            entity: { byID[$0] },
            gridSpacing: nil
        )
    }

    private static let lineID = EntityID(1)

    /// A horizontal line (0,0)-(10,0).
    private static func line() -> EntityRecord {
        EntityRecord(id: lineID, kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    }

    /// Pulls the single `.replace`d kind from a one-edit `.commit`, or `nil`.
    private func replaced(_ outcome: ToolOutcome) -> (EntityID, EntityKind)? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .replace(let id, let kind) = edits[0] else { return nil }
        return (id, kind)
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.distance(to: b) < tol
    }

    // MARK: - Metadata

    @Test("title is Stretch")
    func title() { #expect(StretchTool().title == "Stretch") }

    // MARK: - One endpoint inside the window translates; the other is fixed

    @Test("a line with ONLY its right endpoint inside the window stretches that endpoint")
    func oneEndpointInsideTranslates() {
        var tool = StretchTool()
        let ctx = Self.context(selected: [Self.line()])

        // Crossing window around the RIGHT end only: x in [8,12], y in [-1,1] — it
        // contains (10,0) but not (0,0).
        #expect(tool.handle(.click(Vector(8, -1)), context: ctx) == .none)   // corner 1
        #expect(tool.handle(.click(Vector(12, 1)), context: ctx) == .none)   // corner 2
        #expect(tool.handle(.click(Vector(0, 0)), context: ctx) == .none)    // reference base
        // Destination: +3 in x, +2 in y → delta (3,2).
        let outcome = tool.handle(.click(Vector(3, 2)), context: ctx)

        guard let (id, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a single line .replace"); return
        }
        #expect(id == Self.lineID)
        #expect(approx(d.start, Vector(0, 0)))         // left endpoint OUTSIDE → fixed
        #expect(approx(d.end, Vector(13, 2)))          // right endpoint INSIDE → translated by (3,2)
    }

    // MARK: - Both endpoints inside → whole line translates

    @Test("a line with BOTH endpoints inside the window translates entirely")
    func bothEndpointsInsideTranslate() {
        var tool = StretchTool()
        let ctx = Self.context(selected: [Self.line()])

        // A window covering the whole line.
        _ = tool.handle(.click(Vector(-1, -1)), context: ctx)
        _ = tool.handle(.click(Vector(11, 1)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)   // reference
        let outcome = tool.handle(.click(Vector(5, 0)), context: ctx)  // delta (5,0)

        guard let (_, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace"); return
        }
        #expect(approx(d.start, Vector(5, 0)))   // both endpoints translated
        #expect(approx(d.end, Vector(15, 0)))
    }

    // MARK: - No endpoint inside → no edit

    @Test("a line with NO endpoint inside the window is unchanged (no commit)")
    func noEndpointInsideNoCommit() {
        var tool = StretchTool()
        let ctx = Self.context(selected: [Self.line()])

        // A window over the MIDDLE only (x in [4,6]) contains neither endpoint.
        _ = tool.handle(.click(Vector(4, -1)), context: ctx)
        _ = tool.handle(.click(Vector(6, 1)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)   // reference
        let outcome = tool.handle(.click(Vector(5, 5)), context: ctx)  // delta (5,5)
        #expect(outcome == .none)
    }

    // MARK: - Typed displacement (.value) short-circuits to a stretch

    @Test("a typed displacement after the window stretches the in-window endpoint")
    func typedDisplacementStretches() {
        var tool = StretchTool()
        let ctx = Self.context(selected: [Self.line()])

        // Window around the right end only.
        _ = tool.handle(.click(Vector(8, -1)), context: ctx)
        _ = tool.handle(.click(Vector(12, 1)), context: ctx)
        // Type a displacement (4, 0) — commits immediately, no reference pick.
        let outcome = tool.handle(.value(Vector(4, 0)), context: ctx)

        guard let (_, kind) = replaced(outcome), case .line(let d) = kind else {
            Issue.record("expected a line .replace from typed value"); return
        }
        #expect(approx(d.start, Vector(0, 0)))    // outside → fixed
        #expect(approx(d.end, Vector(14, 0)))     // inside → +4 in x
    }

    @Test("a typed displacement before the window is set is ignored")
    func typedBeforeWindowIgnored() {
        var tool = StretchTool()
        let ctx = Self.context(selected: [Self.line()])
        _ = tool.handle(.click(Vector(8, -1)), context: ctx)   // only first corner
        #expect(tool.handle(.value(Vector(4, 0)), context: ctx) == .none)
    }

    // MARK: - Polyline: only the in-window vertex moves

    @Test("a polyline stretches only the vertices inside the window")
    func polylineInWindowVertexMoves() {
        var tool = StretchTool()
        let pl = EntityRecord(id: EntityID(2), kind: .polyline(PolylineData(vertices: [
            PolylineVertex(point: Vector(0, 0)),
            PolylineVertex(point: Vector(5, 0)),
            PolylineVertex(point: Vector(10, 0)),
        ])))
        let ctx = Self.context(selected: [pl])

        // Window around the MIDDLE vertex (5,0) only.
        _ = tool.handle(.click(Vector(4, -1)), context: ctx)
        _ = tool.handle(.click(Vector(6, 1)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)   // reference
        let outcome = tool.handle(.click(Vector(0, 3)), context: ctx)  // delta (0,3)

        guard let (_, kind) = replaced(outcome), case .polyline(let d) = kind else {
            Issue.record("expected a polyline .replace"); return
        }
        #expect(approx(d.vertices[0].point, Vector(0, 0)))    // fixed
        #expect(approx(d.vertices[1].point, Vector(5, 3)))    // moved by (0,3)
        #expect(approx(d.vertices[2].point, Vector(10, 0)))   // fixed
    }

    // MARK: - Multiple selected entities → one .replace each affected

    @Test("two selected lines: only the affected ones get a .replace")
    func multipleEntitiesOnlyAffectedReplaced() {
        var tool = StretchTool()
        let l1 = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let l2 = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(0, 50), end: Vector(10, 50))))
        let ctx = Self.context(selected: [l1, l2])

        // Window around l1's right end only (y near 0); l2 (at y=50) is untouched.
        _ = tool.handle(.click(Vector(8, -1)), context: ctx)
        _ = tool.handle(.click(Vector(12, 1)), context: ctx)
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)
        let outcome = tool.handle(.click(Vector(2, 0)), context: ctx)  // delta (2,0)

        guard case .commit(let edits) = outcome else {
            Issue.record("expected a commit"); return
        }
        #expect(edits.count == 1)   // only l1 changed
        guard case .replace(let id, _) = edits[0] else { Issue.record("expected replace"); return }
        #expect(id == EntityID(1))
    }

    // MARK: - Lifecycle / guards

    @Test("with no selection every input is a no-op and status nudges to select")
    func emptySelectionNoOp() {
        var tool = StretchTool()
        let ctx = ToolContext.empty
        #expect(tool.handle(.click(Vector(0, 0)), context: ctx) == .none)
        #expect(tool.status == "Select objects to stretch first")
    }

    @Test("a zero displacement commits nothing")
    func zeroDisplacementNoCommit() {
        var tool = StretchTool()
        let ctx = Self.context(selected: [Self.line()])
        _ = tool.handle(.click(Vector(-1, -1)), context: ctx)
        _ = tool.handle(.click(Vector(11, 1)), context: ctx)
        _ = tool.handle(.click(Vector(5, 0)), context: ctx)        // reference
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)  // destination == base
    }

    @Test("cancel finishes the run")
    func cancelFinishes() {
        var tool = StretchTool()
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }
}
