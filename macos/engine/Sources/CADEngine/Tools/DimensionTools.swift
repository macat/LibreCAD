//
//  DimensionTools.swift
//  CADEngine
//
//  The four interactive DIMENSION creation tools — LinearDimTool, AlignedDimTool,
//  RadialDimTool, AngularDimTool — built against the FROZEN `Tool` contract and
//  mirroring the existing draw/edit tools exactly (private `enum State`, pure value
//  types, no CADDrawing/Quadtree/GUI access). They author the `.dimension` entity
//  (`DimData` + `DimKind`) whose graphic is computed in `resolve()` (ADR-001), so
//  each tool just places the DEFINING points and emits one
//  `.add(EntityRecord(kind: .dimension(...)))`.
//
//  Ported in spirit from LibreCAD's `RS_ActionDimLinear` / `RS_ActionDimAligned`
//  / `RS_ActionDimRadial` / `RS_ActionDimDiametric` / `RS_ActionDimAngular`
//  (librecad/src/lib/actions/drawing/dimensions/), with the magic `int m_status`
//  replaced by an exhaustive private `enum State` carrying the picks made so far.
//
//  LIVE PREVIEW: each tool builds the in-progress `DimData` from the picks + the
//  current cursor and RESOLVES it (`EntityKind.dimension(d).resolve(pen:ctx:)`),
//  taking the resolved `.polylines` as the rubber-band overlay (the same
//  resolve-for-preview pattern `FilletTool` uses). Arrowheads (resolved `.fills`)
//  and text glyph fills are omitted from the line-only preview overlay; the final
//  committed dimension renders them.
//
//  PURE: these tools never touch CADDrawing/Quadtree/GUI. They receive already-
//  snapped world points and return outcomes/preview. The radial/angular tools read
//  the read-only `ToolContext` boundary hook (`nearbyEntities`) to pick the circle/
//  arc / line they dimension; the linear/aligned tools ignore `context`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDim* family).
//

import Foundation

// MARK: - Shared dimension-tool helpers

/// Helpers shared by the four dimension tools: building a line-only preview from a
/// resolved `DimData`, and the pick aperture used by the entity-picking variants.
/// (Free functions in this file's scope — kept off the protocol so the tools stay
/// pure value types.)
enum DimToolSupport {

    /// Resolves a `DimData` and returns ONLY its polylines, recolored with the
    /// preview pen, as the live rubber-band overlay. Mirrors `FilletTool`'s
    /// resolve-for-preview (arrowhead/text fills are dropped — the overlay is
    /// line-only). Returns `[]` when the data resolves to nothing (degenerate).
    static func previewLines(_ data: DimData,
                             ctx: ResolveContext = .default) -> [ResolvedPolyline] {
        let geo = EntityKind.dimension(data).resolve(pen: .toolPreview, ctx: ctx)
        // The resolve uses the pen we pass for the lines, so they are already the
        // preview pen; return them directly.
        return geo.polylines
    }

    /// The pick aperture in world units for the entity-picking variants (radial /
    /// angular line pick): a fraction of the grid spacing when present, else a
    /// small fixed default. Mirrors `FilletTool.pickTolerance` / `TrimTool`.
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance {
            return g * 0.5
        }
        return 0.5
    }

    /// The nearest circle or arc within the pick aperture of `p`, or `nil`. Returns
    /// the picked record together with its `center`/`radius` (the only fields the
    /// radial/diameter tools need). Non-circle/arc kinds are skipped.
    static func nearestCircular(at p: Vector,
                                context: ToolContext) -> (record: EntityRecord, center: Vector, radius: Double)? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: (record: EntityRecord, center: Vector, radius: Double)?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) {
            let cr: (Vector, Double)?
            switch e.kind {
            case .circle(let c): cr = (c.center, c.radius)
            case .arc(let a):    cr = (a.center, a.radius)
            default:             cr = nil
            }
            guard let (center, radius) = cr, radius > Tolerance.distance else { continue }
            let d = HitTesting.worldDistance(from: p, to: e)
            if d < bestDist {
                bestDist = d
                best = (e, center, radius)
            }
        }
        return best
    }

    /// The nearest LINE within the pick aperture of `p`, returned as its two
    /// endpoints `(start, end)`, or `nil`. Used by the angular tool's line-pick
    /// path (click a line to use it directly as one of the two angular rays).
    static func nearestLine(at p: Vector, exclude: EntityID?,
                            context: ToolContext) -> (id: EntityID, start: Vector, end: Vector)? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: (id: EntityID, start: Vector, end: Vector)?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) where e.id != exclude {
            guard case .line(let l) = e.kind else { continue }
            let d = HitTesting.worldDistance(from: p, to: e)
            if d < bestDist {
                bestDist = d
                best = (e.id, l.start, l.end)
            }
        }
        return best
    }
}

// MARK: - LinearDimTool (horizontal / vertical / free linear dimension)

/// The interactive Linear dimension tool. Click the two extension-line origins,
/// then a third point for the dimension-line location. Commits one `.linear`
/// dimension measuring the distance between the two origins along a fixed
/// direction (horizontal, vertical, or — in `.free` orientation — along the line
/// through the two origins).
///
/// Click sequence:
///   1. extension origin #1   (State.settingFirst → .settingSecond)
///   2. extension origin #2   (.settingSecond → .settingLine)
///   3. dimension-line location → `DimData.definitionPoint`; commit `.linear`
///      with the two origins + the orientation's measurement `angle`, then RESET.
public struct LinearDimTool: Tool {

    /// The measurement direction the linear dimension is locked to.
    public enum Orientation: Sendable, Equatable {
        /// Measure the horizontal component (angle 0). The default — DXF
        /// `DIMLINEAR` with rotation 0.
        case horizontal
        /// Measure the vertical component (angle π/2).
        case vertical
        /// Measure along the line through the two origins (angle = atan2 of
        /// origin2 − origin1) — a rotated linear dimension.
        case free

        /// The fixed measurement angle (radians) for `DimKind.linear`.
        func angle(from p1: Vector, to p2: Vector) -> Double {
            switch self {
            case .horizontal: return 0
            case .vertical:   return Double.pi / 2
            case .free:       return (p2 - p1).angle
            }
        }
    }

    private enum State: Equatable {
        case settingFirst
        case settingSecond(first: Vector)
        case settingLine(first: Vector, second: Vector)
    }

    private var state: State = .settingFirst
    private var cursor: Vector = .invalid

    /// The measurement-direction lock. Default `.horizontal`.
    public var orientation: Orientation

    public init(orientation: Orientation = .horizontal) {
        self.orientation = orientation
    }

    public var title: String {
        switch orientation {
        case .horizontal: return "Linear Dimension"
        case .vertical:   return "Vertical Dimension"
        case .free:       return "Rotated Dimension"
        }
    }

    public var status: String {
        switch state {
        case .settingFirst:  return "Specify first extension line origin"
        case .settingSecond: return "Specify second extension line origin"
        case .settingLine:   return "Specify dimension line location"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingLine(let first, let second) = state,
              cursor.valid, first.valid, second.valid else { return [] }
        let data = DimData(
            kind: .linear(extension1: first, extension2: second,
                          angle: orientation.angle(from: first, to: second)),
            definitionPoint: cursor
        )
        return DimToolSupport.previewLines(data)
    }

    /// A draw tool: it IGNORES `context` and emits the new dimension as `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next origin/leader point like a click.
            return handleClick(p)
        case .backspace:
            return handleBackspace()
        case .cancel:
            reset()
            return .finished
        case .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingFirst:
            state = .settingSecond(first: p)
            cursor = p
            return .none
        case .settingSecond(let first):
            // Ignore a coincident second origin (degenerate zero-length dim).
            guard p.distance(to: first) > Tolerance.distance else { return .none }
            state = .settingLine(first: first, second: p)
            cursor = p
            return .none
        case .settingLine(let first, let second):
            let record = EntityRecord(
                id: .placeholder,
                kind: .dimension(DimData(
                    kind: .linear(extension1: first, extension2: second,
                                  angle: orientation.angle(from: first, to: second)),
                    definitionPoint: p
                ))
            )
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingFirst:
            return .none
        case .settingSecond:
            reset()
            return .preview
        case .settingLine(let first, _):
            state = .settingSecond(first: first)
            cursor = first
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingFirst
        cursor = .invalid
    }
}

// MARK: - AlignedDimTool (aligned / true-distance dimension)

/// The interactive Aligned dimension tool. Click two points, then an offset point
/// for the dimension-line location. Commits one `.aligned` dimension measuring the
/// TRUE distance between the two points (the dimension line runs parallel to the
/// line through them, offset to pass through the location point).
///
/// Click sequence:
///   1. extension origin #1   (.settingFirst → .settingSecond)
///   2. extension origin #2   (.settingSecond → .settingLine)
///   3. dimension-line offset → `DimData.definitionPoint`; commit `.aligned`,
///      then RESET.
public struct AlignedDimTool: Tool {

    private enum State: Equatable {
        case settingFirst
        case settingSecond(first: Vector)
        case settingLine(first: Vector, second: Vector)
    }

    private var state: State = .settingFirst
    private var cursor: Vector = .invalid

    public init() {}

    public var title: String { "Aligned Dimension" }

    public var status: String {
        switch state {
        case .settingFirst:  return "Specify first extension line origin"
        case .settingSecond: return "Specify second extension line origin"
        case .settingLine:   return "Specify dimension line location"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingLine(let first, let second) = state,
              cursor.valid, first.valid, second.valid else { return [] }
        let data = DimData(
            kind: .aligned(extension1: first, extension2: second),
            definitionPoint: cursor
        )
        return DimToolSupport.previewLines(data)
    }

    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next origin/leader point like a click.
            return handleClick(p)
        case .backspace:
            return handleBackspace()
        case .cancel:
            reset()
            return .finished
        case .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingFirst:
            state = .settingSecond(first: p)
            cursor = p
            return .none
        case .settingSecond(let first):
            guard p.distance(to: first) > Tolerance.distance else { return .none }
            state = .settingLine(first: first, second: p)
            cursor = p
            return .none
        case .settingLine(let first, let second):
            let record = EntityRecord(
                id: .placeholder,
                kind: .dimension(DimData(
                    kind: .aligned(extension1: first, extension2: second),
                    definitionPoint: p
                ))
            )
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingFirst:
            return .none
        case .settingSecond:
            reset()
            return .preview
        case .settingLine(let first, _):
            state = .settingSecond(first: first)
            cursor = first
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingFirst
        cursor = .invalid
    }
}

// MARK: - RadialDimTool (radius "R…" / diameter "⌀…")

/// The interactive Radial / Diameter dimension tool. Click a circle or arc, then a
/// point for the leader / text location. In `.radius` mode commits a `.radial`
/// dimension ("R…"); in `.diameter` mode commits a `.diameter` dimension ("⌀…").
///
/// Click sequence:
///   1. a circle / arc (picked via `context.nearbyEntities`) — fixes the center +
///      radius (.settingEntity → .settingLeader).
///   2. leader / text point → `DimData.definitionPoint`; the point also chooses
///      which side of the circle the leader points to (the point ON the circle is
///      the radius in the direction of the click). Commit `.radial` or
///      `.diameter`, then RESET.
public struct RadialDimTool: Tool {

    /// Whether the tool authors a radius (`.radial`) or a diameter (`.diameter`).
    public enum Mode: Sendable, Equatable {
        case radius
        case diameter
    }

    private enum State: Equatable {
        case settingEntity
        case settingLeader(center: Vector, radius: Double)
    }

    private var state: State = .settingEntity
    private var cursor: Vector = .invalid

    /// Radius vs diameter. Default `.radius`.
    public var mode: Mode

    public init(mode: Mode = .radius) {
        self.mode = mode
    }

    public var title: String { mode == .radius ? "Radius Dimension" : "Diameter Dimension" }

    public var status: String {
        switch state {
        case .settingEntity: return "Select arc or circle"
        case .settingLeader: return "Specify dimension line location"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingLeader(let center, let radius) = state,
              cursor.valid, center.valid, radius > Tolerance.distance,
              let data = makeData(center: center, radius: radius, leader: cursor) else {
            return []
        }
        return DimToolSupport.previewLines(data)
    }

    /// Builds the `DimData` for the picked circle + leader point. The leader point
    /// chooses the DIRECTION from the center; the point on the circle is the radius
    /// in that direction. `definitionPoint` is the leader point itself (where the
    /// text/leader is dragged to).
    private func makeData(center: Vector, radius: Double, leader: Vector) -> DimData? {
        let dir = leader - center
        let len = dir.magnitude
        // Degenerate: leader exactly on the center — no direction to point.
        guard len > Tolerance.distance else { return nil }
        let unit = dir / len
        switch mode {
        case .radius:
            let pointOnCircle = center + unit * radius
            return DimData(
                kind: .radial(center: center, pointOnCircle: pointOnCircle),
                definitionPoint: leader
            )
        case .diameter:
            // Two opposite points on the circle along the leader direction.
            let p1 = center - unit * radius
            let p2 = center + unit * radius
            return DimData(
                kind: .diameter(point1: p1, point2: p2),
                definitionPoint: leader
            )
        }
    }

    /// A draw-from-pick tool: reads `context.nearbyEntities` on the FIRST click to
    /// pick the circle/arc, then emits the new dimension as `.add`.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next pick point like a click.
            return handleClick(p, context: context)
        case .backspace:
            return handleBackspace()
        case .cancel:
            reset()
            return .finished
        case .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingEntity:
            // Pick the nearest circle/arc under the click; ignore a miss.
            guard let hit = DimToolSupport.nearestCircular(at: p, context: context) else {
                return .none
            }
            state = .settingLeader(center: hit.center, radius: hit.radius)
            cursor = p
            return .none
        case .settingLeader(let center, let radius):
            guard let data = makeData(center: center, radius: radius, leader: p) else {
                // Leader on the center — keep waiting for a usable leader point.
                return .none
            }
            let record = EntityRecord(id: .placeholder, kind: .dimension(data))
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingEntity:
            return .none
        case .settingLeader:
            reset()
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingEntity
        cursor = .invalid
    }
}

// MARK: - AngularDimTool (angle between two lines / segments)

/// The interactive Angular dimension tool. Define two rays, then click a point for
/// the dimension-arc location. Commits one `.angular` dimension; the arc-location
/// click chooses WHICH of the four sectors the dimension spans (it becomes
/// `DimData.definitionPoint`, and the resolve's sector selection — `dimAngular
/// Geometry` — picks the sector the def point sits in).
///
/// Two ways to define each of the two rays (the tool accepts a mix):
///   - LINE PICK: if a click lands on a line entity (via `context.nearbyEntities`),
///     that whole line is consumed as one ray (one click).
///   - POINT PAIR: otherwise the click is the ray's start; a second click fixes its
///     end (two clicks). So "4 points = two line segments" works with no entities.
///
/// State carries the two rays as `(start, end)` pairs. The ray END points are the
/// reference directions the resolve uses (`a1 = angle(line1End − vertex)`,
/// `a2 = angle(line2End − vertex)`), so for a line-pick the picked line's
/// (start, end) are used as-is.
///
/// Final click sequence (point-pair form):
///   1. ray1 start          (.settingLine1Start → .settingLine1End)
///   2. ray1 end            (.settingLine1End → .settingLine2Start)
///   3. ray2 start          (.settingLine2Start → .settingLine2End)
///   4. ray2 end            (.settingLine2End → .settingArc)
///   5. arc location → `definitionPoint`; commit `.angular`, then RESET.
public struct AngularDimTool: Tool {

    private enum State: Equatable {
        case settingLine1Start
        case settingLine1End(start: Vector)
        case settingLine2Start(line1: Segment)
        case settingLine2End(line1: Segment, start: Vector)
        case settingArc(line1: Segment, line2: Segment)
    }

    /// A directed ray segment (start → end). The END is the reference direction the
    /// resolve measures from the vertex.
    private struct Segment: Equatable {
        var start: Vector
        var end: Vector
    }

    private var state: State = .settingLine1Start
    private var cursor: Vector = .invalid

    public init() {}

    public var title: String { "Angular Dimension" }

    public var status: String {
        switch state {
        case .settingLine1Start: return "Select first line or specify first point"
        case .settingLine1End:   return "Specify second point of first line"
        case .settingLine2Start: return "Select second line or specify first point"
        case .settingLine2End:   return "Specify second point of second line"
        case .settingArc:        return "Specify dimension arc location"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard case .settingArc(let l1, let l2) = state, cursor.valid,
              l1.start.valid, l1.end.valid, l2.start.valid, l2.end.valid else {
            return []
        }
        let data = DimData(
            kind: .angular(line1Start: l1.start, line1End: l1.end,
                           line2Start: l2.start, line2End: l2.end),
            definitionPoint: cursor
        )
        return DimToolSupport.previewLines(data)
    }

    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next pick point like a click.
            return handleClick(p, context: context)
        case .backspace:
            return handleBackspace()
        case .cancel:
            reset()
            return .finished
        case .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .settingLine1Start:
            // Try a line entity first; if hit, consume the whole line as ray1.
            if let line = DimToolSupport.nearestLine(at: p, exclude: nil, context: context) {
                state = .settingLine2Start(line1: Segment(start: line.start, end: line.end))
            } else {
                state = .settingLine1End(start: p)
            }
            cursor = p
            return .none

        case .settingLine1End(let start):
            guard p.distance(to: start) > Tolerance.distance else { return .none }
            state = .settingLine2Start(line1: Segment(start: start, end: p))
            cursor = p
            return .none

        case .settingLine2Start(let line1):
            if let line = DimToolSupport.nearestLine(at: p, exclude: nil, context: context) {
                state = .settingArc(line1: line1, line2: Segment(start: line.start, end: line.end))
            } else {
                state = .settingLine2End(line1: line1, start: p)
            }
            cursor = p
            return .none

        case .settingLine2End(let line1, let start):
            guard p.distance(to: start) > Tolerance.distance else { return .none }
            state = .settingArc(line1: line1, line2: Segment(start: start, end: p))
            cursor = p
            return .none

        case .settingArc(let line1, let line2):
            // The arc-location click becomes the definition point, which SELECTS
            // the sector (the resolve's dimAngularGeometry spans the sector the def
            // point sits in).
            let record = EntityRecord(
                id: .placeholder,
                kind: .dimension(DimData(
                    kind: .angular(line1Start: line1.start, line1End: line1.end,
                                   line2Start: line2.start, line2End: line2.end),
                    definitionPoint: p
                ))
            )
            reset()
            return .commit([.add(record)])
        }
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .settingLine1Start:
            return .none
        case .settingLine1End:
            reset()
            return .preview
        case .settingLine2Start:
            // Step back to re-pick ray1 from scratch (a line pick was a single
            // click, so the previous state is the initial one either way).
            reset()
            return .preview
        case .settingLine2End(let line1, _):
            state = .settingLine2Start(line1: line1)
            cursor = line1.end
            return .preview
        case .settingArc(let line1, _):
            // Re-pick ray2's end (keep ray1 + ray2's start). A line-picked ray2
            // had no separate start click; stepping back to its start point is the
            // closest sensible step.
            state = .settingLine2End(line1: line1, start: line1.end)
            cursor = line1.end
            return .preview
        }
    }

    private mutating func reset() {
        state = .settingLine1Start
        cursor = .invalid
    }
}
