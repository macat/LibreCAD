//
//  ToolKindWiringTests.swift
//  CADEngineTests
//
//  Guards the central tool registry (`ToolKind`): every kind the UI can activate
//  must mint a usable tool with a stable, unique title. This is the compiler-
//  complement to the exhaustive `switch`es in ToolKind — those guarantee a kind
//  has *an* arm; these assert the arm is correct (non-nil tool for every non-
//  select kind, the tool's own `title` matches the kind's UI title, and titles are
//  unique so the toolbar/menu have no ambiguous labels).
//
//  Domain-prefixed suite name (CONVENTIONS.md: namespace test suites so parallel
//  fan-out builders adding files to the SAME target don't collide).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("ToolKind registry wiring")
struct ToolKindWiringTests {

    /// Every kind has a non-empty UI title.
    @Test func everyKindHasANonEmptyTitle() {
        for kind in ToolKind.allCases {
            #expect(!kind.title.isEmpty, "ToolKind.\(kind) has an empty title")
        }
    }

    /// Titles are unique across all kinds (no ambiguous toolbar/menu labels).
    @Test func titlesAreUnique() {
        let titles = ToolKind.allCases.map(\.title)
        #expect(Set(titles).count == titles.count, "Duplicate ToolKind titles: \(titles)")
    }

    /// `.select` is the only kind without a `Tool` (it is the built-in select/pan
    /// mode); every other kind mints a non-nil tool.
    @Test func selectIsTheOnlyKindWithoutATool() {
        for kind in ToolKind.allCases {
            if kind == .select {
                #expect(kind.makeTool() == nil, ".select must not mint a Tool")
            } else {
                #expect(kind.makeTool() != nil, "ToolKind.\(kind) minted a nil Tool")
            }
        }
    }

    /// A minted tool's own `title` matches the kind's UI title, so the HUD prompt
    /// ("Line: Specify first point") and the toolbar/menu label agree.
    @Test func mintedToolTitleMatchesKindTitle() {
        for kind in ToolKind.allCases where kind != .select {
            let tool = kind.makeTool()
            #expect(tool?.title == kind.title,
                    "ToolKind.\(kind).title (\(kind.title)) != tool.title (\(tool?.title ?? "nil"))")
        }
    }

    /// Every drawing tool and every modify tool the brief wires is present and
    /// activatable — an explicit roster so a dropped registration fails loudly.
    @Test func allDrawAndModifyKindsAreRegistered() {
        let expected: Set<ToolKind> = [
            .select,
            .line, .circle, .arc, .rectangle, .polyline, .point,   // draw
            .ellipse, .polygon,                                    // draw (wave 1)
            .move, .copy, .rotate, .scale, .mirror,                // modify
            .offset,                                               // modify (wave 1)
        ]
        #expect(Set(ToolKind.allCases) == expected,
                "ToolKind.allCases (\(ToolKind.allCases)) != expected roster")
    }

    /// The three wave-1 wiring additions specifically: each mints a non-nil tool
    /// whose own title matches the kind's UI title (Ellipse / Polygon / Offset).
    @Test func waveOneKindsAreWiredWithMatchingTitles() {
        let wave1: [ToolKind: String] = [
            .ellipse: "Ellipse",
            .polygon: "Polygon",
            .offset:  "Offset",
        ]
        for (kind, title) in wave1 {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }
}
