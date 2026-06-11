//
//  MathUtils.swift
//  CADEngine
//
//  Scalar math helpers ported from LibreCAD's RS_Math
//  (librecad/src/lib/math/rs_math.{h,cpp}): angle normalization, angle
//  differences, "is angle between" tests, unit conversions, rounding, and
//  ULP-based floating-point comparison. These are the pure-scalar building
//  blocks the intersection kernels rely on.
//
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2010 R. van Twisk; Copyright (C) 2001-2003 RibbonSoft.
//  Copyright (C) Dongxu Li (original RS_Math implementation).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// Additional tolerance constants used by the polynomial solvers, ported from
/// LibreCAD's `rs.h`. (The base `Tolerance` enum lives in `Geometry.swift`,
/// owned by the foundation; these are the solver-only extras.)
public extension Tolerance {
    /// `RS_TOLERANCE15` — a coarse 1.5e-15 tolerance used as a "near zero" guard
    /// inside the quartic/simultaneous-quadratic solvers.
    static let distance15 = 1.5e-15
}

/// Pure scalar math utilities, a faithful Swift port of LibreCAD's `RS_Math`
/// namespace. The engine is f64 throughout (ADR-003), so these mirror the C++
/// kernel value-for-value.
///
/// Angle normalization (`correctAngle`) already lives on `Vector`; the variants
/// and the angle-relationship predicates that the intersection kernels need
/// (`getAngleDifference`, `isAngleBetween`, …) are gathered here.
public enum MathUtils {

    /// 2π, the angular period.
    @usableFromInline static let twoPi = 2.0 * Double.pi

    // MARK: - Angle normalization (RS_Math::correctAngle family)

    /// Maps an angle into `[0, 2π)`, mirroring `RS_Math::correctAngle`.
    /// Re-exported here so the kernels can stay inside `MathUtils`; identical to
    /// `Vector.correctAngle`.
    @inlinable
    public static func correctAngle(_ a: Double) -> Double {
        Vector.correctAngle(a)
    }

    /// Maps an angle into `[-π, +π)`, mirroring `RS_Math::correctAnglePlusMinusPi`
    /// (`std::remainder(a, 2π)`).
    @inlinable
    public static func correctAnglePlusMinusPi(_ a: Double) -> Double {
        a.remainder(dividingBy: twoPi)
    }

    /// Returns the angle as an unsigned value in `[0, π]`,
    /// mirroring `RS_Math::correctAngle0ToPi` (`|std::remainder(a, 2π)|`).
    @inlinable
    public static func correctAngle0ToPi(_ a: Double) -> Double {
        abs(a.remainder(dividingBy: twoPi))
    }

    // MARK: - Angle differences (RS_Math::getAngleDifference family)

    /// The angle that must be added to `a1` to reach `a2`. Always in `[0, 2π)`.
    /// Mirrors `RS_Math::getAngleDifference` (`reversed` swaps the operands so
    /// the difference is measured clockwise).
    @inlinable
    public static func getAngleDifference(_ a1: Double, _ a2: Double, reversed: Bool = false) -> Double {
        let (x, y) = reversed ? (a2, a1) : (a1, a2)
        return correctAngle(y - x)
    }

    /// The minimum unsigned angular difference in `[0, π]`,
    /// mirroring `RS_Math::getAngleDifferenceU`.
    @inlinable
    public static func getAngleDifferenceU(_ a1: Double, _ a2: Double) -> Double {
        correctAngle0ToPi(a1 - a2)
    }

    /// Tests whether angle `a` lies between `a1` and `a2`.
    ///
    /// All angles in radians. `reversed == true` tests the clockwise sweep
    /// (matching LibreCAD's reversed arcs). Faithful port of
    /// `RS_Math::isAngleBetween`.
    @inlinable
    public static func isAngleBetween(_ a: Double, _ a1: Double, _ a2: Double, reversed: Bool = false) -> Bool {
        var lo = a1
        var hi = a2
        if reversed { swap(&lo, &hi) }

        if getAngleDifferenceU(hi, lo) < Tolerance.angle {
            return true
        }
        let tol = 0.5 * Tolerance.angle
        let diff0 = correctAngle(hi - lo) + tol
        return diff0 >= correctAngle(a - lo) || diff0 >= correctAngle(hi - a)
    }

    /// `true` if two direction angles point the same way to within `tol` (rad),
    /// mirroring `RS_Math::isSameDirection`.
    @inlinable
    public static func isSameDirection(_ dir1: Double, _ dir2: Double, _ tol: Double) -> Bool {
        getAngleDifferenceU(dir1, dir2) < tol
    }

    /// Number of full periods between two angles, mirroring
    /// `RS_Math::getPeriodsCount` — 0 when the angles are the same or
    /// non-periodic, otherwise the count of `2π` periods.
    @inlinable
    public static func getPeriodsCount(_ a1: Double, _ a2: Double, reversed: Bool) -> Int {
        var x = a1
        var y = a2
        if reversed { swap(&x, &y) }
        let dif = abs(y - x) + twoPi
        let rem = dif.remainder(dividingBy: twoPi)
        if rem < Tolerance.angle {
            return Int(dif / twoPi) - 1
        }
        return 0
    }

    // MARK: - Unit conversion (RS_Math::rad2deg family)

    /// Radians → degrees (`RS_Math::rad2deg`).
    @inlinable public static func rad2deg(_ a: Double) -> Double { 180.0 / Double.pi * a }
    /// Degrees → radians (`RS_Math::deg2rad`).
    @inlinable public static func deg2rad(_ a: Double) -> Double { Double.pi / 180.0 * a }
    /// Radians → gradians (`RS_Math::rad2gra`).
    @inlinable public static func rad2gra(_ a: Double) -> Double { 200.0 / Double.pi * a }
    /// Gradians → radians (`RS_Math::gra2rad`).
    @inlinable public static func gra2rad(_ a: Double) -> Double { Double.pi / 200.0 * a }
    /// Gradians → degrees (`RS_Math::gra2deg`).
    @inlinable public static func gra2deg(_ a: Double) -> Double { 180.0 / 200.0 * a }

    // MARK: - Rounding (RS_Math::round)

    /// Rounds to the closest integer (`RS_Math::round(double)`), banker-free
    /// round-half-away-from-zero via `lrint`-equivalent `rounded(.toNearestOrAwayFromZero)`.
    @inlinable
    public static func round(_ v: Double) -> Int {
        Int(v.rounded(.toNearestOrAwayFromZero))
    }

    /// Rounds `v` to a multiple of `precision` (`RS_Math::round(double, double)`).
    /// Falls back to `v` when `precision` is effectively zero.
    @inlinable
    public static func round(_ v: Double, precision: Double) -> Double {
        abs(precision) > Tolerance.distanceSquared
            ? precision * Double((v / precision).rounded(.toNearestOrAwayFromZero))
            : v
    }

    // MARK: - ULP-based comparison (RS_Math::equal / less / inBetween)

    /// Unit-in-the-last-place of `x` (`RS_Math::ulp`): the spacing to the next
    /// representable double in the direction away from zero.
    @inlinable
    public static func ulp(_ x: Double) -> Double {
        if x.sign == .minus {
            return x - x.nextDown
        } else {
            return x.nextUp - x
        }
    }

    /// `true` if two doubles are equal within `max(2·ulp(d1), 2·ulp(d2), tolerance)`,
    /// mirroring `RS_Math::equal`.
    @inlinable
    public static func equal(_ d1: Double, _ d2: Double, tolerance: Double = 0.0) -> Bool {
        abs(d1 - d2) <= Swift.max(2.0 * ulp(d1), 2.0 * ulp(d2), tolerance)
    }

    /// Negation of ``equal(_:_:tolerance:)`` (`RS_Math::notEqual`).
    @inlinable
    public static func notEqual(_ d1: Double, _ d2: Double, tolerance: Double = 0.0) -> Bool {
        !equal(d1, d2, tolerance: tolerance)
    }

    /// `true` if `a <= b + 2·ulp(b)` (`RS_Math::less`).
    @inlinable
    public static func less(_ a: Double, _ b: Double) -> Bool {
        a <= b + 2.0 * ulp(b)
    }

    /// `true` if `x` lies between `a` and `b` (in either order), using ULP as
    /// tolerance (`RS_Math::inBetween`).
    @inlinable
    public static func inBetween(_ x: Double, _ a: Double, _ b: Double) -> Bool {
        less(x, Swift.max(a, b)) && less(Swift.min(a, b), x)
    }
}
