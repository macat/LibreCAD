//
//  PolarTrackingTests.swift
//  CADEngineTests
//
//  Unit tests for the pure polar-TRACKING kernel (`PolarTracking.resolve`) — the
//  dotted-ray / readout layer over the polar angle lock. The kernel reports which
//  increment ray the cursor has engaged, the angle-locked point on that ray (a
//  cross-checked copy of `PolarConstraint`'s result), the reference→cursor
//  distance for the readout, whether the cursor is within ±aperture of the ray
//  (DRAW-GATING ONLY — it never changes the lock), and the dotted ray's far end.
//
//  Asserts: a cursor exactly on a 45° ray engages 45° within aperture with a
//  correct on-ray snapped point, distance, and far endpoint; a small off-ray
//  cursor is out-of-aperture yet still rounds onto the ray; default 15° increment
//  for several angles; degenerate inputs return nil; the aperture test normalizes
//  correctly across the ±180° wrap; and `snappedPoint` matches
//  `PolarConstraint.constrain` for several inputs so the drawn ray agrees with the
//  existing lock.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CADEngine polar-tracking kernel")
struct PolarTrackingKernelTests {

    private let eps = 1e-9
    private let deg90 = Double.pi / 2
    private let deg45 = Double.pi / 4
    private let deg15 = Double.pi / 12
    private let deg1 = Double.pi / 180

    // MARK: - Helpers

    private func dist(_ p: Vector, from ref: Vector) -> Double {
        ((p.x - ref.x) * (p.x - ref.x) + (p.y - ref.y) * (p.y - ref.y)).squareRoot()
    }

    /// Angle (radians) of the reference→point ray, in (-π, π].
    private func angle(_ p: Vector, from ref: Vector) -> Double {
        atan2(p.y - ref.y, p.x - ref.x)
    }

    // MARK: - Cursor exactly on a ray

    @Test("cursor exactly on the 45° ray (45° increment): engaged 45°, within aperture, on-ray point + distance + far end")
    func cursorOn45Ray() {
        let ref = Vector(10, 5)
        let d = 20.0
        // Cursor placed exactly on the 45° ray at distance d.
        let cursor = Vector(ref.x + d * cos(deg45), ref.y + d * sin(deg45))
        let aperture = deg1            // tight aperture; exact ray still inside
        let rayLen = 1000.0

        let out = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg45, apertureRadians: aperture,
            rayLengthWorld: rayLen
        )
        let r = try! #require(out)

        #expect(abs(r.engagedAngle - deg45) < eps)
        #expect(r.withinAperture)                                   // exactly on the ray
        #expect(abs(r.distance - d) < eps)                         // readout distance
        // Snapped point: on the 45° ray at distance d (x == y offset, distance kept).
        #expect(abs(angle(r.snappedPoint, from: ref) - deg45) < eps)
        #expect(abs(dist(r.snappedPoint, from: ref) - d) < eps)
        #expect(abs((r.snappedPoint.x - ref.x) - (r.snappedPoint.y - ref.y)) < eps)
        // Far endpoint: reference + polar(rayLen, 45°).
        #expect(abs(angle(r.rayFar, from: ref) - deg45) < eps)
        #expect(abs(dist(r.rayFar, from: ref) - rayLen) < eps)
    }

    // MARK: - Off-ray cursor: out of aperture but still rounds onto the ray

    @Test("cursor 1° off a ray with a tight aperture: NOT within aperture, but snappedPoint still rounds to the ray")
    func cursorJustOffRay() {
        let ref = Vector(0, 0)
        let d = 30.0
        // 1° above the 90° ray (91°). With 90° increment the nearest ray is 90°.
        let off = deg90 + deg1
        let cursor = Vector(ref.x + d * cos(off), ref.y + d * sin(off))
        let aperture = 0.5 * deg1      // half a degree: 1° off is OUTSIDE

        let out = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg90, apertureRadians: aperture,
            rayLengthWorld: 100
        )
        let r = try! #require(out)

        #expect(!r.withinAperture)                                 // 1° > 0.5° aperture
        // The lock is unaffected: snappedPoint still rounds onto the 90° ray.
        #expect(abs(r.engagedAngle - deg90) < eps)
        #expect(abs(angle(r.snappedPoint, from: ref) - deg90) < eps)
        #expect(abs(dist(r.snappedPoint, from: ref) - d) < eps)    // distance preserved
    }

    @Test("cursor just inside the aperture: within aperture true")
    func cursorJustInsideAperture() {
        let ref = Vector(4, 4)
        let d = 12.0
        // 1° off the 0° ray, aperture 2° -> inside.
        let off = deg1
        let cursor = Vector(ref.x + d * cos(off), ref.y + d * sin(off))
        let out = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg90, apertureRadians: 2 * deg1,
            rayLengthWorld: 50
        )
        let r = try! #require(out)
        #expect(abs(r.engagedAngle - 0) < eps)
        #expect(r.withinAperture)                                  // 1° < 2° aperture
    }

    // MARK: - 15° default increment, several angles

    @Test("15° increment: several cursor angles engage the nearest 15° multiple")
    func fifteenDegSeveralAngles() {
        let ref = Vector(0, 0)
        let d = 25.0
        // (rawAngleDeg, expectedRayDeg) — rounding to nearest 15°.
        let cases: [(Double, Double)] = [
            (7.0, 0.0),       // just under the 7.5° midpoint -> 0°
            (8.0, 15.0),      // just over the midpoint -> 15°
            (44.0, 45.0),     // -> 45°
            (62.0, 60.0),     // -> 60°
            (-23.0, -30.0),   // -23/15 = -1.53 -> -2 -> -30° (round-half-away)
            (-14.0, -15.0),   // -14/15 = -0.93 -> -1 -> -15°
            (97.0, 90.0),     // -> 90°
        ]
        for (rawDeg, expDeg) in cases {
            let raw = rawDeg * deg1
            let cursor = Vector(ref.x + d * cos(raw), ref.y + d * sin(raw))
            let out = PolarTracking.resolve(
                reference: ref, cursor: cursor,
                incrementRadians: deg15, apertureRadians: deg1 * 10,
                rayLengthWorld: 100
            )
            let r = try! #require(out)
            #expect(abs(r.engagedAngle - expDeg * deg1) < eps,
                    "raw \(rawDeg)° should engage \(expDeg)°, got \(r.engagedAngle / deg1)°")
        }
    }

    // MARK: - Degenerate input -> nil

    @Test("coincident reference == cursor returns nil")
    func coincidentReturnsNil() {
        let p = Vector(7, 7)
        let out = PolarTracking.resolve(
            reference: p, cursor: p,
            incrementRadians: deg15, apertureRadians: deg1, rayLengthWorld: 100
        )
        #expect(out == nil)
    }

    @Test("non-positive / non-finite increment returns nil")
    func badIncrementReturnsNil() {
        let ref = Vector(0, 0)
        let cursor = Vector(10, 3)
        #expect(PolarTracking.resolve(reference: ref, cursor: cursor,
                                      incrementRadians: 0, apertureRadians: deg1,
                                      rayLengthWorld: 100) == nil)
        #expect(PolarTracking.resolve(reference: ref, cursor: cursor,
                                      incrementRadians: -deg15, apertureRadians: deg1,
                                      rayLengthWorld: 100) == nil)
        #expect(PolarTracking.resolve(reference: ref, cursor: cursor,
                                      incrementRadians: .nan, apertureRadians: deg1,
                                      rayLengthWorld: 100) == nil)
        #expect(PolarTracking.resolve(reference: ref, cursor: cursor,
                                      incrementRadians: .infinity, apertureRadians: deg1,
                                      rayLengthWorld: 100) == nil)
    }

    @Test("invalid reference or cursor returns nil")
    func invalidPointsReturnNil() {
        let ref = Vector(0, 0)
        let cursor = Vector(10, 3)
        #expect(PolarTracking.resolve(reference: .invalid, cursor: cursor,
                                      incrementRadians: deg15, apertureRadians: deg1,
                                      rayLengthWorld: 100) == nil)
        #expect(PolarTracking.resolve(reference: ref, cursor: .invalid,
                                      incrementRadians: deg15, apertureRadians: deg1,
                                      rayLengthWorld: 100) == nil)
    }

    // MARK: - Aperture normalization across the ±180° wrap

    @Test("aperture normalizes across the ±180° wrap: a cursor near -180° engages the +180° ray within aperture")
    func apertureWrapsAcrossPi() {
        let ref = Vector(0, 0)
        let d = 15.0
        // 90° increment: rays at 0, ±90, 180/-180. A cursor at raw -179°.
        // atan2 gives ~-179° (= -3.124 rad). Nearest 90° multiple via
        // (raw/inc).rounded(): -179/90 = -1.988 -> -2 -> -180°. So engagedAngle
        // = -180° (-π) while rawAngle ~ -179°. The signed diff is ~ +1°, NOT
        // ~359°: the normalized aperture test must see them as ~1° apart.
        let raw = -179.0 * deg1
        let cursor = Vector(ref.x + d * cos(raw), ref.y + d * sin(raw))
        let out = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg90, apertureRadians: 2 * deg1,
            rayLengthWorld: 100
        )
        let r = try! #require(out)
        #expect(abs(abs(r.engagedAngle) - Double.pi) < eps)        // ±π ray
        #expect(r.withinAperture)                                  // ~1° < 2° (normalized)
    }

    @Test("normalizedDelta maps wrapped diffs into [-π, π]")
    func normalizedDeltaWraps() {
        // A naive (raw - engaged) just over +π should normalize to just over -π.
        let a = Double.pi + deg1
        let n = PolarTracking.normalizedDelta(a)
        #expect(n <= Double.pi + eps && n >= -Double.pi - eps)
        #expect(abs(n - (-(Double.pi - deg1))) < eps)
        // Small diffs pass through unchanged.
        #expect(abs(PolarTracking.normalizedDelta(deg1) - deg1) < eps)
        #expect(abs(PolarTracking.normalizedDelta(-deg1) - (-deg1)) < eps)
    }

    // MARK: - snappedPoint must equal PolarConstraint (the lock agrees)

    @Test("snappedPoint exactly equals PolarConstraint.constrain for several inputs")
    func snappedMatchesPolarConstraint() {
        let inputs: [(Vector, Vector, Double)] = [
            (Vector(0, 0),   Vector(10, 11),   deg45),
            (Vector(2, 2),   Vector(30, 8),    deg90),
            (Vector(-3, 4),  Vector(7, -2),    deg15),
            (Vector(5, 5),   Vector(5.1, 40),  deg15),
            (Vector(0, 0),   Vector(-9, -2),   deg90),
            (Vector(1, 1),   Vector(-5, 5),    deg45),
        ]
        for (ref, cursor, inc) in inputs {
            let lock = PolarConstraint.constrain(cursor, relativeTo: ref, incrementRadians: inc)
            let out = PolarTracking.resolve(
                reference: ref, cursor: cursor,
                incrementRadians: inc, apertureRadians: deg15, rayLengthWorld: 100
            )
            let r = try! #require(out)
            // Bit-exact agreement: same rounding + placement formula.
            #expect(r.snappedPoint == lock,
                    "tracking snappedPoint must equal the PolarConstraint lock")
        }
    }

    // MARK: - z is carried from the cursor; rayFar carries reference.z

    @Test("snappedPoint carries cursor.z; rayFar carries reference.z")
    func zCarry() {
        let ref = Vector(0, 0, 2)
        let cursor = Vector(10, 11, 7)
        let out = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg45, apertureRadians: deg15, rayLengthWorld: 100
        )
        let r = try! #require(out)
        #expect(r.snappedPoint.z == 7)        // from cursor, matching PolarConstraint
        #expect(r.rayFar.z == 2)              // from reference
    }

    // MARK: - non-finite ray length / aperture degrade gracefully (render-only)

    @Test("non-finite rayLength degrades to a zero-length ray; non-finite aperture => not within")
    func nonFiniteRenderInputsDegrade() {
        let ref = Vector(1, 1)
        let cursor = Vector(11, 1)            // on the 0° ray
        let outLen = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg90, apertureRadians: deg1, rayLengthWorld: .nan
        )
        let rl = try! #require(outLen)
        #expect(rl.rayFar.x == ref.x && rl.rayFar.y == ref.y)   // zero-length ray
        #expect(rl.withinAperture)                              // geometry still resolves

        let outAp = PolarTracking.resolve(
            reference: ref, cursor: cursor,
            incrementRadians: deg90, apertureRadians: .infinity, rayLengthWorld: 100
        )
        let ra = try! #require(outAp)
        #expect(!ra.withinAperture)                             // non-finite aperture => off
    }
}
