//
//  ResolveCacheTests.swift
//  CADEngineTests
//
//  Wave 1 — Per-entity resolve cache (P1 / R3).
//  Pins the cache contract: hit on identical (id, version, pen, tolerance, kind),
//  miss on version bump, pen change, tolerance change, kind change, and that
//  CADDrawing bumps resolveVersion on add/replace and restores on undo.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("resolve cache (per-entity version + pen)")
struct ResolveCacheTests {

    // MARK: - Helpers

    private func arcRecord(id: UInt64 = 1, version: UInt64 = 0, pen: Pen = .byLayer) -> EntityRecord {
        EntityRecord(
            id: EntityID(id),
            pen: pen,
            kind: .arc(ArcData(center: Vector(0, 0), radius: 10, startAngle: 0, endAngle: .pi / 2)),
            resolveVersion: version
        )
    }

    private func lineRecord(id: UInt64 = 1, version: UInt64 = 0, pen: Pen = .byLayer) -> EntityRecord {
        EntityRecord(id: EntityID(id), pen: pen,
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))),
                     resolveVersion: version)
    }

    private func circleRecord(id: UInt64 = 1, version: UInt64 = 0, pen: Pen = .byLayer) -> EntityRecord {
        EntityRecord(id: EntityID(id), pen: pen,
                     kind: .circle(CircleData(center: Vector(0, 0), radius: 5)),
                     resolveVersion: version)
    }

    private var redPen: Pen {
        Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1)), lineType: .solid, lineWidth: .default)
    }
    private var bluePen: Pen {
        Pen(lineColor: .explicit(RGBAColor(0, 0, 1, 1)), lineType: .solid, lineWidth: .default)
    }

    // MARK: - Cache hit / miss (raw EntityRecord + sharedResolveCache)

    @Test("identical resolve hits the cache (second is a hit, geometry equal)")
    func cacheHit() {
        sharedResolveCache.clear()
        let ctx = ResolveContext(tessellationTolerance: 0.05)
        let rec = arcRecord(version: 0)

        let g1 = rec.resolve(ctx)
        #expect(sharedResolveCache.misses == 1)
        #expect(sharedResolveCache.hits == 0)
        #expect(sharedResolveCache.count == 1)

        let g2 = rec.resolve(ctx)
        #expect(sharedResolveCache.misses == 1)
        #expect(sharedResolveCache.hits == 1)
        #expect(g1 == g2)
        // The cached geometry must equal the uncached computation.
        let fresh = rec.resolveUncached(ctx)
        #expect(g1 == fresh)
    }

    @Test("different resolveVersion misses (bump invalidates)")
    func versionBumpMisses() {
        sharedResolveCache.clear()
        let ctx = ResolveContext(tessellationTolerance: 0.05)
        let recV0 = arcRecord(version: 0)
        _ = recV0.resolve(ctx)
        #expect(sharedResolveCache.misses == 1)

        _ = recV0.resolve(ctx)
        #expect(sharedResolveCache.hits == 1)

        let recV1 = arcRecord(version: 1) // same id, bumped version
        let g3 = recV1.resolve(ctx)
        #expect(sharedResolveCache.misses == 2)
        #expect(sharedResolveCache.hits == 1)
        // Version bump still yields same geometric shape (kind unchanged) but is a miss.
        #expect(g3 == recV0.resolveUncached(ctx))

        _ = recV1.resolve(ctx)
        #expect(sharedResolveCache.hits == 2)
    }

    @Test("different ResolvedPen misses (pen is part of the key)")
    func differentPenMisses() {
        sharedResolveCache.clear()
        let ctx = ResolveContext(tessellationTolerance: 0.05)
        let recRed = arcRecord(pen: redPen)
        let recBlue = arcRecord(pen: bluePen)

        _ = recRed.resolve(ctx)
        #expect(sharedResolveCache.misses == 1)
        _ = recRed.resolve(ctx)
        #expect(sharedResolveCache.hits == 1)

        // Same id/version but different pen → miss (old entry overwritten).
        _ = recBlue.resolve(ctx)
        #expect(sharedResolveCache.misses == 2)
        #expect(sharedResolveCache.hits == 1)

        // Re-resolving the red pen now is again a miss because the slot holds blue.
        _ = recRed.resolve(ctx)
        #expect(sharedResolveCache.misses == 3)
    }

    @Test("different tolerance misses")
    func differentToleranceMisses() {
        sharedResolveCache.clear()
        let rec = arcRecord()
        let ctxA = ResolveContext(tessellationTolerance: 0.05)
        let ctxB = ResolveContext(tessellationTolerance: 0.5)

        _ = rec.resolve(ctxA)
        #expect(sharedResolveCache.misses == 1)
        _ = rec.resolve(ctxA)
        #expect(sharedResolveCache.hits == 1)

        _ = rec.resolve(ctxB)
        #expect(sharedResolveCache.misses == 2)
        // A and B produce different segment counts, so geometries differ.
        let gA = rec.resolveUncached(ctxA)
        let gB = rec.resolveUncached(ctxB)
        #expect(gA != gB)
    }

    @Test("different kind misses (defensive cross-drawing id reuse)")
    func differentKindMisses() {
        sharedResolveCache.clear()
        let ctx = ResolveContext(tessellationTolerance: 0.05)
        let line = lineRecord(version: 0)
        let circle = circleRecord(version: 0) // same id, same version, different kind

        _ = line.resolve(ctx)
        #expect(sharedResolveCache.misses == 1)
        _ = circle.resolve(ctx)
        #expect(sharedResolveCache.misses == 2)
        #expect(sharedResolveCache.hits == 0)
    }

    @Test("remove evicts the entry")
    func removeEvicts() {
        sharedResolveCache.clear()
        let ctx = ResolveContext(tessellationTolerance: 0.05)
        let rec = arcRecord(id: 42)
        _ = rec.resolve(ctx)
        #expect(sharedResolveCache.count == 1)
        sharedResolveCache.remove(id: EntityID(42))
        #expect(sharedResolveCache.count == 0)
        _ = rec.resolve(ctx)
        #expect(sharedResolveCache.misses == 2) // miss again after eviction
    }

    @Test("clear resets hits/misses/count")
    func clearResets() {
        sharedResolveCache.clear()
        let rec = arcRecord()
        _ = rec.resolve()
        #expect(sharedResolveCache.count == 1)
        #expect(sharedResolveCache.misses == 1)
        sharedResolveCache.clear()
        #expect(sharedResolveCache.count == 0)
        #expect(sharedResolveCache.hits == 0)
        #expect(sharedResolveCache.misses == 0)
    }

    // MARK: - CADDrawing version bump (add / replace / undo)

    @Test("CADDrawing.add bumps resolveVersion to 1")
    @MainActor
    func addBumpsVersion() {
        sharedResolveCache.clear()
        let d = CADDrawing()
        let rec = EntityRecord(id: .placeholder,
                               kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        #expect(rec.resolveVersion == 0)
        let id = d.add(rec)
        let stored = d.entity(id)
        #expect(stored?.resolveVersion == 1)
        #expect(d.resolveVersion(for: id) == 1)
    }

    @Test("CADDrawing.replace bumps version exactly once")
    @MainActor
    func replaceBumpsVersion() {
        sharedResolveCache.clear()
        let d = CADDrawing()
        let id = d.add(EntityRecord(id: .placeholder,
                                    kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))))
        #expect(d.resolveVersion(for: id) == 1)
        var rec = d.entity(id)!
        rec.kind = .line(LineData(start: Vector(0, 0), end: Vector(2, 0)))
        // rec still carries version 1 (the stored version); replace should bump to 2.
        d.replace(rec)
        #expect(d.resolveVersion(for: id) == 2)
        // Second replace with a fresh copy (version 2) should bump to 3.
        var rec2 = d.entity(id)!
        rec2.kind = .line(LineData(start: Vector(0, 0), end: Vector(3, 0)))
        d.replace(rec2)
        #expect(d.resolveVersion(for: id) == 3)
    }

    @Test("CADDrawing.replace with explicit bumped version does not double-bump")
    @MainActor
    func replaceExplicitVersionNoDoubleBump() {
        sharedResolveCache.clear()
        let d = CADDrawing()
        let id = d.add(EntityRecord(id: .placeholder,
                                    kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))))
        #expect(d.resolveVersion(for: id) == 1)
        var rec = d.entity(id)!
        rec.resolveVersion = 2 // caller pre-bumps
        rec.kind = .line(LineData(start: Vector(0, 0), end: Vector(5, 0)))
        d.replace(rec)
        #expect(d.resolveVersion(for: id) == 2) // not 3
    }

    @Test("CADDrawing replace is undoable and restores version")
    @MainActor
    func replaceUndoRestoresVersion() {
        sharedResolveCache.clear()
        let d = CADDrawing()
        let id = d.add(EntityRecord(id: .placeholder,
                                    kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))))
        #expect(d.resolveVersion(for: id) == 1)

        let um = UndoManager()
        um.groupsByEvent = false
        d.undoManager = um
        um.beginUndoGrouping()
        var rec = d.entity(id)!
        rec.kind = .line(LineData(start: Vector(0, 0), end: Vector(9, 0)))
        d.replace(rec)
        um.endUndoGrouping()
        #expect(d.resolveVersion(for: id) == 2)

        um.undo()
        #expect(d.resolveVersion(for: id) == 1)
        if case .line(let ld) = d.entity(id)?.kind {
            #expect(ld.end == Vector(1, 0))
        } else {
            Issue.record("expected line after undo")
        }

        um.redo()
        #expect(d.resolveVersion(for: id) == 2)
    }

    @Test("CADDrawing.remove evicts cache entry")
    @MainActor
    func drawingRemoveEvictsCache() {
        sharedResolveCache.clear()
        let d = CADDrawing()
        let id = d.add(EntityRecord(id: .placeholder,
                                    kind: .circle(CircleData(center: Vector(0, 0), radius: 5))))
        let rec = d.entity(id)!
        _ = rec.resolve()
        #expect(sharedResolveCache.count == 1)
        d.remove(id)
        #expect(sharedResolveCache.count == 0)
        #expect(d.resolveVersion(for: id) == nil)
    }

    @Test("resolveVersion is Codable (round-trips, old files decode to 0)")
    func codableRoundTrip() throws {
        let rec = EntityRecord(id: EntityID(99),
                               kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))),
                               resolveVersion: 7)
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(EntityRecord.self, from: data)
        #expect(decoded.resolveVersion == 7)
        #expect(decoded.id == rec.id)

        // Old payload without resolveVersion decodes to 0 — simulate by encoding
        // then stripping the key, preserving the correct EntityID shape.
        let encoded = try JSONEncoder().encode(rec)
        var obj = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        obj.removeValue(forKey: "resolveVersion")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let old = try JSONDecoder().decode(EntityRecord.self, from: stripped)
        #expect(old.resolveVersion == 0)
    }

    @Test("cachedResolve free functions hit the same shared cache")
    func cachedResolveFreeFunction() {
        sharedResolveCache.clear()
        // Use an explicit pen so the pen-aware overload hits the same entry.
        let rec = arcRecord(version: 5, pen: redPen)
        let ctx = ResolveContext(tessellationTolerance: 0.05)
        let g1 = cachedResolve(for: rec, ctx: ctx)
        #expect(sharedResolveCache.misses == 1)
        let g2 = cachedResolve(for: rec, ctx: ctx)
        #expect(sharedResolveCache.hits == 1)
        #expect(g1 == g2)

        // Pen-aware overload with the SAME resolved pen should be a hit.
        let pen = redPen.resolved(layer: rec.layer, in: ctx)
        let g3 = cachedResolve(for: rec, pen: pen, ctx: ctx)
        #expect(sharedResolveCache.hits == 2)
        #expect(g3 == g1)

        // Different pen should be a miss.
        let blueResolved = bluePen.resolved(layer: rec.layer, in: ctx)
        let g4 = cachedResolve(for: rec, pen: blueResolved, ctx: ctx)
        #expect(sharedResolveCache.misses == 2)
        #expect(g4.polylines[0].pen != g1.polylines[0].pen)
    }
}
