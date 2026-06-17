//
//  InspectorEditTests.swift
//  CADEngineTests
//
//  Tests for the PURE inspector-edit transforms (`InspectorEdits`) that back the
//  macOS Inspector panel's property editors: editing a geometry/text field must
//  produce the right new `EntityKind`, a font/bold/italic pick must produce the
//  expected `TextStyle`, and the parameterized tools' option derivation must build
//  the right tool config. The SwiftUI views themselves are user-verified; this
//  covers the value math under them (which lives in the engine for exactly this
//  reason — testable without a GUI).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Geometry field edits → EntityKind

@Suite("Inspector geometry edits")
struct InspectorGeometryEditTests {

    @Test("editing a line endpoint produces a line kind with the new point, others kept")
    func lineEndpoints() {
        let kind = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))

        let movedStart = InspectorEdits.setLineStart(kind, Vector(2, 3))
        guard case .line(let s) = movedStart else { Issue.record("not a line"); return }
        #expect(s.start == Vector(2, 3))
        #expect(s.end == Vector(10, 0))      // end untouched

        let movedEnd = InspectorEdits.setLineEnd(kind, Vector(9, 9))
        guard case .line(let e) = movedEnd else { Issue.record("not a line"); return }
        #expect(e.start == Vector(0, 0))     // start untouched
        #expect(e.end == Vector(9, 9))
    }

    @Test("circle center + radius edits; radius clamps to non-negative")
    func circleEdits() {
        let kind = EntityKind.circle(CircleData(center: Vector(0, 0), radius: 5))

        let moved = InspectorEdits.setCircleCenter(kind, Vector(1, 2))
        guard case .circle(let c) = moved else { Issue.record("not a circle"); return }
        #expect(c.center == Vector(1, 2))
        #expect(c.radius == 5)

        let bigger = InspectorEdits.setCircleRadius(kind, 12)
        guard case .circle(let r) = bigger else { Issue.record("not a circle"); return }
        #expect(r.radius == 12)

        let clamped = InspectorEdits.setCircleRadius(kind, -3)
        guard case .circle(let cl) = clamped else { Issue.record("not a circle"); return }
        #expect(cl.radius == 0)              // negative clamped to 0
    }

    @Test("arc center / radius / angles edits keep the other fields")
    func arcEdits() {
        let kind = EntityKind.arc(ArcData(center: Vector(0, 0), radius: 4,
                                          startAngle: 0, endAngle: .pi))

        let s = InspectorEdits.setArcStartAngle(kind, .pi / 4)
        guard case .arc(let a) = s else { Issue.record("not an arc"); return }
        #expect(a.startAngle == .pi / 4)
        #expect(a.endAngle == .pi)           // end kept
        #expect(a.radius == 4)               // radius kept

        let e = InspectorEdits.setArcEndAngle(kind, .pi / 2)
        guard case .arc(let a2) = e else { Issue.record("not an arc"); return }
        #expect(a2.endAngle == .pi / 2)
        #expect(a2.startAngle == 0)          // start kept
    }

    @Test("an edit applied to the wrong kind is a no-op (returns the kind unchanged)")
    func wrongKindNoOp() {
        let kind = EntityKind.circle(CircleData(center: Vector(0, 0), radius: 5))
        // A line edit on a circle changes nothing.
        let unchanged = InspectorEdits.setLineStart(kind, Vector(99, 99))
        #expect(unchanged == kind)
    }
}

// MARK: - Text field edits → TextData

@Suite("Inspector text edits")
struct InspectorTextEditTests {

    private func sampleText() -> EntityKind {
        .text(TextData(position: Vector(1, 1), height: 2.5, text: "Hi"))
    }

    @Test("height / rotation / string edits produce the expected TextData")
    func textBasics() {
        let kind = sampleText()

        let h = InspectorEdits.setTextHeight(kind, 5)
        guard case .text(let td) = h else { Issue.record("not text"); return }
        #expect(td.height == 5)
        #expect(td.text == "Hi")             // string kept

        let r = InspectorEdits.setTextRotation(kind, .pi / 6)
        guard case .text(let td2) = r else { Issue.record("not text"); return }
        #expect(abs(td2.rotation - .pi / 6) < 1e-12)

        let s = InspectorEdits.setTextString(kind, "Hello")
        guard case .text(let td3) = s else { Issue.record("not text"); return }
        #expect(td3.text == "Hello")
    }

    @Test("height clamps to a positive minimum (never zero)")
    func textHeightClamp() {
        let h = InspectorEdits.setTextHeight(sampleText(), 0)
        guard case .text(let td) = h else { Issue.record("not text"); return }
        #expect(td.height == InspectorEdits.minTextHeight)
    }

    @Test("justification, width factor, oblique, and generation flags round-trip")
    func textStyleFields() {
        let kind = sampleText()

        let j = InspectorEdits.setTextHAlign(kind, .center)
        guard case .text(let td) = j else { Issue.record("not text"); return }
        #expect(td.hAlign == .center)

        let w = InspectorEdits.setTextWidthFactor(kind, 1.5)
        guard case .text(let td2) = w else { Issue.record("not text"); return }
        #expect(td2.widthFactor == 1.5)

        let o = InspectorEdits.setTextOblique(kind, .pi / 8)
        guard case .text(let td3) = o else { Issue.record("not text"); return }
        #expect(abs(td3.obliqueAngle - .pi / 8) < 1e-12)

        let back = InspectorEdits.setTextBackward(kind, true)
        guard case .text(let td4) = back else { Issue.record("not text"); return }
        #expect(td4.generation.contains(.backward))

        let up = InspectorEdits.setTextUpsideDown(back, true)
        guard case .text(let td5) = up else { Issue.record("not text"); return }
        #expect(td5.generation.contains(.upsideDown))
        #expect(td5.generation.contains(.backward))   // both set
    }

    @Test("style-name pointer edit changes only styleName")
    func styleNamePointer() {
        let kind = sampleText()
        let p = InspectorEdits.setTextStyleName(kind, "Helvetica Neue Bold")
        guard case .text(let td) = p else { Issue.record("not text"); return }
        #expect(td.styleName == "Helvetica Neue Bold")
        #expect(td.text == "Hi")             // body kept
    }
}

// MARK: - MTEXT field edits

@Suite("Inspector mtext edits")
struct InspectorMTextEditTests {

    private func sampleMText() -> EntityKind {
        .mtext(MTextData(
            position: Vector(0, 0), height: 3, rectWidth: 50,
            paragraphs: [MTextParagraph(inlines: [.run(TextRun(text: "line one"))])]
        ))
    }

    @Test("geometry + attachment edits keep the run tree")
    func mtextGeometry() {
        let kind = sampleMText()

        let w = InspectorEdits.setMTextRectWidth(kind, 80)
        guard case .mtext(let d) = w else { Issue.record("not mtext"); return }
        #expect(d.rectWidth == 80)
        #expect(d.paragraphs.count == 1)     // body kept

        let a = InspectorEdits.setMTextAttachment(kind, .middleCenter)
        guard case .mtext(let d2) = a else { Issue.record("not mtext"); return }
        #expect(d2.attachment == .middleCenter)
    }

    @Test("plain-text edit replaces paragraphs with single runs split on newlines and clears rawCode")
    func mtextPlainText() {
        var kind = sampleMText()
        if case .mtext(var d) = kind { d.rawCode = "\\fArial;old"; kind = .mtext(d) }

        let edited = InspectorEdits.setMTextPlainText(kind, "alpha\nbeta")
        guard case .mtext(let d) = edited else { Issue.record("not mtext"); return }
        #expect(d.paragraphs.count == 2)
        #expect(d.rawCode == nil)            // stale verbatim code dropped
        // The round-trip reader returns the joined text.
        #expect(InspectorEdits.mtextPlainText(edited) == "alpha\nbeta")
    }
}

// MARK: - Dimension text-edit field edits → DimData

@Suite("Inspector dimension text edits")
struct InspectorDimTextEditTests {

    /// A linear dimension with no text overrides set (the resolve-derived defaults).
    private func sampleDim() -> EntityKind {
        .dimension(DimData(
            kind: .linear(extension1: Vector(0, 0), extension2: Vector(10, 0), angle: 0),
            definitionPoint: Vector(5, 3)))
    }

    @Test("setDimTextMiddle moves the text middle point; nil clears it; other fields kept")
    func textMiddle() {
        let kind = sampleDim()
        guard case .dimension(let base) = kind else { Issue.record("not a dimension"); return }
        #expect(base.textMiddle == nil)               // baseline: no override

        let moved = InspectorEdits.setDimTextMiddle(kind, Vector(7, 4))
        guard case .dimension(let d) = moved else { Issue.record("not a dimension"); return }
        #expect(d.textMiddle == Vector(7, 4))
        #expect(d.definitionPoint == base.definitionPoint)  // other fields kept
        #expect(d.textRotation == base.textRotation)
        #expect(d.obliqueAngle == base.obliqueAngle)

        // Clearing the override.
        let cleared = InspectorEdits.setDimTextMiddle(moved, nil)
        guard case .dimension(let d2) = cleared else { Issue.record("not a dimension"); return }
        #expect(d2.textMiddle == nil)
    }

    @Test("setDimTextRotation sets the explicit text rotation; nil clears it")
    func textRotation() {
        let kind = sampleDim()
        guard case .dimension(let base) = kind else { Issue.record("not a dimension"); return }
        #expect(base.textRotation == nil)             // baseline: derived angle

        let rotated = InspectorEdits.setDimTextRotation(kind, .pi / 4)
        guard case .dimension(let d) = rotated else { Issue.record("not a dimension"); return }
        #expect(d.textRotation != nil)
        #expect(abs((d.textRotation ?? 0) - .pi / 4) < 1e-12)
        #expect(d.textMiddle == base.textMiddle)      // other fields kept

        let cleared = InspectorEdits.setDimTextRotation(rotated, nil)
        guard case .dimension(let d2) = cleared else { Issue.record("not a dimension"); return }
        #expect(d2.textRotation == nil)
    }

    @Test("setDimOblique sets the extension-line oblique angle; other fields kept")
    func oblique() {
        let kind = sampleDim()
        guard case .dimension(let base) = kind else { Issue.record("not a dimension"); return }
        #expect(base.obliqueAngle == 0)               // baseline: perpendicular

        let slanted = InspectorEdits.setDimOblique(kind, .pi / 6)
        guard case .dimension(let d) = slanted else { Issue.record("not a dimension"); return }
        #expect(abs(d.obliqueAngle - .pi / 6) < 1e-12)
        #expect(d.textMiddle == base.textMiddle)      // other fields kept
        #expect(d.textRotation == base.textRotation)
    }

    @Test("no-op when the value is unchanged — re-setting the same value yields an equal kind")
    func noOpWhenUnchanged() {
        // textMiddle: setting the same point back produces an equal kind.
        let withMid = InspectorEdits.setDimTextMiddle(sampleDim(), Vector(7, 4))
        #expect(InspectorEdits.setDimTextMiddle(withMid, Vector(7, 4)) == withMid)

        // textRotation: re-setting the same rotation is a no-op.
        let withRot = InspectorEdits.setDimTextRotation(sampleDim(), .pi / 4)
        #expect(InspectorEdits.setDimTextRotation(withRot, .pi / 4) == withRot)

        // oblique: re-setting the same angle is a no-op.
        let withObl = InspectorEdits.setDimOblique(sampleDim(), .pi / 6)
        #expect(InspectorEdits.setDimOblique(withObl, .pi / 6) == withObl)
    }

    @Test("dimension text edits applied to a non-dimension kind are no-ops")
    func nonDimensionUnaffected() {
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(10, 0)))
        #expect(InspectorEdits.setDimTextMiddle(line, Vector(7, 4)) == line)
        #expect(InspectorEdits.setDimTextRotation(line, .pi / 4) == line)
        #expect(InspectorEdits.setDimOblique(line, .pi / 6) == line)
    }

    @Test("each edit is undoable/redoable: the source kind is unmutated, and re-applying reproduces the edit")
    func undoRedoSnapshots() {
        // The app's undo funnel snapshots the prior EntityKind and applies the new
        // one via `.replace`; these pure builders never mutate their input, so the
        // original value IS the undo snapshot, and re-applying the builder IS redo.
        let original = sampleDim()

        let edited = InspectorEdits.setDimOblique(original, .pi / 3)
        #expect(edited != original)                   // a real change

        // Undo: the original snapshot is intact (the builder did not mutate it).
        guard case .dimension(let o) = original else { Issue.record("not a dimension"); return }
        #expect(o.obliqueAngle == 0)

        // Redo: re-applying the same edit to the original reproduces the edited value.
        let redone = InspectorEdits.setDimOblique(original, .pi / 3)
        #expect(redone == edited)

        // And the same holds for the two override fields.
        let mid = InspectorEdits.setDimTextMiddle(original, Vector(2, 9))
        #expect(InspectorEdits.setDimTextMiddle(original, Vector(2, 9)) == mid)
        let rot = InspectorEdits.setDimTextRotation(original, .pi / 5)
        #expect(InspectorEdits.setDimTextRotation(original, .pi / 5) == rot)
    }
}

// MARK: - Font / style derivation (the font-system payoff)

@Suite("Inspector font/style derivation")
struct InspectorStyleDerivationTests {

    @Test("native family + bold/italic yields a style with a stable, content-derived name")
    func nativeStyle() {
        let plain = InspectorEdits.derivedTextStyle(
            font: .native(family: "Helvetica Neue"), bold: false, italic: false)
        #expect(plain.name == "Helvetica Neue")
        #expect(plain.bold == false)
        #expect(plain.italic == false)
        if case .native(let fam) = plain.primaryFont { #expect(fam == "Helvetica Neue") }
        else { Issue.record("primary font not native") }

        let boldItalic = InspectorEdits.derivedTextStyle(
            font: .native(family: "Helvetica Neue"), bold: true, italic: true)
        #expect(boldItalic.name == "Helvetica Neue Bold Italic")
        #expect(boldItalic.bold && boldItalic.italic)
    }

    @Test("stroke font derives a Stroke-prefixed name")
    func strokeStyle() {
        let s = InspectorEdits.derivedTextStyle(font: .stroke(lff: "standard"), bold: false, italic: false)
        #expect(s.name == "Stroke:standard")
        if case .stroke(let lff) = s.primaryFont { #expect(lff == "standard") }
        else { Issue.record("primary font not stroke") }
    }

    @Test("the same pick reuses one table slot (deterministic name → upsert by name)")
    func deterministicNameReuse() {
        var table = TextStyleTable()
        let a = InspectorEdits.derivedTextStyle(font: .native(family: "Menlo"), bold: true, italic: false)
        let b = InspectorEdits.derivedTextStyle(font: .native(family: "Menlo"), bold: true, italic: false)
        #expect(a.name == b.name)
        table.upsert(a)
        let countAfterFirst = table.styles.count
        table.upsert(b)
        #expect(table.styles.count == countAfterFirst)   // no second slot
        // And the resolved style carries bold so TextShaper renders the heavy face.
        #expect(table.style(named: a.name)?.bold == true)
    }
}

// MARK: - Tool config derivation (parameterized tools' options)

@Suite("Inspector tool config")
struct InspectorToolConfigTests {

    @Test("rectangular array config clamps rows/cols to >= 1 and carries spacing")
    func rectangular() {
        let cfg = InspectorEdits.arrayConfig(
            polar: false, rows: 0, cols: -2, spacingX: 5, spacingY: 7,
            count: 6, totalAngle: .pi, rotateItems: true)
        guard case .rectangular(let rows, let cols, let spacing) = cfg else {
            Issue.record("not rectangular"); return
        }
        #expect(rows == 1)                   // clamped
        #expect(cols == 1)                   // clamped
        #expect(spacing == Vector(5, 7))
    }

    @Test("polar array config clamps count to >= 2 and leaves center nil for canvas pick")
    func polar() {
        let cfg = InspectorEdits.arrayConfig(
            polar: true, rows: 2, cols: 3, spacingX: 1, spacingY: 1,
            count: 1, totalAngle: 2 * .pi, rotateItems: false)
        guard case .polar(let count, let center, let total, let rotate) = cfg else {
            Issue.record("not polar"); return
        }
        #expect(count == 2)                  // clamped up
        #expect(center == nil)               // first canvas click supplies it
        #expect(abs(total - 2 * .pi) < 1e-12)
        #expect(rotate == false)
    }
}

// MARK: - Snap-mode set operations (Inspector toggles)

@Suite("Inspector snap modes")
struct InspectorSnapModeTests {

    @Test("the engine's interactive default omits grid but includes the geometry snaps + free")
    func defaultModes() {
        // Mirror the CanvasModel interactive default to document the contract here
        // (CanvasModel lives in the app target; this asserts the SnapMode algebra).
        let modes: SnapMode = [.endpoint, .center, .middle, .intersection, .onEntity, .free]
        #expect(modes.contains(.endpoint))
        #expect(modes.contains(.free))
        #expect(!modes.contains(.grid))      // grid OFF by default (see CanvasModel note)
    }

    @Test("toggling a snap bit on then off restores the set")
    func toggleRoundTrip() {
        var modes: SnapMode = [.endpoint, .free]
        modes.insert(.grid)
        #expect(modes.contains(.grid))
        modes.remove(.grid)
        #expect(!modes.contains(.grid))
        #expect(modes == [.endpoint, .free])
    }
}
