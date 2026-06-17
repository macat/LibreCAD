//
//  ToolModeKeywordTests.swift
//  CADEngineTests
//
//  Tests the CONSTRUCTION-MODE `keywordOptions` overrides on the three draw tools
//  that the smart command line surfaces AutoCAD-style mode chips for (Wave 2B):
//  `CircleTool`, `ArcTool`, `EllipseTool`. The contract each implements:
//   - in the INITIAL state (nothing placed yet) `keywordOptions` returns one chip
//     per construction mode the tool supports EXCEPT the currently-active one (plus
//     a Circle size toggle);
//   - after the FIRST pick (a `.click`/`.value` that advances out of the initial
//     state) it returns `[]` — switching mode mid-draw re-mints the tool (Wave 3),
//     which is only safe with no in-progress picks to lose.
//
//  No GUI: pure value types, driven without AppKit/Metal (the `.empty` context).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("tool construction-mode keywords")
struct ToolModeKeywordTests {

    /// The `keyword` tokens of a tool's current options, in order.
    private func keywords<T: Tool>(_ tool: T) -> [String] {
        tool.keywordOptions.map(\.keyword)
    }

    // MARK: - CircleTool

    @Test("Circle: initial keywords exclude the active mode and add a size toggle")
    func circleInitialKeywords() {
        // centerRadius (radius size) → 2P, 3P + the Diameter toggle (not Cen, not Radius).
        let cr = CircleTool(mode: .centerRadius)
        #expect(keywords(cr) == ["2P", "3P", "Diameter"])

        // centerRadius in diameter size mode → the toggle flips to Radius.
        var crDia = CircleTool(mode: .centerRadius)
        crDia.sizeMode = .diameter
        #expect(keywords(crDia) == ["2P", "3P", "Radius"])

        // twoPoint → Cen, 3P (no 2P, no size toggle outside centerRadius).
        let tp = CircleTool(mode: .twoPoint)
        #expect(keywords(tp) == ["Cen", "3P"])

        // threePoint → Cen, 2P.
        let three = CircleTool(mode: .threePoint)
        #expect(keywords(three) == ["Cen", "2P"])
    }

    @Test("Circle: no keywords after the first pick")
    func circleNoKeywordsAfterFirstPick() {
        // centerRadius: first click fixes the center → out of initial state.
        var cr = CircleTool(mode: .centerRadius)
        _ = cr.handle(.click(Vector(0, 0)), context: .empty)
        #expect(cr.keywordOptions.isEmpty)

        // twoPoint: first click fixes the first diameter endpoint.
        var tp = CircleTool(mode: .twoPoint)
        _ = tp.handle(.click(Vector(0, 0)), context: .empty)
        #expect(tp.keywordOptions.isEmpty)

        // threePoint: first click fixes the first point.
        var three = CircleTool(mode: .threePoint)
        _ = three.handle(.click(Vector(0, 0)), context: .empty)
        #expect(three.keywordOptions.isEmpty)
    }

    @Test("Circle: cancel re-arms the initial keywords")
    func circleCancelReArms() {
        var cr = CircleTool(mode: .centerRadius)
        _ = cr.handle(.click(Vector(0, 0)), context: .empty)
        #expect(cr.keywordOptions.isEmpty)
        _ = cr.handle(.cancel, context: .empty)        // back to settingCenter
        #expect(keywords(cr) == ["2P", "3P", "Diameter"])
    }

    // MARK: - ArcTool

    @Test("Arc: initial keywords exclude the active mode")
    func arcInitialKeywords() {
        // centerStartEnd → 3P, Tan.
        let cse = ArcTool(mode: .centerStartEnd)
        #expect(keywords(cse) == ["3P", "Tan"])

        // threePoint → CSE, Tan.
        let three = ArcTool(mode: .threePoint)
        #expect(keywords(three) == ["CSE", "Tan"])

        // tangential → CSE, 3P.
        let tan = ArcTool(mode: .tangential)
        #expect(keywords(tan) == ["CSE", "3P"])
    }

    @Test("Arc: no keywords after the first pick")
    func arcNoKeywordsAfterFirstPick() {
        var cse = ArcTool(mode: .centerStartEnd)
        _ = cse.handle(.click(Vector(0, 0)), context: .empty)   // fixes center
        #expect(cse.keywordOptions.isEmpty)

        var three = ArcTool(mode: .threePoint)
        _ = three.handle(.click(Vector(0, 0)), context: .empty) // fixes start
        #expect(three.keywordOptions.isEmpty)

        var tan = ArcTool(mode: .tangential)
        _ = tan.handle(.click(Vector(0, 0)), context: .empty)   // fixes start
        #expect(tan.keywordOptions.isEmpty)
    }

    // MARK: - EllipseTool

    @Test("Ellipse: initial keywords exclude the active mode")
    func ellipseInitialKeywords() {
        // axis → Foci, 4P, Inscribe, Arc.
        let axis = EllipseTool(mode: .axis)
        #expect(keywords(axis) == ["Foci", "4P", "Inscribe", "Arc"])

        // fociPoint → Axis, 4P, Inscribe, Arc.
        let foci = EllipseTool(mode: .fociPoint)
        #expect(keywords(foci) == ["Axis", "4P", "Inscribe", "Arc"])

        // fourPoint → Axis, Foci, Inscribe, Arc.
        let four = EllipseTool(mode: .fourPoint)
        #expect(keywords(four) == ["Axis", "Foci", "Inscribe", "Arc"])

        // inscribeQuad → Axis, Foci, 4P, Arc.
        let inscribe = EllipseTool(mode: .inscribeQuad)
        #expect(keywords(inscribe) == ["Axis", "Foci", "4P", "Arc"])

        // arc → Axis, Foci, 4P, Inscribe.
        let arc = EllipseTool(mode: .arc)
        #expect(keywords(arc) == ["Axis", "Foci", "4P", "Inscribe"])
    }

    @Test("Ellipse: no keywords after the first pick")
    func ellipseNoKeywordsAfterFirstPick() {
        // axis: first click fixes the center → settingMajor.
        var axis = EllipseTool(mode: .axis)
        _ = axis.handle(.click(Vector(0, 0)), context: .empty)
        #expect(axis.keywordOptions.isEmpty)

        // arc shares the axis spine: first click fixes the center.
        var arc = EllipseTool(mode: .arc)
        _ = arc.handle(.click(Vector(0, 0)), context: .empty)
        #expect(arc.keywordOptions.isEmpty)

        // fociPoint: first click fixes focus1 → settingFocus2.
        var foci = EllipseTool(mode: .fociPoint)
        _ = foci.handle(.click(Vector(0, 0)), context: .empty)
        #expect(foci.keywordOptions.isEmpty)

        // fourPoint: first click appends one collecting point.
        var four = EllipseTool(mode: .fourPoint)
        _ = four.handle(.click(Vector(0, 0)), context: .empty)
        #expect(four.keywordOptions.isEmpty)

        // inscribeQuad: first click appends one corner.
        var inscribe = EllipseTool(mode: .inscribeQuad)
        _ = inscribe.handle(.click(Vector(0, 0)), context: .empty)
        #expect(inscribe.keywordOptions.isEmpty)
    }

    @Test("Ellipse: a typed value also leaves the initial state")
    func ellipseValueLeavesInitial() {
        // `.value` (a typed coordinate) is a pick just like `.click`, so it must
        // also clear the construction-mode keywords.
        var axis = EllipseTool(mode: .axis)
        _ = axis.handle(.value(Vector(3, 4)), context: .empty)
        #expect(axis.keywordOptions.isEmpty)
    }
}
