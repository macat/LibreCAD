//
//  DWGReadWriteTests.swift
//  CADEngineTests
//
//  Tests for the DWG (binary AutoCAD) read/write path added through the DxfBridge
//  C ABI (`lc_dwg_read` / `lc_dwg_write` → libdxfrw `dwgRW`) and surfaced on the
//  engine as `CADEngine.readEntities(dwgPath:)` / `writeEntities(...toDWGPath:)`.
//
//  No real `.dwg` sample ships in the repo (binary AutoCAD samples are not
//  redistributable), so the round-trip is SELF-GENERATED: a hand-built drawing is
//  written to a temp `.dwg` through the new write path, then read back through the
//  new read path, and the geometry is asserted to survive. This exercises BOTH
//  bridge directions against a real on-disk R2000 DWG file produced by libdxfrw's
//  own writer — the same write+read round-trip the C++ `dwg_write_smoke_tests`
//  validate at the library level.
//
//  ⚠️ VERIFICATION CAVEAT: this proves we read what our OWN writer emits. It does
//  NOT prove we read DWG files produced by AutoCAD/other CAD apps — that needs a
//  real third-party `.dwg` sample, which the repo does not (and likely cannot)
//  ship. libdxfrw's reader is the same code LibreCAD uses for real-world DWGs, so
//  read fidelity on foreign files rides on that shared library; this suite covers
//  the wiring (routing, POD mapping, ABI) end-to-end.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DWG read/write")
struct DWGReadWriteTests {

    /// A fresh temp .dwg path in the system temp dir; the caller cleans it up.
    private func tempDWGPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("dwgrw-test-\(UUID().uuidString).dwg").path
    }

    private func removeFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Error paths (no file needed).

    @Test("empty DWG path throws invalidPath on read")
    func emptyReadPathThrows() async throws {
        await #expect(throws: CADEngineError.invalidPath) {
            _ = try await CADEngine.shared.readEntities(dwgPath: "")
        }
    }

    @Test("missing DWG file throws readFailed")
    func missingReadFileThrows() async throws {
        await #expect(throws: CADEngineError.readFailed) {
            _ = try await CADEngine.shared.readEntities(
                dwgPath: "/nonexistent/path/does-not-exist.dwg")
        }
    }

    @Test("empty DWG write path throws invalidPath")
    func emptyWritePathThrows() async throws {
        await #expect(throws: CADWriteError.invalidPath) {
            _ = try await CADEngine.shared.writeEntities(
                [], layers: LayerTable(), toDWGPath: "")
        }
    }

    // MARK: - The key self-generated round-trip.

    @Test("hand-built geometry round-trips through DWG write → read")
    func roundTripsBuiltGeometryThroughDWG() async throws {
        // One of each simple primitive the DWG writer (dwgWriter15) encodes.
        let point = EntityRecord(
            id: EntityID(1), layer: LayerID("0"),
            kind: .point(PointData(position: Vector(1.5, 2.5))))
        let line = EntityRecord(
            id: EntityID(2), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 5))))
        let circle = EntityRecord(
            id: EntityID(3), layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(100, 100), radius: 25)))
        let arc = EntityRecord(
            id: EntityID(4), layer: LayerID("0"),
            kind: .arc(ArcData(center: Vector(50, 50), radius: 10,
                               startAngle: 0, endAngle: .pi)))
        let records = [point, line, circle, arc]
        let layers = LayerTable(layers: [Layer(name: "0")], activeLayerName: "0")

        let outPath = tempDWGPath()
        defer { removeFile(outPath) }

        // Write a real R2000 DWG via the new path; nothing should be skipped.
        let writeResult = try await CADEngine.shared.writeEntities(
            records, layers: layers, toDWGPath: outPath)
        #expect(writeResult.skipped == 0)
        #expect(writeResult.written == 4)
        #expect(FileManager.default.fileExists(atPath: outPath))

        // The on-disk file is a binary DWG: the version string "AC1015" is at byte 0.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
        #expect(bytes.count > 100)
        let header = String(decoding: bytes.prefix(6), as: UTF8.self)
        #expect(header == "AC1015")

        // Read it back through the new DWG read path and confirm the geometry survives.
        let back = try await CADEngine.shared.readEntities(dwgPath: outPath)
        #expect(!back.records.isEmpty)

        var points = 0, lines = 0, circles = 0, arcs = 0
        let tol = 1e-6
        for r in back.records {
            switch r.kind {
            case .point(let d):
                points += 1
                #expect(abs(d.position.x - 1.5) < tol)
                #expect(abs(d.position.y - 2.5) < tol)
            case .line(let d):
                lines += 1
                #expect(abs(d.start.x - 0) < tol)
                #expect(abs(d.end.x - 10) < tol)
                #expect(abs(d.end.y - 5) < tol)
            case .circle(let d):
                circles += 1
                #expect(abs(d.center.x - 100) < tol)
                #expect(abs(d.center.y - 100) < tol)
                #expect(abs(d.radius - 25) < tol)
            case .arc(let d):
                arcs += 1
                #expect(abs(d.center.x - 50) < tol)
                #expect(abs(d.radius - 10) < tol)
            default:
                break
            }
        }
        #expect(points == 1)
        #expect(lines == 1)
        #expect(circles == 1)
        #expect(arcs == 1)
    }

    @Test("an empty drawing writes a valid DWG and re-reads with no entities")
    func emptyDrawingRoundTripsThroughDWG() async throws {
        let outPath = tempDWGPath()
        defer { removeFile(outPath) }

        let writeResult = try await CADEngine.shared.writeEntities(
            [], layers: LayerTable(), toDWGPath: outPath)
        #expect(writeResult.skipped == 0)
        #expect(writeResult.written == 0)
        #expect(FileManager.default.fileExists(atPath: outPath))

        let back = try await CADEngine.shared.readEntities(dwgPath: outPath)
        #expect(back.records.isEmpty)
        // libdxfrw's DWG reader always delivers the standard layer "0".
        #expect(back.layers.contains("0"))
    }

    @Test("a DXF file is NOT a valid DWG — the DWG reader rejects it")
    func dwgReaderRejectsDXF() async throws {
        // Write a DXF, then try to read it as DWG: the binary parser must fail
        // (proving the two read paths are genuinely distinct, not aliases).
        let dxfPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dwgrw-cross-\(UUID().uuidString).dxf").path
        defer { removeFile(dxfPath) }
        let line = EntityRecord(
            id: EntityID(1), layer: LayerID("0"),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(1, 1))))
        _ = try await CADEngine.shared.writeEntities(
            [line], layers: LayerTable(), toPath: dxfPath)

        await #expect(throws: CADEngineError.readFailed) {
            _ = try await CADEngine.shared.readEntities(dwgPath: dxfPath)
        }
    }
}
