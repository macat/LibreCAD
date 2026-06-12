//
//  SHXParser.swift
//  CADEngine
//
//  Binary decoder for the AutoCAD compiled SHAPE-font format (`.shx`) and its
//  shape-description bytecode interpreter. Decodes the three documented flavors
//  ("AutoCAD-86 shapes 1.0"/"1.1", "unifont 1.0", "bigfont 1.0") into a
//  `SHXFont` of resolved `SHXGlyph` open-polyline strokes + advance widths.
//
//  ## Format (the documented `.shp`/`.shx` shape-description language)
//
//  A `.shx` file is: a signature line terminated by `\r\n\x1a`, then a one-byte
//  file-type marker, then a shape INDEX TABLE, then the per-shape DEFINITION
//  bytes. Each shape definition is a name (NUL-terminated) followed by the shape
//  bytecode. Shape #0 is the special "font header" shape whose name is the font
//  name and whose two definition bytes are (above-baseline, below-baseline)
//  heights — the font's vertical metrics. Every OTHER shape number is a glyph;
//  for a text font the shape number equals the character's code point.
//
//  ## Shape bytecode (per character)
//
//  A glyph is a list of bytes. A byte's high nibble is a "vector length" and its
//  low nibble is a "direction" (one of 16 compass directions) — a one-byte draw
//  vector. The high nibble == 0 marks a SPECIAL CODE whose meaning is given by
//  the low nibble (0x01–0x0E):
//
//    0x00  end of shape
//    0x01  pen DOWN (start drawing)
//    0x02  pen UP   (stop drawing / move)
//    0x03  divide vector lengths by next byte (scale down)
//    0x04  multiply vector lengths by next byte (scale up)
//    0x05  push current location (location stack)
//    0x06  pop location (restore)
//    0x07  draw sub-shape whose number is the next byte (1- or 2-byte per flavor)
//    0x08  move by signed (x,y) given in the next two bytes
//    0x09  multiple (x,y) moves, (0,0) terminates
//    0x0A  octant arc: next two bytes = radius, (sign·octant-span)
//    0x0B  fractional arc: 5 bytes (start-offset, end-offset, hi-radius,
//          lo-radius, signed-octant-span)
//    0x0C  bulge arc: next two bytes = (x-disp, y-disp), one byte = bulge
//    0x0D  multiple bulge arcs: (x,y,bulge) triples, (0,0) terminates
//    0x0E  next command processed only for vertical text (we SKIP its operand)
//
//  Octant directions number CCW from "east" = 0; each octant is 45°. Arc codes
//  are tessellated into points using the shared `Tessellation` helper so the
//  glyph is straight polylines (identical to the `.lff` bulge expansion).
//
//  Robustness: a truncated/garbage buffer THROWS (never crashes / never reads OOB);
//  per-glyph bytecode errors degrade that ONE glyph (skip it) rather than failing
//  the whole font, mirroring AutoCAD's tolerant rendering.
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

/// Errors surfaced by the SHX loader. The I/O boundary and a structurally
/// unreadable buffer throw; malformed *glyph* bytecode does not (the bad glyph is
/// skipped), mirroring AutoCAD's tolerant rendering.
public enum SHXFontError: Error, Equatable, Sendable {
    /// The file could not be read from disk (missing path, permissions, …).
    case cannotReadFile(path: String)
    /// The signature line was missing / unrecognized (not an SHX shape font).
    case badSignature
    /// The buffer ended before a required field could be read (truncated file).
    case truncated
    /// The index table was structurally invalid (counts/offsets out of range).
    case malformedIndex
}

/// Stateless decoder for AutoCAD `.shx` shape fonts. Use the static entry points.
public enum SHXParser {

    /// Tessellation tolerance (em units) for expanding octant/bulge arc codes into
    /// polyline points. Glyphs are small (cap band ~tens of units) so a fine fixed
    /// tolerance keeps arcs smooth without exploding point counts (same rationale
    /// as `LFFParser.defaultBulgeTolerance`).
    public static let defaultArcTolerance = 0.05

    // MARK: - Public entry points

    /// Parses an SHX font from a raw byte buffer.
    /// - Throws: `SHXFontError.badSignature` / `.truncated` / `.malformedIndex`.
    public static func parse(
        data: Data,
        arcTolerance: Double = defaultArcTolerance
    ) throws -> SHXFont {
        let bytes = [UInt8](data)
        return try parse(bytes: bytes, arcTolerance: arcTolerance)
    }

    /// Parses an SHX font from a raw byte array (the pure, testable core).
    public static func parse(
        bytes: [UInt8],
        arcTolerance: Double = defaultArcTolerance
    ) throws -> SHXFont {
        var reader = try Reader(bytes: bytes)
        return try reader.run(arcTolerance: arcTolerance)
    }

    /// Loads and parses an SHX font from a file URL.
    public static func load(
        contentsOf url: URL,
        arcTolerance: Double = defaultArcTolerance
    ) throws -> SHXFont {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SHXFontError.cannotReadFile(path: url.path)
        }
        return try parse(data: data, arcTolerance: arcTolerance)
    }

    /// Loads and parses an SHX font from a filesystem path.
    public static func load(
        path: String,
        arcTolerance: Double = defaultArcTolerance
    ) throws -> SHXFont {
        try load(contentsOf: URL(fileURLWithPath: path), arcTolerance: arcTolerance)
    }
}

// MARK: - Internal byte reader / decoder

private extension SHXParser {

    /// Cursor over the byte buffer with bounds-checked reads. Every read either
    /// returns a value or throws `.truncated` — there is no path to an OOB access.
    struct Reader {
        let bytes: [UInt8]
        var pos: Int = 0
        let kind: SHXFontKind

        /// The signature lines we recognize, mapped to a flavor. Compared
        /// case-insensitively against the ASCII prefix of the file.
        static let signatures: [(prefix: String, kind: SHXFontKind)] = [
            ("AutoCAD-86 shapes 1.0", .shapes),
            ("AutoCAD-86 shapes 1.1", .shapes),
            ("AutoCAD-86 unifont 1.0", .unifont),
            ("AutoCAD-86 bigfont 1.0", .bigfont),
        ]

        init(bytes: [UInt8]) throws {
            self.bytes = bytes
            // The signature is an ASCII line terminated by 0x1A (Ctrl-Z / SUB).
            // Find that terminator and match the leading text against a known
            // signature; the binary data begins right after the 0x1A.
            guard let subIdx = bytes.firstIndex(of: 0x1A) else {
                throw SHXFontError.badSignature
            }
            let header = String(decoding: bytes[0..<subIdx], as: UTF8.self)
            var matched: SHXFontKind?
            for (prefix, k) in Self.signatures where header.contains(prefix) {
                matched = k
                break
            }
            guard let k = matched else { throw SHXFontError.badSignature }
            self.kind = k
            self.pos = subIdx + 1   // first byte after the 0x1A terminator
        }

        // MARK: Primitive reads (bounds-checked)

        mutating func u8() throws -> UInt8 {
            guard pos < bytes.count else { throw SHXFontError.truncated }
            defer { pos += 1 }
            return bytes[pos]
        }

        /// Little-endian unsigned 16-bit.
        mutating func u16() throws -> Int {
            let lo = Int(try u8())
            let hi = Int(try u8())
            return lo | (hi << 8)
        }

        /// A NUL-terminated ASCII name. Throws `.truncated` if no NUL is found.
        mutating func cString() throws -> String {
            var out: [UInt8] = []
            while true {
                let b = try u8()
                if b == 0 { break }
                out.append(b)
            }
            return String(decoding: out, as: UTF8.self)
        }

        // MARK: Drive the decode

        /// Reads the index table + every shape definition and assembles the font.
        mutating func run(arcTolerance: Double) throws -> SHXFont {
            // After the 0x1A: a one-byte file-type marker (0x1A again in some
            // exports), then the index table. The classic layout is:
            //   shapes  : [firstShapeNo:u16][count:u16] then count×[no:u16,len:u16]
            //   unifont : [count:u16][?:u8?] then count×[no:u16,len:u16]
            // We read defensively: a leading 0x00/0x1A pad byte is skipped, then
            // the count word is taken; for the classic "shapes" layout the first
            // word is a starting shape number we keep for validation.
            //
            // To be robust across the minor header variants in the wild, we parse
            // the index as: optional first-shape word, a count word, then `count`
            // (shapeNo, byteLength) pairs. The font-definition shape (#0) supplies
            // the metrics and the embedded escape flavor.

            // Skip an optional padding byte some compilers emit right after 0x1A.
            if pos < bytes.count, bytes[pos] == 0x1A || bytes[pos] == 0x00 {
                // Peek: only consume if the following two words still leave a sane
                // count. We can't know for sure, so consume a single 0x1A pad only.
                if bytes[pos] == 0x1A { pos += 1 }
            }

            // Index header. "shapes" begins with a starting-shape word; "unifont"
            // and "bigfont" begin directly with the count. We detect by reading two
            // words and validating the count against the remaining buffer.
            let first = try u16()
            let count: Int
            switch kind {
            case .shapes:
                // first = starting shape number; next word = count.
                count = try u16()
            case .unifont, .bigfont:
                // first IS the count.
                count = first
            }
            guard count > 0, count <= 0xFFFF else { throw SHXFontError.malformedIndex }

            // Read the directory: count × (shapeNo:u16, byteLength:u16).
            struct Entry { let shapeNo: Int; let length: Int }
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let no = try u16()
                let len = try u16()
                entries.append(Entry(shapeNo: no, length: len))
            }

            // The shape DATA blocks follow the directory, in directory order. Each
            // block is exactly `length` bytes: a NUL-terminated name then the
            // bytecode. We read each block from the current cursor.
            var glyphs: [UnicodeScalar: SHXGlyph] = [:]
            var aboveBaseline = 0.0
            var belowBaseline = 0.0
            var fontName = ""

            for entry in entries {
                guard entry.length >= 0, pos + entry.length <= bytes.count else {
                    // Truncated data block: stop reading further shapes but keep what
                    // we have (the font is still partially usable). If we have NOTHING
                    // yet, treat as truncated.
                    if glyphs.isEmpty && entry.shapeNo != 0 {
                        throw SHXFontError.truncated
                    }
                    break
                }
                let blockEnd = pos + entry.length
                let name = try cString()

                if entry.shapeNo == 0 {
                    // Font-definition shape: name = font name; first two bytes of the
                    // body = (above-baseline, below-baseline) heights.
                    fontName = name
                    if pos < blockEnd { aboveBaseline = Double(try u8()) }
                    if pos < blockEnd { belowBaseline = Double(try u8()) }
                    pos = blockEnd
                    continue
                }

                // Glyph shape: interpret the bytecode for this block in isolation.
                let body = Array(bytes[pos..<blockEnd])
                pos = blockEnd
                let scalar = UnicodeScalar(UInt32(entry.shapeNo & 0x10FFFF))
                guard let scalar else { continue }
                // A bad bytecode degrades THIS glyph only (skip), never the font.
                if let glyph = try? ShapeInterp.decode(
                    body: body, kind: kind, arcTolerance: arcTolerance) {
                    glyphs[scalar] = glyph
                }
            }

            // Fall back to a sensible cap band if the header omitted metrics.
            if aboveBaseline <= 0 { aboveBaseline = estimatedCapBand(from: glyphs) }
            if belowBaseline <= 0 { belowBaseline = aboveBaseline / 3.0 }

            return SHXFont(
                glyphs: glyphs,
                kind: kind,
                aboveBaseline: aboveBaseline,
                belowBaseline: belowBaseline,
                fontName: fontName
            )
        }

        /// Estimates a cap band from the glyphs' max y when the header lacks one
        /// (so DXF `height` still maps to a sensible scale).
        func estimatedCapBand(from glyphs: [UnicodeScalar: SHXGlyph]) -> Double {
            var maxY = 0.0
            for (_, g) in glyphs {
                if let b = g.bounds() { maxY = Swift.max(maxY, b.max.y) }
            }
            return maxY > 0 ? maxY : 1.0
        }
    }
}

// MARK: - Shape bytecode interpreter

private extension SHXParser {

    /// Interprets one glyph's shape bytecode into open-polyline strokes + advance.
    /// Pure and self-contained: it consumes ONLY the glyph's own body bytes (no
    /// access to the whole file) so a single bad glyph cannot corrupt others.
    enum ShapeInterp {

        /// Decodes the glyph body. Throws on a structurally impossible read so the
        /// caller can skip this one glyph; returns a glyph (possibly with no strokes,
        /// e.g. a space) otherwise.
        static func decode(body: [UInt8], kind: SHXFontKind, arcTolerance: Double) throws -> SHXGlyph {
            var s = State(body: body, kind: kind, arcTolerance: arcTolerance)
            try s.run()
            return s.makeGlyph()
        }

        /// Mutable interpreter state for one glyph.
        struct State {
            let body: [UInt8]
            let kind: SHXFontKind
            let arcTolerance: Double
            var pos = 0

            var pen = Vector(0, 0)         // current location (em units)
            var penDown = true            // pen starts DOWN per the spec
            var scale = 1.0               // current vector-length scale (0x03/0x04)
            var locStack: [Vector] = []   // 0x05 push / 0x06 pop
            var maxX = 0.0                // rightmost reach (advance proxy)

            var current: [Vector] = []    // the in-progress open stroke
            var strokes: [[Vector]] = []

            init(body: [UInt8], kind: SHXFontKind, arcTolerance: Double) {
                self.body = body
                self.kind = kind
                self.arcTolerance = arcTolerance
                self.current = [pen]
            }

            // MARK: bounds-checked reads (throw on truncation)

            mutating func u8() throws -> UInt8 {
                guard pos < body.count else { throw SHXFontError.truncated }
                defer { pos += 1 }
                return body[pos]
            }
            mutating func s8() throws -> Int { Int(Int8(bitPattern: try u8())) }

            // MARK: pen ops

            /// Flushes the in-progress stroke (≥2 points) and starts a fresh one at
            /// the current pen — called when the pen lifts or a discontinuity occurs.
            mutating func breakStroke() {
                if current.count >= 2 { strokes.append(current) }
                current = [pen]
            }

            /// Moves the pen by `delta` (already scaled). Extends the current stroke
            /// when the pen is down; otherwise starts a new stroke at the new point.
            mutating func move(by delta: Vector) {
                pen = pen + delta
                maxX = Swift.max(maxX, pen.x)
                if penDown {
                    current.append(pen)
                } else {
                    // pen up: relocate the (empty) current stroke start.
                    current = [pen]
                }
            }

            /// Appends already-computed arc points (em units) to the current stroke
            /// when the pen is down (the first point coincides with the pen).
            mutating func drawArc(points: [Vector]) {
                guard let last = points.last else { return }
                if penDown {
                    // Skip the first point (it's the current pen position) to avoid a
                    // duplicate vertex, then extend.
                    if points.count > 1 { current.append(contentsOf: points.dropFirst()) }
                } else {
                    current = [last]
                }
                pen = last
                for p in points { maxX = Swift.max(maxX, p.x) }
            }

            // MARK: the interpreter loop

            mutating func run() throws {
                while pos < body.count {
                    let code = try u8()
                    let hi = Int(code >> 4)
                    let lo = Int(code & 0x0F)

                    if hi != 0 {
                        // Ordinary one-byte vector: length = hi nibble, dir = lo nibble.
                        let len = Double(hi) * scale
                        let v = ShapeInterp.dir16Standard(lo) * len
                        move(by: v)
                        continue
                    }

                    // hi == 0: a SPECIAL code keyed by the low nibble.
                    switch lo {
                    case 0x0:                        // end of shape
                        return
                    case 0x1:                        // pen DOWN
                        penDown = true
                        // begin a fresh stroke at the current pen
                        current = [pen]
                    case 0x2:                        // pen UP
                        breakStroke()
                        penDown = false
                    case 0x3:                        // divide scale by next byte
                        let d = try u8()
                        if d != 0 { scale /= Double(d) }
                    case 0x4:                        // multiply scale by next byte
                        let m = try u8()
                        scale *= Double(m)
                    case 0x5:                        // push location
                        locStack.append(pen)
                    case 0x6:                        // pop location
                        if let p = locStack.popLast() {
                            breakStroke()
                            pen = p
                            current = [pen]
                        }
                    case 0x7:                        // draw sub-shape (number follows)
                        // Sub-shape inclusion needs the whole-font table, which the
                        // per-glyph interpreter does not have. Consume the operand so
                        // the stream stays aligned and skip drawing it (a rare,
                        // gracefully-degraded case). 2 bytes for unifont/bigfont.
                        if kind == .shapes { _ = try u8() } else { _ = try u16Body() }
                    case 0x8:                        // move (x,y) signed, next 2 bytes
                        let dx = Double(try s8()) * scale
                        let dy = Double(try s8()) * scale
                        move(by: Vector(dx, dy))
                    case 0x9:                        // multiple (x,y) moves, (0,0) ends
                        while true {
                            let dx = try s8()
                            let dy = try s8()
                            if dx == 0 && dy == 0 { break }
                            move(by: Vector(Double(dx) * scale, Double(dy) * scale))
                        }
                    case 0xA:                        // octant arc: radius, ±octant-span
                        try octantArc()
                    case 0xB:                        // fractional arc: 5 operand bytes
                        try fractionalArc()
                    case 0xC:                        // bulge arc: (dx,dy) + bulge byte
                        try bulgeArc()
                    case 0xD:                        // multiple bulge arcs, (0,0) ends
                        while true {
                            let dx = try s8()
                            let dy = try s8()
                            if dx == 0 && dy == 0 { break }
                            let bulge = try s8()
                            drawBulgeSegment(dx: Double(dx) * scale,
                                             dy: Double(dy) * scale,
                                             bulgeByte: bulge)
                        }
                    case 0xE:                        // vertical-text-only command: skip operand
                        // The next command is processed only in vertical mode; in
                        // horizontal mode we skip ONE command's worth. The simplest
                        // safe skip is the common case (an (x,y) move pair).
                        _ = try? s8(); _ = try? s8()
                    default:
                        // Unknown special low-nibble: ignore (defensive).
                        break
                    }
                }
            }

            /// Two-byte big-endian operand inside a glyph body (sub-shape numbers in
            /// unifont/bigfont are stored big-endian).
            mutating func u16Body() throws -> Int {
                let hi = Int(try u8())
                let lo = Int(try u8())
                return (hi << 8) | lo
            }

            // MARK: arc codes

            /// 0x0A octant arc. Operands: `radius` (byte), then a signed byte whose
            /// magnitude's low nibble is the number of octants spanned and whose high
            /// nibble (bits) is the starting octant; the sign gives CW (−) vs CCW (+).
            mutating func octantArc() throws {
                let radius = Double(try u8()) * scale
                let spec = try u8()
                let ccw = (Int8(bitPattern: spec) >= 0)
                let mag = Int(spec & 0x7F)
                let startOctant = (mag >> 4) & 0x07
                var octantCount = mag & 0x07
                if octantCount == 0 { octantCount = 8 }   // 0 ⇒ full 8-octant circle
                guard radius > 0 else { return }

                let octant = Double.pi / 4.0
                let startAngle = Double(startOctant) * octant
                let sweep = (ccw ? 1.0 : -1.0) * Double(octantCount) * octant

                // The arc center is offset from the pen along the start radius so the
                // arc BEGINS at the current pen position.
                let center = pen - Vector(angle: startAngle) * radius
                let pts = Tessellation.arcPointsBySweep(
                    center: center, radius: radius,
                    startAngle: startAngle, sweep: sweep, tolerance: arcTolerance)
                drawArc(points: pts)
            }

            /// 0x0B fractional (high-precision) arc. Operands: start-offset,
            /// end-offset, high-radius, low-radius, signed octant span. We honor the
            /// radius (hi·256 + lo) and the octant span; offsets refine the endpoints
            /// (treated as small angular adjustments within the start/end octant).
            mutating func fractionalArc() throws {
                let startOffset = Double(try u8()) / 256.0
                let endOffset = Double(try u8()) / 256.0
                let radHi = Int(try u8())
                let radLo = Int(try u8())
                let spec = try u8()
                let radius = Double(radHi * 256 + radLo) * scale
                guard radius > 0 else { return }

                let ccw = (Int8(bitPattern: spec) >= 0)
                let mag = Int(spec & 0x7F)
                let startOctant = (mag >> 4) & 0x07
                var octantCount = mag & 0x07
                if octantCount == 0 { octantCount = 8 }

                let octant = Double.pi / 4.0
                // Offsets nudge the start/end by a fraction of one octant.
                let startAngle = (Double(startOctant) + startOffset) * octant
                let span = (Double(octantCount) - startOffset - (1.0 - endOffset)) * octant
                let sweep = (ccw ? 1.0 : -1.0) * Swift.max(span, octant * 0.0625)

                let center = pen - Vector(angle: startAngle) * radius
                let pts = Tessellation.arcPointsBySweep(
                    center: center, radius: radius,
                    startAngle: startAngle, sweep: sweep, tolerance: arcTolerance)
                drawArc(points: pts)
            }

            /// 0x0C bulge arc: an (x,y) displacement plus a bulge byte
            /// (`bulge = sign · |b|/127`, the standard SHX bulge encoding where the
            /// magnitude is the ratio of the arc's height to half the chord).
            mutating func bulgeArc() throws {
                let dx = Double(try s8()) * scale
                let dy = Double(try s8()) * scale
                let bulge = try s8()
                drawBulgeSegment(dx: dx, dy: dy, bulgeByte: bulge)
            }

            /// Draws one bulge segment from the pen to pen+(dx,dy) with the byte-coded
            /// bulge, reusing the DXF bulge math (`bulge = tan(includedAngle/4)`).
            mutating func drawBulgeSegment(dx: Double, dy: Double, bulgeByte: Int) {
                let end = pen + Vector(dx, dy)
                // SHX bulge byte: signed, magnitude/127 == DXF bulge value.
                let bulge = Double(bulgeByte) / 127.0
                if abs(bulge) < 1e-9 || (dx == 0 && dy == 0) {
                    move(by: Vector(dx, dy))
                    return
                }
                let chord = end - pen
                let chordLen = chord.magnitude
                guard chordLen > 1e-9 else { move(by: Vector(dx, dy)); return }
                let included = 4 * atan(bulge)
                let radius = abs(chordLen / (2 * sin(included / 2)))
                let mid = (pen + end) * 0.5
                let half = chordLen / 2
                let apothem = (max(0, radius * radius - half * half)).squareRoot()
                let dirU = chord / chordLen
                let leftNormal = Vector(-dirU.y, dirU.x)
                let apexSide = (bulge >= 0 ? 1.0 : -1.0)
                let centerSign = -((cos(included / 2)).sign == .minus ? -1.0 : 1.0)
                let center = mid + leftNormal * (apexSide * centerSign * apothem)
                let startAngle = (pen - center).angle
                let pts = Tessellation.arcPointsBySweep(
                    center: center, radius: radius,
                    startAngle: startAngle, sweep: -included, tolerance: arcTolerance)
                drawArc(points: pts)
            }

            // MARK: finalize

            mutating func makeGlyph() -> SHXGlyph {
                breakStroke()
                // advance = the rightmost pen reach (em units); SHX has no separate
                // width record, so the right ink/pen extent is the de-facto advance.
                let advance = Swift.max(maxX, pen.x)
                return SHXGlyph(strokes: strokes, advance: advance)
            }
        }

        /// The standard SHX 16-direction "vector chart". Direction 0 = east, then
        /// CCW. The chart uses 1:2 / 2:1 ratios so that a length-N draw vector lands
        /// on integer grid points; a length multiplies the per-direction step here.
        /// The dominant-axis component is ±1, with the off-axis component ±0.5 for
        /// the 26.57° spokes and ±1 for the 45° diagonals — the documented chart.
        static func dir16Standard(_ i: Int) -> Vector {
            let table: [(Double, Double)] = [
                ( 1,  0), ( 1,  0.5), ( 1,  1), ( 0.5,  1),
                ( 0,  1), (-0.5,  1), (-1,  1), (-1,  0.5),
                (-1,  0), (-1, -0.5), (-1, -1), (-0.5, -1),
                ( 0, -1), ( 0.5, -1), ( 1, -1), ( 1, -0.5),
            ]
            let idx = ((i % 16) + 16) % 16
            let (x, y) = table[idx]
            return Vector(x, y)
        }
    }
}
