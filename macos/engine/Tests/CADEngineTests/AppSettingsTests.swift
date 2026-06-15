//
//  AppSettingsTests.swift
//  CADEngineTests
//
//  Tests for the application-level Preferences (audit G7 — `AppSettingsView.swift`).
//  Covers the PURE, GUI-free settings model that backs the `@AppStorage` views:
//
//    1. Keys are stable, non-empty, and uniquely namespaced (`app.<tab>.<field>`) so
//       they never collide with one another or the existing `commandBar.*`/`toolbar.*`
//       app-storage keys or the per-document `$VAR` header bag.
//    2. The typed defaults are the documented, sensible values (mm / system theme /
//       LibreCAD standard snap set / high quality, etc.).
//    3. The validators clamp/normalize correctly (aperture range, non-negative line
//       width, strictly-positive text height, forgiving unit/enum decode, snap-mask
//       round-trip with `.free` always forced on).
//    4. `AppSettingsModel` builds a fully-normalized snapshot from raw stored values —
//       the shape a read-site consumes — turning every bad/legacy input into a usable
//       value, and `.standard` matches the all-defaults build.
//
//  The view file is symlinked in as `_SharedAppSettings.swift` (the established
//  `_Shared*.swift` pattern) so these tests reach the executable-module types without
//  importing the GUI. No SwiftUI is touched here (no GUI in tests).
//
//  Suite/type names are domain-namespaced per CONVENTIONS.md to avoid the
//  parallel-fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Keys: stable, namespaced, collision-free

@Suite("App Settings — preference keys")
struct AppSettingsKeyTests {

    /// Every key string we persist (the single source the views' `@AppStorage` use).
    private static let allKeys: [String] = [
        AppSettings.Key.defaultUnit,
        AppSettings.Key.defaultTemplate,
        AppSettings.Key.autosaveEnabled,
        AppSettings.Key.theme,
        AppSettings.Key.canvasBackgroundHex,
        AppSettings.Key.gridColorHex,
        AppSettings.Key.crosshairStyle,
        AppSettings.Key.defaultSnapMask,
        AppSettings.Key.snapAperturePx,
        AppSettings.Key.antialias,
        AppSettings.Key.renderQuality,
        AppSettings.Key.defaultLineWidthMM,
        AppSettings.Key.defaultTextFont,
        AppSettings.Key.defaultTextHeight,
    ]

    @Test("keys are non-empty and all uniquely distinct")
    func keysUnique() {
        for k in Self.allKeys { #expect(!k.isEmpty) }
        #expect(Set(Self.allKeys).count == Self.allKeys.count)
    }

    @Test("every key is namespaced under app.<tab>. (no collision with commandBar./toolbar./$VAR)")
    func keysNamespaced() {
        for k in Self.allKeys {
            #expect(k.hasPrefix("app."))
            #expect(!k.hasPrefix("$"))                 // not a document header var
            #expect(!k.hasPrefix("commandBar."))       // existing @AppStorage namespace
            #expect(!k.hasPrefix("toolbar."))          // existing @AppStorage namespace
            // app.<tab>.<field> — at least three dot-separated components.
            #expect(k.split(separator: ".").count >= 3)
        }
    }

    @Test("stable key strings (changing these silently resets users' prefs)")
    func keyStringsStable() {
        #expect(AppSettings.Key.defaultUnit == "app.general.defaultUnit")
        #expect(AppSettings.Key.theme == "app.appearance.theme")
        #expect(AppSettings.Key.defaultSnapMask == "app.snapping.defaultSnapMask")
        #expect(AppSettings.Key.renderQuality == "app.rendering.renderQuality")
        #expect(AppSettings.Key.defaultTextFont == "app.text.defaultTextFont")
    }
}

// MARK: - Defaults: the documented sensible values

@Suite("App Settings — defaults")
struct AppSettingsDefaultTests {

    @Test("the typed defaults are the documented sensible values")
    func defaults() {
        #expect(AppSettings.Default.unit == .millimeter)
        #expect(AppSettings.Default.template == "blank")
        #expect(AppSettings.Default.autosaveEnabled == true)
        #expect(AppSettings.Default.theme == .system)
        #expect(AppSettings.Default.canvasBackgroundHex.isEmpty)    // empty = follow theme
        #expect(AppSettings.Default.gridColorHex.isEmpty)
        #expect(AppSettings.Default.crosshairStyle == .small)
        #expect(AppSettings.Default.snapAperturePx == 12)
        #expect(AppSettings.Default.antialias == true)
        #expect(AppSettings.Default.renderQuality == .high)
        #expect(AppSettings.Default.defaultLineWidthMM == 0)        // 0 = by default
        #expect(AppSettings.Default.textFont == "Standard")
        #expect(AppSettings.Default.textHeight == 2.5)
    }

    @Test("default snap mask is exactly LibreCAD's standard opt-in set")
    func defaultSnapMaskIsStandard() {
        #expect(AppSettings.Default.snapMask == Int(SnapMode.standard.rawValue))
        let decoded = AppSettings.snapMode(fromMask: AppSettings.Default.snapMask)
        #expect(decoded == SnapMode.standard)
        // The constructive modes are OFF by default (opt-in), matching DocumentSettings.
        #expect(!decoded.contains(.perpendicular))
        #expect(!decoded.contains(.tangent))
    }
}

// MARK: - Validators: clamp / normalize

@Suite("App Settings — validators")
struct AppSettingsValidatorTests {

    @Test("aperture clamps to [1, 64]")
    func apertureClamp() {
        #expect(AppSettings.clampAperture(0) == 1)
        #expect(AppSettings.clampAperture(-5) == 1)
        #expect(AppSettings.clampAperture(12) == 12)
        #expect(AppSettings.clampAperture(1000) == 64)
        #expect(AppSettings.clampAperture(64) == 64)
    }

    @Test("line width clamps to non-negative, preserves 0 sentinel and positive values")
    func lineWidthClamp() {
        #expect(AppSettings.clampLineWidthMM(-1) == 0)
        #expect(AppSettings.clampLineWidthMM(0) == 0)
        #expect(AppSettings.clampLineWidthMM(0.35) == 0.35)
    }

    @Test("text height forces strictly positive, falling back to default for bad input")
    func textHeightClamp() {
        #expect(AppSettings.clampTextHeight(5) == 5)
        #expect(AppSettings.clampTextHeight(0) == AppSettings.Default.textHeight)
        #expect(AppSettings.clampTextHeight(-3) == AppSettings.Default.textHeight)
        #expect(AppSettings.clampTextHeight(.nan) == AppSettings.Default.textHeight)
        #expect(AppSettings.clampTextHeight(.infinity) == AppSettings.Default.textHeight)
    }

    @Test("unit decode round-trips a known code and falls back for an unknown one")
    func unitDecode() {
        #expect(AppSettings.unit(fromRaw: DrawingUnit.inch.rawValue) == .inch)
        #expect(AppSettings.unit(fromRaw: DrawingUnit.millimeter.rawValue) == .millimeter)
        // 999 is not a valid $INSUNITS code → fall back to the default unit.
        #expect(AppSettings.unit(fromRaw: 999) == AppSettings.Default.unit)
        #expect(AppSettings.unit(fromRaw: -1) == AppSettings.Default.unit)
    }

    @Test("snap-mask round-trips and always forces .free on")
    func snapMaskRoundTrip() {
        let mode: SnapMode = [.endpoint, .center, .grid]
        let mask = AppSettings.mask(from: mode)
        let back = AppSettings.snapMode(fromMask: mask)
        #expect(back.contains(.endpoint))
        #expect(back.contains(.center))
        #expect(back.contains(.grid))
        #expect(back.contains(.free))          // free is the always-on fallback
        // A 0/blank mask still yields .free so the cursor is never un-snappable.
        #expect(AppSettings.snapMode(fromMask: 0) == .free)
    }
}

// MARK: - AppSettingsModel: the normalized snapshot a read-site consumes

@Suite("App Settings — resolved model")
struct AppSettingsModelTests {

    @Test(".standard matches the all-defaults values")
    func standardMatchesDefaults() {
        let m = AppSettingsModel.standard
        #expect(m.defaultUnit == AppSettings.Default.unit)
        #expect(m.defaultTemplate == AppSettings.Default.template)
        #expect(m.autosaveEnabled == AppSettings.Default.autosaveEnabled)
        #expect(m.theme == AppSettings.Default.theme)
        #expect(m.crosshairStyle == AppSettings.Default.crosshairStyle)
        #expect(m.snapAperturePx == AppSettings.Default.snapAperturePx)
        #expect(m.antialias == AppSettings.Default.antialias)
        #expect(m.renderQuality == AppSettings.Default.renderQuality)
        #expect(m.defaultLineWidthMM == AppSettings.Default.defaultLineWidthMM)
        #expect(m.defaultTextFont == AppSettings.Default.textFont)
        #expect(m.defaultTextHeight == AppSettings.Default.textHeight)
    }

    @Test("building from good raw values preserves them")
    func buildFromGoodValues() {
        let m = AppSettingsModel(
            unitRaw: DrawingUnit.inch.rawValue,
            template: "iso_a3",
            autosave: false,
            themeRaw: AppTheme.dark.rawValue,
            canvasBackgroundHex: "#102030",
            gridColorHex: "#405060",
            crosshairStyleRaw: CrosshairStyle.full.rawValue,
            snapMask: AppSettings.mask(from: [.endpoint, .center]),
            snapAperturePx: 20,
            antialias: false,
            renderQualityRaw: RenderQuality.low.rawValue,
            defaultLineWidthMM: 0.5,
            textFont: "Helvetica",
            textHeight: 4)
        #expect(m.defaultUnit == .inch)
        #expect(m.defaultTemplate == "iso_a3")
        #expect(m.autosaveEnabled == false)
        #expect(m.theme == .dark)
        #expect(m.canvasBackgroundHex == "#102030")
        #expect(m.gridColorHex == "#405060")
        #expect(m.crosshairStyle == .full)
        #expect(m.defaultSnap.contains(.endpoint))
        #expect(m.defaultSnap.contains(.center))
        #expect(m.defaultSnap.contains(.free))   // always forced on
        #expect(m.snapAperturePx == 20)
        #expect(m.antialias == false)
        #expect(m.renderQuality == .low)
        #expect(m.defaultLineWidthMM == 0.5)
        #expect(m.defaultTextFont == "Helvetica")
        #expect(m.defaultTextHeight == 4)
    }

    @Test("building from bad/legacy raw values normalizes every field")
    func buildFromBadValues() {
        let m = AppSettingsModel(
            unitRaw: 999,                  // unknown code → default unit
            template: "",                  // empty → default template
            autosave: true,
            themeRaw: "bogus",             // unknown → default theme
            canvasBackgroundHex: "",
            gridColorHex: "",
            crosshairStyleRaw: "nope",     // unknown → default crosshair
            snapMask: 0,                   // blank → just .free
            snapAperturePx: 9999,          // out of range → clamp to 64
            antialias: true,
            renderQualityRaw: "ultra",     // unknown → default quality
            defaultLineWidthMM: -2,        // negative → 0
            textFont: "",                  // empty → default font
            textHeight: 0)                 // ≤ 0 → default height
        #expect(m.defaultUnit == AppSettings.Default.unit)
        #expect(m.defaultTemplate == AppSettings.Default.template)
        #expect(m.theme == AppSettings.Default.theme)
        #expect(m.crosshairStyle == AppSettings.Default.crosshairStyle)
        #expect(m.defaultSnap == .free)
        #expect(m.snapAperturePx == 64)
        #expect(m.renderQuality == AppSettings.Default.renderQuality)
        #expect(m.defaultLineWidthMM == 0)
        #expect(m.defaultTextFont == AppSettings.Default.textFont)
        #expect(m.defaultTextHeight == AppSettings.Default.textHeight)
    }
}
