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

    private func committedEllipse(_ outcome: ToolOutcome) -> EllipseData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .ellipse(let d) = record.kind else { return nil }
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

    // MARK: - Wire-wave-3 configurable-tool plumbing (mirrored — model not importable)
    //
    // The SAME downcast-and-set the model's `applyToolConfig` performs for the wave-3
    // tools, mirrored over the public tool surface so the option → live-tool path is
    // proven without importing the executable-target `CanvasModel`.

    @Test("plumbing: Align scaleToFit toggles between scale-to-fit and rotate-only")
    func plumbingAlignScaleToFit() {
        guard var on = ToolKind.align.makeTool() as? AlignTool,
              var off = ToolKind.align.makeTool() as? AlignTool else {
            Issue.record("align makeTool did not produce an AlignTool"); return
        }
        on.scaleToFit = true
        off.scaleToFit = false
        #expect(on.scaleToFit == true)
        #expect(off.scaleToFit == false)
        // The align map honors the flag: a 1→2 source mapped onto a 1→4 destination
        // scales ×2 under scale-to-fit, ×1 (rotate-only) when off.
        let withFit = AlignTool.alignTransform(
            src1: Vector(0, 0), dst1: Vector(0, 0),
            src2: Vector(1, 0), dst2: Vector(4, 0), scaleToFit: true)
        let noFit = AlignTool.alignTransform(
            src1: Vector(0, 0), dst1: Vector(0, 0),
            src2: Vector(1, 0), dst2: Vector(4, 0), scaleToFit: false)
        #expect(abs((withFit?.a ?? 0) - 4) < 1e-9)   // ×4 scale on +X
        #expect(abs((noFit?.a ?? 0) - 1) < 1e-9)     // unit scale (rotate-only)
    }

    @Test("plumbing: an ArrayPath configured with count=3 distributes 3 copies")
    func plumbingArrayPathCount() {
        guard var tool = ToolKind.arrayPath.makeTool() as? ArrayPathTool else {
            Issue.record("arrayPath makeTool did not produce an ArrayPathTool"); return
        }
        // Mirror of the applyToolConfig arm: count + alignToTangent (path preserved).
        tool.config = ArrayPathTool.Config(count: 3, alignToTangent: false, path: tool.config.path)
        #expect(tool.config.count == 3)
        #expect(tool.config.alignToTangent == false)
        // A straight horizontal path, one selected item → 3 equal-spaced copy transforms.
        let path = EntityRecord(id: .placeholder,
                                kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
        let item = EntityRecord(id: .placeholder,
                                kind: .point(PointData(position: Vector(0, 0))))
        let transforms = ArrayPathTool.copyTransforms(
            captured: [item], path: path, config: tool.config)
        #expect(transforms.count == 3)
    }

    @Test("plumbing: a Leader configured with text commits an annotation; empty ⇒ bare")
    func plumbingLeaderText() {
        guard var withText = ToolKind.leader.makeTool() as? LeaderTool,
              var bare = ToolKind.leader.makeTool() as? LeaderTool else {
            Issue.record("leader makeTool did not produce a LeaderTool"); return
        }
        // Mirror of the applyToolConfig arm: "" ⇒ nil annotation; non-empty ⇒ that text.
        withText.annotationText = "R5"
        withText.textHeight = 3
        bare.annotationText = nil
        let labeled = committedLeader(buildLeader(&withText))
        let plain = committedLeader(buildLeader(&bare))
        #expect(labeled?.annotation != nil, "leader with text must carry an annotation")
        #expect(plain?.annotation == nil, "bare leader must carry no annotation")
    }

    @Test("plumbing: a BaselineDim re-minted with a custom spacing carries it")
    func plumbingBaselineSpacing() {
        // Mirror of the applyToolConfig arm: BaselineDimTool is re-minted with the spacing.
        let tool = BaselineDimTool(baselineSpacing: 12.5)
        #expect(tool.baselineSpacing == 12.5)
        // And the default mint uses the documented DIMDLI fallback.
        let dflt = ToolKind.baselineDim.makeTool() as? BaselineDimTool
        #expect(dflt?.baselineSpacing == BaselineDimTool.defaultBaselineSpacing)
    }

    /// Drives a LeaderTool through two vertices + commit and extracts the LeaderData.
    private func buildLeader(_ tool: inout LeaderTool) -> ToolOutcome {
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)
        return tool.handle(.commit, context: .empty)
    }

    private func committedLeader(_ outcome: ToolOutcome) -> LeaderData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .leader(let d) = record.kind else { return nil }
        return d
    }

    private func committedImage(_ outcome: ToolOutcome) -> ImageData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .image(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - NEW modes on already-wired tools (this wave)
    //
    // These mirror the SAME downcast-and-set `CanvasModel.applyToolConfig` performs for
    // the Rectangle corner treatment, the Polygon construction mode, the Ellipse
    // construction mode, and the Image tool's file injection — proven over the public
    // tool surface (the model lives in the un-importable executable target). For the
    // enum-with-associated-value options (Rectangle corner / Polygon mode) the model
    // stores a case-index + scalar and assembles the enum here, exactly as the model's
    // arm does.

    /// Mirror of applyToolConfig's Rectangle corner assembly (case index + cut scalar).
    private func rectCorner(style: Int, size: Double) -> RectangleCorner {
        switch style {
        case 1:  return .rounded(radius: size)
        case 2:  return .chamfer(distance: size)
        default: return .square
        }
    }

    /// Mirror of applyToolConfig's Polygon mode assembly (case index + star ratio).
    private func polygonMode(style: Int, ratio: Double) -> PolygonMode {
        switch style {
        case 1:  return .edge
        case 2:  return .star(ratio: ratio)
        default: return .centerCorner
        }
    }

    @Test("plumbing: a Rectangle configured Square (style 0) keeps the 4 sharp corners")
    func plumbingRectCornerSquare() {
        guard var tool = ToolKind.rectangle.makeTool() as? RectangleTool else {
            Issue.record("rectangle makeTool did not produce a RectangleTool"); return
        }
        tool.corner = rectCorner(style: 0, size: 10)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(40, 30)), context: .empty))
        #expect(poly?.vertices.count == 4)
        #expect(poly?.vertices.allSatisfy { abs($0.bulge) < 1e-9 } == true)
    }

    @Test("plumbing: a Rectangle configured Rounded (style 1) produces 8 vertices with a bulge")
    func plumbingRectCornerRounded() {
        guard var tool = ToolKind.rectangle.makeTool() as? RectangleTool else {
            Issue.record("rectangle makeTool did not produce a RectangleTool"); return
        }
        tool.corner = rectCorner(style: 1, size: 5)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(40, 30)), context: .empty))
        // Each of the 4 corners becomes two tangent vertices → 8; rounded carries bulges.
        #expect(poly?.vertices.count == 8)
        #expect(poly?.vertices.contains { abs($0.bulge) > 1e-9 } == true)
    }

    @Test("plumbing: a Rectangle configured Chamfer (style 2) produces 8 straight vertices")
    func plumbingRectCornerChamfer() {
        guard var tool = ToolKind.rectangle.makeTool() as? RectangleTool else {
            Issue.record("rectangle makeTool did not produce a RectangleTool"); return
        }
        tool.corner = rectCorner(style: 2, size: 5)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(40, 30)), context: .empty))
        #expect(poly?.vertices.count == 8)
        // A chamfer is straight bevels — all bulges are 0.
        #expect(poly?.vertices.allSatisfy { abs($0.bulge) < 1e-9 } == true)
    }

    @Test("plumbing: a Polygon configured Edge (mode 1) builds the N-gon on one clicked edge")
    func plumbingPolygonModeEdge() {
        guard var tool = ToolKind.polygon.makeTool() as? PolygonTool else {
            Issue.record("polygon makeTool did not produce a PolygonTool"); return
        }
        tool.sides = 4
        tool.mode = polygonMode(style: 1, ratio: 0.5)
        // Two ADJACENT corners define one edge of length 6 → a square, side 6.
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(6, 0)), context: .empty))
        let pts = poly!.vertices.map(\.point)
        #expect(pts.count == 4)
        #expect((pts[0] - Vector(0, 0)).magnitude < 1e-9)   // first corner at the first click
        #expect((pts[1] - Vector(6, 0)).magnitude < 1e-9)   // second corner at the second click
        // Every side has the clicked edge's length (6).
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            #expect(abs((b - a).magnitude - 6) < 1e-9)
        }
    }

    @Test("plumbing: a Polygon configured Star (mode 2) commits a 2·N-point star ring")
    func plumbingPolygonModeStar() {
        guard var tool = ToolKind.polygon.makeTool() as? PolygonTool else {
            Issue.record("polygon makeTool did not produce a PolygonTool"); return
        }
        tool.sides = 5
        tool.mode = polygonMode(style: 2, ratio: 0.5)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let poly = committedPolyline(tool.handle(.click(Vector(10, 0)), context: .empty))
        // A 5-point star → 2·5 = 10 vertices (outer tips alternating inner valleys).
        #expect(poly?.vertices.count == 10)
        let pts = poly!.vertices.map(\.point)
        // Outer tips (even indices) lie on r=10; inner valleys (odd) at r=10·ratio=5.
        #expect(abs((pts[0] - Vector(0, 0)).magnitude - 10) < 1e-9)
        #expect(abs((pts[1] - Vector(0, 0)).magnitude - 5) < 1e-9)
    }

    @Test("plumbing: an Ellipse re-minted with .fociPoint mode walks the foci flow")
    func plumbingEllipseModeFociPoint() {
        // Mirror of applyToolConfig: EllipseTool's mode is fixed at construction, so the
        // model RE-MINTS EllipseTool(mode:) from the selected index.
        var tool = EllipseTool(mode: .fociPoint)
        #expect(tool.title == "Ellipse (Foci + Point)")
        #expect(tool.status == "Specify first focus of ellipse")
        _ = tool.handle(.click(Vector(-3, 0)), context: .empty)   // focus 1
        #expect(tool.status == "Specify second focus of ellipse")
        _ = tool.handle(.click(Vector(3, 0)), context: .empty)    // focus 2
        #expect(tool.status == "Specify a point on the ellipse")
        // A point on the ellipse → commits one .ellipse. (foci ±3, point (0,4):
        // a = ½(5+5)=5, c=3, b=4 → ratio 0.8.)
        let ell = committedEllipse(tool.handle(.click(Vector(0, 4)), context: .empty))
        #expect(ell != nil)
        #expect(abs(ell!.ratio - 0.8) < 1e-9)
    }

    @Test("plumbing: an Ellipse re-minted with .arc mode commits an elliptic ARC")
    func plumbingEllipseModeArc() {
        var tool = EllipseTool(mode: .arc)
        #expect(tool.title == "Elliptical Arc")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)    // center
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)    // major endpoint
        _ = tool.handle(.click(Vector(0, 2)), context: .empty)    // minor distance
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)    // start angle (0)
        let ell = committedEllipse(tool.handle(.click(Vector(0, 2)), context: .empty)) // end angle
        #expect(ell != nil)
        #expect(ell!.isArc, "an .arc-mode ellipse commits an elliptic arc (non-full)")
    }

    @Test("plumbing: an Ellipse re-minted with the default .axis mode is the full ellipse")
    func plumbingEllipseModeAxisDefault() {
        guard let tool = ToolKind.ellipse.makeTool() as? EllipseTool else {
            Issue.record("ellipse makeTool did not produce an EllipseTool"); return
        }
        #expect(tool.mode == .axis)
        #expect(tool.title == "Ellipse")
    }

    @Test("plumbing: the Image tool re-minted with a path + pixel size places that file")
    func plumbingImagePlacement() {
        // Mirror of applyToolConfig's Image arm: re-mint ImageTool(path:pixelWidth:pixelHeight:).
        var tool = ImageTool(path: "/tmp/logo.png", pixelWidth: 200, pixelHeight: 100)
        #expect(tool.status == "Specify the image's lower-left corner")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)           // lower-left
        #expect(tool.status == "Specify the opposite corner (size + rotation)")
        // Bottom-edge corner sets width (10) + rotation (0); height keeps pixel aspect.
        let img = committedImage(tool.handle(.click(Vector(10, 0)), context: .empty))
        #expect(img != nil)
        #expect(img?.imageDef.path == "/tmp/logo.png")
        #expect(abs((img?.worldWidth ?? 0) - 10) < 1e-9)
        // Pixel aspect 100/200 = 0.5 → height = width · 0.5 = 5.
        #expect(abs((img?.worldHeight ?? 0) - 5) < 1e-9)
        #expect(img?.imageDef.pixelWidth == 200)
        #expect(img?.imageDef.pixelHeight == 100)
    }

    @Test("plumbing: a bare (no-file) Image tool is inert")
    func plumbingImageNoFileInert() {
        guard var tool = ToolKind.image.makeTool() as? ImageTool else {
            Issue.record("image makeTool did not produce an ImageTool"); return
        }
        #expect(tool.status == "Choose an image file to place")
        #expect(tool.handle(.click(Vector(0, 0)), context: .empty) == .none)
    }

    // MARK: - Trim mode (boundary handled by `handle`; amount/mutual are static funcs)
    //
    // ENGINE GAP: TrimTool.handle always drives `.boundary` (single-click cut). The
    // `.amount` / `.mutual` variants exist only as PURE static entry points, NOT yet
    // dispatched from `handle`. The options bar surfaces all three modes + a signed
    // amount; these tests pin the static entry points the model's mode state targets.

    @Test("trim mode index → TrimTool.Mode mapping (mirrors applyToolConfig's split)")
    func trimModeIndexMapping() {
        func mode(_ i: Int) -> TrimTool.Mode {
            switch i { case 1: return .amount; case 2: return .mutual; default: return .boundary }
        }
        #expect(mode(0) == .boundary)
        #expect(mode(1) == .amount)
        #expect(mode(2) == .mutual)
    }

    @Test("trim AMOUNT: a positive signed distance lengthens a line at the picked end")
    func trimAmountLengthensLine() {
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        // Pick near the +x end; +5 lengthens it to length 15.
        let out = TrimTool.trimAmount(line, near: Vector(10, 0), distance: 5)
        guard case .line(let d)? = out else { Issue.record("trimAmount did not return a line"); return }
        #expect(abs(d.start.distance(to: d.end) - 15) < 1e-9)
    }

    @Test("trim MUTUAL: two crossing-carrier lines extend to their intersection (5,5)")
    func trimMutualMeetsAtIntersection() {
        // A horizontal and a vertical line whose carriers cross at (5,5). Both are
        // shorter than the crossing, so mutual trim EXTENDS each to (5,5).
        let a = EntityKind.line(LineData(start: Vector(0, 5), end: Vector(4, 5)))
        let b = EntityKind.line(LineData(start: Vector(5, 0), end: Vector(5, 4)))
        let result = TrimTool.mutualTrim(a, pickA: Vector(2, 5), b, pickB: Vector(5, 2))
        #expect(result != nil, "two crossing carriers must mutually trim/extend to (5,5)")
        // Each reshaped line must HAVE an endpoint at the (5,5) crossing (which endpoint
        // moves is the action's keep/discard choice — assert presence, not position).
        let crossing = Vector(5, 5)
        func touchesCrossing(_ kind: EntityKind?) -> Bool {
            guard case .line(let d)? = kind else { return false }
            return d.start.distance(to: crossing) < 1e-9 || d.end.distance(to: crossing) < 1e-9
        }
        #expect(touchesCrossing(result?.a), "entity a must reach the (5,5) crossing")
        #expect(touchesCrossing(result?.b), "entity b must reach the (5,5) crossing")
    }
}
