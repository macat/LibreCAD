//
//  EntityRegistryTests.swift
//  CADEngineTests
//
//  Wave 5 — EntityKind open registry (perf-arch-review-plan.md Wave 5, A3).
//  Proves that adding a new EntityKind is now an "add file + extend factory"
//  task, not a 22-file atomic arm: `Resolve.swift` and `EntityTransform.swift`
//  dispatch via `kind.resolver` (the ONLY exhaustive switch lives in
//  `Entity.swift:EntityKind.resolver`), so a new kind's resolver can be added
//  without touching those files.
//
//  Tests:
//    - every existing kind resolves/bounds/transforms via the registry (spot checks)
//    - a stub `TestStubResolver` resolves without touching Resolve/Transform
//    - unknown/fallback produces empty geometry (the open-registry fallback)
//    - transform via registry matches the legacy per-helpers
//

import Testing
import Foundation
@testable import CADEngine

private let registryPen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
private let registryCtx = ResolveContext.default

@Suite("EntityKind open registry (Wave 5)")
struct EntityRegistryTests {

    // MARK: - Registry dispatch for existing kinds (spot checks)

    @Test("line resolves via registry — 2-point polyline")
    func lineViaRegistry() {
        let data = LineData(start: Vector(0, 0), end: Vector(10, 5))
        let kind = EntityKind.line(data)
        // Via the registry factory:
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].points == [Vector(0, 0), Vector(10, 5)])
        #expect(geo.polylines[0].closed == false)
        // The top-level `kind.resolve` now dispatches via the same registry:
        let geo2 = kind.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo2 == geo)
    }

    @Test("circle resolves via registry — closed ring")
    func circleViaRegistry() {
        let data = CircleData(center: Vector(5, 5), radius: 10)
        let kind = EntityKind.circle(data)
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].closed == true)
        #expect(geo.polylines[0].points.count >= 3)
        // BoundingBox via registry matches analytic r-box:
        let box = kind.resolver.boundingBox()
        #expect(box.min.x ==  -5) // center 5 - r 10
        #expect(box.max.x ==  15)
        #expect(box.min.y ==  -5)
        #expect(box.max.y ==  15)
        // Context-aware bbox is same for circle (no font/provider):
        let boxCtx = kind.resolver.boundingBox(ctx: registryCtx)
        #expect(boxCtx == box)
    }

    @Test("arc boundingBox via registry — analytic, not tessellated")
    func arcBBoxViaRegistry() {
        // Quarter arc from 0 to π/2, center origin, radius 10, CCW
        let data = ArcData(center: Vector(0, 0), radius: 10, startAngle: 0, endAngle: .pi / 2, reversed: false)
        let kind = EntityKind.arc(data)
        let box = kind.resolver.boundingBox()
        // Analytic box includes the two endpoints and the +Y/+X extremes that are swept
        #expect(abs(box.max.x - 10) < 1e-9)
        #expect(abs(box.max.y - 10) < 1e-9)
        #expect(abs(box.min.x - 0) < 1e-9)
        #expect(abs(box.min.y - 0) < 1e-9)
    }

    @Test("polyline resolves and bounds via registry")
    func polylineViaRegistry() {
        let data = PolylineData(vertices: [PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(10, 0)), PolylineVertex(point: Vector(10, 10))], closed: false)
        let kind = EntityKind.polyline(data)
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].points.count == 3)
        let box = kind.resolver.boundingBox()
        #expect(box.min == Vector(0, 0))
        #expect(box.max == Vector(10, 10))
    }

    @Test("ellipse resolves and bounds via registry")
    func ellipseViaRegistry() {
        let data = EllipseData(center: Vector(0, 0), majorP: Vector(10, 0), ratio: 0.5)
        let kind = EntityKind.ellipse(data)
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].closed == true)
        let box = kind.resolver.boundingBox()
        #expect(box.min.x < 0 && box.max.x > 0)
    }

    @Test("hatch falls back to solid fill when pattern unknown — via registry")
    func hatchViaRegistry() {
        // Simple square hatch with no known pattern → solid fill
        let loop = [PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(10, 0)), PolylineVertex(point: Vector(10, 10)), PolylineVertex(point: Vector(0, 10))]
        let data = HatchData(loops: [loop], solidFill: false, patternName: "UNKNOWN_PAT")
        let kind = EntityKind.hatch(data)
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        // Unknown pattern → solid fallback: one fill, no polylines
        #expect(geo.fills.count == 1)
    }

    @Test("insert with missing block resolves to empty via registry")
    func insertMissingBlockViaRegistry() {
        let data = InsertData(blockName: "MISSING_BLOCK_\(UUID().uuidString)", insertionPoint: Vector(5, 5))
        let kind = EntityKind.insert(data)
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.isEmpty && geo.fills.isEmpty && geo.images.isEmpty)
        // BoundingBox collapses to insertion point when block is missing
        let box = kind.resolver.boundingBox()
        #expect(box.min == Vector(5, 5) && box.max == Vector(5, 5))
    }

    @Test("dimension resolves via registry")
    func dimensionViaRegistry() {
        let dim = DimData(kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0), definitionPoint: Vector(5, 5))
        let kind = EntityKind.dimension(dim)
        let geo = kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        // A linear dimension always has at least the extension + dimension lines
        #expect(geo.polylines.count >= 3)
    }

    // MARK: - Transform via registry

    @Test("line transform via registry — translation")
    func lineTransformViaRegistry() {
        let data = LineData(start: Vector(0, 0), end: Vector(10, 0))
        let kind = EntityKind.line(data)
        let t = Affine2D.translation(Vector(5, 7))
        let moved = kind.resolver.transformed(by: t)
        guard case .line(let out) = moved else {
            Issue.record("expected line after transform")
            return
        }
        #expect(out.start == Vector(5, 7))
        #expect(out.end == Vector(15, 7))
        // Also via the top-level helper (which now dispatches via registry):
        let moved2 = EntityTransform.transform(kind, by: t)
        #expect(moved2 == moved)
        let moved3 = kind.transformed(by: t)
        #expect(moved3 == moved)
    }

    @Test("circle transform via registry — uniform scale")
    func circleTransformViaRegistry() {
        let data = CircleData(center: Vector(1, 1), radius: 5)
        let kind = EntityKind.circle(data)
        let t = Affine2D.scale(factor: 2, about: Vector(0, 0))
        let scaled = kind.resolver.transformed(by: t)
        guard case .circle(let out) = scaled else {
            Issue.record("expected circle")
            return
        }
        #expect(abs(out.center.x - 2) < 1e-9 && abs(out.center.y - 2) < 1e-9)
        #expect(abs(out.radius - 10) < 1e-9)
    }

    @Test("arc transform via registry — rotation")
    func arcTransformViaRegistry() {
        let data = ArcData(center: Vector(0, 0), radius: 10, startAngle: 0, endAngle: .pi / 2, reversed: false)
        let kind = EntityKind.arc(data)
        let t = Affine2D.rotation(angle: .pi / 2)
        let rotated = kind.resolver.transformed(by: t)
        guard case .arc(let out) = rotated else {
            Issue.record("expected arc")
            return
        }
        // Both angles should be shifted by 90°
        #expect(abs(out.startAngle - .pi / 2) < 1e-9)
        #expect(abs(out.endAngle - .pi) < 1e-9)
    }

    @Test("polyline transform via registry — mirror flips bulge")
    func polylineTransformViaRegistry() {
        let data = PolylineData(vertices: [PolylineVertex(point: Vector(0, 0), bulge: 0.5), PolylineVertex(point: Vector(10, 0))], closed: false)
        let kind = EntityKind.polyline(data)
        let t = Affine2D.mirror(axisPoint1: Vector(0, 0), axisPoint2: Vector(0, 1)) // vertical line
        let mirrored = kind.resolver.transformed(by: t)
        guard case .polyline(let out) = mirrored else {
            Issue.record("expected polyline")
            return
        }
        // Mirror flips bulge sign
        #expect(abs(out.vertices[0].bulge + 0.5) < 1e-9)
    }

    // MARK: - Stub kind (proves "add file" extensibility)

    @Test("stub TestStubResolver resolves without touching Resolve.swift or EntityTransform.swift")
    func stubResolverResolves() {
        // This test exercises the per-kind resolver pattern that a NEW kind would use:
        // define `TestStubData` + `TestStubResolver` in its own file, add a case to
        // `EntityKind` + one entry in the `resolver` switch in `Entity.swift` — and
        // `Resolve.swift` / `EntityTransform.swift` handle it via `kind.resolver`
        // with no switch touch. Here we prove the resolver itself works via the same
        // registry dispatch (AnyEntityResolver) that production kinds use.
        let data = TestStubData(position: Vector(3, 4), label: "hello")
        // Direct resolver call (the new file's logic):
        let geo = TestStubResolver.resolve(data, pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.count == 1)
        #expect(geo.polylines[0].points == [Vector(3, 4)])

        // Via the type-erased registry box (the factory's mechanism):
        let any = AnyEntityResolver(
            resolve: { pen, ctx in TestStubResolver.resolve(data, pen: pen, ctx: ctx) },
            boundingBox: { TestStubResolver.boundingBox(data) },
            boundingBoxWithContext: { ctx in TestStubResolver.boundingBox(data, ctx: ctx) },
            transformed: { t in .point(PointData(position: TestStubResolver.transform(data, by: t).position)) }
        )
        let geo2 = any.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo2 == geo)

        // BoundingBox via resolver:
        let box = TestStubResolver.boundingBox(data)
        #expect(box.min == Vector(3, 4) && box.max == Vector(3, 4))
        let box2 = any.boundingBox()
        #expect(box2 == box)
        let boxCtx = any.boundingBox(ctx: registryCtx)
        #expect(boxCtx == box)

        // Transform via resolver:
        let t = Affine2D.translation(Vector(10, 0))
        let moved = TestStubResolver.transform(data, by: t)
        #expect(moved.position == Vector(13, 4))
        #expect(moved.label == "hello") // payload preserved
        let moved2 = any.transformed(by: t)
        // Any's transformed maps to a .point (the stub's world point as a point entity)
        // — the stub's label is not part of EntityKind, so we check the point position:
        if case .point(let pd) = moved2 {
            #expect(pd.position == Vector(13, 4))
        } else {
            Issue.record("expected point after stub transform via AnyEntityResolver")
        }
    }

    @Test("stub TestStubData round-trips through Codable (additive, no existing file breakage)")
    func stubCodableRoundTrip() throws {
        let data = TestStubData(position: Vector(1, 2), label: "stub")
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(TestStubData.self, from: encoded)
        #expect(decoded == data)
    }

    // MARK: - Fallback for unknown kinds

    @Test("AnyEntityResolver.fallback returns empty geometry and empty box")
    func fallbackIsEmpty() {
        let fb = AnyEntityResolver.fallback
        let geo = fb.resolve(pen: registryPen, ctx: registryCtx)
        #expect(geo.polylines.isEmpty && geo.fills.isEmpty && geo.images.isEmpty)
        let box = fb.boundingBox()
        #expect(box.isEmpty)
        let boxCtx = fb.boundingBox(ctx: registryCtx)
        #expect(boxCtx.isEmpty)
        // Fallback transform returns a degenerate point (the documented fallback contract)
        let t = Affine2D.translation(Vector(5, 5))
        let out = fb.transformed(by: t)
        // Fallback is defined as a point at origin; transform should still be a point
        if case .point = out {
            // ok — the fallback contract is "produce a valid, non-crashing EntityKind"
        } else {
            Issue.record("fallback transformed should be a point")
        }
    }

    @Test("unknown kind fallback is stable — repeated fallback calls are equal")
    func fallbackIsStable() {
        let fb = AnyEntityResolver.fallback
        let g1 = fb.resolve(pen: registryPen, ctx: registryCtx)
        let g2 = fb.resolve(pen: registryPen, ctx: registryCtx)
        #expect(g1 == g2)
        #expect(fb.boundingBox() == fb.boundingBox())
    }

    // MARK: - Registry vs legacy dispatch parity (spot checks)

    @Test("EntityRecord.resolve still goes via registry (parity with kind.resolver)")
    func entityRecordParity() {
        let rec = EntityRecord(id: EntityID(1), kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 5))))
        let viaRecord = rec.resolve(registryCtx)
        let viaResolver = rec.kind.resolver.resolve(pen: registryPen, ctx: registryCtx)
        // EntityRecord.resolve uses layer pen resolution (byLayer → green) so we use
        // the same pen it would resolve to; for a direct kind test we compare the
        // kind-level resolve (which takes an already-resolved pen).
        let viaKind = rec.kind.resolve(pen: registryPen, ctx: registryCtx)
        #expect(viaResolver == viaKind)
        _ = viaRecord // record-level includes layer lookup; just ensure it doesn't crash and is non-empty
        #expect(!viaRecord.polylines.isEmpty)
    }

    @Test("all 21 production kinds have a non-crashing registry entry")
    func allKindsHaveRegistry() {
        // Enumerate one representative per kind and ensure the registry doesn't trap
        let kinds: [EntityKind] = [
            .point(PointData(position: Vector(0, 0))),
            .line(LineData(start: Vector(0, 0), end: Vector(1, 0))),
            .circle(CircleData(center: Vector(0, 0), radius: 1)),
            .arc(ArcData(center: Vector(0, 0), radius: 1, startAngle: 0, endAngle: 1, reversed: false)),
            .polyline(PolylineData(vertices: [PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(1, 0))], closed: false)),
            .ellipse(EllipseData(center: Vector(0, 0), majorP: Vector(1, 0), ratio: 0.5)),
            .spline(SplineData(degree: 1, controlPoints: [Vector(0, 0), Vector(1, 1)])),
            .splinePoints(SplinePointsData(controlPoints: [Vector(0, 0), Vector(1, 0), Vector(2, 0)])),
            .text(TextData(position: Vector(0, 0), height: 2.5, text: "hi")),
            .mtext(MTextData(position: Vector(0, 0), height: 2.5, rectWidth: 10, paragraphs: [MTextParagraph(inlines: [.run(TextRun(text: "hi"))])])),
            .hatch(HatchData(loops: [[PolylineVertex(point: Vector(0, 0)), PolylineVertex(point: Vector(1, 0)), PolylineVertex(point: Vector(1, 1))]])),
            .solid(SolidData(corners: [Vector(0, 0), Vector(1, 0), Vector(0, 1)])),
            .dimension(DimData(kind: .linear(extension1: Vector(0, 0), extension2: Vector(1, 0), angle: 0), definitionPoint: Vector(0.5, 1))),
            .insert(InsertData(blockName: "B", insertionPoint: Vector(0, 0))),
            .xline(XLineData(base: Vector(0, 0), direction: Vector(1, 0))),
            .ray(RayData(base: Vector(0, 0), direction: Vector(1, 0))),
            .leader(LeaderData(vertices: [Vector(0, 0), Vector(1, 1)])),
            .multileader(MultiLeaderData(vertices: [Vector(0, 0), Vector(1, 1)])),
            .image(ImageData(path: "p.png", lowerLeft: Vector(0, 0), widthVector: Vector(1, 0), heightVector: Vector(0, 1))),
            .wipeout(WipeoutData(worldBoundary: [Vector(0, 0), Vector(1, 0), Vector(0, 1)])),
            .mline(MLineData(vertices: [Vector(0, 0), Vector(1, 0)], elements: [MLineElement(offset: 0), MLineElement(offset: 0.5)])),
        ]
        for k in kinds {
            // Each should produce a resolver that doesn't crash on resolve/bbox/transform
            let r = k.resolver
            _ = r.resolve(pen: registryPen, ctx: registryCtx)
            _ = r.boundingBox()
            _ = r.boundingBox(ctx: registryCtx)
            _ = r.transformed(by: .identity)
            _ = k.resolve(pen: registryPen, ctx: registryCtx)
            _ = k.boundingBox()
            _ = k.boundingBox(ctx: registryCtx)
            _ = k.transformed(by: .identity)
            _ = EntityTransform.transform(k, by: .identity)
        }
    }
}
