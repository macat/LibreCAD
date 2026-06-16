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

// MARK: - Parameters (DB-2: the value drivers an action reads)

/// A stable, string-keyed identity for a block PARAMETER (dynamic-blocks-plan §2a,
/// DECIDED note). It wraps a raw `String` so the typed API stays explicit while the
/// on-the-wire instance state (`InsertDynamicState.parameterValues`/`flipStates`)
/// uses plain `String` keys — exactly that raw value. A parameter id keys into those
/// dictionaries the way a layer name keys the layer table.
public struct BlockParameterID: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The raw key used in `InsertDynamicState.parameterValues`/`flipStates`.
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { "BlockParameterID(\(raw))" }
}

/// One **block parameter** — the value driver an action reads (block-features.md
/// §5.2). DB-2 ships the two parameters the two DB-2 actions consume:
///
/// - **`.linear`** (§5.2.2): a distance + direction defined by a `base`→`end`
///   segment. Its BASE (default) distance is `|end - base|` and its direction is
///   the unit vector of `(end - base)`. The instance value lives in
///   `InsertDynamicState.parameterValues[id.raw]` as the CURRENT distance (default =
///   the base distance). It drives a STRETCH action.
/// - **`.flip`** (§5.2.7): a reflection line `lineStart`→`lineEnd`. The instance
///   value lives in `InsertDynamicState.flipStates[id.raw]` as a `Bool` (default
///   `false` = not flipped). It drives a FLIP action.
///
/// Modelled as an enum with the per-kind defining points inline (NOT an `EntityKind`
/// case — its own enum, switched only inside the dynamic-block files, zero fan-out).
public enum BlockParameter: Sendable, Hashable, Codable, Identifiable {
    /// A linear (distance + direction) parameter (§5.2.2): `base`→`end` defines the
    /// default distance `|end - base|` and the stretch direction.
    case linear(id: BlockParameterID, label: String, base: Vector, end: Vector)
    /// A flip (reflection) parameter (§5.2.7): `lineStart`→`lineEnd` is the mirror
    /// line a flip action reflects its members across.
    case flip(id: BlockParameterID, label: String, lineStart: Vector, lineEnd: Vector)

    /// The parameter's stable id (its key into the per-instance value dictionaries).
    public var id: BlockParameterID {
        switch self {
        case .linear(let id, _, _, _): return id
        case .flip(let id, _, _, _):   return id
        }
    }

    /// The user-facing label (Properties-palette name, §5.3).
    public var label: String {
        switch self {
        case .linear(_, let label, _, _): return label
        case .flip(_, let label, _, _):   return label
        }
    }

    /// For a `.linear` parameter, the BASE (default) distance `|end - base|`; `nil`
    /// for other kinds. The instance value defaults to this when unset. NaN-safe
    /// (a non-finite segment collapses to `0`).
    public var baseDistance: Double? {
        switch self {
        case .linear(_, _, let base, let end):
            let d = (end - base).magnitude
            return d.isFinite ? d : 0
        case .flip:
            return nil
        }
    }

    /// For a `.linear` parameter, the UNIT direction `(end - base)`; `nil` for other
    /// kinds or a degenerate (zero-length / non-finite) segment.
    public var unitDirection: Vector? {
        switch self {
        case .linear(_, _, let base, let end):
            let v = end - base
            let d = v.magnitude
            guard d.isFinite, d > Tolerance.distance else { return nil }
            return Vector(v.x / d, v.y / d)
        case .flip:
            return nil
        }
    }
}

// MARK: - Actions (DB-2: the geometry transform a parameter value applies)

/// A stable, string-keyed identity for a block ACTION.
public struct BlockActionID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { "BlockActionID(\(raw))" }
}

/// One **block action** — a geometry transform applied to a member subset, driven by
/// an associated parameter's instance value (block-features.md §6). DB-2 ships:
///
/// - **`.stretch`** (§6.2.3): driven by a `.linear` parameter. The signed delta
///   ALONG the parameter direction (current distance − base distance), times
///   `distanceMultiplier` (§13.4) and rotated by `angleOffset` (§13.4), translates
///   the member DEFINING POINTS that fall INSIDE `stretchFrame`; points outside stay.
/// - **`.flip`** (§6.2.6): driven by a `.flip` parameter. When the flip state is
///   `true`, the action's members are MIRRORED about the flip parameter's line.
///
/// `memberIDs` is the action's SELECTION SET — the block-member entity ids it
/// transforms (§6.1, §13.3). Modelled as an enum (own type, zero `EntityKind`
/// fan-out).
public enum BlockAction: Sendable, Hashable, Codable, Identifiable {
    /// A STRETCH action (§6.2.3): members' defining points inside `stretchFrame`
    /// move by the linear parameter's signed delta (scaled by `distanceMultiplier`,
    /// rotated by `angleOffset`); points outside stay put.
    case stretch(id: BlockActionID, parameterID: BlockParameterID,
                 stretchFrame: AABB, memberIDs: Set<EntityID>,
                 distanceMultiplier: Double = 1, angleOffset: Double = 0)
    /// A FLIP action (§6.2.6): mirror the members about the flip parameter's line
    /// when the instance flip state is `true`.
    case flip(id: BlockActionID, parameterID: BlockParameterID, memberIDs: Set<EntityID>)

    /// The action's stable id.
    public var id: BlockActionID {
        switch self {
        case .stretch(let id, _, _, _, _, _): return id
        case .flip(let id, _, _):             return id
        }
    }

    /// The id of the parameter that drives this action (§6.1).
    public var parameterID: BlockParameterID {
        switch self {
        case .stretch(_, let pid, _, _, _, _): return pid
        case .flip(_, let pid, _):             return pid
        }
    }

    /// The action's selection set — the member entity ids it transforms (§6.1).
    public var memberIDs: Set<EntityID> {
        switch self {
        case .stretch(_, _, _, let m, _, _): return m
        case .flip(_, _, let m):             return m
        }
    }
}

/// All dynamic-authoring state for a block DEFINITION — the optional bundle stored
/// on `Block.dynamic`. Optional so a plain (non-dynamic) block — and every old
/// saved file — carries `nil` and is byte-identical (dynamic-blocks-plan §2a).
///
/// DB-1 defined `visibilityStates`; DB-2 grows this struct ADDITIVELY with
/// `parameters` + `actions` (defaulted empty → a DB-1 file decodes them as `[]`).
/// Still no new file on the hot enum and no new `EntityKind` case.
public struct DynamicBlockDef: Sendable, Hashable, Codable {
    /// The block's named visibility states, in declared order. EMPTY ⇒ the block
    /// has no visibility parameter (it resolves all members, unchanged behavior).
    /// The FIRST state (index 0) is the DEFAULT shown when an insert names no /
    /// an unknown active state (§9.5).
    public var visibilityStates: [BlockVisibilityState]
    /// The block's parameters (the value drivers actions read), in declared order.
    /// EMPTY ⇒ no parameters (a DB-1 / static block). ADDITIVE (DB-2): a DB-1 file
    /// (no `parameters` key) decodes this as `[]`.
    public var parameters: [BlockParameter]
    /// The block's actions (geometry transforms driven by parameter values), in
    /// declared order. Applied AFTER the visibility filter, in this order. EMPTY ⇒
    /// no actions (a DB-1 / static block). ADDITIVE (DB-2): a DB-1 file (no
    /// `actions` key) decodes this as `[]`.
    public var actions: [BlockAction]

    public init(visibilityStates: [BlockVisibilityState] = [],
                parameters: [BlockParameter] = [],
                actions: [BlockAction] = []) {
        self.visibilityStates = visibilityStates
        self.parameters = parameters
        self.actions = actions
    }

    /// Whether this bundle carries no dynamic authoring at all (so a `nil`-vs-empty
    /// `Block.dynamic` is observably the same — a plain block).
    public var isEmpty: Bool {
        visibilityStates.isEmpty && parameters.isEmpty && actions.isEmpty
    }

    /// The visibility state matched by `name`, or `nil` if absent.
    public func visibilityState(named name: String) -> BlockVisibilityState? {
        visibilityStates.first { $0.name == name }
    }

    /// The DEFAULT visibility state — the first declared one (§9.5), or `nil` if
    /// the block has no states.
    public var defaultVisibilityState: BlockVisibilityState? {
        visibilityStates.first
    }

    /// The parameter with the given id, or `nil` if absent.
    public func parameter(_ id: BlockParameterID) -> BlockParameter? {
        parameters.first { $0.id == id }
    }
}

// MARK: - Codable back-compat (DB-1 files have no `parameters`/`actions` keys)
//
// DB-1 saved a `DynamicBlockDef` with ONLY the `visibilityStates` key. The DB-2
// `parameters`/`actions` fields are ADDITIVE: a hand-written `init(from:)` using
// `decodeIfPresent` (the same pattern HatchData/InsertData use) decodes those absent
// keys as `[]`, so every DB-1 / static-block file loads unchanged. `encode(to:)`,
// `Hashable`/`Equatable` stay synthesized (the CodingKeys cover every field).

extension DynamicBlockDef {
    private enum CodingKeys: String, CodingKey {
        case visibilityStates, parameters, actions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visibilityStates = try c.decodeIfPresent([BlockVisibilityState].self,
                                                 forKey: .visibilityStates) ?? []
        // ADDITIVE: DB-1 files (no `parameters`/`actions` keys) decode to empty.
        parameters = try c.decodeIfPresent([BlockParameter].self, forKey: .parameters) ?? []
        actions = try c.decodeIfPresent([BlockAction].self, forKey: .actions) ?? []
    }
}

/// Per-INSTANCE dynamic state — the optional bundle stored on `InsertData.dynamic`.
/// Optional so a plain insert — and every old saved file — carries `nil` and is
/// byte-identical (dynamic-blocks-plan §2b).
///
/// - `activeVisibilityState` — the active state NAME, or `nil` ⇒ the block's
///                             default (state 0, §9.5). The ONLY field that drives
///                             this wave.
/// - `parameterValues`       — LINEAR parameter values keyed by a parameter id
///                             string (`BlockParameterID.raw`). For a `.linear`
///                             parameter the value is the CURRENT distance; absent ⇒
///                             the parameter's base distance (no stretch). DB-2 reads
///                             this to drive STRETCH actions.
/// - `flipStates`            — FLIP parameter states keyed by `BlockParameterID.raw`:
///                             `true` = flipped, absent/`false` = not flipped. DB-2
///                             reads this to drive FLIP actions. ADDITIVE (DB-2): a
///                             pre-DB-2 file (no `flipStates` key) decodes to `[:]`.
public struct InsertDynamicState: Sendable, Hashable, Codable {
    /// The active visibility state NAME, or `nil` ⇒ the block's default (§9.5).
    public var activeVisibilityState: String?
    /// LINEAR parameter values keyed by `BlockParameterID.raw` — the current distance
    /// per linear parameter. Absent ⇒ the parameter's base distance (no stretch).
    public var parameterValues: [String: Double]
    /// FLIP parameter states keyed by `BlockParameterID.raw` — `true` = flipped.
    /// Absent/`false` ⇒ not flipped. ADDITIVE (DB-2); a pre-DB-2 file decodes to `[:]`.
    public var flipStates: [String: Bool]

    public init(activeVisibilityState: String? = nil,
                parameterValues: [String: Double] = [:],
                flipStates: [String: Bool] = [:]) {
        self.activeVisibilityState = activeVisibilityState
        self.parameterValues = parameterValues
        self.flipStates = flipStates
    }
}

// MARK: - Codable back-compat (pre-DB-2 instance state has no `flipStates` key)
//
// A pre-DB-2 `InsertDynamicState` saved only `activeVisibilityState` (+ a possibly
// empty `parameterValues`). The DB-2 `flipStates` field is ADDITIVE: a hand-written
// `init(from:)` with `decodeIfPresent` decodes the absent key as `[:]`, so every
// pre-DB-2 file loads unchanged (mirrors InsertData's additive decode).

extension InsertDynamicState {
    private enum CodingKeys: String, CodingKey {
        case activeVisibilityState, parameterValues, flipStates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeVisibilityState = try c.decodeIfPresent(String.self, forKey: .activeVisibilityState)
        parameterValues = try c.decodeIfPresent([String: Double].self, forKey: .parameterValues) ?? [:]
        // ADDITIVE: pre-DB-2 files (no `flipStates` key) decode to empty.
        flipStates = try c.decodeIfPresent([String: Bool].self, forKey: .flipStates) ?? [:]
    }
}
