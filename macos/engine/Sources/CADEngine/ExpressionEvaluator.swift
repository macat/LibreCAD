//
//  ExpressionEvaluator.swift
//  CADEngine
//
//  A pure, value-only expression evaluator for named drawing parameters
//  (Lane L0 of the parametric-parameters program). It evaluates arithmetic
//  expressions over a caller-supplied symbol table — e.g. `a=22`, `b=a*2`,
//  `(a+b)/2`, `22mm` — with operator precedence, parentheses, unary minus,
//  numeric literals (with an OPTIONAL trailing unit token), and identifier
//  references. A whole-table evaluator topologically orders inter-parameter
//  dependencies (Kahn) and detects cycles WITHOUT looping forever or emitting
//  NaN.
//
//  Deliberately scoped to the MVP grammar: arithmetic + parens + unary minus +
//  numeric/unit literals + name refs + cycle detection. DEFERRED: a function
//  library (sin/sqrt/…), conditional/string expressions, and any UI.
//
//  UNIT BOUNDARY (critic fix): this evaluator has NO access to the drawing's
//  unit, so it MUST NOT convert units to drawing units. A literal such as
//  `22mm` evaluates to its numeric value (22) and the parser records the unit
//  TOKEN it saw (`"mm"`). The CALLER (a later app-seam lane) maps the token to a
//  `DrawingUnit` via `DrawingUnit(unitToken:)` and applies `factorToMM`. Mixing
//  a unit suffix into a sub-expression (e.g. `22mm * 2`) keeps the magnitude but
//  is reported through `unitToken` only for a bare top-level literal — see
//  `evaluateLiteralUnit`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Errors

/// A typed evaluation/parse failure. No NaN, no partial results — every failure
/// surfaces as one of these cases.
public enum EvalError: Error, Equatable, Sendable {
    /// The token stream did not form a valid expression (unexpected token,
    /// trailing input, unbalanced parens, empty expression, malformed number…).
    case syntax
    /// An identifier reference resolved against neither the symbol table nor a
    /// sibling parameter. Carries the offending name.
    case unknownName(String)
    /// A division (or modulo-like) by exactly zero.
    case divideByZero
    /// A circular dependency among parameters (`a=b`, `b=a`). Carries the names
    /// that participate in the unresolved cycle (sorted, may be empty if the
    /// detector cannot attribute it precisely).
    case cycle([String])
}

// MARK: - Public evaluator API

/// A stateless expression evaluator. All entry points are pure value functions;
/// no instance state is required, but a namespace keeps the API discoverable.
public enum ExpressionEvaluator {

    // MARK: Single-expression evaluation

    /// Evaluates a single expression string against `symbols`
    /// (identifier → already-resolved Double). Returns the numeric value.
    ///
    /// - Throws: `EvalError` on any syntax/name/division failure.
    public static func evaluate(_ text: String,
                                symbols: [String: Double] = [:]) throws -> Double {
        var parser = Parser(text)
        let value = try parser.parseExpressionEntry(symbols: symbols)
        return value
    }

    /// `Result`-flavored convenience over ``evaluate(_:symbols:)``.
    public static func evaluateResult(_ text: String,
                                      symbols: [String: Double] = [:]) -> Result<Double, EvalError> {
        do {
            return .success(try evaluate(text, symbols: symbols))
        } catch let e as EvalError {
            return .failure(e)
        } catch {
            return .failure(.syntax)
        }
    }

    /// Evaluates a single expression AND reports the unit token of a bare
    /// top-level literal, if any. Useful for an entry like `22mm` where the
    /// caller wants both the magnitude (22) and the token (`"mm"`) so it can
    /// convert with the drawing's `DrawingUnit`. For a compound expression
    /// (e.g. `a*2`) `unitToken` is `nil`.
    ///
    /// The token is only populated when the WHOLE expression is a single signed
    /// numeric literal with a suffix; this mirrors how a parameter row is
    /// typically entered (`"22mm"`), and avoids guessing a unit for arithmetic.
    public static func evaluateLiteralUnit(_ text: String,
                                           symbols: [String: Double] = [:]) throws -> (value: Double, unitToken: String?) {
        let token = bareLiteralUnitToken(text)
        let value = try evaluate(text, symbols: symbols)
        return (value, token)
    }

    // MARK: Whole-table topological evaluation

    /// Evaluates an entire parameter table (paramName → expression text) with
    /// dependency ordering (Kahn topological sort). Every parameter is evaluated
    /// once its referenced parameters are known.
    ///
    /// - Returns: a fully-resolved `[String: Double]` on success.
    /// - Throws: `.cycle(names)` for a circular reference (the evaluation does
    ///   NOT loop forever and never feeds NaN forward), `.unknownName` for a
    ///   reference to neither a table key nor an external symbol, or the first
    ///   per-expression `EvalError` encountered.
    ///
    /// `external` supplies values for names NOT present as table keys (e.g.
    /// constants the host injects). A reference resolves table-first, then
    /// `external`.
    public static func evaluateTable(_ table: [String: String],
                                     external: [String: Double] = [:]) throws -> [String: Double] {
        // 1. Parse each expression once and capture the identifiers it reads.
        //    A parse error here surfaces immediately (before any ordering work).
        var deps: [String: Set<String>] = [:]      // node -> table-keys it depends on
        var allNames = Set(table.keys)
        for (name, expr) in table {
            let referenced = try identifiers(in: expr)
            // Only dependencies that are themselves table keys constrain ordering;
            // references to `external` (or unknowns) are validated at eval time.
            deps[name] = referenced.intersection(allNames)
        }

        // 2. Kahn topological sort over the table-key dependency graph.
        var indegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]   // x -> nodes that depend on x
        for name in allNames { indegree[name] = 0 }
        for (name, ds) in deps {
            indegree[name] = ds.count
            for d in ds { dependents[d, default: []].append(name) }
        }

        var ready = allNames.filter { (indegree[$0] ?? 0) == 0 }.sorted() // deterministic
        var order: [String] = []
        order.reserveCapacity(allNames.count)

        while let next = ready.first {
            ready.removeFirst()
            order.append(next)
            for dep in (dependents[next] ?? []).sorted() {
                let d = (indegree[dep] ?? 0) - 1
                indegree[dep] = d
                if d == 0 {
                    // Insert keeping `ready` sorted for deterministic output.
                    let idx = ready.firstIndex { $0 > dep } ?? ready.endIndex
                    ready.insert(dep, at: idx)
                }
            }
        }

        // 3. Anything left with a positive indegree is in (or fed by) a cycle.
        if order.count != allNames.count {
            let stuck = allNames.filter { (indegree[$0] ?? 0) > 0 }.sorted()
            throw EvalError.cycle(stuck)
        }

        // 4. Evaluate in topological order, layering results over `external`.
        var resolved = external
        for name in order {
            // Table keys shadow external values of the same name.
            let expr = table[name]!
            let value = try evaluate(expr, symbols: resolved)
            resolved[name] = value
        }
        // Return only the table's own keys (callers don't want `external` echoed).
        var out: [String: Double] = [:]
        out.reserveCapacity(allNames.count)
        for name in allNames { out[name] = resolved[name] }
        return out
    }

    // MARK: Assignment parsing

    /// Parses a `name = exprText[unit]` assignment line.
    ///
    /// Returns `nil` (NOT an assignment) for anything whose left-hand side is not
    /// a valid identifier or that has no top-level `=`. This guards the command
    /// line so coordinate / tool-option input is never mis-parsed:
    ///   - `10,20`     → nil (no `=`)
    ///   - `@5,5`      → nil
    ///   - `line`      → nil (no `=`)
    ///   - `5<30`      → nil
    ///   - `2x=5`      → nil (name must start with a letter/underscore)
    ///   - `=`         → nil (empty name)
    /// and the triple for:
    ///   - `a=22`      → ("a", "22", nil)
    ///   - `a=22mm`    → ("a", "22mm", "mm")   (unit token reported, NOT applied)
    ///   - `b=a*2`     → ("b", "a*2", nil)
    ///
    /// The returned `expression` is the raw right-hand side (trimmed); it is NOT
    /// evaluated here. `unit` is the unit token of a bare top-level literal RHS
    /// (e.g. `"mm"`), else `nil` — matching ``evaluateLiteralUnit(_:symbols:)``.
    public static func parseAssignment(_ text: String) -> (name: String, expression: String, unit: String?)? {
        // Find the FIRST top-level `=` that is not part of a comparison operator
        // (`==`, `<=`, `>=`, `!=`). For our MVP grammar there are no comparisons,
        // but we still reject `==`/`<=`/… so a stray comparison never becomes an
        // assignment.
        guard let eq = topLevelAssignmentEquals(text) else { return nil }

        let lhsRaw = String(text[text.startIndex..<eq])
        let rhsRaw = String(text[text.index(after: eq)...])

        let name = lhsRaw.trimmingCharacters(in: .whitespaces)
        guard isValidIdentifier(name) else { return nil }

        let expression = rhsRaw.trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty else { return nil }

        let unit = bareLiteralUnitToken(expression)
        return (name, expression, unit)
    }

    // MARK: Identifier extraction

    /// Returns the set of identifier names referenced by `text` (parse-validated).
    /// Throws `.syntax` if `text` is not a well-formed expression.
    public static func identifiers(in text: String) throws -> Set<String> {
        var lexer = Lexer(text)
        var names = Set<String>()
        // A light validation pass: relexing also catches malformed numbers, but
        // structural validity is enforced when the expression is actually parsed
        // (evaluateTable parses+evaluates; here we only collect names). We still
        // surface a clear `.syntax` for an unrecognized character.
        while let tok = try lexer.next() {
            if case let .name(n) = tok { names.insert(n) }
        }
        return names
    }
}

// MARK: - Unit-token boundary helpers (pure CADEngine)

extension DrawingUnit {

    /// Inverse of ``sign`` (`RS_Units::unitToSign`): maps a unit TOKEN string
    /// (as written by a user / produced by the parser) back to a `DrawingUnit`,
    /// or `nil` if the token names no unit. Case-insensitive, whitespace-trimmed.
    ///
    /// This is the seam a later app-lane uses to turn the parser's unit token
    /// (e.g. `"mm"`) into an engine `DrawingUnit` so it can apply `factorToMM`.
    /// There is intentionally no `DrawingUnit(sign:)` today — this is that pure
    /// helper, kept here next to the evaluator that produces the tokens. It does
    /// NOT touch any per-drawing accessor.
    public init?(unitToken token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // Primary: match the canonical `sign` of each case (case-insensitive).
        for unit in DrawingUnit.allCases where !unit.sign.isEmpty {
            if unit.sign.lowercased() == lower {
                self = unit
                return
            }
        }
        // Secondary: a handful of common spelled-out / alias tokens a user might
        // type that don't equal the terse `sign` (e.g. `in`, `ft`, full words).
        switch lower {
        case "in", "inch", "inches", "\"":          self = .inch
        case "ft", "feet", "'":                      self = .foot
        case "mi", "mile", "miles":                  self = .mile
        case "mm", "millimeter", "millimeters",
             "millimetre", "millimetres":            self = .millimeter
        case "cm", "centimeter", "centimeters",
             "centimetre", "centimetres":            self = .centimeter
        case "m", "meter", "meters",
             "metre", "metres":                      self = .meter
        case "km", "kilometer", "kilometers",
             "kilometre", "kilometres":              self = .kilometer
        case "yd", "yard", "yards":                  self = .yard
        case "mil", "mils":                          self = .mil
        case "um", "µm", "micron", "microns",
             "micrometer", "micrometre":             self = .micron
        case "nm", "nanometer", "nanometre":         self = .nanometer
        case "dm", "decimeter", "decimetre":         self = .decimeter
        case "dam", "decameter", "decametre":        self = .decameter
        case "hm", "hectometer", "hectometre":       self = .hectometer
        default:
            return nil
        }
    }
}

// MARK: - Lexer

/// A token in the MVP expression grammar.
private enum Token: Equatable {
    case number(Double)        // numeric literal magnitude (unit suffix stripped)
    case name(String)          // identifier reference
    case plus
    case minus
    case star
    case slash
    case lparen
    case rparen
}

/// Hand-written lexer over a `[Character]` buffer. Recognizes numbers (with an
/// OPTIONAL trailing unit-letter suffix, which is consumed but does not change
/// the magnitude), identifiers, the four binary operators, and parentheses.
/// Throws `.syntax` on a malformed number or an unrecognized character.
private struct Lexer {
    private let chars: [Character]
    private var i = 0

    init(_ text: String) {
        self.chars = Array(text)
    }

    private func peek() -> Character? { i < chars.count ? chars[i] : nil }

    private static func isIdentStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }
    private static func isIdentContinue(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }

    /// Returns the next token, or `nil` at end of input. Throws `.syntax`.
    mutating func next() throws -> Token? {
        // Skip whitespace.
        while let c = peek(), c == " " || c == "\t" { i += 1 }
        guard let c = peek() else { return nil }

        switch c {
        case "+": i += 1; return .plus
        case "-": i += 1; return .minus
        case "*": i += 1; return .star
        case "/": i += 1; return .slash
        case "(": i += 1; return .lparen
        case ")": i += 1; return .rparen
        default:
            break
        }

        if c.isNumber || c == "." {
            return try lexNumber()
        }
        if Lexer.isIdentStart(c) {
            return lexName()
        }
        // Any other character (`,`, `@`, `<`, `=`, `!`, digit-leading junk…) is
        // not part of the arithmetic grammar.
        throw EvalError.syntax
    }

    /// Lexes a numeric literal with an OPTIONAL trailing unit-letter suffix.
    /// The suffix (e.g. `mm`, `cm`, `"`) is consumed but ignored for magnitude —
    /// the unit boundary is handled separately by the parser/caller. Supports
    /// integers, decimals, and scientific notation (`1e3`, `2.5E-4`).
    private mutating func lexNumber() throws -> Token {
        let start = i
        var sawDigit = false
        var sawDot = false

        while let c = peek() {
            if c.isNumber { sawDigit = true; i += 1 }
            else if c == "." {
                if sawDot { throw EvalError.syntax }
                sawDot = true; i += 1
            } else {
                break
            }
        }
        // Optional exponent.
        if let c = peek(), c == "e" || c == "E" {
            // Only treat as exponent if it's followed by an optional sign + digit.
            let save = i
            i += 1
            if let s = peek(), s == "+" || s == "-" { i += 1 }
            if let d = peek(), d.isNumber {
                while let d2 = peek(), d2.isNumber { i += 1 }
            } else {
                // Not actually an exponent (e.g. `2meter`): rewind, let suffix
                // handling consume the letters.
                i = save
            }
        }
        guard sawDigit else { throw EvalError.syntax }

        let numStr = String(chars[start..<i])
        guard let value = Double(numStr) else { throw EvalError.syntax }

        // Consume an optional unit-letter suffix (letters / `"` / `'` / `µ`),
        // allowing OPTIONAL whitespace between the number and the suffix so that
        // `3.5cm` and `3.5 cm` lex identically (and agree with `parseAssignment`
        // / `bareLiteralUnitToken`). The whitespace is only swallowed when a unit
        // suffix actually follows — otherwise it's left for the next token so an
        // expression like `3 + 4` is unaffected. The suffix is part of the
        // literal's token but does not change the magnitude.
        let isUnitChar: (Character) -> Bool = { $0.isLetter || $0 == "\"" || $0 == "'" || $0 == "µ" }
        if let c = peek(), isUnitChar(c) {
            // Adjacent suffix (`3.5cm`).
            while let u = peek(), isUnitChar(u) { i += 1 }
        } else if let c = peek(), c == " " || c == "\t" {
            // Look past whitespace: only consume it (and the suffix) if a unit
            // suffix immediately follows the whitespace; otherwise leave `i` put.
            var j = i
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            if j < chars.count, isUnitChar(chars[j]) {
                i = j
                while let u = peek(), isUnitChar(u) { i += 1 }
            }
        }
        return .number(value)
    }

    private mutating func lexName() -> Token {
        let start = i
        i += 1
        while let c = peek(), Lexer.isIdentContinue(c) { i += 1 }
        return .name(String(chars[start..<i]))
    }
}

// MARK: - Parser (recursive descent)

/// Recursive-descent parser/evaluator for the MVP grammar:
///
///     expression := term (('+' | '-') term)*
///     term       := factor (('*' | '/') factor)*
///     factor     := '-' factor | '(' expression ')' | number | name
///
/// Evaluates as it parses, resolving names against the supplied symbol table.
private struct Parser {
    private var tokens: [Token] = []
    private var pos = 0
    private let raw: String

    init(_ text: String) {
        self.raw = text
    }

    /// Entry point: lex, parse a full expression, and require EOF.
    mutating func parseExpressionEntry(symbols: [String: Double]) throws -> Double {
        var lexer = Lexer(raw)
        tokens.removeAll(keepingCapacity: true)
        while let t = try lexer.next() { tokens.append(t) }
        guard !tokens.isEmpty else { throw EvalError.syntax }   // empty expression

        let value = try parseExpression(symbols)
        guard pos == tokens.count else { throw EvalError.syntax } // trailing junk
        return value
    }

    private func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func advance() -> Token? {
        guard pos < tokens.count else { return nil }
        defer { pos += 1 }
        return tokens[pos]
    }

    private mutating func parseExpression(_ symbols: [String: Double]) throws -> Double {
        var value = try parseTerm(symbols)
        while let op = peek(), op == .plus || op == .minus {
            pos += 1
            let rhs = try parseTerm(symbols)
            value = (op == .plus) ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm(_ symbols: [String: Double]) throws -> Double {
        var value = try parseFactor(symbols)
        while let op = peek(), op == .star || op == .slash {
            pos += 1
            let rhs = try parseFactor(symbols)
            if op == .star {
                value *= rhs
            } else {
                guard rhs != 0 else { throw EvalError.divideByZero }
                value /= rhs
            }
        }
        return value
    }

    private mutating func parseFactor(_ symbols: [String: Double]) throws -> Double {
        guard let tok = peek() else { throw EvalError.syntax }
        switch tok {
        case .minus:
            pos += 1
            return -(try parseFactor(symbols))
        case .plus:                       // tolerate a leading unary plus
            pos += 1
            return try parseFactor(symbols)
        case .lparen:
            pos += 1
            let inner = try parseExpression(symbols)
            guard peek() == .rparen else { throw EvalError.syntax }
            pos += 1
            return inner
        case .number(let n):
            pos += 1
            return n
        case .name(let id):
            pos += 1
            guard let v = symbols[id] else { throw EvalError.unknownName(id) }
            return v
        case .rparen, .star, .slash:
            throw EvalError.syntax
        }
    }
}

// MARK: - Assignment / identifier helpers

/// Whether `s` is a valid parameter identifier: starts with a letter/underscore,
/// continues with letters/digits/underscores, and is non-empty.
private func isValidIdentifier(_ s: String) -> Bool {
    guard let first = s.first else { return false }
    guard first == "_" || first.isLetter else { return false }
    for c in s.dropFirst() where !(c == "_" || c.isLetter || c.isNumber) {
        return false
    }
    return true
}

/// Finds the index of the FIRST top-level single `=` that denotes an assignment,
/// rejecting comparison operators (`==`, `<=`, `>=`, `!=`). Returns `nil` when
/// there is no such `=`. Parentheses depth is tracked so `a=(b)` works and a `=`
/// only counts at the top level (there are none nested in our grammar, but the
/// guard is cheap and future-proof).
private func topLevelAssignmentEquals(_ text: String) -> String.Index? {
    let chars = Array(text)
    var depth = 0
    var idx = text.startIndex
    var n = 0
    while n < chars.count {
        let c = chars[n]
        switch c {
        case "(": depth += 1
        case ")": depth -= 1
        case "=":
            // Reject `==` and the second char of `<=`/`>=`/`!=`.
            let prev: Character? = n > 0 ? chars[n - 1] : nil
            let nextCh: Character? = n + 1 < chars.count ? chars[n + 1] : nil
            let isComparison = (prev == "<" || prev == ">" || prev == "!" || prev == "=")
                || (nextCh == "=")
            if depth == 0 && !isComparison {
                return idx
            }
        default:
            break
        }
        idx = text.index(after: idx)
        n += 1
    }
    return nil
}

/// If `expr` is a single bare top-level numeric literal with a trailing unit
/// suffix (optionally signed / whitespace-padded — e.g. `22mm`, `-3.5 cm`,
/// `+10in`), returns the suffix TOKEN (`"mm"`). Returns `nil` for a bare number
/// (`22`), a compound expression (`22mm*2`, `a*2`), or anything not matching.
/// The token is returned verbatim (case preserved); the caller maps it via
/// `DrawingUnit(unitToken:)`.
private func bareLiteralUnitToken(_ expr: String) -> String? {
    let s = expr.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    let chars = Array(s)
    var i = 0

    // Optional leading sign.
    if chars[i] == "+" || chars[i] == "-" { i += 1 }
    // Allow whitespace between sign and number.
    while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }

    let numStart = i
    var sawDigit = false
    var sawDot = false
    while i < chars.count {
        let c = chars[i]
        if c.isNumber { sawDigit = true; i += 1 }
        else if c == "." { if sawDot { return nil }; sawDot = true; i += 1 }
        else { break }
    }
    // Optional exponent (mirror the lexer so `1e3mm` parses).
    if i < chars.count, chars[i] == "e" || chars[i] == "E" {
        let save = i
        i += 1
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        if i < chars.count, chars[i].isNumber {
            while i < chars.count, chars[i].isNumber { i += 1 }
        } else {
            i = save
        }
    }
    guard sawDigit else { return nil }

    // Optional whitespace between number and unit.
    while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }

    // The remainder, if any, must be a pure unit token (letters / `"` / `'` / `µ`)
    // with nothing else after it — otherwise it's a compound expression.
    let unitStart = i
    while i < chars.count {
        let c = chars[i]
        if c.isLetter || c == "\"" || c == "'" || c == "µ" { i += 1 }
        else { return nil }  // an operator/paren/etc. → not a bare literal
    }
    guard i == chars.count, unitStart < chars.count else { return nil }
    return String(chars[unitStart..<chars.count])
}
