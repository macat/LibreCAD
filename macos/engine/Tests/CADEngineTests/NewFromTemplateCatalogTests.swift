//
//  NewFromTemplateCatalogTests.swift
//  CADEngineTests
//
//  Verifies the bundled "New from Template…" templates (F24, wave w5-templates) are
//  valid DXF and seed a new drawing with the EXPECTED units, layers, and geometry
//  when read through the SAME engine read path the document Open / template-seed flow
//  uses (`CADEngine.shared.readEntities`). A template is just an ordinary `.dxf`, so
//  the only template-specific logic is file discovery + the catalog contents; this
//  suite pins the catalog so a future edit to a template `.dxf` (or the make-app.sh
//  copy list) that changes its units / layer set / titleblock content trips a test.
//
//  The templates live in `macos/assets/templates/` (the same dir make-app.sh bundles
//  into the app's Resources). The test locates them via a path derived from this
//  file's `#filePath` (the bare-binary / dev fallback the app's `DrawingTemplate`
//  uses), so it needs no copy into the test bundle.
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

@Suite("New-from-template catalog (w5-templates / F24)")
struct NewFromTemplateCatalogTests {

    /// The in-repo `macos/assets/templates` directory, derived from this test file's
    /// source path: <repo>/macos/engine/Tests/CADEngineTests/<thisfile> -> drop the
    /// filename + 4 dirs (CADEngineTests, Tests, engine, macos's `engine` parent...)
    /// to reach `macos`, then `assets/templates`.
    private func templatesDirectory() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let macosDir = thisFile
            .deletingLastPathComponent()   // .../CADEngineTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // .../engine
            .deletingLastPathComponent()   // .../macos
        let dir = macosDir.appendingPathComponent("assets/templates")
        try #require(
            FileManager.default.fileExists(atPath: dir.path),
            "macos/assets/templates directory missing at \(dir.path)")
        return dir
    }

    /// Path to a named template `.dxf` in the assets dir.
    private func templatePath(_ name: String) throws -> String {
        let url = try templatesDirectory().appendingPathComponent("\(name).dxf")
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "template \(name).dxf missing at \(url.path)")
        return url.path
    }

    @Test("all three catalog templates ship and parse without warnings")
    func allTemplatesParse() async throws {
        for name in ["Blank_Metric_A3", "Blank_Imperial", "Titleblock_A4_Metric"] {
            let result = try await CADEngine.shared.readEntities(dxfPath: templatePath(name))
            // A template must at least carry the mandatory layer "0".
            #expect(result.layers.layers.contains { $0.name == "0" },
                    "\(name): missing the default layer 0")
            // Supported entities only — no unsupported-entity warnings from a template.
            #expect(result.warnings.isEmpty, "\(name): unexpected warnings \(result.warnings)")
        }
    }

    @Test("blank metric A3 template: millimeters, default layer, no entities")
    func blankMetricA3() async throws {
        let result = try await CADEngine.shared.readEntities(
            dxfPath: templatePath("Blank_Metric_A3"))
        #expect(result.graphicVariables.unit == .millimeter)
        #expect(result.records.isEmpty, "the blank template should seed an empty drawing")
        #expect(result.layers.layers.contains { $0.name == "0" })
    }

    @Test("blank imperial template: inches, default layer, no entities")
    func blankImperial() async throws {
        let result = try await CADEngine.shared.readEntities(
            dxfPath: templatePath("Blank_Imperial"))
        #expect(result.graphicVariables.unit == .inch)
        #expect(result.records.isEmpty, "the blank template should seed an empty drawing")
        #expect(result.layers.layers.contains { $0.name == "0" })
    }

    @Test("title-block template: metric, a TITLEBLOCK layer, and seeded geometry")
    func titleblockA4() async throws {
        let result = try await CADEngine.shared.readEntities(
            dxfPath: templatePath("Titleblock_A4_Metric"))
        #expect(result.graphicVariables.unit == .millimeter)
        // The titleblock template carries a dedicated layer beyond "0".
        #expect(result.layers.layers.contains { $0.name == "TITLEBLOCK" },
                "missing the TITLEBLOCK layer")
        // It seeds real geometry (border + titleblock lines + label text) — NOT empty.
        #expect(!result.records.isEmpty, "the titleblock template should seed geometry")
        // The border alone is 4 lines; expect at least the border + a couple labels.
        let lineCount = result.records.filter { $0.kind.isLine }.count
        #expect(lineCount >= 4, "expected at least the 4 border lines, got \(lineCount)")
    }
}

// MARK: - Test-local helper

private extension EntityKind {
    /// Whether this entity is a straight `.line` segment (used to count the
    /// titleblock's border/grid lines without depending on the full kind surface).
    var isLine: Bool {
        if case .line = self { return true }
        return false
    }
}
