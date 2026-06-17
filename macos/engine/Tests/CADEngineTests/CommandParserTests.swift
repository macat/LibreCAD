//
//  CommandParserTests.swift
//  CADEngineTests
//
//  Drives the pure `CommandParser` (no GUI) — the command/coordinate input line's
//  parser (UX-plan U1, decision D7). Covers each grammar form: absolute `x,y`,
//  relative `@dx,dy`, polar `dist<angle`, a bare distance along the bearing, plus
//  the error cases (bad input, relative/polar/distance with no reference). Also
//  proves the integration seam: feeding the resolved point to `LineTool` as
//  `.value(p)` places the point at the EXACT typed coordinate (no snap drift).
//
//  Domain-prefixed suite names (CONVENTIONS.md) so parallel fan-out builders adding
//  files to the same target don't collide.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CommandParser coordinate grammar")
struct CommandParserGrammarTests {

    // MARK: - Helpers

    /// Unwraps a `.point` result (fails if it was an error).
    private func point(_ result: CommandParser.Result) -> Vector? {
        guard case .point(let p) = result else { return nil }
        return p
    }

    /// Whether two scalars are within a tight numeric tolerance.
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    // MARK: - Absolute (x,y)

    @Test("absolute x,y resolves to the exact coordinate (no reference needed)")
    func absolute() {
        let r = CommandParser.parse("100,50", reference: nil)
        guard let p = point(r) else { Issue.record("expected a point"); return }
        #expect(close(p.x, 100))
        #expect(close(p.y, 50))
        #expect(p.valid)
    }

    @Test("absolute accepts signs, decimals, and surrounding whitespace")
    func absoluteFormats() {
        guard let p = point(CommandParser.parse("  -3.5 , .25 ", reference: Vector(9, 9))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(p.x, -3.5))
        #expect(close(p.y, 0.25))
    }

    // MARK: - Relative (@dx,dy)

    @Test("@dx,dy is relative to the reference (relative-zero)")
    func relative() {
        let r = CommandParser.parse("@10,0", reference: Vector(5, 5))
        guard let p = point(r) else { Issue.record("expected a point"); return }
        #expect(close(p.x, 15))
        #expect(close(p.y, 5))
    }

    @Test("@dx,dy with a negative component steps backward from the reference")
    func relativeNegative() {
        guard let p = point(CommandParser.parse("@-4,-6", reference: Vector(10, 10))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(p.x, 6))
        #expect(close(p.y, 4))
    }

    @Test("@dx,dy with NO reference is an error")
    func relativeNoReference() {
        guard case .error = CommandParser.parse("@10,0", reference: nil) else {
            Issue.record("expected an error"); return
        }
    }

    // MARK: - Polar (dist<angle)

    @Test("dist<angle is polar from the reference, angle in degrees (5<90 → +Y)")
    func polar() {
        let r = CommandParser.parse("5<90", reference: Vector(0, 0))
        guard let p = point(r) else { Issue.record("expected a point"); return }
        #expect(close(p.x, 0))
        #expect(close(p.y, 5))
    }

    @Test("dist<0 points along +X; dist<180 along -X")
    func polarAxes() {
        guard let east = point(CommandParser.parse("10<0", reference: Vector(2, 3))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(east.x, 12))
        #expect(close(east.y, 3))

        guard let west = point(CommandParser.parse("10<180", reference: Vector(2, 3))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(west.x, -8))
        #expect(close(west.y, 3))
    }

    @Test("@dist<angle is accepted as the same relative-polar form")
    func polarWithAtSign() {
        guard let p = point(CommandParser.parse("@5<90", reference: Vector(1, 1))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(p.x, 1))
        #expect(close(p.y, 6))
    }

    @Test("polar with NO reference is an error")
    func polarNoReference() {
        guard case .error = CommandParser.parse("5<90", reference: nil) else {
            Issue.record("expected an error"); return
        }
    }

    @Test("polar in radians when angleInDegrees is false")
    func polarRadians() {
        guard let p = point(CommandParser.parse("5<\(Double.pi / 2)",
                                                reference: Vector(0, 0),
                                                angleInDegrees: false)) else {
            Issue.record("expected a point"); return
        }
        #expect(close(p.x, 0))
        #expect(close(p.y, 5))
    }

    // MARK: - Bare distance (along the bearing)

    @Test("a bare distance is along the reference→cursor bearing")
    func bareDistance() {
        // Reference (0,0), cursor due east → distance 10 lands at (10,0).
        let r = CommandParser.parse("10", reference: Vector(0, 0), cursor: Vector(3, 0))
        guard let p = point(r) else { Issue.record("expected a point"); return }
        #expect(close(p.x, 10))
        #expect(close(p.y, 0))
    }

    @Test("a bare distance honors a diagonal bearing (45° → equal x/y)")
    func bareDistanceDiagonal() {
        guard let p = point(CommandParser.parse("\(2.0.squareRoot())",
                                                reference: Vector(0, 0),
                                                cursor: Vector(1, 1))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(p.x, 1))
        #expect(close(p.y, 1))
    }

    @Test("a negative bare distance steps backward along the bearing")
    func bareDistanceNegative() {
        guard let p = point(CommandParser.parse("-5", reference: Vector(0, 0), cursor: Vector(1, 0))) else {
            Issue.record("expected a point"); return
        }
        #expect(close(p.x, -5))
        #expect(close(p.y, 0))
    }

    @Test("a bare distance with no reference is an error")
    func bareDistanceNoReference() {
        guard case .error = CommandParser.parse("10", reference: nil, cursor: Vector(1, 0)) else {
            Issue.record("expected an error"); return
        }
    }

    @Test("a bare distance with no cursor (no bearing) is an error")
    func bareDistanceNoCursor() {
        guard case .error = CommandParser.parse("10", reference: Vector(0, 0), cursor: nil) else {
            Issue.record("expected an error"); return
        }
    }

    @Test("a bare distance with a coincident cursor (no direction) is an error")
    func bareDistanceCoincident() {
        guard case .error = CommandParser.parse("10", reference: Vector(2, 2), cursor: Vector(2, 2)) else {
            Issue.record("expected an error"); return
        }
    }

    // MARK: - Errors

    @Test("empty / whitespace-only input is an error")
    func empty() {
        guard case .error = CommandParser.parse("   ", reference: Vector(0, 0)) else {
            Issue.record("expected an error"); return
        }
    }

    @Test("a malformed pair (too many commas) is an error")
    func malformedPair() {
        guard case .error = CommandParser.parse("1,2,3", reference: nil) else {
            Issue.record("expected an error"); return
        }
    }

    @Test("a non-numeric token is an error")
    func nonNumeric() {
        guard case .error = CommandParser.parse("foo", reference: Vector(0, 0), cursor: Vector(1, 0)) else {
            Issue.record("expected an error"); return
        }
        guard case .error = CommandParser.parse("x,y", reference: nil) else {
            Issue.record("expected an error"); return
        }
    }
}

@Suite("ToolInput.value places points exactly")
struct ToolValueInputTests {

    /// Pulls the single LineData out of a `.commit` outcome.
    private func committedLine(_ outcome: ToolOutcome) -> LineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .line(let d) = record.kind else { return nil }
        return d
    }

    @Test("feeding LineTool .value(p) fixes the first point at the exact coordinate")
    func valueFixesFirstPoint() {
        var tool = LineTool()
        // A typed first point behaves like a first click (status advances; no commit).
        let outcome = tool.handle(.value(Vector(0, 0)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify next point")
    }

    @Test("two typed values commit a line with the EXACT typed endpoints (no drift)")
    func twoValuesCommitExactLine() {
        var tool = LineTool()
        let start = Vector(0, 0)
        let end = Vector(10, 0)
        _ = tool.handle(.value(start), context: .empty)
        let line = committedLine(tool.handle(.value(end), context: .empty))
        guard let line else { Issue.record("expected a committed line"); return }
        #expect(line.start == start)
        #expect(line.end == end)
    }

    @Test("a typed value and a click interoperate (value start, click end)")
    func valueAndClickMix() {
        var tool = LineTool()
        _ = tool.handle(.value(Vector(2, 2)), context: .empty)
        let line = committedLine(tool.handle(.click(Vector(2, 9)), context: .empty))
        guard let line else { Issue.record("expected a committed line"); return }
        #expect(line.start == Vector(2, 2))
        #expect(line.end == Vector(2, 9))
    }

    @Test("the full U1 flow: parse 0,0 then @10,0 → an exact 10-unit horizontal line")
    func endToEndParseThenPlace() {
        var tool = LineTool()
        // Step 1: type "0,0" — absolute, no reference needed.
        guard case .point(let p0) = CommandParser.parse("0,0", reference: nil) else {
            Issue.record("parse 0,0 failed"); return
        }
        _ = tool.handle(.value(p0), context: .empty)
        // Step 2: type "@10,0" — relative to the just-placed (0,0).
        guard case .point(let p1) = CommandParser.parse("@10,0", reference: p0) else {
            Issue.record("parse @10,0 failed"); return
        }
        let line = committedLine(tool.handle(.value(p1), context: .empty))
        guard let line else { Issue.record("expected a committed line"); return }
        #expect(line.start == Vector(0, 0))
        #expect(line.end == Vector(10, 0))
        // Exactly horizontal, length 10.
        #expect(abs((line.end - line.start).magnitude - 10) < 1e-9)
        #expect(abs(line.end.y - line.start.y) < 1e-9)
    }

    @Test("a MODIFY tool (MoveTool) treats .value like .click: it picks the base point")
    func modifyToolValueIsAPick() {
        // With an EMPTY selection there is nothing to move, so a typed .value is a
        // no-op (the same guard the first .click hits) — it does NOT advance.
        var empty = MoveTool()
        #expect(empty.handle(.value(Vector(5, 5)), context: .empty) == .none)
        #expect(empty.status == "Select objects to move first")

        // With a selection, a typed .value lands at the EXACT coordinate and behaves
        // exactly like a first .click: it fixes the base point (status advances).
        let line = EntityRecord(id: EntityID(1),
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(selected: [line], entity: { _ in line }, gridSpacing: nil)
        var tool = MoveTool()
        #expect(tool.handle(.value(Vector(2, 2)), context: ctx) == .none)
        #expect(tool.status == "Specify destination")
    }
}
