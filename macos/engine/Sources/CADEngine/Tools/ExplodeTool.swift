//
//  ExplodeTool.swift
//  CADEngine
//
//  The EXPLODE modify tool — break a selected POLYLINE into its constituent
//  independent LINE / ARC segments. Ported in spirit from LibreCAD's
//  `RS_ActionModifyExplode` / `RS_Polyline::explode`
//  (librecad/src/lib/engine/rs_polyline.cpp): each polyline edge becomes a free
//  entity — a straight edge → a `.line`, a bulged edge → an `.arc` — inheriting
//  the polyline's layer / pen / flags. The polyline itself is REMOVED and the
//  segments are ADDED, so one polyline becomes N segment entities in a single
//  undoable group.
//
//  Behavior:
//    - empty selection → status nudges "Select a polyline to explode first";
//                        every input is a no-op.
//    - the tool explodes EVERY selected polyline (non-polyline selections are
//                        ignored — they have nothing to explode). For each:
//        * each real inter-vertex segment with bulge ≈ 0 → a `.line` from this
//          vertex to the next;
//        * each segment with a non-zero bulge → an `.arc` whose center / radius /
//          sweep / direction reproduce EXACTLY the curve `Resolve.expandPolyline`
//          tessellates for that bulge (same DXF bulge = tan(¼·includedAngle)
//          convention), so the exploded arc is geometrically identical to the
//          polyline edge it replaced;
//        * a CLOSED polyline additionally emits the implicit CLOSING edge
//          (last vertex → first vertex) as a straight `.line` (the closing edge's
//          bulge is not stored, matching `expandPolyline`'s straight-closing-edge
//          contract).
//      An N-vertex OPEN polyline → N−1 segments; an N-vertex CLOSED polyline →
//      N segments (N−1 real edges + 1 closing edge).
//    - `.commit` (Return) / `.click` → fire the explode.
//    - `.cancel` (Esc) → discard the captured selection, reset, `.finished`.
//
//  The edits are emitted as `.remove(polylineID)` followed by one `.add(segment)`
//  per segment (the brief's "remove + add" form), so the spatial index and
//  selection stay consistent and the whole explode is one undo step.
//
//  PURE (ADR-001 / Tool contract): never touches CADDrawing / Quadtree / GUI. It
//  reads only `ToolContext.selected`, and converts each edge from the polyline's
//  DEFINING data (vertices + bulges) into a `LineData` / `ArcData`, matching the
//  bulge geometry `Resolve.expandPolyline` produces. The app applies the
//  `.remove` + `.add`s (re-minting the added ids) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Polyline::explode).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Explode tool. With one or more polylines selected, break each
/// into independent line/arc segment entities (closed polylines also get their
/// implicit closing edge); the polylines are removed.
public struct ExplodeTool: Tool {

    // MARK: - State

    private var captured: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Explode" }

    public var status: String {
        explodablePolylines().isEmpty && captured.isEmpty
            ? "Select a polyline to explode first"
            : (explodablePolylines().isEmpty
                ? "Select a polyline to explode first"
                : "Press Return to explode the selected polyline(s)")
    }

    /// The live preview: every segment the explode would produce, resolved with
    /// the preview pen. (Geometrically identical to the source polyline edges, so
    /// this mostly re-draws the polyline in the preview style.)
    public var preview: [ResolvedPolyline] {
        segmentKinds().flatMap { kind in
            kind.resolve(pen: .toolPreview, ctx: .default).polylines
        }
    }

    /// A MODIFY tool: reads `context.selected`, then on fire emits, per selected
    /// polyline, a `.remove(id)` plus one `.add` per exploded segment.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .move:
            return .none

        case .value:
            // A typed coordinate doesn't apply to this selection-based tool — ignore.
            return .none

        case .click, .commit:
            return fire()

        case .backspace:
            return .none

        case .cancel:
            reset()
            return .finished
        }
    }

    // MARK: - Fire

    private mutating func fire() -> ToolOutcome {
        let polylines = explodablePolylines()
        guard !polylines.isEmpty else { return .none }

        var edits: [ToolEdit] = []
        for record in polylines {
            guard case .polyline(let d) = record.kind else { continue }
            let kinds = Self.explode(d)
            guard !kinds.isEmpty else { continue }
            // Remove the polyline, then add each segment (inheriting attrs).
            edits.append(.remove(record.id))
            for kind in kinds {
                edits.append(.add(EntityRecord(
                    id: .placeholder,
                    layer: record.layer,
                    pen: record.pen,
                    flags: record.flags,
                    kind: kind
                )))
            }
        }
        reset()
        return edits.isEmpty ? .none : .commit(edits)
    }

    private mutating func reset() {
        captured = []
    }

    // MARK: - Selection helpers

    /// The captured selections that are polylines with at least one real edge.
    private func explodablePolylines() -> [EntityRecord] {
        captured.filter { record in
            if case .polyline(let d) = record.kind { return d.vertices.count >= 2 }
            return false
        }
    }

    /// The exploded segment kinds across all explodable selections — for preview.
    private func segmentKinds() -> [EntityKind] {
        explodablePolylines().flatMap { record -> [EntityKind] in
            guard case .polyline(let d) = record.kind else { return [] }
            return Self.explode(d)
        }
    }

    // MARK: - Explode geometry (pure, self-contained)

    /// Breaks a polyline into its constituent `.line` / `.arc` segment kinds.
    ///
    /// Each real inter-vertex edge `i → i+1` becomes a line (bulge ≈ 0) or an arc
    /// (non-zero bulge) reproducing the exact curve `Resolve.expandPolyline`
    /// tessellates. A closed polyline additionally emits the implicit closing edge
    /// (last → first) as a straight line (its bulge is not stored — matching the
    /// straight-closing-edge contract in `expandPolyline`).
    static func explode(_ d: PolylineData) -> [EntityKind] {
        let verts = d.vertices
        guard verts.count >= 2 else { return [] }

        var out: [EntityKind] = []
        out.reserveCapacity(verts.count)

        // Real inter-vertex edges.
        for i in 0..<(verts.count - 1) {
            out.append(segment(from: verts[i], to: verts[i + 1].point))
        }
        // Implicit closing edge for a closed polyline (straight).
        if d.closed, let first = verts.first, let last = verts.last,
           last.point.distance(to: first.point) > Tolerance.distance {
            out.append(.line(LineData(start: last.point, end: first.point)))
        }
        return out
    }

    /// One polyline edge → a `.line` (zero bulge) or an `.arc` (non-zero bulge).
    /// The arc center / radius / sweep / direction are derived to reproduce the
    /// exact geometry `Resolve.expandPolyline` produces for this bulge.
    static func segment(from a: PolylineVertex, to bPoint: Vector) -> EntityKind {
        if abs(a.bulge) < Tolerance.distance {
            return .line(LineData(start: a.point, end: bPoint))
        }
        guard let arc = arc(from: a.point, to: bPoint, bulge: a.bulge) else {
            // Degenerate (zero-length chord) → fall back to a straight line.
            return .line(LineData(start: a.point, end: bPoint))
        }
        return .arc(arc)
    }

    /// Converts a DXF-bulge edge (start `a`, end `b`, `bulge`) into an `ArcData`
    /// whose resolve (`Tessellation.arcPoints`) matches `Resolve.expandPolyline`'s
    /// bulge tessellation for the same edge.
    ///
    /// Mirrors `expandPolyline`'s center construction exactly:
    ///   included = 4·atan(bulge);  radius = |chord| / (2·sin(included/2)),
    ///   center placed off the chord midpoint by `apexSide · centerSign · apothem`
    ///   along the chord's LEFT normal, where `apexSide = sign(bulge)` and
    ///   `centerSign = −sign(cos(included/2))` (−1 minor arc, +1 major arc).
    /// `expandPolyline` then sweeps `−included` from `(a−center).angle`; an
    /// `ArcData` reproduces that sweep with `startAngle = (a−center).angle`,
    /// `endAngle = (b−center).angle`, and `reversed = (bulge > 0)` (so the signed
    /// travel of `arcPoints` equals `−included`). Returns `nil` for a degenerate
    /// (zero-length) chord.
    static func arc(from a: Vector, to b: Vector, bulge: Double) -> ArcData? {
        let chord = b - a
        let chordLen = chord.magnitude
        guard chordLen > Tolerance.distance else { return nil }

        let included = 4 * atan(bulge)                       // signed sweep magnitude
        let radius = abs(chordLen / (2 * sin(included / 2)))
        let mid = (a + b) * 0.5
        let half = chordLen / 2
        let apothem = (Swift.max(0, radius * radius - half * half)).squareRoot()
        let dir = chord / chordLen
        let leftNormal = Vector(-dir.y, dir.x)
        let apexSide = (bulge >= 0 ? 1.0 : -1.0)
        let centerSign = -copysign(1.0, cos(included / 2))   // -1 minor, +1 major
        let center = mid + leftNormal * (apexSide * centerSign * apothem)

        let startAngle = (a - center).angle
        let endAngle = (b - center).angle
        // expandPolyline sweeps -included; arcPoints' signed travel is -sweepNorm
        // when reversed, +sweepNorm otherwise. -included < 0 ⇔ bulge > 0 ⇒ reversed.
        return ArcData(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            reversed: bulge > 0
        )
    }
}
