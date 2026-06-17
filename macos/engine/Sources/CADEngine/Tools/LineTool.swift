//
//  LineTool.swift
//  CADEngine
//
//  The reference draw tool — the first concrete `Tool` and the template the
//  fan-out copies. Ported from LibreCAD's `RS_ActionDrawLine`
//  (librecad/src/lib/actions/drawing/draw/lc_actiondrawline.cpp), with the magic
//  `int m_status` replaced by a private `enum State` and the chaining behavior
//  (each committed segment continues from the previous endpoint to form a
//  polyline-like run until commit/cancel) preserved.
//
//  Behavior:
//    - first `.click`  → set the start point (State.settingStart → .settingEnd).
//    - `.move`         → rubber-band preview from the last fixed point to the
//                        cursor (a 1-segment polyline).
//    - next `.click`   → commit ONE `.line(LineData)` from the last fixed point
//                        to the clicked point, then CONTINUE from that endpoint
//                        (the clicked point becomes the new fixed point).
//    - `.backspace`    → step back one fixed point (undo the last pick within the
//                        run, no commit). From a single start point it returns to
//                        the initial state.
//    - `.cancel` (Esc) → discard the run, reset to the initial state, `.finished`.
//    - `.commit` (Ret) → end the run; `.finished` (nothing pending to add — each
//                        segment was already committed on its second click).
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawLine).
//

import Foundation

/// How the Line tool constrains the angle of the NEXT segment — surfaced by the
/// tool-options bar (UX-plan U2). It mirrors LibreCAD's angle-constrained line
/// entry: once a starting point is fixed, the cursor/clicked/typed point is
/// PROJECTED onto a ray of the chosen angle from the running endpoint, so the
/// committed segment lands at exactly that angle (its length is the projection of
/// the pick along the ray).
///
/// `.free` (the default) projects nothing — the original two-point flow is
/// unchanged and fully back-compatible.
public enum LineAngleMode: Sendable, Hashable {
    /// No angle constraint (the original behavior): the segment runs straight to
    /// the picked point.
    case free
    /// Constrain every segment to this ABSOLUTE angle (radians, CCW from +X). The
    /// pick is projected onto the ray from the running endpoint at this angle.
    case absolute(Double)
    /// Constrain each segment to this angle measured RELATIVE to the direction of
    /// the PREVIOUS committed segment (radians, CCW). The first segment of a run
    /// has no previous direction, so it is taken relative to +X (i.e. behaves like
    /// `.absolute` for the first segment), then each subsequent segment turns by
    /// this angle from the one before.
    case relative(Double)
}

/// The interactive Line tool. Click two points to draw a line; it then chains
/// (LibreCAD behavior), continuing from the endpoint until `.commit`/`.cancel`.
public struct LineTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawLine`'s status integers
    /// (SetStartpoint = 0, SetEndpoint = 1) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the first point (no fixed point yet).
        case settingStart
        /// One or more points fixed; waiting for the next point. `last` is the
        /// point the next segment starts from (the running endpoint).
        case settingEnd(last: Vector)
    }

    /// The current state. Starts waiting for the first point.
    private var state: State = .settingStart

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The angle constraint for the next segment. Surfaced by the tool-options bar
    /// (UX-plan U2). Back-compatible: the default `.free` keeps the original
    /// straight-to-the-pick two-point flow.
    public let angleMode: LineAngleMode

    /// The direction (radians) of the most recently committed segment within this
    /// run, or `nil` before the first segment commits. Used by `.relative` angle
    /// mode to turn each segment off the previous one; reset with the run.
    private var lastDirection: Double?

    /// Creates a Line tool with the given angle constraint (default `.free` — the
    /// original two-point flow). The app's `applyToolConfig` mints the tool in the
    /// mode the options bar selected.
    public init(angleMode: LineAngleMode = .free) {
        self.angleMode = angleMode
    }

    // MARK: - Tool

    public var title: String { "Line" }

    public var status: String {
        switch state {
        case .settingStart: return "Specify first point"
        case .settingEnd:   return "Specify next point"
        }
    }

    /// The live rubber-band: a 1-segment polyline from the running fixed point to
    /// the current cursor. Empty before the first point is set, or before the
    /// cursor has moved.
    public var preview: [ResolvedPolyline] {
        guard case .settingEnd(let last) = state, cursor.valid, last.valid else {
            return []
        }
        // Preview the CONSTRAINED endpoint so the rubber-band shows where the
        // angle-locked segment will actually land (identity in `.free` mode).
        let endPoint = constrained(last, cursor)
        return [ResolvedPolyline(points: [last, endPoint], closed: false, pen: .toolPreview)]
    }

    // MARK: - Live dimensional feedback (W1b)

    /// AutoCAD-style live feedback while the next segment is being dragged: the
    /// running LENGTH along the (constrained) segment plus the segment ANGLE near
    /// the cursor. Reuses the SAME `constrained(last, cursor)` endpoint the
    /// `preview` rubber-band shows, so the numbers match what will be drawn.
    ///
    /// Empty before the first point is fixed (`.settingStart`) and after commit
    /// (each segment is committed on its second click, returning to `.settingEnd`
    /// with `last == end`, so a stale cursor would still read empty until the next
    /// move) — the same invariant `referenceSegments` enforces, so it never leaks
    /// into exports. Both labels are formatted IN-ENGINE via `CoordinateFormatter`
    /// from `ctx` (no UI dependency).
    public func liveDimensions(_ ctx: LiveDimensionContext) -> [LiveDimension] {
        guard case .settingEnd(let last) = state, cursor.valid, last.valid else {
            return []
        }
        let end = constrained(last, cursor)
        let delta = end - last
        let length = delta.magnitude
        // A degenerate (zero-length) drag shows nothing — mirrors the commit guard.
        guard length > Tolerance.distance else { return [] }

        let lengthLabel = CoordinateFormatter.length(
            length, format: ctx.linearFormat, precision: ctx.linearPrecision, unit: ctx.unit
        )
        let angle = delta.angle
        let angleLabel = CoordinateFormatter.angle(
            angle, format: ctx.angleFormat, precision: ctx.anglePrecision
        )

        // Length dim runs along the segment, labeled at its midpoint; the angle
        // dim shares the segment and is labeled near the cursor end. Both are
        // editable (dynamic input): the user can type a length and/or an angle and
        // Tab between them — `applyDynamicInput` turns the typed values into the next
        // point. In a constrained angle mode the angle is read-only (the constraint
        // owns it) but still stamped editable so the overlay surfaces it; the typed
        // angle is ignored by `applyDynamicInput` in that mode.
        let midpoint = (last + end) * 0.5
        return [
            LiveDimension(kind: .linear(length), from: last, to: end,
                          label: lengthLabel, labelAnchor: midpoint,
                          field: .length, isEditable: true),
            LiveDimension(kind: .angle(angle), from: last, to: end,
                          label: angleLabel, labelAnchor: end,
                          field: .angle, isEditable: true),
        ]
    }

    // MARK: - Dynamic input (typed length / angle → the next point)

    /// Resolves typed LENGTH / ANGLE values into the next segment's endpoint, measured
    /// from the running endpoint (`reference`). A field the user did not type falls back
    /// to the live value the cursor currently implies.
    ///
    /// - FREE mode (`constraintAngle == nil`): both fields are honored — the point is
    ///   `reference + Vector(angle: typedOrLiveAngle) * typedOrLiveLength`.
    /// - CONSTRAINED mode (`.absolute` / `.relative`, `constraintAngle != nil`): the
    ///   angle is OWNED by the constraint (a typed `.angle` is ignored), and the typed
    ///   length is laid along the locked ray. The result is routed through the SAME
    ///   `constrained(_:_:)` the click-commit path uses, so a typed length lands exactly
    ///   where a click of that reach would.
    ///
    /// Returns `nil` until the first point is fixed (no running endpoint to measure from).
    public func applyDynamicInput(_ values: [LiveDimensionField: Double],
                                  cursor: Vector, reference: Vector) -> Vector? {
        guard case .settingEnd = state else { return nil }
        let liveDelta = cursor - reference
        let len = values[.length] ?? liveDelta.magnitude
        if let lockedAngle = constraintAngle {
            // Angle is fixed by the constraint; lay the typed/live length along the ray,
            // then route through the identical constraint projection the commit uses so a
            // typed length lands precisely on the locked ray.
            let along = reference + Vector(angle: lockedAngle) * len
            return constrained(reference, along)
        }
        let ang = values[.angle] ?? liveDelta.angle
        return reference + Vector(angle: ang) * len
    }

    // MARK: - Angle constraint (pure)

    /// The angle (radians, CCW from +X) the next segment from `from` is locked to,
    /// or `nil` in `.free` mode (no constraint). `.relative` turns off the previous
    /// segment's direction (`lastDirection`), falling back to +X for the first
    /// segment of a run.
    private var constraintAngle: Double? {
        switch angleMode {
        case .free:               return nil
        case .absolute(let a):    return a
        case .relative(let a):    return (lastDirection ?? 0) + a
        }
    }

    /// Projects `pick` onto the constraint ray from `from`. In `.free` mode (or with
    /// an invalid input) it returns `pick` unchanged, so the plain two-point flow is
    /// untouched. The projected point is `from + (pick−from)·d̂ · d̂` for the unit
    /// ray direction `d̂`: the pick's component along the locked angle, so the
    /// segment runs at exactly that angle with the length the cursor reaches.
    func constrained(_ from: Vector, _ pick: Vector) -> Vector {
        guard let angle = constraintAngle, from.valid, pick.valid else { return pick }
        let dir = Vector(angle: angle)            // unit ray direction
        let t = (pick - from).dot(dir)            // signed projection length
        return from + dir * t
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
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
            // Return — end the run. Each segment was already committed on its
            // second click, so there is nothing pending to add here.
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        switch state {
        case .settingStart:
            // First point fixed; now rubber-band toward the next click.
            state = .settingEnd(last: p)
            cursor = p
            return .none

        case .settingEnd(let last):
            // Apply the angle constraint (identity in `.free` mode), then commit one
            // segment last→end and CONTINUE from `end` (chaining).
            let end = constrained(last, p)
            guard last.valid, end.valid, (end - last).magnitude > Tolerance.distance else {
                // Degenerate (zero-length) pick — ignore it, keep waiting. (A pick
                // exactly behind an angle ray projects to `last`, also a no-op.)
                return .none
            }
            let record = EntityRecord(
                id: .placeholder,
                kind: .line(LineData(start: last, end: end))
            )
            lastDirection = (end - last).angle
            state = .settingEnd(last: end)
            cursor = end
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingStart:
            // Nothing to step back.
            return .none
        case .settingEnd:
            // Step back the running endpoint to before the first fixed point.
            // (Already-committed segments stay in the drawing — the app's undo
            //  removes those; backspace only rewinds the in-progress pick.)
            reset()
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-point state.
    private mutating func reset() {
        state = .settingStart
        cursor = .invalid
        lastDirection = nil
    }
}
