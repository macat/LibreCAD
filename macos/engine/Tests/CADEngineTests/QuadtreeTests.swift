//
//  QuadtreeTests.swift
//  CADEngineTests
//
//  Correctness (vs brute force), insert/remove/update consistency, and a
//  large-scale (100k) output-sensitivity smoke test for the loose quadtree
//  spatial index (workstream D).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Quadtree spatial index")
struct QuadtreeTests {

    // MARK: - Test helpers

    /// Deterministic small PRNG so the random fuzz tests are reproducible across
    /// runs/platforms (no dependence on the system RNG seed). SplitMix64.
    private struct SeededRNG: RandomNumberGenerator {
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

    /// Inclusive 2D AABB overlap used as the brute-force oracle — must match the
    /// quadtree's internal predicate. Empty boxes never overlap.
    private func overlaps(_ a: AABB, _ b: AABB) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        return a.min.x <= b.max.x && a.max.x >= b.min.x
            && a.min.y <= b.max.y && a.max.y >= b.min.y
    }

    /// Builds a random AABB whose lower corner is in `[lo, hi]` and whose size is
    /// in `[minSize, minSize + sizeSpan]`, on each axis.
    private func randomBox(_ rng: inout SeededRNG,
                           lo: Double, hi: Double,
                           minSize: Double = 0.5, sizeSpan: Double = 10) -> AABB {
        let x = Double.random(in: lo...hi, using: &rng)
        let y = Double.random(in: lo...hi, using: &rng)
        let w = minSize + Double.random(in: 0...sizeSpan, using: &rng)
        let h = minSize + Double.random(in: 0...sizeSpan, using: &rng)
        return AABB(min: Vector(x, y), max: Vector(x + w, y + h))
    }

    // MARK: - Correctness vs brute force (region queries)

    @Test("region query matches brute-force AABB overlap over many random queries")
    func regionQueryMatchesBruteForce() {
        var rng = SeededRNG(seed: 0xCAD0_1234)
        let tree = Quadtree()
        var truth: [EntityID: AABB] = [:]

        // ~500 random AABBs spread over a wide, off-origin world (exercises grow
        // and negative coordinates).
        for i in 0..<500 {
            let id = EntityID(UInt64(i + 1))
            let box = randomBox(&rng, lo: -1000, hi: 1000)
            tree.insert(id, bounds: box)
            truth[id] = box
        }
        #expect(tree.count == 500)

        // 40 random query regions of varied size, including some that fall outside
        // the populated area (must return empty).
        for _ in 0..<40 {
            let qx = Double.random(in: -1200...1200, using: &rng)
            let qy = Double.random(in: -1200...1200, using: &rng)
            let qw = Double.random(in: 1...400, using: &rng)
            let qh = Double.random(in: 1...400, using: &rng)
            let region = AABB(min: Vector(qx, qy), max: Vector(qx + qw, qy + qh))

            let got = Set(tree.query(region: region))
            let expected = Set(truth.filter { overlaps($0.value, region) }.map(\.key))
            #expect(got == expected)
        }
    }

    @Test("region query never returns duplicates")
    func regionQueryNoDuplicates() {
        var rng = SeededRNG(seed: 0xBEEF)
        let tree = Quadtree()
        for i in 0..<300 {
            tree.insert(EntityID(UInt64(i + 1)), bounds: randomBox(&rng, lo: -500, hi: 500))
        }
        // A region covering the whole world should return every id exactly once.
        let all = tree.query(region: AABB(min: Vector(-1e6, -1e6), max: Vector(1e6, 1e6)))
        #expect(all.count == 300)
        #expect(Set(all).count == all.count)
    }

    // MARK: - Correctness vs brute force (point + tolerance)

    @Test("point+tolerance query matches brute-force inflated-box test")
    func pointToleranceMatchesBruteForce() {
        var rng = SeededRNG(seed: 0xF00D_5678)
        let tree = Quadtree()
        var truth: [EntityID: AABB] = [:]
        for i in 0..<500 {
            let id = EntityID(UInt64(i + 1))
            let box = randomBox(&rng, lo: -1000, hi: 1000)
            tree.insert(id, bounds: box)
            truth[id] = box
        }

        for _ in 0..<40 {
            let p = Vector(Double.random(in: -1100...1100, using: &rng),
                           Double.random(in: -1100...1100, using: &rng))
            let tol = Double.random(in: 0...25, using: &rng)
            let got = Set(tree.query(point: p, tolerance: tol))

            // Oracle: box overlaps the point's probe box (point ± tol).
            let probe = AABB(min: Vector(p.x - tol, p.y - tol),
                             max: Vector(p.x + tol, p.y + tol))
            let expected = Set(truth.filter { overlaps($0.value, probe) }.map(\.key))
            #expect(got == expected)
        }
    }

    @Test("zero-tolerance point query returns boxes containing the point")
    func zeroTolerancePointQuery() {
        let tree = Quadtree()
        tree.insert(EntityID(1), bounds: AABB(min: Vector(0, 0), max: Vector(10, 10)))
        tree.insert(EntityID(2), bounds: AABB(min: Vector(20, 20), max: Vector(30, 30)))

        #expect(Set(tree.query(point: Vector(5, 5), tolerance: 0)) == [EntityID(1)])
        #expect(tree.query(point: Vector(15, 15), tolerance: 0).isEmpty)
        // Point (12,12): box 1's nearest corner (10,10) is ~2.83 away, box 2's
        // corner (20,20) is ~11.3 away — a tolerance of 5 reaches only box 1.
        #expect(Set(tree.query(point: Vector(12, 12), tolerance: 5)) == [EntityID(1)])
        // A large tolerance reaches both (corner-to-point distance test).
        #expect(Set(tree.query(point: Vector(15, 15), tolerance: 8)) == [EntityID(1), EntityID(2)])
    }

    // MARK: - insert / remove / update consistency

    @Test("update moves an entity: old region drops it, new region returns it")
    func updateMovesEntity() {
        let tree = Quadtree()
        let id = EntityID(42)
        let oldBox = AABB(min: Vector(0, 0), max: Vector(5, 5))
        let newBox = AABB(min: Vector(100, 100), max: Vector(105, 105))
        // Some neighbors so the tree actually subdivides around both locations.
        for i in 0..<50 {
            let f = Double(i)
            tree.insert(EntityID(UInt64(1000 + i)), bounds: AABB(min: Vector(f, f), max: Vector(f + 1, f + 1)))
            tree.insert(EntityID(UInt64(2000 + i)), bounds: AABB(min: Vector(100 + f, 100 + f), max: Vector(101 + f, 101 + f)))
        }
        tree.insert(id, bounds: oldBox)

        let oldRegion = AABB(min: Vector(-1, -1), max: Vector(6, 6))
        let newRegion = AABB(min: Vector(99, 99), max: Vector(106, 106))
        #expect(tree.query(region: oldRegion).contains(id))
        #expect(!tree.query(region: newRegion).contains(id))

        tree.update(id, bounds: newBox)

        #expect(!tree.query(region: oldRegion).contains(id))
        #expect(tree.query(region: newRegion).contains(id))
        #expect(tree.box(for: id) == newBox)
        #expect(tree.count == 101)  // 100 neighbors + the moved one, no dup
    }

    @Test("remove drops an entity from all queries")
    func removeDropsEntity() {
        let tree = Quadtree()
        for i in 0..<100 {
            let f = Double(i)
            tree.insert(EntityID(UInt64(i + 1)), bounds: AABB(min: Vector(f, 0), max: Vector(f + 0.5, 1)))
        }
        let target = EntityID(50)
        #expect(tree.box(for: target) != nil)
        tree.remove(target)
        #expect(tree.box(for: target) == nil)
        #expect(tree.count == 99)

        let whole = tree.query(region: AABB(min: Vector(-1, -1), max: Vector(200, 2)))
        #expect(!whole.contains(target))
        #expect(whole.count == 99)
    }

    @Test("re-inserting the same id replaces rather than duplicates")
    func reinsertReplaces() {
        let tree = Quadtree()
        let id = EntityID(7)
        tree.insert(id, bounds: AABB(min: Vector(0, 0), max: Vector(1, 1)))
        tree.insert(id, bounds: AABB(min: Vector(0, 0), max: Vector(2, 2)))  // same id, new box
        #expect(tree.count == 1)
        let hits = tree.query(region: AABB(min: Vector(-1, -1), max: Vector(3, 3)))
        #expect(hits == [id])
        #expect(tree.box(for: id) == AABB(min: Vector(0, 0), max: Vector(2, 2)))
    }

    @Test("removeAll empties the index and queries return nothing")
    func removeAllEmpties() {
        var rng = SeededRNG(seed: 0x1357)
        let tree = Quadtree()
        for i in 0..<200 {
            tree.insert(EntityID(UInt64(i + 1)), bounds: randomBox(&rng, lo: -100, hi: 100))
        }
        #expect(tree.count == 200)
        tree.removeAll()
        #expect(tree.isEmpty)
        #expect(tree.count == 0)
        #expect(tree.query(region: AABB(min: Vector(-1e6, -1e6), max: Vector(1e6, 1e6))).isEmpty)
        // Index is reusable after clearing.
        tree.insert(EntityID(1), bounds: AABB(min: Vector(0, 0), max: Vector(1, 1)))
        #expect(tree.count == 1)
    }

    @Test("empty / invalid boxes are rejected, missing-id ops are no-ops")
    func edgeCases() {
        let tree = Quadtree()
        tree.insert(EntityID(1), bounds: .empty)          // rejected
        #expect(tree.isEmpty)
        tree.remove(EntityID(99))                          // no-op, no crash
        tree.update(EntityID(5), bounds: AABB(min: Vector(0, 0), max: Vector(1, 1)))  // acts as insert
        #expect(tree.count == 1)
        // Invalid query inputs return empty rather than crashing.
        #expect(tree.query(region: .empty).isEmpty)
        #expect(tree.query(point: .invalid, tolerance: 1).isEmpty)
        #expect(tree.nearest(to: .invalid) == nil)
    }

    // MARK: - Straddling entities (the loose-quadtree raison d'être)

    @Test("entities straddling splits are found by both sides' queries")
    func straddlingEntities() {
        let tree = Quadtree()
        // Dense small boxes to force deep subdivision, plus a few big spanning
        // boxes that cross the world center (the classic straddle case).
        var rng = SeededRNG(seed: 0x5151)
        var truth: [EntityID: AABB] = [:]
        for i in 0..<400 {
            let id = EntityID(UInt64(i + 1))
            let box = randomBox(&rng, lo: -200, hi: 200, minSize: 0.2, sizeSpan: 2)
            tree.insert(id, bounds: box); truth[id] = box
        }
        // Big spanners crossing (0,0).
        for i in 0..<10 {
            let id = EntityID(UInt64(900 + i))
            let s = Double(50 + i * 10)
            let box = AABB(min: Vector(-s, -s), max: Vector(s, s))
            tree.insert(id, bounds: box); truth[id] = box
        }
        // Query small windows in opposite quadrants — every spanner overlapping
        // each must be returned, matching brute force.
        for region in [AABB(min: Vector(10, 10), max: Vector(20, 20)),
                       AABB(min: Vector(-20, -20), max: Vector(-10, -10)),
                       AABB(min: Vector(-5, 40), max: Vector(5, 45))] {
            let got = Set(tree.query(region: region))
            let expected = Set(truth.filter { overlaps($0.value, region) }.map(\.key))
            #expect(got == expected)
        }
    }

    // MARK: - nearest()

    @Test("nearest returns the closest box (or nil beyond maxDistance)")
    func nearestSelectsClosest() {
        let tree = Quadtree()
        tree.insert(EntityID(1), bounds: AABB(min: Vector(0, 0), max: Vector(1, 1)))     // near origin
        tree.insert(EntityID(2), bounds: AABB(min: Vector(50, 50), max: Vector(51, 51))) // far
        tree.insert(EntityID(3), bounds: AABB(min: Vector(5, 0), max: Vector(6, 1)))     // middling

        #expect(tree.nearest(to: Vector(0.5, 0.5)) == EntityID(1))  // inside box 1
        #expect(tree.nearest(to: Vector(5.5, 0.5)) == EntityID(3))  // inside box 3
        // Beyond any box within the cap → nil.
        #expect(tree.nearest(to: Vector(0, 0), maxDistance: 0.0) == EntityID(1)) // dist 0 inside
        #expect(tree.nearest(to: Vector(-100, -100), maxDistance: 1.0) == nil)
        // Empty tree → nil.
        #expect(Quadtree().nearest(to: Vector(0, 0)) == nil)
    }

    @Test("nearest matches brute-force closest-box over random points")
    func nearestMatchesBruteForce() {
        var rng = SeededRNG(seed: 0xABCD_EF01)
        let tree = Quadtree()
        var truth: [EntityID: AABB] = [:]
        for i in 0..<300 {
            let id = EntityID(UInt64(i + 1))
            let box = randomBox(&rng, lo: -300, hi: 300)
            tree.insert(id, bounds: box); truth[id] = box
        }
        func boxDist(_ p: Vector, _ b: AABB) -> Double {
            let dx = Swift.max(b.min.x - p.x, 0, p.x - b.max.x)
            let dy = Swift.max(b.min.y - p.y, 0, p.y - b.max.y)
            return (dx * dx + dy * dy).squareRoot()
        }
        for _ in 0..<25 {
            let p = Vector(Double.random(in: -350...350, using: &rng),
                           Double.random(in: -350...350, using: &rng))
            let got = tree.nearest(to: p)
            // Brute-force minimum distance (ties allowed — assert the chosen one is
            // within tolerance of the true minimum, since several boxes can tie).
            let minDist = truth.values.map { boxDist(p, $0) }.min()!
            #expect(got != nil)
            if let got, let gotBox = truth[got] {
                #expect(abs(boxDist(p, gotBox) - minDist) < 1e-9)
            }
        }
    }

    // MARK: - Large-scale output-sensitivity smoke test

    @Test("100k inserts: small-viewport query returns a small, correct subset")
    func largeScaleSmallViewport() {
        let n = 100_000
        var rng = SeededRNG(seed: 0x100C_0000)
        let tree = Quadtree()
        // Spread tiny boxes over a 10k×10k world so a small viewport touches only a
        // sparse subset. Keep boxes small (size ~1) so AABB overlap is meaningful.
        var boxes: [(EntityID, AABB)] = []
        boxes.reserveCapacity(n)
        for i in 0..<n {
            let id = EntityID(UInt64(i + 1))
            let x = Double.random(in: 0...10_000, using: &rng)
            let y = Double.random(in: 0...10_000, using: &rng)
            let box = AABB(min: Vector(x, y), max: Vector(x + 1, y + 1))
            tree.insert(id, bounds: box)
            boxes.append((id, box))
        }
        #expect(tree.count == n)

        // A 100×100 viewport is 1/10000 of the world area → expect ~tens of hits,
        // a tiny fraction of 100k. The key contract: query is output-sensitive.
        let region = AABB(min: Vector(3000, 3000), max: Vector(3100, 3100))
        let hits = Set(tree.query(region: region))

        // Brute-force oracle over a *sampled* subset is not enough for an equality
        // check, so verify against the full set — but that's O(n) once, off the
        // hot path, and validates correctness at scale.
        let expected = Set(boxes.filter { overlaps($0.1, region) }.map(\.0))
        #expect(hits == expected)

        // Output-sensitivity sanity: the returned set is a small fraction of total.
        #expect(hits.count < n / 100)            // far fewer than 1%
        #expect(hits.count == expected.count)    // exact, no misses/dups

        // A point query in the same area also returns a small candidate set.
        let pointHits = tree.query(point: Vector(3050, 3050), tolerance: 50)
        let pointExpected = boxes.filter {
            overlaps($0.1, AABB(min: Vector(3000, 3000), max: Vector(3100, 3100)))
        }.count
        #expect(pointHits.count <= pointExpected)  // tighter probe ⊆ the 100×100 window
        #expect(Set(pointHits).count == pointHits.count)  // no duplicates at scale
    }
}
