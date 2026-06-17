//
//  NewLayerDefaultsTests.swift
//  CADEngineTests
//
//  Finding #32 — the NEW-LAYER defaults (color / line width / line type a fresh layer
//  is born with, edited in Document Settings ▸ Layers and consumed by
//  `LayersSidebar.addLayer`) are now APP-WIDE preferences PERSISTED to `UserDefaults`
//  (the "app policy" the code comment always claimed), instead of plain per-window vars
//  that reset every launch and every new window.
//
//  This suite proves, all hermetically (an isolated, named `UserDefaults` suite that is
//  torn down — never the real `.standard` domain):
//    • the PURE encoders round-trip (RGBAColor ⇆ #RRGGBB hex, PenLineWidth ⇆ mm Double,
//      PenLineType ⇆ String token), and degrade to the documented default on corrupt input;
//    • the `AppSettings.newLayer*` read/write helpers honor the missing-key default and
//      round-trip a write;
//    • a FRESH `CanvasModel` seeded (via `seedNewLayerDefaultsFromAppSettings(defaults:)`)
//      from a store that another "window" persisted adopts those values — and building a
//      `Layer` exactly as `LayersSidebar.addLayer` does carries them through (the
//      end-to-end finding-#32 fix: change → relaunch/new-window → stuck).
//
//  `CanvasModel` / `AppSettings` live in the (un-importable) app target — reached here via
//  the existing `_SharedCanvasModel.swift` / `_SharedAppSettings.swift` symlinks. The
//  CanvasModel suite is `@MainActor` (mirroring `Wave3BCanvasModelWiringTests`); the pure
//  encoder + helper suites need no actor.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Pure encoders (no UserDefaults)

@Suite("New-layer defaults — pure encoders")
struct NewLayerDefaultEncoderTests {

    // Color: RGBAColor ⇆ #RRGGBB

    @Test("color packs to #RRGGBB and parses back to the same RGB")
    func colorRoundTrips() {
        let c = RGBAColor(0.31, 0.80, 0.31)        // LibreCAD green
        let hex = AppSettings.newLayerColorHex(from: c)
        #expect(hex == "#4FCC4F")                  // 0.31*255≈79=0x4F, 0.80*255=204=0xCC
        let back = AppSettings.newLayerColor(fromHex: hex)
        // 8-bit round-trip tolerance (1/255 ≈ 0.004).
        #expect(abs(back.r - c.r) < 0.01)
        #expect(abs(back.g - c.g) < 0.01)
        #expect(abs(back.b - c.b) < 0.01)
        #expect(back.a == 1)                       // opaque
    }

    @Test("color parse accepts a bare (no-#) hex")
    func colorBareHex() {
        let back = AppSettings.newLayerColor(fromHex: "FF0000")
        #expect(back.r == 1 && back.g == 0 && back.b == 0)
    }

    @Test("a malformed / empty color hex falls back to the green default")
    func colorMalformedFallsBack() {
        #expect(AppSettings.newLayerColor(fromHex: "") == AppSettings.Default.newLayerColor)
        #expect(AppSettings.newLayerColor(fromHex: "nope") == AppSettings.Default.newLayerColor)
        #expect(AppSettings.newLayerColor(fromHex: "#12") == AppSettings.Default.newLayerColor)
    }

    // Line width: PenLineWidth ⇆ mm Double

    @Test("an explicit mm width round-trips")
    func widthMillimetersRoundTrips() {
        #expect(AppSettings.newLayerLineWidthMM(from: .millimeters(0.35)) == 0.35)
        #expect(AppSettings.newLayerLineWidth(fromMM: 0.35) == .millimeters(0.35))
    }

    @Test("the .default sentinel encodes as 0 and decodes back to .default")
    func widthDefaultSentinel() {
        #expect(AppSettings.newLayerLineWidthMM(from: .default) == 0)
        #expect(AppSettings.newLayerLineWidth(fromMM: 0) == .default)
        // Non-millimeter sentinels all collapse to the 0 / .default sentinel.
        #expect(AppSettings.newLayerLineWidthMM(from: .byLayer) == 0)
        #expect(AppSettings.newLayerLineWidthMM(from: .byBlock) == 0)
        // Negative / non-finite stored values decode to .default (never an unusable width).
        #expect(AppSettings.newLayerLineWidth(fromMM: -1) == .default)
        #expect(AppSettings.newLayerLineWidth(fromMM: .nan) == .default)
    }

    // Line type: PenLineType ⇆ token

    @Test("every concrete line type round-trips through its token")
    func lineTypeRoundTrips() {
        let all: [PenLineType] = [.byLayer, .byBlock, .solid, .dashed, .dotted,
                                  .dashDot, .center, .border, .divide]
        for t in all {
            #expect(AppSettings.lineType(fromToken: AppSettings.lineTypeToken(t)) == t)
        }
    }

    @Test("an unknown line-type token falls back to the solid default")
    func lineTypeUnknownFallsBack() {
        #expect(AppSettings.lineType(fromToken: "bogus") == AppSettings.Default.newLayerLineType)
        #expect(AppSettings.Default.newLayerLineType == .solid)
    }
}

// MARK: - Read / write helpers (isolated UserDefaults suite)

@Suite("New-layer defaults — UserDefaults read/write")
struct NewLayerDefaultStoreTests {

    /// A throwaway, isolated defaults domain for one test (removed on teardown).
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "NewLayerDefaultStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("a missing key yields each typed default")
    func missingKeysHonorDefaults() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        #expect(AppSettings.newLayerColor(defaults: d) == AppSettings.Default.newLayerColor)
        #expect(AppSettings.newLayerLineWidth(defaults: d) == .default)   // 0 → .default
        #expect(AppSettings.newLayerLineType(defaults: d) == .solid)
    }

    @Test("write → read round-trips for all three defaults")
    func writeReadRoundTrips() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }

        AppSettings.setNewLayerColor(RGBAColor(0, 0, 1), defaults: d)        // blue
        AppSettings.setNewLayerLineWidth(.millimeters(0.50), defaults: d)
        AppSettings.setNewLayerLineType(.dashDot, defaults: d)

        let color = AppSettings.newLayerColor(defaults: d)
        #expect(color.b > 0.99 && color.r < 0.01 && color.g < 0.01)
        #expect(AppSettings.newLayerLineWidth(defaults: d) == .millimeters(0.50))
        #expect(AppSettings.newLayerLineType(defaults: d) == .dashDot)
    }
}

// MARK: - CanvasModel seed integration (the end-to-end finding-#32 fix)

@MainActor
@Suite("New-layer defaults — CanvasModel seed + addLayer use")
struct NewLayerDefaultsSeedTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "NewLayerDefaultsSeedTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func model() -> CanvasModel {
        CanvasModel(drawing: CADDrawing(), viewSize: CGSize(width: 800, height: 600))
    }

    @Test("a fresh model seeded from an empty store adopts the documented defaults")
    func freshModelEmptyStore() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        let m = model()
        m.seedNewLayerDefaultsFromAppSettings(defaults: d)
        #expect(m.defaultLayerColor == AppSettings.Default.newLayerColor)
        #expect(m.defaultLineWidth == .default)
        #expect(m.defaultLineType == .solid)
    }

    @Test("a value persisted by one 'window' is seeded into a fresh model (survives relaunch/new-window)")
    func persistedValueSeedsNewModel() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }

        // Window A: the user edits the new-layer defaults in Document Settings — these are
        // the writes the property `didSet` performs (here routed at the AppSettings layer
        // into the isolated suite so the test stays hermetic).
        AppSettings.setNewLayerColor(RGBAColor(0.9, 0.1, 0.1), defaults: d)   // red-ish
        AppSettings.setNewLayerLineWidth(.millimeters(0.70), defaults: d)
        AppSettings.setNewLayerLineType(.center, defaults: d)

        // Window B (a NEW window / a relaunch): a fresh model seeds from the store.
        let m = model()
        m.seedNewLayerDefaultsFromAppSettings(defaults: d)
        #expect(m.defaultLayerColor.r > 0.8 && m.defaultLayerColor.g < 0.2)
        #expect(m.defaultLineWidth == .millimeters(0.70))
        #expect(m.defaultLineType == .center)

        // …and a layer born from those defaults (exactly what `LayersSidebar.addLayer`
        // constructs) carries them through.
        let born = Layer(name: "New Layer",
                         color: m.defaultLayerColor,
                         lineType: m.defaultLineType,
                         lineWidth: m.defaultLineWidth)
        #expect(born.lineWidth == .millimeters(0.70))
        #expect(born.lineType == .center)
        #expect(born.color.r > 0.8)
    }

    @Test("seeding does NOT echo back to the store (hermetic — no .standard pollution)")
    func seedDoesNotPersist() {
        let (d, suite) = makeDefaults()
        defer { d.removePersistentDomain(forName: suite) }
        // Store carries an explicit dashed line type.
        AppSettings.setNewLayerLineType(.dashed, defaults: d)

        let m = model()
        m.seedNewLayerDefaultsFromAppSettings(defaults: d)
        #expect(m.defaultLineType == .dashed)

        // The seed must NOT have written the color/width keys (they were never set, so
        // they still read as their defaults — proving the suppressed `didSet` did not echo).
        #expect(d.object(forKey: AppSettings.Key.newLayerColorHex) == nil)
        #expect(d.object(forKey: AppSettings.Key.newLayerLineWidthMM) == nil)
    }
}
