//
//  main.swift
//  LCShot — the LibreCAD macOS GUI screenshot harness
//
//  A HEADLESS, device-free, panel-free render-to-PNG tool. It drives a real
//  `CanvasModel` from a small JSON action script (see `ActionScript.swift`) and
//  renders the resulting drawing's COMMITTED geometry to a PNG via the SAME export
//  path the `RasterExportTests` use (`ExportSceneBuilder.build` →
//  `DrawingExporter.rasterData`). No Metal, no window, no `NSApplication`, no
//  save/open panel — so an AI coordinator can run it from bash, open the PNG, and
//  visually verify how a feature behaved.
//
//  ## Usage
//      swift run --package-path macos/engine --disable-sandbox LCShot <scene.json> [out.png]
//      swift run ... LCShot --demo <out.png>      # the built-in hardcoded single-line proof
//
//  ## Coverage ceiling (be honest about this — see `--help`)
//  The PNG shows COMMITTED geometry only, framed fit-to-page. It does NOT show:
//  the grid, selection highlight, snap marker, in-flight tool preview, crosshair,
//  gizmo/grips, the constraint glyph, the live-dimension chip, or any SwiftUI
//  chrome (menus / sheets / sidebar / layout tabs / Preferences).
//
//  `MainActor.assumeIsolated { run() }` mirrors CADBench: this is the SAFE place
//  for `assumeIsolated` (it SIGTRAPs in `App.init()` — never put it there).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import CoreGraphics
import CADEngine

// MARK: - Entry point

MainActor.assumeIsolated {
    let args = Array(CommandLine.arguments.dropFirst())
    exit(LCShot.run(args))
}

// MARK: - Top-level driver

@MainActor
enum LCShot {

    static let helpText = """
    LCShot — the LibreCAD macOS GUI screenshot harness (headless render-to-PNG).

    USAGE
      LCShot <scene.json> [out.png]   Run a JSON action script, render to a PNG.
      LCShot --demo [out.png]         Render the built-in hardcoded single-line proof.
      LCShot --help                   Show this help.

    The PNG shows the drawing's COMMITTED geometry, framed fit-to-page, on the
    CAD canvas background. It does NOT show chrome: no grid, selection highlight,
    snap marker, in-flight tool preview, crosshair, grips/gizmo, constraint glyph,
    live-dimension chip, or any SwiftUI UI (menus/sheets/sidebar/layout-tabs/Prefs).

    SCENE FORMAT — a JSON object:
      {
        "dpi": 150,                     (optional; default 150)
        "background": "#RRGGBB",        (optional; default = CAD canvas dark bg)
        "actions": [ {"op":"...", ...}, ... ]
      }
    (`space`/`layout` are accepted in the header but only pre-select MODEL space;
    switch INTO a paper layout via the `addLayout` + `layout`/`space` ACTIONS, which
    run after the layout exists.) See `ActionScript.swift` for the supported `op`
    verbs (allow-listed; any verb needing a file/open/save panel is EXCLUDED so the
    headless path cannot hang).

    A constraint that the solver does not support (e.g. tangent/collinear) or that is
    given the wrong entity arity is a NO-OP: the harness keeps exit 0 and prints a
    `WARN:`-prefixed line on stdout, so silent no-ops are greppable rather than hidden.
    """

    /// Returns a process exit code (0 == success).
    static func run(_ args: [String]) -> Int32 {
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data((helpText + "\n").utf8))
            return 2
        }
        switch args[0] {
        case "--help", "-h":
            print(helpText)
            return 0
        case "--demo":
            let out = args.count > 1 ? args[1] : "lcshot-demo.png"
            return runDemo(outPath: out)
        default:
            let scenePath = args[0]
            let outOverride = args.count > 1 ? args[1] : nil
            return runScene(scenePath: scenePath, outOverride: outOverride)
        }
    }

    // MARK: - Part 1 proof: a hardcoded single line → PNG

    /// The minimal end-to-end proof (Part 1 GATE 1): construct a drawing with ONE
    /// line, fit the viewport, and render to a non-blank PNG through the panel-free
    /// raster path. Kept as `--demo` so the smoke path is always available.
    static func runDemo(outPath: String) -> Int32 {
        let drawing = CADDrawing()
        let model = CanvasModel(drawing: drawing,
                                viewSize: CGSize(width: 800, height: 600))
        // Add one hardcoded line directly (id minted by `add`).
        model.drawing.add(EntityRecord(
            id: EntityID(0),
            kind: .line(LineData(start: Vector(0, 0), end: Vector(100, 60)))))
        model.zoomToFit()

        do {
            let url = try Capture.render(model: model,
                                         to: outPath,
                                         dpi: DrawingExporter.defaultRasterDPI,
                                         background: Capture.canvasBackground,
                                         writeAssert: false)
            print("LCShot --demo: wrote \(url.path)")
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("LCShot --demo error: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Scene runner

    static func runScene(scenePath: String, outOverride: String?) -> Int32 {
        let url = URL(fileURLWithPath: scenePath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            FileHandle.standardError.write(
                Data("LCShot: cannot read scene '\(scenePath)': \(error)\n".utf8))
            return 1
        }

        let scene: ActionScene
        do {
            scene = try ActionScene.decode(data)
        } catch {
            FileHandle.standardError.write(
                Data("LCShot: malformed scene '\(scenePath)': \(error)\n".utf8))
            return 1
        }

        do {
            try ActionScene.execute(scene, sourcePath: scenePath, outOverride: outOverride)
            return 0
        } catch let e as LCShotError {
            FileHandle.standardError.write(Data("LCShot error: \(e.message)\n".utf8))
            return e.exitCode
        } catch {
            FileHandle.standardError.write(Data("LCShot error: \(error)\n".utf8))
            return 1
        }
    }
}

// MARK: - Errors

/// A harness error that carries a non-zero exit code (so an excluded/unknown verb
/// fails the process instead of hanging or silently no-op'ing).
struct LCShotError: Error {
    let message: String
    var exitCode: Int32 = 1
}
