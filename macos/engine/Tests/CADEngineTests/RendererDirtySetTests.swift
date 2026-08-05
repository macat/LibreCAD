//
//  RendererDirtySetTests.swift
//  CADEngineTests
//
//  Wave P5 — Renderer dirty-set (perf-arch-review-plan.md P5).
//  Proves that the incremental `rebuildDirty` path is byte-identical to
//  a full rebuild for single/multi edits and that fallback is correct.
//
//  CADEngine-only: uses the pure `RendererGeometry` (via _Shared symlink)
//  and the `DirtySet` helper. No CanvasModel / AppKit / Metal.

import Testing
import CADEngine
import simd
import CoreGraphics

@Suite("Renderer dirty-set — incremental rebuild")
@MainActor
struct RendererDirtySetTests {

    // MARK: - Helpers

    private func makeLine(_ a: Vector, _ b: Vector, layer: String = "0") -> EntityRecord {
        EntityRecord(id: .placeholder, layer: LayerID(layer), pen: .byLayer, flags: .default,
                     kind: .line(LineData(start: a, end: b)))
    }

    private func makeCircle(center: Vector, radius: Double) -> EntityRecord {
        EntityRecord(id: .placeholder, layer: LayerID("0"), pen: .byLayer, flags: .default,
                     kind: .circle(CircleData(center: center, radius: radius)))
    }

    private func drawingWithLines(count: Int) -> (CADDrawing, [EntityID]) {
        let d = CADDrawing()
        var ids: [EntityID] = []
        for i in 0..<count {
            let id = d.add(makeLine(Vector(Double(i) * 10, 0), Vector(Double(i) * 10 + 5, 5)))
            ids.append(id)
        }
        return (d, ids)
    }

    private func ctx() -> ResolveContext { .default }
    private var origin: Vector { Vector(0, 0) }
    private var layers: LayerTable { LayerTable() }
    private var halfWidth: Float { RendererGeometry.defaultHalfWidthPx }
    private var backing: CGFloat { 1 }
    private var colorXf: (SIMD4<Float>) -> SIMD4<Float> { { $0 } }

    private func orderedIDs(for drawing: CADDrawing) -> [EntityID] {
        drawing.entities.map(\.id).sorted { (drawing.storageIndex(of: $0) ?? 0) < (drawing.storageIndex(of: $1) ?? 0) }
    }

    // MARK: - DirtySet helper tests

    @Test("DirtySet empty should fallback on first frame")
    func emptyFirstFrameFallback() {
        let ds = DirtySet(ids: [], generation: 0)
        #expect(ds.shouldFallback(visibleCount: 10, isFirstFrame: true) == true)
    }

    @Test("DirtySet empty should fallback even when not first frame")
    func emptyNotFirstFrameFallback() {
        let ds = DirtySet(ids: [], generation: 1)
        #expect(ds.shouldFallback(visibleCount: 10, isFirstFrame: false) == true)
    }

    @Test("DirtySet single dirty among many should not fallback")
    func singleDirtyNoFallback() {
        let id = EntityID(1)
        let ds = DirtySet(ids: [id], generation: 1)
        #expect(ds.shouldFallback(visibleCount: 10, isFirstFrame: false) == false)
    }

    @Test("DirtySet oversized (>50%) should fallback")
    func oversizedFallback() {
        var ids = Set<EntityID>()
        for i in 1...6 { ids.insert(EntityID(UInt64(i))) }
        let ds = DirtySet(ids: ids, generation: 1)
        #expect(ds.shouldFallback(visibleCount: 10, isFirstFrame: false) == true)
    }

    @Test("DirtySet computeDirty finds replaced entity")
    func computeDirtySingleReplace() {
        let (d, ids) = drawingWithLines(count: 5)
        let ordered = orderedIDs(for: d)
        // Simulate a prior build cache.
        var lastVersions: [EntityID: UInt64] = [:]
        for id in ids { lastVersions[id] = d.resolveVersion(for: id) ?? 0 }
        let lastVisible = Set(ids)

        // Replace one entity.
        var rec = d.entity(ids[2])!
        rec.kind = .line(LineData(start: Vector(999, 999), end: Vector(1000, 1000)))
        d.replace(rec)

        let dirty = DirtySet.computeDirty(drawing: d, visibleIDs: Set(ordered), lastVersions: lastVersions, lastVisible: lastVisible)
        #expect(dirty.ids.contains(ids[2]))
        #expect(dirty.ids.count == 1)
    }

    @Test("DirtySet computeDirty finds new entity")
    func computeDirtyNewEntity() {
        let (d, ids) = drawingWithLines(count: 3)
        let orderedBefore = orderedIDs(for: d)
        var lastVersions: [EntityID: UInt64] = [:]
        for id in ids { lastVersions[id] = d.resolveVersion(for: id) ?? 0 }
        let lastVisible = Set(ids)

        let newID = d.add(makeLine(Vector(100, 100), Vector(200, 200)))
        let orderedAfter = orderedIDs(for: d)

        let dirty = DirtySet.computeDirty(drawing: d, visibleIDs: Set(orderedAfter), lastVersions: lastVersions, lastVisible: lastVisible)
        #expect(dirty.ids.contains(newID))
        // The new entity should be dirty; existing unchanged should not be (except the new one).
        #expect(dirty.ids.count == 1)
        _ = orderedBefore // silence
    }

    // MARK: - Incremental vs full (lines)

    @Test("Single-entity edit: dirty rebuild equals full rebuild (lines)")
    func singleEntityDirtyEqualsFull() {
        let (d, ids) = drawingWithLines(count: 10)
        let ordered = orderedIDs(for: d)
        var cache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]

        // Initial full build to populate cache.
        let initial = RendererGeometry.fullRebuild(
            visibleIDs: ordered,
            lookup: { d.entity($0) },
            ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache)
        #expect(initial.lineInstances.count > 0)

        // Edit one entity.
        var rec = d.entity(ids[3])!
        rec.kind = .line(LineData(start: Vector(500, 500), end: Vector(600, 600)))
        d.replace(rec)

        // Compute dirty.
        let lastVersions = Dictionary(uniqueKeysWithValues: cache.map { ($0.key, $0.value.version) })
        // The cache's versions are stale for the edited id; computeDirty will find it.
        // We need lastVisible = set of previous ordered.
        let dirtySet = DirtySet.computeDirty(drawing: d, visibleIDs: Set(ordered), lastVersions: lastVersions, lastVisible: Set(ordered))
        #expect(dirtySet.ids.contains(ids[3]))

        // Dirty rebuild.
        var cacheForDirty = cache
        let dirtyResult = RendererGeometry.rebuildDirty(
            visibleIDs: ordered,
            dirtyIDs: dirtySet.ids,
            lookup: { d.entity($0) },
            ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cacheForDirty)

        // Reference full rebuild (fresh cache).
        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered,
            lookup: { d.entity($0) },
            ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)

        #expect(dirtyResult.didFallback == false)
        #expect(dirtyResult.lineInstances == reference.lineInstances)
        #expect(dirtyResult.fillVerts == reference.fillVerts)
        #expect(dirtyResult.wipeoutVerts == reference.wipeoutVerts)
        // Dirty ranges should be small (one entity's instances).
        let total = reference.lineInstances.count
        let dirtyCount = dirtyResult.dirtyLineRanges.reduce(0) { $0 + $1.count }
        #expect(dirtyCount > 0)
        #expect(dirtyCount * 2 < total || total < 10) // incremental: dirty < half for 10 lines

        // Also verify referenceInstances helper matches.
        let ref2 = RendererGeometry.referenceInstances(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf)
        #expect(ref2 == reference.lineInstances)
    }

    @Test("Multi-entity edit: dirty rebuild equals full rebuild")
    func multiEntityDirtyEqualsFull() {
        let (d, ids) = drawingWithLines(count: 12)
        let ordered = orderedIDs(for: d)
        var cache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        _ = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache)

        // Edit 3 entities.
        for idx in [1, 4, 7] {
            var rec = d.entity(ids[idx])!
            rec.kind = .line(LineData(start: Vector(Double(idx)*100, Double(idx)*100),
                                      end: Vector(Double(idx)*100+10, Double(idx)*100+10)))
            d.replace(rec)
        }

        let lastVersions = Dictionary(uniqueKeysWithValues: cache.map { ($0.key, $0.value.version) })
        let dirtySet = DirtySet.computeDirty(drawing: d, visibleIDs: Set(ordered), lastVersions: lastVersions, lastVisible: Set(ordered))
        #expect(dirtySet.ids.count == 3)

        var cacheForDirty = cache
        let dirtyResult = RendererGeometry.rebuildDirty(
            visibleIDs: ordered, dirtyIDs: dirtySet.ids,
            lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cacheForDirty)

        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)

        #expect(dirtyResult.didFallback == false)
        #expect(dirtyResult.lineInstances == reference.lineInstances)
    }

    @Test("First frame fallback produces same result as full")
    func firstFrameFallback() {
        let (d, _) = drawingWithLines(count: 6)
        let ordered = orderedIDs(for: d)
        var emptyCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let dirtyIDs: Set<EntityID> = [EntityID(999)] // arbitrary, cache empty forces fallback
        let result = RendererGeometry.rebuildDirty(
            visibleIDs: ordered, dirtyIDs: dirtyIDs,
            lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &emptyCache)
        #expect(result.didFallback == true)

        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)
        #expect(result.lineInstances == reference.lineInstances)
    }

    @Test("Empty dirty falls back to full rebuild")
    func emptyDirtyFallback() {
        let (d, _) = drawingWithLines(count: 5)
        let ordered = orderedIDs(for: d)
        var cache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        _ = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache)

        let emptyDirty: Set<EntityID> = []
        var cache2 = cache
        let result = RendererGeometry.rebuildDirty(
            visibleIDs: ordered, dirtyIDs: emptyDirty,
            lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache2)
        #expect(result.didFallback == true)

        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)
        #expect(result.lineInstances == reference.lineInstances)
    }

    @Test("Oversized dirty falls back to full rebuild")
    func oversizedDirtyFallback() {
        let (d, _) = drawingWithLines(count: 10)
        let ordered = orderedIDs(for: d)
        var cache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        _ = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache)

        // Dirty 6 out of 10 (>50%) should fallback.
        let dirty = Set(ordered.prefix(6))
        var cache2 = cache
        let result = RendererGeometry.rebuildDirty(
            visibleIDs: ordered, dirtyIDs: dirty,
            lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin, layers: layers,
            activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache2)
        #expect(result.didFallback == true)

        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)
        #expect(result.lineInstances == reference.lineInstances)
    }

    @Test("Floating-origin offset preserved in dirty rebuild")
    func floatingOriginPreserved() {
        let (d, _) = drawingWithLines(count: 4)
        let ordered = orderedIDs(for: d)
        let bigOrigin = Vector(1_000_000, 2_000_000)
        var cache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        _ = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: bigOrigin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache)

        // Edit one.
        let firstID = ordered[1]
        var rec = d.entity(firstID)!
        rec.kind = .line(LineData(start: Vector(1_000_010, 2_000_010), end: Vector(1_000_020, 2_000_020)))
        d.replace(rec)

        let lastVersions = Dictionary(uniqueKeysWithValues: cache.map { ($0.key, $0.value.version) })
        let dirtySet = DirtySet.computeDirty(drawing: d, visibleIDs: Set(ordered), lastVersions: lastVersions, lastVisible: Set(ordered))

        var cacheForDirty = cache
        let dirtyResult = RendererGeometry.rebuildDirty(
            visibleIDs: ordered, dirtyIDs: dirtySet.ids,
            lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: bigOrigin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cacheForDirty)

        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: bigOrigin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)

        #expect(dirtyResult.lineInstances == reference.lineInstances)
        // Spot-check that the edited line's offsets are small (floating origin).
        // The edited line's points are near the origin, so its offsets should be small;
        // unchanged lines remain far, but their offsets are still correctly computed.
        // This check validates that the dirty path preserves the origin subtraction.
        let editedDirtyInstances = dirtyResult.lineInstances.filter { inst in
            // The edited line is the only one with p0 near (10,10) after offset.
            abs(inst.p0.x - 10) < 1 && abs(inst.p0.y - 10) < 1
        }
        #expect(!editedDirtyInstances.isEmpty)
    }

    @Test("Add and remove: dirty rebuild equals full")
    func addRemoveDirtyEqualsFull() {
        let (d, ids) = drawingWithLines(count: 5)
        var ordered = orderedIDs(for: d)
        var cache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        _ = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cache)

        // Remove one, add one.
        d.remove(ids[0])
        let newID = d.add(makeLine(Vector(777, 777), Vector(888, 888)))
        ordered = orderedIDs(for: d)
        // After remove/add, ordered changed.
        let lastVersions = Dictionary(uniqueKeysWithValues: cache.map { ($0.key, $0.value.version) })
        let dirtySet = DirtySet.computeDirty(drawing: d, visibleIDs: Set(ordered), lastVersions: lastVersions, lastVisible: Set(ids))
        #expect(dirtySet.ids.contains(newID))

        var cacheForDirty = cache
        // Note: removed id is no longer in ordered, but dirtySet contains it for fallback accounting.
        // Dirty rebuild's dirtyIDs should be intersection with visible, so we pass visible intersection.
        let visibleDirty = dirtySet.ids.intersection(Set(ordered))
        let dirtyResult = RendererGeometry.rebuildDirty(
            visibleIDs: ordered, dirtyIDs: visibleDirty,
            lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &cacheForDirty)

        var freshCache: [EntityID: RendererGeometry.CachedEntityGeometry] = [:]
        let reference = RendererGeometry.fullRebuild(
            visibleIDs: ordered, lookup: { d.entity($0) }, ctx: ctx(), renderOrigin: origin,
            layers: layers, activeSpace: .model, activeLayout: nil, blockMembers: [],
            halfWidthPx: halfWidth, backingScale: backing, colorTransform: colorXf, cache: &freshCache)

        #expect(dirtyResult.lineInstances == reference.lineInstances)
    }
}
