//
//  ConstraintSolver.swift
//  CADEngine
//
//  The PARAMETRIC-CONSTRAINT SOLVER (Wave 1 — engine, UNWIRED): a PURE function
//  that, given the entities in a connected component + the constraints over them,
//  solves for the geometry that satisfies the constraints. No `CADDrawing`, no
//  Quadtree, no GUI — it takes value inputs and returns values, so it unit-tests
//  without a GPU or a live view (ADR-001/§testing).
//
//  ## Why a re-parametrized, min-displacement solver (the rewrite)
//  The first cut minimized Σresidual² over the raw endpoint coordinates
//  (sx,sy,ex,ey). That has two fatal failure modes on the COMMON under-constrained
//  case (e.g. perpendicular on two fully-free lines: 8 DOFs, 1 residual):
//
//    1. COLLAPSE — `dot(d1,d2)==0` can be satisfied by SHRINKING a line to zero
//       length so the two overlap ("become one"). A least-squares minimum over raw
//       endpoints happily picks a degenerate line. Degenerate geometry must never
//       be a solution.
//    2. CONDITIONING — the raw direction residuals (`d1·d2`, `d1×d2`) scale with
//       line length (~100 for length-10 lines) and are badly nonlinear across a
//       large rotation, so LM converges poorly or not at all.
//
//  ### Fix A — re-parametrize each LINE around (angle θ, halfLength L)
//  A line's geometry is stored as an ANCHOR point + (θ, L). For a FREE line the
//  anchor is its CENTER and both endpoints are derived symmetrically
//  (start = c − L·u, end = c + L·u, u = (cosθ,sinθ)); for a line with ONE pinned
//  endpoint the anchor IS that endpoint (start = A, end = A + 2L·u — or the mirror).
//  Crucially:
//    • Every DIRECTION constraint acts ONLY on θ and is bounded + well-conditioned:
//        horizontal      → sin θ == 0
//        vertical        → cos θ == 0
//        parallel(a,b)   → sin(θa − θb) == 0
//        perpendicular   → cos(θa − θb) == 0
//    • L is an independent DOF that NO direction residual ever touches → a line
//      CANNOT collapse to satisfy a direction constraint. This is the structural
//      cure for failure mode (1).
//  Circles stay (cx,cy,r); points stay (px,py).
//
//  ### Fix B — `fix` by DOF ELIMINATION (not a penalty)
//  A `fix` on a POINT or CIRCLE-CENTER removes those DOFs outright. A `fix` on a
//  whole LINE (both endpoints) removes all of the line's DOFs (it becomes rigid). A
//  `fix` on ONE line endpoint re-anchors that line on the fixed endpoint and keeps
//  only (θ, L) free — the pinned endpoint is held EXACTLY by construction, with no
//  weighted penalty and therefore no conditioning blow-up. (A penalty/Lagrangian on
//  a derived endpoint spans many orders of magnitude against the direction residuals
//  and wrecks LM convergence; algebraic elimination is exact and well-conditioned.)
//
//  ### Fix C — min-displacement (nearest-solution) regularization
//  An under-constrained system has a whole manifold of solutions. We bias the solve
//  toward the one NEAREST the original geometry by appending a weak Tikhonov
//  residual `√wᵣ·(xᵢ − x₀ᵢ)` per free DOF. That pins the null space (unrelated
//  geometry barely moves) without overpowering the hard constraints (its weight is
//  tiny), and it makes the Jacobian full-rank so Gauss–Newton/LM is well-posed even
//  with a single real residual.
//
//  The solver minimizes the residual (hard constraints + the weak min-displacement
//  term) via Levenberg–Marquardt with a numeric (finite-difference) Jacobian,
//  adaptive damping, and an iteration cap. Convergence is judged on the HARD
//  residuals (the regularizer is never expected to reach zero). It returns
//  `.solved(updatedGeometry)` on convergence, or `.failed` for a singular /
//  non-converging / over-constrained system — NEVER a partial write.
//
//  ## MVP scope
//  Geometry: `.line`, `.circle`, `.point` (the kinds the MVP constraints touch).
//  Any other `EntityKind` in the component is treated as a RIGID anchor (its
//  geometry is read for residuals but contributes no free DOFs — a constraint that
//  needs to MOVE it can't be satisfied and the solve reports `.failed`). Unsupported
//  constraint kinds short-circuit to `.failed(.unsupported)`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation

// MARK: - Solver result

/// The outcome of a constraint solve.
public enum ConstraintSolveResult: Sendable, Equatable {
    /// Convergence: the satisfied geometry, keyed by entity id. Only the entities
    /// whose geometry the solver could vary appear; an unchanged / anchored entity
    /// may be present with its original geometry. Apply each via `replace(_:)`.
    case solved([EntityID: SolvedGeometry])
    /// Non-convergence / singular / unsupported — NOTHING is written. The `reason`
    /// classifies why so the caller can message the user.
    case failed(ConstraintSolveFailure)
}

/// Why a constraint solve failed (NO geometry was changed).
public enum ConstraintSolveFailure: String, Sendable, Equatable {
    /// A constraint kind not implemented in the MVP was present.
    case unsupported
    /// The component has no free DOFs to vary but constraints remain unsatisfied
    /// (everything fixed / non-editable) — over-constrained / locked.
    case overConstrained
    /// The iteration cap was hit without the residual reaching tolerance
    /// (non-converging — typically under- or over-constrained, or contradictory).
    case didNotConverge
    /// The component references an entity not supplied in `entities`, or carries no
    /// solvable geometry — nothing to solve.
    case invalidInput
}

/// The solved geometry for one entity — the subset of `EntityKind` the solver
/// varies. The caller folds it back into the entity's `EntityRecord.kind`.
public enum SolvedGeometry: Sendable, Equatable {
    case line(LineData)
    case circle(CircleData)
    case point(PointData)
}

// MARK: - The solver

/// A pure, stateless least-squares constraint solver. Build one (or use the static
/// `solve`) and call `solve(entities:constraints:)`.
public struct ConstraintSolver: Sendable {

    /// Tuning knobs (sensible defaults; overridable for tests / hard systems).
    public struct Options: Sendable {
        /// Residual-norm convergence tolerance (the solve succeeds when the RMS of
        /// the HARD residuals drops below this). Default 1e-9 (well inside engine
        /// tolerance).
        public var convergenceTolerance: Double
        /// Max Gauss–Newton/LM iterations before declaring `.didNotConverge`.
        public var maxIterations: Int
        /// Finite-difference step for the numeric Jacobian.
        public var fdStep: Double
        /// Initial LM damping factor (λ). Adapted up on a rejected step, down on an
        /// accepted one.
        public var initialDamping: Double
        /// Weight (√w applied to the residual) of the min-displacement / nearest-
        /// solution regularization term that pulls each free DOF toward its original
        /// value. Small enough not to fight a hard constraint, large enough to pin
        /// the null space so unrelated geometry barely moves and the Jacobian is
        /// full-rank.
        public var regularizationWeight: Double

        public init(
            convergenceTolerance: Double = 1e-9,
            maxIterations: Int = 200,
            fdStep: Double = 1e-7,
            initialDamping: Double = 1e-3,
            regularizationWeight: Double = 1e-6
        ) {
            self.convergenceTolerance = convergenceTolerance
            self.maxIterations = maxIterations
            self.fdStep = fdStep
            self.initialDamping = initialDamping
            self.regularizationWeight = regularizationWeight
        }
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// Convenience: a default-tuned solve.
    public static func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint]
    ) -> ConstraintSolveResult {
        ConstraintSolver().solve(entities: entities, constraints: constraints)
    }

    /// Solves `constraints` over `entities` (a connected component's geometry,
    /// keyed by id). Returns the satisfied geometry, or a `.failed` classification
    /// (with NO partial write). `entities` should hold every entity any constraint
    /// references; a reference to a missing entity yields `.invalidInput`.
    public func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint]
    ) -> ConstraintSolveResult {

        // (0) Reject any unsupported constraint kind up front (clean, no work).
        if constraints.contains(where: { !$0.isSolverSupported }) {
            return .failed(.unsupported)
        }

        // (1) Decide each entity's anchoring from the `fix` constraints, THEN build
        //     the variable layout. A line with one pinned endpoint is re-anchored on
        //     it (so the pin is held by construction); a whole-line / point / circle
        //     fix removes the relevant DOFs.
        var fixSpec = FixSpec()
        for c in constraints where c.kind == .geometric(.fix) {
            for p in c.points { fixSpec.note(p) }
        }
        guard fixSpec.allReferencesPresent(in: entities) || fixSpec.isEmpty else {
            // A `fix` naming an entity not in the component is an invalid reference;
            // (the general validation in (3) also catches this, but failing early
            // keeps the layout build clean).
            return .failed(.invalidInput)
        }

        var layout = VariableLayout()
        for (id, kind) in entities.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            layout.register(id: id, kind: kind, fix: fixSpec.anchoring(for: id))
        }
        guard !layout.entities.isEmpty else { return .failed(.invalidInput) }

        // (3) Validate every constraint resolves against the layout (catches a
        //     reference to an entity not in `entities`, or a bad point/kind pairing).
        for c in constraints {
            guard ResidualBuilder.canBuild(c, layout: layout) else {
                return .failed(.invalidInput)
            }
        }

        // (4) The packed free-variable vector + the originals (for min-displacement).
        let x0 = layout.packFree()
        var x = x0
        let hardResidualCount =
            constraints.reduce(0) { $0 + ResidualBuilder.residualCount($1) }
        let regCount = x.count   // one regularization residual per free DOF

        // The HARD residuals — the actual constraint errors. Convergence is judged
        // on these (their natural scale).
        func hardResiduals(_ free: [Double]) -> [Double] {
            let full = layout.expand(free: free)
            var out: [Double] = []
            out.reserveCapacity(hardResidualCount)
            for c in constraints {
                ResidualBuilder.appendResiduals(of: c, values: full, layout: layout, into: &out)
            }
            return out
        }

        // The residual vector the optimizer MINIMIZES: the hard residuals plus the
        // weak min-displacement term (xᵢ − x₀ᵢ).
        func optimizerResiduals(_ free: [Double]) -> [Double] {
            var out = hardResiduals(free)
            if options.regularizationWeight > 0 {
                let w = options.regularizationWeight
                out.reserveCapacity(out.count + regCount)
                for i in 0..<free.count { out.append(w * (free[i] - x0[i])) }
            }
            return out
        }

        // RMS norm of a residual vector.
        func rms(_ r: [Double]) -> Double {
            guard !r.isEmpty else { return 0 }
            let ss = r.reduce(0) { $0 + $1 * $1 }
            return (ss / Double(r.count)).squareRoot()
        }

        // Convergence is judged on the HARD residuals only.
        func hardRMS(_ free: [Double]) -> Double { rms(hardResiduals(free)) }

        // Nothing hard to satisfy → trivially solved at the current geometry.
        if hardResidualCount == 0 {
            return .solved(layout.unpackAll(free: x))
        }

        if hardRMS(x) <= options.convergenceTolerance {
            return .solved(layout.unpackAll(free: x))
        }

        // No free DOFs but hard residuals remain unsatisfied → over-constrained.
        if x.isEmpty {
            return .failed(.overConstrained)
        }

        // (5) Levenberg–Marquardt loop with a numeric Jacobian over the (regularized)
        //     residual.
        var r = optimizerResiduals(x)
        var err = rms(r)
        var lambda = options.initialDamping
        let n = x.count

        for _ in 0..<options.maxIterations {
            // Numeric Jacobian J (m×n) via forward differences.
            let m = r.count
            var jac = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
            for j in 0..<n {
                var xp = x
                let h = options.fdStep * Swift.max(1.0, abs(x[j]))
                xp[j] += h
                let rp = optimizerResiduals(xp)
                for i in 0..<m {
                    jac[i][j] = (rp[i] - r[i]) / h
                }
            }

            // Normal equations: (JᵀJ + λ·(diag(JᵀJ)+1)) δ = −Jᵀr  (LM).
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var jtr = [Double](repeating: 0, count: n)
            for a in 0..<n {
                for b in a..<n {
                    var s = 0.0
                    for i in 0..<m { s += jac[i][a] * jac[i][b] }
                    jtj[a][b] = s
                    jtj[b][a] = s
                }
                var sr = 0.0
                for i in 0..<m { sr += jac[i][a] * r[i] }
                jtr[a] = sr
            }

            // Try an LM step, growing λ until the step reduces the error (or we give
            // up). The damped diagonal keeps the system well-conditioned even when
            // JᵀJ is rank-deficient — the step is then small but valid.
            var stepAccepted = false
            for _ in 0..<12 {
                var aMat = jtj
                // LM damping with a Levenberg FLOOR on each diagonal: `λ·(JᵀJ_dd+1)`.
                // The `+1` floor strongly damps a degenerate direction to a small,
                // safe step instead of a wild one that always gets rejected.
                for d in 0..<n { aMat[d][d] += lambda * (jtj[d][d] + 1.0) }

                guard let delta = LinearSolve.solveSPD(aMat, rhs: jtr) else {
                    // Singular even with damping → bump λ and retry.
                    lambda *= 10
                    continue
                }

                var xNew = x
                for d in 0..<n { xNew[d] -= delta[d] }     // (JᵀJ+λD)δ = +Jᵀr ⇒ x -= δ
                let rNew = optimizerResiduals(xNew)
                let errNew = rms(rNew)

                if errNew < err {
                    // Accepted: take the step, relax damping.
                    x = xNew
                    r = rNew
                    err = errNew
                    lambda = Swift.max(lambda * 0.5, 1e-12)
                    stepAccepted = true
                    break
                } else {
                    // Rejected: tighten damping (more gradient-descent-like) + retry.
                    lambda *= 4
                }
            }

            if hardRMS(x) <= options.convergenceTolerance {
                return .solved(layout.unpackAll(free: x))
            }
            if !stepAccepted {
                // Could not make progress this outer iteration → stalled.
                break
            }
        }

        // Converged late inside the loop?
        if hardRMS(x) <= options.convergenceTolerance {
            return .solved(layout.unpackAll(free: x))
        }
        return .failed(.didNotConverge)
    }
}

// MARK: - Fix specification (which endpoints/points each entity has pinned)

/// Accumulates the `fix` constraints over a component and tells the layout how to
/// anchor each entity. A line can be free, start-pinned, end-pinned, or rigid; a
/// point / circle is free or rigid.
private struct FixSpec {
    /// For each fixed entity, which characteristic points are pinned.
    private(set) var pinned: [EntityID: Set<EntityPoint>] = [:]

    var isEmpty: Bool { pinned.isEmpty }

    mutating func note(_ p: ConstraintPoint) {
        pinned[p.entityID, default: []].insert(p.point)
    }

    func allReferencesPresent(in entities: [EntityID: EntityKind]) -> Bool {
        pinned.keys.allSatisfy { entities[$0] != nil }
    }

    /// How an entity should be anchored, given its pinned points (`nil` == free).
    func anchoring(for id: EntityID) -> LineAnchor {
        guard let pts = pinned[id] else { return .free }
        // For a line, .start/.end name endpoints; .center maps to .start (the sole
        // point of a point entity is interchangeably .start/.center).
        let hasStart = pts.contains(.start) || pts.contains(.center)
        let hasEnd = pts.contains(.end)
        switch (hasStart, hasEnd) {
        case (true, true):   return .rigid
        case (true, false):  return .pinStart
        case (false, true):  return .pinEnd
        case (false, false): return .free
        }
    }
}

/// How a line (or point/circle) is anchored in the variable layout.
enum LineAnchor {
    /// No endpoint pinned — free to move/rotate (a line uses its CENTER as the DOF
    /// origin; a point/circle keeps its positional DOFs).
    case free
    /// The START is pinned (a line is re-anchored on it; a point/circle is rigid).
    case pinStart
    /// The END is pinned (a line is re-anchored on it).
    case pinEnd
    /// Fully fixed — no DOFs at all.
    case rigid
}

// MARK: - Variable layout (DOF packing + fix anchoring + point resolution)

/// Maps a component's entities to a flat variable vector and back.
///
/// PARAMETRIZATION (the structural anti-collapse fix):
///   - line  → anchor point + (angle θ, halfLength L). Endpoints are DERIVED:
///       • free line:  anchor = center; start = c − L·u, end = c + L·u, u=(cosθ,sinθ)
///       • start-pinned: anchor = fixed start; start = A, end = A + 2L·u
///       • end-pinned:   anchor = fixed end;   end = A,   start = A − 2L·u
///       • rigid:        no DOFs (both endpoints constant)
///     L is an independent DOF that NO direction residual touches → a line cannot
///     collapse to satisfy a direction constraint.
///   - circle → (cx, cy, r)   (rigid `fix` removes cx,cy)
///   - point  → (px, py)      (rigid `fix` removes both)
struct VariableLayout {
    /// The per-line geometric parametrization. A line is described by an ANCHOR
    /// point + a direction angle θ + a length L:
    ///   - FREE line: the anchor is the CENTER and is itself a pair of DOFs
    ///     (centerSlot ≥ 0). Endpoints derive symmetrically: start = c − L·u,
    ///     end = c + L·u (u = (cosθ,sinθ)), L is the HALF-length.
    ///   - PINNED line (one endpoint fixed): the anchor is that endpoint, held
    ///     CONSTANT (centerSlot == −1), and L is the FULL length to the other end.
    ///   - RIGID line: θ and L are anchored too (thetaSlot/lenSlot still index the
    ///     fixed slots; they just never vary).
    struct LineParam {
        /// The fixed anchor (the pinned endpoint) when `centerSlot == −1`; otherwise
        /// the INITIAL center (the live center lives in the two `centerSlot` DOFs).
        var anchor: Vector
        var theta: Double        // initial direction angle
        var length: Double       // half-length (free) / full length (pinned)
        var mode: LineAnchor     // .free / .pinStart / .pinEnd / .rigid
        var centerSlot: Int      // full-vector index of cx (cy = cx+1); −1 if pinned
        var thetaSlot: Int       // full-vector index of θ
        var lenSlot: Int         // full-vector index of L
    }

    /// One entity's slot block in the full-variable vector.
    struct EntitySlots {
        let id: EntityID
        let kind: EntityKind
        /// The full-vector index where this entity's block starts.
        let base: Int
        /// How many FREE-able slots this entity contributes.
        let width: Int
        /// Line parametrization (only for `.line`).
        var line: LineParam?
    }

    private(set) var entities: [EntitySlots] = []
    /// The current value of every FULL slot (free + anchored), index == full-vector.
    private(set) var fullValues: [Double] = []
    /// Whether each full slot is anchored (true == fixed, excluded from `free`).
    private var anchored: [Bool] = []
    /// id → its `EntitySlots`.
    private var byID: [EntityID: EntitySlots] = [:]

    /// Registers an entity's DOFs under the given anchoring.
    mutating func register(id: EntityID, kind: EntityKind, fix: LineAnchor) {
        let base = fullValues.count
        switch kind {
        case .line(let d):
            registerLine(id: id, data: d, base: base, fix: fix)
        case .circle(let d):
            // (cx, cy, r); fixing the circle's center anchors cx,cy (the radius stays a
            // free DOF a radius/equal constraint can still drive). A circle's only
            // characteristic point IS its center, so ANY non-free fix (`.rigid` for the
            // whole entity, or a `.center`-point fix which resolves to `.pinStart`) locks
            // the center — mirroring how a point honors `.pinStart`/`.pinEnd`/`.rigid`.
            fullValues.append(contentsOf: [d.center.x, d.center.y, d.radius])
            let lock = (fix != .free)
            anchored.append(contentsOf: [lock, lock, false])
            addEntity(id: id, kind: kind, base: base, width: 3, line: nil)
        case .arc(let d):
            // (cx, cy, r) like a circle, but ANCHORED — an arc is a RIGID anchor in the
            // MVP (the solver never emits arc geometry; `unpackAll` skips it). Storing its
            // center+radius as anchored slots lets concentric / equal / diameter / radius
            // READ them (a circle can move to be concentric with, or equal-radius to, a
            // fixed arc), with no DOFs contributed and no SolvedGeometry/EntityKind change.
            fullValues.append(contentsOf: [d.center.x, d.center.y, d.radius])
            anchored.append(contentsOf: [true, true, true])
            addEntity(id: id, kind: kind, base: base, width: 0, line: nil)
        case .ellipse(let d):
            // Center as anchored slots (a RIGID anchor, like an arc) so concentric can
            // READ an ellipse's center. No radius slot (an ellipse has two radii — equal/
            // diameter don't apply to it), no DOFs contributed, no geometry emitted.
            fullValues.append(contentsOf: [d.center.x, d.center.y])
            anchored.append(contentsOf: [true, true])
            addEntity(id: id, kind: kind, base: base, width: 0, line: nil)
        case .point(let d):
            fullValues.append(contentsOf: [d.position.x, d.position.y])
            let lock = (fix == .rigid || fix == .pinStart || fix == .pinEnd)
            anchored.append(contentsOf: [lock, lock])
            addEntity(id: id, kind: kind, base: base, width: 2, line: nil)
        default:
            // Non-solvable kind: zero width (rigid anchor, no free DOFs).
            addEntity(id: id, kind: kind, base: base, width: 0, line: nil)
        }
    }

    private mutating func registerLine(id: EntityID, data d: LineData, base: Int, fix: LineAnchor) {
        let dx = d.end.x - d.start.x
        let dy = d.end.y - d.start.y
        let theta = atan2(dy, dx)
        let fullLen = (dx * dx + dy * dy).squareRoot()
        let halfLen = 0.5 * fullLen
        let center = Vector((d.start.x + d.end.x) * 0.5, (d.start.y + d.end.y) * 0.5)

        switch fix {
        case .free, .rigid:
            // 4 DOFs: [cx, cy, θ, L]. The center is free (so coincident / distance
            // can TRANSLATE the line); θ rotates; L (half-length) scales. A `.rigid`
            // line locks all four.
            let cxSlot = base, cySlot = base + 1
            let thetaSlot = base + 2, lenSlot = base + 3
            fullValues.append(contentsOf: [center.x, center.y, theta, halfLen])
            let lock = (fix == .rigid)
            anchored.append(contentsOf: [lock, lock, lock, lock])
            let lp = LineParam(anchor: center, theta: theta, length: halfLen,
                               mode: fix, centerSlot: cxSlot,
                               thetaSlot: thetaSlot, lenSlot: lenSlot)
            _ = cySlot
            addEntity(id: id, kind: kind(d), base: base, width: 4, line: lp)

        case .pinStart, .pinEnd:
            // 2 DOFs: [θ, L]. The anchor (the pinned endpoint) is held CONSTANT in
            // the LineParam (not a DOF) — that is how the pin is enforced EXACTLY,
            // with no penalty / conditioning blow-up. L is the FULL length.
            let anchor = (fix == .pinStart) ? d.start : d.end
            let thetaSlot = base, lenSlot = base + 1
            fullValues.append(contentsOf: [theta, fullLen])
            anchored.append(contentsOf: [false, false])
            let lp = LineParam(anchor: anchor, theta: theta, length: fullLen,
                               mode: fix, centerSlot: -1,
                               thetaSlot: thetaSlot, lenSlot: lenSlot)
            addEntity(id: id, kind: kind(d), base: base, width: 2, line: lp)
        }
    }

    private func kind(_ d: LineData) -> EntityKind { .line(d) }

    private mutating func addEntity(id: EntityID, kind: EntityKind, base: Int, width: Int, line: LineParam?) {
        let slots = EntitySlots(id: id, kind: kind, base: base, width: width, line: line)
        entities.append(slots)
        byID[id] = slots
    }

    /// The kind of a registered entity (nil if absent).
    func kindOf(_ id: EntityID) -> EntityKind? { byID[id]?.kind }

    /// The line parametrization for `id`, or `nil` if not a registered line.
    func lineParam(of id: EntityID) -> LineParam? { byID[id]?.line }

    /// The (xIndex, yIndex) FULL-vector slots of a constraint-point for a CIRCLE
    /// center or a POINT, or `nil`. A LINE endpoint is DERIVED (use `endpoint`).
    func coordinateIndices(of p: ConstraintPoint) -> (Int, Int)? {
        guard let s = byID[p.entityID] else { return nil }
        switch s.kind {
        case .line:
            return nil
        case .circle, .arc, .ellipse:
            // Circle / arc / ellipse all store (cx, cy) at the block base (the center).
            return p.point == .center || p.point == .start ? (s.base, s.base + 1) : nil
        case .point:
            return p.point == .end ? nil : (s.base, s.base + 1)
        default:
            return nil
        }
    }

    /// Whether a constraint-point names a resolvable position (a line endpoint, a
    /// circle center, or a point).
    func resolvesPosition(_ p: ConstraintPoint) -> Bool {
        guard let s = byID[p.entityID] else { return false }
        switch s.kind {
        case .line:                  return p.point == .start || p.point == .end
        case .circle, .arc, .ellipse: return p.point == .center || p.point == .start
        case .point:                 return p.point != .end
        default:                     return false
        }
    }

    /// Whether `id` carries a readable CENTER (a circle / arc / ellipse). Backs the
    /// concentric validation (`canBuild`).
    func hasCenter(_ id: EntityID) -> Bool {
        guard let s = byID[id] else { return false }
        switch s.kind {
        case .circle, .arc, .ellipse: return true
        default:                      return false
        }
    }

    /// Whether `id` carries a readable RADIUS slot (a circle or arc). Backs the equal /
    /// diameter validation. (An ellipse has no single radius, so it is excluded.)
    func hasRadius(_ id: EntityID) -> Bool { radiusIndex(of: id) != nil }

    /// The DERIVED (x,y) of a line endpoint from a FULL `values` vector.
    func endpoint(of id: EntityID, which: EntityPoint, values: [Double]) -> (Double, Double) {
        guard let lp = byID[id]?.line else { return (0, 0) }
        let theta = values[lp.thetaSlot]
        let len = values[lp.lenSlot]
        let ux = cos(theta), uy = sin(theta)
        switch lp.mode {
        case .free, .rigid:
            // center is the (live) anchor; half-length each side.
            let cx = values[lp.centerSlot], cy = values[lp.centerSlot + 1]
            switch which {
            case .end:  return (cx + len * ux, cy + len * uy)
            default:    return (cx - len * ux, cy - len * uy)
            }
        case .pinStart:
            // anchor == fixed start; full length to end.
            switch which {
            case .end:  return (lp.anchor.x + len * ux, lp.anchor.y + len * uy)
            default:    return (lp.anchor.x, lp.anchor.y)
            }
        case .pinEnd:
            // anchor == fixed end; full length back to start.
            switch which {
            case .end:  return (lp.anchor.x, lp.anchor.y)
            default:    return (lp.anchor.x - len * ux, lp.anchor.y - len * uy)
            }
        }
    }

    /// The stored / live θ of a line, or `nil` if `id` is not a line. (Even a RIGID
    /// line's θ lives in a slot — anchored, so its value never changes.)
    func angleValue(of id: EntityID, values: [Double]) -> Double? {
        guard let lp = byID[id]?.line else { return nil }
        return values[lp.thetaSlot]
    }

    /// The FULL-vector slot of a circle's or arc's RADIUS, or `nil` otherwise. (Both a
    /// circle and an arc store the radius at block base + 2; an arc's slot is anchored,
    /// so it reads as a constant — fine for equal / diameter against a rigid arc.)
    func radiusIndex(of id: EntityID) -> Int? {
        guard let s = byID[id] else { return nil }
        switch s.kind {
        case .circle, .arc: return s.base + 2
        default:            return nil
        }
    }

    /// Whether `id` is a known, registered entity.
    func contains(_ id: EntityID) -> Bool { byID[id] != nil }

    // MARK: Pack / expand / unpack

    /// The current values of the FREE (non-anchored) slots, in full-vector order.
    func packFree() -> [Double] {
        var out: [Double] = []
        for i in 0..<fullValues.count where !anchored[i] { out.append(fullValues[i]) }
        return out
    }

    /// Expands a FREE vector back to a FULL vector (anchored slots keep their stored
    /// value; free slots take the supplied values in order).
    func expand(free: [Double]) -> [Double] {
        var full = fullValues
        var k = 0
        for i in 0..<full.count where !anchored[i] {
            full[i] = free[k]
            k += 1
        }
        return full
    }

    /// Rebuilds every entity's solved geometry from a FREE vector.
    func unpackAll(free: [Double]) -> [EntityID: SolvedGeometry] {
        let full = expand(free: free)
        var out: [EntityID: SolvedGeometry] = [:]
        for s in entities {
            switch s.kind {
            case .line(let d):
                var nd = d
                let st = endpoint(of: s.id, which: .start, values: full)
                let en = endpoint(of: s.id, which: .end, values: full)
                nd.start = Vector(st.0, st.1)
                nd.end = Vector(en.0, en.1)
                out[s.id] = .line(nd)
            case .circle(let d):
                var nd = d
                nd.center = Vector(full[s.base], full[s.base + 1])
                nd.radius = full[s.base + 2]
                out[s.id] = .circle(nd)
            case .point(let d):
                var nd = d
                nd.position = Vector(full[s.base], full[s.base + 1])
                out[s.id] = .point(nd)
            default:
                break   // non-solvable: nothing to write
            }
        }
        return out
    }
}

// MARK: - Residual construction

/// Builds the residual vector contributions for each constraint kind from a FULL
/// variable vector. The single source of truth for "what does this constraint
/// require" — both the residual evaluation and the up-front validation route here.
///
/// Direction constraints are written in the NORMALIZED, well-conditioned form on the
/// line ANGLE θ (sin/cos of an angle, range [−1,1]) rather than the raw, length-
/// scaled cross/dot of endpoint deltas. Positional constraints (coincident /
/// distance) read the DERIVED endpoints.
enum ResidualBuilder {

    /// How many scalar residuals a constraint contributes (so the solver can size
    /// the Jacobian without evaluating).
    static func residualCount(_ c: Constraint) -> Int {
        switch c.kind {
        case .geometric(let g):
            switch g {
            case .coincident:                  return 2     // Δx, Δy
            case .horizontal, .vertical:       return 1
            case .parallel, .perpendicular:    return 1
            case .fix:                         return 0     // handled by anchoring
            case .collinear:                   return 2     // angle-equal + zero offset
            case .concentric:                  return 2     // Δcenter (dx, dy)
            case .equal:                       return 1     // ΔL  (lines)  or  Δr  (circles)
            case .tangent, .symmetric:
                return 0                                     // unsupported (rejected earlier)
            }
        case .dimensional(let d):
            switch d {
            case .distance, .radius:           return 1
            case .horizontalDistance, .verticalDistance, .diameter, .angle:
                return 1
            }
        }
    }

    /// Whether `c` can be evaluated against `layout` (every referenced point/kind
    /// resolves). `fix` always builds (its anchoring is done before this).
    static func canBuild(_ c: Constraint, layout: VariableLayout) -> Bool {
        switch c.kind {
        case .geometric(.fix):
            return c.points.allSatisfy { layout.resolvesPosition($0) }

        case .geometric(.coincident), .dimensional(.distance):
            guard c.points.count >= 2 else { return false }
            return layout.resolvesPosition(c.points[0])
                && layout.resolvesPosition(c.points[1])

        case .geometric(.horizontal), .geometric(.vertical):
            // The two points name the SAME line whose angle is constrained.
            guard c.points.count >= 2 else { return false }
            return layout.lineParam(of: c.points[0].entityID) != nil
                && c.points[0].entityID == c.points[1].entityID

        case .geometric(.parallel), .geometric(.perpendicular),
             .geometric(.collinear), .dimensional(.angle):
            // Two lines: four endpoints, each pair naming the SAME line.
            guard c.points.count >= 4 else { return false }
            return layout.lineParam(of: c.points[0].entityID) != nil
                && layout.lineParam(of: c.points[2].entityID) != nil
                && c.points[0].entityID == c.points[1].entityID
                && c.points[2].entityID == c.points[3].entityID

        case .geometric(.concentric):
            // Two entities that each carry a CENTER (circle / arc / ellipse).
            guard c.points.count >= 2 else { return false }
            return layout.hasCenter(c.points[0].entityID)
                && layout.hasCenter(c.points[1].entityID)

        case .geometric(.equal):
            // A SAME-FAMILY pair: two lines (length-equal) OR two circular entities
            // (radius-equal). Reject a mixed pair.
            if c.points.count >= 4,
               layout.lineParam(of: c.points[0].entityID) != nil,
               layout.lineParam(of: c.points[2].entityID) != nil,
               c.points[0].entityID == c.points[1].entityID,
               c.points[2].entityID == c.points[3].entityID {
                return true                               // two lines
            }
            if c.points.count == 2,
               layout.hasRadius(c.points[0].entityID),
               layout.hasRadius(c.points[1].entityID) {
                return true                               // two circles/arcs
            }
            return false

        case .dimensional(.radius), .dimensional(.diameter):
            guard let first = c.points.first else { return false }
            return layout.radiusIndex(of: first.entityID) != nil

        case .dimensional(.horizontalDistance), .dimensional(.verticalDistance):
            guard c.points.count >= 2 else { return false }
            return layout.resolvesPosition(c.points[0])
                && layout.resolvesPosition(c.points[1])

        default:
            return false   // unsupported kinds are rejected before this is reached
        }
    }

    /// Appends `c`'s residual scalars (evaluated at FULL `values`) into `out`.
    static func appendResiduals(
        of c: Constraint,
        values: [Double],
        layout: VariableLayout,
        into out: inout [Double]
    ) {
        switch c.kind {
        case .geometric(.fix):
            return   // no residual; anchoring removed the DOFs

        case .geometric(.coincident):
            let (a, b) = (c.points[0], c.points[1])
            let pa = position(a, values, layout), pb = position(b, values, layout)
            out.append(pa.0 - pb.0)   // Δx
            out.append(pa.1 - pb.1)   // Δy

        case .geometric(.horizontal):
            // Line horizontal ⇒ sin θ == 0 (normalized, bounded direction residual).
            out.append(sin(layout.angleValue(of: c.points[0].entityID, values: values) ?? 0))

        case .geometric(.vertical):
            // Line vertical ⇒ cos θ == 0.
            out.append(cos(layout.angleValue(of: c.points[0].entityID, values: values) ?? 0))

        case .geometric(.parallel):
            // Parallel ⇒ sin(θ1 − θ2) == 0 (well-conditioned; CANNOT collapse a line).
            let t1 = layout.angleValue(of: c.points[0].entityID, values: values) ?? 0
            let t2 = layout.angleValue(of: c.points[2].entityID, values: values) ?? 0
            out.append(sin(t1 - t2))

        case .geometric(.perpendicular):
            // Perpendicular ⇒ cos(θ1 − θ2) == 0.
            let t1 = layout.angleValue(of: c.points[0].entityID, values: values) ?? 0
            let t2 = layout.angleValue(of: c.points[2].entityID, values: values) ?? 0
            out.append(cos(t1 - t2))

        case .dimensional(.distance):
            let pa = position(c.points[0], values, layout)
            let pb = position(c.points[1], values, layout)
            let dx = pb.0 - pa.0, dy = pb.1 - pa.1
            out.append((dx * dx + dy * dy).squareRoot() - c.value)

        case .dimensional(.radius):
            if let ri = layout.radiusIndex(of: c.points[0].entityID) {
                out.append(values[ri] - c.value)
            }

        case .geometric(.collinear):
            // Two lines on the SAME infinite line. Equivalent to "both of line-2's
            // endpoints lie on line-1's infinite line" — if BOTH endpoints are on the
            // line, the whole segment is, which IMPLIES equal direction too. Using both
            // endpoints (rather than an angle residual + one offset) is far better
            // conditioned for a FREE line: each residual directly drives an endpoint onto
            // the line (no flat-gradient angle term whose tiny error a long lever arm
            // amplifies into a residual that stalls above tolerance).
            //   residual_k = signed perpendicular distance of line-2 endpoint_k to the
            //   infinite line through line-1's anchor A with direction u1 = (P_k − A) × u1.
            let l1 = c.points[0].entityID, l2 = c.points[2].entityID
            let t1 = layout.angleValue(of: l1, values: values) ?? 0
            let a = layout.endpoint(of: l1, which: .start, values: values)
            let ux = cos(t1), uy = sin(t1)
            let ps = layout.endpoint(of: l2, which: .start, values: values)
            let pe = layout.endpoint(of: l2, which: .end, values: values)
            out.append((ps.0 - a.0) * uy - (ps.1 - a.1) * ux)   // start on line 1
            out.append((pe.0 - a.0) * uy - (pe.1 - a.1) * ux)   // end on line 1

        case .geometric(.concentric):
            // Centers coincide: c2 − c1 == 0 (dx, dy).
            let ca = position(c.points[0], values, layout)
            let cb = position(c.points[1], values, layout)
            out.append(cb.0 - ca.0)
            out.append(cb.1 - ca.1)

        case .geometric(.equal):
            if c.points.count >= 4 {
                // Two LINES: equal length. L is a line DOF (half-length for a free line,
                // full length for a pinned one); equal half-length ⇔ equal length.
                let la = lineLength(c.points[0].entityID, values, layout)
                let lb = lineLength(c.points[2].entityID, values, layout)
                out.append(la - lb)
            } else {
                // Two CIRCULAR entities: equal radius.
                let ra = layout.radiusIndex(of: c.points[0].entityID).map { values[$0] } ?? 0
                let rb = layout.radiusIndex(of: c.points[1].entityID).map { values[$0] } ?? 0
                out.append(ra - rb)
            }

        case .dimensional(.angle):
            // Included angle between two lines driven to `value` (radians). Wrap-safe:
            // residual = sin(Δθ − value), zero ⇔ Δθ ≡ value (mod π for an unsigned line
            // pair — sin makes ±value and value±π all valid, matching a line's antipodal
            // direction ambiguity).
            let t1 = layout.angleValue(of: c.points[0].entityID, values: values) ?? 0
            let t2 = layout.angleValue(of: c.points[2].entityID, values: values) ?? 0
            out.append(sin((t1 - t2) - c.value))

        case .dimensional(.diameter):
            if let ri = layout.radiusIndex(of: c.points[0].entityID) {
                out.append(2.0 * values[ri] - c.value)
            }

        case .dimensional(.horizontalDistance):
            // Δx between the two points driven to `value`: (x2 − x1) − value.
            let pa = position(c.points[0], values, layout)
            let pb = position(c.points[1], values, layout)
            out.append((pb.0 - pa.0) - c.value)

        case .dimensional(.verticalDistance):
            // Δy between the two points driven to `value`: (y2 − y1) − value.
            let pa = position(c.points[0], values, layout)
            let pb = position(c.points[1], values, layout)
            out.append((pb.1 - pa.1) - c.value)

        default:
            return   // unsupported (rejected earlier)
        }
    }

    /// The CURRENT length of a line from the FULL vector: |end − start| derived from its
    /// endpoints (robust whether the line is free or pinned — both store endpoints).
    private static func lineLength(_ id: EntityID, _ values: [Double], _ layout: VariableLayout) -> Double {
        let s = layout.endpoint(of: id, which: .start, values: values)
        let e = layout.endpoint(of: id, which: .end, values: values)
        let dx = e.0 - s.0, dy = e.1 - s.1
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The (x, y) WORLD position of a constraint-point from the FULL vector — a line
    /// endpoint (derived), a circle center, or a point.
    private static func position(_ p: ConstraintPoint, _ values: [Double], _ layout: VariableLayout) -> (Double, Double) {
        if let kind = layout.kindOf(p.entityID), case .line = kind {
            return layout.endpoint(of: p.entityID, which: p.point, values: values)
        }
        if let (xi, yi) = layout.coordinateIndices(of: p) {
            return (values[xi], values[yi])
        }
        return (0, 0)
    }
}

// MARK: - Dense linear solve (symmetric positive-(semi)definite, LM normal eqns)

/// A tiny dense linear-system solver for the LM normal equations. The damped
/// `JᵀJ + λD` is symmetric positive-definite, so Cholesky is the natural choice;
/// it falls back to `nil` if the matrix is not factorable (caught by the caller,
/// which bumps λ). Sized for SMALL systems (a constraint component's DOF count is
/// tiny), so a dense O(n³) factorization is ample.
enum LinearSolve {
    /// Solves `A x = rhs` for a symmetric positive-definite `A` (n×n) via Cholesky.
    /// Returns `nil` if `A` is not positive-definite (a non-positive pivot).
    static func solveSPD(_ A: [[Double]], rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard n > 0, A.count == n, A.allSatisfy({ $0.count == n }) else {
            return n == 0 ? [] : nil
        }
        // Cholesky: A = L Lᵀ.
        var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var sum = A[i][j]
                if j > 0 {
                    for k in 0..<j { sum -= L[i][k] * L[j][k] }
                }
                if i == j {
                    guard sum > 0, sum.isFinite else { return nil }   // not SPD
                    L[i][j] = sum.squareRoot()
                } else {
                    let denom = L[j][j]
                    guard denom != 0, denom.isFinite else { return nil }
                    L[i][j] = sum / denom
                }
            }
        }
        // Forward solve L y = rhs.
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = rhs[i]
            if i > 0 { for k in 0..<i { sum -= L[i][k] * y[k] } }
            y[i] = sum / L[i][i]
        }
        // Back solve Lᵀ x = y.
        var x = [Double](repeating: 0, count: n)
        for ri in 0..<n {
            let i = n - 1 - ri
            var sum = y[i]
            if i + 1 < n { for k in (i + 1)..<n { sum -= L[k][i] * x[k] } }
            x[i] = sum / L[i][i]
        }
        guard x.allSatisfy({ $0.isFinite }) else { return nil }
        return x
    }
}
