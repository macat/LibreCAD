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
            .trim, .extend, .fillet, .chamfer,                     // edit (wave 2)
            .spline, .array, .divide, .explode, .hatch,            // wave A
            .text,                                                 // wave B (annotate)
            .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim, // wave B (dimensions)
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

    /// The four wave-2 EDIT wiring additions: Trim / Extend / Fillet / Chamfer.
    /// Each mints a non-nil tool whose own title matches the kind's UI title, so
    /// the toolbar/menu label and the HUD prompt ("Trim: …") agree.
    @Test func waveTwoEditKindsAreWiredWithMatchingTitles() {
        let wave2: [ToolKind: String] = [
            .trim:    "Trim",
            .extend:  "Extend",
            .fillet:  "Fillet",
            .chamfer: "Chamfer",
        ]
        for (kind, title) in wave2 {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }

    /// The five wave-A wiring additions: Spline / Array / Divide / Explode / Hatch.
    /// Each mints a non-nil tool whose own title matches the kind's UI title, so the
    /// toolbar/menu label and the HUD prompt ("Spline: …") agree.
    @Test func waveAKindsAreWiredWithMatchingTitles() {
        let waveA: [ToolKind: String] = [
            .spline:  "Spline",
            .array:   "Array",
            .divide:  "Divide",
            .explode: "Explode",
            .hatch:   "Hatch",
        ]
        for (kind, title) in waveA {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }

    /// The six wave-B wiring additions: Text + the five dimension tools. Each mints a
    /// non-nil tool whose own title matches the kind's UI title, so the toolbar/menu
    /// label and the HUD prompt agree. The radial/diameter kinds both mint a
    /// `RadialDimTool` (radius vs diameter MODE), so their DISTINCT titles also guard
    /// that the mode is wired correctly.
    @Test func waveBKindsAreWiredWithMatchingTitles() {
        let waveB: [ToolKind: String] = [
            .text:        "Text",
            .linearDim:   "Linear Dimension",
            .alignedDim:  "Aligned Dimension",
            .radialDim:   "Radius Dimension",
            .diameterDim: "Diameter Dimension",
            .angularDim:  "Angular Dimension",
        ]
        for (kind, title) in waveB {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }

    /// The Text kind's title MUST be exactly "Text" — the inline `NSTextView` editor
    /// in `CADCanvasView` activates by matching the active tool's `title == "Text"`,
    /// so a renamed title would silently break text authoring. (A focused guard on the
    /// load-bearing string, separate from the general title checks above.)
    @Test func textKindTitleIsExactlyText() {
        #expect(ToolKind.text.title == "Text")
        #expect(ToolKind.text.makeTool()?.title == "Text")
    }

    /// The keyboard shortcuts the UI assigns to each kind must be UNIQUE — no two
    /// kinds may share the same key chord, or one would shadow the other. This is a
    /// data mirror of the canvas keymap (`CADCanvasView.handleKey`) / Tools menu /
    /// toolbar tooltips, kept here so a future collision (e.g. assigning an already-
    /// used chord to a new tool) fails loudly in the engine test target. A chord is
    /// `(key, shift)`; `.select` and the wave-A additions are all included.
    @Test func toolShortcutsAreUnique() {
        // (kind, key, shiftHeld) — the single source of truth mirrored from the UI.
        let keymap: [(ToolKind, Character, Bool)] = [
            (.select, "v", false),
            (.line, "l", false),
            (.circle, "c", false), (.copy, "c", true),
            (.arc, "a", false), (.array, "a", true),
            (.rectangle, "r", false), (.rotate, "r", true),
            (.polyline, "p", false),
            (.point, "o", false), (.offset, "o", true),
            (.ellipse, "e", false),
            (.polygon, "g", false),
            (.move, "m", false), (.mirror, "m", true),
            (.spline, "s", false), (.scale, "s", true),
            (.hatch, "h", false),
            (.divide, "d", true),
            (.trim, "t", false), (.text, "t", true),
            (.extend, "x", false), (.explode, "x", true),
            (.fillet, "f", false), (.chamfer, "f", true),
            // wave B dimensions — bare, collision-free letters.
            (.linearDim, "d", false),
            (.alignedDim, "i", false),
            (.radialDim, "u", false),
            (.diameterDim, "b", false),
            (.angularDim, "n", false),
        ]
        // No two entries share a (key, shift) chord.
        let chords = keymap.map { "\($0.1)\($0.2 ? "+shift" : "")" }
        #expect(Set(chords).count == chords.count,
                "Duplicate tool shortcut chord(s): \(chords)")
        // No kind appears twice in the keymap.
        let kinds = keymap.map(\.0)
        #expect(Set(kinds).count == kinds.count,
                "A ToolKind is mapped to more than one chord: \(kinds)")
        // Every wave-A kind has a shortcut.
        for k in [ToolKind.spline, .array, .divide, .explode, .hatch] {
            #expect(kinds.contains(k), "wave-A kind \(k) has no keyboard shortcut")
        }
        // Every wave-B kind (Text + the five dimensions) has a shortcut.
        for k in [ToolKind.text, .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim] {
            #expect(kinds.contains(k), "wave-B kind \(k) has no keyboard shortcut")
        }
    }
}
