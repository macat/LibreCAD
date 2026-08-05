//
//  DxfBridgeTests.swift
//  CADEngineTests
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation
@testable import CADEngine

@Suite("DXF bridge")
struct DxfBridgeTests {

    /// Path to the bundled dim_sample.dxf (copied from
    /// librecad/res/dxf/dim_sample.dxf into test resources).
    private func samplePath() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "dim_sample", withExtension: "dxf"),
            "dim_sample.dxf resource missing from the test bundle"
        )
        return url.path
    }

    @Test("counts entities in the bundled sample DXF")
    func countsSample() async throws {
        let engine = CADEngine.shared
        let count = try await engine.entityCount(atPath: samplePath())
        // The sample is non-trivial; the exact count is asserted in
        // `stableCount` once observed on this toolchain.
        #expect(count > 0)
    }

    @Test("entity count is stable")
    func stableCount() async throws {
        let engine = CADEngine.shared
        let count = try await engine.entityCount(atPath: samplePath())
        // Observed count for librecad/res/dxf/dim_sample.dxf via libdxfrw.
        // Update this expectation if the bridge's counted-entity set changes.
        #expect(count == DxfBridgeTests.expectedSampleEntityCount)
    }

    @Test("missing file throws typed badOpen (not generic readFailed)")
    func missingFileThrows() async throws {
        let engine = CADEngine.shared
        // Wave 7: a missing file is now typed as LC_ERR_BAD_OPEN → .badOpen,
        // not the legacy generic readFailed. The detail carries the path + the
        // lc_status_message, suitable for LocalizedError UI.
        do {
            _ = try await engine.entityCount(atPath: "/nonexistent/path/does-not-exist.dxf")
            Issue.record("expected badOpen for missing file")
        } catch let e as CADEngineError {
            guard case .badOpen = e else {
                Issue.record("expected .badOpen for missing file, got \(e)")
                return
            }
            // Typed, not generic — proves the LCStatus → CADEngineError mapping.
            #expect(e.errorDescription?.contains("Cannot open") == true || e.errorDescription?.contains("open") == true)
            // And it must NOT be the generic fallback.
            #expect(e != CADEngineError.readFailed)
        }
    }

    @Test("empty path throws invalidPath")
    func emptyPathThrows() async throws {
        let engine = CADEngine.shared
        // LC_ERR_INVALID_PATH is returned before any parse is attempted.
        await #expect(throws: CADEngineError.invalidPath) {
            _ = try await engine.entityCount(atPath: "")
        }
    }

    /// Observed count for librecad/res/dxf/dim_sample.dxf via libdxfrw on
    /// Swift 6.2.3 / macOS 26 (counting the geometric add* callbacks; tables,
    /// layers, blocks, header, and image/spline definitions are excluded).
    static let expectedSampleEntityCount = 103
}
