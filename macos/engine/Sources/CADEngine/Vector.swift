//
//  Vector.swift
//  CADEngine
//
//  Ported from LibreCAD's RS_Vector (librecad/src/lib/engine/rs_vector.{h,cpp}).
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Vector).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// A 3D point/vector (x, y, z) with a `valid` flag, mirroring LibreCAD's
/// `RS_Vector`. As in the original engine, `z` is carried everywhere but is
/// largely unused in the 2D workflow, and `valid == false` is the pervasive
/// "no result" sentinel returned by geometric queries.
///
/// This is a value type with full value semantics; it is `Sendable` so it can
/// cross actor boundaries freely.
public struct Vector: Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    /// Whether this vector represents a real result (`false` == "no result").
    public var valid: Bool

    /// The invalid sentinel (`RS_Vector(false)` in LibreCAD).
    public static let invalid = Vector(valid: false)

    /// Creates a valid vector from components.
    public init(_ x: Double, _ y: Double, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.valid = true
    }

    /// Creates a zero vector whose validity is explicitly set.
    public init(valid: Bool) {
        self.x = 0
        self.y = 0
        self.z = 0
        self.valid = valid
    }

    /// Creates a unit vector pointing in the direction of `angle` (radians),
    /// matching `RS_Vector(double angle)`.
    public init(angle: Double) {
        self.x = cos(angle)
        self.y = sin(angle)
        self.z = 0
        self.valid = true
    }

    // MARK: - Polar construction

    /// `RS_Vector::polar(rho, theta)` — a vector of length `radius` at `angle`.
    public static func polar(radius rho: Double, angle theta: Double) -> Vector {
        Vector(rho * cos(theta), rho * sin(theta), 0)
    }

    // MARK: - Magnitude & distance

    /// Euclidean length (`magnitude()`).
    public var magnitude: Double {
        guard valid else { return Double.greatestFiniteMagnitude }
        return (x * x + y * y + z * z).squareRoot()
    }

    /// Squared length (`squared()`) — avoids the sqrt.
    public var squared: Double { x * x + y * y + z * z }

    /// Distance to another vector (`distanceTo`). Returns a large sentinel if
    /// either vector is invalid, matching the C++ `RS_MAXDOUBLE` behavior.
    public func distance(to v: Vector) -> Double {
        guard valid, v.valid else { return 1e10 }
        return (self - v).magnitude
    }

    // MARK: - Angles

    /// Angle of the vector in [0, 2π), as `RS_Vector::angle()`
    /// (`correctAngle(atan2(y, x))`).
    public var angle: Double { Vector.correctAngle(atan2(y, x)) }

    /// Angle from `self` to `v` (`angleTo`): the angle of the vector `v - self`.
    /// Returns 0 if either is invalid.
    public func angleTo(_ v: Vector) -> Double {
        guard valid, v.valid else { return 0 }
        return (v - self).angle
    }

    // MARK: - Dot product

    /// Dot product (`dotP`), including the z component.
    public func dot(_ v: Vector) -> Double { x * v.x + y * v.y + z * v.z }

    // MARK: - Rotation

    /// Returns a copy rotated by `angle` radians about the origin
    /// (`RS_Vector::rotated(double)`), which rotates by the unit angle-vector
    /// (cos, sin) using complex multiplication.
    public func rotated(by angle: Double) -> Vector {
        rotated(by: Vector(angle: angle))
    }

    /// Returns a copy rotated by an angle-vector `(cos θ, sin θ)`
    /// (`RS_Vector::rotated(const RS_Vector&)`).
    public func rotated(by angleVector: Vector) -> Vector {
        let nx = x * angleVector.x - y * angleVector.y
        let ny = x * angleVector.y + y * angleVector.x
        return Vector(nx, ny, z)
    }

    // MARK: - Angle normalization (RS_Math::correctAngle)

    /// Maps an angle into [0, 2π), mirroring `RS_Math::correctAngle`.
    public static func correctAngle(_ a: Double) -> Double {
        let twoPi = 2 * Double.pi
        return (Double.pi + (a - Double.pi).remainder(dividingBy: twoPi)).truncatingRemainder(dividingBy: twoPi)
    }
}

// MARK: - Operators

public extension Vector {
    static func + (lhs: Vector, rhs: Vector) -> Vector {
        Vector(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func - (lhs: Vector, rhs: Vector) -> Vector {
        Vector(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static prefix func - (v: Vector) -> Vector { Vector(-v.x, -v.y, -v.z) }

    /// Scalar multiply.
    static func * (v: Vector, s: Double) -> Vector { Vector(v.x * s, v.y * s, v.z * s) }
    /// Scalar multiply (commuted).
    static func * (s: Double, v: Vector) -> Vector { v * s }
    /// Scalar divide.
    static func / (v: Vector, s: Double) -> Vector { Vector(v.x / s, v.y / s, v.z / s) }
}

// MARK: - Equatable / Hashable

extension Vector: Equatable {
    /// Component-wise equality that also requires matching validity, mirroring
    /// `RS_Vector::operator==`.
    public static func == (lhs: Vector, rhs: Vector) -> Bool {
        lhs.valid == rhs.valid && lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }
}

extension Vector: Hashable {
    /// Hashes the components and validity, consistent with `==`. (Bit-exact: two
    /// vectors that compare equal hash equal; this is a cache/dictionary key, not
    /// a tolerance-based geometric comparison.)
    public func hash(into hasher: inout Hasher) {
        hasher.combine(valid)
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(z)
    }
}

// MARK: - Codable

extension Vector: Codable {
    // Default member-wise coding (x, y, z, valid) — kept explicit so the on-disk
    // shape is a stable, documented contract for the entity model's Codable use.
}

// MARK: - CustomStringConvertible

extension Vector: CustomStringConvertible {
    public var description: String {
        valid ? "Vector(\(x), \(y), \(z))" : "Vector(invalid)"
    }
}
