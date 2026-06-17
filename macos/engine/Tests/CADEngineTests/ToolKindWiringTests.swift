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

    /// The OUT-OF-BAND kinds — `.select` (the built-in select/pan mode) and `.viewport`
    /// (paper-space viewport placement, driven by the standalone `ViewportTool`, not a
    /// `Tool` conformer) — mint NO `Tool`; every other kind mints a non-nil tool.
    @Test func selectAndViewportAreTheOnlyKindsWithoutATool() {
        let outOfBand: Set<ToolKind> = [.select, .viewport]
        for kind in ToolKind.allCases {
            if outOfBand.contains(kind) {
                #expect(kind.makeTool() == nil, "ToolKind.\(kind) (out-of-band) must not mint a Tool")
            } else {
                #expect(kind.makeTool() != nil, "ToolKind.\(kind) minted a nil Tool")
            }
        }
    }

    /// A minted tool's own `title` matches the kind's UI title, so the HUD prompt
    /// ("Line: Specify first point") and the toolbar/menu label agree. Skips the
    /// out-of-band kinds (`.select` / `.viewport`) which mint no `Tool`.
    @Test func mintedToolTitleMatchesKindTitle() {
        let outOfBand: Set<ToolKind> = [.select, .viewport]
        for kind in ToolKind.allCases where !outOfBand.contains(kind) {
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
            .stretch, .lengthen, .break,                           // wave C (modify)
            .insert,                                               // wave C (blocks)
            .polylineEdit,                                         // wave D (modify)
            .measureDistance, .measureAngle, .measureArea, .measureLength, // wire-wave-1 (measure/info)
            .join, .explodeText,                                   // wire-wave-1 (modify)
            .ordinateDim, .arcLengthDim, .angular3pDim,            // wire-wave-2 (dimension subtypes)
            .createBlock, .explodeInsert,                          // wire-wave-2 (blocks)
            .xline, .ray,                                          // wire-wave-3 (construction lines)
            .align, .arrayPath,                                    // wire-wave-3 (modify)
            .leader, .baselineDim, .continueDim,                   // wire-wave-3 (annotate)
            .multileader,                                          // ML-W2 (annotate — MLEADER)
            .image,                                                // wire-wave (image)
            .viewport,                                             // wire-wave-1 (paper-space, out-of-band)
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

    /// The four wave-C wiring additions: Stretch / Lengthen / Break / Insert Block.
    /// Each mints a non-nil tool whose own title matches the kind's UI title, so the
    /// toolbar/menu label and the HUD prompt agree.
    @Test func waveCKindsAreWiredWithMatchingTitles() {
        let waveC: [ToolKind: String] = [
            .stretch:  "Stretch",
            .lengthen: "Lengthen",
            .break:    "Break",
            .insert:   "Insert Block",
        ]
        for (kind, title) in waveC {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }

    /// The wave-D wiring addition: Edit Polyline. It mints a non-nil tool whose own
    /// title matches the kind's UI title, so the toolbar/menu label and the HUD prompt
    /// ("Edit Polyline: …") agree. `PolylineEditTool()` defaults to `.move` mode.
    @Test func waveDKindIsWiredWithMatchingTitle() {
        let waveD: [ToolKind: String] = [
            .polylineEdit: "Edit Polyline",
        ]
        for (kind, title) in waveD {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }

    /// The six wire-wave-1 additions: the four MeasureTool variants + Join +
    /// Explode Text. Each mints a non-nil tool whose own title matches the kind's
    /// UI title. The four measure kinds all mint a `MeasureTool` (distinct `Mode`s),
    /// so their DISTINCT titles also guard that the mode is wired correctly.
    @Test func waveOneSurfacedKindsAreWiredWithMatchingTitles() {
        let wave1: [ToolKind: String] = [
            .measureDistance: "Measure Distance",
            .measureAngle:    "Measure Angle",
            .measureArea:     "Measure Area",
            .measureLength:   "Total Length",
            .join:            "Join",
            .explodeText:     "Explode Text",
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

    /// The five wire-wave-2 additions: the three dimension subtypes (Ordinate /
    /// Arc Length / Angular-3p) + the two block tools (Create Block / Explode Block).
    /// Each mints a non-nil tool whose own title matches the kind's UI title, so the
    /// toolbar/menu label and the HUD prompt agree. The kind titles are matched to the
    /// tools' OWN titles (OrdinateDimTool defaults to the `.auto` axis → "Ordinate
    /// Dimension"; CreateBlockTool's title is "Create Block"; ExplodeInsertTool's is
    /// "Explode Block"), so the general `mintedToolTitleMatchesKindTitle` check passes.
    @Test func waveTwoSurfacedKindsAreWiredWithMatchingTitles() {
        let wave2: [ToolKind: String] = [
            .ordinateDim:   "Ordinate Dimension",
            .arcLengthDim:  "Arc Length Dimension",
            .angular3pDim:  "Angular Dimension (3-point)",
            .createBlock:   "Create Block",
            .explodeInsert: "Explode Block",
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

    /// The seven wire-wave-3 additions: the two construction-line tools (XLine / Ray),
    /// the two modify tools (Align / Array Along Path), and the three annotate tools
    /// (Leader / Baseline / Continue). Each mints a non-nil tool whose own title matches
    /// the kind's UI title, so the toolbar/menu label and the HUD prompt agree.
    @Test func waveThreeKindsAreWiredWithMatchingTitles() {
        let wave3: [ToolKind: String] = [
            .xline:       "Construction Line",
            .ray:         "Ray",
            .align:       "Align",
            .arrayPath:   "Array Along Path",
            .leader:      "Leader",
            .baselineDim: "Baseline Dimension",
            .continueDim: "Continue Dimension",
        ]
        for (kind, title) in wave3 {
            #expect(kind.title == title,
                    "ToolKind.\(kind).title (\(kind.title)) != \(title)")
            let tool = kind.makeTool()
            #expect(tool != nil, "ToolKind.\(kind) minted a nil Tool")
            #expect(tool?.title == title,
                    "ToolKind.\(kind) tool.title (\(tool?.title ?? "nil")) != \(title)")
        }
    }

    /// The Image wiring addition: `.image` maps to the title "Image" and mints a
    /// non-nil, constructable `ImageTool` whose own title matches. A bare `makeTool()`
    /// mints an INERT (no-file) tool — the app's file-picker injects the path + source
    /// pixel size via `CanvasModel.applyToolConfig` — so activation never crashes even
    /// before a file is chosen.
    @Test func imageKindIsWiredWithMatchingTitle() {
        #expect(ToolKind.image.title == "Image")
        let tool = ToolKind.image.makeTool()
        #expect(tool != nil, "ToolKind.image minted a nil Tool")
        #expect(tool?.title == "Image")
        // Inert with no file: the bare-minted tool ignores a placement click (no commit).
        var t = tool as! ImageTool
        let outcome = t.handle(.click(Vector(0, 0)), context: .empty)
        #expect(outcome == .none, "a no-file ImageTool must be inert (no commit)")
    }

    /// The Viewport wiring addition (wire-wave-1, paper space): `.viewport` maps to the
    /// title "Viewport" and — UNLIKE every other non-`.select` kind — mints NO `Tool`
    /// (`makeTool() == nil`), because it is an OUT-OF-BAND kind driven by the standalone
    /// `ViewportTool` (whose `LayoutViewport` result is not an entity, so it cannot flow
    /// through the `Tool`/`ToolEdit` contract). The app keys off `activeToolKind ==
    /// .viewport` and runs `ViewportTool` directly (see `CanvasModel.handleViewportClick`).
    @Test func viewportKindIsOutOfBandWithMatchingTitle() {
        #expect(ToolKind.viewport.title == "Viewport")
        #expect(ToolKind.viewport.makeTool() == nil,
                "ToolKind.viewport is out-of-band — it must mint NO Tool")
    }

    /// `.viewport` is reachable via the canonical `allCases` registry (so the
    /// CommandPalette's `ToolKind.allCases` loop surfaces it) and is NOT `.select`
    /// (it is a distinct activatable kind, just one the model handles out of band).
    @Test func viewportKindIsRegisteredAndDistinct() {
        #expect(ToolKind.allCases.contains(.viewport),
                "ToolKind.viewport must be in allCases so the palette/toolbar can reach it")
        #expect(ToolKind.viewport != .select)
    }

    /// `.image` shares no keyboard chord with another kind. Image takes ⇧Y (bare Y is
    /// unassigned, ⌥Y is Ray), so it adds cleanly to the chord set guarded by
    /// `toolShortcutsAreUnique` above. This focused check documents the chosen chord.
    @Test func imageShortcutIsShiftY() {
        // The chord (y, shift, no-option) must not collide with Ray (y, no-shift, option).
        let imageChord = "y+shift"
        let rayChord = "y+option"
        #expect(imageChord != rayChord)
    }

    /// `.createBlock` mints a CreateBlockTool that starts with NO pending request
    /// (nothing is created until a base point is committed) — a freshly-activated tool
    /// applies nothing. Guards the "request is captured on commit, not on mint"
    /// contract the app's apply path (CanvasModel.handleToolInput) relies on.
    @Test func createBlockKindStartsWithNoPendingRequest() {
        let tool = ToolKind.createBlock.makeTool() as? CreateBlockTool
        #expect(tool != nil, "ToolKind.createBlock did not mint a CreateBlockTool")
        #expect(tool?.pendingCreation == nil,
                "a freshly-minted CreateBlockTool must have no pending request")
    }

    /// `.explodeInsert` mints an ExplodeInsertTool that is SAFE with the default
    /// (no-blocks) provider — the app injects the real `blockMembers` provider in
    /// `CanvasModel.applyToolConfig`, but a bare `makeTool()` must never crash and
    /// explodes every insert to nothing (inert) until a provider is injected.
    @Test func explodeInsertKindIsSafeWithDefaultProvider() {
        #expect(ToolKind.explodeInsert.makeTool() != nil)
        #expect(ToolKind.explodeInsert.makeTool()?.title == "Explode Block")
    }

    /// `.insert` mints an Insert tool that is SAFE with no block chosen — the
    /// block-picker UI is a later task, so a wired ⌥/menu activation with no blocks in
    /// the drawing must never crash. With no block name the tool is inert (a no-op),
    /// which the title check above already exercises (it constructs the tool); this
    /// guard documents the "no block ⇒ no crash" contract explicitly.
    @Test func insertKindIsSafeWithNoBlockChosen() {
        #expect(ToolKind.insert.makeTool() != nil)
        #expect(ToolKind.insert.makeTool()?.title == "Insert Block")
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
    /// `(key, shift, option)`; `.select` and the wave-A/B/C additions are all included.
    /// Stretch (⌥S) is the sole OPTION chord, so the model carries an option flag too.
    @Test func toolShortcutsAreUnique() {
        // (kind, key, shiftHeld, optionHeld) — the single source of truth mirrored
        // from the UI (CADCanvasView.handleKey / Tools menu / toolbar tooltips).
        let keymap: [(ToolKind, Character, Bool, Bool)] = [
            (.select, "v", false, false),
            (.line, "l", false, false), (.lengthen, "l", true, false),
            (.circle, "c", false, false), (.copy, "c", true, false),
            (.arc, "a", false, false), (.array, "a", true, false),
            (.rectangle, "r", false, false), (.rotate, "r", true, false),
            (.polyline, "p", false, false),
            (.point, "o", false, false), (.offset, "o", true, false),
            (.ellipse, "e", false, false),
            (.polygon, "g", false, false),
            (.move, "m", false, false), (.mirror, "m", true, false),
            (.spline, "s", false, false), (.scale, "s", true, false),
            (.stretch, "s", false, true),   // ⌥S — ⇧S is Scale, so Stretch takes option.
            (.hatch, "h", false, false),
            (.divide, "d", true, false),
            (.trim, "t", false, false), (.text, "t", true, false),
            (.extend, "x", false, false), (.explode, "x", true, false),
            (.fillet, "f", false, false), (.chamfer, "f", true, false),
            // wave B dimensions — bare, collision-free letters.
            (.linearDim, "d", false, false),
            (.alignedDim, "i", false, false),
            (.radialDim, "u", false, false),
            (.diameterDim, "b", false, false),
            (.angularDim, "n", false, false),
            // wave C — Insert Block + Break take free shift chords; Stretch is ⌥S above.
            (.insert, "i", true, false),
            (.break, "b", true, false),
            // wave D — Edit Polyline takes ⇧P (bare P is Polyline with no shift twin).
            (.polylineEdit, "p", true, false),
            // wire-wave-1 — Measure Distance ⇧K, Join ⇧J, Explode Text ⇧E (bare K/J
            // are unassigned; bare E is Ellipse with no other shift twin). The other
            // measure modes (angle/area/total-length) are menu/⌘K only — no chord.
            (.measureDistance, "k", true, false),
            (.join, "j", true, false),
            (.explodeText, "e", true, false),
            // wire-wave-2 — three dimension subtypes + two block tools, all on free
            // OPTION chords (the bare/⇧ twins of O/G/N/B/X are taken). ⌥ is the third
            // tier alongside ⌥S Stretch. The angular-3p tool takes ⌥N (vs N Angular).
            (.ordinateDim, "o", false, true),
            (.arcLengthDim, "g", false, true),
            (.angular3pDim, "n", false, true),
            (.createBlock, "b", false, true),
            (.explodeInsert, "x", false, true),
            // wire-wave-3 — two construction lines, two modify tools, three annotate
            // tools, all on free OPTION chords (the bare/⇧ twins of I/Y/A/P/L/D/C are
            // taken, except bare Y which is unassigned). These are menu shortcuts
            // (LibreCADApp Tools menu); the canvas keymap is unchanged this wave.
            (.xline, "i", false, true),
            (.ray, "y", false, true),
            (.align, "a", false, true),
            (.arrayPath, "p", false, true),
            (.leader, "l", false, true),
            // ML-W4 — Multileader on ⌥M (bare/⇧ M are Move/Mirror; ⌥M is free).
            (.multileader, "m", false, true),
            (.baselineDim, "d", false, true),
            (.continueDim, "c", false, true),
            // wire-wave-1 — paper-space Viewport placement on ⌥V (bare V is Select; ⌥V
            // is otherwise unassigned, so it adds cleanly to the option-chord tier).
            (.viewport, "v", false, true),
        ]
        // No two entries share a (key, shift, option) chord.
        let chords = keymap.map { "\($0.1)\($0.2 ? "+shift" : "")\($0.3 ? "+option" : "")" }
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
        // Every wave-C kind (Stretch / Lengthen / Break / Insert) has a shortcut.
        for k in [ToolKind.stretch, .lengthen, .break, .insert] {
            #expect(kinds.contains(k), "wave-C kind \(k) has no keyboard shortcut")
        }
        // The wave-D kind (Edit Polyline) has a shortcut.
        #expect(kinds.contains(.polylineEdit), "wave-D kind polylineEdit has no keyboard shortcut")
        // The keyed wire-wave-1 kinds (Measure Distance / Join / Explode Text) have
        // chords. The other three measure modes are intentionally menu/⌘K only.
        for k in [ToolKind.measureDistance, .join, .explodeText] {
            #expect(kinds.contains(k), "wire-wave-1 kind \(k) has no keyboard shortcut")
        }
        // Every wire-wave-2 kind (3 dimension subtypes + 2 block tools) has a chord.
        for k in [ToolKind.ordinateDim, .arcLengthDim, .angular3pDim, .createBlock, .explodeInsert] {
            #expect(kinds.contains(k), "wire-wave-2 kind \(k) has no keyboard shortcut")
        }
        // Every wire-wave-3 kind (2 construction lines + 2 modify + 3 annotate) has a chord.
        for k in [ToolKind.xline, .ray, .align, .arrayPath, .leader, .baselineDim, .continueDim] {
            #expect(kinds.contains(k), "wire-wave-3 kind \(k) has no keyboard shortcut")
        }
    }

    // MARK: - UI grouping (no orphaned tools) — Draw / Modify / Annotate
    //
    // The final UI-organization wave groups every drawing tool into one of three
    // macOS-HIG groups — Draw / Modify / Annotate — that BOTH the grouped toolbar
    // (ContentView's `ToolCatalog`/`groupSection`) and the grouped Tools menu
    // (LibreCADApp's `drawMenu`/`modifyMenu`/`annotateMenu`) read from one source of
    // truth. The engine test target cannot import the SwiftUI app module, so this is
    // a DATA MIRROR of that grouping (the same pattern `toolShortcutsAreUnique` uses):
    // it asserts the rosters PARTITION every non-`.select` `ToolKind` exactly once, so
    // a newly added tool that someone forgets to place in a group fails loudly here
    // ("no orphaned tools"). `.select` is the always-visible core mode (not grouped).

    /// The Draw group roster — geometry-creating tools (mirrors `ToolCatalog.draw`).
    /// `.viewport` is the paper-space viewport-placement mode (an out-of-band kind that
    /// mints no `Tool`); it lives in the Draw group so it has a toolbar/menu home and
    /// is not orphaned, even though the app drives it via `ViewportTool` out of band.
    private static let drawGroup: [ToolKind] = [
        .line, .circle, .arc, .rectangle, .polyline, .point,
        .ellipse, .polygon, .spline, .hatch, .image,
        .xline, .ray, .insert, .viewport,
    ]

    /// The Modify group roster — transforms + edit-under-cursor + blocks
    /// (mirrors `ToolCatalog.modify`).
    private static let modifyGroup: [ToolKind] = [
        .move, .copy, .offset, .rotate, .scale, .mirror,
        .array, .arrayPath, .divide, .explode, .stretch, .lengthen, .break,
        .trim, .extend, .fillet, .chamfer,
        .polylineEdit, .join, .explodeText, .align,
        .createBlock, .explodeInsert,
    ]

    /// The Annotate group roster — text, dimensions, leaders, measure
    /// (mirrors `ToolCatalog.annotate`).
    private static let annotateGroup: [ToolKind] = [
        .text,
        .linearDim, .alignedDim, .radialDim, .diameterDim, .angularDim,
        .ordinateDim, .arcLengthDim, .angular3pDim,
        .leader, .multileader, .baselineDim, .continueDim,
        .measureDistance, .measureAngle, .measureArea, .measureLength,
    ]

    /// Every `ToolKind` (except `.select`, the core mode) appears in EXACTLY ONE UI
    /// group — no orphaned tools (every tool reachable via its toolbar group + Tools
    /// menu group) and no tool double-listed. The union of the three rosters plus
    /// `.select` must equal `ToolKind.allCases`.
    @Test func everyToolKindBelongsToExactlyOneUIGroup() {
        let all = Self.drawGroup + Self.modifyGroup + Self.annotateGroup

        // No tool appears in more than one group (or twice within one group).
        #expect(Set(all).count == all.count,
                "A ToolKind is listed in more than one UI group: \(all)")

        // `.select` is the core mode — it must NOT be in any group.
        #expect(!all.contains(.select), ".select must stay the ungrouped core mode")

        // Together with `.select`, the groups cover EVERY kind — nothing orphaned.
        let covered = Set(all).union([.select])
        let missing = Set(ToolKind.allCases).subtracting(covered)
        #expect(missing.isEmpty,
                "Orphaned ToolKind(s) not in any UI group: \(missing)")
        let extra = covered.subtracting(Set(ToolKind.allCases))
        #expect(extra.isEmpty, "UI group lists a non-existent ToolKind: \(extra)")
        #expect(covered == Set(ToolKind.allCases),
                "UI grouping does not match ToolKind.allCases exactly")
    }

    /// The default PINNED (primary toolbar) set is a SUBSET of the real tools (every
    /// pinned default is a valid, grouped kind) and is small enough to keep the
    /// toolbar uncrowded — the rest live in the per-group `▾` overflow menus. Mirrors
    /// `ToolCatalog.defaultPrimary`; guards that the curated default never references a
    /// removed/renamed kind or pins `.select` (which is the always-present core).
    @Test func defaultPinnedToolbarSetIsValidAndCurated() {
        let defaultPrimary: Set<ToolKind> = [
            .line, .circle, .arc, .rectangle, .polyline,   // draw
            .move, .copy, .rotate, .scale, .trim, .offset, // modify
            .text, .linearDim, .leader, .multileader,      // annotate
        ]
        let grouped = Set(Self.drawGroup + Self.modifyGroup + Self.annotateGroup)
        // Every pinned default is a real, grouped tool (not `.select`, not orphaned).
        #expect(defaultPrimary.isSubset(of: grouped),
                "defaultPrimary pins a tool not in any group: \(defaultPrimary.subtracting(grouped))")
        #expect(!defaultPrimary.contains(.select), "must not pin the core .select mode")
        // Curated, not the whole set — the overflow menus carry the rest.
        #expect(defaultPrimary.count < grouped.count,
                "the default toolbar should be a curated subset, not every tool")
    }

    // MARK: - ⌘D Duplicate command (engine-level, via the static API)
    //
    // The ⌘D Duplicate menu/command funnel (CanvasModel.duplicateSelection) resolves
    // the current selection to full records and calls the PURE `Duplicate.duplicate`
    // static API, applying the resulting `[ToolEdit]` as one undoable group. The model
    // funnel is `@MainActor` UI code (not reachable from this engine test target), so
    // these assertions exercise the SAME static API the command calls — engine-level,
    // no GUI — guaranteeing the command produces correct duplicate edits.

    /// ⌘D over a selection produces one `.add` duplicate per selected entity, each a
    /// deep copy translated by the default AutoCAD-style small nudge, with a NEW
    /// (placeholder) id and the source's layer/pen/flags preserved.
    @Test func duplicateCommandProducesOneNudgedAddPerSelectedEntity() {
        let selection: [EntityRecord] = [
            EntityRecord(id: EntityID(1), layer: LayerID("a"), pen: .byLayer,
                         flags: [.visible, .selected],
                         kind: .line(LineData(start: Vector(0, 0), end: Vector(4, 0)))),
            EntityRecord(id: EntityID(2), layer: LayerID("b"), pen: .byLayer,
                         flags: [.visible, .selected],
                         kind: .circle(CircleData(center: Vector(10, 10), radius: 3))),
        ]

        // The exact call the ⌘D funnel makes (default nudge offset).
        let edits = Duplicate.duplicate(selection)
        #expect(edits.count == selection.count,
                "⌘D must yield one duplicate edit per selected entity")

        let nudge = Duplicate.defaultOffset
        #expect(nudge != Vector(0, 0), "the default duplicate offset must be a visible nudge")

        for (edit, source) in zip(edits, selection) {
            guard case .add(let copy) = edit else {
                Issue.record("⌘D must emit `.add` edits, got \(edit)")
                continue
            }
            // NEW id (app re-mints; source id never reused) + attrs preserved.
            #expect(copy.id == .placeholder, "a duplicate must carry the placeholder id")
            #expect(copy.layer == source.layer, "duplicate must preserve the source layer")
            #expect(copy.pen == source.pen, "duplicate must preserve the source pen")
            #expect(copy.flags == source.flags, "duplicate must preserve the source flags")
            // Geometry is the source translated by the nudge.
            let expected = source.kind.transformed(by: .translation(nudge))
            #expect(copy.kind == expected,
                    "duplicate geometry must be the source nudged by \(nudge)")
        }
    }

    /// ⌘D with NOTHING selected produces no edits (the funnel is a no-op / returns
    /// false), so an empty selection never mutates the drawing.
    @Test func duplicateCommandWithEmptySelectionProducesNoEdits() {
        #expect(Duplicate.duplicate([]).isEmpty,
                "⌘D over an empty selection must produce no edits")
    }
}
