//
//  Purge.swift
//  CADEngine
//
//  "Purge" — pure analysis of which NAMED objects (layers / blocks / dim-styles /
//  line-types) the drawing defines but NO entity references, mirroring LibreCAD's
//  `RS_Graphic` purge / AutoCAD's PURGE command. This file is ANALYSIS ONLY: it
//  inspects a drawing's entity list + name tables and returns a `PurgePlan` — the
//  set of names safe to remove per category — WITHOUT mutating anything (ADR-002:
//  the app applies the plan later through the existing undoable funnels
//  `CADDrawing.removeLayer` / `removeBlock` / `mutateDimStyles`, inside
//  ONE undo group, so a single ⌘Z reverts the whole purge).
//
//  ## What counts as "used"
//  - **Layer**: referenced by `EntityRecord.layer` of any entity. Protected
//    regardless of use: layer "0" (DXF requires it), the active layer (new
//    entities land there), and — at the caller's option — any explicitly pinned
//    name (e.g. the layer of a visible UI selection).
//  - **Block**: referenced by an `.insert(blockName:)`. Usage is TRANSITIVE — a
//    block whose only references come from another block's members is "used" only
//    if that owning block is itself used (a fixpoint walk from the top-level
//    entities). The active block is protected.
//  - **Dim-style**: referenced by a `.dimension`/`.leader`'s `styleName` (DXF code
//    3). "Standard" is protected (the always-present fallback style), as is the
//    active style.
//  - **Line-type**: the engine models line types as the fixed `PenLineType` enum
//    (no user-named LTYPE registry — see `Pen.swift`), so there are no *named*
//    line-types to purge. The category is carried in the plan for API symmetry +
//    forward-compat (it is always empty today); see `PurgePlan.lineTypes`.
//
//  Pure value logic over the value-type tables (no `@MainActor`, no GPU, no UI) so
//  it unit-tests without a live document; a `@MainActor` convenience that reads a
//  `CADDrawing` is provided for the app/wire-wave.
//
//  `static` members of a namespaced `enum` (CONVENTIONS.md §7: no module-scope
//  free functions in a fan-out target — keep helpers as static members so parallel
//  modules don't redeclare).
//
//  GPLv2-or-later (LibreCAD derivative). Purge semantics port RS_Graphic's purge /
//  AutoCAD PURGE.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Graphic).
//

import Foundation

// MARK: - The purge plan (the names to remove, per category)

/// The result of a purge analysis: the names of the unused named objects, grouped
/// by category. A pure value type (`Sendable`) — it carries no object references,
/// only names, so it crosses actor boundaries freely and snapshots cheaply. The
/// app applies it by feeding each list to the matching undoable removal funnel
/// inside one undo group (see the file header). Empty lists mean "nothing to
/// purge in that category".
public struct PurgePlan: Sendable, Hashable {
    /// Layer names safe to remove (referenced by no entity; never includes "0",
    /// the active layer, or a pinned name).
    public var layers: [String]
    /// Block names safe to remove (referenced — transitively — by no `.insert`;
    /// never includes the active block).
    public var blocks: [String]
    /// Dim-style names safe to remove (referenced by no dimension/leader; never
    /// includes "Standard" or the active style).
    public var dimStyles: [String]
    /// Named line-types safe to remove. Always empty in the current engine (line
    /// types are a fixed enum, not a named registry — see the file header); kept
    /// for API symmetry + forward-compat with a future LTYPE table.
    public var lineTypes: [String]

    public init(layers: [String] = [],
                blocks: [String] = [],
                dimStyles: [String] = [],
                lineTypes: [String] = []) {
        self.layers = layers
        self.blocks = blocks
        self.dimStyles = dimStyles
        self.lineTypes = lineTypes
    }

    /// Whether the plan would remove nothing at all (every category empty).
    public var isEmpty: Bool {
        layers.isEmpty && blocks.isEmpty && dimStyles.isEmpty && lineTypes.isEmpty
    }

    /// The total number of named objects the plan would remove (across all
    /// categories) — handy for a "Purge N objects?" confirmation.
    public var totalCount: Int {
        layers.count + blocks.count + dimStyles.count + lineTypes.count
    }
}

// MARK: - Purge analysis

/// Pure purge analysis (`static` members of a namespaced `enum`, CONVENTIONS.md).
/// Every entry point takes value-type inputs (the entity list + name tables) and
/// returns a `PurgePlan`; nothing here mutates. A `@MainActor` convenience reads a
/// `CADDrawing` and forwards to the pure core.
public enum Purge {

    // MARK: Used-name collection

    /// The set of layer names ANY entity references (`EntityRecord.layer.name`).
    /// This is the "used layers" set; subtract it (plus the protected names) from
    /// the layer table to get the purgeable layers.
    public static func usedLayerNames(in entities: [EntityRecord]) -> Set<String> {
        var used = Set<String>()
        used.reserveCapacity(entities.count)
        for e in entities { used.insert(e.layer.name) }
        return used
    }

    /// The set of block names referenced — TRANSITIVELY — by the drawing.
    ///
    /// A block is used if a top-level entity (one that is NOT a member of any
    /// block) inserts it, OR a member of an already-used block inserts it. We seed
    /// the worklist from top-level `.insert` references, then fixpoint-expand by
    /// following inserts that live inside used blocks' member lists. This matches
    /// AutoCAD PURGE's "nested" handling: a block referenced only from inside an
    /// otherwise-unused block is itself unused (both fall away together).
    ///
    /// - Parameters:
    ///   - entities: the whole drawing entity list (id-addressable inserts).
    ///   - blocks: the block table (member id-lists for the transitive walk).
    public static func usedBlockNames(in entities: [EntityRecord],
                                      blocks: BlockTable) -> Set<String> {
        // id → entity for resolving a block's member inserts.
        var byID = [EntityID: EntityRecord](minimumCapacity: entities.count)
        for e in entities { byID[e.id] = e }

        // The set of entity ids that are a member of SOME block (so the complement
        // is "top level"). A member referenced by no insert is still part of its
        // owning block's geometry — but it only counts toward usage once the owning
        // block is reached in the fixpoint below.
        var memberIDs = Set<EntityID>()
        for b in blocks.blocks { memberIDs.formUnion(b.entityIDs) }

        // The names a given entity list inserts (DXF code 2 of each `.insert`).
        func insertedNames<S: Sequence>(in records: S) -> [String]
        where S.Element == EntityRecord {
            var names = [String]()
            for r in records {
                if case .insert(let d) = r.kind { names.append(d.blockName) }
            }
            return names
        }

        // Seed: every block inserted by a TOP-LEVEL entity (not inside any block).
        let topLevel = entities.filter { !memberIDs.contains($0.id) }
        var used = Set<String>()
        var work = [String]()
        for name in insertedNames(in: topLevel) where blocks.contains(name) {
            if used.insert(name).inserted { work.append(name) }
        }

        // Fixpoint: a used block's member inserts pull in further blocks.
        while let name = work.popLast() {
            guard let block = blocks.block(named: name) else { continue }
            let members = block.entityIDs.compactMap { byID[$0] }
            for nested in insertedNames(in: members) where blocks.contains(nested) {
                if used.insert(nested).inserted { work.append(nested) }
            }
        }
        return used
    }

    /// The set of dim-style names referenced by any dimension or leader (DXF code
    /// 3, `DimData.styleName` / `LeaderData.styleName`). Case-insensitive style
    /// matching is the table's job (`DimStyleTable.style(named:)`); here we collect
    /// the raw referenced names. Empty / whitespace-only style names are ignored
    /// (they mean "no explicit style ⇒ the active/Standard default").
    public static func usedDimStyleNames(in entities: [EntityRecord]) -> Set<String> {
        var used = Set<String>()
        for e in entities {
            let name: String?
            switch e.kind {
            case .dimension(let d): name = d.styleName
            case .leader(let d):    name = d.styleName
            default:                name = nil
            }
            if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                used.insert(n)
            }
        }
        return used
    }

    // MARK: Plan builder (pure)

    /// Builds the purge plan from value-type inputs — the core every overload
    /// funnels through. Nothing here mutates.
    ///
    /// - Parameters:
    ///   - entities: the drawing's entity list.
    ///   - layers: the layer table (names + active layer).
    ///   - blocks: the block table (names + active block + member id-lists).
    ///   - dimStyles: the dim-style table (names + active style).
    ///   - pinnedLayers: extra layer names to protect from purge regardless of use
    ///     (e.g. a UI selection's layer, or a layer the user explicitly excluded).
    ///     "0" and the active layer are ALWAYS protected on top of this.
    /// - Returns: a `PurgePlan` whose lists are the unused names per category, each
    ///   in the table's stable definition order (deterministic output).
    public static func plan(entities: [EntityRecord],
                            layers: LayerTable,
                            blocks: BlockTable,
                            dimStyles: DimStyleTable,
                            pinnedLayers: Set<String> = []) -> PurgePlan {
        // --- Layers ---
        let usedLayers = usedLayerNames(in: entities)
        var protectedLayers = pinnedLayers
        protectedLayers.insert("0")                       // DXF default — never purge
        protectedLayers.insert(layers.activeLayerName)     // new entities land here
        let purgeLayers = layers.layers
            .map(\.name)
            .filter { !usedLayers.contains($0) && !protectedLayers.contains($0) }

        // --- Blocks ---
        let usedBlocks = usedBlockNames(in: entities, blocks: blocks)
        let activeBlock = blocks.activeBlockName
        let purgeBlocks = blocks.blocks
            .map(\.name)
            .filter { $0 != activeBlock && !usedBlocks.contains($0) }

        // --- Dim-styles ---
        let usedDimStyles = usedDimStyleNames(in: entities)
        // Match the table's case-insensitive identity when deciding "used".
        func isDimStyleUsed(_ name: String) -> Bool {
            usedDimStyles.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        let activeDimStyle = dimStyles.active()?.name
        let purgeDimStyles = dimStyles.styles
            .map(\.name)
            .filter { name in
                // "Standard" is the always-present fallback (DimStyleTable.remove
                // refuses to drop it); the active style is protected too.
                name.caseInsensitiveCompare("Standard") != .orderedSame
                    && !(activeDimStyle.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false)
                    && !isDimStyleUsed(name)
            }

        // --- Line-types --- (no named registry today; always empty — see header.)
        return PurgePlan(layers: purgeLayers,
                         blocks: purgeBlocks,
                         dimStyles: purgeDimStyles,
                         lineTypes: [])
    }

    // MARK: @MainActor convenience (reads a live CADDrawing)

    /// Computes the purge plan for a live document. Reads the drawing's entity
    /// list + name tables on the main actor and forwards to the pure `plan(...)`
    /// core. Does NOT mutate the drawing — the caller applies the returned plan via
    /// the undoable removal funnels (one undo group). See `apply(_:to:)`.
    @MainActor
    public static func plan(for drawing: CADDrawing,
                            pinnedLayers: Set<String> = []) -> PurgePlan {
        plan(entities: drawing.entities,
             layers: drawing.layers,
             blocks: drawing.blocks,
             dimStyles: drawing.dimStyles,
             pinnedLayers: pinnedLayers)
    }

    /// Applies a `PurgePlan` to a live drawing as ONE undo group, so a single ⌘Z
    /// reverts the whole purge. Each removal goes through the drawing's existing
    /// path: layers via `removeLayer` (no reassign — by construction no entity
    /// references them), blocks via `removeBlock` (definition only; the plan never
    /// lists a block whose members are still in use), and dim-styles via the
    /// undoable `mutateDimStyles` funnel. Returns the number of named objects removed.
    ///
    /// This is the wire-wave entry point; it is `@MainActor` (it mutates the
    /// document) and is deliberately tiny — the policy lives in `plan(...)`.
    ///
    /// - Note: all three removals go through `CADDrawing`'s value-snapshot undo
    ///   funnels (`removeLayer`/`removeBlock`/`mutateDimStyles`), so the whole purge
    ///   reverts as ONE ⌘Z inside the undo group below.
    @MainActor
    @discardableResult
    public static func apply(_ plan: PurgePlan, to drawing: CADDrawing) -> Int {
        guard !plan.isEmpty else { return 0 }
        drawing.undoManager?.beginUndoGrouping()
        defer { drawing.undoManager?.endUndoGrouping() }

        var removed = 0
        for name in plan.blocks where drawing.blocks.contains(name) {
            drawing.removeBlock(name)            // definition only (members unused)
            removed += 1
        }
        for name in plan.layers where name != "0" && drawing.layers.contains(name) {
            drawing.removeLayer(name)            // record only (no referencing entity)
            removed += 1
        }
        for name in plan.dimStyles where drawing.dimStyles.contains(name) {
            drawing.mutateDimStyles { $0.remove(named: name) }   // undoable, folds into the group
            removed += 1
        }
        return removed
    }
}
