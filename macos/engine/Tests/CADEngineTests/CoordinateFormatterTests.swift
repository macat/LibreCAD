//
//  CoordinateFormatterTests.swift
//  CADEngineTests
//
//  Drives the pure `CoordinateFormatter` (no GUI) — the status bar's coordinate /
//  length readout formatter (UX-plan U3, gap G6). Covers each `LinearFormat`
//  (decimal / scientific / engineering / architectural / fractional), the
//  precision + trailing-zero handling, the unit-sign suffix, and the `X / Y`
//  coordinate-pair form the status bar renders.
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

@Suite("CoordinateFormatter linear readout")
struct CoordinateFormatterLinearTests {

    // MARK: - Decimal (the default; mirrors dimFormat)

    @Test("decimal strips trailing zeros and shows whole numbers cleanly")
    func decimalTrim() {
        #expect(CoordinateFormatter.length(10.0, format: .decimal, precision: 4) == "10")
        #expect(CoordinateFormatter.length(12.5, format: .decimal, precision: 4) == "12.5")
        #expect(CoordinateFormatter.length(12.500, format: .decimal, precision: 3) == "12.5")
        #expect(CoordinateFormatter.length(0, format: .decimal, precision: 4) == "0")
    }

    @Test("decimal honors precision (rounds to N places)")
    func decimalPrecision() {
        #expect(CoordinateFormatter.length(3.14159, format: .decimal, precision: 2) == "3.14")
        #expect(CoordinateFormatter.length(3.14159, format: .decimal, precision: 0) == "3")
        #expect(CoordinateFormatter.length(2.999, format: .decimal, precision: 2) == "3")
    }

    @Test("negative values keep their sign; negative zero is normalized to 0")
    func negatives() {
        #expect(CoordinateFormatter.length(-7.25, format: .decimal, precision: 4) == "-7.25")
        // A value that rounds to zero must not render "-0".
        #expect(CoordinateFormatter.length(-0.0001, format: .decimal, precision: 2) == "0")
    }

    // MARK: - Unit sign suffix

    @Test("decimal length appends the metric unit sign")
    func unitSuffix() {
        #expect(CoordinateFormatter.length(12.5, format: .decimal, precision: 4, unit: .millimeter) == "12.5 mm")
        #expect(CoordinateFormatter.length(3, format: .decimal, precision: 4, unit: .meter) == "3 m")
    }

    @Test("a unit with no sign (.none) yields the bare number")
    func noSign() {
        #expect(CoordinateFormatter.length(5, format: .decimal, precision: 4, unit: .none) == "5")
    }

    @Test("inch unit appends the double-prime sign in decimal format")
    func inchDecimal() {
        #expect(CoordinateFormatter.length(2.5, format: .decimal, precision: 4, unit: .inch) == "2.5 \"")
    }

    // MARK: - Scientific

    @Test("scientific notation uses %e at the given precision")
    func scientific() {
        // 12345 → 1.2e+04 at precision 1.
        #expect(CoordinateFormatter.length(12345, format: .scientific, precision: 1) == "1.2e+04")
    }

    // MARK: - Engineering (feet + decimal inches; value is inches)

    @Test("engineering rolls inches into feet with decimal remainder")
    func engineering() {
        #expect(CoordinateFormatter.length(13.5, format: .engineering, precision: 4) == "1'-1.5\"")
        #expect(CoordinateFormatter.length(6, format: .engineering, precision: 4) == "6\"")
        #expect(CoordinateFormatter.length(24, format: .engineering, precision: 4) == "2'-0\"")
    }

    @Test("engineering does NOT get a doubled unit sign even with a unit")
    func engineeringNoDoubleSign() {
        // The feet-inch marks already carry the unit; no " mm"/" \"" appended.
        #expect(CoordinateFormatter.length(13.5, format: .engineering, precision: 4, unit: .inch) == "1'-1.5\"")
    }

    // MARK: - Architectural (feet + fractional inches)

    @Test("architectural rolls inches into feet with a reduced fraction")
    func architectural() {
        // 13.5 inches → 1 foot, 1 1/2 inches.
        #expect(CoordinateFormatter.length(13.5, format: .architectural, precision: 4) == "1'-1 1/2\"")
        // 12 inches → exactly 1 foot, 0 inches.
        #expect(CoordinateFormatter.length(12, format: .architectural, precision: 4) == "1'-0\"")
    }

    // MARK: - Fractional (plain fractional inches, no feet)

    @Test("fractional inches reduce to lowest terms, no feet roll-up")
    func fractional() {
        #expect(CoordinateFormatter.length(13.5, format: .fractional, precision: 4) == "13 1/2")
        #expect(CoordinateFormatter.length(0.25, format: .fractional, precision: 4) == "1/4")
        #expect(CoordinateFormatter.length(2.0, format: .fractional, precision: 4) == "2")
    }

    @Test("fractional respects the precision-driven denominator (1/8 at precision 3)")
    func fractionalDenominator() {
        // precision 3 ⇒ denominator 2^3 = 8; 0.125 → 1/8.
        #expect(CoordinateFormatter.length(0.125, format: .fractional, precision: 3) == "1/8")
    }
}

@Suite("CoordinateFormatter coordinate pair")
struct CoordinateFormatterPairTests {

    @Test("a decimal X/Y pair appends the unit sign once")
    func decimalPair() {
        let s = CoordinateFormatter.coordinatePair(x: 12.5, y: 8.0,
                                                   format: .decimal, precision: 4,
                                                   unit: .millimeter)
        #expect(s == "X 12.5   Y 8 mm")
    }

    @Test("a pair with no unit omits the sign")
    func noUnitPair() {
        let s = CoordinateFormatter.coordinatePair(x: 1, y: 2,
                                                   format: .decimal, precision: 4,
                                                   unit: .none)
        #expect(s == "X 1   Y 2")
    }

    @Test("a feet-inch pair does not append a trailing unit sign")
    func feetInchPair() {
        let s = CoordinateFormatter.coordinatePair(x: 12, y: 24,
                                                   format: .architectural, precision: 4,
                                                   unit: .inch)
        #expect(s == "X 1'-0\"   Y 2'-0\"")
    }
}
