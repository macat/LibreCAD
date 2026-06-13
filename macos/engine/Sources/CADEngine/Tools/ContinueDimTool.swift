//
//  ContinueDimTool.swift
//  CADEngine
//
//  The interactive CONTINUE linear-dimension tool — the second "chained" dimension
//  creator (sibling to `BaselineDimTool`), built against the FROZEN `Tool` contract
//  and mirroring the existing dimension tools exactly (private `enum State`, pure
//  value type, no CADDrawing/Quadtree/GUI access). It authors a RUNNING chain of
//  `.linear` dimensions where each new dimension continues from the PREVIOUS
//  dimension's second extension origin, all drawn at ONE common dimension-line
//  level (end-to-start, in line — unlike baseline's growing offset). Each pick emits
//  one `.add(EntityRecord(kind: .dimension(.linear)))`.
//
//  Ported in spirit from LibreCAD's `RS_ActionDimLinearChain` / the AutoCAD
//  DIMCONTINUE command (librecad/src/lib/actions/drawing/dimensions/), with the
//  magic `int m_status` replaced by an exhaustive private `enum State` carrying the
//  running second origin + the shared dim-line offset.
//
//  ## How a continue run works
//  1. Pick the STARTING dimension — either by clicking an existing `.linear`/
//     `.aligned` dimension entity (the tool reads it from `context.nearbyEntities`,
//     adopting its second origin `origin2` as the chain's running start, plus its
//     `angle` + dim-line offset) OR, when none is under the pick, by clicking the
//     two points + the dim-line location that define the first dimension (committed
//     as the run's first dim, then its `origin2` becomes the running start).
//  2. Click each successive FEATURE point → a new `.linear` dimension is committed
//     from the running origin to the clicked point, at the SAME dim-line level, then
//     the running origin advances to the clicked point. Repeats until `.commit`/
//     `.cancel`.
//
//  PURE: this tool never touches CADDrawing/Quadtree/GUI. It receives already-
//  snapped world points and returns outcomes/preview. It consumes the existing
//  `DimData`/`DimKind.linear` model unchanged (the document dim style for text
//  height / arrow size is applied later in `resolve()` via `dimStyleProvider`). It
//  shares the `ChainDimSupport` helpers with `BaselineDimTool`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDimLinear chain family).
//

import Foundation

// MARK: - ContinueDimTool

/// The interactive Continue linear-dimension tool. Pick a starting dimension (or
/// the two points that define one), then click each successive feature point to
/// continue the chain end-to-start at ONE shared dimension-line level.
///
/// Click sequence:
///   - SEED (one of):
///       a) click an existing `.linear`/`.aligned` dim → adopt its second origin as
///          the running start, plus its `angle` + dim-line offset (`.awaitingBase →
///          .chaining`, no commit on the pick).
///       b) no dim under the pick → fall back to the 3-click linear sequence:
///          origin1, origin2, dim-line location → commit the FIRST dim, then its
///          `origin2` becomes the running start (`.seedSecond → .seedLine →
///          .chaining`).
///   - CHAIN: each subsequent click is a new feature point → commit a `.linear`
///     dim from the running origin to the point, at the shared level, then advance
///     the running origin to the clicked point. Repeats until `.commit`/`.cancel`.
public struct ContinueDimTool: Tool {

    private enum State: Equatable {
        /// No chain yet: the next pick either selects a starting dim or starts the
        /// seed-from-points fallback.
        case awaitingBase
        /// Seeding from points: first origin placed, awaiting the second.
        case seedSecond(origin1: Vector)
        /// Seeding from points: both origins placed, awaiting the dim-line location.
        case seedLine(origin1: Vector, origin2: Vector)
        /// Chain established: `running` is the previous dim's second origin (the new
        /// dim's FIRST origin), `angle` the shared measurement direction, `dimLine`
        /// a FIXED point on the shared dimension line (used verbatim as every dim's
        /// `definitionPoint`, so resolve projects all dims onto the SAME infinite
        /// line — they sit in line at one level).
        case chaining(running: Vector, angle: Double, dimLine: Vector)
    }

    private var state: State = .awaitingBase
    private var cursor: Vector = .invalid

    public init() {}

    public var title: String { "Continue Dimension" }

    public var status: String {
        switch state {
        case .awaitingBase: return "Select starting dimension or specify first extension line origin"
        case .seedSecond:   return "Specify second extension line origin"
        case .seedLine:     return "Specify dimension line location"
        case .chaining:     return "Specify next feature point (continue)"
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
        case .chaining(let running, let angle, let dimLine):
            guard let data = nextDim(running: running, angle: angle,
                                     dimLine: dimLine, feature: cursor) else { return [] }
            return DimToolSupport.previewLines(data)
        default:
            return []
        }
    }

    /// A draw/pick tool: it reads `context.nearbyEntities` only on the FIRST pick
    /// (to adopt a starting dim); thereafter it ignores `context` and emits `.add`s.
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
            // Prefer adopting an existing linear/aligned dim under the pick; its
            // SECOND origin becomes the chain's running start.
            if let base = ChainDimSupport.nearestLinearBase(at: p, context: context) {
                state = .chaining(running: base.origin2, angle: base.angle,
                                  dimLine: base.definitionPoint)
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
            // The chain continues from this first dim's SECOND origin, sharing this
            // dim's dimension line verbatim (so all dims sit on the same line).
            state = .chaining(running: origin2, angle: angle, dimLine: p)
            cursor = p
            return .commit([.add(EntityRecord(id: .placeholder, kind: .dimension(data)))])

        case .chaining(let running, let angle, let dimLine):
            guard let data = nextDim(running: running, angle: angle,
                                     dimLine: dimLine, feature: p) else {
                return .none
            }
            // Advance the running origin to the just-measured feature point; the
            // shared dim line (dimLine) stays fixed.
            state = .chaining(running: p, angle: angle, dimLine: dimLine)
            cursor = p
            return .commit([.add(EntityRecord(id: .placeholder, kind: .dimension(data)))])
        }
    }

    /// Builds the next chained `.linear` dim from the running origin (`running`, the
    /// previous dim's second extension origin) to the `feature` point, along the
    /// shared `angle`, using the FIXED `dimLine` point as the `definitionPoint`.
    /// Because `resolve()` projects each dim's origins onto the line through its
    /// `definitionPoint` parallel to `angle`, reusing the SAME `dimLine` for every
    /// dim places them all on one shared dimension line (end-to-start, in line).
    /// Returns `nil` for a coincident/degenerate feature point (zero-length dim
    /// measured along `angle`).
    private func nextDim(running: Vector, angle: Double, dimLine: Vector,
                         feature: Vector) -> DimData? {
        guard feature.valid, feature.distance(to: running) > Tolerance.distance else {
            return nil
        }
        let along = ChainDimSupport.dirUnit(angle: angle)
        let measured = abs((feature - running).dot(along))
        guard measured > Tolerance.distance else { return nil }

        return DimData(
            kind: .linear(extension1: running, extension2: feature, angle: angle),
            definitionPoint: dimLine
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
        case .chaining:
            // The previously committed dims are applied/undoable on their own; the
            // running origin cannot be walked back to a prior commit's point here, so
            // backspace is a no-op once the chain is running (use Esc to end the run).
            return .none
        }
    }

    private mutating func reset() {
        state = .awaitingBase
        cursor = .invalid
    }
}
