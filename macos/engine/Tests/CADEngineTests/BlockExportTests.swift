//
//  BlockExportTests.swift
//  CADEngineTests
//
//  Export a block / a raw selection to a `.dxf` file (the engine half of "Save
//  Block" / WBLOCK) — the inverse of `BlockLibrary.importDXF`:
//   - `BlockExport.writeBlock`: a named block with a NON-origin base point is
//     written to a temp `.dxf` RE-BASED to the origin, then read back (via the
//     engine reader AND via `BlockLibrary.importDXF`) — a member at world
//     `basePoint + Δ` round-trips at `Δ`.
//   - `BlockExport.writeRecords`: a raw selection round-trips, re-based to origin.
//   - degenerate: an unknown block / an empty block / empty records / a blank path
//     are all graceful (nil result, NO file written — or `invalidPath` for a blank
//     path).
//   - nested INSERTs: a block whose member is an `.insert` of ANOTHER block exports
//     with the referenced block DEFINITION in the file, so the nested geometry
//     round-trips through the reader.
//
//  Uniquely namespaced (`@Suite("block export / WBLOCK")`) so it does not collide
//  with the other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("block export / WBLOCK")
struct BlockExportTests {

    // MARK: - Helpers

    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    private func line(_ a: Vector, _ b: Vector, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: a, end: b)))
    }

    private func circle(_ c: Vector, _ r: Double, id: UInt64 = 0) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .circle(CircleData(center: c, radius: r)))
    }

    private func tempPath(_ tag: String = "export") -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tag)-\(UUID().uuidString).dxf").path
    }

    private func removeFile(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// All resolved polyline points of a record under a drawing's resolve context.
    private func resolvedPoints(_ rec: EntityRecord, in d: CADDrawing) -> [Vector] {
        rec.resolve(d.makeResolveContext()).polylines.flatMap { $0.points }
    }

    /// The center of the single circle in a set of records (or nil).
    private func soleCircleCenter(_ records: [EntityRecord]) -> Vector? {
        for r in records { if case .circle(let c) = r.kind { return c.center } }
        return nil
    }

    /// Reads every TOP-LEVEL record back from a written `.dxf` via the engine reader.
    private func readBack(_ path: String) async throws -> [EntityRecord] {
        try await CADEngine.shared.readEntities(dxfPath: path).records
    }

    // MARK: - writeBlock: named block re-based to origin, round-trips

    @Test("writeBlock re-bases a non-origin block to the origin; geometry round-trips")
    func writeBlockRebasesToOrigin() async throws {
        // A block "WIDGET" whose base point is (100, 100) and whose sole member is a
        // circle at world (130, 100) — i.e. Δ = (30, 0) from the base point. After
        // export+read the circle must sit at Δ = (30, 0).
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let cid = d.add(circle(Vector(130, 100), 5))
        d.addBlock(Block(name: "WIDGET", basePoint: Vector(100, 100), entityIDs: [cid]))

        let path = tempPath()
        defer { removeFile(path) }
        let result = try #require(try await BlockExport.writeBlock(d, name: "WIDGET", toPath: path))
        #expect(result.recordCount == 1)
        #expect(result.written == 1)
        #expect(fileExists(path))

        // Read back the top-level records: the circle is re-based to Δ = (30, 0).
        let back = try await readBack(path)
        let center = try #require(soleCircleCenter(back))
        #expect((center - Vector(30, 0)).magnitude < 1e-6,
                "exported circle should be re-based to (30,0), got \(center)")
    }

    @Test("writeBlock output re-imports cleanly via BlockLibrary.importDXF at origin")
    func writeBlockReimportsViaBlockLibrary() async throws {
        // Block "GASKET", base point (50, 0); two members forming an L at world
        // (60, 0)->(60, 10)->(70, 10). Local frame (minus base point): (10,0)->(10,10)
        // ->(20,10). Re-importing at origin must reproduce that local geometry.
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let a = d.add(line(Vector(60, 0), Vector(60, 10)))
        let b = d.add(line(Vector(60, 10), Vector(70, 10)))
        d.addBlock(Block(name: "GASKET", basePoint: Vector(50, 0), entityIDs: [a, b]))

        let path = tempPath()
        defer { removeFile(path) }
        _ = try #require(try await BlockExport.writeBlock(d, name: "GASKET", toPath: path))

        // Re-import into a fresh drawing as a block at origin; the placed INSERT must
        // resolve to the LOCAL-frame geometry.
        let dest = CADDrawing()
        dest.undoManager = testUndoManager()
        let imp = try #require(try await BlockLibrary.importDXF(path: path, into: dest))
        #expect(imp.memberCount == 2)
        let insertRec = try #require(dest.entity(imp.insertID))
        let pts = resolvedPoints(insertRec, in: dest)
        for corner in [Vector(10, 0), Vector(10, 10), Vector(20, 10)] {
            #expect(pts.contains { ($0 - corner).magnitude < 1e-6 },
                    "re-imported geometry missing local corner \(corner)")
        }
    }

    @Test("writeBlock with a zero base point writes members at their world positions")
    func writeBlockZeroBasePoint() async throws {
        // basePoint == origin ⇒ no translation; members keep world positions.
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let cid = d.add(circle(Vector(7, 3), 2))
        d.addBlock(Block(name: "PLAIN", basePoint: Vector(0, 0), entityIDs: [cid]))

        let path = tempPath()
        defer { removeFile(path) }
        _ = try #require(try await BlockExport.writeBlock(d, name: "PLAIN", toPath: path))
        let back = try await readBack(path)
        let center = try #require(soleCircleCenter(back))
        #expect((center - Vector(7, 3)).magnitude < 1e-6)
    }

    // MARK: - writeRecords: raw selection ("WBLOCK objects")

    @Test("writeRecords exports a raw selection re-based to the origin; round-trips")
    func writeRecordsRebasesSelection() async throws {
        // A hand-picked selection (not a named block): a circle at (20, 20), base
        // point (20, 20) ⇒ re-based to origin.
        let records = [ circle(Vector(20, 20), 4, id: 1) ]
        let path = tempPath("wblock-objects")
        defer { removeFile(path) }
        let result = try #require(try await BlockExport.writeRecords(
            records, basePoint: Vector(20, 20), layers: LayerTable(), toPath: path))
        #expect(result.recordCount == 1)
        #expect(fileExists(path))

        let back = try await readBack(path)
        let center = try #require(soleCircleCenter(back))
        #expect((center - Vector(0, 0)).magnitude < 1e-6,
                "selection should be re-based so its base point is the origin")
    }

    @Test("writeRecords with a non-zero Δ preserves the offset from base point")
    func writeRecordsPreservesDelta() async throws {
        // Two records: base point (10, 10). A line from (10,10) to (40,10) ⇒ local
        // (0,0)->(30,0).
        let records = [ line(Vector(10, 10), Vector(40, 10), id: 1) ]
        let path = tempPath()
        defer { removeFile(path) }
        _ = try #require(try await BlockExport.writeRecords(
            records, basePoint: Vector(10, 10), layers: LayerTable(), toPath: path))

        let back = try await readBack(path)
        var ends: (Vector, Vector)?
        for r in back { if case .line(let l) = r.kind { ends = (l.start, l.end) } }
        let (s, e) = try #require(ends)
        // Order-independent endpoint check.
        let hasOrigin = (s - Vector(0, 0)).magnitude < 1e-6 || (e - Vector(0, 0)).magnitude < 1e-6
        let hasFar = (s - Vector(30, 0)).magnitude < 1e-6 || (e - Vector(30, 0)).magnitude < 1e-6
        #expect(hasOrigin && hasFar)
    }

    // MARK: - Degenerate / graceful

    @Test("writeBlock of an unknown block returns nil and writes NO file")
    func writeBlockUnknownNoFile() async throws {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let path = tempPath()
        defer { removeFile(path) }
        let result = try await BlockExport.writeBlock(d, name: "NOPE", toPath: path)
        #expect(result == nil)
        #expect(!fileExists(path))
    }

    @Test("writeBlock of an empty (member-less) block returns nil and writes NO file")
    func writeBlockEmptyNoFile() async throws {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        d.addBlock(Block(name: "EMPTY", basePoint: Vector(0, 0), entityIDs: []))
        let path = tempPath()
        defer { removeFile(path) }
        let result = try await BlockExport.writeBlock(d, name: "EMPTY", toPath: path)
        #expect(result == nil)
        #expect(!fileExists(path))
    }

    @Test("writeBlock skips stale member ids; returns nil if ALL are stale")
    func writeBlockAllStaleMembers() async throws {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        // The block references an id that is NOT in the drawing.
        d.addBlock(Block(name: "GHOST", basePoint: .init(0, 0), entityIDs: [EntityID(99999)]))
        let path = tempPath()
        defer { removeFile(path) }
        let result = try await BlockExport.writeBlock(d, name: "GHOST", toPath: path)
        #expect(result == nil)
        #expect(!fileExists(path))
    }

    @Test("writeRecords with empty records returns nil and writes NO file")
    func writeRecordsEmptyNoFile() async throws {
        let path = tempPath()
        defer { removeFile(path) }
        let result = try await BlockExport.writeRecords(
            [], basePoint: Vector(0, 0), layers: LayerTable(), toPath: path)
        #expect(result == nil)
        #expect(!fileExists(path))
    }

    @Test("writeRecords with a blank path throws invalidPath")
    func writeRecordsBlankPathThrows() async throws {
        await #expect(throws: CADWriteError.invalidPath) {
            _ = try await BlockExport.writeRecords(
                [circle(Vector(0, 0), 1, id: 1)],
                basePoint: Vector(0, 0), layers: LayerTable(), toPath: "")
        }
    }

    // MARK: - Layer fidelity

    @Test("writeBlock emits the layer a member references (subset of the drawing)")
    func writeBlockEmitsReferencedLayer() async throws {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        d.mutateLayers { $0.add(Layer(name: "SYMBOLS")) }
        var rec = circle(Vector(5, 5), 3)
        rec.layer = LayerID("SYMBOLS")
        let cid = d.add(rec)
        d.addBlock(Block(name: "ONLAYER", basePoint: Vector(0, 0), entityIDs: [cid]))

        let path = tempPath()
        defer { removeFile(path) }
        _ = try #require(try await BlockExport.writeBlock(d, name: "ONLAYER", toPath: path))

        // Read back the layer table: "SYMBOLS" (referenced) + "0" (mandatory) present.
        let table = try await CADEngine.shared.readEntities(dxfPath: path).layers
        #expect(table.contains("SYMBOLS"))
        #expect(table.contains("0"))
    }

    // MARK: - Nested INSERT members round-trip

    @Test("writeBlock of a block whose member is an INSERT emits the nested block; geometry round-trips")
    func writeBlockNestedInsertRoundTrips() async throws {
        // Inner block "PIN": a circle at world (0,0) r=1, base point origin.
        // Outer block "ASSY": its member is an INSERT of "PIN" placed at (5,0); base
        // point of ASSY is (2,0). On export, ASSY's members re-base by (2,0): the
        // INSERT moves to (3,0). The PIN definition (circle at origin) is emitted in
        // the BLOCKS section so the reader can expand it.
        let d = CADDrawing()
        d.undoManager = testUndoManager()

        let pinCircle = d.add(circle(Vector(0, 0), 1))
        d.addBlock(Block(name: "PIN", basePoint: Vector(0, 0), entityIDs: [pinCircle]))

        let insertRec = EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "PIN", insertionPoint: Vector(5, 0))))
        let insertID = d.add(insertRec)
        d.addBlock(Block(name: "ASSY", basePoint: Vector(2, 0), entityIDs: [insertID]))

        let path = tempPath("nested")
        defer { removeFile(path) }
        let result = try #require(try await BlockExport.writeBlock(d, name: "ASSY", toPath: path))
        #expect(result.recordCount == 1)              // one top-level INSERT member
        #expect(result.nestedBlockCount == 1)         // the PIN definition emitted

        // Load the exported file as a full drawing (the reader expands the file's
        // BLOCKS section — the proper round-trip for nested inserts; `importDXF`'s
        // re-block-wrapping does NOT carry the file's block table, a documented
        // import-side limitation, so we validate export fidelity via `loadDrawing`).
        // The top-level INSERT must be at the re-based local point (3,0) and resolve
        // through PIN to the circle centered there.
        let loaded = try await loadDrawing(dxfPath: path)
        var insertPoint: Vector?
        var resolvedPts: [Vector] = []
        for r in loaded.entities {
            if case .insert(let ins) = r.kind {
                insertPoint = ins.insertionPoint
                resolvedPts = resolvedPoints(r, in: loaded)
            }
        }
        let ip = try #require(insertPoint)
        #expect((ip - Vector(3, 0)).magnitude < 1e-6,
                "nested INSERT should be re-based to local (3,0), got \(ip)")
        #expect(!resolvedPts.isEmpty, "nested insert resolved to no geometry — PIN definition lost")
        // The PIN circle (r=1, tessellated) sits centered at local (3,0): every
        // resolved point is within r+ε of (3,0).
        #expect(resolvedPts.allSatisfy { ($0 - Vector(3, 0)).magnitude <= 1.0 + 1e-3 },
                "nested PIN geometry not centered at the re-based insert point (3,0)")
    }
}
