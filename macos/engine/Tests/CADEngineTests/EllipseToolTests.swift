//
//  EllipseToolTests.swift
//  CADEngineTests
//
//  Drives the center + major-axis-endpoint + minor-point `EllipseTool` PURELY
//  (no GUI): feeds `ToolInput` events + a read-only `ToolContext` and asserts the
//  committed geometry (a FULL `.ellipse` with the exact center, relative majorP,
//  and minor/major ratio), the live closed elliptical preview, the
//  re-arm-after-commit behavior, cancel/backspace resets, the degenerate guards,
//  and the status prompt transitions.
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding test files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("EllipseTool interactive draw")
struct EllipseToolTests {

    // MARK: - Helpers

    /// Pulls the single EllipseData out of a `.commit` outcome (returns nil if the
    /// outcome isn't a one-edit `.add` ellipse commit).
    private func committedEllipse(_ outcome: ToolOutcome) -> EllipseData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .ellipse(let d) = record.kind else { return nil }
        return d
    }

    // MARK: - Status / title

    @Test("status walks center → first axis endpoint → minor axis distance")
    func statusTransitions() {
        var tool = EllipseTool()
        #expect(tool.status == "Specify center point")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify first axis endpoint")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify minor axis distance")
    }

    @Test("title is Ellipse")
    func title() {
        #expect(EllipseTool().title == "Ellipse")
    }

    // MARK: - Center + major + minor commit (the brief's canonical case)

    @Test("center (0,0), major endpoint (10,0), minor point (0,5) → ratio 0.5")
    func threeClicksCommit() {
        var tool = EllipseTool()
        let center = Vector(0, 0)

        let first = tool.handle(.click(center), context: .empty)
        #expect(first == .none)   // first click only fixes the center

        let second = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(second == .none)  // second click only fixes the major axis

        let third = tool.handle(.click(Vector(0, 5)), context: .empty)
        let ellipse = committedEllipse(third)
        #expect(ellipse != nil)
        #expect(ellipse?.center == center)
        #expect(ellipse?.majorP == Vector(10, 0))      // RELATIVE to center
        #expect(ellipse?.majorRadius == 10)
        #expect(abs((ellipse?.ratio ?? 0) - 0.5) < 1e-9)
        #expect(abs((ellipse?.minorRadius ?? 0) - 5) < 1e-9)
    }

    @Test("majorP is RELATIVE to the center (offset center)")
    func majorPIsRelative() {
        var tool = EllipseTool()
        let center = Vector(3, 7)
        _ = tool.handle(.click(center), context: .empty)
        _ = tool.handle(.click(Vector(3 + 10, 7)), context: .empty)   // +X by 10
        let ellipse = committedEllipse(tool.handle(.click(Vector(3, 7 + 4)), context: .empty))
        #expect(ellipse?.center == center)
        #expect(ellipse?.majorP == Vector(10, 0))      // relative, not absolute
        #expect(abs((ellipse?.ratio ?? 0) - 0.4) < 1e-9)
    }

    @Test("ratio is the perpendicular distance to the major-axis line over |majorP|")
    func ratioIsPerpendicularDistance() {
        // Major axis along +X (len 10); a minor point off the line at (7, 3): its
        // perpendicular distance to the X axis is 3, so ratio = 3 / 10 = 0.3.
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let ellipse = committedEllipse(tool.handle(.click(Vector(7, 3)), context: .empty))
        #expect(abs((ellipse?.ratio ?? 0) - 0.3) < 1e-9)
    }

    @Test("ratio uses perpendicular distance even for a rotated major axis")
    func ratioForRotatedMajorAxis() {
        // Major axis along +Y (rotated 90°), len 10. A minor point at (4, 6): its
        // perpendicular distance to the Y axis is 4, so ratio = 4 / 10 = 0.4.
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 10)), context: .empty)
        let ellipse = committedEllipse(tool.handle(.click(Vector(4, 6)), context: .empty))
        #expect(ellipse?.majorP == Vector(0, 10))
        #expect(abs((ellipse?.ratio ?? 0) - 0.4) < 1e-9)
    }

    @Test("ratio is clamped to 1 when the minor point is farther than the major radius")
    func ratioClampedToOne() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(5, 0)), context: .empty)         // major radius 5
        let ellipse = committedEllipse(tool.handle(.click(Vector(0, 20)), context: .empty)) // perp 20
        #expect(ellipse?.ratio == 1.0)
    }

    @Test("full ellipse is encoded as startAngle == endAngle == 0 (isArc == false)")
    func fullEllipseEncoding() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let ellipse = committedEllipse(tool.handle(.click(Vector(0, 5)), context: .empty))
        #expect(ellipse?.startAngle == 0)
        #expect(ellipse?.endAngle == 0)
        #expect(ellipse?.reversed == false)
        #expect(ellipse?.isArc == false)   // the whole-ellipse convention
    }

    @Test("committed record carries the placeholder id and EntityRecord defaults")
    func commitUsesPlaceholderID() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(0, 5)), context: .empty)
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0] else {
            Issue.record("expected a single-add commit outcome")
            return
        }
        #expect(record.id == .placeholder)
        #expect(record.id == EntityID(0))
        // Common attrs match the LineTool/EntityRecord defaults (consistency).
        #expect(record.layer == .zero)
        #expect(record.pen == .byLayer)
        #expect(record.flags == .default)
    }

    // MARK: - Re-arm after commit

    @Test("after committing an ellipse the tool re-arms to specify a new center")
    func reArmsAfterCommit() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(0, 5)), context: .empty)
        #expect(committedEllipse(outcome) != nil)
        // Back to the initial state, preview cleared, ready for the next ellipse.
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)

        // A second ellipse can be drawn immediately.
        _ = tool.handle(.click(Vector(20, 20)), context: .empty)
        _ = tool.handle(.click(Vector(28, 20)), context: .empty)   // major radius 8
        let ellipse2 = committedEllipse(tool.handle(.click(Vector(20, 24)), context: .empty)) // perp 4
        #expect(ellipse2?.center == Vector(20, 20))
        #expect(ellipse2?.majorP == Vector(8, 0))
        #expect(abs((ellipse2?.ratio ?? 0) - 0.5) < 1e-9)
    }

    // MARK: - Preview (closed rubber-band ellipse)

    @Test("preview is empty before and during the first two picks")
    func previewEmptyEarly() {
        var tool = EllipseTool()
        #expect(tool.preview.isEmpty)
        // Move with nothing fixed → nothing.
        #expect(tool.handle(.move(Vector(3, 3)), context: .empty) == .none)
        #expect(tool.preview.isEmpty)
        // After only the center is set, a move still shows nothing (no major axis).
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.handle(.move(Vector(5, 0)), context: .empty) == .none)
        #expect(tool.preview.isEmpty)
    }

    @Test("after the major axis is set a move produces a CLOSED elliptical preview")
    func previewAfterMajor() {
        var tool = EllipseTool()
        let center = Vector(0, 0)
        _ = tool.handle(.click(center), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)   // majorP (10,0)

        let outcome = tool.handle(.move(Vector(0, 5)), context: .empty)   // ratio 0.5
        #expect(outcome == .preview)

        #expect(tool.preview.count == 1)
        let poly = tool.preview[0]
        #expect(poly.closed == true)
        // Tessellated ellipse: at least a triangle's worth of points.
        #expect(poly.points.count >= 3)

        // The preview points fit the ellipse: extents ±10 in x, ±5 in y, and every
        // point satisfies (x/10)² + (y/5)² ≈ 1.
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in poly.points {
            maxX = Swift.max(maxX, abs(p.x))
            maxY = Swift.max(maxY, abs(p.y))
            let onCurve = (p.x / 10.0) * (p.x / 10.0) + (p.y / 5.0) * (p.y / 5.0)
            #expect(abs(onCurve - 1.0) < 1e-6)
        }
        #expect(abs(maxX - 10) < 1e-6)   // x extent reaches ±10
        #expect(abs(maxY - 5) < 1e-6)    // y extent reaches ±5
    }

    @Test("preview ratio follows the cursor on a subsequent move")
    func previewFollowsCursor() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(0, 2)), context: .empty)
        _ = tool.handle(.move(Vector(0, 8)), context: .empty)   // ratio now 0.8

        let poly = tool.preview[0]
        var maxY = -Double.greatestFiniteMagnitude
        for p in poly.points { maxY = Swift.max(maxY, abs(p.y)) }
        #expect(abs(maxY - 8) < 1e-6)   // minor radius 8 = 10 * 0.8
    }

    @Test("preview is empty while the cursor is on the major-axis line (ratio 0)")
    func previewEmptyAtZeroRatio() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        // Cursor on the X axis → perpendicular distance 0 → ratio 0.
        let outcome = tool.handle(.move(Vector(4, 0)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.preview.isEmpty)
    }

    // MARK: - Degenerate guards

    @Test("a zero-length major axis (second click on center) does not advance")
    func zeroMajorClickIgnored() {
        var tool = EllipseTool()
        let center = Vector(3, 3)
        _ = tool.handle(.click(center), context: .empty)
        let outcome = tool.handle(.click(center), context: .empty)   // same point
        #expect(outcome == .none)
        // Still waiting for the first axis endpoint — center stays fixed.
        #expect(tool.status == "Specify first axis endpoint")
    }

    @Test("a degenerate (ratio 0) minor click does not commit")
    func zeroRatioClickIgnored() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        // Minor point on the major-axis line → ratio 0 → ignored.
        let outcome = tool.handle(.click(Vector(5, 0)), context: .empty)
        #expect(outcome == .none)
        #expect(tool.status == "Specify minor axis distance")
    }

    // MARK: - Cancel / commit / backspace

    @Test("cancel resets to an empty preview and finishes")
    func cancelResets() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.move(Vector(0, 5)), context: .empty)
        #expect(!tool.preview.isEmpty)

        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("commit while idle ends the run and finishes")
    func commitFinishes() {
        var tool = EllipseTool()
        let outcome = tool.handle(.commit, context: .empty)   // Return → end the run
        #expect(outcome == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify center point")
    }

    @Test("backspace steps back one pick at a time")
    func backspaceRewinds() {
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify minor axis distance")

        // First backspace: undo the major-axis pick → back to first-endpoint.
        let one = tool.handle(.backspace, context: .empty)
        #expect(one == .preview)
        #expect(tool.status == "Specify first axis endpoint")
        #expect(tool.preview.isEmpty)

        // Second backspace: undo the center pick → back to the initial state.
        let two = tool.handle(.backspace, context: .empty)
        #expect(two == .preview)
        #expect(tool.status == "Specify center point")
        #expect(tool.preview.isEmpty)
    }

    @Test("backspace with nothing fixed is a no-op")
    func backspaceNoop() {
        var tool = EllipseTool()
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
        var tool = EllipseTool()
        _ = tool.handle(.click(Vector(1, 2)), context: ctx)
        _ = tool.handle(.click(Vector(1 + 10, 2)), context: ctx)
        let ellipse = committedEllipse(tool.handle(.click(Vector(1, 2 + 5)), context: ctx))
        #expect(ellipse?.center == Vector(1, 2))
        #expect(ellipse?.majorP == Vector(10, 0))
        #expect(abs((ellipse?.ratio ?? 0) - 0.5) < 1e-9)
    }
}

// MARK: - EllipseTool construction VARIANTS (foci+point / 4-point / inscribe / arc)

/// Drives the UNWIRED `EllipseTool.Mode` variants PURELY (no GUI): foci+point,
/// 4-point fit, inscribe-in-parallelogram, and the elliptic-arc mode. Each asserts
/// the resulting center / majorP magnitude+direction / ratio (within tolerance),
/// and the arc asserts its start/end angles. The `axisModeUnchanged*` tests pin the
/// default `.axis` mode so the existing construction stays identical.
@Suite("EllipseTool construction variants")
struct EllipseVariantTests {

    /// Pulls the single committed EllipseData out of a `.commit` outcome.
    private func committedEllipse(_ outcome: ToolOutcome) -> EllipseData? {
        guard case .commit(let edits) = outcome, edits.count == 1,
              case .add(let record) = edits[0],
              case .ellipse(let d) = record.kind else { return nil }
        return d
    }

    /// Asserts two angles are equal modulo 2π within `tol`.
    private func angleClose(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool {
        let twoPi = 2 * Double.pi
        var diff = (a - b).truncatingRemainder(dividingBy: twoPi)
        if diff < 0 { diff += twoPi }
        if diff > Double.pi { diff -= twoPi }
        return abs(diff) < tol
    }

    // MARK: - Default mode is unchanged (.axis)

    @Test("default init selects .axis and draws the original center→major→minor full ellipse")
    func axisModeUnchangedByDefault() {
        var tool = EllipseTool()
        #expect(tool.mode == .axis)
        #expect(tool.title == "Ellipse")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        let e = committedEllipse(tool.handle(.click(Vector(0, 5)), context: .empty))
        #expect(e?.center == Vector(0, 0))
        #expect(e?.majorP == Vector(10, 0))
        #expect(abs((e?.ratio ?? 0) - 0.5) < 1e-9)
        #expect(e?.isArc == false)   // still a WHOLE ellipse
    }

    @Test("explicit .axis init is identical to the default")
    func axisModeExplicitMatchesDefault() {
        var tool = EllipseTool(mode: .axis)
        _ = tool.handle(.click(Vector(2, 3)), context: .empty)
        _ = tool.handle(.click(Vector(2 + 8, 3)), context: .empty)
        let e = committedEllipse(tool.handle(.click(Vector(2, 3 + 4)), context: .empty))
        #expect(e?.center == Vector(2, 3))
        #expect(e?.majorP == Vector(8, 0))
        #expect(abs((e?.ratio ?? 0) - 0.5) < 1e-9)
    }

    // MARK: - Foci + point

    @Test("foci (±4,0) + point (0,3) → center 0, majorP (5,0), ratio 0.6")
    func fociPointCanonical() {
        // foci at (4,0) & (-4,0): c = 4. point (0,3): sum of distances = 2·5 = 10
        // ⇒ a = 5. b = √(25−16) = 3 ⇒ ratio 0.6. major axis toward F1 = +X.
        var tool = EllipseTool(mode: .fociPoint)
        #expect(tool.status == "Specify first focus of ellipse")
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        #expect(tool.status == "Specify second focus of ellipse")
        _ = tool.handle(.click(Vector(-4, 0)), context: .empty)
        #expect(tool.status == "Specify a point on the ellipse")
        let e = committedEllipse(tool.handle(.click(Vector(0, 3)), context: .empty))
        #expect(e != nil)
        #expect(e?.center == Vector(0, 0))
        #expect(abs((e?.majorRadius ?? 0) - 5) < 1e-9)
        #expect(abs((e?.majorP.angle ?? -1) - 0) < 1e-9)          // major toward F1 (+X)
        #expect(abs((e?.ratio ?? 0) - 0.6) < 1e-9)
        #expect(e?.isArc == false)
    }

    @Test("foci+point major axis follows the focal direction (rotated foci)")
    func fociPointRotated() {
        // foci along +Y at (0,±4); point (3,0). a = ½(5+5) = 5, c = 4, b = 3.
        // major axis points toward F1 = (0,4) ⇒ angle π/2.
        var tool = EllipseTool(mode: .fociPoint)
        _ = tool.handle(.click(Vector(0, 4)), context: .empty)
        _ = tool.handle(.click(Vector(0, -4)), context: .empty)
        let e = committedEllipse(tool.handle(.click(Vector(3, 0)), context: .empty))
        #expect(e?.center == Vector(0, 0))
        #expect(abs((e?.majorRadius ?? 0) - 5) < 1e-9)
        #expect(angleClose(e?.majorP.angle ?? -1, .pi / 2))
        #expect(abs((e?.ratio ?? 0) - 0.6) < 1e-9)
    }

    @Test("foci+point rejects coincident foci and a degenerate point")
    func fociPointDegenerate() {
        var tool = EllipseTool(mode: .fociPoint)
        _ = tool.handle(.click(Vector(1, 1)), context: .empty)
        // Same point as focus1 → second focus ignored (foci must be distinct).
        let same = tool.handle(.click(Vector(1, 1)), context: .empty)
        #expect(same == .none)
        #expect(tool.status == "Specify second focus of ellipse")
        // A real second focus, then a point ON the focal segment (a ≤ c) is rejected.
        _ = tool.handle(.click(Vector(5, 1)), context: .empty)   // foci (1,1)-(5,1), c=2
        let onAxis = tool.handle(.click(Vector(3, 1)), context: .empty)  // a = 2 == c
        #expect(onAxis == .none)
    }

    // MARK: - 4-point fit

    @Test("4 points on an axis-aligned ellipse recover center/majorP/ratio")
    func fourPointAxisAligned() {
        // Ellipse centered (2,3), a=10 along X, b=5 along Y.
        // (x-2)²/100 + (y-3)²/25 = 1. Sample the four axis vertices.
        var tool = EllipseTool(mode: .fourPoint)
        #expect(tool.title == "Ellipse (4 Points)")
        #expect(tool.status == "Specify point 1 of 4")
        _ = tool.handle(.click(Vector(12, 3)), context: .empty)
        _ = tool.handle(.click(Vector(-8, 3)), context: .empty)
        _ = tool.handle(.click(Vector(2, 8)), context: .empty)
        let e = committedEllipse(tool.handle(.click(Vector(2, -2)), context: .empty))
        #expect(e != nil)
        #expect(abs((e?.center.x ?? 0) - 2) < 1e-6)
        #expect(abs((e?.center.y ?? 0) - 3) < 1e-6)
        #expect(abs((e?.majorRadius ?? 0) - 10) < 1e-6)
        #expect(angleClose(e?.majorP.angle ?? -1, 0))   // major along +X
        #expect(abs((e?.ratio ?? 0) - 0.5) < 1e-6)
    }

    @Test("4-point fit normalizes a tall ellipse so majorP is along +Y (ratio ≤ 1)")
    func fourPointTallNormalizes() {
        // Centered origin, a=4 along X, b=12 along Y (tall): major axis is +Y.
        var tool = EllipseTool(mode: .fourPoint)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(-4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 12)), context: .empty)
        let e = committedEllipse(tool.handle(.click(Vector(0, -12)), context: .empty))
        #expect(abs((e?.majorRadius ?? 0) - 12) < 1e-6)
        #expect(angleClose(e?.majorP.angle ?? -1, .pi / 2))   // major along +Y
        #expect(abs((e?.ratio ?? 0) - (4.0 / 12.0)) < 1e-6)
    }

    @Test("4 collinear points do not commit (fit fails, last pick is dropped)")
    func fourPointCollinearRejected() {
        var tool = EllipseTool(mode: .fourPoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        _ = tool.handle(.click(Vector(2, 0)), context: .empty)
        let outcome = tool.handle(.click(Vector(3, 0)), context: .empty)
        #expect(outcome == .none)             // no commit on a degenerate fit
        #expect(tool.status == "Specify point 4 of 4")  // dropped back to re-pick #4
    }

    // MARK: - Inscribe in a parallelogram

    @Test("inscribe in an axis-aligned rectangle → the ellipse touching the side midpoints")
    func inscribeRectangle() {
        // Rectangle corners (−10,−5),(10,−5),(10,5),(−10,5). The inscribed ellipse
        // touches the side midpoints ⇒ a=10 (X), b=5 (Y), centered at origin.
        var tool = EllipseTool(mode: .inscribeQuad)
        #expect(tool.title == "Ellipse (Inscribed)")
        #expect(tool.status == "Specify corner 1 of 4")
        _ = tool.handle(.click(Vector(-10, -5)), context: .empty)
        _ = tool.handle(.click(Vector(10, -5)), context: .empty)
        _ = tool.handle(.click(Vector(10, 5)), context: .empty)
        let e = committedEllipse(tool.handle(.click(Vector(-10, 5)), context: .empty))
        #expect(e != nil)
        #expect(abs((e?.center.x ?? 9) - 0) < 1e-9)
        #expect(abs((e?.center.y ?? 9) - 0) < 1e-9)
        #expect(abs((e?.majorRadius ?? 0) - 10) < 1e-9)
        #expect(angleClose(e?.majorP.angle ?? -1, 0))
        #expect(abs((e?.ratio ?? 0) - 0.5) < 1e-9)
    }

    @Test("inscribe in a SKEWED parallelogram fits an ellipse through all four side midpoints")
    func inscribeSkewedParallelogram() {
        // Parallelogram from edge vectors e1=(10,0), e2=(4,6) at base (−7,−3):
        // corners P0=(−7,−3), P1=(3,−3), P2=(7,3), P3=(−3,3). Center = (0,0).
        // Conjugate semi-diameters = midpoints of adjacent sides relative to center:
        //   u = midpoint(P0,P1) − C = (−2,−3),  v = midpoint(P1,P2) − C = (5,0).
        let p0 = Vector(-7, -3), p1 = Vector(3, -3), p2 = Vector(7, 3), p3 = Vector(-3, 3)
        var tool = EllipseTool(mode: .inscribeQuad)
        _ = tool.handle(.click(p0), context: .empty)
        _ = tool.handle(.click(p1), context: .empty)
        _ = tool.handle(.click(p2), context: .empty)
        let e = committedEllipse(tool.handle(.click(p3), context: .empty))
        #expect(e != nil)
        guard let data = e else { return }
        #expect(abs(data.center.x) < 1e-9)
        #expect(abs(data.center.y) < 1e-9)
        // The four side-midpoints must lie ON the resulting ellipse: in the local
        // (unrotated, unscaled) frame each satisfies (x/a)² + (y/b)² ≈ 1.
        let a = data.majorRadius, b = data.minorRadius
        let rot = data.majorP.angle
        for mid in [(p0 + p1) * 0.5, (p1 + p2) * 0.5, (p2 + p3) * 0.5, (p3 + p0) * 0.5] {
            let local = (mid - data.center).rotated(by: -rot)
            let onCurve = (local.x / a) * (local.x / a) + (local.y / b) * (local.y / b)
            #expect(abs(onCurve - 1.0) < 1e-6)
        }
        #expect((data.ratio) <= 1.0 + 1e-12)   // ratio invariant
    }

    @Test("inscribe rejects a non-parallelogram (a trapezoid / arbitrary quad)")
    func inscribeNonParallelogramRejected() {
        // A trapezoid: the diagonals do NOT bisect each other.
        var tool = EllipseTool(mode: .inscribeQuad)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(7, 5)), context: .empty)
        let outcome = tool.handle(.click(Vector(2, 5)), context: .empty)   // top shorter
        #expect(outcome == .none)
        #expect(tool.status == "Specify corner 4 of 4")   // dropped back to re-pick
    }

    // MARK: - Elliptical arc (axis + start/end angles)

    @Test("arc mode: axis ellipse then start (10,0) / end (0,5) → quarter elliptic arc")
    func arcQuarter() {
        // center (0,0), major (10,0), ratio 0.5. Start at angle 0 (point on +X
        // vertex), end at angle π/2 (point on +Y co-vertex).
        var tool = EllipseTool(mode: .arc)
        #expect(tool.title == "Elliptical Arc")
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tool.status == "Specify first axis endpoint")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify minor axis distance")
        _ = tool.handle(.click(Vector(0, 5)), context: .empty)   // ratio 0.5
        #expect(tool.status == "Specify start angle")
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)  // start angle = 0
        #expect(tool.status == "Specify end angle")
        let e = committedEllipse(tool.handle(.click(Vector(0, 5)), context: .empty))  // end = π/2
        #expect(e != nil)
        #expect(e?.center == Vector(0, 0))
        #expect(e?.majorP == Vector(10, 0))
        #expect(abs((e?.ratio ?? 0) - 0.5) < 1e-9)
        #expect(angleClose(e?.startAngle ?? -1, 0))
        #expect(angleClose(e?.endAngle ?? -1, .pi / 2))
        #expect(e?.isArc == true)    // an elliptic ARC, not a whole ellipse
        #expect(e?.reversed == false)
    }

    @Test("arc mode: angles read from off-axis picks via the ellipse-angle projection")
    func arcOffAxisAngles() {
        // center (0,0), major (10,0), ratio 0.5. A start pick anywhere along the
        // +Y direction maps to ellipse angle π/2; a pick along −X maps to π.
        var tool = EllipseTool(mode: .arc)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 5)), context: .empty)
        _ = tool.handle(.click(Vector(0, 99)), context: .empty)    // start: +Y ⇒ π/2
        let e = committedEllipse(tool.handle(.click(Vector(-3, 0)), context: .empty))  // end: −X ⇒ π
        #expect(angleClose(e?.startAngle ?? -1, .pi / 2))
        #expect(angleClose(e?.endAngle ?? -1, .pi))
        #expect(e?.isArc == true)
    }

    @Test("arc mode rejects a zero-sweep (start ≈ end) so it stays an arc, not a whole ellipse")
    func arcZeroSweepRejected() {
        var tool = EllipseTool(mode: .arc)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 5)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)   // start angle 0
        let outcome = tool.handle(.click(Vector(10, 0)), context: .empty)  // end angle 0
        #expect(outcome == .none)
        #expect(tool.status == "Specify end angle")   // still waiting for a real end
    }

    @Test("arc mode preview is a partial (open) elliptic arc once the start angle is fixed")
    func arcPreviewIsOpen() {
        var tool = EllipseTool(mode: .arc)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 5)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)   // start angle 0
        let outcome = tool.handle(.move(Vector(0, 5)), context: .empty)   // cursor end ≈ π/2
        #expect(outcome == .preview)
        #expect(tool.preview.count == 1)
        #expect(tool.preview[0].closed == false)   // an OPEN arc, not a closed ring
    }

    // MARK: - Backspace / re-arm across variants

    @Test("foci+point backspace steps back focus2 → focus1 → initial")
    func fociBackspace() {
        var tool = EllipseTool(mode: .fociPoint)
        _ = tool.handle(.click(Vector(4, 0)), context: .empty)
        _ = tool.handle(.click(Vector(-4, 0)), context: .empty)
        #expect(tool.status == "Specify a point on the ellipse")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify second focus of ellipse")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify first focus of ellipse")
        let noop = tool.handle(.backspace, context: .empty)
        #expect(noop == .none)
    }

    @Test("collecting modes backspace pops the last pick")
    func collectBackspace() {
        var tool = EllipseTool(mode: .fourPoint)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(1, 0)), context: .empty)
        #expect(tool.status == "Specify point 3 of 4")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify point 2 of 4")
    }

    @Test("arc mode backspace rewinds the angle picks back to the axis spine")
    func arcBackspace() {
        var tool = EllipseTool(mode: .arc)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        _ = tool.handle(.click(Vector(0, 5)), context: .empty)
        _ = tool.handle(.click(Vector(10, 0)), context: .empty)
        #expect(tool.status == "Specify end angle")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify start angle")
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify minor axis distance")
    }

    @Test("each variant re-arms to its initial state after a commit")
    func variantsReArm() {
        var foci = EllipseTool(mode: .fociPoint)
        _ = foci.handle(.click(Vector(4, 0)), context: .empty)
        _ = foci.handle(.click(Vector(-4, 0)), context: .empty)
        _ = foci.handle(.click(Vector(0, 3)), context: .empty)
        #expect(foci.status == "Specify first focus of ellipse")

        var four = EllipseTool(mode: .fourPoint)
        _ = four.handle(.click(Vector(12, 3)), context: .empty)
        _ = four.handle(.click(Vector(-8, 3)), context: .empty)
        _ = four.handle(.click(Vector(2, 8)), context: .empty)
        _ = four.handle(.click(Vector(2, -2)), context: .empty)
        #expect(four.status == "Specify point 1 of 4")
    }

    @Test("cancel finishes any variant and resets to its initial state")
    func variantCancel() {
        var tool = EllipseTool(mode: .inscribeQuad)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let outcome = tool.handle(.cancel, context: .empty)
        #expect(outcome == .finished)
        #expect(tool.status == "Specify corner 1 of 4")
    }

    // MARK: - Static construction helpers (direct math checks)

    @Test("axesFromConjugate recovers axes from perpendicular conjugate diameters")
    func axesFromConjugatePerpendicular() {
        let e = EllipseTool.axesFromConjugate(center: Vector(0, 0), u: Vector(10, 0), v: Vector(0, 5))
        #expect(abs((e?.majorRadius ?? 0) - 10) < 1e-9)
        #expect(abs((e?.ratio ?? 0) - 0.5) < 1e-9)
    }

    @Test("ellipseAngle maps a +Y direction on a 0.5-ratio ellipse to π/2")
    func ellipseAngleProjection() {
        let ang = EllipseTool.ellipseAngle(center: Vector(0, 0), majorP: Vector(10, 0),
                                           ratio: 0.5, point: Vector(0, 7))
        #expect(angleClose(ang, .pi / 2))
    }
}
