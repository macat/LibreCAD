//
//  CoordinateFormatter.swift
//  CADEngine
//
//  The pure, GUI-free formatter behind the persistent status bar's coordinate
//  readout (UX-plan U3, gap G6). It turns a world-space length / coordinate into a
//  user-facing string honoring the document's display settings — the drawing
//  `LinearFormat`, the linear precision (`$LUPREC`), and the unit sign
//  (`DrawingUnit.sign`) — so the status bar shows e.g. `12.5 mm` / `1'-0"` instead
//  of a raw `x %.3f`.
//
//  It is intentionally in CADEngine (NOT the SwiftUI app target) so it is
//  unit-testable as plain logic with NO GUI: a test passes a value + format +
//  precision + unit and asserts the string. The status bar (`StatusBar.swift`) is
//  a thin SwiftUI wrapper that calls these statics with the live
//  `drawing.graphicVariables` values.
//
//  The decimal path mirrors the engine's existing dimension-text formatter
//  (`DimensionResolver.dimFormat`) — round to N places, strip trailing zeros — so
//  the coordinate readout and dimension labels read consistently. The other
//  `LinearFormat` cases (scientific / engineering / architectural / fractional)
//  follow LibreCAD's `RS_Units::formatLinear` conventions.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Units formatting conventions).
//

import Foundation

/// A pure formatter for linear lengths / coordinates shown in the status bar (U3).
/// All methods are `static`; it holds no state.
public enum CoordinateFormatter {

    // MARK: - Linear length

    /// Formats a single linear `value` (world units) for display, per the document's
    /// `LinearFormat` and `precision` (decimal places, clamped 0…8). Does NOT append
    /// a unit sign — use `length(_:format:precision:unit:)` for the signed form, or
    /// `coordinatePair` for an `X / Y` readout.
    ///
    /// - Decimal: fixed precision, trailing zeros stripped (`10.0 → "10"`,
    ///   `12.500 → "12.5"`). Matches `DimensionResolver.dimFormat`.
    /// - Scientific: `%.Ne` (`12345 → "1.2e+04"` at precision 1).
    /// - Engineering / Architectural / Fractional: feet-inches / fractional-inch
    ///   forms (LibreCAD `RS_Units::formatLinear`), treating the value as inches.
    public static func length(_ value: Double,
                              format: LinearFormat = .decimal,
                              precision: Int = 4) -> String {
        let p = clampPrecision(precision)
        // Normalize a negative zero so "-0" never shows.
        let v = value == 0 ? 0 : value
        switch format {
        case .decimal:
            return decimal(v, precision: p)
        case .scientific:
            return scientific(v, precision: p)
        case .engineering:
            return engineering(v, precision: p)
        case .architectural, .architecturalMetric:
            return architectural(v, precision: p)
        case .fractional:
            return fractional(v, precision: p)
        }
    }

    /// Formats a linear `value` and appends the unit sign (e.g. `"12.5 mm"`,
    /// `"3\""`). When the unit has no sign (`.none`) the bare number is returned.
    /// The feet-inch formats (`engineering`/`architectural`) already carry their own
    /// `'`/`"` marks, so no extra sign is appended for those.
    public static func length(_ value: Double,
                              format: LinearFormat,
                              precision: Int,
                              unit: DrawingUnit) -> String {
        let body = length(value, format: format, precision: precision)
        // The feet-inch formats embed their own marks; appending a unit sign would
        // double up (e.g. `1'-0" mm`). Decimal/scientific/fractional get the sign.
        switch format {
        case .engineering, .architectural, .architecturalMetric:
            return body
        case .decimal, .scientific, .fractional:
            let sign = unit.sign
            return sign.isEmpty ? body : "\(body) \(sign)"
        }
    }

    // MARK: - Coordinate pair (the status-bar X / Y readout)

    /// Formats an `(x, y)` world point as a compact `"X 12.5  Y 8  mm"`-style readout
    /// for the status bar — each component via `length`, the unit sign appended once
    /// at the end (so the pair reads cleanly). Used for both the absolute cursor
    /// position and (with a `Δ`/`@` label) the relative offset.
    public static func coordinatePair(x: Double, y: Double,
                                      format: LinearFormat = .decimal,
                                      precision: Int = 4,
                                      unit: DrawingUnit = .none) -> String {
        let xs = length(x, format: format, precision: precision)
        let ys = length(y, format: format, precision: precision)
        let sign = unit.sign
        let core = "X \(xs)   Y \(ys)"
        // Only decimal/scientific/fractional take a trailing sign (feet-inch carries
        // its own marks per `length`); append once after the pair.
        switch format {
        case .engineering, .architectural, .architecturalMetric:
            return core
        case .decimal, .scientific, .fractional:
            return sign.isEmpty ? core : "\(core) \(sign)"
        }
    }

    // MARK: - Decimal (mirrors DimensionResolver.dimFormat)

    /// Rounds to `precision` decimal places and strips trailing zeros: `10.0 → "10"`,
    /// `12.500 → "12.5"`. The same logic as the dimension-label formatter so the
    /// status bar and dimension text agree.
    static func decimal(_ value: Double, precision: Int) -> String {
        let p = clampPrecision(precision)
        let factor = pow(10.0, Double(p))
        let rounded = (value * factor).rounded() / factor
        // Whole number within half-a-tick? Show the integer (no ".0").
        if abs(rounded - rounded.rounded()) < (0.5 / factor) {
            return String(Int(rounded.rounded()))
        }
        var s = String(format: "%.\(p)f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Scientific

    /// `%.Ne` scientific notation at `precision` mantissa digits.
    static func scientific(_ value: Double, precision: Int) -> String {
        String(format: "%.\(clampPrecision(precision))e", value)
    }

    // MARK: - Engineering (feet + decimal inches: 1'-0.5")

    /// Treats `value` as INCHES (LibreCAD's convention for the imperial formats) and
    /// renders feet plus decimal inches: `13.5 → "1'-1.5\""`. The sign is carried on
    /// the feet term; a zero is `0\"`.
    static func engineering(_ value: Double, precision: Int) -> String {
        let p = clampPrecision(precision)
        let negative = value < 0
        let totalInches = abs(value)
        let feet = Int(totalInches / 12)
        let inches = totalInches - Double(feet) * 12
        let inchStr = decimal(inches, precision: p)
        let body: String
        if feet > 0 {
            body = "\(feet)'-\(inchStr)\""
        } else {
            body = "\(inchStr)\""
        }
        return negative ? "-\(body)" : body
    }

    // MARK: - Architectural (feet + fractional inches: 1'-0 1/2")

    /// Feet plus fractional inches (`value` in inches): `13.5 → "1'-1 1/2\""`. The
    /// fractional inch denominator is 2^precision (clamped to a sane range), matching
    /// LibreCAD's architectural format.
    static func architectural(_ value: Double, precision: Int) -> String {
        let negative = value < 0
        let totalInches = abs(value)
        let feet = Int(totalInches / 12)
        let remInches = totalInches - Double(feet) * 12
        let inchStr = fractionalInch(remInches, precision: precision)
        let body: String
        if feet > 0 {
            body = "\(feet)'-\(inchStr)\""
        } else {
            body = "\(inchStr)\""
        }
        return negative ? "-\(body)" : body
    }

    // MARK: - Fractional (plain fractional inches: 13 1/2)

    /// Fractional inches with NO feet roll-up (`value` in inches): `13.5 → "13 1/2"`.
    static func fractional(_ value: Double, precision: Int) -> String {
        let negative = value < 0
        let s = fractionalInch(abs(value), precision: precision)
        return negative ? "-\(s)" : s
    }

    /// Renders a non-negative inch quantity as `whole num/den` with the denominator
    /// 2^precision (clamped 1…64) — e.g. `1.5 → "1 1/2"`, `2.0 → "2"`, `0.25 → "1/4"`.
    /// Reduces the fraction to lowest terms.
    static func fractionalInch(_ value: Double, precision: Int) -> String {
        // Denominator is a power of two; precision 0 ⇒ whole inches, capped at 1/64.
        let den = Int(pow(2.0, Double(clampPower(precision))))
        let whole = Int(value)
        var numer = Int((value - Double(whole)) * Double(den) + 0.5)
        var d = den
        if numer >= d {           // rounding bumped the whole number up
            return String(whole + 1)
        }
        guard numer > 0 else { return String(whole) }
        // Reduce numer/d to lowest terms.
        let g = gcd(numer, d)
        numer /= g
        d /= g
        return whole > 0 ? "\(whole) \(numer)/\(d)" : "\(numer)/\(d)"
    }

    // MARK: - Helpers

    private static func clampPrecision(_ p: Int) -> Int { Swift.max(0, Swift.min(8, p)) }
    /// Fractional-inch power-of-two exponent: 0…6 ⇒ denominators 1…64.
    private static func clampPower(_ p: Int) -> Int { Swift.max(0, Swift.min(6, p)) }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x == 0 ? 1 : x
    }
}
