//
//  AutoConstrainSettingTests.swift
//  CADEngineTests
//
//  Tests for the AutoConstrain-on-draw PREFERENCE contract that Lane D's Preferences
//  ▸ Constraints toggle binds (`AppSettingsView.swift` → `ConstraintsSettingsTab`).
//
//  The toggle is an `@AppStorage(CanvasModel.autoConstrainOnDrawKey)` (the literal
//  `"draw.autoConstrainOnDraw"`, default ON) and the model reads that SAME key at `init`
//  and via `CanvasModel.seedAutoConstrainFromAppSettings(defaults:)`. There is no GUI
//  seam to drive here (no SwiftUI view is instantiated — that would need a window), so we
//  exercise the END-TO-END key contract through the model's hermetic seed seam:
//
//    1. The key string is the stable literal the UI binds (changing it silently resets
//       users' prefs and decouples the toggle from the model).
//    2. A MISSING key resolves ON — matching both `@AppStorage(...) = true` and the
//       model's object-first default — so a fresh install draws with AutoConstrain on.
//    3. A suite-written value ROUND-TRIPS through `seedAutoConstrainFromAppSettings`
//       (true→on, false→off), proving the toggle's persisted value reaches the model.
//
//  An isolated, named `UserDefaults` suite is used throughout so the real `.standard`
//  domain is never touched (hermetic, order-independent). The suite is `@MainActor`
//  because `CanvasModel` is main-actor-isolated; it reaches the executable-module
//  `CanvasModel` via the established `_SharedCanvasModel.swift` symlink (no GUI imported).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@MainActor
@Suite("AutoConstrain — on-draw preference contract (Lane D)")
struct AutoConstrainSettingTests {

    private let viewSize = CGSize(width: 800, height: 600)

    /// A throwaway, isolated defaults domain for one test (removed on teardown).
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AutoConstrainSettingTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("the backing key is the stable literal the @AppStorage toggle binds")
    func keyIsStableLiteral() {
        // Lane D's `ConstraintsSettingsTab` binds `@AppStorage(CanvasModel.autoConstrainOnDrawKey)`;
        // the model reads the SAME constant. This pins the literal so the two never drift.
        #expect(CanvasModel.autoConstrainOnDrawKey == "draw.autoConstrainOnDraw")
    }

    @Test("a missing key resolves ON (matches the @AppStorage true default + a fresh install)")
    func missingKeyDefaultsOn() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Nothing written → the object-first read falls back to true (NOT the false a plain
        // `bool(forKey:)` would give), so a brand-new install draws with AutoConstrain on.
        #expect(defaults.object(forKey: CanvasModel.autoConstrainOnDrawKey) == nil)

        let m = CanvasModel(drawing: CADDrawing(), viewSize: viewSize)
        m.seedAutoConstrainFromAppSettings(defaults: defaults)
        #expect(m.autoConstrainOnDraw == true)
    }

    @Test("a suite-written value round-trips through seedAutoConstrainFromAppSettings (off then on)")
    func writtenValueRoundTrips() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = CanvasModel(drawing: CADDrawing(), viewSize: viewSize)

        // Toggle OFF (what the Preferences switch persists) → the model seeds OFF.
        defaults.set(false, forKey: CanvasModel.autoConstrainOnDrawKey)
        m.seedAutoConstrainFromAppSettings(defaults: defaults)
        #expect(m.autoConstrainOnDraw == false)

        // Toggle back ON → the model seeds ON again from the SAME key.
        defaults.set(true, forKey: CanvasModel.autoConstrainOnDrawKey)
        m.seedAutoConstrainFromAppSettings(defaults: defaults)
        #expect(m.autoConstrainOnDraw == true)
    }
}
