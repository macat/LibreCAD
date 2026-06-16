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
        // A draw tool emits the EntityRecord INIT defaults — layer "0" + a fully
        // `.byLayer` pen. This is the tool's *raw* output BEFORE the app applies it:
        // `CanvasModel.applyCommit` STAMPS such a default record with the active layer
        // + the model's `currentPen` (so drawn geometry lands on the active layer, not
        // always "0" — the post-stamp behavior is covered by `PenPropertiesTests`).
        // The stamp keys off exactly these defaults, so the tool MUST keep emitting them.
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

// MARK: - Mode variants (edge / corner-to-corner + star)

/// Covers the LibreCAD polygon DRAW VARIANTS layered onto `PolygonTool`:
/// (a) EDGE / corner-to-corner mode — two clicks define one EDGE of the N-gon
/// (vs the default center→corner); (b) STAR mode — a 2·N-point star via an
/// inner/outer radius ratio. Every assertion keeps the EXISTING `.centerCorner`
/// default unchanged. Pure value logic — no GUI.
@Suite("PolygonTool draw variants")
struct PolygonVariantTests {

    private func committedPolyline(_ outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Default unchanged

    @Test("mode defaults to .centerCorner (existing center→vertex flow is unchanged)")
    func modeDefaultCenterCorner() {
        #expect(PolygonTool().mode == .centerCorner)
        var tool = PolygonTool()
        // Identical to the original hexagon-commit test path.
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify a vertex (N=6)")
        let poly = committedPolyline(tool.handle(.click(Vector(10, 0)), context: .empty))
        #expect(poly?.vertices.count == 6)
        #expect(poly?.vertices.first?.point.x == 10)
        #expect(poly?.vertices.first?.point.y == 0)
    }

    // MARK: - (a) Edge / corner-to-corner mode

    @Test("edge mode has corner-to-corner status prompts")
    func edgeStatusPrompts() {
        var tool = PolygonTool()
        tool.mode = .edge
        #expect(tool.status == "Specify first corner")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify second corner (N=6)")
    }

    @Test("edge mode (N=4): the two clicks are one EDGE; the square has that side length")
    func edgeSquareSideLength() {
        var tool = PolygonTool()
        tool.sides = 4
        tool.mode = .edge
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(4, 0)), context: .empty))
        #expect(poly != nil)
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 4)
        let pts = poly!.vertices.map(\.point)
        // First two corners ARE the clicked edge; built CCW (interior to the left,
        // i.e. above the edge): (0,0),(4,0),(4,4),(0,4).
        #expect(abs(pts[0].x - 0) < 1e-9); #expect(abs(pts[0].y - 0) < 1e-9)
        #expect(abs(pts[1].x - 4) < 1e-9); #expect(abs(pts[1].y - 0) < 1e-9)
        #expect(abs(pts[2].x - 4) < 1e-9); #expect(abs(pts[2].y - 4) < 1e-9)
        #expect(abs(pts[3].x - 0) < 1e-9); #expect(abs(pts[3].y - 4) < 1e-9)
        // EVERY side has the clicked edge's length (4).
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            #expect(abs((b - a).magnitude - 4) < 1e-9)
        }
    }

    @Test("edge mode: the first edge length equals |second − first| for any N")
    func edgeSideMatchesClickDistance() {
        var tool = PolygonTool()
        tool.sides = 5
        tool.mode = .edge
        let p0 = Vector(1, 1), p1 = Vector(1 + 3, 1)   // edge length 3
        _ = tool.handle(.click(p0), context: .empty)
        let poly = committedPolyline(tool.handle(.click(p1), context: .empty))
        #expect(poly?.vertices.count == 5)
        let pts = poly!.vertices.map(\.point)
        // First two corners are exactly the clicked points.
        #expect(abs((pts[0] - p0).magnitude) < 1e-9)
        #expect(abs((pts[1] - p1).magnitude) < 1e-9)
        // All five sides equal the clicked edge length (regular pentagon).
        for i in 0..<5 {
            let a = pts[i], b = pts[(i + 1) % 5]
            #expect(abs((b - a).magnitude - 3) < 1e-9)
        }
    }

    @Test("edge mode: a zero-length edge (coincident clicks) does not commit")
    func edgeDegenerateIgnored() {
        var tool = PolygonTool()
        tool.mode = .edge
        let p = Vector(2, 2)
        _ = tool.handle(.click(p), context: .empty)
        let outcome = tool.handle(.click(p), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify second corner (N=6)")
    }

    @Test("edge mode preview is a closed N-gon while picking the second corner")
    func edgePreview() {
        var tool = PolygonTool()
        tool.sides = 6
        tool.mode = .edge
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.move(Vector(2, 0)), context: .empty)
        #expect(outcome == .preview)
        #expect(tool.preview.first?.closed == true)
        #expect(tool.preview.first?.points.count == 6)
    }

    // MARK: - (b) Star mode

    @Test("star mode (N=5): commits a 2·N-vertex closed polyline, outer/inner alternating")
    func starVertexAlternation() {
        var tool = PolygonTool()
        tool.sides = 5
        tool.mode = .star(ratio: 0.5)
        let center = Vector(0, 0)
        let vertex = Vector(10, 0)     // outer radius 10
        _ = tool.handle(.click(center), context: .empty)
        let poly = committedPolyline(tool.handle(.click(vertex), context: .empty))
        #expect(poly != nil)
        #expect(poly?.closed == true)
        // 5 outer tips + 5 inner valleys = 10 vertices.
        #expect(poly?.vertices.count == 10)
        let pts = poly!.vertices.map(\.point)
        // Even indices are OUTER (radius 10), odd indices are INNER (radius 5).
        for i in 0..<10 {
            let r = (pts[i] - center).magnitude
            if i.isMultiple(of: 2) {
                #expect(abs(r - 10) < 1e-9)      // outer
            } else {
                #expect(abs(r - 5) < 1e-9)       // inner = outer × 0.5
            }
        }
        // First outer tip is exactly the clicked vertex.
        #expect(abs(pts[0].x - 10) < 1e-9)
        #expect(abs(pts[0].y - 0) < 1e-9)
        // First inner valley sits half a step (36°) past the first tip, at radius 5.
        let step = 2 * Double.pi / 5
        let expectedInner = Vector.polar(radius: 5, angle: step * 0.5)
        #expect(abs(pts[1].x - expectedInner.x) < 1e-9)
        #expect(abs(pts[1].y - expectedInner.y) < 1e-9)
    }

    @Test("star mode honors the inner/outer ratio")
    func starRatioControlsInnerRadius() {
        var tool = PolygonTool()
        tool.sides = 6
        tool.mode = .star(ratio: 0.3)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(20, 0)), context: .empty))
        #expect(poly?.vertices.count == 12)
        let pts = poly!.vertices.map(\.point)
        for i in 0..<12 {
            let r = (pts[i] - Vector(0, 0)).magnitude
            #expect(abs(r - (i.isMultiple(of: 2) ? 20 : 6)) < 1e-9)  // 20 × 0.3 = 6
        }
    }

    @Test("star mode: a ratio outside (0,1) does not commit")
    func starInvalidRatioIgnored() {
        for bad in [0.0, 1.0, -0.5, 1.5] {
            var tool = PolygonTool()
            tool.mode = .star(ratio: bad)
            _ = tool.handle(.click(Vector(0, 0)), context: .empty)
            let outcome = tool.handle(.click(Vector(10, 0)), context: .empty)
            #expect(committedPolyline(outcome) == nil)
        }
    }

    @Test("star mode: a zero-radius vertex click does not commit")
    func starZeroRadiusIgnored() {
        var tool = PolygonTool()
        tool.mode = .star(ratio: 0.5)
        let c = Vector(3, 3)
        _ = tool.handle(.click(c), context: .empty)
        let outcome = tool.handle(.click(c), context: .empty)
        #expect(committedPolyline(outcome) == nil)
    }

    @Test("star mode uses the center→vertex prompts (it is a center-based variant)")
    func starUsesCenterPrompts() {
        var tool = PolygonTool()
        tool.mode = .star(ratio: 0.5)
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify a vertex (N=6)")
    }

    // MARK: - Static geometry helpers (direct unit coverage)

    @Test("edgeCorners builds a unit square from a unit edge")
    func edgeCornersHelper() {
        let pts = PolygonTool.edgeCorners(Vector(0, 0), Vector(1, 0), sides: 4)
        #expect(pts?.count == 4)
        let expected = [Vector(0, 0), Vector(1, 0), Vector(1, 1), Vector(0, 1)]
        for i in 0..<4 {
            #expect(abs(pts![i].x - expected[i].x) < 1e-9)
            #expect(abs(pts![i].y - expected[i].y) < 1e-9)
        }
    }

    @Test("starPoints alternates outer (clicked) and inner (×ratio) radii")
    func starPointsHelper() {
        let pts = PolygonTool.starPoints(center: Vector(0, 0), vertex: Vector(8, 0),
                                         sides: 4, fit: .inscribed, ratio: 0.25)
        #expect(pts?.count == 8)
        for (i, p) in pts!.enumerated() {
            #expect(abs(p.magnitude - (i.isMultiple(of: 2) ? 8 : 2)) < 1e-9)  // 8 × 0.25 = 2
        }
    }
}
