//
//  DynamicBlock.swift
//  CADEngine
//
//  The native dynamic-block model — the per-DEFINITION (`Block.dynamic`) and
//  per-INSTANCE (`InsertData.dynamic`) value bundles that drive instance-aware
//  block evaluation (see `BlockEvaluator.swift` + `Resolve.resolveInsert`).
//
//  This is the FIRST concrete dynamic-block feature: **visibility states**
//  (block-features.md §9). A dynamic block definition can hold several named
//  visibility states; each insert shows ONE state (e.g. a valve block with
//  Gate / Ball / Check variants — §9.6). Visibility is PURE member filtering:
//  the active state names a subset of the block's member entity ids, and
//  evaluation drops the members not in that subset before the existing
//  transform / MINSERT / recursion / `.byBlock` / ATTRIB resolve logic runs.
//
//  ## Why these are NEW types in a NEW file (no `EntityKind` case)
//  Dynamic state is authoring metadata on the `Block` definition + value state on
//  the `.insert` instance — it is NOT geometry, so it is modelled ADDITIVELY,
//  exactly mirroring how block attributes were added (`Block.attributeDefs`,
//  `InsertData.attributes`). There is ZERO new `EntityKind` case — the ~28
//  exhaustive enum switches are never touched (dynamic-blocks-plan §8).
//
//  ## Forward-compat (later waves are ADDITIVE on these structs)
//  `DynamicBlockDef` currently carries ONLY `visibilityStates`. Parameters,
//  actions, value sets and lookup tables (dynamic-blocks-plan §2a, waves DB-2..DB-5)
//  are added later as ADDITIVE optional/defaulted fields here — never a new file
//  on the hot enum, never a new `EntityKind`. `InsertDynamicState.parameterValues`
//  is defined now (defaulted empty) for that forward-compat but is UNUSED by
//  visibility — only `activeVisibilityState` matters this wave.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// One **named visibility state** of a dynamic block (block-features.md §9). A
/// state names the subset of the block's member entities that are VISIBLE when an
/// insert has this state active; every other member is dropped at resolve time.
///
/// - `id`               — a stable identity (survives renames); `Identifiable`.
/// - `name`             — the user-facing state label and the per-instance key
///                        (`InsertDynamicState.activeVisibilityState` matches by
///                        this name, §9.4 — the dropdown shows it, the insert
///                        stores it).
/// - `visibleMemberIDs` — the `EntityID`s of the block members shown in this
///                        state. A member id absent from this set is hidden when
///                        the state is active.
public struct BlockVisibilityState: Sendable, Hashable, Codable, Identifiable {
    /// Stable identity (survives a rename of `name`).
    public var id: UUID
    /// User-facing state label + the per-instance key (matched by name, §9.4).
    public var name: String
    /// The block-member entity ids visible while this state is active.
    public var visibleMemberIDs: Set<EntityID>

    public init(id: UUID = UUID(), name: String, visibleMemberIDs: Set<EntityID> = []) {
        self.id = id
        self.name = name
        self.visibleMemberIDs = visibleMemberIDs
    }
}

/// All dynamic-authoring state for a block DEFINITION — the optional bundle stored
/// on `Block.dynamic`. Optional so a plain (non-dynamic) block — and every old
/// saved file — carries `nil` and is byte-identical (dynamic-blocks-plan §2a).
///
/// This wave defines ONLY `visibilityStates`. Later waves grow this struct
/// ADDITIVELY (parameters / actions / value sets / lookup tables) — never as a new
/// file on the hot enum and never a new `EntityKind` case.
public struct DynamicBlockDef: Sendable, Hashable, Codable {
    /// The block's named visibility states, in declared order. EMPTY ⇒ the block
    /// has no visibility parameter (it resolves all members, unchanged behavior).
    /// The FIRST state (index 0) is the DEFAULT shown when an insert names no /
    /// an unknown active state (§9.5).
    public var visibilityStates: [BlockVisibilityState]

    public init(visibilityStates: [BlockVisibilityState] = []) {
        self.visibilityStates = visibilityStates
    }

    /// Whether this bundle carries no dynamic authoring at all (so a `nil`-vs-empty
    /// `Block.dynamic` is observably the same — a plain block).
    public var isEmpty: Bool { visibilityStates.isEmpty }

    /// The visibility state matched by `name`, or `nil` if absent.
    public func visibilityState(named name: String) -> BlockVisibilityState? {
        visibilityStates.first { $0.name == name }
    }

    /// The DEFAULT visibility state — the first declared one (§9.5), or `nil` if
    /// the block has no states.
    public var defaultVisibilityState: BlockVisibilityState? {
        visibilityStates.first
    }
}

/// Per-INSTANCE dynamic state — the optional bundle stored on `InsertData.dynamic`.
/// Optional so a plain insert — and every old saved file — carries `nil` and is
/// byte-identical (dynamic-blocks-plan §2b).
///
/// - `activeVisibilityState` — the active state NAME, or `nil` ⇒ the block's
///                             default (state 0, §9.5). The ONLY field that drives
///                             this wave.
/// - `parameterValues`       — parameter values keyed by a parameter id string
///                             (forward-compat for waves DB-2..DB-5, §2b). Defined
///                             now so the additive `InsertData.dynamic` hot-field
///                             edit never has to change shape later; UNUSED by
///                             visibility.
public struct InsertDynamicState: Sendable, Hashable, Codable {
    /// The active visibility state NAME, or `nil` ⇒ the block's default (§9.5).
    public var activeVisibilityState: String?
    /// Parameter values keyed by a parameter id string. Forward-compat (DB-2..DB-5);
    /// UNUSED by visibility this wave.
    public var parameterValues: [String: Double]

    public init(activeVisibilityState: String? = nil,
                parameterValues: [String: Double] = [:]) {
        self.activeVisibilityState = activeVisibilityState
        self.parameterValues = parameterValues
    }
}
