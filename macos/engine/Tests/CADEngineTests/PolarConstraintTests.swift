//
//  PolarConstraintTests.swift
//  CADEngineTests
//
//  Unit tests for the pure polar (angle-increment) point constraint -- the kernel
//  the app's canvas (CanvasModel.polarConstrained / CADCanvasView) calls on the
//  point-input path while a draw tool is active. The constraint locks the
//  candidate point onto the ray from the reference (last) point at the NEAREST
//  multiple of a fixed angular increment, preserving the reference→point distance.
//
//  Asserts: increments of 90°/45°/15° snap to the nearest allowed angle, points
//  near a quadrant/diagonal boundary snap to the expected angle, the distance from
//  the reference is preserved, the four-axis (90°) case agrees with the ortho
//  family, and degenerate inputs (coincident point, non-positive increment,
//  invalid points) pass through unchanged.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CADEngine polar-constraint kernel")
struct PolarConstraintTests {

    private let eps = 1e-9
    private let deg90 = Double.pi / 2
    private let deg45 = Double.pi / 4
    private let deg15 = Double.pi / 12

    // MARK: - Helpers

    /// Distance of a point from the reference.
    private func dist(_ p: Vector, from ref: Vector) -> Double {
        ((p.x - ref.x) * (p.x - ref.x) + (p.y - ref.y) * (p.y - ref.y)).squareRoot()
    }

    /// Angle (radians) of the reference→point ray, in (-π, π].
    private func angle(_ p: Vector, from ref: Vector) -> Double {
        atan2(p.y - ref.y, p.x - ref.x)
    }

    // MARK: - 90° increment (ortho family)

    @Test("90° increment: a near-horizontal point snaps to the horizontal ray, distance preserved")
    func ninetyDegSnapsToHorizontal() {
        let ref = Vector(10, 5)
        let raw = Vector(30, 8)        // angle ~8.5° -> nearest 0°
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg90)
        #expect(abs(angle(out, from: ref) - 0) < eps)              // 0° ray
        #expect(abs(out.y - 5) < eps)                              // on reference row
        #expect(abs(dist(out, from: ref) - dist(raw, from: ref)) < eps)  // distance kept
    }

    @Test("90° increment: a near-vertical point snaps to the +90° ray (distance preserved)")
    func ninetyDegSnapsToVertical() {
        let ref = Vector(0, 0)
        let raw = Vector(3, 40)        // angle ~85.7° -> nearest 90°
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg90)
        #expect(abs(angle(out, from: ref) - deg90) < eps)
        #expect(abs(out.x - 0) < eps)                              // on reference column
        #expect(abs(dist(out, from: ref) - dist(raw, from: ref)) < eps)
    }

    @Test("90° increment: a down-left point snaps to the -90° ray")
    func ninetyDegNegativeVertical() {
        let ref = Vector(0, 0)
        let raw = Vector(-2, -9)       // angle ~ -102.5° -> nearest -90°
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg90)
        #expect(abs(angle(out, from: ref) - (-deg90)) < eps)
        #expect(abs(out.x - 0) < eps)
        #expect(abs(dist(out, from: ref) - dist(raw, from: ref)) < eps)
    }

    // MARK: - 45° increment

    @Test("45° increment: a point near the diagonal snaps to exactly 45°")
    func fortyFiveDegDiagonal() {
        let ref = Vector(0, 0)
        let raw = Vector(10, 11)       // angle ~47.7° -> nearest 45°
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg45)
        #expect(abs(angle(out, from: ref) - deg45) < eps)
        #expect(abs(out.x - out.y) < eps)                         // 45° => x == y
        #expect(abs(dist(out, from: ref) - dist(raw, from: ref)) < eps)
    }

    @Test("45° increment: a point just past 22.5° snaps up to 45°, just under snaps to 0°")
    func fortyFiveDegBoundary() {
        let ref = Vector(2, 2)
        let d = 10.0
        // Just above the 22.5° midpoint -> 45°.
        let above = Vector(ref.x + d * cos(deg45 * 0.6), ref.y + d * sin(deg45 * 0.6))
        let outAbove = PolarConstraint.constrain(above, relativeTo: ref, incrementRadians: deg45)
        #expect(abs(angle(outAbove, from: ref) - deg45) < eps)
        // Just below the 22.5° midpoint -> 0°.
        let below = Vector(ref.x + d * cos(deg45 * 0.4), ref.y + d * sin(deg45 * 0.4))
        let outBelow = PolarConstraint.constrain(below, relativeTo: ref, incrementRadians: deg45)
        #expect(abs(angle(outBelow, from: ref) - 0) < eps)
    }

    // MARK: - 15° increment

    @Test("15° increment: a point near 30° snaps to exactly 30°, distance preserved")
    func fifteenDegSnapsToThirty() {
        let ref = Vector(5, 5)
        let target = deg15 * 2        // 30°
        let d = 7.0
        let raw = Vector(ref.x + d * cos(target + 0.03), ref.y + d * sin(target + 0.03))
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg15)
        #expect(abs(angle(out, from: ref) - target) < eps)
        #expect(abs(dist(out, from: ref) - d) < eps)              // distance preserved
    }

    @Test("15° increment: each placed angle lands exactly on its multiple")
    func fifteenDegAllMultiples() {
        let ref = Vector(0, 0)
        let d = 12.0
        for k in -12...12 {
            let exact = Double(k) * deg15
            // Perturb slightly so we exercise the rounding, not a no-op.
            let perturbed = exact + deg15 * 0.2
            let raw = Vector(d * cos(perturbed), d * sin(perturbed))
            let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg15)
            // Compare unit directions (angles wrap at ±π; direction does not).
            let cs = cos(angle(out, from: ref))
            let sn = sin(angle(out, from: ref))
            #expect(abs(cs - cos(exact)) < eps)
            #expect(abs(sn - sin(exact)) < eps)
            #expect(abs(dist(out, from: ref) - d) < eps)
        }
    }

    // MARK: - Distance preservation (general)

    @Test("distance from the reference is always preserved by the snap")
    func distancePreserved() {
        let ref = Vector(-3, 7)
        let raw = Vector(20, -4)
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg15)
        #expect(abs(dist(out, from: ref) - dist(raw, from: ref)) < eps)
    }

    @Test("z is passed through from the candidate point")
    func zPassThrough() {
        let ref = Vector(0, 0, 0)
        let raw = Vector(10, 1, 4.5)   // snaps toward 0° but keeps z
        let out = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: deg45)
        #expect(abs(out.z - 4.5) < eps)
    }

    // MARK: - Degenerate inputs

    @Test("coincident point (zero offset) is returned unchanged")
    func coincidentPassThrough() {
        let ref = Vector(3, 3)
        let out = PolarConstraint.constrain(ref, relativeTo: ref, incrementRadians: deg15)
        #expect(abs(out.x - 3) < eps)
        #expect(abs(out.y - 3) < eps)
    }

    @Test("non-positive increment is returned unchanged (no manufactured coordinate)")
    func nonPositiveIncrementPassThrough() {
        let ref = Vector(0, 0)
        let raw = Vector(5, 9)
        let zero = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: 0)
        #expect(zero.x == 5 && zero.y == 9)
        let negative = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: -deg15)
        #expect(negative.x == 5 && negative.y == 9)
        let nan = PolarConstraint.constrain(raw, relativeTo: ref, incrementRadians: .nan)
        #expect(nan.x == 5 && nan.y == 9)
    }

    @Test("invalid inputs pass through unchanged (no manufactured coordinate)")
    func invalidPassThrough() {
        let ref = Vector(1, 1)
        let invalidRaw = PolarConstraint.constrain(.invalid, relativeTo: ref, incrementRadians: deg15)
        #expect(!invalidRaw.valid)
        let validRaw = Vector(5, 9)
        let invalidRef = PolarConstraint.constrain(validRaw, relativeTo: .invalid, incrementRadians: deg15)
        #expect(invalidRef.x == 5 && invalidRef.y == 9)   // unchanged
    }
}
