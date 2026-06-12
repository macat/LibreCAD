//
//  LibreCADDocumentTests.swift
//  CADEngineTests
//
//  Round-trip tests for the DocumentGroup document layer's OFF-MAIN-SAFE codec
//  (`DXFDocumentCodec`) and its Sendable payload (`DXFPayload`) — the data the
//  `LibreCADDocument` stores in its `init(configuration:)` / `snapshot` /
//  `fileWrapper` entry points (the ones that crashed the old build when they
//  touched a `@MainActor` type). The document source is compiled into the test
//  target via the `_SharedLibreCADDocument.swift` symlink (the same zero-drift
//  pattern the renderer/document-state shared files use).
//
//  The codec deliberately runs OFF the main actor (the document entry points are
//  invoked on a background NSOperationQueue), so these tests exercise it from a
//  background thread — both to mirror the real call site and because the codec's
//  semaphore bridge is only safe off-main.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import UniformTypeIdentifiers
@testable import CADEngine

@Suite("LibreCAD document payload")
struct LibreCADDocumentTests {

    // MARK: - Format routing (DXF vs DWG by content type).

    @Test("the document advertises BOTH DXF and DWG as readable + writable")
    func advertisesDxfAndDwgTypes() {
        let readable = LibreCADDocument.readableContentTypes
        let writable = LibreCADDocument.writableContentTypes
        // DXF (exported UTI) and DWG (system com.autodesk.dwg) are both present.
        #expect(readable.contains(.librecadDXF))
        #expect(readable.contains(.librecadDWG))
        #expect(writable.contains(.librecadDXF))
        #expect(writable.contains(.librecadDWG))
    }

    @Test("content-type classification routes DWG types to .dwg and DXF to .dxf")
    func formatRoutingByContentType() {
        // The system DWG UTI -> .dwg.
        #expect(LibreCADDocument.format(for: .librecadDWG) == .dwg)
        // The extension-derived DWG type (Open / double-click fallback) -> .dwg.
        if let byExt = UTType(filenameExtension: "dwg") {
            #expect(LibreCADDocument.format(for: byExt) == .dwg)
        }
        // DXF types (and the default) -> .dxf.
        #expect(LibreCADDocument.format(for: .librecadDXF) == .dxf)
        if let byExt = UTType(filenameExtension: "dxf") {
            #expect(LibreCADDocument.format(for: byExt) == .dxf)
        }
        // An unrelated type defaults to .dxf (the codec never crashes on it).
        #expect(LibreCADDocument.format(for: .plainText) == .dxf)
    }

    @Test("the codec round-trips an empty payload as DWG via the .dwg format")
    func codecRoundTripsEmptyPayloadAsDWG() async throws {
        let empty = DXFPayload.empty
        let data = try await offMain {
            try DXFDocumentCodec.data(from: empty, format: .dwg)
        }
        #expect(!data.isEmpty)
        // Binary DWG: "AC1015" at byte 0 (distinguishes it from an ASCII DXF).
        #expect(String(decoding: data.prefix(6), as: UTF8.self) == "AC1015")

        let back = try await offMain {
            try DXFDocumentCodec.payload(from: data, format: .dwg)
        }
        #expect(back.entities.isEmpty)
    }

    /// Runs an off-main codec call on a background queue (mirroring how NSDocument
    /// invokes the document entry points) and returns its result, so the test never
    /// blocks a cooperative thread with the codec's semaphore.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    @Test("an empty payload (File ▸ New) serializes and re-reads with no entities")
    func emptyPayloadRoundTrips() async throws {
        let empty = DXFPayload.empty
        #expect(empty.entities.isEmpty)
        // LayerTable() seeds the required default layer "0".
        #expect(empty.layers.contains("0"))

        let data = try await offMain { try DXFDocumentCodec.data(from: empty) }
        #expect(!data.isEmpty)

        let back = try await offMain { try DXFDocumentCodec.payload(from: data) }
        #expect(back.entities.isEmpty)
    }

    @Test("a hand-built payload round-trips its geometry through data → payload")
    func builtPayloadRoundTrips() async throws {
        let line = EntityRecord(
            id: EntityID(1),
            layer: LayerID("walls"),
            kind: .line(LineData(start: Vector(1, 2), end: Vector(10, 20)))
        )
        let circle = EntityRecord(
            id: EntityID(2),
            layer: LayerID("0"),
            kind: .circle(CircleData(center: Vector(5, 5), radius: 3.5))
        )
        let arc = EntityRecord(
            id: EntityID(3),
            layer: LayerID("0"),
            kind: .arc(ArcData(center: Vector(0, 0), radius: 2,
                               startAngle: 0, endAngle: .pi / 2))
        )
        let layers = LayerTable(layers: [Layer(name: "0"), Layer(name: "walls")],
                                activeLayerName: "0")
        let payload = DXFPayload(entities: [line, circle, arc], layers: layers)

        // Serialize OFF-main (the document's fileWrapper path) ...
        let data = try await offMain { try DXFDocumentCodec.data(from: payload) }
        #expect(!data.isEmpty)

        // ... and parse it back OFF-main (the document's init(configuration:) path).
        let back = try await offMain { try DXFDocumentCodec.payload(from: data) }

        var lines = 0, circles = 0, arcs = 0
        let tol = 1e-6
        for r in back.entities {
            switch r.kind {
            case .line(let d):
                lines += 1
                #expect(abs(d.start.x - 1) < tol)
                #expect(abs(d.start.y - 2) < tol)
                #expect(abs(d.end.x - 10) < tol)
                #expect(abs(d.end.y - 20) < tol)
            case .circle(let d):
                circles += 1
                #expect(abs(d.center.x - 5) < tol)
                #expect(abs(d.center.y - 5) < tol)
                #expect(abs(d.radius - 3.5) < tol)
            case .arc(let d):
                arcs += 1
                #expect(abs(d.radius - 2) < tol)
            default:
                break
            }
        }
        #expect(lines == 1)
        #expect(circles == 1)
        #expect(arcs == 1)
        #expect(back.layers.contains("walls"))
    }

    @Test("a payload built from file bytes matches a direct engine read")
    func payloadFromBytesMatchesEngineRead() async throws {
        // Read the bundled sample directly through the engine ...
        let samplePath = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle"
        ).path
        let direct = try await CADEngine.shared.readEntities(dxfPath: samplePath)

        // ... and via the document codec from the SAME bytes (the open path).
        let bytes = try Data(contentsOf: URL(fileURLWithPath: samplePath))
        let payload = try await offMain { try DXFDocumentCodec.payload(from: bytes) }

        // The codec parses the same file the same way, so the entity count matches.
        #expect(payload.entities.count == direct.records.count)
        #expect(payload.layers.layers.count == direct.layers.layers.count)
    }

    @Test("empty/corrupt bytes surface an engine read error (never a crash)")
    func corruptDataReports() async throws {
        // An empty (or otherwise unparseable) file is rejected by libdxfrw; the
        // codec wraps that as `.engine(...)` so the document machinery shows a user
        // alert instead of crashing. (A genuinely missing file wrapper — no bytes at
        // all — is caught earlier by `LibreCADDocument.init`'s `regularFileContents`
        // guard, which throws `.noFileContents`.)
        await #expect(throws: DXFDocumentCodec.CodecError.self) {
            _ = try await offMain { try DXFDocumentCodec.payload(from: Data()) }
        }
    }
}
