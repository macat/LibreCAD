//
//  CanvasTheme.swift
//  LibreCADmacOS
//
//  Adaptive (light/dark) chrome colors for the Metal canvas. The canvas itself is
//  a CAD "model space": its background, grid, axis, snap, selection, and crosshair
//  colors are NOT document content, so they should follow the system appearance
//  rather than being baked to one palette. This keeps the app native in both
//  light and dark mode (toggle System Settings ▸ Appearance and the canvas tracks
//  it) instead of shipping a single hardcoded dark canvas.
//
//  ## What it resolves
//  - `clearColor`     — the Metal drawable clear (the canvas background).
//  - the `OverlayStyle` chrome colors (grid / grid-axis / crosshair, plus the
//    selection / snap / tool-preview accents) — written into `OverlayStyle` so the
//    GPU-free, AppKit-free `OverlayGeometry` builders stay unit-testable (they read
//    `OverlayStyle.*`; this file is the only place that mutates them).
//  - `invertNearWhiteEntities` — in light mode, color-7/white pens (the CAD
//    "automatic" color, which the engine resolves to white for a dark canvas) would
//    be invisible on a light background. This is the standard AutoCAD/LibreCAD
//    auto-invert: near-white strokes flip to near-black so the drawing stays legible.
//    (Non-white pens — explicit layer colors — are left untouched.)
//
//  ## Dark mode == today's look, byte-for-byte
//  The dark palette reproduces the previously hardcoded values exactly
//  (clear `(0.07, 0.08, 0.10)`, grid `white·0.06`, axis `(0.55,0.55,0.62)·0.30`,
//  etc.), so this change is a no-op for dark-mode users and only ADDS a tuned
//  light palette.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import AppKit
import simd
import MetalKit

/// The resolved canvas chrome for one appearance (light or dark).
struct CanvasChrome {
    /// The Metal drawable clear color (canvas background).
    var clearColor: MTLClearColor
    var grid: SIMD4<Float>
    var gridAxis: SIMD4<Float>
    var crosshair: SIMD4<Float>
    var selection: SIMD4<Float>
    var snap: SIMD4<Float>
    var toolPreview: SIMD4<Float>
    /// In light mode, near-white ("automatic"/color-7) pens flip to near-black so
    /// the default drawing color stays legible on a light canvas.
    var invertNearWhiteEntities: Bool
}

/// Resolves + applies the adaptive canvas chrome for the current appearance.
enum CanvasTheme {

    // MARK: - Palettes

    /// The dark palette — identical to the values that were previously hardcoded in
    /// `CADCanvasView` (clear color) and `OverlayStyle` (grid/axis/etc.). Changing
    /// any of these changes the dark-mode look; they are kept verbatim on purpose.
    static let dark = CanvasChrome(
        clearColor: MTLClearColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0),
        grid:        SIMD4<Float>(1, 1, 1, 0.06),
        gridAxis:    SIMD4<Float>(0.55, 0.55, 0.62, 0.30),
        crosshair:   SIMD4<Float>(1, 1, 1, 0.18),
        selection:   SIMD4<Float>(1.0, 0.85, 0.20, 1.0),   // amber
        snap:        SIMD4<Float>(0.30, 0.85, 1.0, 1.0),    // cyan
        toolPreview: SIMD4<Float>(0.45, 1.0, 0.55, 0.9),    // green
        invertNearWhiteEntities: false
    )

    /// The light palette — a soft off-white canvas with darker grid/axis lines so
    /// the chrome reads on a bright background. Accents keep their hue but are
    /// darkened/saturated enough to stand out against white.
    static let light = CanvasChrome(
        clearColor: MTLClearColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0),
        grid:        SIMD4<Float>(0, 0, 0, 0.07),
        gridAxis:    SIMD4<Float>(0.20, 0.20, 0.28, 0.35),
        crosshair:   SIMD4<Float>(0, 0, 0, 0.20),
        selection:   SIMD4<Float>(0.90, 0.55, 0.0, 1.0),    // deeper amber/orange
        snap:        SIMD4<Float>(0.0, 0.45, 0.85, 1.0),    // deeper blue
        toolPreview: SIMD4<Float>(0.0, 0.62, 0.20, 0.95),   // deeper green
        invertNearWhiteEntities: true
    )

    // MARK: - Resolution

    /// Whether the given appearance is one of the dark variants (incl. the
    /// high-contrast dark material). Anything else is treated as light.
    static func isDark(_ appearance: NSAppearance) -> Bool {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua,
                                                .accessibilityHighContrastAqua,
                                                .accessibilityHighContrastDarkAqua])
        switch match {
        case .some(.darkAqua), .some(.accessibilityHighContrastDarkAqua):
            return true
        default:
            return false
        }
    }

    /// The chrome for an appearance.
    static func chrome(for appearance: NSAppearance) -> CanvasChrome {
        isDark(appearance) ? dark : light
    }

    // MARK: - Preference overrides (Appearance ▸ canvas background + grid color)

    /// Parses a `#RRGGBB` / `RRGGBB` hex string into an opaque `SIMD4<Float>`
    /// (alpha 1), or `nil` for an empty / malformed string. This is the SAME hex
    /// shape the Preferences ▸ Appearance color pickers persist (see
    /// `AppSettings.Key.canvasBackgroundHex` / `.gridColorHex`); an EMPTY value is
    /// the "follow the theme palette" sentinel, so it resolves to `nil` and the
    /// caller keeps the theme default. Pure value math — unit-tested in
    /// `PrefsWiringTests` (no AppKit/Metal needed).
    static func rgba(fromAppHex hex: String) -> SIMD4<Float>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return SIMD4<Float>(
            Float((v >> 16) & 0xFF) / 255.0,
            Float((v >> 8) & 0xFF) / 255.0,
            Float(v & 0xFF) / 255.0,
            1.0)
    }

    /// An `MTLClearColor` from a `#RRGGBB` hex, or `nil` for empty/invalid (so the
    /// theme default is kept). Shares the parse with `rgba(fromAppHex:)`.
    static func clearColor(fromAppHex hex: String) -> MTLClearColor? {
        guard let c = rgba(fromAppHex: hex) else { return nil }
        return MTLClearColor(red: Double(c.x), green: Double(c.y),
                             blue: Double(c.z), alpha: 1.0)
    }

    /// Returns `chrome` with the user's Preferences ▸ Appearance canvas-background
    /// and grid-color overrides applied where set. An EMPTY hex (the default) leaves
    /// the corresponding theme color untouched, so a user who never opened
    /// Preferences gets byte-for-byte today's palette. A non-empty override REPLACES
    /// that one color in BOTH light and dark chrome — it is an explicit user choice,
    /// not a theme-tracked value. The grid override also tints the grid AXIS color
    /// (a slightly stronger variant) so the override reads consistently. Pure — no
    /// AppKit/Metal state mutated; the value is handed to `apply` to push into the
    /// view + `OverlayStyle`.
    static func overridden(_ chrome: CanvasChrome,
                           backgroundHex: String,
                           gridHex: String) -> CanvasChrome {
        var out = chrome
        if let bg = clearColor(fromAppHex: backgroundHex) {
            out.clearColor = bg
        }
        if let grid = rgba(fromAppHex: gridHex) {
            // Keep the theme grid's alpha (a faint guide), only override the hue, so
            // the grid stays a subtle background guide rather than an opaque slab.
            out.grid = SIMD4<Float>(grid.x, grid.y, grid.z, chrome.grid.w)
            // Tint the axis with the same hue at the theme axis alpha so the two
            // read as a set.
            out.gridAxis = SIMD4<Float>(grid.x, grid.y, grid.z, chrome.gridAxis.w)
        }
        return out
    }

    /// Reads the two Appearance color overrides straight from `UserDefaults`
    /// (the keys the `@AppStorage` Preferences controls write) and applies them on
    /// top of the theme chrome. The defaults are EMPTY strings (the
    /// `AppSettings.Default.*Hex` "follow theme" sentinel), so absent keys are a
    /// no-op — today's behavior for any user who never touched Preferences.
    static func appearanceOverridden(_ chrome: CanvasChrome,
                                     defaults: UserDefaults = .standard) -> CanvasChrome {
        let bg = defaults.string(forKey: AppSettings.Key.canvasBackgroundHex)
            ?? AppSettings.Default.canvasBackgroundHex
        let grid = defaults.string(forKey: AppSettings.Key.gridColorHex)
            ?? AppSettings.Default.gridColorHex
        return overridden(chrome, backgroundHex: bg, gridHex: grid)
    }

    // MARK: - Apply

    /// Applies the chrome for `appearance` to the MTKView's clear color AND to the
    /// shared `OverlayStyle` colors that the GPU-free overlay builders read. Call
    /// from the canvas view on creation and whenever the effective appearance
    /// changes (`viewDidChangeEffectiveAppearance`). Returns the chrome so the
    /// caller can read `invertNearWhiteEntities`.
    @discardableResult
    @MainActor
    static func apply(to view: MTKView, appearance: NSAppearance) -> CanvasChrome {
        // Resolve the appearance palette, THEN layer the user's Preferences ▸
        // Appearance canvas-background / grid-color overrides on top (empty = follow
        // theme, so this is a no-op for anyone who never opened Preferences). Pulled
        // from UserDefaults — the same keys the @AppStorage controls write.
        let chrome = appearanceOverridden(chrome(for: appearance))
        view.clearColor = chrome.clearColor
        OverlayStyle.gridColor = chrome.grid
        OverlayStyle.gridAxisColor = chrome.gridAxis
        OverlayStyle.crosshairColor = chrome.crosshair
        OverlayStyle.selectionColor = chrome.selection
        OverlayStyle.snapColor = chrome.snap
        OverlayStyle.toolPreviewColor = chrome.toolPreview
        OverlayStyle.invertNearWhiteEntities = chrome.invertNearWhiteEntities
        return chrome
    }
}
