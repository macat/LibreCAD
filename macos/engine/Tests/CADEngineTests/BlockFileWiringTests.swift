//
//  BlockFileWiringTests.swift
//  CADEngineTests
//
//  Covers the WIRING behind the Blocks file menus ("Insert Block from File… (DXF)" and
//  "Save Block to File… (WBLOCK)") + the panel-header relocation of the freeze menu —
//  the work done in this wave on top of the already-tested engine seams
//  (`BlockLibrary.importDXF` / `BlockExport.writeBlock`, covered by `BlockLibraryTests`
//  and `BlockExportTests`).
//
//  Two layers are exercised PURELY (no `NSOpenPanel`/`NSSavePanel` is ever reached — the
//  modal lives in the View layer, `ContentView`, which a headless test must never touch):
//
//    1. The engine FLOW the View closures call: importing a real `.dxf` adds a block + a
//       placed insert; saving a block to a file then re-importing it reproduces the
//       block's geometry (the round-trip the "Insert/Save Block to File" pair forms).
//
//    2. The pure menu-target picker `BlockFileMenuWiring.saveTargetName(selectionIDs:in:)`
//       — the SwiftUI-free logic the menu-bar "Save Block to File…" item uses to choose
//       WHICH block to save (the selected insert's block, else the first block, else nil
//       which disables the item). Reached via the established `_SharedSidebarLayoutConfig`
//       symlink (the helper lives in that Foundation+CADEngine file).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("block file menu wiring (insert/save block from file)")
struct BlockFileWiringTests {

    // MARK: - Helpers

    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    private func line(_ a: Vector, _ b: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(0), kind: .line(LineData(start: a, end: b)))
    }

    private func newDrawing() -> CADDrawing {
        let d = CADDrawing()
        d.undoManager = testUndoManager()
        return d
    }

    private func tempDXFPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("blockfile-wire-\(UUID().uuidString).dxf").path
    }

    private func removeFile(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    /// All world points across a record's resolved polylines (for geometry assertions).
    private func resolvedPoints(_ record: EntityRecord, in d: CADDrawing) -> [Vector] {
        record.resolve(d.makeResolveContext()).polylines.flatMap { $0.points }
    }

    // MARK: - "Insert Block from File…" flow (the engine call the View closure makes)

    @Test("insert-from-file flow: importDXF adds a NAMED block + a placed insert resolving to the file geometry")
    func insertFromFileAddsBlockAndInsert() async throws {
        // Author a temp symbol .dxf (the file the NSOpenPanel would pick).
        let path = tempDXFPath()
        defer { removeFile(path) }
        let src = [ line(Vector(0, 0), Vector(20, 0)),
                    line(Vector(20, 0), Vector(20, 5)) ]
        _ = try await CADEngine.shared.writeEntities(src, layers: LayerTable(), toPath: path)

        // The View closure's core: import the chosen file into the drawing.
        let d = newDrawing()
        #expect(d.blocks.blocks.isEmpty)
        let result = try #require(try await BlockLibrary.importDXF(path: path, into: d))

        // A named block now exists with both members, plus the placed insert.
        #expect(d.blocks.contains(result.blockName))
        #expect(result.memberCount == 2)
        let insert = try #require(d.entity(result.insertID))
        if case .insert(let data) = insert.kind {
            #expect(data.blockName == result.blockName)
        } else {
            Issue.record("imported placement is not an .insert")
        }
        // The insert resolves to the imported geometry (origin basePoint ⇒ world positions kept).
        let pts = resolvedPoints(insert, in: d)
        for corner in [Vector(0, 0), Vector(20, 0), Vector(20, 5)] {
            #expect(pts.contains { ($0 - corner).magnitude < 1e-6 },
                    "inserted block missing corner \(corner)")
        }
    }

    @Test("insert-from-file is collision-safe: importing the same file twice keeps BOTH blocks")
    func insertFromFileCollisionSafe() async throws {
        let path = tempDXFPath()
        defer { removeFile(path) }
        _ = try await CADEngine.shared.writeEntities(
            [ line(Vector(0, 0), Vector(1, 1)) ], layers: LayerTable(), toPath: path)

        let d = newDrawing()
        let first = try #require(try await BlockLibrary.importDXF(path: path, into: d))
        let second = try #require(try await BlockLibrary.importDXF(path: path, into: d))
        #expect(first.blockName != second.blockName)   // de-duplicated, never overwritten
        #expect(d.blocks.contains(first.blockName))
        #expect(d.blocks.contains(second.blockName))
    }

    // MARK: - "Save Block to File…" flow (writeBlock → file → re-import round-trip)

    @Test("save-block-to-file flow: writeBlock then re-import reproduces the block geometry")
    func saveBlockRoundTrips() async throws {
        // A drawing with one named block (an L-shape) at a non-origin base point.
        let d = newDrawing()
        let a = d.add(line(Vector(0, 0), Vector(4, 0)))
        let b = d.add(line(Vector(4, 0), Vector(4, 3)))
        let creation = try #require(d.makeBlockFromEntities(
            name: "Bracket", basePoint: Vector(0, 0), ids: [a, b]))

        // The View closure's core: write the named block to a standalone .dxf.
        let path = tempDXFPath()
        defer { removeFile(path) }
        let exportResult = try #require(
            try await BlockExport.writeBlock(d, name: creation.blockName, toPath: path))
        #expect(exportResult.recordCount == 2)

        // Re-import the saved file into a FRESH drawing: the geometry comes back.
        let d2 = newDrawing()
        let imported = try #require(try await BlockLibrary.importDXF(path: path, into: d2))
        #expect(imported.memberCount == 2)
        let insert = try #require(d2.entity(imported.insertID))
        let pts = resolvedPoints(insert, in: d2)
        for corner in [Vector(0, 0), Vector(4, 0), Vector(4, 3)] {
            #expect(pts.contains { ($0 - corner).magnitude < 1e-6 },
                    "re-imported saved block missing corner \(corner)")
        }
    }

    @Test("save-block-to-file of an unknown block writes nothing (nil), no file produced")
    func saveUnknownBlockGraceful() async throws {
        let d = newDrawing()
        let path = tempDXFPath()
        defer { removeFile(path) }
        let result = try await BlockExport.writeBlock(d, name: "NoSuchBlock", toPath: path)
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Pure menu-target picker (BlockFileMenuWiring.saveTargetName)

    @Test("save-target is nil (item disabled) when the drawing defines no blocks")
    func saveTargetNilWithoutBlocks() {
        let d = newDrawing()
        _ = d.add(line(Vector(0, 0), Vector(1, 0)))   // geometry but no blocks
        #expect(BlockFileMenuWiring.saveTargetName(selectionIDs: [], in: d) == nil)
        #expect(BlockFileMenuWiring.saveTargetName(selectionIDs: Set([EntityID(0)]), in: d) == nil)
    }

    @Test("save-target falls back to the FIRST defined block when nothing relevant is selected")
    func saveTargetFirstBlockFallback() throws {
        let d = newDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        let first = try #require(d.makeBlockFromEntities(name: "Alpha", basePoint: .init(0, 0), ids: [a]))
        let b = d.add(line(Vector(2, 0), Vector(3, 0)))
        _ = try #require(d.makeBlockFromEntities(name: "Beta", basePoint: .init(0, 0), ids: [b]))
        // No selection → first defined block.
        #expect(BlockFileMenuWiring.saveTargetName(selectionIDs: [], in: d) == first.blockName)
        #expect(d.blocks.blocks.first?.name == first.blockName)
    }

    @Test("save-target prefers the block of a SELECTED insert over the first-block fallback")
    func saveTargetSelectedInsert() throws {
        let d = newDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        _ = try #require(d.makeBlockFromEntities(name: "Alpha", basePoint: .init(0, 0), ids: [a]))
        let b = d.add(line(Vector(2, 0), Vector(3, 0)))
        let beta = try #require(d.makeBlockFromEntities(name: "Beta", basePoint: .init(0, 0), ids: [b]))
        // Selecting Beta's insert makes it the target even though Alpha is first.
        let target = BlockFileMenuWiring.saveTargetName(selectionIDs: [beta.insertID], in: d)
        #expect(target == "Beta")
    }

    @Test("save-target ignores a selected NON-insert (a plain line) and falls back to the first block")
    func saveTargetIgnoresNonInsert() throws {
        let d = newDrawing()
        let a = d.add(line(Vector(0, 0), Vector(1, 0)))
        let alpha = try #require(d.makeBlockFromEntities(name: "Alpha", basePoint: .init(0, 0), ids: [a]))
        let plain = d.add(line(Vector(5, 5), Vector(6, 6)))   // not an insert
        let target = BlockFileMenuWiring.saveTargetName(selectionIDs: [plain], in: d)
        #expect(target == alpha.blockName)
    }
}
