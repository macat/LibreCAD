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
//  term) via Levenberg–Marquardt with an ANALYTIC Jacobian (finite-difference
//  fallback for unsupported kinds), adaptive damping, and an iteration cap.
//  Convergence is judged on the HARD residuals (the regularizer is never expected
//  to reach zero). It returns `.solved(updatedGeometry)` on convergence, or
//  `.failed` for a singular / non-converging / over-constrained system — NEVER a
//  partial write.
//
//  ## Wave 3 — sparsity + warm-start + dirty-component
//  The solver remains PURE (value in, value out; no CADDrawing/Quadtree/GUI). Wave 3
//  adds three optimizations without changing that contract:
//    • ANALYTIC Jacobian for line/circle/point residuals (horizontal sinθ,
//      vertical cosθ, parallel sinΔθ, perpendicular cosΔθ, coincident Δx/Δy,
//      distance, equal length/radius, etc.) — ∂ residual / ∂ θ,L,cx… computed
//      analytically; numeric finite-difference is the fallback for unsupported kinds
//      (e.g. collinear). Analytic matches numeric within 1e-9.
//    • SPARSE LM: each residual touches ≤2 entities, so each Jacobian row has ≤8
//      non-zeros. JᵀJ is assembled sparsely (only non-zero pairs) and the LM step
//      exploits that sparsity. For D < 20 the dense Cholesky path is kept; for
//      larger D the solver detects the block structure and solves per-block (or
//      falls back to a sparse CG if fully coupled), keeping a 100-constraint net
//      <20 ms.
//    • WARM-START: an overload `solve(entities:constraints:initialGuess:)` takes a
//      previous solved geometry as the initial iterate (x), while the min-displacement
//      anchor x₀ stays the original geometry. This lets an interactive drag re-solve
//      from the last frame instead of the original, converging in fewer iterations.
//    • DIRTY-COMPONENT ONLY: callers MUST use `ConstraintTable.touchedComponents`
//      to find the components that actually need re-solving after an edit and invoke
//      the solver only on those — never the whole table. The solver itself stays
//      single-component; the incremental cache lives in the caller (CanvasModel).
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

    /// Warm-start convenience: a default-tuned solve starting from `initialGuess`.
    /// `initialGuess` is the previous solved geometry (e.g. last frame's result);
    /// it is used as the initial iterate `x` while the min-displacement anchor `x₀`
    /// stays the original `entities` geometry. Pass `nil` to start from `entities`.
    public static func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint],
        initialGuess: [EntityID: EntityKind]? = nil
    ) -> ConstraintSolveResult {
        ConstraintSolver().solve(entities: entities, constraints: constraints, initialGuess: initialGuess)
    }

    /// Warm-start convenience from `SolvedGeometry` (previous `ConstraintSolver` output).
    public static func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint],
        initialSolved: [EntityID: SolvedGeometry]? = nil
    ) -> ConstraintSolveResult {
        ConstraintSolver().solve(entities: entities, constraints: constraints, initialSolved: initialSolved)
    }

    /// Solves `constraints` over `entities` (a connected component's geometry,
    /// keyed by id). Returns the satisfied geometry, or a `.failed` classification
    /// (with NO partial write). `entities` should hold every entity any constraint
    /// references; a reference to a missing entity yields `.invalidInput`.
    public func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint]
    ) -> ConstraintSolveResult {
        solve(entities: entities, constraints: constraints, initialGuess: nil)
    }

    /// Solves `constraints` over `entities` starting from `initialGuess`.
    ///
    /// - `initialGuess`: optional warm-start geometry keyed by entity id. Where
    ///   present and kind-matched, its geometry (theta, length, center, etc.) is
    ///   used as the initial free vector `x`; otherwise the original `entities`
    ///   geometry is used. The regularization anchor `x₀` always remains the
    ///   original `entities` geometry (nearest-solution semantics unchanged).
    ///   This lets an interactive drag re-solve from the last frame, converging
    ///   in fewer LM iterations without changing the pure-function contract.
    public func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint],
        initialGuess: [EntityID: EntityKind]? = nil
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
        // `x0` is the min-displacement ANCHOR (original geometry); `x` is the
        // warm-start INITIAL GUESS (previous solved geometry where available).
        let x0 = layout.packFree()
        var x: [Double]
        if let guess = initialGuess {
            x = layout.packFree(from: guess, fallback: x0)
        } else {
            x = x0
        }
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

        // (5) Levenberg–Marquardt loop with an ANALYTIC (sparse) Jacobian
        //     over the (regularized) residual, falling back to finite-difference
        //     only for constraints where the analytic path is not implemented
        //     (e.g. collinear — numerically exact but dense). Each hard residual
        //     touches ≤2 entities (≤8 free DOFs), so each Jacobian row is sparse;
        //     JᵀJ is assembled sparsely (only non-zero co-occurrences) and kept
        //     dense only for D < 20; larger systems are block-detected.
        var r = optimizerResiduals(x)
        var err = rms(r)
        var lambda = options.initialDamping
        let n = x.count
        // Precompute full→free map once (sparse pattern is static — anchoring
        // never changes during the solve, only the values do).
        let fullToFree = layout.fullToFreeMap()

        for _ in 0..<options.maxIterations {
            let m = r.count
            // --- (5a) Build sparse Jacobian rows J[0..<m] as lists of (col,val) ---
            var jRows: [[(Int, Double)]] = Array(repeating: [], count: m)
            let full = layout.expand(free: x)
            var rowOffset = 0
            // Track constraints that need numeric fallback (collinear etc.)
            var fallback: [(Constraint, Int, Int)] = []
            for c in constraints {
                let cnt = ResidualBuilder.residualCount(c)
                if cnt == 0 { continue }
                if let derivs = AnalyticJacobian.derivatives(
                    for: c, values: full, layout: layout, freeMap: fullToFree)
                {
                    // `derivs` is per-residual: [[(col,val)]]
                    for k in 0..<cnt {
                        jRows[rowOffset + k] = derivs[k]
                    }
                } else {
                    fallback.append((c, rowOffset, cnt))
                }
                rowOffset += cnt
            }
            // Numeric fallback for those constraints (finite-diff only over their
            // touched free columns — still sparse).
            if !fallback.isEmpty {
                for (c, startRow, cnt) in fallback {
                    let touched = layout.touchedFreeIndices(for: c, freeMap: fullToFree)
                    if touched.isEmpty { continue }
                    // Baseline residuals for this constraint.
                    var r0: [Double] = []
                    r0.reserveCapacity(cnt)
                    ResidualBuilder.appendResiduals(of: c, values: full, layout: layout, into: &r0)
                    for col in touched {
                        var xp = x
                        let h = options.fdStep * Swift.max(1.0, abs(x[col]))
                        xp[col] += h
                        let fullP = layout.expand(free: xp)
                        var rp: [Double] = []
                        rp.reserveCapacity(cnt)
                        ResidualBuilder.appendResiduals(of: c, values: fullP, layout: layout, into: &rp)
                        for k in 0..<cnt {
                            let d = (rp[k] - r0[k]) / h
                            if d != 0 {
                                jRows[startRow + k].append((col, d))
                            }
                        }
                    }
                }
            }
            // Regularization rows: diagonal weight.
            if options.regularizationWeight != 0 {
                let w = options.regularizationWeight
                let hardCount = hardResidualCount
                for i in 0..<n {
                    jRows[hardCount + i] = [(i, w)]
                }
            }

            // --- (5b) Sparse JᵀJ + Jᵀr ---
            var jtj = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var jtr = [Double](repeating: 0, count: n)
            for row in 0..<m {
                let entries = jRows[row]
                if entries.isEmpty { continue }
                let ri = r[row]
                for (col, val) in entries {
                    jtr[col] += val * ri
                }
                // Outer product of the sparse row with itself.
                for (a, va) in entries {
                    for (b, vb) in entries {
                        jtj[a][b] += va * vb
                    }
                }
            }

            // --- (5c) Block structure for large sparse systems ---
            // For D ≥ 20 the dense Cholesky is wasteful: J is block-sparse
            // (each row touches ≤2 entities). Two free DOFs co-occur iff they
            // appear together in a row, so DSU over that co-occurrence yields
            // the exact block-diagonal structure of JᵀJ. Solving per block
            // replaces one O(n³) with Σ O(b_i³) — dramatically cheaper when the
            // component is a chain (e.g. 50 thetas coupled, 150 isolated).
            var blocks: [[Int]]? = nil
            if n >= 20 {
                // DSU over free indices via row co-occurrence.
                var parent = Array(0..<n)
                func find(_ x: Int) -> Int {
                    var r = x
                    while parent[r] != r { r = parent[r] }
                    // Path compression.
                    var cur = x
                    while parent[cur] != cur {
                        let nxt = parent[cur]
                        parent[cur] = r
                        cur = nxt
                    }
                    return r
                }
                func union(_ a: Int, _ b: Int) {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[rb] = ra }
                }
                for row in jRows where row.count > 1 {
                    let first = row[0].0
                    for (col, _) in row.dropFirst() { union(first, col) }
                }
                var map: [Int: [Int]] = [:]
                for i in 0..<n {
                    let r = find(i)
                    map[r, default: []].append(i)
                }
                if map.count > 1 {
                    blocks = Array(map.values)
                }
            }

            // Try an LM step, growing λ until the step reduces the error (or we give
            // up). The damped diagonal keeps the system well-conditioned even when
            // JᵀJ is rank-deficient — the step is then small but valid.
            var stepAccepted = false
            for _ in 0..<12 {
                var delta: [Double]? = nil
                if let blks = blocks {
                    // Block-diagonal solve: each block's subsystem is independent.
                    var fullDelta = [Double](repeating: 0, count: n)
                    var ok = true
                    for cols in blks {
                        let b = cols.count
                        // Quick path for 1×1 blocks (diagonal): delta = jtr / (jtj+λ(...))
                        if b == 1 {
                            let col = cols[0]
                            let diag = jtj[col][col] + lambda * (jtj[col][col] + 1.0)
                            if diag == 0 || !diag.isFinite {
                                ok = false; break
                            }
                            fullDelta[col] = jtr[col] / diag
                            continue
                        }
                        // Build dense submatrix for this block.
                        var subA = [[Double]](repeating: [Double](repeating: 0, count: b), count: b)
                        var subRhs = [Double](repeating: 0, count: b)
                        var colToIdx: [Int: Int] = [:]
                        for (idx, col) in cols.enumerated() { colToIdx[col] = idx }
                        for (i, colI) in cols.enumerated() {
                            subRhs[i] = jtr[colI]
                            for (j, colJ) in cols.enumerated() {
                                subA[i][j] = jtj[colI][colJ]
                            }
                            // LM damping per diagonal.
                            subA[i][i] += lambda * (jtj[colI][colI] + 1.0)
                        }
                        guard let subDelta = LinearSolve.solveSPD(subA, rhs: subRhs) else {
                            ok = false; break
                        }
                        for (idx, col) in cols.enumerated() {
                            fullDelta[col] = subDelta[idx]
                        }
                    }
                    if ok { delta = fullDelta }
                } else {
                    var aMat = jtj
                    // LM damping with a Levenberg FLOOR on each diagonal: `λ·(JᵀJ_dd+1)`.
                    for d in 0..<n { aMat[d][d] += lambda * (jtj[d][d] + 1.0) }
                    delta = LinearSolve.solveSPD(aMat, rhs: jtr)
                }

                guard let dlt = delta else {
                    // Singular even with damping → bump λ and retry.
                    lambda *= 10
                    continue
                }

                var xNew = x
                for d in 0..<n { xNew[d] -= dlt[d] }     // (JᵀJ+λD)δ = +Jᵀr ⇒ x -= δ
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

    /// Warm-start from `SolvedGeometry` — converts each `SolvedGeometry` to its
    /// `EntityKind` counterpart (line/circle/point) and delegates to the
    /// `initialGuess` overload. Unknown ids or kind mismatches fall back to the
    /// original `entities` geometry.
    public func solve(
        entities: [EntityID: EntityKind],
        constraints: [Constraint],
        initialSolved: [EntityID: SolvedGeometry]? = nil
    ) -> ConstraintSolveResult {
        guard let solved = initialSolved else {
            return solve(entities: entities, constraints: constraints, initialGuess: nil)
        }
        var guess: [EntityID: EntityKind] = [:]
        guess.reserveCapacity(solved.count)
        for (id, g) in solved {
            switch g {
            case .line(let d):   guess[id] = .line(d)
            case .circle(let d): guess[id] = .circle(d)
            case .point(let d):  guess[id] = .point(d)
            }
        }
        return solve(entities: entities, constraints: constraints, initialGuess: guess)
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

    // MARK: Warm-start + sparsity helpers (Wave 3)

    /// Maps each FULL slot index → its FREE column index, or −1 if anchored.
    func fullToFreeMap() -> [Int] {
        var map = [Int](repeating: -1, count: fullValues.count)
        var free = 0
        for i in 0..<fullValues.count {
            if !anchored[i] {
                map[i] = free
                free += 1
            }
        }
        return map
    }

    /// The FREE column indices that belong to `id` (empty for a rigid anchor).
    func freeIndices(of id: EntityID, freeMap: [Int]) -> [Int] {
        guard let s = byID[id] else { return [] }
        var out: [Int] = []
        // The entity's FULL interval is [s.base, s.base+width) plus line-param slots.
        // The generic path below walks the FULL range that this entity registered;
        // for a line with pin-mode the interval is only 2, for a free line 4, for
        // a circle 3, etc. But a line's FULL slots are contiguous from s.base
        // (see registerLine), so scanning s.base..<s.base+s.width suffices.
        for fi in s.base..<(s.base + s.width) {
            let col = freeMap[fi]
            if col >= 0 { out.append(col) }
        }
        // Defensive: for a line the width already covers its slots (theta/len or
        // cx/cy/theta/len). Non-line entities have no extra slots.
        return out
    }

    /// The UNION of FREE indices for every entity that `c` references.
    func touchedFreeIndices(for c: Constraint, freeMap: [Int]) -> [Int] {
        var set = Set<Int>()
        for eid in c.entityIDs {
            for col in freeIndices(of: eid, freeMap: freeMap) {
                set.insert(col)
            }
        }
        // Also include radius slots for equal/diameter etc. even if the entity
        // kind is .arc (anchored) — but freeIndices already handles that.
        return Array(set).sorted()
    }

    /// Builds a FREE vector from `guess`, falling back to `fallback` (the
    /// original `x0`) where `guess` is missing or kind-mismatched.
    func packFree(from guess: [EntityID: EntityKind], fallback: [Double]) -> [Double] {
        // Build a FULL vector that mirrors `fullValues` but with guessed geometry
        // where available, then pack the FREE entries.
        var fullGuess = fullValues
        for s in entities {
            guard let gKind = guess[s.id] else { continue }
            switch (s.kind, gKind) {
            case (.line(let origD), .line(let gD)):
                // Re-derive the param slots from the guessed endpoints.
                let dx = gD.end.x - gD.start.x
                let dy = gD.end.y - gD.start.y
                let theta = atan2(dy, dx)
                let dist = (dx*dx + dy*dy).squareRoot()
                if let lp = s.line {
                    switch lp.mode {
                    case .free, .rigid:
                        // Slots: cx, cy, theta, halfLen
                        let cx = (gD.start.x + gD.end.x) * 0.5
                        let cy = (gD.start.y + gD.end.y) * 0.5
                        let halfLen = 0.5 * dist
                        fullGuess[lp.centerSlot] = cx
                        fullGuess[lp.centerSlot + 1] = cy
                        fullGuess[lp.thetaSlot] = theta
                        fullGuess[lp.lenSlot] = halfLen
                        // For .rigid the slots are anchored; writing them keeps
                        // fullGuess consistent but they never affect the packed FREE.
                        _ = origD
                    case .pinStart, .pinEnd:
                        // Slots: theta, fullLen (anchor is constant, not a DOF)
                        fullGuess[lp.thetaSlot] = theta
                        fullGuess[lp.lenSlot] = dist
                    }
                }
            case (.circle, .circle(let gD)):
                // Slots: cx, cy, r at s.base
                fullGuess[s.base] = gD.center.x
                fullGuess[s.base + 1] = gD.center.y
                fullGuess[s.base + 2] = gD.radius
            case (.point, .point(let gD)):
                fullGuess[s.base] = gD.position.x
                fullGuess[s.base + 1] = gD.position.y
            default:
                // Kind mismatch — keep original.
                break
            }
        }
        // Pack FREE entries from fullGuess.
        var out: [Double] = []
        out.reserveCapacity(fallback.count)
        for i in 0..<fullGuess.count where !anchored[i] {
            out.append(fullGuess[i])
        }
        // Safety: if guess was degenerate (e.g. zero-length line) we still
        // return a vector of the right size; fallback if somehow mismatched.
        if out.count != fallback.count {
            return fallback
        }
        return out
    }
}

// MARK: - Analytic Jacobian (Wave 3 — sparsity)

/// Analytic ∂ residual / ∂ freeDOF for every solver-supported constraint.
/// Each residual touches ≤2 entities, so each row has ≤8 non-zeros. Returns
/// `nil` for constraints that should use numeric fallback (currently
/// `collinear` — the two-point-normal form) or for degenerate geometry where
/// the analytic derivative is singular (distance ≈ 0).
enum AnalyticJacobian {

    /// Returns the per-residual sparse rows for `c`, or `nil` to request
    /// numeric fallback. Each inner array is the list of (freeCol, derivative)
    /// for one residual scalar of `c`.
    static func derivatives(
        for c: Constraint,
        values: [Double],
        layout: VariableLayout,
        freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        switch c.kind {
        case .geometric(.horizontal):
            return horizontal(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.vertical):
            return vertical(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.parallel):
            return parallel(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.perpendicular):
            return perpendicular(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.coincident):
            return coincident(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.concentric):
            return concentric(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.equal):
            return equal(c, values: values, layout: layout, freeMap: freeMap)
        case .dimensional(.distance):
            return distance(c, values: values, layout: layout, freeMap: freeMap)
        case .dimensional(.radius):
            return radius(c, values: values, layout: layout, freeMap: freeMap)
        case .dimensional(.diameter):
            return diameter(c, values: values, layout: layout, freeMap: freeMap)
        case .dimensional(.horizontalDistance):
            return horizontalDistance(c, values: values, layout: layout, freeMap: freeMap)
        case .dimensional(.verticalDistance):
            return verticalDistance(c, values: values, layout: layout, freeMap: freeMap)
        case .dimensional(.angle):
            return angle(c, values: values, layout: layout, freeMap: freeMap)
        case .geometric(.collinear):
            // Two-point perpendicular-distance form — analytic is involved
            // (depends on both lines' θ,L and the anchor). Keep numeric to
            // guarantee exactness and avoid a hard-to-test branch.
            return nil
        case .geometric(.fix):
            return [] // 0 residuals
        default:
            // Unsupported kinds are rejected before the solver runs; but if we
            // somehow reach here, request numeric fallback.
            return nil
        }
    }

    // MARK: Helpers — position derivatives

    /// ∂ position / ∂ freeCol for a constraint-point (line endpoint or center).
    /// Returns list of (col, dx, dy) where dx = ∂x/∂col, dy = ∂y/∂col.
    private static func posDerivatives(
        _ p: ConstraintPoint,
        values: [Double],
        layout: VariableLayout,
        freeMap: [Int]
    ) -> [(col: Int, dx: Double, dy: Double)] {
        guard let kind = layout.kindOf(p.entityID) else { return [] }
        switch kind {
        case .line:
            return linePosDerivatives(p, values: values, layout: layout, freeMap: freeMap)
        case .circle, .arc, .ellipse:
            var out: [(Int, Double, Double)] = []
            if let (cxIdx, cyIdx) = layout.coordinateIndices(of: p) {
                // coordinateIndices already validates point == .center/.start
                let cxCol = freeMap[cxIdx]
                let cyCol = freeMap[cyIdx]
                if cxCol >= 0 { out.append((cxCol, 1, 0)) }
                if cyCol >= 0 { out.append((cyCol, 0, 1)) }
            } else if p.point == .center || p.point == .start {
                // Fallback: try direct base lookup via byID (rare — arc/ellipse always have indices)
                if let ri = layout.radiusIndex(of: p.entityID) {
                    // radiusIndex is base+2, so base is ri-2
                    let base = ri - 2
                    let cxCol = freeMap[base]
                    let cyCol = freeMap[base + 1]
                    if cxCol >= 0 { out.append((cxCol, 1, 0)) }
                    if cyCol >= 0 { out.append((cyCol, 0, 1)) }
                }
            }
            return out
        case .point:
            if p.point == .end { return [] }
            var out: [(Int, Double, Double)] = []
            if let (xIdx, yIdx) = layout.coordinateIndices(of: p) {
                let xCol = freeMap[xIdx]
                let yCol = freeMap[yIdx]
                if xCol >= 0 { out.append((xCol, 1, 0)) }
                if yCol >= 0 { out.append((yCol, 0, 1)) }
            }
            return out
        default:
            return []
        }
    }

    private static func linePosDerivatives(
        _ p: ConstraintPoint,
        values: [Double],
        layout: VariableLayout,
        freeMap: [Int]
    ) -> [(Int, Double, Double)] {
        guard let lp = layout.lineParam(of: p.entityID) else { return [] }
        let theta = values[lp.thetaSlot]
        let L = values[lp.lenSlot]
        let cosT = cos(theta), sinT = sin(theta)
        var out: [(Int, Double, Double)] = []
        let isStart = (p.point == .start)
        switch lp.mode {
        case .free, .rigid:
            let cxCol = freeMap[lp.centerSlot]
            let cyCol = freeMap[lp.centerSlot + 1]
            let thCol = freeMap[lp.thetaSlot]
            let lenCol = freeMap[lp.lenSlot]
            if isStart {
                if cxCol >= 0 { out.append((cxCol, 1, 0)) }
                if cyCol >= 0 { out.append((cyCol, 0, 1)) }
                if thCol >= 0 { out.append((thCol, L * sinT, -L * cosT)) }
                if lenCol >= 0 { out.append((lenCol, -cosT, -sinT)) }
            } else {
                // end = c + L*u
                if cxCol >= 0 { out.append((cxCol, 1, 0)) }
                if cyCol >= 0 { out.append((cyCol, 0, 1)) }
                if thCol >= 0 { out.append((thCol, -L * sinT, L * cosT)) }
                if lenCol >= 0 { out.append((lenCol, cosT, sinT)) }
            }
        case .pinStart:
            // start is anchored (constant), end = A + L*u
            if isStart { return [] }
            let thCol = freeMap[lp.thetaSlot]
            let lenCol = freeMap[lp.lenSlot]
            if thCol >= 0 { out.append((thCol, -L * sinT, L * cosT)) }
            if lenCol >= 0 { out.append((lenCol, cosT, sinT)) }
        case .pinEnd:
            // end is anchored, start = A - L*u
            if !isStart { return [] }
            let thCol = freeMap[lp.thetaSlot]
            let lenCol = freeMap[lp.lenSlot]
            if thCol >= 0 { out.append((thCol, L * sinT, -L * cosT)) }
            if lenCol >= 0 { out.append((lenCol, -cosT, -sinT)) }
        }
        return out
    }

    // MARK: Per-kind analytic rows

    private static func horizontal(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        guard let lp = layout.lineParam(of: c.points[0].entityID) else { return [[]] }
        let theta = values[lp.thetaSlot]
        let col = freeMap[lp.thetaSlot]
        if col >= 0 {
            return [[(col, cos(theta))]]
        }
        return [[]]
    }

    private static func vertical(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        guard let lp = layout.lineParam(of: c.points[0].entityID) else { return [[]] }
        let theta = values[lp.thetaSlot]
        let col = freeMap[lp.thetaSlot]
        if col >= 0 {
            return [[(col, -sin(theta))]]
        }
        return [[]]
    }

    private static func parallel(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let t1 = layout.angleValue(of: c.points[0].entityID, values: values) ?? 0
        let t2 = layout.angleValue(of: c.points[2].entityID, values: values) ?? 0
        let d = t1 - t2
        let cosD = cos(d)
        var row: [(Int, Double)] = []
        if let lp1 = layout.lineParam(of: c.points[0].entityID) {
            let col = freeMap[lp1.thetaSlot]
            if col >= 0 { row.append((col, cosD)) }
        }
        if let lp2 = layout.lineParam(of: c.points[2].entityID) {
            let col = freeMap[lp2.thetaSlot]
            if col >= 0 { row.append((col, -cosD)) }
        }
        return [row]
    }

    private static func perpendicular(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let t1 = layout.angleValue(of: c.points[0].entityID, values: values) ?? 0
        let t2 = layout.angleValue(of: c.points[2].entityID, values: values) ?? 0
        let d = t1 - t2
        let sinD = sin(d)
        var row: [(Int, Double)] = []
        if let lp1 = layout.lineParam(of: c.points[0].entityID) {
            let col = freeMap[lp1.thetaSlot]
            if col >= 0 { row.append((col, -sinD)) }
        }
        if let lp2 = layout.lineParam(of: c.points[2].entityID) {
            let col = freeMap[lp2.thetaSlot]
            if col >= 0 { row.append((col, sinD)) }
        }
        return [row]
    }

    private static func coincident(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let aDerivs = posDerivatives(c.points[0], values: values, layout: layout, freeMap: freeMap)
        let bDerivs = posDerivatives(c.points[1], values: values, layout: layout, freeMap: freeMap)
        var mapX: [Int: Double] = [:]
        var mapY: [Int: Double] = [:]
        for (col, dx, dy) in aDerivs {
            mapX[col, default: 0] += dx
            mapY[col, default: 0] += dy
        }
        for (col, dx, dy) in bDerivs {
            mapX[col, default: 0] -= dx
            mapY[col, default: 0] -= dy
        }
        var rowX: [(Int, Double)] = []
        var rowY: [(Int, Double)] = []
        for (col, v) in mapX where v != 0 { rowX.append((col, v)) }
        for (col, v) in mapY where v != 0 { rowY.append((col, v)) }
        rowX.sort { $0.0 < $1.0 }
        rowY.sort { $0.0 < $1.0 }
        return [rowX, rowY]
    }

    private static func concentric(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        // Centers coincide: cb - ca. The coincident helper is pa - pb, so flip.
        let rows = coincident(c, values: values, layout: layout, freeMap: freeMap)
        // coincident returns [rowX, rowY] for pa - pb; for concentric we need cb - ca = -(pa - pb)
        // if we reuse coincident directly, just negate.
        guard var r = rows else { return nil }
        for k in 0..<r.count {
            for i in 0..<r[k].count {
                r[k][i].1 = -r[k][i].1
            }
        }
        return r
    }

    private static func equal(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        if c.points.count >= 4 {
            // Two lines: length = factor*L
            var row: [(Int, Double)] = []
            let aID = c.points[0].entityID
            let bID = c.points[2].entityID
            if let lpA = layout.lineParam(of: aID) {
                let factor: Double = (lpA.mode == .free || lpA.mode == .rigid) ? 2.0 : 1.0
                let col = freeMap[lpA.lenSlot]
                if col >= 0 { row.append((col, factor)) }
            }
            if let lpB = layout.lineParam(of: bID) {
                let factor: Double = (lpB.mode == .free || lpB.mode == .rigid) ? 2.0 : 1.0
                let col = freeMap[lpB.lenSlot]
                if col >= 0 { row.append((col, -factor)) }
            }
            return [row]
        } else {
            // Two circular entities: equal radius
            var row: [(Int, Double)] = []
            if let ri = layout.radiusIndex(of: c.points[0].entityID) {
                let col = freeMap[ri]
                if col >= 0 { row.append((col, 1)) }
            }
            if let ri = layout.radiusIndex(of: c.points[1].entityID) {
                let col = freeMap[ri]
                if col >= 0 { row.append((col, -1)) }
            }
            return [row]
        }
    }

    private static func distance(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let a = c.points[0], b = c.points[1]
        let pa = position(a, values: values, layout: layout)
        let pb = position(b, values: values, layout: layout)
        let dx = pb.0 - pa.0, dy = pb.1 - pa.1
        let dist = (dx*dx + dy*dy).squareRoot()
        if dist < 1e-12 { return nil } // singular — fallback numeric
        let aDerivs = posDerivatives(a, values: values, layout: layout, freeMap: freeMap)
        let bDerivs = posDerivatives(b, values: values, layout: layout, freeMap: freeMap)
        var map: [Int: Double] = [:]
        // ∂dist/∂col = (dx*∂dx/∂col + dy*∂dy/∂col)/dist
        // ∂dx/∂col = ∂xb/∂col - ∂xa/∂col
        var daMap: [Int: (Double, Double)] = [:]
        var dbMap: [Int: (Double, Double)] = [:]
        for (col, ddx, ddy) in aDerivs { daMap[col] = (ddx, ddy) }
        for (col, ddx, ddy) in bDerivs { dbMap[col] = (ddx, ddy) }
        var allCols = Set(daMap.keys)
        allCols.formUnion(dbMap.keys)
        for col in allCols {
            let (adx, ady) = daMap[col] ?? (0, 0)
            let (bdx, bdy) = dbMap[col] ?? (0, 0)
            let ddx = bdx - adx
            let ddy = bdy - ady
            let d = (dx * ddx + dy * ddy) / dist
            if d != 0 { map[col] = d }
        }
        var row: [(Int, Double)] = map.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        return [row]
    }

    private static func radius(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        guard let ri = layout.radiusIndex(of: c.points[0].entityID) else { return [[]] }
        let col = freeMap[ri]
        if col >= 0 { return [[(col, 1)]] }
        return [[]]
    }

    private static func diameter(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        guard let ri = layout.radiusIndex(of: c.points[0].entityID) else { return [[]] }
        let col = freeMap[ri]
        if col >= 0 { return [[(col, 2)]] }
        return [[]]
    }

    private static func horizontalDistance(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let aDerivs = posDerivatives(c.points[0], values: values, layout: layout, freeMap: freeMap)
        let bDerivs = posDerivatives(c.points[1], values: values, layout: layout, freeMap: freeMap)
        var map: [Int: Double] = [:]
        for (col, dx, _) in aDerivs { map[col, default: 0] -= dx }
        for (col, dx, _) in bDerivs { map[col, default: 0] += dx }
        var row: [(Int, Double)] = []
        for (col, v) in map where v != 0 { row.append((col, v)) }
        row.sort { $0.0 < $1.0 }
        return [row]
    }

    private static func verticalDistance(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let aDerivs = posDerivatives(c.points[0], values: values, layout: layout, freeMap: freeMap)
        let bDerivs = posDerivatives(c.points[1], values: values, layout: layout, freeMap: freeMap)
        var map: [Int: Double] = [:]
        for (col, _, dy) in aDerivs { map[col, default: 0] -= dy }
        for (col, _, dy) in bDerivs { map[col, default: 0] += dy }
        var row: [(Int, Double)] = []
        for (col, v) in map where v != 0 { row.append((col, v)) }
        row.sort { $0.0 < $1.0 }
        return [row]
    }

    private static func angle(
        _ c: Constraint, values: [Double], layout: VariableLayout, freeMap: [Int]
    ) -> [[(Int, Double)]]? {
        let t1 = layout.angleValue(of: c.points[0].entityID, values: values) ?? 0
        let t2 = layout.angleValue(of: c.points[2].entityID, values: values) ?? 0
        let delta = (t1 - t2) - c.value
        let cosD = cos(delta)
        var row: [(Int, Double)] = []
        if let lp1 = layout.lineParam(of: c.points[0].entityID) {
            let col = freeMap[lp1.thetaSlot]
            if col >= 0 { row.append((col, cosD)) }
        }
        if let lp2 = layout.lineParam(of: c.points[2].entityID) {
            let col = freeMap[lp2.thetaSlot]
            if col >= 0 { row.append((col, -cosD)) }
        }
        return [row]
    }

    // Raw position helper for distance.
    private static func position(
        _ p: ConstraintPoint, values: [Double], layout: VariableLayout
    ) -> (Double, Double) {
        if let kind = layout.kindOf(p.entityID), case .line = kind {
            return layout.endpoint(of: p.entityID, which: p.point, values: values)
        }
        if let (xi, yi) = layout.coordinateIndices(of: p) {
            return (values[xi], values[yi])
        }
        return (0, 0)
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
