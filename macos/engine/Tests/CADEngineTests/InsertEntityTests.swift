//
//  InsertEntityTests.swift
//  CADEngineTests
//
//  Tests for the block-reference (`.insert`) entity — the KEYSTONE block-INSERT
//  feature (feature-catalog #6):
//   - resolve() expands an insert to its block's member entities, transformed by
//     the placement (translate∘rotate∘scale about the insertion point);
//   - boundingBox() encloses the transformed members;
//   - rotation + scale apply correctly;
//   - a MINSERT array repeats the block over its grid;
//   - a missing block resolves to empty (no crash);
//   - a cyclic block reference terminates (the depth guard);
//   - EntityTransform composes onto the placement;
//   - a DXF INSERT round-trips (write → read with point/scale/rotation).
//
//  Uniquely namespaced (`@Suite("insert entity (block reference)")`) so it does not
//  collide with the existing 1055 tests.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("insert entity (block reference)")
struct InsertEntityTests {

    // MARK: - Helpers

    /// A 2-entity block "GRID": a line and a circle, authored about the origin.
    private func gridMembers() -> [EntityRecord] {
        [
            EntityRecord(id: EntityID(1),
                         kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))),
            EntityRecord(id: EntityID(2),
                         kind: .circle(CircleData(center: Vector(0, 0), radius: 2))),
        ]
    }

    /// A resolve context whose `blockProvider` serves the given name → members map.
    private func ctx(_ blocks: [String: [EntityRecord]]) -> ResolveContext {
        ResolveContext(blockProvider: { name in blocks[name] })
    }

    // MARK: - Resolve: members transformed by the placement

    @Test("an insert of a 2-entity block resolves to those 2 entities, translated")
    func resolvesToMembersTranslated() {
        let members = gridMembers()
        let context = ctx(["GRID": members])
        let insert = EntityRecord(
            id: EntityID(100),
            kind: .insert(InsertData(blockName: "GRID", insertionPoint: Vector(100, 50)))
        )
        let geo = insert.resolve(context)

        // The block has a line (1 polyline) + a circle (1 closed polyline) ⇒ 2.
        #expect(geo.polylines.count == 2)
        #expect(geo.fills.isEmpty)

        // Every point is shifted by the insertion point (no rotation/scale).
        let pts = geo.polylines.flatMap { $0.points }
        // The line's far endpoint (10,0) lands at (110,50).
        #expect(pts.contains { abs($0.x - 110) < 1e-9 && abs($0.y - 50) < 1e-9 })
        // The circle's points are centered at (100,50) with radius 2.
        let circlePts = geo.polylines.first { $0.closed }!.points
        for p in circlePts {
            let r = (p - Vector(100, 50)).magnitude
            #expect(abs(r - 2) < 1e-6)
        }
    }

    @Test("boundingBox encloses the transformed members")
    func boundingBoxEnclosesMembers() {
        let members = gridMembers()
        let context = ctx(["GRID": members])
        let insert = EntityKind.insert(
            InsertData(blockName: "GRID", insertionPoint: Vector(100, 50)))
        let box = insert.boundingBox(ctx: context)

        // Line spans (100,50)→(110,50); circle spans (98,48)→(102,52).
        // Union: x in [98,110], y in [48,52].
        #expect(abs(box.min.x - 98) < 1e-6)
        #expect(abs(box.max.x - 110) < 1e-6)
        #expect(abs(box.min.y - 48) < 1e-6)
        #expect(abs(box.max.y - 52) < 1e-6)

        // The no-ctx box (no provider) collapses to the insertion point, not a crash.
        let degenerate = insert.boundingBox()
        #expect(degenerate.min == Vector(100, 50))
        #expect(degenerate.max == Vector(100, 50))
    }

    @Test("rotation applies: a 90° insert rotates the line endpoint")
    func rotationApplies() {
        // A single horizontal line member 0→(10,0).
        let members = [EntityRecord(id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))]
        let context = ctx(["L": members])
        let insert = EntityRecord(id: EntityID(7),
            kind: .insert(InsertData(blockName: "L", insertionPoint: Vector(0, 0),
                                     rotation: .pi / 2)))
        let pts = insert.resolve(context).polylines.flatMap { $0.points }
        // The far endpoint (10,0) rotates 90° CCW about the origin → (0,10).
        #expect(pts.contains { abs($0.x) < 1e-6 && abs($0.y - 10) < 1e-6 })
    }

    @Test("scale applies: a 2× insert doubles the circle radius")
    func scaleApplies() {
        let members = [EntityRecord(id: EntityID(1),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 3)))]
        let context = ctx(["C": members])
        let insert = EntityRecord(id: EntityID(8),
            kind: .insert(InsertData(blockName: "C", insertionPoint: Vector(0, 0),
                                     scale: Vector(2, 2))))
        let pts = insert.resolve(context).polylines.flatMap { $0.points }
        // Every circle point is now at radius 6 from the origin.
        for p in pts { #expect(abs(p.magnitude - 6) < 1e-6) }
        // The bounding box spans [-6,6]².
        let box = insert.boundingBox(ctx: context)
        #expect(abs(box.min.x - -6) < 1e-6 && abs(box.max.x - 6) < 1e-6)
    }

    @Test("rotation + scale compose about the insertion point")
    func rotationAndScaleCompose() {
        let members = [EntityRecord(id: EntityID(1),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))]
        let context = ctx(["L": members])
        // 2× scale then 90° rotation about (5,5).
        let insert = EntityRecord(id: EntityID(9),
            kind: .insert(InsertData(blockName: "L", insertionPoint: Vector(5, 5),
                                     scale: Vector(2, 2), rotation: .pi / 2)))
        let pts = insert.resolve(context).polylines.flatMap { $0.points }
        // (0,0) → scale → (0,0) → rotate → (0,0) → +ins (5,5) = (5,5).
        // (10,0) → scale → (20,0) → rotate 90° → (0,20) → +ins (5,5) = (5,25).
        #expect(pts.contains { abs($0.x - 5) < 1e-6 && abs($0.y - 5) < 1e-6 })
        #expect(pts.contains { abs($0.x - 5) < 1e-6 && abs($0.y - 25) < 1e-6 })
    }

    // MARK: - MINSERT array

    @Test("MINSERT repeats the block over a 2×3 grid")
    func minsertRepeatsGrid() {
        // A single point member at the origin, so each grid cell yields exactly one
        // polyline whose only point is the cell's placement.
        let members = [EntityRecord(id: EntityID(1),
            kind: .point(PointData(position: Vector(0, 0))))]
        let context = ctx(["P": members])
        let insert = EntityRecord(id: EntityID(10),
            kind: .insert(InsertData(blockName: "P", insertionPoint: Vector(0, 0),
                                     rows: 2, cols: 3,
                                     rowSpacing: 100, colSpacing: 10)))
        let geo = insert.resolve(context)
        // 2 rows × 3 cols = 6 placements ⇒ 6 single-point polylines.
        #expect(geo.polylines.count == 6)
        let pts = Set(geo.polylines.compactMap { $0.points.first.map { Vector($0.x, $0.y) } })
        // Cells at (col*10, row*100): (0,0),(10,0),(20,0),(0,100),(10,100),(20,100).
        for r in 0..<2 {
            for c in 0..<3 {
                let expected = Vector(Double(c) * 10, Double(r) * 100)
                #expect(pts.contains { ($0 - expected).magnitude < 1e-9 })
            }
        }
    }

    // MARK: - Missing block / no provider

    @Test("a missing block resolves to empty (no crash)")
    func missingBlockResolvesEmpty() {
        let context = ctx([:])   // provider present, but the name is unknown
        let insert = EntityRecord(id: EntityID(11),
            kind: .insert(InsertData(blockName: "NOPE", insertionPoint: Vector(0, 0))))
        let geo = insert.resolve(context)
        #expect(geo.polylines.isEmpty)
        #expect(geo.fills.isEmpty)
        // The box collapses to the insertion point, not a crash.
        let box = insert.boundingBox(ctx: context)
        #expect(box.min == Vector(0, 0) && box.max == Vector(0, 0))
    }

    @Test("no block provider at all resolves to empty (no crash)")
    func noProviderResolvesEmpty() {
        let insert = EntityRecord(id: EntityID(12),
            kind: .insert(InsertData(blockName: "GRID", insertionPoint: Vector(0, 0))))
        let geo = insert.resolve(.default)   // default ctx has no blockProvider
        #expect(geo.polylines.isEmpty && geo.fills.isEmpty)
    }

    // MARK: - Cyclic block depth guard

    @Test("a self-referencing (cyclic) block terminates via the depth guard")
    func cyclicBlockTerminates() {
        // Block "CYCLE" contains a line AND an insert of itself → infinite without
        // the depth guard. We assert resolve() returns (it terminates) and produces
        // a bounded amount of geometry.
        let selfInsertID = EntityID(2)
        let cycleMembers: [EntityRecord] = [
            EntityRecord(id: EntityID(1),
                         kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))),
            EntityRecord(id: selfInsertID,
                         kind: .insert(InsertData(blockName: "CYCLE",
                                                  insertionPoint: Vector(0, 0)))),
        ]
        let context = ctx(["CYCLE": cycleMembers])
        let insert = EntityRecord(id: EntityID(20),
            kind: .insert(InsertData(blockName: "CYCLE", insertionPoint: Vector(0, 0))))

        // Must return (not hang/overflow). The depth budget bounds the nesting, so
        // the line is emitted at most `maxBlockRecursionDepth` times.
        let geo = insert.resolve(context)
        #expect(geo.polylines.count >= 1)
        #expect(geo.polylines.count <= ResolveContext.maxBlockRecursionDepth + 1)

        // The box terminates too.
        let box = insert.boundingBox(ctx: context)
        #expect(!box.isEmpty)
    }

    @Test("a two-block cycle A→B→A terminates")
    func twoBlockCycleTerminates() {
        let aMembers = [EntityRecord(id: EntityID(1),
            kind: .insert(InsertData(blockName: "B", insertionPoint: Vector(0, 0))))]
        let bMembers = [EntityRecord(id: EntityID(2),
            kind: .insert(InsertData(blockName: "A", insertionPoint: Vector(0, 0))))]
        let context = ctx(["A": aMembers, "B": bMembers])
        let insert = EntityRecord(id: EntityID(21),
            kind: .insert(InsertData(blockName: "A", insertionPoint: Vector(0, 0))))
        // No real geometry anywhere in the cycle ⇒ empty, but crucially it RETURNS.
        let geo = insert.resolve(context)
        #expect(geo.polylines.isEmpty && geo.fills.isEmpty)
    }

    // MARK: - EntityTransform composes onto the placement

    @Test("transforming an insert moves the insertion point and composes rotation")
    func transformComposesPlacement() {
        let original = InsertData(blockName: "X", insertionPoint: Vector(1, 2),
                                  scale: Vector(2, 2), rotation: 0)
        // Translate by (10,0) then rotate 90° about the origin.
        let t = Affine2D.rotation(angle: .pi / 2) * Affine2D.translation(Vector(10, 0))
        guard case .insert(let moved) = EntityKind.insert(original).transformed(by: t) else {
            Issue.record("transform did not preserve the .insert kind"); return
        }
        // The insertion point (1,2) → +translate (11,2) → rotate 90° → (-2,11).
        #expect(abs(moved.insertionPoint.x - -2) < 1e-6)
        #expect(abs(moved.insertionPoint.y - 11) < 1e-6)
        // Rotation gains 90°; scale unchanged (uniform factor 1).
        #expect(abs(moved.rotation - .pi / 2) < 1e-6)
        #expect(abs(moved.scale.x - 2) < 1e-6 && abs(moved.scale.y - 2) < 1e-6)
        #expect(moved.blockName == "X")
    }

    @Test("a uniform-scale transform multiplies the insert's scale")
    func transformScalesInsert() {
        let original = InsertData(blockName: "X", insertionPoint: Vector(0, 0),
                                  scale: Vector(1, 1))
        let t = Affine2D.scale(factor: 3, about: Vector(0, 0))
        guard case .insert(let scaled) = EntityKind.insert(original).transformed(by: t) else {
            Issue.record("not an insert"); return
        }
        #expect(abs(scaled.scale.x - 3) < 1e-6 && abs(scaled.scale.y - 3) < 1e-6)
    }

    // MARK: - DXF round-trip (write → read with point/scale/rotation)

    @Test("a DXF INSERT round-trips with its block geometry, point, scale, rotation")
    func dxfInsertRoundTrips() async throws {
        // Build a drawing with a block "WIDGET" (a line + a circle) and an INSERT
        // referencing it at (100,50), scale 2, rotation 90°.
        let line = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let circle = EntityRecord(id: EntityID(2), layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 4)))
        let insertData = InsertData(blockName: "WIDGET", insertionPoint: Vector(100, 50),
                                    scale: Vector(2, 2), rotation: .pi / 2)
        let insert = EntityRecord(id: EntityID(3), layer: LayerID("0"),
                                  kind: .insert(insertData))

        // The block table references the member ids; the records list carries them
        // PLUS the top-level INSERT.
        var blocks = BlockTable()
        blocks.add(Block(name: "WIDGET", basePoint: Vector(0, 0),
                         entityIDs: [EntityID(1), EntityID(2)]))
        let records = [line, circle, insert]
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
        let blockMembers = ["WIDGET": [line, circle]]

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("insert-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities(
            records, layers: layers, blocks: blocks, blockMembers: blockMembers,
            toPath: outPath)

        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        // The INSERT survives as `.insert` with its placement intact.
        let inserts = back.records.compactMap { r -> InsertData? in
            if case .insert(let d) = r.kind { return d } else { return nil }
        }
        #expect(inserts.count == 1)
        let d = try #require(inserts.first)
        #expect(d.blockName.caseInsensitiveCompare("WIDGET") == .orderedSame)
        #expect(abs(d.insertionPoint.x - 100) < 1e-6)
        #expect(abs(d.insertionPoint.y - 50) < 1e-6)
        #expect(abs(d.scale.x - 2) < 1e-6)
        #expect(abs(d.scale.y - 2) < 1e-6)
        #expect(abs(d.rotation - .pi / 2) < 1e-6)

        // The block definition + its 2 members survive too.
        #expect(back.blocks.contains("WIDGET") || back.blocks.block(namedCaseInsensitive: "WIDGET") != nil)
        let widget = back.blocks.block(named: "WIDGET")
            ?? back.blocks.block(namedCaseInsensitive: "WIDGET")
        let block = try #require(widget)
        #expect(block.entityIDs.count == 2)
    }

    @Test("a MINSERT array round-trips its row/col counts + spacing")
    func dxfMinsertRoundTrips() async throws {
        let circle = EntityRecord(id: EntityID(1), layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(0, 0), radius: 1)))
        let insertData = InsertData(blockName: "DOT", insertionPoint: Vector(0, 0),
                                    rows: 2, cols: 3, rowSpacing: 20, colSpacing: 5)
        let insert = EntityRecord(id: EntityID(2), layer: LayerID("0"),
                                  kind: .insert(insertData))
        var blocks = BlockTable()
        blocks.add(Block(name: "DOT", entityIDs: [EntityID(1)]))
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("minsert-roundtrip-\(UUID().uuidString).dxf").path
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        _ = try await CADEngine.shared.writeEntities(
            [circle, insert], layers: layers, blocks: blocks,
            blockMembers: ["DOT": [circle]], toPath: outPath)
        let back = try await CADEngine.shared.readEntities(dxfPath: outPath)

        let d = try #require(back.records.compactMap { r -> InsertData? in
            if case .insert(let i) = r.kind { return i } else { return nil }
        }.first)
        #expect(d.rows == 2)
        #expect(d.cols == 3)
        #expect(abs(d.rowSpacing - 20) < 1e-6)
        #expect(abs(d.colSpacing - 5) < 1e-6)
    }
}
