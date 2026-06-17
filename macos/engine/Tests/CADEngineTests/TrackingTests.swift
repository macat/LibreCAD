//
//  TrackingTests.swift
//  CADEngineTests
//
//  Unit tests for the pure object-snap-tracking (OTRACK) geometry kernel
//  (`Tracking`): guide generation from acquired points (horizontal / vertical /
//  polar rays), the straight-line extension guide, and cursor resolution
//  (single-guide projection vs. two-guide intersection, with intersection taking
//  precedence). Also asserts the critical edge cases: parallel guides yield an
//  empty `VectorSolutions` so resolution falls through to the nearest single guide
//  (no crash / no bogus intersection), and a cursor outside tolerance returns nil.
//
//  All cases are pure engine math — no NSView, no document, no modal.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("CADEngine OTRACK tracking kernel")
struct TrackingTests {

    private let eps = 1e-9
    private let deg15 = Double.pi / 12

    // MARK: - Helpers

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
        abs(a - b) <= tol
    }

    private func approx(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        a.valid && b.valid && abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
    }

    // MARK: - guides(from:)

    @Test("guides: one point produces H + V + polar rays, all originating at the point")
    func guidesOnePoint() {
        let p = Vector(3, 7)
        let ap = AcquiredPoint(point: p, kind: .endpoint, sourceEntity: EntityID(42))
        let gs = Tracking.guides(from: [ap], polarIncrement: deg15)

        // Every guide originates at the acquired point and carries the source.
        for g in gs {
            #expect(approx(g.origin, p))
            #expect(g.sourceEntity == EntityID(42))
        }

        // Exactly one horizontal and one vertical guide, with the canonical dirs.
        let hs = gs.filter { $0.kind == .horizontal }
        let vs = gs.filter { $0.kind == .vertical }
        #expect(hs.count == 1)
        #expect(vs.count == 1)
        #expect(approx(hs[0].direction, Vector(1, 0)))
        #expect(approx(vs[0].direction, Vector(0, 1)))

        // Polar rays exist; for a 15° increment over 360° there are 24 multiples,
        // of which 0/90/180/270 coincide with H/V and are dropped → 20 polar rays.
        let polars = gs.filter {
            if case .polar = $0.kind { return true }
            return false
        }
        #expect(polars.count == 20)

        // A 30° polar ray must be present with the right unit direction.
        let thirty = polars.first {
            if case let .polar(a) = $0.kind { return approx(a, 2 * deg15, 1e-6) }
            return false
        }
        #expect(thirty != nil)
        if let t = thirty {
            #expect(approx(t.direction, Vector(angle: 2 * deg15)))
        }
    }

    @Test("guides: non-positive increment emits only H + V")
    func guidesNoPolar() {
        let ap = AcquiredPoint(point: Vector(0, 0), kind: .center)
        let gs = Tracking.guides(from: [ap], polarIncrement: 0)
        #expect(gs.count == 2)
        #expect(gs.contains { $0.kind == .horizontal })
        #expect(gs.contains { $0.kind == .vertical })
    }

    @Test("guides: two points produce two H/V families with distinct origins")
    func guidesTwoPoints() {
        let a = AcquiredPoint(point: Vector(0, 0), kind: .endpoint)
        let b = AcquiredPoint(point: Vector(10, 5), kind: .endpoint)
        let gs = Tracking.guides(from: [a, b], polarIncrement: 0)
        // H + V for each of the two points.
        #expect(gs.count == 4)
        #expect(gs.filter { approx($0.origin, Vector(0, 0)) }.count == 2)
        #expect(gs.filter { approx($0.origin, Vector(10, 5)) }.count == 2)
    }

    // MARK: - resolve: single guide

    @Test("resolve: cursor near a horizontal guide locks onto it (y == origin.y)")
    func resolveSingleHorizontal() {
        let origin = Vector(0, 0)
        let gs = Tracking.guides(from: [AcquiredPoint(point: origin, kind: .endpoint)],
                                 polarIncrement: 0) // H + V only
        // Cursor at (5, 0.01): close to the horizontal guide, far from vertical.
        let cursor = Vector(5, 0.01)
        let r = Tracking.resolve(guides: gs, cursor: cursor, worldTolerance: 0.1)
        #expect(r != nil)
        guard let r else { return }
        // Locked onto the horizontal guide → y collapses to the origin's y.
        #expect(approx(r.point.y, 0))
        #expect(approx(r.point.x, 5))
        #expect(r.lockedGuides.count == 1)
        #expect(r.lockedGuides[0].kind == .horizontal)
        // distance from origin to the locked point == 5; angle == 0.
        #expect(approx(r.distance, 5))
        #expect(approx(r.angle, 0, 1e-6))
    }

    // MARK: - resolve: intersection precedence

    @Test("resolve: H-of-one ∩ V-of-other returns the intersection (precedence over single)")
    func resolveIntersection() {
        // Acquired points: A at (0,0), B at (10,5).
        // Horizontal of A is the line y=0; vertical of B is the line x=10.
        // Their intersection is (10, 0).
        let a = AcquiredPoint(point: Vector(0, 0), kind: .endpoint, sourceEntity: EntityID(1))
        let b = AcquiredPoint(point: Vector(10, 5), kind: .endpoint, sourceEntity: EntityID(2))
        let gs = Tracking.guides(from: [a, b], polarIncrement: 0)
        // Cursor near (10, 0): close to BOTH H-of-A (y≈0) and V-of-B (x≈10).
        let cursor = Vector(10.02, 0.02)
        let r = Tracking.resolve(guides: gs, cursor: cursor, worldTolerance: 0.1)
        #expect(r != nil)
        guard let r else { return }
        #expect(approx(r.point, Vector(10, 0), 1e-6))
        // Two locked guides → an intersection lock.
        #expect(r.lockedGuides.count == 2)
    }

    // MARK: - resolve: parallel guides (empty VectorSolutions) → single fallback

    @Test("resolve: two parallel horizontals → no intersection, falls to nearest single (no crash)")
    func resolveParallelFallthrough() {
        // Two horizontal guides at different y; they never cross.
        let a = AcquiredPoint(point: Vector(0, 0), kind: .endpoint)
        let b = AcquiredPoint(point: Vector(0, 1), kind: .endpoint)
        // Take only the horizontal guides (drop verticals) so the two near guides
        // are guaranteed parallel.
        let gs = Tracking.guides(from: [a, b], polarIncrement: 0)
            .filter { $0.kind == .horizontal }
        #expect(gs.count == 2)
        // Cursor just above y=0: nearest to the y=0 horizontal, second-nearest to
        // the y=1 horizontal (both within a generous tolerance → parallel pair).
        let cursor = Vector(4, 0.05)
        let r = Tracking.resolve(guides: gs, cursor: cursor, worldTolerance: 2.0)
        #expect(r != nil)
        guard let r else { return }
        // Parallel pair → empty VectorSolutions → single-guide lock on the nearest
        // (y == 0), NOT a bogus intersection.
        #expect(r.lockedGuides.count == 1)
        #expect(approx(r.point.y, 0))
        #expect(approx(r.point.x, 4))
    }

    // MARK: - extensionGuide

    @Test("extensionGuide: direction == unit(carrier); a cursor along the extension locks")
    func extensionGuideLock() {
        // A line from (0,0) to (10,0); extension past the (10,0) endpoint.
        let start = Vector(0, 0)
        let end = Vector(10, 0)
        let carrier = end - start            // (10, 0), not unit
        let g = Tracking.extensionGuide(endpoint: end, carrierDir: carrier, entity: EntityID(7))
        #expect(g.kind == .extension_)
        #expect(g.sourceEntity == EntityID(7))
        #expect(approx(g.origin, end))
        // Stored direction must be the UNIT carrier.
        #expect(approx(g.direction, Vector(1, 0)))

        // A cursor a bit past the endpoint, slightly off the line, locks onto the
        // extension ray (projects back onto y == 0).
        let cursor = Vector(15, 0.02)
        let r = Tracking.resolve(guides: [g], cursor: cursor, worldTolerance: 0.1)
        #expect(r != nil)
        guard let r else { return }
        #expect(approx(r.point, Vector(15, 0), 1e-6))
        #expect(r.lockedGuides.count == 1)
        #expect(r.lockedGuides[0].kind == .extension_)
    }

    @Test("extensionGuide: degenerate carrier yields an invalid direction")
    func extensionGuideDegenerate() {
        let g = Tracking.extensionGuide(endpoint: Vector(1, 1), carrierDir: Vector(0, 0), entity: nil)
        #expect(g.direction.valid == false)
        // A guide with an invalid direction is skipped by resolve → nil.
        let r = Tracking.resolve(guides: [g], cursor: Vector(2, 2), worldTolerance: 1.0)
        #expect(r == nil)
    }

    // MARK: - resolve: tolerance miss

    @Test("resolve: cursor outside tolerance of every guide returns nil")
    func resolveToleranceMiss() {
        let gs = Tracking.guides(from: [AcquiredPoint(point: Vector(0, 0), kind: .endpoint)],
                                 polarIncrement: 0) // H + V at the origin
        // Cursor at (5, 5): perpendicular distance 5 from both the H and V guides.
        let cursor = Vector(5, 5)
        let r = Tracking.resolve(guides: gs, cursor: cursor, worldTolerance: 0.1)
        #expect(r == nil)
    }

    @Test("resolve: no guides returns nil")
    func resolveNoGuides() {
        let r = Tracking.resolve(guides: [], cursor: Vector(1, 1), worldTolerance: 1.0)
        #expect(r == nil)
    }
}
