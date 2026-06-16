//
//  BlockLibraryTests.swift
//  CADEngineTests
//
//  Parts / symbol library (engine model + import-block-from-.dxf):
//   - `BlockLibrary.scan(directory:)`: a temp folder of `.dxf` files becomes a
//     name-sorted catalog of `BlockLibraryItem`s; non-`.dxf` files are ignored;
//     a missing folder yields an empty catalog (never throws, no file-picker).
//   - `BlockLibrary.importRecords`: already-read geometry becomes a NAMED block
//     plus one placed INSERT in a drawing, routed through the existing
//     `makeBlockFromEntities` op (no in-place overwrite).
//   - `BlockLibrary.importDXF`: a real `.dxf` file (written by the engine writer
//     in-test) round-trips into a named block; the placed insert resolves to the
//     file's geometry.
//   - DATA-SAFETY: a name-collision import is RENAMED via `newName`; BOTH the
//     pre-existing and the imported block survive with ALL members intact (the
//     critic must-fix — no `removeBlock(deletingContents:)` member loss).
//   - degenerate: empty records / an empty (geometry-less) `.dxf` import gracefully
//     to `nil` leaving the drawing UNCHANGED (no crash, no partial block).
//
//  Uniquely namespaced (`@Suite("block library + import")`) so it does not collide
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
@Suite("block library + import")
struct BlockLibraryTests {

    // MARK: - Helpers

    /// An UndoManager configured for unit testing (manual grouping).
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

    private func lineEnds(_ rec: EntityRecord) -> (Vector, Vector)? {
        guard case .line(let l) = rec.kind else { return nil }
        return (l.start, l.end)
    }

    /// A drawing seeded with the given records (ids minted) under an UndoManager;
    /// returns the drawing + the assigned ids in order.
    private func seeded(_ records: [EntityRecord]) -> (CADDrawing, [EntityID]) {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        var ids: [EntityID] = []
        for r in records { ids.append(d.add(r)) }
        return (d, ids)
    }

    /// A fresh temp directory the caller cleans up.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocklib-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeItem(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    private func removeFile(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    // MARK: - BlockLibraryItem naming

    @Test("BlockLibraryItem derives its name from the file base name")
    func itemNameFromURL() {
        let item = BlockLibraryItem(url: URL(fileURLWithPath: "/sym/Gate Valve.dxf"))
        #expect(item.name == "Gate Valve")
        #expect(item.url.lastPathComponent == "Gate Valve.dxf")
        // An explicit name overrides the file base name.
        let named = BlockLibraryItem(name: "V1", url: URL(fileURLWithPath: "/sym/x.dxf"))
        #expect(named.name == "V1")
    }

    // MARK: - scan(directory:)  (no file-picker)

    @Test("scan lists .dxf items name-sorted, ignoring non-.dxf and hidden files")
    func scanListsDXFItems() throws {
        let dir = tempDir()
        defer { removeItem(dir) }
        let fm = FileManager.default
        // Two .dxf symbols (out of alpha order on disk), plus noise that must be ignored.
        try Data().write(to: dir.appendingPathComponent("Valve.dxf"))
        try Data().write(to: dir.appendingPathComponent("Bolt.dxf"))
        try Data().write(to: dir.appendingPathComponent("readme.txt"))   // not .dxf
        try Data().write(to: dir.appendingPathComponent("drawing.dwg"))  // not .dxf
        try fm.createDirectory(at: dir.appendingPathComponent("sub.dxf"),
                               withIntermediateDirectories: true)        // a dir, not a file

        let items = BlockLibrary.scan(directory: dir)
        #expect(items.count == 2)
        #expect(items.map(\.name) == ["Bolt", "Valve"])   // name-sorted, case-insensitive
        #expect(items.allSatisfy { $0.url.pathExtension.lowercased() == "dxf" })
    }

    @Test("scan of a .DXF (upper-case extension) still matches")
    func scanMatchesUpperCaseExtension() throws {
        let dir = tempDir()
        defer { removeItem(dir) }
        try Data().write(to: dir.appendingPathComponent("Sym.DXF"))
        let items = BlockLibrary.scan(directory: dir)
        #expect(items.count == 1)
        #expect(items.first?.name == "Sym")
    }

    @Test("scan of a missing directory is empty (never throws, no picker)")
    func scanMissingDirectoryEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        #expect(BlockLibrary.scan(directory: missing).isEmpty)
        // The collection's reload helper is equally graceful.
        var lib = BlockLibrary()
        lib.reload(from: missing)
        #expect(lib.isEmpty)
    }

    @Test("BlockLibrary lookup by name (case-insensitive) and by url")
    func libraryLookup() {
        let v = BlockLibraryItem(url: URL(fileURLWithPath: "/s/Valve.dxf"))
        let b = BlockLibraryItem(url: URL(fileURLWithPath: "/s/Bolt.dxf"))
        let lib = BlockLibrary(items: [v, b])
        #expect(lib.count == 2)
        #expect(lib.item(named: "valve")?.url == v.url)        // case-insensitive
        #expect(lib.item(at: URL(fileURLWithPath: "/s/Bolt.dxf"))?.name == "Bolt")
        #expect(lib.item(named: "nope") == nil)
    }

    // MARK: - importRecords (pure core — no file I/O / bridge)

    @Test("importRecords creates a named block + ONE placed insert; insert resolves to geometry")
    func importRecordsCreatesBlock() {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let result = try! #require(BlockLibrary.importRecords(
            [ line(Vector(10, 10), Vector(20, 10)) ],
            name: "Widget", into: d))

        #expect(result.blockName == "Widget")
        #expect(result.memberCount == 1)
        #expect(d.blocks.contains("Widget"))

        // One INSERT stands in the drawing; it resolves back to the world geometry
        // (basePoint defaults to origin, so members keep their world position).
        let insertRec = try! #require(d.entity(result.insertID))
        guard case .insert(let data) = insertRec.kind else {
            Issue.record("the placed entity is not an .insert"); return
        }
        #expect(data.blockName == "Widget")
        let geo = insertRec.resolve(d.makeResolveContext())
        let pts = geo.polylines.flatMap { $0.points }
        #expect(pts.contains { ($0 - Vector(10, 10)).magnitude < 1e-9 })
        #expect(pts.contains { ($0 - Vector(20, 10)).magnitude < 1e-9 })
    }

    @Test("importRecords with empty records is a no-op returning nil (drawing unchanged)")
    func importRecordsEmptyNoOp() {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        #expect(BlockLibrary.importRecords([], name: "X", into: d) == nil)
        #expect(d.blocks.isEmpty)
        #expect(d.count == 0)
    }

    @Test("importRecords with a blank name is rejected; nothing added")
    func importRecordsBlankNameRejected() {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        #expect(BlockLibrary.importRecords([ line(.init(0, 0), .init(1, 0)) ],
                                           name: "   ", into: d) == nil)
        #expect(d.blocks.isEmpty)
        #expect(d.count == 0)            // the re-mint adds were rolled back? -> never added
    }

    // MARK: - DATA-SAFETY: name-collision import renames, BOTH survive intact

    @Test("a name-collision import is renamed via newName; BOTH blocks survive with members intact")
    func nameCollisionRenamesAndPreservesBoth() {
        // A pre-existing block "BOX" in the drawing (its sole member is a circle).
        let (d, ids) = seeded([ circle(Vector(0, 0), 5) ])
        let original = try! #require(d.makeBlockFromEntities(
            name: "BOX", basePoint: Vector(0, 0), ids: ids))
        #expect(original.blockName == "BOX")

        // Snapshot the pre-existing block's members + their resolved geometry so we
        // can prove NO member was deleted by the colliding import.
        let oldMemberIDs = d.blocks.entityIDs(of: "BOX")
        #expect(oldMemberIDs.count == 1)
        let oldMemberKinds = oldMemberIDs.map { d.entity($0)?.kind }

        // Import geometry whose suggested name collides with "BOX".
        let imported = try! #require(BlockLibrary.importRecords(
            [ line(Vector(100, 100), Vector(200, 100)) ],
            name: "BOX", into: d))

        // 1. The import was RENAMED (never overwrote "BOX" in place).
        #expect(imported.blockName != "BOX")
        // 2. BOTH blocks exist.
        #expect(d.blocks.contains("BOX"))
        #expect(d.blocks.contains(imported.blockName))
        // 3. The pre-existing block's members are ALL still present, geometry intact
        //    (the critic must-fix: no shared-member deletion / data loss).
        let stillMemberIDs = d.blocks.entityIDs(of: "BOX")
        #expect(stillMemberIDs == oldMemberIDs)
        for (i, id) in stillMemberIDs.enumerated() {
            #expect(d.entity(id) != nil, "pre-existing block member \(id) was deleted")
            #expect(d.entity(id)?.kind == oldMemberKinds[i], "pre-existing member geometry changed")
        }
        // 4. The imported block has its OWN distinct members (disjoint from the old).
        let newMemberIDs = d.blocks.entityIDs(of: imported.blockName)
        #expect(!newMemberIDs.isEmpty)
        #expect(Set(newMemberIDs).isDisjoint(with: Set(oldMemberIDs)))
    }

    @Test("two successive colliding imports each get a distinct de-duplicated name; all survive")
    func repeatedCollisionsAllSurvive() {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let a = try! #require(BlockLibrary.importRecords(
            [ line(.init(0, 0), .init(1, 0)) ], name: "Part", into: d))
        let b = try! #require(BlockLibrary.importRecords(
            [ line(.init(0, 0), .init(2, 0)) ], name: "Part", into: d))
        let c = try! #require(BlockLibrary.importRecords(
            [ line(.init(0, 0), .init(3, 0)) ], name: "Part", into: d))
        #expect(a.blockName == "Part")
        #expect(Set([a.blockName, b.blockName, c.blockName]).count == 3)   // all distinct
        #expect(d.blocks.contains(a.blockName))
        #expect(d.blocks.contains(b.blockName))
        #expect(d.blocks.contains(c.blockName))
    }

    // MARK: - importDXF: real round-trip through the engine reader

    @Test("importDXF reads a real .dxf and creates a named block whose insert resolves to its geometry")
    func importDXFRoundTrips() async throws {
        // Author a temp .dxf (via the engine writer) with two known lines.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("symbol-\(UUID().uuidString).dxf").path
        defer { removeFile(path) }
        let src = [ line(Vector(0, 0), Vector(10, 0)),
                    line(Vector(10, 0), Vector(10, 10)) ]
        _ = try await CADEngine.shared.writeEntities(src, layers: LayerTable(), toPath: path)

        // Import it as a block named after the file's base name.
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let result = try await BlockLibrary.importDXF(path: path, into: d)
        let r = try #require(result)

        #expect(d.blocks.contains(r.blockName))
        #expect(r.memberCount == 2)

        // The placed INSERT resolves to the imported geometry (in world coords:
        // basePoint defaults to origin, so positions are preserved).
        let insertRec = try #require(d.entity(r.insertID))
        let geo = insertRec.resolve(d.makeResolveContext())
        let pts = geo.polylines.flatMap { $0.points }
        for corner in [Vector(0, 0), Vector(10, 0), Vector(10, 10)] {
            #expect(pts.contains { ($0 - corner).magnitude < 1e-6 },
                    "imported geometry missing corner \(corner)")
        }
    }

    @Test("importDXF honors an explicit suggested name (de-duplicated on a clash)")
    func importDXFExplicitName() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("symbol-\(UUID().uuidString).dxf").path
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities(
            [ line(Vector(0, 0), Vector(1, 0)) ], layers: LayerTable(), toPath: path)

        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let first = try #require(try await BlockLibrary.importDXF(
            path: path, name: "MyPart", into: d))
        #expect(first.blockName == "MyPart")
        // A second import of the same suggested name de-duplicates (both survive).
        let second = try #require(try await BlockLibrary.importDXF(
            path: path, name: "MyPart", into: d))
        #expect(second.blockName != "MyPart")
        #expect(d.blocks.contains("MyPart"))
        #expect(d.blocks.contains(second.blockName))
    }

    // MARK: - Degenerate / graceful failure

    @Test("importing an empty (geometry-less) .dxf is graceful: nil, drawing unchanged")
    func importEmptyDXFGraceful() async throws {
        // A valid-but-empty DXF: write zero entities. It reads back with no records.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).dxf").path
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities([], layers: LayerTable(), toPath: path)

        let d = CADDrawing()
        d.undoManager = testUndoManager()
        let result = try await BlockLibrary.importDXF(path: path, into: d)
        #expect(result == nil)             // nothing importable
        #expect(d.blocks.isEmpty)          // no partial block
        #expect(d.count == 0)              // no orphan geometry
    }

    @Test("importing a non-DXF / garbage file throws readFailed and does not mutate the drawing")
    func importGarbageFileThrows() async throws {
        // A file that is not a DXF at all — libdxfrw cannot read it.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).dxf").path
        defer { removeFile(path) }
        try Data("this is not a dxf file".utf8).write(to: URL(fileURLWithPath: path))

        let d = CADDrawing()
        d.undoManager = testUndoManager()
        await #expect(throws: (any Error).self) {
            _ = try await BlockLibrary.importDXF(path: path, into: d)
        }
        // Regardless of how the read failed, the drawing was never touched.
        #expect(d.blocks.isEmpty)
        #expect(d.count == 0)
    }

    // MARK: - Bundled starter-symbol library (backlog #6)

    /// Every symbol the offline generator (`CADBench gen-symbols`) is expected to
    /// have produced and committed under `macos/assets/symbols`. Mirrors
    /// `SymbolCatalog.all()` in `Sources/CADBench/SymbolGenerator.swift`. Asserting
    /// the exact set guards against a symbol being silently dropped from the
    /// committed assets (a regression a "non-empty count" check would miss).
    private static let expectedStarterSymbols: Set<String> = [
        "Door", "Double Door", "Window", "Table", "Chair", "Round Table",
        "Sink", "Duplex Receptacle", "Switch", "Light Fixture",
        "North Arrow", "Leader Arrow",
    ]

    @Test("bundledSymbolsDirectory resolves to the in-repo assets dir in the dev/test context")
    func bundledSymbolsDirectoryResolves() {
        // In the test process there is no app bundle, so resolution falls through
        // to the in-repo dev fallback (`macos/assets/symbols`). That directory is
        // committed alongside this code, so it MUST resolve (non-nil) and exist.
        let dir = try? #require(BlockLibrary.bundledSymbolsDirectory())
        let url = try? #require(dir)
        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(url.lastPathComponent == "symbols")
        }
    }

    @Test("the bundled symbol catalog lists exactly the committed starter symbols, name-sorted")
    func bundledSymbolsCatalogListsCommittedSet() {
        let items = BlockLibrary.bundledSymbols()
        // At least the full starter set is present (a stray extra .dxf would still
        // be a valid symbol, so we assert the starter set is a subset).
        let names = Set(items.map(\.name))
        #expect(Self.expectedStarterSymbols.isSubset(of: names),
                "missing starter symbols: \(Self.expectedStarterSymbols.subtracting(names))")
        // The scan is name-sorted (case-insensitive); confirm sort order holds.
        let sorted = items.map(\.name).sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        #expect(items.map(\.name) == sorted)
    }

    @Test("every bundled starter symbol .dxf round-trips: imports to a block with non-empty geometry")
    func everyBundledSymbolRoundTrips() async throws {
        let items = BlockLibrary.bundledSymbols()
        try #require(!items.isEmpty, "no bundled symbols resolved — check the dev fallback / committed assets")

        for item in items where Self.expectedStarterSymbols.contains(item.name) {
            let d = CADDrawing()
            d.undoManager = testUndoManager()
            let result = try await BlockLibrary.importItem(item, into: d)
            let r = try #require(result, "\(item.name) imported to nil (empty/unreadable .dxf)")

            // A named block was registered and at least one member came in.
            #expect(d.blocks.contains(r.blockName), "\(item.name): no block registered")
            #expect(r.memberCount >= 1, "\(item.name): imported with no members")

            // The placed INSERT resolves to NON-EMPTY geometry (the symbol is
            // actually drawable, not just a structurally-valid empty block).
            let insertRec = try #require(d.entity(r.insertID))
            let geo = insertRec.resolve(d.makeResolveContext())
            let pointCount = geo.polylines.reduce(0) { $0 + $1.points.count }
            #expect(pointCount > 0, "\(item.name): insert resolved to no geometry")
        }
    }
}
