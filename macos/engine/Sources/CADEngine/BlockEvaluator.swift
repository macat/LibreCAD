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
    /// The pipeline (all PURE; `members` is never mutated, a FRESH array is returned):
    /// 1. **VISIBILITY (§9):** if `def` declares visibility states, drop the members
    ///    not in the ACTIVE state — `instanceState?.activeVisibilityState` matched by
    ///    name, else the FIRST declared state as the default (§9.5). No states ⇒ all
    ///    members survive.
    /// 2. **ACTIONS (DB-2 — STRETCH §6.2.3 + FLIP §6.2.6):** for each action in
    ///    DEFINITION order, transform the surviving members in ITS selection set:
    ///    - **flip:** if `instanceState.flipStates[paramID] == true`, MIRROR those
    ///      members about the flip parameter's reflection line (a double-flip is the
    ///      identity, since two reflections about the same line compose to identity).
    ///    - **stretch:** the linear parameter's instance distance
    ///      (`parameterValues[paramID]`, default = the parameter's base distance)
    ///      minus the base distance is a signed delta ALONG the parameter direction,
    ///      times `distanceMultiplier`, rotated by `angleOffset` (§13.4). Each
    ///      member's DEFINING POINTS inside `stretchFrame` move by that delta; points
    ///      outside stay (per-vertex partial transform).
    ///
    /// If `def` is `nil`, or has neither visibility states nor actions, the members
    /// are returned UNCHANGED — zero behavior change for DB-1 / static blocks.
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
        // A plain block (no dynamic def, or a def with no visibility states AND no
        // actions): every member survives unchanged — return them as-is (CoW, no copy).
        guard let def, !(def.visibilityStates.isEmpty && def.actions.isEmpty) else {
            return members
        }

        // ── Step 1: VISIBILITY filter (§9) ────────────────────────────────────────
        var survivors = visibilityFiltered(def: def, members: members,
                                           instanceState: instanceState)

        // No actions ⇒ the visibility result is the answer (DB-1 path unchanged).
        guard !def.actions.isEmpty else { return survivors }

        // ── Step 2: ACTIONS (DB-2) — applied in DEFINITION order ──────────────────
        // Build an id→index map over the SURVIVING members so each action transforms
        // a copy of its selection-set members in place (CoW). Members not in any
        // action's set are untouched; a member in several action sets composes them.
        var indexByID: [EntityID: Int] = [:]
        indexByID.reserveCapacity(survivors.count)
        for (i, rec) in survivors.enumerated() { indexByID[rec.id] = i }

        for action in def.actions {
            switch action {
            case .flip(_, let paramID, let memberIDs):
                applyFlip(paramID: paramID, memberIDs: memberIDs, def: def,
                          instanceState: instanceState,
                          survivors: &survivors, indexByID: indexByID)
            case .stretch(_, let paramID, let frame, let memberIDs, let mult, let ang):
                applyStretch(paramID: paramID, frame: frame, memberIDs: memberIDs,
                             distanceMultiplier: mult, angleOffset: ang, def: def,
                             instanceState: instanceState,
                             survivors: &survivors, indexByID: indexByID)
            }
        }
        return survivors
    }

    // MARK: - Step 1: visibility filter

    /// The visibility-filtered member subset (§9), or `members` unchanged when the
    /// block declares no visibility states. Factored out so the action step composes
    /// on its result.
    private static func visibilityFiltered(def: DynamicBlockDef,
                                           members: [EntityRecord],
                                           instanceState: InsertDynamicState?) -> [EntityRecord] {
        guard !def.visibilityStates.isEmpty else { return members }
        let active: BlockVisibilityState?
        if let name = instanceState?.activeVisibilityState,
           let named = def.visibilityState(named: name) {
            active = named
        } else {
            active = def.defaultVisibilityState
        }
        guard let state = active else { return members }
        return members.filter { state.visibleMemberIDs.contains($0.id) }
    }

    // MARK: - Step 2: FLIP action (§6.2.6)

    /// Mirrors the action's surviving members about the flip parameter's reflection
    /// line when the instance flip state is `true`. A `false`/absent flip state, an
    /// absent/non-`.flip` parameter, or a degenerate reflection line is a no-op (the
    /// members are left exactly as the visibility filter produced them). NaN-safe.
    private static func applyFlip(paramID: BlockParameterID,
                                  memberIDs: Set<EntityID>,
                                  def: DynamicBlockDef,
                                  instanceState: InsertDynamicState?,
                                  survivors: inout [EntityRecord],
                                  indexByID: [EntityID: Int]) {
        // Only flip when the instance state says so.
        guard instanceState?.flipStates[paramID.raw] == true else { return }
        // The parameter must exist and be a flip parameter with a valid line.
        guard case let .flip(_, _, lineStart, lineEnd)? = def.parameter(paramID),
              lineStart.valid, lineEnd.valid,
              (lineEnd - lineStart).magnitude > Tolerance.distance else { return }
        let mirror = Affine2D.mirror(axisPoint1: lineStart, axisPoint2: lineEnd)
        for id in memberIDs {
            guard let i = indexByID[id] else { continue }
            survivors[i].kind = survivors[i].kind.transformed(by: mirror)
        }
    }

    // MARK: - Step 2: STRETCH action (§6.2.3)

    /// Moves each action-member's defining points INSIDE `frame` by the linear
    /// parameter's signed delta (current distance − base distance) along the
    /// parameter direction, scaled by `distanceMultiplier` and rotated by
    /// `angleOffset` (§13.4); points outside the frame stay. A zero delta, an absent/
    /// non-`.linear` parameter, or a degenerate parameter direction is a no-op.
    /// NaN-safe (a non-finite delta is dropped).
    private static func applyStretch(paramID: BlockParameterID,
                                     frame: AABB,
                                     memberIDs: Set<EntityID>,
                                     distanceMultiplier: Double,
                                     angleOffset: Double,
                                     def: DynamicBlockDef,
                                     instanceState: InsertDynamicState?,
                                     survivors: inout [EntityRecord],
                                     indexByID: [EntityID: Int]) {
        // The parameter must exist, be linear, and have a usable direction + base.
        guard let param = def.parameter(paramID),
              let dir = param.unitDirection,
              let baseDistance = param.baseDistance else { return }
        // Current distance: the instance value, else the base distance (no stretch).
        let current = instanceState?.parameterValues[paramID.raw] ?? baseDistance
        guard current.isFinite, distanceMultiplier.isFinite, angleOffset.isFinite else { return }
        let signed = (current - baseDistance) * distanceMultiplier
        guard signed.isFinite, abs(signed) > Tolerance.distance else { return }
        // The displacement vector: along the parameter direction, rotated by the
        // angle offset (§13.4). `dir` is already unit length.
        let delta = Vector(dir.x * signed, dir.y * signed).rotated(by: angleOffset)
        guard delta.valid, delta.x.isFinite, delta.y.isFinite else { return }

        for id in memberIDs {
            guard let i = indexByID[id] else { continue }
            survivors[i].kind = stretched(survivors[i].kind, insideFrame: frame, by: delta)
        }
    }

    /// Returns `kind` with each DEFINING POINT inside `frame` translated by `delta`;
    /// points outside `frame` unchanged. The per-vertex partial transform STRETCH
    /// (§6.2.3) — distinct from `EntityKind.transformed(by:)`, which moves the whole
    /// entity.
    ///
    /// ## v1 member-kind coverage (the documented cut, dynamic-blocks-plan §5/§10.5)
    /// - **line:** each endpoint tested independently (the canonical stretch).
    /// - **polyline:** per-vertex (bulges preserved).
    /// - **point:** its single position tested.
    /// - **circle / arc:** the CENTER is tested → if inside, the WHOLE entity moves
    ///   (a partial-vertex stretch of a circle/arc would distort it into a non-circle;
    ///   AutoCAD likewise moves a circle whole if its center is in the frame).
    /// - **everything else** (ellipse, spline, splinePoints, text, mtext, hatch,
    ///   solid, dimension, nested insert, xline, ray, leader, image): a WHOLE-ENTITY
    ///   fallback — if the kind's bounding box overlaps the frame, the whole entity
    ///   moves by `delta`; otherwise it stays. This keeps v1 bounded while never
    ///   silently dropping a member.
    static func stretched(_ kind: EntityKind, insideFrame frame: AABB, by delta: Vector) -> EntityKind {
        // Translating a point by `delta` iff it is inside the frame.
        func moved(_ p: Vector) -> Vector { frame.contains(p) ? p + delta : p }

        switch kind {
        case .line(let l):
            return .line(LineData(start: moved(l.start), end: moved(l.end)))

        case .polyline(let pl):
            let verts = pl.vertices.map { PolylineVertex(point: moved($0.point), bulge: $0.bulge) }
            return .polyline(PolylineData(vertices: verts, closed: pl.closed))

        case .point(let p):
            return .point(PointData(position: moved(p.position), style: p.style))

        case .circle(let c):
            // Center inside ⇒ move the whole circle (partial stretch would distort it).
            return frame.contains(c.center)
                ? .circle(CircleData(center: c.center + delta, radius: c.radius))
                : kind

        case .arc(let a):
            return frame.contains(a.center)
                ? .arc(ArcData(center: a.center + delta, radius: a.radius,
                               startAngle: a.startAngle, endAngle: a.endAngle,
                               reversed: a.reversed))
                : kind

        // Whole-entity fallback: move the whole entity iff ANY defining point is in
        // the frame (v1 cut — these kinds have no clean per-vertex stretch here).
        default:
            return anyDefiningPointInside(kind, frame: frame)
                ? kind.transformed(by: .translation(delta))
                : kind
        }
    }

    /// `true` if `kind`'s (no-arg) bounding box overlaps `frame` — the trigger for
    /// the whole-entity stretch fallback (cheap, kind-agnostic, NaN-safe).
    ///
    /// CAVEAT (v1 cut): this uses `EntityKind.boundingBox()` with NO block provider,
    /// so a nested `.insert` member's box collapses to its insertion point only — a
    /// nested insert whose CONTENT overlaps the frame but whose insertion point does
    /// not will not trigger the move. Consistent with text/leader/xline using their
    /// loose no-arg boxes; no member is ever silently dropped. Refining nested-insert
    /// stretch is deferred (dynamic-blocks-plan §5).
    private static func anyDefiningPointInside(_ kind: EntityKind, frame: AABB) -> Bool {
        let box = kind.boundingBox()
        guard !box.isEmpty, !frame.isEmpty else { return false }
        // AABB overlap test (inclusive) in x/y — any defining geometry inside the
        // crossing frame means the member is stretched (moved whole).
        return box.min.x <= frame.max.x && box.max.x >= frame.min.x
            && box.min.y <= frame.max.y && box.max.y >= frame.min.y
    }
}
