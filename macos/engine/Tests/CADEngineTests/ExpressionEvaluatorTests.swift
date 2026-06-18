//
//  ExpressionEvaluatorTests.swift
//  CADEngineTests
//
//  Tests for the pure expression evaluator (Lane L0): single-expression
//  evaluation, the value+unit-token boundary (NO conversion), name references,
//  operator precedence / parens / unary minus, error cases (divide-by-zero,
//  unknown name, syntax), the whole-table topological evaluator (transitive
//  freshness + cycle detection with no hang), `parseAssignment` accept/reject,
//  and the `unitToken → DrawingUnit` inverse helper.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
@testable import CADEngine

@Suite("ExpressionEvaluator")
struct ExpressionEvaluatorTests {

    // Floating-point comparison helper.
    private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool {
        abs(a - b) <= eps * max(1, abs(a), abs(b))
    }

    // MARK: - Numeric literals

    @Test("Plain numeric literals")
    func numericLiterals() throws {
        #expect(near(try ExpressionEvaluator.evaluate("22"), 22))
        #expect(near(try ExpressionEvaluator.evaluate("3.5"), 3.5))
        #expect(near(try ExpressionEvaluator.evaluate("  .25 "), 0.25))
        #expect(near(try ExpressionEvaluator.evaluate("1e3"), 1000))
        #expect(near(try ExpressionEvaluator.evaluate("2.5E-4"), 0.00025))
    }

    // MARK: - Unit token is PARSED + RETURNED, but NOT converted

    @Test("Unit literal returns magnitude unchanged + the token")
    func unitTokenReturnedNotConverted() throws {
        let (v, token) = try ExpressionEvaluator.evaluateLiteralUnit("22mm")
        #expect(near(v, 22))            // magnitude unchanged — NOT 22 (already mm) nor converted
        #expect(token == "mm")

        let (v2, t2) = try ExpressionEvaluator.evaluateLiteralUnit("3.5cm")
        #expect(near(v2, 3.5))          // NOT 35 — no conversion happened
        #expect(t2 == "cm")

        let (v3, t3) = try ExpressionEvaluator.evaluateLiteralUnit("-10in")
        #expect(near(v3, -10))
        #expect(t3 == "in")
    }

    @Test("Bare number has no unit token; arithmetic also has none")
    func noUnitTokenForBareOrCompound() throws {
        let (v, token) = try ExpressionEvaluator.evaluateLiteralUnit("22")
        #expect(near(v, 22))
        #expect(token == nil)

        let (v2, t2) = try ExpressionEvaluator.evaluateLiteralUnit("a*2", symbols: ["a": 5])
        #expect(near(v2, 10))
        #expect(t2 == nil)              // compound expression → no top-level unit
    }

    @Test("A unit suffix inside arithmetic keeps magnitude, no token")
    func unitSuffixInArithmetic() throws {
        // The suffix is consumed but does not change magnitude; no top-level token.
        let (v, token) = try ExpressionEvaluator.evaluateLiteralUnit("22mm*2")
        #expect(near(v, 44))
        #expect(token == nil)
    }

    // MARK: - Name references

    @Test("b = a*2 with a supplied")
    func nameRefTimesTwo() throws {
        let value = try ExpressionEvaluator.evaluate("a*2", symbols: ["a": 11])
        #expect(near(value, 22))
    }

    @Test("Multiple names combine")
    func multipleNames() throws {
        let value = try ExpressionEvaluator.evaluate("a + b*c", symbols: ["a": 2, "b": 3, "c": 4])
        #expect(near(value, 14))       // 2 + 12
    }

    // MARK: - Precedence, parentheses, unary minus

    @Test("Operator precedence")
    func precedence() throws {
        #expect(near(try ExpressionEvaluator.evaluate("2 + 3 * 4"), 14))
        #expect(near(try ExpressionEvaluator.evaluate("2 * 3 + 4"), 10))
        #expect(near(try ExpressionEvaluator.evaluate("10 - 2 - 3"), 5))   // left-assoc
        #expect(near(try ExpressionEvaluator.evaluate("100 / 5 / 2"), 10)) // left-assoc
    }

    @Test("Parentheses override precedence")
    func parentheses() throws {
        #expect(near(try ExpressionEvaluator.evaluate("(2 + 3) * 4"), 20))
        #expect(near(try ExpressionEvaluator.evaluate("((1+2)*(3+4))"), 21))
    }

    @Test("Unary minus")
    func unaryMinus() throws {
        #expect(near(try ExpressionEvaluator.evaluate("-5"), -5))
        #expect(near(try ExpressionEvaluator.evaluate("-(2+3)"), -5))
        #expect(near(try ExpressionEvaluator.evaluate("3 * -2"), -6))
        #expect(near(try ExpressionEvaluator.evaluate("--4"), 4))
        #expect(near(try ExpressionEvaluator.evaluate("-a", symbols: ["a": 7]), -7))
        #expect(near(try ExpressionEvaluator.evaluate("+5"), 5))   // tolerate unary plus
    }

    // MARK: - Error cases

    @Test("Divide by zero throws .divideByZero")
    func divideByZero() {
        #expect(ExpressionEvaluator.evaluateResult("1/0") == .failure(.divideByZero))
        #expect(ExpressionEvaluator.evaluateResult("5 / (3 - 3)") == .failure(.divideByZero))
    }

    @Test("Unknown name throws .unknownName")
    func unknownName() {
        let r = ExpressionEvaluator.evaluateResult("a + b", symbols: ["a": 1])
        #expect(r == .failure(.unknownName("b")))
    }

    @Test("Syntax errors")
    func syntaxErrors() {
        #expect(ExpressionEvaluator.evaluateResult("") == .failure(.syntax))
        #expect(ExpressionEvaluator.evaluateResult("(1 + 2") == .failure(.syntax))   // unbalanced
        #expect(ExpressionEvaluator.evaluateResult("1 +") == .failure(.syntax))       // dangling op
        #expect(ExpressionEvaluator.evaluateResult("1 2") == .failure(.syntax))       // two literals
        #expect(ExpressionEvaluator.evaluateResult("* 3") == .failure(.syntax))       // leading binop
        #expect(ExpressionEvaluator.evaluateResult("1 , 2") == .failure(.syntax))     // stray comma
        #expect(ExpressionEvaluator.evaluateResult("3..5") == .failure(.syntax))      // bad number
    }

    // MARK: - Whole-table topological evaluation

    @Test("Topological table evaluation gives fresh transitive values")
    func topoTable() throws {
        let table = [
            "a": "22",
            "b": "a*2",       // depends on a
            "c": "b + a",     // depends on b, a
            "d": "c / 2",     // depends on c
        ]
        let out = try ExpressionEvaluator.evaluateTable(table)
        #expect(near(out["a"]!, 22))
        #expect(near(out["b"]!, 44))
        #expect(near(out["c"]!, 66))
        #expect(near(out["d"]!, 33))
    }

    @Test("Table evaluation order independent of dictionary iteration")
    func topoTableReverseDeclared() throws {
        // Declared with dependents before dependencies — topo sort must still work.
        let table = [
            "z": "y + 1",
            "y": "x * 3",
            "x": "5",
        ]
        let out = try ExpressionEvaluator.evaluateTable(table)
        #expect(near(out["x"]!, 5))
        #expect(near(out["y"]!, 15))
        #expect(near(out["z"]!, 16))
    }

    @Test("Table resolves external constants")
    func topoExternal() throws {
        let table = ["r": "pi * 2"]
        let out = try ExpressionEvaluator.evaluateTable(table, external: ["pi": 3.14])
        #expect(near(out["r"]!, 6.28))
        #expect(out["pi"] == nil)   // external is not echoed in the result
    }

    @Test("Self-cycle (a=b, b=a) → .cycle, no hang")
    func cycleTwoNodes() {
        let table = ["a": "b", "b": "a"]
        let r = Result { try ExpressionEvaluator.evaluateTable(table) }
        switch r {
        case .failure(let e as EvalError):
            if case .cycle(let names) = e {
                #expect(names.contains("a"))
                #expect(names.contains("b"))
            } else {
                Issue.record("expected .cycle, got \(e)")
            }
        default:
            Issue.record("expected failure, got \(r)")
        }
    }

    @Test("Longer cycle (a→b→c→a) → .cycle, no hang")
    func cycleThreeNodes() {
        let table = ["a": "b", "b": "c", "c": "a"]
        #expect(throws: EvalError.self) {
            try ExpressionEvaluator.evaluateTable(table)
        }
    }

    @Test("Direct self-reference (a=a) → .cycle")
    func selfReference() {
        let table = ["a": "a + 1"]
        #expect(throws: EvalError.self) {
            try ExpressionEvaluator.evaluateTable(table)
        }
    }

    @Test("Table propagates a per-expression unknown-name error")
    func tableUnknownName() {
        let table = ["a": "nope + 1"]   // nope is neither a key nor external
        #expect(throws: EvalError.self) {
            try ExpressionEvaluator.evaluateTable(table)
        }
    }

    // MARK: - parseAssignment: accepts

    @Test("parseAssignment accepts valid assignments")
    func parseAssignmentAccepts() throws {
        let a = try #require(ExpressionEvaluator.parseAssignment("a=22"))
        #expect(a.name == "a")
        #expect(a.expression == "22")
        #expect(a.unit == nil)

        let b = try #require(ExpressionEvaluator.parseAssignment("a=22mm"))
        #expect(b.name == "a")
        #expect(b.expression == "22mm")
        #expect(b.unit == "mm")

        let c = try #require(ExpressionEvaluator.parseAssignment("b=a*2"))
        #expect(c.name == "b")
        #expect(c.expression == "a*2")
        #expect(c.unit == nil)

        // Whitespace around `=` and underscore-led name.
        let d = try #require(ExpressionEvaluator.parseAssignment("  _len  =  3.5 cm "))
        #expect(d.name == "_len")
        #expect(d.expression == "3.5 cm")
        #expect(d.unit == "cm")
    }

    // MARK: - parseAssignment: rejects (returns nil)

    @Test("parseAssignment rejects non-assignments")
    func parseAssignmentRejects() {
        #expect(ExpressionEvaluator.parseAssignment("10,20") == nil)   // coordinate
        #expect(ExpressionEvaluator.parseAssignment("@5,5") == nil)    // relative coord
        #expect(ExpressionEvaluator.parseAssignment("line") == nil)    // command, no `=`
        #expect(ExpressionEvaluator.parseAssignment("5<30") == nil)    // polar coord
        #expect(ExpressionEvaluator.parseAssignment("2x=5") == nil)    // name not letter/_-led
        #expect(ExpressionEvaluator.parseAssignment("=") == nil)       // empty name + empty rhs
        #expect(ExpressionEvaluator.parseAssignment("=5") == nil)      // empty name
        #expect(ExpressionEvaluator.parseAssignment("a=") == nil)      // empty rhs
        #expect(ExpressionEvaluator.parseAssignment("a==5") == nil)    // comparison, not assignment
        #expect(ExpressionEvaluator.parseAssignment("a b=5") == nil)   // invalid name with space
    }

    // MARK: - Unit token → DrawingUnit inverse helper

    @Test("DrawingUnit(unitToken:) maps common tokens")
    func unitTokenLookup() {
        #expect(DrawingUnit(unitToken: "mm") == .millimeter)
        #expect(DrawingUnit(unitToken: "cm") == .centimeter)
        #expect(DrawingUnit(unitToken: "m") == .meter)
        #expect(DrawingUnit(unitToken: "km") == .kilometer)
        #expect(DrawingUnit(unitToken: "in") == .inch)
        #expect(DrawingUnit(unitToken: "\"") == .inch)
        #expect(DrawingUnit(unitToken: "ft") == .foot)
        #expect(DrawingUnit(unitToken: "'") == .foot)
        #expect(DrawingUnit(unitToken: "yd") == .yard)
        #expect(DrawingUnit(unitToken: "MM") == .millimeter)   // case-insensitive
        #expect(DrawingUnit(unitToken: " cm ") == .centimeter) // trims whitespace
        #expect(DrawingUnit(unitToken: "millimeter") == .millimeter)  // spelled out
    }

    @Test("DrawingUnit(unitToken:) returns nil for non-units")
    func unitTokenLookupNil() {
        #expect(DrawingUnit(unitToken: "") == nil)
        #expect(DrawingUnit(unitToken: "  ") == nil)
        #expect(DrawingUnit(unitToken: "frob") == nil)
        #expect(DrawingUnit(unitToken: "xyz") == nil)
    }

    @Test("End-to-end: parse + evaluate + map unit (no per-drawing accessor)")
    func endToEndUnitBoundary() throws {
        // This is exactly the seam a later app lane drives: parse the assignment,
        // get the magnitude + token from the evaluator, then map the token to a
        // DrawingUnit and apply factorToMM — the conversion lives with the CALLER.
        let parsed = try #require(ExpressionEvaluator.parseAssignment("width=3.5cm"))
        let (value, token) = try ExpressionEvaluator.evaluateLiteralUnit(parsed.expression)
        #expect(near(value, 3.5))
        let unit = try #require(token.flatMap { DrawingUnit(unitToken: $0) })
        #expect(unit == .centimeter)
        #expect(near(value * unit.factorToMM, 35))   // 3.5 cm == 35 mm (caller's choice)
    }

    @Test("Spaced and unspaced unit literals behave identically")
    func spacedUnitEquivalence() throws {
        // Regression: parseAssignment/bareLiteralUnitToken accepted a space before
        // the unit suffix, but evaluate() used to reject `3.5 cm` with .syntax —
        // the two disagreed. The lexer now consumes optional `whitespace + suffix`
        // so both spellings parse, evaluate, and map identically.
        for spelling in ["3.5cm", "3.5 cm", "3.5  cm"] {
            let (value, token) = try ExpressionEvaluator.evaluateLiteralUnit(spelling)
            #expect(near(value, 3.5), "value for \(spelling)")
            #expect(token == "cm", "token for \(spelling)")
            let unit = try #require(token.flatMap { DrawingUnit(unitToken: $0) })
            #expect(near(value * unit.factorToMM, 35), "mm for \(spelling)")  // 3.5 cm == 35 mm
        }
        // Plain evaluate() must also accept the spaced form (no trailing-token error).
        #expect(near(try ExpressionEvaluator.evaluate("22 mm"), 22))
        #expect(near(try ExpressionEvaluator.evaluate("22mm"), 22))

        // And the assignment path agrees end-to-end on the spaced form.
        let parsed = try #require(ExpressionEvaluator.parseAssignment("a=22 mm"))
        #expect(parsed.unit == "mm")
        #expect(near(try ExpressionEvaluator.evaluate(parsed.expression), 22))
    }

    @Test("Whitespace before an operator is NOT swallowed as a unit")
    func whitespaceBeforeOperatorUnaffected() throws {
        // The optional-whitespace+suffix consumption must not break ordinary
        // spaced arithmetic where a number is followed by space + operator.
        #expect(near(try ExpressionEvaluator.evaluate("3 + 4"), 7))
        #expect(near(try ExpressionEvaluator.evaluate("3 * 4"), 12))
        #expect(near(try ExpressionEvaluator.evaluate("10 - 2 mm"), 8))   // suffix on 2nd literal
    }
}
