//
//  TextEditorOverlay.swift
//  LibreCADmacOS
//
//  The inline TEXT authoring editor — a borderless `NSTextView` floated OVER the
//  Metal canvas at the click point so the user types text directly on the drawing
//  (the payoff of the professional font system; the engine's `TextTool` is the
//  pure commit half, this is the GUI half).
//
//  ## Positioning (worldToScreen, height/zoom aware)
//  When the Text tool is active and the user clicks, `CADCanvasController` snaps the
//  click to a world point, then asks this overlay to open at `viewport.worldToScreen
//  (point)`. The editor's FONT size is set to the text height in WORLD units times
//  the viewport `scale` (points-per-world-unit), so the on-screen editor roughly
//  matches the size the committed CAD text will draw at the current zoom. The
//  editor's top-left anchor is the insertion point (matching `.text` baseline-left
//  / `.mtext` top-left authoring), nudged up by the cap-height so the first line's
//  baseline sits near the click (a close-enough visual match; the precise baseline
//  is fixed once the text commits and the renderer draws it).
//
//  ## Keys
//    - Return        → commit (build the entity via `TextTool` + `applyToolEdits`).
//    - Esc           → cancel (tear the editor down, no entity).
//    - Shift-Return  → insert a newline (multi-line → commits as `.mtext`).
//
//  ## Commit path (reuses the engine, no parallel CanvasModel logic)
//  On commit the controller builds a `TextTool` value configured with the typed
//  string + insertion point + style/height, runs it PURELY
//  (`.click` → `.commit`), and hands the resulting `ToolEdit`s to
//  `CanvasModel.applyToolEdits` — the SAME `applyCommit` the in-canvas tools use
//  (one undoable group, quadtree synced). Editing an existing entity runs the
//  `TextTool(editing:…)` initializer so the commit is a `.replace` that preserves
//  the entity's id/layer/pen/flags.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it under
//  the terms of the GNU General Public License version 2 or (at your option) any
//  later version.
//

import AppKit
import CADEngine

// MARK: - The inline editor's NSTextView (intercepts Return / Esc)

/// A borderless `NSTextView` that routes Return → commit and Esc → cancel back to
/// its owning controller, while Shift-Return inserts a newline (handled by the
/// default text system once we let it through). Used ONLY as the inline text
/// authoring editor floated over the canvas.
final class InlineTextView: NSTextView {

    /// Called when the user presses Return (commit) — `false` lets the keypress
    /// fall through to the default handler (inserting a newline), `true` swallows it.
    var onCommit: (() -> Void)?
    /// Called when the user presses Esc (cancel).
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return / keypad Enter
        let isEscape = event.keyCode == 53
        let shift = event.modifierFlags.contains(.shift)

        if isEscape {
            onCancel?()
            return
        }
        if isReturn, !shift {
            // Plain Return commits; Shift-Return falls through to insert a newline.
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    // Esc also arrives as `cancelOperation(_:)` via the responder chain in some
    // configurations — route it to cancel too (idempotent with the keyDown path).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - The overlay (a positioned container around the text view)

/// Owns the live inline editor: the `InlineTextView`, where it is anchored (the
/// world insertion point), and the entity being edited (if any). The controller
/// holds at most one at a time.
@MainActor
final class TextEditorOverlay {

    /// The world insertion point this editor authors at (the snapped click, or an
    /// existing entity's position when editing).
    let worldPoint: Vector

    /// The text height in WORLD units (drives both the on-screen font size and the
    /// committed entity's height).
    let worldHeight: Double

    /// The style name stamped on the committed entity ("Standard" = Helvetica Neue).
    let styleName: String

    /// The entity being edited, or `nil` when authoring brand-new text. When set,
    /// commit emits a `.replace` (preserving id/layer/pen/flags) via the
    /// `TextTool(editing:…)` path.
    let editingID: EntityID?

    /// The floated editor view.
    let textView: InlineTextView

    /// A thin container so we can give the editor an opaque background + a faint
    /// border without theming the text view itself.
    let container: NSView

    init(
        worldPoint: Vector,
        worldHeight: Double,
        styleName: String,
        editingID: EntityID?,
        initialText: String,
        screenOrigin: CGPoint,
        pointHeight: CGFloat,
        accentColor: NSColor,
        backgroundColor: NSColor,
        textColor: NSColor
    ) {
        self.worldPoint = worldPoint
        self.worldHeight = worldHeight
        self.styleName = styleName
        self.editingID = editingID

        // Font size in screen points = world cap-height × pixels-per-world-unit.
        // Clamp to a usable on-screen range so a far-zoomed-out / -in editor is
        // still legible to type into (the COMMITTED height is `worldHeight`, exact).
        let fontSize = max(8, min(pointHeight, 400))
        let font = NSFont(name: "Helvetica Neue", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)

        // A generous initial editor box; it visually frames where text will land.
        // (The committed geometry is laid out by the renderer, not by this box.)
        let initialSize = CGSize(width: max(120, fontSize * 8), height: max(fontSize * 1.6, 22))

        let tv = InlineTextView(frame: CGRect(origin: .zero, size: initialSize))
        tv.isFieldEditor = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = accentColor
        tv.drawsBackground = false
        tv.string = initialText
        tv.textContainerInset = CGSize(width: 2, height: 1)
        self.textView = tv

        let box = NSView(frame: CGRect(origin: screenOrigin, size: initialSize))
        box.wantsLayer = true
        box.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.92).cgColor
        box.layer?.borderColor = accentColor.withAlphaComponent(0.9).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 2
        tv.frame = box.bounds
        tv.autoresizingMask = [.width, .height]
        box.addSubview(tv)
        self.container = box
    }

    /// The current editor string (the typed text).
    var currentText: String { textView.string }
}
