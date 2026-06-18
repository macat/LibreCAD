//
//  ConstraintSolverTests.swift
//  CADEngineTests
//
//  Unit tests for the parametric-constraint SOLVER (Wave 1). Each IMPLEMENTED
//  constraint drives a small fixture to its ANALYTIC answer within tolerance;
//  over-constrained / under-constrained / unsupported systems each return `.failed`
//  with the right classification. The solver is a PURE function (value in, value
//  out) so these run with no GPU / live view.
//

import XCTest
@testable import CADEngine

final class ConstraintSolverTests: XCTestCase {

    private func id(_ n: UInt64) -> EntityID { EntityID(n) }

    /// Tolerance for analytic checks (well above the solver's 1e-9 convergence).
    private let tol = 1e-6

    // Pull the solved line / circle / point out of a result, failing the test if
    // the solve didn't succeed or the kind is wrong.
    private func solvedLine(_ r: ConstraintSolveResult, _ id: EntityID,
                            file: StaticString = #filePath, line: UInt = #line) -> LineData? {
        guard case .solved(let geo) = r else {
            XCTFail("expected .solved, got \(r)", file: file, line: line); return nil
        }
        guard case .line(let d)? = geo[id] else {
            XCTFail("expected a line for \(id)", file: file, line: line); return nil
        }
        return d
    }
    private func solvedCircle(_ r: ConstraintSolveResult, _ id: EntityID,
                              file: StaticString = #filePath, line: UInt = #line) -> CircleData? {
        guard case .solved(let geo) = r else {
            XCTFail("expected .solved, got \(r)", file: file, line: line); return nil
        }
        guard case .circle(let d)? = geo[id] else {
            XCTFail("expected a circle for \(id)", file: file, line: line); return nil
        }
        return d
    }
    private func solvedPoint(_ r: ConstraintSolveResult, _ id: EntityID,
                             file: StaticString = #filePath, line: UInt = #line) -> PointData? {
        guard case .solved(let geo) = r else {
            XCTFail("expected .solved, got \(r)", file: file, line: line); return nil
        }
        guard case .point(let d)? = geo[id] else {
            XCTFail("expected a point for \(id)", file: file, line: line); return nil
        }
        return d
    }

    // MARK: - horizontal

    func testHorizontalLevelsTheLine() {
        // A slightly-tilted line, made horizontal. The two endpoints must share a Y.
        let lid = id(1)
        let entities: [EntityID: EntityKind] = [
            lid: .line(LineData(start: Vector(0, 0), end: Vector(10, 3)))
        ]
        let r = ConstraintSolver.solve(entities: entities,
                                       constraints: [Constraint.horizontal(line: lid)])
        guard let d = solvedLine(r, lid) else { return }
        XCTAssertEqual(d.start.y, d.end.y, accuracy: tol)
    }

    // MARK: - vertical

    func testVerticalPlumbsTheLine() {
        let lid = id(1)
        let entities: [EntityID: EntityKind] = [
            lid: .line(LineData(start: Vector(0, 0), end: Vector(4, 9)))
        ]
        let r = ConstraintSolver.solve(entities: entities,
                                       constraints: [Constraint.vertical(line: lid)])
        guard let d = solvedLine(r, lid) else { return }
        XCTAssertEqual(d.start.x, d.end.x, accuracy: tol)
    }

    // MARK: - coincident

    func testCoincidentMergesEndpoints() {
        // Two lines; fix line A entirely, make A.end coincident with B.start, then
        // B.start must move onto A.end (3,4).
        let a = id(1), b = id(2)
        let entities: [EntityID: EntityKind] = [
            a: .line(LineData(start: Vector(0, 0), end: Vector(3, 4))),
            b: .line(LineData(start: Vector(20, 20), end: Vector(30, 30)))
        ]
        let constraints = [
            Constraint.fix(line: a),
            Constraint.coincident(ConstraintPoint(entityID: a, point: .end),
                                  ConstraintPoint(entityID: b, point: .start))
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        guard let bd = solvedLine(r, b) else { return }
        XCTAssertEqual(bd.start.x, 3, accuracy: tol)
        XCTAssertEqual(bd.start.y, 4, accuracy: tol)
        // A is fixed — unchanged.
        guard let ad = solvedLine(r, a) else { return }
        XCTAssertEqual(ad.end.x, 3, accuracy: tol)
        XCTAssertEqual(ad.end.y, 4, accuracy: tol)
    }

    // MARK: - parallel

    func testParallelAlignsDirections() {
        // Fix line A horizontal (0,0)->(10,0); make B parallel. B's direction's
        // cross with A's must be 0 (i.e. B becomes horizontal too).
        let a = id(1), b = id(2)
        let entities: [EntityID: EntityKind] = [
            a: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))),
            b: .line(LineData(start: Vector(0, 5), end: Vector(8, 9)))
        ]
        let constraints = [
            Constraint.fix(line: a),
            Constraint.parallel(line: a, line: b)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        guard let bd = solvedLine(r, b) else { return }
        // Cross of A's dir (10,0) and B's dir must be ~0 → B's dy ~0.
        let bdy = bd.end.y - bd.start.y
        XCTAssertEqual(bdy, 0, accuracy: 1e-5)
    }

    // MARK: - perpendicular

    func testPerpendicularSquaresDirections() {
        // Fix A horizontal; make B perpendicular → B's direction dot A's == 0 (B
        // vertical). Pin B's start so it has a free end to rotate.
        let a = id(1), b = id(2)
        let entities: [EntityID: EntityKind] = [
            a: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))),
            b: .line(LineData(start: Vector(2, 0), end: Vector(9, 1)))
        ]
        let constraints = [
            Constraint.fix(line: a),
            Constraint.fix(ConstraintPoint(entityID: b, point: .start)),
            Constraint.perpendicular(line: a, line: b)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        guard let bd = solvedLine(r, b) else { return }
        let ad = LineData(start: Vector(0, 0), end: Vector(10, 0))
        let adir = ad.end - ad.start
        let bdir = bd.end - bd.start
        XCTAssertEqual(adir.dot(bdir), 0, accuracy: 1e-5)
    }

    // MARK: - distance

    func testDistanceDrivesGapToValue() {
        // Fix point P1 at origin; drive the distance P1—P2 to 7. P2 moves to a point
        // exactly 7 away (the solver finds the nearest satisfying P2 along the line).
        let p1 = id(1), p2 = id(2)
        let entities: [EntityID: EntityKind] = [
            p1: .point(PointData(position: Vector(0, 0))),
            p2: .point(PointData(position: Vector(3, 0)))   // currently 3 away
        ]
        let constraints = [
            Constraint.fix(ConstraintPoint(entityID: p1, point: .start)),
            Constraint.distance(ConstraintPoint(entityID: p1, point: .start),
                                ConstraintPoint(entityID: p2, point: .start), value: 7)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        guard let p2d = solvedPoint(r, p2) else { return }
        let dist = Vector(0, 0).distance(to: p2d.position)
        XCTAssertEqual(dist, 7, accuracy: tol)
        // P1 fixed at origin.
        guard let p1d = solvedPoint(r, p1) else { return }
        XCTAssertEqual(p1d.position.x, 0, accuracy: tol)
        XCTAssertEqual(p1d.position.y, 0, accuracy: tol)
    }

    func testDistanceBetweenLineEndpoints() {
        // Lengthen a line to a target distance between its endpoints, with the start
        // fixed. Start (0,0), end (3,0); drive |start-end| to 10 → end at x≈10.
        let lid = id(1)
        let entities: [EntityID: EntityKind] = [
            lid: .line(LineData(start: Vector(0, 0), end: Vector(3, 0)))
        ]
        let constraints = [
            Constraint.fix(ConstraintPoint(entityID: lid, point: .start)),
            Constraint.distance(ConstraintPoint(entityID: lid, point: .start),
                                ConstraintPoint(entityID: lid, point: .end), value: 10)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        guard let d = solvedLine(r, lid) else { return }
        XCTAssertEqual(d.start.distance(to: d.end), 10, accuracy: tol)
        XCTAssertEqual(d.start.x, 0, accuracy: tol)
    }

    // MARK: - radius

    func testRadiusDrivesCircleRadius() {
        let cid = id(1)
        let entities: [EntityID: EntityKind] = [
            cid: .circle(CircleData(center: Vector(5, 5), radius: 2))
        ]
        let r = ConstraintSolver.solve(entities: entities,
                                       constraints: [Constraint.radius(circle: cid, value: 8.5)])
        guard let d = solvedCircle(r, cid) else { return }
        XCTAssertEqual(d.radius, 8.5, accuracy: tol)
        // Center untouched (no constraint pulls it).
        XCTAssertEqual(d.center.x, 5, accuracy: tol)
        XCTAssertEqual(d.center.y, 5, accuracy: tol)
    }

    // MARK: - combined system (multiple constraints, one component)

    func testRightTriangleLegs() {
        // Build a right angle at the origin: line A (origin→x) horizontal & fixed,
        // line B sharing the origin start, perpendicular to A, length 6.
        let a = id(1), b = id(2)
        let entities: [EntityID: EntityKind] = [
            a: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))),
            b: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        ]
        let constraints = [
            Constraint.fix(line: a),
            Constraint.coincident(ConstraintPoint(entityID: a, point: .start),
                                  ConstraintPoint(entityID: b, point: .start)),
            Constraint.perpendicular(line: a, line: b),
            Constraint.distance(ConstraintPoint(entityID: b, point: .start),
                                ConstraintPoint(entityID: b, point: .end), value: 6)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        guard let bd = solvedLine(r, b) else { return }
        // B starts at origin, is perpendicular to the X axis (so vertical), length 6.
        XCTAssertEqual(bd.start.x, 0, accuracy: tol)
        XCTAssertEqual(bd.start.y, 0, accuracy: tol)
        XCTAssertEqual(abs(bd.end.x), 0, accuracy: 1e-5)        // vertical → no x
        XCTAssertEqual(abs(bd.end.y), 6, accuracy: 1e-5)        // length 6
    }

    // MARK: - already-satisfied (trivial)

    func testAlreadySatisfiedReturnsSolvedUnchanged() {
        let lid = id(1)
        let entities: [EntityID: EntityKind] = [
            lid: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))   // already horizontal
        ]
        let r = ConstraintSolver.solve(entities: entities,
                                       constraints: [Constraint.horizontal(line: lid)])
        guard let d = solvedLine(r, lid) else { return }
        XCTAssertEqual(d.start.y, d.end.y, accuracy: tol)
    }

    // MARK: - FAILURE classifications

    func testUnsupportedConstraintFails() {
        let entities: [EntityID: EntityKind] = [
            id(1): .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        ]
        // tangent is declared but unimplemented.
        let c = Constraint(kind: .geometric(.tangent),
                           points: [ConstraintPoint(entityID: id(1))])
        let r = ConstraintSolver.solve(entities: entities, constraints: [c])
        XCTAssertEqual(r, .failed(.unsupported))
    }

    func testOverConstrainedReturnsFailed() {
        // Everything fixed, but a distance demands a value the (fixed) geometry can't
        // meet → no free DOFs + an unsatisfiable residual → .overConstrained.
        let p1 = id(1), p2 = id(2)
        let entities: [EntityID: EntityKind] = [
            p1: .point(PointData(position: Vector(0, 0))),
            p2: .point(PointData(position: Vector(3, 0)))    // actual distance 3
        ]
        let constraints = [
            Constraint.fix(ConstraintPoint(entityID: p1, point: .start)),
            Constraint.fix(ConstraintPoint(entityID: p2, point: .start)),
            // Demand distance 10 — but both points are fixed, so it can't be met.
            Constraint.distance(ConstraintPoint(entityID: p1, point: .start),
                                ConstraintPoint(entityID: p2, point: .start), value: 10)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        XCTAssertEqual(r, .failed(.overConstrained))
    }

    func testUnderConstrainedContradictionDoesNotConverge() {
        // A contradictory system with free DOFs: the SAME line told to be both
        // horizontal AND vertical AND length 5 — its endpoints would have to coincide
        // (h+v ⇒ point) yet be 5 apart. Unsatisfiable → .didNotConverge.
        let lid = id(1)
        let entities: [EntityID: EntityKind] = [
            lid: .line(LineData(start: Vector(0, 0), end: Vector(4, 3)))
        ]
        let constraints = [
            Constraint.fix(ConstraintPoint(entityID: lid, point: .start)),
            Constraint.horizontal(line: lid),
            Constraint.vertical(line: lid),
            Constraint.distance(ConstraintPoint(entityID: lid, point: .start),
                                ConstraintPoint(entityID: lid, point: .end), value: 5)
        ]
        let r = ConstraintSolver.solve(entities: entities, constraints: constraints)
        XCTAssertEqual(r, .failed(.didNotConverge))
    }

    func testReferenceToMissingEntityIsInvalid() {
        // A constraint references id 99 which is not in `entities`.
        let entities: [EntityID: EntityKind] = [
            id(1): .line(LineData(start: Vector(0, 0), end: Vector(1, 0)))
        ]
        let c = Constraint.coincident(ConstraintPoint(entityID: id(1), point: .start),
                                      ConstraintPoint(entityID: id(99), point: .start))
        let r = ConstraintSolver.solve(entities: entities, constraints: [c])
        XCTAssertEqual(r, .failed(.invalidInput))
    }

    func testEmptyEntitiesIsInvalid() {
        let r = ConstraintSolver.solve(entities: [:], constraints: [])
        XCTAssertEqual(r, .failed(.invalidInput))
    }

    // MARK: - Anti-collapse / minimal-change (the user's bug + the rewrite gate)
    //
    // The first solver minimized Σresidual² over raw endpoints and could satisfy a
    // direction constraint on UNDER-constrained (free) lines by SHRINKING one to ~0
    // length so the two overlapped ("become one"). The re-parametrized, min-
    // displacement solver must instead ROTATE the lines while PRESERVING length and
    // pick the solution nearest the original. These are the gating tests.

    /// The signed length of a solved line's direction vector.
    private func length(_ d: LineData) -> Double { d.start.distance(to: d.end) }
    /// The dot of two solved lines' direction vectors.
    private func dirDot(_ a: LineData, _ b: LineData) -> Double {
        (a.end - a.start).dot(b.end - b.start)
    }
    /// The cross of two solved lines' direction vectors.
    private func dirCross(_ a: LineData, _ b: LineData) -> Double {
        let da = a.end - a.start, db = b.end - b.start
        return da.x * db.y - da.y * db.x
    }

    /// THE USER'S EXACT BUG: perpendicular on two FREE near-parallel lines must
    /// rotate them perpendicular while keeping BOTH lengths — never collapse one to
    /// make the two overlap.
    func testPerpendicularOnTwoFreeNearParallelLinesNoCollapse() {
        let a = id(1), b = id(2)
        let la = LineData(start: Vector(0, 0), end: Vector(10, 0))   // length 10
        let lb = LineData(start: Vector(0, 1), end: Vector(10, 2))   // length ~10.05, near-parallel
        let origA = length(la), origB = length(lb)
        let r = ConstraintSolver.solve(entities: [a: .line(la), b: .line(lb)],
                                       constraints: [Constraint.perpendicular(line: a, line: b)])
        guard let da = solvedLine(r, a), let db = solvedLine(r, b) else { return }
        // The constraint is satisfied …
        XCTAssertEqual(dirDot(da, db), 0, accuracy: 1e-5, "lines must be perpendicular")
        // … WITHOUT collapsing either line (the bug shrank one to ~0).
        XCTAssertEqual(length(da), origA, accuracy: 1.5, "line A must keep ~its length")
        XCTAssertEqual(length(db), origB, accuracy: 1.5, "line B must keep ~its length")
        // And neither degenerated to a point.
        XCTAssertGreaterThan(length(da), 1.0, "line A must not collapse")
        XCTAssertGreaterThan(length(db), 1.0, "line B must not collapse")
    }

    /// Parallel on two free lines: aligns directions, preserves both lengths.
    func testParallelOnTwoFreeLinesNoCollapse() {
        let a = id(1), b = id(2)
        let la = LineData(start: Vector(0, 0), end: Vector(10, 1))
        let lb = LineData(start: Vector(0, 5), end: Vector(8, 2))
        let origA = length(la), origB = length(lb)
        let r = ConstraintSolver.solve(entities: [a: .line(la), b: .line(lb)],
                                       constraints: [Constraint.parallel(line: a, line: b)])
        guard let da = solvedLine(r, a), let db = solvedLine(r, b) else { return }
        XCTAssertEqual(dirCross(da, db), 0, accuracy: 1e-5, "lines must be parallel")
        XCTAssertEqual(length(da), origA, accuracy: 1.5, "line A must keep ~its length")
        XCTAssertEqual(length(db), origB, accuracy: 1.5, "line B must keep ~its length")
        XCTAssertGreaterThan(length(da), 1.0)
        XCTAssertGreaterThan(length(db), 1.0)
    }

    /// Perpendicular on two free lines ALREADY perpendicular: the minimal-change
    /// solver must leave the geometry essentially untouched.
    func testPerpendicularOnAlreadyPerpendicularLinesIsMinimalChange() {
        let a = id(1), b = id(2)
        let la = LineData(start: Vector(0, 0), end: Vector(10, 0))   // horizontal
        let lb = LineData(start: Vector(3, 0), end: Vector(3, 7))    // vertical (already ⊥)
        let r = ConstraintSolver.solve(entities: [a: .line(la), b: .line(lb)],
                                       constraints: [Constraint.perpendicular(line: a, line: b)])
        guard let da = solvedLine(r, a), let db = solvedLine(r, b) else { return }
        // Already satisfied → nearest solution is the original geometry, unchanged.
        XCTAssertEqual(da.start.x, 0, accuracy: tol);  XCTAssertEqual(da.start.y, 0, accuracy: tol)
        XCTAssertEqual(da.end.x, 10, accuracy: tol);   XCTAssertEqual(da.end.y, 0, accuracy: tol)
        XCTAssertEqual(db.start.x, 3, accuracy: tol);  XCTAssertEqual(db.start.y, 0, accuracy: tol)
        XCTAssertEqual(db.end.x, 3, accuracy: tol);    XCTAssertEqual(db.end.y, 7, accuracy: tol)
    }

    /// A STRESS chain: H(A) → A‖B → B⊥C → C‖D over four free lines. The whole chain
    /// converges and NO line collapses (each keeps its original length).
    func testFreeLineConstraintChainConvergesWithoutCollapse() {
        let a = id(1), b = id(2), c = id(3), d = id(4)
        let la = LineData(start: Vector(0, 0), end: Vector(10, 1))
        let lb = LineData(start: Vector(0, 5), end: Vector(9, 7))
        let lc = LineData(start: Vector(2, 2), end: Vector(11, 3))
        let ld = LineData(start: Vector(1, 8), end: Vector(10, 10))
        let orig = [a: length(la), b: length(lb), c: length(lc), d: length(ld)]
        let constraints = [
            Constraint.horizontal(line: a),
            Constraint.parallel(line: a, line: b),
            Constraint.perpendicular(line: b, line: c),
            Constraint.parallel(line: c, line: d),
        ]
        let r = ConstraintSolver.solve(
            entities: [a: .line(la), b: .line(lb), c: .line(lc), d: .line(ld)],
            constraints: constraints)
        guard let ra = solvedLine(r, a), let rb = solvedLine(r, b),
              let rc = solvedLine(r, c), let rd = solvedLine(r, d) else { return }
        // Relationships hold.
        XCTAssertEqual(ra.start.y, ra.end.y, accuracy: 1e-5, "A horizontal")
        XCTAssertEqual(dirCross(ra, rb), 0, accuracy: 1e-5, "A ‖ B")
        XCTAssertEqual(dirDot(rb, rc), 0, accuracy: 1e-5, "B ⊥ C")
        XCTAssertEqual(dirCross(rc, rd), 0, accuracy: 1e-5, "C ‖ D")
        // No line collapsed — each kept its original length.
        XCTAssertEqual(length(ra), orig[a]!, accuracy: 1e-4, "A length preserved")
        XCTAssertEqual(length(rb), orig[b]!, accuracy: 1e-4, "B length preserved")
        XCTAssertEqual(length(rc), orig[c]!, accuracy: 1e-4, "C length preserved")
        XCTAssertEqual(length(rd), orig[d]!, accuracy: 1e-4, "D length preserved")
    }

    // MARK: - LinearSolve unit (the Cholesky core)

    func testLinearSolveSPD() {
        // [[4,1],[1,3]] x = [1,2]  →  x = [1/11, 7/11].
        let A = [[4.0, 1.0], [1.0, 3.0]]
        let x = LinearSolve.solveSPD(A, rhs: [1, 2])
        XCTAssertNotNil(x)
        XCTAssertEqual(x![0], 1.0 / 11.0, accuracy: 1e-12)
        XCTAssertEqual(x![1], 7.0 / 11.0, accuracy: 1e-12)
    }

    func testLinearSolveRejectsNonSPD() {
        // A zero matrix is not positive-definite → nil.
        XCTAssertNil(LinearSolve.solveSPD([[0.0, 0.0], [0.0, 0.0]], rhs: [1, 1]))
    }
}
