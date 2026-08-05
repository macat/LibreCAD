//
//  DirtySet.swift
//  CADEngine
//
//  Wave P5 — Renderer dirty-set (perf-arch-review-plan.md P5).
//  Tiny value-type helper for incremental Metal rebuild: tracks which
//  entities changed since the last GPU buffer build, and decides when
//  to fall back to a full rebuild (correctness first).
//
//  Pure, Sendable, no app dependency (CADEngine ⊥ LibreCADmacOS).

import Foundation

/// Tracks the set of entities that changed since the last render buffer
/// build. Produced from the `applyCommit` diff (add/replace/remove) or
/// derived from `resolveVersion` deltas; consumed by the renderer to
/// repack only `dirty ∩ visible` (plus inserts/removes).
public struct DirtySet: Sendable, Equatable, Hashable {

    /// The dirty ids. Empty means "unknown / needs fallback".
    public var ids: Set<EntityID>

    /// When the dirty set was captured (drawing `modelVersion`).
    public var generation: UInt64

    public init(ids: Set<EntityID> = [], generation: UInt64 = 0) {
        self.ids = ids
        self.generation = generation
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }

    public mutating func insert(_ id: EntityID) { ids.insert(id) }
    public mutating func remove(_ id: EntityID) { ids.remove(id) }
    public mutating func formUnion(_ other: Set<EntityID>) { ids.formUnion(other) }
    public mutating func clear() { ids.removeAll() }

    /// Whether the renderer should fall back to a full rebuild.
    ///
    /// Fallback when:
    /// - first frame (no prior build),
    /// - dirty is empty (unknown change, e.g. layer visibility toggle),
    /// - dirty is oversized (> `thresholdFraction` of visible, or absolute large).
    ///
    /// Correctness first: an oversized dirty set costs the same as a full
    /// rebuild, so we just do the full path.
    public func shouldFallback(visibleCount: Int, isFirstFrame: Bool) -> Bool {
        if isFirstFrame { return true }
        if ids.isEmpty { return true }
        if visibleCount == 0 { return false }
        // Oversized threshold: > 50% of visible, or > 256 dirty when >30% visible.
        let fraction = Double(ids.count) / Double(max(visibleCount, 1))
        if fraction > Self.fallbackThresholdFraction { return true }
        if ids.count > 256 && fraction > 0.3 { return true }
        return false
    }

    /// The dirty ids that are also visible (the only ones the renderer
    /// needs to re-resolve).
    public func visibleDirty(visibleIDs: Set<EntityID>) -> Set<EntityID> {
        ids.intersection(visibleIDs)
    }

    /// Fraction above which a dirty set is considered oversized and the
    /// renderer falls back to a full rebuild. Matches perf-arch-review
    /// P5: at smallest edits the upload should be ~half; a >50% dirty
    /// set is no win.
    public static let fallbackThresholdFraction: Double = 0.5

    // MARK: - Diff helpers (pure, testable)

    /// Computes a dirty set by comparing current drawing versions against
    /// a snapshot of last-built versions. Also accounts for removals
    /// (ids that were visible before but are no longer).
    ///
    /// This is the version-delta derivation of the `applyCommit` diff:
    /// `add` → new id not in `lastVersions`, `replace` → version bump,
    /// `remove` → id in `lastVisible` but not in `visibleIDs`.
    @MainActor
    public static func computeDirty(
        drawing: CADDrawing,
        visibleIDs: Set<EntityID>,
        lastVersions: [EntityID: UInt64],
        lastVisible: Set<EntityID>
    ) -> DirtySet {
        var dirty = Set<EntityID>()
        for id in visibleIDs {
            if let last = lastVersions[id] {
                if let cur = drawing.resolveVersion(for: id), cur != last {
                    dirty.insert(id)
                }
            } else {
                // New to the visible set (either newly added, or scrolled into view).
                dirty.insert(id)
            }
        }
        // Entities that left the visible set (removed or scrolled out) also
        // count as dirty for threshold purposes — their old geometry must be
        // removed from the buffer.
        let departed = lastVisible.subtracting(visibleIDs)
        dirty.formUnion(departed)
        return DirtySet(ids: dirty, generation: drawing.modelVersion)
    }

    /// Convenience for the applyCommit explicit diff path: union of
    /// added / replaced / removed ids.
    public static func fromDiff(
        added: [EntityID],
        replaced: [EntityID],
        removed: [EntityID],
        generation: UInt64
    ) -> DirtySet {
        var s = Set<EntityID>()
        s.formUnion(added)
        s.formUnion(replaced)
        s.formUnion(removed)
        return DirtySet(ids: s, generation: generation)
    }
}
