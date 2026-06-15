//
//  NamedViewTests.swift
//  CADEngineTests
//
//  Unit tests for Named Views (LibreCAD / AutoCAD parity): the pure `NamedView`
//  capture/apply viewport math, the ordered name-unique `NamedViewTable` ops, and
//  the `CanvasModel` save / restore / delete plumbing. All GUI-free: the name
//  PROMPT + the name PICKER are AppKit panels in the View layer (LibreCADApp), so
//  they are never exercised here — these tests drive the testable core directly.
//
//  Suite names are domain-prefixed (CONVENTIONS.md "Namespace test-suite type
//  names by domain") to avoid a test-target namespace clash.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
import CoreGraphics
@testable import CADEngine

// MARK: - Pure NamedView capture / apply (the testable viewport math)

@Suite("NamedView — capture / apply viewport math")
struct NamedViewCaptureTests {

    private static let tol = 1e-12

    private func viewport(scale: Double, center: Vector,
                          size: CGSize = CGSize(width: 800, height: 600)) -> Viewport {
        Viewport(scale: scale, center: center, size: size)
    }

    @Test("capture records the viewport's center + scale (rotation 0, no size)")
    func captureRecordsState() {
        let vp = viewport(scale: 7.5, center: Vector(120, -45))
        let nv = NamedView.capture(vp, name: "Iso")
        #expect(nv.name == "Iso")
        #expect(nv.center == Vector(120, -45))
        #expect(abs(nv.scale - 7.5) < Self.tol)
        #expect(nv.rotation == 0)
    }

    @Test("apply restores center + scale but KEEPS the target viewport's size")
    func applyKeepsTargetSize() {
        let saved = NamedView(name: "A", center: Vector(10, 20), scale: 3)
        // A different live viewport: different center, scale, AND a different window size.
        let live = viewport(scale: 1, center: Vector(0, 0),
                            size: CGSize(width: 1280, height: 720))
        let restored = saved.apply(to: live)
        #expect(restored.center == Vector(10, 20))
        #expect(abs(restored.scale - 3) < Self.tol)
        // Size is the LIVE one (re-frame into the current window), not a captured size.
        #expect(restored.size == CGSize(width: 1280, height: 720))
    }

    @Test("capture→apply round-trips center + scale exactly (same view size)")
    func roundTrip() {
        let centers = [Vector(0, 0), Vector(123.456, -789.012), Vector(-1e6, 5e5)]
        let scales = [0.05, 1, 42.0, 1000.0]
        for c in centers {
            for s in scales {
                let vp = viewport(scale: s, center: c)
                let nv = NamedView.capture(vp, name: "rt")
                let back = nv.apply(to: vp)
                #expect(back.center == vp.center)
                #expect(abs(back.scale - vp.scale) < Self.tol)
                #expect(back.size == vp.size)
            }
        }
    }

    @Test("init clamps a non-positive scale and sanitizes an invalid center")
    func initClampsGarbage() {
        let nv = NamedView(name: "g", center: .invalid, scale: -5)
        #expect(nv.center == Vector(0, 0))         // invalid center → origin
        #expect(nv.scale >= Viewport.minScale)     // non-positive scale → floor
    }

    @Test("NamedView is Codable (round-trips through JSON)")
    func codableNamedView() throws {
        let nv = NamedView(name: "Detail", center: Vector(3, 4), scale: 2.5, rotation: 0)
        let data = try JSONEncoder().encode(nv)
        let back = try JSONDecoder().decode(NamedView.self, from: data)
        #expect(back == nv)
    }
}

// MARK: - NamedViewTable ops (ordered, name-unique)

@Suite("NamedViewTable — add / get / rename / delete (ordered, unique)")
struct NamedViewTableOpsTests {

    private func nv(_ name: String, _ x: Double = 0) -> NamedView {
        NamedView(name: name, center: Vector(x, 0), scale: 1)
    }

    @Test("a fresh table is empty")
    func emptyTable() {
        let t = NamedViewTable()
        #expect(t.isEmpty)
        #expect(t.count == 0)
        #expect(t.names.isEmpty)
        #expect(t.view(named: "x") == nil)
        #expect(!t.contains("x"))
    }

    @Test("upsert appends in insertion order + is retrievable case-insensitively")
    func upsertAppendsOrdered() {
        var t = NamedViewTable()
        // (The mutating ops are called on their own lines: the `#expect` macro cannot
        // call a `mutating` member on a `var` — it captures the value immutably.)
        let a = t.upsert(nv("First"))
        let b = t.upsert(nv("Second"))
        let c = t.upsert(nv("Third"))
        #expect(a && b && c)
        #expect(t.count == 3)
        #expect(t.names == ["First", "Second", "Third"])
        #expect(t.contains("second"))                       // case-insensitive
        #expect(t.view(named: "THIRD")?.name == "Third")
    }

    @Test("upsert trims the name and rejects a blank one")
    func upsertTrimsAndRejectsBlank() {
        var t = NamedViewTable()
        let added = t.upsert(nv("  Spaced  "))
        #expect(added)
        #expect(t.names == ["Spaced"])                      // stored trimmed
        let blank = t.upsert(nv("   "))
        #expect(!blank)                                     // blank → rejected
        #expect(t.count == 1)
    }

    @Test("upsert on a case-insensitive clash REPLACES in place (keeps position)")
    func upsertReplacesInPlace() {
        var t = NamedViewTable()
        t.upsert(nv("Plan", 1))
        t.upsert(nv("Side", 2))
        // Re-save "PLAN" (different case, new captured state) — must overwrite, not append.
        let replaced = t.upsert(NamedView(name: "PLAN", center: Vector(99, 0), scale: 5))
        #expect(replaced)
        #expect(t.count == 2)
        #expect(t.names == ["PLAN", "Side"])                // position kept, casing updated
        #expect(t.view(named: "plan")?.center == Vector(99, 0))
        #expect(t.view(named: "plan")?.scale == 5)
    }

    @Test("upsert of an identical entry is a no-op (returns false)")
    func upsertIdenticalNoOp() {
        var t = NamedViewTable()
        t.upsert(nv("Same", 7))
        let again = t.upsert(nv("Same", 7))
        #expect(!again)                                     // unchanged → false
        #expect(t.count == 1)
    }

    @Test("remove deletes by name (case-insensitive); absent is a no-op")
    func removeByName() {
        var t = NamedViewTable()
        t.upsert(nv("A")); t.upsert(nv("B")); t.upsert(nv("C"))
        let removed = t.remove(named: "b")                  // case-insensitive
        #expect(removed)
        #expect(t.names == ["A", "C"])
        let absent = t.remove(named: "Z")
        #expect(!absent)                                    // absent → false
        #expect(t.count == 2)
    }

    @Test("rename keeps the entry's position + captured state")
    func renameKeepsPositionAndState() {
        var t = NamedViewTable()
        t.upsert(nv("One", 1)); t.upsert(nv("Two", 2)); t.upsert(nv("Three", 3))
        let ok = t.rename("Two", to: "Middle")
        #expect(ok)
        #expect(t.names == ["One", "Middle", "Three"])      // position unchanged
        #expect(t.view(named: "Middle")?.center == Vector(2, 0))  // state preserved
    }

    @Test("rename rejects a clash with a DIFFERENT view, a blank, or an absent source")
    func renameRejects() {
        var t = NamedViewTable()
        t.upsert(nv("Alpha")); t.upsert(nv("Beta"))
        let clash = t.rename("Alpha", to: "beta")           // clashes with Beta
        let blank = t.rename("Alpha", to: "   ")            // blank
        let absent = t.rename("Ghost", to: "Anything")      // absent source
        #expect(!clash && !blank && !absent)
        #expect(t.names == ["Alpha", "Beta"])               // table unchanged
    }

    @Test("rename allows a casing-only self-rename of the same entry")
    func renameCasingOnly() {
        var t = NamedViewTable()
        t.upsert(nv("Plan"))
        let ok = t.rename("plan", to: "PLAN")
        #expect(ok)
        #expect(t.names == ["PLAN"])
    }

    @Test("NamedViewTable is Codable (round-trips through JSON, preserving order)")
    func codableTable() throws {
        var t = NamedViewTable()
        t.upsert(nv("X", 1)); t.upsert(nv("Y", 2))
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(NamedViewTable.self, from: data)
        #expect(back == t)
        #expect(back.names == ["X", "Y"])
    }
}

// MARK: - CanvasModel save / restore / delete (session plumbing)

@MainActor
@Suite("CanvasModel — named-view save / restore / delete")
struct CanvasModelNamedViewTests {

    private static let tol = 1e-12

    private func makeModel() -> CanvasModel {
        CanvasModel(viewSize: CGSize(width: 800, height: 600))
    }

    @Test("a fresh model has no named views")
    func freshModelEmpty() {
        let model = makeModel()
        #expect(!model.hasNamedViews)
        #expect(model.namedViewNames.isEmpty)
    }

    @Test("saveNamedView captures the CURRENT viewport and lists the trimmed name")
    func saveCapturesCurrentViewport() {
        let model = makeModel()
        model.viewport = Viewport(scale: 4, center: Vector(50, 60),
                                  size: model.viewport.size)
        let name = model.saveNamedView(name: "  Overview  ")
        #expect(name == "Overview")                         // trimmed
        #expect(model.hasNamedViews)
        #expect(model.namedViewNames == ["Overview"])
        let saved = model.namedViews.view(named: "Overview")
        #expect(saved?.center == Vector(50, 60))
        #expect(saved.map { abs($0.scale - 4) < Self.tol } == true)
    }

    @Test("saveNamedView rejects a blank name (nothing saved)")
    func saveRejectsBlank() {
        let model = makeModel()
        #expect(model.saveNamedView(name: "   ") == nil)
        #expect(!model.hasNamedViews)
    }

    @Test("restoreNamedView sets the viewport's center + scale, keeps the size")
    func restoreSetsViewport() {
        let model = makeModel()
        // Save a distinct viewport.
        model.viewport = Viewport(scale: 9, center: Vector(-7, 3), size: model.viewport.size)
        _ = model.saveNamedView(name: "Saved")
        // Move the live view somewhere else (different center, scale, window size).
        model.setViewSize(CGSize(width: 1024, height: 768))
        model.viewport = Viewport(scale: 1, center: Vector(0, 0),
                                  size: CGSize(width: 1024, height: 768))
        // Restore.
        #expect(model.restoreNamedView(name: "Saved"))
        #expect(model.viewport.center == Vector(-7, 3))
        #expect(abs(model.viewport.scale - 9) < Self.tol)
        // Size is the CURRENT window size (re-frame), not a captured size.
        #expect(model.viewport.size == CGSize(width: 1024, height: 768))
    }

    @Test("restoreNamedView on an unknown name is a no-op (false), viewport unchanged")
    func restoreUnknownNoOp() {
        let model = makeModel()
        let before = model.viewport
        #expect(!model.restoreNamedView(name: "nope"))
        #expect(model.viewport == before)
    }

    @Test("restoreNamedView pushes the prior viewport onto Zoom-Previous history")
    func restorePushesZoomPrevious() {
        let model = makeModel()
        model.viewport = Viewport(scale: 2, center: Vector(1, 1), size: model.viewport.size)
        _ = model.saveNamedView(name: "Target")
        // Move to a clearly different live viewport, then restore.
        let priorToRestore = Viewport(scale: 5, center: Vector(40, 40), size: model.viewport.size)
        model.viewport = priorToRestore
        #expect(!model.canZoomPrevious)
        #expect(model.restoreNamedView(name: "Target"))
        #expect(model.canZoomPrevious)                      // restore is step-back-able
        // Zoom Previous returns to the viewport that was live just before the restore.
        #expect(model.zoomPrevious())
        #expect(model.viewport == priorToRestore)
    }

    @Test("applyNamedView on an identical viewport is a no-op (no history push)")
    func applyIdenticalNoOp() {
        let model = makeModel()
        let current = NamedView.capture(model.viewport, name: "Now")
        #expect(!model.applyNamedView(current))             // same viewport → false
        #expect(!model.canZoomPrevious)                     // nothing pushed
    }

    @Test("deleteNamedView removes by name; absent is a no-op")
    func deleteRemovesByName() {
        let model = makeModel()
        _ = model.saveNamedView(name: "A")
        _ = model.saveNamedView(name: "B")
        #expect(model.namedViewNames == ["A", "B"])
        #expect(model.deleteNamedView(name: "a"))           // case-insensitive
        #expect(model.namedViewNames == ["B"])
        #expect(!model.deleteNamedView(name: "ghost"))      // absent → false
        #expect(model.namedViewNames == ["B"])
    }

    @Test("re-saving the same name overwrites in place (one entry, new state)")
    func resaveOverwrites() {
        let model = makeModel()
        model.viewport = Viewport(scale: 1, center: Vector(0, 0), size: model.viewport.size)
        _ = model.saveNamedView(name: "Plan")
        model.viewport = Viewport(scale: 8, center: Vector(100, 0), size: model.viewport.size)
        _ = model.saveNamedView(name: "Plan")               // same name, new viewport
        #expect(model.namedViewNames == ["Plan"])           // still one entry
        #expect(model.namedViews.view(named: "Plan")?.center == Vector(100, 0))
    }
}
