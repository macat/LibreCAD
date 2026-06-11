//
//  ShaderCompileTests.swift
//  CADEngineTests
//
//  REGRESSION GUARD for the "blank canvas" class of bug. The Metal renderer
//  compiles its MSL at RUNTIME via `device.makeLibrary(source:)`
//  (LineRenderer.buildPipelines). When that compile fails, the failure was only
//  NSLog'd and swallowed — the app still launched, but rendered a BLANK canvas
//  with no obvious cause. A reserved-word bug (a shader var named `half`, which
//  is a reserved MSL type) shipped exactly this way TWICE before being caught.
//
//  This test compiles the REAL shipping shader source and asserts it both
//  compiles AND exposes every function the renderer looks up by name. It would
//  have caught the `half` bug at `swift test` time, before launch.
//
//  ## Why this file compiles a symlinked source
//  `canvasMetalSource` lives in the `LibreCADmacOS` EXECUTABLE target, which
//  SwiftPM does not produce a linkable library for — so a test target cannot
//  `@testable import` it. The shipping source file is therefore SYMLINKED into
//  this test target (`_SharedShaders.swift -> .../Renderer/Shaders.swift`),
//  matching the existing `_SharedRenderer*.swift` pattern, so this test
//  exercises the EXACT shipping MSL with zero drift.
//
//  ## GPU-free-safe
//  `MTLCreateSystemDefaultDevice()` returns nil on a headless host with no GPU
//  (e.g. some CI). In that case this test no-ops (skips) rather than false-
//  failing. In a real macOS dev/test environment a device exists, so the shader
//  is genuinely compiled — `makeLibrary(source:)` works headlessly (no window
//  required), which is what makes shader compilation unit-testable.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Metal

@Suite("Shader compilation")
struct ShaderCompileTests {

    /// The function names `LineRenderer.buildPipelines` looks up by name. If the
    /// MSL compiles but any of these is missing/renamed, both pipelines silently
    /// fail to build and the canvas renders blank — so we assert each exists.
    private static let requiredFunctions = [
        "line_vertex",
        "line_fragment",
        "flat_vertex",
        "flat_fragment",
    ]

    @Test("real canvasMetalSource compiles and exposes every renderer function")
    func canvasShaderCompilesWithAllFunctions() throws {
        // Headless CI without a GPU → no device. Skip rather than false-fail; a
        // real macOS environment has a device and will actually compile.
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        // The crux: this must NOT throw. The `half` reserved-word bug threw here
        // (and was swallowed in the app), producing the blank canvas.
        let library = try device.makeLibrary(source: canvasMetalSource, options: nil)

        // Compiling is necessary but not sufficient: the renderer also looks each
        // function up by name. A typo/rename would compile but break rendering.
        for name in Self.requiredFunctions {
            #expect(
                library.makeFunction(name: name) != nil,
                "canvasMetalSource is missing required function \(name)"
            )
        }
    }
}
