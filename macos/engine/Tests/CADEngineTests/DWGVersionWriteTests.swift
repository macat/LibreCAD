//
//  DWGVersionWriteTests.swift
//  CADEngineTests
//
//  ┌─────────────────────────────────────────────────────────────────────────┐
//  │  SELF-GENERATED round-trip tests (Lane C — Wave 2 / DWG versioned write) │
//  │                                                                         │
//  │  These tests prove:                                                     │
//  │    1. Our DWG writer emits the requested version's magic bytes.         │
//  │    2. Our DWG reader can reopen a file produced at each new version.    │
//  │    3. "Clamp safety": requesting an unsupported DWG version (.r2007,    │
//  │       .r12, .r14) does NOT raise BAD_VERSION; the file is written and   │
//  │       re-read successfully, with magic clamped to AC1015 (R2000).       │
//  │                                                                         │
//  │  ⚠️  SCOPE NOTE: these tests cover OUR writer ↔ OUR reader only.       │
//  │  They do NOT prove that AutoCAD or any third-party tool can open the    │
//  │  resulting files (foreign fidelity requires a real third-party .dwg     │
//  │  sample fed through ODA/dwgread, which the repo does not ship).         │
//  └─────────────────────────────────────────────────────────────────────────┘
//
//  Versioned DWG support (Lane A) added `writeEntities(...toDWGPath:version:)`.
//  The bridge function `lc_dwg_write` maps the version to libdxfrw's dwgRW:
//    .r2000 → AC1015 (dwgWriter15)
//    .r2004 → AC1018 (dwgWriter18)
//    .r2010 → AC1024 (dwgWriter24)
//    .r2013 → AC1027 (dwgWriter27)
//    .r2018 → AC1032 (dwgWriter32)
//    .r12 / .r14 / .r2007 / unknown → clamped to AC1015
//
//  GPLv2-or-later (LibreCAD derivative).
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Helpers

private func tempDWGPath(tag: String = "ver") -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dwgver-\(tag)-\(UUID().uuidString).dwg").path
}

private func removeFile(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// Read the first 6 bytes of a file and decode them as a UTF-8 string. Throws if the
/// file cannot be read; `#expect`s (does not return early) that the file is longer than
/// 6 bytes, then always returns the decoded 6-byte prefix.
private func readMagic(at path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data.count > 6, "DWG file too short to contain a magic header")
    return String(decoding: data.prefix(6), as: UTF8.self)
}

/// A minimal but real payload: two LINEs + an ARC on the "0" layer.
/// Mirrors the shape of the existing DWGReadWriteTests round-trip fixture.
private func makeSmallPayload() -> ([EntityRecord], LayerTable) {
    let line1 = EntityRecord(
        id: EntityID(1), layer: LayerID("0"),
        kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0))))
    let line2 = EntityRecord(
        id: EntityID(2), layer: LayerID("0"),
        kind: .line(LineData(start: Vector(10, 0), end: Vector(10, 10))))
    let arc = EntityRecord(
        id: EntityID(3), layer: LayerID("0"),
        kind: .arc(ArcData(center: Vector(5, 5), radius: 3,
                           startAngle: 0, endAngle: .pi / 2)))
    let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")
    return ([line1, line2, arc], layers)
}

// MARK: - Per-version magic-byte tests

@Suite("DWG versioned write — magic bytes")
struct DWGVersionMagicTests {

    @Test("r2000 writes AC1015 magic (default version — baseline)")
    func r2000MagicIsAC1015() async throws {
        let (records, layers) = makeSmallPayload()
        let path = tempDWGPath(tag: "r2000")
        defer { removeFile(path) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: .r2000)
        #expect(result.written > 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let magic = try readMagic(at: path)
        #expect(magic == "AC1015",
                ".r2000 must emit the R2000 magic (AC1015); got \(magic)")
    }

    @Test("r2004 writes AC1018 magic")
    func r2004MagicIsAC1018() async throws {
        let (records, layers) = makeSmallPayload()
        let path = tempDWGPath(tag: "r2004")
        defer { removeFile(path) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: .r2004)
        #expect(result.written > 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let magic = try readMagic(at: path)
        #expect(magic == "AC1018",
                ".r2004 must emit the R2004 magic (AC1018); got \(magic)")
    }

    @Test("r2010 writes AC1024 magic")
    func r2010MagicIsAC1024() async throws {
        let (records, layers) = makeSmallPayload()
        let path = tempDWGPath(tag: "r2010")
        defer { removeFile(path) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: .r2010)
        #expect(result.written > 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let magic = try readMagic(at: path)
        #expect(magic == "AC1024",
                ".r2010 must emit the R2010 magic (AC1024); got \(magic)")
    }

    @Test("r2013 writes AC1027 magic")
    func r2013MagicIsAC1027() async throws {
        let (records, layers) = makeSmallPayload()
        let path = tempDWGPath(tag: "r2013")
        defer { removeFile(path) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: .r2013)
        #expect(result.written > 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let magic = try readMagic(at: path)
        #expect(magic == "AC1027",
                ".r2013 must emit the R2013 magic (AC1027); got \(magic)")
    }

    @Test("r2018 writes AC1032 magic")
    func r2018MagicIsAC1032() async throws {
        let (records, layers) = makeSmallPayload()
        let path = tempDWGPath(tag: "r2018")
        defer { removeFile(path) }

        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: .r2018)
        #expect(result.written > 0)
        #expect(FileManager.default.fileExists(atPath: path))

        let magic = try readMagic(at: path)
        #expect(magic == "AC1032",
                ".r2018 must emit the R2018 magic (AC1032); got \(magic)")
    }
}

// MARK: - Per-version reopen round-trip tests

@Suite("DWG versioned write — reopen round-trip")
struct DWGVersionRoundTripTests {

    /// Write at `version`, read back, assert entity count and kinds survive.
    private func roundTrip(version: DXFVersion, tag: String) async throws {
        let (records, layers) = makeSmallPayload()
        // records has 2 LINEs + 1 ARC = 3 entities
        let expectedLines = 2
        let expectedArcs  = 1

        let path = tempDWGPath(tag: tag)
        defer { removeFile(path) }

        let writeResult = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: version)
        #expect(writeResult.written == 3,
                "all 3 entities should write at \(version); skipped=\(writeResult.skipped)")
        #expect(FileManager.default.fileExists(atPath: path))

        let back = try await CADEngine.shared.readEntities(dwgPath: path)
        #expect(!back.records.isEmpty,
                "reader returned no entities after writing at \(version)")
        // The TOTAL count must be exactly 3 — catches spurious extra entities the
        // per-kind tallies below would otherwise miss (e.g. a stray POINT/INSERT).
        #expect(back.records.count == 3,
                "total entity count mismatch after \(version) round-trip: expected 3, got \(back.records.count)")

        var lines = 0, arcs = 0
        for r in back.records {
            switch r.kind {
            case .line: lines += 1
            case .arc:  arcs  += 1
            default:    break
            }
        }
        #expect(lines == expectedLines,
                ".line count mismatch after \(version) round-trip: expected \(expectedLines), got \(lines)")
        #expect(arcs == expectedArcs,
                ".arc count mismatch after \(version) round-trip: expected \(expectedArcs), got \(arcs)")
    }

    @Test("r2004 round-trip: write AC1018, read back 3 entities")
    func r2004RoundTrip() async throws {
        try await roundTrip(version: .r2004, tag: "rt-r2004")
    }

    @Test("r2010 round-trip: write AC1024, read back 3 entities")
    func r2010RoundTrip() async throws {
        try await roundTrip(version: .r2010, tag: "rt-r2010")
    }

    @Test("r2013 round-trip: write AC1027, read back 3 entities")
    func r2013RoundTrip() async throws {
        try await roundTrip(version: .r2013, tag: "rt-r2013")
    }

    @Test("r2018 round-trip: write AC1032, read back 3 entities")
    func r2018RoundTrip() async throws {
        try await roundTrip(version: .r2018, tag: "rt-r2018")
    }
}

// MARK: - Clamp safety (no BAD_VERSION)

@Suite("DWG versioned write — clamp safety")
struct DWGVersionClampTests {

    /// Assert that writing at `version` (unsupported in DWG) does NOT throw, produces
    /// a non-empty file whose magic is AC1015 (clamped to R2000), and the file reopens.
    private func assertClamped(version: DXFVersion, tag: String) async throws {
        let (records, layers) = makeSmallPayload()
        let path = tempDWGPath(tag: tag)
        defer { removeFile(path) }

        // The write must NOT throw — unsupported DWG versions are clamped, not rejected.
        let result = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: path, version: version)
        #expect(FileManager.default.fileExists(atPath: path),
                "clamped write at \(version) must produce a file on disk")
        #expect(result.written > 0,
                "clamped write at \(version) must encode some entities")

        // The file must be non-trivially sized (not a stub).
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 100,
                "clamped DWG at \(version) is suspiciously small: \(data.count) bytes")

        // The magic must be AC1015 — the clamp target.
        let magic = String(decoding: data.prefix(6), as: UTF8.self)
        #expect(magic == "AC1015",
                "unsupported DWG version \(version) must clamp to AC1015; got \(magic)")

        // The file must reopen without error.
        let back = try await CADEngine.shared.readEntities(dwgPath: path)
        #expect(!back.records.isEmpty,
                "clamped file at \(version) must reopen and return entities")
    }

    @Test("r2007 clamps to AC1015 — no BAD_VERSION, file reopens")
    func r2007ClampsToAC1015() async throws {
        try await assertClamped(version: .r2007, tag: "clamp-r2007")
    }

    @Test("r12 clamps to AC1015 — no BAD_VERSION, file reopens")
    func r12ClampsToAC1015() async throws {
        try await assertClamped(version: .r12, tag: "clamp-r12")
    }

    @Test("r14 clamps to AC1015 — no BAD_VERSION, file reopens")
    func r14ClampsToAC1015() async throws {
        try await assertClamped(version: .r14, tag: "clamp-r14")
    }
}
