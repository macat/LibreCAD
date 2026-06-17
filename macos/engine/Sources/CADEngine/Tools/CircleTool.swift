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
    }

    /// The current state. Set in `init` from the `mode`.
    private var state: State

    /// The last cursor point seen via `.move`, used to draw the rubber-band even
    /// between clicks. Invalid until the first move.
    private var cursor: Vector = .invalid

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
        case .settingCenter, .twoFirst, .threeFirst: return true
        default:                                      return false
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
            // A move only matters for the preview once the center is fixed.
            return preview.isEmpty ? .none : .preview

        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point exactly like a click.
            return handleClick(p)

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

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
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
        case .settingCenter, .twoFirst, .threeFirst:
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
        }
    }

    /// Returns to the initial waiting-for-first-pick state for the active `mode`.
    private mutating func reset() {
        state = Self.initialState(for: mode)
        cursor = .invalid
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
