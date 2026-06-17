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

    // MARK: - Mode (additive — default reproduces the original behavior)

    /// How the offset distance is determined. The default `.through` mode is the
    /// original behavior, unchanged byte-for-byte: the offset copy passes THROUGH
    /// the clicked point (distance = the perpendicular/radial distance to that
    /// point, on its side). The additive `.distance` mode offsets by a FIXED,
    /// configured `distance` (LibreCAD's `m_dist`), with the click/cursor only
    /// choosing the SIDE — the classic "offset by N units" workflow.
    ///
    /// This is an UNWIRED option: the public `mode` / `distance` vars exist so a
    /// later options-bar wire-wave can set them; the tool defaults to the original
    /// through-point behavior and nothing else in the engine sets them yet.
    public enum OffsetMode: Sendable, Equatable {
        /// Original behavior: the offset copy passes through the picked point
        /// (distance derived from that point, side = the point's side).
        case through
        /// Offset by a fixed configured `distance`; the picked point/cursor only
        /// selects which side of the entity the copy lands on.
        case distance
    }

    /// The active mode. Defaults to `.through` (the original behavior — the
    /// existing tests construct a default `OffsetTool` and expect through-point
    /// offsets, so this default keeps them byte-identical). Public so a future
    /// options-bar can switch it; UNWIRED for now.
    public var mode: OffsetMode = .through

    /// The fixed offset distance used by `.distance` mode (world units). Ignored
    /// in `.through` mode. A non-positive value yields no offset (no edit), the
    /// same safe no-op the through mode uses for a degenerate distance. Public for
    /// the future options-bar; UNWIRED for now.
    public var distance: Double = 0

    /// When `true`, also emit the OPPOSITE-side offset copy for each source —
    /// LibreCAD's "both sides" option. The primary copy still lands toward the
    /// picked point/cursor; the mirror copy is its reflection across the source's
    /// axis (line: across the line; circle/arc: radius `r − delta`). A degenerate
    /// mirror (circle/arc whose radius would be ≤ 0) is silently dropped, so only
    /// valid geometry is emitted. Defaults to `false` — a default tool produces a
    /// single `.add`, byte-identical to the original behavior. Public for the
    /// future options-bar; UNWIRED for now.
    public var bothSides: Bool = false

    /// When `true`, ERASE each source that produced at least one offset copy —
    /// LibreCAD's "delete original" option — by appending a `.remove(source.id)`
    /// alongside its `.add`(s). A source is removed at most ONCE even when
    /// `bothSides` emitted two copies, and a source that produced NO copy (an
    /// unsupported kind, or a degenerate offset) is left untouched. Defaults to
    /// `false` — the original copy-only behavior. Public for the future
    /// options-bar; UNWIRED for now.
    public var eraseSource: Bool = false

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
            guard let kind = offsetForCurrentMode(record.kind, toward: cursor) else { return [] }
            // Resolve the OFFSET geometry, then stamp the shared preview pen on
            // every polyline so the rubber-band reads as a preview regardless of
            // the original entity's pen (the overlay may further recolor it).
            return kind.resolve(pen: .toolPreview, ctx: .default).polylines
        }
    }

    /// Computes the offset of `kind` for the active mode, given the picked point
    /// `p` (or cursor for the preview):
    ///   - `.through`  → offset so the copy passes THROUGH `p` (original behavior).
    ///   - `.distance` → offset by the fixed `distance`, on `p`'s side.
    /// Returns `nil` for an unsupported kind or a degenerate result, matching the
    /// per-mode geometry helpers.
    private func offsetForCurrentMode(_ kind: EntityKind, toward p: Vector) -> EntityKind? {
        switch mode {
        case .through:
            return Self.offset(kind, through: p)
        case .distance:
            return Self.offset(kind, byDistance: distance, towardSideOf: p)
        }
    }

    /// The offset COPIES for one source `kind` toward `p`: the primary (toward-`p`)
    /// offset, plus — when `bothSides` is set — the opposite-side copy. A degenerate
    /// opposite (circle/arc whose mirrored radius would be ≤ 0) is dropped, so this
    /// never returns invalid geometry. Empty when the kind is unsupported or the
    /// primary offset itself is degenerate (e.g. `p` on the line / d ≈ 0).
    private func offsetCopies(of kind: EntityKind, toward p: Vector) -> [EntityKind] {
        guard let primary = offsetForCurrentMode(kind, toward: p) else { return [] }
        guard bothSides else { return [primary] }
        if let opposite = Self.oppositeOffset(of: kind, primary: primary) {
            return [primary, opposite]
        }
        return [primary]
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
        case .value(let p):
            // A TYPED point (U1 coordinate line) where a point is expected: both
            // modes treat it exactly like the through/side-pick `.click` at that
            // exact point (no snap drift). The existing tests never feed `.value`,
            // so the `.through` default behavior is unchanged.
            return handleClick(p)

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

        // One or two `.add`s per SUPPORTED entity whose offset is well-defined for
        // this through point (a degenerate/zero offset or an unsupported kind
        // yields no edit). `bothSides` adds the opposite-side copy; `eraseSource`
        // appends a single `.remove` for any source that produced ≥1 copy.
        // Preserve each original's layer/pen/flags; only the geometry is the offset
        // copy. Without `eraseSource`, originals stay (no `.replace`/`.remove`).
        let edits: [ToolEdit] = captured.flatMap { record -> [ToolEdit] in
            let copies = offsetCopies(of: record.kind, toward: p)
            guard !copies.isEmpty else { return [] }   // produced nothing → no edit
            var recordEdits: [ToolEdit] = copies.map { kind in
                .add(EntityRecord(
                    id: .placeholder,
                    layer: record.layer,
                    pen: record.pen,
                    flags: record.flags,
                    kind: kind
                ))
            }
            // Erase the source ONCE (only because it produced ≥1 copy above).
            if eraseSource {
                recordEdits.append(.remove(record.id))
            }
            return recordEdits
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
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .multileader, .image:
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

    // MARK: - Fixed-distance offset geometry (.distance mode)

    /// Computes the offset of `kind` by the FIXED `distance`, on the side of
    /// `sidePoint` (the picked point / cursor — used only to choose which side).
    /// Returns `nil` if the kind is unsupported, `distance` is non-positive, or the
    /// result is degenerate (e.g. a non-positive radius).
    ///
    /// - line:   a parallel line shifted by `distance` along the unit normal that
    ///           points toward `sidePoint` (so the copy lands on the picked side).
    /// - circle/arc: concentric, radius `r + distance` when `sidePoint` is OUTSIDE
    ///           the original (or on it) and `r − distance` when inside — i.e. the
    ///           copy moves toward the picked side.
    private static func offset(_ kind: EntityKind, byDistance distance: Double,
                               towardSideOf sidePoint: Vector) -> EntityKind? {
        guard distance > Tolerance.distance, sidePoint.valid else { return nil }
        switch kind {
        case .line(let d):
            return offsetLine(d, byDistance: distance, towardSideOf: sidePoint).map(EntityKind.line)
        case .circle(let d):
            return offsetCircle(d, byDistance: distance, towardSideOf: sidePoint).map(EntityKind.circle)
        case .arc(let d):
            return offsetArc(d, byDistance: distance, towardSideOf: sidePoint).map(EntityKind.arc)

        // Same scope as the through-point path: line/circle/arc only.
        case .polyline, .ellipse, .spline, .splinePoints, .point,
             .text, .mtext, .hatch, .solid, .dimension, .insert, .xline, .ray, .leader,
             .multileader, .image:
            return nil
        }
    }

    /// Parallel line shifted by `distance` along the unit normal toward `sidePoint`.
    /// The side is the sign of `(sidePoint − start)·normal`; if `sidePoint` lies on
    /// the line (sign ≈ 0) the positive-normal side is used. Returns `nil` for a
    /// degenerate (zero-length) line.
    private static func offsetLine(_ d: LineData, byDistance distance: Double,
                                   towardSideOf sidePoint: Vector) -> LineData? {
        let dir = d.end - d.start
        let len = dir.magnitude
        guard len > Tolerance.distance else { return nil }   // degenerate line
        let unit = dir / len
        // Left-hand unit normal (perpendicular) of the line direction.
        let normal = Vector(-unit.y, unit.x)
        // Pick the side: the sign of the side point's projection onto the normal
        // (default to the positive-normal side when the point is on the line).
        let signed = (sidePoint - d.start).dot(normal)
        let sign: Double = signed < 0 ? -1 : 1
        let shift = normal * (distance * sign)
        return LineData(start: d.start + shift, end: d.end + shift)
    }

    /// Concentric circle whose radius moves by `distance` toward `sidePoint`:
    /// `r + distance` when the point is outside (or on) the circle, `r − distance`
    /// when inside. Returns `nil` when the new radius would be ~0 or negative.
    private static func offsetCircle(_ d: CircleData, byDistance distance: Double,
                                     towardSideOf sidePoint: Vector) -> CircleData? {
        let inside = sidePoint.distance(to: d.center) < d.radius
        let newRadius = inside ? d.radius - distance : d.radius + distance
        guard newRadius > Tolerance.distance else { return nil }        // radius ≤ 0
        return CircleData(center: d.center, radius: newRadius)
    }

    /// Concentric arc whose radius moves by `distance` toward `sidePoint` (same
    /// inside/outside rule as the circle), preserving the start/end angles and the
    /// `reversed` flag. Returns `nil` when the new radius would be ~0 or negative.
    private static func offsetArc(_ d: ArcData, byDistance distance: Double,
                                  towardSideOf sidePoint: Vector) -> ArcData? {
        let inside = sidePoint.distance(to: d.center) < d.radius
        let newRadius = inside ? d.radius - distance : d.radius + distance
        guard newRadius > Tolerance.distance else { return nil }        // radius ≤ 0
        return ArcData(
            center: d.center,
            radius: newRadius,
            startAngle: d.startAngle,
            endAngle: d.endAngle,
            reversed: d.reversed
        )
    }

    // MARK: - Opposite-side offset (bothSides)

    /// Given a `source` entity and its PRIMARY offset copy `primary` (same kind,
    /// already computed for the active mode), returns the offset copy on the
    /// OPPOSITE side — the mirror of `primary` across the source's axis — or `nil`
    /// when that mirror is degenerate (circle/arc radius ≤ 0) or the kind is
    /// unsupported. Mode-agnostic: it derives the opposite purely from the source
    /// and its primary copy, so it works identically for `.through` and `.distance`.
    ///
    /// - line:   reflect `primary` back across the source line. The primary was
    ///           `source ± shift`; the opposite is `source ∓ shift`, i.e. each
    ///           endpoint shifted by `−(primary − source)`.
    /// - circle: radius `r − delta` where `delta = primaryRadius − r` (the primary
    ///           moved the radius by `delta`; the opposite moves it the other way).
    ///           Equivalently `2·r − primaryRadius`. `nil` when that is ≤ 0.
    /// - arc:    same radius rule, preserving the source's angles + `reversed` flag.
    private static func oppositeOffset(of source: EntityKind, primary: EntityKind) -> EntityKind? {
        switch (source, primary) {
        case let (.line(s), .line(p)):
            // Shift that produced the primary copy; negate it for the other side.
            let shift = p.start - s.start
            return .line(LineData(start: s.start - shift, end: s.end - shift))

        case let (.circle(s), .circle(p)):
            let opposite = 2 * s.radius - p.radius
            guard opposite > Tolerance.distance else { return nil }   // radius ≤ 0 → drop
            return .circle(CircleData(center: s.center, radius: opposite))

        case let (.arc(s), .arc(p)):
            let opposite = 2 * s.radius - p.radius
            guard opposite > Tolerance.distance else { return nil }   // radius ≤ 0 → drop
            return .arc(ArcData(
                center: s.center,
                radius: opposite,
                startAngle: s.startAngle,
                endAngle: s.endAngle,
                reversed: s.reversed
            ))

        // Unsupported / kind-mismatch (shouldn't happen — primary is the same kind):
        default:
            return nil
        }
    }
}
