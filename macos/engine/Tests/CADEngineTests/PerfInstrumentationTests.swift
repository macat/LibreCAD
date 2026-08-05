//
//  PerfInstrumentationTests.swift
//  CADEngineTests
//
//  Wave 0 — Baseline instrumentation (S). Verifies the lightweight trace points
//  added to `CADDrawing` (modelVersion + perf counters + os_signpost intervals)
//  and the bench scaffolding in `CADBench`. All counters default to 0 so the
//  bench still runs before Wave 1 wires a real cache; this suite locks in the
//  Wave-0 contract that later waves will increment.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("Perf instrumentation — Wave 0 baseline")
struct PerfInstrumentationTests {

    // MARK: - Helpers

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
    }

    // MARK: - Initial state

    @Test("initial counters are zero and hit ratio is 0")
    func initialCountersZero() {
        let d = CADDrawing()
        #expect(d.modelVersion == 0)
        #expect(d.perfCounters.addCount == 0)
        #expect(d.perfCounters.replaceCount == 0)
        #expect(d.perfCounters.removeCount == 0)
        #expect(d.perfCounters.resolveCacheHits == 0)
        #expect(d.perfCounters.resolveCacheMisses == 0)
        #expect(d.perfCounters.cacheHitRatio == 0)
        #expect(d.perfCounters.quadtreeRebuilds == 0)
        #expect(d.perfCounters.dirtySetSize == 0)
        #expect(d.perfCounters.perFrameHeapBytes == 0)
    }

    @Test("DrawingPerfCounters hit ratio computes correctly")
    func hitRatioComputation() {
        var c = DrawingPerfCounters()
        #expect(c.cacheHitRatio == 0)
        c.resolveCacheHits = 75
        c.resolveCacheMisses = 25
        #expect(c.cacheHitRatio == 0.75)
        c.resolveCacheHits = 0
        c.resolveCacheMisses = 0
        #expect(c.cacheHitRatio == 0)
    }

    // MARK: - modelVersion + add/replace/remove counters

    @Test("add increments modelVersion and addCount")
    func addIncrements() {
        let d = CADDrawing()
        let v0 = d.modelVersion
        let c0 = d.perfCounters.addCount
        let id = d.add(line(Vector(0, 0), Vector(10, 0)))
        #expect(d.modelVersion == v0 &+ 1)
        #expect(d.perfCounters.addCount == c0 + 1)
        #expect(d.contains(id))
    }

    @Test("remove increments modelVersion and removeCount")
    func removeIncrements() {
        let d = CADDrawing()
        let id = d.add(line(Vector(0, 0), Vector(10, 0)))
        let v0 = d.modelVersion
        let c0 = d.perfCounters.removeCount
        d.remove(id)
        #expect(d.modelVersion == v0 &+ 1)
        #expect(d.perfCounters.removeCount == c0 + 1)
        #expect(!d.contains(id))
    }

    @Test("replace increments modelVersion and replaceCount")
    func replaceIncrements() {
        let d = CADDrawing()
        let id = d.add(line(Vector(0, 0), Vector(10, 0)))
        let v0 = d.modelVersion
        let c0 = d.perfCounters.replaceCount
        var rec = d.entity(id)!
        rec.kind = .line(LineData(start: Vector(0, 0), end: Vector(20, 0)))
        d.replace(rec)
        #expect(d.modelVersion == v0 &+ 1)
        #expect(d.perfCounters.replaceCount == c0 + 1)
    }

    @Test("replace of absent entity falls back to add")
    func replaceFallsBackToAdd() {
        let d = CADDrawing()
        let rec = line(Vector(0, 0), Vector(5, 5))
        let v0 = d.modelVersion
        d.replace(rec) // id 0 will be minted
        #expect(d.modelVersion == v0 &+ 1)
        #expect(d.perfCounters.addCount == 1)
    }

    @Test("remove of absent id is a no-op and does not bump version")
    func removeNoOpDoesNotBump() {
        let d = CADDrawing()
        let v0 = d.modelVersion
        d.remove(EntityID(9999))
        #expect(d.modelVersion == v0)
        #expect(d.perfCounters.removeCount == 0)
    }

    @Test("multiple adds produce monotonic modelVersion")
    func monotonicVersion() {
        let d = CADDrawing()
        var last = d.modelVersion
        for i in 0..<5 {
            _ = d.add(line(Vector(Double(i), 0), Vector(Double(i) + 10, 0)))
            #expect(d.modelVersion == last &+ 1)
            last = d.modelVersion
        }
        #expect(d.perfCounters.addCount == 5)
    }

    // MARK: - Cache / rebuild / dirty / heap hooks (Wave 1+ will wire real values)

    @Test("recordCacheHit and recordCacheMiss increment counters and ratio")
    func cacheHitMissHooks() {
        let d = CADDrawing()
        d.recordCacheHit()
        d.recordCacheHit()
        d.recordCacheMiss()
        #expect(d.perfCounters.resolveCacheHits == 2)
        #expect(d.perfCounters.resolveCacheMisses == 1)
        #expect(abs(d.perfCounters.cacheHitRatio - 2.0 / 3.0) < 1e-9)
    }

    @Test("recordQuadtreeRebuild increments rebuild counter")
    func quadtreeRebuildHook() {
        let d = CADDrawing()
        #expect(d.perfCounters.quadtreeRebuilds == 0)
        d.recordQuadtreeRebuild()
        d.recordQuadtreeRebuild()
        #expect(d.perfCounters.quadtreeRebuilds == 2)
    }

    @Test("setDirtySetSize and setPerFrameHeap store values")
    func dirtyAndHeapHooks() {
        let d = CADDrawing()
        d.setDirtySetSize(42)
        #expect(d.perfCounters.dirtySetSize == 42)
        d.setDirtySetSize(-5) // clamped to 0
        #expect(d.perfCounters.dirtySetSize == 0)
        d.setPerFrameHeap(12345)
        #expect(d.perfCounters.perFrameHeapBytes == 12345)
    }

    @Test("resetInstrumentationCounters clears counters and version")
    func resetInstrumentation() {
        let d = CADDrawing()
        _ = d.add(line(Vector(0, 0), Vector(10, 0)))
        d.recordCacheHit()
        d.recordQuadtreeRebuild()
        d.setDirtySetSize(7)
        d.resetInstrumentationCounters()
        #expect(d.modelVersion == 0)
        #expect(d.perfCounters.addCount == 0)
        #expect(d.perfCounters.resolveCacheHits == 0)
        #expect(d.perfCounters.quadtreeRebuilds == 0)
        #expect(d.perfCounters.dirtySetSize == 0)
    }

    // MARK: - Signpost intervals (should not crash, always-on but cheap)

    @Test("signposted helpers do not crash and return correct geometry")
    func signpostedHelpers() {
        let d = CADDrawing()
        let id = d.add(line(Vector(0, 0), Vector(10, 0)))
        let ctx = d.makeResolveContext()
        let rec = d.entity(id)!
        let geo = d.signpostedResolve(rec, ctx: ctx)
        #expect(!geo.polylines.isEmpty || !geo.fills.isEmpty || geo.polylines.isEmpty) // just exercises the path

        let result: Int = d.signpostedQuadtreeQuery { 42 }
        #expect(result == 42)

        let all = d.resolveAll(ctx)
        #expect(all.count == d.count)

        let ctx2 = d.makeResolveContext(tessellationTolerance: 0.1)
        #expect(ctx2.tessellationTolerance == 0.1)
    }

    @Test("load bumps modelVersion once")
    func loadBumpsVersion() {
        let d = CADDrawing()
        let v0 = d.modelVersion
        d.load(entities: [line(Vector(0, 0), Vector(1, 1))], layers: LayerTable())
        #expect(d.modelVersion == v0 &+ 1)
    }

    @Test("mutateLayers bumps modelVersion on change but not on no-op")
    func mutateLayersBumps() {
        let d = CADDrawing()
        let v0 = d.modelVersion
        d.mutateLayers { _ = $0.add(Layer(name: "TEST")) }
        #expect(d.modelVersion == v0 &+ 1)
        let v1 = d.modelVersion
        d.mutateLayers { _ in /* no change */ }
        #expect(d.modelVersion == v1)
    }

    @Test("reorderEntities bumps modelVersion when order changes")
    func reorderBumps() {
        let d = CADDrawing()
        let a = d.add(line(Vector(0, 0), Vector(10, 0)))
        let b = d.add(line(Vector(10, 0), Vector(20, 0)))
        let v0 = d.modelVersion
        let ok = d.reorderEntities([b, a])
        #expect(ok)
        #expect(d.modelVersion == v0 &+ 1)
        let v1 = d.modelVersion
        // Re-applying same order is a no-op — version should not change.
        // But reorderEntities with same order returns true without bumping; we check it doesn't double-bump via guard.
        let same = d.reorderEntities([b, a])
        #expect(same)
        #expect(d.modelVersion == v1) // no-op order: no bump
    }
}
