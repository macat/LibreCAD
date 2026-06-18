//
//  DWGVersionPickerTests.swift
//  CADEngineTests
//
//  Tests for the DWG-export-version picker on Save-As — the app-layer wiring that lets
//  the user choose which DWG format version (R2000 / R2004 / R2010 / R2013 / R2018) a
//  Save-As DWG writes, persisted as the `app.general.dwgExportVersion` preference and
//  threaded into the engine writer by `DXFDocumentCodec`. The DWG analog of
//  `DXFVersionPickerTests.swift` — mirrors its structure. Covers:
//
//    1. The DWG tier set is EXACTLY the 5 DWG-writable versions {r2000, r2004, r2010,
//       r2013, r2018} — NO R2007/R12/R14 (those return BAD_VERSION from the library;
//       the picker excludes them and the codec clamps to R2000). rawValues are stable
//       + collision-free; every case has a label; R2000 is the default.
//    2. Each `DWGExportVersion.engineVersion` maps to the matching `CADEngine.DXFVersion`.
//    3. The forgiving decoder `AppSettings.dwgExportVersion(fromRaw:)` (a blank / unknown /
//       legacy / NON-DWG-tier string — including "r2007" — falls back to the R2000 default).
//    4. The codec's PURE version resolution `DXFDocumentCodec.dwgVersion(fromRaw:)` (nil /
//       empty / "r2007" / garbage → `.r2000`; a valid raw → the mapped engine version) — no
//       `UserDefaults`, no NSSavePanel, no modal.
//    5. The UserDefaults-backed resolver `resolvedDWGExportVersion()` reads the SAME key the
//       picker writes (`AppSettings.Key.dwgExportVersion`) and falls back to `.r2000` when
//       unset/garbage (key save/restored so the test never pollutes the shared domain).
//    6. A REAL Save-As round-trip through the production codec (`DXFDocumentCodec.data(from:
//       format: .dwg)`) confirms the chosen version reaches the on-disk DWG magic header:
//       R2000 → AC1015, R2018 → AC1032, and the bytes reopen via `payload(from:format:.dwg)`.
//       (Unlike DXF's ASCII `$ACADVER` token, the DWG version string is the 6-byte file head.)
//
//  ⚠️ VERIFICATION CAVEAT (same as DWGReadWriteTests / DWGVersionWriteTests): the Save-As
//  round-trip is SELF-GENERATED — our codec writes, our codec reads. It proves the chosen
//  PREFERENCE reaches the on-disk DWG version, NOT that AutoCAD/other tools open the result
//  (foreign fidelity needs a real third-party `.dwg` + ODA/dwgread).
//
//  Both `AppSettingsView.swift` and `LibreCADDocument.swift` are symlinked into this test
//  target (`_SharedAppSettings.swift` / `_SharedLibreCADDocument.swift`, the established
//  `_Shared*.swift` pattern) so these tests reach the executable-module codec + settings
//  types without importing the GUI. No SwiftUI is touched; no NSSavePanel/modal is reached.
//
//  Suite/type names are domain-namespaced (DWG-prefixed) to avoid the parallel fan-out
//  test-target redeclaration trap (mirrors DXFVersionPicker's naming).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Tier set + tier ↔ engine version mapping

@Suite("DWG version picker — tier set + engine version mapping")
struct DWGVersionPickerMappingTests {

    @Test("allCases is EXACTLY the 5 DWG-writable tiers — no R2007/R12/R14")
    func allCasesAreTheDWGWritableTiers() {
        #expect(DWGExportVersion.allCases == [.r2000, .r2004, .r2010, .r2013, .r2018])
        #expect(DWGExportVersion.allCases.count == 5)
        // Defense: none of the excluded (BAD_VERSION) tiers exist as a DWG case. A
        // DWGExportVersion has no r2007/r12/r14 case, so the strongest assert we can make
        // at the type level is that no rawValue collides with those tier names.
        let raws = Set(DWGExportVersion.allCases.map(\.rawValue))
        #expect(!raws.contains("r2007"), "R2007 must NOT be an exposed DWG tier (BAD_VERSION)")
        #expect(!raws.contains("r12"),   "R12 must NOT be an exposed DWG tier (no DWG writer)")
        #expect(!raws.contains("r14"),   "R14 must NOT be an exposed DWG tier (no DWG writer)")
    }

    @Test("each DWGExportVersion tier maps to the matching CADEngine.DXFVersion")
    func tiersMapToEngineVersions() {
        #expect(DWGExportVersion.r2000.engineVersion == .r2000)
        #expect(DWGExportVersion.r2004.engineVersion == .r2004)
        #expect(DWGExportVersion.r2010.engineVersion == .r2010)
        #expect(DWGExportVersion.r2013.engineVersion == .r2013)
        #expect(DWGExportVersion.r2018.engineVersion == .r2018)
    }

    @Test("rawValue strings are stable + non-empty + collision-free (UserDefaults keys)")
    func rawValuesAreStable() {
        #expect(DWGExportVersion.r2000.rawValue == "r2000")
        #expect(DWGExportVersion.r2004.rawValue == "r2004")
        #expect(DWGExportVersion.r2010.rawValue == "r2010")
        #expect(DWGExportVersion.r2013.rawValue == "r2013")
        #expect(DWGExportVersion.r2018.rawValue == "r2018")
        let raws = DWGExportVersion.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "rawValue collision among DWGExportVersion cases")
        #expect(raws.allSatisfy { !$0.isEmpty })
    }

    @Test("every case has a non-empty Picker label")
    func everyCaseHasALabel() {
        for v in DWGExportVersion.allCases {
            #expect(!v.label.isEmpty, "every DWG tier needs a Picker label")
        }
    }

    @Test("the default export tier is R2000 (the only externally-blessed DWG tier)")
    func defaultTierIsR2000() {
        #expect(AppSettings.Default.dwgExportVersion == .r2000)
        #expect(AppSettings.Default.dwgExportVersion.engineVersion == .r2000)
    }
}

// MARK: - Forgiving decode (settings) — the BAD_VERSION clamp guarantee

@Suite("DWG version picker — AppSettings decode (clamp)")
struct DWGVersionPickerDecodeTests {

    @Test("a valid raw string round-trips to its tier")
    func validRawRoundTrips() {
        #expect(AppSettings.dwgExportVersion(fromRaw: "r2000") == .r2000)
        #expect(AppSettings.dwgExportVersion(fromRaw: "r2004") == .r2004)
        #expect(AppSettings.dwgExportVersion(fromRaw: "r2010") == .r2010)
        #expect(AppSettings.dwgExportVersion(fromRaw: "r2013") == .r2013)
        #expect(AppSettings.dwgExportVersion(fromRaw: "r2018") == .r2018)
    }

    @Test("a NON-DWG tier (r2007/r12/r14) clamps to R2000 — never a BAD_VERSION tier")
    func nonDWGTierClampsToR2000() {
        // This is the safety guarantee: even if a legacy / hand-edited preference carries a
        // tier the DWG writer can't honor, the decode never surfaces it to the writer.
        #expect(AppSettings.dwgExportVersion(fromRaw: "r2007") == .r2000)
        #expect(AppSettings.dwgExportVersion(fromRaw: "r12") == .r2000)
        #expect(AppSettings.dwgExportVersion(fromRaw: "r14") == .r2000)
    }

    @Test("a blank / unknown / legacy raw string falls back to the R2000 default")
    func badRawFallsBack() {
        #expect(AppSettings.dwgExportVersion(fromRaw: "") == .r2000)
        #expect(AppSettings.dwgExportVersion(fromRaw: "garbage") == .r2000)
        #expect(AppSettings.dwgExportVersion(fromRaw: "R2000") == .r2000)  // case-sensitive rawValue
        #expect(AppSettings.dwgExportVersion(fromRaw: "R2018") == .r2000)  // case-sensitive rawValue
    }
}

// MARK: - Codec PURE version resolution (no UserDefaults / no I/O)

@Suite("DWG version picker — codec pure resolution")
struct DWGVersionPickerCodecPureTests {

    @Test("nil / empty / r2007 / garbage raw resolves to .r2000 (the clamp)")
    func absentOrUnsupportedResolvesToR2000() {
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: nil) == .r2000)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "") == .r2000)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "r2007") == .r2000)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "garbage") == .r2000)
    }

    @Test("a valid raw resolves to the mapped engine version")
    func validRawResolves() {
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "r2000") == .r2000)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "r2004") == .r2004)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "r2010") == .r2010)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "r2013") == .r2013)
        #expect(DXFDocumentCodec.dwgVersion(fromRaw: "r2018") == .r2018)
    }
}

// MARK: - UserDefaults-backed resolver (reads the SAME key the picker writes)

@Suite("DWG version picker — UserDefaults resolution")
struct DWGVersionPickerDefaultsTests {

    /// Save → mutate → restore the shared `dwgExportVersion` key around a body so the test
    /// never leaks state into the rest of the suite or the dev's real preferences (mirrors
    /// the DXF resolver suite's hygiene).
    private func withStoredVersion(_ raw: String?, _ body: () -> Void) {
        let key = AppSettings.Key.dwgExportVersion
        let ud = UserDefaults.standard
        let saved = ud.string(forKey: key)
        defer {
            if let saved { ud.set(saved, forKey: key) } else { ud.removeObject(forKey: key) }
        }
        if let raw { ud.set(raw, forKey: key) } else { ud.removeObject(forKey: key) }
        body()
    }

    @Test("the resolver reads the dwgExportVersion key (NOT the DXF key)")
    func resolverReadsTheDWGKey() {
        // Cross-key isolation: storing only the DWG key drives the DWG resolver; the DXF
        // key being unset must not affect it (and vice versa). Stash both keys.
        let dwgKey = AppSettings.Key.dwgExportVersion
        let dxfKey = AppSettings.Key.dxfExportVersion
        let ud = UserDefaults.standard
        let savedDWG = ud.string(forKey: dwgKey)
        let savedDXF = ud.string(forKey: dxfKey)
        defer {
            if let savedDWG { ud.set(savedDWG, forKey: dwgKey) } else { ud.removeObject(forKey: dwgKey) }
            if let savedDXF { ud.set(savedDXF, forKey: dxfKey) } else { ud.removeObject(forKey: dxfKey) }
        }
        ud.set("r2018", forKey: dwgKey)
        ud.removeObject(forKey: dxfKey)
        #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2018,
                "the DWG resolver must read app.general.dwgExportVersion")
    }

    @Test("an unset key resolves to .r2000 (default — unchanged behavior)")
    func unsetKeyResolvesToR2000() {
        withStoredVersion(nil) {
            #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2000)
        }
    }

    @Test("the resolver reads the stored tier for each valid value")
    func storedKeyResolves() {
        withStoredVersion("r2004") {
            #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2004)
        }
        withStoredVersion("r2018") {
            #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2018)
        }
        withStoredVersion("r2000") {
            #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2000)
        }
    }

    @Test("an r2007 / garbage stored value falls back to .r2000 (a bad key never breaks Save)")
    func unsupportedOrGarbageStoredFallsBack() {
        withStoredVersion("r2007") {
            #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2000)
        }
        withStoredVersion("not-a-version") {
            #expect(DXFDocumentCodec.resolvedDWGExportVersion() == .r2000)
        }
    }
}

// MARK: - Real Save-As round-trip: the chosen version reaches the on-disk DWG magic

@Suite("DWG version picker — magic round-trip through the production codec")
struct DWGVersionPickerMagicTests {

    /// A minimal but real payload: one LINE on the default layer. Enough for the codec to
    /// emit a full DWG file (header + entities) regardless of version.
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
        let key = AppSettings.Key.dwgExportVersion
        let ud = UserDefaults.standard
        let saved = ud.string(forKey: key)
        defer {
            if let saved { ud.set(saved, forKey: key) } else { ud.removeObject(forKey: key) }
        }
        if let raw { ud.set(raw, forKey: key) } else { ud.removeObject(forKey: key) }
        try body()
    }

    /// The 6-byte DWG version string at the head of a binary DWG file (e.g. "AC1015").
    /// Unlike DXF's ASCII `$ACADVER` token, the DWG magic IS the first 6 bytes of the file.
    private func dwgMagic(in data: Data) -> String? {
        guard data.count >= 6 else { return nil }
        return String(decoding: data.prefix(6), as: UTF8.self)
    }

    @Test("default (unset key) writes an R2000/AC1015 DWG magic — unchanged behavior")
    func defaultWritesAC1015() throws {
        try withStoredVersion(nil) {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dwg)
            #expect(dwgMagic(in: data) == "AC1015",
                    "an unset DWG-version preference must write the R2000 (AC1015) magic")
        }
    }

    @Test("choosing R2018 writes an AC1032 DWG magic through the codec")
    func r2018WritesAC1032() throws {
        try withStoredVersion("r2018") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dwg)
            let magic = dwgMagic(in: data)
            #expect(magic == "AC1032",
                    "the R2018 DWG preference must reach the writer (AC1032 magic); got \(magic ?? "nil")")
            #expect(magic != "AC1015", "R2018 must not silently fall back to the R2000 default")
        }
    }

    @Test("choosing R2004 writes an AC1018 DWG magic through the codec")
    func r2004WritesAC1018() throws {
        try withStoredVersion("r2004") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dwg)
            #expect(dwgMagic(in: data) == "AC1018",
                    "the R2004 DWG preference must reach the writer (AC1018 magic)")
        }
    }

    @Test("an r2007 stored value still writes the safe R2000/AC1015 default (clamp)")
    func r2007WritesAC1015() throws {
        try withStoredVersion("r2007") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dwg)
            #expect(dwgMagic(in: data) == "AC1015",
                    "an r2007 preference must clamp to the R2000 (AC1015) default, not BAD_VERSION the Save")
        }
    }

    @Test("a garbage stored value still writes the safe R2000/AC1015 default")
    func garbageWritesAC1015() throws {
        try withStoredVersion("not-a-version") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dwg)
            #expect(dwgMagic(in: data) == "AC1015",
                    "a corrupt preference must fall back to the R2000 default, not break Save")
        }
    }

    @Test("a chosen DWG version round-trips: write R2018, reopen the bytes through the codec")
    func chosenVersionReopens() throws {
        try withStoredVersion("r2018") {
            let data = try DXFDocumentCodec.data(from: makeLinePayload(), format: .dwg)
            #expect(dwgMagic(in: data) == "AC1032")
            // Reopen the produced bytes through the production read path — proves the
            // chosen-version file is not just well-headed but genuinely re-readable.
            let payload = try DXFDocumentCodec.payload(from: data, format: .dwg)
            let lines = payload.entities.filter {
                if case .line = $0.kind { return true } else { return false }
            }
            #expect(lines.count == 1, "the single LINE must survive the R2018 codec round-trip")
        }
    }
}
