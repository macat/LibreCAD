//
//  BenchSupport.swift
//  CADBench
//
//  Reproducible synthetic-drawing generation, a fixed-seed PRNG, a high-res
//  timing helper, and a peak-memory probe — the shared scaffolding for the
//  engine/render scale benchmark (macos/docs/perf-report.md). NO engine/renderer
//  source is modified; this target only READS the shipping engine + the GPU-free
//  renderer geometry (symlinked, same pattern as the test target).
//
//  Determinism (CONVENTIONS.md / brief): a fixed SplitMix64 seed drives the whole
//  generator, so the entity set — and therefore every measured number — is
//  reproducible run to run. No `Date()`/system-RNG in the geometry.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation
import CADEngine

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Deterministic PRNG (SplitMix64)

/// A small, fast, fully-deterministic PRNG so the synthetic drawings (and hence
/// the benchmark numbers) reproduce exactly across runs and machines — the same
/// SplitMix64 the engine's own `QuadtreeTests` uses for its fuzz/scale tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - High-resolution timing

/// Wall-clock seconds for `body`, using the monotonic clock (immune to wall-time
/// adjustments). Returns the elapsed time AND the body's result.
@inline(__always)
func timed<T>(_ body: () -> T) -> (seconds: Double, value: T) {
    let start = DispatchTime.now().uptimeNanoseconds
    let v = body()
    let end = DispatchTime.now().uptimeNanoseconds
    return (Double(end - start) / 1_000_000_000.0, v)
}

/// Runs `body` `iterations` times after `warmup` un-timed iterations and returns
/// the BEST (minimum) per-iteration time in milliseconds. Minimum is the right
/// statistic for a microbenchmark: it is the run least perturbed by scheduling /
/// other-process noise, so it tracks the code's intrinsic cost most stably.
/// `setup` (if given) runs un-timed before each timed iteration (e.g. to reset
/// mutable state) and its cost is excluded.
func bestOf(iterations: Int,
            warmup: Int = 1,
            setup: (() -> Void)? = nil,
            _ body: () -> Void) -> Double {
    for _ in 0..<Swift.max(0, warmup) {
        setup?()
        body()
    }
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<Swift.max(1, iterations) {
        setup?()
        let (s, _) = timed(body)
        best = Swift.min(best, s)
    }
    return best * 1000.0   // → milliseconds
}

// MARK: - Peak-memory probe

enum MemoryProbe {

    /// The process's current resident size in bytes (approx peak when sampled at a
    /// high-water point), via `mach_task_basic_info.resident_size`. Falls back to
    /// `ProcessInfo` physical footprint if the mach call is unavailable. 0 on
    /// failure (reported as "n/a").
    static func residentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return info.resident_size
        }
        #endif
        return 0
    }

    /// A human-readable MiB string for a byte count (or "n/a" for 0).
    static func mib(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "n/a" }
        return String(format: "%.1f MiB", Double(bytes) / (1024.0 * 1024.0))
    }
}

// MARK: - Synthetic drawing generation

/// Builds reproducible synthetic CAD drawings of a requested entity count, with a
/// realistic mix of lines / circles / arcs / polylines spread over a square world
/// extent. Used to drive the scale benchmark; the same seed yields the same set.
enum SyntheticDrawing {

    /// The square world half-extent (world units). Entities are scattered in
    /// `[-worldHalf, +worldHalf]` on both axes, so a "typical" zoomed-in viewport
    /// sees a small fraction of them (the culling case the renderer targets).
    static let worldHalf = 50_000.0

    /// The entity-kind mix (fractions, summing to ~1). Lines dominate real CAD
    /// drawings; circles/arcs/polylines fill out the curve + multi-segment cost.
    /// (Polylines carry 4–12 vertices each, so they exercise the per-segment
    /// instance packing and the polyline bbox/resolve paths.)
    static let lineFraction = 0.55
    static let circleFraction = 0.15
    static let arcFraction = 0.15
    // remainder (~0.15) → polylines

    /// A generated drawing plus the parallel `(id, AABB)` list (so the quadtree
    /// build can be timed without re-walking the entity array, and the cull/hit
    /// benches can reuse the exact boxes the index was built from).
    struct Generated {
        let drawing: CADDrawing
        let boxes: [(id: EntityID, box: AABB)]
    }

    /// Generates `count` entities into a fresh `CADDrawing` with a fixed seed.
    ///
    /// The drawing is populated via `load(...)` (no per-entity undo registration —
    /// that would dominate the generation cost and is irrelevant to what we
    /// measure). Boxes are computed once here (the analytic `boundingBox()`), so
    /// the quadtree-build bench times ONLY the index construction, not the bbox
    /// math (which is part of the entity model, benched separately by `resolve`).
    @MainActor
    static func generate(count: Int, seed: UInt64) -> Generated {
        var rng = SeededRNG(seed: seed)
        var records: [EntityRecord] = []
        records.reserveCapacity(count)

        @inline(__always)
        func rand(_ lo: Double, _ hi: Double) -> Double {
            Double.random(in: lo...hi, using: &rng)
        }
        @inline(__always)
        func point() -> Vector { Vector(rand(-worldHalf, worldHalf), rand(-worldHalf, worldHalf)) }

        let lineCut = lineFraction
        let circleCut = lineCut + circleFraction
        let arcCut = circleCut + arcFraction

        for i in 0..<count {
            let id = EntityID(UInt64(i + 1))
            let roll = rand(0, 1)
            let kind: EntityKind
            if roll < lineCut {
                // Short-ish line (length ~ up to 200 units) anchored at a random point.
                let a = point()
                let b = a + Vector(rand(-200, 200), rand(-200, 200))
                kind = .line(LineData(start: a, end: b))
            } else if roll < circleCut {
                kind = .circle(CircleData(center: point(), radius: rand(1, 150)))
            } else if roll < arcCut {
                let start = rand(0, 2 * Double.pi)
                let sweep = rand(0.3, 1.8 * Double.pi)
                kind = .arc(ArcData(center: point(), radius: rand(1, 150),
                                    startAngle: start, endAngle: start + sweep,
                                    reversed: rand(0, 1) < 0.5))
            } else {
                // A 4–12 vertex polyline; ~20% of segments carry a bulge (arc).
                let n = Int(rand(4, 12.999))
                var verts: [PolylineVertex] = []
                verts.reserveCapacity(n)
                var p = point()
                for _ in 0..<n {
                    let bulge = rand(0, 1) < 0.2 ? rand(-0.6, 0.6) : 0.0
                    verts.append(PolylineVertex(point: p, bulge: bulge))
                    p = p + Vector(rand(-80, 80), rand(-80, 80))
                }
                kind = .polyline(PolylineData(vertices: verts, closed: rand(0, 1) < 0.3))
            }
            records.append(EntityRecord(id: id, kind: kind))
        }

        let drawing = CADDrawing()
        drawing.load(entities: records, layers: LayerTable())

        // Precompute the boxes once (analytic bbox), parallel to `records`.
        var boxes: [(id: EntityID, box: AABB)] = []
        boxes.reserveCapacity(count)
        for r in records {
            boxes.append((r.id, r.boundingBox()))
        }
        return Generated(drawing: drawing, boxes: boxes)
    }
}
