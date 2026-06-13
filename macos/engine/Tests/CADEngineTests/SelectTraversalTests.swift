//
//  SelectTraversalTests.swift
//  CADEngineTests
//
//  Tests for the engine selection-traversal helpers (F18, WAVE 2 w2-select):
//  `SelectionTraversal.connected(...)` (transitive closure over shared endpoints)
//  and `SelectionTraversal.contour(...)` (follow a closed loop from a seed). These
//  are PURE engine functions the UI/menu wires later — these tests pin the
//  algorithm + tolerance directly, no UI/Metal target needed.
//
//  Suites are domain-prefixed (CONVENTIONS.md §7) so parallel fan-out test files
//  can't collide at the shared test-target namespace.
//
//  Coverage:
//    - a chain of touching lines from a seed selects the WHOLE chain,
//    - a separate disjoint group is NOT pulled in,
//    - a closed loop's contour returns exactly the loop,
//    - an open chain / ambiguous branch yields NO contour,
//    - tolerance, closed-shape, and visibility edge cases.
//
//  GPLv2-or-later (LibreCAD derivative). Contour semantics port
//  RS_Selection::selectContour (librecad/src/lib/engine/rs_selection.cpp).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_Selection).
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Shared builder

/// A drawing + quadtree builder for traversal tests, on the main actor
/// (`CADDrawing` is `@MainActor`). Each `add*` mints the entity, inserts its bbox
/// into the index, and returns the id so tests can assert by id.
@MainActor
private final class TraversalScene {
    let drawing = CADDrawing()
    let quadtree = Quadtree()

    @discardableResult
    func add(_ kind: EntityKind, flags: EntityFlags = .default) -> EntityID {
        let id = drawing.add(EntityRecord(id: EntityID(0), flags: flags, kind: kind))
        quadtree.insert(id, bounds: drawing.entity(id)!.boundingBox())
        return id
    }

    @discardableResult
    func line(_ a: Vector, _ b: Vector, flags: EntityFlags = .default) -> EntityID {
        add(.line(LineData(start: a, end: b)), flags: flags)
    }

    @discardableResult
    func arc(center: Vector, radius: Double, start: Double, end: Double,
             reversed: Bool = false) -> EntityID {
        add(.arc(ArcData(center: center, radius: radius,
                         startAngle: start, endAngle: end, reversed: reversed)))
    }

    @discardableResult
    func circle(center: Vector, radius: Double) -> EntityID {
        add(.circle(CircleData(center: center, radius: radius)))
    }

    @discardableResult
    func closedPolyline(_ pts: [Vector]) -> EntityID {
        add(.polyline(PolylineData(vertices: pts.map { PolylineVertex(point: $0) }, closed: true)))
    }

    @discardableResult
    func openPolyline(_ pts: [Vector]) -> EntityID {
        add(.polyline(PolylineData(vertices: pts.map { PolylineVertex(point: $0) }, closed: false)))
    }
}

// MARK: - Endpoint / connection unit tests

@MainActor
@Suite("CADEngine select-traversal endpoints")
struct SelectTraversalEndpointTests {

    @Test("line exposes both ends; circle exposes none")
    func lineVsCircleEndpoints() {
        let l = EntityRecord(id: EntityID(1),
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let c = EntityRecord(id: EntityID(2),
                             kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        #expect(SelectionTraversal.endpoints(of: l).count == 2)
        #expect(SelectionTraversal.endpoints(of: c).isEmpty)
    }

    @Test("open polyline has ends; closed polyline has none")
    func polylineEndpoints() {
        let pts = [Vector(0, 0), Vector(1, 0), Vector(1, 1)]
        let open = EntityRecord(id: EntityID(1),
                                kind: .polyline(PolylineData(vertices: pts.map { PolylineVertex(point: $0) },
                                                             closed: false)))
        let closed = EntityRecord(id: EntityID(2),
                                  kind: .polyline(PolylineData(vertices: pts.map { PolylineVertex(point: $0) },
                                                               closed: true)))
        let oe = SelectionTraversal.endpoints(of: open)
        #expect(oe.count == 2)
        #expect(oe[0] == Vector(0, 0))
        #expect(oe[1] == Vector(1, 1))
        #expect(SelectionTraversal.endpoints(of: closed).isEmpty)
    }

    @Test("areConnected: touching lines yes, gapped lines no")
    func areConnectedBasic() {
        let a = EntityRecord(id: EntityID(1),
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2),
                             kind: .line(LineData(start: Vector(5, 0), end: Vector(5, 5))))
        let far = EntityRecord(id: EntityID(3),
                               kind: .line(LineData(start: Vector(100, 0), end: Vector(110, 0))))
        #expect(SelectionTraversal.areConnected(a, b))
        #expect(!SelectionTraversal.areConnected(a, far))
        // Symmetric.
        #expect(SelectionTraversal.areConnected(b, a))
    }

    @Test("areConnected honors tolerance for a small gap")
    func areConnectedTolerance() {
        let a = EntityRecord(id: EntityID(1),
                             kind: .line(LineData(start: Vector(0, 0), end: Vector(5, 0))))
        let b = EntityRecord(id: EntityID(2),
                             kind: .line(LineData(start: Vector(5.01, 0), end: Vector(10, 0))))
        // Default (1e-10) tolerance: the 0.01 gap is NOT connected.
        #expect(!SelectionTraversal.areConnected(a, b))
        // A 0.1 tolerance bridges the 0.01 gap.
        #expect(SelectionTraversal.areConnected(a, b, tolerance: 0.1))
    }

    @Test("two closed shapes are never connected (no free ends)")
    func closedShapesNeverConnected() {
        let c1 = EntityRecord(id: EntityID(1),
                              kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        let c2 = EntityRecord(id: EntityID(2),
                              kind: .circle(CircleData(center: Vector(0, 0), radius: 5)))
        #expect(!SelectionTraversal.areConnected(c1, c2))
    }
}

// MARK: - connected(...) tests

@MainActor
@Suite("CADEngine select-connected")
struct SelectConnectedTests {

    /// A chain of touching lines from a seed selects the WHOLE chain.
    @Test("chain of touching lines → all selected")
    func chainSelectsAll() {
        let s = TraversalScene()
        let a = s.line(Vector(0, 0), Vector(5, 0))
        let b = s.line(Vector(5, 0), Vector(5, 5))
        let c = s.line(Vector(5, 5), Vector(10, 5))
        let d = s.line(Vector(10, 5), Vector(10, 10))

        let result = SelectionTraversal.connected(seed: a, in: s.drawing, using: s.quadtree)
        #expect(result == Set([a, b, c, d]))
    }

    /// A separate disjoint group is NOT included.
    @Test("disjoint group is NOT pulled in")
    func disjointGroupExcluded() {
        let s = TraversalScene()
        // Group 1 — a 2-line chain near the origin.
        let a = s.line(Vector(0, 0), Vector(5, 0))
        let b = s.line(Vector(5, 0), Vector(5, 5))
        // Group 2 — a disjoint 2-line chain far away.
        let c = s.line(Vector(100, 100), Vector(105, 100))
        let d = s.line(Vector(105, 100), Vector(105, 105))

        let fromA = SelectionTraversal.connected(seed: a, in: s.drawing, using: s.quadtree)
        #expect(fromA == Set([a, b]))
        #expect(!fromA.contains(c))
        #expect(!fromA.contains(d))

        // Seeding the other group selects only it.
        let fromC = SelectionTraversal.connected(seed: c, in: s.drawing, using: s.quadtree)
        #expect(fromC == Set([c, d]))
    }

    @Test("connected walks through a mixed line/arc chain")
    func mixedLineArcChain() {
        let s = TraversalScene()
        // Line from (0,0)→(5,0); arc from (5,0) sweeping to (5,2)…; line from arc end.
        let l1 = s.line(Vector(0, 0), Vector(5, 0))
        // Semicircle center (5,1) r=1: start angle -pi/2 at (5,0), end angle pi/2 at (5,2).
        let arc = s.arc(center: Vector(5, 1), radius: 1,
                        start: -.pi / 2, end: .pi / 2)
        let l2 = s.line(Vector(5, 2), Vector(0, 2))

        let result = SelectionTraversal.connected(seed: l1, in: s.drawing, using: s.quadtree)
        #expect(result == Set([l1, arc, l2]))
    }

    @Test("a Y-junction (network) pulls in all three branches")
    func networkBranches() {
        let s = TraversalScene()
        // Three lines all meeting at the hub (0,0).
        let a = s.line(Vector(0, 0), Vector(10, 0))
        let b = s.line(Vector(0, 0), Vector(0, 10))
        let c = s.line(Vector(0, 0), Vector(-10, 0))

        let result = SelectionTraversal.connected(seed: a, in: s.drawing, using: s.quadtree)
        #expect(result == Set([a, b, c]))
    }

    @Test("closed shape seed selects only itself")
    func closedSeedSelectsSelf() {
        let s = TraversalScene()
        let c = s.circle(center: Vector(0, 0), radius: 5)
        // A touching line should NOT be pulled in (the circle has no free ends).
        let l = s.line(Vector(5, 0), Vector(10, 0))

        let result = SelectionTraversal.connected(seed: c, in: s.drawing, using: s.quadtree)
        #expect(result == Set([c]))
        #expect(!result.contains(l))
    }

    @Test("connected skips hidden neighbors")
    func skipsHiddenNeighbors() {
        let s = TraversalScene()
        let a = s.line(Vector(0, 0), Vector(5, 0))
        // Hidden line touching `a` at (5,0) — must NOT be selected.
        let hidden = s.line(Vector(5, 0), Vector(5, 5), flags: [])
        let c = s.line(Vector(5, 0), Vector(10, 0))

        let result = SelectionTraversal.connected(seed: a, in: s.drawing, using: s.quadtree)
        #expect(result.contains(a))
        #expect(result.contains(c))
        #expect(!result.contains(hidden))
    }

    @Test("hidden / missing seed → empty set")
    func badSeed() {
        let s = TraversalScene()
        let hidden = s.line(Vector(0, 0), Vector(5, 0), flags: [])
        #expect(SelectionTraversal.connected(seed: hidden, in: s.drawing, using: s.quadtree).isEmpty)
        #expect(SelectionTraversal.connected(seed: EntityID(99999),
                                             in: s.drawing, using: s.quadtree).isEmpty)
    }

    @Test("connected honors a wider tolerance to bridge a small gap")
    func toleranceBridgesGap() {
        let s = TraversalScene()
        let a = s.line(Vector(0, 0), Vector(5, 0))
        let b = s.line(Vector(5.05, 0), Vector(10, 0))   // 0.05 gap

        // Tight: not connected.
        let tight = SelectionTraversal.connected(seed: a, in: s.drawing, using: s.quadtree)
        #expect(tight == Set([a]))

        // Loose: bridges the gap.
        let loose = SelectionTraversal.connected(seed: a, in: s.drawing, using: s.quadtree, tolerance: 0.1)
        #expect(loose == Set([a, b]))
    }
}

// MARK: - contour(...) tests

@MainActor
@Suite("CADEngine select-contour")
struct SelectContourTests {

    /// A closed loop → contour returns exactly the loop.
    @Test("closed square loop → contour returns the loop")
    func closedSquareContour() {
        let s = TraversalScene()
        let a = s.line(Vector(0, 0), Vector(10, 0))
        let b = s.line(Vector(10, 0), Vector(10, 10))
        let c = s.line(Vector(10, 10), Vector(0, 10))
        let d = s.line(Vector(0, 10), Vector(0, 0))

        let contour = SelectionTraversal.contour(seed: a, in: s.drawing, using: s.quadtree)
        #expect(contour == Set([a, b, c, d]))

        // The contour is the same regardless of which loop entity seeds it.
        let fromC = SelectionTraversal.contour(seed: c, in: s.drawing, using: s.quadtree)
        #expect(fromC == Set([a, b, c, d]))
    }

    @Test("triangle of mixed line + arc edges closes")
    func mixedClosedContour() {
        let s = TraversalScene()
        // A closed loop: line (0,0)→(4,0), arc back up, line down to start.
        let l1 = s.line(Vector(0, 0), Vector(4, 0))
        // Arc center (4,2) r=2: from (4,0) (angle -pi/2) to (4,4) (angle pi/2).
        let arc = s.arc(center: Vector(4, 2), radius: 2, start: -.pi / 2, end: .pi / 2)
        let l2 = s.line(Vector(4, 4), Vector(0, 4))
        let l3 = s.line(Vector(0, 4), Vector(0, 0))

        let contour = SelectionTraversal.contour(seed: l1, in: s.drawing, using: s.quadtree)
        #expect(contour == Set([l1, arc, l2, l3]))
    }

    /// An OPEN chain has no contour.
    @Test("open chain → no contour (nil)")
    func openChainNoContour() {
        let s = TraversalScene()
        let a = s.line(Vector(0, 0), Vector(5, 0))
        let b = s.line(Vector(5, 0), Vector(5, 5))
        let c = s.line(Vector(5, 5), Vector(10, 5))   // free end at (10,5)

        #expect(SelectionTraversal.contour(seed: a, in: s.drawing, using: s.quadtree) == nil)
        #expect(SelectionTraversal.contour(seed: b, in: s.drawing, using: s.quadtree) == nil)
        #expect(SelectionTraversal.contour(seed: c, in: s.drawing, using: s.quadtree) == nil)
    }

    /// An ambiguous branch (a junction where the path is not well-defined) → nil.
    @Test("ambiguous branch off a loop → no contour (nil)")
    func ambiguousBranchNoContour() {
        let s = TraversalScene()
        // A closed square …
        let a = s.line(Vector(0, 0), Vector(10, 0))
        _ = s.line(Vector(10, 0), Vector(10, 10))
        _ = s.line(Vector(10, 10), Vector(0, 10))
        _ = s.line(Vector(0, 10), Vector(0, 0))
        // … plus a stub line sprouting from the corner (10,0): now that junction
        // has TWO continuations, so the walk can't pick one unambiguously.
        _ = s.line(Vector(10, 0), Vector(20, 0))

        #expect(SelectionTraversal.contour(seed: a, in: s.drawing, using: s.quadtree) == nil)
    }

    @Test("a single self-closed polyline is its own contour")
    func selfClosedPolylineContour() {
        let s = TraversalScene()
        let poly = s.closedPolyline([Vector(0, 0), Vector(10, 0), Vector(10, 10), Vector(0, 10)])
        let contour = SelectionTraversal.contour(seed: poly, in: s.drawing, using: s.quadtree)
        #expect(contour == Set([poly]))
    }

    @Test("a single circle is its own contour")
    func circleContour() {
        let s = TraversalScene()
        let c = s.circle(center: Vector(0, 0), radius: 5)
        let contour = SelectionTraversal.contour(seed: c, in: s.drawing, using: s.quadtree)
        #expect(contour == Set([c]))
    }

    @Test("an open polyline (single entity) is NOT a contour")
    func openPolylineNoContour() {
        let s = TraversalScene()
        let poly = s.openPolyline([Vector(0, 0), Vector(10, 0), Vector(10, 10)])
        #expect(SelectionTraversal.contour(seed: poly, in: s.drawing, using: s.quadtree) == nil)
    }

    @Test("a lone line is NOT a contour")
    func loneLineNoContour() {
        let s = TraversalScene()
        let l = s.line(Vector(0, 0), Vector(10, 0))
        #expect(SelectionTraversal.contour(seed: l, in: s.drawing, using: s.quadtree) == nil)
    }

    @Test("hidden / missing seed → no contour (nil)")
    func badSeedContour() {
        let s = TraversalScene()
        let hidden = s.line(Vector(0, 0), Vector(5, 0), flags: [])
        #expect(SelectionTraversal.contour(seed: hidden, in: s.drawing, using: s.quadtree) == nil)
        #expect(SelectionTraversal.contour(seed: EntityID(99999),
                                           in: s.drawing, using: s.quadtree) == nil)
    }
}
