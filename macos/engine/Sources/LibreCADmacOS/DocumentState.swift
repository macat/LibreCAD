//
//  DocumentState.swift
//  LibreCADmacOS
//
//  A tiny main-actor holder for "which file is this window's drawing?" — the URL
//  the document was last opened from or saved to, plus a dirty flag. ContentView
//  owns one and uses it to drive Save (⌘S) vs Save As… (⇧⌘S) and the window
//  title.
//
//  Save (⌘S) writes to `currentURL` when it is set; otherwise it falls through to
//  Save As…, which presents an `NSSavePanel`, writes via `DXFWriter`, and records
//  the chosen URL here. `markOpened`/`markSaved` both clear the dirty flag (the
//  on-disk file now matches the model); `markDirty` sets it after an edit.
//
//  Foundation-only (no SwiftUI/AppKit) on purpose: that keeps it unit-testable in
//  the CADEngine test target via the same source-symlink pattern the renderer
//  core files use (see `_SharedDocumentState.swift`). `@Observable` comes from the
//  `Observation` module, which is available outside SwiftUI.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//

import Foundation
import Observation

/// Tracks the window's current file URL and unsaved-changes flag. `@MainActor`
/// because ContentView (which owns it) runs entirely on the main actor, matching
/// `CanvasModel`.
@MainActor
@Observable
final class DocumentState {

    /// The file the drawing was last opened from or saved to, or `nil` for an
    /// untitled document that has never been saved. When set, Save (⌘S) writes
    /// straight here; when `nil`, Save falls through to Save As…
    private(set) var currentURL: URL?

    /// Whether the model has unsaved changes relative to the on-disk file. Set by
    /// `markDirty()` after an edit; cleared by a successful open/save (the on-disk
    /// file then matches the model). Drives the window's modified indicator.
    private(set) var isDirty: Bool

    /// A user-facing document name for the window title: the current file's name
    /// (without extension) or "Untitled" before the first save.
    var displayName: String {
        currentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// Whether Save can write in place (a current URL exists). When false, the
    /// app should present Save As… instead.
    var canSaveInPlace: Bool { currentURL != nil }

    init(currentURL: URL? = nil, isDirty: Bool = false) {
        self.currentURL = currentURL
        self.isDirty = isDirty
    }

    /// Records that the drawing now corresponds to a file just opened from `url`.
    /// Clears the dirty flag (the model matches what is on disk).
    func markOpened(_ url: URL) {
        currentURL = url
        isDirty = false
    }

    /// Records a successful save to `url` (Save or Save As…): makes `url` the
    /// current file and clears the dirty flag.
    func markSaved(to url: URL) {
        currentURL = url
        isDirty = false
    }

    /// Marks the document as having unsaved changes (call after an edit).
    func markDirty() {
        isDirty = true
    }
}
