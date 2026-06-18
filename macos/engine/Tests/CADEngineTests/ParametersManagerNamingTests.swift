//
//  ParametersManagerNamingTests.swift
//  CADEngineTests
//
//  Headless tests for the PARAMETERS MANAGER's pure naming/validation logic
//  (`ParameterNaming`) and its constraint-kind label helper. These exercise ONLY the
//  side-effect-free value logic reached via the `_SharedParametersManagerView.swift`
//  symlink — they NEVER construct or present `ParametersManagerView` (presenting a
//  SwiftUI sheet from a headless test is the modal trap that hangs the suite). Mirrors
//  the `DimStyleNaming` tests.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import CADEngine
@testable import LibreCADmacOS

@Suite("Parameters Manager — naming validation (pure)")
struct ParametersManagerNamingTests {

    // MARK: - isValidIdentifier

    @Test("a plain identifier is valid")
    func plainIdentifierValid() {
        #expect(ParameterNaming.isValidIdentifier("width"))
        #expect(ParameterNaming.isValidIdentifier("a"))
        #expect(ParameterNaming.isValidIdentifier("Length2"))
        #expect(ParameterNaming.isValidIdentifier("_hidden"))
        #expect(ParameterNaming.isValidIdentifier("w_2"))
    }

    @Test("a leading digit is rejected")
    func leadingDigitRejected() {
        #expect(!ParameterNaming.isValidIdentifier("2width"))
        #expect(!ParameterNaming.isValidIdentifier("3"))
    }

    @Test("a name with a space is rejected")
    func spaceRejected() {
        #expect(!ParameterNaming.isValidIdentifier("my width"))
        #expect(!ParameterNaming.isValidIdentifier("a b"))
    }

    @Test("an operator / punctuation char is rejected")
    func operatorRejected() {
        #expect(!ParameterNaming.isValidIdentifier("a*2"))
        #expect(!ParameterNaming.isValidIdentifier("w-1"))
        #expect(!ParameterNaming.isValidIdentifier("a.b"))
    }

    @Test("empty / whitespace-only is not a valid identifier")
    func emptyNotValid() {
        #expect(!ParameterNaming.isValidIdentifier(""))
        #expect(!ParameterNaming.isValidIdentifier("   "))
    }

    @Test("surrounding whitespace is trimmed before validating")
    func trimsBeforeValidating() {
        #expect(ParameterNaming.isValidIdentifier("  width  "))
    }

    // MARK: - classify (the add-row decision)

    @Test("a fresh valid name classifies .ok and is addable")
    func freshNameOK() {
        let v = ParameterNaming.classify(name: "height", existingNames: ["width"])
        #expect(v == .ok)
        #expect(v.isAddable)
        #expect(v.message == nil)
    }

    @Test("a blank name classifies .empty and is not addable")
    func blankNotAddable() {
        let v = ParameterNaming.classify(name: "   ", existingNames: [])
        #expect(v == .empty)
        #expect(!v.isAddable)
        #expect(v.message != nil)
    }

    @Test("an invalid identifier classifies .invalid and is not addable")
    func invalidNotAddable() {
        #expect(ParameterNaming.classify(name: "2x", existingNames: []) == .invalid)
        #expect(ParameterNaming.classify(name: "my width", existingNames: []) == .invalid)
        #expect(!ParameterNaming.classify(name: "a*b", existingNames: []).isAddable)
    }

    @Test("a duplicate name classifies .duplicate (case-insensitive) and is not addable")
    func duplicateNotAddable() {
        let existing = ["Width", "height"]
        let exact = ParameterNaming.classify(name: "height", existingNames: existing)
        #expect(exact == .duplicate)
        #expect(!exact.isAddable)
        // Case-insensitive: "WIDTH" collides with "Width".
        let folded = ParameterNaming.classify(name: "WIDTH", existingNames: existing)
        #expect(folded == .duplicate)
        // Whitespace around an existing name still collides.
        let padded = ParameterNaming.classify(name: "  width ", existingNames: ["width"])
        #expect(padded == .duplicate)
    }

    @Test("validation precedence: invalid is reported before duplicate")
    func invalidBeforeDuplicate() {
        // "1width" is BOTH not a valid identifier; even if a folded form matched, the
        // invalid check fires first (it can never be a valid existing name anyway).
        #expect(ParameterNaming.classify(name: "1width", existingNames: ["1width"]) == .invalid)
    }

    @Test("each validation case carries a message except .ok")
    func messages() {
        #expect(ParameterNaming.Validation.empty.message != nil)
        #expect(ParameterNaming.Validation.invalid.message != nil)
        #expect(ParameterNaming.Validation.duplicate.message != nil)
        #expect(ParameterNaming.Validation.ok.message == nil)
    }

    // MARK: - constraintLabel (readable kind names for the constraint-param list)

    @Test("dimensional constraint kinds map to readable labels")
    func dimensionalLabels() {
        #expect(ParameterNaming.constraintLabel(for: .dimensional(.distance)) == "Distance")
        #expect(ParameterNaming.constraintLabel(for: .dimensional(.radius)) == "Radius")
        #expect(ParameterNaming.constraintLabel(for: .dimensional(.diameter)) == "Diameter")
        #expect(ParameterNaming.constraintLabel(for: .dimensional(.angle)) == "Angle")
        #expect(ParameterNaming.constraintLabel(for: .dimensional(.horizontalDistance)) == "Horizontal distance")
        #expect(ParameterNaming.constraintLabel(for: .dimensional(.verticalDistance)) == "Vertical distance")
    }

    @Test("a geometric kind gets a defensive label (never shown in the param list)")
    func geometricLabel() {
        #expect(ParameterNaming.constraintLabel(for: .geometric(.coincident)) == "Geometric")
    }
}
