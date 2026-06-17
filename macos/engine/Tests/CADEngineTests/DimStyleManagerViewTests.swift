//
//  DimStyleManagerViewTests.swift
//  CADEngineTests
//
//  Exercises the PURE naming/validation logic of the Dimension Style Manager
//  (`DimStyleNaming` — the default-new-name generator and the rename validator,
//  feature-gap Wave 2B) WITHOUT presenting the panel/sheet — the manager view itself
//  is View-layer-only (headless-modal trap), but its naming logic is a side-effect-free
//  value type (mirrors `LayoutRenameSheet.Validation`). It also drives the engine
//  DIMSTYLE funnel (`CADDrawing.mutateDimStyles` / `upsertDimStyle`) directly to prove
//  the manager's add / rename / delete / set-current edits are correct + UNDOABLE
//  (the same mutators the view calls).
//
//  The manager source is compiled into this engine test target via the
//  `_SharedDimStyleManagerView.swift` symlink (the established convention).
//  Uniquely namespaced (`@Suite`) so it does not collide with other suites in this
//  fan-out-shared target.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Testing
import Foundation
@testable import CADEngine

// MARK: - Pure naming / validation logic

@Suite("dim-style manager (W2B) — pure naming + validation")
struct DimStyleNamingTests {

    // defaultNewName --------------------------------------------------------------

    @Test("default name is 'Style 1' against an empty table")
    func defaultNameEmpty() {
        #expect(DimStyleNaming.defaultNewName(existing: []) == "Style 1")
    }

    @Test("default name skips taken 'Style N' names (case-insensitive)")
    func defaultNameSkipsTaken() {
        #expect(DimStyleNaming.defaultNewName(existing: ["Standard"]) == "Style 1")
        #expect(DimStyleNaming.defaultNewName(existing: ["Style 1"]) == "Style 2")
        // Case-insensitive + whitespace-trimmed: " STYLE 1 " still blocks "Style 1".
        #expect(DimStyleNaming.defaultNewName(existing: [" STYLE 1 ", "style 2"]) == "Style 3")
        // A non-contiguous gap is filled by the lowest free index.
        #expect(DimStyleNaming.defaultNewName(existing: ["Style 1", "Style 3"]) == "Style 2")
    }

    @Test("default name is always unique w.r.t. the existing set")
    func defaultNameUnique() {
        let existing = ["Standard", "ISO-25", "Style 1", "Style 2"]
        let n = DimStyleNaming.defaultNewName(existing: existing)
        #expect(!existing.map { $0.lowercased() }.contains(n.lowercased()))
    }

    // isStandard ------------------------------------------------------------------

    @Test("isStandard is case-insensitive + whitespace-trimmed")
    func isStandard() {
        #expect(DimStyleNaming.isStandard("Standard"))
        #expect(DimStyleNaming.isStandard("  standard "))
        #expect(DimStyleNaming.isStandard("STANDARD"))
        #expect(!DimStyleNaming.isStandard("ISO-25"))
        #expect(!DimStyleNaming.isStandard(""))
    }

    // classify (rename validation) ------------------------------------------------

    private let existing = ["Standard", "ISO-25", "Arch"]

    @Test("blank / whitespace-only names are .empty (confirm disabled)")
    func blankIsEmpty() {
        #expect(DimStyleNaming.classify(newName: "", currentName: "ISO-25", existingNames: existing) == .empty)
        #expect(DimStyleNaming.classify(newName: "   ", currentName: "ISO-25", existingNames: existing) == .empty)
        #expect(!DimStyleNaming.classify(newName: " ", currentName: "ISO-25", existingNames: existing).isConfirmable)
    }

    @Test("a fresh unique name is .ok (confirm enabled)")
    func freshNameIsOK() {
        let v = DimStyleNaming.classify(newName: "Detail", currentName: "ISO-25", existingNames: existing)
        #expect(v == .ok)
        #expect(v.isConfirmable)
    }

    @Test("renaming to the current name (or its recase) is .unchanged, not .collision")
    func currentNameIsUnchanged() {
        #expect(DimStyleNaming.classify(newName: "ISO-25", currentName: "ISO-25", existingNames: existing) == .unchanged)
        #expect(DimStyleNaming.classify(newName: "  iso-25 ", currentName: "ISO-25", existingNames: existing) == .unchanged)
        #expect(DimStyleNaming.classify(newName: "iso-25", currentName: "ISO-25", existingNames: existing).isConfirmable)
    }

    @Test("a name matching a DIFFERENT style (case-insensitive) is .collision (disabled)")
    func collisionWithOther() {
        #expect(DimStyleNaming.classify(newName: "Arch", currentName: "ISO-25", existingNames: existing) == .collision)
        #expect(DimStyleNaming.classify(newName: "  arch ", currentName: "ISO-25", existingNames: existing) == .collision)
        #expect(!DimStyleNaming.classify(newName: "ARCH", currentName: "ISO-25", existingNames: existing).isConfirmable)
    }

    @Test("renaming TO 'Standard' is .reserved (disabled)")
    func renameToStandardIsReserved() {
        let v = DimStyleNaming.classify(newName: "Standard", currentName: "ISO-25", existingNames: existing)
        #expect(v == .reserved)
        #expect(!v.isConfirmable)
        // …but a recase of the current name that IS Standard is .unchanged, not reserved.
        #expect(DimStyleNaming.classify(newName: "standard", currentName: "Standard", existingNames: existing) == .unchanged)
    }
}

// MARK: - The DIMSTYLE funnel the manager drives (undoable add/rename/delete/current)

@MainActor
@Suite("dim-style manager (W2B) — undoable DIMSTYLE mutations")
struct DimStyleManagerMutationTests {

    /// An UndoManager configured for unit testing: manual grouping (there is no run
    /// loop to auto-close per-event groups in a test process). Matches the project's
    /// existing `DeleteUndoTests` convention.
    private func testUndoManager() -> UndoManager {
        let um = UndoManager()
        um.groupsByEvent = false
        return um
    }

    /// A drawing seeded with a "Standard" style (mirroring a real document) with the
    /// `UndoManager` attached AFTER seeding, so setup registers no undo and the tests
    /// start from a clean stack (the `DeleteUndoTests` pattern).
    private func makeDrawing() -> (CADDrawing, UndoManager) {
        let d = CADDrawing()
        d.dimStyles.upsert(NamedDimStyle(name: "Standard", style: .default))
        let um = testUndoManager()
        d.undoManager = um
        return (d, um)
    }

    /// Runs one undoable DIMSTYLE edit in its own group (the run-loop event group a
    /// real document would open/close), mirroring `CanvasModel`'s per-edit grouping.
    private func edit(_ d: CADDrawing, _ um: UndoManager, _ body: (inout DimStyleTable) -> Void) {
        um.beginUndoGrouping()
        d.mutateDimStyles(body)
        um.endUndoGrouping()
    }

    @Test("add upserts a new named style and is undoable")
    func addIsUndoable() {
        let (d, um) = makeDrawing()
        let seed = ResolvedDimStyle(textHeight: 3.5, arrowSize: 2.0)
        edit(d, um) { $0.upsert(NamedDimStyle(name: "Style 1", style: seed)) }

        #expect(d.dimStyles.contains("Style 1"))
        #expect(d.dimStyles.style(named: "Style 1")?.style.textHeight == 3.5)
        #expect(um.canUndo)

        um.undo()
        #expect(!d.dimStyles.contains("Style 1"))   // add rolled back
        #expect(d.dimStyles.contains("Standard"))   // Standard survives
    }

    @Test("edit a field upserts the same name with new values, undoably")
    func editIsUndoable() {
        let (d, um) = makeDrawing()
        edit(d, um) { $0.upsert(NamedDimStyle(name: "Style 1", style: .default)) }

        var updated = d.dimStyles.style(named: "Style 1")!.style
        updated.arrowSize = 9.0
        edit(d, um) { $0.upsert(NamedDimStyle(name: "Style 1", style: updated)) }
        #expect(d.dimStyles.style(named: "Style 1")?.style.arrowSize == 9.0)
        // No new style was created — still just Standard + Style 1.
        #expect(d.dimStyles.count == 2)

        um.undo()
        #expect(d.dimStyles.style(named: "Style 1")?.style.arrowSize == ResolvedDimStyle.default.arrowSize)
    }

    @Test("rename re-keys the entry, carries the active pointer, and is undoable")
    func renameIsUndoable() {
        let (d, um) = makeDrawing()
        let seed = ResolvedDimStyle(textHeight: 7.0)
        edit(d, um) {
            $0.upsert(NamedDimStyle(name: "Old", style: seed))
            $0.activeName = "Old"
        }

        // The manager's rename: remove old, upsert new (preserving values), carry active.
        edit(d, um) { table in
            let wasActive = table.activeName?.caseInsensitiveCompare("Old") == .orderedSame
            let existing = table.style(named: "Old")!.style
            table.remove(named: "Old")
            table.upsert(NamedDimStyle(name: "New", style: existing))
            if wasActive { table.activeName = "New" }
        }

        #expect(!d.dimStyles.contains("Old"))
        #expect(d.dimStyles.style(named: "New")?.style.textHeight == 7.0)
        #expect(d.dimStyles.active()?.name == "New")    // active pointer carried

        um.undo()
        #expect(d.dimStyles.contains("Old"))
        #expect(!d.dimStyles.contains("New"))
        #expect(d.dimStyles.active()?.name == "Old")
    }

    @Test("delete removes a non-Standard style undoably; Standard is protected")
    func deleteIsUndoable() {
        let (d, um) = makeDrawing()
        edit(d, um) { $0.upsert(NamedDimStyle(name: "Doomed", style: .default)) }

        edit(d, um) { $0.remove(named: "Doomed") }
        #expect(!d.dimStyles.contains("Doomed"))
        #expect(d.dimStyles.contains("Standard"))

        um.undo()
        #expect(d.dimStyles.contains("Doomed"))

        // Deleting "Standard" is a no-op (the table protects it): the table is
        // unchanged and an undo of the (empty) edit cannot drop Standard. (canUndo is
        // not asserted here — explicit begin/endUndoGrouping registers the group even
        // when the no-op funnel registered no inner action, an artifact of the
        // test-harness grouping, not the funnel.)
        let before = d.dimStyles
        edit(d, um) { $0.remove(named: "Standard") }
        #expect(d.dimStyles == before)
        #expect(d.dimStyles.contains("Standard"))
    }

    @Test("set-current changes the active style undoably")
    func setCurrentIsUndoable() {
        let (d, um) = makeDrawing()
        edit(d, um) { $0.upsert(NamedDimStyle(name: "ISO-25", style: .default)) }
        #expect(d.dimStyles.active()?.name == "Standard")   // default active

        edit(d, um) { $0.activeName = "ISO-25" }
        #expect(d.dimStyles.active()?.name == "ISO-25")

        um.undo()
        #expect(d.dimStyles.active()?.name == "Standard")
    }
}
