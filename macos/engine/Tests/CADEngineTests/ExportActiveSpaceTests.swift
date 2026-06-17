//
//  ExportActiveSpaceTests.swift
//  CADEngineTests
//
//  Lane S (EXPORT #6 completion) — pins the `DrawingExporter.exportSpace(forActiveSpace:
//  layout:)` mapping that `ContentView.exportDrawing` now threads into the exporter so a
//  default Export/Print follows the on-screen Model/Layout tab (instead of always `.all`).
//
//  The mapping is the load-bearing pure function for that wiring:
//    • model space            → `.model`
//    • a paper-space layout    → `.paper(layoutName:)` carrying the active layout's name
//    • paper space with no name → `.paper(layoutName: nil)` (matches the live canvas with
//      no active layout — yields nothing, never the whole drawing)
//
//  `DrawingExporter` (app module) is symlinked into this target as
//  `_SharedDrawingExporter.swift`; `EntitySpace`/`ExportSpace` are public CADEngine types.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
@testable import CADEngine

@Suite("Export follows the active drawing space (#6)")
@MainActor
struct ExportActiveSpaceTests {

    @Test("model space maps to .model")
    func modelSpace() {
        #expect(DrawingExporter.exportSpace(forActiveSpace: .model, layout: nil) == .model)
        // The layout name is irrelevant in model space.
        #expect(DrawingExporter.exportSpace(forActiveSpace: .model, layout: "Layout1") == .model)
    }

    @Test("a paper-space layout maps to .paper carrying the active layout name")
    func paperSpaceNamed() {
        #expect(DrawingExporter.exportSpace(forActiveSpace: .paper, layout: "Layout1")
                == .paper(layoutName: "Layout1"))
    }

    @Test("paper space with no active layout maps to .paper(nil), never .all")
    func paperSpaceNoLayout() {
        let mapped = DrawingExporter.exportSpace(forActiveSpace: .paper, layout: nil)
        #expect(mapped == .paper(layoutName: nil))
        #expect(mapped != .all)
    }
}
