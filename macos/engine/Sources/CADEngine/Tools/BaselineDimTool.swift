//
//  BaselineDimTool.swift
//  CADEngine
//
//  The interactive BASELINE linear-dimension tool — a "chained" dimension creator
//  built against the FROZEN `Tool` contract and mirroring the existing dimension
//  tools exactly (private `enum State`, pure value type, no CADDrawing/Quadtree/GUI
//  access). It authors a run of `.linear` dimensions that all measure from a COMMON
//  first extension origin (the *baseline*), each successive dimension drawn at a
//  dimension line offset further OUT from the baseline (so the dims stack without
//  overlapping). Each pick emits one `.add(EntityRecord(kind: .dimension(.linear)))`.
//
//  Ported in spirit from LibreCAD's `RS_ActionDimLinearBase`
//  (librecad/src/lib/actions/drawing/dimensions/), with the magic `int m_status`
//  replaced by an exhaustive private `enum State` and DIMDLI (the baseline spacing)
//  modeled as a tool property (the DIMDLI dim-style variable is not yet plumbed
//  into the macOS engine; the default mirrors AutoCAD's proportional fallback).
//
//  ## How a baseline run works
//  1. Pick the BASELINE dimension — either by clicking an existing `.linear`/
//     `.aligned` dimension entity (the tool reads it from `context.nearbyEntities`)
//     OR, when none is under the pick, by clicking the two points that define the
//     first dimension's extension origins + its dimension-line location (the same
//     3-click sequence as `LinearDimTool`, committed as the run's first dim).
//  2. Click each successive FEATURE point → a new `.linear` dimension is committed
//     sharing the baseline's first extension origin (`origin1`) and measurement
//     `angle`, with its `definitionPoint` slid one more DIMDLI step further out
//     along the dimension-line normal (away from the measured points), so the dims
//     stack. The run continues until `.commit`/`.cancel`.
//
//  PURE: this tool never touches CADDrawing/Quadtree/GUI. It receives already-
//  snapped world points and returns outcomes/preview. It consumes the existing
//  `DimData`/`DimKind.linear` model unchanged (the document dim style for text
//  height / arrow size is applied later in `resolve()` via `dimStyleProvider`).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDimLinearBase).
//

import Foundation

// MARK: - Shared chained-dimension helpers

/// Helpers shared by the two chained-dimension tools (`BaselineDimTool` /
/// `ContinueDimTool`): picking a base linear/aligned dimension under a click and
/// the dimension-line geometry math (direction / normal / perpendicular offset).
/// Free `static` members of a namespaced enum so the tools stay pure value types
/// (per CONVENTIONS §7.7 — no module-scope free functions).
enum ChainDimSupport {

    /// A flattened view of a linear/aligned dimension's defining geometry — the two
    /// extension origins, the measurement direction `angle`, and the dimension-line
    /// `definitionPoint` — extracted from a base dimension so the chained tools can
    /// derive their own dims from it. `aligned` reports its measurement angle as the
    /// direction through its two origins (the same convention `resolve()` uses).
    struct LinearBase: Equatable {
        var origin1: Vector
        var origin2: Vector
        var angle: Double
        var definitionPoint: Vector
    }

    /// The pick aperture in world units for selecting the base dimension: a fraction
    /// of the grid spacing when present, else a small fixed default. Mirrors
    /// `DimToolSupport.pickTolerance`.
    static func pickTolerance(_ context: ToolContext) -> Double {
        if let g = context.gridSpacing, g > Tolerance.distance {
            return g * 0.5
        }
        return 0.5
    }

    /// The nearest LINEAR or ALIGNED dimension within the pick aperture of `p`,
    /// flattened to a `LinearBase`, or `nil`. Radial/diameter/angular/ordinate/
    /// arc-length dims are skipped (only linear-style dims can be chained). Used by
    /// both chained tools' base-pick path.
    static func nearestLinearBase(at p: Vector, context: ToolContext) -> LinearBase? {
        guard p.valid else { return nil }
        let tol = pickTolerance(context)
        var best: LinearBase?
        var bestDist = Double.greatestFiniteMagnitude
        for e in context.nearbyEntities(p, tol) {
            guard case .dimension(let d) = e.kind else { continue }
            let base: LinearBase?
            switch d.kind {
            case .linear(let e1, let e2, let angle):
                base = LinearBase(origin1: e1, origin2: e2, angle: angle,
                                  definitionPoint: d.definitionPoint)
            case .aligned(let e1, let e2):
                base = LinearBase(origin1: e1, origin2: e2, angle: (e2 - e1).angle,
                                  definitionPoint: d.definitionPoint)
            default:
                base = nil
            }
            guard let b = base else { continue }
            let dist = HitTesting.worldDistance(from: p, to: e)
            if dist < bestDist {
                bestDist = dist
                best = b
            }
        }
        return best
    }

    /// The unit dimension-line direction for a measurement `angle` (radians).
    static func dirUnit(angle: Double) -> Vector { Vector(angle: angle) }

    /// The unit dimension-line normal (perpendicular to `dirUnit(angle:)`).
    static func normalUnit(angle: Double) -> Vector {
        let d = dirUnit(angle: angle)
        return Vector(-d.y, d.x)
    }

    /// The signed perpendicular offset of point `p` from the dimension line that
    /// passes through `origin1` (i.e. `(p − origin1)·normal`), for a measurement
    /// `angle`. The dimension line for a given level sits at a fixed value of this
    /// signed offset; `BaselineDimTool` steps it outward, `ContinueDimTool` holds it.
    static func perpendicularOffset(of p: Vector, from origin1: Vector, angle: Double) -> Double {
        (p - origin1).dot(normalUnit(angle: angle))
    }

    /// A `definitionPoint` placing the dimension line at the given signed
    /// perpendicular `offset` from `origin1` (along the measurement `angle`'s
    /// normal). Any point on that line is a valid `definitionPoint` (the dim line is
    /// infinite along `dirUnit`); this returns `origin1 + normal·offset`.
    static func definitionPoint(from origin1: Vector, angle: Double, offset: Double) -> Vector {
        origin1 + normalUnit(angle: angle) * offset
    }

}

// MARK: - BaselineDimTool

/// The interactive Baseline linear-dimension tool. Pick a baseline dimension (or
/// the two points that define one), then click each successive feature point to
/// stack a new linear dimension measured from the COMMON baseline origin, each at a
/// dimension line offset one DIMDLI step further out.
///
/// Click sequence:
///   - SEED (one of):
///       a) click an existing `.linear`/`.aligned` dim → adopt its `origin1`,
///          `angle`, and dim-line offset as the baseline (`.pickedBase → .chaining`,
///          no commit on the pick).
///       b) no dim under the pick → fall back to the 3-click linear sequence:
///          origin1, origin2, dim-line location → commit the FIRST dim and adopt it
///          as the baseline (`.seedFirst → .seedSecond → .seedLine → .chaining`).
///   - CHAIN: each subsequent click is a new feature point → commit a `.linear`
///     dim sharing `origin1` + `angle`, with the dim line stepped one more DIMDLI
///     out. Repeats until `.commit`/`.cancel`.
public struct BaselineDimTool: Tool {

    private enum State: Equatable {
        /// No baseline yet: the next pick either selects a base dim or starts the
        /// seed-from-points fallback.
        case awaitingBase
        /// Seeding from points: first origin placed, awaiting the second.
        case seedSecond(origin1: Vector)
        /// Seeding from points: both origins placed, awaiting the dim-line location.
        case seedLine(origin1: Vector, origin2: Vector)
        /// Baseline established: `origin1` + `angle` fixed, `baseOffset` is the
        /// signed perpendicular offset of the LAST committed dim's dimension line,
        /// `count` is how many chained dims have been committed since the baseline.
        case chaining(origin1: Vector, angle: Double, baseOffset: Double, count: Int)
    }

    private var state: State = .awaitingBase
    private var cursor: Vector = .invalid

    /// The default baseline (DIMDLI) spacing (world units) when none is supplied:
    /// the fixed proportional fallback (AutoCAD's DIMDLI default ≈ 3.75 mm for a
    /// 2.5 mm text style — i.e. 1.5× text height + arrow). The DIMDLI dim-style
    /// variable is not yet plumbed into the macOS engine; the dim-style table is
    /// consulted only in `resolve()` (text height / arrow size).
    public static let defaultBaselineSpacing: Double = 3.75

    /// The DIMDLI baseline spacing (world units) each successive dimension line is
    /// stepped further out by. Default = `defaultBaselineSpacing`.
    public var baselineSpacing: Double

    public init(baselineSpacing: Double = BaselineDimTool.defaultBaselineSpacing) {
        self.baselineSpacing = max(baselineSpacing, Tolerance.distance)
    }

    public var title: String { "Baseline Dimension" }

    public var status: String {
        switch state {
        case .awaitingBase: return "Select base dimension or specify first extension line origin"
        case .seedSecond:   return "Specify second extension line origin"
        case .seedLine:     return "Specify dimension line location"
        case .chaining:     return "Specify next feature point (baseline)"
        }
    }

    public var preview: [ResolvedPolyline] {
        guard cursor.valid else { return [] }
        switch state {
        case .seedLine(let origin1, let origin2):
            let data = DimData(
                kind: .linear(extension1: origin1, extension2: origin2,
                              angle: (origin2 - origin1).angle),
                definitionPoint: cursor
            )
            return DimToolSupport.previewLines(data)
        case .chaining(let origin1, let angle, let baseOffset, let count):
            guard let data = nextDim(origin1: origin1, angle: angle,
                                     baseOffset: baseOffset, step: count + 1,
                                     feature: cursor) else { return [] }
            return DimToolSupport.previewLines(data)
        default:
            return []
        }
    }

    /// A draw/pick tool: it reads `context.nearbyEntities` only on the FIRST pick
    /// (to adopt a base dim); thereafter it ignores `context` and emits `.add`s.
    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move(let p):
            cursor = p
            return preview.isEmpty ? .none : .preview
        case .click(let p), .value(let p):
            // A typed coordinate (U1) places the next point like a click. (A typed
            // value can never be a base-dim *pick* — it lands at the exact coord, so
            // it always starts the seed-from-points fallback when no base exists.)
            return handleClick(p, context: context)
        case .backspace:
            return handleBackspace()
        case .cancel, .commit:
            reset()
            return .finished
        }
    }

    private mutating func handleClick(_ p: Vector, context: ToolContext) -> ToolOutcome {
        guard p.valid else { return .none }
        switch state {
        case .awaitingBase:
            // Prefer adopting an existing linear/aligned dim under the pick.
            if let base = ChainDimSupport.nearestLinearBase(at: p, context: context) {
                let baseOffset = ChainDimSupport.perpendicularOffset(
                    of: base.definitionPoint, from: base.origin1, angle: base.angle)
                state = .chaining(origin1: base.origin1, angle: base.angle,
                                  baseOffset: baseOffset, count: 0)
                cursor = p
                return .none
            }
            // No dim under the pick: start the seed-from-points fallback.
            state = .seedSecond(origin1: p)
            cursor = p
            return .none

        case .seedSecond(let origin1):
            guard p.distance(to: origin1) > Tolerance.distance else { return .none }
            state = .seedLine(origin1: origin1, origin2: p)
            cursor = p
            return .none

        case .seedLine(let origin1, let origin2):
            let angle = (origin2 - origin1).angle
            let data = DimData(
                kind: .linear(extension1: origin1, extension2: origin2, angle: angle),
                definitionPoint: p
            )
            let baseOffset = ChainDimSupport.perpendicularOffset(
                of: p, from: origin1, angle: angle)
            state = .chaining(origin1: origin1, angle: angle, baseOffset: baseOffset, count: 0)
            cursor = p
            return .commit([.add(EntityRecord(id: .placeholder, kind: .dimension(data)))])

        case .chaining(let origin1, let angle, let baseOffset, let count):
            // A coincident feature point would be a zero-length dim; skip it. The
            // step is `count + 1`: the first chained dim sits one DIMDLI out from the
            // base level, the next two out, and so on (a growing offset / stack).
            guard let data = nextDim(origin1: origin1, angle: angle,
                                     baseOffset: baseOffset, step: count + 1,
                                     feature: p) else {
                return .none
            }
            state = .chaining(origin1: origin1, angle: angle,
                              baseOffset: baseOffset, count: count + 1)
            cursor = p
            return .commit([.add(EntityRecord(id: .placeholder, kind: .dimension(data)))])
        }
    }

    /// Builds the `step`-th chained `.linear` dim from the common baseline `origin1`
    /// + `angle` to the `feature` point, with the dimension line stepped `step`
    /// DIMDLI increments further out than the base level (`baseOffset`). So
    /// `step == 1` is one increment past the base, `step == 2` two, … — successive
    /// chained dims stack with a GROWING offset. The step direction preserves the
    /// sign of `baseOffset` (away from the measured points, on the same side as the
    /// base dim line); when the base dim line sits ON the origins (`baseOffset ≈ 0`)
    /// the step uses the side the feature point is NOT on (the dim sits clear of the
    /// geometry it measures). Returns `nil` for a coincident/degenerate feature
    /// point (zero-length dim).
    private func nextDim(origin1: Vector, angle: Double, baseOffset: Double,
                         step: Int, feature: Vector) -> DimData? {
        guard feature.valid, feature.distance(to: origin1) > Tolerance.distance else {
            return nil
        }
        // The chained dim measures along the SAME direction as the baseline; a
        // feature that projects to the same point as origin1 (zero length along the
        // measurement direction) is degenerate.
        let along = ChainDimSupport.dirUnit(angle: angle)
        let measured = abs((feature - origin1).dot(along))
        guard measured > Tolerance.distance else { return nil }

        // Step the dim line `step` DIMDLI increments further out, on the base side.
        let sign: Double
        if abs(baseOffset) > Tolerance.distance {
            sign = baseOffset >= 0 ? 1.0 : -1.0
        } else {
            let featOffset = ChainDimSupport.perpendicularOffset(
                of: feature, from: origin1, angle: angle)
            sign = featOffset >= 0 ? -1.0 : 1.0
        }
        let nextOffset = baseOffset + sign * baselineSpacing * Double(step)
        let defPoint = ChainDimSupport.definitionPoint(
            from: origin1, angle: angle, offset: nextOffset)
        return DimData(
            kind: .linear(extension1: origin1, extension2: feature, angle: angle),
            definitionPoint: defPoint
        )
    }

    private mutating func handleBackspace() -> ToolOutcome {
        switch state {
        case .awaitingBase:
            return .none
        case .seedSecond:
            reset()
            return .preview
        case .seedLine(let origin1, _):
            state = .seedSecond(origin1: origin1)
            cursor = origin1
            return .preview
        case .chaining(let origin1, let angle, let baseOffset, let count):
            // Stepping back during the chain re-aims the NEXT dim at the previous
            // level by decrementing the committed `count` (the previously committed
            // dims are already applied/undoable on their own; we cannot un-commit
            // them here). At `count == 0` there is nothing to step back.
            if count > 0 {
                state = .chaining(origin1: origin1, angle: angle,
                                  baseOffset: baseOffset, count: count - 1)
                return .preview
            }
            return .none
        }
    }

    private mutating func reset() {
        state = .awaitingBase
        cursor = .invalid
    }
}
