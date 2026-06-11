//
//  VectorTests.swift
//  CADEngineTests
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

private let tol = 1e-12

@Suite("Vector math")
struct VectorTests {

    @Test("distance between two points")
    func distance() {
        let a = Vector(0, 0)
        let b = Vector(3, 4)
        #expect(abs(a.distance(to: b) - 5) < tol)
        #expect(abs(b.distance(to: a) - 5) < tol)
    }

    @Test("magnitude and squared")
    func magnitude() {
        let v = Vector(3, 4)
        #expect(abs(v.magnitude - 5) < tol)
        #expect(abs(v.squared - 25) < tol)
    }

    @Test("angle is in [0, 2pi)")
    func angle() {
        #expect(abs(Vector(1, 0).angle - 0) < tol)
        #expect(abs(Vector(0, 1).angle - Double.pi / 2) < tol)
        #expect(abs(Vector(-1, 0).angle - Double.pi) < tol)
        // Pointing into the lower-right quadrant must wrap to ~3pi/2, not -pi/2.
        let down = Vector(0, -1).angle
        #expect(abs(down - 3 * Double.pi / 2) < tol)
        #expect(down >= 0)
    }

    @Test("angleTo")
    func angleTo() {
        let origin = Vector(0, 0)
        #expect(abs(origin.angleTo(Vector(1, 0)) - 0) < tol)
        #expect(abs(origin.angleTo(Vector(0, 1)) - Double.pi / 2) < tol)
        // Invalid operand returns 0.
        #expect(origin.angleTo(.invalid) == 0)
    }

    @Test("rotation by 90 degrees")
    func rotation() {
        let v = Vector(1, 0)
        let r = v.rotated(by: Double.pi / 2)
        #expect(abs(r.x - 0) < tol)
        #expect(abs(r.y - 1) < tol)
        // Full turn returns to start.
        let full = v.rotated(by: 2 * Double.pi)
        #expect(abs(full.x - 1) < tol)
        #expect(abs(full.y - 0) < tol)
    }

    @Test("polar construction")
    func polar() {
        let p = Vector.polar(radius: 2, angle: Double.pi / 2)
        #expect(abs(p.x - 0) < tol)
        #expect(abs(p.y - 2) < tol)
        let q = Vector.polar(radius: 5, angle: 0)
        #expect(abs(q.x - 5) < tol)
        #expect(abs(q.y - 0) < tol)
    }

    @Test("dot product")
    func dot() {
        #expect(abs(Vector(1, 0).dot(Vector(0, 1)) - 0) < tol)      // orthogonal
        #expect(abs(Vector(2, 3).dot(Vector(4, 5)) - 23) < tol)     // 8 + 15
        #expect(abs(Vector(1, 2, 3).dot(Vector(4, 5, 6)) - 32) < tol) // includes z
    }

    @Test("arithmetic operators")
    func arithmetic() {
        #expect(Vector(1, 2) + Vector(3, 4) == Vector(4, 6))
        #expect(Vector(5, 7) - Vector(2, 3) == Vector(3, 4))
        #expect(Vector(1, 2) * 3 == Vector(3, 6))
        #expect(3 * Vector(1, 2) == Vector(3, 6))
        #expect(-Vector(1, -2) == Vector(-1, 2))
    }

    @Test("validity sentinel")
    func validity() {
        #expect(Vector.invalid.valid == false)
        #expect(Vector(1, 1).valid == true)
        // An invalid vector is not equal to a valid zero vector.
        #expect(Vector(valid: false) != Vector(0, 0))
        // distance with an invalid operand is the large sentinel.
        #expect(Vector(0, 0).distance(to: .invalid) >= 1e10)
    }
}
