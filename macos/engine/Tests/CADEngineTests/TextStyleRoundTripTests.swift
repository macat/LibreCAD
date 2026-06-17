//
//  TextStyleRoundTripTests.swift
//  CADEngineTests
//
//  DXF (and DWG) round-trip tests for the named STYLE (text-style) table writer /
//  reader (W1-1A — the text-style data-loss fix). Before this lane, named text
//  styles were silently dropped on save and STYLE-table font mappings dropped on
//  load. These tests prove a drawing carrying named `TextStyle`s WRITES through the
//  engine writer and RE-READS preserving every mapped field (font source, width,
//  oblique, bold/italic, fixed height, generation flags), that a TEXT entity's
//  code-7 style reference survives, that a `.native(family:)` style round-trips via
//  code 3 + the code-1071 TTF flag, that a default/Standard-only drawing re-reads to
//  a single Standard (the byte-identity guard), and that the DWG path is crash-free
//  (with the documented DWG STYLE-table write gap, like dim styles).
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

@Suite("STYLE (text-style) writer round-trip (W1-1A)")
struct TextStyleRoundTripTests {

    private func tempPath(_ ext: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("textstyle-rt-\(UUID().uuidString).\(ext)").path
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func layers0() -> LayerTable { LayerTable() }

    // MARK: - (1) A named STROKE style + a TEXT referencing it round-trips

    @Test("a named .stroke style (width/oblique/bold/fixedHeight) + a TEXT referencing it survive write→read")
    func namedStrokeStyleRoundTrips() async throws {
        let out = tempPath("dxf")
        defer { removeFile(out) }

        // A distinctive named STYLE: an `.lff` stroke font with a non-default width
        // factor, a 15° oblique slant, bold, a fixed text height, and the backward
        // generation flag — every mapped field set to a non-default value.
        let oblique = 15.0 * Double.pi / 180.0
        var table = TextStyleTable()
        table.upsert(TextStyle(
            name: "TITLE",
            primaryFont: .stroke(lff: "iso"),
            fixedTextHeight: 2.5,
            widthFactor: 0.85,
            obliqueAngle: oblique,
            generation: [.backward],
            bold: true))

        // A TEXT entity referencing the named style by its code-7 name.
        let text = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: .init(1, 1), height: 2.5,
                                 text: "HELLO", styleName: "TITLE")))

        _ = try await CADEngine.shared.writeEntities(
            [text], layers: layers0(), textStyles: table, toPath: out)
        #expect(FileManager.default.fileExists(atPath: out))

        let result = try await CADEngine.shared.readEntities(dxfPath: out)

        // The named STYLE survived with every field intact.
        let title = try #require(result.textStyles.style(named: "TITLE"))
        #expect(title.primaryFont == .stroke(lff: "iso"))
        #expect(abs(title.widthFactor - 0.85) < 1e-6)
        #expect(abs(title.obliqueAngle - oblique) < 1e-6)
        #expect(title.bold == true)
        #expect(title.italic == false)
        #expect(abs(title.fixedTextHeight - 2.5) < 1e-6)
        #expect(title.generation.contains(.backward))

        // The TEXT entity still references the named style (code 7).
        let textData = try #require(result.records.compactMap { rec -> TextData? in
            if case .text(let d) = rec.kind { return d }
            return nil
        }.first)
        #expect(textData.styleName?.caseInsensitiveCompare("TITLE") == .orderedSame)
    }

    // MARK: - (2) A native-family style round-trips via code 3 + the TTF flag

    @Test("a .native(family:) style round-trips the family (code 3) + the TTF-family flag (italic)")
    func nativeFamilyStyleRoundTrips() async throws {
        let out = tempPath("dxf")
        defer { removeFile(out) }

        var table = TextStyleTable()
        table.upsert(TextStyle(
            name: "ARIALITALIC",
            primaryFont: .native(family: "Arial"),
            widthFactor: 1.0,
            italic: true))

        _ = try await CADEngine.shared.writeEntities(
            [], layers: layers0(), textStyles: table, toPath: out)

        let result = try await CADEngine.shared.readEntities(dxfPath: out)
        let arial = try #require(result.textStyles.style(named: "ARIALITALIC"))
        // The family rode code 3 and the TTF flag drove the `.native` decode (NOT a
        // `.stroke`/`.shx` — there is no `.lff`/`.shx` extension on a TTF family).
        #expect(arial.primaryFont == .native(family: "Arial"))
        #expect(arial.italic == true)
        #expect(arial.bold == false)
    }

    // MARK: - (3) Byte-identity guard: a default drawing re-reads to a single Standard

    @Test("a default (Standard-only) drawing re-reads to a single Standard text style (byte-identity guard)")
    func defaultDrawingReReadsToSingleStandard() async throws {
        let out = tempPath("dxf")
        defer { removeFile(out) }

        // A plain drawing with NO custom text styles — `writeEntities` defaults the
        // STYLE table to the standard one, so the byte-identity gate emits nothing and
        // libdxfrw writes its plain default "Standard" (exactly as before this lane).
        let line = EntityRecord(
            id: EntityID(1),
            kind: .line(LineData(start: .init(0, 0), end: .init(1, 1))))
        _ = try await CADEngine.shared.writeEntities([line], layers: layers0(), toPath: out)

        let result = try await CADEngine.shared.readEntities(dxfPath: out)
        #expect(result.textStyles.styles.count == 1)
        #expect(result.textStyles.style(named: "Standard") != nil)
    }

    // MARK: - (4) DWG path: crash-free + re-reads (documented STYLE write gap)

    @Test("DWG save→reopen is crash-free and re-reads (custom text styles are the documented libdxfrw DWG gap)")
    func dwgPathIsCrashFreeAndReReads() async throws {
        let out = tempPath("dwg")
        defer { removeFile(out) }

        var table = TextStyleTable()
        table.upsert(TextStyle(name: "DWGONLY", primaryFont: .stroke(lff: "iso"),
                               widthFactor: 0.9))
        let text = EntityRecord(
            id: EntityID(1),
            kind: .text(TextData(position: .init(0, 0), height: 1, text: "DWG",
                                 styleName: "DWGONLY")))

        // Write must not crash; DWG is R2000-only and emits its standard STYLE table
        // internally (no per-style write path — the documented gap, like dim styles).
        _ = try await CADEngine.shared.writeEntities(
            [text], layers: layers0(), textStyles: table, toDWGPath: out)
        #expect(FileManager.default.fileExists(atPath: out))

        // Re-read is crash-free and still yields the always-present Standard; the
        // custom "DWGONLY" style is NOT written to DWG (the documented table gap).
        let result = try await CADEngine.shared.readEntities(dwgPath: out)
        #expect(result.textStyles.style(named: "Standard") != nil)
        #expect(result.textStyles.style(named: "DWGONLY") == nil)
    }
}
