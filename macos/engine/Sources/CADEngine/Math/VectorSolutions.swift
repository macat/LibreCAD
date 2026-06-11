//
//  VectorSolutions.swift
//  CADEngine
//
//  Ported from LibreCAD's RS_VectorSolutions (librecad/src/lib/engine/rs_vector.{h,cpp}).
//  The N-point result type returned by every geometric query / intersection.
//
//  LibreCAD is GPLv2-or-later; this native macOS port inherits that license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_VectorSolutions).
//  Copyright (C) Dongxu Li (geometric helpers).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// An ordered set of solution points, mirroring LibreCAD's `RS_VectorSolutions`.
///
/// This is the canonical return type for intersections and other geometric
/// queries: zero, one, or several `Vector`s, plus a `tangent` flag that marks a
/// result where the two curves touch rather than cross. It is a pure value type
/// (`Sendable`) so it crosses actor boundaries freely.
public struct VectorSolutions: Sendable, Equatable {

    /// The solution points, in the order they were produced.
    public private(set) var points: [Vector]

    /// `true` if at least one of the contained points is a tangent point
    /// (the two source curves touch rather than cross). Mirrors
    /// `RS_VectorSolutions::isTangent()`.
    public var tangent: Bool

    // MARK: - Construction

    /// An empty solution set.
    public init() {
        self.points = []
        self.tangent = false
    }

    /// Wraps a list of points.
    public init(_ points: [Vector], tangent: Bool = false) {
        self.points = points
        self.tangent = tangent
    }

    /// Variadic convenience (`RS_VectorSolutions{a, b}`).
    public init(_ points: Vector..., tangent: Bool = false) {
        self.points = points
        self.tangent = tangent
    }

    // MARK: - Count / emptiness

    /// Number of points (`getNumber()` / `size()`).
    public var count: Int { points.count }

    /// `true` when there are no points (`empty()`).
    public var isEmpty: Bool { points.isEmpty }

    /// `true` if any contained point is itself valid (`hasValid()`).
    public var hasValid: Bool { points.contains { $0.valid } }

    // MARK: - Element access

    /// Range-safe element access (`get(i)`): returns `.invalid` when out of range.
    public func get(_ i: Int) -> Vector {
        (i >= 0 && i < points.count) ? points[i] : .invalid
    }

    /// Unchecked subscript, matching `operator[]`.
    public subscript(_ i: Int) -> Vector {
        get { points[i] }
        set { points[i] = newValue }
    }

    /// The first point, or `nil` if empty.
    public var first: Vector? { points.first }
    /// The last point, or `nil` if empty.
    public var last: Vector? { points.last }

    // MARK: - Mutation

    /// Appends a point (`push_back`).
    public mutating func append(_ v: Vector) {
        points.append(v)
    }

    /// Appends every point of another solution set (`push_back(const RS_VectorSolutions&)`).
    public mutating func append(contentsOf other: VectorSolutions) {
        points.append(contentsOf: other.points)
    }

    /// Sets the point at `i` (`set(i, v)`).
    public mutating func set(_ i: Int, _ v: Vector) {
        points[i] = v
    }

    /// Removes the point at `i` (`removeAt(i)`).
    public mutating func remove(at i: Int) {
        points.remove(at: i)
    }

    /// Drops every point (`clear()`), preserving the `tangent` flag semantics
    /// of LibreCAD (which keeps the flag — call sites reset it explicitly).
    public mutating func clear() {
        points.removeAll(keepingCapacity: true)
    }

    // MARK: - Closest point (RS_VectorSolutions::getClosest / getClosestDistance)

    /// The contained point nearest to `coord`, plus its distance, mirroring
    /// `getClosest`. Returns `.invalid` (and a huge distance) when empty.
    public func closest(to coord: Vector) -> (point: Vector, distance: Double) {
        var minDistSq = Double.greatestFiniteMagnitude
        var closestPoint = Vector.invalid
        for p in points where p.valid {
            let dSq = (coord - p).squared
            if dSq < minDistSq {
                minDistSq = dSq
                closestPoint = p
            }
        }
        return (closestPoint, minDistSq.squareRoot())
    }

    /// Convenience: just the nearest point.
    public func closest(to coord: Vector) -> Vector {
        let (p, _): (Vector, Double) = closest(to: coord)
        return p
    }

    /// Closest distance over (up to) the first `counts` points
    /// (`getClosestDistance`). `counts < 0` searches all.
    public func closestDistance(to coord: Vector, counts: Int = -1) -> Double {
        var ret = Double.greatestFiniteMagnitude
        let limit = (counts >= 0 && counts < points.count) ? counts : points.count
        for i in 0..<limit {
            let vp = points[i]
            guard vp.valid else { continue }
            let d = (coord - vp).squared
            if d < ret { ret = d }
        }
        return ret.squareRoot()
    }

    // MARK: - Functional transforms

    /// Returns a new solution set with every point transformed by `f`
    /// (preserving the `tangent` flag), matching LibreCAD's bulk transforms.
    public func map(_ f: (Vector) -> Vector) -> VectorSolutions {
        VectorSolutions(points.map(f), tangent: tangent)
    }

    // MARK: - Geometric transforms (RS_VectorSolutions::move/rotate/scale/flipXY)

    /// Returns a translated copy (`move`).
    public func moved(by offset: Vector) -> VectorSolutions {
        map { $0 + offset }
    }

    /// Returns a copy rotated about the origin by `angle` radians (`rotate`).
    public func rotated(by angle: Double) -> VectorSolutions {
        let av = Vector(angle: angle)
        return map { $0.valid ? $0.rotated(by: av) : $0 }
    }

    /// Returns a copy rotated about `center` by `angle` radians.
    public func rotated(about center: Vector, by angle: Double) -> VectorSolutions {
        let av = Vector(angle: angle)
        return map { $0.valid ? (($0 - center).rotated(by: av) + center) : $0 }
    }

    /// Returns a copy rotated about `center` by an angle-vector `(cos, sin)`.
    public func rotated(about center: Vector, by angleVector: Vector) -> VectorSolutions {
        map { $0.valid ? (($0 - center).rotated(by: angleVector) + center) : $0 }
    }

    /// Returns a non-uniformly scaled copy about `center` (`scale`).
    public func scaled(about center: Vector, by factor: Vector) -> VectorSolutions {
        map { p in
            guard p.valid else { return p }
            let d = p - center
            return Vector(center.x + d.x * factor.x, center.y + d.y * factor.y, p.z)
        }
    }

    /// Returns a copy with x/y swapped for every point (`flipXY`).
    public func flippedXY() -> VectorSolutions {
        map { $0.valid ? Vector($0.y, $0.x, $0.z) : $0 }
    }
}

// MARK: - Sequence conformance

extension VectorSolutions: Sequence {
    public func makeIterator() -> IndexingIterator<[Vector]> {
        points.makeIterator()
    }
}

extension VectorSolutions: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Vector...) {
        self.init(elements)
    }
}

extension VectorSolutions: CustomStringConvertible {
    public var description: String {
        let body = points.map { "(\($0))" }.joined(separator: ", ")
        return "VectorSolutions[\(body)] tangent: \(tangent)"
    }
}
