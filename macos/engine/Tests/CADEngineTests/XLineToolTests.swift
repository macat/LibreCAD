//
//  XLineToolTests.swift
//  CADEngineTests
//
//  Tests for the construction-line draw tools — `XLineTool` (infinite) and
//  `RayTool` (semi-infinite) (feature-catalog #F1). Drive `.click`/`.move`/
//  `.commit`/`.cancel` with NO GUI (the pure `Tool` contract):
//   - two clicks commit a `.xline` / `.ray` with the right base + direction;
//   - the preview rubber-bands after the base is fixed;
//   - constraint modes (horizontal / vertical / angle) lock the xline direction;
//   - the ray's direction runs base → second point;
//   - cancel / backspace reset the tool.
//
//  Uniquely namespaced so it does not collide with the existing suites.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("xline/ray draw tools")
struct XLineToolTests {

    /// Drains the first `.add` xline out of a tool outcome.
    private func addedXLine(_ outcome: ToolOutcome) -> XLineData? {
        guard case .commit(let edits) = outcome else { return nil }
        for e in edits {
            if case .add(let rec) = e, case .xline(let d) = rec.kind { return d }
        }
        return nil
    }

    private func addedRay(_ outcome: ToolOutcome) -> RayData? {
        guard case .commit(let edits) = outcome else { return nil }
        for e in edits {
            if case .add(let rec) = e, case .ray(let d) = rec.kind { return d }
        }
        return nil
    }

    // MARK: - XLineTool (free, two-point)

    @Test("two clicks commit an xline through the base toward the second point")
    func xlineTwoClicks() {
        var tool = XLineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)        // base
        let out = tool.handle(.click(Vector(1, 1)), context: .empty)  // direction
        let d = addedXLine(out)
        #expect(d != nil)
        #expect(abs(d!.base.x) < 1e-9 && abs(d!.base.y) < 1e-9)
        // Direction is base → (1,1): a 45° line.
        #expect(abs(d!.direction.angle - .pi / 4) < 1e-9)
    }

    @Test("the xline preview rubber-bands once the base is fixed")
    func xlinePreview() {
        var tool = XLineTool()
        #expect(tool.preview.isEmpty)                       // nothing yet
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(2, 0)), context: .empty)
        #expect(!tool.preview.isEmpty)                      // a large preview segment
        let pts = tool.preview[0].points
        #expect(pts.count == 2)
        // Horizontal preview through y == 0.
        #expect(abs(pts[0].y) < 1e-6 && abs(pts[1].y) < 1e-6)
    }

    @Test("a typed coordinate places the xline like a click")
    func xlineTypedValue() {
        var tool = XLineTool()
        _ = tool.handle(.value(Vector(0, 0)), context: .empty)
        let out = tool.handle(.value(Vector(0, 5)), context: .empty)
        let d = addedXLine(out)
        #expect(d != nil)
        #expect(abs(d!.direction.angle - .pi / 2) < 1e-9)   // vertical
    }

    // MARK: - XLineTool constraint modes

    @Test("horizontal mode locks the xline direction regardless of the second point")
    func xlineHorizontalMode() {
        var tool = XLineTool(mode: .horizontal)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        // Second point is up-and-to-the-right, but the mode forces horizontal.
        let out = tool.handle(.click(Vector(3, 9)), context: .empty)
        let d = addedXLine(out)
        #expect(d != nil)
        #expect(abs(d!.direction.x - 1) < 1e-9 && abs(d!.direction.y) < 1e-9)
    }

    @Test("vertical mode locks the xline direction to +y")
    func xlineVerticalMode() {
        var tool = XLineTool(mode: .vertical)
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.click(Vector(9, 1)), context: .empty)
        let d = addedXLine(out)
        #expect(d != nil)
        #expect(abs(d!.direction.x) < 1e-9 && abs(d!.direction.y - 1) < 1e-9)
    }

    @Test("angle mode locks the xline to the fixed angle")
    func xlineAngleMode() {
        var tool = XLineTool(mode: .angle(.pi / 6))   // 30°
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.click(Vector(100, -100)), context: .empty)
        let d = addedXLine(out)
        #expect(d != nil)
        #expect(abs(d!.direction.angle - .pi / 6) < 1e-9)
    }

    // MARK: - XLineTool chaining / cancel / backspace

    @Test("the xline tool continues from the same base after a commit")
    func xlineChainsFromBase() {
        var tool = XLineTool()
        _ = tool.handle(.click(Vector(5, 5)), context: .empty)            // base
        let out1 = tool.handle(.click(Vector(6, 5)), context: .empty)     // line 1
        #expect(addedXLine(out1) != nil)
        // A second direction click commits ANOTHER xline through the SAME base.
        let out2 = tool.handle(.click(Vector(5, 6)), context: .empty)
        let d2 = addedXLine(out2)
        #expect(d2 != nil)
        #expect(abs(d2!.base.x - 5) < 1e-9 && abs(d2!.base.y - 5) < 1e-9)
    }

    @Test("cancel finishes and resets the xline tool")
    func xlineCancelResets() {
        var tool = XLineTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        let out = tool.handle(.cancel, context: .empty)
        #expect(out == .finished)
        #expect(tool.preview.isEmpty)
        #expect(tool.status == "Specify base point")
    }

    // MARK: - RayTool

    @Test("two clicks commit a ray from the base toward the second point")
    func rayTwoClicks() {
        var tool = RayTool()
        _ = tool.handle(.click(Vector(2, 2)), context: .empty)         // base
        let out = tool.handle(.click(Vector(2, 8)), context: .empty)   // up
        let d = addedRay(out)
        #expect(d != nil)
        #expect(abs(d!.base.x - 2) < 1e-9 && abs(d!.base.y - 2) < 1e-9)
        // Direction runs base → (2,8): straight up.
        #expect(abs(d!.direction.angle - .pi / 2) < 1e-9)
    }

    @Test("the ray preview starts at the base and runs toward the cursor")
    func rayPreview() {
        var tool = RayTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.move(Vector(1, 0)), context: .empty)
        #expect(!tool.preview.isEmpty)
        let pts = tool.preview[0].points
        // First point is the base, the second is far in +x.
        #expect(abs(pts[0].x) < 1e-9 && abs(pts[0].y) < 1e-9)
        #expect(pts[1].x > 1e5)
    }

    @Test("a degenerate (coincident) second click does not commit a ray")
    func rayDegenerateNoCommit() {
        var tool = RayTool()
        _ = tool.handle(.click(Vector(3, 3)), context: .empty)
        let out = tool.handle(.click(Vector(3, 3)), context: .empty)  // same point
        #expect(addedRay(out) == nil)
    }

    @Test("backspace rewinds the ray tool to wait for the base again")
    func rayBackspaceRewinds() {
        var tool = RayTool()
        _ = tool.handle(.click(Vector(0, 0)), context: .empty)
        _ = tool.handle(.backspace, context: .empty)
        #expect(tool.status == "Specify start point")
        #expect(tool.preview.isEmpty)
    }
}
