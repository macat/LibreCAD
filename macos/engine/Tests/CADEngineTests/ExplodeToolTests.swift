//
//  ExplodeToolTests.swift
//  CADEngineTests
//
//  Drives the EXPLODE modify tool PURELY (no GUI): feeds `ToolInput` events + a
//  read-only `ToolContext` carrying a known polyline selection and asserts the
//  explode contract — a polyline is REMOVED and its edges are ADDED as free
//  `.line` / `.arc` entities. Covers: a straight open polyline → N−1 lines, a
//  closed polyline → N lines (incl. the implicit closing edge), and a 3-vertex
//  polyline with one bulge → 2 segments (one line + one arc) whose geometry
//  matches the polyline's own bulge tessellation.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ExplodeTool modify (polyline → line/arc segments)")
struct ExplodeToolTests {

    // MARK: - Helpers

    private func context(_ records: [EntityRecord]) -> ToolContext {
        ToolContext(
            selected: records,
            entity: { id in records.first { $0.id == id } },
            gridSpacing: nil
        )
    }

    private func approxEqual(_ a: Vector, _ b: Vector, eps: Double = 1e-9) -> Bool {
        a.distance(to: b) < eps
    }

    /// Splits a `.commit` into its single `.remove` id and the ordered `.add`
    /// segment kinds (fails — returns nil — if the shape isn't remove-then-adds).
    private func removeThenAdds(_ outcome: ToolOutcome) -> (removed: EntityID, added: [EntityRecord])? {
        guard case .commit(let edits) = outcome, let first = edits.first,
              case .remove(let id) = first else { return nil }
        var added: [EntityRecord] = []
        for edit in edits.dropFirst() {
            guard case .add(let r) = edit else { return nil }
            added.append(r)
        }
        return (id, added)
    }

    // MARK: - Basics

    @Test("title is Explode")
    func title() {
        #expect(ExplodeTool().title == "Explode")
    }

    @Test("status nudges to select a polyline when nothing explodable is selected")
    func statusEmpty() {
        #expect(ExplodeTool().status == "Select a polyline to explode first")
    }

    @Test("a fire with an empty / non-polyline selection is a no-op")
    func emptyNoop() {
        var tool = ExplodeTool()
        #expect(tool.handle(.commit, context: .empty) == .none)

        // A selected LINE has nothing to explode → still a no-op.
        let line = EntityRecord(
            id: EntityID(1), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        )
        var tool2 = ExplodeTool()
        #expect(tool2.handle(.commit, context: context([line])) == .none)
    }

    // MARK: - Open straight polyline → N−1 lines

    @Test("an open 3-vertex straight polyline explodes into 2 lines; polyline is removed")
    func openStraightPolyline() {
        let pl = EntityRecord(
            id: EntityID(10),
            layer: LayerID("walls"),
            pen: Pen(lineColor: .explicit(RGBAColor(1, 0, 0, 1))),
            flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(4, 0)),
                PolylineVertex(point: Vector(4, 3)),
            ], closed: false))
        )
        var tool = ExplodeTool()
        guard let (removed, added) = removeThenAdds(tool.handle(.commit, context: context([pl]))) else {
            Issue.record("expected remove-then-adds"); return
        }
        #expect(removed == pl.id)
        #expect(added.count == 2)   // N − 1 edges, all lines

        guard case .line(let s0) = added[0].kind, case .line(let s1) = added[1].kind else {
            Issue.record("expected two line segments"); return
        }
        #expect(approxEqual(s0.start, Vector(0, 0)))
        #expect(approxEqual(s0.end, Vector(4, 0)))
        #expect(approxEqual(s1.start, Vector(4, 0)))
        #expect(approxEqual(s1.end, Vector(4, 3)))

        // Segments inherit the polyline's layer/pen/flags and use the placeholder id.
        for r in added {
            #expect(r.id == .placeholder)
            #expect(r.layer == pl.layer)
            #expect(r.pen == pl.pen)
            #expect(r.flags == pl.flags)
        }
    }

    // MARK: - Closed polyline → N lines (incl. closing edge)

    @Test("a closed 3-vertex polyline explodes into 3 lines (incl. the closing edge)")
    func closedPolyline() {
        let pl = EntityRecord(
            id: EntityID(11), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(4, 0)),
                PolylineVertex(point: Vector(2, 3)),
            ], closed: true))
        )
        var tool = ExplodeTool()
        guard let (_, added) = removeThenAdds(tool.handle(.commit, context: context([pl]))) else {
            Issue.record("expected remove-then-adds"); return
        }
        #expect(added.count == 3)   // 2 real edges + 1 closing edge
        // The closing edge is the last segment: (2,3) → (0,0).
        guard case .line(let closing) = added[2].kind else {
            Issue.record("expected the closing edge to be a line"); return
        }
        #expect(approxEqual(closing.start, Vector(2, 3)))
        #expect(approxEqual(closing.end, Vector(0, 0)))
    }

    // MARK: - 3-vertex polyline with one bulge → 1 line + 1 arc, matching geometry

    @Test("a 3-vertex polyline with one bulged segment explodes into 1 line + 1 arc")
    func bulgedPolyline() {
        // Edge 0: straight (0,0)→(4,0). Edge 1: bulged (4,0)→(4,4), bulge 1.0
        // (a quarter→half? bulge 1 == quarter circle's 90°→ included = 4·atan(1) =
        // π, a SEMICIRCLE). The first vertex carries the bulge for the segment that
        // follows it.
        let bulge = 1.0
        let pl = EntityRecord(
            id: EntityID(12), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0), bulge: 0),
                PolylineVertex(point: Vector(4, 0), bulge: bulge),
                PolylineVertex(point: Vector(4, 4), bulge: 0),
            ], closed: false))
        )
        var tool = ExplodeTool()
        guard let (_, added) = removeThenAdds(tool.handle(.commit, context: context([pl]))) else {
            Issue.record("expected remove-then-adds"); return
        }
        #expect(added.count == 2)

        // First segment is the straight line.
        guard case .line(let line) = added[0].kind else {
            Issue.record("expected the first segment to be a line"); return
        }
        #expect(approxEqual(line.start, Vector(0, 0)))
        #expect(approxEqual(line.end, Vector(4, 0)))

        // Second segment is an arc.
        guard case .arc(let arc) = added[1].kind else {
            Issue.record("expected the second segment to be an arc"); return
        }
        // The arc must pass through both edge endpoints.
        let arcStart = arc.center + Vector.polar(radius: arc.radius, angle: arc.startAngle)
        let arcEnd = arc.center + Vector.polar(radius: arc.radius, angle: arc.endAngle)
        #expect(approxEqual(arcStart, Vector(4, 0)))
        #expect(approxEqual(arcEnd, Vector(4, 4)))
    }

    // MARK: - The exploded arc reproduces the polyline's own bulge tessellation

    @Test("the exploded arc's resolved points match the polyline edge's bulge tessellation")
    func explodedArcMatchesBulgeTessellation() {
        let bulge = 0.5
        let a = Vector(1, 1)
        let b = Vector(5, 2)
        // A single-edge polyline (a→b with the bulge) so we can compare exactly.
        let pl = PolylineData(vertices: [
            PolylineVertex(point: a, bulge: bulge),
            PolylineVertex(point: b, bulge: 0),
        ], closed: false)

        // The polyline's OWN tessellation of that bulged edge.
        let plPoints = EntityKind.expandPolyline(pl, ctx: .default)

        // The exploded arc, resolved with the same tolerance.
        guard let arcData = ExplodeTool.arc(from: a, to: b, bulge: bulge) else {
            Issue.record("expected a valid arc"); return
        }
        let arcGeo = EntityKind.arc(arcData).resolve(pen: .toolPreview, ctx: .default)
        guard let arcPoly = arcGeo.polylines.first else {
            Issue.record("expected one resolved arc polyline"); return
        }
        let arcPoints = arcPoly.points

        // Same number of samples and pointwise-equal (same center/radius/sweep math).
        #expect(arcPoints.count == plPoints.count)
        for (p, q) in zip(arcPoints, plPoints) {
            #expect(approxEqual(p, q, eps: 1e-7))
        }
    }

    // MARK: - Multiple polylines in one selection

    @Test("multiple selected polylines each emit their own remove + segments")
    func multiplePolylines() {
        let p1 = EntityRecord(
            id: EntityID(20), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(1, 0)),
            ], closed: false))
        )
        let p2 = EntityRecord(
            id: EntityID(21), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 5)),
                PolylineVertex(point: Vector(2, 5)),
                PolylineVertex(point: Vector(2, 7)),
            ], closed: false))
        )
        var tool = ExplodeTool()
        guard case .commit(let edits) = tool.handle(.commit, context: context([p1, p2])) else {
            Issue.record("expected a commit"); return
        }
        // p1: remove + 1 line = 2 edits. p2: remove + 2 lines = 3 edits. Total 5.
        #expect(edits.count == 5)
        var removes = 0, adds = 0
        for edit in edits {
            switch edit {
            case .remove: removes += 1
            case .add: adds += 1
            case .replace: Issue.record("explode must not .replace")
            }
        }
        #expect(removes == 2)
        #expect(adds == 3)
    }

    // MARK: - Cancel

    @Test("cancel discards the captured selection and finishes")
    func cancelResets() {
        let pl = EntityRecord(
            id: EntityID(30), layer: .zero, pen: .byLayer, flags: [.visible, .selected],
            kind: .polyline(PolylineData(vertices: [
                PolylineVertex(point: Vector(0, 0)),
                PolylineVertex(point: Vector(1, 1)),
            ], closed: false))
        )
        var tool = ExplodeTool()
        let ctx = context([pl])
        _ = tool.handle(.move(Vector(0, 0)), context: ctx)   // captures selection
        #expect(tool.status == "Press Return to explode the selected polyline(s)")
        #expect(tool.handle(.cancel, context: ctx) == .finished)
        #expect(tool.status == "Select a polyline to explode first")
    }
}
