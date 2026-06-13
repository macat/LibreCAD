//
//  MTextParser.swift
//  CADEngine
//
//  The MTEXT inline-code parser (text-system-design §1.3, §3, Phase 2). Turns an
//  AutoCAD/DXF MTEXT coded string into the `MTextData` run tree (paragraphs →
//  inlines → runs / stacked fractions). A PURE function — no GPU, fully
//  unit-testable. Robust to malformed input: an unrecognized escape is passed
//  through as literal text rather than dropped, so we never lose data.
//
//  Supported AutoCAD MTEXT inline codes:
//    \f<family>|b<0/1>|i<0/1>|...;  font family + bold/italic flags (\F is .shx)
//    \H<height>;  or  \H<factor>x;  run height (absolute or relative-to-current)
//    \C<aci>;     ACI colour       \c<0xBBGGRR>;  true colour
//    \S<u>/<d>;   stacked fraction (/ horizontal, # diagonal, ^ tolerance)
//    \L … \l      underline on / off
//    \O … \o      overline on / off
//    \K … \k      strikethrough on / off (AutoCAD 2018+)
//    \T<factor>;  per-run tracking (char spacing)
//    \Q<deg>;     per-run oblique (slant) in degrees
//    \P           paragraph break        \~  non-breaking space
//    \pq<l|c|r|j>;  paragraph alignment (left/center/right/justified)
//    { … }        formatting scope (push/pop the current run state)
//    \\ \{ \}     literal backslash / brace
//  `%%c/%%d/%%p/%%%` and `\U+XXXX` are expanded per run by the shared `TextCodec`.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 2 or (at your
//  option) any later version.
//

import Foundation

public enum MTextParser {

    /// The mutable formatting state threaded through the parse. `{}` pushes/pops a
    /// copy; codes mutate the top of the stack. `heightFactor` is the run height
    /// RELATIVE to the MTEXT base height (so a fresh run is 1.0).
    struct State {
        var fontOverride: FontSource?
        var heightFactor: Double = 1.0
        var color: RGBAColor?
        var bold: Bool?
        var italic: Bool?
        var underline = false
        var overline = false
        var strikethrough = false
        var trackingFactor: Double?
        var obliqueOverride: Double?
    }

    /// Parses an MTEXT coded string into paragraphs (the run tree). The result is
    /// always non-empty when `coded` has content; an empty/blank input yields one
    /// empty paragraph so the entity still has a structural body.
    public static func parse(_ coded: String) -> [MTextParagraph] {
        var paragraphs: [MTextParagraph] = []
        var currentInlines: [MTextInline] = []
        var paragraphAlignment: MTextParagraphAlign? = nil
        var pending = ""                 // text accumulated for the current run
        var stateStack: [State] = [State()]
        var state: State { stateStack[stateStack.count - 1] }

        let chars = Array(coded)
        let n = chars.count
        var i = 0

        // Flush the accumulated literal text into a run with the current state.
        func flushRun() {
            guard !pending.isEmpty else { return }
            let expanded = TextCodec.expandSpecialCharacters(pending)
            currentInlines.append(.run(TextRun(
                text: expanded,
                fontOverride: state.fontOverride,
                heightFactor: state.heightFactor != 1.0 ? state.heightFactor : nil,
                color: state.color,
                bold: state.bold,
                italic: state.italic,
                underline: state.underline,
                overline: state.overline,
                strikethrough: state.strikethrough,
                trackingFactor: state.trackingFactor,
                obliqueOverride: state.obliqueOverride)))
            pending = ""
        }

        // End the current paragraph (on \P) and start a fresh one.
        func endParagraph() {
            flushRun()
            paragraphs.append(MTextParagraph(inlines: currentInlines,
                                             alignment: paragraphAlignment))
            currentInlines = []
            // Paragraph alignment does NOT reset across \P in AutoCAD; carry it.
        }

        while i < n {
            let c = chars[i]

            // --- brace grouping: push / pop the formatting scope ---
            if c == "{" {
                flushRun()
                stateStack.append(state)            // push a copy
                i += 1
                continue
            }
            if c == "}" {
                flushRun()
                if stateStack.count > 1 { stateStack.removeLast() }   // pop (never empty)
                i += 1
                continue
            }

            guard c == "\\", i + 1 < n else {
                // A trailing lone backslash, or any ordinary character.
                pending.append(c)
                i += 1
                continue
            }

            let code = chars[i + 1]
            switch code {
            // Literal escapes.
            case "\\": pending.append("\\"); i += 2
            case "{":  pending.append("{");  i += 2
            case "}":  pending.append("}");  i += 2
            case "~":  pending.append("\u{00A0}"); i += 2   // non-breaking space

            // Paragraph break.
            case "P":
                endParagraph(); i += 2

            // Line/column tab (rare; emit a tab inline).
            case "t":
                flushRun(); currentInlines.append(.tab); i += 2

            // \U+XXXX is handled by TextCodec at flush time; pass it through to
            // `pending` so the codec sees it.
            case "U" where i + 2 < n && chars[i + 2] == "+":
                pending.append("\\"); i += 1

            // Underline / overline / strikethrough toggles.
            case "L": flushRun(); stateStack[stateStack.count - 1].underline = true; i += 2
            case "l": flushRun(); stateStack[stateStack.count - 1].underline = false; i += 2
            case "O": flushRun(); stateStack[stateStack.count - 1].overline = true; i += 2
            case "o": flushRun(); stateStack[stateStack.count - 1].overline = false; i += 2
            case "K": flushRun(); stateStack[stateStack.count - 1].strikethrough = true; i += 2
            case "k": flushRun(); stateStack[stateStack.count - 1].strikethrough = false; i += 2

            // Height: \H<value>;  or  \H<factor>x;
            case "H":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                applyHeight(arg, to: &stateStack[stateStack.count - 1])
                i = next

            // Colour: \C<aci>;   (capital C = ACI index)
            case "C":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                if let rgba = colorFromACI(arg) {
                    stateStack[stateStack.count - 1].color = rgba
                }
                i = next

            // True colour: \c<0xBBGGRR decimal>;
            case "c":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                if let rgba = colorFromTrueColor(arg) {
                    stateStack[stateStack.count - 1].color = rgba
                }
                i = next

            // Tracking: \T<factor>;
            case "T":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                if let v = Double(arg) { stateStack[stateStack.count - 1].trackingFactor = v }
                i = next

            // Oblique: \Q<degrees>;
            case "Q":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                if let deg = Double(arg) {
                    stateStack[stateStack.count - 1].obliqueOverride = deg * .pi / 180.0
                }
                i = next

            // Width factor: \W<factor>;  (carried as tracking-neutral; ignored for
            // layout but consumed so it is not dumped as literal text).
            case "W":
                flushRun()
                let (_, next) = readArg(chars, from: i + 2)
                i = next

            // Font: \f<family>|b1|i0|c0|p0;   (also \F for SHX — same arg shape).
            case "f", "F":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                applyFont(arg, to: &stateStack[stateStack.count - 1])
                i = next

            // Stacked fraction: \S<upper>(/|#|^)<lower>;
            case "S":
                flushRun()
                let (arg, next) = readStackedArg(chars, from: i + 2)
                if let stacked = parseStacked(arg) {
                    currentInlines.append(.stacked(stacked))
                }
                i = next

            // Paragraph properties: \pxqc;  — we honour the qX alignment token.
            case "p", "A":
                flushRun()
                let (arg, next) = readArg(chars, from: i + 2)
                if let align = paragraphAlign(fromPCode: arg) {
                    paragraphAlignment = align
                }
                i = next

            default:
                // Unknown escape: keep the backslash + the following char literally
                // (robust passthrough — never silently drop).
                pending.append("\\")
                pending.append(code)
                i += 2
            }
        }

        endParagraph()
        if paragraphs.isEmpty { paragraphs = [MTextParagraph(inlines: [])] }
        return paragraphs
    }

    /// Builds an `MTextData` from a coded string + the block-level layout fields,
    /// parsing the run tree and keeping the raw string for lossless round-trip.
    public static func makeData(
        coded: String,
        position: Vector,
        height: Double,
        rectWidth: Double = 0,
        rotation: Double = 0,
        styleName: String? = nil,
        attachment: MTextAttachment = .topLeft,
        lineSpacingStyle: MTextLineSpacingStyle = .atLeast,
        lineSpacingFactor: Double = 1
    ) -> MTextData {
        MTextData(
            position: position,
            height: height,
            rectWidth: rectWidth,
            rotation: rotation,
            styleName: styleName,
            attachment: attachment,
            lineSpacingStyle: lineSpacingStyle,
            lineSpacingFactor: lineSpacingFactor,
            paragraphs: parse(coded),
            rawCode: coded)
    }

    // MARK: - Argument reading

    /// Reads a `;`-terminated argument starting at `from`. Returns the argument
    /// (without the terminator) and the index AFTER the terminator. If no `;` is
    /// found the argument runs to the end of input (tolerant of unterminated codes).
    static func readArg(_ chars: [Character], from: Int) -> (String, Int) {
        var j = from
        var out = ""
        while j < chars.count {
            let ch = chars[j]
            if ch == ";" { return (out, j + 1) }
            out.append(ch)
            j += 1
        }
        return (out, j)
    }

    /// Reads a stacked-fraction argument. Like `readArg` but a stacked body may
    /// itself contain an escaped `\;` for a literal semicolon; we stop at the first
    /// UNescaped `;`.
    static func readStackedArg(_ chars: [Character], from: Int) -> (String, Int) {
        var j = from
        var out = ""
        while j < chars.count {
            let ch = chars[j]
            if ch == "\\", j + 1 < chars.count {
                out.append(ch); out.append(chars[j + 1]); j += 2; continue
            }
            if ch == ";" { return (out, j + 1) }
            out.append(ch)
            j += 1
        }
        return (out, j)
    }

    // MARK: - Code application

    /// `\H2x;` → relative factor 2 (multiplies the current factor); `\H5;` →
    /// absolute height 5. We encode the two cases in one `Double`:
    ///   * positive value  ⇒ a RELATIVE factor of the MTEXT base height;
    ///   * negative value  ⇒ an ABSOLUTE world height (`abs(value)`).
    /// The shaper (`MTextShaper.runHeight`) divides the base height in for the
    /// absolute case, so a `\H5;` always draws at world height 5 regardless of the
    /// block height. (The base height is not known here, hence the sentinel.)
    static func applyHeight(_ arg: String, to state: inout State) {
        guard !arg.isEmpty else { return }
        if arg.hasSuffix("x") || arg.hasSuffix("X") {
            let num = String(arg.dropLast())
            if let f = Double(num), f > 0 { state.heightFactor *= f }   // relative
        } else if let absHeight = Double(arg), absHeight > 0 {
            state.heightFactor = -absHeight                              // absolute (sentinel)
        }
    }

    /// `\fArial|b1|i0|c0|p34;` → family + bold/italic flags.
    static func applyFont(_ arg: String, to state: inout State) {
        guard !arg.isEmpty else { return }
        let parts = arg.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let family = parts.first, !family.isEmpty else { return }
        state.fontOverride = .native(family: family)
        for p in parts.dropFirst() {
            guard let flag = p.first else { continue }
            let val = String(p.dropFirst())
            switch flag {
            case "b", "B": state.bold = (val == "1")
            case "i", "I": state.italic = (val == "1")
            default: break   // c<codepage>, p<pitch> — carried implicitly via family
            }
        }
    }

    /// Parses a stacked body `<upper>(/|#|^)<lower>` into a `StackedRun`. The first
    /// UNescaped divider character selects the kind.
    static func parseStacked(_ body: String) -> StackedRun? {
        guard !body.isEmpty else { return nil }
        let chars = Array(body)
        var idx: Int? = nil
        var kind: StackedRun.Kind = .fraction
        var k = 0
        while k < chars.count {
            let ch = chars[k]
            if ch == "\\", k + 1 < chars.count { k += 2; continue }   // skip escaped
            if ch == "/" { idx = k; kind = .fraction; break }
            if ch == "#" { idx = k; kind = .diagonal; break }
            if ch == "^" { idx = k; kind = .tolerance; break }
            k += 1
        }
        func unescape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\;", with: ";")
        }
        if let idx {
            let upper = unescape(String(chars[0..<idx]))
            let lower = unescape(String(chars[(idx + 1)...]))
            return StackedRun(upper: TextCodec.expandSpecialCharacters(upper),
                              lower: TextCodec.expandSpecialCharacters(lower),
                              kind: kind)
        }
        // No divider: treat the whole body as the upper (a degenerate stack).
        return StackedRun(upper: TextCodec.expandSpecialCharacters(unescape(body)),
                          lower: "", kind: .fraction)
    }

    /// Maps `\pq<l|c|r|j|d>` (the alignment token inside a paragraph-property code)
    /// to an `MTextParagraphAlign`. Tolerant: scans for a `q` followed by the token.
    static func paragraphAlign(fromPCode arg: String) -> MTextParagraphAlign? {
        let lower = arg.lowercased()
        guard let qIdx = lower.firstIndex(of: "q") else { return nil }
        let after = lower.index(after: qIdx)
        guard after < lower.endIndex else { return nil }
        switch lower[after] {
        case "l": return .left
        case "c": return .center
        case "r": return .right
        case "j": return .justified
        case "d": return .distributed
        default:  return nil
        }
    }

    // MARK: - Colour helpers (small, self-contained ACI palette)

    /// Maps an ACI index string (`\C1;` … `\C255;`) to an `RGBAColor` for the
    /// common 1–9 colours; higher indices fall back to a neutral grey. (Full
    /// 256-entry palette parity is the DXF reader's `lc_aci_to_rgb`; the parser
    /// keeps a compact built-in so it stays free of the C bridge.)
    static func colorFromACI(_ arg: String) -> RGBAColor? {
        guard let aci = Int(arg.trimmingCharacters(in: .whitespaces)) else { return nil }
        switch aci {
        case 1:  return RGBAColor(1, 0, 0)        // red
        case 2:  return RGBAColor(1, 1, 0)        // yellow
        case 3:  return RGBAColor(0, 1, 0)        // green
        case 4:  return RGBAColor(0, 1, 1)        // cyan
        case 5:  return RGBAColor(0, 0, 1)        // blue
        case 6:  return RGBAColor(1, 0, 1)        // magenta
        case 7:  return RGBAColor(1, 1, 1)        // white/black (display-dependent)
        case 8:  return RGBAColor(0.5, 0.5, 0.5)  // dark grey
        case 9:  return RGBAColor(0.75, 0.75, 0.75) // light grey
        case 0, 256: return nil                    // ByBlock / ByLayer → inherit
        default:
            // Reasonable grey for indices we don't tabulate (never crash).
            let t = Float(min(max(aci, 10), 250)) / 255.0
            return RGBAColor(t, t, t)
        }
    }

    /// Maps a DXF true-colour decimal `\c<0xBBGGRR>;` to an `RGBAColor`. AutoCAD
    /// stores MTEXT true colour as a 24-bit BGR integer.
    static func colorFromTrueColor(_ arg: String) -> RGBAColor? {
        guard let v = Int(arg.trimmingCharacters(in: .whitespaces)) else { return nil }
        let r = Float(v & 0xFF) / 255.0
        let g = Float((v >> 8) & 0xFF) / 255.0
        let b = Float((v >> 16) & 0xFF) / 255.0
        return RGBAColor(r, g, b, 1)
    }
}
