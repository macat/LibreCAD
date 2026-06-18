//
//  DXFVersionPickerTests.swift
//  CADEngineTests
//
//  Tests for the DXF-export-version picker on Save/Export — the wiring that lets the
//  user choose which DXF format version (R12 / R2000 / R2018) a Save writes, persisted
//  as the `app.general.dxfExportVersion` preference and threaded into the engine writer
//  by `DXFDocumentCodec`. Covers:
//
//    1. The settings-tier ↔ engine-version mapping (`DXFExportVersion.engineVersion` is
//       the right `CADEngine.DXFVersion` for each tier; the rawValue strings are stable;
//       R2000 is the default tier).
//    2. The forgiving decoder `AppSettings.dxfExportVersion(fromRaw:)` (a blank / unknown
//       / legacy string falls back to the R2000 default; a valid string round-trips).
//    3. The codec's PURE version resolution `DXFDocumentCodec.dxfVersion(fromRaw:)`
//       (nil / empty / garbage → `.r2000`; a valid raw → the mapped engine version) — no
//       `UserDefaults`, no NSSavePanel, no modal.
//    4. The UserDefaults-backed resolver `resolvedDXFExportVersion()` reads the SAME key
//       the picker writes and falls back to `.r2000` when unset (key save/restored so the
//       test never pollutes the shared domain).
//    5. A REAL save round-trip through the production codec (`DXFDocumentCodec.data(from:)`)
//       confirms the chosen version reaches the on-disk `$ACADVER` header: R12 → AC1009,
//       R2000 (default) → AC1015. The R2018 tier maps to DRW::AC1032 on our side, but
//       libdxfrw's DXF text writer caps the emitted token at AC1021 (R2007) — so that
//       case asserts the actually-observed AC1021 (distinct from the R2000/R12 defaults,
//       proving the preference reached the writer) and documents the vendored-library cap.
//
//  Both `AppSettingsView.swift` and `LibreCADDocument.swift` are symlinked into this test
//  target (`_SharedAppSettings.swift` / `_SharedLibreCADDocument.swift`, the established
//  `_Shared*.swift` pattern) so these tests reach the executable-module codec + settings
//  types without importing the GUI. No SwiftUI is touched; no NSSavePanel/modal is reached.
//
//  Suite/type names are domain-namespaced per CONVENTIONS.md to avoid the parallel
//  fan-out test-target redeclaration trap.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Settings tier ↔ engine version mapping

@Suite("DXF version picker — settings tier ↔ engine version")
struct DXFVersionPickerMappingTests {

    @Test("each DXFExportVersion tier maps to the matching CADEngine.DXFVersion")
    func tiersMapToEngineVersions() {
        #expect(DXFExportVersion.r12.engineVersion == .r12)
        #expect(DXFExportVersion.r2000.engineVersion == .r2000)
        #expect(DXFExportVersion.r2018.engineVersion == .r2018)
    }

    @Test("rawValue strings are stable + non-empty + collision-free (UserDefaults keys)")
    func rawValuesAreStable() {
        #expect(DXFExportVersion.r12.rawValue == "r12")
        #expect(DXFExportVersion.r2000.rawValue == "r2000")
        #expect(DXFExportVersion.r2018.rawValue == "r2018")
        let raws = DXFExportVersion.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "rawValue collision among DXFExportVersion cases")
        #expect(raws.allSatisfy { !$0.isEmpty })
    }

    @Test("allCases covers the six exposed tiers and every case has a label")
    func allCasesAndLabels() {
        #expect(DXFExportVersion.allCases == [.r12, .r14, .r2000, .r2004, .r2007, .r2018])
        for v in DXFExportVersion.allCases {
            #expect(!v.label.isEmpty, "every tier needs a Picker label")
        }
    }

    @Test("the default export tier is R2000 (the writer's own default — unchanged behavior)")
    func defaultTierIsR2000() {
        #expect(AppSettings.Default.dxfExportVersion == .r2000)
        #expect(AppSettings.Default.dxfExportVersion.engineVersion == .r2000)
    }
}

// MARK: - Forgiving decode (settings)

@Suite("DXF version picker — AppSettings decode")
struct DXFVersionPickerDecodeTests {

    @Test("a valid raw string round-trips to its tier")
    func validRawRoundTrips() {
        #expect(AppSettings.dxfExportVersion(fromRaw: "r12") == .r12)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r14") == .r14)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r2000") == .r2000)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r2004") == .r2004)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r2007") == .r2007)
        #expect(AppSettings.dxfExportVersion(fromRaw: "r2018") == .r2018)
    }

    @Test("a blank / unknown / legacy raw string falls back to the R2000 default")
    func badRawFallsBack() {
        #expect(AppSettings.dxfExportVersion(fromRaw: "") == .r2000)
        #expect(AppSettings.dxfExportVersion(fromRaw: "bogus") == .r2000)
        #expect(AppSettings.dxfExportVersion(fromRaw: "R12") == .r2000)   // case-sensitive rawValue
        #expect(AppSettings.dxfExportVersion(fromRaw: "R14") == .r2000)   // case-sensitive rawValue
    }
}

// MARK: - Codec PURE version resolution (no UserDefaults / no I/O)

@Suite("DXF version picker — codec pure resolution")
struct DXFVersionPickerCodecPureTests {

    @Test("nil / empty / garbage raw resolves to .r2000 (unchanged behavior)")
    func absentResolvesToR2000() {
        #expect(DXFDocumentCodec.dxfVersion(fromRaw: nil) == .r2000)
        #expect(DXFDocumentCodec.dxfVersion(fromRaw: "") == .r2000)
        #expect(DXFDocumentCodec.dxfVersion(fromRaw: "garbage") == .r2000)
    }

    @Test("a valid raw resolves to the mapped engine version")
    func validRawResolves() {
        #expect(DXFDocumentCodec.dxfVersion(fromRaw: "r12") == .r12)
        #expect(DXFDocumentCodec.dxfVersion(fromRaw: "r2000") == .r2000)
        #expect(DXFDocumentCodec.dxfVersion(fromRaw: "r2018") == .r2018)
    }
}

// MARK: - UserDefaults-backed resolver (reads the SAME key the picker writes)

@Suite("DXF version picker — UserDefaults resolution")
struct DXFVersionPickerDefaultsTests {

    /// Save → mutate → restore the shared key around a body so the test never leaks state
    /// into the rest of the suite or the dev's real preferences.
    private func withStoredVersion(_ raw: String?, _ body: () -> Void) {
        let key = AppSettings.Key.dxfExportVersion
        let ud = UserDefaults.standard
        let saved = ud.string(forKey: key)
        defer {
            if let saved { ud.set(saved, forKey: key) } else { ud.removeObject(forKey: key) }
        }
        if let raw { ud.set(raw, forKey: key) } else { ud.removeObject(forKey: key) }
        body()
    }

    @Test("an unset key resolves to .r2000 (default — unchanged behavior)")
    func unsetKeyResolvesToR2000() {
        withStoredVersion(nil) {
            #expect(DXFDocumentCodec.resolvedDXFExportVersion() == .r2000)
        }
    }

    @Test("the resolver reads the stored tier for each valid value")
    func storedKeyResolves() {
        withStoredVersion("r12") {
            #expect(DXFDocumentCodec.resolvedDXFExportVersion() == .r12)
        }
        withStoredVersion("r2018") {
            #expect(DXFDocumentCodec.resolvedDXFExportVersion() == .r2018)
        }
        withStoredVersion("r2000") {
            #expect(DXFDocumentCodec.resolvedDXFExportVersion() == .r2000)
        }
    }

    @Test("a garbage stored value falls back to .r2000 (a corrupt key never breaks Save)")
    func garbageStoredFallsBack() {
        withStoredVersion("not-a-version") {
            #expect(DXFDocumentCodec.resolvedDXFExportVersion() == .r2000)
        }
    }
}

// MARK: - Real save round-trip: the chosen version reaches the $ACADVER header

@Suite("DXF version picker — $ACADVER round-trip through the production codec")
struct DXFVersionPickerACADVerTests {

    /// A minimal but real payload: one LINE on the default layer. Enough for the writer to
    /// emit a full DXF file (HEADER with `$ACADVER` + ENTITIES) regardless of version.
    private func makeLinePayload() -> DXFPayload {
        let line = EntityRecord(
            id: EntityID(1),
            kind: .line(LineData(start: .init(0, 0), end: .init(10, 5))))
        return DXFPayload(entities: [line])
    }

    /// Save → mutate → restore the shared key around a body (mirrors the resolver suite),
    /// so the production codec — which reads `UserDefaults.standard` — sees the chosen
    /// version without polluting other tests.
    private func withStoredVersion(_ raw: String?, _ body: () throws -> Void) rethrows {
        let key = AppSettings.Key.dxfExportVersion
        let ud = UserDefaults.standard
        let saved = ud.string(forKey: key)
        defer {
            if let saved { ud.set(saved, forKey: key) } else { ud.removeObject(forKey: key) }
        }
        if let raw { ud.set(raw, forKey: key) } else { ud.removeObject(forKey: key) }
        try body()
    }

    /// The `$ACADVER` AutoCAD release token libdxfrw writes for each tier (the bridge maps
    /// LC_DXF_R12→AC1009, R2000→AC1015, R2018→AC1032).
    private func acadToken(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        // The DXF HEADER encodes the version as a `$ACADVER` var followed (group code 1)
        // by an `AC10xx` token. Find the first `AC10` token after `$ACADVER`.
        guard let acadRange = text.range(of: "$ACADVER") else { return nil }
        let after = text[acadRange.upperBound...]
        guard let tokRange = after.range(of: #"AC10\d\d"#, options: .regularExpression) else { return nil }
        return String(after[tokRange])
    }

    @Test("default (unset key) writes an R2000/AC1015 header — unchanged behavior")
    func defaultWritesAC1015() throws {
        try withStoredVersion(nil) {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dxf)
            #expect(acadToken(in: data) == "AC1015",
                    "an unset DXF-version preference must write the legacy R2000 ($ACADVER AC1015) header")
        }
    }

    @Test("choosing R12 writes an AC1009 header")
    func r12WritesAC1009() throws {
        try withStoredVersion("r12") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dxf)
            #expect(acadToken(in: data) == "AC1009",
                    "the R12 preference must reach the writer ($ACADVER AC1009)")
        }
    }

    @Test("choosing R2018 writes a modern post-R2000 header (vendored libdxfrw now emits the true AC1032/R2018 DXF token)")
    func r2018WritesModernHeader() throws {
        // The bridge maps the R2018 tier to DRW::AC1032 (see toDrwVersion in lcdxf.cpp).
        // UPSTREAM SYNC (#2603, "DWG round 3"): libdxfrw's DXF text writer previously
        // capped the emitted $ACADVER token at AC1021 (AutoCAD 2007) regardless of the
        // requested version; the rewritten writer now emits the TRUE AC1032 token for an
        // R2018 request. The former cap (and this test's old AC1021 expectation) is gone —
        // the cap-documenting comment foretold exactly this update. The contract this test
        // pins is the user-visible one: selecting R2018 produces a DISTINCT, newer header
        // than the R2000/R12 defaults, and now the most-modern token the tier maps to.
        try withStoredVersion("r2018") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dxf)
            let token = acadToken(in: data)
            #expect(token == "AC1032",
                    "R2018 now emits the true AC1032 token via the rewritten libdxfrw DXF writer (was \(token ?? "nil"))")
            // Regardless of the token, the R2018 selection must NOT collapse to the
            // R2000 / R12 defaults — i.e. the preference genuinely reached the writer.
            #expect(token != "AC1015", "R2018 must not silently fall back to the R2000 default")
            #expect(token != "AC1009", "R2018 must not silently fall back to R12")
        }
    }

    @Test("a garbage stored value still writes the safe R2000/AC1015 default")
    func garbageWritesAC1015() throws {
        try withStoredVersion("not-a-version") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dxf)
            #expect(acadToken(in: data) == "AC1015",
                    "a corrupt preference must fall back to the R2000 default, not break Save")
        }
    }
}
