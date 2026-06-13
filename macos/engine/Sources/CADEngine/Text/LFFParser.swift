//
//  LFFParser.swift
//  CADEngine
//
//  Parser for the LibreCAD Font Format (.lff), porting RS_Font::readLFF +
//  generateLffFont (librecad/src/lib/engine/document/fonts/rs_font.cpp).
//
//  Pipeline (single pass, then a resolve pass):
//   1. Tokenize the UTF-8 text into metadata (`#`) lines and glyph blocks
//      (`[<hex>] name` followed by data lines until a blank line).
//   2. For each glyph block, build strokes from the data lines:
//        - `x,y[;x,y...]`            -> one stroke (polyline) of >=2 points
//        - `x,y,A<bulge>`            -> a bulged vertex (arc to the next vertex)
//        - `C<hex>`                  -> include all strokes of glyph <hex>
//      `C` references are resolved RECURSIVELY (with a self-/cycle guard) so the
//      produced `StrokeFont` is fully expanded and immutable.
//   3. Bulge segments are tessellated into arc points using the shared
//      `Tessellation` helper (same sagitta tolerance machinery the entity
//      resolver uses), so consumers see only straight polylines.
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2010 R. van Twisk (librecad@rvt.dds.nl).
//  Copyright (C) 2001-2003 RibbonSoft (original readLFF logic).
//

import Foundation

/// Errors surfaced by the LFF loader. Malformed *content* never throws — the
/// parser is tolerant (mirrors LibreCAD, which skips bad lines) — these cover
/// only the I/O / decoding boundary so callers can fail a load gracefully.
public enum LFFFontError: Error, Equatable, Sendable {
    /// The file could not be read from disk (missing path, permissions, …).
    case cannotReadFile(path: String)
    /// The bytes were not valid text in the declared/UTF-8 encoding.
    case invalidEncoding(path: String)
}

/// Stateless parser for `.lff` font text. Use the static entry points.
public enum LFFParser {

    /// Tessellation tolerance (em units) used to expand bulge ("A") segments
    /// into polyline points. Glyphs are tiny (cap height ~9 em units) so a fine
    /// fixed tolerance keeps curved strokes smooth without exploding point
    /// counts. The Text owner can re-tessellate from raw data later if it wants
    /// zoom-driven LOD; for the font cache a fixed value is correct.
    public static let defaultBulgeTolerance = 0.01

    // MARK: - Public entry points

    /// Parses a `.lff` font from raw file text already decoded to a `String`.
    /// Content errors are tolerated (bad glyph lines skipped); this never
    /// throws — it is the pure, testable core.
    public static func parse(
        text: String,
        bulgeTolerance: Double = defaultBulgeTolerance
    ) -> StrokeFont {
        var p = Parsing(bulgeTolerance: bulgeTolerance)
        p.run(over: text)
        return p.makeFont()
    }

    /// Loads and parses a `.lff` font from a file URL.
    /// - Throws: `LFFFontError.cannotReadFile` / `.invalidEncoding`.
    public static func load(
        contentsOf url: URL,
        bulgeTolerance: Double = defaultBulgeTolerance
    ) throws -> StrokeFont {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LFFFontError.cannotReadFile(path: url.path)
        }
        // .lff is UTF-8 (the format declares `# Encoding: UTF-8`). Fall back to
        // Latin-1 so a stray non-UTF-8 byte in a metadata comment doesn't sink
        // the whole font (mirrors LibreCAD's lenient text handling).
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw LFFFontError.invalidEncoding(path: url.path)
        }
        return parse(text: text, bulgeTolerance: bulgeTolerance)
    }

    /// Loads and parses a `.lff` font from a filesystem path.
    public static func load(
        path: String,
        bulgeTolerance: Double = defaultBulgeTolerance
    ) throws -> StrokeFont {
        try load(contentsOf: URL(fileURLWithPath: path), bulgeTolerance: bulgeTolerance)
    }
}

// MARK: - Internal parsing state machine

private extension LFFParser {

    /// Mutable accumulator for one parse run. Holds raw (unresolved) glyph data
    /// keyed by scalar, then expands `C<hex>` references on demand.
    struct Parsing {
        let bulgeTolerance: Double

        // Metadata (defaults match RS_Font's constructor).
        var letterSpacing = 3.0
        var wordSpacing = 6.75
        var lineSpacingFactor = 1.0
        var encoding = "UTF-8"
        var names: [String] = []
        var authors: [String] = []
        var license = "unknown"
        var created: String?

        /// Raw glyph data lines keyed by scalar, in file order (first wins on
        /// duplicates, like LibreCAD's `rawLffFontList`).
        var rawGlyphs: [UnicodeScalar: [String]] = [:]
        var rawOrder: [UnicodeScalar] = []

        init(bulgeTolerance: Double) { self.bulgeTolerance = bulgeTolerance }

        // MARK: Tokenize

        mutating func run(over text: String) {
            // Split keeping empty lines (blank line == end-of-glyph delimiter).
            // Normalize CRLF/CR so Windows-authored fonts tokenize identically.
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.components(separatedBy: "\n")

            var i = 0
            while i < lines.count {
                let line = lines[i]
                guard let first = line.first else { i += 1; continue }

                if first == "#" {
                    parseMetadata(line)
                    i += 1
                } else if first == "[" {
                    // Glyph header: read data lines until a blank line / EOF.
                    let scalar = Self.scalar(fromHeader: line)
                    var data: [String] = []
                    i += 1
                    while i < lines.count {
                        let dl = lines[i]
                        if dl.isEmpty { break }     // blank line ends the glyph
                        data.append(dl)
                        i += 1
                    }
                    if let scalar, !data.isEmpty, rawGlyphs[scalar] == nil {
                        rawGlyphs[scalar] = data
                        rawOrder.append(scalar)
                    }
                } else {
                    i += 1
                }
            }
        }

        mutating func parseMetadata(_ line: String) {
            // Drop leading '#', split on the FIRST ':' into identifier/value.
            // A line without a ':' (or empty value) is a free-form comment.
            let body = line.dropFirst()
            guard let colon = body.firstIndex(of: ":") else { return }
            let identifier = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty, !value.isEmpty else { return }

            switch identifier {
            case "letterspacing":     if let v = Double(value) { letterSpacing = v }
            case "wordspacing":       if let v = Double(value) { wordSpacing = v }
            case "linespacingfactor": if let v = Double(value) { lineSpacingFactor = v }
            case "author":            authors.append(value)
            case "name":              names.append(value)
            case "license":           license = value
            case "encoding":          encoding = value
            case "created":           created = value
            default:                  break   // ignore unknown metadata keys
            }
        }

        /// Extracts the Unicode scalar from a glyph header line `[<hex>] name`.
        /// Mirrors LibreCAD's `extractFontChar`: the first 1–5 hex digits.
        static func scalar(fromHeader line: String) -> UnicodeScalar? {
            // Strip the leading '[' then read the hex run up to ']' or space.
            var hex = ""
            var started = false
            for ch in line {
                if ch == "[" { started = true; continue }
                guard started else { continue }
                if ch.isHexDigit { hex.append(ch) }
                else { break }   // stop at ']' / space / name
                if hex.count >= 5 { break }
            }
            guard let code = UInt32(hex, radix: 16), let s = UnicodeScalar(code) else {
                return nil
            }
            return s
        }

        // MARK: Resolve (expand C-references) + build font

        mutating func makeFont() -> StrokeFont {
            var resolved: [UnicodeScalar: LFFGlyph] = [:]
            resolved.reserveCapacity(rawGlyphs.count)
            for scalar in rawOrder {
                if resolved[scalar] == nil {
                    var visiting: Set<UnicodeScalar> = []
                    let glyph = resolve(scalar, into: &resolved, visiting: &visiting)
                    resolved[scalar] = glyph
                }
            }

            // LibreCAD always provides a U+FFFD replacement glyph (a small
            // diamond) even when the font omits one. Synthesize it if absent so
            // the Text owner can always fall back.
            let fffd = UnicodeScalar(0xFFFD)!
            if resolved[fffd] == nil {
                resolved[fffd] = LFFGlyph(strokes: [[
                    Vector(1, 0), Vector(0, 2), Vector(1, 4), Vector(2, 2), Vector(1, 0),
                ]])
            }

            return StrokeFont(
                glyphs: resolved,
                letterSpacing: letterSpacing,
                wordSpacing: wordSpacing,
                lineSpacingFactor: lineSpacingFactor,
                encoding: encoding,
                names: names,
                authors: authors,
                license: license,
                created: created
            )
        }

        /// Recursively builds the resolved strokes for `scalar`, expanding any
        /// `C<hex>` references. `visiting` guards against reference cycles (and a
        /// glyph referencing itself), matching LibreCAD's recursion check.
        func resolve(
            _ scalar: UnicodeScalar,
            into cache: inout [UnicodeScalar: LFFGlyph],
            visiting: inout Set<UnicodeScalar>
        ) -> LFFGlyph {
            if let done = cache[scalar] { return done }
            guard let data = rawGlyphs[scalar] else { return LFFGlyph() }
            guard !visiting.contains(scalar) else { return LFFGlyph() }   // cycle guard
            visiting.insert(scalar)
            defer { visiting.remove(scalar) }

            var strokes: [[Vector]] = []
            for line in data {
                guard let first = line.first else { continue }
                if first == "C" || first == "c" {
                    // Reference: include all strokes of glyph <hex>.
                    let hex = line.dropFirst()
                    guard let code = UInt32(hex, radix: 16),
                          let ref = UnicodeScalar(code),
                          ref != scalar else { continue }      // ignore self-ref
                    let sub = resolve(ref, into: &cache, visiting: &visiting)
                    strokes.append(contentsOf: sub.strokes)
                } else {
                    if let stroke = Self.parseStroke(line, bulgeTolerance: bulgeTolerance) {
                        strokes.append(stroke)
                    }
                }
            }
            return LFFGlyph(strokes: strokes)
        }

        // MARK: One polyline stroke

        /// Parses one stroke line `x,y[,A<bulge>];x,y;…` into a point list,
        /// expanding any bulged segment into tessellated arc points. Returns
        /// `nil` for strokes with fewer than 2 vertices (matches LibreCAD's
        /// `vertex.size() < 2` skip).
        static func parseStroke(_ line: String, bulgeTolerance: Double) -> [Vector]? {
            let vertexTokens = line.split(separator: ";", omittingEmptySubsequences: true)
            guard vertexTokens.count >= 2 else { return nil }

            // Parse each "x,y[,A<bulge>]" token into (point, bulge-to-next).
            var verts: [(point: Vector, bulge: Double)] = []
            verts.reserveCapacity(vertexTokens.count)
            for token in vertexTokens {
                let coords = token.split(separator: ",", omittingEmptySubsequences: true)
                guard let xStr = coords.first, let x = Double(xStr) else { continue }
                // Issue #2045: a missing y-coordinate defaults to 0.
                let y: Double = coords.count >= 2 ? (Double(coords[1]) ?? 0) : 0
                var bulge = 0.0
                if coords.count >= 3 {
                    let third = coords[2]
                    if let lead = third.first, lead == "A" || lead == "a" {
                        bulge = Double(third.dropFirst()) ?? 0
                    }
                }
                verts.append((Vector(x, y), bulge))
            }
            guard verts.count >= 2 else { return nil }

            return expand(verts, bulgeTolerance: bulgeTolerance)
        }

        /// Expands `(point, bulge)` vertices into a flat polyline, tessellating
        /// bulged segments into arc runs. The bulge on vertex *i* describes the
        /// arc from vertex *i* to vertex *i+1* (DXF convention,
        /// `bulge = tan(includedAngle/4)`), same as the engine's polyline
        /// expansion in Resolve.swift.
        static func expand(
            _ verts: [(point: Vector, bulge: Double)],
            bulgeTolerance: Double
        ) -> [Vector] {
            var out: [Vector] = []
            out.reserveCapacity(verts.count)
            out.append(verts[0].point)

            for i in 0..<(verts.count - 1) {
                let a = verts[i]
                let b = verts[i + 1]

                if abs(a.bulge) < 1e-10 {
                    out.append(b.point)
                    continue
                }

                let included = 4 * atan(a.bulge)          // signed included angle
                let chord = b.point - a.point
                let chordLen = chord.magnitude
                if chordLen < 1e-10 { out.append(b.point); continue }

                let radius = abs(chordLen / (2 * sin(included / 2)))
                let mid = (a.point + b.point) * 0.5
                let half = chordLen / 2
                let apothem = (max(0, radius * radius - half * half)).squareRoot()
                let dir = chord / chordLen
                let leftNormal = Vector(-dir.y, dir.x)
                let apexSide = (a.bulge >= 0 ? 1.0 : -1.0)
                let centerSign = -((cos(included / 2)).sign == .minus ? -1.0 : 1.0)
                let center = mid + leftNormal * (apexSide * centerSign * apothem)

                let startAngle = (a.point - center).angle
                let pts = Tessellation.arcPointsBySweep(
                    center: center, radius: radius,
                    startAngle: startAngle, sweep: -included,
                    tolerance: bulgeTolerance
                )
                if pts.count > 1 { out.append(contentsOf: pts.dropFirst()) }
                else { out.append(b.point) }
            }
            return out
        }
    }
}
