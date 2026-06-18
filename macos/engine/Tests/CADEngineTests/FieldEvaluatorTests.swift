//
//  FieldEvaluatorTests.swift
//  CADEngineTests
//
//  Wave 2a — the FIELDS engine evaluator + substitution tests:
//    - each MVP token (.date / .layoutName / .fileName) evaluates with a context
//    - a missing context value → the "####" sentinel (per token)
//    - format hints (date pattern; fileName name/nameext/path)
//    - the forward-compatible .objectProperty token (sentinel without a resolver;
//      a value when a resolver is wired)
//    - placeholder substitution: marker → value; nil context / no fields → verbatim;
//      multiple fields; an unmatched marker left in place; the marker is zero-width
//
//  Suite/type names are domain-namespaced (`FieldEngine*`) per CONVENTIONS.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Fixtures

private enum FieldFixtures {
    /// A fixed reference date: 2026-06-17 14:30:00 UTC, built deterministically so a
    /// date-pattern assertion is stable regardless of the test machine's clock.
    static let refDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 17; c.hour = 14; c.minute = 30; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    /// A full context with date / layout / file all populated, in UTC so a fixed
    /// date pattern is deterministic.
    static func fullContext(file: String = "/Users/me/drawings/Plan.dxf") -> FieldContext {
        FieldContext(date: refDate, layoutName: "Layout1", fileName: file)
    }

    /// A date formatter pinned to UTC + POSIX so an assertion matches `formatDate`.
    static func utcFormatter(_ pattern: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")!
        df.dateFormat = pattern
        return df
    }
}

// MARK: - Token evaluation

@Suite struct FieldEngineEvaluateTests {

    @Test func dateWithPatternHint() {
        let ctx = FieldFixtures.fullContext()
        // The evaluator uses the default time zone; pin both sides to UTC by using a
        // date-only pattern that is unaffected by the small TZ offsets on CI, and
        // assert via the SAME formatter the evaluator would build (default TZ).
        let token = FieldToken.date(format: "yyyy-MM-dd")
        let out = FieldEvaluator.evaluate(token, context: ctx)
        // Build the expectation with the evaluator's own locale + the machine TZ so
        // it matches regardless of where the test runs.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        #expect(out == df.string(from: FieldFixtures.refDate))
    }

    @Test func dateDefaultFormatIsNonEmpty() {
        let ctx = FieldFixtures.fullContext()
        let out = FieldEvaluator.evaluate(.date(), context: ctx)
        #expect(!out.isEmpty)
        #expect(out != FieldEvaluator.missingSentinel)
    }

    @Test func dateMissingValueIsSentinel() {
        let ctx = FieldContext(date: nil, layoutName: "L", fileName: "f.dxf")
        #expect(FieldEvaluator.evaluate(.date(), context: ctx) == FieldEvaluator.missingSentinel)
    }

    @Test func layoutNameEvaluates() {
        let ctx = FieldFixtures.fullContext()
        #expect(FieldEvaluator.evaluate(.layoutName(), context: ctx) == "Layout1")
    }

    @Test func layoutNameMissingIsSentinel() {
        #expect(FieldEvaluator.evaluate(.layoutName(),
                                        context: FieldContext()) == FieldEvaluator.missingSentinel)
        // Empty string is treated as missing too.
        #expect(FieldEvaluator.evaluate(.layoutName(),
                                        context: FieldContext(layoutName: "")) == FieldEvaluator.missingSentinel)
    }

    @Test func fileNameDefaultIsNameWithoutExtension() {
        let ctx = FieldFixtures.fullContext(file: "/Users/me/drawings/Plan.dxf")
        #expect(FieldEvaluator.evaluate(.fileName(), context: ctx) == "Plan")
    }

    @Test func fileNameWithExtensionHint() {
        let ctx = FieldFixtures.fullContext(file: "/Users/me/drawings/Plan.dxf")
        #expect(FieldEvaluator.evaluate(.fileName(format: "nameext"), context: ctx) == "Plan.dxf")
    }

    @Test func fileNameFullPathHint() {
        let path = "/Users/me/drawings/Plan.dxf"
        let ctx = FieldFixtures.fullContext(file: path)
        #expect(FieldEvaluator.evaluate(.fileName(format: "path"), context: ctx) == path)
    }

    @Test func fileNameUnknownHintFallsBackToBareName() {
        let ctx = FieldFixtures.fullContext(file: "/Users/me/drawings/Plan.dxf")
        #expect(FieldEvaluator.evaluate(.fileName(format: "garbage"), context: ctx) == "Plan")
    }

    @Test func fileNameMissingIsSentinel() {
        #expect(FieldEvaluator.evaluate(.fileName(),
                                        context: FieldContext()) == FieldEvaluator.missingSentinel)
    }

    // Forward-compatible .objectProperty: sentinel without a resolver; a value with one.
    @Test func objectPropertyWithoutResolverIsSentinel() {
        let token = FieldToken.objectProperty(entityID: EntityID(7), property: "area")
        #expect(FieldEvaluator.evaluate(token, context: FieldFixtures.fullContext())
                    == FieldEvaluator.missingSentinel)
    }

    @Test func objectPropertyWithResolverReturnsValue() {
        let ctx = FieldContext(objectPropertyResolver: { id, prop in
            (id == EntityID(7) && prop == "area") ? "123.45" : nil
        })
        #expect(FieldEvaluator.evaluate(.objectProperty(entityID: EntityID(7), property: "area"),
                                        context: ctx) == "123.45")
        // A property the resolver doesn't know → sentinel.
        #expect(FieldEvaluator.evaluate(.objectProperty(entityID: EntityID(7), property: "length"),
                                        context: ctx) == FieldEvaluator.missingSentinel)
    }
}

// MARK: - Placeholder substitution

@Suite struct FieldEngineSubstituteTests {

    @Test func placeholderRoundTripsThroughSubstitution() {
        let ctx = FieldFixtures.fullContext()
        let raw = "Sheet: \(FieldEvaluator.placeholder(for: 0))"
        let fields = [FieldRun(index: 0, token: .layoutName())]
        #expect(FieldEvaluator.substitute(raw, fields: fields, context: ctx) == "Sheet: Layout1")
    }

    @Test func nilContextLeavesTextVerbatim() {
        let raw = "Sheet: \(FieldEvaluator.placeholder(for: 0))"
        let fields = [FieldRun(index: 0, token: .layoutName())]
        #expect(FieldEvaluator.substitute(raw, fields: fields, context: nil) == raw)
    }

    @Test func noFieldsLeavesTextVerbatim() {
        let ctx = FieldFixtures.fullContext()
        let raw = "Plain text, no markers."
        #expect(FieldEvaluator.substitute(raw, fields: nil, context: ctx) == raw)
        #expect(FieldEvaluator.substitute(raw, fields: [], context: ctx) == raw)
    }

    @Test func multipleFieldsSubstituteIndependently() {
        let ctx = FieldFixtures.fullContext(file: "/x/Plan.dxf")
        let raw = "\(FieldEvaluator.placeholder(for: 0)) — \(FieldEvaluator.placeholder(for: 1))"
        let fields = [
            FieldRun(index: 0, token: .fileName()),
            FieldRun(index: 1, token: .layoutName()),
        ]
        #expect(FieldEvaluator.substitute(raw, fields: fields, context: ctx) == "Plan — Layout1")
    }

    @Test func missingValueSubstitutesSentinelInline() {
        // No date in the context → the date placeholder becomes "####".
        let ctx = FieldContext(layoutName: "L1")
        let raw = "Date: \(FieldEvaluator.placeholder(for: 0))"
        let fields = [FieldRun(index: 0, token: .date())]
        #expect(FieldEvaluator.substitute(raw, fields: fields, context: ctx) == "Date: ####")
    }

    @Test func unmatchedMarkerLeftInPlace() {
        // A field array missing the run for slot 1 leaves that placeholder untouched.
        let ctx = FieldFixtures.fullContext()
        let raw = "\(FieldEvaluator.placeholder(for: 0))\(FieldEvaluator.placeholder(for: 1))"
        let fields = [FieldRun(index: 0, token: .layoutName())]
        let out = FieldEvaluator.substitute(raw, fields: fields, context: ctx)
        #expect(out.hasPrefix("Layout1"))
        #expect(out.contains(FieldEvaluator.placeholder(for: 1)))
    }

    @Test func placeholderMarkerIsZeroWidth() {
        // The bracketing sentinel is U+FEFF (zero-width-no-break-space) so an
        // un-substituted marker shapes to nothing.
        let marker = FieldEvaluator.placeholder(for: 3)
        #expect(marker.unicodeScalars.first == Unicode.Scalar(0xFEFF))
        #expect(marker.unicodeScalars.last == Unicode.Scalar(0xFEFF))
        #expect(marker.contains("{3}"))
    }
}
