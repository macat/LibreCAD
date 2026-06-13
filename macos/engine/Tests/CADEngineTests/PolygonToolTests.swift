//
//  PolygonToolTests.swift
//  CADEngineTests
//
//  Drives the center+vertex regular-polygon `PolygonTool` PURELY (no GUI): feeds
//  `ToolInput` events + a read-only `ToolContext` and asserts the committed
//  geometry (a closed `.polyline` of N evenly-spaced corners inscribed in a
//  circle, first vertex at the clicked point), the live polygon preview, the
//  configurable `sides` count (hexagon default, square case), the re-arm-after-
//  commit behavior, cancel/backspace resets, the zero-radius guard, and the
//  status prompt transitions.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("PolygonTool interactive draw")
struct PolygonToolTests {

    // MARK: - Helpers

    /// Pulls the single PolylineData out of a `.commit` outcome (returns nil if the
    /// outcome isn't a one-edit `.add` polyline commit).
    private func committedPolyline(_ outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status / title

    @Test("status starts at 'Specify center point' and advances after the first click")
    func statusTransitions() {
        var tool = PolygonTool()
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify a vertex (N=6)")
    }

    @Test("title is Polygon")
    func title() {
        #expect(PolygonTool().title == "Polygon")
    }

    @Test("sides defaults to 6")
    func sidesDefault() {
        #expect(PolygonTool().sides == 6)
    }

    // MARK: - Hexagon commit (center + vertex)

    @Test("center (0,0), vertex (10,0), sides=6 commits a closed 6-gon, first vertex at (10,0)")
    func hexagonCommit() {
        var tool = PolygonTool()
        let center = Vector(0, 0)
        let vertex = Vector(10, 0)

        let first = tool.handle(.click(center), context: .empty)
        #expect(first == .none)   // first click only fixes the center

        let outcome = tool.handle(.click(vertex), context: .empty)
        let poly = committedPolyline(outcome)
        #expect(poly != nil)
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 6)

        guard let pts = poly?.vertices.map(\.point) else {
            Issue.record("no committed polyline")
            return
        }

        // First vertex is exactly the clicked vertex.
        #expect(abs(pts[0].x - 10) < 1e-9)
        #expect(abs(pts[0].y - 0) < 1e-9)

        // All corners lie radius 10 from the center.
        for p in pts {
            #expect(abs((p - center).magnitude - 10) < 1e-9)
        }

        // All bulges are zero (straight segments).
        for v in poly!.vertices {
            #expect(v.bulge == 0)
        }

        // Corners are spaced exactly 60° (2π/6) apart, CCW.
        let step = 2 * Double.pi / 6
        for i in 0..<6 {
            let expected = Vector.polar(radius: 10, angle: step * Double(i))
            #expect(abs(pts[i].x - expected.x) < 1e-9)
            #expect(abs(pts[i].y - expected.y) < 1e-9)
        }
    }

    @Test("first vertex follows angle(center → cursor), not always +X")
    func firstVertexAtCursorAngle() {
        var tool = PolygonTool()
        let center = Vector(0, 0)
        let vertex = Vector(0, 7)   // straight up: angle = π/2, radius 7

        _ = tool.handle(.click(center), context: .empty)
        let poly = committedPolyline(tool.handle(.click(vertex), context: .empty))
        let pts = poly!.vertices.map(\.point)

        #expect(pts.count == 6)
        // First corner is exactly the clicked vertex (0,7).
        #expect(abs(pts[0].x - 0) < 1e-9)
        #expect(abs(pts[0].y - 7) < 1e-9)
        // Every corner is radius 7 from the center.
        for p in pts {
            #expect(abs((p - center).magnitude - 7) < 1e-9)
        }
    }

    // MARK: - Square inscribed (sides = 4)

    @Test("sides=4 commits a closed square inscribed in the circle through the vertex")
    func squareInscribed() {
        var tool = PolygonTool()
        tool.sides = 4
        let center = Vector(0, 0)
        let vertex = Vector(5, 0)   // radius 5

        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(center), context: .empty)
        #expect(tool.status == "Specify a vertex (N=4)")

        let poly = committedPolyline(tool.handle(.click(vertex), context: .empty))
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 4)

        let pts = poly!.vertices.map(\.point)
        // Inscribed square corners: (5,0), (0,5), (-5,0), (0,-5).
        let expected = [Vector(5, 0), Vector(0, 5), Vector(-5, 0), Vector(0, -5)]
        for i in 0..<4 {
            #expect(abs(pts[i].x - expected[i].x) < 1e-9)
            #expect(abs(pts[i].y - expected[i].y) < 1e-9)
        }
        // All radius 5, spaced 90°.
        for p in pts {
            #expect(abs((p - center).magnitude - 5) < 1e-9)
        }
    }

    @Test("sides is clamped to a minimum of 3")
    func sidesClampedToMin() {
        var tool = PolygonTool()
        tool.sides = 2          // below the minimum
        #expect(tool.sides == 3)
        tool.sides = 0
        #expect(tool.sides == 3)
        tool.sides = -10
        #expect(tool.sides == 3)
        tool.sides = 8          // valid values pass through
        #expect(tool.sides == 8)
    }

    // MARK: - Preview matches the committed geometry

    @Test("preview is a closed N-gon matching the committed corners")
    func previewMatchesCommit() {
        var tool = PolygonTool()
        let center = Vector(2, 3)
        _ = tool.handle(.click(center), context: .empty)

        let cursor = Vector(2 + 6, 3)   // radius 6 along +X
        let outcome = tool.handle(.move(cursor), context: .empty)
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let preview = tool.preview[0]
        #expect(preview.closed == true)
        #expect(preview.points.count == 6)
        // First preview vertex is exactly the cursor.
        #expect(abs(preview.points[0].x - 8) < 1e-9)
        #expect(abs(preview.points[0].y - 3) < 1e-9)
        // Every preview vertex lies radius 6 from the center.
        for p in preview.points {
            #expect(abs((p - center).magnitude - 6) < 1e-9)
        }
    }

    @Test("preview is empty before the center is set")
    func previewEmptyInitially() {
        var tool = PolygonTool()
        #expect(tool.preview.isEmpty)
        let outcome = tool.handle(.move(Vector(3, 3)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("preview is empty while the radius is still zero (cursor on center)")
    func previewEmptyAtZeroRadius() {
        var tool = PolygonTool()
        let center = Vector(5, 5)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.move(center), context: .empty)   // cursor == center
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Re-arm after commit

    @Test("after committing a polygon the tool re-arms to specify a new center")
    func reArmsAfterCommit() {
        var tool = PolygonTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(5, 0)), context: .empty)
        #expect(committedPolyline(outcome) != nil)
        // Back to the initial state, preview cleared, ready for the next polygon.
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)

        // A second polygon can be drawn immediately.
        _ = tool.handle(.click(Vector(10, 10)), context: .empty)
        let poly2 = committedPolyline(tool.handle(.click(Vector(13, 10)), context: .empty))
        #expect(poly2?.vertices.count == 6)
        #expect(poly2?.vertices.first?.point.x == 13)
        #expect(poly2?.vertices.first?.point.y == 10)
    }

    @Test("committed record carries the placeholder id (app re-mints on add)")
    func commitUsesPlaceholderID() {
        var tool = PolygonTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(4, 0)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
        // Common attrs match the RectangleTool/EntityRecord defaults (consistency).
        #expect(record.layer == .zero)
        #expect(record.pen == .byLayer)
        #expect(record.flags == .default)
    }

    // MARK: - Degenerate (zero-radius) guard

    @Test("a degenerate (zero-radius) vertex click does not commit")
    func zeroRadiusClickIgnored() {
        var tool = PolygonTool()
        let center = Vector(3, 3)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.click(center), context: .empty)   // vertex == center
        #expect(outcome == .none)
        // Still waiting for a (nonzero) vertex — center stays fixed.
        #expect(tool.status == "Specify a vertex (N=6)")
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = PolygonTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(5, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("commit while idle ends the run and finishes")
    func commitFinishes() {
        var tool = PolygonTool()
        let outcome = tool.handle(.commit, context: .empty)   // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("backspace after the center is set returns to the initial state")
    func backspaceRewinds() {
        var tool = PolygonTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)
        #expect(tool.status == "Specify a vertex (N=6)")
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .preview)
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = PolygonTool()
        let outcome = tool.handle(.backspace, context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify center point")
    }

    // MARK: - Context is ignored (draw tool)

    @Test("draw tool ignores a populated context (behavior unchanged with selection)")
    func drawToolIgnoresContext() {
        let selected = EntityRecord(id: EntityID(42), kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 0))))
        let ctx = ToolContext(
            selected: [selected],
            entity: { id in id == EntityID(42) ? selected : nil },
            gridSpacing: 0.5
        )
        var tool = PolygonTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        let poly = committedPolyline(tool.handle(.click(Vector(1 + 6, 2)), context: ctx))
        #expect(poly?.vertices.count == 6)
        #expect(poly?.vertices.first?.point.x == 7)
        #expect(poly?.vertices.first?.point.y == 2)
    }
}
