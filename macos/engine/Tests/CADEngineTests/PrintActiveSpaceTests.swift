//
//  PrintActiveSpaceTests.swift
//  CADEngineTests
//
//  Export-parity #6 (PRINT half) — pins the space-aware scene the general "Print…"
//  path now builds. `DrawingPrinter.print(_:in:setup:space:)` threads its new
//  `space:` argument into `ExportSceneBuilder.build(drawing, space:)`, and the
//  `ContentView.printDrawing` call site supplies it via the SAME
//  `DrawingExporter.exportSpace(forActiveSpace:layout:)` helper Export uses — so a
//  plain Print follows the on-screen Model/Layout tab (instead of always plotting
//  every space, `.all`).
//
//  The modal `NSPrintOperation` itself is View-layer-only (it would hang a headless
//  test), so — exactly as the brief directs — these tests exercise the LOAD-BEARING
//  scene-builder path with the space parameter, NOT the print op. They assert the
//  same scene the print view would render is correctly space-filtered:
//    • active = model  → the model scene only (no paper-space geometry)
//    • active = paper(layout) → that layout's paper scene only (no model geometry)
//    • the legacy default (`.all`) still unions model + every layout (no regression)
//
//  `DrawingExporter` (app module) is symlinked into this target as
//  `_SharedDrawingExporter.swift`; `ExportSceneBuilder`/`ExportSpace`/`ExportScene`
//  are public `CADEngine` types — so no new symlink is required.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
@testable import CADEngine

@Suite("Print follows the active drawing space (#6, print half)")
@MainActor
struct PrintActiveSpaceTests {

    // MARK: - Fixture

    /// A drawing with ONE model-space line + ONE paper-space line on "Layout1", plus
    /// an empty registered "Layout2". Distinct, non-overlapping geometry per space so
    /// the resulting scene's bounds unambiguously identify which space was captured.
    ///   • model line : (0,0)→(10,0)
    ///   • paper line : (100,100)→(110,100)   (Layout1)
    private func mixedSpaceDrawing() -> (CADDrawing, model: EntityID, paper: EntityID) {
        let d = CADDrawing()
        d.addLayout(Layout(name: "Layout1", tabOrder: 0))
        d.addLayout(Layout(name: "Layout2", tabOrder: 1))
        let modelID = d.add(EntityRecord(
            id: .placeholder,
            kind: .line(LineData(start: Vector(0, 0), end: Vector(10, 0)))))
        let paperID = d.add(EntityRecord(
            id: .placeholder,
            kind: .line(LineData(start: Vector(100, 100), end: Vector(110, 100))),
            space: .paper, layoutName: "Layout1"))
        return (d, modelID, paperID)
    }

    /// The scene the general Print path builds for a given active space — the exact
    /// call `DrawingPrinter.print` makes (`ExportSceneBuilder.build(drawing, space:)`)
    /// fed by the call-site helper `DrawingExporter.exportSpace(...)`.
    private func printScene(_ d: CADDrawing,
                            active space: EntitySpace,
                            layout: String?) -> ExportScene {
        let exportSpace = DrawingExporter.exportSpace(forActiveSpace: space, layout: layout)
        return ExportSceneBuilder.build(d, space: exportSpace)
    }

    /// Whether `scene` contains a polyline whose first vertex equals `p` (an easy way
    /// to assert a particular space's line is — or is not — present).
    private func scene(_ scene: ExportScene, containsStartingAt p: Vector) -> Bool {
        scene.polylines.contains { $0.points.first == p }
    }

    // MARK: - Active = model space

    @Test("active model space prints the model scene only (no paper geometry)")
    func activeModelPrintsModelOnly() {
        let (d, _, _) = mixedSpaceDrawing()
        let s = printScene(d, active: .model, layout: nil)
        #expect(scene(s, containsStartingAt: Vector(0, 0)))       // model line present
        #expect(!scene(s, containsStartingAt: Vector(100, 100)))  // paper line absent
        #expect(s.polylines.count == 1)
        // Bounds are the model line's, NOT the union with paper space.
        #expect(s.bounds.min == Vector(0, 0))
        #expect(s.bounds.max == Vector(10, 0))
    }

    // MARK: - Active = paper space (a layout tab)

    @Test("active paper layout prints that layout's scene only (no model geometry)")
    func activePaperPrintsLayoutOnly() {
        let (d, _, _) = mixedSpaceDrawing()
        let s = printScene(d, active: .paper, layout: "Layout1")
        #expect(scene(s, containsStartingAt: Vector(100, 100)))   // paper line present
        #expect(!scene(s, containsStartingAt: Vector(0, 0)))      // model line absent
        #expect(s.polylines.count == 1)
        #expect(s.bounds.min == Vector(100, 100))
        #expect(s.bounds.max == Vector(110, 100))
    }

    @Test("active paper layout with NO geometry prints an empty scene (not the model)")
    func activeEmptyPaperPrintsNothing() {
        let (d, _, _) = mixedSpaceDrawing()
        // "Layout2" exists but holds no entities — printing it must yield nothing,
        // never fall back to the model space (matches the live empty layout tab).
        let s = printScene(d, active: .paper, layout: "Layout2")
        #expect(s.polylines.isEmpty)
        #expect(s.fills.isEmpty)
    }

    // MARK: - No-regression: the default (.all) still unions every space

    @Test("the default .all space still prints model + every layout (no regression)")
    func defaultAllUnionsEverySpace() {
        let (d, _, _) = mixedSpaceDrawing()
        // The legacy call shape — no `space:` argument — defaults to `.all`, the
        // historical union behavior the print path must preserve for source-compat.
        let s = ExportSceneBuilder.build(d)
        #expect(scene(s, containsStartingAt: Vector(0, 0)))       // model line present
        #expect(scene(s, containsStartingAt: Vector(100, 100)))   // paper line present
        #expect(s.polylines.count == 2)
        // Union bounds span BOTH spaces.
        #expect(s.bounds.min == Vector(0, 0))
        #expect(s.bounds.max == Vector(110, 100))
    }
}
