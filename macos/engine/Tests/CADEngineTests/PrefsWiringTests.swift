//
//  PrefsWiringTests.swift
//  CADEngineTests
//
//  Tests for WIRING the application Preferences (audit G7 — `AppSettingsView.swift`)
//  to their read-sites. The Preferences VIEW + the pure `AppSettings` model are
//  already covered by `AppSettingsTests`; THIS suite covers the resolve-and-apply
//  glue each read-site uses, with the same contract everywhere:
//
//    • a STORED value is honored, and
//    • an UNSET key falls back to today's default (no behavior change for a user
//      who never opened Preferences).
//
//  Read-sites exercised (all via the `_Shared*.swift` symlinks, no GUI touched):
//    1. Appearance ▸ canvas background + grid color  → `CanvasTheme` hex parse +
//       `overridden(_:backgroundHex:gridHex:)` (empty hex = follow theme).
//    2. Rendering ▸ antialias / LOD / default width   → `RenderPrefs` resolution
//       (mm→half-width px, LOD→tessellation scale, AA floor), incl. `.fromDefaults`.
//    3. General ▸ default units / template / autosave → `PrefsSeeding` (seed a NEW
//       empty payload's `$INSUNITS`, leave an opened drawing alone; pref-id→template
//       map).
//    4. Text ▸ default font + height                  → `TextTool.applyAppDefaults`
//       drives a new `TextTool()`'s defaults, with the empty/non-positive fallbacks.
//
//  The Snapping defaults pref is DELIBERATELY not wired here — its read-site
//  (`CanvasModel`) is owned by a concurrent agent; this suite leaves it as the
//  documented follow-up.
//
//  Suite/type names are domain-namespaced (CONVENTIONS.md) to avoid the parallel
//  test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import simd
@testable import CADEngine

// MARK: - Appearance: canvas background + grid color overrides (CanvasTheme)

@Suite("Prefs wiring — Appearance canvas colors")
struct PrefsWiringAppearanceTests {

    @Test("hex parse: valid #RRGGBB / RRGGBB → opaque rgba")
    func hexParse() {
        let red = CanvasTheme.rgba(fromAppHex: "#FF0000")
        #expect(red == SIMD4<Float>(1, 0, 0, 1))
        // Without the leading '#', and lower-case, still parses identically.
        #expect(CanvasTheme.rgba(fromAppHex: "00ff00") == SIMD4<Float>(0, 1, 0, 1))
        let mid = CanvasTheme.rgba(fromAppHex: "#808080")
        #expect(mid != nil)
        #expect(abs((mid?.x ?? 0) - 128.0 / 255.0) < 1e-5)
    }

    @Test("hex parse: empty / malformed → nil (the 'follow theme' sentinel)")
    func hexParseInvalid() {
        #expect(CanvasTheme.rgba(fromAppHex: "") == nil)           // unset = follow theme
        #expect(CanvasTheme.rgba(fromAppHex: "   ") == nil)
        #expect(CanvasTheme.rgba(fromAppHex: "#FFF") == nil)       // wrong length
        #expect(CanvasTheme.rgba(fromAppHex: "#GGGGGG") == nil)    // non-hex
        #expect(CanvasTheme.rgba(fromAppHex: "12345") == nil)
    }

    @Test("unset overrides leave the theme chrome byte-for-byte unchanged")
    func unsetKeepsTheme() {
        let base = CanvasTheme.dark
        let out = CanvasTheme.overridden(base, backgroundHex: "", gridHex: "")
        #expect(out.clearColor.red == base.clearColor.red)
        #expect(out.clearColor.green == base.clearColor.green)
        #expect(out.clearColor.blue == base.clearColor.blue)
        #expect(out.grid == base.grid)
        #expect(out.gridAxis == base.gridAxis)
        // Non-overridden accents are always untouched.
        #expect(out.selection == base.selection)
        #expect(out.snap == base.snap)
    }

    @Test("a set background override replaces the clear color; grid override re-hues the grid keeping its alpha")
    func setOverrides() {
        let base = CanvasTheme.dark
        let out = CanvasTheme.overridden(base, backgroundHex: "#101820", gridHex: "#00FF00")
        // Background fully replaced.
        #expect(abs(out.clearColor.red - 16.0 / 255.0) < 1e-5)
        #expect(abs(out.clearColor.green - 24.0 / 255.0) < 1e-5)
        #expect(abs(out.clearColor.blue - 32.0 / 255.0) < 1e-5)
        // Grid hue replaced, but the faint theme alpha is preserved (a guide, not a slab).
        #expect(out.grid.x == 0)
        #expect(out.grid.y == 1)
        #expect(out.grid.z == 0)
        #expect(out.grid.w == base.grid.w)
        // Axis takes the same hue at the theme axis alpha.
        #expect(out.gridAxis.x == 0 && out.gridAxis.y == 1 && out.gridAxis.z == 0)
        #expect(out.gridAxis.w == base.gridAxis.w)
    }

    @Test("only the background override is set: grid stays the theme grid")
    func partialOverride() {
        let base = CanvasTheme.light
        let out = CanvasTheme.overridden(base, backgroundHex: "#FFFFFF", gridHex: "")
        #expect(out.clearColor.red == 1.0)
        #expect(out.grid == base.grid)   // grid untouched (empty hex)
    }
}

// MARK: - Rendering: antialias / LOD / default line width (RenderPrefs)

@Suite("Prefs wiring — Rendering")
struct PrefsWiringRenderingTests {

    @Test(".standard equals today's defaults (AA on, high LOD, hairline width)")
    func standardMatchesDefaults() {
        let p = RenderPrefs.standard
        #expect(p.antialias == AppSettings.Default.antialias)
        #expect(p.quality == AppSettings.Default.renderQuality)
        #expect(p.defaultLineWidthMM == AppSettings.Default.defaultLineWidthMM)
        // 0 mm width → the renderer's hairline default half-width, unchanged.
        #expect(p.lineHalfWidthPx(backingScale: 2) == RendererGeometry.defaultHalfWidthPx)
        #expect(p.tessellationToleranceScale == 1.0)   // high = finest
    }

    @Test("0 mm width keeps the hairline default at any backing scale")
    func zeroWidthIsHairline() {
        let p = RenderPrefs(antialias: true, quality: .high, defaultLineWidthMM: 0)
        #expect(p.lineHalfWidthPx(backingScale: 1) == RendererGeometry.defaultHalfWidthPx)
        #expect(p.lineHalfWidthPx(backingScale: 2) == RendererGeometry.defaultHalfWidthPx)
    }

    @Test("a positive mm width converts mm→points→device px (half), scaled by backing")
    func positiveWidthScales() {
        // 1 pt = mmPerPoint mm; choose a width of exactly 2 points so the math is clean.
        let twoPointsMM = Double(2 * RenderPrefs.mmPerPoint)
        let p = RenderPrefs(antialias: true, quality: .high, defaultLineWidthMM: twoPointsMM)
        // At backing scale 2: 2pt * 2 = 4 device px stroke → half-width 2.0.
        #expect(abs(p.lineHalfWidthPx(backingScale: 2) - 2.0) < 1e-4)
        // At backing scale 1: 2pt * 1 = 2 device px → half-width 1.0.
        #expect(abs(p.lineHalfWidthPx(backingScale: 1) - 1.0) < 1e-4)
        // Half-width never drops below the hairline default.
        #expect(p.lineHalfWidthPx(backingScale: 2) >= RendererGeometry.defaultHalfWidthPx)
    }

    @Test("antialias OFF floors the half-width to a crisp 0.5px (1px hard stroke)")
    func noAAFloor() {
        let p = RenderPrefs(antialias: false, quality: .high, defaultLineWidthMM: 0)
        // The hairline default (0.75) is already ≥ 0.5, so it is kept...
        #expect(p.lineHalfWidthPx(backingScale: 2) == max(0.5, RendererGeometry.defaultHalfWidthPx))
        #expect(p.lineHalfWidthPx(backingScale: 2) >= 0.5)
    }

    @Test("LOD tiers map to a coarsening tessellation tolerance scale")
    func lodScales() {
        #expect(RenderPrefs(antialias: true, quality: .high, defaultLineWidthMM: 0).tessellationToleranceScale == 1.0)
        #expect(RenderPrefs(antialias: true, quality: .medium, defaultLineWidthMM: 0).tessellationToleranceScale == 2.0)
        #expect(RenderPrefs(antialias: true, quality: .low, defaultLineWidthMM: 0).tessellationToleranceScale == 4.0)
        // Coarser LOD strictly increases the tolerance (fewer segments).
        let high = RenderPrefs(antialias: true, quality: .high, defaultLineWidthMM: 0)
        let low = RenderPrefs(antialias: true, quality: .low, defaultLineWidthMM: 0)
        #expect(low.tessellationToleranceScale > high.tessellationToleranceScale)
    }

    @Test("fromDefaults: an empty UserDefaults resolves to .standard (today's behavior)")
    func fromDefaultsUnsetIsStandard() {
        let d = Self.scratchDefaults()
        let p = RenderPrefs.fromDefaults(d)
        #expect(p == RenderPrefs.standard)
    }

    @Test("fromDefaults: stored values are honored")
    func fromDefaultsHonorsStored() {
        let d = Self.scratchDefaults()
        d.set(false, forKey: AppSettings.Key.antialias)
        d.set(RenderQuality.low.rawValue, forKey: AppSettings.Key.renderQuality)
        d.set(0.5, forKey: AppSettings.Key.defaultLineWidthMM)
        let p = RenderPrefs.fromDefaults(d)
        #expect(p.antialias == false)
        #expect(p.quality == .low)
        #expect(p.defaultLineWidthMM == 0.5)
    }

    @Test("fromDefaults: a negative stored width is clamped to the 0 sentinel")
    func fromDefaultsClampsWidth() {
        let d = Self.scratchDefaults()
        d.set(-3.0, forKey: AppSettings.Key.defaultLineWidthMM)
        #expect(RenderPrefs.fromDefaults(d).defaultLineWidthMM == 0)
    }

    /// A throwaway, isolated `UserDefaults` suite so a test never reads/writes the
    /// real app domain (and each test starts empty).
    private static func scratchDefaults() -> UserDefaults {
        let name = "PrefsWiringRenderingTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}

// MARK: - General: new-document seeding (PrefsSeeding)

@Suite("Prefs wiring — General new-document seeding")
struct PrefsWiringSeedingTests {

    @Test("a fresh empty payload is detected; a payload with entities is not")
    func detectsNewEmpty() {
        #expect(PrefsSeeding.isNewEmptyPayload(.empty))
        let withEntity = DXFPayload(entities: [
            EntityRecord(id: .placeholder, kind: .point(PointData(position: Vector(0, 0))))])
        #expect(!PrefsSeeding.isNewEmptyPayload(withEntity))
    }

    @Test("a NEW empty payload is seeded with the preferred units")
    func seedsUnitsOnNew() {
        let seeded = PrefsSeeding.seededPayload(.empty, defaultUnitRaw: DrawingUnit.inch.rawValue)
        #expect(seeded.graphicVariables.unit == .inch)
        #expect(seeded.graphicVariables.has("$INSUNITS"))
    }

    @Test("an unknown stored unit code falls back to the default unit")
    func seedsFallbackUnit() {
        let seeded = PrefsSeeding.seededPayload(.empty, defaultUnitRaw: 999)
        #expect(seeded.graphicVariables.unit == AppSettings.Default.unit)
    }

    @Test("an OPENED drawing (has entities) is NOT re-seeded — its DXF header wins")
    func opensKeepHeader() {
        var gv = GraphicVariables()
        gv.unit = .meter
        let opened = DXFPayload(
            entities: [EntityRecord(id: .placeholder, kind: .point(PointData(position: Vector(0, 0))))],
            graphicVariables: gv)
        let out = PrefsSeeding.seededPayload(opened, defaultUnitRaw: DrawingUnit.inch.rawValue)
        #expect(out.graphicVariables.unit == .meter)   // unchanged
    }

    @Test("a new payload that ALREADY declares $INSUNITS is left alone")
    func respectsExistingUnits() {
        var gv = GraphicVariables()
        gv.unit = .centimeter
        let p = DXFPayload(graphicVariables: gv)
        let out = PrefsSeeding.seededPayload(p, defaultUnitRaw: DrawingUnit.inch.rawValue)
        #expect(out.graphicVariables.unit == .centimeter)
    }

    @Test("pref-id → template resource map: known ids map, blank/unknown → no template")
    func templateMap() {
        #expect(PrefsSeeding.templateResourceName(forPrefID: "a4_mm") == "Titleblock_A4_Metric")
        #expect(PrefsSeeding.templateResourceName(forPrefID: "letter_inch") == "Blank_Imperial")
        #expect(PrefsSeeding.templateResourceName(forPrefID: "iso_a3") == "Blank_Metric_A3")
        // "blank" (the default), empty, and anything unknown → no template.
        #expect(PrefsSeeding.templateResourceName(forPrefID: "blank") == nil)
        #expect(PrefsSeeding.templateResourceName(forPrefID: "") == nil)
        #expect(PrefsSeeding.templateResourceName(forPrefID: AppSettings.Default.template) == nil)
        #expect(PrefsSeeding.templateResourceName(forPrefID: "nonsense") == nil)
    }
}

// MARK: - Text: default font + height (TextTool.applyAppDefaults)

@Suite("Prefs wiring — Text defaults", .serialized)
struct PrefsWiringTextTests {

    @Test("applyAppDefaults makes a new TextTool author with the chosen font + height")
    func appliesDefaults() {
        TextTool.applyAppDefaults(fontStyleName: "Helvetica", height: 7)
        defer { TextTool.resetAppDefaults() }
        let tool = TextTool()
        #expect(tool.styleName == "Helvetica")
        #expect(tool.height == 7)
        // The runtime statics reflect the override.
        #expect(TextTool.defaultFontStyleName == "Helvetica")
        #expect(TextTool.defaultHeight == 7)
    }

    @Test("an empty font / non-positive height fall back to the built-in defaults")
    func clampsBadValues() {
        TextTool.applyAppDefaults(fontStyleName: "   ", height: 0)
        defer { TextTool.resetAppDefaults() }
        #expect(TextTool.defaultFontStyleName == TextTool.standardStyleName)
        #expect(TextTool.defaultHeight == TextTool.standardHeight)
        // A NaN/negative height also falls back.
        TextTool.applyAppDefaults(fontStyleName: "iso", height: -2)
        #expect(TextTool.defaultHeight == TextTool.standardHeight)
        #expect(TextTool.defaultFontStyleName == "iso")
    }

    @Test("reset restores the built-in fallbacks (no leak into other suites)")
    func resetRestores() {
        TextTool.applyAppDefaults(fontStyleName: "Courier", height: 12)
        TextTool.resetAppDefaults()
        #expect(TextTool.defaultFontStyleName == TextTool.standardStyleName)
        #expect(TextTool.defaultHeight == TextTool.standardHeight)
        let tool = TextTool()
        #expect(tool.styleName == TextTool.standardStyleName)
        #expect(tool.height == TextTool.standardHeight)
    }
}
