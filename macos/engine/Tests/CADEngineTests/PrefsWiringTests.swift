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

// MARK: - Snapping: default-snap-modes list completeness (#33)
//
// The Preferences ▸ Snapping "Default snap modes (new windows)" list
// (`AppSettingsView.SnapSettingRow.all`) must expose every snap bit that can be
// on-by-default — including perpendicular / tangent / parallel, which the packed mask
// fully supports — but must NOT expose `.free` (the always-on master fallback, not an
// opt-in default bit; `AppSettings.snapMode(fromMask:)` forces it on regardless).

@Suite("Prefs wiring — default snap modes list (#33)")
struct PrefsWiringSnapDefaultsTests {

    /// The set of bits the Preferences default-snap list offers.
    private var listedModes: [SnapMode] { SnapSettingRow.all.map(\.mode) }

    @Test("perpendicular / tangent / parallel are offered as default bits")
    func includesAdvancedBits() {
        #expect(listedModes.contains(.perpendicular))
        #expect(listedModes.contains(.tangent))
        #expect(listedModes.contains(.parallel))
    }

    @Test(".free is NOT offered (it is the always-on master, not a default bit)")
    func excludesFree() {
        #expect(!listedModes.contains(.free))
    }

    @Test("the classic standard bits remain offered (no regression)")
    func keepsStandardBits() {
        for m in [SnapMode.endpoint, .middle, .center, .intersection,
                  .onEntity, .nearest, .grid] {
            #expect(listedModes.contains(m))
        }
    }

    @Test("every listed bit is a single, distinct SnapMode (no dupes / empties)")
    func bitsAreDistinctAndNonEmpty() {
        for m in listedModes { #expect(!m.isEmpty) }
        // No bit appears twice in the list.
        #expect(Set(listedModes.map(\.rawValue)).count == listedModes.count)
    }

    @Test("toggling a listed bit into the mask round-trips through snapMode(fromMask:)")
    func maskRoundTrip() {
        // Build a mask from perpendicular+tangent+parallel and read it back. `.free`
        // is forced on by `snapMode(fromMask:)`, so it is present in the result even
        // though it was never in the source mask (and never in the list).
        var set: SnapMode = []
        for m in [SnapMode.perpendicular, .tangent, .parallel] { set.insert(m) }
        let resolved = AppSettings.snapMode(fromMask: AppSettings.mask(from: set))
        #expect(resolved.contains(.perpendicular))
        #expect(resolved.contains(.tangent))
        #expect(resolved.contains(.parallel))
        #expect(resolved.contains(.free))   // always-on master, re-added on read
    }
}

// MARK: - Live-apply notifications: open windows refresh instantly (#29/#30 residual)
//
// Changing a canvas-appearance (background / grid) or rendering (antialias / LOD / line
// width) preference must reach ALREADY-OPEN windows immediately. The seam is a pair of
// dedicated app-level notifications `AppSettingsView` POSTS from the relevant
// `@AppStorage` `.onChange` handlers and the canvas Coordinator OBSERVES. The post/observe
// wiring itself is View-layer (a live `MTKView` + `CADCanvasController`, not reachable
// headlessly), so this suite pins the testable CONTRACT: the two `Notification.Name`
// constants exist, are stable, distinct, and a post round-trips through `NotificationCenter`
// to a subscribed observer (proving the channel both sides use is the same one).

@Suite("Prefs wiring — live-apply notifications (#29/#30)")
struct PrefsWiringLiveApplyTests {

    @Test("the two live-apply notification names are stable + distinct")
    func namesStableAndDistinct() {
        // Stable raw strings (an accidental rename would silently break the live-apply
        // channel between AppSettingsView's post and the canvas Coordinator's observer).
        #expect(Notification.Name.lcCanvasAppearanceDidChange.rawValue == "lc.canvasAppearanceDidChange")
        #expect(Notification.Name.lcRenderPrefsDidChange.rawValue == "lc.renderPrefsDidChange")
        // The appearance + rendering channels are SEPARATE (an appearance change must not
        // wake the render-prefs observer and vice-versa).
        #expect(Notification.Name.lcCanvasAppearanceDidChange != Notification.Name.lcRenderPrefsDidChange)
    }

    @Test("posting .lcCanvasAppearanceDidChange reaches a subscribed observer")
    func appearancePostRoundTrips() {
        let center = NotificationCenter()
        var received = 0
        let token = center.addObserver(
            forName: .lcCanvasAppearanceDidChange, object: nil, queue: nil
        ) { _ in received += 1 }
        defer { center.removeObserver(token) }
        center.post(name: .lcCanvasAppearanceDidChange, object: nil)
        // A DIFFERENT name must NOT trigger this observer (channels are isolated).
        center.post(name: .lcRenderPrefsDidChange, object: nil)
        #expect(received == 1)
    }

    @Test("posting .lcRenderPrefsDidChange reaches a subscribed observer")
    func renderPostRoundTrips() {
        let center = NotificationCenter()
        var received = 0
        let token = center.addObserver(
            forName: .lcRenderPrefsDidChange, object: nil, queue: nil
        ) { _ in received += 1 }
        defer { center.removeObserver(token) }
        center.post(name: .lcRenderPrefsDidChange, object: nil)
        center.post(name: .lcCanvasAppearanceDidChange, object: nil)
        #expect(received == 1)
    }
}

// MARK: - Design tokens: field-width tiers (#40)
//
// The settings views adopted `DS.Field.{xy,narrow,std,wide}` in place of the retired
// 56/80/90/110/160 grab-bag. These guard the tier SYSTEM the views now reference: the
// documented values + that the tiers are strictly ordered & distinct (a regression to
// the grab-bag would collapse or reorder them).

@Suite("Prefs wiring — DS.Field width tiers (#40)")
struct PrefsWiringFieldTierTests {

    @Test("the four tiers hold their documented widths")
    func tierValues() {
        #expect(DS.Field.xy == 56)       // documented paired-field exception
        #expect(DS.Field.narrow == 72)
        #expect(DS.Field.std == 96)
        #expect(DS.Field.wide == 130)
    }

    @Test("tiers are strictly increasing (xy < narrow < std < wide) and distinct")
    func tiersOrdered() {
        #expect(DS.Field.xy < DS.Field.narrow)
        #expect(DS.Field.narrow < DS.Field.std)
        #expect(DS.Field.std < DS.Field.wide)
        let all = [DS.Field.xy, DS.Field.narrow, DS.Field.std, DS.Field.wide]
        #expect(Set(all).count == all.count)
    }
}

// MARK: - Paper: persisted size/orientation round-trip into the picker (#31)
//
// `DocumentSettingsView.loadFromStore()` recovers the picker's PaperSize + orientation
// from the persisted `PageSetup.paperSize` (a points rect with orientation applied) by:
//   points → mm → `PrintLayout.nearestStandardPage(...).name` (→ `PaperSize.named`),
//   landscape ⇔ width > height.
// `PaperSize.named` is an app-only (non-symlinked) one-liner over the canonical name,
// so this exercises the symlink-safe CORE: that the points→mm→nearestStandardPage map
// recovers the right canonical name + orientation for each standard sheet, which is the
// part that was missing (loadFromStore previously read back only margin + scale, so the
// picker always re-showed A4/portrait — finding #31).

@Suite("Prefs wiring — paper size/orientation round-trip (#31)")
struct PrefsWiringPaperRoundTripTests {

    /// The standard sheets the picker offers, with their portrait mm dimensions —
    /// mirrors `PaperSize.sizeMM` (kept here as plain values, app enum not symlinked).
    private static let sheets: [(name: String, wMM: Double, hMM: Double)] = [
        ("A4", 210, 297), ("A3", 297, 420), ("A2", 420, 594),
        ("A1", 594, 841), ("A0", 841, 1189),
        ("Letter", 215.9, 279.4), ("Legal", 215.9, 355.6), ("Tabloid", 279.4, 431.8),
    ]

    /// Build the persisted points rect the store would hold for a sheet in an
    /// orientation, exactly as `PaperSettingsTab.paperPointSize` does.
    private func storedRect(wMM: Double, hMM: Double, landscape: Bool) -> SizePt {
        let wpt = pointsFromMM(wMM), hpt = pointsFromMM(hMM)
        return landscape ? SizePt(width: hpt, height: wpt)
                         : SizePt(width: wpt, height: hpt)
    }

    @Test("each standard sheet round-trips its canonical name in PORTRAIT")
    func portraitRoundTrip() {
        for s in Self.sheets {
            let rect = storedRect(wMM: s.wMM, hMM: s.hMM, landscape: false)
            // loadFromStore's back-map: points → mm → nearestStandardPage.
            let widthMM = rect.width * 25.4 / 72.0
            let heightMM = rect.height * 25.4 / 72.0
            let std = PrintLayout.nearestStandardPage(widthMM: widthMM, heightMM: heightMM)
            #expect(std.name == s.name)
            #expect(std.isExact)                         // an exact standard match
            #expect(!(rect.width > rect.height))         // portrait: width ≤ height
        }
    }

    @Test("each standard sheet round-trips its canonical name in LANDSCAPE")
    func landscapeRoundTrip() {
        for s in Self.sheets {
            let rect = storedRect(wMM: s.wMM, hMM: s.hMM, landscape: true)
            let widthMM = rect.width * 25.4 / 72.0
            let heightMM = rect.height * 25.4 / 72.0
            // The matcher is orientation-normalized, so the name still matches…
            let std = PrintLayout.nearestStandardPage(widthMM: widthMM, heightMM: heightMM)
            #expect(std.name == s.name)
            // …and orientation is recovered from the stored rect's aspect.
            #expect(rect.width > rect.height)            // landscape: width > height
        }
    }

    @Test("a non-A4 sheet does NOT collapse to A4 (the pre-fix behavior)")
    func notAlwaysA4() {
        // A3 landscape — the exact case that used to re-show as A4 portrait.
        let rect = storedRect(wMM: 297, hMM: 420, landscape: true)
        let widthMM = rect.width * 25.4 / 72.0
        let heightMM = rect.height * 25.4 / 72.0
        #expect(PrintLayout.nearestStandardPage(widthMM: widthMM, heightMM: heightMM).name == "A3")
        #expect(rect.width > rect.height)   // recovered as landscape, not portrait
    }
}
