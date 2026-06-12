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

/// The interactive Spline tool (spline through points). Click to place successive
/// fit points; press Return (or double-click) to finish, committing all the points
/// as ONE `.splinePoints` (fit-point interpolation) entity that runs through /
/// near them. Clicking near the first point closes the spline. Mirrors
/// `PolylineTool`'s multi-click accumulation but commits a smooth curve instead of
/// straight segments.
public struct SplineTool: Tool {

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

    public init() {}

    // MARK: - Tool

    public var title: String { "Spline" }

    public var status: String {
        switch state {
        case .empty:    return "Specify first point"
        case .building: return "Specify next point (Return to finish)"
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
            pts.append(cursor)   // provisional last fit point at the cursor
        }
        let tessellated = SplineTool.tessellatedSpline(points: pts, closed: false)
        guard tessellated.count >= 2 else { return [] }
        return [ResolvedPolyline(points: tessellated, closed: false, pen: .toolPreview)]
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as a single `.add` edit on commit.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // A move only matters for the preview once there is a fixed point.
            return preview.isEmpty ? .none : .preview

        case .click(let p):
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

    /// Builds the single `.add(.splinePoints)` commit (the clicked fit points as the
    /// quadratic-Bézier control polygon the resolve path interpolates) and resets
    /// the tool, returning `.commit`. The app re-mints the id and applies the edit
    /// as one undoable group.
    private mutating func commitSpline(points: [Vector], closed: Bool) -> ToolOutcome {
        let record = EntityRecord(
            id: .placeholder,
            kind: .splinePoints(SplinePointsData(controlPoints: points, closed: closed))
        )
        reset()
        return .commit([.add(record)])
    }

    /// Returns to the initial waiting-for-first-point state.
    private mutating func reset() {
        state = .empty
        cursor = .invalid
    }

    // MARK: - Preview tessellation (shared model with the committed entity)

    /// Tessellates the given fit points with the SAME quadratic-Bézier model the
    /// committed `.splinePoints` entity resolves with, so the rubber-band preview is
    /// pixel-faithful to the final curve. Falls back to the raw points (the control
    /// polyline) when there are too few for a real Bézier segment — the same
    /// degenerate fallback `QuadSpline.tessellate` uses.
    static func tessellatedSpline(points: [Vector], closed: Bool) -> [Vector] {
        guard points.count >= 1 else { return [] }
        let data = SplinePointsData(controlPoints: points, closed: closed)
        if let (pts, _) = QuadSpline.tessellate(
            data, tolerance: ResolveContext.default.tessellationTolerance
        ) {
            return pts
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
