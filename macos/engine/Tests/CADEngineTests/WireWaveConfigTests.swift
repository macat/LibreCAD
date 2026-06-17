//
//  WireWaveConfigTests.swift
//  CADEngineTests
//
//  Wire-wave-4 (W4) surfacing. The W4 wire-wave makes the parity-program tools/modes
//  that were built UNWIRED actually reachable from the UI:
//
//    • Offset    → mode {Through point / Distance} + bothSides + eraseSource flags.
//    • Rotate    → "Copy (keep original)" (`RotateTool.keepOriginal`).
//    • Mirror    → "Copy (keep original)" (`MirrorTool.keepOriginal`).
//    • Circle    → the new construction modes {TTR, TTT, From Arc} alongside the
//                  existing {Center+Radius, 2-Point, 3-Point}.
//    • Line construction → the construction METHOD picker (perpendicular-foot /
//                  parallel-through / bisector / tangent-1 / tangent-2 / orth-tangent).
//    • Revision Cloud / Wipeout → activatable draw/markup tools (normal makeTool path).
//
//  Each control works by SETTING the matching `CanvasModel` config FIRST, then
//  ACTIVATING the tool, so `applyToolConfig` mints/re-applies the live tool carrying
//  the config (the same Wave-3B/3F/wire-wave-3 plumbing the options bar / flyouts use).
//  These tests guard THAT model→tool contract over the `_SharedCanvasModel.swift`
//  symlink (the app module's `CanvasModel.swift`, compiled into this test target via
//  the `_Shared*` convention — the suite is `@MainActor`).
//
//  No SwiftUI body / NSMenu / NSOpenPanel / modal is rendered (the modal-hang trap):
//  only the pure model wiring is exercised, mirroring `WireWave3CFlyoutModeTests`.
//
//  Uniquely namespaced (`@Suite("wire-wave-4 ...")`) so it does not collide with the
//  other suites in the shared test target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("wire-wave-4 (Offset / Rotate / Mirror / Circle modes / Line construction → minted tool)")
struct WireWaveConfigTests {

    private func model() -> CanvasModel {
        CanvasModel(drawing: CADDrawing())
    }

    // MARK: - Offset ▸ mode {Through / Distance} + bothSides / eraseSource

    @Test("Offset: default config is through-point, single copy, copy-only (back-compatible)")
    func offsetDefaults() throws {
        let m = model()
        m.activateTool(.offset)
        let tool = try #require(m.tool as? OffsetTool, "activating .offset must mint an OffsetTool")
        #expect(tool.mode == .through)
        #expect(tool.bothSides == false)
        #expect(tool.eraseSource == false)
    }

    @Test("Offset: the Distance mode + fixed distance flow onto the minted tool")
    func offsetDistanceModeFlowsToTool() throws {
        let m = model()
        m.offsetModeIndex = 1                // .distance
        m.offsetDistance = 7.5
        m.activateTool(.offset)
        let tool = try #require(m.tool as? OffsetTool)
        #expect(tool.mode == .distance, "the Distance mode index must reach the tool")
        #expect(tool.distance == 7.5)
    }

    @Test("Offset: the both-sides + erase-source flags flow onto the minted tool")
    func offsetFlagsFlowToTool() throws {
        let m = model()
        m.offsetBothSides = true
        m.offsetEraseSource = true
        m.activateTool(.offset)
        let tool = try #require(m.tool as? OffsetTool)
        #expect(tool.bothSides == true, "offsetBothSides must reach the live tool")
        #expect(tool.eraseSource == true, "offsetEraseSource must reach the live tool")

        // Flipping the flags back off + re-applying re-pushes them (the options bar path).
        m.offsetBothSides = false
        m.offsetEraseSource = false
        m.reapplyActiveToolConfig()
        let off = try #require(m.tool as? OffsetTool)
        #expect(off.bothSides == false)
        #expect(off.eraseSource == false)
    }

    @Test("Offset: offsetModeValue maps the index → OffsetMode")
    func offsetModeValueMapping() {
        let m = model()
        m.offsetModeIndex = 0
        #expect(m.offsetModeValue == .through)
        m.offsetModeIndex = 1
        #expect(m.offsetModeValue == .distance)
    }

    // MARK: - Rotate ▸ Copy (keep original)

    @Test("Rotate: default is rotate-in-place (keepOriginal == false)")
    func rotateDefaultKeepsNothing() throws {
        let m = model()
        m.activateTool(.rotate)
        let tool = try #require(m.tool as? RotateTool, "activating .rotate must mint a RotateTool")
        #expect(tool.keepOriginal == false)
    }

    @Test("Rotate: the Copy (keep original) toggle flows onto the minted tool")
    func rotateKeepOriginalFlowsToTool() throws {
        let m = model()
        m.rotateKeepOriginal = true
        m.activateTool(.rotate)
        #expect((m.tool as? RotateTool)?.keepOriginal == true,
                "rotateKeepOriginal must reach the live RotateTool")

        // The options bar can flip it back mid-run via reapply.
        m.rotateKeepOriginal = false
        m.reapplyActiveToolConfig()
        #expect((m.tool as? RotateTool)?.keepOriginal == false)
    }

    // MARK: - Mirror ▸ Copy (keep original)

    @Test("Mirror: default is mirror-COPY (keepOriginal == true) — a plain Mirror duplicates")
    func mirrorDefaultKeepsOriginal() throws {
        let m = model()
        m.activateTool(.mirror)
        let tool = try #require(m.tool as? MirrorTool, "activating .mirror must mint a MirrorTool")
        // AutoCAD MIRROR default keeps the source (erase source? <No>) → the reflection
        // is a DUPLICATE, not an in-place replace. The user reported a plain Mirror not
        // duplicating; the app default is now keep-original.
        #expect(tool.keepOriginal == true)
    }

    @Test("Mirror: toggling Copy OFF flows mirror-in-place onto the minted tool")
    func mirrorKeepOriginalToggleFlowsToTool() throws {
        let m = model()
        // Default is keep-original (duplicate); turning the toggle OFF must reach the tool.
        m.mirrorKeepOriginal = false
        m.activateTool(.mirror)
        #expect((m.tool as? MirrorTool)?.keepOriginal == false,
                "mirrorKeepOriginal=false (in-place) must reach the live MirrorTool")
        // And flipping it back ON mid-run via the options-bar reapply path.
        m.mirrorKeepOriginal = true
        m.reapplyActiveToolConfig()
        #expect((m.tool as? MirrorTool)?.keepOriginal == true,
                "re-enabling Copy must reach the live MirrorTool")
    }

    // MARK: - Circle ▸ the new construction modes {TTR / TTT / From Arc}

    @Test("Circle: TTR (tan-tan-radius) construction mode flows to the minted tool")
    func circleTTRModeFlowsToTool() throws {
        let m = model()
        m.circleConstructionMode = .tanTanRadius
        m.circleFixedSize = 25                 // TTR requires a positive radius
        m.activateTool(.circle)
        let tool = try #require(m.tool as? CircleTool, "activating .circle must mint a CircleTool")
        #expect(tool.mode == .tanTanRadius, "the TTR construction mode must reach the tool")
        #expect(tool.fixedSize == 25, "the TTR radius (circleFixedSize) must reach the tool")
    }

    @Test("Circle: TTT (tan-tan-tan) construction mode flows to the minted tool")
    func circleTTTModeFlowsToTool() throws {
        let m = model()
        m.circleConstructionMode = .tanTanTan
        m.activateTool(.circle)
        #expect((m.tool as? CircleTool)?.mode == .tanTanTan)
    }

    @Test("Circle: From-Arc construction mode flows to the minted tool")
    func circleFromArcModeFlowsToTool() throws {
        let m = model()
        m.circleConstructionMode = .fromArc
        m.activateTool(.circle)
        #expect((m.tool as? CircleTool)?.mode == .fromArc)

        // The existing modes still re-mint correctly after a W4 mode (no regression).
        m.circleConstructionMode = .centerRadius
        m.activateTool(.circle)
        #expect((m.tool as? CircleTool)?.mode == .centerRadius)
    }

    // MARK: - Line construction ▸ method picker

    @Test("Line construction: default method is .perpendicularFoot")
    func lineConstructionDefaultMode() throws {
        let m = model()
        m.activateTool(.lineConstruction)
        let tool = try #require(m.tool as? LineConstructionTool,
                                "activating .lineConstruction must mint a LineConstructionTool")
        #expect(tool.mode == .perpendicularFoot)
    }

    @Test("Line construction: each method flows onto the minted tool")
    func lineConstructionModeFlowsToTool() throws {
        let m = model()
        for method in LineConstructionTool.Mode.allCases {
            m.lineConstructionMode = method
            m.activateTool(.lineConstruction)
            #expect((m.tool as? LineConstructionTool)?.mode == method,
                    "lineConstructionMode \(method) must reach the live tool")
        }
    }

    @Test("Line construction: reapply re-mints in the new method mid-run")
    func lineConstructionReapplyReMints() throws {
        let m = model()
        m.lineConstructionMode = .parallelThrough
        m.activateTool(.lineConstruction)
        #expect((m.tool as? LineConstructionTool)?.mode == .parallelThrough)

        m.lineConstructionMode = .angleBisector
        m.reapplyActiveToolConfig()
        #expect((m.tool as? LineConstructionTool)?.mode == .angleBisector)
    }

    // MARK: - Revision Cloud / Wipeout ▸ activatable draw/markup tools

    @Test("Revision Cloud: .revcloud activates a RevisionCloudTool")
    func revcloudActivates() throws {
        let m = model()
        m.activateTool(.revcloud)
        #expect(m.activeToolKind == .revcloud)
        #expect(m.tool as? RevisionCloudTool != nil,
                "activating .revcloud must mint a RevisionCloudTool")
    }

    @Test("Wipeout: .wipeout activates a WipeoutTool")
    func wipeoutActivates() throws {
        let m = model()
        m.activateTool(.wipeout)
        #expect(m.activeToolKind == .wipeout)
        #expect(m.tool as? WipeoutTool != nil,
                "activating .wipeout must mint a WipeoutTool")
    }
}
