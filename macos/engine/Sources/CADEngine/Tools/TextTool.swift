//
//  TextTool.swift
//  CADEngine
//
//  The in-app TEXT authoring tool — the payoff of the professional font system.
//  Ported in spirit from LibreCAD's `RS_ActionDrawText` (librecad/src/lib/actions/
//  drawing/draw/rs_actiondrawtext.cpp), but split cleanly between this PURE value
//  type (the geometry/commit logic) and the GUI inline editor (an `NSTextView`
//  overlay in `CADCanvasView`, which collects the typed string).
//
//  ## How authoring flows (tool ↔ inline editor)
//  Unlike a geometry tool, text needs a STRING in addition to an insertion point.
//  The split is:
//    1. `.click(p)`  → stash `p` as the insertion point and STAY active. In the
//                      app this is the cue for `CADCanvasView` to raise the inline
//                      `NSTextView` editor at `worldToScreen(p)`. (No preview —
//                      the live editor IS the on-canvas preview.)
//    2. The user types in the editor. The overlay mirrors the string into the
//       tool's `text` (a settable field) as it changes, OR configures a fresh
//       `TextTool(text:…)` it commits directly — both paths are supported.
//    3. Return / focus-out → `.commit` → the tool builds the entity from the
//       stashed point + `text` + `style` and emits one undoable `.add` (or
//       `.replace`, when EDITING an existing entity — see `editing`).
//    4. Esc → `.cancel` → discard, `.finished` (the overlay tears itself down).
//
//  ## Single-line vs multi-line → `.text` vs `.mtext`
//  A string with NO embedded newline commits as single-line CAD `.text(TextData)`.
//  A multi-line string (Shift-Return inserts a `\n`) commits as rich
//  `.mtext(MTextData)` with one `MTextParagraph` per line (a single default run).
//  This matches the user's mental model (one line ⇒ a plain text entity; several
//  lines ⇒ a multi-line text block) and round-trips through the existing resolve
//  arms (`TextShaper` for `.text`, `MTextShaper` for `.mtext`).
//
//  ## Default style = "Standard" (Helvetica Neue)
//  New text uses the `TextStyleTable.standardName` ("Standard") style, whose
//  `primaryFont` is `.native(family: "Helvetica Neue")` (TextStyle.defaultNative-
//  Family). The tool stamps that style NAME on the entity (`styleName`); the
//  drawing's `textStyleProvider` resolves it to the font at draw time. Rich
//  per-run formatting + a font picker are the Inspector's job — this tool authors
//  the STRING with the active/default style.
//
//  PURE: it never touches CADDrawing / Quadtree / GUI. It receives already-snapped
//  world points + a configured string and returns outcomes; the app re-mints ids
//  on `.add` and preserves attrs on `.replace`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2001-2003 RibbonSoft (original RS_ActionDrawText).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

/// The interactive Text authoring tool. A click sets the insertion point and (in
/// the app) raises the inline editor; the typed string is committed as a `.text`
/// (single line) or `.mtext` (multi-line) entity on `.commit`. A pure value type:
/// the GUI editor lives in `CADCanvasView`; this is the testable geometry/commit
/// half.
public struct TextTool: Tool {

    // MARK: - State

    /// The tool's small state machine. A point click moves it from awaiting the
    /// insertion point to "placed" (ready to author + commit).
    private enum State: Equatable {
        /// No insertion point yet — a click picks it (or, when EDITING, the point
        /// is seeded from the existing entity and we start already `.placed`).
        case awaitingPoint
        /// The insertion point is chosen; the user is authoring the string. Commit
        /// builds the entity here.
        case placed(Vector)
    }

    private var state: State

    // MARK: - Authoring configuration (set by the inline editor before commit)

    /// The string to commit. The inline editor mirrors the typed text here (or a
    /// fully-configured `TextTool(text:…)` is committed directly). Embedded `\n`
    /// newlines promote the commit to multi-line `.mtext`.
    public var text: String

    /// Cap height in world units (DXF code 40 / `TextData.height`). Defaults to the
    /// "Standard" style's last interactively used height.
    public var height: Double

    /// Baseline rotation in radians (CCW about the insertion point). `0` for
    /// horizontal text (the default the inline editor uses).
    public var rotation: Double

    /// The text-style NAME stamped on the committed entity (resolved against the
    /// drawing's STYLE table at draw time). Defaults to "Standard" (Helvetica Neue).
    public var styleName: String

    /// When non-`nil`, this run EDITS an existing entity: `.commit` emits
    /// `.replace(editing!, newKind)` instead of `.add`, so the entity keeps its
    /// id / layer / pen / flags and only its geometry (the text kind) is swapped.
    /// `nil` ⇒ author a brand-new entity (`.add`).
    public var editing: EntityID?

    // MARK: - Init

    /// Creates a fresh Text tool for AUTHORING new text. The insertion point is
    /// picked by the first `.click`; `text` is filled by the inline editor before
    /// `.commit`.
    public init(
        text: String = "",
        height: Double = TextTool.defaultHeight,
        rotation: Double = 0,
        styleName: String = TextTool.standardStyleName
    ) {
        self.state = .awaitingPoint
        self.text = text
        self.height = height
        self.rotation = rotation
        self.styleName = styleName
        self.editing = nil
    }

    /// Creates a Text tool PRE-PLACED for EDITING an existing entity: the insertion
    /// point + initial string/height/rotation/style are seeded from the entity, and
    /// `.commit` emits a `.replace(id, …)` so the edit preserves the entity's
    /// id/layer/pen/flags. The inline editor opens pre-filled with `text`.
    public init(
        editing id: EntityID,
        at point: Vector,
        text: String,
        height: Double = TextTool.defaultHeight,
        rotation: Double = 0,
        styleName: String = TextTool.standardStyleName
    ) {
        self.state = .placed(point)
        self.text = text
        self.height = height
        self.rotation = rotation
        self.styleName = styleName
        self.editing = id
    }

    // MARK: - Defaults

    /// The default text style name — the always-present "Standard" style, whose
    /// `primaryFont` is Helvetica Neue (`TextStyle.defaultNativeFamily`).
    public static let standardStyleName = "Standard"

    /// The default cap height (world units) for new text — the "Standard" style's
    /// last interactively used height (`TextStyle.lastHeight` default).
    public static let defaultHeight: Double = 2.5

    // MARK: - Tool

    public var title: String { "Text" }

    public var status: String {
        switch state {
        case .awaitingPoint: return "Specify text insertion point"
        case .placed:        return "Type the text, then press Return"
        }
    }

    /// Text has no rubber-band geometry here — the inline `NSTextView` editor is
    /// the live on-canvas preview, so the tool's overlay preview is always empty.
    public var preview: [ResolvedPolyline] { [] }

    /// The currently chosen insertion point, or `nil` before the first click. The
    /// inline editor reads this to position itself (via `worldToScreen`).
    public var insertionPoint: Vector? {
        if case .placed(let p) = state { return p }
        return nil
    }

    public mutating func handle(_ input: ToolInput, context: ToolContext) -> ToolOutcome {
        switch input {
        case .move:
            // No rubber-band (the editor is the preview) — a move changes nothing.
            return .none

        case .click(let p):
            guard p.valid else { return .none }
            // Pick (or re-pick) the insertion point. Re-clicking before commit just
            // moves the insertion point — the app re-positions the editor.
            state = .placed(p)
            return .preview

        case .backspace:
            // Backspace edits the STRING inside the inline editor, not the tool's
            // point state — nothing to step back here.
            return .none

        case .cancel:
            // Esc — discard the run.
            return .finished

        case .commit:
            // Return — build the entity from the placed point + the authored text.
            guard case .placed(let point) = state else {
                // No insertion point yet — nothing to commit.
                return .finished
            }
            guard let kind = makeEntityKind(at: point) else {
                // Empty (or whitespace-only) text — don't create an empty entity.
                return .finished
            }
            if let id = editing {
                // EDITING an existing entity → replace its geometry in place.
                return .commit([.replace(id, kind)])
            } else {
                let record = EntityRecord(id: .placeholder, kind: kind)
                return .commit([.add(record)])
            }
        }
    }

    // MARK: - Entity construction (single-line .text vs multi-line .mtext)

    /// Builds the `EntityKind` for the current `text` at `point`, or `nil` when the
    /// text is empty / whitespace-only (so an empty commit creates nothing).
    ///
    /// A string with NO embedded newline becomes single-line `.text`; a multi-line
    /// string becomes `.mtext` with one paragraph per line.
    private func makeEntityKind(at point: Vector) -> EntityKind? {
        // Don't commit an entity for an empty / whitespace-only string.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Split on newlines (the inline editor inserts `\n` on Shift-Return). Both
        // \n and \r\n are normalized to logical lines.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        if lines.count <= 1 {
            // Single line → CAD single-line text.
            return .text(TextData(
                position: point,
                height: height,
                rotation: rotation,
                text: lines.first ?? text,
                styleName: styleName
            ))
        }

        // Multi-line → rich MTEXT: one paragraph per line, each a single default
        // run (no per-run formatting — that is the Inspector's job).
        let paragraphs = lines.map { line in
            MTextParagraph(inlines: [.run(TextRun(text: line))])
        }
        return .mtext(MTextData(
            position: point,
            height: height,
            rotation: rotation,
            styleName: styleName,
            // Top-left attachment matches a top-down inline editor (the first line
            // is at the insertion point and subsequent lines drop below it).
            attachment: .topLeft,
            paragraphs: paragraphs
        ))
    }
}
