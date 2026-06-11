//
//  AngleTests.swift
//  CADEngineTests
//
//  The [0, 2π) half-open boundary contract for angle normalization
//  (RS_Math::correctAngle port) — review nice-to-have. An angle of exactly 2π
//  must wrap to 0, not stay at 2π.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

private let tol = 1e-12

@Suite("Angle [0, 2pi) half-open boundary")
struct AngleTests {

    @Test("correctAngle keeps results in [0, 2pi)")
    func rangeIsHalfOpen() {
        let twoPi = 2 * Double.pi
        // Sample a dense sweep including the boundaries.
        for k in -8...8 {
            for frac in stride(from: 0.0, through: 1.0, by: 0.125) {
                let raw = Double(k) * twoPi + frac * twoPi
                let a = Vector.correctAngle(raw)
                #expect(a >= 0)
                #expect(a < twoPi)
            }
        }
    }

    @Test("exactly 2pi wraps to 0 (upper bound is exclusive)")
    func twoPiWrapsToZero() {
        let twoPi = 2 * Double.pi
        let a = Vector.correctAngle(twoPi)
        #expect(a >= 0)
        #expect(a < twoPi)
        // It should be ~0, not ~2pi.
        #expect(abs(a) < 1e-9)
    }

    @Test("exactly 0 stays 0 (lower bound is inclusive)")
    func zeroStaysZero() {
        #expect(abs(Vector.correctAngle(0)) < tol)
    }

    @Test("negative angles wrap into [0, 2pi)")
    func negativeWraps() {
        let twoPi = 2 * Double.pi
        #expect(abs(Vector.correctAngle(-Double.pi / 2) - 3 * Double.pi / 2) < 1e-9)
        let a = Vector.correctAngle(-twoPi)
        #expect(a >= 0 && a < twoPi)
        #expect(abs(a) < 1e-9)
    }

    @Test("Vector.angle of pointing-down is ~3pi/2, never negative")
    func downwardAngle() {
        let down = Vector(0, -1).angle
        #expect(down >= 0)
        #expect(abs(down - 3 * Double.pi / 2) < 1e-9)
    }
}
