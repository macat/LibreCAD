//
//  UCSTests.swift
//  CADEngineTests
//
//  Tests for the pure `UCS` (user coordinate system) value type (wave UCS-W1):
//  identity behaviour, pure translation, pure rotation (exact 90° values),
//  combined origin+rotation round-trips, direction-only rotation, display-angle,
//  and z pass-through.
//
//  Suite name is domain-prefixed (`UCSFrameTests`) to avoid a test-target
//  namespace clash with other parallel builders' suites
//  (CONVENTIONS.md "Namespace test-suite type names by domain").
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("UCS frame")
struct UCSFrameTests {

    private static let tol = 1e-12

    private func expectClose(_ a: Vector, _ b: Vector,
                             tol: Double = UCSFrameTests.tol,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let mag = Swift.max(1.0, abs(b.x), abs(b.y), abs(b.z))
        #expect(abs(a.x - b.x) < tol * mag, sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) < tol * mag, sourceLocation: sourceLocation)
        #expect(abs(a.z - b.z) < tol * mag, sourceLocation: sourceLocation)
    }

    // MARK: - Identity (.world)

    @Test(".world is the identity: toUCS / toWorld are no-ops")
    func worldIsIdentity() {
        let u = UCS.world
        #expect(u.isWorld)
        #expect(u == UCS(origin: .zero, angle: 0))

        let points: [Vector] = [
            Vector(0, 0), Vector(10, -20), Vector(-3.5, 7.25, 4.0),
            Vector(1_000_000.5, -2_000_000.25, -8.0),
        ]
        for p in points {
            expectClose(u.toUCS(p), p)
            expectClose(u.toWorld(p), p)
            expectClose(u.directionToUCS(p), p)
            expectClose(u.directionToWorld(p), p)
        }
    }

    @Test("default-constructed UCS equals .world")
    func defaultIsWorld() {
        #expect(UCS() == UCS.world)
        #expect(UCS().isWorld)
    }

    // MARK: - Pure translation

    @Test("pure translation: toUCS subtracts origin, toWorld adds it")
    func pureTranslation() {
        let origin = Vector(100, -50)
        let u = UCS(origin: origin, angle: 0)
        #expect(!u.isWorld)

        let world = Vector(130, -20, 5)
        let inUCS = u.toUCS(world)
        // No rotation → pure subtraction in x/y; z passes through.
        expectClose(inUCS, Vector(30, 30, 5))
        expectClose(u.toWorld(inUCS), world)

        // Direction conversion ignores the translation entirely (angle 0 ⇒ no-op).
        let d = Vector(7, -3, 2)
        expectClose(u.directionToUCS(d), d)
        expectClose(u.directionToWorld(d), d)
    }

    // MARK: - Pure rotation (exact 90°)

    @Test("pure 90° rotation: world +X → UCS (0,-1); deltas rotate, no translation")
    func pureRotation90() {
        let u = UCS(origin: .zero, angle: .pi / 2)
        #expect(!u.isWorld)

        // toUCS rotates by -90°: (x,y) -> (y, -x).
        expectClose(u.toUCS(Vector(1, 0)), Vector(0, -1))
        expectClose(u.toUCS(Vector(0, 1)), Vector(1, 0))
        expectClose(u.toUCS(Vector(2, 3)), Vector(3, -2))

        // toWorld rotates by +90°: (x,y) -> (-y, x).
        expectClose(u.toWorld(Vector(0, -1)), Vector(1, 0))
        expectClose(u.toWorld(Vector(1, 0)), Vector(0, 1))
        expectClose(u.toWorld(Vector(3, -2)), Vector(2, 3))

        // Pure rotation ⇒ direction conversion equals point conversion (origin 0),
        // and explicitly does not translate.
        let d = Vector(2, 3, 9)
        expectClose(u.directionToUCS(d), Vector(3, -2, 9))
        expectClose(u.directionToWorld(d), Vector(-3, 2, 9))
    }

    @Test("directionToUCS rotates a delta without translating, even with a nonzero origin")
    func directionIgnoresOrigin() {
        let u = UCS(origin: Vector(1000, -777), angle: .pi / 2)
        let d = Vector(2, 3)
        // Same rotated delta regardless of the (large) origin.
        expectClose(u.directionToUCS(d), Vector(3, -2))
        expectClose(u.directionToWorld(d), Vector(-3, 2))
        // Round-trip on directions.
        expectClose(u.directionToWorld(u.directionToUCS(d)), d)
        expectClose(u.directionToUCS(u.directionToWorld(d)), d)
    }

    // MARK: - Combined origin + rotation

    @Test("combined origin+rotation: toWorld(toUCS(p)) == p for several points")
    func combinedRoundTrip() {
        let frames: [UCS] = [
            UCS(origin: Vector(10, 20), angle: .pi / 6),
            UCS(origin: Vector(-300.5, 42.25), angle: -1.234),
            UCS(origin: Vector(1_000_000, -2_000_000), angle: 2.9),
            UCS(origin: .zero, angle: 5.5),
        ]
        let points: [Vector] = [
            Vector(0, 0), Vector(1, 0), Vector(0, 1), Vector(-12.5, 88.0, 3.0),
            Vector(1_234_567.5, -9_876.25, -4.5),
        ]
        // Slightly looser relative tolerance for the million-magnitude frames.
        let rtol = 1e-9
        for u in frames {
            for p in points {
                expectClose(u.toWorld(u.toUCS(p)), p, tol: rtol)
                expectClose(u.toUCS(u.toWorld(p)), p, tol: rtol)
            }
        }
    }

    @Test("known combined value: origin (10,20), 90°")
    func combinedKnownValue() {
        let u = UCS(origin: Vector(10, 20), angle: .pi / 2)
        // world (10,21): translate to (0,1), rotate -90° -> (1,0).
        expectClose(u.toUCS(Vector(10, 21)), Vector(1, 0))
        // world (11,20): translate to (1,0), rotate -90° -> (0,-1).
        expectClose(u.toUCS(Vector(11, 20)), Vector(0, -1))
        // origin maps to UCS zero.
        expectClose(u.toUCS(Vector(10, 20)), Vector(0, 0))
        // UCS zero maps back to world origin.
        expectClose(u.toWorld(Vector(0, 0)), Vector(10, 20))
    }

    // MARK: - Display angle

    @Test("displayAngle subtracts the UCS angle")
    func displayAngleSubtracts() {
        let u = UCS(origin: Vector(5, 5), angle: .pi / 4)
        #expect(abs(u.displayAngle(.pi / 4) - 0) < Self.tol)
        #expect(abs(u.displayAngle(.pi / 2) - (.pi / 2 - .pi / 4)) < Self.tol)
        #expect(abs(u.displayAngle(0) - (-Double.pi / 4)) < Self.tol)
        // World frame leaves angles untouched.
        #expect(abs(UCS.world.displayAngle(1.2345) - 1.2345) < Self.tol)
    }

    // MARK: - z pass-through

    @Test("z is preserved through point and direction conversions")
    func zPreserved() {
        let u = UCS(origin: Vector(10, 20, 999), angle: 1.1)
        let p = Vector(7, -3, 42.5)
        // z is independent of the planar rotation AND of any origin z.
        #expect(abs(u.toUCS(p).z - 42.5) < Self.tol)
        #expect(abs(u.toWorld(p).z - 42.5) < Self.tol)
        #expect(abs(u.directionToUCS(p).z - 42.5) < Self.tol)
        #expect(abs(u.directionToWorld(p).z - 42.5) < Self.tol)
        // Full round-trip keeps z exactly.
        #expect(abs(u.toWorld(u.toUCS(p)).z - 42.5) < Self.tol)
    }

    // MARK: - isWorld tolerance

    @Test("isWorld is true only near origin 0 + angle 0")
    func isWorldTolerance() {
        #expect(UCS(origin: .zero, angle: 0).isWorld)
        #expect(UCS(origin: Vector(1e-12, -1e-12), angle: 1e-12).isWorld)
        #expect(!UCS(origin: Vector(0.001, 0), angle: 0).isWorld)
        #expect(!UCS(origin: .zero, angle: 0.001).isWorld)
        // A full 2π rotation normalizes to ~0 ⇒ treated as world rotation.
        #expect(UCS(origin: .zero, angle: 2 * .pi).isWorld)
    }

    // MARK: - Codable

    @Test("UCS round-trips through JSON Codable")
    func codableRoundTrip() throws {
        let u = UCS(origin: Vector(12.5, -34.75, 6.0), angle: 1.2345)
        let data = try JSONEncoder().encode(u)
        let decoded = try JSONDecoder().decode(UCS.self, from: data)
        #expect(decoded == u)
    }
}
