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

// MARK: - Angle basis ($ANGBASE / $ANGDIR) — UCS-W0

/// Covers the additive `angleBase` / `clockwise` parameters on
/// `CoordinateFormatter.angle` (and the forwarded `polarPair`). The angle basis is
/// AutoCAD's `$ANGBASE` (the WCS direction that displays as zero) plus `$ANGDIR`
/// (0 = CCW default, 1 = CW). The displayed angle is
/// `correctAngle(clockwise ? (angleBase - radians) : (radians - angleBase))`.
@Suite("CoordinateFormatter angle basis ($ANGBASE/$ANGDIR)")
struct CoordinateFormatterAngleBasisTests {

    // MARK: - Default params are byte-identical to the basis-free overload

    @Test("default angleBase/clockwise reproduce the current angle output exactly")
    func defaultsAreIdentical() {
        // Lock the regression: with the defaults the new signature must equal what
        // the formatter produced before the basis params existed, across formats.
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 2) == "90°")
        #expect(CoordinateFormatter.angle(.pi / 4, format: .degreesDecimal, precision: 4) == "45°")
        #expect(CoordinateFormatter.angle(atan2(4.0, 3.0), format: .degreesDecimal, precision: 2) == "53.13°")
        #expect(CoordinateFormatter.angle(-.pi / 2, format: .degreesDecimal, precision: 0) == "270°")
        #expect(CoordinateFormatter.angle(2 * .pi + .pi / 2, format: .degreesDecimal, precision: 0) == "90°")
        #expect(CoordinateFormatter.angle(.pi, format: .radians, precision: 4) == "3.1416r")
        #expect(CoordinateFormatter.angle(.pi / 2, format: .gradians, precision: 2) == "100g")
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesMinutesSeconds, precision: 4) == "90°0'0\"")
        #expect(CoordinateFormatter.angle(.pi / 4, format: .surveyors) == "N 45°0'0\" E")
    }

    @Test("explicitly passing angleBase:0, clockwise:false equals the bare call")
    func explicitDefaultsMatchBare() {
        let inputs: [Double] = [0.0, Double.pi / 6, Double.pi / 2, Double.pi,
                                3 * Double.pi / 2, -Double.pi / 3, 2.7]
        for raw in inputs {
            let bare = CoordinateFormatter.angle(raw, format: .degreesDecimal, precision: 4)
            let explicit = CoordinateFormatter.angle(raw, format: .degreesDecimal, precision: 4,
                                                     angleBase: 0, clockwise: false)
            #expect(bare == explicit)
        }
    }

    // MARK: - $ANGBASE shifts the displayed zero

    @Test("angleBase shifts the displayed zero direction")
    func angleBaseShiftsZero() {
        // With base = 90°, a world angle of 90° displays as 0°.
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2) == "0°")
        // A world angle of 180° displays as 90° (180 - 90).
        #expect(CoordinateFormatter.angle(.pi, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2) == "90°")
        // World 0° with base 90° wraps to 270° (0 - 90 normalized into [0,2π)).
        #expect(CoordinateFormatter.angle(0, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2) == "270°")
    }

    @Test("angleBase works with a non-orthogonal base (45°)")
    func angleBaseFortyFive() {
        // base = 45°, world = 90° ⇒ displays 45°.
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 4) == "45°")
    }

    // MARK: - $ANGDIR (clockwise) negates direction

    @Test("clockwise negates the direction of increasing angle")
    func clockwiseNegates() {
        // CW with base 0: world 90° displays as (0 - 90) → 270°.
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 0,
                                          clockwise: true) == "270°")
        // CW: world 270° displays as (0 - 270) → 90°.
        #expect(CoordinateFormatter.angle(3 * .pi / 2, format: .degreesDecimal, precision: 0,
                                          clockwise: true) == "90°")
        // Zero is unchanged under pure CW (0 → 0).
        #expect(CoordinateFormatter.angle(0, format: .degreesDecimal, precision: 0,
                                          clockwise: true) == "0°")
        // 180° is its own CW reflection.
        #expect(CoordinateFormatter.angle(.pi, format: .degreesDecimal, precision: 0,
                                          clockwise: true) == "180°")
    }

    // MARK: - Combined base + direction

    @Test("combined angleBase and clockwise apply (angleBase - radians)")
    func combinedBaseAndClockwise() {
        // CW with base 90°: world 0° displays as (90 - 0) → 90°.
        #expect(CoordinateFormatter.angle(0, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2, clockwise: true) == "90°")
        // CW with base 90°: world 90° displays as (90 - 90) → 0°.
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2, clockwise: true) == "0°")
        // CW with base 90°: world 180° displays as (90 - 180) → -90 → 270°.
        #expect(CoordinateFormatter.angle(.pi, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2, clockwise: true) == "270°")
    }

    // MARK: - Normalization across ±2π with a basis applied

    @Test("the displayed angle is normalized into [0,2π) after the basis")
    func normalizationWithBasis() {
        // World 90° + 2π full turn, base 90° ⇒ still 0°.
        #expect(CoordinateFormatter.angle(.pi / 2 + 2 * .pi, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2) == "0°")
        // A large negative world angle with a base still folds in.
        #expect(CoordinateFormatter.angle(-3 * .pi / 2, format: .degreesDecimal, precision: 0,
                                          angleBase: .pi / 2) == "0°")
        // CW with a multi-turn input normalizes the same as its principal value.
        #expect(CoordinateFormatter.angle(.pi / 2 - 4 * .pi, format: .degreesDecimal, precision: 0,
                                          clockwise: true) == "270°")
    }

    // MARK: - The basis applies across formats (gradians / DMS / surveyors)

    @Test("basis applies uniformly across angle formats")
    func basisAcrossFormats() {
        // base 90°: world 180° displays 90° ⇒ 100g in gradians.
        #expect(CoordinateFormatter.angle(.pi, format: .gradians, precision: 0,
                                          angleBase: .pi / 2) == "100g")
        // base 90°: world 180° displays 90° ⇒ "90°0'0\"" in DMS.
        #expect(CoordinateFormatter.angle(.pi, format: .degreesMinutesSeconds, precision: 4,
                                          angleBase: .pi / 2) == "90°0'0\"")
        // base 90°: world 180° displays 90° ⇒ "N" in surveyors.
        #expect(CoordinateFormatter.angle(.pi, format: .surveyors,
                                          angleBase: .pi / 2) == "N")
    }

    // MARK: - polarPair forwards the basis to its angle component

    @Test("polarPair forwards angleBase/clockwise; defaults stay identical")
    func polarPairForwardsBasis() {
        // Default basis: unchanged from the established polar output.
        #expect(CoordinateFormatter.polarPair(dx: 3, dy: 4,
                                              format: .decimal, precision: 0,
                                              angleFormat: .degreesDecimal, anglePrecision: 2) == "5<53.13°")
        // dx=0,dy=10 ⇒ θ=90°; base 90° ⇒ angle component reads 0°. Distance unaffected.
        #expect(CoordinateFormatter.polarPair(dx: 0, dy: 10,
                                              format: .decimal, precision: 0,
                                              angleFormat: .degreesDecimal, anglePrecision: 0,
                                              angleBase: .pi / 2) == "10<0°")
        // Same offset, clockwise ⇒ (0 - 90) → 270°.
        #expect(CoordinateFormatter.polarPair(dx: 0, dy: 10,
                                              format: .decimal, precision: 0,
                                              angleFormat: .degreesDecimal, anglePrecision: 0,
                                              clockwise: true) == "10<270°")
    }
}
