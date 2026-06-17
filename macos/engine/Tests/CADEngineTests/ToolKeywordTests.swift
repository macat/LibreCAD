//
//  ToolKeywordTests.swift
//  CADEngineTests
//
//  Tests for the additive `ToolKeyword` value type + the `Tool.keywordOptions`
//  protocol member's extension default (smart command-line, Wave 1C). Mirrors the
//  append-only contract proven by `referenceSegments` / `liveDimensions`:
//   - `ToolKeyword` round-trips its `keyword`/`label` fields and is `Equatable`;
//   - a real concrete tool that does NOT override `keywordOptions` inherits the
//     extension default `[]` (proving no existing tool file must change);
//   - a tiny mock that DOES override surfaces its options (proving opt-in works).
//
//  No GUI: pure value types, driven without AppKit/Metal.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("tool command keywords")
struct ToolKeywordTests {

    // MARK: - Value type

    @Test("ToolKeyword round-trips its fields")
    func roundTripsFields() {
        let kw = ToolKeyword(keyword: "Close", label: "Close")
        #expect(kw.keyword == "Close")
        #expect(kw.label == "Close")

        // keyword and label may differ (terse typed token vs. human chip label).
        let terse = ToolKeyword(keyword: "2P", label: "2 Points")
        #expect(terse.keyword == "2P")
        #expect(terse.label == "2 Points")
    }

    @Test("ToolKeyword is Equatable on both fields")
    func equatable() {
        #expect(ToolKeyword(keyword: "Close", label: "Close")
                == ToolKeyword(keyword: "Close", label: "Close"))
        // Differing keyword → not equal.
        #expect(ToolKeyword(keyword: "Close", label: "Close")
                != ToolKeyword(keyword: "Undo", label: "Close"))
        // Differing label → not equal.
        #expect(ToolKeyword(keyword: "2P", label: "2 Points")
                != ToolKeyword(keyword: "2P", label: "Two Points"))
    }

    // MARK: - Extension default (no existing tool overrides)

    @Test("a real tool inherits the empty keywordOptions default")
    func realToolInheritsEmptyDefault() {
        // LineTool is a concrete `Tool` conformer that does NOT override
        // `keywordOptions`; it must inherit the protocol-extension default `[]`,
        // proving the contract is append-only (no per-tool change required).
        let tool = LineTool()
        #expect(tool.keywordOptions == [])
    }

    @Test("the empty default holds across several non-overriding tools")
    func severalToolsInheritEmptyDefault() {
        // A spread of unrelated draw tools, all relying on the default. NOTE: Circle
        // and Arc were here in W1C but now OPT IN to construction-mode keywords (W2B),
        // so this spread uses tools that still genuinely inherit the empty default —
        // preserving the test's intent (non-overriding tools surface no chips).
        let tools: [any Tool] = [LineTool(), RectangleTool(), PolygonTool(), PointTool()]
        for tool in tools {
            #expect(tool.keywordOptions.isEmpty)
        }
    }

    // MARK: - Opt-in override

    /// A minimal `Tool` that OPTS IN to `keywordOptions`, proving an overriding tool
    /// can surface chips while the default stays `[]` for everyone else.
    private struct KeywordedMockTool: Tool {
        var title: String { "Mock" }
        var status: String { "" }
        var preview: [ResolvedPolyline] { [] }
        mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome { .none }
        var keywordOptions: [ToolKeyword] {
            [ToolKeyword(keyword: "Close", label: "Close"),
             ToolKeyword(keyword: "Undo", label: "Undo")]
        }
    }

    @Test("an overriding tool surfaces its keyword options")
    func overrideSurfacesOptions() {
        let tool = KeywordedMockTool()
        #expect(tool.keywordOptions == [
            ToolKeyword(keyword: "Close", label: "Close"),
            ToolKeyword(keyword: "Undo", label: "Undo"),
        ])
    }
}
