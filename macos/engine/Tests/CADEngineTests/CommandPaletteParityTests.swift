//
//  CommandPaletteParityTests.swift
//  CADEngineTests
//
//  Lane S (#01) — guards the ⌘K command palette's CURATED parity roster + the
//  consistency fixes that keep the palette typeable from the menu wording:
//
//    • Curated allow-list: a fixed set of high-value app actions MUST appear in the
//      palette (Document Settings, Import/Merge DXF, Dimension Style Manager,
//      Save/Restore View, Insert/Save Block from/to File, New Layout, …). This is a
//      CURATED list — NOT a full menu derivation — so the test asserts presence of the
//      agreed roster, not menu/palette equality.
//    • "Show Grid" / "Inspector" titles: the palette's matcher is a strict case-
//      insensitive SUBSEQUENCE, so a palette title must MATCH the menu wording or a
//      user typing the menu label gets ZERO hits. We pin that the grid command reads
//      "Show Grid" (View ▸ Show Grid) and the inspector command reads "Inspector"
//      (the toolbar/menu label) — and that both are reachable via the live matcher.
//
//  The registry is symlinked into this test target as `_SharedCommandPalette.swift`;
//  the fuzzy matcher under test is the pure `CommandMatcher` in CADEngine.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("Command palette curated parity (#01)")
@MainActor
struct CommandPaletteParityTests {

    /// A no-op `Actions` bundle — the parity roster is about which COMMANDS exist, not
    /// what they do, so every closure is an inert stub.
    private func stubActions() -> CommandRegistry.Actions {
        CommandRegistry.Actions(
            activateTool: { _ in },
            placeImage: {},
            createBlockFromSelection: {},
            open: {}, save: {}, saveAs: {},
            export: { _ in }, print: {},
            zoomToFit: {}, undo: {}, redo: {},
            toggleInspector: {}, toggleGrid: {}, documentSettings: {},
            importMergeDXF: {}, dimensionStyleManager: {},
            saveNamedView: {}, restoreNamedView: {},
            insertBlockFromFile: {}, saveBlockToFile: {}, newLayout: {}
        )
    }

    private var commands: [PaletteCommand] { CommandRegistry.commands(stubActions()) }

    // MARK: Curated allow-list of app actions

    /// The CURATED set of app-action command IDs that must be present in the palette
    /// (the agreed high-value roster — extending the pre-existing Open/Save/Export/…).
    /// Pinning by stable `id` (not title) makes the test resilient to copy tweaks.
    private static let requiredAppActionIDs: Set<String> = [
        "app.open", "app.save", "app.saveAs",
        "app.exportPDF", "app.exportPNG", "app.exportSVG",
        "app.print", "app.zoomToFit", "app.undo", "app.redo",
        "app.toggleInspector", "app.toggleGrid", "app.documentSettings",
        // Parity additions (#01):
        "app.importMergeDXF", "app.dimStyleManager",
        "app.saveView", "app.restoreView",
        "app.insertBlockFromFile", "app.saveBlockToFile", "app.newLayout",
    ]

    @Test("the curated app-action roster is all present in the palette")
    func curatedRosterPresent() {
        let ids = Set(commands.map(\.id))
        for required in Self.requiredAppActionIDs {
            #expect(ids.contains(required), "missing curated palette command: \(required)")
        }
    }

    @Test("every command has a unique id (no shadowed entries)")
    func uniqueIDs() {
        let ids = commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("every tool kind is surfaced as a palette command")
    func everyToolPresent() {
        let ids = Set(commands.map(\.id))
        for kind in ToolKind.allCases {
            #expect(ids.contains("tool.\(kind.rawValue)"), "missing tool: \(kind.rawValue)")
        }
    }

    // MARK: Menu-wording titles must be typeable via the matcher

    @Test("‘Show Grid’ is the grid command title and is matchable by the menu wording")
    func showGridMatchesMenuWording() {
        // The title must read "Show Grid" (NOT "Toggle Grid") — the subsequence matcher
        // returns ZERO hits for the menu label "Show Grid" otherwise.
        let grid = commands.first { $0.id == "app.toggleGrid" }
        #expect(grid?.title == "Show Grid")

        // And the live matcher finds it when the user types the menu wording.
        let titles = commands.map(\.title)
        let ranked = CommandMatcher.rank(query: "Show Grid", candidates: titles)
        #expect(ranked.map { titles[$0.index] }.contains("Show Grid"))
    }

    @Test("the inspector command reads ‘Inspector’ (matches the toolbar/menu label)")
    func inspectorTitleConsistent() {
        let inspector = commands.first { $0.id == "app.toggleInspector" }
        #expect(inspector?.title == "Inspector")

        let titles = commands.map(\.title)
        let ranked = CommandMatcher.rank(query: "Inspector", candidates: titles)
        #expect(ranked.map { titles[$0.index] }.contains("Inspector"))
    }

    @Test("curated additions are each findable by their menu wording")
    func parityAdditionsTypeable() {
        let titles = commands.map(\.title)
        // The menu label → the exact palette title it should surface.
        let probes: [(query: String, expected: String)] = [
            ("Import / Merge DXF", "Import / Merge DXF…"),
            ("Dimension Style Manager", "Dimension Style Manager…"),
            ("Save View", "Save View…"),
            ("Restore View", "Restore View…"),
            ("Insert Block from File", "Insert Block from File…"),
            ("Save Block to File", "Save Block to File…"),
            ("New Layout", "New Layout"),
        ]
        for probe in probes {
            let ranked = CommandMatcher.rank(query: probe.query, candidates: titles)
            #expect(ranked.map { titles[$0.index] }.contains(probe.expected),
                    "‘\(probe.query)’ did not surface ‘\(probe.expected)’ in the palette")
        }
    }
}
