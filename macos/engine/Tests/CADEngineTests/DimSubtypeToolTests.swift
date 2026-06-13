//
//  DimSubtypeToolTests.swift
//  CADEngineTests
//
//  Tests for the three dim-subtype creation tools (w2-dimsub, UNWIRED until a
//  later wire-wave): OrdinateDimTool, ArcLengthDimTool, Angular3pDimTool. Drives
//  each tool's `.click`/`.move`/`.commit` state machine with NO GUI, asserting it
//  authors the correct `.dimension(DimData)` on completion (the same Tool-contract
//  exercise the other dimension tools use).
//
//  Suite/type names are domain-namespaced (`DimSubtypeTool*`) per CONVENTIONS.md.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Dim-subtype creation tools")
struct DimSubtypeToolTests {

    /// Extracts the single committed `.dimension` record from an outcome, or fails.
    private func committedDim(_ outcome: ToolOutcome) -> DimData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let rec) = edits[0], case .dimension(let d) = rec.kind else {
            return nil
        }
        return d
    }

    // MARK: - OrdinateDimTool

    @Test("OrdinateDimTool: origin → feature → vertical leader commits an X-datum ordinate")
    func ordinateXTool() {
        var tool = OrdinateDimTool()
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)   // origin
        #expect(tool.handle(.click(Vector(12, 7)), context: .empty) == .none)  // feature
        // Vertical leader (drag up) → auto-selects X-datum.
        let out = tool.handle(.click(Vector(12, 22)), context: .empty)
        guard let d = committedDim(out), case let .ordinate(o, f, l, mx) = d.kind else {
            Issue.record("expected ordinate commit"); return
        }
        #expect(o.distance(to: Vector(0, 0)) < 1e-9)
        #expect(f.distance(to: Vector(12, 7)) < 1e-9)
        #expect(l.distance(to: Vector(12, 22)) < 1e-9)
        #expect(mx == true)
        #expect(d.definitionPoint.distance(to: Vector(0, 0)) < 1e-9)
    }

    @Test("OrdinateDimTool: horizontal leader auto-selects a Y-datum ordinate")
    func ordinateYTool() {
        var tool = OrdinateDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 8)), context: .empty)
        let out = tool.handle(.click(Vector(30, 8)), context: .empty)   // horizontal leader
        guard let d = committedDim(out), case let .ordinate(_, _, _, mx) = d.kind else {
            Issue.record("expected ordinate commit"); return
        }
        #expect(mx == false)
    }

    @Test("OrdinateDimTool: axis lock .y forces a Y-datum even with a vertical leader")
    func ordinateAxisLock() {
        var tool = OrdinateDimTool(axis: .y)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 8)), context: .empty)
        let out = tool.handle(.click(Vector(5, 40)), context: .empty)   // vertical leader
        guard let d = committedDim(out), case let .ordinate(_, _, _, mx) = d.kind else {
            Issue.record("expected ordinate commit"); return
        }
        #expect(mx == false)   // forced Y despite the vertical drag
    }

    @Test("OrdinateDimTool: a typed coordinate (.value) places points like a click")
    func ordinateTypedValue() {
        var tool = OrdinateDimTool(axis: .x)
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(10, 5)), context: .empty)
        let out = tool.handle(.value(Vector(10, 30)), context: .empty)
        #expect(committedDim(out) != nil)
    }

    @Test("OrdinateDimTool: cancel finishes without committing")
    func ordinateCancel() {
        var tool = OrdinateDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.handle(.cancel, context: .empty) == .finished)
    }

    // MARK: - ArcLengthDimTool

    /// A context exposing a single arc as a pickable nearby entity.
    private func arcContext(_ arc: ArcData, id: EntityID = EntityID(1)) -> ToolContext {
        let rec = EntityRecord(id: id, kind: .arc(arc))
        return ToolContext(
            selected: [],
            entity: { $0 == id ? rec : nil },
            gridSpacing: 1.0,
            nearbyEntities: { _, _ in [rec] })
    }

    @Test("ArcLengthDimTool: pick an arc → leader commits an arc-length dim")
    func arcLengthTool() {
        let arc = ArcData(center: Vector(0, 0), radius: 10,
                          startAngle: 0, endAngle: Double.pi / 2)
        var tool = ArcLengthDimTool()
        let ctx = arcContext(arc)
        // First click picks the arc (near a point on it).
        #expect(tool.handle(.click(Vector(10, 0)), context: ctx) == .none)
        // Second click sets the dimension-arc location.
        let out = tool.handle(.click(Vector(15, 0)), context: ctx)
        guard let d = committedDim(out),
              case let .arcLength(c, r, s, e, rev) = d.kind else {
            Issue.record("expected arcLength commit"); return
        }
        #expect(c.distance(to: Vector(0, 0)) < 1e-9)
        #expect(abs(r - 10) < 1e-9)
        #expect(abs(s - 0) < 1e-9)
        #expect(abs(e - Double.pi / 2) < 1e-9)
        #expect(rev == false)
        #expect(d.definitionPoint.distance(to: Vector(15, 0)) < 1e-9)
    }

    @Test("ArcLengthDimTool: a click that hits no arc does not advance")
    func arcLengthNoHit() {
        var tool = ArcLengthDimTool()
        // Empty context → nearbyEntities returns [] → no arc to pick.
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)
        // Still waiting on the entity pick (a subsequent click also no-ops).
        #expect(tool.handle(.click(Vector(15, 0)), context: .empty) == .none)
    }

    @Test("ArcLengthDimTool: a full circle is not pickable (only arcs)")
    func arcLengthIgnoresCircle() {
        let circ = EntityRecord(id: EntityID(2), kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let ctx = ToolContext(selected: [], entity: { _ in circ }, gridSpacing: 1.0,
                              nearbyEntities: { _, _ in [circ] })
        var tool = ArcLengthDimTool()
        #expect(tool.handle(.click(Vector(5, 0)), context: ctx) == .none)
    }

    // MARK: - Angular3pDimTool

    @Test("Angular3pDimTool: vertex → p1 → p2 → arc commits an angular3p dim")
    func angular3pTool() {
        var tool = Angular3pDimTool()
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)    // vertex
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)   // p1
        #expect(tool.handle(.click(Vector(0, 10)), context: .empty) == .none)   // p2
        let out = tool.handle(.click(Vector(7, 7)), context: .empty)            // arc location
        guard let d = committedDim(out),
              case let .angular3p(v, p1, p2) = d.kind else {
            Issue.record("expected angular3p commit"); return
        }
        #expect(v.distance(to: Vector(0, 0)) < 1e-9)
        #expect(p1.distance(to: Vector(10, 0)) < 1e-9)
        #expect(p2.distance(to: Vector(0, 10)) < 1e-9)
        #expect(d.definitionPoint.distance(to: Vector(7, 7)) < 1e-9)
    }

    @Test("Angular3pDimTool: a ray point coincident with the vertex is ignored")
    func angular3pRejectsCoincident() {
        var tool = Angular3pDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // p1 == vertex → no ray direction → ignored (state stays at settingPoint1).
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        // A real p1 now advances.
        #expect(tool.handle(.click(Vector(10, 0)), context: .empty) == .none)
    }

    @Test("Angular3pDimTool: backspace steps the state back one pick")
    func angular3pBackspace() {
        var tool = Angular3pDimTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)   // vertex
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)  // p1
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)  // p2 → settingArc
        // Backspace steps back to settingPoint2; the next click sets p2 again.
        #expect(tool.handle(.backspace, context: .empty) == .preview)
        let out = tool.handle(.click(Vector(0, 5)), context: .empty)  // → settingArc
        // We're now at settingArc, so an arc-location click commits.
        let commit = tool.handle(.click(Vector(3, 3)), context: .empty)
        #expect(out == .none)
        #expect(committedDim(commit) != nil)
    }

    @Test("Angular3pDimTool: a typed coordinate (.value) places points like a click")
    func angular3pTypedValue() {
        var tool = Angular3pDimTool()
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        _ = tool.handle(.value(Vector(10, 0)), context: .empty)
        _ = tool.handle(.value(Vector(0, 10)), context: .empty)
        let out = tool.handle(.value(Vector(7, 7)), context: .empty)
        #expect(committedDim(out) != nil)
    }
}
