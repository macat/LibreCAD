//
//  Block.swift
//  CADEngine
//
//  The block table — the document's named block-definition registry. Mirrors
//  LibreCAD's RS_Block + RS_BlockList (librecad/src/lib/engine/document/blocks/),
//  but per ADR-001 a block's contents are **id references** into the drawing's
//  entity store, NOT a nested child object graph. A `Block` carries only its name,
//  base point, and the ordered `EntityID`s of its member entities; the entities
//  themselves live in `CADDrawing.entities` exactly like top-level geometry.
//
//  This file provides STORAGE + table operations only. Insert *resolve* (expanding
//  an `Insert` entity into placed copies of a block's contents, applying the
//  insert's transform, and threading `.byBlock` pens) is the Blocks-resolve owner's
//  job in a later phase — not here (see phase1-fanout.md "Single-owner").
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Block / RS_BlockList).
//

import Foundation

/// A block reference. DXF blocks are addressed by **name** (the name acts as the
/// id — `RS_BlockData::name` is "an Id for this block"), so we key by name and
/// wrap it for explicitness and future-proofing, mirroring `LayerID`.
public struct BlockID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { "BlockID(\(name))" }
}

/// One **block attribute definition** (ATTDEF template) declared by a block (DXF
/// `ATTDEF`, libdxfrw `DRW_Attdef`, derives `DRW_Attrib`/`DRW_Text`). A block's
/// `attributeDefs` are the TEMPLATES — tag + prompt + default value + placement —
/// that each `INSERT` overrides per-instance with one `BlockAttributeValue`
/// (`ATTRIB`) per tag. Mirrors the defining fields LibreCAD stores on an
/// `RS_Insert`'s attribute children.
///
/// ## Field grounding (DXF `ATTDEF` / libdxfrw `DRW_Attdef`)
/// - `tag`         — code 2: the tag (field name; matches an `ATTRIB`'s tag).
/// - `prompt`      — code 3: the prompt shown when the user is asked for a value.
/// - `defaultText` — code 1: the default value if the insert supplies none.
/// - `position`    — code 10: the template text insertion point (block local frame).
/// - `height`      — code 40: the template text cap height (world units).
/// - `rotation`    — code 50: baseline rotation in **radians** (CCW).
/// - `flags`       — code 70: attribute flags (1 invisible, 2 constant, 4 verify,
///                   8 preset). Carried for round-trip.
public struct BlockAttributeDef: Sendable, Hashable, Codable {
    /// DXF code 2 — the attribute tag (field name).
    public var tag: String
    /// DXF code 3 — the prompt string.
    public var prompt: String
    /// DXF code 1 — the default attribute value.
    public var defaultText: String
    /// DXF code 10 — template text insertion point (block local frame).
    public var position: Vector
    /// DXF code 40 — template text cap height (world units).
    public var height: Double
    /// DXF code 50 — baseline rotation in radians (CCW).
    public var rotation: Double
    /// DXF code 70 — attribute flags (1 invisible, 2 constant, 4 verify, 8 preset).
    public var flags: Int

    public init(
        tag: String,
        prompt: String = "",
        defaultText: String = "",
        position: Vector = Vector(0, 0),
        height: Double = 2.5,
        rotation: Double = 0,
        flags: Int = 0
    ) {
        self.tag = tag
        self.prompt = prompt
        self.defaultText = defaultText
        self.position = position
        self.height = height
        self.rotation = rotation
        self.flags = flags
    }
}

/// A block definition — the value-type port of `RS_Block` / `RS_BlockData`.
///
/// Field map:
/// - `name`        → `RS_BlockData::name` (unique; acts as the id)
/// - `basePoint`   → `RS_BlockData::basePoint` (the block's local origin; usually
///                   (0,0) since placement is via the Insert's insertion point)
/// - `entityIDs`   → the ordered ids of the block's member entities. Per ADR-001
///                   these reference records in `CADDrawing.entities`; the block
///                   owns no nested objects, no back-pointers, no child lists.
/// - `isFrozen`    → `RS_BlockData::frozen` (a frozen block is not drawn)
/// - `attributeDefs` → the block's ATTDEF templates (DXF `ATTDEF`); each `INSERT`
///                   of this block supplies a `BlockAttributeValue` per tag.
public struct Block: Sendable, Hashable, Codable, Identifiable {
    public var id: BlockID { BlockID(name) }
    public var name: String
    public var basePoint: Vector
    /// Ordered ids of the block's member entities (id-refs into the drawing).
    public var entityIDs: [EntityID]
    /// `RS_BlockData::frozen` — a frozen block is invisible / not drawn.
    public var isFrozen: Bool
    /// The block's ATTDEF attribute templates (DXF `ATTDEF`). ADDITIVE field: a
    /// block born without it — and every old saved file — decodes to `[]`, so
    /// existing blocks are 100% unaffected.
    public var attributeDefs: [BlockAttributeDef]
    /// The block's DYNAMIC authoring bundle (visibility states, parameters, actions —
    /// see `DynamicBlockDef`). ADDITIVE optional field: a plain (non-dynamic) block —
    /// and every old saved file — carries `nil`, so a block born without it is
    /// byte-identical (dynamic-blocks-plan §2a).
    ///
    /// PERSISTENCE (R4b, dynamic-blocks-plan §6a): the document is DXF-only, so this
    /// bundle is round-tripped LOSSLESSLY by embedding it in the DXF as a compact
    /// INDEX-KEYED JSON string carried on a reserved-tag ATTDEF inside the block
    /// (`DynamicBlockDef.encodeIndexKeyedJSON` / `decodeIndexKeyedJSON`, wired through
    /// `DXFWriter`/`DXFReader` + the C bridge). Member references are persisted as
    /// member INDICES (not `EntityID`s, which the reader re-mints on every read). DXF
    /// only — dynamic-on-DWG does not round-trip (the DWG writer makes empty blocks).
    public var dynamic: DynamicBlockDef?

    public init(
        name: String,
        basePoint: Vector = Vector(0, 0),
        entityIDs: [EntityID] = [],
        isFrozen: Bool = false,
        attributeDefs: [BlockAttributeDef] = [],
        dynamic: DynamicBlockDef? = nil
    ) {
        self.name = name
        self.basePoint = basePoint
        self.entityIDs = entityIDs
        self.isFrozen = isFrozen
        self.attributeDefs = attributeDefs
        self.dynamic = dynamic
    }

    /// Visibility — the inverse of `isFrozen` (`RS_Block::toggle` flips frozen).
    public var isVisible: Bool {
        get { !isFrozen }
        set { isFrozen = !newValue }
    }

    /// Whether this block carries any dynamic authoring (a non-empty bundle). A
    /// `nil`-vs-empty `dynamic` reads the same — both are a plain block.
    public var isDynamic: Bool { dynamic?.isEmpty == false }
}

// MARK: - Decodable (back-compat: tolerate missing newer fields)

extension Block {
    private enum CodingKeys: String, CodingKey {
        case name, basePoint, entityIDs, isFrozen
        case attributeDefs
        case dynamic
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        basePoint = try c.decodeIfPresent(Vector.self, forKey: .basePoint) ?? Vector(0, 0)
        entityIDs = try c.decodeIfPresent([EntityID].self, forKey: .entityIDs) ?? []
        isFrozen = try c.decodeIfPresent(Bool.self, forKey: .isFrozen) ?? false
        // ADDITIVE: old files (no `attributeDefs` key) decode to an empty list.
        attributeDefs = try c.decodeIfPresent([BlockAttributeDef].self, forKey: .attributeDefs) ?? []
        // ADDITIVE: old files (no `dynamic` key) decode to nil — a plain block.
        dynamic = try c.decodeIfPresent(DynamicBlockDef.self, forKey: .dynamic)
    }
}

/// The ordered, name-keyed block registry — the value-type port of `RS_BlockList`.
///
/// Differences from the C++ original:
/// - Value `struct`, not a pointer-owning list (no `m_owner`/`delete`); copying
///   is a full snapshot for undo / document load.
/// - Active block tracked by name, not raw pointer; `nil` == no active block.
/// - LibreCAD's `RS_BlockListListener` fan-out is replaced by SwiftUI observation
///   of the owning `CADDrawing`.
///
/// ## Removal policy (matches `RS_BlockList::remove`)
/// `remove` drops the block *definition* (the table record) only. The member
/// entities still live in `CADDrawing.entities`; this table doesn't delete them
/// (LibreCAD's separate command path handles entity cleanup). `CADDrawing` exposes
/// `removeBlock(_:deletingContents:)` for callers that also want the member
/// entities removed from the drawing. The active block, if removed, is cleared.
public struct BlockTable: Sendable, Hashable, Codable {
    /// Blocks in creation order.
    public private(set) var blocks: [Block]
    /// The currently active block's name, or `nil` if none (`getActive`).
    public private(set) var activeBlockName: String?

    /// An empty block table.
    public init() {
        self.blocks = []
        self.activeBlockName = nil
    }

    public init(blocks: [Block], activeBlockName: String? = nil) {
        self.blocks = blocks
        self.activeBlockName = activeBlockName.flatMap { name in
            blocks.contains { $0.name == name } ? name : nil
        }
    }

    // MARK: - Reads

    /// Number of block definitions (`RS_BlockList::count`).
    public var count: Int { blocks.count }
    public var isEmpty: Bool { blocks.isEmpty }

    /// Looks up a block by id/name (`RS_BlockList::find`).
    public func block(_ id: BlockID) -> Block? {
        blocks.first { $0.name == id.name }
    }

    /// Looks up a block by name.
    public func block(named name: String) -> Block? {
        blocks.first { $0.name == name }
    }

    /// Case-insensitive lookup (`RS_BlockList::findCaseInsensitive`).
    public func block(namedCaseInsensitive name: String) -> Block? {
        blocks.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether a block with this name exists.
    public func contains(_ name: String) -> Bool {
        blocks.contains { $0.name == name }
    }

    /// The position of a block in the ordered list.
    public func index(of name: String) -> Int? {
        blocks.firstIndex { $0.name == name }
    }

    /// The active block, or `nil` (`RS_BlockList::getActive`).
    public var activeBlock: Block? {
        activeBlockName.flatMap { block(named: $0) }
    }

    /// The member-entity ids of a block, or `[]` if the block is unknown.
    public func entityIDs(of name: String) -> [EntityID] {
        block(named: name)?.entityIDs ?? []
    }

    // MARK: - Active block (RS_BlockList::activate / getActive)

    /// Activates a block by name; `nil` clears the active block. Activating an
    /// unknown name clears (matches LibreCAD's `find`-then-activate path).
    public mutating func activate(_ name: String?) {
        guard let name else { activeBlockName = nil; return }
        activeBlockName = contains(name) ? name : nil
    }

    /// Generates a fresh unused name from `suggestion` (`RS_BlockList::newName`).
    /// Returns `suggestion` if free, else appends `-1`, `-2`, ... until unique.
    public func newName(suggestion: String = "noname") -> String {
        let base = suggestion.isEmpty ? "noname" : suggestion
        if !contains(base) { return base }
        var i = 1
        while contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    // MARK: - Add / edit (RS_BlockList::add / rename)

    /// Adds a block only if its name is free (`RS_BlockList::add` returns false on
    /// a duplicate name). Returns `true` if added.
    @discardableResult
    public mutating func add(_ block: Block) -> Bool {
        guard !contains(block.name) else { return false }
        blocks.append(block)
        return true
    }

    /// Adds, or replaces the existing same-named block.
    public mutating func upsert(_ block: Block) {
        if let idx = index(of: block.name) {
            blocks[idx] = block
        } else {
            blocks.append(block)
        }
    }

    /// Renames a block (`RS_BlockList::rename`). Rejects an empty new name or a
    /// collision with a different existing block. Returns `true` on success.
    @discardableResult
    public mutating func rename(_ oldName: String, to newName: String) -> Bool {
        guard !newName.isEmpty else { return false }
        guard oldName != newName else { return true }
        guard let idx = index(of: oldName), !contains(newName) else { return false }
        blocks[idx].name = newName
        if activeBlockName == oldName { activeBlockName = newName }
        return true
    }

    /// Sets a block's base point. No-op if unknown.
    public mutating func setBasePoint(_ name: String, _ basePoint: Vector) {
        guard let idx = index(of: name) else { return }
        blocks[idx].basePoint = basePoint
    }

    /// Sets a block's frozen flag. No-op if unknown.
    public mutating func setFrozen(_ name: String, _ frozen: Bool) {
        guard let idx = index(of: name) else { return }
        blocks[idx].isFrozen = frozen
    }

    /// Replaces a block's member-entity id list. No-op if unknown.
    public mutating func setEntityIDs(_ name: String, _ ids: [EntityID]) {
        guard let idx = index(of: name) else { return }
        blocks[idx].entityIDs = ids
    }

    /// Appends a member-entity id to a block (avoids duplicates). No-op if unknown.
    public mutating func addEntityID(_ id: EntityID, to name: String) {
        guard let idx = index(of: name) else { return }
        if !blocks[idx].entityIDs.contains(id) {
            blocks[idx].entityIDs.append(id)
        }
    }

    /// Removes a member-entity id from a block (e.g. when the entity is deleted).
    /// No-op if the block or id is absent.
    public mutating func removeEntityID(_ id: EntityID, from name: String) {
        guard let idx = index(of: name) else { return }
        blocks[idx].entityIDs.removeAll { $0 == id }
    }

    /// Removes an id from *every* block's member list (used when an entity is
    /// deleted from the drawing and may be referenced by one or more blocks).
    public mutating func removeEntityIDEverywhere(_ id: EntityID) {
        for i in blocks.indices {
            blocks[i].entityIDs.removeAll { $0 == id }
        }
    }

    // MARK: - Remove (RS_BlockList::remove)

    /// Removes a block *definition* by id. Member entities are NOT touched here
    /// (see the type's removal-policy note). The active block, if removed, clears.
    public mutating func remove(_ id: BlockID) {
        blocks.removeAll { $0.name == id.name }
        if activeBlockName == id.name { activeBlockName = nil }
    }

    /// Removes a block definition by name.
    public mutating func remove(named name: String) { remove(BlockID(name)) }

    /// Clears all blocks (`RS_BlockList::clear`).
    public mutating func clear() {
        blocks.removeAll()
        activeBlockName = nil
    }
}
