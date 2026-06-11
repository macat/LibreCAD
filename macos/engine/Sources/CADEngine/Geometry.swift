//
//  Geometry.swift
//  CADEngine
//
//  Foundation geometric primitives shared across the entity model: stable IDs,
//  the axis-aligned bounding box, and engine tolerances. Pure Swift value types,
//  f64 throughout (ADR-003).
//
//  Ported tolerance constants come from LibreCAD's rs.h (GPLv2-or-later).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_* constants).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// Engine-wide numeric tolerances, ported from LibreCAD's `rs.h`.
///
/// The engine is f64 everywhere (ADR-003), so these match the original C++
/// kernel exactly and hit-testing/snapping stay bit-for-bit comparable.
public enum Tolerance {
    /// `RS_TOLERANCE` — the general distance tolerance (1e-10).
    public static let distance = 1.0e-10
    /// `RS_TOLERANCE2` — squared-distance tolerance (1e-20).
    public static let distanceSquared = 1.0e-20
    /// `RS_TOLERANCE_ANGLE` — angular tolerance in radians (1e-8).
    public static let angle = 1.0e-8
}

/// A lightweight, stable identifier for an entity in a `CADDrawing`.
///
/// IDs are minted by the document (never reused within a document's lifetime),
/// so they are safe to use as dictionary keys and as cross-entity references
/// (block contents, parent/child) per ADR-001 — no object pointers, no cycles.
public struct EntityID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "EntityID(\(rawValue))" }
}

/// A layer reference. Layers live in the document's `LayerTable`; entities carry
/// only this id, never a layer object pointer (ADR-001).
///
/// We key by name (DXF layers are name-addressed and round-trip by name), but
/// wrap it so call sites are explicit and the representation can change later.
public struct LayerID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { "LayerID(\(name))" }

    /// The conventional default layer (DXF layer "0").
    public static let zero = LayerID("0")
}

/// An axis-aligned bounding box in world coordinates (f64).
///
/// Mirrors the (min, max) corner pair LibreCAD threads through `RS_Entity`'s
/// `getMin()/getMax()`. An *empty* box (no points) is represented by `min`
/// being component-wise greater than `max`; `union`/`expand` recover from it.
public struct AABB: Sendable, Equatable {
    public var min: Vector
    public var max: Vector

    /// The empty box: a +inf min / -inf max so the first `expand` snaps to the
    /// real point. Distinguished from a degenerate (zero-size) box at a point.
    public static let empty = AABB(
        min: Vector(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude),
        max: Vector(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
    )

    public init(min: Vector, max: Vector) {
        self.min = min
        self.max = max
    }

    /// A degenerate box collapsed to a single point.
    public init(point p: Vector) {
        self.min = p
        self.max = p
    }

    /// `true` if this box holds no points (still in its `.empty` state).
    public var isEmpty: Bool { min.x > max.x || min.y > max.y || min.z > max.z }

    /// The box width/height/depth as a vector (zero or negative if empty).
    public var size: Vector { max - min }

    /// The center point (invalid for an empty box).
    public var center: Vector { isEmpty ? .invalid : (min + max) * 0.5 }

    /// Returns a copy enlarged to include `p`.
    public func expanded(toInclude p: Vector) -> AABB {
        guard p.valid else { return self }
        return AABB(
            min: Vector(Swift.min(min.x, p.x), Swift.min(min.y, p.y), Swift.min(min.z, p.z)),
            max: Vector(Swift.max(max.x, p.x), Swift.max(max.y, p.y), Swift.max(max.z, p.z))
        )
    }

    /// Enlarges this box in place to include `p`.
    public mutating func expand(toInclude p: Vector) {
        self = expanded(toInclude: p)
    }

    /// Returns the smallest box containing both `self` and `other`.
    public func union(_ other: AABB) -> AABB {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return AABB(
            min: Vector(Swift.min(min.x, other.min.x), Swift.min(min.y, other.min.y), Swift.min(min.z, other.min.z)),
            max: Vector(Swift.max(max.x, other.max.x), Swift.max(max.y, other.max.y), Swift.max(max.z, other.max.z))
        )
    }

    /// `true` if `p` lies within (or on the boundary of) this box, in x/y.
    public func contains(_ p: Vector) -> Bool {
        guard !isEmpty, p.valid else { return false }
        return p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y
    }

    /// Builds the tight box around a sequence of points.
    public init(points: [Vector]) {
        var box = AABB.empty
        for p in points { box.expand(toInclude: p) }
        self = box
    }
}
