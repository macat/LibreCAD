//
//  FieldInsertEditTests.swift
//  CADEngineTests
//
//  Wave 3 — the FIELDS inspector INSERT path. Tests the pure, undoable engine setter
//  (`InspectorEdits.appendField(to:token:)`) that the Inspector's "Insert Field"
//  affordance calls to embed an auto-updating field into a TEXT/MTEXT entity:
//    - appending to TEXT adds a `FieldRun` + the matching zero-width placeholder
//      marker to the string (the prior text is kept)
//    - appending to MTEXT adds a `FieldRun` + a trailing placeholder RUN on the last
//      paragraph (and creates a paragraph when the body is empty); `rawCode` is cleared
//    - the setter is a VALUE transform — the original `EntityKind` is untouched, so the
//      app's copy-on-write undo restores it (engine-level undoability)
//    - the field-bearing entity round-trips losslessly through Codable
//    - placeholder index allocation is monotonic (a second insert never collides)
//    - appending to a NON-text/mtext kind is a safe no-op
//    - end-to-end: the appended placeholder resolves to the live value once a
//      `FieldContext` is supplied (proving the marker ↔ FieldRun index line up)
//
//  The SwiftUI menu itself is user-verified; this covers the value math under it
//  (which lives in the engine for exactly this reason — testable without a GUI).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Fixtures

private enum FieldInsertFixtures {
    /// A fixed reference date (2026-06-17 14:30 UTC), so a resolved `.date` field is
    /// deterministic regardless of the test machine's clock.
    static let refDate: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 17; c.hour = 14; c.minute = 30; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    static func context(file: String = "/Users/me/drawings/Plan.dxf") -> FieldContext {
        FieldContext(date: refDate, layoutName: "Layout1", fileName: file)
    }

    static func text(_ s: String, fields: [FieldRun]? = nil) -> EntityKind {
        .text(TextData(position: Vector(0, 0), height: 2.5, text: s, fields: fields))
    }

    static func mtext(_ paragraphs: [MTextParagraph], fields: [FieldRun]? = nil) -> EntityKind {
        .mtext(MTextData(position: Vector(0, 0), height: 2.5,
                         paragraphs: paragraphs, rawCode: "VERBATIM", fields: fields))
    }

    static func run(_ s: String) -> MTextParagraph { MTextParagraph(inlines: [.run(TextRun(text: s))]) }

    /// Round-trips an `EntityKind` through JSON, asserting equality.
    static func codableRoundTrip(_ kind: EntityKind) throws -> EntityKind {
        let data = try JSONEncoder().encode(kind)
        return try JSONDecoder().decode(EntityKind.self, from: data)
    }
}

// MARK: - TEXT insert

@Suite("Field insert — TEXT")
struct FieldInsertTextEditTests {

    @Test("appending a field to TEXT adds a FieldRun + its placeholder marker, keeping prior text")
    func appendToText() {
        let kind = FieldInsertFixtures.text("Rev ")

        let out = InspectorEdits.appendField(to: kind, token: .date())
        guard case .text(let d) = out else { Issue.record("not text"); return }

        // One field at index 0.
        #expect(d.fields?.count == 1)
        #expect(d.fields?.first?.index == 0)
        #expect(d.fields?.first?.token == .date())

        // The prior text is kept and the placeholder marker for slot 0 is appended.
        #expect(d.text == "Rev " + FieldEvaluator.placeholder(for: 0))
        #expect(d.text.hasPrefix("Rev "))
    }

    @Test("appendField does NOT mutate the original kind (value transform → undoable)")
    func appendIsValueTransform() {
        let original = FieldInsertFixtures.text("Hello")
        let out = InspectorEdits.appendField(to: original, token: .layoutName())

        // The original is an untouched value snapshot — what copy-on-write undo restores.
        guard case .text(let o) = original else { Issue.record("not text"); return }
        #expect(o.text == "Hello")
        #expect(o.fields == nil)
        #expect(out != original)   // the new kind differs (a real edit happened)
    }

    @Test("a second insert allocates the next index and never collides")
    func monotonicIndices() {
        let one = InspectorEdits.appendField(to: FieldInsertFixtures.text(""), token: .date())
        let two = InspectorEdits.appendField(to: one, token: .fileName())
        guard case .text(let d) = two else { Issue.record("not text"); return }

        #expect(d.fields?.map(\.index) == [0, 1])
        // Both placeholders are present and distinct in the string.
        #expect(d.text.contains(FieldEvaluator.placeholder(for: 0)))
        #expect(d.text.contains(FieldEvaluator.placeholder(for: 1)))
    }

    @Test("a field-bearing TEXT round-trips losslessly through Codable")
    func textCodableRoundTrip() throws {
        let inserted = InspectorEdits.appendField(to: FieldInsertFixtures.text("Date: "), token: .date())
        let restored = try FieldInsertFixtures.codableRoundTrip(inserted)
        #expect(restored == inserted)
    }

    @Test("end-to-end: the appended placeholder resolves to the live date value")
    func resolvesWithContext() {
        let inserted = InspectorEdits.appendField(
            to: FieldInsertFixtures.text("Today is "),
            token: .date(format: "yyyy-MM-dd"))
        guard case .text(let d) = inserted else { Issue.record("not text"); return }

        let ctx = ResolveContext(fieldContext: FieldInsertFixtures.context())
        let resolved = EntityKind.applyingFields(d, ctx: ctx)

        // The placeholder marker is gone and the live value is substituted in its place.
        #expect(!resolved.text.contains("\u{FEFF}"))
        #expect(resolved.text.contains("2026-06-17"))
        #expect(resolved.text.hasPrefix("Today is "))
    }

    @Test("without a field context the placeholder stays verbatim (zero-width, unsubstituted)")
    func noContextLeavesPlaceholder() {
        let inserted = InspectorEdits.appendField(to: FieldInsertFixtures.text("x"), token: .date())
        guard case .text(let d) = inserted else { Issue.record("not text"); return }

        let resolved = EntityKind.applyingFields(d, ctx: ResolveContext())  // no fieldContext
        #expect(resolved.text == d.text)                 // byte-identical
        #expect(resolved.text.contains("\u{FEFF}"))      // marker still present (renders zero-width)
    }
}

// MARK: - MTEXT insert

@Suite("Field insert — MTEXT")
struct FieldInsertMTextEditTests {

    @Test("appending a field to MTEXT adds a FieldRun + a trailing placeholder run on the last paragraph")
    func appendToMText() {
        let kind = FieldInsertFixtures.mtext([
            FieldInsertFixtures.run("Line A"),
            FieldInsertFixtures.run("Line B"),
        ])

        let out = InspectorEdits.appendField(to: kind, token: .fileName())
        guard case .mtext(let d) = out else { Issue.record("not mtext"); return }

        #expect(d.fields?.count == 1)
        #expect(d.fields?.first?.token == .fileName())
        // The marker rides a new run appended to the LAST paragraph (the first is kept).
        #expect(d.paragraphs.count == 2)
        let lastInlines = d.paragraphs.last!.inlines
        #expect(lastInlines.count == 2)
        if case .run(let r) = lastInlines.last {
            #expect(r.text == FieldEvaluator.placeholder(for: 0))
        } else {
            Issue.record("last inline is not a run")
        }
        // rawCode is cleared so the writer re-emits from the field-bearing paragraphs.
        #expect(d.rawCode == nil)
    }

    @Test("appending to an EMPTY MTEXT body creates a paragraph carrying the placeholder run")
    func appendToEmptyMText() {
        let out = InspectorEdits.appendField(to: FieldInsertFixtures.mtext([]), token: .layoutName())
        guard case .mtext(let d) = out else { Issue.record("not mtext"); return }

        #expect(d.paragraphs.count == 1)
        if case .run(let r) = d.paragraphs.first?.inlines.first {
            #expect(r.text == FieldEvaluator.placeholder(for: 0))
        } else {
            Issue.record("no placeholder run created")
        }
        #expect(d.fields?.first?.index == 0)
    }

    @Test("appendField does NOT mutate the original MTEXT (value transform → undoable)")
    func appendIsValueTransform() {
        let original = FieldInsertFixtures.mtext([FieldInsertFixtures.run("body")])
        let out = InspectorEdits.appendField(to: original, token: .date())

        guard case .mtext(let o) = original else { Issue.record("not mtext"); return }
        #expect(o.fields == nil)
        #expect(o.paragraphs.count == 1)
        #expect(o.paragraphs.first?.inlines.count == 1)  // no run appended to the original
        #expect(out != original)
    }

    @Test("a field-bearing MTEXT round-trips losslessly through Codable")
    func mtextCodableRoundTrip() throws {
        let inserted = InspectorEdits.appendField(
            to: FieldInsertFixtures.mtext([FieldInsertFixtures.run("Sheet ")]),
            token: .layoutName())
        let restored = try FieldInsertFixtures.codableRoundTrip(inserted)
        #expect(restored == inserted)
    }

    @Test("end-to-end: the appended MTEXT placeholder resolves to the live layout name")
    func resolvesWithContext() {
        let inserted = InspectorEdits.appendField(
            to: FieldInsertFixtures.mtext([FieldInsertFixtures.run("On ")]),
            token: .layoutName())
        guard case .mtext(let d) = inserted else { Issue.record("not mtext"); return }

        let ctx = ResolveContext(fieldContext: FieldInsertFixtures.context())
        let resolved = EntityKind.applyingFields(d, ctx: ctx)

        let joined = resolved.paragraphs.flatMap(\.inlines).compactMap { inline -> String? in
            if case .run(let r) = inline { return r.text }
            return nil
        }.joined()
        #expect(joined.contains("Layout1"))
        #expect(!joined.contains("\u{FEFF}"))
    }
}

// MARK: - Index allocation + non-text no-op

@Suite("Field insert — allocation & no-op")
struct FieldInsertMiscTests {

    @Test("nextFieldIndex is 0 for nil/empty and one past the max otherwise")
    func nextIndexAllocation() {
        #expect(InspectorEdits.nextFieldIndex(nil) == 0)
        #expect(InspectorEdits.nextFieldIndex([]) == 0)
        #expect(InspectorEdits.nextFieldIndex([FieldRun(index: 0, token: .date())]) == 1)
        // Robust to non-contiguous / out-of-order indices.
        #expect(InspectorEdits.nextFieldIndex([
            FieldRun(index: 5, token: .date()),
            FieldRun(index: 2, token: .fileName()),
        ]) == 6)
    }

    @Test("appending a field to a non-text/mtext kind is a safe no-op")
    func nonTextNoOp() {
        let line = EntityKind.line(LineData(start: Vector(0, 0), end: Vector(1, 1)))
        let out = InspectorEdits.appendField(to: line, token: .date())
        #expect(out == line)

        let circle = EntityKind.circle(CircleData(center: Vector(0, 0), radius: 3))
        #expect(InspectorEdits.appendField(to: circle, token: .fileName()) == circle)
    }
}
