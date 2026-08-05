//
//  Quadtree.swift
//  CADEngine
//
//  A loose quadtree that indexes `EntityID -> AABB` in f64 world coordinates
//  (ADR-003). It is the single spatial index shared by the renderer's viewport
//  culling and the CPU snapping / hit-testing path (see
//  macos/docs/rendering-performance.md §2.2 and §5): the renderer queries a
//  rectangle each time the view changes, the snapper queries a small box around
//  the cursor. Both want the same property — query cost that scales with the
//  number of results, not with the total entity count.
//
//  This file is owned by workstream D (spatial index). It uses only the frozen
//  foundation types `Vector`, `AABB`, and `EntityID` from Vector.swift /
//  Geometry.swift; it does not depend on the entity or document model, so it can
//  be unit-tested in isolation.
//
//  GPLv2-or-later (LibreCAD macOS port). The algorithm here is an original Swift
//  implementation, not a line-by-line port of LibreCAD (which has no equivalent
//  spatial index), but it inherits the project license.
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

// MARK: - 2D axis-aligned overlap helpers (x/y only)
//
// `AABB` (Geometry.swift) is owned by another workstream and intentionally has no
// box-vs-box overlap predicate, so the quadtree carries its own. All spatial
// reasoning here is 2D: the engine is a 2D CAD editor and the z extent of an
// entity's box is irrelevant to culling / hit-testing. Keeping these `private`
// avoids leaking quadtree-internal predicates into the shared `AABB` API.

private extension AABB {
    /// Whether two boxes overlap in x and y (touching edges count as overlap, so
    /// this matches the inclusive `contains(_:)` convention in Geometry.swift).
    /// An empty box never overlaps anything.
    @inline(__always)
    func overlaps2D(_ other: AABB) -> Bool {
        if isEmpty || other.isEmpty { return false }
        return min.x <= other.max.x && max.x >= other.min.x
            && min.y <= other.max.y && max.y >= other.min.y
    }

    /// Whether `self` fully contains `other` in x/y (used to decide how deep an
    /// entity's box can sink into the tree). Inclusive on the boundary.
    @inline(__always)
    func contains2D(_ other: AABB) -> Bool {
        if isEmpty || other.isEmpty { return false }
        return other.min.x >= min.x && other.max.x <= max.x
            && other.min.y >= min.y && other.max.y <= max.y
    }
}

// MARK: - Quadtree

/// A **loose** quadtree indexing `EntityID -> AABB` for viewport culling and
/// hit-test candidate gathering.
///
/// ## Why "loose"
/// A *standard* quadtree only stores an item in a node whose bounds fully contain
/// the item's box; an item straddling a split line is forced up toward the root,
/// so in the worst case (an entity crossing the world center) it lands at the root
/// and is visited by *every* query. A **loose** quadtree fixes this by letting an
/// item descend based on the node's *loose* bounds — the node's tight cell scaled
/// up about its center by `loosenessFactor` (here 2×). A box up to a full cell
/// wide therefore still fits a child's loose bounds, so straddling entities sink
/// to a sensible depth instead of piling up at the root. Queries expand each
/// node's tight cell by the same factor when testing overlap. This is the variant
/// recommended in `rendering-performance.md §2.2` for an interactively-edited CAD
/// drawing (cheap incremental insert/remove, no global rebuild on edits).
///
/// ## Auto-growing root
/// The tree starts with no spatial extent. The first insert seeds the root cell
/// from that box; later inserts whose box is not contained by the current root's
/// *loose* bounds trigger a **grow-by-rebuild**: the root cell is doubled (toward
/// the new box) until it covers everything, then all items are re-inserted. Grow
/// is amortized O(n) and rare in practice (CAD drawings settle into a stable world
/// extent quickly); steady-state insert/remove/query never rebuild. Callers that
/// know their world bound up front can `reserveWorld(_:)` once to avoid the early
/// regrowths entirely.
///
/// ## Performance contract
/// `query(region:)` and `query(point:tolerance:)` descend only into nodes whose
/// loose bounds overlap the query and append matching ids to a single result
/// array — cost scales with the number of overlapping nodes/items (≈ result size),
/// not with the total count. No per-query heap allocation beyond the result array
/// (the descent uses an explicit stack reused per call; node children are stored
/// inline). See `QuadtreeTests` for the 100k-insert small-viewport behavior.
///
/// ## Concurrency
/// `Quadtree` is a **non-`Sendable`** mutable `final class`. Per ADR / the
/// rendering doc (§4.5, §5), the index lives behind `CADEngine` / on the main
/// actor: edits drive `insert/update/remove` and the render + snap paths drive
/// `query` from the same isolation domain. It is deliberately *not* marked
/// `@unchecked Sendable` — there is no internal locking, and silently allowing it
/// across actors would invite data races. If a future off-main-actor consumer
/// needs it, wrap it in an actor or take an immutable snapshot rather than
/// weakening this type.
public final class Quadtree {

    // MARK: Tuning

    /// Looseness multiplier applied to a node's tight cell about its center.
    /// 2.0 is the canonical value: a child's loose bounds then exactly cover its
    /// parent's tight cell, so an entity up to one cell wide always fits a child.
    private let loosenessFactor: Double

    /// A node splits once it holds more than this many items *and* is allowed to
    /// go deeper. Small enough that leaf scans stay cheap; large enough that we
    /// don't over-subdivide sparse regions. 8 is a good default for CAD AABBs.
    private let splitThreshold: Int

    /// Hard cap on subdivision depth. Bounds the tree height (and the worst-case
    /// query stack) so a tight cluster of coincident boxes can't recurse forever;
    /// at max depth a node simply keeps all its items in a (possibly large) leaf.
    /// 16 levels over the root span is far finer than any realistic query box.
    private let maxDepth: Int

    // MARK: Node storage

    /// One quadtree node. A node is a leaf (`children == nil`) holding `items`, or
    /// an internal node with four `children` (NW, NE, SW, SE) plus `items` that
    /// straddle this node's children and can't sink further.
    private final class Node {
        /// The node's *tight* cell (its quadrant of the parent). Loose bounds are
        /// derived on demand via `looseBounds(factor:)`.
        var bounds: AABB
        let depth: Int
        /// Items whose box is contained by this node's loose bounds but not by any
        /// single child's loose bounds (or this is a leaf).
        var items: [(id: EntityID, box: AABB)] = []
        /// NW, NE, SW, SE — `nil` until the node splits.
        var children: [Node]?

        init(bounds: AABB, depth: Int) {
            self.bounds = bounds
            self.depth = depth
        }

        /// The node's loose bounds: the tight cell scaled about its center by
        /// `factor`. Queries and descent decisions test against these.
        @inline(__always)
        func looseBounds(factor: Double) -> AABB {
            let c = bounds.center
            let half = (bounds.max - bounds.min) * (0.5 * factor)
            return AABB(min: Vector(c.x - half.x, c.y - half.y),
                        max: Vector(c.x + half.x, c.y + half.y))
        }
    }

    /// Root node; `nil` until the first insert seeds the world extent.
    private var root: Node?

    /// Every indexed id mapped to its current box. This is the authoritative
    /// membership set: it makes `remove`/`update` O(1) to look up the old box, and
    /// lets us detect duplicate inserts and rebuild cheaply on grow.
    private var boxes: [EntityID: AABB] = [:]

    /// The number of indexed entities.
    public var count: Int { boxes.count }

    /// Whether the index holds no entities.
    public var isEmpty: Bool { boxes.isEmpty }

    // MARK: Init

    /// Creates an empty quadtree.
    ///
    /// - Parameters:
    ///   - looseness: cell expansion factor (default 2.0 — see type docs).
    ///   - splitThreshold: items per node before it subdivides (default 8).
    ///   - maxDepth: maximum subdivision depth (default 16).
    public init(looseness: Double = 2.0, splitThreshold: Int = 8, maxDepth: Int = 16) {
        precondition(looseness >= 1.0, "looseness must be >= 1")
        precondition(splitThreshold >= 1, "splitThreshold must be >= 1")
        precondition(maxDepth >= 0, "maxDepth must be >= 0")
        self.loosenessFactor = looseness
        self.splitThreshold = splitThreshold
        self.maxDepth = maxDepth
    }

    // MARK: - Mutation

    /// Pre-seeds the root cell to a known world bound so early inserts inside it
    /// never trigger a regrow. Optional — purely a performance hint. Has no effect
    /// once anything has been inserted (the extent is then owned by the tree).
    public func reserveWorld(_ bound: AABB) {
        guard root == nil, !bound.isEmpty else { return }
        root = Node(bounds: squared(bound), depth: 0)
    }

    /// Inserts `id` with bounding box `bounds`.
    ///
    /// If `id` is already present its box is replaced (equivalent to `update`).
    /// An empty/invalid box is rejected (nothing to index). Inserting outside the
    /// current root grows the tree (see type docs).
    public func insert(_ id: EntityID, bounds: AABB) {
        guard !bounds.isEmpty else { return }

        // Re-insert path: if the id already exists, remove its old placement first
        // so we don't leave a stale entry in a node.
        if boxes[id] != nil {
            removeFromTree(id)
        }
        boxes[id] = bounds

        // Seed or grow the root so it (loosely) contains the new box.
        if root == nil {
            root = Node(bounds: squared(bounds), depth: 0)
        } else if !root!.looseBounds(factor: loosenessFactor).contains2D(bounds) {
            // grow() rebuilds the whole tree from `boxes` (which now includes this
            // id), so the placement is already done — don't insert it again.
            grow(toCover: bounds)
            return
        }

        insert(id: id, box: bounds, into: root!)
    }

    /// Removes `id` from the index. No-op if it isn't present.
    public func remove(_ id: EntityID) {
        guard boxes[id] != nil else { return }
        removeFromTree(id)
        boxes[id] = nil
    }

    /// Moves `id` to a new box (remove + reinsert). If `id` isn't present this is
    /// a plain insert. This is the edit path the renderer/snapper call when an
    /// entity's geometry changes.
    public func update(_ id: EntityID, bounds: AABB) {
        insert(id, bounds: bounds)
    }

    /// Drops every entity and the spatial extent, returning to the freshly-init
    /// state. Cheaper than removing ids one by one when clearing a document.
    public func removeAll() {
        root = nil
        boxes.removeAll(keepingCapacity: true)
    }

    // MARK: - Queries

    /// All entity ids whose box overlaps `region` (inclusive on edges).
    ///
    /// This is the viewport-culling / window-selection query: pass the visible
    /// world rectangle (the renderer) or a selection rectangle (interaction).
    /// Returned ids are *candidates* by AABB; callers needing exact containment
    /// do the precise test themselves. Order is unspecified.
    public func query(region: AABB) -> [EntityID] {
        var result: [EntityID] = []
        guard let root, !region.isEmpty else { return result }
        // Reused descent stack — one allocation per call, then in-place push/pop.
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            // Prune whole subtrees whose loose bounds miss the query.
            guard node.looseBounds(factor: loosenessFactor).overlaps2D(region) else { continue }
            for item in node.items where item.box.overlaps2D(region) {
                result.append(item.id)
            }
            if let children = node.children {
                for child in children { stack.append(child) }
            }
        }
        return result
    }

    /// All entity ids whose box is within `tolerance` of `point` (i.e. whose box,
    /// inflated by `tolerance` on every side, contains `point`).
    ///
    /// This is the hit-test / snapping candidate query (rendering-performance.md
    /// §5): `point` is the cursor in world space, `tolerance` is the pick aperture
    /// (`m_catchEntityGuiRange` converted from GUI pixels to world units). Returned
    /// ids are candidates; the caller runs exact analytic geometry tests against
    /// each. A negative tolerance is treated as zero.
    public func query(point: Vector, tolerance: Double) -> [EntityID] {
        guard point.valid else { return [] }
        let t = Swift.max(tolerance, 0)
        let probe = AABB(min: Vector(point.x - t, point.y - t),
                         max: Vector(point.x + t, point.y + t))
        return query(region: probe)
    }

    /// All entity ids whose box overlaps `aabb` (inclusive on edges).
    ///
    /// Convenience alias for `query(region:)` — the form the snap fast path
    /// describes as `query(aabb: AABB)` / `AABB(min: cursor - tol, max: cursor
    /// + tol)`. Callers that already have a world-space tolerance box can pass it
    /// directly; it is identical to `query(point:tolerance:)` with the same
    /// extents. Exists so the snap/fast-path documentation's `query(aabb:)`
    /// name resolves (the implementation is the same region query).
    public func query(aabb: AABB) -> [EntityID] {
        query(region: aabb)
    }

    /// The single entity whose box is closest to `point` (by box-to-point
    /// distance), within `maxDistance` if given, else `nil`.
    ///
    /// This is a convenience for "nearest entity under/near the cursor". Distance
    /// is measured to the entity's AABB (0 if `point` is inside the box), so it is
    /// a *candidate* selector — the caller still runs exact geometry to break ties
    /// among boxes that are equidistant (e.g. several boxes containing the point).
    /// Walks only nodes whose loose bounds are within the current best distance, so
    /// it stays output-sensitive rather than scanning all entities.
    public func nearest(to point: Vector, maxDistance: Double = .greatestFiniteMagnitude) -> EntityID? {
        guard point.valid, let root else { return nil }
        let cap = Swift.max(maxDistance, 0)
        var best: EntityID? = nil
        // The best distance found so far. Starts just above the cap so the *first*
        // qualifying candidate (including one exactly at the cap, e.g. a point on a
        // box edge with cap 0) is accepted, then later candidates must strictly beat
        // it. `bound` is what we prune subtrees against — always the tighter of the
        // cap and the current best.
        var bestDist = Double.greatestFiniteMagnitude
        var stack: [Node] = [root]
        while let node = stack.popLast() {
            // Prune subtrees whose loose bounds are farther than the active bound
            // (current best, never exceeding the cap).
            let bound = Swift.min(bestDist, cap)
            let loose = node.looseBounds(factor: loosenessFactor)
            if distanceSquared(from: point, to: loose) > bound * bound { continue }
            for item in node.items {
                let d = distance(from: point, to: item.box)
                // Accept if within the cap and strictly closer than the best so far.
                if d <= cap && d < bestDist {
                    bestDist = d
                    best = item.id
                }
            }
            if let children = node.children {
                for child in children { stack.append(child) }
            }
        }
        return best
    }

    /// The current box indexed for `id`, if present. (Exposed for callers that
    /// want to avoid keeping a parallel map.)
    public func box(for id: EntityID) -> AABB? { boxes[id] }

    // MARK: - Insertion internals

    /// Recursively (iteratively) places an item into the deepest node whose loose
    /// bounds fully contain its box, splitting leaves that exceed the threshold.
    private func insert(id: EntityID, box: AABB, into start: Node) {
        var node = start
        while true {
            // At max depth, or a too-small cell to split meaningfully, just store.
            if node.depth >= maxDepth {
                node.items.append((id, box))
                return
            }

            if node.children == nil {
                // Leaf: store, then split if we just exceeded the threshold.
                node.items.append((id, box))
                if node.items.count > splitThreshold {
                    split(node)
                }
                return
            }

            // Internal node: descend into the one child whose loose bounds fully
            // contain the box; if none do (the box straddles children), keep it here.
            if let child = childContaining(box, in: node) {
                node = child
            } else {
                node.items.append((id, box))
                return
            }
        }
    }

    /// Subdivides a leaf into four children and re-distributes any items that now
    /// fit entirely inside a single child's loose bounds. Items that straddle stay
    /// on the parent.
    private func split(_ node: Node) {
        let b = node.bounds
        let c = b.center
        let childDepth = node.depth + 1
        // NW, NE, SW, SE quadrants of the tight cell.
        let nw = AABB(min: Vector(b.min.x, c.y), max: Vector(c.x, b.max.y))
        let ne = AABB(min: Vector(c.x, c.y),     max: Vector(b.max.x, b.max.y))
        let sw = AABB(min: Vector(b.min.x, b.min.y), max: Vector(c.x, c.y))
        let se = AABB(min: Vector(c.x, b.min.y), max: Vector(b.max.x, c.y))
        let children = [
            Node(bounds: nw, depth: childDepth),
            Node(bounds: ne, depth: childDepth),
            Node(bounds: sw, depth: childDepth),
            Node(bounds: se, depth: childDepth),
        ]
        node.children = children

        // Re-home items that fit a single child; keep straddlers on the parent.
        let toRedistribute = node.items
        node.items.removeAll(keepingCapacity: true)
        for item in toRedistribute {
            if let child = childContaining(item.box, in: node) {
                // Direct append (child is a fresh leaf below threshold) — recursing
                // through insert() would re-test depth/threshold needlessly.
                child.items.append(item)
            } else {
                node.items.append(item)
            }
        }
        // A freshly split child can itself exceed the threshold if many items
        // landed in one quadrant; recurse so depth stays balanced.
        for child in children where child.items.count > splitThreshold && child.depth < maxDepth {
            split(child)
        }
    }

    /// Returns the single child of `node` whose *loose* bounds fully contain `box`,
    /// or `nil` if the box straddles more than one child (or fits none).
    @inline(__always)
    private func childContaining(_ box: AABB, in node: Node) -> Node? {
        guard let children = node.children else { return nil }
        var found: Node? = nil
        for child in children where child.looseBounds(factor: loosenessFactor).contains2D(box) {
            if found != nil { return nil }  // fits two children → straddles → keep on parent
            found = child
        }
        return found
    }

    // MARK: - Removal internals

    /// Removes `id`'s placement from the tree structure (leaves `boxes` to the
    /// caller). Uses the recorded box to walk straight down to the holding node
    /// rather than scanning the whole tree.
    private func removeFromTree(_ id: EntityID) {
        guard let root, let box = boxes[id] else { return }
        var node: Node? = root
        while let n = node {
            if let idx = n.items.firstIndex(where: { $0.id == id }) {
                n.items.remove(at: idx)
                return
            }
            node = childContaining(box, in: n)
        }
        // Fallback: the box may have changed since insertion in pathological cases
        // (it shouldn't, since update() re-inserts). Do a full scan to stay correct.
        removeByFullScan(id)
    }

    /// Last-resort removal: walk the entire tree. Only reached if the guided
    /// descent missed (kept for correctness robustness; not on the hot path).
    private func removeByFullScan(_ id: EntityID) {
        guard let root else { return }
        var stack: [Node] = [root]
        while let n = stack.popLast() {
            if let idx = n.items.firstIndex(where: { $0.id == id }) {
                n.items.remove(at: idx)
                return
            }
            if let children = n.children { stack.append(contentsOf: children) }
        }
    }

    // MARK: - Growing

    /// Grows the root cell until its loose bounds cover `box`, then rebuilds.
    private func grow(toCover box: AABB) {
        guard var current = root?.bounds else {
            root = Node(bounds: squared(box), depth: 0)
            rebuild()
            return
        }
        // Double the cell toward the offending box until it (loosely) fits.
        // Guard the loop with maxDepth doublings so a NaN/inf box can't spin.
        var guardCount = 0
        while true {
            let loose = looseBounds(of: current)
            if loose.contains2D(box) { break }
            current = doubled(current, toward: box)
            guardCount += 1
            if guardCount > 64 { break }  // pathological; rebuild with whatever we have
        }
        root = Node(bounds: current, depth: 0)
        rebuild()
    }

    /// Rebuilds the tree structure from `boxes` into the current root cell. Called
    /// after a grow; O(n) in the number of indexed entities.
    private func rebuild() {
        guard let root else { return }
        root.items.removeAll(keepingCapacity: true)
        root.children = nil
        for (id, box) in boxes {
            insert(id: id, box: box, into: root)
        }
    }

    // MARK: - Cell geometry helpers

    /// Loose bounds of a bare tight cell (mirrors `Node.looseBounds`).
    @inline(__always)
    private func looseBounds(of cell: AABB) -> AABB {
        let c = cell.center
        let half = (cell.max - cell.min) * (0.5 * loosenessFactor)
        return AABB(min: Vector(c.x - half.x, c.y - half.y),
                    max: Vector(c.x + half.x, c.y + half.y))
    }

    /// Returns a square cell centered on `box`'s center, sized to the larger of
    /// the box's width/height (with a small floor so a degenerate/point box still
    /// yields a usable, non-zero cell). Square cells keep the four quadrants
    /// uniform so the looseness reasoning holds in both axes.
    private func squared(_ box: AABB) -> AABB {
        let c = box.center
        let w = box.max.x - box.min.x
        let h = box.max.y - box.min.y
        // Floor avoids a zero-size root for a single point; 1.0 world unit is an
        // arbitrary but harmless seed — the tree grows from here as needed.
        let side = Swift.max(Swift.max(w, h), 1.0)
        let half = side * 0.5
        return AABB(min: Vector(c.x - half, c.y - half),
                    max: Vector(c.x + half, c.y + half))
    }

    /// Doubles `cell` about its center, keeping it square. The cell is recentered
    /// toward `target`'s center so growth heads in the useful direction; the
    /// doubled side plus the loose factor then brings `target` inside within
    /// log(distance) doublings. `target` is currently used only to bias the
    /// recenter; symmetric doubling alone also converges, so a future tweak can
    /// drop the bias without changing correctness.
    private func doubled(_ cell: AABB, toward target: AABB) -> AABB {
        let side = cell.max.x - cell.min.x          // square ⇒ width == height
        let newSide = side * 2.0
        // Bias the new center halfway toward the target so we don't waste growth
        // expanding away from it; clamp the shift to a quarter of the new side so
        // the old cell stays comfortably inside the new one.
        let oldCenter = cell.center
        let tCenter = target.center
        let maxShift = newSide * 0.25
        let shiftX = clamp((tCenter.x - oldCenter.x) * 0.5, -maxShift, maxShift)
        let shiftY = clamp((tCenter.y - oldCenter.y) * 0.5, -maxShift, maxShift)
        let cx = oldCenter.x + shiftX
        let cy = oldCenter.y + shiftY
        let half = newSide * 0.5
        return AABB(min: Vector(cx - half, cy - half),
                    max: Vector(cx + half, cy + half))
    }

    @inline(__always)
    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        Swift.min(Swift.max(v, lo), hi)
    }

    // MARK: - Distance helpers (point ↔ box)

    /// Euclidean distance from `point` to the nearest part of `box` (0 if inside).
    @inline(__always)
    private func distance(from point: Vector, to box: AABB) -> Double {
        distanceSquared(from: point, to: box).squareRoot()
    }

    /// Squared distance from `point` to the nearest part of `box` (0 if inside).
    @inline(__always)
    private func distanceSquared(from point: Vector, to box: AABB) -> Double {
        if box.isEmpty { return .greatestFiniteMagnitude }
        let dx = Swift.max(box.min.x - point.x, 0, point.x - box.max.x)
        let dy = Swift.max(box.min.y - point.y, 0, point.y - box.max.y)
        return dx * dx + dy * dy
    }
}
