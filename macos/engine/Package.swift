// swift-tools-version: 6.2
//
//  Package.swift
//  LibreCAD macOS port (GPLv2-or-later)
//
//  Offline, SwiftPM-only build:
//    - DxfBridge:      C++ wrapper over the vendored libdxfrw, exposing a pure
//                      C ABI (no Swift C++ interop needed).
//    - CADEngine:      pure-Swift math core + DXF entry point.
//    - LibreCADmacOS:  SwiftUI/Metal app executable (assembled into a .app by
//                      macos/scripts/make-app.sh).
//    - CADEngineTests: unit tests for the math core and the DXF bridge.
//

import PackageDescription

/// Pin the Swift 6 language mode on every Swift target so strict concurrency is
/// an explicit, frozen part of the build contract — not something inherited from
/// the toolchain default (which can drift between Xcode releases).
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "LibreCADmacOS",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "CADEngine", targets: ["CADEngine"]),
        .executable(name: "LibreCADmacOS", targets: ["LibreCADmacOS"]),
        // Additive: the scale benchmark harness (perf profiling). Not part of the
        // app or the test suite — run explicitly via `swift run ... CADBench`.
        .executable(name: "CADBench", targets: ["CADBench"]),
    ],
    targets: [
        // MARK: - C++ bridge over libdxfrw, exposed as a plain C module.
        .target(
            name: "DxfBridge",
            path: "Sources/DxfBridge",
            // Sources are listed explicitly: our shim plus the 23 libdxfrw
            // translation units (reached through the `libdxfrw` symlink). DWG
            // example/test trees are excluded by simply not listing them.
            sources: [
                "lcdxf.cpp",
                // libdxfrw/src/*.cpp (7)
                "libdxfrw/drw_base.cpp",
                "libdxfrw/drw_classes.cpp",
                "libdxfrw/drw_entities.cpp",
                "libdxfrw/drw_header.cpp",
                "libdxfrw/drw_objects.cpp",
                "libdxfrw/libdwgr.cpp",
                "libdxfrw/libdxfrw.cpp",
                // libdxfrw/src/intern/*.cpp (16)
                "libdxfrw/intern/drw_dbg.cpp",
                "libdxfrw/intern/drw_textcodec.cpp",
                "libdxfrw/intern/dwgbuffer.cpp",
                "libdxfrw/intern/dwgbufferw.cpp",
                "libdxfrw/intern/dwgwriter15.cpp",
                "libdxfrw/intern/dwgreader.cpp",
                "libdxfrw/intern/dwgreader15.cpp",
                "libdxfrw/intern/dwgreader18.cpp",
                "libdxfrw/intern/dwgreader21.cpp",
                "libdxfrw/intern/dwgreader24.cpp",
                "libdxfrw/intern/dwgreader27.cpp",
                "libdxfrw/intern/dwgreader32.cpp",
                "libdxfrw/intern/dwgutil.cpp",
                "libdxfrw/intern/dxfreader.cpp",
                "libdxfrw/intern/dxfwriter.cpp",
                "libdxfrw/intern/rscodec.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                // libdxfrw includes its internal headers by bare/relative name
                // (e.g. "intern/foo.h", and headers inside intern/ include each
                // other by bare name), so both dirs must be on the search path.
                .headerSearchPath("libdxfrw"),
                .headerSearchPath("libdxfrw/intern"),
            ]
        ),

        // MARK: - Pure Swift engine.
        .target(
            name: "CADEngine",
            dependencies: ["DxfBridge"],
            path: "Sources/CADEngine",
            swiftSettings: swift6
        ),

        // MARK: - SwiftUI + Metal app.
        .executableTarget(
            name: "LibreCADmacOS",
            dependencies: ["CADEngine"],
            path: "Sources/LibreCADmacOS",
            swiftSettings: swift6
        ),

        // MARK: - Scale benchmark harness (additive; perf profiling).
        //
        // A standalone executable that measures the engine/render hot paths at
        // 100k / 500k / 1M synthetic entities (macos/docs/perf-report.md). It
        // depends on the CADEngine library and compiles the GPU-FREE renderer
        // geometry directly via symlinks (`_Shared*.swift`) — the same
        // zero-drift pattern the test target uses — so it can time the EXACT
        // shipping `RendererGeometry`/`RendererCull` CPU buffer-build path
        // (the GPU `MTLBuffer` blit is the only step it omits). It is NOT a test
        // target, so `swift test` never runs it.
        .executableTarget(
            name: "CADBench",
            dependencies: ["CADEngine"],
            path: "Sources/CADBench",
            swiftSettings: swift6
        ),

        // MARK: - Tests.
        .testTarget(
            name: "CADEngineTests",
            dependencies: ["CADEngine"],
            path: "Tests/CADEngineTests",
            resources: [
                .copy("Resources/dim_sample.dxf")
            ],
            swiftSettings: swift6
        ),
    ],
    cxxLanguageStandard: .cxx20
)
