//
//  BlockEvaluator.swift
//  CADEngine
//
//  The PURE instance-aware dynamic-block evaluator (dynamic-blocks-plan §3). Given
//  a block's dynamic DEFINITION (`DynamicBlockDef`), its ordered member records,
//  and one insert's per-INSTANCE state (`InsertDynamicState`), it returns the
//  EVALUATED member records — the geometry that insert should place.
//
//  This wave implements ONLY the visibility filter (§9): drop the members not in
//  the active visibility state. Later waves add the action-transform step (move /
//  stretch / rotate / flip — DB-2) ADDITIVELY here, ahead of returning.
//
//  ## Purity contract (dynamic-blocks-plan §3, critic Fix 3) — TESTED, not asserted
//  `evaluate` treats `members` as IMMUTABLE input and returns a FRESH array. It
//  holds NO shared mutable state, aliases nothing across calls, and mutates none
//  of its inputs. Per-instance isolation depends ENTIRELY on this purity: the
//  resolve context's `blockProvider` serves the SAME by-name member snapshot to
//  every insert (`CADDrawing.blockMembersSnapshot`), so the only thing carrying
//  instance identity is the `instanceState` argument. Two inserts of the same
//  dynamic block at two different states therefore evaluate to two correct,
//  independent results, and every MINSERT cell evaluates identically with the
//  source members untouched.
//
//  ## Why this is the SAME shape `blockProvider` returns
//  `evaluate` returns `[EntityRecord]` — exactly what `resolveInsert` already gets
//  from `ctx.blockProvider`. It is threaded in BEFORE the existing transform /
//  MINSERT / recursion / `.byBlock` / ATTRIB logic, which stays byte-for-byte
//  unchanged. A non-dynamic insert (no `def` / empty states) gets its members back
//  unchanged ⇒ zero behavior change for plain blocks.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// A pure namespace for evaluating a dynamic-block instance to its placed member
/// records (ADR-001: PURE — derived, never stored).
public enum BlockEvaluator {

    /// Evaluates one dynamic-block instance to the member records it should place.
    ///
    /// VISIBILITY (§9): if `def` declares visibility states, pick the ACTIVE state
    /// — `instanceState?.activeVisibilityState` matched by name, else the FIRST
    /// declared state as the default (§9.5) — and return ONLY the members whose id
    /// is in that state's `visibleMemberIDs`. If `def` is `nil`, carries no
    /// visibility states, or the resolved active state cannot be found, the members
    /// are returned UNCHANGED (a plain block resolves all its members exactly as
    /// before).
    ///
    /// - Parameters:
    ///   - def: the block's dynamic definition (`Block.dynamic`), or `nil` for a
    ///          plain block.
    ///   - members: the block's ordered member records (from `blockProvider`) —
    ///              treated as immutable; never mutated.
    ///   - instanceState: the insert's per-instance state (`InsertData.dynamic`).
    /// - Returns: a FRESH `[EntityRecord]` — the same shape `blockProvider`
    ///            returns, ready for the unchanged `resolveInsert` member loop.
    public static func evaluate(_ def: DynamicBlockDef?,
                                members: [EntityRecord],
                                instanceState: InsertDynamicState?) -> [EntityRecord] {
        // A plain block (no dynamic def, or a def with no visibility states):
        // every member is visible — return them unchanged.
        guard let def, !def.visibilityStates.isEmpty else { return members }

        // Resolve the ACTIVE visibility state: the instance's named state if it
        // exists, otherwise the block's default (the first declared state, §9.5).
        let active: BlockVisibilityState?
        if let name = instanceState?.activeVisibilityState,
           let named = def.visibilityState(named: name) {
            active = named
        } else {
            active = def.defaultVisibilityState
        }

        // No resolvable state (defensive — `visibilityStates` is non-empty here so
        // `defaultVisibilityState` is non-nil, but stay safe): return unchanged.
        guard let state = active else { return members }

        // Keep only members visible in the active state (filter preserves the
        // declared member order and produces a fresh array).
        return members.filter { state.visibleMemberIDs.contains($0.id) }
    }
}
