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

import XCTest
@testable import CADEngine

final class CoordinateDisplayModeTests: XCTestCase {

    // MARK: - CoordinateDisplayMode.next cycle

    func testNextCyclesAbsoluteRelativePolarAbsolute() {
        XCTAssertEqual(CoordinateDisplayMode.absolute.next, .relative)
        XCTAssertEqual(CoordinateDisplayMode.relative.next, .polar)
        XCTAssertEqual(CoordinateDisplayMode.polar.next, .absolute)
    }

    func testNextThreeStepsReturnToStart() {
        var mode = CoordinateDisplayMode.absolute
        mode = mode.next.next.next
        XCTAssertEqual(mode, .absolute)
    }

    func testAllCasesPresentAndRawValues() {
        XCTAssertEqual(CoordinateDisplayMode.allCases,
                       [.absolute, .relative, .polar])
        XCTAssertEqual(CoordinateDisplayMode.absolute.rawValue, "absolute")
        XCTAssertEqual(CoordinateDisplayMode.relative.rawValue, "relative")
        XCTAssertEqual(CoordinateDisplayMode.polar.rawValue, "polar")
        // Round-trips through the raw value (used for persistence).
        XCTAssertEqual(CoordinateDisplayMode(rawValue: "polar"), .polar)
    }

    // MARK: - Angle formatter — degrees decimal

    func testAngleDegreesDecimalQuarterTurn() {
        XCTAssertEqual(
            CoordinateFormatter.angle(.pi / 2, format: .degreesDecimal, precision: 2),
            "90°")
    }

    func testAngleDegreesDecimalStripsTrailingZeros() {
        // 45° exactly — trailing zeros stripped (mirrors `length`).
        XCTAssertEqual(
            CoordinateFormatter.angle(.pi / 4, format: .degreesDecimal, precision: 4),
            "45°")
    }

    func testAngleDegreesDecimalFractional() {
        // atan2(4,3) ≈ 53.13010235°.
        XCTAssertEqual(
            CoordinateFormatter.angle(atan2(4.0, 3.0), format: .degreesDecimal, precision: 2),
            "53.13°")
    }

    func testAngleNormalizesNegativeIntoZeroTwoPi() {
        // -90° normalizes to 270°.
        XCTAssertEqual(
            CoordinateFormatter.angle(-.pi / 2, format: .degreesDecimal, precision: 0),
            "270°")
    }

    func testAngleNormalizesMultiTurn() {
        // 2π + π/2 → 90°.
        XCTAssertEqual(
            CoordinateFormatter.angle(2 * .pi + .pi / 2, format: .degreesDecimal, precision: 0),
            "90°")
    }

    // MARK: - Angle formatter — radians / gradians

    func testAngleRadians() {
        XCTAssertEqual(
            CoordinateFormatter.angle(.pi, format: .radians, precision: 4),
            "3.1416r")
    }

    func testAngleGradiansQuarterTurn() {
        // π/2 rad == 100 gradians.
        XCTAssertEqual(
            CoordinateFormatter.angle(.pi / 2, format: .gradians, precision: 2),
            "100g")
    }

    // MARK: - Angle formatter — degrees/minutes/seconds

    func testAngleDMSWholeDegree() {
        XCTAssertEqual(
            CoordinateFormatter.angle(.pi / 2, format: .degreesMinutesSeconds, precision: 4),
            "90°0'0\"")
    }

    func testAngleDMSHalfDegree() {
        // 0.5° == 0°30'0".
        XCTAssertEqual(
            CoordinateFormatter.angle(MathUtils.deg2rad(0.5), format: .degreesMinutesSeconds, precision: 4),
            "0°30'0\"")
    }

    func testAngleDMSMinutesSeconds() {
        // 10°15'30".
        let deg = 10.0 + 15.0 / 60.0 + 30.0 / 3600.0
        XCTAssertEqual(
            CoordinateFormatter.angle(MathUtils.deg2rad(deg), format: .degreesMinutesSeconds, precision: 4),
            "10°15'30\"")
    }

    // MARK: - Angle formatter — surveyor's bearings

    func testSurveyorCardinalsCollapse() {
        XCTAssertEqual(CoordinateFormatter.angle(0, format: .surveyors), "E")
        XCTAssertEqual(CoordinateFormatter.angle(.pi / 2, format: .surveyors), "N")
        XCTAssertEqual(CoordinateFormatter.angle(.pi, format: .surveyors), "W")
        XCTAssertEqual(CoordinateFormatter.angle(3 * .pi / 2, format: .surveyors), "S")
    }

    func testSurveyorNEQuadrant() {
        // 45° heading (CCW from east) → N 45° E.
        XCTAssertEqual(
            CoordinateFormatter.angle(.pi / 4, format: .surveyors),
            "N 45°0'0\" E")
    }

    func testSurveyorNWQuadrant() {
        // 135° heading → N 45° W.
        XCTAssertEqual(
            CoordinateFormatter.angle(3 * .pi / 4, format: .surveyors),
            "N 45°0'0\" W")
    }

    func testSurveyorSWQuadrant() {
        // 225° heading → S 45° W.
        XCTAssertEqual(
            CoordinateFormatter.angle(5 * .pi / 4, format: .surveyors),
            "S 45°0'0\" W")
    }

    func testSurveyorSEQuadrant() {
        // 315° heading → S 45° E.
        XCTAssertEqual(
            CoordinateFormatter.angle(7 * .pi / 4, format: .surveyors),
            "S 45°0'0\" E")
    }

    // MARK: - Absolute / relative pairs (reuse coordinatePair)

    func testAbsolutePairDecimalNoUnit() {
        // Absolute readout uses coordinatePair.
        XCTAssertEqual(
            CoordinateFormatter.coordinatePair(x: 12.5, y: 8, format: .decimal, precision: 4),
            "X 12.5   Y 8")
    }

    func testRelativePairDecimalWithUnit() {
        // Relative readout is the same pair on the delta, with a unit sign.
        XCTAssertEqual(
            CoordinateFormatter.coordinatePair(x: 3, y: 4, format: .decimal, precision: 4, unit: .millimeter),
            "X 3   Y 4 mm")
    }

    // MARK: - Polar pair (dist<angle)

    func testPolarPair3_4Degrees() {
        // dx=3, dy=4 → dist 5, angle 53.13°.
        XCTAssertEqual(
            CoordinateFormatter.polarPair(dx: 3, dy: 4,
                                          format: .decimal, precision: 2,
                                          angleFormat: .degreesDecimal, anglePrecision: 2),
            "5<53.13°")
    }

    func testPolarPairUnitSignOnDistance() {
        // The unit sign rides on the distance term; the angle keeps its `°`.
        XCTAssertEqual(
            CoordinateFormatter.polarPair(dx: 3, dy: 4,
                                          format: .decimal, precision: 2, unit: .millimeter,
                                          angleFormat: .degreesDecimal, anglePrecision: 2),
            "5 mm<53.13°")
    }

    func testPolarPairAxisAligned() {
        // Pure +X offset → angle 0°, distance == dx.
        XCTAssertEqual(
            CoordinateFormatter.polarPair(dx: 10, dy: 0,
                                          format: .decimal, precision: 4,
                                          angleFormat: .degreesDecimal, anglePrecision: 4),
            "10<0°")
    }

    func testPolarPairNegativeDeltaNormalizesAngle() {
        // dx=-3, dy=-4 → dist 5, atan2 in third quadrant → normalized 233.13°.
        XCTAssertEqual(
            CoordinateFormatter.polarPair(dx: -3, dy: -4,
                                          format: .decimal, precision: 2,
                                          angleFormat: .degreesDecimal, anglePrecision: 2),
            "5<233.13°")
    }

    func testPolarPairZeroOffset() {
        // Zero offset → "0<0°" (atan2(0,0) == 0).
        XCTAssertEqual(
            CoordinateFormatter.polarPair(dx: 0, dy: 0,
                                          format: .decimal, precision: 4,
                                          angleFormat: .degreesDecimal, anglePrecision: 4),
            "0<0°")
    }
}
