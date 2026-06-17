//
//  CircleTool.swift
//  CADEngine
//
//  The center+radius Circle draw tool — a concrete `Tool` built to the same
//  template as `LineTool`. Ported from LibreCAD's `RS_ActionDrawCircle`
//  (librecad/src/lib/actions/drawing/draw/lc_actiondrawcircle.cpp, the
//  center-then-radius variant), with the magic `int m_status` replaced by a
//  private `enum State` and the post-commit re-arm behavior (stay active for the
//  next circle) preserved.
//
//  Behavior:
//    - first `.click`  → set the center (State.settingCenter → .settingRadius).
//    - `.move`         → rubber-band preview: a tessellated circle centered on the
//                        fixed center with radius = |cursor − center|.
//    - next `.click`   → commit ONE `.circle(CircleData)` (center, radius =
//                        |clicked − center|), then RESET to .settingCenter so the
//                        tool is ready to draw the next circle. A degenerate
//                        zero-radius click is ignored (keeps waiting for radius).
//    - `.backspace`    → step the radius pick back to the initial state (no commit).
//    - `.cancel` (Esc) → discard the in-progress circle, reset to .settingCenter.
//    - `.commit` (Ret) → when idle, end the tool's run; `.finished`.
//
//  PURE: it never touches CADDrawing/Quadtree/GUI. It receives already-snapped
//  world points and returns outcomes/preview; the app re-mints ids on commit, and
//  it IGNORES `context` (a draw tool needs only the snapped points).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawCircle).
//

import Foundation

/// Whether the Circle tool's numeric SIZE input is interpreted as a radius or a
/// diameter — surfaced by the tool-options bar (UX-plan U2). It governs how a typed
/// command-line value and the `fixedSize` option are read: in `.diameter` mode the
/// value is the full diameter (halved to the stored radius). It does NOT change the
/// interactive two-click geometry (the second click is always a point ON the
/// circle); it only labels and scales the NUMERIC entry.
public enum CircleSizeMode: Sendable, Hashable, CaseIterable {
    /// The numeric value is the circle's radius (default).
    case radius
    /// The numeric value is the circle's diameter (stored radius = value / 2).
    case diameter
}

/// The GEOMETRIC construction method the Circle tool uses to fix the circle from
/// picked points — surfaced by the tool-options bar (UX-plan U2), mirroring
/// LibreCAD's circle-construction actions (`RS_ActionDrawCircle*`). This is
/// orthogonal to `CircleSizeMode` (which only labels the NUMERIC entry on the
/// `.centerRadius` path); it selects HOW the picks define the circle.
public enum CircleConstructionMode: Sendable, Hashable, CaseIterable {
    /// Click the center, then a point ON the circle that fixes the radius (the
    /// original two-click flow). The default — fully back-compatible.
    case centerRadius
    /// Click two points that are DIAMETER endpoints: the circle's center is their
    /// midpoint and its radius is half their distance (`RS_ActionDrawCircle2P`).
    case twoPoint
    /// Click three points the circle passes THROUGH: the unique circle through the
    /// three picks (its circumcircle) (`RS_ActionDrawCircle3P`). Collinear /
    /// coincident picks have no finite circle and are ignored.
    case threePoint
    /// Tangent–Tangent–Radius: pick TWO entities (lines / circles / arcs) the circle
    /// must be tangent to, with a fixed `fixedSize` radius; among the up-to-eight
    /// solution circles of that radius the one whose center is NEAREST the cursor (at
    /// the radius pick) is committed (`RS_ActionDrawCircleTan2`). Requires a positive
    /// `fixedSize` (the TTR radius); with none set the picks are no-ops.
    case tanTanRadius
    /// Tangent–Tangent–Tangent (inscribe): pick THREE entities the circle must be
    /// tangent to; the inscribed/escribed circle nearest the cursor is committed
    /// (`RS_ActionDrawCircleTan3`). This build solves the THREE-LINE case (triangle
    /// incircle + excircles) in closed form; a non-line third reference is a no-op.
    case tanTanTan
    /// From-arc: pick a single ARC (or circle); the circle COMPLETING it — same center
    /// and radius — is committed (a one-pick convenience, no solver).
    case fromArc
}

/// The interactive center+radius Circle tool. Click the center, then click (or
/// move to preview) a point on the circle to set the radius; it commits one
/// circle and re-arms for the next (LibreCAD behavior).
public struct CircleTool: Tool {

    // MARK: - Private state machine (no magic Int — engine-architecture note)

    /// The tool's lifecycle, ported from `RS_ActionDrawCircle`'s status integers
    /// (SetCenter / SetRadius) to an exhaustive `enum`.
    private enum State: Equatable {
        /// Waiting for the center point (nothing fixed yet).
        case settingCenter
        /// Center fixed; waiting for a point on the circle that sets the radius.
        case settingRadius(center: Vector)

        /// Two-point (diameter) mode: waiting for the first diameter endpoint.
        case twoFirst
        /// Two-point (diameter) mode: the first endpoint is fixed; waiting for the
        /// second. The committed circle's center is the midpoint of the two.
        case twoSecond(first: Vector)

        /// Three-point mode: waiting for the first point ON the circle.
        case threeFirst
        /// Three-point mode: one point fixed; waiting for the second.
        case threeSecond(first: Vector)
        /// Three-point mode: two points fixed; waiting for the third. The committed
        /// circle is the unique one through the three picks.
        case threeThird(first: Vector, second: Vector)

        /// TTR mode: waiting for the FIRST tangent entity pick.
        case ttrFirst
        /// TTR mode: first tangent entity fixed; waiting for the SECOND. The committed
        /// circle (radius = `fixedSize`) is tangent to both, picked by cursor proximity.
        case ttrSecond(first: EntityRecord)

        /// TTT (inscribe) mode: waiting for the FIRST tangent entity.
        case tttFirst
        /// TTT mode: one entity fixed; waiting for the second.
        case tttSecond(first: EntityRecord)
        /// TTT mode: two entities fixed; waiting for the third. The committed circle is
        /// tangent to all three (incircle/excircle nearest the cursor).
        case tttThird(first: EntityRecord, second: EntityRecord)

        /// From-arc mode: waiting for the single arc/circle pick to complete.
        case fromArcPick
    }

    /// The current state. Set in `init` from the `mode`.
    private var state: State

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

    /// The candidate circle computed on the last `.move` for the ENTITY-PICK modes
    /// (TTR / TTT / from-arc), cached because `preview` has no `ToolContext` (the app
    /// builds one only for `handle`). The interactive point modes don't use it (their
    /// preview is a pure function of `cursor` + fixed points). `nil` when no valid
    /// candidate circle would result. Mirrors `FilletTool.previewResult`.
    private var previewCircleData: CircleData?

    /// Whether a numeric size entry means a radius (default) or a diameter. Surfaced
    /// by the tool-options bar (UX-plan U2). Used to interpret `fixedSize`.
    public var sizeMode: CircleSizeMode = .radius

    /// An optional EXACT size (radius or diameter per `sizeMode`, world units),
    /// surfaced by the tool-options bar (UX-plan U2). When set (> 0), a SINGLE click
    /// fixes the center and immediately commits a circle of that size, then re-arms
    /// — the "drop a Ø50 hole here" flow. `nil` (the default) keeps the original
    /// two-click center+radius behavior, so this is fully back-compatible.
    public var fixedSize: Double?

    /// The configured fixed RADIUS (resolving `sizeMode`), or `nil` when no usable
    /// exact size is set. Diameter mode halves the entry.
    private var fixedRadius: Double? {
        guard let s = fixedSize, s > Tolerance.distance else { return nil }
        return sizeMode == .diameter ? s / 2 : s
    }

    /// The geometric construction method. Surfaced by the tool-options bar (UX-plan
    /// U2). Back-compatible: the default `.centerRadius` keeps the original
    /// two-click center+radius flow (and the `sizeMode` / `fixedSize` options).
    public let mode: CircleConstructionMode

    /// Creates a Circle tool in the given construction mode (default the original
    /// center+radius). The app's `applyToolConfig` mints the tool in the mode the
    /// options bar selected.
    public init(mode: CircleConstructionMode = .centerRadius) {
        self.mode = mode
        self.state = Self.initialState(for: mode)
    }

    /// The initial waiting state for a construction mode.
    private static func initialState(for mode: CircleConstructionMode) -> State {
        switch mode {
        case .centerRadius: return .settingCenter
        case .twoPoint:     return .twoFirst
        case .threePoint:   return .threeFirst
        case .tanTanRadius: return .ttrFirst
        case .tanTanTan:    return .tttFirst
        case .fromArc:      return .fromArcPick
        }
    }

    // MARK: - Tool

    public var title: String { "Circle" }

    public var status: String {
        switch state {
        case .settingCenter: return "Specify center point"
        case .settingRadius: return "Specify radius"
        case .twoFirst:      return "Specify first diameter point"
        case .twoSecond:     return "Specify second diameter point"
        case .threeFirst:    return "Specify first point"
        case .threeSecond:   return "Specify second point"
        case .threeThird:    return "Specify third point"
        case .ttrFirst:      return "Select first tangent entity"
        case .ttrSecond:     return "Select second tangent entity"
        case .tttFirst:      return "Select first tangent entity"
        case .tttSecond:     return "Select second tangent entity"
        case .tttThird:      return "Select third tangent entity"
        case .fromArcPick:   return "Select an arc to complete"
        }
    }

    /// The live rubber-band: a tessellated circle centered on the fixed center
    /// with radius = distance from the center to the current cursor, returned as a
    /// CLOSED `ResolvedPolyline`. Empty before the center is set, before the cursor
    /// has moved, or while the radius is still degenerate (zero).
    public var preview: [ResolvedPolyline] {
        guard cursor.valid else { return [] }
        switch state {
        case .settingRadius(let center):
            guard center.valid else { return [] }
            return previewCircle(center: center, radius: (cursor - center).magnitude)

        case .twoSecond(let first):
            // Diameter preview: center = midpoint(first, cursor), radius = half-span.
            guard first.valid, let c = Self.circleFromDiameter(first, cursor) else { return [] }
            return previewCircle(center: c.center, radius: c.radius)

        case .threeThird(let first, let second):
            // Rubber-band the circle through first → second → cursor.
            guard let c = Self.circleThrough(first, second, cursor) else { return [] }
            return previewCircle(center: c.center, radius: c.radius)

        case .ttrSecond, .tttThird, .fromArcPick:
            // Entity-pick modes: show the candidate circle cached on the last `.move`
            // (the preview path has no `ToolContext`, so it can't recompute the pick).
            guard let c = previewCircleData else { return [] }
            return previewCircle(center: c.center, radius: c.radius)

        default:
            return []
        }
    }

    /// Builds a tessellated, closed circular preview, or `[]` for a degenerate
    /// (non-positive) radius. Shared by every construction mode's rubber-band.
    private func previewCircle(center: Vector, radius: Double) -> [ResolvedPolyline] {
        guard center.valid, radius > Tolerance.distance else { return [] }
        let pts = Tessellation.circlePoints(
            center: center, radius: radius, tolerance: ResolveContext.default.tessellationTolerance
        )
        return [ResolvedPolyline(points: pts, closed: true, pen: .toolPreview)]
    }

    // MARK: - Live dimensional feedback (W1b)

    /// AutoCAD-style live feedback while the circle is being dragged: the running
    /// RADIUS (or DIAMETER, when `sizeMode` is `.diameter`) from the center to the
    /// cursor. Reuses the SAME computed geometry each construction mode's `preview`
    /// shows (center→cursor for `.centerRadius`; the `CircleData` from
    /// `circleFromDiameter` / `circleThrough` for the 2-/3-point modes), so the
    /// number matches what will be drawn.
    ///
    /// Empty before the first pick and after commit (every commit `reset()`s to the
    /// mode's initial waiting state, which has no live circle) and for any degenerate
    /// (zero-radius / no-finite-circle) drag — the same invariant `referenceSegments`
    /// enforces, so it never leaks into exports. The label is formatted IN-ENGINE via
    /// `CoordinateFormatter` from `ctx` (no UI dependency).
    public func liveDimensions(_ ctx: LiveDimensionContext) -> [LiveDimension] {
        guard cursor.valid else { return [] }
        switch state {
        case .settingRadius(let center):
            guard center.valid else { return [] }
            let radius = (cursor - center).magnitude
            guard radius > Tolerance.distance else { return [] }
            // ONLY the center+radius interactive state exposes an editable radius/
            // diameter (the 2P/3P modes derive the radius from picked points, so a typed
            // radius has no well-defined direction — they stay read-only).
            return [radiusDimension(center: center, to: cursor, radius: radius, ctx: ctx,
                                    editable: true)]

        case .twoSecond(let first):
            guard first.valid, let c = Self.circleFromDiameter(first, cursor) else { return [] }
            return [radiusDimension(center: c.center, to: cursor, radius: c.radius, ctx: ctx)]

        case .threeThird(let first, let second):
            guard let c = Self.circleThrough(first, second, cursor) else { return [] }
            return [radiusDimension(center: c.center, to: cursor, radius: c.radius, ctx: ctx)]

        default:
            return []
        }
    }

    /// One radius/diameter live dimension from `center` toward the cursor point
    /// `to`. In `.diameter` size mode it reports the full diameter (`2·radius`) as a
    /// `.diameter` kind; otherwise the radius as a `.radius` kind. The label is the
    /// formatted measured length; the dim line runs center→`to` and the label sits
    /// at its midpoint.
    ///
    /// `editable` stamps the dim's `field` + `isEditable` (dynamic input). Defaults to
    /// `false` so the shared 2P/3P call sites stay read-only; only the `.settingRadius`
    /// interactive state passes `editable: true`, where a typed radius/diameter has a
    /// well-defined direction (center → cursor).
    private func radiusDimension(center: Vector, to: Vector, radius: Double,
                                 ctx: LiveDimensionContext,
                                 editable: Bool = false) -> LiveDimension {
        let midpoint = (center + to) * 0.5
        switch sizeMode {
        case .diameter:
            let diameter = radius * 2
            let label = CoordinateFormatter.length(
                diameter, format: ctx.linearFormat, precision: ctx.linearPrecision, unit: ctx.unit
            )
            return LiveDimension(kind: .diameter(diameter), from: center, to: to,
                                 label: label, labelAnchor: midpoint,
                                 field: editable ? .diameter : nil, isEditable: editable)
        case .radius:
            let label = CoordinateFormatter.length(
                radius, format: ctx.linearFormat, precision: ctx.linearPrecision, unit: ctx.unit
            )
            return LiveDimension(kind: .radius(radius), from: center, to: to,
                                 label: label, labelAnchor: midpoint,
                                 field: editable ? .radius : nil, isEditable: editable)
        }
    }

    // MARK: - Dynamic input (typed radius / diameter → the on-circle point)

    /// Resolves a typed RADIUS (or DIAMETER, halved) into the on-circle point that fixes
    /// the radius, measured from the center (`reference`). Meaningful ONLY in the
    /// `.settingRadius(center:)` interactive state (the 2P/3P modes derive the radius
    /// from picks, so a typed radius has no direction) — returns `nil` otherwise. The
    /// direction is the live center→cursor unit vector; a degenerate cursor==center
    /// falls back to +X so a typed radius still yields a valid point. A field the user
    /// did not type falls back to the live radius the cursor implies.
    public func applyDynamicInput(_ values: [LiveDimensionField: Double],
                                  cursor: Vector, reference: Vector) -> Vector? {
        guard case .settingRadius = state else { return nil }
        let r = values[.radius] ?? values[.diameter].map { $0 / 2 } ?? (cursor - reference).magnitude
        let d = cursor - reference
        let u = d.magnitude > Tolerance.distance ? d / d.magnitude : Vector(angle: 0)
        return reference + u * r
    }

    // MARK: - Construction-mode command keywords (W2B)

    /// Whether the tool is still in its INITIAL waiting state (no point placed yet)
    /// for the active `mode`. The construction-mode chips are offered ONLY here:
    /// switching mode mid-draw re-mints the tool (Wave 3 reapply), which would
    /// discard in-progress picks — so it is only safe with nothing to lose.
    private var isInitialState: Bool {
        switch state {
        case .settingCenter, .twoFirst, .threeFirst,
             .ttrFirst, .tttFirst, .fromArcPick: return true
        default:                                 return false
        }
    }

    /// AutoCAD-style construction-mode options for the smart command line, shown
    /// ONLY in the initial state (before the first pick — see `isInitialState`).
    /// Returns one chip per construction mode the tool supports EXCEPT the active
    /// one, plus a size-mode toggle (`Diameter`/`Radius`, the one NOT currently in)
    /// while in `.centerRadius`. After the first pick → `[]` (mid-draw mode switching
    /// is unsafe). Dispatching a chip reuses the existing `ToolInput` events via the
    /// app's reapply path (Wave 3); see the W2B mapping table for the `CanvasModel`
    /// config each keyword sets.
    public var keywordOptions: [ToolKeyword] {
        guard isInitialState else { return [] }
        var out: [ToolKeyword] = []
        // Construction modes, excluding the currently-active one.
        if mode != .centerRadius { out.append(ToolKeyword(keyword: "Cen", label: "Center, Radius")) }
        if mode != .twoPoint     { out.append(ToolKeyword(keyword: "2P",  label: "2 Points")) }
        if mode != .threePoint   { out.append(ToolKeyword(keyword: "3P",  label: "3 Points")) }
        // Size toggle — only meaningful on the center+radius numeric path; advertise
        // the size mode we are NOT currently in.
        if mode == .centerRadius {
            switch sizeMode {
            case .radius:   out.append(ToolKeyword(keyword: "Diameter", label: "Diameter"))
            case .diameter: out.append(ToolKeyword(keyword: "Radius",   label: "Radius"))
            }
        }
        return out
    }

    /// A draw tool: it IGNORES `context` (it needs only the snapped world points)
    /// and emits new geometry as `.add` edits.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            // The ENTITY-PICK modes (TTR / TTT / from-arc) recompute their candidate
            // circle from the live context on each move (cached for the context-free
            // `preview` path). The interactive point modes derive the preview purely
            // from `cursor` + fixed points, so they only matter once a point is fixed.
            if isEntityPickMode {
                previewCircleData = computeEntityPickCircle(at: p, context: context)
                return previewCircleData == nil ? .none : .preview
            }
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
            return handleClick(p, context: context)

        case .backspace:
            return handleBackspace()

        case .cancel:
            // Esc — discard the in-progress circle and return to the initial state.
            reset()
            return .finished

        case .commit:
            // Return — when idle there is nothing pending, so end the run. (Each
            // circle is committed on its second click; there is never pending
            // geometry to flush here.)
            reset()
            return .finished
        }
    }

    // MARK: - Click / backspace handling

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        switch state {
        case .settingCenter:
            // Exact-size mode (UX-plan U2): a single click fixes the center and
            // immediately commits a circle of the configured radius, then re-arms.
            if let r = fixedRadius, p.valid {
                return commitCircle(center: p, radius: r)
            }
            // Center fixed; now rubber-band the radius toward the next click.
            state = .settingRadius(center: p)
            cursor = p
            return .none

        case .settingRadius(let center):
            // Commit one circle (center, radius = |p − center|), then re-arm.
            guard center.valid, p.valid else { return .none }
            return commitCircle(center: center, radius: (p - center).magnitude)

        // MARK: Two-point (diameter) mode

        case .twoFirst:
            // First diameter endpoint fixed; rubber-band toward the second.
            guard p.valid else { return .none }
            state = .twoSecond(first: p)
            cursor = p
            return .none

        case .twoSecond(let first):
            // Second diameter endpoint: center = midpoint, radius = half-distance.
            guard let c = Self.circleFromDiameter(first, p) else { return .none }
            return commitCircle(center: c.center, radius: c.radius)

        // MARK: Three-point mode

        case .threeFirst:
            guard p.valid else { return .none }
            state = .threeSecond(first: p)
            cursor = p
            return .none

        case .threeSecond(let first):
            // Need a second point distinct from the first; a coincident pick waits.
            guard p.valid, (p - first).magnitude > Tolerance.distance else { return .none }
            state = .threeThird(first: first, second: p)
            cursor = p
            return .none

        case .threeThird(let first, let second):
            // Third pick closes the circle through the three points. Collinear /
            // coincident picks have no finite circle — ignore and keep waiting.
            guard let c = Self.circleThrough(first, second, p) else { return .none }
            return commitCircle(center: c.center, radius: c.radius)

        // MARK: Tangent–Tangent–Radius (TTR)

        case .ttrFirst:
            // Pick the first tangent entity (line / circle / arc) under the click.
            guard let first = Self.nearestTangentEntity(at: p, exclude: nil, context: context) else {
                return .none
            }
            state = .ttrSecond(first: first)
            cursor = p
            previewCircleData = nil
            return .none

        case .ttrSecond:
            // Pick the second tangent entity, solve, and commit the candidate circle
            // whose center is nearest the click.
            guard let c = computeEntityPickCircle(at: p, context: context) else { return .none }
            return commitCircle(center: c.center, radius: c.radius)

        // MARK: Tangent–Tangent–Tangent (inscribe, TTT)

        case .tttFirst:
            guard let first = Self.nearestTangentEntity(at: p, exclude: nil, context: context) else {
                return .none
            }
            state = .tttSecond(first: first)
            cursor = p
            previewCircleData = nil
            return .none

        case .tttSecond(let first):
            guard let second = Self.nearestTangentEntity(at: p, exclude: first.id, context: context) else {
                return .none
            }
            state = .tttThird(first: first, second: second)
            cursor = p
            previewCircleData = nil
            return .none

        case .tttThird:
            guard let c = computeEntityPickCircle(at: p, context: context) else { return .none }
            return commitCircle(center: c.center, radius: c.radius)

        // MARK: From-arc (complete a picked arc/circle to a full circle)

        case .fromArcPick:
            guard let c = computeEntityPickCircle(at: p, context: context) else { return .none }
            return commitCircle(center: c.center, radius: c.radius)
        }
    }

    /// Builds + commits one circle, then resets to draw the next. A degenerate
    /// (zero-radius) circle is ignored (returns `.none`, keeps the current state).
    /// Shared by the two-click center+radius commit and the exact-size single-click
    /// commit.
    private mutating func commitCircle(center: Vector, radius: Double) -> ToolOutcome {
        guard center.valid, radius > Tolerance.distance else { return .none }
        let record = EntityRecord(
            id: .placeholder,
            kind: .circle(CircleData(center: center, radius: radius))
        )
        reset()
        return .commit([.add(record)])
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingCenter, .twoFirst, .threeFirst,
             .ttrFirst, .tttFirst, .fromArcPick:
            // Nothing to step back (waiting for the first pick of the mode).
            return .none
        case .settingRadius:
            // Step the radius pick back to before the center was fixed.
            reset()
            return .preview
        case .twoSecond:
            // Undo the first diameter endpoint → back to the initial state.
            reset()
            return .preview
        case .threeSecond:
            // Undo the first three-point pick → back to the initial state.
            reset()
            return .preview
        case .threeThird(let first, _):
            // Undo the second three-point pick → back to waiting for it, keep first.
            state = .threeSecond(first: first)
            cursor = first
            return .preview

        case .ttrSecond, .tttSecond:
            // Undo the first tangent pick → back to the initial state.
            reset()
            return .preview

        case .tttThird(let first, _):
            // Undo the second tangent pick → back to waiting for it, keep the first.
            state = .tttSecond(first: first)
            previewCircleData = nil
            return .preview
        }
    }

    /// Returns to the initial waiting-for-first-pick state for the active `mode`.
    private mutating func reset() {
        state = Self.initialState(for: mode)
        cursor = .invalid
        previewCircleData = nil
    }

    // MARK: - Entity-pick modes (TTR / TTT / from-arc)

    /// Whether the active `mode` picks ENTITIES (not points) — TTR, TTT, from-arc.
    /// These read `context.nearbyEntities` and cache their candidate circle for the
    /// context-free `preview`; the point modes don't.
    private var isEntityPickMode: Bool {
        switch mode {
        case .tanTanRadius, .tanTanTan, .fromArc: return true
        case .centerRadius, .twoPoint, .threePoint: return false
        }
    }

    /// The candidate circle for the current entity-pick state, given a click/cursor
    /// `p` and the live context. Drives BOTH the `.move` preview and the committing
    /// click. `nil` when the pick is invalid or no tangent/from-arc circle results.
    ///
    /// - TTR (`.ttrSecond`): picks the second tangent entity under `p`, solves every
    ///   circle of radius `fixedRadius` tangent to both, and keeps the one whose
    ///   center is NEAREST `p` (the user steers the solution by where they click).
    ///   Requires a positive `fixedRadius`.
    /// - TTT (`.tttThird`): picks the third tangent entity and solves the
    ///   incircle/excircle (three-line case) nearest `p`.
    /// - from-arc (`.fromArcPick`): picks an arc/circle under `p` and completes it to
    ///   a full circle (same center + radius).
    private func computeEntityPickCircle(at p: Vector, context: ToolContext) -> CircleData? {
        switch state {
        case .ttrSecond(let first):
            guard let r = fixedRadius else { return nil }
            guard let second = Self.nearestTangentEntity(at: p, exclude: first.id, context: context) else {
                return nil
            }
            let centers = Self.tangentCenters(first: first, second: second, radius: r)
            let center = SnapGeometry.closestCenter(centers, to: p)
            guard center.valid else { return nil }
            return CircleData(center: center, radius: r)

        case .tttThird(let first, let second):
            guard let third = Self.nearestTangentEntity(at: p, exclude: nil, context: context),
                  third.id != first.id, third.id != second.id else { return nil }
            let solutions = Self.inscribedCircles(first: first, second: second, third: third)
            // Keep the (center, radius) whose center is nearest the pick.
            let center = SnapGeometry.closestCenter(solutions.map(\.center), to: p)
            guard center.valid, let hit = solutions.first(where: { $0.center == center }) else {
                return nil
            }
            return CircleData(center: hit.center, radius: hit.radius)

        case .fromArcPick:
            guard let e = Self.nearestTangentEntity(at: p, exclude: nil, context: context) else {
                return nil
            }
            return Self.circleCompleting(e)

        default:
            return nil
        }
    }

    /// The nearest LINE / CIRCLE / ARC within the pick aperture of `p`, optionally
    /// excluding one id (so the second/third pick can't re-pick an earlier one). Other
    /// kinds are skipped. Mirrors `FilletTool.nearestLine`'s exact-distance pick but
    /// accepts the tangent-able primitive kinds.
    static func nearestTangentEntity(at p: Vector, exclude: EntityID?, context: ToolContext) -> EntityRecord? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: EntityRecord?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) where e.id != exclude {
            switch e.kind {
            case .line, .circle, .arc:
                let d = HitTesting.worldDistance(from: p, to: e)
                if d < bestDist { bestDist = d; best = e }
            default:
                continue
            }
        }
        return best
    }

    /// The pick tolerance aperture in world units (mirrors `FilletTool.pickTolerance`):
    /// half the grid spacing when present, else a small fixed default.
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance { return g * 0.5 }
        return 0.5
    }

    /// All centers of a circle of `radius` tangent to BOTH picked entities (TTR),
    /// dispatched on the pair's kinds through the `SnapGeometry` solvers. Returns `[]`
    /// for a kind pair this build doesn't solve (e.g. an ellipse) — a graceful no-op.
    static func tangentCenters(first: EntityRecord, second: EntityRecord, radius r: Double) -> [Vector] {
        switch (first.kind, second.kind) {
        case (.line(let a), .line(let b)):
            return SnapGeometry.tangentCircleCentersLineLine(
                r: r, a0: a.start, a1: a.end, b0: b.start, b1: b.end)
        case (.line(let a), .circle(let c)):
            return SnapGeometry.tangentCircleCentersLineCircle(
                r: r, a0: a.start, a1: a.end, center: c.center, radius: c.radius)
        case (.circle(let c), .line(let a)):
            return SnapGeometry.tangentCircleCentersLineCircle(
                r: r, a0: a.start, a1: a.end, center: c.center, radius: c.radius)
        case (.line(let a), .arc(let arc)):
            return SnapGeometry.tangentCircleCentersLineCircle(
                r: r, a0: a.start, a1: a.end, center: arc.center, radius: arc.radius)
        case (.arc(let arc), .line(let a)):
            return SnapGeometry.tangentCircleCentersLineCircle(
                r: r, a0: a.start, a1: a.end, center: arc.center, radius: arc.radius)
        case (.circle(let c1), .circle(let c2)):
            return SnapGeometry.tangentCircleCentersCircleCircle(
                r: r, c1: c1.center, radius1: c1.radius, c2: c2.center, radius2: c2.radius)
        case (.circle(let c), .arc(let arc)), (.arc(let arc), .circle(let c)):
            return SnapGeometry.tangentCircleCentersCircleCircle(
                r: r, c1: c.center, radius1: c.radius, c2: arc.center, radius2: arc.radius)
        case (.arc(let a1), .arc(let a2)):
            return SnapGeometry.tangentCircleCentersCircleCircle(
                r: r, c1: a1.center, radius1: a1.radius, c2: a2.center, radius2: a2.radius)
        default:
            return []
        }
    }

    /// Every circle tangent to all THREE picked entities (TTT). This build solves the
    /// THREE-LINE case (triangle incircle + excircles); any non-line reference yields
    /// `[]` (a graceful no-op — mixed line/circle Apollonius is deferred, see the file
    /// header / brief). Returns `(center, radius)` per solution.
    static func inscribedCircles(first: EntityRecord, second: EntityRecord,
                                 third: EntityRecord) -> [(center: Vector, radius: Double)] {
        guard case .line(let a) = first.kind,
              case .line(let b) = second.kind,
              case .line(let c) = third.kind else { return [] }
        return SnapGeometry.tangentCirclesThreeLines(
            a0: a.start, a1: a.end, b0: b.start, b1: b.end, d0: c.start, d1: c.end)
    }

    /// The full circle COMPLETING a picked arc/circle (from-arc): same center + radius.
    /// A circle pick already IS a full circle (returns it); a line/other → `nil`.
    static func circleCompleting(_ e: EntityRecord) -> CircleData? {
        switch e.kind {
        case .arc(let arc):
            guard arc.radius > Tolerance.distance else { return nil }
            return CircleData(center: arc.center, radius: arc.radius)
        case .circle(let c):
            guard c.radius > Tolerance.distance else { return nil }
            return CircleData(center: c.center, radius: c.radius)
        default:
            return nil
        }
    }

    // MARK: - Construction geometry (pure, side-effect-free; unit-tested directly)

    /// The circle whose DIAMETER endpoints are `a` and `b`: center = midpoint,
    /// radius = half the distance. `nil` when the two points coincide (degenerate,
    /// zero radius) or either is invalid.
    static func circleFromDiameter(_ a: Vector, _ b: Vector) -> CircleData? {
        guard a.valid, b.valid else { return nil }
        let radius = (b - a).magnitude / 2
        guard radius > Tolerance.distance else { return nil }
        let center = (a + b) / 2
        return CircleData(center: center, radius: radius)
    }

    /// The unique circle passing THROUGH the three points `a`, `b`, `c` (their
    /// circumcircle), or `nil` when they are collinear / coincident (no finite
    /// circle). Uses the perpendicular-bisector determinant — the same circumcenter
    /// math as `ArcTool.arcThrough`, returning just center + radius.
    static func circleThrough(_ a: Vector, _ b: Vector, _ c: Vector) -> CircleData? {
        guard a.valid, b.valid, c.valid else { return nil }
        // `d` is twice the signed area of triangle abc; zero exactly when the three
        // points are collinear (or two coincide), which has no finite circle.
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > Tolerance.distance else { return nil }
        let a2 = a.x * a.x + a.y * a.y
        let b2 = b.x * b.x + b.y * b.y
        let c2 = c.x * c.x + c.y * c.y
        let ux = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d
        let uy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d
        let center = Vector(ux, uy)
        let radius = (a - center).magnitude
        guard radius > Tolerance.distance else { return nil }
        return CircleData(center: center, radius: radius)
    }
}
