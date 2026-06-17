//
//  TextEditorOverlay.swift
//  LibreCADmacOS
//
//  The inline TEXT authoring editor — a borderless `NSTextView` floated OVER the
//  Metal canvas at the click point so the user types text directly on the drawing
//  (the payoff of the professional font system; the engine's `TextTool` is the
//  pure commit half, this is the GUI half).
//
//  ## Rich MTEXT authoring (Wave 4C)
//  The editor is now RICH: the user can apply **bold / italic / colour** to the
//  current selection while typing, via a small format bar (B / I / Colour) docked
//  above the text box, or the standard **⌘B / ⌘I** chords. On commit the editor's
//  `NSAttributedString` is translated — through the AppKit-free
//  `MTextRunConverter` (CADEngine) — into MTEXT `TextRun`s (per-run bold / italic /
//  colour), so authored formatting round-trips the MTEXT run model (and thus the
//  existing MTEXT DXF round-trip). On OPEN-for-edit, an existing MTEXT entity's run
//  tree is converted the other way so its formatting is editable. The bridge here
//  is ONLY the `NSAttributedString` ⇄ `MTextSpannedText` copy (an `NSRange`-shaped
//  intermediate); the real run-tree mapping is the pure converter — no
//  `NSAttributedString` leaks into CADEngine.
//
//  Attribute scope: only bold / italic / colour are authorable in the inline
//  editor (height/decoration/font-family/stacked attributes the model+DXF carry
//  are not exposed here — see `MTextRunConverter`'s header). A single-line plain
//  string still commits as a single-line `.text` entity; multi-line OR any
//  formatting commits as rich `.mtext`.
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
//    - Return        → commit (build the entity via `TextTool` / the rich path).
//    - Esc           → cancel (tear the editor down, no entity).
//    - Shift-Return  → insert a newline (multi-line → commits as `.mtext`).
//    - ⌘B / ⌘I       → toggle bold / italic on the current selection.
//
//  ## Commit path (reuses the engine, no parallel CanvasModel logic)
//  On commit the controller either builds a `TextTool` value (plain single-line →
//  `.text`) or, when the editor carries formatting / multiple lines, builds an
//  `.mtext` `EntityKind` directly from `richParagraphs` and applies it through the
//  SAME `applyToolEdits` the in-canvas tools use (one undoable group). Editing an
//  existing entity preserves the entity's id/layer/pen/flags (a `.replace`).
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

// MARK: - The inline editor's NSTextView (intercepts Return / Esc / ⌘B / ⌘I)

/// A borderless `NSTextView` that routes Return → commit and Esc → cancel back to
/// its owning controller, while Shift-Return inserts a newline (handled by the
/// default text system once we let it through). ⌘B / ⌘I toggle bold / italic on
/// the current selection. Used ONLY as the inline rich-text authoring editor
/// floated over the canvas.
final class InlineTextView: NSTextView {

    /// Called when the user presses Return (commit) — `false` lets the keypress
    /// fall through to the default handler (inserting a newline), `true` swallows it.
    var onCommit: (() -> Void)?
    /// Called when the user presses Esc (cancel).
    var onCancel: (() -> Void)?
    /// Called after a typing/formatting change so the format bar can resync its
    /// pressed state to the selection.
    var onFormattingChanged: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76  // Return / keypad Enter
        let isEscape = event.keyCode == 53
        let mods = event.modifierFlags
        let shift = mods.contains(.shift)
        let command = mods.contains(.command)

        if isEscape {
            onCancel?()
            return
        }
        if isReturn, !shift {
            // Plain Return commits; Shift-Return falls through to insert a newline.
            onCommit?()
            return
        }
        // ⌘B / ⌘I toggle bold / italic on the selection.
        if command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "b" { toggleTrait(.boldFontMask); return }
            if chars == "i" { toggleTrait(.italicFontMask); return }
        }
        super.keyDown(with: event)
        onFormattingChanged?()
    }

    // Esc also arrives as `cancelOperation(_:)` via the responder chain in some
    // configurations — route it to cancel too (idempotent with the keyDown path).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Toggle a font trait (bold/italic) over the selection (or the typing
    /// attributes when the selection is empty, so the NEXT typed character picks it
    /// up). Mutates the backing `textStorage` directly so it works on a borderless
    /// view without the font manager's target/action plumbing.
    func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let sel = selectedRange()

        if sel.length == 0 {
            // Empty selection: flip the typing attribute so new text inherits it.
            let base = (typingAttributes[.font] as? NSFont) ?? font ?? NSFont.systemFont(ofSize: 12)
            let isOn = base.fontDescriptor.symbolicTraits.contains(symbolicTrait(trait))
            let next = isOn ? fm.convert(base, toNotHaveTrait: trait)
                            : fm.convert(base, toHaveTrait: trait)
            var attrs = typingAttributes
            attrs[.font] = next
            typingAttributes = attrs
            onFormattingChanged?()
            return
        }

        guard let storage = textStorage else { return }
        // Decide direction from the FIRST character: if it already has the trait,
        // we remove it across the whole selection; else we add it.
        let firstFont = (storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont)
            ?? font ?? NSFont.systemFont(ofSize: 12)
        let turnOn = !firstFont.fontDescriptor.symbolicTraits.contains(symbolicTrait(trait))

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: sel, options: []) { value, range, _ in
            let f = (value as? NSFont) ?? self.font ?? NSFont.systemFont(ofSize: 12)
            let nf = turnOn ? fm.convert(f, toHaveTrait: trait) : fm.convert(f, toNotHaveTrait: trait)
            storage.addAttribute(.font, value: nf, range: range)
        }
        storage.endEditing()
        didChangeText()
        onFormattingChanged?()
    }

    /// Apply a colour to the selection (or typing attributes when empty).
    func applyColor(_ color: NSColor) {
        let sel = selectedRange()
        if sel.length == 0 {
            var attrs = typingAttributes
            attrs[.foregroundColor] = color
            typingAttributes = attrs
            onFormattingChanged?()
            return
        }
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: color, range: sel)
        storage.endEditing()
        didChangeText()
        onFormattingChanged?()
    }

    private func symbolicTrait(_ trait: NSFontTraitMask) -> NSFontDescriptor.SymbolicTraits {
        if trait.contains(.boldFontMask) { return .bold }
        if trait.contains(.italicFontMask) { return .italic }
        return []
    }
}

// MARK: - The overlay (a positioned container around the text view + format bar)

/// Owns the live inline editor: the `InlineTextView`, its format bar, where it is
/// anchored (the world insertion point), and the entity being edited (if any). The
/// controller holds at most one at a time.
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
    /// commit emits a `.replace` (preserving id/layer/pen/flags).
    let editingID: EntityID?

    /// The floated editor view.
    let textView: InlineTextView

    /// A thin container so we can give the editor an opaque background + a faint
    /// border without theming the text view itself. Also hosts the format bar.
    let container: NSView

    /// The base (unformatted) font size in screen points — used to re-derive bold /
    /// italic variants for seeded runs.
    private let baseFontSize: CGFloat

    /// The format bar's Bold / Italic toggle buttons (so we can resync their state).
    private let boldButton: NSButton
    private let italicButton: NSButton

    init(
        worldPoint: Vector,
        worldHeight: Double,
        styleName: String,
        editingID: EntityID?,
        initialText: String,
        initialSpanned: MTextSpannedText? = nil,
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
        self.baseFontSize = fontSize
        let font = NSFont(name: "Helvetica Neue", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)

        // A generous initial editor box; it visually frames where text will land.
        let initialSize = CGSize(width: max(120, fontSize * 8), height: max(fontSize * 1.6, 22))

        let tv = InlineTextView(frame: CGRect(origin: .zero, size: initialSize))
        tv.isFieldEditor = false
        tv.isRichText = true              // 4C: allow per-run bold / italic / colour
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.importsGraphics = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = accentColor
        tv.drawsBackground = false
        tv.textContainerInset = CGSize(width: 2, height: 1)
        self.textView = tv

        // Format bar: B / I toggles + a Colour swatch. Docked along the top of the
        // container, above the text view.
        let barHeight: CGFloat = 22
        let bold = Self.makeToggle(title: "B", bold: true, accent: accentColor)
        let italic = Self.makeToggle(title: "I", italic: true, accent: accentColor)
        self.boldButton = bold
        self.italicButton = italic

        let containerSize = CGSize(width: initialSize.width,
                                   height: initialSize.height + barHeight)
        let box = NSView(frame: CGRect(origin: CGPoint(x: screenOrigin.x,
                                                       y: screenOrigin.y - barHeight),
                                       size: containerSize))
        box.wantsLayer = true
        box.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.92).cgColor
        box.layer?.borderColor = accentColor.withAlphaComponent(0.9).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 2

        let bar = NSView(frame: CGRect(x: 0, y: containerSize.height - barHeight,
                                       width: containerSize.width, height: barHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = backgroundColor.withAlphaComponent(0.6).cgColor

        let colorButton = Self.makeColorButton(accent: accentColor)
        bold.frame = CGRect(x: 4, y: 1, width: 24, height: barHeight - 2)
        italic.frame = CGRect(x: 30, y: 1, width: 24, height: barHeight - 2)
        colorButton.frame = CGRect(x: 56, y: 1, width: 50, height: barHeight - 2)
        bar.addSubview(bold)
        bar.addSubview(italic)
        bar.addSubview(colorButton)
        box.addSubview(bar)

        tv.frame = CGRect(x: 0, y: 0, width: containerSize.width,
                          height: containerSize.height - barHeight)
        tv.autoresizingMask = [.width, .height]
        box.addSubview(tv)
        self.container = box

        // Seed content: prefer the rich spanned text (when editing an MTEXT with
        // formatting), else fall back to plain.
        if let spanned = initialSpanned {
            tv.textStorage?.setAttributedString(
                Self.attributed(from: spanned, baseFont: font, defaultColor: textColor))
        } else {
            tv.string = initialText
        }

        // Wire the format-bar buttons to the text view.
        bold.target = self;   bold.action = #selector(toggleBold(_:))
        italic.target = self; italic.action = #selector(toggleItalic(_:))
        colorButton.target = self; colorButton.action = #selector(chooseColor(_:))

        tv.onFormattingChanged = { [weak self] in self?.syncFormatBar() }
        syncFormatBar()
    }

    // MARK: - Editor content accessors

    /// The current editor string (the typed plain text — newlines preserved).
    var currentText: String { textView.string }

    /// The editor's content as an AppKit-free spanned-text intermediate (the bridge
    /// half that the pure `MTextRunConverter` consumes). Bold / italic come from the
    /// per-character font traits; colour from the `.foregroundColor` attribute
    /// (skipping the editor's default text colour, which is the inherited colour).
    var spannedText: MTextSpannedText {
        Self.spanned(from: textView.attributedString(),
                     defaultColor: textView.textColor ?? .textColor)
    }

    /// The editor's content as an MTEXT run tree (paragraphs), via the pure
    /// converter — what the commit path stamps onto the `.mtext` entity.
    var richParagraphs: [MTextParagraph] {
        MTextRunConverter.paragraphs(from: spannedText)
    }

    /// Whether the editor carries ANY per-run formatting (bold / italic / colour) —
    /// the commit path uses this to decide `.text` (plain single line) vs `.mtext`.
    var hasRichFormatting: Bool {
        spannedText.spans.contains { !$0.isPlain }
    }

    // MARK: - Format-bar actions

    @objc private func toggleBold(_ sender: NSButton) {
        textView.toggleTrait(.boldFontMask)
        focusEditor()
    }

    @objc private func toggleItalic(_ sender: NSButton) {
        textView.toggleTrait(.italicFontMask)
        focusEditor()
    }

    /// Opens the shared colour PANEL (a floating panel, NOT a modal `.runModal()`,
    /// so it never blocks) and applies the chosen colour to the selection. Routes
    /// the panel's changes to this overlay while it is the colour target.
    @objc private func chooseColor(_ sender: NSButton) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = currentSelectionColor() ?? .red
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ panel: NSColorPanel) {
        textView.applyColor(panel.color)
    }

    private func focusEditor() {
        container.window?.makeFirstResponder(textView)
    }

    /// The colour of the first selected character (or typing colour), for seeding
    /// the colour panel.
    private func currentSelectionColor() -> NSColor? {
        let sel = textView.selectedRange()
        if sel.length > 0, let storage = textView.textStorage,
           let c = storage.attribute(.foregroundColor, at: sel.location, effectiveRange: nil) as? NSColor {
            return c
        }
        return textView.typingAttributes[.foregroundColor] as? NSColor
    }

    /// Resync the Bold / Italic toggle pressed state to the current selection's
    /// leading character (or typing attributes).
    private func syncFormatBar() {
        let sel = textView.selectedRange()
        let font: NSFont
        if sel.length > 0, let storage = textView.textStorage,
           let f = storage.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont {
            font = f
        } else {
            font = (textView.typingAttributes[.font] as? NSFont)
                ?? textView.font ?? NSFont.systemFont(ofSize: baseFontSize)
        }
        let traits = font.fontDescriptor.symbolicTraits
        boldButton.state = traits.contains(.bold) ? .on : .off
        italicButton.state = traits.contains(.italic) ? .on : .off
    }

    // MARK: - Button factories

    private static func makeToggle(title: String, bold: Bool = false, italic: Bool = false,
                                   accent: NSColor) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .recessed
        b.showsBorderOnlyWhileMouseInside = false
        var attrs: [NSAttributedString.Key: Any] = [:]
        var fontTraits: NSFontTraitMask = []
        if bold { fontTraits.insert(.boldFontMask) }
        if italic { fontTraits.insert(.italicFontMask) }
        let base = NSFont.systemFont(ofSize: 12)
        attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: fontTraits)
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        return b
    }

    private static func makeColorButton(accent: NSColor) -> NSButton {
        let b = NSButton(title: "Colour", target: nil, action: nil)
        b.bezelStyle = .recessed
        b.font = NSFont.systemFont(ofSize: 11)
        return b
    }

    // MARK: - NSAttributedString <-> MTextSpannedText bridge (the ONLY AppKit half)

    /// Build an `NSAttributedString` from a spanned-text intermediate, for seeding
    /// the editor when opening an existing MTEXT for edit. Bold / italic become font
    /// traits on `baseFont`; colour becomes a `.foregroundColor`. Unspanned ranges
    /// get the base font + default colour.
    static func attributed(from spanned: MTextSpannedText, baseFont: NSFont,
                           defaultColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: spanned.string,
            attributes: [.font: baseFont, .foregroundColor: defaultColor])
        let fm = NSFontManager.shared
        for span in spanned.spans where !span.isPlain {
            let r = span.range
            guard r.location >= 0, r.location + r.length <= (spanned.string as NSString).length,
                  r.length > 0 else { continue }
            var traits: NSFontTraitMask = []
            if span.bold { traits.insert(.boldFontMask) }
            if span.italic { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                result.addAttribute(.font, value: fm.convert(baseFont, toHaveTrait: traits), range: r)
            }
            if let c = span.color {
                result.addAttribute(.foregroundColor,
                                    value: NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g),
                                                   blue: CGFloat(c.b), alpha: CGFloat(c.a)),
                                    range: r)
            }
        }
        return result
    }

    /// Extract a spanned-text intermediate from the editor's `NSAttributedString`.
    /// `defaultColor` is the editor's inherited text colour: a character whose
    /// colour equals it is treated as "no explicit colour" (so plain text yields no
    /// colour span and round-trips clean).
    static func spanned(from attributed: NSAttributedString, defaultColor: NSColor) -> MTextSpannedText {
        let string = attributed.string
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard full.length > 0 else { return MTextSpannedText(string: string) }

        var spans: [MTextFormatSpan] = []
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.bold)
            let italic = traits.contains(.italic)

            var color: RGBAColor? = nil
            if let c = attrs[.foregroundColor] as? NSColor,
               !Self.colorsApproximatelyEqual(c, defaultColor) {
                color = Self.rgba(from: c)
            }

            if bold || italic || color != nil {
                spans.append(MTextFormatSpan(range: range, bold: bold, italic: italic, color: color))
            }
        }
        return MTextSpannedText(string: string, spans: spans)
    }

    private static func rgba(from color: NSColor) -> RGBAColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        return RGBAColor(Float(c.redComponent), Float(c.greenComponent),
                         Float(c.blueComponent), Float(c.alphaComponent))
    }

    private static func colorsApproximatelyEqual(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else {
            return a == b
        }
        let eps: CGFloat = 0.004   // ~1/255
        return abs(ca.redComponent - cb.redComponent) < eps
            && abs(ca.greenComponent - cb.greenComponent) < eps
            && abs(ca.blueComponent - cb.blueComponent) < eps
            && abs(ca.alphaComponent - cb.alphaComponent) < eps
    }
}
