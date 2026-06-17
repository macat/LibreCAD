//
//  AppSettingsView.swift
//  LibreCADmacOS
//
//  The application-level Preferences window (audit G7). This is DISTINCT from the
//  per-document settings sheet (`DocumentSettingsView`, ⌥⌘,): those values belong to
//  ONE drawing and round-trip in its `.dxf`. The preferences here are APP-WIDE
//  policy — the defaults a BRAND-NEW drawing / window is born with, and global
//  app appearance/quality — so they are backed by `@AppStorage` (UserDefaults):
//  they persist across launches and apply to every new document, not just the open one.
//
//  ## How it is shown
//  `LibreCADApp.swift` adds a SwiftUI `Settings { AppSettingsView() }` scene. On
//  macOS that scene is special: AppKit automatically wires it to the standard
//  application-menu "Settings…/Preferences…" item with the conventional **⌘,**
//  shortcut and gives it the standard preferences-window chrome. We do NOT declare a
//  ⌘, shortcut ourselves (that would double-bind it); the `Settings` scene owns ⌘,.
//  The per-document sheet keeps ⌥⌘, (decision D8) — unchanged.
//
//  ## Apply model
//  Each control writes its `@AppStorage` key immediately (UserDefaults persists it).
//  WHO READS the key determines whether the pref drives behavior *today*:
//    • `AppTheme` (Appearance ▸ theme) drives `NSApp.appearance` live via
//      `.onChange` in this file — that is fully wired here (no non-owned edit needed).
//    • The DXF-save-version key is also WIRED: `DXFDocumentCodec` reads it off-main and
//      threads it into the engine writer (R2000 default = unchanged behavior). The new
//      intermediate tiers (R14 / R2004 / R2007) are just additional `DXFExportVersion`
//      cases that map to the corresponding engine `DXFVersion` — no read-site change.
//    • Every OTHER key is STORED-PENDING-A-READ-SITE: a follow-up (in a file this
//      task does not own — `ContentView`/`CanvasModel`/`LibreCADDocument`/
//      `CanvasTheme`) should consult `AppSettings.<key>` when it seeds a new
//      drawing / builds the canvas chrome / picks default snap modes. The exact
//      read-site for each key is named in a `// READ-SITE:` comment below and in the
//      task report, so wiring them is a mechanical, well-scoped change. In particular,
//      the SNAP seeding read-site (a new window's `CanvasModel`, where `snapModes` /
//      the aperture / `polarAngleIncrement` are initialized) is a Wave-3 follow-up: it
//      should seed those three from `AppSettings.snapMode(fromMask:)` /
//      `AppSettings.clampAperture(_:)` / `AppSettings.polarIncrementRadians(fromDegrees:)`
//      (or read the whole `AppSettingsModel` snapshot, whose `defaultSnap` /
//      `snapAperturePx` / `polarIncrementRadians` fields are already normalized).
//
//  ## Testability (CONVENTIONS.md — pure model, GUI-free tests)
//  All the non-GUI logic — the key strings, the typed defaults, and the
//  normalization/validation (clamping, enum round-trip, snap-mask packing) — lives in
//  the pure `AppSettings` namespace + `AppSettingsModel` value type below, with NO
//  SwiftUI/AppKit dependency. `AppSettingsView.swift` is symlinked into the test
//  target (`_SharedAppSettings.swift`) so `AppSettingsTests` can exercise that logic
//  directly, headlessly. The SwiftUI views are thin and untested (no GUI in tests).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
import CADEngine

// MARK: - Pure settings model (testable, no SwiftUI/AppKit)
//
// This namespace is the single source of truth for the preference KEYS, their typed
// DEFAULTS, and the validation/normalization helpers. It is deliberately free of any
// SwiftUI/AppKit reference so the test target (which cannot import the executable's
// GUI types) can `@testable import CADEngine` + use the symlinked copy and exercise it
// headlessly. The `@AppStorage`-backed views below read these SAME keys/defaults, so
// the tested logic is the logic the UI uses.

/// App-wide preference keys + typed defaults + pure validation. Stored in
/// `UserDefaults` (via SwiftUI `@AppStorage` in the views). Keys are namespaced
/// `app.<tab>.<field>` so they never collide with the per-document `$VAR` header bag
/// or the existing `commandBar.*` / `toolbar.*` `@AppStorage` keys.
enum AppSettings {

    // MARK: Keys (the @AppStorage / UserDefaults key strings)

    /// General tab.
    enum Key {
        /// Default `DrawingUnit.rawValue` (Int) a NEW drawing is born with.
        static let defaultUnit = "app.general.defaultUnit"
        /// Identifier of the default template for new drawings (`"blank"` = no template).
        static let defaultTemplate = "app.general.defaultTemplate"
        /// Whether autosave is enabled for new windows.
        static let autosaveEnabled = "app.general.autosaveEnabled"
        /// `DXFExportVersion.rawValue` (String): the DXF format version a Save/Export
        /// writes (read off-main by `DXFDocumentCodec`, defaulting to R2000).
        static let dxfExportVersion = "app.general.dxfExportVersion"

        /// Appearance tab.
        /// `AppTheme.rawValue` (String): system / light / dark.
        static let theme = "app.appearance.theme"
        /// Canvas background color override, packed `#RRGGBB` (empty = follow theme).
        static let canvasBackgroundHex = "app.appearance.canvasBackgroundHex"
        /// Grid color override, packed `#RRGGBB` (empty = follow theme).
        static let gridColorHex = "app.appearance.gridColorHex"
        /// `CrosshairStyle.rawValue` (String).
        static let crosshairStyle = "app.appearance.crosshairStyle"

        /// Snapping tab.
        /// Default snap-mode mask (`SnapMode.rawValue` as Int) for new windows.
        static let defaultSnapMask = "app.snapping.defaultSnapMask"
        /// Default snap aperture in screen pixels for new windows.
        static let snapAperturePx = "app.snapping.snapAperturePx"
        /// Default POLAR-tracking angle increment, stored in DEGREES (Double). The model
        /// (`CanvasModel.polarAngleIncrement`) works in radians, so the read-site converts
        /// via `AppSettings.polarIncrementRadians(fromDegrees:)`. Degrees is the human-
        /// readable unit users expect in the Preferences UI (AutoCAD POLARANG is in degrees).
        static let polarIncrementDegrees = "app.snapping.polarIncrementDegrees"
        /// Whether DYNAMIC INPUT — the on-canvas live dimensional feedback shown while
        /// drawing (AutoCAD F12 / DYNMODE) — is on (Bool). Read at `CanvasModel.init` to
        /// seed `dynamicInputEnabled`, and written back by `CanvasModel.toggleDynamicInput()`
        /// (this is the rare key the MODEL persists directly — via
        /// `AppSettings.setBoolPreference` — because its toggle is also a status-bar/menu
        /// action, not only a Preferences control).
        static let dynamicInput = "app.snapping.dynamicInput"
        /// Whether OBJECT-SNAP TRACKING (OTRACK — LibreCAD's object snap tracking,
        /// AutoCAD F11) is on for NEW windows (Bool). When on, snaps the user dwells over
        /// are ACQUIRED and the cursor locks onto alignment guides radiating from them.
        /// INDEPENDENT of ortho/polar (it can be on together with either). Default OFF
        /// (matching `CanvasModel.objectTrackingEnabled`'s `false` default). READ-SITE
        /// (a one-line CanvasModel.init follow-up, see file header): seed the new window's
        /// `objectTrackingEnabled` from this via `AppSettings.boolPreference`.
        static let objectTracking = "app.snapping.objectTracking"

        /// Rendering tab.
        /// Whether antialiasing is on.
        static let antialias = "app.rendering.antialias"
        /// `RenderQuality.rawValue` (String): the LOD / quality tier.
        static let renderQuality = "app.rendering.renderQuality"
        /// Default line width in millimeters for new geometry (0 = "by default").
        static let defaultLineWidthMM = "app.rendering.defaultLineWidthMM"

        /// Text tab.
        /// Default font family name for new text entities.
        static let defaultTextFont = "app.text.defaultTextFont"
        /// Default text height (world units) for new text entities.
        static let defaultTextHeight = "app.text.defaultTextHeight"
    }

    // MARK: Defaults (the typed default values the keys fall back to)

    enum Default {
        /// Millimeter (DXF `$INSUNITS` = 4) — the common metric CAD default.
        static let unit: DrawingUnit = .millimeter
        static let template = "blank"
        static let autosaveEnabled = true
        /// R2000 (AutoCAD 2000 / AC1015) — the broadly-compatible modern DXF the
        /// writer already defaults to, so an unset key preserves existing behavior.
        static let dxfExportVersion: DXFExportVersion = .r2000

        static let theme: AppTheme = .system
        /// Empty hex = "follow the theme palette" (do not override `CanvasTheme`).
        static let canvasBackgroundHex = ""
        static let gridColorHex = ""
        static let crosshairStyle: CrosshairStyle = .full   // preserve the prior full-window "spider" crosshair as the default; users can pick small/none in Preferences

        /// LibreCAD's standard opt-in set (endpoint+center+middle+intersection+
        /// onEntity+grid+free) — mirrors `SnapMode.standard`.
        static let snapMask: Int = Int(SnapMode.standard.rawValue)
        static let snapAperturePx: Double = 12
        /// 15° — LibreCAD's / AutoCAD's classic polar increment (== `CanvasModel`'s own
        /// `.pi / 12` default, expressed in degrees). 360 / 15 = 24 even divisions of a turn.
        static let polarIncrementDegrees: Double = 15
        /// Dynamic input (live dimensional feedback) defaults ON — AutoCAD ships DYNMODE on,
        /// and the feedback is the point of the feature. Honored by `AppSettings.boolPreference`
        /// (which uses `object(forKey:)`, so a missing key yields this `true`, not `false`).
        static let dynamicInput = true
        /// Object-snap tracking (OTRACK) defaults OFF — it is an advanced drafting aid the
        /// user opts into (LibreCAD/AutoCAD ship it off), and OFF matches the model's own
        /// `objectTrackingEnabled = false` default, so an unset key leaves new-window
        /// behavior unchanged. Honored by `AppSettings.boolPreference` (`object(forKey:)`),
        /// so a missing key yields this `false`.
        static let objectTracking = false

        static let antialias = true
        static let renderQuality: RenderQuality = .high
        /// 0 mm = "by default" (resolve to the layer/global default pen width).
        static let defaultLineWidthMM: Double = 0

        static let textFont = "Standard"
        static let textHeight: Double = 2.5
    }

    // MARK: Validation / normalization (pure — exercised by AppSettingsTests)

    /// Clamp a snap aperture to a sane, usable range. A sub-pixel aperture is
    /// un-clickable; an enormous one snaps to everything. Mirrors the picker bounds.
    static func clampAperture(_ px: Double) -> Double {
        min(max(px, 1), 64)
    }

    /// Clamp a default line width (mm) to non-negative; negative is meaningless and
    /// 0 is the legitimate "by default" sentinel.
    static func clampLineWidthMM(_ mm: Double) -> Double {
        max(0, mm)
    }

    /// Clamp a default text height to a strictly positive value (0 / negative text is
    /// invisible). Falls back to the default when the input is non-finite or ≤ 0.
    static func clampTextHeight(_ h: Double) -> Double {
        guard h.isFinite, h > 0 else { return Default.textHeight }
        return h
    }

    /// Clamp a polar-tracking angle increment (DEGREES) to the usable range `(0, 360]`.
    /// A zero/negative/non-finite step would make `PolarConstraint.constrain` a no-op
    /// (it guards `incrementRadians > 0`), and a step over a full turn is meaningless, so
    /// out-of-range input falls back to the 15° default. The common case (a clean divisor
    /// of 360 such as 5/10/15/30/45/90) passes through unchanged.
    static func clampPolarIncrementDegrees(_ deg: Double) -> Double {
        guard deg.isFinite, deg > 0, deg <= 360 else { return Default.polarIncrementDegrees }
        return deg
    }

    /// Convert a stored polar increment (DEGREES) to the RADIANS the model
    /// (`CanvasModel.polarAngleIncrement`) and `PolarConstraint.constrain` consume. The
    /// input is clamped first, so a corrupt/out-of-range key never yields a no-op polar
    /// step — the read-site always gets a valid, positive radian increment.
    static func polarIncrementRadians(fromDegrees deg: Double) -> Double {
        clampPolarIncrementDegrees(deg) * .pi / 180
    }

    /// Resolve a stored unit rawValue back to a `DrawingUnit`, falling back to the
    /// default for an unknown/legacy code (same forgiving policy as `DrawingUnit(dxf:)`).
    static func unit(fromRaw raw: Int) -> DrawingUnit {
        DrawingUnit(rawValue: raw) ?? Default.unit
    }

    /// Resolve a stored DXF-export version rawValue (String) back to a
    /// `DXFExportVersion`, falling back to the default (R2000) for an unknown / blank /
    /// legacy value. The forgiving decode means a corrupt key never breaks a Save — it
    /// reverts to the broadly-compatible default.
    static func dxfExportVersion(fromRaw raw: String) -> DXFExportVersion {
        DXFExportVersion(rawValue: raw) ?? Default.dxfExportVersion
    }

    /// Resolve a stored snap mask back to a `SnapMode`. `.free` is the always-available
    /// fallback, so it is forced on even if a legacy/blank mask omitted it.
    static func snapMode(fromMask mask: Int) -> SnapMode {
        SnapMode(rawValue: UInt16(truncatingIfNeeded: mask)).union(.free)
    }

    /// Pack a `SnapMode` to the Int rawValue stored in UserDefaults.
    static func mask(from mode: SnapMode) -> Int { Int(mode.rawValue) }

    // MARK: Bool preference read/write (for keys the MODEL seeds + persists directly)

    /// Read a Bool preference, honoring a non-`false` default. `UserDefaults.bool(forKey:)`
    /// returns `false` for a MISSING key, which would silently override a `true` default;
    /// this uses `object(forKey:)` so an unset key falls back to `def` (and a stored value
    /// is coerced through `NSNumber.boolValue`). Pure Foundation (no SwiftUI/AppKit), so
    /// `CanvasModel.init` can seed `dynamicInputEnabled` from it and the test target can
    /// exercise it via the symlinked copy. The `defaults` parameter is injectable for tests.
    static func boolPreference(_ key: String,
                               default def: Bool,
                               defaults: UserDefaults = .standard) -> Bool {
        guard let obj = defaults.object(forKey: key) else { return def }
        return (obj as? NSNumber)?.boolValue ?? def
    }

    /// Write a Bool preference back to `UserDefaults`. The write counterpart of
    /// `boolPreference(_:default:)`, used by `CanvasModel.toggleDynamicInput()` so the
    /// status-bar/menu toggle persists across launches (the same key the Preferences
    /// toggle binds via `@AppStorage`). `defaults` is injectable for tests.
    static func setBoolPreference(_ key: String,
                                  _ value: Bool,
                                  defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}

/// A snapshot of the resolved app preferences as plain values — the shape a read-site
/// (new-document seeding, canvas chrome) would consume. Built purely from UserDefaults
/// values, with every field normalized/clamped through `AppSettings`. Pure + Sendable,
/// so it is fully testable without a `UserDefaults` instance (the `from:` initializer
/// takes the already-read raw values).
struct AppSettingsModel: Sendable, Equatable {
    var defaultUnit: DrawingUnit
    var defaultTemplate: String
    var autosaveEnabled: Bool

    var theme: AppTheme
    var canvasBackgroundHex: String
    var gridColorHex: String
    var crosshairStyle: CrosshairStyle

    var defaultSnap: SnapMode
    var snapAperturePx: Double
    /// The POLAR-tracking angle increment in RADIANS — ready for the model
    /// (`CanvasModel.polarAngleIncrement`) to consume directly. Built by running the
    /// stored degrees value through `AppSettings.polarIncrementRadians(fromDegrees:)`.
    var polarIncrementRadians: Double

    var antialias: Bool
    var renderQuality: RenderQuality
    var defaultLineWidthMM: Double

    var defaultTextFont: String
    var defaultTextHeight: Double

    /// The DXF format version a Save/Export writes (default R2000).
    var dxfExportVersion: DXFExportVersion

    /// The all-defaults model (what a fresh install resolves to).
    static let standard = AppSettingsModel(
        defaultUnit: AppSettings.Default.unit,
        defaultTemplate: AppSettings.Default.template,
        autosaveEnabled: AppSettings.Default.autosaveEnabled,
        theme: AppSettings.Default.theme,
        canvasBackgroundHex: AppSettings.Default.canvasBackgroundHex,
        gridColorHex: AppSettings.Default.gridColorHex,
        crosshairStyle: AppSettings.Default.crosshairStyle,
        defaultSnap: SnapMode(rawValue: UInt16(truncatingIfNeeded: AppSettings.Default.snapMask)),
        snapAperturePx: AppSettings.Default.snapAperturePx,
        polarIncrementRadians: AppSettings.Default.polarIncrementDegrees * .pi / 180,
        antialias: AppSettings.Default.antialias,
        renderQuality: AppSettings.Default.renderQuality,
        defaultLineWidthMM: AppSettings.Default.defaultLineWidthMM,
        defaultTextFont: AppSettings.Default.textFont,
        defaultTextHeight: AppSettings.Default.textHeight,
        dxfExportVersion: AppSettings.Default.dxfExportVersion)

    /// Build a normalized model from the raw stored values (the shape a read-site
    /// gets after `UserDefaults` reads). Every numeric/enum field is run through the
    /// matching `AppSettings` validator so a corrupt/legacy value can never produce an
    /// unusable default (invisible text, un-clickable aperture, unknown unit code).
    init(unitRaw: Int,
         template: String,
         autosave: Bool,
         themeRaw: String,
         canvasBackgroundHex: String,
         gridColorHex: String,
         crosshairStyleRaw: String,
         snapMask: Int,
         snapAperturePx: Double,
         antialias: Bool,
         renderQualityRaw: String,
         defaultLineWidthMM: Double,
         textFont: String,
         textHeight: Double,
         dxfExportVersionRaw: String = AppSettings.Default.dxfExportVersion.rawValue,
         polarIncrementDegrees: Double = AppSettings.Default.polarIncrementDegrees) {
        self.defaultUnit = AppSettings.unit(fromRaw: unitRaw)
        self.defaultTemplate = template.isEmpty ? AppSettings.Default.template : template
        self.autosaveEnabled = autosave
        self.theme = AppTheme(rawValue: themeRaw) ?? AppSettings.Default.theme
        self.canvasBackgroundHex = canvasBackgroundHex
        self.gridColorHex = gridColorHex
        self.crosshairStyle = CrosshairStyle(rawValue: crosshairStyleRaw) ?? AppSettings.Default.crosshairStyle
        self.defaultSnap = AppSettings.snapMode(fromMask: snapMask)
        self.snapAperturePx = AppSettings.clampAperture(snapAperturePx)
        self.polarIncrementRadians = AppSettings.polarIncrementRadians(fromDegrees: polarIncrementDegrees)
        self.antialias = antialias
        self.renderQuality = RenderQuality(rawValue: renderQualityRaw) ?? AppSettings.Default.renderQuality
        self.defaultLineWidthMM = AppSettings.clampLineWidthMM(defaultLineWidthMM)
        self.defaultTextFont = textFont.isEmpty ? AppSettings.Default.textFont : textFont
        self.defaultTextHeight = AppSettings.clampTextHeight(textHeight)
        self.dxfExportVersion = AppSettings.dxfExportVersion(fromRaw: dxfExportVersionRaw)
    }

    /// Memberwise init for `.standard` (avoids re-running validators on known-good
    /// defaults). `private` so callers always go through the normalizing `init(...)`.
    private init(defaultUnit: DrawingUnit, defaultTemplate: String, autosaveEnabled: Bool,
                 theme: AppTheme, canvasBackgroundHex: String, gridColorHex: String,
                 crosshairStyle: CrosshairStyle, defaultSnap: SnapMode, snapAperturePx: Double,
                 polarIncrementRadians: Double,
                 antialias: Bool, renderQuality: RenderQuality, defaultLineWidthMM: Double,
                 defaultTextFont: String, defaultTextHeight: Double,
                 dxfExportVersion: DXFExportVersion) {
        self.defaultUnit = defaultUnit
        self.defaultTemplate = defaultTemplate
        self.autosaveEnabled = autosaveEnabled
        self.theme = theme
        self.canvasBackgroundHex = canvasBackgroundHex
        self.gridColorHex = gridColorHex
        self.crosshairStyle = crosshairStyle
        self.defaultSnap = defaultSnap
        self.snapAperturePx = snapAperturePx
        self.polarIncrementRadians = polarIncrementRadians
        self.antialias = antialias
        self.renderQuality = renderQuality
        self.defaultLineWidthMM = defaultLineWidthMM
        self.defaultTextFont = defaultTextFont
        self.defaultTextHeight = defaultTextHeight
        self.dxfExportVersion = dxfExportVersion
    }
}

// MARK: - Enum prefs (pure: rawValue-backed, no SwiftUI/AppKit)

/// App appearance preference. `.system` follows macOS; `.light`/`.dark` force it.
/// Drives `NSApp.appearance` (fully wired in this file — see `applyTheme`).
enum AppTheme: String, CaseIterable, Sendable, Hashable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Crosshair style preference for the canvas cursor. STORED-PENDING-A-READ-SITE:
/// the canvas overlay (`OverlayGeometry`/`CanvasModel`) would consult this when it
/// draws the crosshair.
enum CrosshairStyle: String, CaseIterable, Sendable, Hashable {
    /// A small cursor-local cross.
    case small
    /// Full-viewport cross-hair lines (LibreCAD's "spider" cursor).
    case full
    /// No crosshair (cursor only).
    case none

    var label: String {
        switch self {
        case .small: return "Small cross"
        case .full:  return "Full-window"
        case .none:  return "None"
        }
    }
}

/// Rendering quality tier (antialias/LOD). STORED-PENDING-A-READ-SITE: the renderer
/// (`RendererGeometry`/`CGSceneRenderer`) would consult this for tessellation LOD.
enum RenderQuality: String, CaseIterable, Sendable, Hashable {
    case low, medium, high

    var label: String {
        switch self {
        case .low:    return "Low (fastest)"
        case .medium: return "Medium"
        case .high:   return "High (best)"
        }
    }
}

/// The DXF format version a Save/Export writes. A thin app-level mirror of the engine's
/// `CADEngine.DXFVersion`: it exposes every tier the engine writer (and the underlying
/// `LCDxfVersion`/libdxfrw) supports in the Preferences UI — R12 / R14 / R2000 / R2004 /
/// R2007 / R2018 — and converts to the engine type for the write call. Backed by a stable
/// `rawValue` String so it persists to `UserDefaults` via `@AppStorage` and is read off-main
/// by `DXFDocumentCodec`. R2000 is the default — identical to the writer's own default — so an
/// unset key leaves existing save behavior byte-for-byte unchanged. The `CaseIterable` order
/// is the chronological version order the Picker presents.
enum DXFExportVersion: String, CaseIterable, Sendable, Hashable {
    /// AutoCAD R12 (AC1009) — the oldest, most widely-importable DXF (no ACAD object DB).
    case r12
    /// AutoCAD R14 (AC1014).
    case r14
    /// AutoCAD 2000 (AC1015) — the modern, broadly-compatible default.
    case r2000
    /// AutoCAD 2004 (AC1018).
    case r2004
    /// AutoCAD 2007 (AC1021).
    case r2007
    /// AutoCAD 2018 (AC1032) — the newest tier the engine writer supports.
    case r2018

    /// A short menu label for the Picker.
    var label: String {
        switch self {
        case .r12:   return "R12 (AC1009)"
        case .r14:   return "R14 (AC1014)"
        case .r2000: return "R2000 (AC1015)"
        case .r2004: return "R2004 (AC1018)"
        case .r2007: return "R2007 (AC1021)"
        case .r2018: return "R2018 (AC1032)"
        }
    }

    /// The engine writer version this UI tier maps to.
    var engineVersion: DXFVersion {
        switch self {
        case .r12:   return .r12
        case .r14:   return .r14
        case .r2000: return .r2000
        case .r2004: return .r2004
        case .r2007: return .r2007
        case .r2018: return .r2018
        }
    }
}

// MARK: - The Preferences window view (SwiftUI; thin, decomposed per gotcha #2)

#if canImport(SwiftUI)
/// The application Preferences window body — a `TabView` of small `@ViewBuilder`
/// per-tab subviews, each backed directly by `@AppStorage` so edits persist to
/// UserDefaults immediately and apply to new documents / the app globally. Decomposed
/// into per-tab subviews so no single SwiftUI body is large enough to blow the
/// type-checker (gotcha #2 — same discipline as the Tools menu + DocumentSettingsView).
struct AppSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            SnappingSettingsTab()
                .tabItem { Label("Snapping", systemImage: "scope") }
            RenderingSettingsTab()
                .tabItem { Label("Rendering", systemImage: "wand.and.rays") }
            TextSettingsTab()
                .tabItem { Label("Text", systemImage: "textformat") }
        }
        // A standard preferences-window footprint (System Settings-like).
        .frame(width: 460, height: 360)
    }
}

// MARK: General tab

/// General: default units for NEW drawings, default template, autosave.
/// All three are STORED-PENDING-A-READ-SITE (the new-document seed path in
/// `LibreCADDocument`/`ContentView` should consult them) — see file header.
private struct GeneralSettingsTab: View {
    // READ-SITE: new-document seeding — `LibreCADDocument()` / `ContentView`'s
    // model-build should set the fresh drawing's `$INSUNITS` from this.
    @AppStorage(AppSettings.Key.defaultUnit) private var unitRaw = AppSettings.Default.unit.rawValue
    // READ-SITE: File ▸ New — the new-document path should preload this template.
    @AppStorage(AppSettings.Key.defaultTemplate) private var template = AppSettings.Default.template
    // READ-SITE: document creation — toggle the DocumentGroup/NSDocument autosave policy.
    @AppStorage(AppSettings.Key.autosaveEnabled) private var autosave = AppSettings.Default.autosaveEnabled
    // READ-SITE (WIRED): the DXF version Save/Export writes. `DXFDocumentCodec.data(from:)`
    // reads this SAME key off-main via `UserDefaults.standard` and threads it into the
    // engine writer; R2000 default = unchanged behavior.
    @AppStorage(AppSettings.Key.dxfExportVersion) private var dxfVersionRaw = AppSettings.Default.dxfExportVersion.rawValue

    var body: some View {
        Form {
            Section("New drawings") {
                Picker("Default units", selection: $unitRaw) {
                    ForEach(DrawingUnit.allCases, id: \.self) { u in
                        Text(unitLabel(u)).tag(u.rawValue)
                    }
                }
                Picker("Default template", selection: $template) {
                    Text("Blank").tag("blank")
                    Text("A4 (mm)").tag("a4_mm")
                    Text("Letter (inch)").tag("letter_inch")
                    Text("ISO A3").tag("iso_a3")
                }
            }
            Section("Documents") {
                Toggle("Autosave new documents", isOn: $autosave)
                Text("Applies to documents created after changing this setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Files") {
                Picker("DXF save version", selection: $dxfVersionRaw) {
                    ForEach(DXFExportVersion.allCases, id: \.self) { v in
                        Text(v.label).tag(v.rawValue)
                    }
                }
                Text("The DXF format version a Save/Export writes. R2000 is the broadly-compatible default; R12 maximizes import compatibility with older tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// "Millimeter (mm)"-style label; reuses the engine's `sign`.
    private func unitLabel(_ u: DrawingUnit) -> String {
        let name = "\(u)".prefix(1).uppercased() + "\(u)".dropFirst()
        let s = u.sign
        return s.isEmpty ? name : "\(name) (\(s))"
    }
}

// MARK: Appearance tab

/// Appearance: app theme (system/light/dark — DRIVES `NSApp.appearance` live here),
/// canvas background + grid color overrides, crosshair style. The two color overrides
/// and the crosshair style are STORED-PENDING-A-READ-SITE (`CanvasTheme` /
/// `OverlayGeometry`).
private struct AppearanceSettingsTab: View {
    @AppStorage(AppSettings.Key.theme) private var themeRaw = AppSettings.Default.theme.rawValue
    // READ-SITE: `CanvasTheme.apply` (clearColor) would honor a non-empty override.
    @AppStorage(AppSettings.Key.canvasBackgroundHex) private var bgHex = AppSettings.Default.canvasBackgroundHex
    // READ-SITE: `CanvasTheme.apply` (OverlayStyle.gridColor) would honor a non-empty override.
    @AppStorage(AppSettings.Key.gridColorHex) private var gridHex = AppSettings.Default.gridColorHex
    // READ-SITE: the crosshair overlay builder (`OverlayGeometry`/`CanvasModel`).
    @AppStorage(AppSettings.Key.crosshairStyle) private var crosshairRaw = AppSettings.Default.crosshairStyle.rawValue

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $themeRaw) {
                    ForEach(AppTheme.allCases, id: \.self) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                // The ONE pref that drives behavior live from this file: apply on
                // change AND on appear so the window opens reflecting the stored theme.
                .onChange(of: themeRaw) { _, newValue in
                    applyTheme(AppTheme(rawValue: newValue) ?? .system)
                }
            }
            Section("Canvas colors") {
                colorRow("Background", hex: $bgHex)
                colorRow("Grid", hex: $gridHex)
                Text("Leave at default to follow the light/dark theme palette.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cursor") {
                Picker("Crosshair", selection: $crosshairRaw) {
                    ForEach(CrosshairStyle.allCases, id: \.self) { c in
                        Text(c.label).tag(c.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { applyTheme(AppTheme(rawValue: themeRaw) ?? .system) }
    }

    /// A color override row: a ColorPicker bound through the `#RRGGBB` hex string, with
    /// a "Default" button that clears the override (empty hex = follow theme).
    @ViewBuilder
    private func colorRow(_ title: String, hex: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                ColorPicker("", selection: Binding(
                    get: { Color(appHex: hex.wrappedValue) ?? .gray },
                    set: { hex.wrappedValue = $0.appHexString }
                ), supportsOpacity: false)
                .labelsHidden()
                Button("Default") { hex.wrappedValue = "" }
                    .controlSize(.small)
                    .disabled(hex.wrappedValue.isEmpty)
            }
        }
    }
}

// MARK: Snapping tab

/// Snapping: default snap modes + aperture + polar increment for NEW windows. All three
/// are STORED-PENDING-A-READ-SITE (the new-window canvas-model build should seed its snap
/// state — `snapModes`, the screen-pixel aperture, and `polarAngleIncrement` — from these).
private struct SnappingSettingsTab: View {
    // READ-SITE: new-window CanvasModel build — seed `snapModes` from this mask
    // (via `AppSettings.snapMode(fromMask:)`).
    @AppStorage(AppSettings.Key.defaultSnapMask) private var snapMask = AppSettings.Default.snapMask
    // READ-SITE: new-window snapper — seed the screen-pixel aperture from this
    // (via `AppSettings.clampAperture(_:)`).
    @AppStorage(AppSettings.Key.snapAperturePx) private var aperture = AppSettings.Default.snapAperturePx
    // READ-SITE: new-window CanvasModel build — seed `polarAngleIncrement` (RADIANS) from
    // this DEGREES value via `AppSettings.polarIncrementRadians(fromDegrees:)`.
    @AppStorage(AppSettings.Key.polarIncrementDegrees) private var polarDegrees = AppSettings.Default.polarIncrementDegrees
    // READ-SITE (WIRED): live dimensional feedback while drawing. `CanvasModel.init` seeds
    // `dynamicInputEnabled` from this SAME key (via `AppSettings.boolPreference`), and
    // `CanvasModel.toggleDynamicInput()` writes it back, so this toggle, the status-bar DYN
    // chip, and the model flag all stay in sync.
    @AppStorage(AppSettings.Key.dynamicInput) private var dynamicInput = AppSettings.Default.dynamicInput
    // READ-SITE (PENDING — a one-line CanvasModel.init follow-up; not in this wave's owned
    // files): seed the new window's `objectTrackingEnabled` from this SAME key via
    // `AppSettings.boolPreference(AppSettings.Key.objectTracking, default: AppSettings.Default.objectTracking)`,
    // mirroring how `dynamicInputEnabled` is seeded. Default OFF == the model's current
    // hardcoded `false`, so until that one line lands a fresh window simply ignores this
    // pref (no behavior change); the status-bar OTRK chip + View-menu item still toggle live.
    @AppStorage(AppSettings.Key.objectTracking) private var objectTracking = AppSettings.Default.objectTracking

    var body: some View {
        Form {
            Section("Default snap modes (new windows)") {
                ForEach(SnapSettingRow.all, id: \.label) { row in
                    Toggle(row.label, isOn: snapBinding(row.mode))
                }
            }
            Section("Aperture") {
                LabeledContent("Snap distance (px)") {
                    TextField("px", value: Binding(
                        get: { aperture },
                        set: { aperture = AppSettings.clampAperture($0) }
                    ), format: .number)
                    .frame(width: 80).multilineTextAlignment(.trailing)
                }
            }
            Section("Polar tracking") {
                LabeledContent("Angle increment (°)") {
                    TextField("degrees", value: Binding(
                        get: { polarDegrees },
                        set: { polarDegrees = AppSettings.clampPolarIncrementDegrees($0) }
                    ), format: .number)
                    .frame(width: 80).multilineTextAlignment(.trailing)
                }
                Text("The angular step polar tracking (F10) snaps to in new windows. 15° gives 24 even divisions of a full turn.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dynamic input") {
                Toggle("Dynamic input — show live dimensions while drawing", isOn: $dynamicInput)
                Text("Shows the running length / radius / size as a value chip and dotted dimension line at the cursor while a draw tool is active (DYN in the status bar).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Object snap tracking") {
                Toggle("Object snap tracking — alignment guides from acquired points", isOn: $objectTracking)
                Text("Locks the cursor onto horizontal / vertical / polar alignment guides radiating from object snaps you acquire (OTRK in the status bar). Independent of ortho and polar — it can be on together with either.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A toggle binding over one snap-mode bit in the packed mask.
    private func snapBinding(_ mode: SnapMode) -> Binding<Bool> {
        Binding(
            get: { SnapMode(rawValue: UInt16(truncatingIfNeeded: snapMask)).contains(mode) },
            set: { on in
                var set = SnapMode(rawValue: UInt16(truncatingIfNeeded: snapMask))
                if on { set.insert(mode) } else { set.remove(mode) }
                snapMask = AppSettings.mask(from: set)
            })
    }
}

/// The snap modes the Snapping tab exposes (label + bit). A small local list, like
/// `DocumentSettingsView`'s `SnapSettingOption`.
private struct SnapSettingRow {
    let label: String
    let mode: SnapMode
    static let all: [SnapSettingRow] = [
        SnapSettingRow(label: "Endpoint", mode: .endpoint),
        SnapSettingRow(label: "Midpoint", mode: .middle),
        SnapSettingRow(label: "Center", mode: .center),
        SnapSettingRow(label: "Intersection", mode: .intersection),
        SnapSettingRow(label: "On entity", mode: .onEntity),
        SnapSettingRow(label: "Nearest point", mode: .nearest),
        SnapSettingRow(label: "Grid", mode: .grid),
    ]
}

// MARK: Rendering tab

/// Rendering: antialias toggle, LOD/quality tier, default line width. All
/// STORED-PENDING-A-READ-SITE (the renderer / new-geometry pen default).
private struct RenderingSettingsTab: View {
    // READ-SITE: renderer (`CGSceneRenderer`/`RendererGeometry`) MSAA / smoothing.
    @AppStorage(AppSettings.Key.antialias) private var antialias = AppSettings.Default.antialias
    // READ-SITE: renderer tessellation LOD selection.
    @AppStorage(AppSettings.Key.renderQuality) private var qualityRaw = AppSettings.Default.renderQuality.rawValue
    // READ-SITE: new-geometry pen — default line width for newly drawn entities.
    @AppStorage(AppSettings.Key.defaultLineWidthMM) private var lineWidthMM = AppSettings.Default.defaultLineWidthMM

    var body: some View {
        Form {
            Section("Quality") {
                Toggle("Antialiasing", isOn: $antialias)
                Picker("Detail (LOD)", selection: $qualityRaw) {
                    ForEach(RenderQuality.allCases, id: \.self) { q in
                        Text(q.label).tag(q.rawValue)
                    }
                }
            }
            Section("New geometry") {
                LabeledContent("Default line width (mm)") {
                    TextField("mm (0 = default)", value: Binding(
                        get: { lineWidthMM },
                        set: { lineWidthMM = AppSettings.clampLineWidthMM($0) }
                    ), format: .number)
                    .frame(width: 110).multilineTextAlignment(.trailing)
                }
                Text("0 mm uses the layer / global default pen width.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Text tab

/// Text: default font family + height for NEW text entities.
/// STORED-PENDING-A-READ-SITE (the Text tool's new-entity defaults).
private struct TextSettingsTab: View {
    // READ-SITE: Text tool new-entity creation — default font family.
    @AppStorage(AppSettings.Key.defaultTextFont) private var font = AppSettings.Default.textFont
    // READ-SITE: Text tool new-entity creation — default text height.
    @AppStorage(AppSettings.Key.defaultTextHeight) private var height = AppSettings.Default.textHeight

    var body: some View {
        Form {
            Section("New text") {
                Picker("Default font", selection: $font) {
                    // LibreCAD's bundled LFF fonts + common system families.
                    ForEach(["Standard", "iso", "unicode", "Helvetica", "Times New Roman", "Courier"], id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                LabeledContent("Default height") {
                    TextField("world units", value: Binding(
                        get: { height },
                        set: { height = AppSettings.clampTextHeight($0) }
                    ), format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Theme application (the one pref wired live in this file)

/// Apply an `AppTheme` to the running app by setting `NSApp.appearance`. `.system`
/// clears the override so AppKit tracks System Settings ▸ Appearance again. This is
/// the single preference that takes effect immediately from THIS file — no edit to a
/// non-owned file is needed because it drives an AppKit-global, not a per-canvas read.
@MainActor
private func applyTheme(_ theme: AppTheme) {
    #if canImport(AppKit)
    switch theme {
    case .system: NSApp.appearance = nil
    case .light:  NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    #endif
}

// MARK: - Color ⇆ #RRGGBB hex (for the @AppStorage-backed color overrides)

private extension Color {
    /// A `Color` from a `#RRGGBB` / `RRGGBB` hex string, or nil for empty/invalid.
    init?(appHex: String) {
        var s = appHex.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255.0,
            green: Double((v >> 8) & 0xFF) / 255.0,
            blue: Double(v & 0xFF) / 255.0)
    }

    /// `#RRGGBB` for this color (via AppKit's sRGB conversion).
    var appHexString: String {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return ""
        #endif
    }
}
#endif
