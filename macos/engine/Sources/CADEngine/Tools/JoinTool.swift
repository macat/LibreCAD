//
//  JoinTool.swift
//  CADEngine
//
//  The JOIN modify tool — merge a selection of touching / collinear LINES and
//  ARCS into a single POLYLINE. Ported in spirit from LibreCAD's polyline-join /
//  "create polyline from existing entities" family
//  (librecad/src/lib/actions/.../rs_actionpolylineappend* +
//  RS_Modification::createPolyline): a set of open primitives that share
//  endpoints is reordered into one connected chain and emitted as a polyline,
//  with each ARC edge carried as a DXF bulge on its leading vertex.
//
//  Behavior (operates on `context.selected`; falls back to clicked picks):
//    - `.click(p)`     → ADD the nearest joinable LINE / ARC under the pick to the
//                        working set (so the tool also works with no pre-selection,
//                        like LibreCAD's pick-then-join). Repeated clicks accrue
//                        more segments.
//    - `.commit` (Return / double-click) → JOIN the working set (the selection if
//                        non-empty, else the clicked segments): order the segments
//                        by shared endpoints within the gap tolerance, build ONE
//                        `.polyline`, and emit `.add(polyline)` + one `.remove` per
//                        original. A selection that cannot be connected into a
//                        single chain is a NO-OP (no commit; the `status` explains).
//    - `.move`         → preview the joined polyline for the current working set.
//    - `.cancel` (Esc) → discard the working set and finish.
//    - `.backspace`    → drop the last clicked segment from the working set.
//    - `.value`        → ignored (Join's picks are entity-based, not coordinate-typed).
//
//  JOIN algorithm (pure, self-contained):
//    1. Each LINE / ARC contributes one directed EDGE (start point, end point, and
//       — for an arc — the SIGNED sweep that reproduces its geometry).
//    2. ORDERING: greedily grow one chain. Seed it with the first edge; repeatedly
//       find an unused edge whose start OR end coincides (within `gapTolerance`)
//       with one of the chain's two free endpoints, and splice it on (reversing the
//       edge if it joins by its end). If no remaining edge connects, the set is not
//       a single chain → the join fails (no-op).
//    3. CLOSED LOOP: if, once all edges are placed, the chain's two free endpoints
//       coincide (within tolerance), the polyline is marked `closed` and the
//       duplicate closing vertex is dropped (the implicit closing edge carries it).
//    4. ARC → BULGE: each edge becomes the polyline vertex at its START, whose
//       `bulge` is `tan(includedAngle / 4)` for the arc's SIGNED traversal sweep
//       (zero for a line). This is the exact inverse of `ExplodeTool.arc(from:to:
//       bulge:)` / `Resolve.expandPolyline`, so a join→explode (or DXF) round-trips.
//
//  PURE (ADR-001 / Tool contract): never touches CADDrawing / Quadtree / GUI. It
//  reads only the read-only `ToolContext` (`selected` + `nearbyEntities` for the
//  click path) plus the snapped points in `ToolInput`, and computes the chain
//  entirely from each entity's defining data. The app applies the `.add` + `.remove`
//  edits (re-minting the polyline's id, dropping the originals) as one undoable
//  group, inheriting the first original's layer/pen.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Modification::createPolyline /
//  polyline-append actions).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Join tool. Reorders a selection of touching / collinear lines
/// and arcs into one polyline (arc edges carried as bulges); a closed chain
/// becomes a closed polyline. Selections that don't connect into a single chain
/// are left untouched (LibreCAD's create-polyline-from-entities behavior).
public struct JoinTool: Tool {

    // MARK: - Tunables

    /// The world-space distance within which two endpoints are treated as the SAME
    /// point when ordering the chain (the "gap tolerance"). Endpoints closer than
    /// this are spliced together. Default `1e-6` (the app passes its px-derived
    /// value); never below the engine's geometric `Tolerance.distance`.
    private let gapTolerance: Double

    /// The pick aperture used to find a segment under a `.click` (the no-pre-
    /// selection path). World units; default `1e-6`.
    private let pickTolerance: Double

    /// Creates a Join tool. `gapTolerance` is the endpoint-coincidence aperture
    /// used when ordering the chain; `pickTolerance` is the click aperture for the
    /// pick-then-join path. Both default to `1e-6`.
    public init(gapTolerance: Double = 1e-6, pickTolerance: Double = 1e-6) {
        self.gapTolerance = Swift.max(gapTolerance, Tolerance.distance)
        self.pickTolerance = pickTolerance
    }

    // MARK: - Working set (segments accrued via clicks; ignored when a selection exists)

    /// Records picked by `.click` (the no-pre-selection path). Empty when the user
    /// relies on `context.selected`. Ordered by pick; deduped by id.
    private var picked: [EntityRecord] = []

    /// The last cursor point seen via `.move`, used to drive the preview's "would
    /// join" feedback. Not load-bearing for the commit.
    private var cursor: Vector = .invalid

    // MARK: - Tool

    public var title: String { "Join" }

    public var status: String {
        "Select touching lines/arcs, then press Return to join into a polyline"
    }

    /// The live preview: the joined polyline for the current working set (the
    /// picked segments — the app feeds `context.selected` only on `handle`, so the
    /// preview reflects the click path). Empty when fewer than two segments are
    /// accrued or they don't form a single chain.
    public var preview: [ResolvedPolyline] {
        guard picked.count >= 2,
              let data = Self.join(picked.map(\.kind), gapTolerance: gapTolerance)
        else { return [] }
        return EntityKind.polyline(data)
            .resolve(pen: .toolPreview, ctx: .default)
            .polylines
    }

    /// A MODIFY tool: it reads `context.selected` (or its clicked working set) and,
    /// on `.commit`, emits `.add(polyline)` + one `.remove` per joined original.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .value:
            // A typed coordinate doesn't map to Join's entity-pick interaction.
            return .none

        case .move(let p):
            cursor = p
            return .none

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            if picked.isEmpty { return .none }
            picked.removeLast()
            return .none

        case .cancel:
            reset()
            return .finished

        case .commit:
            return handleCommit(context: context)
        }
    }

    // MARK: - Click / commit

    /// Adds the nearest joinable LINE / ARC under the pick to the working set.
    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        cursor = p
        let near = context.nearbyEntities(p, pickTolerance)
            .filter { Self.isJoinable($0.kind) }
        guard let target = near.min(by: {
            HitTesting.worldDistance(from: p, to: $0) < HitTesting.worldDistance(from: p, to: $1)
        }) else { return .none }
        // Dedupe by id (a second click on the same entity doesn't double-add it).
        if !picked.contains(where: { $0.id == target.id }) {
            picked.append(target)
        }
        return .none
    }

    /// Joins the working set: the selection if non-empty, otherwise the clicked
    /// segments. Emits `.add(polyline)` + one `.remove` per original, or NO-OP if
    /// the set doesn't connect into a single chain.
    private mutating func handleCommit(context: ToolContext) -> ToolOutcome {
        let sources: [EntityRecord] = {
            let selected = context.selected.filter { Self.isJoinable($0.kind) }
            return selected.isEmpty ? picked : selected
        }()
        // Need at least two joinable segments to form a polyline.
        guard sources.count >= 2,
              let data = Self.join(sources.map(\.kind), gapTolerance: gapTolerance)
        else {
            // Non-connectable selection (or too few segments): no commit — the
            // status already tells the user to pick touching segments.
            return .none
        }

        // Inherit the first source's common attributes; strip `.selected` (§7.6).
        let template = sources[0]
        var flags = template.flags
        flags.remove(.selected)
        let polyline = EntityRecord(
            id: .placeholder,
            layer: template.layer,
            pen: template.pen,
            flags: flags,
            kind: .polyline(data)
        )

        var edits: [ToolEdit] = [.add(polyline)]
        edits.append(contentsOf: sources.map { .remove($0.id) })
        reset()
        return .commit(edits)
    }

    private mutating func reset() {
        picked.removeAll(keepingCapacity: false)
        cursor = .invalid
    }

    /// Whether `kind` is a segment Join can chain (an open LINE or ARC).
    static func isJoinable(_ kind: EntityKind) -> Bool {
        switch kind {
        case .line, .arc:
            return true
        // TODO(backlog): join open polylines (concatenate their vertices) and
        // circles/ellipses (only meaningful when split into arcs first).
        case .polyline, .circle, .ellipse, .spline, .splinePoints, .point,
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .multileader, .image, .wipeout, .mline:
            return false
        }
    }

    // MARK: - Join algorithm (pure, self-contained)

    /// One directed segment in the chain: its endpoints in travel order plus the
    /// SIGNED sweep (radians) of an arc edge (`0` for a straight line). Reversing
    /// the edge swaps `start`/`end` and negates `sweep`.
    struct Edge {
        var start: Vector
        var end: Vector
        /// Signed traversal sweep (positive == CCW, negative == CW); `0` for a line.
        var sweep: Double

        /// The DXF bulge for this edge's leading vertex: `tan(includedAngle / 4)`
        /// where the included angle is the signed sweep. Zero for a straight edge.
        /// This is the exact inverse of `ExplodeTool.arc`/`Resolve.expandPolyline`:
        /// there `expandPolyline` sweeps `-4·atan(bulge)`, so to reproduce a signed
        /// travel of `sweep` we need `bulge = -tan(sweep / 4)`.
        var bulge: Double {
            abs(sweep) < Tolerance.angle ? 0 : -tan(sweep / 4)
        }

        /// The same edge traversed in the opposite direction.
        var reversed: Edge { Edge(start: end, end: start, sweep: -sweep) }
    }

    /// Builds the directed `Edge` for a joinable kind, or `nil` for a degenerate
    /// (zero-length) one.
    static func edge(for kind: EntityKind) -> Edge? {
        switch kind {
        case .line(let d):
            guard d.start.distance(to: d.end) > Tolerance.distance else { return nil }
            return Edge(start: d.start, end: d.end, sweep: 0)
        case .arc(let d):
            guard d.radius > Tolerance.distance else { return nil }
            let s = d.center + Vector.polar(radius: d.radius, angle: d.startAngle)
            let e = d.center + Vector.polar(radius: d.radius, angle: d.endAngle)
            return Edge(start: s, end: e, sweep: signedSweep(d))
        default:
            return nil
        }
    }

    /// The signed traversal sweep (radians) of an arc, matching the direction
    /// `Tessellation.arcPoints` walks: the magnitude is the normalized sweep into
    /// `(0, 2π]`, negated when the arc is `reversed` (CW). Equals `arcPoints`'
    /// `(reversed ? -sweep : sweep)`.
    static func signedSweep(_ d: ArcData) -> Double {
        let twoPi = 2 * Double.pi
        var mag = (d.reversed ? d.startAngle - d.endAngle : d.endAngle - d.startAngle)
            .truncatingRemainder(dividingBy: twoPi)
        if mag <= Tolerance.angle { mag += twoPi }
        return d.reversed ? -mag : mag
    }

    /// Orders `kinds` into a single connected chain and returns the joined
    /// `PolylineData`, or `nil` if they don't all link into one chain (the no-op
    /// case). A chain whose two free ends coincide becomes a CLOSED polyline.
    ///
    /// Greedy splice: seed with the first edge, then repeatedly attach any unused
    /// edge that touches a free endpoint (reversing it to match direction). Two
    /// collinear touching lines → a 2-vertex polyline; an L of two lines → a
    /// 3-vertex polyline; a line+arc chain → a polyline with a bulge segment.
    static func join(_ kinds: [EntityKind], gapTolerance: Double) -> PolylineData? {
        let tol = Swift.max(gapTolerance, Tolerance.distance)
        var edges = kinds.compactMap(edge(for:))
        guard edges.count >= 2 else { return nil }

        // Seed the chain with the first edge; track which remain.
        var chain: [Edge] = [edges.removeFirst()]

        // Grow the chain until no remaining edge connects to a free end.
        var progressed = true
        while progressed, !edges.isEmpty {
            progressed = false
            let head = chain.first!.start
            let tail = chain.last!.end

            for i in edges.indices {
                let e = edges[i]
                // Attach to the TAIL (chain end → edge start, reversing if needed).
                if e.start.distance(to: tail) <= tol {
                    chain.append(e); edges.remove(at: i); progressed = true; break
                }
                if e.end.distance(to: tail) <= tol {
                    chain.append(e.reversed); edges.remove(at: i); progressed = true; break
                }
                // Attach to the HEAD (edge end → chain start, reversing if needed).
                if e.end.distance(to: head) <= tol {
                    chain.insert(e, at: 0); edges.remove(at: i); progressed = true; break
                }
                if e.start.distance(to: head) <= tol {
                    chain.insert(e.reversed, at: 0); edges.remove(at: i); progressed = true; break
                }
            }
        }

        // Every edge must have linked into ONE chain, else the set isn't joinable.
        guard edges.isEmpty else { return nil }

        return polyline(from: mergeCollinear(chain, gapTolerance: tol), gapTolerance: tol)
    }

    /// Merges runs of consecutive COLLINEAR straight edges into one edge, so two
    /// collinear touching lines collapse to a single segment (the brief's "collinear
    /// lines merge"). A pair `(a→b), (b→c)` merges into `(a→c)` when BOTH are
    /// straight (zero bulge) and `b` lies on the line `a→c` within `gapTolerance`
    /// (the cross-product/perp distance is negligible AND `b` is between the ends).
    /// Arc edges and direction changes break the run (an L of two lines keeps its
    /// corner vertex). The chain order is preserved.
    static func mergeCollinear(_ chain: [Edge], gapTolerance: Double) -> [Edge] {
        guard chain.count >= 2 else { return chain }
        var out: [Edge] = []
        out.reserveCapacity(chain.count)
        for e in chain {
            if let prev = out.last,
               abs(prev.sweep) < Tolerance.angle, abs(e.sweep) < Tolerance.angle,
               isCollinear(prev.start, prev.end, e.end, tolerance: gapTolerance) {
                // Extend the previous straight edge through the merged endpoint.
                out[out.count - 1] = Edge(start: prev.start, end: e.end, sweep: 0)
            } else {
                out.append(e)
            }
        }
        return out
    }

    /// Whether the directed run `a → b → c` is collinear and forward-going: `b`'s
    /// perpendicular distance from line `a→c` is within `tolerance` AND the two
    /// sub-vectors point the same way (so a fold-back `a → b → a` is NOT merged).
    static func isCollinear(_ a: Vector, _ b: Vector, _ c: Vector, tolerance: Double) -> Bool {
        let ac = c - a
        let ab = b - a
        let lenAC = ac.magnitude
        guard lenAC > Tolerance.distance else { return false }
        // Perpendicular distance of b from the infinite line through a,c.
        let cross = abs(ab.x * ac.y - ab.y * ac.x) / lenAC
        guard cross <= tolerance else { return false }
        // Same direction and b is not past c (forward, between the ends).
        let t = ab.dot(ac) / (lenAC * lenAC)
        return t >= -Tolerance.distance && t <= 1 + Tolerance.distance
    }

    /// Converts an ordered, connected `chain` of edges into `PolylineData`: each
    /// edge contributes its START vertex carrying that edge's bulge; the final
    /// edge's END is appended as the last vertex. If the chain's first and last
    /// points coincide (within `gapTolerance`) the polyline is CLOSED and the
    /// duplicate closing vertex is dropped (its leading edge's bulge moves onto the
    /// existing first/last vertex as the implicit closing edge).
    static func polyline(from chain: [Edge], gapTolerance: Double) -> PolylineData? {
        guard !chain.isEmpty else { return nil }

        let isClosed = chain.first!.start.distance(to: chain.last!.end) <= gapTolerance

        var vertices: [PolylineVertex] = []
        vertices.reserveCapacity(chain.count + 1)
        for e in chain {
            vertices.append(PolylineVertex(point: e.start, bulge: e.bulge))
        }

        if isClosed {
            // The closing edge's bulge already lives on the last chain vertex; the
            // wrap segment back to vertex 0 carries it (DXF closed-polyline order).
            // Do NOT append the duplicate endpoint.
            guard vertices.count >= 2 else { return nil }
            return PolylineData(vertices: vertices, closed: true)
        } else {
            // Open chain: append the terminal endpoint (zero bulge — no segment
            // leaves it).
            vertices.append(PolylineVertex(point: chain.last!.end, bulge: 0))
            guard vertices.count >= 2 else { return nil }
            return PolylineData(vertices: vertices, closed: false)
        }
    }
}
