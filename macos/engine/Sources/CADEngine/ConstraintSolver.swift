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
//  ## Approach (Levenberg–Marquardt least-squares)
//  Each free degree of freedom (a line endpoint x/y, a point x/y, a circle center
//  x/y + radius) is one variable in a packed `[Double]` vector. `fix` constraints
//  REMOVE those DOFs (the coordinate is anchored at its current value and never
//  varied). Each constraint contributes one or more RESIDUALS — a scalar that is 0
//  exactly when the constraint is satisfied:
//    coincident     two points equal      → (Δx, Δy)
//    horizontal     line dy == 0          → (ey − sy)
//    vertical       line dx == 0          → (ex − sx)
//    parallel       cross(d1, d2) == 0    → d1.x·d2.y − d1.y·d2.x
//    perpendicular  dot(d1, d2)  == 0     → d1.x·d2.x + d1.y·d2.y
//    distance       |p2 − p1| == value    → |p2 − p1| − value
//    radius         r == value            → r − value
//  The solver minimizes Σ residual² via Levenberg–Marquardt with a NUMERIC
//  (finite-difference) Jacobian, LM damping, and an iteration cap. It returns
//  `.solved(updatedGeometry)` on convergence, or `.failed(reason)` for a singular
//  / non-converging (over- or under-constrained) system — NEVER a partial /
//  garbage write.
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
        /// Residual-norm convergence tolerance (the solve succeeds when the RMS
        /// residual drops below this). Default 1e-9 (well inside engine tolerance).
        public var convergenceTolerance: Double
        /// Max Gauss–Newton/LM iterations before declaring `.didNotConverge`.
        public var maxIterations: Int
        /// Finite-difference step for the numeric Jacobian.
        public var fdStep: Double
        /// Initial LM damping factor (λ). Adapted up on a rejected step, down on an
        /// accepted one.
        public var initialDamping: Double

        public init(
            convergenceTolerance: Double = 1e-9,
            maxIterations: Int = 200,
            fdStep: Double = 1e-7,
            initialDamping: Double = 1e-3
        ) {
            self.convergenceTolerance = convergenceTolerance
            self.maxIterations = maxIterations
            self.fdStep = fdStep
            self.initialDamping = initialDamping
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

        // (1) Build the variable layout: each solvable entity contributes its DOFs.
        var layout = VariableLayout()
        for (id, kind) in entities.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            layout.register(id: id, kind: kind)
        }
        guard !layout.entities.isEmpty else { return .failed(.invalidInput) }

        // (2) Apply `fix` constraints — anchor the named coordinates (remove DOFs).
        for c in constraints where c.kind == .geometric(.fix) {
            for p in c.points {
                layout.anchor(point: p)
            }
        }

        // (3) Validate every constraint resolves against the layout (catches a
        //     reference to an entity not in `entities`, or a bad point/kind pairing).
        for c in constraints {
            guard ResidualBuilder.canBuild(c, layout: layout) else {
                return .failed(.invalidInput)
            }
        }

        // (4) The packed free-variable vector (the current values of the free DOFs).
        var x = layout.packFree()
        let residualCount = constraints.reduce(0) { $0 + ResidualBuilder.residualCount($1) }

        // Nothing to satisfy → trivially solved at the current geometry.
        if residualCount == 0 {
            return .solved(layout.unpackAll(free: x))
        }

        // The residual evaluator at a given free-variable vector.
        func residuals(_ free: [Double]) -> [Double] {
            let full = layout.expand(free: free)
            var out: [Double] = []
            out.reserveCapacity(residualCount)
            for c in constraints {
                ResidualBuilder.appendResiduals(of: c, values: full, layout: layout, into: &out)
            }
            return out
        }

        // RMS norm of a residual vector.
        func rms(_ r: [Double]) -> Double {
            guard !r.isEmpty else { return 0 }
            let ss = r.reduce(0) { $0 + $1 * $1 }
            return (ss / Double(r.count)).squareRoot()
        }

        var r = residuals(x)
        var err = rms(r)
        if err <= options.convergenceTolerance {
            return .solved(layout.unpackAll(free: x))
        }

        // No free DOFs but residuals remain unsatisfied → over-constrained / locked.
        if x.isEmpty {
            return .failed(.overConstrained)
        }

        // (5) Levenberg–Marquardt loop with a numeric Jacobian.
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
                let rp = residuals(xp)
                for i in 0..<m {
                    jac[i][j] = (rp[i] - r[i]) / h
                }
            }

            // Normal equations: (JᵀJ + λ·diag(JᵀJ)) δ = −Jᵀr  (LM).
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
            // up). The damped diagonal makes the system well-conditioned even when
            // JᵀJ is singular (under-constrained) — the step is then small but valid.
            var stepAccepted = false
            for _ in 0..<12 {
                var aMat = jtj
                // LM damping with a Levenberg FLOOR on each diagonal: `λ·(JᵀJ_dd + 1)`.
                // The `+1` floor is essential for RANK-DEFICIENT systems (e.g. an
                // under-constrained distance whose JᵀJ has a near-zero diagonal in the
                // free direction): a pure Marquardt `λ·JᵀJ_dd` term would leave that
                // direction nearly undamped, so Cholesky produces a wild step that is
                // always rejected (λ explodes, the solve stalls). The floor strongly
                // damps the degenerate direction to a small, safe step instead.
                for d in 0..<n { aMat[d][d] += lambda * (jtj[d][d] + 1.0) }

                guard let delta = LinearSolve.solveSPD(aMat, rhs: jtr) else {
                    // Singular even with damping → bump λ and retry.
                    lambda *= 10
                    continue
                }

                var xNew = x
                for d in 0..<n { xNew[d] -= delta[d] }     // (JᵀJ+λD)δ = +Jᵀr ⇒ x -= δ
                let rNew = residuals(xNew)
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

            if err <= options.convergenceTolerance {
                return .solved(layout.unpackAll(free: x))
            }
            if !stepAccepted {
                // Could not make progress this outer iteration → stalled.
                break
            }
        }

        // Converged late inside the loop?
        if err <= options.convergenceTolerance {
            return .solved(layout.unpackAll(free: x))
        }
        return .failed(.didNotConverge)
    }
}

// MARK: - Variable layout (DOF packing + fix anchoring + point resolution)

/// Maps a component's entities to a flat variable vector and back. Each entity
/// owns a contiguous block of FULL-variable slots (a line: sx,sy,ex,ey; a circle:
/// cx,cy,r; a point: px,py); `fix` anchors specific slots (they keep their current
/// value and are excluded from the FREE vector the optimizer varies).
struct VariableLayout {
    /// One entity's slot block in the full-variable vector.
    struct EntitySlots {
        let id: EntityID
        let kind: EntityKind
        /// The full-vector index where this entity's block starts.
        let base: Int
        /// How many slots (4 line / 3 circle / 2 point).
        let width: Int
    }

    private(set) var entities: [EntitySlots] = []
    /// The current value of every FULL slot (free + anchored), index == full-vector.
    private(set) var fullValues: [Double] = []
    /// Whether each full slot is anchored (true == fixed, excluded from `free`).
    private var anchored: [Bool] = []
    /// id → its `EntitySlots` (for point resolution).
    private var byID: [EntityID: EntitySlots] = [:]

    /// Registers an entity's DOFs (only solvable kinds add slots; others are ignored
    /// — they act as rigid anchors with no free variables).
    mutating func register(id: EntityID, kind: EntityKind) {
        let base = fullValues.count
        switch kind {
        case .line(let d):
            fullValues.append(contentsOf: [d.start.x, d.start.y, d.end.x, d.end.y])
            anchored.append(contentsOf: [false, false, false, false])
            addEntity(id: id, kind: kind, base: base, width: 4)
        case .circle(let d):
            fullValues.append(contentsOf: [d.center.x, d.center.y, d.radius])
            anchored.append(contentsOf: [false, false, false])
            addEntity(id: id, kind: kind, base: base, width: 3)
        case .point(let d):
            fullValues.append(contentsOf: [d.position.x, d.position.y])
            anchored.append(contentsOf: [false, false])
            addEntity(id: id, kind: kind, base: base, width: 2)
        default:
            // Non-solvable kind: registered with zero width so references still
            // resolve to its (rigid) geometry but it contributes no free DOFs.
            addEntity(id: id, kind: kind, base: base, width: 0)
        }
    }

    private mutating func addEntity(id: EntityID, kind: EntityKind, base: Int, width: Int) {
        let slots = EntitySlots(id: id, kind: kind, base: base, width: width)
        entities.append(slots)
        byID[id] = slots
    }

    /// Anchors the full slots a constraint-point names (a `fix`): for a line point
    /// that's its (x,y); for a circle center its (cx,cy); for a point its (x,y).
    mutating func anchor(point p: ConstraintPoint) {
        guard let (xi, yi) = coordinateIndices(of: p) else { return }
        anchored[xi] = true
        anchored[yi] = true
    }

    /// The (xIndex, yIndex) FULL-vector slots of a constraint-point, or `nil` if the
    /// entity is absent / the point doesn't apply to its kind.
    func coordinateIndices(of p: ConstraintPoint) -> (Int, Int)? {
        guard let s = byID[p.entityID] else { return nil }
        switch s.kind {
        case .line:
            switch p.point {
            case .start:          return (s.base, s.base + 1)
            case .end:            return (s.base + 2, s.base + 3)
            case .center:         return nil          // a line has no "center" point
            }
        case .circle:
            // Only the center is a positional point of a circle.
            return p.point == .center || p.point == .start ? (s.base, s.base + 1) : nil
        case .point:
            // A point's sole position; .start/.center are interchangeable here.
            return p.point == .end ? nil : (s.base, s.base + 1)
        default:
            return nil
        }
    }

    /// The FULL-vector slot of a circle's RADIUS, or `nil` if `id` is not a circle.
    func radiusIndex(of id: EntityID) -> Int? {
        guard let s = byID[id], case .circle = s.kind else { return nil }
        return s.base + 2
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
                nd.start = Vector(full[s.base], full[s.base + 1])
                nd.end = Vector(full[s.base + 2], full[s.base + 3])
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
            case .collinear, .tangent, .equal, .concentric, .symmetric:
                return 0                                     // unsupported (rejected earlier)
            }
        case .dimensional(let d):
            switch d {
            case .distance, .radius:           return 1
            case .horizontalDistance, .verticalDistance, .diameter, .angle:
                return 0                                     // unsupported (rejected earlier)
            }
        }
    }

    /// Whether `c` can be evaluated against `layout` (every referenced point/kind
    /// resolves). `fix` always builds (its anchoring is done before this).
    static func canBuild(_ c: Constraint, layout: VariableLayout) -> Bool {
        switch c.kind {
        case .geometric(.fix):
            // Every fixed point must resolve to a coordinate (else it's a bad ref).
            return c.points.allSatisfy { layout.coordinateIndices(of: $0) != nil }

        case .geometric(.coincident), .dimensional(.distance):
            guard c.points.count >= 2 else { return false }
            return layout.coordinateIndices(of: c.points[0]) != nil
                && layout.coordinateIndices(of: c.points[1]) != nil

        case .geometric(.horizontal), .geometric(.vertical):
            guard c.points.count >= 2 else { return false }
            return layout.coordinateIndices(of: c.points[0]) != nil
                && layout.coordinateIndices(of: c.points[1]) != nil

        case .geometric(.parallel), .geometric(.perpendicular):
            guard c.points.count >= 4 else { return false }
            return (0..<4).allSatisfy { layout.coordinateIndices(of: c.points[$0]) != nil }

        case .dimensional(.radius):
            guard let first = c.points.first else { return false }
            return layout.radiusIndex(of: first.entityID) != nil

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
            let pa = point(a, values, layout), pb = point(b, values, layout)
            out.append(pa.0 - pb.0)   // Δx
            out.append(pa.1 - pb.1)   // Δy

        case .geometric(.horizontal):
            // The line's two endpoints share a Y: ey − sy == 0.
            let s = point(c.points[0], values, layout)
            let e = point(c.points[1], values, layout)
            out.append(e.1 - s.1)

        case .geometric(.vertical):
            // ex − sx == 0.
            let s = point(c.points[0], values, layout)
            let e = point(c.points[1], values, layout)
            out.append(e.0 - s.0)

        case .geometric(.parallel):
            let d1 = direction(c.points[0], c.points[1], values, layout)
            let d2 = direction(c.points[2], c.points[3], values, layout)
            // cross(d1, d2) == 0.
            out.append(d1.0 * d2.1 - d1.1 * d2.0)

        case .geometric(.perpendicular):
            let d1 = direction(c.points[0], c.points[1], values, layout)
            let d2 = direction(c.points[2], c.points[3], values, layout)
            // dot(d1, d2) == 0.
            out.append(d1.0 * d2.0 + d1.1 * d2.1)

        case .dimensional(.distance):
            let pa = point(c.points[0], values, layout)
            let pb = point(c.points[1], values, layout)
            let dx = pb.0 - pa.0, dy = pb.1 - pa.1
            out.append((dx * dx + dy * dy).squareRoot() - c.value)

        case .dimensional(.radius):
            if let ri = layout.radiusIndex(of: c.points[0].entityID) {
                out.append(values[ri] - c.value)
            }

        default:
            return   // unsupported (rejected earlier)
        }
    }

    /// The (x, y) of a constraint-point from the FULL vector.
    private static func point(_ p: ConstraintPoint, _ values: [Double], _ layout: VariableLayout) -> (Double, Double) {
        guard let (xi, yi) = layout.coordinateIndices(of: p) else { return (0, 0) }
        return (values[xi], values[yi])
    }

    /// The (dx, dy) direction `from → to` from the FULL vector.
    private static func direction(_ from: ConstraintPoint, _ to: ConstraintPoint,
                                  _ values: [Double], _ layout: VariableLayout) -> (Double, Double) {
        let a = point(from, values, layout)
        let b = point(to, values, layout)
        return (b.0 - a.0, b.1 - a.1)
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
