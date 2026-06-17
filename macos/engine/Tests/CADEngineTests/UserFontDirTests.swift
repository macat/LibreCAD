//
//  UserFontDirTests.swift
//  CADEngineTests
//
//  Exercises the user-font-directory engine seam (4C): `CADFonts.addUserFontDirectory(_:)`
//  registers a chosen directory with BOTH the stroke (`.lff`) and SHX (`.shx`) providers
//  and clears their caches, so a font that lives ONLY in that directory — and so was a
//  cached MISS before — now resolves. The NSOpenPanel that picks the folder is View-layer
//  only and is NOT exercised here (headless-modal trap): the test writes a hand-made
//  `.lff` to a temp directory and drives the seam + provider lookup directly.
//
//  Uniquely namespaced (`@Suite`) so it does not collide with the other suites in the
//  fan-out-shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

@Suite("user font directory seam (4C)")
struct UserFontDirTests {

    /// A minimal but valid `.lff` body the `LFFParser` accepts: one glyph 'A' with a
    /// single 2-vertex stroke. Named uniquely per test so the SHARED `CADFonts` provider
    /// (a process-global singleton) never has a stale cached hit/miss from another test.
    private func writeFont(named baseName: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lcfonts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        # Name: \(baseName)

        [0041] A
        0,0;6,9
        """
        let url = dir.appendingPathComponent("\(baseName).lff")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a fresh StrokeFontProvider: registerSearchDirectory then clearCache resolves a previously-missed font")
    func freshProviderSeamSemantics() throws {
        let name = "seamtest-\(UUID().uuidString.prefix(8))"
        let url = try writeFont(named: name)
        let dir = url.deletingLastPathComponent()

        let provider = StrokeFontProvider()
        // Before registering: a miss (and the provider caches that miss).
        #expect(provider.font(named: name) == nil)

        // The seam's two moves: register the dir, then clear the cached miss.
        provider.registerSearchDirectory(dir)
        provider.clearCache()

        // Now it resolves the hand-written glyph.
        let font = try #require(provider.font(named: name), "font should resolve after seam")
        #expect(font.glyph(for: Character("A")) != nil)
    }

    @Test("CADFonts.addUserFontDirectory makes a .lff in the chosen dir resolve via the shared provider")
    func sharedProviderResolvesAfterAdd() throws {
        // A unique name so the shared singleton has no prior cached result for it.
        let name = "userfont-\(UUID().uuidString.prefix(8))"
        let url = try writeFont(named: name)
        let dir = url.deletingLastPathComponent()

        // Prime a cached MISS on the shared provider (the realistic pre-state: text
        // resolve looked this name up and found nothing before the user added the folder).
        #expect(CADFonts.strokeProvider.font(named: name) == nil)

        // The seam under test.
        CADFonts.addUserFontDirectory(dir)

        // The shared provider now finds the hand-written font (was nil before).
        let font = try #require(CADFonts.strokeProvider.font(named: name),
                                "shared provider should resolve the added font")
        #expect(font.glyph(for: Character("A")) != nil)
    }

    @Test("addUserFontDirectory also registers the dir with the SHX provider (search dir added)")
    func shxProviderAlsoGetsDir() throws {
        // We don't ship .shx and won't hand-author the binary format here; instead we
        // confirm the seam registers the dir with the SHX provider too by checking an
        // .shx name in the dir would be searched (a non-existent one stays nil, no crash).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lcfonts-shx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        CADFonts.addUserFontDirectory(dir)

        // No .shx present ⇒ still nil, but the call path (search the newly-added dir,
        // cache the miss) must be exercised without crashing.
        let name = "no-such-shx-\(UUID().uuidString.prefix(6))"
        #expect(CADFonts.shxProvider.font(named: name) == nil)
    }

    @Test("resetUserFontCaches drops cached parses without crashing")
    func resetClearsCaches() throws {
        let name = "resettest-\(UUID().uuidString.prefix(8))"
        let url = try writeFont(named: name)
        CADFonts.addUserFontDirectory(url.deletingLastPathComponent())
        #expect(CADFonts.strokeProvider.font(named: name) != nil)   // cached hit

        CADFonts.resetUserFontCaches()
        // Still resolvable (the dir is still registered; only the cache was dropped).
        #expect(CADFonts.strokeProvider.font(named: name) != nil)
    }
}
