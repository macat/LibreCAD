//
//  TextCodec.swift
//  CADEngine
//
//  The CAD special-character + inline-code pre-pass (text-system-design §3).
//  A shared, PURE function that expands AutoCAD/DXF special codes to plain
//  Unicode BEFORE shaping, so BOTH glyph sources (native Core Text and stroke
//  `.lff`) benefit and the resulting string is plain Unicode that Core Text
//  shapes correctly:
//
//    %%c → ⌀ (U+2300 DIAMETER SIGN)
//    %%d → ° (U+00B0 DEGREE SIGN)
//    %%p → ± (U+00B1 PLUS-MINUS SIGN)
//    %%% → %
//    %%nnn → the character with decimal code nnn (DXF %%<3-digit> escape)
//    \U+XXXX → the Unicode scalar U+XXXX (MTEXT-style hex escape)
//
//  MTEXT brace/inline-code parsing (\f \H \C \S …) into the run tree is Phase 2;
//  this Phase-1 codec only handles the plain special-character escapes that apply
//  to single-line TEXT (and the shared `\U+` form).
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

public enum TextCodec {

    /// U+2300 DIAMETER SIGN (`%%c`). The conventional ⌀ symbol AutoCAD draws.
    public static let diameter: Character = "\u{2300}"
    /// U+00B0 DEGREE SIGN (`%%d`).
    public static let degree: Character = "\u{00B0}"
    /// U+00B1 PLUS-MINUS SIGN (`%%p`).
    public static let plusMinus: Character = "\u{00B1}"

    /// Expands DXF/AutoCAD special-character escapes in `s` to plain Unicode.
    /// Case-insensitive for the letter codes (`%%C`/`%%c` both map to ⌀), matching
    /// AutoCAD. Leaves any unrecognized `%%` sequence untouched (so it is never
    /// silently dropped).
    public static func expandSpecialCharacters(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = String()
        out.reserveCapacity(s.count)
        let chars = Array(s)
        var i = 0
        let n = chars.count

        while i < n {
            let c = chars[i]

            // --- DXF `%%` escapes ---
            if c == "%", i + 1 < n, chars[i + 1] == "%" {
                // `%%` consumed; inspect the code character.
                if i + 2 < n {
                    let code = chars[i + 2]
                    switch code.lowercased().first {
                    case "c": out.append(diameter); i += 3; continue
                    case "d": out.append(degree);   i += 3; continue
                    case "p": out.append(plusMinus); i += 3; continue
                    case "%": out.append("%");      i += 3; continue
                    default: break
                    }
                    // `%%nnn` → 3-digit decimal char code.
                    if code.isNumber, i + 4 < n,
                       chars[i + 3].isNumber, chars[i + 4].isNumber {
                        let digits = String([chars[i + 2], chars[i + 3], chars[i + 4]])
                        if let value = UInt32(digits),
                           let scalar = Unicode.Scalar(value) {
                            out.append(Character(scalar))
                            i += 5
                            continue
                        }
                    }
                }
                // Unrecognized: pass `%%` through verbatim (never drop).
                out.append("%%")
                i += 2
                continue
            }

            // --- MTEXT-style `\U+XXXX` hex escape (exactly 4 hex digits, the
            //     AutoCAD form `\U+00B0`). ---
            if c == "\\", i + 2 < n, chars[i + 1] == "U", chars[i + 2] == "+" {
                // Require exactly 4 hex digits after `\U+` (indices i+3 ... i+6).
                if i + 6 < n {
                    let d0 = chars[i + 3], d1 = chars[i + 4], d2 = chars[i + 5], d3 = chars[i + 6]
                    if d0.isHexDigit && d1.isHexDigit && d2.isHexDigit && d3.isHexDigit {
                        let hex = String([d0, d1, d2, d3])
                        if let value = UInt32(hex, radix: 16),
                           let scalar = Unicode.Scalar(value) {
                            out.append(Character(scalar))
                            i += 7
                            continue
                        }
                    }
                }
                // Malformed: pass the backslash through.
                out.append(c)
                i += 1
                continue
            }

            out.append(c)
            i += 1
        }
        return out
    }
}
