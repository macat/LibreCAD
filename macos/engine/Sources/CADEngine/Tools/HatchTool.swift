//
//  HatchTool.swift
//  CADEngine
//
//  The HATCH tool — fill a region bounded by the SELECTED boundary entities.
//  Ported in spirit from LibreCAD's `RS_ActionDrawHatch`
//  (librecad/src/actions/drawing/draw/rs_actiondrawhatch.cpp), but in the
//  decision already made for this port: the user SELECTS the closed boundary
//  geometry first (a circle, a closed polyline, or a closed chain of lines/arcs),
//  then activating Hatch fills inside those boundaries. (Seed-point flood fill is
//  a later follow-up — NOT this tool.)
//
//  Behavior (build a `.hatch` from the current selection):
//    - empty / unusable selection → status nudges the user to select a closed
//      boundary; every input is a no-op (nothing committed).
//    - `.commit` (activation: Return / activating the tool with a selection) →
//      build `HatchData.loops` from the captured boundary entities and emit ONE
//      `.add` of a `.hatch` EntityRecord on the active layer. The originals are
//      left untouched. The tool then RESETS and reports `.finished`.
//    - `.click` → same as activation: if a usable boundary is captured, commit the
//      hatch; otherwise a no-op (there is no point-picking phase in this tool — the
//      boundary IS the selection).
//    - `.move`  → no preview geometry is computed (the boundary is fixed); no-op.
//    - `.cancel` (Esc) → discard the captured selection; finish.
//    - `.backspace` → nothing to step back; no-op.
//
//  ## How boundaries become hatch loops
//  Each selected entity is reduced to oriented point chains, then assembled into
//  closed rings (`loops`), each an ordered `[PolylineVertex]` ring NOT repeating
//  its first vertex (matching `ResolvedFill`'s FROZEN loop contract):
//    - circle           → a tessellated closed ring (one loop on its own).
//    - closed polyline  → its vertices used directly as a ring (bulge preserved
//                         for round-trip; the resolve treats bulge as straight).
//    - line / arc / open polyline → OPEN edges that are joined end-to-end (shared
//                         endpoints within `Tolerance` of the engine) into one or
//                         more closed chains; each closed chain is a loop (arcs
//                         tessellated to points). A chain that does not close is
//                         dropped (it can't bound a fill).
//  Loops are then winding-normalized to the `ResolvedFill` contract: the LARGEST
//  loop (by |signed area|) is the outer boundary (CCW); every other loop is a hole
//  (CW). If no usable loop results, nothing is committed.
//
//  Solid fill by default (`patternName == "SOLID"`, `solidFill == true`). A tool
//  configured with a pattern (`init(patternName:scale:angle:)` or by setting
//  `fill`) instead emits a NON-solid `.hatch` carrying that `patternName` /
//  `patternScale` / `patternAngle`; the resolve arm draws the bundled `.pat`
//  pattern's clipped lines (an unknown name falls back to solid there).
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` and returns the `.add` edit;
//  the app applies it (re-minting the id) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawHatch).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Hatch tool. With closed boundary geometry selected, activating
/// the tool fills the bounded region: it builds `HatchData` loops from the
/// selection and commits one `.hatch` entity on the active layer (originals stay).
public struct HatchTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. Hatch has a SINGLE action (build the fill from the
    /// captured selection), so there is one waiting state; the selection is
    /// captured the first time a non-empty `context.selected` is seen.
    private enum State: Equatable {
        /// Waiting for the activation (a `.commit`/`.click`) that builds the fill.
        case waitingToFill
    }

    /// The current state. There is only one — kept as an `enum` (not a flag) to
    /// match the rest of the tool family and stay exhaustive if states are added.
    private var state: State = .waitingToFill

    /// The selection captured the first time a non-empty `context.selected` is
    /// seen, so the status / commit operate on a stable set even though the live
    /// `context.selected` is rebuilt per call. Empty until then.
    private var captured: [EntityRecord] = []

    /// The endpoint-join tolerance for chaining open edges into closed rings, in
    /// world units. Looser than the raw engine `Tolerance.distance` (1e-10) so
    /// hand-snapped boundaries (whose shared corners agree to ~snap precision, not
    /// to 10 decimals) still chain. Kept private; not user-tunable.
    static let joinTolerance = 1.0e-6

    // MARK: - Pattern configuration (the picker the wire-wave drives)

    /// The fill the committed `.hatch` is given. `.solid` is the back-compatible
    /// default (a solid fill — the prior behavior). `.pattern(name:scale:angle:)`
    /// asks for a named `.pat` pattern (e.g. `"ANSI31"`); the resolve arm draws
    /// its clipped pattern lines, and an unknown name falls back to solid there.
    public enum Fill: Equatable, Sendable {
        /// A solid fill (`solidFill == true`, `patternName == "SOLID"`).
        case solid
        /// A named pattern fill (`solidFill == false`) with the per-hatch
        /// `patternScale` (DXF code 41) and `patternAngle` (DXF code 52, radians).
        case pattern(name: String, scale: Double, angle: Double)
        /// A GRADIENT fill — the committed hatch carries this `HatchGradient` (render
        /// support lands in a later wave). Built as a solid hatch (`solidFill ==
        /// true`, `patternName == "SOLID"`) whose `gradient` field is set, so a
        /// gradient-unaware path still draws a plausible solid (the resolve arm
        /// supersedes the solid with the gradient when it gains gradient support).
        case gradient(HatchGradient)
    }

    /// The fill the next committed hatch is given. Settable so the picker (wired
    /// later) can flip a live tool between solid and a chosen pattern without
    /// re-creating it. Defaults to `.solid` for back-compat.
    public var fill: Fill = .solid

    /// The default Hatch tool: a SOLID fill (unchanged behavior — existing
    /// callers and tests keep getting `solidFill: true, patternName: "SOLID"`).
    public init() {}

    /// A Hatch tool pre-configured to fill with a named `.pat` pattern.
    ///
    /// - `patternName`: the pattern to fill with (case-insensitive; resolved
    ///   against the bundled `.pat` library at draw time). An unknown name still
    ///   commits a `.hatch` — the resolve arm falls back to a solid fill.
    /// - `scale`: the per-hatch pattern scale (DXF code 41); `<= 0`/non-finite is
    ///   normalized to `1` so the hatch always resolves.
    /// - `angle`: an EXTRA rotation applied to the pattern, in radians (code 52).
    ///
    /// Passing `patternName == "SOLID"` (case-insensitive) configures a solid
    /// fill, matching the resolve arm's "SOLID ⇒ no pattern" rule.
    public init(patternName: String, scale: Double = 1, angle: Double = 0) {
        if patternName.uppercased() == "SOLID" {
            self.fill = .solid
        } else {
            let s = (scale.isFinite && scale > 0) ? scale : 1
            self.fill = .pattern(name: patternName, scale: s, angle: angle)
        }
    }

    /// A Hatch tool pre-configured to fill the selected boundary with a GRADIENT.
    /// The committed hatch is a solid hatch carrying the supplied `HatchGradient`
    /// (render support lands later; the resolve arm carries it onto `ResolvedFill`).
    public init(gradient: HatchGradient) {
        self.fill = .gradient(gradient)
    }

    // MARK: - Tool

    public var title: String { "Hatch" }

    public var status: String {
        if captured.isEmpty {
            return "Select closed boundary entities to hatch first"
        }
        // A captured selection may still not form a usable boundary (e.g. only
        // open edges that don't close); nudge accordingly.
        return Self.buildLoops(captured).isEmpty
            ? "Selection is not a closed boundary — select a circle, closed polyline, or closed chain"
            : "Press Enter to fill the selected boundary"
    }

    /// Hatch has no rubber-band: the boundary is the (fixed) selection, so there
    /// is nothing to preview as the cursor moves.
    public var preview: [ResolvedPolyline] { [] }

    /// A MODIFY/DRAW hybrid: it reads `context.selected` to capture the boundary
    /// set, then on activation emits one `.add` of a `.hatch` (originals stay). It
    /// never `.replace`s or `.remove`s.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        // Capture the selection the first time we see a non-empty one, so the
        // status / commit act on a stable set for this run.
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .move:
            // No preview geometry; a move never changes anything.
            return .none

        case .value:
            // A typed coordinate doesn't apply to this selection-based tool — ignore.
            return .none

        case .click, .commit:
            // Both activate the fill (there is no point-picking phase here).
            return commitFill()

        case .backspace:
            // Nothing picked within this single-shot action; no-op.
            return .none

        case .cancel:
            // Esc — discard the captured selection and finish.
            reset()
            return .finished
        }
    }

    // MARK: - Fill (build the hatch from the captured boundary)

    /// Builds the hatch loops from the captured selection and, if a usable
    /// boundary results, emits one `.add` of a `.hatch` on the active layer —
    /// solid or the configured `.pattern`. Commits nothing for an empty / open /
    /// degenerate selection.
    private mutating func commitFill() -> ToolOutcome {
        guard !captured.isEmpty else { return .none }   // status nudges to select

        let loops = Self.buildLoops(captured)
        guard !loops.isEmpty else {
            // Selection isn't a usable closed boundary — no-op (status explains).
            return .none
        }

        // Inherit the layer/pen of the first boundary entity so the hatch lands on
        // the active layer the user was working on (LibreCAD drops the hatch on the
        // current layer; the boundary's layer is the closest pure-tool proxy for
        // "active layer" without GUI access).
        let template = captured[0]
        let hatch: HatchData
        switch fill {
        case .solid:
            hatch = HatchData(loops: loops, solidFill: true, patternName: "SOLID")
        case .pattern(let name, let scale, let angle):
            hatch = HatchData(loops: loops, solidFill: false, patternName: name,
                              patternScale: scale, patternAngle: angle)
        case .gradient(let g):
            // A gradient fill: a solid hatch carrying the gradient descriptor.
            hatch = HatchData(loops: loops, solidFill: true, patternName: "SOLID",
                              gradient: g)
        }
        let record = EntityRecord(
            id: .placeholder,
            layer: template.layer,
            pen: template.pen,
            flags: template.flags,
            kind: .hatch(hatch)
        )

        reset()
        return .commit([.add(record)])
    }

    /// Returns to the initial waiting state and drops the captured selection.
    private mutating func reset() {
        state = .waitingToFill
        captured = []
    }

    // MARK: - Boundary → loops (PURE, self-contained)

    /// Builds the winding-normalized hatch loops from a set of boundary entities,
    /// or `[]` if none of them (and no chain of them) forms a usable closed ring.
    ///
    /// Self-closed entities (circle / closed polyline) each become their own loop;
    /// open edges (line / arc / open polyline) are joined end-to-end into closed
    /// chains, each of which becomes a loop. The result is normalized to the
    /// `ResolvedFill` contract: the largest loop (by |signed area|) is the outer
    /// boundary (CCW), the rest are holes (CW).
    static func buildLoops(_ records: [EntityRecord]) -> [[PolylineVertex]] {
        var loops: [[PolylineVertex]] = []
        var openEdges: [[Vector]] = []

        for record in records {
            switch record.kind {
            case .circle(let d):
                // A circle is a closed ring on its own.
                let ring = Tessellation.circlePoints(
                    center: d.center, radius: d.radius, tolerance: defaultTolerance)
                if ring.count >= 3 { loops.append(ring.map { PolylineVertex(point: $0) }) }

            case .polyline(let d) where d.closed:
                // A closed polyline is a ring directly — keep its vertices (bulge
                // carried for round-trip; the resolve treats bulge as straight).
                let ring = dedupRing(d.vertices)
                if ring.count >= 3 { loops.append(ring) }

            case .arc(let d):
                // An arc is an open edge; tessellate it to a point chain.
                let pts = Tessellation.arcPoints(
                    center: d.center, radius: d.radius,
                    startAngle: d.startAngle, endAngle: d.endAngle,
                    reversed: d.reversed, tolerance: defaultTolerance)
                if pts.count >= 2 { openEdges.append(pts) }

            case .line(let d):
                openEdges.append([d.start, d.end])

            case .polyline(let d):
                // An OPEN polyline is an open edge: its expanded point chain.
                let pts = EntityKind.expandPolyline(d, ctx: .default)
                if pts.count >= 2 { openEdges.append(pts) }

            // Unsupported boundary kinds are skipped (no loop contributed). Ellipse
            // / spline boundaries are a backlog widening; text / hatch / solid /
            // dimension / insert / point / leader can't bound a fill.
            case .ellipse, .spline, .splinePoints, .text, .mtext,
                 .hatch, .solid, .dimension, .point, .insert, .xline, .ray, .leader,
                 .multileader, .image, .wipeout:
                continue
            }
        }

        // Assemble the open edges into closed chains; each becomes a loop.
        loops.append(contentsOf: chainClosedLoops(openEdges))

        guard !loops.isEmpty else { return [] }
        return normalizeWinding(loops)
    }

    /// The tessellation tolerance boundary curves are sampled at (world units).
    /// Matches `ResolveContext.default`'s 0.05 so a hatch's stored boundary and
    /// its rendered fill agree.
    static let defaultTolerance = 0.05

    /// Drops a duplicated closing vertex (first ≈ last) so a ring follows the
    /// `ResolvedFill` "no repeated first vertex" convention.
    private static func dedupRing(_ verts: [PolylineVertex]) -> [PolylineVertex] {
        guard verts.count >= 2,
              let first = verts.first, let last = verts.last,
              first.point.distance(to: last.point) < joinTolerance
        else { return verts }
        return Array(verts.dropLast())
    }

    /// Joins open edges (each an ordered point chain) end-to-end into closed
    /// rings, matching shared endpoints within `joinTolerance`. Returns one
    /// `[PolylineVertex]` ring per closed chain found; open (non-closing) chains
    /// are dropped (they can't bound a fill).
    ///
    /// Greedy nearest-endpoint walk: start an unused edge, then repeatedly append
    /// the unused edge whose either endpoint meets the current chain's tail
    /// (flipping it as needed), until the chain returns to its start (closed) or no
    /// edge connects (dropped).
    private static func chainClosedLoops(_ edges: [[Vector]]) -> [[PolylineVertex]] {
        guard !edges.isEmpty else { return [] }
        var used = [Bool](repeating: false, count: edges.count)
        var rings: [[PolylineVertex]] = []

        for seed in edges.indices where !used[seed] {
            used[seed] = true
            var chain: [Vector] = edges[seed]
            guard let start = chain.first else { continue }

            // Extend from the tail until the chain closes or no edge connects.
            extend: while true {
                guard let tail = chain.last else { break }
                // Closed once the tail returns to the chain's start (and we have a
                // real ring, not a single still-open edge whose ends coincide).
                if chain.count >= 3, tail.distance(to: start) < joinTolerance {
                    break
                }
                for j in edges.indices where !used[j] {
                    let edge = edges[j]
                    guard let head = edge.first, let last = edge.last else { continue }
                    if tail.distance(to: head) < joinTolerance {
                        used[j] = true
                        chain.append(contentsOf: edge.dropFirst())
                        continue extend
                    }
                    if tail.distance(to: last) < joinTolerance {
                        used[j] = true
                        chain.append(contentsOf: edge.dropLast().reversed())
                        continue extend
                    }
                }
                // No edge connects to the tail — this chain can't be closed.
                break
            }

            // Keep only a chain that closed back to its start. Drop the duplicated
            // closing point so the ring follows the no-repeated-vertex convention.
            guard let tail = chain.last, chain.count >= 4,
                  tail.distance(to: start) < joinTolerance
            else { continue }
            let ring = Array(chain.dropLast())
            if ring.count >= 3 {
                rings.append(ring.map { PolylineVertex(point: $0) })
            }
        }
        return rings
    }

    /// Normalizes loop winding to the `ResolvedFill` contract: the loop with the
    /// largest |signed area| is the OUTER boundary and is oriented CCW (positive
    /// signed area); every other loop is a hole oriented CW (negative). Loops are
    /// reordered so the outer boundary is `loops[0]`.
    private static func normalizeWinding(_ loops: [[PolylineVertex]]) -> [[PolylineVertex]] {
        guard !loops.isEmpty else { return [] }

        // Pair each loop with its signed area; the biggest |area| is the outer.
        let withArea = loops.map { (loop: $0, area: signedArea($0)) }
        guard let outerIndex = withArea.indices.max(by: {
            abs(withArea[$0].area) < abs(withArea[$1].area)
        }) else { return loops }

        var out: [[PolylineVertex]] = []
        out.reserveCapacity(loops.count)
        // Outer first (CCW), then the rest (CW), preserving the input order of the
        // remaining loops.
        out.append(oriented(withArea[outerIndex].loop, ccw: true, area: withArea[outerIndex].area))
        for i in withArea.indices where i != outerIndex {
            out.append(oriented(withArea[i].loop, ccw: false, area: withArea[i].area))
        }
        return out
    }

    /// The signed area of a ring (shoelace; CCW positive). The ring must NOT repeat
    /// its first vertex (the closing edge is implicit), matching the loop contract.
    private static func signedArea(_ loop: [PolylineVertex]) -> Double {
        let n = loop.count
        guard n >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<n {
            let a = loop[i].point
            let b = loop[(i + 1) % n].point
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2.0
    }

    /// Returns `loop` oriented CCW (`ccw == true`) or CW, reversing it iff its
    /// current `area` sign disagrees with the requested winding. Reversal preserves
    /// the ring as a set of vertices (no bulge re-association needed because the
    /// resolve treats stored boundary bulges as straight).
    private static func oriented(_ loop: [PolylineVertex], ccw: Bool, area: Double) -> [PolylineVertex] {
        let isCCW = area > 0
        if isCCW == ccw { return loop }
        return loop.reversed()
    }
}
