//
//  CoordinateDisplayModeTests.swift
//  CADEngineTests
//
//  Covers the backlog-#5 foundation (Phase 0, P0-A): the `CoordinateDisplayMode`
//  cycle and the new angle / polar formatters added to `CoordinateFormatter`.
//  Pure CADEngine logic — no GUI, no app module.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CoordinateDisplayMode cycle")
struct CoordinateDisplayModeCycleTests_Backlog5 {

    @Test("next cycles absolute → relative → polar → absolute")
    func nextCyclesAbsoluteRelativePolarAbsolute() {
        #expect(CoordinateDisplayMode.absolute.next == .relative)
        #expect(CoordinateDisplayMode.relative.next == .polar)
        #expect(CoordinateDisplayMode.polar.next == .absolute)
    }

    @Test("three .next steps return to the start")
    func nextThreeStepsReturnToStart() {
        var mode = CoordinateDisplayMode.absolute
        mode = mode.next.next.next
        #expect(mode == .absolute)
    }

    @Test("allCases is the full ordered set with stable raw values")
    func allCasesPresentAndRawValues() {
        #expect(CoordinateDisplayMode.allCases == [.absolute, .relative, .polar])
        #expect(CoordinateDisplayMode.absolute.rawValue == "absolute")
        #expect(CoordinateDisplayMode.relative.rawValue == "relative")
        #expect(CoordinateDisplayMode.polar.rawValue == "polar")
        // Round-trips through the raw value (used for persistence).
        #expect(CoordinateDisplayMode(rawValue: "polar") == .polar)
    }
}

@Suite("CoordinateFormatter.angle")
struct CoordinateFormatterAngleTests_Backlog5 {

    // MARK: - Degrees decimal

    @Test("degrees decimal: quarter turn is 90°")
    func degreesDecimalQuarterTurn() {
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 2) == "90°")
    }

    @Test("degrees decimal strips trailing zeros (45°)")
    func degreesDecimalStripsTrailingZeros() {
        #expect(CoordinateFormatter.angle(.pi / 4, format: .degreesDecimal, precision: 4) == "45°")
    }

    @Test("degrees decimal: atan2(4,3) ≈ 53.13°")
    func degreesDecimalFractional() {
        #expect(CoordinateFormatter.angle(atan2(4.0, 3.0), format: .degreesDecimal, precision: 2) == "53.13°")
    }

    @Test("a negative angle normalizes into [0, 2π) (−90° → 270°)")
    func normalizesNegativeIntoZeroTwoPi() {
        #expect(CoordinateFormatter.angle(-.pi / 2, format: .degreesDecimal, precision: 0) == "270°")
    }

    @Test("a multi-turn angle normalizes (2π + π/2 → 90°)")
    func normalizesMultiTurn() {
        #expect(CoordinateFormatter.angle(2 * .pi + .pi / 2, format: .degreesDecimal, precision: 0) == "90°")
    }

    // MARK: - Radians / gradians

    @Test("radians: π → 3.1416r")
    func radians() {
        #expect(CoordinateFormatter.angle(.pi, format: .radians, precision: 4) == "3.1416r")
    }

    @Test("gradians: π/2 → 100g")
    func gradiansQuarterTurn() {
        #expect(CoordinateFormatter.angle(.pi / 2, format: .gradians, precision: 2) == "100g")
    }

    // MARK: - Degrees / minutes / seconds

    @Test("DMS: whole degree (90°0'0\")")
    func dmsWholeDegree() {
        #expect(CoordinateFormatter.angle(.pi / 2, format: .degreesMinutesSeconds, precision: 4) == "90°0'0\"")
    }

    @Test("DMS: half degree (0°30'0\")")
    func dmsHalfDegree() {
        #expect(CoordinateFormatter.angle(MathUtils.deg2rad(0.5), format: .degreesMinutesSeconds, precision: 4) == "0°30'0\"")
    }

    @Test("DMS: minutes + seconds (10°15'30\")")
    func dmsMinutesSeconds() {
        let deg = 10.0 + 15.0 / 60.0 + 30.0 / 3600.0
        #expect(CoordinateFormatter.angle(MathUtils.deg2rad(deg), format: .degreesMinutesSeconds, precision: 4) == "10°15'30\"")
    }

    // MARK: - Surveyor's bearings

    @Test("surveyor cardinals collapse to a single letter")
    func surveyorCardinalsCollapse() {
        #expect(CoordinateFormatter.angle(0, format: .surveyors) == "E")
        #expect(CoordinateFormatter.angle(.pi / 2, format: .surveyors) == "N")
        #expect(CoordinateFormatter.angle(.pi, format: .surveyors) == "W")
        #expect(CoordinateFormatter.angle(3 * .pi / 2, format: .surveyors) == "S")
    }

    @Test("surveyor NE quadrant: 45° → N 45°0'0\" E")
    func surveyorNEQuadrant() {
        #expect(CoordinateFormatter.angle(.pi / 4, format: .surveyors) == "N 45°0'0\" E")
    }

    @Test("surveyor NW quadrant: 135° → N 45°0'0\" W")
    func surveyorNWQuadrant() {
        #expect(CoordinateFormatter.angle(3 * .pi / 4, format: .surveyors) == "N 45°0'0\" W")
    }

    @Test("surveyor SW quadrant: 225° → S 45°0'0\" W")
    func surveyorSWQuadrant() {
        #expect(CoordinateFormatter.angle(5 * .pi / 4, format: .surveyors) == "S 45°0'0\" W")
    }

    @Test("surveyor SE quadrant: 315° → S 45°0'0\" E")
    func surveyorSEQuadrant() {
        #expect(CoordinateFormatter.angle(7 * .pi / 4, format: .surveyors) == "S 45°0'0\" E")
    }
}

@Suite("CoordinateFormatter abs/rel/polar pairs (backlog #5)")
struct CoordinateFormatterPolarPairTests_Backlog5 {

    // MARK: - Absolute / relative (reuse coordinatePair)

    @Test("absolute pair: decimal, no unit")
    func absolutePairDecimalNoUnit() {
        #expect(CoordinateFormatter.coordinatePair(x: 12.5, y: 8, format: .decimal, precision: 4) == "X 12.5   Y 8")
    }

    @Test("relative pair: decimal with a unit sign")
    func relativePairDecimalWithUnit() {
        #expect(CoordinateFormatter.coordinatePair(x: 3, y: 4, format: .decimal, precision: 4, unit: .millimeter) == "X 3   Y 4 mm")
    }

    // MARK: - Polar (dist<angle)

    @Test("polar pair: dx=3 dy=4 → 5<53.13°")
    func polarPair3_4Degrees() {
        #expect(CoordinateFormatter.polarPair(dx: 3, dy: 4,
                                              format: .decimal, precision: 2,
                                              angleFormat: .degreesDecimal, anglePrecision: 2) == "5<53.13°")
    }

    @Test("polar pair: the unit sign rides on the distance term")
    func polarPairUnitSignOnDistance() {
        #expect(CoordinateFormatter.polarPair(dx: 3, dy: 4,
                                              format: .decimal, precision: 2, unit: .millimeter,
                                              angleFormat: .degreesDecimal, anglePrecision: 2) == "5 mm<53.13°")
    }

    @Test("polar pair: pure +X offset → angle 0°")
    func polarPairAxisAligned() {
        #expect(CoordinateFormatter.polarPair(dx: 10, dy: 0,
                                              format: .decimal, precision: 4,
                                              angleFormat: .degreesDecimal, anglePrecision: 4) == "10<0°")
    }

    @Test("polar pair: negative delta normalizes the angle (5<233.13°)")
    func polarPairNegativeDeltaNormalizesAngle() {
        #expect(CoordinateFormatter.polarPair(dx: -3, dy: -4,
                                              format: .decimal, precision: 2,
                                              angleFormat: .degreesDecimal, anglePrecision: 2) == "5<233.13°")
    }

    @Test("polar pair: zero offset → 0<0°")
    func polarPairZeroOffset() {
        #expect(CoordinateFormatter.polarPair(dx: 0, dy: 0,
                                              format: .decimal, precision: 4,
                                              angleFormat: .degreesDecimal, anglePrecision: 4) == "0<0°")
    }
}
