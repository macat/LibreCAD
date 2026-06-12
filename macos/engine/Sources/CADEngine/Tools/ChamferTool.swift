//
//  ChamferTool.swift
//  CADEngine
//
//  The CHAMFER (bevel) editing tool — pick two LINES and replace their corner
//  with a straight bevel segment, trimming each line back to the bevel's
//  endpoints. Ported in spirit from LibreCAD's `RS_ActionModifyBevel` /
//  `RS_Modification::bevel` (librecad/src/actions/drawing/modify/
//  rs_actionmodifybevel.cpp + librecad/src/lib/modification/rs_modification.cpp),
//  distilled to the two-click "pick line, pick line" interaction this app uses.
//
//  Behavior (two clicks — no pre-selection needed):
//    1. click #1 picks the FIRST line (nearest LINE under the pick in
//       `nearbyEntities`); click #2 picks the SECOND line.
//    2. The CORNER is the (infinite-line) intersection of the two lines
//       (`Intersections.lineLine(..., segment: false)`); parallel lines have no
//       intersection → no-op.
//    3. `P1` is the point on line1 at `distance1` from the corner, measured back
//       toward the PICK side of line1; `P2` likewise on line2 at `distance2`.
//       (Matches LibreCAD's `getTrimPoint` → `getNearestDist`: the corner-end of
//       each line is the endpoint NEAREST the corner / on the pick side, and the
//       bevel point sits `distance` from the corner along the line into the body.)
//    4. The tool emits `.commit([` two `.replace`s + one `.add` `])`:
//         - `.replace(firstID,  line1 trimmed so its corner-end → P1)`
//         - `.replace(secondID, line2 trimmed so its corner-end → P2)`
//         - `.add(EntityRecord(id: .placeholder, layer/pen from the FIRST line,
//                 kind: .line(LineData(start: P1, end: P2))))`  — the bevel line.
//    5. Degenerate cases (parallel, a distance longer than the line, coincident
//       lines, no LINE under a pick) are a no-op (`.none`).
//
//  SCOPE: line–line only. A non-LINE pick (circle/arc/ellipse/text/…) is ignored
//  (`.none`); `// TODO(backlog)` covers arc/polyline bevels.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext` boundary hook (`nearbyEntities`) plus
//  the snapped world points in `ToolInput`, and computes the bevel entirely
//  through the shared `Intersections` kernel + `Vector` math. The app applies the
//  two `.replace` (preserving each line's id / layer / pen / flags) and the one
//  `.add` (re-minting the bevel's id) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyBevel / bevel math).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Chamfer tool. Click two LINES to bevel their corner: the
/// corner is replaced by a straight segment, and each line is trimmed back to the
/// bevel's endpoint (LibreCAD's modify-bevel, two-pick form, line–line scope).
public struct ChamferTool: Tool {

    // MARK: - Configuration (equal-distance default; UI is backlog)

    /// Distance from the corner along the FIRST line to the bevel's endpoint P1.
    public var distance1: Double = 10.0
    /// Distance from the corner along the SECOND line to the bevel's endpoint P2.
    public var distance2: Double = 10.0
    // TODO(backlog): distance input UI (per-distance fields; equal-distance is the
    // default LibreCAD presents, so 10/10 here mirrors that out-of-the-box state).

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionModifyBevel`'s status integers
    /// (pick first line → pick second line) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the click on the FIRST line.
        case pickingFirst
        /// First line fixed; waiting for the SECOND line. `first` is the record the
        /// bevel is measured from (its layer/pen are inherited by the bevel line).
        case pickingSecond(first: EntityRecord)
    }

    /// The current state. Starts waiting for the first line.
    private var state: State = .pickingFirst

    /// The point picked when the FIRST line was chosen, kept so the bevel geometry
    /// knows which side of the first line the user clicked (the corner-end side).
    private var firstPick: Vector = .invalid

    /// The last cursor point seen via `.move`, used to drive the live preview of
    /// the trimmed lines + bevel while the second line is being chosen.
    private var cursor: Vector = .invalid

    public init() {}

    // MARK: - Tool

    public var title: String { "Chamfer" }

    public var status: String {
        switch state {
        case .pickingFirst:
            return "Select first line"
        case .pickingSecond:
            return "Select second line"
        }
    }

    /// The live preview: once the first line is fixed, if the cursor is over a
    /// second LINE whose corner with the first can be beveled, show the two
    /// TRIMMED lines + the bevel segment with the preview pen. Empty otherwise.
    public var preview: [ResolvedPolyline] {
        guard case .pickingSecond(let first) = state,
              cursor.valid,
              let bevel = Self.bevel(first: first, firstPick: firstPick,
                                     secondPick: cursor, distance1: distance1,
                                     distance2: distance2, context: previewContext)
        else {
            return []
        }
        // The trimmed lines + the bevel line, all recolored with the preview pen.
        let kinds: [EntityKind] = [
            .line(bevel.line1),
            .line(bevel.line2),
            .line(LineData(start: bevel.p1, end: bevel.p2)),
        ]
        return kinds.flatMap {
            $0.resolve(pen: .toolPreview, ctx: .default).polylines
        }
    }

    /// The context captured on the last `.move`, so `preview` (which gets no
    /// `ToolContext`) can re-resolve the second line under the cursor. Nil before
    /// any move in the second-pick state.
    private var previewContext: ToolContext = .empty

    /// A MODIFY/ADD editing tool: it reads the boundary hook (`nearbyEntities`),
    /// and on the second click emits two `.replace` (trim each line) + one `.add`
    /// (the bevel line) as a single undoable group.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            previewContext = context
            // A move only matters once the first line is fixed AND a bevel is
            // computable under the cursor.
            guard case .pickingSecond = state else { return .none }
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — Chamfer completes on its second click, so there's nothing
            // pending here; just end the run.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .pickingFirst:
            // Need a LINE under the click to start; otherwise ignore (scope: line).
            guard let first = Self.nearestLine(at: p, context: context) else {
                return .none
            }
            firstPick = p
            cursor = p
            state = .pickingSecond(first: first)
            return .none

        case .pickingSecond(let first):
            // Compute the bevel against the second line under the click.
            guard let bevel = Self.bevel(first: first, firstPick: firstPick,
                                         secondPick: p, distance1: distance1,
                                         distance2: distance2, context: context)
            else {
                // No second line / parallel / degenerate distance → no-op.
                return .none
            }
            // The bevel line inherits the FIRST line's layer + pen (LibreCAD copies
            // the base container's layer/pen onto the new bevel segment).
            let bevelRecord = EntityRecord(
                id: .placeholder,
                layer: first.layer,
                pen: first.pen,
                kind: .line(LineData(start: bevel.p1, end: bevel.p2))
            )
            let edits: [ToolEdit] = [
                .replace(bevel.firstID, .line(bevel.line1)),
                .replace(bevel.secondID, .line(bevel.line2)),
                .add(bevelRecord),
            ]
            reset()
            return .commit(edits)
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .pickingFirst:
            // Nothing to step back.
            return .none
        case .pickingSecond:
            // Step back to before the first-line pick.
            state = .pickingFirst
            firstPick = .invalid
            cursor = .invalid
            return .none
        }
    }

    /// Returns to the initial waiting-for-first-line state, dropping the picks.
    private mutating func reset() {
        state = .pickingFirst
        firstPick = .invalid
        cursor = .invalid
        previewContext = .empty
    }

    // MARK: - Pick aperture

    /// The pick aperture in world units (which LINE is under a click). Derived from
    /// the grid spacing when present, else a small fixed default — mirrors the same
    /// rule `TrimTool` uses so picking feels consistent across the editing tools.
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance {
            return g * 0.5
        }
        return 0.5
    }

    /// The nearest LINE within the pick aperture of `p`, or `nil`. Non-LINE kinds
    /// are skipped (scope: line–line bevel).
    static func nearestLine(at p: Vector, context: ToolContext) -> EntityRecord? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) {
            switch e.kind {
            case .line:
                let d = HitTesting.worldDistance(from: p, to: e)
                if d < bestDist {
                    bestDist = d
                    best = e
                }
            default:
                // TODO(backlog): arc / polyline-segment bevels.
                continue
            }
        }
        return best
    }

    // MARK: - Bevel computation (pure, self-contained)

    /// The computed bevel: the trimmed geometry of both lines and the two bevel
    /// endpoints (P1 on line1, P2 on line2).
    struct BevelComputation {
        let firstID: EntityID
        let secondID: EntityID
        /// Line1 trimmed so its corner-end is moved to P1.
        let line1: LineData
        /// Line2 trimmed so its corner-end is moved to P2.
        let line2: LineData
        let p1: Vector
        let p2: Vector
    }

    /// Computes the bevel for `first` (already picked at `firstPick`) against the
    /// SECOND line under `secondPick`. Returns `nil` when there is no second LINE,
    /// the lines are parallel (no corner), or a distance is degenerate / longer
    /// than its line.
    static func bevel(first: EntityRecord, firstPick: Vector,
                      secondPick: Vector, distance1: Double, distance2: Double,
                      context: ToolContext) -> BevelComputation? {
        // The second line must be a LINE distinct from the first.
        guard let second = nearestLine(at: secondPick, context: context),
              second.id != first.id,
              case .line(let d1) = first.kind,
              case .line(let d2) = second.kind else {
            return nil
        }

        // 1. Corner = infinite-line intersection. Parallel → no intersection.
        let sol = Intersections.lineLine(d1.start, d1.end, d2.start, d2.end, segment: false)
        let corner: Vector = sol.closest(to: secondPick)
        guard corner.valid else { return nil }

        // 2. P1 on line1 at distance1 from the corner toward the FIRST pick side;
        //    P2 on line2 at distance2 from the corner toward the SECOND pick side.
        guard let r1 = bevelPoint(line: d1, pick: firstPick, corner: corner, distance: distance1),
              let r2 = bevelPoint(line: d2, pick: secondPick, corner: corner, distance: distance2)
        else {
            return nil
        }

        // 3. Trim each line: move the corner-end endpoint to the bevel point.
        let line1 = trimmed(d1, cornerIsStart: r1.cornerIsStart, to: r1.point)
        let line2 = trimmed(d2, cornerIsStart: r2.cornerIsStart, to: r2.point)

        return BevelComputation(firstID: first.id, secondID: second.id,
                                line1: line1, line2: line2,
                                p1: r1.point, p2: r2.point)
    }

    /// Resolves which endpoint of `line` is the CORNER-END (the one on the pick
    /// side) and the bevel point at `distance` from the corner back along the line
    /// into the body. Ported from `RS_Line::getTrimPoint` (side test) +
    /// `getNearestDist` (point at `distance` from the corner-end).
    ///
    /// Side test: the corner-end is the endpoint q with `(q − pick) · (corner − pick)
    /// >= 0` — i.e. q and the corner lie on the SAME side of the pick. LibreCAD's
    /// `getTrimPoint` returns `EndingEnd` (trim the END) when
    /// `(start − pick) · (corner − pick) < 0` (start is on the far side), else
    /// `EndingStart`. Returns `nil` if `distance` is non-positive, the line is
    /// zero-length, or `distance` exceeds the line's own length (the bevel point
    /// would fall past the far endpoint).
    static func bevelPoint(line: LineData, pick: Vector, corner: Vector,
                           distance: Double) -> (point: Vector, cornerIsStart: Bool)? {
        guard distance > Tolerance.distance else { return nil }
        let dir = line.end - line.start
        let len = dir.magnitude
        guard len > Tolerance.distance else { return nil }
        // A distance longer than the line itself has no valid bevel point on it.
        guard distance <= len + Tolerance.distance else { return nil }

        // getTrimPoint side test: is START on the far side of the pick from the
        // corner? If so the END is the corner-end (EndingEnd); else START is.
        let vStart = line.start - pick
        let vCorner = corner - pick
        let startIsFar = vStart.dot(vCorner) < 0

        // Unit vector along the line (start → end), as in getNearestDist's angle1.
        let unit = dir / len
        if startIsFar {
            // Corner-end is the END → bevel point = corner − distance·unit (back
            // toward the start / body), mirroring `endpoint − polar(distance, a1)`.
            return (corner - unit * distance, false)
        } else {
            // Corner-end is the START → bevel point = corner + distance·unit
            // (toward the end / body), mirroring `startpoint + polar(distance, a1)`.
            return (corner + unit * distance, true)
        }
    }

    /// Trims `line` so its corner-end endpoint (start when `cornerIsStart`, else
    /// end) is moved to `to`, keeping the opposite endpoint. Mirrors LibreCAD's
    /// `trimStartpoint` / `trimEndpoint`.
    static func trimmed(_ line: LineData, cornerIsStart: Bool, to point: Vector) -> LineData {
        cornerIsStart
            ? LineData(start: point, end: line.end)
            : LineData(start: line.start, end: point)
    }
}
