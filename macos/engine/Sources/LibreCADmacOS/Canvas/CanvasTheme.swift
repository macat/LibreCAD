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

    // MARK: - Apply

    /// Applies the chrome for `appearance` to the MTKView's clear color AND to the
    /// shared `OverlayStyle` colors that the GPU-free overlay builders read. Call
    /// from the canvas view on creation and whenever the effective appearance
    /// changes (`viewDidChangeEffectiveAppearance`). Returns the chrome so the
    /// caller can read `invertNearWhiteEntities`.
    @discardableResult
    @MainActor
    static func apply(to view: MTKView, appearance: NSAppearance) -> CanvasChrome {
        let chrome = chrome(for: appearance)
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
