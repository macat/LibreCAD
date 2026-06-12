//
//  OffsetTool.swift
//  CADEngine
//
//  The OFFSET modify tool — make a parallel COPY of the current selection at a
//  perpendicular/radial distance, on the side of a clicked "through point".
//  Ported in spirit from LibreCAD's `RS_ActionModifyOffset`
//  (librecad/src/actions/drawing/modify/rs_actionmodifyoffset.cpp): pick a point
//  the offset copy must pass through; the distance and side are derived from that
//  point relative to each selected entity.
//
//  Behavior (offset each selected entity through one clicked point):
//    - empty selection → status "Select objects to offset first"; every input is
//                        a no-op (nothing to offset).
//    - `.move`         → rubber-band preview: each SUPPORTED selected entity's
//                        offset copy (computed so it passes through the cursor),
//                        resolved with the `.toolPreview` pen.
//    - `.click` (the through point) → commit one `.add` per SUPPORTED selected
//                        entity: a COPY (same layer/pen/flags, placeholder id so
//                        the app re-mints) whose geometry is the offset of the
//                        original passing through the clicked point. The originals
//                        are untouched. The tool then RESETS to picking another
//                        through point (multiple offsets of the SAME selection,
//                        LibreCAD-style) and reports `.finished` so the app can
//                        return to select mode if it chooses — the tool itself is
//                        left in a clean state either way.
//    - `.cancel` (Esc) → discard the captured selection / preview, reset.
//    - `.backspace`    → nothing picked within a single-pick op; no-op.
//    - `.commit`       → no pending geometry (offset commits on the click); finish.
//
//  SCOPE: line, circle, arc (the common case). Other kinds (polyline, ellipse,
//  spline, splinePoints, point) are SKIPPED — no edit is emitted for them — until
//  a backlog pass widens the offset geometry. See the `// TODO(backlog)` arms.
//
//  PURE (ADR-001 / Tool contract): it never touches CADDrawing / Quadtree / GUI.
//  It reads only the read-only `ToolContext.selected` plus the snapped world
//  points in `ToolInput`, and the offset geometry is computed entirely from the
//  entity defining data + the picked point (NO other-entity access needed). The
//  app applies the `.add` copies (re-minting ids) as one undoable group.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionModifyOffset).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Offset tool. With a selection active, click a "through point"
/// to drop a parallel copy of every supported selected entity at the
/// perpendicular/radial distance implied by that point (and on its side).
public struct OffsetTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle. Offset is a SINGLE-pick action (the through point),
    /// so there is one waiting state; the selection is captured the first time a
    /// non-empty `context.selected` is seen.
    private enum State: Equatable {
        /// Waiting for the through point the offset copy must pass through.
        case pickingThroughPoint
    }

    /// The current state. There is only one — kept as an `enum` (not a flag) to
    /// match the rest of the tool family and stay exhaustive if states are added.
    private var state: State = .pickingThroughPoint

    /// The last cursor point seen via `.move`, used to draw the rubber-band before
    /// the through point is clicked. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The selection captured the first time a non-empty `context.selected` is
    /// seen, so the preview/commit operate on a stable set even though the live
    /// `context.selected` is rebuilt per call. Empty until then.
    private var captured: [EntityRecord] = []

    public init() {}

    // MARK: - Tool

    public var title: String { "Offset" }

    public var status: String {
        // Nudge the user to select first until a selection has been captured.
        captured.isEmpty ? "Select objects to offset first" : "Specify through point"
    }

    /// The live rubber-band: every captured (supported) entity's offset copy,
    /// computed so it passes through the cursor, resolved with the preview pen.
    /// Empty before a selection is captured, before the cursor has moved, or when
    /// no supported entity yields a valid offset for the current cursor.
    public var preview: [ResolvedPolyline] {
        guard cursor.valid, !captured.isEmpty else { return [] }
        return captured.flatMap { record -> [ResolvedPolyline] in
            guard let kind = Self.offset(record.kind, through: cursor) else { return [] }
            // Resolve the OFFSET geometry, then stamp the shared preview pen on
            // every polyline so the rubber-band reads as a preview regardless of
            // the original entity's pen (the overlay may further recolor it).
            return kind.resolve(pen: .toolPreview, ctx: .default).polylines
        }
    }

    /// A MODIFY tool: it reads `context.selected` to capture the set to offset,
    /// then on the through-point click emits one `.add` per SUPPORTED entity (a
    /// parallel COPY; originals stay). It never `.replace`s or `.remove`s.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        // Capture the selection the first time we see a non-empty one, so the
        // status / preview / commit all act on a stable set for this run.
        if captured.isEmpty, !context.selected.isEmpty {
            captured = context.selected
        }

        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once a selection is captured.
            return preview.isEmpty ? .none : .preview

        case .click(let p):
            return handleClick(p)

        case .backspace:
            // Offset has a single pick; there is nothing to step back.
            return .none

        case .cancel:
            // Esc — discard the captured selection / preview and reset.
            reset()
            return .finished

        case .commit:
            // Return — offset commits on the click, so nothing is pending here.
            reset()
            return .finished
        }
    }

    // MARK: - Click handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        // Nothing to offset without a (captured) selection — no-op; the status
        // nudges the user to select first.
        guard !captured.isEmpty, p.valid else { return .none }

        // One `.add` per SUPPORTED entity whose offset is well-defined for this
        // through point (a degenerate/zero offset or an unsupported kind yields no
        // edit). Preserve each original's layer/pen/flags; only the geometry is
        // the offset copy. Originals stay (no `.replace`/`.remove`).
        let edits: [ToolEdit] = captured.compactMap { record in
            guard let kind = Self.offset(record.kind, through: p) else { return nil }
            return .add(EntityRecord(
                id: .placeholder,
                layer: record.layer,
                pen: record.pen,
                flags: record.flags,
                kind: kind
            ))
        }

        // Reset for another offset of the SAME selection if the app keeps the tool
        // active; either way the tool is left clean. If no supported entity
        // produced an offset (e.g. d ≈ 0, or all unsupported kinds), commit
        // nothing and keep waiting.
        reset()
        return edits.isEmpty ? .none : .commit(edits)
    }

    /// Returns to the initial waiting state and drops the captured selection.
    private mutating func reset() {
        state = .pickingThroughPoint
        cursor = .invalid
        captured = []
    }

    // MARK: - Offset geometry (pure, self-contained)

    /// Computes the offset of `kind` so the result passes through `point`, or
    /// `nil` if the kind is unsupported, the offset distance is ~0, or the result
    /// would be degenerate (e.g. a non-positive radius).
    ///
    /// - line:   a parallel line at the signed perpendicular distance from the
    ///           line to `point`, on `point`'s side (both endpoints shifted by
    ///           `d · unitPerp`, where `unitPerp` points toward `point`).
    /// - circle: concentric, radius `= |point − center|` (i.e. `r ± d`, with
    ///           `d = |point − center| − r`: outside → larger, inside → smaller).
    /// - arc:    concentric, radius `= |point − center|`, same start/end angles
    ///           and `reversed` flag.
    private static func offset(_ kind: EntityKind, through point: Vector) -> EntityKind? {
        switch kind {
        case .line(let d):
            return offsetLine(d, through: point).map(EntityKind.line)
        case .circle(let d):
            return offsetCircle(d, through: point).map(EntityKind.circle)
        case .arc(let d):
            return offsetArc(d, through: point).map(EntityKind.arc)

        // TODO(backlog): widen offset to these kinds (parallel polyline with
        // segment joins/trims, concentric ellipse/elliptic-arc, offset spline).
        // For now they are SKIPPED — no edit is emitted, matching the brief's
        // scope (line/circle/arc only).
        case .polyline, .ellipse, .spline, .splinePoints, .point,
             .text, .hatch, .solid, .dimension:
            return nil
        }
    }

    /// Parallel line through `point`. The offset distance is the perpendicular
    /// distance from the infinite line (containing the segment) to `point`, and
    /// the side is `point`'s side — so both endpoints shift by the perpendicular
    /// component of `(point − start)`. Returns `nil` for a degenerate (zero-length)
    /// line or when `point` already lies on the line (d ≈ 0).
    private static func offsetLine(_ d: LineData, through point: Vector) -> LineData? {
        let dir = d.end - d.start
        let len = dir.magnitude
        guard len > Tolerance.distance else { return nil }   // degenerate line
        let unit = dir / len
        // Left-hand unit normal (perpendicular) of the line direction.
        let normal = Vector(-unit.y, unit.x)
        // Signed perpendicular distance of `point` from the line: project
        // (point − start) onto the normal. Sign encodes the side automatically,
        // so `normal * signed` is the shift vector toward `point`'s side.
        let signed = (point - d.start).dot(normal)
        guard abs(signed) > Tolerance.distance else { return nil }   // d ≈ 0
        let shift = normal * signed
        return LineData(start: d.start + shift, end: d.end + shift)
    }

    /// Concentric circle whose radius is the distance from the center to `point`
    /// (`r + d` with `d = |point − center| − r`). Returns `nil` when the new
    /// radius is ~0/negative or unchanged (d ≈ 0).
    private static func offsetCircle(_ d: CircleData, through point: Vector) -> CircleData? {
        let newRadius = point.distance(to: d.center)
        guard newRadius > Tolerance.distance else { return nil }        // radius ≤ 0
        guard abs(newRadius - d.radius) > Tolerance.distance else { return nil }   // d ≈ 0
        return CircleData(center: d.center, radius: newRadius)
    }

    /// Concentric arc: radius `= |point − center|`, preserving the start/end
    /// angles and `reversed` flag (the sweep is unchanged; only the radius moves).
    /// Returns `nil` when the new radius is ~0/negative or unchanged (d ≈ 0).
    private static func offsetArc(_ d: ArcData, through point: Vector) -> ArcData? {
        let newRadius = point.distance(to: d.center)
        guard newRadius > Tolerance.distance else { return nil }        // radius ≤ 0
        guard abs(newRadius - d.radius) > Tolerance.distance else { return nil }   // d ≈ 0
        return ArcData(
            center: d.center,
            radius: newRadius,
            startAngle: d.startAngle,
            endAngle: d.endAngle,
            reversed: d.reversed
        )
    }
}
