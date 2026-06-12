//
//  ToolContextTests.swift
//  CADEngineTests
//
//  Tests for the widened `ToolContext` — the read-only document snapshot the app
//  hands every `Tool.handle` call. This file covers the boundary-finding hooks the
//  editing tools (Trim / Extend / Fillet) consume: `nearbyEntities(_:_:)` (other
//  entities within a WORLD tolerance of a picked point) and `allEntities()` (the
//  full snapshot), plus the defaults that keep the pre-existing draw/modify tools
//  and their tests compiling against the widened contract unchanged.
//
//  Suite names are domain-prefixed (`ToolContext…`) per CONVENTIONS.md so this
//  fan-out test file can't collide with another file's suite names at the
//  test-target namespace.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Boundary hooks (nearbyEntities / allEntities)

@Suite("ToolContext boundary hooks")
struct ToolContextBoundaryTests {

    /// A hand-built context whose boundary hooks scan a fixed set of records with
    /// the SAME exact-distance semantics the app's `makeToolContext` wires up
    /// (quadtree prefilter omitted — the closure can't hold the non-Sendable index;
    /// the exact `HitTesting.worldDistance` test is what makes a hit real). Building
    /// it here keeps the engine test target free of the app module while exercising
    /// the public `ToolContext` contract Trim/Extend/Fillet will consume.
    private static func context(over records: [EntityRecord]) -> ToolContext {
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ToolContext(
            selected: [],
            entity: { byID[$0] },
            gridSpacing: nil,
            nearbyEntities: { point, tolerance in
                guard point.valid else { return [] }
                let tol = Swift.max(tolerance, 0)
                return records.filter { r in
                    guard r.flags.contains(.visible) else { return false }
                    return HitTesting.worldDistance(from: point, to: r) <= tol
                }
            },
            allEntities: { records }
        )
    }

    /// Horizontal line (0,0)->(10,0), a far circle at (100,100) r=2, and a
    /// vertical line (5,-5)->(5,5) crossing the h-line at (5,0).
    private static func sampleRecords() -> (h: EntityRecord, v: EntityRecord, far: EntityRecord) {
        let h = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let v = EntityRecord(id: EntityID(2), kind: .line(LineData(start: Vector(5, -5), end: Vector(5, 5))))
        let far = EntityRecord(id: EntityID(3), kind: .circle(CircleData(center: Vector(100, 100), radius: 2)))
        return (h, v, far)
    }

    @Test("nearbyEntities returns entities near a point and excludes far ones")
    func nearbyNearAndFar() {
        let (h, v, far) = Self.sampleRecords()
        let ctx = Self.context(over: [h, v, far])

        // A pick right on the h-line near (3,0): only the h-line is within tol.
        let near = ctx.nearbyEntities(Vector(3, 0), 0.25)
        #expect(near.map(\.id).sorted { $0.rawValue < $1.rawValue } == [EntityID(1)])

        // The far circle (~140 units away) is never returned for a small aperture.
        #expect(!near.contains { $0.id == EntityID(3) })
    }

    @Test("nearbyEntities finds every boundary at a shared point")
    func nearbyShared() {
        let (h, v, far) = Self.sampleRecords()
        let ctx = Self.context(over: [h, v, far])

        // At the crossing (5,0) both the h-line and the v-line are within tol.
        let hits = ctx.nearbyEntities(Vector(5, 0), 0.1).map(\.id).sorted { $0.rawValue < $1.rawValue }
        #expect(hits == [EntityID(1), EntityID(2)])
        #expect(!hits.contains(EntityID(3)))
    }

    @Test("nearbyEntities respects the world tolerance (point above the line)")
    func nearbyTolerance() {
        let (h, v, far) = Self.sampleRecords()
        let ctx = Self.context(over: [h, v, far])

        // (2, 2): 2.0 above the h-line, 3.0 horizontal from the v-line (x=5), and
        // ~138 from the far circle. A 1.0 aperture misses everything…
        #expect(ctx.nearbyEntities(Vector(2, 2), 1.0).isEmpty)
        // …a 2.5 aperture catches ONLY the h-line (exact perpendicular distance 2.0;
        // the v-line at 3.0 and the circle stay out).
        #expect(ctx.nearbyEntities(Vector(2, 2), 2.5).map(\.id) == [EntityID(1)])
    }

    @Test("nearbyEntities skips hidden (non-visible) entities")
    func nearbySkipsHidden() {
        var h = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        h.flags.remove(.visible)             // hidden → not pickable as a boundary
        let ctx = Self.context(over: [h])
        #expect(ctx.nearbyEntities(Vector(3, 0), 0.25).isEmpty)
    }

    @Test("nearbyEntities returns [] for an invalid point or empty drawing")
    func nearbyDegenerate() {
        let (h, _, _) = Self.sampleRecords()
        #expect(Self.context(over: [h]).nearbyEntities(.invalid, 1.0).isEmpty)
        #expect(Self.context(over: []).nearbyEntities(Vector(3, 0), 1.0).isEmpty)
    }

    @Test("allEntities returns the full set in snapshot order")
    func allEntitiesFull() {
        let (h, v, far) = Self.sampleRecords()
        let ctx = Self.context(over: [h, v, far])
        #expect(ctx.allEntities().map(\.id) == [EntityID(1), EntityID(2), EntityID(3)])
    }
}

// MARK: - Defaults (existing tools / tests compile against the widened contract)

@Suite("ToolContext defaults")
struct ToolContextDefaultsTests {

    @Test("the empty context exposes empty boundary hooks")
    func emptyDefaults() {
        let ctx = ToolContext.empty
        #expect(ctx.nearbyEntities(Vector(0, 0), 100).isEmpty)
        #expect(ctx.allEntities().isEmpty)
        #expect(ctx.selected.isEmpty)
        #expect(ctx.entity(EntityID(1)) == nil)
        #expect(ctx.gridSpacing == nil)
    }

    @Test("the three-arg initializer still compiles (boundary hooks default to [])")
    func threeArgInitDefaults() {
        // This is exactly how the pre-existing tools/tests build a context; the new
        // params are defaulted, so old call sites keep compiling unchanged.
        let rec = EntityRecord(id: EntityID(7), kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(
            selected: [rec],
            entity: { _ in rec },
            gridSpacing: 5
        )
        #expect(ctx.selected.map(\.id) == [EntityID(7)])
        #expect(ctx.gridSpacing == 5)
        #expect(ctx.nearbyEntities(Vector(0, 0), 1).isEmpty)   // defaulted hook
        #expect(ctx.allEntities().isEmpty)                      // defaulted hook
    }

    @Test("a pre-existing MODIFY tool is unaffected by the widened context")
    func existingToolUnaffected() {
        // MoveTool ignores the new fields entirely: a base+destination click still
        // emits one `.replace` per selected entity, proving the widening is additive
        // and the old tools read only `selected` / `entity` / `gridSpacing`.
        let rec = EntityRecord(id: EntityID(42), kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let ctx = ToolContext(
            selected: [rec],
            entity: { $0 == EntityID(42) ? rec : nil },
            gridSpacing: nil
            // nearbyEntities / allEntities defaulted — MoveTool never reads them.
        )
        var tool = MoveTool()
        _ = tool.handle(.click(Vector(0, 0)), context: ctx)         // base point
        let outcome = tool.handle(.click(Vector(3, 4)), context: ctx) // destination
        guard case .commit(let edits) = outcome, edits.count == 1, case .replace(let id, _) = edits[0] else {
            Issue.record("MoveTool should commit one .replace through the widened context")
            return
        }
        #expect(id == EntityID(42))
    }
}
