//
//  FieldCodecBackCompatTests.swift
//  CADEngineTests
//
//  Wave 2a — the FIELDS storage codec + resolve byte-identity tests:
//    - TextData / MTextData with AND without `fields` round-trip via Codable
//    - OLD JSON lacking the `fields` key decodes to `fields == nil` (back-compat)
//    - `FieldToken` / `FieldRun` round-trip via Codable (every MVP token + obj-prop)
//    - resolve with a nil `fieldContext` is BYTE-IDENTICAL to the same entity with
//      NO fields (the regression-lock) — for both TEXT and MTEXT
//    - resolve WITH a wired `fieldContext` actually substitutes (geometry changes
//      vs. the un-substituted form)
//
//  Suite/type names are domain-namespaced (`FieldCodec*`) per CONVENTIONS.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Token / run Codable round-trip

@Suite struct FieldCodecTokenTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func everyTokenRoundTrips() throws {
        let tokens: [FieldToken] = [
            .date(),
            .date(format: "yyyy-MM-dd"),
            .layoutName(),
            .fileName(),
            .fileName(format: "nameext"),
            .objectProperty(entityID: EntityID(42), property: "area"),
            .objectProperty(entityID: EntityID(42), property: "length", format: "%.2f"),
        ]
        for t in tokens {
            #expect(try roundTrip(t) == t)
        }
    }

    @Test func fieldRunRoundTrips() throws {
        let run = FieldRun(index: 3, token: .date(format: "yyyy"))
        #expect(try roundTrip(run) == run)
    }
}

// MARK: - TextData / MTextData Codable round-trip + back-compat

@Suite struct FieldCodecBackCompatTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // TEXT —

    @Test func textDataWithoutFieldsRoundTrips() throws {
        let d = TextData(position: Vector(1, 2), height: 5, text: "hello")
        let back = try roundTrip(d)
        #expect(back == d)
        #expect(back.fields == nil)
    }

    @Test func textDataWithFieldsRoundTrips() throws {
        var d = TextData(position: Vector(1, 2), height: 5,
                         text: "Sheet \(FieldEvaluator.placeholder(for: 0))")
        d.fields = [FieldRun(index: 0, token: .layoutName())]
        let back = try roundTrip(d)
        #expect(back == d)
        #expect(back.fields?.count == 1)
        #expect(back.fields?.first?.token == .layoutName())
    }

    /// Encodes `value`, strips the named top-level key from the JSON (simulating an
    /// OLD payload serialized before that key existed), and returns the trimmed JSON.
    private func jsonRemovingKey<T: Encodable>(_ value: T, key: String) throws -> Data {
        let data = try JSONEncoder().encode(value)
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test func oldTextJSONWithoutFieldsKeyDecodesToNil() throws {
        // Build a real (field-bearing) TextData, then strip the `fields` key to mimic
        // a TEXT serialized BEFORE `fields` existed. It must decode with fields == nil
        // and every other field intact.
        var d = TextData(position: Vector(1, 2), height: 5, text: "old")
        d.fields = [FieldRun(index: 0, token: .layoutName())]
        let trimmed = try jsonRemovingKey(d, key: "fields")
        let back = try JSONDecoder().decode(TextData.self, from: trimmed)
        #expect(back.fields == nil)
        #expect(back.text == "old")
        #expect(back.height == 5)
        #expect(back.position == Vector(1, 2))
    }

    // MTEXT —

    @Test func mtextDataWithoutFieldsRoundTrips() throws {
        let d = MTextData(position: Vector(0, 0), height: 10,
                          paragraphs: [MTextParagraph(inlines: [.run(TextRun(text: "abc"))])])
        let back = try roundTrip(d)
        #expect(back == d)
        #expect(back.fields == nil)
    }

    @Test func mtextDataWithFieldsRoundTrips() throws {
        var d = MTextData(position: Vector(0, 0), height: 10,
                          paragraphs: [MTextParagraph(inlines: [
                            .run(TextRun(text: "Date: \(FieldEvaluator.placeholder(for: 0))"))])])
        d.fields = [FieldRun(index: 0, token: .date(format: "yyyy"))]
        let back = try roundTrip(d)
        #expect(back == d)
        #expect(back.fields?.first?.token == .date(format: "yyyy"))
    }

    @Test func oldMTextJSONWithoutFieldsKeyDecodesToNil() throws {
        // Build a real (field-bearing) MTextData, then strip the `fields` key to mimic
        // an MTEXT serialized before `fields` existed.
        var d = MTextData(position: Vector(0, 0), height: 10,
                          paragraphs: [MTextParagraph(inlines: [.run(TextRun(text: "old"))])])
        d.fields = [FieldRun(index: 0, token: .date())]
        let trimmed = try jsonRemovingKey(d, key: "fields")
        let back = try JSONDecoder().decode(MTextData.self, from: trimmed)
        #expect(back.fields == nil)
        #expect(back.height == 10)
        #expect(back.paragraphs.count == 1)
    }

    // EntityRecord wrapper round-trip (fields ride the engine Codable payload) —

    @Test func entityRecordWithFieldTextRoundTrips() throws {
        var t = TextData(position: Vector(0, 0), height: 4,
                         text: "F: \(FieldEvaluator.placeholder(for: 0))")
        t.fields = [FieldRun(index: 0, token: .fileName())]
        let rec = EntityRecord(id: EntityID(11), kind: .text(t))
        let back = try roundTrip(rec)
        #expect(back == rec)
        if case .text(let bt) = back.kind {
            #expect(bt.fields?.first?.token == .fileName())
        } else {
            Issue.record("decoded kind was not .text")
        }
    }
}

// MARK: - Resolve byte-identity (regression-lock) + substitution

@Suite struct FieldResolveIdentityTests {

    private let pen = ResolvedPen(color: .black, lineType: .solid, lineWidth: .default)
    private func ctx() -> ResolveContext { TextSystemFixtures.nativeCtx() }

    // TEXT: a field-bearing text resolved WITHOUT a field context is byte-identical
    // to the SAME text whose displayed string is the stored placeholder string and
    // that carries NO fields (i.e. resolve never touches the string without a ctx).
    @Test func textNilContextByteIdenticalToNoFields() {
        let stored = "Plan: \(FieldEvaluator.placeholder(for: 0))"
        var withFields = TextData(position: Vector(0, 0), height: 8, text: stored)
        withFields.fields = [FieldRun(index: 0, token: .layoutName())]
        let noFields = TextData(position: Vector(0, 0), height: 8, text: stored)  // fields == nil

        // Context has NO fieldContext wired (nativeCtx) → no substitution.
        let a = EntityKind.text(withFields).resolve(pen: pen, ctx: ctx())
        let b = EntityKind.text(noFields).resolve(pen: pen, ctx: ctx())
        #expect(a == b)
    }

    // A plain non-field text is unaffected (resolve unchanged) regardless of whether
    // a field context is even present.
    @Test func plainTextUnaffectedByFieldContext() {
        let d = TextData(position: Vector(0, 0), height: 8, text: "PLAIN")
        var withFC = ctx()
        withFC.fieldContext = FieldContext(layoutName: "L1")
        let a = EntityKind.text(d).resolve(pen: pen, ctx: ctx())     // no fc
        let b = EntityKind.text(d).resolve(pen: pen, ctx: withFC)    // fc, but no fields
        #expect(a == b)
    }

    // TEXT: WITH a wired field context, the field is substituted, so the geometry
    // differs from the un-substituted (nil-context) resolve.
    @Test func textWithContextSubstitutes() {
        let stored = "X\(FieldEvaluator.placeholder(for: 0))"
        var d = TextData(position: Vector(0, 0), height: 8, text: stored)
        d.fields = [FieldRun(index: 0, token: .layoutName())]

        var withFC = ctx()
        withFC.fieldContext = FieldContext(layoutName: "Layout1")

        let substituted = EntityKind.text(d).resolve(pen: pen, ctx: withFC)
        let verbatim = EntityKind.text(d).resolve(pen: pen, ctx: ctx())  // no fc

        // "XLayout1" (substituted) shapes MORE glyphs than "X" + a zero-width marker.
        #expect(substituted != verbatim)
        #expect(!substituted.fills.isEmpty)
        // The substituted form's displayed string is what a plain "XLayout1" resolves to.
        let plain = TextData(position: Vector(0, 0), height: 8, text: "XLayout1")
        #expect(EntityKind.text(plain).resolve(pen: pen, ctx: ctx()) == substituted)
    }

    // MTEXT: nil-context byte-identity (regression-lock).
    @Test func mtextNilContextByteIdenticalToNoFields() {
        let runText = "S: \(FieldEvaluator.placeholder(for: 0))"
        let para = MTextParagraph(inlines: [.run(TextRun(text: runText))])
        var withFields = MTextData(position: Vector(0, 0), height: 10, paragraphs: [para])
        withFields.fields = [FieldRun(index: 0, token: .layoutName())]
        let noFields = MTextData(position: Vector(0, 0), height: 10, paragraphs: [para])

        let a = EntityKind.mtext(withFields).resolve(pen: pen, ctx: ctx())
        let b = EntityKind.mtext(noFields).resolve(pen: pen, ctx: ctx())
        #expect(a == b)
    }

    // MTEXT: WITH a wired context the run text is substituted (geometry differs).
    @Test func mtextWithContextSubstitutes() {
        let runText = "S\(FieldEvaluator.placeholder(for: 0))"
        let para = MTextParagraph(inlines: [.run(TextRun(text: runText))])
        var d = MTextData(position: Vector(0, 0), height: 10, paragraphs: [para])
        d.fields = [FieldRun(index: 0, token: .layoutName())]

        var withFC = ctx()
        withFC.fieldContext = FieldContext(layoutName: "Layout1")

        let substituted = EntityKind.mtext(d).resolve(pen: pen, ctx: withFC)
        let verbatim = EntityKind.mtext(d).resolve(pen: pen, ctx: ctx())
        #expect(substituted != verbatim)

        // Equals what a plain MTEXT with the substituted run resolves to.
        let plainPara = MTextParagraph(inlines: [.run(TextRun(text: "SLayout1"))])
        let plain = MTextData(position: Vector(0, 0), height: 10, paragraphs: [plainPara])
        #expect(EntityKind.mtext(plain).resolve(pen: pen, ctx: ctx()) == substituted)
    }
}
