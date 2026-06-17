//
//  UCS.swift
//  CADEngine
//
//  A User Coordinate System (UCS) — a rotated/translated 2D coordinate frame
//  used at the input/display boundary, mirroring the concept in LibreCAD /
//  AutoCAD-style CAD apps. Geometry in the document always lives in WORLD
//  coordinates; the UCS converts coordinates only as the user types/reads them.
//
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

extension Vector {
    /// The world origin `(0, 0, 0)` as a valid vector. (Defined here, in the UCS
    /// module file, because `Vector` itself ships only `.invalid`; a zero/origin
    /// constant is what the UCS API's defaults need.)
    public static let zero = Vector(0, 0, 0)
}

/// A user coordinate frame: a world-space `origin` plus a rotation `angle`
/// (radians, **counter-clockwise**, of the UCS X axis relative to world X).
///
/// This is a pure value type — no UI, no rendering, f64 throughout. It exists
/// to translate coordinates at the **input/display boundary**: the engine and
/// document keep all geometry in WORLD coordinates, and a UCS is applied only
/// when the user enters or reads a coordinate.
///
/// ### Conventions
/// - **Rotation sign:** positive `angle` rotates the UCS axes CCW relative to
///   world, matching `Vector.rotated(by:)` (complex-multiply by `(cos, sin)`).
/// - **Forward (`toWorld`)** rotates UCS-relative coordinates by `+angle` then
///   translates by `+origin`.
/// - **Inverse (`toUCS`)** translates by `-origin` then rotates by `-angle`.
/// - **`z` is passed through unchanged** — this is a 2D app, but the carried
///   z-component of `Vector` survives the round trip for 2.5D points.
public struct UCS: Equatable, Sendable, Codable {
    /// World-space position of the UCS origin.
    public var origin: Vector
    /// Rotation of the UCS X axis vs world X, in radians, CCW.
    public var angle: Double

    /// Creates a UCS from an origin and rotation angle (radians, CCW).
    public init(origin: Vector = .zero, angle: Double = 0) {
        self.origin = origin
        self.angle = angle
    }

    /// The world coordinate system (identity): origin at world zero, no rotation.
    public static let world = UCS(origin: .zero, angle: 0)

    /// Whether this frame is (within tolerance) the world frame: origin ≈ 0 and
    /// angle ≈ 0. Uses a small absolute epsilon suitable for f64 CAD coordinates.
    public var isWorld: Bool {
        let eps = 1e-9
        return abs(origin.x) < eps
            && abs(origin.y) < eps
            && abs(origin.z) < eps
            && abs(Vector.correctAngle(angle)) < eps
    }

    // MARK: - Point conversion (translation + rotation)

    /// Converts a WORLD point into UCS-relative coordinates.
    ///
    /// Translates by `-origin`, then rotates by `-angle`. The `z` component is
    /// preserved (the planar rotation leaves it untouched and there is no
    /// z translation).
    public func toUCS(_ world: Vector) -> Vector {
        let translated = world - origin
        // Preserve z: `world - origin` already carries z = world.z - origin.z;
        // re-add origin.z so z is passed through unchanged (no z translation).
        let planar = Vector(translated.x, translated.y, world.z)
        return planar.rotated(by: -angle)
    }

    /// Converts a UCS-relative point into WORLD coordinates.
    ///
    /// Rotates by `+angle`, then translates by `+origin`. The `z` component is
    /// preserved (no z rotation/translation is applied).
    public func toWorld(_ ucs: Vector) -> Vector {
        let rotated = ucs.rotated(by: angle)
        // rotated.z == ucs.z (planar rotation keeps z); add only the planar
        // origin translation so z passes through unchanged.
        return Vector(rotated.x + origin.x, rotated.y + origin.y, ucs.z)
    }

    // MARK: - Direction conversion (rotation only, no translation)

    /// Rotates a WORLD delta/direction into the UCS frame (no translation).
    public func directionToUCS(_ d: Vector) -> Vector {
        let r = d.rotated(by: -angle)
        return Vector(r.x, r.y, d.z)
    }

    /// Rotates a UCS-relative delta/direction into WORLD (no translation).
    public func directionToWorld(_ d: Vector) -> Vector {
        let r = d.rotated(by: angle)
        return Vector(r.x, r.y, d.z)
    }

    // MARK: - Angle conversion

    /// Expresses a WORLD angle relative to the UCS (for polar entry / display):
    /// `worldAngle - angle`. Not range-normalized — callers that need a
    /// canonical range can apply `Vector.correctAngle`.
    public func displayAngle(_ worldAngle: Double) -> Double {
        worldAngle - angle
    }
}
