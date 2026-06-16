//
//  DynamicBlockStretchFlipTests.swift
//  CADEngineTests
//
//  DB-2 engine coverage — dynamic-block PARAMETERS + ACTIONS: a LINEAR parameter
//  driving a STRETCH action and a FLIP parameter driving a FLIP action. Validates:
//   - FLIP: members mirror about the flip line when the instance state is on; off =
//     identity; double-flip stability; only the action's member subset is affected.
//   - STRETCH: per-vertex partial move (defining points inside the frame move, points
//     outside stay) across line / point / polyline / circle / arc + the whole-entity
//     fallback; distanceMultiplier scales; angleOffset rotates the delta; base value
//     = no change.
//   - PURITY/ISOLATION: same block at two instance states → independent; MINSERT
//     cells identical + source unmutated; visibility + stretch compose.
//   - BACK-COMPAT: DB-1 (visibility-only) DynamicBlockDef JSON + pre-DB-2
//     InsertDynamicState JSON decode fine (parameters/actions = [], flipStates = [:]);
//     static blocks unchanged.
//
//  Uniquely namespaced (`@Suite("dynamic block — stretch + flip (DB-2)")`) so it never
//  collides with the DB-1 visibility suite.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("dynamic block — stretch + flip (DB-2)", .serialized)
@MainActor
struct DynamicBlockStretchFlipTests {

    // MARK: - Helpers

    private func line(_ id: UInt64, _ s: Vector, _ e: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .line(LineData(start: s, end: e)))
    }
    private func point(_ id: UInt64, _ p: Vector) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .point(PointData(position: p)))
    }
    private func circle(_ id: UInt64, _ c: Vector, _ r: Double) -> EntityRecord {
        EntityRecord(id: EntityID(id), kind: .circle(CircleData(center: c, radius: r)))
    }

    private func nearly(_ a: Vector, _ b: Vector, _ tol: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    /// Extract the single line member's data from an evaluated result.
    private func lineData(_ recs: [EntityRecord], id: UInt64) -> LineData? {
        guard let rec = recs.first(where: { $0.id == EntityID(id) }),
              case let .line(l) = rec.kind else { return nil }
        return l
    }
    private func pointData(_ recs: [EntityRecord], id: UInt64) -> PointData? {
        guard let rec = recs.first(where: { $0.id == EntityID(id) }),
              case let .point(p) = rec.kind else { return nil }
        return p
    }
    private func circleData(_ recs: [EntityRecord], id: UInt64) -> CircleData? {
        guard let rec = recs.first(where: { $0.id == EntityID(id) }),
              case let .circle(c) = rec.kind else { return nil }
        return c
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - FLIP action
    // ─────────────────────────────────────────────────────────────────────────────

    /// A def whose member id 1 is flipped about the vertical line x = 0 (y-axis).
    private func flipDef(paramID: String = "fp", line s: Vector, _ e: Vector,
                         members: Set<EntityID>) -> DynamicBlockDef {
        DynamicBlockDef(
            parameters: [.flip(id: BlockParameterID(paramID), label: "Flip",
                               lineStart: s, lineEnd: e)],
            actions: [.flip(id: BlockActionID("fa"),
                            parameterID: BlockParameterID(paramID), memberIDs: members)])
    }

    @Test("flip ON mirrors the action's members about the reflection line")
    func flipOnMirrors() {
        // Member: a point at (3, 7); flip line = the y-axis (x=0). ON ⇒ x negates.
        let members = [point(1, Vector(3, 7))]
        let def = flipDef(line: Vector(0, -1), Vector(0, 1), members: [EntityID(1)])
        let on = InsertDynamicState(flipStates: ["fp": true])
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: on)
        #expect(nearly(pointData(r, id: 1)!.position, Vector(-3, 7)))
    }

    @Test("flip OFF (and absent) is the identity")
    func flipOffIsIdentity() {
        let members = [point(1, Vector(3, 7))]
        let def = flipDef(line: Vector(0, -1), Vector(0, 1), members: [EntityID(1)])
        let off = BlockEvaluator.evaluate(def, members: members,
                                          instanceState: InsertDynamicState(flipStates: ["fp": false]))
        let absent = BlockEvaluator.evaluate(def, members: members,
                                             instanceState: InsertDynamicState())
        let nilState = BlockEvaluator.evaluate(def, members: members, instanceState: nil)
        #expect(nearly(pointData(off, id: 1)!.position, Vector(3, 7)))
        #expect(nearly(pointData(absent, id: 1)!.position, Vector(3, 7)))
        #expect(nearly(pointData(nilState, id: 1)!.position, Vector(3, 7)))
    }

    @Test("double-flip is stable (flipping a flip-applied result re-mirrors back)")
    func doubleFlipStability() {
        // Two flip actions on the same line + same member ⇒ a flip applied twice
        // returns to the original (two reflections about one line = identity).
        let members = [point(1, Vector(3, 7))]
        let def = DynamicBlockDef(
            parameters: [.flip(id: BlockParameterID("fp"), label: "Flip",
                               lineStart: Vector(0, -1), lineEnd: Vector(0, 1))],
            actions: [
                .flip(id: BlockActionID("fa1"), parameterID: BlockParameterID("fp"),
                      memberIDs: [EntityID(1)]),
                .flip(id: BlockActionID("fa2"), parameterID: BlockParameterID("fp"),
                      memberIDs: [EntityID(1)]),
            ])
        let r = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(flipStates: ["fp": true]))
        #expect(nearly(pointData(r, id: 1)!.position, Vector(3, 7)))
    }

    @Test("flip affects ONLY the action's member subset")
    func flipAffectsOnlySubset() {
        // m1 in the flip set, m2 NOT. Only m1 mirrors.
        let members = [point(1, Vector(3, 7)), point(2, Vector(4, 8))]
        let def = flipDef(line: Vector(0, -1), Vector(0, 1), members: [EntityID(1)])
        let r = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(flipStates: ["fp": true]))
        #expect(nearly(pointData(r, id: 1)!.position, Vector(-3, 7)))   // flipped
        #expect(nearly(pointData(r, id: 2)!.position, Vector(4, 8)))    // untouched
    }

    @Test("flip about a diagonal line mirrors a line member correctly")
    func flipDiagonalLine() {
        // Mirror across y = x (line through (0,0)→(1,1)): (a,b) ↦ (b,a).
        let members = [line(1, Vector(2, 0), Vector(5, 1))]
        let def = flipDef(line: Vector(0, 0), Vector(1, 1), members: [EntityID(1)])
        let r = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(flipStates: ["fp": true]))
        let l = lineData(r, id: 1)!
        #expect(nearly(l.start, Vector(0, 2), 1e-9))
        #expect(nearly(l.end, Vector(1, 5), 1e-9))
    }

    @Test("a degenerate flip line is a no-op")
    func degenerateFlipLineNoop() {
        let members = [point(1, Vector(3, 7))]
        let def = flipDef(line: Vector(2, 2), Vector(2, 2), members: [EntityID(1)]) // zero-length
        let r = BlockEvaluator.evaluate(def, members: members,
                                        instanceState: InsertDynamicState(flipStates: ["fp": true]))
        #expect(nearly(pointData(r, id: 1)!.position, Vector(3, 7)))
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - STRETCH action
    // ─────────────────────────────────────────────────────────────────────────────

    /// A def whose stretch frame = the right half (x ≥ 5), driven by a horizontal
    /// linear param base→end = (0,0)→(10,0) (base distance 10, direction +x).
    private func stretchDef(members: Set<EntityID>, frame: AABB? = nil,
                            mult: Double = 1, angle: Double = 0) -> DynamicBlockDef {
        DynamicBlockDef(
            parameters: [.linear(id: BlockParameterID("lp"), label: "Length",
                                 base: Vector(0, 0), end: Vector(10, 0))],
            actions: [.stretch(id: BlockActionID("sa"),
                               parameterID: BlockParameterID("lp"),
                               stretchFrame: frame ?? AABB(min: Vector(5, -1e6),
                                                           max: Vector(1e6, 1e6)),
                               memberIDs: members,
                               distanceMultiplier: mult, angleOffset: angle)])
    }

    @Test("line: only the endpoint inside the frame moves by the delta")
    func lineStretchEndpointInside() {
        // Line 0→10 along x; frame covers x≥5 ⇒ end (10,0) inside, start (0,0) outside.
        // Instance distance 13 (base 10) ⇒ delta = +3 along +x.
        let members = [line(1, Vector(0, 0), Vector(10, 0))]
        let def = stretchDef(members: [EntityID(1)])
        let st = InsertDynamicState(parameterValues: ["lp": 13])
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        let l = lineData(r, id: 1)!
        #expect(nearly(l.start, Vector(0, 0)))     // outside → stays
        #expect(nearly(l.end, Vector(13, 0)))      // inside → +3
    }

    @Test("point inside moves; point outside stays")
    func pointStretchInsideOutside() {
        let members = [point(1, Vector(8, 0)), point(2, Vector(2, 0))]
        let def = stretchDef(members: [EntityID(1), EntityID(2)])
        let st = InsertDynamicState(parameterValues: ["lp": 14]) // delta +4
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        #expect(nearly(pointData(r, id: 1)!.position, Vector(12, 0))) // 8 inside → +4
        #expect(nearly(pointData(r, id: 2)!.position, Vector(2, 0)))  // 2 outside → stays
    }

    @Test("polyline: per-vertex — inside vertices move, outside stay, bulges preserved")
    func polylineStretchPerVertex() {
        let pl = EntityRecord(
            id: EntityID(1),
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0), bulge: 0.5),
                PolylineVertex(point: Vector(8, 0), bulge: -0.25),
                PolylineVertex(point: Vector(2, 3), bulge: 0),
            ], closed: true)))
        let def = stretchDef(members: [EntityID(1)])
        let st = InsertDynamicState(parameterValues: ["lp": 12]) // delta +2
        let r = BlockEvaluator.evaluate(def, members: [pl], instanceState: st)
        guard case let .polyline(out) = r.first!.kind else { Issue.record("not polyline"); return }
        #expect(nearly(out.vertices[0].point, Vector(0, 0)))   // outside
        #expect(nearly(out.vertices[1].point, Vector(10, 0)))  // inside → +2
        #expect(nearly(out.vertices[2].point, Vector(2, 3)))   // outside
        #expect(out.vertices[0].bulge == 0.5)                  // bulge preserved
        #expect(out.vertices[1].bulge == -0.25)
        #expect(out.closed)
    }

    @Test("circle: center inside ⇒ whole circle moves; center outside ⇒ unchanged")
    func circleStretchWholeOnCenter() {
        let inMembers = [circle(1, Vector(8, 0), 4)]
        let def = stretchDef(members: [EntityID(1)])
        let st = InsertDynamicState(parameterValues: ["lp": 15]) // delta +5
        let r = BlockEvaluator.evaluate(def, members: inMembers, instanceState: st)
        let c = circleData(r, id: 1)!
        #expect(nearly(c.center, Vector(13, 0)))  // center inside → moved whole
        #expect(c.radius == 4)                    // radius unchanged (no distortion)

        // center outside the frame → unchanged
        let outMembers = [circle(2, Vector(2, 0), 4)]
        let def2 = stretchDef(members: [EntityID(2)])
        let r2 = BlockEvaluator.evaluate(def2, members: outMembers, instanceState: st)
        #expect(nearly(circleData(r2, id: 2)!.center, Vector(2, 0)))
    }

    @Test("arc: center inside ⇒ whole arc moves, angles/radius preserved")
    func arcStretchWholeOnCenter() {
        let arc = EntityRecord(
            id: EntityID(1),
            kind: .arc(ArcData(center: Vector(8, 0), radius: 3,
                               startAngle: 0.1, endAngle: 1.2, reversed: true)))
        let def = stretchDef(members: [EntityID(1)])
        let st = InsertDynamicState(parameterValues: ["lp": 16]) // delta +6
        let r = BlockEvaluator.evaluate(def, members: [arc], instanceState: st)
        guard case let .arc(out) = r.first!.kind else { Issue.record("not arc"); return }
        #expect(nearly(out.center, Vector(14, 0)))
        #expect(out.radius == 3)
        #expect(out.startAngle == 0.1)
        #expect(out.endAngle == 1.2)
        #expect(out.reversed)
    }

    @Test("whole-entity fallback: a text member overlapping the frame moves whole")
    func wholeEntityFallbackText() {
        // Text is not a per-vertex stretch kind ⇒ whole-entity fallback. Its position
        // (8,0) is inside the frame, so the whole text moves by the delta.
        let txt = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: Vector(8, 0), height: 2.5, text: "AB")))
        let def = stretchDef(members: [EntityID(1)])
        let st = InsertDynamicState(parameterValues: ["lp": 11]) // delta +1
        let r = BlockEvaluator.evaluate(def, members: [txt], instanceState: st)
        guard case let .text(out) = r.first!.kind else { Issue.record("not text"); return }
        #expect(out.position.x > 8.5) // moved right (whole-entity fallback)
    }

    @Test("whole-entity fallback: a text fully outside the frame stays put")
    func wholeEntityFallbackTextOutside() {
        // Frame is a tight box well to the right; the text at the origin is fully
        // outside ⇒ no move.
        let txt = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: Vector(0, 0), height: 2.5, text: "AB")))
        let frame = AABB(min: Vector(500, -10), max: Vector(600, 10))
        let def = stretchDef(members: [EntityID(1)], frame: frame)
        let st = InsertDynamicState(parameterValues: ["lp": 100]) // big delta
        let r = BlockEvaluator.evaluate(def, members: [txt], instanceState: st)
        guard case let .text(out) = r.first!.kind else { Issue.record("not text"); return }
        #expect(nearly(out.position, Vector(0, 0)))
    }

    @Test("distanceMultiplier = 2 doubles the applied delta")
    func stretchDistanceMultiplier() {
        let members = [point(1, Vector(8, 0))]
        let def = stretchDef(members: [EntityID(1)], mult: 2)
        let st = InsertDynamicState(parameterValues: ["lp": 13]) // raw delta +3 → ×2 = +6
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        #expect(nearly(pointData(r, id: 1)!.position, Vector(14, 0)))
    }

    @Test("angleOffset rotates the delta direction (+90° turns +x into +y)")
    func stretchAngleOffset() {
        // Param direction is +x; angleOffset = +π/2 rotates the delta to +y.
        let members = [point(1, Vector(8, 0))]
        let def = stretchDef(members: [EntityID(1)], angle: .pi / 2)
        let st = InsertDynamicState(parameterValues: ["lp": 13]) // delta magnitude 3
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        #expect(nearly(pointData(r, id: 1)!.position, Vector(8, 3), 1e-9))
    }

    @Test("base value (and absent value) ⇒ NO change")
    func stretchBaseValueNoChange() {
        let members = [line(1, Vector(0, 0), Vector(10, 0))]
        let def = stretchDef(members: [EntityID(1)])
        // Explicit base distance (10) → zero delta.
        let atBase = BlockEvaluator.evaluate(
            def, members: members, instanceState: InsertDynamicState(parameterValues: ["lp": 10]))
        // No parameter value at all → defaults to the base distance → zero delta.
        let absent = BlockEvaluator.evaluate(def, members: members,
                                             instanceState: InsertDynamicState())
        #expect(nearly(lineData(atBase, id: 1)!.end, Vector(10, 0)))
        #expect(nearly(lineData(absent, id: 1)!.end, Vector(10, 0)))
    }

    @Test("negative delta (shrink) moves an inside endpoint back along the direction")
    func stretchNegativeDelta() {
        let members = [line(1, Vector(0, 0), Vector(10, 0))]
        let def = stretchDef(members: [EntityID(1)])
        let st = InsertDynamicState(parameterValues: ["lp": 7]) // delta -3
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        #expect(nearly(lineData(r, id: 1)!.end, Vector(7, 0)))
    }

    @Test("stretch affects ONLY the action's member subset")
    func stretchAffectsOnlySubset() {
        let members = [point(1, Vector(8, 0)), point(2, Vector(9, 0))]
        let def = stretchDef(members: [EntityID(1)]) // only m1 in the set
        let st = InsertDynamicState(parameterValues: ["lp": 13]) // delta +3
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        #expect(nearly(pointData(r, id: 1)!.position, Vector(11, 0))) // moved
        #expect(nearly(pointData(r, id: 2)!.position, Vector(9, 0)))  // untouched
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Composition: visibility + stretch; multiple actions
    // ─────────────────────────────────────────────────────────────────────────────

    @Test("a visibility state filters first, then a stretch applies to survivors")
    func visibilityThenStretchComposes() {
        // m1, m2 are points; visibility state "On" shows only m1; a stretch then moves
        // m1 (inside the frame). m2 is dropped by visibility — never seen by stretch.
        let members = [point(1, Vector(8, 0)), point(2, Vector(8, 5))]
        let def = DynamicBlockDef(
            visibilityStates: [BlockVisibilityState(name: "On", visibleMemberIDs: [EntityID(1)])],
            parameters: [.linear(id: BlockParameterID("lp"), label: "L",
                                 base: Vector(0, 0), end: Vector(10, 0))],
            actions: [.stretch(id: BlockActionID("sa"), parameterID: BlockParameterID("lp"),
                               stretchFrame: AABB(min: Vector(5, -1e6), max: Vector(1e6, 1e6)),
                               memberIDs: [EntityID(1), EntityID(2)])])
        let st = InsertDynamicState(activeVisibilityState: "On", parameterValues: ["lp": 12])
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        #expect(r.count == 1)                                       // m2 filtered out
        #expect(nearly(pointData(r, id: 1)!.position, Vector(10, 0))) // m1 stretched +2
    }

    @Test("flip then stretch compose in declared order on the same member")
    func flipThenStretchCompose() {
        // Member point at (3,0). Flip about y-axis → (-3,0). Stretch frame is x ≤ -2
        // so the flipped point (-3,0) is inside ⇒ moves by the (negative-x) delta.
        let members = [point(1, Vector(3, 0))]
        let def = DynamicBlockDef(
            parameters: [
                .flip(id: BlockParameterID("fp"), label: "F",
                      lineStart: Vector(0, -1), lineEnd: Vector(0, 1)),
                .linear(id: BlockParameterID("lp"), label: "L",
                        base: Vector(0, 0), end: Vector(10, 0)),
            ],
            actions: [
                .flip(id: BlockActionID("fa"), parameterID: BlockParameterID("fp"),
                      memberIDs: [EntityID(1)]),
                .stretch(id: BlockActionID("sa"), parameterID: BlockParameterID("lp"),
                         stretchFrame: AABB(min: Vector(-1e6, -1e6), max: Vector(-2, 1e6)),
                         memberIDs: [EntityID(1)]),
            ])
        let st = InsertDynamicState(parameterValues: ["lp": 12], flipStates: ["fp": true])
        let r = BlockEvaluator.evaluate(def, members: members, instanceState: st)
        // flip: (3,0)→(-3,0); stretch delta +2 along +x → (-1,0)
        #expect(nearly(pointData(r, id: 1)!.position, Vector(-1, 0)))
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Purity / isolation
    // ─────────────────────────────────────────────────────────────────────────────

    @Test("same block at two instance values yields independent results; source intact")
    func twoInstancesIndependent() {
        let members = [line(1, Vector(0, 0), Vector(10, 0))]
        let def = stretchDef(members: [EntityID(1)])
        let r13 = BlockEvaluator.evaluate(def, members: members,
                                          instanceState: InsertDynamicState(parameterValues: ["lp": 13]))
        let r07 = BlockEvaluator.evaluate(def, members: members,
                                          instanceState: InsertDynamicState(parameterValues: ["lp": 7]))
        #expect(nearly(lineData(r13, id: 1)!.end, Vector(13, 0)))
        #expect(nearly(lineData(r07, id: 1)!.end, Vector(7, 0)))
        // SOURCE members are untouched by either evaluation.
        #expect(nearly(lineData(members, id: 1)!.end, Vector(10, 0)))
    }

    @Test("no stretch/flip params/actions ⇒ members returned exactly as the filter left them")
    func noActionsZeroBehaviorChange() {
        let members = [line(1, Vector(0, 0), Vector(10, 0)), point(2, Vector(5, 5))]
        // A def with only a parameter but NO actions: members unchanged.
        let paramOnly = DynamicBlockDef(parameters: [
            .linear(id: BlockParameterID("lp"), label: "L", base: Vector(0, 0), end: Vector(10, 0))])
        let r = BlockEvaluator.evaluate(paramOnly, members: members,
                                        instanceState: InsertDynamicState(parameterValues: ["lp": 99]))
        #expect(r.count == 2)
        #expect(nearly(lineData(r, id: 1)!.end, Vector(10, 0)))
        #expect(nearly(pointData(r, id: 2)!.position, Vector(5, 5)))
        // An entirely empty def is identical to a plain block.
        let plain = BlockEvaluator.evaluate(DynamicBlockDef(), members: members, instanceState: nil)
        #expect(plain.count == 2)
    }

    @Test("a MINSERT grid of a stretched dynamic insert yields identical cells; source unmutated")
    func minsertStretchCellsIdenticalAndPure() {
        let d = CADDrawing()
        // One line member, minted id, RE-AUTHORED in block-local coords 0→10 along x.
        let memberID = d.add(line(0, Vector(0, 0), Vector(10, 0)))
        let def = DynamicBlockDef(
            parameters: [.linear(id: BlockParameterID("lp"), label: "L",
                                 base: Vector(0, 0), end: Vector(10, 0))],
            actions: [.stretch(id: BlockActionID("sa"), parameterID: BlockParameterID("lp"),
                               stretchFrame: AABB(min: Vector(5, -1e6), max: Vector(1e6, 1e6)),
                               memberIDs: [memberID])])
        d.addBlock(Block(name: "BAR", entityIDs: [memberID], dynamic: def))
        let grid = EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "BAR", insertionPoint: Vector(0, 0),
                                     rows: 2, cols: 2, rowSpacing: 100, colSpacing: 100,
                                     dynamic: InsertDynamicState(parameterValues: ["lp": 15]))))
        let gridID = d.add(grid)
        let geo = d.entity(gridID)!.resolve(d.makeResolveContext())
        // 4 cells × one line each; each stretched line spans 0→15 (length 15) in its cell.
        #expect(geo.polylines.count == 4)
        for pl in geo.polylines {
            let xs = pl.points.map(\.x)
            let span = (xs.max() ?? 0) - (xs.min() ?? 0)
            #expect(abs(span - 15) < 1e-6)
        }
        // The block's source member is untouched (still 0→10) after resolve.
        guard case let .line(src) = d.entity(memberID)!.kind else { Issue.record("not line"); return }
        #expect(nearly(src.end, Vector(10, 0)))
        // Re-resolve is stable.
        #expect(d.entity(gridID)!.resolve(d.makeResolveContext()).polylines.count == 4)
    }

    @Test("resolveInsert drives stretch through the drawing context")
    func resolveInsertHonorsStretch() {
        let d = CADDrawing()
        let memberID = d.add(line(0, Vector(0, 0), Vector(10, 0)))
        let def = DynamicBlockDef(
            parameters: [.linear(id: BlockParameterID("lp"), label: "L",
                                 base: Vector(0, 0), end: Vector(10, 0))],
            actions: [.stretch(id: BlockActionID("sa"), parameterID: BlockParameterID("lp"),
                               stretchFrame: AABB(min: Vector(5, -1e6), max: Vector(1e6, 1e6)),
                               memberIDs: [memberID])])
        d.addBlock(Block(name: "BAR", entityIDs: [memberID], dynamic: def))
        let insert = d.add(EntityRecord(
            id: EntityID(0),
            kind: .insert(InsertData(blockName: "BAR", insertionPoint: Vector(0, 0),
                                     dynamic: InsertDynamicState(parameterValues: ["lp": 14])))))
        let geo = d.entity(insert)!.resolve(d.makeResolveContext())
        #expect(geo.polylines.count == 1)
        let xs = geo.polylines.first!.points.map(\.x)
        #expect(abs(((xs.max() ?? 0) - (xs.min() ?? 0)) - 14) < 1e-6) // span 14 (stretched)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Mutators (CADDrawing authoring, undoable)
    // ─────────────────────────────────────────────────────────────────────────────

    private func testUndoManager() -> UndoManager {
        let um = UndoManager(); um.groupsByEvent = false; return um
    }
    private func grouped(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping(); body(); um.endUndoGrouping()
    }

    @Test("addLinearParameter / addFlipParameter author the block definition; undoable")
    func addParameterMutatorsUndoable() {
        // Seed without the undo manager (the BlockOps pattern), then attach it.
        let d = CADDrawing()
        let mid = d.add(line(0, Vector(0, 0), Vector(10, 0)))
        d.addBlock(Block(name: "BAR", entityIDs: [mid]))
        let um = testUndoManager()
        d.undoManager = um
        grouped(um) {
            #expect(d.addLinearParameter(toBlock: "BAR", id: BlockParameterID("lp"),
                                         label: "L", base: Vector(0, 0), end: Vector(10, 0)))
            #expect(d.addFlipParameter(toBlock: "BAR", id: BlockParameterID("fp"),
                                       label: "F", lineStart: Vector(0, 0), lineEnd: Vector(0, 1)))
        }
        #expect(d.blocks.block(named: "BAR")?.dynamic?.parameters.count == 2)
        // Duplicate id is a no-op.
        #expect(!d.addLinearParameter(toBlock: "BAR", id: BlockParameterID("lp"),
                                      label: "L2", base: Vector(0, 0), end: Vector(5, 0)))
        // Undo reverts both adds (one group).
        um.undo()
        #expect(d.blocks.block(named: "BAR")?.dynamic?.parameters.isEmpty ?? true)
    }

    @Test("addStretchAction / addFlipAction author actions; removeParameter/removeAction undoable")
    func addRemoveActionMutatorsUndoable() {
        // Seed the block + parameters WITHOUT the undo manager, then attach it so the
        // add/remove operations under test register their own undo groups.
        let d = CADDrawing()
        let mid = d.add(line(0, Vector(0, 0), Vector(10, 0)))
        d.addBlock(Block(name: "BAR", entityIDs: [mid]))
        d.addLinearParameter(toBlock: "BAR", id: BlockParameterID("lp"),
                             label: "L", base: Vector(0, 0), end: Vector(10, 0))
        d.addFlipParameter(toBlock: "BAR", id: BlockParameterID("fp"),
                           label: "F", lineStart: Vector(0, 0), lineEnd: Vector(0, 1))
        #expect(d.addStretchAction(toBlock: "BAR", id: BlockActionID("sa"),
                                   parameterID: BlockParameterID("lp"),
                                   frame: AABB(min: Vector(5, -1), max: Vector(15, 1)),
                                   memberIDs: [mid], distanceMultiplier: 2, angleOffset: 0))
        #expect(d.addFlipAction(toBlock: "BAR", id: BlockActionID("fa"),
                                parameterID: BlockParameterID("fp"), memberIDs: [mid]))
        #expect(d.blocks.block(named: "BAR")?.dynamic?.actions.count == 2)
        // Duplicate action id is a no-op.
        #expect(!d.addFlipAction(toBlock: "BAR", id: BlockActionID("fa"),
                                 parameterID: BlockParameterID("fp"), memberIDs: [mid]))

        // Attach the undo manager now, so only the remove operations under test
        // register undo (the seeding above registers nothing).
        let um = testUndoManager()
        d.undoManager = um

        // removeAction undoable.
        grouped(um) { d.removeAction(fromBlock: "BAR", id: BlockActionID("sa")) }
        #expect(d.blocks.block(named: "BAR")?.dynamic?.actions.count == 1)
        um.undo()
        #expect(d.blocks.block(named: "BAR")?.dynamic?.actions.count == 2)

        // removeParameter undoable.
        grouped(um) { d.removeParameter(fromBlock: "BAR", id: BlockParameterID("lp")) }
        #expect(d.blocks.block(named: "BAR")?.dynamic?.parameter(BlockParameterID("lp")) == nil)
        um.undo()
        #expect(d.blocks.block(named: "BAR")?.dynamic?.parameter(BlockParameterID("lp")) != nil)
    }

    @Test("InsertData.dynamic is reachable for the wire-wave to replace instance state")
    func insertDynamicIsReachable() {
        // The wire-wave drives per-instance values by replacing InsertData.dynamic
        // through the entity-edit funnel. Confirm the field is read/write on a record.
        var ins = InsertData(blockName: "BAR", insertionPoint: Vector(0, 0))
        #expect(ins.dynamic == nil)
        ins.dynamic = InsertDynamicState(parameterValues: ["lp": 13], flipStates: ["fp": true])
        #expect(ins.dynamic?.parameterValues["lp"] == 13)
        #expect(ins.dynamic?.flipStates["fp"] == true)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // MARK: - Back-compat Codable
    // ─────────────────────────────────────────────────────────────────────────────

    @Test("DB-1 DynamicBlockDef JSON (visibility only) decodes parameters/actions = []")
    func db1DefDecodesEmptyParamsActions() throws {
        // A DB-1 def: only the `visibilityStates` key — no `parameters`/`actions`.
        let json = """
        {"visibilityStates":[{"id":"00000000-0000-0000-0000-000000000000","name":"A","visibleMemberIDs":[]}]}
        """.data(using: .utf8)!
        let def = try JSONDecoder().decode(DynamicBlockDef.self, from: json)
        #expect(def.visibilityStates.count == 1)
        #expect(def.parameters.isEmpty)
        #expect(def.actions.isEmpty)
    }

    @Test("pre-DB-2 InsertDynamicState JSON (no flipStates) decodes flipStates = [:]")
    func preDB2InstanceStateDecodesEmptyFlip() throws {
        // A pre-DB-2 instance state: activeVisibilityState + parameterValues only.
        let json = """
        {"activeVisibilityState":"B","parameterValues":{"lp":13}}
        """.data(using: .utf8)!
        let st = try JSONDecoder().decode(InsertDynamicState.self, from: json)
        #expect(st.activeVisibilityState == "B")
        #expect(st.parameterValues["lp"] == 13)
        #expect(st.flipStates.isEmpty)
    }

    @Test("a fully-empty InsertDynamicState JSON decodes to all-default")
    func emptyInstanceStateDecodes() throws {
        let st = try JSONDecoder().decode(InsertDynamicState.self,
                                          from: "{}".data(using: .utf8)!)
        #expect(st.activeVisibilityState == nil)
        #expect(st.parameterValues.isEmpty)
        #expect(st.flipStates.isEmpty)
    }

    @Test("DB-2 def round-trips through Codable (linear+flip params, stretch+flip actions)")
    func db2DefRoundTrips() throws {
        let def = DynamicBlockDef(
            visibilityStates: [BlockVisibilityState(name: "On", visibleMemberIDs: [EntityID(1)])],
            parameters: [
                .linear(id: BlockParameterID("lp"), label: "L", base: Vector(0, 0), end: Vector(10, 0)),
                .flip(id: BlockParameterID("fp"), label: "F", lineStart: Vector(0, 0), lineEnd: Vector(0, 1)),
            ],
            actions: [
                .stretch(id: BlockActionID("sa"), parameterID: BlockParameterID("lp"),
                         stretchFrame: AABB(min: Vector(5, -1), max: Vector(15, 1)),
                         memberIDs: [EntityID(1)], distanceMultiplier: 2, angleOffset: 0.5),
                .flip(id: BlockActionID("fa"), parameterID: BlockParameterID("fp"),
                      memberIDs: [EntityID(2)]),
            ])
        let data = try JSONEncoder().encode(def)
        let back = try JSONDecoder().decode(DynamicBlockDef.self, from: data)
        #expect(back == def)
    }

    @Test("AABB stretchFrame round-trips (Codable via the action's encode)")
    func stretchFrameRoundTrips() throws {
        // AABB is Equatable but not Codable on its own surface here — exercise it
        // through the BlockAction Codable path it ships in.
        let action = BlockAction.stretch(
            id: BlockActionID("sa"), parameterID: BlockParameterID("lp"),
            stretchFrame: AABB(min: Vector(1, 2), max: Vector(3, 4)),
            memberIDs: [EntityID(7)], distanceMultiplier: 1.5, angleOffset: -0.25)
        let back = try JSONDecoder().decode(BlockAction.self,
                                            from: try JSONEncoder().encode(action))
        #expect(back == action)
    }
}
