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
        AppSettings.Key.polarIncrementDegrees,
        AppSettings.Key.dynamicInput,
        AppSettings.Key.objectTracking,
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
        #expect(AppSettings.Key.snapAperturePx == "app.snapping.snapAperturePx")
        #expect(AppSettings.Key.polarIncrementDegrees == "app.snapping.polarIncrementDegrees")
        #expect(AppSettings.Key.dynamicInput == "app.snapping.dynamicInput")
        #expect(AppSettings.Key.objectTracking == "app.snapping.objectTracking")
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
        #expect(AppSettings.Default.crosshairStyle == .full)
        #expect(AppSettings.Default.dynamicInput == true)       // DYNMODE ships on
        #expect(AppSettings.Default.objectTracking == false)    // OTRACK is opt-in (matches the model's false default)
        #expect(AppSettings.Default.snapAperturePx == 12)
        #expect(AppSettings.Default.polarIncrementDegrees == 15)   // LibreCAD's classic 15° polar step
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

    @Test("polar increment clamps to (0, 360], falling back to 15° default for bad input")
    func polarIncrementClamp() {
        #expect(AppSettings.clampPolarIncrementDegrees(15) == 15)    // common case passes through
        #expect(AppSettings.clampPolarIncrementDegrees(45) == 45)
        #expect(AppSettings.clampPolarIncrementDegrees(360) == 360)  // a full turn is still valid
        #expect(AppSettings.clampPolarIncrementDegrees(0) == AppSettings.Default.polarIncrementDegrees)
        #expect(AppSettings.clampPolarIncrementDegrees(-10) == AppSettings.Default.polarIncrementDegrees)
        #expect(AppSettings.clampPolarIncrementDegrees(361) == AppSettings.Default.polarIncrementDegrees)
        #expect(AppSettings.clampPolarIncrementDegrees(.nan) == AppSettings.Default.polarIncrementDegrees)
        #expect(AppSettings.clampPolarIncrementDegrees(.infinity) == AppSettings.Default.polarIncrementDegrees)
    }

    @Test("polar increment converts degrees→radians, and the default matches the model's .pi/12")
    func polarIncrementRadians() {
        // 90° → π/2.
        #expect(abs(AppSettings.polarIncrementRadians(fromDegrees: 90) - .pi / 2) < 1e-12)
        // The stored default (15°) must equal CanvasModel.polarAngleIncrement's own default (.pi/12).
        #expect(abs(AppSettings.polarIncrementRadians(fromDegrees: AppSettings.Default.polarIncrementDegrees) - .pi / 12) < 1e-12)
        // A bad stored value is clamped FIRST, so the conversion is never a no-op (always > 0).
        #expect(AppSettings.polarIncrementRadians(fromDegrees: 0) > 0)
        #expect(abs(AppSettings.polarIncrementRadians(fromDegrees: -5) - .pi / 12) < 1e-12)
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

// MARK: - Bool preference read/write (DYN + OTRACK — the model-seeded toggles)

/// The two snapping toggles the MODEL seeds + persists directly through
/// `AppSettings.boolPreference` / `setBoolPreference` (dynamic input + object-snap
/// tracking). Verifies the missing-key-honors-default semantics (so an unset OTRACK key
/// yields its `false` default, and an unset DYN key yields its `true` default — NOT the
/// `false` that plain `UserDefaults.bool(forKey:)` would return) and a write→read
/// round-trip. Uses an isolated, named `UserDefaults` suite so it never touches the real
/// `.standard` domain (hermetic, parallel-safe).
@Suite("App Settings — bool preference seeding (DYN / OTRACK)")
struct AppSettingsBoolPreferenceTests {

    /// A throwaway, isolated defaults domain for one test (removed on teardown).
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AppSettingsBoolPreferenceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("a missing key falls back to the typed default (true for DYN, false for OTRACK)")
    func missingKeyHonorsDefault() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Nothing stored yet → each key returns ITS OWN default, not the bool() `false`.
        #expect(AppSettings.boolPreference(AppSettings.Key.objectTracking,
                                           default: AppSettings.Default.objectTracking,
                                           defaults: defaults) == false)
        #expect(AppSettings.boolPreference(AppSettings.Key.dynamicInput,
                                           default: AppSettings.Default.dynamicInput,
                                           defaults: defaults) == true)
    }

    @Test("OTRACK pref round-trips: writing true then reading yields true (and false→false)")
    func objectTrackingRoundTrips() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        AppSettings.setBoolPreference(AppSettings.Key.objectTracking, true, defaults: defaults)
        #expect(AppSettings.boolPreference(AppSettings.Key.objectTracking,
                                           default: AppSettings.Default.objectTracking,
                                           defaults: defaults) == true)

        AppSettings.setBoolPreference(AppSettings.Key.objectTracking, false, defaults: defaults)
        #expect(AppSettings.boolPreference(AppSettings.Key.objectTracking,
                                           default: AppSettings.Default.objectTracking,
                                           defaults: defaults) == false)
    }
}

// MARK: - DXFExportVersion: UI tiers ⇆ engine writer version

@Suite("App Settings — DXF export version tiers")
struct AppSettingsDXFVersionTests {

    @Test("every UI tier maps to the matching engine DXFVersion")
    func tierToEngineVersion() {
        #expect(DXFExportVersion.r12.engineVersion == .r12)
        #expect(DXFExportVersion.r14.engineVersion == .r14)
        #expect(DXFExportVersion.r2000.engineVersion == .r2000)
        #expect(DXFExportVersion.r2004.engineVersion == .r2004)
        #expect(DXFExportVersion.r2007.engineVersion == .r2007)
        #expect(DXFExportVersion.r2018.engineVersion == .r2018)
    }

    @Test("the intermediate tiers R14 / R2004 / R2007 are exposed")
    func intermediateTiersPresent() {
        let all = Set(DXFExportVersion.allCases)
        #expect(all.contains(.r14))
        #expect(all.contains(.r2004))
        #expect(all.contains(.r2007))
        // Six tiers total, in chronological order, each with a distinct rawValue + label.
        #expect(DXFExportVersion.allCases.count == 6)
        let raws = DXFExportVersion.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        let labels = DXFExportVersion.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test("stable rawValues (changing these silently resets the saved DXF-version pref)")
    func stableRawValues() {
        #expect(DXFExportVersion.r12.rawValue == "r12")
        #expect(DXFExportVersion.r14.rawValue == "r14")
        #expect(DXFExportVersion.r2000.rawValue == "r2000")
        #expect(DXFExportVersion.r2004.rawValue == "r2004")
        #expect(DXFExportVersion.r2007.rawValue == "r2007")
        #expect(DXFExportVersion.r2018.rawValue == "r2018")
    }

    @Test("forgiving decode: a known tier round-trips, an unknown/blank value falls back to R2000")
    func decodeFallback() {
        #expect(AppSettings.dxfExportVersion(fromRaw: "r2004") == .r2004)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r14") == .r14)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r2007") == .r2007)
        #expect(AppSettings.dxfExportVersion(fromRaw: "bogus") == AppSettings.Default.dxfExportVersion)
        #expect(AppSettings.dxfExportVersion(fromRaw: "") == .r2000)
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
        // Default polar increment resolves (in radians) to the model's own .pi/12 default.
        #expect(abs(m.polarIncrementRadians - .pi / 12) < 1e-12)
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
            textHeight: 4,
            dxfExportVersionRaw: DXFExportVersion.r2004.rawValue,
            polarIncrementDegrees: 30)
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
        #expect(abs(m.polarIncrementRadians - 30 * .pi / 180) < 1e-12)   // 30° preserved
        #expect(m.dxfExportVersion == .r2004)
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
            textHeight: 0,                 // ≤ 0 → default height
            dxfExportVersionRaw: "bogus",  // unknown → default DXF version (R2000)
            polarIncrementDegrees: 0)      // ≤ 0 → default 15° (never a no-op step)
        #expect(m.defaultUnit == AppSettings.Default.unit)
        #expect(m.defaultTemplate == AppSettings.Default.template)
        #expect(m.theme == AppSettings.Default.theme)
        #expect(m.crosshairStyle == AppSettings.Default.crosshairStyle)
        #expect(m.defaultSnap == .free)
        #expect(m.snapAperturePx == 64)
        #expect(abs(m.polarIncrementRadians - .pi / 12) < 1e-12)   // bad 0° → default 15°
        #expect(m.dxfExportVersion == AppSettings.Default.dxfExportVersion)
        #expect(m.renderQuality == AppSettings.Default.renderQuality)
        #expect(m.defaultLineWidthMM == 0)
        #expect(m.defaultTextFont == AppSettings.Default.textFont)
        #expect(m.defaultTextHeight == AppSettings.Default.textHeight)
    }
}
