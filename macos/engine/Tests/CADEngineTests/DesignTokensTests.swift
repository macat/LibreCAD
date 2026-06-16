//
//  DesignTokensTests.swift
//  CADEngineTests
//
//  Pins the design-token CONTRACT (`DS`, in DesignTokens.swift) so a later careless
//  edit that drifts a spacing step, radius role, swatch size, or field-width tier is
//  caught here. Wave 1 of the UI redesign (macos/docs/ui-redesign-plan.md §1) declares
//  the token system; these tests make the declared values load-bearing.
//
//  `DS` lives in the app module (it imports SwiftUI for CGFloat/Color), so it is reached
//  through the established `_SharedDesignTokens.swift` SYMLINK (the test target depends
//  only on CADEngine). Asserts numeric metrics only — no GUI, no modal, no rendering.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import SwiftUI

@Suite("design tokens (DS) contract")
struct DesignTokensTests {

    // MARK: Spacing scale — the ONLY allowed steps are {2,4,6,8,12,16,24}.

    @Test("spacing scale is the exact 4pt-base ramp")
    func spacingScale() {
        #expect(DS.Space.xxs == 2)
        #expect(DS.Space.xs  == 4)
        #expect(DS.Space.sm  == 6)
        #expect(DS.Space.md  == 8)
        #expect(DS.Space.lg  == 12)
        #expect(DS.Space.xl  == 16)
        #expect(DS.Space.xxl == 24)
    }

    @Test("spacing values are sorted, unique, and contain no retired steps (5/7/9/10/14)")
    func spacingNoRetiredSteps() {
        let scale: [CGFloat] = [DS.Space.xxs, DS.Space.xs, DS.Space.sm,
                                DS.Space.md, DS.Space.lg, DS.Space.xl, DS.Space.xxl]
        #expect(scale == scale.sorted())
        #expect(Set(scale).count == scale.count)
        for retired: CGFloat in [5, 7, 9, 10, 14] {
            #expect(!scale.contains(retired))
        }
    }

    // MARK: Corner radius — three roles {6,10,14} + the swatch exception (3).

    @Test("radius roles are 6 / 10 / 14 with the swatch exception at 3")
    func radiusRoles() {
        #expect(DS.Radius.selection == 6)
        #expect(DS.Radius.card      == 10)
        #expect(DS.Radius.modal     == 14)
        #expect(DS.Radius.swatch    == 3)   // ✅ resolved 3-vs-4
    }

    // MARK: Control size — the swatch chip is 16x16.

    @Test("swatch control size is 16pt")
    func swatchSize() {
        #expect(DS.Size.swatch == 16)
    }

    @Test("bar primitive metrics are stable (padV 6 / padH 12 / divider 16)")
    func barMetrics() {
        #expect(DS.Size.barPadV   == 6)
        #expect(DS.Size.barPadH   == 12)
        #expect(DS.Size.barDivider == 16)
    }

    // MARK: Field-width tiers — {56,72,96,130}; xy is the paired-field exception.

    @Test("field-width tiers are xy56 / narrow72 / std96 / wide130")
    func fieldTiers() {
        #expect(DS.Field.xy     == 56)
        #expect(DS.Field.narrow == 72)
        #expect(DS.Field.std    == 96)
        #expect(DS.Field.wide   == 130)
    }

    @Test("field tiers strictly increase (no overlap / re-ordering)")
    func fieldTiersOrdered() {
        let tiers: [CGFloat] = [DS.Field.xy, DS.Field.narrow, DS.Field.std, DS.Field.wide]
        #expect(tiers == tiers.sorted())
        #expect(Set(tiers).count == tiers.count)
    }
}
