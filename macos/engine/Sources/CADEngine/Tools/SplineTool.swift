//
//  SplineTool.swift
//  CADEngine
//
//  An interactive "spline through points" draw tool — the user clicks successive
//  fit points and the tool commits ONE interpolation spline that runs through /
//  near them. Ported in spirit from LibreCAD's `LC_ActionDrawSplinePoints`
//  (librecad/src/lib/actions/drawing/draw/lc_actiondrawsplinepoints.cpp), with the
//  magic `int m_status` replaced by a private `enum State`.
//
//  ## What it produces — `.splinePoints` (fit-point / interpolation spline)
//  The deliverable is a fit-point spline (`LC_SplinePoints`): the points the user
//  clicks ARE the spline's defining points. This engine's `.splinePoints` resolve
//  path (`QuadSpline.tessellate`) draws a chain of quadratic Béziers straight from
//  `SplinePointsData.controlPoints`, interpolating the FIRST and LAST point and
//  curving smoothly NEAR the interior ones (see the `splinePoints` arm of
//  `EntityKind.resolve` and the matching endpoint-snap convention in
//  `Snapping`). So this tool stores the clicked fit points DIRECTLY as
//  `controlPoints` — no separate fit→control banded solve (`UpdateControlPoints`)
//  is needed because the engine never ported that step (ADR note on
//  `SplinePointsData`): the stored points and the drawn curve use the same model.
//  Degree-3 character is intrinsic to the quadratic-Bézier interpolation the
//  resolve path uses; there is no separate degree field on `SplinePointsData`.
//
//  Behavior (mirrors `PolylineTool`'s multi-click accumulation):
//    - `.click`     → append the (snapped) fit point; prompt advances to "Specify
//                     next point (Return to finish)". Clicking very near the FIRST
//                     point (≥3 points down) CLOSES the spline and commits at once.
//    - `.move`      → live preview: the tessellated spline through the fixed points
//                     PLUS the cursor as a provisional last point. Falls back to
//                     the open control polyline when there are too few points for a
//                     real curve (so there is always something to see).
//    - `.commit`    → Return / double-click: if ≥2 points, emit ONE
//                     `.add(.splinePoints(...))` (open), then `.finished`; if <2,
//                     just `.finished` (no geometry).
//    - `.backspace` → remove the last fit point (back to the initial state if the
//                     last one is removed).
//    - `.cancel`    → discard the in-progress run, reset, `.finished`.
//    - A degenerate pick (coincident with the last fixed point) is IGNORED.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit and
//  IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2014 Pavel Krejcir / Dongxu Li (original LC_SplinePoints model).
//

import Foundation

/// How the Spline tool interprets the points the user picks — surfaced later by the
/// tool-options bar (via `applyToolConfig` + `ToolOptionsBar`, NOT this tool's job).
/// The two modes are the two CAD spline-construction families and produce DIFFERENT
/// entity kinds from the SAME multi-click flow:
///
/// - `.fit`           — the picks are FIT (interpolation) points the curve runs
///                      through/near; commits a `.splinePoints` (`LC_SplinePoints`)
///                      quadratic-Bézier interpolation spline. The DEFAULT — the
///                      original behavior, fully unchanged.
/// - `.controlPoints` — the picks are the CONTROL polygon of a NURBS curve; commits
///                      a `.spline` (`RS_Spline`) B-spline with those control points
///                      and an auto-generated clamped knot vector (so the curve
///                      interpolates its endpoints), mirroring LibreCAD's
///                      `RS_ActionDrawSpline` (control-point spline action).
public enum SplineMode: Sendable, Hashable, CaseIterable {
    /// Picks are fit points → `.splinePoints` interpolation spline (the default).
    case fit
    /// Picks are NURBS control points → `.spline` B-spline.
    case controlPoints
}

/// The interactive Spline tool (spline through points). Click to place successive
/// points; press Return (or double-click) to finish, committing all the points as
/// ONE entity. The `mode` selects how the picks are interpreted:
///
/// - `.fit` (default): commits ONE `.splinePoints` (fit-point interpolation) entity
///   that runs through / near the picks — the original behavior.
/// - `.controlPoints`: commits ONE `.spline` (NURBS B-spline) entity whose control
///   polygon IS the picks, with a default cubic degree (clamped to the pick count)
///   and an auto-generated clamped knot vector.
///
/// Clicking near the first point closes the spline. Mirrors `PolylineTool`'s
/// multi-click accumulation but commits a smooth curve instead of straight segments.
public struct SplineTool: Tool {

    /// The default degree for a `.controlPoints` (NURBS) spline — cubic, matching
    /// LibreCAD's `RS_Spline` default (`RS_ActionDrawSpline` mints degree 3). The
    /// emitted degree is clamped down to `controlPoints.count - 1` when there are
    /// too few picks for a true cubic (and to ≥ 1), so the commit is ALWAYS a
    /// resolvable NURBS — the engine's `NURBS.knotVector` needs
    /// `controlPoints.count >= degree + 1` to build a curve, else the resolve path
    /// falls back to drawing the control polygon.
    public static let defaultControlPointDegree = 3

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `LC_ActionDrawSplinePoints`'s status
    /// integers to an exhaustive `enum`. "no points yet" vs. "building a fit-point
    /// list".
    private enum State: Equatable {
        /// Waiting for the first fit point (no points yet).
        case empty
        /// One or more fit points fixed; waiting for the next point (or Return).
        /// `points` are the committed fit points in order.
        case building(points: [Vector])
    }

    /// The current state. Starts with no points.
    private var state: State = .empty

    /// The last cursor point seen via `.move`, used to draw the live spline through
    /// the fixed points plus a provisional last point at the cursor. Invalid until
    /// the first move.
    private var cursor: Vector = .invalid

    /// How the picked points are interpreted on commit — fit points (`.splinePoints`)
    /// vs. NURBS control points (`.spline`). Surfaced by the tool-options bar (via
    /// `applyToolConfig` + `ToolOptionsBar`, NOT this tool's job). Back-compatible:
    /// the default `.fit` keeps the original fit-point interpolation behavior.
    public let mode: SplineMode

    /// Creates a Spline tool in the given construction mode (default `.fit`, the
    /// original fit-point interpolation flow). The app's `applyToolConfig` mints the
    /// tool in the mode the options bar selected.
    public init(mode: SplineMode = .fit) {
        self.mode = mode
    }

    // MARK: - Tool

    public var title: String { "Spline" }

    public var status: String {
        let noun = (mode == .controlPoints) ? "control point" : "point"
        switch state {
        case .empty:    return "Specify first \(noun)"
        case .building: return "Specify next \(noun) (Return to finish)"
        }
    }

    /// The live preview while building: the tessellated interpolation spline
    /// through the committed fit points PLUS a provisional last point at the
    /// cursor, drawn with the SAME `QuadSpline` model the committed entity resolves
    /// with (so the preview matches the final curve exactly). Empty before the
    /// first point is set. With too few points for a real Bézier segment the
    /// preview falls back to the open control polyline so there is always something
    /// to see (matching the resolve path's own degenerate fallback).
    public var preview: [ResolvedPolyline] {
        guard case .building(let points) = state, !points.isEmpty else {
            return []
        }
        var pts = points
        if cursor.valid, pts.last.map({ !$0.coincides(with: cursor) }) ?? true {
            pts.append(cursor)   // provisional last point at the cursor
        }
        let tessellated = tessellatedSpline(points: pts, closed: false)
        guard tessellated.count >= 2 else { return [] }
        return [ResolvedPolyline(points: tessellated, closed: false, pen: .toolPreview)]
    }

    /// The AutoCAD-style mid-draw command KEYWORDS the spline offers at its current
    /// step, derived PURELY from the committed fit/control-point count in `state` (no
    /// new stored fields — reads `state` like `preview`/`status` do). The smart command
    /// line (Wave 4) renders these as `[Close]`/`[Undo]` chips, and a chosen keyword is
    /// dispatched back through the EXISTING `ToolInput` events (Wave 3):
    ///   - `Undo` ↔ `.backspace` (removes the last point).
    ///   - `Close` ↔ `.click(firstPoint)` — clicking on the first point closes the
    ///     spline and commits (`commitSpline(closed: true)`); there is no standalone
    ///     close input, so Wave 3 feeds the first point back as a `.click`.
    /// Step gating matches the REAL close path in `handleClick`, which requires
    /// `points.count >= 3` to close: <1 point → none; exactly 1 → `Undo` only; 2 →
    /// `Undo` only (cannot close yet); ≥3 → `Close` + `Undo`. Applies to BOTH modes
    /// (`.fit`/`.controlPoints`) — they share the same accumulation + close flow.
    /// Empty before the first point and after commit/reset (`state == .empty`).
    public var keywordOptions: [ToolKeyword] {
        guard case .building(let points) = state, !points.isEmpty else { return [] }
        if points.count >= 3 {
            return [
                ToolKeyword(keyword: "Close", label: "Close"),
                ToolKeyword(keyword: "Undo", label: "Undo"),
            ]
        }
        return [ToolKeyword(keyword: "Undo", label: "Undo")]
    }

    /// The WORLD point the smart command line's `Close` keyword re-feeds to close the
    /// spline: the FIRST committed point, returned EXACTLY when `keywordOptions` offers
    /// `Close` (≥ 3 committed points — matching `handleClick`'s real close gate), else
    /// `nil`. There is no standalone close input, so Wave 3 dispatches `Close` as
    /// `.click(closeAnchor)`; `handleClick`'s close-on-first-point path then commits the
    /// closed spline. Reads the same private `state.building.points` `keywordOptions`/
    /// `preview` read — no new stored field. Applies to BOTH modes (they share the flow).
    public var closeAnchor: Vector? {
        guard case .building(let points) = state, points.count >= 3 else { return nil }
        return points.first
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as a single `.add` edit on commit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once there is a fixed point.
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
            return handleClick(p)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the run and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return / double-click — finish the spline.
            return handleCommit()
        }
    }

    // MARK: - Click / backspace / commit handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .empty:
            // First fit point fixed; now show the live curve toward the next click.
            state = .building(points: [p])
            cursor = p
            return .none

        case .building(var points):
            // Closing: clicking very near the FIRST point (with ≥3 points) closes
            // the spline and commits immediately.
            if points.count >= 3, let first = points.first,
               first.valid, p.coincides(with: first) {
                return commitSpline(points: points, closed: true)
            }
            // Ignore a degenerate (coincident) repeat of the last point.
            if let last = points.last, last.valid, p.coincides(with: last) {
                return .none
            }
            points.append(p)
            state = .building(points: points)
            cursor = p
            return .none
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .empty:
            // Nothing to step back.
            return .none
        case .building(var points):
            points.removeLast()
            if points.isEmpty {
                reset()
            } else {
                state = .building(points: points)
            }
            return .preview
        }
    }

    private mutating func handleCommit() -> ToolOutcome {
        switch state {
        case .empty:
            // Nothing pending — just end the run.
            reset()
            return .finished
        case .building(let points):
            // Need at least two points to make a spline; otherwise commit nothing.
            guard points.count >= 2 else {
                reset()
                return .finished
            }
            return commitSpline(points: points, closed: false)
        }
    }

    /// Builds the single `.add` commit from the picked points and resets the tool,
    /// returning `.commit`. The entity KIND depends on `mode`:
    ///
    /// - `.fit`: the picks are the quadratic-Bézier control polygon the
    ///   `.splinePoints` resolve path interpolates (the original behavior).
    /// - `.controlPoints`: the picks are the NURBS control polygon of a `.spline`
    ///   with `SplineTool.degree(forControlPointCount:)` (default cubic, clamped) and
    ///   an empty knot vector — the resolve path's `NURBS.knotVector` then generates
    ///   a clamped (open) uniform vector so the curve interpolates its endpoints.
    ///
    /// The app re-mints the id and applies the edit as one undoable group.
    private mutating func commitSpline(points: [Vector], closed: Bool) -> ToolOutcome {
        let kind: EntityKind
        switch mode {
        case .fit:
            kind = .splinePoints(SplinePointsData(controlPoints: points, closed: closed))
        case .controlPoints:
            kind = .spline(SplineData(
                degree: SplineTool.degree(forControlPointCount: points.count),
                controlPoints: points,
                knots: [],     // resolver builds a clamped (endpoint-interpolating) vector
                weights: [],   // non-rational (all weights == 1)
                closed: closed
            ))
        }
        let record = EntityRecord(id: .placeholder, kind: kind)
        reset()
        return .commit([.add(record)])
    }

    /// The NURBS degree to emit for `count` picked control points: the default cubic
    /// (`defaultControlPointDegree`), clamped DOWN so there are always at least
    /// `degree + 1` control points (the minimum `NURBS.knotVector` needs for a real
    /// curve), and clamped UP to ≥ 1 (degree 0 is not a curve). With 2 picks this
    /// yields a degree-1 polyline, 3 picks a quadratic, 4+ the default cubic — every
    /// case resolves to non-empty geometry.
    static func degree(forControlPointCount count: Int) -> Int {
        Swift.max(1, Swift.min(defaultControlPointDegree, count - 1))
    }

    /// Returns to the initial waiting-for-first-point state.
    private mutating func reset() {
        state = .empty
        cursor = .invalid
    }

    // MARK: - Preview tessellation (shared model with the committed entity)

    /// Tessellates the given picked points with the SAME model the committed entity
    /// will resolve with — so the rubber-band preview is pixel-faithful to the final
    /// curve in BOTH modes:
    ///
    /// - `.fit`: the `QuadSpline` quadratic-Bézier interpolation model of
    ///   `.splinePoints` (the original behavior).
    /// - `.controlPoints`: the `NURBS` B-spline model of `.spline`, with the same
    ///   degree the commit will use.
    ///
    /// Falls back to the raw points (the control polyline) when there are too few for
    /// a real segment — the same degenerate fallback the resolve paths use.
    func tessellatedSpline(points: [Vector], closed: Bool) -> [Vector] {
        guard points.count >= 1 else { return [] }
        let tolerance = ResolveContext.default.tessellationTolerance
        switch mode {
        case .fit:
            let data = SplinePointsData(controlPoints: points, closed: closed)
            if let (pts, _) = QuadSpline.tessellate(data, tolerance: tolerance) {
                return pts
            }
        case .controlPoints:
            let data = SplineData(
                degree: SplineTool.degree(forControlPointCount: points.count),
                controlPoints: points,
                closed: closed
            )
            if let pts = NURBS.tessellate(data, tolerance: tolerance) {
                return pts
            }
        }
        return points
    }
}

// MARK: - Vector coincidence helper

private extension Vector {
    /// Whether two world points are within the general distance tolerance — used to
    /// reject degenerate (zero-length) repeat clicks and to detect closing on the
    /// first point. Mirrors the `(p - q).magnitude <= Tolerance.distance` test the
    /// other multi-click tools use, named for readability.
    func coincides(with other: Vector) -> Bool {
        (self - other).magnitude <= Tolerance.distance
    }
}
