//
//  ToolOptionsU2Tests.swift
//  CADEngineTests
//
//  Covers the NEW draw-tool options surfaced by the contextual Tool Options bar
//  (UX-plan U2): Polygon sides + inscribed/circumscribed, Rectangle exact size,
//  Circle radius/diameter + exact size, Arc 3-point construction, Point style, and
//  Text default height. Each option is exercised PURELY (no GUI): feed `ToolInput`
//  events to the tool value and assert the committed geometry honors the option.
//
//  Also models the `CanvasModel.applyToolConfig` "config → live tool" plumbing the
//  options bar relies on. `CanvasModel` lives in the un-importable executable
//  target, so its downcast-and-set logic is mirrored here over the public tool
//  `var`s — the same operation the model performs — proving a Polygon with `sides=6`
//  commits a 6-vertex polygon and a Rectangle with width/height commits that exact
//  size once the config is pushed onto a freshly-minted tool.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("U2 draw-tool options")
struct ToolOptionsU2Tests {

    // MARK: - Commit extractors

    private func committedPolyline(_ outcome: ToolOutcome) -> PolylineData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .polyline(let d) = record.kind else { return nil }
        return d
    }

    private func committedCircle(_ outcome: ToolOutcome) -> CircleData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .circle(let d) = record.kind else { return nil }
        return d
    }

    private func committedArc(_ outcome: ToolOutcome) -> ArcData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .arc(let d) = record.kind else { return nil }
        return d
    }

    private func committedPoint(_ outcome: ToolOutcome) -> PointData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .point(let d) = record.kind else { return nil }
        return d
    }

    private func committedText(_ outcome: ToolOutcome) -> TextData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .text(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Polygon: inscribed vs circumscribed

    @Test("polygon fit defaults to inscribed")
    func polygonFitDefault() {
        #expect(PolygonTool().fit == .inscribed)
    }

    @Test("inscribed square: corners lie ON the reference circle through the vertex")
    func polygonInscribed() {
        var tool = PolygonTool()
        tool.sides = 4
        tool.fit = .inscribed
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(5, 0)), context: .empty))
        let pts = poly!.vertices.map(\.point)
        // Inscribed ⇒ circumradius == reference radius (5); first vertex at the click.
        #expect(abs(pts[0].x - 5) < 1e-9)
        #expect(abs(pts[0].y - 0) < 1e-9)
        for p in pts { #expect(abs((p - Vector(0, 0)).magnitude - 5) < 1e-9) }
    }

    @Test("circumscribed square: the clicked point is an EDGE MIDPOINT; corners sit outside")
    func polygonCircumscribed() {
        var tool = PolygonTool()
        tool.sides = 4
        tool.fit = .circumscribed
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(5, 0)), context: .empty))
        let pts = poly!.vertices.map(\.point)
        #expect(pts.count == 4)
        // Circumscribed: the reference circle (r=5) is inscribed → circumradius is
        // 5 / cos(π/4) = 5 * √2. Every corner lies at that larger radius.
        let expectedR = 5 / cos(Double.pi / 4)
        for p in pts { #expect(abs((p - Vector(0, 0)).magnitude - expectedR) < 1e-9) }
        // The midpoint of the FIRST edge (corner0 → corner1) lands on the click (5,0):
        // it is the point where the reference circle touches that edge.
        let mid = Vector((pts[0].x + pts[1].x) / 2, (pts[0].y + pts[1].y) / 2)
        #expect(abs(mid.x - 5) < 1e-9)
        #expect(abs(mid.y - 0) < 1e-9)
    }

    // MARK: - Rectangle: exact width × height (single-click commit)

    @Test("rectangle width/height unset by default (two-corner drag)")
    func rectFixedSizeDefaultNil() {
        let tool = RectangleTool()
        #expect(tool.fixedWidth == nil)
        #expect(tool.fixedHeight == nil)
        // With no fixed size, the first click only fixes a corner (no commit).
        var t = tool
        #expect(t.handle(.click(Vector(1, 1)), context: .empty) == .none)
    }

    @Test("rectangle with width=100 height=50 commits that EXACT size on a single click")
    func rectExactSizeSingleClick() {
        var tool = RectangleTool()
        tool.fixedWidth = 100
        tool.fixedHeight = 50
        // ONE click drops a 100×50 box anchored at the click, extending +x/+y.
        let outcome = tool.handle(.click(Vector(10, 20)), context: .empty)
        let poly = committedPolyline(outcome)
        #expect(poly != nil)
        #expect(poly?.closed == true)
        #expect(poly?.vertices.count == 4)
        let pts = poly!.vertices.map(\.point)
        // Corner order matches RectangleTool.corners(a, b): (x0,y0),(x1,y0),(x1,y1),(x0,y1).
        #expect(pts[0] == Vector(10, 20))
        #expect(pts[1] == Vector(110, 20))
        #expect(pts[2] == Vector(110, 70))
        #expect(pts[3] == Vector(10, 70))
        // Width and height are exactly the configured size.
        let width = abs(pts[1].x - pts[0].x)
        let height = abs(pts[2].y - pts[1].y)
        #expect(abs(width - 100) < 1e-9)
        #expect(abs(height - 50) < 1e-9)
        // Re-armed for the next rectangle.
        #expect(tool.status.hasPrefix("Specify corner"))
    }

    @Test("rectangle with only width set falls back to the two-corner drag")
    func rectPartialSizeFallsBack() {
        var tool = RectangleTool()
        tool.fixedWidth = 100   // height left nil → not an exact size
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        #expect(tool.status == "Specify opposite corner")
    }

    // MARK: - Circle: radius/diameter mode + exact size

    @Test("circle size mode defaults to radius; fixed size unset")
    func circleSizeDefaults() {
        let tool = CircleTool()
        #expect(tool.sizeMode == .radius)
        #expect(tool.fixedSize == nil)
    }

    @Test("circle with fixed radius=8 commits that radius on a single click")
    func circleFixedRadiusSingleClick() {
        var tool = CircleTool()
        tool.fixedSize = 8       // radius mode (default)
        let circle = committedCircle(tool.handle(.click(Vector(3, 4)), context: .empty))
        #expect(circle?.center == Vector(3, 4))
        #expect(abs((circle?.radius ?? 0) - 8) < 1e-9)
        #expect(tool.status == "Specify center point")  // re-armed
    }

    @Test("circle in DIAMETER mode halves the fixed size to the stored radius")
    func circleFixedDiameterSingleClick() {
        var tool = CircleTool()
        tool.sizeMode = .diameter
        tool.fixedSize = 20      // diameter 20 → radius 10
        let circle = committedCircle(tool.handle(.click(Vector(0, 0)), context: .empty))
        #expect(abs((circle?.radius ?? 0) - 10) < 1e-9)
    }

    @Test("circle with no fixed size keeps the two-click center+radius flow")
    func circleNoFixedSizeTwoClicks() {
        var tool = CircleTool()
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
        let circle = committedCircle(tool.handle(.click(Vector(6, 0)), context: .empty))
        #expect(abs((circle?.radius ?? 0) - 6) < 1e-9)
    }

    // MARK: - Arc: 3-point construction mode

    @Test("arc mode defaults to center→start→end")
    func arcModeDefault() {
        #expect(ArcTool().mode == .centerStartEnd)
        #expect(ArcTool().status == "Specify center point")
    }

    @Test("three-point arc has start-on-arc prompts and commits the circle through 3 points")
    func arcThreePoint() {
        var tool = ArcTool(mode: .threePoint)
        #expect(tool.status == "Specify start point")
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)     // start
        #expect(tool.status == "Specify point on arc")
        _ = tool.handle(.click(Vector(0, 1)), context: .empty)     // mid
        #expect(tool.status == "Specify end point")
        // start (1,0), mid (0,1), end (-1,0) → unit circle centered at origin,
        // sweeping CCW through the top (the mid point).
        let arc = committedArc(tool.handle(.click(Vector(-1, 0)), context: .empty))
        #expect(arc != nil)
        #expect(abs(arc!.center.x - 0) < 1e-9)
        #expect(abs(arc!.center.y - 0) < 1e-9)
        #expect(abs(arc!.radius - 1) < 1e-9)
        // start angle 0, end angle π, CCW (reversed == false) passes through (0,1).
        #expect(abs(arc!.startAngle - 0) < 1e-9)
        #expect(abs(abs(arc!.endAngle) - Double.pi) < 1e-9)
        #expect(arc!.reversed == false)
    }

    @Test("three-point arc through collinear points does not commit")
    func arcThreePointCollinear() {
        var tool = ArcTool(mode: .threePoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        // Third collinear point → no finite circle → ignored, still awaiting end.
        let outcome = tool.handle(.click(Vector(2, 0)), context: .empty)
        #expect(committedArc(outcome) == nil)
        #expect(tool.status == "Specify end point")
    }

    @Test("arcThrough orients the sweep through the mid point (CW case → reversed)")
    func arcThroughOrientation() {
        // start (1,0), mid (0,-1), end (-1,0): the arc through the BOTTOM is the CW
        // sweep from angle 0 to π, so reversed must be true.
        let arc = ArcTool.arcThrough(Vector(1, 0), Vector(0, -1), Vector(-1, 0))
        #expect(arc != nil)
        #expect(arc!.reversed == true)
        #expect(abs(arc!.radius - 1) < 1e-9)
    }

    // MARK: - Point: marker style option

    @Test("point style defaults to dot; a click still commits a point at the location")
    func pointStyle() {
        var tool = PointTool()
        #expect(tool.style == .dot)
        tool.style = .cross
        #expect(tool.style == .cross)
        let pt = committedPoint(tool.handle(.click(Vector(7, 8)), context: .empty))
        #expect(pt?.position == Vector(7, 8))
    }

    @Test("PointStyle rawValues match the DXF $PDMODE codes")
    func pointStyleRawValues() {
        #expect(PointStyle.dot.rawValue == 0)
        #expect(PointStyle.plus.rawValue == 2)
        #expect(PointStyle.cross.rawValue == 3)
        #expect(PointStyle.square.rawValue == 65)
    }

    // MARK: - Text: default cap height option

    @Test("text height option flows into the committed entity")
    func textHeight() {
        var tool = TextTool()
        tool.height = 12.5
        tool.text = "Hi"
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let text = committedText(tool.handle(.commit, context: .empty))
        #expect(abs((text?.height ?? 0) - 12.5) < 1e-9)
    }

    // MARK: - CanvasModel.applyToolConfig plumbing (mirrored — model not importable)
    //
    // `CanvasModel.applyToolConfig` downcasts the freshly-minted tool to its concrete
    // type and overwrites the public option `var`s from the model's config fields.
    // The model lives in the executable target (can't be imported here), so the SAME
    // operation is mirrored over the public tool surface to prove the plumbing
    // produces the expected committed geometry.

    /// Mirror of the relevant `applyToolConfig` arms: push config values onto a tool.
    private func applyPolygonConfig(_ tool: inout PolygonTool, sides: Int, fit: PolygonFit) {
        tool.sides = sides
        tool.fit = fit
    }
    private func applyRectConfig(_ tool: inout RectangleTool, width: Double, height: Double) {
        tool.fixedWidth = width > 0 ? width : nil
        tool.fixedHeight = height > 0 ? height : nil
    }

    @Test("plumbing: a Polygon configured with sides=6 commits a 6-vertex polygon")
    func plumbingPolygonSidesSix() {
        // ToolKind.makeTool() mints a default PolygonTool; the model then applies the
        // config. Here: mint → apply(sides:6) → draw.
        guard var tool = ToolKind.polygon.makeTool() as? PolygonTool else {
            Issue.record("polygon makeTool did not produce a PolygonTool"); return
        }
        applyPolygonConfig(&tool, sides: 6, fit: .inscribed)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 0)), context: .empty))
        #expect(poly?.vertices.count == 6)
        #expect(poly?.closed == true)
    }

    @Test("plumbing: a Polygon configured with sides=5 commits a pentagon")
    func plumbingPolygonSidesFive() {
        guard var tool = ToolKind.polygon.makeTool() as? PolygonTool else {
            Issue.record("polygon makeTool did not produce a PolygonTool"); return
        }
        applyPolygonConfig(&tool, sides: 5, fit: .inscribed)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(4, 0)), context: .empty))
        #expect(poly?.vertices.count == 5)
    }

    @Test("plumbing: a Rectangle configured with width=30 height=20 commits that exact size")
    func plumbingRectExactSize() {
        guard var tool = ToolKind.rectangle.makeTool() as? RectangleTool else {
            Issue.record("rectangle makeTool did not produce a RectangleTool"); return
        }
        applyRectConfig(&tool, width: 30, height: 20)
        let poly = committedPolyline(tool.handle(.click(Vector(0, 0)), context: .empty))
        let pts = poly!.vertices.map(\.point)
        #expect(abs(abs(pts[1].x - pts[0].x) - 30) < 1e-9)
        #expect(abs(abs(pts[2].y - pts[1].y) - 20) < 1e-9)
    }

    @Test("plumbing: width=0 leaves the Rectangle in two-corner mode")
    func plumbingRectZeroIsUnset() {
        guard var tool = ToolKind.rectangle.makeTool() as? RectangleTool else {
            Issue.record("rectangle makeTool did not produce a RectangleTool"); return
        }
        applyRectConfig(&tool, width: 0, height: 0)
        #expect(tool.fixedWidth == nil)
        #expect(tool.fixedHeight == nil)
        // First click only fixes a corner (no exact-size commit).
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
    }
}
