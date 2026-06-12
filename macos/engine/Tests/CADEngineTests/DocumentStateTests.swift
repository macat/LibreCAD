//
//  DocumentStateTests.swift
//  CADEngineTests
//
//  Unit tests for the app's `DocumentState` (current-file URL + dirty tracking),
//  exercised here via the source-symlink pattern the renderer-core files use
//  (`_SharedDocumentState.swift` -> the app's DocumentState.swift). DocumentState
//  is Foundation-only, so it compiles in the CADEngine test target without the
//  app/GPU.
//
//  GPLv2-or-later (LibreCAD derivative).
//

import Testing
import Foundation

@MainActor
@Suite("DocumentState — current URL + dirty tracking")
struct DocumentStateTests {

    @Test("a fresh document is untitled, clean, and cannot save in place")
    func freshIsUntitledAndClean() {
        let doc = DocumentState()
        #expect(doc.currentURL == nil)
        #expect(doc.isDirty == false)
        #expect(doc.canSaveInPlace == false)
        #expect(doc.displayName == "Untitled")
    }

    @Test("markOpened records the URL, clears dirty, and enables in-place save")
    func openRecordsURL() {
        let doc = DocumentState()
        doc.markDirty()
        #expect(doc.isDirty == true)

        let url = URL(fileURLWithPath: "/tmp/drawing.dxf")
        doc.markOpened(url)
        #expect(doc.currentURL == url)
        #expect(doc.isDirty == false)               // on-disk now matches the model
        #expect(doc.canSaveInPlace == true)
        #expect(doc.displayName == "drawing")        // extension stripped
    }

    @Test("markSaved records the URL and clears dirty (Save As… target)")
    func saveRecordsURLAndClears() {
        let doc = DocumentState()
        doc.markDirty()

        let url = URL(fileURLWithPath: "/tmp/out/MyPart.dxf")
        doc.markSaved(to: url)
        #expect(doc.currentURL == url)
        #expect(doc.isDirty == false)
        #expect(doc.canSaveInPlace == true)
        #expect(doc.displayName == "MyPart")
    }

    @Test("markDirty after a save flags unsaved changes again")
    func editAfterSaveIsDirty() {
        let doc = DocumentState()
        let url = URL(fileURLWithPath: "/tmp/a.dxf")
        doc.markSaved(to: url)
        #expect(doc.isDirty == false)

        doc.markDirty()
        #expect(doc.isDirty == true)
        // The URL is unchanged — a subsequent ⌘S still writes in place.
        #expect(doc.currentURL == url)
        #expect(doc.canSaveInPlace == true)
    }

    @Test("displayName uses the file name without its extension")
    func displayNameStripsExtension() {
        let doc = DocumentState()
        doc.markSaved(to: URL(fileURLWithPath: "/x/y/floor.plan.dxf"))
        // deletingPathExtension drops only the LAST extension component.
        #expect(doc.displayName == "floor.plan")
    }
}
