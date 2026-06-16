//
//  PurgeTests.swift
//  CADEngineTests
//
//  Exercises the pure `Purge` analysis: a fixture drawing carrying USED + UNUSED
//  layers / blocks / dim-styles is fed to `Purge.plan(...)`, which must report
//  EXACTLY the unused names per category while protecting the always-kept names
//  (layer "0", the active layer/block, "Standard", the active dim-style). Also
//  covers transitive (nested) block usage, the pinned-layer escape hatch, the
//  empty/degenerate drawing, and the `@MainActor` `apply(_:to:)` round-trip.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Purge — unused named-object analysis")
struct PurgeTests {

    // MARK: - Fixtures

    /// A line on `layer`, id `id`, with the default by-layer pen.
    private func line(_ id: UInt64, layer: String) -> EntityRecord {
        EntityRecord(id: EntityID(id), layer: LayerID(layer),
                     kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
    }

    /// A point at `p`, id `id`, on layer "0".
    private func point(_ id: UInt64, _ p: Vector = Vector(0, 0)) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .point(PointData(position: p)))
    }

    /// An INSERT of `blockName`, id `id`, on layer "0".
    private func insert(_ id: UInt64, block blockName: String) -> EntityRecord {
        EntityRecord(id: EntityID(id),
                     kind: .insert(InsertData(blockName: blockName,
                                              insertionPoint: Vector(0, 0))))
    }

    /// A linear dimension referencing dim-style `styleName`, id `id`.
    private func dimension(_ id: UInt64, style styleName: String?) -> EntityRecord {
        let dk = DimKind.aligned(extension1: Vector(0, 0), extension2: Vector(10, 0))
        let dd = DimData(kind: dk, definitionPoint: Vector(0, 5), styleName: styleName)
        return EntityRecord(id: EntityID(id), kind: .dimension(dd))
    }

    /// A dim-style table with the named styles plus an active name.
    private func dimStyleTable(_ names: [String], active: String? = nil) -> DimStyleTable {
        let styles = names.map { NamedDimStyle(name: $0, style: ResolvedDimStyle()) }
        return DimStyleTable(styles: styles, activeName: active)
    }

    // MARK: - Layers

    @Test("identifies exactly the unused layers; protects '0' + active + used")
    func unusedLayers() {
        var layers = LayerTable()                 // starts with "0", active "0"
        _ = layers.add(Layer(name: "used"))
        _ = layers.add(Layer(name: "unusedA"))
        _ = layers.add(Layer(name: "unusedB"))
        _ = layers.add(Layer(name: "active-empty"))
        layers.activate("active-empty")           // active layer, even though empty

        let entities = [line(1, layer: "used")]   // only "used" is referenced

        let plan = Purge.plan(entities: entities, layers: layers,
                              blocks: BlockTable(), dimStyles: DimStyleTable())

        #expect(Set(plan.layers) == ["unusedA", "unusedB"])
        #expect(!plan.layers.contains("0"))            // DXF default protected
        #expect(!plan.layers.contains("used"))         // referenced
        #expect(!plan.layers.contains("active-empty")) // active layer protected
    }

    @Test("layer '0' is never purged even when no entity is on it")
    func layerZeroAlwaysProtected() {
        var layers = LayerTable()
        _ = layers.add(Layer(name: "x"))
        layers.activate("x")
        // Everything on "x"; "0" referenced by nothing, but must stay.
        let entities = [line(1, layer: "x")]
        let plan = Purge.plan(entities: entities, layers: layers,
                              blocks: BlockTable(), dimStyles: DimStyleTable())
        #expect(!plan.layers.contains("0"))
        #expect(plan.layers.isEmpty)   // "x" is active+used, "0" protected
    }

    @Test("pinnedLayers protects an otherwise-unused layer")
    func pinnedLayerProtected() {
        var layers = LayerTable()
        _ = layers.add(Layer(name: "pinned"))
        _ = layers.add(Layer(name: "loose"))
        let entities: [EntityRecord] = [point(1)]   // on "0"

        let plan = Purge.plan(entities: entities, layers: layers,
                              blocks: BlockTable(), dimStyles: DimStyleTable(),
                              pinnedLayers: ["pinned"])
        #expect(Set(plan.layers) == ["loose"])
        #expect(!plan.layers.contains("pinned"))
    }

    // MARK: - Blocks

    @Test("identifies an unused block; an inserted block is kept")
    func unusedBlocks() {
        var blocks = BlockTable()
        _ = blocks.add(Block(name: "USED"))
        _ = blocks.add(Block(name: "ORPHAN"))

        let entities = [insert(1, block: "USED")]   // ORPHAN inserted by nobody
        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: blocks, dimStyles: DimStyleTable())
        #expect(Set(plan.blocks) == ["ORPHAN"])
    }

    @Test("the active block is protected even if uninserted")
    func activeBlockProtected() {
        var blocks = BlockTable()
        _ = blocks.add(Block(name: "ACTIVE"))
        _ = blocks.add(Block(name: "ORPHAN"))
        blocks.activate("ACTIVE")

        let plan = Purge.plan(entities: [], layers: LayerTable(),
                              blocks: blocks, dimStyles: DimStyleTable())
        #expect(Set(plan.blocks) == ["ORPHAN"])
        #expect(!plan.blocks.contains("ACTIVE"))
    }

    @Test("nested usage: a block inserted only by a USED block's member is kept")
    func nestedBlockUsageKept() {
        // NESTED is inserted by an entity that is a MEMBER of OUTER; OUTER is
        // inserted at the top level → both OUTER and NESTED are transitively used.
        let nestedInsertInsideOuter = insert(100, block: "NESTED")   // member of OUTER
        let topInsertOfOuter = insert(1, block: "OUTER")

        var blocks = BlockTable()
        _ = blocks.add(Block(name: "OUTER", entityIDs: [EntityID(100)]))
        _ = blocks.add(Block(name: "NESTED"))

        let entities = [topInsertOfOuter, nestedInsertInsideOuter]
        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: blocks, dimStyles: DimStyleTable())
        #expect(plan.blocks.isEmpty)   // both reachable → nothing to purge
    }

    @Test("nested usage: a block inserted only by an UNUSED block is purged too")
    func nestedBlockInsideUnusedIsPurged() {
        // GHOST is inserted ONLY by a member of OUTER, and OUTER is inserted by
        // nobody → both OUTER and GHOST are unused and both should be purged.
        let ghostInsertInsideOuter = insert(100, block: "GHOST")    // member of OUTER
        var blocks = BlockTable()
        _ = blocks.add(Block(name: "OUTER", entityIDs: [EntityID(100)]))
        _ = blocks.add(Block(name: "GHOST"))

        let entities = [ghostInsertInsideOuter]    // no top-level insert of OUTER
        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: blocks, dimStyles: DimStyleTable())
        #expect(Set(plan.blocks) == ["OUTER", "GHOST"])
    }

    // MARK: - Dim-styles

    @Test("identifies unused dim-styles; protects Standard + active + referenced")
    func unusedDimStyles() {
        let table = dimStyleTable(["Standard", "USED", "ACTIVE", "ORPHAN"],
                                  active: "ACTIVE")
        let entities = [dimension(1, style: "USED")]

        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: BlockTable(), dimStyles: table)
        #expect(Set(plan.dimStyles) == ["ORPHAN"])
        #expect(!plan.dimStyles.contains("Standard"))
        #expect(!plan.dimStyles.contains("ACTIVE"))
        #expect(!plan.dimStyles.contains("USED"))
    }

    @Test("dim-style usage matching is case-insensitive (AutoCAD table names)")
    func dimStyleUsageCaseInsensitive() {
        let table = dimStyleTable(["Standard", "ISO-25"])
        // Reference it with different casing — it must still count as used.
        let entities = [dimension(1, style: "iso-25")]
        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: BlockTable(), dimStyles: table)
        #expect(plan.dimStyles.isEmpty)
    }

    @Test("a leader's styleName also keeps its dim-style")
    func leaderStyleNameCountsAsUsed() {
        let table = dimStyleTable(["Standard", "VIA-LEADER"])
        var ld = LeaderData(vertices: [Vector(0, 0), Vector(5, 5)])
        ld.styleName = "VIA-LEADER"
        let entities = [EntityRecord(id: EntityID(1), kind: .leader(ld))]
        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: BlockTable(), dimStyles: table)
        #expect(plan.dimStyles.isEmpty)
    }

    @Test("an empty/whitespace dim styleName does not protect any style")
    func emptyStyleNameIgnored() {
        let table = dimStyleTable(["Standard", "EXTRA"])
        let entities = [dimension(1, style: "   "), dimension(2, style: nil)]
        let plan = Purge.plan(entities: entities, layers: LayerTable(),
                              blocks: BlockTable(), dimStyles: table)
        #expect(Set(plan.dimStyles) == ["EXTRA"])
    }

    // MARK: - Line-types + degenerate cases

    @Test("line-types are always empty (no named registry today)")
    func lineTypesAlwaysEmpty() {
        let plan = Purge.plan(entities: [], layers: LayerTable(),
                              blocks: BlockTable(), dimStyles: DimStyleTable())
        #expect(plan.lineTypes.isEmpty)
    }

    @Test("a fresh empty drawing has nothing to purge")
    func emptyDrawingNoPurge() {
        let plan = Purge.plan(entities: [], layers: LayerTable(),
                              blocks: BlockTable(), dimStyles: DimStyleTable())
        #expect(plan.isEmpty)
        #expect(plan.totalCount == 0)
    }

    @Test("totalCount sums across categories")
    func totalCountSums() {
        var layers = LayerTable()
        _ = layers.add(Layer(name: "L1"))
        _ = layers.add(Layer(name: "L2"))
        var blocks = BlockTable()
        _ = blocks.add(Block(name: "B1"))
        let table = dimStyleTable(["Standard", "D1"])

        let plan = Purge.plan(entities: [], layers: layers,
                              blocks: blocks, dimStyles: table)
        // L1+L2 (layers), B1 (block), D1 (dimstyle) = 4.
        #expect(plan.totalCount == 4)
        #expect(Set(plan.layers) == ["L1", "L2"])
        #expect(Set(plan.blocks) == ["B1"])
        #expect(Set(plan.dimStyles) == ["D1"])
    }

    // MARK: - @MainActor apply round-trip

    @MainActor
    @Test("plan(for:) + apply(_:to:) removes exactly the unused objects")
    func applyToLiveDrawing() {
        let d = CADDrawing()
        _ = d.addLayer(Layer(name: "used"))
        _ = d.addLayer(Layer(name: "dead"))
        _ = d.addBlock(Block(name: "ALIVE"))
        _ = d.addBlock(Block(name: "DEAD"))
        d.dimStyles = dimStyleTable(["Standard", "DEADSTYLE"])

        _ = d.add(line(1, layer: "used"))
        _ = d.add(insert(2, block: "ALIVE"))

        let plan = Purge.plan(for: d)
        #expect(Set(plan.layers) == ["dead"])
        #expect(Set(plan.blocks) == ["DEAD"])
        #expect(Set(plan.dimStyles) == ["DEADSTYLE"])

        let removed = Purge.apply(plan, to: d)
        #expect(removed == 3)
        #expect(d.layers.contains("used"))
        #expect(!d.layers.contains("dead"))
        #expect(d.layers.contains("0"))            // protected, still present
        #expect(d.blocks.contains("ALIVE"))
        #expect(!d.blocks.contains("DEAD"))
        #expect(d.dimStyles.contains("Standard"))
        #expect(!d.dimStyles.contains("DEADSTYLE"))
        // Entities untouched.
        #expect(d.count == 2)
    }

    @MainActor
    @Test("apply on an empty plan is a no-op returning 0")
    func applyEmptyPlanNoOp() {
        let d = CADDrawing()
        _ = d.add(point(1))
        let removed = Purge.apply(PurgePlan(), to: d)
        #expect(removed == 0)
        #expect(d.count == 1)
    }
}
