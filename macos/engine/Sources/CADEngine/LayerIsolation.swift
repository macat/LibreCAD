//
//  LayerIsolation.swift
//  CADEngine
//
//  Layer ISOLATE / UNISOLATE — the pure value-type semantics behind the daily
//  "isolate the selection's layer(s), hide everything else, then restore" op
//  (AutoCAD LAYISO / LAYUNISO; LibreCAD has no first-class equivalent yet).
//
//  This file is deliberately PURE: it computes — but never mutates — the
//  visibility/freeze changes that isolate a set of "keep" layers, plus a restore
//  snapshot that undoes exactly that. It leverages the existing freeze/visibility
//  primitives (`LayerTable.setFrozen`, `Layer.isFrozen`/`isVisible`) and the
//  `LayerState` flag-snapshot type rather than inventing a parallel model.
//
//  The wire-wave (layer panel / menu command) applies the result through the
//  drawing's existing undoable funnels:
//
//      let result = LayerIsolation.isolate(keep: keepNames, in: drawing.layers)
//      drawing.mutateLayers { result.isolated.apply(to: &$0) }   // one undo step
//      // …stash `result.restore` so the inverse command can:
//      drawing.mutateLayers { result.restore.apply(to: &$0) }    // exact unisolate
//
//  Because `isolate(...)` is a pure function of the table, it is trivially
//  unit-tested with no GPU, no app module, and no live view.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

/// Pure isolate/unisolate semantics over a `LayerTable`. A namespace of static
/// functions — there is no instance state; everything is a function of the table
/// plus the caller's "keep" set.
public enum LayerIsolation {

    /// The result of computing an isolate operation.
    ///
    /// - `isolated` is the plan the caller applies (inside one `mutateLayers`
    ///   group) to enter the isolated view: every layer NOT in the keep-set is
    ///   frozen (hidden); the kept layers are forced visible so an
    ///   accidentally-frozen kept layer is revealed.
    /// - `restore` is a `LayerState` capturing the table's flags BEFORE the
    ///   isolate, so applying it later restores the table to *exactly* its prior
    ///   state (a frozen-before / locked / printable / construction layer returns
    ///   to that flag). `isolate → restore` is an identity round-trip.
    public struct Result: Sendable, Hashable {
        /// The freeze/visibility changes that enter the isolated view.
        public var isolated: IsolationPlan
        /// The snapshot that exactly undoes the isolate (apply via `LayerState`).
        public var restore: LayerState

        public init(isolated: IsolationPlan, restore: LayerState) {
            self.isolated = isolated
            self.restore = restore
        }

        /// `true` when entering the isolated view would change nothing — i.e. the
        /// kept layers are already the only visible layers and none needs thawing.
        /// The wire-wave can use this to skip polluting the undo stack.
        public var isNoOp: Bool { isolated.isEmpty }
    }

    /// The forward (isolate) plan: which layers to freeze, and which to force
    /// visible. Kept as an explicit, applied-by-name value so the caller can run
    /// it inside the existing undoable `mutateLayers` funnel.
    public struct IsolationPlan: Sendable, Hashable {
        /// Layers to FREEZE (hide) — every existing layer not in the keep-set.
        public var freeze: Set<String>
        /// Kept layers to force VISIBLE (thaw) — those that were frozen before.
        public var thaw: Set<String>

        public init(freeze: Set<String> = [], thaw: Set<String> = []) {
            self.freeze = freeze
            self.thaw = thaw
        }

        /// `true` when the plan changes no layer's frozen flag.
        public var isEmpty: Bool { freeze.isEmpty && thaw.isEmpty }

        /// Applies the plan to a live table: freeze the hidden layers, thaw the
        /// kept-but-frozen ones. Each name is looked up by the table's existing
        /// `setFrozen` (a no-op for an unknown name), so this is safe even if the
        /// table changed between planning and applying.
        public func apply(to table: inout LayerTable) {
            for name in freeze { table.setFrozen(name, true) }
            for name in thaw { table.setFrozen(name, false) }
        }
    }

    // MARK: - Compute

    /// Computes the isolate operation for `keep` over `table`.
    ///
    /// Semantics:
    /// - Every existing layer whose name is NOT in `keep` is frozen (hidden).
    /// - Every kept layer that is currently frozen is thawed (so isolating a
    ///   hidden layer reveals it — matching AutoCAD LAYISO, which makes the
    ///   chosen layers the visible set).
    /// - Names in `keep` that don't exist in the table are ignored.
    /// - The `restore` snapshot captures the table's CURRENT flags, so applying
    ///   it later returns every layer to exactly its prior state.
    ///
    /// An empty `keep` set is safe: it freezes everything (a valid, if extreme,
    /// "hide all" — the caller decides whether to offer it), and `restore` still
    /// round-trips. A keep-set that is already the only-visible set yields an
    /// empty plan (`Result.isNoOp == true`).
    public static func isolate(keep: Set<String>, in table: LayerTable) -> Result {
        var freeze: Set<String> = []
        var thaw: Set<String> = []
        for layer in table.layers {
            if keep.contains(layer.name) {
                // Kept: reveal it if it was hidden.
                if layer.isFrozen { thaw.insert(layer.name) }
            } else {
                // Not kept: hide it if it isn't already.
                if !layer.isFrozen { freeze.insert(layer.name) }
            }
        }
        let plan = IsolationPlan(freeze: freeze, thaw: thaw)
        // The restore snapshot captures EVERY layer's prior flags by name; its
        // `apply` only touches layers it knows about, so it precisely reverts the
        // frozen flips above (and is harmless for layers the plan didn't change).
        let restore = LayerState(name: Self.restoreStateName, capturing: table)
        return Result(isolated: plan, restore: restore)
    }

    /// Convenience overload for an array/sequence of keep names.
    public static func isolate<S: Sequence>(keep: S, in table: LayerTable) -> Result
    where S.Element == String {
        isolate(keep: Set(keep), in: table)
    }

    // MARK: - Restore snapshot name

    /// The reserved name used for the restore `LayerState`. It is an internal
    /// carrier (the snapshot is held transiently by the isolate command, not
    /// added to the document's named `LayerStateTable`), so the exact string only
    /// matters for identity/equality of the value.
    public static let restoreStateName = "__isolate_restore__"
}
